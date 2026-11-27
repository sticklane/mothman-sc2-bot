#lang racket/base

;; =============================================================================
;; Loop 72C Lane A Unit Test Suite (`tests/l72-belief-midgame-econ-test.rkt`)
;;
;; Verifies Loop 72C (`lib/plan/worker-saturation-policy.rkt`, pure L0 Guard 9h):
;;   1. 100% Bit-Identical Release #20 GRMS (Early AND 3-Base Mid-Game):
;;      - `cur-gas = 210 / cur-min = 90` latches `#t` and pulls down to floor `1`
;;        on BOTH 2-base (`loop=5000`) AND 3-base (`loop=9000`, `52w`);
;;      - `cur-gas = 260 / cur-min = 90` and `cur-gas = 310 / cur-min = 140` trigger
;;        `gas-pull-to-zero-now?` -> `0` on BOTH early and 3-base states;
;;      - `g >= 6` mineral-worker floor stays `28` across 2-base AND 3-base states.
;;   2. Post-4:30 (`> 6048f`) A2 Mineral Rally & 3rd/4th-Base Transfer Kickstart:
;;      - Saturated `16/16` Main rallies to empty `0/16` 3rd base at `cur-loop = 9000`
;;        (whereas at `cur-loop = 4000`, `16/16` Main rallies to itself!);
;;      - Oversaturated `20/16` Main transfers `4` workers in a single step;
;;      - `17/16` Main (`sth-surp = 1`) transfers `1` worker when 3rd base `< 8` workers;
;;      - Safe `16/16` donor kickstarts `0/16` 3rd base (`>= 6` patches) by `4` workers,
;;        `15/16` donor by `3` workers (NEVER dropping any donor `< 12`!), and `14/16`
;;        donor transfers `0` workers.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/plan/worker-saturation-policy.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (mk-w tag x y
              #:type [ut 'probe]
              #:ab [ab 298]
              #:tgt [tgt 0]
              #:min? [min? #f]
              #:gas? [gas? #f])
  (sat-worker-info tag ut x y ab tgt min? gas? #f #f))

(define (mk-b tag x y
              #:type [ut 'nexus]
              #:ready? [ready? #t]
              #:asgn [asgn 16]
              #:ideal [ideal 16]
              #:patches [patches '()])
  (sat-base-info tag ut x y ready? #f asgn ideal #f patches))

(define (mk-g tag x y
              #:type [ut 'assimilator]
              #:ready? [ready? #t]
              #:vesp [vesp 2000]
              #:asgn [asgn 3]
              #:ideal [ideal 3]
              #:base [nb #f])
  (sat-gas-info tag ut x y ready? vesp asgn ideal nb #f))

(define (mk-m tag x y #:mins [mins 1500] #:owner [owner #f])
  (sat-mineral-info tag x y mins owner #t))

(define (rally-dirs ds)
  (filter (lambda (d) (eq? (sat-directive-kind d) 'rally-workers)) ds))

(define (gather-dirs ds)
  (filter (lambda (d) (eq? (sat-directive-kind d) 'harvest-gather)) ds))

(define (gas-pull-count ds)
  (for/sum ([d (in-list (gather-dirs ds))]
            #:when (memq (sat-directive-reason d)
                         '(gas-pull-grms-urgent gas-pull-routine gas-pull-early gas-pull-mined-out-evac)))
    (length (sat-directive-unit-tags d))))

(define (gas-refill-count ds)
  (for/sum ([d (in-list (gather-dirs ds))]
            #:when (memq (sat-directive-reason d) '(gas-refill gas-refill-carrying gas-refill-boosted)))
    (length (sat-directive-unit-tags d))))

(define (xfer-count ds)
  (for/sum ([d (in-list (gather-dirs ds))]
            #:when (memq (sat-directive-reason d) '(inter-base-transfer early-natural-transfer)))
    (length (sat-directive-unit-tags d))))

(define (make-base-mins base-tag bx by start-mtag [n 6])
  (for/list ([i (in-range n)])
    (mk-m (+ start-mtag i) (- bx 5.0) (+ (- by 3.0) (* 1.2 i)) #:owner base-tag)))

(define mins-b1 (make-base-mins 1 30.0 30.0 501 6))
(define mins-b2 (make-base-mins 2 65.0 30.0 601 6))
(define mins-b3 (make-base-mins 3 100.0 30.0 701 6))
(define all-3b-mins (append mins-b1 mins-b2 mins-b3))
(define all-2b-mins (append mins-b1 mins-b2))

(define (make-min-workers start-tag bx by patch-tags n)
  (for/list ([i (in-range n)])
    (define ptag (list-ref patch-tags (modulo i (length patch-tags))))
    (mk-w (+ start-tag i) (- bx 4.0) (+ (- by 2.0) (* 0.25 i)) #:ab 298 #:tgt ptag)))

(define (make-gas-workers start-tag gx gy gtag n)
  (for/list ([i (in-range n)])
    (mk-w (+ start-tag i) gx (+ gy 1.0 (* 0.1 i)) #:ab 298 #:tgt gtag)))

;; =============================================================================
;; 1. 100% Release #20 GRMS Preserved Across Early AND 3-Base Mid-Game States
;; =============================================================================
(let ()
  (define b1 (mk-b 1 30.0 30.0 #:asgn 15 #:ideal 16 #:patches (map sat-mineral-info-tag mins-b1)))
  (define b2 (mk-b 2 65.0 30.0 #:asgn 15 #:ideal 16 #:patches (map sat-mineral-info-tag mins-b2)))
  (define b3 (mk-b 3 100.0 30.0 #:asgn 14 #:ideal 16 #:patches (map sat-mineral-info-tag mins-b3)))
  (define g1 (mk-g 10 30.0 22.0 #:asgn 3 #:ideal 3 #:base 1))
  (define g2 (mk-g 11 65.0 22.0 #:asgn 3 #:ideal 3 #:base 2))
  (define g2-0 (mk-g 11 65.0 22.0 #:asgn 0 #:ideal 3 #:base 2))
  (define g3-0 (mk-g 12 100.0 22.0 #:asgn 0 #:ideal 3 #:base 3))
  (define ws-50-6g
    (append (make-min-workers 1000 30.0 30.0 (map sat-mineral-info-tag mins-b1) 15)
            (make-min-workers 1100 65.0 30.0 (map sat-mineral-info-tag mins-b2) 15)
            (make-min-workers 1200 100.0 30.0 (map sat-mineral-info-tag mins-b3) 14)
            (make-gas-workers 2000 30.0 22.0 10 3)
            (make-gas-workers 2100 65.0 22.0 11 3)))
  (define ws-50-3g
    (append (make-min-workers 1000 30.0 30.0 (map sat-mineral-info-tag mins-b1) 16)
            (make-min-workers 1100 65.0 30.0 (map sat-mineral-info-tag mins-b2) 16)
            (make-min-workers 1200 100.0 30.0 (map sat-mineral-info-tag mins-b3) 15)
            (make-gas-workers 2000 30.0 22.0 10 3)))

  ;; 1a: Loop 88A Flow-Balanced Physics (mineral-heavy demand on early & 3-base mid-game):
  ;;     At 210G/90M with mineral-heavy demand (`m-dem=1800, g-dem=150`), flow balance computes G*=0,
  ;;     latches #t, and pulls surplus gas workers on BOTH early (loop=5000) AND 3-base (loop=9000, 50w)!
  (define st-5000 (make-worker-sat-state))
  (define ds-5000
    (evaluate-worker-saturation-policy!
     st-5000 #:loop 5000 #:race 'Protoss #:minerals 90 #:gas 210
     #:workers ws-50-3g #:bases (list b1 b2 b3) #:gas-buildings (list g1 g2-0 g3-0)
     #:minerals-fields all-3b-mins
     #:mineral-demand-rate 1800.0 #:gas-demand-rate 150.0))
  (define st-9000 (make-worker-sat-state))
  (define ds-9000
    (evaluate-worker-saturation-policy!
     st-9000 #:loop 9000 #:race 'Terran #:minerals 90 #:gas 210
     #:workers ws-50-3g #:bases (list b1 b2 b3) #:gas-buildings (list g1 g2-0 g3-0)
     #:minerals-fields all-3b-mins
     #:mineral-demand-rate 1800.0 #:gas-demand-rate 150.0))
  (check! (and (unbox (worker-sat-gas-pull-latch-box st-5000))
               (>= (gas-pull-count ds-5000) 2)
               (unbox (worker-sat-gas-pull-latch-box st-9000))
               (>= (gas-pull-count ds-9000) 2))
          (format "1a. Flow-balanced 210G/90M mineral-heavy must latch #t & pull >=2 on early & 3b/50w; l5=~a p5=~a l9=~a p9=~a"
                  (unbox (worker-sat-gas-pull-latch-box st-5000)) (gas-pull-count ds-5000)
                  (unbox (worker-sat-gas-pull-latch-box st-9000)) (gas-pull-count ds-9000)))

  ;; 1b: 3-base mid-game (loop=9000, 50w) at 260G/90M with mineral-heavy demand evacuates 1->0!
  (define st-evac (make-worker-sat-state))
  (define g1-1 (mk-g 10 30.0 22.0 #:asgn 1 #:ideal 3 #:base 1))
  (define ws-50-1g
    (append (make-min-workers 1000 30.0 30.0 (map sat-mineral-info-tag mins-b1) 16)
            (make-min-workers 1100 65.0 30.0 (map sat-mineral-info-tag mins-b2) 16)
            (make-min-workers 1200 100.0 30.0 (map sat-mineral-info-tag mins-b3) 17)
            (make-gas-workers 2000 30.0 22.0 10 1)))
  (define ds-evac
    (evaluate-worker-saturation-policy!
     st-evac #:loop 9000 #:race 'Zerg #:minerals 90 #:gas 260
     #:workers ws-50-1g #:bases (list b1 b2 b3) #:gas-buildings (list g1-1 g2-0 g3-0)
     #:minerals-fields all-3b-mins
     #:mineral-demand-rate 2000.0 #:gas-demand-rate 120.0))
  (check! (and (unbox (worker-sat-gas-pull-latch-box st-evac))
               (= (gas-pull-count ds-evac) 1))
          (format "1b. Flow-balanced 260G/90M mineral-heavy on 3b/50w must evacuate 1->0; latch=~a pulls=~a"
                  (unbox (worker-sat-gas-pull-latch-box st-evac)) (gas-pull-count ds-evac)))

  ;; 1c: 3-base mid-game (loop=9000) with 6 gas & 25 mineral workers: when macro demand needs
  ;;     <= 6 gas workers (`m-dem=1400, g-dem=240` at 200M/120G -> G*<=6), slot #7 is NOT refilled;
  ;;     when macro demand is gas-heavy (`m-dem=800, g-dem=600` -> G*=9), slot #7 refills immediately!
  (define st-3b-g7 (make-worker-sat-state))
  (define st-3b-g7-hi (make-worker-sat-state))
  (define b1-g7 (mk-b 1 30.0 30.0 #:asgn 9 #:ideal 16 #:patches (map sat-mineral-info-tag mins-b1)))
  (define b2-g7 (mk-b 2 65.0 30.0 #:asgn 8 #:ideal 16 #:patches (map sat-mineral-info-tag mins-b2)))
  (define b3-g7 (mk-b 3 100.0 30.0 #:asgn 8 #:ideal 16 #:patches (map sat-mineral-info-tag mins-b3)))
  (define ws-3b-25m-6g
    (append (make-min-workers 1000 30.0 30.0 (map sat-mineral-info-tag mins-b1) 9)
            (make-min-workers 1100 65.0 30.0 (map sat-mineral-info-tag mins-b2) 8)
            (make-min-workers 1200 100.0 30.0 (map sat-mineral-info-tag mins-b3) 8)
            (make-gas-workers 2000 30.0 22.0 10 3)
            (make-gas-workers 2100 65.0 22.0 11 3)))
  (define ds-3b-g7
    (evaluate-worker-saturation-policy!
     st-3b-g7 #:loop 9000 #:race 'Protoss #:minerals 200 #:gas 120
     #:workers ws-3b-25m-6g #:bases (list b1-g7 b2-g7 b3-g7) #:gas-buildings (list g1 g2 g3-0)
     #:minerals-fields all-3b-mins
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 240.0))
  (define ds-3b-g7-hi
    (evaluate-worker-saturation-policy!
     st-3b-g7-hi #:loop 9000 #:race 'Protoss #:minerals 200 #:gas 120
     #:workers ws-3b-25m-6g #:bases (list b1-g7 b2-g7 b3-g7) #:gas-buildings (list g1 g2 g3-0)
     #:minerals-fields all-3b-mins
     #:mineral-demand-rate 800.0 #:gas-demand-rate 600.0))
  (check! (and (= (gas-refill-count ds-3b-g7) 0)
               (>= (gas-refill-count ds-3b-g7-hi) 1))
          (format "1c. Flow-balanced slot #7 blocks under low gas-dem & refills under gas-heavy dem; low=~a hi=~a"
                  (gas-refill-count ds-3b-g7) (gas-refill-count ds-3b-g7-hi))))

;; =============================================================================
;; 2. Post-4:30 (`> 6048f`) A2 Mineral Rally & 3rd/4th-Base Transfer Kickstart
;; =============================================================================
(let ()
  (define b3-min-tags (map sat-mineral-info-tag mins-b3))
  (define b1-min-tags (map sat-mineral-info-tag mins-b1))
  (define b2-min-tags (map sat-mineral-info-tag mins-b2))

  ;; 2a: Saturated 16/16 Main rallies straight to empty 0/16 3rd base at loop=9000,
  ;;     whereas at loop=4000 (<= 6048), 16/16 Main rallies to itself!
  (define st-r9000 (make-worker-sat-state))
  (define st-r4000 (make-worker-sat-state))
  (define b1-16 (mk-b 1 30.0 30.0 #:asgn 16 #:ideal 16 #:patches b1-min-tags))
  (define b2-16 (mk-b 2 65.0 30.0 #:asgn 16 #:ideal 16 #:patches b2-min-tags))
  (define b3-0  (mk-b 3 100.0 30.0 #:asgn 0 #:ideal 16 #:patches b3-min-tags))
  (define ds-r9000
    (rally-dirs
     (evaluate-worker-saturation-policy!
      st-r9000 #:loop 9000 #:race 'Terran #:minerals 200 #:gas 100
      #:workers '() #:bases (list b1-16 b2-16 b3-0) #:gas-buildings '()
      #:minerals-fields all-3b-mins)))
  (define ds-r4000
    (rally-dirs
     (evaluate-worker-saturation-policy!
      st-r4000 #:loop 4000 #:race 'Terran #:minerals 200 #:gas 100
      #:workers '() #:bases (list b1-16 b2-16 b3-0) #:gas-buildings '()
      #:minerals-fields all-3b-mins)))
  (define r9000-b1 (findf (lambda (d) (equal? (sat-directive-unit-tags d) '(1))) ds-r9000))
  (define r4000-b1 (findf (lambda (d) (equal? (sat-directive-unit-tags d) '(1))) ds-r4000))
  (check! (and r9000-b1 (not (not (memv (sat-directive-target-tag r9000-b1) b3-min-tags)))
               r4000-b1 (not (not (memv (sat-directive-target-tag r4000-b1) b1-min-tags))))
          (format "2a. 16/16 Main must rally to empty 3rd base at loop=9000 and to itself at loop=4000; tgt9000=~a tgt4000=~a"
                  (and r9000-b1 (sat-directive-target-tag r9000-b1))
                  (and r4000-b1 (sat-directive-target-tag r4000-b1))))

  ;; 2b: Oversaturated 20/16 Main transfers 4 workers in a single step at loop=9000!
  (define st-20 (make-worker-sat-state))
  (define b1-20 (mk-b 1 30.0 30.0 #:asgn 20 #:ideal 16 #:patches b1-min-tags))
  (define ws-20 (make-min-workers 1000 30.0 30.0 b1-min-tags 20))
  (define ds-20
    (evaluate-worker-saturation-policy!
     st-20 #:loop 9000 #:race 'Protoss #:minerals 200 #:gas 100
     #:workers ws-20 #:bases (list b1-20 b2-16 b3-0) #:gas-buildings '()
     #:minerals-fields all-3b-mins))
  (check! (= (xfer-count ds-20) 4)
          (format "2b. 20/16 Main at loop=9000 must transfer 4 workers in a single step; got ~a"
                  (xfer-count ds-20)))

  ;; 2c: 17/16 Main (sth-surp = 1) transfers 1 worker when 3rd base has < 8 workers!
  (define st-17 (make-worker-sat-state))
  (define b1-17 (mk-b 1 30.0 30.0 #:asgn 17 #:ideal 16 #:patches b1-min-tags))
  (define ws-17 (make-min-workers 1000 30.0 30.0 b1-min-tags 17))
  (define ds-17
    (evaluate-worker-saturation-policy!
     st-17 #:loop 9000 #:race 'Protoss #:minerals 200 #:gas 100
     #:workers ws-17 #:bases (list b1-17 b2-16 b3-0) #:gas-buildings '()
     #:minerals-fields all-3b-mins))
  (check! (= (xfer-count ds-17) 1)
          (format "2c. 17/16 Main at loop=9000 must transfer 1 worker to 0/16 3rd base (<8w); got ~a"
                  (xfer-count ds-17)))

  ;; 2d: Mid-game kickstart (ZERO oversaturation):
  ;;     - 16/16 donor -> transfers 4 workers (stops strictly at 12!);
  ;;     - 15/16 donor -> transfers 3 workers (stops strictly at 12!);
  ;;     - 14/16 donor -> transfers 0 workers!
  (define st-k16 (make-worker-sat-state))
  (define ws-k16 (append (make-min-workers 1000 30.0 30.0 b1-min-tags 16)
                         (make-min-workers 1100 65.0 30.0 b2-min-tags 14)))
  (define b2-14 (mk-b 2 65.0 30.0 #:asgn 14 #:ideal 16 #:patches b2-min-tags))
  (define ds-k16
    (evaluate-worker-saturation-policy!
     st-k16 #:loop 9000 #:race 'Terran #:minerals 200 #:gas 100
     #:workers ws-k16 #:bases (list b1-16 b2-14 b3-0) #:gas-buildings '()
     #:minerals-fields all-3b-mins))

  (define st-k15 (make-worker-sat-state))
  (define b1-15 (mk-b 1 30.0 30.0 #:asgn 15 #:ideal 16 #:patches b1-min-tags))
  (define ws-k15 (append (make-min-workers 1000 30.0 30.0 b1-min-tags 15)
                         (make-min-workers 1100 65.0 30.0 b2-min-tags 14)))
  (define ds-k15
    (evaluate-worker-saturation-policy!
     st-k15 #:loop 9000 #:race 'Terran #:minerals 200 #:gas 100
     #:workers ws-k15 #:bases (list b1-15 b2-14 b3-0) #:gas-buildings '()
     #:minerals-fields all-3b-mins))

  (define st-k14 (make-worker-sat-state))
  (define b1-14 (mk-b 1 30.0 30.0 #:asgn 14 #:ideal 16 #:patches b1-min-tags))
  (define ws-k14 (append (make-min-workers 1000 30.0 30.0 b1-min-tags 14)
                         (make-min-workers 1100 65.0 30.0 b2-min-tags 14)))
  (define ds-k14
    (evaluate-worker-saturation-policy!
     st-k14 #:loop 9000 #:race 'Terran #:minerals 200 #:gas 100
     #:workers ws-k14 #:bases (list b1-14 b2-14 b3-0) #:gas-buildings '()
     #:minerals-fields all-3b-mins))

  (check! (and (= (xfer-count ds-k16) 4)
               (= (xfer-count ds-k15) 3)
               (= (xfer-count ds-k14) 0))
          (format "2d. Mid-game kickstart must transfer 4 from 16/16, 3 from 15/16 (never <12!), and 0 from 14/16; got 16->~a 15->~a 14->~a"
                  (xfer-count ds-k16) (xfer-count ds-k15) (xfer-count ds-k14))))

(printf "l72-belief-midgame-econ-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
