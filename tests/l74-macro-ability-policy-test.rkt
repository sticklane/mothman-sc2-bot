#lang racket/base

;; =============================================================================
;; Loop 74 Lane A Unit Test Suite (`tests/l74-macro-ability-policy-test.rkt`)
;;
;; Verifies Loop 74 Lane A (`lib/sc2-game-constants.rkt` &
;; `lib/plan/macro-ability-policy.rkt`, pure L0 Guard 9d):
;;   1. `SC2-QUEEN-TUMOR-SURPLUS-ENERGY` = `75`.
;;   2. `select-early-probe-chrono-pairs` cuts off at `4704f` (3:30) OR `28w`
;;      while still boosting at `2400f / 24w`.
;;   3. `select-protoss-chrono-target-policy` / `score-protoss-chrono-target-policy`:
;;      - Promotes `cybernetics-core` / `robotics-facility` ahead of `nexus` at
;;        `4800f / 26w` and `3800f / 28w` (while `2400f / 22w` stays Nexus-first);
;;      - Post-pivot Robo scores `920.0` (`945.0` under facility pressure, `< 955.0`);
;;      - `#:has-ally-caster? #t` holds `50..99e` Nexus at `>= 52w` (boosts at `>= 100e`),
;;        while default `#:has-ally-caster? #f` preserves legacy `62w / 75e` boost.
;;   4. `evaluate-protoss-nexus-recharge-policy` holds `75e` Nexus when a dry
;;      Sentry/HT is `23.0t` away (default `approach-hold-range = 24.5t`).
;;   5. `evaluate-terran-mule-policy`: lone `1`-OC Terran vs Protoss at `5800f`
;;      with `cloak-seen? = #f` allows MULE at `55e`, while `2`-OC at `5800f`
;;      and `1`-OC at `7000f` still hold `'(101)`.
;;   6. `evaluate-terran-supply-drop-policy`: fires at `4500f` & `18000f` when
;;      `supply-left <= 0`, and fires peacefully on `2` OCs non-cloak when
;;      `supply-left = -2` with `depot-nearly-done? = #t` (preserving `1`-OC
;;      `supply-left = 0` and cloak guards).
;; =============================================================================

(require racket/list
         racket/set
         racket/format
         "../lib/sc2-game-constants.rkt"
         "../lib/plan/macro-ability-policy.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (mk-oc tag en [x 30.0] [y 30.0])
  (macro-oc-info tag x y (exact->inexact en)))

(define (mk-th tag sym [x 30.0] [y 30.0])
  (macro-th-info tag sym x y #t #f))

(define (mk-depot tag [x 34.0] [y 30.0] #:done? [done? #t] #:up? [up? #f])
  (macro-depot-info tag 'supply-depot x y done? up?))

(define (mk-nx tag en [x 30.0] [y 30.0] #:tp? [tp? #t] #:cb? [cb? #f])
  (macro-nexus-info tag x y (exact->inexact en) tp? cb?))

(define (mk-caster tag sym x y en)
  (macro-caster-info tag sym x y (exact->inexact en) #f))

(define (mk-self sym tid x y #:struct? [s? #f] #:worker? [w? #f])
  (macro-self-unit-info sym tid x y 8.0 s? w? #t))

;; =============================================================================
;; 1. Queen Creep-Tumor Surplus Energy Floor = 75
;; =============================================================================
(check! (= SC2-QUEEN-TUMOR-SURPLUS-ENERGY 75)
        (format "1. SC2-QUEEN-TUMOR-SURPLUS-ENERGY must equal 75; got ~a"
                SC2-QUEEN-TUMOR-SURPLUS-ENERGY))

;; =============================================================================
;; 2. Early Probe Chrono Cutoff (`4704f` / `28w`)
;; =============================================================================
(let ()
  (define nx1 (mk-nx 101 60.0))
  (define p-early
    (select-early-probe-chrono-pairs
     #:loop 2400 #:worker-count 24 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (define p-loop-cut
    (select-early-probe-chrono-pairs
     #:loop 4800 #:worker-count 24 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (define p-worker-cut
    (select-early-probe-chrono-pairs
     #:loop 3600 #:worker-count 28 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (check! (and (equal? p-early '((101 . 101)))
               (null? p-loop-cut)
               (null? p-worker-cut))
          (format "2. select-early-probe-chrono-pairs must boost at 2400/24w and stop at 4800/24w or 3600/28w; early=~s loop=~s w=~s"
                  p-early p-loop-cut p-worker-cut)))

;; =============================================================================
;; 3. Protoss Chrono Pivot (`4704f / 28w`), Robo Promotion & Caster Hold
;; =============================================================================
(let ()
  (define c-nx   (macro-chrono-candidate-info 101 'nexus))
  (define c-cyb  (macro-chrono-candidate-info 102 'cybernetics-core))
  (define c-robo (macro-chrono-candidate-info 103 'robotics-facility))
  (define c-frg  (macro-chrono-candidate-info 104 'forge))

  ;; 3a: 2400f/22w stays Nexus-first; 4800f/26w picks CyberCore over Nexus; 3800f/28w picks Robo over Nexus
  (define pick-early
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-cyb c-robo) #:loop 2400 #:worker-count 22 #:nexus-energy 60.0))
  (define pick-4800
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-cyb) #:loop 4800 #:worker-count 26 #:nexus-energy 60.0))
  (define pick-28w
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-robo) #:loop 3800 #:worker-count 28 #:nexus-energy 60.0))
  (check! (and pick-early (= (macro-chrono-candidate-info-tag pick-early) 101)
               pick-4800  (= (macro-chrono-candidate-info-tag pick-4800) 102)
               pick-28w   (= (macro-chrono-candidate-info-tag pick-28w) 103))
          (format "3a. Chrono pivot must keep 2400/22w Nexus-first and promote CyberCore@4800/26w & Robo@3800/28w; got early=~s 4800=~s 28w=~s"
                  pick-early pick-4800 pick-28w))

  ;; 3b: Robo post-pivot scores 920.0 (945.0 under facility pressure, strictly < Forge 955.0, exact +25 delta)
  (define sc-robo-norm
    (score-protoss-chrono-target-policy 'robotics-facility #:loop 6000 #:worker-count 40 #:nexus-energy 60.0))
  (define sc-robo-pres
    (score-protoss-chrono-target-policy 'robotics-facility #:loop 6000 #:worker-count 40 #:nexus-energy 60.0
                                        #:facility-override-pressure? #t))
  (define sc-forge
    (score-protoss-chrono-target-policy 'forge #:loop 6000 #:worker-count 40 #:nexus-energy 60.0))
  (define pick-frg-vs-robo
    (select-protoss-chrono-target-policy
     #:candidates (list c-robo c-frg) #:loop 6000 #:worker-count 40 #:nexus-energy 60.0
     #:facility-override-pressure? #t))
  (check! (and (= sc-robo-norm 920.0)
               (= sc-robo-pres 945.0)
               (< sc-robo-pres sc-forge)
               pick-frg-vs-robo (= (macro-chrono-candidate-info-tag pick-frg-vs-robo) 104))
          (format "3b. Post-pivot Robo must score 920/945 (< Forge 955); norm=~a pres=~a frg=~a pick=~s"
                  sc-robo-norm sc-robo-pres sc-forge pick-frg-vs-robo))

  ;; 3c: #:has-ally-caster? #t holds 75e Nexus at >= 52w, allows >= 100e, and default #f preserves 62w/75e
  (define hold-caster-75
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx) #:loop 7500 #:worker-count 54 #:nexus-energy 75.0
     #:has-ally-caster? #t))
  (define allow-caster-100
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx) #:loop 7500 #:worker-count 54 #:nexus-energy 100.0
     #:has-ally-caster? #t))
  (define allow-default-62w-75
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx) #:loop 7500 #:worker-count 62 #:nexus-energy 75.0))
  (check! (and (not hold-caster-75)
               allow-caster-100 (= (macro-chrono-candidate-info-tag allow-caster-100) 101)
               allow-default-62w-75 (= (macro-chrono-candidate-info-tag allow-default-62w-75) 101))
          (format "3c. has-ally-caster?=#t must hold 75e Nexus at >=52w, boost at 100e, and preserve default 62w/75e; hold75=~s allow100=~s def62=~s"
                  hold-caster-75 allow-caster-100 allow-default-62w-75)))

;; =============================================================================
;; 4. Protoss Recharge Approach Hold Range (`+10.0` -> `24.5t` Default)
;; =============================================================================
(let ()
  (define nx1 (mk-nx 101 75.0 30.0 30.0))
  (define sentry-23t (mk-caster 201 'sentry 53.0 30.0 40.0))
  (define sentry-26t (mk-caster 202 'sentry 56.0 30.0 40.0))
  (define d-23
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list nx1) #:ally-casters (list sentry-23t)
     #:enemy-units-present? #f #:recharge-available? #t #:recharge-off-cooldown? #t))
  (define d-26
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list nx1) #:ally-casters (list sentry-26t)
     #:enemy-units-present? #f #:recharge-available? #t #:recharge-off-cooldown? #t))
  (check! (and (not (protoss-nexus-recharge-decision-cast-nexus-tag d-23))
               (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags d-23) 101)
               (not (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags d-26) 101)))
          (format "4. Recharge approach-hold-range default (24.5t) must hold 75e Nexus at 23.0t and not at 26.0t; h23=~s h26=~s"
                  (protoss-nexus-recharge-decision-hold-nexus-tags d-23)
                  (protoss-nexus-recharge-decision-hold-nexus-tags d-26))))

;; =============================================================================
;; 5. Terran 1-OC `4:00-5:00` Non-Cloak MULE Release (`5376..6719f`)
;; =============================================================================
(let ()
  (define scvs16
    (for/list ([i (in-range 16)])
      (mk-self 'scv 45 (+ 26.0 (* 0.2 i)) 30.0 #:worker? #t)))
  (define self-units (cons (mk-self 'barracks 21 38.0 34.0 #:struct? #t) scvs16))
  (define oc1-55 (mk-oc 101 55.0))
  (define oc2-55 (mk-oc 102 55.0 52.0 34.0))
  (define th1 (list (mk-th 101 'orbital-command)))
  (define th2 (list (mk-th 101 'orbital-command) (mk-th 102 'orbital-command 52.0 34.0)))

  ;; 5a: 1 OC vs Protoss at 5800f, cloak-seen?=#f -> allows MULE at 55e (no proactive scan hold!)
  (define p-1oc-5800
    (evaluate-terran-mule-policy
     #:latch (make-macro-policy-latch) #:loop 5800 #:ready-ocs (list oc1-55)
     #:self-units self-units #:enemy-units '() #:townhalls th1 #:worker-count 22
     #:known-enemy-race 'Protoss))
  ;; 5b: 2 OCs vs Protoss at 5800f -> still holds 1 OC '(101)
  (define p-2oc-5800
    (evaluate-terran-mule-policy
     #:latch (make-macro-policy-latch) #:loop 5800 #:ready-ocs (list oc1-55 oc2-55)
     #:self-units self-units #:enemy-units '() #:townhalls th2 #:worker-count 32
     #:known-enemy-race 'Protoss))
  ;; 5c: 1 OC vs Protoss at 7000f (>= 5:00) -> still holds '(101)
  (define p-1oc-7000
    (evaluate-terran-mule-policy
     #:latch (make-macro-policy-latch) #:loop 7000 #:ready-ocs (list oc1-55)
     #:self-units self-units #:enemy-units '() #:townhalls th1 #:worker-count 24
     #:known-enemy-race 'Protoss))
  (check! (and (null? (terran-mule-policy-result-proactive-scan-oc-tags p-1oc-5800))
               (terran-oc-mule-allowed? p-1oc-5800 101 55.0)
               (equal? (terran-mule-policy-result-proactive-scan-oc-tags p-2oc-5800) '(101))
               (equal? (terran-mule-policy-result-proactive-scan-oc-tags p-1oc-7000) '(101)))
          (format "5. 1-OC TvP@5800 non-cloak must allow MULE@55e while 2-OC@5800 & 1-OC@7000 still hold '(101); 1oc58=~s 2oc58=~s 1oc70=~s"
                  (terran-mule-policy-result-proactive-scan-oc-tags p-1oc-5800)
                  (terran-mule-policy-result-proactive-scan-oc-tags p-2oc-5800)
                  (terran-mule-policy-result-proactive-scan-oc-tags p-1oc-7000))))

;; =============================================================================
;; 6. Terran Supply Drop Broadening (`4032..20160f` & 2-OC `<= -2` Severe Block)
;; =============================================================================
(let ()
  (define oc1 (mk-oc 101 60.0))
  (define oc2 (mk-oc 102 65.0 52.0 34.0))
  (define dep (mk-depot 201))

  (define sd-4500
    (evaluate-terran-supply-drop-policy
     #:loop 4500 #:supply-used 39 #:supply-cap 39 #:ready-ocs (list oc1) #:depots (list dep)))
  (define sd-18000
    (evaluate-terran-supply-drop-policy
     #:loop 18000 #:supply-used 140 #:supply-cap 140 #:ready-ocs (list oc1) #:depots (list dep)))
  (define sd-early-skip
    (evaluate-terran-supply-drop-policy
     #:loop 3800 #:supply-used 31 #:supply-cap 31 #:ready-ocs (list oc1) #:depots (list dep)))
  (define sd-2oc-severe
    (evaluate-terran-supply-drop-policy
     #:loop 7000 #:supply-used 56 #:supply-cap 54 #:ready-ocs (list oc1 oc2) #:depots (list dep)
     #:depot-nearly-done? #t #:under-pressure? #f #:cloak-seen? #f))
  (define sd-1oc-nearly-done-skip
    (evaluate-terran-supply-drop-policy
     #:loop 7000 #:supply-used 54 #:supply-cap 54 #:ready-ocs (list oc1) #:depots (list dep)
     #:depot-nearly-done? #t #:under-pressure? #f #:cloak-seen? #f))
  (define sd-2oc-cloak-skip
    (evaluate-terran-supply-drop-policy
     #:loop 7000 #:supply-used 56 #:supply-cap 54 #:ready-ocs (list oc1 oc2) #:depots (list dep)
     #:depot-nearly-done? #t #:under-pressure? #f #:cloak-seen? #t))
  (check! (and (equal? (terran-supply-drop-decision-depot-tag sd-4500) 201)
               (equal? (terran-supply-drop-decision-depot-tag sd-18000) 201)
               (not (terran-supply-drop-decision-depot-tag sd-early-skip))
               (equal? (terran-supply-drop-decision-depot-tag sd-2oc-severe) 201)
               (not (terran-supply-drop-decision-depot-tag sd-1oc-nearly-done-skip))
               (not (terran-supply-drop-decision-depot-tag sd-2oc-cloak-skip)))
          (format "6. Supply drop must fire at 4500f/18000f & 2-OC -2 severe block non-cloak, and skip <4032f / 1-OC nearly-done / cloak; got 4500=~s 18k=~s 3800=~s sev=~s 1oc=~s clk=~s"
                  sd-4500 sd-18000 sd-early-skip sd-2oc-severe sd-1oc-nearly-done-skip sd-2oc-cloak-skip)))

(printf "l74-macro-ability-policy-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
