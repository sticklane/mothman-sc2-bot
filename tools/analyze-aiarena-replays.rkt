#lang racket/base

;; =============================================================================
;; Pure-Racket AI Arena Forensic Replay & Match-Log Analyzer
;; (`tools/analyze-aiarena-replays.rkt`)
;;
;; 100% Zero-Python forensic pipeline for AI Arena & local SC2 replays:
;;   1. Fetches match metadata, `.SC2Replay`, and `match_log.zip` from the
;;      AI Arena REST API (`/api/match-participations/`, `/api/results/`,
;;      `/api/bots/`) via `curl` with bounded parallel worker threads.
;;   2. Decodes `.SC2Replay` MPQ archives + S2Protocol streams in pure Racket
;;      via `lib/sc2-mpq-replay-parser.rkt`.
;;   3. Extracts `stdout.log` and `stderr.log` from `match_log.zip` in-memory
;;      via `file/unzip`, auditing `[SCBOT_PRIORITY]` (`step_ms` P50/P95/max,
;;      `saving_for`, `escrow_queue`, `blocked`), `ActionResult`/`Error_*`
;;      failures, `[SCBOT_TELEMETRY]`, `Tag:` lines, and `stderr.log` crashes.
;;   4. Emits root-cause diagnostic tags + minute-by-minute telemetry + JSON.
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/port
         racket/runtime-path
         racket/set
         racket/string
         racket/system
         file/unzip
         json
         "../lib/sc2-mpq-replay-parser.rkt")

(provide DEFAULT-TOKEN
         BOT-IDS
         KNOWN-BOT-NAMES
         SIDECAR-BIN
         parse-bot-filter
         parse-match-ids-str
         parse-match-log-zip
         invoke-s2protocol-sidecar-summary
         analyze-single-match-forensics
         fetch-aiarena-matches!
         run-aiarena-forensic-analysis!)

(define-runtime-path TOOLS-DIR ".")
(define ROOT-DIR (simplify-path (build-path TOOLS-DIR "..")))
(define DEFAULT-CACHE-DIR (build-path ROOT-DIR "replays" "aiarena_live_cache"))
(define SIDECAR-BIN
  (build-path ROOT-DIR "crates" "s2protocol-sidecar" "target" "release" "s2protocol-sidecar"))

(define TOKEN-FILE (build-path (find-system-path 'home-dir) ".gemini" "aiarena_token"))

(define DEFAULT-TOKEN
  (or (getenv "AIARENA_API_TOKEN")
      (and (file-exists? TOKEN-FILE)
           (let ([t (string-trim (file->string TOKEN-FILE))])
             (and (not (string=? t "")) t)))
      "717fa15cc782b2432c2fe14da6d92c202dfe6c96"))

(define BOT-IDS
  (hasheqv 1457 "Mothman-R"
           1458 "Mothman-Z"
           1459 "Mothman-T"
           1460 "Mothman-P"
           1461 "Mothman-X"))

(define KNOWN-BOT-NAMES
  (make-hasheqv
   '((1457 . "Mothman-R")
     (1458 . "Mothman-Z")
     (1459 . "Mothman-T")
     (1460 . "Mothman-P")
     (1461 . "Mothman-X")
     (1256 . "Atlas")
     (248  . "Eris")
     (611  . "Phobos")
     (730  . "Deimos"))))

(define (round1 x)
  (/ (round (* 10.0 (exact->inexact x))) 10.0))

(define (round2 x)
  (/ (round (* 100.0 (exact->inexact x))) 100.0))

(define (jnull->false v)
  (if (or (eq? v 'null) (not v)) #f v))

(define (safe-filename-token s)
  (define cleaned (regexp-replace* #rx"[^A-Za-z0-9._-]+" (format "~a" s) "_"))
  (if (string=? cleaned "") "Opponent" cleaned))

;; -----------------------------------------------------------------------------
;; 1. CLI Filter Parsers (`--bots`, `--match-ids`)
;; -----------------------------------------------------------------------------

(define (parse-bot-filter bots-str)
  (cond
    [(or (not bots-str) (string=? (string-trim bots-str) "") (string-ci=? (string-trim bots-str) "all"))
     '(1458 1459 1460 1461)]
    [else
     (define tokens
       (filter (lambda (s) (not (string=? s "")))
               (map string-trim (string-split bots-str ","))))
     (remove-duplicates
      (filter values
              (for/list ([tok (in-list tokens)])
                (define up (string-upcase tok))
                (cond
                  [(or (string=? up "Z") (string=? up "MOTHMAN-Z") (string=? up "1458")) 1458]
                  [(or (string=? up "T") (string=? up "MOTHMAN-T") (string=? up "1459")) 1459]
                  [(or (string=? up "P") (string=? up "MOTHMAN-P") (string=? up "1460")) 1460]
                  [(or (string=? up "X") (string=? up "MOTHMAN-X") (string=? up "1461")) 1461]
                  [(or (string=? up "R") (string=? up "MOTHMAN-R") (string=? up "1457")) 1457]
                  [(string->number tok) => (lambda (n) (and (exact-integer? n) n))]
                  [else #f]))))]))

(define (parse-match-ids-str ids-str)
  (if (or (not ids-str) (string=? (string-trim ids-str) ""))
      '()
      (sort
       (remove-duplicates
        (filter exact-positive-integer?
                (map (lambda (s) (string->number (string-trim s)))
                     (string-split ids-str ","))))
       <)))

;; -----------------------------------------------------------------------------
;; 2. HTTP / AI Arena REST Helpers (`curl`)
;; -----------------------------------------------------------------------------

(define (curl-get-json url [token DEFAULT-TOKEN])
  (define curl-bin (or (find-executable-path "curl") (string->path "/usr/bin/curl")))
  (define out-str
    (with-output-to-string
      (lambda ()
        (system* curl-bin "-sL" "--max-time" "20"
                 "-H" (format "Authorization: Token ~a" token)
                 "-H" "User-Agent: mothman-racket-forensics/3.0"
                 url))))
  (with-handlers ([exn:fail? (lambda (_e) (hasheq 'raw out-str))])
    (string->jsexpr out-str)))

(define (curl-download-file! url dest-path [token DEFAULT-TOKEN])
  (define curl-bin (or (find-executable-path "curl") (string->path "/usr/bin/curl")))
  (define dest-str (if (path? dest-path) (path->string dest-path) dest-path))
  (define tmp-str (string-append dest-str ".part"))
  (define auth-args
    (if (string-contains? url "aiarena.net")
        (list "-H" (format "Authorization: Token ~a" token))
        '()))
  (define ok?
    (apply system*
           curl-bin
           "-sfL"
           "--max-time" "25"
           "-H" "User-Agent: mothman-racket-forensics/3.0"
           "-o" tmp-str
           (append auth-args (list url))))
  (cond
    [(and ok? (file-exists? tmp-str) (> (file-size tmp-str) 0))
     (rename-file-or-directory tmp-str dest-str #t)
     #t]
    [else
     (with-handlers ([exn:fail? void])
       (when (file-exists? tmp-str) (delete-file tmp-str)))
     #f]))

(define bot-cache-sema (make-semaphore 1))

(define (load-bot-names-cache! out-dir)
  (define cache-file (build-path out-dir "bot_names_cache.json"))
  (when (file-exists? cache-file)
    (with-handlers ([exn:fail? void])
      (define js (call-with-input-file cache-file read-json))
      (when (hash? js)
        (for ([(k v) (in-hash js)])
          (define id-num (string->number (symbol->string k)))
          (when (and id-num (string? v))
            (hash-set! KNOWN-BOT-NAMES id-num v)))))))

(define (save-bot-names-cache! out-dir)
  (define cache-file (build-path out-dir "bot_names_cache.json"))
  (with-handlers ([exn:fail? void])
    (define out-h
      (for/hasheq ([(k v) (in-hash KNOWN-BOT-NAMES)])
        (values (string->symbol (number->string k)) v)))
    (call-with-output-file cache-file #:exists 'replace
      (lambda (out) (write-json out-h out)))))

(define (resolve-bot-name! bot-id token)
  (cond
    [(not (exact-positive-integer? bot-id)) "Opponent"]
    [else
     (define cached
       (call-with-semaphore bot-cache-sema
         (lambda () (hash-ref KNOWN-BOT-NAMES bot-id #f))))
     (if cached
         cached
         (let* ([resp (curl-get-json (format "https://aiarena.net/api/bots/~a/" bot-id) token)]
                [bname (and (hash? resp) (jnull->false (hash-ref resp 'name #f)))]
                [final-name (if (and (string? bname) (not (string=? bname "")))
                                bname
                                (format "Bot~a" bot-id))])
           (call-with-semaphore bot-cache-sema
             (lambda () (hash-set! KNOWN-BOT-NAMES bot-id final-name)))
           final-name))]))

(define (fetch-single-match-artifacts! mid out-dir token)
  (define meta-path (build-path out-dir (format "~a_meta.json" mid)))
  ;; Reuse cached metadata if match was already finalized (has non-empty result_type)
  (define existing-meta
    (and (file-exists? meta-path)
         (with-handlers ([exn:fail? (lambda (_e) #f)])
           (call-with-input-file meta-path read-json))))
  (define finalized-cached?
    (and (hash? existing-meta)
         (let ([rt (jnull->false (hash-ref existing-meta 'result_type #f))])
           (and (string? rt) (not (string=? rt ""))))))

  (define meta
    (if finalized-cached?
        existing-meta
        (let* ([mp-resp (curl-get-json (format "https://aiarena.net/api/match-participations/?match=~a" mid) token)]
               [parts (if (hash? mp-resp) (hash-ref mp-resp 'results '()) '())]
               [res-resp (curl-get-json (format "https://aiarena.net/api/results/?match=~a" mid) token)]
               [res-list (if (hash? res-resp) (hash-ref res-resp 'results '()) '())]
               [r0 (if (pair? res-list) (car res-list) (hasheq))])
          (define our-part
            (for/first ([p (in-list parts)]
                        #:when (and (hash? p) (hash-has-key? BOT-IDS (hash-ref p 'bot -1))))
              p))
          (define opp-part
            (for/first ([p (in-list parts)]
                        #:when (and (hash? p)
                                    (not (equal? (hash-ref p 'id #f)
                                                 (and our-part (hash-ref our-part 'id #f))))))
              p))
          (define our-bid (and our-part (jnull->false (hash-ref our-part 'bot #f))))
          (define opp-bid (and opp-part (jnull->false (hash-ref opp-part 'bot #f))))
          (define our-bname (if our-bid (hash-ref BOT-IDS our-bid (format "Bot~a" our-bid)) "Mothman"))
          (define opp-bname (if opp-bid (resolve-bot-name! opp-bid token) "Opponent"))
          (define avg-step-sec (and our-part (jnull->false (hash-ref our-part 'avg_step_time #f))))
          (define avg-step-ms
            (if (real? avg-step-sec) (round2 (* 1000.0 avg-step-sec)) #f))
          (define m-obj
            (hasheq 'match_id mid
                    'our_bot_id (or our-bid 0)
                    'our_bot_name our-bname
                    'opp_bot_id (or opp-bid 0)
                    'opp_bot_name opp-bname
                    'our_participant_number (or (and our-part (jnull->false (hash-ref our-part 'participant_number #f))) 0)
                    'result (or (and our-part (jnull->false (hash-ref our-part 'result #f))) "in_progress")
                    'result_cause (or (and our-part (jnull->false (hash-ref our-part 'result_cause #f))) "")
                    'elo_change (or (and our-part (jnull->false (hash-ref our-part 'elo_change #f))) 0)
                    'resultant_elo (or (and our-part (jnull->false (hash-ref our-part 'resultant_elo #f))) 0)
                    'avg_step_time_ms (or avg-step-ms 0.0)
                    'match_log_url (or (and our-part (jnull->false (hash-ref our-part 'match_log #f))) "")
                    'result_type (or (jnull->false (hash-ref r0 'type #f)) "")
                    'game_steps (or (jnull->false (hash-ref r0 'game_steps #f)) 0)
                    'replay_url (or (jnull->false (hash-ref r0 'replay_file #f)) "")
                    'created (or (jnull->false (hash-ref r0 'created #f)) "")))
          (with-handlers ([exn:fail? void])
            (call-with-output-file meta-path #:exists 'replace
              (lambda (out) (write-json m-obj out))))
          m-obj)))

  ;; Download match_log.zip if available and missing
  (define mlog-url (hash-ref meta 'match_log_url ""))
  (define log-dest (build-path out-dir (format "~a_match_log.zip" mid)))
  (when (and (string? mlog-url) (not (string=? mlog-url "")) (not (file-exists? log-dest)))
    (void (curl-download-file! mlog-url log-dest token)))

  ;; Download .SC2Replay if available and missing
  (define rep-url (hash-ref meta 'replay_url ""))
  (define existing-reps
    (filter (lambda (p)
              (define fn (path->string (file-name-from-path p)))
              (and (string-prefix? fn (format "~a_" mid))
                   (string-suffix? fn ".SC2Replay")))
            (directory-list out-dir #:build? #t)))
  (when (and (string? rep-url) (not (string=? rep-url "")) (null? existing-reps))
    (define our-bname (safe-filename-token (hash-ref meta 'our_bot_name "Mothman")))
    (define opp-bname (safe-filename-token (hash-ref meta 'opp_bot_name "Opponent")))
    (define rep-dest (build-path out-dir (format "~a_~a_vs_~a.SC2Replay" mid our-bname opp-bname)))
    (void (curl-download-file! rep-url rep-dest token)))

  meta)

(define (parallel-for-each proc items [max-workers 6])
  (define q (make-semaphore 1))
  (define rem items)
  (define (next-item!)
    (call-with-semaphore q
      (lambda ()
        (if (null? rem)
            #f
            (begin0 (car rem) (set! rem (cdr rem)))))))
  (define workers
    (for/list ([_ (in-range (min max-workers (max 1 (length items))))])
      (thread
       (lambda ()
         (let loop ()
           (define it (next-item!))
           (when it
             (with-handlers ([exn:fail? (lambda (e)
                                          (eprintf "[WARN] Fetch worker error on ~a: ~a\n"
                                                   it (exn-message e)))])
               (proc it))
             (loop)))))))
  (for-each thread-wait workers))

(define (fetch-aiarena-matches! out-dir
                                #:token [token DEFAULT-TOKEN]
                                #:bot-ids [bot-ids '(1458 1459 1460 1461)]
                                #:match-ids [explicit-match-ids '()]
                                #:since-match [since-match #f]
                                #:limit [limit 25])
  (make-directory* out-dir)
  (load-bot-names-cache! out-dir)

  (define discovered-mids
    (cond
      [(pair? explicit-match-ids)
       explicit-match-ids]
      [else
       (define per-bot-limit (if since-match (max limit 40) limit))
       (define mid-lists
         (for/list ([bid (in-list bot-ids)])
           (define url
             (format "https://aiarena.net/api/match-participations/?bot=~a&ordering=-match&limit=~a"
                     bid per-bot-limit))
           (define resp (curl-get-json url token))
           (define rows (if (hash? resp) (hash-ref resp 'results '()) '()))
           (for/list ([r (in-list rows)]
                      #:when (and (hash? r) (exact-positive-integer? (hash-ref r 'match #f))))
             (hash-ref r 'match))))
       (define all-mids (sort (remove-duplicates (apply append mid-lists)) <))
       (define after-since
         (if since-match
             (filter (lambda (m) (>= m since-match)) all-mids)
             all-mids))
       (if (and (not since-match) (> (length after-since) limit))
           (take-right after-since limit)
           after-since)]))

  (printf "[FETCH] Syncing ~a AI Arena match(es) into ~a...\n"
          (length discovered-mids)
          (if (path? out-dir) (path->string out-dir) out-dir))
  (flush-output)
  (parallel-for-each
   (lambda (mid) (fetch-single-match-artifacts! mid out-dir token))
   discovered-mids
   6)
  (save-bot-names-cache! out-dir)
  discovered-mids)

;; -----------------------------------------------------------------------------
;; 3. Pure-Racket `match_log.zip` Forensics (`file/unzip`)
;; -----------------------------------------------------------------------------

(define (percentile-sorted sorted-nums pct)
  (if (null? sorted-nums)
      0.0
      (let* ([n (length sorted-nums)]
             [idx (min (sub1 n) (max 0 (exact-floor (* pct n))))])
        (round2 (list-ref sorted-nums idx)))))

(define (top-k-counts count-hash [k 8])
  (define pairs
    (sort (hash->list count-hash)
          (lambda (a b)
            (if (= (cdr a) (cdr b))
                (string<? (format "~a" (car a)) (format "~a" (car b)))
                (> (cdr a) (cdr b))))))
  (for/list ([p (in-list (take pairs (min k (length pairs))))])
    (list (format "~a" (car p)) (cdr p))))

(define (extract-paren-items line key-prefix)
  ;; Extracts space-separated tokens inside `key=(...)`
  (define pat (regexp (string-append (regexp-quote key-prefix) "\\(([^)]*)\\)")))
  (define m (regexp-match pat line))
  (if (and m (cadr m))
      (filter (lambda (s) (not (string=? s "")))
              (string-split (string-trim (cadr m)) " "))
      '()))

(define (parse-match-log-zip zip-path)
  (define tags '())
  (define telemetry-events '())
  (define native-summary #f)
  (define prio-step-ms '())
  (define saving-for-counts (make-hash))
  (define escrow-item-counts (make-hash))
  (define blocked-item-counts (make-hash))
  (define action-error-counts (make-hash))
  (define stderr-exceptions '())
  (define prio-total 0)
  (define prio-active-escrow 0)
  (define cur-streak-target "")
  (define cur-streak-len 0)
  (define max-streak-target "none")
  (define max-streak-len 0)

  (define (scan-action-errors! line)
    ;; Match `ActionResult=207`, `ActionResult.Error_...`, or `Error_CantBuildOnThat` etc.
    (for ([tok (in-list (regexp-match* #rx"(?:ActionResult[=.:][A-Za-z0-9_]+|Error_[A-Za-z0-9_]+)" line))])
      (hash-update! action-error-counts tok add1 0)))

  (define (scan-priority-line! line)
    (set! prio-total (add1 prio-total))
    ;; step_ms=<num>
    (define sm (regexp-match #rx"step_ms=([0-9]+(?:\\.[0-9]+)?)" line))
    (when sm
      (define v (string->number (cadr sm)))
      (when (real? v)
        (set! prio-step-ms (cons (exact->inexact v) prio-step-ms))))
    ;; saving_for=<target>(...) or saving_for=none
    (define sf (regexp-match #rx"saving_for=([^ (]+)" line))
    (when sf
      (define target (cadr sf))
      (hash-update! saving-for-counts target add1 0)
      (cond
        [(string=? target "none")
         (set! cur-streak-target "")
         (set! cur-streak-len 0)]
        [(string=? target cur-streak-target)
         (set! cur-streak-len (add1 cur-streak-len))
         (when (> cur-streak-len max-streak-len)
           (set! max-streak-len cur-streak-len)
           (set! max-streak-target target))]
        [else
         (set! cur-streak-target target)
         (set! cur-streak-len 1)
         (when (> cur-streak-len max-streak-len)
           (set! max-streak-len cur-streak-len)
           (set! max-streak-target target))]))
    ;; escrow_queue=(...)
    (define eq-items (extract-paren-items line "escrow_queue="))
    (when (pair? eq-items)
      (set! prio-active-escrow (add1 prio-active-escrow))
      (for ([it (in-list eq-items)])
        (define head (car (string-split it "@")))
        (hash-update! escrow-item-counts head add1 0)))
    ;; blocked=(...)
    (for ([it (in-list (extract-paren-items line "blocked="))])
      (define head (car (string-split it "@")))
      (hash-update! blocked-item-counts head add1 0)))

  (when (and zip-path (file-exists? zip-path))
    (with-handlers ([exn:fail? (lambda (e)
                                 (set! stderr-exceptions
                                       (cons (format "zip_parse_error: ~a" (exn-message e))
                                             stderr-exceptions)))])
      (unzip zip-path
             (lambda (raw-name dir? in)
               (unless dir?
                 (define entry-name
                   (path->string (file-name-from-path (bytes->path raw-name))))
                 (define txt (bytes->string/utf-8 (port->bytes in) #\?))
                 (cond
                   [(string=? entry-name "stdout.log")
                    (for ([raw-line (in-list (string-split txt "\n"))])
                      (define line (string-trim raw-line))
                      (unless (string=? line "")
                        (scan-action-errors! line)
                        (cond
                          [(string-prefix? line "Tag:")
                           (set! tags (cons (string-trim (substring line 4)) tags))]
                          [(string-prefix? line "[SCBOT_TELEMETRY]")
                           (define js-str (string-trim (substring line 17)))
                           (with-handlers ([exn:fail? void])
                             (set! telemetry-events (cons (string->jsexpr js-str) telemetry-events)))]
                          [(string-contains? line "[SCBOT_PRIORITY]")
                           (scan-priority-line! line)]
                          [(and (string-prefix? line "{") (string-suffix? line "}"))
                           (with-handlers ([exn:fail? void])
                             (define js (string->jsexpr line))
                             (when (and (hash? js) (hash-has-key? js 'status))
                               (set! native-summary js)))])))]
                   [(string=? entry-name "stderr.log")
                    (for ([raw-line (in-list (string-split txt "\n"))])
                      (define line (string-trim raw-line))
                      (unless (string=? line "")
                        (scan-action-errors! line)
                        (cond
                          [(string-contains? line "[SCBOT_PRIORITY]")
                           (scan-priority-line! line)]
                          [(string-prefix? line "[SCBOT_TELEMETRY]")
                           (void)]
                          [else
                           (set! stderr-exceptions (cons line stderr-exceptions))])))]))))))

  (define sorted-ms (sort prio-step-ms <))
  (define avg-ms
    (if (null? sorted-ms)
        0.0
        (round2 (/ (apply + sorted-ms) (length sorted-ms)))))
  (define p50-ms (percentile-sorted sorted-ms 0.50))
  (define p95-ms (percentile-sorted sorted-ms 0.95))
  (define max-ms (if (null? sorted-ms) 0.0 (round2 (last sorted-ms))))

  ;; Schema 2.0 telemetry summary if present
  (define schema2-summary
    (for/fold ([acc (hasheq)])
              ([ev (in-list (reverse telemetry-events))])
      (if (and (hash? ev)
               (member (hash-ref ev 'event "") '("PERIODIC_SNAPSHOT" "MATCH_END_SUMMARY")))
          (for/fold ([h acc])
                    ([k (in-list '(schema_version
                                   guns_vs_butter_regime
                                   target_resource_ratio
                                   worker_prod_utilization_pct
                                   unit_prod_utilization_pct
                                   observed_enemy_upgrades
                                   implied_enemy_tech_buildings
                                   enemy_committed_branch
                                   our_lost_minerals
                                   our_lost_gas
                                   enemy_lost_minerals
                                   enemy_lost_gas
                                   estimated_enemy_workers
                                   bottlenecks))]
                     #:when (hash-has-key? ev k))
            (hash-set h k (hash-ref ev k)))
          acc)))

  (hasheq 'log_exists (and zip-path (file-exists? zip-path) #t)
          'tags (reverse tags)
          'telemetry_event_count (length telemetry-events)
          'schema2_summary schema2-summary
          'native_summary (or native-summary (hasheq))
          'priority_audit
          (hasheq 'snapshots prio-total
                  'active_escrow_snapshots prio-active-escrow
                  'step_ms_samples (length sorted-ms)
                  'avg_step_ms avg-ms
                  'p50_step_ms p50-ms
                  'p95_step_ms p95-ms
                  'max_step_ms max-ms
                  'top_saving_for (top-k-counts saving-for-counts 8)
                  'max_saving_streak_target max-streak-target
                  'max_saving_streak_snapshots max-streak-len
                  'top_escrow_queue (top-k-counts escrow-item-counts 6)
                  'top_blocked (top-k-counts blocked-item-counts 6))
          'action_errors (top-k-counts action-error-counts 10)
          'action_error_total (for/sum ([v (in-hash-values action-error-counts)]) v)
          'stderr_exception_count (length stderr-exceptions)
          'stderr_exception_samples (take (reverse stderr-exceptions)
                                          (min 10 (length stderr-exceptions)))))

;; -----------------------------------------------------------------------------
;; 4. Combined Replay + Match-Log Forensic Analyzer
;; -----------------------------------------------------------------------------

(define NON-ARMY-BORN-FILTER
  '("Drone" "SCV" "Probe"
    "Overlord" "SupplyDepot" "SupplyDepotLowered" "Pylon"
    "Larva" "Egg" "MULE" "CreepTumor" "CreepTumorBurrowed" "CreepTumorQueen"
    "Broodling" "Interceptor" "InvisibleTargetDummy"))

(define (invoke-s2protocol-sidecar-summary rep-path)
  (and rep-path
       (file-exists? rep-path)
       (file-exists? SIDECAR-BIN)
       (with-handlers ([exn:fail? (lambda (_e) #f)])
         (define rep-str (if (path? rep-path) (path->string rep-path) rep-path))
         (define err-out (open-output-string))
         (define json-str
           (parameterize ([current-error-port err-out])
             (with-output-to-string
               (lambda ()
                 (system* SIDECAR-BIN "--analyze" rep-str "--summary-only")))))
         (define trimmed (string-trim json-str))
         (and (not (string=? trimmed ""))
              (string-prefix? trimmed "{")
              (string->jsexpr trimmed)))))

(define (analyze-single-match-forensics #:match-id match-id-str
                                        #:replay-path [rep-path #f]
                                        #:log-zip-path [log-zip-path #f]
                                        #:meta [meta (hasheq)]
                                        #:with-sidecar? [with-sidecar? #f]
                                        #:quiet? [quiet? #f])
  (define log-info (parse-match-log-zip log-zip-path))
  (define prio (hash-ref log-info 'priority_audit (hasheq)))
  (define native-sum (hash-ref log-info 'native_summary (hasheq)))

  (define rep-data
    (and rep-path
         (file-exists? rep-path)
         (with-handlers ([exn:fail? (lambda (e)
                                      (eprintf "[WARN] Failed to parse replay ~a: ~a\n"
                                               rep-path (exn-message e))
                                      #f)])
           (parse-sc2-replay rep-path))))

  (cond
    [(not rep-data)
     ;; Match without .SC2Replay (Queued, In-Progress, or Crash/InitFailure)
     (define our-name (hash-ref meta 'our_bot_name "Mothman"))
     (define opp-name (hash-ref meta 'opp_bot_name "Opponent"))
     (define api-res (hash-ref meta 'result "unknown"))
     (define api-cause (hash-ref meta 'result_cause ""))
     (define api-type (hash-ref meta 'result_type ""))
     (define findings '())
     (when (member api-cause '("crash" "timeout" "initialization_failure" "error"))
       (set! findings (cons (format "MATCH_CRASH_OR_TIMEOUT: result=~a cause=~a type=~a"
                                    api-res api-cause api-type)
                            findings)))
     (when (> (hash-ref log-info 'stderr_exception_count 0) 0)
       (set! findings (cons (format "STDERR_EXCEPTIONS: ~a error/warning line(s) in stderr.log"
                                    (hash-ref log-info 'stderr_exception_count 0))
                            findings)))
     (when (string=? api-res "in_progress")
       (set! findings (cons "MATCH_IN_PROGRESS_OR_QUEUED: No replay uploaded yet." findings)))

     (unless quiet?
       (printf "==================================================================================================\n")
       (printf "MATCH #~a | Status: ~a (cause=~a, type=~a) | ~a vs ~a (NO REPLAY FILE)\n"
               match-id-str (string-upcase (format "~a" api-res)) api-cause api-type our-name opp-name)
       (when (> (hash-ref log-info 'stderr_exception_count 0) 0)
         (printf "  Stderr Exceptions (~a):\n" (hash-ref log-info 'stderr_exception_count 0))
         (for ([ln (in-list (hash-ref log-info 'stderr_exception_samples '()))])
           (printf "    ! ~a\n" ln)))
       (for ([f (in-list (reverse findings))])
         (printf "    - ~a\n" f)))

     (hasheq 'match_id match-id-str
             'has_replay #f
             'our_bot our-name
             'opp_bot opp-name
             'result api-res
             'result_cause api-cause
             'result_type api-type
             'log_forensics log-info
             'findings (reverse findings))]

    [else
     (define players (hash-ref rep-data 'players))
     (define p1 (hash-ref players 1))
     (define p2 (hash-ref players 2))
     (define p1-name (hash-ref p1 'name "Player1"))
     (define p2-name (hash-ref p2 'name "Player2"))

     (define meta-our-part (hash-ref meta 'our_participant_number 0))
     (define our-pid
       (cond
         [(memv meta-our-part '(1 2)) meta-our-part]
         [(string-contains? p1-name "Mothman") 1]
         [(string-contains? p2-name "Mothman") 2]
         [else 1]))
     (define opp-pid (if (= our-pid 1) 2 1))

     (define our-p (hash-ref players our-pid))
     (define opp-p (hash-ref players opp-pid))
     (define our-name
       (let ([mn (hash-ref meta 'our_bot_name "")])
         (if (and (string? mn) (not (string=? mn "")) (not (string=? mn "Mothman")))
             mn
             (hash-ref our-p 'name "Mothman"))))
     (define opp-name
       (let ([mn (hash-ref meta 'opp_bot_name "")])
         (if (and (string? mn) (not (string=? mn "")) (not (string=? mn "Opponent")))
             mn
             (hash-ref opp-p 'name "Opponent"))))

     (define our-decl-race (hash-ref our-p 'declared_race "Unknown"))
     (define our-actual-race (hash-ref our-p 'actual_race "Unknown"))
     (define opp-actual-race (hash-ref opp-p 'actual_race "Unknown"))

     (define api-res (hash-ref meta 'result ""))
     (define effective-result
       (if (and (string? api-res) (not (string=? api-res "")) (not (string=? api-res "in_progress")))
           (string-upcase api-res)
           (string-upcase (hash-ref our-p 'result "UNKNOWN"))))
     (define api-cause (hash-ref meta 'result_cause ""))
     (define api-type (hash-ref meta 'result_type ""))
     (define api-step-ms (hash-ref meta 'avg_step_time_ms 0.0))
     (define elo-delta (hash-ref meta 'elo_change 0))

     (define dur-sec (hash-ref rep-data 'duration_sec 0.0))
     (define game-loops (hash-ref rep-data 'game_loops 0))
     (define map-name (hash-ref rep-data 'map_name "Unknown"))

     (define our-th (hash-ref (hash-ref rep-data 'townhall_timings) our-pid '()))
     (define opp-th (hash-ref (hash-ref rep-data 'townhall_timings) opp-pid '()))
     (define our-morphs (hash-ref (hash-ref rep-data 'tech_morphs) our-pid '()))
     (define opp-morphs (hash-ref (hash-ref rep-data 'tech_morphs) opp-pid '()))
     (define our-upg (hash-ref (hash-ref rep-data 'upgrades) our-pid '()))
     (define opp-upg (hash-ref (hash-ref rep-data 'upgrades) opp-pid '()))

     (define our-stats (hash-ref (hash-ref rep-data 'stats_by_min) our-pid))
     (define opp-stats (hash-ref (hash-ref rep-data 'stats_by_min) opp-pid))
     (define our-deaths (hash-ref (hash-ref rep-data 'deaths_by_min) our-pid))
     (define opp-deaths (hash-ref (hash-ref rep-data 'deaths_by_min) opp-pid))

     (define max-our-workers
       (for/fold ([mx 0]) ([s (in-hash-values our-stats)])
         (max mx (hash-ref s 'workers 0))))
     (define max-opp-workers
       (for/fold ([mx 0]) ([s (in-hash-values opp-stats)])
         (max mx (hash-ref s 'workers 0))))
     (define max-our-min-below-max
       (for/fold ([mx 0]) ([s (in-hash-values our-stats)])
         (if (< (hash-ref s 'food_used 0) 185)
             (max mx (hash-ref s 'min_cur 0))
             mx)))
     (define max-our-gas
       (for/fold ([mx 0]) ([s (in-hash-values our-stats)])
         (max mx (hash-ref s 'gas_cur 0))))
     (define max-our-army
       (for/fold ([mx 0]) ([s (in-hash-values our-stats)])
         (max mx (+ (hash-ref s 'army_min 0) (hash-ref s 'army_gas 0)))))
     (define max-opp-army
       (for/fold ([mx 0]) ([s (in-hash-values opp-stats)])
         (max mx (+ (hash-ref s 'army_min 0) (hash-ref s 'army_gas 0)))))

     (define sb-our (hash-ref (hash-ref rep-data 'supply_blocked_steps) our-pid 0))
     (define tot-stat-our (max 1 (hash-ref (hash-ref rep-data 'total_stat_events) our-pid 1)))

     (define our-born-map (hash-ref (hash-ref rep-data 'born) our-pid))
     (define opp-born-map (hash-ref (hash-ref rep-data 'born) opp-pid))
     (define (filtered-born bm)
       (define h (make-hash))
       (for ([(u c) (in-hash bm)]
             #:when (and (not (member u NON-ARMY-BORN-FILTER))
                         (not (string-prefix? u "Beacon"))))
         (hash-set! h u c))
       (top-k-counts h 10))

     (define our-exp-count (length our-th))
     (define opp-exp-count (length opp-th))
     (define first-our-exp-sec (and (pair? our-th) (caar our-th)))

     ;; Automatic root-cause finding tags
     (define findings '())
     (define (add-finding! s) (set! findings (cons s findings)))

     (when (member api-cause '("crash" "timeout" "initialization_failure" "error"))
       (add-finding! (format "MATCH_CRASH_OR_TIMEOUT: cause=~a type=~a" api-cause api-type)))
     (when (> (hash-ref log-info 'stderr_exception_count 0) 0)
       (add-finding! (format "STDERR_EXCEPTIONS: ~a runtime warning/exception line(s) in stderr.log."
                             (hash-ref log-info 'stderr_exception_count 0))))
     (when (> (hash-ref log-info 'action_error_total 0) 0)
       (add-finding! (format "ACTION_RESULT_ERRORS: ~a failed command(s): ~s"
                             (hash-ref log-info 'action_error_total 0)
                             (hash-ref log-info 'action_errors '()))))

     (define max-step-ms
       (max (hash-ref prio 'max_step_ms 0.0)
            (hash-ref native-sum 'max_step_ms 0.0)))
     (define p95-step-ms
       (max (hash-ref prio 'p95_step_ms 0.0)
            (hash-ref native-sum 'p95_step_ms 0.0)))
     (when (or (>= max-step-ms 40.0) (>= p95-step-ms 20.0))
       (add-finding! (format "HIGH_STEP_LATENCY: p95=~ams max=~ams." p95-step-ms max-step-ms)))

     (define max-escrow-age (hash-ref native-sum 'max_escrow_age_frames 0))
     (define max-streak-snaps (hash-ref prio 'max_saving_streak_snapshots 0))
     (define max-streak-tgt (hash-ref prio 'max_saving_streak_target "none"))
     (when (or (>= max-escrow-age 1500) (>= max-streak-snaps 25))
       (add-finding! (format "ESCROW_STALL: max_escrow_age_frames=~a max_saving_streak=~a (~a)."
                             max-escrow-age max-streak-snaps max-streak-tgt)))

     (cond
       [(and (= our-exp-count 0) (> dur-sec 150.0))
        (add-finding! "CRITICAL_ZERO_EXPANSIONS: Built 0 additional TownHalls in a >150s match.")]
       [(and first-our-exp-sec (> first-our-exp-sec 180.0))
        (add-finding! (format "DELAYED_NATURAL_EXPANSION: First expansion initiated at ~as (>180s)."
                              first-our-exp-sec))])
     (when (>= opp-exp-count (+ our-exp-count 2))
       (add-finding! (format "MACRO_BASE_DEFICIT: ~a total bases vs opponent ~a bases."
                             (add1 our-exp-count) (add1 opp-exp-count))))
     (when (>= max-opp-workers (+ max-our-workers 15))
       (add-finding! (format "WORKER_DEFICIT: Peak ~a workers vs opponent ~a workers."
                             max-our-workers max-opp-workers)))
     (when (>= max-our-min-below-max 1000)
       (add-finding! (format "UNSPENT_MINERAL_FLOAT: Floated ~a minerals below max supply."
                             max-our-min-below-max)))
     (when (>= max-our-gas 400)
       (add-finding! (format "UNSPENT_GAS_FLOAT: Floated up to ~a Vespene without sufficient gas spending."
                             max-our-gas)))
     (when (and (null? our-upg) (> dur-sec 240.0))
       (add-finding! "ZERO_UPGRADES_COMPLETED: Completed 0 upgrades in a >4 min match."))
     (when (or (>= sb-our 3) (>= (/ sb-our (exact->inexact tot-stat-our)) 0.25))
       (add-finding! (format "SUPPLY_BLOCKED: Supply-blocked on ~a/~a tracker stat snapshots."
                             sb-our tot-stat-our)))

     (define our-incomplete (hash-ref (hash-ref rep-data 'incomplete_structures (hasheqv)) our-pid '()))
     (define opp-incomplete (hash-ref (hash-ref rep-data 'incomplete_structures (hasheqv)) opp-pid '()))
     (define our-proxies (hash-ref (hash-ref rep-data 'proxy_structures (hasheqv)) our-pid '()))
     (define opp-proxies (hash-ref (hash-ref rep-data 'proxy_structures (hasheqv)) opp-pid '()))
     (define our-bases-lost (hash-ref (hash-ref rep-data 'bases_lost (hasheqv)) our-pid '()))
     (define opp-bases-lost (hash-ref (hash-ref rep-data 'bases_lost (hasheqv)) opp-pid '()))
     (define our-killed-by
       (top-k-counts (hash-ref (hash-ref rep-data 'killed_by (hasheqv)) our-pid (hasheq)) 8))
     (define opp-killed-by
       (top-k-counts (hash-ref (hash-ref rep-data 'killed_by (hasheqv)) opp-pid (hasheq)) 8))
     (define our-creep
       (hash-ref (hash-ref rep-data 'creep_tumors (hasheqv)) our-pid (hasheq 'placed 0 'cleared 0)))
     (define engagements (hash-ref rep-data 'engagements '()))
     (define win-chance-curve (hash-ref rep-data 'win_chance_curve '()))
     (define turning-points (hash-ref rep-data 'turning_points '()))

     (define sidecar-bundle
       (and with-sidecar? (invoke-s2protocol-sidecar-summary rep-path)))
     (define our-sidecar
       (and (hash? sidecar-bundle)
            (for/first ([pl (in-list (hash-ref sidecar-bundle 'players '()))]
                        #:when (and (hash? pl) (= (hash-ref pl 'pid 0) our-pid)))
              pl)))
     (define opp-sidecar
       (and (hash? sidecar-bundle)
            (for/first ([pl (in-list (hash-ref sidecar-bundle 'players '()))]
                        #:when (and (hash? pl) (= (hash-ref pl 'pid 0) opp-pid)))
              pl)))

     (when (pair? our-incomplete)
       (add-finding! (format "INCOMPLETE_STRUCTURES: Initiated > completed structures (canceled/sniped/unfinished): ~s"
                             our-incomplete)))
     (when (pair? opp-proxies)
       (add-finding! (format "ENEMY_PROXY_DETECTED: Early enemy proxy structure(s) >50 tiles from enemy main: ~s"
                             opp-proxies)))
     (when (pair? our-bases-lost)
       (add-finding! (format "BASES_LOST: TownHall(s) destroyed: ~s" our-bases-lost)))

     (when (hash? our-sidecar)
       (for ([row (in-list (hash-ref our-sidecar 'wire_actuation_audit '()))]
             #:when (and (hash? row)
                         (string=? (format "~a" (hash-ref row 'status "OK")) "WIRE_DROPPED")))
         (add-finding! (format "WIRE_BUILD_DROPPED: Issued ~ax Build.~a on wire with 0 SUnitInit!"
                               (hash-ref row 'wire_build_cmds 0)
                               (hash-ref row 'structure "?"))))
       (when (>= (hash-ref our-sidecar 'worker_thrash_events 0) 5)
         (add-finding! (format "WORKER_BUILD_THRASH: ~a rapid duplicate/conflicting build commands on wire."
                               (hash-ref our-sidecar 'worker_thrash_events 0))))
       (define bad-decs (hash-ref our-sidecar 'bad_decisions '()))
       (when (pair? bad-decs)
         (define bd0 (car bad-decs))
         (add-finding! (format "COUNTER_UNIT_MISMATCH: ~a unfavorable unit choice(s) vs enemy army (first: ~a @ ~as, score=~a, weak_vs=~a)."
                               (length bad-decs)
                               (hash-ref bd0 'unit "?")
                               (hash-ref bd0 'sec 0)
                               (round2 (hash-ref bd0 'score 0.0))
                               (hash-ref bd0 'weak_vs "")))))

     (define final-findings (reverse findings))

     (unless quiet?
       (printf "==================================================================================================\n")
       (printf "MATCH #~a | ~a (cause=~a, elo=~a) | Map: ~a | Dur: ~as (~a loops) | API step=~ams\n"
               match-id-str
               effective-result
               (if (string=? api-cause "") "replay" api-cause)
               elo-delta
               map-name
               dur-sec
               game-loops
               api-step-ms)
       (printf "  Players: P~a ~a (~a) vs P~a ~a (~a)\n"
               our-pid
               our-name
               (if (or (string=? our-name "Mothman-X") (not (string=? our-decl-race our-actual-race)))
                   (format "Random->~a" our-actual-race)
                   our-actual-race)
               opp-pid
               opp-name
               opp-actual-race)
       (printf "  Expansions (>0s): Us=~s | Morphs=~s || Opp=~s | OppMorphs=~s\n"
               our-th our-morphs opp-th opp-morphs)
       (printf "  Upgrades:         Us=~s || Opp=~s\n" our-upg opp-upg)
       (printf "  Units/Bldgs Born: Us=~s || Opp=~s\n"
               (filtered-born our-born-map)
               (filtered-born opp-born-map))
       (printf "  Peak Economy:     Workers=~a vs ~a | PeakArmyVal=~a vs ~a | MaxFloat=~aM/~aG | SupplyBlocked=~a/~a\n"
               max-our-workers max-opp-workers max-our-army max-opp-army
               max-our-min-below-max max-our-gas sb-our tot-stat-our)
       (printf "  Swarmy Tracker:   Incomplete=~s | OppProxies=~s | BasesLost=~s | KilledBy=~s | Battles=~a | Swings=~a\n"
               our-incomplete opp-proxies our-bases-lost our-killed-by
               (length engagements) (length turning-points))
       (when (hash? our-sidecar)
         (printf "  s2protocol-rs:    Us CPM=~a (macro=~a, spam=~a%, thrash=~a) vs Opp CPM=~a (macro=~a, spam=~a%) | Choices(good=~a even=~a bad=~a)\n"
                 (hash-ref our-sidecar 'raw_cpm 0.0)
                 (hash-ref our-sidecar 'macro_cpm 0.0)
                 (hash-ref our-sidecar 'move_attack_spam_pct 0.0)
                 (hash-ref our-sidecar 'worker_thrash_events 0)
                 (if (hash? opp-sidecar) (hash-ref opp-sidecar 'raw_cpm 0.0) 0.0)
                 (if (hash? opp-sidecar) (hash-ref opp-sidecar 'macro_cpm 0.0) 0.0)
                 (if (hash? opp-sidecar) (hash-ref opp-sidecar 'move_attack_spam_pct 0.0) 0.0)
                 (hash-ref our-sidecar 'good_decisions 0)
                 (hash-ref our-sidecar 'even_decisions 0)
                 (length (hash-ref our-sidecar 'bad_decisions '())))
         (define wire-rows (hash-ref our-sidecar 'wire_actuation_audit '()))
         (when (pair? wire-rows)
           (printf "    wire_audit:     ~s\n"
                   (for/list ([r (in-list wire-rows)])
                     (format "~a(wire=~a,init=~a,done=~a,~a)"
                             (hash-ref r 'structure "?")
                             (hash-ref r 'wire_build_cmds 0)
                             (hash-ref r 'unit_init_count 0)
                             (hash-ref r 'unit_done_count 0)
                             (hash-ref r 'status "?")))))
         (define lessons (hash-ref our-sidecar 'lessons '()))
         (when (pair? lessons)
           (printf "    costed_lessons: ~s\n"
                   (for/list ([ls (in-list (take lessons (min 4 (length lessons))))])
                     (format "~a (~aM): ~a"
                             (hash-ref ls 'title "?")
                             (hash-ref ls 'mineral_equiv_cost 0)
                             (hash-ref ls 'detail ""))))))
       (when (hash-ref log-info 'log_exists #f)
         (printf "  Match-Log Audit:  prio_snaps=~a active_escrow=~a | step_ms(avg=~a p50=~a p95=~a max=~a) | action_errs=~a stderr_exns=~a\n"
                 (hash-ref prio 'snapshots 0)
                 (hash-ref prio 'active_escrow_snapshots 0)
                 (hash-ref prio 'avg_step_ms 0.0)
                 (hash-ref prio 'p50_step_ms 0.0)
                 (hash-ref prio 'p95_step_ms 0.0)
                 (hash-ref prio 'max_step_ms 0.0)
                 (hash-ref log-info 'action_error_total 0)
                 (hash-ref log-info 'stderr_exception_count 0))
         (when (pair? (hash-ref prio 'top_saving_for '()))
           (printf "    saving_for top: ~s (max_streak=~a on ~a) | blocked top: ~s\n"
                   (hash-ref prio 'top_saving_for '())
                   max-streak-snaps
                   max-streak-tgt
                   (hash-ref prio 'top_blocked '())))
         (when (not (hash-empty? native-sum))
           (printf "    native_summary: posture=~a cmds=~a scout=~a harass=~a first_seen_loop=~a max_escrow_age=~a\n"
                   (hash-ref native-sum 'final_posture "?")
                   (hash-ref native-sum 'commands_sent 0)
                   (hash-ref native-sum 'scout_commands_emitted 0)
                   (hash-ref native-sum 'harass_commands_emitted 0)
                   (hash-ref native-sum 'enemy_first_seen_loop -1)
                   (hash-ref native-sum 'max_escrow_age_frames 0)))
         (when (pair? (hash-ref log-info 'action_errors '()))
           (printf "    action_errors:  ~s\n" (hash-ref log-info 'action_errors '())))
         (when (pair? (hash-ref log-info 'stderr_exception_samples '()))
           (printf "    stderr_samples:\n")
           (for ([ln (in-list (hash-ref log-info 'stderr_exception_samples '()))])
             (printf "      ! ~a\n" ln))))
       (printf "  Forensic Findings (~a):\n" (length final-findings))
       (if (null? final-findings)
           (printf "    - CLEAN_EXECUTION: No macro/latency/error anomalies flagged.\n")
           (for ([f (in-list final-findings)])
             (printf "    - ~a\n" f)))
       (printf "  Minute-by-Minute Telemetry:\n")
       (define all-mins
         (sort (remove-duplicates (append (hash-keys our-stats) (hash-keys opp-stats))) <))
       (for ([m (in-list all-mins)])
         (define s1 (hash-ref our-stats m (hasheq)))
         (define s2 (hash-ref opp-stats m (hasheq)))
         (define d1
           (for/list ([(k c) (in-hash our-deaths)]
                      #:when (= (car k) m))
             (format "~a:~a" (cdr k) c)))
         (printf "    Min ~a | Us: W=~a Sup=~a/~a Bank=~aM/~aG Rate=~aM/~aG Army=~a Lost=~a || Opp: W=~a Sup=~a/~a Rate=~aM Army=~a Lost=~a~a\n"
                 (~r m #:min-width 2)
                 (~r (hash-ref s1 'workers 0) #:min-width 2)
                 (~r (hash-ref s1 'food_used 0) #:min-width 3)
                 (~r (hash-ref s1 'food_made 0) #:min-width 3)
                 (~r (hash-ref s1 'min_cur 0) #:min-width 4)
                 (~r (hash-ref s1 'gas_cur 0) #:min-width 4)
                 (~r (hash-ref s1 'min_rate 0) #:min-width 4)
                 (~r (hash-ref s1 'gas_rate 0) #:min-width 3)
                 (~r (+ (hash-ref s1 'army_min 0) (hash-ref s1 'army_gas 0)) #:min-width 5)
                 (~r (+ (hash-ref s1 'lost_min 0) (hash-ref s1 'lost_gas 0)) #:min-width 5)
                 (~r (hash-ref s2 'workers 0) #:min-width 2)
                 (~r (hash-ref s2 'food_used 0) #:min-width 3)
                 (~r (hash-ref s2 'food_made 0) #:min-width 3)
                 (~r (hash-ref s2 'min_rate 0) #:min-width 4)
                 (~r (+ (hash-ref s2 'army_min 0) (hash-ref s2 'army_gas 0)) #:min-width 5)
                 (~r (+ (hash-ref s2 'lost_min 0) (hash-ref s2 'lost_gas 0)) #:min-width 5)
                 (if (null? d1) "" (format " | OurDeaths=(~a)" (string-join (sort d1 string<?) " "))))))

     (hasheq 'match_id match-id-str
             'has_replay #t
             'map map-name
             'duration_sec dur-sec
             'game_loops game-loops
             'result effective-result
             'result_cause api-cause
             'result_type api-type
             'elo_change elo-delta
             'api_avg_step_ms api-step-ms
             'our_bot our-name
             'opp_bot opp-name
             'our_declared_race our-decl-race
             'our_race our-actual-race
             'opp_race opp-actual-race
             'our_expansions our-th
             'opp_expansions opp-th
             'our_tech_morphs our-morphs
             'opp_tech_morphs opp-morphs
             'our_upgrades our-upg
             'opp_upgrades opp-upg
             'our_units_born (filtered-born our-born-map)
             'opp_units_born (filtered-born opp-born-map)
             'our_incomplete_structures our-incomplete
             'opp_incomplete_structures opp-incomplete
             'our_proxy_structures our-proxies
             'opp_proxy_structures opp-proxies
             'our_bases_lost our-bases-lost
             'opp_bases_lost opp-bases-lost
             'our_killed_by our-killed-by
             'opp_killed_by opp-killed-by
             'our_creep_tumors our-creep
             'engagements engagements
             'win_chance_curve win-chance-curve
             'turning_points turning-points
             'sidecar_summary (or sidecar-bundle (hasheq))
             'max_our_workers max-our-workers
             'max_opp_workers max-opp-workers
             'max_our_minerals_float max-our-min-below-max
             'max_our_gas max-our-gas
             'max_our_army_value max-our-army
             'max_opp_army_value max-opp-army
             'supply_blocked_snapshots sb-our
             'tags (hash-ref log-info 'tags '())
             'schema2_summary (hash-ref log-info 'schema2_summary (hasheq))
             'native_summary native-sum
             'priority_audit prio
             'action_errors (hash-ref log-info 'action_errors '())
             'stderr_exceptions (hash-ref log-info 'stderr_exception_samples '())
             'findings final-findings)]))

;; -----------------------------------------------------------------------------
;; 5. Batch Directory / Match-Set Orchestrator (`run-aiarena-forensic-analysis!`)
;; -----------------------------------------------------------------------------

(define (extract-leading-match-id filename)
  (define m (regexp-match #rx"^([0-9]+)_" filename))
  (and m (string->number (cadr m))))

(define (run-aiarena-forensic-analysis! #:dir [dir-in DEFAULT-CACHE-DIR]
                                        #:fetch? [fetch? #f]
                                        #:match-ids [explicit-match-ids '()]
                                        #:since-match [since-match #f]
                                        #:bot-ids [bot-ids #f]
                                        #:limit [limit #f]
                                        #:json-out [json-out #f]
                                        #:token [token DEFAULT-TOKEN]
                                        #:with-sidecar? [with-sidecar? #f]
                                        #:quiet? [quiet? #f])
  (define out-dir (if (path? dir-in) dir-in (string->path dir-in)))
  (make-directory* out-dir)
  (define active-bots (or bot-ids '(1458 1459 1460 1461)))
  (define bot-filter-active? (and bot-ids #t))

  (when fetch?
    (fetch-aiarena-matches! out-dir
                            #:token token
                            #:bot-ids active-bots
                            #:match-ids explicit-match-ids
                            #:since-match since-match
                            #:limit (or limit 25)))

  ;; Index local replays and metadata in `out-dir`
  (define replay-by-id (make-hash))
  (define standalone-replays '())
  (define meta-by-id (make-hash))

  (for ([p (in-list (sort (directory-list out-dir #:build? #t)
                          (lambda (a b) (string<? (path->string a) (path->string b)))))])
    (define fn (path->string (file-name-from-path p)))
    (cond
      [(string-suffix? fn "_meta.json")
       (define mid (extract-leading-match-id fn))
       (when mid
         (with-handlers ([exn:fail? void])
           (hash-set! meta-by-id mid (call-with-input-file p read-json))))]
      [(string-suffix? fn ".SC2Replay")
       (define mid (extract-leading-match-id fn))
       (if mid
           (hash-set! replay-by-id mid p)
           (set! standalone-replays (cons p standalone-replays)))]))

  ;; Candidate numeric match IDs
  (define all-mids
    (sort (remove-duplicates (append (hash-keys replay-by-id) (hash-keys meta-by-id))) <))

  (define filtered-mids-1
    (cond
      [(pair? explicit-match-ids)
       (define want (list->seteqv explicit-match-ids))
       (filter (lambda (m) (set-member? want m)) all-mids)]
      [since-match
       (filter (lambda (m) (>= m since-match)) all-mids)]
      [else all-mids]))

  (define filtered-mids-2
    (if (not bot-filter-active?)
        filtered-mids-1
        (let ([want-bots (list->seteqv active-bots)]
              [want-names (for/list ([b (in-list active-bots)]
                                     #:when (hash-has-key? BOT-IDS b))
                            (hash-ref BOT-IDS b))])
          (filter
           (lambda (mid)
             (define m (hash-ref meta-by-id mid #f))
             (define rp (hash-ref replay-by-id mid #f))
             (cond
               [(and m (> (hash-ref m 'our_bot_id 0) 0))
                (set-member? want-bots (hash-ref m 'our_bot_id 0))]
               [rp
                (define fn (path->string (file-name-from-path rp)))
                (ormap (lambda (bn) (string-contains? fn bn)) want-names)]
               [else #t]))
           filtered-mids-1))))

  (define final-mids
    (if (and limit (> limit 0) (> (length filtered-mids-2) limit))
        (take-right filtered-mids-2 limit)
        filtered-mids-2))

  (define reports
    (append
     (for/list ([mid (in-list final-mids)])
       (define mid-str (number->string mid))
       (define rp (hash-ref replay-by-id mid #f))
       (define lp (build-path out-dir (format "~a_match_log.zip" mid)))
       (define meta (hash-ref meta-by-id mid (hasheq)))
       (analyze-single-match-forensics #:match-id mid-str
                                       #:replay-path rp
                                       #:log-zip-path (and (file-exists? lp) lp)
                                       #:meta meta
                                       #:with-sidecar? with-sidecar?
                                       #:quiet? quiet?))
     (if (and (null? explicit-match-ids) (not since-match))
         (for/list ([rp (in-list (reverse standalone-replays))])
           (define fn (path->string (file-name-from-path rp)))
           (analyze-single-match-forensics #:match-id fn
                                           #:replay-path rp
                                           #:with-sidecar? with-sidecar?
                                           #:quiet? quiet?))
         '())))

  ;; Aggregate Win/Loss/Finding Rollup
  (define wins 0)
  (define losses 0)
  (define ties 0)
  (define other 0)
  (define finding-freq (make-hash))
  (define by-bot (make-hash))

  (for ([r (in-list reports)])
    (define res (string-upcase (format "~a" (hash-ref r 'result "UNKNOWN"))))
    (define bname (hash-ref r 'our_bot "Mothman"))
    (define brec (hash-ref! by-bot bname (lambda () (make-hasheq '((w . 0) (l . 0) (t . 0) (o . 0))))))
    (cond
      [(string=? res "WIN")  (set! wins (add1 wins))   (hash-update! brec 'w add1 0)]
      [(string=? res "LOSS") (set! losses (add1 losses)) (hash-update! brec 'l add1 0)]
      [(string=? res "TIE")  (set! ties (add1 ties))   (hash-update! brec 't add1 0)]
      [else                  (set! other (add1 other)) (hash-update! brec 'o add1 0)])
    (for ([f (in-list (hash-ref r 'findings '()))])
      (define tag (car (string-split f ":")))
      (hash-update! finding-freq tag add1 0)))

  (define out-json-path
    (cond
      [(path? json-out) json-out]
      [(string? json-out) (string->path json-out)]
      [else (build-path out-dir "forensic_summary.json")]))

  (make-directory* (or (path-only out-json-path) out-dir))
  (call-with-output-file out-json-path #:exists 'replace
    (lambda (out) (write-json reports out)))

  (unless quiet?
    (printf "\n==================================================================================================\n")
    (printf "FORENSIC ROLLUP (~a matches) | Record: ~aW - ~aL - ~aT (~a pending/other)\n"
            (length reports) wins losses ties other)
    (for ([bname (in-list (sort (hash-keys by-bot) string<?))])
      (define br (hash-ref by-bot bname))
      (printf "  * ~a: ~aW - ~aL - ~aT~a\n"
              bname
              (hash-ref br 'w 0)
              (hash-ref br 'l 0)
              (hash-ref br 't 0)
              (if (> (hash-ref br 'o 0) 0) (format " (~a pending)" (hash-ref br 'o 0)) "")))
    (when (> (hash-count finding-freq) 0)
      (printf "  Top Root-Cause Finding Frequencies: ~s\n" (top-k-counts finding-freq 12)))
    (printf "[OK] Wrote ~a forensic match report(s) to ~a\n"
            (length reports)
            (path->string out-json-path)))

  reports)

;; -----------------------------------------------------------------------------
;; 6. CLI Entrypoint (`racket tools/analyze-aiarena-replays.rkt ...`)
;; -----------------------------------------------------------------------------

(module+ main
  (define do-fetch? #f)
  (define use-sidecar? #f)
  (define match-ids-str #f)
  (define since-match-num #f)
  (define bots-filter-str #f)
  (define limit-num #f)
  (define cache-dir-str (path->string DEFAULT-CACHE-DIR))
  (define json-out-str #f)

  (command-line
   #:program "analyze-aiarena-replays.rkt"
   #:once-each
   [("--fetch") "Download replays, match_log.zip, and API metadata from AI Arena"
                (set! do-fetch? #t)]
   [("--with-sidecar") "Enrich replay forensics via Rust crates/s2protocol-sidecar (GameEvents + BalanceData)"
                       (set! use-sidecar? #t)]
   [("--match-ids") ids "Comma-separated match IDs (e.g. 5117325,5117326)"
                    (set! match-ids-str ids)]
   [("--since-match") sm "Analyze matches with numeric ID >= <ID> (e.g. 5115348)"
                      (set! since-match-num (string->number sm))]
   [("--bots" "--bot") bf "Comma-separated bot filter: Z,T,P,X,R or bot IDs"
                       (set! bots-filter-str bf)]
   [("--limit") lim "Max recent matches to fetch/analyze"
                (set! limit-num (string->number lim))]
   [("--dir") d "Cache directory for replays and match logs (default: replays/aiarena_live_cache)"
              (set! cache-dir-str d)]
   [("--json-out") jo "Output JSON path (default: <dir>/forensic_summary.json)"
                   (set! json-out-str jo)])

  (void
   (run-aiarena-forensic-analysis!
    #:dir cache-dir-str
    #:fetch? do-fetch?
    #:match-ids (parse-match-ids-str match-ids-str)
    #:since-match since-match-num
    #:bot-ids (and bots-filter-str (parse-bot-filter bots-filter-str))
    #:limit limit-num
    #:json-out json-out-str
    #:with-sidecar? use-sidecar?)))
