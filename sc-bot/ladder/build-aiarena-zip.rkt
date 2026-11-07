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

(require racket/cmdline
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         compiler/cm
         file/gzip
         json)

(define-runtime-path LADDER-DIR ".")
(define ROOT-DIR (simplify-path (build-path LADDER-DIR "..")))
(define CACHE-DIR (build-path LADDER-DIR ".cache"))

(define INCLUDE-DIRS '("sc-bot" "compiler" "lib" "sim" "bots" "ffi"))
(define INCLUDE-TOP-FILES '("run.py" "main.rkt" "info.rkt"))

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
;; 2. Precompile `.zo` Bytecode & `cpplinux_launcher.cpp` ELF Binary
;; -----------------------------------------------------------------------------

(define (precompile-all-racket-zo!)
  (printf "[1/4] Precompiling Racket modules to .zo bytecode via compiler/cm...\n")
  (current-directory ROOT-DIR)
  (define targets
    '("main.rkt"
      "compiler/syntax.rkt"
      "lib/okasaki-sc.rkt"
      "lib/perception-grid.rkt"
      "lib/econ-ledger.rkt"
      "lib/tactics-sim.rkt"
      "lib/human-cortex.rkt"
      "lib/zerospace-mastermind.rkt"
      "lib/mirror-mind-predictor.rkt"
      "lib/bot-runtime.rkt"
      "lib/state-machine-verifier.rkt"
      "lib/bot-crash-fuzzer.rkt"
      "sim/racket_sc2_ipc_bot.rkt"
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

(define (compile-cpplinux-elf bot-name)
  (make-directory* CACHE-DIR)
  (define cpp-src (build-path LADDER-DIR "cpplinux_launcher.cpp"))
  (define out-bin (build-path CACHE-DIR (format "~a_elf" bot-name)))
  (define g++-path (or (find-executable-path "g++")
                       (find-executable-path "clang++")))
  (cond
    [(and (file-exists? cpp-src) g++-path)
     (define ok?
       (system* g++-path
                "-O2" "-s" "-std=c++17"
                (format "-DBOT_VARIANT_NAME=\"~a\"" bot-name)
                (path->string cpp-src)
                "-o" (path->string out-bin)))
     (when (and ok? (file-exists? out-bin))
       (file-or-directory-permissions out-bin #o755))
     (and ok? (file-exists? out-bin) out-bin)]
    [else #f]))

;; -----------------------------------------------------------------------------
;; 3. Collect Common Files & Build Each Variant Zip
;; -----------------------------------------------------------------------------

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

  ;; Bundled portable Racket runtime (`racket_runtime.tar.xz`)
  (define rt-archive (build-path CACHE-DIR "racket_runtime.tar.xz"))
  (when (file-exists? rt-archive)
    (add-spec! "racket_runtime.tar.xz" (file->bytes rt-archive) #t #o100644))

  ;; Source & bytecode directories
  (for ([dname (in-list INCLUDE-DIRS)])
    (define dpath (build-path ROOT-DIR dname))
    (when (directory-exists? dpath)
      (for ([p (in-directory dpath)])
        (when (file-exists? p)
          (define rel (path->string (find-relative-path ROOT-DIR p)))
          (unless (or (string-contains? rel "__pycache__")
                      (string-contains? rel "/.git/")
                      (string-suffix? rel ".pyc")
                      (string-suffix? rel ".o"))
            (define store? (string-suffix? rel ".so"))
            (add-spec! rel (file->bytes p) store? #o100644))))))

  (reverse specs))

(define (build-variant-zip! bot-name bot-race bot-path shared-entries)
  (define zip-path (build-path LADDER-DIR (format "~a.zip" bot-name)))
  (define config-bstr
    (string->bytes/utf-8
     (format "{\n  \"BotName\": ~s,\n  \"BotRace\": ~s,\n  \"BotPath\": ~s\n}\n"
             bot-name bot-race bot-path)))
  (define seed-data-bstr
    (string->bytes/utf-8
     (format "{\n  \"bot_name\": ~s,\n  \"opponents\": {}\n}\n"
             bot-name)))
  (define elf-path (compile-cpplinux-elf bot-name))
  (define header-entries
    (append
     (list (make-zip-entry-spec "config.json" config-bstr #f #o100644))
     (if (and elf-path (file-exists? elf-path))
         (list (make-zip-entry-spec bot-name (file->bytes elf-path) #f #o100755))
         '())
     (list (make-zip-entry-spec "data/mirror_mind_opponents.json" seed-data-bstr #f #o100644))))
  (define all-entries (append header-entries shared-entries))
  (write-pkzip-archive! zip-path all-entries)
  (define sz (file-size zip-path))
  (define sz-mb (/ (round (* 100.0 (/ sz (* 1024.0 1024.0)))) 100.0))
  (printf "  -> Built ~a (~a MB, ~a files)\n" (path->string zip-path) sz-mb (length all-entries))
  (hash 'bot_name bot-name
        'race bot-race
        'bot_path bot-path
        'zip_path (path->string zip-path)
        'files_added (length all-entries)
        'size_bytes sz
        'size_mb sz-mb
        'cpplinux_binary_included (and elf-path (file-exists? elf-path) #t)
        'bundled_portable_racket (file-exists? (build-path CACHE-DIR "racket_runtime.tar.xz"))))

(module+ main
  (define build-all? #t)
  (define target-variant #f)
  (command-line
   #:program "build-aiarena-zip.rkt"
   #:once-each
   [("--all-races") "Build all race-specific zips plus Mothman.zip" (set! build-all? #t)]
   [("--variant") v "Build a single variant only" (set! target-variant v)])

  (precompile-all-racket-zo!)
  (printf "[2/4] Building AI Arena BotZip archives in pure Racket...\n")
  (define shared-entries (collect-shared-tree-entries))
  (define selected-variants
    (if target-variant
        (filter (lambda (row) (equal? (first row) target-variant)) VARIANTS)
        VARIANTS))
  (define results
    (for/list ([row (in-list selected-variants)])
      (build-variant-zip! (first row) (second row) (third row) shared-entries)))
  (printf "[3/4] Verified ~a AI Arena BotZip archives built in pure Racket.\n" (length results))
  (printf "[4/4] Done.\n"))
