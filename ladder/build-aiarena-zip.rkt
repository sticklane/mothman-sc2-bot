#lang racket/base

;; =============================================================================
;; Pure-Racket AI Arena BotZip Builder (`ladder/build-aiarena-zip.rkt`)
;;
;; Builds AI Arena ladder-ready .zip archives in 100% pure Racket:
;;   - ladder/Mothman-X.zip (Random)
;;   - ladder/Mothman-Z.zip (Zerg)
;;   - ladder/Mothman-T.zip (Terran)
;;   - ladder/Mothman-P.zip (Protoss)
;;
;; 1. Precompiles all `#lang sc-bot` and Racket runtime modules to `.zo` bytecode
;;    via `compiler/cm` (`managed-compile-zo`) inside the hermetic portable
;;    Racket 8.16 (`GLIBC_2.14`) runtime unpacked from
;;    `ladder/.cache/racket_runtime.tar.xz`.
;; 2. Embeds the compiled bytecode and `.rackboot` image into a path-independent,
;;    untethered standalone Linux x86_64 ELF (`ladder/.cache/mothman_standalone_elf`)
;;    with zero `GLIBC > 2.14`, `libxxhash`, `liblz4`, `libtinfo`, or `/home/` leaks.
;; 3. Executes a local headless SC2 WebSocket + Protobuf initialization check
;;    (`verify-standalone-elf-headless-init!`) against the standalone ELF before
;;    writing the standard PKZIP archives (`file/gzip` deflate) with `0755` Unix
;;    executable permissions on `<BotName>` and `run.py`.
;; =============================================================================

(require racket/bytes
         racket/cmdline
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         compiler/cm
         compiler/embed
         compiler/find-exe
         setup/dirs
         file/gzip
         json
         "../sim/racket-sc2-ladder-main.rkt")

(provide AIARENA-STANDARD-MAX-ZIP-BYTES
         AIARENA-BRONZE-MAX-ZIP-BYTES
         MAX-BOT-ZIP-SIZE-BYTES
         MIN-BOT-ZIP-SIZE-BYTES
         MIN-STANDALONE-ELF-BYTES
         VARIANTS
         ensure-portable-racket-815-runtime!
         verify-standalone-elf-headless-init!
         validate-bot-zip-archive!
         build-all-aiarena-zips!)

(define-runtime-path LADDER-DIR ".")
(define ROOT-DIR (simplify-path (build-path LADDER-DIR "..")))
(define CACHE-DIR (build-path LADDER-DIR ".cache"))
(define PORTABLE-RUNTIME-DIR (build-path CACHE-DIR "racket_runtime"))
(define PORTABLE-RACKET-BIN  (build-path PORTABLE-RUNTIME-DIR "bin" "racket"))
(define PORTABLE-RUNTIME-TAR (build-path CACHE-DIR "racket_runtime.tar.xz"))
(define PORTABLE-ETC-DIR     (build-path CACHE-DIR "portable-etc"))
(define WORKSPACE-CODE-DIRS
  '("compiled" "sc-bot" "compiler" "lib" "sim" "bots" "ffi" "ladder" "tools"))

;; AI Arena BotZip size limits:
;; - Standard tier max upload: 50 MiB (52,428,800 bytes)
;; - Bronze Patreon max upload: 100 MiB (104,857,600 bytes)
;; - Strict repository safety budget: 35 MB (35,000,000 bytes) max, 3 MB (3,000,000 bytes) min
;; - True untethered Racket CS ELF (.rackboot + .rackprog, original-exe?=#t): >= 45 MB uncompressed
(define AIARENA-STANDARD-MAX-ZIP-BYTES (* 50 1024 1024))
(define AIARENA-BRONZE-MAX-ZIP-BYTES   (* 100 1024 1024))
(define MAX-BOT-ZIP-SIZE-BYTES         35000000)
(define MIN-BOT-ZIP-SIZE-BYTES         3000000)
(define MIN-STANDALONE-ELF-BYTES       45000000)

(define INCLUDE-DIRS '("sc-bot" "compiler" "lib" "sim" "bots" "ffi"))
(define INCLUDE-TOP-FILES '("run.py" "main.rkt" "info.rkt"))

(define VARIANTS
  '(("Mothman-X" "Random"  "bots/Mothman-R.rkt")
    ("Mothman-Z" "Zerg"    "bots/Mothman-Z.rkt")
    ("Mothman-T" "Terran"  "bots/Mothman-T.rkt")
    ("Mothman-P" "Protoss" "bots/Mothman-P.rkt")))

;; -----------------------------------------------------------------------------
;; 1. IEEE 802.3 CRC-32 & Pure-Racket PKZIP Archive Writer
;; -----------------------------------------------------------------------------

(define CRC32-TABLE
  (for/vector ([n (in-range 256)])
    (for/fold ([c n]) ([_k (in-range 8)])
      (if (bitwise-bit-set? c 0)
          (bitwise-xor #xedb88320 (arithmetic-shift c -1))
          (arithmetic-shift c -1)))))

(define (bytes-crc32 bstr)
  (define c
    (for/fold ([acc #xffffffff]) ([b (in-bytes bstr)])
      (define idx (bitwise-and (bitwise-xor acc b) #xff))
      (bitwise-xor (vector-ref CRC32-TABLE idx)
                   (arithmetic-shift acc -8))))
  (bitwise-and (bitwise-not c) #xffffffff))

(define (deflate-bytes raw-bstr)
  (define in (open-input-bytes raw-bstr))
  (define out (open-output-bytes))
  (deflate in out)
  (get-output-bytes out))

(define (write-u16le v out)
  (write-bytes (integer->integer-bytes (bitwise-and v #xffff) 2 #f #f) out))

(define (write-u32le v out)
  (write-bytes (integer->integer-bytes (bitwise-and v #xffffffff) 4 #f #f) out))

(struct zip-entry-spec (name raw-len crc final-bstr final-len method unix-mode) #:transparent)
(struct cd-record (name-bytes method crc comp-len raw-len unix-mode local-offset) #:transparent)

(define (make-zip-entry-spec name raw-bstr store-only? unix-mode)
  (define raw-len (bytes-length raw-bstr))
  (define crc (bytes-crc32 raw-bstr))
  (define store? (or store-only? (< raw-len 64)))
  (define comp-bstr (if store? raw-bstr (deflate-bytes raw-bstr)))
  (define use-store? (or store? (>= (bytes-length comp-bstr) raw-len)))
  (define final-bstr (if use-store? raw-bstr comp-bstr))
  (define final-len (bytes-length final-bstr))
  (define method (if use-store? 0 8))
  (zip-entry-spec name raw-len crc final-bstr final-len method unix-mode))

(define (write-pkzip-archive! zip-path entries)
  (make-parent-directory* zip-path)
  (call-with-output-file zip-path
    #:exists 'replace
    (lambda (out)
      (define cd-records '())
      (for ([ent (in-list entries)])
        (define name-bstr (string->bytes/utf-8 (zip-entry-spec-name ent)))
        (define raw-len (zip-entry-spec-raw-len ent))
        (define crc (zip-entry-spec-crc ent))
        (define final-bstr (zip-entry-spec-final-bstr ent))
        (define final-len (zip-entry-spec-final-len ent))
        (define method (zip-entry-spec-method ent))
        (define local-offset (file-position out))

        ;; Local file header (#x04034b50)
        (write-u32le #x04034b50 out)
        (write-u16le 20 out)               ; version needed to extract (2.0)
        (write-u16le 0 out)                ; general purpose bit flag
        (write-u16le method out)           ; compression method (0=STORED, 8=DEFLATED)
        (write-u16le #x0000 out)           ; last mod file time
        (write-u16le #x5967 out)           ; last mod file date (2024-11-07)
        (write-u32le crc out)              ; crc-32
        (write-u32le final-len out)        ; compressed size
        (write-u32le raw-len out)          ; uncompressed size
        (write-u16le (bytes-length name-bstr) out)
        (write-u16le 0 out)                ; extra field length
        (write-bytes name-bstr out)
        (write-bytes final-bstr out)

        (set! cd-records
              (cons (cd-record name-bstr
                               method
                               crc
                               final-len
                               raw-len
                               (zip-entry-spec-unix-mode ent)
                               local-offset)
                    cd-records)))

      (define cd-start (file-position out))
      (for ([r (in-list (reverse cd-records))])
        (define name-bstr (cd-record-name-bytes r))
        ;; Central directory file header (#x02014b50)
        (write-u32le #x02014b50 out)
        (write-u16le #x031e out)           ; version made by: Unix (3), PKZIP 3.0
        (write-u16le 20 out)               ; version needed to extract
        (write-u16le 0 out)                ; flags
        (write-u16le (cd-record-method r) out)
        (write-u16le #x0000 out)           ; time
        (write-u16le #x5967 out)           ; date
        (write-u32le (cd-record-crc r) out)
        (write-u32le (cd-record-comp-len r) out)
        (write-u32le (cd-record-raw-len r) out)
        (write-u16le (bytes-length name-bstr) out)
        (write-u16le 0 out)                ; extra length
        (write-u16le 0 out)                ; comment length
        (write-u16le 0 out)                ; disk number start
        (write-u16le 0 out)                ; internal file attributes
        (write-u32le (arithmetic-shift (cd-record-unix-mode r) 16) out) ; external Unix mode
        (write-u32le (cd-record-local-offset r) out)
        (write-bytes name-bstr out))

      (define cd-end (file-position out))
      (define cd-size (- cd-end cd-start))
      (define total-entries (length cd-records))

      ;; End of central directory record (#x06054b50)
      (write-u32le #x06054b50 out)
      (write-u16le 0 out)
      (write-u16le 0 out)
      (write-u16le total-entries out)
      (write-u16le total-entries out)
      (write-u32le cd-size out)
      (write-u32le cd-start out)
      (write-u16le 0 out))))

;; -----------------------------------------------------------------------------
;; 2. Hermetic Portable Racket 8.16 Runtime & Clean `.zo` Bytecode Compilation
;; -----------------------------------------------------------------------------

(define (clean-compiled-zo-tree!)
  ;; Purge .zo/.dep files outside ladder/.cache only when they contain hardcoded
  ;; host paths (`/home/` or `/Users/`), keeping clean incremental bytecode caches intact.
  (for ([entry (in-list WORKSPACE-CODE-DIRS)])
    (define p (build-path ROOT-DIR entry))
    (cond
      [(equal? entry "compiled")
       (when (directory-exists? p)
         (delete-directory/files p))]
      [(directory-exists? p)
       (for ([sub (in-directory
                   p
                   (lambda (dir)
                     (define bn (file-name-from-path dir))
                     (not (equal? (and bn (path->string bn)) ".cache"))))])
         (when (file-exists? sub)
           (define s (path->string sub))
           (when (and (string-contains? s "/compiled/")
                      (or (string-suffix? s ".zo")
                          (string-suffix? s ".dep"))
                      (regexp-match? #rx#"/(?:home|Users)/" (file->bytes sub)))
             (delete-file sub))))])))

(define (ensure-portable-racket-815-runtime!)
  (unless (file-exists? PORTABLE-RACKET-BIN)
    (unless (file-exists? PORTABLE-RUNTIME-TAR)
      (error 'ensure-portable-racket-815-runtime!
             "Missing bundled portable Racket archive: ~a"
             PORTABLE-RUNTIME-TAR))
    (define tar-exe (find-executable-path "tar"))
    (unless tar-exe
      (error 'ensure-portable-racket-815-runtime! "Could not locate 'tar' executable"))
    (printf "[0/5] Unpacking bundled portable Racket 8.16 runtime (~a)...\n"
            (path->string PORTABLE-RUNTIME-TAR))
    (unless (system* tar-exe "-xf" (path->string PORTABLE-RUNTIME-TAR)
                     "-C" (path->string CACHE-DIR))
      (error 'ensure-portable-racket-815-runtime!
             "Failed to unpack ~a into ~a"
             PORTABLE-RUNTIME-TAR CACHE-DIR))
    (unless (file-exists? PORTABLE-RACKET-BIN)
      (error 'ensure-portable-racket-815-runtime!
             "Unpacked archive did not produce ~a"
             PORTABLE-RACKET-BIN)))
  (with-handlers ([exn:fail? void])
    (file-or-directory-permissions PORTABLE-RACKET-BIN #o755))
  (make-directory* PORTABLE-ETC-DIR)
  (define host-cfg-file (build-path (find-config-dir) "config.rktd"))
  (define host-cfg
    (if (file-exists? host-cfg-file)
        (let ([v (call-with-input-file host-cfg-file read)])
          (if (hash? v) v (hash)))
        (hash)))
  (define updated-cfg
    (hash-set host-cfg 'bin-dir (path->string (simplify-path (build-path PORTABLE-RUNTIME-DIR "bin")))))
  (call-with-output-file (build-path PORTABLE-ETC-DIR "config.rktd")
    #:exists 'replace
    (lambda (out)
      (write updated-cfg out)
      (newline out)))
  PORTABLE-RACKET-BIN)

(define (discover-sorted-sub-rkt-relpaths subdir)
  (define d (build-path ROOT-DIR subdir))
  (if (directory-exists? d)
      (sort
       (for/list ([p (in-directory d)]
                  #:when (and (file-exists? p)
                              (let ([s (path->string p)])
                                (and (string-suffix? s ".rkt")
                                     (not (string-contains? s "/compiled/"))))))
         (path->string (find-relative-path ROOT-DIR p)))
       string<?)
      '()))

(define (precompile-all-racket-zo!)
  (printf "[1/5] Precompiling Racket modules to .zo bytecode via compiler/cm (Racket ~a)...\n"
          (version))
  (current-directory ROOT-DIR)
  (clean-compiled-zo-tree!)
  (define build-order-subfiles (discover-sorted-sub-rkt-relpaths "lib/build-orders"))
  (define tactic-subfiles (discover-sorted-sub-rkt-relpaths "lib/tactics"))
  (define lib-all-subfiles (discover-sorted-sub-rkt-relpaths "lib"))
  (define ordered-core-targets
    (append
     '("main.rkt"
       "compiler/syntax.rkt"
       ;; Layer 0
       "lib/sc2-types.rkt"
       "lib/sc2-common.rkt"
       "lib/sc2-game-constants.rkt")
     ;; Layer 1
     build-order-subfiles
     '("lib/build-orders.rkt"
       "lib/sc2-bayesian.rkt"
       "lib/sc2-geometry.rkt"
       "lib/sc2-pathing.rkt"
       "lib/sc2-logging.rkt"
       "lib/sc2-proto-wire-verifier.rkt"
       "lib/sc2-typed-commands.rkt"
       ;; Layer 2
       "lib/perception-grid.rkt"
       "lib/sc2-placement.rkt"
       "lib/sc2-combat-eval.rkt")
     tactic-subfiles
     '(;; Layer 3
       "lib/econ-ledger.rkt"
       "lib/priority-macro-brain.rkt"
       "lib/mirror-mind-predictor.rkt"
       "lib/human-cortex.rkt"
       "lib/tactics-sim.rkt"
       ;; Layer 4 + tooling/runtime libraries
       "lib/sc2-mpq-replay-parser.rkt"
       "lib/pro-replay-starvation-audit.rkt"
       "lib/bot-runtime.rkt"
       "lib/state-machine-verifier.rkt"
       "lib/bot-crash-fuzzer.rkt"
       "lib/sc2-protobuf-ws.rkt")
     ;; Ensure any future lib/ submodules are also compiled
     lib-all-subfiles
     '("sim/racket_sc2_ipc_bot.rkt"
       "sim/racket-sc2-ladder-main.rkt"
       "bots/Mothman.rkt"
       "bots/Mothman-Z.rkt"
       "bots/Mothman-T.rkt"
       "bots/Mothman-P.rkt"
       "bots/Mothman-R.rkt")))
  (define targets (remove-duplicates ordered-core-targets string=?))
  (parameterize ([current-directory-for-user ROOT-DIR]
                 [current-write-relative-directory (cons ROOT-DIR ROOT-DIR)])
    (for ([rel (in-list targets)])
      (define p (build-path ROOT-DIR rel))
      (when (file-exists? p)
        (managed-compile-zo p))))
  (printf "  -> All .zo bytecode modules up to date (~a targets).\n" (length targets))
  #t)

;; -----------------------------------------------------------------------------
;; 2b. Untethered Standalone Native Linux x86_64 ELF Compilation (`compiler/embed`)
;;     Passes `#:aux '((original-exe? . #t) (config-dir . #<path:etc>))` and
;;     `#:collects-path "collects"` so `create-embedding-executable` embeds
;;     both `.rackboot` (Chez Scheme + Racket CS kernel/boot images) and
;;     `.rackprog` (all `#lang sc-bot` modules) directly into the full ELF
;;     executable instead of a `starter` wrapper that looks for a host `racket`.
;; -----------------------------------------------------------------------------

(define (resolve-host-racket-bin)
  (define exec-f (find-system-path 'exec-file))
  (or (and (absolute-path? exec-f) (file-exists? exec-f) exec-f)
      (find-executable-path exec-f)
      (find-executable-path "racket")
      (string->path "/usr/bin/racket")))

(define (compile-standalone-racket-elf!)
  (make-directory* CACHE-DIR)
  (current-directory ROOT-DIR)
  (define out-bin (build-path CACHE-DIR "mothman_standalone_elf"))
  (printf "[2/5] Compiling untethered standalone native Linux x86_64 ELF via compiler/embed (Racket ~a)...\n"
          (version))
  ;; Invoke compiler/embed in a fresh subprocess so preloaded Typed Racket modules
  ;; in this builder process cannot trigger `(submod prims-contract.rkt forms)` redefinition.
  (define root-str (path->string (simplify-path ROOT-DIR)))
  (define out-str (path->string (simplify-path out-bin)))
  (define embed-expr
    `(begin
       (require compiler/embed)
       (define d (simplify-path (string->path ,root-str)))
       (parameterize ([current-directory d]
                      [current-directory-for-user d]
                      [current-write-relative-directory (cons d d)])
         (create-embedding-executable
          (string->path ,out-str)
          #:aux (list (cons 'original-exe? #t)
                      (cons 'config-dir (string->path "etc")))
          #:collects-path "collects"
          #:modules (list (list #f "sim/racket-sc2-ladder-main.rkt" '(main))
                          (list #f "bots/Mothman-Z.rkt")
                          (list #f "bots/Mothman-T.rkt")
                          (list #f "bots/Mothman-P.rkt")
                          (list #f "bots/Mothman-R.rkt")
                          (list #f "bots/Mothman.rkt"))
          #:configure-via-first-module? #t
          #:literal-expression
          (parameterize ([current-namespace (make-base-namespace)])
            (compile '(namespace-require '(submod 'racket-sc2-ladder-main main))))
          #:cmdline '("-U" "--")))))
  (unless (parameterize ([current-directory ROOT-DIR])
            (system* (resolve-host-racket-bin) "-e" (format "~s" embed-expr)))
    (error 'compile-standalone-racket-elf!
           "Subprocess compiler/embed failed for ~a"
           out-str))
  (validate-elf-portability! (file->bytes out-bin) "mothman_standalone_elf" out-bin)
  (file-or-directory-permissions out-bin #o755)
  out-bin)

;; -----------------------------------------------------------------------------
;; 2c. Headless Bot Initialization Verification (`verify-standalone-elf-headless-init!`)
;;     Launches the built standalone ELF in an isolated AI-Arena-like working
;;     directory against `start-embedded-sc2-protobuf-server!` over WebSocket
;;     and verifies full runtime initialization and stepping (`steps_executed >= 1`).
;; -----------------------------------------------------------------------------

(define (verify-standalone-elf-headless-init! elf-path)
  (printf "[3/5] Running headless initialization verification on ~a...\n"
          (path->string elf-path))
  (define probe-dir (build-path CACHE-DIR "init_probe"))
  (define probe-bin (build-path probe-dir "Mothman-Z"))
  (define probe-cfg (build-path probe-dir "config.json"))
  (define port (pick-free-local-port))
  (define srv #f)
  (dynamic-wind
    (lambda ()
      (when (directory-exists? probe-dir)
        (delete-directory/files probe-dir))
      (make-directory* (build-path probe-dir "data"))
      (copy-file elf-path probe-bin #t)
      (file-or-directory-permissions probe-bin #o755)
      (call-with-output-file probe-cfg
        #:exists 'replace
        (lambda (out)
          (display "{\n  \"BotName\": \"Mothman-Z\",\n  \"BotRace\": \"Zerg\",\n  \"BotPath\": \"bots/Mothman-Z.rkt\"\n}\n"
                   out)))
      (call-with-output-file (build-path probe-dir "data" "mirror_mind_opponents.json")
        #:exists 'replace
        (lambda (out)
          (display "{\n  \"bot_name\": \"Mothman-Z\",\n  \"opponents\": {}\n}\n" out)))
      (set! srv (start-embedded-sc2-protobuf-server!
                 port #:our-race "Zerg" #:computer-race "Protoss")))
    (lambda ()
      (define-values (proc stdout-in stdin-out stderr-in)
        (parameterize ([current-directory probe-dir])
          (subprocess #f #f #f
                      probe-bin
                      "--GamePort" (number->string port)
                      "--StartPort" (number->string port)
                      "--LadderServer" "127.0.0.1"
                      "--OpponentId" "headless_init_verify"
                      "--max-loops" "16")))
      (close-output-port stdin-out)
      (define err-box (box ""))
      (define err-thd
        (thread (lambda ()
                  (set-box! err-box (port->string stderr-in)))))
      (define out-str (port->string stdout-in))
      (thread-wait err-thd)
      (define err-str (unbox err-box))
      (close-input-port stdout-in)
      (close-input-port stderr-in)
      (define wait-thd (thread (lambda () (subprocess-wait proc))))
      (unless (sync/timeout 25 wait-thd)
        (with-handlers ([exn:fail? void]) (subprocess-kill proc #t))
        (error 'verify-standalone-elf-headless-init!
               "Standalone ELF timed out after 25s during headless initialization!\nstdout:\n~a\nstderr:\n~a"
               out-str err-str))
      (define rc (subprocess-status proc))
      (unless (zero? rc)
        (error 'verify-standalone-elf-headless-init!
               "Standalone ELF exited with code ~a during headless initialization!\nstdout:\n~a\nstderr:\n~a"
               rc out-str err-str))
      (define summary
        (for/or ([line (in-list (reverse (string-split out-str "\n")))])
          (define trimmed (string-trim line))
          (and (string-prefix? trimmed "{")
               (with-handlers ([exn:fail? (lambda (_e) #f)])
                 (string->jsexpr trimmed)))))
      (unless (and (hash? summary)
                   (equal? (hash-ref summary 'status #f) "MATCH_COMPLETED")
                   (>= (hash-ref summary 'steps_executed 0) 1))
        (error 'verify-standalone-elf-headless-init!
               "Standalone ELF failed headless initialization handshake!\nstdout:\n~a\nstderr:\n~a"
               out-str err-str))
      (printf "  -> Headless init verified: status=~a, steps=~a, game_loops=~a, engine=~a\n"
              (hash-ref summary 'status)
              (hash-ref summary 'steps_executed)
              (hash-ref summary 'game_loops)
              (hash-ref summary 'engine))
      summary)
    (lambda ()
      (when (hash? srv)
        (define stop! (hash-ref srv 'stop! #f))
        (when (procedure? stop!) (stop!)))
      (with-handlers ([exn:fail? void])
        (when (directory-exists? probe-dir)
          (delete-directory/files probe-dir))))))

;; -----------------------------------------------------------------------------
;; 3. Collect Common Files, Validate Size/Binary Bounds & Build Each Variant Zip
;; -----------------------------------------------------------------------------

(define (bytes-contains-subbytes? haystack needle)
  (not (not (regexp-match-positions (regexp-quote needle) haystack))))

(define (validate-elf-portability! elf-bytes bot-name [artifact-label elf-bytes])
  (unless (and (>= (bytes-length elf-bytes) MIN-STANDALONE-ELF-BYTES)
               (bytes=? (subbytes elf-bytes 0 4) #"\x7fELF")
               (bytes-contains-subbytes? elf-bytes #".rackboot")
               (bytes-contains-subbytes? elf-bytes #".rackprog")
               (not (bytes-contains-subbytes? elf-bytes #"cOnFiG:"))
               (not (bytes-contains-subbytes? elf-bytes #"failed to start "))
               (not (bytes-contains-subbytes? elf-bytes #"coLLECTs dIRECTORy:/home/"))
               (not (bytes-contains-subbytes? elf-bytes #"coNFIg dIRECTORy:/home/"))
               (not (regexp-match? #rx#"GLIBC_2\\.(?:1[5-9]|[2-9][0-9])" elf-bytes))
               (not (bytes-contains-subbytes? elf-bytes #"libxxhash.so"))
               (not (bytes-contains-subbytes? elf-bytes #"liblz4.so"))
               (not (bytes-contains-subbytes? elf-bytes #"libtinfo.so"))
               (not (bytes-contains-subbytes? elf-bytes #"/home/")))
    (error 'validate-bot-zip-archive!
           "Artifact ~a executable ~a is not a portable untethered Racket CS ELF binary (max GLIBC_2.14, .rackboot + .rackprog, no libxxhash/liblz4/libtinfo or /home/ paths)"
           artifact-label bot-name)))

(define (validate-bot-zip-archive! zip-path
                                   #:bot-name [bot-name #f]
                                   #:elf-bytes [elf-bytes #f]
                                   #:entry-names [entry-names '()]
                                   #:max-bytes [max-bytes MAX-BOT-ZIP-SIZE-BYTES]
                                   #:min-bytes [min-bytes MIN-BOT-ZIP-SIZE-BYTES])
  (unless (file-exists? zip-path)
    (error 'validate-bot-zip-archive! "BotZip archive does not exist: ~a" zip-path))
  (define sz (file-size zip-path))
  (when (> sz AIARENA-STANDARD-MAX-ZIP-BYTES)
    (error 'validate-bot-zip-archive!
           "BotZip ~a (~a bytes) exceeds AI Arena 50 MiB standard upload limit (~a bytes)"
           zip-path sz AIARENA-STANDARD-MAX-ZIP-BYTES))
  (when (> sz max-bytes)
    (error 'validate-bot-zip-archive!
           "BotZip ~a (~a bytes) exceeds strict safety budget (~a bytes)"
           zip-path sz max-bytes))
  (when (< sz min-bytes)
    (error 'validate-bot-zip-archive!
           "BotZip ~a (~a bytes) is smaller than minimum standalone ELF archive floor (~a bytes)"
           zip-path sz min-bytes))
  (when elf-bytes
    (validate-elf-portability! elf-bytes bot-name zip-path))
  (for ([ename (in-list entry-names)])
    (when (or (string-suffix? ename ".zip")
              (string-suffix? ename ".SC2Replay")
              (string-suffix? ename ".tar.xz"))
      (error 'validate-bot-zip-archive!
             "BotZip ~a contains forbidden nested archive/replay artifact: ~a"
             zip-path ename)))
  #t)

(define (collect-shared-tree-entries)
  (define specs '())
  (define seen (make-hash))
  (define (add-spec! arcname bstr store? mode)
    (unless (hash-has-key? seen arcname)
      (hash-set! seen arcname #t)
      (set! specs (cons (make-zip-entry-spec arcname bstr store? mode) specs))))

  ;; Top-level files
  (for ([top-f (in-list INCLUDE-TOP-FILES)])
    (define p (build-path ROOT-DIR top-f))
    (when (file-exists? p)
      (define mode (if (equal? top-f "run.py") #o100755 #o100644))
      (add-spec! top-f (file->bytes p) #f mode)))

  ;; Source files (excluding compiled/ bytecode caches, lakefillq*, and offline-only audit/fuzzer modules)
  (for ([dname (in-list INCLUDE-DIRS)])
    (define dpath (build-path ROOT-DIR dname))
    (when (directory-exists? dpath)
      (for ([p (in-directory dpath)])
        (when (file-exists? p)
          (define rel (path->string (find-relative-path ROOT-DIR p)))
          (unless (or (string-contains? rel "__pycache__")
                      (string-contains? rel "/compiled/")
                      (string-contains? rel "/.git/")
                      (string-suffix? rel ".pyc")
                      (string-suffix? rel ".o")
                      (string-suffix? rel ".zip")
                      (string-suffix? rel ".SC2Replay")
                      (string-suffix? rel ".tar.xz")
                      (string-prefix? rel "compiler/lakefillq")
                      (member rel
                              '("lib/bot-crash-fuzzer.rkt"
                                "lib/state-machine-verifier.rkt"
                                "lib/sc2-mpq-replay-parser.rkt"
                                "lib/pro-replay-starvation-audit.rkt"))
                      ;; In `sc-bot/`, only pack `sc-bot/main.rkt`
                      (and (string-prefix? rel "sc-bot/")
                           (not (equal? rel "sc-bot/main.rkt"))))
            (define store? (string-suffix? rel ".so"))
            (add-spec! rel (file->bytes p) store? #o100644))))))

  (reverse specs))

(define (build-variant-zip! bot-name bot-race bot-path elf-bstr shared-entries)
  (define zip-path (build-path LADDER-DIR (format "~a.zip" bot-name)))
  (define config-bstr
    (string->bytes/utf-8
      (format "{\n  \"BotName\": ~s,\n  \"BotRace\": ~s,\n  \"BotPath\": ~s\n}\n"
              bot-name bot-race bot-path)))
  (define seed-data-bstr
    (string->bytes/utf-8
      (format "{\n  \"bot_name\": ~s,\n  \"opponents\": {}\n}\n"
              bot-name)))
  (define header-entries
    (list (make-zip-entry-spec "config.json" config-bstr #f #o100644)
          (make-zip-entry-spec bot-name elf-bstr #f #o100755)
          (make-zip-entry-spec "data/mirror_mind_opponents.json" seed-data-bstr #f #o100644)))
  (define all-entries (append header-entries shared-entries))
  (write-pkzip-archive! zip-path all-entries)
  (validate-bot-zip-archive! zip-path
                             #:bot-name bot-name
                             #:elf-bytes elf-bstr
                             #:entry-names (map zip-entry-spec-name all-entries))
  (define sz (file-size zip-path))
  (define sz-mb (/ (round (* 100.0 (/ sz (* 1024.0 1024.0)))) 100.0))
  (printf "  -> Built ~a (~a MB, ~a files, standalone ELF=~a MB)\n"
          (path->string zip-path)
          sz-mb
          (length all-entries)
          (/ (round (* 100.0 (/ (bytes-length elf-bstr) (* 1024.0 1024.0)))) 100.0))
  (hash 'bot_name bot-name
        'race bot-race
        'bot_path bot-path
        'zip_path (path->string zip-path)
        'files_added (length all-entries)
        'size_bytes sz
        'size_mb sz-mb
        'standalone_elf_bytes (bytes-length elf-bstr)
        'cpplinux_binary_included #t))

(define (binary-non-portable? path-or-false)
  (define b (and path-or-false (file-exists? path-or-false) (file->bytes path-or-false)))
  (or (not b)
      (regexp-match? #rx#"GLIBC_2\\.(?:1[5-9]|[2-9][0-9])" b)
      (bytes-contains-subbytes? b #"libxxhash.so")
      (bytes-contains-subbytes? b #"liblz4.so")))

(define (host-non-portable-racket?)
  (define target-exe
    (with-handlers ([exn:fail? (lambda (_e) #f)])
      (find-exe #:cross? #t #:untethered? #t #f 'cs)))
  (binary-non-portable? target-exe))

(define (build-all-aiarena-zips! [target-variant #f])
  (define selected-variants
    (if target-variant
        (filter (lambda (row) (equal? (first row) target-variant)) VARIANTS)
        VARIANTS))
  (cond
    [(host-non-portable-racket?)
     (void (ensure-portable-racket-815-runtime!))
     (define script-path (path->string (build-path LADDER-DIR "build-aiarena-zip.rkt")))
     (define host-racket-bin (resolve-host-racket-bin))
     (define cli-args
       (cons script-path
             (if target-variant
                 (list "--variant" target-variant)
                 (list "--all-races"))))
     (putenv "PLTCONFIGDIR" (path->string (simplify-path PORTABLE-ETC-DIR)))
     (printf "[0/5] Re-launching BotZip build with PLTCONFIGDIR=~a targeting portable Racket 8.16...\n"
             (getenv "PLTCONFIGDIR"))
     (unless (apply system* host-racket-bin cli-args)
       (error 'build-all-aiarena-zips!
              "Portable Racket 8.16 BotZip build failed (exit non-zero)"))
     (define elf-bytes-len (file-size (build-path CACHE-DIR "mothman_standalone_elf")))
     (for/list ([row (in-list selected-variants)])
       (define bname (first row))
       (define zpath (build-path LADDER-DIR (format "~a.zip" bname)))
       (define sz (file-size zpath))
       (hash 'bot_name bname
             'race (second row)
             'bot_path (third row)
             'zip_path (path->string zpath)
             'size_bytes sz
             'size_mb (/ (round (* 100.0 (/ sz (* 1024.0 1024.0)))) 100.0)
             'standalone_elf_bytes elf-bytes-len
             'cpplinux_binary_included #t))]
    [else
     (precompile-all-racket-zo!)
     (define elf-path (compile-standalone-racket-elf!))
     (verify-standalone-elf-headless-init! elf-path)
     (printf "[4/5] Building AI Arena BotZip archives in pure Racket...\n")
     (define elf-bstr (file->bytes elf-path))
     (define shared-entries (collect-shared-tree-entries))
     (define results
       (for/list ([row (in-list selected-variants)])
         (build-variant-zip! (first row) (second row) (third row) elf-bstr shared-entries)))
     (printf "[5/5] Verified ~a AI Arena BotZip archives (all <= ~a MB limit) + headless init OK.\n"
             (length results)
             (/ MAX-BOT-ZIP-SIZE-BYTES 1000000.0))
     results]))

(module+ main
  (define target-variant #f)
  (command-line
   #:program "build-aiarena-zip.rkt"
   #:once-each
   [("--all-races") "Build all active race-specific zips (Mothman-X/Z/T/P)" (void)]
   [("--variant") v "Build a single variant only" (set! target-variant v)])
  (void (build-all-aiarena-zips! target-variant)))
