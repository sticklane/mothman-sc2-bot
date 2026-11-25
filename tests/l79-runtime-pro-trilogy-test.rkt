#lang racket/base

;; =============================================================================
;; Loop 79 Lane B — Pro Tactical Micro & Multi-Prong Trilogy Runtime Test Suite
;; Covers:
;;   1. l79-b1-colossi-archons-stand-clear-locusts-while-pure-stalkers-retreat
;;      (+ base-snipe override & air/AA swoop-intercept of flying Locusts / Swarm Hosts)
;;   2. l79-b2-liberator-deadspace-multiprong-sieges-2-bases-and-evacuates-workers-with-minimal-aa-peel
;;      (+ Defender Mode 2558/2560 wire check, flank routing, worker Freedom-Zone evac, minimal AA peel)
;;   3. l79-b3-carrier-binary-commitment-no-mixing
;;      (14 Vikings + 12 Marines -> 100% 'carrier-snipe; 24 Hydras + 2 Vipers -> 100% 'interceptor-burn;
;;       flip-back on empty Carriers; Thor 2362/2364 binary coupling)
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/bot-runtime.rkt"
         "../lib/sc2-protobuf-ws.rkt"
         "../lib/tactics/order-ledger.rkt"
         "../lib/tactics/multiprong-coordinator.rkt")

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
              #:hp [hp 80.0] #:max-hp [mhp hp]
              #:shield [sh 0.0] #:max-shield [msh sh]
              #:energy [en 0.0]
              #:cloak [clk 3]
              #:flying [fly? #f]
              #:build-progress [bp 1.0]
              #:orders [ords '()]
              #:order-ability-id [oab 0]
              #:order-target-tag [ott 0])
  (hasheq 'id id 'type type 'x x 'y y
          'hp hp 'max-hp mhp 'health hp 'health-max mhp
          'shield sh 'shields sh 'max-shield msh 'max-shields msh
          'energy en 'cloak clk 'flying fly? 'is-flying fly?
          'build-progress bp 'orders ords
          'order-ability-id oab 'order-target-tag ott
          'buffs '() 'weapon-cooldown 0.0 'has-builder #t
          'add-on-tag 0 'display-type 1))

(define (mk-live-obs race enemy-race frame
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:effects [effs '()]
                     #:mineral-patches [mps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 156.5] #:enemy-y [ey 148.5]
                     #:enemy-exp-x [eex 126.5] #:enemy-exp-y [eey 148.5]
                     #:researched-upgrades [upgs '()]
                     #:supply-used [su 90] #:supply-cap [sc 140])
  (hasheq 'race race 'enemy-race enemy-race 'frame frame
          'live-game? #t 'live-obs? #t 'live-obs-harvesters? #t
          'minerals 400 'gas 200
          'supply-used su 'supply-cap sc
          'mineral-harvesters 32 'vespene-harvesters 8 'gas-harvesters 8
          'ally-units au 'ally-buildings ab
          'enemy-units eu 'enemy-buildings eb
          'effects effs 'mineral-patches mps
          'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
          'enemy-x ex 'enemy-y ey 'enemy-exp-x eex 'enemy-exp-y eey
          'researched-upgrades upgs 'upgrades-tracked? #t
          'map-width 200 'map-height 200))

(define (run-l34 rt obs [fap 0.5])
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt) obs)
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(define (act-moves-unit? a uid)
  (and (pair? a) (memq (car a) '(move kite))
       (let ([u0 (second a)])
         (or (equal? u0 uid)
             (and (list? u0) (member uid u0) #t)))))

(define (act-attacks-unit? a uid)
  (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3) (equal? (second a) uid)))

(printf "=== Loop 79 Lane B Runtime Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; Test 1: l79-b1-colossi-archons-stand-clear-locusts-while-pure-stalkers-retreat
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs
    (list (mk-u 79001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 79002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)))
  (define loc-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 79050 i) 'locust-mp (+ 94.0 (* 0.5 (modulo i 4))) (+ 68.0 (* 0.6 (quotient i 4))) #:hp 50.0)))
  (define sh-4-far
    (for/list ([i (in-range 4)])
      (mk-u (+ 79080 i) 'swarm-host-mp 132.0 (+ 68.0 (* 0.9 i)) #:hp 160.0)))

  ;; (a) 2 Colossi + 3 Archons + 6 Stalkers (splash-score = 2.15 >= 1.0) STAND & CLEAR Locusts!
  (define splash-army
    (append (for/list ([i (in-range 2)])
              (mk-u (+ 79101 i) 'colossus 88.0 (+ 68.0 (* 1.2 i)) #:hp 200.0 #:shield 150.0))
            (for/list ([i (in-range 3)])
              (mk-u (+ 79111 i) 'archon 90.0 (+ 67.5 (* 1.0 i)) #:hp 10.0 #:shield 350.0))
            (for/list ([i (in-range 6)])
              (mk-u (+ 79121 i) 'stalker 89.0 (+ 67.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0))))
  (define rt-sp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-sp
    (run-l34 rt-sp
             (mk-live-obs 'Protoss 'Zerg 9600
                          #:ally-units splash-army #:ally-buildings p-bldgs
                          #:enemy-units (append loc-12 sh-4-far)
                          #:researched-upgrades '(extended-thermal-lance))))
  (define splash-any-retreat-move?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(move kite))
                  (let ([u0 (second a)])
                    (or (and (integer? u0) (<= 79101 u0 79126))
                        (and (list? u0) (ormap (lambda (x) (<= 79101 x 79126)) u0))))))
           a-sp))
  (define splash-attacked-locusts?
    (>= (count (lambda (a)
                 (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                      (<= 79101 (second a) 79126)
                      (<= 79050 (third a) 79061)))
               a-sp)
        4))

  ;; (b) Pure Stalkers + Immortals (splash-score = 0.0 < 1.0) RETREAT & wait out Locust timer!
  (define nosplash-army
    (append (for/list ([i (in-range 8)])
              (mk-u (+ 79141 i) 'stalker 89.0 (+ 67.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 3)])
              (mk-u (+ 79161 i) 'immortal 88.0 (+ 68.0 (* 0.8 i)) #:hp 200.0 #:shield 100.0))))
  (define rt-no (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-no
    (run-l34 rt-no
             (mk-live-obs 'Protoss 'Zerg 9600
                          #:ally-units nosplash-army #:ally-buildings p-bldgs
                          #:enemy-units (append loc-12 sh-4-far))))
  (define pure-stalkers-retreated?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move)
                  (let ([u0 (second a)])
                    (or (and (integer? u0) (<= 79141 u0 79163))
                        (and (list? u0) (ormap (lambda (x) (<= 79141 x 79163)) u0))))))
           a-no))

  ;; (c) Base-snipe override: 1 Colossus (splash-score = 0.55 >= 0.50) defending Locusts <= 12t of Natural Nexus!
  (define loc-base
    (for/list ([i (in-range 8)])
      (mk-u (+ 79170 i) 'locust-mp (+ 69.0 (* 0.4 (modulo i 4))) (+ 32.5 (* 0.5 (quotient i 4))) #:hp 50.0)))
  (define base-def-army
    (cons (mk-u 79181 'colossus 65.0 32.5 #:hp 200.0 #:shield 150.0)
          (for/list ([i (in-range 4)])
            (mk-u (+ 79182 i) 'stalker 66.0 (+ 31.5 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  (define rt-bs (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-bs
    (run-l34 rt-bs
             (mk-live-obs 'Protoss 'Zerg 9600
                          #:ally-units base-def-army #:ally-buildings p-bldgs
                          #:enemy-units (append loc-base sh-4-far))))
  (define base-snipe-stood?
    (and (not (ormap (lambda (a)
                       (and (pair? a) (memq (car a) '(move kite))
                            (let ([u0 (second a)])
                              (or (equal? u0 79181)
                                  (and (list? u0) (member 79181 u0) #t)))))
                     a-bs))
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                       (<= 79181 (second a) 79185)
                       (<= 79170 (third a) 79177)))
                a-bs)))

  ;; (d) Air/AA Swoop-Intercept: Roaches kite-retreat while Mutalisks + Vikings snipe `locust-mp-flying` mid-air!
  (define fly-loc-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 79190 i) 'locust-mp-flying 96.0 (+ 68.0 (* 0.8 i)) #:hp 50.0 #:flying #t)))
  (define mix-air-army
    (append (for/list ([i (in-range 6)])
              (mk-u (+ 79201 i) 'roach 88.0 (+ 67.5 (* 0.5 i)) #:hp 145.0))
            (for/list ([i (in-range 3)])
              (mk-u (+ 79211 i) 'mutalisk 89.0 (+ 68.0 (* 0.6 i)) #:hp 120.0 #:flying #t))
            (for/list ([i (in-range 2)])
              (mk-u (+ 79221 i) 'viking-fighter 89.5 (+ 69.0 (* 0.6 i)) #:hp 135.0 #:flying #t))))
  (define rt-air (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define a-air
    (run-l34 rt-air
             (mk-live-obs 'Zerg 'Zerg 9600
                          #:ally-units mix-air-army
                          #:ally-buildings (list (mk-u 79240 'hatchery 32.5 32.5 #:hp 1500.0)
                                                 (mk-u 79241 'hatchery 62.5 32.5 #:hp 1500.0))
                          #:enemy-units (append loc-12 fly-loc-3 sh-4-far))))
  (define roaches-kited?
    (ormap (lambda (a) (act-moves-unit? a 79201)) a-air))
  (define air-sniped-flying-locusts?
    (and (= (count (lambda (uid)
                     (ormap (lambda (a)
                              (and (act-attacks-unit? a uid)
                                   (<= 79190 (third a) 79192)))
                            a-air))
                   '(79211 79212 79213 79221 79222))
            5)
         (not (ormap (lambda (uid) (ormap (lambda (a) (act-moves-unit? a uid)) a-air))
                     '(79211 79212 79213 79221 79222)))))

  (check-true "l79-b1-colossi-archons-stand-clear-locusts-while-pure-stalkers-retreat"
              (and (not splash-any-retreat-move?) splash-attacked-locusts?
                   pure-stalkers-retreated? base-snipe-stood?
                   roaches-kited? air-sniped-flying-locusts?)
              (format "noRetreat=~a atkLoc=~a pureRet=~a baseSnipe=~a roachKite=~a airSwoop=~a"
                      (not splash-any-retreat-move?) splash-attacked-locusts?
                      pure-stalkers-retreated? base-snipe-stood?
                      roaches-kited? air-sniped-flying-locusts?)))

;; -----------------------------------------------------------------------------
;; Test 2: l79-b2-liberator-deadspace-multiprong-sieges-2-bases-and-evacuates-workers-with-minimal-aa-peel
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Terran 3 Liberators (1 frontline + 2 parked in behind-mineral dead-space of 2 distinct enemy bases):
  ;;     BOTH harass Liberators siege via `morph-liberator-ag` (`2558`) onto distinct mineral arcs (>= 20t apart)!
  (define-values (px1 py1 sx1 sy1) (compute-liberator-deadspace-spot 156.5 148.5 162.5 154.5 200.0 200.0 #f))
  (define-values (px2 py2 sx2 sy2) (compute-liberator-deadspace-spot 126.5 148.5 126.5 154.5 200.0 200.0 #f))
  (define t-bldgs
    (list (mk-u 79301 'orbital-command 32.5 32.5 #:hp 1500.0)
          (mk-u 79302 'orbital-command 62.5 32.5 #:hp 1500.0)))
  (define en-bases-2
    (list (mk-u 79350 'hatchery 156.5 148.5 #:hp 1500.0)
          (mk-u 79351 'hatchery 126.5 148.5 #:hp 1500.0)))
  (define min-patches-2
    (list (hasheq 'id 79360 'type 'mineral-field 'x 162.5 'y 154.5)
          (hasheq 'id 79361 'type 'mineral-field 'x 126.5 'y 154.5)))
  (define t-army-lib
    (append (for/list ([i (in-range 8)])
              (mk-u (+ 79310 i) 'marine 92.0 (+ 82.0 (* 0.5 i)) #:hp 45.0))
            (list (mk-u 79321 'liberator 91.0 83.0 #:hp 180.0 #:flying #t)
                  (mk-u 79322 'liberator px1 py1 #:hp 180.0 #:flying #t)
                  (mk-u 79323 'liberator px2 py2 #:hp 180.0 #:flying #t))))
  (define en-units-lib
    (append (for/list ([i (in-range 4)]) (mk-u (+ 79370 i) 'drone 162.5 (+ 153.5 (* 0.4 i)) #:hp 40.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 79380 i) 'drone 126.5 (+ 153.5 (* 0.4 i)) #:hp 40.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 79390 i) 'roach 102.0 (+ 84.0 (* 0.7 i)) #:hp 145.0))))
  (define rt-lib (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-lib
    (run-l34 rt-lib
             (mk-live-obs 'Terran 'Zerg 9800
                          #:ally-units t-army-lib #:ally-buildings t-bldgs
                          #:enemy-units en-units-lib #:enemy-buildings en-bases-2
                          #:mineral-patches min-patches-2)))
  (define ag-sieges
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 5)
                   (eq? (third a) 'morph-liberator-ag)
                   (member (second a) '(79322 79323))))
            a-lib))
  (define two-distinct-sieges?
    (and (= (length ag-sieges) 2)
         (let ([a1 (first ag-sieges)] [a2 (second ag-sieges)])
           (and (not (= (second a1) (second a2)))
                (>= (sqrt (+ (sqr (- (fourth a1) (fourth a2)))
                             (sqr (- (fifth a1) (fifth a2)))))
                    20.0)))))
  ;; Verify wire translation of `morph-liberator-ag` -> SC2 Ability ID 2558!
  (define wire-obs-lib
    (sc2-observation 9800 (sc2-player-common 1 400 200 90 140 40 20 0 1 0 2)
                     (list (sc2-unit 1 1 79322 689 1 (sc2-point3d px1 py1 8.0) 0.0 1.2 1.0 0 #f #f #f
                                     180.0 180.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0))
                     '() '() #f '() '() '() '() '() '()))
  (define wire-cmds-lib (translate-bot-actions->sc2-raw-commands (list (first ag-sieges)) wire-obs-lib))
  (define wire-2558-ok?
    (equal? (map sc2-raw-unit-command-ability-id (filter sc2-raw-unit-command? wire-cmds-lib))
            '(2558)))

  ;; (b) Anti-Liberator Worker Evacuation: Drones <= 5.8t of LiberatorDefenderZone evacuate >= 7.5t away!
  (define drones-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 79401 i) 'drone (+ 57.5 (* 0.4 (modulo i 4))) (+ 31.0 (* 0.5 (quotient i 4))) #:hp 40.0)))
  (define z-bldgs-ev
    (list (mk-u 79430 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 79431 'hatchery 62.5 32.5 #:hp 1500.0)))
  (define rt-ev (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define a-ev
    (run-l34 rt-ev
             (mk-live-obs 'Zerg 'Terran 8200
                          #:ally-units drones-12 #:ally-buildings z-bldgs-ev
                          #:enemy-units (list (mk-u 79450 'liberator-ag 52.0 32.0 #:hp 180.0 #:flying #t))
                          #:effects (list (hasheq 'type 'liberator-defender-zone 'effect-id 9 'x 58.0 'y 32.0)))))
  (define evac-moves
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'move) (>= (length a) 4)
                   (exact-integer? (second a)) (<= 79401 (second a) 79412)
                   (>= (sqrt (+ (sqr (- (third a) 58.0)) (sqr (- (fourth a) 32.0)))) 7.5)))
            a-ev))
  (define workers-evacuated? (= (length evac-moves) 12))

  ;; (c) Minimal Local AA Peel: Main army (20 Marines + 6 Marauders = 32 supply) actively fighting
  ;;     at (118, 92) while 1 enemy Liberator harasses main base (32.5, 32.5) with 6 local Marines nearby ->
  ;;     peels strictly <= 4 AA units (<= 12% supply, floor 3) to attack Liberator; frontline stays locked on enemy army!
  (define main-front-army
    (append (for/list ([i (in-range 20)])
              (mk-u (+ 79501 i) 'marine (+ 114.0 (* 0.4 (modulo i 5))) (+ 90.0 (* 0.5 (quotient i 5))) #:hp 45.0))
            (for/list ([i (in-range 6)])
              (mk-u (+ 79531 i) 'marauder (+ 116.0 (* 0.5 i)) 91.0 #:hp 125.0))
            (for/list ([i (in-range 6)])
              (mk-u (+ 79551 i) 'marine (+ 36.0 (* 0.6 i)) 34.0 #:hp 45.0))))
  (define front-enemies
    (cons (mk-u 79599 'liberator-ag 29.0 34.0 #:hp 180.0 #:flying #t)
          (for/list ([i (in-range 10)])
            (mk-u (+ 79570 i) 'stalker (+ 122.0 (* 0.5 (modulo i 5))) (+ 90.0 (* 0.6 (quotient i 5))) #:hp 80.0 #:shield 80.0))))
  (define rt-peel (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-peel
    (run-l34 rt-peel
             (mk-live-obs 'Terran 'Protoss 10200
                          #:ally-units main-front-army #:ally-buildings t-bldgs
                          #:enemy-units front-enemies)))
  (define peeled-to-lib
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                   (= (third a) 79599)))
            a-peel))
  (define front-pulled-to-lib
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                   (<= 79501 (second a) 79536)
                   (= (third a) 79599)))
            a-peel))
  (define front-fighting-stalkers
    (filter (lambda (a)
              (and (pair? a) (memq (car a) '(attack-unit attack-pos))
                   (exact-integer? (second a)) (<= 79501 (second a) 79536)))
            a-peel))
  (define minimal-peel-ok?
    (and (>= (length peeled-to-lib) 3)
         (<= (length peeled-to-lib) 4)
         (null? front-pulled-to-lib)
         (>= (length front-fighting-stalkers) 16)))

  (check-true "l79-b2-liberator-deadspace-multiprong-sieges-2-bases-and-evacuates-workers-with-minimal-aa-peel"
              (and two-distinct-sieges? wire-2558-ok? workers-evacuated? minimal-peel-ok?)
              (format "sieges2=~a wire2558=~a evac=~a/~a peel=~a frontPulled=~a frontFight=~a"
                      two-distinct-sieges? wire-2558-ok? (length evac-moves) 12
                      (length peeled-to-lib) (length front-pulled-to-lib) (length front-fighting-stalkers))))

;; -----------------------------------------------------------------------------
;; Test 3: l79-b3-carrier-binary-commitment-no-mixing
;; -----------------------------------------------------------------------------
(let ()
  (define carriers-4
    (list (mk-u 79601 'carrier 100.0 90.0 #:hp 220.0 #:max-hp 300.0 #:shield 40.0 #:max-shield 150.0 #:flying #t)
          (mk-u 79602 'carrier 102.0 92.0 #:hp 300.0 #:max-hp 300.0 #:shield 150.0 #:max-shield 150.0 #:flying #t)
          (mk-u 79603 'carrier 102.0 88.0 #:hp 300.0 #:max-hp 300.0 #:shield 150.0 #:max-shield 150.0 #:flying #t)
          (mk-u 79604 'carrier 104.0 90.0 #:hp 300.0 #:max-hp 300.0 #:shield 150.0 #:max-shield 150.0 #:flying #t)))
  (define interceptors-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 79620 i) 'interceptor (+ 95.0 (* 0.4 (modulo i 4))) (+ 88.5 (* 0.6 (quotient i 4)))
            #:hp 40.0 #:shield 40.0 #:flying #t)))
  (define t-bldgs-c (list (mk-u 79690 'orbital-command 32.5 32.5 #:hp 1500.0)))
  (define z-bldgs-c (list (mk-u 79691 'hatchery 32.5 32.5 #:hp 1500.0)))

  ;; (a) 14 Vikings + 12 Marines + 2 Medivacs vs 4 Carriers + 16 Interceptors -> 100% 'carrier-snipe!
  (define bio-vik-army
    (append (for/list ([i (in-range 14)])
              (mk-u (+ 79701 i) 'viking-fighter 93.0 (+ 87.0 (* 0.4 i)) #:hp 135.0 #:flying #t))
            (for/list ([i (in-range 12)])
              (mk-u (+ 79721 i) 'marine 94.0 (+ 87.5 (* 0.4 i)) #:hp 45.0))
            (for/list ([i (in-range 2)])
              (mk-u (+ 79741 i) 'medivac 90.0 (+ 89.0 (* 1.0 i)) #:hp 150.0 #:flying #t))))
  (define rt-snipe (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-snipe
    (run-l34 rt-snipe
             (mk-live-obs 'Terran 'Protoss 12000
                          #:ally-units bio-vik-army #:ally-buildings t-bldgs-c
                          #:enemy-units (append carriers-4 interceptors-16)
                          #:researched-upgrades '(stimpack combat-shield))))
  (define snipe-atks
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                   (or (<= 79701 (second a) 79714) (<= 79721 (second a) 79732))))
            a-snipe))
  (define snipe-on-carriers
    (count (lambda (a) (<= 79601 (third a) 79604)) snipe-atks))
  (define snipe-on-interceptors
    (count (lambda (a) (<= 79620 (third a) 79635)) snipe-atks))
  (define pure-snipe-ok?
    (and (>= snipe-on-carriers 20) (= snipe-on-interceptors 0)))

  ;; (b) 24 Hydralisks + 2 Vipers vs 4 Carriers + 16 Interceptors -> 100% 'interceptor-burn!
  (define hydra-viper-army
    (append (for/list ([i (in-range 24)])
              (mk-u (+ 79751 i) 'hydralisk (+ 91.0 (* 0.4 (modulo i 6))) (+ 88.0 (* 0.5 (quotient i 6))) #:hp 90.0))
            (for/list ([i (in-range 2)])
              (mk-u (+ 79781 i) 'viper 88.0 (+ 89.0 (* 1.2 i)) #:hp 150.0 #:energy 150.0 #:flying #t))))
  (define rt-burn (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define a-burn
    (run-l34 rt-burn
             (mk-live-obs 'Zerg 'Protoss 12000
                          #:ally-units hydra-viper-army #:ally-buildings z-bldgs-c
                          #:enemy-units (append carriers-4 interceptors-16)
                          #:researched-upgrades '(grooved-spines muscular-augments))))
  (define burn-hydra-atks
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                   (<= 79751 (second a) 79774)))
            a-burn))
  (define burn-on-interceptors
    (count (lambda (a) (<= 79620 (third a) 79635)) burn-hydra-atks))
  (define burn-on-carriers
    (count (lambda (a) (<= 79601 (third a) 79604)) burn-hydra-atks))
  (define pure-burn-ok?
    (and (>= burn-on-interceptors 20) (= burn-on-carriers 0)))

  ;; (c) Flip-back to 'carrier-snipe once Interceptors drop <= 2 * carriers (4 Interceptors for 4 Carriers)!
  (define rt-flip (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define a-flip
    (run-l34 rt-flip
             (mk-live-obs 'Zerg 'Protoss 12200
                          #:ally-units hydra-viper-army #:ally-buildings z-bldgs-c
                          #:enemy-units (append carriers-4 (take interceptors-16 4))
                          #:researched-upgrades '(grooved-spines muscular-augments))))
  (define flip-hydra-atks
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                   (<= 79751 (second a) 79774)))
            a-flip))
  (define flip-on-carriers
    (count (lambda (a) (<= 79601 (third a) 79604)) flip-hydra-atks))
  (define flip-on-interceptors
    (count (lambda (a) (<= 79620 (third a) 79635)) flip-hydra-atks))
  (define flip-back-ok?
    (and (>= flip-on-carriers 20) (= flip-on-interceptors 0)))

  ;; (d) Thor binary coupling: 'interceptor-burn -> Explosive (2364); 'carrier-snipe -> High-Impact (2362)!
  (define rt-th-burn (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-th-burn
    (run-l34 rt-th-burn
             (mk-live-obs 'Terran 'Protoss 12000
                          #:ally-units (append (list (mk-u 79801 'thor-ap 92.0 90.0 #:hp 400.0)
                                                     (mk-u 79802 'thor-ap 92.0 91.5 #:hp 400.0))
                                               (for/list ([i (in-range 20)])
                                                 (mk-u (+ 79810 i) 'marine 93.0 (+ 88.0 (* 0.3 i)) #:hp 45.0)))
                          #:ally-buildings t-bldgs-c
                          #:enemy-units (append carriers-4 interceptors-16))))
  (define thor-expl-ok?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (equal? (second a) 79801)
                            (eq? (third a) 'morph-thor-explosive)))
           a-th-burn))
  (define rt-th-snipe (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-th-snipe
    (run-l34 rt-th-snipe
             (mk-live-obs 'Terran 'Protoss 12000
                          #:ally-units (append (list (mk-u 79851 'thor 92.0 90.0 #:hp 400.0)
                                                     (mk-u 79852 'thor 92.0 91.5 #:hp 400.0))
                                               (for/list ([i (in-range 12)])
                                                 (mk-u (+ 79860 i) 'viking-fighter 93.0 (+ 88.0 (* 0.4 i)) #:hp 135.0 #:flying #t)))
                          #:ally-buildings t-bldgs-c
                          #:enemy-units (append carriers-4 interceptors-16))))
  (define thor-hi-ok?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (equal? (second a) 79851)
                            (eq? (third a) 'morph-thor-high-impact)))
           a-th-snipe))

  (check-true "l79-b3-carrier-binary-commitment-no-mixing"
              (and pure-snipe-ok? pure-burn-ok? flip-back-ok? thor-expl-ok? thor-hi-ok?)
              (format "snipe=~a/~a burn=~a/~a flip=~a/~a thorExpl=~a thorHI=~a"
                      snipe-on-carriers snipe-on-interceptors
                      burn-on-interceptors burn-on-carriers
                      flip-on-carriers flip-on-interceptors
                      thor-expl-ok? thor-hi-ok?)))

;; -----------------------------------------------------------------------------
;; Test 4 (Pass 2 Anomaly 2): `sh-d02` 0-TH Arena Stalkers+Immortals kite radially
;; away from Locusts when Swarm Hosts are 16-17t behind Locust wall, then punish!
;; -----------------------------------------------------------------------------
(let ()
  (define sh-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 79901 i) 'swarm-host-mp 76.0 (+ 56.0 (* 0.8 i)) #:hp 160.0)))
  (define loc-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 79920 i) (if (even? i) 'locust-mp 'locust-mp-flying)
            (+ 66.5 (* 0.4 (modulo i 4))) (+ 57.5 (* 0.7 (quotient i 4)))
            #:hp 50.0 #:flying (odd? i))))
  (define sh-d02-army
    (append (for/list ([i (in-range 4)])
              (mk-u (+ 79950 i) 'immortal 60.0 (+ 58.0 (* 1.0 i)) #:hp 200.0 #:shield 100.0))
            (for/list ([i (in-range 10)])
              (mk-u (+ 79960 i) 'stalker 59.0 (+ 56.5 (* 0.7 i)) #:hp 80.0 #:shield 80.0))))

  ;; (a) Active 16-Locust wave with 10 Swarm Hosts 16-17t behind them, 0 TownHalls, nat-x/nat-y on top of P1!
  (define rt-d02 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-d02
    (run-l34 rt-d02
             (mk-live-obs 'Protoss 'Zerg 400
                          #:ally-units sh-d02-army #:ally-buildings '()
                          #:enemy-units (append sh-10 loc-16)
                          #:base-x 60.0 #:base-y 60.0 #:nat-x 60.0 #:nat-y 60.0
                          #:enemy-x 76.0 #:enemy-y 60.0
                          #:researched-upgrades '(blink))))
  (define d02-kites-away
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'kite) (>= (length a) 4)
                  (<= 79950 (second a) 79969)
                  (< (third a) 58.5)))
           a-d02))
  (define d02-any-brawl-atk?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-unit)
                  (<= 79950 (second a) 79969)))
           a-d02))

  ;; (b) Once Locusts expire (0 Locusts left, only 10 Swarm Hosts on cooldown): MUST counter-punish!
  (define rt-pun (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-pun
    (run-l34 rt-pun
             (mk-live-obs 'Protoss 'Zerg 900
                          #:ally-units sh-d02-army #:ally-buildings '()
                          #:enemy-units sh-10
                          #:base-x 60.0 #:base-y 60.0 #:nat-x 60.0 #:nat-y 60.0
                          #:enemy-x 76.0 #:enemy-y 60.0
                          #:researched-upgrades '(blink))))
  (define pun-atks
    (count (lambda (a)
             (and (pair? a) (memq (car a) '(attack-unit attack-pos))
                  (let ([u0 (second a)])
                    (or (and (integer? u0) (<= 79950 u0 79969))
                        (and (list? u0) (ormap (lambda (x) (<= 79950 x 79969)) u0))))))
           a-pun))
  (define pun-any-kite?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (<= 79950 (second a) 79969))) a-pun))

  (check-true "l79-pass2-sh-d02-stalkers-kite-0th-when-sh-17t-behind-locusts"
              (and (>= d02-kites-away 12) (not d02-any-brawl-atk?)
                   (>= pun-atks 10) (not pun-any-kite?))
              (format "kitesAway=~a/14 brawlAtk=~a punAtks=~a punKite=~a"
                      d02-kites-away d02-any-brawl-atk? pun-atks pun-any-kite?)))

;; -----------------------------------------------------------------------------
;; Test 5 (Pass 2 Anomaly 3): `sh-d03` 0-TH Arena Hellbat+Marine+Tank stand-and-clear
;; emits Siege Mode (`388`) + Stimpack (`3675`) vs Locusts and keeps Tanks behind Hellbats!
;; -----------------------------------------------------------------------------
(let ()
  (define sh-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 80001 i) 'swarm-host-mp 76.0 (+ 56.0 (* 0.8 i)) #:hp 160.0)))
  (define loc-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 80020 i) 'locust-mp (+ 67.0 (* 0.4 (modulo i 4))) (+ 57.5 (* 0.7 (quotient i 4))) #:hp 50.0)))
  (define d03-army
    (append (for/list ([i (in-range 6)])
              (mk-u (+ 80050 i) 'hellbat 60.4 (+ 57.5 (* 0.8 i)) #:hp 135.0))
            (for/list ([i (in-range 12)])
              (mk-u (+ 80060 i) 'marine 59.4 (+ 56.5 (* 0.5 i)) #:hp 55.0 #:max-hp 55.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 80080 i) 'siege-tank 58.2 (+ 58.0 (* 1.0 i)) #:hp 175.0))))

  ;; (a) Layered formation: 4/4 Tanks cast `siege-mode` (388) AND >= 10/12 Marines cast `stimpack` (3675)!
  (define rt-d03 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-d03
    (run-l34 rt-d03
             (mk-live-obs 'Terran 'Zerg 400
                          #:ally-units d03-army #:ally-buildings '()
                          #:enemy-units (append sh-10 loc-16)
                          #:base-x 59.0 #:base-y 60.0 #:nat-x 59.0 #:nat-y 60.0
                          #:enemy-x 76.0 #:enemy-y 60.0
                          #:researched-upgrades '(stimpack combat-shield))))
  (define tank-siege-cnt
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
                  (<= 80080 (second a) 80083)
                  (eq? (third a) 'siege-mode)))
           a-d03))
  (define marine-stim-cnt
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
                  (<= 80060 (second a) 80071)
                  (eq? (third a) 'stimpack)))
           a-d03))
  ;; Verify wire translation of `siege-mode` (388) and `stimpack` (3675)!
  (define wire-obs-d03
    (sc2-observation 400 (sc2-player-common 1 400 200 60 100 0 60 0 0 0 0)
                     (list (sc2-unit 1 1 80080 33 1 (sc2-point3d 58.2 58.0 8.0) 0.0 0.875 1.0 0 #f #f #f
                                     175.0 175.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0)
                           (sc2-unit 1 1 80060 48 1 (sc2-point3d 59.4 56.5 8.0) 0.0 0.375 1.0 0 #f #f #f
                                     55.0 55.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0))
                     '() '() #f '() '() '() '() '() '()))
  (define wire-d03-ids
    (map sc2-raw-unit-command-ability-id
         (filter sc2-raw-unit-command?
                 (translate-bot-actions->sc2-raw-commands
                  (list (list 'cast-spell 80080 'siege-mode)
                        (list 'cast-spell 80060 'stimpack))
                  wire-obs-d03))))
  (define wire-388-3675-ok? (and (memv 388 wire-d03-ids) (memv 3675 wire-d03-ids) #t))

  ;; (b) Role-layering: an unsieged Tank 3.0t AHEAD of Hellbats while Locusts are 11t away steps behind!
  (define loc-far
    (for/list ([i (in-range 12)])
      (mk-u (+ 80100 i) 'locust-mp (+ 74.5 (* 0.3 (modulo i 4))) (+ 58.0 (* 0.5 (quotient i 4))) #:hp 50.0)))
  (define d03-inv-army
    (append (for/list ([i (in-range 6)])
              (mk-u (+ 80120 i) 'hellbat 60.0 (+ 57.5 (* 0.8 i)) #:hp 135.0))
            (for/list ([i (in-range 8)])
              (mk-u (+ 80130 i) 'marine 59.5 (+ 57.0 (* 0.5 i)) #:hp 55.0 #:max-hp 55.0))
            (list (mk-u 80150 'siege-tank 63.2 59.5 #:hp 175.0)
                  (mk-u 80151 'siege-tank 58.0 59.5 #:hp 175.0)
                  (mk-u 80152 'siege-tank 58.0 60.5 #:hp 175.0))))
  (define rt-inv (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-inv
    (run-l34 rt-inv
             (mk-live-obs 'Terran 'Zerg 420
                          #:ally-units d03-inv-army #:ally-buildings '()
                          #:enemy-units (append sh-10 loc-far)
                          #:base-x 59.0 #:base-y 60.0 #:nat-x 59.0 #:nat-y 60.0
                          #:enemy-x 76.0 #:enemy-y 60.0
                          #:researched-upgrades '(stimpack combat-shield))))
  (define ahead-tank-stepped-back?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move) (>= (length a) 4)
                  (equal? (second a) 80150)
                  (< (third a) 59.5)))
           a-inv))

  (check-true "l79-pass2-sh-d03-tanks-siege-388-and-marines-stim-3675-vs-locusts"
              (and (= tank-siege-cnt 4) (>= marine-stim-cnt 10)
                   wire-388-3675-ok? ahead-tank-stepped-back?)
              (format "siege=~a/4 stim=~a/12 wire=~a rearStep=~a"
                      tank-siege-cnt marine-stim-cnt wire-388-3675-ok? ahead-tank-stepped-back?)))

;; -----------------------------------------------------------------------------
;; Test 6 (Pass 2 Anomaly 4): `liberator-ag` & ground-only `liberator` emit ZERO
;; `attack`/`attack-unit`/`attack-pos` (`ability 23` wire rejects == 0!), `ro25` solo
;; Liberators hold/siege behind minerals, and fighter `liberator` still attacks air!
;; -----------------------------------------------------------------------------
(let ()
  (define (is-lib-attack-act? a lib-ids)
    (and (pair? a) (memq (car a) '(attack attack-unit attack-pos)) (>= (length a) 2)
         (let ([u0 (second a)])
           (or (and (integer? u0) (memv u0 lib-ids) #t)
               (and (list? u0) (ormap (lambda (x) (memv x lib-ids)) u0))))))

  ;; (a) `ro25`-style 2 solo Liberators (1 already sieged `liberator-ag` behind minerals + 1 fighter
  ;;     `liberator` approaching ground-only 16 Drones + 2 Queens + Hatchery) -> ZERO `attack` (23),
  ;;     ZERO premature `2560` unsiege!
  (define z-hatch (list (mk-u 80250 'hatchery 156.5 148.5 #:hp 1500.0)))
  (define z-mps (list (hasheq 'id 80251 'type 'mineral-field 'x 162.5 'y 154.5)))
  (define z-def-ground
    (append (for/list ([i (in-range 16)])
              (mk-u (+ 80260 i) 'drone (+ 161.5 (* 0.3 (modulo i 4))) (+ 153.0 (* 0.4 (quotient i 4))) #:hp 40.0))
            (list (mk-u 80280 'queen 154.0 148.5 #:hp 175.0)
                  (mk-u 80281 'queen 154.0 150.5 #:hp 175.0))))
  (define-values (rpx rpy rsx rsy) (compute-liberator-deadspace-spot 156.5 148.5 162.5 154.5 200.0 200.0 #f))
  (define ro25-libs
    (list (mk-u 80201 'liberator-ag rpx rpy #:hp 180.0 #:flying #t)
          (mk-u 80202 'liberator 147.0 148.5 #:hp 180.0 #:flying #t)))
  (define rt-ro25 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-ro25
    (run-l34 rt-ro25
             (mk-live-obs 'Terran 'Zerg 500
                          #:ally-units ro25-libs #:ally-buildings '()
                          #:enemy-units z-def-ground #:enemy-buildings z-hatch
                          #:mineral-patches z-mps
                          #:base-x 147.0 #:base-y 148.5 #:nat-x 147.0 #:nat-y 148.5
                          #:enemy-x 156.5 #:enemy-y 148.5)))
  (define ro25-lib-atk-cnt (count (lambda (a) (is-lib-attack-act? a '(80201 80202))) a-ro25))
  (define ro25-premature-unsiege?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'cast-spell) (equal? (second a) 80201)
                  (eq? (third a) 'morph-liberator-aa)))
           a-ro25))
  ;; Verify wire translation produces ZERO `ability 23` commands for Liberators!
  (define wire-obs-ro25
    (sc2-observation 500 (sc2-player-common 1 400 200 6 100 0 6 0 0 0 0)
                     (list (sc2-unit 1 1 80201 734 1 (sc2-point3d rpx rpy 10.0) 0.0 1.2 1.0 0 #f #f #f
                                     180.0 180.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0)
                           (sc2-unit 1 1 80202 689 1 (sc2-point3d 147.0 148.5 10.0) 0.0 1.2 1.0 0 #f #f #f
                                     180.0 180.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0))
                     '() '() #f '() '() '() '() '() '()))
  (define ro25-wire-23-cnt
    (count (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 23)
                  (ormap (lambda (tag) (memv tag '(80201 80202)))
                         (sc2-raw-unit-command-unit-tags c))))
           (translate-bot-actions->sc2-raw-commands a-ro25 wire-obs-ro25)))

  ;; (b) Frontline `liberator` + `liberator-ag` + Marines vs ground-only Hydralisks/Queens (`lib-m01`
  ;;     ground-only combat, Liberators on dwell cooldown so Phase 5b runs) -> ZERO `attack` (23) for Libs!
  (define mix-lib-army
    (append (list (mk-u 80301 'liberator-ag 92.0 82.0 #:hp 180.0 #:flying #t)
                  (mk-u 80302 'liberator 80.0 82.0 #:hp 180.0 #:flying #t))
            (for/list ([i (in-range 8)])
              (mk-u (+ 80310 i) 'marine 91.0 (+ 80.0 (* 0.5 i)) #:hp 55.0))))
  (define ground-only-en
    (for/list ([i (in-range 6)])
      (mk-u (+ 80350 i) 'hydralisk 98.0 (+ 80.0 (* 0.6 i)) #:hp 90.0)))
  (define rt-mix (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-mix
    (run-l34 rt-mix
             (mk-live-obs 'Terran 'Zerg 600
                          #:ally-units mix-lib-army #:ally-buildings '()
                          #:enemy-units ground-only-en
                          #:base-x 80.0 #:base-y 82.0 #:nat-x 80.0 #:nat-y 82.0
                          #:enemy-x 98.0 #:enemy-y 82.0)))
  (define mix-lib-atk-cnt (count (lambda (a) (is-lib-attack-act? a '(80301 80302))) a-mix))

  ;; (c) Fighter-mode `liberator` facing flying `mutalisk`s STILL attacks air cleanly!
  (define rt-aa (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-aa
    (run-l34 rt-aa
             (mk-live-obs 'Terran 'Zerg 700
                          #:ally-units (list (mk-u 80401 'liberator 88.0 82.0 #:hp 180.0 #:flying #t)
                                             (mk-u 80402 'liberator 88.0 84.0 #:hp 180.0 #:flying #t))
                          #:ally-buildings (list (mk-u 80410 'orbital-command 32.5 32.5 #:hp 1500.0))
                          #:enemy-units (list (mk-u 80450 'mutalisk 92.0 82.0 #:hp 120.0 #:flying #t)
                                              (mk-u 80451 'mutalisk 92.0 84.0 #:hp 120.0 #:flying #t))
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-x 156.5 #:enemy-y 148.5)))
  (define fighter-attacks-muta?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                  (memv (second a) '(80401 80402))
                  (memv (third a) '(80450 80451))))
           a-aa))

  (check-true "l79-pass2-liberator-ag-and-ground-liberator-zero-attack-23-and-ro25-hold"
              (and (= ro25-lib-atk-cnt 0) (= ro25-wire-23-cnt 0) (not ro25-premature-unsiege?)
                   (= mix-lib-atk-cnt 0) fighter-attacks-muta?)
              (format "ro25Atk=~a ro25Wire23=~a premUnsiege=~a mixAtk=~a aaMuta=~a"
                      ro25-lib-atk-cnt ro25-wire-23-cnt ro25-premature-unsiege?
                      mix-lib-atk-cnt fighter-attacks-muta?)))

;; -----------------------------------------------------------------------------
;; Test 7 (Pass 3): `lib-m01` mixed Marines + Liberator-AG keeps `execute-spatial-maneuver`
;; & Marine attacks active (zero Lib `23`), AND `siege-tank-sieged` drops `< 3.25t` / flying `23`!
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Mixed 8 Marines + 1 Medivac + 1 Liberator-AG + 1 Liberator vs Zerg mineral line:
  ;;     `execute-spatial-maneuver` MUST still be emitted for the escort Marines, Marines MUST
  ;;     attack (`>= 6`), AND Liberators STILL emit `0` `attack` commands!
  (define m01-army
    (append (list (mk-u 80501 'liberator-ag 164.0 156.0 #:hp 180.0 #:flying #t)
                  (mk-u 80502 'liberator 147.0 146.0 #:hp 180.0 #:flying #t)
                  (mk-u 80503 'medivac 146.0 151.0 #:hp 150.0 #:energy 100.0 #:flying #t))
            (for/list ([i (in-range 8)])
              (mk-u (+ 80510 i) 'marine 147.5 (+ 149.0 (* 0.4 i)) #:hp 55.0 #:max-hp 55.0))))
  (define m01-enemies
    (append (for/list ([i (in-range 12)])
              (mk-u (+ 80530 i) 'drone (+ 161.0 (* 0.3 (modulo i 4))) (+ 152.5 (* 0.4 (quotient i 4))) #:hp 40.0))
            (list (mk-u 80550 'queen 154.0 149.0 #:hp 175.0)
                  (mk-u 80551 'hydralisk 153.0 150.5 #:hp 90.0)
                  (mk-u 80552 'hydralisk 153.0 151.5 #:hp 90.0))))
  (define rt-m01 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-m01
    (run-l34 rt-m01
             (mk-live-obs 'Terran 'Zerg 520
                          #:ally-units m01-army #:ally-buildings '()
                          #:enemy-units m01-enemies
                          #:enemy-buildings (list (mk-u 80560 'hatchery 156.5 148.5 #:hp 1500.0))
                          #:mineral-patches (list (hasheq 'id 80561 'type 'mineral-field 'x 162.5 'y 154.5))
                          #:base-x 147.0 #:base-y 150.0 #:nat-x 147.0 #:nat-y 150.0
                          #:enemy-x 156.5 #:enemy-y 148.5
                          #:researched-upgrades '(stimpack combat-shield))))
  (define m01-has-spatial?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'execute-spatial-maneuver))) a-m01))
  (define m01-marine-atks
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                  (<= 80510 (second a) 80517)))
           a-m01))
  (define m01-lib-atks
    (count (lambda (a)
             (and (pair? a) (memq (car a) '(attack attack-unit attack-pos)) (>= (length a) 2)
                  (let ([u0 (second a)])
                    (or (memv u0 '(80501 80502))
                        (and (list? u0) (ormap (lambda (x) (memv x '(80501 80502))) u0))))))
           a-m01))

  ;; (b) `siege-tank-sieged` with close Locusts (`2.2t` < 3.25t deadzone) + flying Locusts (`7.0t`)
  ;;     + valid ground Locusts (`8.0t`): ZERO `attack-unit` onto `< 3.25t` or flying Locusts!
  (define st-allies
    (append (list (mk-u 80601 'siege-tank-sieged 60.0 60.0 #:hp 175.0)
                  (mk-u 80602 'siege-tank-sieged 60.0 62.0 #:hp 175.0))
            (for/list ([i (in-range 6)])
              (mk-u (+ 80610 i) 'hellbat 62.5 (+ 59.5 (* 0.7 i)) #:hp 135.0))))
  (define st-enemies
    (append (for/list ([i (in-range 6)])
              (mk-u (+ 80630 i) 'locust-mp 62.1 (+ 59.8 (* 0.4 i)) #:hp 50.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 80640 i) 'locust-mp-flying 66.5 (+ 60.0 (* 0.5 i)) #:hp 50.0 #:flying #t))
            (for/list ([i (in-range 4)])
              (mk-u (+ 80650 i) 'locust-mp 68.0 (+ 60.0 (* 0.6 i)) #:hp 50.0))))
  (define rt-st (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-st
    (run-l34 rt-st
             (mk-live-obs 'Terran 'Zerg 540
                          #:ally-units st-allies #:ally-buildings '()
                          #:enemy-units st-enemies
                          #:base-x 59.0 #:base-y 60.0 #:nat-x 59.0 #:nat-y 60.0
                          #:enemy-x 76.0 #:enemy-y 60.0)))
  (define st-bad-deadzone-or-air-atks
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                  (memv (second a) '(80601 80602))
                  (or (<= 80630 (third a) 80635)
                      (<= 80640 (third a) 80643))))
           a-st))

  ;; (c) `siege-tank-sieged` max range `16.5t` covers `5x5` TownHalls at `15.5t` (ALLOWED!)
  ;;     while dropping illegal shots beyond `16.5t` (`17.5t` DROPPED!).
  (define rt-st15 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-st15
    (run-l34 rt-st15
             (mk-live-obs 'Terran 'Zerg 560
                          #:ally-units (cons (mk-u 80661 'siege-tank-sieged 60.0 60.0 #:hp 175.0)
                                             (for/list ([i (in-range 6)])
                                               (mk-u (+ 80662 i) 'marine 62.0 (+ 58.5 (* 0.5 i)) #:hp 55.0)))
                          #:ally-buildings '()
                          #:enemy-units '()
                          #:enemy-buildings (list (mk-u 80670 'hatchery 75.5 60.0 #:hp 1500.0))
                          #:base-x 54.0 #:base-y 60.0 #:nat-x 54.0 #:nat-y 60.0
                          #:enemy-x 75.5 #:enemy-y 60.0)))
  (define st-15.5-allowed?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                  (equal? (second a) 80661) (equal? (third a) 80670)))
           a-st15))
  (define rt-st17 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-st17
    (run-l34 rt-st17
             (mk-live-obs 'Terran 'Zerg 560
                          #:ally-units (cons (mk-u 80681 'siege-tank-sieged 60.0 60.0 #:hp 175.0)
                                             (for/list ([i (in-range 6)])
                                               (mk-u (+ 80682 i) 'marine 62.0 (+ 58.5 (* 0.5 i)) #:hp 55.0)))
                          #:ally-buildings '()
                          #:enemy-units (list (mk-u 80688 'zergling 61.5 60.0 #:hp 35.0))
                          #:enemy-buildings (list (mk-u 80690 'hatchery 77.5 60.0 #:hp 1500.0))
                          #:base-x 54.0 #:base-y 60.0 #:nat-x 54.0 #:nat-y 60.0
                          #:enemy-x 77.5 #:enemy-y 60.0)))
  (define st-17.5-dropped?
    (not (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
                       (equal? (second a) 80681) (equal? (third a) 80690)))
                a-st17)))

  (check-true "l79-pass3-lib-m01-marines-spatial-and-sieged-tank-min-range-air-guard"
              (and m01-has-spatial? (>= m01-marine-atks 6) (= m01-lib-atks 0)
                   (= st-bad-deadzone-or-air-atks 0) st-15.5-allowed? st-17.5-dropped?)
              (format "spatial=~a marAtk=~a libAtk=~a stBadAtk=~a st15.5=~a st17.5Drop=~a"
                      m01-has-spatial? m01-marine-atks m01-lib-atks
                      st-bad-deadzone-or-air-atks st-15.5-allowed? st-17.5-dropped?)))

;; -----------------------------------------------------------------------------
;; Test 8: Loop 80 Post-Merge Micro Fixes (`sh-d01` 0-TH Fog-of-War Center Sweep
;;         & `lib-m01` Combined Bio+Liberator Escort Hold + Queen/Drone Raid)
;; -----------------------------------------------------------------------------
(printf "\n[8] Loop 80: 0-TH Fog-of-War Center Sweep & Combined Bio+Liberator Escort\n")
(let ()
  ;; (a) 0-TH mid-map army (`3 archon + 8 stalker + 3 colossus`) at `(71, 88)` on `176x172`
  ;;     with `0` visible enemies & mirrored spawn (`P1=BR`, `P2=TL (33.5, 138.5)`) MUST sweep
  ;;     EAST across map center `(88, 86)` (`x >= 85`) instead of marching west toward `(33.5, 138.5)`!
  (define rt-sh (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define sh-allies
    (append
     (for/list ([i (in-range 3)]) (mk-u (+ 81100 i) 'archon 72.2 (+ 86.0 i) #:hp 10.0 #:shield 350.0))
     (for/list ([i (in-range 8)]) (mk-u (+ 81200 i) 'stalker 71.2 (+ 84.5 i) #:hp 80.0 #:shield 80.0))
     (for/list ([i (in-range 3)]) (mk-u (+ 81300 i) 'colossus 70.2 (+ 86.0 i) #:hp 200.0 #:shield 150.0))))
  (define obs-sh
    (hash-set* (mk-live-obs 'Protoss 'Zerg 152
                            #:ally-units sh-allies #:ally-buildings '()
                            #:enemy-units '() #:enemy-buildings '()
                            #:base-x 142.5 #:base-y 33.5 #:nat-x 135.0 #:nat-y 55.0
                            #:enemy-x 33.5 #:enemy-y 138.5 #:enemy-exp-x 55.0 #:enemy-exp-y 135.0
                            #:researched-upgrades '(extended-thermal-lance)
                            #:supply-used 46 #:supply-cap 200)
               'map-width 176 'map-height 172))
  (define acts-sh (run-l34 rt-sh obs-sh))
  (define sh-east-sweeps
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-pos) (>= (length a) 4)
                  (real? (third a)) (>= (third a) 85.0)))
           acts-sh))
  (define sh-west-stalls
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-pos) (>= (length a) 4)
                  (real? (third a)) (< (third a) 60.0)))
           acts-sh))

  ;; (b) Combined Bio+Liberator escort (`2 liberator + 8 marine + 1 medivac` at BR `(142.5, 33.5)`)
  ;;     fighting `4 hydralisk + 2 queen + 16 drone + spore + hatch`: healthy Liberators supported
  ;;     by `>= 3` Marines within `<= 12t` siege in place (`morph-liberator-ag`) with ZERO off-screen evade!
  (define rt-lm1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define lm-mps
    (for/list ([i (in-range 8)])
      (hasheq 'id (+ 81900 i) 'type 'mineral-field
              'x (if (< i 4) 149.0 (+ 144.0 (* (- i 4) 1.5)))
              'y (if (< i 4) (+ 30.0 (* i 1.5)) 27.5))))
  (define lm-drones
    (for/list ([i (in-range 16)])
      (mk-u (+ 81400 i) 'drone (if (< i 8) 147.0 (+ 144.0 (* 0.5 (- i 8))))
            (if (< i 8) (+ 29.5 (* 0.6 i)) 29.0) #:hp 40.0)))
  (define lm-queens
    (list (mk-u 81500 'queen 139.0 36.0 #:hp 175.0)
          (mk-u 81501 'queen 139.5 35.0 #:hp 175.0)))
  (define lm-hydras
    (for/list ([i (in-range 4)])
      (mk-u (+ 81600 i) 'hydralisk (+ 137.5 (* 0.4 (modulo i 2))) (+ 35.5 (* 0.7 (quotient i 2))) #:hp 90.0)))
  (define lm-spore (hash-set (mk-u 81700 'spore-crawler 145.5 34.0 #:hp 400.0) 'structure? #t))
  (define lm-hatch (hash-set (mk-u 81701 'hatchery 142.5 33.5 #:hp 1500.0) 'structure? #t))
  (define lm-allies1
    (append
     (list (mk-u 81800 'liberator 137.5 42.0 #:hp 180.0 #:flying #t)
           (mk-u 81801 'liberator 138.5 42.0 #:hp 180.0 #:flying #t))
     (for/list ([i (in-range 8)])
       (mk-u (+ 81810 i) 'marine (+ 133.5 (* 0.4 (modulo i 4))) (+ 37.5 (* 0.4 (quotient i 4))) #:hp 55.0))
     (list (mk-u 81890 'medivac 131.5 39.5 #:hp 150.0 #:energy 100.0 #:flying #t))))
  (define obs-lm1
    (hash-set* (mk-live-obs 'Terran 'Zerg 1956
                            #:ally-units lm-allies1 #:ally-buildings '()
                            #:enemy-units (append lm-drones lm-queens lm-hydras (list lm-spore lm-hatch))
                            #:enemy-buildings (list lm-spore lm-hatch)
                            #:mineral-patches lm-mps
                            #:base-x 33.5 #:base-y 138.5 #:nat-x 55.0 #:nat-y 135.0
                            #:enemy-x 142.5 #:enemy-y 33.5 #:enemy-exp-x 142.5 #:enemy-exp-y 60.0
                            #:researched-upgrades '(stimpack combat-shield)
                            #:supply-used 16 #:supply-cap 200)
               'map-width 176 'map-height 172))
  (define acts-lm1 (run-l34 rt-lm1 obs-lm1))
  (define lm1-lib-sieges
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
                  (memv (second a) '(81800 81801))
                  (eq? (third a) 'morph-liberator-ag)))
           acts-lm1))
  (define lm1-lib-evade-moves
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'move) (>= (length a) 4)
                  (memv (second a) '(81800 81801))
                  (real? (fourth a)) (> (fourth a) 45.0)))
           acts-lm1))

  ;; (c) Post-Hydralisk phase (`2 marine + 1 medivac` at `dx=8.5t`, `wcd=0.0` vs `2 queen + 16 drone`):
  ;;     Marines MUST emit `(attack-unit ...)` cleanly with ZERO `(kite ...)` yo-yo and ZERO
  ;;     Phase 7 `(attack-pos ... 28t-away)` hijack!
  (define rt-lm2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-lm2
    (hash-set* (mk-live-obs 'Terran 'Zerg 2140
                            #:ally-units (list (mk-u 81810 'marine 130.5 37.5 #:hp 45.0 #:max-hp 55.0)
                                               (mk-u 81811 'marine 130.8 37.5 #:hp 45.0 #:max-hp 55.0)
                                               (mk-u 81890 'medivac 129.0 39.0 #:hp 150.0 #:energy 100.0 #:flying #t))
                            #:ally-buildings '()
                            #:enemy-units (append lm-drones lm-queens (list lm-spore lm-hatch))
                            #:enemy-buildings (list lm-spore lm-hatch)
                            #:mineral-patches lm-mps
                            #:base-x 33.5 #:base-y 138.5 #:nat-x 55.0 #:nat-y 135.0
                            #:enemy-x 142.5 #:enemy-y 33.5 #:enemy-exp-x 142.5 #:enemy-exp-y 60.0
                            #:researched-upgrades '(stimpack combat-shield)
                            #:supply-used 4 #:supply-cap 200)
               'map-width 176 'map-height 172))
  (define acts-lm2 (run-l34 rt-lm2 obs-lm2))
  (define lm2-marine-atks
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-unit)
                  (memv (second a) '(81810 81811))))
           acts-lm2))
  (define lm2-marine-kites
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'kite)
                  (memv (second a) '(81810 81811))))
           acts-lm2))
  (define lm2-marine-hijacks
    (count (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-pos) (>= (length a) 4)
                  (memv (second a) '(81810 81811))
                  (real? (third a)) (< (third a) 126.0)))
           acts-lm2))

  (check-true "l80-sh-d01-fog-center-sweep-and-lib-m01-escort-queen-raid"
              (and (>= sh-east-sweeps 3) (= sh-west-stalls 0)
                   (>= lm1-lib-sieges 1) (= lm1-lib-evade-moves 0)
                   (= lm2-marine-atks 2) (= lm2-marine-kites 0) (= lm2-marine-hijacks 0))
              (format "shEast=~a shWest=~a libSiege=~a libEvade=~a m2Atk=~a m2Kite=~a m2Hijack=~a"
                      sh-east-sweeps sh-west-stalls lm1-lib-sieges lm1-lib-evade-moves
                      lm2-marine-atks lm2-marine-kites lm2-marine-hijacks)))

(printf "\n=== Loop 79 Lane B Summary: ~a/~a passed (~a failed) ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
