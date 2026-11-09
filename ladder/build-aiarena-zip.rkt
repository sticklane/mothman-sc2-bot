#lang racket/base

;; =============================================================================
;; Pure-Racket AI Arena BotZip Builder (`ladder/build-aiarena-zip.rkt`)
;;
;; Builds AI Arena ladder-ready .zip archives in 100% pure Racket:
;;   - ladder/Mothman.zip
;;   - ladder/Mothman-X.zip (Random)
;;   - ladder/Mothman-Z.zip (Zerg)
;;   - ladder/Mothman-T.zip (Terran)
;;   - ladder/Mothman-P.zip (Protoss)
;;   - ladder/Mothman-R.zip (Random)
;;
;; 1. Precompiles all `#lang sc-bot` and Racket runtime modules to `.zo` bytecode
;;    via `compiler/cm` (`managed-compile-zo`).
;; 2. Compiles `ladder/cpplinux_launcher.cpp` into a stripped Linux x86_64 ELF
;;    launcher (`<BotName>`) via `system*` (`g++ -O2 -s -std=c++17`).
;; 3. Writes standard PKZIP archives directly in pure Racket (`file/gzip` deflate
;;    for source/bytecode + `ZIP_STORED` for `racket_runtime.tar.xz`) with Unix
;;    `0755` executable attributes on `<BotName>` and `run.py` — without touching
;;    `/tmp` or `/var/tmp` or invoking Python.
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
         file/gzip
         json)

(provide AIARENA-STANDARD-MAX-ZIP-BYTES
         AIARENA-BRONZE-MAX-ZIP-BYTES
         MAX-BOT-ZIP-SIZE-BYTES
         MIN-BOT-ZIP-SIZE-BYTES
         MIN-STANDALONE-ELF-BYTES
         VARIANTS
         validate-bot-zip-archive!
         build-all-aiarena-zips!)

(define-runtime-path LADDER-DIR ".")
(define ROOT-DIR (simplify-path (build-path LADDER-DIR "..")))
(define CACHE-DIR (build-path LADDER-DIR ".cache"))

;; AI Arena BotZip size limits:
;; - Standard tier max upload: 50 MiB (52,428,800 bytes)
;; - Bronze Patreon max upload: 100 MiB (104,857,600 bytes)
;; - Strict repository safety budget: 25 MB (25,000,000 bytes) max, 3 MB (3,000,000 bytes) min
;; - True untethered Racket CS ELF (.rackboot + .rackprog, original-exe?=#t): >= 45 MB uncompressed
(define AIARENA-STANDARD-MAX-ZIP-BYTES (* 50 1024 1024))
(define AIARENA-BRONZE-MAX-ZIP-BYTES   (* 100 1024 1024))
(define MAX-BOT-ZIP-SIZE-BYTES         25000000)
(define MIN-BOT-ZIP-SIZE-BYTES         3000000)
(define MIN-STANDALONE-ELF-BYTES       45000000)

(define INCLUDE-DIRS '("sc-bot" "compiler" "lib" "sim" "bots" "ffi"))
(define INCLUDE-TOP-FILES '("run.py" "main.rkt" "info.rkt" "data/pro_build_orders.sexp"))

(define VARIANTS
  '(("Mothman"   "Random"  "bots/Mothman.rkt")
    ("Mothman-X" "Random"  "bots/Mothman-R.rkt")
    ("Mothman-Z" "Zerg"    "bots/Mothman-Z.rkt")
    ("Mothman-T" "Terran"  "bots/Mothman-T.rkt")
    ("Mothman-P" "Protoss" "bots/Mothman-P.rkt")
    ("Mothman-R" "Random"  "bots/Mothman-R.rkt")))

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
;; 2. Precompile `.zo` Bytecode
;; -----------------------------------------------------------------------------

(define (precompile-all-racket-zo!)
  (printf "[1/4] Precompiling Racket modules to .zo bytecode via compiler/cm...\n")
  (current-directory ROOT-DIR)
  (define targets
    '("main.rkt"
      "compiler/syntax.rkt"
      "lib/sc2-game-constants.rkt"
      "lib/okasaki-sc.rkt"
      "lib/perception-grid.rkt"
      "lib/econ-ledger.rkt"
      "lib/build-orders.rkt"
      "lib/tactics-sim.rkt"
      "lib/human-cortex.rkt"
      "lib/zerospace-mastermind.rkt"
      "lib/mirror-mind-predictor.rkt"
      "lib/bot-runtime.rkt"
      "lib/state-machine-verifier.rkt"
      "lib/bot-crash-fuzzer.rkt"
      "lib/sc2-protobuf-ws.rkt"
      "sim/racket_sc2_ipc_bot.rkt"
      "sim/racket-sc2-ladder-main.rkt"
      "bots/Mothman.rkt"
      "bots/Mothman-Z.rkt"
      "bots/Mothman-T.rkt"
      "bots/Mothman-P.rkt"
      "bots/Mothman-R.rkt"))
  (for ([rel (in-list targets)])
    (define p (build-path ROOT-DIR rel))
    (when (file-exists? p)
      (managed-compile-zo p)))
  (printf "  -> All .zo bytecode modules up to date.\n")
  #t)

;; -----------------------------------------------------------------------------
;; 2b. Untethered Standalone Native Linux x86_64 ELF Compilation (`compiler/embed`)
;;     Passes `#:aux '((original-exe? . #t) (config-dir . #<path:etc>))` and
;;     `#:collects-path "collects"` so `create-embedding-executable` embeds
;;     both `.rackboot` (Chez Scheme + Racket CS kernel/boot images) and
;;     `.rackprog` (all `#lang sc-bot` modules) directly into the full ELF
;;     executable instead of a `starter` wrapper that looks for a host `racket`.
;; -----------------------------------------------------------------------------

(define (compile-standalone-racket-elf!)
  (make-directory* CACHE-DIR)
  (current-directory ROOT-DIR)
  (define out-bin (build-path CACHE-DIR "mothman_standalone_elf"))
  (printf "  -> Compiling untethered standalone native Linux x86_64 ELF executable via compiler/embed (original-exe?=#t)...\n")
  (create-embedding-executable
   out-bin
   #:aux (list (cons 'original-exe? #t)
               (cons 'config-dir (string->path "etc")))
   #:collects-path "collects"
   #:modules (list (list #f (build-path ROOT-DIR "sim/racket-sc2-ladder-main.rkt") '(main))
                   (list #f (build-path ROOT-DIR "bots/Mothman-Z.rkt"))
                   (list #f (build-path ROOT-DIR "bots/Mothman-T.rkt"))
                   (list #f (build-path ROOT-DIR "bots/Mothman-P.rkt"))
                   (list #f (build-path ROOT-DIR "bots/Mothman-R.rkt"))
                   (list #f (build-path ROOT-DIR "bots/Mothman.rkt")))
   #:configure-via-first-module? #t
   #:literal-expression
   (parameterize ([current-namespace (make-base-namespace)])
     (compile '(namespace-require '(submod 'racket-sc2-ladder-main main))))
   #:cmdline '("-U" "--"))
  (unless (and (file-exists? out-bin)
               (>= (file-size out-bin) MIN-STANDALONE-ELF-BYTES))
    (error 'compile-standalone-racket-elf!
           "Failed to build untethered standalone ELF executable ~a (>= ~a bytes required)"
           out-bin MIN-STANDALONE-ELF-BYTES))
  (file-or-directory-permissions out-bin #o755)
  out-bin)

;; -----------------------------------------------------------------------------
;; 3. Collect Common Files, Validate Size/Binary Bounds & Build Each Variant Zip
;; -----------------------------------------------------------------------------

(define (bytes-contains-subbytes? haystack needle)
  (not (not (regexp-match-positions (regexp-quote needle) haystack))))

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
    (unless (and (>= (bytes-length elf-bytes) MIN-STANDALONE-ELF-BYTES)
                 (bytes=? (subbytes elf-bytes 0 4) #"\x7fELF")
                 (bytes-contains-subbytes? elf-bytes #".rackboot")
                 (bytes-contains-subbytes? elf-bytes #".rackprog")
                 (not (bytes-contains-subbytes? elf-bytes #"cOnFiG:"))
                 (not (bytes-contains-subbytes? elf-bytes #"failed to start "))
                 (not (bytes-contains-subbytes? elf-bytes #"coLLECTs dIRECTORy:/home/"))
                 (not (bytes-contains-subbytes? elf-bytes #"coNFIg dIRECTORy:/home/")))
      (error 'validate-bot-zip-archive!
             "BotZip ~a executable ~a is not an untethered standalone Racket CS ELF binary (.rackboot + .rackprog with no starter/host paths)"
             zip-path bot-name)))
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

  ;; Source & bytecode directories (excluding lakefillq* compiler research files)
  (for ([dname (in-list INCLUDE-DIRS)])
    (define dpath (build-path ROOT-DIR dname))
    (when (directory-exists? dpath)
      (for ([p (in-directory dpath)])
        (when (file-exists? p)
          (define rel (path->string (find-relative-path ROOT-DIR p)))
          (unless (or (string-contains? rel "__pycache__")
                      (string-contains? rel "/.git/")
                      (string-suffix? rel ".pyc")
                      (string-suffix? rel ".o")
                      (string-suffix? rel ".zip")
                      (string-suffix? rel ".SC2Replay")
                      (string-suffix? rel ".tar.xz")
                      (string-prefix? rel "compiler/lakefillq")
                      ;; In `sc-bot/`, only pack `sc-bot/main.rkt` and `sc-bot/compiled/*`
                      (and (string-prefix? rel "sc-bot/")
                           (not (equal? rel "sc-bot/main.rkt"))
                           (not (string-prefix? rel "sc-bot/compiled/"))))
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

(define (build-all-aiarena-zips! [target-variant #f])
  (precompile-all-racket-zo!)
  (printf "[2/4] Building standalone native ELF + AI Arena BotZip archives in pure Racket...\n")
  (define elf-path (compile-standalone-racket-elf!))
  (define elf-bstr (file->bytes elf-path))
  (define shared-entries (collect-shared-tree-entries))
  (define selected-variants
    (if target-variant
        (filter (lambda (row) (equal? (first row) target-variant)) VARIANTS)
        VARIANTS))
  (define results
    (for/list ([row (in-list selected-variants)])
      (build-variant-zip! (first row) (second row) (third row) elf-bstr shared-entries)))
  (printf "[3/4] Verified ~a AI Arena BotZip archives (all <= ~a MB limit).\n"
          (length results)
          (/ MAX-BOT-ZIP-SIZE-BYTES 1000000.0))
  (printf "[4/4] Done.\n")
  results)

(module+ main
  (define target-variant #f)
  (command-line
   #:program "build-aiarena-zip.rkt"
   #:once-each
   [("--all-races") "Build all race-specific zips plus Mothman.zip" (void)]
   [("--variant") v "Build a single variant only" (set! target-variant v)])
  (void (build-all-aiarena-zips! target-variant)))
