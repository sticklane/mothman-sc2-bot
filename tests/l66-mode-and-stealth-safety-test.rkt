#lang racket/base

;; =============================================================================
;; `tests/l66-mode-and-stealth-safety-test.rkt`
;; Standalone Unit & Performance Suite for Pure L2c `mode-and-stealth-safety.rkt`
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/tactics/mode-and-stealth-safety.rkt"
         "../lib/engine/arbiter.rkt"
         "../lib/sc2-game-constants.rkt")

(define tests-run 0)
(define tests-passed 0)
(define tests-failed 0)

(define (check-true name cond-val [detail ""])
  (set! tests-run (add1 tests-run))
  (if cond-val
      (begin
        (set! tests-passed (add1 tests-passed))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! tests-failed (add1 tests-failed))
        (printf "  [FAIL] ~a ~a\n" name detail))))

(define (mk-info tag utype x y
                 #:flying? [fly? #f]
                 #:burrowed? [bur? #f]
                 #:cloaked? [clk? #f]
                 #:detected? [det? #f]
                 #:energy [en 0.0]
                 #:build-progress [bp 1.0]
                 #:order-ability-id [ab 0]
                 #:order-target-x [otx #f]
                 #:order-target-y [oty #f]
                 #:structure? [struct? #f]
                 #:worker? [wrk? #f]
                 #:townhall? [th? #f]
                 #:combat? [cmb? #f])
  (ms-unit-info tag utype (exact->inexact x) (exact->inexact y)
                0.0 0.0 0.5 fly? bur? clk? det?
                (exact->inexact en) (exact->inexact bp)
                ab otx oty struct? wrk? th? cmb?))

(printf "=== Loop 66 Mode & Stealth Safety Leaf Test Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. Supply Depot Raise/Lower Hysteresis, Fast-Breach Range, Urgent Transit,
;;    Footprint Guard, External Depot-CD Sync & `clear-mode-stealth-depot-cooldown!`
;; -----------------------------------------------------------------------------
(let ()
  (define st (make-mode-stealth-state))
  (define ext-cd (make-hasheqv))
  ;; Standard enemy (Marine 48) at 14.5t -> does NOT raise lowered depot (14.0t threshold)
  (define d-low (mk-info 101 47 50.0 50.0 #:structure? #t))
  (define e-mar-145 (mk-info 201 48 64.5 50.0 #:combat? #t))
  (define p0 (plan-mode-and-stealth-safety!
              st #:loop 500 #:self-units (list d-low) #:enemy-units (list e-mar-145)
              #:depot-cooldown-ht ext-cd))
  (check-true "L66-MS-1a-depot-standard-14.5t-no-raise"
              (null? (mode-stealth-plan-directives p0))
              (format "got=~a" (mode-stealth-plan-directives p0)))

  ;; Fast-breach Zergling (105) at 15.5t -> DOES raise lowered depot (`16.0t` fast-breach threshold)!
  (define e-ling-155 (mk-info 202 105 65.5 50.0 #:combat? #t))
  (define p1 (plan-mode-and-stealth-safety!
              st #:loop 501 #:self-units (list d-low) #:enemy-units (list e-ling-155)
              #:depot-cooldown-ht ext-cd))
  (define dirs1 (mode-stealth-plan-directives p1))
  (check-true "L66-MS-1b-depot-fast-breach-15.5t-raises-558-and-syncs-cd"
              (and (= (length dirs1) 1)
                   (= (ms-directive-ability-id (first dirs1)) 558)
                   (equal? (ms-directive-unit-tags (first dirs1)) '(101))
                   (set-member? (mode-stealth-plan-claimed-mode-unit-tags p1) 101)
                   (= (hash-ref ext-cd 101 0) (+ 501 44)))
              (format "dirs=~a cd=~a" dirs1 (hash-ref ext-cd 101 0)))

  ;; Footprint guard: friendly Marine standing on depot footprint (`<= 1.40t`) blocks raise!
  (define d-low2 (mk-info 102 47 50.0 50.0 #:structure? #t))
  (define ally-on-foot (mk-info 150 48 50.8 50.5 #:combat? #t))
  (define e-ling-4 (mk-info 203 105 54.0 50.0 #:combat? #t))
  (check-true "L66-MS-1c-footprint-helper-true"
              (and (friendly-unit-on-depot-footprint-info? 50.0 50.0 (list ally-on-foot)) #t))
  (define p2 (plan-mode-and-stealth-safety!
              st #:loop 502 #:self-units (list d-low2 ally-on-foot) #:enemy-units (list e-ling-4)))
  (check-true "L66-MS-1d-footprint-blocks-raise"
              (null? (mode-stealth-plan-directives p2))
              (format "got=~a" (mode-stealth-plan-directives p2)))

  ;; Batched multi-tag lower (`556`) with urgent friendly transit (`36f` cooldown) + `explicit-depot-tags` skip
  (define d-r1 (mk-info 103 19 60.0 60.0 #:structure? #t))
  (define d-r2 (mk-info 104 19 62.0 60.0 #:structure? #t))
  (define d-r3-exp (mk-info 105 19 64.0 60.0 #:structure? #t))
  (define ally-transiting (mk-info 151 48 60.0 62.5 #:combat? #t
                                   #:order-ability-id 16 #:order-target-x 90.0 #:order-target-y 90.0))
  (check-true "L66-MS-1e-transit-helper-true"
              (and (friendly-unit-requesting-depot-transit-info? 60.0 60.0 (list ally-transiting)) #t))
  (define p3 (plan-mode-and-stealth-safety!
              st #:loop 550
              #:self-units (list d-r1 d-r2 d-r3-exp ally-transiting)
              #:enemy-units '()
              #:explicit-depot-tags (seteqv 105)))
  (define dirs3 (mode-stealth-plan-directives p3))
  (check-true "L66-MS-1f-batched-urgent-depot-lower-556-and-explicit-skip"
              (and (= (length dirs3) 1)
                   (= (ms-directive-ability-id (first dirs3)) 556)
                   (equal? (ms-directive-unit-tags (first dirs3)) '(103 104))
                   (ms-directive-urgent? (first dirs3))
                   (not (set-member? (mode-stealth-plan-claimed-mode-unit-tags p3) 105))
                   (= (hash-ref (mode-stealth-state-depot-toggle-cooldown st) 103 0) (+ 550 36)))
              (format "dirs=~a cd103=~a" dirs3 (hash-ref (mode-stealth-state-depot-toggle-cooldown st) 103 0)))

  ;; `clear-mode-stealth-depot-cooldown!` immediately unblocks depot 103 on next loop (`551`)!
  (clear-mode-stealth-depot-cooldown! st 103)
  (define p4 (plan-mode-and-stealth-safety!
              st #:loop 551 #:self-units (list d-r1) #:enemy-units '()))
  (check-true "L66-MS-1g-clear-depot-cooldown-immediate-retry"
              (and (= (length (mode-stealth-plan-directives p4)) 1)
                   (= (ms-directive-ability-id (first (mode-stealth-plan-directives p4))) 556))
              (format "got=~a" (mode-stealth-plan-directives p4))))

;; -----------------------------------------------------------------------------
;; 2. Siege Tank Unsiege (390), Lurker Unburrow (2110), Widow Mine Hysteresis
;; -----------------------------------------------------------------------------
(let ()
  (define st (make-mode-stealth-state))
  (define tank (mk-info 301 32 40.0 40.0 #:combat? #t))
  (define lurk (mk-info 302 503 80.0 80.0 #:burrowed? #t #:combat? #t))
  (define e-air-near-lurk (mk-info 401 55 84.0 80.0 #:flying? #t #:combat? #t))
  (define e-far-from-tank (mk-info 402 48 60.0 40.0 #:combat? #t)) ;; 20.0t > 15.5t
  (define p1 (plan-mode-and-stealth-safety!
              st #:loop 1000
              #:self-units (list tank lurk)
              #:enemy-units (list e-air-near-lurk e-far-from-tank)))
  (define abs1 (map ms-directive-ability-id (mode-stealth-plan-directives p1)))
  (check-true "L66-MS-2a-tank-unsiege-390-and-lurker-unburrow-2110-ignores-flyer"
              (and (memv 390 abs1) (memv 2110 abs1) #t)
              (format "abs=~a" abs1))

  ;; On cooldown at loop 1020 -> suppressed
  (define p2 (plan-mode-and-stealth-safety!
              st #:loop 1020 #:self-units (list tank lurk) #:enemy-units '()))
  (check-true "L66-MS-2b-mode-toggle-44f-cooldown"
              (null? (mode-stealth-plan-directives p2))
              (format "got=~a" (mode-stealth-plan-directives p2)))

  ;; Widow Mine (498 -> 2095 burrow <= 11.0t; 500 -> 2097 unburrow needs >= 66f clear AND > 12t from TH)
  (define wm-unbur (mk-info 303 498 100.0 100.0 #:combat? #t))
  (define e-near-wm (mk-info 403 48 108.0 100.0 #:combat? #t)) ;; 8.0t <= 11.0t
  (define pw1 (plan-mode-and-stealth-safety!
               st #:loop 1100 #:self-units (list wm-unbur) #:enemy-units (list e-near-wm)))
  (check-true "L66-MS-2c-widow-mine-burrow-2095"
              (and (= (length (mode-stealth-plan-directives pw1)) 1)
                   (= (ms-directive-ability-id (first (mode-stealth-plan-directives pw1))) 2095)))

  ;; Now burrowed (500), enemy gone at loop 1150 (only 50f < 66f clear) -> holds burrowed!
  (define wm-bur (mk-info 303 500 100.0 100.0 #:burrowed? #t #:combat? #t))
  (define pw2 (plan-mode-and-stealth-safety!
               st #:loop 1150 #:self-units (list wm-bur) #:enemy-units '()))
  (check-true "L66-MS-2d-widow-mine-holds-before-66f-clear"
              (null? (mode-stealth-plan-directives pw2)))

  ;; At loop 1170 (>= 66f clear), friendly TownHall 8.0t away (<= 12.0t) -> STILL holds mineral-line defense!
  (define th-near (mk-info 310 132 108.0 100.0 #:structure? #t #:townhall? #t))
  (define pw3 (plan-mode-and-stealth-safety!
               st #:loop 1170 #:self-units (list wm-bur th-near) #:enemy-units '()))
  (check-true "L66-MS-2e-widow-mine-holds-near-townhall-12t"
              (null? (mode-stealth-plan-directives pw3)))

  ;; Without nearby TownHall at loop 1170 (>= 66f clear) -> unburrows (2097)!
  (define pw4 (plan-mode-and-stealth-safety!
               st #:loop 1170 #:self-units (list wm-bur) #:enemy-units '()))
  (check-true "L66-MS-2f-widow-mine-unburrows-2097-after-66f-far-from-th"
              (and (= (length (mode-stealth-plan-directives pw4)) 1)
                   (= (ms-directive-ability-id (first (mode-stealth-plan-directives pw4))) 2097))))

;; -----------------------------------------------------------------------------
;; 3. Emergency Mobile Detector Intercept: Priority (-10t Cloaked Raider vs -4t Mine),
;;    Cluster Centroid, Unmorph 1912->3745 / 1911->3739, `claimed-detector-tags`,
;;    Scout Lease Preemption, & `explicit-combat-tags` Respect
;; -----------------------------------------------------------------------------
(let ()
  (define st (make-mode-stealth-state))
  ;; One Overseer (129) with a lower-priority `'scout` lease (prio 70 < 75 `'detector-escort`),
  ;; one explicit-combat Observer (82) that must NOT be stolen,
  ;; plus one sieged Overseer (1912) and one sieged Observer (1911).
  (define wrk (mk-info 501 45 30.0 30.0 #:worker? #t))
  (define ally-c (mk-info 502 105 34.0 30.0 #:combat? #t))
  (define ov-scout (mk-info 510 129 60.0 60.0 #:flying? #t #:order-ability-id 16 #:order-target-x 140.0 #:order-target-y 140.0))
  (define obs-exp (mk-info 511 82 35.0 30.0 #:flying? #t))
  ;; Cloaked Banshee raiding workers at (32, 30) AND burrowed Widow Mine 5t away from another unit at (90, 90)
  (define e-banshee (mk-info 601 55 32.0 30.0 #:flying? #t #:cloaked? #t #:detected? #f #:combat? #t))
  (define e-dt-cl   (mk-info 602 76 36.0 30.0 #:cloaked? #t #:detected? #f #:combat? #t)) ;; 4t from Banshee -> cluster centroid (34, 30)
  (define e-mine    (mk-info 603 500 90.0 90.0 #:burrowed? #t #:detected? #f #:combat? #t))
  (define leases (hasheqv 510 (unit-role-lease 'scout 70 0 140.0 140.0 5000)))
  (define p (plan-mode-and-stealth-safety!
             st #:loop 2000
             #:self-units (list wrk ally-c ov-scout obs-exp)
             #:enemy-units (list e-mine e-banshee e-dt-cl)
             #:explicit-combat-tags (seteqv 511)
             #:role-leases leases))
  (define dirs (mode-stealth-plan-directives p))
  (define d1 (and (= (length dirs) 1) (first dirs)))
  (check-true "L66-MS-3a-detector-preempts-scout-prioritizes-raider-cluster-and-respects-explicit"
              (and (mode-stealth-plan-uncovered-stealth-present? p)
                   d1
                   (= (ms-directive-ability-id d1) 16)
                   (equal? (ms-directive-unit-tags d1) '(510))
                   (ms-directive-urgent? d1)
                   ;; Centroid of (32,30) & (36,30) is (34,30), ally-c is at (34,30) -> aim near (34,30)!
                   (<= (abs (- (ms-directive-target-x d1) 34.0)) 0.5)
                   (<= (abs (- (ms-directive-target-y d1) 30.0)) 0.5)
                   (set-member? (mode-stealth-plan-claimed-detector-tags p) 510)
                   (not (set-member? (mode-stealth-plan-claimed-detector-tags p) 511)))
              (format "dirs=~a claimed=~a" dirs (mode-stealth-plan-claimed-detector-tags p)))

  ;; Unmorph sieged detectors (`1912 -> 3745`, `1911 -> 3739`) on two separate stealth fronts
  (define ov-s (mk-info 520 1912 30.0 30.0 #:flying? #t))
  (define ob-s (mk-info 521 1911 110.0 110.0 #:flying? #t))
  (define e-dt1 (mk-info 610 76 35.0 30.0 #:cloaked? #t #:detected? #f #:combat? #t))
  (define e-dt2 (mk-info 611 76 115.0 110.0 #:cloaked? #t #:detected? #f #:combat? #t))
  (define pu (plan-mode-and-stealth-safety!
              st #:loop 2010
              #:self-units (list ov-s ob-s)
              #:enemy-units (list e-dt1 e-dt2)))
  (define u-abs (map ms-directive-ability-id (mode-stealth-plan-directives pu)))
  (check-true "L66-MS-3b-sieged-detector-unmorph-3745-and-3739"
              (and (memv 3745 u-abs)
                   (memv 3739 u-abs)
                   (set-member? (mode-stealth-plan-claimed-detector-tags pu) 520)
                   (set-member? (mode-stealth-plan-claimed-detector-tags pu) 521))
              (format "u-abs=~a claimed=~a" u-abs (mode-stealth-plan-claimed-detector-tags pu))))

;; -----------------------------------------------------------------------------
;; 4. Emergency Terran OC Scanner Sweep (399): 1.6x vs 1.5x Scoring, 160f Cell
;;    Non-Stack, `explicit-scan-oc-tags` Skip, & Arbiter Energy Win over MULE
;; -----------------------------------------------------------------------------
(let ()
  (define st (make-mode-stealth-state))
  (define ledger (make-arbiter-ledger))
  (define oc1 (mk-info 701 132 30.0 30.0 #:energy 50.0 #:structure? #t #:townhall? #t))
  (define oc2-exp (mk-info 702 132 35.0 30.0 #:energy 120.0 #:structure? #t #:townhall? #t))
  (define scv1 (mk-info 710 45 28.0 30.0 #:worker? #t))
  (define scv2 (mk-info 711 45 78.0 80.0 #:worker? #t))
  ;; Banshee raiding scv1 (1.6x weight) vs lone Widow Mine near scv2 (1.5x weight) -> Scans Banshee!
  (define e-ban (mk-info 801 55 32.0 30.0 #:flying? #t #:cloaked? #t #:detected? #f #:combat? #t))
  (define e-wm  (mk-info 802 500 80.0 80.0 #:burrowed? #t #:detected? #f #:combat? #t))
  (define ps1 (plan-mode-and-stealth-safety!
               st #:loop 3000
               #:self-units (list oc1 oc2-exp scv1 scv2)
               #:enemy-units (list e-wm e-ban)
               #:explicit-scan-oc-tags (seteqv 702)
               #:arbiter-ledger ledger))
  (define sdirs1 (mode-stealth-plan-directives ps1))
  (define sd1 (and (= (length sdirs1) 1) (first sdirs1)))
  (check-true "L66-MS-4a-emerg-scan-399-picks-1.6x-raider-skips-explicit-oc-claims-701"
              (and sd1
                   (= (ms-directive-ability-id sd1) 399)
                   (equal? (ms-directive-unit-tags sd1) '(701))
                   (ms-directive-urgent? sd1)
                   (<= (abs (- (ms-directive-target-x sd1) 32.0)) 0.5)
                   (<= (abs (- (ms-directive-target-y sd1) 30.0)) 0.5)
                   (set-member? (mode-stealth-plan-claimed-scan-oc-tags ps1) 701)
                   (not (set-member? (mode-stealth-plan-claimed-scan-oc-tags ps1) 702)))
              (format "dirs=~a claimed=~a" sdirs1 (mode-stealth-plan-claimed-scan-oc-tags ps1)))

  ;; 160f cell non-stack cooldown blocks repeat scan on same cell at loop 3050, allows at loop 3160!
  (define ps2 (plan-mode-and-stealth-safety!
               st #:loop 3050
               #:self-units (list oc1 scv1)
               #:enemy-units (list e-ban)
               #:arbiter-ledger ledger))
  (define ps3 (plan-mode-and-stealth-safety!
               st #:loop 3160
               #:self-units (list oc1 scv1)
               #:enemy-units (list e-ban)
               #:arbiter-ledger ledger))
  (check-true "L66-MS-4b-emerg-scan-160f-cell-nonstack"
              (and (null? (mode-stealth-plan-directives ps2))
                   (= (length (mode-stealth-plan-directives ps3)) 1)
                   (= (ms-directive-ability-id (first (mode-stealth-plan-directives ps3))) 399))
              (format "ps2=~a ps3=~a" (mode-stealth-plan-directives ps2) (mode-stealth-plan-directives ps3)))

  ;; Direct arbiter-resolve! verification: Scan (prio 980, 50e) beats competing MULE (prio 700, 50e) on 50e OC
  (define comp-ledger (make-arbiter-ledger))
  (define comp-res
    (arbiter-resolve!
     comp-ledger 3200
     (make-arbiter-budget-snapshot #:caster-energy-by-tag (hasheqv 701 50.0))
     (list (make-proposal 'mule-701 'macro-ability-policy 'energy 700.0 '(cast-mule 701)
                          #:energy (make-proposal-energy 701 'orbital-command 50.0))
           (make-proposal 'scan-701 'mode-and-stealth-safety 'tactics 980.0 '(scan 701 32.0 30.0)
                          #:claim (make-proposal-claim '(701) #:role 'detector-escort #:lease-ttl 0)
                          #:energy (make-proposal-energy 701 'orbital-command 50.0)))))
  (check-true "L66-MS-4c-arbiter-scan-980-beats-mule-700-on-50e-oc"
              (and (equal? (arbiter-result-approved-actions comp-res) '((scan 701 32.0 30.0)))
                   (= (length (arbiter-result-override-signals comp-res)) 1)
                   (eq? (override-signal-reason (first (arbiter-result-override-signals comp-res)))
                        'energy-reserved))))

;; -----------------------------------------------------------------------------
;; 5. Frame-Rewind Full State Reset & Hot-Path Performance (< 0.12 ms/step)
;; -----------------------------------------------------------------------------
(let ()
  (define st (make-mode-stealth-state))
  (define d1 (mk-info 901 19 50.0 50.0 #:structure? #t))
  (plan-mode-and-stealth-safety! st #:loop 4000 #:self-units (list d1) #:enemy-units '())
  ;; Rewind to loop 4 -> resets all cooldown tables so depot toggles immediately again!
  (define p-rew (plan-mode-and-stealth-safety! st #:loop 4 #:self-units (list d1) #:enemy-units '()))
  (check-true "L66-MS-5a-frame-rewind-resets-all-cooldowns"
              (and (= (length (mode-stealth-plan-directives p-rew)) 1)
                   (= (ms-directive-ability-id (first (mode-stealth-plan-directives p-rew))) 556)))

  ;; Performance benchmark: 500 typical midgame steps with 60 self + 40 enemy units
  (define self60
    (append (list (mk-info 910 19 40.0 40.0 #:structure? #t)
                  (mk-info 911 132 30.0 30.0 #:energy 80.0 #:structure? #t #:townhall? #t)
                  (mk-info 912 32 60.0 60.0 #:combat? #t))
            (for/list ([i (in-range 57)])
              (mk-info (+ 920 i) 48 (+ 50.0 (* 0.5 i)) 50.0 #:combat? #t))))
  (define enemy40
    (for/list ([i (in-range 40)])
      (mk-info (+ 1920 i) 105 (+ 65.0 (* 0.4 i)) 65.0 #:combat? #t)))
  (define t0 (current-inexact-milliseconds))
  (for ([k (in-range 500)])
    (plan-mode-and-stealth-safety! st #:loop (+ 100 k) #:self-units self60 #:enemy-units enemy40))
  (define avg-ms (/ (- (current-inexact-milliseconds) t0) 500.0))
  (check-true (format "L66-MS-5b-hotpath-avg-step-lt-0.12ms (avg=~a ms/step)"
                      (/ (round (* avg-ms 10000.0)) 10000.0))
              (< avg-ms 0.12)))

(printf "\n=== Loop 66 Mode & Stealth Safety Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
