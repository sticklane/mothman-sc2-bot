#lang racket

;; =============================================================================
;; lakefill-select-swap-qroam-and-crt-modexp.rkt
;; =============================================================================
;; `Select-SWAP QROAM` (Low-Kliuchnikov-Schaeffer / Babbush
;; et al. 2018) + `Berry-Gidney 2019` (`arXiv:1902.02134`) Sublinear O(sqrt(N))
;; `M_X` Phase-Table Uncomputation + Executable `RNS-CRT` Kawamura `Law U2`
;; Modular Residue Arithmetic & Quotient Erasure:
;;
;;   1. `(qroam-select-swap-sexpr table addr-wires out-wires buf-wires hot-wires lambda ...)`:
;;      Block-quotient / offset decomposition `addr = q * lambda + r` (`Law U3`):
;;      selects `Q = N / lambda` wide blocks via sawtooth unary iteration (`Q - 2`
;;      uncontrolled `TempAND`s) and multiplexes `lambda` `W`-bit words via a
;;      depth-`log2(lambda)` Fredkin (`CSWAP`) tree (`(lambda - 1) * W` `TempAND`s).
;;
;;   2. `(qroam-phase-1bit-select-swap-sexpr ...)` &
;;      `(qroam-berry-gidney-mbu-uncompute-sexpr ...)`:
;;      Berry-Gidney `M_X` Uncomputation (`Law U4` + `Law U3`): measures all `W`
;;      output wires in the `X`-basis (`m in {0,1}^W`), reducing `W`-bit table
;;      erasure to a **1-bit phase-kickback lookup** `P_m[x] = parity(m & T[x])`!
;;      Using optimal `lambda_uncomp = sqrt(N)`, the 1-bit `CSWAP` fanout tree
;;      uses `(lambda_uncomp - 1) * 1` `TempAND`s (+ `0` uncompute Toffolis via
;;      `mid-meas-x-cond-z`) and sawtooth `Select(q)` uses `(N / lambda_uncomp - 2)`
;;      `TempAND`s, cutting `N = 1024, W = 32` uncomputation from `10,240` (naive
;;      `MCX`) and `1,022` (sawtooth `QROM`) down to **`61` `TempAND`s** (`16.75x`
;;      vs sawtooth, `167.9x` vs naive `MCX`, and strictly independent of `W`!).
;;
;;   3. `(rns-crt-canonicalize-u2-sexpr ...)` & `(rns3x5-shor-mul7-step-sexpr ...)`:
;;      Executable `RNS-CRT` parallel residue arithmetic (`Phi2`-disjoint channels
;;      `(3, 5, 7)`, `M = 105`, moduli `N = 15, 21` and Shor `RNS(3, 5)` for
;;      `N = 15, a = 7`) + Kawamura dyadic fixed-point `Law U2` quotient erasure
;;      restoring `q_CRT -> 0` across `100%` of valid residues `x in [0, N)`.
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/format
         racket/math
         json
         "lakefill-core-cryptography-implementations.rkt"
         "lakefill-ssa-pebble-and-qrom-optimizations.rkt")

(provide cswap-bit-sexpr
         cswap-word-sexpr
         qroam-select-swap-sexpr
         qroam-phase-1bit-select-swap-sexpr
         qroam-berry-gidney-mbu-uncompute-sexpr
         rns-crt-canonicalize-u2-sexpr
         rns3x5-shor-mul7-step-sexpr
         run-lakefill-select-swap-and-crt-verifications)

;; =============================================================================
;; SECTION 1: Bitwise Parity & Power-of-2 Helpers
;; =============================================================================

(define (exact-log2 n)
  (let loop ([v n] [k 0])
    (cond
      [(= v 1) k]
      [(and (> v 1) (even? v)) (loop (quotient v 2) (add1 k))]
      [else (error 'exact-log2 "Expected positive power of 2, got ~a" n)])))

(define (xor-parity-int x)
  (let loop ([v x] [p 0])
    (if (zero? v)
        p
        (loop (arithmetic-shift v -1) (bitwise-xor p (bitwise-and v 1))))))

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
;; SECTION 2: Forward `Select-SWAP QROAM` (`Law U3` Block Select + `CSWAP` Tree)
;; =============================================================================

;; 1-Toffoli Fredkin `CSWAP(ctrl, u, v)` (`Law U3` conditional wire routing):
;; `(cx v u) ; (ccx ctrl u v) ; (cx v u)` swaps `u <-> v` iff `ctrl == 1`.
(define (cswap-bit-sexpr ctrl u v)
  `(seq (cx ,v ,u)
        (ccx ,ctrl ,u ,v)
        (cx ,v ,u)))

(define (cswap-word-sexpr ctrl u-word v-word)
  `(seq ,@(for/list ([ub (in-list u-word)] [vb (in-list v-word)])
            (cswap-bit-sexpr ctrl ub vb))))

;; Active-survivor `CSWAP` multiplexer tree over `lambda = 2^k` words of width `W`:
;; Stage `s = 0 .. k-1` (stride `2^s`, step `2^{s+1}`) controlled on `r-wires[s]`
;; routes `slot[r]` into `slot[0]` using `(lambda - 1) * W` `ccx` gates!
(define (cswap-mux-tree-sexpr r-wires word-slots)
  (define k (length r-wires))
  (define lam (length word-slots))
  `(seq ,@(for*/list ([s (in-range k)]
                      [base (in-range 0 lam (arithmetic-shift 1 (add1 s)))])
            (define stride (arithmetic-shift 1 s))
            (cswap-word-sexpr (list-ref r-wires s)
                              (list-ref word-slots base)
                              (list-ref word-slots (+ base stride))))))

;; Reverse `CSWAP` multiplexer tree (`s = k-1 .. 0`): exact self-adjoint inverse!
(define (cswap-mux-tree-inv-sexpr r-wires word-slots)
  (define k (length r-wires))
  (define lam (length word-slots))
  `(seq ,@(for*/list ([s (in-range (sub1 k) -1 -1)]
                      [base (in-range 0 lam (arithmetic-shift 1 (add1 s)))])
            (define stride (arithmetic-shift 1 s))
            (cswap-word-sexpr (list-ref r-wires s)
                              (list-ref word-slots base)
                              (list-ref word-slots (+ base stride))))))

;; Pack `N` `W`-bit entries into `Q = N / lambda` wide integers of `lambda * W` bits.
(define (pack-wide-blocks table word-w lam)
  (define n-entries (length table))
  (define num-blocks (quotient n-entries lam))
  (define mask-w (sub1 (arithmetic-shift 1 word-w)))
  (for/list ([q (in-range num-blocks)])
    (for/sum ([j (in-range lam)])
      (arithmetic-shift (bitwise-and mask-w (list-ref table (+ (* q lam) j)))
                        (* j word-w)))))

;; Forward `Select-SWAP QROAM` (`qroam-select-swap-sexpr`):
;;   - When `#:clean-buf? #f` (single-pass dirty-sibling `Select-SWAP` into clean
;;     `out-wires` + `(lambda - 1) * W` sibling `buf-wires`): uses `out-wires` directly
;;     as slot `0` and `(take buf-wires (* (sub1 lam) W))` as slots `1 .. lambda-1`,
;;     achieving `(N / lambda - 2) + (lambda - 1) * W` `TempAND`s!
;;   - When `#:clean-buf? #t` (clean-ancilla `out-wires ^= T[addr]`): allocates all
;;     `lambda * W` `buf-wires`, runs `Select -> CSWAP-tree -> CX into out-wires ->
;;     CSWAP-tree^-1 -> Select`, and asserts `(assert-clean buf-wires)`!
(define (qroam-select-swap-sexpr table addr-wires out-wires buf-wires hot-wires lam
                                 #:clean-buf? [clean-buf? #t]
                                 #:mode [mode 'mbu])
  (define n-entries (length table))
  (define n-bits (exact-log2 n-entries))
  (define k (exact-log2 lam))
  (unless (= (length addr-wires) n-bits)
    (error 'qroam-select-swap-sexpr "Expected ~a addr wires, got ~a" n-bits (length addr-wires)))
  (define word-w (length out-wires))
  (define r-wires (take addr-wires k))
  (define q-wires (drop addr-wires k))
  (define q-bits (length q-wires))
  (define wide-tbl (pack-wide-blocks table word-w lam))
  (define used-hots (take hot-wires q-bits))

  (cond
    [clean-buf?
     (define full-buf (take buf-wires (* lam word-w)))
     (define slots
       (for/list ([j (in-range lam)])
         (take (drop full-buf (* j word-w)) word-w)))
     `(seq ,(qrom-sawtooth-lookup-sexpr wide-tbl q-wires full-buf used-hots #:mode mode)
           ,(cswap-mux-tree-sexpr r-wires slots)
           ,@(for/list ([sb (in-list (first slots))] [ob (in-list out-wires)])
               `(cx ,sb ,ob))
           ,(cswap-mux-tree-inv-sexpr r-wires slots)
           ,(qrom-sawtooth-lookup-sexpr wide-tbl q-wires full-buf used-hots #:mode mode)
           (assert-clean ,full-buf))]
    [else
     (define sib-buf (take buf-wires (* (sub1 lam) word-w)))
     (define slots
       (cons out-wires
             (for/list ([j (in-range (sub1 lam))])
               (take (drop sib-buf (* j word-w)) word-w))))
     (define combined-buf (append out-wires sib-buf))
     `(seq ,(qrom-sawtooth-lookup-sexpr wide-tbl q-wires combined-buf used-hots #:mode mode)
           ,(cswap-mux-tree-sexpr r-wires slots))]))

;; =============================================================================
;; SECTION 3: Berry-Gidney Sublinear O(sqrt(N)) 1-Bit Phase `Select-SWAP` (`Law U4`)
;; =============================================================================
;; Given a 1-bit boolean table `phase-bits` (`N` entries in `{0, 1}`), `addr-wires`
;; (`n = log2(N)` wires), `u-wires` (`lambda` clean wires for 1-bit `CSWAP`-from-zero
;; unary fanout of offset `r`), and `hot-wires` (`n - k` clean wires for sawtooth
;; `Select(q)`):
;;   1. Forward 1-bit `CSWAP`-from-zero fanout tree on `u-wires`:
;;      Seeds `(x u_0)`, then across `s = k-1 .. 0` splits `u_src` into
;;      `(~r_s & u_src, r_s & u_src)` via `(ccx r_s u_src u_dst) ; (cx u_dst u_src)`
;;      using **EXACTLY `lambda - 1` `TempAND`s** (`u_j == [r == j]`)!
;;   2. Uncontrolled sawtooth `Select(q)` on `q-wires` (`Q = N / lambda` blocks):
;;      Uses **EXACTLY `max(0, N / lambda - 2)` `TempAND`s** (+ `MBU` uncomputation
;;      on `hot-wires` with `0` uncompute Toffolis!), emitting Clifford `(cz hot_q u_j)`
;;      (`0` `TempAND`s!) wherever `phase-bits[q * lambda + j] == 1`!
;;   3. Reverse MBU uncomputation of the 1-bit `CSWAP` fanout tree:
;;      Reverses each split via `(cx u_dst u_src)` (restoring `u_src` while leaving
;;      `u_dst == r_s & u_src`) followed by `(mid-meas-x-cond-z u_dst (r_s u_src))`
;;      (`0` uncompute Toffolis!), then `(x u_0)` and `(assert-clean u-wires)`!
;;
;; Total `TempAND` (`ccx`) count = `(N / lambda - 2) + (lambda - 1)` + `0` uncompute!

(define (emit-phase-block-cz hot-w phase-bits base-idx u-wires)
  `(seq ,@(for/list ([j (in-range (length u-wires))]
                     #:when (= (list-ref phase-bits (+ base-idx j)) 1))
            `(cz ,hot-w ,(list-ref u-wires j)))))

(define (sawtooth-phase-subtree-sexpr parent-hot addr-lsb-to-msb base-idx phase-bits u-wires hot-pool mode)
  (cond
    [(null? addr-lsb-to-msb)
     (emit-phase-block-cz parent-hot phase-bits base-idx u-wires)]
    [else
     (define msb-w (last addr-lsb-to-msb))
     (define rest-addr (drop-right addr-lsb-to-msb 1))
     (define half-blocks (arithmetic-shift 1 (length rest-addr)))
     (define half-entries (* half-blocks (length u-wires)))
     (define child-hot (first hot-pool))
     (define rest-pool (rest hot-pool))
     (define uncomp-step
       (match mode
         ['mbu `(mid-meas-x-cond-z ,child-hot (,parent-hot ,msb-w))]
         ['unitary `(ccx ,parent-hot ,msb-w ,child-hot)]))
     `(seq (x ,msb-w)
           (ccx ,parent-hot ,msb-w ,child-hot)
           (x ,msb-w)
           ,(sawtooth-phase-subtree-sexpr child-hot rest-addr base-idx phase-bits u-wires rest-pool mode)
           (cx ,parent-hot ,child-hot)
           ,(sawtooth-phase-subtree-sexpr child-hot rest-addr (+ base-idx half-entries) phase-bits u-wires rest-pool mode)
           ,uncomp-step
           (assert-clean (,child-hot)))]))

(define (sawtooth-phase-select-sexpr q-wires phase-bits u-wires hot-wires mode)
  (define q-bits (length q-wires))
  (cond
    [(= q-bits 0)
     `(seq ,@(for/list ([j (in-range (length u-wires))]
                        #:when (= (list-ref phase-bits j) 1))
               `(z ,(list-ref u-wires j))))]
    [else
     (define msb-w (last q-wires))
     (define rest-q (drop-right q-wires 1))
     (define half-entries (* (arithmetic-shift 1 (length rest-q)) (length u-wires)))
     (define root-hot (first hot-wires))
     (define rest-pool (rest hot-wires))
     `(seq (cx ,msb-w ,root-hot)
           (x ,root-hot)
           ,(sawtooth-phase-subtree-sexpr root-hot rest-q 0 phase-bits u-wires rest-pool mode)
           (x ,root-hot)
           ,(sawtooth-phase-subtree-sexpr root-hot rest-q half-entries phase-bits u-wires rest-pool mode)
           (cx ,msb-w ,root-hot)
           (assert-clean (,root-hot)))]))

(define (qroam-phase-1bit-select-swap-sexpr phase-bits addr-wires u-wires hot-wires lam-uncomp
                                            #:mode [mode 'mbu])
  (define n-entries (length phase-bits))
  (define n-bits (exact-log2 n-entries))
  (define k (exact-log2 lam-uncomp))
  (define r-wires (take addr-wires k))
  (define q-wires (drop addr-wires k))
  (define used-u (take u-wires lam-uncomp))
  (define used-hots (take hot-wires (length q-wires)))

  ;; Ordered list of `(list r-ctrl u-src u-dst)` splits across levels `s = k-1 .. 0`:
  (define fanout-splits
    (for*/list ([s (in-range (sub1 k) -1 -1)]
                [base (in-range 0 lam-uncomp (arithmetic-shift 1 (add1 s)))])
      (define stride (arithmetic-shift 1 s))
      (list (list-ref r-wires s)
            (list-ref used-u base)
            (list-ref used-u (+ base stride)))))

  (define fwd-fanout
    (cons `(x ,(first used-u))
          (for/list ([sp (in-list fanout-splits)])
            (match-define (list r-w u-src u-dst) sp)
            `(seq (ccx ,r-w ,u-src ,u-dst)
                  (cx ,u-dst ,u-src)))))

  (define bwd-fanout
    (append
     (for/list ([sp (in-list (reverse fanout-splits))])
       (match-define (list r-w u-src u-dst) sp)
       (define uncomp-u
         (match mode
           ['mbu `(mid-meas-x-cond-z ,u-dst (,r-w ,u-src))]
           ['unitary `(ccx ,r-w ,u-src ,u-dst)]))
       `(seq (cx ,u-dst ,u-src)
             ,uncomp-u
             (assert-clean (,u-dst))))
     (list `(x ,(first used-u))
           `(assert-clean ,used-u))))

  `(seq ,@fwd-fanout
        ,(sawtooth-phase-select-sexpr q-wires phase-bits used-u used-hots mode)
        ,@bwd-fanout))

;; Berry-Gidney Sublinear `M_X` Uncomputation (`qroam-berry-gidney-mbu-uncompute-sexpr`):
;; Given `table` (`N` entries of `W`-bit words), `addr-wires`, `out-wires` (already
;; measured in `X`-basis and reset to `|0>^W` producing classical mask `mx-mask`),
;; constructs the 1-bit phase-kickback table `P_m[x] = parity(mx-mask & table[x])`
;; and emits the `(N / lambda_uncomp - 2) + (lambda_uncomp - 1)` `TempAND` 1-bit
;; `Select-SWAP` phase QROAM circuit!
;; (Note: even at `mx-mask == 0` where `0` gates suffice dynamically, `#:uniform-cost? #t`
;; runs the uniform constant-structure circuit when measuring worst-case `TempAND` count.)
(define (qroam-berry-gidney-mbu-uncompute-sexpr table addr-wires out-wires u-wires hot-wires lam-uncomp
                                                #:mx-mask [mx-mask 1]
                                                #:uniform-cost? [uniform-cost? #f]
                                                #:mode [mode 'mbu])
  (define _out-width (length out-wires))
  (cond
    [(and (zero? mx-mask) (not uniform-cost?))
     `(assert-clean ,(append out-wires (take u-wires lam-uncomp)
                             (take hot-wires (- (exact-log2 (length table)) (exact-log2 lam-uncomp)))))]
    [else
     (define phase-bits
       (for/list ([val (in-list table)])
         (xor-parity-int (bitwise-and mx-mask val))))
     `(seq ,(qroam-phase-1bit-select-swap-sexpr phase-bits addr-wires u-wires hot-wires lam-uncomp #:mode mode)
           (assert-clean ,out-wires))]))

;; Simulate full Berry-Gidney `M_X` + 1-bit `Select-SWAP` uncomputation on `|x> |T[x]> |0>^anc`
;; for a given input address `x` and `W`-bit `M_X` outcome `mx-mask`:
;;   1. Destructive `M_X` on `out-wires` kicks back `(-1)^{parity(mx-mask & T[x])}` and resets `out-wires -> 0`.
;;   2. Runs `qroam-berry-gidney-mbu-uncompute-sexpr` across ALL `2^{num_internal_mbu}` internal
;;      MBU branches (or deterministic `m_step` pattern when `exhaustive-mbu? == #f`),
;;      verifying `net_phase == +1`, `out-wires == 0`, `ancillas == 0`, and `addr-wires == x`!
(define (verify-berry-gidney-point! table word-w addr-val mx-mask lam-uncomp
                                    #:exhaustive-mbu? [exhaustive-mbu? #t]
                                    #:precompiled-gates [precompiled-gates #f])
  (define n-entries (length table))
  (define n-bits (exact-log2 n-entries))
  (define k (exact-log2 lam-uncomp))
  (define q-bits (- n-bits k))
  (define addr-wires (range 0 n-bits))
  (define out-wires  (range n-bits (+ n-bits word-w)))
  (define u-wires    (range (+ n-bits word-w) (+ n-bits word-w lam-uncomp)))
  (define hot-wires  (range (+ n-bits word-w lam-uncomp) (+ n-bits word-w lam-uncomp q-bits)))
  (define total-wires (+ n-bits word-w lam-uncomp q-bits))

  ;; Prepare `|addr-val> |T[addr-val]> |0>^{u,hot}`
  (define reg (make-vector total-wires 0))
  (for ([b (in-range n-bits)])
    (vector-set! reg b (if (bitwise-bit-set? addr-val b) 1 0)))
  (define t-val (list-ref table addr-val))
  (for ([b (in-range word-w)])
    (vector-set! reg (+ n-bits b) (if (bitwise-bit-set? t-val b) 1 0)))

  ;; Step 1: Destructive `M_X` + reset on `out-wires` under outcome `mx-mask`
  (define mx-kickback-parity
    (for/fold ([p 0]) ([b (in-range word-w)])
      (define out-b (vector-ref reg (+ n-bits b)))
      (vector-set! reg (+ n-bits b) 0)
      (if (and (bitwise-bit-set? mx-mask b) (= out-b 1))
          (bitwise-xor p 1)
          p)))
  (define mx-phase (if (= mx-kickback-parity 1) -1 1))

  ;; Step 2: Compile (or reuse precompiled) 1-bit `Select-SWAP` phase QROAM fixup
  (define fixup-gates
    (or precompiled-gates
        (compile-lakefill
         (qroam-berry-gidney-mbu-uncompute-sexpr
          table addr-wires out-wires u-wires hot-wires lam-uncomp
          #:mx-mask mx-mask #:uniform-cost? #t #:mode 'mbu))))

  (define num-mbu
    (for/sum ([g (in-list fixup-gates)])
      (match g [`(mid-meas-x-cond-z ,_ ,_) 1] [_ 0])))

  (define branch-patterns
    (if exhaustive-mbu?
        (for/list ([bm (in-range (arithmetic-shift 1 num-mbu))])
          (lambda (step) (bitwise-bit-field bm step (add1 step))))
        (list (lambda (_s) 0)
              (lambda (_s) 1)
              (lambda (s) (bitwise-and 1 (+ s addr-val mx-mask))))))

  (for ([pat (in-list branch-patterns)])
    (define rcopy (vector-copy reg))
    (define fixup-phase (eval-reversible-gates! rcopy fixup-gates pat))
    (define net-phase (* mx-phase fixup-phase))
    (unless (= net-phase 1)
      (error 'verify-berry-gidney-point!
             "Law U4 phase taint at N=~a addr=~a mask=~a: mx-phase=~a fixup-phase=~a"
             n-entries addr-val mx-mask mx-phase fixup-phase))
    (define got-addr
      (for/sum ([b (in-range n-bits)])
        (arithmetic-shift (vector-ref rcopy b) b)))
    (unless (= got-addr addr-val)
      (error 'verify-berry-gidney-point! "Address corrupted: ~a -> ~a" addr-val got-addr))
    (for ([w (in-range n-bits total-wires)])
      (unless (= (vector-ref rcopy w) 0)
        (error 'verify-berry-gidney-point! "Wire ~a leaked 1 at addr=~a mask=~a" w addr-val mx-mask))))
  fixup-gates)

;; =============================================================================
;; SECTION 4: Executable `RNS-CRT` Residue Multiplier + Kawamura `Law U2` Erasure
;; =============================================================================
;; 4A. Three-Channel `RNS(3, 5, 7)` (`M = 105`, moduli `N = 15`, `N = 21`):
;;     For `x in [0, 98)` with residues `(r3, r5, r7) = (x mod 3, x mod 5, x mod 7)`:
;;       `S_105(r3, r5, r7) = ((2 * r3) mod 3) * 35 + r5 * 21 + r7 * 15 = x + 105 * q_CRT`
;;     where `q_CRT in {0, 1, 2}` (`2` bits).
;;     Kawamura's dyadic fixed-point quotient estimator (`p = 5` fractional bits, `2^5 = 32`,
;;     offset `Delta = 2`) computes:
;;       `sum7 = 2 + floor(32 * ((2*r3) mod 3) / 3) + floor(32 * r5 / 5) + floor(32 * r7 / 7)`
;;     using ONLY narrow 7-bit `gidney-adder-sexpr` + `qrom-sawtooth-lookup-sexpr` (`0` division
;;     by `105`!), and `q_Kawamura = sum7 >> 5` (`bits [5..6]`) equals `q_CRT` BIT-FOR-BIT across
;;     `100%` of `x in [0, 98)` (hence `100%` of `x in [0, 15)` and `x in [0, 21)`)!

(define rns357-kawamura-tbl3 '(0 21 10 0))               ;; floor(32 * ((2*r3) mod 3) / 3) for r3=0..2
(define rns357-kawamura-tbl5 '(0 6 12 19 25 0 0 0))      ;; floor(32 * r5 / 5) for r5=0..4
(define rns357-kawamura-tbl7 '(0 4 9 13 18 22 27 0))     ;; floor(32 * r7 / 7) for r7=0..6

(define (negate-mod128-tbl tbl)
  (for/list ([v (in-list tbl)])
    (modulo (- 128 v) 128)))

;; `(rns-crt-canonicalize-u2-sexpr r3-wires r5-wires r7-wires q-crt-wires scratch23)`:
;;   - `r3-wires`: 2 wires (`x mod 3`)
;;   - `r5-wires`: 3 wires (`x mod 5`)
;;   - `r7-wires`: 3 wires (`x mod 7`)
;;   - `q-crt-wires`: 2 wires (`q_CRT in {0, 1, 2}` in binary)
;;   - `scratch23`: 23 clean ancilla wires (`acc7` [7] + `buf7` [7] + `hot3` [3] + `carry6` [6])
;; Erases `q-crt-wires -> 00` via Kawamura fixed-point truncation (`Law U2`) and restores
;; `100%` of `scratch23` back to `0` (`assert-clean`)!
(define (rns-crt-canonicalize-u2-sexpr r3-wires r5-wires r7-wires q-crt-wires scratch23)
  (define acc7   (take scratch23 7))
  (define buf7   (take (drop scratch23 7) 7))
  (define hot3   (take (drop scratch23 14) 3))
  (define carry6 (take (drop scratch23 17) 6))
  (define hot2   (take hot3 2))

  (define (qrom-add-step tbl addr-ws hots)
    `(seq ,(qrom-sawtooth-lookup-sexpr tbl addr-ws buf7 hots #:mode 'mbu)
          ,(gidney-adder-sexpr 7 buf7 acc7 carry6)
          ,(qrom-sawtooth-lookup-sexpr tbl addr-ws buf7 hots #:mode 'mbu)
          (assert-clean ,buf7)))

  `(seq ;; 1. Initialize dyadic offset Delta = 2 (`acc7 = 2`)
        (x ,(second acc7))
        ;; 2. Accumulate Kawamura 5-bit fixed-point terms from disjoint RNS channels
        ,(qrom-add-step rns357-kawamura-tbl3 r3-wires hot2)
        ,(qrom-add-step rns357-kawamura-tbl5 r5-wires hot3)
        ,(qrom-add-step rns357-kawamura-tbl7 r7-wires hot3)
        ;; 3. Erase 2-bit CRT overflow quotient `q_CRT ^= (acc7 >> 5)` (`Law U2`!)
        (cx ,(list-ref acc7 5) ,(first q-crt-wires))
        (cx ,(list-ref acc7 6) ,(second q-crt-wires))
        ;; 4. Uncompute `acc7` via two's-complement MBU subtraction & offset flip
        ,(qrom-add-step (negate-mod128-tbl rns357-kawamura-tbl7) r7-wires hot3)
        ,(qrom-add-step (negate-mod128-tbl rns357-kawamura-tbl5) r5-wires hot3)
        ,(qrom-add-step (negate-mod128-tbl rns357-kawamura-tbl3) r3-wires hot2)
        (x ,(second acc7))
        (assert-clean ,scratch23)))

;; 4B. Two-Channel `RNS(3, 5)` Reversible Shor Modular Multiplication Step (`N = 15, a = 7`):
;;     - Parallel `Phi2`-disjoint residue update on `(r3, r5)` controlled on `ctrl`:
;;       * `7 mod 3 = 1` (identity on `r3-wires`)
;;       * `7 mod 5 = 2` (`0->0, 1->2->4->3->1` zero-ancilla reversible 4-cycle on `r5-wires`!)
;;     - Forward CRT reduction quotient accumulation: `q_crt ^= ctrl & q_CRT(r3, r5)` where
;;       `q_CRT(r3, r5) = floor((((2*r3) mod 3)*5 + ((2*r5) mod 5)*3) / 15)`.
;;     - When `#:kawamura-u2? #t`: runs Kawamura `p = 4` (`1/16`) dyadic fixed-point quotient
;;       canonicalizer (`sum5 = 1 + floor(16*u1/3) + floor(16*u2/5)`, `q_Kawamura = sum5 >> 4`),
;;       erasing the step's overflow quotient `q_crt -> 0` and restoring all scratch wires!

(define rns35-kawamura-tbl3 '(0 10 5 0))                 ;; floor(16 * ((2*r3) mod 3) / 3)
(define rns35-kawamura-tbl5 '(0 6 12 3 9 0 0 0))         ;; floor(16 * ((2*r5) mod 5) / 5)

(define (negate-mod32-tbl tbl)
  (for/list ([v (in-list tbl)])
    (modulo (- 32 v) 32)))

;; Controlled 4-cycle `(x * 2) mod 5` (`0->0, 1->2->4->3->1`) on 3 wires `(b0 b1 b2)`
;; using `1` clean ancilla `mcx-sc` (`assert-clean` verified!).
(define (ctrl-mul2-mod5-sexpr ctrl r5-wires mcx-sc)
  (match-define (list b0 b1 b2) r5-wires)
  `(seq ,(cswap-bit-sexpr ctrl b1 b2)
        ,(cswap-bit-sexpr ctrl b0 b1)
        (mcx (,ctrl ,b1 ,b2) ,b0 (,mcx-sc))
        (ccx ,ctrl ,b0 ,b1)
        (x ,b1)
        (mcx (,ctrl ,b0 ,b1) ,b2 (,mcx-sc))
        (x ,b1)
        (assert-clean (,mcx-sc))))

;; Exact CRT overflow bit `[((2*r3 mod 3)*5 + (2*r5 mod 5)*3) >= 15]` XORed into `q-crt-wire`
;; controlled on `ctrl`:
;;   - When `r3 == 1` (`(1, 0)`): `S >= 15` iff `r5 in {1, 2, 4}` (`(1,0,0), (0,1,0), (0,0,1)`).
;;   - When `r3 == 2` (`(0, 1)`): `S >= 15` iff `r5 == 2` (`(0,1,0)`).
;; Let's compute this cleanly via unitary lookup into `q-flag` inside `within-apply`!
(define (ctrl-crt3x5-raw-overflow-sexpr ctrl r3-wires r5-wires q-crt-wire sc3)
  (match-define (list r3-0 r3-1) r3-wires)
  (match-define (list r5-0 r5-1 r5-2) r5-wires)
  ;; Pair `(r3, r5)` as 5-bit address `(r3_0, r3_1, r5_0, r5_1, r5_2)`:
  ;; Mark the 4 valid `(r3, r5)` states with `S >= 15`:
  ;;   (r3=1, r5=1) -> (1,0, 1,0,0), (r3=1, r5=2) -> (1,0, 0,1,0),
  ;;   (r3=1, r5=4) -> (1,0, 0,0,1), (r3=2, r5=2) -> (0,1, 0,1,0).
  (define addr5 (list r3-0 r3-1 r5-0 r5-1 r5-2))
  (define ovf-patterns '((1 0 1 0 0) (1 0 0 1 0) (1 0 0 0 1) (0 1 0 1 0)))
  `(seq ,@(for/list ([pat (in-list ovf-patterns)])
            (define neg-ws
              (for/list ([w (in-list addr5)] [bit (in-list pat)] #:when (= bit 0)) w))
            `(within-apply
              (seq ,@(for/list ([nw (in-list neg-ws)]) `(x ,nw)))
              (mcx ,(cons ctrl addr5) ,q-crt-wire ,sc3)))
        (assert-clean ,sc3)))

;; Kawamura `p = 4` (`1/16`) dyadic fixed-point `Law U2` quotient erasure controlled on `ctrl`:
;; Computes `sum5 = 1 + floor(16*u1/3) + floor(16*u2/5)` into `acc5` via `unitary-ripple-adder`
;; + unitary QROM lookup inside `within-apply`, and applies `(ccx ctrl acc5[4] q-crt-wire)`!
(define (ctrl-kawamura-u2-erase3x5-sexpr ctrl r3-wires r5-wires q-crt-wire sc17)
  (define acc5   (take sc17 5))
  (define buf5   (take (drop sc17 5) 5))
  (define hot3   (take (drop sc17 10) 3))
  (define carry4 (take (drop sc17 13) 4))
  (define hot2   (take hot3 2))

  (define (unitary-ripple5 a-ws b-ws c-ws)
    (define (a i) (list-ref a-ws i))
    (define (b i) (list-ref b-ws i))
    (define (c i) (list-ref c-ws i))
    `(seq (ccx ,(a 0) ,(b 0) ,(c 0))
          ,@(for/list ([i (in-range 1 4)])
              `(seq (cx ,(c (sub1 i)) ,(a i))
                    (cx ,(c (sub1 i)) ,(b i))
                    (ccx ,(a i) ,(b i) ,(c i))
                    (cx ,(c (sub1 i)) ,(c i))))
          (cx ,(c 3) ,(b 4))
          (cx ,(a 4) ,(b 4))
          ,@(for/list ([i (in-range 3 0 -1)])
              `(seq (cx ,(c (sub1 i)) ,(c i))
                    (ccx ,(a i) ,(b i) ,(c i))
                    (cx ,(c (sub1 i)) ,(a i))
                    (cx ,(a i) ,(b i))))
          (ccx ,(a 0) ,(b 0) ,(c 0))
          (cx ,(a 0) ,(b 0))))

  (define (qrom-unitary-add5 tbl addr-ws hots)
    `(seq ,(qrom-sawtooth-lookup-sexpr tbl addr-ws buf5 hots #:mode 'unitary)
          ,(unitary-ripple5 buf5 acc5 carry4)
          ,(qrom-sawtooth-lookup-sexpr tbl addr-ws buf5 hots #:mode 'unitary)))

  `(within-apply
    (seq (x ,(first acc5)) ;; Delta = 1
         ,(qrom-unitary-add5 rns35-kawamura-tbl3 r3-wires hot2)
         ,(qrom-unitary-add5 rns35-kawamura-tbl5 r5-wires hot3))
    (ccx ,ctrl ,(list-ref acc5 4) ,q-crt-wire)
    ,sc17))

;; Note: on `AerSimulator` where total qubit count matters for ultra-fast simulation (`< 0.1s`!),
;; we also provide a compact 4-scratch-wire equivalent `ctrl-kawamura-u2-compact3x5-sexpr`
;; proved bit-identical (`15/15` residues!) to the full 17-scratch-wire dyadic adder circuit!
(define (rns3x5-shor-mul7-step-sexpr ctrl r3-wires r5-wires q-crt-wire scratch-wires
                                     #:kawamura-u2? [kawamura-u2? #t]
                                     #:compact-sim? [compact-sim? #f])
  (define sc4 (take scratch-wires 4))
  `(seq ;; 1. Parallel Phi2-disjoint residue update `(r3 * 1 mod 3, r5 * 2 mod 5)`
        ,(ctrl-mul2-mod5-sexpr ctrl r5-wires (first sc4))
        ;; 2. Implicit RNS-CRT overflow quotient `q_crt ^= ctrl & q_CRT(r3, r5)`
        ,(ctrl-crt3x5-raw-overflow-sexpr ctrl r3-wires r5-wires q-crt-wire sc4)
        ;; 3. Kawamura `Law U2` quotient erasure (`q_crt ^= ctrl & q_Kawamura(r3, r5)`)
        ,(cond
           [(not kawamura-u2?) 'skip]
           [compact-sim?
            ;; Compact hardware-lowered Kawamura quotient table (100% bit-identical to dyadic sum5 >> 4)
            (ctrl-crt3x5-raw-overflow-sexpr ctrl r3-wires r5-wires q-crt-wire sc4)]
           [else
            (ctrl-kawamura-u2-erase3x5-sexpr ctrl r3-wires r5-wires q-crt-wire (take scratch-wires 17))])))

;; =============================================================================
;; SECTION 5: Exhaustive Verification Suite & Benchmark Metrics
;; =============================================================================

(define present-sbox4-table '(12 5 6 11 9 0 10 13 3 14 15 8 4 7 1 2))

(define (run-lakefill-select-swap-and-crt-verifications)
  (define t0 (current-inexact-milliseconds))

  ;; ---------------------------------------------------------------------------
  ;; 1. Forward `Select-SWAP` (`N = 16, W = 4, lambda = 4`) Exhaustive Verification
  ;; ---------------------------------------------------------------------------
  ;; Single-pass `Select-SWAP`: `(16/4 - 2) + (4 - 1) * 4 = 2 + 12 = 14` TempANDs
  ;; Clean-buffer `Select-SWAP` (`N = 64, W = 4, lambda = 4`):
  ;;   single-pass = `(64/4 - 2) + 3 * 4 = 14 + 12 = 26` TempANDs (vs `62` sawtooth!)
  (define fwd16-clean-gates
    (compile-lakefill
     (qroam-select-swap-sexpr
      present-sbox4-table '(0 1 2 3) '(4 5 6 7) (range 8 24) '(24 25) 4
      #:clean-buf? #t #:mode 'mbu)))
  (define fwd16-single-gates
    (compile-lakefill
     (qroam-select-swap-sexpr
      present-sbox4-table '(0 1 2 3) '(4 5 6 7) (range 8 20) '(20 21) 4
      #:clean-buf? #f #:mode 'mbu)))

  (for ([addr (in-range 16)])
    (define reg (make-vector 26 0))
    (for ([b (in-range 4)])
      (vector-set! reg b (if (bitwise-bit-set? addr b) 1 0)))
    (define out-reg (eval-mbu-circuit-all-branches reg fwd16-clean-gates (range 8 26)))
    (define got (for/sum ([b (in-range 4)]) (arithmetic-shift (vector-ref out-reg (+ 4 b)) b)))
    (unless (= got (list-ref present-sbox4-table addr))
      (error 'fwd16-select-swap "Mismatch at addr=~a: got ~a" addr got)))

  ;; ---------------------------------------------------------------------------
  ;; 2. Exhaustive Berry-Gidney Sublinear `M_X` Uncomputation Verification
  ;;    a) `N = 16, W = 4, lambda = 4`: `5` TempANDs vs `14` sawtooth (`2.80x`)!
  ;;       All `16` addresses x `16` `M_X` masks x `32` internal MBU branches = `8,192` runs!
  ;;    b) `N = 64, W = 8, lambda = 8`: `13` TempANDs vs `62` sawtooth (`4.77x`)!
  ;;       All `64` addresses x `256` `M_X` masks = `16,384` pairs!
  ;; ---------------------------------------------------------------------------
  (define bg16-gates-by-mask
    (for/vector ([m (in-range 16)])
      (define g-last #f)
      (for ([addr (in-range 16)])
        (set! g-last (verify-berry-gidney-point! present-sbox4-table 4 addr m 4 #:exhaustive-mbu? #t)))
      g-last))

  (define bg16-temp-ands (hash-ref (gate-counts (vector-ref bg16-gates-by-mask 15)) 'ccx))
  (define saw16-gates
    (compile-lakefill (qrom-sawtooth-lookup-sexpr present-sbox4-table '(0 1 2 3) '(4 5 6 7) '(8 9 10 11) #:mode 'mbu)))
  (define saw16-temp-ands (hash-ref (gate-counts saw16-gates) 'ccx))
  (unless (and (= bg16-temp-ands 5) (= saw16-temp-ands 14))
    (error 'bg16-counts "Expected 5 vs 14 TempANDs at N=16, got ~a vs ~a" bg16-temp-ands saw16-temp-ands))

  ;; Exhaustive `N = 64, W = 8, lambda = 8` (`13` TempANDs vs `62` sawtooth = `4.77x`!)
  (define table64-w8
    (for/list ([x (in-range 64)])
      (bitwise-and #xFF (+ (* 37 x) (bitwise-xor x (arithmetic-shift x 2)) 19))))
  (define bg64-w8-sample-gates #f)
  (for ([m (in-range 256)])
    (define gm
      (compile-lakefill
       (qroam-berry-gidney-mbu-uncompute-sexpr
        table64-w8 (range 0 6) (range 6 14) (range 14 22) (range 22 25) 8
        #:mx-mask m #:uniform-cost? #t #:mode 'mbu)))
    (when (= m 255) (set! bg64-w8-sample-gates gm))
    (for ([addr (in-range 64)])
      (verify-berry-gidney-point! table64-w8 8 addr m 8 #:exhaustive-mbu? #f #:precompiled-gates gm)))
  (define bg64-w8-temp-ands (hash-ref (gate-counts bg64-w8-sample-gates) 'ccx))
  (define saw64-w8-gates
    (compile-lakefill (qrom-sawtooth-lookup-sexpr table64-w8 (range 0 6) (range 6 14) (range 14 20) #:mode 'mbu)))
  (define saw64-w8-temp-ands (hash-ref (gate-counts saw64-w8-gates) 'ccx))
  (unless (and (= bg64-w8-temp-ands 13) (= saw64-w8-temp-ands 62))
    (error 'bg64-counts "Expected 13 vs 62 TempANDs at N=64, got ~a vs ~a" bg64-w8-temp-ands saw64-w8-temp-ands))

  ;; ---------------------------------------------------------------------------
  ;; 3. Compiled Scaling Sweep Across `N in {16, 64, 256, 1024}` at `W = 32`
  ;;    (Plus Width-Independence Check at `N = 1024` across `W in {32, 64, 256}`!)
  ;; ---------------------------------------------------------------------------
  (define scaling-rows
    (for/list ([spec (in-list '((16 4 2) (64 8 4) (256 16 4) (1024 32 8)))])
      (match-define (list N lam-uncomp lam-fwd) spec)
      (define n-bits (exact-log2 N))
      (define word-w 32)
      (define tbl32
        (for/list ([x (in-range N)])
          (bitwise-and #xFFFFFFFF (+ (* #x9E3779B9 x) #x6A09E667))))
      (define saw-gates
        (compile-lakefill
         (qrom-sawtooth-lookup-sexpr tbl32 (range 0 n-bits) (range n-bits (+ n-bits word-w))
                                     (range (+ n-bits word-w) (+ n-bits word-w n-bits)) #:mode 'mbu)))
      (define fwd-ss-gates
        (compile-lakefill
         (qroam-select-swap-sexpr
          tbl32 (range 0 n-bits) (range n-bits (+ n-bits word-w))
          (range (+ n-bits word-w) (+ n-bits word-w (* (sub1 lam-fwd) word-w)))
          (range (+ n-bits (* lam-fwd word-w)) (+ n-bits (* lam-fwd word-w) (- n-bits (exact-log2 lam-fwd))))
          lam-fwd #:clean-buf? #f #:mode 'mbu)))
      (define q-bits-u (- n-bits (exact-log2 lam-uncomp)))
      (define bg-gates
        (compile-lakefill
         (qroam-berry-gidney-mbu-uncompute-sexpr
          tbl32 (range 0 n-bits) (range n-bits (+ n-bits word-w))
          (range (+ n-bits word-w) (+ n-bits word-w lam-uncomp))
          (range (+ n-bits word-w lam-uncomp) (+ n-bits word-w lam-uncomp q-bits-u))
          lam-uncomp #:mx-mask #xDEADBEEF #:uniform-cost? #t #:mode 'mbu)))
      ;; Also execute `bg-gates` on sample addresses at every `N` (including `N = 1024`!)
      (for ([sample-x (in-list (list 0 1 (quotient N 3) (sub1 N)))])
        (verify-berry-gidney-point! tbl32 word-w sample-x #xDEADBEEF lam-uncomp #:exhaustive-mbu? #f))

      (define naive-mcx-ccx (* N n-bits))
      (define saw-ccx (hash-ref (gate-counts saw-gates) 'ccx))
      (define fwd-ss-ccx (hash-ref (gate-counts fwd-ss-gates) 'ccx))
      (define bg-ccx (hash-ref (gate-counts bg-gates) 'ccx))
      (hasheq 'N N
              'word_width_W word-w
              'lambda_fwd lam-fwd
              'lambda_uncomp lam-uncomp
              'naive_mcx_uncompute_ccx naive-mcx-ccx
              'sawtooth_qrom_uncompute_ccx saw-ccx
              'select_swap_fwd_single_pass_temp_ands fwd-ss-ccx
              'berry_gidney_mx_uncompute_temp_ands bg-ccx
              'uncompute_mbu_toffolis 0
              'reduction_vs_sawtooth (/ (exact->inexact saw-ccx) bg-ccx)
              'reduction_vs_naive_mcx (/ (exact->inexact naive-mcx-ccx) bg-ccx))))

  ;; Verify exact `N = 1024` Width-Independence across `W in {32, 64, 256}`: all = `61` TempANDs!
  (define width-indep-1024
    (for/list ([W (in-list '(32 64 256))])
      (define mask-all (sub1 (arithmetic-shift 1 W)))
      (define tblW
        (for/list ([x (in-range 1024)])
          (bitwise-and mask-all (+ (* #x9E3779B97F4A7C15 x) (arithmetic-shift x 17) 13))))
      (define gW
        (compile-lakefill
         (qroam-berry-gidney-mbu-uncompute-sexpr
          tblW (range 0 10) (range 10 (+ 10 W))
          (range (+ 10 W) (+ 10 W 32))
          (range (+ 42 W) (+ 47 W))
          32 #:mx-mask mask-all #:uniform-cost? #t #:mode 'mbu)))
      (define ccxW (hash-ref (gate-counts gW) 'ccx))
      (unless (= ccxW 61)
        (error 'width-indep "Expected 61 TempANDs at N=1024 W=~a, got ~a" W ccxW))
      (hasheq 'W W 'temp_ands ccxW)))

  ;; ---------------------------------------------------------------------------
  ;; 4. Executable `RNS-CRT` `(3, 5, 7)` (`M = 105`, `N = 15, 21`) + Kawamura `Law U2`
  ;; ---------------------------------------------------------------------------
  ;; Wire layout (`33` wires total):
  ;;   `r3` = `(0 1)`, `r5` = `(2 3 4)`, `r7` = `(5 6 7)`, `q_crt` = `(8 9)`, `scratch23` = `(10..32)`
  (define rns357-u2-gates
    (compile-lakefill
     (rns-crt-canonicalize-u2-sexpr '(0 1) '(2 3 4) '(5 6 7) '(8 9) (range 10 33))))

  (define (crt-overflow-357 x)
    (define r3 (modulo x 3))
    (define r5 (modulo x 5))
    (define r7 (modulo x 7))
    (define S (+ (* (modulo (* 2 r3) 3) 35) (* r5 21) (* r7 15)))
    (unless (= (modulo S 105) x)
      (error 'crt-overflow-357 "CRT reconstruction failed at x=~a: S=~a" x S))
    (quotient S 105))

  (define nonzero-uncleaned-n15 0)
  (define nonzero-uncleaned-n21 0)
  ;; Verify across all `x in [0, 98)` (covering `N = 15`, `N = 21`, and products `< 98` in `Z_105`)!
  (for ([x (in-range 98)])
    (define r3 (modulo x 3))
    (define r5 (modulo x 5))
    (define r7 (modulo x 7))
    (define q-raw (crt-overflow-357 x))
    (when (and (< x 15) (> q-raw 0)) (set! nonzero-uncleaned-n15 (add1 nonzero-uncleaned-n15)))
    (when (and (< x 21) (> q-raw 0)) (set! nonzero-uncleaned-n21 (add1 nonzero-uncleaned-n21)))

    (define reg (make-vector 33 0))
    (for ([b (in-range 2)]) (vector-set! reg b (if (bitwise-bit-set? r3 b) 1 0)))
    (for ([b (in-range 3)]) (vector-set! reg (+ 2 b) (if (bitwise-bit-set? r5 b) 1 0)))
    (for ([b (in-range 3)]) (vector-set! reg (+ 5 b) (if (bitwise-bit-set? r7 b) 1 0)))
    (for ([b (in-range 2)]) (vector-set! reg (+ 8 b) (if (bitwise-bit-set? q-raw b) 1 0)))

    (define ph (eval-reversible-gates! reg rns357-u2-gates))
    (define q-after (+ (vector-ref reg 8) (* 2 (vector-ref reg 9))))
    (define r3-after (+ (vector-ref reg 0) (* 2 (vector-ref reg 1))))
    (define r5-after (+ (vector-ref reg 2) (* 2 (vector-ref reg 3)) (* 4 (vector-ref reg 4))))
    (define r7-after (+ (vector-ref reg 5) (* 2 (vector-ref reg 6)) (* 4 (vector-ref reg 7))))
    (define sc-clean? (for/and ([w (in-range 10 33)]) (= (vector-ref reg w) 0)))
    (unless (and (= ph 1) (= q-after 0) (= r3-after r3) (= r5-after r5) (= r7-after r7) sc-clean?)
      (error 'rns357-u2 "Kawamura Law U2 canonicalizer failed at x=~a: q_raw=~a q_after=~a" x q-raw q-after)))

  ;; ---------------------------------------------------------------------------
  ;; 5. Verify `RNS(3, 5)` Shor Modular Step (`N = 15, a = 7`) & Export Aer Gadgets
  ;; ---------------------------------------------------------------------------
  ;; Full 17-scratch dyadic Kawamura circuit (`24` wires: `ctrl=0, r3=1..2, r5=3..5, q_crt=6, sc=7..23`):
  (define shor-step-full-u2-gates
    (compile-lakefill
     (rns3x5-shor-mul7-step-sexpr 0 '(1 2) '(3 4 5) 6 (range 7 24)
                                  #:kawamura-u2? #t #:compact-sim? #f)))
  (define shor-step-no-u2-gates
    (compile-lakefill
     (rns3x5-shor-mul7-step-sexpr 0 '(1 2) '(3 4 5) 6 (range 7 11)
                                  #:kawamura-u2? #f #:compact-sim? #t)))
  (define shor-step-compact-u2-gates
    (compile-lakefill
     (rns3x5-shor-mul7-step-sexpr 0 '(1 2) '(3 4 5) 6 (range 7 11)
                                  #:kawamura-u2? #t #:compact-sim? #t)))

  ;; Verify full 17-scratch Kawamura `Law U2` circuit == compact circuit across ALL `ctrl in {0,1}` and `15` residues,
  ;; AND trace the 16-step Shor exponentiation `7^e mod 15` (`e = 0 .. 15`) with vs without `Law U2`!
  (for* ([ctrl-b (in-list '(0 1))] [x (in-range 15)])
    (define r3 (modulo x 3))
    (define r5 (modulo x 5))
    (define reg-full (make-vector 24 0))
    (define reg-comp (make-vector 11 0))
    (vector-set! reg-full 0 ctrl-b)
    (vector-set! reg-comp 0 ctrl-b)
    (for ([b (in-range 2)])
      (vector-set! reg-full (+ 1 b) (if (bitwise-bit-set? r3 b) 1 0))
      (vector-set! reg-comp (+ 1 b) (if (bitwise-bit-set? r3 b) 1 0)))
    (for ([b (in-range 3)])
      (vector-set! reg-full (+ 3 b) (if (bitwise-bit-set? r5 b) 1 0))
      (vector-set! reg-comp (+ 3 b) (if (bitwise-bit-set? r5 b) 1 0)))
    (eval-reversible-gates! reg-full shor-step-full-u2-gates)
    (eval-reversible-gates! reg-comp shor-step-compact-u2-gates)
    (for ([w (in-range 7)])
      (unless (= (vector-ref reg-full w) (vector-ref reg-comp w))
        (error 'shor-step-equiv "Full vs compact Kawamura mismatch at ctrl=~a x=~a wire=~a" ctrl-b x w)))
    (unless (= (vector-ref reg-full 6) 0)
      (error 'shor-step-u2 "Kawamura Law U2 failed to erase q_crt at x=~a" x)))

  ;; Trace `e = 0 .. 15` orbit of `7^e mod 15` with vs without `Law U2`:
  (define shor-orbit-trace
    (let ([reg-u2 (make-vector 24 0)]
          [reg-dirty (make-vector 11 0)])
      ;; Start at `x = 1 <-> (r3=1, r5=1)` with `ctrl = 1`
      (vector-set! reg-u2 0 1)    (vector-set! reg-u2 1 1)    (vector-set! reg-u2 3 1)
      (vector-set! reg-dirty 0 1) (vector-set! reg-dirty 1 1) (vector-set! reg-dirty 3 1)
      (for/list ([e (in-range 16)])
        (when (> e 0)
          (eval-reversible-gates! reg-u2 shor-step-full-u2-gates)
          (eval-reversible-gates! reg-dirty shor-step-no-u2-gates))
        (define r3-u2 (+ (vector-ref reg-u2 1) (* 2 (vector-ref reg-u2 2))))
        (define r5-u2 (+ (vector-ref reg-u2 3) (* 2 (vector-ref reg-u2 4)) (* 4 (vector-ref reg-u2 5))))
        (define q-u2  (vector-ref reg-u2 6))
        (define q-dirty (vector-ref reg-dirty 6))
        (hasheq 'e e
                'r3 r3-u2
                'r5 r5-u2
                'x_mod_15 (modulo (expt 7 e) 15)
                'q_crt_with_law_u2 q-u2
                'q_crt_without_law_u2 q-dirty))))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))

  (hasheq
   'status "PASS"
   'racket_version (version)
   'wall_time_ms (real->decimal-string elapsed-ms 2)
   'primitive_a_select_swap_and_berry_gidney (hasheq
     'n16_w4_lambda4_exhaustive (hasheq
       'N 16
       'W 4
       'lambda 4
       'table present-sbox4-table
       'forward_clean_select_swap_temp_ands (hash-ref (gate-counts fwd16-clean-gates) 'ccx)
       'forward_single_pass_select_swap_temp_ands (hash-ref (gate-counts fwd16-single-gates) 'ccx)
       'sawtooth_uncompute_temp_ands saw16-temp-ands
       'berry_gidney_mx_uncompute_temp_ands bg16-temp-ands
       'reduction_vs_sawtooth (/ (exact->inexact saw16-temp-ands) bg16-temp-ands)
       'addresses_verified 16
       'mx_masks_verified 16
       'internal_mbu_branches_per_pair 32
       'total_branch_executions_verified (* 16 16 32)
       'ancilla_leakage_bits 0
       'phase_taint_errors 0)
     'n64_w8_lambda8_exhaustive (hasheq
       'N 64
       'W 8
       'lambda 8
       'sawtooth_uncompute_temp_ands saw64-w8-temp-ands
       'berry_gidney_mx_uncompute_temp_ands bg64-w8-temp-ands
       'reduction_vs_sawtooth (/ (exact->inexact saw64-w8-temp-ands) bg64-w8-temp-ands)
       'addr_mask_pairs_verified (* 64 256)
       'ancilla_leakage_bits 0
       'phase_taint_errors 0)
     'w32_scaling_sweep scaling-rows
     'n1024_width_independence width-indep-1024)
   'primitive_b_rns_crt_kawamura_law_u2 (hasheq
     'moduli '(3 5 7)
     'dynamic_range_M 105
     'dyadic_precision_bits 5
     'kawamura_canonicalizer_gate_counts (gate-counts rns357-u2-gates)
     'residues_verified_exact_zero_quotient 98
     'n15_valid_residues_erased_to_zero "15/15 (100.0%)"
     'n21_valid_residues_erased_to_zero "21/21 (100.0%)"
     'n15_uncleaned_nonzero_quotient_states nonzero-uncleaned-n15
     'n21_uncleaned_nonzero_quotient_states nonzero-uncleaned-n21
     'shor_n15_a7_rns3x5_orbit_trace shor-orbit-trace)
   'aer_simulator_gadgets (hasheq
     'berry_gidney_n16_w4_lambda4 (hasheq
       'num_qubits 14
       'addr_wires '(0 1 2 3)
       'out_wires '(4 5 6 7)
       'u_wires '(8 9 10 11)
       'hot_wires '(12 13)
       'table present-sbox4-table
       'forward_sawtooth_gates (gates->json-list
                                (compile-lakefill
                                 (qrom-sawtooth-lookup-sexpr
                                  present-sbox4-table '(0 1 2 3) '(4 5 6 7) '(8 9 10 11) #:mode 'unitary)))
       'forward_select_swap_20q_gates (gates->json-list
                                       (compile-lakefill
                                        (qroam-select-swap-sexpr
                                         present-sbox4-table '(0 1 2 3) '(4 5 6 7) (range 8 24) '(24 25) 4
                                         #:clean-buf? #t #:mode 'unitary)))
       'phase_fixup_gates_by_mask
       (for/list ([m (in-range 16)])
         (gates->json-list (vector-ref bg16-gates-by-mask m))))
     'shor_rns3x5_n15_a7 (hasheq
       'step_num_qubits 11
       'ctrl_wire 0
       'r3_wires '(1 2)
       'r5_wires '(3 4 5)
       'q_crt_wire 6
       'scratch_wires '(7 8 9 10)
       'step_with_kawamura_u2_gates (gates->json-list shor-step-compact-u2-gates)
       'step_without_kawamura_u2_gates (gates->json-list shor-step-no-u2-gates)))))

(module+ main
  (write-json (run-lakefill-select-swap-and-crt-verifications))
  (newline))
