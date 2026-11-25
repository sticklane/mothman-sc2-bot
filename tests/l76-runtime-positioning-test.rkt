#lang racket/base

;; =============================================================================
;; `tests/l76-runtime-positioning-test.rkt`
;; Loop 76 Lane A — P0–P3 Concave/Positioning/Micro Runtime Fixes & Clean B6 Revert
;;
;; Covers:
;;   1. `l76-p0-zero-th-no-pullback`: `0` THs (`k05` 5v3 Adepts & `z02` 9 Roach/Ravager
;;      vs 2 Sieged Tanks) NEVER arm `pullback-until-frame` or emit passive off-map `'move`!
;;   2. `l76-p0-winning-attrition-no-pullback`: taking >= 35% casualties with >= 2 THs
;;      while surviving supply >= 0.95x visible enemy NEVER arms pullback!
;;   3. `l76-p0-ladder-outnumbered-retreat-preserved`: >= 2 THs with 0.50x outnumbered
;;      ratio STILL arms pullback and retreats cleanly via `'move` to safe TH!
;;   4. `l76-p0-post-nova-bio-reengages`: `k04` — active `disruptor-phased` triggers split;
;;      once absent (`has-live-nova? = #f`), Marines/Marauders immediately attack Disruptor/Colossus!
;;   5. `l76-p0-p13-lone-colossus-fights`: lone Colossus (`0` Zealots/Stalkers, `0` THs)
;;      at `8.5t` fights cleanly instead of off-map rear-leash!
;;   6. `l76-p1-tank-steps-behind-bio-before-sieging`: `t02` unsieged Tank ahead of 8 Marines
;;      at `10t` from Roaches steps `-2.5t` behind Marines before sieging; once behind Marines
;;      OR Roaches `<= 6.5t`, sieges immediately!
;;   7. `l76-p1-p01-lagging-stalkers-arc-behind-zealots`: lagging Stalkers `> 3.5t` behind
;;      charging Zealots advance on wide curved `'attack-pos` arc behind Zealots!
;;   8. `l76-p2-clumped-stalkers-on-cd-spread-concave`: `>= 4` clumped Stalkers on cooldown
;;      (`w-cd = 0.6`) spread laterally into concave via `'attack-pos`, while `w-cd = 0.0`
;;      fires directly (`'attack-unit`, zero DPS pull)!
;;   9. `l76-p3-cohesive-stalker-kite-avoids-corner`: kiting Stalker on cooldown (`w-cd = 0.5`)
;;      near corner `(10, 10)` steers tangentially away from corner and stays inside `[8, map-w-8]`!
;; =============================================================================

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         (only-in "../lib/tactics/order-ledger.rkt"
                  order-ledger-reconcile-observation!))

(define tests-run 0)
(define tests-passed 0)
(define tests-failed 0)

(define (check-true name cond-val [detail ""])
  (set! tests-run (add1 tests-run))
  (if cond-val
      (begin
        (set! tests-passed (add1 tests-passed))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! tests-failed (add1 tests-failed))
        (printf "  [FAIL] ~a ~a\n" name detail))))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [mhp hp]
              #:shield [sh 0.0] #:max-shield [msh sh]
              #:energy [en 0.0]
              #:flying [fly? #f]
              #:sieged [sieged? #f]
              #:build-progress [bp 1.0]
              #:orders [ords '()]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:weapon-cooldown [wcd 0.0])
  (hasheq 'id id 'type type 'x (exact->inexact x) 'y (exact->inexact y)
          'hp (exact->inexact hp) 'max-hp (exact->inexact mhp)
          'shield (exact->inexact sh) 'shields (exact->inexact sh)
          'max-shield (exact->inexact msh)
          'energy (exact->inexact en) 'cloak 3
          'flying fly? 'flying? fly? 'is-flying fly?
          'sieged sieged?
          'build-progress (exact->inexact bp)
          'orders ords
          'order-ability-id oab 'order-target-id otid
          'weapon-cooldown (exact->inexact wcd)
          'display-type 1))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 100]
                     #:supply-used [su 30]
                     #:supply-cap [sc 60]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:effects [effects '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 142.5] #:enemy-y [ey 138.5]
                     #:researched-upgrades [upgs '()]
                     #:map-width [mw 160.0] #:map-height [mh 160.0])
  (hasheq 'race race 'enemy-race enemy-race 'frame frame
          'live-game? #t 'live-obs? #t 'live-obs-harvesters? #t
          'enable-opponent-world-model #t
          'minerals minerals 'gas gas
          'supply-used su 'supply-cap sc
          'mineral-harvesters 0 'vespene-harvesters 0 'gas-harvesters 0
          'ally-units au 'ally-buildings ab
          'enemy-units eu 'enemy-buildings eb
          'effects effects
          'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
          'enemy-x ex 'enemy-y ey
          'map-width mw 'map-height mh
          'researched-upgrades upgs 'upgrades-tracked? #t
          'pending-upgrades '()))

(define (run-l34 rt obs [fap 0.60])
  (step-layer1-perception! rt obs)
  (step-layer1b-mastermind! rt obs)
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt) obs)
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(define (unit-acts acts uid)
  (filter (lambda (a)
            (and (pair? a)
                 (>= (length a) 2)
                 (or (eqv? (second a) uid)
                     (and (list? (second a)) (memv uid (second a))))))
          acts))

(define (has-attack? uacts)
  (ormap (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos)))) uacts))

(define (has-passive-move? uacts)
  (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move))) uacts))

(printf "=== Loop 76 Lane A: Runtime Positioning & Micro Tests ===\n")

;; -----------------------------------------------------------------------------
;; 1. l76-p0-zero-th-no-pullback (`k05` 5v3 Adepts + `z02` 9 Roach/Ravager vs Tanks)
;; -----------------------------------------------------------------------------
(let ()
  ;; 1a: `k05` 0 THs — 8 Adepts drop to 5 Adepts (37.5% wave loss, incl. 20% HP Adept #1001)
  ;;     vs 3 enemy Adepts at d = 14t -> MUST NOT arm pullback or emit off-map `'move`!
  (define rt-k05 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (hash-set! (rt-bistable-states rt-k05) 'army-attack-wave #t)
  (define adepts-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 1001 i) 'adept 80.0 (+ 78.0 (* 0.6 i)) #:hp 70.0 #:max-hp 70.0 #:shield 70.0 #:max-shield 70.0)))
  (define e-adepts-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 9001 i) 'adept 94.0 (+ 79.0 (* 0.8 i)) #:hp 70.0 #:shield 70.0)))
  (run-l34 rt-k05 (mk-live-obs 'Protoss 'Protoss 1000 #:ally-units adepts-8 #:enemy-units e-adepts-3))
  (hash-set! (rt-bistable-states rt-k05) 'army-attack-wave #t)
  ;; Simulate 37.5% attrition (5 Adepts survive, #1001 at 15/140 EHP < 30%)
  (define adepts-5
    (cons (mk-u 1001 'adept 80.0 78.0 #:hp 15.0 #:max-hp 70.0 #:shield 0.0 #:max-shield 70.0)
          (for/list ([i (in-range 1 5)])
            (mk-u (+ 1001 i) 'adept 80.0 (+ 78.0 (* 0.6 i)) #:hp 70.0 #:max-hp 70.0 #:shield 50.0 #:max-shield 70.0))))
  (define acts-k05
    (run-l34 rt-k05 (mk-live-obs 'Protoss 'Protoss 1040 #:ally-units adepts-5 #:enemy-units e-adepts-3)))
  (define pb-until-k05 (hash-ref (rt-wave-loss-state rt-k05) 'pullback-until-frame -1))
  (define a1-acts (unit-acts acts-k05 1001))
  (define a2-acts (unit-acts acts-k05 1002))
  (check-true "l76-p0-zero-th-no-pullback-k05-adepts"
              (and (<= pb-until-k05 1040)
                   (has-attack? a1-acts)
                   (has-attack? a2-acts)
                   (not (has-passive-move? a1-acts))
                   (not (has-passive-move? a2-acts)))
              (format "pb=~a a1001=~a a1002=~a" pb-until-k05 a1-acts a2-acts))

  ;; 1b: `z02` 0 THs — 14 Roach/Ravager drop to 9 (35.7% wave loss) vs 2 Sieged Tanks + 4 Marines
  ;;     at d = 15..18t -> ZERO off-map `'move` retreat, emits attack orders!
  (define rt-z02 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (hash-set! (rt-bistable-states rt-z02) 'army-attack-wave #t)
  (define z-army-14
    (append (for/list ([i (in-range 10)])
              (mk-u (+ 1101 i) 'roach 76.0 (+ 76.0 (* 0.7 i)) #:hp 145.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 1121 i) 'ravager 74.0 (+ 78.0 (* 0.9 i)) #:hp 120.0))))
  (define t-tanks-marines
    (list (mk-u 9101 'siege-tank-sieged 94.0 79.0 #:hp 175.0 #:sieged #t)
          (mk-u 9102 'siege-tank-sieged 94.0 82.0 #:hp 175.0 #:sieged #t)
          (mk-u 9103 'marine 91.0 78.0 #:hp 45.0)
          (mk-u 9104 'marine 91.0 80.0 #:hp 45.0)
          (mk-u 9105 'marine 91.0 81.0 #:hp 45.0)
          (mk-u 9106 'marine 91.0 83.0 #:hp 45.0)))
  (run-l34 rt-z02 (mk-live-obs 'Zerg 'Terran 1000 #:ally-units z-army-14 #:enemy-units t-tanks-marines))
  (hash-set! (rt-bistable-states rt-z02) 'army-attack-wave #t)
  (define z-army-9
    (append (for/list ([i (in-range 6)])
              (mk-u (+ 1101 i) 'roach 76.0 (+ 76.0 (* 0.7 i)) #:hp 120.0 #:max-hp 145.0))
            (for/list ([i (in-range 3)])
              (mk-u (+ 1121 i) 'ravager 74.0 (+ 78.0 (* 0.9 i)) #:hp 100.0 #:max-hp 120.0))))
  (define acts-z02
    (run-l34 rt-z02 (mk-live-obs 'Zerg 'Terran 1040 #:ally-units z-army-9 #:enemy-units t-tanks-marines)))
  (define pb-until-z02 (hash-ref (rt-wave-loss-state rt-z02) 'pullback-until-frame -1))
  (define r0-acts (unit-acts acts-z02 1101))
  (define rav0-acts (unit-acts acts-z02 1121))
  (check-true "l76-p0-zero-th-no-pullback-z02-roach-ravager-vs-tanks"
              (and (<= pb-until-z02 1040)
                   (has-attack? r0-acts)
                   (not (ormap (lambda (a) (and (eq? (car a) 'move) (< (third a) 70.0))) r0-acts))
                   (not (ormap (lambda (a) (and (eq? (car a) 'move) (< (third a) 70.0))) rav0-acts)))
              (format "pb=~a roach1101=~a rav1121=~a" pb-until-z02 r0-acts rav0-acts)))

;; -----------------------------------------------------------------------------
;; 2. l76-p0-winning-attrition-no-pullback & l76-p0-ladder-outnumbered-retreat-preserved
;; -----------------------------------------------------------------------------
(let ()
  (define p-2th-bldgs
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 2003 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)))
  (define e-th-bldg
    (list (mk-u 9099 'nexus 142.5 138.5 #:hp 1000.0 #:shield 1000.0)))

  ;; 2a (Loop 76B `#2388`): `> 0`-TH ladder partial Fog visibility MUST STILL arm pullback!
  ;;     At frame 7000 we saw 20 enemy Stalkers (40 sup, remembered in Fog). At frame 7040 only
  ;;     5 enemy Stalkers (10 sup) are visible, while our Stalkers dropped 24 -> 15 (37.5% loss,
  ;;     30 sup < 0.85 * 40 est-enemy-sup). Even though 30 >= 0.95 * 10 visible, ladder MUST arm
  ;;     `pullback-until-frame` (no partial-Fog disengage suppression)!
  (define rt-fog (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (hash-set! (rt-bistable-states rt-fog) 'army-attack-wave #t)
  (define st-24
    (for/list ([i (in-range 24)])
      (mk-u (+ 2100 i) 'stalker 95.0 (+ 88.0 (* 0.5 (modulo i 12))) #:hp 80.0 #:shield 80.0)))
  (define st-15
    (for/list ([i (in-range 15)])
      (mk-u (+ 2100 i) 'stalker 95.0 (+ 88.0 (* 0.5 (modulo i 12))) #:hp 80.0 #:shield 60.0)))
  (define e-st-20-seen
    (for/list ([i (in-range 20)])
      (mk-u (+ 9200 i) 'stalker 113.0 (+ 86.0 (* 0.5 (modulo i 10))) #:hp 80.0 #:shield 80.0)))
  (define e-st-5-vis
    (for/list ([i (in-range 5)])
      (mk-u (+ 9200 i) 'stalker 113.0 (+ 89.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0)))
  (run-l34 rt-fog (mk-live-obs 'Protoss 'Protoss 7000 #:supply-used 60 #:supply-cap 90
                               #:ally-units st-24 #:ally-buildings p-2th-bldgs
                               #:enemy-units e-st-20-seen #:enemy-buildings e-th-bldg))
  (hash-set! (rt-bistable-states rt-fog) 'army-attack-wave #t)
  (run-l34 rt-fog (mk-live-obs 'Protoss 'Protoss 7040 #:supply-used 42 #:supply-cap 90
                               #:ally-units st-15 #:ally-buildings p-2th-bldgs
                               #:enemy-units e-st-5-vis #:enemy-buildings e-th-bldg))
  (define pb-until-fog (hash-ref (rt-wave-loss-state rt-fog) 'pullback-until-frame -1))
  (check-true "l76b-p0-ladder-fog-partial-vis-still-arms-pullback"
              (> pb-until-fog 7040)
              (format "pb=~a" pb-until-fog))

  ;; 2b: Ladder outnumbered retreat PRESERVED (`>= 2` THs, 14 -> 6 Stalkers = 12 sup vs 12 Stalkers = 24 sup,
  ;;     0.50x < 0.85x, enemy at 18t mid-map) -> STILL arms `pullback-until-frame` & emits `'move` toward TH!
  (define rt-ret (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (hash-set! (rt-bistable-states rt-ret) 'army-attack-wave #t)
  (define st-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 2200 i) 'stalker 100.0 (+ 96.0 (* 0.5 (modulo i 7))) #:hp 80.0 #:shield 80.0)))
  (define st-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 2200 i) 'stalker 100.0 (+ 96.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define e-st-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 9250 i) 'stalker 118.0 (+ 95.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (run-l34 rt-ret (mk-live-obs 'Protoss 'Protoss 7000 #:supply-used 48 #:supply-cap 80
                               #:ally-units st-14 #:ally-buildings p-2th-bldgs
                               #:enemy-units e-st-12 #:enemy-buildings e-th-bldg))
  (hash-set! (rt-bistable-states rt-ret) 'army-attack-wave #t)
  (define acts-ret
    (run-l34 rt-ret (mk-live-obs 'Protoss 'Protoss 7040 #:supply-used 32 #:supply-cap 80
                                 #:ally-units st-6 #:ally-buildings p-2th-bldgs
                                 #:enemy-units e-st-12 #:enemy-buildings e-th-bldg)))
  (define pb-until-ret (hash-ref (rt-wave-loss-state rt-ret) 'pullback-until-frame -1))
  (define s0-ret-acts (unit-acts acts-ret 2200))
  (check-true "l76-p0-ladder-outnumbered-retreat-preserved"
              (and (> pb-until-ret 7040)
                   (ormap (lambda (a) (and (eq? (car a) 'move) (< (third a) 98.0))) s0-ret-acts))
              (format "pb=~a st2200=~a" pb-until-ret s0-ret-acts)))

;; -----------------------------------------------------------------------------
;; 3. l76-p0-post-nova-bio-reengages (`k04`)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-k04 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bio-squad
    (append (for/list ([i (in-range 8)])
              (mk-u (+ 3100 i) 'marine 82.0 (+ 78.5 (* 0.4 i)) #:hp 45.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 3120 i) 'marauder 83.0 (+ 79.0 (* 0.6 i)) #:hp 125.0))))
  (define e-dis-col-base
    (list (mk-u 9301 'disruptor 91.0 80.0 #:hp 100.0 #:shield 100.0)
          (mk-u 9302 'colossus 92.0 81.5 #:hp 200.0 #:shield 150.0)))
  (define e-with-nova
    (cons (mk-u 9309 'disruptor-phased 84.0 80.0 #:hp 100.0) e-dis-col-base))

  ;; Frame 2000: LIVE Purification Nova (`disruptor-phased`) -> Marines evade/split!
  (define acts-nova
    (run-l34 rt-k04 (mk-live-obs 'Terran 'Protoss 2000 #:ally-units bio-squad #:enemy-units e-with-nova)))
  (define evaded-nova?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(move kite))
                  (let ([u (second a)])
                    (or (and (exact-integer? u) (<= 3100 u 3123))
                        (and (list? u) (ormap (lambda (id) (<= 3100 id 3123)) u))))))
           acts-nova))

  ;; Frame 2016: Nova GONE (`has-live-nova? = #f`) while Disruptor + Colossus remain at 9..10t ->
  ;;             Bio MUST immediately attack Disruptor/Colossus (ZERO stale move/kite/split standoff)!
  (define acts-post
    (run-l34 rt-k04 (mk-live-obs 'Terran 'Protoss 2016 #:ally-units bio-squad #:enemy-units e-dis-col-base)))
  (define m0-post (unit-acts acts-post 3100))
  (define ma0-post (unit-acts acts-post 3120))
  (check-true "l76-p0-post-nova-bio-reengages"
              (and evaded-nova?
                   (has-attack? m0-post)
                   (has-attack? ma0-post)
                   (not (has-passive-move? m0-post))
                   (not (has-passive-move? ma0-post)))
              (format "evaded=~a m3100=~a ma3120=~a" evaded-nova? m0-post ma0-post)))

;; -----------------------------------------------------------------------------
;; 4. l76-p0-p13-lone-colossus-fights (`p13`)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-p13 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define lone-col (list (mk-u 4101 'colossus 80.0 80.0 #:hp 200.0 #:shield 150.0)))
  (define e-marines
    (for/list ([i (in-range 4)])
      (mk-u (+ 9401 i) 'marine 88.5 (+ 79.0 (* 0.6 i)) #:hp 45.0)))
  (define acts-p13
    (run-l34 rt-p13 (mk-live-obs 'Protoss 'Terran 3000 #:ally-units lone-col #:enemy-units e-marines
                                 #:researched-upgrades '(extended-thermal-lance))))
  (define c-acts (unit-acts acts-p13 4101))
  (check-true "l76-p0-p13-lone-colossus-fights"
              (and (has-attack? c-acts)
                   (not (has-passive-move? c-acts)))
              (format "col4101=~a" c-acts)))

;; -----------------------------------------------------------------------------
;; 5. Loop 80B Revert Guard: Tank Sieges Immediately (No Pre-Siege `'move` Delay!)
;; -----------------------------------------------------------------------------
(let ()
  (define bio-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 5100 i) 'marine 84.0 (+ 78.0 (* 0.6 i)) #:hp 45.0)))
  (define roaches-6-far
    (for/list ([i (in-range 6)])
      (mk-u (+ 9500 i) 'roach 95.5 (+ 78.0 (* 0.7 i)) #:hp 145.0)))
  (define roaches-6-close
    (for/list ([i (in-range 6)])
      (mk-u (+ 9510 i) 'roach 94.0 (+ 78.0 (* 0.7 i)) #:hp 145.0)))

  ;; 5a (Loop 80B `#2530`): Unsieged Tank at (86,80) within siege range sieges immediately via
  ;;     `siege-mode` instead of wasting a `'move` behind Bio (which dropped 26% of Tank sieges!).
  (define rt-t02a (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define tank-ahead (mk-u 5201 'siege-tank 86.0 80.0 #:hp 175.0))
  (define acts-ahead
    (run-l34 rt-t02a (mk-live-obs 'Terran 'Zerg 3000 #:ally-units (cons tank-ahead bio-8)
                                  #:enemy-units roaches-6-far)))
  (define tk-ahead-acts (unit-acts acts-ahead 5201))
  (define sieged-immediately?
    (and (ormap (lambda (a) (and (eq? (car a) 'cast-spell) (eq? (third a) 'siege-mode))) tk-ahead-acts)
         (not (ormap (lambda (a) (eq? (car a) 'move)) tk-ahead-acts))))
  (check-true "l80b-reverted-tank-sieges-immediately-no-pre-siege-move"
              sieged-immediately?
              (format "tank5201=~a" tk-ahead-acts))

  ;; 5b: Tank level with Bio (`84.3`) AND when enemy closes to `8.0t` also siege immediately!
  (define rt-t02b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define tank-level (mk-u 5201 'siege-tank 84.3 80.0 #:hp 175.0))
  (define acts-level
    (run-l34 rt-t02b (mk-live-obs 'Terran 'Zerg 3008 #:ally-units (cons tank-level bio-8)
                                  #:enemy-units roaches-6-far)))
  (define tk-level-acts (unit-acts acts-level 5201))
  (define sieged-when-level?
    (ormap (lambda (a) (and (eq? (car a) 'cast-spell) (eq? (third a) 'siege-mode))) tk-level-acts))

  (define rt-t02c (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-close
    (run-l34 rt-t02c (mk-live-obs 'Terran 'Zerg 3000 #:ally-units (cons tank-ahead bio-8)
                                  #:enemy-units roaches-6-close)))
  (define tk-close-acts (unit-acts acts-close 5201))
  (define sieged-when-close?
    (ormap (lambda (a) (and (eq? (car a) 'cast-spell) (eq? (third a) 'siege-mode))) tk-close-acts))
  (check-true "l76-p1-tank-sieges-immediately-when-level-or-within-8.5t"
              (and sieged-when-level? sieged-when-close?)
              (format "level=~a close=~a" tk-level-acts tk-close-acts)))

;; -----------------------------------------------------------------------------
;; 6. Loop 80B Revert Guard: Stalkers Preserve Focus-Fire Coalescing (No Scatter)
;; -----------------------------------------------------------------------------
(let ()
  ;; 6a: 6 tightly clumped Stalkers at (80,80) vs enemies at (85.5,80) (d=5.5t) on weapon cooldown
  ;;     (`w-cd = 0.6`) AND weapon ready (`w-cd = 0.0`) BOTH preserve clean `'attack-unit` focus-fire
  ;;     (ZERO per-Stalker `'attack-pos` scatter shattering wire coalescing!).
  (define rt-cc (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define st-clumped-cd
    (for/list ([i (in-range 6)])
      (mk-u (+ 7100 i) 'stalker 80.0 (+ 79.75 (* 0.1 i)) #:hp 80.0 #:shield 80.0 #:weapon-cooldown 0.6)))
  (define e-enemies-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 9700 i) 'stalker 85.5 (+ 78.5 (* 0.6 i)) #:hp 80.0 #:shield 80.0)))
  (define acts-cd
    (run-l34 rt-cc (mk-live-obs 'Protoss 'Protoss 4000 #:ally-units st-clumped-cd #:enemy-units e-enemies-6)))
  (define cd-scatter-acts
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-pos)
                   (exact-integer? (second a)) (<= 7100 (second a) 7105)))
            acts-cd))
  (define cd-focus-acts
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit)
                   (exact-integer? (second a)) (<= 7100 (second a) 7105)))
            acts-cd))

  (define rt-ready (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define st-clumped-ready
    (for/list ([i (in-range 6)])
      (mk-u (+ 7100 i) 'stalker 80.0 (+ 79.75 (* 0.1 i)) #:hp 80.0 #:shield 80.0 #:weapon-cooldown 0.0)))
  (define acts-ready
    (run-l34 rt-ready (mk-live-obs 'Protoss 'Protoss 4000 #:ally-units st-clumped-ready #:enemy-units e-enemies-6)))
  (define fire-acts
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit)
                   (exact-integer? (second a)) (<= 7100 (second a) 7105)))
            acts-ready))
  (check-true "l80b-reverted-clumped-stalkers-preserve-focus-fire-coalescing"
              (and (= (length cd-scatter-acts) 0)
                   (>= (length cd-focus-acts) 6)
                   (>= (length fire-acts) 6))
              (format "cd-scatter=~a cd-focus=~a fire-cnt=~a acts-cd=~a"
                      (length cd-scatter-acts) (length cd-focus-acts) (length fire-acts) acts-cd)))

;; -----------------------------------------------------------------------------
;; 8. l76-p3-cohesive-stalker-kite-scoped-to-0th (`#2388`, `p03`/`b04`)
;; -----------------------------------------------------------------------------
(let ()
  ;; 8a: `0`-TH arena Stalker on cooldown (`w-cd = 0.9 > 0.12`) near bottom-left corner `(11, 10)`
  ;;     facing enemies at `(15, 13)` -> cohesive kite vector deflects tangentially away from corner!
  (define st-corner
    (list (mk-u 8101 'stalker 11.0 10.0 #:hp 80.0 #:shield 80.0 #:weapon-cooldown 0.9)))
  (define e-zealots-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 9800 i) 'zealot 15.0 (+ 12.0 (* 0.4 i)) #:hp 100.0 #:shield 50.0)))
  (define rt-kite-0th (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-kite-0th
    (run-l34 rt-kite-0th (mk-live-obs 'Protoss 'Protoss 5000
                                      #:ally-units st-corner #:ally-buildings '()
                                      #:enemy-units e-zealots-6
                                      #:base-x 130.0 #:base-y 130.0 #:nat-x 110.0 #:nat-y 125.0)))
  (define k-acts-0th
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'kite) (eqv? (second a) 8101))) acts-kite-0th))
  (define arena-avoids-corner?
    (and (pair? k-acts-0th)
         (let* ([a (car k-acts-0th)]
                [kx (exact->inexact (third a))]
                [ky (exact->inexact (fourth a))])
           (and (>= kx 8.0) (>= ky 8.0)
                (or (>= kx 10.2) (>= ky 10.2))))))

  ;; 8b: `> 0`-TH ladder Stalker in same corner uses standard straight-away `compute-kite-vector`
  ;;     (does NOT deflect tangentially toward map center away from corner base)!
  (define rt-kite-ladder (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-far
    (list (mk-u 8001 'nexus 130.0 130.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 8002 'gateway 128.0 128.0 #:hp 500.0 #:shield 500.0)))
  (define acts-kite-ladder
    (run-l34 rt-kite-ladder (mk-live-obs 'Protoss 'Protoss 5000
                                         #:ally-units st-corner #:ally-buildings p-bldgs-far
                                         #:enemy-units e-zealots-6
                                         #:base-x 130.0 #:base-y 130.0 #:nat-x 110.0 #:nat-y 125.0)))
  (define k-acts-ladder
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'kite) (eqv? (second a) 8101))) acts-kite-ladder))
  (define ladder-standard-kite?
    (and (pair? k-acts-ladder)
         (let* ([a (car k-acts-ladder)]
                [kx (exact->inexact (third a))]
                [ky (exact->inexact (fourth a))])
           (and (< kx 10.0) (< ky 9.8)))))
  (check-true "l76b-p3-cohesive-stalker-kite-0th-only-ladder-standard"
              (and arena-avoids-corner? ladder-standard-kite?)
              (format "0th=~a ladder=~a" k-acts-0th k-acts-ladder)))

(printf "=== Results: ~a/~a passed (~a failed) ===\n" tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
