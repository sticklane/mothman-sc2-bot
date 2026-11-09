#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math)

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

 ;; 6. PDA (Perception -> Decision -> Action) Diagnostic Triangulation
 (struct-out pda-trace)
 make-pda-trace
 diagnose-bot-anomaly)

;; =============================================================================
;; 1. Lanchester Snowball Advantage & Compounding Ledger
;; =============================================================================

;; Generalized Lanchester exponent = 1.7 for ranged/mixed SC combat
(define (lanchester-snowball-advantage self-army-value enemy-army-value
                                       #:self-efficiency [alpha-s 1.0]
                                       #:enemy-efficiency [alpha-e 1.0]
                                       #:exponent [exp-k 1.7])
  (define s-term (* alpha-s (expt (max 0.0 (exact->inexact self-army-value)) exp-k)))
  (define e-term (* alpha-e (expt (max 0.0 (exact->inexact enemy-army-value)) exp-k)))
  (- s-term e-term))

(define (evaluate-compounding-ledger #:self-workers [self-workers 16]
                                     #:enemy-workers [enemy-workers 16]
                                     #:self-army [self-army 200]
                                     #:enemy-army [enemy-army 200]
                                     #:self-bases [self-bases 1]
                                     #:enemy-bases [enemy-bases 1]
                                     #:fap-score [fap-score 0])
  (define worker-delta (- self-workers enemy-workers))
  (define base-delta (- self-bases enemy-bases))
  (define lanchester-delta (lanchester-snowball-advantage self-army enemy-army))
  (define dominant-driver
    (cond
      [(> base-delta 0) 'economic-compounding-snowball]
      [(> worker-delta 1) 'worker-cycle-compound-lead]
      [(and (> self-workers 12) (>= self-army enemy-army) (> self-army 0))
       'worker-cycle-compound-lead]
      [(not (= self-army enemy-army)) 'lanchester-army-critical-mass]
      [(= fap-score 0) 'lanchester-army-critical-mass]
      [else 'neutral-parity]))
  (define directive
    (cond
      [(< fap-score -15) 'retreat-and-regroup]
      [(> fap-score 35)  'press-attack]
      [(or (> self-army 100) (> self-workers 14)) 'probe-poke]
      [else 'hold-macro-neutral]))
  (hash 'dominant-driver dominant-driver
        'worker-delta worker-delta
        'base-delta base-delta
        'lanchester-delta lanchester-delta
        'net-score (+ (* 25 worker-delta) (* 150 base-delta) fap-score)
        'recommended-directive directive))

;; =============================================================================
;; 2. Bot Personalities & Doctrine Loadouts
;; =============================================================================

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

(def-bot-personality MARV-MACRO-OPEN-PERSONALITY
  #:race Protoss
  #:aggression 0.58
  #:econ-greed 0.85
  #:creep-weight 0.10
  #:drop-frequency 0.65
  #:flank-bias 0.72)

(def-bot-personality SCARLETT-CREEP-SWARM-PERSONALITY
  #:race Zerg
  #:aggression 0.74
  #:econ-greed 0.82
  #:creep-weight 0.95
  #:drop-frequency 0.45
  #:flank-bias 0.88)

(def-bot-personality CLEM-TEMPO-MULTITASK-PERSONALITY
  #:race Terran
  #:aggression 0.86
  #:econ-greed 0.70
  #:creep-weight 0.20
  #:drop-frequency 0.92
  #:flank-bias 0.84)

(struct doctrine-loadout (name primary-personality fallback-personality crisis-personality active)
  #:mutable
  #:transparent)

(define-syntax-rule (def-doctrine-loadout id
                      #:primary p1
                      #:fallback p2
                      #:crisis p3)
  (define id
    (doctrine-loadout 'id p1 p2 p3 p1)))

(define (step-doctrine-loadout! loadout #:fap-score [fap 0] #:under-rush? [rush? #f])
  (define chosen
    (cond
      [rush? (doctrine-loadout-crisis-personality loadout)]
      [(< fap -20) (doctrine-loadout-fallback-personality loadout)]
      [else (doctrine-loadout-primary-personality loadout)]))
  (set-doctrine-loadout-active! loadout chosen)
  chosen)

;; =============================================================================
;; 3. Plausible Counter Trees, Switching Cost & Demand-Pull
;; =============================================================================

(struct counter-branch (archetype primary-unit fallback-unit required-buildings tech-cost)
  #:transparent)

(struct plausible-counter-tree (name race default-unit branches)
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
     (list (counter-branch 'arch 'prim 'fall 'reqs cost) ...))))

(def-plausible-counter-tree ZERG-COUNTER-TREE
  #:race Zerg
  #:default zergling
  [standard-macro   roach      zergling (roach-warren)            150]
  [bio-ball         baneling   zergling (spawning-pool baneling-nest) 150]
  [zealot-rush      roach      zergling (roach-warren)            150]
  [mech-siege       ravager    roach    (roach-warren)            150]
  [air-fleet        corruptor  queen    (lair spire)              350]
  [lurker-contain   mutalisk   roach    (lair spire)              400]
  [roach-ravager    hydralisk  roach    (lair hydralisk-den)      250]
  [ling-bane-hydra  roach      baneling (roach-warren)            150]
  [stalker-colossus hydralisk  roach    (lair hydralisk-den)      250]
  [sky-toss         hydralisk  queen    (lair hydralisk-den)      250]
  [muta-flock       hydralisk  queen    (lair hydralisk-den)      250]
  [early-rush       roach      zergling (roach-warren)            150])

(def-plausible-counter-tree PROTOSS-COUNTER-TREE
  #:race Protoss
  #:default zealot
  [standard-macro   stalker    zealot   (cybernetics-core)        150]
  [zergling-flood   zealot     stalker  (gateway)                 150]
  [roach-ravager    immortal   stalker  (cybernetics-core robotics-facility) 350]
  [lurker-contain   immortal   zealot   (cybernetics-core robotics-facility) 350]
  [bio-ball         colossus   stalker  (robotics-facility robotics-bay) 500]
  [air-fleet        stalker    archon   (cybernetics-core)        150]
  [mech-siege       immortal   stalker  (cybernetics-core robotics-facility) 350]
  [stalker-colossus immortal   stalker  (cybernetics-core robotics-facility) 350]
  [sky-toss         stalker    archon   (cybernetics-core)        150]
  [muta-flock       phoenix    stalker  (cybernetics-core stargate) 300]
  [ling-bane-hydra  colossus   adept    (robotics-facility robotics-bay) 500]
  [early-rush       stalker    zealot   (cybernetics-core)        150])

(def-plausible-counter-tree TERRAN-COUNTER-TREE
  #:race Terran
  #:default marine
  [standard-macro   siege-tank marauder (factory)                 250]
  [zergling-flood   widow-mine hellion  (factory)                 200]
  [roach-ravager    marauder   marine   (barracks-techlab)        100]
  [lurker-contain   siege-tank marine   (factory)                 250]
  [protoss-deathball ghost     marauder (barracks-techlab)        300]
  [air-fleet        viking     marine   (starport)                250]
  [bio-ball         siege-tank marauder (factory)                 250]
  [mech-siege       siege-tank marauder (factory)                 250]
  [stalker-colossus marauder   marine   (barracks-techlab)        100]
  [sky-toss         viking     marine   (starport)                250]
  [muta-flock       thor       marine   (factory armory)          300]
  [ling-bane-hydra  siege-tank hellion  (factory)                 250]
  [early-rush       marauder   marine   (barracks-techlab)        100])

(define (get-race-counter-tree race)
  (case race
    [(Zerg zerg)       ZERG-COUNTER-TREE]
    [(Protoss protoss) PROTOSS-COUNTER-TREE]
    [(Terran terran)   TERRAN-COUNTER-TREE]
    [else              ZERG-COUNTER-TREE]))

(define (classify-enemy-archetype enemy-units)
  (define types (map (lambda (e) (hash-ref e 'type 'unknown)) enemy-units))
  (cond
    [(or (memq 'lurker types) (memq 'lurker-burrowed types)) 'lurker-contain]
    [(or (memq 'mutalisk types) (memq 'void-ray types) (memq 'carrier types)
         (memq 'battlecruiser types) (memq 'viking types) (memq 'corruptor types))
     'air-fleet]
    [(and (>= (count (lambda (t) (eq? t 'zergling)) types) 6)) 'zergling-flood]
    [(or (memq 'siege-tank types) (memq 'siege-tank-sieged types)) 'mech-siege]
    [(or (memq 'roach types) (memq 'ravager types)) 'roach-ravager]
    [(and (>= (count (lambda (t) (memq t '(marine marauder medivac))) types) 5)) 'bio-ball]
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

(define (normalize-mastermind-bldg-sym sym)
  (case sym
    [(robotics-support-bay) 'robotics-bay]
    [(templar-archives)     'templar-archive]
    [(warpgate)             'warp-gate]
    [else                   sym]))

(define (compute-switching-cost required-buildings existing-buildings
                                #:available-minerals [minerals 300]
                                #:available-gas [gas 150])
  (define existing-set (list->set (map normalize-mastermind-bldg-sym existing-buildings)))
  (define missing
    (filter (lambda (b) (not (set-member? existing-set (normalize-mastermind-bldg-sym b))))
            required-buildings))
  (define total-cost (* 150 (length missing)))
  (define feasible? (or (null? missing)
                        (and (<= (length missing) 1)
                             (>= (+ minerals gas) total-cost))))
  (hash 'feasible? feasible?
        'missing-buildings missing
        'total-cost total-cost))

(define (resolve-demand-pull tree enemy-archetype existing-buildings
                             #:minerals [minerals 300]
                             #:gas [gas 150])
  (define branch
    (findf (lambda (b) (eq? (counter-branch-archetype b) enemy-archetype))
           (plausible-counter-tree-branches tree)))
  (cond
    [(not branch)
     (hash 'selected-unit (plausible-counter-tree-default-unit tree)
           'plausible? #t
           'switching-cost 0
           'missing-buildings '())]
    [else
     (define sc (compute-switching-cost (counter-branch-required-buildings branch)
                                        existing-buildings
                                        #:available-minerals minerals
                                        #:available-gas gas))
     (if (hash-ref sc 'feasible?)
         (hash 'selected-unit (counter-branch-primary-unit branch)
               'plausible? #t
               'switching-cost (hash-ref sc 'total-cost)
               'missing-buildings (hash-ref sc 'missing-buildings))
         (hash 'selected-unit (counter-branch-fallback-unit branch)
               'plausible? #t
               'fallback-used? #t
               'switching-cost (hash-ref sc 'total-cost)
               'missing-buildings (hash-ref sc 'missing-buildings)))]))

;; =============================================================================
;; 4. Double-Reaction Tactical Loop
;; =============================================================================

(struct mastermind-state
  (race
   personality
   enemy-archetype
   selected-unit
   directive
   double-reactions
   flank-angle-idx
   compounding-dominant)
  #:mutable
  #:transparent)

(define (make-mastermind-state [race 'Zerg] [personality SCARLETT-CREEP-SWARM-PERSONALITY])
  (mastermind-state
   race
   personality
   'standard-macro
   (case race
     [(Zerg zerg) 'zergling]
     [(Protoss protoss) 'zealot]
     [(Terran terran) 'marine]
     [else 'zergling])
   'hold-macro-neutral
   0
   0
   'lanchester-army-critical-mass))

(define (step-double-reaction! mstate
                               #:fap-score [fap-score 0]
                               #:enemy-units [enemy-units '()]
                               #:ally-buildings [ally-buildings '()]
                               #:self-workers [self-workers 16]
                               #:enemy-workers [enemy-workers 16]
                               #:self-army [self-army 200]
                               #:enemy-army [enemy-army 200])
  (define arch (classify-enemy-archetype enemy-units))
  (set-mastermind-state-enemy-archetype! mstate arch)
  (define tree (get-race-counter-tree (mastermind-state-race mstate)))
  (define pull (resolve-demand-pull tree arch ally-buildings))
  (set-mastermind-state-selected-unit! mstate (hash-ref pull 'selected-unit))
  (define ledger
    (evaluate-compounding-ledger #:self-workers self-workers
                                 #:enemy-workers enemy-workers
                                 #:self-army self-army
                                 #:enemy-army enemy-army
                                 #:fap-score fap-score))
  (set-mastermind-state-compounding-dominant!
   mstate (hash-ref ledger 'dominant-driver))
  ;; Double reaction triggers when fap-score < -15 OR enemy archetype is lurker-contain
  (cond
    [(or (< fap-score -15) (eq? arch 'lurker-contain))
     (set-mastermind-state-double-reactions!
      mstate (max 1 (mastermind-state-double-reactions mstate)))
     (set-mastermind-state-flank-angle-idx!
      mstate (max 1 (mastermind-state-flank-angle-idx mstate)))
     (set-mastermind-state-directive! mstate 'retreat-and-regroup)]
    [else
     (set-mastermind-state-directive!
      mstate (hash-ref ledger 'recommended-directive))])
  mstate)

;; =============================================================================
;; 5. Refractory Ability Cast Limiter
;; =============================================================================

(define MACRO-EXEMPT-SPELLS
  '(inject-larva
    calldown-mule
    chrono-boost
    spawn-creep-tumor
    spread-creep-tumor
    cancel))

(struct ability-cast-limiter
  (max-combat-spells-per-frame
   refractory-frames
   last-cast-by-unit
   throttled-count)
  #:mutable
  #:transparent)

(define (make-ability-cast-limiter #:max-per-frame [max-per-frame 1]
                                   #:refractory-frames [refractory-frames 24])
  (ability-cast-limiter max-per-frame refractory-frames (make-hash) 0))

;; Filters action list so combat spells respect `max-combat-spells-per-frame`
;; and per-(caster-id . ability-sym) refractory cooldowns, while MACRO-EXEMPT-SPELLS pass unimpeded!
(define (throttle-ability-casts! limiter actions [frame 0])
  (define max-combat (ability-cast-limiter-max-combat-spells-per-frame limiter))
  (define refrac (ability-cast-limiter-refractory-frames limiter))
  (define unit-last (ability-cast-limiter-last-cast-by-unit limiter))
  (define combat-casts-this-frame 0)
  (define throttled 0)
  (define (handle-cast act caster-id spell)
    (cond
      [(memq spell MACRO-EXEMPT-SPELLS)
       #t]
      [else
       (define key (cons caster-id spell))
       (define prev-f (hash-ref unit-last key -9999))
       (cond
         [(and (< combat-casts-this-frame max-combat)
               (>= (- frame prev-f) refrac))
          (set! combat-casts-this-frame (add1 combat-casts-this-frame))
          (hash-set! unit-last key frame)
          #t]
         [else
          (set! throttled (add1 throttled))
          #f])]))
  (define kept
    (for/fold ([acc '()])
              ([act (in-list actions)])
      (match act
        [(list (or 'cast 'cast-spell 'use-ability) caster-id spell _ ...)
         (if (handle-cast act caster-id spell)
             (cons act acc)
             acc)]
        [(list 'inject-larva caster-id _ ...)
         (if (handle-cast act caster-id 'inject-larva)
             (cons act acc)
             acc)]
        [_ (cons act acc)])))
  (set-ability-cast-limiter-throttled-count! limiter throttled)
  (values (reverse kept) throttled))

;; =============================================================================
;; 6. PDA (Perception -> Decision -> Action) Diagnostic Triangulation
;; =============================================================================

(struct pda-trace
  (scouted-sectors
   posture-switches-window
   actions-emitted
   actions-throttled-or-dropped)
  #:transparent)

(define (make-pda-trace #:scouted-sectors [scouted 8]
                        #:posture-switches [switches 1]
                        #:actions-emitted [emitted 10]
                        #:actions-dropped [dropped 0])
  (pda-trace scouted switches emitted dropped))

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
