#lang racket/base

;; ============================================================================
;; #lang boba-nes : 3-Span Provenance Resugaring & Chordal Zero-Page Coloring
;; ============================================================================

(require racket/match
         racket/list
         racket/format
         racket/string
         "graded-typechecker.rkt")

(provide
 (struct-out source-span)
 (struct-out provenance-chain)
 (struct-out zp-interval)
 (struct-out zp-allocation)
 allocate-zero-page-chordal
 format-resugared-diagnostic
 resugar-module-diagnostics)

;; ============================================================================
;; 1. Three-Span Provenance Chain
;; ============================================================================
;; Preserves:
;;   1. surface-span   : Original DSL form in user's .bnes source file
;;   2. macro-span     : Intermediate macro expansion step (e.g., defrule-engine)
;;   3. lowered-6502   : Emitted 6502 instruction / PPU register address ($2006, $4014)

(struct source-span
  (file
   line
   col
   form-label)
  #:transparent)

(struct provenance-chain
  (surface-span
   macro-span
   lowered-6502-desc)
  #:transparent)

;; ============================================================================
;; 2. Chordal SSA / Interval Zero-Page Allocator ($0010 .. $00EF)
;; ============================================================================
;; On the MOS 6502, Zero Page ($00-$FF) is the primary pointer & fast-register
;; bank. Permanent variables live across the entire frame [0, +inf), while
;; sequential (with-zp-scratch ...) blocks occupy disjoint time intervals
;; [t_start, t_end] and therefore reuse identical physical Zero-Page addresses!

(struct zp-interval
  (name
   bytes
   cap
   start-step
   end-step
   provenance)
  #:transparent)

(struct zp-allocation
  (success?
   address-map       ; list of (hash 'name 'addr 'bytes 'cap 'interval)
   peak-bytes        ; exact-nonnegative-integer?
   budget-bytes      ; exact-nonnegative-integer?
   interference-core ; list of conflicting zp-interval on overflow
   )
  #:transparent)

(define (intervals-overlap? iv1 iv2)
  (and (<= (zp-interval-start-step iv1) (zp-interval-end-step iv2))
       (<= (zp-interval-start-step iv2) (zp-interval-end-step iv1))))

(define (allocate-zero-page-chordal intervals
                                    #:base-addr [base-addr #x10]
                                    #:max-bytes [max-bytes 224])
  ;; Sort intervals by start-step (PEO / left-edge order for interval graphs)
  (define sorted
    (sort intervals
          (lambda (a b)
            (if (= (zp-interval-start-step a) (zp-interval-start-step b))
                (> (zp-interval-bytes a) (zp-interval-bytes b))
                (< (zp-interval-start-step a) (zp-interval-start-step b))))))

  (define placed '()) ; list of (cons zp-interval addr)
  (define high-offset 0)

  (for ([iv (in-list sorted)])
    (cond
      [(eq? (zp-interval-cap iv) 'ConstMeta)
       ;; Erased compile-time constant (grade 0): consumes 0 Zero-Page bytes!
       (set! placed (cons (cons iv #f) placed))]
      [else
       (define sz (zp-interval-bytes iv))
       ;; Find all already-placed active intervals that overlap iv in time
       (define active-addrs
         (for/list ([p (in-list placed)]
                    #:when (and (cdr p)
                                (intervals-overlap? (car p) iv)))
           (cons (cdr p) (+ (cdr p) (zp-interval-bytes (car p)) -1))))

       ;; First-fit lowest available Zero-Page address >= base-addr
       (let loop ([cand base-addr])
         (define cand-end (+ cand sz -1))
         (define conflict
           (findf (lambda (rng)
                    (and (<= cand (cdr rng))
                         (<= (car rng) cand-end)))
                  active-addrs))
         (if conflict
             (loop (add1 (cdr conflict)))
             (begin
               (set! placed (cons (cons iv cand) placed))
               (set! high-offset
                     (max high-offset (- (+ cand sz) base-addr))))))]))

  (define ordered-placed (reverse placed))
  (define addr-table
    (for/list ([p (in-list ordered-placed)])
      (define iv (car p))
      (define addr (cdr p))
      (hasheq 'name (zp-interval-name iv)
              'addr addr
              'hex  (if addr (format "$~a" (~r addr #:base 16 #:min-width 2 #:pad-string "0")) "CONST")
              'bytes (zp-interval-bytes iv)
              'cap   (zp-interval-cap iv)
              'start (zp-interval-start-step iv)
              'end   (zp-interval-end-step iv))))

  ;; If peak-bytes > max-bytes, compute the maximal clique (interference core)
  (define core
    (if (<= high-offset max-bytes)
        '()
        (let ()
          ;; Find time step t that maximizes simultaneous byte demand
          (define steps
            (remove-duplicates
             (map zp-interval-start-step sorted)))
          (define-values (best-step best-ivs)
            (for/fold ([bst 0] [bivs '()])
                      ([st (in-list steps)])
              (define live-here
                (filter (lambda (iv)
                          (and (not (eq? (zp-interval-cap iv) 'ConstMeta))
                               (<= (zp-interval-start-step iv) st)
                               (<= st (zp-interval-end-step iv))))
                        sorted))
              (define sum-here (for/sum ([i (in-list live-here)]) (zp-interval-bytes i)))
              (define sum-best (for/sum ([i (in-list bivs)]) (zp-interval-bytes i)))
              (if (> sum-here sum-best)
                  (values st live-here)
                  (values bst bivs))))
          best-ivs)))

  (zp-allocation
   (<= high-offset max-bytes)
   addr-table
   high-offset
   max-bytes
   core))

;; ============================================================================
;; 3. Resugared Diagnostic Formatter
;; ============================================================================

(define (format-resugared-diagnostic viol [prov #f])
  (define surf-str
    (if prov
        (let ([s (provenance-chain-surface-span prov)])
          (format "~a:~a:~a in (~a ...)"
                  (source-span-file s)
                  (source-span-line s)
                  (source-span-col s)
                  (source-span-form-label s)))
        "surface-dsl:1:1"))
  (define macro-str
    (if prov
        (let ([m (provenance-chain-macro-span prov)])
          (format "~a:~a:~a [macro: ~a]"
                  (source-span-file m)
                  (source-span-line m)
                  (source-span-col m)
                  (source-span-form-label m)))
        "macro-expander"))
  (define low-str
    (if prov
        (provenance-chain-lowered-6502-desc prov)
        "6502/2C02 hardware constraint"))

  (string-join
   (list
    (format "[#lang boba-nes Grade Error | ~a / ~a]"
            (nes-violation-rule-id viol)
            (nes-violation-category viol))
    (format "  Surface DSL Span : ~a" surf-str)
    (format "  Macro Step       : ~a" macro-str)
    (format "  Lowered Hardware : ~a" low-str)
    (format "  Diagnosis        : ~a" (nes-violation-message viol))
    (format "  Auto-Repair Hint : ~a" (nes-violation-repair-hint viol)))
   "\n"))

(define (resugar-module-diagnostics type-res [prov-table (hash)])
  (for/list ([v (in-list (nes-type-result-violations type-res))])
    (define prov (hash-ref prov-table (nes-violation-category v) #f))
    (format-resugared-diagnostic v prov)))
