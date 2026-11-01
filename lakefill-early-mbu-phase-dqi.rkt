#lang racket

;; =============================================================================
;; lakefill-early-mbu-phase-dqi.rkt
;; =============================================================================
;; Early-Measurement `MBU` + Phase-Only Syndrome Decoding in Decoded Quantum Interferometry (`DQI`)
;; (`Khattar–Babbush 2025`, arXiv:2510.10967, Unified Under `Law U1 + Law U4`):
;;
;;   1. Standard Stage-3 `erase-by` `DQI` (`Jordan et al. 2024`):
;;      Prepares sum_{wt(e)<=t} w_|e| (-1)^{b.e} |e>_n |H e>_k, keeps ALL `n`
;;      error qubits alive throughout the deep algebraic syndrome decoder D(s),
;;      XORs D(s) into |e>_n -> |0^n>, and applies H^{otimes k} to |s>_k.
;;      Cost: `n + k` live data/syndrome qubits during Stage 3 (`n * tau_dec`
;;      excess `Phi1` idle decoherence volume + `n` target writebacks).
;;
;;   2. Early-`MBU` Phase-Only `DQI` (`Law U4 + Law U1`):
;;      Immediately after Stage 2 (`|s = H e>_k`), measures ALL `n` error qubits
;;      in the X-basis (`M_X -> m in {0,1}^n`) and releases all `n` error wires!
;;      By `Law U4`, `|s>_k` carries linear phase taint `QTainted[m, e]` = (-1)^{m.e}.
;;      In Stage 3, because forall e in S_{<=t}, D(H e) = e (`Law U1`), running
;;      `(within-apply-mbu-parity (compute-parity m D(s) -> p_anc) p_anc sc)`
;;      kicks phase (-1)^{m . D(s)} = (-1)^{m . e}, canceling `QTainted[m, e]` to
;;      `QClean` (`0` taint) with `0` live error qubits during decoding!
;;
;;   3. Verified Bit-for-Bit & Amplitude-for-Amplitude in `#lang racket`:
;;      - `BCH(7, 4, 3)` (`n=7, k_synd=3, t=1`, 8 patterns): live data/syndrome
;;        qubits drop `10 -> 3` (`-70.0%`), complex statevector fidelity = `1.0`
;;        across ALL `128 / 128` (`2^7`) `M_X` outcome vectors `m in {0,1}^7`.
;;      - `BCH(15, 7, 5)` (`n=15, k_synd=8, t=2`, 121 patterns, Peterson-Berlekamp):
;;        live data/syndrome qubits drop `23 -> 8` (`-65.2%`), `m . D(H e) == m . e`
;;        across `121 / 121` weight<=2 errors with `0` scratch leakage, plus negative
;;        controls for `Law U1` (`wt<=1` stub -> `16/121`, `86.8%` corrupted) and
;;        `Law U4` (omitting `(-1)^{m.D(s)}` collapses `DQI` interference to `1/2^k`).
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/format
         racket/math
         json
         "lakefill-core-cryptography-implementations.rkt")

(provide within-apply-mbu-parity-sexpr
         check-early-mbu-dqi-qsub-types
         bch7-syndrome-parity-sexpr
         bch7-standard-dqi-stage3-sexpr
         bch7-early-mbu-phase-stage3-sexpr
         bch15-standard-dqi-stage3-sexpr
         bch15-early-mbu-phase-stage3-sexpr
         bch15-wt1-stub-early-mbu-stage3-sexpr
         run-early-mbu-phase-dqi-verifications)

;; =============================================================================
;; SECTION 1: Unified `Law U1 + Law U4` Combinator & Static `QSub` Typechecker
;; =============================================================================

;; `(within-apply-mbu-parity-sexpr compute-parity-expr p-anc scratch-wires)`
;; Computes single parity bit `p-anc ^= m . D(s)`, applies `(z p-anc)` to kick
;; phase `(-1)^{m . D(s)}`, and uncomputes `(cons p-anc scratch-wires)` to `0`
;; with runtime `(assert-clean ...)` enforcement.
(define (within-apply-mbu-parity-sexpr compute-parity-expr p-anc scratch-wires)
  `(within-apply
    ,compute-parity-expr
    (z ,p-anc)
    ,(cons p-anc scratch-wires)))

;; Static `QSub` (`Law U1 + Law U4`) typechecker for Early-`MBU` Phase-Only `DQI`.
(define (check-early-mbu-dqi-qsub-types label
                                        #:dicke-max-weight dicke-t
                                        #:decoder-radius dec-t
                                        #:early-mx-performed? early-mx?
                                        #:phase-parity-fixup? phase-fixup?)
  (define u1-ok? (<= dicke-t dec-t))
  (define u4-ok? (or (not early-mx?) (and phase-fixup? u1-ok?)))
  (define accepted? (and u1-ok? u4-ok?))
  (hasheq 'circuit label
          'dicke_max_weight dicke-t
          'decoder_invertible_radius dec-t
          'law_u1_erase_by_ok u1-ok?
          'law_u4_zero_taint_before_hadamard_ok u4-ok?
          'qsub_well_typed accepted?
          'syndrome_wire_type_before_h
          (cond
            [(not early-mx?) (if u1-ok? "QClean" "MixedEntangledWithError")]
            [(not phase-fixup?) "QTainted[m, e] (REJECTED before H^k)"]
            [(not u1-ok?) "QTainted[m, e ^ D_stub(H e)] (REJECTED: residual wt-2 taint)"]
            [else "QClean (QTainted[m, e] canceled by (-1)^{m . D(s)})"])))

;; =============================================================================
;; SECTION 2: Complex Statevector Simulator with `Ry`, `Early-M_X`, & Release
;; =============================================================================

;; Bitwise popcount parity `(m & e)` mod 2.
(define (bitmask-dot-parity a b)
  (let loop ([v (bitwise-and a b)] [p 0])
    (if (zero? v)
        p
        (loop (bitwise-and v (sub1 v)) (bitwise-xor p 1)))))

;; Evaluate a circuit list containing standard reversible/quantum gates plus
;; `(ry theta q)` starting from an arbitrary initial statevector `init-sv` on
;; `num-qubits` wires. Enforces `(assert-clean ws)` (`Law U1` zero leakage).
(define (eval-dqi-statevector num-qubits gates [init-sv #f])
  (define dim (arithmetic-shift 1 num-qubits))
  (define sv
    (if init-sv
        (vector-copy init-sv)
        (let ([v (make-vector dim 0.0+0.0i)])
          (vector-set! v 0 1.0+0.0i)
          v)))
  (define inv-sqrt2 (/ 1.0 (sqrt 2.0)))

  (for ([g (in-list gates)])
    (match g
      [`(x ,q)
       (define mask (arithmetic-shift 1 q))
       (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx mask)))
         (define j (bitwise-ior idx mask))
         (define tmp (vector-ref sv idx))
         (vector-set! sv idx (vector-ref sv j))
         (vector-set! sv j tmp))]
      [`(h ,q)
       (define mask (arithmetic-shift 1 q))
       (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx mask)))
         (define j (bitwise-ior idx mask))
         (define a0 (vector-ref sv idx))
         (define a1 (vector-ref sv j))
         (vector-set! sv idx (* inv-sqrt2 (+ a0 a1)))
         (vector-set! sv j (* inv-sqrt2 (- a0 a1))))]
      [`(ry ,theta ,q)
       (define c (cos (/ theta 2.0)))
       (define s (sin (/ theta 2.0)))
       (define mask (arithmetic-shift 1 q))
       (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx mask)))
         (define j (bitwise-ior idx mask))
         (define a0 (vector-ref sv idx))
         (define a1 (vector-ref sv j))
         (vector-set! sv idx (- (* c a0) (* s a1)))
         (vector-set! sv j (+ (* s a0) (* c a1))))]
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
      [`(z ,q)
       (define m (arithmetic-shift 1 q))
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
      [`(assert-clean ,ws)
       (for ([w (in-list ws)])
         (define wm (arithmetic-shift 1 w))
         (define leak-prob
           (for/sum ([idx (in-range dim)]
                     #:when (not (zero? (bitwise-and idx wm))))
             (sqr (magnitude (vector-ref sv idx)))))
         (when (> leak-prob 1e-11)
           (error 'assert-clean
                  "Scratch wire ~a leaked probability ~a > 0!" w leak-prob)))]
      [_ (error 'eval-dqi-statevector "Unsupported gate: ~a" g)]))
  sv)

;; Gate-level `CRy(theta, ctrl, target)` decomposition into 2 `ry` + 2 `cx` (`0` magic ops).
(define (cry-gates theta ctrl target)
  (list `(ry ,(/ theta 2.0) ,target)
        `(cx ,ctrl ,target)
        `(ry ,(- (/ theta 2.0)) ,target)
        `(cx ,ctrl ,target)))

;; Gate-level Bartschi-Eidenbenz weight-<=1 Dicke + Max-XORSAT phase preparation
;; on wires `0 .. n-1`:
;;   |0^n> -> w0 |0^n> + (w1 / sqrt(n)) sum_{j=0}^{n-1} (-1)^{b_j} |e_j>
(define (dicke-le1-max-xorsat-prep-gates n w0 w1 b-mask)
  (define theta0 (* 2.0 (acos w0)))
  (define unary-ladder
    (cons `(ry ,theta0 0)
          (append-map
           (lambda (j)
             (define theta-next (* 2.0 (acos (sqrt (/ 1.0 (- n j))))))
             (cry-gates theta-next j (add1 j)))
           (range 0 (sub1 n)))))
  (define unary->onehot
    (for/list ([j (in-range (sub1 n))])
      `(cx ,(add1 j) ,j)))
  (define phase-gates
    (for/list ([j (in-range n)] #:when (bitwise-bit-set? b-mask j))
      `(z ,j)))
  (append unary-ladder unary->onehot phase-gates))

;; Project `(n-err + k-synd)` statevector (error wires `0 .. n-err-1`, syndrome
;; wires `n-err .. n-err+k-synd-1`) onto X-basis outcome `m-mask in {0,1}^{n-err}`
;; and FREE all `n-err` error wires, returning:
;;   (values reduced-k-synd-sv branch-prob)
;; where `reduced-k-synd-sv` has dimension `2^{k-synd}` (`0` error wires!).
(define (early-mx-project-and-release sv n-err k-synd m-mask)
  (define n-dim (arithmetic-shift 1 n-err))
  (define k-dim (arithmetic-shift 1 k-synd))
  (define scale (/ 1.0 (sqrt (exact->inexact n-dim))))
  (define out-unnorm (make-vector k-dim 0.0+0.0i))
  (for ([s (in-range k-dim)])
    (define base (arithmetic-shift s n-err))
    (define amp
      (for/sum ([e (in-range n-dim)])
        (define raw (vector-ref sv (bitwise-ior base e)))
        (if (zero? (magnitude raw))
            0.0+0.0i
            (* raw (if (= (bitmask-dot-parity m-mask e) 1) -1.0 1.0) scale))))
    (vector-set! out-unnorm s amp))
  (define branch-prob
    (for/sum ([s (in-range k-dim)])
      (sqr (magnitude (vector-ref out-unnorm s)))))
  (define norm (sqrt branch-prob))
  (define out-sv
    (for/vector ([s (in-range k-dim)])
      (/ (vector-ref out-unnorm s) norm)))
  (values out-sv branch-prob))

;; Embed a `k-synd`-qubit statevector on wires `0 .. k-synd-1` with `num-scratch`
;; clean `|0>` ancilla wires at indices `k-synd .. k-synd+num-scratch-1`.
(define (embed-with-clean-scratch k-sv num-scratch)
  (define k-dim (vector-length k-sv))
  (define full-dim (arithmetic-shift k-dim num-scratch))
  (define out (make-vector full-dim 0.0+0.0i))
  (for ([s (in-range k-dim)])
    (vector-set! out s (vector-ref k-sv s)))
  out)

;; Extract `k-synd`-qubit statevector on wires `0 .. k-synd-1` (asserting scratch `== 0`).
(define (extract-low-qubits full-sv k-synd)
  (define k-dim (arithmetic-shift 1 k-synd))
  (for/vector ([s (in-range k-dim)])
    (vector-ref full-sv s)))

;; Statevector fidelity |<psi | phi>|^2 and L2 norm difference ||psi - phi||_2.
(define (statevector-fidelity-and-l2 sv-a sv-b)
  (define ip
    (for/sum ([a (in-vector sv-a)] [b (in-vector sv-b)])
      (* (conjugate a) b)))
  (define l2-sq
    (for/sum ([a (in-vector sv-a)] [b (in-vector sv-b)])
      (sqr (magnitude (- a b)))))
  (values (sqr (magnitude ip)) (sqrt l2-sq)))

;; =============================================================================
;; SECTION 3: `BCH(7, 4, 3)` Standard `erase-by` vs Early-`MBU` Phase-Only `DQI`
;; =============================================================================
;; Parity check H in F_2^{3 x 7} has column `j` = binary representation of `j + 1` (1..7).

(define (bch7-syndrome-parity-sexpr e7 syn3)
  `(seq
    ,@(append-map
       (lambda (j)
         (define col (add1 j))
         (for/list ([r (in-range 3)] #:when (bitwise-bit-set? col r))
           `(cx ,(list-ref e7 j) ,(list-ref syn3 r))))
       (range 7))))

;; Standard Stage-3 `erase-by` `DQI` for `BCH(7, 4, 3)`:
;; Keeps all 7 error wires `e7` + 3 syndrome wires `syn3` (`10` data/syndrome
;; wires + `1` `mcx` scratch wire = `11` total wires) alive, XORing `D(syn3)`
;; into `e7 -> 0000000`!
(define (bch7-standard-dqi-stage3-sexpr syn3 e7 sc1)
  `(seq
    ,@(for/list ([j (in-range 7)])
        (define col (add1 j))
        (define neg-gates
          (for/list ([r (in-range 3)] #:unless (bitwise-bit-set? col r))
            `(x ,(list-ref syn3 r))))
        `(within-apply
          (seq ,@neg-gates)
          (mcx ,syn3 ,(list-ref e7 j) ,sc1)
          ,sc1))
    (assert-clean ,(append e7 sc1))))

;; Early-`MBU` Phase-Only Stage-3 `DQI` for `BCH(7, 4, 3)` (`Law U4 + Law U1`):
;; Error wires `e7` were ALREADY measured via `M_X -> m-mask` and released!
;; Runs on ONLY `3` syndrome wires `syn3` + `p-anc` + `sc1` (`0` live error wires!).
;; Preparing `p-anc` in `|-> = H X |0>` turns each masked parity writeback into a
;; single-pass phase kickback `(-1)^{D(s)_j}`, cutting average `CCX` count by `50%`
;; (`21 -> 10.5` `CCX`) while restoring `p-anc -> |0>` cleanly; `#:kickback? #f`
;; emits the basis-mode `(within-apply (compute-parity -> p_anc) (z p_anc))` form.
(define (bch7-early-mbu-phase-stage3-sexpr m-mask syn3 p-anc sc1 #:kickback? [kickback? #t])
  (define active-coords
    (for/list ([j (in-range 7)] #:when (bitwise-bit-set? m-mask j)) j))
  (define parity-sweep-sexpr
    `(seq
      ,@(for/list ([j (in-list active-coords)])
          (define col (add1 j))
          (define neg-gates
            (for/list ([r (in-range 3)] #:unless (bitwise-bit-set? col r))
              `(x ,(list-ref syn3 r))))
          `(within-apply
            (seq ,@neg-gates)
            (mcx ,syn3 ,p-anc ,sc1)
            ,sc1))))
  (cond
    [(null? active-coords)
     `(assert-clean ,(cons p-anc sc1))]
    [kickback?
     `(within-apply
       (seq (x ,p-anc) (h ,p-anc))
       ,parity-sweep-sexpr
       ,(cons p-anc sc1))]
    [else
     (within-apply-mbu-parity-sexpr parity-sweep-sexpr p-anc sc1)]))

;; =============================================================================
;; SECTION 4: `BCH(15, 7, 5)` Standard `erase-by` vs Early-`MBU` Phase-Only `DQI`
;; =============================================================================
;; Field `GF(2^4) = GF(2)[a] / (a^4 + a + 1)` (`#x13`).

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

(define (gf16-poly-mul-xor-sexpr a4 b4 out4)
  `(seq
    ,@(append*
       (for*/list ([i (in-range 4)] [j (in-range 4)])
         (define prod (gf16-poly-pow 2 (+ i j)))
         (for/list ([bit (in-range 4)] #:when (bitwise-bit-set? prod bit))
           `(ccx ,(list-ref a4 i) ,(list-ref b4 j) ,(list-ref out4 bit)))))))

(define (gf16-poly-const-mul-xor-sexpr const-val x4 out4)
  `(seq
    ,@(append*
       (for/list ([i (in-range 4)])
         (define prod (gf16-poly-mul const-val (arithmetic-shift 1 i)))
         (for/list ([bit (in-range 4)] #:when (bitwise-bit-set? prod bit))
           `(cx ,(list-ref x4 i) ,(list-ref out4 bit)))))))

;; Exact 3-gate in-place isomorphism between tower `GF((2^2)^2)` basis `{1, u, v, uv}`
;; (`u = a^2 + a = #x6`, `v = a = #x2`, `uv = a^3 + a^2 = #xc`) and `GF(2)[a]/(a^4 + a + 1)`.
(define (gf16-tower->poly-inplace-sexpr w4)
  (match-define (list _w0 w1 w2 w3) w4)
  `(seq (swap ,w1 ,w2)
        (cx ,w2 ,w1)
        (cx ,w3 ,w2)))

(define (gf16-poly-inv-xor-sexpr x4 out4 sc4)
  `(seq (within-apply
         (invert ,(gf16-tower->poly-inplace-sexpr x4))
         ,(gf16-tower-inv-sexpr x4 out4 sc4)
         ,sc4)
        ,(gf16-tower->poly-inplace-sexpr out4)))

(define (bch15-syndrome-parity-sexpr e15 syn8)
  (define s1-wires (take syn8 4))
  (define s3-wires (drop syn8 4))
  `(seq
    ,@(append*
       (for/list ([i (in-range 15)])
         (define p1 (gf16-poly-pow 2 i))
         (define p3 (gf16-poly-pow 2 (* 3 i)))
         (append
          (for/list ([b (in-range 4)] #:when (bitwise-bit-set? p1 b))
            `(cx ,(list-ref e15 i) ,(list-ref s1-wires b)))
          (for/list ([b (in-range 4)] #:when (bitwise-bit-set? p3 b))
            `(cx ,(list-ref e15 i) ,(list-ref s3-wires b))))))))

;; Helper building the reversible Peterson-Berlekamp key-equation compute block:
;; Given `syn8 = (S_1, S_3)` on 8 wires and `sc20 = (s1-sq, num, s1-inv, sigma2, sub-sc)`:
;; computes `sigma2 = (S_3 ^ S_1^3) * S_1^{14}` in `GF(2)[a]/(a^4 + a + 1)`.
(define (bch15-peterson-key-eq-compute-sexpr s1 s3 s1-sq num s1-inv sigma2 sub-sc)
  ;; Squaring matrix in GF(2)[a]/(a^4 + a + 1):
  ;; 1^2 = 1 (#x1), a^2 = a^2 (#x4), (a^2)^2 = a+1 (#x3), (a^3)^2 = a^3+a^2 (#xc)
  `(seq
    ;; s1-sq <- S_1^2 via exact linear CX network
    (cx ,(list-ref s1 0) ,(list-ref s1-sq 0))
    (cx ,(list-ref s1 2) ,(list-ref s1-sq 0))
    (cx ,(list-ref s1 2) ,(list-ref s1-sq 1))
    (cx ,(list-ref s1 1) ,(list-ref s1-sq 2))
    (cx ,(list-ref s1 3) ,(list-ref s1-sq 2))
    (cx ,(list-ref s1 3) ,(list-ref s1-sq 3))
    ;; num <- S_3 ^ (s1-sq * S_1) = S_3 ^ S_1^3
    ,@(for/list ([w (in-list s3)] [dst (in-list num)]) `(cx ,w ,dst))
    ,(gf16-poly-mul-xor-sexpr s1-sq s1 num)
    ;; s1-inv <- S_1^{14} (`0^-1 = 0`)
    ,(gf16-poly-inv-xor-sexpr s1 s1-inv sub-sc)
    ;; sigma2 <- num * s1-inv = (S_3 ^ S_1^3) * S_1^{14}
    ,(gf16-poly-mul-xor-sexpr num s1-inv sigma2)))

;; Standard Stage-3 `erase-by` `DQI` for `BCH(15, 7, 5)`:
;; Keeps ALL `15` error wires `e15` + `8` syndrome wires `syn8` (`23` live
;; data/syndrome wires + `26` scratch = `49` total wires), XORs `D(syn8)` into
;; `e15 -> 0^15`, and preserves `syn8 = H e` intact for Stage-4 `H^{otimes 8}`!
(define (bch15-standard-dqi-stage3-sexpr syn8 e15 sc26)
  (define s1     (take syn8 4))
  (define s3     (drop syn8 4))
  (define s1-sq  (take sc26 4))
  (define num    (take (drop sc26 4) 4))
  (define s1-inv (take (drop sc26 8) 4))
  (define sigma2 (take (drop sc26 12) 4))
  (define lam    (take (drop sc26 16) 4))
  (define sub-sc (take (drop sc26 20) 4))
  (define mcx-sc (drop sc26 24))
  `(seq
    (within-apply
     ,(bch15-peterson-key-eq-compute-sexpr s1 s3 s1-sq num s1-inv sigma2 sub-sc)
     (seq
      ,@(for/list ([i (in-range 15)])
          (define x-inv (gf16-poly-pow 2 (- 15 (modulo i 15))))
          (define x-inv-sq (gf16-poly-mul x-inv x-inv))
          `(within-apply
            (seq
             (x ,(first lam))
             ,(gf16-poly-const-mul-xor-sexpr x-inv s1 lam)
             ,(gf16-poly-const-mul-xor-sexpr x-inv-sq sigma2 lam)
             ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
            (mcx ,lam ,(list-ref e15 i) ,mcx-sc)
            ,(append lam mcx-sc))))
     ,sc26)
    (assert-clean ,(append e15 sc26))))

;; Early-`MBU` Phase-Only Stage-3 `DQI` for `BCH(15, 7, 5)` (`Law U4 + Law U1`):
;; `15` error wires were ALREADY measured in X-basis (`M_X -> m-mask`) and released!
;; Holds ONLY `8` live syndrome wires (`-65.22%` live data/syndrome width vs `23`!)
;; + `1` parity ancilla `p-anc` + `26` scratch wires (`35` total wires vs `49`).
;; Computes Peterson-Berlekamp key equation ONCE, then runs `(within-apply-mbu-parity ...)`
;; over ONLY coordinates `i` where bit `i` of `m-mask` is `1`, kicking `(z p-anc)` and
;; uncomputing `p-anc` and `sc26` cleanly to `0`!
(define (bch15-early-mbu-phase-stage3-sexpr m-mask syn8 p-anc sc26)
  (define active-coords
    (for/list ([i (in-range 15)] #:when (bitwise-bit-set? m-mask i)) i))
  (if (null? active-coords)
      `(assert-clean ,(cons p-anc sc26))
      (let ([s1     (take syn8 4)]
            [s3     (drop syn8 4)]
            [s1-sq  (take sc26 4)]
            [num    (take (drop sc26 4) 4)]
            [s1-inv (take (drop sc26 8) 4)]
            [sigma2 (take (drop sc26 12) 4)]
            [lam    (take (drop sc26 16) 4)]
            [sub-sc (take (drop sc26 20) 4)]
            [mcx-sc (drop sc26 24)])
        `(within-apply
          ,(bch15-peterson-key-eq-compute-sexpr s1 s3 s1-sq num s1-inv sigma2 sub-sc)
          ,(within-apply-mbu-parity-sexpr
            `(seq
              ,@(for/list ([i (in-list active-coords)])
                  (define x-inv (gf16-poly-pow 2 (- 15 (modulo i 15))))
                  (define x-inv-sq (gf16-poly-mul x-inv x-inv))
                  `(within-apply
                    (seq
                     (x ,(first lam))
                     ,(gf16-poly-const-mul-xor-sexpr x-inv s1 lam)
                     ,(gf16-poly-const-mul-xor-sexpr x-inv-sq sigma2 lam)
                     ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                    (mcx ,lam ,p-anc ,mcx-sc)
                    ,(append lam mcx-sc))))
            p-anc
            (append lam mcx-sc))
          ,(cons p-anc sc26)))))

;; Negative Control (`Law U1` violation): incomplete `wt <= 1` Hamming stub
;; phase-only decoder ignoring `S_3` and `sigma_2` (`1 + S_1 * a^{-i} == 0`).
;; Succeeds on `16 / 121` patterns (`wt <= 1`) and corrupts `105 / 121` (`86.8%`) wt-2 patterns!
(define (bch15-wt1-stub-early-mbu-stage3-sexpr m-mask syn8 p-anc sc6)
  (define active-coords
    (for/list ([i (in-range 15)] #:when (bitwise-bit-set? m-mask i)) i))
  (if (null? active-coords)
      `(assert-clean ,(cons p-anc sc6))
      (let ([s1     (take syn8 4)]
            [lam    (take sc6 4)]
            [mcx-sc (drop sc6 4)])
        (within-apply-mbu-parity-sexpr
         `(seq
           ,@(for/list ([i (in-list active-coords)])
               (define x-inv (gf16-poly-pow 2 (- 15 (modulo i 15))))
               `(within-apply
                 (seq
                  (x ,(first lam))
                  ,(gf16-poly-const-mul-xor-sexpr x-inv s1 lam)
                  ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                 (mcx ,lam ,p-anc ,mcx-sc)
                 ,(append lam mcx-sc))))
         p-anc
         sc6))))

;; =============================================================================
;; SECTION 5: End-to-End Verification Runner (`BCH(7,4,3)` + `BCH(15,7,5)`)
;; =============================================================================

;; Compute 8-bit syndrome integer `(S_1 | (S_3 << 4))` for 15-bit error mask `e`.
(define (bch15-syndrome-int e-mask)
  (define-values (s1 s3)
    (for/fold ([s1 0] [s3 0]) ([i (in-range 15)] #:when (bitwise-bit-set? e-mask i))
      (values (bitwise-xor s1 (gf16-poly-pow 2 i))
              (bitwise-xor s3 (gf16-poly-pow 2 (* 3 i))))))
  (bitwise-ior s1 (arithmetic-shift s3 4)))

;; Compute H^T * x for `BCH(7, 4, 3)` (`x in 0..7` -> 7-bit codeword).
(define (bch7-ht-mul x)
  (for/sum ([j (in-range 7)])
    (define col (add1 j))
    (if (= (bitmask-dot-parity col x) 1) (arithmetic-shift 1 j) 0)))

;; Compute H^T * x for `BCH(15, 7, 5)` (`x in 0..255` -> 15-bit dual codeword).
(define (bch15-ht-mul x)
  (for/sum ([i (in-range 15)])
    (define col (bitwise-ior (gf16-poly-pow 2 i)
                             (arithmetic-shift (gf16-poly-pow 2 (* 3 i)) 4)))
    (if (= (bitmask-dot-parity col x) 1) (arithmetic-shift 1 i) 0)))

(define (run-early-mbu-phase-dqi-verifications)
  (define t0 (current-inexact-milliseconds))

  ;; ---------------------------------------------------------------------------
  ;; 1. Static `QSub` Type-Judgment Verification (`Law U1 + Law U4`)
  ;; ---------------------------------------------------------------------------
  (define qsub-bch7-accept
    (check-early-mbu-dqi-qsub-types
     "BCH(7,4,3)_EarlyMBU_PhaseOnly_DQI"
     #:dicke-max-weight 1 #:decoder-radius 1
     #:early-mx-performed? #t #:phase-parity-fixup? #t))
  (define qsub-bch15-accept
    (check-early-mbu-dqi-qsub-types
     "BCH(15,7,5)_PetersonBerlekamp_EarlyMBU_PhaseOnly_DQI"
     #:dicke-max-weight 2 #:decoder-radius 2
     #:early-mx-performed? #t #:phase-parity-fixup? #t))
  (define qsub-bch15-u1-reject
    (check-early-mbu-dqi-qsub-types
     "BCH(15,7,5)_Wt1HammingStub_EarlyMBU_DQI"
     #:dicke-max-weight 2 #:decoder-radius 1
     #:early-mx-performed? #t #:phase-parity-fixup? #t))
  (define qsub-u4-reject
    (check-early-mbu-dqi-qsub-types
     "EarlyMBU_Without_ParityPhaseFixup_DQI"
     #:dicke-max-weight 2 #:decoder-radius 2
     #:early-mx-performed? #t #:phase-parity-fixup? #f))

  (unless (and (hash-ref qsub-bch7-accept 'qsub_well_typed)
               (hash-ref qsub-bch15-accept 'qsub_well_typed)
               (not (hash-ref qsub-bch15-u1-reject 'qsub_well_typed))
               (not (hash-ref qsub-u4-reject 'qsub_well_typed)))
    (error 'qsub-typecheck "Static QSub U1+U4 check failed!"))

  ;; ---------------------------------------------------------------------------
  ;; 2. `BCH(7, 4, 3)`: Complex Statevector Verification Across ALL `128 / 128`
  ;;    (`2^7`) `M_X` Outcome Vectors `m in {0,1}^7`
  ;; ---------------------------------------------------------------------------
  ;; Frustrated Max-XORSAT instance: planted x* = 5 (0b101), flipped clause 0 ->
  ;; 6/7 clauses satisfied at x* = 5 (unique global optimum!).
  ;; Optimal DQI weights on wt<=1: w0 = sqrt(7/32), w1 = sqrt(25/32) -> P(x*) = 4/7!
  (define x-star-7 5)
  (define b-mask-7 (bitwise-xor (bch7-ht-mul x-star-7) 1))
  (define w0-bch7 (sqrt (/ 7.0 32.0)))
  (define w1-bch7 (sqrt (/ 25.0 32.0)))

  ;; Stage 1 + Stage 2 on 10 qubits (`e[0..6]`, `s[7..9]`)
  (define bch7-stage12-gates
    (append (dicke-le1-max-xorsat-prep-gates 7 w0-bch7 w1-bch7 b-mask-7)
            (compile-lakefill (bch7-syndrome-parity-sexpr '(0 1 2 3 4 5 6) '(7 8 9)))))
  (define sv-bch7-stage12 (eval-dqi-statevector 10 bch7-stage12-gates))

  ;; 2A. Standard `erase-by` `DQI` on 11 qubits (`e[0..6]`, `s[7..9]`, `sc[10]`):
  ;;     10 live error+syndrome qubits during Stage 3!
  (define bch7-std-stage3-gates
    (compile-lakefill (bch7-standard-dqi-stage3-sexpr '(7 8 9) '(0 1 2 3 4 5 6) '(10))))
  (define bch7-std-stage34-gates
    (append bch7-std-stage3-gates '((h 7) (h 8) (h 9))))
  (define sv-bch7-std-11q
    (eval-dqi-statevector 11 bch7-std-stage34-gates (embed-with-clean-scratch sv-bch7-stage12 1)))
  ;; Since `e[0..6]` and `sc[10]` are asserted clean `|0^7>|0>`, amplitudes live at `s << 7`!
  (define sv-bch7-std-out
    (for/vector ([x (in-range 8)])
      (vector-ref sv-bch7-std-11q (arithmetic-shift x 7))))
  (define prob-xstar-std-7 (sqr (magnitude (vector-ref sv-bch7-std-out x-star-7))))
  (unless (< (abs (- prob-xstar-std-7 (/ 4.0 7.0))) 1e-12)
    (error 'bch7-std "Expected optimal DQI P(x*)=4/7, got ~a" prob-xstar-std-7))

  ;; 2B. Early-`MBU` Phase-Only `DQI` across ALL `128 / 128` (`2^7`) `M_X` branches `m`!
  ;;     Error wires `0..6` released before Stage 3 -> ONLY `3` live syndrome wires
  ;;     `0..2` (+ 2 scratch wires `3, 4` = `5` total wires vs `11`!).
  (define bch7-exact-branches 0)
  (define bch7-min-fidelity 1.0)
  (define bch7-max-l2-diff 0.0)
  (define bch7-total-early-ccx 0)
  (define unfixed-avg-probs (make-vector 8 0.0))

  (for ([m (in-range 128)])
    (define-values (sv-tainted-3q branch-prob)
      (early-mx-project-and-release sv-bch7-stage12 7 3 m))
    (unless (< (abs (- branch-prob (/ 1.0 128.0))) 1e-12)
      (error 'bch7-early "Expected uniform M_X branch prob 1/128, got ~a" branch-prob))

    (define early-stage3-gates
      (compile-lakefill (bch7-early-mbu-phase-stage3-sexpr m '(0 1 2) 3 '(4))))
    (set! bch7-total-early-ccx
          (+ bch7-total-early-ccx (hash-ref (gate-counts early-stage3-gates) 'ccx)))

    (define sv-early-5q
      (eval-dqi-statevector
       5
       (append early-stage3-gates '((h 0) (h 1) (h 2)))
       (embed-with-clean-scratch sv-tainted-3q 2)))
    (define sv-early-out (extract-low-qubits sv-early-5q 3))
    (define-values (fid l2) (statevector-fidelity-and-l2 sv-bch7-std-out sv-early-out))
    (set! bch7-min-fidelity (min bch7-min-fidelity fid))
    (set! bch7-max-l2-diff (max bch7-max-l2-diff l2))
    (when (< (abs (- fid 1.0)) 1e-12)
      (set! bch7-exact-branches (add1 bch7-exact-branches)))

    ;; Negative Control (`Law U4` violated): apply `H^{\otimes 3}` directly to `QTainted[m, e]`
    ;; WITHOUT `(within-apply-mbu-parity ...)`!
    (define sv-unfixed-out
      (eval-dqi-statevector 3 '((h 0) (h 1) (h 2)) sv-tainted-3q))
    (for ([x (in-range 8)])
      (vector-set! unfixed-avg-probs x
                   (+ (vector-ref unfixed-avg-probs x)
                      (* branch-prob (sqr (magnitude (vector-ref sv-unfixed-out x))))))))

  (unless (= bch7-exact-branches 128)
    (error 'bch7-early "Only ~a / 128 branches matched Standard DQI!" bch7-exact-branches))
  (define prob-xstar-u4-violated-7 (vector-ref unfixed-avg-probs x-star-7))
  (unless (< (abs (- prob-xstar-u4-violated-7 0.125)) 1e-12)
    (error 'bch7-u4-neg "Expected uniform 0.125 collapse on Law U4 violation, got ~a"
           prob-xstar-u4-violated-7))

  ;; ---------------------------------------------------------------------------
  ;; 3. `BCH(15, 7, 5)` (`n=15, k_synd=8, t=2`, 121 patterns, Peterson-Berlekamp):
  ;;    Live Data/Syndrome Qubits Drop `23 -> 8` (`-65.2%`)!
  ;; ---------------------------------------------------------------------------
  (define bch15-masks
    (append (list 0)
            (for/list ([i (in-range 15)]) (arithmetic-shift 1 i))
            (for*/list ([i (in-range 15)] [j (in-range i)])
              (bitwise-ior (arithmetic-shift 1 i) (arithmetic-shift 1 j)))))
  (unless (= (length bch15-masks) 121)
    (error 'bch15 "Expected 121 weight<=2 masks, got ~a" (length bch15-masks)))

  ;; 3A. Verify Standard Stage-3 `erase-by` `DQI` (`49` wires: `8` syn + `15` err + `26` sc;
  ;;     `23` live error+syndrome wires) across all `121 / 121` error patterns!
  (define bch15-syn-encode-gates
    (compile-lakefill (bch15-syndrome-parity-sexpr (range 8 23) (range 0 8))))
  (define bch15-std-stage3-gates
    (compile-lakefill (bch15-standard-dqi-stage3-sexpr (range 0 8) (range 8 23) (range 23 49))))

  (define bch15-std-clean-count
    (for/sum ([e-mask (in-list bch15-masks)])
      (define reg (make-vector 49 0))
      (for ([i (in-range 15)] #:when (bitwise-bit-set? e-mask i))
        (vector-set! reg (+ 8 i) 1))
      (eval-reversible-gates! reg bch15-syn-encode-gates)
      (define ph (eval-reversible-gates! reg bch15-std-stage3-gates))
      (define got-syn
        (for/sum ([b (in-range 8)]) (arithmetic-shift (vector-ref reg b) b)))
      (define err-and-sc-zero?
        (for/and ([w (in-range 8 49)]) (= (vector-ref reg w) 0)))
      (if (and (= ph 1) (= got-syn (bch15-syndrome-int e-mask)) err-and-sc-zero?) 1 0)))
  (unless (= bch15-std-clean-count 121)
    (error 'bch15-std "Standard DQI Stage 3 cleaned ~a / 121!" bch15-std-clean-count))

  ;; 3B. Verify Early-`MBU` Phase-Only Stage-3 `DQI` (`35` wires: `8` syn + `1` p_anc + `26` sc;
  ;;     ONLY `8` live syndrome wires, `0` live error wires!) across ALL `121` error patterns
  ;;     and ALL `15` single-bit basis `M_X` masks `2^j` (proving `D(H e)_j == e_j` on every
  ;;     coordinate!) PLUS `9` dense/representative 15-bit `M_X` masks (`24 * 121 = 2,904` runs)!
  (define basis-mx-masks (for/list ([j (in-range 15)]) (arithmetic-shift 1 j)))
  (define dense-mx-masks
    (list #x0000 #x7fff #x5555 #x2aaa #x3333 #x0f0f #x70f0 #x1d4b #x6ace))
  (define tested-bch15-mx-masks (append basis-mx-masks dense-mx-masks))

  (define compiled-early-bch15-table
    (for/hash ([m (in-list tested-bch15-mx-masks)])
      (values m (compile-lakefill
                 (bch15-early-mbu-phase-stage3-sexpr m (range 0 8) 8 (range 9 35))))))

  (define bch15-early-exact-patterns
    (for/sum ([e-mask (in-list bch15-masks)])
      (define syn-val (bch15-syndrome-int e-mask))
      (define all-masks-ok?
        (for/and ([m (in-list tested-bch15-mx-masks)])
          (define reg (make-vector 35 0))
          (for ([b (in-range 8)] #:when (bitwise-bit-set? syn-val b))
            (vector-set! reg b 1))
          (define ph-fixup
            (eval-reversible-gates! reg (hash-ref compiled-early-bch15-table m)))
          (define mx-taint (if (= (bitmask-dot-parity m e-mask) 1) -1 1))
          (define syn-preserved?
            (= (for/sum ([b (in-range 8)]) (arithmetic-shift (vector-ref reg b) b)) syn-val))
          (define sc-clean?
            (for/and ([w (in-range 8 35)]) (= (vector-ref reg w) 0)))
          ;; Law U4 cancellation: `mx-taint * ph-fixup == +1`!
          (and (= (* mx-taint ph-fixup) 1) syn-preserved? sc-clean?)))
      (if all-masks-ok? 1 0)))
  (unless (= bch15-early-exact-patterns 121)
    (error 'bch15-early "Early-MBU BCH(15,7,5) exact on ~a / 121 patterns!"
           bch15-early-exact-patterns))

  ;; 3C. Negative Control (`Law U1` violation: `wt<=1` Hamming stub on `BCH(15, 7, 5)`):
  ;;     Verify across the 15 single-bit basis masks how many of the 121 patterns satisfy
  ;;     `forall j, e_j == D_stub(H e)_j`: exactly `16 / 121` (`105 / 121 = 86.78%` corrupted!).
  (define compiled-stub-basis
    (for/list ([j (in-range 15)])
      (compile-lakefill
       (bch15-wt1-stub-early-mbu-stage3-sexpr (arithmetic-shift 1 j) (range 0 8) 8 (range 9 15)))))
  (define bch15-stub-exact-patterns
    (for/sum ([e-mask (in-list bch15-masks)])
      (define syn-val (bch15-syndrome-int e-mask))
      (define stub-decoded-mask
        (for/sum ([j (in-range 15)] [gates-j (in-list compiled-stub-basis)])
          (define reg (make-vector 15 0))
          (for ([b (in-range 8)] #:when (bitwise-bit-set? syn-val b))
            (vector-set! reg b 1))
          (define ph (eval-reversible-gates! reg gates-j))
          (if (= ph -1) (arithmetic-shift 1 j) 0)))
      (if (= stub-decoded-mask e-mask) 1 0)))
  (unless (= bch15-stub-exact-patterns 16)
    (error 'bch15-stub "Expected 16 / 121 for wt<=1 stub, got ~a!" bch15-stub-exact-patterns))

  ;; 3D. Full 8-Qubit `BCH(15, 7, 5)` `DQI` Walsh-Hadamard Interference Statevector Check
  ;;     across all `9` dense `M_X` masks `m`:
  ;;     Planted `x* = 173` (`0b10101101`), frustrated by 2-bit error `(1 | 4)` -> `13/15` satisfied!
  (define x-star-15 173)
  (define b-mask-15 (bitwise-xor (bch15-ht-mul x-star-15) #b0000101))
  (define amp-wt (/ 1.0 (sqrt 121.0)))
  (define h8-gates (for/list ([q (in-range 8)]) `(h ,q)))

  ;; Reference Standard DQI 8-qubit syndrome statevector before & after H^{\otimes 8}:
  (define sv-bch15-clean-syn (make-vector 256 0.0+0.0i))
  (for ([e-mask (in-list bch15-masks)])
    (define s (bch15-syndrome-int e-mask))
    (define sign (if (= (bitmask-dot-parity b-mask-15 e-mask) 1) -1.0 1.0))
    (vector-set! sv-bch15-clean-syn s (* sign amp-wt)))
  (define sv-bch15-std-out (eval-dqi-statevector 8 h8-gates sv-bch15-clean-syn))
  (define prob-xstar-std-15 (sqr (magnitude (vector-ref sv-bch15-std-out x-star-15))))

  ;; Evaluate Early-MBU Phase-Only DQI (`Law U1 + Law U4` vs `Law U1` stub vs `Law U4` omitted)
  ;; across the 9 dense 15-bit `M_X` masks using the gate-level Lakefill phase circuits!
  (define bch15-sv-min-fid 1.0)
  (define bch15-stub-fid-sum 0.0)
  (define bch15-u4-unfixed-fid-sum 0.0)

  (for ([m (in-list dense-mx-masks)])
    (define early-gates (hash-ref compiled-early-bch15-table m))
    (define stub-gates
      (compile-lakefill (bch15-wt1-stub-early-mbu-stage3-sexpr m (range 0 8) 8 (range 9 15))))
    (define sv-tainted (make-vector 256 0.0+0.0i))
    (define sv-fixed (make-vector 256 0.0+0.0i))
    (define sv-stub (make-vector 256 0.0+0.0i))

    (for ([e-mask (in-list bch15-masks)])
      (define s (bch15-syndrome-int e-mask))
      (define b-sign (if (= (bitmask-dot-parity b-mask-15 e-mask) 1) -1.0 1.0))
      (define mx-taint (if (= (bitmask-dot-parity m e-mask) 1) -1.0 1.0))
      (define tainted-amp (* b-sign mx-taint amp-wt))
      (vector-set! sv-tainted s tainted-amp)

      (define reg35 (make-vector 35 0))
      (define reg15 (make-vector 15 0))
      (for ([bit (in-range 8)] #:when (bitwise-bit-set? s bit))
        (vector-set! reg35 bit 1)
        (vector-set! reg15 bit 1))
      (define ph-pb (eval-reversible-gates! reg35 early-gates))
      (define ph-st (eval-reversible-gates! reg15 stub-gates))
      (vector-set! sv-fixed s (* tainted-amp ph-pb))
      (vector-set! sv-stub s (* tainted-amp ph-st)))

    (define sv-early-out (eval-dqi-statevector 8 h8-gates sv-fixed))
    (define sv-stub-out (eval-dqi-statevector 8 h8-gates sv-stub))
    (define sv-unfixed-out (eval-dqi-statevector 8 h8-gates sv-tainted))

    (define-values (fid-pb _l2-pb) (statevector-fidelity-and-l2 sv-bch15-std-out sv-early-out))
    (define-values (fid-st _l2-st) (statevector-fidelity-and-l2 sv-bch15-std-out sv-stub-out))
    (define-values (fid-uf _l2-uf) (statevector-fidelity-and-l2 sv-bch15-std-out sv-unfixed-out))
    (set! bch15-sv-min-fid (min bch15-sv-min-fid fid-pb))
    (set! bch15-stub-fid-sum (+ bch15-stub-fid-sum fid-st))
    (set! bch15-u4-unfixed-fid-sum (+ bch15-u4-unfixed-fid-sum fid-uf)))

  (unless (< (abs (- bch15-sv-min-fid 1.0)) 1e-12)
    (error 'bch15-sv "Expected fidelity 1.0 on BCH(15,7,5) Early-MBU DQI, got ~a"
           bch15-sv-min-fid))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))
  (define bch15-half-wt-gates
    (hash-ref compiled-early-bch15-table #x5555))

  (hasheq
   'suite "Lakefill Early-MBU Phase-Only DQI (Law U1 + Law U4)"
   'status "PASS"
   'racket_version (version)
   'wall_time_ms (real->decimal-string elapsed-ms 2)
   'qsub_static_type_judgments (list qsub-bch7-accept
                                     qsub-bch15-accept
                                     qsub-bch15-u1-reject
                                     qsub-u4-reject)
   'bch_7_4_3_early_mbu_dqi (hasheq
     'code "BCH(7, 4, 3)"
     'n_error_qubits 7
     'k_syndrome_qubits 3
     't_radius 1
     'dicke_patterns 8
     'standard_dqi_live_data_syndrome_qubits 10
     'early_mbu_live_data_syndrome_qubits 3
     'live_error_qubits_during_decoding 0
     'live_data_syndrome_width_reduction_pct 70.0
     'standard_dqi_total_stage3_wires 11
     'early_mbu_total_stage3_wires 5
     'mx_branches_tested 128
     'mx_branches_exact_fidelity_1 128
     'min_branch_statevector_fidelity bch7-min-fidelity
     'max_branch_l2_norm_diff bch7-max-l2-diff
     'optimal_solution_x_star x-star-7
     'dqi_optimal_prob_standard prob-xstar-std-7
     'dqi_optimal_prob_early_mbu prob-xstar-std-7
     'dqi_optimal_prob_law_u4_violated prob-xstar-u4-violated-7
     'standard_stage3_ccx_count (hash-ref (gate-counts bch7-std-stage3-gates) 'ccx)
     'early_mbu_avg_stage3_ccx_count (/ (exact->inexact bch7-total-early-ccx) 128.0))
   'bch_15_7_5_early_mbu_dqi (hasheq
     'code "BCH(15, 7, 5)"
     'n_error_qubits 15
     'k_syndrome_qubits 8
     't_radius 2
     'dicke_patterns 121
     'standard_dqi_live_data_syndrome_qubits 23
     'early_mbu_live_data_syndrome_qubits 8
     'live_error_qubits_during_decoding 0
     'live_data_syndrome_width_reduction_pct (real->decimal-string (* 100.0 (/ 15.0 23.0)) 2)
     'standard_dqi_total_stage3_wires 49
     'early_mbu_total_stage3_wires 35
     'standard_stage3_patterns_clean bch15-std-clean-count
     'early_mbu_patterns_exact_parity bch15-early-exact-patterns
     'mx_masks_tested_per_pattern (length tested-bch15-mx-masks)
     'total_gate_level_runs (* 121 (length tested-bch15-mx-masks))
     'ancilla_leakage_bits 0
     'min_dqi_interference_fidelity_peterson_berlekamp bch15-sv-min-fid
     'optimal_solution_x_star x-star-15
     'dqi_optimal_prob_standard prob-xstar-std-15
     'law_u1_violation_wt1_stub_exact_patterns bch15-stub-exact-patterns
     'law_u1_violation_wt1_stub_corrupted_patterns (- 121 bch15-stub-exact-patterns)
     'law_u1_violation_corrupted_pct (real->decimal-string (* 100.0 (/ 105.0 121.0)) 2)
     'law_u1_violation_avg_dqi_fidelity (/ bch15-stub-fid-sum (length dense-mx-masks))
     'law_u4_violation_avg_dqi_fidelity (/ bch15-u4-unfixed-fid-sum (length dense-mx-masks))
     'law_u4_violation_expected_uniform_prob (/ 1.0 256.0)
     'standard_stage3_gate_counts (gate-counts bch15-std-stage3-gates)
     'early_mbu_stage3_half_weight_gate_counts (gate-counts bch15-half-wt-gates))))

(module+ main
  (define summary (run-early-mbu-phase-dqi-verifications))
  (write-json summary)
  (newline))
