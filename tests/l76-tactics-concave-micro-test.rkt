#lang racket/base

;; =============================================================================
;; Loop 76 Lane B Unit Tests:
;;   1. B1 (P2): Mid-Fight Weapon-Cooldown Lateral Concave Stepping (`w-cd > 0.08`)
;;      & Lone Colossus Rear-Leash Guard (`anchor-cnt < 2` -> `#f`)
;;   2. B2 (P0): Zero-TownHall Bounded Short-Step Fallback (`pick-safe-fallback-point`)
;;   3. B3 (P2): Forward-Blink Surround Fan-Arc (`[-0.65, +0.65]` rad, `land-r = 2.6t` Colossus)
;;   4. B4 (P3): Cyclone/Hellion Tangential Bounded Kite Orbit (`compute-tether-kite-point`
;;      & `evaluate-cyclone-micro` corner-avoidance + `< 15.0t` Lock-On preservation)
;; =============================================================================

(require racket/list
         racket/math
         "../lib/tactics/concave-positioning.rkt"
         "../lib/tactics/staging-groups.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/tactics/unit-mode-micro.rkt"
         "../lib/sc2-types.rkt")

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
              #:flying [fly #f]
              #:w-cd [w-cd #f]
              #:buffs [buffs '()])
  (define base
    (hasheq 'id id
            'type type
            'x x
            'y y
            'hp hp
            'max-hp (or max-hp hp)
            'shield sh
            'shields sh
            'max-shield (or max-sh sh)
            'flying? fly
            'flying fly
            'is-flying fly
            'buffs buffs
            'display-type 1))
  (if w-cd
      (hash-set base 'weapon-cooldown w-cd)
      base))

;; -----------------------------------------------------------------------------
;; 1. B1 (P2): Mid-Fight Weapon-Cooldown Lateral Concave Stepping & Lone Colossus
;; -----------------------------------------------------------------------------
(let ()
  ;; 6 clumped Hydralisks at d=5.5t (`<= wr(5.0) + 1.0`) vs 4 Marines at x=81.0
  (define e-marines
    (for/list ([i (in-range 4)]) (mk-u (+ 1900 i) 'marine 81.0 (+ 49.4 (* 0.4 i)) #:hp 45.0)))
  (define hydras-ready
    (for/list ([i (in-range 6)])
      (mk-u (+ 1000 i) 'hydralisk 75.5 (+ 49.5 (* 0.2 i)) #:hp 90.0 #:w-cd 0.0)))
  (define hydras-on-cd
    (for/list ([i (in-range 6)])
      (mk-u (+ 1000 i) 'hydralisk 75.5 (+ 49.5 (* 0.2 i)) #:hp 90.0 #:w-cd 0.55)))
  (define ctx-ready (build-combat-positioning-context hydras-ready e-marines))
  (define ctx-cd    (build-combat-positioning-context hydras-on-cd e-marines))

  ;; (a) `w-cd = 0.0` at d=5.5t returns `#f` for EVERY unit (zero DPS pull!)
  (define ready-steps
    (filter values
            (for/list ([u (in-list hydras-ready)])
              (define-values (ax ay) (compute-lateral-concave-spread-pt ctx-ready u 81.0 50.0 5.0))
              (and ax ay (cons ax ay)))))
  ;; (b) `w-cd = 0.55` at d=5.5t returns lateral concave arc points strictly inside `<= wr - 0.3` (4.7t)!
  (define cd-steps
    (filter values
            (for/list ([u (in-list hydras-on-cd)])
              (define-values (ax ay) (compute-lateral-concave-spread-pt ctx-cd u 81.0 50.0 5.0))
              (and ax ay (cons ax ay)))))
  (define cd-all-in-range?
    (and (pair? cd-steps)
         (for/and ([pt (in-list cd-steps)])
           (<= (dist2d (car pt) (cdr pt) 81.0 50.0) 4.71))))
  (define cd-lat-span
    (if (>= (length cd-steps) 2)
        (- (apply max (map cdr cd-steps)) (apply min (map cdr cd-steps)))
        0.0))
  (check-true "l76-b1-cooldown-concave-steps-only-when-cd-positive"
              (and (null? ready-steps)
                   (>= (length cd-steps) 2)
                   cd-all-in-range?
                   (>= cd-lat-span 2.0))
              (format "ready=~a cd-cnt=~a in-rng?=~a span=~a pts=~a"
                      ready-steps (length cd-steps) cd-all-in-range? cd-lat-span cd-steps))

  ;; (c) Close-range fight (`d = 4.2t < 5.0t`) with `weapon_cooldown` snake-case key also spreads on CD!
  (define mar-close-cd
    (for/list ([i (in-range 6)])
      (hash-set (mk-u (+ 1100 i) 'marine 76.8 (+ 49.5 (* 0.2 i)) #:hp 45.0) 'weapon_cooldown 0.45)))
  (define ctx-close (build-combat-positioning-context mar-close-cd
                                                      (cons (mk-u 1950 'archon 81.0 50.0 #:hp 10.0 #:shield 350.0)
                                                            e-marines)))
  (define close-steps
    (filter values
            (for/list ([u (in-list mar-close-cd)])
              (define-values (ax ay) (compute-lateral-concave-spread-pt ctx-close u 81.0 50.0 5.0))
              (and ax ay (cons ax ay)))))
  (check-true "l76-b1-cooldown-concave-handles-close-range-and-snake-case-cd"
              (and (>= (length close-steps) 2)
                   (for/and ([pt (in-list close-steps)])
                     (<= (dist2d (car pt) (cdr pt) 81.0 50.0) 4.71)))
              (format "close-steps=~a" close-steps))

  ;; (d) Lone Colossus (`0` friendly frontline/core anchors) returns `#f` from `compute-caster-rear-leash-pt`
  (define lone-col (mk-u 1201 'colossus 72.0 50.0 #:hp 200.0 #:shield 150.0))
  (define lone-col2 (mk-u 1202 'colossus 72.5 51.0 #:hp 200.0 #:shield 150.0))
  (define ctx-lone-col (build-combat-positioning-context (list lone-col lone-col2) e-marines))
  (define-values (lcx lcy) (compute-caster-rear-leash-pt ctx-lone-col lone-col))
  (check-true "l76-b1-lone-colossus-no-offmap-leash"
              (and (not lcx) (not lcy))
              (format "lcx=~a lcy=~a" lcx lcy)))

;; -----------------------------------------------------------------------------
;; 2. B2 (P0): Zero-TH Bounded Short-Step Fallback (`pick-safe-fallback-point`)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Zero owned TownHalls at `(80, 80)` facing threat at `(92, 80)` with base `(32.5, 32.5)`
  ;;     MUST stay bounded within `<= 10.0t` of `(80, 80)` (NEVER snap to `(32.5, 32.5)`)!
  (define fb-mid
    (pick-safe-fallback-point #:group-x 80.0 #:group-y 80.0
                              #:threat-x 92.0 #:threat-y 80.0
                              #:severity 'muster
                              #:ally-townhalls '()
                              #:ally-buildings '()
                              #:enemy-units (list (mk-u 2901 'siege-tank-sieged 92.0 80.0 #:hp 175.0))
                              #:base-x 32.5 #:base-y 32.5
                              #:nat-x 56.5 #:nat-y 32.5
                              #:map-width 160.0 #:map-height 160.0))
  (define d-mid-grp (dist2d (car fb-mid) (cdr fb-mid) 80.0 80.0))
  (define d-mid-corner (dist2d (car fb-mid) (cdr fb-mid) 32.5 32.5))
  (check-true "l76-b2-zero-th-fallback-stays-bounded"
              (and (<= d-mid-grp 10.0)
                   (> d-mid-grp 2.0)
                   (> d-mid-corner 40.0)
                   (< (car fb-mid) 80.0))
              (format "fb-mid=~a d-grp=~a d-corner=~a" fb-mid d-mid-grp d-mid-corner))

  ;; (b) Zero-TH near corner `(12, 12)` facing `(22, 22)` stays inside `[10, 150]` and bounded `<= 10.0t`!
  (define fb-edge
    (pick-safe-fallback-point #:group-x 12.0 #:group-y 12.0
                              #:threat-x 22.0 #:threat-y 22.0
                              #:severity 'skirmish
                              #:ally-townhalls '()
                              #:ally-buildings '()
                              #:enemy-units (list (mk-u 2902 'roach 22.0 22.0 #:hp 145.0))
                              #:base-x 32.5 #:base-y 32.5
                              #:nat-x 56.5 #:nat-y 32.5
                              #:map-width 160.0 #:map-height 160.0))
  (check-true "l76-b2-zero-th-corner-blends-inside-arena-bounds"
              (and (>= (car fb-edge) 10.0) (<= (car fb-edge) 150.0)
                   (>= (cdr fb-edge) 10.0) (<= (cdr fb-edge) 150.0)
                   (<= (dist2d (car fb-edge) (cdr fb-edge) 12.0 12.0) 10.0))
              (format "fb-edge=~a d=~a" fb-edge (dist2d (car fb-edge) (cdr fb-edge) 12.0 12.0)))

  ;; (c) With owned TownHall present, Pool 1 STILL routes cleanly to owned base!
  (define fb-with-th
    (pick-safe-fallback-point #:group-x 80.0 #:group-y 80.0
                              #:threat-x 92.0 #:threat-y 80.0
                              #:severity 'muster
                              #:ally-townhalls (list (mk-u 2801 'nexus 32.5 32.5 #:hp 1000.0))
                              #:ally-buildings (list (mk-u 2801 'nexus 32.5 32.5 #:hp 1000.0))
                              #:enemy-units (list (mk-u 2903 'siege-tank-sieged 92.0 80.0 #:hp 175.0))
                              #:base-x 32.5 #:base-y 32.5
                              #:nat-x 56.5 #:nat-y 32.5
                              #:map-width 160.0 #:map-height 160.0))
  (check-true "l76-b2-owned-th-fallback-still-routes-to-base"
              (< (dist2d (car fb-with-th) (cdr fb-with-th) 32.5 32.5) 12.0)
              (format "fb-with-th=~a" fb-with-th)))

;; -----------------------------------------------------------------------------
;; 3. B3 (P2): Forward-Blink Surround Fan-Arc (`[-0.65, +0.65]` rad on Colossus)
;; -----------------------------------------------------------------------------
(let ()
  ;; 8 clumped Stalkers forward-blinking onto 2 Colossi -> distinct landing points spanning >= 3.0t!
  (define stalkers-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 3001 i) 'stalker 60.0 (+ 59.3 (* 0.2 i))
            #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define colossi-2
    (list (mk-u 3901 'colossus 69.0 60.0 #:hp 200.0 #:shield 150.0)
          (mk-u 3902 'colossus 70.5 60.5 #:hp 200.0 #:shield 150.0)))
  (define dirs
    (plan-stalker-blink-micro stalkers-8 colossi-2 (make-spell-claims) 1000
                              #:researched-upgrades '(blink)))
  (define ys (map spell-directive-target-y dirs))
  (define xs (map spell-directive-target-x dirs))
  (define arc-width (if (>= (length ys) 2) (- (apply max ys) (apply min ys)) 0.0))
  (define distinct-pts
    (length (remove-duplicates (map (lambda (x y) (cons (round (* 10.0 x)) (round (* 10.0 y)))) xs ys))))
  (define all-around-2.6?
    (and (= (length dirs) 8)
         (for/and ([d (in-list dirs)])
           (define dist-col (dist2d (spell-directive-target-x d) (spell-directive-target-y d) 69.0 60.0))
           (and (eq? (spell-directive-pattern-name d) 'stalker-blink-forward-snipe)
                (>= dist-col 2.2) (<= dist-col 2.9)))))
  (check-true "l76-b3-forward-blink-fan-arc-spread"
              (and (= (length dirs) 8)
                   (>= arc-width 3.0)
                   (>= distinct-pts 7)
                   all-around-2.6?)
              (format "n=~a arc-w=~a distinct=~a all2.6?=~a ys=~a"
                      (length dirs) arc-width distinct-pts all-around-2.6? ys))

  ;; Sieged Tank deadzone (`land-r = 1.25t <= 2.5t`) preserved cleanly!
  (define tank-1 (list (mk-u 3910 'siege-tank-sieged 68.5 60.0 #:hp 175.0)))
  (define t-dirs
    (plan-stalker-blink-micro (take stalkers-8 6) tank-1 (make-spell-claims) 1200
                              #:researched-upgrades '(blink)))
  (check-true "l76-b3-forward-blink-tank-deadzone-preserved"
              (and (= (length t-dirs) 6)
                   (for/and ([d (in-list t-dirs)])
                     (<= (dist2d (spell-directive-target-x d) (spell-directive-target-y d) 68.5 60.0) 2.0)))
              (format "t-dirs=~a" t-dirs)))

;; -----------------------------------------------------------------------------
;; 4. B4 (P3): Cyclone/Hellion Tangential Bounded Kite Orbit (`k01`/`k02`)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Cyclone at `(12.0, 12.0)` locked onto Immortal at `(22.0, 22.0)` orbits tangentially
  ;;     away from corner and maintains distance `<= 14.0t` (`< 15.0t` Lock-On break)!
  (define tr-cyc (make-unit-mode-tracker))
  (define cyc-init (mk-u 4001 'cyclone 18.0 18.0 #:hp 120.0))
  (define imm-1    (mk-u 4901 'immortal 22.0 22.0 #:hp 200.0 #:shield 100.0))
  ;; Acquire Lock-On first at frame 500
  (define lock-dirs (plan-cyclone-micro (list cyc-init) (list imm-1)
                                        #:tracker tr-cyc #:current-frame 500
                                        #:home-x 10.0 #:home-y 10.0))
  ;; Now evaluate locked Cyclone pushed into corner `(12.0, 12.0)` at frame 520
  (define cyc-corner (mk-u 4001 'cyclone 12.0 12.0 #:hp 120.0 #:buffs '(lock-on)))
  (define orb-dirs (plan-cyclone-micro (list cyc-corner) (list imm-1)
                                       #:tracker tr-cyc #:current-frame 520
                                       #:home-x 10.0 #:home-y 10.0))
  (define d-orb (and (= (length orb-dirs) 1) (car orb-dirs)))
  (define ox (and d-orb (unit-mode-directive-tx d-orb)))
  (define oy (and d-orb (unit-mode-directive-ty d-orb)))
  (define d-to-imm (and ox oy (dist2d ox oy 22.0 22.0)))
  (define kpt-direct (compute-tether-kite-point 12.0 12.0 22.0 22.0 10.0 10.0 11.0
                                                #:map-w 160.0 #:map-h 160.0))
  (define d-direct (dist2d (point2d-x kpt-direct) (point2d-y kpt-direct) 22.0 22.0))
  (check-true "l76-b4-cyclone-orbit-avoids-corner-and-keeps-lockon"
              (and (= (length lock-dirs) 1)
                   d-orb ox oy
                   (> ox 12.0) (> oy 12.0)
                   (<= d-to-imm 14.0)
                   (>= (abs (- ox oy)) 1.0) ;; genuinely tangential, not pure diagonal
                   (<= d-direct 14.0)
                   (> (point2d-x kpt-direct) 12.0))
              (format "orb=(~a,~a) d-imm=~a direct=(~a,~a) d-dir=~a"
                      ox oy d-to-imm (point2d-x kpt-direct) (point2d-y kpt-direct) d-direct))

  ;; (b) Cyclone pinned against left wall `(12.0, 20.0)` facing Immortal at `(20.0, 20.0)` (`d=8.0t`)
  ;;     blends tangent UP toward map center `(80, 80)` instead of slamming straight into `x=4`!
  (define kpt-wall (compute-tether-kite-point 12.0 20.0 20.0 20.0 8.0 20.0 11.0
                                              #:map-w 160.0 #:map-h 160.0))
  (check-true "l76-b4-left-wall-cyclone-orbits-toward-map-center"
              (and (> (point2d-y kpt-wall) 21.5)
                   (<= (dist2d (point2d-x kpt-wall) (point2d-y kpt-wall) 20.0 20.0) 14.0))
              (format "kpt-wall=(~a,~a)" (point2d-x kpt-wall) (point2d-y kpt-wall)))

  ;; (c) Open-map Cyclone at `(60.0, 60.0)` vs `(66.0, 60.0)` still kites cleanly away toward home!
  (define kpt-open (compute-tether-kite-point 60.0 60.0 66.0 60.0 25.0 60.0 11.0))
  (check-true "l76-b4-open-map-cyclone-kites-away-toward-home"
              (and (< (point2d-x kpt-open) 56.0)
                   (<= (abs (- (point2d-y kpt-open) 60.0)) 0.25))
              (format "kpt-open=(~a,~a)" (point2d-x kpt-open) (point2d-y kpt-open))))

(printf "l76-tactics-concave-micro-test: ~a/~a passed\n" pass-cnt (+ pass-cnt fail-cnt))
(when (> fail-cnt 0)
  (exit 1))
