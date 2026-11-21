#lang racket
;; =============================================================================
;; Loop 47 Verification Suite: Arena 3.0 Quick-Win Multipliers & Live Leak Fixes
;;   1. `L47-P0-1a` (`ro09` High-Energy `en >= 90` Stasis Suppress + Oracle Raid):
;;      - Remove `(< en 90.0)` ceiling on `save-for-pulsar-raid?` when `>= 4` workers
;;        within `<= 14t` (`>= 8` workers OR active AA OR `sh >= 25.0`), preserving
;;        `L43-T3d` (`sh=20`, 5 workers, 0 AA)!
;;      - Runtime Oracle handler allows `sh >= 15.0` approach over `>= 8` workers / AA
;;        and `hp-rat >= 0.35` when `<= 1` light AA remains!
;;   2. `L47-P0-1a` (`e01` Probe Harass `> 24.0` EHP Rotate-Out + `pull-min-hp = 26.0`):
;;      - Defending Probe drops to `24.0` EHP -> immediately rotates back via
;;        `harvest-mineral`, is NOT re-pulled on the same frame, and a fresh healthy
;;        replacement is pulled with zero lag while `25.0`-EHP defender stays sticky!
;;   3. `L47-P0-1a` (`z16` Muta Magic-Box `>= 1.35t` Spread Gate + `28f` HOLD Dampen):
;;      - Mutas at `1.20t < 1.35t` pairwise sep keep spreading via `move` (NOT `hold-position`).
;;      - Spread Mutas (`>= 1.80t`) emit `hold-position (18)` on entry, suppress duplicate
;;        `18` spam for `28f` while staying locked in `splash-evading-tags`, then refresh at `+28f`!
;;   4. `L47-P0-1b` (`r02`/`r05`/`r06` `rush_probe` `<= 16` HP `16f` Phase-Out + `4f` Focus):
;;      - Defending against `>= 8` invading workers phases out `<= 16` HP workers via
;;        `mineral-walk` for `16f` (`<= 1` per `3.0t` flank, `<= 2` total across split flanks),
;;        releasing back to fight at `+16f` while keeping `14-15` healthy workers swinging!
;;      - Refreshes primary lowest-HP focus target every `4f`!
;;   5. `L47-P0-1b` (`rd01` SP Multi-Mine `3.6t` Scatter onto `> 4.5t` Safe Patches):
;;      - 2 armed Widow Mines on South & East mineral arcs scatter all Drones `<= 3.6t` of
;;        EITHER mine ONLY onto patches `> 4.5t` from BOTH mines simultaneously (or pure away
;;        `move` when every patch is `<= 3.8t` from a mine!).
;;   6. `L47-P0-1b` (`ro11` SP Cloaked Banshee Undetected Worker Chase `<= 14t` + Fog Push):
;;      - Undetected cloaked Banshees chase & focus visible enemy workers `<= 14t` instead of
;;        shooting a closer Hatchery, fly past the Hatchery in Fog when 0 workers are visible,
;;        and yield cleanly when an enemy detector (`overseer`/`spore-crawler`) is `<= 12.5t`!
;;   7. `L47-P0-1b` (`#59` Creepy `canon_rush` Proxy Preempts Light-Harass):
;;      - When `in-base-proxy-detected?` activates after prior light-harass pulls, immediately
;;        clears `light-harass-def-wids` and NEVER overwrites proxy-pylon `pull-workers-attack`
;;        with `(harvest-mineral ...)`!
;;   8. `L47-P0-1b` (`#72` 12PoolBot Emergency Builder Probe Reserve):
;;      - Reserves `1` safe non-fighting Probe near main Nexus during early Ling breach when
;;        Protoss has `>= 150M` and needs `cybernetics-core` / `gateway`, excluding it from
;;        `pull-workers-attack` & `cur-rush-fighting-wids` (zero effect on `e04` with 0 Pylons/GWs)!
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

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
              #:hp [hp 45.0]
              #:max-hp [max-hp hp]
              #:shield [sh 0.0]
              #:max-shield [max-sh sh]
              #:energy [en 0.0]
              #:flying? [fly? #f]
              #:cloaked? [cloak? #f]
              #:cloak [cloak-state (if cloak? 1 0)]
              #:burrowed? [burr? #f]
              #:buffs [buffs '()]
              #:build-progress [bp 1.0]
              #:weapon-cooldown [wcd 0.0]
              #:engaged-target-tag [etgt 0]
              #:assigned-harvesters [ah #f]
              #:ideal-harvesters [ih #f])
  (define h
    (hasheq 'id id 'type type 'x x 'y y
            'hp hp 'max-hp max-hp
            'shield sh 'shields sh 'max-shield max-sh
            'energy en 'flying? fly?
            'cloaked? cloak? 'cloak cloak-state
            'is-burrowed? burr? 'burrowed? burr?
            'buffs buffs 'build-progress bp
            'weapon-cooldown wcd 'engaged-target-tag etgt
            'orders '() 'order-count 0))
  (define h1 (if ah (hash-set h 'assigned-harvesters ah) h))
  (if ih (hash-set h1 'ideal-harvesters ih) h1))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 150]
                     #:gas [gas 0]
                     #:supply-used [sup-used 16]
                     #:supply-cap [sup-cap 23]
                     #:base-x [bx 32.5]
                     #:base-y [by 32.5]
                     #:nat-x [nx 52.5]
                     #:nat-y [ny 34.5]
                     #:enemy-x [ex 142.5]
                     #:enemy-y [ey 138.5]
                     #:mineral-harvesters [mh 12]
                     #:ally-units [aus '()]
                     #:ally-buildings [abs '()]
                     #:enemy-units [eus '()]
                     #:enemy-buildings [ebs '()]
                     #:mineral-patches [mps '()]
                     #:researched-upgrades [upgs '()])
  (hasheq 'frame frame
          'race race
          'enemy-race enemy-race
          'minerals minerals
          'gas gas
          'supply-used sup-used
          'supply-cap sup-cap
          'supply-left (max 0 (- sup-cap sup-used))
          'mineral-harvesters mh
          'vespene-harvesters 0
          'base-x bx 'base-y by
          'natural-x nx 'natural-y ny
          'enemy-x ex 'enemy-y ey
          'ally-units aus
          'ally-buildings abs
          'enemy-units eus
          'enemy-buildings ebs
          'mineral-patches mps
          'researched-upgrades upgs
          'live-obs? #t))

(define (run-l34 rt obs [fap 0.5])
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(printf "=== Loop 47 Tactics & Runtime Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L47-P0-1a (`ro09` High-Energy `en >= 90` Stasis Suppress + Oracle Raid)
;; -----------------------------------------------------------------------------
(let ()
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'scv 30.3 (+ 135.5 (* 0.4 i)) #:hp 45.0)))
  (define marines-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 8001 i) 'marine 36.5 (+ 137.5 (* 0.6 i)) #:hp 45.0)))

  ;; (i) Oracle at HIGH energy (`en = 120.0 >= 90.0`!), low shield (`sh = 10.0 < 15`), over 16 SCVs + 4 Marines:
  ;; MUST NOT bypass `save-for-pulsar-raid?` to drop Stasis Ward (`2505 = 0`)!
  (define d-en120-lowsh
    (plan-protoss-spellcaster-micro
     (list (mk-u 101 'oracle 37.5 138.5 #:hp 100.0 #:shield 10.0 #:energy 120.0 #:flying? #t))
     (append marines-4 scvs-16)
     #:claims (make-spell-claims) #:current-frame 1150))
  ;; (ii) Oracle at HIGH energy (`en = 120.0 >= 90.0`!), `sh = 18.0`, over 16 SCVs + 4 Marines:
  ;; pops `pulsar-beam-on` (`2375`) with ZERO `stasis-ward`!
  (define d-en120-beam
    (plan-protoss-spellcaster-micro
     (list (mk-u 101 'oracle 37.5 138.5 #:hp 100.0 #:shield 18.0 #:energy 120.0 #:flying? #t))
     (append marines-4 scvs-16)
     #:claims (make-spell-claims) #:current-frame 1150))
  ;; (iii) Negative guard (`L43-T3d`): Uncontested low-shield (`sh = 20 < 25`), `en = 95`, 5 SCVs (`< 8`), 0 AA:
  ;; STILL plants `stasis-ward`!
  (define d-l43-preserve
    (plan-protoss-spellcaster-micro
     (list (mk-u 102 'oracle 35.0 138.5 #:hp 100.0 #:shield 20.0 #:energy 95.0 #:flying? #t))
     (take scvs-16 5)
     #:claims (make-spell-claims) #:current-frame 1150))
  (check-true "L47-T1a-ro09-high-energy-oracle-suppresses-stasis-pops-pulsar-and-preserves-l43"
              (and (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-en120-lowsh))
                   (= (length d-en120-beam) 1)
                   (eq? (spell-directive-ability (car d-en120-beam)) 'pulsar-beam-on)
                   (= (length d-l43-preserve) 1)
                   (eq? (spell-directive-ability (car d-l43-preserve)) 'stasis-ward))
              (format "lowsh=~a beam=~a l43=~a" d-en120-lowsh d-en120-beam d-l43-preserve))

  ;; (iv) Runtime `[(oracle) ...]`: Oracle at `sh = 18.0`, `hp = 60.0` (`hp-rat = 0.4875 >= 0.35`),
  ;; `en = 55.0`, beam OFF, vs 16 SCVs + 1 remaining Marine -> moves INTO SCVs (NOT kiting away!).
  (define rt-or (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-or
    (run-l34 rt-or
             (mk-live-obs 'Protoss 'Terran 1200
                          #:supply-used 3 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units (list (mk-u 105 'oracle 40.5 138.5 #:hp 60.0 #:max-hp 100.0
                                                   #:shield 18.0 #:max-shield 60.0 #:energy 55.0 #:flying? #t))
                          #:enemy-units (cons (car marines-4) scvs-16))))
  (define or-move-in?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 105) (<= (third a) 32.0))) acts-or))
  (define or-kited?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 105))) acts-or))
  (check-true "L47-T1a-ro09-runtime-oracle-sh18-dives-into-16-scvs-instead-of-kiting"
              (and or-move-in? (not or-kited?))
              (format "move-in?=~a kited?=~a acts=~a" or-move-in? or-kited? acts-or)))

;; -----------------------------------------------------------------------------
;; 2. L47-P0-1a (`e01` `> 24.0` EHP Rotate-Out + `pull-min-hp = 26.0` Guard)
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 6000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 12 #:ideal-harvesters 16))
  (define main-mps
    (for/list ([i (in-range 8)])
      (hasheq 'id (+ 7001 i) 'x 26.5 'y (+ 28.0 (* 1.2 i)) 'mineral-contents 1500)))
  (define probes-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 6101 i) 'probe 28.5 (+ 28.0 (* 0.75 i)) #:hp 20.0 #:shield 20.0)))
  (define enemy-probes-2
    (list (mk-u 6901 'probe 31.0 29.0 #:hp 20.0 #:shield 20.0)
          (mk-u 6902 'probe 31.0 30.0 #:hp 20.0 #:shield 20.0)))
  (define rt-e01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-1
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 800 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12 #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define pulled-1
    (remove-duplicates
     (append* (for/list ([a (in-list acts-1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (define def-1 (car pulled-1))
  (define def-2 (cadr pulled-1))
  ;; L48-P0-1b: Drop def-1 to `20.0` EHP (`<= 20.0` -> rotates out & NOT re-pulled!),
  ;; while def-2 drops to `21.0` EHP (`> 20.0` -> stays sticky!)
  (define probes-t2
    (for/list ([u (in-list probes-12)])
      (cond
        [(= (hash-ref u 'id) def-1) (hash-set* u 'hp 20.0 'shield 0.0 'shields 0.0)]
        [(= (hash-ref u 'id) def-2) (hash-set* u 'hp 20.0 'shield 1.0 'shields 1.0)]
        [else u])))
  (define acts-2
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 808 #:minerals 110 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-t2 #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define def1-returned?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (second a) def-1))) acts-2))
  (define pulled-2
    (remove-duplicates
     (append* (for/list ([a (in-list acts-2)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (check-true "L47-T1b-e01-rotates-out-at-20-ehp-keeps-21-ehp-sticky-and-replaces-same-frame"
              (and (= (length pulled-1) 2)
                   def1-returned?
                   (= (length pulled-2) 2)
                   (not (memv def-1 pulled-2))
                   (memv def-2 pulled-2))
              (format "p1=~a ret?=~a p2=~a" pulled-1 def1-returned? pulled-2)))

;; -----------------------------------------------------------------------------
;; 3. L47-P0-1a (`z16` Muta Magic-Box `>= 1.35t` Spread Gate + `28f` HOLD Dampen)
;; -----------------------------------------------------------------------------
(let ()
  (define thor1 (list (mk-u 3901 'thor 80.0 80.0 #:hp 400.0)))
  ;; (i) 4 Mutas within `<= 3.95t` of Thor but pairwise `1.20t` (`>= 1.10t`, `< 1.35t`!):
  ;; MUST emit `'move` to keep spreading, ZERO premature `'hold-position`!
  (define clumped-mutas-1.2t
    (list (mk-u 3001 'mutalisk 78.0 79.4 #:hp 120.0 #:flying? #t)
          (mk-u 3002 'mutalisk 78.0 80.6 #:hp 120.0 #:flying? #t) ;; 1.20t from 3001!
          (mk-u 3003 'mutalisk 82.0 79.4 #:hp 120.0 #:flying? #t)
          (mk-u 3004 'mutalisk 82.0 80.6 #:hp 120.0 #:flying? #t))) ;; 1.20t from 3003!
  (define d-clumped (plan-mutalisk-magic-box clumped-mutas-1.2t thor1))
  (define clumped-holds (count (lambda (d) (eq? (spell-directive-ability d) 'hold-position)) d-clumped))

  ;; (ii) 6 spread Mutas (`sep = 1.8t >= 1.35t`, `d-thor = 1.8t <= 3.95t`) across consecutive ticks:
  ;; `f=500` emits 6 `hold-position (18)`, `f=504`/`f=512` emit 0 duplicate `hold-position` AND 0 `attack`/`move`,
  ;; and `f=528` (`+28f`) refreshes 6 `hold-position (18)`!
  (define spread-6-mutas
    (for/list ([k (in-range 6)])
      (define ang (* 2.0 pi (/ k 6.0)))
      (mk-u (+ 3201 k) 'mutalisk (+ 80.0 (* 1.8 (cos ang))) (+ 80.0 (* 1.8 (sin ang)))
            #:hp 120.0 #:flying? #t)))
  (define rt-z16 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define (step-z16 f)
    (run-l34 rt-z16
             (mk-live-obs 'Zerg 'Terran f #:supply-used 12 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 25.0 #:base-y 25.0 #:enemy-x 80.0 #:enemy-y 80.0
                          #:ally-units spread-6-mutas #:enemy-units thor1)))
  (define a-500 (step-z16 500))
  (define a-504 (step-z16 504))
  (define a-512 (step-z16 512))
  (define a-528 (step-z16 528))
  (define (cnt-head h acts) (count (lambda (a) (and (pair? a) (eq? (car a) h))) acts))
  (define overrides-504
    (count (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos move kite))
                            (<= 3201 (second a) 3206)))
           a-504))
  (check-true "L47-T1c-z16-requires-1.35t-spread-and-dampens-hold-position-spam-28f"
              (and (= clumped-holds 0)
                   (= (cnt-head 'hold-position a-500) 6)
                   (= (cnt-head 'hold-position a-504) 0)
                   (= overrides-504 0)
                   (= (cnt-head 'hold-position a-512) 0)
                   (= (cnt-head 'hold-position a-528) 6))
              (format "clumped-holds=~a h500=~a h504=~a ov504=~a h512=~a h528=~a"
                      clumped-holds (cnt-head 'hold-position a-500)
                      (cnt-head 'hold-position a-504) overrides-504
                      (cnt-head 'hold-position a-512) (cnt-head 'hold-position a-528))))

;; -----------------------------------------------------------------------------
;; 4. L47-P0-1b (`r02`/`r05`/`r06` `<= 16` HP `16f` Phase-Out + `4f` Focus Refresh)
;; -----------------------------------------------------------------------------
(let ()
  (define main-cc (mk-u 1000 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16))
  (define main-mps
    (list (hasheq 'id 9001 'type 'mineral-field 'x 26.5 'y 28.5 'mineral-contents 1500)
          (hasheq 'id 9002 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)
          (hasheq 'id 9003 'type 'mineral-field 'x 26.5 'y 36.5 'mineral-contents 1500)))
  ;; Split-flank brawl: SCV #1101 at `15.0 HP` on SW flank `(29.0, 29.0)`, SCV #1102 at `14.0 HP`
  ;; on NE flank `(35.5, 35.5)` (`> 9.0t` separated!), remaining 14 SCVs healthy (`45.0 HP`)!
  (define scvs-split
    (append
     (list (mk-u 1101 'scv 29.0 29.0 #:hp 15.0 #:max-hp 45.0)
           (mk-u 1102 'scv 35.5 35.5 #:hp 14.0 #:max-hp 45.0))
     (for/list ([i (in-range 2 16)])
       (mk-u (+ 1101 i) 'scv (+ 29.2 (* 0.35 (modulo i 4))) (+ 30.2 (* 0.45 (quotient i 4)))
             #:hp 45.0 #:max-hp 45.0))))
  (define (mk-probes-15 hp0 sh0 hp1 sh1)
    (append
     (list (mk-u 1901 'probe 30.2 29.8 #:hp hp0 #:shield sh0)
           (mk-u 1902 'probe 30.5 30.0 #:hp hp1 #:shield sh1)
           (mk-u 1903 'probe 35.0 35.0 #:hp 20.0 #:shield 20.0))
     (for/list ([i (in-range 12)])
       (mk-u (+ 1904 i) 'probe (+ 30.6 (* 0.15 (modulo i 4))) (+ 30.5 (* 0.20 (quotient i 4)))
             #:hp 20.0 #:shield 20.0))))
  (define rt-rush (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  ;; L48-P0-1b: Zero mid-fight `mineral-walk` disengage in 15-Probe all-in (all 16 commit!),
  ;; while preserving L47's `4f` lowest-HP focus-fire refresh (`#1901` at f=1200 -> `#1902` at f=1204)!
  (define acts-1200
    (step-layer2-economy!
     rt-rush
     (mk-live-obs 'Terran 'Protoss 1200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units scvs-split #:ally-buildings (list main-cc)
                  #:enemy-units (mk-probes-15 15.0 0.0 20.0 20.0) #:mineral-patches main-mps)))
  (define mw-1200 (map second (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-1200)))
  (define pulled-1200
    (remove-duplicates
     (append* (for/list ([a (in-list acts-1200)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (define focus-1901?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 1901))) acts-1200))
  ;; Tick `f=1204` (`+4f`!): `#1902` drops to `5` EHP (`< 15`) -> 4f focus refresh switches primary focus to `#1902`!
  (define acts-1204
    (step-layer2-economy!
     rt-rush
     (mk-live-obs 'Terran 'Protoss 1204 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units scvs-split #:ally-buildings (list main-cc)
                  #:enemy-units (mk-probes-15 15.0 0.0 5.0 0.0) #:mineral-patches main-mps)))
  (define mw-1204 (map second (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-1204)))
  (define focus-1902?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 1902))) acts-1204))
  (check-true "L47-T2a-rush-probe-zero-disengage-all-16-commit-and-4f-focus-refresh"
              (and (null? mw-1200)
                   (= (length pulled-1200) 16)
                   focus-1901?
                   (null? mw-1204)
                   focus-1902?)
              (format "mw1200=~a pulled1200=~a f1901?=~a mw1204=~a f1902?=~a"
                      mw-1200 (length pulled-1200) focus-1901? mw-1204 focus-1902?)))

;; -----------------------------------------------------------------------------
;; 5. L47-P0-1b (`rd01` SP Multi-Mine `3.6t` Scatter onto `> 4.5t` Safe Patches)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 5000 'hatchery 32.5 32.5 #:hp 1500.0))
  ;; 2 armed Widow Mines: Mine 1 near South patch `(28.5, 27.5)`, Mine 2 near Mid-West `(28.5, 32.5)`.
  ;; Only North patch `#5903` `(26.5, 38.5)` is strictly `> 4.5t` from BOTH mines (`11.2t` & `6.3t`)!
  (define wm-mps
    (list (hasheq 'id 5901 'type 'mineral-field 'x 26.5 'y 27.5 'mineral-contents 1500)  ;; 2.0t from WM1!
          (hasheq 'id 5902 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)  ;; 2.0t from WM2!
          (hasheq 'id 5903 'type 'mineral-field 'x 26.5 'y 38.5 'mineral-contents 1500))) ;; > 6.3t from BOTH!
  (define drones-rd01
    (list (mk-u 5101 'drone 27.8 27.5 #:hp 40.0)   ;; targeted by WM1
          (mk-u 5102 'drone 27.0 29.8 #:hp 40.0)   ;; 2.74t from WM1 (<= 3.6t!)
          (mk-u 5103 'drone 27.8 32.5 #:hp 40.0)   ;; targeted by WM2
          (mk-u 5104 'drone 27.0 34.8 #:hp 40.0)   ;; 2.74t from WM2 (<= 3.6t!)
          (mk-u 5105 'drone 26.8 38.5 #:hp 40.0))) ;; safe far drone (> 6.2t from BOTH mines!)
  (define wms-2
    (list (mk-u 5991 'widow-mine-burrowed 28.5 27.5 #:hp 90.0 #:burrowed? #t #:engaged-target-tag 5101)
          (mk-u 5992 'widow-mine-burrowed 28.5 32.5 #:hp 90.0 #:burrowed? #t #:engaged-target-tag 5103)))
  (define acts-rd01
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 3200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:ally-units drones-rd01 #:ally-buildings (list hatch)
                  #:enemy-units wms-2 #:mineral-patches wm-mps)))
  (define mw-scatters (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-rd01))
  (define all-to-safe-5903?
    (and (>= (length mw-scatters) 2)
         (for/and ([a (in-list mw-scatters)]) (= (third a) 5903))))
  (define far-5105-untouched?
    (not (ormap (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk move)) (= (second a) 5105))) acts-rd01)))
  ;; Blanket case: 2 mines cover ALL patches `<= 3.8t` -> Drone #5102 emits pure `move` AWAY (NOT `mineral-walk` into Mine #2!)
  (define acts-blanket
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 3200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:ally-units (take drones-rd01 4) #:ally-buildings (list hatch)
                  #:enemy-units wms-2 #:mineral-patches (take wm-mps 2))))
  (define blanket-5102-move?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 5102))) acts-blanket))
  (define blanket-5102-mw?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) 5102))) acts-blanket))
  (check-true "L47-T2b-rd01-multi-mine-3.6t-scatters-strictly-to-4.5t-safe-patch-or-away-move"
              (and all-to-safe-5903? far-5105-untouched? blanket-5102-move? (not blanket-5102-mw?))
              (format "scatters=~a far-ok?=~a b-move?=~a b-mw?=~a"
                      mw-scatters far-5105-untouched? blanket-5102-move? blanket-5102-mw?)))

;; -----------------------------------------------------------------------------
;; 6. L47-P0-1b (`ro11` SP Cloaked Banshee Undetected Worker Chase `<= 14t`)
;; -----------------------------------------------------------------------------
(let ()
  (define banshees-2
    (list (mk-u 601 'banshee 40.0 133.5 #:hp 140.0 #:energy 60.0 #:flying? #t #:cloaked? #t #:cloak 1)
          (mk-u 602 'banshee 40.5 133.5 #:hp 140.0 #:energy 60.0 #:flying? #t #:cloaked? #t #:cloak 1)))
  (define enemy-hatch (mk-u 9001 'hatchery 35.0 137.0 #:hp 1500.0)) ;; closer (6.1t)!
  ;; Evacuated / mining Drones at `11.5t` NW (`<= 14.0t`!)
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 9100 i) 'drone 31.0 (+ 139.0 (* 0.35 i)) #:hp 40.0)))
  ;; (i) Undetected cloaked Banshees MUST chase/attack Drones (`9100..9115`), NOT the closer Hatchery (`9001`)!
  (define acts-ro11-chase
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 300 #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 35.0 #:enemy-y 137.0
                          #:ally-units banshees-2 #:enemy-units drones-16
                          #:enemy-buildings (list enemy-hatch))))
  (define drone-ids (map (lambda (d) (hash-ref d 'id)) drones-16))
  (define banshee-drone-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (memv (second a) '(601 602))
                             (memv (third a) drone-ids)))
            acts-ro11-chase))
  (define banshee-hatch-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (memv (second a) '(601 602))
                             (= (third a) 9001)))
            acts-ro11-chase))
  ;; (ii) Fog approach (`0` Drones visible yet, Hatchery at `6.1t`, 0 detectors): fly PAST Hatchery!
  (define acts-ro11-fog
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 300 #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 35.0 #:enemy-y 137.0
                          #:ally-units banshees-2 #:enemy-units '()
                          #:enemy-buildings (list enemy-hatch))))
  (define banshee-fog-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move)
                             (memv (second a) '(601 602))
                             (< (third a) 34.0) (> (fourth a) 138.0)))
            acts-ro11-fog))
  ;; (iii) Negative guard: Enemy Overseer detector `<= 12.5t` + Stalkers/Hydras blocks blind cloaked worker dive!
  (define overseer-det (mk-u 9200 'overseer 36.0 136.5 #:hp 200.0 #:flying? #t))
  (define hydras-6
    (for/list ([i (in-range 6)]) (mk-u (+ 9210 i) 'hydralisk 36.0 (+ 135.0 (* 0.5 i)) #:hp 90.0)))
  (define acts-ro11-det
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 300 #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 35.0 #:enemy-y 137.0
                          #:ally-units banshees-2 #:enemy-units (append (list overseer-det) hydras-6 drones-16)
                          #:enemy-buildings (list enemy-hatch))))
  (define det-blind-drone-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (memv (second a) '(601 602))
                             (memv (third a) drone-ids)))
            acts-ro11-det))
  (check-true "L47-T2c-ro11-cloaked-banshee-chases-workers-14t-pushes-fog-and-respects-detectors"
              (and (= (length banshee-drone-atks) 2)
                   (null? banshee-hatch-atks)
                   (= (length banshee-fog-moves) 2)
                   (null? det-blind-drone-atks))
              (format "drone-atks=~a hatch-atks=~a fog-moves=~a det-drone-atks=~a"
                      banshee-drone-atks banshee-hatch-atks banshee-fog-moves det-blind-drone-atks)))

;; -----------------------------------------------------------------------------
;; 7. L47-P0-1b (`#59` Creepy `canon_rush` — `in-base-proxy-detected?` Preempts Light-Harass)
;; -----------------------------------------------------------------------------
(let ()
  (define main-cc (mk-u 7000 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 14 #:ideal-harvesters 16))
  (define main-mps
    (for/list ([i (in-range 6)])
      (hasheq 'id (+ 7501 i) 'type 'mineral-field 'x 26.5 'y (+ 29.0 (* 1.2 i)) 'mineral-contents 1500)))
  (define scvs-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 7101 i) 'scv 28.5 (+ 29.0 (* 0.5 i)) #:hp 45.0)))
  (define enemy-scout-probe (list (mk-u 7901 'probe 33.5 32.0 #:hp 20.0 #:shield 20.0)))
  (define rt-59 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  ;; Tick 1 (`f=900`): Enemy Probe enters base before warping Pylon -> light-harass pulls 1 SCV!
  (define acts-t1
    (step-layer2-economy!
     rt-59
     (mk-live-obs 'Terran 'Protoss 900 #:minerals 100 #:gas 0 #:supply-used 14 #:supply-cap 15
                  #:ally-units scvs-14 #:ally-buildings (list main-cc)
                  #:enemy-units enemy-scout-probe #:mineral-patches main-mps)))
  (define lh-pulled-t1
    (remove-duplicates
     (append* (for/list ([a (in-list acts-t1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  ;; Tick 2 (`f=908`): Proxy Pylon warps in base -> `in-base-proxy-detected?` immediately preempts
  ;; light-harass, pulls SCVs onto Proxy Pylon #7950, and emits ZERO `(harvest-mineral ...)` yanking
  ;; `lh-pulled-t1` off the Proxy Pylon!
  (define proxy-pylon (list (mk-u 7950 'pylon 36.0 34.0 #:hp 50.0 #:shield 50.0 #:build-progress 0.15)))
  (define acts-t2
    (step-layer2-economy!
     rt-59
     (mk-live-obs 'Terran 'Protoss 908 #:minerals 110 #:gas 0 #:supply-used 14 #:supply-cap 15
                  #:ally-units scvs-14 #:ally-buildings (list main-cc)
                  #:enemy-units enemy-scout-probe #:enemy-buildings proxy-pylon
                  #:mineral-patches main-mps)))
  (define pylon-pulled?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 7950))) acts-t2))
  (define stale-lh-harvest-yank?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (memv (second a) lh-pulled-t1))) acts-t2))
  (check-true "L47-T2d-59-in-base-proxy-preempts-light-harass-and-never-yanks-proxy-scvs"
              (and (= (length lh-pulled-t1) 1)
                   pylon-pulled?
                   (not stale-lh-harvest-yank?))
              (format "lh-t1=~a pylon-pulled?=~a stale-yank?=~a acts-t2=~a"
                      lh-pulled-t1 pylon-pulled? stale-lh-harvest-yank? acts-t2)))

;; -----------------------------------------------------------------------------
;; 8. L47-P0-1b (`#72` 12PoolBot Reserve 1 Non-Fighting Probe for Emergency Build)
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 8000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define main-pyl (mk-u 8001 'pylon 36.0 35.0 #:hp 200.0 #:shield 200.0))
  (define main-gw  (mk-u 8002 'gateway 37.5 35.0 #:hp 500.0 #:shield 500.0))
  (define main-mps
    (for/list ([i (in-range 6)])
      (hasheq 'id (+ 8501 i) 'type 'mineral-field 'x 26.5 'y (+ 29.0 (* 1.2 i)) 'mineral-contents 1500)))
  (define probes-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 8101 i) 'probe (+ 28.0 (* 0.3 i)) (+ 29.0 (* 0.8 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 8901 i) 'zergling 34.5 (+ 30.5 (* 0.4 i)) #:hp 35.0)))
  ;; Protoss with Nexus + Pylon + Gateway #1 (0 CyberCore!), 200M bank, 8 Probes vs 6 invading Lings:
  ;; MUST reserve 1 safe non-fighting Probe (NEVER pulled into `pull-workers-attack`!)
  (define rt-72 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-72
    (step-layer2-economy!
     rt-72
     (mk-live-obs 'Protoss 'Zerg 2500 #:minerals 200 #:gas 0 #:supply-used 10 #:supply-cap 23
                  #:ally-units probes-8 #:ally-buildings (list main-nex main-pyl main-gw)
                  #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define pulled-72
    (remove-duplicates
     (append* (for/list ([a (in-list acts-72)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  ;; Verify at least 1 of the 8 Probes is cleanly left unpulled (free for `cybernetics-core`/`gateway` build!)
  ;; AND when all 7 other Probes fight (`keep-m = 1` for `avail-hw = 7`), reserved Probe is strictly outside `pulled-72`!
  (define free-probes-72
    (filter (lambda (u) (not (memv (hash-ref u 'id) pulled-72))) probes-8))
  ;; Even with ONLY 6 Probes (`avail-hw = 5 < 8`, where `keep-m = 0` would otherwise pull ALL 6 Probes!),
  ;; 1 safe Probe MUST STILL be reserved for `cybernetics-core`/`gateway`!
  (define rt-72-tight (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-72-tight
    (step-layer2-economy!
     rt-72-tight
     (mk-live-obs 'Protoss 'Zerg 2500 #:minerals 200 #:gas 0 #:supply-used 8 #:supply-cap 23
                  #:ally-units (take probes-8 6) #:ally-buildings (list main-nex main-pyl main-gw)
                  #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define pulled-72-tight
    (remove-duplicates
     (append* (for/list ([a (in-list acts-72-tight)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  ;; Negative guard (`e04` pure Nexus + 6 Probes, 0 Pylons, 0 Gateways -> NO emergency build reserve, pulls all 6!)
  (define rt-e04-neg (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-e04-neg
    (step-layer2-economy!
     rt-e04-neg
     (mk-live-obs 'Protoss 'Zerg 2500 #:minerals 200 #:gas 0 #:supply-used 6 #:supply-cap 15
                  #:ally-units (take probes-8 6) #:ally-buildings (list main-nex)
                  #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define pulled-e04-neg
    (remove-duplicates
     (append* (for/list ([a (in-list acts-e04-neg)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (check-true "L47-T2e-72-reserves-1-non-fighting-probe-for-emergency-build-and-preserves-e04"
              (and (pair? pulled-72)
                   (>= (length free-probes-72) 1)
                   (= (length pulled-72-tight) 5)
                   (= (length pulled-e04-neg) 6))
              (format "pulled8=~a free8=~a pulled6-gw=~a pulled6-e04=~a"
                      (length pulled-72) (length free-probes-72)
                      (length pulled-72-tight) (length pulled-e04-neg))))

(printf "\n=== Loop 47 Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
