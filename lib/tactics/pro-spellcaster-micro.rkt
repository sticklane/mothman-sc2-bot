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

(require racket/fixnum
         racket/flonum
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
           dyn-u-cloak-state
           dyn-u-snapshot-flag
           dyn-u-burrowed-flag
           dyn-u-has-order-ability?
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
      [(symbol? b)
       (or (and (eq? target 'interference-matrix) (eq? b 'interference-matrix-carrier))
           (and (eq? target 'anti-armor-missile) (eq? b 'raven-shredder-missile-tint))
           (and (eq? target 'oracle-weapon) (eq? b 'pulsar-beam))
           (and (eq? target 'microbial-shroud) (eq? b 'amorphous-armorcloud))
           (and (eq? target 'banshee-cloak) (eq? b 'cloak-banshee)))]
      [(exact-integer? b)
       (case b
         [(5) (eq? target 'graviton-beam)]
         [(6) (eq? target 'ghost-cloak)]
         [(7) (or (eq? target 'banshee-cloak) (eq? target 'cloak-banshee))]
         [(17) (eq? target 'fungal-growth)]
         [(18) (eq? target 'guardian-shield)]
         [(22) (eq? target 'neural-parasite)]
         [(28) (eq? target 'psi-storm)]
         [(36) (eq? target 'contaminate)]
         [(49) (eq? target 'oracle-revelation)]
         [(72) (eq? target 'stasis)]
         [(83) (eq? target 'blinding-cloud)]
         [(89) (eq? target 'medivac-speed-boost)]
         [(99) (or (eq? target 'oracle-weapon) (eq? target 'pulsar-beam))]
         [(116) (eq? target 'lock-on)]
         [(122) (eq? target 'void-ray-prismatic-alignment)]
         [(129) (or (eq? target 'oracle-stasis-trap-target) (eq? target 'stasis-ward-target))]
         [(132) (eq? target 'parasitic-bomb)]
         [(277 300) (or (eq? target 'interference-matrix) (eq? target 'interference-matrix-carrier))]
         [(279 280) (or (eq? target 'anti-armor-missile) (eq? target 'raven-shredder-missile-tint))]
         [(288) (eq? target 'transfusion)]
         [(297) (or (eq? target 'microbial-shroud) (eq? target 'amorphous-armorcloud))]
         [(302) (eq? target 'hydralisk-frenzy)]
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
  ;; Returns 'undetected (cloak=1), 'detected (cloak=2), 'not-cloaked (cloak=3/4), or 'unknown
  (define (dyn-u-cloak-state u)
    (if (hash? u)
        (let ([cv (hash-ref u 'cloak #f)])
          (cond
            [(or (eqv? cv 1) (eq? cv 'cloaked)) 'undetected]
            [(or (eqv? cv 2) (eq? cv 'cloaked-detected)) 'detected]
            [(or (eqv? cv 3) (eqv? cv 4) (eq? cv 'not-cloaked) (eq? cv 'not-cloaked-unknown)) 'not-cloaked]
            [(eq? (hash-ref u 'cloaked #f) #t) 'undetected]
            [else 'unknown]))
        'unknown))
  (define (dyn-u-snapshot-flag u)
    (and (hash? u)
         (or (eq? (hash-ref u 'snapshot? #f) #t)
             (eqv? (hash-ref u 'display-type 1) 2))))
  (define (dyn-u-burrowed-flag u)
    (and (hash? u)
         (or (eq? (hash-ref u 'burrowed #f) #t)
             (eq? (hash-ref u 'burrowed? #f) #t)
             (eq? (hash-ref u 'is-burrowed #f) #t)
             (eq? (hash-ref u 'is-burrowed? #f) #t))))
  (define (dyn-u-has-order-ability? u target-ab-id)
    (and (hash? u)
         (or (eqv? (hash-ref u 'order-ability-id 0) target-ab-id)
             (let ([ords (hash-ref u 'orders '())])
               (and (list? ords)
                    (let loop ([rem ords])
                      (and (pair? rem)
                           (let ([o (car rem)])
                             (or (eqv? o target-ab-id)
                                 (and (hash? o)
                                      (or (eqv? (hash-ref o 'ability-id 0) target-ab-id)
                                          (eqv? (hash-ref o 'ability_id 0) target-ab-id)))
                                 (loop (cdr rem)))))))))))
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
  [dyn-u-cloak-state (-> Any Symbol)]
  [dyn-u-snapshot-flag (-> Any Boolean)]
  [dyn-u-burrowed-flag (-> Any Boolean)]
  [dyn-u-has-order-ability? (-> Any Integer Boolean)]
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
 CORROSIVE-BILE-FF-CHECK-RADIUS
 corrosive-bile-target-safe?
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
 bc-yamato-channel-locked?
 spellcaster-channel-protected?
 oracle-pulsar-beam-active?
 spell-directive->sexp

 ;; Race planners & top-level orchestrators
 plan-zerg-spellcaster-micro
 plan-terran-spellcaster-micro
 plan-protoss-spellcaster-micro
 step-pro-spellcaster-micro!
 step-pro-spellcaster-sexps!

 ;; L38-P0-1a / 1b & L39-P0-1b / 1e: DT ShadowStride PF Snipe, Widow Mine Detection & Mutalisk Magic-Box
 SHADOW-STRIDE-COOLDOWN-FRAMES
 SHADOW-STRIDE-MAX-RANGE
 PF-PERIMETER-BLINK-INNER-RADIUS
 PF-PERIMETER-BLINK-OUTER-RADIUS
 PF-BLINK-MAX-APPROACH-DIST
 MUTA-MAGIC-BOX-MIN-COUNT
 WIDOW-MINE-TRIGGER-RADIUS
 WIDOW-MINE-MELEE-SAFE-RADIUS
 shadow-stride-researched?
 plan-dt-blink-pf-snipe
 plan-mutalisk-magic-box
 widow-mine-detected-targetable?
 ;; L43-P0-1b: Stalker Blink-Back & Coordinated Blink-Forward High-Value Snipe
 STALKER-BLINK-COOLDOWN-FRAMES
 STALKER-BLINK-MAX-RANGE
 stalker-blink-researched?
 plan-stalker-blink-micro)

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
(define CORROSIVE-BILE-FF-CHECK-RADIUS : Float 1.75)
;; W10-TAC-1 / W10-TAC-2 / W10-TAC-5: Exact SC2 live per-unit ability cooldowns (22.4 fps).
(define MEDIVAC-BOOST-COOLDOWN-FRAMES : Integer 320)
(define CYCLONE-LOCK-ON-COOLDOWN-FRAMES : Integer 196)
(define BC-TACTICAL-JUMP-COOLDOWN-FRAMES : Integer 1590)
(define BC-YAMATO-COOLDOWN-FRAMES : Integer 1590)
(define CORRUPTOR-CAUSTIC-SPRAY-COOLDOWN-FRAMES : Integer 1008)
;; L38-P0-1a / 1b: DT ShadowStride (`2700`, upg `141`) PF snipe & Widow Mine standoff constants
;; Use `7.65t` clamp so even after `0.5`-tile `safe-coord` rounding, cast range stays strictly `<= 8.0t`!
(define SHADOW-STRIDE-COOLDOWN-FRAMES : Integer 314)
(define SHADOW-STRIDE-MAX-RANGE : Float 7.65)
(define PF-PERIMETER-BLINK-INNER-RADIUS : Float 3.0)
(define PF-PERIMETER-BLINK-OUTER-RADIUS : Float 3.5)
;; L39-P0-1b: Maximum DT->PF center distance before blinking onto the `3.0t` PF perimeter ring
;; (`3.0 + 7.65 = 10.65`, with `0.30t` tolerance for spawn-arc spread -> `10.95t`); DTs farther
;; than `10.95t` cloaked-walk (`move`) into range before blinking so zero DTs land short in Bio!
(define PF-BLINK-MAX-APPROACH-DIST : Float 10.95)
;; L39-P0-1e + L42-P0-1c: Minimum Mutalisk squad size for Magic-Box spread over splash AA Thors
;; (lowered 6 -> 2 so surviving 2-5 Mutalisks stay spread-locked on HOLD 18 vs last Thor!)
(define MUTA-MAGIC-BOX-MIN-COUNT : Integer 2)
(define WIDOW-MINE-TRIGGER-RADIUS : Float 5.0)
(define WIDOW-MINE-MELEE-SAFE-RADIUS : Float 6.0)

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
   [ghost-cloak-frame : (HashTable Integer Integer)]
   [medivac-boost-ready-frame : (HashTable Integer Integer)]
   [cyclone-lock-on-ready-frame : (HashTable Integer Integer)]
   [bc-jump-ready-frame : (HashTable Integer Integer)]
   [bc-yamato-ready-frame : (HashTable Integer Integer)]
   [corruptor-spray-ready-frame : (HashTable Integer Integer)]
   [dt-blink-ready-frame : (HashTable Integer Integer)]
   [dt-blink-issue-state : (HashTable Integer (Vector Integer Float Float))]
   [bc-yamato-issue-frame : (HashTable Integer Integer)]
   [stalker-blink-ready-frame : (HashTable Integer Integer)])
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
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   ((inst make-hasheqv Integer (Vector Integer Float Float)))
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

   ;; ZERG: Overseer (Contaminate 1825/182, Oversight 3743/1912, SpawnChangeling 181)
   (spell-tactic-mode 'overseer 'contaminate 1825 'overseer-contaminate-upgrade-tech
                      "Freeze active enemy upgrade lab (Twilight/Forge/Ebay/Armory/Cyber) for 30s"
                      "en>=125 & enemy upgrade/tech building<=7.0")
   (spell-tactic-mode 'overseer 'contaminate 1825 'overseer-contaminate-prod-bottleneck
                      "Halt enemy Stargate/Robotics/Starport/Factory production before timing"
                      "en>=125 & enemy tech production<=7.0")
   (spell-tactic-mode 'overseer 'contaminate 1825 'overseer-contaminate-threat-delay
                      "Contaminate Gateway/Barracks/Hatchery during enemy all-in rally"
                      "en>=125 & enemy production<=7.0")
   (spell-tactic-mode 'overseer 'morph-oversight-mode 3743 'overseer-oversight-ring-watch
                      "Anchor Oversight +50% vision over dead-air/drop approach when AA is absent"
                      "safe>11.0 from enemy AA & stationary spot")
   (spell-tactic-mode 'overseer 'morph-oversight-mode 3743 'overseer-oversight-burrow-guard
                      "Hold Oversight over friendly base/choke against DT, Banshee, or burrow ambushes"
                      "home/choke oversight-desired?")
   (spell-tactic-mode 'overseer 'morph-oversight-mode 3743 'overseer-unmorph-mobile-follow
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

   ;; ZERG: Infestor (Fungal Growth 74, Neural Parasite 249, Microbial Shroud 4111)
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
   (spell-tactic-mode 'infestor 'microbial-shroud 4111 'infestor-shroud-anti-carrier-tempest
                      "Blanket >=3 ground combat units under >=3 enemy air threats (-50% air-to-ground dmg)"
                      "en>=75 & >=3 air enemies<=14.0 & >=3 ground allies")
   (spell-tactic-mode 'infestor 'microbial-shroud 4111 'infestor-shroud-vs-liberator-banshee
                      "Shield Hydralisk/Queen/Lurker core trading upward vs Carrier/Tempest/Banshee"
                      "en>=75 & r=3.5 unclaimed")
   (spell-tactic-mode 'infestor 'microbial-shroud 4111 'infestor-shroud-retreat-cover
                      "Deploy protective Shroud when <70 energy Infestor retreats out of air threat"
                      "fallback when en<70 & threat<=12.0")

   ;; ZERG: Viper (Blinding Cloud 2063, Abduct 2067, Parasitic Bomb 2542 + Consume 2073)
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
   (spell-tactic-mode 'viper 'viper-consume 2073 'viper-safe-consume-regen
                      "Retreat outside 12.0 enemy threat when energy<60 and Consume >450 HP Zerg building"
                      "en<60 & 0 enemies<=12.0 & bldg hp>450")

   ;; ZERG: Corruptor (2324), SwarmHost (2704), Lurker (2108/2110)
   (spell-tactic-mode 'corruptor 'caustic-spray 2324 'corruptor-spray-exposed-townhall
                      "Channel Caustic Spray on unguarded CommandCenter/Nexus/Hatchery (0 AA <=11.0)"
                      "0 AA/air threat<=11.0 & townhall<=6.0")
   (spell-tactic-mode 'corruptor 'caustic-spray 2324 'corruptor-spray-pf-sniper
                      "Burn down Planetary Fortress / high-HP townhall once air is clear"
                      "0 AA/air threat<=11.0 & high-HP townhall")
   (spell-tactic-mode 'corruptor 'caustic-spray 2324 'corruptor-spray-hit-and-abort
                      "Refuse or abort Spray immediately whenever enemy AA/air enters <=11.0 tiles"
                      "enemy AA/air threat<=11.0 -> abort")
   (spell-tactic-mode 'swarm-host-mp 'spawn-locusts 2704 'swarm-host-locust-wave-base
                      "Launch off-cooldown Locust wave onto enemy mineral line or 3rd from 16-24 tiles"
                      "locusts ready & target<=24.0 unclaimed")
   (spell-tactic-mode 'swarm-host-mp 'spawn-locusts 2704 'swarm-host-locust-tank-breaker
                      "Drop Locusts onto sieged Tanks/Immortals/Colossi before main ground engage"
                      "locusts ready & high-value mech/robo clump")
   (spell-tactic-mode 'swarm-host-mp 'spawn-locusts 2704 'swarm-host-nydus-kite-cycle
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

   ;; TERRAN: Raven (Interference Matrix 3747, Anti-Armor Missile 3753, Auto-Turret 1764)
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
   (spell-tactic-mode 'raven 'auto-turret 1764 'raven-turret-worker-harass
                      "Drop Auto-Turret into enemy mineral line prioritizing SCV/Probe/Drone targets"
                      "en>=50 & worker/light<=8.0")
   (spell-tactic-mode 'raven 'auto-turret 1764 'raven-turret-melee-zone
                      "Place Auto-Turret to block charging Zerglings/Zealots/Adepts"
                      "en>=50 & >=2 enemies r=3.5")
   (spell-tactic-mode 'raven 'auto-turret 1764 'raven-turret-vision-tank
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
   (spell-tactic-mode 'sentry 'hallucination-archon 146 'sentry-hallucination-colossus-tank
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
    [(shadow-strike) 'shadow-stride]
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

(: uh-z (-> Any (Option Float)))
(define (uh-z u)
  (define raw (or (dyn-hash-ref u 'z #f) (dyn-hash-ref u 'pos-z #f)))
  (if (and (real? raw) (< -inf.0 raw +inf.0))
      (real->double-flonum raw)
      #f))

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
       [(5) 'graviton-beam]
       [(6) 'ghost-cloak]
       [(7) 'banshee-cloak]
       [(17) 'fungal-growth]
       [(18) 'guardian-shield]
       [(22) 'neural-parasite]
       [(28) 'psi-storm]
       [(36) 'contaminate]
       [(49) 'oracle-revelation]
       [(72) 'stasis]
       [(83) 'blinding-cloud]
       [(89) 'medivac-speed-boost]
       [(99) 'oracle-weapon]
       [(116) 'lock-on]
       [(122) 'void-ray-prismatic-alignment]
       [(129) 'oracle-stasis-trap-target]
       [(132) 'parasitic-bomb]
       [(277) 'interference-matrix]
       [(279) 'raven-shredder-missile-tint]
       [(280) 'anti-armor-missile]
       [(288) 'transfusion]
       [(297) 'microbial-shroud]
       [(300) 'interference-matrix-carrier]
       [(302) 'hydralisk-frenzy]
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
    (or (eq? cls 'channel) (eq? cls 'morph) (= ab 2324) (= ab 1825))))

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
  (prune-hash-below! (spell-claims-ravager-bile-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-medivac-boost-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-cyclone-lock-on-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-bc-jump-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-bc-yamato-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-corruptor-spray-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-dt-blink-ready-frame claims) current-frame)
  (prune-hash-below! (spell-claims-bc-yamato-issue-frame claims) (- current-frame 64))
  (prune-hash-below! (spell-claims-stalker-blink-ready-frame claims) current-frame)
  (let ([st (spell-claims-dt-blink-issue-state claims)])
    (define stale-dt
      (for/fold ([ks : (Listof Integer) '()])
                ([(k v) (in-hash st)])
        (if (<= (+ (vector-ref v 0) 64) current-frame) (cons k ks) ks)))
    (for ([k (in-list stale-dt)])
      (hash-remove! st k))))

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

;; L40-P0-1e (`z14`): Distinguish ANOTHER caster's claim vs THIS caster's own active claim so
;; an approaching Infestor never self-blocks on tick 2 of its own `neural-approach` reservation!
(: spell-unit-claimed-by-other? (-> spell-claims Symbol Integer Integer Integer Boolean))
(define (spell-unit-claimed-by-other? claims ability target-tag caster-tag current-frame)
  (define ab (canonical-spell-key ability))
  (for/or : Boolean ([c (in-list (spell-claims-unit-claims claims))])
    (and (eq? (unit-claim-ability c) ab)
         (= (unit-claim-target-tag c) target-tag)
         (> (unit-claim-expires-frame c) current-frame)
         (not (= (unit-claim-caster-tag c) caster-tag)))))

(: spell-unit-claimed-by-self? (-> spell-claims Symbol Integer Integer Integer Boolean))
(define (spell-unit-claimed-by-self? claims ability target-tag caster-tag current-frame)
  (define ab (canonical-spell-key ability))
  (for/or : Boolean ([c (in-list (spell-claims-unit-claims claims))])
    (and (eq? (unit-claim-ability c) ab)
         (= (unit-claim-target-tag c) target-tag)
         (> (unit-claim-expires-frame c) current-frame)
         (= (unit-claim-caster-tag c) caster-tag))))

(: spell-renew-unit-claim! (-> spell-claims Symbol Integer Integer Integer Integer Boolean))
(define (spell-renew-unit-claim! claims ability target-tag caster-tag current-frame ttl)
  (define ab (canonical-spell-key ability))
  (define renewed? : Boolean #f)
  (define updated
    (for/list : (Listof unit-claim)
              ([c (in-list (spell-claims-unit-claims claims))]
               #:when (> (unit-claim-expires-frame c) current-frame))
      (if (and (eq? (unit-claim-ability c) ab)
               (= (unit-claim-target-tag c) target-tag)
               (= (unit-claim-caster-tag c) caster-tag))
          (begin
            (set! renewed? #t)
            (unit-claim ab target-tag caster-tag (unit-claim-frame c) (+ current-frame (max 1 ttl))))
          c)))
  (when renewed?
    (set-spell-claims-unit-claims! claims updated))
  renewed?)

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

;; L40-P0-1d (`t15`): Returns `#t` if Battlecruiser (`tag` or unit hash) is actively channeling
;; Yamato Cannon (`order == 401` / `2358` Tactical Jump) OR inside its `52f` (`48`-loop channel +
;; `4f` margin) Yamato cast lock with `yamato-cooldown <= 0` so NO `attack-unit`/`move`/`401`
;; overwrites can cancel the beam mid-channel!
(: bc-yamato-channel-locked? (-> spell-claims Any Integer Boolean))
(define (bc-yamato-channel-locked? claims caster-or-tag current-frame)
  (define tag : Integer
    (if (exact-integer? caster-or-tag)
        caster-or-tag
        (uh-tag caster-or-tag)))
  (define obs-cd : Integer
    (if (hash? caster-or-tag)
        (safe-int (dyn-hash-ref caster-or-tag 'yamato-cooldown 0) 0)
        0))
  (define ord-chan? : Boolean
    (and (hash? caster-or-tag)
         (for/or : Boolean ([ab (in-list (uh-order-ids caster-or-tag))])
           (or (= ab 401) (= ab 2358)))))
  (define f0 : (Option Integer)
    (hash-ref (spell-claims-bc-yamato-issue-frame claims) tag (lambda () #f)))
  (or ord-chan?
      (and (integer? f0)
           (<= obs-cd 0)
           (>= current-frame f0)
           (< (- current-frame f0) 52))))

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
    [(hold-position) (list 'hold-position uid)]
    [(attack-unit) (list 'attack-unit uid tid)]
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
         (let ([eval-seeds
                (if (null? (list-tail seeds (min 16 (length seeds))))
                    seeds
                    (let ([inv-step (/ 1.0 (max 0.85 (* 0.65 aoe-radius)))]
                          [seen : (HashTable Fixnum Boolean) ((inst make-hasheq Fixnum Boolean))])
                      (for/fold ([acc : (Listof cluster-pt) '()]
                                 #:result (reverse acc))
                                ([s (in-list seeds)])
                        (define gx (fxand (fx+ 2048 (fl->exact-integer (flround (* (cluster-pt-x s) inv-step)))) #xfff))
                        (define gy (fxand (fx+ 2048 (fl->exact-integer (flround (* (cluster-pt-y s) inv-step)))) #xfff))
                        (define k (fxior (fxlshift gx 12) gy))
                        (if (hash-has-key? seen k)
                            acc
                            (begin
                              (hash-set! seen k #t)
                              (cons s acc))))))])
           (for/fold ([f? : Boolean #f]
                      [best-x : Float 0.0]
                      [best-y : Float 0.0]
                      [best-s : Float 0.0])
                     ([s (in-list eval-seeds)])
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
                  (values f? best-x best-y best-s))]))))]))

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
;; 6. Attribute, Size & Spell Targetability Helpers + Zerg Spellcaster Patterns
;; -----------------------------------------------------------------------------

(: unit-attr-has-any? (-> Symbol Fixnum Boolean))
(define (unit-attr-has-any? sym mask)
  (fx> (fxand (unit-attribute-mask sym) mask) 0))

(: multi-hit-ally-attacker? (-> Any Boolean))
(define (multi-hit-ally-attacker? u)
  (and (not (uh-hallucination? u))
       (not (eq? (memq (uh-type u)
                       '(marine viking viking-fighter zealot zergling
                         hydralisk mutalisk cyclone thor thor-ap
                         battlecruiser carrier interceptor phoenix reaper
                         hellion hellbat adept marauder))
                 #f))))

(: ally-repair-target-valid? (-> Any Boolean))
(define (ally-repair-target-valid? a)
  (define sym (uh-type a))
  (define cur-hp (uh-total-hp a))
  (define max-hp (uh-max-total-hp a))
  (define is-fort? (and (memq sym '(planetary-fortress bunker missile-turret)) #t))
  (and (spell-valid-for-target-attrs? 'repair sym)
       (not (uh-hallucination? a))
       (> max-hp 0.0)
       (< cur-hp (- max-hp 0.5))
       (if is-fort?
           (and (< (uh-hp-ratio a) 0.98)
                (>= (- max-hp cur-hp) 5.0))
           (and (< (uh-hp-ratio a) 0.90)
                (>= (- max-hp cur-hp) 15.0)))))

(: scv-repair-priority (-> Symbol Float))
(define (scv-repair-priority sym)
  (cond
    [(not (spell-valid-for-target-attrs? 'repair sym)) 0.0]
    [else
     (case sym
       [(battlecruiser thor thor-ap siege-tank-sieged siege-tank) 130.0]
       [(liberator-ag liberator viking viking-fighter banshee raven cyclone medivac) 115.0]
       [(planetary-fortress bunker missile-turret) 105.0]
       [(hellbat hellion widow-mine widow-mine-burrowed) 95.0]
       [(command-center orbital-command barracks factory starport supply-depot supply-depot-lowered armory engineering-bay fusion-core) 80.0]
       [(scv) 65.0]
       [else 70.0])]))

(: queen-transfuse-priority (-> Symbol Float))
(define (queen-transfuse-priority sym)
  (if (not (spell-valid-for-target-attrs? 'transfusion sym))
      0.0
      (case sym
        [(ultralisk ultralisk-burrowed) 100.0]
        [(brood-lord) 95.0]
        [(queen queen-burrowed) 92.0]
        [(lurker lurker-burrowed lurker-mp lurker-mp-burrowed) 88.0]
        [(viper) 85.0]
        [(infestor infestor-burrowed) 82.0]
        [(ravager ravager-burrowed) 78.0]
        [(hydralisk hydralisk-burrowed) 72.0]
        [(roach roach-burrowed) 68.0]
        [(spine-crawler) 64.0]
        [(spore-crawler) 60.0]
        [(hatchery lair hive) 58.0]
        [else 0.0])))

(define ZERG-BILE-SIEGE-STATIC-SYMS : (Listof Symbol)
  '(siege-tank-sieged liberator-ag lurker-burrowed lurker-mp-burrowed
    warp-prism-phasing photon-cannon bunker shield-battery
    spine-crawler spore-crawler missile-turret))

(: zerg-bile-siege-or-static? (-> Any Boolean))
(define (zerg-bile-siege-or-static? e)
  (or (and (memq (uh-raw-type e) ZERG-BILE-SIEGE-STATIC-SYMS) #t)
      (and (memq (uh-type e) ZERG-BILE-SIEGE-STATIC-SYMS) #t)
      (eq? (dyn-hash-ref e 'sieged #f) #t)))

(define current-bile-allies : (Parameterof (Listof Any)) (make-parameter '()))

(define BILE-IMMOBILE-OR-BURROWED-SYMS : (Listof Symbol)
  '(siege-tank-sieged liberator-ag warp-prism-phasing
    observer-siege-mode overseer-siege-mode
    zergling-burrowed baneling-burrowed drone-burrowed
    roach-burrowed hydralisk-burrowed infestor-burrowed
    infestor-terran-burrowed queen-burrowed
    lurker-burrowed lurker-mp-burrowed
    ravager-burrowed swarm-host-burrowed swarm-host-mp-burrowed
    widow-mine-burrowed
    creep-tumor creep-tumor-burrowed creep-tumor-queen
    spine-crawler spore-crawler
    larva egg baneling-cocoon ravager-cocoon
    lurker-cocoon lurker-mp-egg overlord-cocoon transport-overlord-cocoon))

(: ally-immobile-or-burrowed? (-> Any Boolean))
(define (ally-immobile-or-burrowed? a)
  (define ut (uh-type a))
  (define uraw (uh-raw-type a))
  (or (uh-burrowed? a)
      (eq? (dyn-hash-ref a 'burrowed #f) #t)
      (eq? (dyn-hash-ref a 'is-burrowed #f) #t)
      (eq? (dyn-hash-ref a 'sieged #f) #t)
      (eq? (dyn-hash-ref a 'immobile? #f) #t)
      (eq? (dyn-hash-ref a 'is-building #f) #t)
      (and (memq ut BILE-IMMOBILE-OR-BURROWED-SYMS) #t)
      (and (memq uraw BILE-IMMOBILE-OR-BURROWED-SYMS) #t)
      (and (memq ut SC2-ALL-STRUCTURE-SYMS) #t)
      (and (memq uraw SC2-ALL-STRUCTURE-SYMS) #t)))

(: corrosive-bile-target-safe? (-> Float Float (Listof Any) Boolean))
(define (corrosive-bile-target-safe? tx ty allies)
  (cond
    [(null? allies) #t]
    [else
     (let loop ([rem : (Listof Any) allies]
                [ground-cnt : Integer 0])
       (cond
         [(null? rem) #t]
         [else
          (define a (car rem))
          (cond
            [(not (and (hash? a)
                       (or (> (uh-total-hp a) 0.0)
                           (and (not (dyn-hash-has-key? a 'hp))
                                (not (dyn-hash-has-key? a 'hull-hp))))
                       (not (uh-hallucination? a))))
             (loop (cdr rem) ground-cnt)]
            [(> (dist2 tx ty (uh-x a) (uh-y a)) CORROSIVE-BILE-FF-CHECK-RADIUS)
             (loop (cdr rem) ground-cnt)]
            [(ally-immobile-or-burrowed? a)
             #f]
            [(not (uh-flying? a))
             (define next-cnt (+ ground-cnt 1))
             (if (>= next-cnt 2)
                 #f
                 (loop (cdr rem) next-cnt))]
            [else
             (loop (cdr rem) ground-cnt)])]))]))

(: ravager-try-bile-point!
   (->* (spell-claims Integer Float Float Float Float Float Boolean Integer Symbol)
        (#:allies (Listof Any))
        (Option spell-directive)))
(define (ravager-try-bile-point! claims r-tag rx ry bx by cluster-hp force-field? current-frame pattern
                               #:allies [allies (current-bile-allies)])
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
            (corrosive-bile-target-safe? cx cy allies)
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
  ;; Strictly requires not 'frenzied (rejects Ultralisk) and not 'heroic/'structure
  (if (not (spell-valid-for-target-attrs? 'neural-parasite sym))
      0.0
      (case sym
        [(carrier) 130.0]
        [(battlecruiser) 125.0]
        [(tempest) 118.0]
        [(thor thor-ap) 115.0]
        [(colossus) 112.0]
        [(siege-tank-sieged siege-tank) 108.0]
        [(archon) 105.0]
        [(immortal) 102.0]
        [(liberator-ag liberator) 96.0]
        [(high-templar ghost viper) 88.0]
        [else 0.0])))

(: enemy-fungal-value-weight (-> Symbol Float))
(define (enemy-fungal-value-weight sym)
  (define base
    (case sym
      [(mutalisk phoenix) 1.6]
      [(stalker blink-stalker adept hellion reaper) 1.45]
      [(marine zergling baneling medivac viking viking-fighter banshee) 1.3]
      [(high-templar ghost oracle hydralisk dark-templar) 1.25]
      [else 1.0]))
  (define attr-boost
    (+ 1.0
       (if (unit-attr-has-any? sym SC2-UNIT-ATTR-LIGHT) 0.25 0.0)
       (if (unit-attr-has-any? sym SC2-UNIT-ATTR-BIOLOGICAL) 0.15 0.0)))
  (define pack (aoe-radius-packing-multiplier (unit-collision-radius sym) 2.25))
  (* base attr-boost pack))

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
  ;; Strictly requires not 'frenzied and 'armored or 'massive
  (if (not (and (spell-valid-for-target-attrs? 'abduct sym)
                (unit-attr-has-any? sym (fxior SC2-UNIT-ATTR-ARMORED SC2-UNIT-ATTR-MASSIVE))))
      0.0
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
        [(archon brood-lord disruptor void-ray) 88.0]
        [else 0.0])))

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
  '(ghost raven battlecruiser medivac cyclone scv))

(define PROTOSS-CASTER-SYMS : (Listof Symbol)
  '(sentry high-templar oracle phoenix disruptor))

(: zerg-upgrade-ready? (-> (Listof Any) Symbol Boolean Boolean))
(define (zerg-upgrade-ready? upgrades target-sym fallback-flag)
  (if (null? upgrades)
      fallback-flag
      (or fallback-flag
          (for/or : Boolean ([up (in-list upgrades)])
            (eq? (safe-sym up 'unknown) target-sym)))))

(: run-zerg-spellcaster-micro
   (->* ((Listof Any) (Listof Any) (Listof Any) spell-claims Integer
         (Listof Any) (Listof Any) (Listof Any) Float Float Float Float
         (Listof Integer) (Listof Integer))
        ((Listof Any) Boolean)
        (Listof spell-directive)))
(define (run-zerg-spellcaster-micro
         caster-units ally-units enemy-units
         claims current-frame ally-buildings enemy-buildings effects
         home-x home-y enemy-base-x enemy-base-y
         inject-queen-tags exclude-tags
         [researched-upgrades '()]
         [neural-parasite-researched? #t])
  (define all-enemies (if (null? enemy-buildings) enemy-units (append enemy-units enemy-buildings)))
  (define all-allies (if (null? ally-buildings) ally-units (append ally-units ally-buildings)))
  ;; W8-TAC-2: Gate Infestor Neural Parasite (249) on 'neural-parasite upgrade
  (define neural-ok? (zerg-upgrade-ready? researched-upgrades 'neural-parasite neural-parasite-researched?))

  (define-values (dirs-rev _)
    (parameterize ([current-bile-allies all-allies])
      (for/fold ([acc : (Listof spell-directive) '()]
                 [used-tags : (Listof Integer) exclude-tags])
                ([u (in-list caster-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used-tags) (uh-hallucination? u))
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
                     (or
                      (let-values ([(ok? tgt _w)
                                    (best-unit-target
                                     ux uy 9.5 all-allies
                                     (lambda ([a : Any])
                                       (and (not (= (uh-tag a) tag))
                                            (not (uh-hallucination? a))
                                            (> (queen-transfuse-priority (uh-type a)) 0.0)
                                            (>= (uh-missing-hp a) 55.0)
                                            (< (uh-hp-ratio a) 0.70)
                                            (< (spell-unit-claim-count claims 'transfusion (uh-tag a) current-frame)
                                               (unit-claim-effective-cap 'transfusion 0.0 (uh-missing-hp a) #f #t))))
                                     (lambda ([a : Any])
                                       (- (+ (queen-transfuse-priority (uh-type a))
                                             (* 30.0 (- 1.0 (uh-hp-ratio a)))
                                             (min 40.0 (* 0.25 (uh-missing-hp a))))
                                          (* 25.0 (->float (spell-unit-claim-count claims 'transfusion (uh-tag a) current-frame))))))])
                        (and ok?
                             (let ([ttag (uh-tag tgt)])
                               (and (spell-claim-unit?!
                                     claims 'transfusion ttag current-frame UNIT-SPELL-CLAIM-TTL
                                     #:caster-tag tag #:missing-hp (uh-missing-hp tgt))
                                    (spell-directive tag 'queen 'transfusion 'unit ttag
                                                     (uh-x tgt) (uh-y tgt) 'queen-transfuse)))))
                      ;; L27-P0-3 (`z12` mineral-line last-stand): when a lone defending Queen has
                      ;; NO high-HP ally (`queen-transfuse-priority > 0`) within 14t and >= 4 enemy
                      ;; rushers are within 8.0t, Transfuse a critically wounded defending Zergling
                      ;; or Drone (`< 58%` HP) rather than dying with unspent 50+ energy!
                      (and (not (any-unit-within?
                                 all-allies ux uy 14.0
                                 (lambda ([a : Any])
                                   (and (not (= (uh-tag a) tag))
                                        (> (queen-transfuse-priority (uh-type a)) 0.0)))))
                           (>= (count-units-within enemy-units ux uy 8.0 sc2-enemy-unit-targetable?) 4)
                           (let-values ([(ok? tgt _w)
                                         (best-unit-target
                                          ux uy 7.0 ally-units
                                          (lambda ([a : Any])
                                            (and (not (= (uh-tag a) tag))
                                                 (memq (uh-type a) '(zergling drone baneling))
                                                 (>= (uh-missing-hp a) 15.0)
                                                 (< (uh-hp-ratio a) 0.58)
                                                 (= (spell-unit-claim-count claims 'transfusion (uh-tag a) current-frame) 0)))
                                          (lambda ([a : Any])
                                            (+ (if (eq? (uh-type a) 'zergling) 40.0 25.0)
                                               (* 40.0 (- 1.0 (uh-hp-ratio a))))))])
                             (and ok?
                                  (let ([ttag (uh-tag tgt)])
                                    (and (spell-claim-unit?!
                                          claims 'transfusion ttag current-frame UNIT-SPELL-CLAIM-TTL
                                          #:caster-tag tag #:missing-hp (uh-missing-hp tgt))
                                         (spell-directive tag 'queen 'transfusion 'unit ttag
                                                          (uh-x tgt) (uh-y tgt) 'queen-transfuse)))))))))
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
                 (and neural-ok?
                      (>= en SC2-INFESTOR-NEURAL-ENERGY)
                      friendly-army-near?
                      (let-values ([(ok? tgt _w)
                                    (best-unit-target
                                     ux uy SC2-INFESTOR-NEURAL-CAST-RANGE enemy-units
                                     (lambda ([e : Any])
                                       (and (not (uh-has-buff? e 'neural-parasite))
                                            (= (spell-unit-claim-count claims 'neural-parasite (uh-tag e) current-frame) 0)
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
                 ;; L39-P0-1d + L40-P0-1e (`z14` + `novel-116`): If ANOTHER Infestor already claimed a
                 ;; Neural (or Neural-approach) on this tick AND THIS Infestor does NOT already hold an
                 ;; active `neural-approach` reservation AND no Fungal has been claimed yet AND a
                 ;; `>= 3`-unit un-fungaled enemy cluster is in Fungal range, let THIS Infestor open
                 ;; with Fungal Growth first so mixed packs get BOTH Neural + Fungal simultaneously
                 ;; while approaching Infestors keep walking uninterrupted to fire NeuralParasite!
                 (when (< en SC2-INFESTOR-NEURAL-ENERGY)
                   ;; Release stale `neural-approach` reservation if THIS Infestor dropped < 100e
                   ;; (e.g. EMP or Fungal) so another loaded Infestor immediately takes over!
                   (set-spell-claims-unit-claims!
                    claims
                    (for/list : (Listof unit-claim)
                              ([c (in-list (spell-claims-unit-claims claims))]
                               #:unless (and (eq? (unit-claim-ability c) 'neural-approach)
                                             (= (unit-claim-caster-tag c) tag)))
                      c)))
                 (define self-has-neural-approach?
                   (for/or : Boolean ([c (in-list (spell-claims-unit-claims claims))])
                     (and (eq? (unit-claim-ability c) 'neural-approach)
                          (= (unit-claim-caster-tag c) tag)
                          (> (unit-claim-expires-frame c) current-frame))))
                 (define neural-already-claimed-now?
                   (for/or : Boolean ([c (in-list (spell-claims-unit-claims claims))])
                     (and (memq (unit-claim-ability c) '(neural-parasite neural-approach))
                          (not (= (unit-claim-caster-tag c) tag))
                          (> (unit-claim-expires-frame c) current-frame)
                          (or (= (unit-claim-frame c) current-frame)
                              (eq? (unit-claim-ability c) 'neural-approach)))))
                 (define fungal-already-claimed-now?
                   (for/or : Boolean ([c (in-list (spell-claims-point-claims claims))])
                     (and (eq? (point-claim-ability c) 'fungal-growth)
                          (> (point-claim-expires-frame c) current-frame))))
                 (define defer-second-neural-for-opening-fungal?
                   (and (not self-has-neural-approach?)
                        neural-already-claimed-now?
                        (not fungal-already-claimed-now?)
                        (>= en SC2-INFESTOR-FUNGAL-ENERGY)
                        (let-values ([(ok? _fx _fy _s)
                                      (best-enemy-cluster
                                       ux uy SC2-INFESTOR-FUNGAL-CAST-RANGE enemy-units 2.25 0.5
                                       (lambda ([_cx : Float] [_cy : Float] [cl : (Listof Any)])
                                         (define unb
                                           (for/sum : Integer ([e (in-list cl)])
                                             (if (not (uh-has-buff? e 'fungal-growth)) 1 0)))
                                         (if (>= unb 3) (->float unb) 0.0)))])
                          ok?)))
                 (or
                  ;; 1. L39-P0-1d (`z14`): Evaluate Neural Parasite (`100e`, ab `249`, range `9.0`,
                  ;;    requires 'neural-parasite upgrade + friendly army `< 11.0`) STRICTLY BEFORE
                  ;;    Fungal Growth so loaded Infestors hijack Sieged Tanks/Thors/Colossi/Capitals
                  ;;    instead of dropping below 100e on an opening Bio Fungal!
                  (and neural-ok?
                       (not defer-second-neural-for-opening-fungal?)
                       (>= en SC2-INFESTOR-NEURAL-ENERGY)
                       friendly-army-near?
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy SC2-INFESTOR-NEURAL-CAST-RANGE enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-has-buff? e 'neural-parasite))
                                             (= (spell-unit-claim-count claims 'neural-parasite (uh-tag e) current-frame) 0)
                                             (> (infestor-neural-weight (uh-type e)) 0.0)))
                                      (lambda ([e : Any]) (infestor-neural-weight (uh-type e))))])
                         (and ok?
                              (spell-claim-unit?! claims 'neural-parasite (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'infestor 'neural-parasite 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'infestor-neural))))
                  ;; 1b. L39-P0-1d + L40-P0-1e (`z14`): When an unclaimed (or self-claimed!) high-value
                  ;;     Neural target (`>= 102.0`: SiegeTankSieged/Thor/Colossus/Carrier/BC/Tempest/Archon/Immortal)
                  ;;     sits just outside cast range (`9.0..14.0t`), reserve 1 approaching Infestor per target
                  ;;     and ALLOW the same `caster-tag` to renew and continue its own `neural-approach` claim
                  ;;     on tick 2..N instead of self-blocking and falling through to Fungal!
                  (and neural-ok?
                       (not defer-second-neural-for-opening-fungal?)
                       (>= en SC2-INFESTOR-NEURAL-ENERGY)
                       friendly-army-near?
                       (not (any-unit-within? enemy-units ux uy (if (< (uh-hp-ratio u) 0.60) 4.5 3.5) sc2-enemy-unit-targetable?))
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 14.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-has-buff? e 'neural-parasite))
                                             (= (spell-unit-claim-count claims 'neural-parasite (uh-tag e) current-frame) 0)
                                             (not (spell-unit-claimed-by-other? claims 'neural-approach (uh-tag e) tag current-frame))
                                             (>= (infestor-neural-weight (uh-type e)) 102.0)))
                                      (lambda ([e : Any])
                                        (+ (infestor-neural-weight (uh-type e))
                                           (if (spell-unit-claimed-by-self? claims 'neural-approach (uh-tag e) tag current-frame)
                                               50.0
                                               0.0))))])
                         (and ok?
                              (or (spell-renew-unit-claim! claims 'neural-approach (uh-tag tgt) tag current-frame 12)
                                  (spell-claim-unit?! claims 'neural-approach (uh-tag tgt) current-frame 12
                                                      #:caster-tag tag #:max-casters 1))
                              (let* ([ex (uh-x tgt)]
                                     [ey (uh-y tgt)]
                                     [dx (- ex ux)]
                                     [dy (- ey uy)]
                                     [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                     [step (max 0.5 (- d 8.2))]
                                     [ax (clamp-coord (+ ux (* step (/ dx d))))]
                                     [ay (clamp-coord (+ uy (* step (/ dy d))))])
                                (spell-directive tag 'infestor 'move 'move 0 ax ay 'infestor-neural-approach)))))
                  ;; 2. L59-P2 (`sc2-ab-z01` fix): Microbial Shroud (`4111`) vs `>= 3` air threats
                  ;;    over `>= 3` friendly ground combat units PRIORITIZED above Fungal Growth when
                  ;;    not deferring for Neural/Fungal opening split (`novel-116` safe!), so Infestors
                  ;;    protect Hydralisks from Carriers/Tempests before spending energy on Fungal!
                  (and (not defer-second-neural-for-opening-fungal?)
                       (not neural-ok?)
                       (>= en 75.0)
                       (>= (count-units-within enemy-units ux uy 16.0 enemy-air-capital-or-ranged?) 3)
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
                  ;; 3. Fungal Growth (`0.5`-tile velocity lead, `r=2.25 ttl=32`)
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
                  ;; 3b. Microbial Shroud fallback when Neural IS researched and no Fungal target is in range
                  (and neural-ok?
                       (>= en 75.0)
                       (>= (count-units-within enemy-units ux uy 16.0 enemy-air-capital-or-ranged?) 3)
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
                  ;; 1. Blinding Cloud on >= 2 ground ranged clumps, prioritizing 'armored/'mechanical lines (`range 11.0`)
                  (and (>= en 100.0)
                       (let-values ([(ok? cx cy _s)
                                     (best-enemy-cluster
                                      ux uy 12.5 enemy-units 2.0 0.0
                                      (lambda ([px : Float] [py : Float] [cl : (Listof Any)])
                                        (define-values (rcnt score)
                                          (for/fold ([cnt : Integer 0] [sc : Float 0.0])
                                                    ([e (in-list cl)])
                                            (if (and (viper-ranged-ground? e)
                                                     (not (uh-has-buff? e 'blinding-cloud)))
                                                (let* ([esym (uh-type e)]
                                                       [pack (aoe-radius-packing-multiplier
                                                              (unit-collision-radius esym) 2.0)]
                                                       [w (* pack
                                                             (+ 1.0
                                                                (if (unit-attr-has-any? esym SC2-UNIT-ATTR-ARMORED) 0.40 0.0)
                                                                (if (unit-attr-has-any? esym SC2-UNIT-ATTR-MECHANICAL) 0.40 0.0)))])
                                                  (values (+ cnt 1) (+ sc w)))
                                                (values cnt sc))))
                                        (if (and (>= rcnt 2)
                                                 (not (spell-point-claimed? claims 'blinding-cloud px py BLINDING-CLOUD-CLAIM-RADIUS current-frame)))
                                            score
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'blinding-cloud cx cy BLINDING-CLOUD-CLAIM-RADIUS current-frame BLINDING-CLOUD-CLAIM-TTL)
                              (spell-directive tag 'viper 'blinding-cloud 'point 0 cx cy 'viper-blinding-cloud))))
                  ;; 2. L27-P0-3 / L28-P0-3 / L29-P0-3 (`z07`/`z08`/`#16`): Prioritize Parasitic Bomb
                  ;;    (`energy >= 125`, `r=8.5`, `>= 2` air within `4.5t`) STRICTLY ABOVE Abduct AND
                  ;;    HOLD Abduct whenever an unbombed `>= 2` air clump sits inside `13.0t` so Vipers
                  ;;    step in and drop ParasiticBomb instead of burning 75e (`140 -> 65 < 125`)!
                  (let ([pbomb-clump-in-13t?
                         (and (>= en 125.0)
                              (any-unit-within?
                               enemy-units ux uy 13.0
                               (lambda ([e : Any])
                                 (and (enemy-air-capital-or-ranged? e)
                                      (not (uh-has-buff? e 'parasitic-bomb))
                                      (>= (count-units-within enemy-units (uh-x e) (uh-y e) 4.5 enemy-air-capital-or-ranged?) 2)
                                      (not (any-unit-within?
                                            enemy-units (uh-x e) (uh-y e) 4.0
                                            (lambda ([d : Any])
                                              (or (eq? (uh-type d) 'parasitic-bomb-dummy)
                                                  (= (safe-int (dyn-hash-ref d 'unit-type-id 0) 0) 824)
                                                  (= (safe-int (dyn-hash-ref d 'type 0) 0) 824)
                                                  (uh-has-buff? d 'parasitic-bomb)))))
                                      (not (spell-point-claimed? claims 'parasitic-bomb-zone (uh-x e) (uh-y e) 3.5 current-frame))))))])
                    (or
                     (and (>= en 125.0)
                          (let-values ([(ok? tgt _w)
                                        (best-unit-target
                                         ux uy 8.5 enemy-units
                                         (lambda ([e : Any])
                                           (and (enemy-air-capital-or-ranged? e)
                                                (not (uh-has-buff? e 'parasitic-bomb))
                                                (>= (count-units-within enemy-units (uh-x e) (uh-y e) 4.5 enemy-air-capital-or-ranged?) 2)
                                                (not (any-unit-within?
                                                      enemy-units (uh-x e) (uh-y e) 4.0
                                                      (lambda ([d : Any])
                                                        (or (eq? (uh-type d) 'parasitic-bomb-dummy)
                                                            (= (safe-int (dyn-hash-ref d 'unit-type-id 0) 0) 824)
                                                            (= (safe-int (dyn-hash-ref d 'type 0) 0) 824)
                                                            (uh-has-buff? d 'parasitic-bomb)))))
                                                (not (spell-point-claimed? claims 'parasitic-bomb-zone (uh-x e) (uh-y e) 3.5 current-frame))))
                                         (lambda ([e : Any])
                                           (define air-cnt (count-units-within enemy-units (uh-x e) (uh-y e) 4.5 enemy-air-capital-or-ranged?))
                                           (define pack (aoe-radius-packing-multiplier (unit-collision-radius (uh-type e)) 3.0))
                                           (+ (* 20.0 pack (->float air-cnt))
                                              (min 100.0 (* 0.2 (uh-total-hp e))))))])
                            (and ok?
                                 (spell-claim-unit?! claims 'parasitic-bomb (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                     #:caster-tag tag)
                                 (begin
                                   (spell-claim-point?! claims 'parasitic-bomb-zone (uh-x tgt) (uh-y tgt) 3.5 current-frame 64)
                                   (spell-directive tag 'viper 'parasitic-bomb 'unit (uh-tag tgt)
                                                    (uh-x tgt) (uh-y tgt) 'viper-parasitic-bomb)))))
                     ;; 3. Abduct into >= 4 friendly combat units within 9.0 (`energy >= 75`, approach <= 13.0),
                     ;;    held when `pbomb-clump-in-13t?` OR `bcloud-clump-in-15t?` is active so Vipers
                     ;;    always land Blinding Cloud (`100e`) / Parasitic Bomb (`125e`) before spending `75e` on Abduct!
                     (let ([bcloud-clump-in-15t?
                            (and (>= en 100.0)
                                 (any-unit-within?
                                  enemy-units ux uy 15.0
                                  (lambda ([e : Any])
                                    (and (viper-ranged-ground? e)
                                         (not (uh-has-buff? e 'blinding-cloud))
                                         (>= (count-units-within enemy-units (uh-x e) (uh-y e) 2.5
                                                                 (lambda ([o : Any])
                                                                   (and (viper-ranged-ground? o)
                                                                        (not (uh-has-buff? o 'blinding-cloud)))))
                                             2)
                                         (not (spell-point-claimed? claims 'blinding-cloud (uh-x e) (uh-y e)
                                                                    BLINDING-CLOUD-CLAIM-RADIUS current-frame))))))])
                       (and (not pbomb-clump-in-13t?)
                            (not bcloud-clump-in-15t?)
                            (>= en 75.0)
                            (>= (count-units-within ally-units ux uy 9.0
                                                    (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a))))
                                4)
                            (let-values ([(ok? tgt _w)
                                          (best-unit-target
                                           ux uy 13.0 enemy-units
                                           (lambda ([e : Any])
                                             (define et (uh-type e))
                                             (define d-e (dist2 ux uy (uh-x e) (uh-y e)))
                                             (and (> (viper-abduct-weight et) 0.0)
                                                  ;; Keep `13.0t` Abduct approach for capital targets (Colossus/Carrier/
                                                  ;; Tempest/BC/BroodLord/Thor), while keeping Sieged Tank Abduct at
                                                  ;; native `<= 9.0t` cast range (never stealing `100e` from Blinding Cloud
                                                  ;; at `9..13t`, and never abducting an already-blinded unit!).
                                                  (or (<= d-e 9.0)
                                                      (not (memq et '(siege-tank siege-tank-sieged))))
                                                  (not (uh-has-buff? e 'blinding-cloud))
                                                  (= (spell-unit-claim-count claims 'abduct (uh-tag e) current-frame) 0)))
                                           (lambda ([e : Any]) (viper-abduct-weight (uh-type e))))])
                              (and ok?
                                   (spell-claim-unit?! claims 'abduct (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                       #:caster-tag tag)
                                   (spell-directive tag 'viper 'abduct 'unit (uh-tag tgt)
                                                    (uh-x tgt) (uh-y tgt) 'viper-abduct)))))))
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
              (define spray-unlock (hash-ref (spell-claims-corruptor-spray-ready-frame claims) tag (lambda () -1)))
              (define spray-ready?
                (and (not (eq? (dyn-hash-ref u 'caustic-spray-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'caustic-spray-cooldown 0) 0) 0)
                     (>= current-frame spray-unlock)))
              (cond
                [(or (spellcaster-channel-protected? u) (not spray-ready?)) #f]
                [else
                 (define air-or-col-threat-near?
                   (any-unit-within? enemy-units ux uy 28.0
                                     (lambda ([e : Any])
                                       (and (sc2-enemy-unit-targetable? e)
                                            (or (uh-flying? e)
                                                (eq? (uh-type e) 'colossus))))))
                 (define aa-threat-near?
                   (any-unit-within? all-enemies ux uy 11.0 enemy-anti-air-or-air-threat?))
                 (and (not aa-threat-near?)
                      (not air-or-col-threat-near?)
                      (let-values ([(ok? tgt _w)
                                    (best-unit-target
                                     ux uy 28.0 all-enemies
                                     (lambda ([e : Any])
                                       (define et (uh-type e))
                                       (and (or (memq et SC2-TOWNHALL-STRUCTURE-SYMS)
                                                (memq et '(robotics-facility stargate starport factory
                                                           gateway warp-gate barracks spire greater-spire
                                                           robotics-bay fleet-beacon twilight-council
                                                           templar-archive dark-shrine forge cybernetics-core
                                                           engineering-bay armory fusion-core ghost-academy
                                                           spawning-pool roach-warren baneling-nest
                                                           hydralisk-den infestation-pit lurker-den lurker-den-mp
                                                           ultralisk-cavern evolution-chamber
                                                           pylon supply-depot supply-depot-lowered
                                                           bunker spine-crawler spore-crawler photon-cannon
                                                           missile-turret shield-battery
                                                           assimilator extractor refinery))
                                                (eq? (dyn-hash-ref e 'structure? #f) #t))
                                            #t))
                                     (lambda ([e : Any])
                                       (define et (uh-type e))
                                       (define mult
                                         (cond
                                           [(memq et SC2-TOWNHALL-STRUCTURE-SYMS) 2.5]
                                           [(memq et '(robotics-facility stargate starport factory
                                                       gateway warp-gate barracks spire greater-spire))
                                            1.5]
                                           [else 1.0]))
                                       (- (* mult (max 100.0 (uh-total-hp e)))
                                          (* 20.0 (dist2 ux uy (uh-x e) (uh-y e))))))])
                        (and ok?
                             (begin
                               (hash-set! (spell-claims-corruptor-spray-ready-frame claims)
                                          tag
                                          (+ current-frame CORRUPTOR-CAUSTIC-SPRAY-COOLDOWN-FRAMES))
                               (spell-directive tag 'corruptor 'caustic-spray 'unit (uh-tag tgt)
                                                (uh-x tgt) (uh-y tgt) 'corruptor-caustic-spray)))))])]

             ;; --- OVERSEER (Contaminate 1825/182, SpawnChangeling 181, Oversight 3743/1912) ---
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
              (define-values (contam-cand-ok? contam-cand _contam-w)
                (if (>= en 100.0)
                    (best-unit-target
                     ux uy 28.0 enemy-buildings
                     (lambda ([b : Any])
                       (and (> (contam-weight b) 0.0)
                            (not (uh-has-buff? b 'contaminate))
                            (= (spell-unit-claim-count claims 'contaminate (uh-tag b) current-frame) 0)))
                     (lambda ([b : Any])
                       (- (contam-weight b) (* 2.5 (dist2 ux uy (uh-x b) (uh-y b))))))
                    (values #f #f 0.0)))
              (cond
                [(spellcaster-channel-protected? u) #f]
                [(and (eq? sym 'overseer-siege-mode) aa-near?)
                 (spell-directive tag sym 'morph-overseer-mode 'none 0 ux uy 'overseer-unmorph-mobile-follow)]
                [else
                 (define nydus-needs-changeling?
                   (and (>= en 50.0)
                        (for/or : Boolean ([b (in-list ally-buildings)])
                          (and (hash? b) (eq? (uh-type b) 'nydus-network)))
                        (not (for/or : Boolean ([a (in-list ally-units)])
                               (and (hash? a)
                                    (memq (uh-type a) '(changeling changeling-zealot changeling-marine
                                                        changeling-marine-shield changeling-zergling
                                                        changeling-zergling-wings))
                                    #t)))))
                 (or
                  ;; 0. L59-P2 (`sc2-trn-n20`): When ally owns a Nydus Network with 0 Changelings,
                  ;;    immediately cast Spawn Changeling (`181`) for Nydus vision scouting!
                  (and nydus-needs-changeling?
                       (spell-claim-unit?! claims 'spawn-changeling tag current-frame 336 #:caster-tag tag)
                       (spell-directive tag sym 'spawn-changeling 'none 0 ux uy 'overseer-changeling-nydus-vision))
                  (and oversight-wanted?
                       (eq? sym 'overseer)
                       (not aa-near?)
                       (spell-directive tag sym 'morph-oversight-mode 'none 0 ux uy 'overseer-oversight-ring-watch))
                  ;; 1. Contaminate enemy upgrade / tech / production building (`en >= 125`, approach up to `22.0t`)
                  (and (>= en 125.0)
                       contam-cand-ok?
                       (let ([btag (uh-tag contam-cand)])
                         (and (spell-claim-unit?! claims 'contaminate btag current-frame 64 #:caster-tag tag)
                              (spell-directive tag sym 'contaminate 'unit btag
                                               (uh-x contam-cand) (uh-y contam-cand) 'overseer-contaminate-upgrade-tech))))
                  ;; 2. Spawn Changeling (`en >= 50`, `336f` per-Overseer cooldown), held back when
                  ;;    `>= 100e` next to an uncontaminated production/tech building OR active frontline
                  ;;    combat (`<= 16t`) so Overseers preserve energy for Contaminate (`1825`)!
                  (and (>= en 50.0)
                       (not contam-cand-ok?)
                       (not (and (>= en 100.0)
                                 (any-unit-within? all-enemies ux uy 16.0 unit-combat-relevant?)))
                       (spell-claim-unit?! claims 'spawn-changeling tag current-frame 336 #:caster-tag tag)
                       (spell-directive tag sym 'spawn-changeling 'none 0 ux uy 'overseer-changeling-ramp-block))
                  ;; 3. Oversight static vision anchor when `< 50` energy, safe from AA, AND no active
                  ;; nearby combat/enemy engagement (`<= 22t`) so Overseer stays mobile to detect
                  ;; cloaked Observers/DTs/Banshees during fights instead of spamming Oversight!
                  (and (eq? sym 'overseer)
                       (not aa-near?)
                       (not (any-unit-within? all-enemies ux uy 22.0 unit-combat-relevant?))
                       (not (any-unit-within? all-enemies ux uy 22.0
                                              (lambda ([e : Any])
                                                (and (memq (uh-type e) '(observer observer-siege-mode dark-templar banshee ghost)) #t))))
                       (> (dist2 ux uy home-x home-y) 8.0)
                       (spell-claim-unit?! claims 'morph-oversight-mode tag current-frame 160 #:caster-tag tag)
                       (spell-directive tag sym 'morph-oversight-mode 'none 0 ux uy 'overseer-oversight-ring-watch)))])]

             ;; --- SWARM HOST (Spawn Locusts 2704) ---
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
              (define raw-sym (uh-raw-type u))
              (define lurker-is-burrowed?
                (or (memq raw-sym '(lurker-burrowed lurker-mp-burrowed))
                    (eq? (dyn-hash-ref u 'burrowed #f) #t)
                    (eq? (dyn-hash-ref u 'is-burrowed #f) #t)))
              (define luz (uh-z u))
              (define cliff-ladder-ready?
                (and luz
                     (any-unit-within?
                      ally-units ux uy 11.0
                      (lambda ([a : Any])
                        (or (eq? (uh-raw-type a) 'overlord-transport)
                            (= (safe-int (dyn-hash-ref a 'unit-type-id 0) 0) 893))))
                     (any-unit-within?
                      enemy-units ux uy 16.0
                      (lambda ([e : Any])
                        (define ez (uh-z e))
                        ;; L59-P3 (`n16` fix): Strictly UPHILL enemies (`ez - luz >= 1.5`), never downhill
                        ;; once the Lurker has already been dropped on high ground!
                        (and (ground-enemy? e) ez (>= (- ez luz) 1.5))))
                     (not (any-unit-within?
                           enemy-units ux uy 9.5
                           (lambda ([e : Any])
                             (define ez (uh-z e))
                             (and (ground-enemy? e) (or (not ez) (< (- ez luz) 1.5))))))))
              (cond
                [(and (not lurker-is-burrowed?) (memq sym '(lurker lurker-mp)))
                 (and (not cliff-ladder-ready?)
                      (not (spellcaster-channel-protected? u))
                      (not (= (safe-int (dyn-hash-ref u 'order-ability-id 0) 0) 2108))
                      (any-unit-within? enemy-units ux uy 9.5 ground-enemy?)
                      (spell-directive tag sym 'burrow-lurker 'none 0 ux uy 'lurker-burrow-choke-siege))]
                [else
                 (define hazard?
                   (or (any-effect-within? effects 'purification-nova ux uy 3.5 (lambda ([_ef : Any]) #t))
                       (any-effect-within? effects 'psi-storm ux uy 3.0 (lambda ([_ef : Any]) #t))
                       (any-effect-within? effects 'corrosive-bile ux uy 2.5 (lambda ([_ef : Any]) #t))))
                 (define idle-frames (safe-int (dyn-hash-ref u 'burrowed-idle-frames 0) 0))
                 (and (not (= (safe-int (dyn-hash-ref u 'order-ability-id 0) 0) 2110))
                      (or hazard?
                          cliff-ladder-ready?
                          (and (>= idle-frames 24)
                               (not (any-unit-within? enemy-units ux uy 13.0 ground-enemy?))))
                      (spell-directive tag sym 'unburrow-lurker 'none 0 ux uy 'lurker-unburrow-reposition))])]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used-tags))
             (values acc used-tags))]))))
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
         #:researched-upgrades (Listof Any)
         #:neural-parasite-researched? Boolean
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
         #:researched-upgrades [researched-upgrades '()]
         #:neural-parasite-researched? [neural-parasite-researched? #t]
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
       enemy-base-x enemy-base-y inject-queen-tags exclude-tags
       researched-upgrades neural-parasite-researched?)))

;; -----------------------------------------------------------------------------
;; 7. Terran Spellcaster Patterns (Ghost, Raven, Battlecruiser)
;; -----------------------------------------------------------------------------

(: ghost-emp-target-bonus (-> Any Float))
(define (ghost-emp-target-bonus e)
  (define sym (uh-type e))
  (define sh (uh-shields e))
  (define en (uh-energy e))
  (cond
    [(not (spell-valid-for-target-attrs? 'emp-round sym en sh)) 0.0]
    [else
     (define psi? (unit-attr-has-any? sym SC2-UNIT-ATTR-PSIONIC))
     (define shielded? (or (> sh 0.0) (unit-attr-has-any? sym SC2-UNIT-ATTR-SHIELDED)))
     (define pack (aoe-radius-packing-multiplier (unit-collision-radius sym) 1.5))
     (define sh-score (if shielded? (min 100.0 sh) 0.0))
     (define psi-score (+ (if psi? 60.0 0.0) (min 100.0 en)))
     (* pack (+ sh-score psi-score))]))

(: ghost-snipe-weight (-> Any Float))
(define (ghost-snipe-weight e)
  ;; Steady Targeting strictly requires 'biological and rejects Mechanical & Archon ('psionic+'massive)
  (define sym (uh-type e))
  (if (or (not (spell-valid-for-target-attrs? 'steady-targeting sym))
          (unit-attr-has-any? sym SC2-UNIT-ATTR-MECHANICAL))
      0.0
      (case sym
        [(lurker-burrowed lurker-mp-burrowed lurker lurker-mp) 130.0]
        [(viper) 128.0]
        [(ultralisk ultralisk-burrowed) 126.0]
        [(brood-lord) 125.0]
        [(infestor infestor-burrowed)
         (if (or (>= (uh-energy e) 50.0) (>= (uh-total-hp e) 110.0)) 122.0 80.0)]
        [(ravager ravager-burrowed) 105.0]
        [(high-templar ghost) 100.0]
        [(queen queen-burrowed) 95.0]
        [(corruptor swarm-host swarm-host-mp swarm-host-burrowed) 85.0]
        [(mutalisk marauder) 75.0]
        [else 0.0])))

(: raven-matrix-weight (-> Any Float))
(define (raven-matrix-weight e)
  ;; Interference Matrix strictly requires 'mechanical or 'psionic and not 'frenzied (rejects Ultralisk/Roach/Lurker)
  (define sym (uh-type e))
  (if (not (spell-valid-for-target-attrs? 'interference-matrix sym))
      0.0
      (case sym
        [(colossus) 130.0]
        [(siege-tank-sieged) 128.0]
        [(carrier mothership tempest) 124.0]
        [(battlecruiser) 122.0]
        [(thor thor-ap) 118.0]
        [(immortal) 114.0]
        [(infestor infestor-burrowed viper high-templar) 112.0]
        [(archon) 106.0]
        [(siege-tank liberator-ag liberator cyclone void-ray) 98.0]
        [(raven ghost warp-prism warp-prism-phasing oracle disruptor banshee) 92.0]
        [else 0.0])))

(: bc-yamato-weight (-> Any Float))
(define (bc-yamato-weight e)
  (case (uh-type e)
    [(carrier mothership) 130.0]
    [(battlecruiser) 126.0]
    [(tempest) 122.0]
    [(planetary-fortress) 120.0]
    [(thor thor-ap) 118.0]
    [(viper) 116.0]
    [(corruptor) 112.0]
    [(viking viking-fighter) 106.0]
    [(infestor archon) 102.0]
    [(high-templar) 96.0]
    [(queen) 94.0]
    [(spore-crawler) 92.0]
    [(missile-turret photon-cannon) 90.0]
    [(stalker bunker) 88.0]
    [else 0.0]))

(: terran-upgrade-ready? (-> (Listof Any) Symbol Boolean Boolean))
(define (terran-upgrade-ready? upgrades target-sym fallback-flag)
  (if (null? upgrades)
      fallback-flag
      (or fallback-flag
          (for/or : Boolean ([up (in-list upgrades)])
            (eq? (safe-sym up 'unknown) target-sym)))))

(: run-terran-spellcaster-micro
   (->* ((Listof Any) (Listof Any) (Listof Any) spell-claims Integer
         (Listof Any) (Listof Any) (Listof Any) (Listof Any) Boolean Float Float
         (Listof Integer))
        ((Option (Listof Any)) Boolean Boolean)
        (Listof spell-directive)))
(define (run-terran-spellcaster-micro
         caster-units ally-units enemy-units
         claims current-frame ally-buildings enemy-buildings _effects
         researched-upgrades yamato-researched? home-x home-y exclude-tags
         [precomputed-repair-targets #f]
         [ghost-cloak-researched? #t]
         [interference-matrix-researched? #t])
  (define all-enemies (if (null? enemy-buildings) enemy-units (append enemy-units enemy-buildings)))
  ;; L40-P0-1d (`#918/#919`, `t15`): SC2 4.10/5.0 still requires Fusion Core `WeaponRefit`
  ;; (upgrade ID `76`, `'weapon-refit`) to unlock Battlecruiser Yamato Cannon (`401`).
  (define yamato-ok?
    (or yamato-researched?
        (for/or : Boolean ([up (in-list researched-upgrades)])
          (or (eq? (safe-sym up 'unknown) 'weapon-refit)
              (and (exact-integer? up) (= up 76))))))
  (define ghost-cloak-ok? (terran-upgrade-ready? researched-upgrades 'personal-cloaking ghost-cloak-researched?))
  ;; L51-W2 (`#1262/#1263`): SC2 5.0.14 locks Raven Interference Matrix (`3747`) behind
  ;; StarportTechLab `807` (`upg 300` on PersephoneAIE_v4/TorchesAIE_v4, `upg 299` on AcropolisAIE).
  (define interference-matrix-ok?
    (or interference-matrix-researched?
        (for/or : Boolean ([up (in-list researched-upgrades)])
          (or (eq? (safe-sym up 'unknown) 'interference-matrix)
              (and (exact-integer? up) (or (= up 299) (= up 300)))))))

  (define-values (dirs-rev _)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used-tags : (Listof Integer) exclude-tags])
              ([u (in-list caster-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used-tags) (uh-hallucination? u))
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
                 ;; W4-TAC-1 + W4-TAC-5 + L30/L31/L32-P0-3 (`t04` Ghost Snipe Priority): When an unshielded
                 ;; heavy-biological Snipe target (Ultralisk/BroodLord/Lurker) is in range (<= 10t),
                 ;; evaluate Snipe BEFORE non-shield EMP regardless of energy, only casting EMP first if
                 ;; `>= 160` shields or `>= 2` shielded psionics exist; hold `snipe-danger-r = 1.8t` when
                 ;; Bio-screened OR `2.0t` when heavy-bio target is in range & Ghost cannot cloak (preserving
                 ;; `novel-62` cloak-first when Personal Cloaking is ready!), and let solo Ghosts step `2.2t`
                 ;; away/home when melee closes `< snipe-danger-r` so Ghosts land `6–8` Snipes (`2714`)!
                 (define ghost-bio-screened?
                   (>= (count-units-within
                        ally-units ux uy 4.5
                        (lambda ([a : Any])
                          (and (not (= (uh-tag a) tag))
                               (not (eq? (uh-type a) 'medivac))
                               (unit-combat-relevant? a))))
                       2))
                 (define heavy-bio-target-in-10? : Boolean
                   (and (>= en 50.0)
                        (any-unit-within?
                         enemy-units ux uy 10.0
                         (lambda ([e : Any])
                           (and (not (uh-hallucination? e))
                                (<= (uh-shields e) 0.0)
                                (not (eq? (memq (uh-type e)
                                                '(ultralisk ultralisk-burrowed brood-lord broodlord
                                                  lurker lurker-burrowed lurker-mp lurker-mp-burrowed))
                                          #f))
                                (< (spell-unit-claim-count claims 'steady-targeting (uh-tag e) current-frame)
                                   (unit-claim-effective-cap 'steady-targeting (uh-total-hp e) 0.0 #f #t)))))))
                 (define ghost-can-cloak-now? : Boolean
                   (and ghost-cloak-ok?
                        (>= en 50.0)
                        (not (uh-cloaked? u))
                        (> (- current-frame (hash-ref (spell-claims-ghost-cloak-frame claims) tag (lambda () -10000))) 20)
                        (not (enemy-detector-within? enemy-units enemy-buildings ux uy 10.999))))
                 (define snipe-danger-r : Float
                   (cond
                     [ghost-bio-screened? 1.8]
                     [(and heavy-bio-target-in-10? (not ghost-can-cloak-now?)) 2.0]
                     [else 4.499]))
                 (define (enemy-melee-threat? [e : Any]) : Boolean
                   (and (sc2-enemy-unit-targetable? e)
                        (let ([st (cached-unit-combat-stats (uh-type e))])
                          (and (> (safe-fl (hash-ref st 'ground-dps (lambda () 0.0)) 0.0) 0.0)
                               (<= (safe-fl (hash-ref st 'ground-range (lambda () 0.0)) 0.0) 1.5)))))
                 (define (try-ghost-melee-step-back) : (Option spell-directive)
                   (define step-trigger-r : Float (if ghost-bio-screened? 1.8 2.0))
                   (and (>= en 50.0)
                        (let-values ([(m-hit? mx my md)
                                      (for/fold ([hit? : Boolean #f]
                                                 [bx : Float 0.0]
                                                 [by : Float 0.0]
                                                 [bd : Float step-trigger-r])
                                                ([e (in-list enemy-units)])
                                        (if (and (hash? e) (enemy-melee-threat? e))
                                            (let* ([ex (uh-x e)]
                                                   [ey (uh-y e)]
                                                   [d (dist2 ux uy ex ey)])
                                              (if (< d bd)
                                                  (values #t ex ey d)
                                                  (values hit? bx by bd)))
                                            (values hit? bx by bd)))])
                          (and m-hit?
                               (let-values ([(bsx bsy bcnt)
                                             (for/fold ([sx : Float 0.0]
                                                        [sy : Float 0.0]
                                                        [c : Integer 0])
                                                       ([a (in-list ally-units)])
                                               (if (and (hash? a)
                                                        (not (= (uh-tag a) tag))
                                                        (not (eq? (memq (uh-type a) '(marine marauder)) #f))
                                                        (<= (dist2 ux uy (uh-x a) (uh-y a)) 8.0))
                                                   (values (+ sx (uh-x a)) (+ sy (uh-y a)) (+ c 1))
                                                   (values sx sy c)))])
                                 (let* ([use-bio-anchor?
                                         (and (> bcnt 0)
                                              (> (dist2 (/ bsx (->float bcnt)) (/ bsy (->float bcnt)) mx my) md))]
                                        [ax (if use-bio-anchor? (/ bsx (->float bcnt)) ux)]
                                        [ay (if use-bio-anchor? (/ bsy (->float bcnt)) uy)]
                                        [dx0 (- ax mx)]
                                        [dy0 (- ay my)]
                                        [d0 (flsqrt (+ (* dx0 dx0) (* dy0 dy0)))]
                                        [dx1 (if (> d0 0.05) dx0 (- home-x ux))]
                                        [dy1 (if (> d0 0.05) dy0 (- home-y uy))]
                                        [d1 (flsqrt (+ (* dx1 dx1) (* dy1 dy1)))])
                                   (and (> d1 0.05)
                                        (let ([rx (max 2.0 (min 250.0 (+ ax (* 2.2 (/ dx1 d1)))))]
                                              [ry (max 2.0 (min 250.0 (+ ay (* 2.2 (/ dy1 d1)))))])
                                          (spell-directive tag 'ghost 'move 'move 0 rx ry
                                                           'ghost-melee-step-back)))))))))
                 (define heavy-bio-snipe-near?
                   (and heavy-bio-target-in-10?
                        (not (any-unit-within? all-enemies ux uy snipe-danger-r sc2-enemy-unit-targetable?))))
                 (define (try-ghost-emp [require-heavy-shields? : Boolean]) : (Option spell-directive)
                   (and (>= en 75.0)
                        (let-values ([(ok? ex ey _s)
                                      (best-enemy-cluster
                                       ux uy 10.0 enemy-units 2.0 0.25
                                       (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                         (define-values (shield-sum energy-sum score-sum prio? sh-psi-cnt)
                                           (for/fold ([sh-s : Float 0.0]
                                                      [en-s : Float 0.0]
                                                      [sc-s : Float 0.0]
                                                      [has-p? : Boolean #f]
                                                      [sp-c : Integer 0])
                                                     ([e (in-list cl)])
                                             (define sym (uh-type e))
                                             (define esh (uh-shields e))
                                             (define een (uh-energy e))
                                             (define val (ghost-emp-target-bonus e))
                                             (define is-psi?
                                               (or (unit-attr-has-any? sym SC2-UNIT-ATTR-PSIONIC)
                                                   (not (eq? (memq sym '(high-templar sentry oracle archon infestor infestor-burrowed viper ghost raven queen)) #f))))
                                             (define p?
                                               (and (spell-valid-for-target-attrs? 'emp-round sym een esh)
                                                    is-psi?
                                                    (>= (+ een esh) 40.0)))
                                             (values (+ sh-s esh)
                                                     (+ en-s (if (> een 0.0) een 0.0))
                                                     (+ sc-s val)
                                                     (or has-p? p?)
                                                     (if (and is-psi? (> esh 0.0)) (+ sp-c 1) sp-c))))
                                         (if (and (> score-sum 0.0)
                                                  (if require-heavy-shields?
                                                      (or (>= shield-sum 160.0) (>= sh-psi-cnt 2))
                                                      (or (>= shield-sum 120.0)
                                                          (>= energy-sum 100.0)
                                                          prio?))
                                                  (not (spell-point-claimed? claims 'emp-round cx cy EMP-CLAIM-RADIUS current-frame)))
                                             score-sum
                                             0.0)))])
                          (and ok?
                               (spell-claim-point?! claims 'emp-round ex ey EMP-CLAIM-RADIUS current-frame EMP-CLAIM-TTL)
                               (spell-directive tag 'ghost 'emp-round 'point 0 ex ey 'ghost-emp)))))
                 (define (try-ghost-snipe) : (Option spell-directive)
                   (and (>= en 50.0)
                        (not (any-unit-within? all-enemies ux uy snipe-danger-r sc2-enemy-unit-targetable?))
                        (let-values ([(ok? tgt _w)
                                      (best-unit-target
                                       ux uy 10.0 enemy-units
                                       (lambda ([e : Any])
                                         (and (not (uh-hallucination? e))
                                              (> (ghost-snipe-weight e) 0.0)
                                              (< (spell-unit-claim-count claims 'steady-targeting (uh-tag e) current-frame)
                                                 (unit-claim-effective-cap 'steady-targeting (uh-total-hp e) 0.0 #f #t))))
                                       (lambda ([e : Any])
                                         ;; L58-P3 (`sc2-real-t04`): Focus-fire high-HP multi-Snipe targets
                                         ;; (`> 170 HP`, e.g. Ultralisk/BroodLord) already claimed below cap so
                                         ;; Ultralisk #1 drops before reaching melee, while `<= 170 HP` targets
                                         ;; (`cap = 1`, e.g. Infestor/Viper) still split cleanly via `< cap`!
                                         (define cur-cl (spell-unit-claim-count claims 'steady-targeting (uh-tag e) current-frame))
                                         (if (and (> cur-cl 0) (> (uh-total-hp e) 170.0))
                                             (+ (ghost-snipe-weight e) 12.0)
                                             (- (ghost-snipe-weight e) (* 8.0 (->float cur-cl))))))])
                          (and ok?
                               (spell-claim-unit?!
                                claims 'steady-targeting (uh-tag tgt) current-frame SNIPE-CHANNEL-LOCKOUT-FRAMES
                                #:caster-tag tag #:target-hp (uh-total-hp tgt))
                               (begin
                                 (lock-ghost-snipe-channel! claims tag current-frame SNIPE-CHANNEL-LOCKOUT-FRAMES)
                                 (spell-directive tag 'ghost 'steady-targeting 'unit (uh-tag tgt)
                                                  (uh-x tgt) (uh-y tgt) 'ghost-snipe))))))
                 (or
                  (if heavy-bio-snipe-near?
                      (or (try-ghost-emp #t)
                          (try-ghost-snipe)
                          (try-ghost-emp #f))
                      (or (try-ghost-emp #f)
                          (try-ghost-snipe)))
                  ;; 3. Ghost Cloak (W6-TAC-1 + L46-P0-1b `d12`: requires 'personal-cloaking upgrade,
                  ;;    `energy >= 50`, engaging `<= 11.0t`, no mobile enemy detector `< 11.0t`, and no
                  ;;    static enemy detector `< 11.0t` unless backed by `>= 6` combat allies actively
                  ;;    clearing outer-rim static detectors `>= 8.0t` away!)
                  (and ghost-cloak-ok?
                       (>= en 50.0)
                       (not (uh-cloaked? u))
                       (> (- current-frame (hash-ref (spell-claims-ghost-cloak-frame claims) tag (lambda () -10000))) 20)
                       (any-unit-within? enemy-units ux uy 11.0 sc2-enemy-unit-targetable?)
                       (let* ([mobile-det-near?
                               (any-unit-within?
                                enemy-units ux uy 10.999
                                (lambda ([e : Any])
                                  (and (memq (uh-type e) '(observer observer-siege-mode overseer overseer-siege-mode raven)) #t)))]
                              [static-det-11?
                               (or (any-unit-within?
                                    enemy-units ux uy 10.999
                                    (lambda ([e : Any])
                                      (and (memq (uh-type e) '(missile-turret photon-cannon spore-crawler)) #t)))
                                   (any-unit-within?
                                    enemy-buildings ux uy 10.999
                                    (lambda ([e : Any])
                                      (and (memq (uh-type e) '(missile-turret photon-cannon spore-crawler)) #t))))]
                              [static-det-8?
                               (or (any-unit-within?
                                    enemy-units ux uy 8.0
                                    (lambda ([e : Any])
                                      (and (memq (uh-type e) '(missile-turret photon-cannon spore-crawler)) #t)))
                                   (any-unit-within?
                                    enemy-buildings ux uy 8.0
                                    (lambda ([e : Any])
                                      (and (memq (uh-type e) '(missile-turret photon-cannon spore-crawler)) #t))))]
                              [friendly-squad-clearing?
                               (and static-det-11?
                                    (not static-det-8?)
                                    (>= (count-units-within
                                         ally-units ux uy 12.0
                                         (lambda ([a : Any])
                                           (and (not (= (uh-tag a) tag))
                                                (not (memq (uh-type a) '(scv probe drone mule medivac raven)))
                                                (unit-combat-relevant? a))))
                                        6))])
                         (and (not mobile-det-near?)
                              (or (not static-det-11?)
                                  friendly-squad-clearing?)))
                       (begin
                         (hash-set! (spell-claims-ghost-cloak-frame claims) tag current-frame)
                         (spell-directive tag 'ghost 'cloak-ghost 'none 0 ux uy 'ghost-cloak)))
                  ;; 4. L31-P0-3 (`t04`): Step `2.2t` behind Marines ONLY if melee threat closes `< 1.8t`!
                  (try-ghost-melee-step-back))])]

             ;; --- RAVEN ---
             [(raven)
              ;; L51-2D (`t14`): Prioritize Interference Matrix (3747) on high-value mechanical
              ;; targets (`<= 9.5t` general, `<= 13.5t` for Colossus/SiegedTank/Carrier/Tempest/
              ;; Immortal/Disruptor/etc.) FIRST when `en >= 75`, and never spend energy below `75`
              ;; on a 2nd/3rd Auto-Turret while an unclaimed un-Matrixed HV mech target is `<= 13.5t`!
              (define (raven-hv-mech-matrix-target? [e : Any]) : Boolean
                (and (memq (uh-type e)
                           '(colossus siege-tank-sieged carrier tempest immortal disruptor
                             thor thor-ap battlecruiser mothership))
                     (not (uh-hallucination? e))
                     (not (uh-has-buff? e 'interference-matrix))
                     (= (spell-unit-claim-count claims 'interference-matrix (uh-tag e) current-frame) 0)
                     (> (raven-matrix-weight e) 0.0)))
              (define hv-matrix-tgt-near?
                (and interference-matrix-ok?
                     (any-unit-within? enemy-units ux uy 13.5 raven-hv-mech-matrix-target?)))
              (or
               ;; 1. Interference Matrix (`energy >= 75`, `<= 9.5t` general / `<= 13.5t` HV mech, 1/target;
               ;;    strictly gated on `interference-matrix-ok?` per SC2 5.0.14 StarportTechLab `807`!)
               (and interference-matrix-ok?
                    (>= en 75.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 13.5 enemy-units
                                   (lambda ([e : Any])
                                     (and (not (uh-hallucination? e))
                                          (not (uh-has-buff? e 'interference-matrix))
                                          (= (spell-unit-claim-count claims 'interference-matrix (uh-tag e) current-frame) 0)
                                          (> (raven-matrix-weight e) 0.0)
                                          (or (<= (dist2 ux uy (uh-x e) (uh-y e)) 9.5)
                                              (raven-hv-mech-matrix-target? e))))
                                   (lambda ([e : Any]) (raven-matrix-weight e)))])
                      (and ok?
                           (spell-claim-unit?! claims 'interference-matrix (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                               #:caster-tag tag)
                           (spell-directive tag 'raven 'interference-matrix 'unit (uh-tag tgt)
                                            (uh-x tgt) (uh-y tgt) 'raven-interference-matrix))))
               ;; 2. Anti-Armor Missile (`energy >= 75`, targets 'armored/'massive or >= 4 clumps w/ multi-hit attackers in range)
               (and (>= en 75.0)
                    (let ([ally-idx (get-spell-xy-index ally-units)]
                          [enemy-idx (get-spell-xy-index enemy-units)]
                          [cached-aam-score : Float 0.0])
                      (: count-ally-pair (-> Float Float Float (Values Integer Integer)))
                      (define (count-ally-pair cx cy rad)
                        (define r2 (* rad rad))
                        (if ally-idx
                            (let ([xs (spell-xy-index-xs ally-idx)]
                                  [ys (spell-xy-index-ys ally-idx)]
                                  [us (spell-xy-index-us ally-idx)]
                                  [n (spell-xy-index-n ally-idx)])
                              (for/fold ([mc : Integer 0] [cc : Integer 0])
                                        ([i (in-range n)])
                                (define dx (- cx (flvector-ref xs i)))
                                (if (<= (flabs dx) rad)
                                    (let ([dy (- cy (flvector-ref ys i))])
                                      (if (and (<= (flabs dy) rad) (<= (+ (* dx dx) (* dy dy)) r2))
                                          (let ([a (vector-ref us i)])
                                            (values (+ mc (if (multi-hit-ally-attacker? a) 1 0))
                                                    (+ cc (if (unit-combat-relevant? a) 1 0))))
                                          (values mc cc)))
                                    (values mc cc))))
                            (values (count-units-within ally-units cx cy rad multi-hit-ally-attacker?)
                                    (count-units-within ally-units cx cy rad unit-combat-relevant?))))
                      (: count-enemy-aam-pair (-> Float Float Float (Values Integer Integer)))
                      (define (count-enemy-aam-pair cx cy rad)
                        (define r2 (* rad rad))
                        (if enemy-idx
                            (let ([xs (spell-xy-index-xs enemy-idx)]
                                  [ys (spell-xy-index-ys enemy-idx)]
                                  [us (spell-xy-index-us enemy-idx)]
                                  [n (spell-xy-index-n enemy-idx)])
                              (for/fold ([tc : Integer 0] [hc : Integer 0])
                                        ([i (in-range n)])
                                (define dx (- cx (flvector-ref xs i)))
                                (if (<= (flabs dx) rad)
                                    (let ([dy (- cy (flvector-ref ys i))])
                                      (if (and (<= (flabs dy) rad) (<= (+ (* dx dx) (* dy dy)) r2))
                                          (let ([x (vector-ref us i)])
                                            (if (sc2-enemy-unit-targetable? x)
                                                (values (+ tc 1)
                                                        (+ hc (if (unit-attr-has-any?
                                                                   (uh-type x)
                                                                   (fxior SC2-UNIT-ATTR-ARMORED SC2-UNIT-ATTR-MASSIVE))
                                                                  1 0)))
                                                (values tc hc)))
                                          (values tc hc)))
                                    (values tc hc))))
                            (values (count-units-within enemy-units cx cy rad sc2-enemy-unit-targetable?)
                                    (count-units-within
                                     enemy-units cx cy rad
                                     (lambda ([x : Any])
                                       (and (sc2-enemy-unit-targetable? x)
                                            (unit-attr-has-any? (uh-type x)
                                                                (fxior SC2-UNIT-ATTR-ARMORED SC2-UNIT-ATTR-MASSIVE))))))))
                      (define-values (near-mc near-cc) (count-ally-pair ux uy 21.0))
                      (and (or (>= near-mc 2) (>= near-cc 4))
                           (let-values ([(ok? tgt _w)
                                         (best-unit-target
                                          ux uy 10.0 enemy-units
                                          (lambda ([e : Any])
                                            (define ex (uh-x e))
                                            (define ey (uh-y e))
                                            (define esym (uh-type e))
                                            (cond
                                              [(or (not (sc2-enemy-unit-targetable? e))
                                                   (uh-has-buff? e 'anti-armor-missile)
                                                   (spell-point-claimed? claims 'anti-armor-missile ex ey ANTI-ARMOR-CLAIM-RADIUS current-frame))
                                               #f]
                                              [else
                                               (define-values (multi-cnt combat-cnt) (count-ally-pair ex ey 11.0))
                                               (and (or (>= multi-cnt 2) (>= combat-cnt 4))
                                                    (let-values ([(clump-cnt heavy-cnt) (count-enemy-aam-pair ex ey 2.88)])
                                                      (define valid?
                                                        (or (>= clump-cnt 4)
                                                            (and (unit-attr-has-any? esym (fxior SC2-UNIT-ATTR-ARMORED SC2-UNIT-ATTR-MASSIVE))
                                                                 (or (>= heavy-cnt 2)
                                                                     (unit-attr-has-any? esym SC2-UNIT-ATTR-MASSIVE))
                                                                 (>= (+ multi-cnt combat-cnt) 4))))
                                                      (when valid?
                                                        (define pack (aoe-radius-packing-multiplier (unit-collision-radius esym) 2.88))
                                                        (set! cached-aam-score
                                                              (+ (* 18.0 pack (->float clump-cnt))
                                                                 (if (unit-attr-has-any? esym SC2-UNIT-ATTR-MASSIVE) 30.0 0.0)
                                                                 (if (unit-attr-has-any? esym SC2-UNIT-ATTR-ARMORED) 18.0 0.0)
                                                                 (* 5.0 (->float multi-cnt)))))
                                                      valid?))]))
                                          (lambda ([_e : Any]) cached-aam-score))])
                             (and ok?
                                  (spell-claim-unit?! claims 'anti-armor-missile (uh-tag tgt) current-frame ANTI-ARMOR-CLAIM-TTL
                                                      #:caster-tag tag)
                                  (spell-claim-point?! claims 'anti-armor-missile (uh-x tgt) (uh-y tgt)
                                                       ANTI-ARMOR-CLAIM-RADIUS current-frame ANTI-ARMOR-CLAIM-TTL)
                                  (spell-directive tag 'raven 'anti-armor-missile 'unit (uh-tag tgt)
                                                   (uh-x tgt) (uh-y tgt) 'raven-anti-armor-missile))))))
               ;; 3. Auto-Turret (`energy >= 50`, harass workers / melee / engaged zone;
               ;;    L54-2E: allow 50..64e Ravens to drop Auto-Turret; hold energy for Matrix only
               ;;    when `65 <= en < 125` and an unclaimed un-Matrixed HV mech target is <= 13.5t!)
               (and (>= en 50.0)
                    (or (not hv-matrix-tgt-near?)
                        (< en 65.0)
                        (>= en 125.0))
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
                                  [cast-d (min 2.0 (max 0.5 (- d 0.75)))]
                                  [tx (clamp-coord (+ ux (* cast-d (/ dx d))))]
                                  [ty (clamp-coord (+ uy (* cast-d (/ dy d))))])
                             (and (spell-claim-point?! claims 'auto-turret tx ty 2.5 current-frame 64)
                                  (spell-directive tag 'raven 'auto-turret 'point 0 tx ty 'raven-auto-turret)))))))]

             ;; --- BATTLECRUISER ---
             [(battlecruiser)
              (define yam-issue-ht (spell-claims-bc-yamato-issue-frame claims))
              (define yam-ready-ht (spell-claims-bc-yamato-ready-frame claims))
              (define yam-channelling? (dyn-u-has-order-ability? u 401))
              (define yam-obs-cd (safe-int (dyn-hash-ref u 'yamato-cooldown 0) 0))
              (when (or yam-channelling? (> yam-obs-cd 0))
                (define f0 (hash-ref yam-issue-ht tag (lambda () current-frame)))
                (hash-set! yam-ready-ht tag (max (hash-ref yam-ready-ht tag (lambda () -1))
                                                 (+ f0 BC-YAMATO-COOLDOWN-FRAMES)))
                (when (> yam-obs-cd 0)
                  (hash-remove! yam-issue-ht tag)))
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (define jump-unlock (hash-ref (spell-claims-bc-jump-ready-frame claims) tag (lambda () -1)))
                 (define yam-unlock (hash-ref yam-ready-ht tag (lambda () -1)))
                 (define jump-ready?
                   (and (not (eq? (dyn-hash-ref u 'tactical-jump-ready? #t) #f))
                        (<= (safe-int (dyn-hash-ref u 'tactical-jump-cooldown 0) 0) 0)
                        (>= current-frame jump-unlock)))
                 (define yam-ready?
                   (and yamato-ok?
                        (not (eq? (dyn-hash-ref u 'yamato-ready? #t) #f))
                        (<= yam-obs-cd 0)
                        (>= current-frame yam-unlock)))
                 (or
                  ;; 1. Emergency Tactical Jump home when HP ratio < 0.32
                  (and jump-ready?
                       (< (uh-hp-ratio u) 0.32)
                       (> (dist2 ux uy home-x home-y) 12.0)
                       (begin
                         (hash-set! (spell-claims-bc-jump-ready-frame claims)
                                    tag
                                    (+ current-frame BC-TACTICAL-JUMP-COOLDOWN-FRAMES))
                         (spell-directive tag 'battlecruiser 'tactical-jump 'point 0 home-x home-y
                                          'bc-emergency-tactical-jump)))
                  ;; 2. L40-P0-1d (`t15`) + L58-P1 (`y06`): Single-emitter Yamato Cannon (`401`, `ceil(hp/240)`
                  ;;    claim cap, strictly `<= 10.0t` cast range over `all-enemies` incl. Spores/Turrets/PF/Queens!)
                  (and yam-ready?
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 all-enemies
                                      (lambda ([e : Any])
                                        (and (not (uh-hallucination? e))
                                             (< (spell-unit-claim-count claims 'yamato-cannon (uh-tag e) current-frame)
                                                (unit-claim-effective-cap 'yamato-cannon (uh-total-hp e) 0.0 #f #t))
                                             (> (bc-yamato-weight e) 0.0)))
                                      (lambda ([e : Any])
                                        (define cc (spell-unit-claim-count claims 'yamato-cannon (uh-tag e) current-frame))
                                        (- (bc-yamato-weight e) (* 15.0 (->float cc)))))])
                         (and ok?
                              (spell-claim-unit?! claims 'yamato-cannon (uh-tag tgt) current-frame 52
                                                  #:caster-tag tag #:target-hp (uh-total-hp tgt))
                              (begin
                                (hash-set! yam-issue-ht tag current-frame)
                                (hash-set! yam-ready-ht tag (+ current-frame 52))
                                (spell-directive tag 'battlecruiser 'yamato-cannon 'unit (uh-tag tgt)
                                                 (uh-x tgt) (uh-y tgt) 'bc-yamato-snipe)))))
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
                              (begin
                                (hash-set! (spell-claims-bc-jump-ready-frame claims)
                                           tag
                                           (+ current-frame BC-TACTICAL-JUMP-COOLDOWN-FRAMES))
                                (spell-directive tag 'battlecruiser 'tactical-jump 'point 0 jx jy
                                                 'bc-tactical-jump-backstab))))))])]

             ;; --- MEDIVAC (Boost 2116 / Heal 386 / Low-HP Retreat) ---
             [(medivac)
              (define boost-unlock (hash-ref (spell-claims-medivac-boost-ready-frame claims) tag (lambda () -1)))
              (define boost-ready?
                (and (not (eq? (dyn-hash-ref u 'boost-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'boost-cooldown 0) 0) 0)
                     (not (uh-has-buff? u 'medivac-speed-boost))
                     (>= current-frame boost-unlock)))
              (define cargo-cnt (safe-int (dyn-hash-ref u 'cargo-count 0) 0))
              (define hp-rat (uh-hp-ratio u))
              (define danger-near? (any-unit-within? all-enemies ux uy 9.5 enemy-anti-air-or-air-threat?))
              (or
               (and boost-ready?
                    (or (> cargo-cnt 0)
                        (and (< hp-rat 0.45) danger-near?))
                    (begin
                      (hash-set! (spell-claims-medivac-boost-ready-frame claims)
                                 tag
                                 (+ current-frame MEDIVAC-BOOST-COOLDOWN-FRAMES))
                      (spell-directive tag 'medivac 'medivac-boost 'none 0 ux uy
                                       (if (> cargo-cnt 0) 'medivac-boost-loaded-drop 'medivac-boost-rescue-evac))))
               (and (< hp-rat 0.45)
                    (= cargo-cnt 0)
                    danger-near?
                    (let-values ([(rx ry) (safe-retreat-point ux uy all-enemies home-x home-y 9.0)])
                      (spell-directive tag 'medivac 'move 'kite 0 rx ry 'medivac-retreat-low-hp-empty)))
               ;; W5-TAC-4: SC2 permits strictly 1 Medivac heal beam per target (`#:max-casters 1`)
               (let-values ([(ok? tgt _w)
                             (best-unit-target
                              ux uy 5.5 ally-units
                              (lambda ([a : Any])
                                (and (not (= (uh-tag a) tag))
                                     (not (uh-hallucination? a))
                                     (spell-valid-for-target-attrs? 'heal (uh-type a))
                                     (memq (uh-type a) '(marine marauder reaper ghost hellbat scv))
                                     (< (uh-hp-ratio a) 0.92)
                                     (= (spell-unit-claim-count claims 'heal (uh-tag a) current-frame) 0)))
                              (lambda ([a : Any])
                                (+ (* 100.0 (- 1.0 (uh-hp-ratio a)))
                                   (case (uh-type a) [(ghost) 25.0] [(marauder) 15.0] [(marine) 12.0] [else 5.0]))))])
                 (and ok?
                      (let ([ttag (uh-tag tgt)])
                        (and (spell-claim-unit?! claims 'heal ttag current-frame 16 #:caster-tag tag #:max-casters 1)
                             (spell-directive tag 'medivac 'heal 'unit ttag
                                              (uh-x tgt) (uh-y tgt) 'medivac-heal-injured-bio))))))]

             ;; --- CYCLONE (Lock-On 2350) ---
             [(cyclone)
              (define lock-unlock (hash-ref (spell-claims-cyclone-lock-on-ready-frame claims) tag (lambda () -1)))
              (define lock-ready?
                (and (not (spellcaster-channel-protected? u))
                     (not (eq? (dyn-hash-ref u 'lock-on-ready? #t) #f))
                     (<= (safe-int (dyn-hash-ref u 'lock-on-cooldown 0) 0) 0)
                     (>= current-frame lock-unlock)))
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
                                 (begin
                                   (hash-set! (spell-claims-cyclone-lock-on-ready-frame claims)
                                              tag
                                              (+ current-frame CYCLONE-LOCK-ON-COOLDOWN-FRAMES))
                                   (spell-directive tag 'cyclone 'lock-on 'unit ttag
                                                    (uh-x tgt) (uh-y tgt) 'cyclone-lock-on-high-value)))))))]

             ;; --- SCV (Repair 3685: strictly 'mechanical units/structures) ---
             [(scv)
              (define busy-or-carrying?
                (or (eq? (dyn-hash-ref u 'constructing? #f) #t)
                    (eq? (dyn-hash-ref u 'repairing? #f) #t)
                    (> (safe-int (dyn-hash-ref u 'cargo-count 0) 0) 0)
                    (eq? (dyn-hash-ref u 'carrying? #f) #t)))
              (and (not busy-or-carrying?)
                   (let ([repair-pool (or precomputed-repair-targets
                                          (if (null? ally-buildings)
                                              ally-units
                                              (append ally-units ally-buildings)))])
                     (and (pair? repair-pool)
                          (let-values ([(ok? tgt _w)
                                        (best-unit-target
                                         ux uy 14.0 repair-pool
                                         (lambda ([a : Any])
                                           (define asym (uh-type a))
                                           (define ax (uh-x a))
                                           (define ay (uh-y a))
                                           (define max-rep-casters
                                             (case asym
                                               [(planetary-fortress) 6]
                                               [(bunker) 4]
                                               [(thor thor-ap battlecruiser siege-tank-sieged) 3]
                                               [else 2]))
                                           (define max-rep-r
                                             (if (memq asym '(planetary-fortress bunker missile-turret)) 14.0 10.0))
                                           ;; L39-P0-1a / 1f + L41-P0-1b + L48-W2 (`#5140013` / `r05` / `r15` / `e03`):
                                           ;; - Never pull SCVs to repair another SCV under active enemy combat harass (`<= 6.5t`,
                                           ;;   e.g. Adepts/Lings) or enemy worker rush (`>= 6` workers, OR `>= 3` pure workers w/ 0
                                           ;;   enemy combat units).
                                           ;; - Under a `>= 6`-worker pure worker rush (0 enemy combat units within `24t`, e.g. `r15`),
                                           ;;   ALSO suppress SCV `3685` repair of non-fortification buildings (CC/Barracks/Depot/etc.)
                                           ;;   so SCVs fight/mine instead of burning 38-47 ticks on repair — while strictly preserving
                                           ;;   combat Mech/Siege Tank/Bunker/Planetary Fortress/Missile Turret repair (`L39-T1b`)!
                                           (define near-ew-cnt-24
                                             (count-units-within
                                              enemy-units ax ay 24.0
                                              (lambda ([e : Any])
                                                (and (memq (uh-type e) '(scv probe drone)) #t))))
                                           (define any-enemy-combat-24?
                                             (any-unit-within?
                                              enemy-units ax ay 24.0
                                              (lambda ([e : Any])
                                                (and (sc2-enemy-unit-targetable? e)
                                                     (not (memq (uh-type e) '(scv probe drone)))
                                                     (unit-combat-relevant? e)))))
                                           (define pure-worker-rush-noncombat-bldg-repair?
                                             (and (>= near-ew-cnt-24 6)
                                                  (not any-enemy-combat-24?)
                                                  (memq asym '(scv command-center orbital-command
                                                               barracks supply-depot supply-depot-lowered
                                                               refinery engineering-bay factory starport
                                                               armory ghost-academy fusion-core
                                                               tech-lab reactor
                                                               barracks-techlab barracks-reactor
                                                               factory-techlab factory-reactor
                                                               starport-techlab starport-reactor))))
                                           (define unsafe-scv-on-scv?
                                             (or pure-worker-rush-noncombat-bldg-repair?
                                                 (and (eq? asym 'scv)
                                                      (let ([near-combat?
                                                             (any-unit-within?
                                                              enemy-units ax ay 6.5
                                                              (lambda ([e : Any])
                                                                (and (sc2-enemy-unit-targetable? e)
                                                                     (not (memq (uh-type e) '(scv probe drone)))
                                                                     (unit-combat-relevant? e))))]
                                                            [near-ew-cnt
                                                             (count-units-within
                                                              enemy-units ax ay 14.0
                                                              (lambda ([e : Any])
                                                                (and (memq (uh-type e) '(scv probe drone)) #t)))]
                                                            [any-enemy-combat-14?
                                                             (any-unit-within?
                                                              enemy-units ax ay 14.0
                                                              (lambda ([e : Any])
                                                                (and (sc2-enemy-unit-targetable? e)
                                                                     (not (memq (uh-type e) '(scv probe drone)))
                                                                     (unit-combat-relevant? e))))])
                                                        (or near-combat?
                                                            (>= near-ew-cnt 6)
                                                            (and (>= near-ew-cnt 3)
                                                                 (not any-enemy-combat-14?)))))))
                                           (and (not (= (uh-tag a) tag))
                                                (<= (dist2 ux uy ax ay) max-rep-r)
                                                (not unsafe-scv-on-scv?)
                                                (ally-repair-target-valid? a)
                                                (< (spell-unit-claim-count claims 'repair (uh-tag a) current-frame) max-rep-casters)))
                                         (lambda ([a : Any])
                                           (+ (scv-repair-priority (uh-type a))
                                              (* 35.0 (- 1.0 (uh-hp-ratio a)))
                                              (- (* 1.5 (dist2 ux uy (uh-x a) (uh-y a)))))))])
                            (and ok?
                                 (let* ([ttag (uh-tag tgt)]
                                        [tsym (uh-type tgt)]
                                        [mcap (case tsym
                                                [(planetary-fortress) 6]
                                                [(bunker) 4]
                                                [(thor thor-ap battlecruiser siege-tank-sieged) 3]
                                                [else 2])])
                                   (and (spell-claim-unit?! claims 'repair ttag current-frame 16 #:caster-tag tag #:max-casters mcap)
                                   (spell-directive tag 'scv 'repair 'unit ttag
                                                    (uh-x tgt) (uh-y tgt) 'scv-repair-mechanical))))))))]

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
         #:ghost-cloak-researched? Boolean
         #:interference-matrix-researched? Boolean
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
         #:ghost-cloak-researched? [ghost-cloak-researched? #t]
         #:interference-matrix-researched? [interference-matrix-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:exclude-tags [exclude-tags '()])
  (define-values (casters scvs dmg-units)
    (for/fold ([acc : (Listof Any) '()]
               [scv-acc : (Listof Any) '()]
               [dmgs : (Listof Any) '()]
               #:result (values (reverse acc) (reverse scv-acc) (reverse dmgs)))
              ([u (in-list ally-units)]
               #:when (hash? u))
      (define sym (uh-type u))
      (define next-dmgs (if (ally-repair-target-valid? u) (cons u dmgs) dmgs))
      (cond
        [(eq? sym 'scv)
         (let ([t (uh-tag u)])
           (if (and (> t 0) (not (memv t exclude-tags)))
               (values acc (cons u scv-acc) next-dmgs)
               (values acc scv-acc next-dmgs)))]
        [(memq sym TERRAN-CASTER-SYMS)
         (let ([t (uh-tag u)])
           (if (and (> t 0) (not (memv t exclude-tags)))
               (values (cons u acc) scv-acc next-dmgs)
               (values acc scv-acc next-dmgs)))]
        [else (values acc scv-acc next-dmgs)])))
  (define repair-targets
    (if (null? scvs)
        '()
        (for/fold ([acc : (Listof Any) dmg-units]
                   #:result acc)
                  ([b (in-list ally-buildings)]
                   #:when (hash? b))
          (if (ally-repair-target-valid? b) (cons b acc) acc))))
  (define effective-casters
    (if (and (pair? scvs) (pair? repair-targets))
        (if (null? casters) scvs (append casters scvs))
        casters))
  (if (null? effective-casters)
      '()
      (run-terran-spellcaster-micro
       effective-casters ally-units enemy-units claims current-frame
       ally-buildings enemy-buildings effects researched-upgrades
       yamato-researched? home-x home-y exclude-tags repair-targets
       ghost-cloak-researched? interference-matrix-researched?)))

;; -----------------------------------------------------------------------------
;; 8. Protoss Spellcaster Patterns (Sentry, High Templar, Oracle)
;; -----------------------------------------------------------------------------

(: ht-feedback-priority (-> Any Float))
(define (ht-feedback-priority e)
  ;; Feedback strictly requires non-structure target with energy >= 50
  (define sym (uh-type e))
  (define en (uh-energy e))
  (if (not (spell-valid-for-target-attrs? 'feedback sym en))
      0.0
      (let ([base (case sym
                    [(infestor infestor-burrowed) 200.0]
                    [(viper) 185.0]
                    [(ghost) 165.0]
                    [(medivac) 145.0]
                    [(high-templar) 130.0]
                    [(raven) 120.0]
                    [(oracle) 110.0]
                    [(queen queen-burrowed) 95.0]
                    [(sentry banshee battlecruiser mothership) 80.0]
                    [else 50.0])])
        (+ base (* 0.35 en)))))

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

(: oracle-pulsar-non-aa-victim? (-> Any Boolean))
(define (oracle-pulsar-non-aa-victim? e)
  (and (oracle-pulsar-victim? e)
       (not (enemy-anti-air-or-air-threat? e))))

(: ht-dry-for-archon? (-> Any Boolean))
(define (ht-dry-for-archon? u)
  (and (hash? u)
       (eq? (uh-type u) 'high-templar)
       (> (uh-tag u) 0)
       (not (uh-hallucination? u))
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
        [(or (<= tag 0) (memv tag used) (uh-hallucination? u))
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
               ;; 3. Hallucination Archon (tank soak vs siege/armored/combat `<= 16.0t`) / Phoenix scout (`> 18.0t` safe)
               (and (>= en 75.0)
                    (let* ([scout-window? (and (>= current-frame 4480) (<= current-frame 7000))]
                           [no-recent-phoenix?
                            (> (- current-frame (spell-claims-last-hallucination-phoenix-frame claims)) 900)]
                           [enemy-combat-16?
                            (any-unit-within? enemy-units ux uy 16.0
                                              (lambda ([e : Any])
                                                (and (sc2-enemy-unit-targetable? e)
                                                     (unit-combat-relevant? e))))]
                           [enemy-combat-18?
                            (or enemy-combat-16?
                                (any-unit-within? all-enemies ux uy 18.0 sc2-enemy-unit-targetable?))]
                           [heavy-siege-armored-16?
                            (any-unit-within?
                             enemy-units ux uy 16.0
                             (lambda ([e : Any])
                               (and (memq (uh-type e) '(siege-tank siege-tank-sieged immortal thor thor-ap
                                                        marauder colossus lurker-burrowed lurker-mp-burrowed
                                                        disruptor widow-mine widow-mine-burrowed))
                                    #t)))])
                      (cond
                        [(and enemy-combat-16?
                              (or (and heavy-siege-armored-16? (>= en 75.0))
                                  (>= en 125.0))
                              (spell-claim-unit?! claims 'hallucination-archon tag current-frame 24 #:caster-tag tag))
                         (spell-directive tag 'sentry 'hallucination-archon 'none 0 ux uy 'sentry-hallucination-archon-tank)]
                        [(and scout-window?
                              no-recent-phoenix?
                              (not enemy-combat-18?))
                         (set-spell-claims-last-hallucination-phoenix-frame! claims current-frame)
                         (spell-directive tag 'sentry 'hallucination-phoenix 'none 0 ux uy 'sentry-hallucination-phoenix-scout)]
                        [(and (<= current-frame 7200)
                              no-recent-phoenix?
                              (not enemy-combat-18?))
                         (set-spell-claims-last-hallucination-phoenix-frame! claims current-frame)
                         (spell-directive tag 'sentry 'hallucination-phoenix 'none 0 ux uy 'sentry-hallucination-phoenix-scout)]
                        [(and enemy-combat-16?
                              heavy-siege-armored-16?
                              (spell-claim-unit?! claims 'hallucination-zealot tag current-frame 24 #:caster-tag tag))
                         (spell-directive tag 'sentry 'hallucination-zealot 'none 0 ux uy 'sentry-hallucination-bait-fire)]
                        [else #f]))))]

             ;; --- HIGH TEMPLAR (Primary spells: Storm & Feedback) ---
             [(high-templar)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. Psi Storm (`energy >= 75`, `r=2.0 ttl=56f`, `<= 1` ally within `1.5`, packing-weighted)
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
                                            (sum-units-fl
                                             cl
                                             (lambda ([e : Any])
                                               (define pack
                                                 (aoe-radius-packing-multiplier
                                                  (unit-collision-radius (uh-type e)) 1.5))
                                               (+ (* 35.0 pack)
                                                  (* 0.08 (protoss-cached-hp e)))))
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'psi-storm sx sy PSI-STORM-CLAIM-RADIUS current-frame PSI-STORM-CLAIM-TTL)
                              (begin
                                (hash-set! (spell-claims-ht-storm-frame claims) tag current-frame)
                                (spell-directive tag 'high-templar 'psi-storm 'point 0 sx sy 'ht-psi-storm)))))
                  ;; 2. Feedback (`Infestor -> Viper -> Ghost -> Medivac -> HT -> Raven -> Oracle`, 1/target)
                  ;; L58-P3 (`sc2-ab-p03`): Scan up to `13.0t` so HTs step 1..3t forward to Feedback
                  ;; backline Vipers/Infestors behind front Roaches instead of rear-leashing away!
                  (and (>= en 50.0)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 13.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (> (ht-feedback-priority e) 0.0)
                                             (= (spell-unit-claim-count claims 'feedback (uh-tag e) current-frame) 0)))
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
                ;; L45-P0-1b + L46-P0-1a (`ro09`): When raiding a mineral line (`>= 4` enemy workers
                ;; within `<= 14.0t` or `>= 4` light pulsar victims within `<= 9.5t`), hold Pulsar Beam
                ;; ON down to `sh < 10.0` (and `en < 10.0`) so Oracles finish crossing front Marines and
                ;; shredding SCVs/Drones/Probes instead of toggling OFF at `sh = 24`!
                [beam-on?
                 (define near-raid-workers
                   (count-units-within enemy-units ux uy 14.0
                                       (lambda ([e : Any])
                                         (and (memq (uh-type e) '(scv probe drone mule)) #t))))
                 (define near-light-victims
                   (count-units-within enemy-units ux uy 9.5 oracle-pulsar-victim?))
                 (define beam-enemy-th-near-22?
                   (any-unit-within?
                    enemy-buildings ux uy 22.0
                    (lambda ([b : Any])
                      (and (memq (uh-type b) SC2-TOWNHALL-STRUCTURE-SYMS) #t))))
                 (define worker-raid-hold?
                   (or (>= near-raid-workers 4)
                       (>= near-light-victims 4)
                       beam-enemy-th-near-22?))
                 (define min-sh-off (if worker-raid-hold? 10.0 25.0))
                 (define min-en-off (if worker-raid-hold? 10.0 15.0))
                 (and (>= dwell ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES)
                      (or (< en min-en-off)
                          (< sh min-sh-off)
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
                     ;; Branch (b): Pulsar Beam ON (`energy >= 40`, `shields >= 35`, `>= 2` light/workers in `7.5t`,
                     ;; or `>= 4` workers in `9.0t` with `energy >= 35` & `shields >= 25`, or full mineral line
                     ;; `>= 8` workers in `10.0t` / active AA-contested worker raid down to `shields >= 15`)
                     ;; L44-P0-1b + L45-P0-1b + L46-P0-1a (`ro09`): Pop Pulsar Beam (`2375`) cleanly on approach
                     ;; instead of stopping to drop Stasis Ward (while uncontested low-shield `sh=20` near 5-6
                     ;; workers preserves `L43-T3d`!).
                     (and (let* ([ew-10 (count-units-within enemy-units ux uy 10.0
                                                            (lambda ([e : Any])
                                                              (and (memq (uh-type e) '(scv probe drone mule)) #t)))]
                                 [ew-9 (count-units-within enemy-units ux uy 9.0
                                                           (lambda ([e : Any])
                                                             (and (memq (uh-type e) '(scv probe drone mule)) #t)))]
                                 [aa-near? (any-unit-within? all-enemies ux uy 10.5 enemy-anti-air-or-air-threat?)])
                            (or (and (>= en 40.0)
                                     (>= sh 35.0)
                                     (>= (count-units-within enemy-units ux uy 7.5 oracle-pulsar-victim?) 2))
                                (and (>= en 35.0)
                                     (>= sh 25.0)
                                     (>= ew-9 4))
                                (and (>= en 35.0)
                                     (>= sh 15.0)
                                     (or (>= ew-10 8)
                                         (and (>= ew-9 4) aa-near?)))))
                          (begin
                            (hash-set! (spell-claims-oracle-beam-start claims) tag current-frame)
                            (spell-directive tag 'oracle 'pulsar-beam-on 'none 0 ux uy
                                             'oracle-pulsar-beam-on)))
                     ;; Branch (c): Stasis Ward (`beam OFF` & `energy >= 50` at enemy mineral line
                     ;; or `>= 55` at choke/approach).
                     ;; L44-P0-1b + L45-P0-1b + L46-P0-1a + L47-P0-1a (`ro09` Dummy & SP `2505` suppress):
                     ;; Remove the `(< en 90.0)` ceiling on Stasis Ward suppression during a worker raid
                     ;; (`>= 4` enemy workers `<= 14t` with `>= 8` workers OR active AA `<= 10.5t` OR `sh >= 25.0`)
                     ;; because Oracles starting/recharging to `en >= 90` bypassed `(< en 90.0)` and burned `2505`
                     ;; in open space instead of activating Pulsar Beam on 16 SCVs! Uncontested low-shield `sh=20`
                     ;; near `5-6` workers (`L43-T3d`/`L44-T2b`/`L45-T2b`/`L46-T1b`) STILL plants Stasis Ward!
                     (and (>= en 50.0)
                          (let* ([ew-14 (count-units-within enemy-units ux uy 14.0
                                                            (lambda ([e : Any])
                                                              (and (memq (uh-type e) '(scv probe drone mule)) #t)))]
                                 [aa-near-10? (any-unit-within? all-enemies ux uy 10.5 enemy-anti-air-or-air-threat?)]
                                 [aa-in-lethal-range? (any-unit-within? all-enemies ux uy 6.5 enemy-anti-air-or-air-threat?)]
                                 [enemy-th-near-22?
                                  (any-unit-within?
                                   enemy-buildings ux uy 22.0
                                   (lambda ([b : Any])
                                     (and (memq (uh-type b) SC2-TOWNHALL-STRUCTURE-SYMS) #t)))]
                                 ;; L49-W1 + L59-P2 (`nc-14`): Suppress Stasis Ward whenever a healthy Oracle (`sh >= 25`)
                                 ;; is actively raiding an enemy base / mineral line (`<= 22t` of enemy
                                 ;; TownHall or `>= 2` non-AA light/worker victims `<= 14t`), regardless of `en >= 90`,
                                 ;; so energy stays reserved for Pulsar Beam worker shred! NEVER suppress defensive
                                 ;; ramp Stasis Ward because anti-air Marines/Hydras patrol `7..14t` away!
                                 [save-for-pulsar-raid?
                                  (or (and (>= sh 25.0)
                                           (or enemy-th-near-22?
                                               (>= (count-units-within enemy-units ux uy 14.0 oracle-pulsar-non-aa-victim?) 2)))
                                      (and (>= ew-14 4)
                                           (or (>= ew-14 8)
                                               aa-near-10?
                                               (>= sh 25.0))))]
                                 [safe-site?
                                  (lambda ([wx : Float] [wy : Float])
                                    (and (<= (dist2 ux uy wx wy) 8.0)
                                         (not (any-unit-within? all-enemies wx wy 4.5 sc2-enemy-unit-targetable?))
                                         (not (any-unit-within?
                                               all-allies wx wy 4.5
                                               (lambda ([a : Any]) (and (memq (uh-type a) '(oracle-stasis-trap stasis-ward)) #t))))
                                         (not (spell-point-claimed? claims 'stasis-ward wx wy STASIS-WARD-CLAIM-RADIUS current-frame))))]
                                 ;; L43-P0-1c + L44-P0-1b: Plant Stasis Ward at enemy mineral-line worker cluster
                                 ;; ONLY when not saving energy for a healthy Pulsar Beam worker shred!
                                 [mineral-trap-pt : (Option (Pairof Float Float))
                                  (if save-for-pulsar-raid?
                                      #f
                                      (let* ([near-ew
                                              (for/list : (Listof Any) ([e (in-list enemy-units)]
                                                                        #:when (and (memq (uh-type e) '(scv probe drone mule))
                                                                                    (<= (dist2 ux uy (uh-x e) (uh-y e)) 11.0)))
                                                e)]
                                             [n-ew (length near-ew)])
                                        (if (>= n-ew 3)
                                            (let* ([wcx (/ (for/fold ([s : Float 0.0]) ([e (in-list near-ew)]) (+ s (uh-x e)))
                                                           (exact->inexact n-ew))]
                                                   [wcy (/ (for/fold ([s : Float 0.0]) ([e (in-list near-ew)]) (+ s (uh-y e)))
                                                           (exact->inexact n-ew))]
                                                   ;; L58-P2 (`sc2-sta-s01`): Offset Stasis Ward `2.2t` clear of the
                                                   ;; occupied mineral/worker core (rotating across 4 offsets on retries)
                                                   ;; so SC2 doesn't reject `2505` with `41:CantFindPlacementLocation`!
                                                   [rot (modulo (quotient (max 0 current-frame) 16) 4)]
                                                   [ox (case rot [(0) 2.2] [(1) -2.2] [(2) 0.0] [else 0.0])]
                                                   [oy (case rot [(0) 0.0] [(1) 0.0] [(2) 2.2] [else -2.2])]
                                                   [bx (clamp-coord (+ wcx ox))]
                                                   [by (clamp-coord (+ wcy oy))]
                                                   [d-wc (dist2 ux uy bx by)]
                                                   [tx (if (<= d-wc 8.0) bx (clamp-coord (+ ux (* 7.2 (/ (- bx ux) (max 0.01 d-wc))))))]
                                                   [ty (if (<= d-wc 8.0) by (clamp-coord (+ uy (* 7.2 (/ (- by uy) (max 0.01 d-wc))))))])
                                              (and (= (spell-unit-claim-count claims 'oracle-stasis-cd tag current-frame) 0)
                                                   (not (any-unit-within?
                                                         all-allies tx ty 4.5
                                                         (lambda ([a : Any]) (and (memq (uh-type a) '(oracle-stasis-trap stasis-ward)) #t))))
                                                   (not (spell-point-claimed? claims 'stasis-ward tx ty STASIS-WARD-CLAIM-RADIUS current-frame))
                                                   (cons tx ty)))
                                            #f)))]
                                 [under-fire-low-sh?
                                  (and (< sh 35.0)
                                       (any-unit-within? all-enemies ux uy 12.0 unit-combat-relevant?))]
                                 [choke-pt : (Option (Pairof Float Float))
                                  (and (not save-for-pulsar-raid?)
                                       (not aa-in-lethal-range?)
                                       (not under-fire-low-sh?)
                                       (>= en 55.0)
                                       (for/or : (Option (Pairof Float Float)) ([cp (in-list choke-points)])
                                         (define cx (safe-fl (car cp) 0.0))
                                         (define cy (safe-fl (cdr cp) 0.0))
                                         (and (<= (dist2 ux uy cx cy) 6.5)
                                              (let* ([rot (modulo (quotient (max 0 current-frame) 16) 4)]
                                                     [ox (case rot [(0) 0.0] [(1) 1.6] [(2) -1.6] [else 0.0])]
                                                     [oy (case rot [(0) 0.0] [(1) 0.0] [(2) 0.0] [else 1.6])]
                                                     [wx (clamp-coord (+ cx ox))]
                                                     [wy (clamp-coord (+ cy oy))])
                                                (cond
                                                  [(safe-site? cx cy) (cons cx cy)]
                                                  [(safe-site? wx wy) (cons wx wy)]
                                                  [else #f])))))]
                                 [default-pt : (Option (Pairof Float Float))
                                  (and (not save-for-pulsar-raid?)
                                       (not aa-in-lethal-range?)
                                       (not under-fire-low-sh?)
                                       (>= en 55.0)
                                       (let* (;; L59-P2 (`sc2-nc-14`): When visible approaching ground enemies
                                              ;; patrol within `<= 18t` (defensive ramp ward, `ew-14 = 0`),
                                              ;; aim dead-center down the ramp (`3.0t` toward approaching enemy
                                              ;; centroid) instead of toward the distant enemy main corner!
                                              [near-gnd-enemies
                                               (if (= ew-14 0)
                                                   (for/list : (Listof Any)
                                                             ([e (in-list enemy-units)]
                                                              #:when (and (not (uh-flying? e))
                                                                          (unit-combat-relevant? e)
                                                                          (<= (dist2 ux uy (uh-x e) (uh-y e)) 18.0)))
                                                     e)
                                                   '())]
                                              [aim-x
                                               (if (pair? near-gnd-enemies)
                                                   (/ (for/fold ([s : Float 0.0]) ([e (in-list near-gnd-enemies)]) (+ s (uh-x e)))
                                                      (exact->inexact (length near-gnd-enemies)))
                                                   enemy-base-x)]
                                              [aim-y
                                               (if (pair? near-gnd-enemies)
                                                   (/ (for/fold ([s : Float 0.0]) ([e (in-list near-gnd-enemies)]) (+ s (uh-y e)))
                                                      (exact->inexact (length near-gnd-enemies)))
                                                   enemy-base-y)]
                                              [dx (- aim-x ux)]
                                              [dy (- aim-y uy)]
                                              [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                              [step-fwd (if (pair? near-gnd-enemies) (min 3.0 (max 1.5 (- d 5.5))) 2.0)]
                                              [bx0 (if (and (null? near-gnd-enemies)
                                                            (<= (dist2 ux uy natural-x natural-y) 8.0))
                                                       (+ natural-x (* 2.0 (/ (- enemy-base-x natural-x)
                                                                              (max 0.01 (dist2 natural-x natural-y enemy-base-x enemy-base-y)))))
                                                       (+ ux (* step-fwd (/ dx d))))]
                                              [by0 (if (and (null? near-gnd-enemies)
                                                            (<= (dist2 ux uy natural-x natural-y) 8.0))
                                                       (+ natural-y (* 2.0 (/ (- enemy-base-y natural-y)
                                                                              (max 0.01 (dist2 natural-x natural-y enemy-base-x enemy-base-y)))))
                                                       (+ uy (* step-fwd (/ dy d))))]
                                              ;; L58-P3 + L59-P2 (`nc-14`): Center on ramp (`0.0`), then `2.6t`
                                              ;; retry offsets so unbuildable ramp edges clear on retry (`> 2.5t`)!
                                              [rot (modulo (quotient (max 0 current-frame) 16) 4)]
                                              [rox (case rot [(0) 0.0] [(1) (* -2.6 (/ dx d))] [(2) (* -2.6 (/ dy d))] [else (* 2.6 (/ dy d))])]
                                              [roy (case rot [(0) 0.0] [(1) (* -2.6 (/ dy d))] [(2) (* 2.6 (/ dx d))] [else (* -2.6 (/ dx d))])]
                                              [wx (clamp-coord (+ bx0 rox))]
                                              [wy (clamp-coord (+ by0 roy))])
                                         (and (safe-site? wx wy) (cons wx wy))))]
                                 [chosen (or mineral-trap-pt choke-pt default-pt)])
                            (and chosen
                                 (not (memv 2505 (uh-order-ids u)))
                                 (= (spell-unit-claim-count claims 'oracle-stasis-cd tag current-frame) 0)
                                 (spell-claim-point?! claims 'stasis-ward (car chosen) (cdr chosen)
                                                      STASIS-WARD-CLAIM-RADIUS current-frame STASIS-WARD-CLAIM-TTL)
                                 (begin
                                   (spell-claim-unit?! claims 'oracle-stasis-cd tag current-frame 20 #:caster-tag tag)
                                   (spell-directive tag 'oracle 'stasis-ward 'point 0
                                                    (car chosen) (cdr chosen) 'oracle-stasis-ward))))))])]

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

  ;; Phase B: Post-storm dry High Templars (< 50 energy) -> Hold merge if a friendly ready Nexus
  ;; (`>= 50e`, off `4126` Energy Recharge cooldown) is within `14.0t` and can recharge for Psi Storm;
  ;; otherwise Archon pair merge vs unpaired kite.
  (define recharge-ready-nexuses : (Listof Any)
    (if (and storm-ok?
             (= (spell-unit-claim-count claims 'nexus-energy-recharge 1 current-frame) 0))
        (for/list : (Listof Any)
                  ([b (in-list ally-buildings)]
                   #:when (and (hash? b)
                               (eq? (uh-type b) 'nexus)
                               (>= (safe-fl (dyn-hash-ref b 'build-progress 1.0) 1.0) 1.0)
                               (>= (uh-energy b) 50.0)))
          b)
        '()))
  (define (ht-awaiting-nexus-recharge? [u : Any]) : Any
    (and (pair? recharge-ready-nexuses)
         (let ([ux (uh-x u)] [uy (uh-y u)])
           (let loop-nx : Any ([rem : (Listof Any) recharge-ready-nexuses])
             (cond
               [(null? rem) #f]
               [(<= (dist2 ux uy (uh-x (car rem)) (uh-y (car rem))) 14.0) (car rem)]
               [else (loop-nx (cdr rem))])))))
  (define dry-hts : (Listof Any)
    (if (null? friendly-hts)
        '()
        (for/list ([u (in-list friendly-hts)]
                   #:when (and (ht-dry-for-archon? u)
                               (not (memv (uh-tag u) used-tags))))
          u)))
  (define-values (recharge-dirs-rev mergeable-dry-hts)
    (if (null? recharge-ready-nexuses)
        (values dirs-rev dry-hts)
        (let loop-r : (Values (Listof spell-directive) (Listof Any))
             ([rem : (Listof Any) dry-hts]
              [acc : (Listof spell-directive) dirs-rev]
              [keep-rev : (Listof Any) '()]
              [recharged? : Boolean #f])
          (cond
            [(null? rem) (values acc (reverse keep-rev))]
            [else
             (define ht (car rem))
             (define nx (and (not recharged?) (ht-awaiting-nexus-recharge? ht)))
             (cond
               [nx
                (define d-nx (dist2 (uh-x ht) (uh-y ht) (uh-x nx) (uh-y nx)))
                (if (<= d-nx 10.0)
                    (begin
                      (spell-claim-unit?! claims 'nexus-energy-recharge 1 current-frame 1344 #:caster-tag (uh-tag nx))
                      (loop-r (cdr rem)
                              (cons (spell-directive (uh-tag nx) 'nexus 'nexus-energy-recharge 'unit (uh-tag ht)
                                                     (uh-x ht) (uh-y ht) 'nexus-energy-recharge-ht)
                                    acc)
                              keep-rev
                              #t))
                    ;; Step HT into 10.0t Nexus Energy Recharge cast range instead of burning it on Archon merge!
                    (loop-r (cdr rem)
                            (cons (spell-directive (uh-tag ht) 'high-templar 'move 'move 0
                                                   (uh-x nx) (uh-y nx) 'ht-approach-nexus-recharge)
                                  acc)
                            keep-rev
                            #t))]
               [else
                (loop-r (cdr rem) acc (cons ht keep-rev) recharged?)])]))))

  (if (null? mergeable-dry-hts)
      (reverse recharge-dirs-rev)
      (let-values ([(final-rev _paired)
                    (let loop : (Values (Listof spell-directive) (Listof Integer))
                         ([rem : (Listof Any) mergeable-dry-hts]
                          [acc : (Listof spell-directive) recharge-dirs-rev]
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
                              [(and (hash? partner)
                                    (let ([mx (* 0.5 (+ x1 (uh-x partner)))]
                                          [my (* 0.5 (+ y1 (uh-y partner)))])
                                      (not (any-unit-within?
                                            all-enemies mx my 8.5
                                            (lambda ([e : Any])
                                              (and (sc2-enemy-unit-targetable? e)
                                                   (unit-combat-relevant? e)))))))
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
         #:ghost-cloak-researched? Boolean
         #:interference-matrix-researched? Boolean
         #:neural-parasite-researched? Boolean
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
         #:ghost-cloak-researched? [ghost-cloak-researched? #t]
         #:interference-matrix-researched? [interference-matrix-researched? #t]
         #:neural-parasite-researched? [neural-parasite-researched? #t]
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
  (define-values (z-casters t-casters t-scvs dmg-units p-casters p-hts)
    (for/fold ([zs : (Listof Any) '()]
               [ts : (Listof Any) '()]
               [scvs : (Listof Any) '()]
               [dmgs : (Listof Any) '()]
               [ps : (Listof Any) '()]
               [hts : (Listof Any) '()]
               #:result (values (reverse zs) (reverse ts) (reverse scvs) (reverse dmgs) (reverse ps) (reverse hts)))
              ([u (in-list ally-units)]
               #:when (hash? u))
      (define sym (uh-type u))
      (define next-dmgs (if (ally-repair-target-valid? u) (cons u dmgs) dmgs))
      (cond
        [(memq sym ZERG-CASTER-SYMS)
         (define t (uh-tag u))
         (values (if (and (> t 0) (not (memv t exclude-tags))) (cons u zs) zs) ts scvs next-dmgs ps hts)]
        [(eq? sym 'scv)
         (define t (uh-tag u))
         (values zs ts (if (and (> t 0) (not (memv t exclude-tags))) (cons u scvs) scvs) next-dmgs ps hts)]
        [(memq sym TERRAN-CASTER-SYMS)
         (define t (uh-tag u))
         (values zs (if (and (> t 0) (not (memv t exclude-tags))) (cons u ts) ts) scvs next-dmgs ps hts)]
        [(memq sym PROTOSS-CASTER-SYMS)
         (define t (uh-tag u))
         (define next-hts (if (eq? sym 'high-templar) (cons u hts) hts))
         (values zs ts scvs next-dmgs (if (and (> t 0) (not (memv t exclude-tags))) (cons u ps) ps) next-hts)]
        [else
         (values zs ts scvs next-dmgs ps hts)])))
  (define t-repair-targets
    (if (null? t-scvs)
        '()
        (for/fold ([acc : (Listof Any) dmg-units]
                   #:result acc)
                  ([b (in-list ally-buildings)]
                   #:when (hash? b))
          (if (ally-repair-target-valid? b) (cons b acc) acc))))
  (define eff-t-casters
    (if (and (pair? t-scvs) (pair? t-repair-targets))
        (if (null? t-casters) t-scvs (append t-casters t-scvs))
        t-casters))
  (cond
    [(and (null? z-casters) (null? eff-t-casters) (null? p-casters)) '()]
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
                 enemy-base-x enemy-base-y inject-queen-tags exclude-tags
                 researched-upgrades neural-parasite-researched?))
            (if (null? eff-t-casters)
                '()
                (run-terran-spellcaster-micro
                 eff-t-casters ally-units enemy-units claims current-frame
                 ally-buildings enemy-buildings effects researched-upgrades
                 yamato-researched? home-x home-y exclude-tags t-repair-targets
                 ghost-cloak-researched? interference-matrix-researched?))
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
         #:ghost-cloak-researched? Boolean
         #:interference-matrix-researched? Boolean
         #:neural-parasite-researched? Boolean
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
         #:ghost-cloak-researched? [ghost-cloak-researched? #t]
         #:interference-matrix-researched? [interference-matrix-researched? #t]
         #:neural-parasite-researched? [neural-parasite-researched? #t]
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
        #:ghost-cloak-researched? ghost-cloak-researched?
        #:interference-matrix-researched? interference-matrix-researched?
        #:neural-parasite-researched? neural-parasite-researched?
        #:home-x home-x
        #:home-y home-y
        #:natural-x natural-x
        #:natural-y natural-y
        #:enemy-base-x enemy-base-x
        #:enemy-base-y enemy-base-y
        #:inject-queen-tags inject-queen-tags
        #:choke-points choke-points
        #:exclude-tags exclude-tags)))

;; -----------------------------------------------------------------------------
;; 9. L38-P0-1a / 1b: DT ShadowStride PF Snipe & Burrowed Widow Mine Helpers
;; -----------------------------------------------------------------------------

(: shadow-stride-researched? (-> (Listof Any) Boolean))
(define (shadow-stride-researched? researched-upgrades)
  (for/or : Boolean ([up (in-list researched-upgrades)])
    (or (eqv? up 141)
        (let ([s (safe-sym up 'unknown)])
          (and (memq s '(shadow-stride shadow-strike effect-shadow-stride dark-templar-blink)) #t)))))

(: detector-unit-or-bldg-sym? (-> Symbol Boolean))
(define (detector-unit-or-bldg-sym? s)
  (and (memq s '(observer observer-siege-mode overseer overseer-siege-mode raven
                 photon-cannon missile-turret spore-crawler))
       #t))

;; Exact detection check for `widow-mine-burrowed`: NEVER target `cloak=1` undetected mines;
;; targetable iff unburrowed, explicitly detected (`cloak=2/3/4`), or within `11.0t` of a
;; friendly mobile/static detector when the observation omits `cloak`.
(: widow-mine-detected-targetable? (-> Any (Listof Any) Boolean))
(define (widow-mine-detected-targetable? wm ally-entities)
  (cond
    [(not (hash? wm)) #f]
    [(dyn-u-snapshot-flag wm) #f]
    [else
     (define raw-t (uh-raw-type wm))
     (define burrowed?
       (or (eq? raw-t 'widow-mine-burrowed)
           (dyn-u-burrowed-flag wm)))
     (cond
       [(not burrowed?) #t]
       [else
        (define cs (dyn-u-cloak-state wm))
        (cond
          [(eq? cs 'undetected) #f]
          [(or (eq? cs 'detected) (eq? cs 'not-cloaked)) #t]
          [else
           (define wmx (uh-x wm))
           (define wmy (uh-y wm))
           (for/or : Boolean ([a (in-list ally-entities)]
                              #:when (and (hash? a)
                                          (detector-unit-or-bldg-sym? (uh-raw-type a))))
             (define dx (- wmx (uh-x a)))
             (define dy (- wmy (uh-y a)))
             (<= (+ (* dx dx) (* dy dy)) 121.0))])])]))

(: dt-angle-diff (-> Float Float Float))
(define (dt-angle-diff a b)
  (define raw (- a b))
  (define pi-fl (exact->inexact pi))
  (define two-pi (* 2.0 pi-fl))
  (let loop ([v raw])
    (cond
      [(> v pi-fl) (loop (- v two-pi))]
      [(< v (- pi-fl)) (loop (+ v two-pi))]
      [else v])))

(: dt-clamp-blink-target (-> Float Float Float Float Float Float Float (Values Float Float)))
(define (dt-clamp-blink-target ux uy rx0 ry0 cx cy min-center-r)
  (define dx (- rx0 ux))
  (define dy (- ry0 uy))
  (define d (flsqrt (+ (* dx dx) (* dy dy))))
  (define-values (tx1 ty1)
    (if (> d SHADOW-STRIDE-MAX-RANGE)
        (let ([scale (/ SHADOW-STRIDE-MAX-RANGE (max 1e-4 d))])
          (values (+ ux (* scale dx)) (+ uy (* scale dy))))
        (values rx0 ry0)))
  (define pdx (- tx1 cx))
  (define pdy (- ty1 cy))
  (define pd (flsqrt (+ (* pdx pdx) (* pdy pdy))))
  (if (< pd min-center-r)
      (let* ([ox (if (> pd 0.05) pdx (- ux cx))]
             [oy (if (> pd 0.05) pdy (- uy cy))]
             [od (max 1e-4 (flsqrt (+ (* ox ox) (* oy oy))))]
             [px (+ cx (* min-center-r (/ ox od)))]
             [py (+ cy (* min-center-r (/ oy od)))]
             [cdx (- px ux)]
             [cdy (- py uy)]
             [cd (flsqrt (+ (* cdx cdx) (* cdy cdy)))])
        (if (> cd SHADOW-STRIDE-MAX-RANGE)
            (let ([s (/ SHADOW-STRIDE-MAX-RANGE (max 1e-4 cd))])
              (values (+ ux (* s cdx)) (+ uy (* s cdy))))
            (values px py)))
      (values tx1 ty1)))

(: dt-pf-ring-blink-target
   (-> Float Float Float Float Float Float Float Float Float Float (Values Float Float)))
(define (dt-pf-ring-blink-target ux uy tx0 ty0 th ring-r outer-r min-center-r d-tgt is-pf-flag)
  (define rx0 (+ tx0 (* ring-r (flcos th))))
  (define ry0 (+ ty0 (* ring-r (flsin th))))
  (define d-slot (dist2 ux uy rx0 ry0))
  (cond
    [(<= d-slot SHADOW-STRIDE-MAX-RANGE)
     (dt-clamp-blink-target ux uy rx0 ry0 tx0 ty0 min-center-r)]
    [(and (> is-pf-flag 0.5) (> d-tgt 0.1))
     ;; Exact circle-circle intersection on PF perimeter ring so every DT lands directly on the
     ;; 3.0..3.5t PF perimeter ring (instant melee swing, wide arc spread) rather than landing short
     ;; in the screening Marines/Hellbats!
     (define u-th (real->double-flonum (atan (- uy ty0) (- ux tx0))))
     (define r-cand (max ring-r outer-r))
     (define r-use
       (if (<= (- d-tgt r-cand) SHADOW-STRIDE-MAX-RANGE)
           r-cand
           (max min-center-r (- d-tgt SHADOW-STRIDE-MAX-RANGE))))
     (define denom (max 1e-4 (* 2.0 d-tgt r-use)))
     (define raw-cos (/ (- (+ (* d-tgt d-tgt) (* r-use r-use))
                           (* SHADOW-STRIDE-MAX-RANGE SHADOW-STRIDE-MAX-RANGE))
                        denom))
     (define clamped-cos (max -1.0 (min 1.0 raw-cos)))
     (define alpha-max (flacos clamped-cos))
     (define delta (dt-angle-diff th u-th))
     (define clamped-delta (max (- alpha-max) (min alpha-max delta)))
     (define final-th (+ u-th clamped-delta))
     (define rx1 (+ tx0 (* r-use (flcos final-th))))
     (define ry1 (+ ty0 (* r-use (flsin final-th))))
     (dt-clamp-blink-target ux uy rx1 ry1 tx0 ty0 min-center-r)]
    [else
     (dt-clamp-blink-target ux uy rx0 ry0 tx0 ty0 min-center-r)]))

;; L38-P0-1a + L39-P0-1b + L40-P0-1c: Coordinated Dark Templar `ShadowStride` (`2700`, upg `141`)
;; Planetary Fortress 1-shot perimeter-ring snipe + immediate PF focus-fire, followed by post-PF
;; static detector snipe (`missile-turret`/`photon-cannon`/`spore-crawler`) so surviving DTs go dark!
;; L40-P0-1c upgrades:
;;   1. Compute enemy ground-combat screen centroid near the PF (`<= 12.0t`); when a Bio/Hellbat
;;      screen blocks the direct approach side, bias PF perimeter slots onto the N/S/E flanking arcs
;;      STRICTLY away from the screen (`safe-th = threat-th + pi`, wings `[-2.00,-1.15]` & `[+1.15,+2.00]`)
;;      so DTs never blink straight onto the front edge into Hellbat/Bio splash!
;;   2. Whenever `dist(DT, assigned-slot) > SHADOW-STRIDE-MAX-RANGE (7.65t)`, emit cloaked flanking
;;      `move (16)` toward the lateral blink-launch point (bypassing the front screen cloaked!)
;;      rather than letting DTs blink short or fall through to `23` Attack-Move into Hellbats!
;;   3. Once `dist(DT, assigned-slot) <= 7.65t`, synchronized `ShadowStride (2700)` lands directly
;;      on the `3.0..3.45t` PF melee ring, with execution-confirmed `12f -> 314f` cooldown promotion.
(: plan-dt-blink-pf-snipe
   (->* ((Listof Any) (Listof Any) (Listof Any) spell-claims Integer)
        (#:researched-upgrades (Listof Any)
         #:shadow-stride-ok? (U Boolean 'auto)
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-dt-blink-pf-snipe
         ally-units enemy-units enemy-buildings claims current-frame
         #:researched-upgrades [researched-upgrades '()]
         #:shadow-stride-ok? [shadow-stride-override 'auto]
         #:exclude-tags [exclude-tags '()])
  (define dts
    (for/list : (Listof Any) ([u (in-list ally-units)]
                              #:when (and (hash? u)
                                          (eq? (uh-type u) 'dark-templar)
                                          (not (uh-hallucination? u))
                                          (> (uh-tag u) 0)
                                          (not (memv (uh-tag u) exclude-tags))))
      u))
  (cond
    [(null? dts) '()]
    [else
     (define ss-ok?
       (if (boolean? shadow-stride-override)
           shadow-stride-override
           (shadow-stride-researched? researched-upgrades)))
     (define dt-blink-ht (spell-claims-dt-blink-ready-frame claims))
     (define dt-issue-ht (spell-claims-dt-blink-issue-state claims))
     (define all-enemies
       (if (null? enemy-buildings) enemy-units (append enemy-buildings enemy-units)))
     (define n-dts (exact->inexact (length dts)))
     (define dt-cx
       (/ (for/fold ([s : Float 0.0]) ([u (in-list dts)]) (+ s (uh-x u))) n-dts))
     (define dt-cy
       (/ (for/fold ([s : Float 0.0]) ([u (in-list dts)]) (+ s (uh-y u))) n-dts))
     ;; L43-P0-1a (`p15` Detection-First Priority Inversion + Simultaneous Multi-Detector Blitz!):
     ;; Priority 1: ALL live visible enemy static detectors (`missile-turret`, `photon-cannon`,
     ;; `spore-crawler`) within `<= 20.0t` of the DT squad — EVEN WHEN a Planetary Fortress is
     ;; present! When `>= 2` static detectors exist (like `p15`'s North & South Turrets), split the
     ;; North & South DT wings to blink onto BOTH turrets simultaneously so both evaporate in
     ;; `< 0.25s`, blinding the PF + 6 Sieged Tanks + Bio; once `0` detectors remain, Priority 2
     ;; sweeps the Planetary Fortress -> Tanks -> SCVs -> Bio while permanently cloaked!
     (define live-detectors
       (let ([raw
              (for/list : (Listof Any)
                        ([e (in-list all-enemies)]
                         #:when (and (hash? e)
                                     (memq (uh-raw-type e) '(missile-turret photon-cannon spore-crawler))
                                     (not (dyn-u-snapshot-flag e))
                                     (> (uh-tag e) 0)
                                     (<= (dist2 (uh-x e) (uh-y e) dt-cx dt-cy) 20.01)))
                e)])
         (sort raw
               (lambda ([a : Any] [b : Any])
                 (define da (dist2 (uh-x a) (uh-y a) dt-cx dt-cy))
                 (define db (dist2 (uh-x b) (uh-y b) dt-cx dt-cy))
                 (if (= da db) (< (uh-tag a) (uh-tag b)) (< da db))))))
     ;; Priority 2 (when 0 static detectors remain): Live visible enemy Planetary Fortress `<= 19.0t`
     (define-values (best-pf best-pf-d)
       (if (pair? live-detectors)
           (values #f 999.0)
           (for/fold ([bp : Any #f] [bd : Float 19.01])
                     ([e (in-list all-enemies)]
                      #:when (and (hash? e)
                                  (eq? (uh-raw-type e) 'planetary-fortress)
                                  (not (dyn-u-snapshot-flag e))
                                  (> (uh-tag e) 0)))
             (define ex (uh-x e))
             (define ey (uh-y e))
             (define d (flsqrt (+ (* (- ex dt-cx) (- ex dt-cx))
                                  (* (- ey dt-cy) (- ey dt-cy)))))
             (if (< d bd) (values e d) (values bp bd)))))
     (define primary-tgt (if (pair? live-detectors) (car live-detectors) best-pf))
     (define is-pf? (and (null? live-detectors) best-pf #t))
     (cond
       [(not primary-tgt) '()]
       [(not is-pf?)
        ;; Priority 1: Static Detector Blitz (supports 1 detector OR simultaneous 2-wing dual-turret split!)
        (define det-pair : (Listof Any)
          (if (>= (length live-detectors) 2)
              (list (car live-detectors) (cadr live-detectors))
              (list (car live-detectors))))
        (define det-a (car det-pair))
        (define det-b (if (>= (length det-pair) 2) (cadr det-pair) #f))
        (define mx (if det-b (* 0.5 (+ (uh-x det-a) (uh-x det-b))) (uh-x det-a)))
        (define my (if det-b (* 0.5 (+ (uh-y det-a) (uh-y det-b))) (uh-y det-a)))
        (define max-part-dist 20.5)
        (define active-dts
          (for/list : (Listof Any)
                    ([u (in-list dts)]
                     #:when (for/or : Boolean ([det (in-list det-pair)])
                              (<= (dist2 (uh-x u) (uh-y u) (uh-x det) (uh-y det)) max-part-dist)))
            u))
        (if (null? active-dts)
            '()
            (let* ([an (exact->inexact (length active-dts))]
                   [acx (/ (for/fold ([s : Float 0.0]) ([u (in-list active-dts)]) (+ s (uh-x u))) an)]
                   [acy (/ (for/fold ([s : Float 0.0]) ([u (in-list active-dts)]) (+ s (uh-y u))) an)]
                   [theta0 (real->double-flonum (atan (- acy my) (- acx mx)))]
                   [d-ac-m (dist2 acx acy mx my)]
                   [screen-enemies
                    (for/list : (Listof Any)
                              ([e (in-list enemy-units)]
                               #:when (and (hash? e)
                                           (not (dyn-u-snapshot-flag e))
                                           (not (uh-hallucination? e))
                                           (not (uh-flying? e))
                                           (not (memq (uh-type e) '(scv probe drone)))
                                           (unit-combat-relevant? e)
                                           (<= (dist2 mx my (uh-x e) (uh-y e)) 14.5)
                                           (<= (dist2 acx acy (uh-x e) (uh-y e)) (+ d-ac-m 1.0))))
                      e)]
                   [n-screen (length screen-enemies)]
                   [screen-cx
                    (if (>= n-screen 3)
                        (/ (for/fold ([s : Float 0.0]) ([e (in-list screen-enemies)]) (+ s (uh-x e)))
                           (exact->inexact n-screen))
                        acx)]
                   [screen-cy
                    (if (>= n-screen 3)
                        (/ (for/fold ([s : Float 0.0]) ([e (in-list screen-enemies)]) (+ s (uh-y e)))
                           (exact->inexact n-screen))
                        acy)]
                   [threat-th (real->double-flonum (atan (- screen-cy my) (- screen-cx mx)))]
                   [screen-blocks-approach?
                    (and (>= (length active-dts) 4)
                         (>= n-screen 3)
                         (> (flcos (dt-angle-diff threat-th theta0)) 0.20))]
                   [safe-th (if screen-blocks-approach? (+ threat-th (exact->inexact pi)) theta0)]
                   [safe-dx (flcos safe-th)]
                   [safe-dy (flsin safe-th)]
                   [perp-dx (- safe-dy)]
                   [perp-dy safe-dx]
                   ;; Order dual detectors cleanly onto negative (`-1`) vs positive (`+1`) perp wing
                   [det-neg : Any
                    (if det-b
                        (let ([pa (+ (* (- (uh-x det-a) mx) perp-dx) (* (- (uh-y det-a) my) perp-dy))]
                              [pb (+ (* (- (uh-x det-b) mx) perp-dx) (* (- (uh-y det-b) my) perp-dy))])
                          (if (<= pa pb) det-a det-b))
                        det-a)]
                   [det-pos : Any
                    (if det-b
                        (if (eq? det-neg det-a) det-b det-a)
                        det-a)]
                   [sorted-dts
                    (sort active-dts
                          (lambda ([a : Any] [b : Any])
                            (define pa (+ (* (- (uh-x a) mx) perp-dx) (* (- (uh-y a) my) perp-dy)))
                            (define pb (+ (* (- (uh-x b) mx) perp-dx) (* (- (uh-y b) my) perp-dy)))
                            (if (= pa pb) (< (uh-tag a) (uh-tag b)) (< pa pb))))]
                   [n-act (length sorted-dts)]
                   [neg-side-cnt
                    (for/sum : Integer ([u (in-list sorted-dts)])
                      (if (< (+ (* (- (uh-x u) mx) perp-dx) (* (- (uh-y u) my) perp-dy)) 0.0) 1 0))]
                   [half-n
                    (if (and det-b (> neg-side-cnt 0) (< neg-side-cnt n-act))
                        neg-side-cnt
                        (quotient n-act 2))]
                   [in-melee-r 2.4]
                   [inner-r 1.45]
                   [outer-r 1.75]
                   [min-center-r 1.30]
                   [dt-plans
                    (for/list : (Listof (Vector Any Integer Float Float Float Boolean Integer Float Float Float Float Float Float Boolean Boolean Boolean Integer Float Float))
                              ([u (in-list sorted-dts)]
                               [i (in-naturals)])
                      (define tag (uh-tag u))
                      (define ux (uh-x u))
                      (define uy (uh-y u))
                      (define wing-neg? (or (not det-b) (< i half-n)))
                      (define my-det (if wing-neg? det-neg det-pos))
                      (define my-tid (uh-tag my-det))
                      (define dtx (uh-x my-det))
                      (define dty (uh-y my-det))
                      (define d-tgt (dist2 ux uy dtx dty))
                      (define in-flight? (dyn-u-has-order-ability? u 2700))
                      (define prev-iss (hash-ref dt-issue-ht tag (lambda () #f)))
                      (when (and prev-iss (> current-frame (vector-ref prev-iss 0)))
                        (define f0 (vector-ref prev-iss 0))
                        (define disp (dist2 ux uy (vector-ref prev-iss 1) (vector-ref prev-iss 2)))
                        (cond
                          [(or in-flight? (>= disp 3.0))
                           (hash-set! dt-blink-ht tag (max (hash-ref dt-blink-ht tag (lambda () -10000))
                                                           (+ f0 SHADOW-STRIDE-COOLDOWN-FRAMES)))
                           (hash-remove! dt-issue-ht tag)]
                          [(>= current-frame (+ f0 12))
                           (hash-remove! dt-issue-ht tag)]))
                      (define ready-f (hash-ref dt-blink-ht tag (lambda () -10000)))
                      (define wing-sign
                        (cond
                          [det-b (if wing-neg? -1.0 1.0)]
                          [(< (+ (* (- ux dtx) perp-dx) (* (- uy dty) perp-dy)) 0.0) -1.0]
                          [else 1.0]))
                      (define wf
                        (if wing-neg?
                            (/ (exact->inexact i) (exact->inexact (max 1 (- (if det-b half-n n-act) 1))))
                            (let ([hi-n (max 1 (- n-act half-n))])
                              (/ (exact->inexact (- i half-n)) (exact->inexact (max 1 (- hi-n 1)))))))
                      ;; Safe flank rim slot (`1.55..1.95t`) around each detector, slightly biased toward
                      ;; the outer N/S flank so DTs reach `<= 7.65t` blink range BEFORE Bio intercepts!
                      (define ang-off
                        (if screen-blocks-approach?
                            (* wing-sign (+ 1.60 (* 0.65 wf)))
                            (+ -1.20 (* 2.40 wf))))
                      (define ring-r (if (even? i) inner-r outer-r))
                      (define th (+ safe-th ang-off))
                      (define slot-x (clamp-coord (+ dtx (* ring-r (flcos th)))))
                      (define slot-y (clamp-coord (+ dty (* ring-r (flsin th)))))
                      (define d-slot (dist2 ux uy slot-x slot-y))
                      (define can-blink? (and ss-ok? (not in-flight?) (> d-tgt in-melee-r) (>= current-frame ready-f)))
                      (define in-range? (and can-blink? (or (not screen-blocks-approach?) (<= d-slot SHADOW-STRIDE-MAX-RANGE))))
                      (define damaged? (< (uh-hp-ratio u) 0.88))
                      (vector u tag ux uy d-tgt in-flight? ready-f wing-sign ring-r th slot-x slot-y d-slot
                              can-blink? in-range? damaged? my-tid dtx dty))]
                   [ready-tot (for/sum : Integer ([p (in-list dt-plans)]) (if (vector-ref p 13) 1 0))]
                   [ready-in-range-cnt (for/sum : Integer ([p (in-list dt-plans)]) (if (vector-ref p 14) 1 0))]
                   [damaged-ready-cnt (for/sum : Integer ([p (in-list dt-plans)])
                                        (if (and (vector-ref p 13) (vector-ref p 15)) 1 0))]
                   [any-already-on-det? (for/or : Boolean ([p (in-list dt-plans)]) (<= (vector-ref p 4) in-melee-r))]
                   [sync-thresh (max 2 (exact-floor (* 0.65 (exact->inexact ready-tot))))]
                   [squad-blink-go?
                    (or (not screen-blocks-approach?)
                        any-already-on-det?
                        (< ready-tot 4)
                        (>= ready-in-range-cnt sync-thresh)
                        (and (>= ready-in-range-cnt (max 2 (exact-floor (* 0.30 (exact->inexact ready-tot)))))
                             (>= damaged-ready-cnt 1)))])
              (for/list : (Listof spell-directive) ([p (in-list dt-plans)])
                (define tag (vector-ref p 1))
                (define ux (vector-ref p 2))
                (define uy (vector-ref p 3))
                (define d-tgt (vector-ref p 4))
                (define in-flight? (vector-ref p 5))
                (define wing-sign (vector-ref p 7))
                (define ring-r (vector-ref p 8))
                (define th (vector-ref p 9))
                (define slot-x (vector-ref p 10))
                (define slot-y (vector-ref p 11))
                (define can-blink? (vector-ref p 13))
                (define in-range? (vector-ref p 14))
                (define my-tid (vector-ref p 16))
                (define dtx (vector-ref p 17))
                (define dty (vector-ref p 18))
                ;; Cloaked outer-flank staging waypoint (`6.0t` back + `2.2t` wide => `6.39t <= 7.65t`!)
                (define-values (wp-x wp-y)
                  (if screen-blocks-approach?
                      (values (clamp-coord (+ slot-x (* -6.0 safe-dx) (* 2.2 wing-sign perp-dx)))
                              (clamp-coord (+ slot-y (* -6.0 safe-dy) (* 2.2 wing-sign perp-dy))))
                      (values slot-x slot-y)))
                (cond
                  [in-flight?
                   (spell-directive tag 'dark-templar 'shadow-stride 'hold 0 ux uy 'dt-blink-in-flight)]
                  [(and can-blink? screen-blocks-approach? (not in-range?))
                   (spell-directive tag 'dark-templar 'move 'move 0 wp-x wp-y 'dt-detector-cloaked-approach)]
                  [(and can-blink? screen-blocks-approach? (not squad-blink-go?))
                   (spell-directive tag 'dark-templar 'move 'move 0 wp-x wp-y 'dt-detector-sync-stage)]
                  [can-blink?
                   (define-values (bx by)
                     (dt-pf-ring-blink-target ux uy dtx dty th ring-r outer-r min-center-r d-tgt 0.0))
                   (hash-set! dt-blink-ht tag (+ current-frame 12))
                   (hash-set! dt-issue-ht tag (vector current-frame ux uy))
                   (spell-directive tag 'dark-templar 'shadow-stride 'point 0 bx by 'dt-blink-detector-snipe)]
                  [else
                   (spell-directive tag 'dark-templar 'attack-unit 'attack-unit my-tid dtx dty 'dt-detector-focus-fire)]))))]
       [else
        ;; Priority 2 (0 live static detectors): Synchronized Planetary Fortress Rim Alpha Strike!
        (define tgt-id (uh-tag primary-tgt))
        (define tx0 (uh-x primary-tgt))
        (define ty0 (uh-y primary-tgt))
        (define max-part-dist 19.5)
        (define active-dts
          (for/list : (Listof Any) ([u (in-list dts)]
                                    #:when (let ([dx (- (uh-x u) tx0)]
                                                 [dy (- (uh-y u) ty0)])
                                             (<= (+ (* dx dx) (* dy dy))
                                                 (* max-part-dist max-part-dist))))
            u))
        (if (< (length active-dts) 4)
            '()
            (let* ([an (exact->inexact (length active-dts))]
                   [acx (/ (for/fold ([s : Float 0.0]) ([u (in-list active-dts)]) (+ s (uh-x u))) an)]
                   [acy (/ (for/fold ([s : Float 0.0]) ([u (in-list active-dts)]) (+ s (uh-y u))) an)]
                   [theta0 (real->double-flonum (atan (- acy ty0) (- acx tx0)))]
                   ;; Detect screening ground-combat wall in front of the PF (`<= 12.0t` of PF
                   ;; and not behind the PF relative to the approaching DT centroid)
                   [d-ac-pf (dist2 acx acy tx0 ty0)]
                   [screen-enemies
                    (if is-pf?
                        (for/list : (Listof Any)
                                  ([e (in-list enemy-units)]
                                   #:when (and (hash? e)
                                               (not (dyn-u-snapshot-flag e))
                                               (not (uh-hallucination? e))
                                               (not (uh-flying? e))
                                               (not (memq (uh-type e) '(scv probe drone)))
                                               (unit-combat-relevant? e)
                                               (<= (dist2 tx0 ty0 (uh-x e) (uh-y e)) 12.0)
                                               (<= (dist2 acx acy (uh-x e) (uh-y e)) (+ d-ac-pf 1.0))))
                          e)
                        '())]
                   [n-screen (length screen-enemies)]
                   [screen-cx
                    (if (>= n-screen 3)
                        (/ (for/fold ([s : Float 0.0]) ([e (in-list screen-enemies)]) (+ s (uh-x e)))
                           (exact->inexact n-screen))
                        acx)]
                   [screen-cy
                    (if (>= n-screen 3)
                        (/ (for/fold ([s : Float 0.0]) ([e (in-list screen-enemies)]) (+ s (uh-y e)))
                           (exact->inexact n-screen))
                        acy)]
                   [threat-th (real->double-flonum (atan (- screen-cy ty0) (- screen-cx tx0)))]
                   [screen-blocks-approach?
                    (and is-pf?
                         (>= n-screen 3)
                         (> (flcos (dt-angle-diff threat-th theta0)) 0.20))]
                   [safe-th
                    (if screen-blocks-approach?
                        (+ threat-th (exact->inexact pi))
                        theta0)]
                   [safe-dx (flcos safe-th)]
                   [safe-dy (flsin safe-th)]
                   [perp-dx (- safe-dy)]
                   [perp-dy safe-dx]
                   [sorted-dts
                    (sort active-dts
                          (lambda ([a : Any] [b : Any])
                            (define pa (+ (* (- (uh-x a) tx0) perp-dx) (* (- (uh-y a) ty0) perp-dy)))
                            (define pb (+ (* (- (uh-x b) tx0) perp-dx) (* (- (uh-y b) ty0) perp-dy)))
                            (if (= pa pb) (< (uh-tag a) (uh-tag b)) (< pa pb))))]
                   [n-act (length sorted-dts)]
                   ;; Split flanking wings strictly by each DT's geometric side (`pa < 0` vs `pa >= 0`)
                   ;; when both sides are populated so a 14/13 split NEVER sends the 14th DT across the screen!
                   [neg-side-cnt
                    (for/sum : Integer ([u (in-list sorted-dts)])
                      (if (< (+ (* (- (uh-x u) tx0) perp-dx) (* (- (uh-y u) ty0) perp-dy)) 0.0) 1 0))]
                   [half-n
                    (if (and (> neg-side-cnt 0) (< neg-side-cnt n-act))
                        neg-side-cnt
                        (quotient n-act 2))]
                   [in-melee-r (if is-pf? 4.2 2.4)]
                   [inner-r (if is-pf? PF-PERIMETER-BLINK-INNER-RADIUS 1.65)]
                   [outer-r (if is-pf? PF-PERIMETER-BLINK-OUTER-RADIUS 2.15)]
                   [min-center-r (if is-pf? 2.9 1.35)]
                   [blink-pat (if is-pf? 'dt-blink-pf-snipe 'dt-blink-detector-snipe)]
                   [focus-pat (if is-pf? 'dt-pf-focus-fire 'dt-detector-focus-fire)]
                   [pf-flag (if is-pf? 1.0 0.0)]
                   ;; L41-P0-1a (`p15` Synchronized 20+-DT Alpha Strike):
                   ;; Pass 1 pre-computes every DT's assigned N/S/E PF rim slot, blink readiness,
                   ;; and range status so lead DTs HOLD on the wide cloaked staging arc (outside
                   ;; Hellbat/Marine agro!) until >= 70% of ready DTs are simultaneously <= 7.65t
                   ;; of their N/S/E PF rim slots — then fire ONE synchronized 20+-DT ShadowStride!
                   [dt-plans
                    (for/list : (Listof (Vector Any Integer Float Float Float Boolean Integer Float Float Float Float Float Float Boolean Boolean Boolean))
                              ([u (in-list sorted-dts)]
                               [i (in-naturals)])
                      (define tag (uh-tag u))
                      (define ux (uh-x u))
                      (define uy (uh-y u))
                      (define d-tgt (flsqrt (+ (* (- ux tx0) (- ux tx0))
                                               (* (- uy ty0) (- uy ty0)))))
                      (define in-flight? (dyn-u-has-order-ability? u 2700))
                      ;; Execution-confirmed cooldown promotion (`12f` pending -> `314f` confirmed)
                      (define prev-iss (hash-ref dt-issue-ht tag (lambda () #f)))
                      (when (and prev-iss (> current-frame (vector-ref prev-iss 0)))
                        (define f0 (vector-ref prev-iss 0))
                        (define disp (dist2 ux uy (vector-ref prev-iss 1) (vector-ref prev-iss 2)))
                        (cond
                          [(or in-flight? (>= disp 3.0))
                           (hash-set! dt-blink-ht tag (max (hash-ref dt-blink-ht tag (lambda () -10000))
                                                           (+ f0 SHADOW-STRIDE-COOLDOWN-FRAMES)))
                           (hash-remove! dt-issue-ht tag)]
                          [(>= current-frame (+ f0 12))
                           (hash-remove! dt-issue-ht tag)]))
                      (define ready-f (hash-ref dt-blink-ht tag (lambda () -10000)))
                      (define-values (ang-off wing-sign)
                        (cond
                          [screen-blocks-approach?
                           (if (< i half-n)
                               (let ([wf (/ (exact->inexact i) (exact->inexact (max 1 (- half-n 1))))])
                                 (values (+ -2.05 (* 0.73 wf)) -1.0))
                               (let* ([hi-n (max 1 (- n-act half-n))]
                                      [wf (/ (exact->inexact (- i half-n)) (exact->inexact (max 1 (- hi-n 1))))])
                                 (values (+ 1.32 (* 0.73 wf)) 1.0)))]
                          [else
                           (let ([frac (if (<= n-act 1)
                                           0.0
                                           (/ (exact->inexact i) (exact->inexact (- n-act 1))))])
                             (values (+ -1.20 (* 2.40 frac)) (if (< frac 0.5) -1.0 1.0)))]))
                      (define ring-r (if (even? i) inner-r outer-r))
                      (define th (+ safe-th ang-off))
                      (define slot-x (clamp-coord (+ tx0 (* ring-r (flcos th)))))
                      (define slot-y (clamp-coord (+ ty0 (* ring-r (flsin th)))))
                      (define d-slot (dist2 ux uy slot-x slot-y))
                      (define can-blink? (and ss-ok? (not in-flight?) (> d-tgt in-melee-r) (>= current-frame ready-f)))
                      (define in-range? (and can-blink? (or (not is-pf?) (<= d-slot SHADOW-STRIDE-MAX-RANGE))))
                      (define damaged? (< (uh-hp-ratio u) 0.88))
                      (vector u tag ux uy d-tgt in-flight? ready-f wing-sign ring-r th slot-x slot-y d-slot can-blink? in-range? damaged?))]
                   [ready-tot
                    (for/sum : Integer ([p (in-list dt-plans)])
                      (if (vector-ref p 13) 1 0))]
                   [ready-in-range-cnt
                    (for/sum : Integer ([p (in-list dt-plans)])
                      (if (vector-ref p 14) 1 0))]
                   [damaged-ready-cnt
                    (for/sum : Integer ([p (in-list dt-plans)])
                      (if (and (vector-ref p 13) (vector-ref p 15)) 1 0))]
                   [any-already-on-pf?
                    (for/or : Boolean ([p (in-list dt-plans)])
                      (<= (vector-ref p 4) in-melee-r))]
                   [sync-thresh (max 4 (exact-floor (* 0.70 (exact->inexact ready-tot))))]
                   [squad-blink-go?
                    (or (not is-pf?)
                        (not screen-blocks-approach?)
                        any-already-on-pf?
                        (< ready-tot 4)
                        (>= ready-in-range-cnt sync-thresh)
                        ;; L42-P0-1b + L43-P0-1a (`p15` SP Bio rush): Trigger under-fire early blink
                        ;; release on the VERY FIRST damaged ready DT (`>= 1` damaged, `>= 35%` ready
                        ;; in range) so DTs blink OVER rushing Bio onto the PF before getting intercepted!
                        (and (>= ready-in-range-cnt (max 4 (exact-floor (* 0.35 (exact->inexact ready-tot)))))
                             (>= damaged-ready-cnt 1)))])
              (for/list : (Listof spell-directive)
                        ([p (in-list dt-plans)])
                (define tag (vector-ref p 1))
                (define ux (vector-ref p 2))
                (define uy (vector-ref p 3))
                (define d-tgt (vector-ref p 4))
                (define in-flight? (vector-ref p 5))
                (define wing-sign (vector-ref p 7))
                (define ring-r (vector-ref p 8))
                (define th (vector-ref p 9))
                (define slot-x (vector-ref p 10))
                (define slot-y (vector-ref p 11))
                (define can-blink? (vector-ref p 13))
                (define in-range? (vector-ref p 14))
                ;; Wide cloaked staging arc (`6.2t` back along -safe + `2.8t` wide along wing*perp
                ;; => `6.80t <= 7.65t` from PF rim slot, staying clear of Hellbat/Marine corners!)
                (define-values (wp-x wp-y)
                  (if screen-blocks-approach?
                      (values (clamp-coord (+ slot-x (* -6.2 safe-dx) (* 2.8 wing-sign perp-dx)))
                              (clamp-coord (+ slot-y (* -6.2 safe-dy) (* 2.8 wing-sign perp-dy))))
                      (values slot-x slot-y)))
                (cond
                  [in-flight?
                   (spell-directive tag 'dark-templar 'shadow-stride 'hold 0 ux uy 'dt-blink-in-flight)]
                  [(and can-blink? is-pf? (not in-range?))
                   (spell-directive tag 'dark-templar 'move 'move 0 wp-x wp-y 'dt-pf-cloaked-approach)]
                  [(and can-blink? is-pf? (not squad-blink-go?))
                   ;; Hold already-in-range lead DTs on the wide cloaked staging arc until >= 70%
                   ;; of the squad is simultaneously ready to alpha-strike the N/S/E PF rim!
                   (spell-directive tag 'dark-templar 'move 'move 0 wp-x wp-y 'dt-pf-sync-stage)]
                  [can-blink?
                   (define-values (bx by)
                     (dt-pf-ring-blink-target ux uy tx0 ty0 th ring-r outer-r min-center-r d-tgt pf-flag))
                   (hash-set! dt-blink-ht tag (+ current-frame 12))
                   (hash-set! dt-issue-ht tag (vector current-frame ux uy))
                   (spell-directive tag 'dark-templar 'shadow-stride 'point 0 bx by blink-pat)]
                  [else
                   (spell-directive tag 'dark-templar 'attack-unit 'attack-unit tgt-id tx0 ty0 focus-pat)]))))])]))

;; L39-P0-1e (`z16` Mutalisk Magic-Box vs Thors):
;; When `>= 6` Mutalisks engage enemy `Thor`s (Javelin AA splash `0.5t` radius / `1.0t` diameter),
;; assign non-crossing concentric spread slots (`>= 1.5t` spacing, within `<= 3.0t` Mutalisk range)
;; directly OVER the nearest Thor, issuing pure `MOVE (16)` into slot (zero boid-clumping!) and
;; `HOLD_POSITION (18)` once positioned so Mutalisks hover spread apart and auto-attack!
(: plan-mutalisk-magic-box
   (->* ((Listof Any) (Listof Any))
        (#:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-mutalisk-magic-box
         ally-units enemy-units
         #:exclude-tags [exclude-tags '()])
  (define mutas
    (for/list : (Listof Any) ([u (in-list ally-units)]
                              #:when (and (hash? u)
                                          (eq? (uh-type u) 'mutalisk)
                                          (not (uh-hallucination? u))
                                          (> (uh-tag u) 0)
                                          (not (memv (uh-tag u) exclude-tags))))
      u))
  (cond
    [(< (length mutas) MUTA-MAGIC-BOX-MIN-COUNT) '()]
    [else
     (define n-mutas (exact->inexact (length mutas)))
     (define mcx (/ (for/fold ([s : Float 0.0]) ([u (in-list mutas)]) (+ s (uh-x u))) n-mutas))
     (define mcy (/ (for/fold ([s : Float 0.0]) ([u (in-list mutas)]) (+ s (uh-y u))) n-mutas))
     (define-values (best-thor _best-td)
       (for/fold ([bt : Any #f] [bd : Float 16.51])
                 ([e (in-list enemy-units)]
                  #:when (and (hash? e)
                              (memq (uh-type e) '(thor thor-ap))
                              (not (dyn-u-snapshot-flag e))
                              (> (uh-tag e) 0)))
         (define d (dist2 mcx mcy (uh-x e) (uh-y e)))
         (if (< d bd) (values e d) (values bt bd))))
     (cond
       [(not best-thor) '()]
       [else
        (define tx0 (uh-x best-thor))
        (define ty0 (uh-y best-thor))
        (define n (length mutas))
        (define two-pi (* 2.0 (exact->inexact pi)))
        (define m1 (min n 5))
        (define m2 (min (max 0 (- n 5)) 12))
        (define m3 (max 0 (- n 17)))
        (define slots-r1 : (Listof (Pairof Float Float))
          (for/list : (Listof (Pairof Float Float)) ([k (in-range m1)])
            (define ang (* two-pi (/ (exact->inexact k) (exact->inexact (max 1 m1)))))
            (cons (clamp-coord (+ tx0 (* 1.40 (flcos ang))))
                  (clamp-coord (+ ty0 (* 1.40 (flsin ang)))))))
        (define slots-r2 : (Listof (Pairof Float Float))
          (for/list : (Listof (Pairof Float Float)) ([k (in-range m2)])
            (define ang (+ 0.26 (* two-pi (/ (exact->inexact k) (exact->inexact (max 1 m2))))))
            (cons (clamp-coord (+ tx0 (* 2.90 (flcos ang))))
                  (clamp-coord (+ ty0 (* 2.90 (flsin ang)))))))
        (define slots-r3 : (Listof (Pairof Float Float))
          (for/list : (Listof (Pairof Float Float)) ([k (in-range m3)])
            (define ang (+ 0.52 (* two-pi (/ (exact->inexact k) (exact->inexact (max 1 m3))))))
            (cons (clamp-coord (+ tx0 (* 4.35 (flcos ang))))
                  (clamp-coord (+ ty0 (* 4.35 (flsin ang)))))))
        ;; Split by distance to Thor (inner ring = closest m1, middle ring = next m2, outer = rest)
        ;; and sort each ring independently by signed angle relative to squad approach axis `app-th`
        ;; (`dt-angle-diff` in `[-pi, +pi]` -> eliminates West-axis `+-pi` wrap crossing so Mutas
        ;; fan out cleanly `>= 1.50t` from tick 0 without crossing paths in `z16` SP!).
        (define app-th (real->double-flonum (atan (- mcy ty0) (- mcx tx0))))
        (define by-thor-dist
          (sort mutas
                (lambda ([a : Any] [b : Any])
                  (define da (dist2 (uh-x a) (uh-y a) tx0 ty0))
                  (define db (dist2 (uh-x b) (uh-y b) tx0 ty0))
                  (if (= da db) (< (uh-tag a) (uh-tag b)) (< da db)))))
        (: sort-ring-mutas (-> (Listof Any) (Listof Any)))
        (define (sort-ring-mutas ring)
          (sort ring
                (lambda ([a : Any] [b : Any])
                  (define aa (dt-angle-diff (real->double-flonum (atan (- (uh-y a) ty0) (- (uh-x a) tx0))) app-th))
                  (define ab (dt-angle-diff (real->double-flonum (atan (- (uh-y b) ty0) (- (uh-x b) tx0))) app-th))
                  (if (= aa ab) (< (uh-tag a) (uh-tag b)) (< aa ab)))))
        (: sort-ring-slots (-> (Listof (Pairof Float Float)) (Listof (Pairof Float Float))))
        (define (sort-ring-slots ring)
          (sort ring
                (lambda ([a : (Pairof Float Float)] [b : (Pairof Float Float)])
                  (define aa (dt-angle-diff (real->double-flonum (atan (- (cdr a) ty0) (- (car a) tx0))) app-th))
                  (define ab (dt-angle-diff (real->double-flonum (atan (- (cdr b) ty0) (- (car b) tx0))) app-th))
                  (< aa ab))))
        (define r1-mutas (sort-ring-mutas (take by-thor-dist m1)))
        (define after-r1 (drop by-thor-dist m1))
        (define r2-mutas (sort-ring-mutas (take after-r1 m2)))
        (define r3-mutas (sort-ring-mutas (drop after-r1 m2)))
        (define sorted-mutas (append r1-mutas r2-mutas r3-mutas))
        (define sorted-slots
          (append (sort-ring-slots slots-r1)
                  (sort-ring-slots slots-r2)
                  (sort-ring-slots slots-r3)))
        (define healthy-cnt
          (for/sum : Integer ([u (in-list sorted-mutas)])
            (if (>= (uh-total-hp u) 32.0) 1 0)))
        (for/list : (Listof spell-directive)
                  ([u (in-list sorted-mutas)]
                   [slot (in-list sorted-slots)])
          (define tag (uh-tag u))
          (define ux (uh-x u))
          (define uy (uh-y u))
          (define sx (car slot))
          (define sy (cdr slot))
          (define d-slot (dist2 ux uy sx sy))
          (define d-thor (dist2 ux uy tx0 ty0))
          (define min-ally-sep
            (for/fold ([m : Float 999.0]) ([other (in-list sorted-mutas)])
              (if (= (uh-tag other) tag)
                  m
                  (min m (dist2 ux uy (uh-x other) (uh-y other))))))
          ;; L42-P0-1c + L43-P0-1d + L47-P0-1a + L58-P2 (`z16` Muta Magic-Box):
          ;; Require `>= 1.25t` pairwise clearance (outside Thor Javelin 0.5t splash radius / 1.0t diameter)
          ;; and trigger `HOLD_POSITION (18)` as soon as within shooting range of the Thor (`<= 4.25t`) OR
          ;; screening enemy AA (`<= 3.6t`, e.g., Marines in front of Thors) so Mutas fire immediately!
          (define near-aa-in-range?
            (for/or : Boolean ([e (in-list enemy-units)])
              (and (hash? e)
                   (not (dyn-u-snapshot-flag e))
                   (enemy-anti-air-or-air-threat? e)
                   (<= (dist2 ux uy (uh-x e) (uh-y e)) 3.6))))
          (define ready-to-hold?
            (and (>= min-ally-sep 1.25)
                 (or (<= d-thor 4.25)
                     near-aa-in-range?
                     (and (<= d-slot 1.05) (<= d-thor 4.35)))))
          (cond
            [(and (< (uh-total-hp u) 32.0) (>= healthy-cnt 4))
             (define dx (- ux tx0))
             (define dy (- uy ty0))
             (define d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy)))))
             (define kx (clamp-coord (+ ux (* 5.5 (/ dx d)))))
             (define ky (clamp-coord (+ uy (* 5.5 (/ dy d)))))
             (spell-directive tag 'mutalisk 'move 'kite 0 kx ky 'muta-magicbox-wounded-pull)]
            [ready-to-hold?
             (spell-directive tag 'mutalisk 'hold-position 'hold-position 0 sx sy 'muta-magicbox-hold-fire)]
            [else
             (spell-directive tag 'mutalisk 'move 'move 0 sx sy 'muta-magicbox-spread-move)]))])]))

;; =============================================================================
;; L43-P0-1b: Stalker Blink-Back & Coordinated Blink-Forward High-Value Snipe
;;   1. Blink-Back: Injured Stalker (`shields < 25.0` OR `hp < 55% max-hp`) under fire
;;      (`enemy ground-shooter <= 11.5t`) blinks `5.5t` (`4.5–6.5t`) back behind healthy
;;      friendly Stalkers (or away from nearest enemy threat) to drop aggro & preserve DPS!
;;   2. Blink-Forward Snipe: `>= 5` Blink-ready healthy Stalkers (`shields >= 40`, `hp >= 60`)
;;      within `<= 13.5t` of a high-value siege/splash/capital target (`siege-tank-sieged`,
;;      `colossus`, `liberator-ag`, `brood-lord`, `high-templar`, `disruptor`, `tempest`)
;;      coordinate a spread forward blink into Tank `1.75t` dead-zone / `2.8t` under Colossi &
;;      Liberators (clamped `<= 7.5t` cast range!) to focus-fire snipe them!
;; =============================================================================

(define STALKER-BLINK-COOLDOWN-FRAMES : Integer 157)
(define STALKER-BLINK-MAX-RANGE : Float 7.95)

(: stalker-blink-researched? (-> (Listof Any) Boolean))
(define (stalker-blink-researched? upgrades)
  (for/or : Boolean ([u (in-list upgrades)])
    (or (eq? u 'blink)
        (eq? u 'blink-tech)
        (eq? u 'stalker-blink)
        (eqv? u 87)
        (and (string? u)
             (or (string=? u "blink")
                 (string=? u "BlinkTech")
                 (string=? u "87"))))))

(: stalker-snipe-hv-priority (-> Symbol Float))
(define (stalker-snipe-hv-priority et)
  (case et
    [(siege-tank-sieged) 140.0]
    [(colossus) 135.0]
    [(liberator-ag) 130.0]
    [(disruptor) 125.0]
    [(high-templar) 120.0]
    [(brood-lord broodlord) 118.0]
    [(tempest) 115.0]
    [else 0.0]))

(: plan-stalker-blink-micro
   (->* ((Listof Any) (Listof Any) spell-claims Integer)
        (#:researched-upgrades (Listof Any)
         #:blink-ok? (U Boolean 'auto)
         #:allow-forward? Boolean
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-stalker-blink-micro
         ally-units enemy-units claims current-frame
         #:researched-upgrades [researched-upgrades '()]
         #:blink-ok? [blink-override 'auto]
         #:allow-forward? [allow-forward? #t]
         #:exclude-tags [exclude-tags '()])
  (define blink-ok?
    (if (boolean? blink-override)
        blink-override
        (stalker-blink-researched? researched-upgrades)))
  (cond
    [(not blink-ok?) '()]
    [else
     (define stalkers
       (for/list : (Listof Any)
                 ([u (in-list ally-units)]
                  #:when (and (hash? u)
                              (eq? (uh-type u) 'stalker)
                              (not (uh-hallucination? u))
                              (> (uh-tag u) 0)
                              (not (memv (uh-tag u) exclude-tags))))
         u))
     (define vis-enemies
       (for/list : (Listof Any)
                 ([e (in-list enemy-units)]
                  #:when (and (hash? e)
                              (not (dyn-u-snapshot-flag e))
                              (not (uh-hallucination? e))
                              (sc2-enemy-unit-targetable? e)
                              (unit-combat-relevant? e)
                              (> (uh-tag e) 0)))
         e))
     (cond
       [(or (null? stalkers) (null? vis-enemies)) '()]
       [else
        (define blink-ht (spell-claims-stalker-blink-ready-frame claims))
        ;; Partition into healthy vs injured Stalkers
        (define healthy-stalkers
          (for/list : (Listof Any)
                    ([s (in-list stalkers)]
                     #:when (and (>= (uh-shields s) 35.0)
                                 (>= (- (uh-total-hp s) (uh-shields s)) 55.0)))
            s))
        (define out : (Listof spell-directive) '())
        (define handled-tags : (HashTable Integer Boolean) (make-hasheqv))
        ;; L49-W2 (`b06` 1-Shot Tank Abort Fix): Check if a coordinated forward-blink strike squad
        ;; (`>= 7` ready Stalkers with `total-hp >= 85.0`) is within strike reach (`<= 11.6t`) of
        ;; a Sieged Tank or Colossus so Pass 1 Blink-Back does not peel a `90`-EHP Stalker (hit once
        ;; by Tank splash: `80 -> 10` shields, `80` hull) backward before Pass 2 blinks forward!
        (define forward-strike-imminent? : Boolean
          (and allow-forward?
               (for/or : Boolean ([e (in-list vis-enemies)])
                 (and (memq (uh-raw-type e) '(siege-tank-sieged colossus))
                      (let ([ex (uh-x e)] [ey (uh-y e)])
                        (>= (for/sum : Integer
                                     ([s (in-list stalkers)]
                                      #:when (and (>= (uh-total-hp s) 85.0)
                                                  (>= current-frame (hash-ref blink-ht (uh-tag s) (lambda () -10000)))
                                                  (<= (dist2 (uh-x s) (uh-y s) ex ey) 11.6)))
                              1)
                            7))))))
        ;; Pass 1: Injured Stalker Blink-Back (`shields < 25.0` OR `hull-hp < 44.0` OR `total-hp-ratio < 0.55`)
        ;; Blinks `5.5t` back behind healthy friendly Stalkers (or away from nearest enemy threat)
        (for ([s (in-list stalkers)])
          (define tag (uh-tag s))
          (define ready-f (hash-ref blink-ht tag (lambda () -10000)))
          (when (>= current-frame ready-f)
            (define sh (uh-shields s))
            (define hull-hp (max 0.0 (- (uh-total-hp s) sh)))
            (define injured?
              (and (not (and forward-strike-imminent? (>= (uh-total-hp s) 85.0)))
                   (or (< sh 25.0) (< hull-hp 44.0) (< (uh-hp-ratio s) 0.55))))
            (when injured?
              (define ux (uh-x s))
              (define uy (uh-y s))
              (define-values (near-e near-d)
                (for/fold ([be : Any #f] [bd : Float 11.51]) ([e (in-list vis-enemies)])
                  (define d (dist2 ux uy (uh-x e) (uh-y e)))
                  (if (< d bd) (values e d) (values be bd))))
              (when near-e
                (define ex (uh-x near-e))
                (define ey (uh-y near-e))
                ;; Compute retreat vector away from threat, biased toward healthy friendly Stalkers behind us
                (define raw-dx (- ux ex))
                (define raw-dy (- uy ey))
                (define raw-d (max 0.01 (flsqrt (+ (* raw-dx raw-dx) (* raw-dy raw-dy)))))
                (define away-x (/ raw-dx raw-d))
                (define away-y (/ raw-dy raw-d))
                (define-values (h-sx h-sy h-cnt)
                  (for/fold ([sx : Float 0.0] [sy : Float 0.0] [cnt : Integer 0])
                            ([hs (in-list healthy-stalkers)]
                             #:when (and (not (= (uh-tag hs) tag))
                                         (<= (dist2 ux uy (uh-x hs) (uh-y hs)) 10.0)
                                         ;; Healthy ally is farther from enemy than we are (behind us!)
                                         (>= (dist2 (uh-x hs) (uh-y hs) ex ey) (- near-d 0.5))))
                    (values (+ sx (uh-x hs)) (+ sy (uh-y hs)) (add1 cnt))))
                (define-values (dir-x dir-y)
                  (if (> h-cnt 0)
                      (let* ([hcx (/ h-sx (exact->inexact h-cnt))]
                             [hcy (/ h-sy (exact->inexact h-cnt))]
                             ;; Aim 2.0t behind healthy Stalker cluster centroid along away vector
                             [tx (+ hcx (* 2.0 away-x))]
                             [ty (+ hcy (* 2.0 away-y))]
                             [vx (- tx ux)]
                             [vy (- ty uy)]
                             [vd (max 0.01 (flsqrt (+ (* vx vx) (* vy vy))))])
                        ;; Ensure we actually move away from the threat (`dot > 0.25`)
                        (if (> (+ (* (/ vx vd) away-x) (* (/ vy vd) away-y)) 0.25)
                            (values (/ vx vd) (/ vy vd))
                            (values away-x away-y)))
                      (values away-x away-y)))
                ;; L59-P2 (`#1481` Waterfall Blink-Back): When a front-rank Stalker is close (`near-d <= 4.5t`)
                ;; with healthy Stalkers behind it (`h-cnt >= 1`) and survivable hull (`>= 36`), step back
                ;; `2.2..3.0t` behind the healthy rank while staying `<= 5.8t` from `(ex, ey)` so it keeps firing
                ;; with ZERO DPS break! When already at max range (`near-d > 4.5t`), solo, or critical hull,
                ;; Blink full `5.5t` back to escape focus-fire cleanly!
                (define waterfall-arc?
                  (and (<= near-d 4.5)
                       (> h-cnt 0)
                       (>= hull-hp 36.0)))
                (define step-dist : Float
                  (if waterfall-arc?
                      (max 2.2 (min 3.0 (max 2.2 (- 5.8 near-d))))
                      5.5))
                (define bx (clamp-coord (+ ux (* step-dist dir-x))))
                (define by (clamp-coord (+ uy (* step-dist dir-y))))
                (hash-set! blink-ht tag (+ current-frame STALKER-BLINK-COOLDOWN-FRAMES))
                (hash-set! handled-tags tag #t)
                (set! out (cons (spell-directive tag 'stalker 'blink 'point 0 bx by 'stalker-blink-back) out))))))
        ;; Pass 1b (L59-P2 `#1481` + L59-P3 flat-ground guard): Downhill / High-Ground Cliff Escape Blink-Out
        ;; ONLY for isolated high-ground cliff scouts/pairs (`sz >= 10.0`, `local-ally-cnt <= 2`,
        ;; `2:1+` outnumbered `ecnt >= 2 * local-ally-cnt`, `shields < 35.0`) — NEVER misfires on
        ;; normal flat-ground Stalker army fights (`b01`/`b11`/`p08`/`p09`)!
        (for ([s (in-list stalkers)])
          (define tag (uh-tag s))
          (define sz (uh-z s))
          (when (and sz
                     (>= sz 10.0)
                     (not (hash-has-key? handled-tags tag))
                     (>= current-frame (hash-ref blink-ht tag (lambda () -10000)))
                     (< (uh-shields s) 35.0))
            (define ux (uh-x s))
            (define uy (uh-y s))
            (define-values (esx esy ecnt)
              (for/fold ([sx : Float 0.0] [sy : Float 0.0] [cnt : Integer 0])
                        ([e (in-list vis-enemies)])
                (define ez (uh-z e))
                (if (and ez
                         (< (abs (- ez sz)) 1.2)
                         (<= (dist2 ux uy (uh-x e) (uh-y e)) 6.5))
                    (values (+ sx (uh-x e)) (+ sy (uh-y e)) (add1 cnt))
                    (values sx sy cnt))))
            (define local-ally-cnt
              (for/sum : Integer ([a (in-list stalkers)]
                                  #:when (<= (dist2 ux uy (uh-x a) (uh-y a)) 6.5))
                1))
            (when (and (<= local-ally-cnt 2)
                       (>= ecnt (* 2 local-ally-cnt)))
              (define ecx (/ esx (exact->inexact ecnt)))
              (define ecy (/ esy (exact->inexact ecnt)))
              (define dx (- ux ecx))
              (define dy (- uy ecy))
              (define dn (max 0.01 (flsqrt (+ (* dx dx) (* dy dy)))))
              (define bx (clamp-coord (+ ux (* 6.5 (/ dx dn)))))
              (define by (clamp-coord (+ uy (* 6.5 (/ dy dn)))))
              (hash-set! blink-ht tag (+ current-frame STALKER-BLINK-COOLDOWN-FRAMES))
              (hash-set! handled-tags tag #t)
              (set! out (cons (spell-directive tag 'stalker 'blink 'point 0 bx by 'stalker-blink-downhill-escape) out)))))
        ;; Pass 2: Coordinated Blink-Forward Snipe (`>= 5` Blink-ready Stalkers with `total-hp >= 85.0` vs HV target)
        (define ready-healthy
          (for/list : (Listof Any)
                    ([s (in-list stalkers)]
                     #:when (and (not (hash-has-key? handled-tags (uh-tag s)))
                                 (>= (uh-total-hp s) 85.0)
                                 (>= current-frame (hash-ref blink-ht (uh-tag s) (lambda () -10000)))))
            s))
        (when (and allow-forward? (>= (length ready-healthy) 5))
          (define rn (exact->inexact (length ready-healthy)))
          (define scx (/ (for/fold ([s : Float 0.0]) ([u (in-list ready-healthy)]) (+ s (uh-x u))) rn))
          (define scy (/ (for/fold ([s : Float 0.0]) ([u (in-list ready-healthy)]) (+ s (uh-y u))) rn))
          ;; Find highest-priority high-value siege/splash/capital target within `<= 13.5t`
          ;; (use `uh-raw-type` first so `'siege-tank-sieged` and `'liberator-ag` aren't canonicalized!)
          (define best-hv : Any
            (for/fold ([bt : Any #f] [bsc : Float 0.0] #:result bt)
                      ([e (in-list vis-enemies)])
              (define raw-et (uh-raw-type e))
              (define pri0 (stalker-snipe-hv-priority raw-et))
              (define pri (if (> pri0 0.0) pri0 (stalker-snipe-hv-priority (uh-type e))))
              (if (> pri 0.0)
                  (let ([d (dist2 scx scy (uh-x e) (uh-y e))])
                    (if (<= d 13.5)
                        (let ([sc (- pri (* 4.0 d) (* 0.05 (uh-total-hp e)))])
                          (if (> sc bsc) (values e sc) (values bt bsc)))
                        (values bt bsc)))
                  (values bt bsc))))
          (when best-hv
            (define hv-x (uh-x best-hv))
            (define hv-y (uh-y best-hv))
            (define hv-tag (uh-tag best-hv))
            (define hv-type (uh-raw-type best-hv))
            ;; L44-P0-1a + L49-W1 + L49-W2: Trigger `siege-tank-sieged` forward Blink at
            ;; `hv-centroid-d <= 10.6` (`strike-max-d <= 11.6`) BEFORE Tank splash lands, with
            ;; `total-hp >= 85.0` and `tank-overlap-safe?` `n-strike >= 7` (`local-enemy-cnt <= 2 * n-strike`)!
            (define hv-centroid-d (dist2 scx scy hv-x hv-y))
            (define centroid-in-range?
              (cond [(eq? hv-type 'siege-tank-sieged) (<= hv-centroid-d 10.6)]
                    [(eq? hv-type 'colossus) (<= hv-centroid-d 10.15)]
                    [else (<= hv-centroid-d 11.5)]))
            (define strike-max-d : Float
              (cond [(eq? hv-type 'siege-tank-sieged) 11.6]
                    [(eq? hv-type 'colossus) 11.2]
                    [else 11.5]))
            (define strike-stalkers
              (if centroid-in-range?
                  (for/list : (Listof Any)
                            ([s (in-list ready-healthy)]
                             #:when (<= (dist2 (uh-x s) (uh-y s) hv-x hv-y) strike-max-d))
                    s)
                  '()))
            (define local-enemy-cnt
              (for/sum : Integer ([e (in-list vis-enemies)]
                                  #:when (and (not (memq (uh-type e)
                                                         '(scv probe drone mule overlord overseer observer
                                                           larva egg medivac warp-prism warp-prism-phasing)))
                                              (<= (dist2 hv-x hv-y (uh-x e) (uh-y e)) 10.0)))
                1))
            (define other-sieged-tanks-in-range
              (for/sum : Integer ([e (in-list vis-enemies)]
                                  #:when (and (not (= (uh-tag e) hv-tag))
                                              (eq? (uh-raw-type e) 'siege-tank-sieged)
                                              (<= (dist2 hv-x hv-y (uh-x e) (uh-y e)) 13.0)))
                1))
            (define n-strike (length strike-stalkers))
            (define tank-overlap-safe?
              (or (< other-sieged-tanks-in-range 2)
                  (and (>= n-strike 7)
                       (<= local-enemy-cnt (* n-strike 2)))))
            (when (and (>= n-strike 5)
                       (<= local-enemy-cnt (* n-strike 2))
                       tank-overlap-safe?)
              ;; Land inside Tank `1.25t` dead-zone (`<= 2.0t` min range!) or `1.75t` arc under Colossus,
              ;; blinking straight along each Stalker's own near-side ray so wing Stalkers never cross paths!
              (define land-r
                (cond [(eq? hv-type 'siege-tank-sieged) 1.25]
                      [(eq? hv-type 'colossus) 1.75]
                      [else 2.8]))
              (for ([s (in-list strike-stalkers)]
                    [idx (in-naturals)])
                (define tag (uh-tag s))
                (define ux (uh-x s))
                (define uy (uh-y s))
                (define ray-th (real->double-flonum (atan (- uy hv-y) (- ux hv-x))))
                (define jitter (* (exact->inexact (- (modulo idx 3) 1)) 0.08))
                (define ang (+ ray-th jitter))
                (define goal-x (clamp-coord (+ hv-x (* land-r (flcos ang)))))
                (define goal-y (clamp-coord (+ hv-y (* land-r (flsin ang)))))
                (define d-goal (dist2 ux uy goal-x goal-y))
                ;; Only blink forward if not already inside landing ring (`d > land-r + 1.5`)
                (when (> (dist2 ux uy hv-x hv-y) (+ land-r 1.5))
                  (define-values (bx by)
                    (if (<= d-goal STALKER-BLINK-MAX-RANGE)
                        (values goal-x goal-y)
                        (let ([ratio (/ STALKER-BLINK-MAX-RANGE (max 0.01 d-goal))])
                          (values (clamp-coord (+ ux (* (- goal-x ux) ratio)))
                                  (clamp-coord (+ uy (* (- goal-y uy) ratio)))))))
                  (hash-set! blink-ht tag (+ current-frame STALKER-BLINK-COOLDOWN-FRAMES))
                  (hash-set! handled-tags tag #t)
                  (set! out (cons (spell-directive tag 'stalker 'blink 'point hv-tag bx by 'stalker-blink-forward-snipe) out)))))))
        ;; Pass 2b (L59-P2 `#1481`): Coordinated Uphill Cliff Blink-In when High-Ground Vision is Live!
        ;; When `>= 3` Blink-ready healthy Stalkers sit below visible uphill enemies (`ez - sz >= 1.5`)
        ;; within `<= 9.5t` and local enemy count is manageable (`<= 2 * n-uphill`), Blink onto the plateau!
        (when allow-forward?
          (define uphill-ready
            (for/list : (Listof Any)
                      ([s (in-list stalkers)]
                       #:when (and (not (hash-has-key? handled-tags (uh-tag s)))
                                   (uh-z s)
                                   (>= (uh-total-hp s) 85.0)
                                   (>= current-frame (hash-ref blink-ht (uh-tag s) (lambda () -10000)))))
              s))
          (when (>= (length uphill-ready) 3)
            (define rn (exact->inexact (length uphill-ready)))
            (define scx (/ (for/fold ([s : Float 0.0]) ([u (in-list uphill-ready)]) (+ s (uh-x u))) rn))
            (define scy (/ (for/fold ([s : Float 0.0]) ([u (in-list uphill-ready)]) (+ s (uh-y u))) rn))
            (define scz (/ (for/fold ([s : Float 0.0]) ([u (in-list uphill-ready)]) (+ s (or (uh-z u) 0.0))) rn))
            (define uphill-tgt : Any
              (for/fold ([bt : Any #f] [bd : Float 9.51] #:result bt)
                        ([e (in-list vis-enemies)])
                (define ez (uh-z e))
                (if (and ez (>= (- ez scz) 1.5))
                    (let ([d (dist2 scx scy (uh-x e) (uh-y e))])
                      (if (< d bd) (values e d) (values bt bd)))
                    (values bt bd))))
            (when uphill-tgt
              (define tx (uh-x uphill-tgt))
              (define ty (uh-y uphill-tgt))
              (define ttag (uh-tag uphill-tgt))
              (define in-range-uphill
                (for/list : (Listof Any)
                          ([s (in-list uphill-ready)]
                           #:when (and (let ([sz (uh-z s)] [ez (uh-z uphill-tgt)])
                                         (and sz ez (>= (- ez sz) 1.5)))
                                       (<= (dist2 (uh-x s) (uh-y s) tx ty) 9.5)))
                  s))
              (define n-up (length in-range-uphill))
              (define local-e-cnt
                (for/sum : Integer ([e (in-list vis-enemies)]
                                    #:when (and (not (memq (uh-type e)
                                                           '(scv probe drone mule overlord overseer observer
                                                             larva egg medivac warp-prism warp-prism-phasing)))
                                                (<= (dist2 tx ty (uh-x e) (uh-y e)) 9.5)))
                  1))
              (when (and (>= n-up 3) (<= local-e-cnt (* n-up 2)))
                (for ([s (in-list in-range-uphill)]
                      [idx (in-naturals)])
                  (define tag (uh-tag s))
                  (define ux (uh-x s))
                  (define uy (uh-y s))
                  (define dx (- tx ux))
                  (define dy (- ty uy))
                  (define d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy)))))
                  ;; Land onto the high ground (`min(STALKER-BLINK-MAX-RANGE, max(3.5, d - 2.0))`)
                  ;; with small lateral spread so Stalkers don't stack on one tile!
                  (define step (min STALKER-BLINK-MAX-RANGE (max 3.5 (- d 2.0))))
                  (define lat (* (exact->inexact (- (modulo idx 3) 1)) 0.65))
                  (define bx (clamp-coord (+ ux (* step (/ dx d)) (* lat (/ (- dy) d)))))
                  (define by (clamp-coord (+ uy (* step (/ dy d)) (* lat (/ dx d)))))
                  (hash-set! blink-ht tag (+ current-frame STALKER-BLINK-COOLDOWN-FRAMES))
                  (hash-set! handled-tags tag #t)
                  (set! out (cons (spell-directive tag 'stalker 'blink 'point ttag bx by 'stalker-blink-uphill-in) out)))))))
        (reverse out)])]))
