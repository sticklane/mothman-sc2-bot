#lang racket/base

;; =============================================================================
;; Loop 82 Track B Unit Test Suite (`tests/l82-adept-battery-cancel-test.rkt`)
;;
;; Verifies:
;;   1. `lib/plan/wall-and-block.rkt`:
;;      - Protoss Emergency Doorway Wall-Off (`plan-protoss-emergency-walloff-and-cancel`
;;        and `assess-protoss-emergency-walloff`):
;;        * Adept Shade (`1.0-4.5t` & approaching `<= 11.0t`) and `>= 4` Speedlings
;;          at an unsealed 1-hex doorway -> immediate `shield-battery` (`100M` when
;;          CyberCore ready + powered) or `pylon` (`100M` otherwise).
;;        * Suppressed when a healthy friendly door-plug unit holds the gap alive,
;;          when `< 100M`, when doorway already covered, or for non-Protoss races.
;;        * Auto-Cancel (`cancel-building` `314`, `75%` refund = `25M` net) when:
;;          (i) Shade expires / threat clears, (ii) under-construction HP < 35%
;;          (without falsely cancelling undamaged freshly-started SC2 buildings!),
;;          or (iii) build progress >= 88% (preventing permanent self-wall-in).
;;      - Pro Offensive Natural Expansion-Block (`plan-pro-offensive-expansion-block`):
;;        * Bounded `0:45-1:45` (`1008..2352f`) scouting worker `PvZ` Pylon (`25M` net)
;;          and `TvP` Engineering Bay (`31.25M` net) on empty enemy natural with spare
;;          minerals; gated off when occupied, under attack, or outside window.
;;        * Auto-Cancel (`cancel-building` `314`) at `< 35%` HP or `>= 85%` progress
;;          while NEVER cancelling own home/natural buildings.
;;   2. `lib/plan/multitask-harass-and-proxy.rkt`:
;;      - Pro Adept Shade Micro (`plan-multi-base-adept-harass` + `step-multitask-harass-and-proxy`):
;;        * Delayed Fake-Shade Cancel: holds fake Shades to final `1.0-1.5s` (`>= 122f`
;;          = `5.45s` of `7.0s`) before cancelling against lethal defender stacks
;;          (`>= 3` Stalkers / `>= 4` Roaches / `>= 6` Marines / Cannon+Battery),
;;          including automatic stateful `shade-birth-table` tracking in `step-*`.
;;        * High-Commit Enemy Main Minerals (`~75%` pro commit): never cancels Shade into
;;          Enemy Main Minerals with `<= 2` combat defenders even with 16+ workers present.
;;        * Coordinated 1-Volley Worker Focus-Fire: `2` Adepts focus the EXACT SAME
;;          Probe/Drone (`44 >= 40` HP), `3` Adepts focus the EXACT SAME SCV (`66 >= 45` HP),
;;          and `4` Adepts split cleanly into `2+2` parallel 1-volley kill pairs.
;;        * Retreat-Out Safety Shades (`18.2%` pro Shades, `87.1%` completion):
;;          pressured Adepts (`HP < 60%` or outnumbered inside enemy base) cast
;;          `adept-phase-shift` (`2544`) `16-22t` toward safe home ground, never cancel
;;          active retreat Shades, and keep shooting workers while waiting to teleport out.
;;        * Cross-Base Dual-Prong Fake-Shade (`Main <-> Nat`): physical Adepts at one
;;          enemy mineral line project `adept-phase-shift` (`2544`) to the opposite
;;          mineral line (and Main->Nat fake Shades are NOT misclassified as retreats!).
;; =============================================================================

(require racket/list
         racket/math
         "../lib/plan/wall-and-block.rkt"
         "../lib/plan/multitask-harass-and-proxy.rkt"
         "../lib/plan/situational-counter.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (dist2 a-x a-y b-x b-y)
  (sqrt (+ (sqr (- a-x b-x)) (sqr (- a-y b-y)))))

(define (find-cmd cmds head)
  (findf (lambda (c) (and (pair? c) (eq? (car c) head))) cmds))

(define (find-dirs-by-ability dirs ab)
  (filter (lambda (d) (eq? (harass-directive-ability d) ab)) dirs))

(define (find-dirs-by-action dirs act)
  (filter (lambda (d) (eq? (harass-directive-action d) act)) dirs))

;; =============================================================================
;; PART 1: Protoss Emergency Doorway Wall-Off + Auto-Cancel (`314`)
;; =============================================================================

(define door-x 58.0)
(define door-y 58.0)

(define base-protoss-obs
  (hasheq 'our-race 'Protoss
          'enemy-race 'Protoss
          'frame 2600
          'minerals 150.0
          'base-x 32.0 'base-y 32.0
          'natural-x 50.0 'natural-y 50.0
          'enemy-x 132.0 'enemy-y 132.0
          'door-pos (cons door-x door-y)
          'ally-units (list (hasheq 'id 101 'type 'probe 'x 52.0 'y 52.0 'hp 20.0 'max-hp 20.0 'shield 20.0 'shield-max 20.0))
          'ally-buildings (list (hasheq 'id 201 'type 'pylon 'x 54.0 'y 55.0 'build-progress 1.0)
                                (hasheq 'id 202 'type 'cybernetics-core 'x 56.0 'y 55.0 'build-progress 1.0)
                                (hasheq 'id 203 'type 'gateway 'x 56.0 'y 60.0 'build-progress 1.0))
          'enemy-units '()))

;; T1.1: Enemy Adept Shade within 1.0-4.5t of 1-hex doorway + CyberCore ready + powered -> Shield Battery!
(let* ([shade (hasheq 'id 901 'type 'adept-phase-shift 'x 60.5 'y 60.0)]
       [obs (hash-set base-protoss-obs 'enemy-units (list shade))]
       [asm (assess-protoss-emergency-walloff obs)]
       [cmds (plan-protoss-emergency-walloff-and-cancel obs)])
  (check! (eq? (EmergencyWalloffAssessment-threat-kind asm) 'adept-shade)
          "T1.1a: Adept Shade within 4.5t classified as 'adept-shade")
  (check! (eq? (EmergencyWalloffAssessment-chosen-structure asm) 'shield-battery)
          "T1.1b: Ready CyberCore + Pylon power selects 'shield-battery")
  (check! (equal? cmds (list (list 'build 'shield-battery door-x door-y)))
          (format "T1.1c: Emits (build shield-battery ~a ~a), got ~a" door-x door-y cmds)))

;; T1.2: Enemy Adept Shade at door WITHOUT ready CyberCore (or unpowered) -> Pylon!
(let* ([shade (hasheq 'id 901 'type 'adept-phase-shift 'x 60.0 'y 60.0)]
       [obs-no-cyber (hash-set* base-protoss-obs
                                'ally-buildings (list (hasheq 'id 201 'type 'pylon 'x 54.0 'y 55.0 'build-progress 1.0)
                                                      (hasheq 'id 202 'type 'cybernetics-core 'x 56.0 'y 55.0 'build-progress 0.65))
                                'enemy-units (list shade))]
       [obs-unpowered (hash-set* base-protoss-obs
                                 'ally-buildings (list (hasheq 'id 201 'type 'pylon 'x 40.0 'y 40.0 'build-progress 1.0)
                                                       (hasheq 'id 202 'type 'cybernetics-core 'x 42.0 'y 40.0 'build-progress 1.0))
                                 'enemy-units (list shade))]
       [cmds-no-cyber (plan-protoss-emergency-walloff-and-cancel obs-no-cyber)]
       [cmds-unpowered (plan-protoss-emergency-walloff-and-cancel obs-unpowered)])
  (check! (equal? cmds-no-cyber (list (list 'build 'pylon door-x door-y)))
          (format "T1.2a: Incomplete CyberCore falls back to (build pylon ...), got ~a" cmds-no-cyber))
  (check! (equal? cmds-unpowered (list (list 'build 'pylon door-x door-y)))
          (format "T1.2b: Unpowered doorway falls back to (build pylon ...), got ~a" cmds-unpowered)))

;; T1.3: Approaching Shade (8.5t away) heading INTO door triggers; Shade running AWAY does not!
(let* ([shade-in (hasheq 'id 902 'type 'adept-phase-shift 'x 64.0 'y 64.0 'vx -3.0 'vy -3.0)]
       [shade-out (hasheq 'id 903 'type 'adept-phase-shift 'x 64.0 'y 64.0 'vx 3.0 'vy 3.0)]
       [cmds-in (plan-protoss-emergency-walloff-and-cancel
                 (hash-set base-protoss-obs 'enemy-units (list shade-in)))]
       [cmds-out (plan-protoss-emergency-walloff-and-cancel
                  (hash-set base-protoss-obs 'enemy-units (list shade-out)))])
  (check! (and (pair? cmds-in) (eq? (caar cmds-in) 'build))
          (format "T1.3a: Approaching Shade at 8.5t heading into door triggers wall-off, got ~a" cmds-in))
  (check! (null? cmds-out)
          (format "T1.3b: Retreating Shade at 8.5t heading away does NOT trigger wall-off, got ~a" cmds-out)))

;; T1.4 & T1.5: >= 4 Speedlings rushing unsealed doorway vs Zealot holding position alive!
(let* ([lings-4 (for/list ([i (in-range 4)])
                  (hasheq 'id (+ 910 i) 'type 'zergling 'x (+ 63.0 (* 0.5 i)) 'y 63.0))]
       [lings-3 (take lings-4 3)]
       [zealot-hold (hasheq 'id 102 'type 'zealot 'x 58.2 'y 58.1
                            'hp 100.0 'max-hp 100.0 'shield 50.0 'shield-max 50.0
                            'order 'hold-position)]
       [cmds-unsealed (plan-protoss-emergency-walloff-and-cancel
                       (hash-set base-protoss-obs 'enemy-units lings-4))]
       [cmds-sealed (plan-protoss-emergency-walloff-and-cancel
                     (hash-set* base-protoss-obs
                                'ally-units (cons zealot-hold (hash-ref base-protoss-obs 'ally-units))
                                'enemy-units lings-4))]
       [cmds-only-3 (plan-protoss-emergency-walloff-and-cancel
                     (hash-set base-protoss-obs 'enemy-units lings-3))])
  (check! (equal? cmds-unsealed (list (list 'build 'shield-battery door-x door-y)))
          (format "T1.4: >= 4 Speedlings at unsealed door emits emergency wall-off, got ~a" cmds-unsealed))
  (check! (null? cmds-sealed)
          (format "T1.5: Healthy Zealot holding doorway suppresses emergency building, got ~a" cmds-sealed))
  (check! (null? cmds-only-3)
          (format "T1.6a: Only 3 Speedlings (< 4) does not trigger emergency wall-off, got ~a" cmds-only-3)))

;; T1.6b: Guards (< 100M, non-Protoss, already covered)
(let* ([shade (hasheq 'id 901 'type 'adept-phase-shift 'x 60.0 'y 60.0)]
       [cmds-low-min (plan-protoss-emergency-walloff-and-cancel
                      (hash-set* base-protoss-obs 'minerals 85.0 'enemy-units (list shade)))]
       [cmds-terran (plan-protoss-emergency-walloff-and-cancel
                     (hash-set* base-protoss-obs 'our-race 'Terran 'enemy-units (list shade)))]
       [cmds-covered (plan-protoss-emergency-walloff-and-cancel
                      (hash-set* base-protoss-obs
                                 'ally-buildings (cons (hasheq 'id 250 'type 'gateway 'x 58.0 'y 58.0 'build-progress 1.0)
                                                       (hash-ref base-protoss-obs 'ally-buildings))
                                 'enemy-units (list shade)))])
  (check! (null? cmds-low-min) "T1.6b: Minerals < 100 suppresses emergency build")
  (check! (null? cmds-terran) "T1.6c: Non-Protoss race returns empty")
  (check! (null? cmds-covered) "T1.6d: Doorway already covered by building suppresses duplicate build"))

;; T1.7: Emergency Wall-Off Auto-Cancel (`cancel-building` 314 -> 25M net cost!)
(let* ([shade (hasheq 'id 901 'type 'adept-phase-shift 'x 60.0 'y 60.0)]
       ;; (a) Threat cleared (Shade expired/cancelled, 0 lings) while Battery at 45% progress
       [plug-healthy (hasheq 'id 501 'type 'shield-battery 'x 58.0 'y 58.0
                             'build-progress 0.45 'hp 76.0 'max-hp 150.0 'shield 76.0 'max-shield 150.0)]
       [cmds-cleared (plan-protoss-emergency-walloff-and-cancel
                      (hash-set* base-protoss-obs
                                 'ally-buildings (cons plug-healthy (hash-ref base-protoss-obs 'ally-buildings))
                                 'enemy-units '()))]
       ;; (b) Healthy plug while Shade is STILL breaching -> HOLD (no cancel, no duplicate build!)
       [cmds-hold (plan-protoss-emergency-walloff-and-cancel
                   (hash-set* base-protoss-obs
                              'ally-buildings (cons plug-healthy (hash-ref base-protoss-obs 'ally-buildings))
                              'enemy-units (list shade)))]
       ;; (c) Brand-new undamaged SC2 Pylon at 10% build progress (`expected-vit = 0.19`) while Shade active -> HOLD!
       [plug-fresh (hasheq 'id 502 'type 'pylon 'x 58.0 'y 58.0
                           'build-progress 0.10 'hp 38.0 'max-hp 200.0 'shield 38.0 'max-shield 200.0)]
       [cmds-fresh (plan-protoss-emergency-walloff-and-cancel
                    (hash-set* base-protoss-obs
                               'ally-buildings (cons plug-fresh (hash-ref base-protoss-obs 'ally-buildings))
                               'enemy-units (list shade)))]
       ;; (d) Damaged plug drops < 35% HP while under attack -> CANCEL!
       [plug-low-hp-pct (hasheq 'id 503 'type 'shield-battery 'x 58.0 'y 58.0
                                'build-progress 0.50 'hp-pct 0.30)]
       [plug-low-hp-raw (hasheq 'id 504 'type 'pylon 'x 58.0 'y 58.0
                                'build-progress 0.50 'hp 55.0 'max-hp 200.0 'shield 0.0 'max-shield 200.0)]
       [cmds-low-pct (plan-protoss-emergency-walloff-and-cancel
                      (hash-set* base-protoss-obs
                                 'ally-buildings (cons plug-low-hp-pct (hash-ref base-protoss-obs 'ally-buildings))
                                 'enemy-units (list shade)))]
       [cmds-low-raw (plan-protoss-emergency-walloff-and-cancel
                      (hash-set* base-protoss-obs
                                 'ally-buildings (cons plug-low-hp-raw (hash-ref base-protoss-obs 'ally-buildings))
                                 'enemy-units (list shade)))]
       ;; (e) Nearly complete (`build-progress >= 0.88`) -> CANCEL to avoid permanent self-wall-in!
       [plug-near-done (hasheq 'id 505 'type 'pylon 'x 58.0 'y 58.0
                               'build-progress 0.89 'hp 180.0 'max-hp 200.0 'shield 180.0 'max-shield 200.0)]
       [cmds-near-done (plan-protoss-emergency-walloff-and-cancel
                        (hash-set* base-protoss-obs
                                   'ally-buildings (cons plug-near-done (hash-ref base-protoss-obs 'ally-buildings))
                                   'enemy-units (list shade)))]
       ;; (f) Explicitly tagged `emergency-plug-id` slightly offset (`2.8t`) -> CANCEL on threat clear!
       [plug-tagged (hasheq 'id 506 'type 'pylon 'x 60.8 'y 58.0 'build-progress 0.40 'hp-pct 0.90)]
       [cmds-tagged (plan-protoss-emergency-walloff-and-cancel
                     (hash-set* base-protoss-obs
                                'emergency-plug-id 506
                                'ally-buildings (cons plug-tagged (hash-ref base-protoss-obs 'ally-buildings))
                                'enemy-units '()))]
       ;; (g) Completed doorway building (`build-progress = 1.0`) -> NEVER cancel
       [plug-done (hasheq 'id 507 'type 'pylon 'x 58.0 'y 58.0 'build-progress 1.0 'hp-pct 0.20)]
       [cmds-done (plan-protoss-emergency-walloff-and-cancel
                   (hash-set* base-protoss-obs
                              'ally-buildings (cons plug-done (hash-ref base-protoss-obs 'ally-buildings))
                              'enemy-units '()))])
  (check! (equal? cmds-cleared '((cancel-building 501)))
          (format "T1.7a: Shade expired / threat cleared cancels emergency plug 501, got ~a" cmds-cleared))
  (check! (null? cmds-hold)
          (format "T1.7b: Healthy plug holds while Shade is still active, got ~a" cmds-hold))
  (check! (null? cmds-fresh)
          (format "T1.7c: Fresh undamaged SC2 building (prog=0.10, vit=0.19) MUST NOT falsely cancel, got ~a" cmds-fresh))
  (check! (equal? cmds-low-pct '((cancel-building 503)))
          (format "T1.7d1: Explicit hp-pct < 0.35 cancels plug 503, got ~a" cmds-low-pct))
  (check! (equal? cmds-low-raw '((cancel-building 504)))
          (format "T1.7d2: Raw SC2 vitality < 35% of expected cancels plug 504, got ~a" cmds-low-raw))
  (check! (equal? cmds-near-done '((cancel-building 505)))
          (format "T1.7e: build-progress >= 0.88 cancels plug 505 to prevent self-wall-in, got ~a" cmds-near-done))
  (check! (equal? cmds-tagged '((cancel-building 506)))
          (format "T1.7f: Tagged emergency-plug-id 506 cancels cleanly, got ~a" cmds-tagged))
  (check! (null? cmds-done)
          (format "T1.7g: Completed structure (prog=1.0) never emits cancel-building, got ~a" cmds-done)))

;; =============================================================================
;; PART 2: Pro Offensive Natural Expansion-Block + Auto-Cancel (`25M`/`31.25M`)
;; =============================================================================

(define enemy-nat-x 116.0)
(define enemy-nat-y 116.0)

(define base-pvz-block-obs
  (hasheq 'our-race 'Protoss
          'enemy-race 'Zerg
          'frame 1456 ;; 1:05 (inside 0:45-1:45 = 1008..2352)
          'minerals 140.0
          'base-x 32.0 'base-y 32.0
          'enemy-x 132.0 'enemy-y 132.0
          'enemy-natural-x enemy-nat-x 'enemy-natural-y enemy-nat-y
          'ally-units (list (hasheq 'id 301 'type 'probe 'x 113.0 'y 114.0))
          'ally-buildings '()
          'enemy-buildings (list (hasheq 'id 801 'type 'hatchery 'x 132.0 'y 132.0 'build-progress 1.0))))

(define base-tvp-block-obs
  (hasheq 'our-race 'Terran
          'enemy-race 'Protoss
          'frame 1680 ;; 1:15 (inside 0:45-1:45)
          'minerals 165.0
          'base-x 32.0 'base-y 32.0
          'enemy-x 132.0 'enemy-y 132.0
          'enemy-natural-x enemy-nat-x 'enemy-natural-y enemy-nat-y
          'ally-units (list (hasheq 'id 302 'type 'scv 'x 114.0 'y 115.0))
          'ally-buildings '()
          'enemy-buildings (list (hasheq 'id 802 'type 'nexus 'x 132.0 'y 132.0 'build-progress 1.0))))

;; T2.1 & T2.2: PvZ Pylon & TvP Engineering Bay placement on empty enemy natural
(let ([pvz-cmds (plan-pro-offensive-expansion-block base-pvz-block-obs)]
      [tvp-cmds (plan-pro-offensive-expansion-block base-tvp-block-obs)])
  (check! (equal? pvz-cmds (list (list 'build 'pylon enemy-nat-x enemy-nat-y)))
          (format "T2.1: PvZ empty enemy nat emits (build pylon ~a ~a), got ~a" enemy-nat-x enemy-nat-y pvz-cmds))
  (check! (equal? tvp-cmds (list (list 'build 'engineering-bay enemy-nat-x enemy-nat-y)))
          (format "T2.2: TvP empty enemy nat emits (build engineering-bay ~a ~a), got ~a" enemy-nat-x enemy-nat-y tvp-cmds)))

;; T2.3: Timing window, spare minerals, occupied natural, under-attack, disabled, and scout-distance gates
(check! (null? (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'frame 900)))
        "T2.3a: Frame < 1008 (< 0:45) suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'frame 2400)))
        "T2.3b: Frame > 2352 (> 1:45) suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'minerals 110.0)))
        "T2.3c: PvZ minerals < 125 spare-floor suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block (hash-set base-tvp-block-obs 'minerals 135.0)))
        "T2.3d: TvP minerals < 150 spare-floor suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block
                (hash-set base-pvz-block-obs 'enemy-buildings
                          (list (hasheq 'id 803 'type 'hatchery 'x enemy-nat-x 'y enemy-nat-y 'build-progress 0.2)))))
        "T2.3e: Occupied enemy natural suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'under-attack? #t)))
        "T2.3f: under-attack? = #t suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'enabled? #f)))
        "T2.3g: enabled? = #f suppresses offensive block")
(check! (null? (plan-pro-offensive-expansion-block
                (hash-set base-pvz-block-obs 'ally-units (list (hasheq 'id 301 'type 'probe 'x 35.0 'y 35.0)))))
        "T2.3h: No forward scouting worker near enemy natural suppresses offensive block")

;; T2.4: Auto-cancel (`cancel-building` 314) at < 35% HP or >= 85% progress; NEVER cancels home Pylon!
(let* ([pvz-low-hp (hasheq 'id 601 'type 'pylon 'x enemy-nat-x 'y enemy-nat-y
                           'build-progress 0.50 'hp-pct 0.30)]
       [tvp-near-done (hasheq 'id 602 'type 'engineering-bay 'x enemy-nat-x 'y enemy-nat-y
                              'build-progress 0.86 'hp 720.0 'max-hp 850.0)]
       [pvz-fresh-ok (hasheq 'id 603 'type 'pylon 'x enemy-nat-x 'y enemy-nat-y
                             'build-progress 0.20 'hp 56.0 'max-hp 200.0 'shield 56.0 'max-shield 200.0)]
       [own-home-pylon (hasheq 'id 604 'type 'pylon 'x 36.0 'y 36.0
                               'build-progress 0.90 'hp-pct 0.20)]
       [c1 (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'ally-buildings (list pvz-low-hp)))]
       [c2 (plan-pro-offensive-expansion-block (hash-set* base-tvp-block-obs 'frame 2650 'ally-buildings (list tvp-near-done)))]
       [c3 (plan-pro-offensive-expansion-block (hash-set base-pvz-block-obs 'ally-buildings (list pvz-fresh-ok)))]
       [c4 (plan-pro-offensive-expansion-block (hash-set* base-pvz-block-obs 'frame 2650 'ally-buildings (list own-home-pylon)))])
  (check! (equal? c1 '((cancel-building 601)))
          (format "T2.4a: PvZ Pylon block < 35% HP emits (cancel-building 601), got ~a" c1))
  (check! (equal? c2 '((cancel-building 602)))
          (format "T2.4b: TvP Ebay block >= 85% progress emits (cancel-building 602) even post-window, got ~a" c2))
  (check! (null? c3)
          (format "T2.4c: Healthy freshly-warped PvZ Pylon block does NOT falsely cancel, got ~a" c3))
  (check! (null? c4)
          (format "T2.4d: Own home-base Pylon is NEVER cancelled, got ~a" c4)))

;; =============================================================================
;; PART 3: Pro Adept Shade Micro (`plan-multi-base-adept-harass` + `step-*`)
;; =============================================================================

(define home-x 32.0)
(define home-y 32.0)
(define enemy-main '(132.0 . 132.0))
(define enemy-nat '(112.0 . 116.0))
(define two-base-targets (list enemy-main enemy-nat))

(define (mk-adept tag x y #:hp [hp 70.0] #:shield [sh 70.0]
                  #:ready? [ready? #t] #:active? [active? #f])
  (hasheq 'id tag 'type 'adept 'x x 'y y
          'hp hp 'max-hp 70.0 'shield sh 'max-shield 70.0
          'phase-shift-ready? ready? 'phase-shift-active? active?))

(define (mk-shade tag x y #:owner [owner #f] #:born [born #f] #:age [age #f] #:purpose [purpose #f])
  (define h0 (hasheq 'id tag 'type 'adept-phase-shift 'x x 'y y 'hp 1.0 'max-hp 1.0))
  (define h1 (if owner (hash-set h0 'owner-tag owner) h0))
  (define h2 (if born (hash-set h1 'born-frame born) h1))
  (define h3 (if age (hash-set h2 'age-frames age) h2))
  (if purpose (hash-set h3 'shade-purpose purpose) h3))

;; T3.1a: Hold Fake Shades until >= 122f (5.45s of 7.0s) vs lethal defender stacks, then CANCEL!
(let* ([adepts (list (mk-adept 1001 130.0 130.0 #:ready? #f #:active? #t)
                     (mk-adept 1002 131.0 130.0 #:ready? #f #:active? #t))]
       [stalkers-3 (list (hasheq 'id 2001 'type 'stalker 'x 112.0 'y 116.0 'hp 80.0 'max-hp 80.0 'shield 80.0 'max-shield 80.0)
                         (hasheq 'id 2002 'type 'stalker 'x 113.0 'y 116.0 'hp 80.0 'max-hp 80.0 'shield 80.0 'max-shield 80.0)
                         (hasheq 'id 2003 'type 'stalker 'x 111.0 'y 117.0 'hp 80.0 'max-hp 80.0 'shield 80.0 'max-shield 80.0))]
       [roaches-4 (for/list ([i (in-range 4)])
                    (hasheq 'id (+ 2010 i) 'type 'roach 'x (+ 111.0 i) 'y 116.0 'hp 145.0 'max-hp 145.0))]
       [marines-6 (for/list ([i (in-range 6)])
                    (hasheq 'id (+ 2020 i) 'type 'marine 'x (+ 110.0 (* 0.5 i)) 'y 116.0 'hp 45.0 'max-hp 45.0))]
       [cannon-bat (list (hasheq 'id 2030 'type 'photon-cannon 'x 112.0 'y 116.0 'hp 150.0 'max-hp 150.0 'shield 150.0 'max-shield 150.0)
                         (hasheq 'id 2031 'type 'shield-battery 'x 113.0 'y 116.0 'hp 150.0 'max-hp 150.0 'shield 150.0 'max-shield 150.0))]
       [shades-early (list (mk-shade 1101 112.0 116.0 #:owner 1001 #:age 45)
                           (mk-shade 1102 112.5 116.0 #:owner 1002 #:age 110))]
       [shades-late (list (mk-shade 1101 112.0 116.0 #:owner 1001 #:age 125) ;; 5.58s
                          (mk-shade 1102 112.5 116.0 #:owner 1002 #:age 128))] ;; 5.71s
       [d-early (plan-multi-base-adept-harass (append adepts shades-early) stalkers-3
                                              #:home-x home-x #:home-y home-y
                                              #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                              #:enemy-targets two-base-targets)]
       [d-stalkers (plan-multi-base-adept-harass (append adepts shades-late) stalkers-3
                                                 #:home-x home-x #:home-y home-y
                                                 #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                 #:enemy-targets two-base-targets)]
       [d-roaches (plan-multi-base-adept-harass (append adepts shades-late) roaches-4
                                                #:home-x home-x #:home-y home-y
                                                #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                #:enemy-targets two-base-targets)]
       [d-marines (plan-multi-base-adept-harass (append adepts shades-late) marines-6
                                                #:home-x home-x #:home-y home-y
                                                #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                #:enemy-targets two-base-targets)]
       [d-canbat (plan-multi-base-adept-harass (append adepts shades-late) cannon-bat
                                               #:home-x home-x #:home-y home-y
                                               #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                               #:enemy-targets two-base-targets)])
  (check! (null? (find-dirs-by-ability d-early 'cancel-adept-phase-shift))
          (format "T3.1a1: Fake Shade at 2.0s/4.9s (< 122f) MUST NOT instant-cancel, got ~a" d-early))
  (check! (= (length (find-dirs-by-ability d-stalkers 'cancel-adept-phase-shift)) 2)
          "T3.1a2: Fake Shade at 5.6s vs >= 3 Stalkers emits cancel-adept-phase-shift for both Adepts")
  (check! (= (length (find-dirs-by-ability d-roaches 'cancel-adept-phase-shift)) 2)
          "T3.1a3: Fake Shade at 5.6s vs >= 4 Roaches emits cancel-adept-phase-shift")
  (check! (= (length (find-dirs-by-ability d-marines 'cancel-adept-phase-shift)) 2)
          "T3.1a4: Fake Shade at 5.6s vs >= 6 Marines emits cancel-adept-phase-shift")
  (check! (= (length (find-dirs-by-ability d-canbat 'cancel-adept-phase-shift)) 2)
          "T3.1a5: Fake Shade at 5.6s vs Cannon+Battery emits cancel-adept-phase-shift"))

;; T3.1b: `step-multitask-harass-and-proxy` stateful `shade-birth-table` tracks real SC2 shades
;;        WITHOUT needing `'owner-tag` or `'born-frame`!
(let* ([_ (reset-adept-shade-birth-table!)]
       [allies (list (mk-adept 1001 130.0 130.0 #:ready? #f #:active? #t)
                     (mk-adept 1002 131.0 130.0 #:ready? #f #:active? #t)
                     ;; Real SC2 shades have NO owner-tag and NO born-frame!
                     (mk-shade 1901 112.0 116.0)
                     (mk-shade 1902 112.5 116.0))]
       [enemies (list (hasheq 'id 2100 'type 'hatchery 'x 132.0 'y 132.0 'hp 1500.0 'max-hp 1500.0)
                      (hasheq 'id 2101 'type 'hatchery 'x 112.0 'y 116.0 'hp 1500.0 'max-hp 1500.0)
                      (hasheq 'id 2110 'type 'roach 'x 112.0 'y 116.0 'hp 145.0 'max-hp 145.0)
                      (hasheq 'id 2111 'type 'roach 'x 113.0 'y 116.0 'hp 145.0 'max-hp 145.0)
                      (hasheq 'id 2112 'type 'roach 'x 111.0 'y 116.0 'hp 145.0 'max-hp 145.0)
                      (hasheq 'id 2113 'type 'roach 'x 112.0 'y 117.0 'hp 145.0 'max-hp 145.0))]
       [s-f0 (step-multitask-harass-and-proxy 'Protoss 'Zerg allies enemies
                                              #:current-frame 3000 #:home-x home-x #:home-y home-y
                                              #:enemy-main-x 132.0 #:enemy-main-y 132.0)]
       [s-f90 (step-multitask-harass-and-proxy 'Protoss 'Zerg allies enemies
                                               #:current-frame 3090 #:home-x home-x #:home-y home-y
                                               #:enemy-main-x 132.0 #:enemy-main-y 132.0)]
       [s-f125 (step-multitask-harass-and-proxy 'Protoss 'Zerg allies enemies
                                                #:current-frame 3125 #:home-x home-x #:home-y home-y
                                                #:enemy-main-x 132.0 #:enemy-main-y 132.0)]
       [cancels-f0 (filter (lambda (c) (and (pair? c) (eq? (car c) 'cast-spell) (eq? (caddr c) 'cancel-adept-phase-shift))) s-f0)]
       [cancels-f90 (filter (lambda (c) (and (pair? c) (eq? (car c) 'cast-spell) (eq? (caddr c) 'cancel-adept-phase-shift))) s-f90)]
       [cancels-f125 (filter (lambda (c) (and (pair? c) (eq? (car c) 'cast-spell) (eq? (caddr c) 'cancel-adept-phase-shift))) s-f125)])
  (check! (null? cancels-f0) "T3.1b1: step-* holds newly spawned Shade at frame 3000 (0.0s)")
  (check! (null? cancels-f90) "T3.1b2: step-* holds fake Shade at frame 3090 (4.0s < 5.45s)")
  (check! (= (length cancels-f125) 2)
          (format "T3.1b3: step-* cancels both fake Shades at frame 3125 (5.58s >= 5.45s), got ~a" cancels-f125)))

;; T3.2a: Commit inside Enemy Main Minerals (`<= 2` defenders + 16 workers) even at 5.8s!
(let* ([adepts (list (mk-adept 1001 112.0 116.0 #:ready? #f #:active? #t)
                     (mk-adept 1002 113.0 116.0 #:ready? #f #:active? #t))]
       [shades-main (list (mk-shade 1201 132.0 132.0 #:owner 1001 #:age 130)
                          (mk-shade 1202 132.5 132.0 #:owner 1002 #:age 130))]
       [drones-16 (for/list ([i (in-range 16)])
                    (hasheq 'id (+ 3000 i) 'type 'drone 'x (+ 131.0 (* 0.25 (modulo i 4)))
                            'y (+ 131.0 (* 0.25 (quotient i 4))) 'hp 40.0 'max-hp 40.0))]
       [two-defenders (list (hasheq 'id 3101 'type 'queen 'x 133.0 'y 132.0 'hp 175.0 'max-hp 175.0)
                            (hasheq 'id 3102 'type 'zergling 'x 131.0 'y 133.0 'hp 35.0 'max-hp 35.0))]
       [dirs (plan-multi-base-adept-harass (append adepts shades-main) (append drones-16 two-defenders)
                                           #:home-x home-x #:home-y home-y
                                           #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                           #:enemy-targets two-base-targets)])
  (check! (null? (find-dirs-by-ability dirs 'cancel-adept-phase-shift))
          (format "T3.2a: Shade into Enemy Main with 16 Drones + <= 2 defenders MUST COMMIT (no cancel), got ~a" dirs)))

;; T3.2b: 2-Adept (44 >= 40 Drone/Probe) & 3-Adept (66 >= 45 SCV) 1-Volley Worker Focus-Fire!
(let* ([adepts-2 (list (mk-adept 1001 131.0 131.0 #:ready? #f)
                       (mk-adept 1002 131.5 131.0 #:ready? #f))]
       [probes (list (hasheq 'id 4001 'type 'probe 'x 132.0 'y 132.0 'hp 20.0 'max-hp 20.0 'shield 20.0 'max-shield 20.0)
                     (hasheq 'id 4002 'type 'probe 'x 132.5 'y 132.0 'hp 20.0 'max-hp 20.0 'shield 10.0 'max-shield 20.0)
                     (hasheq 'id 4003 'type 'probe 'x 133.0 'y 132.0 'hp 20.0 'max-hp 20.0 'shield 20.0 'max-shield 20.0))]
       [d-2p (plan-multi-base-adept-harass adepts-2 probes
                                           #:home-x home-x #:home-y home-y
                                           #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                           #:enemy-targets two-base-targets)]
       [ff-2p (find-dirs-by-action d-2p 'focus-fire)]
       [tgts-2p (map harass-directive-target-tag ff-2p)]
       ;; 3 Adepts vs SCVs -> ALL 3 focus the EXACT SAME SCV tag (66 >= 45 HP 1-volley kill!)
       [adepts-3 (list (mk-adept 1011 131.0 131.0 #:ready? #f)
                       (mk-adept 1012 131.5 131.0 #:ready? #f)
                       (mk-adept 1013 132.0 131.0 #:ready? #f))]
       [scvs (list (hasheq 'id 4101 'type 'scv 'x 132.0 'y 132.5 'hp 45.0 'max-hp 45.0)
                   (hasheq 'id 4102 'type 'scv 'x 133.0 'y 132.5 'hp 45.0 'max-hp 45.0)
                   (hasheq 'id 4103 'type 'scv 'x 134.0 'y 132.5 'hp 45.0 'max-hp 45.0))]
       [d-3s (plan-multi-base-adept-harass adepts-3 scvs
                                           #:home-x home-x #:home-y home-y
                                           #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                           #:enemy-targets two-base-targets)]
       [ff-3s (find-dirs-by-action d-3s 'focus-fire)]
       [tgts-3s (map harass-directive-target-tag ff-3s)]
       ;; 4 Adepts vs 4 Probes -> splits cleanly into 2 + 2 parallel 1-volley kill pairs
       [adepts-4 (list (mk-adept 1021 131.0 131.0 #:ready? #f)
                       (mk-adept 1022 131.5 131.0 #:ready? #f)
                       (mk-adept 1023 132.0 131.0 #:ready? #f)
                       (mk-adept 1024 132.5 131.0 #:ready? #f))]
       [d-4p (plan-multi-base-adept-harass adepts-4 probes
                                           #:home-x home-x #:home-y home-y
                                           #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                           #:enemy-targets two-base-targets)]
       [tgts-4p (map harass-directive-target-tag (find-dirs-by-action d-4p 'focus-fire))])
  (check! (and (= (length tgts-2p) 2) (= (car tgts-2p) 4002) (= (cadr tgts-2p) 4002))
          (format "T3.2b1: 2 Adepts both 1-volley focus wounded Probe 4002, got ~a" tgts-2p))
  (check! (and (= (length tgts-3s) 3) (andmap (lambda (t) (= t (car tgts-3s))) tgts-3s))
          (format "T3.2b2: 3 Adepts all 1-volley focus the SAME SCV tag, got ~a" tgts-3s))
  (check! (and (= (length tgts-4p) 4)
               (= (list-ref tgts-4p 0) (list-ref tgts-4p 1))
               (= (list-ref tgts-4p 2) (list-ref tgts-4p 3))
               (not (= (list-ref tgts-4p 0) (list-ref tgts-4p 2))))
          (format "T3.2b3: 4 Adepts split cleanly into 2+2 parallel 1-volley Probe pairs, got ~a" tgts-4p)))

;; T3.3: Retreat-Out Safety Shades (`HP < 60%` or outnumbered inside enemy base)
(let* (;; (a) Wounded Adept (50% EHP < 60%) inside Enemy Main casts Retreat-Out Shade toward home!
       [wounded-adept (mk-adept 1051 131.0 131.0 #:hp 70.0 #:shield 0.0 #:ready? #t)] ;; 70/140 = 0.50 < 0.60
       [d-retreat-hp (plan-multi-base-adept-harass (list wounded-adept)
                                                   (list (hasheq 'id 4201 'type 'probe 'x 132.0 'y 132.0 'hp 20.0 'max-hp 20.0 'shield 20.0 'max-shield 20.0))
                                                   #:home-x home-x #:home-y home-y
                                                   #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                   #:enemy-targets two-base-targets)]
       [sh-hp (car (find-dirs-by-ability d-retreat-hp 'adept-phase-shift))]
       ;; (b) Outnumbered full-HP Adepts (2 Adepts vs 3 closing Stalkers within 9.5t) cast Retreat-Out Shade!
       [adepts-outnum (list (mk-adept 1052 112.0 116.0 #:ready? #t)
                            (mk-adept 1053 113.0 116.0 #:ready? #t))]
       [closing-stalkers (list (hasheq 'id 4210 'type 'stalker 'x 116.0 'y 116.0 'hp 80.0 'max-hp 80.0 'shield 80.0 'max-shield 80.0)
                               (hasheq 'id 4211 'type 'stalker 'x 116.0 'y 117.0 'hp 80.0 'max-hp 80.0 'shield 80.0 'max-shield 80.0)
                               (hasheq 'id 4212 'type 'stalker 'x 116.0 'y 115.0 'hp 80.0 'max-hp 80.0 'shield 80.0 'max-shield 80.0))]
       [d-retreat-outnum (plan-multi-base-adept-harass adepts-outnum closing-stalkers
                                                       #:home-x home-x #:home-y home-y
                                                       #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                       #:enemy-targets two-base-targets)]
       [retreat-dirs-outnum (filter (lambda (d) (eq? (harass-directive-reason d) 'adept-retreat-out-safety-shade))
                                    d-retreat-outnum)]
       ;; (c) Active Retreat-Out Shade traveling toward safe home ground (`98, 102`, > 10.5t from both bases):
       ;;     MUST NOT cancel even at 5.9s (132f) AND physical Adepts keep firing worker volleys!
       [retreat-shades (list (mk-shade 1301 98.0 102.0 #:owner 1052 #:age 132)
                             (mk-shade 1302 98.5 102.0 #:owner 1053 #:age 132))]
       [d-retreat-active (plan-multi-base-adept-harass
                          (append (list (mk-adept 1052 112.0 116.0 #:ready? #f #:active? #t)
                                        (mk-adept 1053 113.0 116.0 #:ready? #f #:active? #t))
                                  retreat-shades)
                          (cons (hasheq 'id 4220 'type 'drone 'x 112.0 'y 117.0 'hp 40.0 'max-hp 40.0)
                                closing-stalkers)
                          #:home-x home-x #:home-y home-y
                          #:enemy-main-x 132.0 #:enemy-main-y 132.0
                          #:enemy-targets two-base-targets)])
  (check! (and sh-hp
               (eq? (harass-directive-reason sh-hp) 'adept-retreat-out-safety-shade)
               (< (dist2 (harass-directive-tx sh-hp) (harass-directive-ty sh-hp) home-x home-y)
                  (dist2 131.0 131.0 home-x home-y))
               (> (dist2 (harass-directive-tx sh-hp) (harass-directive-ty sh-hp) 112.0 116.0) 10.0))
          (format "T3.3a: Wounded Adept (<60% HP) casts Retreat-Out Shade toward safe home ground outside Nat, got ~a" sh-hp))
  (check! (= (length retreat-dirs-outnum) 2)
          (format "T3.3b: Outnumbered Adepts inside enemy Nat cast Retreat-Out Safety Shades, got ~a" d-retreat-outnum))
  (check! (null? (find-dirs-by-ability d-retreat-active 'cancel-adept-phase-shift))
          "T3.3c1: Active Retreat-Out Safety Shade MUST NEVER cancel even at 5.9s")
  (check! (= (length (find-dirs-by-action d-retreat-active 'focus-fire)) 2)
          "T3.3c2: While Retreat-Out Shade travels out, Adepts keep firing final worker volley!"))

;; T3.4: Cross-Base Dual-Prong Fake-Shade (`Main <-> Nat`)
(let* ([adepts-at-nat (list (mk-adept 1071 112.0 116.0 #:ready? #t)
                            (mk-adept 1072 113.0 116.0 #:ready? #t))]
       [adepts-at-main (list (mk-adept 1073 132.0 132.0 #:ready? #t)
                             (mk-adept 1074 131.0 132.0 #:ready? #t))]
       [workers-both (list (hasheq 'id 4301 'type 'drone 'x 112.0 'y 117.0 'hp 40.0 'max-hp 40.0)
                           (hasheq 'id 4302 'type 'drone 'x 132.0 'y 133.0 'hp 40.0 'max-hp 40.0)
                           ;; Even with 4 Roaches guarding Nat, Adepts in Main still project a Fake Shade to Nat!
                           (hasheq 'id 4310 'type 'roach 'x 112.0 'y 115.0 'hp 145.0 'max-hp 145.0)
                           (hasheq 'id 4311 'type 'roach 'x 113.0 'y 115.0 'hp 145.0 'max-hp 145.0)
                           (hasheq 'id 4312 'type 'roach 'x 111.0 'y 115.0 'hp 145.0 'max-hp 145.0)
                           (hasheq 'id 4313 'type 'roach 'x 112.0 'y 114.0 'hp 145.0 'max-hp 145.0))]
       ;; Adepts at Nat (no roaches at Nat here) project Shade to opposite base (Main 132, 132)
       [d-nat->main (plan-multi-base-adept-harass adepts-at-nat
                                                  (take workers-both 2)
                                                  #:home-x home-x #:home-y home-y
                                                  #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                  #:enemy-targets two-base-targets)]
       [sh-nat->main (find-dirs-by-ability d-nat->main 'adept-phase-shift)]
       ;; Adepts at Main project Fake Shade to opposite base (Nat 112, 116) even with 4 Roaches at Nat
       [d-main->nat (plan-multi-base-adept-harass adepts-at-main
                                                  workers-both
                                                  #:home-x home-x #:home-y home-y
                                                  #:enemy-main-x 132.0 #:enemy-main-y 132.0
                                                  #:enemy-targets two-base-targets)]
       [sh-main->nat (find-dirs-by-ability d-main->nat 'adept-phase-shift)])
  (check! (and (= (length sh-nat->main) 2)
               (andmap (lambda (d) (<= (dist2 (harass-directive-tx d) (harass-directive-ty d) 132.0 132.0) 1.0))
                       sh-nat->main))
          (format "T3.4a: Physical Adepts at Nat project Shade to opposite Main (132,132), got ~a" sh-nat->main))
  (check! (and (= (length sh-main->nat) 2)
               (andmap (lambda (d) (<= (dist2 (harass-directive-tx d) (harass-directive-ty d) 112.0 116.0) 1.0))
                       sh-main->nat))
          (format "T3.4b: Physical Adepts at Main project Fake Shade to opposite Nat (112,116), got ~a" sh-main->nat)))

;; =============================================================================
;; PART 4: Loop 82B Fogged Terran Main-Ramp Protection (`classify-enemy-wall-state`)
;; =============================================================================

(let* ([en-main-x 132.0]
       [en-main-y 132.0]
       [en-nat-x 116.0]
       [en-nat-y 116.0]
       ;; T4.1: Fogged Terran (`scouted-enemy-main? = #f`, low-ground natural scout only + natural CC)
       ;;       MUST return `'unknown-unscouted` (NOT `'no-wall` or `'gapped-wall`) with posterior < 0.50!
       [wa-t-fog-explicit
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Terran
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-choke? #t 'scouted-enemy-main? #f
                 'ally-units (list (hasheq 'id 701 'type 'overlord 'x en-nat-x 'y en-nat-y))
                 'enemy-buildings (list (hasheq 'id 801 'type 'command-center 'x en-nat-x 'y en-nat-y))))]
       ;; T4.2: Fogged Terran WITHOUT explicit `scouted-enemy-main?` key (only low-ground Overlord at natural)
       [wa-t-fog-inferred
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Terran
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-choke? #t
                 'ally-units (list (hasheq 'id 701 'type 'overlord 'x en-nat-x 'y en-nat-y))
                 'enemy-buildings (list (hasheq 'id 801 'type 'command-center 'x en-nat-x 'y en-nat-y))))]
       ;; T4.3: Fogged Terran with only 1 Depot corner visible (`wall-cnt = 1`) and no main vision
       ;;       MUST still return `'unknown-unscouted` (NOT `'gapped-wall`)!
       [wa-t-fog-1depot
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Terran
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-choke? #t 'scouted-enemy-main? #f
                 'enemy-buildings (list (hasheq 'id 802 'type 'supply-depot 'x 126.3 'y 126.3))))]
       ;; T4.4: Actually scouted Terran main (`scouted-enemy-main? = #t` OR Reaper on high ground) with 0 ramp bldgs
       ;;       STILL classifies `'no-wall`!
       [wa-t-main-scouted
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Terran
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-choke? #t 'scouted-enemy-main? #t
                 'enemy-buildings '()))]
       [wa-t-reaper-hg
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Terran
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'ally-units (list (hasheq 'id 702 'type 'reaper 'x 128.0 'y 128.0))
                 'enemy-buildings '()))]
       ;; T4.5: Directly observed lowered Supply Depot at Terran ramp STILL classifies `'open-depot-door`!
       [wa-t-lowered
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Terran
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-main? #f
                 'enemy-buildings (list (hasheq 'id 803 'type 'supply-depot-lowered 'x 126.3 'y 126.3))))]
       ;; T4.6: Protoss & Zerg natural-open detection remains intact when natural IS scouted (`scouted-enemy-main? = #f`)!
       [wa-p-nat-open
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Protoss
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-choke? #t 'scouted-enemy-main? #f
                 'enemy-buildings (list (hasheq 'id 804 'type 'nexus 'x en-nat-x 'y en-nat-y))))]
       [wa-z-nat-open
        (classify-enemy-wall-state
         (hasheq 'frame 2200 'enemy-race 'Zerg
                 'base-x 32.0 'base-y 32.0 'enemy-x en-main-x 'enemy-y en-main-y
                 'enemy-natural-x en-nat-x 'enemy-natural-y en-nat-y
                 'scouted-enemy-choke? #t 'scouted-enemy-main? #f
                 'enemy-buildings (list (hasheq 'id 805 'type 'hatchery 'x en-nat-x 'y en-nat-y))))])
  (check! (and (eq? (EnemyWallAssessment-wall-state wa-t-fog-explicit) 'unknown-unscouted)
               (< (EnemyWallAssessment-unwalled-posterior wa-t-fog-explicit) 0.50))
          (format "T4.1: Fogged Terran (scouted-enemy-main?=#f) must be 'unknown-unscouted (<0.50), got ~a" wa-t-fog-explicit))
  (check! (and (eq? (EnemyWallAssessment-wall-state wa-t-fog-inferred) 'unknown-unscouted)
               (< (EnemyWallAssessment-unwalled-posterior wa-t-fog-inferred) 0.50))
          (format "T4.2: Fogged Terran with only low-ground Overlord at nat must be 'unknown-unscouted, got ~a" wa-t-fog-inferred))
  (check! (and (eq? (EnemyWallAssessment-wall-state wa-t-fog-1depot) 'unknown-unscouted)
               (< (EnemyWallAssessment-unwalled-posterior wa-t-fog-1depot) 0.50))
          (format "T4.3: Fogged Terran with 1 Depot corner visible must NOT return 'gapped-wall, got ~a" wa-t-fog-1depot))
  (check! (eq? (EnemyWallAssessment-wall-state wa-t-main-scouted) 'no-wall)
          (format "T4.4a: High-ground scouted open Terran main still returns 'no-wall, got ~a" wa-t-main-scouted))
  (check! (eq? (EnemyWallAssessment-wall-state wa-t-reaper-hg) 'no-wall)
          (format "T4.4b: Reaper on Terran high ground seeing 0 ramp bldgs still returns 'no-wall, got ~a" wa-t-reaper-hg))
  (check! (eq? (EnemyWallAssessment-wall-state wa-t-lowered) 'open-depot-door)
          (format "T4.5: Observed lowered Supply Depot still returns 'open-depot-door, got ~a" wa-t-lowered))
  (check! (eq? (EnemyWallAssessment-wall-state wa-p-nat-open) 'no-wall)
          (format "T4.6a: Scouted open Protoss natural still returns 'no-wall, got ~a" wa-p-nat-open))
  (check! (eq? (EnemyWallAssessment-wall-state wa-z-nat-open) 'no-wall)
          (format "T4.6b: Scouted open Zerg natural still returns 'no-wall, got ~a" wa-z-nat-open)))

;; =============================================================================
;; PART 5: Loop 82B `'infernal-preigniter` (Blue Flame) Gate (`situational-counter.rkt`)
;; =============================================================================

(let* ([t-bldgs '(command-center barracks factory factory-techlab)]
       ;; T5.1: Direct `select-situational-upgrades` — 0 or 1 Hellions MUST block Blue Flame!
       [u-0h-default
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(zergling) '() '() t-bldgs 300 300)]
       [u-0h-tvz
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(zergling) '() '() t-bldgs 300 300
                                     #:enemy-race 'Zerg #:hellion-count 0 #:siege-tank-count 0)]
       [u-1h-tvz
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(zergling) '() '() t-bldgs 300 300
                                     #:enemy-race 'Zerg #:hellion-count 1 #:siege-tank-count 0)]
       [u-2h-tvz
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(zergling) '() '() t-bldgs 300 300
                                     #:enemy-race 'Zerg #:hellion-count 2 #:siege-tank-count 0)]
       [u-2h-tvp
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(zealot) '() '() t-bldgs 300 300
                                     #:enemy-race 'Protoss #:hellion-count 2 #:siege-tank-count 0)]
       ;; T5.2: TvT (`enemy-race = 'Terran`) MUST ALSO require `siege-tank-count >= 2`!
       [u-tvt-4h-0t
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(marine) '() '() t-bldgs 300 300
                                     #:enemy-race 'Terran #:hellion-count 4 #:siege-tank-count 0)]
       [u-tvt-4h-1t
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(marine) '() '() t-bldgs 300 300
                                     #:enemy-race 'Terran #:hellion-count 4 #:siege-tank-count 1)]
       [u-tvt-2h-2t
        (select-situational-upgrades 'Terran 'opponent-unwalled-punish '(marine) '() '() t-bldgs 300 300
                                     #:enemy-race 'Terran #:hellion-count 2 #:siege-tank-count 2)]
       ;; T5.3: End-to-end `evaluate-situational-counter-plan` counts live Hellions/Hellbats & Siege Tanks
       [base-sit-obs
        (hasheq 'frame 3200 'race 'Terran 'minerals 300 'gas 200 'wall-sealed? #f 'enemy-wall-count 0
                'ally-buildings (list (hasheq 'id 1 'type 'command-center 'build-progress 1.0)
                                      (hasheq 'id 2 'type 'factory 'build-progress 1.0)
                                      (hasheq 'id 3 'type 'factory-techlab 'build-progress 1.0)))]
       [plan-0h-tvt
        (evaluate-situational-counter-plan
         (hash-set* base-sit-obs 'enemy-race 'Terran
                    'ally-units (list (hasheq 'id 10 'type 'marine))
                    'enemy-units (list (hasheq 'id 20 'type 'marine)))
         'Terran 'Terran 3200)]
       [plan-3h-1t-tvt
        (evaluate-situational-counter-plan
         (hash-set* base-sit-obs 'enemy-race 'Terran
                    'ally-units (list (hasheq 'id 10 'type 'hellion)
                                      (hasheq 'id 11 'type 'hellion)
                                      (hasheq 'id 12 'type 'hellion)
                                      (hasheq 'id 13 'type 'siege-tank))
                    'enemy-units (list (hasheq 'id 20 'type 'marine)))
         'Terran 'Terran 3200)]
       [plan-2h-2t-tvt
        (evaluate-situational-counter-plan
         (hash-set* base-sit-obs 'enemy-race 'Terran
                    'ally-units (list (hasheq 'id 10 'type 'hellion)
                                      (hasheq 'id 11 'type 'hellbat)
                                      (hasheq 'id 12 'type 'siege-tank)
                                      (hasheq 'id 13 'type 'siege-tank-sieged))
                    'enemy-units (list (hasheq 'id 20 'type 'marine)))
         'Terran 'Terran 3200)]
       [plan-2h-0t-tvz
        (evaluate-situational-counter-plan
         (hash-set* base-sit-obs 'enemy-race 'Zerg
                    'ally-units (list (hasheq 'id 10 'type 'hellion)
                                      (hasheq 'id 11 'type 'hellion))
                    'enemy-units (list (hasheq 'id 20 'type 'zergling)))
         'Terran 'Zerg 3200)])
  (check! (not (memq 'infernal-preigniter u-0h-default))
          (format "T5.1a: Default (0-Hellion) select-situational-upgrades MUST block infernal-preigniter, got ~a" u-0h-default))
  (check! (not (memq 'infernal-preigniter u-0h-tvz))
          (format "T5.1b: 0 Hellions in TvZ MUST block infernal-preigniter, got ~a" u-0h-tvz))
  (check! (not (memq 'infernal-preigniter u-1h-tvz))
          (format "T5.1c: 1 Hellion (< 2) in TvZ MUST block infernal-preigniter, got ~a" u-1h-tvz))
  (check! (not (not (memq 'infernal-preigniter u-2h-tvz)))
          (format "T5.1d: >= 2 Hellions in TvZ unlocks infernal-preigniter, got ~a" u-2h-tvz))
  (check! (not (not (memq 'infernal-preigniter u-2h-tvp)))
          (format "T5.1e: >= 2 Hellions in TvP unlocks infernal-preigniter, got ~a" u-2h-tvp))
  (check! (not (memq 'infernal-preigniter u-tvt-4h-0t))
          (format "T5.2a: TvT with 4 Hellions + 0 Tanks MUST block infernal-preigniter, got ~a" u-tvt-4h-0t))
  (check! (not (memq 'infernal-preigniter u-tvt-4h-1t))
          (format "T5.2b: TvT with 4 Hellions + 1 Tank (< 2) MUST block infernal-preigniter, got ~a" u-tvt-4h-1t))
  (check! (not (not (memq 'infernal-preigniter u-tvt-2h-2t)))
          (format "T5.2c: TvT with >= 2 Hellions + >= 2 Tanks unlocks infernal-preigniter, got ~a" u-tvt-2h-2t))
  (check! (not (memq 'infernal-preigniter (situational-counter-plan-recommended-upgrades plan-0h-tvt)))
          "T5.3a: End-to-end TvT plan with 0 Hellions blocks infernal-preigniter")
  (check! (not (memq 'infernal-preigniter (situational-counter-plan-recommended-upgrades plan-3h-1t-tvt)))
          "T5.3b: End-to-end TvT plan with 3 Hellions + 1 Tank blocks infernal-preigniter")
  (check! (not (not (memq 'infernal-preigniter (situational-counter-plan-recommended-upgrades plan-2h-2t-tvt))))
          "T5.3c: End-to-end TvT plan with Hellion+Hellbat (2) + Tank+SiegedTank (2) allows infernal-preigniter")
  (check! (not (not (memq 'infernal-preigniter (situational-counter-plan-recommended-upgrades plan-2h-0t-tvz))))
          "T5.3d: End-to-end TvZ plan with 2 Hellions + 0 Tanks allows infernal-preigniter"))

(printf "l82-adept-battery-cancel-test: ~a passed, ~a failed\n" passed failed)
(when (> failed 0)
  (exit 1))
