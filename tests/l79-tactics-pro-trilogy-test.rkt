#lang racket/base

;; =============================================================================
;; Loop 79 Lane A Unit Tests — Pro Tactical Micro & Multi-Prong Trilogy:
;;   1. A1: Liberator Defender Mode (`2558/2560`, mineral-line harass, `96f` empty
;;          unsiege, AA evade, Advanced Ballistics, wire-check) & Thor Carrier Coupling
;;   2. A2: Dead-Space Multi-Prong Liberator Harass (`compute-liberator-deadspace-spot`,
;;          `plan-liberator-multiprong-harass`) & Minimal AA Peel
;;   3. A3: Swarm Host Anti-Light Splash Evaluator (`compute-anti-light-locust-splash-score`),
;;          Anti-Carrier Binary Commitment (`evaluate-carrier-engagement-mode`),
;;          & Spellcaster Dense-Interceptor Gating (Storm / Fungal / Parasitic Bomb)
;; =============================================================================

(require racket/list
         racket/math
         "../lib/tactics/unit-mode-micro.rkt"
         "../lib/tactics/multiprong-coordinator.rkt"
         "../lib/tactics/arena-minimax.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/sc2-protobuf-ws.rkt"
         "../lib/sc2-typed-commands.rkt")

(define pass-cnt 0)
(define fail-cnt 0)

(define (check-true name cond [detail ""])
  (if cond
      (set! pass-cnt (add1 pass-cnt))
      (begin
        (set! fail-cnt (add1 fail-cnt))
        (eprintf "FAIL [~a]: ~a\n" name detail))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-u id type x y
              #:hp [hp 100.0]
              #:max-hp [max-hp #f]
              #:shield [sh 0.0]
              #:max-shield [max-sh #f]
              #:energy [en 0.0]
              #:flying [fly #f]
              #:is-building [bldg #f])
  (hasheq 'id id
          'type type
          'unit-type type
          'x x
          'y y
          'hp hp
          'max-hp (or max-hp hp)
          'shield sh
          'shields sh
          'max-shield (or max-sh sh)
          'energy en
          'flying? fly
          'flying fly
          'is-flying fly
          'is-building bldg
          'is-structure bldg
          'build-progress 1.0
          'cloak 3
          'display-type 1))

(define (mk-raw-u tag ut-id alliance x y #:hp [hp 180.0] #:flying [fly #f])
  (sc2-unit 1 alliance tag ut-id 1 (sc2-point3d x y 8.0) 0.0 0.75 1.0
            3 #f #t #f hp hp 0.0 0.0 0.0 0.0 0 0 fly #f #f #t #t
            '() 0 '() 0 0 0.0 0 0 0 0))

;; -----------------------------------------------------------------------------
;; 1. A1: Liberator Defender Mode (`2558/2560`), Wire Check & Thor Carrier Coupling
;; -----------------------------------------------------------------------------
(let ()
  (define lib-f  (mk-u 1101 'liberator    70.0 70.0 #:hp 180.0 #:max-hp 180.0 #:flying #t))
  (define lib-d  (mk-u 1102 'liberator-ag 70.0 70.0 #:hp 180.0 #:max-hp 180.0 #:flying #t))
  (define lib-lo (mk-u 1103 'liberator-ag 70.0 70.0 #:hp  60.0 #:max-hp 180.0 #:flying #t))
  (define roaches-3
    (list (mk-u 1901 'roach 78.0 69.5 #:hp 145.0)
          (mk-u 1902 'roach 78.0 70.0 #:hp 145.0)
          (mk-u 1903 'roach 78.0 70.5 #:hp 145.0)))
  (define drone-1 (mk-u 1910 'drone 78.5 70.0 #:hp 40.0))
  (define drone-far (mk-u 1911 'drone 81.2 70.0 #:hp 40.0)) ;; 11.2t -> needs Advanced Ballistics!
  (define mutas-3
    (list (mk-u 1921 'mutalisk 74.0 69.0 #:hp 120.0 #:flying #t)
          (mk-u 1922 'mutalisk 74.0 70.0 #:hp 120.0 #:flying #t)
          (mk-u 1923 'mutalisk 74.0 71.0 #:hp 120.0 #:flying #t)))

  ;; (a) Frontline Liberator vs 3 Roaches -> 5-elem `(cast-spell 1101 'morph-liberator-ag tx ty)` clamped <= 4.8t
  (define tr-lib (make-unit-mode-tracker))
  (define acts-ag (step-unit-mode-micro! (list lib-f) roaches-3 #:tracker tr-lib #:current-frame 2000))
  (define ag-cmd (and (pair? acts-ag) (first acts-ag)))
  (check-true "l79-a1-liberator-frontline-siege-2558-clamped-le-4.8t"
              (and (list? ag-cmd)
                   (= (length ag-cmd) 5)
                   (eq? (first ag-cmd) 'cast-spell)
                   (= (second ag-cmd) 1101)
                   (eq? (third ag-cmd) 'morph-liberator-ag)
                   (<= (dist2d 70.0 70.0 (fourth ag-cmd) (fifth ag-cmd)) 4.81))
              (format "acts-ag=~a" acts-ag))

  ;; (b) Worker harass siege (`>= 1` enemy worker inside 9.0t; 11.2t requires Advanced Ballistics)
  (define d-wk-base (evaluate-liberator-mode lib-f '() (list drone-1) #:current-frame 2000))
  (define d-wk-far-no-upg (evaluate-liberator-mode lib-f '() (list drone-far) #:current-frame 2000))
  (define d-wk-far-upg (evaluate-liberator-mode lib-f '() (list drone-far)
                                                #:current-frame 2000 #:has-range-upg? #t))
  (define d-hzt (evaluate-liberator-mode lib-f '() '()
                                         #:current-frame 2000
                                         #:harass-zone-target (cons 77.5 70.0)))
  (check-true "l79-a1-liberator-worker-and-harass-zone-siege-with-range-upg"
              (and d-wk-base (= (unit-mode-directive-ability-id d-wk-base) MORPH-LIBERATOR-AG-ABILITY-ID)
                   (not d-wk-far-no-upg)
                   d-wk-far-upg
                   (<= (dist2d 70.0 70.0 (unit-mode-directive-tx d-wk-far-upg) (unit-mode-directive-ty d-wk-far-upg)) 7.81)
                   d-hzt (= (unit-mode-directive-ability-id d-hzt) 2558))
              (format "base=~a no-upg=~a upg=~a hzt=~a" d-wk-base d-wk-far-no-upg d-wk-far-upg d-hzt))

  ;; (c) Uncontested >= 3 enemy AA air within 7t blocks sieging
  (define d-aa-blk (evaluate-liberator-mode lib-f '() (append roaches-3 mutas-3) #:current-frame 2000))
  (check-true "l79-a1-liberator-skips-siege-vs-uncontested-aa-air"
              (not d-aa-blk)
              (format "d-aa-blk=~a" d-aa-blk))

  ;; (d) Defender Mode (`liberator-ag`) empty >= 96f unsieges `2560`, holds during < 96f worker pull,
  ;;     and immediately unsieges `2560` under heavy AA threat!
  (define tr-h (make-unit-mode-tracker))
  (define d-hold-0 (evaluate-liberator-mode lib-d '() '() #:tracker tr-h #:current-frame 3000
                                            #:harass-zone-target (cons 77.0 70.0)))
  (define d-hold-50 (evaluate-liberator-mode lib-d '() '() #:tracker tr-h #:current-frame 3050
                                             #:harass-zone-target (cons 77.0 70.0)))
  (define d-unsiege-96 (evaluate-liberator-mode lib-d '() '() #:tracker tr-h #:current-frame 3096
                                                #:harass-zone-target (cons 77.0 70.0)))
  (define d-aa-evade (evaluate-liberator-mode lib-lo '() (list (mk-u 1930 'stalker 75.0 70.0 #:hp 80.0 #:shield 80.0))
                                              #:current-frame 3000))
  (check-true "l79-a1-liberator-ag-96f-empty-unsiege-and-aa-evade-2560"
              (and (not d-hold-0)
                   (not d-hold-50)
                   d-unsiege-96 (= (unit-mode-directive-ability-id d-unsiege-96) MORPH-LIBERATOR-AA-ABILITY-ID)
                   d-aa-evade (= (unit-mode-directive-ability-id d-aa-evade) 2560))
              (format "h0=~a h50=~a u96=~a evade=~a" d-hold-0 d-hold-50 d-unsiege-96 d-aa-evade))

  ;; (e) Full SC2 wire translation verification (`2558` point-target, `2560` no-target -> 0 rejects!)
  (reset-typed-command-gate-stats!)
  (define wire-obs
    (sc2-observation 2200 (sc2-player-common 1 200 100 40 20 12 12 0 0 0 0)
                     (list (mk-raw-u 1101 LIBERATOR-UNIT-TYPE-ID 1 70.0 70.0 #:hp 180.0 #:flying #t)
                           (mk-raw-u 1102 LIBERATOR-AG-UNIT-TYPE-ID 1 70.0 70.0 #:hp 180.0 #:flying #t))
                     '() '() #f '() '() '() '() '() '()))
  (define wire-cmds
    (translate-bot-actions->sc2-raw-commands
     (list ag-cmd '(cast-spell 1102 morph-liberator-aa))
     wire-obs))
  (define c-2558 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2558))) wire-cmds))
  (define c-2560 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2560))) wire-cmds))
  (check-true "l79-a1-liberator-wire-translates-2558-2560-zero-rejects"
              (and (= (get-total-bot-action-reject-count) 0)
                   (sc2-raw-unit-command? c-2558)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-2558))
                   (sc2-raw-unit-command? c-2560)
                   (not (sc2-raw-unit-command-target-pos c-2560)))
              (format "rej=~a cmds=~a" (get-total-bot-action-reject-count) wire-cmds))

  ;; (f) Thor Carrier-Strategy coupling (`'carrier-snipe` -> 2362 HI, `'interceptor-burn` >= 6 Int -> 2364 Exp)
  (define thor-exp (mk-u 1201 'thor    50.0 50.0 #:hp 400.0))
  (define thor-hi  (mk-u 1202 'thor-ap 50.0 50.0 #:hp 400.0))
  (define carriers-and-ints
    (append (list (mk-u 1950 'carrier 60.0 50.0 #:hp 300.0 #:shield 150.0 #:flying #t)
                  (mk-u 1951 'carrier 61.0 51.0 #:hp 300.0 #:shield 150.0 #:flying #t))
            (for/list ([i (in-range 10)])
              (mk-u (+ 1960 i) 'interceptor 56.0 (+ 48.0 (* 0.4 i)) #:hp 40.0 #:shield 40.0 #:flying #t))))
  (define d-thor-snipe (evaluate-thor-mode thor-exp carriers-and-ints #:carrier-mode 'carrier-snipe))
  (define d-thor-burn  (evaluate-thor-mode thor-hi  carriers-and-ints #:carrier-mode 'interceptor-burn))
  (define d-thor-def   (evaluate-thor-mode thor-exp carriers-and-ints))
  (check-true "l79-a1-thor-mode-couples-to-carrier-binary-mode"
              (and d-thor-snipe (= (unit-mode-directive-ability-id d-thor-snipe) 2362)
                   d-thor-burn  (= (unit-mode-directive-ability-id d-thor-burn) 2364)
                   d-thor-def   (= (unit-mode-directive-ability-id d-thor-def) 2362))
              (format "snipe=~a burn=~a def=~a" d-thor-snipe d-thor-burn d-thor-def)))

;; -----------------------------------------------------------------------------
;; 2. A2: Dead-Space Multi-Prong Liberator Harass & Minimal AA Peel
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) `compute-liberator-deadspace-spot`: sets `(siege-x, siege-y)` 1.5t toward TH from
  ;;     minerals (on the mining worker arc!) and `(park-x, park-y)` 4.5t past siege (`7.5t`
  ;;     w/ range upg), so `(dist park siege) <= 4.8t` (`<= 7.8t` w/ range upg) -> ZERO clipping!
  (define-values (px1 py1 sx1 sy1)
    (compute-liberator-deadspace-spot 140.0 140.0 145.5 140.0 200.0 200.0 #f))
  (define-values (px2 py2 sx2 sy2)
    (compute-liberator-deadspace-spot 140.0 140.0 145.5 140.0 200.0 200.0 #t))
  (define-values (pxc pyc _sxc _syc)
    (compute-liberator-deadspace-spot 10.0 10.0 5.0 10.0 200.0 200.0 #f))
  (check-true "l79-a2-deadspace-spot-projects-behind-minerals-and-clamps"
              (and (<= (abs (- sx1 144.0)) 0.05) (= sy1 140.0)
                   (<= (dist2d px1 py1 sx1 sy1) 4.8)
                   (<= (abs (- (dist2d px1 py1 sx1 sy1) 4.5)) 0.05)
                   (> px1 145.5) ;; still behind mineral line in dead space!
                   (<= (dist2d px2 py2 sx2 sy2) 7.8)
                   (<= (abs (- (dist2d px2 py2 sx2 sy2) 7.5)) 0.05)
                   (>= pxc 4.0) (<= pxc 196.0) (>= pyc 4.0) (<= pyc 196.0))
              (format "base=(~a,~a)/(~a,~a) rng=(~a,~a)/(~a,~a) clamp=(~a,~a)"
                      px1 py1 sx1 sy1 px2 py2 sx2 sy2 pxc pyc))

  ;; (b) `plan-liberator-multiprong-harass`: detachment scaling (1->0, 2->1, 3->2, 5->3),
  ;;     distinct bases >= 20t apart, edge flank waypoints >= 18t clear of enemy army!
  (define libs-5
    (for/list ([i (in-range 5)])
      (mk-u (+ 2101 i) 'liberator (+ 40.0 (* 1.0 i)) 40.0 #:hp 180.0 #:max-hp 180.0 #:flying #t)))
  (define enemy-bases
    (list (hasheq 'th-x 160.0 'th-y 160.0 'mineral-cx 166.0 'mineral-cy 160.0 'aa-cnt 0 'workers 16)
          (hasheq 'th-x 160.0 'th-y 110.0 'mineral-cx 166.0 'mineral-cy 110.0 'aa-cnt 0 'workers 16)
          (hasheq 'th-x 110.0 'th-y 160.0 'mineral-cx 110.0 'mineral-cy 166.0 'aa-cnt 0 'workers 14)
          (hasheq 'th-x 115.0 'th-y 115.0 'mineral-cx 120.0 'mineral-cy 115.0 'aa-cnt 5 'workers 12)))
  (define p1 (plan-liberator-multiprong-harass (take libs-5 1) enemy-bases 40.0 40.0 100.0 100.0 8000))
  (define p2 (plan-liberator-multiprong-harass (take libs-5 2) enemy-bases 40.0 40.0 100.0 100.0 8000))
  (define p3 (plan-liberator-multiprong-harass (take libs-5 3) enemy-bases 40.0 40.0 100.0 100.0 8000 200.0 200.0 #f #t))
  (define p5 (plan-liberator-multiprong-harass libs-5 enemy-bases 40.0 40.0 100.0 100.0 8000 200.0 200.0 #f #t))
  (define p3-distinct?
    (and (= (length p3) 2)
         (>= (dist2d (hash-ref (first p3) 'siege-x) (hash-ref (first p3) 'siege-y)
                     (hash-ref (second p3) 'siege-x) (hash-ref (second p3) 'siege-y))
             20.0)))
  (define p5-all-distinct-and-clear?
    (and (= (length p5) 3)
         (for/and ([h (in-list p5)])
           (and (memq (hash-ref h 'stage) '(flank park siege evade))
                (eq? (hash-ref h 'synced?) #t)
                (>= (dist2d (hash-ref h 'waypoint-x) (hash-ref h 'waypoint-y) 100.0 100.0) 18.0)))
         (>= (dist2d (hash-ref (first p5) 'siege-x) (hash-ref (first p5) 'siege-y)
                     (hash-ref (second p5) 'siege-x) (hash-ref (second p5) 'siege-y))
             20.0)
         (>= (dist2d (hash-ref (first p5) 'siege-x) (hash-ref (first p5) 'siege-y)
                     (hash-ref (third p5) 'siege-x) (hash-ref (third p5) 'siege-y))
             20.0)
         (>= (dist2d (hash-ref (second p5) 'siege-x) (hash-ref (second p5) 'siege-y)
                     (hash-ref (third p5) 'siege-x) (hash-ref (third p5) 'siege-y))
             20.0)))
  (check-true "l79-a2-liberator-multiprong-scaling-distinct-bases-and-flank-clearance"
              (and (null? p1)
                   (= (length p2) 1)
                   p3-distinct?
                   p5-all-distinct-and-clear?)
              (format "n1=~a n2=~a n3=~a p3d=~a p5ok=~a p5=~a"
                      (length p1) (length p2) (length p3) p3-distinct? p5-all-distinct-and-clear? p5))

  ;; (c) `select-minimal-liberator-aa-peel`: <= 4 AND <= 12% supply (min 3) while fighting; up to 6 when idle
  (define stalkers-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 2201 i) 'stalker (+ 35.0 (* 2.0 i)) 35.0 #:hp 80.0 #:shield 80.0)))
  (define zealots-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 2251 i) 'zealot 34.0 (+ 34.0 (* 0.5 i)) #:hp 100.0 #:shield 50.0)))
  (define static-1 (list (mk-u 2299 'photon-cannon 34.0 35.0 #:hp 150.0 #:is-building #t)))
  (define pool (append zealots-4 static-1 stalkers-12))
  (define peel-100 (select-minimal-liberator-aa-peel pool 32.0 35.0 #t 100.0)) ;; 12% = 12 sup -> 4 Stalkers (8 sup)
  (define peel-60  (select-minimal-liberator-aa-peel pool 32.0 35.0 #t  60.0)) ;; 12% = 7.2 sup -> 3 Stalkers (6 sup)
  (define peel-idle (select-minimal-liberator-aa-peel pool 32.0 35.0 #f 100.0)) ;; idle -> 6 Stalkers
  (check-true "l79-a2-minimal-aa-peel-caps-4-and-12pct-supply-excludes-ground-and-static"
              (and (= (length peel-100) 4)
                   (= (length peel-60) 3)
                   (= (length peel-idle) 6)
                   (andmap (lambda (u) (eq? (hash-ref u 'type) 'stalker)) peel-100)
                   ;; Nearest Stalkers chosen first (ids 2201..2204)
                   (equal? (map (lambda (u) (hash-ref u 'id)) peel-100) '(2201 2202 2203 2204)))
              (format "p100=~a p60=~a pidle=~a" (length peel-100) (length peel-60) (length peel-idle)))

  ;; (d) Loop 79 Pass 2 (`sc2-runby-ro25` regression): 2 solo Liberators vs Zerg main
  ;;     (16 Drones + 2 Queens local defense) -> detaches BOTH Liberators directly to `'park`
  ;;     behind the mineral line (NOT `'flank` south off cliff, NOT `'evade`), sieges `2558`
  ;;     despite 2 Queens, stays sieged at 100% & 60% HP while workers are in the 5.0t zone,
  ;;     and only unsieges `2560` / `'evade` when `hp-ratio < 0.42` or `>= 3` AA in range!
  (define ro25-libs-spawn
    (list (mk-u 2301 'liberator 42.7 138.0 #:hp 180.0 #:max-hp 180.0 #:flying #t)
          (mk-u 2302 'liberator 42.7 139.0 #:hp 180.0 #:max-hp 180.0 #:flying #t)))
  (define ro25-base
    (list (hasheq 'th-x 33.5 'th-y 138.5 'mineral-cx 29.5 'mineral-cy 142.5 'aa-cnt 2 'workers 16)))
  (define ro25-drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 2400 i) 'drone (+ 29.0 (* 0.4 (modulo i 4))) (+ 141.0 (* 0.4 (quotient i 4))) #:hp 40.0)))
  (define ro25-queens-2
    (list (mk-u 2450 'queen 36.3 138.0 #:hp 175.0)
          (mk-u 2451 'queen 36.3 139.0 #:hp 175.0)))
  (define ro25-plan
    (plan-liberator-multiprong-harass ro25-libs-spawn ro25-base
                                      42.7 138.5 36.3 138.5 120 168.0 168.0 #f #f
                                      #:enemy-units (append ro25-drones-16 ro25-queens-2)))
  (define ro25-solo1-plan
    (plan-liberator-multiprong-harass (list (first ro25-libs-spawn)) ro25-base
                                      42.7 138.5 36.3 138.5 120 168.0 168.0 #f #f
                                      #:pure-harass-squad? #t))
  (define ro25-evade-lowhp
    (plan-liberator-multiprong-harass
     (list (mk-u 2301 'liberator-ag 26.5 145.5 #:hp 70.0 #:max-hp 180.0 #:flying #t))
     ro25-base 26.5 145.5 31.0 142.0 300 168.0 168.0 #f #f
     #:pure-harass-squad? #t))
  (define ro25-evade-3aa
    (plan-liberator-multiprong-harass
     (list (mk-u 2301 'liberator-ag 26.5 145.5 #:hp 180.0 #:max-hp 180.0 #:flying #t))
     ro25-base 26.5 145.5 31.0 142.0 300 168.0 168.0 #f #f
     #:pure-harass-squad? #t
     #:enemy-units (list (mk-u 2461 'queen 30.0 143.0 #:hp 175.0)
                         (mk-u 2462 'queen 30.5 143.5 #:hp 175.0)
                         (mk-u 2463 'queen 31.0 144.0 #:hp 175.0))))
  (define ro25-in-cast-range-plan
    (plan-liberator-multiprong-harass
     (list (mk-u 2305 'liberator 26.8 144.4 #:hp 180.0 #:max-hp 180.0 #:flying #t))
     ro25-base 26.8 144.4 36.3 138.5 220 168.0 168.0 #f #f
     #:pure-harass-squad? #t
     #:enemy-units (append ro25-drones-16 ro25-queens-2)))
  (check-true "l79-a2-ro25-solo-liberators-park-behind-minerals-not-flank-off-cliff"
              (and (= (length ro25-plan) 2)
                   (= (length ro25-solo1-plan) 1)
                   (andmap (lambda (h)
                             (and (eq? (hash-ref h 'stage) 'park)
                                  (< (hash-ref h 'waypoint-x) 29.5)
                                  (> (hash-ref h 'waypoint-y) 142.5)
                                  (<= (dist2d (hash-ref h 'park-x) (hash-ref h 'park-y)
                                              (hash-ref h 'siege-x) (hash-ref h 'siege-y))
                                      4.81)))
                           ro25-plan)
                   ;; Live worker centroid refinement + instant `'siege` when inside <= 4.8t of siege!
                   (= (length ro25-in-cast-range-plan) 1)
                   (eq? (hash-ref (first ro25-in-cast-range-plan) 'stage) 'siege)
                   (<= (dist2d (hash-ref (first ro25-in-cast-range-plan) 'siege-x)
                               (hash-ref (first ro25-in-cast-range-plan) 'siege-y)
                               29.6 141.6)
                       0.2)
                   (> (dist2d (hash-ref (first ro25-plan) 'siege-x) (hash-ref (first ro25-plan) 'siege-y)
                              (hash-ref (second ro25-plan) 'siege-x) (hash-ref (second ro25-plan) 'siege-y))
                      1.0)
                   (eq? (hash-ref (first ro25-evade-lowhp) 'stage) 'evade)
                   (eq? (hash-ref (first ro25-evade-3aa) 'stage) 'evade))
              (format "plan=~a solo1=~a inCast=~a lowhp=~a aa3=~a"
                      ro25-plan ro25-solo1-plan ro25-in-cast-range-plan ro25-evade-lowhp ro25-evade-3aa))

  ;; Defender Mode siege & hold under 2 Queens in `ro25` geometry
  (define ro25-lib-parked (mk-u 2311 'liberator    26.5 145.5 #:hp 180.0 #:max-hp 180.0 #:flying #t))
  (define ro25-ag-full    (mk-u 2312 'liberator-ag 26.5 145.5 #:hp 180.0 #:max-hp 180.0 #:flying #t))
  (define ro25-ag-60pct   (mk-u 2313 'liberator-ag 26.5 145.5 #:hp 108.0 #:max-hp 180.0 #:flying #t))
  (define ro25-ag-39pct   (mk-u 2314 'liberator-ag 26.5 145.5 #:hp  70.0 #:max-hp 180.0 #:flying #t))
  (define ro25-queens-close
    (list (mk-u 2470 'queen 31.0 142.0 #:hp 175.0)
          (mk-u 2471 'queen 31.5 142.5 #:hp 175.0)))
  (define ro25-queens-3
    (cons (mk-u 2472 'queen 31.0 143.0 #:hp 175.0) ro25-queens-close))
  (define ro25-en-2q (append ro25-drones-16 ro25-queens-close))
  (define ro25-en-3q (append ro25-drones-16 ro25-queens-3))
  (define ro25-hzt (cons 29.5 142.5))
  (define d-ro25-siege (evaluate-liberator-mode ro25-lib-parked '() ro25-en-2q
                                                #:current-frame 300 #:harass-zone-target ro25-hzt))
  (define d-ro25-hold-full (evaluate-liberator-mode ro25-ag-full '() ro25-en-2q
                                                    #:current-frame 300 #:harass-zone-target ro25-hzt))
  (define d-ro25-hold-60   (evaluate-liberator-mode ro25-ag-60pct '() ro25-en-2q
                                                    #:current-frame 300 #:harass-zone-target ro25-hzt))
  (define d-ro25-evade-lo  (evaluate-liberator-mode ro25-ag-39pct '() ro25-en-2q
                                                    #:current-frame 300 #:harass-zone-target ro25-hzt))
  (define d-ro25-evade-3q  (evaluate-liberator-mode ro25-ag-full '() ro25-en-3q
                                                    #:current-frame 300 #:harass-zone-target ro25-hzt))
  (check-true "l79-a1-ro25-liberator-sieges-and-stays-sieged-vs-2-queens-unsieges-only-lt42pct-or-3aa"
              (and d-ro25-siege (= (unit-mode-directive-ability-id d-ro25-siege) 2558)
                   (not d-ro25-hold-full)
                   (not d-ro25-hold-60)
                   d-ro25-evade-lo (= (unit-mode-directive-ability-id d-ro25-evade-lo) 2560)
                   d-ro25-evade-3q (= (unit-mode-directive-ability-id d-ro25-evade-3q) 2560))
              (format "siege=~a full=~a hp60=~a lo=~a q3=~a"
                      d-ro25-siege d-ro25-hold-full d-ro25-hold-60 d-ro25-evade-lo d-ro25-evade-3q)))

;; -----------------------------------------------------------------------------
;; 3. A3: Swarm Host Anti-Light Splash, Carrier Binary Commitment & Spell Gating
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Swarm Host Anti-Light Splash thresholds across all 3 races
  (define colossi-2 (list (mk-u 3001 'colossus 50 50) (mk-u 3002 'colossus 51 50)))
  (define ht-2-ok   (list (mk-u 3003 'high-templar 50 50 #:energy 75.0) (mk-u 3004 'high-templar 51 50 #:energy 80.0)))
  (define ht-2-dry  (list (mk-u 3005 'high-templar 50 50 #:energy 40.0) (mk-u 3006 'high-templar 51 50 #:energy 50.0)))
  (define dis-2     (list (mk-u 3007 'disruptor 50 50) (mk-u 3008 'disruptor 51 50)))
  (define archons-3 (for/list ([i (in-range 3)]) (mk-u (+ 3010 i) 'archon 50 50)))
  (define tanks-3   (for/list ([i (in-range 3)]) (mk-u (+ 3020 i) 'siege-tank-sieged 50 50)))
  (define lurkers-3 (for/list ([i (in-range 3)]) (mk-u (+ 3030 i) 'lurker-burrowed 50 50)))
  (define hellbats-4 (for/list ([i (in-range 4)]) (mk-u (+ 3040 i) 'hellbat 50 50)))
  (define banes-6   (for/list ([i (in-range 6)]) (mk-u (+ 3050 i) 'baneling 50 50)))
  (define no-splash (append (for/list ([i (in-range 10)]) (mk-u (+ 3060 i) 'stalker 50 50))
                            (for/list ([i (in-range 4)])  (mk-u (+ 3080 i) 'immortal 50 50))
                            (for/list ([i (in-range 12)]) (mk-u (+ 3090 i) 'marine 50 50))))
  (check-true "l79-a3-swarm-host-anti-light-splash-thresholds-all-3-races"
              (and (army-has-strong-anti-light-locust-splash? colossi-2)
                   (army-has-strong-anti-light-locust-splash? ht-2-ok)
                   (not (army-has-strong-anti-light-locust-splash? ht-2-dry))
                   (army-has-strong-anti-light-locust-splash? dis-2)
                   (army-has-strong-anti-light-locust-splash? archons-3)
                   (army-has-strong-anti-light-locust-splash? tanks-3)
                   (army-has-strong-anti-light-locust-splash? lurkers-3)
                   (army-has-strong-anti-light-locust-splash? hellbats-4)
                   (army-has-strong-anti-light-locust-splash? banes-6)
                   (= (compute-anti-light-locust-splash-score no-splash) 0.0)
                   (not (army-has-strong-anti-light-locust-splash? no-splash)))
              (format "col=~a ht=~a dry=~a dis=~a arc=~a tk=~a lrk=~a hb=~a bn=~a none=~a"
                      (compute-anti-light-locust-splash-score colossi-2)
                      (compute-anti-light-locust-splash-score ht-2-ok)
                      (compute-anti-light-locust-splash-score ht-2-dry)
                      (compute-anti-light-locust-splash-score dis-2)
                      (compute-anti-light-locust-splash-score archons-3)
                      (compute-anti-light-locust-splash-score tanks-3)
                      (compute-anti-light-locust-splash-score lurkers-3)
                      (compute-anti-light-locust-splash-score hellbats-4)
                      (compute-anti-light-locust-splash-score banes-6)
                      (compute-anti-light-locust-splash-score no-splash)))

  ;; (b) Anti-Carrier Binary Commitment (`evaluate-carrier-engagement-mode`: ZERO mixing!)
  (define carriers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 3501 i) 'carrier 80.0 (+ 45.0 (* 1.5 i)) #:hp 300.0 #:shield 150.0 #:flying #t)))
  (define ints-36
    (for/list ([i (in-range 36)])
      (mk-u (+ 3601 i) 'interceptor 72.0 (+ 47.0 (* 0.15 i)) #:hp 40.0 #:shield 40.0 #:flying #t)))
  (define ints-10 (take ints-36 10)) ;; <= 2 * 6 = 12 (empty Carriers!)
  (define fleet-full (append carriers-6 ints-36))
  (define fleet-empty (append carriers-6 ints-10))

  (define comp-corruptors (for/list ([i (in-range 10)]) (mk-u (+ 3101 i) 'corruptor 65 50 #:flying #t)))
  (define comp-bio-vikings
    (append (for/list ([i (in-range 14)]) (mk-u (+ 3120 i) 'viking-fighter 65 50 #:flying #t))
            (for/list ([i (in-range 12)]) (mk-u (+ 3140 i) 'marine 65 50))))
  (define comp-archon-tempest
    (append (for/list ([i (in-range 8)]) (mk-u (+ 3160 i) 'archon 65 50))
            (for/list ([i (in-range 8)]) (mk-u (+ 3170 i) 'tempest 65 50 #:flying #t))))
  (define comp-hydra-viper
    (append (for/list ([i (in-range 24)]) (mk-u (+ 3200 i) 'hydralisk 65 50))
            (for/list ([i (in-range 2)])  (mk-u (+ 3230 i) 'viper 64 50 #:energy 150.0 #:flying #t))))
  (define comp-marines-16 (for/list ([i (in-range 16)]) (mk-u (+ 3250 i) 'marine 65 50)))
  (define comp-archon-ht
    (append (for/list ([i (in-range 3)]) (mk-u (+ 3270 i) 'archon 65 50))
            (for/list ([i (in-range 2)]) (mk-u (+ 3280 i) 'high-templar 64 50 #:energy 100.0))))

  (check-true "l79-a3-carrier-binary-commitment-and-empty-carrier-flip"
              (and (eq? (evaluate-carrier-engagement-mode comp-hydra-viper (list (mk-u 3999 'stalker 80 50))) 'none)
                   (eq? (evaluate-carrier-engagement-mode comp-corruptors fleet-full) 'carrier-snipe)
                   (eq? (evaluate-carrier-engagement-mode comp-bio-vikings fleet-full) 'carrier-snipe)
                   (eq? (evaluate-carrier-engagement-mode comp-archon-tempest fleet-full) 'carrier-snipe)
                   (eq? (evaluate-carrier-engagement-mode comp-hydra-viper fleet-full) 'interceptor-burn)
                   (eq? (evaluate-carrier-engagement-mode comp-marines-16 fleet-full) 'interceptor-burn)
                   (eq? (evaluate-carrier-engagement-mode comp-archon-ht fleet-full) 'interceptor-burn)
                   ;; Once Interceptors drop <= 2 * live-carriers, flips automatically to `'carrier-snipe`!
                   (eq? (evaluate-carrier-engagement-mode comp-hydra-viper fleet-empty) 'carrier-snipe))
              (format "corr=~a bv=~a at=~a hv=~a mar=~a aht=~a empty=~a"
                      (evaluate-carrier-engagement-mode comp-corruptors fleet-full)
                      (evaluate-carrier-engagement-mode comp-bio-vikings fleet-full)
                      (evaluate-carrier-engagement-mode comp-archon-tempest fleet-full)
                      (evaluate-carrier-engagement-mode comp-hydra-viper fleet-full)
                      (evaluate-carrier-engagement-mode comp-marines-16 fleet-full)
                      (evaluate-carrier-engagement-mode comp-archon-ht fleet-full)
                      (evaluate-carrier-engagement-mode comp-hydra-viper fleet-empty)))

  ;; (c) Spellcaster dense-Interceptor gating (Storm / Fungal / Parasitic Bomb):
  ;;     Cast on >= 4 Interceptor cloud ONLY in `'interceptor-burn`, NEVER in `'carrier-snipe` or on <= 2!
  (define int-cloud-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 4901 i) 'interceptor 70.0 (+ 50.0 (* 0.2 i)) #:hp 40.0 #:shield 40.0 #:flying #t)))
  (define int-cloud-2 (take int-cloud-6 2))
  (define far-carriers
    (list (mk-u 4950 'carrier 85.0 50.0 #:hp 300.0 #:shield 150.0 #:flying #t)
          (mk-u 4951 'carrier 86.0 50.0 #:hp 300.0 #:shield 150.0 #:flying #t)))
  (define enemy-burn-scene (append far-carriers int-cloud-6))

  ;; High Templar Psi Storm
  (define ht-u (mk-u 4001 'high-templar 64.0 50.0 #:hp 40.0 #:shield 40.0 #:energy 100.0))
  (define d-storm-burn
    (plan-protoss-spellcaster-micro (list ht-u) enemy-burn-scene #:current-frame 5000 #:carrier-mode 'interceptor-burn))
  (define d-storm-snipe
    (plan-protoss-spellcaster-micro (list ht-u) enemy-burn-scene #:current-frame 5000 #:carrier-mode 'carrier-snipe))
  (define d-storm-2int
    (plan-protoss-spellcaster-micro (list ht-u) (append far-carriers int-cloud-2) #:current-frame 5000 #:carrier-mode 'interceptor-burn))
  (check-true "l79-a3-psi-storm-dense-interceptors-only-in-burn-mode"
              (and (ormap (lambda (d) (eq? (spell-directive-ability d) 'psi-storm)) d-storm-burn)
                   (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'psi-storm)) d-storm-snipe))
                   (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'psi-storm)) d-storm-2int)))
              (format "burn=~a snipe=~a two=~a" d-storm-burn d-storm-snipe d-storm-2int))

  ;; Infestor Fungal Growth
  (define inf-u (mk-u 4002 'infestor 64.0 50.0 #:hp 90.0 #:energy 100.0))
  (define d-fung-burn
    (plan-zerg-spellcaster-micro (list inf-u) enemy-burn-scene
                                 #:current-frame 5000 #:neural-parasite-researched? #f
                                 #:microbial-shroud-ok? #f #:carrier-mode 'interceptor-burn))
  (define d-fung-snipe
    (plan-zerg-spellcaster-micro (list inf-u) enemy-burn-scene
                                 #:current-frame 5000 #:neural-parasite-researched? #f
                                 #:microbial-shroud-ok? #f #:carrier-mode 'carrier-snipe))
  (check-true "l79-a3-fungal-growth-dense-interceptors-only-in-burn-mode"
              (and (ormap (lambda (d) (eq? (spell-directive-ability d) 'fungal-growth)) d-fung-burn)
                   (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'fungal-growth)) d-fung-snipe)))
              (format "burn=~a snipe=~a" d-fung-burn d-fung-snipe))

  ;; Viper Parasitic Bomb
  (define vip-u (mk-u 4003 'viper 64.0 50.0 #:hp 150.0 #:energy 150.0 #:flying #t))
  (define d-pb-burn
    (plan-zerg-spellcaster-micro (list vip-u) enemy-burn-scene #:current-frame 5000 #:carrier-mode 'interceptor-burn))
  (define d-pb-snipe
    (plan-zerg-spellcaster-micro (list vip-u) enemy-burn-scene #:current-frame 5000 #:carrier-mode 'carrier-snipe))
  (check-true "l79-a3-parasitic-bomb-dense-interceptors-only-in-burn-mode"
              (and (ormap (lambda (d) (eq? (spell-directive-ability d) 'parasitic-bomb)) d-pb-burn)
                   (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'parasitic-bomb)) d-pb-snipe)))
              (format "burn=~a snipe=~a" d-pb-burn d-pb-snipe)))

(printf "l79-tactics-pro-trilogy-test: ~a/~a passed\n" pass-cnt (+ pass-cnt fail-cnt))
(when (> fail-cnt 0)
  (exit 1))
