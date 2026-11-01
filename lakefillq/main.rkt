#lang racket/base

;; =============================================================================
;; lakefillq/main.rkt
;;
;; Surface Language Expander and AST Builders for `#lang lakefillq`.
;; Elaborates `LakefillQ` circuit modules (`defq`, `defqfree`, `with-and-session`,
;; `within-apply-mbu`, `erase-by`, `canonicalize-quotient`, `qmatch`,
;; `focus-zipper`, `fold-braun`, and `target-profile`) into first-class program
;; specifications consumed by `compiler/lakefillqc.rkt` (`LakefillQ -> RevIR ->
;; MachineISA`).
;; =============================================================================

(require (for-syntax racket/base
                     syntax/parse)
         racket/list
         racket/match
         racket/math
         racket/runtime-path
         racket/string)

(define-runtime-path lakefillqc-driver-path "../compiler/lakefillqc.rkt")

(provide (rename-out [lakefillq-module-begin #%module-begin])
         #%app
         #%datum
         #%top
         #%top-interaction
         ;; Standard pure expression & binding forms usable in `.lfq` circuit definitions
         define
         let
         let*
         lambda
         if
         cond
         else
         and
         or
         not
         quote
         quasiquote
         unquote
         unquote-splicing
         for/list
         for*/list
         in-range
         in-list
         in-naturals
         when
         unless
         match-define
         list
         cons
         append
         reverse
         length
         null?
         first
         second
         third
         fourth
         last
         rest
         take
         drop
         drop-right
         list-ref
         range
         map
         filter
         foldl
         apply
         remove-duplicates
         member
         memv
         vector
         vector-ref
         vector-length
         list->vector
         vector->list
         string-join
         +
         -
         *
         /
         add1
         sub1
         quotient
         modulo
         expt
         min
         max
         abs
         odd?
         even?
         zero?
         bitwise-and
         bitwise-ior
         bitwise-xor
         arithmetic-shift
         bitwise-bit-set?
         pi
         sin
         cos
         sqrt
         acos
         =
         <
         >
         <=
         >=
         eq?
         equal?
         ;; Data structures exported to `compiler/lakefillqc.rkt`
         (struct-out lfq-circuit-decl)
         (struct-out lfq-program)
         (struct-out lfq-cluster-profile-entry)
         (struct-out lfq-surface-span)
         (struct-out braun-node)
         list->braun-tree
         check-qfree-ast!
         lfq-program-cluster-profiles
         register-program-cluster-profiles!
         attach-surface-span!
         attach-surface-span-deep!
         lookup-surface-span
         propagate-surface-span!
         propagate-surface-span-list!
         lookup-decl-group-spans
         attach-decl-target!
         lookup-decl-target
         lookup-cluster-profile-meta
         (struct-out exn:fail:lfq-surface)
         ;; `#lang lakefillq` top-level declarations
         target-profile
         define-cluster-profile
         defconst
         defq
         defqfree
         ;; `#lang lakefillq` surface combinators
         skip
         seq
         for/seq
         invert
         call-q
         with-and-session
         within-apply-mbu
         within-apply
         erase-by
         erase-by-part-bij
         guard-valid-if
         guard-involutory
         guard-qblock-lcu-phase
         guard-wire-basis
         guard-drift-eps
         guard-single-ir
         guard-par-partition
         par-cluster-opt-spec
         solve-optimal-qpar-machines
         canonicalize-quotient
         qmatch
         focus-zipper
         fold-braun
         par-wires
         multishot-reset
         logical-relabel
         ;; `#lang lakefillq` gate constructors
         x
         z
         s
         s-dag
         h
         ry
         rz-dyadic
         cx
         cz
         ccx
         ccz
         swap
         cswap-bit
         cswap-word
         mcx
         mcz
         qft
         temp-and
         temp-and-lin
         prepare-dicke-le1
         mid-meas-x
         mid-meas-x-unshielded
         mid-meas-x-cond-z
         cond-z
         cond-cz
         syndrome-plaquette
         ;; `#lang lakefillq` domain & guard constructors
         all
         wt-le
         quotient-vars
         domain-guard
         g-true
         g-false
         g-wire
         g-zero
         g-not
         g-xor
         g-and
         g-or
         g-all-zero
         g-non-zero
         g-eq-bits
         g-eq-wires
         ;; Wire & linear-form helpers
         qvec
         wref
         lin-xor)

;; =============================================================================
;; 1. Program, Circuit Declaration & Surface Provenance Side-Table Structures
;; =============================================================================

(struct lfq-circuit-decl
  (name          ;; symbol
   kind          ;; 'defq or 'defqfree
   wire-groups   ;; list of (cons sym (listof nat))
   scratch-groups;; list of (cons sym (listof nat))
   input-wires   ;; flat list of nat
   scratch-wires ;; flat list of nat
   domain-spec   ;; 'all | `(wt-le ,t) | `(quotient-vars ,ws) | `(domain-guard ,g)
   surface-ast)  ;; LakefillQ surface S-expression AST
  #:transparent)

(struct lfq-program
  (source-id     ;; string or symbol
   target        ;; 'heron-r2 | 'bluvstein-aod | 'bb-qldpc | 'ideal
   circuits)     ;; non-empty list of lfq-circuit-decl (last or 'main is primary entry)
  #:transparent)

(struct lfq-cluster-profile-entry
  (name            ;; symbol
   spec            ;; `(par-cluster-opt-spec ...)` S-expression
   qpu-wire-slices);; #f or list of `(listof nat)` explicit disjoint QPU wire slices
  #:transparent)

;; Non-intrusive weak side-table provenance span (`file:line:col` + surface form + pass tag)
;; preserved across `LakefillQ -> lambda_LFQ_kern -> RevIR` without altering S-expression patterns:
(struct lfq-surface-span
  (file      ;; string ("examples/mod13_adder_mbu.lfq" or "<memory>")
   line      ;; exact positive integer (1-indexed)
   col       ;; exact nonnegative integer (0-indexed)
   form-str  ;; compact surface form text
   pass-tag) ;; symbol ('LakefillQ | 'lambda_LFQ_kern | 'RevIR | 'RevIR-Chordal)
  #:transparent)

(define lfq-surface-span-table (make-weak-hasheq))

(define (attach-surface-span! node span #:overwrite? [overwrite? #f])
  (when (and span (or (pair? node) (lfq-circuit-decl? node)))
    (when (or overwrite? (not (hash-has-key? lfq-surface-span-table node)))
      (hash-set! lfq-surface-span-table node span)))
  node)

(define (attach-surface-span-deep! node span)
  (when span
    (let walk ([n node])
      (cond
        [(lfq-circuit-decl? n)
         (attach-surface-span! n span)]
        [(pair? n)
         (attach-surface-span! n span)
         (walk (car n))
         (walk (cdr n))]
        [else (void)])))
  node)

(define (lookup-surface-span node)
  (and (or (pair? node) (lfq-circuit-decl? node))
       (hash-ref lfq-surface-span-table node #f)))

(define (propagate-surface-span! src-node dst-node [pass-tag #f])
  (define sp (lookup-surface-span src-node))
  (when sp
    (define next-sp
      (if pass-tag
          (struct-copy lfq-surface-span sp [pass-tag pass-tag])
          sp))
    (attach-surface-span! dst-node next-sp))
  dst-node)

(define (propagate-surface-span-list! src-node dst-list [pass-tag #f])
  (define sp (lookup-surface-span src-node))
  (when sp
    (define next-sp
      (if pass-tag
          (struct-copy lfq-surface-span sp [pass-tag pass-tag])
          sp))
    (for ([elem (in-list dst-list)])
      (attach-surface-span! elem next-sp)))
  dst-list)

(define program-cluster-profiles-table (make-weak-hasheq))
(define decl-group-spans-table (make-weak-hasheq))
(define decl-target-override-table (make-weak-hasheq))
(define cluster-profile-meta-table (make-weak-hasheq))

(define (register-program-cluster-profiles! prog entries)
  (hash-set! program-cluster-profiles-table prog entries)
  prog)

(define (lfq-program-cluster-profiles prog)
  (hash-ref program-cluster-profiles-table prog '()))

(define (attach-decl-group-spans! decl group-span-hash)
  (when (and (lfq-circuit-decl? decl) (hash? group-span-hash))
    (hash-set! decl-group-spans-table decl group-span-hash))
  decl)

(define (lookup-decl-group-spans decl)
  (if (lfq-circuit-decl? decl)
      (hash-ref decl-group-spans-table decl (hasheq))
      (hasheq)))

(define (attach-decl-target! decl target-sym)
  (when (and (lfq-circuit-decl? decl) target-sym)
    (hash-set! decl-target-override-table decl target-sym))
  decl)

(define (lookup-decl-target decl)
  (and (lfq-circuit-decl? decl)
       (hash-ref decl-target-override-table decl #f)))

(define (attach-cluster-profile-meta! entry meta-hash)
  (when (and (lfq-cluster-profile-entry? entry) (hash? meta-hash))
    (hash-set! cluster-profile-meta-table entry meta-hash))
  entry)

(define (lookup-cluster-profile-meta entry)
  (if (lfq-cluster-profile-entry? entry)
      (hash-ref cluster-profile-meta-table entry (hasheq))
      (hasheq)))

;; Balanced Okasaki Braun tree node (`size(right) <= size(left) <= size(right) + 1`)
;; whose in-order catamorphism traversal visits indices `0 .. n-1` in exact sequential order.
(struct braun-node
  (value
   index
   left
   right)
  #:transparent)

(define (list->braun-tree items)
  (let build ([xs items] [base-idx 0])
    (define n (length xs))
    (cond
      [(= n 0) #f]
      [else
       (define right-n (quotient (sub1 n) 2))
       (define left-n (- (sub1 n) right-n))
       (define left-xs (take xs left-n))
       (define root-val (list-ref xs left-n))
       (define right-xs (drop xs (add1 left-n)))
       (braun-node root-val
                   (+ base-idx left-n)
                   (build left-xs base-idx)
                   (build right-xs (+ base-idx left-n 1)))])))

;; =============================================================================
;; 2. Wire & Linear-Form Helpers (`qvec` Symbolic Disjoint Wire Allocator)
;; =============================================================================

(define current-qvec-allocator-box (make-parameter #f))

(define (qvec width)
  (unless (exact-nonnegative-integer? width)
    (error 'qvec "Expected exact nonnegative integer width, got: ~a" width))
  (define bx (current-qvec-allocator-box))
  (cond
    [bx
     (define base (unbox bx))
     (set-box! bx (+ base width))
     (range base (+ base width))]
    [else
     (range 0 width)]))

(define (advance-qvec-watermark! ws)
  (unless (and (list? ws) (andmap exact-nonnegative-integer? ws))
    (error 'defq "Wire group must evaluate to a list of nonnegative integers (or `(qvec n)`), got: ~a" ws))
  (define bx (current-qvec-allocator-box))
  (when (and bx (not (null? ws)))
    (set-box! bx (max (unbox bx) (add1 (apply max ws)))))
  ws)

(struct exn:fail:lfq-surface exn:fail
  (code
   span
   repair-hint)
  #:transparent)

(define (proc-wref ws idx [reg-label #f] [span #f])
  (unless (and (list? ws) (exact-integer? idx))
    (raise (exn:fail:lfq-surface
            (format "Expected quantum register wire list and exact integer index in `wref`, got register `~a` and index `~a`"
                    (or reg-label ws) idx)
            (current-continuation-marks)
            "LFQ-E-REGISTER-BOUNDS"
            span
            "Bind quantum registers via `[reg (qvec n)]` in `#:wires` / `#:scratch` and index with an integer `0 .. n-1`.")))
  (define width (length ws))
  (when (or (< idx 0) (>= idx width))
    (define valid-str
      (if (= width 0)
          "register has width 0"
          (format "valid indices: 0..~a" (sub1 width))))
    (raise (exn:fail:lfq-surface
            (format "Register index ~a out of bounds for ~a-qubit register `~a` (~a)"
                    idx width (or reg-label "register") valid-str)
            (current-continuation-marks)
            "LFQ-E-REGISTER-BOUNDS"
            span
            (format "Increase `[~a (qvec ~a)]` in `#:wires` / `#:scratch` or choose an index within ~a."
                    (or reg-label "reg") (add1 (max 0 idx)) valid-str))))
  (list-ref ws idx))

(define (lin-xor . forms)
  (define counts (make-hasheqv))
  (for* ([f (in-list forms)] [w (in-list f)])
    (hash-update! counts w add1 0))
  (sort (for/list ([(w c) (in-hash counts)] #:when (odd? c)) w) <))

;; =============================================================================
;; 3. Domain & Guard Constructors
;; =============================================================================

(define all 'all)
(define (wt-le t) `(wt-le ,t))
(define (quotient-vars ws) `(quotient-vars ,ws))
(define (domain-guard g) `(domain-guard ,g))

(define (g-true) 'true)
(define (g-false) 'false)
(define (g-wire w) `(wire ,w))
(define (g-zero w) `(zero ,w))
(define (g-not g) `(not ,g))
(define (g-xor . gs) `(xor ,@gs))
(define (g-and . gs) `(and ,@gs))
(define (g-or . gs) `(or ,@gs))
(define (g-all-zero ws) `(all-zero ,ws))
(define (g-non-zero ws) `(non-zero ,ws))
(define (g-eq-wires wlist1 wlist2) `(eq-wires ,wlist1 ,wlist2))
(define (g-eq-bits ws bits)
  `(and ,@(for/list ([w (in-list ws)] [b (in-list bits)])
            (if (= b 1) `(wire ,w) `(zero ,w)))))

;; =============================================================================
;; 4. Surface Gate & Combinator Constructors (`LakefillQ` Surface Dialect)
;; =============================================================================

(begin-for-syntax
  (define (stx->span-parts stx)
    (define raw-src (syntax-source stx))
    (define src-str
      (cond
        [(path? raw-src) (path->string raw-src)]
        [(and raw-src (not (equal? raw-src ""))) (format "~a" raw-src)]
        [else "<memory>"]))
    (define ln (or (syntax-line stx) 1))
    (define col (or (syntax-column stx) 0))
    (define raw-frm (format "~s" (syntax->datum stx)))
    (define frm
      (if (> (string-length raw-frm) 140)
          (string-append (substring raw-frm 0 137) "...")
          raw-frm))
    (values src-str ln col frm)))

(define-syntax (wref call-stx)
  (syntax-case call-stx ()
    [(_ reg-expr idx-expr)
     (let-values ([(src ln col frm) (stx->span-parts call-stx)])
       (define reg-lbl (format "~a" (syntax->datum #'reg-expr)))
       (with-syntax ([s src] [l ln] [c col] [f frm] [rl reg-lbl])
         #'(proc-wref reg-expr idx-expr rl (lfq-surface-span s l c f 'LakefillQ))))]
    [(_ . args)
     #'(#%app proc-wref . args)]
    [id (identifier? #'id) #'proc-wref]))

;; Dual-mode syntax wrapper: captures exact caller `(file, line, col, form)` at every
;; call site `(op arg ...)`, while expanding to `impl-id` when used as a first-class value!
(define-syntax (define-spanned-op stx)
  (syntax-parse stx
    [(_ pub-id:id impl-id:id)
     #'(define-syntax (pub-id call-stx)
         (syntax-case call-stx ()
           [(_ . args)
            (let-values ([(src ln col frm) (stx->span-parts call-stx)])
              (with-syntax ([s src] [l ln] [c col] [f frm])
                #'(attach-surface-span-deep!
                   (#%app impl-id . args)
                   (lfq-surface-span s l c f 'LakefillQ))))]
           [id (identifier? #'id) #'impl-id]))]))

(define skip 'skip)

(define (proc-seq . es)
  (define flat
    (for/fold ([acc '()]) ([e (in-list es)])
      (match e
        ['skip acc]
        [(? lfq-circuit-decl? sub-d)
         (match (lfq-circuit-decl-surface-ast sub-d)
           ['skip acc]
           [`(seq ,subs ...) (append (reverse subs) acc)]
           [sub-ast (cons sub-ast acc)])]
        [`(seq ,subs ...) (append (reverse subs) acc)]
        [_ (cons e acc)])))
  (match (reverse flat)
    ['() 'skip]
    [(list single) single]
    [many (cons 'seq many)]))
(define-spanned-op seq proc-seq)

(define-syntax (lfq-seq-block stx)
  (syntax-parse stx
    #:literals (define match-define)
    [(_) #'skip]
    [(_ (define head rhs ...) rest ...)
     #'(let () (define head rhs ...) (lfq-seq-block rest ...))]
    [(_ (match-define pat rhs) rest ...)
     #'(let () (match-define pat rhs) (lfq-seq-block rest ...))]
    [(_ first-e:expr rest ...)
     (let-values ([(src ln col frm) (stx->span-parts #'first-e)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(let ([v (attach-surface-span-deep!
                     first-e
                     (lfq-surface-span s l c f 'LakefillQ))])
             (proc-seq v (lfq-seq-block rest ...)))))]))

(define-syntax (for/seq stx)
  (syntax-parse stx
    [(_ clauses body ...)
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(attach-surface-span-deep!
            (apply proc-seq (for/list clauses (lfq-seq-block body ...)))
            (lfq-surface-span s l c f 'LakefillQ))))]))

(define (proc-invert e) (list 'invert e))
(define-spanned-op invert proc-invert)

(define (proc-call-q callee . port-args)
  (list* 'call-q callee port-args))
(define-spanned-op call-q proc-call-q)

(define (proc-within-apply-mbu comp-e act-e [erased-ws '()])
  (list 'within-apply-mbu comp-e act-e erased-ws))
(define-spanned-op within-apply-mbu proc-within-apply-mbu)

(define (proc-within-apply comp-e act-e [erased-ws '()])
  (list 'within-apply comp-e act-e erased-ws))
(define-spanned-op within-apply proc-within-apply)

(define (proc-erase-by fwd-e bwd-e erased-ws)
  (list 'erase-by fwd-e bwd-e erased-ws))
(define-spanned-op erase-by proc-erase-by)

;; 7-Rule Generalized Bug-Class & Parallel-Partitionability Surface Guards (`T-DomImg` .. `T-ParGuard`):
(define (proc-erase-by-part-bij spec fwd-e bwd-e erased-ws)
  (list 'erase-by-part-bij spec fwd-e bwd-e erased-ws))
(define-spanned-op erase-by-part-bij proc-erase-by-part-bij)

(define (proc-guard-valid-if vprog [body-e 'skip])
  (list 'guard-valid-if vprog body-e))
(define-spanned-op guard-valid-if proc-guard-valid-if)

(define (proc-guard-involutory consumer op-spec [body-e 'skip])
  (list 'guard-involutory consumer op-spec body-e))
(define-spanned-op guard-involutory proc-guard-involutory)

(define (proc-guard-qblock-lcu-phase qb-expr [body-e 'skip])
  (list 'guard-qblock-lcu-phase qb-expr body-e))
(define-spanned-op guard-qblock-lcu-phase proc-guard-qblock-lcu-phase)

(define (proc-guard-wire-basis wb-prog [body-e 'skip])
  (list 'guard-wire-basis wb-prog body-e))
(define-spanned-op guard-wire-basis proc-guard-wire-basis)

(define (proc-guard-drift-eps drift-spec [body-e 'skip])
  (list 'guard-drift-eps drift-spec body-e))
(define-spanned-op guard-drift-eps proc-guard-drift-eps)

(define (proc-guard-single-ir sir-spec [body-e 'skip])
  (list 'guard-single-ir sir-spec body-e))
(define-spanned-op guard-single-ir proc-guard-single-ir)

(define (proc-guard-par-partition par-spec [body-e 'skip])
  (list 'guard-par-partition par-spec body-e))
(define-spanned-op guard-par-partition proc-guard-par-partition)

(define-runtime-path bug-prevention-types-path "../compiler/lakefillq-bug-class-prevention-types.rkt")

(define (par-cluster-opt-spec #:workload workload
                              #:paradigm paradigm
                              #:max-machines [max-machines 256]
                              #:q-cap-per-machine q-cap-per-machine
                              #:raw-bell-rate-hz [raw-bell-rate-hz 100000.0]
                              #:raw-per-logical-ebit [raw-per-logical-ebit 30]
                              #:q-single q-single
                              #:q-data-dist [q-data-dist 0]
                              #:q-local-fixed [q-local-fixed 0]
                              #:q-peer-sync [q-peer-sync 0]
                              #:candidate-machines [candidate-machines '(1 2 4 6 8 12 16 24 32 48 64 96 128 256)]
                              #:window-bits [window-bits 0]
                              #:num-windows [num-windows 0]
                              #:local-toffolis [local-toffolis 0]
                              #:carry-scheme [carry-scheme 'none]
                              #:lookup-scheme [lookup-scheme 'none]
                              #:interconnect-topology [interconnect-topology 'all-to-all-peers]
                              #:total-shots [total-shots #f]
                              #:strict-parallel? [strict-parallel? #f])
  `(par-cluster-opt-spec
    #:workload ,workload
    #:paradigm ,paradigm
    #:max-machines ,max-machines
    #:q-cap-per-machine ,q-cap-per-machine
    #:raw-bell-rate-hz ,raw-bell-rate-hz
    #:raw-per-logical-ebit ,raw-per-logical-ebit
    #:q-single ,q-single
    #:q-data-dist ,q-data-dist
    #:q-local-fixed ,q-local-fixed
    #:q-peer-sync ,q-peer-sync
    #:candidate-machines ,candidate-machines
    #:window-bits ,window-bits
    #:num-windows ,num-windows
    #:local-toffolis ,local-toffolis
    #:carry-scheme ,carry-scheme
    #:lookup-scheme ,lookup-scheme
    #:interconnect-topology ,interconnect-topology
    #:total-shots ,total-shots
    #:strict-parallel? ,strict-parallel?))

(define (solve-optimal-qpar-machines spec . rest)
  (apply (dynamic-require bug-prevention-types-path 'solve-optimal-qpar-machines) spec rest))

(define (proc-canonicalize-quotient q-ws cleanup-e)
  (list 'canonicalize-quotient q-ws cleanup-e))
(define-spanned-op canonicalize-quotient proc-canonicalize-quotient)

(define-syntax (with-and-session stx)
  (syntax-parse stx
    [(_ ([anc-e:expr lhs-e:expr rhs-e:expr] ...) body ...)
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(attach-surface-span-deep!
            (list 'with-and-session
                  (list (list anc-e lhs-e rhs-e #f #f) ...)
                  (lfq-seq-block body ...))
            (lfq-surface-span s l c f 'LakefillQ))))]
    [(_ ([anc-e:expr lhs-e:expr rhs-e:expr
          (~optional neg-l?:expr #:defaults ([neg-l? #'#f]))
          (~optional neg-r?:expr #:defaults ([neg-r? #'#f]))] ...)
        body ...)
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(attach-surface-span-deep!
            (list 'with-and-session
                  (list (list anc-e lhs-e rhs-e neg-l? neg-r?) ...)
                  (lfq-seq-block body ...))
            (lfq-surface-span s l c f 'LakefillQ))))]))

(define-syntax (qmatch stx)
  (syntax-parse stx
    [(_ ([guard-e:expr arm-e ...] ...+))
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(attach-surface-span-deep!
            (list 'qmatch (list (list guard-e (lfq-seq-block arm-e ...)) ...))
            (lfq-surface-span s l c f 'LakefillQ))))]))

(begin-for-syntax
  (define lfq-surface-operator-symbols
    '(x z s s-dag h ry rz-dyadic
      cx cz ccx ccz swap cswap-bit cswap-word mcx mcz qft
      temp-and temp-and-lin prepare-dicke-le1
      mid-meas-x mid-meas-x-unshielded mid-meas-x-cond-z cond-z cond-cz
      syndrome-plaquette
      seq for/seq invert call-q with-and-session within-apply-mbu within-apply
      erase-by erase-by-part-bij canonicalize-quotient qmatch focus-zipper
      fold-braun par-wires multishot-reset logical-relabel
      guard-valid-if guard-involutory guard-qblock-lcu-phase guard-wire-basis
      guard-drift-eps guard-single-ir guard-par-partition
      qvec wref lin-xor
      wt-le quotient-vars domain-guard
      g-true g-false g-wire g-zero g-not g-xor g-and g-or g-all-zero g-non-zero
      g-eq-bits g-eq-wires)))

(define-syntax (bind-lfq-register-clauses stx)
  (syntax-parse stx
    [(_ () body-expr:expr)
     #'body-expr]
    [(_ ([reg-id:id rhs-expr:expr reg-tmp:id] rest ...) body-expr:expr)
     (define sym (syntax-e #'reg-id))
     (if (memq sym lfq-surface-operator-symbols)
         (with-syntax ([outer-op (datum->syntax #'here sym)])
           #'(let ([reg-tmp rhs-expr])
               (let-syntax ([reg-id
                             (lambda (use-stx)
                               (syntax-case use-stx ()
                                 [(_ . args)
                                  (datum->syntax use-stx
                                                 (cons #'outer-op #'args)
                                                 use-stx
                                                 use-stx)]
                                 [id (identifier? #'id) #'reg-tmp]))])
                 (bind-lfq-register-clauses (rest ...) body-expr))))
         #'(let ([reg-tmp rhs-expr])
             (let ([reg-id reg-tmp])
               (bind-lfq-register-clauses (rest ...) body-expr))))]))

(define-syntax (focus-zipper stx)
  (syntax-parse stx
    [(_ [focus-id:id sub-ws-e:expr ambient-ws-e:expr] body ...)
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm]
                     [focus-tmp (car (generate-temporaries (list #'focus-id)))])
         #'(let ([sub-ws sub-ws-e]
                 [ambient-ws ambient-ws-e])
             (for ([w (in-list sub-ws)])
               (unless (member w ambient-ws)
                 (error 'focus-zipper
                        "Focused wire ~a is outside ambient register ~a" w ambient-ws)))
             (bind-lfq-register-clauses
              ([focus-id sub-ws focus-tmp])
              (attach-surface-span-deep!
               (list 'focus-zipper (list focus-tmp ambient-ws) (lfq-seq-block body ...))
               (lfq-surface-span s l c f 'LakefillQ))))))]))

(define (proc-fold-braun step-proc items)
  (define btree (list->braun-tree items))
  (define (render-node nd)
    (match nd
      [#f 'braun-leaf]
      [(braun-node val idx l r)
       (list 'braun-branch idx (step-proc val idx) (render-node l) (render-node r))]))
  (list 'fold-braun (render-node btree)))
(define-spanned-op fold-braun proc-fold-braun)

(define (proc-par-wires e1 e2) (list 'par-wires e1 e2))
(define-spanned-op par-wires proc-par-wires)

(define (proc-multishot-reset k body) (list 'multishot-reset k body))
(define-spanned-op multishot-reset proc-multishot-reset)

(define (proc-logical-relabel ws perm) (list 'logical-relabel ws perm))
(define-spanned-op logical-relabel proc-logical-relabel)

;; Gate constructors
(define (proc-x w) (list 'x w))
(define-spanned-op x proc-x)

(define (proc-z w) (list 'z w))
(define-spanned-op z proc-z)

(define (proc-s w) (list 's w))
(define-spanned-op s proc-s)

(define (proc-s-dag w) (list 's-dag w))
(define-spanned-op s-dag proc-s-dag)

(define (proc-h w) (list 'h w))
(define-spanned-op h proc-h)

(define (proc-ry theta w) (list 'ry theta w))
(define-spanned-op ry proc-ry)

(define (proc-rz-dyadic w exp-k #:precision [prec 'exact-dyadic] #:distance [dist 5])
  (list 'rz-dyadic w exp-k (eq? prec 'float64) dist))
(define-spanned-op rz-dyadic proc-rz-dyadic)

(define (proc-cx c t) (list 'cx c t))
(define-spanned-op cx proc-cx)

(define (proc-cz a b) (list 'cz a b))
(define-spanned-op cz proc-cz)

(define (proc-ccx c1 c2 t) (list 'ccx c1 c2 t))
(define-spanned-op ccx proc-ccx)

(define (proc-ccz a b c) (list 'ccz a b c))
(define-spanned-op ccz proc-ccz)

(define (proc-swap a b) (list 'swap a b))
(define-spanned-op swap proc-swap)

(define (proc-cswap-bit ctrl u v) (list 'cswap-bit ctrl u v))
(define-spanned-op cswap-bit proc-cswap-bit)

(define (proc-cswap-word ctrl u-ws v-ws) (list 'cswap-word ctrl u-ws v-ws))
(define-spanned-op cswap-word proc-cswap-word)

(define (proc-mcx ctrls target [scratch '()]) (list 'mcx ctrls target scratch))
(define-spanned-op mcx proc-mcx)

(define (proc-mcz ctrls [scratch '()]) (list 'mcz ctrls scratch))
(define-spanned-op mcz proc-mcz)

(define (proc-qft ws) (list 'qft ws))
(define-spanned-op qft proc-qft)

(define (proc-temp-and c1 c2 anc) (list 'temp-and c1 c2 anc))
(define-spanned-op temp-and proc-temp-and)

(define (proc-temp-and-lin lhs-ws rhs-ws anc [neg-l? #f] [neg-r? #f])
  (list 'temp-and-lin lhs-ws rhs-ws anc neg-l? neg-r?))
(define-spanned-op temp-and-lin proc-temp-and-lin)

(define (proc-prepare-dicke-le1 ws w0 w1 b-mask)
  (list 'prepare-dicke-le1 ws w0 w1 b-mask))
(define-spanned-op prepare-dicke-le1 proc-prepare-dicke-le1)

(define mbu-u4-sym-counter (box 0))
(define (fresh-u4-meas-sym!)
  (define idx (unbox mbu-u4-sym-counter))
  (set-box! mbu-u4-sym-counter (add1 idx))
  (string->symbol (format "__u4_mx_~a" idx)))

(define (proc-mid-meas-x anc m-sym) (list 'mid-meas-x anc m-sym #t))
(define-spanned-op mid-meas-x proc-mid-meas-x)

(define (proc-mid-meas-x-unshielded anc m-sym) (list 'mid-meas-x anc m-sym #f))
(define-spanned-op mid-meas-x-unshielded proc-mid-meas-x-unshielded)

(define (proc-cond-z m-sym t) (list 'cond-z m-sym t))
(define-spanned-op cond-z proc-cond-z)

(define (proc-cond-cz m-sym c1 c2) (list 'cond-cz m-sym c1 c2))
(define-spanned-op cond-cz proc-cond-cz)

(define (proc-mid-meas-x-cond-z anc target [m-sym #f])
  (define sym (or m-sym (fresh-u4-meas-sym!)))
  (proc-seq (proc-mid-meas-x anc sym)
            (proc-cond-z sym target)))
(define-spanned-op mid-meas-x-cond-z proc-mid-meas-x-cond-z)

(define (proc-syndrome-plaquette ws code-dist #:schedule [sched 'nzsw-orthogonal])
  (list 'syndrome-plaquette ws code-dist (eq? sched 'aligned)))
(define-spanned-op syndrome-plaquette proc-syndrome-plaquette)

;; =============================================================================
;; 5. `defqfree` Basis-Preserving (`qfree`) Static Discipline Check
;; =============================================================================

(define (check-qfree-ast! circ-name ast)
  (let walk ([e ast])
    (match e
      ['skip (void)]
      ['braun-leaf (void)]
      [(or `(x ,_) `(cx ,_ ,_) `(ccx ,_ ,_ ,_) `(swap ,_ ,_)
           `(cswap-bit ,_ ,_ ,_) `(cswap-word ,_ ,_ ,_)
           `(mcx ,_ ,_ ,_) `(temp-and ,_ ,_ ,_) `(temp-and-lin . ,_)
           `(logical-relabel ,_ ,_)
           `(mid-meas-x . ,_) `(cond-z . ,_) `(cond-cz . ,_))
       (void)]
      [(or `(h ,_) `(qft ,_) `(ry . ,_) `(rz-dyadic . ,_) `(z ,_) `(s ,_) `(s-dag ,_)
           `(cz ,_ ,_) `(ccz ,_ ,_ ,_) `(mcz . ,_) `(syndrome-plaquette . ,_)
           `(prepare-dicke-le1 . ,_)
           `(guard-valid-if . ,_) `(guard-qblock-lcu-phase . ,_))
       (error 'defqfree
              "Non-basis quantum gate ~a forbidden inside defqfree circuit `~a`"
              e circ-name)]
      [`(seq ,es ...) (for ([sub (in-list es)]) (walk sub))]
      [`(invert ,sub) (walk sub)]
      [`(call-q ,callee . ,_)
       (unless (and (lfq-circuit-decl? callee)
                    (eq? (lfq-circuit-decl-kind callee) 'defqfree))
         (error 'defqfree
                "Non-qfree callee `~a` forbidden inside defqfree circuit `~a`"
                (if (lfq-circuit-decl? callee) (lfq-circuit-decl-name callee) callee)
                circ-name))]
      [`(with-and-session ,_ ,body) (walk body)]
      [`(within-apply-mbu ,c ,a ,_) (walk c) (walk a)]
      [`(within-apply ,c ,a ,_) (walk c) (walk a)]
      [`(erase-by ,f ,b ,_) (walk f) (walk b)]
      [`(erase-by-part-bij ,_ ,f ,b ,_) (walk f) (walk b)]
      [`(guard-involutory ,_ ,_ ,b) (walk b)]
      [`(guard-wire-basis ,_ ,b) (walk b)]
      [`(guard-drift-eps ,_ ,b) (walk b)]
      [`(guard-single-ir ,_ ,b) (walk b)]
      [`(guard-par-partition ,_ ,b) (walk b)]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,node) (walk node)]
      [`(braun-branch ,_ ,step ,l ,r) (walk step) (walk l) (walk r)]
      [`(par-wires ,e1 ,e2) (walk e1) (walk e2)]
      [`(multishot-reset ,_ ,b) (walk b)]
      [_ (error 'defqfree "Unrecognized form in defqfree `~a`: ~a" circ-name e)])))

;; =============================================================================
;; 6. Module-Level Registration & `#%module-begin` for `#lang lakefillq`
;; =============================================================================

(define current-lfq-target-box (make-parameter #f))
(define current-lfq-circuits-box (make-parameter #f))
(define current-lfq-clusters-box (make-parameter #f))

(define (validate-lfq-target-sym! sym [span #f])
  (unless (memq sym '(heron-r2 bluvstein-aod bb-qldpc ideal))
    (raise (exn:fail:lfq-surface
            (format "Unsupported target profile `~a`; expected heron-r2, bluvstein-aod, bb-qldpc, or ideal"
                    sym)
            (current-continuation-marks)
            "LFQ-E-TARGET-PROFILE"
            span
            "Choose one of `(target-profile heron-r2)`, `(target-profile bluvstein-aod)`, `(target-profile bb-qldpc)`, or `(target-profile ideal)`.")))
  sym)

(define (register-lfq-target! sym [span #f])
  (validate-lfq-target-sym! sym span)
  (define bx (current-lfq-target-box))
  (when bx (set-box! bx sym)))

(define-syntax (lfq-normalize-target-opt stx)
  (syntax-parse stx
    [(_ #f _span-e:expr) #'#f]
    [(_ ((~datum quote) sym:id) span-e:expr)
     #'(validate-lfq-target-sym! 'sym span-e)]
    [(_ sym:id span-e:expr)
     #:when (memq (syntax-e #'sym) '(heron-r2 bluvstein-aod bb-qldpc ideal))
     #'(validate-lfq-target-sym! 'sym span-e)]
    [(_ expr:expr span-e:expr)
     #'(let ([v expr])
         (and v (validate-lfq-target-sym! v span-e)))]))

(define (register-lfq-circuit! decl)
  ;; Note: `defqfree` basis-preserving checking (`LFQ-E-QFREE-BASIS`) runs as a
  ;; structured, span-preserving diagnostic pass in `compile-lfq-circuit` so
  ;; violations report resugared register names and `file:line:col` provenance!
  (define bx (current-lfq-circuits-box))
  (when bx (set-box! bx (append (unbox bx) (list decl))))
  decl)

(define (build-cluster-profile-entry profile-name
                                     #:workload [workload profile-name]
                                     #:paradigm [paradigm 'algebraic-limb]
                                     #:max-machines [max-machines 256]
                                     #:q-cap [q-cap #f]
                                     #:q-cap-per-machine [q-cap-per-machine #f]
                                     #:r-bell-hz [r-bell-hz #f]
                                     #:raw-bell-rate-hz [raw-bell-rate-hz #f]
                                     #:raw-per-logical-ebit [raw-per-logical-ebit 30]
                                     #:q-single [q-single 'auto]
                                     #:q-data-dist [q-data-dist 'auto]
                                     #:q-local-fixed [q-local-fixed 0]
                                     #:q-peer-sync [q-peer-sync 0]
                                     #:candidate-machines [candidate-machines '(1 2 4 6 8 12 16 24 32 48 64 96 128 256)]
                                     #:window-bits [window-bits 0]
                                     #:num-windows [num-windows 0]
                                     #:local-toffolis [local-toffolis 'auto]
                                     #:carry-scheme [carry-scheme 'none]
                                     #:lookup-scheme [lookup-scheme 'none]
                                     #:interconnect-topology [interconnect-topology 'all-to-all-peers]
                                     #:total-shots [total-shots #f]
                                     #:strict-parallel? [strict-parallel? #f]
                                     #:qpu-wire-slices [qpu-wire-slices #f]
                                     #:verify-circuit-match? [verify-circuit-match? #f]
                                     #:surface-span [surface-span #f])
  (define eff-q-cap (or q-cap q-cap-per-machine 400))
  (define eff-r-bell (or r-bell-hz raw-bell-rate-hz 100000.0))
  (define spec
    (par-cluster-opt-spec
     #:workload workload
     #:paradigm paradigm
     #:max-machines max-machines
     #:q-cap-per-machine eff-q-cap
     #:raw-bell-rate-hz eff-r-bell
     #:raw-per-logical-ebit raw-per-logical-ebit
     #:q-single q-single
     #:q-data-dist q-data-dist
     #:q-local-fixed q-local-fixed
     #:q-peer-sync q-peer-sync
     #:candidate-machines candidate-machines
     #:window-bits window-bits
     #:num-windows num-windows
     #:local-toffolis local-toffolis
     #:carry-scheme carry-scheme
     #:lookup-scheme lookup-scheme
     #:interconnect-topology interconnect-topology
     #:total-shots total-shots
     #:strict-parallel? strict-parallel?))
  (attach-cluster-profile-meta!
   (lfq-cluster-profile-entry profile-name spec qpu-wire-slices)
   (hasheq 'verify_circuit_match verify-circuit-match?
           'surface_span surface-span)))

(define (register-lfq-cluster-profile! entry)
  (define bx (current-lfq-clusters-box))
  (when bx (set-box! bx (append (unbox bx) (list entry))))
  (lfq-cluster-profile-entry-spec entry))

(define-syntax (target-profile stx)
  (syntax-parse stx
    [(_ ((~datum quote) sym:id))
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(register-lfq-target! 'sym (lfq-surface-span s l c f 'LakefillQ))))]
    [(_ sym:id)
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(register-lfq-target! 'sym (lfq-surface-span s l c f 'LakefillQ))))]))

(define-syntax (define-cluster-profile stx)
  (syntax-parse stx
    [(_ prof-id:id kw-arg ...)
     (let-values ([(src ln col frm) (stx->span-parts stx)])
       (with-syntax ([s src] [l ln] [c col] [f frm])
         #'(define prof-id
             (register-lfq-cluster-profile!
              (build-cluster-profile-entry
               'prof-id
               #:surface-span (lfq-surface-span s l c f 'LakefillQ)
               kw-arg ...)))))]))

(define-syntax-rule (defconst id val-expr)
  (define id val-expr))

(begin-for-syntax
  (define (clause->span-stx cl-stx)
    (let-values ([(cs cl cc cf) (stx->span-parts cl-stx)])
      (with-syntax ([cs-d cs] [cl-d cl] [cc-d cc] [cf-d cf])
        #'(lfq-surface-span cs-d cl-d cc-d cf-d 'LakefillQ))))

  (define (expand-defq-form stx kind-sym)
    (syntax-parse stx
      [(_ (circ-name:id
           (~alt
            (~once (~seq #:wires ((~and w-clause [w-id:id w-expr:expr]) ...)))
            (~optional (~seq #:scratch ((~and s-clause [s-id:id s-expr:expr]) ...))
                       #:defaults ([(s-clause 1) '()] [(s-id 1) '()] [(s-expr 1) '()]))
            (~optional (~seq #:domain dom-expr:expr) #:defaults ([dom-expr #'all]))
            (~optional (~seq #:target tgt-expr:expr) #:defaults ([tgt-expr #'#f]))) ...)
          body ...+)
       (let-values ([(src ln col _full-frm) (stx->span-parts stx)]
                    [(_hsrc _hln _hcol hdr-frm) (stx->span-parts (cadr (syntax->list stx)))])
         (with-syntax ([kind-d kind-sym]
                       [s src]
                       [l ln]
                       [c col]
                       [f (format "(~a ~a ...)" kind-sym hdr-frm)]
                       [(w-sp ...) (map clause->span-stx (syntax->list #'(w-clause ...)))]
                       [(s-sp ...) (map clause->span-stx (syntax->list #'(s-clause ...)))]
                       [(w-tmp ...) (generate-temporaries #'(w-id ...))]
                       [(s-tmp ...) (generate-temporaries #'(s-id ...))])
           #'(define circ-name
               (let ([qvec-box (box 0)])
                 (parameterize ([current-qvec-allocator-box qvec-box])
                   (bind-lfq-register-clauses
                    ([w-id (advance-qvec-watermark! w-expr) w-tmp] ...
                     [s-id (advance-qvec-watermark! s-expr) s-tmp] ...)
                    (let* ([decl-sp (lfq-surface-span s l c f 'LakefillQ)]
                           [tgt-sym (lfq-normalize-target-opt tgt-expr decl-sp)]
                           [w-groups (list (cons 'w-id w-tmp) ...)]
                           [s-groups (list (cons 's-id s-tmp) ...)]
                           [grp-spans (make-immutable-hasheq
                                       (list (cons 'w-id w-sp) ...
                                             (cons 's-id s-sp) ...))]
                           [flat-w (append w-tmp ...)]
                           [flat-s (append s-tmp ...)]
                           [dom dom-expr]
                           [ast (lfq-seq-block body ...)])
                      (register-lfq-circuit!
                       (attach-decl-target!
                        (attach-decl-group-spans!
                         (attach-surface-span!
                          (lfq-circuit-decl 'circ-name
                                            'kind-d
                                            w-groups
                                            s-groups
                                            flat-w
                                            flat-s
                                            dom
                                            ast)
                          decl-sp)
                         grp-spans)
                        tgt-sym)))))))))]
      [(_ bad-hdr:id . _)
       (raise-syntax-error
        kind-sym
        "expected parenthesized circuit header `(name #:wires ([reg (qvec n)] ...) [#:scratch (...)] [#:domain ...] [#:target ...])`"
        stx
        #'bad-hdr)])))

(define-syntax (defq stx)
  (expand-defq-form stx 'defq))

(define-syntax (defqfree stx)
  (expand-defq-form stx 'defqfree))

(define-syntax (lakefillq-module-begin stx)
  (syntax-parse stx
    [(_ top-form ...)
     #:with prog-spec-id (datum->syntax stx 'lakefillq-program-spec)
     #'(#%plain-module-begin
        (define mod-target-box (box 'ideal))
        (define mod-circuits-box (box '()))
        (define mod-clusters-box (box '()))
        (parameterize ([current-lfq-target-box mod-target-box]
                       [current-lfq-circuits-box mod-circuits-box]
                       [current-lfq-clusters-box mod-clusters-box])
          top-form ...
          (void))
        (define prog-spec-id
          (register-program-cluster-profiles!
           (lfq-program (format "~a" 'lakefillq-module)
                        (unbox mod-target-box)
                        (unbox mod-circuits-box))
           (unbox mod-clusters-box)))
        (provide prog-spec-id)
        (module+ main
          (define run-fn
            (dynamic-require lakefillqc-driver-path 'run-lfq-module-default-cli!))
          (run-fn prog-spec-id)))]))
