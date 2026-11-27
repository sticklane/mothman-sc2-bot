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
         racket/string
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
         owm-next-stale-ring-pad
         owm-stale-ring-pad-count
         owm-confirmed-enemy-base-pts
         owm-enemy-turtle-breakdown
         owm-estimated-enemy-bases
         owm-estimated-enemy-gases
         owm-estimated-min-rate
         owm-estimated-gas-rate
         owm-belief-telemetry-snapshot
         (struct-out owm-control-signals)
         owm-build-control-signals
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

;; L86 Track 1: ABI-preserving weak side-tables for full map expansion-ring tracking,
;; confirmed enemy base positions, and static-defense/siege/mine turtle breakdown.
;; Zero changes to the 35-field `opponent-world-summary` struct ABI.
(define DEFAULT-TURTLE-BREAKDOWN
  (hasheq 'static-ground-count 0
          'pf-count 0
          'static-aa-count 0
          'burrow-mine-count 0
          'siege-zone-count 0))

(define (make-l86-ring-state)
  (define ht (make-hasheq))
  (hash-set! ht 'ring-pads '())
  (hash-set! ht 'confirmed-enemy-base-pts '())
  (hash-set! ht 'turtle-breakdown DEFAULT-TURTLE-BREAKDOWN)
  (hash-set! ht 'raw-unit-types (make-hasheqv))
  (hash-set! ht 'estimated-enemy-bases 1)
  (hash-set! ht 'estimated-enemy-gases 0)
  (hash-set! ht 'min-rate-per-min 0)
  (hash-set! ht 'gas-rate-per-min 0)
  (hash-set! ht 'seen-workers 0)
  (hash-set! ht 'prod-counts (hasheq))
  (hash-set! ht 'combat-unit-counts (hasheq))
  (hash-set! ht 'owm-upgrades '())
  (hash-set! ht 'believed-army-val-unweighted 0)
  (hash-set! ht 'worker-kill-events '())
  (hash-set! ht 'last-recorded-workers-killed 0)
  (hash-set! ht 'recent-comp-weights (make-hasheq))
  (hash-set! ht 'kinematic-anchors (make-hasheqv))
  (hash-set! ht 'kinematic-hits (make-hasheq))
  (hash-set! ht 'unupg-seen-frame (make-hasheq))
  (hash-set! ht 'tech-first-seen-frame (make-hasheq))
  ht)

(define owm-l86-ring-state-table (make-weak-hasheq))
(define owm-summary-l86-ring-state-table (make-weak-hasheq))

(define (owm-l86-ring-state x)
  (cond
    [(opponent-world-model? x) (hash-ref owm-l86-ring-state-table x #f)]
    [(opponent-world-summary? x) (hash-ref owm-summary-l86-ring-state-table x #f)]
    [else #f]))

(define (extract-pad-xy p)
  (cond
    [(and (hash? p) (real? (hash-ref p 'x #f)) (real? (hash-ref p 'y #f)))
     (values (exact->inexact (hash-ref p 'x)) (exact->inexact (hash-ref p 'y)))]
    [(and (pair? p) (real? (car p)) (real? (cdr p)))
     (values (exact->inexact (car p)) (exact->inexact (cdr p)))]
    [(and (pair? p) (real? (car p)) (pair? (cdr p)) (real? (cadr p)))
     (values (exact->inexact (car p)) (exact->inexact (cadr p)))]
    [(and (vector? p) (>= (vector-length p) 2) (real? (vector-ref p 0)) (real? (vector-ref p 1)))
     (values (exact->inexact (vector-ref p 0)) (exact->inexact (vector-ref p 1)))]
    [else (values #f #f)]))

(define (pad-near-own-base? px py own-base-pts)
  (for/or ([ob (in-list own-base-pts)])
    (define-values (ox oy) (extract-pad-xy ob))
    (and ox oy (< (dist2 px py ox oy) 256.0))))

(define (pad-is-stale? rp frame min-stale)
  (define lv (vector-ref rp 2))
  (or (< lv 0) (>= (- frame lv) min-stale)))

(define (owm-next-stale-ring-pad owm frame
                                 #:own-base-pts [own-base-pts '()]
                                 #:min-stale-frames [min-stale 1344])
  (define st (owm-l86-ring-state owm))
  (define pads (if (hash? st) (hash-ref st 'ring-pads '()) '()))
  (define f (if (exact-integer? frame) frame (if (real? frame) (exact-round frame) 0)))
  (define ms (if (real? min-stale) (max 0 (exact-round min-stale)) 1344))
  (define ob-list (if (list? own-base-pts) own-base-pts '()))
  (define best-rp
    (for/fold ([best #f])
              ([rp (in-list pads)]
               #:when (and (vector? rp)
                           (>= (vector-length rp) 6)
                           (not (pad-near-own-base? (vector-ref rp 0) (vector-ref rp 1) ob-list))
                           (pad-is-stale? rp f ms)))
      (cond
        [(not best) rp]
        [(< (vector-ref rp 2) (vector-ref best 2)) rp]
        [(and (= (vector-ref rp 2) (vector-ref best 2))
              (< (vector-ref rp 5) (vector-ref best 5)))
         rp]
        [else best])))
  (and best-rp (cons (vector-ref best-rp 0) (vector-ref best-rp 1))))

(define (owm-stale-ring-pad-count owm frame
                                  #:own-base-pts [own-base-pts '()]
                                  #:min-stale-frames [min-stale 1344])
  (define st (owm-l86-ring-state owm))
  (define pads (if (hash? st) (hash-ref st 'ring-pads '()) '()))
  (define f (if (exact-integer? frame) frame (if (real? frame) (exact-round frame) 0)))
  (define ms (if (real? min-stale) (max 0 (exact-round min-stale)) 1344))
  (define ob-list (if (list? own-base-pts) own-base-pts '()))
  (for/sum ([rp (in-list pads)])
    (if (and (vector? rp)
             (>= (vector-length rp) 6)
             (not (pad-near-own-base? (vector-ref rp 0) (vector-ref rp 1) ob-list))
             (pad-is-stale? rp f ms))
        1
        0)))

(define (owm-confirmed-enemy-base-pts owm)
  (define st (owm-l86-ring-state owm))
  (if (hash? st) (hash-ref st 'confirmed-enemy-base-pts '()) '()))

(define (owm-enemy-turtle-breakdown owm)
  (define st (owm-l86-ring-state owm))
  (if (hash? st) (hash-ref st 'turtle-breakdown DEFAULT-TURTLE-BREAKDOWN) DEFAULT-TURTLE-BREAKDOWN))

(define (owm-estimated-enemy-bases owm)
  (define st (owm-l86-ring-state owm))
  (if (hash? st) (hash-ref st 'estimated-enemy-bases 1) 1))

(define (owm-estimated-enemy-gases owm)
  (define st (owm-l86-ring-state owm))
  (if (hash? st) (hash-ref st 'estimated-enemy-gases 0) 0))

(define (owm-estimated-min-rate owm)
  (define st (owm-l86-ring-state owm))
  (if (hash? st) (hash-ref st 'min-rate-per-min 0) 0))

(define (owm-estimated-gas-rate owm)
  (define st (owm-l86-ring-state owm))
  (if (hash? st) (hash-ref st 'gas-rate-per-min 0) 0))

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
  (hash-set! owm-l86-ring-state-table owm (make-l86-ring-state))
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
  (hash-set! owm-l86-ring-state-table owm (make-l86-ring-state))
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
      (let ([t (hash-ref u 'type
                         (lambda ()
                           (hash-ref u 'unit-type
                                     (lambda ()
                                       (hash-ref u 'unit-type-id 'unknown)))))])
        (cond
          [(symbol? t) t]
          [(or (exact-integer? t) (string? t)) (canonical-unit-type-sym t)]
          [else 'unknown]))
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
    [(planetary-fortress) '(engineering-bay)]
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
;; Past these deadlines, a rational macro player has STARTED their 2nd..6th base.
;; If they have NOT, they are deviating from the happy path to invest in Army / Tech!
(define (happy-path-expected-bases enemy-race frame)
  (define sec (/ (exact->inexact (max 0 frame)) 22.4))
  (case enemy-race
    [(Zerg)
     (cond [(>= sec 720.0) 6]
           [(>= sec 570.0) 5]
           [(>= sec 420.0) 4]
           [(>= sec 215.0) 3]
           [(>= sec 78.0)  2]
           [else           1])]
    [(Protoss)
     (cond [(>= sec 840.0) 6]
           [(>= sec 690.0) 5]
           [(>= sec 540.0) 4]
           [(>= sec 355.0) 3]
           [(>= sec 120.0) 2]
           [else           1])]
    [else ; Terran / Unknown
     (cond [(>= sec 870.0) 6]
           [(>= sec 720.0) 5]
           [(>= sec 570.0) 4]
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
;; Internal 7-value integrator returning cumulative totals + instantaneous
;; final-step `min-rate-per-min` (`M/min`) and `gas-rate-per-min` (`G/min`).
;; Loop 87B Calibration:
;;   - Models worker-kill attrition inside the integration loop so active TownHalls
;;     rebuild killed workers naturally over time (no permanent cumulative subtraction!).
;;   - Calibrated SC2 Faster gas harvest rate (`0.87 G/worker-sec` = `156.6 G/min/geyser`,
;;     avg `2.65` effective gas-workers per active geyser) and earlier `baseline-g` ramp
;;     starting at `55s` (suppressed when main was swept gas-free early).
;; Public `integrate-opponent-economy` preserves its exact 5-value return arity.
(define (integrate-opponent-economy/rates enemy-race frame base-ready-frames geyser-entries workers-killed
                                          [kill-events '()]
                                          [seen-workers 0]
                                          [main-gas-free? #f])
  (define f-sec (/ (exact->inexact (max 0 frame)) 22.4))
  (define w-cap-race
    (case enemy-race
      [(Zerg) 70.0]
      [(Protoss) 68.0]
      [else 64.0]))
  (define w-rate-mult
    (case enemy-race
      ;; Zerg shares Larva across Drones/Overlords/Army and consumes Drones into structures,
      ;; so net sustained worker growth is lower than parallel Nexus/CC production.
      [(Zerg) 0.90]
      [(Protoss) 0.96]
      [else 0.92]))
  ;; Separate geysers with exact observed vespene depletion (`2250 - vespene_contents` at `t_seen`)
  ;; from geysers estimated purely by ready-frame integration!
  (define geyser-ready-secs
    (for/list ([ge (in-list geyser-entries)])
      (/ (exact->inexact (car ge)) 22.4)))
  (define kill-sec-events
    (for/list ([ke (in-list kill-events)]
               #:when (and (pair? ke) (real? (car ke)) (real? (cdr ke)) (> (cdr ke) 0)))
      (cons (/ (exact->inexact (max 0 (car ke))) 22.4)
            (exact->inexact (cdr ke)))))
  (define has-kill-events? (pair? kill-sec-events))
  (define recent-kills-90s
    (if has-kill-events?
        (for/sum ([ks (in-list kill-sec-events)]
                  #:when (<= (- f-sec (car ks)) 90.0))
          (cdr ks))
        (exact->inexact (max 0 workers-killed))))
  (let loop ([s 0.0] [w 12.0] [w-born 12.0] [cum-m 50.0] [cum-g-rate 0.0] [cum-g-unobs 0.0]
             [last-b 1] [last-g 0] [last-eff-g 0.0] [last-sat-cap 18.0]
             [last-opt-rate 0.0] [last-mule-bonus 0.0])
    (if (>= s f-sec)
        (let* (;; Apply kills that occurred at exact current frame (`>= f-sec`), or stateless
               ;; decayed kill debt when caller didn't pass timestamped `kill-events`.
               [end-kills
                (if has-kill-events?
                    (for/sum ([ks (in-list kill-sec-events)]
                              #:when (>= (car ks) f-sec))
                      (cdr ks))
                    (let* ([wk-fl (exact->inexact (max 0 workers-killed))]
                           ;; Stateless fallback: old kills recover slowly over elapsed time
                           [max-debt (max 0.0 (- w 4.0))])
                      (min max-debt wk-fl)))]
               [w-after-end (max 4.0 (- w end-kills))]
               [eff-w-raw (max 4 seen-workers (exact-round w-after-end))]
               ;; Multi-base macro saturation floor when opponent has >= 2 bases past 5:00
               ;; and suffered < 6 worker kills in the last 90s (old kills have been rebuilt!).
               [eff-w
                (if (and (>= last-b 2) (>= f-sec 300.0) (< recent-kills-90s 6.0))
                    (max eff-w-raw (exact-round (* 0.70 last-sat-cap)))
                    eff-w-raw)]
               ;; Reconcile gas against exact observed geyser depletion anchors when available!
               ;; SC2 Faster 3-worker saturated geyser harvests ~2.61 G/sec (~156.6 G/min).
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
                     (min 2250 (+ mined-at-seen (exact-round (* 2.61 post-sec))))]
                    [(< rdy-s f-sec)
                     (min 2250 (exact-round (* 2.61 (- f-sec rdy-s))))]
                    [else 0]))]
               [final-gas (max (exact-round cum-g-rate) anchored-gas)]
               [eff-w-fl (exact->inexact eff-w)]
               [wg-tot-now (max 0.0 (min (* 2.65 last-eff-g) (- eff-w-fl 10.0)))]
               [wg-conf-now (max 0.0 (min (* 2.85 (exact->inexact last-g)) (- eff-w-fl 8.0)))]
               [wg-now (max wg-tot-now wg-conf-now)]
               [wm-now (max 0.0 (- eff-w-fl wg-now))]
               [wm-opt-now (min wm-now (* 16.0 (exact->inexact last-b)))]
               [wm-ovr-now (max 0.0 (min (- wm-now wm-opt-now) (* 6.0 (exact->inexact last-b))))]
               [min-rate-per-min
                (if (< f-sec 5.0)
                    0
                    (max 0 (exact-round (* 60.0 (+ (* last-opt-rate wm-opt-now)
                                                   (* 0.38 wm-ovr-now)
                                                   last-mule-bonus)))))]
               [gas-rate-per-min
                (if (< f-sec 5.0)
                    0
                    (max 0 (exact-round (* 60.0 (* 0.87 wg-now)))))])
          (values (exact-round cum-m)
                  final-gas
                  (exact-round cum-g-unobs)
                  eff-w
                  (exact-round w-born)
                  min-rate-per-min
                  gas-rate-per-min))
        (let* ([dt (min 5.0 (- f-sec s))]
               [s-next (+ s dt)]
               [b (max 1 (count (lambda (rf) (<= (/ (exact->inexact rf) 22.4) s)) base-ready-frames))]
               [g (min (* 2 b) (count (lambda (gs) (<= gs s)) geyser-ready-secs))]
               ;; Earlier baseline gas ramp (`s >= 55s`, ~1.1 by 1:50, ~1.5 by 2:15, scaling
               ;; smoothly to ~1.05..1.65 gases/base midgame; 0 if main was swept gas-free early).
               [baseline-g
                (cond
                  [(and main-gas-free? (< s 180.0)) 0.0]
                  [(< s 55.0) 0.0]
                  [(< s 135.0) (min (* 2.0 b) (+ 0.25 (* 1.25 (/ (- s 55.0) 80.0))))]
                  [else
                   (define g-per-b (min 1.65 (+ 1.05 (* 0.0014 (max 0.0 (- s 180.0))))))
                   (min (* 2.0 b) (* g-per-b (exact->inexact b)))])]
               [eff-g (max (exact->inexact g) baseline-g)]
               [sat-cap (min w-cap-race (+ (* 16.0 b) (* 3.0 eff-g) 2.0))]
               ;; Subtract kills occurring in `[s, s + dt)` BEFORE applying TownHall worker rebuild!
               [step-kills
                (if has-kill-events?
                    (for/sum ([ks (in-list kill-sec-events)]
                              #:when (and (>= (car ks) s) (< (car ks) s-next)))
                      (cdr ks))
                    0.0)]
               [w-post-kill (max 4.0 (- w step-kills))]
               ;; Opening worker-production efficiency ramp (supply/tech/expand build windows)
               [ramp-eff (cond [(< s 90.0) 0.82] [(< s 180.0) 0.92] [else 1.00])]
               [dw (max 0.0 (min (- sat-cap w-post-kill)
                                 (* dt ramp-eff w-rate-mult (/ (min 3.5 (exact->inexact b)) 12.0))))]
               [w-next (+ w-post-kill dw)]
               [w-mid (if has-kill-events?
                          (max 4.0 (* 0.5 (+ w-post-kill w-next)))
                          (max 4.0 (- (* 0.5 (+ w-post-kill w-next))
                                      (if (>= s (* 0.5 f-sec)) (* 0.5 (exact->inexact workers-killed)) 0.0))))]
               [wg-tot (max 0.0 (min (* 2.65 eff-g) (- w-mid 10.0)))]
               [wg-conf (max 0.0 (min (* 2.85 g) (- w-mid 8.0)))]
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
               ;; Empirically calibrated LotV Faster-speed (22.4 loops/sec) harvest rates:
               ;; 0 for opening 5s walk; 0.84 min/mineral-worker-sec tapering to 0.76 late,
               ;; 0.38 oversaturated, 0.87 gas/worker-sec (~156.6 G/min/geyser).
               [opt-rate
                (cond
                  [(< s 5.0) 0.0]
                  [(<= s 420.0) 0.84]
                  [else (max 0.76 (- 0.84 (* 0.08 (/ (- s 420.0) 360.0))))])]
               [dm (* dt (+ (* opt-rate wm-opt) (* 0.38 wm-ovr) mule-bonus))]
               [dg-conf (* dt 0.87 wg-conf)]
               [dg-unobs (* dt 0.87 wg-unobs)])
          (loop s-next w-next (+ w-born dw) (+ cum-m dm) (+ cum-g-rate dg-conf) (+ cum-g-unobs dg-unobs)
                b g eff-g sat-cap opt-rate mule-bonus)))))

(define (integrate-opponent-economy enemy-race frame base-ready-frames geyser-entries workers-killed)
  (define-values (cum-m final-gas cum-g-unobs eff-w w-born _min-rate _gas-rate)
    (integrate-opponent-economy/rates enemy-race frame base-ready-frames geyser-entries workers-killed))
  (values cum-m final-gas cum-g-unobs eff-w w-born))

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
  (define pads-reanchored?
    (or (not (opponent-world-model-pads-initialized? owm))
        (null? cur-pads)
        (> (dist2 enemy-x enemy-y
                  (pad-belief-entry-x (car cur-pads))
                  (pad-belief-entry-y (car cur-pads)))
           144.0)))
  (when pads-reanchored?
    (set-opponent-world-model-pads!
     owm
     (list (pad-belief-entry 'enemy-main enemy-x enemy-y 'confirmed-base -1 -9999 0)
           (pad-belief-entry 'enemy-natural enemy-nat-x enemy-nat-y 'unscouted #f -9999 -9999)
           (pad-belief-entry 'enemy-third enemy-third-x enemy-third-y 'unscouted #f -9999 -9999)
           (pad-belief-entry 'enemy-fourth enemy-fourth-x enemy-fourth-y 'unscouted #f -9999 -9999)))
    (set-opponent-world-model-pads-initialized?! owm #t))

  ;; L86 Track 1: Lazy ingestion & deduplication (`>= 8.0t`) of full map expansion ring pads
  (define ring-st
    (or (hash-ref owm-l86-ring-state-table owm #f)
        (let ([s (make-l86-ring-state)])
          (hash-set! owm-l86-ring-state-table owm s)
          s)))
  (define raw-exp-pads
    (let ([p1 (hash-ref obs 'expansion-pads #f)])
      (if (and (list? p1) (pair? p1))
          p1
          (let ([p2 (hash-ref obs 'expansion-candidates #f)])
            (if (and (list? p2) (pair? p2)) p2 '())))))
  (define cur-ring-pads (hash-ref ring-st 'ring-pads '()))
  (when (and pads-reanchored? (pair? cur-ring-pads))
    (for ([rp (in-list cur-ring-pads)])
      (vector-set! rp 5 (sqrt (dist2 (vector-ref rp 0) (vector-ref rp 1) enemy-x enemy-y))))
    (set! cur-ring-pads (sort cur-ring-pads < #:key (lambda (rp) (vector-ref rp 5))))
    (hash-set! ring-st 'ring-pads cur-ring-pads))
  (when (pair? raw-exp-pads)
    (define added? #f)
    (define acc (reverse cur-ring-pads))
    (for ([raw-p (in-list raw-exp-pads)])
      (define-values (px py) (extract-pad-xy raw-p))
      (when (and px py
                 (not (for/or ([existing (in-list acc)])
                        (< (dist2 px py (vector-ref existing 0) (vector-ref existing 1)) 64.0))))
        (define d-em (sqrt (dist2 px py enemy-x enemy-y)))
        (set! acc (cons (vector px py -9999 #f -9999 d-em) acc))
        (set! added? #t)))
    (when added?
      (set! cur-ring-pads (sort acc < #:key (lambda (rp) (vector-ref rp 5))))
      (hash-set! ring-st 'ring-pads cur-ring-pads)))

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
  (define observed-upgs (opponent-world-model-observed-upgrades-set owm))

  ;; Step A: Process explicit `dead-unit-tags` from wire
  (define raw-unit-types
    (or (hash-ref ring-st 'raw-unit-types #f)
        (let ([ht (make-hasheqv)])
          (hash-set! ring-st 'raw-unit-types ht)
          ht)))
  (define kinematic-anchors
    (or (hash-ref ring-st 'kinematic-anchors #f)
        (let ([ht (make-hasheqv)])
          (hash-set! ring-st 'kinematic-anchors ht)
          ht)))
  (define kinematic-hits
    (or (hash-ref ring-st 'kinematic-hits #f)
        (let ([ht (make-hasheq)])
          (hash-set! ring-st 'kinematic-hits ht)
          ht)))
  (define unupg-seen-ht
    (or (hash-ref ring-st 'unupg-seen-frame #f)
        (let ([ht (make-hasheq)])
          (hash-set! ring-st 'unupg-seen-frame ht)
          ht)))
  (define tech-first-seen-ht
    (or (hash-ref ring-st 'tech-first-seen-frame #f)
        (let ([ht (make-hasheq)])
          (hash-set! ring-st 'tech-first-seen-frame ht)
          ht)))
  (define (record-tech-first-seen! sym f)
    (define prev (hash-ref tech-first-seen-ht sym #f))
    (when (or (not (exact-integer? prev)) (< f prev))
      (hash-set! tech-first-seen-ht sym f)))
  (define dead-tags-this-step (mutable-seteqv))
  (for ([dtag (in-list dead-tags-now)]
        #:when (and (exact-integer? dtag) (> dtag 0)))
    (set-add! dead-tags-this-step dtag)
    (unless (set-member? dead-tags dtag)
      (set-add! dead-tags dtag)
      (hash-remove! kinematic-anchors dtag)
      (cond
        [(hash-has-key? known-units dtag)
         (define rec (hash-ref known-units dtag))
         (hash-remove! known-units dtag)
         (hash-remove! raw-unit-types dtag)
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
          owm (+ (opponent-world-model-confirmed-destroyed-gas owm) (tracked-enemy-bldg-gas-cost rec)))])))

  ;; Step B: Ingest currently observed enemy structures
  ;; L86D: Spatial dedup across SC2 Protobuf `Snapshot` tag-churn! Every time an enemy structure
  ;; enters fog of war, SC2 assigns a brand-new `Snapshot` tag ID (and morphs change type).
  ;; Before inserting `tag`, evict any existing `old-tag != tag` of the same structure family
  ;; within footprint-safe radius (`4.0t` for TownHalls/Geysers, `1.5t` for 2x2 structures so
  ;; adjacent 2.0t side-by-side Turrets/Cannons/Pylons never merge, `2.5t` for 3x3+ structures),
  ;; carrying forward earliest `start-f`, `ready-f`, max `build-progress` (same type), and lowest
  ;; positive `vespene-contents` WITHOUT poisoning `dead-tags`!
  (define (same-bldg-family? ct1 ct2)
    (or (eq? ct1 ct2)
        (and (hash-has-key? TOWNHALL-SYM-SET ct1)
             (hash-has-key? TOWNHALL-SYM-SET ct2))
        (and (hash-has-key? GEYSER-BLDG-SYM-SET ct1)
             (hash-has-key? GEYSER-BLDG-SYM-SET ct2))
        (and (memq ct1 '(gateway warp-gate))
             (memq ct2 '(gateway warp-gate)))
        (and (memq ct1 '(spire greater-spire))
             (memq ct2 '(spire greater-spire)))))
  (define (bldg-dedup-r2 ct)
    (cond
      [(or (hash-has-key? TOWNHALL-SYM-SET ct)
           (hash-has-key? GEYSER-BLDG-SYM-SET ct))
       16.0] ; 4.0t (distinct TownHalls >= 5.0t, distinct Geysers >= 5.0t)
      [(memq ct '(pylon supply-depot photon-cannon shield-battery missile-turret
                  spine-crawler spore-crawler sensor-tower dark-shrine creep-tumor))
       2.25] ; 1.5t (distinct adjacent 2x2 buildings are >= 2.0t apart -> dist2 >= 4.0)
      [else
       6.25])) ; 2.5t (distinct adjacent 3x3+ buildings are >= 3.0t apart -> dist2 >= 9.0)
  (define seen-bldg-tags-now (mutable-seteqv))
  (for ([b (in-list enemy-bldgs)] #:when (hash? b))
    (define tag (hash-ref b 'id 0))
    (when (and (exact-integer? tag) (> tag 0) (not (set-member? dead-tags-this-step tag)))
      (set-add! seen-bldg-tags-now tag)
      (define prev-direct (hash-ref known-bldgs tag #f))
      (define btype (unit-type-sym b))
      (define bx (exact->inexact (hash-ref b 'x enemy-x)))
      (define by (exact->inexact (hash-ref b 'y enemy-y)))
      (define bhp (max 1 (exact-round (hash-ref b 'hp 500))))
      (define bprog (max 0.0 (min 1.0 (exact->inexact (hash-ref b 'build-progress 1.0)))))
      (define vcont (hash-ref b 'vespene-contents 0))
      (define act? (not (not (or (hash-ref b 'active? #f) (hash-ref b 'active #f)))))
      (define prox? (not (not (hash-ref b 'is-proxy? #f))))
      (cond
        ;; L86E O(1) Fast Path (~99% of calls): already-tracked tag with unchanged type skips
        ;; full-hash spatial dedup scan, `implied-tech-prereqs`, and `near-pad` scan completely!
        [(and prev-direct (eq? (tracked-enemy-bldg-type prev-direct) btype))
         (define old-vcont (tracked-enemy-bldg-vespene-contents prev-direct))
         (define best-vcont
           (cond
             [(and (exact-integer? vcont) (> vcont 0))
              (if (> old-vcont 0) (min vcont old-vcont) vcont)]
             [(> old-vcont 0) old-vcont]
             [else 0]))
         (hash-set! known-bldgs tag
                    (tracked-enemy-bldg tag
                                        btype
                                        (tracked-enemy-bldg-canon-type prev-direct)
                                        bx by bhp
                                        (max bprog (tracked-enemy-bldg-build-progress prev-direct))
                                        (tracked-enemy-bldg-start-frame prev-direct)
                                        (tracked-enemy-bldg-ready-frame prev-direct)
                                        best-vcont
                                        act? prox? frame
                                        (tracked-enemy-bldg-min-cost prev-direct)
                                        (tracked-enemy-bldg-gas-cost prev-direct)))]
        [else
         (define ctype (sc2-canonical-structure-sym btype))
         (when (eq? ctype 'warp-gate)
           (set-add! observed-upgs 'warp-gate-research))
         (when (set-member? dead-tags tag)
           (set-remove! dead-tags tag))
         (set-remove! destroyed-tech ctype)
         (for ([p (in-list (implied-tech-prereqs ctype))])
           (set-add! implied-set p))
         ;; Spatial dedup ONLY runs on genuinely new/Snapshot tags (`not prev-direct`)!
         (define replaced-recs
           (if prev-direct
               '()
               (let ([dedup-r2 (bldg-dedup-r2 ctype)])
                 (for/list ([(old-tag old-rec) (in-hash known-bldgs)]
                            #:when (and (not (= old-tag tag))
                                        (same-bldg-family? (tracked-enemy-bldg-canon-type old-rec) ctype)
                                        (let ([d2 (dist2 bx by (tracked-enemy-bldg-x old-rec) (tracked-enemy-bldg-y old-rec))])
                                          (if (set-member? seen-bldg-tags-now old-tag)
                                              (<= d2 1.0)
                                              (<= d2 dedup-r2)))))
                   (cons old-tag old-rec)))))
         (for ([pair (in-list replaced-recs)])
           (hash-remove! known-bldgs (car pair)))
         (define prior-recs
           (if prev-direct
               (cons prev-direct (map cdr replaced-recs))
               (map cdr replaced-recs)))
         (define b-frames (structure-build-frames ctype))
         (define start-f
           (if (pair? prior-recs)
               (apply min (map tracked-enemy-bldg-start-frame prior-recs))
               (cond
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
                      (max 0 (- frame b-frames)))])))
         (define ready-f
           (let ([rf (+ start-f b-frames)])
             (for/fold ([best rf]) ([pr (in-list prior-recs)])
               (if (eq? (tracked-enemy-bldg-canon-type pr) ctype)
                   (min best (tracked-enemy-bldg-ready-frame pr))
                   best))))
         (define best-bprog
           (for/fold ([bp bprog]) ([pr (in-list prior-recs)])
             (if (eq? (tracked-enemy-bldg-canon-type pr) ctype)
                 (max bp (tracked-enemy-bldg-build-progress pr))
                 bp)))
         ;; Preserve lowest observed positive vespene-contents (`snapshot` buildings often report 0)
         (define best-vcont
           (let ([pos-vals
                  (append (if (and (exact-integer? vcont) (> vcont 0)) (list vcont) '())
                          (for/list ([pr (in-list prior-recs)]
                                     #:when (> (tracked-enemy-bldg-vespene-contents pr) 0))
                            (tracked-enemy-bldg-vespene-contents pr)))])
             (if (pair? pos-vals) (apply min pos-vals) 0)))
         (hash-set! known-bldgs tag
                    (tracked-enemy-bldg tag btype ctype bx by bhp best-bprog start-f ready-f
                                        best-vcont act? prox? frame
                                        (max 0 (sc2-min-cost ctype))
                                        (max 0 (sc2-gas-cost ctype))))
         (record-tech-first-seen! ctype ready-f)
         (when (eq? ctype 'hydralisk-den)
           (record-tech-first-seen! 'hydralisk-tech ready-f))])))

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
  ;; L86E: Only check `replaced-by-live-alias?` lazily when a building is unseen AND about to be
  ;; sight-cleared (eliminates eager O(N*M) nested scan over `seen-bldg-tags-now` every step!).
  (define tags-to-sight-clear
    (for/list ([(tag rec) (in-hash known-bldgs)]
               #:when (and (not (set-member? seen-bldg-tags-now tag))
                           (not (memq (tracked-enemy-bldg-type rec)
                                      '(barracks-flying factory-flying starport-flying
                                        command-center-flying orbital-command-flying
                                        spine-crawler-uprooted spore-crawler-uprooted)))
                           (ally-can-sight-clear-bldg? rec)
                           (let* ([ct (tracked-enemy-bldg-canon-type rec)]
                                  [r2 (bldg-dedup-r2 ct)]
                                  [rx (tracked-enemy-bldg-x rec)]
                                  [ry (tracked-enemy-bldg-y rec)])
                             (not (for/or ([stag (in-set seen-bldg-tags-now)])
                                    (define srec (hash-ref known-bldgs stag #f))
                                    (and srec
                                         (same-bldg-family? (tracked-enemy-bldg-canon-type srec) ct)
                                         (<= (dist2 rx ry
                                                    (tracked-enemy-bldg-x srec)
                                                    (tracked-enemy-bldg-y srec))
                                             r2)))))))
      (cons tag rec)))
  (for ([kv (in-list tags-to-sight-clear)])
    (define tag (car kv))
    (define rec (cdr kv))
    (define ct (tracked-enemy-bldg-canon-type rec))
    (define liftable-bldg?
      (not (not (memq ct '(command-center orbital-command barracks factory starport)))))
    (hash-remove! known-bldgs tag)
    ;; L86B: Do NOT permanently poison `dead-tags` when sight-clearing liftable Terran structures
    ;; (e.g. a Command Center floated to an expansion pad and morphed into a Planetary Fortress!).
    (unless liftable-bldg?
      (set-add! dead-tags tag)
      (set-add! destroyed-tech ct)
      (set-opponent-world-model-confirmed-destroyed-min!
       owm (+ (opponent-world-model-confirmed-destroyed-min owm) (tracked-enemy-bldg-min-cost rec)))
      (set-opponent-world-model-confirmed-destroyed-gas!
       owm (+ (opponent-world-model-confirmed-destroyed-gas owm) (tracked-enemy-bldg-gas-cost rec)))))

  ;; Step D: Ingest currently observed enemy units (separating free summons!)
  (define active-summon-cnt 0)
  (define active-locust-cnt 0)
  (define seen-unit-tags-now (mutable-seteqv))
  (define ally-is-zerg?
    (for/or ([au (in-list ally-units)] #:when (hash? au))
      (eq? (hash-ref RACE-DETECTION-HT (unit-type-sym au) #f) 'Zerg)))
  (define (record-kinematic-hit! upg-sym req-hits)
    (unless (set-member? observed-upgs upg-sym)
      (define nxt (add1 (hash-ref kinematic-hits upg-sym 0)))
      (hash-set! kinematic-hits upg-sym nxt)
      (when (>= nxt req-hits)
        (set-add! observed-upgs upg-sym))))
  (define (near-own-creep-free-main? ux uy)
    (and (not ally-is-zerg?)
         (<= frame 13440)
         (<= (dist2 ux uy base-x base-y) 324.0)
         (not (for/or ([rec (in-hash-values known-bldgs)])
                (and (memq (tracked-enemy-bldg-canon-type rec)
                           '(hatchery lair hive creep-tumor creep-tumor-burrowed creep-tumor-queen))
                     (<= (dist2 ux uy (tracked-enemy-bldg-x rec) (tracked-enemy-bldg-y rec)) 256.0))))))

  (for ([u (in-list enemy-units)] #:when (hash? u))
    (define utype (unit-type-sym u))
    (define halluc? (or (hash-ref u 'is-hallucination #f) (hash-ref u 'hallucination #f)))
    (define visible-unit? (not (equal? (hash-ref u 'display-type 1) 2)))
    (define has-atk-key? (or (hash-has-key? u 'attack-upgrade-level) (hash-has-key? u 'atk-upg)))
    (define has-arm-key? (or (hash-has-key? u 'armor-upgrade-level) (hash-has-key? u 'arm-upg)))
    (define atk-lvl (or (hash-ref u 'attack-upgrade-level #f) (hash-ref u 'atk-upg 0)))
    (define arm-lvl (or (hash-ref u 'armor-upgrade-level #f) (hash-ref u 'arm-upg 0)))
    (define shd-lvl (or (hash-ref u 'shield-upgrade-level #f) (hash-ref u 'shd-upg 0)))
    (when (and (exact-integer? atk-lvl) (> atk-lvl 0))
      (when (> atk-lvl (opponent-world-model-max-atk-upg owm))
        (set-opponent-world-model-max-atk-upg! owm atk-lvl))
      (when (>= atk-lvl 1) (set-add! observed-upgs 'enemy-weapons-1))
      (when (>= atk-lvl 2) (set-add! observed-upgs 'enemy-weapons-2))
      (when (>= atk-lvl 3) (set-add! observed-upgs 'enemy-weapons-3)))
    (when (and (exact-integer? arm-lvl) (> arm-lvl 0))
      (when (> arm-lvl (opponent-world-model-max-arm-upg owm))
        (set-opponent-world-model-max-arm-upg! owm arm-lvl))
      (when (>= arm-lvl 1) (set-add! observed-upgs 'enemy-armor-1))
      (when (>= arm-lvl 2) (set-add! observed-upgs 'enemy-armor-2))
      (when (>= arm-lvl 3) (set-add! observed-upgs 'enemy-armor-3)))
    (when (and (exact-integer? shd-lvl) (> shd-lvl 0))
      (when (> shd-lvl (opponent-world-model-max-shd-upg owm))
        (set-opponent-world-model-max-shd-upg! owm shd-lvl))
      (when (>= shd-lvl 1) (set-add! observed-upgs 'enemy-shields-1))
      (when (>= shd-lvl 2) (set-add! observed-upgs 'enemy-shields-2))
      (when (>= shd-lvl 3) (set-add! observed-upgs 'enemy-shields-3)))
    (when (and visible-unit? (not halluc?))
      (record-direct-unit-tier-upgrades! observed-upgs utype atk-lvl arm-lvl shd-lvl)
      (define mhp-obs (or (hash-ref u 'max-hp #f) (hash-ref u 'hp #f)))
      (record-unupgraded-evidence! unupg-seen-ht utype frame
                                   (and has-atk-key? atk-lvl)
                                   (and has-arm-key? arm-lvl)
                                   mhp-obs)
      (when (memq utype '(hydralisk hydralisk-burrowed))
        (record-tech-first-seen! 'hydralisk-tech frame))
      (let ([u-buffs (hash-ref u 'buffs '())])
        (when (pair? u-buffs)
          (for ([bf (in-list u-buffs)])
            (case bf
              [(stimpack stimpack-marauder) (set-add! observed-upgs 'stimpack)]
              [(neural-parasite) (set-add! observed-upgs 'neural-parasite)]
              [else (void)])))))
    (let ([u-upgs (hash-ref u 'upgrades '())])
      (when (pair? u-upgs)
        (for ([eu (in-list u-upgs)])
          (cond
            [(symbol? eu) (set-add! observed-upgs eu)]
            [(and (string? eu) (> (string-length (string-trim eu)) 0))
             (set-add! observed-upgs (string->symbol (string-downcase (string-trim eu))))]))))
    (when (and (eq? utype 'marine) (not (set-member? observed-upgs 'combat-shield)))
      (define mhp (or (hash-ref u 'max-hp #f) (hash-ref u 'hp 0)))
      (when (and (real? mhp) (>= mhp 55.0))
        (set-add! observed-upgs 'combat-shield)))
    (when (and (eq? utype 'zergling) (not (set-member? observed-upgs 'zergling-movementspeed)))
      (define spd (hash-ref u 'speed 0.0))
      (when (and (real? spd) (> spd 3.5))
        (set-add! observed-upgs 'zergling-movementspeed)))
    (when (and (eq? utype 'roach) (not (set-member? observed-upgs 'glial-reconstitution)))
      (define spd (hash-ref u 'speed 0.0))
      (when (and (real? spd) (> spd 2.5))
        (set-add! observed-upgs 'glial-reconstitution)))
    (when (and (eq? utype 'banshee) (not (set-member? observed-upgs 'cloaking-field)))
      (define clk-val (hash-ref u 'cloak 0))
      (when (or (hash-ref u 'cloaked? #f)
                (hash-ref u 'cloaked #f)
                (hash-ref u 'is-cloaked #f)
                (and (exact-integer? clk-val) (>= clk-val 1) (<= clk-val 3)))
        (set-add! observed-upgs 'cloaking-field)))
    (when (and (eq? utype 'ghost) (not (set-member? observed-upgs 'personal-cloaking)))
      (define clk-val (hash-ref u 'cloak 0))
      (when (or (hash-ref u 'cloaked? #f)
                (hash-ref u 'cloaked #f)
                (hash-ref u 'is-cloaked #f)
                (and (exact-integer? clk-val) (>= clk-val 1) (<= clk-val 3)))
        (set-add! observed-upgs 'personal-cloaking)))
    (define u-burrowed?
      (not (not (or (memq utype '(roach-burrowed zergling-burrowed baneling-burrowed
                                  hydralisk-burrowed drone-burrowed infestor-burrowed
                                  swarm-host-burrowed queen-burrowed ultralisk-burrowed))
                    (hash-ref u 'burrowed? #f)
                    (hash-ref u 'burrowed #f)
                    (hash-ref u 'is-burrowed #f)))))
    (when (and (not (set-member? observed-upgs 'burrow))
               (or (memq utype '(roach-burrowed zergling-burrowed baneling-burrowed
                                 hydralisk-burrowed drone-burrowed infestor-burrowed
                                 swarm-host-burrowed queen-burrowed ultralisk-burrowed))
                   (and (eq? erace 'Zerg)
                        (not (memq utype '(lurker lurker-mp lurker-burrowed lurker-mp-burrowed
                                           creep-tumor creep-tumor-burrowed creep-tumor-queen)))
                        u-burrowed?)))
      (set-add! observed-upgs 'burrow))

    ;; L87C Track 1: Zero-FP kinematic speed observation across consecutive visible frames.
    ;; Measures actual Faster-speed tiles/sec (`dist / ((frame - prev-f) / 22.4)`) against hard
    ;; SC2 LotV engine speed ceilings (even on creep!) to detect speed upgrades directly without
    ;; relying on an absent protobuf `speed` field or noisy elapsed-clock priors.
    (when (and visible-unit?
               (not halluc?)
               (real? (hash-ref u 'x #f))
               (real? (hash-ref u 'y #f)))
      (define ktag (hash-ref u 'id 0))
      (when (and (exact-integer? ktag) (> ktag 0) (not (set-member? dead-tags ktag)))
        (define kux (exact->inexact (hash-ref u 'x)))
        (define kuy (exact->inexact (hash-ref u 'y)))
        (define prev-k (hash-ref kinematic-anchors ktag #f))
        (cond
          [(or (not prev-k)
               (not (eq? (vector-ref prev-k 0) utype))
               (not (eq? (vector-ref prev-k 1) u-burrowed?))
               (< frame (vector-ref prev-k 4))
               (> (- frame (vector-ref prev-k 4)) 72))
           (hash-set! kinematic-anchors ktag (vector utype u-burrowed? kux kuy frame))]
          [(>= (- frame (vector-ref prev-k 4)) 16)
           (define dt-s (/ (exact->inexact (- frame (vector-ref prev-k 4))) 22.4))
           (define dx (- kux (vector-ref prev-k 2)))
           (define dy (- kuy (vector-ref prev-k 3)))
           (define dist (sqrt (+ (* dx dx) (* dy dy))))
           (define vel (/ dist dt-s))
           (case utype
             [(zergling)
              (when (and (not u-burrowed?) (>= dist 1.8) (>= vel 5.85) (<= vel 10.5))
                (record-kinematic-hit! 'zergling-movementspeed 2))]
             [(roach roach-burrowed)
              (cond
                [u-burrowed?
                 (when (and (>= dist 1.2) (>= vel 0.8) (<= vel 5.5))
                   (set-add! observed-upgs 'tunneling-claws)
                   (set-add! observed-upgs 'burrow))]
                [(and (>= dist 1.8) (>= vel 4.50) (<= vel 7.0))
                 (record-kinematic-hit! 'glial-reconstitution 2)]
                [(and (>= dist 1.8) (>= vel 3.75) (<= vel 5.0) (near-own-creep-free-main? kux kuy))
                 (record-kinematic-hit! 'glial-reconstitution 3)])]
             [(hydralisk)
              (cond
                [(and (not u-burrowed?) (>= dist 1.8) (>= vel 4.45) (<= vel 6.8))
                 (record-kinematic-hit! 'muscular-augments 2)]
                [(and (not u-burrowed?) (>= dist 1.8) (>= vel 3.60) (<= vel 4.50)
                      (near-own-creep-free-main? kux kuy))
                 (record-kinematic-hit! 'muscular-augments 3)])]
             [(overlord overlord-transport)
              (when (and (>= dist 1.1) (>= vel 1.65) (<= vel 4.0))
                (record-kinematic-hit! 'pneumatized-carapace 2))]
             [(baneling)
              (when (and (not u-burrowed?) (>= dist 1.8) (>= vel 4.85) (<= vel 6.8))
                (record-kinematic-hit! 'centrifugal-hooks 2))]
             [(zealot)
              (when (and (>= dist 1.8) (>= vel 3.85) (<= vel 12.0))
                (record-kinematic-hit! 'charge 2))]
             [(banshee)
              (when (and (>= dist 1.8) (>= vel 4.55) (<= vel 7.0))
                (record-kinematic-hit! 'hyperflight-rotors 2))]
             [else (void)])
           (hash-set! kinematic-anchors ktag (vector utype u-burrowed? kux kuy frame))]
          [else (void)])))

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
         (hash-set! raw-unit-types tag utype)
         (hash-set! known-units tag
                    (tracked-enemy-unit tag ctype ux uy uhp frame
                                        (unit-speed-tps ctype)
                                        (max 0 (sc2-supply-cost ctype))
                                        (max 0 (sc2-min-cost ctype))
                                        (max 0 (sc2-gas-cost ctype)))))]))

  ;; Direct persistent-effect spell upgrade observation (`psi-storm` -> `psi-storm-tech`)
  (when (eq? erace 'Protoss)
    (let ([effs (hash-ref obs 'effects '())])
      (when (list? effs)
        (for ([ef (in-list effs)] #:when (hash? ef))
          (when (or (eq? (hash-ref ef 'type #f) 'psi-storm)
                    (equal? (hash-ref ef 'effect-id #f) 1))
            (set-add! observed-upgs 'psi-storm-tech))))))

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
      (hash-remove! raw-unit-types tag)
      (hash-remove! kinematic-anchors tag)
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

  ;; L86 Track 1: Update full expansion-ring pad vision & enemy TownHall presence
  (define visible-enemy-th-pts
    (for/list ([b (in-list enemy-bldgs)]
               #:when (and (hash? b)
                           (hash-has-key? TOWNHALL-SYM-SET (sc2-canonical-structure-sym (unit-type-sym b)))
                           (not (hash-ref b 'is-proxy? #f))
                           (real? (hash-ref b 'x #f))
                           (real? (hash-ref b 'y #f))))
      (cons (exact->inexact (hash-ref b 'x)) (exact->inexact (hash-ref b 'y)))))
  (define scanner-sweep-pts
    (let ([effs (hash-ref obs 'effects '())])
      (if (list? effs)
          (for/list ([ef (in-list effs)]
                     #:when (and (hash? ef)
                                 (or (eq? (hash-ref ef 'type #f) 'scanner-sweep)
                                     (equal? (hash-ref ef 'effect-id #f) 6)
                                     (equal? (hash-ref ef 'id #f) 6))
                                 (real? (hash-ref ef 'x #f))
                                 (real? (hash-ref ef 'y #f))))
            (cons (exact->inexact (hash-ref ef 'x)) (exact->inexact (hash-ref ef 'y))))
          '())))
  (define (ally-or-scan-sees-point? px py r2)
    (or (ally-sees-point? ally-units px py r2)
        (for/or ([sp (in-list scanner-sweep-pts)])
          (<= (dist2 (car sp) (cdr sp) px py) 169.0))))
  (define (visible-enemy-th-near? px py r2)
    (for/or ([pt (in-list visible-enemy-th-pts)])
      (<= (dist2 (car pt) (cdr pt) px py) r2)))
  (for ([rp (in-list cur-ring-pads)])
    (define px (vector-ref rp 0))
    (define py (vector-ref rp 1))
    (define vis-th? (visible-enemy-th-near? px py 100.0))
    (define tracked-th
      (and (not vis-th?)
           (for/first ([th (in-list th-bldgs)]
                       #:when (<= (dist2 (tracked-enemy-bldg-x th) (tracked-enemy-bldg-y th) px py) 100.0))
             th)))
    (define visited-now? (ally-or-scan-sees-point? px py 144.0))
    (define cleared-now? (and (not vis-th?) (ally-or-scan-sees-point? px py 100.0)))
    (when (or visited-now? vis-th?)
      (vector-set! rp 2 frame))
    (cond
      [vis-th?
       (vector-set! rp 3 #t)
       (vector-set! rp 4 frame)]
      [cleared-now?
       (vector-set! rp 3 #f)]
      [tracked-th
       (vector-set! rp 3 #t)
       (vector-set! rp 4 (max (vector-ref rp 4) (tracked-enemy-bldg-last-seen-frame tracked-th)))]
      [else (void)]))

  (define main-pad-empty?
    (let ([mp (and (pair? (opponent-world-model-pads owm)) (car (opponent-world-model-pads owm)))])
      (and mp (eq? (pad-belief-entry-state mp) 'confirmed-empty))))
  (define confirmed-enemy-base-pts
    (let* ([raw-pts
            (append
             (if main-pad-empty? '() (list (cons enemy-x enemy-y)))
             (for/list ([th (in-list th-bldgs)])
               (cons (tracked-enemy-bldg-x th) (tracked-enemy-bldg-y th)))
             visible-enemy-th-pts
             (for/list ([rp (in-list cur-ring-pads)]
                        #:when (vector-ref rp 3))
               (cons (vector-ref rp 0) (vector-ref rp 1))))]
           [pruned
            (for/list ([pt (in-list raw-pts)]
                       #:when (or (visible-enemy-th-near? (car pt) (cdr pt) 100.0)
                                  (not (ally-or-scan-sees-point? (car pt) (cdr pt) 100.0))))
              pt)])
      (reverse
       (for/fold ([dedup '()]) ([pt (in-list pruned)])
         (if (for/or ([ex (in-list dedup)])
               (< (dist2 (car pt) (cdr pt) (car ex) (cdr ex)) 64.0))
             dedup
             (cons pt dedup))))))
  (hash-set! ring-st 'confirmed-enemy-base-pts confirmed-enemy-base-pts)

  ;; Step F: Reconstruct Base & Geyser Timelines + Happy-Path Deviation
  ;; L86D: Spatially deduplicate `confirmed-base-ready-frames` (`<= 4.0t` -> `dist2 <= 16.0`)
  ;; and compute `confirmed-bases` STRICTLY from spatially deduped `confirmed-enemy-base-pts`
  ;; (NEVER un-deduped `(length th-bldgs)`!).
  (define dedup-exp-th-ready-frames
    (let ([clusters
           (for/fold ([acc '()])
                     ([th (in-list th-bldgs)]
                      #:when (> (dist2 (tracked-enemy-bldg-x th) (tracked-enemy-bldg-y th) enemy-x enemy-y) 100.0))
             (define tx (tracked-enemy-bldg-x th))
             (define ty (tracked-enemy-bldg-y th))
             (define trf (tracked-enemy-bldg-ready-frame th))
             (define matched? #f)
             (define next-acc
               (for/list ([cl (in-list acc)])
                 (if (and (not matched?)
                          (<= (dist2 tx ty (vector-ref cl 0) (vector-ref cl 1)) 16.0))
                     (begin
                       (set! matched? #t)
                       (vector (vector-ref cl 0) (vector-ref cl 1) (min trf (vector-ref cl 2))))
                     cl)))
             (if matched?
                 next-acc
                 (cons (vector tx ty trf) next-acc)))])
      (sort (map (lambda (cl) (vector-ref cl 2)) clusters) <)))
  (define confirmed-base-ready-frames
    (cons 0 ; initial main TownHall ready at frame 0
          dedup-exp-th-ready-frames))
  (define confirmed-bases
    (max 1 (length confirmed-enemy-base-pts)))
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

  ;; L86D: Spatially dedup geysers (`<= 2.5t` -> `dist2 <= 6.25`, merging tagged + untagged)
  ;; AND cap at `<= 2` geysers within `12.0t` (`144.0`) of the same expansion pad so Snapshot
  ;; tag-churn can never inflate `confirmed-geyser-cnt` above physical SC2 geyser limits!
  (define all-raw-geyser-entries
    (append
     (for/list ([rec (in-hash-values known-bldgs)]
                #:when (hash-has-key? GEYSER-BLDG-SYM-SET (tracked-enemy-bldg-canon-type rec)))
       (vector (tracked-enemy-bldg-x rec)
               (tracked-enemy-bldg-y rec)
               (tracked-enemy-bldg-ready-frame rec)
               (tracked-enemy-bldg-last-seen-frame rec)
               (tracked-enemy-bldg-vespene-contents rec)))
     (for/list ([b (in-list enemy-bldgs)]
                #:when (and (hash? b)
                            (let ([tag (hash-ref b 'id 0)])
                              (or (not (exact-integer? tag)) (<= tag 0)))
                            (hash-has-key? GEYSER-BLDG-SYM-SET (sc2-canonical-structure-sym (unit-type-sym b)))))
       (vector (exact->inexact (hash-ref b 'x enemy-x))
               (exact->inexact (hash-ref b 'y enemy-y))
               (max 0 (- frame 470))
               frame
               (let ([vc (hash-ref b 'vespene-contents 0)]) (if (exact-integer? vc) vc 0))))))
  (define dedup-geyser-vecs
    (let* ([spatially-deduped
            (reverse
             (for/fold ([acc '()]) ([g (in-list all-raw-geyser-entries)])
               (define gx (vector-ref g 0))
               (define gy (vector-ref g 1))
               (define matched? #f)
               (define next-acc
                 (for/list ([ex (in-list acc)])
                   (if (and (not matched?)
                            (<= (dist2 gx gy (vector-ref ex 0) (vector-ref ex 1)) 6.25))
                       (let* ([vc1 (vector-ref ex 4)]
                              [vc2 (vector-ref g 4)]
                              [best-vc
                               (cond [(and (> vc1 0) (> vc2 0)) (min vc1 vc2)]
                                     [(> vc1 0) vc1]
                                     [(> vc2 0) vc2]
                                     [else 0])])
                         (set! matched? #t)
                         (vector (vector-ref ex 0)
                                 (vector-ref ex 1)
                                 (min (vector-ref ex 2) (vector-ref g 2))
                                 (max (vector-ref ex 3) (vector-ref g 3))
                                 best-vc))
                       ex)))
               (if matched? next-acc (cons g next-acc))))]
           [pad-anchors
            (append confirmed-enemy-base-pts
                    (for/list ([rp (in-list cur-ring-pads)])
                      (cons (vector-ref rp 0) (vector-ref rp 1))))]
           [pad-counts (make-hasheqv)])
      (reverse
       (for/fold ([kept '()]) ([g (in-list spatially-deduped)])
         (define gx (vector-ref g 0))
         (define gy (vector-ref g 1))
         (define pad-idx
           (for/first ([pa (in-list pad-anchors)]
                       [idx (in-naturals 0)]
                       #:when (<= (dist2 gx gy (car pa) (cdr pa)) 144.0))
             idx))
         (if pad-idx
             (let ([cnt (hash-ref pad-counts pad-idx 0)])
               (if (< cnt 2)
                   (begin
                     (hash-set! pad-counts pad-idx (add1 cnt))
                     (cons g kept))
                   kept))
             (cons g kept))))))
  (define known-geysers
    (for/list ([g (in-list dedup-geyser-vecs)])
      (list (vector-ref g 2) (vector-ref g 3) (vector-ref g 4))))
  ;; If gas tech/units were implied (`extractor`/`refinery`/`assimilator` in `implied-set`) and 0 geysers directly seen,
  ;; infer at least 1 geyser ready by `min(frame - 448, 1200)`!
  (define eff-geysers
    (if (and (null? known-geysers)
             (or (set-member? implied-set 'extractor)
                 (set-member? implied-set 'refinery)
                 (set-member? implied-set 'assimilator)))
        (list (list (min (max 400 (- frame 448)) 1200) frame 0))
        known-geysers))
  (define confirmed-geyser-cnt (length eff-geysers))

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

  ;; L86C Track A: Past 6:00 (`8064f`), do NOT let main/nat production density (`>= 3 * confirmed-bases`)
  ;; freeze `eff-bases` when `>= 3` outer ring pads are stale/unscouted! Keep `stopped-expanding?`
  ;; active `< 6:00` OR when `overdue-pad-confirmed-empty?` is genuinely true.
  (define stale-ring-pads-now
    (let ([own-ref-pts (list (cons base-x base-y) (cons nat-x nat-y))])
      (for/sum ([rp (in-list cur-ring-pads)])
        (if (and (vector? rp)
                 (>= (vector-length rp) 6)
                 (not (pad-near-own-base? (vector-ref rp 0) (vector-ref rp 1) own-ref-pts))
                 (pad-is-stale? rp frame 1344))
            1 0))))
  (define prod-surge-blocks-expand?
    (and (>= prod-bldg-cnt (* 3 confirmed-bases))
         (or (< frame 8064)
             (< stale-ring-pads-now 3))))
  (define stopped-expanding?
    (or early-worker-rush-active?
        (and (< confirmed-bases happy-bases)
             (or overdue-pad-confirmed-empty?
                 prod-surge-blocks-expand?
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
  ;; `happy-bases` (up to 6th base) for unscouted (not confirmed-empty) pads so deep-fog macro
  ;; opponents keep realistic worker/base counts rather than freezing at 2 bases through 15:00!
  (define eff-base-ready-frames
    (if (and unscouted-expansion-ambiguity? (< (length confirmed-base-ready-frames) happy-bases))
        (let* ([cur-cnt (length confirmed-base-ready-frames)]
               [happy-rfs
                (for/list ([b-idx (in-range (add1 cur-cnt) (add1 happy-bases))])
                  (case b-idx
                    [(2) (case erace [(Zerg) 3340] [(Protoss) 4280] [else 4610])]
                    [(3) (case erace [(Zerg) 6400] [(Protoss) 9540] [else 9990])]
                    [(4) (case erace [(Zerg) 11000] [(Protoss) 13680] [else 14350])]
                    [(5) (case erace [(Zerg) 14350] [(Protoss) 17040] [else 17710])]
                    [else (case erace [(Zerg) 17710] [(Protoss) 20400] [else 21070])]))])
          (sort (append confirmed-base-ready-frames happy-rfs) <))
        confirmed-base-ready-frames))

  (define eff-workers-killed
    (max (opponent-world-model-workers-killed owm)
         (let ([wk (hash-ref obs 'enemy-workers-killed 0)])
           (if (exact-integer? wk) wk 0))))
  ;; L87B Track A: Track timestamped worker-kill deltas so `integrate-opponent-economy/rates`
  ;; naturally rebuilds old kills via active TownHalls instead of subtracting them forever!
  (define prev-recorded-wk (hash-ref ring-st 'last-recorded-workers-killed 0))
  (define cur-kill-events (hash-ref ring-st 'worker-kill-events '()))
  (when (> eff-workers-killed prev-recorded-wk)
    (define delta-wk (- eff-workers-killed prev-recorded-wk))
    (set! cur-kill-events (append cur-kill-events (list (cons frame delta-wk))))
    (hash-set! ring-st 'worker-kill-events cur-kill-events)
    (hash-set! ring-st 'last-recorded-workers-killed eff-workers-killed))
  (define seen-workers-pre
    (for/sum ([rec (in-hash-values known-units)]
              #:when (hash-has-key? WORKER-SYM-SET (tracked-enemy-unit-type rec)))
      1))
  (define main-gas-free-early?
    (and scouted-enemy-main?
         (= confirmed-geyser-cnt 0)
         (not (or (set-member? implied-set 'extractor)
                  (set-member? implied-set 'refinery)
                  (set-member? implied-set 'assimilator)))
         (< frame 4032)))

  (define-values (cum-min cum-gas est-unobs-gas est-workers est-workers-born
                  est-min-rate est-gas-rate)
    (integrate-opponent-economy/rates erace frame eff-base-ready-frames eff-geysers eff-workers-killed
                                      cur-kill-events seen-workers-pre main-gas-free-early?))

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
  ;; L86 Track 1: Expand turtle structure accounting to include shield-battery, planetary-fortress,
  ;; and AA static defense (`missile-turret` / `spore-crawler`, half-weighted in `siege-turtle-cnt`),
  ;; plus exact `turtle-breakdown` side-table counts.
  (define-values (sunk-tech-bldg-min sunk-tech-bldg-gas static-ground-cnt pf-cnt static-aa-cnt)
    (for/fold ([tm 0] [tg 0] [sg-cnt 0] [pfc 0] [aa-cnt 0])
              ([rec (in-hash-values known-bldgs)])
      (define ct (tracked-enemy-bldg-canon-type rec))
      (define sg-inc (if (memq ct '(bunker shield-battery photon-cannon spine-crawler)) 1 0))
      (define pf-inc (if (eq? ct 'planetary-fortress) 1 0))
      (define aa-inc (if (memq ct '(missile-turret spore-crawler)) 1 0))
      (if (or (hash-has-key? TOWNHALL-SYM-SET ct)
              (hash-has-key? GEYSER-BLDG-SYM-SET ct))
          (values tm tg (+ sg-cnt sg-inc) (+ pfc pf-inc) (+ aa-cnt aa-inc))
          (values (+ tm (tracked-enemy-bldg-min-cost rec))
                  (+ tg (tracked-enemy-bldg-gas-cost rec))
                  (+ sg-cnt sg-inc)
                  (+ pfc pf-inc)
                  (+ aa-cnt aa-inc)))))
  (define-values (untagged-sg-cnt untagged-pf-cnt untagged-aa-cnt)
    (for/fold ([sg 0] [pfc 0] [aa 0])
              ([b (in-list enemy-bldgs)] #:when (hash? b))
      (define tag (hash-ref b 'id 0))
      (if (or (not (exact-integer? tag)) (<= tag 0))
          (let ([ct (sc2-canonical-structure-sym (unit-type-sym b))])
            (values (+ sg (if (memq ct '(bunker shield-battery photon-cannon spine-crawler)) 1 0))
                    (+ pfc (if (eq? ct 'planetary-fortress) 1 0))
                    (+ aa (if (memq ct '(missile-turret spore-crawler)) 1 0))))
          (values sg pfc aa))))
  ;; Also catch weaponized static-defense structures (e.g. planetary-fortress) if passed in `enemy-units`
  ;; without duplicating any tag already tracked in `known-bldgs`!
  (define-values (unit-list-sg-cnt unit-list-pf-cnt unit-list-aa-cnt)
    (for/fold ([sg 0] [pfc 0] [aa 0])
              ([(utag rec) (in-hash known-units)]
               #:unless (hash-has-key? known-bldgs utag))
      (define ct (sc2-canonical-structure-sym (tracked-enemy-unit-type rec)))
      (values (+ sg (if (memq ct '(bunker shield-battery photon-cannon spine-crawler)) 1 0))
              (+ pfc (if (eq? ct 'planetary-fortress) 1 0))
              (+ aa (if (memq ct '(missile-turret spore-crawler)) 1 0)))))
  (define total-static-ground-cnt (+ static-ground-cnt untagged-sg-cnt unit-list-sg-cnt))
  (define total-pf-cnt (+ pf-cnt untagged-pf-cnt unit-list-pf-cnt))
  (define total-static-aa-cnt (+ static-aa-cnt untagged-aa-cnt unit-list-aa-cnt))
  (define siege-turtle-cnt
    (+ total-static-ground-cnt total-pf-cnt (quotient total-static-aa-cnt 2)))

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
  (define-values (known-army-sup known-army-min known-army-gas known-support-min known-support-gas imm-known-sup unit-siege-cnt burrow-mine-cnt siege-zone-unit-cnt)
    (for/fold ([asup 0] [amin 0] [agas 0] [smin 0] [sgas 0] [isup 0] [usiege 0] [bm-cnt 0] [sz-cnt 0])
              ([rec (in-hash-values known-units)])
      (define ut (tracked-enemy-unit-type rec))
      (hash-update! known-unit-counts-mut ut add1 0)
      (cond
        [(hash-has-key? WORKER-SYM-SET ut)
         (values asup amin agas smin sgas isup usiege bm-cnt sz-cnt)]
        [(memq ut '(overlord overlord-transport dropperlord))
         ;; Overlords are already accounted for in `sunk-supply-min` below
         (values asup amin agas smin sgas isup usiege bm-cnt sz-cnt)]
        [(memq ut '(overseer observer))
         (values asup amin agas
                 (+ smin (tracked-enemy-unit-min-cost rec))
                 (+ sgas (tracked-enemy-unit-gas-cost rec))
                 isup usiege bm-cnt sz-cnt)]
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
         ;; L86C: Count ONLY deployed/burrowed/true-turtle siege units in `siege-zone-count`
         ;; using pre-canonicalized `raw-ut` so mobile unsieged `siege-tank` / un-deployed
         ;; `liberator` / unburrowed `lurker` NEVER inflate turtle siege-zone counts!
         (define raw-ut (hash-ref raw-unit-types (tracked-enemy-unit-tag rec) ut))
         (define bm-inc
           (if (memq raw-ut '(widow-mine widow-mine-burrowed lurker-burrowed lurker-mp-burrowed))
               1 0))
         (define sz-inc
           (if (or (= bm-inc 1)
                   (memq raw-ut '(siege-tank-sieged liberator-ag tempest
                                  swarm-host swarm-host-burrowed swarm-host-mp)))
               1 0))
         (define siege-inc
           (if (or (= sz-inc 1) (eq? ut 'brood-lord))
               1 0))
         (values (+ asup usup)
                 (+ amin (tracked-enemy-unit-min-cost rec))
                 (+ agas (tracked-enemy-unit-gas-cost rec))
                 smin
                 sgas
                 (+ isup reach-inc)
                 (+ usiege siege-inc)
                 (+ bm-cnt bm-inc)
                 (+ sz-cnt sz-inc))])))
  (define-values (untagged-bm-cnt untagged-sz-cnt)
    (for/fold ([bm 0] [sz 0])
              ([u (in-list enemy-units)] #:when (hash? u))
      (define tag (hash-ref u 'id 0))
      (if (or (not (exact-integer? tag)) (<= tag 0))
          (let* ([raw-ut (unit-type-sym u)]
                 [bm-i (if (memq raw-ut '(widow-mine widow-mine-burrowed lurker-burrowed lurker-mp-burrowed)) 1 0)]
                 [sz-i (if (or (= bm-i 1)
                               (memq raw-ut '(siege-tank-sieged liberator-ag tempest
                                              swarm-host swarm-host-burrowed swarm-host-mp)))
                           1 0)])
            (values (+ bm bm-i) (+ sz sz-i)))
          (values bm sz))))
  (define total-burrow-mine-cnt (+ burrow-mine-cnt untagged-bm-cnt))
  (define total-siege-zone-cnt (+ siege-zone-unit-cnt untagged-sz-cnt))
  (define turtle-breakdown-ht
    (hasheq 'static-ground-count total-static-ground-cnt
            'pf-count total-pf-cnt
            'static-aa-count total-static-aa-cnt
            'burrow-mine-count total-burrow-mine-cnt
            'siege-zone-count total-siege-zone-cnt))
  (hash-set! ring-st 'turtle-breakdown turtle-breakdown-ht)

  ;; L86C Track A: Calibrated estimated enemy bases & gases (stored strictly in weak side-tables
  ;; so `confirmed-bases` / `confirmed-geysers` remain 100% pure for early rush detection and
  ;; the 35-field `opponent-world-summary` ABI stays untouched!).
  (define estimated-enemy-bases (max 1 (min 12 (max confirmed-bases eff-bases))))
  (define max-plausible-gases (* 2 estimated-enemy-bases))
  (define obs-total-gas-spend
    (+ known-army-gas known-support-gas obs-sunk-tech-gas
       (opponent-world-model-confirmed-destroyed-gas owm)
       (opponent-world-model-expired-sunk-gas owm)))
  (define spend-implied-gases
    (if (> obs-total-gas-spend 0)
        (exact-ceiling (/ (exact->inexact obs-total-gas-spend)
                          (* 1.85 (max 30.0 (- f-sec 85.0)))))
        0))
  (define gas-tech-min-gases
    (cond
      [(and (>= obs-total-gas-spend 250) (>= frame 3360)) 2]
      [(or (> obs-total-gas-spend 0)
           (set-member? implied-set 'extractor)
           (set-member? implied-set 'refinery)
           (set-member? implied-set 'assimilator))
       1]
      [else 0]))
  ;; L87B Track A: Conservative early gas prior from >= 100s (`2240f`) when enemy main was
  ;; NOT swept gas-free, plus calibrated mid/late `g-per-base` (`1.25 -> 1.65`) while keeping
  ;; `confirmed-geyser-cnt` 100% pure for cheese/proxy detection!
  (define main-swept-gas-free?
    (and scouted-enemy-main?
         (= confirmed-geyser-cnt 0)
         (= gas-tech-min-gases 0)
         (< frame 4032)))
  (define early-prior-g
    (if (and (>= frame 2240)
             (< frame 5376)
             (not early-worker-rush-active?)
             (not main-swept-gas-free?))
        (if (and (>= frame 3136) (not (eq? erace 'Zerg))) 2 1)
        0))
  (define econ-baseline-g
    (if (and (>= frame 5376)
             (not early-worker-rush-active?)
             (not enemy-1base-double-gas?)
             (>= estimated-enemy-bases 2))
        (let ([g-per-base (min 1.65 (+ 1.25 (* 0.0011 (max 0.0 (- f-sec 240.0)))))])
          (max 2 (exact-round (* g-per-base (exact->inexact estimated-enemy-bases)))))
        0))
  (define estimated-enemy-gases
    (if (and (< frame 1344) (= confirmed-geyser-cnt 0) (= gas-tech-min-gases 0))
        0
        (min max-plausible-gases
             (max confirmed-geyser-cnt
                  gas-tech-min-gases
                  spend-implied-gases
                  early-prior-g
                  econ-baseline-g))))
  (hash-set! ring-st 'estimated-enemy-bases estimated-enemy-bases)
  (hash-set! ring-st 'estimated-enemy-gases estimated-enemy-gases)

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
    (if (or (<= cum-gas 0) (< f-sec 85.0))
        0
        (min (quotient (* cum-gas 50) 100)
             (exact-round (+ (* 1.45 (max 0.0 (- f-sec 85.0)))
                             (* 105.0 extra-bases-built))))))
  (define baseline-tech-gas-tot
    (if (or (<= total-est-gas 0) (< f-sec 80.0))
        0
        (min (quotient (* total-est-gas 55) 100)
             (exact-round (+ (* 1.95 (max 0.0 (- f-sec 80.0)))
                             (* 135.0 extra-bases-built))))))
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

  ;; 1) Conservation-based unseen army value (`0.87` factor reflects ~12.5M/supply provider cost for unseen army,
  ;;    and unweighted `1.0x` on unobserved gas calibrated for SC2 Faster `0.87 G/w-s` collection rate)
  (define conservation-unseen-val
    (exact-round (* unseen-threat-weight
                    (+ (* 0.87 unaccounted-min)
                       (* 1.0 unaccounted-tot-gas)))))

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
  ;; L87 Track 5 + L87B Track A: Full 7-dimension calibrated belief telemetry side-table
  ;; (ZERO ABI change to 35-field `opponent-world-summary`!).
  (define seen-workers-cnt
    (for/sum ([(ut cnt) (in-hash known-unit-counts-mut)]
              #:when (hash-has-key? WORKER-SYM-SET ut))
      cnt))
  (define raw-combat-unit-counts-ht
    (for/hasheq ([(ut cnt) (in-hash known-unit-counts-mut)]
                 #:when (and (> cnt 0)
                             (not (hash-has-key? WORKER-SYM-SET ut))
                             (not (hash-has-key? FREE-SUMMON-SET ut))
                             (not (hash-has-key? TOWNHALL-SYM-SET ut))
                             (not (hash-has-key? GEYSER-BLDG-SYM-SET ut))
                             (not (memq ut '(overlord overlord-transport dropperlord
                                             bunker photon-cannon shield-battery
                                             spine-crawler spore-crawler missile-turret
                                             creep-tumor creep-tumor-burrowed creep-tumor-queen
                                             sensor-tower nydus-worm nydus-canal
                                             supply-depot pylon)))))
      (values ut cnt)))
  ;; Update decayed recent combat composition memory (for fog retention + upgrade/prod inference)
  (define recent-comp-ht
    (let ([h (hash-ref ring-st 'recent-comp-weights #f)])
      (if (and (hash? h) (not (immutable? h)))
          h
          (let ([nh (make-hasheq)])
            (hash-set! ring-st 'recent-comp-weights nh)
            nh))))
  (for ([(ut cnt) (in-hash raw-combat-unit-counts-ht)])
    (define prev (hash-ref recent-comp-ht ut #f))
    (define prev-decayed
      (if (and (pair? prev) (real? (car prev)) (exact-integer? (cdr prev)))
          (let ([age-s (/ (exact->inexact (max 0 (- frame (cdr prev)))) 22.4)])
            (* (exact->inexact (car prev)) (expt 0.5 (/ age-s 180.0))))
          0.0))
    (hash-set! recent-comp-ht ut (cons (max (exact->inexact cnt) prev-decayed) frame)))

  ;; Econ-scaled production facility counts (Zerg uses `estimated-enemy-bases`; T/P scale past 3:30)
  (define prod-counts-ht
    (compute-owm-prod-counts known-bldgs implied-set destroyed-tech erace estimated-enemy-bases
                             #:frame frame
                             #:stopped-expanding? stopped-expanding?
                             #:early-worker-rush? early-worker-rush-active?
                             #:unit-counts raw-combat-unit-counts-ht
                             #:recent-comp recent-comp-ht))

  ;; L87B Calibration 5: Unweighted (`1.0*M + 1.0*G`) `believed-army-val` matching SC2 ActiveForces,
  ;; deducting unseen inferred production surplus and trimming Zerg unscouted-ambiguity over-bias.
  (define known-army-unweighted (+ known-army-min known-army-gas))
  (define-values (inferred-prod-tot-min inferred-prod-tot-gas)
    (for/fold ([pm 0] [pg 0])
              ([(psym cnt) (in-hash prod-counts-ht)]
               #:unless (memq psym '(hatchery lair hive)))
      (values (+ pm (* cnt (max 0 (sc2-min-cost psym))))
              (+ pg (* cnt (max 0 (sc2-gas-cost psym)))))))
  (define inferred-extra-prod-min (max 0 (- inferred-prod-tot-min sunk-tech-min)))
  (define inferred-extra-prod-gas (max 0 (- inferred-prod-tot-gas tot-sunk-tech-gas)))
  (define unseen-min-unweighted (max 0 (- unaccounted-min inferred-extra-prod-min)))
  (define unseen-gas-unweighted (max 0 (- unaccounted-tot-gas inferred-extra-prod-gas)))
  (define u-wt-unweighted
    (cond
      [(< frame 1568) 0.25]
      [stopped-expanding? 0.70]
      [(eq? erace 'Zerg) 0.44]
      [unscouted-expansion-ambiguity? 0.50]
      [else 0.48]))
  (define cons-unseen-unweighted
    (exact-round (* u-wt-unweighted
                    (+ (* 0.85 (exact->inexact unseen-min-unweighted))
                       (exact->inexact unseen-gas-unweighted)))))
  (define prod-window-cap-unweighted
    (exact-round (* 0.85 (exact->inexact prod-window-cap-val))))
  (define sup-headroom-unweighted
    (* (max 0 (- max-army-sup known-army-sup)) 80))
  (define unseen-army-unweighted
    (min cons-unseen-unweighted prod-window-cap-unweighted sup-headroom-unweighted))
  (define believed-army-val-unweighted
    (+ known-army-unweighted unseen-army-unweighted))

  ;; L87B Calibration 6: Baseline Zerg Queens + fog-retained econ-proportional unit count projection
  (define combat-unit-counts-ht
    (compute-owm-projected-units raw-combat-unit-counts-ht
                                 recent-comp-ht
                                 erace
                                 frame
                                 estimated-enemy-bases
                                 believed-army-val-unweighted
                                 early-worker-rush-active?))

  ;; L87B Calibration 4 + L87C Track 1: Observed + evidence-backed canonical upgrades
  (define owm-upgrades-list
    (infer-owm-telemetry-upgrades
     (collect-owm-upgrade-symbols observed-upgs
                                  (opponent-world-model-max-atk-upg owm)
                                  (opponent-world-model-max-arm-upg owm)
                                  (opponent-world-model-max-shd-upg owm)
                                  erace)
     erace
     frame
     estimated-enemy-bases
     estimated-enemy-gases
     known-bldg-counts-mut
     implied-set
     raw-combat-unit-counts-ht
     recent-comp-ht
     #:known-bldgs known-bldgs
     #:confirmed-geysers confirmed-geyser-cnt
     #:unupg-seen unupg-seen-ht
     #:tech-first-seen tech-first-seen-ht))

  (hash-set! ring-st 'min-rate-per-min est-min-rate)
  (hash-set! ring-st 'gas-rate-per-min est-gas-rate)
  (hash-set! ring-st 'seen-workers seen-workers-cnt)
  (hash-set! ring-st 'prod-counts prod-counts-ht)
  (hash-set! ring-st 'combat-unit-counts combat-unit-counts-ht)
  (hash-set! ring-st 'owm-upgrades owm-upgrades-list)
  (hash-set! ring-st 'believed-army-val-unweighted believed-army-val-unweighted)

  (define ring-snapshot-ht
    (hasheq 'ring-pads
            (for/list ([rp (in-list cur-ring-pads)])
              (vector-immutable (vector-ref rp 0) (vector-ref rp 1)
                                (vector-ref rp 2) (vector-ref rp 3)
                                (vector-ref rp 4) (vector-ref rp 5)))
            'confirmed-enemy-base-pts confirmed-enemy-base-pts
            'turtle-breakdown turtle-breakdown-ht
            'estimated-enemy-bases estimated-enemy-bases
            'estimated-enemy-gases estimated-enemy-gases
            'min-rate-per-min est-min-rate
            'gas-rate-per-min est-gas-rate
            'seen-workers seen-workers-cnt
            'prod-counts prod-counts-ht
            'combat-unit-counts combat-unit-counts-ht
            'owm-upgrades owm-upgrades-list
            'believed-army-val-unweighted believed-army-val-unweighted))
  (hash-set! owm-summary-l86-ring-state-table summary ring-snapshot-ht)
  (set-opponent-world-model-last-summary! owm summary)
  summary)

;; -----------------------------------------------------------------------------
;; 5. Loop 87 Track 5 & Loop 87B Track A: Full 7-Dimension OWM Belief Telemetry
;; -----------------------------------------------------------------------------

(define (canonical-prod-facility-sym sym)
  (define cs (sc2-canonical-structure-sym sym))
  (case cs
    [(warp-gate warpgate) 'gateway]
    [(barracks factory starport gateway robotics-facility stargate hatchery lair hive) cs]
    [else #f]))

(define (zerg-th-prod-tier sym)
  (case sym
    [(hive) 3]
    [(lair) 2]
    [(hatchery) 1]
    [else 0]))

(define (recent-or-cur-unit-cnt ut raw-ht recent-ht frame)
  (define cur (if (hash? raw-ht) (hash-ref raw-ht ut 0) 0))
  (define rec (and (hash? recent-ht) (hash-ref recent-ht ut #f)))
  (define dec
    (if (and (pair? rec) (real? (car rec)) (exact-integer? (cdr rec)))
        (let ([age-s (/ (exact->inexact (max 0 (- frame (cdr rec)))) 22.4)])
          (if (<= age-s 240.0)
              (exact-round (* (exact->inexact (car rec)) (expt 0.5 (/ age-s 180.0))))
              0))
        0))
  (max cur dec))

(define (sum-recent-or-cur syms raw-ht recent-ht frame)
  (for/sum ([u (in-list syms)])
    (recent-or-cur-unit-cnt u raw-ht recent-ht frame)))

;; Merge spatially-deduped `known-bldgs` + tech-implied minimum `>= 1` + econ-scaled
;; production facility floor (`estimated-bases` for Zerg; T/P macro scaling past 3:30).
(define (compute-owm-prod-counts known-bldgs implied-set destroyed-tech erace est-bases
                                 #:frame [frame 0]
                                 #:stopped-expanding? [stopped-expanding? #f]
                                 #:early-worker-rush? [early-worker-rush? #f]
                                 #:unit-counts [unit-counts (hasheq)]
                                 #:recent-comp [recent-comp #f])
  (define non-zerg-clusters (make-hasheq)) ; psym -> list of (cons x y)
  (define zerg-th-clusters '())            ; list of (vector x y tier sym)
  (for ([rec (in-hash-values known-bldgs)])
    (define psym (canonical-prod-facility-sym (tracked-enemy-bldg-canon-type rec)))
    (when psym
      (define bx (tracked-enemy-bldg-x rec))
      (define by (tracked-enemy-bldg-y rec))
      (define ztier (zerg-th-prod-tier psym))
      (if (> ztier 0)
          (let ([matched? #f])
            (set! zerg-th-clusters
                  (for/list ([cl (in-list zerg-th-clusters)])
                    (if (and (not matched?)
                             (<= (dist2 bx by (vector-ref cl 0) (vector-ref cl 1)) 16.0))
                        (begin
                          (set! matched? #t)
                          (if (> ztier (vector-ref cl 2))
                              (vector (vector-ref cl 0) (vector-ref cl 1) ztier psym)
                              cl))
                        cl)))
            (unless matched?
              (set! zerg-th-clusters (cons (vector bx by ztier psym) zerg-th-clusters))))
          (let ([pts (hash-ref non-zerg-clusters psym '())])
            (unless (for/or ([pt (in-list pts)])
                      (<= (dist2 bx by (car pt) (cdr pt)) 6.25))
              (hash-set! non-zerg-clusters psym (cons (cons bx by) pts)))))))
  (define prod-mut (make-hasheq))
  (for ([(psym pts) (in-hash non-zerg-clusters)])
    (when (pair? pts)
      (hash-set! prod-mut psym (length pts))))
  (for ([cl (in-list zerg-th-clusters)])
    (hash-update! prod-mut (vector-ref cl 3) add1 0))
  ;; Merge tech-implied facilities (`>= 1` unless destroyed; Hive satisfies Lair)
  (for ([isym (in-set implied-set)]
        #:unless (set-member? destroyed-tech isym))
    (define psym (canonical-prod-facility-sym isym))
    (when psym
      (cond
        [(and (eq? psym 'lair) (> (hash-ref prod-mut 'hive 0) 0)) (void)]
        [(= (hash-ref prod-mut psym 0) 0)
         (hash-set! prod-mut psym 1)])))
  ;; L87B Calibration 3: Econ-scaled production floors across all 3 races!
  (define eb (max 1 est-bases))
  (case erace
    [(Zerg)
     ;; Zerg production IS Hatchery/Lair/Hive: floor total at `estimated-enemy-bases`!
     (define z-th-cnt (+ (hash-ref prod-mut 'hatchery 0)
                         (hash-ref prod-mut 'lair 0)
                         (hash-ref prod-mut 'hive 0)))
     (when (< z-th-cnt eb)
       (hash-update! prod-mut 'hatchery (lambda (c) (+ c (- eb z-th-cnt))) 0))]
    [(Terran)
     (when (and (>= frame 4704) (not early-worker-rush?)) ; >= 3:30
       (define bio-cnt (sum-recent-or-cur '(marine marauder reaper ghost) unit-counts recent-comp frame))
       (define mech-cnt (sum-recent-or-cur '(hellion hellbat widow-mine cyclone siege-tank thor) unit-counts recent-comp frame))
       (define air-cnt (sum-recent-or-cur '(medivac viking-fighter viking liberator banshee raven battlecruiser) unit-counts recent-comp frame))
       (define cur-rax (hash-ref prod-mut 'barracks 0))
       (define cur-fac (hash-ref prod-mut 'factory 0))
       (define cur-sp (hash-ref prod-mut 'starport 0))
       ;; Primary Barracks scaling (conservative so pure mech isn't over-estimated)
       (when (or (> cur-rax 0) (> bio-cnt 0) (>= frame 5376))
         (define rax-floor
           (cond
             [(>= frame 10752) (min 6 (max 2 (if (>= bio-cnt 10) (+ eb 1) eb)))]
             [(>= frame 8064) (min 5 (max 2 (if (>= bio-cnt 8) (+ eb 1) eb)))]
             [(or stopped-expanding? (>= eb 2)) 2]
             [else 1]))
         (when (< cur-rax rax-floor)
           (hash-set! prod-mut 'barracks rax-floor)))
       ;; Factory scaling once mech/starport seen or midgame >= 4:30 on >= 2 bases
       (when (or (> cur-fac 0) (> mech-cnt 0) (> cur-sp 0) (> air-cnt 0)
                 (and (>= frame 6048) (>= eb 2)))
         (define fac-floor
           (cond
             [(and (>= frame 10752) (>= eb 3) (>= mech-cnt 6)) 3]
             [(and (>= frame 8064) (>= eb 3) (>= mech-cnt 3)) 2]
             [else 1]))
         (when (< cur-fac fac-floor)
           (hash-set! prod-mut 'factory fac-floor)))
       ;; Starport scaling once air seen or midgame >= 5:00 on >= 2 bases
       (when (or (> cur-sp 0) (> air-cnt 0)
                 (and (>= frame 6720) (>= eb 2)))
         (define sp-floor
           (if (and (>= frame 8960) (>= eb 3) (>= air-cnt 4)) 2 1))
         (when (< cur-sp sp-floor)
           (hash-set! prod-mut 'starport sp-floor))))]
    [(Protoss)
     (when (and (>= frame 4704) (not early-worker-rush?)) ; >= 3:30
       (define gw-cnt (sum-recent-or-cur '(zealot stalker sentry adept high-templar dark-templar archon) unit-counts recent-comp frame))
       (define robo-cnt (sum-recent-or-cur '(immortal colossus disruptor warp-prism observer) unit-counts recent-comp frame))
       (define sg-cnt (sum-recent-or-cur '(phoenix void-ray oracle tempest carrier mothership) unit-counts recent-comp frame))
       (define cur-gw (hash-ref prod-mut 'gateway 0))
       (define cur-robo (hash-ref prod-mut 'robotics-facility 0))
       (define cur-sg (hash-ref prod-mut 'stargate 0))
       (when (or (> cur-gw 0) (> gw-cnt 0) (>= frame 5376))
         (define gw-floor
           (min 8
                (cond
                  [(>= eb 4) (+ eb 2)]
                  [(>= eb 3) (if (>= frame 8064) 4 3)]
                  [(>= eb 2) (if (>= frame 7392) 3 2)]
                  [stopped-expanding? 2]
                  [else 1])))
         (when (< cur-gw gw-floor)
           (hash-set! prod-mut 'gateway gw-floor)))
       (when (and (>= cur-robo 1) (>= eb 3) (>= frame 9408) (>= robo-cnt 4) (< cur-robo 2))
         (hash-set! prod-mut 'robotics-facility 2))
       (when (and (>= cur-sg 1) (>= eb 3) (>= frame 9408) (>= sg-cnt 4) (< cur-sg 2))
         (hash-set! prod-mut 'stargate 2)))]
    [else (void)])
  (for/hasheq ([(k v) (in-hash prod-mut)] #:when (> v 0))
    (values k v)))

(define (derive-prod-counts-from-bldg-hash bldg-ht erace est-bases)
  (define prod-mut (make-hasheq))
  (when (hash? bldg-ht)
    (for ([(k v) (in-hash bldg-ht)] #:when (and (exact-integer? v) (> v 0)))
      (define psym (canonical-prod-facility-sym k))
      (when psym
        (hash-update! prod-mut psym (lambda (c) (+ c v)) 0))))
  (when (eq? erace 'Zerg)
    (define z-th-cnt (+ (hash-ref prod-mut 'hatchery 0)
                        (hash-ref prod-mut 'lair 0)
                        (hash-ref prod-mut 'hive 0)))
    (when (< z-th-cnt est-bases)
      (hash-update! prod-mut 'hatchery (lambda (c) (+ c (- est-bases z-th-cnt))) 0)))
  (for/hasheq ([(k v) (in-hash prod-mut)] #:when (> v 0))
    (values k v)))

;; L87B Calibration 6: Baseline Zerg Queens + fog-retained econ-proportional unit count projection.
(define UNIT-PROJECTION-SUPPORT-ONLY
  '(queen observer overseer warp-prism raven medivac))

(define (compute-owm-projected-units raw-units-ht recent-comp-ht erace frame est-bases
                                     believed-army-val-unweighted early-worker-rush?)
  (define out (make-hasheq))
  (for ([(ut cnt) (in-hash raw-units-ht)] #:when (> cnt 0))
    (hash-set! out ut cnt))
  ;; Baseline Zerg Queen floor (`>= 1` at 2:15+, scaling to `min(5, est-bases)` at 3:30+)
  (when (and (eq? erace 'Zerg) (>= frame 3024) (not early-worker-rush?))
    (define q-floor (if (>= frame 4704) (min 5 (max 1 est-bases)) 1))
    (when (< (hash-ref out 'queen 0) q-floor)
      (hash-set! out 'queen q-floor)))
  ;; Compute currently accounted unweighted value in `out`
  (define counted-val
    (for/sum ([(ut cnt) (in-hash out)])
      (* cnt (max 25 (+ (max 0 (sc2-min-cost ut)) (max 0 (sc2-gas-cost ut)))))))
  (define delta-val (max 0 (- believed-army-val-unweighted counted-val)))
  ;; Build core combat unit composition weights from currently seen units, or recently seen
  ;; fog-retained units (<= 240s) if between engagements (NEVER hallucinating unseen unit types!).
  (define core-weights
    (let ([cur-core
           (for/list ([(ut cnt) (in-hash raw-units-ht)]
                      #:when (and (> cnt 0) (not (memq ut UNIT-PROJECTION-SUPPORT-ONLY))))
             (cons ut (exact->inexact cnt)))])
      (if (pair? cur-core)
          cur-core
          (if (hash? recent-comp-ht)
              (for/list ([(ut pair-cf) (in-hash recent-comp-ht)]
                         #:when (and (not (memq ut UNIT-PROJECTION-SUPPORT-ONLY))
                                     (pair? pair-cf)
                                     (real? (car pair-cf))
                                     (exact-integer? (cdr pair-cf))
                                     (<= (/ (exact->inexact (max 0 (- frame (cdr pair-cf)))) 22.4) 240.0)))
                (define age-s (/ (exact->inexact (max 0 (- frame (cdr pair-cf)))) 22.4))
                (cons ut (* (exact->inexact (car pair-cf)) (expt 0.5 (/ age-s 180.0)))))
              '()))))
  (when (and (>= delta-val 125) (pair? core-weights))
    (define proj-budget (* 0.65 (exact->inexact delta-val)))
    (define tot-wt
      (for/sum ([p (in-list core-weights)])
        (define u-cost (exact->inexact (max 50 (+ (max 0 (sc2-min-cost (car p))) (max 0 (sc2-gas-cost (car p)))))))
        (* (cdr p) u-cost)))
    (when (> tot-wt 0.0)
      (for ([p (in-list core-weights)])
        (define ut (car p))
        (define wt-cnt (cdr p))
        (define u-cost (max 50 (+ (max 0 (sc2-min-cost ut)) (max 0 (sc2-gas-cost ut)))))
        (define u-sup (max 1 (sc2-supply-cost ut)))
        (define share (* proj-budget (/ (* wt-cnt (exact->inexact u-cost)) tot-wt)))
        (define raw-add (exact-floor (/ share (exact->inexact u-cost))))
        (define cap-add
          (if (<= u-sup 1)
              (max 4 (min 18 (exact-round (* 2.5 wt-cnt))))
              (max 1 (min 8 (exact-round (* 1.5 wt-cnt))))))
        (define add-n (min raw-add cap-add))
        (when (> add-n 0)
          (hash-update! out ut (lambda (c) (+ c add-n)) 0)))))
  (for/hasheq ([(k v) (in-hash out)] #:when (> v 0))
    (values k v)))

;; Canonical upgrade normalization (including `burrow-or-subterranean-tech -> burrow` for Zerg
;; and dropping it for Terran/Protoss so Widow Mines never produce false-positive `burrow`!).
(define (normalize-upg-sym u [erace 'Unknown])
  (define raw-sym
    (cond
      [(symbol? u)
       (if (memq u '(#f unknown none ||)) #f u)]
      [(string? u)
       (define t (string-trim u))
       (if (or (string=? t "") (string=? t "unknown") (string=? t "none"))
           #f
           (string->symbol (string-downcase t)))]
      [else #f]))
  (and raw-sym
       (case raw-sym
         [(burrow-or-subterranean-tech)
          (if (memq erace '(Terran Protoss)) #f 'burrow)]
         [(metabolic-boost zergling-speed) 'zergling-movementspeed]
         [(roach-speed) 'glial-reconstitution]
         [(baneling-speed) 'centrifugal-hooks]
         [(banshee-cloak) 'cloaking-field]
         [(shield-wall) 'combat-shield]
         [(punisher-grenades) 'concussive-shells]
         [(warp-gate) 'warp-gate-research]
         [(psi-storm) 'psi-storm-tech]
         [(thermal-lance) 'extended-thermal-lance]
         [else raw-sym])))

(define (collect-owm-upgrade-symbols observed-upgs max-atk max-arm max-shd [erace 'Unknown])
  (define s (mutable-seteq))
  (when (generic-set? observed-upgs)
    (for ([u (in-set observed-upgs)])
      (define nu (normalize-upg-sym u erace))
      (when nu (set-add! s nu))))
  (when (and (exact-integer? max-atk) (>= max-atk 1)) (set-add! s 'enemy-weapons-1))
  (when (and (exact-integer? max-atk) (>= max-atk 2)) (set-add! s 'enemy-weapons-2))
  (when (and (exact-integer? max-atk) (>= max-atk 3)) (set-add! s 'enemy-weapons-3))
  (when (and (exact-integer? max-arm) (>= max-arm 1)) (set-add! s 'enemy-armor-1))
  (when (and (exact-integer? max-arm) (>= max-arm 2)) (set-add! s 'enemy-armor-2))
  (when (and (exact-integer? max-arm) (>= max-arm 3)) (set-add! s 'enemy-armor-3))
  (when (and (exact-integer? max-shd) (>= max-shd 1)) (set-add! s 'enemy-shields-1))
  (when (and (exact-integer? max-shd) (>= max-shd 2)) (set-add! s 'enemy-shields-2))
  (when (and (exact-integer? max-shd) (>= max-shd 3)) (set-add! s 'enemy-shields-3))
  (sort (set->list s) symbol<?))

;; L87C Track 1: Direct zero-FP mapping from visible enemy unit category + SC2 upgrade levels
;; (`attack-upgrade-level`, `armor-upgrade-level`, `shield-upgrade-level`) to exact canonical
;; upgrade symbols (tiers 1..3).
(define (add-tier-family! upg-set lvl u1 u2 u3)
  (when (and (exact-integer? lvl) (>= lvl 1))
    (set-add! upg-set u1)
    (when (>= lvl 2) (set-add! upg-set u2))
    (when (>= lvl 3) (set-add! upg-set u3))))

(define (record-direct-unit-tier-upgrades! observed-upgs utype atk-lvl arm-lvl shd-lvl)
  (when (and (exact-integer? atk-lvl) (> atk-lvl 0))
    (cond
      [(memq utype '(roach roach-burrowed ravager hydralisk hydralisk-burrowed
                     lurker lurker-mp lurker-burrowed lurker-mp-burrowed
                     locust locust-mp locust-mp-flying infested-terran))
       (add-tier-family! observed-upgs atk-lvl
                         'zerg-missile-weapons-1 'zerg-missile-weapons-2 'zerg-missile-weapons-3)]
      [(memq utype '(zergling zergling-burrowed baneling baneling-burrowed
                     ultralisk ultralisk-burrowed broodling))
       (add-tier-family! observed-upgs atk-lvl
                         'zerg-melee-weapons-1 'zerg-melee-weapons-2 'zerg-melee-weapons-3)]
      [(memq utype '(mutalisk corruptor brood-lord))
       (add-tier-family! observed-upgs atk-lvl
                         'zerg-flyer-weapons-1 'zerg-flyer-weapons-2 'zerg-flyer-weapons-3)]
      [(memq utype '(marine marauder reaper ghost))
       (add-tier-family! observed-upgs atk-lvl
                         'terran-infantry-weapons-1 'terran-infantry-weapons-2 'terran-infantry-weapons-3)]
      [(memq utype '(hellion hellbat siege-tank siege-tank-sieged cyclone thor thor-ap viking-assault))
       (add-tier-family! observed-upgs atk-lvl
                         'terran-vehicle-weapons-1 'terran-vehicle-weapons-2 'terran-vehicle-weapons-3)]
      [(memq utype '(viking viking-fighter banshee battlecruiser liberator liberator-ag))
       (add-tier-family! observed-upgs atk-lvl
                         'terran-ship-weapons-1 'terran-ship-weapons-2 'terran-ship-weapons-3)]
      [(memq utype '(zealot stalker sentry adept immortal colossus archon dark-templar high-templar))
       (add-tier-family! observed-upgs atk-lvl
                         'protoss-ground-weapons-1 'protoss-ground-weapons-2 'protoss-ground-weapons-3)]
      [(memq utype '(phoenix void-ray oracle carrier interceptor tempest mothership))
       (add-tier-family! observed-upgs atk-lvl
                         'protoss-air-weapons-1 'protoss-air-weapons-2 'protoss-air-weapons-3)]
      [else (void)]))
  (when (and (exact-integer? arm-lvl) (> arm-lvl 0))
    (cond
      [(memq utype '(zergling zergling-burrowed baneling baneling-burrowed
                     roach roach-burrowed ravager hydralisk hydralisk-burrowed
                     lurker lurker-mp lurker-burrowed lurker-mp-burrowed
                     ultralisk ultralisk-burrowed queen queen-burrowed
                     drone drone-burrowed infestor infestor-burrowed
                     swarm-host swarm-host-mp swarm-host-burrowed
                     locust locust-mp broodling))
       (add-tier-family! observed-upgs arm-lvl
                         'zerg-ground-carapace-1 'zerg-ground-carapace-2 'zerg-ground-carapace-3)]
      [(memq utype '(mutalisk corruptor brood-lord overlord overlord-transport overseer viper))
       (add-tier-family! observed-upgs arm-lvl
                         'zerg-flyer-carapace-1 'zerg-flyer-carapace-2 'zerg-flyer-carapace-3)]
      [(memq utype '(marine marauder reaper ghost))
       (add-tier-family! observed-upgs arm-lvl
                         'terran-infantry-armor-1 'terran-infantry-armor-2 'terran-infantry-armor-3)]
      [(memq utype '(hellion hellbat siege-tank siege-tank-sieged cyclone thor thor-ap
                     widow-mine widow-mine-burrowed viking viking-fighter viking-assault
                     medivac banshee raven battlecruiser liberator liberator-ag))
       (add-tier-family! observed-upgs arm-lvl
                         'terran-vehicle-and-ship-plating-1
                         'terran-vehicle-and-ship-plating-2
                         'terran-vehicle-and-ship-plating-3)]
      [(memq utype '(zealot stalker sentry adept immortal colossus archon
                     high-templar dark-templar disruptor))
       (add-tier-family! observed-upgs arm-lvl
                         'protoss-ground-armor-1 'protoss-ground-armor-2 'protoss-ground-armor-3)]
      [(memq utype '(phoenix void-ray oracle carrier tempest mothership observer warp-prism))
       (add-tier-family! observed-upgs arm-lvl
                         'protoss-air-armor-1 'protoss-air-armor-2 'protoss-air-armor-3)]
      [else (void)]))
  (when (and (exact-integer? shd-lvl) (> shd-lvl 0))
    (add-tier-family! observed-upgs shd-lvl
                      'protoss-shields-1 'protoss-shields-2 'protoss-shields-3)))

;; L87C Track 1: Record direct visible unupgraded unit observations (`atk-lvl == 0`, `arm-lvl == 0`,
;; unshielded 45-HP Marine) so fog priors NEVER hallucinate +1/+1 or Combat Shield when we literally
;; just saw unupgraded units on screen!
(define (record-unupgraded-evidence! unupg-ht utype frame atk-lvl arm-lvl mhp)
  (when (and (exact-integer? atk-lvl) (= atk-lvl 0))
    (cond
      [(memq utype '(roach roach-burrowed ravager hydralisk hydralisk-burrowed
                     lurker lurker-mp lurker-burrowed lurker-mp-burrowed))
       (hash-set! unupg-ht 'zerg-missile-atk-0 frame)]
      [(memq utype '(zergling zergling-burrowed baneling baneling-burrowed ultralisk ultralisk-burrowed))
       (hash-set! unupg-ht 'zerg-melee-atk-0 frame)]
      [(memq utype '(marine marauder))
       (hash-set! unupg-ht 'terran-inf-atk-0 frame)]
      [(memq utype '(zealot stalker adept immortal colossus archon))
       (hash-set! unupg-ht 'protoss-ground-atk-0 frame)]
      [else (void)]))
  (when (and (exact-integer? arm-lvl) (= arm-lvl 0))
    (cond
      [(memq utype '(zergling zergling-burrowed baneling baneling-burrowed
                     roach roach-burrowed ravager hydralisk hydralisk-burrowed
                     lurker lurker-mp lurker-burrowed lurker-mp-burrowed
                     ultralisk ultralisk-burrowed queen drone))
       (hash-set! unupg-ht 'zerg-ground-arm-0 frame)]
      [(memq utype '(marine marauder))
       (hash-set! unupg-ht 'terran-inf-arm-0 frame)]
      [(memq utype '(zealot stalker adept immortal colossus archon))
       (hash-set! unupg-ht 'protoss-ground-arm-0 frame)]
      [else (void)]))
  (when (and (eq? utype 'marine) (real? mhp) (> mhp 0.0) (<= mhp 46.0))
    (hash-set! unupg-ht 'terran-marine-no-cs frame)))

;; Deduplicate generic `enemy-weapons-k`/`enemy-armor-k`/`enemy-shields-k` (`k=1..3`) composite
;; tokens whenever a specific matching tier-`k` upgrade is already present in `upg-set`.
(define (dedup-generic-tier1-upgrades! upg-set)
  (when (for/or ([u (in-list '(terran-infantry-weapons-1 terran-vehicle-weapons-1 terran-ship-weapons-1
                               protoss-ground-weapons-1 protoss-air-weapons-1
                               zerg-melee-weapons-1 zerg-missile-weapons-1 zerg-flyer-weapons-1))])
          (set-member? upg-set u))
    (set-remove! upg-set 'enemy-weapons-1))
  (when (for/or ([u (in-list '(terran-infantry-weapons-2 terran-vehicle-weapons-2 terran-ship-weapons-2
                               protoss-ground-weapons-2 protoss-air-weapons-2
                               zerg-melee-weapons-2 zerg-missile-weapons-2 zerg-flyer-weapons-2))])
          (set-member? upg-set u))
    (set-remove! upg-set 'enemy-weapons-2))
  (when (for/or ([u (in-list '(terran-infantry-weapons-3 terran-vehicle-weapons-3 terran-ship-weapons-3
                               protoss-ground-weapons-3 protoss-air-weapons-3
                               zerg-melee-weapons-3 zerg-missile-weapons-3 zerg-flyer-weapons-3))])
          (set-member? upg-set u))
    (set-remove! upg-set 'enemy-weapons-3))
  (when (for/or ([u (in-list '(terran-infantry-armor-1 terran-vehicle-and-ship-plating-1
                               protoss-ground-armor-1 protoss-air-armor-1
                               zerg-ground-carapace-1 zerg-flyer-carapace-1))])
          (set-member? upg-set u))
    (set-remove! upg-set 'enemy-armor-1))
  (when (for/or ([u (in-list '(terran-infantry-armor-2 terran-vehicle-and-ship-plating-2
                               protoss-ground-armor-2 protoss-air-armor-2
                               zerg-ground-carapace-2 zerg-flyer-carapace-2))])
          (set-member? upg-set u))
    (set-remove! upg-set 'enemy-armor-2))
  (when (for/or ([u (in-list '(terran-infantry-armor-3 terran-vehicle-and-ship-plating-3
                               protoss-ground-armor-3 protoss-air-armor-3
                               zerg-ground-carapace-3 zerg-flyer-carapace-3))])
          (set-member? upg-set u))
    (set-remove! upg-set 'enemy-armor-3))
  (when (set-member? upg-set 'protoss-shields-1)
    (set-remove! upg-set 'enemy-shields-1))
  (when (set-member? upg-set 'protoss-shields-2)
    (set-remove! upg-set 'enemy-shields-2))
  (when (set-member? upg-set 'protoss-shields-3)
    (set-remove! upg-set 'enemy-shields-3)))

;; L87B Calibration 4 + L87C Track 1: High-precision evidence-backed upgrade inference for telemetry.
(define (infer-owm-telemetry-upgrades base-upgs erace frame est-bases est-gases
                                      bldg-counts implied-set raw-units recent-comp
                                      #:known-bldgs [known-bldgs #f]
                                      #:confirmed-geysers [confirmed-geysers 0]
                                      #:unupg-seen [unupg-seen #f]
                                      #:tech-first-seen [tech-first-seen #f])
  (define s (mutable-seteq))
  (for ([u (in-list base-upgs)])
    (define nu (normalize-upg-sym u erace))
    (when nu (set-add! s nu)))
  (define (direct-bldg-count bsym)
    (if (hash? known-bldgs)
        (for/sum ([rec (in-hash-values known-bldgs)]
                  #:when (eq? (tracked-enemy-bldg-canon-type rec) bsym))
          1)
        (hash-ref bldg-counts bsym 0)))
  (define (has-direct-bldg? bsym)
    (> (direct-bldg-count bsym) 0))
  (define (earliest-bldg-ready bsym)
    (and (hash? known-bldgs)
         (for/fold ([best #f])
                   ([rec (in-hash-values known-bldgs)]
                    #:when (eq? (tracked-enemy-bldg-canon-type rec) bsym))
           (define rf (tracked-enemy-bldg-ready-frame rec))
           (if (or (not best) (< rf best)) rf best))))
  (define (has-bldg? bsym)
    (or (> (hash-ref bldg-counts bsym 0) 0)
        (and (generic-set? implied-set) (set-member? implied-set bsym))))
  (define (recently-seen-unupg? cat-sym [win 2016])
    (define lf (and (hash? unupg-seen) (hash-ref unupg-seen cat-sym #f)))
    (and (exact-integer? lf) (<= (- frame lf) win)))
  (define (tech-age-frames tech-sym)
    (define ff (and (hash? tech-first-seen) (hash-ref tech-first-seen tech-sym #f)))
    (if (exact-integer? ff) (max 0 (- frame ff)) 0))
  (define (u-cnt sym) (recent-or-cur-unit-cnt sym raw-units recent-comp frame))
  (define (u-sum syms) (sum-recent-or-cur syms raw-units recent-comp frame))
  (case erace
    [(Zerg)
     (define ling-cnt (u-cnt 'zergling))
     (define roach-cnt (u-cnt 'roach))
     (define rav-cnt (u-cnt 'ravager))
     (define hydra-cnt (u-cnt 'hydralisk))
     (define bane-cnt (u-cnt 'baneling))
     (define missile-cnt (+ roach-cnt rav-cnt hydra-cnt))
     ;; L87C Track 1: Never fire Zergling Speed on pure elapsed clock or slowling count!
     ;; Real Speedlings are detected with 0 FP via Step D kinematic speed (`>= 5.85` t/s) or
     ;; explicit `'speed`. Fallback ONLY for confirmed Ling/Bane synergy (`>= 4:30`, confirmed
     ;; gas, Baneling Nest or `>= 2` Banelings, and `>= 6` Zerglings).
     (when (and (>= frame 6048)
                (>= confirmed-geysers 1)
                (>= ling-cnt 6)
                (or (has-bldg? 'baneling-nest) (>= bane-cnt 2)))
       (set-add! s 'zergling-movementspeed))
     ;; L87C Track 1: Roach Speed (`glial-reconstitution`) is detected directly via Step D
     ;; kinematic velocity (`>= 4.50` t/s anywhere or `>= 3.75` t/s in creep-free own main)
     ;; or explicit `'speed`, never guessed from clock/Lair/Roach count (avoids FPs on
     ;; burrow/tunneling or Hatchery-tech Roach builds that skip Roach Speed).
     ;; Hydralisk Range (`grooved-spines`) & Speed (`muscular-augments`): enforce SC2 Den
     ;; research-duration physics (`71s` each, `142s` for both sequentially!).
     (define hydra-tech-age
       (max (tech-age-frames 'hydralisk-tech)
            (let ([rf (earliest-bldg-ready 'hydralisk-den)])
              (if rf (max 0 (- frame rf)) 0))))
     (when (and (>= frame 9408)
                (>= hydra-cnt 3)
                (or (has-bldg? 'hydralisk-den) (>= hydra-cnt 4))
                (>= hydra-tech-age 1008))
       (set-add! s 'grooved-spines))
     (when (and (>= frame 14784)
                (>= hydra-cnt 6)
                (has-bldg? 'hydralisk-den)
                (>= hydra-tech-age 2912))
       (set-add! s 'muscular-augments))
     ;; L87C Track 1: Zerg Evo +1 Missile/Melee/Carapace are detected with 0 FP directly from
     ;; visible unit `attack-upgrade-level` / `armor-upgrade-level` in Step D. Fog fallback
     ;; strictly requires directly-observed Evolution Chamber(s) AND no recent visible unit
     ;; with `0` attack/armor refuting the upgrade!
     (when (and (>= frame 9408)
                (has-direct-bldg? 'evolution-chamber))
       (cond
         [(and (>= missile-cnt 4) (not (recently-seen-unupg? 'zerg-missile-atk-0)))
          (set-add! s 'zerg-missile-weapons-1)]
         [(and (>= (+ ling-cnt bane-cnt) 10) (not (recently-seen-unupg? 'zerg-melee-atk-0)))
          (set-add! s 'zerg-melee-weapons-1)]))
     (when (and (>= frame 11424)
                (>= (direct-bldg-count 'evolution-chamber) 2)
                (>= (+ missile-cnt ling-cnt bane-cnt) 10)
                (not (recently-seen-unupg? 'zerg-ground-arm-0)))
       (set-add! s 'zerg-ground-carapace-1))]
    [(Terran)
     (define marine-cnt (u-cnt 'marine))
     (define marauder-cnt (u-cnt 'marauder))
     (define bio-cnt (+ marine-cnt marauder-cnt))
     (define banshee-cnt (u-cnt 'banshee))
     ;; Concussive Shells: Barracks TechLab + >= 2 Marauders past 4:00 (`5376f`)
     (when (and (>= frame 5376)
                (>= marauder-cnt 2)
                (or (has-bldg? 'barracks-techlab) (>= marauder-cnt 3)))
       (set-add! s 'concussive-shells))
     ;; Stimpack: Barracks TechLab + >= 10 bio past 6:00 (`8064f`)
     (when (and (>= frame 8064)
                (>= bio-cnt 10)
                (or (has-bldg? 'barracks-techlab) (>= marauder-cnt 2)))
       (set-add! s 'stimpack))
     ;; Combat Shield: Barracks TechLab + >= 10 Marines past 7:30 (`10080f`), unless 45-HP Marines observed
     (when (and (>= frame 10080)
                (>= marine-cnt 10)
                (or (has-bldg? 'barracks-techlab) (>= marauder-cnt 2))
                (not (recently-seen-unupg? 'terran-marine-no-cs)))
       (set-add! s 'combat-shield))
     ;; Cloaking Field: >= 2 Banshees past 4:30 (`6048f`) (direct cloak in Step D fires at any time)
     (when (and (>= frame 6048) (>= banshee-cnt 2))
       (set-add! s 'cloaking-field))
     ;; Terran Infantry +1/+1 past 6:30 / 8:00 unless recently refuted by 0-upgrade bio units
     (when (and (>= frame 8736)
                (>= bio-cnt 8)
                (or (has-bldg? 'engineering-bay) (>= est-bases 2))
                (not (recently-seen-unupg? 'terran-inf-atk-0)))
       (set-add! s 'terran-infantry-weapons-1))
     (when (and (>= frame 10752)
                (>= bio-cnt 12)
                (or (has-bldg? 'engineering-bay) (>= est-bases 3))
                (not (recently-seen-unupg? 'terran-inf-arm-0)))
       (set-add! s 'terran-infantry-armor-1))]
    [(Protoss)
     (define zealot-cnt (u-cnt 'zealot))
     (define stalker-cnt (u-cnt 'stalker))
     (define colossus-cnt (u-cnt 'colossus))
     (define gw-cnt (u-sum '(zealot stalker sentry adept)))
     (define p-ground-cnt (+ gw-cnt (u-sum '(immortal colossus archon high-templar dark-templar))))
     ;; Warp Gate Research past 4:00 (`5376f`) once CyberCore or >= 3 Gateway units seen
     (when (and (>= frame 5376)
                (or (has-bldg? 'cybernetics-core) (>= gw-cnt 3)))
       (set-add! s 'warp-gate-research))
     ;; Charge / Blink when Twilight Council observed + matching unit mass past 5:30 (`7392f`)
     ;; (Exclude DT-prereq Twilight Council with small Zealot counts; kinematic Charge still fires!)
     (when (and (>= frame 7392)
                (has-bldg? 'twilight-council)
                (>= zealot-cnt 4)
                (or (>= zealot-cnt 6) (not (has-bldg? 'dark-shrine))))
       (set-add! s 'charge))
     (when (and (>= frame 7392) (has-bldg? 'twilight-council) (>= stalker-cnt 5))
       (set-add! s 'blink))
     ;; Extended Thermal Lance when Colossus + Robo Bay past 7:30 (`10080f`)
     (when (and (>= frame 10080)
                (>= colossus-cnt 1)
                (or (has-bldg? 'robotics-bay) (>= colossus-cnt 2)))
       (set-add! s 'extended-thermal-lance))
     ;; Protoss Ground Weapons +1 past 6:30 (`8736f`) unless refuted by recent 0-attack ground units
     (when (and (>= frame 8736)
                (>= est-bases 2)
                (or (has-bldg? 'forge)
                    (and (>= est-bases 3) (>= p-ground-cnt 6)))
                (not (recently-seen-unupg? 'protoss-ground-atk-0)))
       (set-add! s 'protoss-ground-weapons-1))]
    [else (void)])
  (dedup-generic-tier1-upgrades! s)
  (sort (set->list s) symbol<?))

;; Extract observed/inferred upgrade symbols from `mmstate` (`mirror-mind-state`,
;; `enemy-tech-observation`, hash, list, or set) without importing `mirror-mind-predictor.rkt`.
(define (extract-mmstate-upgrades mmstate [erace 'Unknown])
  (define out (mutable-seteq))
  (define (add-any! x)
    (cond
      [(not x) (void)]
      [(list? x)
       (for ([elem (in-list x)])
         (define nu (normalize-upg-sym elem erace))
         (when nu (set-add! out nu)))]
      [(generic-set? x)
       (for ([elem (in-set x)])
         (define nu (normalize-upg-sym elem erace))
         (when nu (set-add! out nu)))]
      [else
       (define nu (normalize-upg-sym x erace))
       (when nu (set-add! out nu))]))
  (define (walk! obj)
    (cond
      [(not obj) (void)]
      [(or (list? obj) (generic-set? obj)) (add-any! obj)]
      [(hash? obj)
       (when (hash-has-key? obj 'last-tech-observation)
         (walk! (hash-ref obj 'last-tech-observation #f)))
       (when (hash-has-key? obj 'observed-upgrades)
         (add-any! (hash-ref obj 'observed-upgrades '())))
       (when (hash-has-key? obj 'upgrades)
         (add-any! (hash-ref obj 'upgrades '())))]
      [(struct? obj)
       (define v (struct->vector obj))
       (when (> (vector-length v) 1)
         (case (vector-ref v 0)
           [(struct:enemy-tech-observation)
            (add-any! (vector-ref v 1))]
           [(struct:mirror-mind-state)
            (for ([i (in-range 1 (vector-length v))])
              (define elem (vector-ref v i))
              (when (struct? elem)
                (define ev (struct->vector elem))
                (when (and (> (vector-length ev) 1)
                           (eq? (vector-ref ev 0) 'struct:enemy-tech-observation))
                  (add-any! (vector-ref ev 1)))))]
           [else (void)]))]
      [else (void)]))
  (walk! mmstate)
  (set->list out))

;; Exported full 7-dimension OWM belief telemetry snapshot.
;; Returns a clean immutable `hasheq` for logging (`format-owm-belief-log-line`) and
;; replay-vs-belief accuracy auditing (`tools/audit-owm-belief-accuracy.py`).
(define (owm-belief-telemetry-snapshot owm-or-sum [mmstate #f] [frame 0])
  (define owm (and (opponent-world-model? owm-or-sum) owm-or-sum))
  (define summary
    (cond
      [(opponent-world-summary? owm-or-sum) owm-or-sum]
      [owm (opponent-world-model-last-summary owm)]
      [else #f]))
  (define ring-st
    (or (and summary (owm-l86-ring-state summary))
        (and owm (owm-l86-ring-state owm))))
  (define eff-frame
    (cond
      [(and (exact-integer? frame) (> frame 0)) frame]
      [(and (real? frame) (> frame 0)) (exact-round frame)]
      [summary (opponent-world-summary-frame summary)]
      [owm (max 0 (opponent-world-model-last-frame owm))]
      [else 0]))
  (define erace
    (cond
      [summary (opponent-world-summary-enemy-race summary)]
      [owm (opponent-world-model-enemy-race owm)]
      [else 'Unknown]))
  (define conf-bases
    (if summary (opponent-world-summary-confirmed-bases summary) 1))
  (define est-bases
    (max conf-bases
         (if (hash? ring-st) (hash-ref ring-st 'estimated-enemy-bases conf-bases) conf-bases)))
  (define conf-gases
    (if summary (opponent-world-summary-confirmed-geysers summary) 0))
  (define est-gases
    (max conf-gases
         (if (hash? ring-st) (hash-ref ring-st 'estimated-enemy-gases conf-gases) conf-gases)))
  (define est-workers
    (if summary (opponent-world-summary-estimated-workers summary) 0))
  (define seen-workers
    (cond
      [(and (hash? ring-st) (hash-has-key? ring-st 'seen-workers))
       (hash-ref ring-st 'seen-workers 0)]
      [summary
       (for/sum ([(ut cnt) (in-hash (opponent-world-summary-known-unit-counts summary))]
                 #:when (hash-has-key? WORKER-SYM-SET ut))
         cnt)]
      [else 0]))
  (define est-min-rate
    (if (hash? ring-st) (hash-ref ring-st 'min-rate-per-min 0) 0))
  (define est-gas-rate
    (if (hash? ring-st) (hash-ref ring-st 'gas-rate-per-min 0) 0))
  (define cum-min
    (if summary (opponent-world-summary-cum-minerals-mined summary) 0))
  (define cum-gas
    (if summary (opponent-world-summary-cum-gas-mined summary) 0))
  (define prod-ht
    (cond
      [(and (hash? ring-st) (hash-has-key? ring-st 'prod-counts))
       (hash-ref ring-st 'prod-counts (hasheq))]
      [owm
       (compute-owm-prod-counts (opponent-world-model-known-bldgs owm)
                                (opponent-world-model-implied-tech-set owm)
                                (opponent-world-model-destroyed-tech-set owm)
                                erace
                                est-bases)]
      [summary
       (derive-prod-counts-from-bldg-hash (opponent-world-summary-known-bldg-counts summary)
                                          erace
                                          est-bases)]
      [else (hasheq)]))
  (define units-ht
    (cond
      [(and (hash? ring-st) (hash-has-key? ring-st 'combat-unit-counts))
       (hash-ref ring-st 'combat-unit-counts (hasheq))]
      [summary
       (for/hasheq ([(ut cnt) (in-hash (opponent-world-summary-known-unit-counts summary))]
                    #:when (and (> cnt 0)
                                (not (hash-has-key? WORKER-SYM-SET ut))
                                (not (hash-has-key? FREE-SUMMON-SET ut))
                                (not (hash-has-key? TOWNHALL-SYM-SET ut))
                                (not (hash-has-key? GEYSER-BLDG-SYM-SET ut))
                                (not (memq ut '(overlord overlord-transport dropperlord
                                                bunker photon-cannon shield-battery
                                                spine-crawler spore-crawler missile-turret
                                                creep-tumor creep-tumor-burrowed creep-tumor-queen
                                                sensor-tower nydus-worm nydus-canal
                                                supply-depot pylon)))))
         (values ut cnt))]
      [else (hasheq)]))
  (define owm-upgs
    (cond
      [(and (hash? ring-st) (hash-has-key? ring-st 'owm-upgrades))
       (hash-ref ring-st 'owm-upgrades '())]
      [owm
       (collect-owm-upgrade-symbols (opponent-world-model-observed-upgrades-set owm)
                                    (opponent-world-model-max-atk-upg owm)
                                    (opponent-world-model-max-arm-upg owm)
                                    (opponent-world-model-max-shd-upg owm)
                                    erace)]
      [else '()]))
  (define merged-upgs
    (let ([s (mutable-seteq)])
      (for ([u (in-list owm-upgs)])
        (define nu (normalize-upg-sym u erace))
        (when nu (set-add! s nu)))
      (for ([u (in-list (extract-mmstate-upgrades mmstate erace))])
        (define nu (normalize-upg-sym u erace))
        (when nu (set-add! s nu)))
      (dedup-generic-tier1-upgrades! s)
      (sort (set->list s) symbol<?)))
  (define unseen-min
    (if summary (opponent-world-summary-unaccounted-minerals summary) 0))
  (define unseen-gas
    (if summary (opponent-world-summary-unaccounted-gas summary) 0))
  (define believed-army-val
    (cond
      [(and (hash? ring-st) (hash-has-key? ring-st 'believed-army-val-unweighted))
       (hash-ref ring-st 'believed-army-val-unweighted 0)]
      [summary (opponent-world-summary-believed-total-army-value summary)]
      [else 0]))
  (hasheq 'frame eff-frame
          'confirmed-bases conf-bases
          'estimated-bases est-bases
          'confirmed-gases conf-gases
          'estimated-gases est-gases
          'est-workers est-workers
          'seen-workers seen-workers
          'est-min-rate est-min-rate
          'est-gas-rate est-gas-rate
          'cum-min cum-min
          'cum-gas cum-gas
          'prod prod-ht
          'upgrades merged-upgs
          'units units-ht
          'unseen-min unseen-min
          'unseen-gas unseen-gas
          'believed-army-val believed-army-val))

;; =============================================================================
;; 7-Dimension Control-Signal Bridge (`owm-control-signals`)
;; =============================================================================
;; Canonical read-only view exposing all 7 calibrated OWM dimensions to Layer 2
;; macro game planning and Layer 4 tactical operation control without changing
;; the 35-field `opponent-world-summary` struct ABI.

(struct owm-control-signals
  (;; Dim 1: Bases & Map Control
   confirmed-bases
   estimated-bases
   happy-expected-bases
   stopped-expanding?
   unscouted-expansion-ambiguity?
   confirmed-early-greed?
   urgent-scout-pad
   ;; Dim 2: Geysers & Resource Income
   confirmed-geysers
   estimated-geysers
   est-min-rate
   est-gas-rate
   cum-minerals-mined
   cum-gas-mined
   ;; Dim 3: Workers & Eco Attrition
   estimated-workers
   workers-killed
   ;; Dim 4: Production Throughput & Reachability
   production-facility-count
   home-prod-count
   imminent-reachable-supply
   ;; Dim 5: Hidden Tech & Unaccounted Bank
   unaccounted-minerals
   unaccounted-gas
   hidden-gas-tech-risk?
   enemy-1base-double-gas?
   early-pool-latched?
   inferred-proxy-rush-floor
   requires-anti-air?
   requires-detection?
   ;; Dim 6: Standing Army, Siege/Turtle & Free-Summon Split
   known-army-supply
   known-army-value
   believed-army-supply
   believed-army-value
   enemy-siege-or-turtle-count
   locust-wave-active?
   swarm-host-cooldown-window?
   active-summon-count
   destroyed-min
   destroyed-gas
   ;; Dim 7: Upgrades & Posture
   enemy-upgrade-advantage
   enemy-posture)
  #:transparent)

(define (owm-build-control-signals owm-or-sum
                                   #:enemy-upgrade-advantage [enemy-upg-adv 0]
                                   #:enemy-posture [enemy-posture 'MacroStandard])
  (define owm (and (opponent-world-model? owm-or-sum) owm-or-sum))
  (define summary
    (cond
      [(opponent-world-summary? owm-or-sum) owm-or-sum]
      [owm (opponent-world-model-last-summary owm)]
      [else #f]))
  (define src (or summary owm))
  (define upg-adv
    (if (real? enemy-upg-adv) (inexact->exact (round enemy-upg-adv)) 0))
  (define posture (if (symbol? enemy-posture) enemy-posture 'MacroStandard))
  (cond
    [(not summary)
     (owm-control-signals
      1 1 1 #f #f #f #f
      0 0 0 0 0 0
      0 0
      0 0 0
      0 0 #f #f #f 0.0 #f #f
      0 0 0 0 0 #f #f 0 0 0
      upg-adv posture)]
    [else
     (define conf-b (opponent-world-summary-confirmed-bases summary))
     (define est-b (max conf-b (owm-estimated-enemy-bases src)))
     (define conf-g (opponent-world-summary-confirmed-geysers summary))
     (define est-g (max conf-g (owm-estimated-enemy-gases src)))
     (owm-control-signals
      conf-b
      est-b
      (opponent-world-summary-happy-expected-bases summary)
      (and (opponent-world-summary-stopped-expanding? summary) #t)
      (and (opponent-world-summary-unscouted-expansion-ambiguity? summary) #t)
      (and (opponent-world-summary-confirmed-early-greed? summary) #t)
      (opponent-world-summary-urgent-scout-pad summary)
      conf-g
      est-g
      (owm-estimated-min-rate src)
      (owm-estimated-gas-rate src)
      (opponent-world-summary-cum-minerals-mined summary)
      (opponent-world-summary-cum-gas-mined summary)
      (opponent-world-summary-estimated-workers summary)
      (opponent-world-summary-workers-killed summary)
      (opponent-world-summary-production-facility-count summary)
      (owm-home-prod-count src)
      (opponent-world-summary-imminent-reachable-supply summary)
      (opponent-world-summary-unaccounted-minerals summary)
      (opponent-world-summary-unaccounted-gas summary)
      (and (opponent-world-summary-hidden-gas-tech-risk? summary) #t)
      (and (owm-enemy-1base-double-gas? src) #t)
      (and (owm-early-pool-latched? src) #t)
      (exact->inexact (owm-inferred-proxy-rush-floor src))
      (and (opponent-world-summary-requires-anti-air? summary) #t)
      (and (opponent-world-summary-requires-detection? summary) #t)
      (opponent-world-summary-known-army-supply summary)
      (opponent-world-summary-known-army-value summary)
      (opponent-world-summary-believed-total-army-supply summary)
      (opponent-world-summary-believed-total-army-value summary)
      (opponent-world-summary-enemy-siege-or-turtle-count summary)
      (and (opponent-world-summary-locust-wave-active? summary) #t)
      (and (opponent-world-summary-swarm-host-cooldown-window? summary) #t)
      (opponent-world-summary-active-summon-count summary)
      (opponent-world-summary-destroyed-min summary)
      (opponent-world-summary-destroyed-gas summary)
      upg-adv
      posture)]))
