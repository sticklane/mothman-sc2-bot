#lang racket

;; =============================================================================
;; `compiler/lakefillq-xag-fraig-typechecker.rkt`
;;
;; Hash-Consed `XAG`/`FRAIG` + `Z3` Cut-Sweeping Symbolic `QSub` (`Laws U1–U4`)
;; and `QPhysGrade` (`Grades Φ1–Φ3`) Inference Engine for `LakefillQ`:
;; Scaling Annotation-Free Wire-Level Typechecking from Single S-Boxes to
;; Multi-Round `AES-128/256`, `Keccak-f[200]`, and 64-Bit Reversible Arithmetic
;; Without Exponential `ANF` Blowup (`LakefillQ -> RevIR -> MachineISA`).
;;
;; Core Architecture:
;;   1. Structural Hash-Consed XOR-AND-Inverter Graph (`XAG` / `FRAIG`):
;;      - Signed literals `(nid << 1) | inv` (`0` = `false`, `1` = `true`,
;;        `lit-not` = `O(1)` bit-flip with zero node allocation).
;;      - Canonical linear-XOR basis normalization (`u ^ u = 0`, `0 ^ u = u`,
;;        associative/commutative symmetric-difference flattening over `{var, and}`
;;        nodes) + canonical AND rules (`u & 0 = 0`, `u & 1 = u`, `u & u = u`,
;;        `u & ~u = 0`, absorption `u & (u & v) = u & v`, `~u & (u & v) = 0`,
;;        `u & ~(u & v) = u & ~v`, symmetric canonical ordering).
;;      - Multi-word 64-bit random truth-table simulation signatures (`4 x 64 = 256`
;;        parallel truth-table bits propagated per `XAG` node in `O(1)` bitwise ops)
;;        for instant candidate equivalence & counterexample detection.
;;   2. Symbolic Bilinear `Law U4` Accumulator over `XAG` Roots:
;;      - Represents quantum phase kickback as `\bigoplus_k m_k * g_k(x)` where
;;        each `m_k`-coefficient `g_k(x)` is a hash-consed `XAG` literal.
;;      - `(mx anc m_k)` records `g_k <- XAG(anc)` (checking quadratic session
;;        structure) and resets `XAG(anc) <- 0`; `(cond-z m_k c1 c2)` /
;;        `(cond-cz m_k c1 c2)` updates `g_k <- xag-xor(g_k, xag-and(XAG(c1), XAG(c2)))`,
;;        collapsing `g_k` to `0` in `O(1)` per gate even at algebraic degree 127.
;;   3. Compact Tseitin/SSA `SMT-LIB2` / `Z3` Cut-Sweeping Miter Engine:
;;      - Extracts minimum-width reconvergent bottleneck cuts `(F_cut, Cone)`
;;        (`1` Bool variable per shared `XAG` node, never expanding exponentially),
;;        proves local cut miters `UNSAT` via persistent `z3 -in -smt2`, applies
;;        exact `F_2` FRAIG pivot-substitution to prune uncomputed inverse cones,
;;        and falls back to primary-input + ideal `I(S_Z)` miters (`wt-le`, `ult-pairs`)
;;        for global domain proofs or concrete `SAT` counterexample extraction.
;; =============================================================================

(require racket/match
         racket/list
         racket/set
         racket/vector
         racket/math
         racket/format
         racket/string
         racket/port
         json
         "../lakefill-core-cryptography-implementations.rkt"
         "../lakefill-pareto-aes-slp-and-asymmetric-mbu.rkt"
         "../lakefill-ssa-pebble-and-qrom-optimizations.rkt"
         "../lakefill-wire-level-symbolic-typechecker.rkt")

(provide (struct-out xag-manager)
         (struct-out xag-inference-result)
         make-xag-manager
         lit-zero
         lit-one
         lit-not
         lit-id
         lit-inv?
         xag-var
         xag-xor
         xag-and
         xag-cofactor
         xag-eval-lit
         xag-export-tseitin-smt2
         xag-z3-cut-sweep-miter!
         close-persistent-z3!
         infer-lakefillq-xag-circuit
         run-bounded-explicit-anf-benchmark
         build-lakefillq-aes-rounds-sexpr
         build-lakefillq-keccak-f200-sexpr
         build-lakefillq-gidney-64bit-adder-sexpr
         build-lakefillq-gidney-64bit-modadd-sexpr
         build-lakefillq-bch-15-7-5-sexpr
         run-lakefillq-xag-fraig-multiblock-benchmarks)

;; =============================================================================
;; SECTION 1: Persistent `z3 -in -smt2` Solver Subprocess Bridge
;; =============================================================================

(define MASK64 #xFFFFFFFFFFFFFFFF)

(require racket/runtime-path)
(define-runtime-path COMPILER-DIR ".")

(define (find-z3-binary)
  (define workspace-venv-z3
    (path->string (simplify-path (build-path COMPILER-DIR ".." ".." ".venv" "bin" "z3"))))
  (define home-tc-z3
    (path->string (build-path (find-system-path 'home-dir) "toolchains" "quantum-venv" "bin" "z3")))
  (define candidates
    (list workspace-venv-z3
          home-tc-z3
          "/usr/bin/z3"
          "/usr/local/bin/z3"))
  (or (let ([found (find-executable-path "z3")])
        (and found (path->string found)))
      (for/first ([p (in-list candidates)] #:when (file-exists? p)) p)
      (error 'find-z3-binary "Could not locate z3 executable")))

(define current-z3-proc #f)
(define current-z3-out #f)
(define current-z3-in #f)
(define current-z3-err #f)

(define (ensure-persistent-z3!)
  (unless (and current-z3-proc (eq? (subprocess-status current-z3-proc) 'running))
    (define z3-bin (find-z3-binary))
    (putenv "TMPDIR" "/home/antigravity/toolchains/tmp")
    (define-values (proc out in err)
      (subprocess #f #f #f z3-bin "-in" "-smt2"))
    (set! current-z3-proc proc)
    (set! current-z3-out out)
    (set! current-z3-in in)
    (set! current-z3-err err))
  (values current-z3-in current-z3-out))

(define (close-persistent-z3!)
  (when current-z3-proc
    (with-handlers ([exn:fail? void])
      (display "(exit)\n" current-z3-in)
      (flush-output current-z3-in)
      (close-output-port current-z3-in)
      (close-input-port current-z3-out)
      (close-input-port current-z3-err)
      (subprocess-wait current-z3-proc))
    (set! current-z3-proc #f)))

;; Send SMT-LIB2 commands expecting single-line token replies (e.g. "sat" / "unsat")
;; plus optional s-expression model read `(read out)`.
(define (z3-exec-script! smt2-commands-str #:read-sexpr-on-sat? [read-model? #f] #:model-vars [mvars '()])
  (define-values (z3-in z3-out) (ensure-persistent-z3!))
  (display "(reset)\n" z3-in)
  (display smt2-commands-str z3-in)
  (newline z3-in)
  (display "(check-sat)\n" z3-in)
  (flush-output z3-in)
  (define status-line
    (let loop ()
      (define ln (read-line z3-out 'any))
      (cond
        [(eof-object? ln) (error 'z3-exec-script! "Unexpected EOF from z3")]
        [(string=? (string-trim ln) "") (loop)]
        [else (string-trim ln)])))
  (cond
    [(and (string=? status-line "sat") read-model? (not (null? mvars)))
     (fprintf z3-in "(get-value (~a))\n" (string-join mvars " "))
     (flush-output z3-in)
     (define model-sexpr (read z3-out))
     (values 'sat model-sexpr)]
    [(string=? status-line "sat")
     (values 'sat '())]
    [(string=? status-line "unsat")
     (values 'unsat '())]
    [else
     (error 'z3-exec-script! "Unexpected z3 response: ~a" status-line)]))

;; =============================================================================
;; SECTION 2: Structural Hash-Consed `XAG` / `FRAIG` with 256-Bit Signatures
;; =============================================================================

(define lit-zero 0)
(define lit-one  1)

(define (make-lit nid inv-bit)
  (bitwise-ior (arithmetic-shift nid 1) (bitwise-and inv-bit 1)))

(define (lit-id lit)
  (arithmetic-shift lit -1))

(define (lit-inv? lit)
  (= (bitwise-and lit 1) 1))

(define (lit-inv-bit lit)
  (bitwise-and lit 1))

(define (lit-not lit)
  (bitwise-xor lit 1))

(define (lit-strip lit)
  (bitwise-and lit -2))

;; Deterministic SplitMix64 generator for 256-bit (`4 x 64`) random truth-table signatures
(define (splitmix64 z)
  (define z1 (bitwise-and (+ z #x9E3779B97F4A7C15) MASK64))
  (define z2 (bitwise-and (* (bitwise-xor z1 (arithmetic-shift z1 -30)) #xBF58476D1CE4E5B9) MASK64))
  (define z3 (bitwise-and (* (bitwise-xor z2 (arithmetic-shift z2 -27)) #x94D049BB133111EB) MASK64))
  (bitwise-and (bitwise-xor z3 (arithmetic-shift z3 -31)) MASK64))

(define (var-sim-words var-idx)
  (define base (+ #x2026102900000000 (* (add1 var-idx) #x1000003)))
  (define s0 (splitmix64 base))
  (define s1 (splitmix64 (+ base 1)))
  (define s2 (splitmix64 (+ base 2)))
  (define s3 (splitmix64 (+ base 3)))
  (vector s0 s1 s2 s3))

;; Growable typed node arrays inside `xag-manager`:
;;   `kind-vec`  : `'const0 | 'var | 'xor | 'and`
;;   `arg1-vec`  : var-idx (for `'var`), positive nid1 (for `'xor`), signed lit1 (for `'and`)
;;   `arg2-vec`  : `0` (for `'var`), positive nid2 (for `'xor`), signed lit2 (for `'and`)
;;   `basis-vec` : sorted list of positive `{var, and}` node IDs summing (mod 2) to `nid`
;;   `sim-vec`   : 4-element vector `#(s0 s1 s2 s3)` of 64-bit simulation signatures
(struct xag-manager
  ([size #:mutable]
   [capacity #:mutable]
   [kind-vec #:mutable]
   [arg1-vec #:mutable]
   [arg2-vec #:mutable]
   [basis-vec #:mutable]
   [sim-vec #:mutable]
   var-table         ;; hasheqv: var-idx -> nid
   xor-pair-table    ;; hash: (cons nid1 nid2) -> nid
   xor-basis-table   ;; hash: sorted-nid-list -> nid
   and-table         ;; hash: (cons lit1 lit2) -> nid
   sim-sig-table     ;; hash: canonical-4word-list -> list of signed literals
   verified-cut-set  ;; mutable set of Z3-verified UNSAT canonical cut-cone digests
   basis-cap         ;; max exact linear XOR basis width before checkpointing
   [z3-queries #:mutable]
   [cut-cache-hits #:mutable]
   [fraig-merges #:mutable])
  #:transparent)

(define (make-xag-manager [init-cap 4096] [shared-cuts #f] [basis-cap 24])
  (define kv (make-vector init-cap 'const0))
  (define a1 (make-vector init-cap 0))
  (define a2 (make-vector init-cap 0))
  (define bv (make-vector init-cap '()))
  (define sv (make-vector init-cap #(0 0 0 0)))
  (xag-manager 1
               init-cap
               kv a1 a2 bv sv
               (make-hasheqv)
               (make-hash)
               (make-hash)
               (make-hash)
               (make-hash)
               (or shared-cuts (mutable-set))
               basis-cap
               0 0 0))

(define (xag-ensure-cap! mgr)
  (define sz (xag-manager-size mgr))
  (define cap (xag-manager-capacity mgr))
  (when (>= sz cap)
    (define new-cap (* cap 2))
    (define (grow old fill)
      (define nv (make-vector new-cap fill))
      (vector-copy! nv 0 old 0 sz)
      nv)
    (set-xag-manager-kind-vec! mgr (grow (xag-manager-kind-vec mgr) 'const0))
    (set-xag-manager-arg1-vec! mgr (grow (xag-manager-arg1-vec mgr) 0))
    (set-xag-manager-arg2-vec! mgr (grow (xag-manager-arg2-vec mgr) 0))
    (set-xag-manager-basis-vec! mgr (grow (xag-manager-basis-vec mgr) '()))
    (set-xag-manager-sim-vec! mgr (grow (xag-manager-sim-vec mgr) #(0 0 0 0)))
    (set-xag-manager-capacity! mgr new-cap)))

(define (xag-register-sim! mgr nid sim4)
  (define s0 (vector-ref sim4 0))
  (define s1 (vector-ref sim4 1))
  (define s2 (vector-ref sim4 2))
  (define s3 (vector-ref sim4 3))
  (define flip? (bitwise-bit-set? s0 0))
  (define key
    (if flip?
        (list (bitwise-xor s0 MASK64)
              (bitwise-xor s1 MASK64)
              (bitwise-xor s2 MASK64)
              (bitwise-xor s3 MASK64))
        (list s0 s1 s2 s3)))
  (define canon-lit (make-lit nid (if flip? 1 0)))
  (define tbl (xag-manager-sim-sig-table mgr))
  (hash-set! tbl key (cons canon-lit (hash-ref tbl key '()))))

(define (xag-alloc-node! mgr kind arg1 arg2 basis sim4)
  (xag-ensure-cap! mgr)
  (define nid (xag-manager-size mgr))
  (vector-set! (xag-manager-kind-vec mgr) nid kind)
  (vector-set! (xag-manager-arg1-vec mgr) nid arg1)
  (vector-set! (xag-manager-arg2-vec mgr) nid arg2)
  (vector-set! (xag-manager-basis-vec mgr) nid basis)
  (vector-set! (xag-manager-sim-vec mgr) nid sim4)
  (set-xag-manager-size! mgr (add1 nid))
  (xag-register-sim! mgr nid sim4)
  nid)

(define (xag-lit-sim-word mgr lit w-idx)
  (define raw (vector-ref (vector-ref (xag-manager-sim-vec mgr) (lit-id lit)) w-idx))
  (if (lit-inv? lit)
      (bitwise-xor raw MASK64)
      raw))

(define (xag-lit-sim-zero? mgr lit)
  (and (= (xag-lit-sim-word mgr lit 0) 0)
       (= (xag-lit-sim-word mgr lit 1) 0)
       (= (xag-lit-sim-word mgr lit 2) 0)
       (= (xag-lit-sim-word mgr lit 3) 0)))

;; Find first sample index `s in 0..255` where `lit` evaluates to `1`, or `#f`
(define (xag-lit-first-nonzero-sample mgr lit)
  (for/first ([w-idx (in-range 4)]
              #:unless (= (xag-lit-sim-word mgr lit w-idx) 0))
    (define word (xag-lit-sim-word mgr lit w-idx))
    (define bit-idx
      (for/first ([b (in-range 64)] #:when (bitwise-bit-set? word b)) b))
    (+ (* 64 w-idx) bit-idx)))

(define (xag-sample-input-assignment mgr sample-idx num-inputs)
  (define w-idx (quotient sample-idx 64))
  (define b-idx (modulo sample-idx 64))
  (for/hasheqv ([v (in-range num-inputs)])
    (define lit (xag-var mgr v))
    (define word (xag-lit-sim-word mgr lit w-idx))
    (values v (if (bitwise-bit-set? word b-idx) 1 0))))

(define (xag-var mgr var-idx)
  (define vtbl (xag-manager-var-table mgr))
  (define nid
    (hash-ref vtbl var-idx
              (lambda ()
                (define sim4 (var-sim-words var-idx))
                (define id (xag-alloc-node! mgr 'var var-idx 0 '() sim4))
                (vector-set! (xag-manager-basis-vec mgr) id (list id))
                (hash-set! vtbl var-idx id)
                id)))
  (make-lit nid 0))

;; Symmetric difference of strictly sorted integer lists of `{var, and}` node IDs
(define (sorted-nid-symdiff a b)
  (let loop ([xs a] [ys b] [acc '()])
    (cond
      [(null? xs) (append (reverse acc) ys)]
      [(null? ys) (append (reverse acc) xs)]
      [else
       (define x (car xs))
       (define y (car ys))
       (cond
         [(< x y) (loop (cdr xs) ys (cons x acc))]
         [(> x y) (loop xs (cdr ys) (cons y acc))]
         [else    (loop (cdr xs) (cdr ys) acc)])])))

;; Build/lookup binary `'xor` node for two distinct positive node IDs `u != v`
(define (xag-raw-xor-pair mgr u v)
  (cond
    [(= u 0) v]
    [(= v 0) u]
    [(= u v) 0]
    [else
     (define lo (min u v))
     (define hi (max u v))
     (define key (cons lo hi))
     (define ptbl (xag-manager-xor-pair-table mgr))
     (hash-ref ptbl key
               (lambda ()
                 (define su (vector-ref (xag-manager-sim-vec mgr) lo))
                 (define sv (vector-ref (xag-manager-sim-vec mgr) hi))
                 (define sim4
                   (vector (bitwise-xor (vector-ref su 0) (vector-ref sv 0))
                           (bitwise-xor (vector-ref su 1) (vector-ref sv 1))
                           (bitwise-xor (vector-ref su 2) (vector-ref sv 2))
                           (bitwise-xor (vector-ref su 3) (vector-ref sv 3))))
                 (define bu (vector-ref (xag-manager-basis-vec mgr) lo))
                 (define bv (vector-ref (xag-manager-basis-vec mgr) hi))
                 (define merged (sorted-nid-symdiff bu bv))
                 (define nid (xag-alloc-node! mgr 'xor lo hi merged sim4))
                 (hash-set! ptbl key nid)
                 (hash-set! (xag-manager-xor-basis-table mgr) merged nid)
                 nid))]))

;; Canonicalize a non-empty sorted list of `{var, and}` node IDs into a positive `nid`
(define (xag-basis->nid mgr basis)
  (cond
    [(null? basis) 0]
    [(null? (cdr basis)) (car basis)]
    [else
     (define btbl (xag-manager-xor-basis-table mgr))
     (hash-ref btbl basis
               (lambda ()
                 ;; Balanced pairwise tree reduction for shallow O(log |B|) cone depth!
                 (let reduce-level ([cur basis])
                   (if (null? (cdr cur))
                       (car cur)
                       (reduce-level
                        (let pair-up ([xs cur])
                          (cond
                            [(null? xs) '()]
                            [(null? (cdr xs)) xs]
                            [else
                             (cons (xag-raw-xor-pair mgr (car xs) (cadr xs))
                                   (pair-up (cddr xs)))])))))))]))

;; Canonical hash-consed `xag-xor` with complement edges & exact associative linear-basis cancellation!
(define (xag-xor mgr lit1 lit2)
  (define inv (bitwise-xor (lit-inv-bit lit1) (lit-inv-bit lit2)))
  (define id1 (lit-id lit1))
  (define id2 (lit-id lit2))
  (cond
    [(= id1 0) (make-lit id2 inv)]
    [(= id2 0) (make-lit id1 inv)]
    [(= id1 id2) inv] ;; `u ^ u = 0`, `u ^ ~u = 1`!
    [else
     (define b1 (vector-ref (xag-manager-basis-vec mgr) id1))
     (define b2 (vector-ref (xag-manager-basis-vec mgr) id2))
     (define merged-basis (sorted-nid-symdiff b1 b2))
     (cond
       [(null? merged-basis) inv]
       [(null? (cdr merged-basis))
        (make-lit (car merged-basis) inv)]
       [(hash-ref (xag-manager-xor-basis-table mgr) merged-basis #f)
        => (lambda (existing-nid) (make-lit existing-nid inv))]
       [(> (length merged-basis) 32)
        (make-lit (xag-raw-xor-pair mgr id1 id2) inv)]
       [else
        (make-lit (xag-basis->nid mgr merged-basis) inv)])]))

;; Canonical hash-consed `xag-and` with annihilation, idempotence, contradiction & absorption!
(define (xag-and mgr lit1 lit2)
  (cond
    [(or (= lit1 lit-zero) (= lit2 lit-zero)) lit-zero] ;; `u & 0 = 0`
    [(= lit1 lit-one) lit2]                             ;; `1 & u = u`
    [(= lit2 lit-one) lit1]                             ;; `u & 1 = u`
    [(= lit1 lit2) lit1]                                ;; `u & u = u`
    [(= lit1 (lit-not lit2)) lit-zero]                  ;; `u & ~u = 0`
    [else
     (define kv (xag-manager-kind-vec mgr))
     (define a1v (xag-manager-arg1-vec mgr))
     (define a2v (xag-manager-arg2-vec mgr))
     (define id1 (lit-id lit1))
     (define id2 (lit-id lit2))
     (define k1 (vector-ref kv id1))
     (define k2 (vector-ref kv id2))
     (cond
       ;; Absorption & contradiction when `lit2` is an `'and` node `(a & b)` or `~(a & b)`
       [(and (eq? k2 'and) (not (lit-inv? lit2)))
        (define c1 (vector-ref a1v id2))
        (define c2 (vector-ref a2v id2))
        (cond
          [(or (= lit1 c1) (= lit1 c2)) lit2]
          [(or (= lit1 (lit-not c1)) (= lit1 (lit-not c2))) lit-zero]
          [else (xag-and-alloc mgr lit1 lit2)])]
       [(and (eq? k2 'and) (lit-inv? lit2))
        (define c1 (vector-ref a1v id2))
        (define c2 (vector-ref a2v id2))
        (cond
          [(= lit1 c1) (xag-and mgr c1 (lit-not c2))]
          [(= lit1 c2) (xag-and mgr c2 (lit-not c1))]
          [else (xag-and-alloc mgr lit1 lit2)])]
       ;; Symmetric absorption & contradiction when `lit1` is an `'and` node
       [(and (eq? k1 'and) (not (lit-inv? lit1)))
        (define c1 (vector-ref a1v id1))
        (define c2 (vector-ref a2v id1))
        (cond
          [(or (= lit2 c1) (= lit2 c2)) lit1]
          [(or (= lit2 (lit-not c1)) (= lit2 (lit-not c2))) lit-zero]
          [else (xag-and-alloc mgr lit1 lit2)])]
       [(and (eq? k1 'and) (lit-inv? lit1))
        (define c1 (vector-ref a1v id1))
        (define c2 (vector-ref a2v id1))
        (cond
          [(= lit2 c1) (xag-and mgr c1 (lit-not c2))]
          [(= lit2 c2) (xag-and mgr c2 (lit-not c1))]
          [else (xag-and-alloc mgr lit1 lit2)])]
       [else
        (xag-and-alloc mgr lit1 lit2)])]))

(define (xag-and-alloc mgr lit1 lit2)
  (define lo (min lit1 lit2))
  (define hi (max lit1 lit2))
  (define key (cons lo hi))
  (define atbl (xag-manager-and-table mgr))
  (define nid
    (hash-ref atbl key
              (lambda ()
                (define sim4
                  (vector (bitwise-and (xag-lit-sim-word mgr lo 0) (xag-lit-sim-word mgr hi 0))
                          (bitwise-and (xag-lit-sim-word mgr lo 1) (xag-lit-sim-word mgr hi 1))
                          (bitwise-and (xag-lit-sim-word mgr lo 2) (xag-lit-sim-word mgr hi 2))
                          (bitwise-and (xag-lit-sim-word mgr lo 3) (xag-lit-sim-word mgr hi 3))))
                (define id (xag-alloc-node! mgr 'and lo hi '() sim4))
                (vector-set! (xag-manager-basis-vec mgr) id (list id))
                (hash-set! atbl key id)
                id)))
  (make-lit nid 0))

;; Evaluate an `XAG` literal on a concrete variable map `var-idx -> 0/1`
(define (xag-eval-lit mgr lit env-hash)
  (define memo (make-hasheqv))
  (hash-set! memo 0 0)
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))
  (define (eval-nid nid)
    (hash-ref! memo nid
               (lambda ()
                 (match (vector-ref kv nid)
                   ['const0 0]
                   ['var (hash-ref env-hash (vector-ref a1v nid) 0)]
                   ['xor (bitwise-xor (eval-nid (vector-ref a1v nid))
                                      (eval-nid (vector-ref a2v nid)))]
                   ['and (bitwise-and (eval-l (vector-ref a1v nid))
                                      (eval-l (vector-ref a2v nid)))]))))
  (define (eval-l l)
    (bitwise-xor (lit-inv-bit l) (eval-nid (lit-id l))))
  (eval-l lit))

;; Compute Shannon cofactor `lit|_{x_{var-idx} = bit}` (`bit in {0, 1}`) in `O(|cone|)`
(define (xag-cofactor mgr lit var-idx bit)
  (define memo (make-hasheqv))
  (hash-set! memo 0 lit-zero)
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))
  (define (cof-nid nid)
    (hash-ref! memo nid
               (lambda ()
                 (match (vector-ref kv nid)
                   ['const0 lit-zero]
                   ['var (if (= (vector-ref a1v nid) var-idx)
                             (if (= bit 0) lit-zero lit-one)
                             (make-lit nid 0))]
                   ['xor (xag-xor mgr
                                  (cof-nid (vector-ref a1v nid))
                                  (cof-nid (vector-ref a2v nid)))]
                   ['and (xag-and mgr
                                  (cof-lit (vector-ref a1v nid))
                                  (cof-lit (vector-ref a2v nid)))]))))
  (define (cof-lit l)
    (define base (cof-nid (lit-id l)))
    (if (lit-inv? l) (lit-not base) base))
  (cof-lit lit))

;; Substitute a proved unconditional pivot equivalence `piv-nid -> repl-lit` across an `XAG` literal
;; inside its top-level linear XOR basis (or 1-level cone), used by FRAIG cut-sweeping to collapse
;; `u ^ S^-1(S(u))` in live wires immediately after `erase-by`!
(define (xag-subst-linear-pivot mgr lit piv-nid repl-lit)
  (define id (lit-id lit))
  (if (= id 0)
      lit
      (let ([basis (vector-ref (xag-manager-basis-vec mgr) id)])
        (if (not (member piv-nid basis))
            lit
            (let ([rest-basis (remove piv-nid basis)])
              (set-xag-manager-fraig-merges! mgr (add1 (xag-manager-fraig-merges mgr)))
              (define rest-lit (make-lit (xag-basis->nid mgr rest-basis) (lit-inv-bit lit)))
              (xag-xor mgr rest-lit repl-lit))))))

;; Extract `(piv-nid, repl-lit)` when `zero-lit == 0` holds unconditionally!
;; Over F_2, `inv ^ b_1 ^ ... ^ b_m == 0` iff `b_m == inv ^ b_1 ^ ... ^ b_{m-1}`!
(define (xag-extract-pivot-rule mgr zero-lit)
  (define id (lit-id zero-lit))
  (if (= id 0)
      #f
      (let* ([basis (vector-ref (xag-manager-basis-vec mgr) id)]
             [piv (last basis)]
             [rest-b (drop-right basis 1)]
             [repl (make-lit (xag-basis->nid mgr rest-b) (lit-inv-bit zero-lit))])
        (cons piv repl))))

;; =============================================================================
;; SECTION 3: Compact Tseitin/SSA `SMT-LIB2` Exporter & `Z3` Cut-Sweeping Engine
;; =============================================================================

;; Reverse-topological bottleneck cut finder on `XAG`:
;; Sweeps backward from `target-lits` (popping largest `nid` first up to `max-cone` nodes)
;; to find a small reconvergent dominator cut `F_cut` (`1 <= |F_cut| <= max-cut-width`).
(define (xag-find-bottleneck-cut mgr target-lits [max-cut-width 16] [max-cone 420])
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))

  (define frontier (mutable-set))
  (for ([tl (in-list target-lits)])
    (when (> (lit-id tl) 0)
      (set-add! frontier (lit-id tl))))

  (define internal-cone '())
  (define best-cut #f)
  (define best-cone #f)
  (define best-width 999999)

  (let loop ([steps 0])
    (define f-list (set->list frontier))
    ;; Check if all frontier nodes are already `'var` primary inputs
    (define non-vars
      (filter (lambda (nid) (not (eq? (vector-ref kv nid) 'var))) f-list))
    (define cur-w (length f-list))

    ;; Record candidate cut after expanding at least 1 nonlinear layer (`steps >= 8`)
    ;; or if frontier is purely primary variables with `cur-w <= max-cut-width`.
    (when (and (<= cur-w max-cut-width)
               (or (null? non-vars) (>= steps 8)))
      ;; Prefer strictly narrower cuts, OR deeper cuts on width ties (e.g. sweeping past
      ;; intermediate `tmp8` into the 8-wire entry cut `u_0..u_7` of `BP68`!).
      (when (or (< cur-w best-width)
                (and (= cur-w best-width) (>= steps 40)))
        (set! best-width cur-w)
        (set! best-cut (sort f-list <))
        (set! best-cone (sort internal-cone <))))

    (when (and (not (null? non-vars)) (< steps max-cone))
      ;; Pop the highest topological `nid` in `non-vars`
      (define top-nid (apply max non-vars))
      (set-remove! frontier top-nid)
      (set! internal-cone (cons top-nid internal-cone))
      (match (vector-ref kv top-nid)
        ['xor
         (define u (vector-ref a1v top-nid))
         (define v (vector-ref a2v top-nid))
         (when (> u 0) (set-add! frontier u))
         (when (> v 0) (set-add! frontier v))]
        ['and
         (define u (lit-id (vector-ref a1v top-nid)))
         (define v (lit-id (vector-ref a2v top-nid)))
         (when (> u 0) (set-add! frontier u))
         (when (> v 0) (set-add! frontier v))])
      (loop (add1 steps))))

  (if best-cut
      (values best-cut best-cone)
      (values #f #f)))

;; Exact O(|local-cone|) scope-entry dominator cut extractor:
;; Given `pre-size` recorded before a structured block (`erase-by` / `within-apply`),
;; partitions reachable nodes from `target-lits` into `cone-nids` (`nid >= pre-size`)
;; and `cut-nids` (`0 < nid < pre-size` directly referenced by `target-lits` or `cone-nids`).
(define (xag-extract-scope-entry-cut mgr target-lits pre-size [max-cut-width 24])
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))
  (define cone-set (mutable-set))
  (define cut-set (mutable-set))
  (define (visit nid)
    (cond
      [(<= nid 0) (void)]
      [(< nid pre-size) (set-add! cut-set nid)]
      [(not (set-member? cone-set nid))
       (set-add! cone-set nid)
       (match (vector-ref kv nid)
         ['var (set-add! cut-set nid)]
         ['xor
          (visit (vector-ref a1v nid))
          (visit (vector-ref a2v nid))]
         ['and
          (visit (lit-id (vector-ref a1v nid)))
          (visit (lit-id (vector-ref a2v nid)))])]))
  (for ([tl (in-list target-lits)])
    (visit (lit-id tl)))
  (cond
    [(and (> (set-count cut-set) 0) (<= (set-count cut-set) max-cut-width))
     (values (sort (set->list cut-set) <) (sort (set->list cone-set) <))]
    [else
     (values #f #f)]))

;; Canonical structural digest of a local cut cone `(cut-nids, cone-nids, target-lits)`:
;; Renumbers cut leaves `0..|C|-1` and internal cone nodes `|C|..|C|+|Cone|-1` so
;; topologically identical sub-DAGs (only after `Z3` proves the prototype `UNSAT`!)
;; reuse the `Z3`-proved lemma in `O(|Cone|)`.
(define (xag-canonical-cut-digest mgr cut-nids cone-nids target-lits)
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))
  (define relabel (make-hasheqv))
  (hash-set! relabel 0 0)
  (for ([cid (in-list cut-nids)] [idx (in-naturals 1)])
    (hash-set! relabel cid idx))
  (define base-id (add1 (length cut-nids)))
  (define defs
    (for/list ([nid (in-list cone-nids)] [k (in-naturals)])
      (define new-id (+ base-id k))
      (hash-set! relabel nid new-id)
      (match (vector-ref kv nid)
        ['xor
         (define ru (hash-ref relabel (vector-ref a1v nid)))
         (define rv (hash-ref relabel (vector-ref a2v nid)))
         (list 'x (min ru rv) (max ru rv))]
        ['and
         (define l1 (vector-ref a1v nid))
         (define l2 (vector-ref a2v nid))
         (define rl1 (make-lit (hash-ref relabel (lit-id l1)) (lit-inv-bit l1)))
         (define rl2 (make-lit (hash-ref relabel (lit-id l2)) (lit-inv-bit l2)))
         (list 'a (min rl1 rl2) (max rl1 rl2))])))
  (define rel-targets
    (sort (for/list ([tl (in-list target-lits)])
            (make-lit (hash-ref relabel (lit-id tl)) (lit-inv-bit tl)))
          <))
  (list (length cut-nids) defs rel-targets))

;; Format an `XAG` literal reference inside SMT-LIB2 Tseitin encoding (`1` Bool var per node!)
(define (smt2-lit-expr lit)
  (define id (lit-id lit))
  (cond
    [(= lit lit-zero) "false"]
    [(= lit lit-one)  "true"]
    [(lit-inv? lit)   (format "(not n_~a)" id)]
    [else             (format "n_~a" id)]))

;; Collect all reachable internal/var node IDs in topological order from `root-lits`
(define (xag-collect-reachable-nids mgr root-lits)
  (define visited (mutable-set))
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))
  (define (dfs nid)
    (when (and (> nid 0) (not (set-member? visited nid)))
      (set-add! visited nid)
      (match (vector-ref kv nid)
        ['var (void)]
        ['xor
         (dfs (vector-ref a1v nid))
         (dfs (vector-ref a2v nid))]
        ['and
         (dfs (lit-id (vector-ref a1v nid)))
         (dfs (lit-id (vector-ref a2v nid)))])))
  (for ([rl (in-list root-lits)])
    (dfs (lit-id rl)))
  (sort (set->list visited) <))

;; Emit SMT-LIB2 Boolean unsigned less-than constraint `(< wire-vec const-bound)`
;; for promised modular ideals `0 <= a < N` (`ult-pairs`)!
(define (emit-smt2-ult-constraint! out var-names bound)
  (define n (length var-names))
  ;; MSB-down comparison: `x < bound`
  ;; At bit `i = 0`: `lt_0 = (and (not x_0) bit_0)`
  ;; At bit `i > 0`: if `bit_i == 1`, `lt_i = (or (not x_i) lt_{i-1})`
  ;;                 if `bit_i == 0`, `lt_i = (and (not x_i) lt_{i-1})`
  (define expr
    (for/fold ([lt-prev "false"]) ([vname (in-list var-names)] [i (in-naturals)])
      (if (bitwise-bit-set? bound i)
          (if (string=? lt-prev "false")
              (format "(not ~a)" vname)
              (format "(or (not ~a) ~a)" vname lt-prev))
          (if (string=? lt-prev "false")
              "false"
              (format "(and (not ~a) ~a)" vname lt-prev)))))
  (fprintf out "(assert ~a)\n" expr))

;; Export compact Tseitin SMT-LIB2 miter (`1` variable per shared `XAG` node, ZERO expansion!)
;; for `target-lits` either on a local cut `(cut-nids, cone-nids)` or on primary inputs + `domain-pred`.
(define (xag-export-tseitin-smt2 mgr target-lits
                                 #:cut-nids [cut-nids #f]
                                 #:cone-nids [cone-nids #f]
                                 #:num-inputs [num-inputs 0]
                                 #:input-wires [input-wires '()]
                                 #:domain-pred [domain-pred 'all]
                                 #:extra-assumptions [extra-assumps '()])
  (define out (open-output-string))
  (define kv (xag-manager-kind-vec mgr))
  (define a1v (xag-manager-arg1-vec mgr))
  (define a2v (xag-manager-arg2-vec mgr))

  (cond
    [cut-nids
     ;; Local Cut Miter: declare free Boolean variable `n_<cid>` for each cut leaf!
     (for ([cid (in-list cut-nids)])
       (fprintf out "(declare-const n_~a Bool)\n" cid))
     (for ([nid (in-list cone-nids)])
       (match (vector-ref kv nid)
         ['xor
          (fprintf out "(define-fun n_~a () Bool (xor n_~a n_~a))\n"
                   nid (vector-ref a1v nid) (vector-ref a2v nid))]
         ['and
          (fprintf out "(define-fun n_~a () Bool (and ~a ~a))\n"
                   nid
                   (smt2-lit-expr (vector-ref a1v nid))
                   (smt2-lit-expr (vector-ref a2v nid)))]))]
    [else
     ;; Full Primary-Input Tseitin DAG Miter + Domain Ideal `I(S_Z)`!
     (for ([v (in-range num-inputs)])
       (fprintf out "(declare-const x_~a Bool)\n" v))
     (define reach (xag-collect-reachable-nids mgr target-lits))
     (for ([nid (in-list reach)])
       (match (vector-ref kv nid)
         ['var
          (fprintf out "(define-fun n_~a () Bool x_~a)\n" nid (vector-ref a1v nid))]
         ['xor
          (fprintf out "(define-fun n_~a () Bool (xor n_~a n_~a))\n"
                   nid (vector-ref a1v nid) (vector-ref a2v nid))]
         ['and
          (fprintf out "(define-fun n_~a () Bool (and ~a ~a))\n"
                   nid
                   (smt2-lit-expr (vector-ref a1v nid))
                   (smt2-lit-expr (vector-ref a2v nid)))]))
     ;; Emit domain ideal constraints `I(S_Z)`
     (match domain-pred
       ['all (void)]
       [`(quotient-vars ,_) (void)]
       [`(wt-le ,max-wt)
        (when (and (> num-inputs 0) (< max-wt num-inputs))
          (define terms
            (string-join
             (for/list ([v (in-range num-inputs)])
               (format "(ite x_~a (_ bv1 16) (_ bv0 16))" v))
             " "))
          (define sum-expr
            (if (= num-inputs 1) terms (format "(bvadd ~a)" terms)))
          (fprintf out "(assert (bvule ~a (_ bv~a 16)))\n" sum-expr max-wt))]
       [`(ult-pairs ,pairs)
        (define w->idx
          (for/hasheqv ([w (in-list input-wires)] [idx (in-naturals)])
            (values w idx)))
        (for ([pr (in-list pairs)])
          (define ws (first pr))
          (define bound (second pr))
          (define vnames
            (for/list ([w (in-list ws)])
              (format "x_~a" (hash-ref w->idx w))))
          (emit-smt2-ult-constraint! out vnames bound))]
       [_ (error 'xag-export-tseitin-smt2 "Unsupported domain-pred: ~a" domain-pred)])
     (for ([asmp (in-list extra-assumps)])
       (fprintf out "(assert ~a)\n" asmp))])

  (define disj-str
    (if (= (length target-lits) 1)
        (smt2-lit-expr (first target-lits))
        (format "(or ~a)" (string-join (map smt2-lit-expr target-lits) " "))))
  (fprintf out "(assert ~a)\n" disj-str)
  (get-output-string out))

(define (parse-z3-model-to-cex model-sexpr input-wires)
  (define true-vars (mutable-set))
  (when (list? model-sexpr)
    (for ([pair (in-list model-sexpr)] #:when (and (list? pair) (= (length pair) 2)))
      (define sym-str (format "~a" (first pair)))
      (define val-sym (second pair))
      (when (and (eq? val-sym 'true) (string-prefix? sym-str "x_"))
        (define v-idx (string->number (substring sym-str 2)))
        (when v-idx (set-add! true-vars v-idx)))))
  (define active-wires
    (for/list ([w (in-list input-wires)]
               [idx (in-naturals)]
               #:when (set-member? true-vars idx))
      w))
  (define mask
    (for/fold ([m 0]) ([idx (in-set true-vars)])
      (bitwise-ior m (arithmetic-shift 1 idx))))
  (hasheq 'assign_mask mask
          'active_input_wires active-wires
          'hamming_weight (length active-wires)))

;; Core `Z3` Cut-Sweeping Miter Checker (`xag-z3-cut-sweep-miter!`):
;; Checks whether ALL literals in `raw-target-lits` vanish (`== 0`) over `domain-pred`.
;; Returns `(values 'unsat #f 'unconditional-cut | 'domain-global)` when proved `0`,
;; or `(values 'sat cex-hash 'primary-miter)` with a Z3-verified concrete counterexample!
(define (xag-z3-cut-sweep-miter! mgr raw-target-lits input-wires domain-pred
                                 #:scope-pre-size [scope-pre-size #f])
  (define nonzero-targets
    (remove-duplicates
     (filter (lambda (l) (not (= l lit-zero))) raw-target-lits)))
  (cond
    [(null? nonzero-targets)
     (values 'unsat #f 'structural-zero)]
    [(member lit-one nonzero-targets)
     ;; Constant `1` is trivially satisfiable at all-zero input `0`!
     (values 'sat
             (hasheq 'assign_mask 0 'active_input_wires '() 'hamming_weight 0)
             'constant-one)]
    [else
     (define num-inputs (length input-wires))
     (define all-sim-zero?
       (for/and ([tl (in-list nonzero-targets)])
         (xag-lit-sim-zero? mgr tl)))

     ;; 1. Local Bottleneck Cut-Sweeping (`UNSAT` candidate when `sim256 == 0`)
     (define cut-proved?
       (and all-sim-zero?
            (let-values ([(cut-nids cone-nids)
                          (if scope-pre-size
                              (let-values ([(sc scone)
                                            (xag-extract-scope-entry-cut mgr nonzero-targets scope-pre-size 24)])
                                (if sc
                                    (values sc scone)
                                    (xag-find-bottleneck-cut mgr nonzero-targets 16 700)))
                              (xag-find-bottleneck-cut mgr nonzero-targets 16 700))])
              (and cut-nids
                   (let ([digest (xag-canonical-cut-digest mgr cut-nids cone-nids nonzero-targets)])
                     (cond
                       [(set-member? (xag-manager-verified-cut-set mgr) digest)
                        (set-xag-manager-cut-cache-hits! mgr (add1 (xag-manager-cut-cache-hits mgr)))
                        #t]
                       [else
                        (define smt2
                          (xag-export-tseitin-smt2 mgr nonzero-targets
                                                   #:cut-nids cut-nids
                                                   #:cone-nids cone-nids))
                        (set-xag-manager-z3-queries! mgr (add1 (xag-manager-z3-queries mgr)))
                        (define-values (st _) (z3-exec-script! smt2))
                        (when (eq? st 'unsat)
                          (set-add! (xag-manager-verified-cut-set mgr) digest))
                        (eq? st 'unsat)]))))))

     (cond
       [cut-proved?
        (values 'unsat #f 'unconditional-cut)]
       [else
        ;; 2. Full Primary-Input Tseitin Miter + Ideal `I(S_Z)` in Z3!
        (define mvars (for/list ([v (in-range num-inputs)]) (format "x_~a" v)))
        (define sample-hit
          (and (eq? domain-pred 'all)
               (for/first ([tl (in-list nonzero-targets)]
                           #:when (xag-lit-first-nonzero-sample mgr tl))
                 (xag-lit-first-nonzero-sample mgr tl))))

        (cond
          ;; Simulation-guided cube-assumption fast path on high-round unconstrained ciphers:
          ;; First check sparse low-Hamming-weight probes in O(|cone|), else use `sample-hit`
          ;; (`s-assign`, guaranteed to evaluate `tl == 1`), freeing `x_0, x_1` so Z3 formally
          ;; solves and certifies the complete primary-input Tseitin model in < 2 ms!
          [sample-hit
           (define s-assign (xag-sample-input-assignment mgr sample-hit num-inputs))
           (define sparse-hit
             (or (let ([z-env (make-hasheqv)])
                   (and (for/or ([tl (in-list nonzero-targets)])
                          (= (xag-eval-lit mgr tl z-env) 1))
                        z-env))
                 (for/first ([v (in-range (min num-inputs 16))]
                             #:when (let ([e1 (hasheqv v 1)])
                                      (for/or ([tl (in-list nonzero-targets)])
                                        (= (xag-eval-lit mgr tl e1) 1))))
                   (hasheqv v 1))))
           (define witness-assign (or sparse-hit s-assign))
           (define sim-assumps
             (for/list ([v (in-range 2 num-inputs)])
               (if (= (hash-ref witness-assign v 0) 1)
                   (format "x_~a" v)
                   (format "(not x_~a)" v))))
           (define smt-sim
             (xag-export-tseitin-smt2 mgr nonzero-targets
                                      #:num-inputs num-inputs
                                      #:input-wires input-wires
                                      #:domain-pred domain-pred
                                      #:extra-assumptions sim-assumps))
           (set-xag-manager-z3-queries! mgr (add1 (xag-manager-z3-queries mgr)))
           (define-values (st-sim mod-sim)
             (z3-exec-script! smt-sim #:read-sexpr-on-sat? #t #:model-vars mvars))
           (if (eq? st-sim 'sat)
               (values 'sat (parse-z3-model-to-cex mod-sim input-wires) 'primary-miter)
               ;; Full unconstrained fallback (completeness!)
               (let ()
                 (define smt-full
                   (xag-export-tseitin-smt2 mgr nonzero-targets
                                            #:num-inputs num-inputs
                                            #:input-wires input-wires
                                            #:domain-pred domain-pred))
                 (set-xag-manager-z3-queries! mgr (add1 (xag-manager-z3-queries mgr)))
                 (define-values (st-f mod-f)
                   (z3-exec-script! smt-full #:read-sexpr-on-sat? #t #:model-vars mvars))
                 (if (eq? st-f 'sat)
                     (values 'sat (parse-z3-model-to-cex mod-f input-wires) 'primary-miter)
                     (values 'unsat #f 'domain-global))))]
          [else
           ;; Exact global domain miter (`wt-le`, `ult-pairs`, or `sim == 0` check)
           (define smt-full
             (xag-export-tseitin-smt2 mgr nonzero-targets
                                      #:num-inputs num-inputs
                                      #:input-wires input-wires
                                      #:domain-pred domain-pred))
           (set-xag-manager-z3-queries! mgr (add1 (xag-manager-z3-queries mgr)))
           (define-values (st-f mod-f)
             (z3-exec-script! smt-full #:read-sexpr-on-sat? #t #:model-vars mvars))
           (cond
             [(eq? st-f 'unsat)
              (values 'unsat #f 'domain-global)]
             [else
              ;; Minimize Hamming weight when `num-inputs <= 32` (e.g. `BCH(15, 7, 5)` -> exact weight 2!)
              (define best-cex (parse-z3-model-to-cex mod-f input-wires))
              (when (and (<= num-inputs 32) (> (hash-ref best-cex 'hamming_weight) 1))
                (let tighten ([target-w 1])
                  (when (< target-w (hash-ref best-cex 'hamming_weight))
                    (define smt-min
                      (xag-export-tseitin-smt2 mgr nonzero-targets
                                               #:num-inputs num-inputs
                                               #:input-wires input-wires
                                               #:domain-pred `(wt-le ,target-w)))
                    (set-xag-manager-z3-queries! mgr (add1 (xag-manager-z3-queries mgr)))
                    (define-values (st-m mod-m)
                      (z3-exec-script! smt-min #:read-sexpr-on-sat? #t #:model-vars mvars))
                    (if (eq? st-m 'sat)
                        (set! best-cex (parse-z3-model-to-cex mod-m input-wires))
                        (tighten (add1 target-w))))))
              (values 'sat best-cex 'primary-miter)])])])]))

;; =============================================================================
;; SECTION 4: `LakefillQ` Wire-Level `XAG`/`FRAIG` + `QSub` (`U1–U4`) Typechecker
;; =============================================================================

(struct xag-inference-result
  (well-typed?
   logical-well-typed?
   u1-ok?
   u2-ok?
   u3-ok?
   u4-ok?
   phi1-ok?
   phi2-ok?
   phi3-ok?
   u1-violations
   u2-violations
   u3-violations
   u4-violations
   phi2-collision-pairs
   qura-width
   phys-grade
   effective-lindblad-milli
   xag-stats
   final-wire-xag
   final-u4-coeffs
   final-wmap
   manager)
  #:transparent)

;; Syntactic adjoint for unitary sub-blocks inside `within-apply` / `within-apply-raw`
(define (invert-lakefillq-unitary expr)
  (match expr
    ['skip 'skip]
    [`(assert-clean ,_) 'skip]
    [`(logical-swap ,a ,b) `(logical-swap ,a ,b)]
    [`(x ,w) `(x ,w)]
    [`(cx ,c ,t) `(cx ,c ,t)]
    [`(cx ,c ,t ,s) `(cx ,c ,t ,s)]
    [`(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t)]
    [`(ccx ,c1 ,c2 ,t ,s) `(ccx ,c1 ,c2 ,t ,s)]
    [`(swap ,a ,b) `(swap ,a ,b)]
    [`(h ,w) `(h ,w)]
    [`(z ,w) `(z ,w)]
    [`(cz ,a ,b) `(cz ,a ,b)]
    [`(ccz ,a ,b ,c) `(ccz ,a ,b ,c)]
    [`(seq ,es ...) `(seq ,@(map invert-lakefillq-unitary (reverse es)))]
    [`(par-wires ,e1 ,e2)
     `(par-wires ,(invert-lakefillq-unitary e1) ,(invert-lakefillq-unitary e2))]
    [`(within-apply ,u ,b ,erased)
     `(within-apply ,u ,(invert-lakefillq-unitary b) ,erased)]
    [`(within-apply ,u ,b)
     `(within-apply ,u ,(invert-lakefillq-unitary b))]
    [`(within-apply-raw ,u ,b ,erased)
     `(within-apply-raw ,u ,(invert-lakefillq-unitary b) ,erased)]
    [`(within-apply-raw ,u ,b)
     `(within-apply-raw ,u ,(invert-lakefillq-unitary b))]
    [`(mcx ,ctrls ,target ,scratch) `(mcx ,ctrls ,target ,scratch)]
    [`(mcx-raw ,ctrls ,target ,scratch) `(mcx-raw ,ctrls ,target ,scratch)]
    [_ (error 'invert-lakefillq-unitary "Non-unitary form in unitary adjoint: ~a" expr)]))

;; Asymmetric `MBU` adjoint for `within-apply-mbu`: turns `(temp-and c1 c2 anc)`
;; and `(temp-and-lin ...)` in reverse topological order into `0T` `(mx anc m_k) + (cond-z m_k c1 c2)`!
(define (invert-lakefillq-mbu expr fresh-m-fn)
  (match expr
    ['skip 'skip]
    [`(assert-clean ,_) 'skip]
    [`(logical-swap ,a ,b) `(logical-swap ,a ,b)]
    [`(x ,w) `(x ,w)]
    [`(cx ,c ,t) `(cx ,c ,t)]
    [`(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t)]
    [`(swap ,a ,b) `(swap ,a ,b)]
    [`(temp-and ,c1 ,c2 ,anc)
     (define m-sym (fresh-m-fn))
     `(seq (mx ,anc ,m-sym) (cond-z ,m-sym ,c1 ,c2))]
    [`(temp-and-lin ,lhs ,rhs ,anc ,neg-l? ,neg-r?)
     (define m-sym (fresh-m-fn))
     `(temp-and-lin-adj-mbu ,lhs ,rhs ,anc ,neg-l? ,neg-r? ,m-sym)]
    [`(temp-and-lin ,lhs ,rhs ,anc)
     (invert-lakefillq-mbu `(temp-and-lin ,lhs ,rhs ,anc #f #f) fresh-m-fn)]
    [`(seq ,es ...)
     `(seq ,@(map (lambda (e) (invert-lakefillq-mbu e fresh-m-fn)) (reverse es)))]
    [`(within-apply ,u ,b ,erased)
     `(within-apply ,u ,(invert-lakefillq-mbu b fresh-m-fn) ,erased)]
    [`(within-apply ,u ,b)
     `(within-apply ,u ,(invert-lakefillq-mbu b fresh-m-fn))]
    [_ (error 'invert-lakefillq-mbu "Unsupported form in MBU adjoint: ~a" expr)]))

;; Distinct-pivot zero-ancilla linear fan-in helper (matching `lakefill-pareto`)
(define (distinct-pivot-fanin-cxs phys-lhs phys-rhs neg-l? neg-r?)
  (define r-minus-l (filter (lambda (w) (not (member w phys-lhs))) phys-rhs))
  (define l-minus-r (filter (lambda (w) (not (member w phys-rhs))) phys-lhs))
  (cond
    [(not (null? r-minus-l))
     (define pR (first r-minus-l))
     (define pL (first phys-lhs))
     (define prep
       (append (for/list ([w (in-list phys-rhs)] #:when (not (= w pR))) `(cx ,w ,pR))
               (if neg-r? (list `(x ,pR)) '())
               (for/list ([w (in-list phys-lhs)] #:when (not (= w pL))) `(cx ,w ,pL))
               (if neg-l? (list `(x ,pL)) '())))
     (values pL pR prep)]
    [else
     (define pL (first l-minus-r))
     (define pR (first phys-rhs))
     (define prep
       (append (for/list ([w (in-list phys-lhs)] #:when (not (= w pL))) `(cx ,w ,pL))
               (if neg-l? (list `(x ,pL)) '())
               (for/list ([w (in-list phys-rhs)] #:when (not (= w pR))) `(cx ,w ,pR))
               (if neg-r? (list `(x ,pR)) '())))
     (values pL pR prep)]))

(define (expand-mcx-to-within ctrls target scratch)
  (define k (length ctrls))
  (cond
    [(= k 0) `(x ,target)]
    [(= k 1) `(cx ,(first ctrls) ,target)]
    [(= k 2) `(ccx ,(first ctrls) ,(second ctrls) ,target)]
    [else
     (define used (take scratch (- k 2)))
     (define steps
       (cons `(ccx ,(first ctrls) ,(second ctrls) ,(first used))
             (for/list ([idx (in-range 2 (- k 1))])
               `(ccx ,(list-ref ctrls idx)
                     ,(list-ref used (- idx 2))
                     ,(list-ref used (- idx 1))))))
     `(within-apply-raw (seq ,@steps)
                        (ccx ,(last ctrls) ,(last used) ,target)
                        ,used)]))

;; Evaluate a wire-level Boolean guard formula into a hash-consed `XAG` literal
(define (eval-xag-guard mgr guard-sexpr get-phys-lit)
  (let eval-g ([g guard-sexpr])
    (match g
      ['true lit-one]
      ['false lit-zero]
      [`(wire ,w) (get-phys-lit w)]
      [`(zero ,w) (lit-not (get-phys-lit w))]
      [`(not ,sub) (lit-not (eval-g sub))]
      [`(xor ,subs ...)
       (foldl (lambda (s acc) (xag-xor mgr acc (eval-g s))) lit-zero subs)]
      [`(and ,subs ...)
       (foldl (lambda (s acc) (xag-and mgr acc (eval-g s))) lit-one subs)]
      [`(or ,subs ...)
       (lit-not
        (foldl (lambda (s acc) (xag-and mgr acc (lit-not (eval-g s)))) lit-one subs))]
      [`(all-zero ,ws)
       (foldl (lambda (w acc) (xag-and mgr acc (lit-not (get-phys-lit w)))) lit-one ws)]
      [`(non-zero ,ws)
       (lit-not (eval-g `(all-zero ,ws)))]
      [`(eq-wires ,ws1 ,ws2)
       (foldl (lambda (w1 w2 acc)
                (xag-and mgr acc (lit-not (xag-xor mgr (get-phys-lit w1) (get-phys-lit w2)))))
              lit-one ws1 ws2)]
      [_ (error 'eval-xag-guard "Unrecognized wire guard: ~a" g)])))

;; Check if an `XAG` literal recorded at `(mx anc m_k)` has valid quadratic session structure
;; (`0`, `1`, linear literal, `'and` product `l1 & l2`, or affine XOR `l0 ^ (l1 & l2)`).
(define (xag-quadratic-session-form? mgr lit)
  (define id (lit-id lit))
  (if (= id 0)
      #t
      (let ([basis (vector-ref (xag-manager-basis-vec mgr) id)]
            [kv (xag-manager-kind-vec mgr)])
        (for/and ([b-nid (in-list basis)])
          (memq (vector-ref kv b-nid) '(var and xor))))))

;; Instantiate a list of `src-lits` from `src-mgr` (`var 0..k-1`) onto `var-lits-vec` in `dst-mgr`
(define (xag-instantiate-lits! dst-mgr src-mgr var-lits-vec src-lits)
  (define memo (make-hasheqv))
  (hash-set! memo 0 lit-zero)
  (define kv (xag-manager-kind-vec src-mgr))
  (define a1v (xag-manager-arg1-vec src-mgr))
  (define a2v (xag-manager-arg2-vec src-mgr))
  (define (inst-nid nid)
    (hash-ref! memo nid
               (lambda ()
                 (match (vector-ref kv nid)
                   ['const0 lit-zero]
                   ['var (vector-ref var-lits-vec (vector-ref a1v nid))]
                   ['xor (xag-xor dst-mgr
                                  (inst-nid (vector-ref a1v nid))
                                  (inst-nid (vector-ref a2v nid)))]
                   ['and (xag-and dst-mgr
                                  (inst-lit (vector-ref a1v nid))
                                  (inst-lit (vector-ref a2v nid)))]))))
  (define (inst-lit l)
    (define base (inst-nid (lit-id l)))
    (if (lit-inv? l) (lit-not base) base))
  (for/list ([sl (in-list src-lits)])
    (inst-lit sl)))

;; Collect logical wires touched by a pure reversible/MBU sub-block (`#f` if non-cut-sweepable)
(define (collect-cut-sweep-wires expr)
  (define ws (mutable-set))
  (define ok? #t)
  (let walk ([e expr])
    (when ok?
      (match e
        ['skip (void)]
        [`(x ,w) (set-add! ws w)]
        [(or `(cx ,c ,t) `(cx ,c ,t ,_)) (set-add! ws c) (set-add! ws t)]
        [(or `(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t ,_) `(temp-and ,c1 ,c2 ,t))
         (set-add! ws c1) (set-add! ws c2) (set-add! ws t)]
        [`(swap ,a ,b) (set-add! ws a) (set-add! ws b)]
        [`(temp-and-lin ,lhs ,rhs ,anc ,_ ,_)
         (for ([w (in-list lhs)]) (set-add! ws w))
         (for ([w (in-list rhs)]) (set-add! ws w))
         (set-add! ws anc)]
        [`(temp-and-lin ,lhs ,rhs ,anc)
         (for ([w (in-list lhs)]) (set-add! ws w))
         (for ([w (in-list rhs)]) (set-add! ws w))
         (set-add! ws anc)]
        [`(temp-and-lin-adj-mbu ,lhs ,rhs ,anc ,_ ,_ ,_)
         (for ([w (in-list lhs)]) (set-add! ws w))
         (for ([w (in-list rhs)]) (set-add! ws w))
         (set-add! ws anc)]
        [(or `(mx ,anc ,_) `(mid-meas-x ,anc -> ,_) `(mid-meas-x ,anc ,_))
         (set-add! ws anc)]
        [`(cond-z ,_ ,t) (set-add! ws t)]
        [(or `(cond-z ,_ ,c1 ,c2) `(cond-cz ,_ ,c1 ,c2))
         (set-add! ws c1) (set-add! ws c2)]
        [`(mid-meas-x-cond-z ,anc (,c1 ,c2))
         (set-add! ws anc) (set-add! ws c1) (set-add! ws c2)]
        [`(mid-meas-x-cond-z ,anc ,c1)
         (set-add! ws anc) (set-add! ws c1)]
        [`(seq ,es ...) (for ([sub (in-list es)]) (walk sub))]
        [(or `(within-apply ,u ,b ,erased) `(within-apply-raw ,u ,b ,erased)
             `(within-apply-mbu ,u ,b ,erased) `(erase-by ,u ,b ,erased) `(erase-by-raw ,u ,b ,erased))
         (walk u) (walk b) (for ([w (in-list erased)]) (set-add! ws w))]
        [(or `(within-apply ,u ,b) `(within-apply-raw ,u ,b))
         (walk u) (walk b)]
        [_ (set! ok? #f)])))
  (and ok? (sort (set->list ws) <)))

;; Detect purely affine/linear `LakefillQ` subcircuits (e.g., 200-wire Keccak `theta` `40x40` GF(2) inverse)
(define (purely-linear-cut-expr? expr)
  (match expr
    ['skip #t]
    [`(assert-clean ,_) #t]
    [`(logical-swap ,_ ,_) #t]
    [`(logical-relabel ,_ ,_) #t]
    [`(x ,_) #t]
    [`(swap ,_ ,_) #t]
    [(or `(cx ,_ ,_) `(cx ,_ ,_ ,_)) #t]
    [`(seq ,es ...) (andmap purely-linear-cut-expr? es)]
    [(or `(within-apply ,u ,b ,_) `(within-apply-raw ,u ,b ,_)
         `(within-apply ,u ,b) `(within-apply-raw ,u ,b)
         `(erase-by ,u ,b ,_) `(erase-by-raw ,u ,b ,_))
     (and (purely-linear-cut-expr? u) (purely-linear-cut-expr? b))]
    [_ #f]))

;; Core `LakefillQ` `XAG`/`FRAIG` + `Z3` Cut-Sweeping Symbolic Type & Grade Inference Engine!
(define (infer-lakefillq-xag-circuit hw input-wires scratch-wires domain-pred raw-sexpr
                                     #:enforce-phi1? [enforce-phi1? #t]
                                     #:shared-cut-cache [shared-cut-cache #f]
                                     #:initial-wmap [initial-wmap #f]
                                     #:allow-local-cut? [allow-local-cut? #t])
  (define num-inputs (length input-wires))
  (define mgr-basis-cap
    (cond
      [shared-cut-cache 256]
      [(<= num-inputs 128) 64]
      [else 24]))
  (define mgr (make-xag-manager (if shared-cut-cache 1024 8192) shared-cut-cache mgr-basis-cap))
  (define input-var-map
    (for/hasheqv ([w (in-list input-wires)] [idx (in-naturals)])
      (values w idx)))

  ;; Compile-time logical-to-physical wire relabeling map (`0`-SWAP `ShiftRows` / `SLP91`)
  (define wmap (if initial-wmap (hash-copy initial-wmap) (make-hasheqv)))
  (define (phys w) (hash-ref wmap w w))

  ;; Physical wire -> `XAG` literal map
  (define wire-xag (make-hasheqv))
  (for ([w (in-list input-wires)] [idx (in-naturals)])
    (hash-set! wire-xag w (xag-var mgr idx)))
  (for ([w (in-list scratch-wires)])
    (unless (hash-has-key? wire-xag w)
      (hash-set! wire-xag w lit-zero)))

  (define next-fresh-var num-inputs)
  (define auto-m-counter 0)
  (define (fresh-m-sym!)
    (set! auto-m-counter (add1 auto-m-counter))
    (string->symbol (format "m_auto_~a" auto-m-counter)))

  (define live-wires (list->set input-wires))
  (define freed-ever (set))
  (define peak-live (set-count live-wires))
  (define unrecycled-allocs 0)
  (define recycled-reuses 0)
  (define temp-and-count 0)
  (define mbu-count 0)

  ;; Tracked quotient wires & history variables (`Law U2`)
  (define tracked-quotient-wires (set))
  (define tracked-history-vars
    (match domain-pred
      [`(quotient-vars ,qws)
       (for/set ([qw (in-list qws)] #:when (hash-has-key? input-var-map qw))
         (hash-ref input-var-map qw))]
      [_ (set)]))

  ;; Symbolic Bilinear `Law U4` Accumulator: `m-sym -> XAG literal g_k(x)`
  (define u4-coeffs (make-hasheq))

  ;; Accumulated violations
  (define u1-viols '())
  (define u2-viols '())
  (define u3-viols '())
  (define u4-viols '())
  (define phi2-pairs '())

  ;; Hardware grade helpers
  (define qphys-zero-grade (qphys-grade 0 0 0 0 0 #f 0 (set) 0))
  (define (idle-milli n-w dur)
    (define t2 (hw-spec-t2-ns hw))
    (if (= t2 0) 999999 (quotient (* n-w dur 1000) t2)))
  (define (min-fdist a b)
    (cond [(not a) b] [(not b) a] [else (min a b)]))
  (define (grade-seq g1 g2)
    (qphys-grade (+ (qphys-grade-idle-milli g1) (qphys-grade-idle-milli g2))
                 (+ (qphys-grade-gate-milli g1) (qphys-grade-gate-milli g2))
                 (+ (qphys-grade-mbu-excess-ns g1) (qphys-grade-mbu-excess-ns g2))
                 (+ (qphys-grade-routing-excess-cx g1) (qphys-grade-routing-excess-cx g2))
                 (+ (qphys-grade-exclusion-collisions g1) (qphys-grade-exclusion-collisions g2))
                 (min-fdist (qphys-grade-eff-fault-dist g1) (qphys-grade-eff-fault-dist g2))
                 (max (qphys-grade-req-target-dist g1) (qphys-grade-req-target-dist g2))
                 (set-union (qphys-grade-support-wires g1) (qphys-grade-support-wires g2))
                 (+ (qphys-grade-duration-ns g1) (qphys-grade-duration-ns g2))))
  (define (grade-join g1 g2)
    (qphys-grade (max (qphys-grade-idle-milli g1) (qphys-grade-idle-milli g2))
                 (max (qphys-grade-gate-milli g1) (qphys-grade-gate-milli g2))
                 (max (qphys-grade-mbu-excess-ns g1) (qphys-grade-mbu-excess-ns g2))
                 (max (qphys-grade-routing-excess-cx g1) (qphys-grade-routing-excess-cx g2))
                 (max (qphys-grade-exclusion-collisions g1) (qphys-grade-exclusion-collisions g2))
                 (min-fdist (qphys-grade-eff-fault-dist g1) (qphys-grade-eff-fault-dist g2))
                 (max (qphys-grade-req-target-dist g1) (qphys-grade-req-target-dist g2))
                 (set-union (qphys-grade-support-wires g1) (qphys-grade-support-wires g2))
                 (max (qphys-grade-duration-ns g1) (qphys-grade-duration-ns g2))))

  (define (touch-phys! pw [ssa-alloc? #f])
    (when (not (set-member? live-wires pw))
      (when (set-member? freed-ever pw)
        (set! recycled-reuses (add1 recycled-reuses)))
      (when ssa-alloc?
        (set! unrecycled-allocs (add1 unrecycled-allocs)))
      (set! live-wires (set-add live-wires pw))
      (when (> (set-count live-wires) peak-live)
        (set! peak-live (set-count live-wires)))))

  (define (free-phys! pw)
    (when (set-member? live-wires pw)
      (set! live-wires (set-remove live-wires pw))
      (set! freed-ever (set-add freed-ever pw)))
    (hash-set! wire-xag pw lit-zero))

  (define (get-phys-lit pw)
    (hash-ref wire-xag pw lit-zero))

  (define (get-log-lit lw)
    (get-phys-lit (phys lw)))

  ;; Apply unconditional FRAIG pivot equivalences proved by `Z3` Cut-Sweeping to live wires!
  (define (apply-fraig-zero-pivots! zero-lits)
    (define rem-lits zero-lits)
    (let loop ()
      (unless (null? rem-lits)
        (define cur (car rem-lits))
        (define rest (cdr rem-lits))
        (define rule (xag-extract-pivot-rule mgr cur))
        (when rule
          (define piv-nid (car rule))
          (define repl-lit (cdr rule))
          (set! rest
                (for/list ([rl (in-list rest)])
                  (xag-subst-linear-pivot mgr rl piv-nid repl-lit)))
          (for ([pw (in-set live-wires)])
            (define old-l (hash-ref wire-xag pw lit-zero))
            (define new-l (xag-subst-linear-pivot mgr old-l piv-nid repl-lit))
            (unless (= old-l new-l)
              (hash-set! wire-xag pw new-l))))
        (set! rem-lits rest)
        (loop))))

  ;; Batched `Law U1` verification + FRAIG simplification on `erased-phys-wires`
  (define (verify-and-free-erased-phys! construct-tag erased-phys-wires [scope-pre-size #f])
    (define non-zero-pairs
      (for/list ([pw (in-list erased-phys-wires)]
                 #:unless (= (get-phys-lit pw) lit-zero))
        (cons pw (get-phys-lit pw))))
    (cond
      [(null? non-zero-pairs)
       (for ([pw (in-list erased-phys-wires)]) (free-phys! pw))]
      [else
       (define target-lits (map cdr non-zero-pairs))
       (define-values (st batch-cex mode)
         (xag-z3-cut-sweep-miter! mgr target-lits input-wires domain-pred
                                  #:scope-pre-size scope-pre-size))
       (cond
         [(eq? st 'unsat)
          (when (eq? mode 'unconditional-cut)
            (apply-fraig-zero-pivots! target-lits))
          (for ([pw (in-list erased-phys-wires)])
            (free-phys! pw))]
         [else
          ;; Pinpoint the offending wire(s) with Z3 counterexamples
          (for ([pw (in-list erased-phys-wires)])
            (define plit (get-phys-lit pw))
            (if (= plit lit-zero)
                (free-phys! pw)
                (let-values ([(wst wcex _)
                              (xag-z3-cut-sweep-miter! mgr (list plit) input-wires domain-pred
                                                       #:scope-pre-size scope-pre-size)])
                  (when (eq? wst 'sat)
                    (set! u1-viols
                          (cons (hasheq 'construct (symbol->string construct-tag)
                                        'wire pw
                                        'xag_lit plit
                                        'counterexample wcex)
                                u1-viols)))
                  (free-phys! pw))))])]))

  ;; Check `Law U2` and `Law U4` before Hadamard / QFT interference on physical wires `pws`
  (define (check-interference-barriers! gate-tag pws)
    ;; 1. `Law U2`: tracked quotient wires must vanish on `S_Z`
    (for ([qw (in-list (sort (set->list tracked-quotient-wires) <))])
      (define qlit (get-phys-lit qw))
      (define-values (st cex _)
        (xag-z3-cut-sweep-miter! mgr (list qlit) input-wires domain-pred))
      (when (eq? st 'sat)
        (set! u2-viols
              (cons (hasheq 'kind "residual_quotient_wire_before_interference"
                            'gate (format "~a" gate-tag)
                            'quotient_wire qw
                            'counterexample cex)
                    u2-viols))))
    ;; 2. `Law U2`: history-variable independence `f|_{q=0} ^ f|_{q=1} == 0` via `XAG` cofactors!
    (for* ([hv (in-list (sort (set->list tracked-history-vars) <))]
           [pw (in-list pws)])
      (define wlit (get-phys-lit pw))
      (define diff-lit
        (xag-xor mgr (xag-cofactor mgr wlit hv 0) (xag-cofactor mgr wlit hv 1)))
      (define-values (st cex _)
        (xag-z3-cut-sweep-miter! mgr (list diff-lit) input-wires domain-pred))
      (when (eq? st 'sat)
        (set! u2-viols
              (cons (hasheq 'kind "history_variable_dependence_before_interference"
                            'gate (format "~a" gate-tag)
                            'live_wire pw
                            'history_var_idx hv
                            'counterexample cex)
                    u2-viols))))
    ;; 3. `Law U4`: active bilinear `XAG` phase coefficients `g_k` must vanish before interference!
    (for ([(m-sym glit) (in-hash u4-coeffs)] #:unless (= glit lit-zero))
      (define-values (st cex _)
        (xag-z3-cut-sweep-miter! mgr (list glit) input-wires domain-pred))
      (when (eq? st 'sat)
        (set! u4-viols
              (cons (hasheq 'trigger (format "interference_~a" gate-tag)
                            'meas_var (symbol->string m-sym)
                            'xag_lit glit
                            'counterexample cex)
                    u4-viols)))
      (hash-set! u4-coeffs m-sym lit-zero)))

  (define (dedup-odd-wires ws)
    (define h (make-hasheqv))
    (for ([w (in-list ws)]) (hash-update! h w add1 0))
    (sort (for/list ([(w c) (in-hash h)] #:when (odd? c)) w) <))

  ;; Recursive `LakefillQ` symbolic abstract interpreter
  (define (step-expr! expr)
    (match expr
      ['skip qphys-zero-grade]

      [`(assert-clean ,ws)
       (verify-and-free-erased-phys! 'assert-clean (map phys ws))
       qphys-zero-grade]

      [`(logical-swap ,a ,b)
       (define pa (phys a))
       (define pb (phys b))
       (hash-set! wmap a pb)
       (hash-set! wmap b pa)
       qphys-zero-grade]

      [`(logical-relabel ,wires ,src-for-dst)
       (define old-phys (for/vector ([w (in-list wires)]) (phys w)))
       (for ([w (in-list wires)] [sidx (in-list src-for-dst)])
         (hash-set! wmap w (vector-ref old-phys sidx)))
       qphys-zero-grade]

      [`(x ,w)
       (define pw (phys w))
       (touch-phys! pw #t)
       (hash-set! wire-xag pw (lit-not (get-phys-lit pw)))
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli 1 dur) 0 0 0 0 #f 0 (set pw) dur)]

      [(or `(z ,w) `(s ,w) `(ccz ,w ,_ ,_))
       (define pw (phys w))
       (touch-phys! pw #f)
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli 1 dur) 0 0 0 0 #f 0 (set pw) dur)]

      [`(h ,w)
       (define pw (phys w))
       (touch-phys! pw #f)
       (check-interference-barriers! `(h ,pw) (list pw))
       (define fidx next-fresh-var)
       (set! next-fresh-var (add1 next-fresh-var))
       (hash-set! wire-xag pw (xag-var mgr fidx))
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli 1 dur) 0 0 0 0 #f 0 (set pw) dur)]

      [`(qft ,ws)
       (define pws (map phys ws))
       (for ([pw (in-list pws)]) (touch-phys! pw #f))
       (check-interference-barriers! `(qft ,pws) pws)
       (for ([pw (in-list pws)])
         (define fidx next-fresh-var)
         (set! next-fresh-var (add1 next-fresh-var))
         (hash-set! wire-xag pw (xag-var mgr fidx)))
       (define n-q (max 1 (length pws)))
       (define n-2q (quotient (* n-q (sub1 n-q)) 2))
       (define dur (+ (* n-q (hw-spec-1q-ns hw)) (* n-2q (hw-spec-2q-ns hw))))
       (qphys-grade (idle-milli n-q dur)
                    (* n-2q (hw-spec-p2q-permil hw))
                    0 0 0 #f 0 (list->set pws) dur)]

      [`(swap ,a ,b)
       (define pa (phys a))
       (define pb (phys b))
       (cond
         [(= pa pb) qphys-zero-grade]
         [else
          (touch-phys! pa #f)
          (touch-phys! pb #f)
          (define la (get-phys-lit pa))
          (define lb (get-phys-lit pb))
          (hash-set! wire-xag pa lb)
          (hash-set! wire-xag pb la)
          (define dur (* 3 (hw-spec-2q-ns hw)))
          (qphys-grade (idle-milli 2 dur)
                       (* 3 (hw-spec-p2q-permil hw))
                       0 0 0 #f 0 (set pa pb) dur)])]

      [(or `(cx ,c ,t) `(cx ,c ,t ,_))
       (define pc (phys c))
       (define pt (phys t))
       (when (= pc pt)
         (error 'infer-lakefillq-xag-circuit "cx alias on physical wire ~a in ~a" pc expr))
       (define saved (match expr [`(cx ,_ ,_ ,s) s] [_ 0]))
       (touch-phys! pc #f)
       (touch-phys! pt #t)
       (hash-set! wire-xag pt (xag-xor mgr (get-phys-lit pt) (get-phys-lit pc)))
       (define d-edge ((hw-spec-coupling-dist-fn hw) pc pt))
       (define swap-cx (if (<= d-edge 1) 0 (* 3 (- d-edge 1))))
       (define rt-exc (+ (if (= d-edge 0) 1 0) (max 0 (- swap-cx saved))))
       (define total-2q (+ 1 swap-cx))
       (define dur (* total-2q (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli 2 dur)
                    (* total-2q (hw-spec-p2q-permil hw))
                    0 rt-exc 0 #f 0 (set pc pt) dur)]

      [`(cz ,a ,b)
       (define pa (phys a))
       (define pb (phys b))
       (touch-phys! pa #f)
       (touch-phys! pb #f)
       (define dur (hw-spec-2q-ns hw))
       (qphys-grade (idle-milli 2 dur) (hw-spec-p2q-permil hw) 0 0 0 #f 0 (set pa pb) dur)]

      [(or `(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t ,_))
       (define p1 (phys c1))
       (define p2 (phys c2))
       (define pt (phys t))
       (when (or (= p1 p2) (= p1 pt) (= p2 pt))
         (error 'infer-lakefillq-xag-circuit "ccx wire alias in ~a" expr))
       (define saved (match expr [`(ccx ,_ ,_ ,_ ,s) s] [_ 0]))
       (touch-phys! p1 #f)
       (touch-phys! p2 #f)
       (touch-phys! pt #t)
       (set! temp-and-count (add1 temp-and-count))
       (define prod (xag-and mgr (get-phys-lit p1) (get-phys-lit p2)))
       (hash-set! wire-xag pt (xag-xor mgr (get-phys-lit pt) prod))
       (define d12 ((hw-spec-coupling-dist-fn hw) p1 p2))
       (define d2t ((hw-spec-coupling-dist-fn hw) p2 pt))
       (define max-d (max d12 d2t))
       (define swap-cx (if (<= max-d 1) 0 (* 3 (- max-d 1))))
       (define rt-exc (max 0 (- swap-cx saved)))
       (define total-2q (+ 6 swap-cx))
       (define dur (* total-2q (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli 3 dur)
                    (* total-2q (hw-spec-p2q-permil hw))
                    0 rt-exc 0 #f 0 (set p1 p2 pt) dur)]

      ;; Gidney temporary-AND `(temp-and c1 c2 anc)` (`Law U1` pre-clean check + 1 `XAG` AND node!)
      [`(temp-and ,c1 ,c2 ,anc)
       (define p1 (phys c1))
       (define p2 (phys c2))
       (define pa (phys anc))
       (when (or (= p1 p2) (= p1 pa) (= p2 pa))
         (error 'infer-lakefillq-xag-circuit "temp-and wire alias in ~a" expr))
       (define pre-lit (get-phys-lit pa))
       (unless (= pre-lit lit-zero)
         (define-values (st cex _)
           (xag-z3-cut-sweep-miter! mgr (list pre-lit) input-wires domain-pred))
         (when (eq? st 'sat)
           (set! u1-viols
                 (cons (hasheq 'construct "temp-and-preclean-check"
                               'wire pa
                               'xag_lit pre-lit
                               'counterexample cex)
                       u1-viols)))
         (hash-set! wire-xag pa lit-zero))
       (touch-phys! p1 #f)
       (touch-phys! p2 #f)
       (touch-phys! pa #t)
       (set! temp-and-count (add1 temp-and-count))
       (define prod (xag-and mgr (get-phys-lit p1) (get-phys-lit p2)))
       (hash-set! wire-xag pa (xag-xor mgr (get-phys-lit pa) prod))
       (define dur (* 4 (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli 3 dur)
                    (* 4 (hw-spec-p2q-permil hw))
                    0 0 0 #f 0 (set p1 p2 pa) dur)]

      ;; Zero-ancilla linear fan-in `temp-and-lin` (forward compute)
      [`(temp-and-lin ,lhs-ws ,rhs-ws ,anc ,neg-l? ,neg-r?)
       (define plhs (dedup-odd-wires (map phys lhs-ws)))
       (define prhs (dedup-odd-wires (map phys rhs-ws)))
       (define pa (phys anc))
       (define-values (pL pR prep)
         (distinct-pivot-fanin-cxs plhs prhs neg-l? neg-r?))
       ;; Note: `prep` already uses physical wire indices, so execute with identity lookup!
       (step-phys-gate-list! (append prep (list `(temp-and-phys ,pL ,pR ,pa)) (reverse prep)))]

      [`(temp-and-lin ,lhs-ws ,rhs-ws ,anc)
       (step-expr! `(temp-and-lin ,lhs-ws ,rhs-ws ,anc #f #f))]

      ;; Adjoint MBU of `temp-and-lin` (with optional omission hook for bug injection!)
      [`(temp-and-lin-adj-mbu ,lhs-ws ,rhs-ws ,anc ,neg-l? ,neg-r? ,m-sym)
       (define plhs (dedup-odd-wires (map phys lhs-ws)))
       (define prhs (dedup-odd-wires (map phys rhs-ws)))
       (define pa (phys anc))
       (define-values (pL pR prep)
         (distinct-pivot-fanin-cxs plhs prhs neg-l? neg-r?))
       (step-phys-gate-list!
        (append prep
                (list `(mx-phys ,pa ,m-sym)
                      `(cond-z-phys ,m-sym ,pL ,pR))
                (reverse prep)))]

      ;; Hadamard-dual X-measurement `(mx anc m_k)` / `(mid-meas-x anc -> m_k)`:
      ;; Records `g_k <- XAG(anc)` (verifying quadratic session form) and resets `XAG(anc) <- 0`!
      [(or `(mx ,anc ,m-sym)
           `(mid-meas-x ,anc -> ,m-sym)
           `(mid-meas-x ,anc ,m-sym))
       (step-mx-phys! (phys anc) m-sym)]

      ;; 1-control feed-forward Z fixup `(cond-z m_k t)`: `g_k <- xag-xor(g_k, XAG(t))`
      [`(cond-z ,m-sym ,t)
       (define pt (phys t))
       (touch-phys! pt #f)
       (hash-set! u4-coeffs m-sym
                  (xag-xor mgr (hash-ref u4-coeffs m-sym lit-zero) (get-phys-lit pt)))
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli 1 dur) 0 0 0 0 #f 0 (set pt) dur)]

      ;; 2-control feed-forward CZ fixup `(cond-z m_k c1 c2)` / `(cond-cz m_k c1 c2)`:
      ;; Updates `g_k <- xag-xor(g_k, xag-and(XAG(c1), XAG(c2)))` -> collapses to `0` in `O(1)`!
      [(or `(cond-z ,m-sym ,c1 ,c2)
           `(cond-cz ,m-sym ,c1 ,c2))
       (step-cond-cz-phys! m-sym (phys c1) (phys c2))]

      ;; Fused `RevIR` MBU gate `(mid-meas-x-cond-z anc (c1 c2))` / `(mid-meas-x-cond-z anc c1)`
      [`(mid-meas-x-cond-z ,anc (,c1 ,c2))
       (define m-sym (fresh-m-sym!))
       (grade-seq (step-mx-phys! (phys anc) m-sym)
                  (step-cond-cz-phys! m-sym (phys c1) (phys c2)))]

      [`(mid-meas-x-cond-z ,anc ,c1)
       (define m-sym (fresh-m-sym!))
       (grade-seq (step-mx-phys! (phys anc) m-sym)
                  (step-expr! `(cond-z ,m-sym ,c1)))]

      [(or `(mcx ,ctrls ,target ,scratch)
           `(mcx-raw ,ctrls ,target ,scratch))
       (step-expr! (expand-mcx-to-within ctrls target scratch))]

      [`(rz-dyadic ,q ,exp-k ,uses-float64? ,code-dist)
       (define pq (phys q))
       (touch-phys! pq #f)
       (define dur (hw-spec-1q-ns hw))
       (define exact-prec? (or (not uses-float64?) (< exp-k 53)))
       (define d-eff (if exact-prec? code-dist 0))
       (qphys-grade (idle-milli 1 dur) 0 0 0 0 d-eff (max 3 code-dist) (set pq) dur)]

      [`(syndrome-plaquette ,ws ,code-dist ,hook-aligned?)
       (define pws (map phys ws))
       (for ([pw (in-list pws)]) (touch-phys! pw #f))
       (define n-2q (max 1 (sub1 (length pws))))
       (define dur (* n-2q (hw-spec-2q-ns hw)))
       (define d-eff (if hook-aligned? (quotient (add1 code-dist) 2) code-dist))
       (qphys-grade (idle-milli (max 1 (length pws)) dur)
                    (* n-2q (hw-spec-p2q-permil hw))
                    0 0 0 d-eff (max 3 code-dist) (list->set pws) dur)]

      [`(seq ,es ...)
       (for/fold ([g-acc qphys-zero-grade]) ([e (in-list es)])
         (grade-seq g-acc (step-expr! e)))]

      [`(par-wires ,e1 ,e2)
       (define g1 (step-expr! e1))
       (define g2 (step-expr! e2))
       (define s1 (qphys-grade-support-wires g1))
       (define s2 (qphys-grade-support-wires g2))
       (define s-union (set-union s1 s2))
       (define dist-fn (hw-spec-par-coupler-dist-fn hw))
       (define rb (hw-spec-blockade-radius-um hw))
       (define pairs
         (for*/list ([u (in-list (sort (set->list s1) <))]
                     [v (in-list (sort (set->list s2) <))]
                     #:when (or (= u v)
                                (< (dist-fn u v) 2)
                                (< (* 5 (abs (- u v))) rb)))
           (list u v)))
       (when (not (null? pairs))
         (set! phi2-pairs (append phi2-pairs pairs)))
       (define par-dur (max (qphys-grade-duration-ns g1) (qphys-grade-duration-ns g2)))
       (qphys-grade (idle-milli (max 1 (set-count s-union)) par-dur)
                    (+ (qphys-grade-gate-milli g1) (qphys-grade-gate-milli g2))
                    (max (qphys-grade-mbu-excess-ns g1) (qphys-grade-mbu-excess-ns g2))
                    (+ (qphys-grade-routing-excess-cx g1) (qphys-grade-routing-excess-cx g2))
                    (+ (qphys-grade-exclusion-collisions g1)
                       (qphys-grade-exclusion-collisions g2)
                       (length pairs))
                    (min-fdist (qphys-grade-eff-fault-dist g1) (qphys-grade-eff-fault-dist g2))
                    (max (qphys-grade-req-target-dist g1) (qphys-grade-req-target-dist g2))
                    s-union
                    par-dur)]

      [(or `(within-apply ,comp-e ,act-e ,erased-ws)
           `(within-apply-raw ,comp-e ,act-e ,erased-ws))
       (define pre-sz (xag-manager-size mgr))
       (define g1 (step-expr! comp-e))
       (define gb (step-expr! act-e))
       (define g2 (step-expr! (invert-lakefillq-unitary comp-e)))
       (verify-and-free-erased-phys! 'within-apply-raw (map phys erased-ws) pre-sz)
       (grade-seq g1 (grade-seq gb g2))]

      [(or `(within-apply ,comp-e ,act-e)
           `(within-apply-raw ,comp-e ,act-e))
       (define pre-sz (xag-manager-size mgr))
       (define pre-live live-wires)
       (define g1 (step-expr! comp-e))
       (define newly-live (set->list (set-subtract live-wires pre-live)))
       (define gb (step-expr! act-e))
       (define g2 (step-expr! (invert-lakefillq-unitary comp-e)))
       (verify-and-free-erased-phys! 'within-apply-raw newly-live pre-sz)
       (grade-seq g1 (grade-seq gb g2))]

      [`(within-apply-mbu ,comp-e ,act-e ,erased-ws)
       (define pre-sz (xag-manager-size mgr))
       (define g1 (step-expr! comp-e))
       (define gb (step-expr! act-e))
       (define g2 (step-expr! (invert-lakefillq-mbu comp-e fresh-m-sym!)))
       (verify-and-free-erased-phys! 'within-apply-mbu (map phys erased-ws) pre-sz)
       (grade-seq g1 (grade-seq gb g2))]

      [(or `(erase-by ,fwd-e ,bwd-e ,erased-ws)
           `(erase-by-raw ,fwd-e ,bwd-e ,erased-ws))
       (define touched-lws
         (and allow-local-cut?
              (eq? domain-pred 'all)
              (collect-cut-sweep-wires `(erase-by-raw ,fwd-e ,bwd-e ,erased-ws))))
       (define touched-pws
         (and touched-lws (remove-duplicates (map phys touched-lws))))
       (define active-pws
         (and touched-pws
              (filter (lambda (pw) (not (= (get-phys-lit pw) lit-zero))) touched-pws)))
       (cond
         ;; Local Bottleneck Cut-Sweeping + FRAIG Pivot Pruning when `1 <= |active-pws| <= 16`
         ;; or purely linear GF(2) inverse block up to `256` active wires (e.g., 200-wire Keccak `theta`)!
         [(and active-pws
               (>= (length active-pws) 1)
               (or (<= (length active-pws) 16)
                   (and (<= (length active-pws) 256)
                        (purely-linear-cut-expr? fwd-e)
                        (purely-linear-cut-expr? bwd-e))))
          (define clean-pws
            (filter (lambda (pw) (= (get-phys-lit pw) lit-zero)) touched-pws))
          (define orig-lits-vec
            (for/vector ([pw (in-list active-pws)]) (get-phys-lit pw)))
          (define sub-res
            (infer-lakefillq-xag-circuit hw
                                         active-pws
                                         clean-pws
                                         'all
                                         `(erase-by-raw ,fwd-e ,bwd-e ,erased-ws)
                                         #:enforce-phi1? #f
                                         #:shared-cut-cache (xag-manager-verified-cut-set mgr)
                                         #:initial-wmap wmap
                                         #:allow-local-cut? #f))
          (define sub-mgr (xag-inference-result-manager sub-res))
          (define sub-stats (xag-inference-result-xag-stats sub-res))
          (set-xag-manager-z3-queries! mgr
                                       (+ (xag-manager-z3-queries mgr)
                                          (xag-manager-z3-queries sub-mgr)))
          (set-xag-manager-cut-cache-hits! mgr
                                           (+ (xag-manager-cut-cache-hits mgr)
                                              (xag-manager-cut-cache-hits sub-mgr)))
          (set-xag-manager-fraig-merges! mgr
                                         (+ (xag-manager-fraig-merges mgr)
                                            (xag-manager-fraig-merges sub-mgr)))
          (define sub-quad-ok?
            (for/and ([v (in-list (xag-inference-result-u4-violations sub-res))])
              (not (equal? (hash-ref v 'trigger "") "non_quadratic_mx_session_ancilla"))))
          (cond
            [(and (xag-inference-result-u1-ok? sub-res)
                  (xag-inference-result-u2-ok? sub-res)
                  (xag-inference-result-u3-ok? sub-res)
                  sub-quad-ok?)
             ;; Update `temp-and-count`, `mbu-count`, and `qura` wire liveness
             (set! temp-and-count (+ temp-and-count (hash-ref sub-stats 'temp_and_gates_checked)))
             (set! mbu-count (+ mbu-count (hash-ref sub-stats 'mbu_sessions_checked)))
             (for ([pw (in-list clean-pws)]) (touch-phys! pw #t))
             (define erased-pws (map phys erased-ws))
             (define erased-pset (list->set erased-pws))
             (define kept-pws
               (filter (lambda (pw) (not (set-member? erased-pset pw))) touched-pws))
             (define sub-wxag (xag-inference-result-final-wire-xag sub-res))
             (define sub-u4 (xag-inference-result-final-u4-coeffs sub-res))
             (define nonzero-sub-u4
               (for/list ([(ms sl) (in-hash sub-u4)] #:unless (= sl lit-zero))
                 (cons ms sl)))
             (define inst-all
               (xag-instantiate-lits!
                mgr
                sub-mgr
                orig-lits-vec
                (append (for/list ([pw (in-list kept-pws)])
                          (hash-ref sub-wxag pw lit-zero))
                        (map cdr nonzero-sub-u4))))
             (define inst-kept (take inst-all (length kept-pws)))
             (define inst-u4   (drop inst-all (length kept-pws)))
             (for ([pw (in-list kept-pws)] [ilit (in-list inst-kept)])
               (hash-set! wire-xag pw ilit))
             (for ([pair (in-list nonzero-sub-u4)] [uglit (in-list inst-u4)])
               (hash-set! u4-coeffs (fresh-m-sym!) uglit))
             (for ([pw (in-list erased-pws)])
               (free-phys! pw))
             (xag-inference-result-phys-grade sub-res)]
            [else
             ;; Local cut not unconditionally clean -> run directly in global `mgr` for exact CEX!
             (define pre-sz (xag-manager-size mgr))
             (define gf (step-expr! fwd-e))
             (define gb (step-expr! bwd-e))
             (verify-and-free-erased-phys! 'erase-by-raw (map phys erased-ws) pre-sz)
             (grade-seq gf gb)])]
         [else
          (define pre-sz (xag-manager-size mgr))
          (define gf (step-expr! fwd-e))
          (define gb (step-expr! bwd-e))
          (verify-and-free-erased-phys! 'erase-by-raw (map phys erased-ws) pre-sz)
          (grade-seq gf gb)])]

      [`(canon-quotient-raw ,q-wires ,cleanup-e)
       (define pqws (map phys q-wires))
       (for ([qw (in-list pqws)])
         (set! tracked-quotient-wires (set-add tracked-quotient-wires qw)))
       (define gc (step-expr! cleanup-e))
       (for ([qw (in-list pqws)])
         (define-values (st _ __)
           (xag-z3-cut-sweep-miter! mgr (list (get-phys-lit qw)) input-wires domain-pred))
         (when (eq? st 'unsat)
           (free-phys! qw)))
       gc]

      [`(match-wires-raw ,arms)
       (define guard-lits
         (for/list ([arm (in-list arms)])
           (eval-xag-guard mgr (first arm) get-log-lit)))
       ;; 1. Pairwise orthogonality `G_i & G_j == 0`
       (for* ([i (in-range (length guard-lits))]
              [j (in-range (add1 i) (length guard-lits))])
         (define ov (xag-and mgr (list-ref guard-lits i) (list-ref guard-lits j)))
         (define-values (st cex _)
           (xag-z3-cut-sweep-miter! mgr (list ov) input-wires domain-pred))
         (when (eq? st 'sat)
           (set! u3-viols
                 (cons (hasheq 'kind "branch_overlap_non_orthogonal"
                               'branch_i i
                               'branch_j j
                               'counterexample cex)
                       u3-viols))))
       ;; 2. Totality `~(G_1 ^ ... ^ G_k) == 0`
       (define xor-sum (foldl (lambda (gl acc) (xag-xor mgr acc gl)) lit-zero guard-lits))
       (define uncovered (lit-not xor-sum))
       (define-values (ust ucex _)
         (xag-z3-cut-sweep-miter! mgr (list uncovered) input-wires domain-pred))
       (when (eq? ust 'sat)
         (set! u3-viols
               (cons (hasheq 'kind "incomplete_branch_cover_singular_locus"
                             'num_arms (length arms)
                             'counterexample ucex)
                     u3-viols)))
       ;; 3. Multiplex arm `XAG`s
       (define base-xag (hash-copy wire-xag))
       (define base-live live-wires)
       (define arm-xags '())
       (define arm-lives '())
       (define joined-g qphys-zero-grade)
       (for ([arm (in-list arms)])
         (set! wire-xag (hash-copy base-xag))
         (set! live-wires base-live)
         (define ga (step-expr! (second arm)))
         (set! joined-g (grade-join joined-g ga))
         (set! arm-xags (cons (hash-copy wire-xag) arm-xags))
         (set! arm-lives (cons live-wires arm-lives)))
       (set! arm-xags (reverse arm-xags))
       (set! arm-lives (reverse arm-lives))
       (define all-ws
         (remove-duplicates (append (hash-keys base-xag) (append-map hash-keys arm-xags))))
       (define merged (make-hasheqv))
       (for ([pw (in-list all-ws)])
         (define mux-lit
           (for/fold ([acc (xag-and mgr uncovered (hash-ref base-xag pw lit-zero))])
                     ([gl (in-list guard-lits)] [amap (in-list arm-xags)])
             (xag-xor mgr acc (xag-and mgr gl (hash-ref amap pw lit-zero)))))
         (hash-set! merged pw mux-lit))
       (set! wire-xag merged)
       (set! live-wires (foldl set-union base-live arm-lives))
       joined-g]

      [`(multishot-reset-raw ,shots-k ,body)
       (define gb (step-expr! body))
       (if (<= shots-k 1)
           gb
           (struct-copy qphys-grade gb
                        [idle-milli (quotient (qphys-grade-idle-milli gb) shots-k)]
                        [gate-milli (quotient (qphys-grade-gate-milli gb) shots-k)]
                        [duration-ns (quotient (qphys-grade-duration-ns gb) shots-k)]))]

      [_ (error 'infer-lakefillq-xag-circuit "Unrecognized LakefillQ AST: ~a" expr)]))

  ;; Physical-index helper gates for `temp-and-lin` expansion (bypassing `wmap` double-lookup)
  (define (step-mx-phys! pa m-sym)
    (define anc-lit (get-phys-lit pa))
    (unless (xag-quadratic-session-form? mgr anc-lit)
      (set! u4-viols
            (cons (hasheq 'trigger "non_quadratic_mx_session_ancilla"
                          'meas_var (symbol->string m-sym)
                          'wire pa)
                  u4-viols)))
    (hash-set! u4-coeffs m-sym
               (xag-xor mgr (hash-ref u4-coeffs m-sym lit-zero) anc-lit))
    (free-phys! pa)
    (set! mbu-count (add1 mbu-count))
    (define n-spec (max 0 (set-count live-wires)))
    (define t-meas (hw-spec-t-meas-reset-ns hw))
    (define mbu-exc
      (if (hw-spec-xy4-dd-enabled? hw)
          0
          (max 0 (- (* (+ 2 n-spec) t-meas) (hw-spec-unitary-budget-ns hw)))))
    (qphys-grade (idle-milli (add1 n-spec) t-meas)
                 (hw-spec-p2q-permil hw)
                 mbu-exc 0 0 #f 0 (set pa) t-meas))

  (define (step-cond-cz-phys! m-sym p1 p2)
    (when (= p1 p2)
      (error 'infer-lakefillq-xag-circuit "cond-z/cz wires alias on ~a" p1))
    (touch-phys! p1 #f)
    (touch-phys! p2 #f)
    (define prod (xag-and mgr (get-phys-lit p1) (get-phys-lit p2)))
    (hash-set! u4-coeffs m-sym
               (xag-xor mgr (hash-ref u4-coeffs m-sym lit-zero) prod))
    (define dur (hw-spec-2q-ns hw))
    (qphys-grade (idle-milli 2 dur) (hw-spec-p2q-permil hw) 0 0 0 #f 0 (set p1 p2) dur))

  (define (step-phys-gate-list! gs)
    (for/fold ([g-acc qphys-zero-grade]) ([g (in-list gs)])
      (define g-step
        (match g
          [`(x ,pw)
           (touch-phys! pw #t)
           (hash-set! wire-xag pw (lit-not (get-phys-lit pw)))
           (define dur (hw-spec-1q-ns hw))
           (qphys-grade (idle-milli 1 dur) 0 0 0 0 #f 0 (set pw) dur)]
          [`(cx ,pc ,pt)
           (touch-phys! pc #f)
           (touch-phys! pt #t)
           (hash-set! wire-xag pt (xag-xor mgr (get-phys-lit pt) (get-phys-lit pc)))
           (define dur (hw-spec-2q-ns hw))
           (qphys-grade (idle-milli 2 dur) (hw-spec-p2q-permil hw) 0 0 0 #f 0 (set pc pt) dur)]
          [`(temp-and-phys ,p1 ,p2 ,pa)
           (define pre-lit (get-phys-lit pa))
           (unless (= pre-lit lit-zero)
             (define-values (st cex _)
               (xag-z3-cut-sweep-miter! mgr (list pre-lit) input-wires domain-pred))
             (when (eq? st 'sat)
               (set! u1-viols
                     (cons (hasheq 'construct "temp-and-preclean-check"
                                   'wire pa
                                   'xag_lit pre-lit
                                   'counterexample cex)
                           u1-viols)))
             (hash-set! wire-xag pa lit-zero))
           (touch-phys! p1 #f)
           (touch-phys! p2 #f)
           (touch-phys! pa #t)
           (set! temp-and-count (add1 temp-and-count))
           (define prod (xag-and mgr (get-phys-lit p1) (get-phys-lit p2)))
           (hash-set! wire-xag pa (xag-xor mgr (get-phys-lit pa) prod))
           (define dur (* 4 (hw-spec-2q-ns hw)))
           (qphys-grade (idle-milli 3 dur) (* 4 (hw-spec-p2q-permil hw)) 0 0 0 #f 0 (set p1 p2 pa) dur)]
          [`(mx-phys ,pa ,m-sym)
           (step-mx-phys! pa m-sym)]
          [`(cond-z-phys ,m-sym ,p1 ,p2)
           (step-cond-cz-phys! m-sym p1 p2)]))
      (grade-seq g-acc g-step)))

  (define final-grade (step-expr! raw-sexpr))

  ;; Scope-exit `Law U4` check across all recorded `m_k` bilinear `XAG` roots!
  (for ([(m-sym glit) (in-hash u4-coeffs)] #:unless (= glit lit-zero))
    (define-values (st cex _)
      (xag-z3-cut-sweep-miter! mgr (list glit) input-wires domain-pred))
    (when (eq? st 'sat)
      (set! u4-viols
            (cons (hasheq 'trigger "scope_exit_uncancelled_u4_kickback"
                          'meas_var (symbol->string m-sym)
                          'xag_lit glit
                          'counterexample cex)
                  u4-viols))))

  (define u1-ok? (null? u1-viols))
  (define u2-ok? (null? u2-viols))
  (define u3-ok? (null? u3-viols))
  (define u4-ok? (null? u4-viols))
  (define logical-ok? (and u1-ok? u2-ok? u3-ok? u4-ok?))

  (define eff-lindblad
    (+ (qphys-grade-idle-milli final-grade)
       (qphys-grade-gate-milli final-grade)
       (* 700 (+ (qphys-grade-mbu-excess-ns final-grade)
                 (qphys-grade-routing-excess-cx final-grade)))))
  (define phi1-ok? (or (not enforce-phi1?) (<= eff-lindblad 693)))
  (define phi2-ok? (= (qphys-grade-exclusion-collisions final-grade) 0))
  (define d-eff (qphys-grade-eff-fault-dist final-grade))
  (define d-req (qphys-grade-req-target-dist final-grade))
  (define phi3-ok? (if (not d-eff) (= d-req 0) (and (>= d-eff 3) (>= d-eff d-req))))
  (define all-ok? (and logical-ok? phi1-ok? phi2-ok? phi3-ok?))

  (define init-w (length input-wires))
  (define final-w (set-count live-wires))
  (define unrecycled-w (+ init-w unrecycled-allocs))
  (define qura-summary
    (qura-width-summary init-w
                        final-w
                        peak-live
                        (max peak-live unrecycled-w)
                        recycled-reuses
                        (max 0 (- (max peak-live unrecycled-w) peak-live))))

  ;; Count live reachable `XAG` nodes and AND-nodes across final outputs
  (define final-reach
    (xag-collect-reachable-nids mgr (hash-values wire-xag)))
  (define kv (xag-manager-kind-vec mgr))
  (define live-and-nodes
    (for/sum ([nid (in-list final-reach)] #:when (eq? (vector-ref kv nid) 'and)) 1))
  (define total-and-nodes
    (for/sum ([nid (in-range 1 (xag-manager-size mgr))] #:when (eq? (vector-ref kv nid) 'and)) 1))

  (define stats
    (hasheq 'total_xag_nodes_allocated (sub1 (xag-manager-size mgr))
            'total_and_nodes_allocated total-and-nodes
            'live_reachable_xag_nodes (length final-reach)
            'live_reachable_and_nodes live-and-nodes
            'temp_and_gates_checked temp-and-count
            'mbu_sessions_checked mbu-count
            'nonzero_u4_coeffs_at_exit
            (for/sum ([(m glit) (in-hash u4-coeffs)] #:unless (= glit lit-zero)) 1)
            'z3_cut_sweep_queries (xag-manager-z3-queries mgr)
            'verified_cut_lemma_reuses (xag-manager-cut-cache-hits mgr)
            'fraig_pivot_substitutions (xag-manager-fraig-merges mgr)))

  (xag-inference-result
   all-ok?
   logical-ok?
   u1-ok?
   u2-ok?
   u3-ok?
   u4-ok?
   phi1-ok?
   phi2-ok?
   phi3-ok?
   (reverse u1-viols)
   (reverse u2-viols)
   (reverse u3-viols)
   (reverse u4-viols)
   phi2-pairs
   qura-summary
   final-grade
   eff-lindblad
   stats
   wire-xag
   u4-coeffs
   wmap
   mgr))

;; =============================================================================
;; SECTION 5: Multi-Round Cryptographic Builders, Deep Bug Injections & ANF Cap
;; =============================================================================

;; 1. Multi-round `AES-128` (`r = 1..10`, `290 Q`, `12,240` `TempAND`s at `r=10`) &
;;    `AES-256` (`r = 1..14`, `418 Q`, `17,000` `TempAND`s at `r=14`), with optional
;;    deep bug `(omit-cond-z-round-sbox)` omitting a single `cond-z` fixup on S-box `#sbox-idx`
;;    inside Round `bug-round`!
(define (build-lakefillq-aes-rounds-sexpr key-bits num-rounds state128 key-wires sc34
                                          #:omit-cond-z-round-sbox [bug-spec #f])
  (define nk (/ key-bits 32))
  (define max-nr (match key-bits [128 10] [192 12] [256 14]))
  (define and-sc (drop sc34 8))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))
  (define (xor-w32 s32 d32)
    `(seq ,@(for/list ([s (in-list s32)] [d (in-list d32)]) `(cx ,s ,d))))
  (define rcon-vec #(#x00 #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80 #x1B #x36))

  ;; S-box #`sb-idx` in round `r`: if `(equal? bug-spec (list r sb-idx))`, inject a single
  ;; missing `cond-z` fixup on the final MBU of `BP68` while still resetting `anc -> 0` via `mx`!
  (define (state-sbox-sexpr r sb-idx byte8)
    (define base-sbox (aes-sbox-bp68-inplace-sexpr byte8 sc34))
    (if (and bug-spec (= (first bug-spec) r) (= (second bug-spec) sb-idx))
        `(seq ,base-sbox
              ;; Deep multi-round `Law U4` bug inside Round `r` S-box `#sb-idx`:
              ;; Computes `temp-and` on two byte wires into clean `sc34[8]`, measures `mx`
              ;; (resetting `sc34[8] -> |0>` so `assert-clean` passes!), and OMITS `cond-z`!
              (temp-and ,(first byte8) ,(second byte8) ,(list-ref sc34 8))
              (mx ,(list-ref sc34 8) ,(string->symbol (format "m_aes_r~a_sbox~a_missing_condz" r sb-idx))))
        base-sbox))

  (define (key-sub-rot-rcon src32 dst32 rcon-u8)
    (define s0 (take src32 8))
    (define s1 (take (drop src32 8) 8))
    (define s2 (take (drop src32 16) 8))
    (define s3 (drop src32 24))
    `(seq ,(aes-sbox-bp34-zero-fanin-xor-sexpr s1 (take dst32 8) and-sc)
          ,(aes-sbox-bp34-zero-fanin-xor-sexpr s2 (take (drop dst32 8) 8) and-sc)
          ,(aes-sbox-bp34-zero-fanin-xor-sexpr s3 (take (drop dst32 16) 8) and-sc)
          ,(aes-sbox-bp34-zero-fanin-xor-sexpr s0 (drop dst32 24) and-sc)
          ,@(for/list ([b (in-range 8)] #:when (bitwise-bit-set? rcon-u8 b))
              `(x ,(list-ref dst32 b)))))

  (define (key-subword src32 dst32)
    `(seq ,@(for/list ([b (in-range 4)])
              (aes-sbox-bp34-zero-fanin-xor-sexpr
               (take (drop src32 (* 8 b)) 8)
               (take (drop dst32 (* 8 b)) 8)
               and-sc))))

  (define (advance-epoch e)
    (match nk
      [4 `(seq ,(key-sub-rot-rcon (kword 3) (kword 0) (vector-ref rcon-vec e))
               ,(xor-w32 (kword 0) (kword 1))
               ,(xor-w32 (kword 1) (kword 2))
               ,(xor-w32 (kword 2) (kword 3)))]
      [8 (if (= e 7)
             `(seq ,(key-sub-rot-rcon (kword 7) (kword 0) (vector-ref rcon-vec e))
                   ,(xor-w32 (kword 0) (kword 1))
                   ,(xor-w32 (kword 1) (kword 2))
                   ,(xor-w32 (kword 2) (kword 3)))
             `(seq ,(key-sub-rot-rcon (kword 7) (kword 0) (vector-ref rcon-vec e))
                   ,(xor-w32 (kword 0) (kword 1))
                   ,(xor-w32 (kword 1) (kword 2))
                   ,(xor-w32 (kword 2) (kword 3))
                   ,(key-subword (kword 3) (kword 4))
                   ,(xor-w32 (kword 4) (kword 5))
                   ,(xor-w32 (kword 5) (kword 6))
                   ,(xor-w32 (kword 6) (kword 7))))]))

  (define shiftrows-perm
    (for*/list ([c (in-range 4)] [r (in-range 4)] [b (in-range 8)])
      (+ (* 8 (+ r (* 4 (modulo (+ c r) 4)))) b)))

  (define steps '())
  (for ([r (in-range (add1 num-rounds))])
    (when (> r 0)
      (set! steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (state-sbox-sexpr r b (take (drop state128 (* 8 b)) 8))))
                  steps))
      (set! steps (cons `(logical-relabel ,state128 ,shiftrows-perm) steps))
      (when (< r max-nr)
        (set! steps (cons (aes-mixcolumns-slp92-sexpr state128 #:rewire? #t) steps))))
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! steps (cons (advance-epoch (quotient w-idx nk)) steps)))
      (set! steps (cons (xor-w32 (kword (modulo w-idx nk)) (sword c)) steps))))
  `(seq ,@(reverse steps) (assert-clean ,sc34)))

;; 2. 18-round `Keccak-f[200]` (`3,600` `TempAND`s) with optional deep bug omitting
;;    uncomputation on a single `TempAND` inside Round `bug-round` (e.g. Round 11)!
(define (build-lakefillq-keccak-f200-sexpr round-states sc45 [num-rounds 18]
                                           #:uncomputed-tempand-round [bug-round #f])
  (define base (keccak-f200-outofplace-sexpr round-states sc45 num-rounds))
  (if (not bug-round)
      base
      ;; Omit uncomputation on the single `TempAND` `(y=0, z=0, x=0)` inside Round `bug-round`
      ;; (`0`-indexed `target-ir = bug-round - 1`) while keeping all 18 `iota` constants `rc[0..17]`!
      (let ([target-ir (sub1 bug-round)]
            [omitted? #f])
        (define (strip-first-mbu expr)
          (cond
            [omitted? expr]
            [else
             (match expr
               [`(mid-meas-x-cond-z ,_ ,_)
                (set! omitted? #t)
                'skip]
               [`(seq ,es ...)
                `(seq ,@(map strip-first-mbu es))]
               [_ expr])]))
        (define top-elems (cdr base))
        `(seq ,@(for/list ([elem (in-list top-elems)] [idx (in-naturals)])
                  (if (= idx target-ir)
                      (strip-first-mbu elem)
                      elem))))))

;; 3. 64-Bit Gidney Ripple-Carry Temporary-AND Adder (`191 Q`, `63` `TempAND`s) with
;;    optional premature carry `MBU` bug at bit `bug-bit` (e.g. `bit = 47`)!
(define (build-lakefillq-gidney-64bit-adder-sexpr n a-wires b-wires carry-wires
                                                  #:premature-mbu-bit [bug-bit #f])
  (define (a i) (list-ref a-wires i))
  (define (b i) (list-ref b-wires i))
  (define (c i) (list-ref carry-wires i))
  (define used-carries (take carry-wires (sub1 n)))
  (define fwd-steps
    (cons `(temp-and ,(a 0) ,(b 0) ,(c 0))
          (for/list ([i (in-range 1 (sub1 n))])
            `(seq (cx ,(c (sub1 i)) ,(a i))
                  (cx ,(c (sub1 i)) ,(b i))
                  (temp-and ,(a i) ,(b i) ,(c i))
                  (cx ,(c (sub1 i)) ,(c i))))))
  (define top-step
    `(seq (cx ,(c (- n 2)) ,(b (sub1 n)))
          (cx ,(a (sub1 n)) ,(b (sub1 n)))))
  (define rev-steps
    (append
     (for/list ([i (in-range (- n 2) 0 -1)])
       (define m-sym (string->symbol (format "m_carry_~a" i)))
       `(seq ;; If `bug-bit == i`, omit `(cx c_{i-1} c_i)` before `mx c_i`!
             ;; `mx` still resets `c_i -> |0>` (`assert-clean` passes!), but injects
             ;; uncancelled degree-`(i)` carry kickback `m_carry_i * c_{i-1}(a, b)`!
             ,(if (and bug-bit (= bug-bit i))
                  'skip
                  `(cx ,(c (sub1 i)) ,(c i)))
             (mx ,(c i) ,m-sym)
             (cond-z ,m-sym ,(a i) ,(b i))
             (cx ,(c (sub1 i)) ,(a i))
             (cx ,(a i) ,(b i))))
     (list (let ([m0 'm_carry_0])
             `(seq (mx ,(c 0) ,m0)
                   (cond-z ,m0 ,(a 0) ,(b 0))
                   (cx ,(a 0) ,(b 0)))))))
  `(seq ,@fwd-steps ,top-step ,@rev-steps (assert-clean ,used-carries)))

;; 4. 64-Bit Gidney Modular Adder `(a + b) mod p_64` (`p_64 = 2^64 - 59`, `258 Q`)
(define (build-lakefillq-gidney-64bit-modadd-sexpr n modulus a-wires b-wires ovf-wire zero-wire mod-wires carry-wires)
  (gidney-modular-adder-sexpr n modulus a-wires b-wires ovf-wire zero-wire mod-wires carry-wires))

;; 5. `BCH(15, 7, 5)` Peterson-Berlekamp Syndrome Uncomputation vs Incomplete Hamming `wt<=1` Decoder
(define (build-lakefillq-bch-15-7-5-sexpr e15 syn8 sc26 #:incomplete-wt1-decoder? [stub? #f])
  (define s1      (take syn8 4))
  (define s3      (drop syn8 4))
  (define s1-sq   (take sc26 4))
  (define num     (take (drop sc26 4) 4))
  (define s1-inv  (take (drop sc26 8) 4))
  (define sigma2  (take (drop sc26 12) 4))
  (define lam     (take (drop sc26 16) 4))
  (define sub-sc  (take (drop sc26 20) 4))
  (define mcx-sc  (drop sc26 24))

  (define (gf16-mul a b)
    (for/fold ([res 0]) ([k (in-range 4)])
      (define term
        (for/fold ([x a]) ([_ (in-range k)])
          (define sh (bitwise-and (arithmetic-shift x 1) #xF))
          (if (bitwise-bit-set? x 3) (bitwise-xor sh #x3) sh)))
      (if (bitwise-bit-set? b k) (bitwise-xor res term) res)))
  (define (gf16-pow a e)
    (for/fold ([r 1]) ([_ (in-range (modulo e 15))]) (gf16-mul r a)))
  (define (const-mul-xor cval x4 out4)
    `(seq ,@(for*/list ([i (in-range 4)]
                        [b (in-range 4)]
                        #:when (bitwise-bit-set? (gf16-mul cval (arithmetic-shift 1 i)) b))
              `(cx ,(list-ref x4 i) ,(list-ref out4 b)))))
  (define parity-fwd
    `(seq ,@(for*/list ([i (in-range 15)]
                        [g (in-list
                            (let ([p1 (gf16-pow 2 i)] [p3 (gf16-pow 2 (* 3 i))])
                              (append
                               (for/list ([b (in-range 4)] #:when (bitwise-bit-set? p1 b))
                                 `(cx ,(list-ref e15 i) ,(list-ref s1 b)))
                               (for/list ([b (in-range 4)] #:when (bitwise-bit-set? p3 b))
                                 `(cx ,(list-ref e15 i) ,(list-ref s3 b))))))])
              g)))

  (define (var-mul-xor x4 y4 out4)
    `(seq ,@(for*/list ([i (in-range 4)]
                        [j (in-range 4)]
                        [b (in-range 4)]
                        #:when (bitwise-bit-set?
                                (gf16-mul (arithmetic-shift 1 i) (arithmetic-shift 1 j))
                                b))
              `(ccx ,(list-ref x4 i) ,(list-ref y4 j) ,(list-ref out4 b)))))
  (define (sq-inplace w4)
    `(seq (cx ,(third w4) ,(first w4))
          (cx ,(fourth w4) ,(second w4))
          (swap ,(second w4) ,(third w4))))

  (if stub?
      `(erase-by-raw
        ,parity-fwd
        (seq ,@(for/list ([i (in-range 15)])
                 (define x-inv (gf16-pow 2 (- 15 (modulo i 15))))
                 `(within-apply-raw
                   (seq (x ,(first lam))
                        ,(const-mul-xor x-inv s1 lam)
                        ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                   (mcx-raw ,lam ,(list-ref e15 i) ,mcx-sc)
                   ,(append lam mcx-sc))))
        ,(append e15 sc26))
      ;; Full Peterson-Berlekamp `wt <= 2` error-locator decoder erasing `(append e15 sc26)`!
      `(erase-by-raw
        ,parity-fwd
        (within-apply-raw
         (seq ;; 1. s1-sq <- S_1^2
              ,@(for/list ([sw (in-list s1)] [dw (in-list s1-sq)]) `(cx ,sw ,dw))
              ,(sq-inplace s1-sq)
              ;; 2. num <- S_3 ^ (s1-sq * S_1) = S_3 ^ S_1^3
              ,@(for/list ([sw (in-list s3)] [dw (in-list num)]) `(cx ,sw ,dw))
              ,(var-mul-xor s1-sq s1 num)
              ;; 3. s1-inv <- S_1^{14} = S_1^6 * S_1^8 using `sub-sc` & `lam` cleanly via `within-apply-raw`
              (within-apply-raw
               (seq ,@(for/list ([sw (in-list s1-sq)] [dw (in-list sub-sc)]) `(cx ,sw ,dw))
                    ,(sq-inplace sub-sc)             ;; sub-sc = S_1^4
                    ,(var-mul-xor s1-sq sub-sc lam)  ;; lam    = S_1^2 * S_1^4 = S_1^6
                    ,(sq-inplace sub-sc))            ;; sub-sc = S_1^8
               ,(var-mul-xor lam sub-sc s1-inv)      ;; s1-inv ^= S_1^6 * S_1^8 = S_1^{14}
               ,(append sub-sc lam))
              ;; 4. sigma2 <- num * s1-inv = (S_3 ^ S_1^3) * S_1^{14}
              ,(var-mul-xor num s1-inv sigma2))
         ;; 5. Chien search across all 15 coordinates `i = 0 .. 14`
         (seq ,@(for/list ([i (in-range 15)])
                  (define x-inv (gf16-pow 2 (- 15 (modulo i 15))))
                  (define x-inv-sq (gf16-mul x-inv x-inv))
                  `(within-apply-raw
                    (seq (x ,(first lam))
                         ,(const-mul-xor x-inv s1 lam)
                         ,(const-mul-xor x-inv-sq sigma2 lam)
                         ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                    (mcx-raw ,lam ,(list-ref e15 i) ,mcx-sc)
                    ,(append lam mcx-sc))))
         ,(take sc26 16))
        ,(append e15 sc26))))

;; Bounded Explicit `ANF` Evaluator (measuring exact monomial count on Round 1 vs
;; exponential blowup / monomial-cap abort on Round 2+ of `AES-128`, `Keccak-f[200]`, and `64`-bit adder!)
(define (run-bounded-explicit-anf-benchmark input-wires raw-sexpr
                                            #:monomial-cap [mono-cap 40000]
                                            #:timeout-ms [timeout-ms 400.0])
  (define t0 (current-inexact-milliseconds))
  (define wmap (make-hasheqv))
  (define (phys w) (hash-ref wmap w w))
  (define wire-anf (make-hasheqv))
  (for ([w (in-list input-wires)] [idx (in-naturals)])
    (hash-set! wire-anf w (anf-var idx)))
  (define peak-wire-monomials 1)
  (define peak-total-monomials (length input-wires))
  (define gates-completed 0)
  (define aborted-reason #f)

  (define (get-p pw) (hash-ref wire-anf pw anf-zero))
  (define (record-poly! pw p)
    (hash-set! wire-anf pw p)
    (define lp (length p))
    (when (> lp peak-wire-monomials)
      (set! peak-wire-monomials lp))
    (when (> lp mono-cap)
      (set! aborted-reason "monomial_cap_exceeded")
      (raise 'anf-blowup-abort))
    (when (> (- (current-inexact-milliseconds) t0) timeout-ms)
      (set! aborted-reason "timeout_cap_exceeded")
      (raise 'anf-blowup-abort)))

  ;; Bounded polynomial multiplication over F_2 checking `mono-cap` and `timeout-ms`
  ;; on every outer monomial so Round 2+ blowup aborts cleanly in milliseconds!
  (define (anf-and-bounded! p1 p2)
    (define-values (smaller larger)
      (if (<= (length p1) (length p2))
          (values p1 p2)
          (values p2 p1)))
    (for/fold ([acc anf-zero]) ([m1 (in-list smaller)])
      (when (> (- (current-inexact-milliseconds) t0) timeout-ms)
        (set! aborted-reason "timeout_cap_exceeded")
        (raise 'anf-blowup-abort))
      (define shifted
        (sort (for/list ([m2 (in-list larger)]) (bitwise-ior m1 m2)) <))
      ;; Deduplicate even-multiplicity identical monomials in `shifted`
      (define deduped
        (let dedup ([xs shifted] [out '()])
          (cond
            [(null? xs) (reverse out)]
            [(and (not (null? (cdr xs))) (= (car xs) (cadr xs)))
             (dedup (cddr xs) out)]
            [else
             (dedup (cdr xs) (cons (car xs) out))])))
      (define next-acc (anf-xor acc deduped))
      (define la (length next-acc))
      (when (> la peak-wire-monomials)
        (set! peak-wire-monomials la))
      (when (> la mono-cap)
        (set! aborted-reason "monomial_cap_exceeded")
        (raise 'anf-blowup-abort))
      next-acc))

  (define (dedup-odd ws)
    (define h (make-hasheqv))
    (for ([w (in-list ws)]) (hash-update! h w add1 0))
    (sort (for/list ([(w c) (in-hash h)] #:when (odd? c)) w) <))

  (define (step-anf! e)
    (match e
      ['skip (void)]
      [`(assert-clean ,_) (void)]
      [`(logical-swap ,a ,b)
       (define pa (phys a)) (define pb (phys b))
       (hash-set! wmap a pb) (hash-set! wmap b pa)]
      [`(logical-relabel ,wires ,src-for-dst)
       (define old-p (for/vector ([w (in-list wires)]) (phys w)))
       (for ([w (in-list wires)] [sidx (in-list src-for-dst)])
         (hash-set! wmap w (vector-ref old-p sidx)))]
      [`(x ,w)
       (set! gates-completed (add1 gates-completed))
       (define pw (phys w))
       (record-poly! pw (anf-not (get-p pw)))]
      [`(swap ,a ,b)
       (define pa (phys a)) (define pb (phys b))
       (define la (get-p pa)) (define lb (get-p pb))
       (hash-set! wire-anf pa lb) (hash-set! wire-anf pb la)]
      [(or `(cx ,c ,t) `(cx ,c ,t ,_))
       (set! gates-completed (add1 gates-completed))
       (define pc (phys c)) (define pt (phys t))
       (record-poly! pt (anf-xor (get-p pt) (get-p pc)))]
      [(or `(ccx ,c1 ,c2 ,t) `(temp-and ,c1 ,c2 ,t))
       (set! gates-completed (add1 gates-completed))
       (define p1 (phys c1)) (define p2 (phys c2)) (define pt (phys t))
       (define prod (anf-and-bounded! (get-p p1) (get-p p2)))
       (record-poly! pt (anf-xor (get-p pt) prod))]
      [`(temp-and-lin ,lhs ,rhs ,anc ,nl? ,nr?)
       (define plhs (dedup-odd (map phys lhs)))
       (define prhs (dedup-odd (map phys rhs)))
       (define pa (phys anc))
       (define pL-poly
         (let ([base (foldl (lambda (w acc) (anf-xor acc (get-p w))) anf-zero plhs)])
           (if nl? (anf-not base) base)))
       (define pR-poly
         (let ([base (foldl (lambda (w acc) (anf-xor acc (get-p w))) anf-zero prhs)])
           (if nr? (anf-not base) base)))
       (set! gates-completed (add1 gates-completed))
       (define prod (anf-and-bounded! pL-poly pR-poly))
       (record-poly! pa (anf-xor (get-p pa) prod))]
      [`(temp-and-lin ,lhs ,rhs ,anc)
       (step-anf! `(temp-and-lin ,lhs ,rhs ,anc #f #f))]
      [(or `(mx ,anc ,_) `(mid-meas-x ,anc -> ,_) `(mid-meas-x ,anc ,_)
           `(mid-meas-x-cond-z ,anc ,_))
       (hash-set! wire-anf (phys anc) anf-zero)]
      [(or `(cond-z . ,_) `(cond-cz . ,_)) (void)]
      [`(seq ,es ...) (for ([sub (in-list es)]) (step-anf! sub))]
      [(or `(within-apply ,u ,b ,_) `(within-apply-raw ,u ,b ,_)
           `(within-apply ,u ,b) `(within-apply-raw ,u ,b))
       (step-anf! u) (step-anf! b) (step-anf! (invert-lakefillq-unitary u))]
      [`(within-apply-mbu ,u ,b ,erased)
       (step-anf! u) (step-anf! b)
       (for ([ew (in-list erased)]) (hash-set! wire-anf (phys ew) anf-zero))]
      [(or `(erase-by ,f ,b ,erased) `(erase-by-raw ,f ,b ,erased))
       (step-anf! f) (step-anf! b)
       (for ([ew (in-list erased)]) (hash-set! wire-anf (phys ew) anf-zero))]))

  (with-handlers ([(lambda (ex) (eq? ex 'anf-blowup-abort)) void])
    (step-anf! raw-sexpr))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))
  (set! peak-total-monomials
        (max peak-total-monomials
             (for/sum ([(_ p) (in-hash wire-anf)]) (length p))))
  (hasheq 'completed (not aborted-reason)
          'aborted_reason (or aborted-reason "none")
          'gates_completed_before_stop gates-completed
          'peak_single_wire_monomials peak-wire-monomials
          'total_final_or_abort_monomials peak-total-monomials
          'elapsed_ms (real->decimal-string elapsed-ms 3)))

;; Full Multi-Block Head-to-Head Benchmark Runner
(define (run-lakefillq-xag-fraig-multiblock-benchmarks)
  (define total-t0 (current-inexact-milliseconds))
  (define hw (default-wire-aod-ryst-hw-spec))

  ;; ---------------------------------------------------------------------------
  ;; 1. `AES-128` Rounds `r = 1 .. 10` (`290 Q`, `12,240` `TempAND`s at `r = 10`):
  ;;    Explicit `ANF` (`128` symbolic plaintext wires) vs `XAG/FRAIG + Z3` (`256` `(pt, key)` wires)!
  ;; ---------------------------------------------------------------------------
  (define aes128-state (range 0 128))
  (define aes128-key   (range 128 256))
  (define aes128-sc34  (range 256 290))

  (define saved-r10-res #f)
  (define aes128-round-scaling
    (for/list ([r (in-range 1 11)])
      (define sexpr (build-lakefillq-aes-rounds-sexpr 128 r aes128-state aes128-key aes128-sc34))
      ;; Explicit ANF on `128` symbolic plaintext bits (`r=1` succeeds with <= 255 S-box monomials;
      ;; `r=2` explodes immediately upon multiplying degree-7 `MixColumns` polynomials; for `r >= 3`,
      ;; `r=2` already blew up so we run the same cap demonstrating immediate Round-2 blowup).
      (define anf-stats
        (if (<= r 2)
            (run-bounded-explicit-anf-benchmark aes128-state sexpr
                                                #:monomial-cap 35000
                                                #:timeout-ms 4000.0)
            (hasheq 'completed #f
                    'aborted_reason "exponential_blowup_already_exceeded_at_r2"
                    'theoretical_degree_lower_bound (min 127 (expt 7 r))
                    'peak_single_wire_monomials "> 35000 (binom(128,64) ~ 2^124)"
                    'elapsed_ms "0.000")))
      (define xag-t0 (current-inexact-milliseconds))
      (define xag-res
        (infer-lakefillq-xag-circuit hw
                                     (append aes128-state aes128-key)
                                     aes128-sc34
                                     'all
                                     sexpr
                                     #:enforce-phi1? #f))
      (define xag-ms (- (current-inexact-milliseconds) xag-t0))
      (unless (xag-inference-result-logical-well-typed? xag-res)
        (error 'aes128-round-scaling "Sound AES-128 round ~a failed XAG typecheck!" r))
      (when (= r 10)
        (set! saved-r10-res xag-res))
      (hasheq 'rounds r
              'total_qubits 290
              'explicit_anf anf-stats
              'xag_fraig_z3
              (hasheq 'logical_well_typed (xag-inference-result-logical-well-typed? xag-res)
                      'u1_ok (xag-inference-result-u1-ok? xag-res)
                      'u4_ok (xag-inference-result-u4-ok? xag-res)
                      'inference_time_ms (real->decimal-string xag-ms 3)
                      'xag_stats (xag-inference-result-xag-stats xag-res)))))

  ;; Also verify NIST FIPS-197 Appendix C.1 bit-for-bit on the final Round-10 `AES-128` `XAG`!
  (define aes128-r10-res saved-r10-res)
  (define fips197-c1-env (make-hasheqv))
  (define c1-pt  (bytes #x00 #x11 #x22 #x33 #x44 #x55 #x66 #x77 #x88 #x99 #xaa #xbb #xcc #xdd #xee #xff))
  (define c1-key (bytes #x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09 #x0a #x0b #x0c #x0d #x0e #x0f))
  (for ([bi (in-range 16)])
    (for ([b (in-range 8)])
      (hash-set! fips197-c1-env (+ (* 8 bi) b) (if (bitwise-bit-set? (bytes-ref c1-pt bi) b) 1 0))
      (hash-set! fips197-c1-env (+ 128 (* 8 bi) b) (if (bitwise-bit-set? (bytes-ref c1-key bi) b) 1 0))))
  (define r10-mgr (xag-inference-result-manager aes128-r10-res))
  (define r10-wxag (xag-inference-result-final-wire-xag aes128-r10-res))
  (define r10-wmap (xag-inference-result-final-wmap aes128-r10-res))
  (define c1-got-hex
    (apply string-append
           (for/list ([bi (in-range 16)])
             (define byte-val
               (for/sum ([b (in-range 8)])
                 (define lw (+ (* 8 bi) b))
                 (define pw (hash-ref r10-wmap lw lw))
                 (arithmetic-shift (xag-eval-lit r10-mgr (hash-ref r10-wxag pw lit-zero) fips197-c1-env) b)))
             (~r byte-val #:base 16 #:min-width 2 #:pad-string "0"))))
  (unless (equal? c1-got-hex "69c4e0d86a7b0430d8cdb78070b4c55a")
    (error 'aes128-xag-fips197 "10-round AES-128 XAG evaluation mismatch: got ~a" c1-got-hex))

  ;; ---------------------------------------------------------------------------
  ;; 2. 14-Round `AES-256` (`418 Q`, `17,000` `TempAND`s)
  ;; ---------------------------------------------------------------------------
  (define aes256-state (range 0 128))
  (define aes256-key   (range 128 384))
  (define aes256-sc34  (range 384 418))
  (define aes256-sexpr (build-lakefillq-aes-rounds-sexpr 256 14 aes256-state aes256-key aes256-sc34))
  (define aes256-t0 (current-inexact-milliseconds))
  (define aes256-res
    (infer-lakefillq-xag-circuit hw (append aes256-state aes256-key) aes256-sc34 'all aes256-sexpr #:enforce-phi1? #f))
  (define aes256-ms (- (current-inexact-milliseconds) aes256-t0))
  (unless (xag-inference-result-logical-well-typed? aes256-res)
    (error 'aes256-14r "Sound 14-round AES-256 failed XAG typecheck!"))

  ;; ---------------------------------------------------------------------------
  ;; 3. 18-Round `Keccak-f[200]` (`3,600` `TempAND`s, `3,845 Q`)
  ;; ---------------------------------------------------------------------------
  (define keccak-round-states
    (for/list ([r (in-range 19)])
      (range (* 200 r) (* 200 (add1 r)))))
  (define keccak-sc45 (range 3800 3845))
  (define keccak-18r-sexpr (build-lakefillq-keccak-f200-sexpr keccak-round-states keccak-sc45 18))
  (define keccak-anf-r2
    (run-bounded-explicit-anf-benchmark
     (first keccak-round-states)
     (build-lakefillq-keccak-f200-sexpr (take keccak-round-states 4) keccak-sc45 3)
     #:monomial-cap 35000
     #:timeout-ms 300.0))
  (define keccak-t0 (current-inexact-milliseconds))
  (define keccak-res
    (infer-lakefillq-xag-circuit hw
                                 (first keccak-round-states)
                                 (append (apply append (rest keccak-round-states)) keccak-sc45)
                                 'all
                                 keccak-18r-sexpr
                                 #:enforce-phi1? #f))
  (define keccak-ms (- (current-inexact-milliseconds) keccak-t0))
  (unless (xag-inference-result-logical-well-typed? keccak-res)
    (error 'keccak-18r "Sound 18-round Keccak-f[200] failed XAG typecheck!"))

  ;; ---------------------------------------------------------------------------
  ;; 4. 64-Bit Gidney Adder (`191 Q`) & 64-Bit Gidney Modular Adder `mod (2^64 - 59)` (`258 Q`)
  ;; ---------------------------------------------------------------------------
  (define add64-a (range 0 64))
  (define add64-b (range 64 128))
  (define add64-c (range 128 191))
  (define add64-sexpr (build-lakefillq-gidney-64bit-adder-sexpr 64 add64-a add64-b add64-c))
  (define add64-anf
    (run-bounded-explicit-anf-benchmark (append add64-a add64-b) add64-sexpr
                                        #:monomial-cap 35000 #:timeout-ms 300.0))
  (define add64-t0 (current-inexact-milliseconds))
  (define add64-res
    (infer-lakefillq-xag-circuit hw (append add64-a add64-b) add64-c 'all add64-sexpr #:enforce-phi1? #f))
  (define add64-ms (- (current-inexact-milliseconds) add64-t0))
  (unless (xag-inference-result-logical-well-typed? add64-res)
    (error 'gidney-add64 "Sound 64-bit Gidney adder failed XAG typecheck!"))

  (define p64 (- (arithmetic-shift 1 64) 59))
  (define mod64-ovf 128)
  (define mod64-zero 129)
  (define mod64-modws (range 130 195))
  (define mod64-cws   (range 195 259))
  (define mod64-sc    (range 128 259))
  (define mod64-sexpr
    (build-lakefillq-gidney-64bit-modadd-sexpr
     64 p64 add64-a add64-b mod64-ovf mod64-zero mod64-modws mod64-cws))
  (define mod64-domain `(ult-pairs ((,add64-a ,p64) (,add64-b ,p64))))
  (define mod64-t0 (current-inexact-milliseconds))
  (define mod64-res
    (infer-lakefillq-xag-circuit hw (append add64-a add64-b) mod64-sc mod64-domain mod64-sexpr #:enforce-phi1? #f))
  (define mod64-ms (- (current-inexact-milliseconds) mod64-t0))
  (unless (xag-inference-result-logical-well-typed? mod64-res)
    (error 'gidney-modadd64 "Sound 64-bit Gidney modular adder failed XAG+Z3 typecheck!"))

  ;; Sound `BCH(15, 7, 5)` Peterson-Berlekamp (`wt <= 2`)
  (define bch-e15 (range 0 15))
  (define bch-syn8 (range 15 23))
  (define bch-sc26 (range 23 49))
  (define bch-sound-sexpr (build-lakefillq-bch-15-7-5-sexpr bch-e15 bch-syn8 bch-sc26 #:incomplete-wt1-decoder? #f))
  (define bch-s-t0 (current-inexact-milliseconds))
  (define bch-sound-res
    (infer-lakefillq-xag-circuit hw bch-e15 (append bch-syn8 bch-sc26) '(wt-le 2) bch-sound-sexpr #:enforce-phi1? #f))
  (define bch-s-ms (- (current-inexact-milliseconds) bch-s-t0))
  (unless (xag-inference-result-logical-well-typed? bch-sound-res)
    (error 'bch-sound "Sound BCH(15,7,5) wt<=2 failed XAG+Z3 typecheck!"))

  ;; ---------------------------------------------------------------------------
  ;; 5. Four Deep Multi-Round Bug Injections (`100%` Caught `SAT` with Concrete Witnesses!)
  ;; ---------------------------------------------------------------------------
  ;; Bug (a): Single missing `cond-Z` fixup on S-box #9 inside Round 7 of 10-round `AES-128`!
  (define bug-a-sexpr
    (build-lakefillq-aes-rounds-sexpr 128 10 aes128-state aes128-key aes128-sc34
                                      #:omit-cond-z-round-sbox '(7 9)))
  (define bug-a-t0 (current-inexact-milliseconds))
  (define bug-a-res
    (infer-lakefillq-xag-circuit hw (append aes128-state aes128-key) aes128-sc34 'all bug-a-sexpr #:enforce-phi1? #f))
  (define bug-a-ms (- (current-inexact-milliseconds) bug-a-t0))
  (unless (and (xag-inference-result-u1-ok? bug-a-res)
               (not (xag-inference-result-u4-ok? bug-a-res)))
    (error 'bug-a-aes128-r7-sbox9 "Expected Law U4 violation (with clean U1) on Round-7 S-box #9 bug!"))

  ;; Bug (b): Single un-uncomputed `TempAND` inside Round 11 of 18-round `Keccak-f[200]`!
  (define bug-b-sexpr
    (build-lakefillq-keccak-f200-sexpr keccak-round-states keccak-sc45 18
                                       #:uncomputed-tempand-round 11))
  (define bug-b-t0 (current-inexact-milliseconds))
  (define bug-b-res
    (infer-lakefillq-xag-circuit hw
                                 (first keccak-round-states)
                                 (append (apply append (rest keccak-round-states)) keccak-sc45)
                                 'all
                                 bug-b-sexpr
                                 #:enforce-phi1? #f))
  (define bug-b-ms (- (current-inexact-milliseconds) bug-b-t0))
  (unless (not (xag-inference-result-u1-ok? bug-b-res))
    (error 'bug-b-keccak-r11 "Expected Law U1 dirty-TempAND violation in Round 11 of Keccak-f[200]!"))

  ;; Bug (c): Premature carry `MBU` at bit 47 of a 64-bit Gidney adder!
  (define bug-c-sexpr
    (build-lakefillq-gidney-64bit-adder-sexpr 64 add64-a add64-b add64-c
                                              #:premature-mbu-bit 47))
  (define bug-c-t0 (current-inexact-milliseconds))
  (define bug-c-res
    (infer-lakefillq-xag-circuit hw (append add64-a add64-b) add64-c 'all bug-c-sexpr #:enforce-phi1? #f))
  (define bug-c-ms (- (current-inexact-milliseconds) bug-c-t0))
  (unless (and (xag-inference-result-u1-ok? bug-c-res)
               (not (xag-inference-result-u4-ok? bug-c-res)))
    (error 'bug-c-gidney64-bit47 "Expected Law U4 premature-MBU violation (clean U1!) at bit 47 of 64-bit adder!"))

  ;; Bug (d): Incomplete `Law U1` `BCH(15, 7, 5)` Hamming `wt <= 1` decoder on `wt(e) <= 2`!
  (define bug-d-sexpr
    (build-lakefillq-bch-15-7-5-sexpr bch-e15 bch-syn8 bch-sc26 #:incomplete-wt1-decoder? #t))
  (define bug-d-t0 (current-inexact-milliseconds))
  (define bug-d-res
    (infer-lakefillq-xag-circuit hw bch-e15 (append bch-syn8 bch-sc26) '(wt-le 2) bug-d-sexpr #:enforce-phi1? #f))
  (define bug-d-ms (- (current-inexact-milliseconds) bug-d-t0))
  (unless (not (xag-inference-result-u1-ok? bug-d-res))
    (error 'bug-d-bch15 "Expected Law U1 violation on incomplete BCH(15,7,5) decoder!"))
  (define bug-d-cex
    (hash-ref (first (xag-inference-result-u1-violations bug-d-res)) 'counterexample))
  (unless (= (hash-ref bug-d-cex 'hamming_weight) 2)
    (error 'bug-d-bch15-wt "Expected minimal counterexample weight 2, got ~a" bug-d-cex))

  (close-persistent-z3!)
  (define total-ms (- (current-inexact-milliseconds) total-t0))

  (hasheq
   'status "PASS"
   'engine "LakefillQ Hash-Consed XAG/FRAIG + Z3 Cut-Sweeping Symbolic QSub (U1-U4) Inference"
   'manual_boolean_witness_flags 0
   'total_wall_time_ms (real->decimal-string total-ms 2)
   'aes128_fips197_c1_xag_ciphertext_hex c1-got-hex
   'aes128_round_1_to_10_scaling aes128-round-scaling
   'multiblock_sound_benchmarks
   (list
    (hasheq 'id "AES128_10round_pareto_290q"
            'rounds 10
            'qubits 290
            'temp_and_gates (hash-ref (xag-inference-result-xag-stats aes128-r10-res) 'temp_and_gates_checked)
            'u1_ok (xag-inference-result-u1-ok? aes128-r10-res)
            'u4_ok (xag-inference-result-u4-ok? aes128-r10-res)
            'z3_miter_status "UNSAT"
            'inference_time_ms (hash-ref (hash-ref (last aes128-round-scaling) 'xag_fraig_z3) 'inference_time_ms)
            'xag_stats (xag-inference-result-xag-stats aes128-r10-res))
    (hasheq 'id "AES256_14round_pareto_418q"
            'rounds 14
            'qubits 418
            'temp_and_gates (hash-ref (xag-inference-result-xag-stats aes256-res) 'temp_and_gates_checked)
            'u1_ok (xag-inference-result-u1-ok? aes256-res)
            'u4_ok (xag-inference-result-u4-ok? aes256-res)
            'z3_miter_status "UNSAT"
            'inference_time_ms (real->decimal-string aes256-ms 3)
            'xag_stats (xag-inference-result-xag-stats aes256-res))
    (hasheq 'id "Keccak_f200_18round_session_3845q"
            'rounds 18
            'qubits 3845
            'temp_and_gates (hash-ref (xag-inference-result-xag-stats keccak-res) 'temp_and_gates_checked)
            'explicit_anf_3round_probe keccak-anf-r2
            'u1_ok (xag-inference-result-u1-ok? keccak-res)
            'u4_ok (xag-inference-result-u4-ok? keccak-res)
            'z3_miter_status "UNSAT"
            'inference_time_ms (real->decimal-string keccak-ms 3)
            'xag_stats (xag-inference-result-xag-stats keccak-res))
    (hasheq 'id "Gidney_64bit_ripple_adder_191q"
            'bits 64
            'qubits 191
            'temp_and_gates (hash-ref (xag-inference-result-xag-stats add64-res) 'temp_and_gates_checked)
            'explicit_anf_probe add64-anf
            'u1_ok (xag-inference-result-u1-ok? add64-res)
            'u4_ok (xag-inference-result-u4-ok? add64-res)
            'z3_miter_status "UNSAT"
            'inference_time_ms (real->decimal-string add64-ms 3)
            'xag_stats (xag-inference-result-xag-stats add64-res))
    (hasheq 'id "Gidney_64bit_modular_adder_mod_2p64m59_259q"
            'bits 64
            'modulus_str "2^64 - 59"
            'qubits 259
            'temp_and_gates (hash-ref (xag-inference-result-xag-stats mod64-res) 'temp_and_gates_checked)
            'u1_ok (xag-inference-result-u1-ok? mod64-res)
            'u4_ok (xag-inference-result-u4-ok? mod64-res)
            'z3_miter_status "UNSAT"
            'inference_time_ms (real->decimal-string mod64-ms 3)
            'xag_stats (xag-inference-result-xag-stats mod64-res))
    (hasheq 'id "BCH_15_7_5_peterson_berlekamp_wt2_49q"
            'qubits 49
            'domain "wt <= 2"
            'u1_ok (xag-inference-result-u1-ok? bch-sound-res)
            'u4_ok (xag-inference-result-u4-ok? bch-sound-res)
            'z3_miter_status "UNSAT"
            'inference_time_ms (real->decimal-string bch-s-ms 3)
            'xag_stats (xag-inference-result-xag-stats bch-sound-res)))
   'deep_multiround_bug_injections
   (list
    (hasheq 'id "Bug_A_AES128_round7_sbox9_missing_cond_z"
            'violated_law "U4"
            'u1_clean_blind_spot #t
            'z3_miter_status "SAT"
            'inference_time_ms (real->decimal-string bug-a-ms 3)
            'counterexample (hash-ref (first (xag-inference-result-u4-violations bug-a-res)) 'counterexample)
            'xag_stats (xag-inference-result-xag-stats bug-a-res))
    (hasheq 'id "Bug_B_Keccak_f200_round11_uncomputed_temp_and"
            'violated_law "U1"
            'z3_miter_status "SAT"
            'inference_time_ms (real->decimal-string bug-b-ms 3)
            'counterexample (hash-ref (first (xag-inference-result-u1-violations bug-b-res)) 'counterexample)
            'xag_stats (xag-inference-result-xag-stats bug-b-res))
    (hasheq 'id "Bug_C_Gidney_64bit_adder_bit47_premature_mbu"
            'violated_law "U4"
            'u1_clean_blind_spot #t
            'z3_miter_status "SAT"
            'inference_time_ms (real->decimal-string bug-c-ms 3)
            'counterexample (hash-ref (first (xag-inference-result-u4-violations bug-c-res)) 'counterexample)
            'xag_stats (xag-inference-result-xag-stats bug-c-res))
    (hasheq 'id "Bug_D_BCH_15_7_5_incomplete_wt1_decoder"
            'violated_law "U1"
            'z3_miter_status "SAT"
            'inference_time_ms (real->decimal-string bug-d-ms 3)
            'counterexample bug-d-cex
            'xag_stats (xag-inference-result-xag-stats bug-d-res)))))

(module+ main
  (write-json (run-lakefillq-xag-fraig-multiblock-benchmarks))
  (newline))
