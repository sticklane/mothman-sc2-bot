#lang typed/racket/base

;; =============================================================================
;; `lib/situational-counter-planner.rkt`
;; Standalone Mid-Level LotV Situational Counter, Ability & Upgrade Planner
;;
;; Layering invariant: imports ONLY `"sc2-types.rkt"` and `"sc2-game-constants.rkt"`
;; (plus `racket/*` stdlib) so it compiles fast and independently of upstream edits.
;; Sits between global `build-orders.rkt` and frame-level `tactics/*.rkt`.
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/set
         typed/racket/unsafe
         "sc2-types.rkt"
         "sc2-game-constants.rkt")

;; Safe dynamic inspection of untyped observation/unit hashes without polluting Typed invariants.
(module dyn-ops racket/base
  (require racket/math racket/flonum)
  (provide dyn-ref
           dyn-list
           dyn-sym
           dyn-real
           dyn-int
           dyn-bool
           dyn-unit-type
           dyn-unit-id-energy
           dyn-unit-dist2
           dyn-unit-stealth?
           dyn-unit-snapshot
           dyn-extract-plan-scalars)
  (define (dyn-ref h k default)
    (if (hash? h) (hash-ref h k default) default))
  (define (dyn-list v)
    (if (list? v) v '()))
  (define (dyn-sym v [default 'unknown])
    (cond
      [(symbol? v) v]
      [(string? v) (string->symbol (string-downcase v))]
      [else default]))
  (define (dyn-real v [default 0.0])
    (cond
      [(and (flonum? v) (fl= (fl- v v) 0.0)) v]
      [(and (real? v) (not (nan? v)) (not (infinite? v))) (real->double-flonum v)]
      [else (real->double-flonum default)]))
  (define (dyn-int v [default 0])
    (cond
      [(fixnum? v) v]
      [(and (real? v) (not (nan? v)) (not (infinite? v))) (exact-round v)]
      [else default]))
  (define (dyn-bool v [default #f])
    (cond
      [(boolean? v) v]
      [(eq? v 'null) default]
      [else (if v #t #f)]))
  (define (dyn-sym-list v)
    (if (pair? v)
        (for/list ([s (in-list v)])
          (dyn-sym s 'unknown))
        '()))
  (define (dyn-unit-type u)
    (cond
      [(hash? u)
       (define raw-t (hash-ref u 'type 'unknown))
       (cond
         [(symbol? raw-t) raw-t]
         [(string? raw-t) (string->symbol (string-downcase raw-t))]
         [else 'unknown])]
      [(symbol? u) u]
      [(string? u) (string->symbol (string-downcase u))]
      [else 'unknown]))
  (define (dyn-unit-id-energy u)
    (if (hash? u)
        (let ([id (dyn-int (hash-ref u 'id 0) 0)])
          (if (> id 0)
              (values id (dyn-real (hash-ref u 'energy 999.0) 999.0))
              (values 0 999.0)))
        (values 0 999.0)))
  (define (dyn-unit-dist2 u bx by def)
    (if (hash? u)
        (let* ([ux (dyn-real (hash-ref u 'x def) def)]
               [uy (dyn-real (hash-ref u 'y def) def)]
               [dx (fl- ux bx)]
               [dy (fl- uy by)])
          (fl+ (fl* dx dx) (fl* dy dy)))
        (let ([dx (fl- def bx)]
              [dy (fl- def by)])
          (fl+ (fl* dx dx) (fl* dy dy)))))
  (define (dyn-unit-stealth? u)
    (and (hash? u)
         (or (dyn-bool (hash-ref u 'burrowed #f) #f)
             (dyn-bool (hash-ref u 'cloaked #f) #f))))
  ;; Extracts (raw-sym id x y burrowed? cloaked? energy) in 1 boundary crossing
  (define (dyn-unit-snapshot u default-x default-y)
    (cond
      [(hash? u)
       (define raw-t (hash-ref u 'type 'unknown))
       (define sym
         (cond
           [(symbol? raw-t) raw-t]
           [(string? raw-t) (string->symbol (string-downcase raw-t))]
           [else 'unknown]))
       (define id (dyn-int (hash-ref u 'id 0) 0))
       (define ux (dyn-real (hash-ref u 'x default-x) default-x))
       (define uy (dyn-real (hash-ref u 'y default-y) default-y))
       (define burrowed? (dyn-bool (hash-ref u 'burrowed #f) #f))
       (define cloaked? (dyn-bool (hash-ref u 'cloaked #f) #f))
       (define energy (dyn-real (hash-ref u 'energy 999.0) 999.0))
       (values sym id ux uy burrowed? cloaked? energy)]
      [(symbol? u)
       (values u 0 (real->double-flonum default-x) (real->double-flonum default-y) #f #f 999.0)]
      [(string? u)
       (values (string->symbol (string-downcase u)) 0 (real->double-flonum default-x) (real->double-flonum default-y) #f #f 999.0)]
      [else
       (values 'unknown 0 (real->double-flonum default-x) (real->double-flonum default-y) #f #f 999.0)]))
  ;; Extracts all observation scalar fields & lists in 1 single boundary crossing
  (define (dyn-extract-plan-scalars raw-obs raw-our-race raw-enemy-race frame-arg)
    (define obs (if (hash? raw-obs) raw-obs (hash)))
    (define our-race (or (hash-ref obs 'race #f) raw-our-race))
    (define enemy-race (or (hash-ref obs 'enemy-race #f) raw-enemy-race))
    (define frame (or frame-arg (dyn-int (hash-ref obs 'frame #f) 0)))
    (define ally-units (dyn-list (hash-ref obs 'ally-units '())))
    (define ally-bldgs (dyn-list (hash-ref obs 'ally-buildings '())))
    (define enemy-units (dyn-list (hash-ref obs 'enemy-units '())))
    (define enemy-bldgs (dyn-list (hash-ref obs 'enemy-buildings '())))
    (define researched-upgs (dyn-sym-list (hash-ref obs 'researched-upgrades '())))
    (define pending-upgs (dyn-sym-list (hash-ref obs 'pending-upgrades '())))
    (define bx (dyn-real (hash-ref obs 'base-x 32.5) 32.5))
    (define by (dyn-real (hash-ref obs 'base-y 32.5) 32.5))
    (define ex (dyn-real (hash-ref obs 'enemy-x 160.5) 160.5))
    (define ey (dyn-real (hash-ref obs 'enemy-y 160.5) 160.5))
    (define our-workers (dyn-int (hash-ref obs 'workers 20) 20))
    (define est-enemy-workers (dyn-int (hash-ref obs 'estimated-enemy-workers 20) 20))
    (define enemy-bases (dyn-int (hash-ref obs 'enemy-known-bases 1) 1))
    (define wall-sealed? (dyn-bool (hash-ref obs 'opponent-walled? #t) #t))
    (define enemy-wall-count (dyn-int (hash-ref obs 'opponent-wall-building-count 2) 2))
    (define proxy-flag? (dyn-bool (hash-ref obs 'proxy-detected? #f) #f))
    (define trapped? (dyn-bool (hash-ref obs 'our-army-trapped? #f) #f))
    (define gold-contest?
      (or (dyn-bool (hash-ref obs 'gold-base-present? #f) #f)
          (dyn-bool (hash-ref obs 'map-split? #f) #f)))
    (define base-threat-score (dyn-int (hash-ref obs 'base-threat-score 0) 0))
    (define minerals (max 0 (dyn-int (hash-ref obs 'minerals 0) 0)))
    (define gas (max 0 (dyn-int (hash-ref obs 'gas 0) 0)))
    (values our-race enemy-race frame bx by ex ey
            ally-units ally-bldgs enemy-units enemy-bldgs
            researched-upgs pending-upgs
            our-workers est-enemy-workers enemy-bases
            wall-sealed? enemy-wall-count proxy-flag? trapped?
            gold-contest? base-threat-score minerals gas)))

(unsafe-require/typed (submod "." dyn-ops)
  [dyn-ref (-> Any Any Any Any)]
  [dyn-list (-> Any (Listof Any))]
  [dyn-sym (->* (Any) (Symbol) Symbol)]
  [dyn-real (->* (Any) (Real) Float)]
  [dyn-int (->* (Any) (Integer) Integer)]
  [dyn-bool (->* (Any) (Boolean) Boolean)]
  [dyn-unit-type (-> Any Symbol)]
  [dyn-unit-id-energy (-> Any (Values Integer Float))]
  [dyn-unit-dist2 (-> Any Float Float Float Float)]
  [dyn-unit-stealth? (-> Any Boolean)]
  [dyn-unit-snapshot (-> Any Real Real (Values Symbol Integer Float Float Boolean Boolean Float))]
  [dyn-extract-plan-scalars
   (-> Any Any Any (Option Integer)
       (Values Any Any Integer Float Float Float Float
               (Listof Any) (Listof Any) (Listof Any) (Listof Any)
               (Listof Symbol) (Listof Symbol)
               Integer Integer Integer
               Boolean Integer Boolean Boolean
               Boolean Integer Integer Integer))])

(provide
 ;; Canonical Supplemental Ability Constants aligned with `s2clientprotocol` & `sc2-typed-commands.rkt`
 NEXUS-ENERGY-RECHARGE-ABILITY-ID
 SHIELD-BATTERY-RECHARGE-ABILITY-ID
 SHIELD-BATTERY-RESTORE-LEGACY-ID
 BUNKER-LOAD-ABILITY-ID
 BUNKER-UNLOAD-ALL-ABILITY-ID
 NYDUS-LOAD-ABILITY-ID
 NYDUS-UNLOAD-ALL-ABILITY-ID
 NYDUS-WORM-LOAD-ABILITY-ID
 NYDUS-WORM-UNLOAD-ALL-ABILITY-ID
 CANCEL-BUILD-IN-PROGRESS-ID
 CANCEL-ADEPT-PHASE-SHIFT-ID
 LOCUST-SWOOP-ABILITY-ID
 EFFECT-SPAWN-LOCUSTS-LEGACY-ID
 HOLD-POSITION-ABILITY-ID
 SCV-REPAIR-ABILITY-ID
 SPINE-CRAWLER-UPROOT-ID
 SPINE-CRAWLER-ROOT-ID
 SPORE-CRAWLER-UPROOT-ID
 SPORE-CRAWLER-ROOT-ID
 ;; Structs & Enumerations
 (struct-out ability-catalog-entry)
 (struct-out upgrade-catalog-entry)
 (struct-out unit-counter-entry)
 (struct-out situational-counter-plan)
 ALL-OPERATIONAL-SITUATIONS
 ;; Catalogs
 COMPLETE-LOTV-ABILITY-LIST
 COMPLETE-LOTV-ABILITY-CATALOG
 COMPLETE-LOTV-UPGRADE-LIST
 COMPLETE-LOTV-UPGRADE-CATALOG
 COMPLETE-UNIT-COUNTER-LIST
 COMPLETE-UNIT-COUNTER-MATRIX
 COMPLETE-STRUCTURE-COUNTER-MATRIX
 ;; Selectors & Evaluators
 lookup-ability-entry
 lookup-upgrade-entry
 lookup-unit-counter-entry
 select-situational-ability-actions
 select-situational-upgrades
 evaluate-situational-counter-plan)

;; -----------------------------------------------------------------------------
;; 1. Canonical Ability Constants & Transparent Data Models
;; -----------------------------------------------------------------------------

(define NEXUS-ENERGY-RECHARGE-ABILITY-ID      : Positive-Integer 4126) ;; ENERGYRECHARGE_ENERGYRECHARGE
(define SHIELD-BATTERY-RECHARGE-ABILITY-ID    : Positive-Integer 4113) ;; SHIELDBATTERYRECHARGEEX5
(define SHIELD-BATTERY-RESTORE-LEGACY-ID      : Positive-Integer 3751) ;; EFFECT_REPAIR_REPAIRDRONE alias
(define BUNKER-LOAD-ABILITY-ID                : Positive-Integer 407)  ;; LOAD_BUNKER
(define BUNKER-UNLOAD-ALL-ABILITY-ID          : Positive-Integer 408)  ;; UNLOADALL_BUNKER
(define NYDUS-LOAD-ABILITY-ID                 : Positive-Integer 1437) ;; LOAD_NYDUSNETWORK
(define NYDUS-UNLOAD-ALL-ABILITY-ID           : Positive-Integer 1438) ;; UNLOADALL_NYDASNETWORK
(define NYDUS-WORM-LOAD-ABILITY-ID            : Positive-Integer 2370) ;; LOAD_NYDUSWORM
(define NYDUS-WORM-UNLOAD-ALL-ABILITY-ID      : Positive-Integer 2371) ;; UNLOADALL_NYDUSWORM
(define CANCEL-BUILD-IN-PROGRESS-ID           : Positive-Integer 314)  ;; CANCEL_BUILDINPROGRESS
(define CANCEL-ADEPT-PHASE-SHIFT-ID           : Positive-Integer 2594) ;; CANCEL_ADEPTPHASESHIFT (2546 is PurificationNovaMorph)
(define LOCUST-SWOOP-ABILITY-ID               : Positive-Integer 2706) ;; LOCUSTMPFLYINGSWOOPATTACK_LOCUSTMPFLYINGSWOOP
(define EFFECT-SPAWN-LOCUSTS-LEGACY-ID        : Positive-Integer 2704) ;; EFFECT_SPAWNLOCUSTS legacy alias for 1990
(define HOLD-POSITION-ABILITY-ID              : Positive-Integer 18)   ;; HOLDPOSITION_HOLD
(define SCV-REPAIR-ABILITY-ID                 : Positive-Integer 316)  ;; EFFECT_REPAIR_SCV
(define SPINE-CRAWLER-UPROOT-ID               : Positive-Integer 1725) ;; SPINECRAWLERUPROOT
(define SPINE-CRAWLER-ROOT-ID                 : Positive-Integer 1729) ;; SPINECRAWLERROOT
(define SPORE-CRAWLER-UPROOT-ID               : Positive-Integer 1727) ;; SPORECRAWLERUPROOT
(define SPORE-CRAWLER-ROOT-ID                 : Positive-Integer 1731) ;; SPORECRAWLERROOT

(struct ability-catalog-entry
  ([sym : Symbol]
   [ability-id : Positive-Integer]
   [race : Symbol]
   [caster-type : Symbol]
   [target-mode : Symbol]           ;; 'none | 'point | 'unit | 'point-or-unit
   [energy-cost : Nonnegative-Integer]
   [cooldown-frames : Nonnegative-Integer]
   [range : Float]
   [situation-tags : (Listof Symbol)]
   [note : String])
  #:transparent)

(struct upgrade-catalog-entry
  ([sym : Symbol]
   [research-id : Positive-Integer]
   [upgrade-id : Positive-Integer]
   [race : Symbol]
   [structure : Symbol]
   [mineral-cost : Nonnegative-Integer]
   [gas-cost : Nonnegative-Integer]
   [tier : Positive-Integer]        ;; 1 = core/early, 2 = mid, 3 = late/t3
   [prereq : (Option Symbol)]
   [situation-triggers : (Listof Symbol)]
   [enemy-unit-triggers : (Listof Symbol)])
  #:transparent)

(struct unit-counter-entry
  ([unit-sym : Symbol]
   [race : Symbol]
   [threat-class : Symbol]
   [zerg-hard-counters : (Listof Symbol)]
   [terran-hard-counters : (Listof Symbol)]
   [protoss-hard-counters : (Listof Symbol)]
   [soft-counters : (Listof Symbol)]
   [spell-counters : (Listof Symbol)]
   [positioning-response : Symbol]
   [recommended-upgrades : (Listof Symbol)])
  #:transparent)

(struct situational-counter-plan
  ([primary-situation : Symbol]
   [active-situations : (Listof Symbol)]
   [situation-scores : (Immutable-HashTable Symbol Float)]
   [posture-override : Symbol]
   [target-units : (Listof Symbol)]
   [recommended-upgrades : (Listof Symbol)]
   [ability-actions : (Listof (Listof Any))]
   [positioning-directives : (Listof Symbol)]
   [static-defense-advice : (Listof Symbol)]
   [rationale : String])
  #:transparent)

(define ALL-OPERATIONAL-SITUATIONS : (Listof Symbol)
  '(opponent-unwalled-punish
    opponent-proxy-all-in-defense
    enemy-early-pool-or-worker-rush
    enemy-cannon-or-bunker-contain
    enemy-air-harass-transition
    enemy-cloaked-or-burrowed-threat
    enemy-siege-or-lurker-contain
    enemy-multi-prong-drop-or-runby
    enemy-fast-3cc-or-nexus-greed
    enemy-turtle-skytoss-or-mech
    map-split-or-gold-base-contest
    our-army-trapped-or-out-of-position
    our-snowball-finish-window
    our-eco-deficit-comeback-harass
    late-game-spellcaster-standoff
    base-trade-race))

;; -----------------------------------------------------------------------------
;; 2. Complete LotV 1v1 Active Ability & Spell Catalog
;; -----------------------------------------------------------------------------

(: ab (-> Symbol Positive-Integer Symbol Symbol Symbol Nonnegative-Integer Nonnegative-Integer Float (Listof Symbol) String ability-catalog-entry))
(define (ab s id r c tm e cd rng tags note)
  (ability-catalog-entry s id r c tm e cd rng tags note))

(define COMPLETE-LOTV-ABILITY-LIST : (Listof ability-catalog-entry)
  (list
   ;; Zerg active spells, modes, burrow, Nydus & crawlers
   (ab 'inject-larva            251  'Zerg 'queen               'unit  25   0   1.0 '(macro eco-recovery) "Queen Inject Larva")
   (ab 'transfusion             1664 'Zerg 'queen               'unit  50   0   7.0 '(enemy-early-pool-or-worker-rush enemy-cannon-or-bunker-contain our-snowball-finish-window) "Immediate +75 + 50 HoT sustain")
   (ab 'spawn-creep-tumor       1694 'Zerg 'queen               'point 25   0   3.0 '(map-split-or-gold-base-contest enemy-multi-prong-drop-or-runby) "Queen Creep Tumor")
   (ab 'spread-creep-tumor      1733 'Zerg 'creep-tumor-burrowed 'point 0  336 10.0 '(map-split-or-gold-base-contest) "Extend creep highway")
   (ab 'build-creep-tumor       3691 'Zerg 'queen               'point 25   0   3.0 '(map-split-or-gold-base-contest) "Generic Creep Tumor alias")
   (ab 'corrosive-bile          2338 'Zerg 'ravager             'point 0   157  9.0 '(enemy-cannon-or-bunker-contain enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech) "60-dmg skillshot breaks bunkers, force fields, tanks, liberators")
   (ab 'fungal-growth           74   'Zerg 'infestor            'point 75   0  10.0 '(enemy-multi-prong-drop-or-runby enemy-air-harass-transition late-game-spellcaster-standoff) "Root & reveal bio/blink/phoenix/muta clumps")
   (ab 'neural-parasite         249  'Zerg 'infestor            'unit  100  0   8.0 '(enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) "Hijack Carrier/Thor/Tempest/Mothership/HT")
   (ab 'microbial-shroud        2545 'Zerg 'infestor            'point 100  0   9.0 '(enemy-turtle-skytoss-or-mech enemy-air-harass-transition late-game-spellcaster-standoff) "-50% air-to-ground damage dome")
   (ab 'abduct                  2067 'Zerg 'viper               'unit  75   0   9.0 '(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) "Yank Siege Tank/Colossus/Tempest/Carrier/Lurker into kill zone")
   (ab 'blinding-cloud          2063 'Zerg 'viper               'point 100  0  11.0 '(enemy-siege-or-lurker-contain enemy-cannon-or-bunker-contain late-game-spellcaster-standoff) "Reduce ground weapon & PF/Tank/SCV range to melee")
   (ab 'parasitic-bomb          2542 'Zerg 'viper               'unit  125  0   8.0 '(enemy-turtle-skytoss-or-mech enemy-air-harass-transition late-game-spellcaster-standoff) "AoE air-to-air DoT vs Void Ray/Viking/Muta/Phoenix")
   (ab 'viper-consume           2073 'Zerg 'viper               'unit  0    0   1.0 '(late-game-spellcaster-standoff) "Drain friendly structure HP for +50 Viper energy")
   (ab 'viper-consume-structure 2069 'Zerg 'viper               'unit  0    0   1.0 '(late-game-spellcaster-standoff) "Alternative structure energy siphon ability ID")
   (ab 'spawn-locusts           1990 'Zerg 'swarm-host          'point 0   963 25.0 '(our-eco-deficit-comeback-harass enemy-turtle-skytoss-or-mech enemy-fast-3cc-or-nexus-greed) "Canonical SWARMHOSTSPAWNLOCUSTS_LOCUSTMP (legacy alias 2704)")
   (ab 'locust-swoop            2706 'Zerg 'locust-flying       'point 0    0   4.0 '(our-eco-deficit-comeback-harass base-trade-race) "LOCUSTMPFLYINGSWOOPATTACK swoop on mineral/tech cluster")
   (ab 'spawn-changeling        181  'Zerg 'overseer            'none  50   0   0.0 '(enemy-fast-3cc-or-nexus-greed opponent-proxy-all-in-defense) "Scout production, ramp wall, and tech branches")
   (ab 'contaminate             1825 'Zerg 'overseer            'unit  125  0   7.0 '(enemy-fast-3cc-or-nexus-greed opponent-proxy-all-in-defense enemy-turtle-skytoss-or-mech) "Halt production/upgrade structure for 21s")
   (ab 'morph-oversight-mode    3745 'Zerg 'overseer            'none  0    0   0.0 '(enemy-cloaked-or-burrowed-threat enemy-multi-prong-drop-or-runby) "Expand detector/vision radius while stationary")
   (ab 'morph-overseer-mode     3743 'Zerg 'overseer-siege-mode 'none  0    0   0.0 '(our-army-trapped-or-out-of-position) "Resume mobile Overseer flight")
   (ab 'caustic-spray           2324 'Zerg 'corruptor           'unit  0    0   6.0 '(base-trade-race enemy-turtle-skytoss-or-mech) "Focus-melt Nexuses, PFs, and Stargates")
   (ab 'build-nydus-worm        1768 'Zerg 'nydus-network       'point 0    0 256.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass base-trade-race) "Open remote Nydus Canal")
   (ab 'nydus-load              1437 'Zerg 'nydus-network       'unit  0    0   1.5 '(our-army-trapped-or-out-of-position base-trade-race) "LOAD_NYDUSNETWORK")
   (ab 'nydus-unload-all        1438 'Zerg 'nydus-network       'none  0    0   0.0 '(our-army-trapped-or-out-of-position base-trade-race) "UNLOADALL_NYDASNETWORK")
   (ab 'nydus-worm-load         2370 'Zerg 'nydus-canal         'unit  0    0   1.5 '(our-army-trapped-or-out-of-position base-trade-race) "LOAD_NYDUSWORM evacuation")
   (ab 'nydus-worm-unload-all   2371 'Zerg 'nydus-canal         'none  0    0   0.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass) "UNLOADALL_NYDUSWORM rapid deployment")
   (ab 'burrow-down             3661 'Zerg 'zerg-ground         'none  0    0   0.0 '(enemy-multi-prong-drop-or-runby enemy-air-harass-transition) "General unit Burrow Down")
   (ab 'burrow-up               3662 'Zerg 'zerg-burrowed       'none  0    0   0.0 '(opponent-unwalled-punish our-snowball-finish-window) "General unit Burrow Up")
   (ab 'burrow-lurker           2108 'Zerg 'lurker              'none  0    0   0.0 '(enemy-siege-or-lurker-contain enemy-multi-prong-drop-or-runby) "Siege Lurker spines")
   (ab 'unburrow-lurker         2110 'Zerg 'lurker-burrowed     'none  0    0   0.0 '(our-snowball-finish-window base-trade-race) "Relocate Lurker")
   (ab 'spine-crawler-uproot    1725 'Zerg 'spine-crawler       'none  0    0   0.0 '(enemy-cannon-or-bunker-contain opponent-proxy-all-in-defense) "Relocate Spine Crawler")
   (ab 'spine-crawler-root      1729 'Zerg 'spine-crawler-uprooted 'point 0 0   5.0 '(enemy-cannon-or-bunker-contain enemy-early-pool-or-worker-rush) "Root Spine Crawler on forward creep")
   (ab 'spore-crawler-uproot    1727 'Zerg 'spore-crawler       'none  0    0   0.0 '(enemy-air-harass-transition enemy-cloaked-or-burrowed-threat) "Relocate Spore Crawler")
   (ab 'spore-crawler-root      1731 'Zerg 'spore-crawler-uprooted 'point 0 0   5.0 '(enemy-air-harass-transition enemy-cloaked-or-burrowed-threat) "Root Spore Crawler to shield mineral line")
   (ab 'morph-overlord-transport 2708 'Zerg 'overlord           'none  0    0   0.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass) "Create Dropperlord")
   (ab 'overlord-unload-all-at  1408 'Zerg 'overlord-transport  'point 0    0   0.0 '(our-army-trapped-or-out-of-position base-trade-race) "Drop passengers")

   ;; Terran active spells, modes, bunkers, PF, repair & buildings
   (ab 'calldown-mule           171  'Terran 'orbital-command    'unit  50   0 256.0 '(our-eco-deficit-comeback-harass enemy-fast-3cc-or-nexus-greed) "Drop MULE on richest mineral patch")
   (ab 'scanner-sweep           399  'Terran 'orbital-command    'point 50   0 256.0 '(enemy-cloaked-or-burrowed-threat enemy-siege-or-lurker-contain opponent-proxy-all-in-defense) "Temporary area scan & detection")
   (ab 'supply-drop             255  'Terran 'orbital-command    'unit  50   0 256.0 '(enemy-early-pool-or-worker-rush opponent-proxy-all-in-defense) "Emergency +8 supply & Depot armor")
   (ab 'morph-planetary-fortress 1450 'Terran 'command-center    'none  0    0   0.0 '(map-split-or-gold-base-contest enemy-multi-prong-drop-or-runby base-trade-race) "Fortify exposed 3rd/4th expansion")
   (ab 'stimpack                3675 'Terran 'bio-unit           'none  0    0   0.0 '(opponent-unwalled-punish our-snowball-finish-window base-trade-race) "Generic Bio Stimpack")
   (ab 'stim-marine             380  'Terran 'marine             'none  0    0   0.0 '(opponent-unwalled-punish our-snowball-finish-window) "Marine Stimpack")
   (ab 'stim-marauder           253  'Terran 'marauder           'none  0    0   0.0 '(enemy-siege-or-lurker-contain our-snowball-finish-window) "Marauder Stimpack")
   (ab 'kd8-charge              2588 'Terran 'reaper             'point 0   314  5.0 '(opponent-unwalled-punish enemy-early-pool-or-worker-rush) "Knockback grenade")
   (ab 'emp-round               1628 'Terran 'ghost              'point 75   0  10.0 '(late-game-spellcaster-standoff enemy-turtle-skytoss-or-mech enemy-cannon-or-bunker-contain) "Strip 100 shields & 100 energy in 1.5 radius")
   (ab 'steady-targeting        2714 'Terran 'ghost              'unit  50   0  10.0 '(late-game-spellcaster-standoff enemy-turtle-skytoss-or-mech) "130 anti-psionic/biological Snipe")
   (ab 'cloak-ghost             382  'Terran 'ghost              'none  25   0   0.0 '(late-game-spellcaster-standoff base-trade-race) "Cloak Ghost for Snipe/Nuke")
   (ab 'decloak-ghost           383  'Terran 'ghost              'none  0    0   0.0 '(late-game-spellcaster-standoff) "Conserve Ghost energy")
   (ab 'nuke-calldown           1622 'Terran 'ghost              'point 0    0  12.0 '(enemy-turtle-skytoss-or-mech enemy-siege-or-lurker-contain) "Zone static defense & siege line")
   (ab 'morph-hellbat           1998 'Terran 'hellion            'none  0    0   0.0 '(enemy-early-pool-or-worker-rush opponent-proxy-all-in-defense) "Transform to armored light-cleave Hellbat")
   (ab 'morph-hellion           1978 'Terran 'hellbat            'none  0    0   0.0 '(our-eco-deficit-comeback-harass enemy-multi-prong-drop-or-runby) "Transform to high-speed Hellion runby")
   (ab 'burrow-widow-mine       2095 'Terran 'widow-mine         'none  0    0   0.0 '(enemy-multi-prong-drop-or-runby our-eco-deficit-comeback-harass) "Arm Widow Mine ambush")
   (ab 'unburrow-widow-mine     2097 'Terran 'widow-mine-burrowed 'none 0    0   0.0 '(our-snowball-finish-window base-trade-race) "Unburrow Widow Mine")
   (ab 'widow-mine-attack       2099 'Terran 'widow-mine-burrowed 'unit 0   650  5.0 '(enemy-multi-prong-drop-or-runby) "Explicit Widow Mine sentinel lock")
   (ab 'lock-on                 2350 'Terran 'cyclone            'unit  0    0   7.0 '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain) "15-tile tethered high-DPS Lock-On")
   (ab 'siege-mode              388  'Terran 'siege-tank         'none  0    0   0.0 '(enemy-siege-or-lurker-contain enemy-cannon-or-bunker-contain opponent-proxy-all-in-defense) "Deploy 13-range splash Siege Tank")
   (ab 'unsiege-mode            390  'Terran 'siege-tank-sieged  'none  0    0   0.0 '(our-army-trapped-or-out-of-position our-snowball-finish-window) "Reposition Siege Tank")
   (ab 'morph-thor-high-impact  2362 'Terran 'thor               'none  0    0   0.0 '(enemy-turtle-skytoss-or-mech) "11-range High Impact anti-Massive air")
   (ab 'morph-thor-explosive    2364 'Terran 'thor-ap            'none  0    0   0.0 '(enemy-air-harass-transition) "Splash anti-light air mode")
   (ab 'heal                    386  'Terran 'medivac            'unit  0    0   4.0 '(our-snowball-finish-window opponent-unwalled-punish) "Medivac bio sustain")
   (ab 'medivac-boost           2116 'Terran 'medivac            'none  0   314  0.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass base-trade-race) "Ignite Afterburners rescue/drop")
   (ab 'medivac-unload-all-at   396  'Terran 'medivac            'point 0    0   0.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass) "Drop bio/mines into mineral line")
   (ab 'morph-viking-assault    403  'Terran 'viking-fighter     'none  0    0   0.0 '(our-eco-deficit-comeback-harass base-trade-race) "Land Viking for worker/armored harass")
   (ab 'morph-viking-fighter    405  'Terran 'viking-assault     'none  0    0   0.0 '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech) "Liftoff Viking vs air")
   (ab 'morph-liberator-ag      2558 'Terran 'liberator          'point 0    0   5.0 '(enemy-siege-or-lurker-contain enemy-cannon-or-bunker-contain our-eco-deficit-comeback-harass) "Defender Mode Freedom Zone")
   (ab 'morph-liberator-aa      2560 'Terran 'liberator-ag       'none  0    0   0.0 '(our-snowball-finish-window base-trade-race) "Reposition Liberator")
   (ab 'auto-turret             349  'Terran 'raven              'point 50   0   2.0 '(our-eco-deficit-comeback-harass enemy-multi-prong-drop-or-runby) "Drop Raven Auto-Turret in mineral line")
   (ab 'interference-matrix     3747 'Terran 'raven              'unit  75   0   9.0 '(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) "Disable Mech/Psionic weapons & spells for 11s")
   (ab 'anti-armor-missile      3753 'Terran 'raven              'unit  75   0  10.0 '(enemy-turtle-skytoss-or-mech our-snowball-finish-window late-game-spellcaster-standoff) "-2 armor AoE shred before engage")
   (ab 'cloak-banshee           392  'Terran 'banshee            'none  25   0   0.0 '(our-eco-deficit-comeback-harass enemy-cannon-or-bunker-contain) "Banshee Cloak harass")
   (ab 'decloak-banshee         393  'Terran 'banshee            'none  0    0   0.0 '(our-eco-deficit-comeback-harass) "Save Banshee energy")
   (ab 'yamato-cannon           401  'Terran 'battlecruiser      'unit  0  1590 10.0 '(enemy-turtle-skytoss-or-mech base-trade-race) "240-dmg Yamato snipe")
   (ab 'tactical-jump           2358 'Terran 'battlecruiser      'point 0  1590 256.0 '(our-army-trapped-or-out-of-position base-trade-race our-eco-deficit-comeback-harass) "Map-wide Tactical Jump")
   (ab 'bunker-load             407  'Terran 'bunker             'unit  0    0   2.0 '(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush enemy-cannon-or-bunker-contain) "LOAD_BUNKER")
   (ab 'bunker-unload           408  'Terran 'bunker             'none  0    0   0.0 '(enemy-cannon-or-bunker-contain our-snowball-finish-window) "UNLOADALL_BUNKER dodge Bile / chase")
   (ab 'salvage                 32   'Terran 'bunker             'none  0    0   0.0 '(enemy-fast-3cc-or-nexus-greed map-split-or-gold-base-contest) "Reclaim 75 minerals from idle Bunker")
   (ab 'salvage-sensor-tower    4130 'Terran 'sensor-tower       'none  0    0   0.0 '(base-trade-race) "SALVAGESENSORTOWERREFUND")
   (ab 'effect-repair           316  'Terran 'scv                'unit  0    0   0.5 '(opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain enemy-turtle-skytoss-or-mech) "EFFECT_REPAIR_SCV Bunker/PF/Mech repair")
   (ab 'repair                  3685 'Terran 'scv                'unit  0    0   0.5 '(opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain) "Generic EFFECT_REPAIR")
   (ab 'morph-supply-depot-lower 556 'Terran 'supply-depot      'none  0    0   0.0 '(our-army-trapped-or-out-of-position our-snowball-finish-window) "Open ramp gate")
   (ab 'morph-supply-depot-raise 558 'Terran 'supply-depot      'none  0    0   0.0 '(enemy-early-pool-or-worker-rush enemy-multi-prong-drop-or-runby) "Seal ramp wall")
   (ab 'lift                    3679 'Terran 'terran-building   'none  0    0   0.0 '(base-trade-race our-army-trapped-or-out-of-position) "Float Terran structure")
   (ab 'land                    3678 'Terran 'terran-building   'point 0    0   0.0 '(map-split-or-gold-base-contest) "Land Terran structure")

   ;; Protoss active spells, modes, Nexus & Shield Battery
   (ab 'chrono-boost            3755 'Protoss 'nexus             'unit  50   0 256.0 '(opponent-proxy-all-in-defense our-snowball-finish-window enemy-fast-3cc-or-nexus-greed) "Accelerate key tech/upgrade/unit production")
   (ab 'battery-overcharge      4107 'Protoss 'nexus             'unit  50 1344 256.0 '(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush enemy-cannon-or-bunker-contain) "Supercharge Shield Battery within 8.0 tiles of Nexus for 14s")
   (ab 'nexus-energy-recharge   4126 'Protoss 'nexus             'unit  50 1344 256.0 '(late-game-spellcaster-standoff enemy-air-harass-transition opponent-proxy-all-in-defense) "ENERGYRECHARGE_ENERGYRECHARGE +100 caster energy")
   (ab 'nexus-mass-recall       3757 'Protoss 'nexus             'point 0  2912 256.0 '(our-army-trapped-or-out-of-position enemy-multi-prong-drop-or-runby base-trade-race) "Recall stranded army back to Nexus")
   (ab 'shield-battery-recharge 4113 'Protoss 'shield-battery    'unit  0    0   6.0 '(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush enemy-cannon-or-bunker-contain) "SHIELDBATTERYRECHARGEEX5 (legacy 3751)")
   (ab 'guardian-shield         76   'Protoss 'sentry            'none  75   0   0.0 '(opponent-proxy-all-in-defense our-snowball-finish-window) "-2 ranged damage aura")
   (ab 'force-field             1526 'Protoss 'sentry            'point 50   0   9.0 '(enemy-early-pool-or-worker-rush opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain) "Split melee floods & seal ramp/repair arcs")
   (ab 'hallucination-phoenix   154  'Protoss 'sentry            'none  75   0   0.0 '(enemy-fast-3cc-or-nexus-greed opponent-proxy-all-in-defense) "Free air scout hallucination")
   (ab 'hallucination-archon    146  'Protoss 'sentry            'none  75   0   0.0 '(our-snowball-finish-window opponent-proxy-all-in-defense) "Tank damage with hallucinated Archon")
   (ab 'charge                  1819 'Protoss 'zealot            'unit  0  157   4.0 '(opponent-unwalled-punish enemy-siege-or-lurker-contain) "Zealot gap-closer")
   (ab 'blink                   3687 'Protoss 'stalker           'point 0  157   8.0 '(our-army-trapped-or-out-of-position enemy-air-harass-transition base-trade-race) "Stalker Blink reposition / dodge")
   (ab 'blink-stalker           1442 'Protoss 'stalker           'point 0  157   8.0 '(enemy-siege-or-lurker-contain our-snowball-finish-window) "Unit-specific Blink ID")
   (ab 'adept-phase-shift       2544 'Protoss 'adept             'point 0  246  16.0 '(opponent-unwalled-punish our-eco-deficit-comeback-harass enemy-fast-3cc-or-nexus-greed) "Project Psionic Transfer shade")
   (ab 'cancel-adept-phase-shift 2594 'Protoss 'adept            'none  0    0   0.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass) "Canonical CANCEL_ADEPTPHASESHIFT (2546 is PurificationNovaMorph)")
   (ab 'psi-storm               1036 'Protoss 'high-templar      'point 75   0   9.0 '(late-game-spellcaster-standoff enemy-cannon-or-bunker-contain enemy-multi-prong-drop-or-runby) "80 AoE Psionic Storm")
   (ab 'feedback                140  'Protoss 'high-templar      'unit  50   0  10.0 '(late-game-spellcaster-standoff enemy-air-harass-transition) "Burn Medivac/Viper/Infestor/Ghost/HT/Oracle energy")
   (ab 'morph-archon            1766 'Protoss 'high-templar      'none  0    0   0.0 '(enemy-early-pool-or-worker-rush our-snowball-finish-window) "Merge depleted HTs/DTs into Archon")
   (ab 'shadow-stride           2700 'Protoss 'dark-templar      'point 0  314   8.0 '(our-eco-deficit-comeback-harass base-trade-race) "DT Blink into mineral lines or escape")
   (ab 'immortal-barrier        2328 'Protoss 'immortal          'none  0  717   0.0 '(opponent-proxy-all-in-defense enemy-siege-or-lurker-contain) "100-shield Barrier absorption")
   (ab 'purification-nova       2346 'Protoss 'disruptor         'point 0  480  13.5 '(enemy-siege-or-lurker-contain enemy-cannon-or-bunker-contain late-game-spellcaster-standoff) "145(+55 vs shields) Nova breaks ground clumps")
   (ab 'morph-observer-mode     3739 'Protoss 'observer-siege-mode 'none 0   0   0.0 '(our-snowball-finish-window) "Un-siege Observer")
   (ab 'morph-observer-siege-mode 3741 'Protoss 'observer        'none  0    0   0.0 '(enemy-cloaked-or-burrowed-threat enemy-multi-prong-drop-or-runby) "Anchor Surveillance Mode at choke/drop lane")
   (ab 'morph-warp-prism-phasing 1528 'Protoss 'warp-prism       'none  0    0   0.0 '(our-eco-deficit-comeback-harass opponent-unwalled-punish base-trade-race) "Deploy mobile Warp Gate field")
   (ab 'morph-warp-prism-transport 1530 'Protoss 'warp-prism-phasing 'none 0 0  0.0 '(our-army-trapped-or-out-of-position) "Mobilize Warp Prism for rescue/juggle")
   (ab 'warp-prism-unload-all-at 913 'Protoss 'warp-prism        'point 0    0   0.0 '(our-army-trapped-or-out-of-position our-eco-deficit-comeback-harass) "Drop juggled units")
   (ab 'graviton-beam           173  'Protoss 'phoenix           'unit  50   0   4.0 '(enemy-siege-or-lurker-contain enemy-multi-prong-drop-or-runby our-eco-deficit-comeback-harass) "Lift Tank/Lurker/Queen/Worker")
   (ab 'prismatic-alignment     2393 'Protoss 'void-ray          'none  0 1008   0.0 '(enemy-turtle-skytoss-or-mech enemy-cannon-or-bunker-contain base-trade-race) "+bonus vs Armored burst")
   (ab 'pulsar-beam             2375 'Protoss 'oracle            'none  25   0   0.0 '(our-eco-deficit-comeback-harass opponent-unwalled-punish) "Light-worker assassinate beam")
   (ab 'pulsar-beam-off         2376 'Protoss 'oracle            'none  0    0   0.0 '(enemy-air-harass-transition) "Conserve Oracle energy for Revelation/Stasis")
   (ab 'oracle-revelation       2146 'Protoss 'oracle            'point 25   0   9.0 '(enemy-cloaked-or-burrowed-threat enemy-siege-or-lurker-contain) "Tag cloaked/burrowed & siege army for 20s")
   (ab 'stasis-ward             2505 'Protoss 'oracle            'point 50   0   3.0 '(enemy-multi-prong-drop-or-runby opponent-proxy-all-in-defense) "Plant cloaked Stasis Trap")
   (ab 'build-interceptors      1042 'Protoss 'carrier           'none  0    0   0.0 '(enemy-turtle-skytoss-or-mech) "Replenish Carrier Interceptors")
   (ab 'mothership-mass-recall  2368 'Protoss 'mothership        'point 0 2000 256.0 '(our-army-trapped-or-out-of-position base-trade-race) "Recall army to Mothership")

   ;; Shared structural / unit control abilities
   (ab 'cancel-build            314  'Shared 'building           'none  0    0   0.0 '(enemy-cannon-or-bunker-contain our-eco-deficit-comeback-harass) "CANCEL_BUILDINPROGRESS refund 75%")
   (ab 'hold-position           18   'Shared 'unit               'none  0    0   0.0 '(enemy-cannon-or-bunker-contain enemy-early-pool-or-worker-rush) "HOLDPOSITION_HOLD block cage/ramp")
   (ab 'load-transport          3668 'Shared 'transport          'unit  0    0   2.0 '(our-army-trapped-or-out-of-position) "Generic transport load")
   (ab 'unload-all-at           3669 'Shared 'transport          'point 0    0   0.0 '(our-army-trapped-or-out-of-position) "Generic transport unload at")
   (ab 'unload-all              3664 'Shared 'transport          'none  0    0   0.0 '(enemy-cannon-or-bunker-contain) "Generic immediate unload")))

(define COMPLETE-LOTV-ABILITY-CATALOG : (Immutable-HashTable Symbol ability-catalog-entry)
  (for/hasheq : (Immutable-HashTable Symbol ability-catalog-entry)
              ([e (in-list COMPLETE-LOTV-ABILITY-LIST)])
    (values (ability-catalog-entry-sym e) e)))

(: lookup-ability-entry (-> Symbol (Option ability-catalog-entry)))
(define (lookup-ability-entry sym)
  (hash-ref COMPLETE-LOTV-ABILITY-CATALOG sym (lambda () #f)))

;; -----------------------------------------------------------------------------
;; 3. Complete LotV Upgrade Catalog (`RESEARCH-ABILITY-TABLE` Aligned)
;; -----------------------------------------------------------------------------

(: upg (-> Symbol Positive-Integer Positive-Integer Symbol Symbol Nonnegative-Integer Nonnegative-Integer Positive-Integer (Option Symbol) (Listof Symbol) (Listof Symbol) upgrade-catalog-entry))
(define (upg sym rid uid race bldg min gas tier pre sit-trigs enemy-trigs)
  (upgrade-catalog-entry sym rid uid race bldg min gas tier pre sit-trigs enemy-trigs))

(define COMPLETE-LOTV-UPGRADE-LIST : (Listof upgrade-catalog-entry)
  (list
   ;; Zerg Upgrades (29)
   (upg 'zergling-movementspeed 1253 66  'Zerg 'spawning-pool     100 100 1 #f '(opponent-unwalled-punish enemy-early-pool-or-worker-rush enemy-fast-3cc-or-nexus-greed enemy-multi-prong-drop-or-runby) '(reaper zealot stalker marine hellion))
   (upg 'zergling-attackspeed   1252 65  'Zerg 'spawning-pool     200 200 3 'zergling-movementspeed '(base-trade-race late-game-spellcaster-standoff our-snowball-finish-window) '(marauder thor immortal carrier))
   (upg 'glial-reconstitution   216  2   'Zerg 'roach-warren      100 100 1 #f '(opponent-unwalled-punish opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain) '(hellbat marine zealot adept))
   (upg 'tunneling-claws        217  3   'Zerg 'roach-warren      150 150 2 'glial-reconstitution '(our-eco-deficit-comeback-harass enemy-multi-prong-drop-or-runby) '(siege-tank stalker disruptor))
   (upg 'centrifugal-hooks      1482 75  'Zerg 'baneling-nest     150 150 2 #f '(opponent-unwalled-punish enemy-multi-prong-drop-or-runby our-snowball-finish-window) '(marine zergling zealot hellbat hydralisk))
   (upg 'grooved-spines         1282 134 'Zerg 'hydralisk-den     100 100 2 #f '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech enemy-cannon-or-bunker-contain) '(mutalisk void-ray carrier oracle liberator medivac tempest))
   (upg 'muscular-augments      1283 135 'Zerg 'hydralisk-den     100 100 2 #f '(enemy-air-harass-transition enemy-multi-prong-drop-or-runby) '(medivac warp-prism stalker banshee))
   (upg 'adaptive-talons        3709 293 'Zerg 'lurker-den        150 150 3 #f '(enemy-siege-or-lurker-contain late-game-spellcaster-standoff) '(marine marauder zealot stalker templar))
   (upg 'lurker-range           3710 127 'Zerg 'lurker-den        150 150 3 #f '(enemy-siege-or-lurker-contain late-game-spellcaster-standoff) '(siege-tank colossus disruptor ghost high-templar))
   (upg 'chitinous-plating      265  4   'Zerg 'ultralisk-cavern  150 150 3 #f '(our-snowball-finish-window late-game-spellcaster-standoff) '(marine zergling zealot carrier))
   (upg 'anabolic-synthesis     263  88  'Zerg 'ultralisk-cavern  150 150 3 #f '(our-snowball-finish-window base-trade-race) '(ghost marauder immortal stalker))
   (upg 'burrow                 1225 64  'Zerg 'hatchery          100 100 1 #f '(enemy-multi-prong-drop-or-runby our-eco-deficit-comeback-harass enemy-fast-3cc-or-nexus-greed) '(oracle phoenix hellion reaper adept))
   (upg 'pneumatized-carapace   1223 62  'Zerg 'hatchery          100 100 1 #f '(opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain enemy-fast-3cc-or-nexus-greed enemy-multi-prong-drop-or-runby) '(phoenix viking void-ray))
   (upg 'neural-parasite        1455 101 'Zerg 'infestation-pit   150 150 3 #f '(enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) '(carrier tempest thor battlecruiser mothership colossus))
   (upg 'zerg-melee-weapons-1   1186 53  'Zerg 'evolution-chamber 100 100 1 #f '(opponent-unwalled-punish enemy-multi-prong-drop-or-runby) '(marine zergling zealot))
   (upg 'zerg-melee-weapons-2   1187 54  'Zerg 'evolution-chamber 150 150 2 'zerg-melee-weapons-1 '(our-snowball-finish-window enemy-fast-3cc-or-nexus-greed) '(marine stalker zealot))
   (upg 'zerg-melee-weapons-3   1188 55  'Zerg 'evolution-chamber 200 200 3 'zerg-melee-weapons-2 '(late-game-spellcaster-standoff base-trade-race) '(marine marauder ultralisk archon))
   (upg 'zerg-missile-weapons-1 1192 59  'Zerg 'evolution-chamber 100 100 1 #f '(opponent-proxy-all-in-defense enemy-air-harass-transition) '(roach hydralisk void-ray stalker))
   (upg 'zerg-missile-weapons-2 1193 60  'Zerg 'evolution-chamber 150 150 2 'zerg-missile-weapons-1 '(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech) '(siege-tank immortal carrier liberator))
   (upg 'zerg-missile-weapons-3 1194 61  'Zerg 'evolution-chamber 200 200 3 'zerg-missile-weapons-2 '(late-game-spellcaster-standoff base-trade-race) '(thor battlecruiser tempest carrier))
   (upg 'zerg-ground-armor-1    1189 56  'Zerg 'evolution-chamber 150 150 1 #f '(enemy-air-harass-transition opponent-proxy-all-in-defense) '(marine zergling carrier interceptor adept))
   (upg 'zerg-ground-armor-2    1190 57  'Zerg 'evolution-chamber 225 225 2 'zerg-ground-armor-1 '(our-snowball-finish-window enemy-turtle-skytoss-or-mech) '(marine zergling mutalisk carrier))
   (upg 'zerg-ground-armor-3    1191 58  'Zerg 'evolution-chamber 300 300 3 'zerg-ground-armor-2 '(late-game-spellcaster-standoff enemy-turtle-skytoss-or-mech) '(marine carrier battlecruiser zealot))
   (upg 'zerg-flyer-weapons-1   1312 68  'Zerg 'spire             100 100 2 #f '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech) '(mutalisk phoenix carrier tempest battlecruiser))
   (upg 'zerg-flyer-weapons-2   1313 69  'Zerg 'spire             175 175 2 'zerg-flyer-weapons-1 '(enemy-turtle-skytoss-or-mech) '(carrier tempest brood-lord battlecruiser))
   (upg 'zerg-flyer-weapons-3   1314 70  'Zerg 'spire             250 250 3 'zerg-flyer-weapons-2 '(late-game-spellcaster-standoff) '(carrier tempest battlecruiser))
   (upg 'zerg-flyer-armor-1     1315 71  'Zerg 'spire             150 150 2 #f '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech) '(phoenix marine thor carrier mutalisk))
   (upg 'zerg-flyer-armor-2     1316 72  'Zerg 'spire             225 225 2 'zerg-flyer-armor-1 '(enemy-turtle-skytoss-or-mech) '(carrier phoenix thor marine))
   (upg 'zerg-flyer-armor-3     1317 73  'Zerg 'spire             300 300 3 'zerg-flyer-armor-2 '(late-game-spellcaster-standoff) '(carrier battlecruiser thor))

   ;; Terran Upgrades (27)
   (upg 'stimpack                  730  15  'Terran 'barracks-techlab 100 100 1 #f '(opponent-unwalled-punish opponent-proxy-all-in-defense enemy-multi-prong-drop-or-runby our-snowball-finish-window) '(zergling roach zealot stalker baneling))
   (upg 'combat-shield             731  16  'Terran 'barracks-techlab 100 100 1 #f '(opponent-proxy-all-in-defense enemy-cannon-or-bunker-contain enemy-air-harass-transition) '(baneling oracle widow-mine adept stalker))
   (upg 'concussive-shells         732  17  'Terran 'barracks-techlab 50  50  1 #f '(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush) '(zealot stalker roach zergling))
   (upg 'infernal-preigniter       761  19  'Terran 'factory-techlab  100 100 2 #f '(opponent-unwalled-punish enemy-multi-prong-drop-or-runby) '(zergling zealot hydralisk marine))
   (upg 'drilling-claws            764  122 'Terran 'factory-techlab  75  75  2 #f '(enemy-multi-prong-drop-or-runby our-eco-deficit-comeback-harass) '(zergling baneling zealot stalker oracle))
   (upg 'smart-servos              766  289 'Terran 'factory-techlab  100 100 2 #f '(enemy-air-harass-transition enemy-multi-prong-drop-or-runby enemy-cannon-or-bunker-contain) '(mutalisk zergling zealot void-ray tempest))
   (upg 'cyclone-lock-on-damage    769  144 'Terran 'factory-techlab  100 100 2 #f '(enemy-cannon-or-bunker-contain enemy-air-harass-transition enemy-turtle-skytoss-or-mech) '(void-ray oracle roach stalker ravager warp-prism tempest))
   (upg 'banshee-cloak             790  20  'Terran 'starport-techlab 100 100 1 #f '(our-eco-deficit-comeback-harass enemy-fast-3cc-or-nexus-greed) '(roach siege-tank immortal zealot))
   (upg 'hyperflight-rotors        799  138 'Terran 'starport-techlab 100 100 2 #f '(our-eco-deficit-comeback-harass enemy-multi-prong-drop-or-runby) '(stalker hydralisk phoenix mutalisk))
   (upg 'advanced-ballistics       805  140 'Terran 'fusion-core      150 150 3 #f '(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech) '(lurker immortal stalker hydralisk queen))
   (upg 'personal-cloaking         820  25  'Terran 'ghost-academy    150 150 2 #f '(late-game-spellcaster-standoff enemy-turtle-skytoss-or-mech) '(high-templar infestor viper ultralisk))
   (upg 'weapon-refit              1532 76  'Terran 'fusion-core      150 150 3 #f '(enemy-turtle-skytoss-or-mech base-trade-race) '(carrier tempest corruptor thor battlecruiser))
   (upg 'terran-infantry-weapons-1 652  7   'Terran 'engineering-bay  100 100 1 #f '(opponent-unwalled-punish our-snowball-finish-window) '(zergling roach zealot stalker))
   (upg 'terran-infantry-weapons-2 653  8   'Terran 'engineering-bay  175 175 2 'terran-infantry-weapons-1 '(our-snowball-finish-window enemy-siege-or-lurker-contain) '(roach marauder stalker immortal))
   (upg 'terran-infantry-weapons-3 654  9   'Terran 'engineering-bay  250 250 3 'terran-infantry-weapons-2 '(late-game-spellcaster-standoff base-trade-race) '(ultralisk archon brood-lord))
   (upg 'terran-infantry-armor-1   656  11  'Terran 'engineering-bay  100 100 1 #f '(opponent-proxy-all-in-defense enemy-multi-prong-drop-or-runby) '(zergling marine carrier mutalisk))
   (upg 'terran-infantry-armor-2   657  12  'Terran 'engineering-bay  175 175 2 'terran-infantry-armor-1 '(our-snowball-finish-window enemy-air-harass-transition) '(mutalisk carrier marine zealot))
   (upg 'terran-infantry-armor-3   658  13  'Terran 'engineering-bay  250 250 3 'terran-infantry-armor-2 '(late-game-spellcaster-standoff) '(carrier marine ultralisk))
   (upg 'terran-vehicle-weapons-1  855  30  'Terran 'armory           100 100 2 #f '(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech enemy-cannon-or-bunker-contain) '(roach siege-tank stalker lurker photon-cannon shield-battery))
   (upg 'terran-vehicle-weapons-2  856  31  'Terran 'armory           175 175 2 'terran-vehicle-weapons-1 '(enemy-turtle-skytoss-or-mech) '(siege-tank thor ultralisk immortal))
   (upg 'terran-vehicle-weapons-3  857  32  'Terran 'armory           250 250 3 'terran-vehicle-weapons-2 '(late-game-spellcaster-standoff) '(thor ultralisk colossus))
   (upg 'terran-vehicle-plating-1  864  116 'Terran 'armory           100 100 2 #f '(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech) '(zergling mutalisk marine carrier))
   (upg 'terran-vehicle-plating-2  865  117 'Terran 'armory           175 175 2 'terran-vehicle-plating-1 '(enemy-turtle-skytoss-or-mech) '(carrier viking mutalisk))
   (upg 'terran-vehicle-plating-3  866  118 'Terran 'armory           250 250 3 'terran-vehicle-plating-2 '(late-game-spellcaster-standoff) '(carrier tempest battlecruiser))
   (upg 'terran-ship-weapons-1     861  36  'Terran 'armory           100 100 2 #f '(enemy-turtle-skytoss-or-mech enemy-air-harass-transition) '(viking battlecruiser carrier corruptor))
   (upg 'terran-ship-weapons-2     862  37  'Terran 'armory           175 175 2 'terran-ship-weapons-1 '(enemy-turtle-skytoss-or-mech) '(carrier tempest brood-lord battlecruiser))
   (upg 'terran-ship-weapons-3     863  38  'Terran 'armory           250 250 3 'terran-ship-weapons-2 '(late-game-spellcaster-standoff) '(carrier tempest battlecruiser))

   ;; Protoss Upgrades (26)
   (upg 'warpgate                 1568 84  'Protoss 'cybernetics-core  50  50  1 #f '(opponent-unwalled-punish opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush enemy-cannon-or-bunker-contain) '(zergling marine reaper zealot))
   (upg 'charge                   1592 86  'Protoss 'twilight-council  100 100 2 #f '(enemy-siege-or-lurker-contain opponent-unwalled-punish our-snowball-finish-window) '(siege-tank marauder immortal hydralisk stalker))
   (upg 'blink                    1593 87  'Protoss 'twilight-council  150 150 2 #f '(enemy-air-harass-transition enemy-multi-prong-drop-or-runby our-army-trapped-or-out-of-position enemy-cannon-or-bunker-contain) '(liberator banshee oracle mutalisk medivac roach tempest void-ray warp-prism))
   (upg 'resonating-glaives       1594 130 'Protoss 'twilight-council  100 100 1 #f '(opponent-unwalled-punish our-eco-deficit-comeback-harass enemy-fast-3cc-or-nexus-greed) '(marine zergling hydralisk zealot))
   (upg 'psi-storm                1126 52  'Protoss 'templar-archive   200 200 2 #f '(late-game-spellcaster-standoff enemy-siege-or-lurker-contain enemy-multi-prong-drop-or-runby) '(marine marauder hydralisk mutalisk baneling zergling))
   (upg 'shadow-strike            2720 141 'Protoss 'dark-shrine       100 100 2 #f '(our-eco-deficit-comeback-harass base-trade-race) '(siege-tank planetary-fortress ghost))
   (upg 'extended-thermal-lance   1097 50  'Protoss 'robotics-bay      150 150 2 #f '(enemy-siege-or-lurker-contain our-snowball-finish-window) '(marine hydralisk zergling lurker))
   (upg 'gravitic-booster         1093 48  'Protoss 'robotics-bay      100 100 2 #f '(enemy-cloaked-or-burrowed-threat enemy-multi-prong-drop-or-runby) '(banshee ghost dark-templar widow-mine lurker))
   (upg 'gravitic-drive           1094 49  'Protoss 'robotics-bay      100 100 2 #f '(our-eco-deficit-comeback-harass our-army-trapped-or-out-of-position enemy-cannon-or-bunker-contain) '(siege-tank immortal stalker))
   (upg 'anion-pulse-crystals     44   112 'Protoss 'fleet-beacon      150 150 2 #f '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech) '(mutalisk corruptor medivac liberator void-ray))
   (upg 'flux-vanes               48   288 'Protoss 'fleet-beacon      150 150 3 #f '(enemy-turtle-skytoss-or-mech base-trade-race) '(corruptor viking stalker))
   (upg 'protoss-ground-weapons-1 1062 39  'Protoss 'forge             100 100 1 #f '(opponent-unwalled-punish our-snowball-finish-window) '(zergling roach marine zealot))
   (upg 'protoss-ground-weapons-2 1063 40  'Protoss 'forge             150 150 2 'protoss-ground-weapons-1 '(our-snowball-finish-window enemy-siege-or-lurker-contain) '(roach marauder stalker ravager))
   (upg 'protoss-ground-weapons-3 1064 41  'Protoss 'forge             200 200 3 'protoss-ground-weapons-2 '(late-game-spellcaster-standoff) '(ultralisk archon thor))
   (upg 'protoss-ground-armor-1   1065 42  'Protoss 'forge             100 100 1 #f '(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush) '(zergling marine carrier))
   (upg 'protoss-ground-armor-2   1066 43  'Protoss 'forge             150 150 2 'protoss-ground-armor-1 '(our-snowball-finish-window enemy-multi-prong-drop-or-runby) '(zergling marine carrier))
   (upg 'protoss-ground-armor-3   1067 44  'Protoss 'forge             200 200 3 'protoss-ground-armor-2 '(late-game-spellcaster-standoff) '(marine zergling carrier))
   (upg 'protoss-shields-1        1068 45  'Protoss 'forge             150 150 2 #f '(enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) '(phoenix void-ray marine archon))
   (upg 'protoss-shields-2        1069 46  'Protoss 'forge             225 225 3 'protoss-shields-1 '(enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) '(carrier tempest mutalisk))
   (upg 'protoss-shields-3        1070 47  'Protoss 'forge             300 300 3 'protoss-shields-2 '(late-game-spellcaster-standoff) '(carrier tempest battlecruiser))
   (upg 'protoss-air-weapons-1    1562 78  'Protoss 'cybernetics-core  100 100 2 #f '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech) '(carrier tempest void-ray corruptor))
   (upg 'protoss-air-weapons-2    1563 79  'Protoss 'cybernetics-core  175 175 2 'protoss-air-weapons-1 '(enemy-turtle-skytoss-or-mech) '(carrier tempest brood-lord battlecruiser))
   (upg 'protoss-air-weapons-3    1564 80  'Protoss 'cybernetics-core  250 250 3 'protoss-air-weapons-2 '(late-game-spellcaster-standoff) '(carrier tempest battlecruiser))
   (upg 'protoss-air-armor-1      1565 81  'Protoss 'cybernetics-core  150 150 2 #f '(enemy-air-harass-transition enemy-turtle-skytoss-or-mech) '(phoenix marine mutalisk carrier))
   (upg 'protoss-air-armor-2      1566 82  'Protoss 'cybernetics-core  225 225 2 'protoss-air-armor-1 '(enemy-turtle-skytoss-or-mech) '(carrier phoenix thor))
   (upg 'protoss-air-armor-3      1567 83  'Protoss 'cybernetics-core  300 300 3 'protoss-air-armor-2 '(late-game-spellcaster-standoff) '(carrier battlecruiser marine))))

(define COMPLETE-LOTV-UPGRADE-CATALOG : (Immutable-HashTable Symbol upgrade-catalog-entry)
  (for/hasheq : (Immutable-HashTable Symbol upgrade-catalog-entry)
              ([u (in-list COMPLETE-LOTV-UPGRADE-LIST)])
    (values (upgrade-catalog-entry-sym u) u)))

(: lookup-upgrade-entry (-> Symbol (Option upgrade-catalog-entry)))
(define (lookup-upgrade-entry sym)
  (hash-ref COMPLETE-LOTV-UPGRADE-CATALOG sym (lambda () #f)))

;; -----------------------------------------------------------------------------
;; 4. Complete 48-Unit LotV Counter Matrix (+ Static Defense/Utility Aux Matrix)
;; -----------------------------------------------------------------------------

(: uc (-> Symbol Symbol Symbol (Listof Symbol) (Listof Symbol) (Listof Symbol) (Listof Symbol) (Listof Symbol) Symbol (Listof Symbol) unit-counter-entry))
(define (uc sym r tc zh th ph soft spells pos upgs)
  (unit-counter-entry sym r tc zh th ph soft spells pos upgs))

;; Exact 48 trainable LotV multiplayer combat & support units (16 Terran + 14 Zerg + 18 Protoss).
(define COMPLETE-UNIT-COUNTER-LIST : (Listof unit-counter-entry)
  (list
   ;; --- Terran (16) ---
   (uc 'marine 'Terran 'bio-light
       '(baneling lurker ultralisk infestor)
       '(siege-tank hellbat widow-mine colossus-proxy)
       '(colossus high-templar disruptor)
       '(zergling roach marine adept stalker)
       '(fungal-growth psi-storm purification-nova blinding-cloud)
       'concave-splash-surround
       '(centrifugal-hooks psi-storm extended-thermal-lance chitinous-plating))
   (uc 'marauder 'Terran 'bio-armored
       '(zergling hydralisk mutalisk brood-lord)
       '(siege-tank banshee liberator marine)
       '(immortal zealot void-ray archon)
       '(roach ravager disruptor void-ray)
       '(fungal-growth blinding-cloud anti-armor-missile charge)
       'surround-or-air-kite
       '(zergling-movementspeed charge stimpack))
   (uc 'reaper 'Terran 'early-raider
       '(queen zergling roach spine-crawler)
       '(marine reaper hellion)
       '(adept stalker zealot)
       '(spine-crawler photon-cannon bunker)
       '(kd8-charge lock-on graviton-beam)
       'cliff-edge-screen
       '(zergling-movementspeed concussive-shells resonating-glaives))
   (uc 'ghost 'Terran 'spellcaster-cloak
       '(zergling baneling ultralisk overseer)
       '(siege-tank hellion raven banshee)
       '(disruptor colossus zealot observer)
       '(roach stalker marauder)
       '(fungal-growth feedback anti-armor-missile oracle-revelation scanner-sweep)
       'spread-casters-detect
       '(zergling-movementspeed gravitic-booster psi-storm))
   (uc 'hellion 'Terran 'light-raider
       '(roach queen zergling-surround)
       '(marauder cyclone siege-tank)
       '(stalker adept immortal)
       '(bunker photon-cannon spine-crawler)
       '(fungal-growth force-field lock-on concussive-shells)
       'seal-mineral-line-choke
       '(glial-reconstitution blink concussive-shells))
   (uc 'hellbat 'Terran 'light-cleave
       '(roach ravager lurker baneling)
       '(siege-tank marauder banshee)
       '(stalker adept colossus disruptor)
       '(hydralisk immortal liberator)
       '(corrosive-bile force-field purification-nova)
       'kite-beyond-4.5-tiles
       '(glial-reconstitution blink stimpack))
   (uc 'widow-mine 'Terran 'burrow-splash
       '(hydralisk overseer ravager brood-lord)
       '(siege-tank raven marauder)
       '(observer stalker disruptor colossus)
       '(zergling-bait oracle-revelation)
       '(corrosive-bile oracle-revelation scanner-sweep purification-nova)
       'bait-single-unit-out-range
       '(grooved-spines gravitic-booster))
   (uc 'cyclone 'Terran 'fast-skirmisher
       '(zergling infestors ravager)
       '(siege-tank marauder viking-probe-tank)
       '(stalker immortal phoenix-lift)
       '(roach adept zealot)
       '(fungal-growth graviton-beam interference-matrix neural-parasite)
       'break-15-tile-lock-on-tether
       '(zergling-movementspeed charge blink))
   (uc 'siege-tank 'Terran 'siege
       '(viper ravager brood-lord mutalisk zergling-flank)
       '(liberator banshee viking-drops battlecruiser)
       '(immortal zealot phoenix tempest disruptor)
       '(hydralisk marauder stalker)
       '(abduct blinding-cloud corrosive-bile interference-matrix graviton-beam)
       'flank-or-air-pickoff
       '(charge extended-thermal-lance anabolic-synthesis))
   (uc 'thor 'Terran 'heavy-mech
       '(zergling lurker infestor viper brood-lord)
       '(siege-tank marauder banshee)
       '(immortal disruptor zealot high-templar)
       '(roach hydra-viper)
       '(neural-parasite blinding-cloud abduct interference-matrix feedback)
       'surround-with-light-ground
       '(adrenal-glands charge neural-parasite))
   (uc 'viking 'Terran 'anti-air
       '(mutalisk-magic-box corruptor viper hydralisk)
       '(marine cyclone thor-es)
       '(stalker high-templar phoenix-micro void-ray)
       '(queen spore-crawler missile-turret)
       '(parasitic-bomb psi-storm fungal-growth anti-armor-missile)
       'ground-anti-armor-focus-landed
       '(grooved-spines blink psi-storm))
   (uc 'medivac 'Terran 'drop-transport
       '(mutalisk corruptor hydralisk queen)
       '(viking cyclone missile-turret)
       '(phoenix stalker high-templar)
       '(spore-crawler blink-stalker)
       '(feedback parasitic-bomb abduct fungal-growth)
       'snipe-before-unload
       '(muscular-augments blink anion-pulse-crystals))
   (uc 'liberator 'Terran 'air-siege
       '(corruptor ravager mutalisk viper)
       '(viking cyclone thor)
       '(tempest stalker phoenix void-ray)
       '(hydralisk queen-spore)
       '(corrosive-bile parasitic-bomb abduct blink)
       'exit-freedom-zone-angle-snipe
       '(blink grooved-spines anion-pulse-crystals))
   (uc 'raven 'Terran 'air-caster
       '(corruptor hydralisk queen)
       '(viking cyclone marine)
       '(phoenix stalker high-templar)
       '(mutalisk void-ray)
       '(feedback parasitic-bomb abduct fungal-growth)
       'pull-workers-7-tiles-from-turret
       '(blink anion-pulse-crystals))
   (uc 'banshee 'Terran 'air-cloak-harass
       '(queen spore-crawler overseer mutalisk)
       '(viking cyclone missile-turret raven)
       '(phoenix observer stalker)
       '(hydralisk marine)
       '(oracle-revelation scanner-sweep fungal-growth lock-on)
       'detector-mineral-line-screen
       '(gravitic-booster blink pneuma-carapace))
   (uc 'battlecruiser 'Terran 'capital-air
       '(corruptor viper infestor spore-crawler)
       '(viking cyclone thor-hip)
       '(tempest void-ray high-templar stalker)
       '(queen-transfuse marine)
       '(neural-parasite parasitic-bomb interference-matrix prismatic-alignment feedback)
       'kiting-anti-armor-yamato-split
       '(zerg-flyer-weapons-1 prismatic-alignment terran-ship-weapons-1))

   ;; --- Zerg (14) ---
   (uc 'queen 'Zerg 'macro-defense
       '(zergling-surround ravager baneling)
       '(hellbat siege-tank liberator marine)
       '(immortal void-ray adept disruptor)
       '(roach stalker)
       '(emp-round anti-armor-missile feedback corrosive-bile)
       'deny-creep-and-energy-burn
       '(stimpack resonating-glaives))
   (uc 'zergling 'Zerg 'light-swarm
       '(baneling roach spine-crawler)
       '(hellion hellbat marine-medivac widow-mine)
       '(zealot archon adept colossus oracle)
       '(marauder stalker)
       '(force-field psi-storm pulsar-beam)
       'seal-choke-and-clump-cleave
       '(infernal-preigniter resonating-glaives charge))
   (uc 'baneling 'Zerg 'melee-splash
       '(roach lurker-burrowed ravager)
       '(siege-tank marauder widow-mine hellbat-split)
       '(immortal archon stalker disruptor colossus)
       '(queen-tank-frontline)
       '(force-field psi-storm stimpack corrosive-bile)
       'delta-split-and-direct-target-fire
       '(combat-shield stimpack blink))
   (uc 'roach 'Zerg 'armored-midground
       '(ravager lurker zergling-surround)
       '(marauder siege-tank banshee cyclone)
       '(immortal void-ray stalker disruptor)
       '(hydralisk-micro)
       '(blinding-cloud anti-armor-missile corrosive-bile prismatic-alignment)
       'concave-anti-armored-kiting
       '(concussive-shells stimpack blink))
   (uc 'ravager 'Zerg 'artillery-cast
       '(mutalisk zergling lurker)
       '(siege-tank marauder banshee liberator)
       '(immortal stalker phoenix disruptor)
       '(marine hydralisk)
       '(neural-parasite abduct interference-matrix)
       'sidestep-3.5s-corrosive-bile
       '(stimpack blink))
   (uc 'hydralisk 'Zerg 'glass-cannon-ranged
       '(baneling lurker-burrowed infestors)
       '(siege-tank hellbat marine-medivac)
       '(colossus high-templar disruptor)
       '(roach-timing stalker)
       '(psi-storm purification-nova fungal-growth blinding-cloud)
       'pre-split-splash-punish
       '(extended-thermal-lance psi-storm infernal-preigniter))
   (uc 'lurker 'Zerg 'burrowed-siege
       '(viper ravager brood-lord overseer)
       '(siege-tank liberator ghost-snipe)
       '(disruptor immortal carrier tempest oracle)
       '(hydralisk-viper observer-tempest)
       '(abduct blinding-cloud scanner-sweep oracle-revelation purification-nova steady-targeting)
       'outrange-10-tiles-with-detection
       '(advanced-ballistics gravitic-booster))
   (uc 'mutalisk 'Zerg 'air-harass
       '(hydralisk viper parasitic-bomb spore-crawler)
       '(thor-explosive marine-stim cyclone widow-mine)
       '(phoenix archon high-templar stalker)
       '(queen missile-turret photon-cannon)
       '(parasitic-bomb fungal-growth psi-storm guardian-shield)
       'armor-line-defense-and-base-counter
       '(anion-pulse-crystals grooved-spines combat-shield))
   (uc 'corruptor 'Zerg 'anti-capital-air
       '(hydralisk viper parasitic-bomb)
       '(marine thor-hip cyclone viking-focus)
       '(void-ray-prismatic archon high-templar stalker)
       '(queen spore-crawler)
       '(prismatic-alignment parasitic-bomb psi-storm fungal-growth anti-armor-missile)
       'punish-ground-less-void-or-storm
       '(psi-storm stimpack))
   (uc 'brood-lord 'Zerg 'capital-siege
       '(corruptor viper hydralisk)
       '(viking thor-hip ghost-snipe battlecruiser)
       '(tempest void-ray carrier blink-stalker)
       '(mothership)
       '(abduct parasitic-bomb steady-targeting prismatic-alignment tactical-jump)
       'air-pincer-bypass-broodling-wall
       '(weapon-refit blink flux-vanes))
   (uc 'ultralisk 'Zerg 'heavy-melee-tank
       '(lurker brood-lord queen-roach)
       '(ghost-snipe marauder liberator siege-tank)
       '(immortal void-ray carrier tempest archon)
       '(baneling-counter)
       '(steady-targeting neural-parasite blinding-cloud force-field)
       'choke-kite-with-high-single-target-dps
       '(concussive-shells advanced-ballistics))
   (uc 'infestor 'Zerg 'spellcaster
       '(ravager lurker zergling-surround overseer)
       '(ghost-emp siege-tank raven)
       '(high-templar-feedback disruptor observer)
       '(stalker marine)
       '(feedback emp-round scanner-sweep oracle-revelation)
       'split-vs-fungal-burn-energy
       '(personal-cloaking gravitic-booster))
   (uc 'swarm-host 'Zerg 'wave-siege
       '(mutalisk zergling-hunt overseer)
       '(hellion banshee reaper medivac-drop)
       '(phoenix oracle warp-prism-zealot)
       '(roach-runby)
       '(scanner-sweep oracle-revelation parasitic-bomb)
       'triangulate-locust-vector-hunt-43s-cd
       '(zergling-movementspeed gravitic-booster hyperflight-rotors))
   (uc 'viper 'Zerg 'air-spellcaster
       '(hydralisk corruptor parasitic-bomb)
       '(ghost-emp-snipe viking thor-hip marine)
       '(high-templar-feedback phoenix tempest stalker)
       '(queen spore-crawler)
       '(feedback emp-round steady-targeting interference-matrix)
       'zone-and-snipe-low-range-casters
       '(personal-cloaking blink))

   ;; --- Protoss (18) ---
   (uc 'zealot 'Protoss 'melee-frontline
       '(baneling roach-kite lurker)
       '(hellbat widow-mine marine-concussive-marauder)
       '(archon colossus adept)
       '(zergling-surround)
       '(fungal-growth emp-round blinding-cloud)
       'choke-kite-shield-strip
       '(infernal-preigniter concussive-shells glial-reconstitution))
   (uc 'stalker 'Protoss 'blink-skirmisher
       '(zergling-surround roach hydralisk lurker)
       '(marauder siege-tank cyclone)
       '(immortal disruptor zealot-charge)
       '(mutalisk void-ray)
       '(fungal-growth concussive-shells lock-on blinding-cloud)
       'surround-after-blink-cooldown
       '(zergling-movementspeed concussive-shells charge))
   (uc 'sentry 'Protoss 'forcefield-support
       '(ravager baneling zergling)
       '(ghost-emp siege-tank marine)
       '(disruptor high-templar stalker)
       '(roach adept)
       '(corrosive-bile emp-round feedback)
       'shatter-force-field-or-burn-energy
       '(emp-round))
   (uc 'adept 'Protoss 'shade-harass
       '(roach zergling-surround baneling)
       '(marauder hellbat widow-mine)
       '(stalker immortal zealot)
       '(queen spine-crawler bunker)
       '(fungal-growth concussive-shells force-field)
       'split-defense-shade-and-body
       '(glial-reconstitution concussive-shells blink))
   (uc 'high-templar 'Protoss 'aoe-caster
       '(baneling zergling lurker brood-lord)
       '(ghost-emp widow-mine liberator)
       '(disruptor archon high-templar-feedback)
       '(roach stalker)
       '(emp-round steady-targeting abduct purification-nova)
       'spread-and-pre-emp
       '(personal-cloaking adaptive-talons))
   (uc 'dark-templar 'Protoss 'cloak-assassin
       '(overseer spore-crawler zergling-surround)
       '(raven scanner-sweep missile-turret hellbat)
       '(observer oracle-revelation photon-cannon)
       '(roach)
       '(oracle-revelation scanner-sweep fungal-growth emp-round)
       'permanent-detector-at-ramp-and-lines
       '(gravitic-booster))
   (uc 'archon 'Protoss 'heavy-splash
       '(lurker brood-lord ultralisk hydralisk)
       '(ghost-emp marauder liberator siege-tank)
       '(immortal disruptor tempest)
       '(roach ravager)
       '(emp-round blinding-cloud anti-armor-missile purification-nova)
       'emp-350-shields-then-kite
       '(personal-cloaking lurker-range))
   (uc 'immortal 'Protoss 'anti-armored-core
       '(zergling ravager hydralisk mutalisk brood-lord)
       '(marine ghost-emp cyclone-lock-on siege-tank banshee liberator)
       '(zealot stalker-battery-overcharge archon carrier disruptor)
       '(ravager-bile)
       '(emp-round blinding-cloud neural-parasite interference-matrix lock-on)
       'overwhelm-barrier-with-high-rofl-light-units
       '(zergling-attackspeed stimpack charge blink))
   (uc 'colossus 'Protoss 'long-range-splash
       '(corruptor viper lurker)
       '(viking liberator marauder-medivac)
       '(immortal tempest disruptor)
       '(roach ravager)
       '(abduct interference-matrix anti-armor-missile purification-nova)
       'air-snipe-or-abduct-focus
       '(terran-ship-weapons-1 zerg-flyer-weapons-1))
   (uc 'disruptor 'Protoss 'nova-burst
       '(zergling-flank viper brood-lord mutalisk)
       '(liberator ghost-snipe marauder-medivac banshee)
       '(immortal-prism-juggle phoenix disruptor-split)
       '(stalker-blink)
       '(abduct interference-matrix oracle-revelation blink)
       'perpendicular-split-snipe-21s-cooldown
       '(blink hyperflight-rotors zergling-movementspeed))
   (uc 'observer 'Protoss 'cloak-detector
       '(overseer-hydra spore-crawler mutalisk)
       '(raven-viking scanner-sweep missile-turret)
       '(observer-stalker phoenix oracle)
       '(queen)
       '(scanner-sweep oracle-revelation parasitic-bomb)
       'deny-vision-clear-observers
       '(gravitic-booster))
   (uc 'warp-prism 'Protoss 'drop-warp-gate
       '(mutalisk corruptor queen-spore)
       '(viking cyclone missile-turret marine)
       '(phoenix stalker high-templar)
       '(hydralisk)
       '(abduct lock-on feedback fungal-growth)
       'kill-phased-prism-within-4s-warp
       '(blink anion-pulse-crystals grooved-spines))
   (uc 'phoenix 'Protoss 'air-superiority
       '(hydralisk corruptor infestor-fungal spore-crawler)
       '(marine-stim thor-es cyclone widow-mine)
       '(stalker-blink archon carrier)
       '(queen)
       '(fungal-growth parasitic-bomb guardian-shield anti-armor-missile)
       'spread-overlords-kite-under-anti-air
       '(grooved-spines stimpack blink))
   (uc 'void-ray 'Protoss 'anti-armored-air
       '(hydralisk queen-transfuse viper mutalisk-magic)
       '(marine-stim cyclone widow-mine viking-kite)
       '(phoenix stalker-blink high-templar)
       '(spore-crawler)
       '(parasitic-bomb fungal-growth feedback anti-armor-missile)
       'kite-out-4.5s-prismatic-alignment
       '(grooved-spines stimpack blink psi-storm))
   (uc 'oracle 'Protoss 'air-harass-detect
       '(queen spore-crawler hydralisk)
       '(marine-turret cyclone widow-mine viking)
       '(stalker phoenix shield-battery)
       '(mutalisk)
       '(lock-on feedback fungal-growth)
       '6-worker-turret-spore-line-screen
       '(stimpack blink grooved-spines))
   (uc 'carrier 'Protoss 'capital-swarm
       '(corruptor-focus viper infestor-neural)
       '(marine-3-3 thor-es liberator-splash viking-armor)
       '(tempest void-ray archon-storm)
       '(hydralisk-viper)
       '(parasitic-bomb neural-parasite anti-armor-missile interference-matrix feedback)
       'target-carrier-hull-or-anti-armor-mass-marine
       '(zerg-flyer-weapons-1 terran-infantry-weapons-3 protoss-air-weapons-1))
   (uc 'tempest 'Protoss 'long-range-siege-air
       '(corruptor viper zergling-base-counter)
       '(viking cyclone battlecruiser-jump)
       '(void-ray phoenix stalker-blink)
       '(hydralisk)
       '(abduct parasitic-bomb neural-parasite interference-matrix tactical-jump)
       'gap-close-on-low-dps-tempests
       '(flux-vanes pneumatized-carapace hyperflight-rotors))
   (uc 'mothership 'Protoss 'cloak-flagship
       '(viper-abduct corruptor overseer)
       '(viking ghost-emp-snipe thor-hip)
       '(tempest observer-void-ray feedback)
       '(hydralisk-overseer)
       '(abduct neural-parasite interference-matrix feedback oracle-revelation)
       'snipe-cloak-anchor-first-with-detection
       '(zerg-flyer-weapons-2 personal-cloaking))))

(define COMPLETE-UNIT-COUNTER-MATRIX : (Immutable-HashTable Symbol unit-counter-entry)
  (for/hasheq : (Immutable-HashTable Symbol unit-counter-entry)
              ([e (in-list COMPLETE-UNIT-COUNTER-LIST)])
    (values (unit-counter-entry-unit-sym e) e)))

;; Static-Defense / Detector / Nydus Aux Counter Matrix (mirrors tactical defense/counter pairs)
(define COMPLETE-STRUCTURE-COUNTER-MATRIX : (Immutable-HashTable Symbol unit-counter-entry)
  (for/hasheq : (Immutable-HashTable Symbol unit-counter-entry)
              ([e (in-list
                   (list
                    (uc 'photon-cannon 'Protoss 'static-defense
                        '(ravager spine-crawler-7.2t nydus-canal lurker brood-lord zergling-pylon)
                        '(siege-tank cyclone high-ground-bunker liberator marauder)
                        '(stalker shield-battery nexus-overcharge immortal tempest disruptor)
                        '(stalker ravager siege-tank)
                        '(corrosive-bile lock-on battery-overcharge blinding-cloud purification-nova)
                        'snipe-artosis-pylon-or-outrange-7
                        '(lurker-range cyclone-lock-on-damage blink))
                    (uc 'shield-battery 'Protoss 'static-defense
                        '(ravager nydus-canal lurker viper)
                        '(cyclone-lock-on siege-tank ghost-emp high-ground-bunker)
                        '(stalker-blink immortal disruptor shield-battery)
                        '(zergling ravager stalker)
                        '(emp-round corrosive-bile lock-on battery-overcharge purification-nova)
                        'disengage-14s-overcharge-kite-6
                        '(personal-cloaking cyclone-lock-on-damage blink))
                    (uc 'bunker 'Terran 'static-defense
                        '(ravager zergling-scv-focus lurker brood-lord)
                        '(siege-tank liberator reaper-bypass)
                        '(immortal stalker tempest warp-prism)
                        '(baneling)
                        '(corrosive-bile force-field blinding-cloud)
                        'kill-repairing-scvs-or-bile-arc
                        '(lurker-range))
                    (uc 'missile-turret 'Terran 'static-defense-detector
                        '(ravager zergling roach)
                        '(marauder siege-tank marine)
                        '(stalker zealot)
                        '(mutalisk-blind-spot)
                        '(corrosive-bile)
                        'route-air-around-7.5-blind-spots
                        '(stimpack))
                    (uc 'planetary-fortress 'Terran 'fortified-base
                        '(lurker brood-lord viper zergling-baneling)
                        '(siege-tank liberator ghost-nuke)
                        '(immortal tempest disruptor dark-templar)
                        '(corruptor-spray)
                        '(blinding-cloud anti-armor-missile emp-round interference-matrix)
                        'aoe-scv-ring-and-range-6-siege
                        '(lurker-range weapon-refit))
                    (uc 'spine-crawler 'Zerg 'static-defense
                        '(ravager zergling-uproot lurker)
                        '(siege-tank hellion banshee liberator)
                        '(immortal stalker oracle)
                        '(roach)
                        '(corrosive-bile purification-nova)
                        'snipe-uprooted-crawlers-and-tumors
                        '(stimpack))
                    (uc 'spore-crawler 'Zerg 'static-defense-detector
                        '(ravager zergling)
                        '(hellion banshee-uproot liberator)
                        '(stalker adept warp-prism)
                        '(oracle)
                        '(corrosive-bile)
                        'punish-uproot-and-snipe-creep-tumors
                        '(resonating-glaives))
                    (uc 'nydus-canal 'Zerg 'map-bypass
                        '(zergling-workers-6-8 ravager lurker)
                        '(marine-scvs-8 siege-tank hellion)
                        '(zealot-probes-8 stalker immortal)
                        '(queen)
                        '(corrosive-bile force-field)
                        'pull-6-8-workers-snipe-0-armor-head
                        '(stimpack))
                    (uc 'overseer 'Zerg 'detector
                        '(mutalisk hydralisk)
                        '(viking cyclone marine)
                        '(phoenix stalker)
                        '(spore-crawler)
                        '(feedback lock-on)
                        'deny-detection-before-cloak-strike
                        '(blink))))])
    (values (unit-counter-entry-unit-sym e) e)))

(: lookup-unit-counter-entry (-> Symbol (Option unit-counter-entry)))
(define (lookup-unit-counter-entry sym)
  (or (hash-ref COMPLETE-UNIT-COUNTER-MATRIX sym (lambda () #f))
      (hash-ref COMPLETE-STRUCTURE-COUNTER-MATRIX sym (lambda () #f))))

;; -----------------------------------------------------------------------------
;; 5. Situational Ability Action Selector & Upgrade Selector
;; -----------------------------------------------------------------------------

;; Module-level memoization caches & static role bitmasks for O(1) unit/upgrade lookup
(define CANON-UNIT-CACHE : (HashTable Symbol Symbol) (make-hasheq))
(define CANON-STRUCT-CACHE : (HashTable Symbol Symbol) (make-hasheq))
(define FLYING-UNIT-CACHE : (HashTable Symbol Symbol) (make-hasheq))

(: fast-canon-unit-sym (-> Symbol Symbol))
(define (fast-canon-unit-sym s)
  (define hit (hash-ref CANON-UNIT-CACHE s #f))
  (if hit
      hit
      (let ([c (sc2-canonical-unit-sym s)])
        (hash-set! CANON-UNIT-CACHE s c)
        c)))

(: fast-canon-struct-sym (-> Symbol Symbol))
(define (fast-canon-struct-sym s)
  (define hit (hash-ref CANON-STRUCT-CACHE s #f))
  (if hit
      hit
      (let ([c (sc2-canonical-structure-sym s)])
        (hash-set! CANON-STRUCT-CACHE s c)
        c)))

(: fast-flying-sym? (-> Symbol Boolean))
(define (fast-flying-sym? c)
  (define hit (hash-ref FLYING-UNIT-CACHE c #f))
  (if hit
      (eq? hit 'yes)
      (let ([fly? (or (sc2-unit-is-flying-sym? c)
                      (and (memq c '(oracle banshee mutalisk phoenix void-ray liberator
                                     medivac warp-prism carrier tempest battlecruiser brood-lord))
                           #t))])
        (hash-set! FLYING-UNIT-CACHE c (if fly? 'yes 'no))
        fly?)))

(define BIT-CLOAK-BURROW : Fixnum 1)
(define BIT-CASTER       : Fixnum 2)
(define BIT-SKY-MECH     : Fixnum 4)
(define BIT-SIEGE-LURKER : Fixnum 8)
(define BIT-DROP-RUNBY   : Fixnum 16)

(define ENEMY-UNIT-ROLE-HT : (HashTable Symbol Fixnum)
  (let ([ht : (HashTable Symbol Fixnum) (make-hasheq)])
    (: add-bit! (-> (Listof Symbol) Fixnum Void))
    (define (add-bit! syms b)
      (for ([s (in-list syms)])
        (hash-set! ht s (bitwise-ior (hash-ref ht s (lambda () 0)) b))))
    (add-bit! '(dark-templar banshee widow-mine widow-mine-burrowed lurker lurker-burrowed
                ghost swarm-host-burrowed roach-burrowed zergling-burrowed)
              BIT-CLOAK-BURROW)
    (add-bit! '(high-templar ghost infestor viper raven oracle sentry)
              BIT-CASTER)
    (add-bit! '(carrier tempest void-ray mothership siege-tank thor battlecruiser
                planetary-fortress planetary)
              BIT-SKY-MECH)
    (add-bit! '(siege-tank siege-tank-sieged lurker lurker-burrowed lurker-mp lurker-mp-burrowed
                liberator liberator-ag)
              BIT-SIEGE-LURKER)
    (add-bit! '(medivac warp-prism overlord-transport zergling hellion reaper adept zealot)
              BIT-DROP-RUNBY)
    ht))

(define BIT-STATIC-NEAR : Fixnum 1)
(define BIT-CONTAIN     : Fixnum 2)

(define ENEMY-STRUCT-ROLE-HT : (HashTable Symbol Fixnum)
  (let ([ht : (HashTable Symbol Fixnum) (make-hasheq)])
    (for ([s (in-list '(photon-cannon pylon bunker shield-battery spine-crawler barracks gateway))])
      (hash-set! ht s BIT-STATIC-NEAR))
    (for ([s (in-list '(photon-cannon bunker shield-battery spine-crawler))])
      (hash-set! ht s (bitwise-ior (hash-ref ht s (lambda () 0)) BIT-CONTAIN)))
    ht))

(define ABILITY-ACTOR-SET : (Immutable-HashTable Symbol Boolean)
  (for/hasheq : (Immutable-HashTable Symbol Boolean)
              ([s (in-list '(sentry nexus shield-battery queen marine marauder ravager
                             siege-tank bunker orbital-command oracle overseer observer
                             viper disruptor raven infestor ghost cyclone swarm-host
                             swarm-host-burrowed nydus-network mothership battlecruiser
                             stalker high-templar immortal warp-prism warp-prism-phasing
                             void-ray tempest))])
    (values s #t)))

;; Max min-energy threshold queried for each actor symbol in `select-ability-actions-from-ht`.
;; Any subsequent unit with lower/equal energy is strictly dominated (smaller seq already qualifies).
(define ABILITY-ACTOR-MAX-ENERGY-HT : (Immutable-HashTable Symbol Float)
  (hasheq 'sentry 50.0
          'nexus 50.0
          'shield-battery 0.0
          'queen 50.0
          'marine 0.0
          'marauder 0.0
          'ravager 0.0
          'siege-tank 0.0
          'bunker 0.0
          'orbital-command 50.0
          'oracle 25.0
          'overseer 125.0
          'observer 0.0
          'viper 125.0
          'disruptor 0.0
          'raven 75.0
          'infestor 100.0
          'ghost 75.0
          'cyclone 0.0
          'swarm-host 0.0
          'swarm-host-burrowed 0.0
          'nydus-network 0.0
          'mothership 0.0
          'battlecruiser 0.0
          'stalker 0.0
          'high-templar 75.0
          'immortal 0.0
          'warp-prism 0.0
          'warp-prism-phasing 0.0
          'void-ray 0.0
          'tempest 0.0))

;; Pre-partitioned LotV upgrades per known race to avoid scanning all 82 entries per step
(define ZERG-UPGRADE-LIST : (Listof upgrade-catalog-entry)
  (filter (lambda ([u : upgrade-catalog-entry]) (eq? (upgrade-catalog-entry-race u) 'Zerg))
          COMPLETE-LOTV-UPGRADE-LIST))
(define TERRAN-UPGRADE-LIST : (Listof upgrade-catalog-entry)
  (filter (lambda ([u : upgrade-catalog-entry]) (eq? (upgrade-catalog-entry-race u) 'Terran))
          COMPLETE-LOTV-UPGRADE-LIST))
(define PROTOSS-UPGRADE-LIST : (Listof upgrade-catalog-entry)
  (filter (lambda ([u : upgrade-catalog-entry]) (eq? (upgrade-catalog-entry-race u) 'Protoss))
          COMPLETE-LOTV-UPGRADE-LIST))

(struct unit-type-meta
  ([canon-unit : Symbol]
   [canon-struct : Symbol]
   [army? : Boolean]
   [worker? : Boolean]
   [flying? : Boolean]
   [followup? : Boolean]
   [enemy-rmask : Fixnum]
   [enemy-smask : Fixnum]
   [actor-max-energy : (Option Float)])
  #:transparent)

(define UNIT-META-CACHE : (HashTable Symbol unit-type-meta) (make-hasheq))

(: fast-unit-meta (-> Symbol unit-type-meta))
(define (fast-unit-meta s)
  (define hit (hash-ref UNIT-META-CACHE s #f))
  (if hit
      hit
      (let* ([cu (fast-canon-unit-sym s)]
             [cs (fast-canon-struct-sym s)]
             [meta (unit-type-meta
                    cu
                    cs
                    (not (memq s '(scv probe drone larva egg overlord mule)))
                    (and (memq s '(drone probe scv)) #t)
                    (fast-flying-sym? cu)
                    (and (memq cu '(immortal warp-prism warp-prism-phasing tempest void-ray)) #t)
                    (or (hash-ref ENEMY-UNIT-ROLE-HT cu #f) 0)
                    (or (hash-ref ENEMY-STRUCT-ROLE-HT cs #f) 0)
                    (hash-ref ABILITY-ACTOR-MAX-ENERGY-HT cu #f))])
        (when (< (hash-count UNIT-META-CACHE) 512)
          (hash-set! UNIT-META-CACHE s meta))
        meta)))

(struct actor-entry
  ([seq : Integer]
   [id : Integer]
   [energy : Float])
  #:transparent)

(: push-actor-entry! (-> (HashTable Symbol (Listof actor-entry)) Symbol Integer Integer Float Void))
(define (push-actor-entry! actor-ht c seq id energy)
  (hash-set! actor-ht c (cons (actor-entry seq id energy)
                              (or (hash-ref actor-ht c #f) '()))))

(: maybe-push-actor! (-> (HashTable Symbol (Listof actor-entry)) Symbol Float Integer Any Void))
(define (maybe-push-actor! actor-ht c max-req seq u)
  (define cur-bucket (hash-ref actor-ht c #f))
  (unless (and cur-bucket (>= (actor-entry-energy (car cur-bucket)) max-req))
    (define-values (id energy) (dyn-unit-id-energy u))
    (when (> id 0)
      (when (or (not cur-bucket) (> energy (actor-entry-energy (car cur-bucket))))
        (hash-set! actor-ht c (cons (actor-entry seq id energy) (or cur-bucket '())))))))

(: finalize-actor-ht! (-> (HashTable Symbol (Listof actor-entry)) Void))
(define (finalize-actor-ht! actor-ht)
  (hash-for-each actor-ht
                 (lambda ([k : Symbol] [v : (Listof actor-entry)])
                   (when (and (pair? v) (pair? (cdr v)))
                     (hash-set! actor-ht k (reverse v))))))

(: unit-has-type-in? (-> Any (Listof Symbol) Boolean))
(define (unit-has-type-in? u syms)
  (and (hash? u)
       (memq (fast-canon-unit-sym (unit-type-sym u)) syms)
       #t))

(: select-ability-actions-from-ht
   (-> Symbol (Listof Symbol) (HashTable Symbol (Listof actor-entry)) Integer (Listof (Listof Any))))
(define (select-ability-actions-from-ht situation enemy-comp actor-ht frame)
  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  (: find-unit1 (-> Symbol Float (Option Integer)))
  (define (find-unit1 sym min-energy)
    (define bucket (hash-ref actor-ht sym #f))
    (and bucket
         (for/or : (Option Integer) ([e (in-list bucket)])
           (and (>= (actor-entry-energy e) min-energy)
                (actor-entry-id e)))))

  (: find-unit-any (-> (Listof Symbol) Float (Option Integer)))
  (define (find-unit-any types min-energy)
    (define best-seq : (Option Integer) #f)
    (define best-id : (Option Integer) #f)
    (for ([t (in-list types)])
      (define bucket (hash-ref actor-ht t #f))
      (when bucket
        (let loop ([xs : (Listof actor-entry) bucket])
          (when (pair? xs)
            (define e (car xs))
            (if (>= (actor-entry-energy e) min-energy)
                (let ([bs best-seq])
                  (when (or (not bs) (< (actor-entry-seq e) bs))
                    (set! best-seq (actor-entry-seq e))
                    (set! best-id (actor-entry-id e))))
                (loop (cdr xs)))))))
    best-id)

  (: has-enemy? (-> (Listof Symbol) Boolean))
  (define (has-enemy? types)
    (and (for/or : Boolean ([t (in-list enemy-comp)])
           (and (memq t types) #t))
         #t))

  ;; Recommend high-leverage spellcasts matching canonical `sc2-typed-commands.rkt` S-exprs
  (case situation
    [(opponent-unwalled-punish enemy-early-pool-or-worker-rush)
     (cond
       [(find-unit1 'sentry 50.0)
        => (lambda ([sid : Integer]) (emit! (list 'cast-spell sid 'force-field 44.0 44.0)))]
       [(find-unit1 'nexus 50.0)
        => (lambda ([nid : Integer])
             (define bat (find-unit1 'shield-battery 0.0))
             (when bat (emit! (list 'cast-spell nid 'battery-overcharge bat))))]
       [(find-unit1 'queen 50.0)
        => (lambda ([qid : Integer]) (emit! (list 'cast-spell qid 'transfusion qid)))]
       [(find-unit-any '(marine marauder) 0.0)
        => (lambda ([mid : Integer]) (emit! (list 'cast-spell mid 'stimpack)))])]

    [(opponent-proxy-all-in-defense)
     (cond
       [(find-unit1 'ravager 0.0)
        => (lambda ([rid : Integer]) (emit! (list 'cast-spell rid 'corrosive-bile 48.0 48.0)))]
       [(find-unit1 'siege-tank 0.0)
        => (lambda ([tid : Integer]) (emit! (list 'cast-spell tid 'siege-mode)))]
       [(find-unit1 'cyclone 0.0)
        => (lambda ([cid : Integer]) (emit! (list 'cast-spell cid 'lock-on 1)))]
       [(find-unit1 'nexus 50.0)
        => (lambda ([nid : Integer])
             (define bat (find-unit1 'shield-battery 0.0))
             (when bat (emit! (list 'cast-spell nid 'battery-overcharge bat))))]
       [(find-unit1 'bunker 0.0)
        => (lambda ([bid : Integer])
             (define bio (find-unit-any '(marine marauder) 0.0))
             (when bio (emit! (list 'bunker-load bid bio))))])]

    [(enemy-cannon-or-bunker-contain)
     (let ([rid (find-unit1 'ravager 0.0)])
       (when rid (emit! (list 'cast-spell rid 'corrosive-bile 48.0 48.0))))
     (let ([tid (find-unit1 'siege-tank 0.0)])
       (when tid (emit! (list 'cast-spell tid 'siege-mode))))
     (let ([cid (find-unit1 'cyclone 0.0)])
       (when cid (emit! (list 'cast-spell cid 'lock-on 1))))
     (let ([nyd (find-unit1 'nydus-network 0.0)])
       (when nyd (emit! (list 'cast-spell nyd 'build-nydus-worm 148.0 162.0))))
     (let ([nid (find-unit1 'nexus 50.0)]
           [bat (find-unit1 'shield-battery 0.0)])
       (when (and nid bat)
         (emit! (list 'cast-spell nid 'battery-overcharge bat))))
     (let ([bid (find-unit1 'bunker 0.0)]
           [bio (find-unit-any '(marine marauder) 0.0)])
       (when (and bid bio)
         (emit! (list 'bunker-load bid bio))))
     (let ([iid (find-unit1 'immortal 0.0)])
       (when iid (emit! (list 'cast-spell iid 'immortal-barrier))))
     (let ([vid (find-unit1 'void-ray 0.0)])
       (when vid (emit! (list 'cast-spell vid 'prismatic-alignment))))
     (let ([pid (find-unit1 'warp-prism-phasing 0.0)])
       (when pid (emit! (list 'cast-spell pid 'morph-warp-prism-transport))))]

    [(enemy-cloaked-or-burrowed-threat)
     (cond
       [(find-unit1 'orbital-command 50.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'scanner-sweep 45.0 45.0)))]
       [(find-unit1 'oracle 25.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'oracle-revelation 48.0 48.0)))]
       [(find-unit1 'overseer 0.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'morph-oversight-mode)))]
       [(find-unit1 'observer 0.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'morph-observer-siege-mode)))])]

    [(enemy-siege-or-lurker-contain)
     (cond
       [(find-unit1 'viper 75.0)
        => (lambda ([vid : Integer])
             (emit! (list 'cast-spell vid 'blinding-cloud 90.0 90.0))
             (when (find-unit1 'viper 100.0)
               (emit! (list 'cast-spell vid 'abduct 1))))]
       [(find-unit1 'disruptor 0.0)
        => (lambda ([did : Integer]) (emit! (list 'cast-spell did 'purification-nova 90.0 90.0)))]
       [(find-unit1 'raven 75.0)
        => (lambda ([rid : Integer]) (emit! (list 'cast-spell rid 'interference-matrix 1)))]
       [(find-unit1 'ravager 0.0)
        => (lambda ([rid : Integer]) (emit! (list 'cast-spell rid 'corrosive-bile 90.0 90.0)))])]

    [(enemy-air-harass-transition enemy-turtle-skytoss-or-mech)
     (cond
       [(find-unit1 'infestor 100.0)
        => (lambda ([iid : Integer])
             (emit! (list 'cast-spell iid
                          (if (has-enemy? '(carrier tempest battlecruiser void-ray))
                              'microbial-shroud
                              'fungal-growth)
                          88.0 88.0)))]
       [(find-unit1 'viper 125.0)
        => (lambda ([vid : Integer]) (emit! (list 'cast-spell vid 'parasitic-bomb 1)))]
       [(find-unit1 'raven 75.0)
        => (lambda ([rid : Integer]) (emit! (list 'cast-spell rid 'anti-armor-missile 1)))]
       [(find-unit1 'ghost 75.0)
        => (lambda ([gid : Integer]) (emit! (list 'cast-spell gid 'emp-round 88.0 88.0)))]
       [(find-unit1 'cyclone 0.0)
        => (lambda ([cid : Integer]) (emit! (list 'cast-spell cid 'lock-on 1)))])]

    [(enemy-fast-3cc-or-nexus-greed our-eco-deficit-comeback-harass)
     (cond
       [(find-unit-any '(swarm-host swarm-host-burrowed) 0.0)
        => (lambda ([shid : Integer]) (emit! (list 'cast-spell shid 'spawn-locusts 152.0 152.0)))]
       [(find-unit1 'raven 50.0)
        => (lambda ([rid : Integer]) (emit! (list 'cast-spell rid 'auto-turret 152.0 152.0)))]
       [(find-unit1 'overseer 125.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'contaminate 1)))]
       [(find-unit1 'oracle 25.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'pulsar-beam)))]
       [(find-unit1 'nydus-network 0.0)
        => (lambda ([nid : Integer]) (emit! (list 'cast-spell nid 'build-nydus-worm 148.0 162.0)))]
       [(find-unit1 'orbital-command 50.0)
        => (lambda ([oid : Integer]) (emit! (list 'cast-spell oid 'calldown-mule 1)))])]

    [(our-army-trapped-or-out-of-position base-trade-race)
     (cond
       [(find-unit1 'nexus 0.0)
        => (lambda ([nid : Integer]) (emit! (list 'cast-spell nid 'mass-recall 32.5 32.5)))]
       [(find-unit1 'mothership 0.0)
        => (lambda ([mid : Integer]) (emit! (list 'cast-spell mid 'mothership-mass-recall 88.0 88.0)))]
       [(find-unit1 'battlecruiser 0.0)
        => (lambda ([bcid : Integer]) (emit! (list 'cast-spell bcid 'tactical-jump 32.5 32.5)))]
       [(find-unit1 'stalker 0.0)
        => (lambda ([sid : Integer]) (emit! (list 'cast-spell sid 'blink 36.0 36.0)))]
       [(find-unit1 'nydus-network 0.0)
        => (lambda ([nid : Integer]) (emit! (list 'cast-spell nid 'build-nydus-worm 38.0 38.0)))])]

    [(late-game-spellcaster-standoff)
     (cond
       [(find-unit1 'ghost 75.0)
        => (lambda ([gid : Integer]) (emit! (list 'cast-spell gid 'emp-round 88.0 88.0)))]
       [(find-unit1 'high-templar 75.0)
        => (lambda ([hid : Integer])
             (emit! (list 'cast-spell hid 'psi-storm 88.0 88.0))
             (emit! (list 'cast-spell hid 'feedback 1)))]
       [(find-unit1 'nexus 50.0)
        => (lambda ([nid : Integer])
             (define ht (find-unit-any '(high-templar oracle sentry) 0.0))
             (when ht (emit! (list 'cast-spell nid 'nexus-energy-recharge ht))))]
       [(find-unit1 'viper 75.0)
        => (lambda ([vid : Integer]) (emit! (list 'cast-spell vid 'abduct 1)))]
       [(find-unit1 'infestor 75.0)
        => (lambda ([iid : Integer]) (emit! (list 'cast-spell iid 'fungal-growth 88.0 88.0)))])]

    [else
     (when (even? frame)
       (define qid (find-unit1 'queen 25.0))
       (when qid (emit! (list 'cast-spell qid 'spawn-creep-tumor 46.0 46.0))))])

  (reverse actions))

(: select-situational-ability-actions
   (->* (Symbol (Listof Symbol) (Listof Any))
        ((Listof Any) Integer)
        (Listof (Listof Any))))
(define (select-situational-ability-actions situation enemy-comp ally-units
                                            [ally-buildings '()] [frame 0])
  (define actor-ht : (HashTable Symbol (Listof actor-entry)) (make-hasheq))
  (define seq-after-units : Integer
    (let loop-au ([xs : (Listof Any) ally-units] [seq : Integer 0])
      (if (pair? xs)
          (let* ([u (car xs)]
                 [m (fast-unit-meta (dyn-unit-type u))]
                 [max-req (unit-type-meta-actor-max-energy m)])
            (when max-req
              (maybe-push-actor! actor-ht (unit-type-meta-canon-unit m) max-req seq u))
            (loop-au (cdr xs) (+ seq 1)))
          seq)))
  (let loop-ab ([xs : (Listof Any) ally-buildings] [seq : Integer seq-after-units])
    (when (pair? xs)
      (let* ([b (car xs)]
             [m (fast-unit-meta (dyn-unit-type b))]
             [max-req (unit-type-meta-actor-max-energy m)])
        (when max-req
          (maybe-push-actor! actor-ht (unit-type-meta-canon-unit m) max-req seq b))
        (loop-ab (cdr xs) (+ seq 1)))))
  (finalize-actor-ht! actor-ht)
  (select-ability-actions-from-ht situation enemy-comp actor-ht frame))

(: select-situational-upgrades
   (->* (Symbol Symbol (Listof Symbol) (Listof Symbol) (Listof Symbol))
        ((Listof Symbol) Nonnegative-Integer Nonnegative-Integer)
        (Listof Symbol)))
(define (select-situational-upgrades raw-race situation enemy-comp researched-upgs pending-upgs
                                     [available-bldgs '()] [minerals 0] [gas 0])
  (define race : Symbol (normalize-known-race raw-race))
  (define have-ht : (HashTable Symbol Symbol) (make-hasheq))
  (for ([p (in-list pending-upgs)])
    (hash-set! have-ht p 'pending))
  (for ([r (in-list researched-upgs)])
    (hash-set! have-ht r 'researched))
  (define have-bldgs? : Boolean (pair? available-bldgs))
  (define bldg-ht : (HashTable Symbol Boolean) (make-hasheq))
  (when have-bldgs?
    (for ([b (in-list available-bldgs)])
      (when (symbol? b)
        (hash-set! bldg-ht b #t))))

  (define race-upgrades : (Listof upgrade-catalog-entry)
    (case race
      [(Zerg) ZERG-UPGRADE-LIST]
      [(Terran) TERRAN-UPGRADE-LIST]
      [else PROTOSS-UPGRADE-LIST]))

  (define candidates : (Listof (Pairof Float upgrade-catalog-entry))
    (for/list : (Listof (Pairof Float upgrade-catalog-entry))
              ([u (in-list race-upgrades)]
               #:when (and (not (hash-ref have-ht (upgrade-catalog-entry-sym u) #f))
                           (let ([pre (upgrade-catalog-entry-prereq u)])
                             (or (not pre) (eq? (hash-ref have-ht pre #f) 'researched)))
                           (or (not have-bldgs?)
                               (let ([st (upgrade-catalog-entry-structure u)])
                                 (or (hash-ref bldg-ht st #f)
                                     (and (eq? st 'hatchery)
                                          (or (hash-ref bldg-ht 'lair #f) (hash-ref bldg-ht 'hive #f)))
                                     (and (eq? st 'spire)
                                          (hash-ref bldg-ht 'greater-spire #f))
                                     (and (eq? st 'templar-archive)
                                          (hash-ref bldg-ht 'templar-archives #f)))))))
      (define sit-hits : Integer
        (if (memq situation (upgrade-catalog-entry-situation-triggers u)) 1 0))
      (define trig-units : (Listof Symbol) (upgrade-catalog-entry-enemy-unit-triggers u))
      (define enemy-hits : Integer
        (if (null? enemy-comp)
            0
            (for/sum : Integer ([eu (in-list enemy-comp)])
              (if (memq eu trig-units) 1 0))))
      (define tier-bonus : Float
        (case (upgrade-catalog-entry-tier u)
          [(1) 6.0]
          [(2) 3.5]
          [else 1.5]))
      (define afford-bonus : Float
        (if (and (>= minerals (upgrade-catalog-entry-mineral-cost u))
                 (>= gas (upgrade-catalog-entry-gas-cost u)))
            2.5
            0.0))
      (define score : Float
        (+ (* 10.0 (->float sit-hits))
           (* 4.5 (->float enemy-hits))
           tier-bonus
           afford-bonus))
      (cons score u)))

  (define sorted
    (sort candidates
          (lambda ([a : (Pairof Float upgrade-catalog-entry)]
                   [b : (Pairof Float upgrade-catalog-entry)])
            (> (car a) (car b)))))

  (for/list : (Listof Symbol) ([p (in-list (take sorted (min 6 (length sorted))))])
    (upgrade-catalog-entry-sym (cdr p))))

;; -----------------------------------------------------------------------------
;; 6. Top-Level 16-Situation Operational Evaluator
;; -----------------------------------------------------------------------------

(: evaluate-situational-counter-plan
   (->* (Any) (Any Any (Option Integer)) situational-counter-plan))
(define (evaluate-situational-counter-plan raw-obs [raw-our-race 'Zerg] [raw-enemy-race 'Unknown] [frame-arg #f])
  (define-values
    (raw-our enemy-race-raw frame bx by ex ey
     ally-units ally-bldgs enemy-units enemy-bldgs
     researched-upgs pending-upgs
     our-workers est-enemy-workers enemy-bases
     wall-sealed? enemy-wall-count proxy-flag? trapped?
     gold-contest? base-threat-score raw-minerals raw-gas)
    (dyn-extract-plan-scalars raw-obs raw-our-race raw-enemy-race frame-arg))

  (define our-race : Symbol (normalize-known-race raw-our))
  (define minerals : Nonnegative-Integer (if (> raw-minerals 0) raw-minerals 0))
  (define gas : Nonnegative-Integer (if (> raw-gas 0) raw-gas 0))

  (define actor-ht : (HashTable Symbol (Listof actor-entry)) (make-hasheq))

  ;; Single pass over ally units: army count + situational-ability actor indexing
  (define-values (seq-after-units ally-army-count)
    (let loop-au : (Values Integer Integer)
                 ([xs : (Listof Any) ally-units]
                  [seq : Integer 0]
                  [army : Integer 0])
      (if (pair? xs)
          (let* ([u (car xs)]
                 [m (fast-unit-meta (dyn-unit-type u))]
                 [max-req (unit-type-meta-actor-max-energy m)])
            (when max-req
              (maybe-push-actor! actor-ht (unit-type-meta-canon-unit m) max-req seq u))
            (loop-au (cdr xs)
                     (+ seq 1)
                     (if (unit-type-meta-army? m) (+ army 1) army)))
          (values seq army))))

  ;; Single pass over ally buildings: canonical structure list + actor indexing
  (define ally-bldg-syms-rev : (Listof Symbol)
    (let loop-ab : (Listof Symbol)
                 ([xs : (Listof Any) ally-bldgs]
                  [seq : Integer seq-after-units]
                  [bldgs-rev : (Listof Symbol) '()])
      (if (pair? xs)
          (let* ([b (car xs)]
                 [m (fast-unit-meta (dyn-unit-type b))]
                 [cs (unit-type-meta-canon-struct m)]
                 [max-req (unit-type-meta-actor-max-energy m)])
            (when max-req
              (maybe-push-actor! actor-ht (unit-type-meta-canon-unit m) max-req seq b))
            (loop-ab (cdr xs)
                     (+ seq 1)
                     (if (memq cs bldgs-rev) bldgs-rev (cons cs bldgs-rev))))
          bldgs-rev)))

  (finalize-actor-ht! actor-ht)

  ;; Single pass over enemy units: composition, proximity, air, cloak/burrow, casters, siege, drops
  (define-values
    (enemy-army-count enemy-syms-rev0 last-c0
     enemy-near-home0 enemy-workers-near-home enemy-air-count
     enemy-cloak-burrow-count enemy-spellcaster-count
     enemy-sky-mech-count0 enemy-siege-lurker-count
     enemy-drop-runby-count enemy-followup-near?)
    (let loop-eu : (Values Integer (Listof Symbol) (Option Symbol)
                           Integer Integer Integer Integer Integer
                           Integer Integer Integer Boolean)
                 ([xs : (Listof Any) enemy-units]
                  [enemy-army : Integer 0]
                  [esyms-rev : (Listof Symbol) '()]
                  [last-c : (Option Symbol) #f]
                  [near-home : Integer 0]
                  [workers-near : Integer 0]
                  [air : Integer 0]
                  [cloak : Integer 0]
                  [caster : Integer 0]
                  [sky-mech : Integer 0]
                  [siege : Integer 0]
                  [drop-runby : Integer 0]
                  [followup-near? : Boolean #f])
      (if (pair? xs)
          (let* ([u (car xs)]
                 [m (fast-unit-meta (dyn-unit-type u))]
                 [c (unit-type-meta-canon-unit m)]
                 [next-esyms (if (or (eq? c last-c) (memq c esyms-rev)) esyms-rev (cons c esyms-rev))]
                 [d2 : Float (dyn-unit-dist2 u bx by 9999.0)]
                 [near-45? (<= d2 2025.0)]
                 [near-38? (and near-45? (<= d2 1444.0))]
                 [rmask : Fixnum (unit-type-meta-enemy-rmask m)]
                 [nz-rmask? (not (= 0 rmask))]
                 [cloak-hit? (or (and nz-rmask? (not (= 0 (bitwise-and rmask BIT-CLOAK-BURROW))))
                                 (dyn-unit-stealth? u))])
            (loop-eu
             (cdr xs)
             (if (unit-type-meta-army? m) (+ enemy-army 1) enemy-army)
             next-esyms
             c
             (if near-38? (+ near-home 1) near-home)
             (if (and near-38? (<= d2 1156.0) (unit-type-meta-worker? m)) (+ workers-near 1) workers-near)
             (if (unit-type-meta-flying? m) (+ air 1) air)
             (if cloak-hit? (+ cloak 1) cloak)
             (if (and nz-rmask? (not (= 0 (bitwise-and rmask BIT-CASTER)))) (+ caster 1) caster)
             (if (and nz-rmask? (not (= 0 (bitwise-and rmask BIT-SKY-MECH)))) (+ sky-mech 1) sky-mech)
             (if (and nz-rmask? (not (= 0 (bitwise-and rmask BIT-SIEGE-LURKER)))) (+ siege 1) siege)
             (if (and nz-rmask? (not (= 0 (bitwise-and rmask BIT-DROP-RUNBY)))) (+ drop-runby 1) drop-runby)
             (or followup-near? (and near-45? (unit-type-meta-followup? m)))))
          (values enemy-army esyms-rev last-c near-home workers-near air
                  cloak caster sky-mech siege drop-runby followup-near?))))

  ;; Single pass over enemy buildings: composition, sky/mech structures, proximity contain checks
  (define-values
    (enemy-syms-rev enemy-near-home enemy-static-near-home
     enemy-sky-mech-count enemy-contain-direct? enemy-pylon-near?)
    (let loop-eb : (Values (Listof Symbol) Integer Integer Integer Boolean Boolean)
                 ([xs : (Listof Any) enemy-bldgs]
                  [esyms-rev : (Listof Symbol) enemy-syms-rev0]
                  [last-c : (Option Symbol) last-c0]
                  [near-home : Integer enemy-near-home0]
                  [static-near : Integer 0]
                  [sky-mech : Integer enemy-sky-mech-count0]
                  [contain-direct? : Boolean #f]
                  [pylon-near? : Boolean #f])
      (if (pair? xs)
          (let* ([b (car xs)]
                 [m (fast-unit-meta (dyn-unit-type b))]
                 [c (unit-type-meta-canon-unit m)]
                 [next-esyms (if (or (eq? c last-c) (memq c esyms-rev)) esyms-rev (cons c esyms-rev))]
                 [rmask : Fixnum (unit-type-meta-enemy-rmask m)]
                 [d2 : Float (dyn-unit-dist2 b bx by 9999.0)]
                 [near-45? (<= d2 2025.0)]
                 [near-38? (and near-45? (<= d2 1444.0))]
                 [smask : Fixnum (if near-45? (unit-type-meta-enemy-smask m) 0)]
                 [nz-smask? (not (= 0 smask))])
            (loop-eb
             (cdr xs)
             next-esyms
             c
             (if near-38? (+ near-home 1) near-home)
             (if (and nz-smask? (<= d2 1764.0) (not (= 0 (bitwise-and smask BIT-STATIC-NEAR))))
                 (+ static-near 1)
                 static-near)
             (if (not (= 0 (bitwise-and rmask BIT-SKY-MECH))) (+ sky-mech 1) sky-mech)
             (or contain-direct? (and nz-smask? (not (= 0 (bitwise-and smask BIT-CONTAIN)))))
             (or pylon-near? (and near-45? (eq? (unit-type-meta-canon-struct m) 'pylon)))))
          (values esyms-rev near-home static-near sky-mech contain-direct? pylon-near?))))

  (define enemy-contain-near? : Boolean
    (or enemy-contain-direct? (and enemy-pylon-near? enemy-followup-near?)))

  (define enemy-syms : (Listof Symbol) (reverse enemy-syms-rev))
  (define ally-bldg-syms : (Listof Symbol) (reverse ally-bldg-syms-rev))

  (define proxy-detected? (or proxy-flag? (and (> enemy-static-near-home 0) (<= frame 4500))))
  (define base-trade? (and (>= base-threat-score 2) (> enemy-near-home 4) (>= ally-army-count 8)))

  ;; Score all 16 mid-level operational situations directly in local Float bindings
  (define s0 : Float (if (or (not wall-sealed?) (< enemy-wall-count 2)) (if (<= frame 4800) 78.0 42.0) 0.0))
  (define s1 : Float (if proxy-detected? (+ 68.0 (* 8.0 (->float enemy-static-near-home))) 0.0))
  (define s2 : Float (if (or (>= enemy-workers-near-home 3) (and (<= frame 3400) (> enemy-near-home 2)))
                         (+ 64.0 (* 10.0 (->float (+ enemy-workers-near-home enemy-near-home))))
                         0.0))
  (define s3 : Float
    (if enemy-contain-near?
        (+ 82.0 (* 10.0 (->float (+ enemy-static-near-home
                                    (if enemy-followup-near? 3 0)))))
        0.0))
  (define s4 : Float (if (> enemy-air-count 0) (+ 32.0 (* 12.0 (->float enemy-air-count))) 0.0))
  (define s5 : Float (if (> enemy-cloak-burrow-count 0) (+ 48.0 (* 14.0 (->float enemy-cloak-burrow-count))) 0.0))
  (define s6 : Float (if (> enemy-siege-lurker-count 0) (+ 45.0 (* 11.0 (->float enemy-siege-lurker-count))) 0.0))
  (define s7 : Float (if (>= enemy-drop-runby-count 2) (+ 36.0 (* 7.0 (->float enemy-drop-runby-count))) 0.0))
  (define s8 : Float (if (or (and (<= frame 6500) (>= enemy-bases 3)) (> est-enemy-workers (+ our-workers 8))) 66.0 0.0))
  (define s9 : Float (if (>= enemy-sky-mech-count 4) (+ 52.0 (* 6.0 (->float enemy-sky-mech-count))) 0.0))
  (define s10 : Float (if gold-contest? 58.0 0.0))
  (define s11 : Float (if trapped? 84.0 0.0))
  (define s12 : Float (if (and (>= ally-army-count 10)
                               (>= ally-army-count (exact-round (* 1.45 (max 4 enemy-army-count))))
                               (= enemy-near-home 0))
                          70.0
                          0.0))
  (define s13 : Float (if (< our-workers (- est-enemy-workers 6)) 60.0 0.0))
  (define s14 : Float (if (or (>= enemy-spellcaster-count 2) (and (>= frame 13000) (>= ally-army-count 20)))
                          (+ 44.0 (* 9.0 (->float enemy-spellcaster-count)))
                          0.0))
  (define s15 : Float (if base-trade? 82.0 0.0))

  ;; Push only > 15.0 scores in reverse ALL-OPERATIONAL-SITUATIONS order so stable sort preserves exact tie-breaking
  (define hot-hits : (Listof (Pairof Symbol Float)) '())
  (when (> s15 15.0) (set! hot-hits (cons (cons 'base-trade-race s15) hot-hits)))
  (when (> s14 15.0) (set! hot-hits (cons (cons 'late-game-spellcaster-standoff s14) hot-hits)))
  (when (> s13 15.0) (set! hot-hits (cons (cons 'our-eco-deficit-comeback-harass s13) hot-hits)))
  (when (> s12 15.0) (set! hot-hits (cons (cons 'our-snowball-finish-window s12) hot-hits)))
  (when (> s11 15.0) (set! hot-hits (cons (cons 'our-army-trapped-or-out-of-position s11) hot-hits)))
  (when (> s10 15.0) (set! hot-hits (cons (cons 'map-split-or-gold-base-contest s10) hot-hits)))
  (when (> s9  15.0) (set! hot-hits (cons (cons 'enemy-turtle-skytoss-or-mech s9) hot-hits)))
  (when (> s8  15.0) (set! hot-hits (cons (cons 'enemy-fast-3cc-or-nexus-greed s8) hot-hits)))
  (when (> s7  15.0) (set! hot-hits (cons (cons 'enemy-multi-prong-drop-or-runby s7) hot-hits)))
  (when (> s6  15.0) (set! hot-hits (cons (cons 'enemy-siege-or-lurker-contain s6) hot-hits)))
  (when (> s5  15.0) (set! hot-hits (cons (cons 'enemy-cloaked-or-burrowed-threat s5) hot-hits)))
  (when (> s4  15.0) (set! hot-hits (cons (cons 'enemy-air-harass-transition s4) hot-hits)))
  (when (> s3  15.0) (set! hot-hits (cons (cons 'enemy-cannon-or-bunker-contain s3) hot-hits)))
  (when (> s2  15.0) (set! hot-hits (cons (cons 'enemy-early-pool-or-worker-rush s2) hot-hits)))
  (when (> s1  15.0) (set! hot-hits (cons (cons 'opponent-proxy-all-in-defense s1) hot-hits)))
  (when (> s0  15.0) (set! hot-hits (cons (cons 'opponent-unwalled-punish s0) hot-hits)))

  (define sorted-hot : (Listof (Pairof Symbol Float))
    (if (and (pair? hot-hits) (pair? (cdr hot-hits)))
        (sort hot-hits
              (lambda ([a : (Pairof Symbol Float)] [b : (Pairof Symbol Float)])
                (> (cdr a) (cdr b))))
        hot-hits))

  (define primary-sit : Symbol
    (if (pair? sorted-hot)
        (caar sorted-hot)
        (if (eq? enemy-race-raw 'Random)
            'opponent-proxy-all-in-defense
            'enemy-fast-3cc-or-nexus-greed)))

  (define active-sits : (Listof Symbol)
    (if (pair? sorted-hot)
        (for/list : (Listof Symbol) ([p (in-list sorted-hot)])
          (car p))
        (list primary-sit)))

  (define imm-scores : (Immutable-HashTable Symbol Float)
    (ann (hasheq
          'opponent-unwalled-punish s0
          'opponent-proxy-all-in-defense s1
          'enemy-early-pool-or-worker-rush s2
          'enemy-cannon-or-bunker-contain s3
          'enemy-air-harass-transition s4
          'enemy-cloaked-or-burrowed-threat s5
          'enemy-siege-or-lurker-contain s6
          'enemy-multi-prong-drop-or-runby s7
          'enemy-fast-3cc-or-nexus-greed s8
          'enemy-turtle-skytoss-or-mech s9
          'map-split-or-gold-base-contest s10
          'our-army-trapped-or-out-of-position s11
          'our-snowball-finish-window s12
          'our-eco-deficit-comeback-harass s13
          'late-game-spellcaster-standoff s14
          'base-trade-race s15)
         (Immutable-HashTable Symbol Float)))

  ;; Collect race-matched unit counters & positioning responses in a single allocation-free memq pass
  (: push-unique-syms (-> (Listof Symbol) (Listof Symbol) (Listof Symbol)))
  (define (push-unique-syms items acc)
    (let loop ([xs items] [a acc])
      (if (pair? xs)
          (let ([s (car xs)])
            (loop (cdr xs) (if (memq s a) a (cons s a))))
          a)))
  (define-values (unit-counter-recs-rev0 pos-dirs-rev0)
    (let loop-es : (Values (Listof Symbol) (Listof Symbol))
                 ([es-xs : (Listof Symbol) enemy-syms]
                  [rec-acc : (Listof Symbol) '()]
                  [pos-acc : (Listof Symbol) '()])
      (if (pair? es-xs)
          (let ([ent (lookup-unit-counter-entry (car es-xs))])
            (if ent
                (let* ([recs (case our-race
                               [(Zerg) (unit-counter-entry-zerg-hard-counters ent)]
                               [(Terran) (unit-counter-entry-terran-hard-counters ent)]
                               [else (unit-counter-entry-protoss-hard-counters ent)])]
                       [pd (unit-counter-entry-positioning-response ent)])
                  (loop-es (cdr es-xs)
                           (push-unique-syms recs rec-acc)
                           (if (memq pd pos-acc) pos-acc (cons pd pos-acc))))
                (loop-es (cdr es-xs) rec-acc pos-acc)))
          (values rec-acc pos-acc))))
  ;; Printf Cannon-Rush & Proxy-Contain Follow-Up Directives across ZvP / TvP / PvP
  (define printf-contain? : Boolean
    (or (eq? primary-sit 'enemy-cannon-or-bunker-contain) enemy-contain-near?))
  (define unit-counter-recs : (Listof Symbol)
    (reverse
     (if printf-contain?
         (push-unique-syms
          (case our-race
            [(Zerg)    '(ravager spine-crawler nydus-canal queen hydralisk)]
            [(Terran)  '(siege-tank cyclone bunker scv-repair viking)]
            [else      '(stalker shield-battery immortal warp-prism tempest void-ray)])
          unit-counter-recs-rev0)
         unit-counter-recs-rev0)))
  (define pos-dirs : (Listof Symbol)
    (reverse
     (if printf-contain?
         (push-unique-syms
          (case our-race
            [(Zerg)    '(ravager-bile-walled-cannons spine-root-7.2-tiles reroute-expansion-to-third nydus-counter-main)]
            [(Terran)  '(high-ground-bunker-1.5t-from-cliff swap-bunker-builder-scv siege-tank-range-13-cyclone-lock-on scv-resume-cc)]
            [else      '(multi-probe-independent-chase corner-pre-block-probe abort-walled-cannon-pull stalker-battery-nexus-overcharge)])
          pos-dirs-rev0)
         pos-dirs-rev0)))

  (define upg-recs
    (select-situational-upgrades our-race primary-sit enemy-syms
                                 researched-upgs pending-upgs
                                 ally-bldg-syms minerals gas))

  (define ab-recs
    (select-ability-actions-from-ht primary-sit enemy-syms actor-ht frame))

  (define posture : Symbol
    (case primary-sit
      [(opponent-unwalled-punish our-snowball-finish-window) 'all-out-attack]
      [(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush enemy-cannon-or-bunker-contain) 'hold-and-defend]
      [(enemy-air-harass-transition enemy-cloaked-or-burrowed-threat enemy-multi-prong-drop-or-runby) 'split-defend-and-detect]
      [(enemy-fast-3cc-or-nexus-greed our-eco-deficit-comeback-harass) 'multi-prong-harass]
      [(enemy-siege-or-lurker-contain enemy-turtle-skytoss-or-mech late-game-spellcaster-standoff) 'tech-siege-and-poke]
      [(our-army-trapped-or-out-of-position) 'rescue-and-regroup]
      [(base-trade-race) 'base-race-recall-or-snipe]
      [else 'map-control-contest]))

  (define static-def : (Listof Symbol)
    (case our-race
      [(Zerg)
       (case primary-sit
         [(enemy-air-harass-transition enemy-cloaked-or-burrowed-threat) '(spore-crawler-mineral-lines queen-transfuse)]
         [(enemy-cannon-or-bunker-contain) '(spine-crawler-7.2-tiles spine-crawler-front ravager-corrosive-bile reroute-expansion-to-third nydus-worm-counter-main queen-block)]
         [(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush) '(spine-crawler-front queen-block)]
         [(our-eco-deficit-comeback-harass enemy-fast-3cc-or-nexus-greed) '(nydus-worm-backdoor spread-swarm-host)]
         [else '(creep-highway-control)])]
      [(Terran)
       (case primary-sit
         [(enemy-air-harass-transition enemy-cloaked-or-burrowed-threat) '(missile-turret-mineral-lines turret-tank-flank)]
         [(enemy-cannon-or-bunker-contain) '(high-ground-bunker-1.5t swap-bunker-builder-scv siege-tank-range-13 cyclone-lock-on scv-resume-cc scv-repair-3-6)]
         [(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush) '(bunker-ramp scv-repair-3-6 raise-depot)]
         [(map-split-or-gold-base-contest enemy-multi-prong-drop-or-runby) '(morph-planetary-fortress-outer scv-surround-repair)]
         [else '(bunker-salvage-if-idle)])]
      [else
       (case primary-sit
         [(enemy-air-harass-transition enemy-cloaked-or-burrowed-threat) '(photon-cannon-plus-shield-battery dual-pylon-redundancy)]
         [(enemy-cannon-or-bunker-contain) '(shield-battery-overcharge corner-hold-probe multi-probe-chase abort-walled-cannon-pull stalker-battery-contain)]
         [(opponent-proxy-all-in-defense enemy-early-pool-or-worker-rush) '(shield-battery-overcharge corner-hold-probe)]
         [else '(nexus-energy-recharge-casters nexus-recall-contingency)])]))

  (define base-dist2 : Float (+ (* (- bx ex) (- bx ex)) (* (- by ey) (- by ey))))
  (situational-counter-plan
   primary-sit
   active-sits
   imm-scores
   posture
   unit-counter-recs
   upg-recs
   ab-recs
   (if (null? pos-dirs) (list (if (< base-dist2 8100.0) 'hold-choke 'take-map-control)) pos-dirs)
   static-def
   (format "primary=~a active=~a posture=~a" primary-sit active-sits posture)))
