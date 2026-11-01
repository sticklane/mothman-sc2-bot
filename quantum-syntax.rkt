#lang racket/base

(require redex/reduction-semantics
         racket/match
         racket/list)

(provide Quantum-Kickmix-Lang
         circuit-term?
         gate-term?
         qubit-id?
         reg-id?
         meas-id?
         circuit-adjoint
         circuit-toffoli-cost
         circuit-ancilla-peak
         validate-classical-control-discipline)

;; =============================================================================
;; PLT Redex Formal Syntax for Quantum Kickmix & Reversible Uncomputation
;; Grounded in arXiv:2610.22367 ("Discovering state-of-the-art quantum circuits
;; with large language models", Anthropic / Harvard / QuEra, 2026) and
;; Gidney (2018) "Halving the cost of quantum addition" (Quantum 2, 74).
;; =============================================================================

(define-language Quantum-Kickmix-Lang
  ;; Identifiers and Bit Values
  (q x y z u v w t b c ::= variable-not-otherwise-mentioned)
  (m r                 ::= variable-not-otherwise-mentioned)
  (reg                 ::= variable-not-otherwise-mentioned)
  (bit                 ::= 0 1)
  (sign                ::= 1 -1)
  (nat                 ::= natural)

  ;; Register Declarations & Ancilla Scopes
  (reg-decl ::=
    (input-reg reg (q ...))
    (output-reg reg (q ...))
    (ancilla-reg reg (q ...))
    (dirty-ancilla-reg reg (q ...)))

  ;; Classical Control Conditions on Measurement Record Bits (m in {0,1}^k)
  (meas-cond ::=
    (meas-is m bit)
    (meas-and meas-cond meas-cond)
    (meas-xor meas-cond meas-cond))

  ;; Primitive Reversible & Kickmix Gates
  (G ::=
    ;; 1. Classical Reversible Basis-Permutation Gates (0 Toffolis for X/CNOT/SWAP)
    (X q)
    (CNOT q q)
    (SWAP q q)
    ;; 2. Non-Clifford Reversible Gates (Toffoli / Fredkin)
    (Toffoli q q q)          ;; target <- target xor (c1 and c2); cost = 1 Toffoli
    (CCX q q q)              ;; alias for Toffoli
    (CSWAP q q q)            ;; Fredkin gate: swap(x, y) if c=1; cost = 1 Toffoli
    ;; 3. Diagonal Sign / Phase Gates (0 Toffolis for Z/CZ; 1 Toffoli for CCZ)
    (Z q)
    (CZ q q)
    (CCZ q q q)
    (PhaseFlip sign)
    ;; 4. Gidney Measurement-Based Uncomputation (MBU) Primitives
    (Compute-AND q q q)      ;; Clean ancilla t <- u and v (1 Toffoli)
    (X-Meas q m)             ;; Destructive X-basis measurement of q into record m
                             ;; Resets q -> 0 and kicks back phase (-1)^(m * q_val)
    (CZ-if-meas m q q)       ;; Classical feed-forward CZ(u, v) iff record bit m = 1 (0 Toffolis)
    (MBU-Uncompute-AND q q q m) ;; Composite Gidney uncomputation: (X-Meas t m) + (CZ-if-meas m u v)
    ;; 5. UNSAFE / BUGGY Measurement-Controlled Basis Gates (detected by Rule 4)
    (X-if-meas m q)
    (CNOT-if-meas m q q)
    (CSWAP-if-meas m q q q)
    ;; 6. Arithmetic Macro Blocks (with explicit Toffoli / Ancilla semantics)
    (Cuccaro-ADD nat (q ...) (q ...) q)    ;; n-bit ripple adder: 2n-1 Toffolis, 1 ancilla
    (Cuccaro-SUB nat (q ...) (q ...) q)
    (Gidney-ADD nat (q ...) (q ...) (q ...)) ;; n-bit Gidney logical-AND + MBU adder: n-1 Toffolis
    (Gidney-SUB nat (q ...) (q ...) (q ...))
    (Schoolbook-MADD nat (q ...) (q ...) (q ...) (q ...)))

  ;; Higher-Order Circuit Combinators
  (C ::=
    skip
    G
    (seq C ...)
    (adjoint C)
    (ctrl q C)
    (with-ancilla (q ...) C)
    (free-ancilla (q ...) C)
    ;; Conditional routing idiom R_b^{-1} K R_b from arXiv:2610.2610.22367 Fig. 1b
    (routed-branch q ((q q) ...) C)
    ;; State-decoded zero-history uncomputation from arXiv:2610.22367 Fig. 1c / Fig. 3
    (uncompute-with-decoder q (q ...) C C))

  ;; Small-Step Kickmix Machine State (Equations 10-16 of arXiv:2610.22367)
  ;; (kickmix-state bit-env meas-env phase active-ancillas toffoli-count peak-qubits C)
  (bit-binding  ::= (q bit))
  (meas-binding ::= (m bit))
  (bit-env      ::= (bit-binding ...))
  (meas-env     ::= (meas-binding ...))
  (anc-set      ::= (q ...))
  (State ::=
    (kickmix-state bit-env meas-env sign anc-set nat nat C)
    (kickmix-error string)))

(define circuit-term? (redex-match? Quantum-Kickmix-Lang C))
(define gate-term?    (redex-match? Quantum-Kickmix-Lang G))
(define qubit-id?     (redex-match? Quantum-Kickmix-Lang q))
(define reg-id?       (redex-match? Quantum-Kickmix-Lang reg))
(define meas-id?      (redex-match? Quantum-Kickmix-Lang m))

;; =============================================================================
;; Syntactic Adjoint (Dagger / Inverse Circuit) Operator
;; =============================================================================
(define (circuit-adjoint c)
  (match c
    ['skip 'skip]
    [`(X ,q) `(X ,q)]
    [`(CNOT ,c1 ,t) `(CNOT ,c1 ,t)]
    [`(SWAP ,a ,b) `(SWAP ,a ,b)]
    [`(Toffoli ,c1 ,c2 ,t) `(Toffoli ,c1 ,c2 ,t)]
    [`(CCX ,c1 ,c2 ,t) `(CCX ,c1 ,c2 ,t)]
    [`(CSWAP ,c1 ,a ,b) `(CSWAP ,c1 ,a ,b)]
    [`(Z ,q) `(Z ,q)]
    [`(CZ ,a ,b) `(CZ ,a ,b)]
    [`(CCZ ,a ,b ,c1) `(CCZ ,a ,b ,c1)]
    [`(PhaseFlip ,s) `(PhaseFlip ,s)]
    [`(Cuccaro-ADD ,n ,xs ,ys ,anc) `(Cuccaro-SUB ,n ,xs ,ys ,anc)]
    [`(Cuccaro-SUB ,n ,xs ,ys ,anc) `(Cuccaro-ADD ,n ,xs ,ys ,anc)]
    [`(Gidney-ADD ,n ,xs ,ys ,ancs) `(Gidney-SUB ,n ,xs ,ys ,ancs)]
    [`(Gidney-SUB ,n ,xs ,ys ,ancs) `(Gidney-ADD ,n ,xs ,ys ,ancs)]
    [`(seq ,cs ...)
     `(seq ,@(map circuit-adjoint (reverse cs)))]
    [`(adjoint ,inner) inner]
    [`(ctrl ,q ,inner) `(ctrl ,q ,(circuit-adjoint inner))]
    [`(with-ancilla ,qs ,inner) `(with-ancilla ,qs ,(circuit-adjoint inner))]
    [`(routed-branch ,b ,pairs ,inner)
     `(routed-branch ,b ,pairs ,(circuit-adjoint inner))]
    [other other]))

;; =============================================================================
;; Static Resource Analysis: Exact Toffoli Cost & Peak Ancilla Qubits
;; =============================================================================
(define (circuit-toffoli-cost c [ctrl-depth 0])
  (define (scale-ctrl base-cost)
    ;; Controlling a Toffoli adds 1 Toffoli per control wire (via temporary ANDs)
    (+ base-cost ctrl-depth))
  (match c
    ['skip 0]
    [`(X ,_) (if (> ctrl-depth 1) (sub1 ctrl-depth) 0)]
    [`(CNOT ,_ ,_) (if (> ctrl-depth 0) ctrl-depth 0)]
    [`(SWAP ,_ ,_) (if (> ctrl-depth 0) ctrl-depth 0)]
    [`(Toffoli ,_ ,_ ,_) (scale-ctrl 1)]
    [`(CCX ,_ ,_ ,_) (scale-ctrl 1)]
    [`(CSWAP ,_ ,_ ,_) (scale-ctrl 1)]
    [`(Z ,_) (if (> ctrl-depth 1) (sub1 ctrl-depth) 0)]
    [`(CZ ,_ ,_) (if (> ctrl-depth 0) ctrl-depth 0)]
    [`(CCZ ,_ ,_ ,_) (scale-ctrl 1)]
    [`(PhaseFlip ,_) 0]
    [`(Compute-AND ,_ ,_ ,_) (scale-ctrl 1)]
    [`(X-Meas ,_ ,_) 0]
    [`(CZ-if-meas ,_ ,_ ,_) 0]
    [`(MBU-Uncompute-AND ,_ ,_ ,_ ,_) 0] ;; Gidney MBU uncomputation costs ZERO Toffolis!
    [`(X-if-meas ,_ ,_) 0]
    [`(CNOT-if-meas ,_ ,_ ,_) 0]
    [`(CSWAP-if-meas ,_ ,_ ,_ ,_) 1]
    [`(Cuccaro-ADD ,n ,_ ,_ ,_)
     (if (= ctrl-depth 0)
         (max 0 (sub1 (* 2 n)))
         (* 2 (max 0 (sub1 (* 2 n)))))]
    [`(Cuccaro-SUB ,n ,_ ,_ ,_)
     (if (= ctrl-depth 0)
         (max 0 (sub1 (* 2 n)))
         (* 2 (max 0 (sub1 (* 2 n)))))]
    [`(Gidney-ADD ,n ,_ ,_ ,_)
     ;; Gidney (2018) logical-AND + MBU adder uses exactly n-1 Toffolis!
     (if (= ctrl-depth 0)
         (max 0 (sub1 n))
         (+ (max 0 (sub1 n)) n))]
    [`(Gidney-SUB ,n ,_ ,_ ,_)
     (if (= ctrl-depth 0)
         (max 0 (sub1 n))
         (+ (max 0 (sub1 n)) n))]
    [`(Schoolbook-MADD ,n ,_ ,_ ,_ ,_)
     ;; Uncontrolled schoolbook MADD: n^2 ANDs + n ripple additions
     (if (= ctrl-depth 0)
         (quotient (- (+ (* 3 n n) (* 17 n)) 2) 2)
         (- (+ (* 3 n n) (* 17 n)) 2))]
    [`(seq ,cs ...)
     (for/sum ([sub (in-list cs)])
       (circuit-toffoli-cost sub ctrl-depth))]
    [`(adjoint ,inner)
     (circuit-toffoli-cost inner ctrl-depth)]
    [`(ctrl ,_ ,inner)
     (circuit-toffoli-cost inner (add1 ctrl-depth))]
    [`(with-ancilla ,_ ,inner)
     (circuit-toffoli-cost inner ctrl-depth)]
    [`(free-ancilla ,_ ,inner)
     (circuit-toffoli-cost inner ctrl-depth)]
    [`(routed-branch ,_ ,pairs ,inner)
     ;; Each CSWAP pair costs 1 Toffoli on entry and 1 Toffoli on exit
     (+ (* 2 (length pairs))
        (circuit-toffoli-cost inner ctrl-depth))]
    [`(uncompute-with-decoder ,_ ,_ ,decoder ,inv-step)
     (+ (circuit-toffoli-cost decoder ctrl-depth)
        (circuit-toffoli-cost inv-step ctrl-depth))]
    [_ 0]))

(define (circuit-ancilla-peak c)
  (match c
    [`(with-ancilla ,qs ,inner)
     (+ (length qs) (circuit-ancilla-peak inner))]
    [`(seq ,cs ...)
     (apply max 0 (map circuit-ancilla-peak cs))]
    [`(adjoint ,inner) (circuit-ancilla-peak inner)]
    [`(ctrl ,_ ,inner) (circuit-ancilla-peak inner)]
    [`(routed-branch ,_ ,_ ,inner) (circuit-ancilla-peak inner)]
    [`(uncompute-with-decoder ,_ ,_ ,dec ,inv)
     (max (circuit-ancilla-peak dec) (circuit-ancilla-peak inv))]
    [_ 0]))

;; =============================================================================
;; Rule 4 of Kickmix Coherence (arXiv:2610.22367 Eq. 14-15):
;; Classical measurement outcomes m may ONLY control diagonal phase corrections
;; (CZ-if-meas), NEVER basis-permuting gates (X, CNOT, CSWAP, Toffoli).
;; =============================================================================
(define (validate-classical-control-discipline c)
  (match c
    [`(X-if-meas ,m ,q)
     (list (format "VIOLATION (Kickmix Rule 4): measurement bit ~a controls basis gate (X ~a)" m q))]
    [`(CNOT-if-meas ,m ,c1 ,t)
     (list (format "VIOLATION (Kickmix Rule 4): measurement bit ~a controls basis gate (CNOT ~a ~a)" m c1 t))]
    [`(CSWAP-if-meas ,m ,c1 ,a ,b)
     (list (format "VIOLATION (Kickmix Rule 4): measurement bit ~a controls basis gate (CSWAP ~a ~a ~a)" m c1 a b))]
    [`(seq ,cs ...)
     (append-map validate-classical-control-discipline cs)]
    [`(adjoint ,inner)
     (validate-classical-control-discipline inner)]
    [`(ctrl ,_ ,inner)
     (validate-classical-control-discipline inner)]
    [`(with-ancilla ,_ ,inner)
     (validate-classical-control-discipline inner)]
    [`(free-ancilla ,_ ,inner)
     (validate-classical-control-discipline inner)]
    [`(routed-branch ,_ ,_ ,inner)
     (validate-classical-control-discipline inner)]
    [`(uncompute-with-decoder ,_ ,_ ,dec ,inv)
     (append (validate-classical-control-discipline dec)
             (validate-classical-control-discipline inv))]
    [_ '()]))
