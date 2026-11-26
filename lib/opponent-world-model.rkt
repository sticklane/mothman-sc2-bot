#lang racket/base

;; =============================================================================
;; Holistic Constraint-Narrowing Opponent World Model (`lib/opponent-world-model.rkt`)
;;
;; Models what a rational StarCraft II opponent *could* have across all 6 dimensions:
;;   1. Bases & Expansion Pad Sightings (`Confirmed-Base` | `Confirmed-Empty(t)` | `Unscouted`)
;;   2. Geysers, Gas Timings & Exact Vespene Depletion Anchors (`2250 - vespene_contents`)
;;   3. Worker Trajectory & Cumulative Resource Integral (`M_cum(t), G_cum(t)`) — without
;;      needing to see enemy workers mining!
;;   4. Tech & Upgrade DAG Closure (observed buildings/units/spells + weapon/armor/shield
;;      upgrade levels + active structure research, persisted across fog until destroyed)
;;   5. Production Throughput & Happy-Path Deviation Meta:
;;      - Macroing/expanding along the pro happy path is the default.
;;      - Stopping expansions (`B_opp < B*_happy(t)`) means the opponent is deliberately
;;        funneling saved TownHall + worker resources + ongoing income into Army/Tech
;;        (never plan for "opponent is just bad"; if they are bad, playing sound defense +
;;        our own macro game wins automatically).
;;      - Unaccounted minerals/gas (`M_cum - SunkCosts`, `G_cum - SunkCosts`) are treated
;;        as potentially threatening unseen Army/Tech narrowed by gas ratio & tech DAG.
;;   6. Persistent Tag Registry & Spatio-Temporal Reachability Cones + Free-Summon Split
;;      (`locust`, `broodling`, `auto-turret`, `hallucination`, `changeling` separated from
;;      standing army value so temporary summons trigger lifespan kiting + cooldown punish).
;; =============================================================================

(require racket/list
         racket/math
         racket/flonum
         racket/set
         "sc2-game-constants.rkt")

(provide (struct-out tracked-enemy-unit)
         (struct-out tracked-enemy-bldg)
         (struct-out pad-belief-entry)
         (struct-out opponent-world-summary)
         (struct-out opponent-world-model)
         opponent-world-summary-enemy-workers-near-us
         opponent-world-summary-early-worker-rush-active?
         opponent-world-summary-rush-posterior-floor
         owm-home-prod-count
         owm-home-tech-count
         owm-scouted-enemy-main?
         owm-early-pool-latched?
         owm-enemy-1base-double-gas?
         owm-inferred-proxy-rush-floor
         make-opponent-world-model
         reset-opponent-world-model!
         free-summon-unit-sym?
         happy-path-expected-bases
         apply-worker-rush-posterior-floor
         step-opponent-world-model!)

;; -----------------------------------------------------------------------------
;; 1. Core Data Structures
;; -----------------------------------------------------------------------------

(struct tracked-enemy-unit
  (tag
   type
   x
   y
   hp
   last-seen-frame
   speed-tps
   supply
   min-cost
   gas-cost)
  #:transparent)

(struct tracked-enemy-bldg
  (tag
   type
   canon-type
   x
   y
   hp
   build-progress
   start-frame
   ready-frame
   vespene-contents
   active?
   is-proxy?
   last-seen-frame
   min-cost
   gas-cost)
  #:transparent)

(struct pad-belief-entry
  (label               ; 'enemy-main | 'enemy-natural | 'enemy-third | 'enemy-fourth
   x
   y
   state               ; 'confirmed-base | 'confirmed-empty | 'unscouted
   base-tag            ; integer or #f
   last-cleared-frame  ; integer (-9999 if never cleared)
   last-seen-frame)    ; integer (-9999 if never seen)
  #:mutable
  #:transparent)

(struct opponent-world-summary
  (frame
   enemy-race
   confirmed-bases
   confirmed-geysers
   happy-expected-bases
   estimated-workers
   workers-killed
   stopped-expanding?
   unscouted-expansion-ambiguity?
   confirmed-early-greed?
   urgent-scout-pad              ; (cons x y) or #f
   cum-minerals-mined
   cum-gas-mined
   sunk-econ-min
   sunk-tech-min
   sunk-tech-gas
   destroyed-min
   destroyed-gas
   known-army-supply
   known-army-value
   unaccounted-minerals
   unaccounted-gas
   believed-total-army-supply
   believed-total-army-value
   imminent-reachable-supply
   production-facility-count
   hidden-gas-tech-risk?
   requires-anti-air?
   requires-detection?
   locust-wave-active?
   swarm-host-cooldown-window?
   active-summon-count
   enemy-siege-or-turtle-count
   known-unit-counts             ; immutable hasheq: sym -> count
   known-bldg-counts)            ; immutable hasheq: canon-sym -> count
  #:transparent)

;; L48-WR: ABI-preserving weak side-tables for early worker-rush tracking
;; (keeps `opponent-world-summary` at 35 fields and `opponent-world-model` unchanged
;; so existing compiled `.zo` dependents never suffer struct-arity linklet mismatches!).
(define owm-summary-worker-rush-table (make-weak-hasheq))
(define owm-last-worker-rush-frame-table (make-weak-hasheq))

;; L85 Gap B: ABI-preserving weak side-tables for remembered enemy main-scout,
;; home prod/tech counts, early-pool latch, 1-base double-gas, and inferred proxy rush floor.
;; Vector layout: #(home-prod-cnt home-tech-cnt scouted-main? early-pool-latched?
;;                  enemy-1base-double-gas? inferred-proxy-rush-floor)
(define owm-proxy-state-table (make-weak-hasheq))
(define owm-summary-proxy-state-table (make-weak-hasheq))

(define (owm-proxy-state-vec x)
  (cond
    [(opponent-world-model? x) (hash-ref owm-proxy-state-table x #f)]
    [(opponent-world-summary? x) (hash-ref owm-summary-proxy-state-table x #f)]
    [else #f]))

(define (owm-home-prod-count x)
  (define v (owm-proxy-state-vec x))
  (if (vector? v) (vector-ref v 0) 0))

(define (owm-home-tech-count x)
  (define v (owm-proxy-state-vec x))
  (if (vector? v) (vector-ref v 1) 0))

(define (owm-scouted-enemy-main? x)
  (define v (owm-proxy-state-vec x))
  (and (vector? v) (vector-ref v 2) #t))

(define (owm-early-pool-latched? x)
  (define v (owm-proxy-state-vec x))
  (and (vector? v) (vector-ref v 3) #t))

(define (owm-enemy-1base-double-gas? x)
  (define v (owm-proxy-state-vec x))
  (and (vector? v) (vector-ref v 4) #t))

(define (owm-inferred-proxy-rush-floor x)
  (define v (owm-proxy-state-vec x))
  (if (vector? v) (vector-ref v 5) 0.0))

(define (opponent-world-summary-enemy-workers-near-us s)
  (define rec (and (opponent-world-summary? s) (hash-ref owm-summary-worker-rush-table s #f)))
  (if (vector? rec) (vector-ref rec 0) 0))

(define (opponent-world-summary-early-worker-rush-active? s)
  (define rec (and (opponent-world-summary? s) (hash-ref owm-summary-worker-rush-table s #f)))
  (and (vector? rec) (vector-ref rec 1) #t))

(define (opponent-world-summary-rush-posterior-floor s)
  (define rec (and (opponent-world-summary? s) (hash-ref owm-summary-worker-rush-table s #f)))
  (if (vector? rec) (vector-ref rec 2) 0.0))

(struct opponent-world-model
  (enemy-race
   known-units                   ; mutable hasheqv: tag -> tracked-enemy-unit
   known-bldgs                   ; mutable hasheqv: tag -> tracked-enemy-bldg
   dead-tags                     ; mutable seteqv of confirmed dead tags
   implied-tech-set              ; mutable seteq of implied tech building symbols
   destroyed-tech-set            ; mutable seteq of confirmed destroyed tech symbols
   observed-upgrades-set         ; mutable seteq of inferred/observed upgrade symbols
   max-atk-upg                   ; exact nonnegative integer (0..3)
   max-arm-upg                   ; exact nonnegative integer (0..3)
   max-shd-upg                   ; exact nonnegative integer (0..3)
   confirmed-destroyed-min       ; exact nonnegative integer (units + structures killed)
   confirmed-destroyed-gas       ; exact nonnegative integer
   expired-sunk-min              ; exact nonnegative integer (aged-out unseen units)
   expired-sunk-gas              ; exact nonnegative integer
   workers-killed                ; exact nonnegative integer
   pads                          ; list of pad-belief-entry
   pads-initialized?             ; boolean
   last-locust-wave-frame        ; integer (-9999 if none)
   last-frame                    ; integer
   last-summary)                 ; opponent-world-summary or #f
  #:mutable
  #:transparent)

(define (make-opponent-world-model [enemy-race 'Unknown])
  (define owm
    (opponent-world-model
     enemy-race
     (make-hasheqv)
     (make-hasheqv)
     (mutable-seteqv)
     (mutable-seteq)
     (mutable-seteq)
     (mutable-seteq)
     0 0 0
     0 0
     0 0
     0
     '()
     #f
     -9999
     -1
     #f))
  (hash-set! owm-last-worker-rush-frame-table owm -9999)
  (hash-set! owm-proxy-state-table owm (vector 0 0 #f #f #f 0.0 'none 0.0 -9999))
  owm)

(define (reset-opponent-world-model! owm [enemy-race 'Unknown])
  (set-opponent-world-model-enemy-race! owm enemy-race)
  (hash-clear! (opponent-world-model-known-units owm))
  (hash-clear! (opponent-world-model-known-bldgs owm))
  (set-clear! (opponent-world-model-dead-tags owm))
  (set-clear! (opponent-world-model-implied-tech-set owm))
  (set-clear! (opponent-world-model-destroyed-tech-set owm))
  (set-clear! (opponent-world-model-observed-upgrades-set owm))
  (set-opponent-world-model-max-atk-upg! owm 0)
  (set-opponent-world-model-max-arm-upg! owm 0)
  (set-opponent-world-model-max-shd-upg! owm 0)
  (set-opponent-world-model-confirmed-destroyed-min! owm 0)
  (set-opponent-world-model-confirmed-destroyed-gas! owm 0)
  (set-opponent-world-model-expired-sunk-min! owm 0)
  (set-opponent-world-model-expired-sunk-gas! owm 0)
  (set-opponent-world-model-workers-killed! owm 0)
  (set-opponent-world-model-pads! owm '())
  (set-opponent-world-model-pads-initialized?! owm #f)
  (set-opponent-world-model-last-locust-wave-frame! owm -9999)
  (set-opponent-world-model-last-frame! owm -1)
  (set-opponent-world-model-last-summary! owm #f)
  (hash-set! owm-last-worker-rush-frame-table owm -9999)
  (hash-set! owm-proxy-state-table owm (vector 0 0 #f #f #f 0.0 'none 0.0 -9999))
  owm)

;; Prevents premature rush-posterior decay (e.g. 0.91 -> 0.45 at 137.5s) while >= 4
;; enemy workers remain actively attacking/threatening our base during an early worker rush,
;; AND applies Loop 85 remembered proxy / 1-base double-gas / latched early-pool rush floor.
(define (apply-worker-rush-posterior-floor raw-rush-prob owm-sum)
  (define base-p (if (real? raw-rush-prob) (exact->inexact raw-rush-prob) 0.0))
  (cond
    [(opponent-world-summary? owm-sum)
     (define wr-floor
       (if (opponent-world-summary-early-worker-rush-active? owm-sum)
           (opponent-world-summary-rush-posterior-floor owm-sum)
           0.0))
     (define proxy-floor (owm-inferred-proxy-rush-floor owm-sum))
     (max base-p wr-floor proxy-floor)]
    [(opponent-world-model? owm-sum)
     (max base-p (owm-inferred-proxy-rush-floor owm-sum))]
    [else base-p]))

;; -----------------------------------------------------------------------------
;; 2. Domain Constants: Summons, Speeds, Build Times, DAG Prereqs & Happy Path
;; -----------------------------------------------------------------------------

(define FREE-SUMMON-SET
  (hasheq 'locust #t 'locust-mp #t 'locustmp #t 'locust-flying #t 'locust-precursor #t
          'locustmpprecursor #t 'broodling #t 'broodling-escort #t 'auto-turret #t
          'autoturret #t 'changeling #t 'changeling-zealot #t 'changeling-marine #t
          'changeling-marine-shield #t 'changeling-zergling #t 'changeling-zergling-wings #t
          'oracle-stasis-trap #t 'stasis-ward #t 'force-field #t 'mule #t
          'larva #t 'egg #t 'cocoon #t 'baneling-cocoon #t 'ravager-cocoon #t
          'lurker-egg #t 'brood-lord-cocoon #t 'overlord-cocoon #t))

(define (free-summon-unit-sym? sym)
  (hash-has-key? FREE-SUMMON-SET sym))

(define LOCUST-SUMMON-SET
  (hasheq 'locust #t 'locust-mp #t 'locustmp #t 'locust-flying #t
          'locust-precursor #t 'locustmpprecursor #t))

(define NONCOMBAT-UNIT-SET
  (hasheq 'drone #t 'probe #t 'scv #t 'overlord #t 'overseer #t 'observer #t
          'overlord-transport #t 'dropperlord #t 'warp-prism #t 'warp-prism-phasing #t
          'medivac #t))

(define WORKER-SYM-SET
  (hasheq 'drone #t 'probe #t 'scv #t 'drone-burrowed #t))

(define TOWNHALL-SYM-SET
  (hasheq 'hatchery #t 'lair #t 'hive #t
          'nexus #t
          'command-center #t 'orbital-command #t 'planetary-fortress #t
          'command-center-flying #t 'orbital-command-flying #t))

(define GEYSER-BLDG-SYM-SET
  (hasheq 'extractor #t 'extractor-rich #t
          'assimilator #t 'assimilator-rich #t
          'refinery #t 'refinery-rich #t))

(define PROD-FACILITY-SYM-SET
  (hasheq 'barracks #t 'factory #t 'starport #t
          'gateway #t 'warp-gate #t 'robotics-facility #t 'stargate #t))

;; L85 Gap B: Tech structures beyond Gateway/CyberCore, Barracks, or SpawningPool
;; used to distinguish normal in-base tech from off-path Proxy Stargate/Robo/Factory.
(define HOME-TECH-BLDG-SYM-SET
  (hasheq 'twilight-council #t 'robotics-facility #t 'stargate #t 'forge #t
          'robotics-bay #t 'templar-archive #t 'dark-shrine #t 'fleet-beacon #t
          'factory #t 'starport #t 'armory #t 'ghost-academy #t 'engineering-bay #t 'fusion-core #t
          'roach-warren #t 'baneling-nest #t 'lair #t 'hive #t 'spire #t
          'hydralisk-den #t 'infestation-pit #t 'nydus-network #t 'lurker-den #t 'ultralisk-cavern #t))

(define RACE-DETECTION-HT
  (hasheq
   'probe 'Protoss 'zealot 'Protoss 'stalker 'Protoss 'sentry 'Protoss 'adept 'Protoss
   'high-templar 'Protoss 'dark-templar 'Protoss 'archon 'Protoss 'immortal 'Protoss
   'colossus 'Protoss 'disruptor 'Protoss 'void-ray 'Protoss 'carrier 'Protoss 'tempest 'Protoss
   'mothership 'Protoss 'oracle 'Protoss 'phoenix 'Protoss 'observer 'Protoss 'warp-prism 'Protoss
   'nexus 'Protoss 'pylon 'Protoss 'gateway 'Protoss 'warp-gate 'Protoss 'cybernetics-core 'Protoss
   'photon-cannon 'Protoss 'shield-battery 'Protoss 'stargate 'Protoss 'robotics-facility 'Protoss
   'fleet-beacon 'Protoss 'robotics-bay 'Protoss 'templar-archive 'Protoss 'twilight-council 'Protoss 'dark-shrine 'Protoss
   'scv 'Terran 'marine 'Terran 'marauder 'Terran 'reaper 'Terran 'ghost 'Terran
   'hellion 'Terran 'hellbat 'Terran 'widow-mine 'Terran 'cyclone 'Terran 'siege-tank 'Terran
   'siege-tank-sieged 'Terran 'thor 'Terran 'viking 'Terran 'viking-fighter 'Terran
   'viking-assault 'Terran 'medivac 'Terran 'liberator 'Terran 'raven 'Terran
   'banshee 'Terran 'battlecruiser 'Terran 'mule 'Terran
   'command-center 'Terran 'orbital-command 'Terran 'planetary-fortress 'Terran
   'supply-depot 'Terran 'barracks 'Terran 'factory 'Terran 'armory 'Terran
   'starport 'Terran 'fusion-core 'Terran 'bunker 'Terran 'missile-turret 'Terran 'ghost-academy 'Terran
   'drone 'Zerg 'zergling 'Zerg 'baneling 'Zerg 'queen 'Zerg 'roach 'Zerg 'ravager 'Zerg
   'hydralisk 'Zerg 'lurker 'Zerg 'mutalisk 'Zerg 'corruptor 'Zerg 'ultralisk 'Zerg
   'brood-lord 'Zerg 'viper 'Zerg 'infestor 'Zerg 'swarm-host 'Zerg 'overlord 'Zerg 'overseer 'Zerg
   'locust 'Zerg 'locust-mp 'Zerg 'broodling 'Zerg
   'hatchery 'Zerg 'lair 'Zerg 'hive 'Zerg 'extractor 'Zerg
   'spawning-pool 'Zerg 'roach-warren 'Zerg 'baneling-nest 'Zerg 'hydralisk-den 'Zerg 'lurker-den 'Zerg
   'spire 'Zerg 'greater-spire 'Zerg 'infestation-pit 'Zerg 'ultralisk-cavern 'Zerg
   'spine-crawler 'Zerg 'spore-crawler 'Zerg))

(define (unit-type-sym u)
  (if (hash? u)
      (let ([t (hash-ref u 'type 'unknown)])
        (if (symbol? t) t 'unknown))
      'unknown))

(define (unit-speed-tps sym)
  (case sym
    [(zergling reaper hellion mutalisk phoenix oracle banshee) 5.6]
    [(stalker adept roach hydralisk marine marauder medivac warp-prism corruptor void-ray viking-fighter) 4.2]
    [(siege-tank immortal colossus archon thor ultralisk lurker ravager queen zealot) 3.15]
    [(carrier tempest battlecruiser brood-lord mothership) 2.65]
    [else 3.8]))

;; Approximate LotV structure build durations in game loops (22.4 loops/sec)
(define (structure-build-frames canon-sym)
  (case canon-sym
    [(hatchery nexus command-center) 1590] ; ~71s
    [(orbital-command) 560]                ; ~25s
    [(lair) 1277]                          ; ~57s
    [(hive) 1590]                          ; ~71s
    [(extractor assimilator refinery) 470] ; ~21s
    [(spawning-pool barracks gateway) 1030]; ~46s
    [(cybernetics-core roach-warren) 806]  ; ~36s
    [(factory starport robotics-facility stargate twilight-council) 963] ; ~43s
    [(spire robotics-bay fleet-beacon fusion-core infestation-pit) 1030]
    [else 784]))

(define (implied-tech-prereqs sym)
  (case sym
    [(zergling queen spine-crawler spore-crawler) '(spawning-pool)]
    [(baneling baneling-nest) '(spawning-pool baneling-nest extractor)]
    [(roach ravager roach-warren) '(spawning-pool roach-warren extractor)]
    [(hydralisk hydralisk-den) '(spawning-pool lair hydralisk-den extractor)]
    [(lurker lurker-mp lurker-burrowed lurker-den lurker-den-mp) '(spawning-pool lair hydralisk-den lurker-den extractor)]
    [(mutalisk corruptor spire) '(spawning-pool lair spire extractor)]
    ;; L43-P0-2a (`PolyMorph T` 141-tick Viking leak): NEVER infer `greater-spire` from `broodling` —
    ;; every destroyed Zerg structure spawns death Broodlings in SC2!
    [(brood-lord broodlord greater-spire) '(spawning-pool lair infestation-pit hive spire greater-spire extractor)]
    [(swarm-host swarm-host-burrowed locust locust-mp locust-flying infestor) '(spawning-pool lair infestation-pit extractor)]
    [(viper) '(spawning-pool lair infestation-pit hive extractor)]
    [(ultralisk ultralisk-cavern) '(spawning-pool lair infestation-pit hive ultralisk-cavern extractor)]
    [(marine) '(barracks)]
    [(reaper) '(barracks refinery)]
    [(marauder ghost) '(barracks barracks-techlab refinery)]
    [(hellion hellbat widow-mine widow-mine-burrowed cyclone) '(barracks factory refinery)]
    [(siege-tank siege-tank-sieged) '(barracks factory factory-techlab refinery)]
    [(thor) '(barracks factory factory-techlab armory refinery)]
    [(medivac viking viking-fighter viking-assault liberator liberator-ag) '(barracks factory starport refinery)]
    [(banshee raven auto-turret) '(barracks factory starport starport-techlab refinery)]
    [(battlecruiser) '(barracks factory starport starport-techlab fusion-core refinery)]
    [(zealot) '(gateway)]
    [(stalker adept sentry warp-gate) '(gateway cybernetics-core assimilator)]
    [(observer warp-prism warp-prism-phasing immortal) '(gateway cybernetics-core robotics-facility assimilator)]
    [(colossus disruptor) '(gateway cybernetics-core robotics-facility robotics-bay assimilator)]
    [(oracle phoenix void-ray voidray) '(gateway cybernetics-core stargate assimilator)]
    [(carrier tempest mothership) '(gateway cybernetics-core stargate fleet-beacon assimilator)]
    [(high-templar archon) '(gateway cybernetics-core twilight-council templar-archive assimilator)]
    [(dark-templar) '(gateway cybernetics-core twilight-council dark-shrine assimilator)]
    [else '()]))

;; Empirically calibrated pro happy-path base schedule (22.4 loops/sec):
;; Past these deadlines, a rational macro player has STARTED their 2nd / 3rd / 4th base.
;; If they have NOT, they are deviating from the happy path to invest in Army / Tech!
(define (happy-path-expected-bases enemy-race frame)
  (define sec (/ (exact->inexact (max 0 frame)) 22.4))
  (case enemy-race
    [(Zerg)
     (cond [(>= sec 420.0) 4]
           [(>= sec 215.0) 3]
           [(>= sec 78.0)  2]
           [else           1])]
    [(Protoss)
     (cond [(>= sec 540.0) 4]
           [(>= sec 355.0) 3]
           [(>= sec 120.0) 2]
           [else           1])]
    [else ; Terran / Unknown
     (cond [(>= sec 570.0) 4]
           [(>= sec 375.0) 3]
           [(>= sec 135.0) 2]
           [else           1])]))

;; -----------------------------------------------------------------------------
;; 3. Cumulative Resource Integrator (No Worker Visibility Required!)
;; -----------------------------------------------------------------------------
;; Integrates opponent mineral & gas collection from `0 .. frame` given their
;; active/inferred base ready frames, geyser ready frames (+ exact depletion
;; overrides when geyser `vespene-contents` was observed!), and worker kills.
;; Returns 5 values:
;;   1. `cum-min`         : calibrated cumulative minerals mined (LotV 22.4 loops/sec)
;;   2. `cum-gas`         : cumulative gas mined from confirmed/implied geysers (+ depletion anchors)
;;   3. `est-unobs-gas`   : estimated gas mined by baseline unobserved gas workers (conserved for
;;                          army-value estimation without triggering false hidden-gas-tech-risk!)
;;   4. `est-workers`     : estimated alive workers
;;   5. `est-workers-born`: estimated cumulative workers produced
(define (integrate-opponent-economy enemy-race frame base-ready-frames geyser-entries workers-killed)
  (define f-sec (/ (exact->inexact (max 0 frame)) 22.4))
  (define w-cap-race
    (case enemy-race
      [(Zerg) 68.0]
      [(Protoss) 66.0]
      [else 62.0]))
  (define w-rate-mult
    (case enemy-race
      ;; Zerg shares Larva across Drones/Overlords/Army and consumes Drones into structures,
      ;; so net sustained worker growth is lower than parallel Nexus/CC production.
      [(Zerg) 0.88]
      [(Protoss) 0.96]
      [else 0.90]))
  ;; Separate geysers with exact observed vespene depletion (`2250 - vespene_contents` at `t_seen`)
  ;; from geysers estimated purely by ready-frame integration!
  (define geyser-ready-secs
    (for/list ([ge (in-list geyser-entries)])
      (/ (exact->inexact (car ge)) 22.4)))
  (let loop ([s 0.0] [w 12.0] [w-born 12.0] [cum-m 50.0] [cum-g-rate 0.0] [cum-g-unobs 0.0])
    (if (>= s f-sec)
        (let* ([eff-w (max 4 (exact-round (- w (min (- w 4.0) (exact->inexact workers-killed)))))]
               ;; Reconcile gas against exact observed geyser depletion anchors when available!
               [anchored-gas
                (for/sum ([ge (in-list geyser-entries)])
                  (define rdy-s (/ (exact->inexact (car ge)) 22.4))
                  (define seen-s (/ (exact->inexact (cadr ge)) 22.4))
                  (define v-rem (caddr ge))
                  (cond
                    [(and (exact-integer? v-rem) (> v-rem 0) (<= v-rem 2250))
                     ;; Exact gas mined up to `seen-s` is `2250 - v-rem`, plus rate after `seen-s`!
                     (define mined-at-seen (max 0 (- 2250 v-rem)))
                     (define post-sec (max 0.0 (- f-sec seen-s)))
                     (min 2250 (+ mined-at-seen (exact-round (* 1.92 post-sec))))]
                    [(< rdy-s f-sec)
                     (min 2250 (exact-round (* 1.92 (- f-sec rdy-s))))]
                    [else 0]))]
               [final-gas (max (exact-round cum-g-rate) anchored-gas)])
          (values (exact-round cum-m)
                  final-gas
                  (exact-round cum-g-unobs)
                  eff-w
                  (exact-round w-born)))
        (let* ([dt (min 5.0 (- f-sec s))]
               [b (max 1 (count (lambda (rf) (<= (/ (exact->inexact rf) 22.4) s)) base-ready-frames))]
               [g (min (* 2 b) (count (lambda (gs) (<= gs s)) geyser-ready-secs))]
               ;; Account for realistic baseline gas-worker allocation even before geysers are scouted,
               ;; conserving their output in `cum-g-unobs` instead of over-crediting mineral income!
               [baseline-g (if (< s 68.0) 0.0 (min (* 2.0 b) (/ (- s 68.0) 105.0)))]
               [eff-g (max (exact->inexact g) baseline-g)]
               [sat-cap (min w-cap-race (+ (* 16.0 b) (* 3.0 eff-g) 2.0))]
               ;; Opening worker-production efficiency ramp (supply/tech/expand build windows)
               [ramp-eff (cond [(< s 90.0) 0.82] [(< s 180.0) 0.92] [else 1.00])]
               [dw (max 0.0 (min (- sat-cap w) (* dt ramp-eff w-rate-mult (/ (min 3.0 (exact->inexact b)) 12.0))))]
               [w-next (+ w dw)]
               [w-mid (max 4.0 (- (* 0.5 (+ w w-next))
                                  (if (>= s (* 0.5 f-sec)) (* 0.5 (exact->inexact workers-killed)) 0.0)))]
               [wg-tot (max 0.0 (min (* 3.0 eff-g) (- w-mid 10.0)))]
               [wg-conf (max 0.0 (min (* 3.0 g) (- w-mid 8.0)))]
               [wg-unobs (max 0.0 (- wg-tot wg-conf))]
               [wm (max 0.0 (- w-mid wg-tot))]
               [wm-opt (min wm (* 16.0 b))]
               [wm-ovr (max 0.0 (min (- wm wm-opt) (* 6.0 b)))]
               ;; Terran Orbitals morph ~120s for main and ~30s after extra CCs complete (max 3; ~1.7 M/s net of Scans/delays)
               [orbital-cnt
                (if (eq? enemy-race 'Terran)
                    (min 3 (count (lambda (rf)
                                    (define rsec (/ (exact->inexact rf) 22.4))
                                    (<= (if (<= rsec 1.0) 120.0 (+ rsec 30.0)) s))
                                  base-ready-frames))
                    0)]
               [mule-bonus (* 1.7 (exact->inexact orbital-cnt))]
               ;; Empirically calibrated LotV real-time (22.4 loops/sec) mineral rate:
               ;; 0 for opening 5s walk; 0.84 min/mineral-worker-sec tapering to 0.76 late (patch depletion/transfers),
               ;; 0.38 oversaturated, 0.64 gas/worker-sec (~1.92/geyser-sec).
               [opt-rate
                (cond
                  [(< s 5.0) 0.0]
                  [(<= s 420.0) 0.84]
                  [else (max 0.76 (- 0.84 (* 0.08 (/ (- s 420.0) 360.0))))])]
               [dm (* dt (+ (* opt-rate wm-opt) (* 0.38 wm-ovr) mule-bonus))]
               [dg-conf (* dt 0.64 wg-conf)]
               [dg-unobs (* dt 0.64 wg-unobs)])
          (loop (+ s dt) w-next (+ w-born dw) (+ cum-m dm) (+ cum-g-rate dg-conf) (+ cum-g-unobs dg-unobs))))))

;; -----------------------------------------------------------------------------
;; 4. Main Step Update (`step-opponent-world-model!`)
;; -----------------------------------------------------------------------------

(define (dist2 x1 y1 x2 y2)
  (define dx (- (exact->inexact x1) (exact->inexact x2)))
  (define dy (- (exact->inexact y1) (exact->inexact y2)))
  (+ (* dx dx) (* dy dy)))

(define (ally-sees-point? ally-units px py [r2 81.0])
  (for/or ([u (in-list ally-units)])
    (and (hash? u)
         (<= (dist2 (hash-ref u 'x -999.0) (hash-ref u 'y -999.0) px py) r2))))

(define (step-opponent-world-model! owm raw-obs)
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define frame (max 0 (let ([f (hash-ref obs 'frame 0)]) (if (exact-integer? f) f (exact-round f)))))
  ;; Reset cleanly if reused across matches (`frame < last-frame`)
  (when (and (>= (opponent-world-model-last-frame owm) 0)
             (< frame (opponent-world-model-last-frame owm)))
    (reset-opponent-world-model! owm (hash-ref obs 'enemy-race 'Unknown)))
  (set-opponent-world-model-last-frame! owm frame)

  (define ally-units (let ([xs (hash-ref obs 'ally-units '())]) (if (list? xs) xs '())))
  (define enemy-units (let ([xs (hash-ref obs 'enemy-units '())]) (if (list? xs) xs '())))
  (define enemy-bldgs (let ([xs (hash-ref obs 'enemy-buildings '())]) (if (list? xs) xs '())))
  (define dead-tags-now (let ([xs (hash-ref obs 'dead-unit-tags '())]) (if (list? xs) xs '())))

  (define base-x (exact->inexact (hash-ref obs 'base-x 32.0)))
  (define base-y (exact->inexact (hash-ref obs 'base-y 32.0)))
  (define nat-x (exact->inexact (hash-ref obs 'natural-x 50.0)))
  (define nat-y (exact->inexact (hash-ref obs 'natural-y 50.0)))
  (define enemy-x (exact->inexact (hash-ref obs 'enemy-x 160.0)))
  (define enemy-y (exact->inexact (hash-ref obs 'enemy-y 160.0)))
  (define enemy-nat-x (exact->inexact (hash-ref obs 'enemy-exp-x (hash-ref obs 'enemy-expand-x (* 0.85 enemy-x)))))
  (define enemy-nat-y (exact->inexact (hash-ref obs 'enemy-exp-y (hash-ref obs 'enemy-expand-y (* 0.85 enemy-y)))))
  (define enemy-third-x (exact->inexact (hash-ref obs 'enemy-third-x (* 0.72 enemy-x))))
  (define enemy-third-y (exact->inexact (hash-ref obs 'enemy-third-y (* 0.72 enemy-y))))
  (define enemy-fourth-x (exact->inexact (hash-ref obs 'enemy-fourth-x (* 0.62 enemy-x))))
  (define enemy-fourth-y (exact->inexact (hash-ref obs 'enemy-fourth-y (* 0.62 enemy-y))))

  ;; Initialize (or re-anchor if enemy spawn moved on multi-spawn map) 4 primary opponent expansion pads
  (define cur-pads (opponent-world-model-pads owm))
  (when (or (not (opponent-world-model-pads-initialized? owm))
            (null? cur-pads)
            (> (dist2 enemy-x enemy-y
                      (pad-belief-entry-x (car cur-pads))
                      (pad-belief-entry-y (car cur-pads)))
               144.0))
    (set-opponent-world-model-pads!
     owm
     (list (pad-belief-entry 'enemy-main enemy-x enemy-y 'confirmed-base -1 -9999 0)
           (pad-belief-entry 'enemy-natural enemy-nat-x enemy-nat-y 'unscouted #f -9999 -9999)
           (pad-belief-entry 'enemy-third enemy-third-x enemy-third-y 'unscouted #f -9999 -9999)
           (pad-belief-entry 'enemy-fourth enemy-fourth-x enemy-fourth-y 'unscouted #f -9999 -9999)))
    (set-opponent-world-model-pads-initialized?! owm #t))

  ;; Detect / refine enemy race from obs or any observed enemy entity
  (define obs-erace (hash-ref obs 'enemy-race #f))
  (when (and (memq obs-erace '(Zerg Terran Protoss))
             (not (memq (opponent-world-model-enemy-race owm) '(Zerg Terran Protoss))))
    (set-opponent-world-model-enemy-race! owm obs-erace))
  (unless (memq (opponent-world-model-enemy-race owm) '(Zerg Terran Protoss))
    (define det
      (or (for/or ([u (in-list enemy-units)]) (hash-ref RACE-DETECTION-HT (unit-type-sym u) #f))
          (for/or ([b (in-list enemy-bldgs)]) (hash-ref RACE-DETECTION-HT (unit-type-sym b) #f))))
    (when det (set-opponent-world-model-enemy-race! owm det)))
  (define erace (opponent-world-model-enemy-race owm))

  (define known-units (opponent-world-model-known-units owm))
  (define known-bldgs (opponent-world-model-known-bldgs owm))
  (define dead-tags (opponent-world-model-dead-tags owm))
  (define implied-set (opponent-world-model-implied-tech-set owm))
  (define destroyed-tech (opponent-world-model-destroyed-tech-set owm))

  ;; Step A: Process explicit `dead-unit-tags` from wire
  (for ([dtag (in-list dead-tags-now)]
        #:when (and (exact-integer? dtag) (> dtag 0) (not (set-member? dead-tags dtag))))
    (set-add! dead-tags dtag)
    (cond
      [(hash-has-key? known-units dtag)
       (define rec (hash-ref known-units dtag))
       (hash-remove! known-units dtag)
       (set-opponent-world-model-confirmed-destroyed-min!
        owm (+ (opponent-world-model-confirmed-destroyed-min owm) (tracked-enemy-unit-min-cost rec)))
       (set-opponent-world-model-confirmed-destroyed-gas!
        owm (+ (opponent-world-model-confirmed-destroyed-gas owm) (tracked-enemy-unit-gas-cost rec)))
       (when (hash-has-key? WORKER-SYM-SET (tracked-enemy-unit-type rec))
         (set-opponent-world-model-workers-killed!
          owm (add1 (opponent-world-model-workers-killed owm))))]
      [(hash-has-key? known-bldgs dtag)
       (define rec (hash-ref known-bldgs dtag))
       (hash-remove! known-bldgs dtag)
       (set-add! destroyed-tech (tracked-enemy-bldg-canon-type rec))
       (set-opponent-world-model-confirmed-destroyed-min!
        owm (+ (opponent-world-model-confirmed-destroyed-min owm) (tracked-enemy-bldg-min-cost rec)))
       (set-opponent-world-model-confirmed-destroyed-gas!
        owm (+ (opponent-world-model-confirmed-destroyed-gas owm) (tracked-enemy-bldg-gas-cost rec)))]))

  ;; Step B: Ingest currently observed enemy structures
  (define seen-bldg-tags-now (mutable-seteqv))
  (for ([b (in-list enemy-bldgs)] #:when (hash? b))
    (define tag (hash-ref b 'id 0))
    (define btype (unit-type-sym b))
    (define ctype (sc2-canonical-structure-sym btype))
    (define bx (exact->inexact (hash-ref b 'x enemy-x)))
    (define by (exact->inexact (hash-ref b 'y enemy-y)))
    (define bhp (max 1 (exact-round (hash-ref b 'hp 500))))
    (define bprog (max 0.0 (min 1.0 (exact->inexact (hash-ref b 'build-progress 1.0)))))
    (define vcont (hash-ref b 'vespene-contents 0))
    (define act? (not (not (or (hash-ref b 'active? #f) (hash-ref b 'active #f)))))
    (define prox? (not (not (hash-ref b 'is-proxy? #f))))
    (when (and (exact-integer? tag) (> tag 0) (not (set-member? dead-tags tag)))
      (set-add! seen-bldg-tags-now tag)
      (set-remove! destroyed-tech ctype)
      (for ([p (in-list (implied-tech-prereqs ctype))])
        (set-add! implied-set p))
      (define prev (hash-ref known-bldgs tag #f))
      (define b-frames (structure-build-frames ctype))
      (define start-f
        (cond
          [prev (tracked-enemy-bldg-start-frame prev)]
          [(< bprog 0.995)
           (max 0 (- frame (exact-round (* bprog b-frames))))]
          [else
           ;; Seen already completed: bound earliest start by pad `last-cleared-frame` if near a pad
           (define near-pad
             (for/first ([pd (in-list (opponent-world-model-pads owm))]
                         #:when (<= (dist2 bx by (pad-belief-entry-x pd) (pad-belief-entry-y pd)) 144.0))
               pd))
           (if (and near-pad (> (pad-belief-entry-last-cleared-frame near-pad) 0))
               (pad-belief-entry-last-cleared-frame near-pad)
               (max 0 (- frame b-frames)))]))
      (define ready-f (+ start-f b-frames))
      ;; Preserve lowest observed positive vespene-contents (`snapshot` buildings often report 0)
      (define best-vcont
        (cond
          [(and (exact-integer? vcont) (> vcont 0)) vcont]
          [prev (tracked-enemy-bldg-vespene-contents prev)]
          [else 0]))
      (hash-set! known-bldgs tag
                 (tracked-enemy-bldg tag btype ctype bx by bhp bprog start-f ready-f
                                     best-vcont act? prox? frame
                                     (max 0 (sc2-min-cost ctype))
                                     (max 0 (sc2-gas-cost ctype))))))

  ;; Step C: Sight-clear static structures that disappeared while in our direct footprint vision.
  ;; L85B: Ground scouts walking down an enemy ramp (low ground, `6-8.5t` away in 2D) CANNOT see
  ;; up cliffs into high-ground fog! Require flying sight (`<= 7.0t`, geysers `<= 5.0t`) or direct
  ;; ground footprint overlap (`<= 4.0t`, geysers `<= 3.5t`) so high-ground Refineries/Factories/
  ;; Barracks are NEVER falsely deleted into `dead-tags` when a ground scout retreats down the ramp!
  (define (ally-flying-scout? u)
    (or (eq? (hash-ref u 'flying #f) #t)
        (eq? (hash-ref u 'is-flying #f) #t)
        (not (not (memq (unit-type-sym u)
                        '(overlord overseer overlord-transport dropperlord observer phoenix
                          oracle warp-prism warp-prism-phasing void-ray viking-fighter
                          banshee medivac raven liberator mutalisk corruptor))))))
  (define (ally-can-sight-clear-bldg? rec)
    (define bx (tracked-enemy-bldg-x rec))
    (define by (tracked-enemy-bldg-y rec))
    (define is-geyser? (hash-has-key? GEYSER-BLDG-SYM-SET (tracked-enemy-bldg-canon-type rec)))
    (define fly-r2 (if is-geyser? 25.0 49.0))
    (define gnd-r2 (if is-geyser? 12.25 16.0))
    (for/or ([u (in-list ally-units)] #:when (hash? u))
      (define ux (hash-ref u 'x -999.0))
      (define uy (hash-ref u 'y -999.0))
      (define r2 (if (ally-flying-scout? u) fly-r2 gnd-r2))
      (<= (dist2 ux uy bx by) r2)))
  (for ([kv (in-list (hash->list known-bldgs))])
    (define tag (car kv))
    (define rec (cdr kv))
    (when (and (not (set-member? seen-bldg-tags-now tag))
               (not (memq (tracked-enemy-bldg-type rec)
                          '(barracks-flying factory-flying starport-flying
                            command-center-flying orbital-command-flying
                            spine-crawler-uprooted spore-crawler-uprooted)))
               (ally-can-sight-clear-bldg? rec))
      (hash-remove! known-bldgs tag)
      (set-add! dead-tags tag)
      (set-add! destroyed-tech (tracked-enemy-bldg-canon-type rec))
      (set-opponent-world-model-confirmed-destroyed-min!
       owm (+ (opponent-world-model-confirmed-destroyed-min owm) (tracked-enemy-bldg-min-cost rec)))
      (set-opponent-world-model-confirmed-destroyed-gas!
       owm (+ (opponent-world-model-confirmed-destroyed-gas owm) (tracked-enemy-bldg-gas-cost rec)))))

  ;; Step D: Ingest currently observed enemy units (separating free summons!)
  (define active-summon-cnt 0)
  (define active-locust-cnt 0)
  (define seen-unit-tags-now (mutable-seteqv))

  (for ([u (in-list enemy-units)] #:when (hash? u))
    (define utype (unit-type-sym u))
    (define halluc? (or (hash-ref u 'is-hallucination #f) (hash-ref u 'hallucination #f)))
    (define atk-lvl (hash-ref u 'attack-upgrade-level 0))
    (define arm-lvl (hash-ref u 'armor-upgrade-level 0))
    (define shd-lvl (hash-ref u 'shield-upgrade-level 0))
    (when (and (exact-integer? atk-lvl) (> atk-lvl (opponent-world-model-max-atk-upg owm)))
      (set-opponent-world-model-max-atk-upg! owm atk-lvl))
    (when (and (exact-integer? arm-lvl) (> arm-lvl (opponent-world-model-max-arm-upg owm)))
      (set-opponent-world-model-max-arm-upg! owm arm-lvl))
    (when (and (exact-integer? shd-lvl) (> shd-lvl (opponent-world-model-max-shd-upg owm)))
      (set-opponent-world-model-max-shd-upg! owm shd-lvl))

    (cond
      [(or halluc? (free-summon-unit-sym? utype))
       (set! active-summon-cnt (add1 active-summon-cnt))
       ;; L43-P0-2a: Hallucinations NEVER imply real enemy tech or locust waves!
       (unless halluc?
         (when (hash-has-key? LOCUST-SUMMON-SET utype)
           (set! active-locust-cnt (add1 active-locust-cnt)))
         (for ([p (in-list (implied-tech-prereqs utype))])
           (set-add! implied-set p)))]
      [else
       (define tag (hash-ref u 'id 0))
       (for ([p (in-list (implied-tech-prereqs utype))])
         (set-add! implied-set p))
       (when (and (exact-integer? tag) (> tag 0) (not (set-member? dead-tags tag)))
         (set-add! seen-unit-tags-now tag)
         (define ctype (sc2-canonical-unit-sym utype))
         (define ux (exact->inexact (hash-ref u 'x enemy-x)))
         (define uy (exact->inexact (hash-ref u 'y enemy-y)))
         (define uhp (max 1 (exact-round (hash-ref u 'hp 45))))
         (hash-set! known-units tag
                    (tracked-enemy-unit tag ctype ux uy uhp frame
                                        (unit-speed-tps ctype)
                                        (max 0 (sc2-supply-cost ctype))
                                        (max 0 (sc2-min-cost ctype))
                                        (max 0 (sc2-gas-cost ctype)))))]))

  (when (>= active-locust-cnt 2)
    (set-opponent-world-model-last-locust-wave-frame! owm frame))

  ;; Age out very stale unobserved combat units (`> 2464` frames = `110s`), transferring their sunk cost
  ;; so total mined resources remain accounted for without phantom immortal ghosts forever!
  (for ([kv (in-list (hash->list known-units))])
    (define tag (car kv))
    (define rec (cdr kv))
    (when (and (not (set-member? seen-unit-tags-now tag))
               (> (- frame (tracked-enemy-unit-last-seen-frame rec)) 2464))
      (hash-remove! known-units tag)
      (set-opponent-world-model-expired-sunk-min!
       owm (+ (opponent-world-model-expired-sunk-min owm) (tracked-enemy-unit-min-cost rec)))
      (set-opponent-world-model-expired-sunk-gas!
       owm (+ (opponent-world-model-expired-sunk-gas owm) (tracked-enemy-unit-gas-cost rec)))))

  ;; L48-WR: First-class purely physical early worker-rush detector:
  ;; Count recently observed (<= 5s = 112f) enemy workers within 32t of our main/natural
  ;; and outside the enemy's own base (`> 20t` from enemy main on normal maps).
  ;; When >= 4 enemy workers attack/approach before 2:30 (`< 3360f`) with 0 enemy combat
  ;; units and < 6 ally combat supply, latch `early-worker-rush-active?` so `stopped-expanding?`
  ;; flips immediately AND the rush posterior stays floored at 0.91 (no 137.5s decay!).
  (define map-wide-wr? (> (dist2 base-x base-y enemy-x enemy-y) 1600.0))
  (define (worker-near-our-base? ux uy)
    (define d2-our (min (dist2 ux uy base-x base-y)
                        (dist2 ux uy nat-x nat-y)))
    (define d2-en (dist2 ux uy enemy-x enemy-y))
    (if map-wide-wr?
        (and (<= d2-our 1024.0) (> d2-en 400.0))
        (and (<= d2-our 400.0) (<= d2-our d2-en))))
  (define untagged-workers-near-us
    (for/sum ([u (in-list enemy-units)] #:when (hash? u))
      (define tag (hash-ref u 'id 0))
      (define ut (unit-type-sym u))
      (if (and (or (not (exact-integer? tag)) (<= tag 0))
               (hash-has-key? WORKER-SYM-SET ut)
               (worker-near-our-base? (exact->inexact (hash-ref u 'x enemy-x))
                                      (exact->inexact (hash-ref u 'y enemy-y))))
          1
          0)))
  (define tracked-workers-near-us
    (for/sum ([rec (in-hash-values known-units)])
      (if (and (hash-has-key? WORKER-SYM-SET (tracked-enemy-unit-type rec))
               (<= (- frame (tracked-enemy-unit-last-seen-frame rec)) 112)
               (worker-near-our-base? (tracked-enemy-unit-x rec)
                                      (tracked-enemy-unit-y rec)))
          1
          0)))
  (define enemy-workers-near-us (+ tracked-workers-near-us untagged-workers-near-us))
  (define untagged-enemy-combat-cnt
    (for/sum ([u (in-list enemy-units)] #:when (hash? u))
      (define tag (hash-ref u 'id 0))
      (define ut (unit-type-sym u))
      (define halluc? (or (hash-ref u 'is-hallucination #f) (hash-ref u 'hallucination #f)))
      (if (and (or (not (exact-integer? tag)) (<= tag 0))
               (not halluc?)
               (not (free-summon-unit-sym? ut))
               (not (hash-has-key? WORKER-SYM-SET ut))
               (not (hash-has-key? NONCOMBAT-UNIT-SET ut)))
          1
          0)))
  (define tracked-enemy-combat-cnt
    (for/sum ([rec (in-hash-values known-units)])
      (define ut (tracked-enemy-unit-type rec))
      (if (and (not (hash-has-key? WORKER-SYM-SET ut))
               (not (hash-has-key? NONCOMBAT-UNIT-SET ut))
               (not (free-summon-unit-sym? ut)))
          1
          0)))
  (define enemy-combat-cnt-now (+ tracked-enemy-combat-cnt untagged-enemy-combat-cnt))
  (define ally-combat-sup-now
    (let ([explicit-sup (hash-ref obs 'army-supply #f)])
      (if (real? explicit-sup)
          (max 0.0 (exact->inexact explicit-sup))
          (for/sum ([u (in-list ally-units)] #:when (hash? u))
            (define ut (unit-type-sym u))
            (if (or (hash-has-key? WORKER-SYM-SET ut)
                    (hash-has-key? NONCOMBAT-UNIT-SET ut)
                    (free-summon-unit-sym? ut)
                    (hash-has-key? TOWNHALL-SYM-SET ut)
                    (hash-has-key? GEYSER-BLDG-SYM-SET ut)
                    (hash-has-key? PROD-FACILITY-SYM-SET ut))
                0.0
                (max 0.0 (exact->inexact (sc2-supply-cost ut))))))))
  (define prev-wr-f (hash-ref owm-last-worker-rush-frame-table owm -9999))
  (define early-worker-rush-active?
    (and (>= enemy-workers-near-us 4)
         (= enemy-combat-cnt-now 0)
         (< ally-combat-sup-now 6.0)
         (or (< frame 3360)
             (and (>= prev-wr-f 0)
                  (<= (- frame prev-wr-f) 672)
                  (< frame 5376)))))
  (when early-worker-rush-active?
    (hash-set! owm-last-worker-rush-frame-table owm frame))
  (define rush-posterior-floor (if early-worker-rush-active? 0.91 0.0))

  ;; Step E: Update 3-State Expansion Pad Belief (`Confirmed-Base` | `Confirmed-Empty` | `Unscouted`)
  (define th-bldgs
    (for/list ([rec (in-hash-values known-bldgs)]
               #:when (and (hash-has-key? TOWNHALL-SYM-SET (tracked-enemy-bldg-canon-type rec))
                           (not (tracked-enemy-bldg-is-proxy? rec))))
      rec))

  (for ([pd (in-list (opponent-world-model-pads owm))])
    (define px (pad-belief-entry-x pd))
    (define py (pad-belief-entry-y pd))
    (define matching-th
      (for/first ([th (in-list th-bldgs)]
                  #:when (<= (dist2 (tracked-enemy-bldg-x th) (tracked-enemy-bldg-y th) px py) 169.0))
        th))
    (cond
      [matching-th
       (set-pad-belief-entry-state! pd 'confirmed-base)
       (set-pad-belief-entry-base-tag! pd (tracked-enemy-bldg-tag matching-th))
       (set-pad-belief-entry-last-seen-frame! pd frame)]
      [(eq? (pad-belief-entry-label pd) 'enemy-main)
       ;; Enemy main TownHall exists at frame 0 unless sight-cleared empty!
       (if (ally-sees-point? ally-units px py 90.25)
           (begin
             (set-pad-belief-entry-state! pd 'confirmed-empty)
             (set-pad-belief-entry-last-cleared-frame! pd frame))
           (when (not (eq? (pad-belief-entry-state pd) 'confirmed-empty))
             (set-pad-belief-entry-state! pd 'confirmed-base)))]
      [(ally-sees-point? ally-units px py 90.25)
       (set-pad-belief-entry-state! pd 'confirmed-empty)
       (set-pad-belief-entry-base-tag! pd #f)
       (set-pad-belief-entry-last-cleared-frame! pd frame)]
      [else (void)]))

  ;; Step F: Reconstruct Base & Geyser Timelines + Happy-Path Deviation
  (define confirmed-base-ready-frames
    (cons 0 ; initial main TownHall ready at frame 0
          (sort (for/list ([th (in-list th-bldgs)]
                           #:when (> (dist2 (tracked-enemy-bldg-x th) (tracked-enemy-bldg-y th) enemy-x enemy-y) 100.0))
                  (tracked-enemy-bldg-ready-frame th))
                <)))
  (define confirmed-bases (max 1 (max (length th-bldgs) (length confirmed-base-ready-frames))))
  (define happy-bases (happy-path-expected-bases erace frame))

  ;; Check whether next expected pad (`natural` or `third`) was recently confirmed empty vs unscouted!
  (define pads (opponent-world-model-pads owm))
  (define nat-pad (and (>= (length pads) 2) (second pads)))
  (define third-pad (and (>= (length pads) 3) (third pads)))
  (define fourth-pad (and (>= (length pads) 4) (fourth pads)))

  (define prod-bldg-cnt
    (for/sum ([rec (in-hash-values known-bldgs)])
      (if (hash-has-key? PROD-FACILITY-SYM-SET (tracked-enemy-bldg-canon-type rec)) 1 0)))

  ;; L85/85B Gap B: Remembered enemy main scout, home production/tech counts, latched early pool,
  ;; 1-base double-gas, and latched proxy/1-base rush posterior floor (persisted across fog!).
  (define prev-proxy-vec (hash-ref owm-proxy-state-table owm #f))
  (define prev-scouted-main? (and (vector? prev-proxy-vec) (vector-ref prev-proxy-vec 2) #t))
  (define prev-early-pool? (and (vector? prev-proxy-vec) (vector-ref prev-proxy-vec 3) #t))
  (define prev-latched-kind
    (if (and (vector? prev-proxy-vec) (>= (vector-length prev-proxy-vec) 9))
        (vector-ref prev-proxy-vec 6)
        'none))
  (define prev-latched-floor
    (if (and (vector? prev-proxy-vec) (>= (vector-length prev-proxy-vec) 9))
        (vector-ref prev-proxy-vec 7)
        0.0))
  (define prev-latched-frame
    (if (and (vector? prev-proxy-vec) (>= (vector-length prev-proxy-vec) 9))
        (vector-ref prev-proxy-vec 8)
        -9999))

  ;; Main scout latch: ally ACTUALLY enters enemy main interior (`<= 11.0t` of `enemy-x,y`),
  ;; OR explicit `'scouted-enemy-main? #t`, OR we observed a main-interior production/tech
  ;; structure (`<= 14.0t` of `enemy-x,y` and `> 10.0t` from natural).
  ;; L85C: Excludes `GEYSER-BLDG-SYM-SET` (spotting main Assimilators/Refineries alone from
  ;; edge vision MUST NOT prematurely latch `scouted-enemy-main?` with `home-prod-cnt = 0`!).
  (define (main-interior-confirm-sym? ctype)
    (or (hash-has-key? PROD-FACILITY-SYM-SET ctype)
        (hash-has-key? HOME-TECH-BLDG-SYM-SET ctype)
        (eq? ctype 'spawning-pool)))
  (define saw-main-interior-bldg?
    (or (for/or ([rec (in-hash-values known-bldgs)])
          (define ctype (tracked-enemy-bldg-canon-type rec))
          (and (main-interior-confirm-sym? ctype)
               (not (tracked-enemy-bldg-is-proxy? rec))
               (<= (dist2 (tracked-enemy-bldg-x rec) (tracked-enemy-bldg-y rec) enemy-x enemy-y) 196.0)
               (> (dist2 (tracked-enemy-bldg-x rec) (tracked-enemy-bldg-y rec) enemy-nat-x enemy-nat-y) 100.0)))
        (for/or ([b (in-list enemy-bldgs)] #:when (hash? b))
          (define ctype (sc2-canonical-structure-sym (unit-type-sym b)))
          (define bx (exact->inexact (hash-ref b 'x enemy-x)))
          (define by (exact->inexact (hash-ref b 'y enemy-y)))
          (and (main-interior-confirm-sym? ctype)
               (not (hash-ref b 'is-proxy? #f))
               (<= (dist2 bx by enemy-x enemy-y) 196.0)
               (> (dist2 bx by enemy-nat-x enemy-nat-y) 100.0)))))
  (define scouted-enemy-main?
    (or prev-scouted-main?
        (eq? (hash-ref obs 'scouted-enemy-main? #f) #t)
        (ally-sees-point? ally-units enemy-x enemy-y 121.0)
        saw-main-interior-bldg?))

  ;; L85C: Remembered home production & home tech structure counts: include buildings within
  ;; `<= 44.0t` (`1936.0`) of enemy main OR `<= 16.0t` (`256.0`) of enemy natural so natural-choke
  ;; wall Gateways (`~34.5t` from enemy main) are NEVER miscounted as missing main production!
  (define (in-enemy-home-area? bx by)
    (or (<= (dist2 bx by enemy-x enemy-y) 1936.0)
        (<= (dist2 bx by enemy-nat-x enemy-nat-y) 256.0)))
  (define known-home-prod-cnt
    (for/sum ([rec (in-hash-values known-bldgs)])
      (if (and (not (tracked-enemy-bldg-is-proxy? rec))
               (hash-has-key? PROD-FACILITY-SYM-SET (tracked-enemy-bldg-canon-type rec))
               (in-enemy-home-area? (tracked-enemy-bldg-x rec) (tracked-enemy-bldg-y rec)))
          1 0)))
  (define known-home-tech-cnt
    (for/sum ([rec (in-hash-values known-bldgs)])
      (if (and (not (tracked-enemy-bldg-is-proxy? rec))
               (hash-has-key? HOME-TECH-BLDG-SYM-SET (tracked-enemy-bldg-canon-type rec))
               (in-enemy-home-area? (tracked-enemy-bldg-x rec) (tracked-enemy-bldg-y rec)))
          1 0)))
  (define untagged-home-prod-cnt
    (for/sum ([b (in-list enemy-bldgs)] #:when (hash? b))
      (define tag (hash-ref b 'id 0))
      (define ctype (sc2-canonical-structure-sym (unit-type-sym b)))
      (define bx (exact->inexact (hash-ref b 'x enemy-x)))
      (define by (exact->inexact (hash-ref b 'y enemy-y)))
      (if (and (or (not (exact-integer? tag)) (<= tag 0))
               (not (hash-ref b 'is-proxy? #f))
               (hash-has-key? PROD-FACILITY-SYM-SET ctype)
               (in-enemy-home-area? bx by))
          1 0)))
  (define untagged-home-tech-cnt
    (for/sum ([b (in-list enemy-bldgs)] #:when (hash? b))
      (define tag (hash-ref b 'id 0))
      (define ctype (sc2-canonical-structure-sym (unit-type-sym b)))
      (define bx (exact->inexact (hash-ref b 'x enemy-x)))
      (define by (exact->inexact (hash-ref b 'y enemy-y)))
      (if (and (or (not (exact-integer? tag)) (<= tag 0))
               (not (hash-ref b 'is-proxy? #f))
               (hash-has-key? HOME-TECH-BLDG-SYM-SET ctype)
               (in-enemy-home-area? bx by))
          1 0)))
  (define home-prod-cnt (+ known-home-prod-cnt untagged-home-prod-cnt))
  (define home-tech-cnt (+ known-home-tech-cnt untagged-home-tech-cnt))

  ;; L85C: True cheese Spawning Pool latch ONLY (`12-pool` / `13-12` / `14-pool`, NEVER normal
  ;; `16-pool` / `16-hatch`!): `est-start <= 950` (`42.5s`), `bp >= 0.99` at `<= 1950` (`87s`),
  ;; `bp >= 0.50` at `<= 1450` (`65s`), or `>= 6` Zerglings at `<= 2700` (`2:00`, not 4 anti-scout Lings!).
  (define recent-zergling-cnt
    (+ (for/sum ([rec (in-hash-values known-units)])
         (if (and (eq? (tracked-enemy-unit-type rec) 'zergling)
                  (<= (- frame (tracked-enemy-unit-last-seen-frame rec)) 224))
             1 0))
       (for/sum ([u (in-list enemy-units)] #:when (hash? u))
         (define tag (hash-ref u 'id 0))
         (if (and (or (not (exact-integer? tag)) (<= tag 0))
                  (eq? (sc2-canonical-unit-sym (unit-type-sym u)) 'zergling))
             1 0))))
  (define early-zergling-cnt
    (if (> frame 2700) 0 recent-zergling-cnt))
  (define early-pool-now?
    (or (for/or ([rec (in-hash-values known-bldgs)])
          (and (eq? (tracked-enemy-bldg-canon-type rec) 'spawning-pool)
               (or (<= (tracked-enemy-bldg-start-frame rec) 950)
                   (and (>= (tracked-enemy-bldg-build-progress rec) 0.99)
                        (<= (tracked-enemy-bldg-last-seen-frame rec) 1950))
                   (and (>= (tracked-enemy-bldg-build-progress rec) 0.50)
                        (<= (tracked-enemy-bldg-last-seen-frame rec) 1450)))))
        (for/or ([b (in-list enemy-bldgs)] #:when (hash? b))
          (define ctype (sc2-canonical-structure-sym (unit-type-sym b)))
          (define bp (max 0.0 (min 1.0 (exact->inexact (hash-ref b 'build-progress 1.0)))))
          (define est-start (max 0 (- frame (exact-round (* bp (structure-build-frames 'spawning-pool))))))
          (and (eq? ctype 'spawning-pool)
               (or (<= est-start 950)
                   (and (>= bp 0.99) (<= frame 1950))
                   (and (>= bp 0.50) (<= frame 1450)))))
        (and (<= frame 2700) (>= early-zergling-cnt 6))))
  ;; Clear early-pool latch cleanly once opponent has `>= 2` bases and no active Ling wave past `3:15` (`4368f`)
  (define early-pool-cleared-peaceful?
    (and (>= confirmed-bases 2)
         (> frame 4368)
         (< recent-zergling-cnt 6)))
  (define early-pool-latched?
    (and (not early-pool-cleared-peaceful?)
         (or prev-early-pool? early-pool-now?)))

  ;; L85B: Direct proxy combat/production structure remembered across fog!
  ;; Catches BOTH near-base proxies AND mid-map proxies (`> 42t` from enemy main and closer to us
  ;; than enemy main, OR `> 48t` from enemy main before `4:45`), while EXCLUDING expansion-block
  ;; `engineering-bay` / lone natural-pad `pylon` so normal macro expansion blocks never false-fire!
  (define (proxy-combat-bldg-sym? ctype)
    (or (hash-has-key? PROD-FACILITY-SYM-SET ctype)
        (not (not (memq ctype '(photon-cannon bunker spine-crawler))))))
  (define proxy-bldg-remembered?
    (for/or ([rec (in-hash-values known-bldgs)])
      (define ctype (tracked-enemy-bldg-canon-type rec))
      (define bx (tracked-enemy-bldg-x rec))
      (define by (tracked-enemy-bldg-y rec))
      (define d2-en (dist2 bx by enemy-x enemy-y))
      (define d2-us (min (dist2 bx by base-x base-y) (dist2 bx by nat-x nat-y)))
      (and (proxy-combat-bldg-sym? ctype)
           (or (tracked-enemy-bldg-is-proxy? rec)
               (and (> d2-en 1764.0)
                    (or (< d2-us d2-en)
                        (> d2-en 2304.0)))))))

  (define known-geysers
    (for/list ([rec (in-hash-values known-bldgs)]
               #:when (hash-has-key? GEYSER-BLDG-SYM-SET (tracked-enemy-bldg-canon-type rec)))
      (list (tracked-enemy-bldg-ready-frame rec)
            (tracked-enemy-bldg-last-seen-frame rec)
            (tracked-enemy-bldg-vespene-contents rec))))
  (define untagged-geyser-cnt
    (for/sum ([b (in-list enemy-bldgs)] #:when (hash? b))
      (define tag (hash-ref b 'id 0))
      (if (and (or (not (exact-integer? tag)) (<= tag 0))
               (hash-has-key? GEYSER-BLDG-SYM-SET (sc2-canonical-structure-sym (unit-type-sym b))))
          1 0)))
  ;; If gas tech/units were implied (`extractor`/`refinery`/`assimilator` in `implied-set`) and 0 geysers directly seen,
  ;; infer at least 1 geyser ready by `min(frame - 448, 1200)`!
  (define eff-geysers
    (if (and (null? known-geysers)
             (= untagged-geyser-cnt 0)
             (or (set-member? implied-set 'extractor)
                 (set-member? implied-set 'refinery)
                 (set-member? implied-set 'assimilator)))
        (list (list (min (max 400 (- frame 448)) 1200) frame 0))
        known-geysers))
  (define confirmed-geyser-cnt (+ (length eff-geysers) untagged-geyser-cnt))

  ;; L85C Gap B/C: 1-base double-gas (`<= 1` confirmed base, `>= 2` remembered geysers):
  ;; - Terran: `>= 145s` (`3248f`) so normal 1-Rax FE never false-fires `< 145s`.
  ;; - Protoss: `>= 2:40` (`3584f`), OR `>= 2:00` (`2688f`) ONLY if `scouted-enemy-main?` AND
  ;;   `home-tech-cnt == 0` AND `home-prod-cnt <= 1` (catches Proxy Stargate @ 2:15 while
  ;;   normal 2-Gate 2-Gas PvP macro openings NEVER false-fire!).
  ;; - Zerg/Unknown: `>= 2:00` (`2688f`).
  (define enemy-1base-double-gas?
    (and (<= confirmed-bases 1)
         (>= confirmed-geyser-cnt 2)
         (<= frame 6384)
         (cond
           [(eq? erace 'Terran) (>= frame 3248)]
           [(eq? erace 'Protoss)
            (or (>= frame 3584)
                (and (>= frame 2688)
                     scouted-enemy-main?
                     (= home-tech-cnt 0)
                     (<= home-prod-cnt 1)))]
           [else (>= frame 2688)])))

  (define next-overdue-pad
    (cond
      [(and (< confirmed-bases 2) (>= happy-bases 2)) nat-pad]
      [(and (< confirmed-bases 3) (>= happy-bases 3)) third-pad]
      [(and (< confirmed-bases 4) (>= happy-bases 4)) fourth-pad]
      [else #f]))

  (define overdue-pad-confirmed-empty?
    (and next-overdue-pad
         (eq? (pad-belief-entry-state next-overdue-pad) 'confirmed-empty)
         (<= (- frame (pad-belief-entry-last-cleared-frame next-overdue-pad)) 1680))) ; cleared within 75s

  (define stopped-expanding?
    (or early-worker-rush-active?
        (and (< confirmed-bases happy-bases)
             (or overdue-pad-confirmed-empty?
                 (>= prod-bldg-cnt (* 3 confirmed-bases))
                 (and (= confirmed-bases 1) (>= confirmed-geyser-cnt 2) (>= frame 3584))))))

  (define unscouted-expansion-ambiguity?
    (and (< confirmed-bases happy-bases)
         (not stopped-expanding?)))

  (define urgent-scout-pad
    (and unscouted-expansion-ambiguity?
         next-overdue-pad
         (cons (pad-belief-entry-x next-overdue-pad)
               (pad-belief-entry-y next-overdue-pad))))

  ;; Effective base timeline for cumulative income integration:
  ;; When `unscouted-expansion-ambiguity?` is true, include plausible hidden expansions up to
  ;; `happy-bases` for unscouted (not confirmed-empty) pads so deep-fog macro opponents keep
  ;; realistic worker/base counts rather than freezing at 2 bases through 15:00!
  (define eff-base-ready-frames
    (if (and unscouted-expansion-ambiguity? (< (length confirmed-base-ready-frames) happy-bases))
        (let* ([cur-cnt (length confirmed-base-ready-frames)]
               [happy-rfs
                (for/list ([b-idx (in-range (add1 cur-cnt) (add1 happy-bases))])
                  (case b-idx
                    [(2) (case erace [(Zerg) 3340] [(Protoss) 4280] [else 4610])]
                    [(3) (case erace [(Zerg) 6400] [(Protoss) 9540] [else 9990])]
                    [else (case erace [(Zerg) 11000] [(Protoss) 13680] [else 14350])]))])
          (sort (append confirmed-base-ready-frames happy-rfs) <))
        confirmed-base-ready-frames))

  (define eff-workers-killed
    (max (opponent-world-model-workers-killed owm)
         (let ([wk (hash-ref obs 'enemy-workers-killed 0)])
           (if (exact-integer? wk) wk 0))))

  (define-values (cum-min cum-gas est-unobs-gas est-workers est-workers-born)
    (integrate-opponent-economy erace frame eff-base-ready-frames eff-geysers eff-workers-killed))

  ;; Step G: Conservation of Resources (`M_cum = Econ + Tech/Prod + AliveArmy + Dead + Bank + UnseenThreat`)
  (define f-sec (/ (exact->inexact frame) 22.4))
  (define th-cost (case erace [(Zerg) 300] [else 400]))
  (define geyser-cost (case erace [(Zerg) 25] [else 75]))
  (define eff-bases
    (if unscouted-expansion-ambiguity?
        (max confirmed-bases (length eff-base-ready-frames))
        confirmed-bases))
  (define extra-bases-built (max 0 (- eff-bases 1)))

  ;; Tech / production / static-defense structures + upgrades sunk cost
  (define-values (sunk-tech-bldg-min sunk-tech-bldg-gas siege-turtle-cnt)
    (for/fold ([tm 0] [tg 0] [st-cnt 0])
              ([rec (in-hash-values known-bldgs)])
      (define ct (tracked-enemy-bldg-canon-type rec))
      (define st-inc
        (if (memq ct '(bunker planetary-fortress photon-cannon spine-crawler)) 1 0))
      (if (or (hash-has-key? TOWNHALL-SYM-SET ct)
              (hash-has-key? GEYSER-BLDG-SYM-SET ct))
          (values tm tg (+ st-cnt st-inc))
          (values (+ tm (tracked-enemy-bldg-min-cost rec))
                  (+ tg (tracked-enemy-bldg-gas-cost rec))
                  (+ st-cnt st-inc)))))

  ;; Add implied tech structures not yet seen directly in `known-bldgs`
  (define seen-canon-bldgs
    (for/seteq ([rec (in-hash-values known-bldgs)])
      (tracked-enemy-bldg-canon-type rec)))
  (define-values (imp-min imp-gas)
    (for/fold ([im 0] [ig 0])
              ([isym (in-set implied-set)])
      (if (or (set-member? seen-canon-bldgs isym)
              (set-member? destroyed-tech isym)
              (hash-has-key? TOWNHALL-SYM-SET isym)
              (hash-has-key? GEYSER-BLDG-SYM-SET isym))
          (values im ig)
          (values (+ im (max 0 (sc2-min-cost isym)))
                  (+ ig (max 0 (sc2-gas-cost isym)))))))

  (define upg-levels-sum
    (+ (opponent-world-model-max-atk-upg owm)
       (opponent-world-model-max-arm-upg owm)
       (opponent-world-model-max-shd-upg owm)))
  (define sunk-upg-min (* 125 upg-levels-sum))
  (define sunk-upg-gas (* 125 upg-levels-sum))

  (define obs-sunk-tech-min (+ sunk-tech-bldg-min imp-min sunk-upg-min))
  (define obs-sunk-tech-gas (+ sunk-tech-bldg-gas imp-gas sunk-upg-gas))

  ;; Known alive combat units + reachability cone toward our front (`nat-x, nat-y` / `base-x, base-y`)
  ;; Separate non-combat support flyers (`overlord`, `overseer`, `observer`, `dropperlord`,
  ;; `overlord-transport`) from `known-army-val` so scouting Overlords don't add phantom army value.
  (define known-unit-counts-mut (make-hasheq))
  (define-values (known-army-sup known-army-min known-army-gas known-support-min known-support-gas imm-known-sup unit-siege-cnt)
    (for/fold ([asup 0] [amin 0] [agas 0] [smin 0] [sgas 0] [isup 0] [usiege 0])
              ([rec (in-hash-values known-units)])
      (define ut (tracked-enemy-unit-type rec))
      (hash-update! known-unit-counts-mut ut add1 0)
      (cond
        [(hash-has-key? WORKER-SYM-SET ut)
         (values asup amin agas smin sgas isup usiege)]
        [(memq ut '(overlord overlord-transport dropperlord))
         ;; Overlords are already accounted for in `sunk-supply-min` below
         (values asup amin agas smin sgas isup usiege)]
        [(memq ut '(overseer observer))
         (values asup amin agas
                 (+ smin (tracked-enemy-unit-min-cost rec))
                 (+ sgas (tracked-enemy-unit-gas-cost rec))
                 isup usiege)]
        [else
         (define dt-sec (/ (exact->inexact (max 0 (- frame (tracked-enemy-unit-last-seen-frame rec)))) 22.4))
         ;; Discount stale unobserved unit contribution gently after 65s
         (define freshness (if (<= dt-sec 65.0) 1.0 (max 0.35 (- 1.0 (/ (- dt-sec 65.0) 60.0)))))
         (define usup (exact-round (* freshness (tracked-enemy-unit-supply rec))))
         (define d-home
           (sqrt (min (dist2 (tracked-enemy-unit-x rec) (tracked-enemy-unit-y rec) base-x base-y)
                      (dist2 (tracked-enemy-unit-x rec) (tracked-enemy-unit-y rec) nat-x nat-y))))
         ;; Can this unit reach our front within the next 18s given `(dt-sec + 18s) * speed`?
         (define max-reach (* (tracked-enemy-unit-speed-tps rec) (+ dt-sec 18.0)))
         (define reach-inc (if (<= d-home max-reach) usup 0))
         (define siege-inc (if (memq ut '(siege-tank siege-tank-sieged lurker lurker-mp lurker-burrowed tempest brood-lord)) 1 0))
         (values (+ asup usup)
                 (+ amin (tracked-enemy-unit-min-cost rec))
                 (+ agas (tracked-enemy-unit-gas-cost rec))
                 smin
                 sgas
                 (+ isup reach-inc)
                 (+ usiege siege-inc))])))

  ;; Unavoidable macro economic overhead:
  ;;   - Workers built (`50M` each) + extra TownHalls + geysers (observed or baseline)
  ;;   - Supply providers (`100M` per 8 supply above starting 14/15 for workers + known army + 6 headroom)
  ;;   - Race macro infrastructure: Terran Orbital morphs (`150M` each once ready) & Zerg macro Queens/morphed Drones
  (define est-geysers-sunk
    (max confirmed-geyser-cnt
         (if (< f-sec 75.0) 0 (min (* 2 eff-bases) (exact-floor (/ (- f-sec 60.0) 110.0))))))
  (define start-sup (if (eq? erace 'Zerg) 14 15))
  (define base-sup-needed (max start-sup (+ est-workers known-army-sup 6)))
  (define sunk-supply-min
    (* 100 (exact-ceiling (/ (max 0 (- base-sup-needed start-sup)) 8.0))))
  (define known-queen-cnt (hash-ref known-unit-counts-mut 'queen 0))
  (define ready-base-cnt-now
    (max 1 (count (lambda (rf) (<= (/ (exact->inexact rf) 22.4) f-sec)) eff-base-ready-frames)))
  (define race-macro-min
    (case erace
      [(Terran)
       ;; Orbital morph (`150M`) at ~135s for main and ~30s after extra bases complete (up to 3)
       (define orb-cnt
         (min 3 (count (lambda (rf)
                         (define rsec (/ (exact->inexact rf) 22.4))
                         (<= (if (<= rsec 1.0) 135.0 (+ rsec 30.0)) f-sec))
                       eff-base-ready-frames)))
       (* 150 orb-cnt)]
      [(Zerg)
       ;; Macro Queens (`150M` per base once >= 135s, net of already-observed Queens)
       ;; + consumed Drones (`50M` each) for Hatcheries, Extractors, and core tech structures.
       (define exp-queens (if (< f-sec 135.0) 0 (min 4 ready-base-cnt-now)))
       (define consumed-drones
         (+ extra-bases-built
            est-geysers-sunk
            (if (< f-sec 90.0) 0 (min 4 (add1 (exact-floor (/ (- f-sec 90.0) 120.0)))))))
       (+ (* 150 (max 0 (- exp-queens known-queen-cnt)))
          (* 50 consumed-drones))]
      [else 0]))
  (define sunk-econ-min
    (+ (* 50 (max 0 (- est-workers-born 12)))
       (* th-cost extra-bases-built)
       (* geyser-cost est-geysers-sunk)
       sunk-supply-min
       race-macro-min))

  ;; Baseline production / tech / upgrade infrastructure floor scaled by elapsed time & bases.
  ;; Uses `max` against observed/implied tech so observed buildings are never double-counted!
  (define baseline-tech-ramp (max 0.0 (min 1.0 (/ (- f-sec 50.0) 65.0))))
  (define baseline-tech-min
    (min 2500
         (exact-round
          (* baseline-tech-ramp
             (+ 125.0
                (* 1.85 (max 0.0 (- f-sec 115.0)))
                (* 130.0 extra-bases-built))))))
  (define total-est-gas (+ cum-gas est-unobs-gas))
  (define baseline-tech-gas-conf
    (if (or (<= cum-gas 0) (< f-sec 90.0))
        0
        (min (quotient (* cum-gas 45) 100)
             (exact-round (+ (* 0.85 (max 0.0 (- f-sec 90.0)))
                             (* 70.0 extra-bases-built))))))
  (define baseline-tech-gas-tot
    (if (or (<= total-est-gas 0) (< f-sec 90.0))
        0
        (min (quotient (* total-est-gas 48) 100)
             (exact-round (+ (* 1.10 (max 0.0 (- f-sec 90.0)))
                             (* 85.0 extra-bases-built))))))
  (define sunk-tech-min (max obs-sunk-tech-min baseline-tech-min))
  (define sunk-tech-gas (max obs-sunk-tech-gas baseline-tech-gas-conf))
  (define tot-sunk-tech-gas (max obs-sunk-tech-gas baseline-tech-gas-tot))

  (define known-army-val (+ known-army-min (exact-round (* 1.5 known-army-gas))))
  (define tot-destroyed-min (+ (opponent-world-model-confirmed-destroyed-min owm)
                               (opponent-world-model-expired-sunk-min owm)))
  (define tot-destroyed-gas (+ (opponent-world-model-confirmed-destroyed-gas owm)
                               (opponent-world-model-expired-sunk-gas owm)))

  ;; Realistic natural mineral/gas bank + in-progress construction/training queue (~20s cycle).
  ;; Tighter (`0.60x`) when `stopped-expanding?` is confirmed (all-in spending rather than saving for bases).
  (define bank-raw-min
    (+ 125
       (* 70 ready-base-cnt-now)
       (exact-round (* 1.50 (max 0.0 (- f-sec 240.0))))))
  (define transient-bank-min
    (min 2600
         (if stopped-expanding?
             (exact-round (* 0.60 bank-raw-min))
             bank-raw-min)))
  (define transient-bank-gas
    (min 450
         (exact-round (+ 75
                         (* 25 ready-base-cnt-now)
                         (* 0.25 (max 0.0 (- f-sec 240.0)))))))

  (define unaccounted-min
    (max 0 (- cum-min (+ sunk-econ-min sunk-tech-min known-army-min known-support-min tot-destroyed-min transient-bank-min))))
  (define unaccounted-gas
    (max 0 (- cum-gas (+ sunk-tech-gas known-army-gas known-support-gas tot-destroyed-gas transient-bank-gas))))
  ;; Conserved total unaccounted gas (including baseline unobserved gas workers) used ONLY for
  ;; army-value conservation — `unaccounted-gas` above remains strictly anchored to confirmed/implied geysers!
  (define unaccounted-tot-gas
    (max unaccounted-gas
         (max 0 (- total-est-gas (+ tot-sunk-tech-gas known-army-gas known-support-gas tot-destroyed-gas transient-bank-gas)))))

  ;; Rational-Opponent Threat Weighting (post macro-overhead deduction):
  ;;   - If `stopped-expanding?` is confirmed (`B_opp < B*_happy(t)`): 85% of unaccounted M/G is Army!
  ;;   - If `unscouted-expansion-ambiguity?`: 72% of unaccounted M/G is treated as potential Army!
  ;;   - If opponent bases ARE on/ahead of happy path and scouted: 65%.
  (define unseen-threat-weight
    (cond
      [(< frame 1568) 0.35] ; before 1:10 opening noise is tiny
      [stopped-expanding? 0.85]
      [unscouted-expansion-ambiguity? 0.72]
      [else 0.65]))

  ;; Also respect production-facility floor: `k` observed production structures past 3:30 imply active army output!
  (define prod-implied-army-val
    (if (>= frame 4480)
        (* 275 (max 0 (- prod-bldg-cnt 1)))
        0))

  ;; 1) Conservation-based unseen army value (`0.87` factor reflects ~12.5M/supply provider cost for unseen army)
  (define conservation-unseen-val
    (exact-round (* unseen-threat-weight
                    (+ (* 0.87 unaccounted-min)
                       (* 1.5 unaccounted-tot-gas)))))

  ;; 2) Physical production-throughput & rolling standing-army window cap:
  ;;    Prevents early opening noise (< 2:00) AND prevents unbounded lifetime cumulative drift (10:00–45:00+)
  ;;    when off-screen attrition, expansions, or max-out banks occur.
  (define combat-onset-sec (if stopped-expanding? 55.0 68.0))
  (define t-combat (max 0.0 (- f-sec combat-onset-sec)))
  (define eff-prod-window-sec
    (if (<= t-combat 110.0)
        (* 0.5 (/ (* t-combat t-combat) 110.0))
        (+ 55.0 (min (- t-combat 110.0) 190.0))))
  (define eff-prod-bases
    (if stopped-expanding?
        confirmed-bases
        (max eff-bases happy-bases)))
  (define prod-rate-per-sec
    (max (* 4.5 (exact->inexact prod-bldg-cnt))
         (* (if stopped-expanding? 1.45 1.0)
            (+ 7.5 (* 9.5 (min 3.5 (exact->inexact (max 0 (- eff-prod-bases 1)))))))))
  (define prod-window-cap-val
    (exact-round (* prod-rate-per-sec eff-prod-window-sec)))

  ;; 3) Physical supply-cap headroom (`200 - est-workers` max total army supply)
  (define max-army-sup (max known-army-sup (max 0 (- 200 est-workers))))
  (define sup-headroom-val (* (max 0 (- max-army-sup known-army-sup)) 95))

  (define unseen-army-val
    (min conservation-unseen-val prod-window-cap-val sup-headroom-val))

  ;; Convert believed unseen value to supply (~78 weighted resource/supply in LotV),
  ;; then strictly enforce `believed-total-army-val <= (* believed-total-army-sup 105)`!
  (define unseen-army-sup
    (exact-round (/ (exact->inexact unseen-army-val) 78.0)))
  (define prod-implied-sup
    (exact-round (/ (exact->inexact prod-implied-army-val) 78.0)))
  (define believed-total-army-sup
    (min max-army-sup
         (max known-army-sup
              (+ known-army-sup unseen-army-sup)
              prod-implied-sup)))
  (define believed-total-army-val
    (min (* believed-total-army-sup 105)
         (max (+ known-army-val unseen-army-val)
              prod-implied-army-val)))

  (define confirmed-early-greed?
    (and (not stopped-expanding?)
         (or (> (length th-bldgs) happy-bases)
             (and (>= (length th-bldgs) 3) (<= frame 6048)))
         (<= believed-total-army-sup 10)))

  ;; Imminent reachable supply (`within 18s` of our bases):
  ;; Known reachable tags + fraction of unseen army when opponent stopped expanding or mid-map is unscouted!
  (define mid-x (* 0.5 (+ nat-x enemy-nat-x)))
  (define mid-y (* 0.5 (+ nat-y enemy-nat-y)))
  (define mid-map-clear? (ally-sees-point? ally-units mid-x mid-y 225.0))
  (define imm-unseen-sup
    (cond
      [(< frame 2240) 0]
      [stopped-expanding?
       (exact-round (* (if mid-map-clear? 0.35 0.65) unseen-army-sup))]
      [(not mid-map-clear?)
       (exact-round (* 0.30 unseen-army-sup))]
      [else 0]))
  (define imminent-reachable-sup
    (max (min believed-total-army-sup (+ imm-known-sup imm-unseen-sup))
         (if early-worker-rush-active? enemy-workers-near-us 0)))

  ;; Narrow unseen gas profile & persistent AA / Detection requirements
  (define known-bldg-counts-mut (make-hasheq))
  (for ([rec (in-hash-values known-bldgs)])
    (hash-update! known-bldg-counts-mut (tracked-enemy-bldg-canon-type rec) add1 0))
  (for ([isym (in-set implied-set)]
        #:when (and (not (set-member? destroyed-tech isym))
                    (= (hash-ref known-bldg-counts-mut isym 0) 0)))
    (hash-set! known-bldg-counts-mut isym 1))

  (define observed-stealth-prereq-bldg?
    (not (not (for/or ([bt (in-hash-keys known-bldg-counts-mut)])
                (memq bt '(twilight-council starport starport-techlab ghost-academy
                           dark-shrine lurker-den lurker-den-mp))))))

  ;; Tighten `hidden-gas-tech-risk?`: normal 2-gas openings without confirmed stopped-expanding
  ;; or stealth-prereq tech evidence must NOT falsely force premature static detection at 3:20!
  (define hidden-gas-tech-risk?
    (and (>= frame 3360) ; >= 2:30
         (< known-army-gas 100)
         (or (and stopped-expanding?
                  (= confirmed-bases 1)
                  (>= confirmed-geyser-cnt 2)
                  (>= unaccounted-gas 350))
             (and observed-stealth-prereq-bldg?
                  (>= unaccounted-gas 375)))))

  (define pers-req-aa?
    (or (for/or ([ut (in-hash-keys known-unit-counts-mut)])
          (memq ut '(mutalisk corruptor brood-lord broodlord viper oracle phoenix void-ray voidray
                     carrier tempest mothership banshee liberator liberator-ag battlecruiser
                     viking-fighter colossus)))
        (for/or ([bt (in-hash-keys known-bldg-counts-mut)])
          (memq bt '(spire greater-spire stargate fleet-beacon starport-techlab fusion-core)))))

  (define pers-req-det?
    (or (for/or ([ut (in-hash-keys known-unit-counts-mut)])
          (memq ut '(dark-templar banshee ghost lurker lurker-mp lurker-burrowed widow-mine widow-mine-burrowed
                     roach-burrowed swarm-host-burrowed mothership oracle)))
        (for/or ([bt (in-hash-keys known-bldg-counts-mut)])
          (memq bt '(dark-shrine lurker-den lurker-den-mp ghost-academy starport-techlab)))
        ;; Only assert inferred detection at >= 4:00 (5376f) for non-Zerg when high-confidence
        ;; hidden-gas-tech-risk? holds with >= 400 unaccounted gas (1-base 2-gas rush or cloak prereq tech).
        (and hidden-gas-tech-risk?
             (>= frame 5376)
             (not (eq? erace 'Zerg))
             (>= unaccounted-gas 400))))

  ;; Locust wave (`18s` lifespan while `active-locust-cnt > 0`) vs Swarm-Host vulnerable cooldown
  ;; (`43s - 18s = 25s = 560 frames` immediately after the Locust wave expires!)
  (define last-loc-f (opponent-world-model-last-locust-wave-frame owm))
  (define dt-loc (- frame last-loc-f))
  (define locust-wave-active?
    (and (>= last-loc-f 0)
         (or (>= active-locust-cnt 2)
             (and (> active-locust-cnt 0) (>= dt-loc 0) (<= dt-loc 403)))))
  (define swarm-host-cooldown-window?
    (and (>= last-loc-f 0)
         (not locust-wave-active?)
         (= active-locust-cnt 0)
         (>= dt-loc 1)
         (<= dt-loc 515)))

  (define summary
    (opponent-world-summary
     frame
     erace
     confirmed-bases
     confirmed-geyser-cnt
     happy-bases
     est-workers
     eff-workers-killed
     (not (not stopped-expanding?))
     (not (not unscouted-expansion-ambiguity?))
     (not (not confirmed-early-greed?))
     urgent-scout-pad
     cum-min
     cum-gas
     sunk-econ-min
     sunk-tech-min
     sunk-tech-gas
     tot-destroyed-min
     tot-destroyed-gas
     known-army-sup
     known-army-val
     unaccounted-min
     unaccounted-gas
     believed-total-army-sup
     believed-total-army-val
     imminent-reachable-sup
     prod-bldg-cnt
     (not (not hidden-gas-tech-risk?))
     (not (not pers-req-aa?))
     (not (not pers-req-det?))
     (not (not locust-wave-active?))
     (not (not swarm-host-cooldown-window?))
     active-summon-cnt
     (+ siege-turtle-cnt unit-siege-cnt)
     (for/hasheq ([(k v) (in-hash known-unit-counts-mut)]) (values k v))
     (for/hasheq ([(k v) (in-hash known-bldg-counts-mut)]) (values k v))))
  ;; L85B: Compute & latch confirmed early proxy / 1-base 2-gas / early-pool rush posterior floor
  ;; across fog through `~285s` (`6384f`), clearing cleanly if enemy takes a 2nd base + normal
  ;; main production (or past `~260s` [`5824f`] once we hold with safe army parity so held
  ;; cheeses immediately expand instead of stalling CC #2 / Nexus #2 past `300s`).
  (define-values (fresh-proxy-kind fresh-proxy-floor)
    (cond
      [(and proxy-bldg-remembered? (<= frame 6384))
       (values 'proxy-bldg 0.85)]
      [(and scouted-enemy-main?
            (= home-prod-cnt 0)
            (not (eq? erace 'Zerg))
            (<= confirmed-bases 1)
            (>= frame 2240)
            (<= frame 6384))
       (values 'missing-main-prod 0.82)]
      [(and enemy-1base-double-gas?
            scouted-enemy-main?
            (= home-tech-cnt 0))
       (values 'one-base-double-gas 0.80)]
      [enemy-1base-double-gas?
       (values 'one-base-double-gas 0.68)]
      [(and early-pool-latched? (<= frame 5824) (< confirmed-bases 3))
       (values 'early-pool 0.72)]
      [else
       (values 'none 0.0)]))
  (define post-hold-safe-parity?
    (and (>= frame 5824)
         (= enemy-workers-near-us 0)
         (>= ally-combat-sup-now (max 8.0 (* 1.15 (max 4.0 (exact->inexact known-army-sup)))))))
  (define normal-macro-clears-latch?
    (case prev-latched-kind
      [(early-pool) (or (>= confirmed-bases 3) early-pool-cleared-peaceful?)]
      [(proxy-bldg) (and (>= confirmed-bases 2) (>= home-prod-cnt 1) (not proxy-bldg-remembered?))]
      [(missing-main-prod one-base-double-gas) (and (>= confirmed-bases 2) (>= home-prod-cnt 1))]
      [else #f]))
  (define-values (latched-kind latched-floor latched-frame)
    (cond
      [(> frame 6384)
       (values 'none 0.0 -9999)]
      [post-hold-safe-parity?
       (values 'none 0.0 -9999)]
      [(> fresh-proxy-floor 0.0)
       (if (and (not normal-macro-clears-latch?)
                (> prev-latched-floor fresh-proxy-floor)
                (or (not (eq? prev-latched-kind 'early-pool)) (<= frame 5824)))
           (values prev-latched-kind prev-latched-floor prev-latched-frame)
           (values fresh-proxy-kind fresh-proxy-floor frame))]
      [(and (> prev-latched-floor 0.0)
            (not normal-macro-clears-latch?)
            (<= frame (if (eq? prev-latched-kind 'early-pool) 5824 6384)))
       (values prev-latched-kind prev-latched-floor prev-latched-frame)]
      [else
       (values 'none 0.0 -9999)]))
  (define inferred-proxy-rush-floor
    (max (if early-worker-rush-active? 0.91 0.0)
         latched-floor))

  (hash-set! owm-summary-worker-rush-table
             summary
             (vector enemy-workers-near-us
                     (not (not early-worker-rush-active?))
                     rush-posterior-floor))
  (define proxy-state-vec
    (vector home-prod-cnt
            home-tech-cnt
            (not (not scouted-enemy-main?))
            (not (not early-pool-latched?))
            (not (not enemy-1base-double-gas?))
            inferred-proxy-rush-floor
            latched-kind
            latched-floor
            latched-frame))
  (hash-set! owm-proxy-state-table owm proxy-state-vec)
  (hash-set! owm-summary-proxy-state-table summary proxy-state-vec)
  (set-opponent-world-model-last-summary! owm summary)
  summary)
