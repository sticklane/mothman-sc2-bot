#lang racket/base

;; ============================================================================
;; tools/nes-resource-tool.rkt
;; Out-of-ROM Asset Ripper, Tile Inspector & External Level Binary Patcher
;;
;; Supports the 4th architectural layer (External ROM Resource & Level Tools):
;;   1. Inspecting commercial .nes ROM headers and decoding 2bpp CHR tiles to ASCII
;;   2. Exporting standalone .chr files from Super Mario Bros., Zelda, and Tetris
;;   3. Compiling external declarative level files (.sexp) into binary tables
;;   4. Binary-patching CHR banks and PRG level tables directly into an existing
;;      compiled .nes ROM without recompiling the 6502 game engine!
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         racket/file
         racket/list
         racket/match
         racket/path
         "../compiler/boba-rom-builder.rkt"
         "../lib/nes-chr-assets.rkt")

(provide
 inspect-ines-rom
 count-nonblank-chr-tiles
 export-authentic-chr-files!
 compile-external-boba-stage-bytes
 validate-external-boba-stage
 patch-ines-rom-chr!
 patch-ines-rom-prg!
 patch-boba-rom-stage!)

(define-syntax (get-default-chr-dir stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up "assets" "chr")))))

(define DEFAULT-CHR-DIR (string->path (get-default-chr-dir)))

;; Count how many 16-byte 8x8 tiles in a CHR buffer contain at least one non-zero bit
(define (count-nonblank-chr-tiles chr-bytes)
  (define num-tiles (quotient (bytes-length chr-bytes) 16))
  (for/sum ([tid (in-range num-tiles)])
    (define base (* tid 16))
    (if (for/or ([i (in-range 16)])
          (not (zero? (bytes-ref chr-bytes (+ base i)))))
        1
        0)))

;; Inspect any .nes ROM file or byte vector and return header + CHR summary
(define (inspect-ines-rom rom-src)
  (define rom (if (bytes? rom-src) rom-src (file->bytes rom-src)))
  (define hdr (parse-ines-header rom))
  (define chr-len (hash-ref hdr 'chr-bytes))
  (define nonblank-chr
    (if (> chr-len 0)
        (count-nonblank-chr-tiles (extract-ines-chr-rom rom))
        0))
  (hash-set hdr 'nonblank-chr-tiles nonblank-chr))

;; Export standalone 8 KB .chr files from the 3 commercial NES ROMs into `out-dir`
(define (export-authentic-chr-files! [out-dir #f])
  (define target-dir (or out-dir DEFAULT-CHR-DIR))
  (make-directory* target-dir)
  (define smb-chr    (load-authentic-smb-chr-rom))
  (define zelda-chr  (load-authentic-zelda-chr-rom))
  (define tetris-chr (load-authentic-tetris-chr-rom))
  (define smb-path    (build-path target-dir "smb_authentic.chr"))
  (define zelda-path  (build-path target-dir "zelda_authentic.chr"))
  (define tetris-path (build-path target-dir "tetris_authentic.chr"))
  (display-to-file smb-chr    smb-path    #:exists 'replace #:mode 'binary)
  (display-to-file zelda-chr  zelda-path  #:exists 'replace #:mode 'binary)
  (display-to-file tetris-chr tetris-path #:exists 'replace #:mode 'binary)
  (hasheq 'smb-chr-path    smb-path
          'zelda-chr-path  zelda-path
          'tetris-chr-path tetris-path
          'smb-nonblank    (count-nonblank-chr-tiles smb-chr)
          'zelda-nonblank  (count-nonblank-chr-tiles zelda-chr)
          'tetris-nonblank (count-nonblank-chr-tiles tetris-chr)))

;; Validate an external declarative 8x8 stage s-expression before binary patching:
;;   stage-sexp = '((col row TOKEN-ID) ...)
(define (validate-external-boba-stage stage-cells)
  (unless (and (list? stage-cells) (<= (length stage-cells) 64))
    (error 'validate-external-boba-stage "stage must be a list of <= 64 cells, got ~v" stage-cells))
  (define seen-coords (make-hash))
  (for ([cell (in-list stage-cells)])
    (match cell
      [(list col row tok)
       (unless (and (exact-integer? col) (<= 0 col 7)
                    (exact-integer? row) (<= 0 row 7))
         (error 'validate-external-boba-stage "cell coordinate (~a, ~a) out of 8x8 bounds 0..7" col row))
       (when (hash-has-key? seen-coords (cons col row))
         (error 'validate-external-boba-stage "duplicate cell coordinate (~a, ~a)" col row))
       (hash-set! seen-coords (cons col row) tok)]
      [_ (error 'validate-external-boba-stage "malformed cell entry ~v" cell)]))
  #t)

;; Compile an external stage cell list into a 64-byte row-major 8x8 stage table
(define (compile-external-boba-stage-bytes stage-cells)
  (validate-external-boba-stage stage-cells)
  (define buf (make-bytes 64 0))
  (for ([cell (in-list stage-cells)])
    (match-define (list col row tok) cell)
    (define token-byte
      (cond
        [(exact-integer? tok) tok]
        [(symbol? tok)
         (case tok
           [(EMPTY TILE-EMPTY)         TILE-EMPTY]
           [(BOBA OBJ-BOBA)            OBJ-BOBA]
           [(WALL OBJ-WALL)            OBJ-WALL]
           [(ROCK OBJ-ROCK)            OBJ-ROCK]
           [(FLAG OBJ-FLAG)            OBJ-FLAG]
           [(SKULL WATER OBJ-SKULL)    OBJ-SKULL]
           [(WORD-BOBA TXT-BOBA)       TXT-BOBA]
           [(WORD-ROCK TXT-ROCK)       TXT-ROCK]
           [(WORD-WALL TXT-WALL)       TXT-WALL]
           [(WORD-FLAG TXT-FLAG)       TXT-FLAG]
           [(WORD-SKULL TXT-SKULL)     TXT-SKULL]
           [(WORD-IS TXT-IS)           TXT-IS]
           [(WORD-YOU TXT-YOU)         TXT-YOU]
           [(WORD-PUSH TXT-PUSH)       TXT-PUSH]
           [(WORD-STOP TXT-STOP)       TXT-STOP]
           [(WORD-WIN TXT-WIN)         TXT-WIN]
           [(WORD-DEFEAT TXT-DEFEAT)   TXT-DEFEAT]
           [else (error 'compile-external-boba-stage-bytes "unknown token symbol ~v" tok)])]
        [else (error 'compile-external-boba-stage-bytes "invalid token ~v" tok)]))
    (bytes-set! buf (+ (* row 8) col) token-byte))
  buf)

;; Binary-patch the CHR-ROM section of an existing .nes ROM without recompiling PRG-ROM
(define (patch-ines-rom-chr! rom-in-src new-chr-bytes #:out-path [out-path #f] #:bank-8k [bank-8k 0])
  (define orig-rom (if (bytes? rom-in-src) (bytes-copy rom-in-src) (file->bytes rom-in-src)))
  (define hdr (parse-ines-header orig-rom))
  (define chr-off (+ (hash-ref hdr 'chr-offset) (* bank-8k 8192)))
  (unless (= (bytes-length new-chr-bytes) 8192)
    (error 'patch-ines-rom-chr! "expected 8192-byte CHR bank, got ~a bytes" (bytes-length new-chr-bytes)))
  (bytes-copy! orig-rom chr-off new-chr-bytes 0 8192)
  (when out-path
    (display-to-file orig-rom out-path #:exists 'replace #:mode 'binary))
  orig-rom)

;; Binary-patch a slice of PRG-ROM at CPU address `cpu-addr` (in $8000-$FFFF) inside an existing .nes ROM
(define (patch-ines-rom-prg! rom-in-src cpu-addr patch-bytes #:out-path [out-path #f] #:prg-bank [prg-bank 0])
  (define orig-rom (if (bytes? rom-in-src) (bytes-copy rom-in-src) (file->bytes rom-in-src)))
  (define hdr (parse-ines-header orig-rom))
  (define prg-off (hash-ref hdr 'prg-offset))
  (define bank-offset (- cpu-addr #x8000))
  (define file-off (+ prg-off (* prg-bank 16384) bank-offset))
  (bytes-copy! orig-rom file-off patch-bytes 0 (bytes-length patch-bytes))
  (when out-path
    (display-to-file orig-rom out-path #:exists 'replace #:mode 'binary))
  orig-rom)

;; High-level external level editor hook:
;; Takes a compiled Boba Is You ROM, the `stage_0_table` CPU symbol address,
;; a stage index (0..4), and an external list of `(col row TOKEN)` cells,
;; validates hardware bounds, and binary-patches the 64-byte stage directly into the ROM!
(define (patch-boba-rom-stage! rom-in-src stage0-cpu-addr stage-index stage-cells
                               #:out-path [out-path #f])
  (unless (<= 0 stage-index 4)
    (error 'patch-boba-rom-stage! "stage-index must be in 0..4, got ~v" stage-index))
  (define stage-bytes (compile-external-boba-stage-bytes stage-cells))
  (define target-cpu-addr (+ stage0-cpu-addr (* stage-index 64)))
  (patch-ines-rom-prg! rom-in-src target-cpu-addr stage-bytes #:out-path out-path))
