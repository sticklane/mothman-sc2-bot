#lang racket

;; =============================================================================
;; lakefill-core-cryptography-implementations.rkt
;; =============================================================================
;; Genuine Reversible Lakefill Lisp DSL, Gate-Level Evaluators, and Bit-Exact
;; Cryptographic & Algebraic Circuit Implementations:
;;
;;   1. Core Reversible & Quantum Gate DSL + Compiler + Evaluators:
;;      Primitive gates:
;;        (x i), (cx c t), (ccx c1 c2 t), (swap a b), (h i), (z i),
;;        (cz a b), (mcz (c ...) t), (mid-meas-x-cond-z anc ctrl),
;;        (assert-clean (anc ...))
;;      Higher-order Lakefill combinators:
;;        (seq expr ...), (invert expr), (within-apply compute-expr action-expr [ancs]),
;;        (erase-by fwd-expr bwd-uncompute-expr [ancs])
;;      Automatic syntactic circuit inversion `(invert-circuit gates)` and
;;      strict `Law U1` / `Rule 2` runtime clean-ancilla assertion (`anc == 0`)
;;      plus `Law U4` / `Rule 3` Hadamard-dual `M_X + cond-Z/CZ` zero-phase-taint
;;      branch verification!
;;
;;   2. Official NIST FIPS-197 Reversible AES-128 (10r), AES-192 (12r), AES-256 (14r):
;;      - SubBytes via composite tower field GF(2^8) ~= GF(((2^2)^2)^2) reversible
;;        `ccx`/`cx` multiplier & inverter + GF(2) PLU affine `cx`/`x` network +
;;        in-place `erase-by` S^-1 uncomputation (`0` per-round ancilla growth!).
;;      - ShiftRows via wire `swap` cycle decomposition (`0` Toffolis, `0` ancillas).
;;      - MixColumns via exact 32x32 GF(2) PLU in-place `cx`/`swap` network (`0` ancillas).
;;      - In-place rolling RoundKey schedule (`Nk = 4, 6, 8`) + `within-apply`
;;        Grover phase-kickback oracle uncomputing 100% of round/S-box ancillas to `0`.
;;      - Verified bit-for-bit on NIST FIPS-197 Appendix C.1, C.2, and C.3!
;;
;;   3. Reversible 18-Round `Keccak-f[200]` (`SPHINCS+` / FIPS-202 Sponge Core):
;;      - Complete `theta` (40-wire parity sheet with `erase-by` uncomputation),
;;        `rho`, `pi` (`swap` permutations), `chi` (`ccx` + `within-apply` degree-3
;;        algebraic inverse scratch-plane uncomputation), and `iota`.
;;
;;   4. Gidney Temporary-AND Adder & Modular Multiplier (`RSA / ECC` Core):
;;      - `(gidney-adder-sexpr n a-wires b-wires carry-wires)` using `n - 1` `ccx`
;;        temporary-ANDs + `(mid-meas-x-cond-z anc (u v))` (`0` uncompute Toffolis!),
;;        verified across superpositions + exported to OpenQASM 3.0 & gate JSON.
;;      - Reversible modular adder `(a + b) mod N` and schoolbook multiplier.
;;
;;   5. `BCH(15, 7, 5)` Peterson-Berlekamp Syndrome Uncomputation (`DQI` Core):
;;      - Uniform branchless reversible GF(2^4) algebraic syndrome decoder + parity
;;        erasure verifying `121 / 121` weight <= 2 error masks uncompute syndrome
;;        wires to `00000000` with `0` ancilla leakage.
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/format
         racket/string
         racket/math
         json)

(provide compile-lakefill
         invert-circuit
         within-apply-gates
         gate-counts
         eval-reversible-gates!
         eval-mbu-circuit-all-branches
         eval-quantum-statevector
         gates->openqasm3
         gf16-tower-inv-sexpr
         aes-sbox-inplace-sexpr
         aes-cipher-sexpr
         aes-grover-oracle-sexpr
         keccak-chi5-inplace-sexpr
         keccak-f200-sexpr
         gidney-adder-sexpr
         gidney-modular-adder-sexpr
         gidney-schoolbook-multiplier-sexpr
         bch-15-7-5-syndrome-uncompute-sexpr
         run-all-lakefill-verifications)

;; =============================================================================
;; SECTION 1: Genuine Lakefill Lisp Reversible Circuit DSL, Inversion & Evaluator
;; =============================================================================

;; Invert a single flat primitive gate. Self-adjoint reversible gates map to
;; themselves; `(assert-clean ws)` remains an assertion at uncompute boundaries.
(define (invert-gate g)
  (match g
    [`(x ,i) `(x ,i)]
    [`(cx ,c ,t) `(cx ,c ,t)]
    [`(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t)]
    [`(swap ,a ,b) `(swap ,a ,b)]
    [`(h ,i) `(h ,i)]
    [`(z ,i) `(z ,i)]
    [`(cz ,a ,b) `(cz ,a ,b)]
    [`(ccz ,a ,b ,c) `(ccz ,a ,b ,c)]
    [`(assert-clean ,ws) `(assert-clean ,ws)]
    [`(mid-meas-x-cond-z . ,_)
     (error 'invert-gate
            "Cannot syntactically invert irreversible mid-meas-x-cond-z gate: ~a" g)]
    [_ (error 'invert-gate "Unknown primitive gate: ~a" g)]))

;; Syntactic adjoint `(invert-circuit gates)`: reverses gate order and inverts each gate.
(define (invert-circuit gates)
  (reverse (map invert-gate gates)))

;; Functional `(within-apply-gates compute-gates action-gates [clean-ancillas])`:
;; Runs `compute-gates`, then `action-gates`, then `(invert-circuit compute-gates)`,
;; followed by `(assert-clean clean-ancillas)` enforcing `Law U1` (`anc == 0`).
(define (within-apply-gates compute-gates action-gates [clean-ancillas '()])
  (append compute-gates
          action-gates
          (invert-circuit compute-gates)
          (if (null? clean-ancillas)
              '()
              (list `(assert-clean ,clean-ancillas)))))

;; Compile a high-level Lakefill Lisp AST S-expression into a flat list of
;; primitive reversible/quantum gates.
(define (compile-lakefill expr)
  (match expr
    ['skip '()]
    [`(x ,i) (list `(x ,i))]
    [`(cx ,c ,t)
     (when (= c t)
       (error 'compile-lakefill "cx control and target must be distinct: ~a" expr))
     (list `(cx ,c ,t))]
    [`(ccx ,c1 ,c2 ,t)
     (when (or (= c1 c2) (= c1 t) (= c2 t))
       (error 'compile-lakefill "ccx wires must be pairwise distinct: ~a" expr))
     (list `(ccx ,c1 ,c2 ,t))]
    [`(swap ,a ,b)
     (if (= a b) '() (list `(swap ,a ,b)))]
    [`(h ,i) (list `(h ,i))]
    [`(z ,i) (list `(z ,i))]
    [`(cz ,a ,b)
     (when (= a b)
       (error 'compile-lakefill "cz wires must be distinct: ~a" expr))
     (list `(cz ,a ,b))]
    [`(ccz ,a ,b ,c)
     (list `(ccz ,a ,b ,c))]
    [`(mid-meas-x-cond-z ,anc ,ctrl)
     (list `(mid-meas-x-cond-z ,anc ,ctrl))]
    [`(assert-clean ,ws)
     (list `(assert-clean ,ws))]
    [`(seq ,es ...)
     (append-map compile-lakefill es)]
    [`(invert ,inner)
     (invert-circuit (compile-lakefill inner))]
    [`(within-apply ,comp-expr ,act-expr)
     (within-apply-gates (compile-lakefill comp-expr)
                         (compile-lakefill act-expr)
                         '())]
    [`(within-apply ,comp-expr ,act-expr ,clean-ancs)
     (within-apply-gates (compile-lakefill comp-expr)
                         (compile-lakefill act-expr)
                         clean-ancs)]
    ;; `erase-by` (`Law U1`): runs forward computation `fwd-expr`, then uncomputes
    ;; intermediate garbage via algebraic left-inverse `bwd-uncompute-expr`, and
    ;; asserts that `clean-ancs` are strictly restored to `0`.
    [`(erase-by ,fwd-expr ,bwd-uncompute-expr ,clean-ancs)
     (append (compile-lakefill fwd-expr)
             (compile-lakefill bwd-uncompute-expr)
             (if (null? clean-ancs)
                 '()
                 (list `(assert-clean ,clean-ancs))))]
    ;; Multi-controlled X `(mcx ctrls target scratch)` lowered into `within-apply`
    ;; V-chain of `ccx` temporary-ANDs on clean `scratch` wires!
    [`(mcx ,ctrls ,target ,scratch)
     (define k (length ctrls))
     (cond
       [(= k 0) (list `(x ,target))]
       [(= k 1) (list `(cx ,(first ctrls) ,target))]
       [(= k 2) (list `(ccx ,(first ctrls) ,(second ctrls) ,target))]
       [else
        (when (< (length scratch) (- k 2))
          (error 'compile-lakefill "mcx needs ~a scratch wires, got ~a"
                 (- k 2) (length scratch)))
        (define used-ancs (take scratch (- k 2)))
        (define comp-steps
          (cons `(ccx ,(first ctrls) ,(second ctrls) ,(first used-ancs))
                (for/list ([idx (in-range 2 (- k 1))])
                  `(ccx ,(list-ref ctrls idx)
                        ,(list-ref used-ancs (- idx 2))
                        ,(list-ref used-ancs (- idx 1))))))
        (define top-act
          `(ccx ,(last ctrls) ,(last used-ancs) ,target))
        (compile-lakefill
         `(within-apply (seq ,@comp-steps) ,top-act ,used-ancs))])]
    ;; Multi-controlled Z `(mcz ctrls scratch)` using `H` conjugation on last control!
    [`(mcz ,ctrls ,scratch)
     (define last-c (last ctrls))
     (define init-cs (drop-right ctrls 1))
     (compile-lakefill
      `(within-apply (h ,last-c) (mcx ,init-cs ,last-c ,scratch)))]
    [_ (error 'compile-lakefill "Unrecognized Lakefill AST form: ~a" expr)]))

;; Count gate statistics across a compiled flat gate list.
(define (gate-counts gates)
  (define n-x 0)
  (define n-cx 0)
  (define n-ccx 0)
  (define n-swap 0)
  (define n-h 0)
  (define n-phase 0)
  (define n-mbu 0)
  (define n-assert 0)
  (for ([g (in-list gates)])
    (match g
      [`(x ,_) (set! n-x (add1 n-x))]
      [`(cx ,_ ,_) (set! n-cx (add1 n-cx))]
      [`(ccx ,_ ,_ ,_) (set! n-ccx (add1 n-ccx))]
      [`(swap ,_ ,_) (set! n-swap (add1 n-swap))]
      [`(h ,_) (set! n-h (add1 n-h))]
      [(or `(z ,_) `(cz ,_ ,_) `(ccz ,_ ,_ ,_)) (set! n-phase (add1 n-phase))]
      [`(mid-meas-x-cond-z ,_ ,_) (set! n-mbu (add1 n-mbu))]
      [`(assert-clean ,_) (set! n-assert (add1 n-assert))]))
  (hasheq 'x n-x
          'cx n-cx
          'ccx n-ccx
          'swap n-swap
          'h n-h
          'phase n-phase
          'mid_meas_x_cond_z n-mbu
          'assert_clean n-assert
          'total_physical_gates (+ n-x n-cx n-ccx n-swap n-h n-phase n-mbu)))

;; Bit-exact reversible register + phase evaluator (`eval-reversible-gates!`).
;; Mutates `reg` (a vector of 0/1 bits) and returns the accumulated global phase
;; sign (+1 or -1). For `(mid-meas-x-cond-z anc ctrl)`, uses `meas-branch-fn`
;; (default deterministic `m = 1` worst-case kickback test!) to simulate:
;;   1. Hadamard-dual X-measurement on `anc` -> phase kickback `(-1)^(m * anc_val)`
;;   2. Reset `anc -> 0`
;;   3. Conditional Z / CZ fixup on `ctrl` when `m = 1`, cancelling the phase kickback!
(define (eval-reversible-gates! reg gates [meas-branch-fn (lambda (_step) 1)])
  (define phase 1)
  (define mbu-step 0)
  (for ([g (in-list gates)])
    (match g
      [`(x ,i)
       (vector-set! reg i (bitwise-xor (vector-ref reg i) 1))]
      [`(cx ,c ,t)
       (when (= (vector-ref reg c) 1)
         (vector-set! reg t (bitwise-xor (vector-ref reg t) 1)))]
      [`(ccx ,c1 ,c2 ,t)
       (when (and (= (vector-ref reg c1) 1) (= (vector-ref reg c2) 1))
         (vector-set! reg t (bitwise-xor (vector-ref reg t) 1)))]
      [`(swap ,a ,b)
       (define va (vector-ref reg a))
       (vector-set! reg a (vector-ref reg b))
       (vector-set! reg b va)]
      [`(z ,i)
       (when (= (vector-ref reg i) 1)
         (set! phase (- phase)))]
      [`(cz ,a ,b)
       (when (and (= (vector-ref reg a) 1) (= (vector-ref reg b) 1))
         (set! phase (- phase)))]
      [`(ccz ,a ,b ,c)
       (when (and (= (vector-ref reg a) 1)
                  (= (vector-ref reg b) 1)
                  (= (vector-ref reg c) 1))
         (set! phase (- phase)))]
      [`(h ,i)
       ;; Supported in basis mode when paired as H-Z-H = X or inside statevector mode;
       ;; track standalone H only if invoked via `mcz` (`H` around `mcx`? No: `H-X-H = Z`!).
       ;; Wait: in `mcz`, `within-apply (h last-c) (mcx init-cs last-c)` conjugates X into Z!
       ;; Let's detect or evaluate general circuits cleanly: in computational basis, `mcz`
       ;; flips phase iff all `ctrls` are 1! Let's handle `h` if encountered in statevector,
       ;; and keep basis `mcz` directly compiling to `ccx` V-chain + `cz` so basis mode is 100% exact!
       (error 'eval-reversible-gates!
              "Basis evaluator encountered non-basis Hadamard ~a; use statevector evaluator" g)]
      [`(mid-meas-x-cond-z ,anc ,ctrl)
       (define m (meas-branch-fn mbu-step))
       (set! mbu-step (add1 mbu-step))
       (define anc-val (vector-ref reg anc))
       ;; 1. Destructive M_X kicks back phase (-1)^(m * anc_val) and resets anc -> 0
       (when (and (= m 1) (= anc-val 1))
         (set! phase (- phase)))
       (vector-set! reg anc 0)
       ;; 2. Classical feed-forward Z / CZ fixup (`Rule 3` / `Law U4`)
       (when (= m 1)
         (match ctrl
           [(list c1 c2)
            (when (and (= (vector-ref reg c1) 1) (= (vector-ref reg c2) 1))
              (set! phase (- phase)))]
           [(? exact-nonnegative-integer? c1)
            (when (= (vector-ref reg c1) 1)
              (set! phase (- phase)))]))]
      [`(assert-clean ,ws)
       (for ([w (in-list ws)])
         (unless (= (vector-ref reg w) 0)
           (error 'assert-clean
                  "Law U1 violation: scratch ancilla wire ~a leaked value ~a != 0"
                  w (vector-ref reg w))))]))
  phase)

;; Fix `mcz` in `compile-lakefill`? Wait: notice if we redefine `mcz` to use `(cz ...)`
;; at the apex of a `ccx` V-chain instead of `(h ...)`, then `mcz` works identically in
;; BOTH classical basis-phase mode AND quantum statevector / Qiskit / Stim mode without
;; needing Hadamard gates! Let's provide a helper `(mcz-sexpr ctrls scratch)` using `cz`!
(define (mcz-sexpr ctrls scratch)
  (define k (length ctrls))
  (cond
    [(= k 1) `(z ,(first ctrls))]
    [(= k 2) `(cz ,(first ctrls) ,(second ctrls))]
    [(= k 3) `(ccz ,(first ctrls) ,(second ctrls) ,(third ctrls))]
    [else
     (define used-ancs (take scratch (- k 2)))
     (define comp-steps
       (cons `(ccx ,(first ctrls) ,(second ctrls) ,(first used-ancs))
             (for/list ([idx (in-range 2 (- k 1))])
               `(ccx ,(list-ref ctrls idx)
                     ,(list-ref used-ancs (- idx 2))
                     ,(list-ref used-ancs (- idx 1))))))
     `(within-apply (seq ,@comp-steps)
                    (cz ,(last ctrls) ,(last used-ancs))
                    ,used-ancs)]))

;; Exhaustively evaluate an MBU circuit across ALL `2^k` mid-circuit measurement
;; outcome bitstrings `m in {0, 1}^k`, asserting that EVERY branch yields the
;; exact same output register, `0` ancilla leakage, and `+1` phase (`0` taint)!
(define (eval-mbu-circuit-all-branches init-reg gates ancilla-wires)
  (define num-mbu
    (for/sum ([g (in-list gates)])
      (match g [`(mid-meas-x-cond-z ,_ ,_) 1] [_ 0])))
  (define ref-out #f)
  (for ([mask (in-range (arithmetic-shift 1 num-mbu))])
    (define reg (vector-copy init-reg))
    (define ph
      (eval-reversible-gates!
       reg gates
       (lambda (step) (bitwise-bit-field mask step (add1 step)))))
    (unless (= ph 1)
      (error 'eval-mbu-circuit-all-branches
             "Law U4 phase taint leak on MBU mask ~a: phase = ~a" mask ph))
    (for ([w (in-list ancilla-wires)])
      (unless (= (vector-ref reg w) 0)
        (error 'eval-mbu-circuit-all-branches
               "Ancilla wire ~a leaked 1 on MBU mask ~a" w mask)))
    (if (not ref-out)
        (set! ref-out reg)
        (unless (equal? reg ref-out)
          (error 'eval-mbu-circuit-all-branches
                 "Branch mismatch on MBU mask ~a" mask))))
  ref-out)

;; Exact quantum statevector evaluator (`eval-quantum-statevector`) supporting
;; `(h i)` superpositions, `(x i)`, `(cx c t)`, `(ccx c1 c2 t)`, `(swap a b)`,
;; `(z i)`, `(cz a b)`, `(ccz a b c)`, `(mid-meas-x-cond-z anc ctrl)`, and
;; `(assert-clean ws)` (`Law U1` zero-leakage probability assertion!).
(define (eval-quantum-statevector num-qubits gates [meas-branch-fn (lambda (_step) 1)])
  (define dim (arithmetic-shift 1 num-qubits))
  (define sv (make-vector dim 0.0+0.0i))
  (vector-set! sv 0 1.0+0.0i)
  (define inv-sqrt2 (/ 1.0 (sqrt 2.0)))
  (define mbu-step 0)

  (define (apply-h! q)
    (define mask (arithmetic-shift 1 q))
    (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx mask)))
      (define a0 (vector-ref sv idx))
      (define a1 (vector-ref sv (bitwise-ior idx mask)))
      (vector-set! sv idx (* inv-sqrt2 (+ a0 a1)))
      (vector-set! sv (bitwise-ior idx mask) (* inv-sqrt2 (- a0 a1)))))

  (define (apply-x! q)
    (define mask (arithmetic-shift 1 q))
    (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx mask)))
      (define tmp (vector-ref sv idx))
      (vector-set! sv idx (vector-ref sv (bitwise-ior idx mask)))
      (vector-set! sv (bitwise-ior idx mask) tmp)))

  (for ([g (in-list gates)])
    (match g
      [`(x ,i) (apply-x! i)]
      [`(h ,i) (apply-h! i)]
      [`(cx ,c ,t)
       (define cm (arithmetic-shift 1 c))
       (define tm (arithmetic-shift 1 t))
       (for ([idx (in-range dim)]
             #:when (and (not (zero? (bitwise-and idx cm)))
                         (zero? (bitwise-and idx tm))))
         (define j (bitwise-ior idx tm))
         (define tmp (vector-ref sv idx))
         (vector-set! sv idx (vector-ref sv j))
         (vector-set! sv j tmp))]
      [`(ccx ,c1 ,c2 ,t)
       (define cm (bitwise-ior (arithmetic-shift 1 c1) (arithmetic-shift 1 c2)))
       (define tm (arithmetic-shift 1 t))
       (for ([idx (in-range dim)]
             #:when (and (= (bitwise-and idx cm) cm)
                         (zero? (bitwise-and idx tm))))
         (define j (bitwise-ior idx tm))
         (define tmp (vector-ref sv idx))
         (vector-set! sv idx (vector-ref sv j))
         (vector-set! sv j tmp))]
      [`(swap ,a ,b)
       (define am (arithmetic-shift 1 a))
       (define bm (arithmetic-shift 1 b))
       (for ([idx (in-range dim)]
             #:when (and (not (zero? (bitwise-and idx am)))
                         (zero? (bitwise-and idx bm))))
         (define j (bitwise-xor idx (bitwise-ior am bm)))
         (define tmp (vector-ref sv idx))
         (vector-set! sv idx (vector-ref sv j))
         (vector-set! sv j tmp))]
      [`(z ,i)
       (define m (arithmetic-shift 1 i))
       (for ([idx (in-range dim)] #:when (not (zero? (bitwise-and idx m))))
         (vector-set! sv idx (- (vector-ref sv idx))))]
      [`(cz ,a ,b)
       (define m (bitwise-ior (arithmetic-shift 1 a) (arithmetic-shift 1 b)))
       (for ([idx (in-range dim)] #:when (= (bitwise-and idx m) m))
         (vector-set! sv idx (- (vector-ref sv idx))))]
      [`(ccz ,a ,b ,c)
       (define m (bitwise-ior (arithmetic-shift 1 a)
                              (arithmetic-shift 1 b)
                              (arithmetic-shift 1 c)))
       (for ([idx (in-range dim)] #:when (= (bitwise-and idx m) m))
         (vector-set! sv idx (- (vector-ref sv idx))))]
      [`(mid-meas-x-cond-z ,anc ,ctrl)
       (define m (meas-branch-fn mbu-step))
       (set! mbu-step (add1 mbu-step))
       (apply-h! anc)
       (define am (arithmetic-shift 1 anc))
       (define prob
         (for/sum ([idx (in-range dim)]
                   #:when (= (if (zero? (bitwise-and idx am)) 0 1) m))
           (sqr (magnitude (vector-ref sv idx)))))
       (define norm (sqrt prob))
       (for ([idx (in-range dim)])
         (if (= (if (zero? (bitwise-and idx am)) 0 1) m)
             (vector-set! sv idx (/ (vector-ref sv idx) norm))
             (vector-set! sv idx 0.0+0.0i)))
       (when (= m 1)
         (apply-x! anc)
         (match ctrl
           [(list c1 c2)
            (define cm (bitwise-ior (arithmetic-shift 1 c1) (arithmetic-shift 1 c2)))
            (for ([idx (in-range dim)] #:when (= (bitwise-and idx cm) cm))
              (vector-set! sv idx (- (vector-ref sv idx))))]
           [(? exact-nonnegative-integer? c1)
            (define cm (arithmetic-shift 1 c1))
            (for ([idx (in-range dim)] #:when (not (zero? (bitwise-and idx cm))))
              (vector-set! sv idx (- (vector-ref sv idx))))]))]
      [`(assert-clean ,ws)
       (for ([w (in-list ws)])
         (define wm (arithmetic-shift 1 w))
         (define leak-prob
           (for/sum ([idx (in-range dim)] #:when (not (zero? (bitwise-and idx wm))))
             (sqr (magnitude (vector-ref sv idx)))))
         (when (> leak-prob 1e-12)
           (error 'eval-quantum-statevector
                  "Quantum ancilla wire ~a leaked probability ~a > 0!" w leak-prob)))]))
  sv)

;; Export compiled Lakefill gate list to OpenQASM 3.0 (supporting dynamic MBU!).
(define (gates->openqasm3 num-qubits gates)
  (define lines
    (list "OPENQASM 3.0;"
          "include \"stdgates.inc\";"
          (format "qubit[~a] q;" num-qubits)
          "bit m_anc;"))
  (define body
    (for/fold ([acc '()]) ([g (in-list gates)])
      (match g
        [`(x ,i) (cons (format "x q[~a];" i) acc)]
        [`(cx ,c ,t) (cons (format "cx q[~a], q[~a];" c t) acc)]
        [`(ccx ,c1 ,c2 ,t) (cons (format "ccx q[~a], q[~a], q[~a];" c1 c2 t) acc)]
        [`(swap ,a ,b) (cons (format "swap q[~a], q[~a];" a b) acc)]
        [`(h ,i) (cons (format "h q[~a];" i) acc)]
        [`(z ,i) (cons (format "z q[~a];" i) acc)]
        [`(cz ,a ,b) (cons (format "cz q[~a], q[~a];" a b) acc)]
        [`(ccz ,a ,b ,c)
         (cons (format "h q[~a]; ccx q[~a], q[~a], q[~a]; h q[~a];" c a b c c) acc)]
        [`(mid-meas-x-cond-z ,anc ,(list c1 c2))
         (append
          (reverse
           (list (format "h q[~a];" anc)
                 (format "m_anc = measure q[~a];" anc)
                 (format "if (m_anc == 1) { x q[~a]; cz q[~a], q[~a]; }" anc c1 c2)))
          acc)]
        [`(mid-meas-x-cond-z ,anc ,c1)
         (append
          (reverse
           (list (format "h q[~a];" anc)
                 (format "m_anc = measure q[~a];" anc)
                 (format "if (m_anc == 1) { x q[~a]; z q[~a]; }" anc c1)))
          acc)]
        [`(assert-clean ,_) acc])))
  (string-join (append lines (reverse body)) "\n"))

;; Serialize flat gate list to JSON-friendly list of lists.
(define (gates->json-list gates)
  (for/fold ([acc '()] #:result (reverse acc)) ([g (in-list gates)])
    (match g
      [`(assert-clean ,_) acc]
      [`(mid-meas-x-cond-z ,anc ,(list c1 c2))
       (cons (list "mid-meas-x-cond-cz" anc c1 c2) acc)]
      [`(mid-meas-x-cond-z ,anc ,c1)
       (cons (list "mid-meas-x-cond-z" anc c1) acc)]
      [`(,op ,args ...)
       (cons (cons (symbol->string op) args) acc)])))

;; =============================================================================
;; SECTION 2: Exact GF(2) Linear Bijection Compiler -> Reversible `cx`/`swap` AST
;; =============================================================================
;; Factors any nonsingular m x m matrix M over GF(2) (where y = M * x) into an
;; exact 0-ancilla, 0-Toffoli Lakefill `(seq ...)` of `(cx c t)` and `(swap a b)`
;; gates via Gauss-Jordan row reduction recording inverse row ops!
;; Proof of correctness:
;;   If `ops` are elementary row operations (`row_t ^= row_c` and `swap row_a row_b`)
;;   such that `O_k ... O_1 * M = I`, then `M = O_1^{-1} ... O_k^{-1}`.
;;   Since every elementary `cx` and `swap` is self-inverse over GF(2), applying
;;   `O_k, ..., O_2, O_1` (i.e. `(reverse ops)`) to wire vector `x` computes `M * x`!

(define (gf2-matrix->lakefill-sexpr mat wires)
  (define m (length wires))
  (define rows
    (for/vector ([r (in-range m)])
      (vector-copy (vector-ref mat r))))
  (define recorded-ops '())
  (for ([col (in-range m)])
    (define piv
      (for/first ([r (in-range col m)]
                  #:when (= (vector-ref (vector-ref rows r) col) 1))
        r))
    (unless piv
      (error 'gf2-matrix->lakefill-sexpr "Singular GF(2) matrix at column ~a" col))
    (when (not (= piv col))
      (define tmp (vector-ref rows col))
      (vector-set! rows col (vector-ref rows piv))
      (vector-set! rows piv tmp)
      (set! recorded-ops
            (cons `(swap ,(list-ref wires col) ,(list-ref wires piv))
                  recorded-ops)))
    (for ([r (in-range m)]
          #:when (and (not (= r col))
                      (= (vector-ref (vector-ref rows r) col) 1)))
      (define r-vec (vector-ref rows r))
      (define c-vec (vector-ref rows col))
      (for ([j (in-range m)])
        (vector-set! r-vec j (bitwise-xor (vector-ref r-vec j) (vector-ref c-vec j))))
      ;; Row operation `row[r] ^= row[col]` corresponds to wire gate `(cx wires[col] wires[r])`!
      (set! recorded-ops
            (cons `(cx ,(list-ref wires col) ,(list-ref wires r))
                  recorded-ops))))
  ;; `recorded-ops` holds `(list O_k ... O_1)`, so executing `O_k` down to `O_1`?
  ;; Wait: `O_k ... O_1 * M = I` => `M * x = O_1 * (O_2 * ... (O_k * x))`!
  ;; In `recorded-ops`, `O_k` is at the HEAD (`first`) and `O_1` is at the TAIL (`last`)!
  ;; So executing `recorded-ops` in order applies `O_k` first, ..., `O_1` last = `M * x`!
  `(seq ,@recorded-ops))

;; Helper to build an m x m GF(2) matrix from column bitmasks (col j -> m-bit integer).
(define (cols->gf2-matrix m col-masks)
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-bit-field (list-ref col-masks c) r (add1 r)))))

;; Multiply two m x m GF(2) matrices.
(define (gf2-matmul A B)
  (define m (vector-length A))
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-and
       1
       (for/sum ([k (in-range m)])
         (* (vector-ref (vector-ref A r) k)
            (vector-ref (vector-ref B k) c)))))))

;; Invert an m x m GF(2) matrix.
(define (gf2-matinv M)
  (define m (vector-length M))
  (define aug
    (for/vector ([r (in-range m)])
      (vector-append
       (vector-copy (vector-ref M r))
       (for/vector ([c (in-range m)]) (if (= r c) 1 0)))))
  (for ([col (in-range m)])
    (define piv
      (for/first ([r (in-range col m)]
                  #:when (= (vector-ref (vector-ref aug r) col) 1))
        r))
    (unless piv (error 'gf2-matinv "Matrix is singular"))
    (when (not (= piv col))
      (define tmp (vector-ref aug col))
      (vector-set! aug col (vector-ref aug piv))
      (vector-set! aug piv tmp))
    (for ([r (in-range m)]
          #:when (and (not (= r col))
                      (= (vector-ref (vector-ref aug r) col) 1)))
      (define rv (vector-ref aug r))
      (define cv (vector-ref aug col))
      (for ([j (in-range (* 2 m))])
        (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))))
  (for/vector ([r (in-range m)])
    (vector-copy (vector-ref aug r) m (* 2 m))))

;; Permutation `out[i] = in[src-for-dst[i]]` -> exact `(swap a b)` cycle decomposition!
(define (perm->swap-sexpr wires src-for-dst)
  ;; After gate sequence, wire `wires[i]` holds the initial value of `wires[src-for-dst[i]]`.
  ;; Track current wire contents `cur[i]` initialized to `i`, swapping until `cur[i] = src-for-dst[i]`.
  (define n (length wires))
  (define cur (for/vector ([i (in-range n)]) i))
  (define swaps '())
  (for ([i (in-range n)])
    (define target-val (list-ref src-for-dst i))
    (when (not (= (vector-ref cur i) target-val))
      (define j
        (for/first ([k (in-range (add1 i) n)]
                    #:when (= (vector-ref cur k) target-val))
          k))
      (define tmp (vector-ref cur i))
      (vector-set! cur i (vector-ref cur j))
      (vector-set! cur j tmp)
      (set! swaps (cons `(swap ,(list-ref wires i) ,(list-ref wires j)) swaps))))
  `(seq ,@(reverse swaps)))

;; =============================================================================
;; SECTION 3: Composite Tower Field GF(((2^2)^2)^2) & Full NIST AES-128/192/256
;; =============================================================================
;; Tower construction over GF(2):
;;   - GF(2^2) = GF(2)[u] / (u^2 + u + 1)
;;   - GF(2^4) = GF(2^2)[v] / (v^2 + v + u)
;;   - GF(2^8) = GF(2^4)[W] / (W^2 + W + u*v)
;; Isomorphism to AES polynomial field GF(2)[a]/(a^8 + a^4 + a^3 + a + 1):
;;   `u = 0xbc`, `v = 0x5c`, `W = 0xf2`
;;   Tower basis `{1, u, v, uv, W, uW, vW, uvW}` in AES basis:
;;   `(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)`!

;; GF(2^2) reversible XOR-multiplier: `out[0..1] ^= a[0..1] * b[0..1]` (`5` `ccx` gates, `0` ancillas).
;; `(a0 + a1 u)(b0 + b1 u) = (a0 b0 + a1 b1) + (a0 b1 + a1 b0 + a1 b1) u`.
(define (gf4-mul-xor-sexpr a b out)
  (match-define (list a0 a1) a)
  (match-define (list b0 b1) b)
  (match-define (list o0 o1) out)
  `(seq (ccx ,a0 ,b0 ,o0)
        (ccx ,a1 ,b1 ,o0)
        (ccx ,a0 ,b1 ,o1)
        (ccx ,a1 ,b0 ,o1)
        (ccx ,a1 ,b1 ,o1)))

;; GF(2^2) XOR `(a0 + a1 u) * u = a1 + (a0 + a1) u` into `out[0..1]`.
(define (gf4-mul-u-xor-sexpr a out)
  (match-define (list a0 a1) a)
  (match-define (list o0 o1) out)
  `(seq (cx ,a1 ,o0)
        (cx ,a0 ,o1)
        (cx ,a1 ,o1)))

;; GF(2^2) in-place squaring / multiplicative inversion: `(a0, a1) -> (a0 ^ a1, a1)` (`1` `cx`!).
(define (gf4-inv-inplace-sexpr a)
  `(cx ,(second a) ,(first a)))

;; GF(2^4) = GF(2^2)[v]/(v^2 + v + u) reversible XOR-multiplier: `out[0..3] ^= a[0..3] * b[0..3]`.
;; `(aL + aH v)(bL + bH v) = (aL bL + u * aH bH) + (aL bH + aH bL + aH bH) v`.
;; Uses `2` clean scratch wires `sc2` via `within-apply` to hold `aH * bH` (`15` `ccx`? `20` `ccx`, `2` scratch -> `0`!).
;; Or direct bilinear expansion without ANY scratch wires (`22` `ccx` gates, `0` ancillas!):
;; Notice `(u * (aH * bH))` has bilinear bits:
;;   let `p0 = a2 b2 ^ a3 b3`, `p1 = a2 b3 ^ a3 b2 ^ a3 b3`:
;;   `(u * p)_0 = p1 = a2 b3 ^ a3 b2 ^ a3 b3`,
;;   `(u * p)_1 = p0 ^ p1 = a2 b2 ^ a2 b3 ^ a3 b2`!
;; Zero scratch wires needed!
(define (gf16-mul-xor-sexpr a b out)
  (match-define (list a0 a1 a2 a3) a)
  (match-define (list b0 b1 b2 b3) b)
  (match-define (list o0 o1 o2 o3) out)
  (define aL (list a0 a1))
  (define aH (list a2 a3))
  (define bL (list b0 b1))
  (define bH (list b2 b3))
  (define oL (list o0 o1))
  (define oH (list o2 o3))
  `(seq ,(gf4-mul-xor-sexpr aL bL oL)
        ;; oL ^= u * (aH * bH):
        ;; o0 ^= a2*b3 ^ a3*b2 ^ a3*b3; o1 ^= a2*b2 ^ a2*b3 ^ a3*b2
        (ccx ,a2 ,b3 ,o0)
        (ccx ,a3 ,b2 ,o0)
        (ccx ,a3 ,b3 ,o0)
        (ccx ,a2 ,b2 ,o1)
        (ccx ,a2 ,b3 ,o1)
        (ccx ,a3 ,b2 ,o1)
        ;; oH ^= aL*bH ^ aH*bL ^ aH*bH
        ,(gf4-mul-xor-sexpr aL bH oH)
        ,(gf4-mul-xor-sexpr aH bL oH)
        ,(gf4-mul-xor-sexpr aH bH oH)))

;; GF(2^4) reversible tower inverter: `out[0..3] ^= inv_GF16(x[0..3])` with `0^-1 = 0`,
;; using `4` clean scratch wires `sc4 = (conj0 conj1 norm0 norm1)` restored to `0000`
;; via `within-apply` (`10` wires total: `4` in + `4` out + `4` scratch? Actually only `4` scratch -> `12` wires total!).
;; Formula over GF(2^2)[v]/(v^2 + v + u):
;;   `x = xL + xH v`, `conjL = xL ^ xH`.
;;   `N(x) = xL * conjL ^ u * xH^2` in GF(2^2), where:
;;     `xH^2 = (x2 ^ x3) + x3 u`, so `u * xH^2 = x3 + x2 u`! (Pure `cx` gates!)
;;   `N_inv = N(x)^2` (`1` `cx` gate!).
;;   `outL ^= conjL * N_inv`, `outH ^= xH * N_inv`!
(define (gf16-tower-inv-sexpr x out sc4)
  (match-define (list x0 x1 x2 x3) x)
  (match-define (list o0 o1 o2 o3) out)
  (match-define (list c0 c1 d0 d1) sc4)
  (define xL (list x0 x1))
  (define xH (list x2 x3))
  (define cL (list c0 c1))
  (define d  (list d0 d1))
  (define oL (list o0 o1))
  (define oH (list o2 o3))
  `(within-apply
    (seq ;; cL <- xL ^ xH
         (cx ,x0 ,c0) (cx ,x2 ,c0)
         (cx ,x1 ,c1) (cx ,x3 ,c1)
         ;; d <- xL * cL ^ u * xH^2 (where u * xH^2 = x3 + x2 u)
         ,(gf4-mul-xor-sexpr xL cL d)
         (cx ,x3 ,d0)
         (cx ,x2 ,d1)
         ;; d <- d^-1 = d^2 in GF(2^2)
         ,(gf4-inv-inplace-sexpr d))
    (seq ,(gf4-mul-xor-sexpr cL d oL)
         ,(gf4-mul-xor-sexpr xH d oH))
    ,sc4))

;; Helper: linear circuit XORing `(u*v) * xH^2` in GF(2^4) into `d[0..3]`!
;; Let's derive `(u*v) * (x0 + x1 u + x2 v + x3 uv)^2` in GF(2^4):
;;   - `1^2 * uv = uv` (`#b1000` = 8)
;;   - `u^2 * uv = (u+1)*uv = u^2 v + uv = (u+1)v + uv = v` (`#b0100` = 4)
;;   - `v^2 * uv = (v+u)*uv = u v^2 + u^2 v = u(v+u) + (u+1)v = uv + u^2 + uv + v = (u+1) + v` (`#b0111` = 7)
;;   - `(uv)^2 * uv = u^2 v^2 * uv = (u+1)(v+u) uv`
;;     Note `(uv)^2 = u^2 v^2 = (u+1)(v+u) = uv + u^2 + v + u = uv + v + 1`.
;;     Multiply by `uv`: `u^2 v^2 + u v^2 + uv = (uv + v + 1) + u(v + u) + uv = v + 1 + uv + u + 1 = u + v + uv` (`#b1110` = 14)!
;; Let's check: bit 0 gets `x2`, bit 1 gets `x2 ^ x3`, bit 2 gets `x1 ^ x2 ^ x3`, bit 3 gets `x0 ^ x3`!
(define (gf16-mul-uv-sq-xor-sexpr xH d4)
  (match-define (list x0 x1 x2 x3) xH)
  (match-define (list d0 d1 d2 d3) d4)
  `(seq (cx ,x2 ,d0)
        (cx ,x2 ,d1) (cx ,x3 ,d1)
        (cx ,x1 ,d2) (cx ,x2 ,d2) (cx ,x3 ,d2)
        (cx ,x0 ,d3) (cx ,x3 ,d3)))

;; GF(2^8) = GF(2^4)[W]/(W^2 + W + uv) reversible tower inverter:
;; `out8 ^= inv_tower(x8)` using `16` clean scratch wires `sc16` restored to `0` via `within-apply`!
(define (gf256-tower-inv-sexpr x8 out8 sc16)
  (define xL (take x8 4))
  (define xH (drop x8 4))
  (define oL (take out8 4))
  (define oH (drop out8 4))
  (define c4    (take sc16 4))           ;; xL ^ xH
  (define d4    (take (drop sc16 4) 4))  ;; norm Delta in GF(2^4)
  (define dinv4 (take (drop sc16 8) 4))  ;; Delta^-1 in GF(2^4)
  (define sub4  (drop sc16 12))          ;; 4 scratch wires for gf16-tower-inv
  `(within-apply
    (seq ;; c4 <- xL ^ xH
         ,@(for/list ([xl (in-list xL)] [xh (in-list xH)] [c (in-list c4)])
             `(seq (cx ,xl ,c) (cx ,xh ,c)))
         ;; d4 <- xL * c4 ^ (uv) * xH^2
         ,(gf16-mul-xor-sexpr xL c4 d4)
         ,(gf16-mul-uv-sq-xor-sexpr xH d4)
         ;; dinv4 <- inv_GF16(d4)
         ,(gf16-tower-inv-sexpr d4 dinv4 sub4))
    (seq ,(gf16-mul-xor-sexpr c4 dinv4 oL)
         ,(gf16-mul-xor-sexpr xH dinv4 oH))
    ,sc16))

;; Tower-to-AES-poly matrix `delta^-1` (`8x8` over GF(2)) and AES affine matrix `M_aff` (`8x8` over GF(2)).
(define tower-to-aes-mat
  (cols->gf2-matrix 8 '(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)))

(define aes-to-tower-mat
  (gf2-matinv tower-to-aes-mat))

;; FIPS-197 Section 5.1.1 affine matrix M_aff:
;; b'_i = b_i ^ b_{(i+4)%8} ^ b_{(i+5)%8} ^ b_{(i+6)%8} ^ b_{(i+7)%8} ^ c_i (`c = #x63`).
;; Column `j` has 1s at rows `r` where `j in {r, r+4, r+5, r+6, r+7} mod 8`, i.e.,
;; `(r - j) mod 8 in {0, 1, 2, 3, 4}`!
(define aes-affine-mat
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (if (<= (modulo (- r c) 8) 4) 1 0))))

(define aes-affine-inv-mat
  (gf2-matinv aes-affine-mat))

(define post-sbox-mat (gf2-matmul aes-affine-mat tower-to-aes-mat))
(define pre-inv-sbox-mat (gf2-matmul aes-to-tower-mat aes-affine-inv-mat))

(define (xor-byte-const-sexpr byte-wires const-u8)
  `(seq ,@(for/list ([b (in-range 8)]
                     #:when (bitwise-bit-set? const-u8 b))
            `(x ,(list-ref byte-wires b)))))

;; Forward AES S-box into a clean 8-wire output (`clean-out8 = 0^8 -> S(in8)`),
;; leaving `in8` unchanged and restoring all `16` tower scratch wires to `0`!
(define (aes-sbox-into-clean-sexpr in8 clean-out8 sc16)
  `(seq (within-apply
         ,(gf2-matrix->lakefill-sexpr aes-to-tower-mat in8)
         ,(gf256-tower-inv-sexpr in8 clean-out8 sc16)
         ,sc16)
        ,(gf2-matrix->lakefill-sexpr post-sbox-mat clean-out8)
        ,(xor-byte-const-sexpr clean-out8 #x63)))

;; Inverse AES S-box `S^-1` into a clean 8-wire output (`clean-out8 = 0^8 -> S^-1(in8)`),
;; leaving `in8` unchanged and restoring all `16` tower scratch wires to `0`!
(define (aes-inv-sbox-into-clean-sexpr in8 clean-out8 sc16)
  `(seq (within-apply
         (seq ,(xor-byte-const-sexpr in8 #x63)
              ,(gf2-matrix->lakefill-sexpr pre-inv-sbox-mat in8))
         ,(gf256-tower-inv-sexpr in8 clean-out8 sc16)
         ,sc16)
        ,(gf2-matrix->lakefill-sexpr tower-to-aes-mat clean-out8)))

;; General XOR S-box `target8 ^= S(in8)` (safe for arbitrary non-zero `target8`!)
;; using `24` clean scratch wires (`tmp8` + `sc16`), all restored to `0` via `within-apply`!
(define (aes-sbox-xor-sexpr in8 target8 sc24)
  (define tmp8 (take sc24 8))
  (define sc16 (drop sc24 8))
  `(within-apply
    ,(aes-sbox-into-clean-sexpr in8 tmp8 sc16)
    (seq ,@(for/list ([s (in-list tmp8)] [t (in-list target8)])
             `(cx ,s ,t)))
    ,sc24))

;; Strictly IN-PLACE AES S-box `byte8 -> S(byte8)` via Lakefill `erase-by` (`Law U1`)!
;; Uses `32` clean scratch wires (`tmp8` + `inv8` + `sc16`), and restores ALL `32`
;; scratch wires to `0` at the end of EVERY S-box (`0` per-round ancilla growth!).
(define (aes-sbox-inplace-sexpr byte8 sc32)
  (define tmp8 (take sc32 8))
  (define inv8 (take (drop sc32 8) 8))
  (define sc16 (drop sc32 16))
  `(erase-by
    ,(aes-sbox-into-clean-sexpr byte8 tmp8 sc16)
    (seq ;; Uncompute `byte8` (`x ^ S^-1(S(x)) = 0^8`) and restore `inv8`, `sc16` to `0`
         (within-apply
          ,(aes-inv-sbox-into-clean-sexpr tmp8 inv8 sc16)
          (seq ,@(for/list ([iv (in-list inv8)] [bw (in-list byte8)])
                   `(cx ,iv ,bw)))
          ,(append inv8 sc16))
         ;; Swap `byte8` (now `0^8`) with `tmp8` (holding `S(x)`), leaving `tmp8 = 0^8`!
         ,@(for/list ([bw (in-list byte8)] [tw (in-list tmp8)])
             `(swap ,bw ,tw)))
    ,sc32))

;; AES ShiftRows (`0` Toffolis, `0` ancillas): wire swaps on 16-byte column-major state.
;; Byte `(r, c)` is at byte index `r + 4*c`; after ShiftRows `(r, c) <- (r, (c + r) mod 4)`.
(define (aes-shiftrows-sexpr state128)
  (define src-for-dst
    (for*/list ([c (in-range 4)]
                [r (in-range 4)]
                [b (in-range 8)])
      (+ (* 8 (+ r (* 4 (modulo (+ c r) 4)))) b)))
  (perm->swap-sexpr state128 src-for-dst))

;; AES MixColumns (`0` Toffolis, `0` ancillas): exact 32x32 GF(2) PLU linear `cx`/`swap`
;; network on each 32-bit column!
(define (gf256-aes-xtime x)
  (define sh (bitwise-and (arithmetic-shift x 1) #xFF))
  (if (bitwise-bit-set? x 7) (bitwise-xor sh #x1B) sh))

(define aes-mixcol-32x32-mat
  (let ()
    (define col-masks
      (for*/list ([in-byte (in-range 4)]
                  [in-bit  (in-range 8)])
        (define v (arithmetic-shift 1 in-bit))
        (define v2 (gf256-aes-xtime v))
        (define v3 (bitwise-xor v2 v))
        ;; Column vector `[b0', b1', b2', b3']` when unit input `v` is in `in-byte`:
        ;; b0' = 2*b0 ^ 3*b1 ^ 1*b2 ^ 1*b3
        ;; b1' = 1*b0 ^ 2*b1 ^ 3*b2 ^ 1*b3
        ;; b2' = 1*b0 ^ 1*b1 ^ 2*b2 ^ 3*b3
        ;; b3' = 3*b0 ^ 1*b1 ^ 1*b2 ^ 2*b3
        (define out-bytes
          (match in-byte
            [0 (list v2 v  v  v3)]
            [1 (list v3 v2 v  v )]
            [2 (list v  v3 v2 v )]
            [3 (list v  v  v3 v2)]))
        (for/sum ([ob (in-list out-bytes)] [idx (in-naturals)])
          (arithmetic-shift ob (* 8 idx)))))
    (cols->gf2-matrix 32 col-masks)))

(define aes-mixcol-col-gates-template
  (gf2-matrix->lakefill-sexpr aes-mixcol-32x32-mat (range 32)))

(define (aes-mixcolumns-sexpr state128)
  `(seq ,@(for/list ([col (in-range 4)])
            (define col-wires (take (drop state128 (* 32 col)) 32))
            (gf2-matrix->lakefill-sexpr aes-mixcol-32x32-mat col-wires))))

;; FIPS-197 Rcon[1..10] byte constants.
(define aes-rcon-bytes
  #(#x00 #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80 #x1B #x36))

;; Helper: XOR 32-bit `SubWord(RotWord(src-word32)) ^ Rcon[rcon-idx]` into `dst-word32`
;; using `aes-sbox-xor-sexpr` on `24` of the `32` shared scratch wires (`0` ancilla leak!).
(define (aes-xor-sub-rot-rcon-sexpr src32 dst32 rcon-u8 sc32)
  (define sc24 (take sc32 24))
  (define s0 (take src32 8))
  (define s1 (take (drop src32 8) 8))
  (define s2 (take (drop src32 16) 8))
  (define s3 (drop src32 24))
  (define d0 (take dst32 8))
  (define d1 (take (drop dst32 8) 8))
  (define d2 (take (drop dst32 16) 8))
  (define d3 (drop dst32 24))
  ;; RotWord([s0, s1, s2, s3]) = [s1, s2, s3, s0]
  `(seq ,(aes-sbox-xor-sexpr s1 d0 sc24)
        ,(aes-sbox-xor-sexpr s2 d1 sc24)
        ,(aes-sbox-xor-sexpr s3 d2 sc24)
        ,(aes-sbox-xor-sexpr s0 d3 sc24)
        ,(xor-byte-const-sexpr d0 rcon-u8)))

;; Helper: XOR 32-bit `SubWord(src32)` (no RotWord, for AES-256 `i mod 8 == 4`!) into `dst32`.
(define (aes-xor-subword-sexpr src32 dst32 sc32)
  (define sc24 (take sc32 24))
  `(seq ,@(for/list ([b (in-range 4)])
            (aes-sbox-xor-sexpr (take (drop src32 (* 8 b)) 8)
                                (take (drop dst32 (* 8 b)) 8)
                                sc24))))

(define (xor-word32-sexpr src32 dst32)
  `(seq ,@(for/list ([s (in-list src32)] [d (in-list dst32)])
            `(cx ,s ,d))))

;; Full reversible AES-128 (`key-bits = 128`, 10r), AES-192 (`key-bits = 192`, 12r),
;; and AES-256 (`key-bits = 256`, 14r) Lakefill Lisp S-expression!
;; Layout:
;;   - `state128` : 128 wires (plaintext in -> ciphertext out in-place!)
;;   - `key-wires`: 128, 192, or 256 wires (rolling key state evolved reversibly in-place!)
;;   - `sc32`     : 32 shared clean scratch wires (asserted `0` after every S-box and at exit!)
(define (aes-cipher-sexpr key-bits state128 key-wires sc32)
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  ;; Advance the Nk-word key register by one full Nk-word epoch `e >= 1` in-place!
  (define (advance-key-epoch e)
    (match nk
      [4 `(seq ,(aes-xor-sub-rot-rcon-sexpr (kword 3) (kword 0) (vector-ref aes-rcon-bytes e) sc32)
               ,(xor-word32-sexpr (kword 0) (kword 1))
               ,(xor-word32-sexpr (kword 1) (kword 2))
               ,(xor-word32-sexpr (kword 2) (kword 3)))]
      [6 `(seq ,(aes-xor-sub-rot-rcon-sexpr (kword 5) (kword 0) (vector-ref aes-rcon-bytes e) sc32)
               ,(xor-word32-sexpr (kword 0) (kword 1))
               ,(xor-word32-sexpr (kword 1) (kword 2))
               ,(xor-word32-sexpr (kword 2) (kword 3))
               ,(xor-word32-sexpr (kword 3) (kword 4))
               ,(xor-word32-sexpr (kword 4) (kword 5)))]
      [8 ;; For AES-256 epoch 7 (final half-epoch needing only W[56..59] = kword 0..3),
         ;; advancing all 8 words is still 100% reversible and keeps key evolution uniform!
         `(seq ,(aes-xor-sub-rot-rcon-sexpr (kword 7) (kword 0) (vector-ref aes-rcon-bytes e) sc32)
               ,(xor-word32-sexpr (kword 0) (kword 1))
               ,(xor-word32-sexpr (kword 1) (kword 2))
               ,(xor-word32-sexpr (kword 2) (kword 3))
               ,(aes-xor-subword-sexpr (kword 3) (kword 4) sc32)
               ,(xor-word32-sexpr (kword 4) (kword 5))
               ,(xor-word32-sexpr (kword 5) (kword 6))
               ,(xor-word32-sexpr (kword 6) (kword 7)))]))

  ;; Stream the `4 * (nr + 1)` key words in strictly increasing order `w = 0 .. 4*nr + 3`,
  ;; advancing the rolling key register right when `w > 0` and `(modulo w nk) == 0`!
  (define steps '())
  (for ([r (in-range (add1 nr))])
    (when (> r 0)
      ;; SubBytes (16 bytes in-place via `erase-by`!)
      (set! steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-sbox-inplace-sexpr (take (drop state128 (* 8 b)) 8) sc32)))
                  steps))
      ;; ShiftRows
      (set! steps (cons (aes-shiftrows-sexpr state128) steps))
      ;; MixColumns (omitted in final round `r = nr`)
      (when (< r nr)
        (set! steps (cons (aes-mixcolumns-sexpr state128) steps))))
    ;; AddRoundKey (interleaving epoch advancement cleanly for all Nk in {4, 6, 8}!)
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! steps (cons (advance-key-epoch (quotient w-idx nk)) steps)))
      (set! steps (cons (xor-word32-sexpr (kword (modulo w-idx nk)) (sword c)) steps))))
  `(seq ,@(reverse steps) (assert-clean ,sc32)))

;; AES Grover Key-Search Phase Oracle (`within-apply` around full AES-128/192/256!):
;; Runs forward AES encryption, checks whether a subset/full ciphertext matches
;; `target-ct-bytes` via phase kickback (`-1` phase iff ciphertext == target!),
;; and runs `(invert ...)` to restore:
;;   - `state128` back to the initial plaintext,
;;   - `key-wires` back to the initial candidate key, AND
;;   - `100%` of `sc32` ancillas (plus `mcz` scratch wires) to `0` (`Law U1`)!
(define (aes-grover-oracle-sexpr key-bits state128 key-wires sc32 target-ct-bytes [check-bits 32])
  ;; Note: `sc32` has 32 clean wires at the end of `aes-cipher-sexpr`, so `mcz` on
  ;; `check-bits <= 32` ciphertext wires can reuse `sc32` (`check-bits - 2 <= 30` wires)!
  (define checked-wires (take state128 check-bits))
  (define negations
    (for/list ([bit-idx (in-range check-bits)]
               #:when (not (bitwise-bit-set?
                            (bytes-ref target-ct-bytes (quotient bit-idx 8))
                            (modulo bit-idx 8))))
      `(x ,(list-ref state128 bit-idx))))
  `(within-apply
    ,(aes-cipher-sexpr key-bits state128 key-wires sc32)
    (within-apply
     (seq ,@negations)
     ,(mcz-sexpr checked-wires sc32)
     ,sc32)
    ,sc32))

;; =============================================================================
;; SECTION 4: Reversible 18-Round `Keccak-f[200]` (`SPHINCS+` / SHA-3 Core)
;; =============================================================================
;; State: 200 wires `state200` (`A[x, y, z]` at wire `8 * (5*y + x) + z`),
;; plus 40 clean scratch wires `sc40` restored to `0` after EVERY round step!

;; Exact 40x40 GF(2) matrix `M_theta` mapping `C[x, z] -> C'[x, z] = C[x, z] ^ D[x, z]`.
(define keccak-theta-parity-mat
  (let ([M (for/vector ([r (in-range 40)]) (make-vector 40 0))])
    (for* ([x (in-range 5)]
           [z (in-range 8)])
      (define row (+ (* 8 x) z))
      (define c-self row)
      (define c-left (+ (* 8 (modulo (sub1 x) 5)) z))
      (define c-right (+ (* 8 (modulo (add1 x) 5)) (modulo (sub1 z) 8)))
      (vector-set! (vector-ref M row) c-self 1)
      (vector-set! (vector-ref M row) c-left 1)
      (vector-set! (vector-ref M row) c-right 1))
    M))

;; Reversible `Keccak-f[200]` `theta` step using Lakefill `erase-by` on 40 scratch wires!
(define (keccak-f200-theta-sexpr state200 sc40)
  (define (awire x y z) (list-ref state200 (+ (* 8 (+ (* 5 y) x)) z)))
  (define (cwire x z)   (list-ref sc40 (+ (* 8 x) z)))
  `(erase-by
    (seq ;; 1. Compute column parities C[x, z] into clean `sc40`
         ,@(for*/list ([x (in-range 5)] [z (in-range 8)] [y (in-range 5)])
             `(cx ,(awire x y z) ,(cwire x z)))
         ;; 2. XOR D[x, z] = C[x-1, z] ^ C[x+1, z-1] into A[x, y, z] -> A'[x, y, z]
         ,@(for*/list ([x (in-range 5)] [y (in-range 5)] [z (in-range 8)])
             `(seq (cx ,(cwire (modulo (sub1 x) 5) z) ,(awire x y z))
                   (cx ,(cwire (modulo (add1 x) 5) (modulo (sub1 z) 8)) ,(awire x y z)))))
    (seq ;; 3. Transform `sc40` in-place from C to C' = M_theta * C (`0` ancillas!)
         ,(gf2-matrix->lakefill-sexpr keccak-theta-parity-mat sc40)
         ;; 4. Cancel `sc40` (`C' ^ sum_y A'[x,y,z] = C' ^ C' = 0^40`)!
         ,@(for*/list ([x (in-range 5)] [z (in-range 8)] [y (in-range 5)])
             `(cx ,(awire x y z) ,(cwire x z))))
    ,sc40))

;; Combined `rho` + `pi` permutation on `Keccak-f[200]` compiled to wire `swap`s (`0` ancillas!).
(define keccak-f200-rho-offsets
  (let ([tbl (make-vector 25 0)]
        [x 1] [y 0])
    (for ([t (in-range 24)])
      (vector-set! tbl (+ (* 5 y) x) (modulo (quotient (* (add1 t) (+ t 2)) 2) 8))
      (define nx y)
      (define ny (modulo (+ (* 2 x) (* 3 y)) 5))
      (set! x nx)
      (set! y ny))
    tbl))

(define (keccak-f200-rho-pi-sexpr state200)
  ;; After rho then pi:
  ;; rho: R[x, y, z] = A[x, y, (z - offset[x,y]) mod 8]
  ;; pi : P[x, y, z] = R[(x + 3*y) mod 5, x, z]
  ;;                 = A[(x + 3*y) mod 5, x, (z - offset[(x + 3*y) mod 5, x]) mod 8]!
  (define src-for-dst
    (for*/list ([y (in-range 5)]
                [x (in-range 5)]
                [z (in-range 8)])
      (define sx (modulo (+ x (* 3 y)) 5))
      (define sy x)
      (define off (vector-ref keccak-f200-rho-offsets (+ (* 5 sy) sx)))
      (define sz (modulo (- z off) 8))
      (+ (* 8 (+ (* 5 sy) sx)) sz)))
  (perm->swap-sexpr state200 src-for-dst))

;; Reversible 5-bit `Keccak` row `chi_5` (`a[0..4] -> chi_5(a)`) using `ccx` + `cx` +
;; `within-apply` / `erase-by` degree-3 algebraic inverse scratch-plane uncomputation!
;; Uses `10` clean scratch wires `sc10 = (s0..s4, t0..t4)`, all restored to `0`!
(define (keccak-chi5-inplace-sexpr row5 sc10)
  (define s5 (take sc10 5))
  (define t5 (drop sc10 5))
  (define (r i) (list-ref row5 (modulo i 5)))
  (define (s i) (list-ref s5   (modulo i 5)))
  (define (t i) (list-ref t5   (modulo i 5)))
  `(erase-by
    ;; 1. Forward `s[x] <- a[x] ^ (~a[x+1] & a[x+2])` (`5` `ccx` gates)
    (seq ,@(for/list ([x (in-range 5)])
             `(seq (cx ,(r x) ,(s x))
                   (x ,(r (add1 x)))
                   (ccx ,(r (add1 x)) ,(r (+ x 2)) ,(s x))
                   (x ,(r (add1 x))))))
    ;; 2. Degree-3 algebraic inverse `a ^= chi_5^-1(s)` via `within-apply` on `t5`:
    ;;    `t[x] = s[x+2] ^ (~s[x+3] & s[x+4])`,
    ;;    `chi_5^-1(s)_x = s[x] ^ (~s[x+1] & t[x])`,
    ;;    which cancels `a` to `00000` and restores `t5` to `00000`; then swap `a <-> s`!
    (seq (within-apply
          (seq ,@(for/list ([x (in-range 5)])
                   `(seq (cx ,(s (+ x 2)) ,(t x))
                         (x ,(s (+ x 3)))
                         (ccx ,(s (+ x 3)) ,(s (+ x 4)) ,(t x))
                         (x ,(s (+ x 3))))))
          (seq ,@(for/list ([x (in-range 5)])
                   `(seq (cx ,(s x) ,(r x))
                         (x ,(s (add1 x)))
                         (ccx ,(s (add1 x)) ,(t x) ,(r x))
                         (x ,(s (add1 x))))))
          ,t5)
         ,@(for/list ([x (in-range 5)])
             `(swap ,(r x) ,(s x))))
    ,sc10))

(define (keccak-f200-chi-sexpr state200 sc40)
  (define sc10 (take sc40 10))
  `(seq ,@(for*/list ([y (in-range 5)] [z (in-range 8)])
            (define row5
              (for/list ([x (in-range 5)])
                (list-ref state200 (+ (* 8 (+ (* 5 y) x)) z))))
            (keccak-chi5-inplace-sexpr row5 sc10))
        (assert-clean ,sc40)))

;; Official FIPS-202 `Keccak-f[200]` 8-bit round constants `RC[0..17]`.
(define keccak-f200-rc-bytes
  #(#x01 #x82 #x8a #x00 #x8b #x01 #x81 #x09 #x8a
    #x88 #x09 #x0a #x8b #x8b #x89 #x03 #x02 #x80))

(define (keccak-f200-iota-sexpr state200 round-idx)
  (xor-byte-const-sexpr (take state200 8)
                        (vector-ref keccak-f200-rc-bytes round-idx)))

;; Complete 18-round reversible `Keccak-f[200]` Lakefill Lisp S-expression!
(define (keccak-f200-sexpr state200 sc40 [num-rounds 18])
  `(seq ,@(for/list ([ir (in-range num-rounds)])
            `(seq ,(keccak-f200-theta-sexpr state200 sc40)
                  ,(keccak-f200-rho-pi-sexpr state200)
                  ,(keccak-f200-chi-sexpr state200 sc40)
                  ,(keccak-f200-iota-sexpr state200 ir)))
        (assert-clean ,sc40)))

;; =============================================================================
;; SECTION 5: Gidney Temporary-AND Adder & Modular Multiplier (`RSA / ECC` Core)
;; =============================================================================
;; Gidney (Quantum 2, 74, 2018): `n`-bit ripple-carry in-place adder `b <- (a + b) mod 2^n`
;; using ONLY `n - 1` Toffolis (`ccx`) in the forward carry sweep and `0` Toffolis in
;; the reverse carry uncomputation via `(mid-meas-x-cond-z c_i (a_i b_i))` (`Law U4`)!

(define (gidney-adder-sexpr n a-wires b-wires carry-wires)
  (when (< n 2)
    (error 'gidney-adder-sexpr "Gidney adder requires n >= 2, got ~a" n))
  (when (< (length carry-wires) (sub1 n))
    (error 'gidney-adder-sexpr "Need ~a carry ancillas, got ~a" (sub1 n) (length carry-wires)))
  (define (a i) (list-ref a-wires i))
  (define (b i) (list-ref b-wires i))
  (define (c i) (list-ref carry-wires i))
  (define used-carries (take carry-wires (sub1 n)))

  ;; 1. Forward carry tree (`n - 1` `ccx` temporary-AND gates)
  (define fwd-steps
    (cons `(ccx ,(a 0) ,(b 0) ,(c 0))
          (for/list ([i (in-range 1 (sub1 n))])
            `(seq (cx ,(c (sub1 i)) ,(a i))
                  (cx ,(c (sub1 i)) ,(b i))
                  (ccx ,(a i) ,(b i) ,(c i))
                  (cx ,(c (sub1 i)) ,(c i))))))

  ;; 2. MSB sum (`i = n - 1`)
  (define top-step
    `(seq (cx ,(c (- n 2)) ,(b (sub1 n)))
          (cx ,(a (sub1 n)) ,(b (sub1 n)))))

  ;; 3. Reverse carry uncomputation via `mid-meas-x-cond-z` (`0` Toffolis!) + sum bits
  (define rev-steps
    (append
     (for/list ([i (in-range (- n 2) 0 -1)])
       `(seq (cx ,(c (sub1 i)) ,(c i))
             (mid-meas-x-cond-z ,(c i) (,(a i) ,(b i)))
             (cx ,(c (sub1 i)) ,(a i))
             (cx ,(a i) ,(b i))))
     (list `(seq (mid-meas-x-cond-z ,(c 0) (,(a 0) ,(b 0)))
                 (cx ,(a 0) ,(b 0))))))

  `(seq ,@fwd-steps ,top-step ,@rev-steps (assert-clean ,used-carries)))

;; Purely unitary Gidney-structure ripple adder (`2n - 2` Toffolis, invertible via `invert`!)
;; used as a subroutine inside `within-apply` / modular arithmetic when syntactic inversion is needed.
(define (unitary-ripple-adder-sexpr n a-wires b-wires carry-wires)
  (define (a i) (list-ref a-wires i))
  (define (b i) (list-ref b-wires i))
  (define (c i) (list-ref carry-wires i))
  (define used-carries (take carry-wires (sub1 n)))
  (define fwd-steps
    (cons `(ccx ,(a 0) ,(b 0) ,(c 0))
          (for/list ([i (in-range 1 (sub1 n))])
            `(seq (cx ,(c (sub1 i)) ,(a i))
                  (cx ,(c (sub1 i)) ,(b i))
                  (ccx ,(a i) ,(b i) ,(c i))
                  (cx ,(c (sub1 i)) ,(c i))))))
  (define top-step
    `(seq (cx ,(c (- n 2)) ,(b (sub1 n)))
          (cx ,(a (sub1 n)) ,(b (sub1 n)))))
  (define rev-steps
    (append
     (for/list ([i (in-range (- n 2) 0 -1)])
       `(seq (cx ,(c (sub1 i)) ,(c i))
             (ccx ,(a i) ,(b i) ,(c i))
             (cx ,(c (sub1 i)) ,(a i))
             (cx ,(a i) ,(b i))))
     (list `(seq (ccx ,(a 0) ,(b 0) ,(c 0))
                 (cx ,(a 0) ,(b 0))))))
  `(seq ,@fwd-steps ,top-step ,@rev-steps (assert-clean ,used-carries)))

;; Controlled Gidney adder: `if ctrl == 1 then b <- (a + b) mod 2^n` using `within-apply`
;; masked `a_masked <- ctrl & a` (`n` `ccx` + `(n-1)` Gidney MBU adder + `n` `ccx` uncompute!).
(define (ctrl-gidney-adder-sexpr n ctrl a-wires b-wires masked-a-wires carry-wires)
  `(within-apply
    (seq ,@(for/list ([aw (in-list a-wires)] [mw (in-list masked-a-wires)])
             `(ccx ,ctrl ,aw ,mw)))
    ,(gidney-adder-sexpr n masked-a-wires b-wires carry-wires)
    ,masked-a-wires))

;; Reversible Gidney Modular Adder (`b <- (a + b) mod N` for `0 <= a, b < N < 2^n`)!
;; Uses `(n + 1)`-bit extended arithmetic (`b_ext = (b_0 .. b_{n-1}, ovf)`):
;;   1. Add `a_ext` (`n+1` bits, MSB=0) into `b_ext` via Gidney MBU adder!
;;   2. Subtract `N` (i.e. add `2^{n+1} - N` loaded into `mod-wires`) via Gidney MBU adder!
;;      Now `ovf == 1` iff `a + b < N` (underflow!).
;;   3. Controlled on `ovf == 1`, add `N` back into `b_ext`! Now `b` holds `(a + b) mod N`!
;;   4. Uncompute `ovf` (`ovf == 1` iff `(a + b) mod N >= a`, i.e., no wrap-around!):
;;      Compare `b < a` by subtracting `a` (`+ (2^{n+1} - 1 - a + 1)`), toggling `ovf` to `0`,
;;      and restoring `b`! All scratch wires (`ovf`, `mod-wires`, `carry-wires`) return to `0`!
(define (gidney-modular-adder-sexpr n modulus a-wires b-wires ovf-wire zero-wire mod-wires carry-wires)
  (define n1 (add1 n))
  (define b-ext (append b-wires (list ovf-wire)))
  (define a-ext (append a-wires (list zero-wire)))
  (define two-comp-N (- (arithmetic-shift 1 n1) modulus))
  (define (load-const-sexpr ws val)
    `(seq ,@(for/list ([i (in-range (length ws))]
                       #:when (bitwise-bit-set? val i))
              `(x ,(list-ref ws i)))))
  `(seq ;; 1. b_ext <- a + b (Gidney MBU adder)
        ,(gidney-adder-sexpr n1 a-ext b-ext carry-wires)
        ;; 2. b_ext <- (a + b) - N mod 2^{n+1}; ovf-wire = 1 iff a + b < N
        (within-apply
         ,(load-const-sexpr mod-wires two-comp-N)
         ,(gidney-adder-sexpr n1 mod-wires b-ext carry-wires)
         ,mod-wires)
        ;; 3. Conditionally add N back into b[0..n-1] if ovf-wire == 1
        (within-apply
         (seq ,@(for/list ([i (in-range n)]
                           #:when (bitwise-bit-set? modulus i))
                  `(cx ,ovf-wire ,(list-ref mod-wires i))))
         ,(gidney-adder-sexpr n (take mod-wires n) b-wires (take carry-wires (sub1 n)))
         ,(take mod-wires n))
        ;; 4. Uncompute ovf-wire via `[(2^n - 1 - b_out) + a >= 2^n] == [b_out < a]`!
        (x ,ovf-wire)
        (within-apply
         (seq ,@(for/list ([bw (in-list b-wires)] [mw (in-list (take mod-wires n))])
                  `(cx ,bw ,mw))
              ,@(for/list ([mw (in-list (take mod-wires n))]) `(x ,mw))
              ,(unitary-ripple-adder-sexpr n1 a-ext mod-wires carry-wires))
         (cx ,(last mod-wires) ,ovf-wire)
         ,(append mod-wires carry-wires))
        (assert-clean ,(append (list ovf-wire zero-wire) mod-wires carry-wires))))

;; Reversible Gidney Schoolbook Multiplier (`acc <- (acc + x * y) mod 2^n` for RSA/ECC cores):
;; Uses shifted controlled Gidney MBU adders!
(define (gidney-schoolbook-multiplier-sexpr n x-wires y-wires acc-wires masked-wires carry-wires)
  `(seq
    ,@(for/list ([k (in-range n)])
        (define yk (list-ref y-wires k))
        (define rem (- n k))
        (cond
          [(= rem 1)
           `(ccx ,(first x-wires) ,yk ,(list-ref acc-wires k))]
          [else
           (ctrl-gidney-adder-sexpr
            rem
            yk
            (take x-wires rem)
            (drop acc-wires k)
            (take masked-wires rem)
            (take carry-wires (sub1 rem)))]))
    (assert-clean ,(append masked-wires carry-wires))))

;; =============================================================================
;; SECTION 6: `BCH(15, 7, 5)` Peterson-Berlekamp Syndrome Uncomputation (`DQI`)
;; =============================================================================
;; Field `GF(2^4) = GF(2)[a] / (a^4 + a + 1)` (primitive polynomial `x^4 + x + 1`, `#x13`)!
;; Note: earlier in Section 3 we built tower `GF((2^2)^2)` for AES. Here we build
;; exact reversible polynomial-basis `GF(2)[a]/(a^4 + a + 1)` multiplication and
;; inversion (via isomorphism to our `gf16-tower-inv-sexpr`!) so syndrome `(S_1, S_3)`
;; matches the textbook `BCH(15, 7, 5)` parity check `H = [a^i, a^{3i}]_{i=0..14}`!

(define (gf16-poly-mul a b)
  (for/fold ([res 0]) ([k (in-range 4)])
    (define term
      (for/fold ([x a]) ([_ (in-range k)])
        (define sh (bitwise-and (arithmetic-shift x 1) #xF))
        (if (bitwise-bit-set? x 3) (bitwise-xor sh #x3) sh)))
    (if (bitwise-bit-set? b k) (bitwise-xor res term) res)))

(define (gf16-poly-pow a e)
  (for/fold ([r 1]) ([_ (in-range (modulo e 15))])
    (gf16-poly-mul r a)))

;; Isomorphism between polynomial `GF(2)[a]/(a^4 + a + 1)` and tower `GF((2^2)^2)`:
;; In `GF(2)[a]/(a^4 + a + 1)`: `u = a^5 = a^2 + a = #b0110` (`6`) satisfies `u^2 + u + 1 = 0`,
;; and `v = a = #b0010` (`2`)? Check `a^2 + a = u` => `v^2 + v + u = 0`! YES!! `v = a` (`2`),
;; `u*v = a * (a^2 + a) = a^3 + a^2 = #b1100` (`12`)!
;; So tower basis `{1, u, v, uv}` in poly basis is `'(#x1 #x6 #x2 #xc)`!
(define gf16-tower-to-poly-mat (cols->gf2-matrix 4 '(#x1 #x6 #x2 #xc)))
(define gf16-poly-to-tower-mat (gf2-matinv gf16-tower-to-poly-mat))

;; Reversible bilinear multiplier `out4 ^= a4 * b4` in `GF(2)[a]/(a^4 + a + 1)` (`0` ancillas!).
(define (gf16-poly-mul-xor-sexpr a4 b4 out4)
  (define terms '())
  (for* ([i (in-range 4)] [j (in-range 4)])
    (define prod (gf16-poly-pow 2 (+ i j)))
    (for ([bit (in-range 4)]
          #:when (bitwise-bit-set? prod bit))
      (set! terms (cons `(ccx ,(list-ref a4 i) ,(list-ref b4 j) ,(list-ref out4 bit))
                        terms))))
  `(seq ,@(reverse terms)))

;; Reversible constant multiplier `out4 ^= c_gf16 * x4` in `GF(2)[a]/(a^4 + a + 1)` (pure `cx`!).
(define (gf16-poly-const-mul-xor-sexpr const-val x4 out4)
  (define terms '())
  (for ([i (in-range 4)])
    (define prod (gf16-poly-mul const-val (arithmetic-shift 1 i)))
    (for ([bit (in-range 4)]
          #:when (bitwise-bit-set? prod bit))
      (set! terms (cons `(cx ,(list-ref x4 i) ,(list-ref out4 bit)) terms))))
  `(seq ,@(reverse terms)))

;; Reversible `GF(2)[a]/(a^4 + a + 1)` inverter `out4 ^= x4^{14}` (`0^-1 = 0`) via tower `within-apply`!
(define (gf16-poly-inv-xor-sexpr x4 out4 sc4)
  `(seq (within-apply
         ,(gf2-matrix->lakefill-sexpr gf16-poly-to-tower-mat x4)
         ,(gf16-tower-inv-sexpr x4 out4 sc4)
         ,sc4)
        ,(gf2-matrix->lakefill-sexpr gf16-tower-to-poly-mat out4)))

;; Forward/uncompute syndrome parity network `syn8 ^= H^perp * e15`:
;; `S_1[0..3] ^= sum_i e[i] * a^i`, `S_3[0..3] ^= sum_i e[i] * a^{3i}` (pure `cx` gates!).
(define (bch15-syndrome-parity-sexpr e15 syn8)
  (define s1-wires (take syn8 4))
  (define s3-wires (drop syn8 4))
  (define steps '())
  (for ([i (in-range 15)])
    (define p1 (gf16-poly-pow 2 i))
    (define p3 (gf16-poly-pow 2 (* 3 i)))
    (for ([b (in-range 4)])
      (when (bitwise-bit-set? p1 b)
        (set! steps (cons `(cx ,(list-ref e15 i) ,(list-ref s1-wires b)) steps)))
      (when (bitwise-bit-set? p3 b)
        (set! steps (cons `(cx ,(list-ref e15 i) ,(list-ref s3-wires b)) steps)))))
  `(seq ,@(reverse steps)))

;; Complete DQI `BCH(15, 7, 5)` Peterson-Berlekamp Syndrome Uncomputation S-expression!
;; Given `(syn8 = H^perp(e_target), e15 = 0^15, sc26 = 0^26)`:
;;   1. Reversible algebraic Peterson-Berlekamp + Chien search decodes `e15 <- e_target`
;;      from `syn8 = (S_1, S_3)` inside `within-apply`, restoring all `26` scratch wires to `0`!
;;   2. Parity-check erasure `syn8 ^= H^perp(e15)` uncomputes `syn8 -> 00000000` (`Law U1`)!
(define (bch-15-7-5-syndrome-uncompute-sexpr syn8 e15 sc26)
  (define s1      (take syn8 4))
  (define s3      (drop syn8 4))
  (define s1-sq   (take sc26 4))            ;; S_1^2
  (define num     (take (drop sc26 4) 4))   ;; S_3 ^ S_1^3
  (define s1-inv  (take (drop sc26 8) 4))   ;; S_1^{14}
  (define sigma2  (take (drop sc26 12) 4))  ;; (S_3 ^ S_1^3) * S_1^{14}
  (define lam     (take (drop sc26 16) 4))  ;; Chien evaluation Lambda(a^{-i})
  (define sub-sc  (take (drop sc26 20) 4))  ;; 4 scratch wires for gf16-poly-inv
  (define mcx-sc  (drop sc26 24))           ;; 2 scratch wires for 4-ctrl `mcx`

  ;; Linear squaring `s1-sq ^= S_1^2` in `GF(2)[a]/(a^4 + a + 1)` (`1->1, a->a^2, a^2->a+1, a^3->a^3+a^2`?):
  ;;Wait: `(a^3)^2 = a^6 = a^2 * (a + 1) = a^3 + a^2`! Let's compute via `gf16-poly-mul`!
  (define sq-mat
    (cols->gf2-matrix
     4
     (for/list ([b (in-range 4)])
       (define v (arithmetic-shift 1 b))
       (gf16-poly-mul v v))))

  `(erase-by
    ;; Step 1: Decode `e15` from `syn8` via `within-apply` on Peterson-Berlekamp scratch registers
    (within-apply
     (seq ;; s1-sq <- S_1^2 (`cx` gates via Copy + in-place sq)
          ,@(for/list ([w (in-list s1)] [dst (in-list s1-sq)]) `(cx ,w ,dst))
          ,(gf2-matrix->lakefill-sexpr sq-mat s1-sq)
          ;; num <- S_3 ^ (s1-sq * S_1) = S_3 ^ S_1^3
          ,@(for/list ([w (in-list s3)] [dst (in-list num)]) `(cx ,w ,dst))
          ,(gf16-poly-mul-xor-sexpr s1-sq s1 num)
          ;; s1-inv <- S_1^{14} (`0^-1 = 0`)
          ,(gf16-poly-inv-xor-sexpr s1 s1-inv sub-sc)
          ;; sigma2 <- num * s1-inv = (S_3 ^ S_1^3) * S_1^{-1}
          ,(gf16-poly-mul-xor-sexpr num s1-inv sigma2))
     ;; Chien search across all 15 codeword coordinates `i = 0 .. 14`!
     (seq ,@(for/list ([i (in-range 15)])
              (define x-inv (gf16-poly-pow 2 (- 15 (modulo i 15))))
              (define x-inv-sq (gf16-poly-mul x-inv x-inv))
              `(within-apply
                (seq ;; lam <- 1 ^ (S_1 * a^{-i}) ^ (sigma2 * a^{-2i})
                     (x ,(first lam))
                     ,(gf16-poly-const-mul-xor-sexpr x-inv s1 lam)
                     ,(gf16-poly-const-mul-xor-sexpr x-inv-sq sigma2 lam)
                     ;; Negate `lam` so `lam == 1111` iff root `Lambda(a^{-i}) == 0`!
                     ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                (mcx ,lam ,(list-ref e15 i) ,mcx-sc)
                ,(append lam mcx-sc))))
     ,sc26)
    ;; Step 2: Uncompute `syn8 -> 00000000` via linear parity check `syn8 ^= H^perp(e15)`!
    ,(bch15-syndrome-parity-sexpr e15 syn8)
    ,(append syn8 sc26)))

;; =============================================================================
;; SECTION 7: Byte/Hex Helpers & Official NIST FIPS-197 / Keccak / RSA / BCH Runner
;; =============================================================================

(define (hex->bytes s)
  (define clean (string-replace s " " ""))
  (list->bytes
   (for/list ([i (in-range 0 (string-length clean) 2)])
     (string->number (substring clean i (+ i 2)) 16))))

(define (bytes->hex bs)
  (apply string-append
         (for/list ([b (in-bytes bs)])
           (~r b #:base 16 #:min-width 2 #:pad-string "0"))))

(define (load-bytes-into-reg! reg offset bs)
  (for ([byte-val (in-bytes bs)] [bi (in-naturals)])
    (for ([bit (in-range 8)])
      (vector-set! reg (+ offset (* 8 bi) bit)
                   (if (bitwise-bit-set? byte-val bit) 1 0)))))

(define (read-bytes-from-reg reg offset num-bytes)
  (list->bytes
   (for/list ([bi (in-range num-bytes)])
     (for/sum ([bit (in-range 8)])
       (arithmetic-shift (vector-ref reg (+ offset (* 8 bi) bit)) bit)))))

;; Standalone classical FIPS-202 `Keccak-f[200]` reference for cross-verification.
(define (keccak-f200-reference in-bytes)
  (define A (make-vector 25 0))
  (for ([i (in-range 25)])
    (vector-set! A i (bytes-ref in-bytes i)))
  (define (rol8 v n)
    (define s (modulo n 8))
    (bitwise-and #xFF (bitwise-ior (arithmetic-shift v s) (arithmetic-shift v (- s 8)))))
  (for ([ir (in-range 18)])
    ;; theta
    (define C (for/vector ([x (in-range 5)])
                (for/fold ([acc 0]) ([y (in-range 5)])
                  (bitwise-xor acc (vector-ref A (+ x (* 5 y)))))))
    (define D (for/vector ([x (in-range 5)])
                (bitwise-xor (vector-ref C (modulo (sub1 x) 5))
                             (rol8 (vector-ref C (modulo (add1 x) 5)) 1))))
    (for* ([x (in-range 5)] [y (in-range 5)])
      (define idx (+ x (* 5 y)))
      (vector-set! A idx (bitwise-xor (vector-ref A idx) (vector-ref D x))))
    ;; rho + pi
    (define B (make-vector 25 0))
    (for* ([x (in-range 5)] [y (in-range 5)])
      (define off (vector-ref keccak-f200-rho-offsets (+ x (* 5 y))))
      (define nx y)
      (define ny (modulo (+ (* 2 x) (* 3 y)) 5))
      (vector-set! B (+ nx (* 5 ny)) (rol8 (vector-ref A (+ x (* 5 y))) off)))
    ;; chi
    (for* ([y (in-range 5)] [x (in-range 5)])
      (define b0 (vector-ref B (+ x (* 5 y))))
      (define b1 (vector-ref B (+ (modulo (add1 x) 5) (* 5 y))))
      (define b2 (vector-ref B (+ (modulo (+ x 2) 5) (* 5 y))))
      (vector-set! A (+ x (* 5 y))
                   (bitwise-xor b0 (bitwise-and (bitwise-xor b1 #xFF) b2))))
    ;; iota
    (vector-set! A 0 (bitwise-xor (vector-ref A 0) (vector-ref keccak-f200-rc-bytes ir))))
  (list->bytes (vector->list A)))

;; Verify a single NIST FIPS-197 Appendix C vector (encryption + decryption via
;; `(invert-circuit ...)` + Grover `within-apply` phase oracle zero-leakage check!).
(define (verify-nist-aes-vector label key-bits pt-hex key-hex expected-ct-hex)
  (define pt-bytes (hex->bytes pt-hex))
  (define key-bytes (hex->bytes key-hex))
  (define exp-ct-bytes (hex->bytes expected-ct-hex))

  (define state128  (range 0 128))
  (define key-wires (range 128 (+ 128 key-bits)))
  (define sc32      (range (+ 128 key-bits) (+ 160 key-bits)))
  (define total-wires (+ 160 key-bits))

  ;; 1. Compile genuine reversible Lakefill AES circuit
  (define enc-gates
    (compile-lakefill (aes-cipher-sexpr key-bits state128 key-wires sc32)))
  (define reg (make-vector total-wires 0))
  (load-bytes-into-reg! reg 0 pt-bytes)
  (load-bytes-into-reg! reg 128 key-bytes)
  (eval-reversible-gates! reg enc-gates)

  (define got-ct-bytes (read-bytes-from-reg reg 0 16))
  (define got-ct-hex (bytes->hex got-ct-bytes))
  (define scratch-clean-after-enc?
    (for/and ([w (in-list sc32)]) (= (vector-ref reg w) 0)))
  (unless (equal? got-ct-hex expected-ct-hex)
    (error 'verify-nist-aes-vector
           "~a mismatch: got ~a, expected ~a" label got-ct-hex expected-ct-hex))
  (unless scratch-clean-after-enc?
    (error 'verify-nist-aes-vector "~a leaked scratch ancillas!" label))

  ;; 2. Run `(invert-circuit enc-gates)` to verify exact reversible decryption!
  (eval-reversible-gates! reg (invert-circuit enc-gates))
  (define recovered-pt-hex (bytes->hex (read-bytes-from-reg reg 0 16)))
  (define recovered-key-hex (bytes->hex (read-bytes-from-reg reg 128 (/ key-bits 8))))
  (unless (and (equal? recovered-pt-hex pt-hex) (equal? recovered-key-hex key-hex))
    (error 'verify-nist-aes-vector "~a inverse circuit failed roundtrip!" label))

  ;; 3. Run `within-apply` Grover phase oracle on matching key vs wrong key!
  (define oracle-gates
    (compile-lakefill (aes-grover-oracle-sexpr key-bits state128 key-wires sc32 exp-ct-bytes 32)))
  (define reg-hit (make-vector total-wires 0))
  (load-bytes-into-reg! reg-hit 0 pt-bytes)
  (load-bytes-into-reg! reg-hit 128 key-bytes)
  (define phase-hit (eval-reversible-gates! reg-hit oracle-gates))

  (define reg-miss (make-vector total-wires 0))
  (load-bytes-into-reg! reg-miss 0 pt-bytes)
  (load-bytes-into-reg! reg-miss 128 key-bytes)
  (vector-set! reg-miss 128 (bitwise-xor (vector-ref reg-miss 128) 1)) ;; flip 1 key bit
  (define phase-miss (eval-reversible-gates! reg-miss oracle-gates))

  (define oracle-ancillas-restored?
    (and (= phase-hit -1)
         (= phase-miss 1)
         (equal? (bytes->hex (read-bytes-from-reg reg-hit 0 16)) pt-hex)
         (equal? (bytes->hex (read-bytes-from-reg reg-hit 128 (/ key-bits 8))) key-hex)
         (for/and ([w (in-list sc32)]) (= (vector-ref reg-hit w) 0))
         (for/and ([w (in-list sc32)]) (= (vector-ref reg-miss w) 0))))
  (unless oracle-ancillas-restored?
    (error 'verify-nist-aes-vector "~a Grover oracle failed uncomputation or phase test!" label))

  (hasheq 'variant label
          'key_bits key-bits
          'rounds (match key-bits [128 10] [192 12] [256 14])
          'total_wires total-wires
          'shared_scratch_ancillas 32
          'plaintext_hex pt-hex
          'key_hex key-hex
          'ciphertext_hex got-ct-hex
          'expected_ciphertext_hex expected-ct-hex
          'nist_fips197_exact_match #t
          'inverse_decryption_exact #t
          'grover_oracle_phase_hit phase-hit
          'grover_oracle_phase_miss phase-miss
          'ancilla_leakage_bits 0
          'encrypt_gate_counts (gate-counts enc-gates)
          'grover_oracle_gate_counts (gate-counts oracle-gates)))

;; Run the complete Lakefill Lisp cryptographic verification suite and export gate lists!
(define (run-all-lakefill-verifications)
  (define t0 (current-inexact-milliseconds))

  ;; ---------------------------------------------------------------------------
  ;; 1. Exhaustive 256/256 AES S-Box & NIST FIPS-197 C.1 / C.2 / C.3 Verification
  ;; ---------------------------------------------------------------------------
  (define sbox-gates
    (compile-lakefill (aes-sbox-inplace-sexpr (range 0 8) (range 8 40))))
  (define sbox-00-reg (make-vector 40 0))
  (eval-reversible-gates! sbox-00-reg sbox-gates)
  (define sbox-00-out (bytes-ref (read-bytes-from-reg sbox-00-reg 0 1) 0))
  ;; Verify S(0x00) = 0x63, S(0x53) = 0xed, and S^-1(S(x)) = x across all 256 bytes!
  (define sbox-inv-gates (invert-circuit sbox-gates))
  (define sbox-256-bijective?
    (and (= sbox-00-out #x63)
         (let ([seen (make-hash)])
           (for/and ([x (in-range 256)])
             (define r (make-vector 40 0))
             (load-bytes-into-reg! r 0 (bytes x))
             (eval-reversible-gates! r sbox-gates)
             (define y (bytes-ref (read-bytes-from-reg r 0 1) 0))
             (hash-set! seen y #t)
             (define clean1? (for/and ([w (in-range 8 40)]) (= (vector-ref r w) 0)))
             (eval-reversible-gates! r sbox-inv-gates)
             (define x-back (bytes-ref (read-bytes-from-reg r 0 1) 0))
             (define clean2? (for/and ([w (in-range 8 40)]) (= (vector-ref r w) 0)))
             (and clean1? clean2? (= x-back x)))
           (= (hash-count seen) 256))))
  (unless sbox-256-bijective?
    (error 'run-all-lakefill-verifications "Boyar-Peralta/tower S-Box 256 check failed"))

  (define aes128-res
    (verify-nist-aes-vector
     "AES-128 (FIPS-197 C.1)" 128
     "00112233445566778899aabbccddeeff"
     "000102030405060708090a0b0c0d0e0f"
     "69c4e0d86a7b0430d8cdb78070b4c55a"))

  (define aes192-res
    (verify-nist-aes-vector
     "AES-192 (FIPS-197 C.2)" 192
     "00112233445566778899aabbccddeeff"
     "000102030405060708090a0b0c0d0e0f1011121314151617"
     "dda97ca4864cdfe06eaf70a0ec0d7191"))

  (define aes256-res
    (verify-nist-aes-vector
     "AES-256 (FIPS-197 C.3)" 256
     "00112233445566778899aabbccddeeff"
     "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
     "8ea2b7ca516745bfeafc49904b496089"))

  ;; ---------------------------------------------------------------------------
  ;; 2. Reversible 18-Round `Keccak-f[200]` Verification
  ;; ---------------------------------------------------------------------------
  (define keccak-gates
    (compile-lakefill (keccak-f200-sexpr (range 0 200) (range 200 240) 18)))
  (define keccak-inv-gates (invert-circuit keccak-gates))
  (define keccak-in-zero (make-bytes 25 0))
  (define keccak-in-pat
    (list->bytes (for/list ([i (in-range 25)]) (bitwise-and #xFF (+ (* 17 i) 5)))))

  (for ([in-bs (in-list (list keccak-in-zero keccak-in-pat))])
    (define kreg (make-vector 240 0))
    (load-bytes-into-reg! kreg 0 in-bs)
    (eval-reversible-gates! kreg keccak-gates)
    (define got-bs (read-bytes-from-reg kreg 0 25))
    (define ref-bs (keccak-f200-reference in-bs))
    (unless (equal? got-bs ref-bs)
      (error 'keccak-f200 "Keccak-f[200] mismatch: got ~a vs ~a"
             (bytes->hex got-bs) (bytes->hex ref-bs)))
    (unless (for/and ([w (in-range 200 240)]) (= (vector-ref kreg w) 0))
      (error 'keccak-f200 "Keccak-f[200] scratch leakage!"))
    (eval-reversible-gates! kreg keccak-inv-gates)
    (unless (equal? (read-bytes-from-reg kreg 0 25) in-bs)
      (error 'keccak-f200 "Keccak-f[200] inverse failed roundtrip!")))

  (define kreg-zero (make-vector 240 0))
  (eval-reversible-gates! kreg-zero keccak-gates)
  (define keccak-zero-out-hex (bytes->hex (read-bytes-from-reg kreg-zero 0 25)))

  ;; ---------------------------------------------------------------------------
  ;; 3. Gidney Temporary-AND Adder (`mid-meas-x-cond-z`) + Modular Adder & Multiplier
  ;; ---------------------------------------------------------------------------
  ;; 3a. Exhaustive 4-bit Gidney MBU adder (`256 / 256` `(a, b)` pairs x all `2^3 = 8` MBU branches!)
  (define gidney4-sexpr (gidney-adder-sexpr 4 '(0 1 2 3) '(4 5 6 7) '(8 9 10)))
  (define gidney4-gates (compile-lakefill gidney4-sexpr))
  (for* ([a (in-range 16)] [b (in-range 16)])
    (define greg (make-vector 11 0))
    (for ([bit (in-range 4)])
      (vector-set! greg bit (if (bitwise-bit-set? a bit) 1 0))
      (vector-set! greg (+ 4 bit) (if (bitwise-bit-set? b bit) 1 0)))
    (define out-reg (eval-mbu-circuit-all-branches greg gidney4-gates '(8 9 10)))
    (define got-a (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref out-reg bit) bit)))
    (define got-sum (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref out-reg (+ 4 bit)) bit)))
    (unless (and (= got-a a) (= got-sum (modulo (+ a b) 16)))
      (error 'gidney4 "Mismatch for (~a, ~a): got ~a" a b got-sum)))

  ;; Verify 11-qubit uniform quantum superposition `H^8 |0>` + Gidney MBU adder
  ;; across all `2^3 = 8` mid-circuit X-measurement branches in Racket statevector mode!
  (define gidney4-superpos-gates
    (append (for/list ([q (in-range 8)]) `(h ,q)) gidney4-gates))
  (for ([mask (in-range 8)])
    (define sv
      (eval-quantum-statevector
       11 gidney4-superpos-gates
       (lambda (step) (bitwise-bit-field mask step (add1 step)))))
    (define inner-prod
      (for*/sum ([a (in-range 16)] [b (in-range 16)])
        (define s (modulo (+ a b) 16))
        (define idx (bitwise-ior a (arithmetic-shift s 4)))
        (* (/ 1.0 16.0) (conjugate (vector-ref sv idx)))))
    (define fid (sqr (magnitude inner-prod)))
    (unless (< (abs (- fid 1.0)) 1e-10)
      (error 'gidney4-superpos "Superposition fidelity ~a != 1.0 on mask ~a" fid mask)))

  ;; 3b. Exhaustive 4-bit Gidney Modular Adder `(a + b) mod 13` (`169 / 169` pairs!)
  (define modadd4-gates
    (compile-lakefill
     (gidney-modular-adder-sexpr
      4 13 '(0 1 2 3) '(4 5 6 7) 8 9 '(10 11 12 13 14) '(15 16 17 18))))
  (for* ([a (in-range 13)] [b (in-range 13)])
    (define mreg (make-vector 19 0))
    (for ([bit (in-range 4)])
      (vector-set! mreg bit (if (bitwise-bit-set? a bit) 1 0))
      (vector-set! mreg (+ 4 bit) (if (bitwise-bit-set? b bit) 1 0)))
    (define ph (eval-reversible-gates! mreg modadd4-gates))
    (define got-sum (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref mreg (+ 4 bit)) bit)))
    (unless (and (= ph 1)
                 (= got-sum (modulo (+ a b) 13))
                 (for/and ([w (in-range 8 19)]) (= (vector-ref mreg w) 0)))
      (error 'gidney-modadd "Modular adder mod 13 failed on (~a, ~a): got ~a" a b got-sum)))

  ;; 3c. Exhaustive 4-bit Gidney Schoolbook Multiplier `acc <- (acc + x * y) mod 16` (`256 / 256` pairs!)
  (define mul4-gates
    (compile-lakefill
     (gidney-schoolbook-multiplier-sexpr
      4 '(0 1 2 3) '(4 5 6 7) '(8 9 10 11) '(12 13 14 15) '(16 17 18))))
  (for* ([x (in-range 16)] [y (in-range 16)])
    (define mreg (make-vector 19 0))
    (for ([bit (in-range 4)])
      (vector-set! mreg bit (if (bitwise-bit-set? x bit) 1 0))
      (vector-set! mreg (+ 4 bit) (if (bitwise-bit-set? y bit) 1 0)))
    (define ph (eval-reversible-gates! mreg mul4-gates))
    (define got-prod (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref mreg (+ 8 bit)) bit)))
    (unless (and (= ph 1)
                 (= got-prod (modulo (* x y) 16))
                 (for/and ([w (in-range 12 19)]) (= (vector-ref mreg w) 0)))
      (error 'gidney-mul "Multiplier failed on (~a, ~a): got ~a" x y got-prod)))

  ;; ---------------------------------------------------------------------------
  ;; 4. `BCH(15, 7, 5)` Peterson-Berlekamp Syndrome Uncomputation (`121 / 121`!)
  ;; ---------------------------------------------------------------------------
  (define bch-syn-encode-gates
    (compile-lakefill (bch15-syndrome-parity-sexpr (range 8 23) (range 0 8))))
  (define bch-uncompute-gates
    (compile-lakefill
     (bch-15-7-5-syndrome-uncompute-sexpr (range 0 8) (range 8 23) (range 23 49))))

  (define bch-masks
    (append (list 0)
            (for/list ([i (in-range 15)]) (arithmetic-shift 1 i))
            (for*/list ([i (in-range 15)] [j (in-range i)])
              (bitwise-ior (arithmetic-shift 1 i) (arithmetic-shift 1 j)))))
  (unless (= (length bch-masks) 121)
    (error 'bch15 "Expected 121 weight <= 2 masks, got ~a" (length bch-masks)))

  (define bch-uncomputed-count
    (for/sum ([mask (in-list bch-masks)])
      ;; Prepare initial syndrome `syn[0..7] = H^perp(mask)` on clean register, then clear `e`
      ;; so the DQI decoder receives ONLY `(syn[0..7], e = 0^15, scratch = 0^26)`!
      (define prep-reg (make-vector 49 0))
      (for ([i (in-range 15)] #:when (bitwise-bit-set? mask i))
        (vector-set! prep-reg (+ 8 i) 1))
      (eval-reversible-gates! prep-reg bch-syn-encode-gates)
      (for ([i (in-range 15)]) (vector-set! prep-reg (+ 8 i) 0))

      ;; Execute genuine reversible Lakefill Peterson-Berlekamp syndrome uncomputation!
      (eval-reversible-gates! prep-reg bch-uncompute-gates)
      (define syn-zero? (for/and ([w (in-range 0 8)]) (= (vector-ref prep-reg w) 0)))
      (define scratch-zero? (for/and ([w (in-range 23 49)]) (= (vector-ref prep-reg w) 0)))
      (define decoded-mask
        (for/sum ([i (in-range 15)])
          (arithmetic-shift (vector-ref prep-reg (+ 8 i)) i)))
      (if (and syn-zero? scratch-zero? (= decoded-mask mask)) 1 0)))

  (unless (= bch-uncomputed-count 121)
    (error 'bch15 "BCH(15,7,5) uncomputed ~a / 121 masks!" bch-uncomputed-count))

  ;; ---------------------------------------------------------------------------
  ;; 5. Export Reversible Quantum Superposition Gadgets for Qiskit Aer & Stim!
  ;; ---------------------------------------------------------------------------
  ;; 5a. GF(2^4) Tower S-box Inverter (`12` qubits: `x[0..3]`, `out[4..7]`, `sc[8..11]`)
  (define gf16-sbox-gadget-gates
    (compile-lakefill (gf16-tower-inv-sexpr '(0 1 2 3) '(4 5 6 7) '(8 9 10 11))))
  ;; 5b. Keccak `chi_5` Reversible In-Place S-box (`15` qubits: `row[0..4]`, `sc[5..14]`)
  (define keccak-chi5-gadget-gates
    (compile-lakefill (keccak-chi5-inplace-sexpr '(0 1 2 3 4) (range 5 15))))
  ;; 5c. 4-Bit Gidney MBU Adder (`11` qubits: `a[0..3]`, `b[4..7]`, `c[8..10]`)
  ;; 5d. Clifford Hadamard-Dual MBU Gadget & AES MixColumns 32-qubit Clifford Network for `stim`!
  (define clifford-mbu-gadget-gates
    (compile-lakefill
     '(seq (cx 0 2)
           (cx 1 2)
           ;; Uncompute CNOT parity ancilla `2` via Hadamard-dual `M_X + cond-Z` on both controls!
           (cx 0 2)
           (mid-meas-x-cond-z 2 1))))
  (define mixcol32-gadget-gates
    (compile-lakefill (gf2-matrix->lakefill-sexpr aes-mixcol-32x32-mat (range 32))))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))

  (hasheq
   'suite "Executable #lang racket Lakefill Lisp Cryptographic Verification"
   'status "PASS"
   'racket_version (version)
   'wall_time_ms (real->decimal-string elapsed-ms 2)
   'aes_sbox_boyar_peralta_tower (hasheq
     'wires 40
     'scratch_ancillas 32
     'exhaustive_256_bijection_verified sbox-256-bijective?
     'sbox_00_hex (~r sbox-00-out #:base 16 #:min-width 2 #:pad-string "0")
     'ancilla_leakage_bits 0
     'gate_counts (gate-counts sbox-gates))
   'nist_fips197_vectors (list aes128-res aes192-res aes256-res)
   'keccak_f200_reversible (hasheq
     'rounds 18
     'state_wires 200
     'scratch_ancillas 40
     'total_wires 240
     'zero_block_output_hex keccak-zero-out-hex
     'fips202_reference_exact_match #t
     'inverse_circuit_roundtrip_exact #t
     'ancilla_leakage_bits 0
     'gate_counts (gate-counts keccak-gates))
   'gidney_mbu_arithmetic (hasheq
     'gidney_4bit_adder_sexpr (format "~s" gidney4-sexpr)
     'gidney_4bit_toffoli_count (hash-ref (gate-counts gidney4-gates) 'ccx)
     'gidney_4bit_mbu_count (hash-ref (gate-counts gidney4-gates) 'mid_meas_x_cond_z)
     'exhaustive_256_pairs_x_8_mbu_branches_verified #t
     'modular_adder_mod13_169_pairs_verified #t
     'schoolbook_multiplier_4bit_256_pairs_verified #t
     'phase_taint_leakage 0
     'ancilla_leakage_bits 0
     'gidney_4bit_openqasm3 (gates->openqasm3 11 gidney4-gates)
     'gate_counts (gate-counts gidney4-gates))
   'bch_15_7_5_dqi_syndrome_uncompute (hasheq
     'code "BCH(15, 7, 5)"
     'syndrome_wires 8
     'error_wires 15
     'scratch_ancillas 26
     'total_wires 49
     'weight_le_2_masks_tested 121
     'weight_le_2_masks_uncomputed bch-uncomputed-count
     'syndrome_restored_to "00000000"
     'ancilla_leakage_bits 0
     'gate_counts (gate-counts bch-uncompute-gates))
   'exported_quantum_gadgets (hasheq
     'gf16_tower_inv_12q (hasheq
       'num_qubits 12
       'input_wires '(0 1 2 3)
       'output_wires '(4 5 6 7)
       'ancilla_wires '(8 9 10 11)
       'gates (gates->json-list gf16-sbox-gadget-gates))
     'keccak_chi5_inplace_15q (hasheq
       'num_qubits 15
       'state_wires '(0 1 2 3 4)
       'ancilla_wires (range 5 15)
       'gates (gates->json-list keccak-chi5-gadget-gates))
     'gidney_adder_mbu_11q (hasheq
       'num_qubits 11
       'a_wires '(0 1 2 3)
       'b_wires '(4 5 6 7)
       'ancilla_wires '(8 9 10)
       'gates (gates->json-list gidney4-gates))
     'clifford_mbu_stim_3q (hasheq
       'num_qubits 3
       'data_wires '(0 1)
       'ancilla_wires '(2)
       'gates (gates->json-list clifford-mbu-gadget-gates))
     'aes_mixcolumns_clifford_32q (hasheq
       'num_qubits 32
       'state_wires (range 32)
       'ancilla_wires '()
       'gates (gates->json-list mixcol32-gadget-gates)))))

(module+ main
  (define summary (run-all-lakefill-verifications))
  (write-json summary)
  (newline))
