#lang racket/base

;; =============================================================================
;; Loop 88A Track 2 Verification Suite:
;;   1. Compiled Pro-Corpus Matchup Curves (`lib/plan/pro-curves.rkt`)
;;   2. Declarative Pro-Backed Macro Game Plan + 7-Dim OWM (`lib/plan/macro-game-plan.rkt`)
;;   3. Time-Horizon Slack Escrow, Zeno's-Paradox Guard, Closed-Loop Flow Balance,
;;      Forward In-Progress Tech Lookahead & Physical Refusals (`lib/econ/escrow-engine.rkt`)
;;   4. End-to-End `step-priority-macro-brain` Integration & Exported Accessors
;; =============================================================================

(require racket/list
         "../lib/plan/pro-curves.rkt"
         "../lib/plan/macro-game-plan.rkt"
         "../lib/econ/escrow-engine.rkt"
         "../lib/opponent-world-model.rkt"
         "../lib/build-orders/cheese.rkt"
         "../lib/priority-macro-brain.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check! cond-val msg)
  (if cond-val
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL: ~a\n" msg))))

;; -----------------------------------------------------------------------------
;; 1. Pro-Corpus Matchup Curves (`lib/plan/pro-curves.rkt`)
;; -----------------------------------------------------------------------------
(let ()
  (define all-matchups
    '((Protoss . Protoss) (Protoss . Terran) (Protoss . Zerg)
      (Terran  . Protoss) (Terran  . Terran) (Terran  . Zerg)
      (Zerg    . Protoss) (Zerg    . Terran) (Zerg    . Zerg)))
  (check! (andmap (lambda (m)
                    (define c (lookup-pro-matchup-curve (car m) (cdr m)))
                    (and (pro-matchup-curve? c)
                         (> (pro-natural-frame (car m) (cdr m)) 0)
                         (> (pro-third-frame (car m) (cdr m))
                            (pro-natural-frame (car m) (cdr m)))))
                  all-matchups)
          "1a. All 9 Pro matchup curves must exist with positive natural < third timings")

  (define (sec->f s) (inexact->exact (round (* s SC2-FRAMES-PER-SEC))))
  (define zvp-2m (pro-target-workers-at 'Zerg 'Protoss (sec->f 120)))
  (define zvp-4m (pro-target-workers-at 'Zerg 'Protoss (sec->f 240)))
  (define zvp-6m (pro-target-workers-at 'Zerg 'Protoss (sec->f 360)))
  (define zvp-8m (pro-target-workers-at 'Zerg 'Protoss (sec->f 480)))
  (define tvp-6m (pro-target-workers-at 'Terran 'Protoss (sec->f 360)))
  (check! (and (< zvp-2m zvp-4m zvp-6m zvp-8m)
               (> zvp-6m tvp-6m)
               (>= (pro-target-bases-at 'Zerg 'Protoss (sec->f 360)) 3)
               (> (pro-target-army-supply-at 'Terran 'Zerg (sec->f 480))
                  (pro-target-army-supply-at 'Terran 'Zerg (sec->f 240))))
          (format "1b. Pro curve interpolation monotone & Zerg econ lead failed: z2=~a z4=~a z6=~a z8=~a t6=~a"
                  zvp-2m zvp-4m zvp-6m zvp-8m tvp-6m))

  (define tvt-g (pro-gas-worker-thresholds 'Terran 'Terran))
  (define pvz-g (pro-gas-worker-thresholds 'Protoss 'Zerg))
  (check! (and (>= (length tvt-g) 4)
               (<= (car tvt-g) 20)
               (< (car tvt-g) (cadr tvt-g))
               (< (cadr pvz-g) (list-ref pvz-g 3)))
          (format "1c. Pro gas worker thresholds must increase cleanly with geyser count: tvt=~s pvz=~s"
                  tvt-g pvz-g)))

;; -----------------------------------------------------------------------------
;; 2. Declarative Macro Game Plan + All 7 Calibrated OWM Dimensions
;; -----------------------------------------------------------------------------
(let ()
  ;; Build a live opponent-world-model & summary via `step-opponent-world-model!`
  (define owm (make-opponent-world-model 'Protoss))
  (define raw-sum
    (step-opponent-world-model!
     owm
     (hasheq 'frame 6720 'enemy-race 'Protoss 'enemy-main-x 160.0 'enemy-main-y 160.0)))
  ;; Construct a calibrated 35-field summary with all 7 dims active
  (define active-owm-sum
    (struct-copy opponent-world-summary raw-sum
                 [confirmed-bases 2]
                 [happy-expected-bases 3]
                 [stopped-expanding? #t]
                 [confirmed-geysers 4]
                 [estimated-workers 42.0]
                 [production-facility-count 6]
                 [unaccounted-minerals 650.0]
                 [unaccounted-gas 320.0]
                 [hidden-gas-tech-risk? #t]
                 [believed-total-army-supply 46.0]
                 [believed-total-army-value 2400.0]
                 [enemy-siege-or-turtle-count 0]))

  ;; 2a: Terran reads ALL 7 OWM dimensions & reacts to believed-enemy-army (L6661 lifted!)
  (define t-plan
    (build-macro-game-plan
     #:race 'Terran #:enemy-race 'Protoss #:frame 6720
     #:workers 38 #:active-bases 2 #:total-bases 2
     #:army-supply 20 #:enemy-threat-supply 0 #:under-attack? #f
     #:enemy-unit-counts (hasheq 'stalker 8 'immortal 2)
     #:enemy-building-counts (hasheq 'gateway 5 'robotics-facility 1)
     #:ready-bldg-counts (hasheq 'orbital-command 2 'barracks 3 'factory 1 'starport 1 'refinery 2)
     #:total-bldg-counts (hasheq 'orbital-command 2 'barracks 3 'factory 1 'starport 1 'refinery 2)
     #:unit-counts (hasheq 'scv 38 'marine 14 'marauder 3)
     #:owm-summary active-owm-sum
     #:mirror-signals (hasheq 'mirror-enemy-upgrade-advantage 1.0 'rush-prob 0.1)))

  (define sigs (macro-game-plan-owm-signals-used t-plan))
  (define addons (macro-game-plan-desired-addons t-plan))
  (check! (and (eq? (hash-ref sigs 'has-owm?) #t)
               (= (hash-ref sigs 'estimated-bases) 2)
               (eq? (hash-ref sigs 'stopped-expanding?) #t)
               (eq? (hash-ref sigs 'hidden-gas-tech-risk?) #t)
               (>= (hash-ref sigs 'unaccounted-gas) 300.0)
               (>= (hash-ref sigs 'enemy-prod-count) 6)
               (>= (hash-ref sigs 'believed-army-supply) 45.0)
               (>= (hash-ref sigs 'enemy-upgrade-advantage) 1.0))
          (format "2a. All 7 OWM dimensions must flow into macro-game-plan: ~s" sigs))

  (check! (and (eq? (macro-game-plan-posture t-plan) 'counter-timing)
               (> (macro-game-plan-army-parity-floor t-plan) 35.0)
               (eq? (macro-game-plan-army-deficit? t-plan) #t)
               (eq? (macro-game-plan-upgrade-catchup-urgent? t-plan) #t)
               (eq? (macro-game-plan-tech-defense-urgent? t-plan) #t))
          (format "2b. Terran must lift L6661 army deficit + upgrade/tech urgency from OWM: posture=~a floor=~a def=~a upg=~a tech=~a"
                  (macro-game-plan-posture t-plan)
                  (macro-game-plan-army-parity-floor t-plan)
                  (macro-game-plan-army-deficit? t-plan)
                  (macro-game-plan-upgrade-catchup-urgent? t-plan)
                  (macro-game-plan-tech-defense-urgent? t-plan)))

  (check! (and (eq? (hash-ref addons 'factory-techlab?) #t)
               (>= (hash-ref addons 'factory-techlab-count) 1)
               (eq? (hash-ref addons 'starport-techlab?) #t)
               (>= (hash-ref addons 'starport-techlab-count) 1))
          (format "2c. Goal-driven Terran addon exposure vs armored + hidden gas tech failed: ~s" addons))

  ;; 2d: Protoss also lifts L6661 army parity deficit from OWM!
  (define p-plan
    (build-macro-game-plan
     #:race 'Protoss #:enemy-race 'Terran #:frame 7200
     #:workers 40 #:active-bases 2 #:total-bases 2
     #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
     #:enemy-unit-counts (hasheq 'marine 10 'marauder 4)
     #:ready-bldg-counts (hasheq 'nexus 2 'gateway 4 'robotics-facility 1 'assimilator 3)
     #:total-bldg-counts (hasheq 'nexus 2 'gateway 4 'robotics-facility 1 'assimilator 3)
     #:owm-summary active-owm-sum))
  (check! (and (eq? (macro-game-plan-army-deficit? p-plan) #t)
               (> (macro-game-plan-army-parity-floor p-plan) 35.0))
          (format "2d. Protoss must also enforce OWM believed-army parity deficit: floor=~a def=~a"
                  (macro-game-plan-army-parity-floor p-plan)
                  (macro-game-plan-army-deficit? p-plan)))

  ;; 2e: Version C cheese integration preserves cheese worker & base caps
  (define c-spec (lookup-cheese-build-spec 'tvt-proxy-2rax-reaper))
  (define c-plan
    (build-macro-game-plan
     #:race 'Terran #:enemy-race 'Terran #:frame 3000
     #:workers 18 #:active-bases 1 #:total-bases 1
     #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
     #:cheese-spec c-spec))
  (check! (and (eq? (macro-game-plan-cheese-active? c-plan) #t)
               (eq? (macro-game-plan-posture c-plan) 'cheese-commit)
               (= (macro-game-plan-worker-target-cap c-plan) (cheese-build-spec-worker-cap c-spec))
               (= (macro-game-plan-target-bases c-plan) (cheese-build-spec-max-bases c-spec)))
          (format "2e. Version C cheese spec must govern worker/base caps: cap=~a bases=~a posture=~a"
                  (macro-game-plan-worker-target-cap c-plan)
                  (macro-game-plan-target-bases c-plan)
                  (macro-game-plan-posture c-plan))))

;; -----------------------------------------------------------------------------
;; 3. Time-Horizon Slack Escrow, Zeno's Paradox Guard, Refusals & Flow Balance
;; -----------------------------------------------------------------------------
(let ()
  ;; 3a: Gas-bound Colossus (`300M/200G` at `350M/40G`, 2 Assimilators = 5.4 G/s, 30 min harv = 29 M/s):
  ;;     t_gas = 29.6s (gas-bound!), m-slack > 800M, g-slack = 0 -> allows disjoint 0-gas Probe/Zealot,
  ;;     strictly blocks gas-spending Stalker (50G) and same-slot Immortal!
  (define-values (p-mr p-gr)
    (compute-live-income-rates 30 6 36 (hasheq 'nexus 2 'assimilator 2) 'Protoss))
  (define col-slack
    (compute-escrow-slack
     #:item-sym 'colossus #:item-min-cost 300 #:item-gas-cost 200 #:tier 'T1
     #:rem-min 350 #:rem-gas 40 #:m-rate-sec p-mr #:g-rate-sec p-gr))
  (check! (and (escrow-slack-result-should-escrow? col-slack)
               (escrow-slack-result-gas-bound? col-slack)
               (> (escrow-slack-result-mineral-slack col-slack) 500.0)
               (= (escrow-slack-result-gas-slack col-slack) 0.0)
               (escrow-allows-disjoint-spend? col-slack
                 #:a-slot 'robotics-facility #:a-tier 'T1 #:a-cat 'combat-unit
                 #:b-slot 'townhall #:b-cat 'worker #:b-min-cost 50 #:b-gas-cost 0
                 #:m-rate-sec p-mr #:rem-min 350 #:rem-gas 40)
               (escrow-allows-disjoint-spend? col-slack
                 #:a-slot 'robotics-facility #:a-tier 'T1 #:a-cat 'combat-unit
                 #:b-slot 'gateway #:b-cat 'combat-unit #:b-min-cost 100 #:b-gas-cost 0
                 #:m-rate-sec p-mr #:rem-min 350 #:rem-gas 40)
               (not (escrow-allows-disjoint-spend? col-slack
                      #:a-slot 'robotics-facility #:a-tier 'T1 #:a-cat 'combat-unit
                      #:b-slot 'gateway #:b-cat 'combat-unit #:b-min-cost 125 #:b-gas-cost 50
                      #:m-rate-sec p-mr #:rem-min 350 #:rem-gas 40))
               (not (escrow-allows-disjoint-spend? col-slack
                      #:a-slot 'robotics-facility #:a-tier 'T1 #:a-cat 'combat-unit
                      #:b-slot 'robotics-facility #:b-cat 'combat-unit #:b-min-cost 250 #:b-gas-cost 0
                      #:m-rate-sec p-mr #:rem-min 350 #:rem-gas 40)))
          (format "3a. Gas-bound Colossus zero-delay slack contract failed: ~s" col-slack))

  ;; 3b: Zeno's Paradox Guard (`T_fund <= 3.5s`):
  ;;     Medivac (`100M/100G`) at `74M/180G` with 17 mineral SCVs (~16.4 M/s) -> T_fund = 1.58s <= 3.5s
  ;;     MUST block 50M SCV! Whereas at 60M/50G (T_fund = 11.1s > 3.5s), SCV trains cleanly!
  (define-values (t-mr t-gr)
    (compute-live-income-rates 17 5 22 (hasheq 'command-center 1 'refinery 2) 'Terran))
  (define med-near
    (compute-escrow-slack
     #:item-sym 'medivac #:item-min-cost 100 #:item-gas-cost 100 #:tier 'T2
     #:rem-min 74 #:rem-gas 180 #:m-rate-sec t-mr #:g-rate-sec t-gr))
  (define med-far
    (compute-escrow-slack
     #:item-sym 'medivac #:item-min-cost 100 #:item-gas-cost 100 #:tier 'T2
     #:rem-min 60 #:rem-gas 50 #:m-rate-sec t-mr #:g-rate-sec t-gr))
  (check! (and (escrow-slack-result-near-ready? med-near)
               (not (escrow-allows-disjoint-spend? med-near
                      #:a-slot 'starport #:a-tier 'T2 #:a-cat 'combat-unit
                      #:b-slot 'townhall #:b-cat 'worker #:b-min-cost 50 #:b-gas-cost 0
                      #:m-rate-sec t-mr #:rem-min 74 #:rem-gas 180))
               (not (escrow-slack-result-near-ready? med-far))
               (escrow-allows-disjoint-spend? med-far
                 #:a-slot 'starport #:a-tier 'T2 #:a-cat 'combat-unit
                 #:b-slot 'townhall #:b-cat 'worker #:b-min-cost 50 #:b-gas-cost 0
                 #:m-rate-sec t-mr #:rem-min 60 #:rem-gas 50))
          (format "3b. Zeno's-Paradox 3.5s guard failed: near=~s far=~s" med-near med-far))

  ;; 3c: Horizon cutoff + Closed-loop Physical Refusal (hash & raw wire tuple formats)
  (define unfundable-col
    (compute-escrow-slack
     #:item-sym 'colossus #:item-min-cost 300 #:item-gas-cost 200 #:tier 'T1
     #:rem-min 400 #:rem-gas 0 #:m-rate-sec 20.0 #:g-rate-sec 2.7))
  (define refused-spire-hash
    (compute-escrow-slack
     #:item-sym 'spire #:item-min-cost 200 #:item-gas-cost 200 #:tier 'T0
     #:rem-min 2787 #:rem-gas 180 #:m-rate-sec 30.0 #:g-rate-sec 8.1
     #:frame 9000 #:physical-refusals (hasheq 'spire (cons 'no-creep 9112))))
  (define refused-spire-wire
    (compute-escrow-slack
     #:item-sym 'spire #:item-min-cost 200 #:item-gas-cost 200 #:tier 'T0
     #:rem-min 2787 #:rem-gas 180 #:m-rate-sec 30.0 #:g-rate-sec 8.1
     #:frame 9050 #:physical-refusals (list (list 'spire 'no-creep 9000))))
  (define expired-refusal
    (refusal-active? (list (list 'spire 'no-creep 9000)) 'spire 9200))
  (check! (and (not (escrow-slack-result-should-escrow? unfundable-col))
               (not (escrow-slack-result-should-escrow? refused-spire-hash))
               (not (escrow-slack-result-should-escrow? refused-spire-wire))
               (not expired-refusal))
          (format "3c. Horizon cutoff & physical refusal checks failed: unfund=~s h=~s w=~s exp=~s"
                  unfundable-col refused-spire-hash refused-spire-wire expired-refusal))

  ;; 3d: Forward In-Progress Tech Lookahead (<= 25s Spire pre-banks gas & boosts G*)
  (define-values (fm-near fg-near fres-near)
    (compute-forward-tech-demand (hasheq 'spire 10.0)))
  (define-values (fm-far fg-far fres-far)
    (compute-forward-tech-demand (hasheq 'spire 45.0)))
  (check! (and (> fm-near 100.0) (> fg-near 150.0) (>= fres-near 70)
               (= fm-far 0.0) (= fg-far 0.0) (= fres-far 0))
          (format "3d. Forward tech lookahead failed: near=(~a ~a ~a) far=(~a ~a ~a)"
                  fm-near fg-near fres-near fm-far fg-far fres-far))

  ;; 3e: Closed-Loop Flow Balance: 1-Refinery Terran w/ Factory+FTL+Starport demands Refinery #2,
  ;;     and completing Spire boosts desired-gas-workers & sat-kwargs match Track 1 contract!
  (define t-1ref-plan
    (build-macro-game-plan
     #:race 'Terran #:enemy-race 'Terran #:frame 5400
     #:workers 26 #:active-bases 2 #:total-bases 2
     #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-bldg-counts (hasheq 'orbital-command 2 'barracks 2 'factory 1 'factory-techlab 1 'starport 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 2 'barracks 2 'factory 1 'factory-techlab 1 'starport 1 'refinery 1)))
  (define t-1ref-flow
    (compute-flow-balance
     #:plan t-1ref-plan #:race 'Terran #:minerals 220 #:gas 40 #:workers 26
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 23 #:gas-harvesters 3
     #:ready-bldg-counts (hasheq 'orbital-command 2 'barracks 2 'factory 1 'factory-techlab 1 'starport 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 2 'barracks 2 'factory 1 'factory-techlab 1 'starport 1 'refinery 1)))
  (define sat-kw (escrow-flow-report->sat-kwargs t-1ref-flow))
  (check! (and (escrow-flow-report-need-more-gas-geysers? t-1ref-flow)
               (> (hash-ref sat-kw 'mineral-demand-rate) 0.0)
               (> (hash-ref sat-kw 'gas-demand-rate) 0.0)
               (exact-nonnegative-integer? (hash-ref sat-kw 'desired-gas-workers)))
          (format "3e. 1-Refinery Terran Factory+Starport must trigger need-more-gas-geysers? & valid sat-kwargs: flow=~s kw=~s"
                  t-1ref-flow sat-kw))

  ;; 3f (Loop 88B): Early Terran with 1 Refinery + 140G (bare Barracks + bare Factory,
  ;;     saving for Starport/FactoryTechLab/SiegeTank) MUST keep desired-gas-workers >= 3
  ;;     (NEVER 0!), 2 Refineries @155G w/ FTL in progress keeps >= 4, and genuine 900G
  ;;     gas overflow cleanly pulls back to 0!
  (define t-early-plan
    (build-macro-game-plan
     #:race 'Terran #:enemy-race 'Terran #:frame 4032
     #:workers 22 #:active-bases 2 #:total-bases 2
     #:army-supply 6 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)))
  (define t-early-1ref-140g
    (compute-flow-balance
     #:plan t-early-plan #:race 'Terran #:minerals 120 #:gas 140 #:workers 22
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 19 #:gas-harvesters 3
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)))
  (define t-early-2ref-155g
    (compute-flow-balance
     #:plan t-early-plan #:race 'Terran #:minerals 100 #:gas 155 #:workers 24
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 18 #:gas-harvesters 6
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 2)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'factory-techlab 1 'refinery 2)))
  (define t-overflow-900g
    (compute-flow-balance
     #:plan t-early-plan #:race 'Terran #:minerals 50 #:gas 900 #:workers 24
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 18 #:gas-harvesters 6
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 2)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 2)))
  (check! (and (>= (escrow-flow-report-desired-gas-workers t-early-1ref-140g) 3)
               (>= (escrow-flow-report-desired-gas-workers t-early-2ref-155g) 4)
               (= (escrow-flow-report-desired-gas-workers t-overflow-900g) 0))
          (format "3f. Loop 88B flow-gas G* must stay >=3 at 1ref/140G & >=4 at 2ref/155G, pulling to 0 only on overflow; 1ref=~a 2ref=~a ovf=~a"
                  (escrow-flow-report-desired-gas-workers t-early-1ref-140g)
                  (escrow-flow-report-desired-gas-workers t-early-2ref-155g)
                  (escrow-flow-report-desired-gas-workers t-overflow-900g)))

  ;; 3g (Loop 88C): 30s horizon + active-escrow-gas-floor-only working buffer eliminates
  ;;     double-counted 90s gas hoarding: early 140G saving with escrow floor=100 keeps >=3,
  ;;     1-base 44M/336G releases gas workers to 0 for Natural CC, and 3-base 93M/808G
  ;;     (even with Tank 125G escrow floor) drops to 0 while normal 150M/80G keeps >=12!
  (define t-early-1ref-esc100
    (compute-flow-balance
     #:plan t-early-plan #:race 'Terran #:minerals 120 #:gas 140 #:workers 22
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 19 #:gas-harvesters 3
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:active-escrow-gas-floor 100))
  (define t-1b-float-336g
    (compute-flow-balance
     #:plan (build-macro-game-plan
             #:race 'Terran #:enemy-race 'Protoss #:frame 5400
             #:workers 22 #:active-bases 1 #:total-bases 1
             #:army-supply 10 #:enemy-threat-supply 0 #:under-attack? #f
             #:ready-bldg-counts (hasheq 'orbital-command 1 'barracks 2 'factory 1 'refinery 2)
             #:total-bldg-counts (hasheq 'orbital-command 1 'barracks 2 'factory 1 'refinery 2))
     #:race 'Terran #:minerals 44 #:gas 336 #:workers 22
     #:active-bases 1 #:total-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
     #:ready-bldg-counts (hasheq 'orbital-command 1 'barracks 2 'factory 1 'refinery 2)
     #:total-bldg-counts (hasheq 'orbital-command 1 'barracks 2 'factory 1 'refinery 2)))
  (define t-3b-bldg
    (hasheq 'orbital-command 3 'barracks 5 'barracks-techlab 2 'barracks-reactor 3
            'factory 2 'factory-techlab 2 'starport 1 'refinery 6))
  (define t-3b-plan
    (build-macro-game-plan
     #:race 'Terran #:enemy-race 'Terran #:frame 16000
     #:workers 60 #:active-bases 3 #:total-bases 3
     #:army-supply 60 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-bldg-counts t-3b-bldg #:total-bldg-counts t-3b-bldg))
  (define t-3b-float-808g
    (compute-flow-balance
     #:plan t-3b-plan #:race 'Terran #:minerals 93 #:gas 808 #:workers 60
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 42 #:gas-harvesters 18
     #:ready-bldg-counts t-3b-bldg #:total-bldg-counts t-3b-bldg
     #:active-escrow-gas-floor 125))
  (define t-3b-float-348g
    (compute-flow-balance
     #:plan t-3b-plan #:race 'Terran #:minerals 93 #:gas 348 #:workers 54
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
     #:ready-bldg-counts t-3b-bldg #:total-bldg-counts t-3b-bldg
     #:active-escrow-gas-floor 125))
  (define t-3b-normal-80g
    (compute-flow-balance
     #:plan t-3b-plan #:race 'Terran #:minerals 150 #:gas 80 #:workers 54
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
     #:ready-bldg-counts t-3b-bldg #:total-bldg-counts t-3b-bldg))
  (check! (and (>= (escrow-flow-report-desired-gas-workers t-early-1ref-esc100) 3)
               (= (escrow-flow-report-desired-gas-workers t-1b-float-336g) 0)
               (= (escrow-flow-report-desired-gas-workers t-3b-float-808g) 0)
               (<= (escrow-flow-report-desired-gas-workers t-3b-float-348g) 9)
               (>= (escrow-flow-report-desired-gas-workers t-3b-normal-80g) 12))
          (format "3g. Loop 88C 30s flow-gas G* failed: early100=~a 1b336=~a 3b808=~a 3b348=~a 3b80=~a"
                  (escrow-flow-report-desired-gas-workers t-early-1ref-esc100)
                  (escrow-flow-report-desired-gas-workers t-1b-float-336g)
                  (escrow-flow-report-desired-gas-workers t-3b-float-808g)
                  (escrow-flow-report-desired-gas-workers t-3b-float-348g)
                  (escrow-flow-report-desired-gas-workers t-3b-normal-80g)))

  ;; 3h (Loop 88D): Exact per-addon `fac-g` + Mineral-Feasible Gas Burn Coupling:
  ;;     Terran 3-Fac w/ only 1 TL @30M/350G (and @30M/503G w/ 125G escrow) drives G* -> 0,
  ;;     Zerg 4-Hatch (RW+HD) @30M/350G & 3-Hatch (RW-only) @10M/240G drive G* -> 0,
  ;;     while normal Zerg @200M/80G keeps >= 10 & early Terran 120M/140G w/ esc=125 keeps >= 3!
  (define t-3fac1tl-bldg
    (hasheq 'orbital-command 3 'barracks 4 'barracks-techlab 1 'barracks-reactor 2
            'factory 3 'factory-techlab 1 'starport 1 'refinery 4))
  (define t-3fac1tl-plan
    (build-macro-game-plan
     #:race 'Terran #:enemy-race 'Protoss #:frame 11000
     #:workers 46 #:active-bases 3 #:total-bases 3
     #:army-supply 36 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-bldg-counts t-3fac1tl-bldg #:total-bldg-counts t-3fac1tl-bldg))
  (define t-3fac-30m-350g
    (compute-flow-balance
     #:plan t-3fac1tl-plan #:race 'Terran #:minerals 30 #:gas 350 #:workers 46
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 34 #:gas-harvesters 12
     #:ready-bldg-counts t-3fac1tl-bldg #:total-bldg-counts t-3fac1tl-bldg))
  (define t-3fac-30m-503g-esc
    (compute-flow-balance
     #:plan t-3fac1tl-plan #:race 'Terran #:minerals 30 #:gas 503 #:workers 46
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 34 #:gas-harvesters 12
     #:ready-bldg-counts t-3fac1tl-bldg #:total-bldg-counts t-3fac1tl-bldg
     #:active-escrow-gas-floor 125))
  (define z-4h-bldg
    (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 4))
  (define z-4h-plan
    (build-macro-game-plan
     #:race 'Zerg #:enemy-race 'Protoss #:frame 10000
     #:workers 52 #:active-bases 3 #:total-bases 4
     #:army-supply 30 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-bldg-counts z-4h-bldg #:total-bldg-counts z-4h-bldg))
  (define z-4h-30m-350g
    (compute-flow-balance
     #:plan z-4h-plan #:race 'Zerg #:minerals 30 #:gas 350 #:workers 52
     #:active-bases 3 #:total-bases 4 #:mineral-harvesters 40 #:gas-harvesters 12
     #:ready-bldg-counts z-4h-bldg #:total-bldg-counts z-4h-bldg))
  (define z-3h-rw-bldg
    (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 4))
  (define z-3h-rw-10m-240g
    (compute-flow-balance
     #:plan (build-macro-game-plan
             #:race 'Zerg #:enemy-race 'Protoss #:frame 8000
             #:workers 36 #:active-bases 3 #:total-bases 3
             #:army-supply 20 #:enemy-threat-supply 0 #:under-attack? #f
             #:ready-bldg-counts z-3h-rw-bldg #:total-bldg-counts z-3h-rw-bldg)
     #:race 'Zerg #:minerals 10 #:gas 240 #:workers 36
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 24 #:gas-harvesters 12
     #:ready-bldg-counts z-3h-rw-bldg #:total-bldg-counts z-3h-rw-bldg))
  (define z-4h-normal-80g
    (compute-flow-balance
     #:plan z-4h-plan #:race 'Zerg #:minerals 200 #:gas 80 #:workers 54
     #:active-bases 3 #:total-bases 4 #:mineral-harvesters 42 #:gas-harvesters 12
     #:ready-bldg-counts z-4h-bldg #:total-bldg-counts z-4h-bldg))
  (define t-early-1ref-esc125
    (compute-flow-balance
     #:plan t-early-plan #:race 'Terran #:minerals 120 #:gas 140 #:workers 22
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 19 #:gas-harvesters 3
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:active-escrow-gas-floor 125))
  (check! (and (< (escrow-flow-report-g-drain-per-min t-3fac-30m-350g) 650.0)
               (= (escrow-flow-report-desired-gas-workers t-3fac-30m-350g) 0)
               (= (escrow-flow-report-desired-gas-workers t-3fac-30m-503g-esc) 0)
               (= (escrow-flow-report-desired-gas-workers z-4h-30m-350g) 0)
               (= (escrow-flow-report-desired-gas-workers z-3h-rw-10m-240g) 0)
               (>= (escrow-flow-report-desired-gas-workers z-4h-normal-80g) 10)
               (>= (escrow-flow-report-desired-gas-workers t-early-1ref-esc125) 3))
          (format "3h. Loop 88D mineral-feasible gas burn failed: tDrain=~a t350=~a t503=~a z4h=~a z3h=~a z80=~a early125=~a"
                  (escrow-flow-report-g-drain-per-min t-3fac-30m-350g)
                  (escrow-flow-report-desired-gas-workers t-3fac-30m-350g)
                  (escrow-flow-report-desired-gas-workers t-3fac-30m-503g-esc)
                  (escrow-flow-report-desired-gas-workers z-4h-30m-350g)
                  (escrow-flow-report-desired-gas-workers z-3h-rw-10m-240g)
                  (escrow-flow-report-desired-gas-workers z-4h-normal-80g)
                  (escrow-flow-report-desired-gas-workers t-early-1ref-esc125)))

  ;; 3i (Loop 88E): `target-g-H = max(active-escrow-gas-floor, eff-g-burn-H + fwd-g-res)`
  ;;     (NEVER additive!): Protoss 0M/350..584G esc=200G -> G*=0, Terran 5M/393G esc=125G -> G*=0,
  ;;     early Terran 120M/140G esc=150G -> G*>=3, low-burn Protoss 50M/160G esc=200G -> G*>0,
  ;;     and early 1-base Protoss 180M/140G saving for 400M/0G Natural Nexus -> G*=0!
  (define p-3b-bldg
    (hasheq 'nexus 3 'gateway 6 'robotics-facility 1 'robotics-bay 1 'assimilator 4))
  (define p-3b-plan
    (build-macro-game-plan
     #:race 'Protoss #:enemy-race 'Zerg #:frame 12000
     #:workers 54 #:active-bases 3 #:total-bases 3
     #:army-supply 44 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-bldg-counts p-3b-bldg #:total-bldg-counts p-3b-bldg))
  (define p-3b-0m-350g-esc200
    (compute-flow-balance
     #:plan p-3b-plan #:race 'Protoss #:minerals 0 #:gas 350 #:workers 54
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
     #:ready-bldg-counts p-3b-bldg #:total-bldg-counts p-3b-bldg
     #:active-escrow-gas-floor 200))
  (define p-3b-0m-584g-esc200
    (compute-flow-balance
     #:plan p-3b-plan #:race 'Protoss #:minerals 0 #:gas 584 #:workers 54
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
     #:ready-bldg-counts p-3b-bldg #:total-bldg-counts p-3b-bldg
     #:active-escrow-gas-floor 200))
  (define t-3b-5m-393g-esc125
    (compute-flow-balance
     #:plan t-3fac1tl-plan #:race 'Terran #:minerals 5 #:gas 393 #:workers 48
     #:active-bases 3 #:total-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
     #:ready-bldg-counts (hasheq 'orbital-command 3 'barracks 4 'barracks-techlab 1 'barracks-reactor 2
                                 'factory 2 'factory-techlab 1 'starport 1 'refinery 4)
     #:total-bldg-counts (hasheq 'orbital-command 3 'barracks 4 'barracks-techlab 1 'barracks-reactor 2
                                 'factory 2 'factory-techlab 1 'starport 1 'refinery 4)
     #:active-escrow-gas-floor 125))
  (define t-early-1ref-esc150
    (compute-flow-balance
     #:plan t-early-plan #:race 'Terran #:minerals 120 #:gas 140 #:workers 22
     #:active-bases 2 #:total-bases 2 #:mineral-harvesters 19 #:gas-harvesters 3
     #:ready-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:total-bldg-counts (hasheq 'orbital-command 1 'command-center 1 'barracks 1 'factory 1 'refinery 1)
     #:active-escrow-gas-floor 150))
  (define p-1b-nat-bldg
    (hasheq 'nexus 1 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 1))
  (define p-1b-nat-180m-140g
    (compute-flow-balance
     #:plan (build-macro-game-plan
             #:race 'Protoss #:enemy-race 'Terran #:frame 2240
             #:workers 19 #:active-bases 1 #:total-bases 1
             #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
             #:ready-bldg-counts p-1b-nat-bldg #:total-bldg-counts p-1b-nat-bldg)
     #:race 'Protoss #:minerals 180 #:gas 140 #:workers 19
     #:active-bases 1 #:total-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:ready-bldg-counts p-1b-nat-bldg #:total-bldg-counts p-1b-nat-bldg))
  (define p-1b-nat-esc200-floor
    (compute-flow-balance
     #:plan (build-macro-game-plan
             #:race 'Protoss #:enemy-race 'Terran #:frame 2240
             #:workers 19 #:active-bases 1 #:total-bases 1
             #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
             #:ready-bldg-counts p-1b-nat-bldg #:total-bldg-counts p-1b-nat-bldg)
     #:race 'Protoss #:minerals 180 #:gas 140 #:workers 19
     #:active-bases 1 #:total-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:ready-bldg-counts p-1b-nat-bldg #:total-bldg-counts p-1b-nat-bldg
     #:active-escrow-gas-floor 200))
  (check! (and (= (escrow-flow-report-desired-gas-workers p-3b-0m-350g-esc200) 0)
               (= (escrow-flow-report-desired-gas-workers p-3b-0m-584g-esc200) 0)
               (= (escrow-flow-report-desired-gas-workers t-3b-5m-393g-esc125) 0)
               (>= (escrow-flow-report-desired-gas-workers t-early-1ref-esc150) 3)
               (= (escrow-flow-report-desired-gas-workers p-1b-nat-180m-140g) 0)
               (> (escrow-flow-report-desired-gas-workers p-1b-nat-esc200-floor) 0))
          (format "3i. Loop 88E max-floor gas burn failed: p350=~a p584=~a t393=~a t150=~a pNat=~a pEsc200=~a"
                  (escrow-flow-report-desired-gas-workers p-3b-0m-350g-esc200)
                  (escrow-flow-report-desired-gas-workers p-3b-0m-584g-esc200)
                  (escrow-flow-report-desired-gas-workers t-3b-5m-393g-esc125)
                  (escrow-flow-report-desired-gas-workers t-early-1ref-esc150)
                  (escrow-flow-report-desired-gas-workers p-1b-nat-180m-140g)
                  (escrow-flow-report-desired-gas-workers p-1b-nat-esc200-floor))))

;; -----------------------------------------------------------------------------
;; 4. End-to-End `step-priority-macro-brain` Integration & Exported Accessors
;; -----------------------------------------------------------------------------
(let ()
  ;; 4a: Physical refusal on `spire` at 2,787M/180G vs Capital Air MUST drop spire escrow
  ;;     and spend the bank cleanly instead of deadlocking!
  (reset-macro-escrow-tracker!)
  (define z-refused-spire
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Protoss #:frame 10800
      #:minerals 2787 #:gas 180 #:supply-used 72 #:supply-cap 114 #:supply-left 42 #:pending-supply 0
      #:workers 46 #:active-bases 3 #:mineral-harvesters 34 #:gas-harvesters 12
      #:army-supply 26 #:enemy-threat-supply 24 #:under-attack? #f #:requires-anti-air? #t
      #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 4)
      #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 4)
      #:unit-counts (hasheq 'drone 46 'queen 3 'roach 10 'overlord 12)
      #:enemy-unit-counts (hasheq 'tempest 4 'void-ray 4)
      #:open-facility-slots (hasheq 'townhall 3 'larva 6))
     #:physical-refusals (list (list 'spire 'no-creep 10780))))
  (check! (and (not (eq? (macro-brain-decision-saving-for z-refused-spire) 'spire))
               (not (memq 'spire (macro-brain-decision-scheduled-ids z-refused-spire)))
               (pair? (macro-brain-decision-scheduled-ids z-refused-spire)))
          (format "4a. Physically refused Spire at 2787M must NOT freeze or escrow Spire; sav=~a sched=~s"
                  (macro-brain-decision-saving-for z-refused-spire)
                  (macro-brain-decision-scheduled-ids z-refused-spire)))

  ;; 4b: Imminent completing Spire (`eta = 10s`) pre-banks gas (`reserved-gas-floor > 0`)
  ;;     and exposes `flow-demand` & `game-plan` through clean exported accessors!
  (reset-macro-escrow-tracker!)
  (define z-spire-imminent
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Protoss #:frame 9600
      #:minerals 420 #:gas 60 #:supply-used 68 #:supply-cap 102 #:supply-left 34 #:pending-supply 0
      #:workers 46 #:active-bases 3 #:mineral-harvesters 34 #:gas-harvesters 12
      #:army-supply 22 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 4)
      #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'spire 1 'extractor 4)
      #:unit-counts (hasheq 'drone 46 'queen 4 'roach 8 'overlord 10)
      #:enemy-unit-counts (hasheq 'void-ray 3 'stalker 6)
      #:open-facility-slots (hasheq 'townhall 3 'larva 5))
     #:in-progress-tech-etas (hasheq 'spire 10.0)))
  (define z-flow (macro-brain-decision-flow-report z-spire-imminent))
  (define z-fkw  (macro-brain-decision-flow-demand z-spire-imminent))
  (check! (and (macro-game-plan? (macro-brain-decision-game-plan z-spire-imminent))
               (escrow-flow-report? z-flow)
               (> (escrow-flow-report-forward-tech-gas-reserve z-flow) 0)
               (>= (macro-brain-decision-reserved-gas-floor z-spire-imminent)
                   (escrow-flow-report-forward-tech-gas-reserve z-flow))
               (> (hash-ref z-fkw 'gas-demand-rate) 0.0))
          (format "4b. Completing Spire (10s ETA) must pre-bank gas floor & export flow-demand: gasf=~a res=~a kw=~s"
                  (macro-brain-decision-reserved-gas-floor z-spire-imminent)
                  (escrow-flow-report-forward-tech-gas-reserve z-flow)
                  z-fkw))

  ;; 4c: End-to-end Terran Zeno's Paradox prevention (`74M/180G`, Medivac `100M/100G` 1.6s away)
  ;;     + desired-addons accessor exposes `'factory-techlab? = #t`!
  (reset-macro-escrow-tracker!)
  (define t-zeno-medivac
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 6200
      #:minerals 74 #:gas 180 #:supply-used 42 #:supply-cap 62 #:supply-left 20 #:pending-supply 0
      #:workers 24 #:active-bases 2 #:mineral-harvesters 18 #:gas-harvesters 6
      #:army-supply 18 #:enemy-threat-supply 12 #:under-attack? #f
      #:researched-upgrades '(stimpack)
      #:ready-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 6
                                      'barracks 3 'barracks-techlab 1 'barracks-reactor 1
                                      'factory 1 'factory-reactor 1 'starport 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 6
                                      'barracks 3 'barracks-techlab 1 'barracks-reactor 1
                                      'factory 1 'factory-reactor 1 'starport 1 'refinery 2)
      #:unit-counts (hasheq 'scv 24 'marine 12 'marauder 3)
      #:enemy-unit-counts (hasheq 'stalker 8 'immortal 2)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 0 'factory 0 'starport 1))))
  (define t-addons (macro-brain-decision-desired-addons t-zeno-medivac))
  (check! (and (eq? (macro-brain-decision-saving-for t-zeno-medivac) 'medivac)
               (not (memq 'scv (macro-brain-decision-scheduled-ids t-zeno-medivac)))
               (eq? (hash-ref t-addons 'factory-techlab?) #t))
          (format "4c. Terran 74M/180G waiting 1.6s on Medivac must block SCV (no Zeno) & request factory-techlab; sav=~a sched=~s addons=~s"
                  (macro-brain-decision-saving-for t-zeno-medivac)
                  (macro-brain-decision-scheduled-ids t-zeno-medivac)
                  t-addons))

  ;; 4d: Terran 1-Refinery Factory+FTL+Starport automatically schedules Refinery #2!
  (reset-macro-escrow-tracker!)
  (define t-1ref-auto-ref2
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Terran #:frame 5400
      #:minerals 160 #:gas 40 #:supply-used 42 #:supply-cap 62 #:supply-left 20 #:pending-supply 0
      #:workers 26 #:active-bases 2 #:mineral-harvesters 23 #:gas-harvesters 3
      #:army-supply 16 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 6 'barracks 2
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 1)
      #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 6 'barracks 2
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 1)
      #:unit-counts (hasheq 'scv 26 'marine 10 'siege-tank 1 'medivac 1)
      #:enemy-unit-counts (hasheq 'marine 8 'siege-tank 1)
      #:open-facility-slots (hasheq 'townhall 0 'barracks 0 'factory 0 'starport 0))))
  (check! (and (escrow-flow-report-need-more-gas-geysers? (macro-brain-decision-flow-report t-1ref-auto-ref2))
               (not (not (memq 'refinery (macro-brain-decision-scheduled-ids t-1ref-auto-ref2)))))
          (format "4d. Terran 1-Refinery Factory+FTL+Starport must schedule Refinery #2 automatically; need=~a sched=~s sav=~a"
                  (escrow-flow-report-need-more-gas-geysers? (macro-brain-decision-flow-report t-1ref-auto-ref2))
                  (macro-brain-decision-scheduled-ids t-1ref-auto-ref2)
                  (macro-brain-decision-saving-for t-1ref-auto-ref2)))

  ;; 4e (Loop 88E): End-to-end `step-priority-macro-brain` max-floor handoff:
  ;;     (1) Early 1-base Protoss `180M/140G` saving for `400M/0G` Natural Nexus keeps
  ;;         `reserved-gas-floor = 0` and `G* = 0` (does not over-mine gas);
  ;;     (2) Protoss `0M/380G` even with Colossus `200G` escrow drives `G* = 0` (non-additive!);
  ;;     (3) Terran 3-Fac `30M/380G` drives `G* = 0`!
  (reset-macro-escrow-tracker!)
  (define p-brain-nat-180m-140g
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 2400
      #:minerals 180 #:gas 140 #:supply-used 22 #:supply-cap 31 #:supply-left 9 #:pending-supply 0
      #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
      #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 1)
      #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 1)
      #:unit-counts (hasheq 'probe 19 'zealot 1)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 1 'worker 1))))
  (define p-nat-fkw (macro-brain-decision-flow-demand p-brain-nat-180m-140g))
  (reset-macro-escrow-tracker!)
  (define p-brain-0m-380g-col
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 12000
      #:minerals 0 #:gas 380 #:supply-used 98 #:supply-cap 126 #:supply-left 28 #:pending-supply 0
      #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
      #:army-supply 44 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                      'robotics-facility 1 'robotics-bay 1 'assimilator 4)
      #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                      'robotics-facility 1 'robotics-bay 1 'assimilator 4)
      #:unit-counts (hasheq 'probe 54 'stalker 14 'zealot 8)
      #:enemy-unit-counts (hasheq 'hydralisk 14 'roach 10)
      #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1))))
  (define p-col-fkw (macro-brain-decision-flow-demand p-brain-0m-380g-col))
  (reset-macro-escrow-tracker!)
  (define t-brain-30m-380g
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 11000
      #:minerals 30 #:gas 380 #:supply-used 92 #:supply-cap 118 #:supply-left 26 #:pending-supply 0
      #:workers 46 #:active-bases 3 #:mineral-harvesters 34 #:gas-harvesters 12
      #:army-supply 46 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 4
                                      'barracks-techlab 1 'barracks-reactor 2
                                      'factory 3 'factory-techlab 1 'starport 1 'refinery 4)
      #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 4
                                      'barracks-techlab 1 'barracks-reactor 2
                                      'factory 3 'factory-techlab 1 'starport 1 'refinery 4)
      #:unit-counts (hasheq 'scv 46 'marine 24 'marauder 6 'siege-tank 4 'medivac 2)
      #:enemy-unit-counts (hasheq 'stalker 12 'zealot 8)
      #:open-facility-slots (hasheq 'townhall 3 'barracks 4 'factory 3 'starport 1))))
  (define t-float-fkw (macro-brain-decision-flow-demand t-brain-30m-380g))
  (check! (and (eq? (macro-brain-decision-saving-for p-brain-nat-180m-140g) 'nexus)
               (= (macro-brain-decision-reserved-gas-floor p-brain-nat-180m-140g) 0)
               (= (hash-ref p-nat-fkw 'desired-gas-workers) 0)
               (= (hash-ref p-col-fkw 'desired-gas-workers) 0)
               (= (hash-ref t-float-fkw 'desired-gas-workers) 0))
          (format "4e. Loop 88E brain->flow max-floor handoff failed: natSav=~a natGasF=~a natG*=~a pColG*=~a tFloatG*=~a"
                  (macro-brain-decision-saving-for p-brain-nat-180m-140g)
                  (macro-brain-decision-reserved-gas-floor p-brain-nat-180m-140g)
                  (hash-ref p-nat-fkw 'desired-gas-workers)
                  (hash-ref p-col-fkw 'desired-gas-workers)
                  (hash-ref t-float-fkw 'desired-gas-workers))))

(printf "l88-declarative-escrow-engine-test: ~a passed, ~a failed\n" pass-count fail-count)
(unless (= fail-count 0)
  (exit 1))
