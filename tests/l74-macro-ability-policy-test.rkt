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
;; 1. Queen Creep-Tumor Surplus Energy Floor = 45 (Restored in Loop 75)
;; =============================================================================
(check! (= SC2-QUEEN-TUMOR-SURPLUS-ENERGY 45)
        (format "1. SC2-QUEEN-TUMOR-SURPLUS-ENERGY must equal 45; got ~a"
                SC2-QUEEN-TUMOR-SURPLUS-ENERGY))

;; =============================================================================
;; 2. Early Probe Chrono Cutoff (`6720f` / `34w` / `5376f & 28w`, Restored in Loop 75)
;; =============================================================================
(let ()
  (define nx1 (mk-nx 101 60.0))
  (define p-early
    (select-early-probe-chrono-pairs
     #:loop 2400 #:worker-count 24 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (define p-mid-boost
    (select-early-probe-chrono-pairs
     #:loop 4800 #:worker-count 24 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (define p-loop-cut
    (select-early-probe-chrono-pairs
     #:loop 6800 #:worker-count 24 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (define p-worker-cut
    (select-early-probe-chrono-pairs
     #:loop 3600 #:worker-count 34 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (define p-4m-28w-cut
    (select-early-probe-chrono-pairs
     #:loop 5400 #:worker-count 28 #:ready-nexuses (list nx1)
     #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #f
     #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t)))
  (check! (and (equal? p-early '((101 . 101)))
               (equal? p-mid-boost '((101 . 101)))
               (null? p-loop-cut)
               (null? p-worker-cut)
               (null? p-4m-28w-cut))
          (format "2. select-early-probe-chrono-pairs must boost at 2400/24w & 4800/24w and stop at 6800/24w, 3600/34w, or 5400/28w; early=~s mid=~s loop=~s w=~s m28=~s"
                  p-early p-mid-boost p-loop-cut p-worker-cut p-4m-28w-cut)))

;; =============================================================================
;; 3. Protoss Chrono Pivot (`5376f / 34w`, Restored in Loop 75) & Robo 900/925
;; =============================================================================
(let ()
  (define c-nx   (macro-chrono-candidate-info 101 'nexus))
  (define c-cyb  (macro-chrono-candidate-info 102 'cybernetics-core))
  (define c-robo (macro-chrono-candidate-info 103 'robotics-facility))
  (define c-frg  (macro-chrono-candidate-info 104 'forge))

  ;; 3a: 2400f/22w & 4800f/26w stay Nexus-first; 5500f/26w picks CyberCore; 3800f/34w picks Robo
  (define pick-early
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-cyb c-robo) #:loop 2400 #:worker-count 22 #:nexus-energy 60.0))
  (define pick-4800
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-cyb) #:loop 4800 #:worker-count 26 #:nexus-energy 60.0))
  (define pick-5500
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-cyb) #:loop 5500 #:worker-count 26 #:nexus-energy 60.0))
  (define pick-34w
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx c-robo) #:loop 3800 #:worker-count 34 #:nexus-energy 60.0))
  (check! (and pick-early (= (macro-chrono-candidate-info-tag pick-early) 101)
               pick-4800  (= (macro-chrono-candidate-info-tag pick-4800) 101)
               pick-5500  (= (macro-chrono-candidate-info-tag pick-5500) 102)
               pick-34w   (= (macro-chrono-candidate-info-tag pick-34w) 103))
          (format "3a. Chrono pivot must keep 2400/22w & 4800/26w Nexus-first and promote CyberCore@5500/26w & Robo@3800/34w; got early=~s 4800=~s 5500=~s 34w=~s"
                  pick-early pick-4800 pick-5500 pick-34w))

  ;; 3b: Robo post-pivot scores 900.0 (925.0 under facility pressure, strictly < Forge 955.0, exact +25 delta)
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
  (check! (and (= sc-robo-norm 900.0)
               (= sc-robo-pres 925.0)
               (< sc-robo-pres sc-forge)
               pick-frg-vs-robo (= (macro-chrono-candidate-info-tag pick-frg-vs-robo) 104))
          (format "3b. Post-pivot Robo must score 900/925 (< Forge 955); norm=~a pres=~a frg=~a pick=~s"
                  sc-robo-norm sc-robo-pres sc-forge pick-frg-vs-robo))

  ;; 3c: #:has-ally-caster? accepted harmlessly without blocking 54w/75e Nexus (reverted in Loop 75),
  ;;     while #:dry-caster-near? #t still holds 75e and allows 100e!
  (define allow-caster-75
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx) #:loop 7500 #:worker-count 54 #:nexus-energy 75.0
     #:has-ally-caster? #t))
  (define hold-dry-75
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx) #:loop 7500 #:worker-count 54 #:nexus-energy 75.0
     #:dry-caster-near? #t))
  (define allow-dry-100
    (select-protoss-chrono-target-policy
     #:candidates (list c-nx) #:loop 7500 #:worker-count 54 #:nexus-energy 100.0
     #:dry-caster-near? #t))
  (check! (and allow-caster-75 (= (macro-chrono-candidate-info-tag allow-caster-75) 101)
               (not hold-dry-75)
               allow-dry-100 (= (macro-chrono-candidate-info-tag allow-dry-100) 101))
          (format "3c. has-ally-caster?=#t must allow 54w/75e Nexus (Loop 75 revert) while dry-caster-near?=#t still holds 75e & boosts 100e; allow75=~s holdDry=~s allow100=~s"
                  allow-caster-75 hold-dry-75 allow-dry-100)))

;; =============================================================================
;; 4. Protoss Recharge Approach Hold Range (`+4.0` -> `18.5t` Default, Restored in Loop 75)
;; =============================================================================
(let ()
  (define nx1 (mk-nx 101 75.0 30.0 30.0))
  (define sentry-175t (mk-caster 201 'sentry 47.5 30.0 40.0))
  (define sentry-20t  (mk-caster 202 'sentry 50.0 30.0 40.0))
  (define d-175
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list nx1) #:ally-casters (list sentry-175t)
     #:enemy-units-present? #f #:recharge-available? #t #:recharge-off-cooldown? #t))
  (define d-20
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list nx1) #:ally-casters (list sentry-20t)
     #:enemy-units-present? #f #:recharge-available? #t #:recharge-off-cooldown? #t))
  (check! (and (not (protoss-nexus-recharge-decision-cast-nexus-tag d-175))
               (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags d-175) 101)
               (not (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags d-20) 101)))
          (format "4. Recharge approach-hold-range default (18.5t) must hold 75e Nexus at 17.5t and not at 20.0t; h175=~s h20=~s"
                  (protoss-nexus-recharge-decision-hold-nexus-tags d-175)
                  (protoss-nexus-recharge-decision-hold-nexus-tags d-20))))

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
