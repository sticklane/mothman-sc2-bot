#lang racket/base

;; =============================================================================
;; `tests/l88-tactical-operation-and-concave-test.rkt`
;; Loop 88A Track 3 Unit Tests:
;;   1. 7-Dimension `owm-control-signals` Bridge & Struct ABI Preservation
;;   2. `sc2-combat-eval.rkt` Cohesion, Elevation, Choke & Upgrade-Delta Physics
;;   3. `lib/tactics/operation-controller.rkt` All 6 Op-Modes, 7 OWM Dims & Hysteresis
;;   4. `lib/tactics/concave-positioning.rkt` All-Race Uphill Brake, Per-Cluster Axis,
;;      In-Combat Concave Widening & Defensive Pre-Arc Crescent
;;   5. `lib/tactics/multiprong-coordinator.rkt` Decoupled Bounded (<= 15%) Delay Harass
;;      with `active-home-defense-engaged?` Safety Gate
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/opponent-world-model.rkt"
         "../lib/sc2-combat-eval.rkt"
         "../lib/tactics/operation-controller.rkt"
         "../lib/tactics/concave-positioning.rkt"
         "../lib/tactics/multiprong-coordinator.rkt")

(define pass-cnt 0)
(define fail-cnt 0)

(define (check-true name cond [detail ""])
  (if cond
      (set! pass-cnt (add1 pass-cnt))
      (begin
        (set! fail-cnt (add1 fail-cnt))
        (eprintf "FAIL [~a]: ~a\n" name detail))))

(define (mk-u id type x y
              #:z [z 8.0]
              #:hp [hp 100.0]
              #:shield [sh 0.0]
              #:flying [fly #f]
              #:w-cd [w-cd 0.0]
              #:sieged [sieged #f])
  (hasheq 'id id
          'type type
          'x x
          'y y
          'z z
          'hp hp
          'max-hp hp
          'shield sh
          'shields sh
          'flying? fly
          'flying fly
          'is-flying fly
          'weapon-cooldown w-cd
          'sieged sieged
          'display-type 1))

(define (mk-th id type x y)
  (hasheq 'id id 'type type 'x x 'y y 'build-progress 1.0 'display-type 1))

;; =============================================================================
;; Group 1: 7-Dimension `owm-control-signals` Bridge & ABI Invariants
;; =============================================================================
(let ()
  ;; 1a. 35-field `opponent-world-summary` ABI intact
  (define-values (_n init-cnt _auto _acc _mut _imm _sup _skip?)
    (struct-type-info struct:opponent-world-summary))
  (check-true "g1-owm-summary-35-fields-abi"
              (= init-cnt 35)
              (format "init-cnt=~a" init-cnt))

  ;; 1b. `#f` input yields safe neutral `owm-control-signals`
  (define neutral (owm-build-control-signals #f #:enemy-upgrade-advantage 1 #:enemy-posture 'Aggressive))
  (check-true "g1-owm-neutral-signals"
              (and (owm-control-signals? neutral)
                   (= (owm-control-signals-confirmed-bases neutral) 1)
                   (= (owm-control-signals-enemy-upgrade-advantage neutral) 1)
                   (eq? (owm-control-signals-enemy-posture neutral) 'Aggressive))
              (format "neutral=~a" neutral))

  ;; 1c. Populated `opponent-world-summary` maps all 7 dimensions cleanly
  (define raw-sum
    (opponent-world-summary
     8000 'Terran
     2 3 3          ;; confirmed-bases, confirmed-geysers, happy-expected-bases
     44 5           ;; estimated-workers, workers-killed
     #t #t #f       ;; stopped-expanding?, unscouted-expansion-ambiguity?, confirmed-early-greed?
     (cons 120.0 40.0) ;; urgent-scout-pad
     12000 3800     ;; cum-min, cum-gas
     2500 1200 900  ;; sunk econ/tech
     400 200        ;; destroyed min/gas
     30 2200        ;; known army sup/val
     1500 600       ;; unaccounted min/gas
     42 3200        ;; believed army sup/val
     12 6 #t        ;; imminent-reachable-supply, production-facility-count, hidden-gas-tech-risk?
     #f #t          ;; requires-anti-air?, requires-detection?
     #f #f 0        ;; locust-wave, sh-cooldown, active-summon-count
     4              ;; enemy-siege-or-turtle-count
     (hasheq 'marine 14 'siege-tank-sieged 4)
     (hasheq 'command-center 2 'factory 2 'barracks 3 'starport 1)))
  (define cs (owm-build-control-signals raw-sum #:enemy-upgrade-advantage 1 #:enemy-posture 'TimingPush))
  (check-true "g1-owm-7dim-extraction"
              (and (= (owm-control-signals-confirmed-bases cs) 2)
                   (= (owm-control-signals-happy-expected-bases cs) 3)
                   (owm-control-signals-stopped-expanding? cs)
                   (owm-control-signals-unscouted-expansion-ambiguity? cs)
                   (equal? (owm-control-signals-urgent-scout-pad cs) (cons 120.0 40.0))
                   (= (owm-control-signals-estimated-workers cs) 44)
                   (= (owm-control-signals-workers-killed cs) 5)
                   (= (owm-control-signals-production-facility-count cs) 6)
                   (= (owm-control-signals-imminent-reachable-supply cs) 12)
                   (= (owm-control-signals-unaccounted-gas cs) 600)
                   (owm-control-signals-hidden-gas-tech-risk? cs)
                   (owm-control-signals-requires-detection? cs)
                   (= (owm-control-signals-believed-army-value cs) 3200)
                   (= (owm-control-signals-enemy-siege-or-turtle-count cs) 4)
                   (= (owm-control-signals-enemy-upgrade-advantage cs) 1)
                   (eq? (owm-control-signals-enemy-posture cs) 'TimingPush))
              (format "cs=~a" cs)))

;; =============================================================================
;; Group 2: `sc2-combat-eval.rkt` Cohesion, Elevation, Choke & Upgrade Physics
;; =============================================================================
(let ()
  (define ally-sq (list (cons 'stalker 8)))
  (define enemy-sq (list (cons 'stalker 8)))

  ;; 2a. Neutral defaults preserve exact raw ratio & mult = 1.0
  (define base-res (predict-engagement-outcome ally-sq enemy-sq))
  (check-true "g2-neutral-mult-exact"
              (and (<= (abs (- (hash-ref base-res 'terrain-cohesion-multiplier) 1.0)) 1e-6)
                   (<= (abs (- (hash-ref base-res 'predicted-lanchester-ratio)
                               (hash-ref base-res 'raw-lanchester-ratio))) 1e-6)
                   (not (hash-ref base-res 'uphill-disadvantage?)))
              (format "base=~a" base-res))

  ;; 2b. Low local cohesion (`0.50`) cuts power ratio & rejects marginal engage
  (define disp-res (predict-engagement-outcome ally-sq enemy-sq #:ally-cohesion 0.50))
  (check-true "g2-dispersed-cohesion-penalizes"
              (and (< (hash-ref disp-res 'predicted-lanchester-ratio) 0.50)
                   (not (hash-ref disp-res 'should-engage?)))
              (format "disp=~a" disp-res))

  ;; 2c. Uphill disadvantage (`-2.0`) penalizes & flags; high ground (`+2.0`) boosts
  (define up-res (predict-engagement-outcome ally-sq enemy-sq #:elevation-delta -2.0))
  (define hg-res (predict-engagement-outcome ally-sq enemy-sq #:elevation-delta 2.0))
  (check-true "g2-elevation-physics"
              (and (hash-ref up-res 'uphill-disadvantage?)
                   (< (hash-ref up-res 'predicted-lanchester-ratio) 0.70)
                   (not (hash-ref up-res 'should-engage?))
                   (not (hash-ref hg-res 'uphill-disadvantage?))
                   (> (hash-ref hg-res 'predicted-lanchester-ratio) 1.35)
                   (hash-ref hg-res 'should-engage?))
              (format "up=~a hg=~a" up-res hg-res))

  ;; 2d. Narrow choke (`3.0t`): penalizes attacker, boosts home defender
  (define chk-atk (predict-engagement-outcome ally-sq enemy-sq #:choke-width 3.0 #:defending-home? #f))
  (define chk-def (predict-engagement-outcome ally-sq enemy-sq #:choke-width 3.0 #:defending-home? #t))
  (check-true "g2-choke-asymmetry"
              (and (< (hash-ref chk-atk 'predicted-lanchester-ratio) 0.80)
                   (> (hash-ref chk-def 'predicted-lanchester-ratio) 1.10))
              (format "atk=~a def=~a" chk-atk chk-def))

  ;; 2e. Upgrade delta applies when explicit lists empty, never double-counts when lists provided
  (define upg-plus (predict-engagement-outcome ally-sq enemy-sq #:upgrade-delta 1))
  (define upg-minus (predict-engagement-outcome ally-sq enemy-sq #:upgrade-delta -1))
  (define upg-explicit
    (predict-engagement-outcome ally-sq enemy-sq
                                #:ally-upgrades '(protoss-ground-weapons-1)
                                #:upgrade-delta 2))
  (check-true "g2-upgrade-delta-no-double-count"
              (and (> (hash-ref upg-plus 'predicted-lanchester-ratio) 1.10)
                   (< (hash-ref upg-minus 'predicted-lanchester-ratio) 0.92)
                   (<= (abs (- (hash-ref upg-explicit 'terrain-cohesion-multiplier) 1.0)) 1e-6))
              (format "plus=~a minus=~a exp=~a" upg-plus upg-minus upg-explicit)))

;; =============================================================================
;; Group 3: `operation-controller.rkt` Modes, All 7 OWM Dims & Safety Invariants
;; =============================================================================
(let ()
  (define ally-ths (list (mk-th 1 'nexus 32.0 32.0) (mk-th 2 'nexus 56.0 32.0)))

  ;; 3a. Local clustering separates split 50/50 army
  (define split-army
    (append (for/list ([i (in-range 5)]) (mk-u (+ 100 i) 'stalker (+ 60.0 i) 50.0 #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 5)]) (mk-u (+ 200 i) 'stalker (+ 120.0 i) 50.0 #:hp 80.0 #:shield 80.0))))
  (define-values (cl-u _cx _cy cl-val tot-val coh) (compute-local-combat-clusters split-army))
  (check-true "g3-split-army-cohesion-half"
              (and (= (length cl-u) 5)
                   (<= (abs (- coh 0.50)) 0.05)
                   (< cl-val (* 0.60 tot-val)))
              (format "len=~a coh=~a cl=~a tot=~a" (length cl-u) coh cl-val tot-val))

  ;; 3b. Elevation & choke width measurement on synthetic 3-tile corridor
  (define corridor-pathable? (lambda (_x y) (and (>= y 49.0) (<= y 51.0))))
  (define low-a (list (mk-u 301 'stalker 70.0 50.0 #:z 8.0)))
  (define high-e (list (mk-u 401 'marine 80.0 50.0 #:z 10.0)))
  (define-values (dz cw)
    (compute-clash-elevation-and-choke low-a high-e #:pathable-fn corridor-pathable?))
  (check-true "g3-elevation-and-choke-measure"
              (and (<= (abs (- dz -2.0)) 1e-6)
                   (<= cw 4.0))
              (format "dz=~a cw=~a" dz cw))

  ;; 3c. Dispersed army stages in `'regroup-stage` while keeping `delay-harass-allowed? = #t`
  (define p-disp
    (evaluate-tactical-operation
     #:frame 6000 #:race 'Protoss #:live-obs? #t
     #:combat-units split-army #:enemy-units '()
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  (check-true "g3-dispersed-army-regroups-and-allows-delay-harass"
              (and (eq? (tactical-op-plan-op-mode p-disp) 'regroup-stage)
                   (tactical-op-plan-suppress-main-attack? p-disp)
                   (tactical-op-plan-delay-harass-allowed? p-disp))
              (format "mode=~a sup=~a dh=~a"
                      (tactical-op-plan-op-mode p-disp)
                      (tactical-op-plan-suppress-main-attack? p-disp)
                      (tactical-op-plan-delay-harass-allowed? p-disp)))

  ;; 3d. Tight cohesive army vs uphill high-ground enemy triggers `'pre-arc-hold` + `uphill-brake-active?`
  (define tight-a (for/list ([i (in-range 8)]) (mk-u (+ 500 i) 'stalker (+ 70.0 (* 0.5 i)) 50.0 #:z 8.0 #:hp 80.0 #:shield 80.0)))
  (define high-es (for/list ([i (in-range 8)]) (mk-u (+ 600 i) 'stalker (+ 82.0 (* 0.5 i)) 50.0 #:z 10.0 #:hp 80.0 #:shield 80.0)))
  (define p-uphill
    (evaluate-tactical-operation
     #:frame 7000 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units high-es
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  (check-true "g3-uphill-triggers-pre-arc-or-retreat-and-uphill-brake"
              (and (tactical-op-plan-uphill-brake-active? p-uphill)
                   (memq (tactical-op-plan-op-mode p-uphill) '(pre-arc-hold retreat-regroup))
                   (tactical-op-plan-delay-harass-allowed? p-uphill))
              (format "plan=~a" p-uphill))

  ;; 3e. Fortified choke with soft `choke-redirect-xy` triggers `'flank-rotate`
  (define p-flank
    (evaluate-tactical-operation
     #:frame 8000 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:choke-hold-active? #t #:choke-redirect-xy (cons 140.0 95.0)
     #:our-bases 2))
  (check-true "g3-soft-redirect-triggers-flank-rotate"
              (and (eq? (tactical-op-plan-op-mode p-flank) 'flank-rotate)
                   (equal? (tactical-op-plan-redirect-target-pt p-flank) (cons 140.0 95.0))
                   (not (tactical-op-plan-suppress-main-attack? p-flank)))
              (format "plan=~a" p-flank))

  ;; 3f. Active timing spike (`spike-eta-sec = 14.0 <= 25.0`) holds briefly in `'pre-arc-hold`
  (define p-spike
    (evaluate-tactical-operation
     #:frame 7500 #:race 'Terran #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:owm-signals (owm-control-signals
                    2 2 2 #f #t #f (cons 130.0 45.0)
                    2 2 1400 300 9000 1800
                    40 0 4 4 8
                    800 350 #t #f #f 0.0 #f #f
                    16 1400 18 1600 0 #f #f 0 0 0
                    0 'MacroStandard)
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:spike-eta-sec 14.0 #:our-bases 2))
  (check-true "g3-spike-hold-plus-owm-scout-and-det-reserve"
              (and (eq? (tactical-op-plan-op-mode p-spike) 'pre-arc-hold)
                   (equal? (tactical-op-plan-scout-ambiguous-pad p-spike) (cons 130.0 45.0))
                   (tactical-op-plan-reserve-home-detector? p-spike)
                   (tactical-op-plan-delay-harass-allowed? p-spike))
              (format "mode=~a scout=~a det=~a"
                      (tactical-op-plan-op-mode p-spike)
                      (tactical-op-plan-scout-ambiguous-pad p-spike)
                      (tactical-op-plan-reserve-home-detector? p-spike)))

  ;; 3g. Swarm-Host cooldown window flips hold into immediate `'commit-push` counter-attack!
  (define p-sh-cd
    (evaluate-tactical-operation
     #:frame 9000 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:owm-signals (owm-control-signals
                    2 2 2 #f #f #f #f
                    2 2 1400 300 9000 1800
                    40 0 4 4 0
                    0 0 #f #f #f 0.0 #f #f
                    16 1400 16 1400 0 #f #t 0 0 0
                    0 'MacroStandard)
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  (check-true "g3-sh-cooldown-triggers-commit-push"
              (and (eq? (tactical-op-plan-op-mode p-sh-cd) 'commit-push)
                   (not (tactical-op-plan-suppress-main-attack? p-sh-cd)))
              (format "mode=~a ratio=~a" (tactical-op-plan-op-mode p-sh-cd)
                      (tactical-op-plan-eff-power-ratio p-sh-cd)))

  ;; 3h. Locust wave active (`>= 6` summons) triggers `'retreat-regroup`
  (define p-locust
    (evaluate-tactical-operation
     #:frame 9000 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:owm-signals (owm-control-signals
                    2 2 2 #f #f #f #f
                    2 2 1400 300 9000 1800
                    40 0 4 4 0
                    0 0 #f #f #f 0.0 #f #f
                    16 1400 16 1400 0 #t #f 10 0 0
                    0 'MacroStandard)
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  (check-true "g3-locust-wave-triggers-retreat-regroup"
              (eq? (tactical-op-plan-op-mode p-locust) 'retreat-regroup)
              (format "mode=~a" (tactical-op-plan-op-mode p-locust)))

  ;; 3i. Active home defense (`active-home-defense-engaged?`) ALWAYS commits `'defend-home`
  ;;     and disables `delay-harass-allowed?` (never splits a live home defense fight!)
  (define home-def-allies (for/list ([i (in-range 4)]) (mk-u (+ 700 i) 'stalker (+ 54.0 i) 32.0 #:hp 80.0 #:shield 80.0)))
  (define home-attackers (for/list ([i (in-range 10)]) (mk-u (+ 800 i) 'stalker (+ 60.0 (* 0.4 i)) 32.0 #:hp 80.0 #:shield 80.0)))
  (define p-hdef
    (evaluate-tactical-operation
     #:frame 8200 #:race 'Protoss #:live-obs? #t
     #:combat-units home-def-allies #:enemy-units home-attackers
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:under-home-attack? #t #:our-bases 2))
  (check-true "g3-active-home-defense-commits-and-blocks-harass"
              (and (tactical-op-plan-active-home-defense-engaged? p-hdef)
                   (eq? (tactical-op-plan-op-mode p-hdef) 'defend-home)
                   (not (tactical-op-plan-delay-harass-allowed? p-hdef))
                   (not (tactical-op-plan-suppress-main-attack? p-hdef)))
              (format "plan=~a" p-hdef))

  ;; 3i2. Rear squad 15t behind Natural under heavy 0.23x push is NOT engaged (pre-arcs safely)
  (define rear-marines (for/list ([i (in-range 4)]) (mk-u (+ 740 i) 'marine (+ 45.0 (* 0.3 i)) 32.0 #:hp 45.0)))
  (define p-rear-muster
    (evaluate-tactical-operation
     #:frame 8200 #:race 'Terran #:live-obs? #t
     #:combat-units rear-marines #:enemy-units home-attackers
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:under-home-attack? #t #:our-bases 2))
  (check-true "g3-rear-squad-15t-not-engaged-pre-arcs"
              (and (not (tactical-op-plan-active-home-defense-engaged? p-rear-muster))
                   (eq? (tactical-op-plan-op-mode p-rear-muster) 'pre-arc-hold))
              (format "plan=~a" p-rear-muster))

  ;; 3i3. High-Lanchester bio counter (19 Marines vs 7 Stalkers at Natural, ratio > 1.15)
  ;;      commits `'defend-home` even though gas-weighted resource value is < 0.72x
  (define bio-marines (for/list ([i (in-range 19)]) (mk-u (+ 760 i) 'marine (+ 45.0 (* 0.2 i)) 32.0 #:hp 45.0)))
  (define nat-stalkers (for/list ([i (in-range 7)]) (mk-u (+ 840 i) 'stalker (+ 60.0 (* 0.3 i)) 32.0 #:hp 80.0 #:shield 80.0)))
  (define p-bio-win
    (evaluate-tactical-operation
     #:frame 8200 #:race 'Terran #:live-obs? #t
     #:combat-units bio-marines #:enemy-units nat-stalkers
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:under-home-attack? #t #:our-bases 2))
  (check-true "g3-bio-lanchester-win-commits-home-defense"
              (and (>= (tactical-op-plan-eff-power-ratio p-bio-win) 1.15)
                   (eq? (tactical-op-plan-op-mode p-bio-win) 'defend-home))
              (format "mode=~a ratio=~a"
                      (tactical-op-plan-op-mode p-bio-win)
                      (tactical-op-plan-eff-power-ratio p-bio-win)))

  ;; 3j. Hysteresis state prevents 1-frame flicker out of `'pre-arc-hold`, yields on emergency
  (define hst (make-tactical-op-state))
  (define h1
    (evaluate-tactical-operation
     #:frame 7000 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:owm-signals (owm-control-signals
                    2 2 2 #f #f #f #f 2 2 1400 300 9000 1800
                    40 0 4 4 0 0 0 #f #f #f 0.0 #f #f
                    16 1400 18 1600 0 #f #f 0 0 0 0 'MacroStandard)
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:spike-eta-sec 10.0 #:our-bases 2 #:state hst))
  (define h2
    (evaluate-tactical-operation
     #:frame 7010 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:owm-signals (owm-control-signals
                    2 2 2 #f #f #f #f 2 2 1400 300 9000 1800
                    40 0 4 4 0 0 0 #f #f #f 0.0 #f #f
                    16 1400 16 1500 0 #f #f 0 0 0 0 'MacroStandard)
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:spike-eta-sec 0.0 #:our-bases 2 #:state hst))
  (define h3
    (evaluate-tactical-operation
     #:frame 7015 #:race 'Protoss #:live-obs? #t
     #:combat-units tight-a #:enemy-units '()
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:enemy-near-main? #t #:our-bases 2 #:state hst))
  (check-true "g3-hysteresis-holds-and-yields-on-emergency"
              (and (eq? (tactical-op-plan-op-mode h1) 'pre-arc-hold)
                   (eq? (tactical-op-plan-op-mode h2) 'pre-arc-hold)
                   (eq? (tactical-op-plan-op-mode h3) 'defend-home))
              (format "h1=~a h2=~a h3=~a"
                      (tactical-op-plan-op-mode h1)
                      (tactical-op-plan-op-mode h2)
                      (tactical-op-plan-op-mode h3)))

  ;; 3k. Distant scouted enemy siege wall (6 Tanks + 12 Marines at (130, 110)) holds 24-sup
  ;;     Stalkers in `'pre-arc-hold`, while 62-sup critical mass releases to `'commit-push`!
  (define far-tanks6
    (append (for/list ([i (in-range 6)]) (mk-u (+ 860 i) 'siege-tank-sieged (+ 130.0 (* 1.5 i)) 110.0 #:hp 175.0))
            (for/list ([i (in-range 12)]) (mk-u (+ 880 i) 'marine (+ 128.0 (* 0.5 i)) 108.0 #:hp 45.0))))
  (define st12 (for/list ([i (in-range 12)]) (mk-u (+ 900 i) 'stalker (+ 56.0 (* 0.4 i)) 32.0 #:hp 80.0 #:shield 80.0)))
  (define st31 (for/list ([i (in-range 31)]) (mk-u (+ 940 i) 'stalker (+ 56.0 (* 0.2 i)) 32.0 #:hp 80.0 #:shield 80.0)))
  (define p-siege-hold
    (evaluate-tactical-operation
     #:frame 9600 #:race 'Protoss #:live-obs? #t
     #:combat-units st12 #:enemy-units far-tanks6
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  (define p-siege-rel
    (evaluate-tactical-operation
     #:frame 11000 #:race 'Protoss #:live-obs? #t
     #:combat-units st31 #:enemy-units far-tanks6
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  (check-true "g3-distant-siege-wall-holds-24sup-releases-62sup"
              (and (eq? (tactical-op-plan-op-mode p-siege-hold) 'pre-arc-hold)
                   (eq? (tactical-op-plan-op-mode p-siege-rel) 'commit-push))
              (format "hold=~a rel=~a"
                      (tactical-op-plan-op-mode p-siege-hold)
                      (tactical-op-plan-op-mode p-siege-rel)))

  ;; 3l. Slow Tank squad in deep fog (~0.90x believed) holds without spike, then commits
  ;;     immediately when fresh upgrade completes on `op-state`!
  (define slow-tanks
    (append (for/list ([i (in-range 3)]) (mk-u (+ 980 i) 'siege-tank (+ 70.0 i) 70.0 #:hp 175.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 985 i) 'marauder (+ 72.0 i) 71.0 #:hp 125.0))
            (for/list ([i (in-range 12)]) (mk-u (+ 990 i) 'marine (+ 70.0 (* 0.4 i)) 73.0 #:hp 45.0))))
  (define fog-owm
    (owm-control-signals
     1 2 2 #f #f #f #f 2 2 1400 300 9000 1800
     40 0 3 3 0 0 0 #f #f #f 0.0 #f #f
     0 0 30 2243 0 #f #f 0 0 0 0 'MacroStandard))
  (define sp-st (make-tactical-op-state))
  (define p-nospike1
    (evaluate-tactical-operation
     #:frame 8900 #:race 'Terran #:live-obs? #t
     #:combat-units slow-tanks #:enemy-units '()
     #:owm-signals fog-owm #:ally-upgrades '()
     #:ally-buildings (list (mk-th 1 'command-center 32.0 32.0))
     #:base-x 32.0 #:base-y 32.0 #:our-workers 16 #:our-bases 1 #:state sp-st))
  (define p-nospike2
    (evaluate-tactical-operation
     #:frame 9000 #:race 'Terran #:live-obs? #t
     #:combat-units slow-tanks #:enemy-units '()
     #:owm-signals fog-owm #:ally-upgrades '()
     #:ally-buildings (list (mk-th 1 'command-center 32.0 32.0))
     #:base-x 32.0 #:base-y 32.0 #:our-workers 16 #:our-bases 1 #:state sp-st))
  (define p-withspike
    (evaluate-tactical-operation
     #:frame 9005 #:race 'Terran #:live-obs? #t
     #:combat-units slow-tanks #:enemy-units '()
     #:owm-signals fog-owm #:ally-upgrades '(stimpack)
     #:ally-buildings (list (mk-th 1 'command-center 32.0 32.0))
     #:base-x 32.0 #:base-y 32.0 #:our-workers 16 #:our-bases 1 #:state sp-st))
  (check-true "g3-deep-fog-slow-army-holds-without-spike-commits-on-upgrade-completion"
              (and (tactical-op-plan-suppress-main-attack? p-nospike1)
                   (tactical-op-plan-suppress-main-attack? p-nospike2)
                   (eq? (tactical-op-plan-op-mode p-withspike) 'commit-push))
              (format "ns1=~a ns2=~a sp=~a"
                      (tactical-op-plan-op-mode p-nospike1)
                      (tactical-op-plan-op-mode p-nospike2)
                      (tactical-op-plan-op-mode p-withspike)))

  ;; 3m (Loop 88B Track 3): Real owned-TH perimeter (`<= 26t` of ANY owned TH: Main/Nat/3rd)
  ;;     NEVER returns `'retreat-regroup`, while far-from-TH (> 26t) & 0-TH arenas STILL retreat!
  (define z-3ths (list (mk-th 1 'hatchery 32.0 32.0)
                       (mk-th 2 'hatchery 56.0 32.0)
                       (mk-th 3 'hatchery 82.0 32.0)))
  (define z-def-army (for/list ([i (in-range 10)]) (mk-u (+ 1200 i) 'roach (+ 84.0 (* 0.3 i)) 36.0 #:hp 145.0)))
  (define e-3rd-push (for/list ([i (in-range 12)]) (mk-u (+ 1250 i) 'roach (+ 98.0 (* 0.3 i)) 42.0 #:hp 145.0)))
  (define p-3rd-def
    (evaluate-tactical-operation
     #:frame 8400 #:race 'Zerg #:live-obs? #t
     #:combat-units z-def-army #:enemy-units e-3rd-push
     #:ally-buildings z-3ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:enemy-x 160.5 #:enemy-y 160.5 #:pullback-active? #t #:our-bases 3))
  ;; Defender standing inside Natural perimeter (`<= 26t` of Nat TH) vs enemy shelling at `28t` (`> 26t`)
  (define z-perim-def (for/list ([i (in-range 6)]) (mk-u (+ 1280 i) 'roach (+ 68.0 (* 0.3 i)) 46.0 #:hp 145.0)))
  (define e-perim-shell (for/list ([i (in-range 14)]) (mk-u (+ 1300 i) 'roach (+ 76.0 (* 0.3 i)) 52.0 #:hp 145.0)))
  (define p-perim-def
    (evaluate-tactical-operation
     #:frame 8450 #:race 'Zerg #:live-obs? #t
     #:combat-units z-perim-def #:enemy-units e-perim-shell
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:enemy-x 160.5 #:enemy-y 160.5 #:pullback-active? #t #:our-bases 2))
  ;; Control 1: outnumbered squad far from TH (`> 26t` from Main/Nat at `(76, 80)`) STILL retreats!
  (define z-far-small (for/list ([i (in-range 5)]) (mk-u (+ 1340 i) 'roach (+ 76.0 (* 0.3 i)) 78.0 #:hp 145.0)))
  (define e-far-big (for/list ([i (in-range 14)]) (mk-u (+ 1360 i) 'roach (+ 82.0 (* 0.3 i)) 80.0 #:hp 145.0)))
  (define p-far-ret
    (evaluate-tactical-operation
     #:frame 8500 #:race 'Zerg #:live-obs? #t
     #:combat-units z-far-small #:enemy-units e-far-big
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:enemy-x 160.5 #:enemy-y 160.5 #:pullback-active? #t #:our-bases 2))
  ;; Control 2: 0-TH synthetic arena (`ally-buildings = '()`) near `(bx, by)` STILL retreats!
  (define z-0th-small (for/list ([i (in-range 3)]) (mk-u (+ 1380 i) 'stalker (+ 36.0 (* 0.3 i)) 34.0 #:hp 80.0 #:shield 80.0)))
  (define e-0th-big (for/list ([i (in-range 10)]) (mk-u (+ 1390 i) 'marauder (+ 42.0 (* 0.3 i)) 34.0 #:hp 125.0)))
  (define p-0th-ret
    (evaluate-tactical-operation
     #:frame 8550 #:race 'Protoss #:live-obs? #t
     #:combat-units z-0th-small #:enemy-units e-0th-big
     #:ally-buildings '() #:base-x 32.0 #:base-y 32.0 #:enemy-x 160.5 #:enemy-y 160.5))
  (check-true "g3-own-territory-3rd-and-home-perimeter-never-retreats-while-far-and-0th-retreat"
              (and (eq? (tactical-op-plan-op-mode p-3rd-def) 'defend-home)
                   (not (eq? (tactical-op-plan-op-mode p-perim-def) 'retreat-regroup))
                   (eq? (tactical-op-plan-op-mode p-far-ret) 'retreat-regroup)
                   (eq? (tactical-op-plan-op-mode p-0th-ret) 'retreat-regroup))
              (format "3rd=~a perim=~a far=~a 0th=~a"
                      (tactical-op-plan-op-mode p-3rd-def)
                      (tactical-op-plan-op-mode p-perim-def)
                      (tactical-op-plan-op-mode p-far-ret)
                      (tactical-op-plan-op-mode p-0th-ret)))

  ;; 3n (Loop 88B Track 3): Un-stacked `base-commit-thresh` (`<= 1.12` non-fortified, zero `eco-lead?`
  ;;     hesitation at parity/advantage, no `slow-nonretreatable-army?` / `waiting-for-spike?` lock
  ;;     on ahead midgame armies >= 1.05x!)
  (define t-3ths (list (mk-th 11 'command-center 32.0 32.0)
                       (mk-th 12 'orbital-command 56.0 32.0)
                       (mk-th 13 'orbital-command 82.0 32.0)))
  ;; Midgame Terran Bio+Tank (`4` Tanks + `16` Marines + `4` Marauders = `36` sup, `2650` val)
  (define mid-terran-army
    (append (for/list ([i (in-range 4)]) (mk-u (+ 1400 i) 'siege-tank (+ 72.0 i) 68.0 #:hp 175.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 1410 i) 'marauder (+ 73.0 i) 70.0 #:hp 125.0))
            (for/list ([i (in-range 16)]) (mk-u (+ 1420 i) 'marine (+ 71.0 (* 0.3 i)) 72.0 #:hp 55.0))))
  ;; Ahead (`ratio ~ 1.08`) with `eco-lead?` + `high-gas-tech-opp?` + `prod-surge-pressure?` + secondary TechLab spike
  (define ahead-mid-owm
    (owm-control-signals
     2 2 2 #f #f #f #f
     4 4 1400 600 12000 5000
     40 4 6 6 10
     0 0 #f #f #f 0.0 #f #f
     18 1700 26 2450 0 #f #f 0 400 200
     0 'MacroStandard))
  (define p-mid-commit
    (evaluate-tactical-operation
     #:frame 10800 #:race 'Terran #:live-obs? #t
     #:combat-units mid-terran-army #:enemy-units '()
     #:owm-signals ahead-mid-owm
     #:ally-buildings t-3ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-workers 56 #:our-bases 3 #:spike-eta-sec 14.0))
  ;; Stacked ALL non-fortified caution flags (stopped-exp + high-gas + prod-surge + hidden-gas + aggressive)
  ;; MUST stay capped <= 1.12 so a `1.15x` army commits cleanly (`2650 / 2300 = 1.152`)!
  (define stacked-caution-owm
    (owm-control-signals
     2 2 3 #t #f #f #f
     4 4 1400 600 12000 5000
     40 4 6 6 10
     0 0 #t #f #f 0.0 #t #f
     16 1550 24 2300 0 #f #f 0 400 200
     0 'Aggressive))
  (define p-cap-commit
    (evaluate-tactical-operation
     #:frame 10800 #:race 'Terran #:live-obs? #t
     #:combat-units mid-terran-army #:enemy-units '()
     #:owm-signals stacked-caution-owm
     #:ally-buildings t-3ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-workers 56 #:our-bases 3))
  ;; Behind in army (`ratio = 2650 / 3100 = 0.85 < 1.0`) with `eco-lead?` STILL holds solidly!
  (define behind-eco-owm
    (owm-control-signals
     2 2 2 #f #f #f #f
     2 2 1400 300 12000 2400
     40 0 4 4 0
     0 0 #f #f #f 0.0 #f #f
     30 3100 32 3100 0 #f #f 0 0 0
     0 'MacroStandard))
  (define p-eco-behind-army-hold
    (evaluate-tactical-operation
     #:frame 10800 #:race 'Terran #:live-obs? #t
     #:combat-units mid-terran-army #:enemy-units '()
     #:owm-signals behind-eco-owm
     #:ally-buildings t-3ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-workers 56 #:our-bases 3))
  (check-true "g3-unstacked-commit-with-eco-lead-and-midgame-tech-spike"
              (and (eq? (tactical-op-plan-op-mode p-mid-commit) 'commit-push)
                   (eq? (tactical-op-plan-op-mode p-cap-commit) 'commit-push)
                   (tactical-op-plan-suppress-main-attack? p-eco-behind-army-hold))
              (format "mid=~a (r=~a) cap=~a (r=~a) hold=~a (r=~a)"
                      (tactical-op-plan-op-mode p-mid-commit)
                      (tactical-op-plan-eff-power-ratio p-mid-commit)
                      (tactical-op-plan-op-mode p-cap-commit)
                      (tactical-op-plan-eff-power-ratio p-cap-commit)
                      (tactical-op-plan-op-mode p-eco-behind-army-hold)
                      (tactical-op-plan-eff-power-ratio p-eco-behind-army-hold)))

  ;; 3o (Loop 88D Track 2): Multi-base Zerg army (< 60 sup, below critical-mass) with strong main
  ;;     cluster + spread-out rear Queens near Hatcheries & newly morphed rallies (`local-cohesion
  ;;     < 0.65`) MUST NOT suffer a double cohesion penalty: commits `'commit-push` cleanly in both
  ;;     fog & local clash, while a genuinely weak split army still regroups!
  (define z-4ths (list (mk-th 21 'hatchery 32.0 32.0)
                       (mk-th 22 'hatchery 56.0 32.0)
                       (mk-th 23 'hatchery 82.0 32.0)
                       (mk-th 24 'hatchery 32.0 64.0)))
  ;; Main cohesive cluster at `(102, 96)`: 10 Roaches (1125) + 4 Hydras (700) = 1825 val (28 sup)
  (define z-main-cl
    (append (for/list ([i (in-range 10)]) (mk-u (+ 1500 i) 'roach (+ 100.0 (* 0.4 i)) 96.0 #:hp 145.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 1520 i) 'hydralisk (+ 101.0 (* 0.5 i)) 94.0 #:hp 90.0))))
  ;; 4 home-bound Queens across 4 Hatcheries (`600` val, 8 sup, excluded from offensive cohesion)
  (define z-home-queens
    (list (mk-u 1540 'queen 34.0 33.0 #:hp 175.0)
          (mk-u 1542 'queen 57.0 33.0 #:hp 175.0)
          (mk-u 1544 'queen 83.0 33.0 #:hp 175.0)
          (mk-u 1545 'queen 34.0 65.0 #:hp 175.0)))
  ;; Spread-out newly morphed rallies (`10` Roaches = `1125` val, 20 sup -> total 56 sup < 60,
  ;; mobile cohesion = `1825 / 2950 = 0.619 < 0.65`!)
  (define z-rear-rallies
    (append (for/list ([i (in-range 4)]) (mk-u (+ 1560 i) 'roach (+ 35.0 (* 0.5 i)) 36.0 #:hp 145.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 1570 i) 'roach (+ 60.0 (* 0.5 i)) 36.0 #:hp 145.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 1580 i) 'roach (+ 35.0 (* 0.5 i)) 68.0 #:hp 145.0))))
  (define z-spread-full (append z-main-cl z-home-queens z-rear-rallies))
  (define z-opp-owm
    (owm-control-signals
     3 3 3 #f #f #f #f
     4 4 1600 450 14000 3200
     50 2 5 5 0
     0 0 #f #f #f 0.0 #f #f
     14 1400 16 1400 0 #f #f 0 0 0
     0 'MacroStandard))
  (define p-z-spread-fog
    (evaluate-tactical-operation
     #:frame 10800 #:race 'Zerg #:live-obs? #t
     #:combat-units z-spread-full #:enemy-units '()
     #:owm-signals z-opp-owm
     #:ally-buildings z-4ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-workers 60 #:our-bases 4))
  ;; Same spread Zerg army in local clash at `(110, 96)` vs 6 Stalkers (1200 val) -> commits `'commit-push`!
  (define e-clash-st6
    (for/list ([i (in-range 6)]) (mk-u (+ 1600 i) 'stalker (+ 110.0 (* 0.4 i)) 96.0 #:hp 80.0 #:shield 80.0)))
  (define p-z-spread-clash
    (evaluate-tactical-operation
     #:frame 10820 #:race 'Zerg #:live-obs? #t
     #:combat-units z-spread-full #:enemy-units e-clash-st6
     #:owm-signals z-opp-owm
     #:ally-buildings z-4ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-workers 60 #:our-bases 4))
  ;; Control: weak split army (`6` Roaches = `675` val + `6` Roaches = `675` val) vs `1400`-val enemy STILL regroups!
  (define z-weak-split
    (append (for/list ([i (in-range 6)]) (mk-u (+ 1620 i) 'roach (+ 75.0 (* 0.4 i)) 75.0 #:hp 145.0))
            (for/list ([i (in-range 6)]) (mk-u (+ 1630 i) 'roach (+ 35.0 (* 0.4 i)) 35.0 #:hp 145.0))))
  (define p-z-weak-regroup
    (evaluate-tactical-operation
     #:frame 10840 #:race 'Zerg #:live-obs? #t
     #:combat-units z-weak-split #:enemy-units '()
     #:owm-signals z-opp-owm
     #:ally-buildings z-4ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-workers 60 #:our-bases 4))
  (check-true "g3-multibase-zerg-no-double-cohesion-penalty-commits-when-main-cluster-wins"
              (and (< (tactical-op-plan-local-cohesion-ratio p-z-spread-fog) 0.65)
                   (eq? (tactical-op-plan-op-mode p-z-spread-fog) 'commit-push)
                   (>= (tactical-op-plan-eff-power-ratio p-z-spread-fog) 1.25)
                   (eq? (tactical-op-plan-op-mode p-z-spread-clash) 'commit-push)
                   (eq? (tactical-op-plan-op-mode p-z-weak-regroup) 'regroup-stage))
              (format "coh=~a fog=~a (r=~a) clash=~a (r=~a) weak=~a"
                      (tactical-op-plan-local-cohesion-ratio p-z-spread-fog)
                      (tactical-op-plan-op-mode p-z-spread-fog)
                      (tactical-op-plan-eff-power-ratio p-z-spread-fog)
                      (tactical-op-plan-op-mode p-z-spread-clash)
                      (tactical-op-plan-eff-power-ratio p-z-spread-clash)
                      (tactical-op-plan-op-mode p-z-weak-regroup)))

  ;; 3p (Loop 88E Track 1): All 4 own-territory & retreat-latch physics invariants:
  ;;     (1) Queens stay in `main-cluster` / `local-cluster-val` when enemy is `<= 40t` of TH;
  ;;     (2) `own-territory-clash?` guards the full `<= 38t` TH approach band against `'retreat-regroup`;
  ;;     (3) Stale `pullback-active?` NEVER triggers `'retreat-regroup` on a winning mid-map clash
  ;;         (stays strictly `'regroup-stage` out-of-combat);
  ;;     (4) `'retreat-regroup` is NOT latched by 67f hysteresis (exits immediately on `'commit-push`).
  (define z-2ths (list (mk-th 31 'hatchery 32.0 32.0) (mk-th 32 'hatchery 56.0 32.0)))
  (define z-queens5-roaches4
    (append (for/list ([i (in-range 5)]) (mk-u (+ 1700 i) 'queen (+ 68.0 (* 0.4 i)) 34.0 #:hp 175.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 1710 i) 'roach (+ 72.0 (* 0.4 i)) 35.0 #:hp 145.0))))
  ;; Enemy approaching at `(88, 36)` (`32.2t` from Nat `(56, 32)`: `> 26t`, `<= 38t` & `<= 40t`)
  (define e-approach-32t
    (for/list ([i (in-range 10)]) (mk-u (+ 1720 i) 'marine (+ 88.0 (* 0.3 i)) 36.0 #:hp 55.0)))
  (define p-queen-retain
    (evaluate-tactical-operation
     #:frame 8600 #:race 'Zerg #:live-obs? #t
     #:combat-units z-queens5-roaches4 #:enemy-units e-approach-32t
     #:ally-buildings z-2ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2))
  ;; Outnumbered clash at `34.4t` from Nat `(56, 32)` (`<= 38t`) NEVER fires `'retreat-regroup`
  (define z-34t-small (for/list ([i (in-range 4)]) (mk-u (+ 1740 i) 'roach (+ 84.0 (* 0.4 i)) 52.0 #:hp 145.0)))
  (define e-34t-big (for/list ([i (in-range 14)]) (mk-u (+ 1750 i) 'roach (+ 90.0 (* 0.4 i)) 52.0 #:hp 145.0)))
  (define p-34t-no-ret
    (evaluate-tactical-operation
     #:frame 8620 #:race 'Zerg #:live-obs? #t
     #:combat-units z-34t-small #:enemy-units e-34t-big
     #:ally-buildings z-2ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:pullback-active? #t #:our-bases 2))
  ;; Winning mid-map clash (`(105, 105)` vs `(114, 105)`) with stale `pullback-active? = #t`
  ;; MUST commit `'commit-push` (NOT `'retreat-regroup`!), while out-of-combat stages `'regroup-stage`!
  (define mid-win-allies (for/list ([i (in-range 12)]) (mk-u (+ 1770 i) 'marauder (+ 105.0 (* 0.4 i)) 105.0 #:hp 125.0)))
  (define mid-small-en (for/list ([i (in-range 4)]) (mk-u (+ 1790 i) 'marine (+ 114.0 (* 0.4 i)) 105.0 #:hp 55.0)))
  (define p-pb-win
    (evaluate-tactical-operation
     #:frame 9200 #:race 'Terran #:live-obs? #t
     #:combat-units mid-win-allies #:enemy-units mid-small-en
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:pullback-active? #t #:our-bases 2))
  (define p-pb-ooc
    (evaluate-tactical-operation
     #:frame 9220 #:race 'Terran #:live-obs? #t
     #:combat-units mid-win-allies #:enemy-units '()
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:pullback-active? #t #:our-bases 2))
  ;; Hysteresis dwell MUST NOT trap `'retreat-regroup` when `cand-mode` returns to `'commit-push` 10f later!
  (define ret-hst (make-tactical-op-state))
  (define mid-lose-a (for/list ([i (in-range 4)]) (mk-u (+ 1800 i) 'stalker (+ 105.0 (* 0.4 i)) 105.0 #:hp 80.0 #:shield 80.0)))
  (define mid-win-e (for/list ([i (in-range 10)]) (mk-u (+ 1820 i) 'stalker (+ 114.0 (* 0.4 i)) 105.0 #:hp 80.0 #:shield 80.0)))
  (define p-ret-enter
    (evaluate-tactical-operation
     #:frame 9000 #:race 'Protoss #:live-obs? #t
     #:combat-units mid-lose-a #:enemy-units mid-win-e
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2 #:state ret-hst))
  ;; 10f later (inside 67f dwell), reinforcements make `ratio ~ 1.05` (below `+0.20` emergency override!)
  (define mid-reinf-a (for/list ([i (in-range 10)]) (mk-u (+ 1800 i) 'stalker (+ 105.0 (* 0.4 i)) 105.0 #:hp 80.0 #:shield 80.0)))
  (define p-ret-exit
    (evaluate-tactical-operation
     #:frame 9010 #:race 'Protoss #:live-obs? #t
     #:combat-units mid-reinf-a #:enemy-units '()
     #:owm-signals (owm-control-signals
                    2 2 2 #f #f #f #f 2 2 1400 300 9000 1800
                    40 0 4 4 0 0 0 #f #f #f 0.0 #f #f
                    18 1900 18 1900 0 #f #f 0 0 0 0 'MacroStandard)
     #:ally-buildings ally-ths #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
     #:our-bases 2 #:state ret-hst))
  (check-true "g3-loop88e-queen-retain-38t-guard-stale-pullback-and-zero-retreat-latch"
              (and (>= (tactical-op-plan-local-cluster-val p-queen-retain) 1100.0)
                   (not (eq? (tactical-op-plan-op-mode p-queen-retain) 'retreat-regroup))
                   (not (eq? (tactical-op-plan-op-mode p-34t-no-ret) 'retreat-regroup))
                   (eq? (tactical-op-plan-op-mode p-pb-win) 'commit-push)
                   (eq? (tactical-op-plan-op-mode p-pb-ooc) 'regroup-stage)
                   (eq? (tactical-op-plan-op-mode p-ret-enter) 'retreat-regroup)
                   (eq? (tactical-op-plan-op-mode p-ret-exit) 'commit-push))
              (format "qval=~a qm=~a 34t=~a pbw=~a pbo=~a re=~a rx=~a"
                      (tactical-op-plan-local-cluster-val p-queen-retain)
                      (tactical-op-plan-op-mode p-queen-retain)
                      (tactical-op-plan-op-mode p-34t-no-ret)
                      (tactical-op-plan-op-mode p-pb-win)
                      (tactical-op-plan-op-mode p-pb-ooc)
                      (tactical-op-plan-op-mode p-ret-enter)
                      (tactical-op-plan-op-mode p-ret-exit))))

;; =============================================================================
;; Group 4: `concave-positioning.rkt` All-Race Uphill, Per-Cluster Axis,
;;          In-Combat Concave & Defensive Pre-Arc Crescent
;; =============================================================================
(let ()
  ;; 4a. All-race uphill ramp hold works for Protoss, Terran AND Zerg; flat ground -> `#f`
  (define p-st (mk-u 1001 'stalker 70.0 50.0 #:z 8.0))
  (define t-ma (mk-u 1002 'marine 70.0 50.0 #:z 8.0))
  (define z-ro (mk-u 1003 'roach 70.0 50.0 #:z 8.0))
  (define high-tanks (list (mk-u 2001 'siege-tank-sieged 81.0 50.0 #:z 10.0 #:sieged #t)
                           (mk-u 2002 'marine 81.0 51.0 #:z 10.0)))
  (define flat-tanks (list (mk-u 2003 'siege-tank-sieged 81.0 50.0 #:z 8.0 #:sieged #t)
                           (mk-u 2004 'marine 81.0 51.0 #:z 8.0)))
  (define ctx-p-up (build-combat-positioning-context (list p-st) high-tanks))
  (define ctx-t-up (build-combat-positioning-context (list t-ma) high-tanks))
  (define ctx-z-up (build-combat-positioning-context (list z-ro) high-tanks))
  (define ctx-flat (build-combat-positioning-context (list p-st) flat-tanks))
  (define-values (px _py) (all-race-uphill-ramp-hold-pt ctx-p-up p-st))
  (define-values (tx _ty) (all-race-uphill-ramp-hold-pt ctx-t-up t-ma))
  (define-values (zx _zy) (all-race-uphill-ramp-hold-pt ctx-z-up z-ro))
  (define-values (fx _fy) (all-race-uphill-ramp-hold-pt ctx-flat p-st))
  (check-true "g4-all-race-uphill-ramp-brake"
              (and px tx zx (not fx) (< px 70.0) (< tx 70.0) (< zx 70.0))
              (format "px=~a tx=~a zx=~a fx=~a" px tx zx fx))

  ;; 4b. General uphill combat (`>= 2` Marines on high ground, 0 Tanks) holds without vision,
  ;;     releases cleanly when `#:high-ground-vision? #t`!
  (define high-bio (list (mk-u 2010 'marine 80.0 50.0 #:z 10.0)
                         (mk-u 2011 'marine 80.0 51.0 #:z 10.0)
                         (mk-u 2012 'marauder 80.0 49.0 #:z 10.0)))
  (define ctx-bio-up (build-combat-positioning-context (list p-st) high-bio))
  (define-values (bx-novis _by1) (all-race-uphill-ramp-hold-pt ctx-bio-up p-st #:high-ground-vision? #f))
  (define-values (bx-vis _by2) (all-race-uphill-ramp-hold-pt ctx-bio-up p-st #:high-ground-vision? #t))
  (check-true "g4-uphill-bio-holds-without-vision-releases-with-vision"
              (and bx-novis (not bx-vis))
              (format "novis=~a vis=~a" bx-novis bx-vis))

  ;; 4c. Per-cluster combat axis splits East vs North clashes cleanly
  (define ally-east (for/list ([i (in-range 4)]) (mk-u (+ 3000 i) 'marine 60.0 (+ 49.0 (* 0.5 i)))))
  (define ally-north (for/list ([i (in-range 4)]) (mk-u (+ 3100 i) 'marine (+ 109.0 (* 0.5 i)) 100.0)))
  (define en-east (list (mk-u 3201 'stalker 72.0 50.0) (mk-u 3202 'stalker 72.0 51.0)))
  (define en-north (list (mk-u 3301 'stalker 110.0 112.0) (mk-u 3302 'stalker 111.0 112.0)))
  (define ctx-dual (build-combat-positioning-context (append ally-east ally-north)
                                                     (append en-east en-north)))
  (define-values (_e1x _e1y f1x f1y _p1x _p1y) (compute-local-cluster-axis ctx-dual 60.0 50.0))
  (define-values (_e2x _e2y f2x f2y _p2x _p2y) (compute-local-cluster-axis ctx-dual 110.0 100.0))
  (check-true "g4-per-cluster-axis-distinct-fronts"
              (and (> f1x 0.90) (< (abs f1y) 0.25)
                   (> f2y 0.90) (< (abs f2x) 0.25))
              (format "east=(~a,~a) north=(~a,~a)" f1x f1y f2x f2y))

  ;; 4d. In-combat concave widens ONLY genuinely body-blocked back-row units between shots
  ;;     (`wcd = 0.45`), NEVER scatters clean single-row squads (`l80b`), and NEVER cancels ready shots!
  (define en-line (for/list ([i (in-range 4)]) (mk-u (+ 4000 i) 'marine 80.0 (+ 49.0 (* 0.5 i)))))
  (define st-single-row-cd
    (for/list ([i (in-range 6)]) (mk-u (+ 4050 i) 'stalker 75.5 (+ 49.5 (* 0.15 i)) #:w-cd 0.45)))
  (define ctx-single-cd (build-combat-positioning-context st-single-row-cd en-line))
  (define single-row-pts
    (filter values
            (for/list ([u (in-list st-single-row-cd)])
              (define-values (ax ay) (compute-in-combat-concave-step-pt ctx-single-cd u 80.0 50.0 6.0))
              (and ax ay (cons ax ay)))))
  (define st-two-row-cd
    (append (for/list ([i (in-range 3)]) (mk-u (+ 4100 i) 'stalker 76.5 (+ 49.5 (* 0.4 i)) #:w-cd 0.45))
            (for/list ([i (in-range 3)]) (mk-u (+ 4110 i) 'stalker 74.5 (+ 49.5 (* 0.4 i)) #:w-cd 0.45))))
  (define st-two-row-ready
    (append (for/list ([i (in-range 3)]) (mk-u (+ 4200 i) 'stalker 76.5 (+ 49.5 (* 0.4 i)) #:w-cd 0.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 4210 i) 'stalker 74.5 (+ 49.5 (* 0.4 i)) #:w-cd 0.0))))
  (define ctx-ic-cd (build-combat-positioning-context st-two-row-cd en-line))
  (define ctx-ic-rd (build-combat-positioning-context st-two-row-ready en-line))
  (define ic-cd-pts
    (filter values
            (for/list ([u (in-list st-two-row-cd)])
              (define-values (ax ay) (compute-in-combat-concave-step-pt ctx-ic-cd u 80.0 50.0 6.0))
              (and ax ay (cons ax ay)))))
  (define ic-rd-pts
    (filter values
            (for/list ([u (in-list st-two-row-ready)])
              (define-values (ax ay) (compute-in-combat-concave-step-pt ctx-ic-rd u 80.0 50.0 6.0))
              (and ax ay (cons ax ay)))))
  (check-true "g4-in-combat-concave-widens-body-blocked-backrow-preserves-frontrow-and-ready"
              (and (null? single-row-pts)
                   (>= (length ic-cd-pts) 1)
                   (null? ic-rd-pts))
              (format "single=~a cd-cnt=~a rd-cnt=~a"
                      (length single-row-pts) (length ic-cd-pts) (length ic-rd-pts)))

  ;; 4e. Defensive pre-arc crescent layers frontliners ahead of ranged ahead of casters
  (define pre-z (mk-u 5001 'zealot 50.0 32.0))
  (define pre-s (mk-u 5002 'stalker 50.0 32.0))
  (define pre-ht (mk-u 5003 'high-templar 50.0 32.0))
  (define-values (zax _zay)
    (compute-defensive-pre-arc-pt #f pre-z #:anchor-x 56.0 #:anchor-y 32.0
                                  #:facing-x 100.0 #:facing-y 32.0 #:slot-index 4 #:slot-total 9))
  (define-values (sax _say)
    (compute-defensive-pre-arc-pt #f pre-s #:anchor-x 56.0 #:anchor-y 32.0
                                  #:facing-x 100.0 #:facing-y 32.0 #:slot-index 4 #:slot-total 9))
  (define-values (hax _hay)
    (compute-defensive-pre-arc-pt #f pre-ht #:anchor-x 56.0 #:anchor-y 32.0
                                  #:facing-x 100.0 #:facing-y 32.0 #:slot-index 4 #:slot-total 9))
  (check-true "g4-defensive-pre-arc-front-to-back-layering"
              (and zax sax hax (> zax sax) (> sax hax))
              (format "zealot-x=~a stalker-x=~a ht-x=~a" zax sax hax)))

;; =============================================================================
;; Group 5: `multiprong-coordinator.rkt` Decoupled Bounded (<= 15%) Delay Harass
;; =============================================================================
(let ()
  (define ally-ths (list (mk-th 1 'nexus 32.0 32.0) (mk-th 2 'nexus 56.0 32.0)))
  (define enemy-ths (list (mk-th 10 'command-center 155.0 155.0)
                          (mk-th 11 'command-center 125.0 155.0)
                          (mk-th 12 'command-center 155.0 110.0)))
  ;; 14 Zealots + 10 Stalkers = 48 supply staging at Natural `(56, 32)`
  (define our-army
    (append (for/list ([i (in-range 14)]) (mk-u (+ 6000 i) 'zealot (+ 54.0 (* 0.3 i)) 34.0))
            (for/list ([i (in-range 10)]) (mk-u (+ 6100 i) 'stalker (+ 52.0 (* 0.3 i)) 30.0))))
  ;; Enemy army parked near `(120, 145)` (`>= 30t` from exposed 3rd at `(155, 110)`)
  (define far-enemies
    (for/list ([i (in-range 16)]) (mk-u (+ 6500 i) 'marine (+ 118.0 (* 0.3 i)) 145.0)))

  ;; 5a. Legacy `#:delay-harass-allowed? #f` under `combat-suppress-attack? = #t` stays `'inactive`
  (define st-off (make-multiprong-state))
  (define res-off
    (step-multiprong-coordinator!
     st-off #:frame 7200 #:live-obs? #t #:race 'Protoss
     #:ally-units our-army #:combat-units our-army #:ally-townhalls ally-ths
     #:enemy-units far-enemies #:enemy-townhalls enemy-ths
     #:base-x 32.0 #:base-y 32.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:combat-suppress-attack? #t #:delay-harass-allowed? #f))
  (check-true "g5-legacy-suppress-blocks-backstab"
              (eq? (multiprong-result-mode res-off) 'inactive)
              (format "mode=~a" (multiprong-result-mode res-off)))

  ;; 5b. Decoupled `#:delay-harass-allowed? #t` under `combat-suppress-attack? = #t`
  ;;     launches bounded (`<= 15%` supply!) harass while leaving `>= 85%` army untouched!
  (define st-on (make-multiprong-state))
  (define res-on
    (step-multiprong-coordinator!
     st-on #:frame 7200 #:live-obs? #t #:race 'Protoss
     #:ally-units our-army #:combat-units our-army #:ally-townhalls ally-ths
     #:enemy-units far-enemies #:enemy-townhalls enemy-ths
     #:base-x 32.0 #:base-y 32.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:combat-suppress-attack? #t #:delay-harass-allowed? #t))
  (define claimed-cnt (set-count (multiprong-result-handled-tags res-on)))
  (define claimed-sup (* 2.0 claimed-cnt))
  (check-true "g5-delay-harass-runs-bounded-15pct-while-holding"
              (and (memq (multiprong-result-mode res-on) '(counter-backstab offensive-rotate))
                   (>= claimed-cnt 2)
                   (<= claimed-sup (* 0.16 48.0)))
              (format "mode=~a claimed=~a sup=~a/48"
                      (multiprong-result-mode res-on) claimed-cnt claimed-sup))

  ;; 5c. Active engaged home-defense battle STRICTLY blocks delay harass even when `#t`!
  (define home-clash-enemies
    (for/list ([i (in-range 12)]) (mk-u (+ 6800 i) 'marine (+ 62.0 (* 0.3 i)) 34.0)))
  (define st-hdef (make-multiprong-state))
  (define res-hdef
    (step-multiprong-coordinator!
     st-hdef #:frame 7200 #:live-obs? #t #:race 'Protoss
     #:ally-units our-army #:combat-units our-army #:ally-townhalls ally-ths
     #:enemy-units home-clash-enemies #:enemy-townhalls enemy-ths
     #:base-x 32.0 #:base-y 32.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:combat-suppress-attack? #t #:delay-harass-allowed? #t))
  (check-true "g5-active-home-defense-blocks-delay-harass"
              (not (memq (multiprong-result-mode res-hdef) '(counter-backstab offensive-rotate)))
              (format "mode=~a" (multiprong-result-mode res-hdef))))

(printf "l88-tactical-operation-and-concave-test: ~a/~a passed (~a failed)\n"
        pass-cnt (+ pass-cnt fail-cnt) fail-cnt)
(when (> fail-cnt 0) (exit 1))
