#lang racket/base

;; =============================================================================
;; `tests/macro-ability-policy-test.rkt`
;; Loop 62 Phase 2 Unit Verification Suite for:
;;   1. `lib/plan/macro-ability-policy.rkt` (Terran MULE vs Scan, safe mineral
;;      patch selector, Protoss Nexus Energy Recharge vs Chrono Boost arbitration,
;;      early 0:00-5:00 Probe Chrono Boost)
;;   2. `sc2-upgrade-researcher-slot` single-source authority across ALL 70+
;;      upgrade symbols & legacy aliases in `lib/priority-macro-brain.rkt`
;;   3. Live-observation (`live-obs? = #t`) `4126` duplicate-cast guards in
;;      `lib/plan/static-defense.rkt` and `lib/plan/situational-counter.rkt`
;; =============================================================================

(require racket/list
         racket/set
         (only-in "../lib/sc2-game-constants.rkt"
                  sc2-spell-cast-range)
         "../lib/plan/macro-ability-policy.rkt"
         "../lib/priority-macro-brain.rkt"
         (only-in "../lib/plan/static-defense.rkt"
                  plan-shield-battery-and-nexus-overcharge-tactics)
         (only-in "../lib/plan/situational-counter.rkt"
                  evaluate-situational-counter-plan
                  situational-counter-plan-ability-actions
                  situational-counter-plan-primary-situation))

(define passed 0)
(define failed 0)

(define (check-true name cond-val)
  (if cond-val
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL [~a]\n" name))))

(define (check-eq name got want)
  (if (equal? got want)
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL [~a]: got ~s, want ~s\n" name got want))))

;; Helper constructors
(define (mk-oc tag energy [x 30.0] [y 30.0])
  (macro-oc-info tag x y (exact->inexact energy)))

(define (mk-th tag sym x y #:completed? [completed? #t] #:flying? [flying? #f])
  (macro-th-info tag sym x y completed? flying?))

(define (mk-min tag x y [contents 1500] #:visible? [visible? #t])
  (macro-mineral-info tag x y contents visible?))

(define (mk-self sym tid x y [z 8.0]
                 #:structure? [structure? #f]
                 #:worker? [worker? #f]
                 #:completed? [completed? #t])
  (macro-self-unit-info sym tid x y z structure? worker? completed?))

(define (mk-enemy sym tid x y [z 8.0]
                  #:cloak [cloak 0]
                  #:burrowed? [burrowed? #f]
                  #:flying? [flying? #f])
  (macro-enemy-info sym tid x y z cloak burrowed? flying?))

(define (mk-nx tag energy [x 30.0] [y 30.0]
               #:training-probe? [tp? #t]
               #:chrono-buffed? [cb? #f])
  (macro-nexus-info tag x y (exact->inexact energy) tp? cb?))

(define (mk-caster tag sym x y energy #:hallucination? [hal? #f])
  (macro-caster-info tag sym x y (exact->inexact energy) hal?))

(define std-scvs
  (for/list ([i (in-range 16)])
    (mk-self 'scv 45 (+ 26.0 (* 0.2 i)) 30.0 #:worker? #t)))

(define std-rax (mk-self 'barracks 21 38.0 34.0 #:structure? #t))
(define std-oc-self (mk-self 'orbital-command 132 30.0 30.0 #:structure? #t))
(define std-marines6
  (for/list ([i (in-range 6)])
    (mk-self 'marine 48 (+ 36.0 (* 0.3 i)) 32.0)))

(define std-ths (list (mk-th 101 'orbital-command 30.0 30.0)))

;; =============================================================================
;; 1. Terran MULE vs Scan Policy (`evaluate-terran-mule-policy`)
;; =============================================================================

;; 1a. Unprovoked TvT and TvZ: 50.0e floor on all OCs (never starved!)
(let ()
  (define latch (make-macro-policy-latch))
  (define p-tvt
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5800
     #:ready-ocs (list (mk-oc 101 55.0) (mk-oc 102 52.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Terran))
  (check-true "tvt-unprovoked-not-hard-blocked" (not (terran-mule-policy-result-hard-blocked? p-tvt)))
  (check-true "tvt-unprovoked-not-uphill" (not (terran-mule-policy-result-uphill-scan-reserve? p-tvt)))
  (check-eq "tvt-unprovoked-no-proactive-ocs" (terran-mule-policy-result-proactive-scan-oc-tags p-tvt) '())
  (check-true "tvt-unprovoked-oc1-mules-at-55e" (terran-oc-mule-allowed? p-tvt 101 55.0))
  (check-true "tvt-unprovoked-oc2-mules-at-52e" (terran-oc-mule-allowed? p-tvt 102 52.0))

  ;; Unprovoked TvZ even with enemy burrowed CreepTumor (137) visible -> still 50.0e!
  (reset-macro-policy-latch-for-new-match! latch)
  (define p-tvz
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5800
     #:ready-ocs (list (mk-oc 101 55.0) (mk-oc 102 52.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units (list (mk-enemy 'creep-tumor-burrowed 137 45.0 30.0 #:cloak 1 #:burrowed? #t))
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Zerg))
  (check-true "tvz-creep-tumor-no-hard-block" (not (terran-mule-policy-result-hard-blocked? p-tvz)))
  (check-true "tvz-creep-tumor-no-latch" (not (macro-policy-latch-seen-enemy-cloak? latch)))
  (check-true "tvz-creep-tumor-oc1-mules" (terran-oc-mule-allowed? p-tvz 101 55.0))
  (check-true "tvz-creep-tumor-oc2-mules" (terran-oc-mule-allowed? p-tvz 102 52.0)))

;; 1b. Unprovoked TvP >= 4:00 (5376f): 2-OC holds ONLY OC#1 @ 100e (OC#2 @ 50e); 3-OC holds top-2 @ 100e (OC#3 @ 50e)
(let ()
  (define latch (make-macro-policy-latch))
  (define p-tvp-2oc
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5800
     #:ready-ocs (list (mk-oc 101 80.0) (mk-oc 102 60.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-eq "tvp-4m-2oc-top1-reserved" (terran-mule-policy-result-proactive-scan-oc-tags p-tvp-2oc) '(101))
  (check-eq "tvp-4m-2oc-floor-100" (terran-mule-policy-result-proactive-scan-floor p-tvp-2oc) 100.0)
  (check-true "tvp-4m-2oc-oc1-holds-at-80e" (not (terran-oc-mule-allowed? p-tvp-2oc 101 80.0)))
  (check-true "tvp-4m-2oc-oc1-mules-at-100e" (terran-oc-mule-allowed? p-tvp-2oc 101 100.0))
  (check-true "tvp-4m-2oc-oc2-mules-at-60e" (terran-oc-mule-allowed? p-tvp-2oc 102 60.0))

  (define p-tvp-3oc
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5820
     #:ready-ocs (list (mk-oc 101 90.0) (mk-oc 102 75.0 56.0 30.0) (mk-oc 103 60.0 80.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0)
                       (mk-th 102 'orbital-command 56.0 30.0)
                       (mk-th 103 'orbital-command 80.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-eq "tvp-4m-3oc-top2-reserved" (terran-mule-policy-result-proactive-scan-oc-tags p-tvp-3oc) '(101 102))
  (check-true "tvp-4m-3oc-oc1-holds" (not (terran-oc-mule-allowed? p-tvp-3oc 101 90.0)))
  (check-true "tvp-4m-3oc-oc2-holds" (not (terran-oc-mule-allowed? p-tvp-3oc 102 75.0)))
  (check-true "tvp-4m-3oc-oc3-mules" (terran-oc-mule-allowed? p-tvp-3oc 103 60.0)))

;; 1c. TvP DT/WarpPrism scouted -> BOTH OCs hold 101.0e (even before 4:00 & persists via latch!)
(let ()
  (define latch (make-macro-policy-latch))
  (define p-dt-seen
    (evaluate-terran-mule-policy
     #:latch latch #:loop 4800
     #:ready-ocs (list (mk-oc 101 100.0) (mk-oc 102 100.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units (list (mk-enemy 'warp-prism 81 95.0 95.0 #:flying? #t))
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-eq "tvp-dt-prism-2oc-reserved" (terran-mule-policy-result-proactive-scan-oc-tags p-dt-seen) '(101 102))
  (check-eq "tvp-dt-prism-floor-101" (terran-mule-policy-result-proactive-scan-floor p-dt-seen) 101.0)
  (check-true "tvp-dt-prism-oc1-holds-100e" (not (terran-oc-mule-allowed? p-dt-seen 101 100.0)))
  (check-true "tvp-dt-prism-oc2-holds-100e" (not (terran-oc-mule-allowed? p-dt-seen 102 100.0)))
  (check-true "tvp-dt-prism-oc1-mules-101e" (terran-oc-mule-allowed? p-dt-seen 101 101.0))

  ;; After Warp Prism leaves vision, latch persists 2-OC 101e reserve; Raven or ready Turret clears it!
  (define p-dt-latched
    (evaluate-terran-mule-policy
     #:latch latch #:loop 4900
     #:ready-ocs (list (mk-oc 101 100.0) (mk-oc 102 100.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-true "tvp-dt-prism-persists-after-fow" (not (terran-oc-mule-allowed? p-dt-latched 102 100.0)))

  (define p-with-raven
    (evaluate-terran-mule-policy
     #:latch latch #:loop 4920
     #:ready-ocs (list (mk-oc 101 60.0) (mk-oc 102 60.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax (mk-self 'raven 56 35.0 30.0)) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-eq "raven-clears-proactive-scan" (terran-mule-policy-result-proactive-scan-oc-tags p-with-raven) '())
  (check-true "raven-allows-50e-mule" (terran-oc-mule-allowed? p-with-raven 101 60.0))

  (define p-with-turret
    (evaluate-terran-mule-policy
     #:latch latch #:loop 4940
     #:ready-ocs (list (mk-oc 101 60.0) (mk-oc 102 60.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax (mk-self 'missile-turret 23 32.0 32.0 #:structure? #t #:completed? #t))
                          std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-eq "ready-turret-clears-proactive-scan" (terran-mule-policy-result-proactive-scan-oc-tags p-with-turret) '())
  (check-true "ready-turret-allows-50e-mule" (terran-oc-mule-allowed? p-with-turret 101 60.0)))

;; 1d. TvT Banshee/StarportTL scouted -> top-1 OC holds 100.0e (OC#2 MULEs at 50e)
(let ()
  (define latch (make-macro-policy-latch))
  (define p-tvt-stl
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5900
     #:ready-ocs (list (mk-oc 101 80.0) (mk-oc 102 60.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units (list (mk-enemy 'starport-techlab 41 120.0 120.0))
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 16
     #:known-enemy-race 'Terran))
  (check-eq "tvt-stl-top1-reserved" (terran-mule-policy-result-proactive-scan-oc-tags p-tvt-stl) '(101))
  (check-true "tvt-stl-oc1-holds-80e" (not (terran-oc-mule-allowed? p-tvt-stl 101 80.0)))
  (check-true "tvt-stl-oc2-mules-60e" (terran-oc-mule-allowed? p-tvt-stl 102 60.0)))

;; 1e. Active uncovered cloak=1 or burrowed combat enemy within 32t -> hard-blocked? = #t even at 200e!
(let ()
  (define latch (make-macro-policy-latch))
  (define p-hard-cloak
    (evaluate-terran-mule-policy
     #:latch latch #:loop 6100
     #:ready-ocs (list (mk-oc 101 200.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units (list (mk-enemy 'dark-templar 76 42.0 32.0 #:cloak 1))
     #:townhalls std-ths
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-true "uncovered-dt-within-32t-hard-blocks" (terran-mule-policy-result-hard-blocked? p-hard-cloak))
  (check-true "uncovered-dt-blocks-even-at-200e" (not (terran-oc-mule-allowed? p-hard-cloak 101 200.0))))

;; 1f. Isolated Arena `sc2-ab-t10` (<= 8 SCVs, 0 macro infra, >= 6 Marines, OC @ 100e) -> holds 101e Scan!
(let ()
  (define latch (make-macro-policy-latch))
  (define p-t10
    (evaluate-terran-mule-policy
     #:latch latch #:loop 16
     #:ready-ocs (list (mk-oc 101 100.0))
     #:self-units (append (list std-oc-self) (take std-scvs 6) std-marines6)
     #:enemy-units '()
     #:townhalls std-ths
     #:worker-count 6
     #:known-enemy-race 'Protoss))
  (check-eq "arena-t10-top1-reserved" (terran-mule-policy-result-proactive-scan-oc-tags p-t10) '(101))
  (check-eq "arena-t10-floor-101" (terran-mule-policy-result-proactive-scan-floor p-t10) 101.0)
  (check-true "arena-t10-blocks-100e-mule" (not (terran-oc-mule-allowed? p-t10 101 100.0))))

;; 1g. Uphill Sieged Tank without air spotter -> 150.0e floor; WITH Viking spotter <= 16t -> clears to 50.0e!
(let ()
  (define latch (make-macro-policy-latch))
  (define tk-sieged (mk-self 'siege-tank-sieged 32 70.0 70.0 8.0))
  (define e-uphill  (mk-enemy 'stalker 74 70.0 82.0 10.0))
  (define p-uphill-blind
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5000
     #:ready-ocs (list (mk-oc 101 120.0))
     #:self-units (append (list std-oc-self std-rax tk-sieged) std-scvs)
     #:enemy-units (list e-uphill)
     #:townhalls std-ths
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-true "uphill-tank-blind-reserves-150e" (terran-mule-policy-result-uphill-scan-reserve? p-uphill-blind))
  (check-true "uphill-tank-blind-blocks-120e" (not (terran-oc-mule-allowed? p-uphill-blind 101 120.0)))
  (check-true "uphill-tank-blind-allows-150e" (terran-oc-mule-allowed? p-uphill-blind 101 150.0))

  (define p-uphill-spotted
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5020
     #:ready-ocs (list (mk-oc 101 120.0))
     #:self-units (append (list std-oc-self std-rax tk-sieged (mk-self 'viking-fighter 35 72.0 74.0 12.0)) std-scvs)
     #:enemy-units (list e-uphill)
     #:townhalls std-ths
     #:worker-count 16
     #:known-enemy-race 'Protoss))
  (check-true "uphill-tank-with-viking-clears-reserve" (not (terran-mule-policy-result-uphill-scan-reserve? p-uphill-spotted)))
  (check-true "uphill-tank-with-viking-allows-120e" (terran-oc-mule-allowed? p-uphill-spotted 101 120.0))

  ;; Blind uphill error 83 persists 44f then clears at +48f
  (define p-err83
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5100
     #:ready-ocs (list (mk-oc 101 120.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs)
     #:enemy-units '()
     #:townhalls std-ths
     #:worker-count 16
     #:known-enemy-race 'Terran
     #:blind-uphill-err-now? #t))
  (define p-err83-still
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5130
     #:ready-ocs (list (mk-oc 101 120.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs)
     #:enemy-units '()
     #:townhalls std-ths
     #:worker-count 16
     #:known-enemy-race 'Terran))
  (define p-err83-clear
    (evaluate-terran-mule-policy
     #:latch latch #:loop 5148
     #:ready-ocs (list (mk-oc 101 120.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs)
     #:enemy-units '()
     #:townhalls std-ths
     #:worker-count 16
     #:known-enemy-race 'Terran))
  (check-true "err83-reserves-150e" (terran-mule-policy-result-uphill-scan-reserve? p-err83))
  (check-true "err83-persists-30f" (terran-mule-policy-result-uphill-scan-reserve? p-err83-still))
  (check-true "err83-clears-at-48f" (not (terran-mule-policy-result-uphill-scan-reserve? p-err83-clear))))

;; =============================================================================
;; 2. Safe MULE Mineral Patch Selector (`select-safe-mule-mineral-patch-tag`)
;; =============================================================================

(let ()
  (define th1 (mk-th 201 'orbital-command 30.0 30.0))
  (define th2 (mk-th 202 'command-center 64.0 30.0))
  (define m-main (mk-min 301 25.0 30.0 1500))
  (define m-nat  (mk-min 302 69.0 30.0 1500))
  (define m-low  (mk-min 303 26.0 31.0 90))   ;; < 150 contents -> rejected
  (define m-fog  (mk-min 304 26.0 29.0 1500 #:visible? #f)) ;; not visible -> rejected

  ;; Combat enemy near Main (<= 11t) -> rejects Main patch 301, selects safe Nat patch 302
  (check-eq "safe-mule-rejects-threatened-main-picks-nat"
            (select-safe-mule-mineral-patch-tag
             30.0 30.0 (list th1 th2) (list m-main m-nat m-low m-fog)
             (list (mk-enemy 'zergling 105 28.0 30.0)))
            302)

  ;; Harmless enemy Probe/Overlord near Main -> ignored, selects closer rich Main patch 301!
  (check-eq "safe-mule-ignores-harmless-probe-and-overlord"
            (select-safe-mule-mineral-patch-tag
             30.0 30.0 (list th1 th2) (list m-main m-nat m-low m-fog)
             (list (mk-enemy 'probe 84 26.0 30.0)
                   (mk-enemy 'overlord 106 27.0 30.0 #:flying? #t)))
            301)

  ;; Both bases threatened -> returns 0 (never drop MULE into combat!)
  (check-eq "safe-mule-returns-0-when-all-bases-unsafe"
            (select-safe-mule-mineral-patch-tag
             30.0 30.0 (list th1 th2) (list m-main m-nat)
             (list (mk-enemy 'marine 48 28.0 30.0)
                   (mk-enemy 'marine 48 66.0 30.0)))
            0))

;; =============================================================================
;; 3. Protoss Nexus Energy Recharge (4126) vs Chrono Boost (3755)
;; =============================================================================

(let ()
  ;; 3a. Priority: HT (3) > Oracle (2) > Sentry (1) within cast-range <= 10t
  (define dec-prio
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 70.0 30.0 30.0))
     #:ally-casters (list (mk-caster 501 'sentry 34.0 30.0 30.0)
                          (mk-caster 502 'oracle 35.0 30.0 30.0)
                          (mk-caster 503 'high-templar 38.0 30.0 40.0)
                          (mk-caster 504 'high-templar 31.0 30.0 20.0 #:hallucination? #t))
     #:enemy-units-present? #t
     #:recharge-available? #t
     #:recharge-off-cooldown? #t))
  (check-eq "recharge-picks-real-ht-over-oracle-sentry-and-halluc"
            (list (protoss-nexus-recharge-decision-cast-nexus-tag dec-prio)
                  (protoss-nexus-recharge-decision-cast-target-tag dec-prio))
            '(401 503))

  ;; 3b. Approaching caster in (cast-range, cast-range + 4.0] -> holds 50..99e Nexus in hold-nexus-tags, does NOT cast yet!
  (define live-recharge-range (exact->inexact (sc2-spell-cast-range 'nexus-energy-recharge 14.5)))
  (define approach-x (+ 30.0 live-recharge-range 2.0))
  (define dec-hold
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 75.0 30.0 30.0) (mk-nx 402 120.0 30.0 30.0))
     #:ally-casters (list (mk-caster 503 'high-templar approach-x 30.0 40.0))
     #:enemy-units-present? #t
     #:recharge-available? #t
     #:recharge-off-cooldown? #t))
  (check-eq "recharge-approach-no-cast-yet" (protoss-nexus-recharge-decision-cast-nexus-tag dec-hold) #f)
  (check-true "recharge-approach-holds-75e-nx"
              (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags dec-hold) 401))
  (check-true "recharge-approach-does-not-hold-120e-nx"
              (not (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags dec-hold) 402)))

  ;; 3b2. Explicit 14.5t parity check (`#1704`/`#1705`): 13.0t fires cleanly, 16.5t holds in combat!
  (define dec-145-cast
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 75.0 30.0 30.0))
     #:ally-casters (list (mk-caster 503 'sentry 43.0 30.0 85.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t
     #:cast-range 14.5))
  (check-eq "recharge-14.5t-casts-at-13t"
            (list (protoss-nexus-recharge-decision-cast-nexus-tag dec-145-cast)
                  (protoss-nexus-recharge-decision-cast-target-tag dec-145-cast))
            '(401 503))

  (define dec-145-approach
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 75.0 30.0 30.0))
     #:ally-casters (list (mk-caster 503 'high-templar 46.5 30.0 40.0))
     #:enemy-units-present? #t
     #:recharge-available? #t
     #:recharge-off-cooldown? #t
     #:cast-range 14.5))
  (check-eq "recharge-14.5t-approach-16.5t-no-cast"
            (protoss-nexus-recharge-decision-cast-nexus-tag dec-145-approach) #f)
  (check-true "recharge-14.5t-approach-16.5t-holds-75e-nx"
              (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags dec-145-approach) 401))

  ;; 3c. Unavailable or on cooldown -> no cast, empty holds
  (define dec-cd
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 75.0 30.0 30.0))
     #:ally-casters (list (mk-caster 503 'high-templar 35.0 30.0 40.0))
     #:enemy-units-present? #t
     #:recharge-available? #t
     #:recharge-off-cooldown? #f))
  (check-eq "recharge-on-cd-no-cast" (protoss-nexus-recharge-decision-cast-nexus-tag dec-cd) #f)
  (check-true "recharge-on-cd-no-holds" (set-empty? (protoss-nexus-recharge-decision-hold-nexus-tags dec-cd)))

  ;; 3c2. L63B (`#1752` Bug #2A): Out-of-combat (`enemy-units-present? = #f`) Recharge `<= cast-range`
  ;;      casts immediately (preferring in-range Sentry over out-of-range HT), AND approaching casters
  ;;      in `(cast-range, eff-hold-range]` STILL hold `50..99e` Nexus energy out of combat!
  (define dec-peace-cast
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 70.0 30.0 30.0) (mk-nx 402 70.0 60.0 30.0))
     #:ally-casters (list (mk-caster 501 'sentry 36.0 30.0 35.0)
                          (mk-caster 503 'high-templar approach-x 30.0 40.0)
                          (mk-caster 505 'oracle 65.0 30.0 30.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t))
  (check-eq "recharge-peace-in-range-casts-sentry-ignores-out-of-range-ht"
            (list (protoss-nexus-recharge-decision-cast-nexus-tag dec-peace-cast)
                  (protoss-nexus-recharge-decision-cast-target-tag dec-peace-cast))
            '(401 501))
  (check-true "recharge-peace-does-not-hold-chrono-on-second-nx-once-casting"
              (set-empty? (protoss-nexus-recharge-decision-hold-nexus-tags dec-peace-cast)))

  (define dec-peace-approach
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 75.0 30.0 30.0) (mk-nx 402 120.0 30.0 30.0))
     #:ally-casters (list (mk-caster 503 'high-templar 51.0 30.0 90.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t
     #:cast-range 17.5
     #:approach-hold-range 22.0))
  (check-eq "recharge-peace-approach-no-cast" (protoss-nexus-recharge-decision-cast-nexus-tag dec-peace-approach) #f)
  (check-true "recharge-peace-approach-holds-75e-nx-within-22t"
              (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags dec-peace-approach) 401))
  (check-true "recharge-peace-approach-does-not-hold-120e-nx"
              (not (set-member? (protoss-nexus-recharge-decision-hold-nexus-tags dec-peace-approach) 402)))

  ;; 3c3. L63B (`#1752` Bug #2A): `< 100.0e` dry threshold across HT/Oracle/Sentry/Mothership:
  ;;      95.0e Sentry & 90.0e Mothership fire out of combat; 100.0e Sentry does NOT.
  (define dec-sentry-95
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 70.0 30.0 30.0))
     #:ally-casters (list (mk-caster 506 'sentry 36.0 30.0 95.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t))
  (check-eq "recharge-sentry-95e-out-of-combat-fires"
            (list (protoss-nexus-recharge-decision-cast-nexus-tag dec-sentry-95)
                  (protoss-nexus-recharge-decision-cast-target-tag dec-sentry-95))
            '(401 506))

  (define dec-mothership-90
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 70.0 30.0 30.0))
     #:ally-casters (list (mk-caster 508 'mothership 36.0 30.0 90.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t))
  (check-eq "recharge-mothership-90e-out-of-combat-fires"
            (list (protoss-nexus-recharge-decision-cast-nexus-tag dec-mothership-90)
                  (protoss-nexus-recharge-decision-cast-target-tag dec-mothership-90))
            '(401 508))

  (define dec-sentry-100
    (evaluate-protoss-nexus-recharge-policy
     #:ready-nexuses (list (mk-nx 401 70.0 30.0 30.0))
     #:ally-casters (list (mk-caster 507 'sentry 36.0 30.0 100.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t))
  (check-eq "recharge-sentry-100e-does-not-fire"
            (protoss-nexus-recharge-decision-cast-nexus-tag dec-sentry-100)
            #f)

  ;; 3d. Early Probe Chrono Boost (< 6720f, < 50 workers) boosts self when no dry caster <= 20.0t,
  ;;     when Recharge is ON cooldown (`#:recharge-off-cooldown? #f`), or when Nexus >= 100e;
  ;;     yields BOTH in combat & out of combat when Recharge is off cooldown and dry caster <= 20.0t!
  (define pairs-peace-clear
    (select-early-probe-chrono-pairs
     #:loop 2400
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 55.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f)
                           (mk-nx 402 55.0 60.0 30.0 #:training-probe? #t #:chrono-buffed? #t))
     #:ally-casters (list (mk-caster 503 'sentry 36.0 30.0 100.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-boosts-unbuffed-probe-nx-when-caster-full" pairs-peace-clear '((401 . 401)))

  (define pairs-peace-yield-sentry-19t
    (select-early-probe-chrono-pairs
     #:loop 2400
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 55.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
     #:ally-casters (list (mk-caster 506 'sentry 49.0 30.0 95.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-yields-out-of-combat-near-dry-sentry-19t" pairs-peace-yield-sentry-19t '())

  (define pairs-peace-cd-allows-chrono
    (select-early-probe-chrono-pairs
     #:loop 2400
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 55.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
     #:ally-casters (list (mk-caster 506 'sentry 49.0 30.0 95.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #f
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-boosts-when-recharge-on-cooldown" pairs-peace-cd-allows-chrono '((401 . 401)))

  (define pairs-peace-21t-allows-chrono
    (select-early-probe-chrono-pairs
     #:loop 2400
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 55.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
     #:ally-casters (list (mk-caster 506 'sentry 51.0 30.0 95.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:recharge-off-cooldown? #t
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-boosts-when-dry-caster-beyond-20t" pairs-peace-21t-allows-chrono '((401 . 401)))

  (define pairs-peace-105e-ok
    (select-early-probe-chrono-pairs
     #:loop 2400
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 105.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
     #:ally-casters (list (mk-caster 506 'sentry 43.0 30.0 85.0))
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-boosts-105e-nx-preserving-50e-for-recharge" pairs-peace-105e-ok '((401 . 401)))

  (define pairs-yield
    (select-early-probe-chrono-pairs
     #:loop 2400
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 55.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
     #:ally-casters (list (mk-caster 503 'high-templar 36.0 30.0 40.0))
     #:enemy-units-present? #t
     #:recharge-available? #t
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-yields-to-recharge-near-dry-ht" pairs-yield '())

  (define pairs-late
    (select-early-probe-chrono-pairs
     #:loop 7000
     #:worker-count 24
     #:ready-nexuses (list (mk-nx 401 55.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
     #:ally-casters '()
     #:enemy-units-present? #f
     #:recharge-available? #t
     #:caster-ready? (lambda (_) #t)
     #:target-ready? (lambda (_) #t)))
  (check-eq "early-chrono-stops-after-5m" pairs-late '()))

;; =============================================================================
;; 4. `sc2-upgrade-researcher-slot`: ALL 70+ Upgrade Symbols & Legacy Aliases
;; =============================================================================

(define expected-upgrade-slots
  (list
   ;; Terran Engineering Bay
   (cons 'infantry-weapons-1 'engineering-bay)
   (cons 'infantry-armor-1 'engineering-bay)
   (cons 'terran-infantry-weapons-1 'engineering-bay)
   (cons 'terran-infantry-weapons-2 'engineering-bay)
   (cons 'terran-infantry-weapons-3 'engineering-bay)
   (cons 'terran-infantry-armor-1 'engineering-bay)
   (cons 'terran-infantry-armor-2 'engineering-bay)
   (cons 'terran-infantry-armor-3 'engineering-bay)
   (cons 'hi-sec-auto-tracking 'engineering-bay)
   ;; Terran Armory
   (cons 'vehicle-weapons-1 'armory)
   (cons 'terran-vehicle-weapons-1 'armory)
   (cons 'terran-vehicle-weapons-2 'armory)
   (cons 'terran-vehicle-weapons-3 'armory)
   (cons 'terran-vehicle-and-ship-plating-1 'armory)
   (cons 'terran-vehicle-and-ship-plating-2 'armory)
   (cons 'terran-vehicle-and-ship-plating-3 'armory)
   (cons 'terran-ship-weapons-1 'armory)
   (cons 'terran-ship-weapons-2 'armory)
   (cons 'terran-ship-weapons-3 'armory)
   ;; Terran Tech Labs, Ghost Academy, Fusion Core
   (cons 'stimpack 'barracks-techlab)
   (cons 'combat-shield 'barracks-techlab)
   (cons 'concussive-shells 'barracks-techlab)
   (cons 'drilling-claws 'factory-techlab)
   (cons 'infernal-pre-igniter 'factory-techlab)
   (cons 'smart-servos 'factory-techlab)
   (cons 'cyclone-lock-on-damage 'factory-techlab)
   (cons 'banshee-cloak 'starport-techlab)
   (cons 'hyperflight-rotors 'starport-techlab)
   (cons 'interference-matrix 'starport-techlab)
   (cons 'personal-cloaking 'ghost-academy)
   (cons 'weapon-refit 'fusion-core)
   (cons 'advanced-ballistics 'fusion-core)
   ;; Protoss Forge, CyberCore, Twilight, RoboBay, Templar, DarkShrine, FleetBeacon
   (cons 'ground-weapons-1 'forge)
   (cons 'ground-armor-1 'forge)
   (cons 'protoss-ground-weapons-1 'forge)
   (cons 'protoss-ground-weapons-2 'forge)
   (cons 'protoss-ground-weapons-3 'forge)
   (cons 'protoss-ground-armor-1 'forge)
   (cons 'protoss-ground-armor-2 'forge)
   (cons 'protoss-ground-armor-3 'forge)
   (cons 'protoss-shields-1 'forge)
   (cons 'protoss-shields-2 'forge)
   (cons 'protoss-shields-3 'forge)
   (cons 'warpgate 'cybernetics-core)
   (cons 'warpgate-research 'cybernetics-core)
   (cons 'warp-gate 'cybernetics-core)
   (cons 'warp-gate-research 'cybernetics-core)
   (cons 'protoss-air-weapons-1 'cybernetics-core)
   (cons 'protoss-air-weapons-2 'cybernetics-core)
   (cons 'protoss-air-weapons-3 'cybernetics-core)
   (cons 'protoss-air-armor-1 'cybernetics-core)
   (cons 'protoss-air-armor-2 'cybernetics-core)
   (cons 'protoss-air-armor-3 'cybernetics-core)
   (cons 'charge 'twilight-council)
   (cons 'blink 'twilight-council)
   (cons 'resonating-glaives 'twilight-council)
   (cons 'extended-thermal-lance 'robotics-bay)
   (cons 'gravitic-booster 'robotics-bay)
   (cons 'gravitic-drive 'robotics-bay)
   (cons 'psi-storm 'templar-archive)
   (cons 'psionic-storm 'templar-archive)
   (cons 'shadow-stride 'dark-shrine)
   (cons 'shadow-strike 'dark-shrine)
   (cons 'flux-vanes 'fleet-beacon)
   (cons 'anion-pulse-crystals 'fleet-beacon)
   ;; Zerg Evo, Pool, Townhall, RW, BN, HydraDen, LurkerDen, InfPit, UltraCavern, Spire
   (cons 'missile-attacks-1 'evolution-chamber)
   (cons 'ground-carapace-1 'evolution-chamber)
   (cons 'zerg-missile-weapons-1 'evolution-chamber)
   (cons 'zerg-missile-weapons-2 'evolution-chamber)
   (cons 'zerg-missile-weapons-3 'evolution-chamber)
   (cons 'zerg-ground-armor-1 'evolution-chamber)
   (cons 'zerg-ground-armor-2 'evolution-chamber)
   (cons 'zerg-ground-armor-3 'evolution-chamber)
   (cons 'zerg-melee-weapons-1 'evolution-chamber)
   (cons 'zerg-melee-weapons-2 'evolution-chamber)
   (cons 'zerg-melee-weapons-3 'evolution-chamber)
   (cons 'zergling-movementspeed 'spawning-pool)
   (cons 'metabolic-boost 'spawning-pool)
   (cons 'zergling-attackspeed 'spawning-pool)
   (cons 'adrenal-glands 'spawning-pool)
   (cons 'overlord-speed 'townhall)
   (cons 'pneumatized-carapace 'townhall)
   (cons 'burrow 'townhall)
   (cons 'glial-reconstitution 'roach-warren)
   (cons 'tunneling-claws 'roach-warren)
   (cons 'centrifical-hooks 'baneling-nest)
   (cons 'centrifugal-hooks 'baneling-nest)
   (cons 'grooved-spines 'hydralisk-den)
   (cons 'muscular-augments 'hydralisk-den)
   (cons 'lurker-range 'lurker-den)
   (cons 'seismic-spines 'lurker-den)
   (cons 'adaptive-talons 'lurker-den)
   (cons 'neural-parasite 'infestation-pit)
   (cons 'chitinous-plating 'ultralisk-cavern)
   (cons 'anabolic-synthesis 'ultralisk-cavern)
   (cons 'zerg-flyer-weapons-1 'spire)
   (cons 'zerg-flyer-weapons-2 'spire)
   (cons 'zerg-flyer-weapons-3 'spire)
   (cons 'zerg-flyer-armor-1 'spire)
   (cons 'zerg-flyer-armor-2 'spire)
   (cons 'zerg-flyer-armor-3 'spire)))

(for ([p (in-list expected-upgrade-slots)])
  (check-eq (format "upgrade-slot-~a" (car p))
            (sc2-upgrade-researcher-slot (car p))
            (cdr p)))

;; Non-upgrade symbols MUST return #f
(check-eq "upgrade-slot-non-upgrade-marine" (sc2-upgrade-researcher-slot 'marine) #f)
(check-eq "upgrade-slot-non-upgrade-nexus" (sc2-upgrade-researcher-slot 'nexus) #f)

;; =============================================================================
;; 5. Phase 2 Duplicate `4126` Live-Obs Guards (`static-defense.rkt` & `situational-counter.rkt`)
;; =============================================================================

(let ()
  (define sd-base-obs
    (hash 'frame 5000
          'ally-units (list (hash 'id 601 'type 'high-templar 'x 34.0 'y 30.0 'energy 20.0 'hp 40.0 'max-hp 40.0))
          'ally-buildings (list (hash 'id 602 'type 'nexus 'x 30.0 'y 30.0 'energy 80.0 'hp 1000.0 'max-hp 1000.0 'build-progress 1.0))
          'enemy-units (list (hash 'id 603 'type 'marine 'x 60.0 'y 60.0 'hp 45.0))))
  (define sd-offline-acts (plan-shield-battery-and-nexus-overcharge-tactics sd-base-obs))
  (define sd-live-acts (plan-shield-battery-and-nexus-overcharge-tactics (hash-set sd-base-obs 'live-obs? #t)))
  (define (has-recharge? acts)
    (and (ormap (lambda (a) (and (list? a) (>= (length a) 3) (eq? (third a) 'nexus-energy-recharge))) acts) #t))
  (check-true "static-defense-emits-4126-offline" (has-recharge? sd-offline-acts))
  (check-true "static-defense-suppresses-duplicate-4126-live" (not (has-recharge? sd-live-acts)))

  (define sc-obs-off
    (hash 'frame 8000 'race 'Protoss 'enemy-race 'Terran
          'ally-units (list (hash 'id 701 'type 'high-templar 'x 34.0 'y 30.0 'energy 20.0))
          'ally-buildings (list (hash 'id 702 'type 'nexus 'x 30.0 'y 30.0 'energy 80.0 'build-progress 1.0))
          'enemy-units (list (hash 'id 703 'type 'ghost 'x 80.0 'y 80.0)
                             (hash 'id 704 'type 'ghost 'x 81.0 'y 80.0))))
  (define sc-plan-off (evaluate-situational-counter-plan sc-obs-off 'Protoss 'Terran 8000))
  (define sc-plan-live (evaluate-situational-counter-plan (hash-set sc-obs-off 'live-obs? #t) 'Protoss 'Terran 8000))
  (check-true "situational-counter-suppresses-duplicate-4126-live"
              (not (has-recharge? (situational-counter-plan-ability-actions sc-plan-live))))
  (check-true "situational-counter-keeps-offline-4126-compat"
              (or (not (eq? (situational-counter-plan-primary-situation sc-plan-off) 'late-game-spellcaster-standoff))
                  (has-recharge? (situational-counter-plan-ability-actions sc-plan-off)))))

;; =============================================================================
;; 6. Loop 64 A4 & A5: Dynamic Phase/Situation Chrono Boost, OC Scan Reserve,
;;    Multi-Widow-Mine Reserve, & Terran Supply Drop (`255`) Policy
;; =============================================================================

(let ()
  ;; 6a. Protoss Chrono Boost 4:00 Pivot & Gateway Sink Elimination
  (define c-nx (macro-chrono-candidate-info 101 'nexus))
  (define c-cy (macro-chrono-candidate-info 102 'cybernetics-core))
  (define c-fg (macro-chrono-candidate-info 103 'forge))
  (define c-rb (macro-chrono-candidate-info 104 'robotics-facility))
  (define c-sg (macro-chrono-candidate-info 105 'stargate))
  (define c-gw (macro-chrono-candidate-info 106 'gateway))
  (define c-wg (macro-chrono-candidate-info 107 'warp-gate))

  ;; Phase 0-4m (< 5376f & < 34w): Nexus > CyberCore > Robo > Gateway
  (check-eq "l64-chrono-0-4m-picks-nexus-first"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-gw c-rb c-cy c-nx)
              #:loop 2400 #:worker-count 22 #:nexus-energy 60.0))
            101)
  (check-true "l64-chrono-0-4m-early-rush-prioritizes-gate-over-nexus"
              (and (> (score-protoss-chrono-target-policy 'gateway #:loop 2200 #:worker-count 18
                                                          #:early-ling-or-worker-rush? #t #:early-gate-defenders 1)
                      900.0)
                   (< (score-protoss-chrono-target-policy 'nexus #:loop 2200 #:worker-count 18
                                                          #:early-ling-or-worker-rush? #t #:early-gate-defenders 1)
                      0.0)))

  ;; Sharp 4:00 Pivot (>= 5376f OR >= 34w): TechUpgrades (955) > Robo (900) > Stargate (860) > Nexus (600 only if idle tech/robo & <56w)
  (check-eq "l64-chrono-4m-picks-forge-over-robo-nexus-gate"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-nx c-gw c-rb c-fg c-sg)
              #:loop 5600 #:worker-count 36 #:nexus-energy 75.0 #:under-pressure? #t))
            103)
  (check-eq "l64-chrono-4m-picks-robo-over-stargate-nexus-gate"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-nx c-gw c-sg c-rb)
              #:loop 6200 #:worker-count 40 #:nexus-energy 75.0))
            104)
  (check-eq "l64-chrono-4m-suppresses-gateway-even-under-pressure"
            (select-protoss-chrono-target-policy
             #:candidates (list c-gw c-wg)
             #:loop 9000 #:worker-count 58 #:nexus-energy 85.0 #:under-pressure? #t #:army-supply 24.0)
            #f)
  (check-eq "l64-chrono-4m-allows-nexus-when-no-tech-robo-busy-and-under-56w"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-nx c-gw)
              #:loop 6200 #:worker-count 44 #:nexus-energy 75.0))
            101)
  (check-eq "l64-chrono-4m-bleeds-gateway-only-at-150e-plus"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-gw)
              #:loop 11000 #:worker-count 68 #:nexus-energy 155.0))
            106)
  (check-eq "l64-chrono-4m-allows-gateway-on-main-breach-under-6-army"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-gw)
              #:loop 6400 #:worker-count 40 #:nexus-energy 65.0
              #:main-base-breach? #t #:army-supply 4.0))
            106)
  ;; L64B (`#1814` Bug #4): Post-4m Nexus `< 66w` (+ `>= 125e` `< 72w` bleed) & Gateway `>= 100e` (`>= 125e` near dry caster)
  (check-eq "l64b-chrono-4m-allows-nexus-at-62w-when-no-unbuffed-tech-robo"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-nx c-gw)
              #:loop 9200 #:worker-count 62 #:nexus-energy 75.0))
            101)
  (check-true "l64b-chrono-4m-nexus-cap-bleed-125e-under-72w-stops-at-72w"
              (and (= (score-protoss-chrono-target-policy 'nexus #:loop 11000 #:worker-count 70
                                                          #:nexus-energy 130.0 #:has-busy-tech-or-robo? #t)
                      580.0)
                   (< (score-protoss-chrono-target-policy 'nexus #:loop 11000 #:worker-count 72
                                                          #:nexus-energy 130.0 #:has-busy-tech-or-robo? #t)
                      0.0)))
  (check-eq "l64b-chrono-4m-gateway-cap-bleed-at-105e-no-dry-caster"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-gw)
              #:loop 11000 #:worker-count 68 #:nexus-energy 105.0 #:dry-caster-near? #f))
            106)
  (check-eq "l64b-chrono-4m-gateway-holds-110e-near-dry-caster"
            (select-protoss-chrono-target-policy
             #:candidates (list c-gw)
             #:loop 11000 #:worker-count 68 #:nexus-energy 110.0 #:dry-caster-near? #t)
            #f)
  (check-eq "l64b-chrono-4m-gateway-bleeds-130e-near-dry-caster-preserving-50e-recharge"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-gw)
              #:loop 11000 #:worker-count 68 #:nexus-energy 130.0 #:dry-caster-near? #t))
            106)
  ;; Wire early probe chrono stops handing Nexus chrono at >= 4:00 w/ >= 28 probes!
  (check-eq "l64-early-probe-chrono-yields-after-4m-28w"
            (select-early-probe-chrono-pairs
             #:loop 5600 #:worker-count 30
             #:ready-nexuses (list (mk-nx 401 60.0 30.0 30.0 #:training-probe? #t #:chrono-buffed? #f))
             #:ally-casters '() #:enemy-units-present? #f #:recharge-available? #t
             #:caster-ready? (lambda (_) #t) #:target-ready? (lambda (_) #t))
            '())

  ;; 6b. Terran OC Policy: Multi-WM (>=2 even w/ Turret), cloak_seen top-2 OCs, >=8:00 & under-pressure top-1 OC
  (define latch64 (make-macro-policy-latch))
  (define p-wm2-with-turret
    (evaluate-terran-mule-policy
     #:latch latch64 #:loop 6000
     #:ready-ocs (list (mk-oc 101 80.0) (mk-oc 102 65.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax (mk-self 'missile-turret 23 32.0 32.0 #:structure? #t #:completed? #t))
                          std-scvs std-marines6)
     #:enemy-units (list (mk-enemy 'widow-mine 498 90.0 90.0)
                         (mk-enemy 'widow-mine-burrowed 500 92.0 90.0 #:burrowed? #t))
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 32
     #:known-enemy-race 'Terran))
  (check-eq "l64-multi-wm-reserves-1-oc-even-with-home-turret"
            (terran-mule-policy-result-proactive-scan-oc-tags p-wm2-with-turret)
            '(101))
  (check-true "l64-multi-wm-oc1-holds-80e" (not (terran-oc-mule-allowed? p-wm2-with-turret 101 80.0)))
  (check-true "l64-multi-wm-oc2-mules-65e" (terran-oc-mule-allowed? p-wm2-with-turret 102 65.0))

  (reset-macro-policy-latch-for-new-match! latch64)
  (define p-cloak-top2
    (evaluate-terran-mule-policy
     #:latch latch64 #:loop 7000
     #:ready-ocs (list (mk-oc 101 90.0) (mk-oc 102 75.0 56.0 30.0) (mk-oc 103 60.0 80.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units (list (mk-enemy 'banshee 55 110.0 110.0 #:flying? #t))
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0)
                       (mk-th 102 'orbital-command 56.0 30.0)
                       (mk-th 103 'orbital-command 80.0 30.0))
     #:worker-count 44
     #:known-enemy-race 'Terran))
  (check-eq "l64-cloak-seen-reserves-top2-ocs"
            (terran-mule-policy-result-proactive-scan-oc-tags p-cloak-top2)
            '(101 102))
  (check-true "l64-cloak-seen-oc3-mules-60e" (terran-oc-mule-allowed? p-cloak-top2 103 60.0))

  (reset-macro-policy-latch-for-new-match! latch64)
  (define p-8m-phase
    (evaluate-terran-mule-policy
     #:latch latch64 #:loop 11000
     #:ready-ocs (list (mk-oc 101 85.0) (mk-oc 102 65.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 50
     #:known-enemy-race 'Zerg))
  (check-eq "l64-8m-phase-reserves-top1-oc"
            (terran-mule-policy-result-proactive-scan-oc-tags p-8m-phase)
            '(101))
  (check-true "l64-8m-phase-oc1-holds-85e" (not (terran-oc-mule-allowed? p-8m-phase 101 85.0)))
  (check-true "l64-8m-phase-oc2-mules-65e" (terran-oc-mule-allowed? p-8m-phase 102 65.0))

  (reset-macro-policy-latch-for-new-match! latch64)
  (define p-pressure-2b
    (evaluate-terran-mule-policy
     #:latch latch64 #:loop 6200
     #:ready-ocs (list (mk-oc 101 85.0) (mk-oc 102 65.0 56.0 30.0))
     #:self-units (append (list std-oc-self std-rax) std-scvs std-marines6)
     #:enemy-units '()
     #:townhalls (list (mk-th 101 'orbital-command 30.0 30.0) (mk-th 102 'orbital-command 56.0 30.0))
     #:worker-count 36
     #:known-enemy-race 'Zerg
     #:under-pressure? #t))
  (check-eq "l64-under-pressure-2b-reserves-top1-oc"
            (terran-mule-policy-result-proactive-scan-oc-tags p-pressure-2b)
            '(101))

  ;; 6c. Terran Supply Drop (`evaluate-terran-supply-drop-policy`)
  (define d-upg  (macro-depot-info 301 'supply-depot 32.0 32.0 #t #t))
  (define d-free (macro-depot-info 302 'supply-depot-lowered 35.0 32.0 #t #f))
  (define sd-go
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 78 #:supply-cap 78
     #:ready-ocs (list (mk-oc 101 85.0) (mk-oc 102 65.0 56.0 30.0))
     #:depots (list d-upg d-free)
     #:under-pressure? #t #:cloak-seen? #f #:mule-policy p-pressure-2b))
  (check-eq "l64-supply-drop-prefers-unreserved-oc-and-fresh-depot"
            (list (terran-supply-drop-decision-oc-tag sd-go)
                  (terran-supply-drop-decision-depot-tag sd-go))
            '(102 302))
  (define sd-cloak-low
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 78 #:supply-cap 78
     #:ready-ocs (list (mk-oc 101 85.0))
     #:depots (list d-free)
     #:under-pressure? #t #:cloak-seen? #t))
  (check-eq "l64-supply-drop-holds-under-cloak-below-100e"
            (terran-supply-drop-decision-oc-tag sd-cloak-low)
            #f)
  (define sd-cloak-105
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 78 #:supply-cap 78
     #:ready-ocs (list (mk-oc 101 105.0))
     #:depots (list d-free)
     #:under-pressure? #t #:cloak-seen? #t))
  (check-eq "l64-supply-drop-fires-under-cloak-at-105e"
            (list (terran-supply-drop-decision-oc-tag sd-cloak-105)
                  (terran-supply-drop-decision-depot-tag sd-cloak-105))
            '(101 302))
  ;; Loop 65 (`#1831`/`#1833`): Fire SupplyDrop on real 4-12m supply blocks even when peaceful
  ;; (skip only when a Depot is already nearly done peacefully or not supply-blocked)!
  (define sd-peace
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 78 #:supply-cap 78
     #:ready-ocs (list (mk-oc 101 85.0))
     #:depots (list d-free)
     #:under-pressure? #f))
  (check-eq "l65-supply-drop-fires-on-midgame-block-without-pressure"
            (list (terran-supply-drop-decision-oc-tag sd-peace)
                  (terran-supply-drop-decision-depot-tag sd-peace))
            '(101 302))
  (define sd-peace-nearly-done
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 78 #:supply-cap 78
     #:ready-ocs (list (mk-oc 101 85.0))
     #:depots (list d-free)
     #:under-pressure? #f
     #:depot-nearly-done? #t))
  (check-eq "l65-supply-drop-skips-peaceful-when-depot-nearly-done"
            (terran-supply-drop-decision-oc-tag sd-peace-nearly-done)
            #f)
  (define sd-not-blocked
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 76 #:supply-cap 78
     #:ready-ocs (list (mk-oc 101 85.0))
     #:depots (list d-free)
     #:under-pressure? #f))
  (check-eq "l65-supply-drop-skips-when-not-blocked"
            (terran-supply-drop-decision-oc-tag sd-not-blocked)
            #f)
  (check-eq "l65-chrono-4m-under-breach-promotes-robo-over-forge"
            (macro-chrono-candidate-info-tag
             (select-protoss-chrono-target-policy
              #:candidates (list c-nx c-fg c-rb c-gw)
              #:loop 8000 #:worker-count 44 #:nexus-energy 60.0 #:under-pressure? #t #:main-base-breach? #t))
            104)
  (define sd-cap192
    (evaluate-terran-supply-drop-policy
     #:loop 8000 #:supply-used 192 #:supply-cap 192
     #:ready-ocs (list (mk-oc 101 85.0))
     #:depots (list d-free)
     #:under-pressure? #t))
  (check-eq "l64-supply-drop-skips-at-192-plus-cap"
            (terran-supply-drop-decision-oc-tag sd-cap192)
            #f))

(printf "macro-ability-policy-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
