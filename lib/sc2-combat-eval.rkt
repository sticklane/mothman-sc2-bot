#lang typed/racket/base

;; =============================================================================
;; `lib/sc2-combat-eval.rkt`
;; StarCraft II LotV Strategic & Combat Evaluation Engine (Typed Racket):
;;   1. Lanchester Snowball Advantage & Compounding Economic/Military Ledger
;;   2. Bot Personalities & Doctrine Loadouts
;;   3. Plausible Counter Trees, Switching Cost & Demand-Pull Resolution
;;   4. Double-Reaction Tactical Loop State (`mastermind-state`)
;;   5. Refractory Ability Cast Limiter (`ability-cast-limiter`)
;;   6. PDA (Perception -> Decision -> Action) Diagnostic Triangulation
;;   7. Typed Combat Measure & DPS Force Splitting (`split-combat-units-by-dps`)
;;   8. FAP Combat Simulator, Focus-Fire Scoring, Hysteresis & Kite/Retreat Vectors
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/set
         racket/fixnum
         racket/flonum
         typed/racket/unsafe
         "sc2-types.rkt"
         "sc2-game-constants.rkt"
         (only-in "sc2-pathing.rkt"
                  compute-concave-arc)
         (only-in "perception-grid.rkt"
                  struct:combat-measure
                  combat-measure
                  combat-measure?
                  combat-measure-count
                  combat-measure-dps
                  combat-measure-hp
                  combat-measure-cost))

;; Local untyped hash accessor bridge so heterogeneous SC2 unit hashes cross
;; the Typed/Untyped boundary without hash/c chaperone failures.
(module dyn-hash-ops racket/base
  (provide dyn-hash-ref
           dyn-hash-has-key?)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (hash-ref h k (lambda () default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)])

(provide
 ;; 1. Lanchester Snowball & Compounding Ledger
 lanchester-snowball-advantage
 evaluate-compounding-ledger

 ;; 2. Bot Personalities & Doctrine Loadouts
 (struct-out bot-personality)
 def-bot-personality
 MARV-MACRO-OPEN-PERSONALITY
 SCARLETT-CREEP-SWARM-PERSONALITY
 CLEM-TEMPO-MULTITASK-PERSONALITY
 (struct-out doctrine-loadout)
 set-doctrine-loadout-name!
 set-doctrine-loadout-primary-personality!
 set-doctrine-loadout-fallback-personality!
 set-doctrine-loadout-crisis-personality!
 set-doctrine-loadout-active!
 def-doctrine-loadout
 step-doctrine-loadout!

 ;; 3. Plausible Counter Trees, Switching Cost & Demand-Pull
 (struct-out counter-branch)
 (struct-out plausible-counter-tree)
 def-plausible-counter-tree
 ZERG-COUNTER-TREE
 PROTOSS-COUNTER-TREE
 TERRAN-COUNTER-TREE
 get-race-counter-tree
 classify-enemy-archetype
 compute-switching-cost
 resolve-demand-pull

 ;; 4. Double-Reaction Tactical Loop
 (struct-out mastermind-state)
 make-mastermind-state
 step-double-reaction!

 ;; 5. Refractory Ability Cast Limiter
 MACRO-EXEMPT-SPELLS
 (struct-out ability-cast-limiter)
 make-ability-cast-limiter
 throttle-ability-casts!

 ;; 6. PDA Diagnostic Triangulation
 (struct-out pda-trace)
 make-pda-trace
 diagnose-bot-anomaly

 ;; 7. Typed Combat Measure & DPS Splitting
 (struct-out combat-measure)
 measure-zero
 measure-plus
 combat-unit->measure
 measure-combat-units
 split-combat-units-by-dps

 ;; 8. Typed FAP Evaluator, Focus-Fire Scoring & Tactical Vectors
 (struct-out fap-unit)
 make-fap-unit
 ally-squad-has-stealth-unit?
 sc2-target-priority-multiplier
 score-focus-fire-priority
 score-arena-focus-target
 select-focus-fire-target
 fap-simulate-combat
 fap-evaluate-engagement
 fap-posture-with-hysteresis
 purplewave-traffic-retreat
 compute-kite-vector
 compute-concave-arc

 ;; 9. LotV Attribute Bitmasks, Collision Radii, Exact Weapon-vs-Armor & Spell Gates
 SC2-UNIT-ATTR-LIGHT
 SC2-UNIT-ATTR-ARMORED
 SC2-UNIT-ATTR-BIOLOGICAL
 SC2-UNIT-ATTR-MECHANICAL
 SC2-UNIT-ATTR-PSIONIC
 SC2-UNIT-ATTR-MASSIVE
 SC2-UNIT-ATTR-SHIELDED
 SC2-UNIT-ATTR-FRENZIED
 SC2-UNIT-ATTR-STRUCTURE
 SC2-UNIT-ATTR-HEROIC
 canonical-unit-type-sym
 unit-attribute-mask
 unit-collision-radius
 aoe-radius-packing-multiplier
 unit-primary-bonus-attr-mask
 compute-exact-hit-damage-vs-target/fast
 compute-exact-hit-damage-vs-target
 compute-exact-weapon-dps-vs-target
 spell-valid-for-target-attrs?
 predict-engagement-outcome)

;; =============================================================================
;; Internal Safe Numeric & Extraction Helpers
;; =============================================================================

(: real-expt-nonneg (-> Real Real Flonum))
(define (real-expt-nonneg base power)
  (define b (->float (max 0.0 (safe-finite-real base 0.0))))
  (define p (->float (safe-finite-real power 1.0)))
  (define r (expt b p))
  (if (and (real? r) (finite-real? r))
      (->float r)
      0.0))

(: symbol-or-default (-> Any Symbol Symbol))
(define (symbol-or-default v default)
  (if (symbol? v) v default))

;; =============================================================================
;; 1. Lanchester Snowball Advantage & Compounding Ledger
;; =============================================================================

;; Generalized Lanchester exponent = 1.7 for ranged/mixed SC2 combat
(: lanchester-snowball-advantage
   (->* (Any Any)
        (#:self-efficiency Real #:enemy-efficiency Real #:exponent Real)
        Flonum))
(define (lanchester-snowball-advantage self-army-value enemy-army-value
                                       #:self-efficiency [alpha-s 1.0]
                                       #:enemy-efficiency [alpha-e 1.0]
                                       #:exponent [exp-k 1.7])
  (define a-s (->float (safe-finite-real alpha-s 1.0)))
  (define a-e (->float (safe-finite-real alpha-e 1.0)))
  (define s-term (* a-s (real-expt-nonneg (safe-finite-real self-army-value 0.0) exp-k)))
  (define e-term (* a-e (real-expt-nonneg (safe-finite-real enemy-army-value 0.0) exp-k)))
  (- s-term e-term))

(: evaluate-compounding-ledger
   (->* ()
        (#:self-workers Any
         #:enemy-workers Any
         #:self-army Any
         #:enemy-army Any
         #:self-bases Any
         #:enemy-bases Any
         #:fap-score Any)
        (Immutable-HashTable Symbol Any)))
(define (evaluate-compounding-ledger #:self-workers [self-workers 16]
                                     #:enemy-workers [enemy-workers 16]
                                     #:self-army [self-army 200]
                                     #:enemy-army [enemy-army 200]
                                     #:self-bases [self-bases 1]
                                     #:enemy-bases [enemy-bases 1]
                                     #:fap-score [fap-score 0])
  (define sw (safe-exact-int self-workers 16))
  (define ew (safe-exact-int enemy-workers 16))
  (define sa (safe-finite-real self-army 200.0))
  (define ea (safe-finite-real enemy-army 200.0))
  (define sb (safe-exact-int self-bases 1))
  (define eb (safe-exact-int enemy-bases 1))
  (define fs (safe-exact-int fap-score 0))
  (define worker-delta (- sw ew))
  (define base-delta (- sb eb))
  (define lanchester-delta (lanchester-snowball-advantage sa ea))
  (define dominant-driver : Symbol
    (cond
      [(> base-delta 0) 'economic-compounding-snowball]
      [(> worker-delta 1) 'worker-cycle-compound-lead]
      [(and (> sw 12) (>= sa ea) (> sa 0.0))
       'worker-cycle-compound-lead]
      [(not (= sa ea)) 'lanchester-army-critical-mass]
      [(= fs 0) 'lanchester-army-critical-mass]
      [else 'neutral-parity]))
  (define directive : Symbol
    (cond
      [(< fs -15) 'retreat-and-regroup]
      [(> fs 35)  'press-attack]
      [(or (> sa 100.0) (> sw 14)) 'probe-poke]
      [else 'hold-macro-neutral]))
  ((inst hash Symbol Any)
   'dominant-driver dominant-driver
   'worker-delta worker-delta
   'base-delta base-delta
   'lanchester-delta lanchester-delta
   'net-score (+ (* 25 worker-delta) (* 150 base-delta) fs)
   'recommended-directive directive))

;; Local untyped submodule defining personality/loadout/counter-tree structs
;; and `def-*` syntax-rule macros so untyped callers (e.g., tests & runtime)
;; can invoke `def-doctrine-loadout` etc. without TR macro-boundary errors.
(module core-doctrine-macros racket/base
  (provide (struct-out bot-personality)
           def-bot-personality
           (struct-out doctrine-loadout)
           def-doctrine-loadout
           (struct-out counter-branch)
           (struct-out plausible-counter-tree)
           def-plausible-counter-tree)

  (struct bot-personality
    (name race aggression econ-greed creep-weight drop-frequency flank-bias)
    #:transparent)

  (define-syntax-rule (def-bot-personality id
                        #:race race
                        #:aggression aggr
                        #:econ-greed greed
                        #:creep-weight creep
                        #:drop-frequency drop
                        #:flank-bias flank)
    (define id
      (bot-personality 'id 'race aggr greed creep drop flank)))

  (struct doctrine-loadout
    (name primary-personality fallback-personality crisis-personality active)
    #:mutable
    #:transparent)

  (define-syntax-rule (def-doctrine-loadout id
                        #:primary p1
                        #:fallback p2
                        #:crisis p3)
    (define id
      (doctrine-loadout 'id p1 p2 p3 p1)))

  (struct counter-branch
    (archetype primary-unit fallback-unit required-buildings tech-cost)
    #:transparent)

  (struct plausible-counter-tree
    (name race default-unit branches)
    #:transparent)

  (define-syntax-rule (def-plausible-counter-tree id
                        #:race race
                        #:default default-u
                        [arch prim fall reqs cost] ...)
    (define id
      (plausible-counter-tree
       'id
       'race
       'default-u
       (list (counter-branch 'arch 'prim 'fall 'reqs cost) ...)))))

(require (only-in (submod "." core-doctrine-macros)
                  def-bot-personality
                  def-doctrine-loadout
                  def-plausible-counter-tree))

(unsafe-require/typed (submod "." core-doctrine-macros)
  [#:struct bot-personality
   ([name : Symbol]
    [race : Symbol]
    [aggression : Real]
    [econ-greed : Real]
    [creep-weight : Real]
    [drop-frequency : Real]
    [flank-bias : Real])]
  [#:struct doctrine-loadout
   ([name : Symbol]
    [primary-personality : bot-personality]
    [fallback-personality : bot-personality]
    [crisis-personality : bot-personality]
    [active : bot-personality])]
  [set-doctrine-loadout-name! (-> doctrine-loadout Symbol Void)]
  [set-doctrine-loadout-primary-personality! (-> doctrine-loadout bot-personality Void)]
  [set-doctrine-loadout-fallback-personality! (-> doctrine-loadout bot-personality Void)]
  [set-doctrine-loadout-crisis-personality! (-> doctrine-loadout bot-personality Void)]
  [set-doctrine-loadout-active! (-> doctrine-loadout bot-personality Void)]
  [#:struct counter-branch
   ([archetype : Symbol]
    [primary-unit : Symbol]
    [fallback-unit : Symbol]
    [required-buildings : (Listof Symbol)]
    [tech-cost : Real])]
  [#:struct plausible-counter-tree
   ([name : Symbol]
    [race : Symbol]
    [default-unit : Symbol]
    [branches : (Listof counter-branch)])])

;; =============================================================================
;; 2. Bot Personalities & Doctrine Loadouts
;; =============================================================================

(: MARV-MACRO-OPEN-PERSONALITY bot-personality)
(define MARV-MACRO-OPEN-PERSONALITY
  (bot-personality 'MARV-MACRO-OPEN-PERSONALITY 'Protoss 0.58 0.85 0.10 0.65 0.72))

(: SCARLETT-CREEP-SWARM-PERSONALITY bot-personality)
(define SCARLETT-CREEP-SWARM-PERSONALITY
  (bot-personality 'SCARLETT-CREEP-SWARM-PERSONALITY 'Zerg 0.74 0.82 0.95 0.45 0.88))

(: CLEM-TEMPO-MULTITASK-PERSONALITY bot-personality)
(define CLEM-TEMPO-MULTITASK-PERSONALITY
  (bot-personality 'CLEM-TEMPO-MULTITASK-PERSONALITY 'Terran 0.86 0.70 0.20 0.92 0.84))

(: step-doctrine-loadout!
   (->* (doctrine-loadout) (#:fap-score Real #:under-rush? Any) bot-personality))
(define (step-doctrine-loadout! loadout #:fap-score [fap 0] #:under-rush? [rush? #f])
  (define f (safe-finite-real fap 0.0))
  (define chosen : bot-personality
    (cond
      [rush? (doctrine-loadout-crisis-personality loadout)]
      [(< f -20.0) (doctrine-loadout-fallback-personality loadout)]
      [else (doctrine-loadout-primary-personality loadout)]))
  (set-doctrine-loadout-active! loadout chosen)
  chosen)

;; =============================================================================
;; 3. Plausible Counter Trees, Switching Cost & Demand-Pull
;; =============================================================================

(: ZERG-COUNTER-TREE plausible-counter-tree)
(define ZERG-COUNTER-TREE
  (plausible-counter-tree
   'ZERG-COUNTER-TREE
   'Zerg
   'zergling
   (list (counter-branch 'standard-macro   'roach     'zergling '(roach-warren)               150)
         (counter-branch 'bio-ball         'baneling  'hydralisk '(spawning-pool baneling-nest) 150)
         (counter-branch 'zealot-rush      'roach     'zergling '(roach-warren)               150)
         (counter-branch 'mech-siege       'ravager   'roach    '(roach-warren)               150)
         (counter-branch 'air-fleet        'corruptor 'hydralisk '(lair spire)                350)
         (counter-branch 'lurker-contain   'hydralisk 'ravager  '(lair hydralisk-den)         250)
         (counter-branch 'roach-ravager    'hydralisk 'roach    '(lair hydralisk-den)         250)
         (counter-branch 'ling-bane-hydra  'baneling  'roach    '(spawning-pool baneling-nest) 150)
         (counter-branch 'stalker-colossus 'hydralisk 'lurker   '(lair hydralisk-den)         250)
         (counter-branch 'sky-toss         'hydralisk 'corruptor '(lair hydralisk-den)        250)
         (counter-branch 'muta-flock       'hydralisk 'queen    '(lair hydralisk-den)         250)
         (counter-branch 'queen-infestor   'lurker    'ravager  '(lair hydralisk-den lurker-den) 350)
         (counter-branch 'early-rush       'roach     'zergling '(roach-warren)               150))))

(: PROTOSS-COUNTER-TREE plausible-counter-tree)
(define PROTOSS-COUNTER-TREE
  (plausible-counter-tree
   'PROTOSS-COUNTER-TREE
   'Protoss
   'zealot
   (list (counter-branch 'standard-macro   'zealot   'immortal '(gateway)                           150)
         (counter-branch 'zergling-flood   'zealot   'adept    '(gateway)                           150)
         (counter-branch 'roach-ravager    'immortal 'zealot   '(cybernetics-core robotics-facility) 350)
         (counter-branch 'lurker-contain   'immortal 'zealot   '(cybernetics-core robotics-facility) 350)
         (counter-branch 'bio-ball         'colossus 'stalker  '(robotics-facility robotics-bay)    500)
         (counter-branch 'air-fleet        'void-ray 'tempest  '(cybernetics-core stargate)         300)
         (counter-branch 'mech-siege       'immortal 'zealot   '(cybernetics-core robotics-facility) 350)
         (counter-branch 'stalker-colossus 'immortal 'zealot   '(cybernetics-core robotics-facility) 350)
         (counter-branch 'sky-toss         'void-ray 'tempest  '(cybernetics-core stargate)         300)
         (counter-branch 'muta-flock       'phoenix  'archon   '(cybernetics-core stargate)         300)
         (counter-branch 'queen-infestor   'archon   'colossus '(templar-archive)                   350)
         (counter-branch 'ling-bane-hydra  'colossus 'zealot   '(robotics-facility robotics-bay)    500)
         (counter-branch 'early-rush       'zealot   'stalker  '(gateway)                           150))))

(: TERRAN-COUNTER-TREE plausible-counter-tree)
(define TERRAN-COUNTER-TREE
  (plausible-counter-tree
   'TERRAN-COUNTER-TREE
   'Terran
   'marine
   (list (counter-branch 'standard-macro   'siege-tank 'marauder '(factory)          250)
         (counter-branch 'zergling-flood   'widow-mine 'hellion  '(factory)          200)
         (counter-branch 'roach-ravager    'marauder   'siege-tank '(barracks-techlab) 100)
         (counter-branch 'lurker-contain   'siege-tank 'marauder '(factory)          250)
         (counter-branch 'protoss-deathball 'marauder  'ghost    '(barracks-techlab ghost-academy) 200)
         (counter-branch 'air-fleet        'viking     'marine   '(starport)         250)
         (counter-branch 'bio-ball         'siege-tank 'marauder '(factory)          250)
         (counter-branch 'mech-siege       'siege-tank 'marauder '(factory)          250)
         (counter-branch 'stalker-colossus 'marauder   'ghost    '(barracks-techlab ghost-academy) 150)
         (counter-branch 'sky-toss         'viking     'marine   '(starport)         250)
         (counter-branch 'muta-flock       'thor       'marine   '(factory armory)   300)
         (counter-branch 'queen-infestor   'ghost      'liberator '(barracks ghost-academy) 250)
         (counter-branch 'ling-bane-hydra  'siege-tank 'hellion  '(factory)          250)
         (counter-branch 'early-rush       'marauder   'marine   '(barracks-techlab) 100))))

(: get-race-counter-tree (-> Any plausible-counter-tree))
(define (get-race-counter-tree race)
  (case race
    [(Zerg zerg)       ZERG-COUNTER-TREE]
    [(Protoss protoss) PROTOSS-COUNTER-TREE]
    [(Terran terran)   TERRAN-COUNTER-TREE]
    [else              ZERG-COUNTER-TREE]))

(: classify-enemy-archetype (-> Any Symbol))
(define (classify-enemy-archetype enemy-units)
  (define units : (Listof Any) (if (list? enemy-units) enemy-units '()))
  (define types : (Listof Symbol)
    (for/list : (Listof Symbol) ([e (in-list units)])
      (if (symbol? e)
          e
          (symbol-or-default (dyn-hash-ref e 'type 'unknown) 'unknown))))
  (define bio-cnt : Integer
    (count (lambda ([t : Symbol]) (not (not (memq t '(marine marauder medivac))))) types))
  (define cap-air-cnt : Integer
    (count (lambda ([t : Symbol])
             (not (not (memq t '(mutalisk void-ray voidray carrier tempest battlecruiser corruptor brood-lord broodlord)))))
           types))
  (define viking-cnt : Integer
    (count (lambda ([t : Symbol]) (not (not (memq t '(viking viking-fighter))))) types))
  (define queen-infestor-cnt : Integer
    (count (lambda ([t : Symbol]) (not (not (memq t '(queen infestor infestor-burrowed))))) types))
  (cond
    [(or (memq 'lurker types) (memq 'lurker-burrowed types) (memq 'lurker-mp-burrowed types))
     'lurker-contain]
    [(or (> cap-air-cnt 0)
         (and (> viking-cnt 0)
              (or (< bio-cnt 5) (>= viking-cnt 3))))
     'air-fleet]
    [(>= (count (lambda ([t : Symbol]) (eq? t 'zergling)) types) 6)
     'zergling-flood]
    [(or (memq 'infestor types) (memq 'infestor-burrowed types) (>= queen-infestor-cnt 4))
     'queen-infestor]
    [(or (memq 'siege-tank types) (memq 'siege-tank-sieged types)) 'mech-siege]
    [(or (memq 'roach types) (memq 'ravager types)) 'roach-ravager]
    [(>= bio-cnt 5)
     'bio-ball]
    [(or (memq 'oracle types) (memq 'phoenix types) (memq 'banshee types)
         (memq 'liberator types) (memq 'liberator-ag types))
     'sky-toss]
    [(or (memq 'colossus types) (memq 'immortal types) (memq 'archon types)
         (memq 'disruptor types) (memq 'high-templar types) (memq 'stalker types))
     'stalker-colossus]
    [(or (memq 'hellion types) (memq 'hellbat types) (memq 'cyclone types)
         (memq 'thor types) (memq 'widow-mine types))
     'mech-siege]
    [(or (memq 'hydralisk types) (memq 'baneling types))
     'ling-bane-hydra]
    [(or (memq 'marauder types) (memq 'reaper types) (memq 'ghost types) (memq 'marine types) (memq 'medivac types))
     'bio-ball]
    [(or (memq 'zealot types) (memq 'adept types) (memq 'sentry types) (memq 'dark-templar types))
     'stalker-colossus]
    [(memq 'zergling types)
     'ling-bane-hydra]
    [(memq 'queen types)
     'queen-infestor]
    [else 'standard-macro]))

(: normalize-mastermind-bldg-sym (-> Any Symbol))
(define (normalize-mastermind-bldg-sym sym)
  (define s : Symbol
    (cond
      [(symbol? sym) sym]
      [(hash? (cast sym Any)) (symbol-or-default (dyn-hash-ref sym 'type 'unknown) 'unknown)]
      [else 'unknown]))
  (case s
    [(robotics-support-bay) 'robotics-bay]
    [(templar-archives)     'templar-archive]
    [(warpgate)             'warp-gate]
    [else                   s]))

(: compute-switching-cost
   (->* ((Listof Symbol) Any)
        (#:available-minerals Any #:available-gas Any)
        (Immutable-HashTable Symbol Any)))
(define (compute-switching-cost required-buildings existing-buildings
                                #:available-minerals [minerals 300]
                                #:available-gas [gas 150])
  (define ex-list : (Listof Any) (if (list? existing-buildings) existing-buildings '()))
  (define existing-set : (Setof Symbol)
    (list->set (map normalize-mastermind-bldg-sym ex-list)))
  (define missing : (Listof Symbol)
    (filter (lambda ([b : Symbol])
              (not (set-member? existing-set (normalize-mastermind-bldg-sym b))))
            required-buildings))
  (define min-val (safe-finite-real minerals 300.0))
  (define gas-val (safe-finite-real gas 150.0))
  (define total-cost : Nonnegative-Integer (* 150 (length missing)))
  (define feasible? : Boolean
    (or (null? missing)
        (and (<= (length missing) 1)
             (>= (+ min-val gas-val) (->float total-cost)))))
  ((inst hash Symbol Any)
   'feasible? feasible?
   'missing-buildings missing
   'total-cost total-cost))

(: resolve-demand-pull
   (->* (plausible-counter-tree Any Any)
        (#:minerals Any #:gas Any)
        (Immutable-HashTable Symbol Any)))
(define (resolve-demand-pull tree enemy-archetype existing-buildings
                             #:minerals [minerals 300]
                             #:gas [gas 150])
  (define arch (symbol-or-default enemy-archetype 'standard-macro))
  (define branch : (Option counter-branch)
    (findf (lambda ([b : counter-branch]) (eq? (counter-branch-archetype b) arch))
           (plausible-counter-tree-branches tree)))
  (cond
    [(not branch)
     ((inst hash Symbol Any)
      'selected-unit (plausible-counter-tree-default-unit tree)
      'plausible? #t
      'switching-cost 0
      'missing-buildings '())]
    [else
     (define sc
       (compute-switching-cost (counter-branch-required-buildings branch)
                               existing-buildings
                               #:available-minerals minerals
                               #:available-gas gas))
     (define feasible? (and (hash-ref sc 'feasible? (lambda () #f)) #t))
     (define cost (hash-ref sc 'total-cost (lambda () 0)))
     (define missing (hash-ref sc 'missing-buildings (lambda () '())))
     (if feasible?
         ((inst hash Symbol Any)
          'selected-unit (counter-branch-primary-unit branch)
          'plausible? #t
          'switching-cost cost
          'missing-buildings missing)
         ((inst hash Symbol Any)
          'selected-unit (counter-branch-fallback-unit branch)
          'plausible? #t
          'fallback-used? #t
          'switching-cost cost
          'missing-buildings missing))]))

;; =============================================================================
;; 4. Double-Reaction Tactical Loop
;; =============================================================================

(struct mastermind-state
  ([race : Any]
   [personality : Any]
   [enemy-archetype : Symbol]
   [selected-unit : Symbol]
   [directive : Symbol]
   [double-reactions : Integer]
   [flank-angle-idx : Integer]
   [compounding-dominant : Symbol])
  #:mutable
  #:transparent)

(: make-mastermind-state (->* () (Any Any) mastermind-state))
(define (make-mastermind-state [race 'Zerg] [personality SCARLETT-CREEP-SWARM-PERSONALITY])
  (define init-unit : Symbol
    (case race
      [(Zerg zerg) 'zergling]
      [(Protoss protoss) 'zealot]
      [(Terran terran) 'marine]
      [else 'zergling]))
  (mastermind-state
   race
   personality
   'standard-macro
   init-unit
   'hold-macro-neutral
   0
   0
   'lanchester-army-critical-mass))

(: step-double-reaction!
   (->* (mastermind-state)
        (#:fap-score Any
         #:enemy-units Any
         #:ally-buildings Any
         #:self-workers Any
         #:enemy-workers Any
         #:self-army Any
         #:enemy-army Any)
        mastermind-state))
(define (step-double-reaction! mstate
                               #:fap-score [fap-score 0]
                               #:enemy-units [enemy-units '()]
                               #:ally-buildings [ally-buildings '()]
                               #:self-workers [self-workers 16]
                               #:enemy-workers [enemy-workers 16]
                               #:self-army [self-army 200]
                               #:enemy-army [enemy-army 200])
  (define fs (safe-exact-int fap-score 0))
  (define arch (classify-enemy-archetype enemy-units))
  (set-mastermind-state-enemy-archetype! mstate arch)
  (define tree (get-race-counter-tree (mastermind-state-race mstate)))
  (define pull (resolve-demand-pull tree arch ally-buildings))
  (set-mastermind-state-selected-unit!
   mstate
   (symbol-or-default (hash-ref pull 'selected-unit (lambda () 'zergling)) 'zergling))
  (define ledger
    (evaluate-compounding-ledger #:self-workers self-workers
                                 #:enemy-workers enemy-workers
                                 #:self-army self-army
                                 #:enemy-army enemy-army
                                 #:fap-score fs))
  (set-mastermind-state-compounding-dominant!
   mstate
   (symbol-or-default (hash-ref ledger 'dominant-driver (lambda () 'neutral-parity)) 'neutral-parity))
  ;; Double reaction triggers when fap-score < -15 OR enemy archetype is lurker-contain
  (cond
    [(or (< fs -15) (eq? arch 'lurker-contain))
     (set-mastermind-state-double-reactions!
      mstate (max 1 (mastermind-state-double-reactions mstate)))
     (set-mastermind-state-flank-angle-idx!
      mstate (max 1 (mastermind-state-flank-angle-idx mstate)))
     (set-mastermind-state-directive! mstate 'retreat-and-regroup)]
    [else
     (set-mastermind-state-directive!
      mstate
      (symbol-or-default (hash-ref ledger 'recommended-directive (lambda () 'hold-macro-neutral))
                         'hold-macro-neutral))])
  mstate)

;; =============================================================================
;; 5. Refractory Ability Cast Limiter
;; =============================================================================

(define MACRO-EXEMPT-SPELLS : (Listof Symbol)
  '(inject-larva
    calldown-mule
    chrono-boost
    spawn-creep-tumor
    spread-creep-tumor
    cancel))

(struct ability-cast-limiter
  ([max-combat-spells-per-frame : Integer]
   [refractory-frames : Integer]
   [last-cast-by-unit : (Mutable-HashTable Any Integer)]
   [throttled-count : Integer])
  #:mutable
  #:transparent)

(: make-ability-cast-limiter (->* () (#:max-per-frame Any #:refractory-frames Any) ability-cast-limiter))
(define (make-ability-cast-limiter #:max-per-frame [max-per-frame 1]
                                   #:refractory-frames [refractory-frames 24])
  (define tbl : (Mutable-HashTable Any Integer) (make-hash))
  (ability-cast-limiter (max 0 (safe-exact-int max-per-frame 1))
                        (max 0 (safe-exact-int refractory-frames 24))
                        tbl
                        0))

;; Filters action list so combat spells respect `max-combat-spells-per-frame`
;; and per-(caster-id . ability-sym) refractory cooldowns, while MACRO-EXEMPT-SPELLS pass unimpeded!
(: throttle-ability-casts! (->* (ability-cast-limiter Any) (Any) (Values (Listof Any) Nonnegative-Integer)))
(define (throttle-ability-casts! limiter actions [frame 0])
  (define fr (safe-exact-int frame 0))
  (define max-combat (ability-cast-limiter-max-combat-spells-per-frame limiter))
  (define refrac (ability-cast-limiter-refractory-frames limiter))
  (define unit-last (ability-cast-limiter-last-cast-by-unit limiter))
  (define combat-casts-this-frame : Nonnegative-Integer 0)
  (define throttled : Nonnegative-Integer 0)
  (: handle-cast (-> Any Any Boolean))
  (define (handle-cast caster-id spell)
    (cond
      [(and (symbol? spell) (memq spell MACRO-EXEMPT-SPELLS))
       #t]
      [else
       (define key : (Pair Any Any) (cons caster-id spell))
       (define prev-f : Integer (hash-ref unit-last key (lambda () -9999)))
       (cond
         [(and (< combat-casts-this-frame max-combat)
               (>= (- fr prev-f) refrac))
          (set! combat-casts-this-frame (add1 combat-casts-this-frame))
          (hash-set! unit-last key fr)
          #t]
         [else
          (set! throttled (add1 throttled))
          #f])]))
  (define action-list : (Listof Any) (if (list? actions) actions '()))
  (define kept : (Listof Any)
    (for/fold ([acc : (Listof Any) '()])
              ([act (in-list action-list)])
      (match act
        [(list (or 'cast 'cast-spell 'use-ability) caster-id spell _ ...)
         (if (handle-cast caster-id spell)
             (cons act acc)
             acc)]
        [(list 'inject-larva caster-id _ ...)
         (if (handle-cast caster-id 'inject-larva)
             (cons act acc)
             acc)]
        [_ (cons act acc)])))
  (set-ability-cast-limiter-throttled-count! limiter throttled)
  (values (reverse kept) throttled))

;; =============================================================================
;; 6. PDA (Perception -> Decision -> Action) Diagnostic Triangulation
;; =============================================================================

(struct pda-trace
  ([scouted-sectors : Integer]
   [posture-switches-window : Integer]
   [actions-emitted : Integer]
   [actions-throttled-or-dropped : Integer])
  #:transparent)

(: make-pda-trace
   (->* ()
        (#:scouted-sectors Any
         #:posture-switches Any
         #:actions-emitted Any
         #:actions-dropped Any)
        pda-trace))
(define (make-pda-trace #:scouted-sectors [scouted 8]
                        #:posture-switches [switches 1]
                        #:actions-emitted [emitted 10]
                        #:actions-dropped [dropped 0])
  (pda-trace (safe-exact-int scouted 8)
             (safe-exact-int switches 1)
             (safe-exact-int emitted 10)
             (safe-exact-int dropped 0)))

(: diagnose-bot-anomaly (-> pda-trace Symbol))
(define (diagnose-bot-anomaly trace)
  (cond
    [(<= (pda-trace-scouted-sectors trace) 0)
     'perception-blindspot]
    [(>= (pda-trace-posture-switches-window trace) 6)
     'decision-oscillation-thrash]
    [(and (> (pda-trace-actions-throttled-or-dropped trace) 8)
          (>= (pda-trace-actions-emitted trace) 20))
     'action-execution-failure]
    [else
     'healthy-pda-loop]))

;; =============================================================================
;; 7. Typed Combat Measure & DPS Splitting (`combat-measure` from perception-grid)
;; =============================================================================

(define measure-zero : combat-measure (combat-measure 0 0 0 0))

(: measure-plus (-> combat-measure combat-measure combat-measure))
(define (measure-plus m1 m2)
  (combat-measure
   (+ (combat-measure-count m1) (combat-measure-count m2))
   (+ (combat-measure-dps m1) (combat-measure-dps m2))
   (+ (combat-measure-hp m1) (combat-measure-hp m2))
   (+ (combat-measure-cost m1) (combat-measure-cost m2))))

;; =============================================================================
;; 8. Typed FAP Evaluator, Focus-Fire Scoring & Tactical Vectors
;; =============================================================================

(struct fap-unit
  ([id : Any]
   [hp : Real]
   [dps : Real]
   [armor : Real]
   [range : Real]
   [speed : Real]
   [cost : Real]
   [x : Real]
   [y : Real])
  #:mutable
  #:transparent)

(: make-fap-unit
   (->* (Any)
        (#:hp Real
         #:dps Real
         #:armor Real
         #:range Real
         #:speed Real
         #:cost Real
         #:x Real
         #:y Real)
        fap-unit))
(define (make-fap-unit id
                       #:hp [hp 45]
                       #:dps [dps 12]
                       #:armor [armor 0]
                       #:range [range 5]
                       #:speed [speed 4]
                       #:cost [cost 50]
                       #:x [x 32]
                       #:y [y 32])
  (fap-unit id hp dps armor range speed cost x y))

(: coerce-fap-unit (-> Any fap-unit))
(define (coerce-fap-unit u)
  (cond
    [(fap-unit? u)
     (fap-unit (fap-unit-id u)
               (fap-unit-hp u)
               (fap-unit-dps u)
               (fap-unit-armor u)
               (fap-unit-range u)
               (fap-unit-speed u)
               (fap-unit-cost u)
               (fap-unit-x u)
               (fap-unit-y u))]
    [(hash? u)
     (fap-unit (dyn-hash-ref u 'id 0)
               (safe-real (dyn-hash-ref u 'hp 45) 45)
               (safe-real (dyn-hash-ref u 'dps 12) 12)
               (safe-real (dyn-hash-ref u 'armor 0) 0)
               (safe-real (dyn-hash-ref u 'range 5) 5)
               (safe-real (dyn-hash-ref u 'speed 4) 4)
               (safe-real (dyn-hash-ref u 'cost 50) 50)
               (safe-real (dyn-hash-ref u 'x 32) 32)
               (safe-real (dyn-hash-ref u 'y 32) 32))]
    [else (make-fap-unit 0)]))

(: combat-unit->measure (-> Any combat-measure))
(define (combat-unit->measure u)
  (cond
    [(combat-measure? u) u]
    [(fap-unit? u)
     (combat-measure 1
                     (max 0.0 (safe-finite-real (fap-unit-dps u) 0.0))
                     (max 0.0 (safe-finite-real (fap-unit-hp u) 0.0))
                     (max 0.0 (safe-finite-real (fap-unit-cost u) 0.0)))]
    [(hash? u)
     (define utype (dyn-hash-ref u 'type 'marine))
     (define stats (sc2-unit-combat-stats utype))
     (define raw-dps (dyn-hash-ref u 'dps #f))
     (define dps : Float
       (if (and (real? raw-dps) (finite-real? raw-dps))
           (max 0.0 (->float raw-dps))
           (let ([gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 10.0)) 10.0)]
                 [adps (safe-finite-real (hash-ref stats 'air-dps (lambda () 0.0)) 0.0)])
             (max gdps adps))))
     (define raw-hp (dyn-hash-ref u 'hp #f))
     (define hp : Float
       (if (and (real? raw-hp) (finite-real? raw-hp))
           (max 0.0 (->float raw-hp))
           (safe-finite-real (hash-ref stats 'max-hp (lambda () 40.0)) 40.0)))
     (define raw-cost (dyn-hash-ref u 'cost #f))
     (define cost : Float
       (if (and (real? raw-cost) (finite-real? raw-cost))
           (max 0.0 (->float raw-cost))
           (->float (+ (sc2-min-cost utype 50) (sc2-gas-cost utype 0)))))
     (combat-measure 1 dps hp cost)]
    [else (combat-measure 1 10 40 50)]))

(: measure-combat-units (-> Any combat-measure))
(define (measure-combat-units units)
  (define unit-list : (Listof Any) (if (list? units) units '()))
  (for/fold ([acc : combat-measure measure-zero])
            ([u (in-list unit-list)])
    (measure-plus acc (combat-unit->measure u))))

;; Splits combat units in order into `(values vanguard reserve)` once cumulative
;; DPS reaches `target-dps` (or `(* ratio total-dps)` when `target-dps` is `#f`).
(: split-combat-units-by-dps
   (->* (Any) ((U Real False) #:ratio Real) (Values (Listof Any) (Listof Any))))
(define (split-combat-units-by-dps units [target-dps #f] #:ratio [ratio 0.70])
  (define unit-list : (Listof Any) (if (list? units) units '()))
  (define total-dps (combat-measure-dps (measure-combat-units unit-list)))
  (define cutoff : Float
    (if target-dps
        (->float (max 0.0 (safe-finite-real target-dps 0.0)))
        (->float (ceiling (* (clamp-real (safe-finite-real ratio 0.70) 0.0 1.0)
                             (->float total-dps))))))
  (cond
    [(or (null? unit-list) (<= cutoff 0.0))
     (values '() unit-list)]
    [(<= (->float total-dps) cutoff)
     (values unit-list '())]
    [else
     (let loop ([rest : (Listof Any) unit-list]
                [cum-dps : Float 0.0]
                [van-rev : (Listof Any) '()])
       (cond
         [(null? rest)
          (values (reverse van-rev) '())]
         [else
          (define u (car rest))
          (define udps (->float (combat-measure-dps (combat-unit->measure u))))
          (define next-dps (+ cum-dps udps))
          (define next-van (cons u van-rev))
          (if (>= next-dps cutoff)
              (values (reverse next-van) (cdr rest))
              (loop (cdr rest) next-dps next-van))]))]))

;; L43-P0-1a: Detect whether an allied combat squad contains cloaked or burrowed combat units
;; (Dark Templar, cloaked Banshee/Ghost, burrowed Lurker/Roach/WidowMine/Infestor/Baneling).
(: ally-squad-has-stealth-unit? (-> (Listof Any) Boolean))
(define (ally-squad-has-stealth-unit? ally-units)
  (for/or : Boolean ([u (in-list ally-units)])
    (and (hash? u)
         (let ([ut (symbol-or-default (dyn-hash-ref u 'type 'unknown) 'unknown)]
               [clk (dyn-hash-ref u 'cloak #f)])
           (not (not (or (eq? ut 'dark-templar)
                         (memq ut '(lurker-burrowed lurker-mp-burrowed roach-burrowed
                                    widow-mine-burrowed baneling-burrowed infestor-burrowed
                                    zergling-burrowed))
                         (and (memq ut '(banshee ghost lurker lurker-mp roach widow-mine))
                              (or (eq? (dyn-hash-ref u 'cloaked #f) #t)
                                  (eq? (dyn-hash-ref u 'burrowed #f) #t)
                                  (eq? (dyn-hash-ref u 'is-burrowed #f) #t)
                                  (eq? (dyn-hash-ref u 'burrowed? #f) #t)
                                  (eqv? clk 1) (eqv? clk 2)
                                  (eq? clk 'cloaked) (eq? clk 'cloaked-detected)))
                         (eq? (dyn-hash-ref u 'cloaked #f) #t)
                         (eq? (dyn-hash-ref u 'burrowed #f) #t)
                         (eq? (dyn-hash-ref u 'is-burrowed #f) #t)
                         (eq? (dyn-hash-ref u 'burrowed? #f) #t))))))))

(: RUNBY-WORKER-RAIDER-SYMS (Listof Symbol))
(define RUNBY-WORKER-RAIDER-SYMS
  '(hellion adept oracle banshee mutalisk zergling reaper dark-templar zealot))

(: WORKER-TARGET-SYMS (Listof Symbol))
(define WORKER-TARGET-SYMS '(scv probe drone mule))

;; Shared detector/changeling/decoy target multiplier across FAP & Arena Minimax.
(: sc2-target-priority-multiplier (->* (Any Any) (Any) Flonum))
(define (sc2-target-priority-multiplier etype stealth-active? [explicit-changeling? #f])
  (define detector-target? : Boolean
    (not (not (or (memq etype SC2-MOBILE-DETECTOR-SYMS)
                  (memq etype SC2-STATIC-DETECTOR-SYMS)))))
  (define changeling-target? : Boolean
    (not (not (or (memq etype SC2-CHANGELING-UNIT-SYMS)
                  explicit-changeling?))))
  (cond
    [changeling-target? 4.0]
    [(and detector-target? stealth-active?)
     (max 8.0 (->float SC2-DETECTOR-SNIPE-PRIORITY-BONUS))]
    [(memq etype SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS) 0.05]
    [else 1.0]))

;; W7-P0-1-eval (w7-tac-1): Extract `(values hull-hp shields total-ehp)` without double-counting
;; Protoss shields on live `sc2-protobuf-ws` hashes where `'hp = (+ health shield)` and `'hull-hp = health`,
;; while preserving synthetic split hashes (`'hp` = hull only, `'shield`/`'shields` = shield) matching
;; `pro-spellcaster-micro.rkt:1009` (`uh-total-hp`).
(: extract-unit-hull-and-shields (-> Any Flonum Flonum Flonum (Values Flonum Flonum Flonum)))
(define (extract-unit-hull-and-shields src-hash default-hp default-sh table-max-hp)
  (cond
    [(not (hash? src-hash))
     (define h (max 1.0 default-hp))
     (define s (max 0.0 default-sh))
     (values h s (max 1.0 (+ h s)))]
    [else
     (define sh : Flonum
       (max 0.0
            (safe-finite-real
             (cond
               [(dyn-hash-has-key? src-hash 'shields) (dyn-hash-ref src-hash 'shields default-sh)]
               [(dyn-hash-has-key? src-hash 'shield)  (dyn-hash-ref src-hash 'shield default-sh)]
               [else default-sh])
             default-sh)))
     (cond
       [(dyn-hash-has-key? src-hash 'hull-hp)
        (define hull : Flonum (max 1.0 (safe-finite-real (dyn-hash-ref src-hash 'hull-hp default-hp) default-hp)))
        (values hull sh (max 1.0 (+ hull sh)))]
       [else
        (define raw-hp : Flonum
          (safe-finite-real
           (cond
             [(dyn-hash-has-key? src-hash 'hp)     (dyn-hash-ref src-hash 'hp default-hp)]
             [(dyn-hash-has-key? src-hash 'health) (dyn-hash-ref src-hash 'health default-hp)]
             [else default-hp])
           default-hp))
        (define has-max? : Boolean (dyn-hash-has-key? src-hash 'max-hp))
        (define raw-max : Flonum
          (if has-max? (safe-finite-real (dyn-hash-ref src-hash 'max-hp 0.0) 0.0) 0.0))
        (define already-combined? : Boolean
          (and (> sh 0.0)
               (or (and (> table-max-hp 0.0) (> raw-hp (+ table-max-hp 0.5)))
                   (and (<= table-max-hp 0.0) has-max? (> raw-max (+ sh 0.5)) (>= raw-hp sh)))))
        (if already-combined?
            (let* ([tot (max 1.0 raw-hp)]
                   [hull (max 1.0 (- tot sh))])
              (values hull sh tot))
            (let ([hull (max 1.0 raw-hp)])
              (values hull sh (max 1.0 (+ hull sh)))))])]))

;; Shared target scoring used by `select-focus-fire-target` (live/FAP combat).
;; L44-P0-1a: Gate `4.5x` `raider-worker-mult` strictly to mineral-line runby context
;; (`runby-worker-context?` = enemy workers present AND nearby enemy combat threat is light),
;; NEVER pulling Zealots/Adepts/Zerglings off a real frontal army clash!
(: score-focus-fire-priority (->* (Any Any Real Boolean Boolean Flonum Flonum Flonum) (Boolean) Flonum))
(define (score-focus-fire-priority attacker e arange stealth-active? has-attacker-pos? ax ay default-dps
                                   [runby-worker-context? #f])
  (define etype : Symbol
    (if (fap-unit? e)
        'unknown
        (symbol-or-default (dyn-hash-ref e 'type 'unknown) 'unknown)))
  (define attacker-type : Symbol
    (if (hash? attacker)
        (symbol-or-default (dyn-hash-ref attacker 'type 'unknown) 'unknown)
        'unknown))
  (define attr-bonus-mult : Flonum
    (if (and (not (eq? attacker-type 'unknown))
             (not (eq? etype 'unknown)))
        (let ([bmask (unit-primary-bonus-attr-mask attacker-type)]
              [tmask (unit-attribute-mask etype)])
          (cond
            [(fx= bmask 0) 1.0]
            [(fx> (fxand bmask tmask) 0) 3.0]
            [else 0.55]))
        1.0))
  (define detector-target? : Boolean
    (not (not (or (memq etype SC2-MOBILE-DETECTOR-SYMS)
                  (memq etype SC2-STATIC-DETECTOR-SYMS)))))
  (define changeling-target? : Boolean
    (not (not (or (memq etype SC2-CHANGELING-UNIT-SYMS)
                  (and (hash? e) (dyn-hash-ref e 'changeling? #f))))))
  (define decoy-mult : Flonum
    (sc2-target-priority-multiplier etype stealth-active? changeling-target?))
  (define hp : Flonum
    (max 1.0
         (if (fap-unit? e)
             (safe-real (fap-unit-hp e) 45.0)
             (let* ([st (if (eq? etype 'unknown) #f (sc2-unit-combat-stats etype))]
                    [t-hull (if st (safe-finite-real (dyn-hash-ref st 'max-hp 0.0) 0.0) 0.0)])
               (define-values (_hull _sh tot) (extract-unit-hull-and-shields e 45.0 0.0 t-hull))
               tot))))
  (define raw-dps : Flonum
    (cond
      [(and detector-target? stealth-active?)
       (max 30.0
            (if (fap-unit? e)
                (safe-real (fap-unit-dps e) 30.0)
                (safe-real (dyn-hash-ref e 'dps 30.0) 30.0)))]
      [changeling-target? 20.0]
      [(and runby-worker-context?
            (memq attacker-type RUNBY-WORKER-RAIDER-SYMS)
            (memq etype WORKER-TARGET-SYMS))
       (max 16.0
            (if (fap-unit? e)
                (safe-real (fap-unit-dps e) 16.0)
                (safe-real (dyn-hash-ref e 'dps 16.0) 16.0)))]
      [(fap-unit? e) (safe-real (fap-unit-dps e) default-dps)]
      [else (safe-real (dyn-hash-ref e 'dps 12.0) 12.0)]))
  (define raider-worker-mult : Flonum
    (cond
      [(and detector-target? stealth-active?) 1.0]
      [(not runby-worker-context?)
       (if (memq etype WORKER-TARGET-SYMS) 0.35 1.0)]
      [(not (memq attacker-type RUNBY-WORKER-RAIDER-SYMS)) 1.0]
      [(memq etype WORKER-TARGET-SYMS) 4.5]
      [(not (fx= (fxand (unit-attribute-mask etype) SC2-UNIT-ATTR-STRUCTURE) 0)) 0.15]
      [else 1.0]))
  (define dps : Flonum (max 1.0 raw-dps))
  (define base-priority : Flonum (* decoy-mult attr-bonus-mult raider-worker-mult (/ dps hp)))
  (define reach-weight : Flonum
    (if has-attacker-pos?
        (let* ([ex (if (fap-unit? e)
                       (safe-real (fap-unit-x e) ax)
                       (safe-real (dyn-hash-ref e 'x ax) ax))]
               [ey (if (fap-unit? e)
                       (safe-real (fap-unit-y e) ay)
                       (safe-real (dyn-hash-ref e 'y ay) ay))]
               [dist (dist2d ax ay ex ey)]
               [excess (max 0.0 (- dist (max 1.0 (->float arange))))])
          (/ 1.0 (+ 1.0 (* 0.25 excess))))
        1.0))
  (* base-priority reach-weight))

;; Shared target scoring helper for arena minimax rollouts (DPS / effective-HP * range ratio).
(: score-arena-focus-target (-> Real Real Real Real Flonum))
(define (score-arena-focus-target combined-dps effective-hp dist attacker-range)
  (define dps-num (+ 5.0 (max 0.0 (safe-finite-real combined-dps 0.0))))
  (define hp-den (max 1.0 (safe-finite-real effective-hp 1.0)))
  (define r-den (max 1.0 (safe-finite-real attacker-range 1.0)))
  (define d-val (max 1.0 (safe-finite-real dist 1.0)))
  (/ dps-num (* hp-den (max 1.0 (/ d-val r-den)))))

;; Focus-fire target selector:
;; Ranks enemy targets by DPS-to-HP priority (`dps / max(1, hp)`), weighted by
;; spatial proximity / weapon range reachability when unit coordinates are present.
;; Supports both `(select-focus-fire-target enemies)` and `(select-focus-fire-target attacker enemies)`.
(: select-focus-fire-target
   (->* (Any) (Any #:max-range (U Real False) #:ally-has-stealth? Boolean #:ally-units (Listof Any)) Any))
(define (select-focus-fire-target arg1 [arg2 #f]
                                  #:max-range [max-range #f]
                                  #:ally-has-stealth? [ally-has-stealth? #f]
                                  #:ally-units [ally-units '()])
  (define attacker : Any (if (list? arg1) arg2 arg1))
  (define enemies : (Listof Any)
    (cond
      [(list? arg1) arg1]
      [(list? arg2) arg2]
      [else '()]))
  (define attacker-type : (Option Symbol)
    (and (hash? attacker)
         (let ([t (dyn-hash-ref attacker 'type #f)])
           (and (symbol? t) t))))
  (define squad-stealth? : Boolean
    (or ally-has-stealth?
        (and (pair? ally-units) (ally-squad-has-stealth-unit? ally-units))))
  (define live-detector-cnt : Integer
    (if squad-stealth?
        (for/sum : Integer ([e (in-list enemies)]
                            #:when (and (hash? e)
                                        (let ([et (symbol-or-default (dyn-hash-ref e 'type 'unknown) 'unknown)])
                                          (or (memq et SC2-MOBILE-DETECTOR-SYMS)
                                              (memq et SC2-STATIC-DETECTOR-SYMS)))))
          1)
        0))
  (define stealth-active? : Boolean
    (not (not (or (and ally-has-stealth? (or (null? ally-units) (<= live-detector-cnt 3)))
                  (and (pair? ally-units) squad-stealth? (>= live-detector-cnt 1) (<= live-detector-cnt 3))
                  (and attacker-type (memq attacker-type SC2-CLOAKED-OR-BURROW-STEALTH-SYMS))
                  (and (hash? attacker)
                       (or (dyn-hash-ref attacker 'cloaked #f)
                           (dyn-hash-ref attacker 'burrowed #f)))))))
  (define raw-alive-enemies : (Listof Any)
    (filter (lambda ([e : Any])
              (define hp : Real
                (if (fap-unit? e)
                    (fap-unit-hp e)
                    (safe-real (dyn-hash-ref e 'hp 45) 45)))
              (and (> hp 0)
                   (or (fap-unit? e) (sc2-enemy-unit-targetable? e))))
            enemies))
  (define domain-matched-enemies : (Listof Any)
    (if attacker-type
        (filter (lambda ([e : Any])
                  (or (fap-unit? e)
                      (sc2-attacker-can-hit-enemy? attacker-type e)))
                raw-alive-enemies)
        raw-alive-enemies))
  (define alive-enemies : (Listof Any)
    (if (null? domain-matched-enemies) raw-alive-enemies domain-matched-enemies))
  (cond
    [(null? alive-enemies) #f]
    [else
     (define has-attacker-pos? : Boolean
       (or (fap-unit? attacker)
           (and (hash? attacker)
                (dyn-hash-has-key? attacker 'x)
                (dyn-hash-has-key? attacker 'y))))
     (define ax : Flonum
       (cond [(fap-unit? attacker) (safe-real (fap-unit-x attacker) 32.0)]
             [(hash? attacker) (safe-real (dyn-hash-ref attacker 'x 32.0) 32.0)]
             [else 32.0]))
     (define ay : Flonum
       (cond [(fap-unit? attacker) (safe-real (fap-unit-y attacker) 32.0)]
             [(hash? attacker) (safe-real (dyn-hash-ref attacker 'y 32.0) 32.0)]
             [else 32.0]))
     (define arange : Real
       (or max-range
           (cond [(fap-unit? attacker) (fap-unit-range attacker)]
                 [(hash? attacker) (safe-real (dyn-hash-ref attacker 'range 6.0) 6.0)]
                 [else 6.0])))
     ;; L44-P0-1a: Compute `runby-worker-context?` strictly when a raider faces enemy workers
     ;; with light nearby enemy combat defense (`<= 2` ground melee/skirmisher, `<= 3` dedicated
     ;; mineral-line harassers within `<= 8.0t`) — NEVER pulling Zealots/Adepts/Lings off a real
     ;; frontal army clash to chase 1 repairing SCV!
     (define runby-worker-context? : Boolean
       (and (symbol? attacker-type)
            (not (not (memq attacker-type RUNBY-WORKER-RAIDER-SYMS)))
            (let-values ([(has-worker? combat-cnt)
                          (for/fold ([hw? : Boolean #f] [cc : Integer 0])
                                    ([e (in-list alive-enemies)])
                            (if (fap-unit? e)
                                (values hw? (add1 cc))
                                (let ([et (symbol-or-default (dyn-hash-ref e 'type 'unknown) 'unknown)])
                                  (cond
                                    [(memq et WORKER-TARGET-SYMS)
                                     (values #t cc)]
                                    [(or (memq et SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS)
                                         (memq et SC2-CHANGELING-UNIT-SYMS)
                                         (not (fx= (fxand (unit-attribute-mask et) SC2-UNIT-ATTR-STRUCTURE) 0)))
                                     (values hw? cc)]
                                    [(or (not has-attacker-pos?)
                                         (<= (dist2d ax ay
                                                     (safe-real (dyn-hash-ref e 'x ax) ax)
                                                     (safe-real (dyn-hash-ref e 'y ay) ay))
                                             8.0))
                                     (values hw? (add1 cc))]
                                    [else (values hw? cc)]))))])
              (define max-combat : Integer
                (if (memq attacker-type '(hellion adept oracle banshee mutalisk)) 3 2))
              (and has-worker? (<= combat-cnt max-combat)))))
     (define best-target : Any (car alive-enemies))
     (define best-score : Flonum -inf.0)
     (for ([e (in-list alive-enemies)])
       (define score
         (score-focus-fire-priority attacker e arange stealth-active? has-attacker-pos? ax ay 12.0
                                    runby-worker-context?))
       (when (> score best-score)
         (set! best-score score)
         (set! best-target e)))
     best-target]))

;; Simulate `ticks` of combat and return net value advantage.
(: fap-simulate-combat (->* (Any Any) (Any) Real))
(define (fap-simulate-combat ally-units enemy-units [ticks 8])
  (define a-list : (Listof Any) (if (list? ally-units) ally-units '()))
  (define e-list : (Listof Any) (if (list? enemy-units) enemy-units '()))
  (define allies : (Listof fap-unit) (map coerce-fap-unit a-list))
  (define enemies : (Listof fap-unit) (map coerce-fap-unit e-list))
  (define n-ticks (max 0 (safe-exact-int ticks 8)))
  (for ([_ (in-range n-ticks)])
    (define alive-allies : (Listof fap-unit)
      (filter (lambda ([u : fap-unit]) (> (fap-unit-hp u) 0)) allies))
    (define alive-enemies : (Listof fap-unit)
      (filter (lambda ([u : fap-unit]) (> (fap-unit-hp u) 0)) enemies))
    (when (and (not (null? alive-allies))
               (not (null? alive-enemies)))
      (for ([a (in-list alive-allies)])
        (define raw-target (select-focus-fire-target a alive-enemies))
        (define target : fap-unit
          (if (fap-unit? raw-target) raw-target (car alive-enemies)))
        (define dmg (max 1 (- (fap-unit-dps a) (fap-unit-armor target))))
        (set-fap-unit-hp! target (- (fap-unit-hp target) dmg)))
      (for ([e (in-list alive-enemies)])
        (define raw-target (select-focus-fire-target e alive-allies))
        (define target : fap-unit
          (if (fap-unit? raw-target) raw-target (car alive-allies)))
        (define dmg (max 1 (- (fap-unit-dps e) (fap-unit-armor target))))
        (set-fap-unit-hp! target (- (fap-unit-hp target) dmg)))))
  (define ally-surviving-val : Real
    (for/sum : Real ([a (in-list allies)] #:when (> (fap-unit-hp a) 0))
      (fap-unit-cost a)))
  (define enemy-surviving-val : Real
    (for/sum : Real ([e (in-list enemies)] #:when (> (fap-unit-hp e) 0))
      (fap-unit-cost e)))
  (- ally-surviving-val enemy-surviving-val))

;; Fast closed-form Lanchester + HP/DPS score used in per-frame telemetry.
(: fap-evaluate-engagement (-> Any Any Integer))
(define (fap-evaluate-engagement ally-units enemy-units)
  (define allies : (Listof Any) (if (list? ally-units) ally-units '()))
  (define enemies : (Listof Any) (if (list? enemy-units) enemy-units '()))
  (cond
    [(and (null? allies) (null? enemies)) 0]
    [(null? enemies) (* 10 (length allies))]
    [(null? allies) (* -15 (length enemies))]
    [else
     (define ally-power : Real
       (for/sum : Real ([u (in-list allies)])
         (cond
           [(hash? u)
            (+ (safe-real (dyn-hash-ref u 'dps 12) 12)
               (quotient (safe-exact-int (dyn-hash-ref u 'hp 45) 45) 5))]
           [(fap-unit? u)
            (+ (fap-unit-dps u)
               (quotient (safe-exact-int (fap-unit-hp u) 45) 5))]
           [else 20])))
     (define enemy-power : Real
       (for/sum : Real ([e (in-list enemies)])
         (cond
           [(hash? e)
            (+ (safe-real (dyn-hash-ref e 'dps 12) 12)
               (quotient (safe-exact-int (dyn-hash-ref e 'hp 45) 45) 5))]
           [(fap-unit? e)
            (+ (fap-unit-dps e)
               (quotient (safe-exact-int (fap-unit-hp e) 45) 5))]
           [else 20])))
     (exact-round (- (* ally-power 1.1) enemy-power))]))

;; Hysteresis band [theta-retreat = -15, theta-attack = +25]:
;; Inside [theta-retreat, theta-attack], preserve `current-posture` (no thrashing!).
(: fap-posture-with-hysteresis
   (->* (Any Symbol) (#:theta-retreat Real #:theta-attack Real) Symbol))
(define (fap-posture-with-hysteresis fap-score current-posture
                                     #:theta-retreat [theta-retreat -15]
                                     #:theta-attack [theta-attack 25])
  (define s (safe-finite-real fap-score 0.0))
  (cond
    [(< s theta-retreat) 'retreat]
    [(> s theta-attack)  'attack]
    [else current-posture]))

;; Orders units by distance to choke (`choke-x`, `choke-y`) so front/closest-to-choke
;; units step through the narrow choke first without body-blocking rear units,
;; assigning staggered retreat lanes in SC2 map tiles.
(: purplewave-traffic-retreat
   (->* (Any Any Any Any Any) (Any) (Listof (Immutable-HashTable Symbol Any))))
(define (purplewave-traffic-retreat units choke-x choke-y safe-x safe-y [choke-clearance 3])
  (define unit-list : (Listof Any) (if (list? units) units '()))
  (define cx (safe-finite-real choke-x 32.0))
  (define cy (safe-finite-real choke-y 32.0))
  (define sx (safe-finite-real safe-x 32.0))
  (define sy (safe-finite-real safe-y 32.0))
  (define clr (max 1 (safe-exact-int choke-clearance 3)))
  (define sorted-units : (Listof Any)
    ((inst sort Any Real)
     unit-list
     <
     #:key (lambda ([u : Any])
             (define ux (if (fap-unit? u)
                            (safe-real (fap-unit-x u) 32.0)
                            (safe-real (dyn-hash-ref u 'x 32.0) 32.0)))
             (define uy (if (fap-unit? u)
                            (safe-real (fap-unit-y u) 32.0)
                            (safe-real (dyn-hash-ref u 'y 32.0) 32.0)))
             (+ (sqr (- ux cx)) (sqr (- uy cy))))))
  (for/list : (Listof (Immutable-HashTable Symbol Any))
            ([u (in-list sorted-units)]
             [idx : Nonnegative-Integer (in-naturals)])
    (define uid
      (if (fap-unit? u)
          (fap-unit-id u)
          (dyn-hash-ref u 'id idx)))
    (define lane-offset : Integer
      (* (- (modulo idx clr) (quotient clr 2)) 2))
    (define wave-depth : Integer
      (* (quotient idx clr) 2))
    ((inst hash Symbol Any)
     'unit-id uid
     'order-rank idx
     'target-x (if (exact-integer? safe-x) (+ safe-x lane-offset) (+ sx lane-offset))
     'target-y (if (exact-integer? safe-y) (- safe-y wave-depth) (- sy wave-depth))
     'collision-free #t)))

(: compute-kite-vector (->* (Any Any Any Any) (Any) (Values Integer Integer)))
(define (compute-kite-vector ux uy ex ey [step-dist 3])
  (define fx (safe-finite-real ux 32.0))
  (define fy (safe-finite-real uy 32.0))
  (define fex (safe-finite-real ex 32.0))
  (define fey (safe-finite-real ey 32.0))
  (define sd (safe-finite-real step-dist 3.0))
  (define dx (- fx fex))
  (define dy (- fy fey))
  (define mag (max 1.0 (dist2d fx fy fex fey)))
  (values (exact-round (+ fx (* sd (/ dx mag))))
          (exact-round (+ fy (* sd (/ dy mag))))))

;; =============================================================================
;; 9. Predictive Engagement Outcome Evaluator (Slice 1.5A)
;; =============================================================================

(define *combat-norm-sym-cache* : (HashTable String Symbol) (make-hash))

(: normalize-combat-unit-sym (-> Any Symbol))
(define (normalize-combat-unit-sym raw)
  (cond
    [(symbol? raw)
     (define key (symbol->string raw))
     (define cached (hash-ref *combat-norm-sym-cache* key #f))
     (if cached
         cached
         (let* ([kebab (string->kebab-canon key)]
                [canon (canonical-unit-type-sym (string->symbol kebab))]
                [final (resolve-combat-sym-alias canon)])
           (hash-set! *combat-norm-sym-cache* key final)
           final))]
    [(string? raw)
     (define cached (hash-ref *combat-norm-sym-cache* raw #f))
     (if cached
         cached
         (let* ([kebab (string->kebab-canon raw)]
                [canon (canonical-unit-type-sym (string->symbol kebab))]
                [final (resolve-combat-sym-alias canon)])
           (hash-set! *combat-norm-sym-cache* raw final)
           final))]
    [else 'unknown]))

(: string->kebab-canon (-> String String))
(define (string->kebab-canon s)
  (define len (string-length s))
  (define out (open-output-string))
  (let loop ([i : Nonnegative-Fixnum 0]
             [prev-ch : (U False Char) #f]
             [prev-dash? : Boolean #t])
    (if (< i len)
        (let ([ch (string-ref s i)])
          (cond
            [(or (char=? ch #\_) (char=? ch #\space) (char=? ch #\-))
             (unless prev-dash?
               (write-char #\- out))
             (loop (fx+ i 1) ch #t)]
            [(and (char-upper-case? ch)
                  prev-ch
                  (not prev-dash?)
                  (or (char-lower-case? prev-ch) (char-numeric? prev-ch)))
             (write-char #\- out)
             (write-char (char-downcase ch) out)
             (loop (fx+ i 1) ch #f)]
            [else
             (write-char (char-downcase ch) out)
             (loop (fx+ i 1) ch #f)]))
        (get-output-string out))))

(: resolve-combat-sym-alias (-> Symbol Symbol))
(define (resolve-combat-sym-alias s)
  (case s
    [(viking-fighter vikingfighter) 'viking]
    [(siegetanksieged siegetank) (if (eq? s 'siegetanksieged) 'siege-tank-sieged 'siege-tank)]
    [(thorap) 'thor-ap]
    [(lurker-mp lurker-burrowed-mp) 'lurker]
    [(baneling-cocoon) 'baneling]
    [(broodlord) 'brood-lord]
    [(swarmhost swarm-host-mp) 'swarm-host]
    [(voidray) 'void-ray]
    [(hightemplar) 'high-templar]
    [(darktemplar) 'dark-templar]
    [(missileturret) 'missile-turret]
    [(photoncannon) 'photon-cannon]
    [(shieldbattery) 'shield-battery]
    [(sporecrawler) 'spore-crawler]
    [(spinecrawler) 'spine-crawler]
    [else s]))

(: parse-combat-upgrade-suffix (-> String Nonnegative-Fixnum))
(define (parse-combat-upgrade-suffix s)
  (define len (string-length s))
  (if (> len 0)
      (let ([last-c (string-ref s (- len 1))])
        (cond
          [(char=? last-c #\3) 3]
          [(char=? last-c #\2) 2]
          [(char=? last-c #\1) 1]
          [else 0]))
      0))

(struct combat-upgrade-levels
  ([gen-atk : Nonnegative-Fixnum]
   [bio-atk : Nonnegative-Fixnum]
   [mech-atk : Nonnegative-Fixnum]
   [air-atk : Nonnegative-Fixnum]
   [melee-atk : Nonnegative-Fixnum]
   [missile-atk : Nonnegative-Fixnum]
   [ground-armor : Nonnegative-Fixnum]
   [air-armor : Nonnegative-Fixnum]
   [shields : Nonnegative-Fixnum]))

(: parse-combat-upgrades (-> Any combat-upgrade-levels))
(define (parse-combat-upgrades raw)
  (define gen-atk : Nonnegative-Fixnum 0)
  (define bio-atk : Nonnegative-Fixnum 0)
  (define mech-atk : Nonnegative-Fixnum 0)
  (define air-atk : Nonnegative-Fixnum 0)
  (define melee-atk : Nonnegative-Fixnum 0)
  (define missile-atk : Nonnegative-Fixnum 0)
  (define ground-armor : Nonnegative-Fixnum 0)
  (define air-armor : Nonnegative-Fixnum 0)
  (define shield-lvl : Nonnegative-Fixnum 0)
  (: add-upg-sym! (-> Symbol Void))
  (define (add-upg-sym! s)
    (define k (normalize-combat-unit-sym s))
    (define str (symbol->string k))
    (define lvl (parse-combat-upgrade-suffix str))
    (when (> lvl 0)
      (cond
        [(regexp-match? #rx"shield" str)
         (when (> lvl shield-lvl) (set! shield-lvl lvl))]
        [(or (regexp-match? #rx"armor" str)
             (regexp-match? #rx"plating" str)
             (regexp-match? #rx"carapace" str))
         (cond
           [(regexp-match? #rx"vehicle-and-ship" str)
            (when (> lvl ground-armor) (set! ground-armor lvl))
            (when (> lvl air-armor) (set! air-armor lvl))]
           [(or (regexp-match? #rx"ship" str)
                (regexp-match? #rx"flyer" str)
                (regexp-match? #rx"air" str))
            (when (> lvl air-armor) (set! air-armor lvl))]
           [else
            (when (> lvl ground-armor) (set! ground-armor lvl))])]
        [(or (regexp-match? #rx"weapon" str)
             (regexp-match? #rx"attack" str))
         (cond
           [(regexp-match? #rx"melee" str)
            (when (> lvl melee-atk) (set! melee-atk lvl))]
           [(regexp-match? #rx"missile" str)
            (when (> lvl missile-atk) (set! missile-atk lvl))]
           [(regexp-match? #rx"infantry" str)
            (when (> lvl bio-atk) (set! bio-atk lvl))]
           [(or (regexp-match? #rx"vehicle-and-ship" str))
            (when (> lvl mech-atk) (set! mech-atk lvl))
            (when (> lvl air-atk) (set! air-atk lvl))]
           [(regexp-match? #rx"vehicle" str)
            (when (> lvl mech-atk) (set! mech-atk lvl))]
           [(or (regexp-match? #rx"ship" str)
                (regexp-match? #rx"flyer" str)
                (regexp-match? #rx"air" str))
            (when (> lvl air-atk) (set! air-atk lvl))]
           [(regexp-match? #rx"ground" str)
            (when (> lvl bio-atk) (set! bio-atk lvl))
            (when (> lvl mech-atk) (set! mech-atk lvl))]
           [else
            (when (> lvl gen-atk) (set! gen-atk lvl))])])))
  (: clamp-lvl (-> Any Nonnegative-Fixnum))
  (define (clamp-lvl v)
    (if (real? v)
        (let ([n (exact-floor v)])
          (cond [(>= n 3) 3] [(= n 2) 2] [(= n 1) 1] [else 0]))
        0))
  (cond
    [(list? raw)
     (for ([x (in-list raw)])
       (cond
         [(or (symbol? x) (string? x)) (add-upg-sym! (if (symbol? x) x (string->symbol x)))]
         [(and (pair? x) (or (symbol? (car x)) (string? (car x))) (cdr x))
          (define c (car x))
          (add-upg-sym! (if (symbol? c) c (string->symbol c)))]))]
    [(vector? raw)
     (for ([x (in-vector raw)])
       (when (or (symbol? x) (string? x))
         (add-upg-sym! (if (symbol? x) x (string->symbol x)))))]
    [(hash? raw)
     (when (dyn-hash-has-key? raw 'attack)
       (define al (clamp-lvl (dyn-hash-ref raw 'attack 0)))
       (when (> al gen-atk) (set! gen-atk al)))
     (when (dyn-hash-has-key? raw 'weapons)
       (define al (clamp-lvl (dyn-hash-ref raw 'weapons 0)))
       (when (> al gen-atk) (set! gen-atk al)))
     (when (dyn-hash-has-key? raw 'armor)
       (define al (clamp-lvl (dyn-hash-ref raw 'armor 0)))
       (when (> al ground-armor) (set! ground-armor al))
       (when (> al air-armor) (set! air-armor al)))
     (when (dyn-hash-has-key? raw 'armor-upg)
       (define al (clamp-lvl (dyn-hash-ref raw 'armor-upg 0)))
       (when (> al ground-armor) (set! ground-armor al))
       (when (> al air-armor) (set! air-armor al)))
     (when (dyn-hash-has-key? raw 'ground-armor)
       (define al (clamp-lvl (dyn-hash-ref raw 'ground-armor 0)))
       (when (> al ground-armor) (set! ground-armor al)))
     (when (dyn-hash-has-key? raw 'air-armor)
       (define al (clamp-lvl (dyn-hash-ref raw 'air-armor 0)))
       (when (> al air-armor) (set! air-armor al)))
     (when (dyn-hash-has-key? raw 'shields)
       (define sl (clamp-lvl (dyn-hash-ref raw 'shields 0)))
       (when (> sl shield-lvl) (set! shield-lvl sl)))
     (when (dyn-hash-has-key? raw 'shield-upg)
       (define sl (clamp-lvl (dyn-hash-ref raw 'shield-upg 0)))
       (when (> sl shield-lvl) (set! shield-lvl sl)))
     (for ([(k v) (in-hash raw)])
       (when (and v
                  (or (symbol? k) (string? k))
                  (not (memq k '(attack weapons armor armor-upg ground-armor air-armor shields shield-upg))))
         (add-upg-sym! (if (symbol? k) k (string->symbol k)))))]
    [(real? raw)
     (define lvl (clamp-lvl raw))
     (set! gen-atk lvl)
     (set! ground-armor lvl)
     (set! air-armor lvl)])
  (combat-upgrade-levels gen-atk bio-atk mech-atk air-atk melee-atk missile-atk ground-armor air-armor shield-lvl))

(: attacker-weapon-upgrade-lvl (-> Symbol Boolean combat-upgrade-levels Nonnegative-Fixnum))
(define (attacker-weapon-upgrade-lvl atk-type atk-flying? upgs)
  (define specific : Nonnegative-Fixnum
    (cond
      [(or atk-flying? (memq atk-type '(viking viking-fighter liberator banshee raven battlecruiser
                                                mutalisk corruptor brood-lord viper
                                                phoenix void-ray oracle carrier interceptor tempest mothership)))
       (combat-upgrade-levels-air-atk upgs)]
      [(memq atk-type '(zergling baneling ultralisk broodling))
       (combat-upgrade-levels-melee-atk upgs)]
      [(memq atk-type '(roach ravager hydralisk lurker lurker-burrowed queen locust))
       (combat-upgrade-levels-missile-atk upgs)]
      [(memq atk-type '(hellion hellbat widow-mine widow-mine-burrowed cyclone siege-tank siege-tank-sieged thor thor-ap viking-assault))
       (combat-upgrade-levels-mech-atk upgs)]
      [(memq atk-type '(photon-cannon spine-crawler spore-crawler missile-turret bunker))
       0]
      [else
       (combat-upgrade-levels-bio-atk upgs)]))
  (if (> specific (combat-upgrade-levels-gen-atk upgs))
      specific
      (combat-upgrade-levels-gen-atk upgs)))

(struct norm-combat-unit
  ([type : Symbol]
   [hp : Flonum]
   [shields : Flonum]
   [ehp : Flonum]
   [flying? : Boolean]
   [can-air? : Boolean]
   [count : Positive-Integer]
   [barrier? : Boolean]
   [aam? : Boolean]
   [gs? : Boolean]))

(: bool-hash-flag (-> Any (Listof Symbol) Boolean Boolean))
(define (bool-hash-flag h keys default-val)
  (let loop ([ks keys])
    (if (null? ks)
        default-val
        (let ([k (car ks)])
          (if (dyn-hash-has-key? h k)
              (let ([v (dyn-hash-ref h k #f)])
                (if (boolean? v) v (if v #t #f)))
              (loop (cdr ks)))))))

(: first-hash-val (-> Any (Listof Symbol) Any Any))
(define (first-hash-val h keys default-val)
  (let loop ([ks keys])
    (if (null? ks)
        default-val
        (let ([k (car ks)])
          (if (dyn-hash-has-key? h k)
              (dyn-hash-ref h k default-val)
              (loop (cdr ks)))))))

(: build-norm-combat-unit (-> Symbol Any Flonum Boolean (Values norm-combat-unit Boolean)))
(define (build-norm-combat-unit canon src-hash cnt flying-default?)
  (define st (sc2-unit-combat-stats canon))
  (define st-hp (safe-finite-real (dyn-hash-ref st 'max-hp 0.0) 0.0))
  (define st-sh (safe-finite-real (dyn-hash-ref st 'max-shield 0.0) 0.0))
  (define default-hp (if (> st-hp 0.0) st-hp 100.0))
  ;; W7-P0-1-eval (w7-tac-1): Never double-count shields when src-hash already stores combined 'hp + 'hull-hp
  (define-values (hp sh ehp)
    (if src-hash
        (extract-unit-hull-and-shields src-hash default-hp st-sh st-hp)
        (values default-hp st-sh (max 1.0 (+ default-hp st-sh)))))
  (define flying?
    (if src-hash
        (bool-hash-flag src-hash '(flying? is_flying is-flying) flying-default?)
        flying-default?))
  (define barrier?
    (if src-hash
        (bool-hash-flag src-hash '(barrier-active? barrier?) #f)
        #f))
  (define aam?
    (if src-hash
        (bool-hash-flag src-hash '(aam-debuff?) #f)
        #f))
  (define gs?
    (if src-hash
        (bool-hash-flag src-hash '(guardian-shield?) #f)
        #f))
  (define can-air? (sc2-unit-can-attack-air? canon))
  (define cnt-int (exact-floor cnt))
  (define pos-cnt : Positive-Integer (if (> cnt-int 0) cnt-int 1))
  (values (norm-combat-unit canon hp sh ehp flying? can-air? pos-cnt barrier? aam? gs?)
          (> cnt-int 0)))

(: parse-combat-unit-list (-> Any (Listof norm-combat-unit)))
(define (parse-combat-unit-list raw)
  (define raw-items : (Listof Any)
    (cond
      [(list? raw) raw]
      [(vector? raw) (vector->list raw)]
      [(hash? raw)
       (if (or (dyn-hash-has-key? raw 'type)
               (dyn-hash-has-key? raw 'unit_type)
               (dyn-hash-has-key? raw 'unit-type)
               (dyn-hash-has-key? raw 'name)
               (dyn-hash-has-key? raw 'unit-name))
           (list raw)
           (for/list : (Listof Any) ([(k v) (in-hash raw)])
             (cons k v)))]
      [else '()]))
  ;; Group identical (type, hp, shields, flying?, barrier?, aam?, gs?) entries so 200v200 calls stay microsecond-fast
  (define grouped : (HashTable (List Symbol Integer Integer Boolean Boolean Boolean Boolean)
                               (List norm-combat-unit Integer))
    (make-hash))
  (for ([item (in-list raw-items)])
    (define-values (canon src-hash raw-cnt)
      (cond
        [(or (symbol? item) (string? item))
         (values (normalize-combat-unit-sym item) #f 1.0)]
        [(hash? item)
         (define t (first-hash-val item '(type unit_type unit-type name unit-name) 'unknown))
         (define c (safe-finite-real (first-hash-val item '(count qty) 1.0) 1.0))
         (values (normalize-combat-unit-sym t) item c)]
        [(pair? item)
         (define c (safe-finite-real (if (list? (cdr item)) (car (cdr item)) (cdr item)) 1.0))
         (values (normalize-combat-unit-sym (car item)) #f c)]
        [else (values 'unknown #f 0.0)]))
    (when (and (not (eq? canon 'unknown)) (> raw-cnt 0.0))
      (define flying-def? (sc2-unit-is-flying-sym? canon))
      (define-values (nu ok?) (build-norm-combat-unit canon src-hash raw-cnt flying-def?))
      (when ok?
        (define key (list (norm-combat-unit-type nu)
                          (exact-round (norm-combat-unit-hp nu))
                          (exact-round (norm-combat-unit-shields nu))
                          (norm-combat-unit-flying? nu)
                          (norm-combat-unit-barrier? nu)
                          (norm-combat-unit-aam? nu)
                          (norm-combat-unit-gs? nu)))
        (define cur (hash-ref grouped key #f))
        (if cur
            (hash-set! grouped key (list (car cur) (+ (cadr cur) (norm-combat-unit-count nu))))
            (hash-set! grouped key (list nu (norm-combat-unit-count nu)))))))
  (for/list : (Listof norm-combat-unit) ([entry (in-hash-values grouped)])
    (define u (car entry))
    (define n (cadr entry))
    (define pos-n : Positive-Integer (if (> n 0) n 1))
    (norm-combat-unit (norm-combat-unit-type u)
                      (norm-combat-unit-hp u)
                      (norm-combat-unit-shields u)
                      (norm-combat-unit-ehp u)
                      (norm-combat-unit-flying? u)
                      (norm-combat-unit-can-air? u)
                      pos-n
                      (norm-combat-unit-barrier? u)
                      (norm-combat-unit-aam? u)
                      (norm-combat-unit-gs? u))))

(: exact-unit-dps-vs (-> norm-combat-unit norm-combat-unit combat-upgrade-levels combat-upgrade-levels Flonum))
(define (exact-unit-dps-vs atk tgt atk-upgs tgt-upgs)
  (define a-type (norm-combat-unit-type atk))
  (define t-type (norm-combat-unit-type tgt))
  (define atk-lvl (attacker-weapon-upgrade-lvl a-type (norm-combat-unit-flying? atk) atk-upgs))
  (define t-shield-lvl (combat-upgrade-levels-shields tgt-upgs))
  (if (norm-combat-unit-flying? tgt)
      (if (norm-combat-unit-can-air? atk)
          (compute-exact-weapon-dps-vs-target
           a-type t-type
           #:attacker-upgrades atk-lvl
           #:target-armor-upg (combat-upgrade-levels-air-armor tgt-upgs)
           #:target-shield-upg t-shield-lvl
           #:target-shields (norm-combat-unit-shields tgt)
           #:target-hp (norm-combat-unit-hp tgt)
           #:barrier-active? (norm-combat-unit-barrier? tgt)
           #:aam-debuff? (norm-combat-unit-aam? tgt)
           #:guardian-shield? (norm-combat-unit-gs? tgt))
          0.0)
      (compute-exact-weapon-dps-vs-target
       a-type t-type
       #:attacker-upgrades atk-lvl
       #:target-armor-upg (combat-upgrade-levels-ground-armor tgt-upgs)
       #:target-shield-upg t-shield-lvl
       #:target-shields (norm-combat-unit-shields tgt)
       #:target-hp (norm-combat-unit-hp tgt)
       #:barrier-active? (norm-combat-unit-barrier? tgt)
       #:aam-debuff? (norm-combat-unit-aam? tgt)
       #:guardian-shield? (norm-combat-unit-gs? tgt))))

(: predict-engagement-outcome
   (->* (Any Any)
        (#:ally-upgrades Any
         #:enemy-upgrades Any
         #:defending-home? Any)
        (Immutable-HashTable Symbol Any)))
(define (predict-engagement-outcome ally-units enemy-units
                                    #:ally-upgrades [au '()]
                                    #:enemy-upgrades [eu '()]
                                    #:defending-home? [def? #f])
  (define allies (parse-combat-unit-list ally-units))
  (define enemies (parse-combat-unit-list enemy-units))
  (define ally-upgs (parse-combat-upgrades au))
  (define enemy-upgs (parse-combat-upgrades eu))
  (define home? (if def? #t #f))
  (define ally-total-ehp
    (for/fold ([acc : Flonum 0.0]) ([a (in-list allies)])
      (+ acc (* (exact->inexact (norm-combat-unit-count a)) (norm-combat-unit-ehp a)))))
  (define enemy-total-ehp
    (for/fold ([acc : Flonum 0.0]) ([e (in-list enemies)])
      (+ acc (* (exact->inexact (norm-combat-unit-count e)) (norm-combat-unit-ehp e)))))
  (define ally-aa-ehp
    (for/fold ([acc : Flonum 0.0]) ([a (in-list allies)])
      (if (norm-combat-unit-can-air? a)
          (+ acc (* (exact->inexact (norm-combat-unit-count a)) (norm-combat-unit-ehp a)))
          acc)))
  (define enemy-air-ehp
    (for/fold ([acc : Flonum 0.0]) ([e (in-list enemies)])
      (if (norm-combat-unit-flying? e)
          (+ acc (* (exact->inexact (norm-combat-unit-count e)) (norm-combat-unit-ehp e)))
          acc)))
  ;; 1. Ally effective DPS vs enemy force + fraction of enemy EHP allies can damage
  (define damageable-enemy-ehp : Flonum 0.0)
  (for ([e (in-list enemies)])
    (define e-pool (* (exact->inexact (norm-combat-unit-count e)) (norm-combat-unit-ehp e)))
    (define any-hit?
      (for/or : Boolean ([a (in-list allies)])
        (> (exact-unit-dps-vs a e ally-upgs enemy-upgs) 0.0)))
    (when any-hit?
      (set! damageable-enemy-ehp (+ damageable-enemy-ehp e-pool))))
  (define ally-eff-dps : Flonum
    (if (<= enemy-total-ehp 0.0)
        0.0
        (for/fold ([sum : Flonum 0.0]) ([a (in-list allies)])
          (define ca (exact->inexact (norm-combat-unit-count a)))
          (define weighted-dps-vs-e
            (/ (for/fold ([ws : Flonum 0.0]) ([e (in-list enemies)])
                 (define e-pool (* (exact->inexact (norm-combat-unit-count e)) (norm-combat-unit-ehp e)))
                 (+ ws (* e-pool (exact-unit-dps-vs a e ally-upgs enemy-upgs))))
               enemy-total-ehp))
          (+ sum (* ca weighted-dps-vs-e)))))
  ;; 2. Ally AA-only DPS against flying enemy units (weighted over enemy-air-ehp)
  (define ally-aa-dps : Flonum
    (if (<= enemy-air-ehp 0.0)
        0.0
        (for/fold ([sum : Flonum 0.0]) ([a (in-list allies)])
          (if (norm-combat-unit-can-air? a)
              (let* ([ca (exact->inexact (norm-combat-unit-count a))]
                     [w-dps
                      (/ (for/fold ([ws : Flonum 0.0]) ([e (in-list enemies)])
                           (if (norm-combat-unit-flying? e)
                               (let ([e-pool (* (exact->inexact (norm-combat-unit-count e))
                                                (norm-combat-unit-ehp e))])
                                 (+ ws (* e-pool (exact-unit-dps-vs a e ally-upgs enemy-upgs))))
                               ws))
                         enemy-air-ehp)])
                (+ sum (* ca w-dps)))
              sum))))
  ;; 3. Enemy effective DPS vs ally force & enemy flying DPS vs ally AA/army
  (define enemy-eff-dps : Flonum
    (if (<= ally-total-ehp 0.0)
        0.0
        (for/fold ([sum : Flonum 0.0]) ([e (in-list enemies)])
          (define ce (exact->inexact (norm-combat-unit-count e)))
          (define weighted-dps-vs-a
            (/ (for/fold ([ws : Flonum 0.0]) ([a (in-list allies)])
                 (define a-pool (* (exact->inexact (norm-combat-unit-count a)) (norm-combat-unit-ehp a)))
                 (+ ws (* a-pool (exact-unit-dps-vs e a enemy-upgs ally-upgs))))
               ally-total-ehp))
          (+ sum (* ce weighted-dps-vs-a)))))
  ;; Enemy flying DPS weighed primarily against Ally AA sub-force (falling back to whole ally force if Ally has 0 AA)
  (define enemy-air-dps : Flonum
    (if (<= enemy-air-ehp 0.0)
        0.0
        (let ([denom (if (> ally-aa-ehp 0.0) ally-aa-ehp ally-total-ehp)])
          (if (<= denom 0.0)
              (for/fold ([sum : Flonum 0.0]) ([e (in-list enemies)])
                (if (norm-combat-unit-flying? e)
                    (let* ([ce (exact->inexact (norm-combat-unit-count e))]
                           [st (sc2-unit-combat-stats (norm-combat-unit-type e))]
                           [gdps (safe-finite-real (dyn-hash-ref st 'ground-dps 0.0) 0.0)]
                           [adps (safe-finite-real (dyn-hash-ref st 'air-dps 0.0) 0.0)])
                      (+ sum (* ce (max gdps adps))))
                    sum))
              (for/fold ([sum : Flonum 0.0]) ([e (in-list enemies)])
                (if (norm-combat-unit-flying? e)
                    (let* ([ce (exact->inexact (norm-combat-unit-count e))]
                           [w-dps
                            (/ (for/fold ([ws : Flonum 0.0]) ([a (in-list allies)])
                                 (if (or (<= ally-aa-ehp 0.0) (norm-combat-unit-can-air? a))
                                     (let ([a-pool (* (exact->inexact (norm-combat-unit-count a))
                                                      (norm-combat-unit-ehp a))])
                                       (+ ws (* a-pool (exact-unit-dps-vs e a enemy-upgs ally-upgs))))
                                     ws))
                               denom)])
                      (+ sum (* ce w-dps)))
                    sum))))))
  (define can-damage-enemy-pct : Flonum
    (if (> enemy-total-ehp 0.0)
        (min 1.0 (max 0.0 (/ damageable-enemy-ehp enemy-total-ehp)))
        1.0))
  (define anti-air-deficit? : Boolean
    (and (> enemy-air-ehp 0.0)
         (> enemy-air-dps 0.0)
         (< (* ally-aa-dps ally-aa-ehp)
            (* 0.90 enemy-air-dps enemy-air-ehp))))
  (define ally-power (* ally-eff-dps ally-total-ehp))
  (define enemy-power (* enemy-eff-dps enemy-total-ehp))
  (define predicted-lanchester-ratio : Flonum
    (cond
      [(<= ally-total-ehp 0.0) 0.0]
      [(<= enemy-total-ehp 0.0) 10.0]
      [(<= enemy-power 0.0)
       (if (> ally-eff-dps 0.0) 10.0 0.0)]
      [else
       (/ ally-power enemy-power)]))
  (define engage-threshold : Flonum (if home? 0.62 0.95))
  (define should-engage? : Boolean
    (and (> ally-total-ehp 0.0)
         (>= predicted-lanchester-ratio engage-threshold)
         (not anti-air-deficit?)
         (>= can-damage-enemy-pct 0.50)))
  (define recommended-posture : Symbol
    (cond
      [(or anti-air-deficit?
           (< can-damage-enemy-pct 0.50)
           (< predicted-lanchester-ratio (if home? 0.62 0.75)))
       'retreat-and-remacro-counter]
      [(and should-engage?
            (>= predicted-lanchester-ratio (if home? 0.90 1.05)))
       'press-advantage]
      [else
       'skirmish-kite]))
  (hasheq 'predicted-lanchester-ratio predicted-lanchester-ratio
          'can-damage-enemy-pct can-damage-enemy-pct
          'anti-air-deficit? anti-air-deficit?
          'should-engage? should-engage?
          'recommended-posture recommended-posture))
