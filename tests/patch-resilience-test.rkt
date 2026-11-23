#lang racket/base

;; =============================================================================
;; tests/patch-resilience-test.rkt
;; Loop 60 Phase 0 Patch-Resilience & Live `ResponseData` Hydration Suite
;; =============================================================================
;; Verifies:
;;   1. Static SC2 `5.0.14` fallback accuracy (`Hatchery 275M`, `Queen 175M`,
;;      `Immortal 250M`, `Disruptor 3 supply`, `Tempest 4 supply / 13.0 air-range`,
;;      `Mothership 400/400/8`, `Sensor Tower 100/50`, `Cyclone` TechLab, Abduct
;;      Heroic immunity).
;;   2. Synthetic `4.10` protobuf `ResponseData` hydration (incremental Drone/morph
;;      cost subtraction via `SC2-UNIT-MORPH-BASE-MAP`, `Cyclone` non-TechLab,
;;      `Tempest 5 / 14.0`).
;;   3. Synthetic `5.0.15` protobuf `ResponseData` hydration (`Spire 200/150 -> 150/150`,
;;      `Ghost` Light attribute, `PsiStorm` cast-range `8.0` & effect radius `2.0`,
;;      `4107` unavailable / `4126` available, `MicrobialShroud` upgrade defined &
;;      `pathogen-glands` absent).
;;   4. Future ability ID `>= 4200` (`4512`) unbounded `hasheqv` hydration across
;;      BOTH `lib/sc2-typed-commands.rkt` and clean-room `lib/sc2-proto-wire-verifier.rkt`,
;;      `1766` Archon invariant protection, and clean `(reset-sc2-live-response-data!)`!
;;   5. Loop 60B (`#1606`) SC2 5.0.14 CamelCase `UpgradeData` alias fanout: verifies
;;      `sc2-upgrade-defined-in-live-data?`, `sc2-upgrade-live-available?`, and live
;;      upgrade costs across ALL static aliases (`warp-gate-research`, `metabolic-boost`,
;;      `centrifical-hooks`, `terran-vehicle-and-ship-plating-1`, `psionic-storm`, etc.)
;;      while keeping `'pathogen-glands` absent and shifted `>= 290` IDs name-isolated.
;;   6. Loop 61 Phase 1 (`#1603`): single-source total-value & on-field-supply static +
;;      live hydration (`SC2-LIVE-RAW-COST-OVERLAY`), unified `SC2-SPELL-SPEC` registry
;;      live hydration + aliases + defensive `EffectData` aliases.
;;   7. Loop 61 Phase 1 (`#1603`): static anti-duplication guard verifying zero parallel
;;      definitions of `UNIT-COST-TABLE`, `UNIT-RESOURCE-VALUE`, or `*splash-unit-supply-table*`
;;      anywhere under `lib/`.

(require racket/list
         racket/format
         racket/file
         racket/path
         racket/runtime-path
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-typed-commands.rkt"
         "../lib/sc2-proto-wire-verifier.rkt"
         "../lib/sc2-protobuf-ws.rkt")

(define-runtime-path repo-lib-dir "../lib")

(define passed 0)
(define failed 0)

(define (check-true name expr)
  (if expr
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "  [FAIL] ~a\n" name))))

(define (check-equal name actual expected)
  (if (equal? actual expected)
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "  [FAIL] ~a: expected ~s, got ~s\n" name expected actual))))

(define (check-approx name actual expected [tol 1e-4])
  (if (and (real? actual) (<= (abs (- actual expected)) tol))
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "  [FAIL] ~a: expected ~a (+/- ~a), got ~s\n" name expected tol actual))))

;; =============================================================================
;; Protobuf `ResponseData` Wire Encoders (`data.proto` verbatim field numbers)
;; =============================================================================

(define (pb-concat . parts)
  (apply bytes-append (filter bytes? parts)))

(define (encode-damage-bonus attr bonus)
  (pb-concat (encode-uint32 1 attr)
             (encode-float32 2 bonus)))

(define (encode-weapon #:type [wtype 1]
                       #:damage [dmg 10.0]
                       #:bonuses [bonuses '()]
                       #:attacks [attacks 1]
                       #:range [rng 5.0]
                       #:speed [spd 1.0])
  (apply pb-concat
         (append (list (encode-uint32 1 wtype)
                       (encode-float32 2 dmg)
                       (encode-uint32 4 attacks)
                       (encode-float32 5 rng)
                       (encode-float32 6 spd))
                 (for/list ([b (in-list bonuses)])
                   (encode-submessage-field 3 (encode-damage-bonus (car b) (cdr b)))))))

(define (encode-ability-data #:id id
                             #:link-name [lname ""]
                             #:friendly-name [fname ""]
                             #:remaps-to [remaps 0]
                             #:available [avail #t]
                             #:target [target 0]
                             #:allow-minimap [minimap? #f]
                             #:allow-autocast [autocast? #f]
                             #:is-building [bldg? #f]
                             #:footprint-radius [fpr 0.0]
                             #:cast-range [cr 0.0])
  (pb-concat
   (encode-uint32 1 id)
   (and (not (string=? lname "")) (encode-string-field 2 lname))
   (and (not (string=? fname "")) (encode-string-field 5 fname))
   (and (> remaps 0) (encode-uint32 7 remaps))
   (encode-bool 8 avail)
   (and (> target 0) (encode-uint32 9 target))
   (and minimap? (encode-bool 10 #t))
   (and autocast? (encode-bool 11 #t))
   (and bldg? (encode-bool 12 #t))
   (and (> fpr 0.0) (encode-float32 13 fpr))
   (and (> cr 0.0) (encode-float32 15 cr))))

(define (encode-unit-type-data #:id id
                               #:name name
                               #:available [avail #t]
                               #:cargo-size [cargo 0]
                               #:attributes [attrs '()]
                               #:speed [spd #f]
                               #:armor [arm #f]
                               #:weapons [wpns '()]
                               #:min [m 0]
                               #:gas [g 0]
                               #:food [f 0.0]
                               #:food-provided [fp 0.0]
                               #:ability-id [ab 0]
                               #:build-time [bt 0.0]
                               #:tech-alias [talias '()]
                               #:unit-alias [ualias 0]
                               #:tech-req [treq 0]
                               #:require-attached [req-att #f]
                               #:sight-range [sight 0.0])
  (apply pb-concat
         (append
          (list (encode-uint32 1 id)
                (encode-string-field 2 name)
                (encode-bool 3 avail)
                (and (> cargo 0) (encode-uint32 4 cargo))
                (and spd (encode-float32 9 spd))
                (and arm (encode-float32 10 arm))
                (encode-uint32 12 m)
                (encode-uint32 13 g)
                (and (> f 0.0) (encode-float32 14 f))
                (and (> ab 0) (encode-uint32 15 ab))
                (and (> bt 0.0) (encode-float32 17 bt))
                (and (> fp 0.0) (encode-float32 18 fp))
                (and (> ualias 0) (encode-uint32 22 ualias))
                (and (> treq 0) (encode-uint32 23 treq))
                (encode-bool 24 req-att)
                (and (> sight 0.0) (encode-float32 25 sight)))
          (for/list ([a (in-list attrs)])
            (encode-uint32 8 a))
          (for/list ([w (in-list wpns)])
            (encode-submessage-field 11 w))
          (for/list ([ta (in-list talias)])
            (encode-uint32 21 ta)))))

(define (encode-upgrade-data #:id id
                             #:name name
                             #:min [m 0]
                             #:gas [g 0]
                             #:research-time [rt 0.0]
                             #:ability-id [ab 0])
  (pb-concat
   (encode-uint32 1 id)
   (encode-string-field 2 name)
   (and (> m 0) (encode-uint32 3 m))
   (and (> g 0) (encode-uint32 4 g))
   (and (> rt 0.0) (encode-float32 5 rt))
   (and (> ab 0) (encode-uint32 6 ab))))

(define (encode-effect-data #:id id
                            #:name name
                            #:friendly-name [fname ""]
                            #:radius [rad 0.0])
  (pb-concat
   (encode-uint32 1 id)
   (encode-string-field 2 name)
   (and (not (string=? fname "")) (encode-string-field 3 fname))
   (and (> rad 0.0) (encode-float32 4 rad))))

(define (encode-response-data #:abilities [abs '()]
                              #:units [us '()]
                              #:upgrades [upgs '()]
                              #:effects [effs '()])
  (apply pb-concat
         (append
          (for/list ([b (in-list abs)]) (encode-submessage-field 1 b))
          (for/list ([b (in-list us)]) (encode-submessage-field 2 b))
          (for/list ([b (in-list upgs)]) (encode-submessage-field 3 b))
          (for/list ([b (in-list effs)]) (encode-submessage-field 5 b)))))

(printf "=================================================================\n")
(printf "SUITE: Loop 60 Phase 0 Patch-Resilience & ResponseData Hydration\n")
(printf "=================================================================\n")

;; Ensure clean offline baseline
(reset-sc2-live-response-data!)

;; -----------------------------------------------------------------------------
;; 1. Static SC2 5.0.14 Fallback Accuracy
;; -----------------------------------------------------------------------------
(printf "[1/8] Verifying static 5.0.14 fallback constants...\n")
(check-true  "offline-live-data-inactive" (not (unbox SC2-LIVE-DATA-ACTIVE?)))
(check-equal "static-5014-hatchery-min"         (sc2-min-cost 'hatchery) 275)
(check-equal "static-5014-queen-min"            (sc2-min-cost 'queen) 175)
(check-equal "static-5014-queen-burrowed-min"   (sc2-min-cost 'queen-burrowed) 175)
(check-equal "static-5014-immortal-min"         (sc2-min-cost 'immortal) 250)
(check-equal "static-5014-disruptor-supply"     (sc2-supply-cost 'disruptor) 3)
(check-equal "static-5014-tempest-supply"       (sc2-supply-cost 'tempest) 4)
(check-approx "static-5014-tempest-air-range"   (hash-ref (sc2-unit-combat-stats 'tempest) 'air-range) 13.0)
(check-equal "static-5014-mothership-min"       (sc2-min-cost 'mothership) 400)
(check-equal "static-5014-mothership-gas"       (sc2-gas-cost 'mothership) 400)
(check-equal "static-5014-mothership-supply"    (sc2-supply-cost 'mothership) 8)
(check-equal "static-5014-sensor-tower-min"     (sc2-min-cost 'sensor-tower) 100)
(check-equal "static-5014-sensor-tower-gas"     (sc2-gas-cost 'sensor-tower) 50)
(check-true  "static-5014-cyclone-techlab"      (sc2-unit-requires-techlab? 'cyclone))
(check-true  "static-5014-mothership-abduct-immune"
             (not (spell-valid-for-target-attrs? 'abduct 'mothership)))
(check-equal "static-5014-spire-200-200"
             (list (sc2-min-cost 'spire) (sc2-gas-cost 'spire))
             '(200 200))
(check-true  "static-5014-ghost-not-light"
             (not (sc2-unit-attr-has-any? 'ghost SC2-UNIT-ATTR-LIGHT)))

;; -----------------------------------------------------------------------------
;; 2. Synthetic SC2 4.10 Protobuf `ResponseData` Hydration
;; -----------------------------------------------------------------------------
(printf "[2/8] Verifying synthetic 4.10 ResponseData hydration & morph cost subtraction...\n")
(define data-410-bytes
  (encode-response-data
   #:units
   (list
    (encode-unit-type-data #:id 104 #:name "Drone" #:min 50 #:gas 0 #:food 1.0 #:build-time 272.0)
    (encode-unit-type-data #:id 86  #:name "Hatchery" #:min 350 #:gas 0 #:food 0.0 #:build-time 1600.0)
    (encode-unit-type-data #:id 126 #:name "Queen" #:min 150 #:gas 0 #:food 2.0 #:build-time 800.0)
    (encode-unit-type-data #:id 83  #:name "Immortal" #:min 275 #:gas 100 #:food 4.0 #:build-time 880.0)
    (encode-unit-type-data #:id 496 #:name "Tempest" #:min 250 #:gas 175 #:food 5.0
                           #:weapons (list (encode-weapon #:type 1 #:damage 40.0 #:attacks 1 #:range 10.0 #:speed 2.36)
                                           (encode-weapon #:type 2 #:damage 30.0 #:bonuses '((7 . 22.0)) #:attacks 1 #:range 14.0 #:speed 2.36)))
    (encode-unit-type-data #:id 692 #:name "Cyclone" #:min 150 #:gas 100 #:food 3.0 #:require-attached #f)
    (encode-unit-type-data #:id 18  #:name "CommandCenter" #:min 400 #:gas 0 #:food 0.0)
    (encode-unit-type-data #:id 132 #:name "OrbitalCommand" #:min 550 #:gas 0 #:food 0.0)
    (encode-unit-type-data #:id 110 #:name "Roach" #:min 75 #:gas 25 #:food 2.0)
    (encode-unit-type-data #:id 688 #:name "Ravager" #:min 100 #:gas 100 #:food 3.0)
    (encode-unit-type-data #:id 105 #:name "Zergling" #:min 25 #:gas 0 #:food 0.5)
    (encode-unit-type-data #:id 9   #:name "Baneling" #:min 50 #:gas 25 #:food 0.5))))

(register-sc2-response-data! (decode-response-data-bytes data-410-bytes))

(check-equal  "live-410-hatchery-min-300"         (sc2-min-cost 'hatchery) 300)
(check-equal  "live-410-hatchery-supply-0"        (sc2-supply-cost 'hatchery) 0)
(check-equal  "live-410-queen-min-150"            (sc2-min-cost 'queen) 150)
(check-equal  "live-410-immortal-min-275"         (sc2-min-cost 'immortal) 275)
(check-equal  "live-410-tempest-supply-5"         (sc2-supply-cost 'tempest) 5)
(check-approx "live-410-tempest-air-range-14"     (hash-ref (sc2-unit-combat-stats 'tempest) 'air-range) 14.0)
(check-true   "live-410-cyclone-no-techlab"       (not (sc2-unit-requires-techlab? 'cyclone)))
(check-equal  "live-410-orbital-incremental-150"  (sc2-min-cost 'orbital-command) 150)
(check-equal  "live-410-ravager-incremental"      (list (sc2-min-cost 'ravager) (sc2-gas-cost 'ravager) (sc2-supply-cost 'ravager)) '(25 75 1))
(check-equal  "live-410-zergling-pair-50-0-1"     (list (sc2-min-cost 'zergling) (sc2-gas-cost 'zergling) (sc2-supply-cost 'zergling)) '(50 0 1))
(check-equal  "live-410-baneling-incremental"     (list (sc2-min-cost 'baneling) (sc2-gas-cost 'baneling)) '(25 25))
(check-equal  "live-410-hatchery-build-frames"    (sc2-unit-build-frames 'hatchery) 1600)

;; -----------------------------------------------------------------------------
;; 3. Synthetic SC2 5.0.15 Protobuf `ResponseData` Hydration (via `decode-sc2-response`)
;; -----------------------------------------------------------------------------
(printf "[3/8] Verifying synthetic 5.0.15 ResponseData hydration (Spire, Ghost Light, PsiStorm, Upgrades)...\n")
(define data-5015-bytes
  (encode-response-data
   #:abilities
   (list
    (encode-ability-data #:id 1036 #:link-name "PsiStorm" #:friendly-name "Psi Storm"
                         #:available #t #:target 2 #:cast-range 8.0)
    (encode-ability-data #:id 4126 #:link-name "EnergyRecharge" #:friendly-name "Energy Recharge"
                         #:available #t #:target 3 #:cast-range 10.0)
    (encode-ability-data #:id 4107 #:link-name "BatteryOvercharge" #:friendly-name "Battery Overcharge"
                         #:available #f #:target 3))
   #:units
   (list
    (encode-unit-type-data #:id 104 #:name "Drone" #:min 50 #:gas 0 #:food 1.0)
    (encode-unit-type-data #:id 92  #:name "Spire" #:min 200 #:gas 150 #:food 0.0)
    (encode-unit-type-data #:id 50  #:name "Ghost" #:min 150 #:gas 125 #:food 2.0
                           #:attributes '(1 3 6) ;; Light, Biological, Psionic
                           #:speed 4.2 #:armor 1.0)
    (encode-unit-type-data #:id 74  #:name "Stalker" #:min 125 #:gas 50 #:food 2.0
                           #:attributes '(2 4))  ;; Armored, Mechanical (preserves synthetic SHIELDED!)
    (encode-unit-type-data #:id 692 #:name "Cyclone" #:min 150 #:gas 100 #:food 3.0 #:require-attached #t))
   #:upgrades
   (list
    (encode-upgrade-data #:id 299 #:name "MicrobialShroud" #:min 100 #:gas 100 #:research-time 1792.0 #:ability-id 4130))
   #:effects
   (list
    (encode-effect-data #:id 1 #:name "PsiStormPersistent" #:friendly-name "Psi Storm" #:radius 2.0))))

;; Round-trip through full `Response` protobuf message (field 13 = ResponseData, field 99 = status 3=in-game)
(define resp-5015-bytes
  (pb-concat (encode-uint32 99 3)
             (encode-submessage-field 13 data-5015-bytes)))
(define decoded-5015-resp (decode-sc2-response resp-5015-bytes))
(register-sc2-response-data! (sc2-response-data decoded-5015-resp))

(check-equal  "live-5015-spire-min-150"           (sc2-min-cost 'spire) 150)
(check-equal  "live-5015-spire-gas-150"           (sc2-gas-cost 'spire) 150)
(check-equal  "live-5015-spire-supply-0"          (sc2-supply-cost 'spire) 0)
(check-true   "live-5015-ghost-attr-light"        (sc2-unit-attr-has-any? 'ghost SC2-UNIT-ATTR-LIGHT))
(check-true   "live-5015-ghost-attr-psionic"      (sc2-unit-attr-has-any? 'ghost SC2-UNIT-ATTR-PSIONIC))
(check-true   "live-5015-ghost-not-armored"       (not (sc2-unit-attr-has-any? 'ghost SC2-UNIT-ATTR-ARMORED)))
(check-true   "live-5015-stalker-preserves-shielded"
              (sc2-unit-attr-has-any? 'stalker SC2-UNIT-ATTR-SHIELDED))
(check-approx "live-5015-ghost-speed-4.2"         (hash-ref (sc2-unit-combat-stats 'ghost) 'speed) 4.2)
(check-approx "live-5015-psistorm-cast-range-8.0" (sc2-ability-cast-range 1036) 8.0)
(check-equal  "live-5015-psistorm-target-point"   (sc2-ability-live-target-mode 1036) 'point)
(check-approx "live-5015-psistorm-effect-rad-2.0" (sc2-live-effect-radius 'psi-storm) 2.0)
(check-true   "live-5015-cyclone-techlab"         (sc2-unit-requires-techlab? 'cyclone))
(check-true   "live-5015-4107-unavailable"        (not (sc2-ability-live-available? 4107)))
(check-true   "live-5015-4126-available"          (sc2-ability-live-available? 4126))
(check-true   "live-5015-microbial-shroud-def"    (sc2-upgrade-defined-in-live-data? 'microbial-shroud))
(check-true   "live-5015-microbial-shroud-avail"  (sc2-upgrade-live-available? 'microbial-shroud))
(check-true   "live-5015-pathogen-glands-absent"  (not (sc2-upgrade-defined-in-live-data? 'pathogen-glands)))
(check-true   "live-5015-pathogen-glands-unavail" (not (sc2-upgrade-live-available? 'pathogen-glands)))
(check-equal  "live-5015-microbial-shroud-cost"   (list (sc2-min-cost 'microbial-shroud) (sc2-gas-cost 'microbial-shroud)) '(100 100))
(check-equal  "live-5015-microbial-shroud-abid"   (sc2-upgrade-research-ability-id 'microbial-shroud) 4130)

;; -----------------------------------------------------------------------------
;; 4. Future Ability ID >= 4200 (`hasheqv` Unbounded) + `1766` Guard + Clean Reset
;; -----------------------------------------------------------------------------
(printf "[4/8] Verifying future ability ID >= 4200 (4512) hydration, 1766 Archon guard, & clean reset...\n")
(define data-future-bytes
  (encode-response-data
   #:abilities
   (list
    (encode-ability-data #:id 4512 #:link-name "FuturePatch_Nova" #:friendly-name "Future Nova"
                         #:available #t #:target 2 #:allow-autocast #t #:cast-range 11.0)
    ;; Adversarial: SC2 sending 1766 as Target=None must NEVER bypass WireCmdArchon!
    (encode-ability-data #:id 1766 #:link-name "Morph_Archon" #:available #t #:target 1))))

(register-sc2-response-data! (decode-response-data-bytes data-future-bytes))

(define pt-ab-4512 (lookup-point-target-ability 4512))
(define ac-ab-4512 (lookup-autocast-ability 4512))
(check-true   "future-4512-point-lookup-ok"       (PointTargetAbility? pt-ab-4512))
(check-true   "future-4512-autocast-lookup-ok"    (AutocastAbility? ac-ab-4512))
(check-true   "future-4512-not-no-target"         (not (lookup-no-target-ability 4512)))
(check-approx "future-4512-cast-range-11.0"       (sc2-ability-cast-range 4512) 11.0)
(check-true   "archon-1766-never-in-no-target"    (not (lookup-no-target-ability 1766)))

;; Clean-room wire verifier MUST accept wire-encoded 4512 point command & 4512 toggle-autocast!
(define actors-1 (make-non-empty-unit-tags '(99001)))
(define pt-4512  (make-world-point2d 64.5 72.5))
(define wire-pt-4512 (encode-typed-sc2-action (WireCmdPoint pt-ab-4512 actors-1 pt-4512 #f)))
(define wire-ac-4512 (encode-typed-sc2-action (WireToggleAutocast ac-ab-4512 actors-1)))
(define-values (v-pt-ok? v-pt-dec) (verify-sc2-action-bytes wire-pt-4512))
(define-values (v-ac-ok? v-ac-dec) (verify-sc2-action-bytes wire-ac-4512))
(check-true  "future-4512-verifier-accepts-point-cmd"    v-pt-ok?)
(check-true  "future-4512-verifier-accepts-autocast-cmd" v-ac-ok?)

;; Clean reset restores static 5.0.14 defaults and clears 4512 from BOTH typed & verifier tables!
(reset-sc2-live-response-data!)
(define-values (v-pt-after-ok? _v-pt-after-err) (verify-sc2-action-bytes wire-pt-4512))
(define-values (v-ac-after-ok? _v-ac-after-err) (verify-sc2-action-bytes wire-ac-4512))
(check-true   "reset-restores-offline-flag"       (not (unbox SC2-LIVE-DATA-ACTIVE?)))
(check-equal  "reset-restores-hatchery-275"       (sc2-min-cost 'hatchery) 275)
(check-equal  "reset-restores-queen-175"          (sc2-min-cost 'queen) 175)
(check-equal  "reset-restores-spire-200-200"      (list (sc2-min-cost 'spire) (sc2-gas-cost 'spire)) '(200 200))
(check-equal  "reset-restores-tempest-4"          (sc2-supply-cost 'tempest) 4)
(check-approx "reset-restores-tempest-range-13.0" (hash-ref (sc2-unit-combat-stats 'tempest) 'air-range) 13.0)
(check-true   "reset-restores-ghost-not-light"    (not (sc2-unit-attr-has-any? 'ghost SC2-UNIT-ATTR-LIGHT)))
(check-true   "reset-clears-4512-typed-point"     (not (lookup-point-target-ability 4512)))
(check-true   "reset-clears-4512-typed-autocast"  (not (lookup-autocast-ability 4512)))
(check-true   "reset-clears-4512-verifier-point"  (not v-pt-after-ok?))
(check-true   "reset-clears-4512-verifier-auto"   (not v-ac-after-ok?))
(check-true   "reset-restores-4107-offline-avail" (sc2-ability-live-available? 4107))
(check-approx "reset-clears-4512-cast-range"      (sc2-ability-cast-range 4512) 0.0)

;; -----------------------------------------------------------------------------
;; 5. Loop 60B (`#1606`) SC2 5.0.14 CamelCase Upgrade Alias Fanout & >= 290 Isolation
;; -----------------------------------------------------------------------------
(printf "[5/8] Verifying real SC2 5.0.14 CamelCase UpgradeData alias fanout & >=290 isolation...\n")
(define data-5014-upgs-bytes
  (encode-response-data
   #:upgrades
   (list
    (encode-upgrade-data #:id 5   #:name "HiSecAutoTracking" #:min 100 #:gas 100 #:research-time 1280.0 #:ability-id 650)
    (encode-upgrade-data #:id 15  #:name "Stimpack" #:min 100 #:gas 100 #:research-time 2240.0 #:ability-id 730)
    (encode-upgrade-data #:id 16  #:name "ShieldWall" #:min 100 #:gas 100 #:research-time 1792.0 #:ability-id 731)
    (encode-upgrade-data #:id 17  #:name "PunisherGrenades" #:min 50 #:gas 50 #:research-time 960.0 #:ability-id 732)
    (encode-upgrade-data #:id 50  #:name "ExtendedThermalLance" #:min 150 #:gas 150 #:research-time 2240.0 #:ability-id 1097)
    (encode-upgrade-data #:id 52  #:name "PsiStormTech" #:min 200 #:gas 200 #:research-time 1792.0 #:ability-id 1126)
    (encode-upgrade-data #:id 66  #:name "zerglingmovementspeed" #:min 100 #:gas 100 #:research-time 1792.0 #:ability-id 1253)
    (encode-upgrade-data #:id 75  #:name "CentrificalHooks" #:min 150 #:gas 150 #:research-time 1792.0 #:ability-id 1482)
    (encode-upgrade-data #:id 84  #:name "WarpGateResearch" #:min 50 #:gas 50 #:research-time 2240.0 #:ability-id 1568)
    (encode-upgrade-data #:id 116 #:name "TerranVehicleAndShipArmorsLevel1" #:min 100 #:gas 100 #:research-time 2560.0 #:ability-id 864)
    (encode-upgrade-data #:id 293 #:name "DiggingClaws" #:min 150 #:gas 150 #:research-time 1280.0 #:ability-id 3709)
    (encode-upgrade-data #:id 300 #:name "InterferenceMatrix" #:min 50 #:gas 50 #:research-time 1280.0 #:ability-id 4131))))

(register-sc2-response-data! (decode-response-data-bytes data-5014-upgs-bytes))

(for ([usym (in-list '(warp-gate-research warp-gate warpgate warpgate-research
                       psi-storm psionic-storm psistorm-tech
                       extended-thermal-lance
                       stimpack
                       combat-shield shield-wall
                       concussive-shells punisher-grenades
                       metabolic-boost zergling-movementspeed
                       centrifical-hooks centrifugal-hooks
                       terran-vehicle-and-ship-plating-1 terran-vehicle-plating-1 vehicle-and-ship-plating-1
                       hi-sec-auto-tracking hisec-auto-tracking
                       adaptive-talons
                       interference-matrix))])
  (check-true (format "live-5014-upg-defined-~a" usym)
              (sc2-upgrade-defined-in-live-data? usym))
  (check-true (format "live-5014-upg-avail-~a" usym)
              (sc2-upgrade-live-available? usym)))

;; Non-primary aliases must also carry live ResponseData costs & research ability IDs!
(check-equal "live-5014-alias-cost-warp-gate-research"
             (list (sc2-min-cost 'warp-gate-research)
                   (sc2-gas-cost 'warp-gate-research)
                   (sc2-upgrade-research-ability-id 'warp-gate-research))
             '(50 50 1568))
(check-equal "live-5014-alias-cost-metabolic-boost"
             (list (sc2-min-cost 'metabolic-boost)
                   (sc2-gas-cost 'metabolic-boost)
                   (sc2-upgrade-research-ability-id 'metabolic-boost))
             '(100 100 1253))
(check-equal "live-5014-alias-cost-centrifical-hooks"
             (list (sc2-min-cost 'centrifical-hooks)
                   (sc2-gas-cost 'centrifical-hooks)
                   (sc2-upgrade-research-ability-id 'centrifical-hooks))
             '(150 150 1482))
(check-equal "live-5014-alias-cost-terran-vehicle-and-ship-plating-1"
             (list (sc2-min-cost 'terran-vehicle-and-ship-plating-1)
                   (sc2-gas-cost 'terran-vehicle-and-ship-plating-1)
                   (sc2-upgrade-research-ability-id 'terran-vehicle-and-ship-plating-1))
             '(100 100 864))
(check-equal "live-5014-alias-cost-psionic-storm"
             (list (sc2-min-cost 'psionic-storm)
                   (sc2-gas-cost 'psionic-storm)
                   (sc2-upgrade-research-ability-id 'psionic-storm))
             '(200 200 1126))
(check-equal "live-5014-alias-cost-adaptive-talons"
             (list (sc2-min-cost 'adaptive-talons)
                   (sc2-gas-cost 'adaptive-talons)
                   (sc2-upgrade-research-ability-id 'adaptive-talons))
             '(150 150 3709))

;; Removed / non-existent upgrade must return #f
(check-true "live-5014-pathogen-glands-absent"
            (not (sc2-upgrade-defined-in-live-data? 'pathogen-glands)))
(check-true "live-5014-pathogen-glands-unavail"
            (not (sc2-upgrade-live-available? 'pathogen-glands)))

;; Balance-mod shifted ID >= 290 isolation: id=299 "InterferenceMatrix" must NOT define 'microbial-shroud!
(define data-mod-a-shifted-bytes
  (encode-response-data
   #:upgrades
   (list
    (encode-upgrade-data #:id 15  #:name "Stimpack" #:min 100 #:gas 100)
    (encode-upgrade-data #:id 299 #:name "InterferenceMatrix" #:min 50 #:gas 50))))
(register-sc2-response-data! (decode-response-data-bytes data-mod-a-shifted-bytes))
(check-true "live-mod-a-299-interference-matrix-def"
            (sc2-upgrade-defined-in-live-data? 'interference-matrix))
(check-true "live-mod-a-299-microbial-shroud-absent"
            (not (sc2-upgrade-defined-in-live-data? 'microbial-shroud)))
(check-true "live-mod-a-299-microbial-shroud-unavail"
            (not (sc2-upgrade-live-available? 'microbial-shroud)))

;; Clean reset clears SC2-LIVE-DEFINED-UPGRADE-IDS and restores offline availability
(reset-sc2-live-response-data!)
(check-true "reset-clears-live-defined-warpgate"
            (not (sc2-upgrade-defined-in-live-data? 'warp-gate-research)))
(check-true "reset-restores-offline-avail-warpgate"
            (sc2-upgrade-live-available? 'warp-gate-research))

;; -----------------------------------------------------------------------------
;; 6. Loop 61 Phase 1 (`#1603`): Total-Value, On-Field Supply, & SC2-SPELL-SPEC
;; -----------------------------------------------------------------------------
(printf "[6/8] Verifying Phase 1 total-value, on-field supply, & SC2-SPELL-SPEC live hydration...\n")

;; 6a. Static 5.0.14 defaults for total-value & on-field supply
(for ([spec (in-list '((zergling   25  0  25  0.5)
                       (baneling   50  25 75  0.5)
                       (ravager    100 100 200 3.0)
                       (lurker-mp  150 150 300 3.0)
                       (brood-lord 300 250 550 4.0)
                       (archon     100 300 400 4.0)
                       (hatchery   275 0  275 0.0)
                       (lair       425 100 525 0.0)
                       (hive       625 250 875 0.0)
                       (spire      200 200 400 0.0)
                       (ultralisk  275 200 475 6.0)
                       (tempest    250 175 425 4.0)
                       (mothership 400 400 800 8.0)))])
  (define usym (first spec))
  (define exp-m (second spec))
  (define exp-g (third spec))
  (define exp-v (fourth spec))
  (define exp-s (fifth spec))
  (check-equal  (format "p1-static-total-pair-~a" usym) (sc2-unit-total-cost-pair usym) (cons exp-m exp-g))
  (check-equal  (format "p1-static-total-min-~a" usym)  (sc2-unit-total-min-cost usym)  exp-m)
  (check-equal  (format "p1-static-total-gas-~a" usym)  (sc2-unit-total-gas-cost usym)  exp-g)
  (check-equal  (format "p1-static-total-val-~a" usym)  (sc2-unit-total-value usym)     exp-v)
  (check-approx (format "p1-static-field-sup-~a" usym)  (sc2-unit-on-field-supply usym) exp-s))

(check-equal  "p1-unknown-total-pair-default" (sc2-unit-total-cost-pair 'nonexistent-unit (cons 100 25)) (cons 100 25))
(check-equal  "p1-unknown-total-val-default"  (sc2-unit-total-value 'nonexistent-unit 0) 0)
(check-approx "p1-unknown-field-sup-default"  (sc2-unit-on-field-supply 'nonexistent-unit 1.0) 1.0)

;; 6b. Static 5.0.14 SC2-SPELL-SPEC defaults + alias normalization
(check-approx "p1-static-storm-range"   (sc2-spell-cast-range 'psi-storm) 9.0)
(check-approx "p1-static-storm-effect"  (sc2-spell-effect-radius 'psi-storm) 1.5)
(check-approx "p1-static-storm-claim"   (sc2-spell-claim-radius 'psi-storm) 2.0)
(check-approx "p1-static-storm-energy"  (sc2-spell-energy 'psi-storm) 75.0)
(check-equal  "p1-static-storm-ttl"     (sc2-spell-claim-ttl 'psi-storm) 56)
(check-equal  "p1-static-storm-dur"     (sc2-spell-duration-frames 'psi-storm) 64)
(check-equal  "p1-static-storm-req-upg" (sc2-spell-required-upgrade 'psi-storm) 'psi-storm)
(check-approx "p1-static-emp-range"     (sc2-spell-cast-range 'emp-round) 10.0)
(check-approx "p1-static-emp-effect"    (sc2-spell-effect-radius 'emp-round) 1.5)
(check-approx "p1-static-snipe-base"    (sc2-spell-base-damage 'steady-targeting) 130.0)
(check-approx "p1-static-snipe-bonus"   (sc2-spell-bonus-damage 'steady-targeting) 40.0)
(check-equal  "p1-static-snipe-lock"    (sc2-spell-lockout-frames 'steady-targeting) 34)
(check-equal  "p1-static-nova-cd"       (sc2-spell-cooldown-frames 'purification-nova) 480)
(check-approx "p1-static-nova-effect"   (sc2-spell-effect-radius 'purification-nova) 1.5)
(check-approx "p1-static-nova-claim"    (sc2-spell-claim-radius 'purification-nova) 4.0)
(check-approx "p1-static-nova-base"     (sc2-spell-base-damage 'purification-nova) 100.0)
(check-approx "p1-static-nova-bonus"    (sc2-spell-bonus-damage 'purification-nova) 200.0)
(check-equal  "p1-static-recharge-id"   (sc2-spell-ability-id 'nexus-energy-recharge) 4126)
(check-equal  "p1-static-recharge-cd"   (sc2-spell-cooldown-frames 'nexus-energy-recharge) 1344)
(check-approx "p1-static-recharge-en"   (sc2-spell-energy 'nexus-energy-recharge) 50.0)
;; Alias checks
(check-equal  "p1-alias-psionic-storm"        (sc2-spell-ability-id 'psionic-storm) 1036)
(check-equal  "p1-alias-emp"                  (sc2-spell-ability-id 'emp) 1628)
(check-equal  "p1-alias-snipe"                (sc2-spell-lockout-frames 'snipe) 34)
(check-equal  "p1-alias-energy-recharge"      (sc2-spell-cooldown-frames 'energy-recharge) 1344)
(check-equal  "p1-alias-amorphous-armorcloud" (sc2-spell-ability-id 'amorphous-armorcloud) 4111)
(check-equal  "p1-alias-oracle-revelation"    (sc2-spell-ability-id 'oracle-revelation) 2146)
(check-equal  "p1-alias-disruptor-nova"       (sc2-spell-cooldown-frames 'disruptor-nova) 480)

;; 6c. Simulated SC2 5.0.15 ResponseData live hydration for total-value, field-supply, & spells
(define data-p1-5015-bytes
  (encode-response-data
   #:abilities
   (list
    (encode-ability-data #:id 1036 #:link-name "PsiStorm" #:available #t #:target 2 #:cast-range 8.0))
   #:units
   (list
    (encode-unit-type-data #:id 104 #:name "Drone" #:min 50 #:gas 0 #:food 1.0)
    (encode-unit-type-data #:id 92  #:name "Spire" #:min 200 #:gas 150 #:food 0.0)
    (encode-unit-type-data #:id 496 #:name "Tempest" #:min 250 #:gas 175 #:food 4.0)
    (encode-unit-type-data #:id 141 #:name "Archon" #:min 0 #:gas 0 #:food 4.0))
   #:effects
   (list
    (encode-effect-data #:id 1 #:name "PsiStormPersistent" #:radius 2.0)
    (encode-effect-data #:id 2 #:name "EMPPulse" #:radius 1.75)
    (encode-effect-data #:id 3 #:name "PurificationNova" #:radius 1.75)
    (encode-effect-data #:id 4 #:name "FungalGrowth" #:radius 2.5))))

(register-sc2-response-data! (decode-response-data-bytes data-p1-5015-bytes))

(check-equal  "p1-live-5015-spire-total-val-300"    (sc2-unit-total-value 'spire) 300)
(check-equal  "p1-live-5015-spire-total-pair"       (sc2-unit-total-cost-pair 'spire) '(150 . 150))
(check-equal  "p1-live-5015-spire-inc-150-150"      (list (sc2-min-cost 'spire) (sc2-gas-cost 'spire)) '(150 150))
(check-approx "p1-live-5015-tempest-field-sup-4.0"  (sc2-unit-on-field-supply 'tempest) 4.0)
(check-equal  "p1-live-5015-archon-total-pair"      (sc2-unit-total-cost-pair 'archon) '(100 . 300))
(check-approx "p1-live-5015-archon-field-sup-4.0"   (sc2-unit-on-field-supply 'archon) 4.0)
(check-approx "p1-live-5015-storm-cast-range-8.0"   (sc2-spell-cast-range 'psi-storm) 8.0)
(check-approx "p1-live-5015-storm-effect-rad-2.0"   (sc2-spell-effect-radius 'psi-storm) 2.0)
(check-approx "p1-live-5015-storm-claim-rad-2.0"    (sc2-spell-claim-radius 'psi-storm) 2.0)
(check-approx "p1-live-5015-alias-psionic-range"    (sc2-spell-cast-range 'psionic-storm) 8.0)
(check-approx "p1-live-5015-alias-psionic-effect"   (sc2-spell-effect-radius 'psionic-storm) 2.0)
(check-approx "p1-live-5015-emp-effect-rad-1.75"    (sc2-spell-effect-radius 'emp) 1.75)
(check-approx "p1-live-5015-emp-claim-rad-1.75"     (sc2-spell-claim-radius 'emp) 1.75)
(check-approx "p1-live-5015-nova-effect-rad-1.75"   (sc2-spell-effect-radius 'purification-nova) 1.75)
(check-approx "p1-live-5015-nova-claim-floor-4.0"   (sc2-spell-claim-radius 'purification-nova) 4.0)
(check-approx "p1-live-5015-fungal-effect-rad-2.5"  (sc2-spell-effect-radius 'fungal-growth) 2.5)
(check-approx "p1-live-5015-fungal-claim-rad-2.5"   (sc2-spell-claim-radius 'fungal-growth) 2.5)

(reset-sc2-live-response-data!)
(check-equal  "p1-reset-spire-total-val-400"        (sc2-unit-total-value 'spire) 400)
(check-approx "p1-reset-storm-cast-range-9.0"       (sc2-spell-cast-range 'psi-storm) 9.0)
(check-approx "p1-reset-storm-effect-rad-1.5"       (sc2-spell-effect-radius 'psi-storm) 1.5)
(check-approx "p1-reset-storm-claim-rad-2.0"        (sc2-spell-claim-radius 'psi-storm) 2.0)

;; -----------------------------------------------------------------------------
;; 7. Loop 61 Phase 1 (`#1603`): Static Anti-Duplication Guard (`lib/**/*.rkt`)
;; -----------------------------------------------------------------------------
(printf "[7/8] Verifying zero duplicate unit cost/supply tables across lib/**/*.rkt...\n")
(define dup-table-rx
  #px"\\(define\\s+(?:UNIT-COST-TABLE|UNIT-RESOURCE-VALUE|\\*splash-unit-supply-table\\*)\\b")
(define dup-table-hits
  (for/list ([p (in-directory repo-lib-dir)]
             #:when (and (file-exists? p)
                         (equal? (path-get-extension p) #".rkt")
                         (regexp-match? dup-table-rx (file->string p))))
    (path->string p)))
(check-equal "p1-zero-duplicate-cost-or-supply-tables-in-lib" dup-table-hits '())

;; -----------------------------------------------------------------------------
;; 8. Loop 62 Phase 2 (`#1662`): Static Architectural Boundary Guards
;; -----------------------------------------------------------------------------
(printf "[8/8] Verifying Phase 2 transport cleanup, leaf policy purity, & single spell authority...\n")
(define ws-src (file->string (build-path repo-lib-dir "sc2-protobuf-ws.rkt")))
(define rt-src (file->string (build-path repo-lib-dir "bot-runtime.rkt")))
(define macro-policy-path (build-path repo-lib-dir "plan" "macro-ability-policy.rkt"))
(define ws-forbidden-policy-hits
  (for/list ([tok (in-list '("proactive-scan-oc-limit"
                             "case-c-uphill-scan-reserve?"
                             "low-energy-protoss-caster-near-nexus?"))]
             #:when (regexp-match? (regexp-quote tok) ws-src))
    tok))
(define rt-forbidden-spell-hits
  (for/list ([tok (in-list '("l34-bc-find-yamato-tgt"
                             "l23-viper-pbomb"
                             "l27-viper-bcloud"
                             "l23-viper-abduct"
                             "last-nexus-recharge-frame"))]
             #:when (regexp-match? (regexp-quote tok) rt-src))
    tok))
(define macro-policy-bad-require-hits
  (if (file-exists? macro-policy-path)
      (regexp-match* #px"\"[^\"]*(?:sc2-protobuf-ws|bot-runtime|priority-macro-brain)\\.rkt\""
                     (file->string macro-policy-path))
      '("missing-macro-ability-policy.rkt")))
(check-equal "p2-zero-duplicated-mule-chrono-policy-in-protobuf-ws" ws-forbidden-policy-hits '())
(check-equal "p2-zero-duplicate-spell-loops-in-bot-runtime" rt-forbidden-spell-hits '())
(check-equal "p2-macro-ability-policy-pure-leaf-module" macro-policy-bad-require-hits '())

(printf "-----------------------------------------------------------------\n")
(printf "Patch-Resilience & ResponseData Checks: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(printf "=================================================================\n")
(when (> failed 0)
  (exit 1))
