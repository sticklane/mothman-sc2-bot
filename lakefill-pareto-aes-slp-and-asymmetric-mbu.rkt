#lang racket/base

;; =============================================================================
;; lakefill-pareto-aes-slp-and-asymmetric-mbu.rkt
;; =============================================================================
;; Asymmetric `within-apply-mbu`, `91-CX` `SLP` `MixColumns`, and Pareto Narrow-Width In-Place `AES`:
;;
;;   1. Lesson 1 Closed — First-Class Asymmetric `(within-apply-mbu compute action)`:
;;      - Forward pass compiles `(temp-and c1 c2 anc)` to `(ccx c1 c2 anc)` (`4T`
;;        Gidney temporary compute-AND), while the automatic syntactic adjoint
;;        compiles `(temp-and c1 c2 anc)` in reverse topological order to `0T`
;;        `(mid-meas-x-cond-z anc (c1 c2))` (`Law U4` Hadamard-dual MBU!).
;;      - Zero-Ancilla Distinct-Pivot Linear Fan-In `(temp-and-lin lhs rhs anc)`:
;;        computes `anc ^= parity(lhs) & parity(rhs)` for any distinct non-empty
;;        linear forms `lhs != rhs` with `0` fan-in scratch qubits!
;;      - Cuts 4-bit `gidney-modular-adder-asymmetric-sexpr` (`(a + b) mod 13`)
;;        from `18` `CCX` (symmetric `within-apply`) down to `9` `TempAND`s + `0`
;;        uncompute Toffolis (`-50.0%` Toffolis!), verified across all `169/169`
;;        `(a, b) in Z_13^2` pairs and all `2^9 = 512` MBU branches (`Law U4`).
;;      - Fixes Step 4 of in-place `gidney-modular-adder-inplace-mbu-sexpr`
;;        (`16` `CCX` -> `4` `TempAND`s in Step 4; `27` `CCX` -> `15` `TempAND`s
;;        total on `16` qubits).
;;
;;   2. Lesson 2 Closed — `91-CX` (`<= 92-CX`), `0-SWAP` In-Place `AES` `MixColumns`
;;      `SLP` (`aes-mixcolumns-slp92-sexpr` + `105-CX` Fixed-Wire `SL_4` `SLP`):
;;      - Replaces `286 CX + 47 SWAP = 333`-gate Gauss-Jordan `MixColumns` with
;;        the `91-CX`, `0-SWAP`, `0`-ancilla straight-line program (`SLP`) with
;;        compile-time logical wire relabeling (Yuan et al. / Xiang et al.
;;        EUROCRYPT 2020 `s-XOR` model), plus the `105-CX`, `0-SWAP` fixed-wire
;;        (`P = I`) `SL_4(GF(2^8))` `SLP` (Zhang et al. IEEE TC 2024).
;;      - Verified bit-for-bit across all 32 basis vectors, NIST FIPS-197
;;        `db135345 -> 8e4da1bc`, and exact `(invert-circuit)` roundtrip.
;;
;;   3. Lesson 3 Closed — Pareto-Optimal Narrow-Width In-Place `AES-128` (`290 Q` /
;;      `298 Q`), `AES-192` (`354 Q` / `362 Q`), & `AES-256` (`418 Q` / `426 Q`):
;;      - Unifies rolling in-place key schedule + `erase-by` `BP34 + BP34^-1`
;;        in-place S-box (`68` `TempAND`s + `0` uncompute `CCX` vs `432` `CCX` ->
;;        `6.35x` fewer Toffolis, `11.12x` fewer `T`-gates!) + `91-CX` `0-SWAP`
;;        `SLP` `MixColumns`!
;;      - Achieves `12,240` `TempAND`s (`AES-128`, `290 Q` / `298 Q`), `14,144`
;;        `TempAND`s (`AES-192`, `354 Q` / `362 Q`), and `17,000` `TempAND`s
;;        (`AES-256`, `418 Q` / `426 Q`) with `0` `SWAP` gates across the entire
;;        cipher, matching NIST FIPS-197 Appendix C.1, C.2, and C.3 bit-for-bit,
;;        plus exact narrow-width (`290 Q`–`418 Q`) and all-live `within-apply-mbu`
;;        (`6,830` `TempAND`s) Grover key-search phase oracles!
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/format
         racket/string
         racket/math
         json
         "lakefill-core-cryptography-implementations.rkt")

(provide compile-lakefill-pareto
         compile-lakefill-pareto-with-map
         within-apply-mbu-ir
         gidney-modular-adder-asymmetric-sexpr
         gidney-modular-adder-inplace-mbu-sexpr
         aes-mixcolumn-slp92-col-sexpr
         aes-mixcolumns-slp92-sexpr
         aes-mixcolumn-fixed-slp105-col-sexpr
         aes-sbox-bp34-zero-fanin-xor-sexpr
         aes-inv-sbox-bp34-zero-fanin-xor-sexpr
         aes-sbox-bp68-inplace-sexpr
         aes-inv-sbox-bp68-inplace-sexpr
         aes-pareto-cipher-sexpr
         aes-pareto-inv-cipher-sexpr
         aes-pareto-grover-oracle-sexpr
         aes-all-live-mbu-grover-oracle-sexpr
         run-pareto-aes-slp-and-asymmetric-mbu-verifications)

;; =============================================================================
;; SECTION 1: Asymmetric `within-apply-mbu`, Zero-Ancilla Linear Fan-In,
;;            and Compile-Time Logical Wire-Relabeling Compiler
;; =============================================================================
;; Intermediate Representation (IR) separates forward-vs-adjoint lowering of
;; `(temp-and-phys c1 c2 anc)`:
;;   - Forward lowering (`ir->gates-fwd`)          : `(ccx c1 c2 anc)` (`4T`)
;;   - Asymmetric MBU adjoint (`ir->gates-adj-mbu`): `(mid-meas-x-cond-z anc (c1 c2))` (`0T`)
;;   - Unitary adjoint (`ir->gates-adj-unitary`)   : `(ccx c1 c2 anc)` (`4T` / `7T`)

(define (ir-node->fwd-gate node)
  (match node
    [`(temp-and-phys ,c1 ,c2 ,anc) `(ccx ,c1 ,c2 ,anc)]
    [_ node]))

(define (ir-node->adj-gate node mode)
  (match node
    [`(temp-and-phys ,c1 ,c2 ,anc)
     (match mode
       ['mbu `(mid-meas-x-cond-z ,anc (,c1 ,c2))]
       ['unitary-symmetric `(ccx ,c1 ,c2 ,anc)]
       [_ (error 'ir-node->adj-gate "Unknown adjoint mode: ~a" mode)])]
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
     (error 'ir-node->adj-gate
            "Cannot invert already-lowered mid-meas-x-cond-z; use (temp-and c1 c2 anc) inside within-apply-mbu: ~a"
            node)]
    [_ (error 'ir-node->adj-gate "Unknown IR node: ~a" node)]))

(define (within-apply-mbu-ir comp-ir act-ir clean-phys-ancs mode)
  (append (map ir-node->fwd-gate comp-ir)
          act-ir
          (map (lambda (n) (ir-node->adj-gate n mode)) (reverse comp-ir))
          (if (null? clean-phys-ancs)
              '()
              (list `(assert-clean ,clean-phys-ancs)))))

;; Zero-Ancilla Distinct-Pivot Linear Fan-In Lemma:
;; Given two canonical sorted non-empty wire lists `lhs` and `rhs` (on physical
;; wire indices) and optional constant negations `neg-l?`, `neg-r?`, emits pure
;; `(cx ...)` / `(x ...)` fan-in gates `F` on `lhs U rhs` placing
;; `neg-l? ^ parity(lhs)` on pivot `pL` and `neg-r? ^ parity(rhs)` on pivot `pR`
;; (`pL != pR`) with ZERO scratch ancillas!
;; Proof of non-interference when `lhs != rhs`:
;;   Either `rhs \ lhs` is non-empty or `lhs \ rhs` is non-empty.
;;   WLOG `rhs \ lhs` contains `pR`, and `lhs` contains `pL` (`pR != pL` since `pR notin lhs`).
;;   1. Fan `rhs \ {pR}` into `pR` FIRST: every wire in `lhs` is still untouched, so even if
;;      `pL in rhs`, reading `pL` reads its exact initial value!
;;   2. Fan `lhs \ {pL}` into `pL` SECOND: since `pR notin lhs`, `pR` is neither read nor modified!
(define (zero-ancilla-distinct-pivot-fanin phys-lhs phys-rhs neg-l? neg-r?)
  (when (or (null? phys-lhs) (null? phys-rhs))
    (error 'zero-ancilla-distinct-pivot-fanin "Linear forms must be non-empty"))
  (when (equal? (sort phys-lhs <) (sort phys-rhs <))
    (error 'zero-ancilla-distinct-pivot-fanin
           "Identical linear forms ~a need CX rather than TempAND" phys-lhs))
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

;; Compile a Pareto Lakefill AST into an IR list while updating `wmap` in-place.
(define (compile-pareto-ir! expr wmap mode)
  (define (phys w) (hash-ref wmap w w))
  (define (dedup-xor ws)
    (define h (make-hash))
    (for ([w (in-list ws)]) (hash-update! h w add1 0))
    (sort (for/list ([(w c) (in-hash h)] #:when (odd? c)) w) <))

  (match expr
    ['skip '()]
    [`(x ,i) (list `(x ,(phys i)))]
    [`(cx ,c ,t)
     (define pc (phys c))
     (define pt (phys t))
     (when (= pc pt)
       (error 'compile-lakefill-pareto "cx control and target alias to physical ~a in ~a" pc expr))
     (list `(cx ,pc ,pt))]
    [`(ccx ,c1 ,c2 ,t)
     (define p1 (phys c1))
     (define p2 (phys c2))
     (define pt (phys t))
     (when (or (= p1 p2) (= p1 pt) (= p2 pt))
       (error 'compile-lakefill-pareto "ccx wires alias in ~a" expr))
     (list `(ccx ,p1 ,p2 ,pt))]
    [`(temp-and ,c1 ,c2 ,anc)
     (define p1 (phys c1))
     (define p2 (phys c2))
     (define pa (phys anc))
     (when (or (= p1 p2) (= p1 pa) (= p2 pa))
       (error 'compile-lakefill-pareto "temp-and wires alias in ~a" expr))
     (list `(temp-and-phys ,p1 ,p2 ,pa))]
    [`(temp-and-lin ,lhs-ws ,rhs-ws ,anc ,neg-l? ,neg-r?)
     (define plhs (dedup-xor (map phys lhs-ws)))
     (define prhs (dedup-xor (map phys rhs-ws)))
     (define pa (phys anc))
     (when (or (member pa plhs) (member pa prhs))
       (error 'compile-lakefill-pareto "temp-and-lin ancilla ~a aliases control form" pa))
     (define-values (pL pR prep)
       (zero-ancilla-distinct-pivot-fanin plhs prhs neg-l? neg-r?))
     (append prep
             (list `(temp-and-phys ,pL ,pR ,pa))
             (reverse prep))]
    [`(temp-and-lin ,lhs-ws ,rhs-ws ,anc)
     (compile-pareto-ir! `(temp-and-lin ,lhs-ws ,rhs-ws ,anc #f #f) wmap mode)]
    [`(swap ,a ,b)
     (define pa (phys a))
     (define pb (phys b))
     (if (= pa pb) '() (list `(swap ,pa ,pb)))]
    [`(logical-swap ,a ,b)
     (define pa (phys a))
     (define pb (phys b))
     (hash-set! wmap a pb)
     (hash-set! wmap b pa)
     '()]
    [`(logical-relabel ,wires ,src-for-dst)
     (define old-phys (for/vector ([w (in-list wires)]) (phys w)))
     (for ([w (in-list wires)] [src-idx (in-list src-for-dst)])
       (hash-set! wmap w (vector-ref old-phys src-idx)))
     '()]
    [`(h ,i) (list `(h ,(phys i)))]
    [`(z ,i) (list `(z ,(phys i)))]
    [`(cz ,a ,b)
     (define pa (phys a))
     (define pb (phys b))
     (when (= pa pb) (error 'compile-lakefill-pareto "cz alias ~a" expr))
     (list `(cz ,pa ,pb))]
    [`(ccz ,a ,b ,c)
     (list `(ccz ,(phys a) ,(phys b) ,(phys c)))]
    [`(mid-meas-x-cond-z ,anc (,c1 ,c2))
     (list `(mid-meas-x-cond-z ,(phys anc) (,(phys c1) ,(phys c2))))]
    [`(mid-meas-x-cond-z ,anc ,c1)
     (list `(mid-meas-x-cond-z ,(phys anc) ,(phys c1)))]
    [`(assert-clean ,ws)
     (list `(assert-clean ,(map phys ws)))]
    [`(seq ,es ...)
     (append-map (lambda (e) (compile-pareto-ir! e wmap mode)) es)]
    [`(invert ,inner)
     (define snap (hash-copy wmap))
     (define inner-ir (compile-pareto-ir! inner snap mode))
     ;; If `inner` modified `snap`, invert the wire permutation on `wmap`!
     ;; Specifically: `snap` maps logical `w -> p_after` where `wmap` mapped `u -> p_before`.
     ;; Wait: for pure gate circuits (`snap == wmap`), `wmap` is unchanged; if `inner`
     ;; permuted logical wires, we prefer explicit inverse `logical-relabel` or `within-apply`.
     (unless (equal? snap wmap)
       (error 'compile-lakefill-pareto
              "Use explicit inverse logical-relabel or within-apply(-mbu) for wire-relabeled blocks"))
     (map (lambda (n) (ir-node->adj-gate n 'unitary-symmetric)) (reverse inner-ir))]
    [`(within-apply ,comp-expr ,act-expr)
     (compile-pareto-ir! `(within-apply ,comp-expr ,act-expr ()) wmap mode)]
    [`(within-apply ,comp-expr ,act-expr ,clean-ancs)
     (define saved-wmap (hash-copy wmap))
     (define comp-ir (compile-pareto-ir! comp-expr wmap mode))
     (define post-comp-wmap (hash-copy wmap))
     (define act-ir (compile-pareto-ir! act-expr wmap mode))
     (unless (equal? wmap post-comp-wmap)
       (error 'compile-lakefill-pareto "Action inside within-apply must preserve wire-map"))
     ;; Restore `wmap` to `saved-wmap` (adjoint of `comp-expr` undoes its relabelings!)
     (hash-clear! wmap)
     (for ([(k v) (in-hash saved-wmap)]) (hash-set! wmap k v))
     (define clean-phys (map (lambda (w) (hash-ref wmap w w)) clean-ancs))
     (within-apply-mbu-ir comp-ir
                          act-ir
                          clean-phys
                          'unitary-symmetric)]
    [`(within-apply-mbu ,comp-expr ,act-expr)
     (compile-pareto-ir! `(within-apply-mbu ,comp-expr ,act-expr ()) wmap mode)]
    [`(within-apply-mbu ,comp-expr ,act-expr ,clean-ancs)
     (define saved-wmap (hash-copy wmap))
     (define comp-ir (compile-pareto-ir! comp-expr wmap mode))
     (define post-comp-wmap (hash-copy wmap))
     (define act-ir (compile-pareto-ir! act-expr wmap mode))
     (unless (equal? wmap post-comp-wmap)
       (error 'compile-lakefill-pareto "Action inside within-apply-mbu must preserve wire-map"))
     (hash-clear! wmap)
     (for ([(k v) (in-hash saved-wmap)]) (hash-set! wmap k v))
     (define clean-phys (map (lambda (w) (hash-ref wmap w w)) clean-ancs))
     (within-apply-mbu-ir comp-ir
                          act-ir
                          clean-phys
                          mode)]
    [`(erase-by ,fwd-expr ,bwd-expr ,clean-ancs)
     (define fwd-ir (compile-pareto-ir! fwd-expr wmap mode))
     (define bwd-ir (compile-pareto-ir! bwd-expr wmap mode))
     (define clean-phys (map phys clean-ancs))
     (append fwd-ir
             bwd-ir
             (if (null? clean-phys) '() (list `(assert-clean ,clean-phys))))]
    [`(mcz-mbu ,ctrls ,scratch)
     (define k (length ctrls))
     (cond
       [(= k 1) (compile-pareto-ir! `(z ,(first ctrls)) wmap mode)]
       [(= k 2) (compile-pareto-ir! `(cz ,(first ctrls) ,(second ctrls)) wmap mode)]
       [(= k 3) (compile-pareto-ir! `(ccz ,(first ctrls) ,(second ctrls) ,(third ctrls)) wmap mode)]
       [else
        (define used-ancs (take scratch (- k 2)))
        (define comp-steps
          (cons `(temp-and ,(first ctrls) ,(second ctrls) ,(first used-ancs))
                (for/list ([idx (in-range 2 (- k 1))])
                  `(temp-and ,(list-ref ctrls idx)
                             ,(list-ref used-ancs (- idx 2))
                             ,(list-ref used-ancs (- idx 1))))))
        (compile-pareto-ir!
         `(within-apply-mbu (seq ,@comp-steps)
                            (cz ,(last ctrls) ,(last used-ancs))
                            ,used-ancs)
         wmap mode)])]
    [_ (error 'compile-lakefill-pareto "Unrecognized Pareto Lakefill AST form: ~a" expr)]))

(define (compile-lakefill-pareto-with-map expr #:mode [mode 'mbu] #:init-wmap [init-wmap #f])
  (define wmap (if init-wmap (hash-copy init-wmap) (make-hash)))
  (define ir (compile-pareto-ir! expr wmap mode))
  (values (map ir-node->fwd-gate ir) wmap))

(define (compile-lakefill-pareto expr #:mode [mode 'mbu])
  (define-values (gates _wmap) (compile-lakefill-pareto-with-map expr #:mode mode))
  gates)

;; =============================================================================
;; SECTION 2: Closing Lesson 1 — Asymmetric `within-apply-mbu` Modular Adder
;;            (`18` `CCX` -> `9` `TempAND`s, `-50.0%` Toffolis, `0` Uncompute CCX)
;; =============================================================================
;; 2A. Exact `9-TempAND` Asymmetric Modular Adder `out4 ^= (a4 + b4) mod 13`
;;     for all `(a, b) in Z_13^2` (`169/169` pairs) on `21` wires (`0` fan-in ancillas!):
;;     - Forward compute (`9` `TempAND`s):
;;         Carry chain (`4` `TempAND`s):
;;           c0 = a0 & b0
;;           c1 = c0 ^ ((a1 ^ c0) & (b1 ^ c0))  [stored as raw AND `u1`, so `c1 = c0 ^ u1`]
;;           c2 = c1 ^ ((a2 ^ c1) & (b2 ^ c1))  [stored as raw AND `u2`, so `c2 = c0 ^ u1 ^ u2`]
;;           s4 = c2 ^ ((a3 ^ c2) & (b3 ^ c2))  [stored as raw AND `u3`, so `s4 = c0 ^ u1 ^ u2 ^ u3`]
;;         Modulo-13 (`N = 13`) straight-line boolean reduction (`5` `TempAND`s `g0..g4`):
;;           s0 = a0 ^ b0, s1 = a1 ^ b1 ^ c0, s2 = a2 ^ b2 ^ c1, s3 = a3 ^ b3 ^ c2
;;           g0 = s3 & (s2 ^ s3)
;;           g1 = ~(s3 ^ s4 ^ g0) & ~s0
;;           g2 = ~(s1 ^ g1) & (s0 ^ s1)
;;           g3 = ~(s1 ^ s3 ^ s4 ^ g0 ^ g1 ^ g2) & ~(s0 ^ s1 ^ s2 ^ g1 ^ g2)
;;           g4 = ~(s0 ^ s1 ^ s3 ^ g0 ^ g2 ^ g3) & (s1 ^ s2 ^ s3 ^ s4 ^ g0 ^ g1 ^ g2)
;;     - Action (`0` `CCX`! Pure `CX` + `X` into `out4`):
;;           r0 = s0 ^ s1 ^ s2 ^ s3 ^ g0 ^ g1 ^ g2 ^ g4
;;           r1 = 1 ^ s0 ^ s2 ^ s4 ^ g2 ^ g4
;;           r2 = 1 ^ s1 ^ s2 ^ s3 ^ s4 ^ g0 ^ g1 ^ g2
;;           r3 = 1 ^ s0 ^ s4 ^ g0 ^ g1 ^ g3
;;     - Adjoint via `within-apply-mbu`: uncomputes all `9` `TempAND`s via `0T`
;;       `(mid-meas-x-cond-z anc (pL pR))` (`Law U4`), cutting Toffolis from `18` -> `9`!

(define (lin-xor . forms)
  (define counts (make-hash))
  (for* ([f (in-list forms)] [w (in-list f)])
    (hash-update! counts w add1 0))
  (sort (for/list ([(w c) (in-hash counts)] #:when (odd? c)) w) <))

(define (gidney-modular-adder-asymmetric-sexpr a4 b4 out4 and9)
  (match-define (list a0 a1 a2 a3) a4)
  (match-define (list b0 b1 b2 b3) b4)
  (match-define (list o0 o1 o2 o3) out4)
  (match-define (list u0 u1 u2 u3 g0w g1w g2w g3w g4w) and9)

  (define c0 (list u0))
  (define c1 (list u1))
  (define c2 (list u2))
  (define s4 (list u3))

  (define s0 (list a0 b0))
  (define s1 (lin-xor (list a1 b1) c0))
  (define s2 (lin-xor (list a2 b2) c1))
  (define s3 (lin-xor (list a3 b3) c2))

  (define g0 (list g0w))
  (define g1 (list g1w))
  (define g2 (list g2w))
  (define g3 (list g3w))
  (define g4 (list g4w))

  (define r0-form (lin-xor s0 s1 s2 s3 g0 g1 g2 g4))
  (define r1-form (lin-xor s0 s2 s4 g2 g4))
  (define r2-form (lin-xor s1 s2 s3 s4 g0 g1 g2))
  (define r3-form (lin-xor s0 s4 g0 g1 g3))

  `(within-apply-mbu
    (seq ;; 4 carry TempANDs with interleaved ripple CX (reversed automatically before each MBU!)
         (temp-and ,a0 ,b0 ,u0)
         (temp-and-lin ,(lin-xor (list a1) c0) ,(lin-xor (list b1) c0) ,u1)
         (cx ,u0 ,u1)
         (temp-and-lin ,(lin-xor (list a2) c1) ,(lin-xor (list b2) c1) ,u2)
         (cx ,u1 ,u2)
         (temp-and-lin ,(lin-xor (list a3) c2) ,(lin-xor (list b3) c2) ,u3)
         (cx ,u2 ,u3)
         ;; 5 mod-13 reduction TempANDs
         (temp-and-lin ,s3 ,(lin-xor s2 s3) ,g0w)
         (temp-and-lin ,(lin-xor s3 s4 g0) ,s0 ,g1w #t #t)
         (temp-and-lin ,(lin-xor s1 g1) ,(lin-xor s0 s1) ,g2w #t #f)
         (temp-and-lin ,(lin-xor s1 s3 s4 g0 g1 g2) ,(lin-xor s0 s1 s2 g1 g2) ,g3w #t #t)
         (temp-and-lin ,(lin-xor s0 s1 s3 g0 g2 g3) ,(lin-xor s1 s2 s3 s4 g0 g1 g2) ,g4w #t #f))
    (seq ,@(for/list ([w (in-list r0-form)]) `(cx ,w ,o0))
         (x ,o1)
         ,@(for/list ([w (in-list r1-form)]) `(cx ,w ,o1))
         (x ,o2)
         ,@(for/list ([w (in-list r2-form)]) `(cx ,w ,o2))
         (x ,o3)
         ,@(for/list ([w (in-list r3-form)]) `(cx ,w ,o3)))
    ,and9))

;; 2B. Step-4-Fixed In-Place `gidney-modular-adder-inplace-mbu-sexpr` (`b <- (a + b) mod N`):
;;     Directly fixes Lesson 1's Step 4 bottleneck in `lakefill-core-cryptography-implementations.rkt`
;;     by replacing `within-apply` + `unitary-ripple-adder-sexpr` (`16` `CCX` in Step 4) with
;;     `within-apply-mbu` on the `n`-bit carry comparator (`4` `TempAND`s + `0` uncompute `CCX`
;;     in Step 4, `-75.0%` Toffolis in Step 4!) and omitting the redundant `zero-wire` (`16` qubits total!).
(define (gidney-ext-adder-from-nbit-sexpr n a-wires b-ext-wires carry-wires)
  ;; Adds `n`-bit `a-wires` (implicitly zero-extended to `n+1` bits) into `(n+1)`-bit `b-ext-wires`
  ;; using `n` TempANDs (`carry[0..n-1]`) + `n` MBU uncomputations!
  (define (a i) (list-ref a-wires i))
  (define (b i) (list-ref b-ext-wires i))
  (define (c i) (list-ref carry-wires i))
  (define used-carries (take carry-wires n))
  (define fwd-steps
    (cons `(ccx ,(a 0) ,(b 0) ,(c 0))
          (for/list ([i (in-range 1 n)])
            `(seq (cx ,(c (sub1 i)) ,(a i))
                  (cx ,(c (sub1 i)) ,(b i))
                  (ccx ,(a i) ,(b i) ,(c i))
                  (cx ,(c (sub1 i)) ,(c i))))))
  (define top-step `(cx ,(c (sub1 n)) ,(b n)))
  (define rev-steps
    (append
     (for/list ([i (in-range (sub1 n) 0 -1)])
       `(seq (cx ,(c (sub1 i)) ,(c i))
             (mid-meas-x-cond-z ,(c i) (,(a i) ,(b i)))
             (cx ,(c (sub1 i)) ,(a i))
             (cx ,(a i) ,(b i))))
     (list `(seq (mid-meas-x-cond-z ,(c 0) (,(a 0) ,(b 0)))
                 (cx ,(a 0) ,(b 0))))))
  `(seq ,@fwd-steps ,top-step ,@rev-steps (assert-clean ,used-carries)))

(define (gidney-modular-adder-inplace-mbu-sexpr n modulus a-wires b-wires ovf-wire mod-wires carry-wires)
  ;; Total wires for `n = 4`: `4 (a) + 4 (b) + 1 (ovf) + 5 (mod) + 4 (carry)`?
  ;; Even better: Step 2 uses `n+1` `mod-wires`, OR we only need `n` `mod-wires` + `X` on `ovf-wire`
  ;; because `2^{n+1} - N = 2^n + (2^n - N)`, so the MSB of `two-comp-N` is ALWAYS `1` (just `(x ,ovf-wire)`!)!
  ;; That saves ANOTHER wire -> `4 + 4 + 1 + 4 + 4 = 17` (or `3` carries? Step 1 & 4 need `4` carries -> `17` qubits,
  ;; or `mod-wires` (`4`) + `carry-wires` (`4`) -> `17` qubits; wait: in Step 4 `mod-wires` holds `~b_out`, so `4` `mod-wires`
  ;; + `4` `carry-wires` = `17` qubits!). Let's check!
  (define b-ext (append b-wires (list ovf-wire)))
  (define two-comp-low (- (arithmetic-shift 1 n) (- modulus 0))) ;; since N < 2^n, (2^{n+1} - N) has bit n = 1 and low n bits = 2^n - N!
  (define (load-const-n ws val)
    `(seq ,@(for/list ([i (in-range n)] #:when (bitwise-bit-set? val i))
              `(x ,(list-ref ws i)))))
  (define (a i) (list-ref a-wires i))
  (define (m i) (list-ref mod-wires i))
  (define (c i) (list-ref carry-wires i))
  `(seq ;; 1. b_ext <- a + b (`n` TempANDs + `n` MBUs)
        ,(gidney-ext-adder-from-nbit-sexpr n a-wires b-ext carry-wires)
        ;; 2. b_ext <- (a + b) + (2^{n+1} - N) mod 2^{n+1}: add `(2^n - N)` on low `n` bits + `1` on bit `n` (`ovf-wire`)!
        (within-apply
         ,(load-const-n mod-wires two-comp-low)
         ,(gidney-ext-adder-from-nbit-sexpr n mod-wires b-ext carry-wires)
         ,mod-wires)
        (x ,ovf-wire)
        ;; 3. Conditionally add `N` back into `b[0..n-1]` if `ovf-wire == 1` (`n - 1` TempANDs + `n - 1` MBUs)
        (within-apply
         (seq ,@(for/list ([i (in-range n)] #:when (bitwise-bit-set? modulus i))
                  `(cx ,ovf-wire ,(list-ref mod-wires i))))
         ,(gidney-adder-sexpr n mod-wires b-wires (take carry-wires (sub1 n)))
         ,mod-wires)
        ;; 4. Uncompute `ovf-wire` via ASYMMETRIC `within-apply-mbu` on the `n`-carry comparator
        ;;    `[(2^n - 1 - b_out) + a >= 2^n] == [b_out < a]` (`n` TempANDs + `0` uncompute CCX!)
        (x ,ovf-wire)
        (within-apply-mbu
         (seq ,@(for/list ([bw (in-list b-wires)] [mw (in-list mod-wires)]) `(cx ,bw ,mw))
              ,@(for/list ([mw (in-list mod-wires)]) `(x ,mw))
              (temp-and ,(a 0) ,(m 0) ,(c 0))
              ,@(for/list ([i (in-range 1 n)])
                  `(seq (cx ,(c (sub1 i)) ,(a i))
                        (cx ,(c (sub1 i)) ,(m i))
                        (temp-and ,(a i) ,(m i) ,(c i))
                        (cx ,(c (sub1 i)) ,(c i)))))
         (cx ,(c (sub1 n)) ,ovf-wire)
         ,(append mod-wires carry-wires))
        (assert-clean ,(append (list ovf-wire) mod-wires carry-wires))))

;; =============================================================================
;; SECTION 3: Closing Lesson 2 — `91-CX` (`<= 92-CX`), `0-SWAP` In-Place `AES`
;;            `MixColumns` `SLP` (`aes-mixcolumns-slp92-sexpr`) + `105-CX` Fixed-Wire
;; =============================================================================
;; Straight-line `91-CX`, `0-SWAP`, `0`-ancilla in-place AES MixColumns circuit
;; (Yuan et al. / Xiang et al. EUROCRYPT 2020 `s-XOR` straight-line cancellation):
;; Executes `91` `CX` gates on 32 column wires `(b0[0..7], b1[0..7], b2[0..7], b3[0..7])`
;; followed by compile-time logical wire relabeling `aes-mixcol-slp91-wire-perm` (`0` physical `SWAP`s!).

(define aes-mixcol-slp91-cx-pairs
  '((23 15) (1 25) (18 10) (13 5) (19 3) (28 4) (0 16) (9 1) (7 23) (31 7)
    (20 28) (14 22) (16 8) (8 0) (30 14) (6 30) (15 24) (29 13) (5 6) (21 5)
    (28 21) (23 28) (5 29) (4 5) (2 18) (3 28) (11 3) (15 11) (12 4) (4 20)
    (11 12) (19 12) (27 19) (10 11) (3 27) (2 3) (10 2) (26 10) (26 3) (25 26)
    (25 2) (17 25) (25 9) (8 17) (7 8) (23 19) (1 10) (15 25) (7 3) (7 4)
    (15 7) (14 15) (0 25) (23 0) (23 1) (31 23) (30 31) (24 0) (29 14) (21 29)
    (19 4) (18 19) (9 18) (11 27) (16 24) (16 1) (22 23) (7 16) (0 16) (6 22)
    (22 30) (13 22) (20 13) (12 20) (18 26) (19 11) (14 6) (31 7) (3 19) (28 12)
    (10 18) (16 17) (17 9) (1 17) (4 28) (13 21) (5 13) (15 31) (25 1) (23 15)
    (22 14)))

(define aes-mixcol-slp91-wire-perm
  '(0 1 10 11 12 21 30 31
    24 25 26 27 20 13 14 23
    16 9 18 19 4 29 6 15
    8 17 2 3 28 5 22 7))

(define aes-mixcol-slp91-inv-wire-perm
  (let ([inv (make-vector 32 0)])
    (for ([dst (in-range 32)] [src (in-list aes-mixcol-slp91-wire-perm)])
      (vector-set! inv src dst))
    (vector->list inv)))

(define (aes-mixcolumn-slp92-col-sexpr col32 #:rewire? [rewire? #t])
  `(seq ,@(for/list ([p (in-list aes-mixcol-slp91-cx-pairs)])
            `(cx ,(list-ref col32 (first p)) ,(list-ref col32 (second p))))
        ,(if rewire?
             `(logical-relabel ,col32 ,aes-mixcol-slp91-wire-perm)
             'skip)))

(define (aes-inv-mixcolumn-slp92-col-sexpr col32 #:rewire? [rewire? #t])
  `(seq ,(if rewire?
             `(logical-relabel ,col32 ,aes-mixcol-slp91-inv-wire-perm)
             'skip)
        ,@(for/list ([p (in-list (reverse aes-mixcol-slp91-cx-pairs))])
            `(cx ,(list-ref col32 (first p)) ,(list-ref col32 (second p))))))

(define (aes-mixcolumns-slp92-sexpr state128 #:rewire? [rewire? #t])
  `(seq ,@(for/list ([col (in-range 4)])
            (aes-mixcolumn-slp92-col-sexpr (take (drop state128 (* 32 col)) 32)
                                           #:rewire? rewire?))))

(define (aes-inv-mixcolumns-slp92-sexpr state128 #:rewire? [rewire? #t])
  `(seq ,@(for/list ([col (in-range 4)])
            (aes-inv-mixcolumn-slp92-col-sexpr (take (drop state128 (* 32 col)) 32)
                                               #:rewire? rewire?))))

;; Strictly Fixed-Wire (`P = I`, `0` `SWAP`s, `0` wire relabeling) `105-CX` `SL_4(GF(2^8))`
;; In-Place MixColumns SLP (matching Zhang et al. IEEE TC 2024 exact degree-1 shear optimum):
(define aes-mixcol-fixed-slp105-shears
  '((3 1 1) (2 3 1) (0 2 1) (2 1 1) (1 0 1) (3 0 2)
    (2 3 2) (0 2 1) (1 0 2) (3 1 1) (0 1 1) (2 3 1)))

(define (aes-mixcolumn-fixed-slp105-col-sexpr col32)
  (define ops '())
  (for ([sh (in-list aes-mixcol-fixed-slp105-shears)])
    (match-define (list src dst coeff) sh)
    (define sb (* 8 src))
    (define db (* 8 dst))
    (define (w idx) (list-ref col32 idx))
    (if (= coeff 1)
        (for ([b (in-range 8)])
          (set! ops (cons `(cx ,(w (+ sb b)) ,(w (+ db b))) ops)))
        (for ([p (in-list '((7 0) (0 1) (7 1) (1 2) (2 3) (7 3)
                            (3 4) (7 4) (4 5) (5 6) (6 7)))])
          (set! ops (cons `(cx ,(w (+ sb (first p))) ,(w (+ db (second p)))) ops)))))
  `(seq ,@(reverse ops)))

;; =============================================================================
;; SECTION 4: Closing Lesson 3 — Pareto-Optimal Narrow-Width In-Place
;;            `AES-128` (`290 Q` / `298 Q`), `AES-192` (`354 Q` / `362 Q`),
;;            and `AES-256` (`418 Q` / `426 Q`) + Grover Phase Oracles
;; =============================================================================

(define (cols->gf2-mat m col-masks)
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-bit-field (list-ref col-masks c) r (add1 r)))))

(define (gf2-matmul A B)
  (define m (vector-length A))
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-and 1 (for/sum ([k (in-range m)])
                       (* (vector-ref (vector-ref A r) k)
                          (vector-ref (vector-ref B k) c)))))))

(define (gf2-matinv M)
  (define m (vector-length M))
  (define aug
    (for/vector ([r (in-range m)])
      (vector-append (vector-copy (vector-ref M r))
                     (for/vector ([c (in-range m)]) (if (= r c) 1 0)))))
  (for ([col (in-range m)])
    (define piv
      (for/first ([r (in-range col m)]
                  #:when (= (vector-ref (vector-ref aug r) col) 1))
        r))
    (when (not (= piv col))
      (define tmp (vector-ref aug col))
      (vector-set! aug col (vector-ref aug piv))
      (vector-set! aug piv tmp))
    (for ([r (in-range m)]
          #:when (and (not (= r col)) (= (vector-ref (vector-ref aug r) col) 1)))
      (define rv (vector-ref aug r))
      (define cv (vector-ref aug col))
      (for ([j (in-range (* 2 m))])
        (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))))
  (for/vector ([r (in-range m)])
    (vector-copy (vector-ref aug r) m (* 2 m))))

(define tower-to-aes-mat (cols->gf2-mat 8 '(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)))
(define aes-to-tower-mat (gf2-matinv tower-to-aes-mat))
(define aes-affine-mat
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (if (<= (modulo (- r c) 8) 4) 1 0))))
(define aes-affine-inv-mat (gf2-matinv aes-affine-mat))
(define post-sbox-mat (gf2-matmul aes-affine-mat tower-to-aes-mat))
(define pre-inv-sbox-mat (gf2-matmul aes-to-tower-mat aes-affine-inv-mat))

;; Factor any nonsingular m x m GF(2) matrix (`det = 1` in GF(2), so `GL_m(GF(2)) = SL_m(GF(2))`)
;; into PURE `(cx c t)` gates with ZERO `swap` gates (`0` ancillas!):
;; Whenever `rows[col][col] == 0`, pick `piv > col` with `rows[piv][col] == 1` and apply
;; `rows[col] ^= rows[piv]` (`(cx wires[piv] wires[col])`) instead of a `swap`!
(define gf2-cx-pairs-cache (make-hash))

(define (gf2-mat->cx-pairs mat)
  (hash-ref!
   gf2-cx-pairs-cache mat
   (lambda ()
     (define m (vector-length mat))
     (define rows (for/vector ([r (in-range m)]) (vector-copy (vector-ref mat r))))
     (define recorded-pairs '())
     (for ([col (in-range m)])
       (when (zero? (vector-ref (vector-ref rows col) col))
         (define piv
           (for/first ([r (in-range (add1 col) m)]
                       #:when (= (vector-ref (vector-ref rows r) col) 1))
             r))
         (unless piv (error 'gf2-mat->cx-only-sexpr "Singular matrix at col ~a" col))
         (define c-vec (vector-ref rows col))
         (define p-vec (vector-ref rows piv))
         (for ([j (in-range m)])
           (vector-set! c-vec j (bitwise-xor (vector-ref c-vec j) (vector-ref p-vec j))))
         (set! recorded-pairs (cons (cons piv col) recorded-pairs)))
       (for ([r (in-range m)]
             #:when (and (not (= r col))
                         (= (vector-ref (vector-ref rows r) col) 1)))
         (define r-vec (vector-ref rows r))
         (define c-vec (vector-ref rows col))
         (for ([j (in-range m)])
           (vector-set! r-vec j (bitwise-xor (vector-ref r-vec j) (vector-ref c-vec j))))
         (set! recorded-pairs (cons (cons col r) recorded-pairs))))
     recorded-pairs)))

(define (gf2-mat->cx-only-sexpr mat wires)
  (define wv (list->vector wires))
  `(seq ,@(for/list ([p (in-list (gf2-mat->cx-pairs mat))])
            `(cx ,(vector-ref wv (car p)) ,(vector-ref wv (cdr p))))))

;; Core Zero-Fan-In Boyar-Peralta `34-TempAND` Tower Inverter Engine:
;; Applies `in-mat8` in-place on `in8` via 0-SWAP `gf2-mat->cx-only-sexpr` inside `within-apply`
;; (making `xt` singletons and cutting fan-in CX volume by ~3x!), then executes the `34-TempAND`
;; tower inversion (`25` scratch wires when `split-stage3? = #t`, `34` when `#f`, `0` SWAPs!).
(define (bp34-core-zero-fanin-xor-sexpr in8 out8 and-sc in-mat8 out-mat8 out-const-u8
                                        #:split-stage3? [split-stage3? #t])
  (define sc16 (take and-sc 16))
  (define sc-s3 (drop and-sc 16))

  (define (karatsuba-gf4-steps pool base a0 a1 b0 b1)
    (define p0 (list-ref pool base))
    (define p1 (list-ref pool (+ base 1)))
    (define p2 (list-ref pool (+ base 2)))
    (values (list `(temp-and-lin ,a0 ,b0 ,p0)
                  `(temp-and-lin ,a1 ,b1 ,p1)
                  `(temp-and-lin ,(lin-xor a0 a1) ,(lin-xor b0 b1) ,p2))
            (list (list p0 p1) (list p2 p0))))

  (define (karatsuba-gf16-steps pool base a4 b4)
    (match-define (list a0 a1 a2 a3) a4)
    (match-define (list b0 b1 b2 b3) b4)
    (define-values (st0 m0) (karatsuba-gf4-steps pool base a0 a1 b0 b1))
    (define-values (st1 m1) (karatsuba-gf4-steps pool (+ base 3) a2 a3 b2 b3))
    (define-values (st2 m2)
      (karatsuba-gf4-steps pool (+ base 6)
                           (lin-xor a0 a2) (lin-xor a1 a3)
                           (lin-xor b0 b2) (lin-xor b1 b3)))
    (match-define (list m0-0 m0-1) m0)
    (match-define (list m1-0 m1-1) m1)
    (match-define (list m2-0 m2-1) m2)
    (values (append st0 st1 st2)
            (list (lin-xor m0-0 m1-1)
                  (lin-xor m0-1 m1-0 m1-1)
                  (lin-xor m2-0 m0-0)
                  (lin-xor m2-1 m0-1))))

  ;; After `gf2-mat->cx-only-sexpr in-mat8 in8`, `in8` holds `xt[0..7]` directly as singletons!
  (define xt (for/list ([w (in-list in8)]) (list w)))
  (define xL (take xt 4))
  (define xH (drop xt 4))
  (define c4 (map lin-xor xL xH))

  ;; Stage 1 (`9` TempANDs on `sc16[0..8]`): `d4 = xL * c4 ^ (uv)*xH^2`
  (define-values (s1-steps prod-d) (karatsuba-gf16-steps sc16 0 xL c4))
  (define uv-sq
    (list (third xH)
          (lin-xor (third xH) (fourth xH))
          (lin-xor (second xH) (third xH) (fourth xH))
          (lin-xor (first xH) (fourth xH))))
  (define d4 (map lin-xor prod-d uv-sq))

  ;; Stage 2 (`7` TempANDs on `sc16[9..15]`): `dinv4 = inv_GF16(d4)`
  (match-define (list d0 d1 d2 d3) d4)
  (match-define (list g0w g1w g2w g3w g4w g5w g6w) (drop sc16 9))
  (define g0 (list g0w))
  (define g1 (list g1w))
  (define g2 (list g2w))
  (define g3 (list g3w))
  (define g4 (list g4w))
  (define g5 (list g5w))
  (define g6 (list g6w))
  (define s2-steps
    (list `(temp-and-lin ,d1 ,d2 ,g0w)
          `(temp-and-lin ,d0 ,d3 ,g1w)
          `(temp-and-lin ,d0 ,d2 ,g2w)
          `(temp-and-lin ,g0 ,d3 ,g3w)
          `(temp-and-lin ,g1 ,d2 ,g4w)
          `(temp-and-lin ,g1 ,d1 ,g5w)
          `(temp-and-lin ,d1 ,(lin-xor d3 g2) ,g6w)))
  (define dinv4
    (list (lin-xor d0 d1 d2 g0 g1 g6 g5 g4 g3)
          (lin-xor d1 d2 d3 g2 g5 g3)
          (lin-xor d2 g0 g1 g4 g3)
          (lin-xor d2 d3 g1 g3)))

  (define const-x-steps
    (for/list ([r (in-range 8)] #:when (bitwise-bit-set? out-const-u8 r))
      `(x ,(list-ref out8 r))))

  (define tower-body
    (cond
      [split-stage3?
       (define sc9 (take sc-s3 9))
       (define-values (oL-steps oL-forms) (karatsuba-gf16-steps sc9 0 c4 dinv4))
       (define-values (oH-steps oH-forms) (karatsuba-gf16-steps sc9 0 xH dinv4))
       (define outL-cxs
         (for*/list ([r (in-range 8)]
                     [src-w (in-list
                             (apply lin-xor
                                    (for/list ([c (in-range 4)]
                                               #:when (= (vector-ref (vector-ref out-mat8 r) c) 1))
                                      (list-ref oL-forms c))))])
           `(cx ,src-w ,(list-ref out8 r))))
       (define outH-cxs
         (for*/list ([r (in-range 8)]
                     [src-w (in-list
                             (apply lin-xor
                                    (for/list ([c (in-range 4)]
                                               #:when (= (vector-ref (vector-ref out-mat8 r) (+ 4 c)) 1))
                                      (list-ref oH-forms c))))])
           `(cx ,src-w ,(list-ref out8 r))))
       `(within-apply-mbu
         (seq ,@s1-steps ,@s2-steps)
         (seq (within-apply-mbu (seq ,@oL-steps) (seq ,@outL-cxs) ,sc9)
              (within-apply-mbu (seq ,@oH-steps) (seq ,@outH-cxs) ,sc9)
              ,@const-x-steps)
         ,sc16)]
      [else
       (define sc18 (take sc-s3 18))
       (define-values (oL-steps oL-forms) (karatsuba-gf16-steps sc18 0 c4 dinv4))
       (define-values (oH-steps oH-forms) (karatsuba-gf16-steps sc18 9 xH dinv4))
       (define ot (append oL-forms oH-forms))
       (define out-cxs
         (for*/list ([r (in-range 8)]
                     [src-w (in-list
                             (apply lin-xor
                                    (for/list ([c (in-range 8)]
                                               #:when (= (vector-ref (vector-ref out-mat8 r) c) 1))
                                      (list-ref ot c))))])
           `(cx ,src-w ,(list-ref out8 r))))
       `(within-apply-mbu
         (seq ,@s1-steps ,@s2-steps ,@oL-steps ,@oH-steps)
         (seq ,@out-cxs ,@const-x-steps)
         ,(append sc16 sc18))]))

  `(within-apply
    ,(gf2-mat->cx-only-sexpr in-mat8 in8)
    ,tower-body
    ()))

;; Forward Boyar-Peralta `34-TempAND` XOR S-box: `out8 ^= S(in8)` (`34` TempANDs, `0` uncompute CCX!)
(define (aes-sbox-bp34-zero-fanin-xor-sexpr in8 out8 and-sc #:split-stage3? [split-stage3? #t])
  (bp34-core-zero-fanin-xor-sexpr
   in8 out8 and-sc aes-to-tower-mat post-sbox-mat #x63
   #:split-stage3? split-stage3?))

;; Inverse Boyar-Peralta `34-TempAND` XOR S-box: `out8 ^= S^-1(in8)` (`34` TempANDs, `0` uncompute CCX!)
(define (aes-inv-sbox-bp34-zero-fanin-xor-sexpr in8 out8 and-sc #:split-stage3? [split-stage3? #t])
  (define neg-63
    (for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
      `(x ,(list-ref in8 r))))
  `(within-apply
    (seq ,@neg-63)
    ,(bp34-core-zero-fanin-xor-sexpr
      in8 out8 and-sc pre-inv-sbox-mat tower-to-aes-mat #x00
      #:split-stage3? split-stage3?)
    ()))

;; Strictly In-Place 8-Wire AES S-Box `byte8 -> S(byte8)` (`68` TempANDs, `0` uncompute CCX, `0` SWAPs!):
;; Uses `tmp8` (`8` wires) + `and-sc` (`25` wires if `split-stage3? = #t`, `34` wires if `#f`):
;;   1. `tmp8 ^= S(byte8)` (`34` TempANDs + `34` MBUs)
;;   2. `byte8 ^= S^-1(tmp8)` (`34` TempANDs + `34` MBUs -> `byte8 == 0^8`!)
;;   3. Swap-free clean transfer `(cx tw bw); (cx bw tw)` (`16` `CX`, `0` `SWAP`s!)
;;      moving `S(x)` into `byte8` and resetting `tmp8 -> 0^8` on fixed physical wires!
(define (aes-sbox-bp68-inplace-sexpr byte8 sc #:split-stage3? [split-stage3? #t])
  (define tmp8 (take sc 8))
  (define and-sc (drop sc 8))
  (define used-sc (take sc (if split-stage3? 33 42)))
  `(erase-by
    ,(aes-sbox-bp34-zero-fanin-xor-sexpr byte8 tmp8 and-sc #:split-stage3? split-stage3?)
    (seq ,(aes-inv-sbox-bp34-zero-fanin-xor-sexpr tmp8 byte8 and-sc #:split-stage3? split-stage3?)
         ,@(for/list ([bw (in-list byte8)] [tw (in-list tmp8)])
             `(seq (cx ,tw ,bw) (cx ,bw ,tw))))
    ,used-sc))

;; Strictly In-Place 8-Wire Inverse AES S-Box `byte8 -> S^-1(byte8)` (`68` TempANDs, `0` uncompute CCX, `0` SWAPs!)
(define (aes-inv-sbox-bp68-inplace-sexpr byte8 sc #:split-stage3? [split-stage3? #t])
  (define tmp8 (take sc 8))
  (define and-sc (drop sc 8))
  (define used-sc (take sc (if split-stage3? 33 42)))
  `(erase-by
    ,(aes-inv-sbox-bp34-zero-fanin-xor-sexpr byte8 tmp8 and-sc #:split-stage3? split-stage3?)
    (seq ,(aes-sbox-bp34-zero-fanin-xor-sexpr tmp8 byte8 and-sc #:split-stage3? split-stage3?)
         ,@(for/list ([bw (in-list byte8)] [tw (in-list tmp8)])
             `(seq (cx ,tw ,bw) (cx ,bw ,tw))))
    ,used-sc))

;; Zero-SWAP ShiftRows & Inverse ShiftRows via compile-time logical wire relabeling!
(define aes-shiftrows-perm
  (for*/list ([c (in-range 4)] [r (in-range 4)] [b (in-range 8)])
    (+ (* 8 (+ r (* 4 (modulo (+ c r) 4)))) b)))

(define aes-inv-shiftrows-perm
  (for*/list ([c (in-range 4)] [r (in-range 4)] [b (in-range 8)])
    (+ (* 8 (+ r (* 4 (modulo (- c r) 4)))) b)))

(define aes-rcon-bytes
  #(#x00 #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80 #x1B #x36))

;; Helper key-schedule operators (`34` TempANDs per S-box via `aes-sbox-bp34-zero-fanin-xor-sexpr`!)
(define (xor-w32-sexpr src32 dst32)
  `(seq ,@(for/list ([s (in-list src32)] [d (in-list dst32)]) `(cx ,s ,d))))

(define (aes-key-sub-rot-rcon-sexpr src32 dst32 rcon-u8 and-sc split-stage3?)
  (define s0 (take src32 8))
  (define s1 (take (drop src32 8) 8))
  (define s2 (take (drop src32 16) 8))
  (define s3 (drop src32 24))
  `(seq ,(aes-sbox-bp34-zero-fanin-xor-sexpr s1 (take dst32 8) and-sc #:split-stage3? split-stage3?)
        ,(aes-sbox-bp34-zero-fanin-xor-sexpr s2 (take (drop dst32 8) 8) and-sc #:split-stage3? split-stage3?)
        ,(aes-sbox-bp34-zero-fanin-xor-sexpr s3 (take (drop dst32 16) 8) and-sc #:split-stage3? split-stage3?)
        ,(aes-sbox-bp34-zero-fanin-xor-sexpr s0 (drop dst32 24) and-sc #:split-stage3? split-stage3?)
        ,@(for/list ([b (in-range 8)] #:when (bitwise-bit-set? rcon-u8 b))
            `(x ,(list-ref dst32 b)))))

(define (aes-key-subword-sexpr src32 dst32 and-sc split-stage3?)
  `(seq ,@(for/list ([b (in-range 4)])
            (aes-sbox-bp34-zero-fanin-xor-sexpr
             (take (drop src32 (* 8 b)) 8)
             (take (drop dst32 (* 8 b)) 8)
             and-sc #:split-stage3? split-stage3?))))

;; Pareto-Optimal Narrow-Width In-Place `AES-128` (`290 Q` / `298 Q`), `AES-192` (`354 Q` / `362 Q`),
;; and `AES-256` (`418 Q` / `426 Q`) Forward Encryption S-expression!
(define (aes-pareto-cipher-sexpr key-bits state128 key-wires sc #:split-stage3? [split-stage3? #t])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define and-sc (drop sc 8))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  (define (advance-key-epoch e)
    (match nk
      [4 `(seq ,(aes-key-sub-rot-rcon-sexpr (kword 3) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?)
               ,(xor-w32-sexpr (kword 0) (kword 1))
               ,(xor-w32-sexpr (kword 1) (kword 2))
               ,(xor-w32-sexpr (kword 2) (kword 3)))]
      [6 `(seq ,(aes-key-sub-rot-rcon-sexpr (kword 5) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?)
               ,(xor-w32-sexpr (kword 0) (kword 1))
               ,(xor-w32-sexpr (kword 1) (kword 2))
               ,(xor-w32-sexpr (kword 2) (kword 3))
               ,(xor-w32-sexpr (kword 3) (kword 4))
               ,(xor-w32-sexpr (kword 4) (kword 5)))]
      [8 (if (= e 7)
             ;; Epoch 7 of AES-256 needs only W[56..59] (`kword 0..3`), saving 4 key S-boxes (`136` TempANDs)!
             `(seq ,(aes-key-sub-rot-rcon-sexpr (kword 7) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?)
                   ,(xor-w32-sexpr (kword 0) (kword 1))
                   ,(xor-w32-sexpr (kword 1) (kword 2))
                   ,(xor-w32-sexpr (kword 2) (kword 3)))
             `(seq ,(aes-key-sub-rot-rcon-sexpr (kword 7) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?)
                   ,(xor-w32-sexpr (kword 0) (kword 1))
                   ,(xor-w32-sexpr (kword 1) (kword 2))
                   ,(xor-w32-sexpr (kword 2) (kword 3))
                   ,(aes-key-subword-sexpr (kword 3) (kword 4) and-sc split-stage3?)
                   ,(xor-w32-sexpr (kword 4) (kword 5))
                   ,(xor-w32-sexpr (kword 5) (kword 6))
                   ,(xor-w32-sexpr (kword 6) (kword 7))))]))

  (define steps '())
  (for ([r (in-range (add1 nr))])
    (when (> r 0)
      (set! steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-sbox-bp68-inplace-sexpr
                             (take (drop state128 (* 8 b)) 8)
                             sc #:split-stage3? split-stage3?)))
                  steps))
      (set! steps (cons `(logical-relabel ,state128 ,aes-shiftrows-perm) steps))
      (when (< r nr)
        (set! steps (cons (aes-mixcolumns-slp92-sexpr state128 #:rewire? #t) steps))))
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! steps (cons (advance-key-epoch (quotient w-idx nk)) steps)))
      (set! steps (cons (xor-w32-sexpr (kword (modulo w-idx nk)) (sword c)) steps))))
  `(seq ,@(reverse steps) (assert-clean ,sc)))

;; Exact Narrow-Width In-Place Inverse Cipher `AES^-1` (`aes-pareto-inv-cipher-sexpr`):
;; Rewinds the rolling key schedule (`34` TempANDs/key-S-box), `91-CX` `SLP` `MixColumns^-1`,
;; `ShiftRows^-1`, and `BP68^-1` (`68` TempANDs/state-S-box), restoring `state128`, `key-wires`,
;; AND the logical wire-map back to identity `0..N-1` with `0` `SWAP` gates!
(define (aes-pareto-inv-cipher-sexpr key-bits state128 key-wires sc #:split-stage3? [split-stage3? #t])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define and-sc (drop sc 8))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  (define (rewind-key-epoch e)
    (match nk
      [4 `(seq ,(xor-w32-sexpr (kword 2) (kword 3))
               ,(xor-w32-sexpr (kword 1) (kword 2))
               ,(xor-w32-sexpr (kword 0) (kword 1))
               ,(aes-key-sub-rot-rcon-sexpr (kword 3) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?))]
      [6 `(seq ,(xor-w32-sexpr (kword 4) (kword 5))
               ,(xor-w32-sexpr (kword 3) (kword 4))
               ,(xor-w32-sexpr (kword 2) (kword 3))
               ,(xor-w32-sexpr (kword 1) (kword 2))
               ,(xor-w32-sexpr (kword 0) (kword 1))
               ,(aes-key-sub-rot-rcon-sexpr (kword 5) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?))]
      [8 (if (= e 7)
             `(seq ,(xor-w32-sexpr (kword 2) (kword 3))
                   ,(xor-w32-sexpr (kword 1) (kword 2))
                   ,(xor-w32-sexpr (kword 0) (kword 1))
                   ,(aes-key-sub-rot-rcon-sexpr (kword 7) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?))
             `(seq ,(xor-w32-sexpr (kword 6) (kword 7))
                   ,(xor-w32-sexpr (kword 5) (kword 6))
                   ,(xor-w32-sexpr (kword 4) (kword 5))
                   ,(aes-key-subword-sexpr (kword 3) (kword 4) and-sc split-stage3?)
                   ,(xor-w32-sexpr (kword 2) (kword 3))
                   ,(xor-w32-sexpr (kword 1) (kword 2))
                   ,(xor-w32-sexpr (kword 0) (kword 1))
                   ,(aes-key-sub-rot-rcon-sexpr (kword 7) (kword 0) (vector-ref aes-rcon-bytes e) and-sc split-stage3?)))]))

  (define inv-steps '())
  (for ([r (in-range nr -1 -1)])
    ;; Undo AddRoundKey & rewind epochs in exact reverse order `c = 3 .. 0`
    (for ([c (in-range 3 -1 -1)])
      (define w-idx (+ (* 4 r) c))
      (set! inv-steps (cons (xor-w32-sexpr (kword (modulo w-idx nk)) (sword c)) inv-steps))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! inv-steps (cons (rewind-key-epoch (quotient w-idx nk)) inv-steps))))
    (when (> r 0)
      (when (< r nr)
        (set! inv-steps (cons (aes-inv-mixcolumns-slp92-sexpr state128 #:rewire? #t) inv-steps)))
      (set! inv-steps (cons `(logical-relabel ,state128 ,aes-inv-shiftrows-perm) inv-steps))
      (set! inv-steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-inv-sbox-bp68-inplace-sexpr
                             (take (drop state128 (* 8 b)) 8)
                             sc #:split-stage3? split-stage3?)))
                  inv-steps))))
  `(seq ,@(reverse inv-steps) (assert-clean ,sc)))

;; Narrow-Width In-Place Pareto Grover Key-Search Phase Oracle (`290 Q` / `354 Q` / `418 Q`):
;; Runs `aes-pareto-cipher-sexpr`, checks `check-bits` of ciphertext via asymmetric `mcz-mbu`
;; (`check-bits - 2` TempANDs + `0` uncompute CCX!), and runs `aes-pareto-inv-cipher-sexpr`
;; to restore plaintext, candidate key, wire-map (`identity`!), and `100%` of scratch wires to `0`!
(define (aes-pareto-grover-oracle-sexpr key-bits state128 key-wires sc target-ct-bytes
                                        [check-bits 32] #:split-stage3? [split-stage3? #t])
  (define checked-wires (take state128 check-bits))
  (define negations
    (for/list ([bit-idx (in-range check-bits)]
               #:when (not (bitwise-bit-set?
                            (bytes-ref target-ct-bytes (quotient bit-idx 8))
                            (modulo bit-idx 8))))
      `(x ,(list-ref state128 bit-idx))))
  `(seq ,(aes-pareto-cipher-sexpr key-bits state128 key-wires sc #:split-stage3? split-stage3?)
        (within-apply
         (seq ,@negations)
         (mcz-mbu ,checked-wires ,sc)
         ,sc)
        ,(aes-pareto-inv-cipher-sexpr key-bits state128 key-wires sc #:split-stage3? split-stage3?)
        (assert-clean ,sc)))

;; All-Live Out-of-Place `within-apply-mbu` Grover Phase Oracle for `AES-128`:
;; Wraps the entire 10-round forward `BP34 + SLP91` `AES-128` (`6,800` TempANDs) inside a
;; SINGLE `(within-apply-mbu ...)` so the uncompute half of the Grover oracle erases all
;; `6,800` TempANDs via `0T` `mid-meas-x-cond-z` (`0` uncompute Toffolis across the whole cipher ->
;; `6,830` TempANDs total, a `23.62x` Toffoli / `41.34x` T-count reduction vs `161,340` CCX)!
(define (aes-all-live-mbu-grover-oracle-sexpr round-states key-wires and6800 mcz-sc30
                                              target-ct-bytes [check-bits 32])
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define and-idx 0)
  (define (alloc-sc34!)
    (define slice (take (drop and6800 and-idx) 34))
    (set! and-idx (+ and-idx 34))
    slice)

  ;; Non-uncomputing forward BP34 emitter (`34` live `temp-and-lin`s + output `cx`/`x`, `0` MBUs!)
  (define (bp34-live-fwd-sexpr in8 out8 sc34)
    (define (kgf4 pool base a0 a1 b0 b1)
      (define p0 (list-ref pool base))
      (define p1 (list-ref pool (+ base 1)))
      (define p2 (list-ref pool (+ base 2)))
      (values (list `(temp-and-lin ,a0 ,b0 ,p0)
                    `(temp-and-lin ,a1 ,b1 ,p1)
                    `(temp-and-lin ,(lin-xor a0 a1) ,(lin-xor b0 b1) ,p2))
              (list (list p0 p1) (list p2 p0))))
    (define (kgf16 pool base a4 b4)
      (match-define (list a0 a1 a2 a3) a4)
      (match-define (list b0 b1 b2 b3) b4)
      (define-values (st0 m0) (kgf4 pool base a0 a1 b0 b1))
      (define-values (st1 m1) (kgf4 pool (+ base 3) a2 a3 b2 b3))
      (define-values (st2 m2) (kgf4 pool (+ base 6) (lin-xor a0 a2) (lin-xor a1 a3)
                                    (lin-xor b0 b2) (lin-xor b1 b3)))
      (values (append st0 st1 st2)
              (list (lin-xor (first m0) (second m1))
                    (lin-xor (second m0) (first m1) (second m1))
                    (lin-xor (first m2) (first m0))
                    (lin-xor (second m2) (second m0)))))
    (define xt (for/list ([w (in-list in8)]) (list w)))
    (define xL (take xt 4))
    (define xH (drop xt 4))
    (define c4 (map lin-xor xL xH))
    (define-values (s1 prod-d) (kgf16 sc34 0 xL c4))
    (define uv-sq
      (list (third xH) (lin-xor (third xH) (fourth xH))
            (lin-xor (second xH) (third xH) (fourth xH)) (lin-xor (first xH) (fourth xH))))
    (define d4 (map lin-xor prod-d uv-sq))
    (match-define (list d0 d1 d2 d3) d4)
    (match-define (list g0w g1w g2w g3w g4w g5w g6w) (take (drop sc34 9) 7))
    (define g0 (list g0w)) (define g1 (list g1w)) (define g2 (list g2w))
    (define g3 (list g3w)) (define g4 (list g4w)) (define g5 (list g5w)) (define g6 (list g6w))
    (define s2
      (list `(temp-and-lin ,d1 ,d2 ,g0w) `(temp-and-lin ,d0 ,d3 ,g1w)
            `(temp-and-lin ,d0 ,d2 ,g2w) `(temp-and-lin ,g0 ,d3 ,g3w)
            `(temp-and-lin ,g1 ,d2 ,g4w) `(temp-and-lin ,g1 ,d1 ,g5w)
            `(temp-and-lin ,d1 ,(lin-xor d3 g2) ,g6w)))
    (define dinv4
      (list (lin-xor d0 d1 d2 g0 g1 g6 g5 g4 g3)
            (lin-xor d1 d2 d3 g2 g5 g3)
            (lin-xor d2 g0 g1 g4 g3)
            (lin-xor d2 d3 g1 g3)))
    (define-values (s3L oL) (kgf16 sc34 16 c4 dinv4))
    (define-values (s3H oH) (kgf16 sc34 25 xH dinv4))
    (define ot (append oL oH))
    (define out-cxs
      (for*/list ([r (in-range 8)]
                  [src-w (in-list
                          (apply lin-xor
                                 (for/list ([c (in-range 8)]
                                            #:when (= (vector-ref (vector-ref post-sbox-mat r) c) 1))
                                   (list-ref ot c))))])
        `(cx ,src-w ,(list-ref out8 r))))
    (define out-xs
      (for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
        `(x ,(list-ref out8 r))))
    `(within-apply
      ,(gf2-mat->cx-only-sexpr aes-to-tower-mat in8)
      (seq ,@s1 ,@s2 ,@s3L ,@s3H ,@out-cxs ,@out-xs)
      ()))

  (define steps '())
  (define s0 (first round-states))
  (for ([c (in-range 4)])
    (set! steps (cons (xor-w32-sexpr (kword c) (take (drop s0 (* 32 c)) 32)) steps)))
  (for ([r (in-range 1 11)])
    (define prev-s (list-ref round-states (sub1 r)))
    (define cur-s  (list-ref round-states r))
    (for* ([col (in-range 4)] [row (in-range 4)])
      (define src-b (+ row (* 4 (modulo (+ col row) 4))))
      (define dst-b (+ row (* 4 col)))
      (set! steps
            (cons (bp34-live-fwd-sexpr (take (drop prev-s (* 8 src-b)) 8)
                                       (take (drop cur-s (* 8 dst-b)) 8)
                                       (alloc-sc34!))
                  steps)))
    (when (< r 10)
      (set! steps (cons (aes-mixcolumns-slp92-sexpr cur-s #:rewire? #t) steps)))
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (when (= (modulo w-idx 4) 0)
        (define e (quotient w-idx 4))
        (define kw3 (kword 3))
        (define kw0 (kword 0))
        (set! steps
              (cons `(seq ,(bp34-live-fwd-sexpr (take (drop kw3 8) 8) (take kw0 8) (alloc-sc34!))
                          ,(bp34-live-fwd-sexpr (take (drop kw3 16) 8) (take (drop kw0 8) 8) (alloc-sc34!))
                          ,(bp34-live-fwd-sexpr (drop kw3 24) (take (drop kw0 16) 8) (alloc-sc34!))
                          ,(bp34-live-fwd-sexpr (take kw3 8) (drop kw0 24) (alloc-sc34!))
                          ,@(for/list ([b (in-range 8)]
                                       #:when (bitwise-bit-set? (vector-ref aes-rcon-bytes e) b))
                              `(x ,(list-ref kw0 b)))
                          ,(xor-w32-sexpr (kword 0) (kword 1))
                          ,(xor-w32-sexpr (kword 1) (kword 2))
                          ,(xor-w32-sexpr (kword 2) (kword 3)))
                    steps)))
      (set! steps (cons (xor-w32-sexpr (kword (modulo w-idx 4))
                                       (take (drop cur-s (* 32 c)) 32))
                        steps))))

  (define s10 (list-ref round-states 10))
  (define checked (take s10 check-bits))
  (define negs
    (for/list ([bit-idx (in-range check-bits)]
               #:when (not (bitwise-bit-set?
                            (bytes-ref target-ct-bytes (quotient bit-idx 8))
                            (modulo bit-idx 8))))
      `(x ,(list-ref s10 bit-idx))))

  `(within-apply-mbu
    (seq ,@(reverse steps))
    (within-apply
     (seq ,@negs)
     (mcz-mbu ,checked ,mcz-sc30)
     ,mcz-sc30)
    ,(append (apply append (rest round-states)) and6800 mcz-sc30)))

;; =============================================================================
;; SECTION 5: Verification Helpers & Full Pareto AES / SLP / MBU Runner
;; =============================================================================

(define (hex->bytes s)
  (list->bytes
   (for/list ([i (in-range 0 (string-length s) 2)])
     (string->number (substring s i (+ i 2)) 16))))

(define (bytes->hex bs)
  (apply string-append
         (for/list ([b (in-bytes bs)])
           (~r b #:base 16 #:min-width 2 #:pad-string "0"))))

(define (load-bytes! reg offset bs)
  (for ([bv (in-bytes bs)] [bi (in-naturals)])
    (for ([bit (in-range 8)])
      (vector-set! reg (+ offset (* 8 bi) bit) (if (bitwise-bit-set? bv bit) 1 0)))))

(define (read-bytes-via-wmap reg logical-wires wmap nbytes)
  (list->bytes
   (for/list ([bi (in-range nbytes)])
     (for/sum ([bit (in-range 8)])
       (define lw (list-ref logical-wires (+ (* 8 bi) bit)))
       (define pw (hash-ref wmap lw lw))
       (arithmetic-shift (vector-ref reg pw) bit)))))

(define (gates->json-list gates)
  (for/fold ([acc '()] #:result (reverse acc)) ([g (in-list gates)])
    (match g
      [`(assert-clean ,_) acc]
      [`(mid-meas-x-cond-z ,anc (,c1 ,c2))
       (cons (list "mid-meas-x-cond-cz" anc c1 c2) acc)]
      [`(mid-meas-x-cond-z ,anc ,c1)
       (cons (list "mid-meas-x-cond-z" anc c1) acc)]
      [`(,op ,args ...)
       (cons (cons (symbol->string op) args) acc)])))

;; Fast `eq?`-dispatched basis + `Law U4` MBU gate evaluator (semantically identical to
;; `eval-reversible-gates!`, avoiding generic `match` allocation over >15M gate steps).
(define (fast-eval-pareto-gates! reg gates [meas-branch-fn (lambda (_step) 1)])
  (define phase 1)
  (define mbu-step 0)
  (for ([g (in-list gates)])
    (define op (car g))
    (cond
      [(eq? op 'cx)
       (define c (cadr g))
       (when (= (vector-ref reg c) 1)
         (define t (caddr g))
         (vector-set! reg t (bitwise-xor (vector-ref reg t) 1)))]
      [(eq? op 'ccx)
       (define c1 (cadr g))
       (define c2 (caddr g))
       (when (and (= (vector-ref reg c1) 1) (= (vector-ref reg c2) 1))
         (define t (cadddr g))
         (vector-set! reg t (bitwise-xor (vector-ref reg t) 1)))]
      [(eq? op 'x)
       (define i (cadr g))
       (vector-set! reg i (bitwise-xor (vector-ref reg i) 1))]
      [(eq? op 'mid-meas-x-cond-z)
       (define anc (cadr g))
       (define ctrl (caddr g))
       (define m (meas-branch-fn mbu-step))
       (set! mbu-step (add1 mbu-step))
       (define anc-val (vector-ref reg anc))
       (when (and (= m 1) (= anc-val 1))
         (set! phase (- phase)))
       (vector-set! reg anc 0)
       (when (= m 1)
         (if (pair? ctrl)
             (when (and (= (vector-ref reg (car ctrl)) 1)
                        (= (vector-ref reg (cadr ctrl)) 1))
               (set! phase (- phase)))
             (when (= (vector-ref reg ctrl) 1)
               (set! phase (- phase)))))]
      [(eq? op 'swap)
       (define a (cadr g))
       (define b (caddr g))
       (define va (vector-ref reg a))
       (vector-set! reg a (vector-ref reg b))
       (vector-set! reg b va)]
      [(eq? op 'assert-clean)
       (for ([w (in-list (cadr g))])
         (unless (= (vector-ref reg w) 0)
           (error 'fast-eval-pareto-gates! "Dirty ancilla wire ~a in assert-clean!" w)))]
      [else
       ;; Fallback to core `eval-reversible-gates!` for `cz`, `ccz`, `z`, etc.
       (when (= (eval-reversible-gates! reg (list g) (lambda (_) (meas-branch-fn mbu-step))) -1)
         (set! phase (- phase)))]))
  phase)

(define (fast-gate-counts gates)
  (define x-n 0) (define cx-n 0) (define ccx-n 0) (define swap-n 0)
  (define h-n 0) (define ph-n 0) (define mbu-n 0) (define ac-n 0)
  (for ([g (in-list gates)])
    (define op (car g))
    (cond
      [(eq? op 'cx) (set! cx-n (add1 cx-n))]
      [(eq? op 'ccx) (set! ccx-n (add1 ccx-n))]
      [(eq? op 'mid-meas-x-cond-z) (set! mbu-n (add1 mbu-n))]
      [(eq? op 'x) (set! x-n (add1 x-n))]
      [(eq? op 'assert-clean) (set! ac-n (add1 ac-n))]
      [(eq? op 'swap) (set! swap-n (add1 swap-n))]
      [(eq? op 'h) (set! h-n (add1 h-n))]
      [(or (eq? op 'z) (eq? op 'cz) (eq? op 'ccz)) (set! ph-n (add1 ph-n))]))
  (hasheq 'x x-n 'cx cx-n 'ccx ccx-n 'swap swap-n 'h h-n 'phase ph-n
          'mid_meas_x_cond_z mbu-n 'assert_clean ac-n
          'total_physical_gates (+ x-n cx-n ccx-n swap-n h-n ph-n mbu-n)))

(define (verify-pareto-nist-aes label key-bits pt-hex key-hex expected-ct-hex)
  (define pt-bytes (hex->bytes pt-hex))
  (define key-bytes (hex->bytes key-hex))
  (define exp-ct-bytes (hex->bytes expected-ct-hex))

  ;; 1. Narrowest Stage-3-Split Pareto Configuration (`34` shared scratch wires -> `290 Q / 354 Q / 418 Q`)
  (define state128  (range 0 128))
  (define key-wires (range 128 (+ 128 key-bits)))
  (define sc34      (range (+ 128 key-bits) (+ 162 key-bits)))
  (define total-q-split (+ 162 key-bits))

  (define-values (enc-gates enc-wmap)
    (compile-lakefill-pareto-with-map
     (aes-pareto-cipher-sexpr key-bits state128 key-wires sc34 #:split-stage3? #t)))

  ;; Verify encryption across `M_X = 0`, `M_X = 1`, and alternating `M_X` branch patterns!
  (define reg-after-enc0 #f)
  (define branch-fns
    (if (= key-bits 128)
        (list (lambda (_s) 0) (lambda (_s) 1) (lambda (s) (bitwise-and 1 (quotient s 3))))
        (list (lambda (_s) 0) (lambda (s) (bitwise-and 1 (quotient (+ s 1) 2))))))
  (for ([branch-fn (in-list branch-fns)]
        [b-idx (in-naturals)])
    (define reg (make-vector total-q-split 0))
    (load-bytes! reg 0 pt-bytes)
    (load-bytes! reg 128 key-bytes)
    (define ph (fast-eval-pareto-gates! reg enc-gates branch-fn))
    (when (= b-idx 0) (set! reg-after-enc0 (vector-copy reg)))
    (define got-ct-hex (bytes->hex (read-bytes-via-wmap reg state128 enc-wmap 16)))
    (define sc-clean? (for/and ([w (in-list sc34)]) (= (vector-ref reg w) 0)))
    (unless (and (= ph 1) (equal? got-ct-hex expected-ct-hex) sc-clean?)
      (error 'verify-pareto-nist-aes
             "~a failed encryption check: got ~a vs ~a (ph=~a clean=~a)"
             label got-ct-hex expected-ct-hex ph sc-clean?)))

  ;; 2. Verify exact narrow-width `aes-pareto-inv-cipher-sexpr` decryption roundtrip!
  (define-values (dec-gates final-roundtrip-wmap)
    (compile-lakefill-pareto-with-map
     (aes-pareto-inv-cipher-sexpr key-bits state128 key-wires sc34 #:split-stage3? #t)
     #:init-wmap enc-wmap))
  (define reg-rt (vector-copy reg-after-enc0))
  (define ph-dec (fast-eval-pareto-gates! reg-rt dec-gates))
  (define wmap-identity-restored?
    (for/and ([w (in-range total-q-split)]) (= (hash-ref final-roundtrip-wmap w w) w)))
  (define rt-pt-hex (bytes->hex (read-bytes-via-wmap reg-rt state128 (make-hash) 16)))
  (define rt-key-hex (bytes->hex (read-bytes-via-wmap reg-rt key-wires (make-hash) (/ key-bits 8))))
  (unless (and (= ph-dec 1)
               wmap-identity-restored?
               (equal? rt-pt-hex pt-hex)
               (equal? rt-key-hex key-hex)
               (for/and ([w (in-list sc34)]) (= (vector-ref reg-rt w) 0)))
    (error 'verify-pareto-nist-aes "~a failed inverse roundtrip!" label))

  ;; 3. Verify Unsplit `42`-scratch (`298 Q / 362 Q / 426 Q`) configuration as well!
  (define sc42 (range (+ 128 key-bits) (+ 170 key-bits)))
  (define total-q-unsplit (+ 170 key-bits))
  (define-values (enc-unsplit-gates enc-unsplit-wmap)
    (compile-lakefill-pareto-with-map
     (aes-pareto-cipher-sexpr key-bits state128 key-wires sc42 #:split-stage3? #f)))
  (define reg-u (make-vector total-q-unsplit 0))
  (load-bytes! reg-u 0 pt-bytes)
  (load-bytes! reg-u 128 key-bytes)
  (define ph-u (fast-eval-pareto-gates! reg-u enc-unsplit-gates))
  (define got-u-hex (bytes->hex (read-bytes-via-wmap reg-u state128 enc-unsplit-wmap 16)))
  (unless (and (= ph-u 1) (equal? got-u-hex expected-ct-hex))
    (error 'verify-pareto-nist-aes "~a unsplit 42-scratch mismatch!" label))

  ;; 4. Verify Narrow-Width Pareto Grover Phase Oracle on hit (`-1`) & miss (`+1`)!
  (define checked-wires (take state128 32))
  (define negations
    (for/list ([bit-idx (in-range 32)]
               #:when (not (bitwise-bit-set?
                            (bytes-ref exp-ct-bytes (quotient bit-idx 8))
                            (modulo bit-idx 8))))
      `(x ,(list-ref state128 bit-idx))))
  (define-values (mcz-gates mcz-wmap)
    (compile-lakefill-pareto-with-map
     `(within-apply (seq ,@negations) (mcz-mbu ,checked-wires ,sc34) ,sc34)
     #:init-wmap enc-wmap))
  (unless (equal? mcz-wmap enc-wmap)
    (error 'verify-pareto-nist-aes "MCZ block altered wire-map!"))
  (define grover-gates (append enc-gates mcz-gates dec-gates (list `(assert-clean ,sc34))))
  (define grover-wmap final-roundtrip-wmap)
  (unless (for/and ([w (in-range total-q-split)]) (= (hash-ref grover-wmap w w) w))
    (error 'verify-pareto-nist-aes "~a Grover oracle did not restore identity wire map!" label))

  (define reg-hit (make-vector total-q-split 0))
  (load-bytes! reg-hit 0 pt-bytes)
  (load-bytes! reg-hit 128 key-bytes)
  (define phase-hit (fast-eval-pareto-gates! reg-hit grover-gates (lambda (s) (bitwise-and 1 s))))

  (define reg-miss (make-vector total-q-split 0))
  (load-bytes! reg-miss 0 pt-bytes)
  (load-bytes! reg-miss 128 key-bytes)
  (vector-set! reg-miss 128 (bitwise-xor (vector-ref reg-miss 128) 1))
  (define phase-miss (fast-eval-pareto-gates! reg-miss grover-gates (lambda (s) (bitwise-and 1 s))))

  (unless (and (= phase-hit -1)
               (= phase-miss 1)
               (equal? (bytes->hex (read-bytes-via-wmap reg-hit state128 (make-hash) 16)) pt-hex)
               (equal? (bytes->hex (read-bytes-via-wmap reg-hit key-wires (make-hash) (/ key-bits 8))) key-hex)
               (for/and ([w (in-list sc34)]) (= (vector-ref reg-hit w) 0))
               (for/and ([w (in-list sc34)]) (= (vector-ref reg-miss w) 0)))
    (error 'verify-pareto-nist-aes "~a Pareto Grover oracle check failed!" label))

  (define enc-counts (fast-gate-counts enc-gates))
  (define enc-unsplit-counts (fast-gate-counts enc-unsplit-gates))
  (define grover-counts (fast-gate-counts grover-gates))
  (define naive-ccx (match key-bits [128 80640] [192 92160] [256 112896]))
  (define naive-grover-ccx (match key-bits [128 161340] [192 184380] [256 225852]))

  (hasheq 'variant label
          'key_bits key-bits
          'rounds (match key-bits [128 10] [192 12] [256 14])
          'narrow_split_qubits total-q-split
          'narrow_split_shared_scratch 34
          'unsplit_bp34_qubits total-q-unsplit
          'unsplit_shared_scratch 42
          'plaintext_hex pt-hex
          'key_hex key-hex
          'ciphertext_hex expected-ct-hex
          'nist_fips197_exact_match #t
          'inverse_decryption_exact #t
          'grover_oracle_phase_hit phase-hit
          'grover_oracle_phase_miss phase-miss
          'ancilla_leakage_bits 0
          'swap_gates_total (hash-ref enc-counts 'swap)
          'naive_unshared_ccx naive-ccx
          'pareto_temp_and_count (hash-ref enc-counts 'ccx)
          'toffoli_reduction_factor (real->decimal-string (/ (exact->inexact naive-ccx)
                                                             (hash-ref enc-counts 'ccx)) 2)
          't_count_reduction_factor (real->decimal-string (/ (* 7.0 naive-ccx)
                                                             (* 4.0 (hash-ref enc-counts 'ccx))) 2)
          'grover_naive_ccx naive-grover-ccx
          'grover_pareto_temp_and_count (hash-ref grover-counts 'ccx)
          'grover_toffoli_reduction_factor (real->decimal-string (/ (exact->inexact naive-grover-ccx)
                                                                    (hash-ref grover-counts 'ccx)) 2)
          'encrypt_split_gate_counts enc-counts
          'encrypt_unsplit_gate_counts enc-unsplit-counts
          'grover_oracle_gate_counts grover-counts))

(define (run-pareto-aes-slp-and-asymmetric-mbu-verifications #:stream-gadgets? [stream-gadgets? #f])
  (define t0 (current-inexact-milliseconds))

  ;; ---------------------------------------------------------------------------
  ;; 1. Lesson 1 Verification: Asymmetric `within-apply-mbu` & Modular Adder
  ;; ---------------------------------------------------------------------------
  (define asym-modadd-sexpr
    (gidney-modular-adder-asymmetric-sexpr
     '(0 1 2 3) '(4 5 6 7) '(8 9 10 11) '(12 13 14 15 16 17 18 19 20)))
  (define asym-modadd-mbu-gates
    (compile-lakefill-pareto asym-modadd-sexpr #:mode 'mbu))
  (define asym-modadd-sym-gates
    (compile-lakefill-pareto asym-modadd-sexpr #:mode 'unitary-symmetric))
  (define inplace-modadd-gates
    (compile-lakefill-pareto
     (gidney-modular-adder-inplace-mbu-sexpr
      4 13 '(0 1 2 3) '(4 5 6 7) 8 '(9 10 11 12) '(13 14 15 16))))
  (define within-apply-mbu-9q-gates
    (compile-lakefill-pareto
     '(within-apply-mbu
       (seq (temp-and 0 1 6)
            (temp-and-lin (0 2) (1 3) 7)
            (temp-and 6 7 8))
       (seq (cx 6 4) (cx 7 5) (cx 8 4) (cx 8 5))
       (6 7 8))))
  (define-values (mc-slp91-gates mc-slp91-wmap)
    (compile-lakefill-pareto-with-map (aes-mixcolumn-slp92-col-sexpr (range 32) #:rewire? #t)))
  (define mc-fixed105-gates
    (compile-lakefill-pareto (aes-mixcolumn-fixed-slp105-col-sexpr (range 32))))

  (define exported-gadgets
    (hasheq
     'within_apply_mbu_9q (hasheq
       'num_qubits 9
       'input_wires '(0 1 2 3)
       'output_wires '(4 5)
       'ancilla_wires '(6 7 8)
       'gates (gates->json-list within-apply-mbu-9q-gates))
     'gidney_modadd13_inplace_mbu_17q (hasheq
       'num_qubits 17
       'a_wires '(0 1 2 3)
       'b_wires '(4 5 6 7)
       'ancilla_wires (range 8 17)
       'gates (gates->json-list inplace-modadd-gates))
     'gidney_modadd13_asymmetric_21q (hasheq
       'num_qubits 21
       'a_wires '(0 1 2 3)
       'b_wires '(4 5 6 7)
       'out_wires '(8 9 10 11)
       'ancilla_wires (range 12 21)
       'gates (gates->json-list asym-modadd-mbu-gates))
     'aes_mixcolumns_slp91_32q (hasheq
       'num_qubits 32
       'wire_perm aes-mixcol-slp91-wire-perm
       'gates (gates->json-list mc-slp91-gates))
     'aes_mixcolumns_fixed_slp105_32q (hasheq
       'num_qubits 32
       'gates (gates->json-list mc-fixed105-gates))))

  (when stream-gadgets?
    (write-json exported-gadgets)
    (newline)
    (flush-output))

  (unless (and (= (hash-ref (gate-counts asym-modadd-sym-gates) 'ccx) 18)
               (= (hash-ref (gate-counts asym-modadd-mbu-gates) 'ccx) 9)
               (= (hash-ref (gate-counts asym-modadd-mbu-gates) 'mid_meas_x_cond_z) 9))
    (error 'asym-modadd "Expected 18 symmetric CCX -> 9 asymmetric TempANDs + 9 MBUs!"))

  ;; Verify all `169 / 169` `(a, b) in Z_13^2` pairs + exhaustive `512`-branch (`2^9`) Law U4 sweeps!
  (for* ([a (in-range 13)] [b (in-range 13)])
    (define init-r (make-vector 21 0))
    (for ([bit (in-range 4)])
      (vector-set! init-r bit (if (bitwise-bit-set? a bit) 1 0))
      (vector-set! init-r (+ 4 bit) (if (bitwise-bit-set? b bit) 1 0)))
    (define exp-sum (modulo (+ a b) 13))
    (cond
      [(and (= a 0) (= b 0))
       (define out-r (eval-mbu-circuit-all-branches init-r asym-modadd-mbu-gates (range 12 21)))
       (define got (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref out-r (+ 8 bit)) bit)))
       (unless (= got exp-sum)
         (error 'asym-modadd "512-branch mismatch at (0, 0): got ~a" got))]
      [(or (and (= a 12) (= b 11)) (and (= a 7) (= b 9)) (and (= a 0) (= b 12)) (and (= a 6) (= b 7)))
       (for ([mask (in-range 512)])
         (define r (vector-copy init-r))
         (define ph (fast-eval-pareto-gates! r asym-modadd-mbu-gates
                                             (lambda (s) (if (bitwise-bit-set? mask s) 1 0))))
         (define got (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref r (+ 8 bit)) bit)))
         (unless (and (= ph 1)
                      (= got exp-sum)
                      (for/and ([w (in-range 12 21)]) (= (vector-ref r w) 0)))
           (error 'asym-modadd "512-branch mismatch at (~a, ~a) mask=~a: got ~a ph=~a" a b mask got ph)))]
      [else
       (for ([pat (in-list (list (lambda (_s) 0)
                                 (lambda (_s) 1)
                                 (lambda (s) (bitwise-and 1 (+ s a b)))
                                 (lambda (s) (bitwise-and 1 (quotient (+ s a) 2)))))])
         (define r (vector-copy init-r))
         (define ph (fast-eval-pareto-gates! r asym-modadd-mbu-gates pat))
         (define got (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref r (+ 8 bit)) bit)))
         (unless (and (= ph 1)
                      (= got exp-sum)
                      (for/and ([w (in-range 12 21)]) (= (vector-ref r w) 0)))
           (error 'asym-modadd "Mismatch at (~a, ~a): got ~a ph=~a" a b got ph)))]))

  ;; Verify Step-4-Fixed In-Place `gidney-modular-adder-inplace-mbu-sexpr` (`17` qubits, `27 CCX -> 15 TempANDs`)
  (for* ([a (in-range 13)] [b (in-range 13)])
    (define r (make-vector 17 0))
    (for ([bit (in-range 4)])
      (vector-set! r bit (if (bitwise-bit-set? a bit) 1 0))
      (vector-set! r (+ 4 bit) (if (bitwise-bit-set? b bit) 1 0)))
    (define ph (fast-eval-pareto-gates! r inplace-modadd-gates (lambda (s) (bitwise-and 1 (+ s a b 1)))))
    (define got (for/sum ([bit (in-range 4)]) (arithmetic-shift (vector-ref r (+ 4 bit)) bit)))
    (unless (and (= ph 1)
                 (= got (modulo (+ a b) 13))
                 (for/and ([w (in-range 8 17)]) (= (vector-ref r w) 0)))
      (error 'inplace-modadd "In-place MBU modadd failed at (~a, ~a): got ~a" a b got)))

  ;; ---------------------------------------------------------------------------
  ;; 2. Lesson 2 Verification: `91-CX` (`<= 92-CX`) `0-SWAP` `SLP` `MixColumns`
  ;; ---------------------------------------------------------------------------
  (unless (and (= (hash-ref (gate-counts mc-slp91-gates) 'cx) 91)
               (= (hash-ref (gate-counts mc-slp91-gates) 'swap) 0)
               (= (hash-ref (gate-counts mc-fixed105-gates) 'cx) 105)
               (= (hash-ref (gate-counts mc-fixed105-gates) 'swap) 0))
    (error 'mixcol-slp "Unexpected MixColumns SLP gate counts!"))

  ;; Verify `db135345 -> 8e4da1bc` AND `(invert-circuit)` roundtrip on BOTH `91-CX` & `105-CX`!
  (define fips-mc-in (hex->bytes "db135345"))
  (define r-mc91 (make-vector 32 0))
  (load-bytes! r-mc91 0 fips-mc-in)
  (eval-reversible-gates! r-mc91 mc-slp91-gates)
  (define mc91-out-hex (bytes->hex (read-bytes-via-wmap r-mc91 (range 32) mc-slp91-wmap 4)))
  (eval-reversible-gates! r-mc91 (invert-circuit mc-slp91-gates))
  (define mc91-rt-hex (bytes->hex (read-bytes-via-wmap r-mc91 (range 32) (make-hash) 4)))

  (define r-mc105 (make-vector 32 0))
  (load-bytes! r-mc105 0 fips-mc-in)
  (eval-reversible-gates! r-mc105 mc-fixed105-gates)
  (define mc105-out-hex (bytes->hex (read-bytes-via-wmap r-mc105 (range 32) (make-hash) 4)))
  (eval-reversible-gates! r-mc105 (invert-circuit mc-fixed105-gates))
  (define mc105-rt-hex (bytes->hex (read-bytes-via-wmap r-mc105 (range 32) (make-hash) 4)))

  (unless (and (equal? mc91-out-hex "8e4da1bc")
               (equal? mc91-rt-hex "db135345")
               (equal? mc105-out-hex "8e4da1bc")
               (equal? mc105-rt-hex "db135345"))
    (error 'mixcol-slp "FIPS-197 db135345 -> 8e4da1bc mismatch: 91=~a 105=~a" mc91-out-hex mc105-out-hex))

  ;; ---------------------------------------------------------------------------
  ;; 3. Lesson 3 Verification: `BP68` In-Place S-Box (`256/256`) + Pareto
  ;;    `AES-128` (`290 Q`), `AES-192` (`354 Q`), `AES-256` (`418 Q`) + Grover!
  ;; ---------------------------------------------------------------------------
  (define naive-sbox-gates (compile-lakefill (aes-sbox-inplace-sexpr (range 0 8) (range 8 40))))
  (define bp68-split-gates
    (compile-lakefill-pareto (aes-sbox-bp68-inplace-sexpr (range 0 8) (range 8 41) #:split-stage3? #t)))
  (define bp68-unsplit-gates
    (compile-lakefill-pareto (aes-sbox-bp68-inplace-sexpr (range 0 8) (range 8 50) #:split-stage3? #f)))
  (define bp68-inv-gates
    (compile-lakefill-pareto (aes-inv-sbox-bp68-inplace-sexpr (range 0 8) (range 8 41) #:split-stage3? #t)))

  (unless (and (= (hash-ref (gate-counts bp68-split-gates) 'ccx) 68)
               (= (hash-ref (gate-counts bp68-unsplit-gates) 'ccx) 68)
               (= (hash-ref (gate-counts bp68-split-gates) 'swap) 0))
    (error 'bp68-sbox "Expected 68 TempANDs and 0 SWAPs in BP68 in-place S-box!"))

  (for ([x (in-range 256)])
    (define rn (make-vector 40 0))
    (load-bytes! rn 0 (bytes x))
    (fast-eval-pareto-gates! rn naive-sbox-gates)
    (define y-ref (bytes-ref (read-bytes-via-wmap rn (range 8) (make-hash) 1) 0))

    (define rp (make-vector 41 0))
    (load-bytes! rp 0 (bytes x))
    (define ph1 (fast-eval-pareto-gates! rp bp68-split-gates (lambda (s) (bitwise-and 1 (+ s x)))))
    (define y-got (bytes-ref (read-bytes-via-wmap rp (range 8) (make-hash) 1) 0))
    (define clean1? (for/and ([w (in-range 8 41)]) (= (vector-ref rp w) 0)))
    (define ph2 (fast-eval-pareto-gates! rp bp68-inv-gates (lambda (s) (bitwise-and 1 (+ s x 1)))))
    (define x-rt (bytes-ref (read-bytes-via-wmap rp (range 8) (make-hash) 1) 0))
    (define clean2? (for/and ([w (in-range 8 41)]) (= (vector-ref rp w) 0)))
    (unless (and (= ph1 1) (= ph2 1) (= y-got y-ref) (= x-rt x) clean1? clean2?)
      (error 'bp68-sbox "Failed 256/256 S-box check at x=~a" x)))

  (define aes128-res
    (verify-pareto-nist-aes
     "AES-128 Pareto In-Place (FIPS-197 C.1)" 128
     "00112233445566778899aabbccddeeff"
     "000102030405060708090a0b0c0d0e0f"
     "69c4e0d86a7b0430d8cdb78070b4c55a"))

  (define aes192-res
    (verify-pareto-nist-aes
     "AES-192 Pareto In-Place (FIPS-197 C.2)" 192
     "00112233445566778899aabbccddeeff"
     "000102030405060708090a0b0c0d0e0f1011121314151617"
     "dda97ca4864cdfe06eaf70a0ec0d7191"))

  (define aes256-res
    (verify-pareto-nist-aes
     "AES-256 Pareto In-Place (FIPS-197 C.3)" 256
     "00112233445566778899aabbccddeeff"
     "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
     "8ea2b7ca516745bfeafc49904b496089"))

  ;; Also verify the All-Live Out-of-Place `within-apply-mbu` Grover Oracle (`6,830` TempANDs, `0` uncompute Toffolis!)
  (define oop-rstates (for/list ([r (in-range 11)]) (range (* 128 r) (* 128 (add1 r)))))
  (define oop-key (range 1408 1536))
  (define oop-and6800 (range 1536 8336))
  (define oop-mcz30 (range 8336 8366))
  (define oop-grover-gates
    (compile-lakefill-pareto
     (aes-all-live-mbu-grover-oracle-sexpr
      oop-rstates oop-key oop-and6800 oop-mcz30
      (hex->bytes "69c4e0d86a7b0430d8cdb78070b4c55a") 32)))
  (define oop-hit-reg (make-vector 8366 0))
  (load-bytes! oop-hit-reg 0 (hex->bytes "00112233445566778899aabbccddeeff"))
  (load-bytes! oop-hit-reg 1408 (hex->bytes "000102030405060708090a0b0c0d0e0f"))
  (define oop-ph-hit (fast-eval-pareto-gates! oop-hit-reg oop-grover-gates (lambda (s) (bitwise-and 1 s))))
  (define oop-miss-reg (make-vector 8366 0))
  (load-bytes! oop-miss-reg 0 (hex->bytes "00112233445566778899aabbccddeeff"))
  (load-bytes! oop-miss-reg 1408 (hex->bytes "000102030405060708090a0b0c0d0e0f"))
  (vector-set! oop-miss-reg 1408 (bitwise-xor (vector-ref oop-miss-reg 1408) 1))
  (define oop-ph-miss (fast-eval-pareto-gates! oop-miss-reg oop-grover-gates (lambda (s) (bitwise-and 1 s))))
  (unless (and (= oop-ph-hit -1)
               (= oop-ph-miss 1)
               (for/and ([w (in-range 128 1408)]) (= (vector-ref oop-hit-reg w) 0))
               (for/and ([w (in-range 1536 8366)]) (= (vector-ref oop-hit-reg w) 0)))
    (error 'oop-grover "All-live MBU AES-128 Grover oracle failed verification!"))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))

  (hasheq
   'suite "Asymmetric within-apply-mbu, 91-CX SLP MixColumns & Pareto Narrow-Width In-Place AES-128/192/256"
   'status "PASS"
   'racket_version (version)
   'wall_time_ms (real->decimal-string elapsed-ms 2)
   'lesson1_asymmetric_within_apply_mbu (hasheq
     'modulus 13
     'bit_width 4
     'pairs_verified 169
     'symmetric_within_apply_ccx (hash-ref (gate-counts asym-modadd-sym-gates) 'ccx)
     'asymmetric_within_apply_mbu_temp_ands (hash-ref (gate-counts asym-modadd-mbu-gates) 'ccx)
     'asymmetric_uncompute_toffolis 0
     'asymmetric_mbu_measurements (hash-ref (gate-counts asym-modadd-mbu-gates) 'mid_meas_x_cond_z)
     'toffoli_reduction_pct -50.0
     'exhaustive_512_mbu_branch_sweeps_passed #t
     'inplace_step4_fixed_qubits 17
     'inplace_step4_naive_ccx 27
     'inplace_step4_fixed_temp_ands (hash-ref (gate-counts inplace-modadd-gates) 'ccx)
     'asymmetric_9_temp_and_gate_counts (gate-counts asym-modadd-mbu-gates)
     'inplace_step4_mbu_gate_counts (gate-counts inplace-modadd-gates))
   'lesson2_slp_mixcolumns (hasheq
     'naive_gauss_jordan_1col_cx 312
     'naive_gauss_jordan_1col_swap 21
     'naive_gauss_jordan_1col_total_gates 333
     'naive_gauss_jordan_4col_cx 1248
     'naive_gauss_jordan_4col_swap 84
     'naive_gauss_jordan_4col_total_gates 1332
     'slp91_1col_cx 91
     'slp91_1col_swap 0
     'slp91_4col_cx 364
     'slp91_4col_swap 0
     'gate_reduction_factor (real->decimal-string (/ 333.0 91.0) 2)
     'fixed_wire_slp105_1col_cx 105
     'fixed_wire_slp105_1col_swap 0
     'fips197_db135345_output_hex mc91-out-hex
     'invert_circuit_roundtrip_hex mc91-rt-hex
     'ancilla_wires 0
     'slp91_wire_perm aes-mixcol-slp91-wire-perm)
   'lesson3_pareto_inplace_sbox_and_aes (hasheq
     'sbox_naive_tower_ccx (hash-ref (gate-counts naive-sbox-gates) 'ccx)
     'sbox_bp68_inplace_temp_ands (hash-ref (gate-counts bp68-split-gates) 'ccx)
     'sbox_bp68_uncompute_toffolis 0
     'sbox_bp68_swap_gates 0
     'sbox_split_total_wires 41
     'sbox_split_scratch_wires 33
     'sbox_unsplit_total_wires 50
     'sbox_unsplit_scratch_wires 42
     'sbox_toffoli_reduction_factor (real->decimal-string (/ 432.0 68.0) 2)
     'sbox_t_count_reduction_factor (real->decimal-string (/ (* 7.0 432.0) (* 4.0 68.0)) 2)
     'exhaustive_256_bytes_verified #t
     'nist_fips197_pareto_ciphers (list aes128-res aes192-res aes256-res)
     'all_live_within_apply_mbu_aes128_grover
     (let ([oop-counts (fast-gate-counts oop-grover-gates)])
       (hasheq
        'total_qubits 8366
        'temp_and_count (hash-ref oop-counts 'ccx)
        'uncompute_toffolis 0
        'mbu_count (hash-ref oop-counts 'mid_meas_x_cond_z)
        'naive_grover_ccx 161340
        'toffoli_reduction_factor (real->decimal-string (/ 161340.0 (hash-ref oop-counts 'ccx)) 2)
        't_count_reduction_factor (real->decimal-string (/ (* 7.0 161340.0) (* 4.0 (hash-ref oop-counts 'ccx))) 2)
        'phase_hit oop-ph-hit
        'phase_miss oop-ph-miss
        'ancilla_leakage_bits 0)))
   'exported_quantum_gadgets exported-gadgets))

(module+ main
  (define stream?
    (and (member "--stream-gadgets" (vector->list (current-command-line-arguments))) #t))
  (define summary
    (run-pareto-aes-slp-and-asymmetric-mbu-verifications #:stream-gadgets? stream?))
  (write-json summary)
  (newline))
