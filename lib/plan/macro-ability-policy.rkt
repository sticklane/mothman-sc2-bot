#lang racket/base

;; =============================================================================
;; `lib/plan/macro-ability-policy.rkt`
;; Pure Single-Source Leaf Policy Module for Macro Energy Abilities:
;;   1. Terran Orbital Command MULE (`171`) vs Scanner Sweep (`399`) energy floors,
;;      stealth hard-block, uphill-scan reserve, and safe mineral patch selection.
;;   2. Protoss Nexus Energy Recharge (`4126`) vs Chrono Boost (`3755`) arbitration
;;      and early 0:00-5:00 Probe-training Chrono Boost selection.
;;
;; Architectural Boundary (Phase 2):
;;   - Pure leaf policy module depending ONLY on Racket stdlib + `sc2-game-constants.rkt`.
;;   - ZERO imports of `sc2-protobuf-ws.rkt`, `bot-runtime.rkt`, or `priority-macro-brain.rkt`.
;;   - Both `sc2-protobuf-ws.rkt` (wire transport) and `bot-runtime.rkt` (Layer 2)
;;     construct lightweight transport-agnostic descriptor structs and delegate here.
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../sc2-game-constants.rkt")

(provide (struct-out macro-oc-info)
         (struct-out macro-nexus-info)
         (struct-out macro-caster-info)
         (struct-out macro-th-info)
         (struct-out macro-mineral-info)
         (struct-out macro-enemy-info)
         (struct-out macro-self-unit-info)
         (struct-out macro-policy-latch)
         (struct-out terran-mule-policy-result)
         (struct-out protoss-nexus-recharge-decision)
         make-macro-policy-latch
         reset-macro-policy-latch!
         reset-macro-policy-latch-for-new-match!
         evaluate-terran-mule-policy
         terran-oc-mule-allowed?
         SC2-MULE-HARMLESS-ENEMY-SYMS
         select-safe-mule-mineral-patch-tag
         evaluate-protoss-nexus-recharge-policy
         select-early-probe-chrono-pairs)

;; -----------------------------------------------------------------------------
;; 1. Lightweight Transport-Agnostic Descriptor Structs & Per-Match Latch
;; -----------------------------------------------------------------------------

(struct macro-oc-info
  (tag x y energy) #:transparent)

(struct macro-nexus-info
  (tag x y energy training-probe? chrono-buffed?) #:transparent)

(struct macro-caster-info
  (tag sym x y energy hallucination?) #:transparent)

(struct macro-th-info
  (tag sym x y completed? flying?) #:transparent)

(struct macro-mineral-info
  (tag x y contents visible?) #:transparent)

(struct macro-enemy-info
  (sym type-id x y z cloak burrowed? flying?) #:transparent)

(struct macro-self-unit-info
  (sym type-id x y z structure? worker? completed?) #:transparent)

(struct macro-policy-latch
  ([observed-enemy-race      #:mutable]   ;; #f | 'Zerg | 'Terran | 'Protoss
   [seen-terran-cloak-tech?  #:mutable]   ;; Boolean
   [seen-protoss-dt-prism?   #:mutable]   ;; Boolean
   [seen-enemy-cloak?        #:mutable]   ;; Boolean
   [last-blind-uphill-loop   #:mutable])  ;; Integer (default -9999)
  #:transparent)

(define (make-macro-policy-latch)
  (macro-policy-latch #f #f #f #f -9999))

(define (reset-macro-policy-latch! latch)
  (when (macro-policy-latch? latch)
    (set-macro-policy-latch-observed-enemy-race! latch #f)
    (set-macro-policy-latch-seen-terran-cloak-tech?! latch #f)
    (set-macro-policy-latch-seen-protoss-dt-prism?! latch #f)
    (set-macro-policy-latch-seen-enemy-cloak?! latch #f)
    (set-macro-policy-latch-last-blind-uphill-loop! latch -9999))
  (void))

(define (reset-macro-policy-latch-for-new-match! latch)
  (reset-macro-policy-latch! latch))

(struct terran-mule-policy-result
  (hard-blocked?              ;; Boolean: #t when active uncovered cloak/burrow <= 32t of self
   uphill-scan-reserve?       ;; Boolean: #t when 150e floor applies (Arena, recent 83 err, explicit scan, unspotted uphill tank)
   proactive-scan-oc-tags     ;; (Listof Integer): top-K OC tags reserving Scan energy
   proactive-scan-floor       ;; Flonum: 100.0 (normal) or 101.0 (DT/Prism 2-OC or isolated Arena reserve)
   oc-energy-floor-ht)        ;; (HashTable Integer Flonum): oc-tag -> required min energy to drop MULE
  #:transparent)

(struct protoss-nexus-recharge-decision
  (cast-nexus-tag             ;; #f | Integer (Nexus tag casting 4126 this tick)
   cast-target-tag            ;; #f | Integer (dry caster tag receiving 4126)
   hold-nexus-tags)           ;; (Seteqv Integer): Nexus tags holding 50..99e for approaching caster <= 14t
  #:transparent)

;; -----------------------------------------------------------------------------
;; 2. Internal Geometry & Classification Helpers
;; -----------------------------------------------------------------------------

(define (dist2d x1 y1 x2 y2)
  (define dx (- (exact->inexact x1) (exact->inexact x2)))
  (define dy (- (exact->inexact y1) (exact->inexact y2)))
  (sqrt (+ (* dx dx) (* dy dy))))

(define TERRAN-ENEMY-IDS
  (seteqv 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44
          45 46 47 48 49 50 51 52 53 54 55 56 57 130 132 134 268 484 498 500 689 691 692 734))

(define PROTOSS-ENEMY-IDS
  (seteqv 4 10 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85
          133 136 141 311 488 495 496 694 733 1910 1911))

(define ZERG-ENEMY-IDS
  (seteqv 9 12 13 14 15 16 17 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105
          106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126
          127 128 129 137 138 139 140 142 151 493 494 499 502 503 504 687 688 690 732 892 893 894 1912))

(define TERRAN-ENEMY-SYMS
  (seteq 'command-center 'command-center-flying 'orbital-command 'orbital-command-flying
         'planetary-fortress 'supply-depot 'supply-depot-lowered 'refinery 'barracks 'barracks-flying
         'barracks-techlab 'barracks-reactor 'engineering-bay 'missile-turret 'bunker 'sensor-tower
         'ghost-academy 'factory 'factory-flying 'factory-techlab 'factory-reactor 'starport
         'starport-flying 'starport-techlab 'starport-reactor 'armory 'fusion-core 'scv 'mule
         'marine 'marauder 'reaper 'ghost 'hellion 'hellbat 'hellion-tank 'widow-mine
         'widow-mine-burrowed 'cyclone 'siege-tank 'siege-tank-sieged 'thor 'thor-ap 'medivac
         'viking 'viking-fighter 'viking-assault 'liberator 'liberator-ag 'banshee 'raven
         'battlecruiser 'auto-turret))

(define PROTOSS-ENEMY-SYMS
  (seteq 'nexus 'pylon 'assimilator 'gateway 'warp-gate 'forge 'cybernetics-core 'photon-cannon
         'shield-battery 'robotics-facility 'robotics-bay 'stargate 'fleet-beacon 'twilight-council
         'templar-archive 'dark-shrine 'probe 'zealot 'stalker 'sentry 'adept 'high-templar
         'dark-templar 'archon 'observer 'observer-siege-mode 'warp-prism 'warp-prism-phasing
         'immortal 'colossus 'disruptor 'phoenix 'oracle 'void-ray 'carrier 'tempest 'mothership))

(define ZERG-ENEMY-SYMS
  (seteq 'hatchery 'lair 'hive 'extractor 'spawning-pool 'evolution-chamber 'roach-warren
         'baneling-nest 'spine-crawler 'spore-crawler 'hydralisk-den 'lurker-den 'lurker-den-mp
         'infestation-pit 'spire 'greater-spire 'ultralisk-cavern 'nydus-network 'nydus-canal
         'creep-tumor 'creep-tumor-burrowed 'creep-tumor-queen 'drone 'overlord 'overseer
         'overseer-siege-mode 'overlord-transport 'queen 'zergling 'baneling 'roach 'ravager
         'hydralisk 'lurker 'lurker-mp 'lurker-burrowed 'lurker-mp-burrowed 'infestor 'swarm-host
         'mutalisk 'corruptor 'viper 'ultralisk 'brood-lord 'changeling 'changeling-zealot
         'changeling-marine 'changeling-marine-shield 'changeling-zergling 'changeling-zergling-wings))

(define (infer-enemy-race-from-infos enemy-units)
  (for/first ([e (in-list enemy-units)]
              #:when (macro-enemy-info? e)
              #:do [(define tid (macro-enemy-info-type-id e))
                    (define sym (macro-enemy-info-sym e))
                    (define r
                      (cond
                        [(or (and (exact-integer? tid) (set-member? PROTOSS-ENEMY-IDS tid))
                             (and (symbol? sym) (set-member? PROTOSS-ENEMY-SYMS sym)))
                         'Protoss]
                        [(or (and (exact-integer? tid) (set-member? TERRAN-ENEMY-IDS tid))
                             (and (symbol? sym) (set-member? TERRAN-ENEMY-SYMS sym)))
                         'Terran]
                        [(or (and (exact-integer? tid) (set-member? ZERG-ENEMY-IDS tid))
                             (and (symbol? sym) (set-member? ZERG-ENEMY-SYMS sym)))
                         'Zerg]
                        [else #f]))]
              #:when r)
    r))

(define NON-COMBAT-SELF-IDS
  (seteqv 12 13 14 15 16 17 82 103 106 129 151 268 1911 1912))

(define NON-COMBAT-SELF-SYMS
  (seteq 'changeling 'changeling-zealot 'changeling-marine-shield 'changeling-marine
         'changeling-zergling-wings 'changeling-zergling 'observer 'observer-siege-mode
         'egg 'overlord 'overseer 'overseer-siege-mode 'larva 'mule))

(define MACRO-INFRA-SELF-IDS
  (seteqv 19 20 21 27 28 47))

(define MACRO-INFRA-SELF-SYMS
  (seteq 'supply-depot 'supply-depot-lowered 'refinery 'barracks 'barracks-flying
         'factory 'factory-flying 'starport 'starport-flying))

(define TERRAN-CLOAK-TECH-ENEMY-IDS
  (seteqv 41 26 50 55))

(define TERRAN-CLOAK-TECH-ENEMY-SYMS
  (seteq 'starport-techlab 'starport-tech-lab 'ghost-academy 'ghost 'banshee))

(define PROTOSS-DT-PRISM-ENEMY-IDS
  (seteqv 69 76 81 136))

(define PROTOSS-DT-PRISM-ENEMY-SYMS
  (seteq 'dark-shrine 'dark-templar 'warp-prism 'warp-prism-phasing))

(define CLOAK-THREAT-EXCLUDED-ENEMY-IDS
  (seteqv 87 137 138))

(define CLOAK-THREAT-EXCLUDED-ENEMY-SYMS
  (seteq 'creep-tumor 'creep-tumor-burrowed 'creep-tumor-queen))

(define CLOAK-THREAT-UNIT-ENEMY-IDS
  (seteqv 50 55 69 76 498 500 502 503 504))

(define CLOAK-THREAT-UNIT-ENEMY-SYMS
  (seteq 'ghost 'banshee 'dark-shrine 'dark-templar 'widow-mine 'widow-mine-burrowed
         'lurker 'lurker-mp 'lurker-burrowed 'lurker-mp-burrowed))

(define UNCOVERED-CLOAK-EXCLUDED-IDS
  (seteqv 137 138 732))

(define UNCOVERED-CLOAK-EXCLUDED-SYMS
  (seteq 'creep-tumor-burrowed 'creep-tumor-queen 'lurker-egg 'lurker-mp-egg))

(define AIR-SPOTTER-SELF-IDS
  (seteqv 35 54 55 56 57 689 692))

(define AIR-SPOTTER-SELF-SYMS
  (seteq 'viking 'viking-fighter 'medivac 'banshee 'raven 'battlecruiser 'liberator 'liberator-ag))

;; -----------------------------------------------------------------------------
;; 3. Terran Orbital Command MULE vs Scanner Sweep Policy
;; -----------------------------------------------------------------------------

(define (evaluate-terran-mule-policy
         #:latch latch
         #:loop cur-loop
         #:ready-ocs ready-ocs
         #:self-units self-units
         #:enemy-units enemy-units
         #:townhalls townhalls
         #:worker-count worker-count
         #:known-enemy-race [known-enemy-race #f]
         #:step-has-scan-request? [step-has-scan-request? #f]
         #:blind-uphill-err-now? [blind-uphill-err-now? #f])
  (define seen-enemy-race-now (infer-enemy-race-from-infos enemy-units))
  (when (and (macro-policy-latch? latch) seen-enemy-race-now)
    (set-macro-policy-latch-observed-enemy-race! latch seen-enemy-race-now))
  (define seen-terran-cloak-tech-now?
    (ormap (lambda (e)
             (and (macro-enemy-info? e)
                  (or (and (exact-integer? (macro-enemy-info-type-id e))
                           (set-member? TERRAN-CLOAK-TECH-ENEMY-IDS (macro-enemy-info-type-id e)))
                      (and (symbol? (macro-enemy-info-sym e))
                           (set-member? TERRAN-CLOAK-TECH-ENEMY-SYMS (macro-enemy-info-sym e))))))
           enemy-units))
  (when (and (macro-policy-latch? latch) seen-terran-cloak-tech-now?)
    (set-macro-policy-latch-seen-terran-cloak-tech?! latch #t))
  (define seen-protoss-dt-prism-now?
    (ormap (lambda (e)
             (and (macro-enemy-info? e)
                  (or (and (exact-integer? (macro-enemy-info-type-id e))
                           (set-member? PROTOSS-DT-PRISM-ENEMY-IDS (macro-enemy-info-type-id e)))
                      (and (symbol? (macro-enemy-info-sym e))
                           (set-member? PROTOSS-DT-PRISM-ENEMY-SYMS (macro-enemy-info-sym e))))))
           enemy-units))
  (when (and (macro-policy-latch? latch) seen-protoss-dt-prism-now?)
    (set-macro-policy-latch-seen-protoss-dt-prism?! latch #t))
  (define eff-enemy-race
    (or seen-enemy-race-now
        (and (memq known-enemy-race '(Zerg Terran Protoss)) known-enemy-race)
        (and (macro-policy-latch? latch) (macro-policy-latch-observed-enemy-race latch))
        known-enemy-race))
  (define enemy-cloak-threat-now?
    (ormap (lambda (e)
             (and (macro-enemy-info? e)
                  (let ([tid (macro-enemy-info-type-id e)]
                        [sym (macro-enemy-info-sym e)])
                    (and (not (or (and (exact-integer? tid)
                                       (set-member? CLOAK-THREAT-EXCLUDED-ENEMY-IDS tid))
                                  (and (symbol? sym)
                                       (set-member? CLOAK-THREAT-EXCLUDED-ENEMY-SYMS sym))))
                         (or (memv (macro-enemy-info-cloak e) '(1 2))
                             (macro-enemy-info-burrowed? e)
                             (and (exact-integer? tid)
                                  (set-member? CLOAK-THREAT-UNIT-ENEMY-IDS tid))
                             (and (symbol? sym)
                                  (set-member? CLOAK-THREAT-UNIT-ENEMY-SYMS sym)))))))
           enemy-units))
  (when (and (macro-policy-latch? latch) enemy-cloak-threat-now?)
    (set-macro-policy-latch-seen-enemy-cloak?! latch #t))
  (define seen-dt-prism-latched?
    (or seen-protoss-dt-prism-now?
        (and (macro-policy-latch? latch) (macro-policy-latch-seen-protoss-dt-prism? latch))))
  (define seen-terran-cloak-latched?
    (or seen-terran-cloak-tech-now?
        (and (macro-policy-latch? latch) (macro-policy-latch-seen-terran-cloak-tech? latch))))
  (define seen-enemy-cloak-latched?
    (or enemy-cloak-threat-now?
        (and (macro-policy-latch? latch) (macro-policy-latch-seen-enemy-cloak? latch))))
  (define has-raven-now?
    (ormap (lambda (u)
             (and (macro-self-unit-info? u)
                  (or (equal? (macro-self-unit-info-type-id u) 56)
                      (eq? (macro-self-unit-info-sym u) 'raven))))
           self-units))
  (define has-ready-turret-now?
    (ormap (lambda (u)
             (and (macro-self-unit-info? u)
                  (macro-self-unit-info-completed? u)
                  (or (equal? (macro-self-unit-info-type-id u) 23)
                      (eq? (macro-self-unit-info-sym u) 'missile-turret))))
           self-units))
  (define friendly-combat-cnt
    (count (lambda (u)
             (and (macro-self-unit-info? u)
                  (not (macro-self-unit-info-structure? u))
                  (not (macro-self-unit-info-worker? u))
                  (not (and (exact-integer? (macro-self-unit-info-type-id u))
                            (set-member? NON-COMBAT-SELF-IDS (macro-self-unit-info-type-id u))))
                  (not (and (symbol? (macro-self-unit-info-sym u))
                            (set-member? NON-COMBAT-SELF-SYMS (macro-self-unit-info-sym u))))))
           self-units))
  (define isolated-arena-skirmish?
    (and (<= worker-count 8)
         (not (ormap (lambda (u)
                       (and (macro-self-unit-info? u)
                            (or (and (exact-integer? (macro-self-unit-info-type-id u))
                                     (set-member? MACRO-INFRA-SELF-IDS (macro-self-unit-info-type-id u)))
                                (and (symbol? (macro-self-unit-info-sym u))
                                     (set-member? MACRO-INFRA-SELF-SYMS (macro-self-unit-info-sym u))))))
                     self-units))))
  (define proactive-scan-oc-limit
    (cond
      [(and (memq eff-enemy-race '(Protoss Random))
            seen-dt-prism-latched?)
       (if (>= (length ready-ocs) 2) 2 1)]
      [(and (>= cur-loop 5376)
            (memq eff-enemy-race '(Protoss Random)))
       (if (>= (length ready-ocs) 3) 2 1)]
      [(or seen-enemy-cloak-latched?
           (and isolated-arena-skirmish?
                (>= friendly-combat-cnt 6)))
       1]
      [(and (eq? eff-enemy-race 'Terran)
            seen-terran-cloak-latched?)
       1]
      [else 0]))
  (define proactive-scan-oc-tags
    (if (and (> proactive-scan-oc-limit 0)
             (not has-raven-now?)
             (not has-ready-turret-now?)
             (pair? ready-ocs))
        (let* ([sorted-ocs
                (sort ready-ocs
                      (lambda (a b)
                        (let ([ea (exact->inexact (macro-oc-info-energy a))]
                              [eb (exact->inexact (macro-oc-info-energy b))])
                          (if (= ea eb)
                              (< (macro-oc-info-tag a) (macro-oc-info-tag b))
                              (> ea eb)))))]
               [take-n (min proactive-scan-oc-limit (length sorted-ocs))])
          (map macro-oc-info-tag (take sorted-ocs take-n)))
        '()))
  (define proactive-scan-floor
    (if (or (and isolated-arena-skirmish? (>= friendly-combat-cnt 6))
            (and (memq eff-enemy-race '(Protoss Random)) seen-dt-prism-latched?))
        101.0
        100.0))
  ;; Active uncovered cloaked (cloak=1) or burrowed combat enemy within 32.0t of any friendly unit
  (define hard-blocked?
    (and (ormap (lambda (e)
                  (and (macro-enemy-info? e)
                       (or (equal? (macro-enemy-info-cloak e) 1)
                           (macro-enemy-info-burrowed? e))
                       (not (or (and (exact-integer? (macro-enemy-info-type-id e))
                                     (set-member? UNCOVERED-CLOAK-EXCLUDED-IDS (macro-enemy-info-type-id e)))
                                (and (symbol? (macro-enemy-info-sym e))
                                     (set-member? UNCOVERED-CLOAK-EXCLUDED-SYMS (macro-enemy-info-sym e)))))
                       (let ([ex (macro-enemy-info-x e)]
                             [ey (macro-enemy-info-y e)])
                         (ormap (lambda (u)
                                  (and (macro-self-unit-info? u)
                                       (<= (dist2d ex ey (macro-self-unit-info-x u) (macro-self-unit-info-y u))
                                           32.0)))
                                self-units))))
                enemy-units)
         #t))
  ;; Uphill-Scan 150.0e reserve
  (when (and (macro-policy-latch? latch) blind-uphill-err-now?)
    (set-macro-policy-latch-last-blind-uphill-loop! latch cur-loop))
  (define recent-blind-uphill-err?
    (or blind-uphill-err-now?
        (and (macro-policy-latch? latch)
             (>= (macro-policy-latch-last-blind-uphill-loop latch) 0)
             (<= (- cur-loop (macro-policy-latch-last-blind-uphill-loop latch)) 44))))
  (define air-spotters
    (filter (lambda (u)
              (and (macro-self-unit-info? u)
                   (or (and (exact-integer? (macro-self-unit-info-type-id u))
                            (set-member? AIR-SPOTTER-SELF-IDS (macro-self-unit-info-type-id u)))
                       (and (symbol? (macro-self-unit-info-sym u))
                            (set-member? AIR-SPOTTER-SELF-SYMS (macro-self-unit-info-sym u))))))
            self-units))
  (define sieged-tanks
    (filter (lambda (u)
              (and (macro-self-unit-info? u)
                   (or (equal? (macro-self-unit-info-type-id u) 32)
                       (eq? (macro-self-unit-info-sym u) 'siege-tank-sieged))))
            self-units))
  (define sieged-tank-uphill-needs-scan?
    (and (pair? sieged-tanks)
         (pair? enemy-units)
         (ormap (lambda (tk)
                  (define tx (macro-self-unit-info-x tk))
                  (define ty (macro-self-unit-info-y tk))
                  (define tz (exact->inexact (macro-self-unit-info-z tk)))
                  (and (not (ormap (lambda (sp)
                                     (<= (dist2d tx ty (macro-self-unit-info-x sp) (macro-self-unit-info-y sp))
                                         16.0))
                                   air-spotters))
                       (ormap (lambda (e)
                                (and (macro-enemy-info? e)
                                     (not (macro-enemy-info-flying? e))
                                     (>= (- (exact->inexact (macro-enemy-info-z e)) tz) 1.5)
                                     (<= (dist2d tx ty (macro-enemy-info-x e) (macro-enemy-info-y e))
                                         15.0)))
                              enemy-units)))
                sieged-tanks)))
  (define isolated-arena-scan-clash?
    (or (null? townhalls)
        (and (= (length townhalls) 1)
             (<= worker-count 0)
             (not (ormap macro-self-unit-info-worker? self-units))
             (pair? sieged-tanks)
             (null? air-spotters))))
  (define uphill-scan-reserve?
    (and (or step-has-scan-request?
             recent-blind-uphill-err?
             sieged-tank-uphill-needs-scan?
             isolated-arena-scan-clash?)
         #t))
  (define oc-energy-floor-ht
    (for/hasheqv ([oc (in-list ready-ocs)]
                  #:when (macro-oc-info? oc))
      (define tag (macro-oc-info-tag oc))
      (define floor-val
        (cond
          [uphill-scan-reserve? 150.0]
          [(and (pair? proactive-scan-oc-tags)
                (memv tag proactive-scan-oc-tags))
           proactive-scan-floor]
          [(and enemy-cloak-threat-now?
                (not has-raven-now?)
                (not has-ready-turret-now?))
           100.0]
          [else 50.0]))
      (values tag floor-val)))
  (terran-mule-policy-result
   hard-blocked?
   uphill-scan-reserve?
   proactive-scan-oc-tags
   proactive-scan-floor
   oc-energy-floor-ht))

(define (terran-oc-mule-allowed? policy oc-tag oc-energy)
  (and (terran-mule-policy-result? policy)
       (not (terran-mule-policy-result-hard-blocked? policy))
       (>= (exact->inexact oc-energy)
           (hash-ref (terran-mule-policy-result-oc-energy-floor-ht policy)
                     oc-tag
                     (if (terran-mule-policy-result-uphill-scan-reserve? policy)
                         150.0
                         50.0)))))

;; -----------------------------------------------------------------------------
;; 4. Safe MULE Mineral Patch Selector
;; -----------------------------------------------------------------------------

(define SC2-MULE-HARMLESS-ENEMY-SYMS
  (seteq 'drone 'scv 'probe 'overlord 'overlord-cocoon
         'overseer 'overseer-siege-mode 'observer 'observer-siege-mode
         'changeling 'changeling-zealot 'changeling-marine-shield
         'changeling-marine 'changeling-zergling-wings 'changeling-zergling))

(define SC2-MULE-HARMLESS-ENEMY-IDS
  (seteqv 12 13 14 15 16 17 45 82 84 104 106 107 129 1911 1912))

(define (select-safe-mule-mineral-patch-tag ref-x ref-y townhalls mineral-fields enemy-units)
  (define completed-grounded-ths
    (filter (lambda (th)
              (and (macro-th-info? th)
                   (macro-th-info-completed? th)
                   (not (macro-th-info-flying? th))
                   (not (memq (macro-th-info-sym th)
                              '(command-center-flying orbital-command-flying)))))
            townhalls))
  (cond
    [(or (null? completed-grounded-ths) (null? mineral-fields)) 0]
    [else
     (define danger-xys
       (for/list ([e (in-list enemy-units)]
                  #:when (and (macro-enemy-info? e)
                              (let ([sym (macro-enemy-info-sym e)]
                                    [tid (macro-enemy-info-type-id e)])
                                (not (or (and (symbol? sym)
                                              (set-member? SC2-MULE-HARMLESS-ENEMY-SYMS sym))
                                         (and (not (symbol? sym))
                                              (exact-integer? tid)
                                              (set-member? SC2-MULE-HARMLESS-ENEMY-IDS tid)))))))
         (cons (exact->inexact (macro-enemy-info-x e))
               (exact->inexact (macro-enemy-info-y e)))))
     (define safe-ths
       (filter (lambda (th)
                 (define tx (exact->inexact (macro-th-info-x th)))
                 (define ty (exact->inexact (macro-th-info-y th)))
                 (for/and ([exy (in-list danger-xys)])
                   (define dx (- tx (car exy)))
                   (define dy (- ty (cdr exy)))
                   (or (> (abs dx) 12.5)
                       (> (abs dy) 12.5)
                       (> (+ (* dx dx) (* dy dy)) 156.25))))
               completed-grounded-ths))
     (cond
       [(null? safe-ths) 0]
       [else
        (define safe-th-xys
          (for/list ([th (in-list safe-ths)])
            (cons (exact->inexact (macro-th-info-x th))
                  (exact->inexact (macro-th-info-y th)))))
        (define fallback-th
          (or (findf (lambda (th) (eq? (macro-th-info-sym th) 'orbital-command)) safe-ths)
              (first safe-ths)))
        (define rx (exact->inexact (if (real? ref-x) ref-x (macro-th-info-x fallback-th))))
        (define ry (exact->inexact (if (real? ref-y) ref-y (macro-th-info-y fallback-th))))
        (define best-tag 0)
        (define best-score +inf.0)
        (for ([m (in-list mineral-fields)]
              #:when (and (macro-mineral-info? m)
                          (macro-mineral-info-visible? m)
                          (let ([mc (macro-mineral-info-contents m)])
                            (or (= mc 0) (>= mc 150)))))
          (define mx (exact->inexact (macro-mineral-info-x m)))
          (define my (exact->inexact (macro-mineral-info-y m)))
          (when (and (for/or ([txy (in-list safe-th-xys)])
                       (define dx (- mx (car txy)))
                       (define dy (- my (cdr txy)))
                       (and (<= (abs dx) 12.0)
                            (<= (abs dy) 12.0)
                            (<= (+ (* dx dx) (* dy dy)) 144.0)))
                     (for/and ([exy (in-list danger-xys)])
                       (define dx (- mx (car exy)))
                       (define dy (- my (cdr exy)))
                       (or (> (abs dx) 11.0)
                           (> (abs dy) 11.0)
                           (> (+ (* dx dx) (* dy dy)) 121.0))))
            (define mc (macro-mineral-info-contents m))
            (define sc (- (* 0.35 (dist2d rx ry mx my))
                          (* 0.002 (if (= mc 0) 1500 mc))))
            (when (< sc best-score)
              (set! best-score sc)
              (set! best-tag (macro-mineral-info-tag m)))))
        best-tag])]))

;; -----------------------------------------------------------------------------
;; 5. Protoss Nexus Energy Recharge (`4126`) vs Chrono Boost (`3755`) Policy
;; -----------------------------------------------------------------------------

(define (caster-dry-for-recharge? c)
  (and (macro-caster-info? c)
       (not (macro-caster-info-hallucination? c))
       (let ([sym (macro-caster-info-sym c)]
             [en (exact->inexact (macro-caster-info-energy c))])
         ;; L63B (`#1752` Bug #2A): Any Protoss spellcaster (`high-templar`/`oracle`/`sentry`/`mothership`)
         ;; below `100.0e` (< 50% max energy) is eligible for Nexus Energy Recharge (`4126`).
         (and (memq sym '(high-templar oracle sentry mothership))
              (< en 100.0)))))

(define (caster-recharge-priority sym)
  (case sym
    [(high-templar) 3]
    [(oracle mothership) 2]
    [else           1]))

(define (evaluate-protoss-nexus-recharge-policy
         #:ready-nexuses ready-nexuses
         #:ally-casters ally-casters
         #:enemy-units-present? enemy-units-present?
         #:recharge-available? recharge-available?
         #:recharge-off-cooldown? recharge-off-cooldown?
         #:cast-range [cast-range (sc2-spell-cast-range 'nexus-energy-recharge 14.5)]
         #:approach-hold-range [approach-hold-range (+ (exact->inexact cast-range) 4.0)])
  (define eff-cast-range (exact->inexact cast-range))
  (define eff-hold-range (max eff-cast-range (exact->inexact approach-hold-range)))
  ;; L63B (`#1752` Bug #2A): Always scan up to `eff-hold-range` (`<= 22.0t`) BOTH in combat
  ;; and out of combat (`enemy-units-present? = #f`) so `hold-nexus-tags` preserves `50..99e`
  ;; Nexus energy while a dry caster approaches; always prefer any in-range (`<= eff-cast-range`)
  ;; dry caster for immediate `4126` emission!
  (cond
    [(or (not recharge-available?)
         (not recharge-off-cooldown?)
         (null? ready-nexuses)
         (null? ally-casters))
     (protoss-nexus-recharge-decision #f #f (seteqv))]
    [else
     (define dry-casters (filter caster-dry-for-recharge? ally-casters))
     (cond
       [(null? dry-casters)
        (protoss-nexus-recharge-decision #f #f (seteqv))]
       [else
        (define cast-nx-tag #f)
        (define cast-tgt-tag #f)
        (define hold-tags (mutable-seteqv))
        (for ([nx (in-list ready-nexuses)]
              #:when (and (macro-nexus-info? nx)
                          (exact-integer? (macro-nexus-info-tag nx))
                          (> (macro-nexus-info-tag nx) 0)
                          (>= (exact->inexact (macro-nexus-info-energy nx)) 50.0)))
          (define nx-tag (macro-nexus-info-tag nx))
          (define nx-en (exact->inexact (macro-nexus-info-energy nx)))
          (define nxx (macro-nexus-info-x nx))
          (define nxy (macro-nexus-info-y nx))
          (define-values (best-cast-c _cast-prio _cast-d any-hold?)
            (for/fold ([bc #f] [bp -1] [bd +inf.0] [hold? #f]) ([c (in-list dry-casters)])
              (define d (dist2d nxx nxy (macro-caster-info-x c) (macro-caster-info-y c)))
              (cond
                [(<= d eff-cast-range)
                 (let ([p (caster-recharge-priority (macro-caster-info-sym c))])
                   (if (or (> p bp) (and (= p bp) (< d bd)))
                       (values c p d #t)
                       (values bc bp bd #t)))]
                [(<= d eff-hold-range)
                 (values bc bp bd #t)]
                [else
                 (values bc bp bd hold?)])))
          (cond
            [(and (not cast-nx-tag)
                  best-cast-c
                  (exact-integer? (macro-caster-info-tag best-cast-c))
                  (> (macro-caster-info-tag best-cast-c) 0))
             (set! cast-nx-tag nx-tag)
             (set! cast-tgt-tag (macro-caster-info-tag best-cast-c))]
            [(and (not cast-nx-tag) any-hold? (< nx-en 100.0))
             (set-add! hold-tags nx-tag)]))
        (protoss-nexus-recharge-decision
         cast-nx-tag
         cast-tgt-tag
         (for/seteqv ([t (in-set hold-tags)]) t))])]))

(define EARLY-CHRONO-RECHARGE-YIELD-CASTER-SYMS
  (seteq 'high-templar 'sentry 'oracle 'mothership))

(define (select-early-probe-chrono-pairs
         #:loop cur-loop
         #:worker-count worker-count
         #:ready-nexuses ready-nexuses
         #:ally-casters ally-casters
         #:enemy-units-present? enemy-units-present?
         #:recharge-available? recharge-available?
         #:recharge-off-cooldown? [recharge-off-cooldown? #t]
         #:caster-ready? caster-ready?
         #:target-ready? target-ready?)
  (cond
    [(or (>= cur-loop 6720)
         (>= worker-count 50)
         (null? ready-nexuses))
     '()]
    [else
     ;; L63B (`#1752` Bug #2A): Widen `Sec 6b` Probe Chrono yield radius to `20.0t` and gate
     ;; yield on `recharge-off-cooldown?` so Probe Chrono yields `50..99e` ONLY when Recharge is
     ;; actually off cooldown and a dry caster (`< 100.0e`) is within `20.0t`!
     (define eff-yield-range
       (max 20.0 (exact->inexact (sc2-spell-cast-range 'nexus-energy-recharge 14.5))))
     (define (low-energy-caster-near-nexus? nx)
       (and recharge-available?
            recharge-off-cooldown?
            (< (exact->inexact (macro-nexus-info-energy nx)) 100.0)
            (ormap (lambda (c)
                     (and (caster-dry-for-recharge? c)
                          (<= (dist2d (macro-nexus-info-x nx) (macro-nexus-info-y nx)
                                      (macro-caster-info-x c) (macro-caster-info-y c))
                              eff-yield-range)))
                   ally-casters)))
     (define probe-training-unboosted
       (filter (lambda (nx)
                 (and (macro-nexus-info? nx)
                      (macro-nexus-info-training-probe? nx)
                      (not (macro-nexus-info-chrono-buffed? nx))
                      (target-ready? (macro-nexus-info-tag nx))))
               ready-nexuses))
     (cond
       [(null? probe-training-unboosted) '()]
       [else
        (define claimed-tgts (mutable-seteqv))
        (define pairs '())
        (for ([caster-nx (in-list ready-nexuses)]
              #:when (and (macro-nexus-info? caster-nx)
                          (>= (exact->inexact (macro-nexus-info-energy caster-nx))
                              (exact->inexact SC2-NEXUS-CHRONO-BOOST-ENERGY))
                          (not (low-energy-caster-near-nexus? caster-nx))
                          (caster-ready? (macro-nexus-info-tag caster-nx))))
          (define ctag (macro-nexus-info-tag caster-nx))
          (define tgt-nx
            (or (findf (lambda (nx)
                         (and (= (macro-nexus-info-tag nx) ctag)
                              (not (set-member? claimed-tgts ctag))))
                       probe-training-unboosted)
                (findf (lambda (nx)
                         (not (set-member? claimed-tgts (macro-nexus-info-tag nx))))
                       probe-training-unboosted)))
          (when tgt-nx
            (define ttag (macro-nexus-info-tag tgt-nx))
            (set-add! claimed-tgts ttag)
            (set! pairs (cons (cons ctag ttag) pairs))))
        (reverse pairs)])]))
