#lang racket/base

;; =============================================================================
;; Pure-Racket AI Arena REST & GraphQL API Client (`tools/aiarena-api-client.rkt`)
;;
;; Manages Mothman bots on AI Arena (`https://aiarena.net`) in 100% pure Racket:
;;   1. `--sync-zips`: Uploads latest `ladder/Mothman-{X,Z,T,P}.zip` (filtered by
;;      `--bots Z,T,P,X`) via `PATCH /api/bots/<id>/` and activates Competition #38.
;;   2. `--request-matches <N>`: Requests `<N>` new matches via `requestMatch`
;;      GraphQL mutation against configurable `--opponents` / `--preset` on
;;      Map Pool #18 (`2025 S2`), decoding Relay base64 IDs into numeric Match IDs
;;      (`#5117325` + `https://aiarena.net/matches/5117325/`).
;;   3. `--status`: Queries live bot zip MD5 hashes, Competition #38 ELO/division,
;;      and recent match statuses (`Queued`, `In Progress`, `Win`/`Loss`) in parallel.
;;   4. `--analyze` / `--forensics` / `--since-match <ID>` / `--match-ids <IDs>`:
;;      Directly invokes `run-aiarena-forensic-analysis!` from
;;      `tools/analyze-aiarena-replays.rkt` in-process (zero Python, zero subprocess).
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/set
         racket/string
         racket/system
         file/md5
         net/base64
         json
         "../ladder/build-aiarena-zip.rkt"
         "analyze-aiarena-replays.rkt")

(provide relay-global-id
         decode-relay-global-id
         resolve-opponents-spec
         sync-all-bot-zips!
         request-n-matches!
         print-live-status!)

(define-runtime-path TOOLS-DIR ".")
(define ROOT-DIR (simplify-path (build-path TOOLS-DIR "..")))
(define LADDER-DIR (build-path ROOT-DIR "ladder"))

(define USER-ID 3871)
(define COMPETITION-ID 38)
(define DEFAULT-MAP-POOL-ID 18) ; 2025 S2 ladder pool

(define MOTHMAN-BOT-UPLOADS
  ;; (bot-id bot-name zip-filename)
  '((1461 "Mothman-X" "Mothman-X.zip")
    (1458 "Mothman-Z" "Mothman-Z.zip")
    (1459 "Mothman-T" "Mothman-T.zip")
    (1460 "Mothman-P" "Mothman-P.zip")))

(define OPPONENT-PRESETS
  (hash "div1"
        '((1256 "Atlas")
          (248  "Eris")
          (611  "Phobos")
          (730  "Deimos"))
        "div2-3"
        '("Creepy_strategies"
          "Thssprtssbt"
          "Mulebot")
        "div3-5"
        '("Creepy_strategies"
          "Thssprtssbt"
          "sludgement2-revived"
          "mini-puck"
          "onlyfans"
          "oberon"
          "titania"
          "who")))

(define (jnull->false v)
  (if (or (eq? v 'null) (not v)) #f v))

(define (relay-global-id type-name id-num)
  (define raw (string->bytes/utf-8 (format "~a:~a" type-name id-num)))
  (string-trim (bytes->string/utf-8 (base64-encode raw #""))))

(define (decode-relay-global-id relay-b64)
  ;; Decodes e.g. "TWF0Y2hUeXBlOjUxMTczMjU=" -> (values "MatchType" 5117325)
  (with-handlers ([exn:fail? (lambda (_e) (values "" #f))])
    (define decoded (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (string-trim relay-b64))) #\?))
    (define parts (string-split decoded ":"))
    (if (= (length parts) 2)
        (values (car parts) (string->number (cadr parts)))
        (values decoded #f))))

(define (curl-json args)
  (define curl-bin (or (find-executable-path "curl") (string->path "/usr/bin/curl")))
  (define out-str
    (with-output-to-string
      (lambda ()
        (apply system* curl-bin "-sL" "--max-time" "25" args))))
  (with-handlers ([exn:fail? (lambda (_e) (hasheq 'raw out-str))])
    (string->jsexpr out-str)))

(define (api-get endpoint [token DEFAULT-TOKEN])
  (define url
    (if (string-prefix? endpoint "http")
        endpoint
        (format "https://aiarena.net/api/~a" (string-trim endpoint "/" #:right? #f))))
  (curl-json (list "-H" (format "Authorization: Token ~a" token) url)))

(define (graphql-post query-str variables-jsexpr [token DEFAULT-TOKEN])
  (define payload
    (jsexpr->string (hasheq 'query query-str
                            'variables variables-jsexpr)))
  (curl-json (list "-X" "POST"
                   "-H" (format "Authorization: Token ~a" token)
                   "-H" "Content-Type: application/json"
                   "-d" payload
                   "https://aiarena.net/graphql/")))

(define (resolve-single-opponent-entry entry [token DEFAULT-TOKEN])
  ;; Returns (list bot-id bot-name)
  (cond
    [(and (list? entry) (= (length entry) 2))
     entry]
    [(exact-positive-integer? entry)
     (define cached (hash-ref KNOWN-BOT-NAMES entry #f))
     (if cached
         (list entry cached)
         (let* ([resp (api-get (format "bots/~a/" entry) token)]
                [nm (or (and (hash? resp) (jnull->false (hash-ref resp 'name #f)))
                        (format "Bot~a" entry))])
           (hash-set! KNOWN-BOT-NAMES entry nm)
           (list entry nm)))]
    [(string? entry)
     (define trimmed (string-trim entry))
     (cond
       [(string->number trimmed)
        => (lambda (n) (resolve-single-opponent-entry n token))]
       [else
        ;; Check KNOWN-BOT-NAMES case-insensitively first
        (define known-id
          (for/first ([(bid bname) (in-hash KNOWN-BOT-NAMES)]
                      #:when (string-ci=? bname trimmed))
            bid))
        (if known-id
            (list known-id (hash-ref KNOWN-BOT-NAMES known-id))
            (let* ([resp (api-get (format "bots/?name=~a" trimmed) token)]
                   [results (if (hash? resp) (hash-ref resp 'results '()) '())]
                   [b0 (and (pair? results) (car results))])
              (if (and (hash? b0) (exact-positive-integer? (hash-ref b0 'id #f)))
                  (let ([bid (hash-ref b0 'id)]
                        [bnm (hash-ref b0 'name trimmed)])
                    (hash-set! KNOWN-BOT-NAMES bid bnm)
                    (list bid bnm))
                  (error 'resolve-opponents-spec
                         "Could not resolve AI Arena opponent bot ~s" trimmed))))])]
    [else
     (error 'resolve-opponents-spec "Invalid opponent specification: ~s" entry)]))

(define (resolve-opponents-spec opponents-str preset-str [token DEFAULT-TOKEN])
  (define raw-entries
    (cond
      [(and opponents-str (not (string=? (string-trim opponents-str) "")))
       (define trimmed (string-trim opponents-str))
       (if (hash-has-key? OPPONENT-PRESETS (string-downcase trimmed))
           (hash-ref OPPONENT-PRESETS (string-downcase trimmed))
           (filter (lambda (s) (not (string=? s "")))
                   (map string-trim (string-split trimmed ","))))]
      [(and preset-str (hash-has-key? OPPONENT-PRESETS (string-downcase (string-trim preset-str))))
       (hash-ref OPPONENT-PRESETS (string-downcase (string-trim preset-str)))]
      [else
       (hash-ref OPPONENT-PRESETS "div1")]))
  (for/list ([e (in-list raw-entries)])
    (resolve-single-opponent-entry e token)))

(define (build-request-pairings bot-ids opponents)
  ;; Round-robin interleaving across selected Mothman bots and target opponents
  ;; so small N (e.g., 4 or 8) covers all selected bots evenly with rotated pairings!
  (define active-bots
    (filter (lambda (b) (hash-has-key? BOT-IDS b)) bot-ids))
  (define nb (max 1 (length active-bots)))
  (define no (max 1 (length opponents)))
  (define total-lcm (* nb no))
  (for/list ([idx (in-range total-lcm)])
    (define b-idx (modulo idx nb))
    (define o-idx (modulo (+ idx (quotient idx nb)) no))
    (define bid (list-ref active-bots b-idx))
    (define bname (hash-ref BOT-IDS bid))
    (match-define (list oid oname) (list-ref opponents o-idx))
    (list bid bname oid oname)))

(define (patch-bot-zip! bot-id bot-name zip-path [token DEFAULT-TOKEN])
  (validate-bot-zip-archive! zip-path #:bot-name bot-name)
  (define local-md5 (bytes->string/utf-8 (call-with-input-file zip-path md5)))
  (define sz-mb (/ (round (* 100.0 (/ (file-size zip-path) (* 1024.0 1024.0)))) 100.0))
  (printf "  [UPLOAD] Uploading ~a (~a MB, md5=~a) -> Bot #~a (~a)...\n"
          (path->string zip-path) sz-mb local-md5 bot-id bot-name)
  (flush-output)
  (define resp
    (curl-json (list "-X" "PATCH"
                     "-H" (format "Authorization: Token ~a" token)
                     "-F" (format "bot_zip=@~a" (path->string zip-path))
                     "-F" "bot_data_enabled=true"
                     (format "https://aiarena.net/api/bots/~a/" bot-id))))
  (define check-resp
    (if (hash-has-key? resp 'bot_zip_md5hash)
        resp
        (api-get (format "bots/~a/" bot-id) token)))
  (define remote-upd (hash-ref check-resp 'bot_zip_updated "unknown"))
  (define remote-md5 (hash-ref check-resp 'bot_zip_md5hash "unknown"))
  (printf "    -> Updated: ~a | Remote MD5: ~a (match? ~a)\n"
          remote-upd remote-md5 (equal? remote-md5 local-md5))
  check-resp)

(define (set-competition-active! bot-id active? [token DEFAULT-TOKEN])
  (define bot-gql (relay-global-id "BotType" bot-id))
  (define comp-gql (relay-global-id "CompetitionType" COMPETITION-ID))
  (graphql-post
   "mutation($input: UpdateCompetitionParticipationInput!) { updateCompetitionParticipation(input: $input) { errors { field messages } } }"
   (hasheq 'input (hasheq 'bot bot-gql
                          'competition comp-gql
                          'active active?))
   token))

(define (request-single-match! bot1-id bot1-name bot2-id bot2-name
                               #:map-pool-id [map-pool-id DEFAULT-MAP-POOL-ID]
                               #:token [token DEFAULT-TOKEN])
  (define bot1-gql (relay-global-id "BotType" bot1-id))
  (define bot2-gql (relay-global-id "BotType" bot2-id))
  (define pool-gql (relay-global-id "MapPoolType" map-pool-id))
  (define resp
    (graphql-post
     "mutation($input: RequestMatchInput!) { requestMatch(input: $input) { errors { field messages } match { id } } }"
     (hasheq 'input (hasheq 'bot1 bot1-gql
                            'bot2 bot2-gql
                            'matchCount 1
                            'mapSelectionType "map_pool"
                            'mapPool pool-gql))
     token))
  (define data-obj (let ([d (hash-ref resp 'data (hasheq))]) (if (hash? d) d (hasheq))))
  (define rm (let ([r (hash-ref data-obj 'requestMatch (hasheq))]) (if (hash? r) r (hasheq))))
  (define errs (or (and (pair? (hash-ref rm 'errors '())) (hash-ref rm 'errors '()))
                   (hash-ref resp 'errors '())))
  (define match-obj (jnull->false (hash-ref rm 'match #f)))
  (define relay-id (and (hash? match-obj) (jnull->false (hash-ref match-obj 'id #f))))
  (define-values (_mtype numeric-mid)
    (if (string? relay-id) (decode-relay-global-id relay-id) (values "" #f)))
  (cond
    [numeric-mid
     (printf "  [REQUEST] ~a (#~a) vs ~a (#~a) -> Match #~a (https://aiarena.net/matches/~a/ | relay=~a)\n"
             bot1-name bot1-id bot2-name bot2-id numeric-mid numeric-mid relay-id)]
    [else
     (printf "  [REQUEST] ~a (#~a) vs ~a (#~a) -> match=~v errors=~v\n"
             bot1-name bot1-id bot2-name bot2-id match-obj errs)])
  (flush-output)
  numeric-mid)

(define (sync-all-bot-zips! [token DEFAULT-TOKEN]
                            #:bot-ids [bot-ids '(1461 1458 1459 1460)])
  (define want-set (list->seteqv bot-ids))
  (printf "============================================================================\n")
  (printf "  Uploading Mothman BotZip Packages to AI Arena (`https://aiarena.net`)\n")
  (printf "============================================================================\n")
  ;; Keep legacy Python Mothman-R (#1457) paused
  (void (set-competition-active! 1457 #f token))
  (for ([row (in-list MOTHMAN-BOT-UPLOADS)])
    (match-define (list bid bname zfile) row)
    (when (set-member? want-set bid)
      (define zpath (build-path LADDER-DIR zfile))
      (when (file-exists? zpath)
        (patch-bot-zip! bid bname zpath token)
        (void (set-competition-active! bid #t token))))))

(define (request-n-matches! count
                            [token DEFAULT-TOKEN]
                            #:bot-ids [bot-ids '(1458 1459 1460 1461)]
                            #:opponents [opponents #f]
                            #:map-pool-id [map-pool-id DEFAULT-MAP-POOL-ID])
  (define eff-opponents (or opponents (resolve-opponents-spec #f "div1" token)))
  (define pairings (build-request-pairings bot-ids eff-opponents))
  (printf "\n============================================================================\n")
  (printf "  Requesting ~a New AI Arena Matches (Map Pool #~a)\n" count map-pool-id)
  (printf "============================================================================\n")
  (define created-ids
    (filter values
            (for/list ([i (in-range count)])
              (match-define (list b1 n1 b2 n2)
                (list-ref pairings (modulo i (length pairings))))
              (request-single-match! b1 n1 b2 n2
                                     #:map-pool-id map-pool-id
                                     #:token token))))
  (when (pair? created-ids)
    (printf "  [SUMMARY] Requested ~a match(es): --match-ids ~a (min=#~a)\n"
            (length created-ids)
            (string-join (map number->string created-ids) ",")
            (apply min created-ids)))
  created-ids)

(define (parallel-map proc items)
  (define thds
    (for/list ([it (in-list items)])
      (define box-res (box #f))
      (define t
        (thread
         (lambda ()
           (set-box! box-res
                     (with-handlers ([exn:fail? (lambda (_e) #f)])
                       (proc it))))))
      (cons t box-res)))
  (for/list ([tb (in-list thds)])
    (thread-wait (car tb))
    (unbox (cdr tb))))

(define (print-live-status! [token DEFAULT-TOKEN]
                            #:bot-ids [bot-ids #f]
                            #:recent-limit [recent-limit 5])
  (printf "\n============================================================================\n")
  (printf "  AI Arena Live Bot & Match Status (User #~a, Competition #~a)\n" USER-ID COMPETITION-ID)
  (printf "============================================================================\n")
  (define bots-resp (api-get (format "bots/?user=~a" USER-ID) token))
  (define all-bots (if (hash? bots-resp) (hash-ref bots-resp 'results '()) '()))
  (define filtered-bots
    (if (not bot-ids)
        all-bots
        (let ([want (list->seteqv bot-ids)])
          (filter (lambda (b) (set-member? want (hash-ref b 'id -1))) all-bots))))

  (define bot-details
    (parallel-map
     (lambda (b)
       (define bid (hash-ref b 'id))
       (define cp-resp
         (api-get (format "competition-participations/?bot=~a&competition=~a" bid COMPETITION-ID) token))
       (define cp-list (if (hash? cp-resp) (hash-ref cp-resp 'results '()) '()))
       (define cp0 (and (pair? cp-list) (car cp-list)))
       (define mp-resp
         (api-get (format "match-participations/?bot=~a&ordering=-match&limit=~a" bid recent-limit) token))
       (define mp-list (if (hash? mp-resp) (hash-ref mp-resp 'results '()) '()))
       (list b cp0 mp-list))
     filtered-bots))

  (for ([entry (in-list bot-details)]
        #:when entry)
    (match-define (list b cp0 mp-list) entry)
    (define bid (hash-ref b 'id))
    (define bname (hash-ref b 'name))
    (define btype (hash-ref b 'type))
    (define zupd (hash-ref b 'bot_zip_updated))
    (define zmd5 (hash-ref b 'bot_zip_md5hash))
    (define active? (and (hash? cp0) (jnull->false (hash-ref cp0 'active #f))))
    (define elo (and (hash? cp0) (jnull->false (hash-ref cp0 'elo #f))))
    (define div-num (and (hash? cp0) (jnull->false (hash-ref cp0 'division_num #f))))
    (printf "  * ~a (#~a, ~a) | active=~a elo=~a div=~a | updated=~a md5=~a\n"
            bname bid btype active? (or elo "N/A") (or div-num "N/A") zupd zmd5)
    (for ([p (in-list (take mp-list (min recent-limit (length mp-list))))])
      (define mid (hash-ref p 'match))
      (define res (jnull->false (hash-ref p 'result #f)))
      (define cause (jnull->false (hash-ref p 'result_cause #f)))
      (define elo-chg (jnull->false (hash-ref p 'elo_change #f)))
      (define step-s (jnull->false (hash-ref p 'avg_step_time #f)))
      (define step-str
        (if (real? step-s)
            (format "~ams" (/ (round (* 100000.0 step-s)) 100.0))
            "N/A"))
      (printf "      - Match #~a (https://aiarena.net/matches/~a/): status=~a cause=~a elo_chg=~a step=~a\n"
              mid mid (or res "QUEUED/IN_PROGRESS") (or cause "-") (or elo-chg 0) step-str))))

(module+ main
  (define do-sync? #f)
  (define req-count 0)
  (define do-status? #f)
  (define do-analyze? #f)
  (define bots-str #f)
  (define opponents-str #f)
  (define preset-str "div1")
  (define map-pool-id DEFAULT-MAP-POOL-ID)
  (define since-match-num #f)
  (define match-ids-str #f)
  (define limit-num #f)
  (define cache-dir-str #f)
  (define decode-b64-str #f)

  (command-line
   #:program "aiarena-api-client.rkt"
   #:once-each
   [("--sync-zips") "Upload latest ladder/Mothman-*.zip to AI Arena"
                    (set! do-sync? #t)]
   [("--request-matches") n "Request N matches (e.g., 8)"
                          (set! req-count (or (string->number n) 5))]
   [("--status") "Print live AI Arena bot ELO, MD5, and recent match status"
                 (set! do-status? #t)]
   [("--analyze" "--forensics") "Fetch and run pure-Racket replay + match_log.zip forensics"
                                (set! do-analyze? #t)]
   [("--bots") b "Comma-separated Mothman bot filter: Z,T,P,X (default: all 4)"
               (set! bots-str b)]
   [("--opponents") opp "Comma-separated opponent bot IDs/names or preset (div1, div2-3, div3-5)"
                    (set! opponents-str opp)]
   [("--preset") pr "Opponent preset name: div1, div2-3, div3-5 (default: div1)"
                 (set! preset-str pr)]
   [("--map-pool") mp "Map Pool ID (default: 18)"
                   (set! map-pool-id (or (string->number mp) DEFAULT-MAP-POOL-ID))]
   [("--since-match") sm "Analyze/fetch matches with ID >= <ID>"
                      (begin (set! since-match-num (string->number sm))
                             (set! do-analyze? #t))]
   [("--match-ids") mids "Analyze/fetch exact comma-separated match IDs"
                    (begin (set! match-ids-str mids)
                           (set! do-analyze? #t))]
   [("--limit") lim "Max recent matches to show in --status or fetch in --analyze"
                (set! limit-num (string->number lim))]
   [("--dir") d "Cache directory for --analyze (default: replays/aiarena_live_cache)"
              (set! cache-dir-str d)]
   [("--decode-match-id") b64 "Decode a Relay base64 ID (e.g., TWF0Y2hUeXBlOjUxMTczMjU=)"
                          (set! decode-b64-str b64)])

  (when decode-b64-str
    (define-values (tname num) (decode-relay-global-id decode-b64-str))
    (if num
        (printf "~a -> ~a #~a (https://aiarena.net/matches/~a/)\n"
                decode-b64-str tname num num)
        (printf "~a -> ~a (unrecognized Relay ID)\n" decode-b64-str tname)))

  (define selected-bot-ids
    (and bots-str (parse-bot-filter bots-str)))

  (when do-sync?
    (sync-all-bot-zips! DEFAULT-TOKEN
                        #:bot-ids (or selected-bot-ids '(1461 1458 1459 1460))))

  (define requested-ids
    (if (> req-count 0)
        (let ([opps (resolve-opponents-spec opponents-str preset-str DEFAULT-TOKEN)])
          (request-n-matches! req-count
                              DEFAULT-TOKEN
                              #:bot-ids (or selected-bot-ids '(1458 1459 1460 1461))
                              #:opponents opps
                              #:map-pool-id map-pool-id))
        '()))

  (when (or do-status?
            (and (not do-sync?) (zero? req-count) (not do-analyze?) (not decode-b64-str)))
    (print-live-status! DEFAULT-TOKEN
                        #:bot-ids selected-bot-ids
                        #:recent-limit (or limit-num 5)))

  (when do-analyze?
    (define eff-match-ids
      (let ([parsed (parse-match-ids-str match-ids-str)])
        (if (pair? parsed) parsed requested-ids)))
    (void
     (run-aiarena-forensic-analysis!
      #:dir (or cache-dir-str (build-path ROOT-DIR "replays" "aiarena_live_cache"))
      #:fetch? #t
      #:match-ids eff-match-ids
      #:since-match since-match-num
      #:bot-ids selected-bot-ids
      #:limit limit-num
      #:token DEFAULT-TOKEN))))
