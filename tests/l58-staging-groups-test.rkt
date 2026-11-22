#lang racket/base

;; =============================================================================
;; `tests/l58-staging-groups-test.rkt`
;; Unit & Runtime Integration Test Suite for Loop 58 Engineering Sprint:
;;   1. Dynamic Safe Staging Point Selection across all 4 map corners & 4 domains
;;   2. Role-Lease Priority Integration (`'staging-group` 50 / `'strike-group` 55)
;;   3. Staging Control-Group Lifecycle Hysteresis (`'staging -> 'dispatched -> 'regrouping`)
;;   4. All 5 Hard Safety Overrides (Home-Defense Scramble, In-Contact Reflex,
;;      Production-Aware Anti-Stall + Endgame Override, Live Full-Match Gate,
;;      Ground `attack-pos` Order Discipline)
;;   5. Generalizable Combat Concave & Front-to-Back Positioning (PvP/TvP layering,
;;      Terran Medivac/Raven/Ghost rear leash, Zerg two-wing surround + uphill ramp
;;      brake with flat-ground control, pre-contact anti-splash lateral fan-out)
;;   6. Div-5 Macro Runtime Sync Gates (0-Stargate air upgrade block, PvT 1-Obs cap
;;      vs Mines, faster Stimpack, ZvP Spine/Evo/BN-RW/HydraDen-vs-Spire caps)
;;   7. Pass 3B Fogged-Colossus Air-Memory Retention & Instant Dead-Tag Prune
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/sc2-game-constants.rkt"
         "../lib/tactics/staging-groups.rkt"
         "../lib/tactics/concave-positioning.rkt"
         "../lib/tactics/unit-mode-micro.rkt"
         "../lib/bot-runtime.rkt")

(define pass-cnt 0)
(define fail-cnt 0)

(define (check-true name pred [detail ""])
  (if pred
      (set! pass-cnt (add1 pass-cnt))
      (begin
        (set! fail-cnt (add1 fail-cnt))
        (eprintf "FAIL [~a]: ~a\n" name detail))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-u id sym x y
              #:hp [hp 100.0]
              #:max-hp [max-hp hp]
              #:shield [sh 0.0]
              #:max-shield [max-sh sh]
              #:energy [en 0.0]
              #:flying [fly? #f]
              #:z [z #f]
              #:build-progress [bp 1.0])
  (define base
    (hash 'id id 'type sym 'x x 'y y
          'hp hp 'max-hp max-hp
          'shield sh 'shields sh 'max-shield max-sh 'max-shields max-sh
          'energy en 'flying? fly? 'flying fly?
          'build-progress bp 'display-type 1 'snapshot? #f))
  (if z (hash-set base 'z z) base))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 400]
                     #:gas [gas 200]
                     #:supply-used [sup-u 40]
                     #:supply-cap [sup-c 70]
                     #:mineral-harvesters [mharv 16]
                     #:vespene-harvesters [vharv 6]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:mineral-patches [mps '()]
                     #:researched-upgrades [upgs '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 56.5] #:nat-y [ny 32.5]
                     #:third-x [tx 32.5] #:third-y [ty 64.5]
                     #:enemy-x [ex 167.5] #:enemy-y [ey 167.5]
                     #:map-width [mw 200.0] #:map-height [mh 200.0])
  (hash 'race race
        'enemy-race enemy-race
        'frame frame
        'live-obs? #t
        'minerals minerals
        'gas gas
        'supply-used sup-u
        'supply-cap sup-c
        'mineral-harvesters mharv
        'vespene-harvesters vharv
        'ally-units au
        'ally-buildings ab
        'enemy-units eu
        'enemy-buildings eb
        'mineral-patches mps
        'researched-upgrades upgs
        'base-x bx 'base-y by
        'natural-x nx 'natural-y ny
        'third-x tx 'third-y ty
        'enemy-x ex 'enemy-y ey
        'enemy-base-x ex 'enemy-base-y ey
        'map-width mw 'map-height mh))

;; =============================================================================
;; 1. Dynamic `pick-safe-staging-point` Across All 4 Corners (NW, NE, SW, SE)
;; =============================================================================
(let ()
  (define corners
    (list (list 'SW 32.5 32.5  56.5 32.5  167.5 167.5)
          (list 'SE 167.5 32.5 143.5 32.5 32.5 167.5)
          (list 'NW 32.5 167.5 56.5 167.5 167.5 32.5)
          (list 'NE 167.5 167.5 143.5 167.5 32.5 32.5)))
  (for ([c (in-list corners)])
    (define label (first c))
    (define bx (second c)) (define by (third c))
    (define nx (fourth c)) (define ny (fifth c))
    (define ex (sixth c))  (define ey (seventh c))
    (define ths (list (mk-u 1 'hatchery bx by) (mk-u 2 'hatchery nx ny)))
    ;; Exposed forward Spire right near enemy MUST NOT anchor air staging!
    (define bldgs (append ths (list (mk-u 3 'spire (* 0.5 (+ nx ex)) (* 0.5 (+ ny ey))))))
    (define air-pt
      (pick-safe-staging-point
       #:domain 'air
       #:ally-townhalls ths #:ally-buildings bldgs
       #:enemy-units '() #:enemy-anchor-x ex #:enemy-anchor-y ey
       #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
       #:map-width 200.0 #:map-height 200.0 #:enemy-capital-air? #t))
    (define d-air-en (dist2d (car air-pt) (cdr air-pt) ex ey))
    (define d-main-en (dist2d bx by ex ey))
    (check-true (format "corner-~a-air-behind-safest-th-and-in-bounds" label)
                (and (>= (car air-pt) 5.0) (<= (car air-pt) 195.0)
                     (>= (cdr air-pt) 5.0) (<= (cdr air-pt) 195.0)
                     (> d-air-en d-main-en))
                (format "air-pt=~a d-air-en=~a d-main-en=~a" air-pt d-air-en d-main-en))
    ;; Ground-front avoids obstacles >= 3.0t & obeys BFS pathability callback
    (define blocker-x (+ nx (* 7.5 (/ (- ex nx) (dist2d nx ny ex ey)))))
    (define blocker-y (+ ny (* 7.5 (/ (- ey ny) (dist2d nx ny ex ey)))))
    (define obs-bldgs (append bldgs (list (mk-u 4 'supply-depot blocker-x blocker-y))))
    (define bfs-fn (lambda (px py)
                     ;; Block direct central ray via unpathable cliff stub
                     (if (<= (dist2d px py blocker-x blocker-y) 3.5) +inf.0 20.0)))
    (define gf-pt
      (pick-safe-staging-point
       #:domain 'ground-front
       #:ally-townhalls ths #:ally-buildings obs-bldgs
       #:enemy-units '() #:enemy-anchor-x ex #:enemy-anchor-y ey
       #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
       #:map-width 200.0 #:map-height 200.0 #:bfs-dist-fn bfs-fn))
    (check-true (format "corner-~a-ground-front-bfs-pathable-and-obstacle-clear" label)
                (and (>= (car gf-pt) 6.0) (<= (car gf-pt) 194.0)
                     (>= (cdr gf-pt) 6.0) (<= (cdr gf-pt) 194.0)
                     (>= (dist2d (car gf-pt) (cdr gf-pt) blocker-x blocker-y) 3.0))
                (format "gf-pt=~a blocker=(~a,~a)" gf-pt blocker-x blocker-y))
    ;; Ground-flank & drop domains valid and distinct from main base
    (define flank-pt
      (pick-safe-staging-point
       #:domain 'ground-flank
       #:ally-townhalls ths #:ally-buildings bldgs
       #:enemy-units '() #:enemy-anchor-x ex #:enemy-anchor-y ey
       #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
       #:map-width 200.0 #:map-height 200.0))
    (define drop-pt
      (pick-safe-staging-point
       #:domain 'drop
       #:ally-townhalls ths #:ally-buildings bldgs
       #:enemy-units '() #:enemy-anchor-x ex #:enemy-anchor-y ey
       #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
       #:map-width 200.0 #:map-height 200.0))
    (check-true (format "corner-~a-flank-and-drop-valid" label)
                (and (>= (car flank-pt) 6.0) (<= (car flank-pt) 194.0)
                     (>= (cdr flank-pt) 6.0) (<= (cdr flank-pt) 194.0)
                     (>= (car drop-pt) 5.0)  (<= (car drop-pt) 195.0)
                     (>= (cdr drop-pt) 5.0)  (<= (cdr drop-pt) 195.0))
                (format "flank=~a drop=~a" flank-pt drop-pt)))

  ;; Anchor smoothing: holds safe prev-pt within <= 4.5t drift, shifts immediately if enemy < 16t
  (define th-sw (list (mk-u 1 'command-center 32.5 32.5) (mk-u 2 'command-center 56.5 32.5)))
  (define p0 (pick-safe-staging-point #:domain 'ground-front #:ally-townhalls th-sw #:ally-buildings th-sw
                                      #:enemy-units '() #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                                      #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5))
  (define p-near (cons (+ (car p0) 2.0) (cdr p0)))
  (define p-smooth (pick-safe-staging-point #:domain 'ground-front #:ally-townhalls th-sw #:ally-buildings th-sw
                                            #:enemy-units '() #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                                            #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                                            #:prev-pt p-near))
  (define p-unsafe (pick-safe-staging-point #:domain 'ground-front #:ally-townhalls th-sw #:ally-buildings th-sw
                                            #:enemy-units (list (mk-u 901 'stalker (+ (car p-near) 4.0) (cdr p-near)))
                                            #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                                            #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                                            #:prev-pt p-near))
  (check-true "staging-anchor-smoothing-holds-safe-and-shifts-when-unsafe"
              (and (<= (dist2d (car p-smooth) (cdr p-smooth) (car p-near) (cdr p-near)) 0.01)
                   (> (dist2d (car p-unsafe) (cdr p-unsafe) (car p-near) (cdr p-near)) 1.0))
              (format "p-near=~a p-smooth=~a p-unsafe=~a" p-near p-smooth p-unsafe)))

;; =============================================================================
;; 2. Role-Lease Priority Integration (`'staging-group` 50 / `'strike-group` 55)
;; =============================================================================
(let ()
  (check-true "role-lease-priority-ordering"
              (and (> (role-lease-priority 'staging-group) (role-lease-priority 'army))
                   (> (role-lease-priority 'strike-group) (role-lease-priority 'staging-group))
                   (< (role-lease-priority 'strike-group) (role-lease-priority 'creep-queen))
                   (< (role-lease-priority 'strike-group) (role-lease-priority 'scout))
                   (< (role-lease-priority 'strike-group) (role-lease-priority 'door-guard))
                   (< (role-lease-priority 'strike-group) (role-lease-priority 'builder)))
              (format "staging=~a strike=~a" (role-lease-priority 'staging-group) (role-lease-priority 'strike-group)))

  ;; A unit holding a `'door-guard` lease MUST NOT be hijacked by `step-staging-groups!`
  (define mgr (make-staging-group-manager))
  (define leases (make-hasheqv))
  (acquire-unit-lease! leases 501 'door-guard 200 100 #:x 40.0 #:y 32.5)
  (define u-guard (mk-u 501 'zealot 40.0 32.5))
  (define u-free  (mk-u 502 'zealot 34.0 32.5))
  (define front-units (for/list ([i (in-range 5)]) (mk-u (+ 600 i) 'stalker 110.0 (+ 100.0 i))))
  (define probes (list (mk-u 701 'probe 28.0 32.5)))
  (define bldgs (list (mk-u 801 'nexus 32.5 32.5) (mk-u 802 'gateway 36.0 36.0)))
  (define res
    (step-staging-groups! mgr #:frame 220 #:live-obs? #t
                          #:ally-units (append probes (list u-guard u-free) front-units)
                          #:combat-units (append (list u-guard u-free) front-units)
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:role-leases leases #:in-production-counts (hasheq 'zealot 2)))
  (check-true "door-guard-lease-never-hijacked-by-staging"
              (and (staging-step-result-active? res)
                   (not (set-member? (staging-step-result-handled-tags res) 501))
                   (set-member? (staging-step-result-handled-tags res) 502))
              (format "handled=~a" (staging-step-result-handled-tags res))))

;; =============================================================================
;; 3. Lifecycle Hysteresis (`'staging -> 'dispatched -> 'regrouping -> 'staging`)
;; =============================================================================
(let ()
  (define mgr (make-staging-group-manager))
  (define drones (list (mk-u 1001 'drone 28.0 32.5)))
  (define bldgs (list (mk-u 1010 'lair 32.5 32.5) (mk-u 1011 'spire 36.0 36.0)))
  (define mutas-3 (for/list ([i (in-range 3)]) (mk-u (+ 1100 i) 'mutalisk 34.0 (+ 32.0 i) #:hp 120.0 #:flying #t)))
  ;; Step 1: 3 Mutalisks (< min 6) -> `'staging`
  (define r1
    (step-staging-groups! mgr #:frame 5000 #:live-obs? #t
                          #:ally-units (append drones mutas-3) #:combat-units mutas-3
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'mutalisk 3)))
  (define anch (hash-ref (staging-step-result-anchors r1) 'air-harass-muta (cons 20.0 20.0)))
  ;; Step 2: 6 cohesive Mutalisks at anchor -> `'dispatched`
  (define mutas-6 (for/list ([i (in-range 6)]) (mk-u (+ 1100 i) 'mutalisk (car anch) (+ (cdr anch) (* 0.4 i)) #:hp 120.0 #:flying #t)))
  (define r2
    (step-staging-groups! mgr #:frame 5040 #:live-obs? #t
                          #:ally-units (append drones mutas-6) #:combat-units mutas-6
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'mutalisk 0)))
  ;; Step 3: After min-dwell (`+110f`), attrited to 2 low-HP Mutas (`< 0.55x` & `< 45%` HP) -> `'regrouping`
  (define mutas-2-low
    (list (mk-u 1100 'mutalisk 120.0 120.0 #:hp 40.0 #:max-hp 120.0 #:flying #t)
          (mk-u 1101 'mutalisk 121.0 120.0 #:hp 45.0 #:max-hp 120.0 #:flying #t)))
  (define r3
    (step-staging-groups! mgr #:frame 5150 #:live-obs? #t
                          #:ally-units (append drones mutas-2-low) #:combat-units mutas-2-low
                          #:ally-buildings bldgs #:enemy-units (list (mk-u 1901 'marine 130.0 120.0))
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (define st3 (staging-group-state (hash-ref (staging-group-manager-groups mgr) 'air-harass-muta)))
  ;; Step 4: Back at anchor (`<= 14t`) and clear of enemies (`> 16t`) -> returns to `'staging`
  (define mutas-2-home
    (list (mk-u 1100 'mutalisk (car anch) (cdr anch) #:hp 100.0 #:max-hp 120.0 #:flying #t)
          (mk-u 1101 'mutalisk (+ (car anch) 1.0) (cdr anch) #:hp 100.0 #:max-hp 120.0 #:flying #t)))
  (define _r4
    (step-staging-groups! mgr #:frame 5200 #:live-obs? #t
                          #:ally-units (append drones mutas-2-home) #:combat-units mutas-2-home
                          #:ally-buildings bldgs #:enemy-units (list (mk-u 1901 'marine 150.0 150.0))
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (define st4 (staging-group-state (hash-ref (staging-group-manager-groups mgr) 'air-harass-muta)))
  (check-true "staging-lifecycle-hysteresis-full-cycle"
              (and (memq 'air-harass-muta (staging-step-result-staging-groups r1))
                   (memq 'air-harass-muta (staging-step-result-dispatched-groups r2))
                   (eq? st3 'regrouping)
                   (eq? st4 'staging))
              (format "r1-stg=~a r2-disp=~a st3=~a st4=~a"
                      (staging-step-result-staging-groups r1)
                      (staging-step-result-dispatched-groups r2) st3 st4)))

;; =============================================================================
;; 4. All 5 Hard Safety Overrides
;; =============================================================================
(let ()
  (define drones (list (mk-u 2001 'drone 28.0 32.5)))
  (define bldgs (list (mk-u 2010 'hive 32.5 32.5) (mk-u 2011 'hatchery 56.5 32.5) (mk-u 2012 'spire 36.0 36.0)))

  ;; Override #1: Emergency Home-Defense Scramble releases Mutalisks, protects `< 6` Corruptors vs 10 Tempests
  (define mgr1 (make-staging-group-manager))
  (define mutas-2 (list (mk-u 2101 'mutalisk 34.0 34.0 #:hp 120.0 #:flying #t)
                        (mk-u 2102 'mutalisk 35.0 34.0 #:hp 120.0 #:flying #t)))
  (define corrs-2 (list (mk-u 2201 'corruptor 33.0 33.0 #:hp 200.0 #:flying #t)
                        (mk-u 2202 'corruptor 34.0 33.0 #:hp 200.0 #:flying #t)))
  (define tempests-10 (for/list ([i (in-range 10)]) (mk-u (+ 2800 i) 'tempest 44.0 (+ 30.0 (* 0.5 i)) #:hp 200.0 #:shield 125.0 #:flying #t)))
  (define r-o1
    (step-staging-groups! mgr1 #:frame 6000 #:live-obs? #t
                          #:ally-units (append drones mutas-2 corrs-2)
                          #:combat-units (append mutas-2 corrs-2)
                          #:ally-buildings bldgs #:enemy-units tempests-10
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 10 #:under-home-attack? #t #:enemy-near-main? #t))
  (check-true "override-1-home-scramble-releases-mutas-protects-2-corruptors-vs-10-tempests"
              (and (memq 'air-harass-muta (staging-step-result-dispatched-groups r-o1))
                   (memq 'air-anti-cap (staging-step-result-staging-groups r-o1))
                   (set-member? (staging-step-result-handled-tags r-o1) 2201)
                   (ormap (lambda (a) (and (eq? (car a) 'move) (= (second a) 2201) (< (third a) 30.0)))
                          (staging-step-result-preserved-actions r-o1)))
              (format "disp=~a stg=~a pres=~a"
                      (staging-step-result-dispatched-groups r-o1)
                      (staging-step-result-staging-groups r-o1)
                      (staging-step-result-preserved-actions r-o1)))

  ;; Override #2: In-Contact Reflex — ground staging ALWAYS releases to Phase 5b (ZERO `'move`!);
  ;; strong air pack commits (`>= 0.70x`), weak air unit retreats (`< 0.55x`) with `'move`!
  (define mgr2a (make-staging-group-manager))
  (define hellions-2 (list (mk-u 2301 'hellion 52.0 32.0 #:hp 90.0)
                           (mk-u 2302 'hellion 53.0 32.0 #:hp 90.0)))
  (define r-o2-commit
    (step-staging-groups! mgr2a #:frame 6100 #:live-obs? #t
                          #:ally-units (append (list (mk-u 2002 'scv 28.0 32.5)) hellions-2)
                          #:combat-units hellions-2
                          #:ally-buildings (list (mk-u 2020 'command-center 32.5 32.5) (mk-u 2021 'factory 36.0 36.0))
                          #:enemy-units (list (mk-u 2901 'zergling 58.0 32.0 #:hp 35.0))
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (define mgr2b (make-staging-group-manager))
  (define roaches-6 (for/list ([i (in-range 6)]) (mk-u (+ 2920 i) 'roach 58.0 (+ 30.0 i) #:hp 145.0)))
  (define r-o2-ground-no-move
    (step-staging-groups! mgr2b #:frame 6100 #:live-obs? #t
                          #:ally-units (append (list (mk-u 2002 'scv 28.0 32.5)) (list (car hellions-2)))
                          #:combat-units (list (car hellions-2))
                          #:ally-buildings (list (mk-u 2020 'command-center 32.5 32.5) (mk-u 2021 'factory 36.0 36.0))
                          #:enemy-units roaches-6
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (define mgr2c (make-staging-group-manager))
  (define muta-lone (list (mk-u 2311 'mutalisk 48.0 32.0 #:hp 120.0 #:flying #t)))
  (define marines-8 (for/list ([i (in-range 8)]) (mk-u (+ 2940 i) 'marine 56.0 (+ 29.0 (* 0.5 i)) #:hp 45.0)))
  (define r-o2-air-retreat
    (step-staging-groups! mgr2c #:frame 6100 #:live-obs? #t
                          #:ally-units (append drones muta-lone)
                          #:combat-units muta-lone
                          #:ally-buildings bldgs
                          #:enemy-units marines-8
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (check-true "override-2-in-contact-reflex-ground-never-moves-and-weak-air-retreats"
              (and (not (set-member? (staging-step-result-handled-tags r-o2-commit) 2301))
                   (not (set-member? (staging-step-result-handled-tags r-o2-ground-no-move) 2301))
                   (not (ormap (lambda (a) (eq? (car a) 'move)) (staging-step-result-actions r-o2-ground-no-move)))
                   (set-member? (staging-step-result-handled-tags r-o2-air-retreat) 2311)
                   (ormap (lambda (a) (and (eq? (car a) 'move) (= (second a) 2311) (< (third a) 48.0)))
                          (staging-step-result-actions r-o2-air-retreat)))
              (format "gnd-handled=~a gnd-acts=~a air-acts=~a"
                      (staging-step-result-handled-tags r-o2-ground-no-move)
                      (staging-step-result-actions r-o2-ground-no-move)
                      (staging-step-result-actions r-o2-air-retreat)))

  ;; Override #3: Production-Aware Anti-Stall (`112f` w/ 0 in prod) + Endgame Override (`supply >= 165` / `endgame-hunt`)
  (define mgr3 (make-staging-group-manager))
  (define r-o3-eg
    (step-staging-groups! mgr3 #:frame 7000 #:live-obs? #t
                          #:ally-units (append drones mutas-2) #:combat-units mutas-2
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:supply-used 170))
  (define mgr3b (make-staging-group-manager))
  (define _r-o3-t0
    (step-staging-groups! mgr3b #:frame 7000 #:live-obs? #t
                          #:ally-units (append drones mutas-2) #:combat-units mutas-2
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq)))
  (define r-o3-t112
    (step-staging-groups! mgr3b #:frame 7120 #:live-obs? #t
                          #:ally-units (append drones mutas-2) #:combat-units mutas-2
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq)))
  (check-true "override-3-endgame-and-zero-prod-antistall-force-dispatch"
              (and (memq 'air-harass-muta (staging-step-result-dispatched-groups r-o3-eg))
                   (memq 'air-harass-muta (staging-step-result-dispatched-groups r-o3-t112)))
              (format "eg=~a t112=~a"
                      (staging-step-result-dispatched-groups r-o3-eg)
                      (staging-step-result-dispatched-groups r-o3-t112)))

  ;; Override #4: Live Full-Match Gate Only (Arena skirmish w/ 0 THs or 1 lone OC & 0 workers bypasses completely!)
  (define mgr4 (make-staging-group-manager))
  (define r-o4-arena
    (step-staging-groups! mgr4 #:frame 200 #:live-obs? #t
                          #:ally-units mutas-2 #:combat-units mutas-2
                          #:ally-buildings '() #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (define r-o4-lone-oc
    (step-staging-groups! mgr4 #:frame 220 #:live-obs? #t
                          #:ally-units mutas-2 #:combat-units mutas-2
                          #:ally-buildings (list (mk-u 2099 'orbital-command 32.5 32.5))
                          #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  (check-true "override-4-live-full-match-gate-bypasses-arena-skirmishes"
              (and (not (staging-step-result-active? r-o4-arena))
                   (null? (staging-step-result-actions r-o4-arena))
                   (not (staging-step-result-active? r-o4-lone-oc))
                   (null? (staging-step-result-actions r-o4-lone-oc)))
              (format "arena=~a lone-oc=~a"
                      (staging-step-result-active? r-o4-arena)
                      (staging-step-result-active? r-o4-lone-oc)))

  ;; Override #5: Ground `'main-reinforce` emits `attack-pos` ONLY (never passive `move` -> `OBRet = 0`)
  (define mgr5 (make-staging-group-manager))
  (define front-marines (for/list ([i (in-range 6)]) (mk-u (+ 2400 i) 'marine 115.0 (+ 110.0 i) #:hp 45.0)))
  (define new-home-marines (list (mk-u 2501 'marine 34.0 32.5 #:hp 45.0)
                                 (mk-u 2502 'marine 35.0 33.0 #:hp 45.0)))
  (define r-o5
    (step-staging-groups! mgr5 #:frame 4000 #:live-obs? #t
                          #:ally-units (append (list (mk-u 2003 'scv 28.0 32.5)) front-marines new-home-marines)
                          #:combat-units (append front-marines new-home-marines)
                          #:ally-buildings (list (mk-u 2030 'command-center 32.5 32.5)
                                                 (mk-u 2031 'command-center 56.5 32.5)
                                                 (mk-u 2032 'barracks 36.0 36.0))
                          #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'marine 4)))
  (define o5-acts (staging-step-result-actions r-o5))
  (check-true "override-5-ground-main-reinforce-uses-attack-pos-only"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-o5))
                   (pair? o5-acts)
                   (andmap (lambda (a) (eq? (car a) 'attack-pos)) o5-acts)
                   (set-member? (staging-step-result-handled-tags r-o5) 2501)
                   (not (set-member? (staging-step-result-handled-tags r-o5) 2400)))
              (format "acts=~a handled=~a" o5-acts (staging-step-result-handled-tags r-o5))))

;; =============================================================================
;; 5. Generalizable Combat Concave, Front-to-Back, Caster Leash & Zerg Surround/Uphill
;; =============================================================================
(let ()
  ;; 5a. PvP Front-to-Back Layering: Stalker ahead of Zealot at 11t holds behind Zealot; in-range Stalker fires!
  (define z1 (mk-u 3101 'zealot 70.0 50.0 #:hp 100.0 #:shield 50.0))
  (define s-ahead (mk-u 3102 'stalker 73.0 50.0 #:hp 80.0 #:shield 80.0))
  (define s-inrange (mk-u 3103 'stalker 78.5 50.0 #:hp 80.0 #:shield 80.0))
  (define e-pvp (list (mk-u 3901 'stalker 84.0 50.0 #:hp 80.0 #:shield 80.0)))
  (define ctx-pvp (build-combat-positioning-context (list z1 s-ahead s-inrange) e-pvp))
  (define-values (shx shy) (compute-front-to-back-advance-pt ctx-pvp s-ahead 84.0 50.0 6.0))
  (define-values (sirx _siry) (compute-front-to-back-advance-pt ctx-pvp s-inrange 84.0 50.0 6.0))
  (check-true "front-to-back-pvp-stalker-holds-behind-zealot-and-fires-in-range"
              (and shx shy (< shx 70.0) (not sirx))
              (format "shx=~a shy=~a sirx=~a" shx shy sirx))

  ;; 5b. TvP Front-to-Back Layering: Marine ahead of Marauder at 10t holds behind Marauder
  (define ma1 (mk-u 3201 'marauder 70.0 50.0 #:hp 125.0))
  (define mr-ahead (mk-u 3202 'marine 72.5 50.0 #:hp 45.0))
  (define ctx-tvp (build-combat-positioning-context (list ma1 mr-ahead) e-pvp))
  (define-values (mhx mhy) (compute-front-to-back-advance-pt ctx-tvp mr-ahead 84.0 50.0 5.0))
  (check-true "front-to-back-tvp-marine-holds-behind-marauder"
              (and mhx mhy (< mhx 70.0))
              (format "mhx=~a mhy=~a" mhx mhy))

  ;; 5c. Terran Caster Rear Leash (Medivac / Raven / Ghost `-2.5t` behind Bio vs 0-AA Zerglings!)
  (define bio-6 (for/list ([i (in-range 6)]) (mk-u (+ 3300 i) 'marine 70.0 (+ 48.0 (* 0.6 i)) #:hp 45.0)))
  (define med-ahead (mk-u 3350 'medivac 73.0 50.0 #:hp 150.0 #:flying #t))
  (define rav-ahead (mk-u 3351 'raven 72.0 50.0 #:hp 140.0 #:flying #t))
  (define gho-ahead (mk-u 3352 'ghost 72.5 50.0 #:hp 100.0))
  (define lings-8 (for/list ([i (in-range 8)]) (mk-u (+ 3950 i) 'zergling 84.0 (+ 48.0 (* 0.5 i)) #:hp 35.0)))
  (define ctx-tvz (build-combat-positioning-context (append bio-6 (list med-ahead rav-ahead gho-ahead)) lings-8))
  (define-values (mlx _mly) (compute-caster-rear-leash-pt ctx-tvz med-ahead))
  (define-values (rlx _rly) (compute-caster-rear-leash-pt ctx-tvz rav-ahead))
  (define-values (glx _gly) (compute-caster-rear-leash-pt ctx-tvz gho-ahead))
  (check-true "terran-caster-rear-leash-medivac-raven-ghost-behind-bio"
              (and mlx (< mlx 68.5)
                   rlx (< rlx 68.5)
                   glx (< glx 68.5))
              (format "mlx=~a rlx=~a glx=~a" mlx rlx glx))

  ;; 5d. Zerg Two-Wing Surround (`10` Lings -> outer 40% flank laterally `±3.0..4.0t`, ALWAYS `use-move? = #f`;
  ;;     Roaches/Ravagers/Hydras skipped; optional `#:pathable?` rejects wall points!)
  (define z-lings-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 3400 i) 'zergling 70.0 (+ 45.0 (* 1.0 i)) #:hp 35.0)))
  (define e-marines (for/list ([i (in-range 6)]) (mk-u (+ 3970 i) 'marine 81.0 (+ 48.5 (* 0.6 i)) #:hp 45.0)))
  (define ctx-surr (build-combat-positioning-context z-lings-10 e-marines))
  (define wing-results
    (for/list ([u (in-list z-lings-10)])
      (define-values (wx wy um?) (compute-zerg-surround-wing-pt ctx-surr u e-marines))
      (list (hash-ref u 'id) wx wy um?)))
  (define flanked-cnt (count (lambda (r) (and (second r) #t)) wing-results))
  (define any-use-move? (ormap fourth wing-results))
  (define left-wing-y (third (first wing-results)))
  (define right-wing-y (third (last wing-results)))
  (define-values (blocked-wx _blocked-wy _blocked-um?)
    (compute-zerg-surround-wing-pt ctx-surr (first z-lings-10) e-marines
                                   #:pathable? (lambda (_x _y) #f)))
  (define z-roaches-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 3450 i) 'roach 70.0 (+ 45.0 (* 1.0 i)) #:hp 145.0)))
  (define ctx-roach-surr (build-combat-positioning-context z-roaches-10 e-marines))
  (define roach-flanked-cnt
    (count (lambda (u)
             (define-values (wx _wy _um?) (compute-zerg-surround-wing-pt ctx-roach-surr u e-marines))
             (and wx #t))
           z-roaches-10))
  (check-true "zerg-two-wing-surround-zergling-only-no-move-and-pathable-checked"
              (and (= flanked-cnt 4)
                   (not any-use-move?)
                   left-wing-y right-wing-y
                   (>= (abs (- right-wing-y left-wing-y)) 6.0)
                   (<= (abs (- right-wing-y left-wing-y)) 9.0)
                   (not blocked-wx)
                   (= roach-flanked-cnt 0))
              (format "flanked=~a move?=~a left-y=~a right-y=~a blocked=~a roach-flanked=~a"
                      flanked-cnt any-use-move? left-wing-y right-wing-y blocked-wx roach-flanked-cnt))

  ;; 5d2. Protoss Stalker Front-to-Back Tightened (`1.2t` rear offset within `8..14t` approach; skips at `7.5t` & `15t`)
  (define s-too-close (mk-u 3104 'stalker 76.5 50.0 #:hp 80.0 #:shield 80.0)) ;; d=7.5t (< 8t)
  (define s-too-far   (mk-u 3105 'stalker 69.0 50.0 #:hp 80.0 #:shield 80.0)) ;; d=15.0t (> 14t)
  (define-values (scx _scy) (compute-front-to-back-advance-pt ctx-pvp s-too-close 84.0 50.0 6.0))
  (define-values (sfx _sfy) (compute-front-to-back-advance-pt ctx-pvp s-too-far 84.0 50.0 6.0))
  (check-true "front-to-back-protoss-stalker-tightened-1.2t-and-8-to-14t-window"
              (and shx (<= (abs (- shx (- 70.0 1.2))) 0.15)
                   (not scx) (not sfx))
              (format "shx=~a scx=~a sfx=~a" shx scx sfx))

  ;; 5e. Zerg Uphill Ramp Brake (`z_enemy - z_ally >= 1.5`) vs Flat-Ground Control (`dz = 0.0`) & Ravager Control
  (define z-low (for/list ([i (in-range 6)]) (mk-u (+ 3500 i) 'roach 70.0 (+ 48.0 i) #:hp 145.0 #:z 8.0)))
  (define tanks-high (list (mk-u 3980 'siege-tank-sieged 82.0 50.0 #:hp 175.0 #:z 10.0)
                           (mk-u 3981 'siege-tank-sieged 83.0 51.0 #:hp 175.0 #:z 10.0)
                           (mk-u 3982 'marine 81.0 50.0 #:hp 45.0 #:z 10.0)
                           (mk-u 3983 'marine 81.0 51.0 #:hp 45.0 #:z 10.0)
                           (mk-u 3984 'marine 81.0 49.0 #:hp 45.0 #:z 10.0)
                           (mk-u 3985 'marine 81.0 52.0 #:hp 45.0 #:z 10.0)))
  (define tanks-flat (map (lambda (e) (hash-set e 'z 8.0)) tanks-high))
  (define ctx-uphill (build-combat-positioning-context z-low tanks-high))
  (define ctx-flat   (build-combat-positioning-context z-low tanks-flat))
  (define ctx-rav    (build-combat-positioning-context (cons (mk-u 3599 'ravager 69.0 50.0 #:hp 120.0 #:z 8.0) z-low) tanks-high))
  (define-values (uhx uhy) (zerg-uphill-ramp-hold-pt ctx-uphill (car z-low)))
  (define-values (flx _fly) (zerg-uphill-ramp-hold-pt ctx-flat (car z-low)))
  (define-values (rvx _rvy) (zerg-uphill-ramp-hold-pt ctx-rav (car z-low)))
  (check-true "zerg-uphill-ramp-brake-holds-uphill-and-commits-flat-or-with-ravager"
              (and uhx uhy
                   (>= (dist2d uhx uhy 82.0 50.0) 14.5)
                   (not flx)
                   (not rvx))
              (format "uh=(~a,~a) fl=~a rv=~a" uhx uhy flx rvx))

  ;; 5f. Pre-Contact Lateral Concave Spread (`>= 6` ranged vs enemy splash at 11t -> laterally fanned >= 2t apart!)
  (define clumped-marines
    (for/list ([i (in-range 8)])
      (mk-u (+ 3600 i) 'marine 70.0 (+ 49.6 (* 0.1 i)) #:hp 45.0)))
  (define enemy-splash (list (mk-u 3990 'colossus 81.0 50.0 #:hp 200.0 #:shield 150.0)
                             (mk-u 3991 'stalker 80.5 50.5 #:hp 80.0 #:shield 80.0)))
  (define ctx-cc (build-combat-positioning-context clumped-marines enemy-splash))
  (define cc-ys
    (for/list ([u (in-list clumped-marines)])
      (define-values (ax ay) (compute-lateral-concave-spread-pt ctx-cc u 81.0 50.0 5.0))
      (and ax ay ay)))
  (define valid-cc-ys (filter real? cc-ys))
  (check-true "pre-contact-lateral-concave-fans-ranged-squad-against-splash"
              (and (>= (length valid-cc-ys) 6)
                   (>= (- (apply max valid-cc-ys) (apply min valid-cc-ys)) 9.0))
              (format "valid-ys=~a" valid-cc-ys)))

;; =============================================================================
;; 6. Runtime Sync Gates for `#1434` Div-5 Macro
;; =============================================================================
(let ()
  ;; 6a. 0-Stargate Protoss Air Upgrade Block: CyberCore ready, WarpGate done, 0 Stargates -> ZERO air upgrades!
  (define rt-p-air (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-probes (for/list ([i (in-range 22)]) (mk-u (+ 4100 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define p-stalkers (for/list ([i (in-range 6)]) (mk-u (+ 4150 i) 'stalker 56.0 (+ 30.0 i) #:hp 80.0 #:shield 80.0)))
  (define p-bldgs-0sg
    (list (mk-u 4001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 4002 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 4003 'gateway 38.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 4004 'cybernetics-core 39.0 37.0 #:hp 550.0 #:shield 550.0)))
  (define a-p-air
    (step-layer2-economy!
     rt-p-air
     (mk-live-obs 'Protoss 'Zerg 4200 #:minerals 450 #:gas 350 #:supply-used 40 #:supply-cap 62
                  #:mineral-harvesters 18 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append p-probes p-stalkers)
                  #:ally-buildings p-bldgs-0sg
                  #:enemy-units (list (mk-u 4901 'mutalisk 120.0 120.0 #:hp 120.0 #:flying #t)))))
  (define leaked-air-upg?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'research)
                  (memq (second a) '(protoss-air-weapons-1 protoss-air-armor-1
                                     protoss-air-weapons-2 protoss-air-armor-2))))
           a-p-air))
  (check-true "div5-sync-protoss-zero-stargate-blocks-air-upgrades"
              (not leaked-air-upg?)
              (format "acts=~a" a-p-air))

  ;; 6b. PvT Observer #2 Deferral vs Widow Mines: 1 Obs alive, 0 Immortals, enemy Widow Mine (0 Banshees) -> Immortal, NOT Obs #2!
  (define rt-pvt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-obs1 (mk-u 4201 'observer 62.0 33.0 #:hp 40.0 #:shield 20.0 #:flying #t))
  (define p-bldgs-robo
    (append p-bldgs-0sg
            (list (mk-u 4005 'robotics-facility 42.0 35.0 #:hp 450.0 #:shield 450.0)
                  (mk-u 4006 'pylon 37.5 34.0 #:hp 200.0 #:shield 200.0)
                  (mk-u 4007 'assimilator 30.0 37.0 #:hp 300.0 #:shield 300.0)
                  (mk-u 4008 'assimilator 30.0 28.0 #:hp 300.0 #:shield 300.0))))
  (define a-pvt
    (step-layer2-economy!
     rt-pvt
     (mk-live-obs 'Protoss 'Terran 5200 #:minerals 500 #:gas 250 #:supply-used 46 #:supply-cap 70
                  #:mineral-harvesters 20 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append p-probes p-stalkers (list p-obs1))
                  #:ally-buildings p-bldgs-robo
                  #:enemy-units (list (mk-u 4910 'widow-mine-burrowed 80.0 50.0 #:hp 90.0)
                                      (mk-u 4911 'marine 82.0 50.0 #:hp 45.0)))))
  (define trained-obs2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'observer))) a-pvt))
  (define trained-imm?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'immortal))) a-pvt))
  (check-true "div5-sync-pvt-defers-observer2-for-immortal-vs-widow-mines"
              (and (not trained-obs2?) trained-imm?)
              (format "obs2?=~a imm?=~a acts=~a" trained-obs2? trained-imm? a-pvt))

  ;; 6c. Faster Terran Stimpack: 2 CCs + Factory + BarracksTechLab + 100M/100G -> emits `'stimpack`!
  (define rt-t-stim (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-26 (for/list ([i (in-range 26)]) (mk-u (+ 4300 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0)))
  (define mar-4   (for/list ([i (in-range 4)]) (mk-u (+ 4330 i) 'marine 52.0 (+ 31.0 (* 0.5 i)) #:hp 45.0)))
  (define t-bldgs-stim
    (list (mk-u 4350 'orbital-command 32.5 32.5 #:hp 1500.0)
          (mk-u 4351 'orbital-command 56.5 32.5 #:hp 1500.0)
          (hash-set (mk-u 4352 'barracks 38.0 34.0 #:hp 1000.0) 'add-on-tag 4353)
          (mk-u 4353 'barracks-techlab 40.5 34.0 #:hp 400.0)
          (hash-set (mk-u 4354 'factory 38.0 39.0 #:hp 1250.0) 'add-on-tag 4355)
          (mk-u 4355 'factory-techlab 40.5 39.0 #:hp 400.0)
          (mk-u 4356 'starport 38.0 43.0 #:hp 1300.0 #:build-progress 0.5)
          (mk-u 4357 'refinery 30.0 37.0 #:hp 500.0)
          (mk-u 4358 'refinery 30.0 28.0 #:hp 500.0)))
  (define a-t-stim
    (step-layer2-economy!
     rt-t-stim
     (mk-live-obs 'Terran 'Zerg 4200 #:minerals 225 #:gas 105 #:supply-used 36 #:supply-cap 54
                  #:mineral-harvesters 20 #:vespene-harvesters 6
                  #:ally-units (append scvs-26 mar-4) #:ally-buildings t-bldgs-stim #:enemy-units '())))
  (define researched-stim?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (eq? (second a) 'stimpack))) a-t-stim))
  (check-true "div5-sync-terran-stimpack-fires-at-2cc-1factory-100g"
              researched-stim?
              (format "stim?=~a acts=~a" researched-stim? a-t-stim))

  ;; 6d. ZvP Early Droning & 4-Parallel Tech Cap:
  ;;   (i) Peaceful 2-base Zerg (24 Drones) -> ZERO peaceful Spine Crawler & ZERO Evo Chamber!
  ;;   (ii) 2-base Zerg with HydraDen + Lair vs 3 Phoenixes (0 Capital Air) -> ZERO Spire!
  (define rt-z-eco (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-drones-24 (for/list ([i (in-range 24)]) (mk-u (+ 4400 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define z-bldgs-2b
    (list (mk-u 4450 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 4451 'hatchery 56.5 32.5 #:hp 1500.0)
          (mk-u 4452 'spawning-pool 36.0 36.0 #:hp 1000.0)
          (mk-u 4453 'roach-warren 38.0 34.0 #:hp 850.0)
          (mk-u 4454 'hydralisk-den 38.0 38.0 #:hp 850.0)))
  (define phx-3 (for/list ([i (in-range 3)]) (mk-u (+ 4950 i) 'phoenix 120.0 (+ 100.0 i) #:hp 120.0 #:shield 60.0 #:flying #t)))
  (define a-z-eco
    (step-layer2-economy!
     rt-z-eco
     (mk-live-obs 'Zerg 'Protoss 4800 #:minerals 450 #:gas 250 #:supply-used 42 #:supply-cap 66
                  #:mineral-harvesters 20 #:vespene-harvesters 4
                  #:ally-units (append z-drones-24 (list (mk-u 4480 'roach 54.0 32.5 #:hp 145.0)
                                                         (mk-u 4481 'roach 55.0 32.5 #:hp 145.0)))
                  #:ally-buildings z-bldgs-2b
                  #:enemy-units phx-3)))
  (define built-spine? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spine-crawler))) a-z-eco))
  (define built-evo?   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'evolution-chamber))) a-z-eco))
  (define built-bn?    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'baneling-nest))) a-z-eco))
  (define built-spire? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spire))) a-z-eco))
  (check-true "div5-sync-zvp-blocks-early-spine-evo-dual-t15-and-spire-over-hydraden"
              (and (not built-spine?) (not built-evo?) (not built-bn?) (not built-spire?))
              (format "spine?=~a evo?=~a bn?=~a spire?=~a acts=~a" built-spine? built-evo? built-bn? built-spire? a-z-eco)))

;; =============================================================================
;; 7. Pass 3B Fogged-Colossus Retention & Instant Dead-Tag Prune (`unit-mode-micro`)
;; =============================================================================
(let ()
  (define tr (make-unit-mode-tracker))
  (define viks-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 5100 i) 'viking-fighter 60.0 (+ 58.0 (* 0.5 i)) #:hp 135.0 #:max-hp 135.0 #:flying #t)))
  (define col (mk-u 5801 'colossus 95.0 60.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0))
  (define stalks-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 5810 i) 'stalker 70.0 (+ 58.0 (* 0.7 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  ;; Frame 100: Colossus seen on right edge at 35t (farther than old 32t radius!) -> MUST NOT land!
  (sync-unit-mode-tracker! tr viks-6 (cons col stalks-4) 100 #:track-air-memory? #t)
  (define dirs-vis (plan-viking-modes viks-6 (cons col stalks-4) #:tracker tr #:current-frame 100))
  ;; Frame 150 (+50f > old 24f prune!): Colossus stepped into Fog on right edge (`35t` from Vikings) -> MUST STILL NOT land!
  (sync-unit-mode-tracker! tr viks-6 stalks-4 150 #:track-air-memory? #t)
  (define dirs-fog (plan-viking-modes viks-6 stalks-4 #:tracker tr #:current-frame 150))
  ;; Frame 170: Colossus tag 5801 arrives in `dead-tags` -> memory clears IMMEDIATELY -> Vikings land (`403`)!
  (sync-unit-mode-tracker! tr viks-6 stalks-4 170 #:dead-tags '(5801) #:track-air-memory? #t)
  (define dirs-dead (plan-viking-modes viks-6 stalks-4 #:tracker tr #:current-frame 170))
  (check-true "pass3b-viking-holds-fighter-vs-fogged-colossus-and-lands-on-dead-tag"
              (and (null? dirs-vis)
                   (null? dirs-fog)
                   (pair? dirs-dead)
                   (eq? (unit-mode-directive-ability (car dirs-dead)) 'morph-viking-assault))
              (format "vis=~a fog=~a dead=~a" (length dirs-vis) (length dirs-fog) (length dirs-dead))))

;; =============================================================================
;; 8. Loop 58 HOLD Bug #1 & Bug #2 Regression Guards
;; =============================================================================
(let ()
  ;; 8a. Bug #1: `'main-reinforce` clears `u2g` on `'dispatched`, graduates members, NEVER recaptures
  ;;     frontline units `> 26t` away or yanks them back to Main/Nat on attrition / low HP / suppress!
  (define mgr (make-staging-group-manager))
  (define drones (list (mk-u 6001 'drone 28.0 32.5)))
  (define bldgs (list (mk-u 6010 'hatchery 32.5 32.5)
                      (mk-u 6011 'hatchery 56.5 32.5)
                      (mk-u 6012 'roach-warren 36.0 36.0)))
  (define front-roaches (for/list ([i (in-range 6)]) (mk-u (+ 6100 i) 'roach 120.0 (+ 115.0 i) #:hp 145.0)))
  ;; Wave 1: 2 fresh Roaches at Main (`<= 24t`) -> enter `'main-reinforce` (`'staging`)
  (define wave-2 (list (mk-u 6201 'roach 35.0 32.5 #:hp 145.0)
                       (mk-u 6202 'roach 36.0 32.5 #:hp 145.0)))
  (define r1
    (step-staging-groups! mgr #:frame 4000 #:live-obs? #t
                          #:ally-units (append drones front-roaches wave-2)
                          #:combat-units (append front-roaches wave-2)
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'roach 2)))
  ;; Wave 1 reaches 4 cohesive Roaches at home (`<= 24t`) -> transitions to `'dispatched` -> MUST clear `u2g`!
  (define wave-4-home
    (for/list ([i (in-range 4)])
      (mk-u (+ 6201 i) 'roach 46.0 (+ 32.0 (* 0.4 i)) #:hp 145.0)))
  (define r2
    (step-staging-groups! mgr #:frame 4120 #:live-obs? #t
                          #:ally-units (append drones front-roaches wave-4-home)
                          #:combat-units (append front-roaches wave-4-home)
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'roach 0)))
  (define u2g-after-dispatch
    (for/list ([uid (in-list '(6201 6202 6203 6204))]
               #:when (hash-has-key? (staging-group-manager-unit->group mgr) uid))
      uid))
  ;; Step 3: Even 2 frames later while STILL near home, graduated units are NEVER recaptured!
  (define r3-near
    (step-staging-groups! mgr #:frame 4124 #:live-obs? #t
                          #:ally-units (append drones front-roaches wave-4-home)
                          #:combat-units (append front-roaches wave-4-home)
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5))
  ;; Step 4: Now at `dH=120`, attrited to 2 low-HP Roaches (`< 0.55x`, `30%` HP) + `combat-suppress-attack? #t`
  ;;         -> MUST NEVER be recaptured or yanked back to Main/Nat!
  (define wave-2-front-low
    (list (mk-u 6201 'roach 120.0 118.0 #:hp 40.0 #:max-hp 145.0)
          (mk-u 6202 'roach 121.0 118.0 #:hp 40.0 #:max-hp 145.0)))
  (define r4-front
    (step-staging-groups! mgr #:frame 4300 #:live-obs? #t
                          #:ally-units (append drones front-roaches wave-2-front-low)
                          #:combat-units (append front-roaches wave-2-front-low)
                          #:ally-buildings bldgs
                          #:enemy-units (list (mk-u 6901 'stalker 130.0 120.0 #:hp 80.0))
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:combat-suppress-attack? #t))
  ;; Step 5: With NO distant frontline, `combat-suppress-attack? #t` alone MUST NOT capture `'main-reinforce`!
  (define mgr-sup (make-staging-group-manager))
  (define r5-sup
    (step-staging-groups! mgr-sup #:frame 4400 #:live-obs? #t
                          #:ally-units (append drones wave-2)
                          #:combat-units wave-2
                          #:ally-buildings bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:combat-suppress-attack? #t))
  (check-true "bug1-main-reinforce-clears-u2g-and-never-recaptures-frontline-or-yanks-back"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r1))
                   (memq 'main-reinforce (staging-step-result-dispatched-groups r2))
                   (null? u2g-after-dispatch)
                   (not (set-member? (staging-step-result-handled-tags r3-near) 6201))
                   (not (set-member? (staging-step-result-handled-tags r4-front) 6201))
                   (null? (staging-step-result-actions r4-front))
                   (not (memq 'main-reinforce (staging-step-result-staging-groups r5-sup))))
              (format "r1=~a r2-disp=~a u2g=~a r3-h=~a r4-h=~a r4-a=~a r5=~a"
                      (staging-step-result-staging-groups r1)
                      (staging-step-result-dispatched-groups r2)
                      u2g-after-dispatch
                      (staging-step-result-handled-tags r3-near)
                      (staging-step-result-handled-tags r4-front)
                      (staging-step-result-actions r4-front)
                      (staging-step-result-staging-groups r5-sup)))

  ;; 8b. Bug #1: `'main-reinforce` NEVER emits `'move` even when heavily outnumbered in combat contact!
  (define mgr-nomove (make-staging-group-manager))
  (define lone-roach (list (mk-u 6251 'roach 38.0 32.5 #:hp 145.0)))
  (define stalkers-8 (for/list ([i (in-range 8)]) (mk-u (+ 6950 i) 'stalker 46.0 (+ 30.0 (* 0.5 i)) #:hp 80.0)))
  (define r-nomove
    (step-staging-groups! mgr-nomove #:frame 4500 #:live-obs? #t
                          #:ally-units (append drones front-roaches lone-roach)
                          #:combat-units (append front-roaches lone-roach)
                          #:ally-buildings bldgs #:enemy-units stalkers-8
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'roach 4)))
  (check-true "bug1-main-reinforce-never-emits-move-in-contact"
              (and (not (set-member? (staging-step-result-handled-tags r-nomove) 6251))
                   (not (ormap (lambda (a) (eq? (car a) 'move)) (staging-step-result-actions r-nomove)))
                   (not (ormap (lambda (a) (eq? (car a) 'move)) (staging-step-result-preserved-actions r-nomove))))
              (format "h=~a acts=~a pres=~a"
                      (staging-step-result-handled-tags r-nomove)
                      (staging-step-result-actions r-nomove)
                      (staging-step-result-preserved-actions r-nomove)))

  ;; 8c. Bug #2: `'air-anti-cap` dives vs 17 Tempests with >= 8 Corruptors (in contact) OR >= 6 under base shelling,
  ;;     AND anti-stall releases >= 6 Corruptors after 336f (no permanent freeze trap like `EXT #31 sc2ai`!)
  (define z-bldgs-cap (list (mk-u 6301 'hive 32.5 32.5)
                            (mk-u 6302 'hatchery 56.5 32.5)
                            (mk-u 6303 'spire 36.0 36.0)))
  (define tempests-17-contact
    (for/list ([i (in-range 17)])
      (mk-u (+ 6800 i) 'tempest 95.0 (+ 80.0 (* 0.4 i)) #:hp 200.0 #:shield 125.0 #:flying #t)))
  (define corrs-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 6400 i) 'corruptor 80.0 (+ 80.0 (* 0.4 i)) #:hp 200.0 #:flying #t)))
  (define mgr-cap1 (make-staging-group-manager))
  (define r-cap-dive8
    (step-staging-groups! mgr-cap1 #:frame 9000 #:live-obs? #t
                          #:ally-units (append drones corrs-8) #:combat-units corrs-8
                          #:ally-buildings z-bldgs-cap #:enemy-units tempests-17-contact
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 17 #:in-production-counts (hasheq 'corruptor 4)))
  ;; 6 Corruptors while 17 Tempests shell Natural (`<= 24t` from Nat) -> MUST dispatch immediately!
  (define tempests-17-nat
    (for/list ([i (in-range 17)])
      (mk-u (+ 6850 i) 'tempest 68.0 (+ 32.0 (* 0.4 i)) #:hp 200.0 #:shield 125.0 #:flying #t)))
  (define corrs-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 6450 i) 'corruptor 24.0 (+ 24.0 (* 0.4 i)) #:hp 200.0 #:flying #t)))
  (define mgr-cap2 (make-staging-group-manager))
  (define r-cap-shell6
    (step-staging-groups! mgr-cap2 #:frame 9100 #:live-obs? #t
                          #:ally-units (append drones corrs-6) #:combat-units corrs-6
                          #:ally-buildings z-bldgs-cap #:enemy-units tempests-17-nat
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 17 #:in-production-counts (hasheq 'corruptor 4)))
  ;; 7 Corruptors waiting with 17 Tempests at 22t -> after 340f (>= 336f), anti-stall MUST release!
  (define corrs-7
    (for/list ([i (in-range 7)])
      (mk-u (+ 6480 i) 'corruptor 73.0 (+ 80.0 (* 0.4 i)) #:hp 200.0 #:flying #t)))
  (define mgr-cap3 (make-staging-group-manager))
  (define _r-cap-t0
    (step-staging-groups! mgr-cap3 #:frame 9200 #:live-obs? #t
                          #:ally-units (append drones corrs-7) #:combat-units corrs-7
                          #:ally-buildings z-bldgs-cap #:enemy-units tempests-17-contact
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 17 #:in-production-counts (hasheq 'corruptor 4)))
  (define r-cap-t340
    (step-staging-groups! mgr-cap3 #:frame 9540 #:live-obs? #t
                          #:ally-units (append drones corrs-7) #:combat-units corrs-7
                          #:ally-buildings z-bldgs-cap #:enemy-units tempests-17-contact
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 17 #:in-production-counts (hasheq 'corruptor 4)))
  (check-true "bug2-air-anti-cap-dives-vs-17-tempests-and-never-freezes-past-336f"
              (and (not (set-member? (staging-step-result-handled-tags r-cap-dive8) 6400))
                   (null? (staging-step-result-preserved-actions r-cap-dive8))
                   (memq 'air-anti-cap (staging-step-result-dispatched-groups r-cap-shell6))
                   (memq 'air-anti-cap (staging-step-result-dispatched-groups r-cap-t340)))
              (format "dive8-h=~a dive8-pres=~a shell6-disp=~a t340-disp=~a"
                      (staging-step-result-handled-tags r-cap-dive8)
                      (staging-step-result-preserved-actions r-cap-dive8)
                      (staging-step-result-dispatched-groups r-cap-shell6)
                      (staging-step-result-dispatched-groups r-cap-t340))))

;; =============================================================================
;; 9. Loop 59 Package 2: Corruptor 1-by-1 Tempest Feed Fix, Blind-Uphill Retreat
;;    & Multi-Race High-Ground Vision Dispatcher
;; =============================================================================
(let ()
  ;; 9a. Endgame supply >= 165 MUST NOT force-dispatch `< 6` Corruptors 1-by-1 into Tempests!
  ;;     And even 1 Tempest activates `'air-anti-cap` staging >= 18t clear!
  (define drones (list (mk-u 9101 'drone 28.0 32.5)))
  (define bldgs (list (mk-u 9110 'hive 32.5 32.5)
                      (mk-u 9111 'hatchery 56.5 32.5)
                      (mk-u 9112 'spire 36.0 36.0)))
  (define corrs-2 (list (mk-u 9201 'corruptor 34.0 33.0 #:hp 200.0 #:flying #t)
                        (mk-u 9202 'corruptor 35.0 33.0 #:hp 200.0 #:flying #t)))
  (define tempests-1 (list (mk-u 9801 'tempest 48.0 33.0 #:hp 200.0 #:shield 125.0 #:flying #t)))
  (define mgr-l59 (make-staging-group-manager))
  (define r-t0
    (step-staging-groups! mgr-l59 #:frame 14000 #:live-obs? #t
                          #:ally-units (append drones corrs-2) #:combat-units corrs-2
                          #:ally-buildings bldgs #:enemy-units tempests-1
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 1 #:supply-used 182))
  (define r-t400
    (step-staging-groups! mgr-l59 #:frame 14400 #:live-obs? #t
                          #:ally-units (append drones corrs-2) #:combat-units corrs-2
                          #:ally-buildings bldgs #:enemy-units tempests-1
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 56.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:enemy-cap-air-cnt 1 #:supply-used 182))
  (check-true "l59-p2-corruptor-2pack-never-endgame-fed-into-tempests"
              (and (memq 'air-anti-cap (staging-step-result-staging-groups r-t0))
                   (not (memq 'air-anti-cap (staging-step-result-dispatched-groups r-t0)))
                   (memq 'air-anti-cap (staging-step-result-staging-groups r-t400))
                   (ormap (lambda (a) (and (eq? (car a) 'move) (= (second a) 9201)))
                          (staging-step-result-preserved-actions r-t0)))
              (format "t0-stg=~a t0-disp=~a t400-stg=~a pres=~a"
                      (staging-step-result-staging-groups r-t0)
                      (staging-step-result-dispatched-groups r-t0)
                      (staging-step-result-staging-groups r-t400)
                      (staging-step-result-preserved-actions r-t0)))

  ;; 9b. Blind-Uphill Retreat pulls ground unit 4.5t back when taking unseen uphill fire (0 visible enemies)
  ;;     and returns #f #f when an enemy IS visible in range or unit is flying!
  (define stalk-blind (mk-u 9301 'stalker 60.0 60.0 #:hp 60.0 #:max-hp 80.0 #:shield 30.0 #:z 8.0))
  (define-values (brx bry)
    (compute-blind-uphill-retreat-pt #f stalk-blind
                                     #:prev-hp 120.0 #:enemy-units '()
                                     #:uphill-target-x 66.0 #:uphill-target-y 60.0 #:uphill-z 10.0))
  (define vis-en (list (mk-u 9901 'marine 65.0 60.0 #:hp 45.0 #:z 10.0)))
  (define-values (vrx vry)
    (compute-blind-uphill-retreat-pt #f stalk-blind
                                     #:prev-hp 120.0 #:enemy-units vis-en
                                     #:uphill-target-x 66.0 #:uphill-target-y 60.0 #:uphill-z 10.0))
  (define phx-fly (mk-u 9302 'phoenix 60.0 60.0 #:hp 100.0 #:flying #t #:z 10.0))
  (define-values (frx fry)
    (compute-blind-uphill-retreat-pt #f phx-fly #:prev-hp 140.0 #:enemy-units '()
                                     #:uphill-target-x 66.0 #:uphill-target-y 60.0))
  (check-true "l59-p2-blind-uphill-retreat-pulls-back-4.5t-and-guards-visible-or-air"
              (and brx bry
                   (< brx 56.5)
                   (>= (dist2d 60.0 60.0 brx bry) 4.0)
                   (not vrx) (not vry)
                   (not frx) (not fry))
              (format "blind=(~a,~a) vis=(~a,~a) fly=(~a,~a)" brx bry vrx vry frx fry))

  ;; 9c. Multi-Race High-Ground Vision Dispatcher:
  ;;     Protoss (Observer move + Sentry Hallucination-Phoenix 154),
  ;;     Terran (Viking move + OC Scanner Sweep 399), Zerg (Changeling/Overlord move)
  (define p-obs-acts
    (plan-high-ground-vision-actions 'Protoss
                                     (list (mk-u 9401 'observer 50.0 50.0 #:flying #t))
                                     '() '() #:uphill-x 66.0 #:uphill-y 60.0 #:home-x 32.5 #:home-y 32.5))
  (define p-sen-acts
    (plan-high-ground-vision-actions 'Protoss
                                     (list (mk-u 9402 'sentry 56.0 58.0 #:energy 80.0))
                                     '() '() #:uphill-x 66.0 #:uphill-y 60.0 #:home-x 32.5 #:home-y 32.5))
  (define t-oc-acts
    (plan-high-ground-vision-actions 'Terran
                                     (list (mk-u 9403 'siege-tank-sieged 54.0 58.0))
                                     (list (mk-u 9404 'orbital-command 32.5 32.5 #:energy 65.0))
                                     '() #:uphill-x 66.0 #:uphill-y 60.0 #:home-x 32.5 #:home-y 32.5))
  (define z-ovi-acts
    (plan-high-ground-vision-actions 'Zerg
                                     (list (mk-u 9405 'overlord 48.0 50.0 #:flying #t))
                                     '() '() #:uphill-x 66.0 #:uphill-y 60.0 #:home-x 32.5 #:home-y 32.5))
  (check-true "l59-p2-multi-race-high-ground-vision-dispatcher"
              (and (pair? p-obs-acts) (eq? (caar p-obs-acts) 'move) (= (cadar p-obs-acts) 9401)
                   (equal? p-sen-acts '((cast-spell 9402 hallucination-phoenix)))
                   (pair? t-oc-acts) (eq? (caar t-oc-acts) 'cast-spell) (eq? (caddar t-oc-acts) 'scanner-sweep)
                   (pair? z-ovi-acts) (eq? (caar z-ovi-acts) 'move) (= (cadar z-ovi-acts) 9405))
              (format "p-obs=~a p-sen=~a t-oc=~a z-ovi=~a" p-obs-acts p-sen-acts t-oc-acts z-ovi-acts)))

(printf "=== L58 Staging Groups & Concave Positioning Test Suite: ~a PASS, ~a FAIL ===\n"
        pass-cnt fail-cnt)
(when (> fail-cnt 0)
  (exit 1))
