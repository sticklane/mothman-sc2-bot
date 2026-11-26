#lang racket/base

;; =============================================================================
;; Loop 86 Track 3: Softest-Outer-Base Target Selection, Choke-Attrition
;; Drip-Feed Breaker (All 5 Anti-Stalemate Valves) & Mobile Detector Army Escort
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/tactics/multiprong-coordinator.rkt"
         "../lib/tactics/staging-groups.rkt"
         "../lib/tactics/mode-and-stealth-safety.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check-true name expr)
  (if expr
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected truthy, got ~s\n" name expr))))

(define (check-equal name actual expected)
  (if (equal? actual expected)
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected ~s, got ~s\n" name expected actual))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-u id sym x y #:flying? [fl? #f] #:bp [bp 1.0])
  (hasheq 'id id 'type sym 'x x 'y y 'flying? fl? 'build-progress bp))

;; =============================================================================
;; 1. Exposure-Scored Softest-Outer-Base Target Selection (Track 3A)
;; =============================================================================
(printf "[1/3] Testing score-enemy-base-fortification, select-softest-enemy-base-target & multiprong integration...\n")

;; 1a. Exact scoring weights + zero double-counting across enemy-units & enemy-buildings
(define fort-bpt (cons 120.0 100.0))
(define fort-bldgs
  (list (mk-u 101 'planetary-fortress 120.0 100.0)
        (mk-u 102 'bunker 115.0 102.0)
        (mk-u 103 'missile-turret 122.0 105.0)))
(define fort-units
  (list (mk-u 101 'planetary-fortress 120.0 100.0) ;; duplicate tag -> MUST NOT double count!
        (mk-u 201 'siege-tank-sieged 118.0 104.0)
        (mk-u 202 'widow-mine-burrowed 114.0 98.0)
        (mk-u 203 'marine 116.0 100.0)))
(define-values (f-tot f-sf f-sm f-av)
  (score-enemy-base-fortification fort-bpt fort-units fort-bldgs
                                  #:enemy-main-xy (cons 150.0 150.0)
                                  #:army-xy (cons 60.0 100.0)))
(check-true "l86-3a-static-fort-pf-bunker-turret-no-dup" (< (abs (- f-sf (+ 650.0 350.0 90.0))) 0.01))
(check-true "l86-3a-siege-mine-tank-and-mine" (< (abs (- f-sm (+ 320.0 180.0))) 0.01))
(check-true "l86-3a-army-val-positive" (> f-av 0.0))

;; Blacklist penalty adds exact +1400.0
(define-values (f-tot-bl _sf2 _sm2 _av2)
  (score-enemy-base-fortification fort-bpt fort-units fort-bldgs
                                  #:enemy-main-xy (cons 150.0 150.0)
                                  #:army-xy (cons 60.0 100.0)
                                  #:choke-blacklist-fn (lambda (p) (< (dist2d (car p) (cdr p) 120.0 100.0) 10.0))))
(check-true "l86-3a-blacklist-penalty-1400" (< (abs (- (- f-tot-bl f-tot) 1400.0)) 0.01))

;; 1b. Open outer 5th base beats fortified front 3rd (Bunkers + Tanks + Mines) AND generates flank waypoint >= 18t clear!
(define em-main (cons 160.0 160.0))
(define em-nat  (cons 140.0 140.0))
(define em-3rd  (cons 110.0 105.0)) ;; Fortified choke right on path from army (60, 100) -> 5th (155, 110)
(define em-5th  (cons 155.0 110.0)) ;; Wide-open outer 5th expansion!
(define fort-choke-bldgs
  (list (mk-u 301 'bunker 110.0 103.0)
        (mk-u 302 'bunker 112.0 107.0)
        (mk-u 303 'shield-battery 140.0 138.0)
        (mk-u 304 'photon-cannon 142.0 142.0)
        (mk-u 305 'command-center 160.0 160.0)))
(define fort-choke-units
  (list (mk-u 310 'siege-tank-sieged 111.0 106.0)
        (mk-u 311 'siege-tank-sieged 108.0 105.0)
        (mk-u 312 'widow-mine-burrowed 109.0 102.0)
        (mk-u 313 'widow-mine-burrowed 112.0 103.0)))
(define-values (best-b best-sc avoid-b flank-b)
  (select-softest-enemy-base-target
   #:enemy-base-pts (list em-main em-nat em-3rd em-5th (cons 155.5 110.5)) ;; dup within 10t merges cleanly
   #:enemy-units fort-choke-units
   #:enemy-buildings fort-choke-bldgs
   #:enemy-main-xy em-main
   #:army-xy (cons 60.0 100.0)
   #:map-width 200.0
   #:map-height 200.0))
(check-true "l86-3a-picks-open-5th-over-fortified-3rd"
            (and (pair? best-b) (< (dist2d (car best-b) (cdr best-b) 155.0 110.0) 2.0)))
(check-true "l86-3a-identifies-fortified-3rd-obstacle"
            (and (pair? avoid-b) (< (dist2d (car avoid-b) (cdr avoid-b) 110.0 105.0) 2.0)))
(check-true "l86-3a-flank-waypoint-clears-choke-ge-18t"
            (and (pair? flank-b) (>= (dist2d (car flank-b) (cdr flank-b) 110.0 105.0) 18.0)))

;; 1c. No fortified obstacle on direct line -> avoid-pt and flank-xy stay #f (zero needless detour)
(define-values (direct-b _dsc direct-avoid direct-flank)
  (select-softest-enemy-base-target
   #:enemy-base-pts (list em-main em-5th)
   #:enemy-units '()
   #:enemy-buildings '()
   #:enemy-main-xy em-main
   #:army-xy (cons 120.0 60.0)))
(check-true "l86-3a-direct-open-picks-outer-5th"
            (and (pair? direct-b) (< (dist2d (car direct-b) (cdr direct-b) 155.0 110.0) 2.0)))
(check-equal "l86-3a-direct-open-no-avoid" direct-avoid #f)
(check-equal "l86-3a-direct-open-no-flank" direct-flank #f)

;; 1d. step-multiprong-coordinator! consumes #:extra-enemy-base-pts & #:choke-blacklist-fn
(define mp-st (make-multiprong-state))
(define mp-ally-ths (list (mk-u 1 'nexus 30.0 30.0) (mk-u 2 'nexus 50.0 30.0)))
(define mp-combat
  (for/list ([i (in-range 1 21)])
    (mk-u (+ 1000 i) (if (<= i 6) 'zealot 'stalker) (+ 55.0 (* 0.5 i)) 55.0)))
;; Enemy army (`12` Marines = `12.0` sup >= `10.0`) sitting at enemy main/nat (150, 150); OWM remembered open outer base at (155, 55)!
(define mp-enemy-units
  (for/list ([i (in-range 1 13)])
    (mk-u (+ 2000 i) 'marine (+ 148.0 (* 0.4 i)) 148.0)))
(define mp-res
  (step-multiprong-coordinator!
   mp-st
   #:frame 9000
   #:live-obs? #t
   #:race 'Protoss
   #:ally-units mp-combat
   #:combat-units mp-combat
   #:ally-townhalls mp-ally-ths
   #:enemy-units mp-enemy-units
   #:enemy-townhalls (list (mk-u 2500 'command-center 150.0 150.0))
   #:base-x 30.0 #:base-y 30.0
   #:enemy-x 150.0 #:enemy-y 150.0
   #:extra-enemy-base-pts (list (cons 110.0 110.0) (cons 155.0 55.0))
   #:choke-blacklist-fn (lambda (p) (< (dist2d (car p) (cdr p) 110.0 110.0) 15.0))))
(check-equal "l86-3a-multiprong-backstab-uses-owm-unblacklisted-base"
             (multiprong-result-mode mp-res) 'counter-backstab)
(check-true "l86-3a-multiprong-backstab-targets-open-outer-base"
            (and (pair? (multiprong-result-active-prong-target mp-res))
                 (< (dist2d (car (multiprong-result-active-prong-target mp-res))
                            (cdr (multiprong-result-active-prong-target mp-res))
                            155.0 55.0)
                    5.0)))

;; =============================================================================
;; 2. Choke-Attrition / Small-Wave Drip-Feed Breaker + All 5 Release Valves (Track 3B)
;; =============================================================================
(printf "[2/3] Testing update-choke-attrition-breaker! & all 5 anti-stalemate release valves...\n")

(define (make-stalker-wave start-id n x y)
  (for/list ([i (in-range n)])
    ;; Stalker = 125M + 50G = 175 res val -> 8 Stalkers = 1400 >= 1200!
    (mk-u (+ start-id i) 'stalker (+ x (* 0.2 i)) y)))

(define choke-bldgs (list (mk-u 900 'bunker 100.0 100.0) (mk-u 901 'bunker 102.0 102.0)))

;; 2a. Open-field loss (>= 1200 with zero TH/forts and turtle=0.05, even with >= 1000 enemy army) MUST NOT trigger!
(define cst-open (make-choke-attrition-state))
(define wave-open (make-stalker-wave 100 10 100.0 100.0))
(define open-field-enemies
  (for/list ([i (in-range 10)])
    (mk-u (+ 8000 i) 'marauder (+ 102.0 (* 0.3 i)) 100.0))) ;; 1250 enemy army value, 0 TH, 0 forts!
(void (update-choke-attrition-breaker! cst-open #:frame 9000 #:combat-units wave-open
                                       #:enemy-units open-field-enemies #:enemy-turtle-posterior 0.05))
(define v-open (update-choke-attrition-breaker! cst-open #:frame 9024 #:combat-units (drop wave-open 8)
                                                #:enemy-units open-field-enemies #:enemy-turtle-posterior 0.05))
(check-equal "l86-3b-open-field-no-hold" (choke-attrition-verdict-hold-active? v-open) #f)
(check-equal "l86-3b-open-field-no-blacklist" (choke-attrition-verdict-blacklisted-zone-key v-open) #f)

;; 2a-ii. Loop 86C: Normal mobile-army battle near an enemy expansion (0 static fort, mobile Marauders/
;;        unsieged Siege Tanks, turtle=0.08) MUST NOT trigger a false 60s choke hold!
(define cst-mobexp (make-choke-attrition-state))
(define mobexp-bldgs (list (mk-u 910 'command-center 102.0 102.0)))
(define mobexp-units
  (list (mk-u 911 'marauder 100.0 101.0) (mk-u 912 'marauder 101.0 101.0)
        (mk-u 913 'marauder 102.0 101.0) (mk-u 914 'marauder 103.0 101.0)
        (mk-u 915 'siege-tank 104.0 101.0) (mk-u 916 'siege-tank 105.0 101.0))) ;; mobile unsieged tanks!
(define wave-defexp (make-stalker-wave 150 8 100.0 100.0))
(void (update-choke-attrition-breaker! cst-mobexp #:frame 9000 #:combat-units wave-defexp
                                       #:enemy-units mobexp-units #:enemy-buildings mobexp-bldgs
                                       #:enemy-turtle-posterior 0.08))
(define v-mobexp
  (update-choke-attrition-breaker! cst-mobexp #:frame 9024 #:combat-units '()
                                   #:enemy-units mobexp-units #:enemy-buildings mobexp-bldgs
                                   #:enemy-turtle-posterior 0.08))
(check-equal "l86c-3b-mobile-battle-near-cc-no-false-hold"
             (choke-attrition-verdict-hold-active? v-mobexp) #f)
(check-equal "l86c-3b-mobile-battle-near-cc-no-blacklist"
             (choke-attrition-verdict-blacklisted-zone-key v-mobexp) #f)

;; 2a-iii. Loop 86C: Genuine Planetary Fortress (`650 >= 350`) or `2x` Sieged Tanks (`640 >= 350`)
;;         DOES trigger zone blacklist + pivot/hold even when `enemy-turtle-posterior < 0.45`!
(define cst-pf (make-choke-attrition-state))
(define pf-bldgs (list (mk-u 920 'planetary-fortress 102.0 102.0)))
(void (update-choke-attrition-breaker! cst-pf #:frame 9000 #:combat-units wave-defexp
                                       #:enemy-buildings pf-bldgs #:enemy-turtle-posterior 0.08))
(define v-pf
  (update-choke-attrition-breaker! cst-pf #:frame 9024 #:combat-units '()
                                   #:enemy-buildings pf-bldgs #:enemy-turtle-posterior 0.08
                                   #:soft-alt-xy (cons 155.0 55.0)
                                   #:soft-alt-score 90.0))
(check-equal "l86c-3b-pf-triggers-outer-pivot-even-at-low-turtle"
             (choke-attrition-verdict-release-reason v-pf) 'outer-pivot)
(check-true  "l86c-3b-pf-blacklists-zone"
             (choke-attrition-zone-blacklisted? cst-pf (cons 102.0 102.0) 9050))
(check-equal "l86c-3b-pf-pivot-no-hold"
             (choke-attrition-verdict-hold-active? v-pf) #f)

(define cst-sieged (make-choke-attrition-state))
(define sieged-units (list (mk-u 925 'siege-tank-sieged 100.0 100.0)
                           (mk-u 926 'siege-tank-sieged 102.0 100.0)))
(void (update-choke-attrition-breaker! cst-sieged #:frame 9000 #:combat-units wave-defexp
                                       #:enemy-units sieged-units #:enemy-turtle-posterior 0.08))
(define v-sieged (update-choke-attrition-breaker! cst-sieged #:frame 9024 #:combat-units '()
                                                  #:enemy-units sieged-units #:enemy-turtle-posterior 0.08))
(check-equal "l86c-3b-sieged-tanks-trigger-hold-even-at-low-turtle"
             (choke-attrition-verdict-hold-active? v-sieged) #t)

;; 2b. Fortified choke loss >= 1200 across a 12t grid boundary (x=95.5 & x=96.5) with soft outer pivot -> ZERO hold!
(define cst-piv (make-choke-attrition-state))
(define wave-piv
  (append (make-stalker-wave 200 4 95.5 100.0)
          (make-stalker-wave 210 4 96.5 100.0))) ;; 8 * 175 = 1400 split across x=96 boundary!
(void (update-choke-attrition-breaker! cst-piv #:frame 9000 #:combat-units wave-piv #:enemy-buildings choke-bldgs))
(define v-piv
  (update-choke-attrition-breaker! cst-piv
                                   #:frame 9024
                                   #:combat-units '()
                                   #:enemy-buildings choke-bldgs
                                   #:soft-alt-xy (cons 150.0 60.0)
                                   #:soft-alt-score 120.0))
(check-equal "l86-3b-soft-pivot-no-hold" (choke-attrition-verdict-hold-active? v-piv) #f)
(check-equal "l86-3b-soft-pivot-reason" (choke-attrition-verdict-release-reason v-piv) 'outer-pivot)
(check-true  "l86-3b-soft-pivot-target-xy"
             (and (pair? (choke-attrition-verdict-redirect-target-xy v-piv))
                  (= (car (choke-attrition-verdict-redirect-target-xy v-piv)) 150.0)
                  (= (cdr (choke-attrition-verdict-redirect-target-xy v-piv)) 60.0)))
(check-true  "l86-3b-zone-blacklisted-pair-api"
             (choke-attrition-zone-blacklisted? cst-piv (cons 96.0 100.0) 9050))
(check-true  "l86-3b-zone-blacklisted-xy-api"
             (choke-attrition-zone-blacklisted? cst-piv 96.0 100.0 9050))
(check-equal "l86-3b-zone-blacklist-expires-after-90s"
             (choke-attrition-zone-blacklisted? cst-piv (cons 96.0 100.0) (+ 9024 2016)) #f)

;; 2c. Bounded hold when NO soft outer base exists + ALL 5 anti-stalemate release valves!
(define cst-hold (make-choke-attrition-state))
(define wave-h (make-stalker-wave 300 8 100.0 100.0))
(void (update-choke-attrition-breaker! cst-hold #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(define v-h1 (update-choke-attrition-breaker! cst-hold #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs
                                              #:supply-used 110 #:our-combat-supply 44.0))
(check-equal "l86-3b-no-soft-alt-enters-hold" (choke-attrition-verdict-hold-active? v-h1) #t)
(check-true  "l86-3b-rolling-loss-ge-1200" (>= (choke-attrition-verdict-rolling-loss-val v-h1) 1200.0))

;; Still holding at +800f (< 1344f)
(define v-h2 (update-choke-attrition-breaker! cst-hold #:frame 10824 #:combat-units '() #:enemy-buildings choke-bldgs
                                              #:supply-used 120 #:our-combat-supply 50.0))
(check-equal "l86-3b-hold-persists-under-60s" (choke-attrition-verdict-hold-active? v-h2) #t)

;; Valve 5: Hard 60s (`1344f`) max-duration timer forces release + 60s refractory immunity!
(define v-v5 (update-choke-attrition-breaker! cst-hold #:frame (+ 10024 1344) #:combat-units '() #:enemy-buildings choke-bldgs
                                              #:supply-used 120 #:our-combat-supply 50.0))
(check-equal "l86-3b-valve5-max-duration-releases" (choke-attrition-verdict-hold-active? v-v5) #f)
(check-equal "l86-3b-valve5-max-duration-reason" (choke-attrition-verdict-release-reason v-v5) 'max-duration)
;; Refractory immunity: another 1400 loss 200f later MUST NOT re-enter hold!
(define wave-ref (make-stalker-wave 350 8 100.0 100.0))
(void (update-choke-attrition-breaker! cst-hold #:frame (+ 10024 1400) #:combat-units wave-ref #:enemy-buildings choke-bldgs))
(define v-ref (update-choke-attrition-breaker! cst-hold #:frame (+ 10024 1424) #:combat-units '() #:enemy-buildings choke-bldgs))
(check-equal "l86-3b-valve5-refractory-blocks-rehold" (choke-attrition-verdict-hold-active? v-ref) #f)
(check-equal "l86-3b-valve5-refractory-reason" (choke-attrition-verdict-release-reason v-ref) 'max-duration)

;; Valve 3: Max-supply (`>= 165` supply OR `>= 80` combat supply) releases hold immediately
(define cst-v3 (make-choke-attrition-state))
(void (update-choke-attrition-breaker! cst-v3 #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(void (update-choke-attrition-breaker! cst-v3 #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs #:supply-used 120))
(define v-v3 (update-choke-attrition-breaker! cst-v3 #:frame 10100 #:combat-units '() #:enemy-buildings choke-bldgs #:supply-used 168))
(check-equal "l86-3b-valve3-max-supply-releases" (choke-attrition-verdict-hold-active? v-v3) #f)
(check-equal "l86-3b-valve3-max-supply-reason" (choke-attrition-verdict-release-reason v-v3) 'max-supply)

;; Valve 4: Siege + Detection Ready Release (holds without detector at narrow 1.18x advantage, releases WITH detector!)
(define cst-v4 (make-choke-attrition-state))
(void (update-choke-attrition-breaker! cst-v4 #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(void (update-choke-attrition-breaker! cst-v4 #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs))
(define v-v4-nodet
  (update-choke-attrition-breaker! cst-v4 #:frame 10100 #:combat-units '() #:enemy-buildings choke-bldgs
                                   #:our-siege-breaker-count 2 #:enemy-needs-detection? #t #:has-army-detector? #f
                                   #:our-combat-val 2360.0 #:known-enemy-val 2000.0))
(check-equal "l86-3b-valve4-waits-for-detector-when-needed" (choke-attrition-verdict-hold-active? v-v4-nodet) #t)
(define v-v4-ready
  (update-choke-attrition-breaker! cst-v4 #:frame 10124 #:combat-units '() #:enemy-buildings choke-bldgs
                                   #:our-siege-breaker-count 2 #:enemy-needs-detection? #t #:has-army-detector? #t
                                   #:our-combat-val 2360.0 #:known-enemy-val 2000.0))
(check-equal "l86-3b-valve4-siege-and-detector-releases" (choke-attrition-verdict-hold-active? v-v4-ready) #f)
(check-equal "l86-3b-valve4-siege-ready-reason" (choke-attrition-verdict-release-reason v-v4-ready) 'siege-ready)

;; Loop 86C Winning-Army Override: >= 1.25x army advantage NEVER activates AND immediately releases hold!
(define cst-win (make-choke-attrition-state))
(void (update-choke-attrition-breaker! cst-win #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(define v-win-noenter
  (update-choke-attrition-breaker! cst-win #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs
                                   #:our-combat-val 2600.0 #:known-enemy-val 2000.0))
(check-equal "l86c-3b-winning-army-never-enters-hold" (choke-attrition-verdict-hold-active? v-win-noenter) #f)
(check-equal "l86c-3b-winning-army-never-enters-reason" (choke-attrition-verdict-release-reason v-win-noenter) 'winning-army)
;; Also releases an already-active hold immediately once our army reaches >= 1.25x
(define cst-win2 (make-choke-attrition-state))
(void (update-choke-attrition-breaker! cst-win2 #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(define v-win2-held
  (update-choke-attrition-breaker! cst-win2 #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs
                                   #:our-combat-val 1800.0 #:known-enemy-val 2000.0))
(check-equal "l86c-3b-behind-army-still-holds" (choke-attrition-verdict-hold-active? v-win2-held) #t)
(define v-win2-rel
  (update-choke-attrition-breaker! cst-win2 #:frame 10100 #:combat-units '() #:enemy-buildings choke-bldgs
                                   #:our-combat-val 2600.0 #:known-enemy-val 2000.0))
(check-equal "l86c-3b-winning-army-releases-active-hold" (choke-attrition-verdict-hold-active? v-win2-rel) #f)
(check-equal "l86c-3b-winning-army-release-reason" (choke-attrition-verdict-release-reason v-win2-rel) 'winning-army)

;; Valve 2: TH Kill resets blacklist & suppresses re-trigger; Home Defense immediately releases hold
(define cst-v2 (make-choke-attrition-state))
(void (update-choke-attrition-breaker! cst-v2 #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(void (update-choke-attrition-breaker! cst-v2 #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs))
(define v-v2-hd (update-choke-attrition-breaker! cst-v2 #:frame 10060 #:combat-units '() #:enemy-buildings choke-bldgs #:under-home-attack? #t))
(check-equal "l86-3b-valve2-home-attack-releases" (choke-attrition-verdict-hold-active? v-v2-hd) #f)
(check-equal "l86-3b-valve2-home-attack-reason" (choke-attrition-verdict-release-reason v-v2-hd) 'home-defense)
(define v-v2-th (update-choke-attrition-breaker! cst-v2 #:frame 10080 #:combat-units '() #:enemy-buildings choke-bldgs #:enemy-th-killed? #t))
(check-equal "l86-3b-valve2-th-kill-reason" (choke-attrition-verdict-release-reason v-v2-th) 'th-killed)
(check-equal "l86-3b-valve2-th-kill-clears-blacklist" (choke-attrition-zone-blacklisted? cst-v2 (cons 100.0 100.0) 10090) #f)

;; Valve 1: Bypass Guard (cheese / --no-macro)
(define cst-v1 (make-choke-attrition-state))
(void (update-choke-attrition-breaker! cst-v1 #:frame 10000 #:combat-units wave-h #:enemy-buildings choke-bldgs))
(define v-v1-ch (update-choke-attrition-breaker! cst-v1 #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs #:cheese-committed? #t))
(define v-v1-nm (update-choke-attrition-breaker! cst-v1 #:frame 10048 #:combat-units '() #:enemy-buildings choke-bldgs #:skip-build-order? #t))
(check-equal "l86-3b-valve1-cheese-bypass" (choke-attrition-verdict-release-reason v-v1-ch) 'bypass)
(check-equal "l86-3b-valve1-nomacro-bypass" (choke-attrition-verdict-release-reason v-v1-nm) 'bypass)

;; =============================================================================
;; 3. Mobile Detector Army Escort & Raven 56 Safety (Track 3C)
;; =============================================================================
(printf "[3/3] Testing plan-mobile-detector-army-escort (Observer/Overseer/Raven, unmorph, AA/Mine standoff, split)...\n")

;; 3a. Raven (unit-type 56) recognized by plan-mode-and-stealth-safety! emergency stealth intercept!
(define ms-st (make-mode-stealth-state))
(define raven-info
  (ms-unit-info 501 56 40.0 40.0 0.0 0.0 0.625 #t #f #f #f 50.0 1.0 0 0.0 0.0 #f #f #f #f))
(define burrowed-mine-info
  (ms-unit-info 601 500 52.0 40.0 0.0 0.0 0.5 #f #t #f #f 0.0 1.0 0 0.0 0.0 #f #f #f #t))
(define ms-plan
  (plan-mode-and-stealth-safety! ms-st
                                 #:loop 5000
                                 #:self-units (list raven-info)
                                 #:enemy-units (list burrowed-mine-info)))
(check-true "l86-3c-raven-56-claimed-by-emergency-stealth-safety"
            (set-member? (mode-stealth-plan-claimed-detector-tags ms-plan) 501))

;; 3b. Sole Observer, Overseer, and Raven each escort deployed army at safe -2.0t BEHIND centroid by default
;;     (Loop 86E: cures Observer suicide loop flying ahead into fog/Spores/Queens/Turrets!)
(define army-fwd
  (list (mk-u 10 'stalker 100.0 100.0)
        (mk-u 11 'stalker 101.0 99.0)
        (mk-u 12 'immortal 99.0 101.0)
        (mk-u 13 'colossus 100.0 100.0)))
(define own-ths (list (cons 30.0 30.0) (cons 50.0 30.0)))
(for ([spec (in-list '((701 observer) (702 overseer) (703 raven)))])
  (define did (first spec))
  (define dsym (second spec))
  (define-values (cmds ids)
    (plan-mobile-detector-army-escort
     #:detectors (list (mk-u did dsym 60.0 60.0 #:flying? #t))
     #:combat-units army-fwd
     #:enemy-units '()
     #:enemy-buildings '()
     #:own-townhall-pts own-ths
     #:attack-target-xy (cons 140.0 100.0)
     #:active-home-stealth? #f
     #:escort-required? #t))
  (check-true (format "l86e-3c-sole-~a-escorts-safely-behind-army" dsym)
              (and (= (length cmds) 1)
                   (eq? (first (first cmds)) 'move)
                   (= (second (first cmds)) did)
                   (< (third (first cmds)) 99.0)   ;; -2.0t BEHIND 100.0 toward retreat vector (NOT ahead!)
                   (> (third (first cmds)) 97.0)
                   (set-member? ids did))))

;; 3b-ii. Loop 86E: Burrowed Lurkers/Mines + ZERO enemy AA within 13t nudges gently +1.5t forward;
;;        adding enemy Queen/AA within 13t pulls back behind army with >= 9.5t AA standoff!
(define-values (lurk-fwd-cmds _lf-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 705 'observer 85.0 100.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units (list (mk-u 810 'lurker-burrowed 111.0 100.0))
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-true "l86e-3c-burrowed-lurker-zero-aa-nudges-forward-1.5t"
            (and (= (length lurk-fwd-cmds) 1)
                 (> (third (first lurk-fwd-cmds)) 100.8)
                 (< (third (first lurk-fwd-cmds)) 102.2)))

(define-values (lurk-aa-cmds _la-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 706 'observer 101.0 100.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units (list (mk-u 810 'lurker-burrowed 111.0 100.0)
                       (mk-u 811 'queen 107.0 100.0)) ;; AA within 13t!
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-true "l86e-3c-burrowed-lurker-with-aa-stays-behind-and-ge-9.5t-clear"
            (and (= (length lurk-aa-cmds) 1)
                 (< (third (first lurk-aa-cmds)) 99.0)
                 (>= (dist2d (third (first lurk-aa-cmds)) (fourth (first lurk-aa-cmds)) 107.0 100.0) 9.5)))

;; 3c. Unmorph distant sieged Observer & Overseer (> 12t behind army centroid)
(define-values (obs-unmorph-cmds obs-unmorph-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 710 'observer-siege-mode 40.0 40.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-equal "l86-3c-unmorph-distant-sieged-observer"
             obs-unmorph-cmds '((cast-spell 710 morph-observer-mode)))
(check-true  "l86-3c-unmorph-observer-claimed" (set-member? obs-unmorph-ids 710))

(define-values (ovs-unmorph-cmds ovs-unmorph-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 711 'overseer-siege-mode 40.0 40.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-equal "l86-3c-unmorph-distant-sieged-overseer"
             ovs-unmorph-cmds '((cast-spell 711 morph-overseer-mode)))
(check-true  "l86-3c-unmorph-overseer-claimed" (set-member? ovs-unmorph-ids 711))

;; 3d. Safe AA (>= 9.5t) and Widow Mine (>= 6.8t, <= 11.0t sight) standoff positioning!
(define-values (aa-cmds _aa-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 720 'raven 101.0 100.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings (list (mk-u 801 'missile-turret 105.0 100.0))
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-true "l86-3c-aa-standoff-ge-9.5t"
            (and (= (length aa-cmds) 1)
                 (>= (dist2d (third (first aa-cmds)) (fourth (first aa-cmds)) 105.0 100.0) 9.5)))

(define-values (mine-cmds _mine-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 721 'observer 90.0 100.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units (list (mk-u 802 'widow-mine-burrowed 105.0 100.0))
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-true "l86-3c-mine-standoff-safe-and-revealing"
            (and (= (length mine-cmds) 1)
                 (let ([dm (dist2d (third (first mine-cmds)) (fourth (first mine-cmds)) 105.0 100.0)])
                   (and (>= dm 6.8) (<= dm 11.0)))))

;; 3e. Active home stealth split: 1 detector stays home; 2 detectors -> closest stays home, #2 escorts army!
(define-values (hs1-cmds hs1-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 730 'observer 35.0 35.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)
   #:active-home-stealth? #t))
(check-equal "l86-3c-home-stealth-sole-detector-stays-home" hs1-cmds '())
(check-true  "l86-3c-home-stealth-sole-detector-unclaimed" (set-empty? hs1-ids))

(define-values (hs2-cmds hs2-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 730 'observer 35.0 35.0 #:flying? #t)
                     (mk-u 731 'observer 75.0 75.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)
   #:active-home-stealth? #t))
(check-true "l86-3c-home-stealth-2det-sends-second-to-army"
            (and (= (length hs2-cmds) 1)
                 (= (second (first hs2-cmds)) 731)
                 (set-member? hs2-ids 731)
                 (not (set-member? hs2-ids 730))))

;; 3f. Deadband (<= 2.2t of rear -2.0t target and safe -> 0 move spam, STILL claimed!) + escort-required?=#f guard
(define-values (db-cmds db-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 740 'observer 98.5 100.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:attack-target-xy (cons 140.0 100.0)))
(check-equal "l86-3c-deadband-no-move-spam" db-cmds '())
(check-true  "l86-3c-deadband-still-claimed" (set-member? db-ids 740))

(define-values (off-cmds off-ids)
  (plan-mobile-detector-army-escort
   #:detectors (list (mk-u 740 'observer 60.0 60.0 #:flying? #t))
   #:combat-units army-fwd
   #:enemy-units '()
   #:enemy-buildings '()
   #:own-townhall-pts own-ths
   #:escort-required? #f))
(check-equal "l86-3c-escort-not-required-no-cmds" off-cmds '())
(check-true  "l86-3c-escort-not-required-no-claims" (set-empty? off-ids))

(printf "\n=============================================================================\n")
(printf "l86-target-choke-escort-test: ~a PASSED, ~a FAILED\n" pass-count fail-count)
(printf "=============================================================================\n")
(when (> fail-count 0) (exit 1))
