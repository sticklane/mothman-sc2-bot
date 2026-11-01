#lang racket/base

(require redex/reduction-semantics
         racket/match
         racket/list
         racket/vector
         racket/fixnum
         "quantum-syntax.rkt")

(provide -->kickmix
         run-kickmix-redex
         eval-kickmix-trajectory
         verify-kickmix-coherence
         make-dyadic
         dyadic-zero
         dyadic-one
         dyadic+
         dyadic-
         dyadic*
         dyadic-conj
         dyadic-norm-sq
         dyadic=?
         eval-dyadic-statevector-branch
         verify-dyadic-superposition-coherence)

;; =============================================================================
;; 1. PLT Redex Small-Step Operational Semantics (-->kickmix)
;;    Models Basis-State Kickmix Trajectories (arXiv:2610.22367 Equations 10-16)
;; =============================================================================

(define (env-lookup env key [default 0])
  (cond
    [(assoc key env) => cadr]
    [else default]))

(define (env-update env key val)
  (let loop ([xs env] [found? #f] [acc '()])
    (cond
      [(null? xs)
       (reverse (if found? acc (cons (list key val) acc)))]
      [(equal? (caar xs) key)
       (loop (cdr xs) #t (cons (list key val) acc))]
      [else
       (loop (cdr xs) found? (cons (car xs) acc))])))

(define (bits->int env qs)
  (for/fold ([acc 0])
            ([q (in-list qs)]
             [i (in-naturals)])
    (bitwise-ior acc (arithmetic-shift (env-lookup env q 0) i))))

(define (int->bits env qs val)
  (for/fold ([e env])
            ([q (in-list qs)]
             [i (in-naturals)])
    (env-update e q (bitwise-bit-field val i (add1 i)))))

(define -->kickmix
  (reduction-relation
   Quantum-Kickmix-Lang
   #:domain State

   ;; Sequential composition
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (seq))
        (kickmix-state bit-env meas-env sign anc-set nat_t nat_q skip)
        "E-Seq-Empty")

   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (seq skip C_rest ...))
        (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (seq C_rest ...))
        "E-Seq-Skip")

   ;; Pauli X (bit flip)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (X q))
        (kickmix-state ,(env-update (term bit-env) (term q)
                                    (bitwise-xor 1 (env-lookup (term bit-env) (term q))))
                       meas-env sign anc-set nat_t nat_q skip)
        "E-X")

   ;; CNOT
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (CNOT q_c q_t))
        (kickmix-state ,(let ([vc (env-lookup (term bit-env) (term q_c))]
                              [vt (env-lookup (term bit-env) (term q_t))])
                          (env-update (term bit-env) (term q_t) (bitwise-xor vc vt)))
                       meas-env sign anc-set nat_t nat_q skip)
        "E-CNOT")

   ;; SWAP
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (SWAP q_a q_b))
        (kickmix-state ,(let* ([va (env-lookup (term bit-env) (term q_a))]
                               [vb (env-lookup (term bit-env) (term q_b))]
                               [e1 (env-update (term bit-env) (term q_a) vb)])
                          (env-update e1 (term q_b) va))
                       meas-env sign anc-set nat_t nat_q skip)
        "E-SWAP")

   ;; Toffoli / CCX (1 Toffoli gate)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (Toffoli q_1 q_2 q_t))
        (kickmix-state ,(let ([v1 (env-lookup (term bit-env) (term q_1))]
                              [v2 (env-lookup (term bit-env) (term q_2))]
                              [vt (env-lookup (term bit-env) (term q_t))])
                          (env-update (term bit-env) (term q_t)
                                      (bitwise-xor vt (bitwise-and v1 v2))))
                       meas-env sign anc-set ,(add1 (term nat_t)) nat_q skip)
        "E-Toffoli")

   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (CCX q_1 q_2 q_t))
        (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (Toffoli q_1 q_2 q_t))
        "E-CCX")

   ;; CSWAP / Fredkin (1 Toffoli gate)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (CSWAP q_c q_a q_b))
        (kickmix-state ,(let ([vc (env-lookup (term bit-env) (term q_c))]
                              [va (env-lookup (term bit-env) (term q_a))]
                              [vb (env-lookup (term bit-env) (term q_b))])
                          (if (= vc 1)
                              (env-update (env-update (term bit-env) (term q_a) vb) (term q_b) va)
                              (term bit-env)))
                       meas-env sign anc-set ,(add1 (term nat_t)) nat_q skip)
        "E-CSWAP")

   ;; Diagonal Z, CZ, CCZ
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (Z q))
        (kickmix-state bit-env meas-env
                       ,(if (= (env-lookup (term bit-env) (term q)) 1)
                            (- (term sign))
                            (term sign))
                       anc-set nat_t nat_q skip)
        "E-Z")

   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (CZ q_a q_b))
        (kickmix-state bit-env meas-env
                       ,(if (= (bitwise-and (env-lookup (term bit-env) (term q_a))
                                            (env-lookup (term bit-env) (term q_b)))
                               1)
                            (- (term sign))
                            (term sign))
                       anc-set nat_t nat_q skip)
        "E-CZ")

   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (CCZ q_a q_b q_c))
        (kickmix-state bit-env meas-env
                       ,(if (= (bitwise-and (env-lookup (term bit-env) (term q_a))
                                            (env-lookup (term bit-env) (term q_b))
                                            (env-lookup (term bit-env) (term q_c)))
                               1)
                            (- (term sign))
                            (term sign))
                       anc-set ,(add1 (term nat_t)) nat_q skip)
        "E-CCZ")

   ;; Gidney Compute-AND (1 Toffoli)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (Compute-AND q_u q_v q_t))
        (kickmix-state ,(let ([vu (env-lookup (term bit-env) (term q_u))]
                              [vv (env-lookup (term bit-env) (term q_v))]
                              [vt (env-lookup (term bit-env) (term q_t))])
                          (env-update (term bit-env) (term q_t)
                                      (bitwise-xor vt (bitwise-and vu vv))))
                       meas-env sign anc-set ,(add1 (term nat_t)) nat_q skip)
        "E-Compute-AND")

   ;; Destructive X-Basis Measurement with Pre-Specified Trajectory Outcome m
   ;; Resets qubit q -> 0 and kicks back phase (-1)^(m_val * q_val) (0 Toffolis!)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (X-Meas q m))
        (kickmix-state ,(env-update (term bit-env) (term q) 0)
                       meas-env
                       ,(let ([vq (env-lookup (term bit-env) (term q))]
                              [vm (env-lookup (term meas-env) (term m))])
                          (if (= (bitwise-and vq vm) 1)
                              (- (term sign))
                              (term sign)))
                       anc-set nat_t nat_q skip)
        "E-X-Meas")

   ;; Classical feed-forward CZ conditioned on measurement record m (0 Toffolis!)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (CZ-if-meas m q_u q_v))
        (kickmix-state bit-env meas-env
                       ,(let ([vm (env-lookup (term meas-env) (term m))]
                              [vu (env-lookup (term bit-env) (term q_u))]
                              [vv (env-lookup (term bit-env) (term q_v))])
                          (if (= (bitwise-and vm vu vv) 1)
                              (- (term sign))
                              (term sign)))
                       anc-set nat_t nat_q skip)
        "E-CZ-if-meas")

   ;; Composite Gidney MBU-Uncompute-AND: expands to X-Meas followed by CZ-if-meas
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q (MBU-Uncompute-AND q_u q_v q_t m))
        (kickmix-state bit-env meas-env sign anc-set nat_t nat_q
                       (seq (X-Meas q_t m) (CZ-if-meas m q_u q_v)))
        "E-MBU-Uncompute-AND")

   ;; Conditional Routing Idiom R_b^{-1} K R_b (arXiv:2610.22367 Fig. 1b)
   (--> (kickmix-state bit-env meas-env sign anc-set nat_t nat_q
                       (routed-branch q_b ((q_x q_y) ...) C_kernel))
        (kickmix-state bit-env meas-env sign anc-set nat_t nat_q
                       (seq ,@(map (lambda (p) `(CSWAP ,(term q_b) ,(car p) ,(cadr p)))
                                   (term ((q_x q_y) ...)))
                            C_kernel
                            ,@(map (lambda (p) `(CSWAP ,(term q_b) ,(car p) ,(cadr p)))
                                   (reverse (term ((q_x q_y) ...))))))
        "E-Routed-Branch")))

(define (run-kickmix-redex init-state)
  (apply-reduction-relation* -->kickmix init-state))

;; =============================================================================
;; 2. Fast Compiled Trajectory Evaluator & Exhaustive Coherence Verifier
;;    Checks Equations (10)-(16) of arXiv:2610.22367 Across All 2^k Branches
;; =============================================================================

(define (collect-meas-ids c)
  (remove-duplicates
   (let loop ([t c])
     (match t
       [`(X-Meas ,_ ,m) (list m)]
       [`(CZ-if-meas ,m ,_ ,_) (list m)]
       [`(MBU-Uncompute-AND ,_ ,_ ,_ ,m) (list m)]
       [`(X-if-meas ,m ,_) (list m)]
       [`(CNOT-if-meas ,m ,_ ,_) (list m)]
       [`(CSWAP-if-meas ,m ,_ ,_ ,_) (list m)]
       [`(seq ,cs ...) (append-map loop cs)]
       [`(adjoint ,inner) (loop inner)]
       [`(ctrl ,_ ,inner) (loop inner)]
       [`(with-ancilla ,_ ,inner) (loop inner)]
       [`(free-ancilla ,_ ,inner) (loop inner)]
       [`(routed-branch ,_ ,_ ,inner) (loop inner)]
       [`(uncompute-with-decoder ,_ ,_ ,dec ,inv)
        (append (loop dec) (loop inv))]
       [_ '()]))))

;; Evaluate a single Kickmix trajectory (input assignment + measurement record m)
;; Returns (values final-bit-hash final-phase toffoli-count peak-ancillas dirty-ancilla-errors)
(define (eval-kickmix-trajectory c init-bits meas-bits)
  (define bits (make-hasheq))
  (for ([(k v) (in-hash init-bits)])
    (hash-set! bits k v))
  (define phase 1)
  (define toffolis 0)
  (define active-ancs 0)
  (define peak-ancs 0)
  (define dirty-errors '())

  (define (bref q) (hash-ref bits q 0))
  (define (bset! q v) (hash-set! bits q (bitwise-and v 1)))
  (define (mref m) (hash-ref meas-bits m 0))

  (define (exec term ctrl-active? ctrl-depth)
    (when ctrl-active?
      (match term
        ['skip (void)]
        [`(X ,q)
         (when (> ctrl-depth 1)
           (set! toffolis (+ toffolis (sub1 ctrl-depth))))
         (bset! q (bitwise-xor 1 (bref q)))]
        [`(CNOT ,c1 ,t)
         (when (> ctrl-depth 0)
           (set! toffolis (+ toffolis ctrl-depth)))
         (bset! t (bitwise-xor (bref t) (bref c1)))]
        [`(SWAP ,a ,b)
         (when (> ctrl-depth 0)
           (set! toffolis (+ toffolis ctrl-depth)))
         (define va (bref a))
         (define vb (bref b))
         (bset! a vb)
         (bset! b va)]
        [`(Toffoli ,c1 ,c2 ,t)
         (set! toffolis (+ toffolis 1 ctrl-depth))
         (bset! t (bitwise-xor (bref t) (bitwise-and (bref c1) (bref c2))))]
        [`(CCX ,c1 ,c2 ,t)
         (exec `(Toffoli ,c1 ,c2 ,t) ctrl-active? ctrl-depth)]
        [`(CSWAP ,c1 ,a ,b)
         (set! toffolis (+ toffolis 1 ctrl-depth))
         (when (= (bref c1) 1)
           (define va (bref a))
           (define vb (bref b))
           (bset! a vb)
           (bset! b va))]
        [`(Z ,q)
         (when (> ctrl-depth 1)
           (set! toffolis (+ toffolis (sub1 ctrl-depth))))
         (when (= (bref q) 1)
           (set! phase (- phase)))]
        [`(CZ ,a ,b)
         (when (> ctrl-depth 0)
           (set! toffolis (+ toffolis ctrl-depth)))
         (when (= (bitwise-and (bref a) (bref b)) 1)
           (set! phase (- phase)))]
        [`(CCZ ,a ,b ,c1)
         (set! toffolis (+ toffolis 1 ctrl-depth))
         (when (= (bitwise-and (bref a) (bref b) (bref c1)) 1)
           (set! phase (- phase)))]
        [`(PhaseFlip ,s)
         (when (= s -1)
           (set! phase (- phase)))]
        [`(Compute-AND ,u ,v ,t)
         (set! toffolis (+ toffolis 1 ctrl-depth))
         (bset! t (bitwise-xor (bref t) (bitwise-and (bref u) (bref v))))]
        [`(X-Meas ,q ,m)
         (define vq (bref q))
         (define vm (mref m))
         (when (= (bitwise-and vq vm) 1)
           (set! phase (- phase)))
         (bset! q 0)]
        [`(CZ-if-meas ,m ,u ,v)
         (when (= (bitwise-and (mref m) (bref u) (bref v)) 1)
           (set! phase (- phase)))]
        [`(MBU-Uncompute-AND ,u ,v ,t ,m)
         (exec `(X-Meas ,t ,m) ctrl-active? ctrl-depth)
         (exec `(CZ-if-meas ,m ,u ,v) ctrl-active? ctrl-depth)]
        ;; Unsafe measurement-controlled basis gates (for bug reproduction)
        [`(X-if-meas ,m ,q)
         (when (= (mref m) 1)
           (bset! q (bitwise-xor 1 (bref q))))]
        [`(CNOT-if-meas ,m ,c1 ,t)
         (when (= (mref m) 1)
           (bset! t (bitwise-xor (bref t) (bref c1))))]
        [`(CSWAP-if-meas ,m ,c1 ,a ,b)
         (set! toffolis (add1 toffolis))
         (when (and (= (mref m) 1) (= (bref c1) 1))
           (define va (bref a))
           (define vb (bref b))
           (bset! a vb)
           (bset! b va))]
        ;; Arithmetic Macro Blocks
        [`(Cuccaro-ADD ,n ,xs ,ys ,anc)
         (set! toffolis (+ toffolis (if (= ctrl-depth 0) (max 0 (sub1 (* 2 n))) (* 2 (max 0 (sub1 (* 2 n)))))))
         (define modulus (arithmetic-shift 1 n))
         (define xv (for/fold ([acc 0]) ([q (in-list xs)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define yv (for/fold ([acc 0]) ([q (in-list ys)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define sum (modulo (+ xv yv) modulus))
         (for ([q (in-list ys)] [i (in-naturals)])
           (bset! q (bitwise-bit-field sum i (add1 i))))]
        [`(Cuccaro-SUB ,n ,xs ,ys ,anc)
         (set! toffolis (+ toffolis (if (= ctrl-depth 0) (max 0 (sub1 (* 2 n))) (* 2 (max 0 (sub1 (* 2 n)))))))
         (define modulus (arithmetic-shift 1 n))
         (define xv (for/fold ([acc 0]) ([q (in-list xs)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define yv (for/fold ([acc 0]) ([q (in-list ys)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define diff (modulo (- yv xv) modulus))
         (for ([q (in-list ys)] [i (in-naturals)])
           (bset! q (bitwise-bit-field diff i (add1 i))))]
        [`(Gidney-ADD ,n ,xs ,ys ,ancs)
         (set! toffolis (+ toffolis (if (= ctrl-depth 0) (max 0 (sub1 n)) (+ (max 0 (sub1 n)) n))))
         (define modulus (arithmetic-shift 1 n))
         (define xv (for/fold ([acc 0]) ([q (in-list xs)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define yv (for/fold ([acc 0]) ([q (in-list ys)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define sum (modulo (+ xv yv) modulus))
         (for ([q (in-list ys)] [i (in-naturals)])
           (bset! q (bitwise-bit-field sum i (add1 i))))]
        [`(Gidney-SUB ,n ,xs ,ys ,ancs)
         (set! toffolis (+ toffolis (if (= ctrl-depth 0) (max 0 (sub1 n)) (+ (max 0 (sub1 n)) n))))
         (define modulus (arithmetic-shift 1 n))
         (define xv (for/fold ([acc 0]) ([q (in-list xs)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define yv (for/fold ([acc 0]) ([q (in-list ys)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define diff (modulo (- yv xv) modulus))
         (for ([q (in-list ys)] [i (in-naturals)])
           (bset! q (bitwise-bit-field diff i (add1 i))))]
        [`(Schoolbook-MADD ,n ,xs ,ys ,zs ,ancs)
         (set! toffolis (+ toffolis
                           (if (= ctrl-depth 0)
                               (quotient (- (+ (* 3 n n) (* 17 n)) 2) 2)
                               (- (+ (* 3 n n) (* 17 n)) 2))))
         (define modulus (arithmetic-shift 1 n))
         (define xv (for/fold ([acc 0]) ([q (in-list xs)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define yv (for/fold ([acc 0]) ([q (in-list ys)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define zv (for/fold ([acc 0]) ([q (in-list zs)] [i (in-naturals)])
                      (bitwise-ior acc (arithmetic-shift (bref q) i))))
         (define res (modulo (+ zv (* xv yv)) modulus))
         (for ([q (in-list zs)] [i (in-naturals)])
           (bset! q (bitwise-bit-field res i (add1 i))))]
        [`(seq ,cs ...)
         (for ([sub (in-list cs)])
           (exec sub ctrl-active? ctrl-depth))]
        [`(adjoint ,inner)
         (exec (circuit-adjoint inner) ctrl-active? ctrl-depth)]
        [`(ctrl ,cq ,inner)
         (define cval (= (bref cq) 1))
         (exec inner (and ctrl-active? cval) (add1 ctrl-depth))]
        [`(with-ancilla ,qs ,inner)
         (for ([q (in-list qs)])
           (bset! q 0))
         (set! active-ancs (+ active-ancs (length qs)))
         (set! peak-ancs (max peak-ancs active-ancs))
         (exec inner ctrl-active? ctrl-depth)
         ;; Check strict uncomputation at end of scope (Kickmix Invariant 2)
         (for ([q (in-list qs)])
           (unless (= (bref q) 0)
             (set! dirty-errors
                   (cons (format "Dirty ancilla ~a = ~a at scope exit" q (bref q))
                         dirty-errors))))
         (set! active-ancs (- active-ancs (length qs)))]
        [`(free-ancilla ,qs ,inner)
         (exec inner ctrl-active? ctrl-depth)
         (for ([q (in-list qs)])
           (unless (= (bref q) 0)
             (set! dirty-errors
                   (cons (format "Dirty ancilla ~a = ~a at free-ancilla" q (bref q))
                         dirty-errors))))]
        [`(routed-branch ,b ,pairs ,inner)
         (for ([p (in-list pairs)])
           (exec `(CSWAP ,b ,(car p) ,(cadr p)) ctrl-active? ctrl-depth))
         (exec inner ctrl-active? ctrl-depth)
         (for ([p (in-list (reverse pairs))])
           (exec `(CSWAP ,b ,(car p) ,(cadr p)) ctrl-active? ctrl-depth))]
        [`(uncompute-with-decoder ,b-anc ,_ ,decoder ,inv-step)
         (bset! b-anc 0)
         (set! active-ancs (add1 active-ancs))
         (set! peak-ancs (max peak-ancs active-ancs))
         (exec decoder ctrl-active? ctrl-depth)
         (exec inv-step ctrl-active? ctrl-depth)
         (unless (= (bref b-anc) 0)
           (set! dirty-errors
                 (cons (format "Decoder failed to uncompute branch ancilla ~a (got ~a)"
                               b-anc (bref b-anc))
                       dirty-errors)))
         (set! active-ancs (sub1 active-ancs))]))
    (unless ctrl-active?
      ;; Still account for static Toffoli gate cost even when control bit is 0 in circuit
      (set! toffolis (+ toffolis (circuit-toffoli-cost term ctrl-depth)))))

  (exec c #t 0)
  (values bits phase toffolis peak-ancs (reverse dirty-errors)))

;; Exhaustively verify all 4 Kickmix Coherence Invariants (arXiv:2610.22367 Eq. 10-16)
;; across a list of input-bit hashes and ALL 2^k measurement trajectories!
;; Returns a struct/hash summary with:
;;   'coherent?         -> boolean
;;   'perm-ok?          -> boolean (Invariant 1: pi(x) = target-perm(x) for all x, m)
;;   'ancilla-clean?    -> boolean (Invariant 2: all ancillas returned to |0>)
;;   'phase-independent?-> boolean (Invariant 3: phi(x, m) = target-phase(x), independent of m)
;;   'control-safe?     -> boolean (Invariant 4: no basis gates controlled by measurement record m)
;;   'toffoli-count     -> exact Toffoli count
;;   'peak-ancillas     -> peak ancilla count
;;   'violations        -> list of human-readable violation strings
(define (verify-kickmix-coherence c input-envs target-perm-fn
                                  #:target-phase [target-phase-fn (lambda (_env) 1)]
                                  #:check-qubits [check-qubits #f])
  (define control-violations (validate-classical-control-discipline c))
  (define control-safe? (null? control-violations))
  (define meas-ids (collect-meas-ids c))
  (define num-meas (length meas-ids))
  (define num-branches (arithmetic-shift 1 num-meas))

  (define perm-ok? #t)
  (define ancilla-clean? #t)
  (define phase-independent? #t)
  (define violations (reverse control-violations))
  (define max-toffolis 0)
  (define max-ancillas 0)

  (for ([in-env (in-list input-envs)])
    (define expected-out (target-perm-fn in-env))
    (define expected-ph  (target-phase-fn in-env))
    (define ref-branch-phase #f)

    (for ([m-mask (in-range num-branches)])
      (define m-hash (make-hasheq))
      (for ([m-id (in-list meas-ids)]
            [bit-idx (in-naturals)])
        (hash-set! m-hash m-id (bitwise-bit-field m-mask bit-idx (add1 bit-idx))))

      (define-values (out-bits out-phase toffolis peak-ancs dirty-errs)
        (eval-kickmix-trajectory c in-env m-hash))

      (set! max-toffolis (max max-toffolis toffolis))
      (set! max-ancillas (max max-ancillas peak-ancs))

      ;; Invariant 2: Strict ancilla uncomputation
      (unless (null? dirty-errs)
        (set! ancilla-clean? #f)
        (set! violations (append dirty-errs violations)))

      ;; Also check any explicit ancilla keys in expected-out mapped to 'ancilla-0
      (define keys-to-check
        (or check-qubits (hash-keys expected-out)))
      (for ([q (in-list keys-to-check)])
        (define actual-v (hash-ref out-bits q 0))
        (define exp-v    (hash-ref expected-out q 0))
        (unless (= actual-v exp-v)
          (set! perm-ok? #f)
          (set! violations
                (cons (format "Permutation mismatch on qubit ~a (meas mask ~b): expected ~a, got ~a"
                              q m-mask exp-v actual-v)
                      violations))))

      ;; Invariant 3: Phase independence from measurement trajectory m
      (if (not ref-branch-phase)
          (set! ref-branch-phase out-phase)
          (unless (= out-phase ref-branch-phase)
            (set! phase-independent? #f)
            (set! violations
                  (cons (format "Phase depends on measurement trajectory m=~b: got ~a vs m=0 phase ~a"
                                m-mask out-phase ref-branch-phase)
                        violations))))
      (unless (= out-phase expected-ph)
        (set! phase-independent? #f)
        (set! violations
              (cons (format "Target phase mismatch (meas mask ~b): expected ~a, got ~a"
                            m-mask expected-ph out-phase)
                    violations)))))

  (hasheq 'coherent? (and perm-ok? ancilla-clean? phase-independent? control-safe?)
          'perm-ok? perm-ok?
          'ancilla-clean? ancilla-clean?
          'phase-independent? phase-independent?
          'control-safe? control-safe?
          'toffoli-count max-toffolis
          'peak-ancillas max-ancillas
          'num-meas-branches num-branches
          'violations (remove-duplicates (reverse violations))))

;; =============================================================================
;; 3. Exact Dyadic Cyclotomic Statevector Box over Q(sqrt(2), i)
;;    Cross-Validates Kickmix Basis Coherence on Universal Superpositions!
;; =============================================================================
;; Every amplitude in Clifford+T + X-Measurement circuits lies in the ring
;; Z[1/sqrt(2), e^(i*pi/4)], which has a canonical 4-tuple representation:
;;   alpha = (a + b*sqrt(2) + c*i + d*i*sqrt(2)) / 2^k
;; Represented exact-rationally as (dyadic a b c d) where a, b, c, d in Q:
;;   value = (a + b*sqrt(2)) + i*(c + d*sqrt(2)).

(struct dyadic (a b c d) #:transparent)

(define dyadic-zero (dyadic 0 0 0 0))
(define dyadic-one  (dyadic 1 0 0 0))
(define dyadic-i    (dyadic 0 0 1 0))
(define dyadic-inv-sqrt2 (dyadic 0 1/2 0 0)) ;; 1/sqrt(2) = (1/2)*sqrt(2)
;; e^(i*pi/4) = (1 + i)/sqrt(2) = (1/2)*sqrt(2) + i*(1/2)*sqrt(2)
(define dyadic-omega     (dyadic 0 1/2 0 1/2))
;; e^(-i*pi/4) = (1 - i)/sqrt(2)
(define dyadic-omega-dag (dyadic 0 1/2 0 -1/2))

(define (make-dyadic a [b 0] [c 0] [d 0])
  (dyadic a b c d))

(define (dyadic=? x y)
  (and (= (dyadic-a x) (dyadic-a y))
       (= (dyadic-b x) (dyadic-b y))
       (= (dyadic-c x) (dyadic-c y))
       (= (dyadic-d x) (dyadic-d y))))

(define (dyadic+ x y)
  (dyadic (+ (dyadic-a x) (dyadic-a y))
          (+ (dyadic-b x) (dyadic-b y))
          (+ (dyadic-c x) (dyadic-c y))
          (+ (dyadic-d x) (dyadic-d y))))

(define (dyadic- x y)
  (dyadic (- (dyadic-a x) (dyadic-a y))
          (- (dyadic-b x) (dyadic-b y))
          (- (dyadic-c x) (dyadic-c y))
          (- (dyadic-d x) (dyadic-d y))))

(define (dyadic-neg x)
  (dyadic (- (dyadic-a x)) (- (dyadic-b x)) (- (dyadic-c x)) (- (dyadic-d x))))

;; Multiplication in Q(sqrt(2), i):
;; Let X = (a1 + b1*sqrt(2)) + i*(c1 + d1*sqrt(2))
;;     Y = (a2 + b2*sqrt(2)) + i*(c2 + d2*sqrt(2))
(define (dyadic* x y)
  (match-define (dyadic a1 b1 c1 d1) x)
  (match-define (dyadic a2 b2 c2 d2) y)
  (define (mul-r2 p1 q1 p2 q2)
    (values (+ (* p1 p2) (* 2 q1 q2))
            (+ (* p1 q2) (* q1 p2))))
  (define-values (rr-a rr-b) (mul-r2 a1 b1 a2 b2))
  (define-values (ii-a ii-b) (mul-r2 c1 d1 c2 d2))
  (define-values (ri-a ri-b) (mul-r2 a1 b1 c2 d2))
  (define-values (ir-a ir-b) (mul-r2 c1 d1 a2 b2))
  (dyadic (- rr-a ii-a)
          (- rr-b ii-b)
          (+ ri-a ir-a)
          (+ ri-b ir-b)))

(define (dyadic-conj x)
  (dyadic (dyadic-a x) (dyadic-b x) (- (dyadic-c x)) (- (dyadic-d x))))

;; Returns (values r-part sqrt2-part) of |x|^2 = (a + b*sqrt(2))^2 + (c + d*sqrt(2))^2
(define (dyadic-norm-sq x)
  (define prod (dyadic* x (dyadic-conj x)))
  (values (dyadic-a prod) (dyadic-b prod)))

;; Exact statevector evolution for a circuit on qubit list `qubits` under measurement
;; branch `meas-bits` (where projective X-measurement projects onto |+> for m=0 or |-> for m=1,
;; normalized by sqrt(2) and then resets the measured ancilla to |0>).
(define (eval-dyadic-statevector-branch c qubits init-sv meas-bits)
  (define n (length qubits))
  (define dim (arithmetic-shift 1 n))
  (define q-idx (for/hasheq ([q (in-list qubits)] [i (in-naturals)]) (values q i)))
  (define (idx-of q) (hash-ref q-idx q))
  (define sv (vector-copy init-sv))

  (define (apply-1q! qi f)
    (define mask (arithmetic-shift 1 qi))
    (for ([s (in-range dim)] #:when (= (bitwise-and s mask) 0))
      (define s0 s)
      (define s1 (bitwise-ior s mask))
      (define a0 (vector-ref sv s0))
      (define a1 (vector-ref sv s1))
      (define-values (n0 n1) (f a0 a1))
      (vector-set! sv s0 n0)
      (vector-set! sv s1 n1)))

  (define (exec term)
    (match term
      ['skip (void)]
      [`(H ,q)
       (apply-1q! (idx-of q)
                  (lambda (a0 a1)
                    (values (dyadic* dyadic-inv-sqrt2 (dyadic+ a0 a1))
                            (dyadic* dyadic-inv-sqrt2 (dyadic- a0 a1)))))]
      [`(S ,q)
       (apply-1q! (idx-of q)
                  (lambda (a0 a1) (values a0 (dyadic* dyadic-i a1))))]
      [`(T ,q)
       (apply-1q! (idx-of q)
                  (lambda (a0 a1) (values a0 (dyadic* dyadic-omega a1))))]
      [`(Tdg ,q)
       (apply-1q! (idx-of q)
                  (lambda (a0 a1) (values a0 (dyadic* dyadic-omega-dag a1))))]
      [`(X ,q)
       (apply-1q! (idx-of q) (lambda (a0 a1) (values a1 a0)))]
      [`(Z ,q)
       (apply-1q! (idx-of q) (lambda (a0 a1) (values a0 (dyadic-neg a1))))]
      [`(CNOT ,c1 ,t)
       (define mc (arithmetic-shift 1 (idx-of c1)))
       (define mt (arithmetic-shift 1 (idx-of t)))
       (for ([s (in-range dim)]
             #:when (and (not (= (bitwise-and s mc) 0))
                         (= (bitwise-and s mt) 0)))
         (define s1 (bitwise-ior s mt))
         (define tmp (vector-ref sv s))
         (vector-set! sv s (vector-ref sv s1))
         (vector-set! sv s1 tmp))]
      [`(SWAP ,a ,b)
       (define ma (arithmetic-shift 1 (idx-of a)))
       (define mb (arithmetic-shift 1 (idx-of b)))
       (for ([s (in-range dim)]
             #:when (and (not (= (bitwise-and s ma) 0))
                         (= (bitwise-and s mb) 0)))
         (define s2 (bitwise-ior (bitwise-xor s ma) mb))
         (define tmp (vector-ref sv s))
         (vector-set! sv s (vector-ref sv s2))
         (vector-set! sv s2 tmp))]
      [`(Toffoli ,c1 ,c2 ,t)
       (define m1 (arithmetic-shift 1 (idx-of c1)))
       (define m2 (arithmetic-shift 1 (idx-of c2)))
       (define mt (arithmetic-shift 1 (idx-of t)))
       (for ([s (in-range dim)]
             #:when (and (not (= (bitwise-and s m1) 0))
                         (not (= (bitwise-and s m2) 0))
                         (= (bitwise-and s mt) 0)))
         (define s1 (bitwise-ior s mt))
         (define tmp (vector-ref sv s))
         (vector-set! sv s (vector-ref sv s1))
         (vector-set! sv s1 tmp))]
      [`(CCX ,c1 ,c2 ,t)
       (exec `(Toffoli ,c1 ,c2 ,t))]
      [`(CSWAP ,c1 ,a ,b)
       (define mc (arithmetic-shift 1 (idx-of c1)))
       (define ma (arithmetic-shift 1 (idx-of a)))
       (define mb (arithmetic-shift 1 (idx-of b)))
       (for ([s (in-range dim)]
             #:when (and (not (= (bitwise-and s mc) 0))
                         (not (= (bitwise-and s ma) 0))
                         (= (bitwise-and s mb) 0)))
         (define s2 (bitwise-ior (bitwise-xor s ma) mb))
         (define tmp (vector-ref sv s))
         (vector-set! sv s (vector-ref sv s2))
         (vector-set! sv s2 tmp))]
      [`(CZ ,a ,b)
       (define ma (arithmetic-shift 1 (idx-of a)))
       (define mb (arithmetic-shift 1 (idx-of b)))
       (for ([s (in-range dim)]
             #:when (and (not (= (bitwise-and s ma) 0))
                         (not (= (bitwise-and s mb) 0))))
         (vector-set! sv s (dyadic-neg (vector-ref sv s))))]
      [`(CCZ ,a ,b ,c1)
       (define ma (arithmetic-shift 1 (idx-of a)))
       (define mb (arithmetic-shift 1 (idx-of b)))
       (define mc (arithmetic-shift 1 (idx-of c1)))
       (for ([s (in-range dim)]
             #:when (and (not (= (bitwise-and s ma) 0))
                         (not (= (bitwise-and s mb) 0))
                         (not (= (bitwise-and s mc) 0))))
         (vector-set! sv s (dyadic-neg (vector-ref sv s))))]
      [`(Compute-AND ,u ,v ,t)
       (exec `(Toffoli ,u ,v ,t))]
      [`(X-Meas ,q ,m)
       ;; Destructive X-measurement of q with outcome r = meas-bits[m], resetting q -> |0>:
       ;; |0>_q |psi_0> + |1>_q |psi_1>  -->  |0>_q (|psi_0> + (-1)^r |psi_1>)
       (define r (hash-ref meas-bits m 0))
       (apply-1q! (idx-of q)
                  (lambda (a0 a1)
                    (values (if (= r 0) (dyadic+ a0 a1) (dyadic- a0 a1))
                            dyadic-zero)))]
      [`(CZ-if-meas ,m ,u ,v)
       (when (= (hash-ref meas-bits m 0) 1)
         (exec `(CZ ,u ,v)))]
      [`(MBU-Uncompute-AND ,u ,v ,t ,m)
       (exec `(X-Meas ,t ,m))
       (exec `(CZ-if-meas ,m ,u ,v))]
      [`(X-if-meas ,m ,q)
       (when (= (hash-ref meas-bits m 0) 1)
         (exec `(X ,q)))]
      [`(CNOT-if-meas ,m ,c1 ,t)
       (when (= (hash-ref meas-bits m 0) 1)
         (exec `(CNOT ,c1 ,t)))]
      [`(CSWAP-if-meas ,m ,c1 ,a ,b)
       (when (= (hash-ref meas-bits m 0) 1)
         (exec `(CSWAP ,c1 ,a ,b)))]
      [`(seq ,cs ...)
       (for ([sub (in-list cs)]) (exec sub))]
      [`(with-ancilla ,_ ,inner)
       (exec inner)]
      [`(routed-branch ,b ,pairs ,inner)
       (for ([p (in-list pairs)]) (exec `(CSWAP ,b ,(car p) ,(cadr p))))
       (exec inner)
       (for ([p (in-list (reverse pairs))]) (exec `(CSWAP ,b ,(car p) ,(cadr p))))]
      [`(uncompute-with-decoder ,_ ,_ ,dec ,inv)
       (exec dec)
       (exec inv)]))

  (exec c)
  sv)

;; Verify that across ALL 2^k measurement branches, a circuit `c` maps an arbitrary
;; dyadic quantum superposition `init-sv` to the EXACT SAME final statevector as `ref-circuit`!
(define (verify-dyadic-superposition-coherence c ref-circuit qubits init-sv)
  (define meas-ids (collect-meas-ids c))
  (define num-meas (length meas-ids))
  (define num-branches (arithmetic-shift 1 num-meas))
  (define ref-sv (eval-dyadic-statevector-branch ref-circuit qubits init-sv (hasheq)))

  (for/and ([m-mask (in-range num-branches)])
    (define m-hash (make-hasheq))
    (for ([m-id (in-list meas-ids)]
          [bit-idx (in-naturals)])
      (hash-set! m-hash m-id (bitwise-bit-field m-mask bit-idx (add1 bit-idx))))
    (define branch-sv (eval-dyadic-statevector-branch c qubits init-sv m-hash))
    (for/and ([amp-actual (in-vector branch-sv)]
              [amp-expected (in-vector ref-sv)])
      (dyadic=? amp-actual amp-expected))))
