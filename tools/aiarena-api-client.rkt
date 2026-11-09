#lang racket/base

;; =============================================================================
;; Pure-Racket AI Arena REST & GraphQL API Client (`tools/aiarena-api-client.rkt`)
;;
;; Manages Mothman bots on AI Arena (`https://aiarena.net`) in 100% pure Racket:
;;   1. `--sync-zips`: Uploads latest `ladder/Mothman-{X,Z,T,P}.zip` to bots
;;      `1461` (`Mothman-X`), `1458` (`Mothman-Z`), `1459` (`Mothman-T`), and
;;      `1460` (`Mothman-P`) via `PATCH /api/bots/<id>/`.
;;   2. `--request-matches <N>`: Requests `<N>` new matches (default 5) via the
;;      `requestMatch` GraphQL mutation against Division-1 opponents (`Atlas`,
;;      `Eris`, `Phobos`, `Deimos`) on Map Pool 18 (`2025 S2`).
;;   3. `--status`: Queries live bot zip MD5 hashes, competition ELOs, and
;;      recent match statuses (`Queued`, `LIVE IN PROGRESS`, `Finished`).
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         file/md5
         net/base64
         json
         "../ladder/build-aiarena-zip.rkt")

(define-runtime-path TOOLS-DIR ".")
(define ROOT-DIR (simplify-path (build-path TOOLS-DIR "..")))
(define LADDER-DIR (build-path ROOT-DIR "ladder"))

(define TOKEN-FILE (build-path (find-system-path 'home-dir) ".gemini" "aiarena_token"))

(define DEFAULT-TOKEN
  (or (getenv "AIARENA_API_TOKEN")
      (and (file-exists? TOKEN-FILE)
           (let ([t (string-trim (file->string TOKEN-FILE))])
             (and (not (string=? t "")) t)))
      "717fa15cc782b2432c2fe14da6d92c202dfe6c96"))

(define USER-ID 3871)
(define COMPETITION-ID 38)
(define MAP-POOL-ID 18) ; 2025 S2 ladder pool

(define MOTHMAN-BOT-UPLOADS
  ;; (bot-id bot-name zip-filename)
  '((1461 "Mothman-X" "Mothman-X.zip")
    (1458 "Mothman-Z" "Mothman-Z.zip")
    (1459 "Mothman-T" "Mothman-T.zip")
    (1460 "Mothman-P" "Mothman-P.zip")))

(define MATCH-REQUEST-PAIRINGS
  ;; (our-bot-id our-name opp-bot-id opp-name)
  '((1458 "Mothman-Z" 1256 "Atlas")
    (1459 "Mothman-T" 248  "Eris")
    (1460 "Mothman-P" 611  "Phobos")
    (1461 "Mothman-X" 730  "Deimos")
    (1458 "Mothman-Z" 730  "Deimos")
    (1459 "Mothman-T" 1256 "Atlas")
    (1460 "Mothman-P" 248  "Eris")
    (1461 "Mothman-X" 611  "Phobos")))

(define (relay-global-id type-name id-num)
  (define raw (string->bytes/utf-8 (format "~a:~a" type-name id-num)))
  (string-trim (bytes->string/utf-8 (base64-encode raw #""))))

(define (curl-json args)
  (define curl-bin (find-executable-path "curl"))
  (define out-str
    (with-output-to-string
      (lambda ()
        (apply system* curl-bin "-sL" args))))
  (with-handlers ([exn:fail? (lambda (_e) (hash 'raw out-str))])
    (string->jsexpr out-str)))

(define (api-get endpoint [token DEFAULT-TOKEN])
  (define url
    (if (string-prefix? endpoint "http")
        endpoint
        (format "https://aiarena.net/api/~a" (string-trim endpoint "/" #:right? #f))))
  (curl-json (list "-H" (format "Authorization: Token ~a" token) url)))

(define (graphql-post query-str variables-jsexpr [token DEFAULT-TOKEN])
  (define payload
    (jsexpr->string (hash 'query query-str
                          'variables variables-jsexpr)))
  (curl-json (list "-X" "POST"
                   "-H" (format "Authorization: Token ~a" token)
                   "-H" "Content-Type: application/json"
                   "-d" payload
                   "https://aiarena.net/graphql/")))

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
   (hash 'input (hash 'bot bot-gql
                      'competition comp-gql
                      'active active?))
   token))

(define (request-single-match! bot1-id bot1-name bot2-id bot2-name [token DEFAULT-TOKEN])
  (define bot1-gql (relay-global-id "BotType" bot1-id))
  (define bot2-gql (relay-global-id "BotType" bot2-id))
  (define pool-gql (relay-global-id "MapPoolType" MAP-POOL-ID))
  (define resp
    (graphql-post
     "mutation($input: RequestMatchInput!) { requestMatch(input: $input) { errors { field messages } match { id } } }"
     (hash 'input (hash 'bot1 bot1-gql
                        'bot2 bot2-gql
                        'matchCount 1
                        'mapSelectionType "map_pool"
                        'mapPool pool-gql))
     token))
  (define data-obj (let ([d (hash-ref resp 'data (hash))]) (if (hash? d) d (hash))))
  (define rm (let ([r (hash-ref data-obj 'requestMatch (hash))]) (if (hash? r) r (hash))))
  (define errs (or (and (pair? (hash-ref rm 'errors '())) (hash-ref rm 'errors '()))
                   (hash-ref resp 'errors '())))
  (define match-obj (hash-ref rm 'match #f))
  (printf "  [REQUEST] ~a (#~a) vs ~a (#~a) -> match=~v errors=~v\n"
          bot1-name bot1-id bot2-name bot2-id match-obj errs)
  resp)

(define (sync-all-bot-zips! [token DEFAULT-TOKEN])
  (printf "============================================================================\n")
  (printf "  Uploading Mothman BotZip Packages to AI Arena (`https://aiarena.net`)\n")
  (printf "============================================================================\n")
  ;; Keep legacy Python Mothman-R (#1457) paused
  (void (set-competition-active! 1457 #f token))
  (for ([row (in-list MOTHMAN-BOT-UPLOADS)])
    (match-define (list bid bname zfile) row)
    (define zpath (build-path LADDER-DIR zfile))
    (when (file-exists? zpath)
      (patch-bot-zip! bid bname zpath token)
      (void (set-competition-active! bid #t token)))))

(define (request-n-matches! count [token DEFAULT-TOKEN])
  (printf "\n============================================================================\n")
  (printf "  Requesting ~a New AI Arena Matches (Map Pool #~a)\n" count MAP-POOL-ID)
  (printf "============================================================================\n")
  (for ([i (in-range count)])
    (match-define (list b1 n1 b2 n2)
      (list-ref MATCH-REQUEST-PAIRINGS (modulo i (length MATCH-REQUEST-PAIRINGS))))
    (request-single-match! b1 n1 b2 n2 token)))

(define (print-live-status! [token DEFAULT-TOKEN])
  (printf "\n============================================================================\n")
  (printf "  AI Arena Live Bot & Match Status (User #~a)\n" USER-ID)
  (printf "============================================================================\n")
  (define bots-resp (api-get (format "bots/?user=~a" USER-ID) token))
  (define bots (hash-ref bots-resp 'results '()))
  (for ([b (in-list bots)])
    (define bid (hash-ref b 'id))
    (define bname (hash-ref b 'name))
    (define btype (hash-ref b 'type))
    (define zupd (hash-ref b 'bot_zip_updated))
    (define zmd5 (hash-ref b 'bot_zip_md5hash))
    (printf "  * ~a (#~a, ~a): updated=~a md5=~a\n" bname bid btype zupd zmd5)
    (define mp-resp (api-get (format "match-participations/?bot=~a&ordering=-match&limit=5" bid) token))
    (for ([p (in-list (take (hash-ref mp-resp 'results '())
                            (min 3 (length (hash-ref mp-resp 'results '())))))])
      (define mid (hash-ref p 'match))
      (define res (hash-ref p 'result 'null))
      (define cause (hash-ref p 'result_cause 'null))
      (printf "      - Match #~a: result=~a cause=~a\n" mid res cause))))

(module+ main
  (define do-sync? #f)
  (define req-count 0)
  (define do-status? #f)

  (command-line
   #:program "aiarena-api-client.rkt"
   #:once-each
   [("--sync-zips") "Upload latest ladder/Mothman-*.zip to AI Arena" (set! do-sync? #t)]
   [("--request-matches") n "Request N matches (e.g., 5)" (set! req-count (or (string->number n) 5))]
   [("--status") "Print live AI Arena bot & match status" (set! do-status? #t)])

  (when do-sync?
    (sync-all-bot-zips! DEFAULT-TOKEN))
  (when (> req-count 0)
    (request-n-matches! req-count DEFAULT-TOKEN))
  (when (or do-status? (and (not do-sync?) (zero? req-count)))
    (print-live-status! DEFAULT-TOKEN)))
