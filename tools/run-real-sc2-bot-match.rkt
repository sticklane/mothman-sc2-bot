#lang racket

;; =============================================================================
;; Pure-Racket 2-Player Headless SC2_x64 Real Bot Match Harness & Auditor
;; (`tools/run-real-sc2-bot-match.rkt`)
;;
;; Launches two real headless Blizzard `SC2_x64` (v4.10 / Base75689) servers,
;; connects Player 1 (`sim/racket-sc2-ladder-main.rkt` running Mothman-Z/T/P/X)
;; and Player 2 (real downloaded AI Arena ladder bot in `downloaded_bots/`),
;; saves the `.SC2Replay` file and `[SCBOT_PRIORITY]` trace, and audits:
;;   1. Unexpected exits / crashes / WebSocket errors
;;   2. Escrow liveness & zero deadlock (`max_escrow_age_frames`, `saving_for` transitions)
;;   3. Opening & periodic scouting (`scout_commands_emitted`) + mineral-patch
;;      harassment (`harass_commands_emitted`) + opponent contact (`enemy_first_seen_loop`)
;;   4. Per-turn latency (`avg_step_ms`, `p95_step_ms`, `max_step_ms`)
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
         racket/string
         racket/system
         racket/tcp
         json)

(provide OPPONENT-SPECS
         run-real-sc2-bot-match)

(define-runtime-path TOOLS-DIR ".")
(define REPO-ROOT (simplify-path (build-path TOOLS-DIR "..")))
(define SC2-ROOT
  (or (getenv "SC2PATH")
      (and (directory-exists? "/home/antigravity/sc2_local/StarCraftII/SC2Data")
           "/home/antigravity/sc2_local/StarCraftII")
      "/home/antigravity/sc2_headless/StarCraftII"))
(define SC2-BIN
  (build-path SC2-ROOT "Versions" "Base75689" "SC2_x64"))
(define SC2-SUPPORT64
  (build-path SC2-ROOT "Support64"))
(define SC2-CWD
  (if (directory-exists? SC2-SUPPORT64) SC2-SUPPORT64 SC2-ROOT))
(define DOWNLOADED-BOTS-DIR
  (build-path REPO-ROOT "downloaded_bots"))
(define REPLAY-OUT-DIR
  (build-path REPO-ROOT "replays" "local_real_matches"))
(define RACKET-BIN
  (cond
    [(file-exists? "/home/antigravity/toolchains/racket_full/bin/racket")
     "/home/antigravity/toolchains/racket_full/bin/racket"]
    [(file-exists? "/home/antigravity/toolchains/racket/bin/racket")
     "/home/antigravity/toolchains/racket/bin/racket"]
    [else
     (path->string (or (find-executable-path "racket") (build-path "/usr/bin/racket")))]))

(define MAX-CONCURRENT-SC2-MATCHES
  (or (and (getenv "SC2_MAX_CONCURRENT_MATCHES")
           (string->number (getenv "SC2_MAX_CONCURRENT_MATCHES")))
      1))

;; Downloaded AI Arena & Pure-Racket Opponent Specifications
(define OPPONENT-SPECS
  (hash "Creepy12ProbeRush"
        (hash 'race "Protoss"
              'type 'racket
              'dir REPO-ROOT
              'exec "Creepy12ProbeRush")
        "Mothman-Z"
        (hash 'race "Zerg"
              'type 'racket
              'dir REPO-ROOT
              'exec "Mothman-Z")
        "Mothman-T"
        (hash 'race "Terran"
              'type 'racket
              'dir REPO-ROOT
              'exec "Mothman-T")
        "Mothman-P"
        (hash 'race "Protoss"
              'type 'racket
              'dir REPO-ROOT
              'exec "Mothman-P")
        "who"
        (hash 'race "Random"
              'type 'python
              'dir (build-path DOWNLOADED-BOTS-DIR "who")
              'exec "run.py")
        "Creepy_strategies"
        (hash 'race "Protoss"
              'type 'python
              'dir (build-path DOWNLOADED-BOTS-DIR "Creepy_strategies")
              'exec "run.py")
        "Mulebot"
        (hash 'race "Terran"
              'type 'python
              'dir (build-path DOWNLOADED-BOTS-DIR "Mulebot")
              'exec "run.py")
        "Thssprtssbt"
        (hash 'race "Protoss"
              'type 'python
              'dir (build-path DOWNLOADED-BOTS-DIR "Thssprtssbt")
              'exec "run.py")
        "mini-puck"
        (hash 'race "Protoss"
              'type 'cpplinux
              'dir (build-path DOWNLOADED-BOTS-DIR "mini-puck")
              'exec (path->string (build-path DOWNLOADED-BOTS-DIR "mini-puck" "mini-puck")))
        "sludgement2-revived"
        (hash 'race "Zerg"
              'type 'cpplinux
              'dir (build-path DOWNLOADED-BOTS-DIR "sludgement2-revived")
              'exec (path->string (build-path DOWNLOADED-BOTS-DIR "sludgement2-revived" "sludgement2-revived")))
        "onlyfans"
        (hash 'race "Terran"
              'type 'cpplinux
              'dir (build-path DOWNLOADED-BOTS-DIR "onlyfans")
              'exec (path->string (build-path DOWNLOADED-BOTS-DIR "onlyfans" "onlyfans")))
        "oberon"
        (hash 'race "Terran"
              'type 'cpplinux
              'dir (build-path DOWNLOADED-BOTS-DIR "oberon")
              'exec (path->string (build-path DOWNLOADED-BOTS-DIR "oberon" "oberon")))
        "titania"
        (hash 'race "Zerg"
              'type 'cpplinux
              'dir (build-path DOWNLOADED-BOTS-DIR "titania")
              'exec (path->string (build-path DOWNLOADED-BOTS-DIR "titania" "titania")))))

(define (pick-port-block)
  (define base (+ 18000 (random 8000)))
  (values base (+ base 1) (+ base 10)))

(define (wait-for-tcp-port host port [timeout-sec 25.0])
  (define deadline (+ (current-inexact-milliseconds) (* 1000.0 timeout-sec)))
  (let loop ()
    (cond
      [(> (current-inexact-milliseconds) deadline) #f]
      [else
       (define ok?
         (with-handlers ([exn:fail? (lambda (_e) #f)])
           (define-values (in out) (tcp-connect host port))
           (close-input-port in)
           (close-output-port out)
           #t))
       (if ok?
           #t
           (begin
             (sleep 0.2)
             (loop)))])))

(define (kill-subprocess-safe! sp)
  (when (and sp (subprocess? sp))
    (with-handlers ([exn:fail? void])
      (when (eq? (subprocess-status sp) 'running)
        (subprocess-kill sp #f)
        (sleep 0.2)
        (when (eq? (subprocess-status sp) 'running)
          (subprocess-kill sp #t))))))

;; Acquire one of `MAX-CONCURRENT-SC2-MATCHES` slots using Racket's `call-with-file-lock/timeout`
(define (call-with-sc2-slot thunk [max-slots MAX-CONCURRENT-SC2-MATCHES])
  (make-directory* REPLAY-OUT-DIR)
  (let loop ([waited? #f])
    (define acquired-slot #f)
    (define result #f)
    (for ([slot-idx (in-range max-slots)]
          #:break acquired-slot)
      (define lock-file (build-path REPLAY-OUT-DIR (format ".sc2_racket_slot_~a.lock" slot-idx)))
      (call-with-file-lock/timeout
       #f
       'exclusive
       (lambda ()
         (set! acquired-slot slot-idx)
         (set! result (thunk slot-idx)))
       (lambda () (void))
       #:lock-file lock-file
       #:max-delay 0.05))
    (if acquired-slot
        result
        (begin
          (unless waited?
            (printf "[SC2-SLOT] Waiting for one of ~a concurrent SC2 match slots...\n" max-slots)
            (flush-output))
          (sleep 1.5)
          (loop #t)))))

;; Audit `[SCBOT_PRIORITY]` log lines in pure Racket
(define (audit-priority-logs our-stderr-str priority-log-path)
  (define all-lines (string-split our-stderr-str "\n"))
  (define prio-lines
    (filter (lambda (ln) (string-contains? ln "[SCBOT_PRIORITY]"))
            (map string-trim all-lines)))
  (when (pair? prio-lines)
    (display-lines-to-file prio-lines priority-log-path #:exists 'replace))

  (define saving-counts (make-hash))
  (define escrow-active-lines '())
  (define max-consecutive-same-saving 0)
  (define cur-consecutive-saving 0)
  (define prev-saving-target #f)

  (for ([ln (in-list prio-lines)])
    (define m (regexp-match #rx"saving_for=([^ (]+)" ln))
    (define target (if m (second m) "none"))
    (hash-update! saving-counts target add1 0)
    (if (and (not (string=? target "none"))
             (equal? target prev-saving-target))
        (set! cur-consecutive-saving (add1 cur-consecutive-saving))
        (begin
          (set! prev-saving-target target)
          (set! cur-consecutive-saving (if (string=? target "none") 0 1))))
    (set! max-consecutive-same-saving (max max-consecutive-same-saving cur-consecutive-saving))
    (unless (string-contains? ln "escrow_queue=()")
      (set! escrow-active-lines (cons ln escrow-active-lines))))
  (set! escrow-active-lines (reverse escrow-active-lines))

  (printf "[PRIORITY-AUDIT] Logged ~a priority snapshots (~a with active escrow, max_consecutive_saving=~a) -> ~a\n"
          (length prio-lines)
          (length escrow-active-lines)
          max-consecutive-same-saving
          priority-log-path)
  (when (> (hash-count saving-counts) 0)
    (printf "  saving_for distribution: ~v\n" (hash->list saving-counts)))
  (define sample-lines
    (take (if (pair? escrow-active-lines) escrow-active-lines prio-lines)
          (min 6 (length (if (pair? escrow-active-lines) escrow-active-lines prio-lines)))))
  (for ([sln (in-list sample-lines)])
    (printf "  ~a\n" sln))
  (flush-output)

  (hasheq 'total_snapshots (length prio-lines)
          'active_escrow_snapshots (length escrow-active-lines)
          'max_consecutive_same_saving max-consecutive-same-saving
          'saving_for_counts (for/hasheq ([(k v) (in-hash saving-counts)])
                               (values (string->symbol k) v))
          'priority_log_path (if (pair? prio-lines) (path->string priority-log-path) "")))

(define (run-real-sc2-bot-match #:our-bot [our-bot "Mothman-Z"]
                                #:opponent [opponent "sludgement2-revived"]
                                #:map-name [map-name "AcropolisLE"]
                                #:max-loops [max-loops 6720]
                                #:step-size [step-size 4]
                                #:timeout-sec [timeout-sec 300])
  (unless (hash-has-key? OPPONENT-SPECS opponent)
    (error 'run-real-sc2-bot-match
           "Unknown opponent ~a; available: ~a"
           opponent
           (hash-keys OPPONENT-SPECS)))
  (define opp-info (hash-ref OPPONENT-SPECS opponent))
  (define opp-race (hash-ref opp-info 'race))
  (define opp-type (hash-ref opp-info 'type))
  (define opp-dir (hash-ref opp-info 'dir))
  (define opp-exec (hash-ref opp-info 'exec))

  (call-with-sc2-slot
   (lambda (slot-idx)
     (make-directory* REPLAY-OUT-DIR)
     (define ts (current-seconds))
     (define prefix (format "~a_~a_vs_~a_~a" ts our-bot opponent map-name))
     (define replay-path (build-path REPLAY-OUT-DIR (format "~a.SC2Replay" prefix)))
     (define our-stdout-path (build-path REPLAY-OUT-DIR (format "~a_our_stdout.log" prefix)))
     (define our-stderr-path (build-path REPLAY-OUT-DIR (format "~a_our_stderr.log" prefix)))
     (define priority-log-path (build-path REPLAY-OUT-DIR (format "~a_priority.log" prefix)))
     (define opp-stdout-path (build-path REPLAY-OUT-DIR (format "~a_opp_stdout.log" prefix)))
     (define opp-stderr-path (build-path REPLAY-OUT-DIR (format "~a_opp_stderr.log" prefix)))

     (define-values (game-port-1 game-port-2 start-port) (pick-port-block))
     (printf "[REAL-SC2-MATCH][Slot=~a] Starting ~a vs ~a (~a) on ~a (P1=~a, P2=~a, StartPort=~a, max_loops=~a)\n"
             slot-idx our-bot opponent opp-race map-name game-port-1 game-port-2 start-port max-loops)
     (flush-output)

     (define temp-dir-1 (build-path REPLAY-OUT-DIR (format "tmp_sc2_p1_~a_~a" ts slot-idx)))
     (define temp-dir-2 (build-path REPLAY-OUT-DIR (format "tmp_sc2_p2_~a_~a" ts slot-idx)))
     (make-directory* temp-dir-1)
     (make-directory* temp-dir-2)

     (define sc2-p1 #f)
     (define sc2-p2 #f)
     (define bot-p1 #f)
     (define bot-p2 #f)
     (define our-out-port #f)
     (define our-err-port #f)
     (define opp-out-port #f)
     (define opp-err-port #f)
     (define devnull-in1 #f)
     (define devnull-out1 #f)
     (define devnull-err1 #f)
     (define devnull-in2 #f)
     (define devnull-out2 #f)
     (define devnull-err2 #f)

     (define t0 (current-inexact-milliseconds))

     (dynamic-wind
       void
       (lambda ()
         ;; 1. Spawn two headless SC2_x64 instances
         (parameterize ([current-directory SC2-CWD]
                        [current-subprocess-custodian-mode 'kill])
           (define-values (sp1 out1 in1 err1)
             (subprocess #f #f #f
                         SC2-BIN
                         "-listen" "127.0.0.1"
                         "-port" (number->string game-port-1)
                         "-displayMode" "0"
                         "-dataDir" (path->string (simplify-path SC2-ROOT))
                         "-tempDir" (path->string temp-dir-1)))
           (set! sc2-p1 sp1)
           (set! devnull-in1 in1)
           (set! devnull-out1 out1)
           (set! devnull-err1 err1)

           (define-values (sp2 out2 in2 err2)
             (subprocess #f #f #f
                         SC2-BIN
                         "-listen" "127.0.0.1"
                         "-port" (number->string game-port-2)
                         "-displayMode" "0"
                         "-dataDir" (path->string (simplify-path SC2-ROOT))
                         "-tempDir" (path->string temp-dir-2)))
           (set! sc2-p2 sp2)
           (set! devnull-in2 in2)
           (set! devnull-out2 out2)
           (set! devnull-err2 err2))

         (unless (wait-for-tcp-port "127.0.0.1" game-port-1 25.0)
           (error 'run-real-sc2-bot-match "SC2_x64 #1 failed to listen on port ~a" game-port-1))
         (unless (wait-for-tcp-port "127.0.0.1" game-port-2 25.0)
           (error 'run-real-sc2-bot-match "SC2_x64 #2 failed to listen on port ~a" game-port-2))

         (set! our-out-port (open-output-file our-stdout-path #:exists 'replace))
         (set! our-err-port (open-output-file our-stderr-path #:exists 'replace))
         (set! opp-out-port (open-output-file opp-stdout-path #:exists 'replace))
         (set! opp-err-port (open-output-file opp-stderr-path #:exists 'replace))

         ;; 2. Launch Player 1 (our pure-Racket bot)
         (parameterize ([current-directory REPO-ROOT]
                        [current-subprocess-custodian-mode 'kill])
           (define-values (bp1 _bo1 bi1 _be1)
             (subprocess our-out-port #f our-err-port
                         RACKET-BIN
                         (path->string (build-path REPO-ROOT "sim" "racket-sc2-ladder-main.rkt"))
                         "--BotName" our-bot
                         "--GamePort" (number->string game-port-1)
                         "--StartPort" (number->string start-port)
                         "--LadderServer" "127.0.0.1"
                         "--OpponentId" opponent
                         "--Host2POpponentRace" opp-race
                         "--Map" map-name
                         "--SaveReplay" (path->string replay-path)
                         "--max-loops" (number->string max-loops)
                         "--step-size" (number->string step-size)))
           (close-output-port bi1)
           (set! bot-p1 bp1))

         ;; Wait for Player 1 to complete RequestCreateGame before Player 2 joins
         (define cg-deadline (+ (current-inexact-milliseconds) 25000.0))
         (let wait-cg ()
           (cond
             [(> (current-inexact-milliseconds) cg-deadline) (void)]
             [(not (eq? (subprocess-status bot-p1) 'running)) (void)]
             [(and (file-exists? our-stderr-path)
                   (string-contains? (file->string our-stderr-path) "[HOST-2P] RequestCreateGame completed"))
              (void)]
             [else
              (sleep 0.2)
              (wait-cg)]))
         (sleep 0.2)

         ;; 3. Launch Player 2 (downloaded opponent bot)
         (define opp-env (environment-variables-copy (current-environment-variables)))
         (parameterize ([current-directory opp-dir]
                        [current-environment-variables opp-env]
                        [current-subprocess-custodian-mode 'kill])
           (cond
             [(eq? opp-type 'racket)
              (define-values (bp2 _bo2 bi2 _be2)
                (subprocess opp-out-port #f opp-err-port
                            RACKET-BIN
                            (path->string (build-path REPO-ROOT "sim" "racket-sc2-ladder-main.rkt"))
                            "--BotName" opp-exec
                            "--GamePort" (number->string game-port-2)
                            "--StartPort" (number->string start-port)
                            "--LadderServer" "127.0.0.1"
                            "--OpponentId" our-bot
                            "--max-loops" (number->string max-loops)
                            "--step-size" (number->string step-size)))
              (close-output-port bi2)
              (set! bot-p2 bp2)]
             [(eq? opp-type 'cpplinux)
              (define-values (bp2 _bo2 bi2 _be2)
                (subprocess opp-out-port #f opp-err-port
                            opp-exec
                            "--GamePort" (number->string game-port-2)
                            "--StartPort" (number->string start-port)
                            "--LadderServer" "127.0.0.1"
                            "--OpponentId" our-bot))
              (close-output-port bi2)
              (set! bot-p2 bp2)]
             [else
              (define bundled-py
                (build-path DOWNLOADED-BOTS-DIR "sludgement2-revived" "python" "bin" "python3.8"))
              (define bundled-sp
                (build-path DOWNLOADED-BOTS-DIR "sludgement2-revived" "site-packages"))
              (define who-dir
                (build-path DOWNLOADED-BOTS-DIR "who"))
              (define who-ares
                (build-path DOWNLOADED-BOTS-DIR "who" "ares-sc2" "src"))
              (define py-path-str
                (string-join (map path->string (list opp-dir bundled-sp who-dir who-ares)) ":"))
              (environment-variables-set! opp-env #"PYTHONPATH" (string->bytes/utf-8 py-path-str))
              (define py-bin
                (if (file-exists? bundled-py)
                    (path->string bundled-py)
                    (path->string (or (find-executable-path "python3") (build-path "/usr/bin/python3")))))
              (define-values (bp2 _bo2 bi2 _be2)
                (subprocess opp-out-port #f opp-err-port
                            py-bin
                            opp-exec
                            "--GamePort" (number->string game-port-2)
                            "--StartPort" (number->string start-port)
                            "--LadderServer" "127.0.0.1"
                            "--OpponentId" our-bot))
              (close-output-port bi2)
              (set! bot-p2 bp2)]))

         ;; 4. Wait for match completion
         (define match-deadline (+ (current-inexact-milliseconds) (* 1000.0 timeout-sec)))
         (define p2-exit-at #f)
         (let wait-match ()
           (cond
             [(> (current-inexact-milliseconds) match-deadline)
              (printf "[WARN] Match exceeded timeout (~as); terminating.\n" timeout-sec)
              (flush-output)]
             [(not (eq? (subprocess-status bot-p1) 'running))
              (void)]
             [(not (eq? (subprocess-status bot-p2) 'running))
              (cond
                [(not p2-exit-at)
                 (set! p2-exit-at (current-inexact-milliseconds))
                 (sleep 0.5)
                 (wait-match)]
                [(> (- (current-inexact-milliseconds) p2-exit-at) 8000.0)
                 (printf "[WARN] Opponent bot exited early (status=~a); stopping wait.\n"
                         (subprocess-status bot-p2))
                 (flush-output)]
                [else
                 (sleep 0.5)
                 (wait-match)])]
             [else
              (sleep 0.5)
              (wait-match)])))
       (lambda ()
         (for ([p (in-list (list our-out-port our-err-port opp-out-port opp-err-port
                                 devnull-in1 devnull-in2))])
           (when (and p (output-port? p) (not (port-closed? p)))
             (with-handlers ([exn:fail? void]) (close-output-port p))))
         (for ([p (in-list (list devnull-out1 devnull-err1 devnull-out2 devnull-err2))])
           (when (and p (input-port? p) (not (port-closed? p)))
             (with-handlers ([exn:fail? void]) (close-input-port p))))
         (kill-subprocess-safe! bot-p1)
         (kill-subprocess-safe! bot-p2)
         (kill-subprocess-safe! sc2-p1)
         (kill-subprocess-safe! sc2-p2)
         (with-handlers ([exn:fail? void]) (delete-directory/files temp-dir-1 #:must-exist? #f))
         (with-handlers ([exn:fail? void]) (delete-directory/files temp-dir-2 #:must-exist? #f))))

     (define elapsed-sec (/ (round (/ (- (current-inexact-milliseconds) t0) 10.0)) 100.0))
     (define our-stdout (if (file-exists? our-stdout-path) (string-trim (file->string our-stdout-path)) ""))
     (define our-stderr (if (file-exists? our-stderr-path) (string-trim (file->string our-stderr-path)) ""))
     (define opp-stderr (if (file-exists? opp-stderr-path) (string-trim (file->string opp-stderr-path)) ""))

     (define bot-summary
       (let loop ([lines (reverse (string-split our-stdout "\n"))])
         (cond
           [(null? lines) (hasheq)]
           [else
            (define ln (string-trim (car lines)))
            (if (and (string-prefix? ln "{") (string-suffix? ln "}"))
                (with-handlers ([exn:fail? (lambda (_e) (loop (cdr lines)))])
                  (string->jsexpr ln))
                (loop (cdr lines)))])))

     (printf "[REAL-SC2-MATCH][Slot=~a] Finished in ~as | Summary: ~a\n"
             slot-idx elapsed-sec (jsexpr->string bot-summary))
     (when (hash-has-key? bot-summary 'avg_step_ms)
       (printf "[TURN-TIMING] avg_step_ms=~a p95_step_ms=~a max_step_ms=~a | obs=~ams runtime=~ams translate=~ams\n"
               (hash-ref bot-summary 'avg_step_ms 0)
               (hash-ref bot-summary 'p95_step_ms 0)
               (hash-ref bot-summary 'max_step_ms 0)
               (hash-ref bot-summary 'avg_obs_ms 0)
               (hash-ref bot-summary 'avg_runtime_ms 0)
               (hash-ref bot-summary 'avg_translate_ms 0)))
     (when (hash-has-key? bot-summary 'scout_commands_emitted)
       (printf "[INTEL-AUDIT] scout_cmds=~a harass_cmds=~a enemy_first_seen_loop=~a max_intel_staleness=~a max_escrow_age=~a peak_remembered_threat=~a\n"
               (hash-ref bot-summary 'scout_commands_emitted 0)
               (hash-ref bot-summary 'harass_commands_emitted 0)
               (hash-ref bot-summary 'enemy_first_seen_loop -1)
               (hash-ref bot-summary 'max_intel_staleness_frames 0)
               (hash-ref bot-summary 'max_escrow_age_frames 0)
               (hash-ref bot-summary 'peak_remembered_enemy_threat 0)))
     (define priority-audit (audit-priority-logs our-stderr priority-log-path))
     (when (and (not (string=? opp-stderr ""))
                (not (hash-has-key? bot-summary 'status)))
       (printf "[OPP-STDERR]\n~a\n" (substring opp-stderr 0 (min 800 (string-length opp-stderr)))))
     (flush-output)

     (hasheq 'elapsed_sec elapsed-sec
             'bot_summary bot-summary
             'priority_audit priority-audit
             'replay_path (if (file-exists? replay-path) (path->string replay-path) "")))))

(module+ main
  (define our-bot "Mothman-Z")
  (define opponent "sludgement2-revived")
  (define map-name "AcropolisLE")
  (define max-loops 6720)
  (define step-size 4)
  (define timeout-sec 300)

  (command-line
   #:program "run-real-sc2-bot-match.rkt"
   #:once-each
   [("--bot") b "Our bot variant (Mothman-Z, Mothman-T, Mothman-P, Mothman-X)"
              (set! our-bot b)]
   [("--opponent") o "Downloaded opponent bot name"
                   (set! opponent o)]
   [("--map") m "SC2 Map name"
              (set! map-name m)]
   [("--max-loops") ml "Max game loops (6720 = 5 min, 13440 = 10 min)"
                    (set! max-loops (or (string->number ml) 6720))]
   [("--step-size") ss "Game loops per RequestStep"
                    (set! step-size (or (string->number ss) 4))]
   [("--timeout") to "Wall-clock timeout in seconds"
                  (set! timeout-sec (or (string->number to) 300))])

  (void (run-real-sc2-bot-match #:our-bot our-bot
                                #:opponent opponent
                                #:map-name map-name
                                #:max-loops max-loops
                                #:step-size step-size
                                #:timeout-sec timeout-sec)))
