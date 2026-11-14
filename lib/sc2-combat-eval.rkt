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
 sc2-target-priority-multiplier
 score-focus-fire-priority
 score-arena-focus-target
 select-focus-fire-target
 fap-simulate-combat
 fap-evaluate-engagement
 fap-posture-with-hysteresis
 purplewave-traffic-retreat
 compute-kite-vector
 compute-concave-arc)

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
         (counter-branch 'bio-ball         'baneling  'zergling '(spawning-pool baneling-nest) 150)
         (counter-branch 'zealot-rush      'roach     'zergling '(roach-warren)               150)
         (counter-branch 'mech-siege       'ravager   'roach    '(roach-warren)               150)
         (counter-branch 'air-fleet        'corruptor 'queen    '(lair spire)                 350)
         (counter-branch 'lurker-contain   'mutalisk  'roach    '(lair spire)                 400)
         (counter-branch 'roach-ravager    'hydralisk 'roach    '(lair hydralisk-den)         250)
         (counter-branch 'ling-bane-hydra  'roach     'baneling '(roach-warren)               150)
         (counter-branch 'stalker-colossus 'hydralisk 'roach    '(lair hydralisk-den)         250)
         (counter-branch 'sky-toss         'hydralisk 'queen    '(lair hydralisk-den)         250)
         (counter-branch 'muta-flock       'hydralisk 'queen    '(lair hydralisk-den)         250)
         (counter-branch 'early-rush       'roach     'zergling '(roach-warren)               150))))

(: PROTOSS-COUNTER-TREE plausible-counter-tree)
(define PROTOSS-COUNTER-TREE
  (plausible-counter-tree
   'PROTOSS-COUNTER-TREE
   'Protoss
   'zealot
   (list (counter-branch 'standard-macro   'stalker  'zealot  '(cybernetics-core)                   150)
         (counter-branch 'zergling-flood   'zealot   'stalker '(gateway)                            150)
         (counter-branch 'roach-ravager    'immortal 'stalker '(cybernetics-core robotics-facility) 350)
         (counter-branch 'lurker-contain   'immortal 'zealot  '(cybernetics-core robotics-facility) 350)
         (counter-branch 'bio-ball         'colossus 'stalker '(robotics-facility robotics-bay)     500)
         (counter-branch 'air-fleet        'stalker  'archon  '(cybernetics-core)                   150)
         (counter-branch 'mech-siege       'immortal 'stalker '(cybernetics-core robotics-facility) 350)
         (counter-branch 'stalker-colossus 'immortal 'stalker '(cybernetics-core robotics-facility) 350)
         (counter-branch 'sky-toss         'stalker  'archon  '(cybernetics-core)                   150)
         (counter-branch 'muta-flock       'phoenix  'stalker '(cybernetics-core stargate)          300)
         (counter-branch 'ling-bane-hydra  'colossus 'adept   '(robotics-facility robotics-bay)     500)
         (counter-branch 'early-rush       'stalker  'zealot  '(cybernetics-core)                   150))))

(: TERRAN-COUNTER-TREE plausible-counter-tree)
(define TERRAN-COUNTER-TREE
  (plausible-counter-tree
   'TERRAN-COUNTER-TREE
   'Terran
   'marine
   (list (counter-branch 'standard-macro   'siege-tank 'marauder '(factory)          250)
         (counter-branch 'zergling-flood   'widow-mine 'hellion  '(factory)          200)
         (counter-branch 'roach-ravager    'marauder   'marine   '(barracks-techlab) 100)
         (counter-branch 'lurker-contain   'siege-tank 'marine   '(factory)          250)
         (counter-branch 'protoss-deathball 'ghost     'marauder '(barracks-techlab) 300)
         (counter-branch 'air-fleet        'viking     'marine   '(starport)         250)
         (counter-branch 'bio-ball         'siege-tank 'marauder '(factory)          250)
         (counter-branch 'mech-siege       'siege-tank 'marauder '(factory)          250)
         (counter-branch 'stalker-colossus 'marauder   'marine   '(barracks-techlab) 100)
         (counter-branch 'sky-toss         'viking     'marine   '(starport)         250)
         (counter-branch 'muta-flock       'thor       'marine   '(factory armory)   300)
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
  (cond
    [(or (memq 'lurker types) (memq 'lurker-burrowed types) (memq 'lurker-mp-burrowed types))
     'lurker-contain]
    [(or (memq 'mutalisk types) (memq 'void-ray types) (memq 'carrier types)
         (memq 'battlecruiser types) (memq 'viking types) (memq 'corruptor types))
     'air-fleet]
    [(>= (count (lambda ([t : Symbol]) (eq? t 'zergling)) types) 6)
     'zergling-flood]
    [(or (memq 'siege-tank types) (memq 'siege-tank-sieged types)) 'mech-siege]
    [(or (memq 'roach types) (memq 'ravager types)) 'roach-ravager]
    [(>= (count (lambda ([t : Symbol]) (not (not (memq t '(marine marauder medivac))))) types) 5)
     'bio-ball]
    [(or (memq 'oracle types) (memq 'phoenix types) (memq 'banshee types)
         (memq 'liberator types) (memq 'tempest types))
     'sky-toss]
    [(or (memq 'colossus types) (memq 'immortal types) (memq 'archon types)
         (memq 'disruptor types) (memq 'high-templar types) (memq 'stalker types))
     'stalker-colossus]
    [(or (memq 'hellion types) (memq 'hellbat types) (memq 'cyclone types)
         (memq 'thor types) (memq 'widow-mine types))
     'mech-siege]
    [(or (memq 'hydralisk types) (memq 'baneling types))
     'ling-bane-hydra]
    [(or (memq 'marauder types) (memq 'reaper types) (memq 'ghost types) (memq 'marine types))
     'bio-ball]
    [(or (memq 'zealot types) (memq 'adept types) (memq 'sentry types) (memq 'dark-templar types))
     'stalker-colossus]
    [(memq 'zergling types)
     'ling-bane-hydra]
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
    [(and detector-target? stealth-active?) (->float SC2-DETECTOR-SNIPE-PRIORITY-BONUS)]
    [(memq etype SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS) 0.05]
    [else 1.0]))

;; Shared target scoring used by `select-focus-fire-target` (live/FAP combat).
(: score-focus-fire-priority (-> Any Any Real Boolean Boolean Flonum Flonum Flonum Flonum))
(define (score-focus-fire-priority _attacker e arange stealth-active? has-attacker-pos? ax ay default-dps)
  (define etype : Symbol
    (if (fap-unit? e)
        'unknown
        (symbol-or-default (dyn-hash-ref e 'type 'unknown) 'unknown)))
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
             (safe-real (dyn-hash-ref e 'hp 45.0) 45.0))))
  (define raw-dps : Flonum
    (cond
      [(and detector-target? stealth-active?)
       (max 18.0
            (if (fap-unit? e)
                (safe-real (fap-unit-dps e) 18.0)
                (safe-real (dyn-hash-ref e 'dps 18.0) 18.0)))]
      [changeling-target? 20.0]
      [(fap-unit? e) (safe-real (fap-unit-dps e) default-dps)]
      [else (safe-real (dyn-hash-ref e 'dps 12.0) 12.0)]))
  (define dps : Flonum (max 1.0 raw-dps))
  (define base-priority : Flonum (* decoy-mult (/ dps hp)))
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
   (->* (Any) (Any #:max-range (U Real False) #:ally-has-stealth? Boolean) Any))
(define (select-focus-fire-target arg1 [arg2 #f]
                                  #:max-range [max-range #f]
                                  #:ally-has-stealth? [ally-has-stealth? #f])
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
  (define stealth-active? : Boolean
    (not (not (or ally-has-stealth?
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
     (define best-target : Any (car alive-enemies))
     (define best-score : Flonum -inf.0)
     (for ([e (in-list alive-enemies)])
       (define score
         (score-focus-fire-priority attacker e arange stealth-active? has-attacker-pos? ax ay 12.0))
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
