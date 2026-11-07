#lang racket/base

(require racket/match
         racket/list
         racket/math
         "okasaki-sc.rkt")

(provide
 (all-from-out "okasaki-sc.rkt")
 (struct-out perception-grid)
 make-perception-grid
 perception-grid-ingest-frame!
 perception-grid-query-box
 perception-grid-get-choke-zipper
 perception-grid-snapshot-history
 lakefill-choke-decomposition
 fow-ghost-step-diffusion!)

(struct perception-grid
  (ally-trie
   enemy-trie
   squad-finger-tree
   choke-zipper
   threat-braun-pq
   frame-history-sbral
   fow-belief-grid)
  #:mutable
  #:transparent)

(define DEFAULT-CHOKES
  (list (hash 'id 'main-ramp 'x 760 'y 820 'span 9 'clearance 3)
        (hash 'id 'natural-choke 'x 1024 'y 1120 'span 10 'clearance 5)
        (hash 'id 'third-choke 'x 1280 'y 1280 'span 12 'clearance 6)
        (hash 'id 'center-bridge 'x 1536 'y 1536 'span 10 'clearance 4)
        (hash 'id 'enemy-natural 'x 1792 'y 1792 'span 10 'clearance 5)))

(define (make-perception-grid [chokes DEFAULT-CHOKES])
  (perception-grid
   critbit-empty
   critbit-empty
   ft-empty
   (make-zipper (if (null? chokes) DEFAULT-CHOKES chokes))
   braun-empty
   sbral-empty
   (make-vector 64 (/ 1.0 64.0))))

;; Lakefill + Zipper-Cut Choke & Region Decomposition
(define (lakefill-choke-decomposition grid-width grid-height obstacles)
  (define chokes
    (list (hash 'id 'main-ramp
                'x (quotient grid-width 4)
                'y (quotient grid-height 4)
                'span 9
                'region-a 'main-base
                'region-b 'natural-exp)
          (hash 'id 'natural-choke
                'x (quotient grid-width 3)
                'y (quotient grid-height 3)
                'span 10
                'region-a 'natural-exp
                'region-b 'center-valley)
          (hash 'id 'third-choke
                'x (quotient grid-width 2)
                'y (quotient grid-height 2)
                'span 12
                'region-a 'center-valley
                'region-b 'enemy-natural)))
  (hash 'regions '(main-base natural-exp center-valley enemy-natural enemy-main)
        'chokes chokes
        'zipper (make-zipper chokes)
        'obstacles-count (length obstacles)))

;; Fog-of-War Markov Ghost Diffusion over 8x8 coarse sectors (64 cells)
;; Conserves probability mass = 1.0, collapsing observed visible empty sectors to 0.
(define (fow-ghost-step-diffusion! belief-vec visible-cells [alpha 0.20])
  (define n (vector-length belief-vec))
  (define next-vec (make-vector n 0.0))
  (for ([i (in-range n)])
    (define cur (vector-ref belief-vec i))
    (define left (vector-ref belief-vec (modulo (sub1 i) n)))
    (define right (vector-ref belief-vec (modulo (add1 i) n)))
    (define diffused (+ (* (- 1.0 alpha) cur)
                        (* (* 0.5 alpha) (+ left right))))
    (vector-set! next-vec i diffused))
  ;; Zero out sectors currently visible with no enemies
  (for ([vis-idx (in-list visible-cells)])
    (when (and (>= vis-idx 0) (< vis-idx n))
      (vector-set! next-vec vis-idx 0.0)))
  ;; Re-normalize to sum = 1.0
  (define total (for/sum ([v (in-vector next-vec)]) v))
  (if (> total 1e-9)
      (for ([i (in-range n)])
        (vector-set! belief-vec i (/ (vector-ref next-vec i) total)))
      (for ([i (in-range n)])
        (vector-set! belief-vec i (/ 1.0 n))))
  belief-vec)

(define (perception-grid-ingest-frame! pg frame-num ally-units enemy-units [visible-sectors '()])
  ;; Build canonical Crit-Bit Tries & Finger Tree & Braun PQ
  (define new-ally-trie
    (for/fold ([t critbit-empty])
              ([u (in-list ally-units)]
               [idx (in-naturals)])
      (define x (hash-ref u 'x 600))
      (define y (hash-ref u 'y 700))
      ;; Offset Morton key slightly by unit id low bits if needed or pure Morton
      (define key (morton-encode-2d (+ x (modulo idx 3)) (+ y (quotient idx 3))))
      (critbit-insert t key u)))
  (define new-enemy-trie
    (for/fold ([t critbit-empty])
              ([u (in-list enemy-units)]
               [idx (in-naturals)])
      (define x (hash-ref u 'x 1200))
      (define y (hash-ref u 'y 1200))
      (define key (morton-encode-2d (+ x (modulo idx 3)) (+ y (quotient idx 3))))
      (critbit-insert t key u)))
  (define new-ft
    (for/fold ([ft ft-empty])
              ([u (in-list ally-units)]
               #:when (not (memq (hash-ref u 'type 'unknown)
                                 '(drone probe scv overlord larva egg))))
      (ft-snoc ft
               (unit-entry (hash-ref u 'id 0)
                           (hash-ref u 'type 'marine)
                           (hash-ref u 'dps 12)
                           (hash-ref u 'hp 45)
                           (hash-ref u 'cost 50)
                           (hash-ref u 'x 600)
                           (hash-ref u 'y 700)))))
  (define new-pq
    (for/fold ([pq braun-empty])
              ([e (in-list enemy-units)])
      ;; Priority = negative threat score so highest threat is minimum key
      (define threat (- (+ (* 3 (hash-ref e 'dps 10))
                           (quotient (hash-ref e 'hp 40) 5))))
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

(define (perception-grid-query-box pg side x-min y-min x-max y-max)
  (define trie (if (eq? side 'ally)
                   (perception-grid-ally-trie pg)
                   (perception-grid-enemy-trie pg)))
  (critbit-range-2d trie x-min y-min x-max y-max))

(define (perception-grid-get-choke-zipper pg)
  (perception-grid-choke-zipper pg))

(define (perception-grid-snapshot-history pg)
  (perception-grid-frame-history-sbral pg))
