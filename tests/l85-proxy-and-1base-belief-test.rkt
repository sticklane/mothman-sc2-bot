#lang racket/base

;; =============================================================================
;; Loop 85 Track 2 Unit Test Suite (`tests/l85-proxy-and-1base-belief-test.rkt`)
;;
;; Verifies Gap A/B/C Proxy, 1-Base Double-Gas, & Latched Early-Pool Belief:
;;   1. `lib/sc2-bayesian.rkt`:
;;      - `compute-bayesian-proxy-all-in-posterior` optional kwargs
;;        (`#:home-tech-count`, `#:early-pool-spotted?`, `#:enemy-race`):
;;        * Proxy 2-Rax (`0` Rax @ `1:50`)
;;        * Proxy Stargate (`1` Gate, `2` Gas, `0` main tech, `0` Nat @ `2:15`)
;;        * Proxy Robo (`2` Gates, `2` Gas, `0` main tech, `0` Nat @ `2:40`; `0.18x` disabled!)
;;        * 1-Base 2-Gas Cyclone (`1` Rax + `1` Factory, `2` Gas, `0` Nat @ `1:51-2:15`)
;;        * Early Spawning Pool (`12-Pool`, `0` Nat)
;;        * Zero false positives on standard 1-gas FE & 2-base macro openings
;;      - `evaluate-strategic-posteriors-from-signals` optional `#:proxy-all-in-posterior`
;;        wiring into `rush-posterior` & `hidden-expand-posterior`.
;;   2. `lib/opponent-world-model.rkt` (ABI-preserving side-tables, zero struct arity break):
;;      - Exported accessors: `owm-home-prod-count`, `owm-home-tech-count`,
;;        `owm-scouted-enemy-main?`, `owm-early-pool-latched?`,
;;        `owm-enemy-1base-double-gas?`, `owm-inferred-proxy-rush-floor`
;;        working identically on both `opponent-world-model` and `opponent-world-summary`.
;;      - Persistence across fog after scout leaves/dies for all 5 cheese/1-base openings,
;;        clean clear on expansion/reset, and `apply-worker-rush-posterior-floor`.
;; =============================================================================

(require racket/list
         "../lib/sc2-bayesian.rkt"
         "../lib/opponent-world-model.rkt"
         (only-in "../lib/mirror-mind-predictor.rkt"
                  make-mirror-mind-state
                  compute-opponent-shadow-ledger
                  interpret-opponent-actions
                  step-mirror-mind-predictor!
                  mirror-mind-state-last-shadow-ledger
                  mirror-mind-state-last-action-reading
                  shadow-ledger-dark-matter-hypothesis
                  action-lens-reading-proxy-or-rush-detected?))

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

;; =============================================================================
;; PART 1: `compute-bayesian-proxy-all-in-posterior` (`lib/sc2-bayesian.rkt`)
;; =============================================================================

;; T1.1: Proxy 2-Rax (`0` Barracks in scouted Terran main @ `1:50` = `2464f`)
(let ([p (compute-bayesian-proxy-all-in-posterior
          #:prior 0.12
          #:home-production-count 0
          #:expected-home-production 1
          #:enemy-natural-taken? #f
          #:scouted-enemy-main? #t
          #:enemy-gas-count 1
          #:frame 2464
          #:home-tech-count 0
          #:enemy-race 'Terran)])
  (check! (>= p 0.80)
          (format "T1.1: Proxy 2-Rax (0 Rax @ 1:50) must yield >= 0.80, got ~a" p)))

;; T1.2: Proxy Stargate (`1` Gate, `2` Gas, `0` main tech, `0` Nat @ `2:15` = `3024f`)
(let ([p (compute-bayesian-proxy-all-in-posterior
          #:prior 0.12
          #:home-production-count 1
          #:expected-home-production 1
          #:enemy-natural-taken? #f
          #:scouted-enemy-main? #t
          #:enemy-gas-count 2
          #:frame 3024
          #:home-tech-count 0
          #:enemy-race 'Protoss)])
  (check! (>= p 0.85)
          (format "T1.2: Proxy Stargate (1 Gate 2 Gas 0 tech @ 2:15) must yield >= 0.85, got ~a" p)))

;; T1.3: Proxy Robo (`2` Gates, `2` Gas, `0` main tech, `0` Nat @ `2:40` = `3584f`)
;;       MUST NOT trigger the `0.18x` discount on 1-base 2-gas!
(let ([p (compute-bayesian-proxy-all-in-posterior
          #:prior 0.12
          #:home-production-count 2
          #:expected-home-production 1
          #:enemy-natural-taken? #f
          #:scouted-enemy-main? #t
          #:enemy-gas-count 2
          #:frame 3584
          #:home-tech-count 0
          #:enemy-race 'Protoss)])
  (check! (>= p 0.85)
          (format "T1.3: Proxy Robo (2 Gates 2 Gas 0 tech @ 2:40) must yield >= 0.85 (0.18x disabled), got ~a" p)))

;; T1.4: 1-Base 2-Gas Cyclone (`1` Rax + `1` Factory = 2 prod, 1 tech, 2 Gas, 0 Nat @ `>= 145s` = `3248f`)
(let ([p-early (compute-bayesian-proxy-all-in-posterior
                #:prior 0.12
                #:home-production-count 2
                #:expected-home-production 1
                #:enemy-natural-taken? #f
                #:scouted-enemy-main? #t
                #:enemy-gas-count 2
                #:frame 2800
                #:home-tech-count 1
                #:enemy-race 'Terran)]
      [p-145s (compute-bayesian-proxy-all-in-posterior
               #:prior 0.12
               #:home-production-count 2
               #:expected-home-production 1
               #:enemy-natural-taken? #f
               #:scouted-enemy-main? #t
               #:enemy-gas-count 2
               #:frame 3248
               #:home-tech-count 1
               #:enemy-race 'Terran)])
  (check! (< p-early 0.20)
          (format "T1.4a: Terran < 145s (f=2800) with main Rax MUST stay < 0.20 (no false 1-Rax FE fire), got ~a" p-early))
  (check! (>= p-145s 0.60)
          (format "T1.4b: 1-Base 2-Gas Cyclone (2 prod 1 tech 2 gas 0 nat @ 145s = 3248f) must yield >= 0.60, got ~a" p-145s)))

;; T1.5: Early Spawning Pool (`12-Pool`, no natural @ `1:20` = `1792f`)
(let ([p (compute-bayesian-proxy-all-in-posterior
          #:prior 0.12
          #:home-production-count 0
          #:expected-home-production 0
          #:enemy-natural-taken? #f
          #:scouted-enemy-main? #t
          #:enemy-gas-count 0
          #:frame 1792
          #:early-pool-spotted? #t
          #:enemy-race 'Zerg)])
  (check! (>= p 0.60)
          (format "T1.5: Early Spawning Pool with no natural must yield >= 0.60, got ~a" p)))

;; T1.6: Standard Macro Openings MUST NOT False-Positive!
(let ([p-macro-2base
       (compute-bayesian-proxy-all-in-posterior
        #:prior 0.12
        #:home-production-count 2
        #:expected-home-production 1
        #:enemy-natural-taken? #t
        #:scouted-enemy-main? #t
        #:enemy-gas-count 2
        #:frame 3200
        #:home-tech-count 1
        #:enemy-race 'Protoss)]
      [p-1gas-fe
       (compute-bayesian-proxy-all-in-posterior
        #:prior 0.12
        #:home-production-count 1
        #:expected-home-production 1
        #:enemy-natural-taken? #f
        #:scouted-enemy-main? #t
        #:enemy-gas-count 1
        #:frame 2100
        #:home-tech-count 0
        #:enemy-race 'Terran)]
      [p-legacy-no-kwargs
       (compute-bayesian-proxy-all-in-posterior
        #:prior 0.12
        #:home-production-count 1
        #:expected-home-production 1
        #:enemy-natural-taken? #t
        #:scouted-enemy-main? #t
        #:enemy-gas-count 1
        #:frame 2400)])
  (check! (<= p-macro-2base 0.05)
          (format "T1.6a: Standard 2-base 2-gas macro must stay <= 0.05, got ~a" p-macro-2base))
  (check! (<= p-1gas-fe 0.15)
          (format "T1.6b: Standard 1-gas FE before natural must stay <= 0.15, got ~a" p-1gas-fe))
  (check! (<= p-legacy-no-kwargs 0.05)
          (format "T1.6c: Backward-compatible call without new kwargs works cleanly, got ~a" p-legacy-no-kwargs)))

;; =============================================================================
;; PART 2: `evaluate-strategic-posteriors-from-signals` (`#:proxy-all-in-posterior`)
;; =============================================================================

(let ([s-legacy
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 3024 #:combat-count 0
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 1
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq))]
      [s-low-proxy
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 3024 #:combat-count 0
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 2
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:proxy-all-in-posterior 0.15)]
      [s-cyclone-1b
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 2800 #:combat-count 0
        #:unaccounted-minerals 150.0 #:unaccounted-gas 100.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 1
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:proxy-all-in-posterior 0.68)]
      [s-proxy-sg
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 3024 #:combat-count 0
        #:unaccounted-minerals 200.0 #:unaccounted-gas 150.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 1
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:proxy-all-in-posterior 0.92)]
      [s-late-game
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 9500 #:combat-count 0
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 3
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:proxy-all-in-posterior 0.65)])
  (check! (< (abs (- (bayesian-strategic-priors-rush-posterior s-legacy) 0.12)) 0.01)
          (format "T2.1: Legacy call without #:proxy-all-in-posterior keeps baseline 0.12, got ~a"
                  (bayesian-strategic-priors-rush-posterior s-legacy)))
  (check! (< (abs (- (bayesian-strategic-priors-rush-posterior s-low-proxy) 0.12)) 0.01)
          "T2.2: Low proxy posterior (0.15) does NOT inflate rush-posterior")
  (check! (and (>= (bayesian-strategic-priors-rush-posterior s-cyclone-1b) 0.65)
               (< (bayesian-strategic-priors-hidden-expand-posterior s-cyclone-1b) 0.05))
          (format "T2.3: 1-base 2-gas proxy posterior 0.68 lifts rush >= 0.65 & discounts hidden-expand, got rush=~a hexp=~a"
                  (bayesian-strategic-priors-rush-posterior s-cyclone-1b)
                  (bayesian-strategic-priors-hidden-expand-posterior s-cyclone-1b)))
  (check! (>= (bayesian-strategic-priors-rush-posterior s-proxy-sg) 0.88)
          (format "T2.4: Proxy SG posterior 0.92 lifts rush >= 0.88, got ~a"
                  (bayesian-strategic-priors-rush-posterior s-proxy-sg)))
  (check! (< (bayesian-strategic-priors-rush-posterior s-late-game) 0.30)
          (format "T2.5: Late game (f=9500, 3 bases) does not apply early-game rush floor, got ~a"
                  (bayesian-strategic-priors-rush-posterior s-late-game))))

;; =============================================================================
;; PART 3: `lib/opponent-world-model.rkt` Side-Table Persistence Across Fog
;; =============================================================================

(define (mk-base-obs frame erace ally-units enemy-bldgs [enemy-units '()])
  (hasheq 'frame frame
          'enemy-race erace
          'base-x 32.0 'base-y 32.0
          'natural-x 50.0 'natural-y 42.0
          'enemy-x 160.0 'enemy-y 160.0
          'enemy-exp-x 142.0 'enemy-exp-y 150.0
          'ally-units ally-units
          'enemy-units enemy-units
          'enemy-buildings enemy-bldgs))

;; T3.1: Proxy 2-Rax (`0` Rax in scouted main @ `1:50`) persists across fog!
(let* ([owm (make-opponent-world-model 'Terran)]
       ;; Scout enters enemy main at 1:50 (2464f), sees CC + Depot + 1 Refinery (0 Barracks)
       [s1 (step-opponent-world-model!
            owm
            (mk-base-obs 2464 'Terran
                         (list (hasheq 'id 10 'type 'probe 'x 156.0 'y 156.0))
                         (list (hasheq 'id 501 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                               (hasheq 'id 502 'type 'supply-depot 'x 152.0 'y 152.0 'build-progress 1.0)
                               (hasheq 'id 503 'type 'refinery 'x 164.0 'y 162.0 'build-progress 1.0))))]
       ;; Scout dies at 2:15 (3024f); enemy main back in fog (`enemy-buildings = '()`)
       [s2 (step-opponent-world-model!
            owm
            (mk-base-obs 3024 'Terran
                         (list (hasheq 'id 11 'type 'probe 'x 33.0 'y 33.0))
                         '()))])
  (check! (and (owm-scouted-enemy-main? owm) (owm-scouted-enemy-main? s2))
          "T3.1a: owm-scouted-enemy-main? stays latched #t across fog on both owm and summary")
  (check! (and (= (owm-home-prod-count owm) 0) (= (owm-home-prod-count s2) 0))
          "T3.1b: Proxy 2-Rax keeps home-prod-count = 0 across fog")
  (check! (and (= (owm-home-tech-count owm) 0) (= (owm-home-tech-count s2) 0))
          "T3.1c: Proxy 2-Rax keeps home-tech-count = 0 across fog")
  (check! (and (>= (owm-inferred-proxy-rush-floor owm) 0.80)
               (>= (owm-inferred-proxy-rush-floor s1) 0.80)
               (>= (owm-inferred-proxy-rush-floor s2) 0.80)
               (>= (apply-worker-rush-posterior-floor 0.12 s2) 0.80))
          (format "T3.1d: Proxy 2-Rax keeps inferred rush floor >= 0.80 across fog, got ~a"
                  (owm-inferred-proxy-rush-floor s2))))

;; T3.2: Proxy Stargate (`1` Gate, `2` Assimilators, `0` main tech, `0` Nat @ `2:15`) across fog!
(let* ([owm (make-opponent-world-model 'Protoss)]
       [s1 (step-opponent-world-model!
            owm
            (mk-base-obs 3024 'Protoss
                         (list (hasheq 'id 10 'type 'scv 'x 158.0 'y 158.0))
                         (list (hasheq 'id 601 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                               (hasheq 'id 602 'type 'gateway 'x 154.0 'y 156.0 'build-progress 1.0)
                               (hasheq 'id 603 'type 'cybernetics-core 'x 155.0 'y 153.0 'build-progress 1.0)
                               (hasheq 'id 604 'type 'assimilator 'x 164.0 'y 158.0 'build-progress 1.0)
                               (hasheq 'id 605 'type 'assimilator 'x 158.0 'y 166.0 'build-progress 1.0))))]
       [s2 (step-opponent-world-model!
            owm
            (mk-base-obs 3500 'Protoss
                         (list (hasheq 'id 11 'type 'scv 'x 33.0 'y 33.0))
                         '()))])
  (check! (and (= (owm-home-prod-count s2) 1)
               (= (owm-home-tech-count s2) 0)
               (owm-scouted-enemy-main? s2)
               (owm-enemy-1base-double-gas? s2)
               (owm-enemy-1base-double-gas? owm))
          (format "T3.2a: Proxy Stargate remembers prod=1, tech=0, main=#t, 1b2g=#t across fog (prod=~a tech=~a 1b2g=~a)"
                  (owm-home-prod-count s2) (owm-home-tech-count s2) (owm-enemy-1base-double-gas? s2)))
  (check! (and (>= (owm-inferred-proxy-rush-floor s1) 0.78)
               (>= (owm-inferred-proxy-rush-floor s2) 0.78)
               (>= (apply-worker-rush-posterior-floor 0.12 s2) 0.78))
          (format "T3.2b: Proxy Stargate floor >= 0.78 across fog, got ~a"
                  (owm-inferred-proxy-rush-floor s2))))

;; T3.3: Proxy Robo (`2` Gates, `2` Assimilators, `0` main tech, `0` Nat @ `2:40`) across fog!
(let* ([owm (make-opponent-world-model 'Protoss)]
       [s1 (step-opponent-world-model!
            owm
            (mk-base-obs 3584 'Protoss
                         (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                         (list (hasheq 'id 611 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                               (hasheq 'id 612 'type 'gateway 'x 154.0 'y 156.0 'build-progress 1.0)
                               (hasheq 'id 613 'type 'gateway 'x 154.0 'y 152.0 'build-progress 1.0)
                               (hasheq 'id 614 'type 'cybernetics-core 'x 156.0 'y 154.0 'build-progress 1.0)
                               (hasheq 'id 615 'type 'assimilator 'x 164.0 'y 158.0 'build-progress 1.0)
                               (hasheq 'id 616 'type 'assimilator 'x 158.0 'y 166.0 'build-progress 1.0))))]
       [s2 (step-opponent-world-model!
            owm
            (mk-base-obs 4000 'Protoss '() '()))])
  (check! (and (= (owm-home-prod-count s2) 2)
               (= (owm-home-tech-count s2) 0)
               (owm-enemy-1base-double-gas? s2)
               (>= (owm-inferred-proxy-rush-floor s2) 0.78))
          (format "T3.3: Proxy Robo remembers prod=2 tech=0 1b2g=#t floor>=0.78 across fog, got prod=~a tech=~a floor=~a"
                  (owm-home-prod-count s2) (owm-home-tech-count s2) (owm-inferred-proxy-rush-floor s2))))

;; T3.4: 1-Base 2-Gas Cyclone (`1` Rax + `1` Factory + `2` Refineries, `0` Nat) -> fires at >= 145s (`3248f`) & clears cleanly on Nat CC!
(let* ([owm (make-opponent-world-model 'Terran)]
       ;; Scouted at 125s (`2800f` < `145s`): remembers 2 Refineries, does NOT fire < 145s!
       [s1 (step-opponent-world-model!
            owm
            (mk-base-obs 2800 'Terran
                         (list (hasheq 'id 10 'type 'probe 'x 157.0 'y 157.0))
                         (list (hasheq 'id 701 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                               (hasheq 'id 702 'type 'barracks 'x 154.0 'y 155.0 'build-progress 1.0)
                               (hasheq 'id 703 'type 'factory 'x 156.0 'y 152.0 'build-progress 0.7)
                               (hasheq 'id 704 'type 'refinery 'x 164.0 'y 158.0 'build-progress 1.0)
                               (hasheq 'id 705 'type 'refinery 'x 158.0 'y 166.0 'build-progress 1.0))))]
       ;; Fog tick past 145s (`3300f` = `147s`): scout leaves -> 1-base 2-gas activates & latches across fog!
       [s2 (step-opponent-world-model!
            owm
            (mk-base-obs 3300 'Terran '() '()))]
       ;; Expansion tick: opponent takes Natural CC -> no longer 1-base!
       [s3 (step-opponent-world-model!
            owm
            (mk-base-obs 3800 'Terran
                         '()
                         (list (hasheq 'id 706 'type 'command-center 'x 142.0 'y 150.0 'build-progress 0.5))))])
  (check! (and (= (owm-inferred-proxy-rush-floor s1) 0.0)
               (not (owm-enemy-1base-double-gas? s1)))
          (format "T3.4a0: Terran < 145s (2800f) with main Rax does NOT prematurely fire 1b2g, got floor=~a"
                  (owm-inferred-proxy-rush-floor s1)))
  (check! (and (= (owm-home-prod-count s2) 2)
               (= (owm-home-tech-count s2) 1)
               (owm-enemy-1base-double-gas? s2)
               (>= (owm-inferred-proxy-rush-floor s2) 0.65)
               (>= (apply-worker-rush-posterior-floor 0.12 s2) 0.65))
          (format "T3.4a: 1-Base 2-Gas Cyclone remembers prod=2 tech=1 1b2g=#t floor>=0.65 at >=145s across fog, got prod=~a tech=~a floor=~a"
                  (owm-home-prod-count s2) (owm-home-tech-count s2) (owm-inferred-proxy-rush-floor s2)))
  (check! (and (not (owm-enemy-1base-double-gas? s3))
               (= (owm-inferred-proxy-rush-floor s3) 0.0)
               (= (apply-worker-rush-posterior-floor 0.12 s3) 0.12))
          (format "T3.4b: Taking Natural CC clears 1b2g & proxy rush floor cleanly, got 1b2g=~a floor=~a"
                  (owm-enemy-1base-double-gas? s3) (owm-inferred-proxy-rush-floor s3))))

;; T3.5: 12-Pool latched memory across fog vs Standard Hatch-First zero false positive!
(let* ([owm-12p (make-opponent-world-model 'Zerg)]
       ;; 1:12 (1612f): Probe sees completed 12-Pool (`bp=1.0`) with 0 natural
       [s1 (step-opponent-world-model!
            owm-12p
            (mk-base-obs 1612 'Zerg
                         (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                         (list (hasheq 'id 801 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                               (hasheq 'id 802 'type 'spawning-pool 'x 156.0 'y 158.0 'build-progress 1.0))))]
       ;; 1:45 (2352f) & 2:20 (3136f): Probe gone, main in fog (`enemy-buildings = '()`)
       [s2 (step-opponent-world-model! owm-12p (mk-base-obs 2352 'Zerg '() '()))]
       [s3 (step-opponent-world-model! owm-12p (mk-base-obs 3136 'Zerg '() '()))]
       ;; Standard 16-Hatch-17-Pool at 1:20 (1792f): natural Hatchery + Pool at bp=0.15 (started 1:13)
       [owm-std (make-opponent-world-model 'Zerg)]
       [s-std (step-opponent-world-model!
               owm-std
               (mk-base-obs 1792 'Zerg
                            (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                            (list (hasheq 'id 811 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                  (hasheq 'id 812 'type 'hatchery 'x 142.0 'y 150.0 'build-progress 0.70)
                                  (hasheq 'id 813 'type 'spawning-pool 'x 156.0 'y 158.0 'build-progress 0.15))))])
  (check! (and (owm-early-pool-latched? owm-12p)
               (owm-early-pool-latched? s1)
               (owm-early-pool-latched? s2)
               (owm-early-pool-latched? s3)
               (>= (owm-inferred-proxy-rush-floor s2) 0.70)
               (>= (owm-inferred-proxy-rush-floor s3) 0.70)
               (>= (apply-worker-rush-posterior-floor 0.12 s3) 0.70))
          (format "T3.5a: 12-Pool stays latched across fog through 2:20 with floor >= 0.70, got latch=~a floor=~a"
                  (owm-early-pool-latched? s3) (owm-inferred-proxy-rush-floor s3)))
  (check! (and (not (owm-early-pool-latched? owm-std))
               (not (owm-early-pool-latched? s-std))
               (= (owm-inferred-proxy-rush-floor s-std) 0.0))
          (format "T3.5b: Standard 16-Hatch-17-Pool MUST NOT false-latch early-pool, got latch=~a floor=~a"
                  (owm-early-pool-latched? s-std) (owm-inferred-proxy-rush-floor s-std))))

;; T3.6: Low-ground natural scout does NOT latch main; `reset-opponent-world-model!` clears all 6 fields;
;;       ABI check (35-field `opponent-world-summary`) & safe `#f` defaults.
(let* ([owm (make-opponent-world-model 'Terran)]
       [s-nat-only (step-opponent-world-model!
                    owm
                    (mk-base-obs 2200 'Terran
                                 (list (hasheq 'id 10 'type 'overlord 'x 142.0 'y 150.0))
                                 (list (hasheq 'id 901 'type 'command-center 'x 142.0 'y 150.0 'build-progress 0.5))))]
       [_ (step-opponent-world-model!
           owm
           (mk-base-obs 2464 'Terran
                        (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                        '()))]
       [latched-before-reset? (owm-scouted-enemy-main? owm)]
       [_ (reset-opponent-world-model! owm 'Unknown)])
  (check! (not (owm-scouted-enemy-main? s-nat-only))
          "T3.6a: Low-ground natural scout MUST NOT falsely latch owm-scouted-enemy-main?")
  (check! (and latched-before-reset?
               (not (owm-scouted-enemy-main? owm))
               (= (owm-home-prod-count owm) 0)
               (= (owm-home-tech-count owm) 0)
               (not (owm-early-pool-latched? owm))
               (not (owm-enemy-1base-double-gas? owm))
               (= (owm-inferred-proxy-rush-floor owm) 0.0))
          "T3.6b: reset-opponent-world-model! resets all 6 side-table fields cleanly")
  (check! (= (sub1 (vector-length (struct->vector s-nat-only))) 35)
          "T3.6c: opponent-world-summary ABI preserved at exact 35 fields (zero struct arity break)")
  (check! (and (= (owm-home-prod-count #f) 0)
               (= (owm-home-tech-count #f) 0)
               (not (owm-scouted-enemy-main? #f))
               (not (owm-early-pool-latched? #f))
               (not (owm-enemy-1base-double-gas? #f))
               (= (owm-inferred-proxy-rush-floor #f) 0.0))
          "T3.6d: All 6 accessors handle #f safely without throwing"))

;; T3.7: End-to-end Pipeline Integration (OWM -> proxy posterior -> strategic posteriors -> floor)
(let* ([owm (make-opponent-world-model 'Protoss)]
       [s1 (step-opponent-world-model!
            owm
            (mk-base-obs 3024 'Protoss
                         (list (hasheq 'id 10 'type 'scv 'x 158.0 'y 158.0))
                         (list (hasheq 'id 951 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                               (hasheq 'id 952 'type 'gateway 'x 154.0 'y 156.0 'build-progress 1.0)
                               (hasheq 'id 953 'type 'cybernetics-core 'x 155.0 'y 153.0 'build-progress 1.0)
                               (hasheq 'id 954 'type 'assimilator 'x 164.0 'y 158.0 'build-progress 1.0)
                               (hasheq 'id 955 'type 'assimilator 'x 158.0 'y 166.0 'build-progress 1.0))))]
       [s-fog (step-opponent-world-model! owm (mk-base-obs 3400 'Protoss '() '()))]
       [b-proxy (compute-bayesian-proxy-all-in-posterior
                 #:prior 0.12
                 #:home-production-count (owm-home-prod-count owm)
                 #:expected-home-production 2
                 #:enemy-natural-taken? (>= (opponent-world-summary-confirmed-bases s-fog) 2)
                 #:scouted-enemy-main? (owm-scouted-enemy-main? owm)
                 #:enemy-gas-count (opponent-world-summary-confirmed-geysers s-fog)
                 #:frame 3400
                 #:home-tech-count (owm-home-tech-count owm)
                 #:early-pool-spotted? (owm-early-pool-latched? owm)
                 #:enemy-race (opponent-world-summary-enemy-race s-fog))]
       [priors (evaluate-strategic-posteriors-from-signals
                #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 3400 #:combat-count 0
                #:unaccounted-minerals 200.0 #:unaccounted-gas 150.0
                #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 1
                #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
                #:branch-posteriors (hasheq)
                #:proxy-all-in-posterior b-proxy)]
       [final-rush (apply-worker-rush-posterior-floor
                    (bayesian-strategic-priors-rush-posterior priors)
                    s-fog)])
  (check! (and (>= b-proxy 0.90)
               (>= (bayesian-strategic-priors-rush-posterior priors) 0.88)
               (>= final-rush 0.88))
          (format "T3.7: Full fog-persisted Proxy Stargate pipeline yields rush >= 0.88, got proxy=~a rush=~a final=~a"
                  b-proxy (bayesian-strategic-priors-rush-posterior priors) final-rush)))

;; =============================================================================
;; PART 4: Loop 85B Track 2B Regression Suite (Zero 1-Rax FE False Positives +
;;         Zero Post-Scout Fog Amnesia + Clean Post-Hold Release)
;; =============================================================================

;; T4.1: Normal 1-Rax FE (`@118s` f=2640 AND `@134s` f=3000 with `exp-prod=2`, `1` Rax `1` Gas `0` Nat)
;;       MUST stay `< 0.20` (zero false-positive `rush = 0.91`!)
(let* ([p-118s (compute-bayesian-proxy-all-in-posterior
                #:prior 0.12
                #:home-production-count 1
                #:expected-home-production 1
                #:enemy-natural-taken? #f
                #:scouted-enemy-main? #t
                #:enemy-gas-count 1
                #:frame 2640
                #:home-tech-count 0
                #:enemy-race 'Terran)]
       [p-134s-exp2 (compute-bayesian-proxy-all-in-posterior
                     #:prior 0.12
                     #:home-production-count 1
                     #:expected-home-production 2
                     #:enemy-natural-taken? #f
                     #:scouted-enemy-main? #t
                     #:enemy-gas-count 1
                     #:frame 3000
                     #:home-tech-count 0
                     #:enemy-race 'Terran)]
       [owm (make-opponent-world-model 'Terran)]
       [s-118s (step-opponent-world-model!
                owm
                (mk-base-obs 2640 'Terran
                             (list (hasheq 'id 10 'type 'probe 'x 156.0 'y 156.0))
                             (list (hasheq 'id 961 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                                   (hasheq 'id 962 'type 'barracks 'x 154.0 'y 155.0 'build-progress 1.0)
                                   (hasheq 'id 963 'type 'refinery 'x 164.0 'y 158.0 'build-progress 1.0)
                                   (hasheq 'id 964 'type 'supply-depot 'x 151.0 'y 152.0 'build-progress 1.0))))]
       [s-134s (step-opponent-world-model! owm (mk-base-obs 3000 'Terran '() '()))])
  (check! (< p-118s 0.20)
          (format "T4.1a: Normal 1-Rax FE @118s (1 Rax 1 Gas 0 Nat) must stay < 0.20, got ~a" p-118s))
  (check! (< p-134s-exp2 0.20)
          (format "T4.1b: Normal 1-Rax FE @134s with exp-prod=2 (1 Rax 1 Gas 0 Nat) must stay < 0.20, got ~a" p-134s-exp2))
  (check! (and (= (owm-inferred-proxy-rush-floor s-118s) 0.0)
               (= (owm-inferred-proxy-rush-floor s-134s) 0.0)
               (< (apply-worker-rush-posterior-floor p-134s-exp2 s-134s) 0.20))
          (format "T4.1c: OWM normal 1-Rax FE floor=0.0 at 118s & 134s, got ~a / ~a"
                  (owm-inferred-proxy-rush-floor s-118s) (owm-inferred-proxy-rush-floor s-134s))))

;; T4.2: Low-ground Probe peeking ONLY at Terran ramp Supply Depot (`10t` from main) MUST NOT
;;       falsely latch `owm-scouted-enemy-main?`; expansion-block `engineering-bay` near our nat
;;       MUST NOT fire proxy rush floor!
(let* ([owm (make-opponent-world-model 'Terran)]
       [s-depot (step-opponent-world-model!
                 owm
                 (mk-base-obs 2400 'Terran
                              ;; Probe on low ground 14t from enemy main (160,160)
                              (list (hasheq 'id 10 'type 'probe 'x 149.0 'y 151.0))
                              ;; Only sees ramp Supply Depot (10t from main) + natural-block Ebay near our nat!
                              (list (hasheq 'id 971 'type 'supply-depot 'x 153.0 'y 153.0 'build-progress 1.0)
                                    (hasheq 'id 972 'type 'engineering-bay 'x 50.0 'y 42.0 'build-progress 0.4 'is-proxy? #t))))])
  (check! (and (not (owm-scouted-enemy-main? s-depot))
               (= (owm-inferred-proxy-rush-floor s-depot) 0.0))
          (format "T4.2: Ramp Supply Depot peek + nat-block Ebay must NOT latch main or fire proxy floor, got main=~a floor=~a"
                  (owm-scouted-enemy-main? s-depot) (owm-inferred-proxy-rush-floor s-depot))))

;; T4.3: Low-ground scout retreating down ramp (`7t` in 2D from high-ground Refinery) MUST NOT
;;       falsely sight-clear high-ground Refineries into `dead-tags`; 1-base 2-gas persists @150s..240s!
(let* ([owm (make-opponent-world-model 'Terran)]
       ;; Scout enters main at 115s (`2580f`), sees 2 Refineries + Rax + Factory
       [_ (step-opponent-world-model!
           owm
           (mk-base-obs 2580 'Terran
                        (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                        (list (hasheq 'id 981 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                              (hasheq 'id 982 'type 'barracks 'x 154.0 'y 155.0 'build-progress 1.0)
                              (hasheq 'id 983 'type 'factory 'x 156.0 'y 152.0 'build-progress 0.6)
                              (hasheq 'id 984 'type 'refinery 'x 164.0 'y 158.0 'build-progress 1.0)
                              (hasheq 'id 985 'type 'refinery 'x 158.0 'y 166.0 'build-progress 1.0))))]
       ;; Ground Probe retreats down ramp (`7.0t` in 2D from Factory/Refinery #2, buildings now in high-ground fog!)
       [_ (step-opponent-world-model!
           owm
           (mk-base-obs 2796 'Terran
                        (list (hasheq 'id 10 'type 'probe 'x 151.0 'y 165.0))
                        '()))]
       ;; Check persistence across fog at 150s (`3360f`) and 240s (`5376f`)!
       [s-150s (step-opponent-world-model! owm (mk-base-obs 3360 'Terran '() '()))]
       [s-240s (step-opponent-world-model! owm (mk-base-obs 5376 'Terran '() '()))])
  (check! (and (= (opponent-world-summary-confirmed-geysers s-150s) 2)
               (owm-enemy-1base-double-gas? s-150s)
               (>= (owm-inferred-proxy-rush-floor s-150s) 0.65)
               (>= (owm-inferred-proxy-rush-floor s-240s) 0.65))
          (format "T4.3: Low-ground ramp retreat must preserve high-ground Refineries & hold >= 0.65 through 150s..240s, got gas=~a f150=~a f240=~a"
                  (opponent-world-summary-confirmed-geysers s-150s)
                  (owm-inferred-proxy-rush-floor s-150s)
                  (owm-inferred-proxy-rush-floor s-240s))))

;; T4.4: Mid-map Proxy Robotics Facility (`97t` from enemy main, `62t` from our base) spotted at 174s
;;       persists latched `>= 0.80` across fog at `180s..240s..280s`!
(let* ([owm (make-opponent-world-model 'Protoss)]
       [s-spot (step-opponent-world-model!
                owm
                (mk-base-obs 3908 'Protoss
                             (list (hasheq 'id 10 'type 'adept 'x 90.0 'y 55.0))
                             (list (hasheq 'id 991 'type 'robotics-facility 'x 92.0 'y 52.0 'build-progress 0.3))))]
       [s-180s (step-opponent-world-model! owm (mk-base-obs 4032 'Protoss '() '()))]
       [s-240s (step-opponent-world-model! owm (mk-base-obs 5376 'Protoss '() '()))]
       [s-280s (step-opponent-world-model! owm (mk-base-obs 6272 'Protoss '() '()))])
  (check! (and (>= (owm-inferred-proxy-rush-floor s-spot) 0.80)
               (>= (owm-inferred-proxy-rush-floor s-180s) 0.80)
               (>= (owm-inferred-proxy-rush-floor s-240s) 0.80)
               (>= (owm-inferred-proxy-rush-floor s-280s) 0.80))
          (format "T4.4: Mid-map Proxy Robo must stay latched >= 0.80 through 180s..280s fog, got ~a/~a/~a/~a"
                  (owm-inferred-proxy-rush-floor s-spot)
                  (owm-inferred-proxy-rush-floor s-180s)
                  (owm-inferred-proxy-rush-floor s-240s)
                  (owm-inferred-proxy-rush-floor s-280s))))

;; T4.5: 12-Pool (`18.4s` Pool) & late `91s` follow-up natural Hatchery stay latched `>= 0.70`
;;       through `120s..190s` (`<= 4368f`), clear cleanly past `3:15` (`4368f`) when 2-base
;;       with `< 6` active Zerglings, and stay latched past `4368f` if `>= 6` Lings are active!
(let* ([owm (make-opponent-world-model 'Zerg)]
       [_ (step-opponent-world-model!
           owm
           (mk-base-obs 1612 'Zerg
                        (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                        (list (hasheq 'id 1001 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                              (hasheq 'id 1002 'type 'spawning-pool 'x 156.0 'y 158.0 'build-progress 1.0))))]
       ;; Zerg drops follow-up natural Hatchery at 91s (`2047f`), observed at 120s (`2688f`)
       [s-120s (step-opponent-world-model!
                owm
                (mk-base-obs 2688 'Zerg
                             (list (hasheq 'id 10 'type 'probe 'x 142.0 'y 150.0))
                             (list (hasheq 'id 1003 'type 'hatchery 'x 142.0 'y 150.0 'build-progress 0.35))))]
       ;; Fog at 150s (`3360f`) and 190s (`4256f <= 4368f`): stays latched!
       [s-150s (step-opponent-world-model! owm (mk-base-obs 3360 'Zerg '() '()))]
       [s-190s (step-opponent-world-model! owm (mk-base-obs 4256 'Zerg '() '()))]
       ;; Peaceful 2-base past 3:15 (`4480f > 4368f`) with 0 active Lings -> clears cleanly!
       [s-200s-clear (step-opponent-world-model! owm (mk-base-obs 4480 'Zerg '() '()))]
       ;; Active >= 6 Ling wave past 3:15 (`4700f > 4368f`) -> stays latched!
       [six-lings (for/list ([i (in-range 6)])
                    (hasheq 'id (+ 1100 i) 'type 'zergling 'x 60.0 'y 50.0 'hp 35))]
       [s-210s-wave (step-opponent-world-model! owm (mk-base-obs 4700 'Zerg '() '() six-lings))]
       [b-12p-with-nat (compute-bayesian-proxy-all-in-posterior
                        #:prior 0.12
                        #:home-production-count 0 #:expected-home-production 0
                        #:enemy-natural-taken? #t #:scouted-enemy-main? #t
                        #:enemy-gas-count 0 #:frame 3360
                        #:early-pool-spotted? #t #:enemy-race 'Zerg)])
  (check! (and (>= (owm-inferred-proxy-rush-floor s-120s) 0.70)
               (>= (owm-inferred-proxy-rush-floor s-150s) 0.70)
               (>= (owm-inferred-proxy-rush-floor s-190s) 0.70)
               (>= b-12p-with-nat 0.60))
          (format "T4.5a: 12-Pool with follow-up Hatchery must stay latched >= 0.70 through 120s..190s, got ~a/~a/~a bayes=~a"
                  (owm-inferred-proxy-rush-floor s-120s)
                  (owm-inferred-proxy-rush-floor s-150s)
                  (owm-inferred-proxy-rush-floor s-190s)
                  b-12p-with-nat))
  (check! (and (not (owm-early-pool-latched? s-200s-clear))
               (= (owm-inferred-proxy-rush-floor s-200s-clear) 0.0)
               (owm-early-pool-latched? s-210s-wave)
               (>= (owm-inferred-proxy-rush-floor s-210s-wave) 0.70))
          (format "T4.5b: 12-Pool clears peacefully >4368f on 2-base (<6 Lings) and re-arms on >=6 active Lings, got clear=(~a,~a) wave=(~a,~a)"
                  (owm-early-pool-latched? s-200s-clear)
                  (owm-inferred-proxy-rush-floor s-200s-clear)
                  (owm-early-pool-latched? s-210s-wave)
                  (owm-inferred-proxy-rush-floor s-210s-wave))))

;; T4.6: Post-hold safe army parity past `260s` (`5824f`) cleanly releases latched proxy floor
;;       so held cheeses (`T vs 4-Gate`) immediately expand instead of stalling CC #2 past 300s!
(let* ([owm (make-opponent-world-model 'Protoss)]
       [_ (step-opponent-world-model!
           owm
           (mk-base-obs 2300 'Protoss
                        (list (hasheq 'id 10 'type 'scv 'x 158.0 'y 158.0))
                        (list (hasheq 'id 1011 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0))))]
       [s-240s (step-opponent-world-model! owm (mk-base-obs 5376 'Protoss '() '()))]
       ;; At 265s (`5936f`), we hold cleanly with 10 Marines (`army-supply = 10.0`) vs 2 visible Zealots!
       [s-held (step-opponent-world-model!
                owm
                (hash-set (mk-base-obs 5936 'Protoss '() '()
                                       (list (hasheq 'id 1021 'type 'zealot 'x 52.0 'y 42.0 'hp 100)
                                             (hasheq 'id 1022 'type 'zealot 'x 53.0 'y 42.0 'hp 100)))
                          'army-supply 10.0))])
  (check! (and (>= (owm-inferred-proxy-rush-floor s-240s) 0.80)
               (= (owm-inferred-proxy-rush-floor s-held) 0.0))
          (format "T4.6: Proxy latch holds at 240s (>=0.80) and releases cleanly at 265s on safe army parity (0.0), got ~a -> ~a"
                  (owm-inferred-proxy-rush-floor s-240s)
                  (owm-inferred-proxy-rush-floor s-held))))

;; =============================================================================
;; PART 5: Loop 85C Track 2C Regression Suite (Zero False-Positive `rush_high`:
;;         Tightened `early-pool-now?`, Natural-Choke `home-prod-cnt`, Geyser
;;         Non-Latch, `missing-main-prod >= 2240f`, Standard PvP 2-Gate 2-Gas,
;;         and Mirror-Mind Natural-Pad Expansion-Block Exclusion)
;; =============================================================================

;; T5.1: Tightened `early-pool-now?` — Standard `16-Pool` + `4` anti-scout Lings MUST NOT latch,
;;       while true `14-Pool` (`est-start <= 950`) and `>= 6` Lings (`<= 2700f`) DO latch!
(let* ([owm-16p (make-opponent-world-model 'Zerg)]
       ;; Standard 16-Pool started at 1150f (`51.3s`): spotted at 1665f (bp=0.50), again at 2180f (bp=1.0),
       ;; plus 4 anti-scout Zerglings at 2500f (`1:52`)!
       [s16-a (step-opponent-world-model!
               owm-16p
               (mk-base-obs 1665 'Zerg
                            (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                            (list (hasheq 'id 2001 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                  (hasheq 'id 2002 'type 'spawning-pool 'x 156.0 'y 158.0 'build-progress 0.50))))]
       [s16-b (step-opponent-world-model!
               owm-16p
               (mk-base-obs 2180 'Zerg
                            (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                            (list (hasheq 'id 2001 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                  (hasheq 'id 2002 'type 'spawning-pool 'x 156.0 'y 158.0 'build-progress 1.0))))]
       [four-lings (for/list ([i (in-range 4)])
                     (hasheq 'id (+ 2010 i) 'type 'zergling 'x 140.0 'y 148.0 'hp 35))]
       [s16-c (step-opponent-world-model!
               owm-16p
               (mk-base-obs 2500 'Zerg '() '() four-lings))]
       ;; True 14-Pool started at ~850f (`38s`): spotted at 1400f (bp=0.53)
       [owm-14p (make-opponent-world-model 'Zerg)]
       [s14 (step-opponent-world-model!
             owm-14p
             (mk-base-obs 1400 'Zerg
                          (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                          (list (hasheq 'id 2021 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                (hasheq 'id 2022 'type 'spawning-pool 'x 156.0 'y 158.0 'build-progress 0.53))))]
       ;; >= 6 Zerglings at 2600f (`<= 2700f`) without seeing Pool -> latches!
       [owm-6l (make-opponent-world-model 'Zerg)]
       [six-lings (for/list ([i (in-range 6)])
                    (hasheq 'id (+ 2030 i) 'type 'zergling 'x 70.0 'y 60.0 'hp 35))]
       [s6l (step-opponent-world-model!
             owm-6l
             (mk-base-obs 2600 'Zerg '() '() six-lings))])
  (check! (and (not (owm-early-pool-latched? s16-a))
               (not (owm-early-pool-latched? s16-b))
               (not (owm-early-pool-latched? s16-c))
               (= (owm-inferred-proxy-rush-floor s16-c) 0.0))
          (format "T5.1a: Standard 16-Pool + 4 anti-scout Lings MUST NOT false-latch early-pool, got (~a,~a,~a) floor=~a"
                  (owm-early-pool-latched? s16-a)
                  (owm-early-pool-latched? s16-b)
                  (owm-early-pool-latched? s16-c)
                  (owm-inferred-proxy-rush-floor s16-c)))
  (check! (and (owm-early-pool-latched? s14)
               (>= (owm-inferred-proxy-rush-floor s14) 0.70))
          (format "T5.1b: True 14-Pool (est-start approx 850 <= 950) must latch early-pool >= 0.70, got latch=~a floor=~a"
                  (owm-early-pool-latched? s14) (owm-inferred-proxy-rush-floor s14)))
  (check! (and (owm-early-pool-latched? s6l)
               (>= (owm-inferred-proxy-rush-floor s6l) 0.70))
          (format "T5.1c: >= 6 Zerglings at <= 2700f must latch early-pool >= 0.70, got latch=~a floor=~a"
                  (owm-early-pool-latched? s6l) (owm-inferred-proxy-rush-floor s6l))))

;; T5.2: Natural-choke wall Gateways (`~35t` from enemy main, `<= 16t` from enemy natural) count in
;;       `owm-home-prod-count`; spotting ONLY Assimilators MUST NOT latch `owm-scouted-enemy-main?`;
;;       and `missing-main-prod` requires `frame >= 2240` (`100s`) in both OWM and Bayesian posterior!
(let* ([owm-wall (make-opponent-world-model 'Protoss)]
       ;; Enemy main `(160, 160)`, enemy natural `(142, 150)`. Natural-choke Gateways at `(132, 138)`
       ;; (`dMain = 35.6t <= 44.0t`, `dNat = 15.6t <= 16.0t`) and `(135, 136)` (`dMain = 34.7t`).
       [s-wall (step-opponent-world-model!
                owm-wall
                (mk-base-obs 2500 'Protoss
                             (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                             (list (hasheq 'id 2101 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                   (hasheq 'id 2102 'type 'gateway 'x 132.0 'y 138.0 'build-progress 1.0)
                                   (hasheq 'id 2103 'type 'gateway 'x 135.0 'y 136.0 'build-progress 1.0))))]
       ;; Edge-vision scout (`15t > 11t` from enemy main) spotting ONLY Assimilators!
       [owm-gas-edge (make-opponent-world-model 'Protoss)]
       [s-gas-edge (step-opponent-world-model!
                    owm-gas-edge
                    (mk-base-obs 2400 'Protoss
                                 (list (hasheq 'id 10 'type 'probe 'x 149.0 'y 149.0))
                                 (list (hasheq 'id 2111 'type 'assimilator 'x 164.0 'y 158.0 'build-progress 1.0))))]
       ;; Main scouted with `0` prod at `2000f` (`89s < 2240f`) vs `2300f` (`103s >= 2240f`)!
       [owm-gate (make-opponent-world-model 'Terran)]
       [s-2000 (step-opponent-world-model!
                owm-gate
                (mk-base-obs 2000 'Terran
                             (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                             (list (hasheq 'id 2121 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0))))]
       [s-2300 (step-opponent-world-model!
                owm-gate
                (mk-base-obs 2300 'Terran '() '()))]
       [p-2000 (compute-bayesian-proxy-all-in-posterior
                #:prior 0.12 #:home-production-count 0 #:expected-home-production 1
                #:enemy-natural-taken? #f #:scouted-enemy-main? #t
                #:enemy-gas-count 1 #:frame 2000 #:home-tech-count 0 #:enemy-race 'Terran)]
       [p-2300 (compute-bayesian-proxy-all-in-posterior
                #:prior 0.12 #:home-production-count 0 #:expected-home-production 1
                #:enemy-natural-taken? #f #:scouted-enemy-main? #t
                #:enemy-gas-count 1 #:frame 2300 #:home-tech-count 0 #:enemy-race 'Terran)])
  (check! (and (= (owm-home-prod-count s-wall) 2)
               (= (owm-inferred-proxy-rush-floor s-wall) 0.0))
          (format "T5.2a: Natural-choke wall Gateways (approx 35t from main) must count in home-prod (=2) with floor=0.0, got prod=~a floor=~a"
                  (owm-home-prod-count s-wall) (owm-inferred-proxy-rush-floor s-wall)))
  (check! (and (not (owm-scouted-enemy-main? s-gas-edge))
               (= (owm-inferred-proxy-rush-floor s-gas-edge) 0.0))
          (format "T5.2b: Edge-vision Assimilator alone MUST NOT latch scouted-enemy-main?, got main=~a floor=~a"
                  (owm-scouted-enemy-main? s-gas-edge) (owm-inferred-proxy-rush-floor s-gas-edge)))
  (check! (and (= (owm-inferred-proxy-rush-floor s-2000) 0.0)
               (< p-2000 0.20)
               (>= (owm-inferred-proxy-rush-floor s-2300) 0.80)
               (>= p-2300 0.80))
          (format "T5.2c: missing-main-prod must wait for >= 2240f (0.0/<0.20 @ 2000f, >=0.80 @ 2300f), got owm=~a->~a bayes=~a->~a"
                  (owm-inferred-proxy-rush-floor s-2000)
                  (owm-inferred-proxy-rush-floor s-2300)
                  p-2000 p-2300)))

;; T5.3: Standard `PvP` 2-Gate 2-Gas macro (`2:00..2:39`, `2688..3583f`) MUST NOT false-fire
;;       `one-base-double-gas?` or `rush_high`, while Proxy Stargate (`1` Gate `2` Gas `0` tech @ `2:15`)
;;       and Proxy Robo (`2` Gates `2` Gas `0` tech @ `2:40`) STILL fire cleanly!
(let* ([owm-pvp (make-opponent-world-model 'Protoss)]
       [s-pvp-215 (step-opponent-world-model!
                   owm-pvp
                   (mk-base-obs 3024 'Protoss
                                (list (hasheq 'id 10 'type 'probe 'x 158.0 'y 158.0))
                                (list (hasheq 'id 2201 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hasheq 'id 2202 'type 'gateway 'x 154.0 'y 156.0 'build-progress 1.0)
                                      (hasheq 'id 2203 'type 'gateway 'x 154.0 'y 152.0 'build-progress 1.0)
                                      (hasheq 'id 2204 'type 'cybernetics-core 'x 156.0 'y 154.0 'build-progress 1.0)
                                      (hasheq 'id 2205 'type 'assimilator 'x 164.0 'y 158.0 'build-progress 1.0)
                                      (hasheq 'id 2206 'type 'assimilator 'x 158.0 'y 166.0 'build-progress 1.0))))]
       [p-pvp-215 (compute-bayesian-proxy-all-in-posterior
                   #:prior 0.12 #:home-production-count 2 #:expected-home-production 2
                   #:enemy-natural-taken? #f #:scouted-enemy-main? #t
                   #:enemy-gas-count 2 #:frame 3024 #:home-tech-count 0 #:enemy-race 'Protoss)]
       [p-pvp-215-tech1 (compute-bayesian-proxy-all-in-posterior
                         #:prior 0.12 #:home-production-count 2 #:expected-home-production 2
                         #:enemy-natural-taken? #f #:scouted-enemy-main? #t
                         #:enemy-gas-count 2 #:frame 3024 #:home-tech-count 1 #:enemy-race 'Protoss)]
       ;; Same Protoss still on 1 base with 2 gas at 2:40 (`3584f`) -> NOW activates!
       [s-pvp-240 (step-opponent-world-model! owm-pvp (mk-base-obs 3584 'Protoss '() '()))])
  (check! (and (not (owm-enemy-1base-double-gas? s-pvp-215))
               (= (owm-inferred-proxy-rush-floor s-pvp-215) 0.0)
               (< p-pvp-215 0.20)
               (< p-pvp-215-tech1 0.20))
          (format "T5.3a: Standard PvP 2-Gate 2-Gas @ 2:15 (3024f < 3584f) MUST NOT fire rush, got 1b2g=~a floor=~a p0=~a p1=~a"
                  (owm-enemy-1base-double-gas? s-pvp-215)
                  (owm-inferred-proxy-rush-floor s-pvp-215)
                  p-pvp-215 p-pvp-215-tech1))
  (check! (and (owm-enemy-1base-double-gas? s-pvp-240)
               (>= (owm-inferred-proxy-rush-floor s-pvp-240) 0.78))
          (format "T5.3b: 1-base 2-Gas Protoss still unexpanded @ 2:40 (3584f) must activate >= 0.78, got 1b2g=~a floor=~a"
                  (owm-enemy-1base-double-gas? s-pvp-240)
                  (owm-inferred-proxy-rush-floor s-pvp-240))))

;; T5.4: `lib/mirror-mind-predictor.rkt` natural-pad expansion-block exclusion:
;;       Lone `pylon` or `engineering-bay` at our natural pad (`dNat <= 7.5t`, `dMain > 16.0t`)
;;       MUST NOT trigger `proxy-or-rush-detected?` or `'proxy-production-or-all-in`;
;;       >= 2 Pylons (Cannon Rush), combat/production proxy, or in-main Pylon MUST trigger!
(let ()
  (define (eval-bldg-case erace bldgs)
    (define mm (make-mirror-mind-state #:our-race 'Zerg #:enemy-race erace))
    (define ledger
      (compute-opponent-shadow-ledger mm 2100 '() bldgs
                                      #:base-x 32 #:base-y 32
                                      #:nat-x 50 #:nat-y 42))
    (define reading
      (interpret-opponent-actions mm 2100 '() bldgs ledger
                                  #:base-x 32 #:base-y 32
                                  #:nat-x 50 #:nat-y 42))
    (values (action-lens-reading-proxy-or-rush-detected? reading)
            (shadow-ledger-dark-matter-hypothesis ledger)))
  (define-values (lone-pylon-rush? lone-pylon-hyp)
    (eval-bldg-case 'Protoss
                    (list (hasheq 'id 3001 'type 'pylon 'x 50.0 'y 42.0 'hp 200))))
  (define-values (lone-ebay-rush? lone-ebay-hyp)
    (eval-bldg-case 'Terran
                    (list (hasheq 'id 3002 'type 'engineering-bay 'x 51.0 'y 43.0 'hp 850))))
  (define-values (two-pylon-rush? _two-pylon-hyp)
    (eval-bldg-case 'Protoss
                    (list (hasheq 'id 3003 'type 'pylon 'x 50.0 'y 42.0 'hp 200)
                          (hasheq 'id 3004 'type 'pylon 'x 52.0 'y 44.0 'hp 200))))
  (define-values (cannon-rush? _cannon-hyp)
    (eval-bldg-case 'Protoss
                    (list (hasheq 'id 3005 'type 'pylon 'x 50.0 'y 42.0 'hp 200)
                          (hasheq 'id 3006 'type 'photon-cannon 'x 51.0 'y 43.0 'hp 150))))
  (define-values (proxy-rax-rush? _rax-hyp)
    (eval-bldg-case 'Terran
                    (list (hasheq 'id 3007 'type 'barracks 'x 50.0 'y 42.0 'hp 1000))))
  (define-values (in-main-pylon-rush? _main-pylon-hyp)
    (eval-bldg-case 'Protoss
                    (list (hasheq 'id 3008 'type 'pylon 'x 38.0 'y 36.0 'hp 200))))
  ;; Also verify full `step-mirror-mind-predictor!` propagates nat-x/nat-y cleanly!
  (define mm-step (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss))
  (void (step-mirror-mind-predictor!
         mm-step
         (hasheq 'frame 2100 'race 'Zerg 'enemy-race 'Protoss
                 'base-x 32 'base-y 32 'natural-x 50 'natural-y 42
                 'enemy-x 160 'enemy-y 160 'enemy-expand-x 142 'enemy-expand-y 150
                 'ally-units '() 'ally-buildings '() 'enemy-units '()
                 'enemy-buildings (list (hasheq 'id 3009 'type 'pylon 'x 50.0 'y 42.0 'hp 200)))))
  (define step-reading (mirror-mind-state-last-action-reading mm-step))
  (define step-ledger (mirror-mind-state-last-shadow-ledger mm-step))
  (check! (and (not lone-pylon-rush?)
               (not (eq? lone-pylon-hyp 'proxy-production-or-all-in))
               (not lone-ebay-rush?)
               (not (eq? lone-ebay-hyp 'proxy-production-or-all-in))
               (not (action-lens-reading-proxy-or-rush-detected? step-reading))
               (not (eq? (shadow-ledger-dark-matter-hypothesis step-ledger)
                         'proxy-production-or-all-in)))
          (format "T5.4a: Lone nat-pad pylon/engineering-bay must NOT fire proxy-or-rush or proxy-all-in hyp, got pylon=(~a,~a) ebay=(~a,~a) step=(~a,~a)"
                  lone-pylon-rush? lone-pylon-hyp
                  lone-ebay-rush? lone-ebay-hyp
                  (action-lens-reading-proxy-or-rush-detected? step-reading)
                  (shadow-ledger-dark-matter-hypothesis step-ledger)))
  (check! (and two-pylon-rush? cannon-rush? proxy-rax-rush? in-main-pylon-rush?)
          (format "T5.4b: >=2 nat Pylons, Cannon, Proxy Rax, and in-main Pylon MUST all trigger proxy-or-rush, got ~a/~a/~a/~a"
                  two-pylon-rush? cannon-rush? proxy-rax-rush? in-main-pylon-rush?)))

(printf "l85-proxy-and-1base-belief-test: ~a passed, ~a failed\n" passed failed)
(when (> failed 0)
  (exit 1))
