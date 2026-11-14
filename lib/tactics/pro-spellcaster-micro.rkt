#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/pro-spellcaster-micro.rkt`
;; Pro-Corpus-Calibrated Spellcaster Micro Module (Zerg / Terran / Protoss)
;;
;; Empirically grounded in the #115 pro replay corpus audit (278 LotV games /
;; 556 trajectories / 4,300+ combat spell casts):
;;   1. Universal delta-f = 0 overkill prevention via spatial (`point-claim`)
;;      and single/HP-capped (`unit-claim`) reservation + Disruptor `28f-32f`
;;      (`med=31f`) army-wide Nova stagger.
;;   2. Zerg: Queen Transfusion (`<110` missing = 1 caster, `>=110` = 2) & safe
;;      Creep Tumor; Ravager Fungal->Bile combo, Siege/Static/ForceField shatter,
;;      velocity-led clumps with `0.75`-tile multi-Ravager stagger; Infestor
;;      `0.5`-tile velocity-led Fungal, Neural Parasite w/ nearby army,
;;      Microbial Shroud vs air, non-channeling `<70` energy retreat; Viper
;;      Blinding Cloud, Abduct into `>=4` allies, Parasitic Bomb anti-`824`
;;      stack guard, safe Consume `<60` (`hp > 450`); Corruptor Caustic Spray
;;      when clear of air/AA threats within `11.0` tiles.
;;   3. Terran: Ghost EMP, close-threat-guarded (`0` enemies `<4.5`) HP-capped
;;      Snipe + `34f` channel movement/kite lockout, detector-guarded Cloak;
;;      Raven Interference Matrix, Anti-Armor Missile (`>=5` clump & `>=6`
;;      allies), Auto-Turret; Battlecruiser HP-capped Yamato & `<32%` emergency
;;      Tactical Jump home.
;;   4. Protoss: Sentry `246f` Guardian Shield, `~27f` post-GS Force Field
;;      avoiding `<1.8`-tile ally traps, early `4:00-4:15` Hallucination
;;      Phoenix scout / Archon tank; High Templar Psi Storm (`<=1` ally in `1.5`),
;;      Feedback priority (`Infestor->Viper->Ghost->Medivac->HT->Raven->Oracle`),
;;      post-storm dry-HT `<50` Archon pair merge vs unpaired kite; Oracle
;;      strict 1-command/frame mutex (Revelation -> Pulsar Beam ON w/ `>=60f`
;;      minimum dwell before OFF -> Stasis Ward only when beam OFF).
;;
;; Architecture Boundary:
;;   Depends ONLY on typed Racket stdlib and `../sc2-game-constants.rkt`
;;   (plus local `dyn-hash-ops` typed bridge). Never requires `tactics-sim.rkt`,
;;   `bot-runtime.rkt`, `unit-mode-micro.rkt`, or `transport-drop-micro.rkt`.
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         racket/string
         racket/vector
         typed/racket/unsafe
         "../sc2-game-constants.rkt")

;; Safe bridge for inspecting heterogeneous untyped/mutable/immutable hashes.
(module dyn-hash-ops racket/base
  (require racket/flonum
           racket/string)
  (provide dyn-hash-ref
           dyn-hash-has-key?
           dyn-u-raw-type
           dyn-u-raw-tag
           dyn-u-x
           dyn-u-y
           dyn-u-energy
           dyn-u-shields
           dyn-u-has-buff?
           dyn-u-flying-flag
           dyn-u-hallucination-flag
           dyn-units-xy-batch)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (hash-ref h k (lambda () default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))
  (define (dyn-u-raw-type u)
    (if (hash? u)
        (let ([v (hash-ref u 'type 'unknown)])
          (cond
            [(symbol? v) v]
            [(string? v)
             (let ([t (string-trim v)])
               (if (zero? (string-length t)) 'unknown (string->symbol (string-downcase t))))]
            [else 'unknown]))
        'unknown))
  (define (dyn-u-raw-tag u)
    (if (hash? u)
        (let ([tid (hash-ref u 'id #f)])
          (cond
            [(and (exact-integer? tid) (> tid 0)) tid]
            [else
             (let ([t2 (hash-ref u 'tag 0)])
               (cond
                 [(exact-integer? t2) t2]
                 [(and (real? t2) (< -inf.0 t2 +inf.0)) (inexact->exact (round t2))]
                 [else 0]))]))
        0))
  (define (to-fl v default)
    (cond
      [(flonum? v) (if (and (< -inf.0 v +inf.0)) v default)]
      [(and (real? v) (< -inf.0 v +inf.0)) (exact->inexact v)]
      [else default]))
  (define (dyn-u-x u)
    (if (hash? u) (to-fl (hash-ref u 'x 0.0) 0.0) 0.0))
  (define (dyn-u-y u)
    (if (hash? u) (to-fl (hash-ref u 'y 0.0) 0.0) 0.0))
  (define (dyn-u-energy u)
    (if (hash? u) (to-fl (hash-ref u 'energy 0.0) 0.0) 0.0))
  (define (dyn-u-shields u)
    (if (hash? u)
        (let ([s1 (hash-ref u 'shield #f)])
          (if (not (eq? s1 #f))
              (to-fl s1 0.0)
              (to-fl (hash-ref u 'shields 0.0) 0.0)))
        0.0))
  (define (buff-match? b target)
    (cond
      [(eq? b target) #t]
      [(exact-integer? b)
       (case b
         [(17) (eq? target 'fungal-growth)]
         [(18) (eq? target 'guardian-shield)]
         [(22) (eq? target 'neural-parasite)]
         [(28) (eq? target 'transfusion)]
         [(49) (eq? target 'oracle-revelation)]
         [(56) (eq? target 'oracle-weapon)]
         [(83) (eq? target 'blinding-cloud)]
         [(132) (eq? target 'parasitic-bomb)]
         [else #f])]
      [(string? b)
       (let ([t (string-trim b)])
         (and (not (zero? (string-length t)))
              (eq? (string->symbol (string-downcase t)) target)))]
      [else #f]))
  (define (dyn-u-has-buff? u target)
    (if (hash? u)
        (let ([raw (hash-ref u 'buffs '())])
          (cond
            [(null? raw) #f]
            [(list? raw)
             (let loop ([rem raw])
               (and (pair? rem)
                    (or (buff-match? (car rem) target)
                        (loop (cdr rem)))))]
            [(vector? raw)
             (let ([n (vector-length raw)])
               (let loop ([i 0])
                 (and (< i n)
                      (or (buff-match? (vector-ref raw i) target)
                          (loop (+ i 1))))))]
            [else #f]))
        #f))
  (define (dyn-u-flying-flag u)
    (and (hash? u)
         (or (eq? (hash-ref u 'flying? #f) #t)
             (eq? (hash-ref u 'is-flying #f) #t))))
  (define (dyn-u-hallucination-flag u)
    (and (hash? u)
         (or (eq? (hash-ref u 'is-hallucination #f) #t)
             (eq? (hash-ref u 'hallucination #f) #t))))
  (define (dyn-units-xy-batch units)
    (define max-n (length units))
    (define xs (make-flvector max-n 0.0))
    (define ys (make-flvector max-n 0.0))
    (define us (make-vector max-n #f))
    (let loop ([rem units] [k 0])
      (cond
        [(null? rem) (values xs ys us k)]
        [else
         (define u (car rem))
         (if (hash? u)
             (begin
               (flvector-set! xs k (to-fl (hash-ref u 'x 0.0) 0.0))
               (flvector-set! ys k (to-fl (hash-ref u 'y 0.0) 0.0))
               (vector-set! us k u)
               (loop (cdr rem) (+ k 1)))
             (loop (cdr rem) k))]))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [dyn-u-raw-type (-> Any Symbol)]
  [dyn-u-raw-tag (-> Any Integer)]
  [dyn-u-x (-> Any Float)]
  [dyn-u-y (-> Any Float)]
  [dyn-u-energy (-> Any Float)]
  [dyn-u-shields (-> Any Float)]
  [dyn-u-has-buff? (-> Any Symbol Boolean)]
  [dyn-u-flying-flag (-> Any Boolean)]
  [dyn-u-hallucination-flag (-> Any Boolean)]
  [dyn-units-xy-batch (-> (Listof Any) (Values FlVector FlVector (Vectorof Any) Integer))])

(provide
 ;; Pro-calibrated constants
 PSI-STORM-CLAIM-RADIUS
 PSI-STORM-CLAIM-TTL
 EMP-CLAIM-RADIUS
 EMP-CLAIM-TTL
 FUNGAL-CLAIM-RADIUS
 FUNGAL-CLAIM-TTL
 BLINDING-CLOUD-CLAIM-RADIUS
 BLINDING-CLOUD-CLAIM-TTL
 GUARDIAN-SHIELD-CLAIM-RADIUS
 GUARDIAN-SHIELD-CLAIM-TTL
 ORACLE-REVELATION-CLAIM-RADIUS
 ORACLE-REVELATION-CLAIM-TTL
 FORCE-FIELD-CLAIM-RADIUS
 FORCE-FIELD-CLAIM-TTL
 CORROSIVE-BILE-CLAIM-RADIUS
 CORROSIVE-BILE-CLAIM-TTL
 CORROSIVE-BILE-STAGGER-OFFSET
 CORROSIVE-BILE-COOLDOWN-FRAMES
 ANTI-ARMOR-CLAIM-RADIUS
 ANTI-ARMOR-CLAIM-TTL
 MICROBIAL-SHROUD-CLAIM-RADIUS
 MICROBIAL-SHROUD-CLAIM-TTL
 STASIS-WARD-CLAIM-RADIUS
 STASIS-WARD-CLAIM-TTL
 UNIT-SPELL-CLAIM-TTL
 SNIPE-CHANNEL-LOCKOUT-FRAMES
 SNIPE-DAMAGE
 YAMATO-DAMAGE
 DISRUPTOR-NOVA-STAGGER-MIN-FRAMES
 DISRUPTOR-NOVA-STAGGER-MAX-FRAMES
 DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES
 ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES
 ORACLE-PULSAR-BEAM-ZERO-TARGET-DWELL-FRAMES
 SENTRY-FORCE-FIELD-POST-GS-DELAY-FRAMES
 HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES

 ;; Data structures
 (struct-out spell-directive)
 (struct-out point-claim)
 (struct-out unit-claim)
 (struct-out spell-claims)
 (struct-out spell-tactic-mode)
 make-spell-claims
 SPELL-ABILITY-3-TACTICS-CATALOG
 spell-ability-3-tactics

 ;; Claim, lockout & stagger primitives
 prune-spell-claims!
 spell-point-claimed?
 spell-claim-point?!
 spell-unit-claim-count
 spell-claim-unit?!
 disruptor-nova-stagger-ready?
 record-disruptor-nova-cast!
 filter-staggered-nova-actions
 lock-ghost-snipe-channel!
 snipe-channel-locked?
 can-ghost-move-or-kite?
 spellcaster-channel-protected?
 oracle-pulsar-beam-active?
 spell-directive->sexp

 ;; Race planners & top-level orchestrators
 plan-zerg-spellcaster-micro
 plan-terran-spellcaster-micro
 plan-protoss-spellcaster-micro
 step-pro-spellcaster-micro!
 step-pro-spellcaster-sexps!)

;; -----------------------------------------------------------------------------
;; 1. Calibrated Constants (#115 Pro Corpus)
;; -----------------------------------------------------------------------------

(define PSI-STORM-CLAIM-RADIUS : Float 2.0)
(define PSI-STORM-CLAIM-TTL : Integer 56)

(define EMP-CLAIM-RADIUS : Float 2.0)
(define EMP-CLAIM-TTL : Integer 24)

(define FUNGAL-CLAIM-RADIUS : Float 2.25)
(define FUNGAL-CLAIM-TTL : Integer 32)

(define BLINDING-CLOUD-CLAIM-RADIUS : Float 2.0)
(define BLINDING-CLOUD-CLAIM-TTL : Integer 48)

(define GUARDIAN-SHIELD-CLAIM-RADIUS : Float 5.0)
(define GUARDIAN-SHIELD-CLAIM-TTL : Integer 246)

(define ORACLE-REVELATION-CLAIM-RADIUS : Float 6.0)
(define ORACLE-REVELATION-CLAIM-TTL : Integer 448)

(define FORCE-FIELD-CLAIM-RADIUS : Float 1.5)
(define FORCE-FIELD-CLAIM-TTL : Integer 32)

(define CORROSIVE-BILE-CLAIM-RADIUS : Float 0.55)
(define CORROSIVE-BILE-CLAIM-TTL : Integer 36)
(define CORROSIVE-BILE-STAGGER-OFFSET : Float 0.75)
(define CORROSIVE-BILE-COOLDOWN-FRAMES : Integer 157)

(define ANTI-ARMOR-CLAIM-RADIUS : Float 2.5)
(define ANTI-ARMOR-CLAIM-TTL : Integer 48)

(define MICROBIAL-SHROUD-CLAIM-RADIUS : Float 3.5)
(define MICROBIAL-SHROUD-CLAIM-TTL : Integer 48)

(define STASIS-WARD-CLAIM-RADIUS : Float 2.5)
(define STASIS-WARD-CLAIM-TTL : Integer 64)

(define UNIT-SPELL-CLAIM-TTL : Integer 36)

(define SNIPE-CHANNEL-LOCKOUT-FRAMES : Integer 34)
(define SNIPE-DAMAGE : Float 170.0)
(define YAMATO-DAMAGE : Float 240.0)

(define DISRUPTOR-NOVA-STAGGER-MIN-FRAMES : Integer 28)
(define DISRUPTOR-NOVA-STAGGER-MAX-FRAMES : Integer 32)
(define DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES : Integer 31)

(define ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES : Integer 60)
(define ORACLE-PULSAR-BEAM-ZERO-TARGET-DWELL-FRAMES : Integer 111)
(define SENTRY-FORCE-FIELD-POST-GS-DELAY-FRAMES : Integer 27)
(define HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES : Integer 33)

;; -----------------------------------------------------------------------------
;; 2. Typed Directives & Claim Registry
;; -----------------------------------------------------------------------------

;; Typed spellcaster tactical order (`target-mode`: `'none` `'point` `'unit` `'pair` `'move` `'kite`).
(struct spell-directive
  ([caster-tag : Integer]
   [caster-type : Symbol]
   [ability : Symbol]
   [target-mode : Symbol]
   [target-tag : Integer]
   [target-x : Float]
   [target-y : Float]
   [pattern-name : Symbol])
  #:transparent)

;; Spatial AoE reservation record preventing delta-f = 0 overlapping casts.
(struct point-claim
  ([ability : Symbol]
   [x : Float]
   [y : Float]
   [radius : Float]
   [frame : Integer]
   [expires-frame : Integer])
  #:transparent)

;; Single-target reservation record preventing delta-f = 0 overkill casts.
(struct unit-claim
  ([ability : Symbol]
   [target-tag : Integer]
   [caster-tag : Integer]
   [frame : Integer]
   [expires-frame : Integer])
  #:transparent)

;; Mutable army-wide spell claim, cooldown, channel-lockout, and dwell state.
(struct spell-claims
  ([point-claims : (Listof point-claim)]
   [unit-claims : (Listof unit-claim)]
   [last-disruptor-nova-frame : Integer]
   [last-guardian-shield-frame : Integer]
   [last-hallucination-phoenix-frame : Integer]
   [ghost-snipe-unlock : (HashTable Integer Integer)]
   [oracle-beam-start : (HashTable Integer Integer)]
   [ravager-bile-ready-frame : (HashTable Integer Integer)]
   [ht-storm-frame : (HashTable Integer Integer)]
   [ht-merge-lock-until : (HashTable Integer Integer)]
   [ghost-cloak-frame : (HashTable Integer Integer)])
  #:mutable
  #:transparent)

;; Construct an empty `spell-claims` state for multi-frame micro tracking.
(: make-spell-claims (-> spell-claims))
(define (make-spell-claims)
  (spell-claims
   '()
   '()
   -10000
   -10000
   -10000
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

;; Explicit pro-replay-calibrated tactical mode entry for each caster and spell ability.
(struct spell-tactic-mode
  ([caster-type : Symbol]
   [ability : Symbol]
   [ability-id : Integer]
   [mode-id : Symbol]
   [summary : String]
   [pro-trigger : String])
  #:transparent)

;; 3 pro-replay-supported tactical modes per spell ability across all Z/T/P spellcasters.
(: SPELL-ABILITY-3-TACTICS-CATALOG (Listof spell-tactic-mode))
(define SPELL-ABILITY-3-TACTICS-CATALOG
  (list
   ;; ZERG: Queen (Inject 251, Creep Tumor 1694, Transfusion 1664)
   (spell-tactic-mode 'queen 'inject-larva 251 'queen-inject-cycle
                      "Maintain 29s Inject Larva cadence on active Hatcheries without inject buff"
                      "en>=25 & in inject-queen-tags & townhall<=11.0 unbuffed")
   (spell-tactic-mode 'queen 'inject-larva 251 'queen-inject-banked-double
                      "Dump banked >=50 energy onto auxiliary macro Hatcheries post-engage"
                      "en>=50 & no urgent Transfuse & inject-target open")
   (spell-tactic-mode 'queen 'inject-larva 251 'queen-inject-before-creep
                      "Prioritize Inject ahead of Creep Tumor for designated inject Queens"
                      "tag in inject-queen-tags")
   (spell-tactic-mode 'queen 'spawn-creep-tumor 1694 'queen-tumor-highway
                      "Extend primary main->nat->3rd->enemy highway tumor 3.0-4.8 tiles out"
                      "en>=tumor-min & no enemy<14.0 & no tumor<2.8")
   (spell-tactic-mode 'queen 'spawn-creep-tumor 1694 'queen-tumor-connect-bases
                      "Bridge natural-to-third/fourth creep gaps so defensive Queens stay mobile"
                      "peaceful off-inject macro queen")
   (spell-tactic-mode 'queen 'spawn-creep-tumor 1694 'queen-tumor-anti-drop-edge
                      "Seed perimeter drop-warning tumors along exposed main/natural cliff lines"
                      "2+ bases & perimeter creep deficit")
   (spell-tactic-mode 'queen 'transfusion 1664 'queen-transfuse-brood-queen-anchor
                      "Save sister Queens, Ravagers, Lurkers, and Spines/Spores <65% HP"
                      "en>=50 & ally<=7.0 missing>=65 hp & hp-ratio<0.65")
   (spell-tactic-mode 'queen 'transfusion 1664 'queen-transfuse-ultralisk-tank
                      "Sustain frontline Ultralisk/BroodLord/Corruptor anchors with claim dedup"
                      "frontline capital/tank ally injured")
   (spell-tactic-mode 'queen 'transfusion 1664 'queen-transfuse-hatch-save
                      "Emergency Transfuse on targeted Hatchery/Lair/Hive under timing push"
                      "ally townhall hp-ratio<0.65")

   ;; ZERG: Overseer (Contaminate 1825/182, Oversight 3745/1912, SpawnChangeling 181)
   (spell-tactic-mode 'overseer 'contaminate 1825 'overseer-contaminate-upgrade-tech
                      "Freeze active enemy upgrade lab (Twilight/Forge/Ebay/Armory/Cyber) for 30s"
                      "en>=125 & enemy upgrade/tech building<=7.0")
   (spell-tactic-mode 'overseer 'contaminate 1825 'overseer-contaminate-prod-bottleneck
                      "Halt enemy Stargate/Robotics/Starport/Factory production before timing"
                      "en>=125 & enemy tech production<=7.0")
   (spell-tactic-mode 'overseer 'contaminate 1825 'overseer-contaminate-threat-delay
                      "Contaminate Gateway/Barracks/Hatchery during enemy all-in rally"
                      "en>=125 & enemy production<=7.0")
   (spell-tactic-mode 'overseer 'morph-oversight-mode 3745 'overseer-oversight-ring-watch
                      "Anchor Oversight +50% vision over dead-air/drop approach when AA is absent"
                      "safe>11.0 from enemy AA & stationary spot")
   (spell-tactic-mode 'overseer 'morph-oversight-mode 3745 'overseer-oversight-burrow-guard
                      "Hold Oversight over friendly base/choke against DT, Banshee, or burrow ambushes"
                      "home/choke oversight-desired?")
   (spell-tactic-mode 'overseer 'morph-oversight-mode 3745 'overseer-unmorph-mobile-follow
                      "Exit Oversight back to mobile Overseer when AA closes <10.5 tiles"
                      "overseer-siege-mode & enemy AA<=10.5")
   (spell-tactic-mode 'overseer 'spawn-changeling 181 'overseer-changeling-ramp-block
                      "Drop Changeling near enemy ramp/choke for HoldPosition body-blocking"
                      "en>=50 & en<125 or outside Contaminate range")
   (spell-tactic-mode 'overseer 'spawn-changeling 181 'overseer-changeling-shot-bait
                      "Spawn Changeling forward to absorb opening SiegeTank/Immortal/Stalker shots"
                      "en>=50 & combat skirmish nearby")
   (spell-tactic-mode 'overseer 'spawn-changeling 181 'overseer-changeling-tech-scout
                      "Maintain continuous zero-cooldown Changeling scouting on >=50 energy"
                      "en>=50")

   ;; ZERG: Ravager (Corrosive Bile 2338)
   (spell-tactic-mode 'ravager 'corrosive-bile 2338 'ravager-fungal-bile-combo
                      "Drop Corrosive Bile directly onto Fungal-Growth-rooted clusters (60 guaranteed dmg)"
                      "bile ready & enemy has fungal-growth<=9.0")
   (spell-tactic-mode 'ravager 'corrosive-bile 2338 'ravager-force-field-shatter
                      "Immediately shatter enemy Force Fields blocking army advance"
                      "bile ready & enemy force-field<=9.0")
   (spell-tactic-mode 'ravager 'corrosive-bile 2338 'ravager-siege-static-bile
                      "Target immobile SiegeTankSieged, LiberatorAG, LurkerBurrowed, Cannon, Battery, Bunker"
                      "bile ready & immobile target or >=2 clump<=9.0")

   ;; ZERG: Infestor (Fungal Growth 74, Neural Parasite 249, Microbial Shroud 2545/3821)
   (spell-tactic-mode 'infestor 'fungal-growth 74 'infestor-fungal-kite-root
                      "Lead velocity 0.5 tiles onto >=2 unbuffed Bio/Ling/Air targets with delta-f=0 claim"
                      "en>=75 & >=2 unbuffed enemies r=2.25")
   (spell-tactic-mode 'infestor 'fungal-growth 74 'infestor-fungal-air-clump
                      "Pin harassing Phoenix/Mutalisk/Medivac/Banshee flocks to force engagements"
                      "en>=75 & air harass pack")
   (spell-tactic-mode 'infestor 'fungal-growth 74 'infestor-fungal-reveal-cloaked
                      "Reveal and slow cloaked Ghost/Banshee/DT/burrowed clusters"
                      "en>=75 & unrevealed enemy cluster")
   (spell-tactic-mode 'infestor 'neural-parasite 249 'infestor-neural-capital-tank
                      "Neural high-value Thor/Colossus/Carrier/BC/Immortal behind >=4 combat allies"
                      "en>=100 & >=4 allies<=11.0 & target<=9.0")
   (spell-tactic-mode 'infestor 'neural-parasite 249 'infestor-neural-burst-divert
                      "Steal enemy HighTemplar/Ghost/Viper to turn spells back on opponent"
                      "en>=100 & >=4 allies<=11.0")
   (spell-tactic-mode 'infestor 'neural-parasite 249 'infestor-burrowed-neural-ambush
                      "Channel safe Neural Parasite while burrowed behind front line"
                      "infestor-burrowed & en>=100")
   (spell-tactic-mode 'infestor 'microbial-shroud 2545 'infestor-shroud-anti-carrier-tempest
                      "Blanket >=3 ground combat units under >=3 enemy air threats (-50% air-to-ground dmg)"
                      "en>=75 & >=3 air enemies<=14.0 & >=3 ground allies")
   (spell-tactic-mode 'infestor 'microbial-shroud 2545 'infestor-shroud-vs-liberator-banshee
                      "Shield Hydralisk/Queen/Lurker core trading upward vs Carrier/Tempest/Banshee"
                      "en>=75 & r=3.5 unclaimed")
   (spell-tactic-mode 'infestor 'microbial-shroud 2545 'infestor-shroud-retreat-cover
                      "Deploy protective Shroud when <70 energy Infestor retreats out of air threat"
                      "fallback when en<70 & threat<=12.0")

   ;; ZERG: Viper (Blinding Cloud 2063, Abduct 2067, Parasitic Bomb 2542 + Consume 2069)
   (spell-tactic-mode 'viper 'blinding-cloud 2063 'viper-cloud-ranged-ball
                      "Blind >=2 unclouded ground ranged attackers within 11.0 tiles"
                      "en>=100 & >=2 ranged enemies r=2.0")
   (spell-tactic-mode 'viper 'blinding-cloud 2063 'viper-cloud-static-bunker
                      "Neutralize Bunkers, Planetary Fortresses, Cannons, and Siege Tanks during siege"
                      "en>=100 & static/siege line")
   (spell-tactic-mode 'viper 'blinding-cloud 2063 'viper-cloud-choke-deny
                      "Seal enemy choke ranged fire while Zergling/Roach closes distance"
                      "en>=100 & choke skirmish")
   (spell-tactic-mode 'viper 'abduct 2067 'viper-abduct-siege-colossus
                      "Abduct SiegeTankSieged/Colossus/Thor/Lurker/Tempest into >=4 friendly allies"
                      "en>=75 & >=4 allies<=7.0 & priority target<=9.0")
   (spell-tactic-mode 'viper 'abduct 2067 'viper-abduct-carrier-bc
                      "Pick off exposed Carrier/Battlecruiser/Mothership sequentially with 1/target claim"
                      "en>=75 & >=4 allies<=7.0")
   (spell-tactic-mode 'viper 'abduct 2067 'viper-abduct-spellcaster-pick
                      "Pull isolated Ghost/HighTemplar/Immortal out of protective wall"
                      "en>=75 & >=4 allies<=7.0")
   (spell-tactic-mode 'viper 'parasitic-bomb 2542 'viper-pbomb-air-flock
                      "Tag >=3 enemy air units skipping when 824 dummy or active bomb within 4.0 tiles"
                      "en>=125 & >=3 air enemies & no 824 dummy")
   (spell-tactic-mode 'viper 'parasitic-bomb 2542 'viper-pbomb-medivac-drop
                      "Punish bunched Medivacs, Vikings, Void Rays, or Phoenixes"
                      "en>=125 & air flock<=8.0")
   (spell-tactic-mode 'viper 'viper-consume 2069 'viper-safe-consume-regen
                      "Retreat outside 12.0 enemy threat when energy<60 and Consume >450 HP Zerg building"
                      "en<60 & 0 enemies<=12.0 & bldg hp>450")

   ;; ZERG: Corruptor (2324), SwarmHost (1990), Lurker (2108/2110)
   (spell-tactic-mode 'corruptor 'caustic-spray 2324 'corruptor-spray-exposed-townhall
                      "Channel Caustic Spray on unguarded CommandCenter/Nexus/Hatchery (0 AA <=11.0)"
                      "0 AA/air threat<=11.0 & townhall<=6.0")
   (spell-tactic-mode 'corruptor 'caustic-spray 2324 'corruptor-spray-pf-sniper
                      "Burn down Planetary Fortress / high-HP townhall once air is clear"
                      "0 AA/air threat<=11.0 & high-HP townhall")
   (spell-tactic-mode 'corruptor 'caustic-spray 2324 'corruptor-spray-hit-and-abort
                      "Refuse or abort Spray immediately whenever enemy AA/air enters <=11.0 tiles"
                      "enemy AA/air threat<=11.0 -> abort")
   (spell-tactic-mode 'swarm-host-mp 'spawn-locusts 1990 'swarm-host-locust-wave-base
                      "Launch off-cooldown Locust wave onto enemy mineral line or 3rd from 16-24 tiles"
                      "locusts ready & target<=24.0 unclaimed")
   (spell-tactic-mode 'swarm-host-mp 'spawn-locusts 1990 'swarm-host-locust-tank-breaker
                      "Drop Locusts onto sieged Tanks/Immortals/Colossi before main ground engage"
                      "locusts ready & high-value mech/robo clump")
   (spell-tactic-mode 'swarm-host-mp 'spawn-locusts 1990 'swarm-host-nydus-kite-cycle
                      "Stagger Swarm Host casts across r=4.0 zones and retreat on cooldown"
                      "locust claim radius=4.0")
   (spell-tactic-mode 'lurker-mp 'burrow-lurker 2108 'lurker-burrow-choke-siege
                      "Burrow Lurker within 9.2 tiles of enemy ground targets for instant spine splash"
                      "unburrowed & ground enemy<=9.5")
   (spell-tactic-mode 'lurker-mp 'burrow-lurker 2108 'lurker-burrow-creep-anchor
                      "Lock Lurker behind Roach/Hydra wall before melee/Bio engage lands"
                      "unburrowed & frontline threats<=9.5")
   (spell-tactic-mode 'lurker-mp 'unburrow-lurker 2110 'lurker-unburrow-reposition
                      "Unburrow when 0 ground threats <=13.0 tiles after idle or dodging Nova/Storm/Bile"
                      "lurker-burrowed & (idle>=24f no enemy<=13.0 or hazard<=3.5)")

   ;; TERRAN: Ghost (EMP 1628, Snipe 2714, Cloak 382)
   (spell-tactic-mode 'ghost 'emp-round 1628 'ghost-emp-shield-caster-cluster
                      "EMP >=180 shields or HT/Archon/Sentry/Oracle/Infestor/Viper cluster (r=2.0 dedup)"
                      "en>=75 & >=180 shields or priority caster")
   (spell-tactic-mode 'ghost 'emp-round 1628 'ghost-emp-anti-cloaked-reveal
                      "Strip cloak & energy off enemy Banshees, DTs, or flanking Ghosts"
                      "en>=75 & caster/cloak cluster")
   (spell-tactic-mode 'ghost 'emp-round 1628 'ghost-emp-pre-engage-opener
                      "Fire lead EMP at 10.0 range prior to main Bio Stim crash"
                      "en>=75 & enemy<=10.0 unclaimed")
   (spell-tactic-mode 'ghost 'steady-targeting 2714 'ghost-snipe-capital-bio
                      "Channel 34f Snipe on Ultralisk/BroodLord/Lurker/Viper/Infestor when 0 threats <4.5"
                      "en>=50 & 0 enemies<4.5 & target<=10.0")
   (spell-tactic-mode 'ghost 'steady-targeting 2714 'ghost-snipe-high-hp-zero-overkill
                      "Distribute ceil(HP/170) Snipe claims cleanly across multiple Ghosts"
                      "multi-Ghost HP-capped claim")
   (spell-tactic-mode 'ghost 'steady-targeting 2714 'ghost-snipe-safety-abort
                      "Suppress Snipe whenever any enemy closes inside 4.5 tiles to prevent interruption"
                      "enemy<4.5 -> forbid snipe")
   (spell-tactic-mode 'ghost 'cloak-ghost 382 'ghost-cloak-combat-safety
                      "Cloak at >=50 energy within 10.0 tiles when 0 enemy detectors <11.0 tiles"
                      "en>=50 & enemy<=10.0 & 0 detectors<11.0")
   (spell-tactic-mode 'ghost 'cloak-ghost 382 'ghost-cloak-nuke-infiltration
                      "Remain cloaked during flank positioning outside enemy static/mobile detection"
                      "detector-free flank")
   (spell-tactic-mode 'ghost 'cloak-ghost 382 'ghost-cloak-save-emp
                      "Withhold Cloak when enemy Observer/Overseer/Raven/Turret is within 11.0 tiles"
                      "detector<11.0 -> skip cloak")

   ;; TERRAN: Raven (Interference Matrix 3747, Anti-Armor Missile 3753, Auto-Turret 349)
   (spell-tactic-mode 'raven 'interference-matrix 3747 'raven-matrix-siege-colossus
                      "Disable SiegeTank/Colossus/Thor/Carrier/Immortal/Tempest/Raven/Infestor 1/target"
                      "en>=75 & high-value unit<=9.0")
   (spell-tactic-mode 'raven 'interference-matrix 3747 'raven-matrix-spellcaster-shutoff
                      "Lock HighTemplar/Viper/Oracle before AoE or Storm launches"
                      "en>=75 & enemy caster<=9.0")
   (spell-tactic-mode 'raven 'interference-matrix 3747 'raven-matrix-tvt-tank-opener
                      "Shut down lead TvT Siege Tank before Marine/Tank push connects"
                      "en>=75 & siege-tank<=9.0")
   (spell-tactic-mode 'raven 'anti-armor-missile 3753 'raven-aam-bio-armor-shred
                      "Apply -3 armor Anti-Armor Missile to >=5 enemy clump when >=6 allies <11.0 firing"
                      "en>=75 & >=5 enemies r=2.88 & >=6 allies")
   (spell-tactic-mode 'raven 'anti-armor-missile 3753 'raven-aam-mech-air-splash
                      "Shred armor on bunched Mutalisk/Viking/Roach/Stalker balls with point dedup"
                      "en>=75 & unclaimed clump")
   (spell-tactic-mode 'raven 'anti-armor-missile 3753 'raven-aam-hold-vs-skirmish
                      "Conserve 75 energy for Matrix/Turret when <5 targets or <6 firing allies"
                      "insufficient clump or firing allies")
   (spell-tactic-mode 'raven 'auto-turret 349 'raven-turret-worker-harass
                      "Drop Auto-Turret into enemy mineral line prioritizing SCV/Probe/Drone targets"
                      "en>=50 & worker/light<=8.0")
   (spell-tactic-mode 'raven 'auto-turret 349 'raven-turret-melee-zone
                      "Place Auto-Turret to block charging Zerglings/Zealots/Adepts"
                      "en>=50 & >=2 enemies r=3.5")
   (spell-tactic-mode 'raven 'auto-turret 349 'raven-turret-vision-tank
                      "Deploy Auto-Turret forward as disposable high-DPS decoy during skirmish"
                      "en>=50 & point claim free")

   ;; TERRAN: Medivac (2116/386), Cyclone (2350), Battlecruiser (401/2358)
   (spell-tactic-mode 'medivac 'medivac-boost 2116 'medivac-boost-loaded-drop
                      "Fire Ignite Afterburners carrying bio cargo toward peripheral mineral drop"
                      "boost ready & cargo-count>0")
   (spell-tactic-mode 'medivac 'medivac-boost 2116 'medivac-boost-rescue-evac
                      "Boost injured Medivac (<45% HP) away from pursuing anti-air / casters"
                      "boost ready & hp-ratio<0.45 & enemy<=9.0")
   (spell-tactic-mode 'medivac 'medivac-boost 2116 'medivac-boost-tempo-reinforce
                      "Accelerate empty/full Medivac reinforcement back across long map lanes"
                      "boost ready & cargo>0 or threat")
   (spell-tactic-mode 'medivac 'heal 386 'medivac-heal-injured-bio
                      "Explicitly heal lowest-HP Marine/Marauder/Ghost/Reaper/SCV/Hellbat (<92% HP <=5.5)"
                      "bio ally<=5.5 missing hp")
   (spell-tactic-mode 'medivac 'heal 386 'medivac-heal-stim-recovery
                      "Top off Stim-damaged bio ball right before or between kite volleys"
                      "injured marine/marauder<=5.5")
   (spell-tactic-mode 'medivac 'heal 386 'medivac-retreat-low-hp-empty
                      "Pull critically damaged Medivac (<45% HP) safely behind army"
                      "hp-ratio<0.45 & boost on cd & enemy<=9.0")
   (spell-tactic-mode 'cyclone 'lock-on 2350 'cyclone-lock-on-high-value
                      "Lock-On Stalker/VoidRay/Oracle/WarpPrism/Medivac/Roach/Ravager <=7.5 (1/target)"
                      "lock-on ready & priority unit<=7.5")
   (spell-tactic-mode 'cyclone 'lock-on 2350 'cyclone-lock-on-kite-tether
                      "Keep 9.0-14.5 tile kite separation while Lock-On channels full 6s burst"
                      "tethered target locked")
   (spell-tactic-mode 'cyclone 'lock-on 2350 'cyclone-lock-on-air-zone
                      "Snap-Lock invading Oracle, Banshee, Liberator, or Warp Prism immediately"
                      "air harasser<=7.5")
   (spell-tactic-mode 'battlecruiser 'yamato-cannon 401 'bc-yamato-snipe
                      "Distribute ceil(HP/240) Yamato claims across Carrier/Tempest/Colossus/Thor/BC"
                      "yamato ready & high-value unit<=10.0")
   (spell-tactic-mode 'battlecruiser 'yamato-cannon 401 'bc-yamato-static-aa-clear
                      "Delete defensive MissileTurret/Spore/Cannon/Viking threat protecting mineral line"
                      "yamato ready & heavy AA<=10.0")
   (spell-tactic-mode 'battlecruiser 'yamato-cannon 401 'bc-yamato-reserve-jump-escape
                      "Always prioritize Emergency Jump at <32% HP over firing Yamato"
                      "hp-ratio<0.32 -> jump first")
   (spell-tactic-mode 'battlecruiser 'tactical-jump 2358 'bc-emergency-tactical-jump
                      "Tactical Jump to home repair anchor whenever HP falls <32% >12 tiles from home"
                      "jump ready & hp-ratio<0.32 & dist-home>12")
   (spell-tactic-mode 'battlecruiser 'tactical-jump 2358 'bc-tactical-jump-backstab
                      "Jump healthy BC (>=85% HP, no threat <16) onto isolated remote enemy worker cluster"
                      "jump ready & hp>=85% & isolated remote target>25")
   (spell-tactic-mode 'battlecruiser 'tactical-jump 2358 'bc-tactical-jump-reinforce-def
                      "Teleport across map directly to defend home base vs all-in"
                      "emergency home jump")

   ;; PROTOSS: HighTemplar (Psi Storm 1036, Feedback 140)
   (spell-tactic-mode 'high-templar 'psi-storm 1036 'ht-psi-storm-bio-clump
                      "Lead 0.25-tile Storm onto >=2 bio/hydra/ling clump with <=1 ally in 1.5 tiles"
                      "en>=75 & >=2 enemies & <=1 ally in 1.5")
   (spell-tactic-mode 'high-templar 'psi-storm 1036 'ht-psi-storm-emp-counter
                      "Cast max-range 9.0 Storm immediately before Ghost EMP/Viper closes"
                      "en>=75 & unclaimed r=2.0 storm")
   (spell-tactic-mode 'high-templar 'psi-storm 1036 'ht-psi-storm-dry-archon-merge
                      "Pair dry HTs (<50 energy) into instant Archon merge or safe back-kite"
                      "2 dry HTs<=20.0")
   (spell-tactic-mode 'high-templar 'feedback 140 'ht-feedback-medivac-viper
                      "Feedback >=50-energy Ghost/Viper/Infestor/Medivac/Raven/Oracle/Sentry (1/target)"
                      "en>=50 & high-energy enemy caster<=10.0")
   (spell-tactic-mode 'high-templar 'feedback 140 'ht-feedback-bc-ghost-shutoff
                      "Strip energy from incoming Ghosts/Ravens/Queens before spells cast"
                      "en>=50 & caster priority")
   (spell-tactic-mode 'high-templar 'feedback 140 'ht-feedback-defend-warp-prism
                      "Counter-snipe dropping Medivacs/WarpPrisms/Vipers behind natural"
                      "en>=50 & medivac/caster<=10.0")

   ;; PROTOSS: Sentry (Guardian Shield 76, Force Field 1526, Hallucination 154/bait)
   (spell-tactic-mode 'sentry 'guardian-shield 76 'sentry-guardian-shield-ranged-fight
                      "Activate GS with >=3 combat allies <4.5 facing >=2 ranged enemies <10 (246f claim)"
                      "en>=75 & >=3 allies<=4.5 & >=2 ranged<=10")
   (spell-tactic-mode 'sentry 'guardian-shield 76 'sentry-gs-timing-push
                      "Open main army clash with Guardian Shield -2 ranged damage aura"
                      "unbuffed sentry & ranged engage")
   (spell-tactic-mode 'sentry 'guardian-shield 76 'sentry-gs-hold-vs-melee
                      "Hold GS energy vs pure melee charges until Force Field is spent"
                      "<2 ranged enemies")
   (spell-tactic-mode 'sentry 'force-field 1526 'sentry-force-field-split-army
                      "Bisect >=4 melee enemies >=27f after GS with zero non-flying allies <1.8 tiles"
                      "en>=50 & >=27f post-GS & 0 allies<1.8")
   (spell-tactic-mode 'sentry 'force-field 1526 'sentry-force-field-ramp-lock
                      "Block ramp/choke vs Baneling/Zealot/Zergling floods"
                      "en>=50 & melee cluster<=10.5")
   (spell-tactic-mode 'sentry 'force-field 1526 'sentry-force-field-retreat-wall
                      "Slice pursuing ground pack cleanly without trapping friendly units"
                      "ally-trapped?=#f & no existing force-field")
   (spell-tactic-mode 'sentry 'hallucination-phoenix 154 'sentry-hallucination-phoenix-scout
                      "Spawn safe Hallucination Phoenix scout in 4:00-4:15 pro window (900f cooldown)"
                      "en>=75 & safe & frame<=7200")
   (spell-tactic-mode 'sentry 'hallucination-archon 156 'sentry-hallucination-colossus-tank
                      "Spawn Hallucination Archon frontline damage sponge during >=125 energy clash"
                      "en>=125 & engaged?")
   (spell-tactic-mode 'sentry 'hallucination-zealot 164 'sentry-hallucination-bait-fire
                      "Spawn cheap Hallucination Zealot/bait when engaged near WidowMines/SiegeTanks"
                      "en>=75 & <125 & high-burst siege/mine<=11.0")

   ;; PROTOSS: Oracle (2375/2146/2505), Phoenix (173/176), Disruptor (2346)
   (spell-tactic-mode 'oracle 'pulsar-beam 2375 'oracle-pulsar-beam-workers
                      "Enable Pulsar Beam >=40 en & >=35 sh vs >=2 light/workers <5 with >=60f dwell"
                      "en>=40 & sh>=35 & >=2 light/worker<=5.0")
   (spell-tactic-mode 'oracle 'pulsar-beam 2375 'oracle-pulsar-beam-ling-defense
                      "Melts early Zergling/Zealot runbys inside natural wall behind batteries"
                      "en>=40 & >=2 light attackers<=5.0")
   (spell-tactic-mode 'oracle 'pulsar-beam 2375 'oracle-pulsar-beam-dwell-off
                      "Hold beam ON >=60f (111f 0-target) then switch OFF preserving Revelation energy"
                      "dwell>=60 & (en<15 or sh<25 or 0-tgt>=111f)")
   (spell-tactic-mode 'oracle 'oracle-revelation 2146 'oracle-revelation-stealth-reveal
                      "Cast Revelation immediately onto cloaked/burrowed Banshee/Ghost/DT/Lurker/Mine"
                      "beam OFF & en>=25 & unrevealed stealth<=10.5")
   (spell-tactic-mode 'oracle 'oracle-revelation 2146 'oracle-revelation-army-tag
                      "Tag enemy siege/HT ball ahead of friendly High Templars for long-range Storm"
                      "beam OFF & en>=25 & HT within 16.0")
   (spell-tactic-mode 'oracle 'oracle-revelation 2146 'oracle-revelation-kiting-vision
                      "Maintain continuous vision on kited Mech/Lurker army before Tempest volleys"
                      "r=6.0 ttl=448 claim dedup")
   (spell-tactic-mode 'oracle 'stasis-ward 2505 'oracle-stasis-ward-choke
                      "Plant Stasis Ward on choke points or natural ramp when beam OFF & >=55 energy"
                      "beam OFF & en>=55 & safe site<=8.0")
   (spell-tactic-mode 'oracle 'stasis-ward 2505 'oracle-stasis-mineral-trap
                      "Seed behind enemy mineral line to freeze pulling SCVs/Drones/Probes"
                      "beam OFF & en>=55 & safe behind line")
   (spell-tactic-mode 'oracle 'stasis-ward 2505 'oracle-stasis-defensive-ramp
                      "Anchor home natural/3rd choke against multi-prong Ling/Bane/Hellion drops"
                      "safe from existing ward<4.5 & enemy<4.5")
   (spell-tactic-mode 'phoenix 'graviton-beam 173 'phoenix-graviton-lift-siege-lurker
                      "Lift Sieged Tank, Lurker, Disruptor, Swarm Host, or Immortal (>=50 en, 1/target)"
                      "en>=50 & priority ground<=5.5 & safe AA ratio")
   (spell-tactic-mode 'phoenix 'graviton-beam 173 'phoenix-graviton-worker-pick
                      "Lift exposed Queen or Probes/SCVs/Drones while sister Phoenixes focus-fire"
                      "en>=50 & worker/queen<=5.5 & wingman ready")
   (spell-tactic-mode 'phoenix 'graviton-beam 173 'phoenix-graviton-abort-vs-aa
                      "Refuse risky Graviton channel if solo Phoenix faces >=2 anti-air threats <8.0"
                      "solo phoenix vs >=2 AA<=8.0 -> skip lift")
   (spell-tactic-mode 'disruptor 'purification-nova 2346 'disruptor-nova-stagger-clump
                      "Fire Purification Nova onto >=2 ground clump honoring >=28-32f (`31f`) stagger gate"
                      "nova ready & stagger-ready? & >=2 ground clump<=12.5")
   (spell-tactic-mode 'disruptor 'purification-nova 2346 'disruptor-nova-siege-zone
                      "Snipe immobile SiegeTankSieged/LurkerBurrowed/Colossus/Marauder clusters"
                      "nova ready & high-value ground<=12.5")
   (spell-tactic-mode 'disruptor 'purification-nova 2346 'disruptor-nova-zone-choke-retreat
                      "Hold staggered second Nova ready to zone enemy follow-up while Stalkers kite"
                      "disruptor-nova-stagger-ready? commit=#t")))

(: normalize-tactic-lookup-sym (-> Symbol Symbol))
(define (normalize-tactic-lookup-sym sym)
  (case sym
    [(swarm-host) 'swarm-host-mp]
    [(lurker lurker-burrowed lurker-mp-burrowed) 'lurker-mp]
    [(overseer-siege-mode) 'overseer]
    [(infestor-burrowed) 'infestor]
    [(transfuse) 'transfusion]
    [(revelation) 'oracle-revelation]
    [(emp) 'emp-round]
    [(snipe) 'steady-targeting]
    [(yamato yamato-gun) 'yamato-cannon]
    [(consume) 'viper-consume]
    [(oversight) 'morph-oversight-mode]
    [(inject) 'inject-larva]
    [(creep-tumor) 'spawn-creep-tumor]
    [(fungal) 'fungal-growth]
    [(neural) 'neural-parasite]
    [(shroud) 'microbial-shroud]
    [(ghost-cloak) 'cloak-ghost]
    [(ignite-afterburners) 'medivac-boost]
    [else sym]))

;; Lookup all 3 pro-replay tactical modes for a caster (`'overseer`, `'phoenix`, ...)
;; or a spell ability (`'contaminate`, `'graviton-beam`, `'purification-nova`, ...).
(: spell-ability-3-tactics (-> Symbol (Listof spell-tactic-mode)))
(define (spell-ability-3-tactics caster-or-ability)
  (define k (normalize-tactic-lookup-sym caster-or-ability))
  (filter (lambda ([m : spell-tactic-mode])
            (or (eq? (spell-tactic-mode-caster-type m) k)
                (eq? (spell-tactic-mode-ability m) k)
                (and (eq? k 'hallucination)
                     (not (not (memq (spell-tactic-mode-ability m)
                                     '(hallucination-phoenix hallucination-archon hallucination-zealot)))))))
          SPELL-ABILITY-3-TACTICS-CATALOG))

;; -----------------------------------------------------------------------------
;; 3. Internal Math, Normalization & Safe Unit Hash Inspectors
;; -----------------------------------------------------------------------------

(: safe-fl (-> Any Float Float))
(define (safe-fl v default)
  (if (real? v)
      (let ([f (real->double-flonum v)])
        (if (or (nan? f) (infinite? f)) default f))
      default))

(: safe-int (-> Any Integer Integer))
(define (safe-int v default)
  (cond
    [(exact-integer? v) v]
    [(real? v)
     (let ([f (real->double-flonum v)])
       (if (or (nan? f) (infinite? f))
           default
           (exact-round f)))]
    [else default]))

(: safe-sym (-> Any Symbol Symbol))
(define (safe-sym v default)
  (cond
    [(symbol? v) v]
    [(string? v)
     (let ([t (string-trim v)])
       (if (zero? (string-length t))
           default
           (string->symbol (string-downcase t))))]
    [else default]))

(: ->float (-> Real Float))
(define (->float x)
  (real->double-flonum x))

(: dist2 (-> Float Float Float Float Float))
(define (dist2 x1 y1 x2 y2)
  (define dx (- x1 x2))
  (define dy (- y1 y2))
  (flsqrt (+ (* dx dx) (* dy dy))))

(: clamp-coord (-> Float Float))
(define (clamp-coord c)
  (min SC2-MAP-SAFE-MAX-COORD (max SC2-MAP-SAFE-MIN-COORD c)))

(: safe-ceil-div (-> Float Float Integer))
(define (safe-ceil-div num den)
  (define d (max 1.0 den))
  (define n (max 0.0 num))
  (if (<= n 0.0)
      1
      (let* ([q (/ n d)]
             [i (exact-floor q)])
        (max 1 (if (< (* d (->float i)) n) (+ i 1) i)))))

(: sum-units-fl (-> (Listof Any) (-> Any Float) Float))
(define (sum-units-fl units fn)
  (for/fold ([tot : Float 0.0])
            ([u (in-list units)])
    (+ tot (fn u))))

(struct spell-xy-index
  ([xs : FlVector]
   [ys : FlVector]
   [us : (Vectorof Any)]
   [n : Integer]))

(define current-spell-xy-table : (Parameterof (Option (HashTable Any spell-xy-index)))
  (make-parameter #f))

(: list-at-least-8? (-> (Listof Any) Boolean))
(define (list-at-least-8? lst)
  (let ([p lst])
    (and (pair? p)
         (let ([p1 (cdr p)])
           (and (pair? p1)
                (let ([p2 (cdr p1)])
                  (and (pair? p2)
                       (let ([p3 (cdr p2)])
                         (and (pair? p3)
                              (let ([p4 (cdr p3)])
                                (and (pair? p4)
                                     (let ([p5 (cdr p4)])
                                       (and (pair? p5)
                                            (let ([p6 (cdr p5)])
                                              (and (pair? p6)
                                                   (pair? (cdr p6)))))))))))))))))

(: get-spell-xy-index (-> (Listof Any) (Option spell-xy-index)))
(define (get-spell-xy-index units)
  (define tbl (current-spell-xy-table))
  (cond
    [(or (not tbl) (not (list-at-least-8? units))) #f]
    [else
     (or (hash-ref tbl units (lambda () #f))
         (let-values ([(xs ys us n) (dyn-units-xy-batch units)])
           (define idx (spell-xy-index xs ys us n))
           (hash-set! tbl units idx)
           idx))]))

(: sum-hp-within (-> (Listof Any) Float Float Float Float))
(define (sum-hp-within units cx cy rad)
  (if (< rad 0.0)
      0.0
      (let ([r2 (* rad rad)]
            [idx (get-spell-xy-index units)])
        (if idx
            (let ([xs (spell-xy-index-xs idx)]
                  [ys (spell-xy-index-ys idx)]
                  [us (spell-xy-index-us idx)]
                  [n (spell-xy-index-n idx)])
              (for/fold ([tot : Float 0.0])
                        ([i (in-range n)])
                (define dx (- cx (flvector-ref xs i)))
                (if (<= (flabs dx) rad)
                    (let ([dy (- cy (flvector-ref ys i))])
                      (if (and (<= (flabs dy) rad)
                               (<= (+ (* dx dx) (* dy dy)) r2))
                          (+ tot (uh-total-hp (vector-ref us i)))
                          tot))
                    tot)))
            (for/fold ([tot : Float 0.0])
                      ([e (in-list units)])
              (if (hash? e)
                  (let ([dx (- cx (uh-x e))])
                    (if (<= (flabs dx) rad)
                        (let ([dy (- cy (uh-y e))])
                          (if (and (<= (flabs dy) rad)
                                   (<= (+ (* dx dx) (* dy dy)) r2))
                              (+ tot (uh-total-hp e))
                              tot))
                        tot))
                  tot))))))

(: canonical-spell-key (-> Symbol Symbol))
(define (canonical-spell-key ab)
  (case ab
    [(emp) 'emp-round]
    [(psistorm) 'psi-storm]
    [(forcefield) 'force-field]
    [(snipe) 'steady-targeting]
    [(yamato yamato-gun) 'yamato-cannon]
    [(transfuse) 'transfusion]
    [(consume viper-consume-structure) 'viper-consume]
    [(revelation) 'oracle-revelation]
    [(oracle-stasis-ward build-stasis-trap) 'stasis-ward]
    [(pulsar-beam) 'pulsar-beam-on]
    [(spread-creep-tumor build-creep-tumor) 'spawn-creep-tumor]
    [(build-auto-turret) 'auto-turret]
    [else ab]))

(: canonical-sexp-spell (-> Symbol Symbol))
(define (canonical-sexp-spell ab)
  (case ab
    [(yamato-gun yamato) 'yamato-cannon]
    [(snipe) 'steady-targeting]
    [(transfuse) 'transfusion]
    [(revelation) 'oracle-revelation]
    [(emp) 'emp-round]
    [(consume) 'viper-consume]
    [else ab]))

(: uh-tag (-> Any Integer))
(define (uh-tag u)
  (dyn-u-raw-tag u))

(define *spell-canon-sym-cache* : (Mutable-HashTable Symbol Symbol) (make-hasheq))

(: uh-type (-> Any Symbol))
(define (uh-type u)
  (define raw (dyn-u-raw-type u))
  (or (hash-ref *spell-canon-sym-cache* raw (lambda () #f))
      (let ([canon (sc2-canonical-unit-sym raw)])
        (hash-set! *spell-canon-sym-cache* raw canon)
        canon)))

(: uh-raw-type (-> Any Symbol))
(define (uh-raw-type u)
  (dyn-u-raw-type u))

(: uh-x (-> Any Float))
(define (uh-x u)
  (dyn-u-x u))

(: uh-y (-> Any Float))
(define (uh-y u)
  (dyn-u-y u))

(: uh-vx (-> Any Float))
(define (uh-vx u)
  (safe-fl (dyn-hash-ref u 'vx 0.0) 0.0))

(: uh-vy (-> Any Float))
(define (uh-vy u)
  (safe-fl (dyn-hash-ref u 'vy 0.0) 0.0))

(: uh-energy (-> Any Float))
(define (uh-energy u)
  (dyn-u-energy u))

(: uh-shields (-> Any Float))
(define (uh-shields u)
  (dyn-u-shields u))

;; Extract total current HP (hull + shields) supporting both live combined
;; `sc2-protobuf-ws` hashes (`'hull-hp` + combined `'hp`) and synthetic split hashes.
(define *spell-combat-stats-cache* :
  (Mutable-HashTable Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol)))
  (make-hasheq))

(: cached-unit-combat-stats (-> Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol))))
(define (cached-unit-combat-stats sym)
  (or (hash-ref *spell-combat-stats-cache* sym (lambda () #f))
      (let ([st (sc2-unit-combat-stats sym)])
        (hash-set! *spell-combat-stats-cache* sym st)
        st)))

(: uh-total-hp (-> Any Float))
(define (uh-total-hp u)
  (cond
    [(dyn-hash-has-key? u 'hull-hp)
     (if (dyn-hash-has-key? u 'hp)
         (safe-fl (dyn-hash-ref u 'hp 0.0) 0.0)
         (+ (safe-fl (dyn-hash-ref u 'hull-hp 0.0) 0.0) (uh-shields u)))]
    [else
     (define raw-hp (safe-fl (dyn-hash-ref u 'hp 0.0) 0.0))
     (define sh (uh-shields u))
     (if (<= sh 0.0)
         raw-hp
         (let* ([stats (cached-unit-combat-stats (uh-type u))]
                [t-hull (safe-fl (hash-ref stats 'max-hp (lambda () 0.0)) 0.0)]
                [has-max? (dyn-hash-has-key? u 'max-hp)]
                [raw-max (if has-max? (safe-fl (dyn-hash-ref u 'max-hp 0.0) 0.0) 0.0)]
                [already-combined?
                 (or (and (> t-hull 0.0) (> raw-hp (+ t-hull 0.5)))
                     (and (<= t-hull 0.0) has-max? (> raw-max (+ sh 0.5)) (>= raw-hp sh)))])
           (if already-combined? raw-hp (+ raw-hp sh))))]))

(: uh-max-total-hp (-> Any Float))
(define (uh-max-total-hp u)
  (define stats (cached-unit-combat-stats (uh-type u)))
  (define t-hull (safe-fl (hash-ref stats 'max-hp (lambda () 0.0)) 0.0))
  (define t-shield (safe-fl (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
  (define table-tot (+ t-hull t-shield))
  (cond
    [(dyn-hash-has-key? u 'hull-hp)
     (define raw-max (safe-fl (dyn-hash-ref u 'max-hp 0.0) 0.0))
     (if (> raw-max 0.0) raw-max table-tot)]
    [(dyn-hash-has-key? u 'max-hp)
     (define raw-max (safe-fl (dyn-hash-ref u 'max-hp 0.0) 0.0))
     (define sh (uh-shields u))
     (if (and (> (+ t-shield sh) 0.0)
              (> t-hull 0.0)
              (<= raw-max (+ t-hull 0.5)))
         (+ raw-max (max t-shield sh))
         (max raw-max (uh-total-hp u)))]
    [(> table-tot 0.0) (max table-tot (uh-total-hp u))]
    [else (uh-total-hp u)]))

(: uh-missing-hp (-> Any Float))
(define (uh-missing-hp u)
  (max 0.0 (- (uh-max-total-hp u) (uh-total-hp u))))

(: uh-hp-ratio (-> Any Float))
(define (uh-hp-ratio u)
  (define m (uh-max-total-hp u))
  (if (<= m 0.0) 1.0 (min 1.0 (max 0.0 (/ (uh-total-hp u) m)))))

(: buff-entry->sym (-> Any (Option Symbol)))
(define (buff-entry->sym b)
  (cond
    [(symbol? b) b]
    [(string? b) (string->symbol (string-downcase (string-trim b)))]
    [(exact-integer? b)
     (case b
       [(17) 'fungal-growth]
       [(18) 'guardian-shield]
       [(22) 'neural-parasite]
       [(28) 'transfusion]
       [(49) 'oracle-revelation]
       [(56) 'oracle-weapon]
       [(83) 'blinding-cloud]
       [(132) 'parasitic-bomb]
       [else #f])]
    [else #f]))

(: uh-buffs (-> Any (Listof Symbol)))
(define (uh-buffs u)
  (define raw (dyn-hash-ref u 'buffs '()))
  (define items : (Listof Any)
    (cond
      [(list? raw) raw]
      [(vector? raw) (vector->list raw)]
      [else '()]))
  (for/fold ([acc : (Listof Symbol) '()])
            ([b (in-list items)])
    (define s (buff-entry->sym b))
    (if s (cons s acc) acc)))

(: uh-has-buff? (-> Any Symbol Boolean))
(define (uh-has-buff? u target-buff)
  (dyn-u-has-buff? u target-buff))

(: uh-cloaked? (-> Any Boolean))
(define (uh-cloaked? u)
  (or (eq? (dyn-hash-ref u 'cloaked #f) #t)
      (let ([cv (dyn-hash-ref u 'cloak 0)])
        (or (eq? cv #t)
            (and (exact-integer? cv) (or (= cv 1) (= cv 2)))
            (and (memq (safe-sym cv 'unknown) '(cloaked cloaked-detected)) #t)))))

(: uh-burrowed? (-> Any Boolean))
(define (uh-burrowed? u)
  (or (eq? (dyn-hash-ref u 'is-burrowed #f) #t)
      (eq? (dyn-hash-ref u 'burrowed #f) #t)
      (and (memq (uh-raw-type u)
                 '(lurker-burrowed lurker-mp-burrowed widow-mine-burrowed
                   infestor-burrowed roach-burrowed zergling-burrowed
                   baneling-burrowed hydralisk-burrowed ultralisk-burrowed
                   queen-burrowed drone-burrowed swarm-host-burrowed))
           #t)))

(: uh-hallucination? (-> Any Boolean))
(define (uh-hallucination? u)
  (dyn-u-hallucination-flag u))

(: current-spell-flying-cache (Parameterof (Option (HashTable Any Symbol))))
(define current-spell-flying-cache (make-parameter #f))

(: uh-flying? (-> Any Boolean))
(define (uh-flying? u)
  (define ht (current-spell-flying-cache))
  (cond
    [ht
     (define cached (hash-ref ht u #f))
     (cond
       [(eq? cached 'yes) #t]
       [(eq? cached 'no) #f]
       [else
        (define res
          (or (dyn-u-flying-flag u)
              (sc2-unit-is-flying-sym? (uh-type u))))
        (hash-set! ht u (if res 'yes 'no))
        res])]
    [else
     (or (dyn-u-flying-flag u)
         (sc2-unit-is-flying-sym? (uh-type u)))]))

(: uh-detector? (-> Any Boolean))
(define (uh-detector? u)
  (or (eq? (dyn-hash-ref u 'is-detector #f) #t)
      (eq? (dyn-hash-ref u 'detector? #f) #t)
      (sc2-unit-is-detector-sym? (uh-type u))
      (and (memq (uh-type u) SC2-MOBILE-DETECTOR-SYMS) #t)
      (and (memq (uh-type u) SC2-STATIC-DETECTOR-SYMS) #t)))

(: uh-order-ids (-> Any (Listof Integer)))
(define (uh-order-ids u)
  (define top-ab (safe-int (dyn-hash-ref u 'order-ability-id 0) 0))
  (define orders-raw (dyn-hash-ref u 'orders '()))
  (define lst : (Listof Any)
    (cond
      [(list? orders-raw) orders-raw]
      [(vector? orders-raw) (vector->list orders-raw)]
      [else '()]))
  (define order-ids
    (for/fold ([acc : (Listof Integer) '()])
              ([ord (in-list lst)])
      (define ab
        (cond
          [(exact-integer? ord) ord]
          [(hash? ord)
           (let ([id1 (safe-int (dyn-hash-ref ord 'ability-id 0) 0)])
             (if (> id1 0) id1 (safe-int (dyn-hash-ref ord 'ability_id 0) 0)))]
          [else 0]))
      (if (> ab 0) (cons ab acc) acc)))
  (if (> top-ab 0) (cons top-ab order-ids) order-ids))

;; Returns `#t` if unit is currently executing a protected channel or Archon morph order.
(: spellcaster-channel-protected? (-> Any Boolean))
(define (spellcaster-channel-protected? u)
  (for/or : Boolean ([ab (in-list (uh-order-ids u))])
    (define cls (sc2-order-protection-class ab))
    (or (eq? cls 'channel) (eq? cls 'morph))))

(: velocity-lead-xy (-> Any Float (Values Float Float)))
(define (velocity-lead-xy u max-lead)
  (define vx (uh-vx u))
  (define vy (uh-vy u))
  (define spd2 (+ (* vx vx) (* vy vy)))
  (if (<= spd2 0.0625) ;; speed <= 0.25 tiles/sec
      (values (uh-x u) (uh-y u))
      (let* ([spd (flsqrt spd2)]
             [lead (min max-lead (* 0.25 spd))])
        (values (clamp-coord (+ (uh-x u) (* lead (/ vx spd))))
                (clamp-coord (+ (uh-y u) (* lead (/ vy spd))))))))

;; -----------------------------------------------------------------------------
;; 4. Universal delta-f = 0 Claims, Lockouts & Disruptor Stagger Primitives
;; -----------------------------------------------------------------------------

(: spell-point-default-radius (-> Symbol Float))
(define (spell-point-default-radius ab)
  (case (canonical-spell-key ab)
    [(psi-storm) PSI-STORM-CLAIM-RADIUS]
    [(emp-round) EMP-CLAIM-RADIUS]
    [(fungal-growth) FUNGAL-CLAIM-RADIUS]
    [(blinding-cloud) BLINDING-CLOUD-CLAIM-RADIUS]
    [(guardian-shield) GUARDIAN-SHIELD-CLAIM-RADIUS]
    [(oracle-revelation) ORACLE-REVELATION-CLAIM-RADIUS]
    [(force-field) FORCE-FIELD-CLAIM-RADIUS]
    [(corrosive-bile) CORROSIVE-BILE-CLAIM-RADIUS]
    [(anti-armor-missile) ANTI-ARMOR-CLAIM-RADIUS]
    [(microbial-shroud) MICROBIAL-SHROUD-CLAIM-RADIUS]
    [(stasis-ward) STASIS-WARD-CLAIM-RADIUS]
    [(spawn-creep-tumor) 3.5]
    [(auto-turret) 2.0]
    [else 2.0]))

(: spell-point-default-ttl (-> Symbol Integer))
(define (spell-point-default-ttl ab)
  (case (canonical-spell-key ab)
    [(psi-storm) PSI-STORM-CLAIM-TTL]
    [(emp-round) EMP-CLAIM-TTL]
    [(fungal-growth) FUNGAL-CLAIM-TTL]
    [(blinding-cloud) BLINDING-CLOUD-CLAIM-TTL]
    [(guardian-shield) GUARDIAN-SHIELD-CLAIM-TTL]
    [(oracle-revelation) ORACLE-REVELATION-CLAIM-TTL]
    [(force-field) FORCE-FIELD-CLAIM-TTL]
    [(corrosive-bile) CORROSIVE-BILE-CLAIM-TTL]
    [(anti-armor-missile) ANTI-ARMOR-CLAIM-TTL]
    [(microbial-shroud) MICROBIAL-SHROUD-CLAIM-TTL]
    [(stasis-ward) STASIS-WARD-CLAIM-TTL]
    [(spawn-creep-tumor auto-turret) 64]
    [else 32]))

(: prune-hash-below! (-> (HashTable Integer Integer) Integer Void))
(define (prune-hash-below! ht frame)
  (define stale
    (for/fold ([ks : (Listof Integer) '()])
              ([(k v) (in-hash ht)])
      (if (<= v frame) (cons k ks) ks)))
  (for ([k (in-list stale)])
    (hash-remove! ht k)))

;; Prune all expired spatial point claims, unit claims, and temporary windows.
(: prune-spell-claims! (-> spell-claims Integer Void))
(define (prune-spell-claims! claims current-frame)
  (set-spell-claims-point-claims!
   claims
   (for/list : (Listof point-claim)
             ([c (in-list (spell-claims-point-claims claims))]
              #:when (> (point-claim-expires-frame c) current-frame))
     c))
  (set-spell-claims-unit-claims!
   claims
   (for/list : (Listof unit-claim)
             ([c (in-list (spell-claims-unit-claims claims))]
              #:when (> (unit-claim-expires-frame c) current-frame))
     c))
  (prune-hash-below! (spell-claims-ghost-snipe-unlock claims) current-frame)
  (prune-hash-below! (spell-claims-ht-merge-lock-until claims) current-frame)
  (prune-hash-below! (spell-claims-ravager-bile-ready-frame claims) current-frame))

;; Returns `#t` if an active claim of `ability` covers `(x, y)` at `current-frame`.
;; Supports `(claims ability x y frame)` and `(claims ability x y radius frame)`.
(: spell-point-claimed? (->* (spell-claims Symbol Real Real Real) ((Option Real) #:radius (Option Real)) Boolean))
(define (spell-point-claimed? claims ability x y arg5 [arg6 #f] #:radius [kw-radius #f])
  (define ab (canonical-spell-key ability))
  (define fx (safe-fl x 0.0))
  (define fy (safe-fl y 0.0))
  (define-values (rad frame)
    (cond
      [arg6 (values (safe-fl arg5 (spell-point-default-radius ab)) (safe-int arg6 0))]
      [(exact-integer? arg5)
       (values (if kw-radius (safe-fl kw-radius (spell-point-default-radius ab)) (spell-point-default-radius ab))
               arg5)]
      [else (values (spell-point-default-radius ab) (safe-int arg5 0))]))
  (for/or : Boolean ([c (in-list (spell-claims-point-claims claims))])
    (and (eq? (point-claim-ability c) ab)
         (> (point-claim-expires-frame c) frame)
         (< (dist2 fx fy (point-claim-x c) (point-claim-y c))
            (max rad (point-claim-radius c))))))

;; Atomically reserve an AoE cast point `(x, y)` if no active claim overlaps.
;; Supports 5-arg `(claims ab x y frame)`, 6-arg `(claims ab x y radius frame)`,
;; 7-arg `(claims ab x y radius frame ttl)`, or keyword overrides.
(: spell-claim-point?!
   (->* (spell-claims Symbol Real Real)
        ((Option Real) (Option Real) (Option Integer) #:radius (Option Real) #:frame (Option Integer) #:ttl (Option Integer))
        Boolean))
(define (spell-claim-point?! claims ability x y [arg5 #f] [arg6 #f] [arg7 #f]
                             #:radius [kw-radius #f] #:frame [kw-frame #f] #:ttl [kw-ttl #f])
  (define ab (canonical-spell-key ability))
  (define fx (safe-fl x 0.0))
  (define fy (safe-fl y 0.0))
  (define-values (rad frame ttl)
    (cond
      [(and arg5 arg6 arg7)
       (values (safe-fl arg5 (spell-point-default-radius ab))
               (safe-int arg6 0)
               (max 1 (safe-int arg7 (spell-point-default-ttl ab))))]
      [(and arg5 arg6)
       (values (safe-fl arg5 (spell-point-default-radius ab))
               (safe-int arg6 0)
               (if kw-ttl (max 1 kw-ttl) (spell-point-default-ttl ab)))]
      [arg5
       (values (if kw-radius (safe-fl kw-radius (spell-point-default-radius ab)) (spell-point-default-radius ab))
               (if kw-frame kw-frame (safe-int arg5 0))
               (if kw-ttl (max 1 kw-ttl) (spell-point-default-ttl ab)))]
      [else
       (values (if kw-radius (safe-fl kw-radius (spell-point-default-radius ab)) (spell-point-default-radius ab))
               (or kw-frame 0)
               (if kw-ttl (max 1 kw-ttl) (spell-point-default-ttl ab)))]))
  (cond
    [(spell-point-claimed? claims ab fx fy rad frame) #f]
    [else
     (define active
       (for/list : (Listof point-claim)
                 ([c (in-list (spell-claims-point-claims claims))]
                  #:when (> (point-claim-expires-frame c) frame))
         c))
     (set-spell-claims-point-claims!
      claims
      (cons (point-claim ab fx fy rad frame (+ frame ttl)) active))
     (when (eq? ab 'guardian-shield)
       (set-spell-claims-last-guardian-shield-frame! claims frame))
     #t]))

;; Count active unit-target claims for `(ability, target-tag)` at `current-frame`.
(: spell-unit-claim-count (-> spell-claims Symbol Integer Integer Integer))
(define (spell-unit-claim-count claims ability target-tag current-frame)
  (define ab (canonical-spell-key ability))
  (for/sum : Integer ([c (in-list (spell-claims-unit-claims claims))])
    (if (and (eq? (unit-claim-ability c) ab)
             (= (unit-claim-target-tag c) target-tag)
             (> (unit-claim-expires-frame c) current-frame))
        1
        0)))

;; Determine effective concurrent caster cap on `target-tag` per #115/#117 rules.
(: unit-claim-effective-cap (-> Symbol Real Real (Option Positive-Integer) Boolean Positive-Integer))
(define (unit-claim-effective-cap ab target-hp missing-hp explicit-max allow-multi?)
  (cond
    [explicit-max explicit-max]
    [(eq? ab 'steady-targeting)
     (define eff (if (> (safe-fl target-hp 0.0) 0.0) (safe-fl target-hp SNIPE-DAMAGE) SNIPE-DAMAGE))
     (define c (safe-ceil-div eff SNIPE-DAMAGE))
     (if (> c 0) c 1)]
    [(eq? ab 'yamato-cannon)
     (define eff (if (> (safe-fl target-hp 0.0) 0.0) (safe-fl target-hp YAMATO-DAMAGE) YAMATO-DAMAGE))
     (define c (safe-ceil-div eff YAMATO-DAMAGE))
     (if (> c 0) c 1)]
    [(eq? ab 'transfusion)
     (if (and allow-multi? (>= (safe-fl missing-hp 0.0) 110.0)) 2 1)]
    [else 1]))

;; Atomically reserve a single/HP-capped unit-target spell cast on `target-tag`.
;; Enforces `target-tag > 0` and delta-f = 0 / overkill limits.
(: spell-claim-unit?!
   (->* (spell-claims Symbol Integer Integer)
        (Integer #:caster-tag Integer #:max-casters (Option Positive-Integer) #:target-hp Real #:missing-hp Real #:allow-multi? Boolean)
        Boolean))
(define (spell-claim-unit?! claims ability target-tag current-frame
                            [ttl UNIT-SPELL-CLAIM-TTL]
                            #:caster-tag [caster-tag 0]
                            #:max-casters [max-casters #f]
                            #:target-hp [target-hp 0.0]
                            #:missing-hp [missing-hp 0.0]
                            #:allow-multi? [allow-multi? #t])
  (define ab (canonical-spell-key ability))
  (cond
    [(<= target-tag 0) #f]
    [else
     (define active
       (for/list : (Listof unit-claim)
                 ([c (in-list (spell-claims-unit-claims claims))]
                  #:when (> (unit-claim-expires-frame c) current-frame))
         c))
     (define matching
       (for/list : (Listof unit-claim)
                 ([c (in-list active)]
                  #:when (and (eq? (unit-claim-ability c) ab)
                              (= (unit-claim-target-tag c) target-tag)))
         c))
     (define cap (unit-claim-effective-cap ab target-hp missing-hp max-casters allow-multi?))
     (define same-caster-this-frame?
       (and (> caster-tag 0)
            (for/or : Boolean ([c (in-list matching)])
              (and (= (unit-claim-caster-tag c) caster-tag)
                   (= (unit-claim-frame c) current-frame)))))
     (cond
       [same-caster-this-frame? #f]
       [(>= (length matching) cap) #f]
       [else
        (set-spell-claims-unit-claims!
         claims
         (cons (unit-claim ab target-tag caster-tag current-frame (+ current-frame (max 1 ttl)))
               active))
        #t])]))

;; Record an army-wide Disruptor Purification Nova cast at `current-frame`.
(: record-disruptor-nova-cast! (-> spell-claims Integer Void))
(define (record-disruptor-nova-cast! claims current-frame)
  (set-spell-claims-last-disruptor-nova-frame! claims current-frame))

;; Check #115 `28f-32f` (`med=31f`) army-wide Disruptor Purification Nova stagger gate.
;; When `#:commit? #t` is passed and ready, atomically advances the Nova timestamp.
(: disruptor-nova-stagger-ready? (->* (spell-claims Integer) (Integer #:commit? Boolean) Boolean))
(define (disruptor-nova-stagger-ready? claims current-frame
                                       [stagger-frames DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES]
                                       #:commit? [commit? #f])
  (define last-f (spell-claims-last-disruptor-nova-frame claims))
  (define ready?
    (or (< last-f -5000)
        (>= (- current-frame last-f) stagger-frames)))
  (when (and ready? commit?)
    (set-spell-claims-last-disruptor-nova-frame! claims current-frame))
  ready?)

;; Filter S-expression action lists (e.g. from `step-disruptor-tactical-micro!`)
;; so at most one `'purification-nova` (`2346`) fires per `28f-32f` (`med=31f`) window.
(: filter-staggered-nova-actions (->* (spell-claims (Listof (Listof Any)) Integer) (Integer) (Listof (Listof Any))))
(define (filter-staggered-nova-actions claims actions current-frame
                                       [stagger-frames DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES])
  (for/fold ([acc : (Listof (Listof Any)) '()]
             #:result (reverse acc))
            ([act (in-list actions)])
    (define nova-cast?
      (and (pair? act)
           (memq (car act) '(cast cast-spell))
           (>= (length act) 3)
           (let ([sp (caddr act)])
             (or (eq? sp 'purification-nova)
                 (and (exact-integer? sp) (= sp 2346))))))
    (cond
      [(not nova-cast?) (cons act acc)]
      [(disruptor-nova-stagger-ready? claims current-frame stagger-frames #:commit? #t)
       (cons act acc)]
      [else acc])))

;; Lock a Ghost out of movement/kiting/recasting for `duration-frames` (`34f` per #115).
(: lock-ghost-snipe-channel! (->* (spell-claims Integer Integer) (Integer) Void))
(define (lock-ghost-snipe-channel! claims caster-tag current-frame
                                   [duration-frames SNIPE-CHANNEL-LOCKOUT-FRAMES])
  (when (> caster-tag 0)
    (hash-set! (spell-claims-ghost-snipe-unlock claims)
               caster-tag
               (+ current-frame (max 1 duration-frames)))))

;; Returns `#t` if Ghost (`tag` or unit hash) is inside its `34f` Snipe channel lockout.
(: snipe-channel-locked? (-> spell-claims Any Integer Boolean))
(define (snipe-channel-locked? claims caster-or-tag current-frame)
  (define tag : Integer
    (if (exact-integer? caster-or-tag)
        caster-or-tag
        (uh-tag caster-or-tag)))
  (define unlock-f (hash-ref (spell-claims-ghost-snipe-unlock claims) tag (lambda () -1)))
  (or (< current-frame unlock-f)
      (and (hash? caster-or-tag)
           (for/or : Boolean ([ab (in-list (uh-order-ids caster-or-tag))])
             (= ab 2714)))))

;; Convenience inverse of `snipe-channel-locked?`.
(: can-ghost-move-or-kite? (-> spell-claims Any Integer Boolean))
(define (can-ghost-move-or-kite? claims caster-or-tag current-frame)
  (not (snipe-channel-locked? claims caster-or-tag current-frame)))

;; Returns `(values active? dwell-frames)` for an Oracle's Pulsar Beam mutex tracker.
(: oracle-pulsar-beam-active? (-> spell-claims Any Integer (Values Boolean Integer)))
(define (oracle-pulsar-beam-active? claims oracle-u current-frame)
  (define o-tag (if (exact-integer? oracle-u) oracle-u (uh-tag oracle-u)))
  (define start-ht (spell-claims-oracle-beam-start claims))
  (define explicit-off?
    (and (hash? oracle-u)
         (dyn-hash-has-key? oracle-u 'pulsar-beam-on?)
         (not (eq? (dyn-hash-ref oracle-u 'pulsar-beam-on? #t) #t))))
  (define buff-on?
    (and (hash? oracle-u)
         (or (uh-has-buff? oracle-u 'oracle-weapon)
             (uh-has-buff? oracle-u 'pulsar-beam)
             (eq? (dyn-hash-ref oracle-u 'pulsar-beam-on? #f) #t)
             (eq? (dyn-hash-ref oracle-u 'pulsar-beam? #f) #t))))
  (cond
    [explicit-off?
     (hash-remove! start-ht o-tag)
     (values #f 0)]
    [buff-on?
     (define st
       (or (hash-ref start-ht o-tag (lambda () #f))
           (begin (hash-set! start-ht o-tag current-frame) current-frame)))
     (values #t (max 0 (- current-frame st)))]
    [(hash-ref start-ht o-tag (lambda () #f))
     => (lambda ([st : Integer])
          (define dwell (max 0 (- current-frame st)))
          (if (> dwell 450)
              (begin (hash-remove! start-ht o-tag) (values #f 0))
              (values #t dwell)))]
    [else (values #f 0)]))

;; Convert a typed `spell-directive` into a `sc2-typed-commands` S-expression.
(: spell-directive->sexp (-> spell-directive (Listof Any)))
(define (spell-directive->sexp d)
  (define uid (spell-directive-caster-tag d))
  (define ab (canonical-sexp-spell (spell-directive-ability d)))
  (define mode (spell-directive-target-mode d))
  (define tid (spell-directive-target-tag d))
  (define tx (spell-directive-target-x d))
  (define ty (spell-directive-target-y d))
  (case mode
    [(none) (list 'cast-spell uid ab)]
    [(point) (list 'cast-spell uid ab tx ty)]
    [(unit) (list 'cast-spell uid ab tid)]
    [(pair)
     (if (and (memq (spell-directive-ability d) '(morph-archon archon))
              (> tid 0)
              (not (= uid tid)))
         (list 'morph (list uid tid) 'archon)
         (list 'morph 'archon))]
    [(move) (list 'move uid tx ty)]
    [(kite) (list 'kite uid tx ty)]
    [else (list 'cast-spell uid ab)]))

;; -----------------------------------------------------------------------------
;; 5. Shared Spatial Scoring, Cluster Selection & Effect Helpers
;; -----------------------------------------------------------------------------

(: unit-combat-relevant? (-> Any Boolean))
(define (unit-combat-relevant? u)
  (define t (uh-type u))
  (and (not (memq t '(larva egg cocoon baneling-cocoon ravager-cocoon
                      brood-lord-cocoon overlord-cocoon overlord
                      overlord-transport changeling changeling-zealot
                      changeling-marine changeling-marine-shield
                      changeling-zergling changeling-zergling-wings
                      adept-phase-shift disruptor-phased kd8-charge
                      parasitic-bomb-dummy mule broodling broodling-escort
                      creep-tumor creep-tumor-burrowed creep-tumor-queen)))
       (not (memq t '(scv probe drone)))
       (not (uh-hallucination? u))))

(: count-units-within (-> (Listof Any) Float Float Float (-> Any Boolean) Integer))
(define (count-units-within units cx cy radius pred)
  (cond
    [(or (< radius 0.0) (null? units)) 0]
    [else
     (define r2 (* radius radius))
     (define idx (get-spell-xy-index units))
     (if idx
         (let ([xs (spell-xy-index-xs idx)]
               [ys (spell-xy-index-ys idx)]
               [us (spell-xy-index-us idx)]
               [n (spell-xy-index-n idx)])
           (for/sum : Integer ([i (in-range n)])
             (define dx (- cx (flvector-ref xs i)))
             (if (<= (flabs dx) radius)
                 (let ([dy (- cy (flvector-ref ys i))])
                   (if (and (<= (flabs dy) radius)
                            (<= (+ (* dx dx) (* dy dy)) r2)
                            (pred (vector-ref us i)))
                       1
                       0))
                 0)))
         (for/sum : Integer ([u (in-list units)])
           (if (hash? u)
               (let ([dx (- cx (uh-x u))])
                 (if (<= (flabs dx) radius)
                     (let ([dy (- cy (uh-y u))])
                       (if (and (<= (flabs dy) radius)
                                (<= (+ (* dx dx) (* dy dy)) r2)
                                (pred u))
                           1
                           0))
                     0))
               0)))]))

(: any-unit-within? (-> (Listof Any) Float Float Float (-> Any Boolean) Boolean))
(define (any-unit-within? units cx cy radius pred)
  (cond
    [(or (< radius 0.0) (null? units)) #f]
    [else
     (define r2 (* radius radius))
     (define idx (get-spell-xy-index units))
     (if idx
         (let ([xs (spell-xy-index-xs idx)]
               [ys (spell-xy-index-ys idx)]
               [us (spell-xy-index-us idx)]
               [n (spell-xy-index-n idx)])
           (let loop : Boolean ([i : Integer 0])
             (cond
               [(>= i n) #f]
               [else
                (define dx (- cx (flvector-ref xs i)))
                (if (<= (flabs dx) radius)
                    (let ([dy (- cy (flvector-ref ys i))])
                      (if (and (<= (flabs dy) radius)
                               (<= (+ (* dx dx) (* dy dy)) r2)
                               (pred (vector-ref us i)))
                          #t
                          (loop (+ i 1))))
                    (loop (+ i 1)))])))
         (for/or : Boolean ([u (in-list units)])
           (and (hash? u)
                (let ([dx (- cx (uh-x u))])
                  (and (<= (flabs dx) radius)
                       (let ([dy (- cy (uh-y u))])
                         (and (<= (flabs dy) radius)
                              (<= (+ (* dx dx) (* dy dy)) r2)
                              (pred u))))))))]))

(: count-within-at-most? (-> (Listof Any) Float Float Float Integer (-> Any Boolean) Boolean))
(define (count-within-at-most? units cx cy radius limit pred)
  (cond
    [(< radius 0.0) (>= limit 0)]
    [(< limit 0) #f]
    [(null? units) #t]
    [else
     (define r2 (* radius radius))
     (define idx (get-spell-xy-index units))
     (if idx
         (let ([xs (spell-xy-index-xs idx)]
               [ys (spell-xy-index-ys idx)]
               [us (spell-xy-index-us idx)]
               [n (spell-xy-index-n idx)])
           (let loop : Boolean ([i : Integer 0] [cnt : Integer 0])
             (cond
               [(>= i n) #t]
               [else
                (define dx (- cx (flvector-ref xs i)))
                (if (<= (flabs dx) radius)
                    (let ([dy (- cy (flvector-ref ys i))])
                      (if (and (<= (flabs dy) radius)
                               (<= (+ (* dx dx) (* dy dy)) r2)
                               (pred (vector-ref us i)))
                          (let ([nxt (+ cnt 1)])
                            (if (> nxt limit) #f (loop (+ i 1) nxt)))
                          (loop (+ i 1) cnt)))
                    (loop (+ i 1) cnt))])))
         (let loop : Boolean ([rem : (Listof Any) units] [cnt : Integer 0])
           (cond
             [(null? rem) #t]
             [else
              (define u (car rem))
              (if (hash? u)
                  (let ([dx (- cx (uh-x u))])
                    (if (<= (flabs dx) radius)
                        (let ([dy (- cy (uh-y u))])
                          (if (and (<= (flabs dy) radius)
                                   (<= (+ (* dx dx) (* dy dy)) r2)
                                   (pred u))
                              (let ([nxt (+ cnt 1)])
                                (if (> nxt limit) #f (loop (cdr rem) nxt)))
                              (loop (cdr rem) cnt)))
                        (loop (cdr rem) cnt)))
                  (loop (cdr rem) cnt))])))]))

(: count-all-allies-within (-> (Listof Any) (Listof Any) Float Float Float (-> Any Boolean) Integer))
(define (count-all-allies-within units bldgs cx cy radius pred)
  (+ (count-units-within units cx cy radius pred)
     (count-units-within bldgs cx cy radius pred)))

(: enemy-ground-range (-> Any Float))
(define (enemy-ground-range u)
  (safe-fl (hash-ref (cached-unit-combat-stats (uh-type u)) 'ground-range (lambda () 0.0)) 0.0))

(: enemy-ranged-threat? (-> Any Boolean))
(define (enemy-ranged-threat? u)
  (define st (cached-unit-combat-stats (uh-type u)))
  (define gr (safe-fl (hash-ref st 'ground-range (lambda () 0.0)) 0.0))
  (define ar (safe-fl (hash-ref st 'air-range (lambda () 0.0)) 0.0))
  (or (>= gr 2.0) (>= ar 2.0)))

(: enemy-anti-air-or-air-threat? (-> Any Boolean))
(define (enemy-anti-air-or-air-threat? u)
  (define t (uh-type u))
  (and (not (memq t '(overlord overlord-transport observer observer-siege-mode
                      overseer overseer-siege-mode scv probe drone larva egg
                      parasitic-bomb-dummy kd8-charge)))
       (or (uh-flying? u)
           (sc2-unit-can-attack-air? t))))

(: enemy-detector-within? (-> (Listof Any) (Listof Any) Float Float Float Boolean))
(define (enemy-detector-within? enemy-units enemy-bldgs cx cy radius)
  (or (any-unit-within? enemy-units cx cy radius uh-detector?)
      (any-unit-within? enemy-bldgs cx cy radius uh-detector?)))

(: safe-retreat-point (-> Float Float (Listof Any) Float Float Float (Values Float Float)))
(define (safe-retreat-point ux uy threats home-x home-y step-dist)
  (define-values (tx ty n)
    (for/fold ([sx : Float 0.0]
               [sy : Float 0.0]
               [cnt : Integer 0])
              ([e (in-list threats)]
               #:when (and (hash? e) (<= (dist2 ux uy (uh-x e) (uh-y e)) 14.0)))
      (values (+ sx (uh-x e)) (+ sy (uh-y e)) (+ cnt 1))))
  (define raw-dx
    (if (> n 0)
        (- ux (/ tx (->float n)))
        (- home-x ux)))
  (define raw-dy
    (if (> n 0)
        (- uy (/ ty (->float n)))
        (- home-y uy)))
  ;; Blend 65% away from immediate threats + 35% toward home base
  (define hdx (- home-x ux))
  (define hdy (- home-y uy))
  (define hlen (max 0.01 (flsqrt (+ (* hdx hdx) (* hdy hdy)))))
  (define rlen (max 0.01 (flsqrt (+ (* raw-dx raw-dx) (* raw-dy raw-dy)))))
  (define vx (+ (* 0.65 (/ raw-dx rlen)) (* 0.35 (/ hdx hlen))))
  (define vy (+ (* 0.65 (/ raw-dy rlen)) (* 0.35 (/ hdy hlen))))
  (define vlen (max 0.01 (flsqrt (+ (* vx vx) (* vy vy)))))
  (values (clamp-coord (+ ux (* step-dist (/ vx vlen))))
          (clamp-coord (+ uy (* step-dist (/ vy vlen))))))

(: centroid-and-velocity (-> (Listof Any) (Values Float Float Float Float Integer)))
(define (centroid-and-velocity members)
  (define-values (sx sy svx svy n)
    (for/fold ([ax : Float 0.0]
               [ay : Float 0.0]
               [avx : Float 0.0]
               [avy : Float 0.0]
               [cnt : Integer 0])
              ([u (in-list members)])
      (values (+ ax (uh-x u))
              (+ ay (uh-y u))
              (+ avx (uh-vx u))
              (+ avy (uh-vy u))
              (+ cnt 1))))
  (if (= n 0)
      (values 0.0 0.0 0.0 0.0 0)
      (let ([fn (->float n)])
        (values (/ sx fn) (/ sy fn) (/ svx fn) (/ svy fn) n))))

;; Generic cluster evaluator: returns `(values best-x best-y best-score)`.
;; Evaluates candidate cluster centered on each eligible seed unit in `seeds`
;; within `cast-range` of `(caster-x, caster-y)`, aggregating nearby enemies
;; within `aoe-radius`, applying optional velocity lead (`max-lead`), and calling
;; `score-fn : (cluster-cx cluster-cy cluster-members -> Float)`.
(struct cluster-pt ([x : Float] [y : Float] [vx : Float] [vy : Float] [u : Any]))

(: best-enemy-cluster
   (-> Float Float Float (Listof Any) Float Float (-> Float Float (Listof Any) Float)
       (Values Boolean Float Float Float)))
(define (best-enemy-cluster caster-x caster-y cast-range enemies aoe-radius max-lead score-fn)
  (cond
    [(or (< cast-range 0.0) (< aoe-radius 0.0) (null? enemies))
     (values #f 0.0 0.0 0.0)]
    [else
     (define r-outer (+ cast-range aoe-radius 1e-6))
     (define r-outer-sq (* r-outer r-outer))
     (define cast-r2 (* cast-range cast-range))
     (define aoe-r2 (* aoe-radius aoe-radius))
     (define idx (get-spell-xy-index enemies))
     (define-values (nearby seeds)
       (if idx
           (let ([xs (spell-xy-index-xs idx)]
                 [ys (spell-xy-index-ys idx)]
                 [us (spell-xy-index-us idx)]
                 [n (spell-xy-index-n idx)])
             (for/fold ([nb : (Listof cluster-pt) '()]
                        [sd : (Listof cluster-pt) '()]
                        #:result (values nb (reverse sd)))
                       ([i (in-range n)])
               (define ex (flvector-ref xs i))
               (define dx (- caster-x ex))
               (if (<= (flabs dx) r-outer)
                   (let* ([ey (flvector-ref ys i)]
                          [dy (- caster-y ey)])
                     (if (<= (flabs dy) r-outer)
                         (let ([d2 (+ (* dx dx) (* dy dy))])
                           (if (<= d2 r-outer-sq)
                               (let ([e (vector-ref us i)])
                                 (if (sc2-enemy-unit-targetable? e)
                                     (let ([pt (cluster-pt ex ey (uh-vx e) (uh-vy e) e)])
                                       (values (cons pt nb)
                                               (if (and (<= (flabs dx) cast-range)
                                                        (<= (flabs dy) cast-range)
                                                        (<= d2 cast-r2))
                                                   (cons pt sd)
                                                   sd)))
                                     (values nb sd)))
                               (values nb sd)))
                         (values nb sd)))
                   (values nb sd))))
           (for/fold ([nb : (Listof cluster-pt) '()]
                      [sd : (Listof cluster-pt) '()]
                      #:result (values nb (reverse sd)))
                     ([e (in-list enemies)]
                      #:when (hash? e))
             (define ex (uh-x e))
             (define dx (- caster-x ex))
             (if (<= (flabs dx) r-outer)
                 (let* ([ey (uh-y e)]
                        [dy (- caster-y ey)])
                   (if (<= (flabs dy) r-outer)
                       (let ([d2 (+ (* dx dx) (* dy dy))])
                         (if (and (<= d2 r-outer-sq)
                                  (sc2-enemy-unit-targetable? e))
                             (let ([pt (cluster-pt ex ey (uh-vx e) (uh-vy e) e)])
                               (values (cons pt nb)
                                       (if (and (<= (flabs dx) cast-range)
                                                (<= (flabs dy) cast-range)
                                                (<= d2 cast-r2))
                                           (cons pt sd)
                                           sd)))
                             (values nb sd)))
                       (values nb sd)))
                 (values nb sd)))))
     (if (null? seeds)
         (values #f 0.0 0.0 0.0)
         (for/fold ([f? : Boolean #f]
                    [best-x : Float 0.0]
                    [best-y : Float 0.0]
                    [best-s : Float 0.0])
                   ([s (in-list seeds)])
           (define sx (cluster-pt-x s))
           (define sy (cluster-pt-y s))
           (define-values (cluster ax ay avx avy cnt)
             (for/fold ([cl : (Listof Any) '()]
                        [sx-acc : Float 0.0]
                        [sy-acc : Float 0.0]
                        [svx-acc : Float 0.0]
                        [svy-acc : Float 0.0]
                        [n : Integer 0])
                       ([p (in-list nearby)])
               (define px (cluster-pt-x p))
               (define py (cluster-pt-y p))
               (define dx (- sx px))
               (define dy (- sy py))
               (if (and (<= (abs dx) aoe-radius)
                        (<= (abs dy) aoe-radius)
                        (<= (+ (* dx dx) (* dy dy)) aoe-r2))
                   (values (cons (cluster-pt-u p) cl)
                           (+ sx-acc px)
                           (+ sy-acc py)
                           (+ svx-acc (cluster-pt-vx p))
                           (+ svy-acc (cluster-pt-vy p))
                           (+ n 1))
                   (values cl sx-acc sy-acc svx-acc svy-acc n))))
           (cond
             [(= cnt 0) (values f? best-x best-y best-s)]
             [else
              (define fn (->float cnt))
              (define cx (/ ax fn))
              (define cy (/ ay fn))
              (define vx (/ avx fn))
              (define vy (/ avy fn))
              (define-values (lx ly)
                (if (<= max-lead 0.0)
                    (values cx cy)
                    (let ([spd2 (+ (* vx vx) (* vy vy))])
                      (if (<= spd2 0.0625)
                          (values cx cy)
                          (let* ([spd (flsqrt spd2)]
                                 [lead (min max-lead (* 0.25 spd))])
                            (values (clamp-coord (+ cx (* lead (/ vx spd))))
                                    (clamp-coord (+ cy (* lead (/ vy spd))))))))))
              (define ldx (- caster-x lx))
              (define ldy (- caster-y ly))
              (define sc (if (<= (+ (* ldx ldx) (* ldy ldy)) cast-r2)
                             (score-fn lx ly cluster)
                             0.0))
              (if (> sc best-s)
                  (values #t lx ly sc)
                  (values f? best-x best-y best-s))])))]))

(: effect-type (-> Any Symbol))
(define (effect-type eff)
  (safe-sym (dyn-hash-ref eff 'type 'unknown) 'unknown))

(: effect-friendly? (-> Any Boolean))
(define (effect-friendly? eff)
  (eq? (dyn-hash-ref eff 'friendly? #f) #t))

(: any-effect-within? (-> (Listof Any) Symbol Float Float Float (-> Any Boolean) Boolean))
(define (any-effect-within? effects target-type cx cy radius extra-pred)
  (for/or : Boolean ([eff (in-list effects)])
    (and (hash? eff)
         (eq? (effect-type eff) target-type)
         (<= (dist2 cx cy (uh-x eff) (uh-y eff)) radius)
         (extra-pred eff))))

(: unit-inside-point-claim? (-> spell-claims Symbol Float Float Float Integer Boolean))
(define (unit-inside-point-claim? claims ab ux uy extra-rad frame)
  (for/or : Boolean ([c (in-list (spell-claims-point-claims claims))])
    (and (eq? (point-claim-ability c) ab)
         (> (point-claim-expires-frame c) frame)
         (<= (dist2 ux uy (point-claim-x c) (point-claim-y c))
             (+ (point-claim-radius c) extra-rad)))))

;; Pick highest-priority target unit within `cast-range` matching `pred` & `weight-fn`.
(: best-unit-target
   (-> Float Float Float (Listof Any) (-> Any Boolean) (-> Any Float)
       (Values Boolean Any Float)))
(define (best-unit-target cx cy cast-range candidates pred weight-fn)
  (cond
    [(or (< cast-range 0.0) (null? candidates))
     (values #f #f 0.0)]
    [else
     (define r2 (* cast-range cast-range))
     (define idx (get-spell-xy-index candidates))
     (if idx
         (let ([xs (spell-xy-index-xs idx)]
               [ys (spell-xy-index-ys idx)]
               [us (spell-xy-index-us idx)]
               [n (spell-xy-index-n idx)])
           (for/fold ([found? : Boolean #f]
                      [best-u : Any #f]
                      [best-w : Float 0.0])
                     ([i (in-range n)])
             (define dx (- cx (flvector-ref xs i)))
             (if (<= (flabs dx) cast-range)
                 (let ([dy (- cy (flvector-ref ys i))])
                   (if (and (<= (flabs dy) cast-range)
                            (<= (+ (* dx dx) (* dy dy)) r2))
                       (let ([u (vector-ref us i)])
                         (if (and (> (uh-tag u) 0) (pred u))
                             (let ([w (weight-fn u)])
                               (if (> w best-w)
                                   (values #t u w)
                                   (values found? best-u best-w)))
                             (values found? best-u best-w)))
                       (values found? best-u best-w)))
                 (values found? best-u best-w))))
         (for/fold ([found? : Boolean #f]
                    [best-u : Any #f]
                    [best-w : Float 0.0])
                   ([u (in-list candidates)]
                    #:when (hash? u))
           (define dx (- cx (uh-x u)))
           (if (<= (flabs dx) cast-range)
               (let ([dy (- cy (uh-y u))])
                 (if (and (<= (flabs dy) cast-range)
                          (<= (+ (* dx dx) (* dy dy)) r2)
                          (> (uh-tag u) 0)
                          (pred u))
                     (let ([w (weight-fn u)])
                       (if (> w best-w)
                           (values #t u w)
                           (values found? best-u best-w)))
                     (values found? best-u best-w)))
               (values found? best-u best-w))))]))

;; -----------------------------------------------------------------------------
;; 6. Zerg Spellcaster Patterns (Queen, Ravager, Infestor, Viper, Corruptor)
;; -----------------------------------------------------------------------------

(: queen-transfuse-priority (-> Symbol Float))
(define (queen-transfuse-priority sym)
  (case sym
    [(ultralisk) 100.0]
    [(brood-lord) 95.0]
    [(queen) 92.0]
    [(lurker lurker-burrowed lurker-mp lurker-mp-burrowed) 88.0]
    [(viper) 85.0]
    [(infestor infestor-burrowed) 82.0]
    [(ravager) 78.0]
    [(hydralisk) 72.0]
    [(roach roach-burrowed) 68.0]
    [(spine-crawler) 64.0]
    [(spore-crawler) 60.0]
    [(hatchery lair hive) 58.0]
    [else 0.0]))

(: zerg-bile-siege-or-static? (-> Any Boolean))
(define (zerg-bile-siege-or-static? e)
  (and (memq (uh-type e)
             '(siege-tank-sieged liberator-ag lurker-burrowed lurker-mp-burrowed
               warp-prism-phasing photon-cannon bunker shield-battery
               spine-crawler spore-crawler missile-turret))
       #t))

(: ravager-try-bile-point! (-> spell-claims Integer Float Float Float Float Float Boolean Integer Symbol (Option spell-directive)))
(define (ravager-try-bile-point! claims r-tag rx ry bx by cluster-hp force-field? current-frame pattern)
  (define max-biles : Integer
    (if force-field?
        1
        (min 3 (max 1 (safe-ceil-div (max 60.0 cluster-hp) 60.0)))))
  (define existing-near
    (for/sum : Integer ([c (in-list (spell-claims-point-claims claims))])
      (if (and (eq? (point-claim-ability c) 'corrosive-bile)
               (> (point-claim-expires-frame c) current-frame)
               (<= (dist2 bx by (point-claim-x c) (point-claim-y c)) 1.6))
          1
          0)))
  (cond
    [(>= existing-near max-biles) #f]
    [else
     (define d-off CORROSIVE-BILE-STAGGER-OFFSET)
     (define offsets : (Listof (Pairof Float Float))
       (list (cons 0.0 0.0)
             (cons d-off 0.0)
             (cons (- d-off) 0.0)
             (cons 0.0 d-off)
             (cons 0.0 (- d-off))
             (cons (* 0.707 d-off) (* 0.707 d-off))
             (cons (* -0.707 d-off) (* 0.707 d-off))))
     (for/or : (Option spell-directive) ([off (in-list offsets)])
       (define cx (clamp-coord (+ bx (car off))))
       (define cy (clamp-coord (+ by (cdr off))))
       (and (<= (dist2 rx ry cx cy) 9.0)
            (spell-claim-point?! claims 'corrosive-bile cx cy
                                 CORROSIVE-BILE-CLAIM-RADIUS
                                 current-frame
                                 CORROSIVE-BILE-CLAIM-TTL)
            (begin
              (hash-set! (spell-claims-ravager-bile-ready-frame claims)
                         r-tag
                         (+ current-frame CORROSIVE-BILE-COOLDOWN-FRAMES))
              (spell-directive r-tag 'ravager 'corrosive-bile 'point 0 cx cy pattern))))]))

(: infestor-neural-weight (-> Symbol Float))
(define (infestor-neural-weight sym)
  (case sym
    [(carrier mothership) 130.0]
    [(battlecruiser) 125.0]
    [(tempest) 118.0]
    [(thor thor-ap) 115.0]
    [(colossus) 112.0]
    [(archon) 108.0]
    [(siege-tank-sieged siege-tank) 104.0]
    [(immortal) 98.0]
    [(ultralisk) 95.0]
    [else 0.0]))

(: enemy-fungal-value-weight (-> Symbol Float))
(define (enemy-fungal-value-weight sym)
  (case sym
    [(mutalisk phoenix) 1.6]
    [(stalker blink-stalker adept hellion reaper) 1.45]
    [(marine zergling baneling medivac viking viking-fighter banshee) 1.3]
    [(high-templar ghost oracle hydralisk) 1.25]
    [else 1.0]))

(: enemy-air-capital-or-ranged? (-> Any Boolean))
(define (enemy-air-capital-or-ranged? e)
  (and (uh-flying? e)
       (not (memq (uh-type e)
                  '(overlord overlord-transport observer observer-siege-mode
                    overseer overseer-siege-mode parasitic-bomb-dummy
                    interceptor)))
       (sc2-enemy-unit-targetable? e)))

(: viper-abduct-weight (-> Symbol Float))
(define (viper-abduct-weight sym)
  (case sym
    [(siege-tank-sieged) 130.0]
    [(colossus) 125.0]
    [(thor thor-ap) 120.0]
    [(tempest) 115.0]
    [(carrier mothership) 112.0]
    [(battlecruiser) 110.0]
    [(lurker-burrowed lurker-mp-burrowed lurker lurker-mp) 106.0]
    [(liberator-ag liberator) 102.0]
    [(immortal) 98.0]
    [(viper) 95.0]
    [(siege-tank) 90.0]
    [else 0.0]))

(: viper-ranged-ground? (-> Any Boolean))
(define (viper-ranged-ground? e)
  (and (not (uh-flying? e))
       (>= (enemy-ground-range e) 2.0)
       (sc2-enemy-unit-targetable? e)))

(: zerg-consume-structure-weight (-> Any Float))
(define (zerg-consume-structure-weight b)
  (define t (uh-type b))
  (define hp (uh-total-hp b))
  (cond
    [(<= hp 450.0) 0.0]
    [(memq t '(creep-tumor creep-tumor-burrowed creep-tumor-queen
               larva egg cocoon spine-crawler spore-crawler)) 0.0]
    [(memq t '(evolution-chamber roach-warren baneling-nest spawning-pool)) (+ 120.0 (* 0.05 hp))]
    [(memq t '(hatchery lair hive spire greater-spire infestation-pit
               hydralisk-den lurker-den ultralisk-cavern)) (+ 90.0 (* 0.05 hp))]
    [(memq t '(extractor extractor-rich)) (+ 80.0 (* 0.05 hp))]
    [else 0.0]))

(define ZERG-CASTER-SYMS : (Listof Symbol)
  '(queen ravager infestor infestor-burrowed viper corruptor
    overseer overseer-siege-mode swarm-host swarm-host-mp
    lurker lurker-mp lurker-burrowed lurker-mp-burrowed))

(define TERRAN-CASTER-SYMS : (Listof Symbol)
  '(ghost raven battlecruiser medivac cyclone))

(define PROTOSS-CASTER-SYMS : (Listof Symbol)
  '(sentry high-templar oracle phoenix disruptor))

(: run-zerg-spellcaster-micro
   (-> (Listof Any) (Listof Any) (Listof Any) spell-claims Integer
       (Listof Any) (Listof Any) (Listof Any) Float Float Float Float
       (Listof Integer) (Listof Integer)
       (Listof spell-directive)))
(define (run-zerg-spellcaster-micro
         caster-units ally-units enemy-units
         claims current-frame ally-buildings enemy-buildings effects
         home-x home-y enemy-base-x enemy-base-y
         inject-queen-tags exclude-tags)
  (define all-enemies (if (null? enemy-buildings) enemy-units (append enemy-units enemy-buildings)))
  (define all-allies (if (null? ally-buildings) ally-units (append ally-units ally-buildings)))

  (define-values (dirs-rev _)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used-tags : (Listof Integer) exclude-tags])
              ([u (in-list caster-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used-tags))
         (values acc used-tags)]
        [else
         (define ux (uh-x u))
         (define uy (uh-y u))
         (define en (uh-energy u))
         (define dir : (Option spell-directive)
           (case sym
             ;; --- QUEEN ---
             [(queen)
              (define transfuse-d : (Option spell-directive)
                (and (>= en SC2-QUEEN-TRANSFUSION-ENERGY)
                     (let-values ([(ok? tgt _w)
                                   (best-unit-target
                                    ux uy 7.0 all-allies
                                    (lambda ([a : Any])
                                      (and (not (= (uh-tag a) tag))
                                           (not (uh-hallucination? a))
                                           (> (queen-transfuse-priority (uh-type a)) 0.0)
                                           (>= (uh-missing-hp a) 65.0)
                                           (< (uh-hp-ratio a) 0.65)))
                                    (lambda ([a : Any])
                                      (+ (queen-transfuse-priority (uh-type a))
                                         (* 30.0 (- 1.0 (uh-hp-ratio a)))
                                         (min 40.0 (* 0.25 (uh-missing-hp a))))))])
                       (and ok?
                            (let ([ttag (uh-tag tgt)])
                              (and (spell-claim-unit?!
                                    claims 'transfusion ttag current-frame UNIT-SPELL-CLAIM-TTL
                                    #:caster-tag tag #:missing-hp (uh-missing-hp tgt))
                                   (spell-directive tag 'queen 'transfusion 'unit ttag
                                                    (uh-x tgt) (uh-y tgt) 'queen-transfuse)))))))
              (or transfuse-d
                  ;; 2. Inject Larva for designated inject Queens when energy >= 25.0
                  (and (not (not (memv tag inject-queen-tags)))
                       (>= en 25.0)
                       (let-values ([(ok? th _w)
                                     (best-unit-target
                                      ux uy 11.0 ally-buildings
                                      (lambda ([b : Any])
                                        (and (memq (uh-type b) SC2-TOWNHALL-STRUCTURE-SYMS)
                                             (not (uh-has-buff? b 'queen-spawn-larva-timer))
                                             (= (spell-unit-claim-count claims 'inject-larva (uh-tag b) current-frame) 0)))
                                      (lambda ([b : Any])
                                        (- 100.0 (dist2 ux uy (uh-x b) (uh-y b)))))])
                         (and ok?
                              (let ([btag (uh-tag th)])
                                (and (spell-claim-unit?! claims 'inject-larva btag current-frame 64 #:caster-tag tag)
                                     (spell-directive tag 'queen 'inject-larva 'unit btag
                                                      (uh-x th) (uh-y th) 'queen-inject-larva))))))
                  ;; 3. Creep Tumor spread (only off-inject or >= 100 energy, safe > 14 tiles)
                  (let* ([inject? (and (memv tag inject-queen-tags) #t)]
                         [tumor-en-min (if inject? 100.0 (->float SC2-QUEEN-TUMOR-ENERGY))])
                    (and (>= en tumor-en-min)
                         (not (any-unit-within? all-enemies ux uy 14.0 sc2-enemy-unit-targetable?))
                         (let* ([dx (- enemy-base-x ux)]
                                [dy (- enemy-base-y uy)]
                                [dlen (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                [tx (clamp-coord (+ ux (* 3.0 (/ dx dlen))))]
                                [ty (clamp-coord (+ uy (* 3.0 (/ dy dlen))))]
                                [tumor-nearby?
                                 (any-unit-within?
                                  all-allies tx ty 2.8
                                  (lambda ([b : Any])
                                    (and (memq (uh-type b)
                                               '(creep-tumor creep-tumor-burrowed creep-tumor-queen))
                                         #t)))])
                           (and (not tumor-nearby?)
                                (spell-claim-point?! claims 'spawn-creep-tumor tx ty 3.5 current-frame 64)
                                (spell-directive tag 'queen 'spawn-creep-tumor 'point 0 tx ty
                                                 'queen-creep-tumor))))))]

             ;; --- RAVAGER ---
             [(ravager)
              (define bile-unlock (hash-ref (spell-claims-ravager-bile-ready-frame claims) tag (lambda () -1)))
              (define explicit-ready? (not (eq? (dyn-hash-ref u 'bile-ready? #t) #f)))
              (define explicit-cd (safe-int (dyn-hash-ref u 'corrosive-bile-cooldown 0) 0))
              (define ready? (and explicit-ready? (<= explicit-cd 0) (>= current-frame bile-unlock)))
              (and ready?
                   ;; Priority 1: Fungal -> Bile guaranteed 60-damage combo
                   (or (let-values ([(ok? fx fy _s)
                                     (best-enemy-cluster
                                      ux uy 9.0 enemy-units 1.5 0.0
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define fungal-cnt
                                          (for/sum : Integer ([e (in-list cl)])
                                            (if (or (uh-has-buff? e 'fungal-growth)
                                                    (unit-inside-point-claim? claims 'fungal-growth (uh-x e) (uh-y e) 0.5 current-frame)
                                                    (any-effect-within? effects 'fungal-growth (uh-x e) (uh-y e) 2.5 (lambda ([_ef : Any]) #t)))
                                                1 0)))
                                        (if (> fungal-cnt 0)
                                            (+ (* 100.0 (->float fungal-cnt)) (* 10.0 (->float (length cl))))
                                            0.0)))])
                         (and ok?
                              (let ([hp-sum (sum-hp-within enemy-units fx fy 1.6)])
                                (ravager-try-bile-point! claims tag ux uy fx fy hp-sum #f current-frame
                                                         'ravager-fungal-bile-combo))))
                       ;; Priority 2: Enemy Force Fields
                       (for/or : (Option spell-directive) ([eff (in-list effects)])
                         (and (hash? eff)
                              (eq? (effect-type eff) 'force-field)
                              (not (effect-friendly? eff))
                              (<= (dist2 ux uy (uh-x eff) (uh-y eff)) 9.0)
                              (ravager-try-bile-point! claims tag ux uy (uh-x eff) (uh-y eff) 60.0 #t current-frame
                                                       'ravager-force-field-shatter)))
                       ;; Priority 2b: Enemy Siege / Static Defense targets
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 9.0 all-enemies zerg-bile-siege-or-static?
                                      (lambda ([e : Any])
                                        (case (uh-type e)
                                          [(siege-tank-sieged) 130.0]
                                          [(liberator-ag) 125.0]
                                          [(lurker-burrowed lurker-mp-burrowed) 120.0]
                                          [(warp-prism-phasing) 115.0]
                                          [(bunker photon-cannon shield-battery) 100.0]
                                          [else 85.0])))])
                         (and ok?
                              (ravager-try-bile-point! claims tag ux uy (uh-x tgt) (uh-y tgt) (uh-total-hp tgt) #f
                                                       current-frame 'ravager-siege-static-bile)))
                       ;; Priority 3: Velocity-led ground clumps (>= 2 within 1.5 tiles)
                       (let-values ([(ok? bx by _s)
                                     (best-enemy-cluster
                                      ux uy 9.0
                                      (filter (lambda ([e : Any]) (and (hash? e) (not (uh-flying? e)))) enemy-units)
                                      1.5 1.1
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (if (>= (length cl) 2)
                                            (+ (* 30.0 (->float (length cl)))
                                               (* 0.1 (sum-units-fl cl uh-total-hp)))
                                            0.0)))])
                         (and ok?
                              (let ([hp-sum (sum-hp-within enemy-units bx by 1.6)])
                                (ravager-try-bile-point! claims tag ux uy bx by hp-sum #f current-frame
                                                         'ravager-clump-bile))))))]

             ;; --- INFESTOR ---
             [(infestor infestor-burrowed)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [(eq? sym 'infestor-burrowed)
                 ;; Burrowed Infestor can still safely channel Neural Parasite
                 (define friendly-army-near?
                   (any-unit-within? ally-units ux uy 11.0
                                     (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a)))))
                 (and (>= en SC2-INFESTOR-NEURAL-ENERGY)
                      friendly-army-near?
                      (let-values ([(ok? tgt _w)
                                    (best-unit-target
                                     ux uy SC2-INFESTOR-NEURAL-CAST-RANGE enemy-units
                                     (lambda ([e : Any])
                                       (and (not (uh-has-buff? e 'neural-parasite))
                                            (> (infestor-neural-weight (uh-type e)) 0.0)))
                                     (lambda ([e : Any]) (infestor-neural-weight (uh-type e))))])
                        (and ok?
                             (spell-claim-unit?! claims 'neural-parasite (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                 #:caster-tag tag)
                             (spell-directive tag sym 'neural-parasite 'unit (uh-tag tgt)
                                              (uh-x tgt) (uh-y tgt) 'infestor-neural))))]
                [else
                 (define friendly-army-near?
                   (any-unit-within? ally-units ux uy 11.0
                                     (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a)))))
                 (or
                  ;; 1. Fungal Growth (`0.5`-tile velocity lead, `r=2.25 ttl=32`)
                  (and (>= en SC2-INFESTOR-FUNGAL-ENERGY)
                       (let-values ([(ok? fx fy _s)
                                     (best-enemy-cluster
                                      ux uy SC2-INFESTOR-FUNGAL-CAST-RANGE enemy-units 2.25 0.5
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define unbuffed
                                          (for/list : (Listof Any) ([e (in-list cl)]
                                                                    #:when (not (uh-has-buff? e 'fungal-growth)))
                                            e))
                                        (if (and (>= (length unbuffed) 2)
                                                 (not (spell-point-claimed? claims 'fungal-growth cx cy FUNGAL-CLAIM-RADIUS current-frame)))
                                            (sum-units-fl unbuffed
                                                          (lambda ([e : Any])
                                                            (* 25.0 (enemy-fungal-value-weight (uh-type e)))))
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'fungal-growth fx fy FUNGAL-CLAIM-RADIUS current-frame FUNGAL-CLAIM-TTL)
                              (spell-directive tag 'infestor 'fungal-growth 'point 0 fx fy 'infestor-fungal))))
                  ;; 2. Neural Parasite (`energy >= 100`, range `9.0`, friendly army `< 11.0`)
                  (and (>= en SC2-INFESTOR-NEURAL-ENERGY)
                       friendly-army-near?
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy SC2-INFESTOR-NEURAL-CAST-RANGE enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-has-buff? e 'neural-parasite))
                                             (> (infestor-neural-weight (uh-type e)) 0.0)))
                                      (lambda ([e : Any]) (infestor-neural-weight (uh-type e))))])
                         (and ok?
                              (spell-claim-unit?! claims 'neural-parasite (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'infestor 'neural-parasite 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'infestor-neural))))
                  ;; 3. Microbial Shroud vs >= 3 air threats over friendly ground army cluster
                  (and (>= en 75.0)
                       (>= (count-units-within enemy-units ux uy 14.0 enemy-air-capital-or-ranged?) 3)
                       (let-values ([(ok? sx sy _cnt)
                                     (for/fold ([f? : Boolean #f] [bx : Float 0.0] [by : Float 0.0] [bc : Integer 2])
                                               ([a (in-list ally-units)]
                                                #:when (and (hash? a)
                                                            (not (uh-flying? a))
                                                            (unit-combat-relevant? a)
                                                            (<= (dist2 ux uy (uh-x a) (uh-y a)) 9.0)))
                                       (define ax (uh-x a))
                                       (define ay (uh-y a))
                                       (define cnt
                                         (count-units-within
                                          ally-units ax ay 3.5
                                          (lambda ([b : Any]) (and (not (uh-flying? b)) (unit-combat-relevant? b)))))
                                       (if (and (> cnt bc)
                                                (not (spell-point-claimed? claims 'microbial-shroud ax ay MICROBIAL-SHROUD-CLAIM-RADIUS current-frame)))
                                           (values #t ax ay cnt)
                                           (values f? bx by bc)))])
                         (and ok?
                              (spell-claim-point?! claims 'microbial-shroud sx sy MICROBIAL-SHROUD-CLAIM-RADIUS current-frame MICROBIAL-SHROUD-CLAIM-TTL)
                              (spell-directive tag 'infestor 'microbial-shroud 'point 0 sx sy 'infestor-microbial-shroud))))
                  ;; 4. Low-energy (< 70, non-channeling) 10.0-tile retreat when threatened
                  (and (< en 70.0)
                       (any-unit-within? all-enemies ux uy 12.0 sc2-enemy-unit-targetable?)
                       (let-values ([(rx ry) (safe-retreat-point ux uy all-enemies home-x home-y 10.0)])
                         (spell-directive tag 'infestor 'move 'kite 0 rx ry 'infestor-low-energy-retreat))))])]

             ;; --- VIPER ---
             [(viper)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. Blinding Cloud on >= 2 ground ranged clumps (`range 11.0`)
                  (and (>= en 100.0)
                       (let-values ([(ok? cx cy _s)
                                     (best-enemy-cluster
                                      ux uy 11.0 enemy-units 2.0 0.0
                                      (lambda ([px : Float] [py : Float] [cl : (Listof Any)])
                                        (define rcnt
                                          (for/sum : Integer ([e (in-list cl)])
                                            (if (and (viper-ranged-ground? e)
                                                     (not (uh-has-buff? e 'blinding-cloud)))
                                                1 0)))
                                        (if (and (>= rcnt 2)
                                                 (not (spell-point-claimed? claims 'blinding-cloud px py BLINDING-CLOUD-CLAIM-RADIUS current-frame)))
                                            (->float rcnt)
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'blinding-cloud cx cy BLINDING-CLOUD-CLAIM-RADIUS current-frame BLINDING-CLOUD-CLAIM-TTL)
                              (spell-directive tag 'viper 'blinding-cloud 'point 0 cx cy 'viper-blinding-cloud))))
                  ;; 2. Abduct into >= 4 friendly combat units within 7.0 (`energy >= 75`, `range 9.0`)
                  (and (>= en 75.0)
                       (>= (count-units-within ally-units ux uy 7.0
                                               (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a))))
                           4)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 9.0 enemy-units
                                      (lambda ([e : Any]) (> (viper-abduct-weight (uh-type e)) 0.0))
                                      (lambda ([e : Any]) (viper-abduct-weight (uh-type e))))])
                         (and ok?
                              (spell-claim-unit?! claims 'abduct (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'viper 'abduct 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'viper-abduct))))
                  ;; 3. Parasitic Bomb on >= 3 air units without nearby `824` dummy or active bomb
                  (and (>= en 125.0)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 8.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (enemy-air-capital-or-ranged? e)
                                             (not (uh-has-buff? e 'parasitic-bomb))
                                             (>= (count-units-within enemy-units (uh-x e) (uh-y e) 3.0 enemy-air-capital-or-ranged?) 3)
                                             (not (any-unit-within?
                                                   enemy-units (uh-x e) (uh-y e) 4.0
                                                   (lambda ([d : Any])
                                                     (or (eq? (uh-type d) 'parasitic-bomb-dummy)
                                                         (= (safe-int (dyn-hash-ref d 'unit-type-id 0) 0) 824)
                                                         (= (safe-int (dyn-hash-ref d 'type 0) 0) 824)
                                                         (uh-has-buff? d 'parasitic-bomb)))))
                                             (not (spell-point-claimed? claims 'parasitic-bomb-zone (uh-x e) (uh-y e) 3.5 current-frame))))
                                      (lambda ([e : Any])
                                        (+ (* 20.0 (->float (count-units-within enemy-units (uh-x e) (uh-y e) 3.0 enemy-air-capital-or-ranged?)))
                                           (min 100.0 (* 0.2 (uh-total-hp e))))))])
                         (and ok?
                              (spell-claim-unit?! claims 'parasitic-bomb (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (begin
                                (spell-claim-point?! claims 'parasitic-bomb-zone (uh-x tgt) (uh-y tgt) 3.5 current-frame 64)
                                (spell-directive tag 'viper 'parasitic-bomb 'unit (uh-tag tgt)
                                                 (uh-x tgt) (uh-y tgt) 'viper-parasitic-bomb)))))
                  ;; 4. Safe Consume (`energy < 60`, `0` enemies within `12.0`, Zerg building `hp > 450`)
                  (and (< en 60.0)
                       (not (any-unit-within? all-enemies ux uy 12.0 sc2-enemy-unit-targetable?))
                       (let-values ([(ok? bldg _w)
                                     (best-unit-target
                                      ux uy 25.0 (append ally-buildings ally-units)
                                      (lambda ([b : Any]) (> (zerg-consume-structure-weight b) 0.0))
                                      (lambda ([b : Any])
                                        (- (zerg-consume-structure-weight b)
                                           (* 1.5 (dist2 ux uy (uh-x b) (uh-y b))))))])
                         (and ok?
                              (spell-claim-unit?! claims 'viper-consume (uh-tag bldg) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'viper 'viper-consume 'unit (uh-tag bldg)
                                               (uh-x bldg) (uh-y bldg) 'viper-safe-consume)))))])]

             ;; --- CORRUPTOR ---
             [(corruptor)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (let-values ([(ok? th _w)
                               (best-unit-target
                                ux uy 6.0 all-enemies
                                (lambda ([e : Any]) (and (memq (uh-type e) SC2-TOWNHALL-STRUCTURE-SYMS) #t))
                                (lambda ([e : Any]) (uh-total-hp e)))])
                   (and ok?
                        (not (any-unit-within? all-enemies ux uy 11.0 enemy-anti-air-or-air-threat?))
                        (spell-directive tag 'corruptor 'caustic-spray 'unit (uh-tag th)
                                         (uh-x th) (uh-y th) 'corruptor-caustic-spray)))])]

             ;; --- OVERSEER (Contaminate 1825/182, SpawnChangeling 181, Oversight 3745/1912) ---
             [(overseer overseer-siege-mode)
              (define aa-near? (any-unit-within? all-enemies ux uy 10.8 enemy-anti-air-or-air-threat?))
              (define oversight-wanted? (eq? (dyn-hash-ref u 'oversight-desired? #f) #t))
              (: contam-weight (-> Any Float))
              (define (contam-weight b)
                (define bt (uh-type b))
                (cond
                  [(memq bt '(twilight-council forge cybernetics-core robotics-bay templar-archive
                              fleet-beacon dark-shrine engineering-bay armory fusion-core
                              ghost-academy barracks-techlab factory-techlab starport-techlab
                              evolution-chamber spire greater-spire infestation-pit baneling-nest
                              roach-warren spawning-pool hydralisk-den lurker-den lurker-den-mp))
                   160.0]
                  [(memq bt '(robotics-facility stargate starport factory gateway warp-gate barracks))
                   125.0]
                  [(memq bt SC2-TOWNHALL-STRUCTURE-SYMS) 90.0]
                  [else 0.0]))
              (cond
                [(and (eq? sym 'overseer-siege-mode) aa-near?)
                 (spell-directive tag sym 'morph-overseer-mode 'none 0 ux uy 'overseer-unmorph-mobile-follow)]
                [else
                 (or
                  (and oversight-wanted?
                       (eq? sym 'overseer)
                       (not aa-near?)
                       (spell-directive tag sym 'morph-oversight-mode 'none 0 ux uy 'overseer-oversight-ring-watch))
                  ;; 1. Contaminate enemy upgrade / tech / production building (`en >= 125`, range `7.0`)
                  (and (>= en 125.0)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 7.0 enemy-buildings
                                      (lambda ([b : Any])
                                        (and (> (contam-weight b) 0.0)
                                             (not (uh-has-buff? b 'contaminate))
                                             (= (spell-unit-claim-count claims 'contaminate (uh-tag b) current-frame) 0)))
                                      contam-weight)])
                         (and ok?
                              (let ([btag (uh-tag tgt)])
                                (and (spell-claim-unit?! claims 'contaminate btag current-frame 64 #:caster-tag tag)
                                     (spell-directive tag sym 'contaminate 'unit btag
                                                      (uh-x tgt) (uh-y tgt) 'overseer-contaminate-upgrade-tech))))))
                  ;; 2. Spawn Changeling (`en >= 50`)
                  (and (>= en 50.0)
                       (spell-claim-unit?! claims 'spawn-changeling tag current-frame 16 #:caster-tag tag)
                       (spell-directive tag sym 'spawn-changeling 'none 0 ux uy 'overseer-changeling-ramp-block))
                  ;; 3. Oversight static vision anchor when `< 50` energy and safe from AA
                  (and (eq? sym 'overseer)
                       (not aa-near?)
                       (> (dist2 ux uy home-x home-y) 8.0)
                       (spell-directive tag sym 'morph-oversight-mode 'none 0 ux uy 'overseer-oversight-ring-watch)))])]

             ;; --- SWARM HOST (Spawn Locusts 1990) ---
             [(swarm-host swarm-host-mp)
              (define ready?
                (and (not (spellcaster-channel-protected? u))
                     (not (eq? (dyn-hash-ref u 'locusts-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'spawn-locusts-cooldown 0) 0) 0)))
              (and ready?
                   (let-values ([(ok? lx ly _s)
                                 (best-enemy-cluster
                                  ux uy 24.0 all-enemies 4.0 0.0
                                  (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                    (if (spell-point-claimed? claims 'spawn-locusts cx cy 4.0 current-frame)
                                        0.0
                                        (+ (* 20.0 (->float (length cl)))
                                           (* 0.05 (sum-units-fl cl uh-total-hp))))))])
                     (and ok?
                          (spell-claim-point?! claims 'spawn-locusts lx ly 4.0 current-frame 32)
                          (spell-directive tag sym 'spawn-locusts 'point 0 lx ly 'swarm-host-locust-wave-base))))]

             ;; --- LURKER (Burrow 2108 / Unburrow 2110) ---
             [(lurker lurker-mp lurker-burrowed lurker-mp-burrowed)
              (: ground-enemy? (-> Any Boolean))
              (define (ground-enemy? e)
                (and (sc2-enemy-unit-targetable? e) (not (uh-flying? e))))
              (cond
                [(memq sym '(lurker lurker-mp))
                 (and (not (spellcaster-channel-protected? u))
                      (any-unit-within? enemy-units ux uy 9.5 ground-enemy?)
                      (spell-directive tag sym 'burrow-lurker 'none 0 ux uy 'lurker-burrow-choke-siege))]
                [else
                 (define hazard?
                   (or (any-effect-within? effects 'purification-nova ux uy 3.5 (lambda ([_ef : Any]) #t))
                       (any-effect-within? effects 'psi-storm ux uy 3.0 (lambda ([_ef : Any]) #t))
                       (any-effect-within? effects 'corrosive-bile ux uy 2.5 (lambda ([_ef : Any]) #t))))
                 (define idle-frames (safe-int (dyn-hash-ref u 'burrowed-idle-frames 0) 0))
                 (and (or hazard?
                          (and (>= idle-frames 24)
                               (not (any-unit-within? enemy-units ux uy 13.0 ground-enemy?))))
                      (spell-directive tag sym 'unburrow-lurker 'none 0 ux uy 'lurker-unburrow-reposition))])]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used-tags))
             (values acc used-tags))])))
  (reverse dirs-rev))

;; Plan #115-calibrated Zerg spellcaster micro (`queen`, `ravager`, `infestor`,
;; `viper`, `corruptor`) while preserving delta-f = 0 invariants via `claims`.
(: plan-zerg-spellcaster-micro
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:home-x Float
         #:home-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:inject-queen-tags (Listof Integer)
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-zerg-spellcaster-micro
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:inject-queen-tags [inject-queen-tags '()]
         #:exclude-tags [exclude-tags '()])
  (define casters
    (for/fold ([acc : (Listof Any) '()] #:result (reverse acc))
              ([u (in-list ally-units)]
               #:when (hash? u))
      (define sym (uh-type u))
      (if (memq sym ZERG-CASTER-SYMS)
          (let ([t (uh-tag u)])
            (if (and (> t 0) (not (memv t exclude-tags)))
                (cons u acc)
                acc))
          acc)))
  (if (null? casters)
      '()
      (run-zerg-spellcaster-micro
       casters ally-units enemy-units claims current-frame
       ally-buildings enemy-buildings effects home-x home-y
       enemy-base-x enemy-base-y inject-queen-tags exclude-tags)))

;; -----------------------------------------------------------------------------
;; 7. Terran Spellcaster Patterns (Ghost, Raven, Battlecruiser)
;; -----------------------------------------------------------------------------

(: ghost-emp-target-bonus (-> Any Float))
(define (ghost-emp-target-bonus e)
  (define sh (uh-shields e))
  (define caster?
    (and (memq (uh-type e) '(high-templar sentry oracle archon infestor viper ghost raven))
         (>= (+ (uh-energy e) sh) 40.0)))
  (if (or (> sh 0.0) caster?)
      (+ sh (if caster? 80.0 0.0))
      0.0))

(: ghost-snipe-weight (-> Any Float))
(define (ghost-snipe-weight e)
  (case (uh-type e)
    [(lurker-burrowed lurker-mp-burrowed lurker lurker-mp) 130.0]
    [(viper) 128.0]
    [(infestor infestor-burrowed) 124.0]
    [(brood-lord) 120.0]
    [(ultralisk) 115.0]
    [(ravager) 105.0]
    [(high-templar ghost) 100.0]
    [(queen) 95.0]
    [else 0.0]))

(: raven-matrix-weight (-> Any Float))
(define (raven-matrix-weight e)
  (case (uh-type e)
    [(colossus) 130.0]
    [(siege-tank-sieged) 128.0]
    [(carrier mothership tempest) 124.0]
    [(battlecruiser) 122.0]
    [(thor thor-ap) 118.0]
    [(infestor viper high-templar) 112.0]
    [(archon immortal) 105.0]
    [(siege-tank raven ghost warp-prism warp-prism-phasing) 95.0]
    [else 0.0]))

(: bc-yamato-weight (-> Any Float))
(define (bc-yamato-weight e)
  (case (uh-type e)
    [(carrier mothership) 130.0]
    [(battlecruiser) 126.0]
    [(tempest) 122.0]
    [(thor thor-ap) 118.0]
    [(corruptor viper) 112.0]
    [(viking viking-fighter) 106.0]
    [(infestor archon) 102.0]
    [(high-templar) 96.0]
    [(stalker) 88.0]
    [else 0.0]))

(: terran-upgrade-ready? (-> (Listof Any) Symbol Boolean Boolean))
(define (terran-upgrade-ready? upgrades target-sym fallback-flag)
  (if (null? upgrades)
      fallback-flag
      (or fallback-flag
          (for/or : Boolean ([up (in-list upgrades)])
            (eq? (safe-sym up 'unknown) target-sym)))))

(: run-terran-spellcaster-micro
   (-> (Listof Any) (Listof Any) (Listof Any) spell-claims Integer
       (Listof Any) (Listof Any) (Listof Any) (Listof Any) Boolean Float Float
       (Listof Integer)
       (Listof spell-directive)))
(define (run-terran-spellcaster-micro
         caster-units ally-units enemy-units
         claims current-frame ally-buildings enemy-buildings _effects
         researched-upgrades yamato-researched? home-x home-y exclude-tags)
  (define all-enemies (if (null? enemy-buildings) enemy-units (append enemy-units enemy-buildings)))
  (define yamato-ok? (terran-upgrade-ready? researched-upgrades 'weapon-refit yamato-researched?))

  (define-values (dirs-rev _)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used-tags : (Listof Integer) exclude-tags])
              ([u (in-list caster-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used-tags))
         (values acc used-tags)]
        [else
         (define ux (uh-x u))
         (define uy (uh-y u))
         (define en (uh-energy u))
         (define dir : (Option spell-directive)
           (case sym
             ;; --- GHOST ---
             [(ghost)
              (cond
                [(snipe-channel-locked? claims u current-frame) #f]
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. EMP Round (`energy >= 75`, `r=2.0 ttl=24`, >= 180 shields or key casters)
                  (and (>= en 75.0)
                       (let-values ([(ok? ex ey _s)
                                     (best-enemy-cluster
                                      ux uy 10.0 enemy-units 2.0 0.25
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define shield-sum
                                          (sum-units-fl cl uh-shields))
                                        (define has-priority-caster?
                                          (for/or : Boolean ([e (in-list cl)])
                                            (and (memq (uh-type e)
                                                       '(high-templar sentry oracle archon infestor viper ghost raven))
                                                 (>= (+ (uh-energy e) (uh-shields e)) 40.0))))
                                        (if (and (or (>= shield-sum 180.0) has-priority-caster?)
                                                 (not (spell-point-claimed? claims 'emp-round cx cy EMP-CLAIM-RADIUS current-frame)))
                                            (sum-units-fl cl ghost-emp-target-bonus)
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'emp-round ex ey EMP-CLAIM-RADIUS current-frame EMP-CLAIM-TTL)
                              (spell-directive tag 'ghost 'emp-round 'point 0 ex ey 'ghost-emp))))
                  ;; 2. Snipe / Steady Targeting (`energy >= 50`, ZERO enemies `< 4.5` tiles, HP-capped + `34f` lock)
                  (and (>= en 50.0)
                       (not (any-unit-within? all-enemies ux uy 4.499 sc2-enemy-unit-targetable?))
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-hallucination? e))
                                             (> (ghost-snipe-weight e) 0.0)))
                                      (lambda ([e : Any]) (ghost-snipe-weight e)))])
                         (and ok?
                              (spell-claim-unit?!
                               claims 'steady-targeting (uh-tag tgt) current-frame SNIPE-CHANNEL-LOCKOUT-FRAMES
                               #:caster-tag tag #:target-hp (uh-total-hp tgt))
                              (begin
                                (lock-ghost-snipe-channel! claims tag current-frame SNIPE-CHANNEL-LOCKOUT-FRAMES)
                                (spell-directive tag 'ghost 'steady-targeting 'unit (uh-tag tgt)
                                                 (uh-x tgt) (uh-y tgt) 'ghost-snipe)))))
                  ;; 3. Ghost Cloak (`energy >= 50`, engaging `< 10.0`, no enemy detector `< 11.0`)
                  (and (>= en 50.0)
                       (not (uh-cloaked? u))
                       (> (- current-frame (hash-ref (spell-claims-ghost-cloak-frame claims) tag (lambda () -10000))) 20)
                       (any-unit-within? enemy-units ux uy 10.0 sc2-enemy-unit-targetable?)
                       (not (enemy-detector-within? enemy-units enemy-buildings ux uy 10.999))
                       (begin
                         (hash-set! (spell-claims-ghost-cloak-frame claims) tag current-frame)
                         (spell-directive tag 'ghost 'cloak-ghost 'none 0 ux uy 'ghost-cloak))))])]

             ;; --- RAVEN ---
             [(raven)
              (or
               ;; 1. Interference Matrix (`energy >= 75`, `range 9.0`, 1/target)
               (and (>= en 75.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 9.0 enemy-units
                                   (lambda ([e : Any])
                                     (and (not (uh-hallucination? e))
                                          (not (uh-has-buff? e 'interference-matrix))
                                          (> (raven-matrix-weight e) 0.0)))
                                   (lambda ([e : Any]) (raven-matrix-weight e)))])
                      (and ok?
                           (spell-claim-unit?! claims 'interference-matrix (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                               #:caster-tag tag)
                           (spell-directive tag 'raven 'interference-matrix 'unit (uh-tag tgt)
                                            (uh-x tgt) (uh-y tgt) 'raven-interference-matrix))))
               ;; 2. Anti-Armor Missile (`energy >= 75`, `>= 5` clump & `>= 6` allies firing)
               (and (>= en 75.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 10.0 enemy-units
                                   (lambda ([e : Any])
                                     (define ex (uh-x e))
                                     (define ey (uh-y e))
                                     (and (sc2-enemy-unit-targetable? e)
                                          (not (uh-has-buff? e 'anti-armor-missile))
                                          (>= (count-units-within enemy-units ex ey 2.88 sc2-enemy-unit-targetable?) 5)
                                          (>= (count-units-within ally-units ex ey 11.0 unit-combat-relevant?) 6)
                                          (not (spell-point-claimed? claims 'anti-armor-missile ex ey ANTI-ARMOR-CLAIM-RADIUS current-frame))))
                                   (lambda ([e : Any])
                                     (->float (count-units-within enemy-units (uh-x e) (uh-y e) 2.88 sc2-enemy-unit-targetable?))))])
                      (and ok?
                           (spell-claim-unit?! claims 'anti-armor-missile (uh-tag tgt) current-frame ANTI-ARMOR-CLAIM-TTL
                                               #:caster-tag tag)
                           (spell-claim-point?! claims 'anti-armor-missile (uh-x tgt) (uh-y tgt)
                                                ANTI-ARMOR-CLAIM-RADIUS current-frame ANTI-ARMOR-CLAIM-TTL)
                           (spell-directive tag 'raven 'anti-armor-missile 'unit (uh-tag tgt)
                                            (uh-x tgt) (uh-y tgt) 'raven-anti-armor-missile))))
               ;; 3. Auto-Turret (`energy >= 50`, harass workers / melee / engaged zone)
               (and (>= en 50.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 8.0 enemy-units
                                   (lambda ([e : Any])
                                     (or (and (memq (uh-type e) '(scv probe drone zergling zealot adept baneling dark-templar)) #t)
                                         (>= (count-units-within enemy-units (uh-x e) (uh-y e) 3.5 sc2-enemy-unit-targetable?) 2)))
                                   (lambda ([e : Any])
                                     (if (memq (uh-type e) '(scv probe drone))
                                         110.0
                                         (->float (* 20 (count-units-within enemy-units (uh-x e) (uh-y e) 3.5 sc2-enemy-unit-targetable?))))))])
                      (and ok?
                           (let* ([dx (- (uh-x tgt) ux)]
                                  [dy (- (uh-y tgt) uy)]
                                  [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                  [cast-d (min 2.5 (max 0.5 (- d 0.75)))]
                                  [tx (clamp-coord (+ ux (* cast-d (/ dx d))))]
                                  [ty (clamp-coord (+ uy (* cast-d (/ dy d))))])
                             (and (spell-claim-point?! claims 'auto-turret tx ty 2.5 current-frame 64)
                                  (spell-directive tag 'raven 'auto-turret 'point 0 tx ty 'raven-auto-turret)))))))]

             ;; --- BATTLECRUISER ---
             [(battlecruiser)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (define jump-ready? (not (eq? (dyn-hash-ref u 'tactical-jump-ready? #t) #f)))
                 (define yam-ready? (and yamato-ok? (not (eq? (dyn-hash-ref u 'yamato-ready? #t) #f))))
                 (or
                  ;; 1. Emergency Tactical Jump home when HP ratio < 0.32
                  (and jump-ready?
                       (< (uh-hp-ratio u) 0.32)
                       (> (dist2 ux uy home-x home-y) 12.0)
                       (spell-directive tag 'battlecruiser 'tactical-jump 'point 0 home-x home-y
                                        'bc-emergency-tactical-jump))
                  ;; 2. Yamato Cannon (`ceil(hp/240)` claim cap)
                  (and yam-ready?
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-hallucination? e))
                                             (> (bc-yamato-weight e) 0.0)))
                                      (lambda ([e : Any]) (bc-yamato-weight e)))])
                         (and ok?
                              (spell-claim-unit?! claims 'yamato-cannon (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag #:target-hp (uh-total-hp tgt))
                              (spell-directive tag 'battlecruiser 'yamato-cannon 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'bc-yamato-snipe))))
                  ;; 3. Offensive Tactical Jump onto undefended remote worker line when healthy (>=85% HP, no threat <16)
                  (and jump-ready?
                       (>= (uh-hp-ratio u) 0.85)
                       (not (any-unit-within? all-enemies ux uy 16.0 sc2-enemy-unit-targetable?))
                       (let-values ([(ok? jx jy _s)
                                     (best-enemy-cluster
                                      ux uy 220.0 enemy-units 4.0 0.0
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define workers
                                          (for/sum : Integer ([e (in-list cl)])
                                            (if (memq (uh-type e) '(scv probe drone)) 1 0)))
                                        (if (and (>= workers 3)
                                                 (> (dist2 ux uy cx cy) 25.0)
                                                 (not (any-unit-within? all-enemies cx cy 11.0 enemy-anti-air-or-air-threat?))
                                                 (not (spell-point-claimed? claims 'tactical-jump cx cy 6.0 current-frame)))
                                            (->float workers)
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'tactical-jump jx jy 6.0 current-frame 64)
                              (spell-directive tag 'battlecruiser 'tactical-jump 'point 0 jx jy
                                               'bc-tactical-jump-backstab)))))])]

             ;; --- MEDIVAC (Boost 2116 / Heal 386 / Low-HP Retreat) ---
             [(medivac)
              (define boost-ready?
                (and (not (eq? (dyn-hash-ref u 'boost-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'boost-cooldown 0) 0) 0)))
              (define cargo-cnt (safe-int (dyn-hash-ref u 'cargo-count 0) 0))
              (define hp-rat (uh-hp-ratio u))
              (define danger-near? (any-unit-within? all-enemies ux uy 9.5 enemy-anti-air-or-air-threat?))
              (or
               (and boost-ready?
                    (or (> cargo-cnt 0)
                        (and (< hp-rat 0.45) danger-near?))
                    (spell-directive tag 'medivac 'medivac-boost 'none 0 ux uy
                                     (if (> cargo-cnt 0) 'medivac-boost-loaded-drop 'medivac-boost-rescue-evac)))
               (and (< hp-rat 0.45)
                    (= cargo-cnt 0)
                    danger-near?
                    (let-values ([(rx ry) (safe-retreat-point ux uy all-enemies home-x home-y 9.0)])
                      (spell-directive tag 'medivac 'move 'kite 0 rx ry 'medivac-retreat-low-hp-empty)))
               (let-values ([(ok? tgt _w)
                             (best-unit-target
                              ux uy 5.5 ally-units
                              (lambda ([a : Any])
                                (and (not (= (uh-tag a) tag))
                                     (not (uh-hallucination? a))
                                     (memq (uh-type a) '(marine marauder reaper ghost hellbat scv))
                                     (< (uh-hp-ratio a) 0.92)))
                              (lambda ([a : Any])
                                (+ (* 100.0 (- 1.0 (uh-hp-ratio a)))
                                   (case (uh-type a) [(ghost) 25.0] [(marauder) 15.0] [(marine) 12.0] [else 5.0]))))])
                 (and ok?
                      (let ([ttag (uh-tag tgt)])
                        (and (spell-claim-unit?! claims 'heal ttag current-frame 16 #:caster-tag tag #:max-casters 2)
                             (spell-directive tag 'medivac 'heal 'unit ttag
                                              (uh-x tgt) (uh-y tgt) 'medivac-heal-injured-bio))))))]

             ;; --- CYCLONE (Lock-On 2350) ---
             [(cyclone)
              (define lock-ready?
                (and (not (spellcaster-channel-protected? u))
                     (not (eq? (dyn-hash-ref u 'lock-on-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'lock-on-cooldown 0) 0) 0)))
              (: cyclone-lock-weight (-> Any Float))
              (define (cyclone-lock-weight e)
                (case (uh-type e)
                  [(oracle warp-prism warp-prism-phasing medivac banshee liberator) 140.0]
                  [(void-ray phoenix tempest battlecruiser carrier corruptor overlord-transport overseer) 130.0]
                  [(stalker immortal ravager roach siege-tank colossus cyclone) 110.0]
                  [else (if (sc2-enemy-unit-targetable? e) 60.0 0.0)]))
              (and lock-ready?
                   (let-values ([(ok? tgt _w)
                                 (best-unit-target
                                  ux uy 7.5 enemy-units
                                  (lambda ([e : Any])
                                    (and (sc2-enemy-unit-targetable? e)
                                         (not (uh-hallucination? e))
                                         (not (uh-has-buff? e 'lock-on))
                                         (= (spell-unit-claim-count claims 'lock-on (uh-tag e) current-frame) 0)
                                         (> (cyclone-lock-weight e) 0.0)))
                                  cyclone-lock-weight)])
                     (and ok?
                          (let ([ttag (uh-tag tgt)])
                            (and (spell-claim-unit?! claims 'lock-on ttag current-frame 36 #:caster-tag tag #:max-casters 1)
                                 (spell-directive tag 'cyclone 'lock-on 'unit ttag
                                                  (uh-x tgt) (uh-y tgt) 'cyclone-lock-on-high-value))))))]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used-tags))
             (values acc used-tags))])))
  (reverse dirs-rev))

;; Plan #115-calibrated Terran spellcaster micro (`ghost`, `raven`, `battlecruiser`)
;; enforcing Ghost `34f` Snipe channel lockout, close-range `<4.5` guard, and detector Cloak check.
(: plan-terran-spellcaster-micro
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:yamato-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-terran-spellcaster-micro
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:yamato-researched? [yamato-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:exclude-tags [exclude-tags '()])
  (define casters
    (for/fold ([acc : (Listof Any) '()] #:result (reverse acc))
              ([u (in-list ally-units)]
               #:when (hash? u))
      (define sym (uh-type u))
      (if (memq sym TERRAN-CASTER-SYMS)
          (let ([t (uh-tag u)])
            (if (and (> t 0) (not (memv t exclude-tags)))
                (cons u acc)
                acc))
          acc)))
  (if (null? casters)
      '()
      (run-terran-spellcaster-micro
       casters ally-units enemy-units claims current-frame
       ally-buildings enemy-buildings effects researched-upgrades
       yamato-researched? home-x home-y exclude-tags)))

;; -----------------------------------------------------------------------------
;; 8. Protoss Spellcaster Patterns (Sentry, High Templar, Oracle)
;; -----------------------------------------------------------------------------

(: ht-feedback-priority (-> Any Float))
(define (ht-feedback-priority e)
  (define en (uh-energy e))
  (if (< en 45.0)
      0.0
      (let ([base (case (uh-type e)
                    [(infestor infestor-burrowed) 200.0]
                    [(viper) 180.0]
                    [(ghost) 160.0]
                    [(medivac) 140.0]
                    [(high-templar) 125.0]
                    [(raven) 115.0]
                    [(oracle) 105.0]
                    [(sentry queen banshee battlecruiser) 75.0]
                    [else 0.0])])
        (if (> base 0.0) (+ base (* 0.35 en)) 0.0))))

(: force-field-splitter-target? (-> Any Boolean))
(define (force-field-splitter-target? e)
  (and (not (uh-flying? e))
       (not (memq (uh-type e) '(ultralisk ultralisk-burrowed archon colossus thor thor-ap)))
       (<= (enemy-ground-range e) 3.5)
       (sc2-enemy-unit-targetable? e)))

(: oracle-revelation-priority-target? (-> Any Boolean))
(define (oracle-revelation-priority-target? e)
  (and (not (uh-has-buff? e 'oracle-revelation))
       (or (uh-cloaked? e)
           (uh-burrowed? e)
           (and (memq (uh-type e)
                      '(lurker-burrowed lurker-mp-burrowed widow-mine-burrowed
                        banshee ghost dark-templar))
                #t))))

(: oracle-pulsar-victim? (-> Any Boolean))
(define (oracle-pulsar-victim? e)
  (and (not (uh-flying? e))
       (sc2-enemy-unit-targetable? e)
       (or (eq? (dyn-hash-ref e 'light? #f) #t)
           (eq? (safe-sym (dyn-hash-ref e 'attribute 'unknown) 'unknown) 'light)
           (and (memq (uh-type e)
                      '(scv probe drone marine zergling baneling zealot adept
                        high-templar dark-templar ghost reaper hellion hydralisk
                        sentry widow-mine locust swarm-host))
                #t))))

(: ht-dry-for-archon? (-> Any Boolean))
(define (ht-dry-for-archon? u)
  (and (hash? u)
       (eq? (uh-type u) 'high-templar)
       (> (uh-tag u) 0)
       (< (uh-energy u) 50.0)
       (not (spellcaster-channel-protected? u))))

(: run-protoss-spellcaster-micro
   (-> (Listof Any) (Listof Any) (Listof Any) (Listof Any)
       spell-claims Integer (Listof Any) (Listof Any) (Listof Any) (Listof Any)
       Boolean Float Float Float Float Float Float (Listof (Pairof Real Real)) (Listof Integer)
       (Listof spell-directive)))
(define (run-protoss-spellcaster-micro
         caster-units friendly-hts ally-units enemy-units
         claims current-frame ally-buildings enemy-buildings effects
         researched-upgrades psi-storm-researched?
         home-x home-y natural-x natural-y enemy-base-x enemy-base-y
         choke-points exclude-tags)
  (define all-enemies (if (null? enemy-buildings) enemy-units (append enemy-units enemy-buildings)))
  (define all-allies (if (null? ally-buildings) ally-units (append ally-units ally-buildings)))
  (define storm-ok?
    (or psi-storm-researched?
        (for/or : Boolean ([up (in-list researched-upgrades)])
          (and (memq (safe-sym up 'unknown) '(psi-storm psistorm psi-storm-tech psistorm-tech psionic-storm)) #t))))

  ;; Per-step cache for unit total-hp lookups during cluster scoring
  (define protoss-hp-cache : (Mutable-HashTable Integer Float) (make-hasheqv))
  (: protoss-cached-hp (-> Any Float))
  (define (protoss-cached-hp e)
    (define t (uh-tag e))
    (if (> t 0)
        (or (hash-ref protoss-hp-cache t (lambda () #f))
            (let ([v (uh-total-hp e)])
              (hash-set! protoss-hp-cache t v)
              v))
        (uh-total-hp e)))

  ;; Phase A: Per-unit primary spell actions (`sentry`, `high-templar` Storm/Feedback, `oracle`)
  (define-values (dirs-rev used-tags)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used : (Listof Integer) exclude-tags])
              ([u (in-list caster-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used))
         (values acc used)]
        [else
         (define ux (uh-x u))
         (define uy (uh-y u))
         (define en (uh-energy u))
         (define sh (uh-shields u))
         (define dir : (Option spell-directive)
           (case sym
             ;; --- SENTRY ---
             [(sentry)
              (or
               ;; 1. Guardian Shield (`r=5.0 ttl=246f`, >= 3 allies within 4.5, >= 2 enemy ranged < 10.0)
               (and (>= en SC2-SENTRY-GUARDIAN-SHIELD-ENERGY)
                    (not (uh-has-buff? u 'guardian-shield))
                    (>= (count-units-within ally-units ux uy 4.5 unit-combat-relevant?) 3)
                    (>= (count-units-within enemy-units ux uy 10.0 enemy-ranged-threat?) 2)
                    (spell-claim-point?! claims 'guardian-shield ux uy
                                         GUARDIAN-SHIELD-CLAIM-RADIUS current-frame GUARDIAN-SHIELD-CLAIM-TTL)
                    (spell-directive tag 'sentry 'guardian-shield 'none 0 ux uy 'sentry-guardian-shield))
               ;; 2. Force Field (`energy >= 50`, `~27f` post-GS stagger, splitting >= 4 melee, zero allies < 1.8)
               (let* ([last-gs (spell-claims-last-guardian-shield-frame claims)]
                      [gs-stagger-ok? (or (< last-gs 0)
                                           (>= (- current-frame last-gs) SENTRY-FORCE-FIELD-POST-GS-DELAY-FRAMES))])
                 (and (>= en SC2-SENTRY-FORCE-FIELD-ENERGY)
                      gs-stagger-ok?
                      (let-values ([(ok? mx my _s)
                                    (best-enemy-cluster
                                     ux uy 10.5 enemy-units 3.5 0.0
                                     (lambda ([_cx : Float] [_cy : Float] [cl : (Listof Any)])
                                       (define mcnt (count-units-within cl _cx _cy 3.5 force-field-splitter-target?))
                                       (if (>= mcnt 4) (->float mcnt) 0.0)))])
                        (and ok?
                             (let* ([dx (- ux mx)]
                                    [dy (- uy my)]
                                    [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                    [fx (clamp-coord (+ mx (* 1.6 (/ dx d))))]
                                    [fy (clamp-coord (+ my (* 1.6 (/ dy d))))]
                                    [ally-trapped?
                                     (any-unit-within? ally-units fx fy 1.799
                                                       (lambda ([a : Any]) (not (uh-flying? a))))]
                                    [existing-ff?
                                     (any-effect-within? effects 'force-field fx fy 2.2 (lambda ([_e : Any]) #t))])
                               (and (<= (dist2 ux uy fx fy) 9.0)
                                    (not ally-trapped?)
                                    (not existing-ff?)
                                    (spell-claim-point?! claims 'force-field fx fy FORCE-FIELD-CLAIM-RADIUS current-frame FORCE-FIELD-CLAIM-TTL)
                                    (spell-directive tag 'sentry 'force-field 'point 0 fx fy 'sentry-force-field)))))))
               ;; 3. Hallucination Phoenix (~4:00-4:15 early scout, `88.6%`) / Archon surplus tank
               (and (>= en 75.0)
                    (let* ([scout-window? (and (>= current-frame 4480) (<= current-frame 7000))]
                           [no-recent-phoenix?
                            (> (- current-frame (spell-claims-last-hallucination-phoenix-frame claims)) 900)])
                      (cond
                        [(and scout-window?
                              no-recent-phoenix?
                              (not (any-unit-within? all-enemies ux uy 10.0 sc2-enemy-unit-targetable?)))
                         (set-spell-claims-last-hallucination-phoenix-frame! claims current-frame)
                         (spell-directive tag 'sentry 'hallucination-phoenix 'none 0 ux uy 'sentry-hallucination-phoenix-scout)]
                        [(and (>= en 125.0)
                              (any-unit-within? enemy-units ux uy 10.0 sc2-enemy-unit-targetable?)
                              (spell-claim-unit?! claims 'hallucination-archon tag current-frame 24 #:caster-tag tag))
                         (spell-directive tag 'sentry 'hallucination-archon 'none 0 ux uy 'sentry-hallucination-archon-tank)]
                        [(and (<= current-frame 7200)
                              no-recent-phoenix?
                              (not (any-unit-within? all-enemies ux uy 10.0 sc2-enemy-unit-targetable?)))
                         (set-spell-claims-last-hallucination-phoenix-frame! claims current-frame)
                         (spell-directive tag 'sentry 'hallucination-phoenix 'none 0 ux uy 'sentry-hallucination-phoenix-scout)]
                        [(and (any-unit-within? enemy-units ux uy 10.0 sc2-enemy-unit-targetable?)
                              (any-unit-within?
                               enemy-units ux uy 11.0
                               (lambda ([e : Any])
                                 (and (memq (uh-type e) '(widow-mine widow-mine-burrowed siege-tank siege-tank-sieged
                                                          immortal lurker-burrowed lurker-mp-burrowed disruptor))
                                      #t)))
                              (spell-claim-unit?! claims 'hallucination-zealot tag current-frame 24 #:caster-tag tag))
                         (spell-directive tag 'sentry 'hallucination-zealot 'none 0 ux uy 'sentry-hallucination-bait-fire)]
                        [else #f]))))]

             ;; --- HIGH TEMPLAR (Primary spells: Storm & Feedback) ---
             [(high-templar)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. Psi Storm (`energy >= 75`, `r=2.0 ttl=56f`, `<= 1` ally within `1.5`)
                  (and storm-ok?
                       (>= en 75.0)
                       (let-values ([(ok? sx sy _s)
                                     (best-enemy-cluster
                                      ux uy 9.0 enemy-units 2.0 0.25
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define n-cl (length cl))
                                        (if (and (>= n-cl 2)
                                                 (not (spell-point-claimed? claims 'psi-storm cx cy PSI-STORM-CLAIM-RADIUS current-frame))
                                                 (count-within-at-most?
                                                  ally-units cx cy 1.5 1
                                                  (lambda ([a : Any]) (not (uh-hallucination? a)))))
                                            (+ (* 35.0 (->float n-cl))
                                               (* 0.08 (sum-units-fl cl protoss-cached-hp)))
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'psi-storm sx sy PSI-STORM-CLAIM-RADIUS current-frame PSI-STORM-CLAIM-TTL)
                              (begin
                                (hash-set! (spell-claims-ht-storm-frame claims) tag current-frame)
                                (spell-directive tag 'high-templar 'psi-storm 'point 0 sx sy 'ht-psi-storm)))))
                  ;; 2. Feedback (`Infestor -> Viper -> Ghost -> Medivac -> HT -> Raven -> Oracle`, 1/target)
                  (and (>= en 50.0)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 enemy-units
                                      (lambda ([e : Any]) (> (ht-feedback-priority e) 0.0))
                                      (lambda ([e : Any]) (ht-feedback-priority e)))])
                         (and ok?
                              (spell-claim-unit?! claims 'feedback (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'high-templar 'feedback 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'ht-feedback)))))])]

             ;; --- ORACLE (#115 [P0] Strict 1-command-per-frame mutex + >=60f Pulsar dwell) ---
             [(oracle)
              (define-values (beam-on? dwell) (oracle-pulsar-beam-active? claims u current-frame))
              (cond
                ;; When Pulsar Beam is ON: ONLY permit OFF after >= 60f minimum dwell
                [beam-on?
                 (and (>= dwell ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES)
                      (or (< en 15.0)
                          (< sh 25.0)
                          (and (>= dwell ORACLE-PULSAR-BEAM-ZERO-TARGET-DWELL-FRAMES)
                               (= (count-units-within all-enemies ux uy 8.0 sc2-enemy-unit-targetable?) 0)))
                      (begin
                        (hash-remove! (spell-claims-oracle-beam-start claims) tag)
                        (spell-directive tag 'oracle 'pulsar-beam-off 'none 0 ux uy
                                         'oracle-pulsar-beam-off)))]
                [else
                 ;; Branch (a): Oracle Revelation (`energy >= 25`, `r=6.0 ttl=448`)
                 (define rev-dir : (Option spell-directive)
                   (and (>= en 25.0)
                        (or
                         ;; (a1) Cloaked / burrowed priority threat
                         (let-values ([(ok? tgt _w)
                                       (best-unit-target
                                        ux uy 10.5 enemy-units oracle-revelation-priority-target?
                                        (lambda ([e : Any])
                                          (if (memq (uh-type e) '(lurker-burrowed lurker-mp-burrowed))
                                              120.0 95.0)))])
                           (and ok?
                                (spell-claim-point?! claims 'oracle-revelation (uh-x tgt) (uh-y tgt)
                                                     ORACLE-REVELATION-CLAIM-RADIUS current-frame ORACLE-REVELATION-CLAIM-TTL)
                                (spell-directive tag 'oracle 'oracle-revelation 'point 0
                                                 (uh-x tgt) (uh-y tgt) 'oracle-revelation-stealth)))
                         ;; (a2) Unrevealed enemy army ahead of friendly HTs
                         (let-values ([(ok? rx ry _s)
                                       (best-enemy-cluster
                                        ux uy 9.5 enemy-units 4.5 0.0
                                        (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                          (define unrev-combat
                                            (for/sum : Integer ([e (in-list cl)])
                                              (if (and (not (uh-has-buff? e 'oracle-revelation))
                                                       (unit-combat-relevant? e))
                                                  1 0)))
                                          (define key-unrev?
                                            (for/or : Boolean ([e (in-list cl)])
                                              (and (not (uh-has-buff? e 'oracle-revelation))
                                                   (memq (uh-type e)
                                                         '(siege-tank-sieged colossus disruptor high-templar ghost immortal tempest liberator-ag))
                                                   #t)))
                                          (define ht-near?
                                            (any-unit-within? friendly-hts cx cy 16.0 (lambda ([_h : Any]) #t)))
                                          (if (and ht-near?
                                                   (or (>= unrev-combat 2) key-unrev?)
                                                   (not (spell-point-claimed? claims 'oracle-revelation cx cy
                                                                               ORACLE-REVELATION-CLAIM-RADIUS current-frame)))
                                              (+ (->float unrev-combat) (if key-unrev? 2.0 0.0))
                                              0.0)))])
                           (and ok?
                                (spell-claim-point?! claims 'oracle-revelation rx ry
                                                     ORACLE-REVELATION-CLAIM-RADIUS current-frame ORACLE-REVELATION-CLAIM-TTL)
                                (spell-directive tag 'oracle 'oracle-revelation 'point 0 rx ry
                                                 'oracle-revelation-army))))))
                 (or rev-dir
                     ;; Branch (b): Pulsar Beam ON (`energy >= 40`, `shields >= 35`, `>= 2` light/workers in `5.0`)
                     (and (>= en 40.0)
                          (>= sh 35.0)
                          (>= (count-units-within enemy-units ux uy 5.0 oracle-pulsar-victim?) 2)
                          (begin
                            (hash-set! (spell-claims-oracle-beam-start claims) tag current-frame)
                            (spell-directive tag 'oracle 'pulsar-beam-on 'none 0 ux uy
                                             'oracle-pulsar-beam-on)))
                     ;; Branch (c): Stasis Ward (`beam OFF` & `energy >= 55`) at choke or approach
                     (and (>= en 55.0)
                          (let* ([safe-site?
                                  (lambda ([wx : Float] [wy : Float])
                                    (and (<= (dist2 ux uy wx wy) 8.0)
                                         (not (any-unit-within? all-enemies wx wy 4.5 sc2-enemy-unit-targetable?))
                                         (not (any-unit-within?
                                               all-allies wx wy 4.5
                                               (lambda ([a : Any]) (and (memq (uh-type a) '(oracle-stasis-trap stasis-ward)) #t))))
                                         (not (spell-point-claimed? claims 'stasis-ward wx wy STASIS-WARD-CLAIM-RADIUS current-frame))))]
                                 [choke-pt : (Option (Pairof Float Float))
                                  (for/or : (Option (Pairof Float Float)) ([cp (in-list choke-points)])
                                    (define cx (safe-fl (car cp) 0.0))
                                    (define cy (safe-fl (cdr cp) 0.0))
                                    (and (safe-site? cx cy) (cons cx cy)))]
                                 [default-pt : (Option (Pairof Float Float))
                                  (let* ([dx (- enemy-base-x ux)]
                                         [dy (- enemy-base-y uy)]
                                         [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                         [wx (clamp-coord (if (<= (dist2 ux uy natural-x natural-y) 8.0)
                                                              (+ natural-x (* 2.5 (/ (- enemy-base-x natural-x)
                                                                                     (max 0.01 (dist2 natural-x natural-y enemy-base-x enemy-base-y)))))
                                                              (+ ux (* 2.5 (/ dx d)))))]
                                         [wy (clamp-coord (if (<= (dist2 ux uy natural-x natural-y) 8.0)
                                                              (+ natural-y (* 2.5 (/ (- enemy-base-y natural-y)
                                                                                     (max 0.01 (dist2 natural-x natural-y enemy-base-x enemy-base-y)))))
                                                              (+ uy (* 2.5 (/ dy d)))))])
                                    (and (safe-site? wx wy) (cons wx wy)))]
                                 [chosen (or choke-pt default-pt)])
                            (and chosen
                                 (spell-claim-point?! claims 'stasis-ward (car chosen) (cdr chosen)
                                                      STASIS-WARD-CLAIM-RADIUS current-frame STASIS-WARD-CLAIM-TTL)
                                 (spell-directive tag 'oracle 'stasis-ward 'point 0
                                                  (car chosen) (cdr chosen) 'oracle-stasis-ward)))))])]

             ;; --- PHOENIX (Graviton Beam 173/176) ---
             [(phoenix)
              (define ally-air-cnt
                (count-units-within ally-units ux uy 9.0
                                    (lambda ([a : Any]) (and (uh-flying? a) (unit-combat-relevant? a)))))
              (define enemy-aa-cnt (count-units-within all-enemies ux uy 8.5 enemy-anti-air-or-air-threat?))
              (define safe-lift? (or (>= ally-air-cnt 2) (< enemy-aa-cnt 2)))
              (: phoenix-lift-weight (-> Any Float))
              (define (phoenix-lift-weight e)
                (if (or (uh-flying? e) (not (sc2-enemy-unit-targetable? e)) (uh-hallucination? e))
                    0.0
                    (case (uh-type e)
                      [(siege-tank-sieged siege-tank) 150.0]
                      [(lurker lurker-mp lurker-burrowed lurker-mp-burrowed disruptor) 140.0]
                      [(immortal high-templar ghost infestor infestor-burrowed ravager) 130.0]
                      [(queen swarm-host swarm-host-mp cyclone) 115.0]
                      [(scv probe drone) 95.0]
                      [else 0.0])))
              (and (>= en 50.0)
                   (not (spellcaster-channel-protected? u))
                   safe-lift?
                   (let-values ([(ok? tgt _w)
                                 (best-unit-target
                                  ux uy 5.5 enemy-units
                                  (lambda ([e : Any])
                                    (and (> (phoenix-lift-weight e) 0.0)
                                         (not (uh-has-buff? e 'graviton-beam))
                                         (= (spell-unit-claim-count claims 'graviton-beam (uh-tag e) current-frame) 0)))
                                  phoenix-lift-weight)])
                     (and ok?
                          (let ([ttag (uh-tag tgt)])
                            (and (spell-claim-unit?! claims 'graviton-beam ttag current-frame 36 #:caster-tag tag #:max-casters 1)
                                 (spell-directive tag 'phoenix 'graviton-beam 'unit ttag
                                                  (uh-x tgt) (uh-y tgt) 'phoenix-graviton-lift-siege-lurker))))))]

             ;; --- DISRUPTOR (Purification Nova 2346 w/ 28-32f `31f` stagger gate) ---
             [(disruptor)
              (define nova-ready?
                (and (not (spellcaster-channel-protected? u))
                     (not (eq? (dyn-hash-ref u 'nova-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'nova-cooldown 0) 0) 0)))
              (and nova-ready?
                   (disruptor-nova-stagger-ready? claims current-frame DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES #:commit? #f)
                   (let-values ([(ok? nx ny _s)
                                     (best-enemy-cluster
                                  ux uy 12.5 enemy-units 1.5 0.25
                                  (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                    (define ground-cl
                                      (for/list : (Listof Any) ([e (in-list cl)]
                                                                #:when (not (uh-flying? e)))
                                        e))
                                    (define n-gr (length ground-cl))
                                    (define hv?
                                      (and (< n-gr 2)
                                           (for/or : Boolean ([e (in-list ground-cl)])
                                             (and (memq (uh-type e) '(siege-tank-sieged lurker-burrowed lurker-mp-burrowed colossus ravager marauder stalker))
                                                  #t))))
                                    (if (and (or (>= n-gr 2) hv?)
                                             (not (spell-point-claimed? claims 'purification-nova cx cy 2.0 current-frame))
                                             (count-within-at-most?
                                              ally-units cx cy 1.5 1
                                              (lambda ([a : Any]) (and (not (uh-flying? a)) (not (uh-hallucination? a))))))
                                        (+ (* 40.0 (->float n-gr))
                                           (* 0.1 (sum-units-fl ground-cl protoss-cached-hp)))
                                        0.0)))])
                     (and ok?
                          (disruptor-nova-stagger-ready? claims current-frame DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES #:commit? #t)
                          (spell-claim-point?! claims 'purification-nova nx ny 2.0 current-frame 31)
                          (spell-directive tag 'disruptor 'purification-nova 'point 0 nx ny
                                           'disruptor-nova-stagger-clump))))]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used))
             (values acc used))])))

  ;; Phase B: Post-storm dry High Templars (< 50 energy) -> Archon pair merge vs unpaired kite
  (define dry-hts : (Listof Any)
    (if (null? friendly-hts)
        '()
        (for/list ([u (in-list friendly-hts)]
                   #:when (and (ht-dry-for-archon? u)
                               (not (memv (uh-tag u) used-tags))))
          u)))

  (if (null? dry-hts)
      (reverse dirs-rev)
      (let-values ([(final-rev _paired)
                    (let loop : (Values (Listof spell-directive) (Listof Integer))
                         ([rem : (Listof Any) dry-hts]
                          [acc : (Listof spell-directive) dirs-rev]
                          [seen : (Listof Integer) used-tags])
                      (cond
                        [(null? rem) (values acc seen)]
                        [else
                         (define ht1 (car rem))
                         (define t1 (uh-tag ht1))
                         (cond
                           [(memv t1 seen) (loop (cdr rem) acc seen)]
                           [else
                            (define x1 (uh-x ht1))
                            (define y1 (uh-y ht1))
                            ;; Find closest dry HT partner within 20.0 tiles
                            (define-values (partner _best-d)
                              (for/fold ([best : Any #f]
                                         [bd : Float 20.001])
                                        ([cand (in-list (cdr rem))])
                                (define ctag (uh-tag cand))
                                (if (memv ctag seen)
                                    (values best bd)
                                    (let ([d (dist2 x1 y1 (uh-x cand) (uh-y cand))])
                                      (if (< d bd)
                                          (values cand d)
                                          (values best bd))))))
                            (cond
                              [(hash? partner)
                               (define t2 (uh-tag partner))
                               (define mx (* 0.5 (+ x1 (uh-x partner))))
                               (define my (* 0.5 (+ y1 (uh-y partner))))
                               (hash-set! (spell-claims-ht-merge-lock-until claims) t1 (+ current-frame HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES))
                               (hash-set! (spell-claims-ht-merge-lock-until claims) t2 (+ current-frame HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES))
                               (loop (cdr rem)
                                     (cons (spell-directive t1 'high-templar 'morph-archon 'pair t2 mx my
                                                            'ht-post-storm-archon-merge)
                                           acc)
                                     (cons t1 (cons t2 seen)))]
                              [else
                               ;; Unpaired dry HT: only kite if not inside an active merge lock and threatened
                               (define merge-until (hash-ref (spell-claims-ht-merge-lock-until claims) t1 (lambda () -1)))
                               (define threatened? (any-unit-within? all-enemies x1 y1 10.0 sc2-enemy-unit-targetable?))
                               (if (and (>= current-frame merge-until) threatened?)
                                   (let-values ([(rx ry) (safe-retreat-point x1 y1 all-enemies home-x home-y 8.0)])
                                     (loop (cdr rem)
                                           (cons (spell-directive t1 'high-templar 'move 'kite 0 rx ry
                                                                  'ht-unpaired-dry-kite)
                                                 acc)
                                           (cons t1 seen)))
                                   (loop (cdr rem) acc (cons t1 seen)))])])]))])
        (reverse final-rev))))

;; Plan #115-calibrated Protoss spellcaster micro (`sentry`, `high-templar`, `oracle`)
;; enforcing Sentry `246f` GS / `~27f` Force Field stagger / `<1.8` ally trap guard,
;; HT `<=1` FF / Feedback priority / paired dry-HT `morph-archon`, and Oracle `[P0]`
;; strict 1-command-per-frame mutex + `>=60f` Pulsar Beam dwell.
(: plan-protoss-spellcaster-micro
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:psi-storm-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:natural-x Float
         #:natural-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:choke-points (Listof (Pairof Real Real))
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-protoss-spellcaster-micro
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:psi-storm-researched? [psi-storm-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:natural-x [natural-x SC2-DEFAULT-NATURAL-X]
         #:natural-y [natural-y SC2-DEFAULT-NATURAL-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:choke-points [choke-points '()]
         #:exclude-tags [exclude-tags '()])
  (define-values (casters friendly-hts)
    (for/fold ([cs : (Listof Any) '()]
               [hts : (Listof Any) '()]
               #:result (values (reverse cs) (reverse hts)))
              ([u (in-list ally-units)]
               #:when (hash? u))
      (define sym (uh-type u))
      (define next-hts (if (eq? sym 'high-templar) (cons u hts) hts))
      (if (memq sym PROTOSS-CASTER-SYMS)
          (let ([t (uh-tag u)])
            (values (if (and (> t 0) (not (memv t exclude-tags))) (cons u cs) cs)
                    next-hts))
          (values cs next-hts))))
  (if (null? casters)
      '()
      (run-protoss-spellcaster-micro
       casters friendly-hts ally-units enemy-units claims current-frame
       ally-buildings enemy-buildings effects researched-upgrades psi-storm-researched?
       home-x home-y natural-x natural-y enemy-base-x enemy-base-y
       choke-points exclude-tags)))

;; -----------------------------------------------------------------------------
;; 9. Unified Multi-Race Spellcaster Entrypoints
;; -----------------------------------------------------------------------------

;; Plan pro-calibrated spellcaster micro across Zerg, Terran, and Protoss casters
;; in a single pass after pruning expired `spell-claims`.
(: step-pro-spellcaster-micro!
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:psi-storm-researched? Boolean
         #:yamato-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:natural-x Float
         #:natural-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:inject-queen-tags (Listof Integer)
         #:choke-points (Listof (Pairof Real Real))
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (step-pro-spellcaster-micro!
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:psi-storm-researched? [psi-storm-researched? #t]
         #:yamato-researched? [yamato-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:natural-x [natural-x SC2-DEFAULT-NATURAL-X]
         #:natural-y [natural-y SC2-DEFAULT-NATURAL-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:inject-queen-tags [inject-queen-tags '()]
         #:choke-points [choke-points '()]
         #:exclude-tags [exclude-tags '()])
  (prune-spell-claims! claims current-frame)
  (define-values (z-casters t-casters p-casters p-hts)
    (for/fold ([zs : (Listof Any) '()]
               [ts : (Listof Any) '()]
               [ps : (Listof Any) '()]
               [hts : (Listof Any) '()]
               #:result (values (reverse zs) (reverse ts) (reverse ps) (reverse hts)))
              ([u (in-list ally-units)]
               #:when (hash? u))
      (define sym (uh-type u))
      (cond
        [(memq sym ZERG-CASTER-SYMS)
         (define t (uh-tag u))
         (values (if (and (> t 0) (not (memv t exclude-tags))) (cons u zs) zs) ts ps hts)]
        [(memq sym TERRAN-CASTER-SYMS)
         (define t (uh-tag u))
         (values zs (if (and (> t 0) (not (memv t exclude-tags))) (cons u ts) ts) ps hts)]
        [(memq sym PROTOSS-CASTER-SYMS)
         (define t (uh-tag u))
         (define next-hts (if (eq? sym 'high-templar) (cons u hts) hts))
         (values zs ts (if (and (> t 0) (not (memv t exclude-tags))) (cons u ps) ps) next-hts)]
        [else
         (values zs ts ps hts)])))
  (cond
    [(and (null? z-casters) (null? t-casters) (null? p-casters)) '()]
    [else
     (parameterize ([current-spell-xy-table
                     (or (current-spell-xy-table) ((inst make-hasheq Any spell-xy-index)))])
       (define-values (z-dirs t-dirs p-dirs)
         (parameterize ([current-spell-flying-cache ((inst make-hasheq Any Symbol))])
           (values
            (if (null? z-casters)
                '()
                (run-zerg-spellcaster-micro
                 z-casters ally-units enemy-units claims current-frame
                 ally-buildings enemy-buildings effects home-x home-y
                 enemy-base-x enemy-base-y inject-queen-tags exclude-tags))
            (if (null? t-casters)
                '()
                (run-terran-spellcaster-micro
                 t-casters ally-units enemy-units claims current-frame
                 ally-buildings enemy-buildings effects researched-upgrades
                 yamato-researched? home-x home-y exclude-tags))
            (if (null? p-casters)
                '()
                (run-protoss-spellcaster-micro
                 p-casters p-hts ally-units enemy-units claims current-frame
                 ally-buildings enemy-buildings effects researched-upgrades psi-storm-researched?
                 home-x home-y natural-x natural-y enemy-base-x enemy-base-y
                 choke-points exclude-tags)))))
       (cond
         [(and (null? z-dirs) (null? t-dirs)) p-dirs]
         [(and (null? t-dirs) (null? p-dirs)) z-dirs]
         [(and (null? z-dirs) (null? p-dirs)) t-dirs]
         [else (append z-dirs t-dirs p-dirs)]))]))

;; Convenience wrapper returning `sc2-typed-commands`-ready S-expression commands.
(: step-pro-spellcaster-sexps!
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:psi-storm-researched? Boolean
         #:yamato-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:natural-x Float
         #:natural-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:inject-queen-tags (Listof Integer)
         #:choke-points (Listof (Pairof Real Real))
         #:exclude-tags (Listof Integer))
        (Listof (Listof Any))))
(define (step-pro-spellcaster-sexps!
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:psi-storm-researched? [psi-storm-researched? #t]
         #:yamato-researched? [yamato-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:natural-x [natural-x SC2-DEFAULT-NATURAL-X]
         #:natural-y [natural-y SC2-DEFAULT-NATURAL-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:inject-queen-tags [inject-queen-tags '()]
         #:choke-points [choke-points '()]
         #:exclude-tags [exclude-tags '()])
  (map spell-directive->sexp
       (step-pro-spellcaster-micro!
        ally-units enemy-units
        #:claims claims
        #:current-frame current-frame
        #:ally-buildings ally-buildings
        #:enemy-buildings enemy-buildings
        #:effects effects
        #:researched-upgrades researched-upgrades
        #:psi-storm-researched? psi-storm-researched?
        #:yamato-researched? yamato-researched?
        #:home-x home-x
        #:home-y home-y
        #:natural-x natural-x
        #:natural-y natural-y
        #:enemy-base-x enemy-base-x
        #:enemy-base-y enemy-base-y
        #:inject-queen-tags inject-queen-tags
        #:choke-points choke-points
        #:exclude-tags exclude-tags)))
