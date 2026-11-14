#lang typed/racket/base

(require racket/match
         racket/list
         racket/math
         "sc2-types.rkt"
         "sc2-bayesian.rkt"
         "sc2-pathing.rkt")

(provide
 (struct-out perception-grid)
 (struct-out choke-point)
 (struct-out unit-entry)
 (struct-out combat-measure)
 (struct-out huet-zipper)
 DEFAULT-CHOKES
 make-perception-grid
 lakefill-choke-decomposition
 fow-ghost-step-diffusion!
 best-retreat-sector
 perception-grid-ingest-frame!
 perception-grid-query-box
 perception-grid-get-choke-zipper
 perception-grid-snapshot-history
 perception-grid-history->list
 morton-encode-2d
 morton-decode-2d
 make-zipper
 zipper-focus
 zipper-index
 zipper-move-left
 zipper-move-right
 zipper-move-to-index
 zipper-update
 zipper-checkpoint
 zipper-rollback
 ft-empty
 ft-measure
 ft-from-list
 ft-to-list
 ft-append
 split-by-dps)

;; =============================================================================
;; Layer 1: Typed Functional Perception Grid (Crit-Bit, Finger Tree, Braun, SBRAL)
;; Zero dependency on `okasaki-sc.rkt`; built cleanly over `sc2-types`,
;; `sc2-bayesian`, and `sc2-pathing`.
;; =============================================================================

;; -----------------------------------------------------------------------------
;; Morton-Keyed Crit-Bit Trie
;; -----------------------------------------------------------------------------

(struct cb-leaf ([key : Nonnegative-Integer] [val : Any]) #:transparent)
(struct cb-branch ([prefix : Nonnegative-Integer]
                   [mask : Nonnegative-Integer]
                   [left : (U False cb-leaf cb-branch)]
                   [right : (U False cb-leaf cb-branch)])
  #:transparent)

(define-type CritBit (U False cb-leaf cb-branch))

(: critbit-empty CritBit)
(define critbit-empty #f)

(: highest-bit-mask (-> Nonnegative-Integer Nonnegative-Integer))
(define (highest-bit-mask x)
  (if (zero? x)
      0
      (max 0 (arithmetic-shift 1 (max 0 (sub1 (integer-length x)))))))

(: crit-bit-mask (-> Nonnegative-Integer Nonnegative-Integer Nonnegative-Integer))
(define (crit-bit-mask k1 k2)
  (highest-bit-mask (max 0 (bitwise-xor k1 k2))))

(: zero-bit? (-> Nonnegative-Integer Nonnegative-Integer Boolean))
(define (zero-bit? key mask)
  (zero? (bitwise-and key mask)))

(: mask-prefix (-> Nonnegative-Integer Nonnegative-Integer Nonnegative-Integer))
(define (mask-prefix key mask)
  (max 0 (bitwise-and key (bitwise-not (sub1 (arithmetic-shift mask 1))))))

(: match-prefix? (-> Nonnegative-Integer Nonnegative-Integer Nonnegative-Integer Boolean))
(define (match-prefix? key prefix mask)
  (= (mask-prefix key mask) prefix))

(: critbit-insert (-> CritBit Nonnegative-Integer Any CritBit))
(define (critbit-insert t key val)
  (match t
    [#f (cb-leaf key val)]
    [(cb-leaf k _v)
     (if (= k key)
         (cb-leaf key val)
         (let* ([m : Nonnegative-Integer (crit-bit-mask key k)]
                [p : Nonnegative-Integer (mask-prefix key m)]
                [new-leaf : cb-leaf (cb-leaf key val)])
           (if (zero-bit? key m)
               (cb-branch p m new-leaf t)
               (cb-branch p m t new-leaf))))]
    [(cb-branch p m l r)
     (cond
       [(match-prefix? key p m)
        (if (zero-bit? key m)
            (cb-branch p m (critbit-insert l key val) r)
            (cb-branch p m l (critbit-insert r key val)))]
       [else
        (let* ([new-m : Nonnegative-Integer (crit-bit-mask key p)]
               [new-p : Nonnegative-Integer (mask-prefix key new-m)]
               [new-leaf : cb-leaf (cb-leaf key val)])
          (if (zero-bit? key new-m)
              (cb-branch new-p new-m new-leaf t)
              (cb-branch new-p new-m t new-leaf)))])]))

(: critbit-range-2d (-> CritBit Integer Integer Integer Integer (Listof Any)))
(define (critbit-range-2d t x-min y-min x-max y-max)
  (define m-min : Nonnegative-Integer (morton-encode-2d (max 0 x-min) (max 0 y-min)))
  (define m-max : Nonnegative-Integer (morton-encode-2d (max 0 x-max) (max 0 y-max)))
  (let loop : (Listof Any) ([node : CritBit t] [acc : (Listof Any) '()])
    (match node
      [#f acc]
      [(cb-leaf k v)
       (if (and (>= k m-min) (<= k m-max))
           (let-values ([(ux uy) (morton-decode-2d k)])
             (if (and (>= ux x-min) (<= ux x-max)
                      (>= uy y-min) (<= uy y-max))
                 (cons v acc)
                 acc))
           acc)]
      [(cb-branch p m l r)
       (define sub-min : Integer p)
       (define sub-max : Integer (+ p (sub1 (arithmetic-shift m 1))))
       (if (or (< sub-max m-min) (> sub-min m-max))
           acc
           (loop r (loop l acc)))])))

;; -----------------------------------------------------------------------------
;; Typed 2-3 Monoidal Finger Tree (Squad DPS & Split)
;; -----------------------------------------------------------------------------

(struct unit-entry
  ([id : Integer]
   [type : Symbol]
   [dps : Real]
   [hp : Real]
   [cost : Real]
   [x : Real]
   [y : Real])
  #:transparent)

(struct combat-measure
  ([count : Nonnegative-Integer]
   [dps : Real]
   [hp : Real]
   [cost : Real])
  #:transparent)

(struct ft-empty-node () #:transparent)
(struct ft-node2 ([a : (U unit-entry ft-node2 ft-node3)]
                  [b : (U unit-entry ft-node2 ft-node3)]
                  [m : combat-measure])
  #:transparent)
(struct ft-node3 ([a : (U unit-entry ft-node2 ft-node3)]
                  [b : (U unit-entry ft-node2 ft-node3)]
                  [c : (U unit-entry ft-node2 ft-node3)]
                  [m : combat-measure])
  #:transparent)
(define-type FTElem (U unit-entry ft-node2 ft-node3))
(struct ft-single ([val : FTElem] [m : combat-measure]) #:transparent)
(struct ft-deep ([left : (Listof FTElem)]
                 [mid : (U ft-empty-node ft-single ft-deep)]
                 [right : (Listof FTElem)]
                 [m : combat-measure])
  #:transparent)
(define-type FingerTree (U ft-empty-node ft-single ft-deep))

(: measure-zero combat-measure)
(define measure-zero (combat-measure 0 0 0 0))

(: measure-plus (-> combat-measure combat-measure combat-measure))
(define (measure-plus m1 m2)
  (combat-measure
   (+ (combat-measure-count m1) (combat-measure-count m2))
   (+ (combat-measure-dps m1) (combat-measure-dps m2))
   (+ (combat-measure-hp m1) (combat-measure-hp m2))
   (+ (combat-measure-cost m1) (combat-measure-cost m2))))

(: elem-measure (-> FTElem combat-measure))
(define (elem-measure x)
  (cond
    [(ft-node2? x) (ft-node2-m x)]
    [(ft-node3? x) (ft-node3-m x)]
    [else
     (combat-measure 1
                     (unit-entry-dps x)
                     (unit-entry-hp x)
                     (unit-entry-cost x))]))

(: digit-measure (-> (Listof FTElem) combat-measure))
(define (digit-measure d)
  (for/fold ([acc : combat-measure measure-zero])
            ([x : FTElem (in-list d)])
    (measure-plus acc (elem-measure x))))

(: ft-empty FingerTree)
(define ft-empty (ft-empty-node))

(: ft-is-empty? (-> FingerTree Boolean))
(define (ft-is-empty? t) (ft-empty-node? t))

(: ft-measure (-> FingerTree combat-measure))
(define (ft-measure t)
  (match t
    [(ft-empty-node) measure-zero]
    [(ft-single _ m) m]
    [(ft-deep _ _ _ m) m]))

(: make-ft-single (-> FTElem ft-single))
(define (make-ft-single x)
  (ft-single x (elem-measure x)))

(: make-ft-node2 (-> FTElem FTElem ft-node2))
(define (make-ft-node2 a b)
  (ft-node2 a b (measure-plus (elem-measure a) (elem-measure b))))

(: make-ft-node3 (-> FTElem FTElem FTElem ft-node3))
(define (make-ft-node3 a b c)
  (ft-node3 a b c (measure-plus (elem-measure a)
                                (measure-plus (elem-measure b) (elem-measure c)))))

(: make-ft-deep (-> (Listof FTElem) FingerTree (Listof FTElem) ft-deep))
(define (make-ft-deep left mid right)
  (ft-deep left mid right
           (measure-plus (digit-measure left)
                         (measure-plus (ft-measure mid)
                                       (digit-measure right)))))

(: ft-snoc (-> FingerTree FTElem FingerTree))
(define (ft-snoc t a)
  (match t
    [(ft-empty-node) (make-ft-single a)]
    [(ft-single b _) (make-ft-deep (list b) ft-empty (list a))]
    [(ft-deep left mid (list b c d e) _)
     (make-ft-deep left (ft-snoc mid (make-ft-node3 b c d)) (list e a))]
    [(ft-deep left mid right _)
     (make-ft-deep left mid (append right (list a)))]))

(: node->digit (-> FTElem (Listof FTElem)))
(define (node->digit nd)
  (match nd
    [(ft-node2 a b _) (list a b)]
    [(ft-node3 a b c _) (list a b c)]
    [else (list nd)]))

(: ft-from-list (-> (Listof FTElem) FingerTree))
(define (ft-from-list xs)
  (for/fold ([acc : FingerTree ft-empty])
            ([x : FTElem (in-list xs)])
    (ft-snoc acc x)))

(: expand-elem (-> FTElem (Listof FTElem)))
(define (expand-elem x)
  (match x
    [(ft-node2 a b _) (append (expand-elem a) (expand-elem b))]
    [(ft-node3 a b c _) (append (expand-elem a) (expand-elem b) (expand-elem c))]
    [else (list x)]))

(: ft-to-list (-> FingerTree (Listof FTElem)))
(define (ft-to-list t)
  (match t
    [(ft-empty-node) '()]
    [(ft-single a _) (expand-elem a)]
    [(ft-deep left mid right _)
     (append (append-map expand-elem left)
             (ft-to-list mid)
             (append-map expand-elem right))]))

(: ft-append (-> FingerTree FingerTree FingerTree))
(define (ft-append t1 t2)
  (cond
    [(ft-is-empty? t1) t2]
    [(ft-is-empty? t2) t1]
    [else (for/fold ([acc : FingerTree t1])
                    ([x : FTElem (in-list (ft-to-list t2))])
            (ft-snoc acc x))]))

(: ft-head (-> FingerTree FTElem))
(define (ft-head t)
  (match t
    [(ft-empty-node) (error 'ft-head "empty finger tree")]
    [(ft-single a _) a]
    [(ft-deep (cons a _) _ _ _) a]
    [(ft-deep '() mid right _)
     (if (ft-is-empty? mid)
         (car right)
         (ft-head mid))]))

(: ft-tail (-> FingerTree FingerTree))
(define (ft-tail t)
  (match t
    [(ft-empty-node) (error 'ft-tail "empty finger tree")]
    [(ft-single _ _) ft-empty]
    [(ft-deep (cons _ rest) mid right _)
     (deep-left rest mid right)]
    [(ft-deep '() mid right _)
     (deep-left '() mid right)]))

(: ft-last (-> FingerTree FTElem))
(define (ft-last t)
  (match t
    [(ft-empty-node) (error 'ft-last "empty finger tree")]
    [(ft-single a _) a]
    [(ft-deep _ _ (and right (cons _ _)) _) (last right)]
    [(ft-deep left mid '() _)
     (if (ft-is-empty? mid)
         (last left)
         (ft-last mid))]))

(: drop-last-elem (-> (Listof FTElem) (Listof FTElem)))
(define (drop-last-elem xs)
  (match xs
    ['() '()]
    [(list _) '()]
    [(cons h t) (cons h (drop-last-elem t))]))

(: ft-init (-> FingerTree FingerTree))
(define (ft-init t)
  (match t
    [(ft-empty-node) (error 'ft-init "empty finger tree")]
    [(ft-single _ _) ft-empty]
    [(ft-deep left mid right _)
     (deep-right left mid (drop-last-elem right))]))

(: deep-left (-> (Listof FTElem) FingerTree (Listof FTElem) FingerTree))
(define (deep-left left mid right)
  (if (not (null? left))
      (make-ft-deep left mid right)
      (if (ft-is-empty? mid)
          (ft-from-list right)
          (make-ft-deep (node->digit (ft-head mid))
                        (ft-tail mid)
                        right))))

(: deep-right (-> (Listof FTElem) FingerTree (Listof FTElem) FingerTree))
(define (deep-right left mid right)
  (if (not (null? right))
      (make-ft-deep left mid right)
      (if (ft-is-empty? mid)
          (ft-from-list left)
          (make-ft-deep left
                        (ft-init mid)
                        (node->digit (ft-last mid))))))

(: split-digit (-> (-> combat-measure Boolean) combat-measure (Listof FTElem)
                   (Values (Listof FTElem) FTElem (Listof FTElem))))
(define (split-digit pred acc xs)
  (let loop : (Values (Listof FTElem) FTElem (Listof FTElem))
       ([rem : (Listof FTElem) xs]
        [left : (Listof FTElem) '()]
        [cur : combat-measure acc])
    (match rem
      ['() (error 'split-digit "empty digit")]
      [(list x) (values (reverse left) x '())]
      [(cons x rest)
       (define next-acc : combat-measure (measure-plus cur (elem-measure x)))
       (if (pred next-acc)
           (values (reverse left) x rest)
           (loop rest (cons x left) next-acc))])))

(: split-tree (-> (-> combat-measure Boolean) combat-measure FingerTree
                  (Values FingerTree FTElem FingerTree)))
(define (split-tree pred acc t)
  (match t
    [(ft-empty-node) (error 'split-tree "empty finger tree")]
    [(ft-single x _)
     (values ft-empty x ft-empty)]
    [(ft-deep left mid right _)
     (define v-left : combat-measure (measure-plus acc (digit-measure left)))
     (cond
       [(pred v-left)
        (define-values (l x r) (split-digit pred acc left))
        (values (ft-from-list l) x (deep-left r mid right))]
       [else
        (define v-mid : combat-measure (measure-plus v-left (ft-measure mid)))
        (cond
          [(pred v-mid)
           (define-values (ml xs mr) (split-tree pred v-left mid))
           (define v-ml : combat-measure (measure-plus v-left (ft-measure ml)))
           (define-values (l x r) (split-digit pred v-ml (node->digit xs)))
           (values (deep-right left ml l) x (deep-left r mr right))]
          [else
           (define-values (l x r) (split-digit pred v-mid right))
           (values (deep-right left mid l) x (ft-from-list r))])])]))

(: split-by-dps (-> FingerTree Real (Values FingerTree FingerTree)))
(define (split-by-dps t target-dps)
  (cond
    [(ft-is-empty? t) (values ft-empty ft-empty)]
    [(<= target-dps 0) (values ft-empty t)]
    [(< (combat-measure-dps (ft-measure t)) target-dps)
     (values t ft-empty)]
    [else
     (define-values (l x r)
       (split-tree (lambda ([m : combat-measure]) (>= (combat-measure-dps m) target-dps))
                   measure-zero
                   t))
     (values (ft-snoc l x) r)]))

;; -----------------------------------------------------------------------------
;; Functional Braun Priority Queue (Threat Queue)
;; -----------------------------------------------------------------------------

(struct braun-node ([key : Real]
                    [val : Any]
                    [left : (U False braun-node)]
                    [right : (U False braun-node)])
  #:transparent)

(define-type BraunPQ (U False braun-node))

(: braun-empty BraunPQ)
(define braun-empty #f)

(: braun-insert (-> BraunPQ Real Any BraunPQ))
(define (braun-insert t key val)
  (match t
    [#f (braun-node key val #f #f)]
    [(braun-node k v l r)
     (if (< key k)
         (braun-node key val (braun-insert r k v) l)
         (braun-node k v (braun-insert r key val) l))]))

;; -----------------------------------------------------------------------------
;; Skew-Binary Random-Access List (O(1) Frame History Snapshots)
;; -----------------------------------------------------------------------------

(struct sbral-leaf ([val : Any]) #:transparent)
(struct sbral-node ([val : Any]
                    [left : (U sbral-leaf sbral-node)]
                    [right : (U sbral-leaf sbral-node)])
  #:transparent)
(define-type SbralTree (U sbral-leaf sbral-node))
(struct sbral-root ([trees : (Listof (Pairof Positive-Integer SbralTree))]
                    [len : Nonnegative-Integer])
  #:transparent)

(: sbral-empty sbral-root)
(define sbral-empty (sbral-root '() 0))

(: sbral-cons (-> Any sbral-root sbral-root))
(define (sbral-cons x s)
  (define ts (sbral-root-trees s))
  (define new-ts : (Listof (Pairof Positive-Integer SbralTree))
    (match ts
      [(list* (cons w1 t1) (cons w2 t2) rest)
       #:when (= w1 w2)
       (cons (cons (+ 1 w1 w2) (sbral-node x t1 t2)) rest)]
      [_
       (cons (cons 1 (sbral-leaf x)) ts)]))
  (sbral-root new-ts (add1 (sbral-root-len s))))

(: sbral-tree->list (-> SbralTree (Listof Any)))
(define (sbral-tree->list tr)
  (match tr
    [(sbral-leaf v) (list v)]
    [(sbral-node v l r)
     (cons v (append (sbral-tree->list l) (sbral-tree->list r)))]))

(: sbral->list (-> sbral-root (Listof Any)))
(define (sbral->list s)
  (append-map (lambda ([wt : (Pairof Positive-Integer SbralTree)])
                (sbral-tree->list (cdr wt)))
              (sbral-root-trees s)))

;; -----------------------------------------------------------------------------
;; Unified Perception Grid State & Operations
;; -----------------------------------------------------------------------------

(struct perception-grid
  ([ally-trie : CritBit]
   [enemy-trie : CritBit]
   [squad-finger-tree : FingerTree]
   [choke-zipper : huet-zipper]
   [threat-braun-pq : BraunPQ]
   [frame-history-sbral : sbral-root]
   [fow-belief-grid : (Vectorof Float)])
  #:mutable
  #:transparent)

(: make-perception-grid (->* () ((Listof Any)) perception-grid))
(define (make-perception-grid [chokes DEFAULT-CHOKES])
  (perception-grid
   critbit-empty
   critbit-empty
   ft-empty
   (make-zipper (if (null? chokes) DEFAULT-CHOKES chokes))
   braun-empty
   sbral-empty
   (make-vector 64 (/ 1.0 64.0))))

(: safe-belief-vec (-> Any (Vectorof Float)))
(define (safe-belief-vec pg-or-belief)
  (cond
    [(perception-grid? pg-or-belief) (perception-grid-fow-belief-grid pg-or-belief)]
    [(vector? pg-or-belief)
     (define n : Nonnegative-Integer (vector-length pg-or-belief))
     (define out : (Vectorof Float) (make-vector n (/ 1.0 (max 1.0 (->float n)))))
     (for ([i : Nonnegative-Integer (in-range n)])
       (define v (vector-ref pg-or-belief i))
       (when (and (real? v) (finite-real? v))
         (vector-set! out i (->float v))))
     out]
    [else (make-vector 64 (/ 1.0 64.0))]))

(: best-retreat-sector
   (->* (Any) (Real (Listof Any) #:ally-sectors (U False (Listof Any))) Nonnegative-Integer))
(define (best-retreat-sector pg-or-belief [current-sector 9] [ally-sectors-pos '()] #:ally-sectors [ally-sectors-kw #f])
  (define ally-sectors : (Listof Any) (or ally-sectors-kw ally-sectors-pos))
  (define belief-vec : (Vectorof Float) (safe-belief-vec pg-or-belief))
  (define n : Nonnegative-Integer (vector-length belief-vec))
  (cond
    [(zero? n) 0]
    [else
     (define cur-sec : Nonnegative-Integer
       (max 0 (min (sub1 n) (exact-round (safe-finite-real current-sector 9.0)))))
     (define cur-r : Integer (quotient cur-sec 8))
     (define cur-c : Integer (modulo cur-sec 8))
     (define-values (best-s _best-score)
       (for/fold ([bs : Nonnegative-Integer cur-sec] [bsc : Float +inf.0])
                 ([s : Nonnegative-Integer (in-range n)])
         (define r : Integer (quotient s 8))
         (define c : Integer (modulo s 8))
         (define self-threat : Float (vector-ref belief-vec s))
         (define nbr-indices : (Listof Nonnegative-Integer)
           (for/fold ([acc : (Listof Nonnegative-Integer) '()])
                     ([cand : Integer (in-list (list (if (> r 0) (- s 8) -1)
                                                     (if (< r 7) (+ s 8) -1)
                                                     (if (> c 0) (sub1 s) -1)
                                                     (if (< c 7) (add1 s) -1)))])
             (if (and (>= cand 0) (< cand n))
                 (cons cand acc)
                 acc)))
         (define nbr-threat : Float
           (if (null? nbr-indices)
               self-threat
               (/ (for/fold ([acc : Float 0.0])
                            ([ni : Nonnegative-Integer (in-list nbr-indices)])
                    (+ acc (vector-ref belief-vec ni)))
                  (->float (length nbr-indices)))))
         (define dr : Float (->float (- r cur-r)))
         (define dc : Float (->float (- c cur-c)))
         (define grid-dist : Float (->float (sqrt (max 0.0 (+ (* dr dr) (* dc dc))))))
         (define corner-penalty : Float
           (if (and (or (= r 0) (= r 7)) (or (= c 0) (= c 7)) (> grid-dist 1.5))
               0.015
               0.0))
         (define ally-bonus : Float (if (memv s ally-sectors) -0.02 0.0))
         (define score : Float
           (+ (* 0.70 self-threat)
              (* 0.30 nbr-threat)
              (* 0.004 grid-dist)
              corner-penalty
              ally-bonus))
         (if (< score bsc)
             (values s score)
             (values bs bsc))))
     best-s]))

(: extract-unit-num (-> Any Symbol Real Real))
(define (extract-unit-num u key default)
  (cond
    [(hash? u)
     (define v (hash-ref u key (lambda () default)))
     (if (and (real? v) (finite-real? v)) v default)]
    [else default]))

(: extract-unit-int (-> Any Symbol Integer Integer))
(define (extract-unit-int u key default)
  (cond
    [(hash? u)
     (define v (hash-ref u key (lambda () default)))
     (if (exact-integer? v) v (safe-exact-int v default))]
    [else default]))

(: perception-grid-ingest-frame!
   (->* (perception-grid Integer (Listof Any) (Listof Any)) ((Listof Any)) perception-grid))
(define (perception-grid-ingest-frame! pg frame-num ally-units enemy-units [visible-sectors '()])
  (define-values (new-ally-trie _)
    (for/fold ([t : CritBit critbit-empty] [idx : Nonnegative-Integer 0])
              ([u : Any (in-list ally-units)])
      (define ux : Integer
        (cond
          [(unit-entry? u) (exact-round (->float (unit-entry-x u)))]
          [else (exact-round (safe-finite-real (extract-unit-num u 'x 32) 32.0))]))
      (define uy : Integer
        (cond
          [(unit-entry? u) (exact-round (->float (unit-entry-y u)))]
          [else (exact-round (safe-finite-real (extract-unit-num u 'y 32) 32.0))]))
      (define key : Nonnegative-Integer
        (morton-encode-2d (+ ux (modulo idx 3)) (+ uy (quotient idx 3))))
      (values (critbit-insert t key u) (add1 idx))))

  (define-values (new-enemy-trie _eidx)
    (for/fold ([t : CritBit critbit-empty] [idx : Nonnegative-Integer 0])
              ([u : Any (in-list enemy-units)])
      (define ux : Integer
        (cond
          [(unit-entry? u) (exact-round (->float (unit-entry-x u)))]
          [else (exact-round (safe-finite-real (extract-unit-num u 'x 160) 160.0))]))
      (define uy : Integer
        (cond
          [(unit-entry? u) (exact-round (->float (unit-entry-y u)))]
          [else (exact-round (safe-finite-real (extract-unit-num u 'y 160) 160.0))]))
      (define key : Nonnegative-Integer
        (morton-encode-2d (+ ux (modulo idx 3)) (+ uy (quotient idx 3))))
      (values (critbit-insert t key u) (add1 idx))))

  (define new-ft : FingerTree
    (for/fold ([ft : FingerTree ft-empty])
              ([u : Any (in-list ally-units)])
      (define utype : Symbol
        (if (unit-entry? u) (unit-entry-type u) (unit-type-sym u)))
      (cond
        [(memq utype '(drone probe scv overlord larva egg)) ft]
        [(unit-entry? u) (ft-snoc ft u)]
        [(hash? u)
         (ft-snoc ft
                  (unit-entry (extract-unit-int u 'id 0)
                              (let ([rt (hash-ref u 'type (lambda () 'marine))])
                                (if (symbol? rt) rt utype))
                              (extract-unit-num u 'dps 12)
                              (extract-unit-num u 'hp 45)
                              (extract-unit-num u 'cost 50)
                              (extract-unit-num u 'x 32)
                              (extract-unit-num u 'y 32)))]
        [else ft])))

  (define new-pq : BraunPQ
    (for/fold ([pq : BraunPQ braun-empty])
              ([e : Any (in-list enemy-units)])
      (define dps : Real
        (if (unit-entry? e) (unit-entry-dps e) (extract-unit-num e 'dps 10)))
      (define hp : Real
        (if (unit-entry? e) (unit-entry-hp e) (extract-unit-num e 'hp 40)))
      (define threat : Real (- (+ (* 3 dps) (quotient (max 0 (exact-round (->float hp))) 5))))
      (braun-insert pq threat e)))

  (set-perception-grid-ally-trie! pg new-ally-trie)
  (set-perception-grid-enemy-trie! pg new-enemy-trie)
  (set-perception-grid-squad-finger-tree! pg new-ft)
  (set-perception-grid-threat-braun-pq! pg new-pq)
  (fow-ghost-step-diffusion! (perception-grid-fow-belief-grid pg) visible-sectors)
  (set-perception-grid-frame-history-sbral!
   pg
   (sbral-cons (hash 'frame frame-num
                     'ally-count (length ally-units)
                     'enemy-count (length enemy-units)
                     'ally-dps (combat-measure-dps (ft-measure new-ft)))
               (perception-grid-frame-history-sbral pg)))
  pg)

(: perception-grid-query-box (-> perception-grid Symbol Real Real Real Real (Listof Any)))
(define (perception-grid-query-box pg side x-min y-min x-max y-max)
  (define trie : CritBit
    (if (eq? side 'ally)
        (perception-grid-ally-trie pg)
        (perception-grid-enemy-trie pg)))
  (critbit-range-2d trie
                    (exact-floor (->float x-min))
                    (exact-floor (->float y-min))
                    (exact-ceiling (->float x-max))
                    (exact-ceiling (->float y-max))))

(: perception-grid-get-choke-zipper (-> perception-grid huet-zipper))
(define (perception-grid-get-choke-zipper pg)
  (perception-grid-choke-zipper pg))

(: perception-grid-snapshot-history (-> perception-grid sbral-root))
(define (perception-grid-snapshot-history pg)
  (perception-grid-frame-history-sbral pg))

(: perception-grid-history->list (-> sbral-root (Listof Any)))
(define (perception-grid-history->list hist)
  (sbral->list hist))
