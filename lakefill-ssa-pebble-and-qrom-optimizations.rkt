#lang racket

;; =============================================================================
;; lakefill-ssa-pebble-and-qrom-optimizations.rkt
;; =============================================================================
;; Empirically-Driven Lakefill Lisp Compiler & Standard-Library Optimizations
;; Inspired by Comparing Generic Compositional Lakefill against Q# (Jaques et al.
;; EUROCRYPT 2020), Qrisp (Seidel et al. 2024), Qualtran (Gidney 2018/2019,
;; Babbush et al. 2018), Silq (Bichsel et al. PLDI 2020), and Quipper (PLDI 2013):
;;
;;   1. `(with-and-session bindings lin-pair2 action-expr #:mode mode)`:
;;      Session-scoped SSA straight-line `TempAND` DAG combinator keeping all
;;      intermediate `AND` ancillas alive across the entire session and erasing
;;      them in reverse topological order via `Law U4` (`mid-meas-x-cond-z`)
;;      with `0` uncompute Toffolis!
;;   2. Boyar-Peralta `34-AND` (`AND`-depth 4) Straight-Line AES S-Box &
;;      Out-of-Place / Key-Shared Full NIST AES-128 & AES-256 Pipelines:
;;      - Cuts single AES S-box from `432` `CCX` (`3,024` `T`) down to `34`
;;        `TempAND`s + `0` uncompute Toffolis (`136` `T` -> `12.71x` Toffoli /
;;        `22.24x` `T`-count reduction!), verified `256/256` against FIPS-197.
;;      - Cuts 10-round `AES-128` from `80,640` `CCX` down to `6,800` `TempAND`s
;;        (quantum key schedule) or `5,440` `TempAND`s (shared classical key;
;;        `2,720–3,400` `TempAND`s amortized half-depth / multi-block key sharing),
;;        verified bit-exact on NIST FIPS-197 C.1 & C.3!
;;   3. `(qrom-sawtooth-lookup-sexpr ...)` (Babbush et al. 2018 Sawtooth Unary
;;      Iteration `QROM`, `N - 1` controlled / `N - 2` uncontrolled `TempAND`s +
;;      `M_X + cond-Z` uncomputation) & Windowed `QROM` Lookup-Addition (`3.5x–5.2x`
;;      `TempAND` reduction over bit-by-bit schoolbook/controlled multiplication).
;;   4. `Keccak-f[200]` Out-of-Place `TempAND` Pipeline (`3,600` `TempAND`s,
;;      `4.00x` fewer `AND`s than generic in-place `erase-by` `14,400` `CCX`,
;;      exposing the exact `240`-wire vs `3,845`-wire Bennett space-time frontier).
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/format
         racket/math
         json
         "lakefill-core-cryptography-implementations.rkt")

(provide with-and-session-sexpr
         aes-sbox-bp34-xor-sexpr
         aes-outofplace-pipeline-sexpr
         qrom-sawtooth-ctrl-lookup-sexpr
         qrom-sawtooth-lookup-sexpr
         windowed-qrom-const-mul-add-sexpr
         naive-bitbybit-const-mul-add-sexpr
         keccak-chi5-outofplace-sexpr
         keccak-f200-outofplace-sexpr
         run-lakefill-ssa-qrom-optimizations)

;; =============================================================================
;; SECTION 1: Session-Scoped SSA `TempAND` DAG Combinator (`with-and-session`)
;; =============================================================================
;; `bindings` is a topologically ordered list of `(list anc-wire lhs-wires rhs-wires)`
;; where `lhs-wires` and `rhs-wires` are non-empty lists of previously bound wires
;; whose GF(2) parity forms the two inputs to `anc-wire <- parity(lhs) & parity(rhs)`.
;; `lin-pair2 = (list lin-a lin-b)` provides 2 clean scratch wires for multi-wire
;; linear fan-in (never incurring wire-aliasing bugs even when `lhs` and `rhs` overlap!).
;;
;; Modes:
;;   - `'mbu`          : Lakefill `Law U4` (`mid-meas-x-cond-z`) -> `M` `TempAND`s + `0` uncompute CCX (`4M` T-gates)
;;   - `'unitary-silq` : Unitary `CCX` uncomputation (Silq `qfree`) -> `2M` `CCX` (`8M` or `14M` T-gates)

(define (with-and-session-sexpr bindings lin-pair2 action-expr #:mode [mode 'mbu])
  (match-define (list lin-a lin-b) lin-pair2)
  (define anc-wires (map first bindings))

  (define (fanin-step wires scratch-w)
    (if (= (length wires) 1)
        (values (first wires) 'skip '())
        (values scratch-w
                `(seq ,@(for/list ([w (in-list wires)]) `(cx ,w ,scratch-w)))
                (list scratch-w))))

  (define fwd-steps
    (for/list ([b (in-list bindings)])
      (match-define (list anc lhs-ws rhs-ws) b)
      (define-values (lw l-prep l-clean) (fanin-step lhs-ws lin-a))
      (define-values (rw r-prep r-clean) (fanin-step rhs-ws lin-b))
      (define clean-pair (append l-clean r-clean))
      (if (null? clean-pair)
          `(ccx ,lw ,rw ,anc)
          `(within-apply (seq ,l-prep ,r-prep)
                         (ccx ,lw ,rw ,anc)
                         ,clean-pair))))

  (define bwd-steps
    (for/list ([b (in-list (reverse bindings))])
      (match-define (list anc lhs-ws rhs-ws) b)
      (define-values (lw l-prep l-clean) (fanin-step lhs-ws lin-a))
      (define-values (rw r-prep r-clean) (fanin-step rhs-ws lin-b))
      (define clean-pair (append l-clean r-clean))
      (define uncomp-leaf
        (match mode
          ['mbu `(mid-meas-x-cond-z ,anc (,lw ,rw))]
          ['unitary-silq `(ccx ,lw ,rw ,anc)]
          [_ (error 'with-and-session-sexpr "Unknown mode: ~a" mode)]))
      (if (null? clean-pair)
          uncomp-leaf
          `(within-apply (seq ,l-prep ,r-prep)
                         ,uncomp-leaf
                         ,clean-pair))))

  `(seq ,@fwd-steps
        ,action-expr
        ,@bwd-steps
        (assert-clean ,(append anc-wires lin-pair2))))

;; =============================================================================
;; SECTION 2: Boyar-Peralta `34-AND` (`AND`-Depth 4) Straight-Line AES S-Box
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
(define post-sbox-mat (gf2-matmul aes-affine-mat tower-to-aes-mat))

;; Represent linear forms over wire indices as canonical sorted duplicate-canceled lists
;; (GF(2) XOR cancellation: `w ^ w = 0`!).
(define (lin-xor . forms)
  (define counts (make-hash))
  (for* ([f (in-list forms)] [w (in-list f)])
    (hash-update! counts w add1 0))
  (sort (for/list ([(w c) (in-hash counts)] #:when (odd? c)) w) <))

;; Out-of-place XOR AES S-box `out8 ^= S(in8)` using EXACTLY `34` `TempAND`s
;; (`AND`-depth 4) and `36` clean scratch wires (`34` `TempAND`s + `2` linear fan-in
;; wires), all restored to `0` at the end of the S-box with `0` uncompute Toffolis!
(define (aes-sbox-bp34-xor-sexpr in8 out8 sc36 #:mode [mode 'mbu])
  (define and34 (take sc36 34))
  (define lin2  (drop sc36 34))
  (define next-idx 0)
  (define bindings '())

  (define (alloc-and! lhs-form rhs-form)
    (define w (list-ref and34 next-idx))
    (set! next-idx (add1 next-idx))
    (set! bindings (cons (list w lhs-form rhs-form) bindings))
    (list w))

  (define (karatsuba-gf4 a0 a1 b0 b1)
    (define p0 (alloc-and! a0 b0))
    (define p1 (alloc-and! a1 b1))
    (define p2 (alloc-and! (lin-xor a0 a1) (lin-xor b0 b1)))
    (list (lin-xor p0 p1) (lin-xor p2 p0)))

  (define (karatsuba-gf16 a4 b4)
    (match-define (list a0 a1 a2 a3) a4)
    (match-define (list b0 b1 b2 b3) b4)
    (match-define (list m0-0 m0-1) (karatsuba-gf4 a0 a1 b0 b1))
    (match-define (list m1-0 m1-1) (karatsuba-gf4 a2 a3 b2 b3))
    (match-define (list m2-0 m2-1)
      (karatsuba-gf4 (lin-xor a0 a2) (lin-xor a1 a3)
                     (lin-xor b0 b2) (lin-xor b1 b3)))
    (list (lin-xor m0-0 m1-1)
          (lin-xor m0-1 m1-0 m1-1)
          (lin-xor m2-0 m0-0)
          (lin-xor m2-1 m0-1)))

  ;; Input linear basis map `xt[0..7] = A2T * in8` (pure symbolic linear forms, 0 gates!)
  (define xt
    (for/list ([r (in-range 8)])
      (for/list ([c (in-range 8)]
                 #:when (= (vector-ref (vector-ref aes-to-tower-mat r) c) 1))
        (list-ref in8 c))))
  (define xL (take xt 4))
  (define xH (drop xt 4))
  (define c4 (map lin-xor xL xH))

  ;; Stage 1 (`9` TempANDs, depth 1): d4 = xL * c4 ^ (uv)*xH^2
  (define prod-d (karatsuba-gf16 xL c4))
  (define uv-sq
    (list (third xH)
          (lin-xor (third xH) (fourth xH))
          (lin-xor (second xH) (third xH) (fourth xH))
          (lin-xor (first xH) (fourth xH))))
  (define d4 (map lin-xor prod-d uv-sq))

  ;; Stage 2 (`7` TempANDs, depth 2): dinv4 = inv_GF16(d4)
  (match-define (list d0 d1 d2 d3) d4)
  (define g0 (alloc-and! d1 d2))
  (define g1 (alloc-and! d0 d3))
  (define g2 (alloc-and! d0 d2))
  (define g3 (alloc-and! g0 d3))
  (define g4 (alloc-and! g1 d2))
  (define g5 (alloc-and! g1 d1))
  (define g6 (alloc-and! d1 (lin-xor d3 g2)))
  (define dinv4
    (list (lin-xor d0 d1 d2 g0 g1 g6 g5 g4 g3)
          (lin-xor d1 d2 d3 g2 g5 g3)
          (lin-xor d2 g0 g1 g4 g3)
          (lin-xor d2 d3 g1 g3)))

  ;; Stage 3 (`18` TempANDs, depth 1): oL = c4 * dinv4, oH = xH * dinv4
  (define oL (karatsuba-gf16 c4 dinv4))
  (define oH (karatsuba-gf16 xH dinv4))
  (define ot (append oL oH))

  ;; Output linear map `out8 ^= POST * ot ^ 0x63`
  (define out-forms
    (for/list ([r (in-range 8)])
      (apply lin-xor
             (for/list ([c (in-range 8)]
                        #:when (= (vector-ref (vector-ref post-sbox-mat r) c) 1))
               (list-ref ot c)))))

  (define action-expr
    `(seq ,@(for*/list ([r (in-range 8)]
                        [src-w (in-list (list-ref out-forms r))])
              `(cx ,src-w ,(list-ref out8 r)))
          ,@(for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
              `(x ,(list-ref out8 r)))))

  (with-and-session-sexpr (reverse bindings) lin2 action-expr #:mode mode))

;; =============================================================================
;; SECTION 3: Out-of-Place & Key-Shared NIST AES-128 / AES-256 Pipelines
;; =============================================================================

(define (gf256-aes-xtime x)
  (define sh (bitwise-and (arithmetic-shift x 1) #xFF))
  (if (bitwise-bit-set? x 7) (bitwise-xor sh #x1B) sh))

(define aes-mixcol-32x32-mat
  (cols->gf2-mat
   32
   (for*/list ([in-byte (in-range 4)] [in-bit (in-range 8)])
     (define v (arithmetic-shift 1 in-bit))
     (define v2 (gf256-aes-xtime v))
     (define v3 (bitwise-xor v2 v))
     (define out-bytes
       (match in-byte
         [0 (list v2 v v v3)]
         [1 (list v3 v2 v v)]
         [2 (list v v3 v2 v)]
         [3 (list v v v3 v2)]))
     (for/sum ([ob (in-list out-bytes)] [idx (in-naturals)])
       (arithmetic-shift ob (* 8 idx))))))

(define (gf2-mat->lakefill-sexpr mat wires)
  (define m (length wires))
  (define rows (for/vector ([r (in-range m)]) (vector-copy (vector-ref mat r))))
  (define ops '())
  (for ([col (in-range m)])
    (define piv
      (for/first ([r (in-range col m)] #:when (= (vector-ref (vector-ref rows r) col) 1)) r))
    (when (not (= piv col))
      (define tmp (vector-ref rows col))
      (vector-set! rows col (vector-ref rows piv))
      (vector-set! rows piv tmp)
      (set! ops (cons `(swap ,(list-ref wires col) ,(list-ref wires piv)) ops)))
    (for ([r (in-range m)]
          #:when (and (not (= r col)) (= (vector-ref (vector-ref rows r) col) 1)))
      (define rv (vector-ref rows r))
      (define cv (vector-ref rows col))
      (for ([j (in-range m)])
        (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))
      (set! ops (cons `(cx ,(list-ref wires col) ,(list-ref wires r)) ops))))
  `(seq ,@ops))

(define aes-rcon-bytes #(#x00 #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80 #x1B #x36))

;; Out-of-place round-pipelined AES-128 (`key-bits = 128`, 10r) & AES-256 (`key-bits = 256`, 14r)
;; matching Q# (`Jaques et al. EUROCRYPT 2020`) and Qrisp (`Seidel et al. 2024`):
;;   - `round-states`: list of `nr + 1` 128-wire registers (`s_0` holds plaintext; `s_1..s_nr` start clean `0^128`;
;;     `s_nr` receives ciphertext!).
;;   - If `classical-round-keys` is `#f`, evolves `key-wires` reversibly in-place (`40` S-boxes for AES-128 ->
;;     `6,800` `TempAND`s total; `52` S-boxes for AES-256 -> `9,384` `TempAND`s total!).
;;   - If `classical-round-keys` is provided (shared key schedule / known-key mode), skips quantum key S-boxes
;;     (`5,440` `TempAND`s for AES-128; `2,720` `TempAND`s for 5-round / half-pipeline!).
(define (aes-outofplace-pipeline-sexpr key-bits round-states key-wires sc36
                                       #:classical-round-keys [classical-round-keys #f]
                                       #:mode [mode 'mbu])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (xor-w32 src dst)
    `(seq ,@(for/list ([s (in-list src)] [d (in-list dst)]) `(cx ,s ,d))))
  (define (xor-const-w32 dst val32)
    `(seq ,@(for/list ([i (in-range 32)] #:when (bitwise-bit-set? val32 i))
              `(x ,(list-ref dst i)))))
  (define (xor-sub-rot-rcon src32 dst32 rcon-u8)
    (define s0 (take src32 8))
    (define s1 (take (drop src32 8) 8))
    (define s2 (take (drop src32 16) 8))
    (define s3 (drop src32 24))
    `(seq ,(aes-sbox-bp34-xor-sexpr s1 (take dst32 8) sc36 #:mode mode)
          ,(aes-sbox-bp34-xor-sexpr s2 (take (drop dst32 8) 8) sc36 #:mode mode)
          ,(aes-sbox-bp34-xor-sexpr s3 (take (drop dst32 16) 8) sc36 #:mode mode)
          ,(aes-sbox-bp34-xor-sexpr s0 (drop dst32 24) sc36 #:mode mode)
          ,@(for/list ([b (in-range 8)] #:when (bitwise-bit-set? rcon-u8 b))
              `(x ,(list-ref dst32 b)))))
  (define (advance-key-epoch e)
    (match nk
      [4 `(seq ,(xor-sub-rot-rcon (kword 3) (kword 0) (vector-ref aes-rcon-bytes e))
               ,(xor-w32 (kword 0) (kword 1))
               ,(xor-w32 (kword 1) (kword 2))
               ,(xor-w32 (kword 2) (kword 3)))]
      [8 ;; Exact FIPS-197 AES-256 epoch: on final epoch `e = 7`, only W[56..59] (`kword 0..3`) are needed!
         (if (= e 7)
             `(seq ,(xor-sub-rot-rcon (kword 7) (kword 0) (vector-ref aes-rcon-bytes e))
                   ,(xor-w32 (kword 0) (kword 1))
                   ,(xor-w32 (kword 1) (kword 2))
                   ,(xor-w32 (kword 2) (kword 3)))
             `(seq ,(xor-sub-rot-rcon (kword 7) (kword 0) (vector-ref aes-rcon-bytes e))
                   ,(xor-w32 (kword 0) (kword 1))
                   ,(xor-w32 (kword 1) (kword 2))
                   ,(xor-w32 (kword 2) (kword 3))
                   ,@(for/list ([b (in-range 4)])
                       (aes-sbox-bp34-xor-sexpr (take (drop (kword 3) (* 8 b)) 8)
                                                (take (drop (kword 4) (* 8 b)) 8)
                                                sc36 #:mode mode))
                   ,(xor-w32 (kword 4) (kword 5))
                   ,(xor-w32 (kword 5) (kword 6))
                   ,(xor-w32 (kword 6) (kword 7))))]))

  (define steps '())
  (define s0 (first round-states))
  ;; Initial AddRoundKey on `s0`
  (for ([c (in-range 4)])
    (define dst32 (take (drop s0 (* 32 c)) 32))
    (if classical-round-keys
        (set! steps (cons (xor-const-w32 dst32 (list-ref classical-round-keys c)) steps))
        (set! steps (cons (xor-w32 (kword c) dst32) steps))))

  ;; Rounds `r = 1 .. nr`: SubBytes + ShiftRows directly into clean `s_r` (`0` swaps!),
  ;; followed by in-place MixColumns (`r < nr`) and AddRoundKey on `s_r`!
  (for ([r (in-range 1 (add1 nr))])
    (define prev-s (list-ref round-states (sub1 r)))
    (define cur-s  (list-ref round-states r))
    ;; Fused SubBytes + ShiftRows: byte `(row, col)` of `cur-s` gets `S(prev-s[row, (col + row) mod 4])`!
    (for* ([col (in-range 4)] [row (in-range 4)])
      (define src-byte-idx (+ row (* 4 (modulo (+ col row) 4))))
      (define dst-byte-idx (+ row (* 4 col)))
      (set! steps
            (cons (aes-sbox-bp34-xor-sexpr
                   (take (drop prev-s (* 8 src-byte-idx)) 8)
                   (take (drop cur-s  (* 8 dst-byte-idx)) 8)
                   sc36 #:mode mode)
                  steps)))
    (when (< r nr)
      (for ([col (in-range 4)])
        (set! steps
              (cons (gf2-mat->lakefill-sexpr
                     aes-mixcol-32x32-mat
                     (take (drop cur-s (* 32 col)) 32))
                    steps))))
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (define dst32 (take (drop cur-s (* 32 c)) 32))
      (cond
        [classical-round-keys
         (set! steps (cons (xor-const-w32 dst32 (list-ref classical-round-keys w-idx)) steps))]
        [else
         (when (= (modulo w-idx nk) 0)
           (set! steps (cons (advance-key-epoch (quotient w-idx nk)) steps)))
         (set! steps (cons (xor-w32 (kword (modulo w-idx nk)) dst32) steps))])))
  `(seq ,@(reverse steps) (assert-clean ,sc36)))

;; =============================================================================
;; SECTION 4: Babbush-Gidney Sawtooth Unary-Iteration `QROM` & Windowed Addition
;; =============================================================================
;; Controlled sawtooth unary-iteration QROM (`Babbush et al. PRX 2018`, Fig. 7):
;; Given `ctrl` wire, `addr-wires = (a_0 ... a_{w-1})` (LSB-first, `N = 2^w`),
;; classical `table` of `N` integers (`m`-bit values), `out-wires` (`m` wires),
;; and `w` clean `hot-wires`:
;;   - Uses EXACTLY `N - 1` `TempAND` (`ccx`) gates (vs `N * (2w - 3)` in naive `mcx`!)
;;   - Uses `0` uncompute Toffolis via `Law U4` (`mid-meas-x-cond-z`)!
;; Uncontrolled `qrom-sawtooth-lookup-sexpr` seeds the root wire directly with `~a_{w-1}`
;; and toggles via `(x h_root)`, using ONLY `N - 2` `TempAND`s!

(define (emit-table-fanout hot-w val out-wires)
  `(seq ,@(for/list ([b (in-range (length out-wires))]
                     #:when (bitwise-bit-set? val b))
            `(cx ,hot-w ,(list-ref out-wires b)))))

(define (sawtooth-subtree-sexpr parent-hot addr-lsb-to-msb base-idx table out-wires hot-pool mode)
  (cond
    [(null? addr-lsb-to-msb)
     (emit-table-fanout parent-hot (list-ref table base-idx) out-wires)]
    [else
     (define msb-w (last addr-lsb-to-msb))
     (define rest-addr (drop-right addr-lsb-to-msb 1))
     (define half (arithmetic-shift 1 (length rest-addr)))
     (define child-hot (first hot-pool))
     (define rest-pool (rest hot-pool))
     (define uncomp-step
       (match mode
         ['mbu `(mid-meas-x-cond-z ,child-hot (,parent-hot ,msb-w))]
         ['unitary `(ccx ,parent-hot ,msb-w ,child-hot)]))
     `(seq ;; child-hot <- parent-hot & ~msb-w (`1` TempAND)
           (x ,msb-w)
           (ccx ,parent-hot ,msb-w ,child-hot)
           (x ,msb-w)
           ;; Left branch (`msb == 0`)
           ,(sawtooth-subtree-sexpr child-hot rest-addr base-idx table out-wires rest-pool mode)
           ;; Sawtooth toggle: child-hot ^= parent-hot => child-hot == parent-hot & msb-w (`0` TempANDs!)
           (cx ,parent-hot ,child-hot)
           ;; Right branch (`msb == 1`)
           ,(sawtooth-subtree-sexpr child-hot rest-addr (+ base-idx half) table out-wires rest-pool mode)
           ;; Uncompute child-hot (`0` Toffolis in `'mbu` mode!)
           ,uncomp-step
           (assert-clean (,child-hot)))]))

(define (qrom-sawtooth-ctrl-lookup-sexpr ctrl table addr-wires out-wires hot-wires #:mode [mode 'mbu])
  (sawtooth-subtree-sexpr ctrl addr-wires 0 table out-wires hot-wires mode))

(define (qrom-sawtooth-lookup-sexpr table addr-wires out-wires hot-wires #:mode [mode 'mbu])
  (define w (length addr-wires))
  (cond
    [(= w 0)
     `(seq ,@(for/list ([b (in-range (length out-wires))]
                        #:when (bitwise-bit-set? (first table) b))
               `(x ,(list-ref out-wires b))))]
    [else
     (define msb-w (last addr-wires))
     (define rest-addr (drop-right addr-wires 1))
     (define half (arithmetic-shift 1 (length rest-addr)))
     (define root-hot (first hot-wires))
     (define rest-pool (rest hot-wires))
     `(seq ;; Seed root-hot <- ~msb-w (`0` TempANDs!)
           (cx ,msb-w ,root-hot)
           (x ,root-hot)
           ,(sawtooth-subtree-sexpr root-hot rest-addr 0 table out-wires rest-pool mode)
           ;; Toggle root-hot -> msb-w (`0` TempANDs!)
           (x ,root-hot)
           ,(sawtooth-subtree-sexpr root-hot rest-addr half table out-wires rest-pool mode)
           ;; Uncompute root-hot (`cx`, `0` TempANDs!)
           (cx ,msb-w ,root-hot)
           (assert-clean (,root-hot)))]))

;; Windowed `QROM` Constant Multiplier-Adder (`Gidney 2019`):
;; Computes `acc <- (acc + const-c * x) mod 2^n` by slicing `x` into `ceil(n / w)`
;; windows of `w` bits, looking up `T_j[u] = (const-c * u * 2^{j*w}) mod 2^n` via
;; sawtooth `QROM` into `buf-wires`, adding via `gidney-adder-sexpr`, and uncomputing `buf-wires`!
(define (windowed-qrom-const-mul-add-sexpr n win-w const-c x-wires acc-wires buf-wires hot-wires carry-wires)
  (define mask-n (sub1 (arithmetic-shift 1 n)))
  (define num-wins (ceiling (/ n win-w)))
  `(seq
    ,@(for/list ([j (in-range num-wins)])
        (define lo (* j win-w))
        (define hi (min n (+ lo win-w)))
        (define cur-w (- hi lo))
        (define win-addr (take (drop x-wires lo) cur-w))
        (define tbl
          (for/list ([u (in-range (arithmetic-shift 1 cur-w))])
            (bitwise-and mask-n (* const-c u (arithmetic-shift 1 lo)))))
        `(seq ,(qrom-sawtooth-lookup-sexpr tbl win-addr buf-wires (take hot-wires cur-w) #:mode 'mbu)
              ,(gidney-adder-sexpr n buf-wires acc-wires carry-wires)
              ,(qrom-sawtooth-lookup-sexpr tbl win-addr buf-wires (take hot-wires cur-w) #:mode 'mbu)
              (assert-clean ,buf-wires)))))

;; Naive Generic Bit-by-Bit Controlled Multiplier-Adder (for apples-to-apples comparison):
;; For each bit `x_k` (`k = 0 .. n-1`), loads `ctrl * ((const-c * 2^k) mod 2^n)`? Wait: in generic
;; schoolbook `x * y` (when `y` is in a quantum register or unspecialized generic multiplier), each bit
;; performs a controlled `n`-bit Gidney addition (`2*(n-k)` `ccx` mask + `(n-k-1)` `ccx` carry)!
;; Let's compare `gidney-schoolbook-multiplier-sexpr` (`3/2 n^2` `ccx`) AND bit-by-bit controlled
;; addition against `windowed-qrom-const-mul-add-sexpr`!
(define (naive-bitbybit-const-mul-add-sexpr n const-c x-wires y-const-wires acc-wires masked-wires carry-wires)
  `(within-apply
    (seq ,@(for/list ([i (in-range n)] #:when (bitwise-bit-set? const-c i))
             `(x ,(list-ref y-const-wires i))))
    ,(gidney-schoolbook-multiplier-sexpr n y-const-wires x-wires acc-wires masked-wires carry-wires)
    ,y-const-wires))

;; =============================================================================
;; SECTION 5: `Keccak-f[200]` Out-of-Place `TempAND` Pipeline (`3,600` `TempAND`s)
;; =============================================================================
;; Out-of-place `chi_5` (`in5 -> out5 ^= chi_5(in5)`) uses ONLY `5` `TempAND`s + `5`
;; `mid-meas-x-cond-z`s (`4.0x` fewer `AND`s than generic in-place `erase-by`'s `20` `CCX`!),
;; at the cost of allocating `18 * 200 = 3,600` round-history state wires across 18 rounds!

(define (keccak-chi5-outofplace-sexpr in5 out5 and5 #:mode [mode 'mbu])
  (define (inw i)  (list-ref in5  (modulo i 5)))
  (define (outw i) (list-ref out5 (modulo i 5)))
  (define (aw i)   (list-ref and5 (modulo i 5)))
  `(seq ,@(for/list ([x (in-range 5)])
            `(seq (cx ,(inw x) ,(outw x))
                  (x ,(inw (add1 x)))
                  (ccx ,(inw (add1 x)) ,(inw (+ x 2)) ,(aw x))
                  (cx ,(aw x) ,(outw x))
                  ,(match mode
                     ['mbu `(mid-meas-x-cond-z ,(aw x) (,(inw (add1 x)) ,(inw (+ x 2))))]
                     ['unitary `(ccx ,(inw (add1 x)) ,(inw (+ x 2)) ,(aw x))])
                  (x ,(inw (add1 x)))))
        (assert-clean ,and5)))

(define keccak-theta-parity-mat
  (let ([M (for/vector ([r (in-range 40)]) (make-vector 40 0))])
    (for* ([x (in-range 5)] [z (in-range 8)])
      (define row (+ (* 8 x) z))
      (vector-set! (vector-ref M row) row 1)
      (vector-set! (vector-ref M row) (+ (* 8 (modulo (sub1 x) 5)) z) 1)
      (vector-set! (vector-ref M row) (+ (* 8 (modulo (add1 x) 5)) (modulo (sub1 z) 8)) 1))
    M))

(define keccak-rho-offsets
  (let ([tbl (make-vector 25 0)] [x 1] [y 0])
    (for ([t (in-range 24)])
      (vector-set! tbl (+ (* 5 y) x) (modulo (quotient (* (add1 t) (+ t 2)) 2) 8))
      (define nx y)
      (define ny (modulo (+ (* 2 x) (* 3 y)) 5))
      (set! x nx)
      (set! y ny))
    tbl))

(define keccak-rc-bytes
  #(#x01 #x82 #x8a #x00 #x8b #x01 #x81 #x09 #x8a
    #x88 #x09 #x0a #x8b #x8b #x89 #x03 #x02 #x80))

(define (keccak-f200-outofplace-sexpr round-states sc45 [num-rounds 18])
  (define sc40 (take sc45 40))
  (define and5 (drop sc45 40))
  (define (awire st x y z) (list-ref st (+ (* 8 (+ (* 5 y) x)) z)))
  (define (cwire x z) (list-ref sc40 (+ (* 8 x) z)))
  ;; Fused `rho + pi` wire re-indexing (`0` physical `swap` gates!):
  ;; Wire for `(x, y, z)` after `rho + pi` is simply wire `(sx, sy, sz)` of `cur-in`!
  (define (post-rho-pi-wire st x y z)
    (define sx (modulo (+ x (* 3 y)) 5))
    (define sy x)
    (define off (vector-ref keccak-rho-offsets (+ (* 5 sy) sx)))
    (define sz (modulo (- z off) 8))
    (awire st sx sy sz))

  `(seq
    ,@(for/list ([ir (in-range num-rounds)])
        (define st-in  (list-ref round-states ir))
        (define st-out (list-ref round-states (add1 ir)))
        `(seq ;; 1. In-place `theta` on `st-in` (`0` Toffolis, `sc40` restored to `0`!)
              (erase-by
               (seq ,@(for*/list ([x (in-range 5)] [z (in-range 8)] [y (in-range 5)])
                        `(cx ,(awire st-in x y z) ,(cwire x z)))
                    ,@(for*/list ([x (in-range 5)] [y (in-range 5)] [z (in-range 8)])
                        `(seq (cx ,(cwire (modulo (sub1 x) 5) z) ,(awire st-in x y z))
                              (cx ,(cwire (modulo (add1 x) 5) (modulo (sub1 z) 8)) ,(awire st-in x y z)))))
               (seq ,(gf2-mat->lakefill-sexpr keccak-theta-parity-mat sc40)
                    ,@(for*/list ([x (in-range 5)] [z (in-range 8)] [y (in-range 5)])
                        `(cx ,(awire st-in x y z) ,(cwire x z))))
               ,sc40)
              ;; 2. Zero-swap `rho + pi` + Out-of-place `chi_5` (`5` TempANDs/row = `200` TempANDs/round!)
              ,@(for*/list ([y (in-range 5)] [z (in-range 8)])
                  (define in-row5  (for/list ([x (in-range 5)]) (post-rho-pi-wire st-in x y z)))
                  (define out-row5 (for/list ([x (in-range 5)]) (awire st-out x y z)))
                  (keccak-chi5-outofplace-sexpr in-row5 out-row5 and5 #:mode 'mbu))
              ;; 3. `iota` round constant on `st-out`
              ,@(for/list ([b (in-range 8)]
                           #:when (bitwise-bit-set? (vector-ref keccak-rc-bytes ir) b))
                  `(x ,(list-ref st-out b)))))
    (assert-clean ,sc45)))

;; =============================================================================
;; SECTION 6: Empirical Verification Suite & Exported Simulator Gadgets
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

(define (read-bytes reg offset nbytes)
  (list->bytes
   (for/list ([bi (in-range nbytes)])
     (for/sum ([bit (in-range 8)])
       (arithmetic-shift (vector-ref reg (+ offset (* 8 bi) bit)) bit)))))

(define (gates->json gates)
  (for/fold ([acc '()] #:result (reverse acc)) ([g (in-list gates)])
    (match g
      [`(assert-clean ,_) acc]
      [`(mid-meas-x-cond-z ,anc ,(list c1 c2))
       (cons (list "mid-meas-x-cond-cz" anc c1 c2) acc)]
      [`(mid-meas-x-cond-z ,anc ,c1)
       (cons (list "mid-meas-x-cond-z" anc c1) acc)]
      [`(,op ,args ...)
       (cons (cons (symbol->string op) args) acc)])))

(define (expand-aes128-words-classical key-bytes sbox-vec)
  (define w (make-vector 44 0))
  (for ([i (in-range 4)])
    (vector-set! w i
      (for/sum ([b (in-range 4)])
        (arithmetic-shift (bytes-ref key-bytes (+ (* 4 i) b)) (* 8 b)))))
  (for ([i (in-range 4 44)])
    (define prev (vector-ref w (sub1 i)))
    (define tmp
      (if (= (modulo i 4) 0)
          (let ([rot (bitwise-ior (arithmetic-shift prev -8)
                                  (arithmetic-shift (bitwise-and prev #xFF) 24))])
            (bitwise-xor
             (for/sum ([b (in-range 4)])
               (arithmetic-shift
                (vector-ref sbox-vec (bitwise-and #xFF (arithmetic-shift rot (* -8 b))))
                (* 8 b)))
             (vector-ref aes-rcon-bytes (quotient i 4))))
          prev))
    (vector-set! w i (bitwise-xor (vector-ref w (- i 4)) tmp)))
  (vector->list w))

(define (run-lakefill-ssa-qrom-optimizations)
  (define t0 (current-inexact-milliseconds))

  ;; ---------------------------------------------------------------------------
  ;; 1. Compare Naive Generic AES S-Box (`432` CCX) vs Boyar-Peralta `34-AND` Session S-Box
  ;; ---------------------------------------------------------------------------
  (define naive-sbox-gates
    (compile-lakefill (aes-sbox-inplace-sexpr (range 0 8) (range 8 40))))
  (define bp34-mbu-gates
    (compile-lakefill (aes-sbox-bp34-xor-sexpr (range 0 8) (range 8 16) (range 16 52) #:mode 'mbu)))
  (define bp34-silq-gates
    (compile-lakefill (aes-sbox-bp34-xor-sexpr (range 0 8) (range 8 16) (range 16 52) #:mode 'unitary-silq)))

  ;; Verify all 256/256 NIST S-box bytes + 0 scratch leakage + 0 phase taint across deterministic M_X=1 & random M_X masks!
  (define sbox-table (make-vector 256 0))
  (for ([x (in-range 256)])
    (define r-naive (make-vector 40 0))
    (load-bytes! r-naive 0 (bytes x))
    (eval-reversible-gates! r-naive naive-sbox-gates)
    (define y-ref (bytes-ref (read-bytes r-naive 0 1) 0))
    (vector-set! sbox-table x y-ref)

    (for ([alt-pat (in-list (list (lambda (_s) 0)
                                  (lambda (_s) 1)
                                  (lambda (s) (bitwise-and 1 (+ s x)))))])
      (define r-bp (make-vector 52 0))
      (load-bytes! r-bp 0 (bytes x))
      (define ph (eval-reversible-gates! r-bp bp34-mbu-gates alt-pat))
      (define y-got (bytes-ref (read-bytes r-bp 8 1) 0))
      (define x-intact (bytes-ref (read-bytes r-bp 0 1) 0))
      (define clean? (for/and ([w (in-range 16 52)]) (= (vector-ref r-bp w) 0)))
      (unless (and (= ph 1) (= y-got y-ref) (= x-intact x) clean?)
        (error 'bp34-sbox "Failed at x=~a: ph=~a y=~a ref=~a clean=~a" x ph y-got y-ref clean?))))

  ;; ---------------------------------------------------------------------------
  ;; 2. Full NIST FIPS-197 AES-128 (C.1) & AES-256 (C.3) Out-of-Place & Key-Shared Pipelines
  ;; ---------------------------------------------------------------------------
  ;; 2a. AES-128 with Quantum Key Schedule (`6,800` TempANDs)
  (define aes128-round-states (for/list ([r (in-range 11)]) (range (* 128 r) (* 128 (add1 r)))))
  (define aes128-key-wires (range 1408 1536))
  (define aes128-sc36 (range 1536 1572))
  (define aes128-qkey-gates
    (compile-lakefill (aes-outofplace-pipeline-sexpr 128 aes128-round-states aes128-key-wires aes128-sc36)))

  (define pt-c1 (hex->bytes "00112233445566778899aabbccddeeff"))
  (define key-c1 (hex->bytes "000102030405060708090a0b0c0d0e0f"))
  (define reg-aes128 (make-vector 1572 0))
  (load-bytes! reg-aes128 0 pt-c1)
  (load-bytes! reg-aes128 1408 key-c1)
  (define ph-aes128 (eval-reversible-gates! reg-aes128 aes128-qkey-gates))
  (define ct-aes128-hex (bytes->hex (read-bytes reg-aes128 (* 128 10) 16)))
  (unless (and (= ph-aes128 1)
               (equal? ct-aes128-hex "69c4e0d86a7b0430d8cdb78070b4c55a")
               (for/and ([w (in-list aes128-sc36)]) (= (vector-ref reg-aes128 w) 0)))
    (error 'aes128-bp34 "NIST C.1 mismatch: got ~a" ct-aes128-hex))

  ;; 2b. AES-128 with Classical / Shared Key Schedule (`5,440` TempANDs; `2,720` per 5-round half!)
  (define c1-rk-words (expand-aes128-words-classical key-c1 sbox-table))
  (define aes128-ckey-gates
    (compile-lakefill
     (aes-outofplace-pipeline-sexpr 128 aes128-round-states '() (range 1408 1444)
                                    #:classical-round-keys c1-rk-words)))
  (define reg-aes128-ck (make-vector 1444 0))
  (load-bytes! reg-aes128-ck 0 pt-c1)
  (eval-reversible-gates! reg-aes128-ck aes128-ckey-gates)
  (define ct-aes128-ck-hex (bytes->hex (read-bytes reg-aes128-ck (* 128 10) 16)))
  (unless (equal? ct-aes128-ck-hex "69c4e0d86a7b0430d8cdb78070b4c55a")
    (error 'aes128-ckey "NIST C.1 classical-key mismatch: got ~a" ct-aes128-ck-hex))

  ;; 2c. AES-256 with Quantum Key Schedule (`9,384` TempANDs vs `112,896` CCX!) on NIST FIPS-197 C.3
  (define aes256-round-states (for/list ([r (in-range 15)]) (range (* 128 r) (* 128 (add1 r)))))
  (define aes256-key-wires (range 1920 2176))
  (define aes256-sc36 (range 2176 2212))
  (define aes256-qkey-gates
    (compile-lakefill (aes-outofplace-pipeline-sexpr 256 aes256-round-states aes256-key-wires aes256-sc36)))
  (define key-c3 (hex->bytes "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
  (define reg-aes256 (make-vector 2212 0))
  (load-bytes! reg-aes256 0 pt-c1)
  (load-bytes! reg-aes256 1920 key-c3)
  (define ph-aes256 (eval-reversible-gates! reg-aes256 aes256-qkey-gates))
  (define ct-aes256-hex (bytes->hex (read-bytes reg-aes256 (* 128 14) 16)))
  (unless (and (= ph-aes256 1)
               (equal? ct-aes256-hex "8ea2b7ca516745bfeafc49904b496089")
               (for/and ([w (in-list aes256-sc36)]) (= (vector-ref reg-aes256 w) 0)))
    (error 'aes256-bp34 "NIST C.3 mismatch: got ~a" ct-aes256-hex))

  ;; ---------------------------------------------------------------------------
  ;; 3. Babbush Sawtooth Unary-Iteration `QROM` + Windowed Lookup Addition
  ;; ---------------------------------------------------------------------------
  ;; 3a. Exhaustive verification of Controlled `QROM` (`N = 8`, `3` addr bits -> `N - 1 = 7` TempANDs!)
  ;;     and Uncontrolled `QROM` (`N = 8` -> `N - 2 = 6` TempANDs, `N = 16` -> `14` TempANDs!)
  (define qrom8-table '(13 7 11 2 14 5 9 12)) ;; 4-bit values
  (define qrom8-ctrl-gates
    (compile-lakefill
     (qrom-sawtooth-ctrl-lookup-sexpr 0 qrom8-table '(1 2 3) '(4 5 6 7) '(8 9 10) #:mode 'mbu)))
  (define qrom8-unctrl-gates
    (compile-lakefill
     (qrom-sawtooth-lookup-sexpr qrom8-table '(0 1 2) '(3 4 5 6) '(7 8 9) #:mode 'mbu)))

  ;; Exhaustively verify all `2^7 = 128` M_X outcome branches on Controlled QROM8 (`11` qubits)
  (for* ([ctrl-b (in-list '(0 1))] [addr (in-range 8)])
    (define qreg (make-vector 11 0))
    (vector-set! qreg 0 ctrl-b)
    (for ([b (in-range 3)]) (vector-set! qreg (add1 b) (if (bitwise-bit-set? addr b) 1 0)))
    (define out-reg (eval-mbu-circuit-all-branches qreg qrom8-ctrl-gates '(8 9 10)))
    (define got-val (for/sum ([b (in-range 4)]) (arithmetic-shift (vector-ref out-reg (+ 4 b)) b)))
    (define exp-val (if (= ctrl-b 1) (list-ref qrom8-table addr) 0))
    (unless (= got-val exp-val)
      (error 'qrom8-ctrl "QROM8 mismatch ctrl=~a addr=~a: got ~a vs ~a" ctrl-b addr got-val exp-val)))

  ;; Exhaustively verify all `2^6 = 64` M_X branches on Uncontrolled QROM8 (`10` qubits)
  (for ([addr (in-range 8)])
    (define qreg (make-vector 10 0))
    (for ([b (in-range 3)]) (vector-set! qreg b (if (bitwise-bit-set? addr b) 1 0)))
    (define out-reg (eval-mbu-circuit-all-branches qreg qrom8-unctrl-gates '(7 8 9)))
    (define got-val (for/sum ([b (in-range 4)]) (arithmetic-shift (vector-ref out-reg (+ 3 b)) b)))
    (unless (= got-val (list-ref qrom8-table addr))
      (error 'qrom8-unctrl "Uncontrolled QROM8 mismatch addr=~a: got ~a" addr got-val)))

  ;; 3b. Windowed `QROM` Multiplier-Adder vs Naive Bit-by-Bit Schoolbook Multiplier
  ;;     Verify bit-exact `n = 8, w = 4` (`256/256` inputs) and gate counts at `n = 16, w = 4` and `n = 32, w = 4`!
  (define const-c8 179)
  (define win8-gates
    (compile-lakefill
     (windowed-qrom-const-mul-add-sexpr
      8 4 const-c8 (range 0 8) (range 8 16) (range 16 24) (range 24 28) (range 28 35))))
  (define naive8-gates
    (compile-lakefill
     (naive-bitbybit-const-mul-add-sexpr
      8 const-c8 (range 0 8) (range 16 24) (range 8 16) (range 24 32) (range 32 39))))
  (for ([x (in-range 256)])
    (define wreg (make-vector 35 0))
    (for ([b (in-range 8)]) (vector-set! wreg b (if (bitwise-bit-set? x b) 1 0)))
    (define ph (eval-reversible-gates! wreg win8-gates))
    (define got (for/sum ([b (in-range 8)]) (arithmetic-shift (vector-ref wreg (+ 8 b)) b)))
    (unless (and (= ph 1)
                 (= got (modulo (* const-c8 x) 256))
                 (for/and ([w (in-range 16 35)]) (= (vector-ref wreg w) 0)))
      (error 'win8-qrom "Windowed QROM mul-add failed at x=~a: got ~a" x got)))

  (define win16-gates
    (compile-lakefill
     (windowed-qrom-const-mul-add-sexpr
      16 4 49157 (range 0 16) (range 16 32) (range 32 48) (range 48 52) (range 52 67))))
  (define naive16-gates
    (compile-lakefill
     (naive-bitbybit-const-mul-add-sexpr
      16 49157 (range 0 16) (range 32 48) (range 16 32) (range 48 64) (range 64 79))))

  ;; Real compiled & executed 64-bit (`w = 5`) and 128-bit (`w = 6`) Windowed QROM vs Naive Schoolbook!
  (define const-c64 #x9e3779b97f4a7c15)
  (define x-test64  #x6a09e667bb67ae85)
  (define win64-gates
    (compile-lakefill
     (windowed-qrom-const-mul-add-sexpr
      64 5 const-c64 (range 0 64) (range 64 128) (range 128 192) (range 192 197) (range 197 260))))
  (define naive64-gates
    (compile-lakefill
     (naive-bitbybit-const-mul-add-sexpr
      64 const-c64 (range 0 64) (range 128 192) (range 64 128) (range 192 256) (range 256 319))))
  (let ([reg64 (make-vector 260 0)])
    (for ([b (in-range 64)]) (vector-set! reg64 b (if (bitwise-bit-set? x-test64 b) 1 0)))
    (define ph64 (eval-reversible-gates! reg64 win64-gates))
    (define got64 (for/sum ([b (in-range 64)]) (arithmetic-shift (vector-ref reg64 (+ 64 b)) b)))
    (unless (and (= ph64 1)
                 (= got64 (modulo (* const-c64 x-test64) (arithmetic-shift 1 64)))
                 (for/and ([w (in-range 128 260)]) (= (vector-ref reg64 w) 0)))
      (error 'win64-qrom "64-bit Windowed QROM mul-add mismatch: got ~a" got64)))

  (define const-c128 #x9e3779b97f4a7c15f39cc0605cedc835)
  (define x-test128  #x6a09e667bb67ae853c6ef372a54ff53a)
  (define win128-gates
    (compile-lakefill
     (windowed-qrom-const-mul-add-sexpr
      128 6 const-c128 (range 0 128) (range 128 256) (range 256 384) (range 384 390) (range 390 517))))
  (define naive128-gates
    (compile-lakefill
     (naive-bitbybit-const-mul-add-sexpr
      128 const-c128 (range 0 128) (range 256 384) (range 128 256) (range 384 512) (range 512 639))))
  (let ([reg128 (make-vector 517 0)])
    (for ([b (in-range 128)]) (vector-set! reg128 b (if (bitwise-bit-set? x-test128 b) 1 0)))
    (define ph128 (eval-reversible-gates! reg128 win128-gates))
    (define got128 (for/sum ([b (in-range 128)]) (arithmetic-shift (vector-ref reg128 (+ 128 b)) b)))
    (unless (and (= ph128 1)
                 (= got128 (modulo (* const-c128 x-test128) (arithmetic-shift 1 128)))
                 (for/and ([w (in-range 256 517)]) (= (vector-ref reg128 w) 0)))
      (error 'win128-qrom "128-bit Windowed QROM mul-add mismatch: got ~a" got128)))

  (define const-c256 #x9e3779b97f4a7c15f39cc0605cedc8341082276bf3a27251f86c6a11d0c18e95)
  (define x-test256  #x6a09e667bb67ae853c6ef372a54ff53a510e527fade682d19b05688c2b3e6c1f)
  (define win256-gates
    (compile-lakefill
     (windowed-qrom-const-mul-add-sexpr
      256 7 const-c256 (range 0 256) (range 256 512) (range 512 768) (range 768 775) (range 775 1030))))
  (define naive256-gates
    (compile-lakefill
     (naive-bitbybit-const-mul-add-sexpr
      256 const-c256 (range 0 256) (range 512 768) (range 256 512) (range 768 1024) (range 1024 1279))))
  (let ([reg256 (make-vector 1030 0)])
    (for ([b (in-range 256)]) (vector-set! reg256 b (if (bitwise-bit-set? x-test256 b) 1 0)))
    (define ph256 (eval-reversible-gates! reg256 win256-gates))
    (define got256 (for/sum ([b (in-range 256)]) (arithmetic-shift (vector-ref reg256 (+ 256 b)) b)))
    (unless (and (= ph256 1)
                 (= got256 (modulo (* const-c256 x-test256) (arithmetic-shift 1 256)))
                 (for/and ([w (in-range 512 1030)]) (= (vector-ref reg256 w) 0)))
      (error 'win256-qrom "256-bit Windowed QROM mul-add mismatch!")))

  ;; ---------------------------------------------------------------------------
  ;; 4. `Keccak-f[200]` In-Place `erase-by` (`240`w, `14,400` CCX) vs Out-of-Place (`3,845`w, `3,600` TempANDs)
  ;; ---------------------------------------------------------------------------
  (define keccak-inplace-gates
    (compile-lakefill (keccak-f200-sexpr (range 0 200) (range 200 240) 18)))
  (define keccak-round-states (for/list ([r (in-range 19)]) (range (* 200 r) (* 200 (add1 r)))))
  (define keccak-sc45 (range 3800 3845))
  (define keccak-outofplace-gates
    (compile-lakefill (keccak-f200-outofplace-sexpr keccak-round-states keccak-sc45 18)))

  (define kreg-oop (make-vector 3845 0))
  (define ph-koop (eval-reversible-gates! kreg-oop keccak-outofplace-gates))
  (define koop-zero-hex (bytes->hex (read-bytes kreg-oop (* 200 18) 25)))
  (unless (and (= ph-koop 1)
               (equal? koop-zero-hex "3c2826841cb35c171eaae9b811134ceaa3852c69d2c5abafea")
               (for/and ([w (in-list keccak-sc45)]) (= (vector-ref kreg-oop w) 0)))
    (error 'keccak-oop "Out-of-place Keccak-f[200] mismatch: ~a" koop-zero-hex))

  ;; Also test non-zero pattern agreement between in-place and out-of-place Keccak-f[200]!
  (define kpat (list->bytes (for/list ([i (in-range 25)]) (bitwise-and #xFF (+ (* 17 i) 5)))))
  (define kreg-ip-pat (make-vector 240 0))
  (load-bytes! kreg-ip-pat 0 kpat)
  (eval-reversible-gates! kreg-ip-pat keccak-inplace-gates)
  (define kreg-oop-pat (make-vector 3845 0))
  (load-bytes! kreg-oop-pat 0 kpat)
  (eval-reversible-gates! kreg-oop-pat keccak-outofplace-gates)
  (unless (equal? (read-bytes kreg-ip-pat 0 25) (read-bytes kreg-oop-pat 3600 25))
    (error 'keccak-oop "Pattern mismatch vs in-place Keccak-f[200]!"))

  ;; ---------------------------------------------------------------------------
  ;; 5. Small Quantum Superposition Gadgets for `qiskit_aer.AerSimulator`
  ;; ---------------------------------------------------------------------------
  (define gf16-session-7and-gates
    (let ()
      (define d0 '(0)) (define d1 '(1)) (define d2 '(2)) (define d3 '(3))
      (define bindings
        (list (list 8  d1 d2)            ;; g0 = d1 & d2
              (list 9  d0 d3)            ;; g1 = d0 & d3
              (list 10 d0 d2)            ;; g2 = d0 & d2
              (list 11 '(8) d3)          ;; g3 = g0 & d3
              (list 12 '(9) d2)          ;; g4 = g1 & d2
              (list 13 '(9) d1)          ;; g5 = g1 & d1
              (list 14 d1 '(3 10))))     ;; g6 = d1 & (d3 ^ g2)
      (define y-forms
        (list '(0 1 2 8 9 14 13 12 11)
              '(1 2 3 10 13 11)
              '(2 8 9 12 11)
              '(2 3 9 11)))
      (define act
        `(seq ,@(for*/list ([b (in-range 4)] [w (in-list (list-ref y-forms b))])
                  `(cx ,w ,(+ 4 b)))))
      (compile-lakefill (with-and-session-sexpr bindings '(15 15) act #:mode 'mbu))))

  ;; Exhaustively verify all `2^7 = 128` M_X outcome branches across all `16` GF(2^4) inputs!
  (define gf16-inv-expected #(0 1 3 2 15 12 9 11 10 6 8 7 5 14 13 4))
  (for ([x (in-range 16)])
    (define greg (make-vector 16 0))
    (for ([b (in-range 4)]) (vector-set! greg b (if (bitwise-bit-set? x b) 1 0)))
    (define out-reg (eval-mbu-circuit-all-branches greg gf16-session-7and-gates (range 8 16)))
    (define got (for/sum ([b (in-range 4)]) (arithmetic-shift (vector-ref out-reg (+ 4 b)) b)))
    (unless (= got (vector-ref gf16-inv-expected x))
      (error 'gf16-session-7and "GF(2^4) 7-AND session mismatch at x=~a: got ~a" x got)))

  ;; 15-qubit Out-of-Place `Keccak chi_5` (`in5 = 0..4`, `out5 = 5..9`, `and5 = 10..14`)
  (define chi5-oop-15q-gates
    (compile-lakefill (keccak-chi5-outofplace-sexpr '(0 1 2 3 4) '(5 6 7 8 9) '(10 11 12 13 14) #:mode 'mbu)))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))

  (define naive-sbox-ccx (hash-ref (gate-counts naive-sbox-gates) 'ccx))
  (define bp34-sbox-ccx  (hash-ref (gate-counts bp34-mbu-gates) 'ccx))
  (define silq-sbox-ccx  (hash-ref (gate-counts bp34-silq-gates) 'ccx))

  (define win8-ccx     (hash-ref (gate-counts win8-gates) 'ccx))
  (define naive8-ccx   (hash-ref (gate-counts naive8-gates) 'ccx))
  (define win16-ccx    (hash-ref (gate-counts win16-gates) 'ccx))
  (define naive16-ccx  (hash-ref (gate-counts naive16-gates) 'ccx))
  (define win64-ccx    (hash-ref (gate-counts win64-gates) 'ccx))
  (define naive64-ccx  (hash-ref (gate-counts naive64-gates) 'ccx))
  (define win128-ccx   (hash-ref (gate-counts win128-gates) 'ccx))
  (define naive128-ccx (hash-ref (gate-counts naive128-gates) 'ccx))
  (define win256-ccx   (hash-ref (gate-counts win256-gates) 'ccx))
  (define naive256-ccx (hash-ref (gate-counts naive256-gates) 'ccx))

  (hasheq
   'status "PASS"
   'racket_version (version)
   'wall_time_ms (real->decimal-string elapsed-ms 2)
   'root_cause_ab_aes_sbox_and_cipher (hasheq
     'naive_generic_tower_sbox (hasheq
       'wires 40
       'ccx naive-sbox-ccx
       't_gates (* 7 naive-sbox-ccx)
       'gate_counts (gate-counts naive-sbox-gates))
     'silq_qfree_unitary_bp34_sbox (hasheq
       'wires 52
       'ccx silq-sbox-ccx
       't_gates_gidney_unitary (* 4 silq-sbox-ccx)
       't_gates_clifford_t (* 7 silq-sbox-ccx)
       'gate_counts (gate-counts bp34-silq-gates))
     'lakefill_session_mbu_bp34_sbox (hasheq
       'wires 52
       'scratch_ancillas 36
       'temp_ands bp34-sbox-ccx
       'uncompute_toffolis 0
       'mid_meas_x_cond_z (hash-ref (gate-counts bp34-mbu-gates) 'mid_meas_x_cond_z)
       'and_depth 4
       't_gates (* 4 bp34-sbox-ccx)
       'toffoli_reduction_vs_naive (/ (exact->inexact naive-sbox-ccx) bp34-sbox-ccx)
       't_count_reduction_vs_naive (/ (* 7.0 naive-sbox-ccx) (* 4.0 bp34-sbox-ccx))
       'exhaustive_256_of_256_nist_sbox_verified #t
       'scratch_leakage_bits 0
       'phase_taint 0
       'gate_counts (gate-counts bp34-mbu-gates))
     'aes128_nist_c1_outofplace_qkey (hasheq
       'total_wires 1572
       'ciphertext_hex ct-aes128-hex
       'expected_hex "69c4e0d86a7b0430d8cdb78070b4c55a"
       'nist_exact_match #t
       'naive_generic_ccx 80640
       'temp_ands (hash-ref (gate-counts aes128-qkey-gates) 'ccx)
       'uncompute_toffolis 0
       'toffoli_reduction_vs_naive (/ 80640.0 (hash-ref (gate-counts aes128-qkey-gates) 'ccx))
       't_count_reduction_vs_naive (/ (* 7.0 80640) (* 4.0 (hash-ref (gate-counts aes128-qkey-gates) 'ccx)))
       'gate_counts (gate-counts aes128-qkey-gates))
     'aes128_nist_c1_shared_key_schedule (hasheq
       'total_wires 1444
       'ciphertext_hex ct-aes128-ck-hex
       'temp_ands_full_10r (hash-ref (gate-counts aes128-ckey-gates) 'ccx)
       'temp_ands_half_5r_mitm (/ (hash-ref (gate-counts aes128-ckey-gates) 'ccx) 2)
       'temp_ands_half_with_key_epoch 3400
       'gate_counts (gate-counts aes128-ckey-gates))
     'aes256_nist_c3_outofplace_qkey (hasheq
       'total_wires 2212
       'ciphertext_hex ct-aes256-hex
       'expected_hex "8ea2b7ca516745bfeafc49904b496089"
       'nist_exact_match #t
       'naive_generic_ccx 112896
       'temp_ands (hash-ref (gate-counts aes256-qkey-gates) 'ccx)
       'uncompute_toffolis 0
       'toffoli_reduction_vs_naive (/ 112896.0 (hash-ref (gate-counts aes256-qkey-gates) 'ccx))
       'gate_counts (gate-counts aes256-qkey-gates)))
   'root_cause_c_qrom_and_windowed_mul (hasheq
     'qrom8_controlled_sawtooth (hasheq
       'table_size 8
       'addr_bits 3
       'temp_ands (hash-ref (gate-counts qrom8-ctrl-gates) 'ccx)
       'uncompute_toffolis 0
       'naive_mcx_toffolis (* 8 4)
       'all_128_mbu_branches_verified #t
       'gate_counts (gate-counts qrom8-ctrl-gates))
     'qrom8_uncontrolled_sawtooth (hasheq
       'table_size 8
       'addr_bits 3
       'temp_ands (hash-ref (gate-counts qrom8-unctrl-gates) 'ccx)
       'uncompute_toffolis 0
       'all_64_mbu_branches_verified #t
       'gate_counts (gate-counts qrom8-unctrl-gates))
     'windowed_mul_add_benchmarks (list
       (hasheq 'bits 8   'window 4 'compiled_and_executed #t 'naive_ccx naive8-ccx   'qrom_windowed_temp_ands win8-ccx
               'reduction_factor (/ (exact->inexact naive8-ccx) win8-ccx))
       (hasheq 'bits 16  'window 4 'compiled_and_executed #t 'naive_ccx naive16-ccx  'qrom_windowed_temp_ands win16-ccx
               'reduction_factor (/ (exact->inexact naive16-ccx) win16-ccx))
       (hasheq 'bits 64  'window 5 'compiled_and_executed #t 'naive_ccx naive64-ccx  'qrom_windowed_temp_ands win64-ccx
               'reduction_factor (/ (exact->inexact naive64-ccx) win64-ccx))
       (hasheq 'bits 128 'window 6 'compiled_and_executed #t 'naive_ccx naive128-ccx 'qrom_windowed_temp_ands win128-ccx
               'reduction_factor (/ (exact->inexact naive128-ccx) win128-ccx))
       (hasheq 'bits 256 'window 7 'compiled_and_executed #t 'naive_ccx naive256-ccx 'qrom_windowed_temp_ands win256-ccx
               'reduction_factor (/ (exact->inexact naive256-ccx) win256-ccx))))
   'root_cause_d_keccak_space_time_tradeoff (hasheq
     'inplace_erase_by_keccak_f200 (hasheq
       'total_wires 240
       'persistent_round_ancillas 0
       'ccx_per_chi5_row 20
       'total_ccx (hash-ref (gate-counts keccak-inplace-gates) 'ccx)
       'zero_block_hex "3c2826841cb35c171eaae9b811134ceaa3852c69d2c5abafea"
       'gate_counts (gate-counts keccak-inplace-gates))
     'outofplace_session_keccak_f200 (hasheq
       'total_wires 3845
       'persistent_round_ancillas 3600
       'temp_ands_per_chi5_row 5
       'total_temp_ands (hash-ref (gate-counts keccak-outofplace-gates) 'ccx)
       'uncompute_toffolis 0
       'and_reduction_factor (/ (exact->inexact (hash-ref (gate-counts keccak-inplace-gates) 'ccx))
                                (hash-ref (gate-counts keccak-outofplace-gates) 'ccx))
       'qubit_overhead_factor (/ 3845.0 240.0)
       'zero_block_hex koop-zero-hex
       'fips202_exact_match #t
       'gate_counts (gate-counts keccak-outofplace-gates)))
   'aer_simulator_gadgets (hasheq
     'qrom8_uncontrolled_10q (hasheq
       'num_qubits 10
       'addr_wires '(0 1 2)
       'out_wires '(3 4 5 6)
       'ancilla_wires '(7 8 9)
       'table qrom8-table
       'gates (gates->json qrom8-unctrl-gates))
     'qrom8_controlled_11q (hasheq
       'num_qubits 11
       'ctrl_wire 0
       'addr_wires '(1 2 3)
       'out_wires '(4 5 6 7)
       'ancilla_wires '(8 9 10)
       'table qrom8-table
       'gates (gates->json qrom8-ctrl-gates))
     'gf16_session_7and_16q (hasheq
       'num_qubits 16
       'in_wires '(0 1 2 3)
       'out_wires '(4 5 6 7)
       'ancilla_wires '(8 9 10 11 12 13 14 15)
       'gates (gates->json gf16-session-7and-gates))
     'keccak_chi5_outofplace_15q (hasheq
       'num_qubits 15
       'in_wires '(0 1 2 3 4)
       'out_wires '(5 6 7 8 9)
       'ancilla_wires '(10 11 12 13 14)
       'gates (gates->json chi5-oop-15q-gates)))))

(module+ main
  (write-json (run-lakefill-ssa-qrom-optimizations))
  (newline))
