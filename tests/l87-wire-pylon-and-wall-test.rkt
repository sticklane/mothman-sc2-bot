#lang racket

(require "../lib/sc2-game-constants.rkt"
         "../lib/sc2-protobuf-ws.rkt"
         "../lib/sc2-placement.rkt")

;; =============================================================================
;; Loop 87 Track 2 Unit Tests:
;;   1. Supply-Blocked / Miss-Streak In-Main High-Ground Pylon Guarantee
;;   2. Normal Unblocked Midgame Pylon Preservation (Natural + Repower + 200/200)
;;   3. Per-Cell SC2-PLACEMENT-NEG-COOLDOWN (160f) Rotation on Failed build-pylon
;;   4. Protoss Natural Wall Doorway Corridor Permanence + Intact Opening Wall
;; =============================================================================

(define total 0)
(define passed 0)
(define failed 0)

(define (check-true name cond [detail ""])
  (set! total (add1 total))
  (if cond
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (printf "FAIL: ~a ~a\n" name detail))))

(define (hypot dx dy) (sqrt (+ (* dx dx) (* dy dy))))

(define (mk-unit tag utype alliance x y
                 #:hp [hp 200.0]
                 #:sh [sh 200.0]
                 #:rad [rad 1.0]
                 #:bp [bp 1.0]
                 #:powered? [powered? #t]
                 #:flying? [flying? #f]
                 #:orders [orders '()]
                 #:mins [mins 0])
  (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
            (sc2-point3d x y 10.0) 0.0 rad bp 0 #f #t #f
            hp hp sh sh 50.0 200.0 mins 0
            flying? #f #f powered? #f
            orders 0 '() 0 0 0.0 0 0 0 0 '() 0 0))

(define (mk-mins base-tag cx cy dx-off)
  (for/list ([i (in-range 6)])
    (mk-unit (+ base-tag i) 341 3 (+ cx dx-off) (+ cy (* (- i 2.5) 1.5))
             #:hp 1000.0 #:sh 0.0 #:rad 1.0 #:mins 1500)))

;; Build 128x128 game-info with configurable placement, pathing, and 8-bit terrain-height grid.
;; Default height: Main plateau (x < cliff-x) = 200, Natural/low ground (x >= cliff-x) = 184.
(define (mk-gi enemy-x enemy-y enemy-race #:cliff-x [cliff-x 46])
  (define w 128)
  (define h 128)
  (define pl-bytes (make-bytes (* w h) 1))
  (define pa-bytes (make-bytes (* w h) 1))
  (define th-bytes (make-bytes (* w h) 200))
  (for* ([y (in-range h)]
         [x (in-range w)])
    (define idx (+ x (* y w)))
    (when (or (< x 6) (> x 120) (< y 6) (> y 120))
      (bytes-set! pl-bytes idx 0)
      (bytes-set! pa-bytes idx 0))
    (when (>= x cliff-x)
      (bytes-set! th-bytes idx 184)))
  (sc2-game-info
   "TestMap" "TestMap.SC2Map"
   (list (hash 'player-id 1 'race-requested 'Protoss 'race-actual 'Protoss)
         (hash 'player-id 2 'race-requested enemy-race 'race-actual enemy-race))
   (cons w h)
   (hash 'x0 6 'y0 6 'x1 120 'y1 120)
   (list (sc2-point2d 30.0 32.0) (sc2-point2d enemy-x enemy-y))
   (sc2-image-grid 8 w h pa-bytes #f #f)
   (sc2-image-grid 8 w h th-bytes #f #f)
   (sc2-image-grid 8 w h pl-bytes #f #f)))

(define (mk-obs loop food-used food-cap units #:power-sources [ps '()] #:minerals [mins 400])
  (sc2-observation loop
                   (sc2-player-common 1 mins 100 food-cap food-used 0 0 0 0 0 0)
                   units '() ps #f '() '() '() '() '() '()))

(define (first-cmd-pt cmds ab-id)
  (define c
    (findf (lambda (x)
             (and (sc2-raw-unit-command? x)
                  (= (sc2-raw-unit-command-ability-id x) ab-id)))
           cmds))
  (and c (sc2-raw-unit-command-target-pos c)))

(define (reset-wire-state! gi units)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 12 15 units) #:game-info gi)))

;; =============================================================================
;; 1. Supply-Blocked / Miss-Streak In-Main High-Ground Pylon Guarantee
;; =============================================================================
(printf "[1/5] Testing supply-blocked / miss-streak in-main high-ground Pylon guarantee...\n")
(let ()
  (define gi (mk-gi 98.0 96.0 'Zerg #:cliff-x 46))
  (define th-grid (sc2-game-info-terrain-height gi))
  (define main-nex (mk-unit 1001 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define nat-nex  (mk-unit 1002 59 1 60.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  ;; Two existing Main Pylons near home (would trigger 9.0t anti-pylon-soup if not relaxed!)
  (define py-m1    (mk-unit 1003 60 1 34.0 28.0 #:rad 1.0))
  (define py-m2    (mk-unit 1004 60 1 34.0 36.0 #:rad 1.0))
  ;; Unpowered outer Gateway (> 15t from Main Nexus at 30, 32)
  (define gw-outer (mk-unit 1005 62 1 56.0 36.0 #:hp 500.0 #:sh 500.0 #:rad 1.5 #:powered? #f))
  (define probe-1  (mk-unit 1006 84 1 32.0 32.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
  (define mins-m   (mk-mins 1010 30.0 32.0 -6.5))
  (define units-1a (append (list main-nex nat-nex py-m1 py-m2 gw-outer probe-1) mins-m))

  ;; 1a. Supply-blocked (110/110) with in-main req, empty Natural Pylon slot, AND unpowered outer Gateway
  ;;     MUST place strictly inside Main (<= 14t of home) on Main high ground (height 200)!
  (reset-wire-state! gi units-1a)
  (define cmds-1a
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 4000 110 110 units-1a)
                                             #:game-info gi))
  (define pt-1a (first-cmd-pt cmds-1a 881))
  (check-true "l87-1a-supply-blocked-110-stays-in-main-beats-nat-and-outer-repower"
              (and (sc2-point2d? pt-1a)
                   (<= (hypot (- (sc2-point2d-x pt-1a) 30.0) (- (sc2-point2d-y pt-1a) 32.0)) 14.0)
                   (> (hypot (- (sc2-point2d-x pt-1a) 60.0) (- (sc2-point2d-y pt-1a) 32.0)) 16.0)
                   (> (hypot (- (sc2-point2d-x pt-1a) 56.0) (- (sc2-point2d-y pt-1a) 36.0)) 12.0)
                   (= (sc2-grid-ref th-grid
                                    (inexact->exact (floor (sc2-point2d-x pt-1a)))
                                    (inexact->exact (floor (sc2-point2d-y pt-1a))))
                      200))
              (format "pt=~a" pt-1a))

  ;; 1b. Supply-blocked (110/110) with an IN-MAIN unpowered Gateway (<= 15t from Main) still repowers it!
  (define gw-inmain (mk-unit 1020 62 1 39.0 32.0 #:hp 500.0 #:sh 500.0 #:rad 1.5 #:powered? #f))
  (define units-1b  (append (list main-nex nat-nex gw-inmain probe-1) mins-m))
  (reset-wire-state! gi units-1b)
  (define cmds-1b
    (translate-bot-actions->sc2-raw-commands '((build pylon 34.0 32.0))
                                             (mk-obs 4040 110 110 units-1b)
                                             #:game-info gi))
  (define pt-1b (first-cmd-pt cmds-1b 881))
  (check-true "l87-1b-supply-blocked-110-keeps-inmain-repower-within-15t"
              (and (sc2-point2d? pt-1b)
                   (<= (hypot (- (sc2-point2d-x pt-1b) 39.0) (- (sc2-point2d-y pt-1b) 32.0)) 6.0)
                   (<= (hypot (- (sc2-point2d-x pt-1b) 30.0) (- (sc2-point2d-y pt-1b) 32.0)) 14.0))
              (format "pt=~a" pt-1b))

  ;; 1c. Near supply-block (106/110, headroom = 4 <= 4) with in-main req stays in Main (no Natural hijack!)
  (define units-1c (append (list main-nex nat-nex py-m1 py-m2 probe-1) mins-m))
  (reset-wire-state! gi units-1c)
  (define cmds-1c
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 4100 106 110 units-1c)
                                             #:game-info gi))
  (define pt-1c (first-cmd-pt cmds-1c 881))
  (check-true "l87-1c-near-supply-block-headroom-4-inmain-req-stays-in-main"
              (and (sc2-point2d? pt-1c)
                   (<= (hypot (- (sc2-point2d-x pt-1c) 30.0) (- (sc2-point2d-y pt-1c) 32.0)) 14.0)
                   (= (sc2-grid-ref th-grid
                                    (inexact->exact (floor (sc2-point2d-x pt-1c)))
                                    (inexact->exact (floor (sc2-point2d-y pt-1c))))
                      200))
              (format "pt=~a" pt-1c))

  ;; 1d. Miss-streak >= 1 at unblocked supply (80/110) near cliff edge stays on Main high ground (height 200)!
  (define gi-cliff (mk-gi 98.0 96.0 'Zerg #:cliff-x 40))
  (define th-cliff (sc2-game-info-terrain-height gi-cliff))
  (define blocker-cliff (mk-unit 1025 62 1 39.0 32.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define units-1d (append (list main-nex nat-nex py-m1 blocker-cliff probe-1) mins-m))
  (reset-wire-state! gi-cliff units-1d)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'pylon 1)
  (define cmds-1d
    (translate-bot-actions->sc2-raw-commands '((build pylon 39.0 32.0))
                                             (mk-obs 4200 80 110 units-1d)
                                             #:game-info gi-cliff))
  (define pt-1d (first-cmd-pt cmds-1d 881))
  (check-true "l87-1d-miss-streak-1-stays-on-main-high-ground-not-low-ground-or-nat"
              (and (sc2-point2d? pt-1d)
                   (<= (hypot (- (sc2-point2d-x pt-1d) 30.0) (- (sc2-point2d-y pt-1d) 32.0)) 14.0)
                   (< (sc2-point2d-x pt-1d) 40.0)
                   (= (sc2-grid-ref th-cliff
                                    (inexact->exact (floor (sc2-point2d-x pt-1d)))
                                    (inexact->exact (floor (sc2-point2d-y pt-1d))))
                      200))
              (format "pt=~a" pt-1d))

  ;; 1e. Supply-blocked (110/110) with an OUT-OF-MAIN req (60, 36 at Natural) still redirects to Main high ground!
  (reset-wire-state! gi units-1c)
  (define cmds-1e
    (translate-bot-actions->sc2-raw-commands '((build pylon 60.0 36.0))
                                             (mk-obs 4300 110 110 units-1c)
                                             #:game-info gi))
  (define pt-1e (first-cmd-pt cmds-1e 881))
  (check-true "l87-1e-supply-blocked-out-of-main-req-redirects-to-main-high-ground"
              (and (sc2-point2d? pt-1e)
                   (<= (hypot (- (sc2-point2d-x pt-1e) 30.0) (- (sc2-point2d-y pt-1e) 32.0)) 14.0)
                   (= (sc2-grid-ref th-grid
                                    (inexact->exact (floor (sc2-point2d-x pt-1e)))
                                    (inexact->exact (floor (sc2-point2d-y pt-1e))))
                      200))
              (format "pt=~a" pt-1e)))

;; =============================================================================
;; 2. Normal Unblocked Midgame Pylon Preservation (80/110, miss-streak = 0)
;; =============================================================================
(printf "[2/5] Testing normal unblocked midgame Pylon natural coverage & outer repower preservation...\n")
(let ()
  (define gi (mk-gi 98.0 96.0 'Terran #:cliff-x 46))
  (define main-nex (mk-unit 2001 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define nat-nex  (mk-unit 2002 59 1 60.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define py-m1    (mk-unit 2003 60 1 36.0 32.0 #:rad 1.0))
  (define probe-2  (mk-unit 2004 84 1 34.0 32.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
  (define mins-m   (mk-mins 2010 30.0 32.0 -6.5))
  (define units-2a (append (list main-nex nat-nex py-m1 probe-2) mins-m))

  ;; 2a. Unblocked (80/110, miss-streak = 0) preserves pylon-nat-anchors at Natural Nexus!
  (reset-wire-state! gi units-2a)
  (define cmds-2a
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 36.0))
                                             (mk-obs 5000 80 110 units-2a)
                                             #:game-info gi))
  (define pt-2a (first-cmd-pt cmds-2a 881))
  (check-true "l87-2a-unblocked-80-110-preserves-natural-pylon-coverage"
              (and (sc2-point2d? pt-2a)
                   (<= (hypot (- (sc2-point2d-x pt-2a) 60.0) (- (sc2-point2d-y pt-2a) 32.0)) 10.0))
              (format "pt=~a" pt-2a))

  ;; 2b. Unblocked (80/110, miss-streak = 0) preserves outer repower-place-pt!
  (define gw-outer (mk-unit 2020 62 1 56.0 36.0 #:hp 500.0 #:sh 500.0 #:rad 1.5 #:powered? #f))
  (define units-2b (append (list main-nex nat-nex py-m1 gw-outer probe-2) mins-m))
  (reset-wire-state! gi units-2b)
  (define cmds-2b
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 5100 80 110 units-2b)
                                             #:game-info gi))
  (define pt-2b (first-cmd-pt cmds-2b 881))
  (check-true "l87-2b-unblocked-80-110-preserves-outer-repower"
              (and (sc2-point2d? pt-2b)
                   (<= (hypot (- (sc2-point2d-x pt-2b) 56.0) (- (sc2-point2d-y pt-2b) 36.0)) 6.0))
              (format "pt=~a" pt-2b))

  ;; 2c. Maxed supply (200/200) does NOT falsely trigger supply-block lock (still covers Natural)!
  (reset-wire-state! gi units-2a)
  (define cmds-2c
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 36.0))
                                             (mk-obs 5200 200 200 units-2a)
                                             #:game-info gi))
  (define pt-2c (first-cmd-pt cmds-2c 881))
  (check-true "l87-2c-maxed-200-200-not-supply-blocked-preserves-nat"
              (and (sc2-point2d? pt-2c)
                   (<= (hypot (- (sc2-point2d-x pt-2c) 60.0) (- (sc2-point2d-y pt-2c) 32.0)) 10.0))
              (format "pt=~a" pt-2c)))

;; =============================================================================
;; 3. Per-Cell SC2-PLACEMENT-NEG-COOLDOWN (160f) Rotation on Failed build-pylon
;; =============================================================================
(printf "[3/5] Testing per-cell SC2-PLACEMENT-NEG-COOLDOWN (160f) rotation after failed dispatch...\n")
(let ()
  (define gi (mk-gi 98.0 96.0 'Zerg #:cliff-x 46))
  (define main-nex (mk-unit 3001 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define probe-3  (mk-unit 3002 84 1 34.0 32.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
  (define mins-m   (mk-mins 3010 30.0 32.0 -6.5))
  (define units-3  (append (list main-nex probe-3) mins-m))

  ;; Step 1 (loop 3000): Dispatch supply-blocked Pylon at (36.0, 32.0) -> lands at pt1.
  (reset-wire-state! gi units-3)
  (define cmds-s1
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 3000 110 110 units-3)
                                             #:game-info gi))
  (define pt1 (first-cmd-pt cmds-s1 881))
  (define k1 (and (sc2-point2d? pt1)
                  (list 'failed-cell 'pylon
                        (inexact->exact (round (sc2-point2d-x pt1)))
                        (inexact->exact (round (sc2-point2d-y pt1))))))

  ;; Step 2 (loop 3016, +16f): Probe dropped 881 order and NO Pylon initialized at pt1!
  ;; Next build-pylon MUST record k1 in SC2-PLACEMENT-NEG-COOLDOWN and rotate > 2.5t away!
  (define cmds-s2
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 3016 110 110 units-3)
                                             #:game-info gi))
  (define pt2 (first-cmd-pt cmds-s2 881))
  (check-true "l87-3a-failed-pylon-dispatch-records-neg-cooldown-and-rotates"
              (and (sc2-point2d? pt1)
                   (sc2-point2d? pt2)
                   (hash-has-key? SC2-PLACEMENT-NEG-COOLDOWN k1)
                   (> (hypot (- (sc2-point2d-x pt2) (sc2-point2d-x pt1))
                             (- (sc2-point2d-y pt2) (sc2-point2d-y pt1)))
                      2.5)
                   (<= (hypot (- (sc2-point2d-x pt2) 30.0) (- (sc2-point2d-y pt2) 32.0)) 14.0))
              (format "pt1=~a pt2=~a hasKey=~a" pt1 pt2 (hash-has-key? SC2-PLACEMENT-NEG-COOLDOWN k1)))

  ;; Step 3 (loop 3032, +16f later, unrelated Gateway completes so cur-struct-sig changes!):
  ;; Failed-cell entry k1 MUST survive unrelated structure signature changes during its 160f TTL!
  (define new-gw (mk-unit 3020 62 1 25.0 24.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define pt2-warped (mk-unit 3021 60 1 (sc2-point2d-x pt2) (sc2-point2d-y pt2) #:bp 0.25 #:rad 1.0))
  (define units-s3 (append (list main-nex new-gw pt2-warped probe-3) mins-m))
  (define cmds-s3
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 3032 110 110 units-s3)
                                             #:game-info gi))
  (define pt3 (first-cmd-pt cmds-s3 881))
  (check-true "l87-3b-failed-cell-survives-unrelated-struct-sig-and-blocks-pt1-within-160f"
              (and (sc2-point2d? pt3)
                   (hash-has-key? SC2-PLACEMENT-NEG-COOLDOWN k1)
                   (> (hypot (- (sc2-point2d-x pt3) (sc2-point2d-x pt1))
                             (- (sc2-point2d-y pt3) (sc2-point2d-y pt1)))
                      2.5))
              (format "pt1=~a pt3=~a" pt1 pt3))

  ;; Step 4 (loop 3190, 174f > 160f since failure at 3016): cooldown expired, pt1 eligible again!
  (define units-s4 (append (list main-nex probe-3) mins-m))
  (define cmds-s4
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 3190 110 110 units-s4)
                                             #:game-info gi))
  (define pt4 (first-cmd-pt cmds-s4 881))
  (check-true "l87-3c-failed-cell-expires-after-160f"
              (and (sc2-point2d? pt4)
                   (<= (hypot (- (sc2-point2d-x pt4) (sc2-point2d-x pt1))
                              (- (sc2-point2d-y pt4) (sc2-point2d-y pt1)))
                       0.5))
              (format "pt1=~a pt4=~a" pt1 pt4))

  ;; Step 5: Successful Pylon initialization does NOT record a failed-cell cooldown!
  (reset-wire-state! gi units-3)
  (define cmds-ok1
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 32.0))
                                             (mk-obs 3300 110 110 units-3)
                                             #:game-info gi))
  (define pt-ok1 (first-cmd-pt cmds-ok1 881))
  (define k-ok1 (and (sc2-point2d? pt-ok1)
                     (list 'failed-cell 'pylon
                           (inexact->exact (round (sc2-point2d-x pt-ok1)))
                           (inexact->exact (round (sc2-point2d-y pt-ok1))))))
  (define warped-ok (mk-unit 3030 60 1 (sc2-point2d-x pt-ok1) (sc2-point2d-y pt-ok1) #:bp 0.15 #:rad 1.0))
  (void (translate-bot-actions->sc2-raw-commands '()
                                                 (mk-obs 3316 110 110 (append (list warped-ok) units-3))
                                                 #:game-info gi))
  (check-true "l87-3d-successful-pylon-init-does-not-record-neg-cooldown"
              (not (hash-has-key? SC2-PLACEMENT-NEG-COOLDOWN k-ok1))
              (format "k=~a" k-ok1)))

;; =============================================================================
;; 4. Protoss Natural Wall Doorway Corridor Permanence & Intact Opening Wall
;; =============================================================================
(printf "[4/5] Testing Protoss doorway-corridor permanence & opening wall-slot exactness...\n")
(let ()
  ;; 4a. make-wall-reserved-aabbs ALWAYS emits doorway-corridor (>= 1.15t) even with bypass-wall-pylon? = #t!
  (define pwall-hash
    (hasheq 'pylon     (cons 54.0 34.0)
            'slot-1    (cons 57.5 31.5)
            'slot-2    (cons 57.5 34.5)
            'slot-3    (cons 57.5 37.5)
            'door      (cons 55.5 36.0)
            'door-park (cons 54.0 36.0)))
  (define bypassed-aabbs
    (make-wall-reserved-aabbs 'Protoss
                              #:protoss-matchup-wall pwall-hash
                              #:bypass-wall-pylon? #t))
  (define door-aabbs
    (filter (lambda (b) (and (reserved-aabb? b) (eq? (reserved-aabb-kind b) 'doorway-corridor)))
            bypassed-aabbs))
  (define slot-aabbs
    (filter (lambda (b) (and (reserved-aabb? b) (eq? (reserved-aabb-kind b) 'wall-slot)))
            bypassed-aabbs))
  (check-true "l87-4a-make-wall-reserved-aabbs-keeps-doorway-corridor-on-bypass"
              (and (= (length door-aabbs) 2)
                   (= (length slot-aabbs) 0)
                   (for/and ([b (in-list door-aabbs)])
                     (and (>= (reserved-aabb-half-w b) 1.15)
                          (>= (reserved-aabb-half-h b) 1.15))))
              (format "doorCount=~a slotCount=~a" (length door-aabbs) (length slot-aabbs)))

  ;; 4b. Midgame non-wall Gateway/CyberCore/Pylon NEVER plugs 1-hex natural doorway corridor
  ;;     even with shrunken 0.5x0.5 caller AABBs, occupied wall slots, and 0.5t/0.0t tight fallback!
  (define gi (mk-gi 98.0 96.0 'Zerg #:cliff-x 46))
  (define shrunken-wall-aabbs
    (list (reserved-aabb 54.0 34.0 1.0 1.0 'wall-slot 0 0)
          (reserved-aabb 57.5 31.5 1.5 1.5 'wall-slot 0 0)
          (reserved-aabb 57.5 34.5 1.5 1.5 'wall-slot 0 0)
          (reserved-aabb 57.5 37.5 1.5 1.5 'wall-slot 0 0)
          ;; Simulate runtime passing 0.5x0.5 doorway-corridor AABBs
          (reserved-aabb 55.5 36.0 0.5 0.5 'doorway-corridor 0 0)
          (reserved-aabb 54.0 36.0 0.5 0.5 'doorway-corridor 0 0)))
  (define main-nex (mk-unit 4001 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define nat-nex  (mk-unit 4002 59 1 62.5 32.5 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define wall-pyl (mk-unit 4003 60 1 54.0 34.0 #:rad 1.0))
  (define wall-gw1 (mk-unit 4004 62 1 57.5 31.5 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define wall-cc  (mk-unit 4005 72 1 57.5 34.5 #:hp 550.0 #:sh 550.0 #:rad 1.5))
  (define wall-gw2 (mk-unit 4006 62 1 57.5 37.5 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define probe-4  (mk-unit 4007 84 1 52.0 34.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
  (define ps-4     (list (sc2-power-source (sc2-point2d 54.0 34.0) 6.5 4003)))
  (define full-wall-units (list main-nex nat-nex wall-pyl wall-gw1 wall-cc wall-gw2 probe-4))

  (define (clears-door-corridor? pt hw hh)
    (and (sc2-point2d? pt)
         (let ([x (sc2-point2d-x pt)]
               [y (sc2-point2d-y pt)])
           (and (not (aabb-overlaps? x y hw hh (reserved-aabb 55.5 36.0 1.15 1.15 'doorway-corridor 0 0)))
                (not (aabb-overlaps? x y hw hh (reserved-aabb 54.0 36.0 1.15 1.15 'doorway-corridor 0 0)))))))

  ;; 4b-i: Midgame non-wall Gateway requested right on doorway (55.5, 36.0) near occupied wall slots
  (reset-wire-state! gi full-wall-units)
  (define mid-gw-cmds
    (translate-bot-actions->sc2-raw-commands '((build gateway 55.5 36.0))
                                             (mk-obs 6500 80 110 full-wall-units #:power-sources ps-4)
                                             #:game-info gi
                                             #:reserved-aabbs shrunken-wall-aabbs))
  (define mid-gw-pt (first-cmd-pt mid-gw-cmds 883))
  (check-true "l87-4b1-midgame-gateway-respects-permanent-doorway-corridor"
              (clears-door-corridor? mid-gw-pt 1.5 1.5)
              (format "pt=~a" mid-gw-pt))

  ;; 4b-ii: Tight-spacing (0.5t) direct placement near doorway MUST still enforce >= 1.15t doorway corridor!
  (define tight-gw-pt
    (find-verified-building-placement #f 883 55.5 36.0 full-wall-units
                                      #:min-spacing 0.5
                                      #:max-radius 6.5
                                      #:step 1.0
                                      #:reserved-aabbs shrunken-wall-aabbs
                                      #:power-sources ps-4
                                      #:bldg-sym 'gateway
                                      #:game-info gi))
  (check-true "l87-4b2-tight-spacing-gateway-respects-permanent-doorway-corridor"
              (clears-door-corridor? tight-gw-pt 1.5 1.5)
              (format "pt=~a" tight-gw-pt))

  ;; 4b-iii: Midgame non-wall Pylon requested near doorway MUST NOT plug doorway corridor!
  (define mid-pyl-pt
    (find-verified-building-placement #f 881 55.5 36.0 full-wall-units
                                      #:min-spacing 0.5
                                      #:max-radius 8.0
                                      #:step 1.0
                                      #:reserved-aabbs shrunken-wall-aabbs
                                      #:bldg-sym 'pylon
                                      #:game-info gi))
  (check-true "l87-4b3-midgame-pylon-respects-permanent-doorway-corridor"
              (clears-door-corridor? mid-pyl-pt 1.0 1.0)
              (format "pt=~a" mid-pyl-pt))

  ;; 4c. Opening unoccupied wall slots MUST still land at EXACT coordinates (100% wall seal preserved!)
  (define open-aabbs
    (make-wall-reserved-aabbs 'Protoss
                              #:protoss-matchup-wall pwall-hash
                              #:bypass-wall-pylon? #f))
  (define open-pyl-pt
    (find-verified-building-placement #f 881 54.0 34.0 (list main-nex nat-nex probe-4)
                                      #:min-spacing 0.0
                                      #:reserved-aabbs open-aabbs
                                      #:bldg-sym 'pylon
                                      #:game-info gi))
  (define open-s1-pt
    (find-verified-building-placement #f 883 57.5 31.5 (list main-nex nat-nex wall-pyl probe-4)
                                      #:min-spacing 0.0
                                      #:reserved-aabbs open-aabbs
                                      #:power-sources ps-4
                                      #:bldg-sym 'gateway
                                      #:game-info gi))
  (define open-s2-pt
    (find-verified-building-placement #f 894 57.5 34.5 (list main-nex nat-nex wall-pyl wall-gw1 probe-4)
                                      #:min-spacing 0.0
                                      #:reserved-aabbs open-aabbs
                                      #:power-sources ps-4
                                      #:bldg-sym 'cybernetics-core
                                      #:game-info gi))
  (define open-s3-pt
    (find-verified-building-placement #f 883 57.5 37.5 (list main-nex nat-nex wall-pyl wall-gw1 wall-cc probe-4)
                                      #:min-spacing 0.0
                                      #:reserved-aabbs open-aabbs
                                      #:power-sources ps-4
                                      #:bldg-sym 'gateway
                                      #:game-info gi))
  (check-true "l87-4c-opening-wall-slots-still-exact"
              (and (sc2-point2d? open-pyl-pt) (= (sc2-point2d-x open-pyl-pt) 54.0) (= (sc2-point2d-y open-pyl-pt) 34.0)
                   (sc2-point2d? open-s1-pt)  (= (sc2-point2d-x open-s1-pt) 57.5)  (= (sc2-point2d-y open-s1-pt) 31.5)
                   (sc2-point2d? open-s2-pt)  (= (sc2-point2d-x open-s2-pt) 57.5)  (= (sc2-point2d-y open-s2-pt) 34.5)
                   (sc2-point2d? open-s3-pt)  (= (sc2-point2d-x open-s3-pt) 57.5)  (= (sc2-point2d-y open-s3-pt) 37.5))
              (format "pyl=~a s1=~a s2=~a s3=~a" open-pyl-pt open-s1-pt open-s2-pt open-s3-pt))

  ;; 4d. Destroyed opening wall slot (slot-1 killed, slot-2 & slot-3 intact) rebuilds at exact slot-1!
  (define rebuild-s1-pt
    (find-verified-building-placement #f 883 57.5 31.5 (list main-nex nat-nex wall-pyl wall-cc wall-gw2 probe-4)
                                      #:min-spacing 0.0
                                      #:reserved-aabbs open-aabbs
                                      #:power-sources ps-4
                                      #:bldg-sym 'gateway
                                      #:game-info gi))
  (check-true "l87-4d-destroyed-wall-slot1-rebuilds-at-exact-slot"
              (and (sc2-point2d? rebuild-s1-pt)
                   (= (sc2-point2d-x rebuild-s1-pt) 57.5)
                   (= (sc2-point2d-y rebuild-s1-pt) 31.5))
              (format "pt=~a" rebuild-s1-pt)))

;; =============================================================================
;; 5. Loop 87B Track C: APM-500 SC2-UI Calibration, P0->P1 Non-Starvation,
;;    Pre-Governor Noop Suppression, Spatial Coalescing, & Spell/P2 Dedup
;; =============================================================================
(printf "[5/5] Testing APM-500 calibration, P0->P1 protection, noop suppression & micro coalescing...\n")
(let ()
  (define (gov-tokens g) (vector-ref (struct->vector g) 3))

  ;; 5a. Live ladder 500-SC2-UI-APM config: target=680.0 fast-min (~486 SC2-UI), cap=760.0 (~543 peak),
  ;;     burst=72.0, init tokens=60.0!
  (define gov680 (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 72.0))
  (check-true "l87b-5a-ladder-gov-680-cap-760-burst-72-init-60"
              (and (= (wire-apm-governor-target-apm gov680) 680.0)
                   (= (wire-apm-governor-hard-cap-apm gov680) 760.0)
                   (= (wire-apm-governor-burst-capacity gov680) 72.0)
                   (= (gov-tokens gov680) 60.0)))

  ;; 5b. P0 overdraft NEVER starves core fresh P1 macro (train/worker/supply/build)!
  ;;     Drain tokens to -4.0 via urgent P0 burst; 3 core P1 macro cmds MUST still emit with 0 P1 drops
  ;;     while tokens stays clamped >= -4.0 and rolling hard-cap is strictly respected!
  (define gov-p1 (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 6.0))
  ;; Warm up LAST-P1-LOOP at loop 996 (+4f < 8f so 1a-pre/1c overdue rescue does NOT fire!)
  (void (govern-sc2-wire-actions! gov-p1 (list (sc2-raw-unit-command 524 #f 0 '(5900) #f)) 996))
  ;; Batch at loop 1000: 5 urgent P0 survival cmds (drains tokens down to -4.0!) + 3 core P1 macro cmds
  (define p0-burst
    (for/list ([i (in-range 5)])
      (mark-urgent-survival-cmd! (sc2-raw-unit-command 407 #f (+ 5950 i) (list (+ 5910 i)) #f))))
  (define p1-core-batch
    (list (sc2-raw-unit-command 560 #f 0 '(5921) #f)  ;; Train Marine
          (sc2-raw-unit-command 524 #f 0 '(5922) #f)  ;; Train SCV
          (sc2-raw-unit-command 881 (sc2-point2d 36.0 32.0) 0 '(5923) #f))) ;; Build Pylon
  (define out-p1-prot (govern-sc2-wire-actions! gov-p1 (append p0-burst p1-core-batch) 1000))
  (define emitted-p1-abs
    (for/list ([c (in-list out-p1-prot)]
               #:when (and (sc2-raw-unit-command? c)
                           (memv (sc2-raw-unit-command-ability-id c) '(560 524 881))))
      (sc2-raw-unit-command-ability-id c)))
  (define st-p1-prot (get-wire-apm-drop-stats gov-p1))
  (check-true "l87b-5b-p0-overdraft-never-starves-core-p1-macro"
              (and (= (length emitted-p1-abs) 3)
                   (= (hash-ref (hash-ref st-p1-prot 'by_tier) 'P1 -1) 0)
                   (>= (gov-tokens gov-p1) -4.0))
              (format "emittedP1=~a p1Drops=~a tok=~a"
                      emitted-p1-abs (hash-ref (hash-ref st-p1-prot 'by_tier) 'P1 -1) (gov-tokens gov-p1)))

  ;; 5c. Relaxed P2 token floor (0.0 vs 4.0) & headroom floor (6.0 vs 12.0) at >= 500 APM!
  (define gov-hi (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 10.0))
  (define gov-lo (make-wire-apm-governor #:target-apm 495.0 #:hard-cap-apm 760.0 #:burst-capacity 10.0))
  (void (govern-sc2-wire-actions! gov-hi (list (sc2-raw-unit-command 23 (sc2-point2d 40.0 40.0) 0 '(5001) #f)) 996))
  (void (govern-sc2-wire-actions! gov-lo (list (sc2-raw-unit-command 23 (sc2-point2d 40.0 40.0) 0 '(5001) #f)) 996))
  (define p2-burst
    (for/list ([i (in-range 6)])
      (sc2-raw-unit-command 23 (sc2-point2d (+ 50.0 (* 2.0 i)) 50.0) 0 (list (+ 5010 i)) #f)))
  (define out-hi (govern-sc2-wire-actions! gov-hi p2-burst 1000))
  (define out-lo (govern-sc2-wire-actions! gov-lo p2-burst 1000))
  (define gov-hr-hi (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 14.0 #:burst-capacity 72.0))
  (define gov-hr-lo (make-wire-apm-governor #:target-apm 495.0 #:hard-cap-apm 14.0 #:burst-capacity 72.0))
  (void (govern-sc2-wire-actions! gov-hr-hi (list (sc2-raw-unit-command 23 (sc2-point2d 40.0 40.0) 0 '(5101) #f)) 1996))
  (void (govern-sc2-wire-actions! gov-hr-lo (list (sc2-raw-unit-command 23 (sc2-point2d 40.0 40.0) 0 '(5101) #f)) 1996))
  ;; Remaining headroom = 12.0: high-APM P2 floor 6.0 admits 3 cmds (6 events -> 6.0 rem), 495 floor 12.0 admits 0!
  (define out-hr-hi (govern-sc2-wire-actions! gov-hr-hi p2-burst 2000))
  (define out-hr-lo (govern-sc2-wire-actions! gov-hr-lo p2-burst 2000))
  (check-true "l87b-5c-high-apm-p2-token-0-and-headroom-6-floors"
              (and (> (length out-hi) (length out-lo))
                   (>= (gov-tokens gov-hi) 0.0)
                   (= (length out-hr-hi) 3)
                   (= (length out-hr-lo) 0))
              (format "tokHi=~a tokLo=~a hrHi=~a hrLo=~a"
                      (length out-hi) (length out-lo) (length out-hr-hi) (length out-hr-lo)))

  ;; 5d. Pre-governor _obs noop suppression eliminates redundant Attack/Move Selection+UpdateTarget churn
  ;;     with ZERO tokens spent and ZERO APM drops, while preserving kiting & target switches!
  (define gov-noop (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 72.0))
  (define stk1 (mk-unit 5201 74 1 50.0 50.0 #:orders (list (sc2-unit-order 23 #f 9001 0.0))))
  (define stk2 (mk-unit 5202 74 1 51.0 50.0 #:orders (list (sc2-unit-order 16 (sc2-point3d 60.0 60.0 10.0) 0 0.0))))
  (define noop-obs (mk-obs 3000 60 90 (list stk1 stk2)))
  (define tok-before-noop (gov-tokens gov-noop))
  ;; Duplicate attack 9001 on stk1 + duplicate move near (60.4, 60.3) on stk2 -> BOTH suppressed!
  (define out-noop
    (govern-sc2-wire-actions!
     gov-noop
     (list (sc2-raw-unit-command 23 #f 9001 '(5201) #f)
           (sc2-raw-unit-command 16 (sc2-point2d 60.4 60.3) 0 '(5202) #f))
     3000 noop-obs))
  ;; Partial tag filter: attack 9001 on (5201 5202) emits ONLY for 5202!
  ;; Target switch / kite: move (45.0, 45.0) on 5201 fires immediately!
  (define out-real
    (govern-sc2-wire-actions!
     gov-noop
     (list (sc2-raw-unit-command 23 #f 9001 '(5201 5202) #f)
           (sc2-raw-unit-command 16 (sc2-point2d 45.0 45.0) 0 '(5201) #f))
     3004 noop-obs))
  (check-true "l87b-5d-obs-noop-suppression-zero-tokens-and-preserves-kite-switch"
              (and (null? out-noop)
                   (= (gov-tokens gov-noop) (- tok-before-noop 4.0 (- (* 4.0 (/ 680.0 1344.0)))))
                   (= (hash-ref (get-wire-apm-drop-stats gov-noop) 'total -1) 0)
                   (= (length out-real) 2)
                   (equal? (sc2-raw-unit-command-unit-tags (first out-real)) '(5202))
                   (equal? (sc2-raw-unit-command-unit-tags (second out-real)) '(5201)))
              (format "outNoop=~a outReal=~a drops=~a" out-noop out-real (get-wire-apm-drop-stats gov-noop)))

  ;; 5e. Spatial 1.0t micro coalescing + 8f cross-step P2 combat repeat dedup!
  (define gov-coal (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 72.0))
  (define kite-cmds
    (list (sc2-raw-unit-command 16 (sc2-point2d 54.1 62.2) 0 '(5301) #f)
          (sc2-raw-unit-command 16 (sc2-point2d 54.3 62.4) 0 '(5302) #f)
          (sc2-raw-unit-command 16 (sc2-point2d 53.8 62.1) 0 '(5303) #f)
          (sc2-raw-unit-command 16 (sc2-point2d 54.2 61.9) 0 '(5304) #f)))
  (define out-coal1 (govern-sc2-wire-actions! gov-coal kite-cmds 4000))
  ;; Same coalesced 4-tag move 4 loops later (< 8f) -> deduped cleanly!
  (define out-coal2 (govern-sc2-wire-actions! gov-coal kite-cmds 4004))
  ;; 8 loops later (>= 8f) -> allowed again!
  (define out-coal3 (govern-sc2-wire-actions! gov-coal kite-cmds 4008))
  (check-true "l87b-5e-spatial-micro-coalesce-and-8f-p2-repeat-dedup"
              (and (= (length out-coal1) 1)
                   (equal? (sc2-raw-unit-command-unit-tags (first out-coal1)) '(5301 5302 5303 5304))
                   (null? out-coal2)
                   (= (length out-coal3) 1)
                   (= (hash-ref (get-wire-apm-drop-stats gov-coal) 'total -1) 0))
              (format "c1=~a c2=~a c3=~a" (length out-coal1) (length out-coal2) (length out-coal3)))

  ;; 5f. Tier cleanup (386 Heal & 1725 Root in P2, 386 12f dedup) + unchanged Ravager Bile (2338) 16f backoff!
  (define gov-rej (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 72.0))
  (define heal-cmd (sc2-raw-unit-command 386 #f 5499 '(5401) #f))
  (define root-cmd (sc2-raw-unit-command 1725 (sc2-point2d 50.0 50.0) 0 '(5402) #f))
  (define rav-u (mk-unit 5403 688 1 55.0 55.0 #:orders '()))
  (define bile-cmd (sc2-raw-unit-command 2338 (sc2-point2d 62.0 55.0) 0 '(5403) #f))
  (define rej-obs1 (mk-obs 5000 80 100 (list rav-u)))
  (define rej-obs2 (mk-obs 5004 80 100 (list rav-u)))
  (define rej-obs3 (mk-obs 5016 80 100 (list rav-u)))
  (define h1 (govern-sc2-wire-actions! gov-rej (list heal-cmd bile-cmd) 5000 rej-obs1))
  (define h2 (govern-sc2-wire-actions! gov-rej (list heal-cmd bile-cmd) 5004 rej-obs2))
  (define h3 (govern-sc2-wire-actions! gov-rej (list heal-cmd bile-cmd) 5016 rej-obs3))
  (check-true "l87b-5f-heal-root-p2-dedup-and-rejected-bile-backoff"
              (and (= (wire-cmd-priority-tier heal-cmd) 2)
                   (= (wire-cmd-priority-tier root-cmd) 2)
                   (= (length h1) 2)
                   (null? h2)
                   (= (length h3) 2))
              (format "h1=~a h2=~a h3=~a" (length h1) (length h2) (length h3)))

  ;; 5g. Default make-wire-apm-governor preserves 530 / 595 / 36.0 / init 30.0 defaults cleanly!
  (define gov-def (make-wire-apm-governor))
  (check-true "l87b-5g-default-governor-defaults-preserved"
              (and (= (wire-apm-governor-target-apm gov-def) 530.0)
                   (= (wire-apm-governor-hard-cap-apm gov-def) 595.0)
                   (= (wire-apm-governor-burst-capacity gov-def) 36.0)
                   (= (gov-tokens gov-def) 30.0)))

  ;; 5h. Fuzz-resilience: malformed non-unit entries ('not-a-unit) & NaN target coords in _obs/cmds never throw!
  (define gov-fuzz (make-wire-apm-governor #:target-apm 680.0 #:hard-cap-apm 760.0 #:burst-capacity 72.0))
  (define bad-obs (mk-obs 6000 50 100 (list 'not-a-unit #f 42)))
  (define fuzz-out
    (govern-sc2-wire-actions!
     gov-fuzz
     (list (sc2-raw-unit-command 23 (sc2-point2d 50.0 50.0) 0 '(6001) #f)
           (sc2-raw-unit-command 16 (sc2-point2d +nan.0 +inf.0) 0 '(6002) #f)
           (sc2-raw-unit-command 2338 (sc2-point2d 55.0 55.0) 0 '(6003) #f))
     6000 bad-obs))
  (check-true "l87b-5h-malformed-obs-units-and-nan-coords-fuzz-safe"
              (= (length fuzz-out) 3)
              (format "out=~a" (length fuzz-out))))

;; =============================================================================
;; 6. Loop 87C Version C Proxy Geometry, Nydus, Warp Prism, Cannon/Spine/Bunker
;; =============================================================================
(printf "[6/6] Testing Version C proxy geometry, Nydus, Warp Prism, Cannon/Spine/Bunker...\n")
(let ()
  (define (pt-d x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  ;; Helper: grid builders for visibility, creep, and stepped terrain height
  (define (mk-disc-grid discs [w 160] [h 160] [val 1])
    (define bs (make-bytes (* w h) 0))
    (for* ([d (in-list discs)]
           [cx (in-value (first d))]
           [cy (in-value (second d))]
           [r (in-value (third d))]
           [ix (in-range (max 0 (inexact->exact (floor (- cx r))))
                         (min w (add1 (inexact->exact (ceiling (+ cx r))))))]
           [iy (in-range (max 0 (inexact->exact (floor (- cy r))))
                         (min h (add1 (inexact->exact (ceiling (+ cy r))))))]
           #:when (<= (pt-d ix iy cx cy) r))
      (bytes-set! bs (+ ix (* iy w)) val))
    (sc2-image-grid 8 w h bs #f #t))

  (define (mk-open-gi [w 160] [h 160] #:th-fn [th-fn #f])
    (define pl-bs (make-bytes (* w h) 1))
    (define pa-bs (make-bytes (* w h) 1))
    (define th-bs (make-bytes (* w h) 128))
    (when (procedure? th-fn)
      (for* ([ix (in-range w)] [iy (in-range h)])
        (bytes-set! th-bs (+ ix (* iy w)) (th-fn ix iy))))
    (sc2-game-info
     "TestVersionCArena"
     "TestVersionCArena.SC2Map"
     '()
     (sc2-point2d (exact->inexact w) (exact->inexact h))
     (list (sc2-point2d 0.0 0.0) (sc2-point2d (exact->inexact w) (exact->inexact h)))
     (list (sc2-point2d 130.0 130.0))
     (sc2-image-grid 8 w h pl-bs #f #t)
     (sc2-image-grid 8 w h th-bs #f #t)
     (sc2-image-grid 8 w h pa-bs #f #t)))

  ;; 6a. Profile-Specific Proxy Site Geometry (lib/sc2-placement.rkt)
  (let ()
    (define-values (def-x def-y)
      (compute-off-path-proxy-site 30 30 50 30 130 130 110 130 #:proxy-profile 'default))
    (define-values (air-x air-y)
      (compute-off-path-proxy-site 30 30 50 30 130 130 110 130 #:proxy-profile 'close-air))
    (define-values (rep-x rep-y)
      (compute-off-path-proxy-site 30 30 50 30 130 130 110 130 #:proxy-profile 'reaper-cliff))
    (define-values (fwd-x fwd-y)
      (compute-off-path-proxy-site 30 30 50 30 130 130 110 130
                                   #:proxy-profile 'forward-mid
                                   #:expansion-pads (list (cons 90.0 100.0))))
    (define d-def (pt-d def-x def-y 130.0 130.0))
    (define d-air (pt-d air-x air-y 130.0 130.0))
    (define d-rep (pt-d rep-x rep-y 130.0 130.0))
    (define d-fwd (pt-d fwd-x fwd-y 130.0 130.0))
    (check-true "l87c-6a1-proxy-profiles-hit-target-distance-bands"
                (and (>= d-def 50.0)
                     (>= d-air 27.5) (<= d-air 38.5)
                     (>= d-rep 35.5) (<= d-rep 46.5)
                     (>= d-fwd 35.5) (<= d-fwd 46.5)
                     (>= (pt-d fwd-x fwd-y 90.0 100.0) 6.0))
                (format "def=~a air=~a rep=~a fwd=~a" d-def d-air d-rep d-fwd))

    ;; East 5x3 add-on clearance check on map-grids rejects spots whose East (+2.5, -0.5) is unbuildable!
    (define mg-east-blocked
      (hasheq 'width 160 'height 160
              'pathing-ref (lambda (x y) #t)
              'placement-ref (lambda (x y)
                               ;; Block East add-on strip just East of default fwd spot
                               (not (and (>= x (+ fwd-x 1.5)) (<= x (+ fwd-x 4.5))
                                         (>= y (- fwd-y 2.5)) (<= y (+ fwd-y 1.5)))))
              'height-ref (lambda (x y) 10.0)))
    (define-values (ea-x ea-y)
      (compute-off-path-proxy-site 30 30 50 30 130 130 110 130
                                   #:map-grids mg-east-blocked
                                   #:proxy-profile 'forward-mid
                                   #:require-east-addon? #t))
    (check-true "l87c-6a2-require-east-addon-avoids-blocked-east-pad"
                (and (not (and (< (abs (- ea-x fwd-x)) 1.0) (< (abs (- ea-y fwd-y)) 1.0)))
                     (>= (pt-d ea-x ea-y 130.0 130.0) 35.5)
                     (<= (pt-d ea-x ea-y 130.0 130.0) 46.5))
                (format "fwd=(~a,~a) ea=(~a,~a)" fwd-x fwd-y ea-x ea-y)))

  ;; 6b. Dual Same-Step Proxy Barracks East Add-On Non-Collision
  (let ()
    (define gi (mk-open-gi))
    (define cc (mk-unit 6100 18 1 30.0 30.0 #:hp 1500.0 #:rad 2.75))
    (define scv1 (mk-unit 6101 45 1 108.0 45.0 #:hp 45.0 #:rad 0.375))
    (define scv2 (mk-unit 6102 45 1 112.0 45.0 #:hp 45.0 #:rad 0.375))
    (define us (list cc scv1 scv2))
    (reset-wire-state! gi us)
    (define cmds
      (filter sc2-raw-unit-command?
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy barracks 110.0 45.0 6101)
                 (build-proxy barracks 110.0 45.0 6102))
               (mk-obs 1000 18 23 us)
               #:ws-conn #f #:game-info gi)))
    (define rax-cmds (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) 321)) cmds))
    (define p1 (and (>= (length rax-cmds) 1) (sc2-raw-unit-command-target-pos (first rax-cmds))))
    (define p2 (and (>= (length rax-cmds) 2) (sc2-raw-unit-command-target-pos (second rax-cmds))))
    (define (no-overlap? cx1 cy1 hw1 hh1 cx2 cy2 hw2 hh2)
      (or (>= (abs (- cx1 cx2)) (- (+ hw1 hw2) 0.05))
          (>= (abs (- cy1 cy2)) (- (+ hh1 hh2) 0.05))))
    (check-true "l87c-6b-dual-same-step-proxy-rax-keep-both-east-addons-clear"
                (and (= (length rax-cmds) 2)
                     (sc2-point2d? p1) (sc2-point2d? p2)
                     (let ([x1 (sc2-point2d-x p1)] [y1 (sc2-point2d-y p1)]
                           [x2 (sc2-point2d-x p2)] [y2 (sc2-point2d-y p2)])
                       (and (no-overlap? x1 y1 1.5 1.5 x2 y2 1.5 1.5)
                            (no-overlap? (+ x1 2.5) (- y1 0.5) 1.0 1.0 x2 y2 1.5 1.5)
                            (no-overlap? (+ x2 2.5) (- y2 0.5) 1.0 1.0 x1 y1 1.5 1.5))))
                (format "p1=~a p2=~a" p1 p2)))

  ;; 6c. Nydus Worm (1768) Visibility Gate, Spotter Steering, & NEVER Spawns at Home
  (let ()
    (define gi (mk-open-gi))
    (define main-h (mk-unit 6200 86 1 30.0 30.0 #:hp 1500.0 #:rad 2.5))
    (define nnet   (mk-unit 6201 95 1 36.0 32.0 #:hp 850.0 #:rad 1.5))
    (define drone  (mk-unit 6202 104 1 32.0 30.0 #:hp 40.0 #:rad 0.375))
    ;; Home (30,30) is Visible=2, Enemy Main (130,130) is Fog=0, NO spotter near enemy!
    (define vis-home-only (mk-disc-grid '((30.0 30.0 16.0)) 160 160 2))
    (for ([act-spec (in-list (list (cons 'build-proxy  '(build-proxy nydus-worm 130.0 130.0))
                                   (cons 'build        '(build nydus-worm 130.0 130.0))
                                   (cons 'build-nydus  '(build-nydus-worm 130.0 130.0))
                                   (cons 'cast-spell   '(cast-spell 6201 build-nydus-worm 130.0 130.0))))]
          [idx (in-naturals 0)])
      (define obs-fog (mk-obs (+ 5000 (* idx 30)) 50 70 (list main-h nnet drone)))
      (hash-set! SC2-OBS-VISIBILITY-GRIDS obs-fog vis-home-only)
      (reset-wire-state! gi (list main-h nnet drone))
      (define cmds
        (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1768)))
                (translate-bot-actions->sc2-raw-commands (list (cdr act-spec)) obs-fog #:ws-conn #f #:game-info gi)))
      (check-true (format "l87c-6c1-nydus-fogged-never-spawns-at-home-~a" (car act-spec))
                  (null? cmds)
                  (format "cmds=~a" cmds)))

    ;; Now add Overlord spotting at (116, 128) (14t from blind target (130,130)) with Visible=2 disc!
    (define ovie (mk-unit 6205 106 1 116.0 128.0 #:hp 200.0 #:rad 1.0 #:flying? #t))
    (define vis-with-ovie (mk-disc-grid '((30.0 30.0 16.0) (116.0 128.0 10.0)) 160 160 2))
    (for ([act-spec (in-list (list (cons 'build-proxy  '(build-proxy nydus-worm 130.0 130.0))
                                   (cons 'build        '(build nydus-worm 130.0 130.0))
                                   (cons 'build-nydus  '(build-nydus-worm 130.0 130.0))
                                   (cons 'cast-spell   '(cast-spell 6201 build-nydus-worm 130.0 130.0))))]
          [idx (in-naturals 0)])
      (define obs-ov (mk-obs (+ 5300 (* idx 30)) 50 70 (list main-h nnet drone ovie)))
      (hash-set! SC2-OBS-VISIBILITY-GRIDS obs-ov vis-with-ovie)
      (reset-wire-state! gi (list main-h nnet drone ovie))
      (define cmds
        (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1768)))
                (translate-bot-actions->sc2-raw-commands (list (cdr act-spec)) obs-ov #:ws-conn #f #:game-info gi)))
      (define wpt (and (= (length cmds) 1) (sc2-raw-unit-command-target-pos (first cmds))))
      (check-true (format "l87c-6c2-nydus-steers-to-overlord-vision-~a" (car act-spec))
                  (and (sc2-point2d? wpt)
                       (= (sc2-grid-ref vis-with-ovie (sc2-point2d-x wpt) (sc2-point2d-y wpt)) 2)
                       (<= (pt-d (sc2-point2d-x wpt) (sc2-point2d-y wpt) 116.0 128.0) 11.0)
                       (> (pt-d (sc2-point2d-x wpt) (sc2-point2d-y wpt) 30.0 30.0) 80.0))
                  (format "wpt=~a" wpt))))

  ;; 6d. Warp Prism Forward Warp-In Priority, Anti-Demotion, 8-Gate Batching, & Wrong-Polarity Morph Guard
  (let ()
    (define gi (mk-open-gi))
    (define nx  (mk-unit 6300 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
    (define pyl (mk-unit 6301 60 1 34.0 34.0 #:hp 200.0 #:sh 200.0 #:rad 1.0))
    (define wgs (for/list ([i (in-range 8)])
                  (mk-unit (+ 6310 i) 133 1 (+ 36.0 (* i 2.0)) 30.0 #:hp 500.0 #:sh 500.0 #:rad 1.5)))
    (define wpp (mk-unit 6320 136 1 100.0 100.0 #:hp 80.0 #:sh 100.0 #:rad 1.0 #:flying? #t))
    (define wpt-mob (mk-unit 6321 81 1 95.0 95.0 #:hp 80.0 #:sh 100.0 #:rad 1.0 #:flying? #t))
    (define ps-list
      (list (sc2-power-source (sc2-point3d 34.0 34.0 10.0) 6.5 6301)
            (sc2-power-source (sc2-point3d 100.0 100.0 10.0) 3.75 6320)))
    ;; 1 enemy Queen (126, AA!) within 5t of Prism -> MUST NOT demote Prism!
    (define one-queen (mk-unit 6390 126 4 105.0 100.0 #:hp 175.0 #:rad 0.875))
    (define units-1q (append (list nx pyl wpp) wgs (list one-queen)))
    (reset-wire-state! gi units-1q)
    (define cmds-8g
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413)))
              (translate-bot-actions->sc2-raw-commands
               (make-list 8 '(train zealot))
               (mk-obs 6000 50 80 units-1q #:power-sources ps-list)
               #:ws-conn #f #:game-info gi #:enemy-base '(130.0 130.0))))
    (define pts-8g (map sc2-raw-unit-command-target-pos cmds-8g))
    (define all-near-prism?
      (and (= (length pts-8g) 8)
           (for/and ([p (in-list pts-8g)])
             (and (sc2-point2d? p)
                  (<= (pt-d (sc2-point2d-x p) (sc2-point2d-y p) 100.0 100.0) 3.26)))))
    (define all-separated?
      (for/and ([i (in-range (length pts-8g))])
        (define pi (list-ref pts-8g i))
        (for/and ([j (in-range (add1 i) (length pts-8g))])
          (define pj (list-ref pts-8g j))
          (> (pt-d (sc2-point2d-x pi) (sc2-point2d-y pi) (sc2-point2d-x pj) (sc2-point2d-y pj)) 1.14))))
    (check-true "l87c-6d1-8gate-train-zealot-warps-all-8-at-phasing-prism-even-with-1-queen"
                (and all-near-prism? all-separated?)
                (format "cnt=~a near=~a sep=~a" (length pts-8g) all-near-prism? all-separated?))

    ;; Home under direct attack (enemy <= 16t of home) -> warps at home Pylon (34, 34)!
    (define home-raider (mk-unit 6391 105 4 38.0 32.0 #:hp 35.0 #:rad 0.375))
    (define units-home-atk (append (list nx pyl wpp) wgs (list home-raider)))
    (reset-wire-state! gi units-home-atk)
    (define cmds-def
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413)))
              (translate-bot-actions->sc2-raw-commands
               '((train zealot))
               (mk-obs 6100 50 80 units-home-atk #:power-sources ps-list)
               #:ws-conn #f #:game-info gi #:enemy-base '(130.0 130.0))))
    (define def-pt (and (= (length cmds-def) 1) (sc2-raw-unit-command-target-pos (first cmds-def))))
    (check-true "l87c-6d2-home-under-attack-warps-at-home-pylon"
                (and (sc2-point2d? def-pt)
                     (<= (pt-d (sc2-point2d-x def-pt) (sc2-point2d-y def-pt) 34.0 34.0) 6.5))
                (format "def-pt=~a" def-pt))

    ;; Heavy AA (>= 2 Queens within 7t of Prism) -> demotes Prism and falls back to home Pylon!
    (define q1 (mk-unit 6392 126 4 104.0 100.0 #:hp 175.0 #:rad 0.875))
    (define q2 (mk-unit 6393 126 4 96.0 100.0 #:hp 175.0 #:rad 0.875))
    (define units-2q (append (list nx pyl wpp) wgs (list q1 q2)))
    (reset-wire-state! gi units-2q)
    (define cmds-2q
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413)))
              (translate-bot-actions->sc2-raw-commands
               '((train zealot))
               (mk-obs 6200 50 80 units-2q #:power-sources ps-list)
               #:ws-conn #f #:game-info gi #:enemy-base '(130.0 130.0))))
    (define q2-pt (and (= (length cmds-2q) 1) (sc2-raw-unit-command-target-pos (first cmds-2q))))
    (check-true "l87c-6d3-heavy-aa-2-queens-demotes-prism-to-home-pylon"
                (and (sc2-point2d? q2-pt)
                     (<= (pt-d (sc2-point2d-x q2-pt) (sc2-point2d-y q2-pt) 34.0 34.0) 6.5))
                (format "q2-pt=~a" q2-pt))

    ;; Wrong-polarity Prism morph guard: 1528 only on utype=81, 1530 only on utype=136!
    (define units-morph (list nx pyl wpp wpt-mob))
    (reset-wire-state! gi units-morph)
    (define cmds-morph
      (filter sc2-raw-unit-command?
              (translate-bot-actions->sc2-raw-commands
               '((cast-spell 6320 morph-warp-prism-phasing 6320)   ;; WRONG: 6320 is already 136!
                 (cast-spell 6321 morph-warp-prism-transport 6321) ;; WRONG: 6321 is already 81!
                 (cast-spell 6321 morph-warp-prism-phasing 6321)   ;; VALID: 81 -> 1528
                 (cast-spell 6320 morph-warp-prism-transport 6320));; VALID: 136 -> 1530
               (mk-obs 6300 50 80 units-morph)
               #:ws-conn #f #:game-info gi)))
    (define m1528 (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) 1528)) cmds-morph))
    (define m1530 (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) 1530)) cmds-morph))
    (check-true "l87c-6d4-wrong-polarity-prism-morphs-filtered"
                (and (= (length m1528) 1) (equal? (sc2-raw-unit-command-unit-tags (first m1528)) '(6321))
                     (= (length m1530) 1) (equal? (sc2-raw-unit-command-unit-tags (first m1530)) '(6320)))
                (format "m1528=~a m1530=~a" m1528 m1530)))

  ;; 6e. Cannon Rush Terrain-Height Power Rule & Destroyed Proxy Pylon Rotation + Spacing
  (let ()
    ;; Low ground x < 102 (th=128), High ground x >= 102 (th=144)
    (define gi-cliff (mk-open-gi #:th-fn (lambda (x y) (if (>= x 102) 144 128))))
    (define nx  (mk-unit 6400 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
    (define prb (mk-unit 6401 84 1 100.0 98.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
    (define low-pyl (mk-unit 6402 60 1 100.0 100.0 #:hp 200.0 #:sh 200.0 #:rad 1.0))
    (define low-ps  (list (sc2-power-source (sc2-point3d 100.0 100.0 10.0) 6.5 6402)))
    (reset-wire-state! gi-cliff (list nx prb low-pyl))
    ;; Request Cannon at high-ground (104, 100): low-ground Pylon MUST place Cannon on low ground (x < 102)!
    (define cmds-can
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 887)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy photon-cannon 104.0 100.0 6401))
               (mk-obs 7000 30 40 (list nx prb low-pyl) #:power-sources low-ps)
               #:ws-conn #f #:game-info gi-cliff)))
    (define cpt (and (= (length cmds-can) 1) (sc2-raw-unit-command-target-pos (first cmds-can))))
    (check-true "l87c-6e1-low-ground-pylon-never-places-cannon-on-high-ground"
                (and (sc2-point2d? cpt)
                     (< (sc2-point2d-x cpt) 102.0)
                     (<= (pt-d (sc2-point2d-x cpt) (sc2-point2d-y cpt) 100.0 100.0) 6.5))
                (format "cpt=~a" cpt))

    ;; Proxy Pylon spacing >= 4.5t from existing live proxy Pylon + 448f rotation after destruction!
    (define gi-flat (mk-open-gi))
    (define p-live (mk-unit 6410 60 1 115.0 115.0 #:hp 200.0 #:sh 200.0 #:rad 1.0))
    (define p-prb  (mk-unit 6411 84 1 114.0 112.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
    (reset-wire-state! gi-flat (list nx p-live p-prb))
    ;; Step 1 (loop 7100): p-live exists at (115, 115) -> Pylon #2 must space >= 4.5t away!
    (define cmds-p2
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy pylon 115.0 115.0 6411))
               (mk-obs 7100 30 40 (list nx p-live p-prb))
               #:ws-conn #f #:game-info gi-flat)))
    (define p2-pt (and (= (length cmds-p2) 1) (sc2-raw-unit-command-target-pos (first cmds-p2))))
    ;; Step 2 (loop 7160): p-live was destroyed (removed from units!) -> retry MUST rotate > 2.5t off (115, 115)!
    (define cmds-rot
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy pylon 115.0 115.0 6411))
               (mk-obs 7160 30 40 (list nx p-prb))
               #:ws-conn #f #:game-info gi-flat)))
    (define rot-pt (and (= (length cmds-rot) 1) (sc2-raw-unit-command-target-pos (first cmds-rot))))
    (check-true "l87c-6e2-proxy-pylon-spacing-and-destroyed-cell-rotation"
                (and (sc2-point2d? p2-pt)
                     (>= (pt-d (sc2-point2d-x p2-pt) (sc2-point2d-y p2-pt) 115.0 115.0) 4.45)
                     (hash-has-key? SC2-PLACEMENT-NEG-COOLDOWN '(failed-cell proxy-pylon 115 115))
                     (sc2-point2d? rot-pt)
                     (> (pt-d (sc2-point2d-x rot-pt) (sc2-point2d-y rot-pt) 115.0 115.0) 2.5))
                (format "p2=~a rot=~a" p2-pt rot-pt)))

  ;; 6f. Proxy Spine Enemy-Creep Recovery + Fog Move + Proxy Bunker Creep-Edge Stand-Off
  (let ()
    (define gi (mk-open-gi))
    (define main-h (mk-unit 6500 86 1 30.0 30.0 #:hp 1500.0 #:rad 2.5))
    (define pdrone (mk-unit 6501 104 1 112.0 110.0 #:hp 40.0 #:rad 0.375))
    (define ehatch (mk-unit 6550 86 4 130.0 130.0 #:hp 1500.0 #:rad 2.5))
    ;; 1-base ZvZ: ZERO creep at Nat (112, 112), live creep ONLY at enemy Main (130, 130) r=9!
    (define creep-main-only (mk-disc-grid '((30.0 30.0 10.0) (130.0 130.0 9.0)) 160 160 1))
    (define obs-sp1 (mk-obs 8000 16 20 (list main-h pdrone ehatch)))
    (hash-set! SC2-OBS-CREEP-GRIDS obs-sp1 creep-main-only)
    (reset-wire-state! gi (list main-h pdrone ehatch))
    (define cmds-sp1
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1166)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy spine-crawler 112.0 112.0 6501))
               obs-sp1 #:ws-conn #f #:game-info gi #:enemy-base '(130.0 130.0))))
    (define sp1-pt (and (= (length cmds-sp1) 1) (sc2-raw-unit-command-target-pos (first cmds-sp1))))
    (check-true "l87c-6f1-proxy-spine-recovers-onto-enemy-main-creep-when-nat-bare"
                (and (sc2-point2d? sp1-pt)
                     (<= (pt-d (sc2-point2d-x sp1-pt) (sc2-point2d-y sp1-pt) 130.0 130.0) 10.0)
                     (> (pt-d (sc2-point2d-x sp1-pt) (sc2-point2d-y sp1-pt) 30.0 30.0) 80.0))
                (format "sp1=~a" sp1-pt))

    ;; Fogged enemy base (vis=0 at Nat & Main, creep=0 there) -> emits Move (16) for proxy Drone!
    (define creep-home-only (mk-disc-grid '((30.0 30.0 10.0)) 160 160 1))
    (define vis-home-only   (mk-disc-grid '((30.0 30.0 16.0)) 160 160 2))
    (define obs-sp-fog (mk-obs 8100 16 20 (list main-h pdrone)))
    (hash-set! SC2-OBS-CREEP-GRIDS obs-sp-fog creep-home-only)
    (hash-set! SC2-OBS-VISIBILITY-GRIDS obs-sp-fog vis-home-only)
    (reset-wire-state! gi (list main-h pdrone))
    (define cmds-sp-fog
      (filter sc2-raw-unit-command?
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy spine-crawler 112.0 112.0 6501))
               obs-sp-fog #:ws-conn #f #:game-info gi #:enemy-base '(130.0 130.0))))
    (check-true "l87c-6f2-proxy-spine-fogged-moves-drone-to-reveal-creep"
                (and (= (length cmds-sp-fog) 1)
                     (= (sc2-raw-unit-command-ability-id (first cmds-sp-fog)) 16)
                     (equal? (sc2-raw-unit-command-unit-tags (first cmds-sp-fog)) '(6501)))
                (format "cmds=~a" cmds-sp-fog))

    ;; Proxy Bunker creep-edge stand-off: enemy Nat Hatch at (118, 112) with r=5.5 creep;
    ;; suicidal request at (114, 112) (4.0t!) -> MUST land off-creep in 6.3..8.8t stand-off range!
    (define cc   (mk-unit 6600 18 1 30.0 30.0 #:hp 1500.0 #:rad 2.75))
    (define pscv (mk-unit 6601 45 1 110.0 110.0 #:hp 45.0 #:rad 0.375))
    (define enat (mk-unit 6650 86 4 118.0 112.0 #:hp 1500.0 #:rad 2.5))
    (define enat-creep (mk-disc-grid '((118.0 112.0 5.5)) 160 160 1))
    (define obs-bnk (mk-obs 8200 20 25 (list cc pscv enat)))
    (hash-set! SC2-OBS-CREEP-GRIDS obs-bnk enat-creep)
    (reset-wire-state! gi (list cc pscv enat))
    (define cmds-bnk
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 324)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy bunker 114.0 112.0 6601))
               obs-bnk #:ws-conn #f #:game-info gi #:enemy-base '(130.0 130.0))))
    (define bpt (and (= (length cmds-bnk) 1) (sc2-raw-unit-command-target-pos (first cmds-bnk))))
    (define bd (and (sc2-point2d? bpt) (pt-d (sc2-point2d-x bpt) (sc2-point2d-y bpt) 118.0 112.0)))
    (check-true "l87c-6f3-proxy-bunker-lands-off-creep-in-standoff-range"
                (and (sc2-point2d? bpt)
                     (>= bd 6.3) (<= bd 8.8)
                     (= (sc2-grid-ref enat-creep (sc2-point2d-x bpt) (sc2-point2d-y bpt)) 0))
                (format "bpt=~a dist=~a" bpt bd))))

;; =============================================================================
;; 7. Loop 87D Map-Analysis Cheese Spot Solvers & Wire Tight Wall-Pylon Allowance
;; =============================================================================
(printf "[7/7] Testing Loop 87D map-analysis cheese spot solvers & tight 3-pylon wall wire...\n")
(let ()
  (define (pt-d x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

  (define (mk-grid w h fn)
    (define bs (make-bytes (* w h) 0))
    (for* ([ix (in-range w)] [iy (in-range h)])
      (bytes-set! bs (+ ix (* iy w)) (fn ix iy)))
    (sc2-image-grid 8 w h bs #f #t))

  ;; 7a. 3-Pylon 0-Gap Cannon Wall against a straight cliff behind enemy natural!
  ;;     Enemy Nat at (100, 100), cliff wall runs horizontally along y >= 106 (unpathable/unbuildable),
  ;;     open ground below y < 106 -> Cannon at y=105 against cliff needs 3 Pylons (W, S, E) for 0 gaps!
  (let ()
    (define pl-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 6) (< x 154) (>= y 6) (< y 106)) 1 0))))
    (define pa-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 6) (< x 154) (>= y 6) (< y 106)) 1 0))))
    (define th-g (mk-grid 160 160 (lambda (x y) (if (>= y 106) 144 128))))
    (define spots
      (solve-cannon-rush-wall-spots pl-g pa-g th-g '(130.0 . 130.0) '(100.0 . 100.0) '(30.0 . 30.0)))
    (define best (and (pair? spots) (first spots)))
    (define cpt (and best (hash-ref best 'cannon-pt #f)))
    (define ppts (and best (hash-ref best 'pylon-pts '())))
    (define bpt (and best (hash-ref best 'battery-pt #f)))
    (check-true "l87d-7a-cannon-3pylon-wall-achieves-zero-seal-gaps-and-battery"
                (and (hash? best)
                     (eq? (hash-ref best 'target-kind #f) 'nat)
                     (= (hash-ref best 'seal-gaps -1) 0)
                     (= (length ppts) 3)
                     (pair? cpt)
                     (<= (pt-d (car cpt) (cdr cpt) 100.0 100.0) 9.5)
                     (pair? bpt)
                     (<= (pt-d (car bpt) (cdr bpt) (car (first ppts)) (cdr (first ppts))) 6.0))
                (format "best=~a" best)))

  ;; 7b. 2-Pylon + Mineral/Cliff Corner 0-Gap Seal (prefers 1-2 Pylons over 3 when corner/minerals seal 2 sides!)
  (let ()
    ;; Cliff on North (y >= 107) AND West (x <= 93) forming an L-corner beside Nat (100, 100),
    ;; with mineral patches at (95, 106) and (97, 106) sealing the North edge cleanly!
    (define pl-g (mk-grid 160 160 (lambda (x y) (if (and (> x 93) (< x 154) (>= y 6) (< y 107)) 1 0))))
    (define pa-g (mk-grid 160 160 (lambda (x y) (if (and (> x 93) (< x 154) (>= y 6) (< y 107)) 1 0))))
    (define th-g (mk-grid 160 160 (lambda (x y) 128)))
    (define nat-mins (list (cons 95.0 106.0) (cons 97.0 106.0)))
    (define spots
      (solve-cannon-rush-wall-spots pl-g pa-g th-g '(130.0 . 130.0) '(100.0 . 100.0) '(30.0 . 30.0)
                                    #:minerals nat-mins))
    (define best (and (pair? spots) (first spots)))
    (define ppts (and best (hash-ref best 'pylon-pts '())))
    (check-true "l87d-7b-cannon-2pylon-mineral-cliff-corner-seal"
                (and (hash? best)
                     (= (hash-ref best 'seal-gaps -1) 0)
                     (<= (length ppts) 2)
                     (>= (length ppts) 1))
                (format "best=~a" best)))

  ;; 7c. Hidden Proxy Site Solver: HARD sightline invariant d-nat >= 22t, d-main >= 24t, perp >= 16t!
  (let ()
    ;; Open 160x160 map with dead-air border around edges (x <= 10 or x >= 150 or y <= 10 or y >= 150)
    ;; and a cliff ridge around enemy main (x >= 112 and y >= 112 at height 144 vs low ground 128)
    (define pl-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 12) (< x 148) (>= y 12) (< y 148)) 1 0))))
    (define pa-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 12) (< x 148) (>= y 12) (< y 148)) 1 0))))
    (define th-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 112) (>= y 112)) 144 128))))
    (define mg (hash 'width 160 'height 160 'placement-grid pl-g 'pathing-grid pa-g 'terrain-height th-g))
    (define air-res
      (solve-hidden-proxy-site mg mg mg '(130.0 . 130.0) '(108.0 . 124.0) '(30.0 . 30.0)
                               #:proxy-profile 'close-air))
    (define rep-res
      (solve-hidden-proxy-site pl-g pa-g th-g '(130.0 . 130.0) '(108.0 . 124.0) '(30.0 . 30.0)
                               #:proxy-profile 'reaper-cliff
                               #:require-east-addon? #t))
    (define hid-res
      (solve-hidden-proxy-site pl-g pa-g th-g '(130.0 . 130.0) '(108.0 . 124.0) '(30.0 . 30.0)
                               #:proxy-profile 'hidden-prod
                               #:all-expansions (list '(90.0 . 110.0) '(120.0 . 80.0))))
    (define (check-hidden-invariants r min-m max-m)
      (and (hash? r)
           (pair? (hash-ref r 'proxy-pt #f))
           (>= (hash-ref r 'd-nat 0.0) 22.0)
           (>= (hash-ref r 'd-main 0.0) min-m)
           (<= (hash-ref r 'd-main 999.0) max-m)))
    (define air-bat (and (hash? air-res) (hash-ref air-res 'battery-pt #f)))
    (check-true "l87d-7c-hidden-proxy-enforces-dnat-22-and-close-air-battery"
                (and (check-hidden-invariants air-res 28.0 42.0)
                     (pair? air-bat)
                     (>= (pt-d (car air-bat) (cdr air-bat) 130.0 130.0) 22.0)
                     (<= (pt-d (car air-bat) (cdr air-bat) 130.0 130.0) 28.0)
                     (>= (pt-d (car air-bat) (cdr air-bat) 108.0 124.0) 18.0)
                     (check-hidden-invariants rep-res 36.0 48.0)
                     (check-hidden-invariants hid-res 38.0 50.0))
                (format "air=~a rep=~a hid=~a" air-res rep-res hid-res)))

  ;; 7d. Nydus Main-Plateau Corner + Safe Dead-Air Overlord Perch Solver
  (let ()
    ;; Enemy Main plateau is [110..144] x [110..144] (height 144), surrounded by dead-air at x>=145 / y>=145!
    ;; Low ground is x < 110 or y < 110 (height 128), enemy Nat at (96, 124).
    (define pl-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 10) (< x 145) (>= y 10) (< y 145)) 1 0))))
    (define pa-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 10) (< x 145) (>= y 10) (< y 145)) 1 0))))
    (define th-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 110) (>= y 110)) 144 128))))
    (define nres
      (solve-nydus-main-corner-spot pl-g pa-g th-g '(128.0 . 128.0) '(96.0 . 124.0)
                                    #:minerals (list '(135.0 . 128.0) '(135.0 . 130.0))))
    (define wpt (and (hash? nres) (hash-ref nres 'worm-pt #f)))
    (define opt (and (hash? nres) (hash-ref nres 'overlord-perch-pt #f)))
    (define d-wo (and wpt opt (pt-d (car wpt) (cdr wpt) (car opt) (cdr opt))))
    (check-true "l87d-7d-nydus-main-corner-plateau-and-dead-air-overlord-perch"
                (and (pair? wpt) (pair? opt)
                     (>= (pt-d (car wpt) (cdr wpt) 128.0 128.0) 12.0)
                     (= (sc2-grid-ref th-g (car wpt) (cdr wpt)) 144)
                     (>= d-wo 5.4) (<= d-wo 7.6)
                     (= (sc2-grid-ref pa-g (car opt) (cdr opt)) 0)
                     (= (sc2-grid-ref pl-g (car opt) (cdr opt)) 0))
                (format "nres=~a d-wo=~a" nres d-wo)))

  ;; 7e. Choke-Backed Proxy Bunker & Creep-Backed Proxy Spine Solvers
  (let ()
    ;; Nat at (105, 110), cliff ridge running along y >= 115 (unpathable), creep radius 5.5 around Nat,
    ;; our Main at (30, 30) -> Bunker must sit off-creep in 6.5..8.5t backed by the cliff!
    (define pl-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 6) (< x 154) (>= y 6) (< y 115)) 1 0))))
    (define pa-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 6) (< x 154) (>= y 6) (< y 115)) 1 0))))
    (define th-g (mk-grid 160 160 (lambda (x y) 128)))
    (define cr-g (mk-grid 160 160 (lambda (x y) (if (<= (pt-d x y 105.0 110.0) 5.5) 1 0))))
    (define bpt (solve-bunker-choke-spot pl-g pa-g th-g cr-g '(130.0 . 130.0) '(105.0 . 110.0) '(30.0 . 30.0)))
    (define spt (solve-spine-creep-spot pl-g pa-g cr-g '(130.0 . 130.0) '(105.0 . 110.0) '(30.0 . 30.0)))
    ;; Fallback Spine test: ZERO creep at Nat, creep ONLY at enemy Main (130, 105) r=10
    (define cr-main (mk-grid 160 160 (lambda (x y) (if (<= (pt-d x y 130.0 105.0) 10.0) 1 0))))
    (define spt-main (solve-spine-creep-spot pl-g pa-g cr-main '(130.0 . 105.0) '(105.0 . 110.0) '(30.0 . 30.0)))
    (check-true "l87d-7e-bunker-choke-and-spine-creep-solvers"
                (and (pair? bpt)
                     (>= (pt-d (car bpt) (cdr bpt) 105.0 110.0) 6.5)
                     (<= (pt-d (car bpt) (cdr bpt) 105.0 110.0) 8.5)
                     (= (sc2-grid-ref cr-g (car bpt) (cdr bpt)) 0)
                     (>= (cdr bpt) 111.0) ;; backed up near the y=115 cliff!
                     (pair? spt)
                     (>= (pt-d (car spt) (cdr spt) 105.0 110.0) 3.0)
                     (<= (pt-d (car spt) (cdr spt) 105.0 110.0) 6.0)
                     (= (sc2-grid-ref cr-g (car spt) (cdr spt)) 1)
                     (pair? spt-main)
                     (<= (pt-d (car spt-main) (cdr spt-main) 130.0 105.0) 16.0)
                     (= (sc2-grid-ref cr-main (car spt-main) (cdr spt-main)) 1))
                (format "bpt=~a spt=~a spt-main=~a" bpt spt spt-main)))

  ;; 7f. Wire Tight Wall-Pylon Allowance (2.0..4.5t exact sealing) + obs 'map-grids 'creep-ref!
  (let ()
    (define pl-g (mk-grid 160 160 (lambda (x y) 1)))
    (define pa-g (mk-grid 160 160 (lambda (x y) 1)))
    (define th-g (mk-grid 160 160 (lambda (x y) 128)))
    (define cr-g (mk-grid 160 160 (lambda (x y) (if (<= (pt-d x y 105.0 110.0) 5.0) 1 0))))
    (define gi
      (sc2-game-info "TestWallPylon" "TestWallPylon.SC2Map" '()
                     (sc2-point2d 160.0 160.0)
                     (list (sc2-point2d 0.0 0.0) (sc2-point2d 160.0 160.0))
                     (list (sc2-point2d 130.0 130.0))
                     pa-g th-g pl-g))
    (define nx  (mk-unit 7000 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
    (define prb (mk-unit 7001 84 1 100.0 96.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
    (define p1  (mk-unit 7002 60 1 100.0 100.0 #:hp 200.0 #:sh 200.0 #:rad 1.0))
    (define can (mk-unit 7003 66 1 102.0 100.0 #:hp 150.0 #:sh 150.0 #:rad 1.0))
    ;; Deliberate Wall Pylon #2 at (102, 98) (d=2.83 from p1) & Wall Pylon #3 at (104, 100) (d=4.0 from p1)
    (define us (list nx prb p1 can))
    (reset-wire-state! gi us)
    (define obs-w (mk-obs 9000 20 30 us))
    (hash-set! SC2-OBS-CREEP-GRIDS obs-w cr-g)
    (define rt-hash (sc2-observation->runtime-obs-hash obs-w #:game-info gi #:configured-race 'Protoss #:our-player-id 1))
    (define mg (hash-ref rt-hash 'map-grids #f))
    (define cmds-wp2
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy pylon 102.0 98.0 7001))
               obs-w #:ws-conn #f #:game-info gi)))
    (define wp2-pt (and (= (length cmds-wp2) 1) (sc2-raw-unit-command-target-pos (first cmds-wp2))))
    ;; Duplicate re-drop on exact (100, 100) MUST still space >= 4.5t!
    (define cmds-dup
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881)))
              (translate-bot-actions->sc2-raw-commands
               '((build-proxy pylon 100.0 100.0 7001))
               (mk-obs 9040 20 30 us) #:ws-conn #f #:game-info gi)))
    (define dup-pt (and (= (length cmds-dup) 1) (sc2-raw-unit-command-target-pos (first cmds-dup))))
    (check-true "l87d-7f-wire-tight-wall-pylon-exact-and-creep-ref-in-map-grids"
                (and (sc2-point2d? wp2-pt)
                     (= (sc2-point2d-x wp2-pt) 102.0)
                     (= (sc2-point2d-y wp2-pt) 98.0)
                     (sc2-point2d? dup-pt)
                     (>= (pt-d (sc2-point2d-x dup-pt) (sc2-point2d-y dup-pt) 100.0 100.0) 4.45)
                     (hash? mg)
                     (procedure? (hash-ref mg 'creep-ref #f))
                     (= ((hash-ref mg 'creep-ref) 105 110) 1)
                     (= ((hash-ref mg 'creep-ref) 30 30) 0))
                (format "wp2=~a dup=~a hasCreepRef=~a" wp2-pt dup-pt (and (hash? mg) (procedure? (hash-ref mg 'creep-ref #f))))))

  ;; 7g. Loop 87E: Cannon Wall hard range (<= 13.5t Nat OR <= 18.5t Main), non-overlap, & height power guard
  (let ()
    ;; Map where ONLY mid-map (55..85, 55..85) is buildable (> 25t from both enemy-main & enemy-nat)
    (define pl-far (mk-grid 160 160 (lambda (x y) (if (and (>= x 55) (<= x 85) (>= y 55) (<= y 85)) 1 0))))
    (define pa-far pl-far)
    (define th-far (mk-grid 160 160 (lambda (x y) 128)))
    (define far-spots
      (solve-cannon-rush-wall-spots pl-far pa-far th-far '(130.0 . 130.0) '(105.0 . 120.0) '(30.0 . 30.0)))
    ;; Wide-nat map (enemy-nat 45t from enemy-main): EVERY returned spot MUST satisfy <= 13.5t Nat OR <= 18.5t Main!
    (define pl-open (mk-grid 160 160 (lambda (x y) (if (and (>= x 6) (< x 154) (>= y 6) (< y 140)) 1 0))))
    (define pa-open pl-open)
    (define th-step (mk-grid 160 160 (lambda (x y) (if (and (>= x 118) (>= y 118)) 144 128))))
    (define wide-spots
      (solve-cannon-rush-wall-spots pl-open pa-open th-step '(130.0 . 130.0) '(88.0 . 112.0) '(30.0 . 30.0)))
    (define all-invariants-ok?
      (and (pair? wide-spots)
           (for/and ([sp (in-list wide-spots)])
             (define cp (hash-ref sp 'cannon-pt))
             (define pps (hash-ref sp 'pylon-pts))
             (define p1 (first pps))
             (and (or (<= (pt-d (car cp) (cdr cp) 88.0 112.0) 13.5)
                      (<= (pt-d (car cp) (cdr cp) 130.0 130.0) 18.5))
                  (<= (sc2-grid-ref th-step (car cp) (cdr cp))
                      (+ (sc2-grid-ref th-step (car p1) (cdr p1)) 4))
                  (for/and ([pp (in-list pps)])
                    (>= (pt-d (car cp) (cdr cp) (car pp) (cdr pp)) 2.0))))))
    (check-true "l87e-7g-cannon-wall-enforces-hard-range-nonoverlap-and-height"
                (and (null? far-spots) all-invariants-ok?)
                (format "farLen=~a wideLen=~a ok=~a" (length far-spots) (length wide-spots) all-invariants-ok?)))

  ;; 7h. Loop 87E: Hidden Proxy infers enemy-nat from all-expansions when enemy-nat is #f or == enemy-main
  ;;     and strictly enforces d-nat >= 20.0t on proxy-pt AND >= 18.0t on close-air battery-pt!
  (let ()
    (define pl-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 12) (< x 148) (>= y 12) (< y 148)) 1 0))))
    (define pa-g pl-g)
    (define th-g (mk-grid 160 160 (lambda (x y) (if (and (>= x 112) (>= y 112)) 144 128))))
    (define exps (list '(108.0 . 124.0) '(90.0 . 110.0) '(120.0 . 80.0)))
    (define res-false
      (solve-hidden-proxy-site pl-g pa-g th-g '(130.0 . 130.0) #f '(30.0 . 30.0)
                               #:proxy-profile 'close-air #:all-expansions exps))
    (define res-same
      (solve-hidden-proxy-site pl-g pa-g th-g '(130.0 . 130.0) '(130.0 . 130.0) '(30.0 . 30.0)
                               #:proxy-profile 'close-air #:all-expansions exps))
    (define (ok-inferred? r)
      (and (hash? r)
           (let ([pp (hash-ref r 'proxy-pt #f)]
                 [bp (hash-ref r 'battery-pt #f)])
             (and (pair? pp)
                  (>= (pt-d (car pp) (cdr pp) 108.0 124.0) 20.0)
                  (>= (hash-ref r 'd-nat 0.0) 20.0)
                  (or (not bp)
                      (>= (pt-d (car bp) (cdr bp) 108.0 124.0) 18.0))))))
    (check-true "l87e-7h-hidden-proxy-infers-enemy-nat-and-blocks-close-exposure"
                (and (ok-inferred? res-false) (ok-inferred? res-same))
                (format "resFalse=~a resSame=~a" res-false res-same)))

  ;; 7i. Loop 87F: Ground-pathing BFS distance helper (`placement-ground-bfs-dist-grid` &
  ;;     `placement-ground-dist-to-targets`) rejects Euclidean-closer back-cliff pocket bases
  ;;     in favor of the true walking-distance natural, unblocks 5x5 StartRaw TH pads, supports
  ;;     O(1) `#:bfs` reuse, and guides `solve-hidden-proxy-site` natural auto-inference!
  (let ()
    ;; 160x160 map: enemy main at (130, 120) with a 5x5 unpathable StartRaw TH pad [128..132]x[118..122].
    ;; A solid horizontal cliff wall at y in [127..131] for x >= 50 separates enemy main from a
    ;; back-cliff pocket expansion at (130, 140) (Euclidean=20t, but walking around x=49 takes >170t!).
    ;; True natural sits directly West at (102, 120) (Euclidean=28t, ground walking distance ~28t!).
    (define pa-pocket
      (mk-grid 160 160
               (lambda (x y)
                 (cond
                   [(or (< x 8) (>= x 152) (< y 8) (>= y 152)) 0]
                   [(and (>= x 128) (<= x 132) (>= y 118) (<= y 122)) 0] ; StartRaw 5x5 TH pad
                   [(and (>= x 50) (>= y 127) (<= y 131)) 0]             ; Cliff wall blocking pocket
                   [else 1]))))
    (define pl-pocket pa-pocket)
    (define th-pocket (mk-grid 160 160 (lambda (x y) (if (and (>= x 116) (<= y 126)) 144 128))))
    (define origin '(130.0 . 120.0))
    (define pocket-pad '(130.0 . 140.0))
    (define true-nat-pad '(102.0 . 120.0))
    (define bfs-grid (placement-ground-bfs-dist-grid pa-pocket origin #:max-dist 90.0))
    (define dists-direct
      (placement-ground-dist-to-targets pa-pocket origin (list pocket-pad true-nat-pad) #:max-dist 90.0))
    (define dists-reuse
      (placement-ground-dist-to-targets #f origin (list pocket-pad true-nat-pad) #:bfs bfs-grid))
    (define d-pocket (cdr (first dists-direct)))
    (define d-nat (cdr (second dists-direct)))
    (define d-nat-reuse (cdr (second dists-reuse)))
    ;; Hidden proxy with enemy-nat=#f MUST infer true-nat-pad (NOT pocket-pad) and keep >= 20t from it!
    (define hid-pocket
      (solve-hidden-proxy-site pl-pocket pa-pocket th-pocket origin #f '(30.0 . 30.0)
                               #:proxy-profile 'close-air
                               #:all-expansions (list pocket-pad true-nat-pad)))
    (define hid-pt (and (hash? hid-pocket) (hash-ref hid-pocket 'proxy-pt #f)))
    (check-true "l87f-7i-ground-bfs-picks-true-natural-over-back-cliff-pocket"
                (and (hash? bfs-grid)
                     (or (not d-pocket) (>= d-pocket 70.0))
                     (real? d-nat) (>= d-nat 24.0) (<= d-nat 34.0)
                     (real? d-nat-reuse) (= d-nat d-nat-reuse)
                     (pair? hid-pt)
                     (>= (pt-d (car hid-pt) (cdr hid-pt) (car true-nat-pad) (cdr true-nat-pad)) 20.0))
                (format "dPocket=~a dNat=~a dReuse=~a hidPt=~a" d-pocket d-nat d-nat-reuse hid-pt)))

  ;; 7j. Loop 87F: `solve-cannon-rush-wall-spots` guards against < 16.5t enemy-main worker-snipe traps
  ;;     when enemy-nat is known, preferring crisp <= 13.5t natural-choke / low-ground-ramp walls!
  (let ()
    ;; High-ground enemy main at (130, 130) (x >= 112 & y >= 112 -> height 144) with a tempting 1-pylon
    ;; L-cliff corner right inside the enemy main at (117, 123) (d_main=14.8t < 16.5t, d_nat=24.1t!).
    ;; Low-ground enemy natural at (100, 106) (height 128) with straight cliff at y >= 112 (3-pylon wall).
    (define pl-snipe
      (mk-grid 160 160
               (lambda (x y)
                 (cond
                   [(or (< x 8) (>= x 152) (< y 8) (>= y 152)) 0]
                   ;; Cliff border between natural low-ground (y < 112) and main high-ground (y >= 116)
                   [(and (>= y 112) (< y 116) (< x 116)) 0]
                   ;; Inside-main 1-pylon L-corner pocket right at (117, 123) (x<=115 or y<=121 blocked inside main)
                   [(and (>= x 112) (< x 116) (>= y 116) (<= y 124)) 0]
                   [(and (>= x 116) (<= x 120) (>= y 116) (<= y 121)) 0]
                   [else 1]))))
    (define pa-snipe pl-snipe)
    (define th-snipe (mk-grid 160 160 (lambda (x y) (if (and (>= x 112) (>= y 114)) 144 128))))
    (define spots
      (solve-cannon-rush-wall-spots pl-snipe pa-snipe th-snipe '(130.0 . 130.0) '(100.0 . 106.0) '(30.0 . 30.0)))
    (define best (and (pair? spots) (first spots)))
    (define best-cp (and best (hash-ref best 'cannon-pt #f)))
    (define all-safe?
      (and (pair? spots)
           (for/and ([sp (in-list spots)])
             (define cp (hash-ref sp 'cannon-pt))
             (define dm (pt-d (car cp) (cdr cp) 130.0 130.0))
             (define dn (pt-d (car cp) (cdr cp) 100.0 106.0))
             (or (>= dm 16.5)
                 (and (<= dn 13.5) (< (sc2-grid-ref th-snipe (car cp) (cdr cp)) 140))))))
    ;; Also check a compact map with a true low-ground ramp spot (d_main ~ 15.5t, d_nat <= 13.5t, low ground 128 < 144)
    (define pl-ramp
      (mk-grid 160 160
               (lambda (x y)
                 (cond
                   [(or (< x 8) (>= x 152) (< y 8) (>= y 152)) 0]
                   ;; Cliff separates high ground (x >= 118) from low-ground ramp/natural (x < 116)
                   [(and (>= x 116) (< x 118)) 0]
                   [else 1]))))
    (define th-ramp (mk-grid 160 160 (lambda (x y) (if (>= x 118) 144 128))))
    (define ramp-spots
      (solve-cannon-rush-wall-spots pl-ramp pl-ramp th-ramp '(130.0 . 130.0) '(106.0 . 126.0) '(30.0 . 30.0)))
    (define ramp-best (and (pair? ramp-spots) (first ramp-spots)))
    (define ramp-cp (and ramp-best (hash-ref ramp-best 'cannon-pt #f)))
    (check-true "l87f-7j-cannon-wall-blocks-main-snipe-trap-and-keeps-safe-nat-and-low-ramp"
                (and (pair? best-cp)
                     (eq? (hash-ref best 'target-kind #f) 'nat)
                     (>= (pt-d (car best-cp) (cdr best-cp) 130.0 130.0) 16.5)
                     (<= (pt-d (car best-cp) (cdr best-cp) 100.0 106.0) 13.5)
                     all-safe?
                     (pair? ramp-cp)
                     (< (sc2-grid-ref th-ramp (car ramp-cp) (cdr ramp-cp)) 140)
                     (<= (pt-d (car ramp-cp) (cdr ramp-cp) 106.0 126.0) 13.5))
                (format "best=~a allSafe=~a rampBest=~a" best all-safe? ramp-best))))

(printf "\n====================================================\n")
(printf "Loop 87 Wire Pylon & Wall Test Results: ~a/~a passed (~a failed)\n" passed total failed)
(printf "====================================================\n")
(when (> failed 0) (exit 1))
