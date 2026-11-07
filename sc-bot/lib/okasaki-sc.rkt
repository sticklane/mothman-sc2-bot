#lang racket/base

(require racket/match
         racket/list
         racket/math)

(provide
 ;; 1.1 Okasaki-Gill Canonical Crit-Bit Trie + Morton 2D Z-Order Curve
 morton-encode-2d
 morton-decode-2d
 critbit-empty
 critbit-empty?
 (struct-out cb-leaf)
 (struct-out cb-branch)
 critbit-insert
 critbit-lookup
 critbit-delete
 critbit-fold
 critbit->alist
 critbit-size
 critbit-range-2d

 ;; 1.2 Hinze-Paterson 2-3 Monoidal Finger Tree
 (struct-out unit-entry)
 (struct-out combat-measure)
 measure-zero
 measure-plus
 unit->measure
 ft-empty
 ft-is-empty?
 ft-measure
 ft-cons
 ft-snoc
 ft-head
 ft-tail
 ft-last
 ft-init
 ft-append
 ft-to-list
 ft-from-list
 split-by-dps

 ;; 1.3 Huet Focus Zipper with O(1) Speculative Rollback
 (struct-out huet-zipper)
 make-zipper
 zipper-focus
 zipper-index
 zipper-move-left
 zipper-move-right
 zipper-move-to-index
 zipper-update
 zipper-checkpoint
 zipper-rollback

 ;; 1.4 Pointerless/Functional Braun Tree Priority Queue
 (struct-out braun-node)
 braun-empty
 braun-empty?
 braun-insert
 braun-min
 braun-delete-min
 braun-diff
 braun-size
 fold-braun
 braun->sorted-list

 ;; 1.5 Skew-Binary Random-Access List (O(1) Frame Snapshots)
 (struct-out sbral-root)
 sbral-empty
 sbral-empty?
 sbral-cons
 sbral-head
 sbral-tail
 sbral-ref
 sbral-set
 sbral-length
 sbral->list)

;; =============================================================================
;; 1.1 Okasaki-Gill Canonical Crit-Bit Trie + Morton 2D Z-Order Curve
;; =============================================================================

(define (part1by1 n)
  (let* ([x (bitwise-and n #xFFFF)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 8)) #x00FF00FF)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 4)) #x0F0F0F0F)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 2)) #x33333333)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 1)) #x55555555)])
    x))

(define (compact1by1 n)
  (let* ([x (bitwise-and n #x55555555)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -1)) #x33333333)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -2)) #x0F0F0F0F)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -4)) #x00FF00FF)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -8)) #x0000FFFF)])
    x))

(define (morton-encode-2d x y)
  (bitwise-ior (part1by1 x)
               (arithmetic-shift (part1by1 y) 1)))

(define (morton-decode-2d code)
  (values (compact1by1 code)
          (compact1by1 (arithmetic-shift code -1))))

(struct cb-leaf (key val) #:transparent)
(struct cb-branch (prefix mask left right) #:transparent)

(define critbit-empty #f)
(define (critbit-empty? t) (not t))

;; Highest differing bit mask (canonical MSB crit-bit)
(define (highest-bit-mask x)
  (if (zero? x)
      0
      (arithmetic-shift 1 (sub1 (integer-length x)))))

(define (crit-bit-mask k1 k2)
  (highest-bit-mask (bitwise-xor k1 k2)))

(define (zero-bit? key mask)
  (zero? (bitwise-and key mask)))

(define (mask-prefix key mask)
  (bitwise-and key (bitwise-not (sub1 (arithmetic-shift mask 1)))))

(define (match-prefix? key prefix mask)
  (= (mask-prefix key mask) prefix))

(define (critbit-insert t key val)
  (match t
    [#f (cb-leaf key val)]
    [(cb-leaf k v)
     (if (= k key)
         (cb-leaf key val)
         (let* ([m (crit-bit-mask key k)]
                [p (mask-prefix key m)]
                [new-leaf (cb-leaf key val)])
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
        (let* ([new-m (crit-bit-mask key p)]
               [new-p (mask-prefix key new-m)]
               [new-leaf (cb-leaf key val)])
          (if (zero-bit? key new-m)
              (cb-branch new-p new-m new-leaf t)
              (cb-branch new-p new-m t new-leaf)))])]))

(define (critbit-lookup t key [default #f])
  (match t
    [#f default]
    [(cb-leaf k v) (if (= k key) v default)]
    [(cb-branch p m l r)
     (if (not (match-prefix? key p m))
         default
         (if (zero-bit? key m)
             (critbit-lookup l key default)
             (critbit-lookup r key default)))]))

(define (critbit-delete t key)
  (match t
    [#f #f]
    [(cb-leaf k _) (if (= k key) #f t)]
    [(cb-branch p m l r)
     (if (not (match-prefix? key p m))
         t
         (if (zero-bit? key m)
             (let ([l2 (critbit-delete l key)])
               (if l2 (cb-branch p m l2 r) r))
             (let ([r2 (critbit-delete r key)])
               (if r2 (cb-branch p m l r2) l))))]))

(define (critbit-fold f init t)
  (match t
    [#f init]
    [(cb-leaf k v) (f k v init)]
    [(cb-branch _ _ l r)
     (critbit-fold f (critbit-fold f init l) r)]))

(define (critbit->alist t)
  (reverse
   (critbit-fold (lambda (k v acc) (cons (cons k v) acc)) '() t)))

(define (critbit-size t)
  (critbit-fold (lambda (_k _v acc) (add1 acc)) 0 t))

;; 2D Range query over Morton-encoded keys with subtree prefix pruning
(define (critbit-range-2d t x-min y-min x-max y-max)
  (define m-min (morton-encode-2d (max 0 x-min) (max 0 y-min)))
  (define m-max (morton-encode-2d (max 0 x-max) (max 0 y-max)))
  (let loop ([node t] [acc '()])
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
       ;; Subtree key range is [p, p + 2*m - 1]
       (define sub-min p)
       (define sub-max (+ p (sub1 (arithmetic-shift m 1))))
       (if (or (< sub-max m-min) (> sub-min m-max))
           acc
           (loop r (loop l acc)))])))

;; =============================================================================
;; 1.2 Hinze-Paterson 2-3 Monoidal Finger Tree
;; =============================================================================

(struct unit-entry (id type dps hp cost x y) #:transparent)
(struct combat-measure (count dps hp cost) #:transparent)

(define measure-zero (combat-measure 0 0 0 0))

(define (measure-plus m1 m2)
  (combat-measure
   (+ (combat-measure-count m1) (combat-measure-count m2))
   (+ (combat-measure-dps m1) (combat-measure-dps m2))
   (+ (combat-measure-hp m1) (combat-measure-hp m2))
   (+ (combat-measure-cost m1) (combat-measure-cost m2))))

(define (unit->measure u)
  (cond
    [(unit-entry? u)
     (combat-measure 1
                     (unit-entry-dps u)
                     (unit-entry-hp u)
                     (unit-entry-cost u))]
    [(hash? u)
     (combat-measure 1
                     (hash-ref u 'dps 10)
                     (hash-ref u 'hp 40)
                     (hash-ref u 'cost 50))]
    [else (combat-measure 1 10 40 50)]))

(struct ft-empty-node () #:transparent)
(struct ft-single (val m) #:transparent)
(struct ft-deep (left mid right m) #:transparent)
(struct ft-node2 (a b m) #:transparent)
(struct ft-node3 (a b c m) #:transparent)

(define ft-empty (ft-empty-node))
(define (ft-is-empty? t) (ft-empty-node? t))

(define (elem-measure x)
  (cond
    [(ft-node2? x) (ft-node2-m x)]
    [(ft-node3? x) (ft-node3-m x)]
    [(combat-measure? x) x]
    [else (unit->measure x)]))

(define (digit-measure d)
  (foldl (lambda (x acc) (measure-plus acc (elem-measure x)))
         measure-zero
         d))

(define (ft-measure t)
  (match t
    [(ft-empty-node) measure-zero]
    [(ft-single _ m) m]
    [(ft-deep _ _ _ m) m]))

(define (make-ft-single x)
  (ft-single x (elem-measure x)))

(define (make-ft-node2 a b)
  (ft-node2 a b (measure-plus (elem-measure a) (elem-measure b))))

(define (make-ft-node3 a b c)
  (ft-node3 a b c (measure-plus (elem-measure a)
                                (measure-plus (elem-measure b) (elem-measure c)))))

(define (make-ft-deep left mid right)
  (ft-deep left mid right
           (measure-plus (digit-measure left)
                         (measure-plus (ft-measure mid)
                                       (digit-measure right)))))

(define (ft-cons a t)
  (match t
    [(ft-empty-node) (make-ft-single a)]
    [(ft-single b _) (make-ft-deep (list a) ft-empty (list b))]
    [(ft-deep (list b c d e) mid right _)
     (make-ft-deep (list a b) (ft-cons (make-ft-node3 c d e) mid) right)]
    [(ft-deep left mid right _)
     (make-ft-deep (cons a left) mid right)]))

(define (ft-snoc t a)
  (match t
    [(ft-empty-node) (make-ft-single a)]
    [(ft-single b _) (make-ft-deep (list b) ft-empty (list a))]
    [(ft-deep left mid (list b c d e) _)
     (make-ft-deep left (ft-snoc mid (make-ft-node3 b c d)) (list e a))]
    [(ft-deep left mid right _)
     (make-ft-deep left mid (append right (list a)))]))

(define (node->digit nd)
  (match nd
    [(ft-node2 a b _) (list a b)]
    [(ft-node3 a b c _) (list a b c)]))

(define (deep-left left mid right)
  (if (not (null? left))
      (make-ft-deep left mid right)
      (if (ft-is-empty? mid)
          (ft-from-list right)
          (make-ft-deep (node->digit (ft-head mid))
                        (ft-tail mid)
                        right))))

(define (deep-right left mid right)
  (if (not (null? right))
      (make-ft-deep left mid right)
      (if (ft-is-empty? mid)
          (ft-from-list left)
          (make-ft-deep left
                        (ft-init mid)
                        (node->digit (ft-last mid))))))

(define (ft-head t)
  (match t
    [(ft-empty-node) (error 'ft-head "empty finger tree")]
    [(ft-single a _) a]
    [(ft-deep (cons a _) _ _ _) a]))

(define (ft-tail t)
  (match t
    [(ft-empty-node) (error 'ft-tail "empty finger tree")]
    [(ft-single _ _) ft-empty]
    [(ft-deep (cons _ rest) mid right _)
     (deep-left rest mid right)]))

(define (ft-last t)
  (match t
    [(ft-empty-node) (error 'ft-last "empty finger tree")]
    [(ft-single a _) a]
    [(ft-deep _ _ right _) (last right)]))

(define (ft-init t)
  (match t
    [(ft-empty-node) (error 'ft-init "empty finger tree")]
    [(ft-single _ _) ft-empty]
    [(ft-deep left mid right _)
     (deep-right left mid (take right (sub1 (length right))))]))

(define (ft-from-list xs)
  (foldl (lambda (x acc) (ft-snoc acc x)) ft-empty xs))

(define (ft-to-list t)
  (let loop ([node t] [acc '()])
    (match node
      [(ft-empty-node) acc]
      [(ft-single a _) (append acc (expand-elem a))]
      [(ft-deep left mid right _)
       (append acc
               (append-map expand-elem left)
               (loop mid '())
               (append-map expand-elem right))])))

(define (expand-elem x)
  (match x
    [(ft-node2 a b _) (append (expand-elem a) (expand-elem b))]
    [(ft-node3 a b c _) (append (expand-elem a) (expand-elem b) (expand-elem c))]
    [else (list x)]))

(define (ft-append t1 t2)
  (cond
    [(ft-is-empty? t1) t2]
    [(ft-is-empty? t2) t1]
    [else (foldl (lambda (x acc) (ft-snoc acc x)) t1 (ft-to-list t2))]))

;; O(log N) Monoidal Split by DPS threshold
(define (split-digit pred acc xs)
  (let loop ([rem xs] [left '()] [cur acc])
    (match rem
      [(list x)
       (values (reverse left) x '())]
      [(cons x rest)
       (define next-acc (measure-plus cur (elem-measure x)))
       (if (pred next-acc)
           (values (reverse left) x rest)
           (loop rest (cons x left) next-acc))])))

(define (split-tree pred acc t)
  (match t
    [(ft-single x _)
     (values ft-empty x ft-empty)]
    [(ft-deep left mid right _)
     (define v-left (measure-plus acc (digit-measure left)))
     (cond
       [(pred v-left)
        (define-values (l x r) (split-digit pred acc left))
        (values (ft-from-list l) x (deep-left r mid right))]
       [else
        (define v-mid (measure-plus v-left (ft-measure mid)))
        (cond
          [(pred v-mid)
           (define-values (ml xs mr) (split-tree pred v-left mid))
           (define v-ml (measure-plus v-left (ft-measure ml)))
           (define-values (l x r) (split-digit pred v-ml (node->digit xs)))
           (values (deep-right left ml l) x (deep-left r mr right))]
          [else
           (define-values (l x r) (split-digit pred v-mid right))
           (values (deep-right left mid l) x (ft-from-list r))])])]))

;; Splits finger tree `t` at cumulative DPS >= `target-dps`
;; Returns `(values vanguard-tree reserve-tree)`
(define (split-by-dps t target-dps)
  (cond
    [(ft-is-empty? t) (values ft-empty ft-empty)]
    [(<= target-dps 0) (values ft-empty t)]
    [(< (combat-measure-dps (ft-measure t)) target-dps)
     (values t ft-empty)]
    [else
     (define-values (l x r)
       (split-tree (lambda (m) (>= (combat-measure-dps m) target-dps))
                   measure-zero
                   t))
     (values (ft-snoc l x) r)]))

;; =============================================================================
;; 1.3 Huet Focus Zipper with O(|b1 - b2|) Choke Switching & O(1) Rollback
;; =============================================================================

(struct huet-zipper (left focus right index checkpoint) #:transparent)

(define (make-zipper items)
  (match items
    ['() (error 'make-zipper "cannot create zipper over empty list")]
    [(cons h t) (huet-zipper '() h t 0 #f)]))

(define (zipper-focus z) (huet-zipper-focus z))
(define (zipper-index z) (huet-zipper-index z))

(define (zipper-move-left z)
  (match (huet-zipper-left z)
    ['() (error 'zipper-move-left "zipper at left boundary")]
    [(cons l ls)
     (huet-zipper ls l (cons (huet-zipper-focus z) (huet-zipper-right z))
                  (sub1 (huet-zipper-index z))
                  (huet-zipper-checkpoint z))]))

(define (zipper-move-right z)
  (match (huet-zipper-right z)
    ['() (error 'zipper-move-right "zipper at right boundary")]
    [(cons r rs)
     (huet-zipper (cons (huet-zipper-focus z) (huet-zipper-left z))
                  r rs
                  (add1 (huet-zipper-index z))
                  (huet-zipper-checkpoint z))]))

(define (zipper-move-to-index z target-idx)
  (let loop ([cur z])
    (define idx (huet-zipper-index cur))
    (cond
      [(= idx target-idx) cur]
      [(< idx target-idx) (loop (zipper-move-right cur))]
      [else               (loop (zipper-move-left cur))])))

(define (zipper-update z f)
  (huet-zipper (huet-zipper-left z)
               (f (huet-zipper-focus z))
               (huet-zipper-right z)
               (huet-zipper-index z)
               (huet-zipper-checkpoint z)))

;; O(1) persistent checkpoint & rollback
(define (zipper-checkpoint z)
  (huet-zipper (huet-zipper-left z)
               (huet-zipper-focus z)
               (huet-zipper-right z)
               (huet-zipper-index z)
               z))

(define (zipper-rollback z)
  (or (huet-zipper-checkpoint z) z))

;; =============================================================================
;; 1.4 Pointerless / Functional Braun Tree Priority Queue (Okasaki 1997)
;; =============================================================================

(struct braun-node (key val left right) #:transparent)

(define braun-empty #f)
(define (braun-empty? t) (not t))

(define (braun-insert t key [val key])
  (match t
    [#f (braun-node key val #f #f)]
    [(braun-node k v l r)
     (if (< key k)
         (braun-node key val (braun-insert r k v) l)
         (braun-node k v (braun-insert r key val) l))]))

(define (braun-min t)
  (match t
    [#f (error 'braun-min "empty braun tree")]
    [(braun-node k v _ _) (cons k v)]))

(define (braun-extract-leftmost t)
  (match t
    [(braun-node k v #f #f) (values k v #f)]
    [(braun-node k v l r)
     (define-values (lk lv l-rest) (braun-extract-leftmost l))
     (values lk lv (braun-node k v r l-rest))]))

(define (braun-sift-down k v l r)
  (match* (l r)
    [(#f #f) (braun-node k v #f #f)]
    [((braun-node lk lv #f #f) #f)
     (if (<= k lk)
         (braun-node k v l #f)
         (braun-node lk lv (braun-node k v #f #f) #f))]
    [((braun-node lk lv ll lr) (braun-node rk rv rl rr))
     (cond
       [(and (<= k lk) (<= k rk))
        (braun-node k v l r)]
       [(<= lk rk)
        (braun-node lk lv (braun-sift-down k v ll lr) r)]
       [else
        (braun-node rk rv l (braun-sift-down k v rl rr))])]))

(define (braun-delete-min t)
  (match t
    [#f (error 'braun-delete-min "empty braun tree")]
    [(braun-node _ _ #f _) #f]
    [(braun-node _ _ l r)
     (define-values (lk lv l-rest) (braun-extract-leftmost l))
     (braun-sift-down lk lv r l-rest)]))

;; Okasaki's O(log^2 N) `diff` helper for Braun tree size
(define (braun-diff t m)
  (cond
    [(not t) 0]
    [(zero? m) 1]
    [(odd? m)
     (braun-diff (braun-node-left t) (quotient (sub1 m) 2))]
    [else
     (braun-diff (braun-node-right t) (quotient (- m 2) 2))]))

(define (braun-size t)
  (match t
    [#f 0]
    [(braun-node _ _ l r)
     (define m (braun-size r))
     (+ 1 (* 2 m) (braun-diff l m))]))

(define (fold-braun f init t)
  (match t
    [#f init]
    [(braun-node k v l r)
     (fold-braun f (fold-braun f (f k v init) l) r)]))

(define (braun->sorted-list t)
  (let loop ([cur t] [acc '()])
    (if (braun-empty? cur)
        (reverse acc)
        (loop (braun-delete-min cur)
              (cons (braun-min cur) acc)))))

;; =============================================================================
;; 1.5 Skew-Binary Random-Access List (O(1) Frame Snapshots & O(log N) Ref/Set)
;; =============================================================================

(struct sbral-leaf (val) #:transparent)
(struct sbral-node (val left right) #:transparent)
(struct sbral-root (trees len) #:transparent)

(define sbral-empty (sbral-root '() 0))
(define (sbral-empty? s) (null? (sbral-root-trees s)))
(define (sbral-length s) (sbral-root-trees-length s))

(define (sbral-root-trees-length s) (sbral-root-len s))

(define (sbral-cons x s)
  (define ts (sbral-root-trees s))
  (define new-ts
    (match ts
      [(list* (cons w1 t1) (cons w2 t2) rest)
       #:when (= w1 w2)
       (cons (cons (+ 1 w1 w2) (sbral-node x t1 t2)) rest)]
      [_
       (cons (cons 1 (sbral-leaf x)) ts)]))
  (sbral-root new-ts (add1 (sbral-root-len s))))

(define (sbral-head s)
  (match (sbral-root-trees s)
    ['() (error 'sbral-head "empty skew-binary random-access list")]
    [(cons (cons 1 (sbral-leaf x)) _) x]
    [(cons (cons _ (sbral-node x _ _)) _) x]))

(define (sbral-tail s)
  (match (sbral-root-trees s)
    ['() (error 'sbral-tail "empty skew-binary random-access list")]
    [(cons (cons 1 (sbral-leaf _)) rest)
     (sbral-root rest (sub1 (sbral-root-len s)))]
    [(cons (cons w (sbral-node _ t1 t2)) rest)
     (define half (quotient w 2))
     (sbral-root (list* (cons half t1) (cons half t2) rest)
                 (sub1 (sbral-root-len s)))]))

(define (tree-lookup w t idx)
  (match t
    [(sbral-leaf x)
     (if (zero? idx) x (error 'sbral-ref "index out of bounds"))]
    [(sbral-node x t1 t2)
     (if (zero? idx)
         x
         (let ([half (quotient w 2)])
           (if (<= idx half)
               (tree-lookup half t1 (sub1 idx))
               (tree-lookup half t2 (- idx 1 half)))))]))

(define (tree-update w t idx new-val)
  (match t
    [(sbral-leaf _)
     (if (zero? idx)
         (sbral-leaf new-val)
         (error 'sbral-set "index out of bounds"))]
    [(sbral-node x t1 t2)
     (if (zero? idx)
         (sbral-node new-val t1 t2)
         (let ([half (quotient w 2)])
           (if (<= idx half)
               (sbral-node x (tree-update half t1 (sub1 idx) new-val) t2)
               (sbral-node x t1 (tree-update half t2 (- idx 1 half) new-val)))))]))

(define (sbral-ref s idx)
  (let loop ([ts (sbral-root-trees s)] [i idx])
    (match ts
      ['() (error 'sbral-ref "index out of bounds: ~a" idx)]
      [(cons (cons w t) rest)
       (if (< i w)
           (tree-lookup w t i)
           (loop rest (- i w)))])))

(define (sbral-set s idx new-val)
  (define new-ts
    (let loop ([ts (sbral-root-trees s)] [i idx])
      (match ts
        ['() (error 'sbral-set "index out of bounds: ~a" idx)]
        [(cons (cons w t) rest)
         (if (< i w)
             (cons (cons w (tree-update w t i new-val)) rest)
             (cons (cons w t) (loop rest (- i w))))])))
  (sbral-root new-ts (sbral-root-len s)))

(define (sbral->list s)
  (let loop ([cur s] [acc '()])
    (if (sbral-empty? cur)
        (reverse acc)
        (loop (sbral-tail cur) (cons (sbral-head cur) acc)))))
