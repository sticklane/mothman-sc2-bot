#lang racket/base

;; =============================================================================
;; `tests/engine-arbiter-test.rkt`
;; Comprehensive Unit, Edge-Case & Performance Tests for Architecture Phase A:
;;   - `lib/engine/arbiter.rkt` (4 scarce budgets, blocking escrow, canonical
;;     role-leases, allow-partial?, threat-veto, same-step alternatives cascade,
;;     cross-step ring buffer & rewind reset, telemetry summary, < 0.15 ms/step)
;;   - `lib/engine/world-view.rkt` (immutable L1 snapshot & extras)
;;   - `lib/sc2-common.rkt` (`dyn-hash-ref`, `dyn-hash-has-key?`,
;;     `fast-units-have-any-type?`)
;; =============================================================================

(require racket/list
         racket/set
         "../lib/sc2-common.rkt"
         "../lib/sc2-game-constants.rkt"
         "../lib/engine/world-view.rkt"
         "../lib/engine/arbiter.rkt")

(define passed 0)
(define failed 0)

(define (check-true name cond?)
  (if cond?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (printf "  [FAIL] ~a\n" name))))

(define (check-equal name got want)
  (if (equal? got want)
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (printf "  [FAIL] ~a: got ~s, want ~s\n" name got want))))

(printf "=================================================================\n")
(printf "Engine Arbiter & WorldView Architecture Phase A Test Suite\n")
(printf "=================================================================\n")

;; -----------------------------------------------------------------------------
;; 1. L0 Common Helpers & Immutable L1 WorldView
;; -----------------------------------------------------------------------------
(printf "[1/7] Testing L0 sc2-common hash helpers & L1 immutable world-view...\n")

(check-equal "common-dyn-hash-ref-hit" (dyn-hash-ref (hasheq 'x 42) 'x 0) 42)
(check-equal "common-dyn-hash-ref-miss" (dyn-hash-ref (hasheq 'x 42) 'y 99) 99)
(check-equal "common-dyn-hash-ref-non-hash" (dyn-hash-ref #f 'x 'def) 'def)
(check-true  "common-dyn-hash-has-key-t" (dyn-hash-has-key? (hasheq 'a 1) 'a))
(check-true  "common-dyn-hash-has-key-f" (not (dyn-hash-has-key? (hasheq 'a 1) 'b)))
(check-true  "common-dyn-hash-has-key-non-hash" (not (dyn-hash-has-key? 123 'a)))
(check-true  "common-fast-units-have-any-type-t"
             (fast-units-have-any-type? (list (hasheq 'type 'marine) (hasheq 'type 'tank)) '(tank)))
(check-true  "common-fast-units-have-any-type-f"
             (not (fast-units-have-any-type? (list (hasheq 'type 'marine)) '(tank marauder))))

(define wv0
  (make-world-view
   #:frame 4800
   #:race 'Protoss
   #:enemy-race 'Terran
   #:live-obs? #t
   #:obs (make-hasheq '((frame . 4800) (minerals . 350)))
   #:posture 'MacroStandard
   #:fap-score 2.5
   #:minerals 350
   #:gas 175
   #:supply-used 64
   #:supply-cap 78
   #:under-attack? #f))
(check-true  "wv-struct" (world-view? wv0))
(check-equal "wv-frame" (world-view-frame wv0) 4800)
(check-equal "wv-race" (world-view-race wv0) 'Protoss)
(check-equal "wv-supply-left" (world-view-supply-left wv0) 14)
(check-true  "wv-obs-immutable" (immutable? (world-view-obs wv0)))
(define wv1 (world-view-with-extra wv0 'cloak-seen? #t))
(check-equal "wv-extra-missing-orig" (world-view-extra wv0 'cloak-seen? #f) #f)
(check-equal "wv-extra-set-copy" (world-view-extra wv1 'cloak-seen? #f) #t)

;; -----------------------------------------------------------------------------
;; 2. Canonical Override Reason Enum & Role Priority Alignment
;; -----------------------------------------------------------------------------
(printf "[2/7] Testing canonical override reason enum & role-lease alignment...\n")

(check-equal "override-reason-count-10" (length ARBITER-OVERRIDE-REASONS) 10)
(for ([r (in-list '(budget-mineral budget-gas budget-supply budget-larva
                    facility-busy unit-claimed-higher-priority energy-reserved
                    threat-veto apm-cap-deferred superseded-by-alternative))])
  (check-true (format "reason-valid-~a" r) (arbiter-override-reason? r)))
(check-true "reason-invalid-bogus" (not (arbiter-override-reason? 'bogus-reason)))
(check-true "role-prio-order-builder>defense>detector>strike>stage>concave>army>harv"
            (> (arbiter-role-priority 'builder)
               (arbiter-role-priority 'home-defense)
               (arbiter-role-priority 'detector-escort)
               (arbiter-role-priority 'strike-group)
               (arbiter-role-priority 'staging-group)
               (arbiter-role-priority 'concave)
               (arbiter-role-priority 'army)
               (arbiter-role-priority 'harvester)))

;; -----------------------------------------------------------------------------
;; 3. Budget 1: Resources, Facilities & Blocking Escrow
;; -----------------------------------------------------------------------------
(printf "[3/7] Testing Budget 1 (min/gas/supply/larva/facilities + blocking escrow)...\n")

(let* ([ledger (make-arbiter-ledger)]
       ;; 150M / 100G, 1 robo slot, 1 larva, 2 supply left
       [bud (make-arbiter-budget-snapshot
             #:minerals 150
             #:gas 100
             #:supply-left 2
             #:larva-count 1
             #:open-facility-slots (hasheq 'robotics-facility 1 'gateway 2 'larva 1)
             #:busy-facility-tags (seteqv 5001))]
       [p-colossus
        (make-proposal 'colossus 'priority-macro-brain 'macro 760
                       '(train colossus)
                       #:cost (make-proposal-cost #:minerals 300 #:gas 200 #:supply 6 #:facility-slot 'robotics-facility)
                       #:blocking-escrow? #t)]
       ;; Fails on gas? Wait: colossus fails on supply=6 > 2 first? Let's test escrow on affordable supply!
       [bud-escrow
        (make-arbiter-budget-snapshot
         #:minerals 250
         #:gas 100
         #:supply-left 10
         #:larva-count 1
         #:open-facility-slots (hasheq 'robotics-facility 1 'gateway 2 'larva 1)
         #:busy-facility-tags (seteqv 5001))]
       ;; Colossus needs 300M/200G (unaffordable min+gas) and locks escrow 300M/200G
       [p-stalker
        (make-proposal 'stalker 'priority-macro-brain 'macro 620
                       '(train stalker)
                       #:cost (make-proposal-cost #:minerals 125 #:gas 50 #:supply 2 #:facility-slot 'gateway))]
       [res (arbiter-resolve! ledger 4000 bud-escrow (list p-stalker p-colossus))])
  ;; Colossus must sort first, lock escrow, and block Stalker via budget-mineral citing 'colossus!
  (check-equal "escrow-no-accepted" (arbiter-result-accepted-proposals res) '())
  (check-equal "escrow-saving-for" (hash-ref (arbiter-result-telemetry-summary res) 'saving-for) 'colossus)
  (check-equal "escrow-min-floor" (hash-ref (arbiter-result-telemetry-summary res) 'escrow-min-floor) 300)
  (check-equal "escrow-gas-floor" (hash-ref (arbiter-result-telemetry-summary res) 'escrow-gas-floor) 200)
  (define stalker-sig (findf (lambda (s) (eq? (override-signal-proposal-id s) 'stalker))
                             (arbiter-result-override-signals res)))
  (check-true  "escrow-stalker-signal-present" (override-signal? stalker-sig))
  (check-equal "escrow-stalker-reason-min" (override-signal-reason stalker-sig) 'budget-mineral)
  (check-equal "escrow-stalker-winner-id" (override-signal-winner-id stalker-sig) 'colossus)

  ;; Test supply, larva, facility-slot, facility-tag, and budget-gas reasons directly
  (define bud2
    (make-arbiter-budget-snapshot
     #:minerals 400
     #:gas 50
     #:supply-left 2
     #:larva-count 1
     #:open-facility-slots (hasheq 'gateway 1 'forge 1)
     #:busy-facility-tags (seteqv 9001)))
  (define res2
    (arbiter-resolve!
     ledger 4008 bud2
     (list
      (make-proposal 'busy-fac 'macro-a 'macro 800 '(research wp1)
                     #:cost (make-proposal-cost #:minerals 100 #:gas 100 #:facility-tag 9001))
      (make-proposal 'ok-gate 'macro-a 'macro 750 '(train zealot)
                     #:cost (make-proposal-cost #:minerals 100 #:supply 2 #:facility-slot 'gateway))
      (make-proposal 'slot-full 'macro-b 'macro 740 '(train adept)
                     #:cost (make-proposal-cost #:minerals 100 #:supply 2 #:facility-slot 'gateway))
      (make-proposal 'no-larva 'zerg-a 'macro 730 '(train drone)
                     #:cost (make-proposal-cost #:minerals 50 #:supply 1 #:larva 2))
      (make-proposal 'no-sup 'macro-c 'macro 720 '(train marine)
                     #:cost (make-proposal-cost #:minerals 50 #:supply 1))
      (make-proposal 'no-gas 'tech-a 'macro 710 '(research blink)
                     #:cost (make-proposal-cost #:minerals 150 #:gas 150 #:facility-slot 'forge)))))
  (define sigs2 (arbiter-result-override-signals res2))
  (define (rsn-of id)
    (define s (findf (lambda (x) (eq? (override-signal-proposal-id x) id)) sigs2))
    (and s (override-signal-reason s)))
  (check-equal "res2-accepted-ok-gate" (map proposal-id (arbiter-result-accepted-proposals res2)) '(ok-gate))
  (check-equal "res2-busy-fac-tag" (rsn-of 'busy-fac) 'facility-busy)
  (check-equal "res2-slot-full" (rsn-of 'slot-full) 'facility-busy)
  (check-equal "res2-no-larva" (rsn-of 'no-larva) 'budget-larva)
  (check-equal "res2-no-sup" (rsn-of 'no-sup) 'budget-supply)
  (check-equal "res2-no-gas" (rsn-of 'no-gas) 'budget-gas))

;; -----------------------------------------------------------------------------
;; 4. Budget 2: Canonical Unit Tag Ownership, Leases & `allow-partial?`
;; -----------------------------------------------------------------------------
(printf "[4/7] Testing Budget 2 (tag ownership, persistent leases, preemption, allow-partial?)...\n")

(let* ([ledger (make-arbiter-ledger)]
       [bud (make-arbiter-budget-snapshot)]
       ;; Step 1 (f=5000): Detector intercept claims Observer 101 with persistent TTL 44
       [p-det (make-proposal 'det-101 'mode-and-stealth-safety 'micro 960
                             '(move 101 50.0 50.0)
                             #:claim (make-proposal-claim '(101) #:role 'detector-escort #:lease-ttl 44))]
       ;; Lower-priority scout also wants Observer 101 same step
       [p-scout (make-proposal 'scout-101 'periodic-scout 'ops 150
                               '(move 101 160.0 160.0)
                               #:claim (make-proposal-claim '(101) #:role 'scout))]
       ;; Multiprong claims '(201 202) with strike-group lease; main army wants '(201 202 203 204) with allow-partial?
       [p-mp (make-proposal 'mp-runby 'multiprong-coordinator 'ops 520
                            '(attack-pos (201 202) 150.0 40.0)
                            #:claim (make-proposal-claim '(201 202) #:role 'strike-group #:lease-ttl 60))]
       [p-main (make-proposal 'main-atk 'concave-positioning 'micro 300
                              (lambda (tags) (list 'attack-pos tags 90.0 90.0))
                              #:claim (make-proposal-claim '(201 202 203 204)
                                                           #:role 'concave
                                                           #:allow-partial? #t
                                                           #:min-units 2))]
       ;; Another proposal needs at least 3 of '(201 202 203 204) -> only 0 left after p-main!
       [p-leftover (make-proposal 'leftover 'phase6-rally 'ops 180
                                  '(attack-pos (201 202 203 204) 45.0 45.0)
                                  #:claim (make-proposal-claim '(201 202 203 204)
                                                               #:role 'army
                                                               #:allow-partial? #t
                                                               #:min-units 1))]
       [res1 (arbiter-resolve! ledger 5000 bud (list p-scout p-leftover p-main p-mp p-det))])
  (check-equal "tags-accepted-ids"
               (map proposal-id (arbiter-result-accepted-proposals res1))
               '(det-101 mp-runby main-atk))
  (check-true  "tags-partial-narrowed-action"
               (not (not (member '(attack-pos (203 204) 90.0 90.0)
                                 (arbiter-result-approved-actions res1)))))
  (check-equal "tags-claimed-set"
               (arbiter-result-claimed-tags res1)
               (seteqv 101 201 202 203 204))
  (define scout-sig (findf (lambda (s) (eq? (override-signal-proposal-id s) 'scout-101))
                           (arbiter-result-override-signals res1)))
  (check-equal "tags-scout-reason" (override-signal-reason scout-sig) 'unit-claimed-higher-priority)
  (check-equal "tags-scout-winner" (override-signal-winner-module scout-sig) 'mode-and-stealth-safety)

  ;; Step 2 (f=5020): Persistent detector-escort lease (prio 75) still blocks scout (prio 70) on 101!
  (define res2 (arbiter-resolve! ledger 5020 bud (list p-scout)))
  (check-equal "lease-blocks-next-step-scout" (arbiter-result-accepted-proposals res2) '())
  (check-equal "lease-blocks-reason"
               (override-signal-reason (first (arbiter-result-override-signals res2)))
               'unit-claimed-higher-priority)

  ;; Step 3 (f=5024): Higher-role home-defense (prio 88 > 75) cleanly preempts persistent detector-escort lease!
  (define p-hd (make-proposal 'hd-101 'home-defense 'ops 880
                              '(move 101 32.0 32.0)
                              #:claim (make-proposal-claim '(101) #:role 'home-defense #:lease-ttl 16)))
  (define res3 (arbiter-resolve! ledger 5024 bud (list p-hd)))
  (check-equal "lease-preempted-by-higher-role"
               (map proposal-id (arbiter-result-accepted-proposals res3))
               '(hd-101))

  ;; Step 4 (f=5044): After TTL expiry (5024+16=5040 <= 5044), scout can reclaim 101 cleanly
  (define res4 (arbiter-resolve! ledger 5044 bud (list p-scout)))
  (check-equal "lease-expired-scout-reclaims"
               (map proposal-id (arbiter-result-accepted-proposals res4))
               '(scout-101)))

;; -----------------------------------------------------------------------------
;; 5. Budget 3 (Macro Energy) & Budget 4 (Attention / APM QoS Tiers)
;; -----------------------------------------------------------------------------
(printf "[5/7] Testing Budget 3 (macro energy reserves) & Budget 4 (APM P0-P4 QoS)...\n")

(let* ([ledger (make-arbiter-ledger)]
       ;; OC 701 has 75e with 50e reserved for cloak Scan (prio 850)
       [bud-en (make-arbiter-budget-snapshot
                #:caster-energy-by-tag (hasheqv 701 75.0)
                #:caster-reserve-by-tag (hasheqv 701 (vector 50.0 'mode-and-stealth-safety 'scan-reserve 850.0)))]
       [p-mule (make-proposal 'mule-701 'macro-ability-policy 'energy 700
                              '(cast 701 calldown-mule 9001)
                              #:energy (make-proposal-energy 701 'orbital-command 50.0))]
       [p-scan (make-proposal 'scan-701 'mode-and-stealth-safety 'micro 980
                              '(cast 701 scanner-sweep 60.0 60.0)
                              #:energy (make-proposal-energy 701 'orbital-command 50.0))]
       ;; First test MULE alone vs Scan reserve -> must fail with 'energy-reserved!
       [res-mule (arbiter-resolve! ledger 6000 bud-en (list p-mule))]
       ;; Next test Scan + MULE -> Scan (980) bypasses/owns reserve and takes 50e, leaving 25e so MULE fails!
       [res-both (arbiter-resolve! ledger 6004 bud-en (list p-mule p-scan))])
  (check-equal "energy-mule-blocked-by-reserve" (arbiter-result-accepted-proposals res-mule) '())
  (check-equal "energy-mule-reason"
               (override-signal-reason (first (arbiter-result-override-signals res-mule)))
               'energy-reserved)
  (check-equal "energy-mule-winner"
               (override-signal-winner-module (first (arbiter-result-override-signals res-mule)))
               'mode-and-stealth-safety)
  (check-equal "energy-scan-wins-over-mule"
               (map proposal-id (arbiter-result-accepted-proposals res-both))
               '(scan-701))

  ;; Attention / APM QoS budget: 3.0 tokens available, floors #(0.0 1.0 2.0 3.0 4.0)
  (define bud-apm
    (make-arbiter-budget-snapshot
     #:apm-tokens-available 3.0
     #:apm-tier-floors #(0.0 1.0 2.0 3.0 4.0)))
  (define res-apm
    (arbiter-resolve!
     ledger 6008 bud-apm
     (list
      (make-proposal 'p0-dodge 'dodge 'micro 990 '(move 1 10.0 10.0) #:attention-tier 0)
      (make-proposal 'p1-train 'macro 'macro 750 '(train marine) #:attention-tier 1)
      (make-proposal 'p2-atk   'combat 'micro 400 '(attack-pos 2 80.0 80.0) #:attention-tier 2)
      (make-proposal 'p3-creep 'creep 'ops 120 '(spread-creep) #:attention-tier 3)
      (make-proposal 'p4-cam   'camera 'camera 60 '(move-camera 32.0 32.0) #:attention-tier 4))))
  ;; p0 uses 3->2 (ok), p1 checks 2-1>=1 (ok, 2->1), p2 checks 1-2<1 (deferred!), p3/p4 deferred!
  (check-equal "apm-p0-p1-accepted"
               (map proposal-id (arbiter-result-accepted-proposals res-apm))
               '(p0-dodge p1-train))
  (check-equal "apm-deferred-count"
               (hash-ref (hash-ref (arbiter-result-telemetry-summary res-apm) 'by-reason) 'apm-cap-deferred 0)
               3))

;; -----------------------------------------------------------------------------
;; 6. Same-Step Ranked Alternatives Cascade, Threat Veto & Cross-Step Ring Buffer
;; -----------------------------------------------------------------------------
(printf "[6/7] Testing same-step alternatives cascade, threat-veto & cross-step feedback ring...\n")

(let* ([ledger (make-arbiter-ledger #:ring-cap 8)]
       [bud (make-arbiter-budget-snapshot #:minerals 450 #:gas 100 #:supply-left 20
                                          #:open-facility-slots (hasheq 'robotics-facility 1 'gateway 2))]
       ;; Multiprong primary 2-prong push vetoed by threat-veto -> Alt 1 defensive rotation accepted!
       [p-alt-def (make-proposal 'mp-rotate-def 'multiprong-coordinator 'ops 860
                                 '(attack-pos (301 302 303) 35.0 35.0)
                                 #:claim (make-proposal-claim '(301 302 303) #:role 'home-defense #:lease-ttl 24))]
       [p-2prong (make-proposal 'mp-2prong 'multiprong-coordinator 'ops 520
                                '(attack-pos (301 302 303) 150.0 150.0)
                                #:claim (make-proposal-claim '(301 302 303) #:role 'strike-group #:lease-ttl 44)
                                #:alternatives (list p-alt-def))]
       ;; Gas-escrowed Colossus (300M/200G, we have 450M/100G) with mineral-only Zealot alt (100M/0G)
       ;; Because 450 - 300 escrow = 150M surplus >= 100M, Zealot alt succeeds WHILE Colossus locks 300M/200G escrow!
       [p-zealot-alt (make-proposal 'zealot-dump 'priority-macro-brain 'macro 600
                                    '(train zealot)
                                    #:cost (make-proposal-cost #:minerals 100 #:supply 2 #:facility-slot 'gateway))]
       [p-colossus (make-proposal 'colossus-escrow 'priority-macro-brain 'macro 760
                                  '(train colossus)
                                  #:cost (make-proposal-cost #:minerals 300 #:gas 200 #:supply 6 #:facility-slot 'robotics-facility)
                                  #:blocking-escrow? #t
                                  #:alternatives (list p-zealot-alt))]
       [veto-fn (lambda (p)
                  (if (eq? (proposal-id p) 'mp-2prong)
                      (list 'home-breach 'home-defense 920 (hasheq 'strength-ratio 0.62))
                      #f))]
       [res (arbiter-resolve! ledger 7000 bud (list p-2prong p-colossus) #:threat-veto-fn veto-fn)])
  (check-equal "alt-accepted-both-fallbacks"
               (map proposal-id (arbiter-result-accepted-proposals res))
               '(zealot-dump mp-rotate-def))
  (check-equal "alt-rescued-count-2"
               (hash-ref (arbiter-result-telemetry-summary res) 'alternative-count)
               2)
  (check-equal "alt-escrow-floor-still-held"
               (hash-ref (arbiter-result-telemetry-summary res) 'escrow-gas-floor)
               200)
  (define mp-fb (arbiter-feedback-for ledger 'multiprong-coordinator))
  (check-equal "alt-mp-feedback-len" (length mp-fb) 1)
  (check-equal "alt-mp-reason-superseded" (override-signal-reason (first mp-fb)) 'superseded-by-alternative)
  (check-equal "alt-mp-primary-reason-veto"
               (hash-ref (override-signal-details (first mp-fb)) 'primary-reason)
               'threat-veto)
  (check-equal "alt-mp-accepted-alt-id"
               (hash-ref (override-signal-details (first mp-fb)) 'accepted-alt-id)
               'mp-rotate-def)

  ;; Bounded ring buffer eviction & hysteresis window count + frame-rewind reset
  (define p-gas-starved
    (make-proposal 'ht-tech 'tech-proposer 'macro 700 '(train high-templar)
                   #:cost (make-proposal-cost #:minerals 50 #:gas 150)))
  (define bud-dry (make-arbiter-budget-snapshot #:minerals 300 #:gas 40))
  (for ([i (in-range 12)])
    (arbiter-resolve! ledger (+ 7010 (* i 20)) bud-dry (list p-gas-starved)))
  (define tech-fb (arbiter-feedback-for ledger 'tech-proposer))
  (check-equal "ring-cap-8-bounded" (length tech-fb) 8)
  (check-equal "ring-newest-first" (override-signal-frame (first tech-fb)) (+ 7010 (* 11 20)))
  (check-equal "ring-oldest-retained" (override-signal-frame (last tech-fb)) (+ 7010 (* 4 20)))
  ;; Window 100 frames from 7230 -> frames 7130..7230 = 7130,7150,7170,7190,7210,7230 = 6 hits
  (check-equal "ring-window-count-6"
               (arbiter-recent-override-count ledger 'tech-proposer 'budget-gas 7230 #:window-frames 100)
               6)
  (define tsum (arbiter-telemetry-summary ledger))
  (check-true  "telemetry-summary-total>=14" (>= (hash-ref tsum 'total-overrides) 14))
  ;; Frame rewind (< last-frame) auto-clears ring buffer & leases!
  (arbiter-resolve! ledger 100 bud-dry '())
  (check-equal "rewind-clears-feedback" (arbiter-feedback-for ledger 'tech-proposer) '())
  (check-equal "rewind-clears-leases" (hash-count (arbiter-ledger-role-leases ledger)) 0))

;; -----------------------------------------------------------------------------
;; 7. Performance Benchmark (< 0.15 ms/step steady-state on 30 proposals / 60 tags)
;; -----------------------------------------------------------------------------
(printf "[7/7] Benchmarking steady-state arbiter-resolve! (< 0.15 ms/step target)...\n")

(let* ([ledger (make-arbiter-ledger)]
       [bud (make-arbiter-budget-snapshot
             #:minerals 800 #:gas 400 #:supply-left 40 #:larva-count 8
             #:open-facility-slots (hasheq 'barracks 4 'factory 2 'starport 2 'gateway 4)
             #:caster-energy-by-tag (hasheqv 901 120.0 902 80.0 903 60.0)
             #:apm-tokens-available 18.0
             #:apm-tier-floors #(0.0 2.0 4.0 6.0 8.0))]
       [props
        (append
         (for/list ([i (in-range 10)])
           (make-proposal (list 'macro i) 'priority-macro-brain 'macro (- 780 (* i 10))
                          (list 'train 'marine)
                          #:cost (make-proposal-cost #:minerals 50 #:supply 1 #:facility-slot 'barracks)
                          #:attention-tier 1))
         (for/list ([i (in-range 10)])
           (define base-t (+ 1000 (* i 6)))
           (make-proposal (list 'squad i) 'concave-positioning 'micro (- 450 (* i 12))
                          (list 'attack-pos (list base-t (+ base-t 1) (+ base-t 2)) 90.0 90.0)
                          #:claim (make-proposal-claim (list base-t (+ base-t 1) (+ base-t 2)
                                                             (+ base-t 3) (+ base-t 4) (+ base-t 5))
                                                       #:role 'concave #:lease-ttl 16 #:allow-partial? #t)
                          #:attention-tier 2))
         (for/list ([i (in-range 10)])
           (make-proposal (list 'clash i) 'phase6-rally 'ops (- 200 (* i 5))
                          (list 'move (+ 1000 (* i 6)) 45.0 45.0)
                          #:claim (make-proposal-claim (list (+ 1000 (* i 6)) (+ 1001 (* i 6)))
                                                       #:role 'army)
                          #:attention-tier 3)))])
  ;; Warmup 20 steps
  (for ([k (in-range 20)])
    (arbiter-resolve! ledger (+ 1000 (* k 4)) bud props))
  ;; Timed 200 steps using process CPU milliseconds (immune to external host loadavg jitter)
  (define c0 (current-process-milliseconds))
  (for ([k (in-range 200)])
    (arbiter-resolve! ledger (+ 1100 (* k 4)) bud props))
  (define avg-cpu-ms (/ (exact->inexact (- (current-process-milliseconds) c0)) 200.0))
  (printf "  [PERF] 30 proposals / 60 tags steady-state CPU: ~a ms/step (budget < 0.15 ms/step)\n"
          (real->decimal-string avg-cpu-ms 4))
  (check-true (format "perf-arbiter-under-0.15ms (~a ms)" (real->decimal-string avg-cpu-ms 4))
              (< avg-cpu-ms 0.15)))

(printf "-----------------------------------------------------------------\n")
(printf "Engine Arbiter & WorldView Checks: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(printf "=================================================================\n")
(when (> failed 0)
  (exit 1))
