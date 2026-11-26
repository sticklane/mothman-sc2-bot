#lang racket/base

;; =============================================================================
;; Loop 86 Track 1 Unit Test Suite (`tests/l86-anti-turtle-belief-test.rkt`)
;;
;; Verifies 100% general SC2 anti-greed / anti-turtle belief mechanics:
;;   1. `lib/opponent-world-model.rkt`:
;;      - Full expansion-ring pad ingestion, deduplication, own-base exclusion,
;;        visit rotation (ally units + scanner sweep), staleness re-surfacing
;;      - Enemy 5th/6th+ TownHall detection on ring pads -> confirmed-bases,
;;        fog persistence in `owm-confirmed-enemy-base-pts`, clean clearing
;;      - `owm-enemy-turtle-breakdown` across PF/Bunker/Battery/Cannon/Spine/
;;        Turret/Spore/Mine/Tank/Lurker/Liberator/Tempest/SwarmHost + 35-field ABI
;;   2. `lib/sc2-bayesian.rkt`:
;;      - `compute-bayesian-enemy-turtle-posterior` calibration + rush immunity
;;      - Pure untouched `compute-bayesian-pad-camped-posterior`
;;      - `evaluate-strategic-posteriors-from-signals` optional kwargs raising
;;        `hidden-expand-posterior` on enemy base lead & stale unvisited outer rings
;;   3. `lib/mirror-mind-predictor.rkt`:
;;      - Expanded `opponent-turtling?` unit/structure set
;;      - `compute-calibrated-win-prob` economic base-deficit & high-hexp damper
;; =============================================================================

(require racket/list
         racket/math
         "../lib/sc2-bayesian.rkt"
         "../lib/opponent-world-model.rkt"
         (only-in "../lib/mirror-mind-predictor.rkt"
                  make-mirror-mind-state
                  compute-opponent-shadow-ledger
                  interpret-opponent-actions
                  step-mirror-mind-predictor!
                  mirror-mind-state-signals-ht
                  mirror-mind-state-last-shadow-ledger
                  mirror-mind-state-seen-enemy-bldg-costs
                  shadow-ledger-expected-gas
                  shadow-ledger-predicted-enemy-bases
                  action-lens-reading-opponent-turtling?
                  compute-calibrated-win-prob
                  compute-calibrated-snowball-adv))

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (pt-near? p x y [tol 1.0])
  (and (pair? p)
       (<= (+ (expt (- (car p) x) 2) (expt (- (cdr p) y) 2)) (* tol tol))))

(define (mk-ring-obs frame erace ally-units enemy-bldgs
                     #:enemy-units [enemy-units '()]
                     #:expansion-pads [exp-pads '()]
                     #:effects [effects '()])
  (hasheq 'frame frame
          'enemy-race erace
          'base-x 32.0 'base-y 32.0
          'natural-x 50.0 'natural-y 42.0
          'enemy-x 160.0 'enemy-y 160.0
          'enemy-exp-x 142.0 'enemy-exp-y 150.0
          'enemy-third-x 125.0 'enemy-third-y 155.0
          'enemy-fourth-x 155.0 'enemy-fourth-y 120.0
          'ally-units ally-units
          'enemy-units enemy-units
          'enemy-buildings enemy-bldgs
          'expansion-pads exp-pads
          'effects effects))

;; =============================================================================
;; PART 1: OWM Expansion-Ring Tracker, Enemy Base Pts & Turtle Breakdown
;; =============================================================================

;; 12 unique pads across a 200x200 map (+ 1 near-duplicate within 3t to test dedup!)
(define MAP-12-PADS
  (list (cons 32.0 32.0)                  ; P1: our main
        (cons 50.0 42.0)                  ; P2: our natural
        (cons 68.0 30.0)                  ; P3: our 3rd
        (cons 35.0 75.0)                  ; P4: our 4th
        (cons 85.0 55.0)                  ; P5: mid-low
        (cons 110.0 85.0)                 ; P6: mid-center
        (cons 145.0 90.0)                 ; P7: enemy 6th (outer east)
        (cons 95.0 140.0)                 ; P8: enemy 5th (outer north)
        (hasheq 'x 155.0 'y 120.0)        ; P9: enemy 4th (hash format test)
        (cons 125.0 155.0)                ; P10: enemy 3rd
        (cons 142.0 150.0)                ; P11: enemy natural
        (cons 160.0 160.0)                ; P12: enemy main
        (cons 143.0 151.0)))              ; near-duplicate of P11 (< 8t) -> must dedup!

;; T1.1 & T1.2: Ingestion, deduplication, own-base exclusion, visit rotation & scanner sweep
(let* ([owm (make-opponent-world-model 'Terran)]
       [own-bases (list (cons 32.0 32.0) (cons 50.0 42.0) (cons 68.0 30.0))]
       [s1 (step-opponent-world-model!
            owm
            (mk-ring-obs 7400 'Terran
                         (list (hasheq 'id 1 'type 'probe 'x 32.0 'y 32.0))
                         '()
                         #:expansion-pads MAP-12-PADS))]
       ;; 12 unique pads minus 3 own-base pads (<16t) = 9 stale pads!
       [stale-cnt-0 (owm-stale-ring-pad-count owm 7400 #:own-base-pts own-bases #:min-stale-frames 1344)]
       [stale-cnt-s (owm-stale-ring-pad-count s1 7400 #:own-base-pts own-bases #:min-stale-frames 1344)]
       ;; Closest tie-breaker to enemy main (160,160) among unvisited (-9999) is (160,160)
       [p-first (owm-next-stale-ring-pad owm 7400 #:own-base-pts own-bases #:min-stale-frames 1344)]
       ;; Visit (160,160) with an observer & (142,150) with a scanner sweep!
       [_ (step-opponent-world-model!
           owm
           (mk-ring-obs 7450 'Terran
                        (list (hasheq 'id 2 'type 'observer 'x 158.0 'y 158.0))
                        '()
                        #:effects (list (hasheq 'type 'scanner-sweep 'x 142.0 'y 150.0))))]
       [stale-cnt-1 (owm-stale-ring-pad-count owm 7450 #:own-base-pts own-bases #:min-stale-frames 1344)]
       ;; Next stalest closest to enemy main should rotate to enemy 3rd (125,155) (d=35.4t vs 40.3t for 4th)!
       [p-second (owm-next-stale-ring-pad owm 7450 #:own-base-pts own-bases #:min-stale-frames 1344)]
       ;; Visit ALL remaining 7 pads at frame 7500 -> stale count becomes 0, next pad becomes #f!
       [all-vis-allies
        (for/list ([pt (in-list (list (cons 125.0 155.0) (cons 155.0 120.0) (cons 95.0 140.0)
                                      (cons 145.0 90.0) (cons 110.0 85.0) (cons 85.0 55.0)
                                      (cons 35.0 75.0)))]
                   [idx (in-naturals 20)])
          (hasheq 'id idx 'type 'zergling 'x (car pt) 'y (cdr pt)))]
       [_ (step-opponent-world-model! owm (mk-ring-obs 7500 'Terran all-vis-allies '()))]
       [stale-cnt-all-fresh (owm-stale-ring-pad-count owm 7500 #:own-base-pts own-bases #:min-stale-frames 1344)]
       [p-none (owm-next-stale-ring-pad owm 7500 #:own-base-pts own-bases #:min-stale-frames 1344)]
       ;; Advance past 1344f from 7450 -> (160,160) & (142,150) become stale first (7450 vs 7500)!
       [p-resurface (owm-next-stale-ring-pad owm 8800 #:own-base-pts own-bases #:min-stale-frames 1344)])
  (check! (and (= stale-cnt-0 9) (= stale-cnt-s 9))
          (format "T1.1a: 12 unique pads minus 3 own bases must yield 9 stale pads (deduped), got owm=~a sum=~a"
                  stale-cnt-0 stale-cnt-s))
  (check! (pt-near? p-first 160.0 160.0)
          (format "T1.1b: First stale ring pad tie-breaks closest to enemy main (160,160), got ~a" p-first))
  (check! (and (= stale-cnt-1 7) (pt-near? p-second 125.0 155.0))
          (format "T1.2a: Visiting main+nat (observer+scan) drops stale to 7 and rotates to (125,155), got cnt=~a next=~a"
                  stale-cnt-1 p-second))
  (check! (and (= stale-cnt-all-fresh 0) (not p-none))
          (format "T1.2b: Visiting all non-own pads yields 0 stale & #f next pad, got cnt=~a next=~a"
                  stale-cnt-all-fresh p-none))
  (check! (pt-near? p-resurface 160.0 160.0)
          (format "T1.2c: Oldest visited pad (7450f) resurfaces once >= 1344f elapses (8800f), got ~a" p-resurface)))

;; T1.3: Detecting enemy 5th & 6th TownHalls on outer ring pads increments confirmed-bases,
;;       persists across fog in `owm-confirmed-enemy-base-pts`, and prunes when cleared!
(let* ([owm (make-opponent-world-model 'Terran)]
       ;; Observe enemy 2nd, 3rd, 4th, 5th (tagged), and 6th (untagged!) CCs across ring pads
       [s-seen (step-opponent-world-model!
                owm
                (mk-ring-obs
                 9500 'Terran
                 (list (hasheq 'id 30 'type 'observer 'x 145.0 'y 90.0)
                       (hasheq 'id 31 'type 'observer 'x 95.0 'y 140.0))
                 (list (hasheq 'id 501 'type 'orbital-command 'x 142.0 'y 150.0 'build-progress 1.0)
                       (hasheq 'id 502 'type 'planetary-fortress 'x 125.0 'y 155.0 'build-progress 1.0)
                       (hasheq 'id 503 'type 'command-center 'x 155.0 'y 120.0 'build-progress 1.0)
                       (hasheq 'id 504 'type 'command-center 'x 95.0 'y 140.0 'build-progress 1.0)
                       (hasheq 'id 0   'type 'command-center 'x 145.0 'y 90.0 'build-progress 1.0))
                 #:expansion-pads MAP-12-PADS))]
       ;; Fog step: all observers leave -> all 6 confirmed bases MUST persist across fog!
       [s-fog (step-opponent-world-model! owm (mk-ring-obs 10200 'Terran '() '()))]
       [pts-fog (owm-confirmed-enemy-base-pts owm)]
       [pts-fog-sum (owm-confirmed-enemy-base-pts s-fog)]
       ;; Ally visits 6th pad (145,90) and sees 0 enemy TH there -> pruned cleanly!
       [s-cleared (step-opponent-world-model!
                   owm
                   (mk-ring-obs 10800 'Terran
                                (list (hasheq 'id 32 'type 'stalker 'x 145.0 'y 90.0))
                                '()))]
       [pts-cleared (owm-confirmed-enemy-base-pts owm)])
  (check! (and (= (opponent-world-summary-confirmed-bases s-seen) 6)
               (= (opponent-world-summary-confirmed-bases s-fog) 6)
               (= (length pts-fog) 6)
               (= (length pts-fog-sum) 6))
          (format "T1.3a: Enemy 1st..6th THs on ring pads must yield confirmed-bases=6 across fog, got seen=~a fog=~a pts=~a/~a"
                  (opponent-world-summary-confirmed-bases s-seen)
                  (opponent-world-summary-confirmed-bases s-fog)
                  (length pts-fog) (length pts-fog-sum)))
  (check! (and (= (length pts-cleared) 5)
               (not (for/or ([pt (in-list pts-cleared)]) (pt-near? pt 145.0 90.0 8.0))))
          (format "T1.3b: Visiting cleared 6th pad (145,90) with 0 enemy TH must prune it (6 -> 5), got ~a"
                  (length pts-cleared))))

;; T1.4: `owm-enemy-turtle-breakdown` counts PF/static-ground/AA/burrow-mine/siege-zone across fog,
;;       preserves 35-field `opponent-world-summary` ABI, safe `#f` defaults & clean reset!
(let* ([owm (make-opponent-world-model 'Terran)]
       [s1 (step-opponent-world-model!
            owm
            (mk-ring-obs
             9000 'Terran
             (list (hasheq 'id 40 'type 'observer 'x 125.0 'y 155.0))
             (list (hasheq 'id 601 'type 'bunker 'x 130.0 'y 150.0 'build-progress 1.0)
                   (hasheq 'id 602 'type 'bunker 'x 128.0 'y 152.0 'build-progress 1.0)
                   (hasheq 'id 603 'type 'shield-battery 'x 126.0 'y 152.0 'build-progress 1.0)
                   (hasheq 'id 604 'type 'planetary-fortress 'x 125.0 'y 155.0 'build-progress 1.0)
                   (hasheq 'id 605 'type 'missile-turret 'x 124.0 'y 156.0 'build-progress 1.0)
                   (hasheq 'id 606 'type 'missile-turret 'x 122.0 'y 156.0 'build-progress 1.0)
                   (hasheq 'id 607 'type 'missile-turret 'x 120.0 'y 156.0 'build-progress 1.0)
                   (hasheq 'id 608 'type 'spore-crawler 'x 118.0 'y 156.0 'build-progress 1.0))
             #:enemy-units
             (list (hasheq 'id 701 'type 'widow-mine-burrowed 'x 129.0 'y 149.0 'hp 90)
                   (hasheq 'id 702 'type 'widow-mine 'x 127.0 'y 149.0 'hp 90)
                   (hasheq 'id 703 'type 'lurker-burrowed 'x 125.0 'y 149.0 'hp 200)
                   (hasheq 'id 704 'type 'siege-tank-sieged 'x 123.0 'y 152.0 'hp 175)
                   (hasheq 'id 705 'type 'liberator-ag 'x 121.0 'y 152.0 'hp 180)
                   (hasheq 'id 706 'type 'tempest 'x 119.0 'y 152.0 'hp 300))))]
       ;; Next tick in fog: breakdown persists!
       [s2 (step-opponent-world-model! owm (mk-ring-obs 9200 'Terran '() '()))]
       [bd (owm-enemy-turtle-breakdown s2)]
       [_ (reset-opponent-world-model! owm 'Unknown)]
       [bd-reset (owm-enemy-turtle-breakdown owm)])
  (check! (and (= (hash-ref bd 'static-ground-count) 3)
               (= (hash-ref bd 'pf-count) 1)
               (= (hash-ref bd 'static-aa-count) 4)
               (= (hash-ref bd 'burrow-mine-count) 3)
               (= (hash-ref bd 'siege-zone-count) 6))
          (format "T1.4a: Turtle breakdown across fog must be sg=3 pf=1 aa=4 bm=3 sz=6, got ~a" bd))
  (check! (= (sub1 (vector-length (struct->vector s1))) 35)
          "T1.4b: opponent-world-summary ABI strictly preserved at 35 fields")
  (check! (and (= (hash-ref bd-reset 'static-ground-count) 0)
               (= (hash-ref bd-reset 'siege-zone-count) 0)
               (null? (owm-confirmed-enemy-base-pts owm))
               (not (owm-next-stale-ring-pad owm 9500))
               (= (owm-stale-ring-pad-count #f 9500) 0)
               (null? (owm-confirmed-enemy-base-pts #f))
               (= (hash-ref (owm-enemy-turtle-breakdown #f) 'pf-count) 0))
          "T1.4c: Reset & #f inputs cleanly zero all Loop 86 OWM accessors without throwing"))

;; T1.5 (L86B): Remembered `command-center` morphing in-place into `planetary-fortress` (symbol
;;              OR integer unit-type-id `130`), AND a floated CC sight-cleared in enemy main that
;;              re-lands at pad #3 as a PF, MUST increment `pf-count` on the VERY frame seen!
(let* ([owm (make-opponent-world-model 'Terran)]
       ;; Frame 6000: Observe 3 regular Command Centers (two on expansions + one building in main)
       [s-cc (step-opponent-world-model!
              owm
              (mk-ring-obs
               6000 'Terran
               (list (hasheq 'id 50 'type 'observer 'x 156.0 'y 156.0))
               (list (hasheq 'id 801 'type 'command-center 'x 125.0 'y 155.0 'build-progress 1.0)
                     (hasheq 'id 802 'type 'command-center 'x 155.0 'y 120.0 'build-progress 1.0)
                     (hasheq 'id 803 'type 'command-center 'x 152.0 'y 156.0 'build-progress 1.0))))]
       [pf-before (hash-ref (owm-enemy-turtle-breakdown s-cc) 'pf-count)]
       ;; Frame 6500: CC #803 lifted off in fog; our observer flies right over (152,156) and sees 0 CC there!
       [_ (step-opponent-world-model!
           owm
           (mk-ring-obs 6500 'Terran
                        (list (hasheq 'id 50 'type 'observer 'x 152.0 'y 156.0))
                        '()))]
       ;; Frame 7200: CC #801 morphs in-place ('planetary-fortress), CC #802 morphs (numeric id 130),
       ;;             AND floated CC #803 re-lands at (95,140) as 'planetary-fortress!
       [s-pf (step-opponent-world-model!
              owm
              (mk-ring-obs
               7200 'Terran
               (list (hasheq 'id 50 'type 'observer 'x 125.0 'y 155.0))
               (list (hasheq 'id 801 'type 'planetary-fortress 'x 125.0 'y 155.0 'build-progress 1.0)
                     (hasheq 'id 802 'unit-type 130 'x 155.0 'y 120.0 'build-progress 1.0)
                     (hasheq 'id 803 'type 'planetary-fortress 'x 95.0 'y 140.0 'build-progress 1.0))))]
       [pf-after (hash-ref (owm-enemy-turtle-breakdown s-pf) 'pf-count)]
       [p-pf-turtle (compute-bayesian-enemy-turtle-posterior
                     #:pf-count pf-after #:frame 7200)])
  (check! (and (= pf-before 0) (= pf-after 3) (>= p-pf-turtle 0.75))
          (format "T1.5: CC->PF in-place morph + id 130 + floated CC re-landing must yield pf-count 0->3 & turtle>=0.75, got ~a->~a p=~a"
                  pf-before pf-after p-pf-turtle)))

;; T1.6 (L86C): Mobile unsieged `siege-tank`, un-deployed `liberator`, and unburrowed `lurker`
;;              MUST NOT inflate `siege-zone-count` (0), while deployed `siege-tank-sieged`,
;;              `liberator-ag`, `lurker-burrowed`, `widow-mine`, `tempest`, & `swarm-host` DO count!
(let* ([owm (make-opponent-world-model 'Terran)]
       [s-mobile (step-opponent-world-model!
                  owm
                  (mk-ring-obs
                   8500 'Terran
                   (list (hasheq 'id 60 'type 'observer 'x 130.0 'y 150.0))
                   '()
                   #:enemy-units
                   (list (hasheq 'id 901 'type 'siege-tank 'x 130.0 'y 150.0 'hp 175)
                         (hasheq 'id 902 'type 'siege-tank 'x 131.0 'y 150.0 'hp 175)
                         (hasheq 'id 903 'type 'siege-tank 'x 132.0 'y 150.0 'hp 175)
                         (hasheq 'id 904 'type 'siege-tank 'x 133.0 'y 150.0 'hp 175)
                         (hasheq 'id 905 'type 'liberator 'x 134.0 'y 150.0 'hp 180)
                         (hasheq 'id 906 'type 'lurker 'x 135.0 'y 150.0 'hp 200))))]
       [sz-mobile (hash-ref (owm-enemy-turtle-breakdown s-mobile) 'siege-zone-count)]
       ;; Now 2 tanks siege up, liberator deploys, lurker burrows, plus 1 widow-mine + 1 tempest!
       [s-sieged (step-opponent-world-model!
                  owm
                  (mk-ring-obs
                   8600 'Terran
                   (list (hasheq 'id 60 'type 'observer 'x 130.0 'y 150.0))
                   '()
                   #:enemy-units
                   (list (hasheq 'id 901 'type 'siege-tank-sieged 'x 130.0 'y 150.0 'hp 175)
                         (hasheq 'id 902 'type 'siege-tank-sieged 'x 131.0 'y 150.0 'hp 175)
                         (hasheq 'id 903 'type 'siege-tank 'x 132.0 'y 150.0 'hp 175)
                         (hasheq 'id 904 'type 'siege-tank 'x 133.0 'y 150.0 'hp 175)
                         (hasheq 'id 905 'type 'liberator-ag 'x 134.0 'y 150.0 'hp 180)
                         (hasheq 'id 906 'type 'lurker-burrowed 'x 135.0 'y 150.0 'hp 200)
                         (hasheq 'id 907 'type 'widow-mine 'x 136.0 'y 150.0 'hp 90)
                         (hasheq 'id 908 'type 'tempest 'x 137.0 'y 150.0 'hp 300))))]
       [sz-sieged (hash-ref (owm-enemy-turtle-breakdown s-sieged) 'siege-zone-count)]
       ;; Fog persistence + unsiege drop check: 901 unsieges back to mobile -> 6 -> 5!
       [s-unsiege (step-opponent-world-model!
                   owm
                   (mk-ring-obs
                    8700 'Terran
                    (list (hasheq 'id 60 'type 'observer 'x 130.0 'y 150.0))
                    '()
                    #:enemy-units
                    (list (hasheq 'id 901 'type 'siege-tank 'x 130.0 'y 150.0 'hp 175))))]
       [sz-unsiege (hash-ref (owm-enemy-turtle-breakdown s-unsiege) 'siege-zone-count)])
  (check! (and (= sz-mobile 0) (= sz-sieged 6) (= sz-unsiege 5))
          (format "T1.6: Mobile unsieged units must yield siege-zone=0, deployed=6, after 1 unsiege=5, got ~a/~a/~a"
                  sz-mobile sz-sieged sz-unsiege)))

;; =============================================================================
;; PART 2: `compute-bayesian-enemy-turtle-posterior` & Pure Pad-Camped Posterior
;; =============================================================================

(let ([p-2static (compute-bayesian-enemy-turtle-posterior #:static-ground-count 2 #:frame 8500)]
      [p-3static-4b (compute-bayesian-enemy-turtle-posterior #:static-ground-count 3 #:enemy-bases 4 #:frame 9000)]
      [p-2static-4sz (compute-bayesian-enemy-turtle-posterior #:static-ground-count 2 #:siege-zone-count 4 #:frame 8500)]
      [p-1pf     (compute-bayesian-enemy-turtle-posterior #:pf-count 1 #:frame 8500)]
      [p-2pf     (compute-bayesian-enemy-turtle-posterior #:pf-count 2 #:frame 8500)]
      [p-4static (compute-bayesian-enemy-turtle-posterior #:static-ground-count 4 #:frame 8500)]
      [p-6static (compute-bayesian-enemy-turtle-posterior #:static-ground-count 6 #:frame 8500)]
      [p-4aa     (compute-bayesian-enemy-turtle-posterior #:static-aa-count 4 #:frame 9000)]
      [p-6aa     (compute-bayesian-enemy-turtle-posterior #:static-aa-count 6 #:frame 9000)]
      [p-4siege-alone (compute-bayesian-enemy-turtle-posterior #:siege-zone-count 4 #:enemy-bases 3 #:frame 8500)]
      [p-6siege  (compute-bayesian-enemy-turtle-posterior #:siege-zone-count 6 #:frame 8500)]
      [p-4mines  (compute-bayesian-enemy-turtle-posterior #:burrow-mine-count 4 #:siege-zone-count 4 #:frame 8500)]
      [p-8siege  (compute-bayesian-enemy-turtle-posterior #:siege-zone-count 8 #:frame 9500)]
      [p-clean   (compute-bayesian-enemy-turtle-posterior #:frame 8500)]
      [p-rush    (compute-bayesian-enemy-turtle-posterior #:rush-posterior 0.85 #:frame 3000)]
      ;; L86B: < 5:00 (`6720f`) defensive Spines/Bunkers/PF MUST NOT fire turtle macro!
      [p-early-spines (compute-bayesian-enemy-turtle-posterior #:static-ground-count 4 #:frame 3720)]
      [p-early-pf     (compute-bayesian-enemy-turtle-posterior #:pf-count 1 #:frame 6000)]
      [p-at-5min      (compute-bayesian-enemy-turtle-posterior #:static-ground-count 4 #:frame 6720)]
      ;; Verify `compute-bayesian-pad-camped-posterior` stays 100% pure!
      [p-own-nat-clear
       (compute-bayesian-pad-camped-posterior
        #:camp-building-observed? #f #:enemy-combat-count 0
        #:ally-defender-count 2 #:total-ally-combat-count 6 #:live-obs? #t)]
      [p-own-nat-camped
       (compute-bayesian-pad-camped-posterior
        #:camp-building-observed? #t #:enemy-combat-count 0
        #:ally-defender-count 0 #:total-ally-combat-count 4 #:live-obs? #t)])
  (check! (and (< p-2static 0.25) (< p-3static-4b 0.25) (>= p-2static-4sz 0.45))
          (format "T2.1a: 2-3 static-ground alone must stay < 0.25 (even 4b), while 2 static + 4 siege fires >= 0.45, got 2s=~a 3s4b=~a 2s4sz=~a"
                  p-2static p-3static-4b p-2static-4sz))
  (check! (and (>= p-1pf 0.45) (>= p-2pf 0.77))
          (format "T2.1b: >=1 Planetary Fortress >= 0.45 and >=2 PF >= 0.77, got ~a / ~a" p-1pf p-2pf))
  (check! (and (>= p-4static 0.45) (>= p-6static 0.77))
          (format "T2.1c: >=4 static-ground >= 0.45 and >=6 static-ground >= 0.77, got ~a / ~a" p-4static p-6static))
  (check! (and (>= p-4aa 0.36) (>= p-6aa 0.48))
          (format "T2.1d: 4 AA static >= 0.36 and 6 AA static >= 0.48, got ~a / ~a" p-4aa p-6aa))
  (check! (and (< p-4siege-alone 0.25) (>= p-6siege 0.46) (>= p-4mines 0.70) (>= p-8siege 0.80))
          (format "T2.1e: 4 siege alone < 0.25, 6 siege >= 0.46, 4 mines >= 0.70, 8 siege >= 0.80, got 4sz=~a 6sz=~a 4m=~a 8sz=~a"
                  p-4siege-alone p-6siege p-4mines p-8siege))
  (check! (and (<= p-clean 0.05) (<= p-rush 0.05)
               (<= p-early-spines 0.06) (<= p-early-pf 0.06)
               (>= p-at-5min 0.45))
          (format "T2.2: Non-turtle/rush & <5:00 (<6720f) early static must stay <= 0.06 while >=6720f fires >=0.45, got clean=~a rush=~a earlyS=~a earlyPF=~a at5m=~a"
                  p-clean p-rush p-early-spines p-early-pf p-at-5min))
  (check! (and (<= p-own-nat-clear 0.05) (>= p-own-nat-camped 0.75))
          (format "T2.3: compute-bayesian-pad-camped-posterior stays 100% pure (clear<=0.05, camp>=0.75), got ~a / ~a"
                  p-own-nat-clear p-own-nat-camped)))

;; =============================================================================
;; PART 3: `evaluate-strategic-posteriors-from-signals` Hidden-Expand Extensions
;; =============================================================================

(let ([s-legacy
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 9408 #:combat-count 2
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 2
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq))]
      [s-lead-4v2
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 9408 #:combat-count 2
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 4
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:confirmed-enemy-bases 4 #:own-bases 2)]
      [s-lead-6v3
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 11000 #:combat-count 4
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 6
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:confirmed-enemy-bases 6 #:own-bases 3)]
      ;; L86B: At 6:00-7:00 (`8064..9408f`) vs a 2-base opponent, unvisited outer pads MUST NOT
      ;;       false-trigger high `hexp`!
      [s-early-stale-no-fp
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 9408 #:combat-count 2
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 2
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:confirmed-enemy-bases 2 #:own-bases 2 #:stale-ring-pads 10)]
      ;; L86B: At 8:30+ (`>= 11424f`), conf-eb <= 2, stale-pads >= 6, rem-min >= 400, combat <= 4
      ;;       applies mild 1.8x ambiguity lift cleanly!
      [s-late-stale-mild
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 11424 #:combat-count 4
        #:unaccounted-minerals 420.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 2
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:confirmed-enemy-bases 2 #:own-bases 2 #:stale-ring-pads 6)]
      [s-late-stale-low-combat
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 11424 #:combat-count 2
        #:unaccounted-minerals 420.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 2
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #f
        #:branch-posteriors (hasheq)
        #:confirmed-enemy-bases 2 #:own-bases 2 #:stale-ring-pads 6)]
      [s-rush-guarded
       (evaluate-strategic-posteriors-from-signals
        #:bluff-prior 0.08 #:bluff-posterior 0.08 #:frame 9408 #:combat-count 2
        #:unaccounted-minerals 100.0 #:unaccounted-gas 50.0
        #:dark-matter-hypothesis 'accounted-visible-macro #:predicted-enemy-bases 1
        #:feint-or-poke-detected? #f #:proxy-or-rush-detected? #t
        #:branch-posteriors (hasheq)
        #:confirmed-enemy-bases 4 #:own-bases 2 #:stale-ring-pads 5)])
  (check! (< (abs (- (bayesian-strategic-priors-hidden-expand-posterior s-legacy) 0.14)) 0.01)
          (format "T3.1a: Legacy call without L86 kwargs preserves baseline hexp=0.14, got ~a"
                  (bayesian-strategic-priors-hidden-expand-posterior s-legacy)))
  (check! (and (>= (bayesian-strategic-priors-hidden-expand-posterior s-lead-4v2) 0.70)
               (>= (bayesian-strategic-priors-hidden-expand-posterior s-lead-6v3) 0.70))
          (format "T3.1b: Confirmed base leads (4v2, 6v3) must raise hexp >= 0.70, got 4v2=~a 6v3=~a"
                  (bayesian-strategic-priors-hidden-expand-posterior s-lead-4v2)
                  (bayesian-strategic-priors-hidden-expand-posterior s-lead-6v3)))
  (check! (and (< (abs (- (bayesian-strategic-priors-hidden-expand-posterior s-early-stale-no-fp) 0.14)) 0.01)
               (>= (bayesian-strategic-priors-hidden-expand-posterior s-late-stale-mild) 0.21)
               (<= (bayesian-strategic-priors-hidden-expand-posterior s-late-stale-mild) 0.30)
               (>= (bayesian-strategic-priors-hidden-expand-posterior s-late-stale-low-combat) 0.49))
          (format "T3.2a: Early 6:00-7:00 stale pads stay 0.14 (zero FP); 8:30+ >=6 stale + >=400M lifts mildly (0.22/0.51), got early=~a mild=~a lowc=~a"
                  (bayesian-strategic-priors-hidden-expand-posterior s-early-stale-no-fp)
                  (bayesian-strategic-priors-hidden-expand-posterior s-late-stale-mild)
                  (bayesian-strategic-priors-hidden-expand-posterior s-late-stale-low-combat)))
  (check! (< (bayesian-strategic-priors-hidden-expand-posterior s-rush-guarded) 0.10)
          (format "T3.2b: Active rush posterior suppresses hidden-expand inflation (<0.10), got ~a"
                  (bayesian-strategic-priors-hidden-expand-posterior s-rush-guarded))))

;; =============================================================================
;; PART 4: Mirror-Mind `opponent-turtling?` Expansion & `win-prob` Base Damper
;; =============================================================================

;; T4.1: `opponent-turtling?` catches burrowed mines, liberators, lurkers, shield batteries, & PFs
(let ()
  (define (turtling-for-case erace units bldgs)
    (define mm (make-mirror-mind-state #:our-race 'Protoss #:enemy-race erace))
    (define ledger (compute-opponent-shadow-ledger mm 9000 units bldgs #:base-x 32 #:base-y 32 #:nat-x 50 #:nat-y 42))
    (define reading (interpret-opponent-actions mm 9000 units bldgs ledger #:base-x 32 #:base-y 32 #:nat-x 50 #:nat-y 42))
    (action-lens-reading-opponent-turtling? reading))
  (check! (and (turtling-for-case 'Terran (list (hasheq 'id 1 'type 'widow-mine-burrowed 'x 130 'y 150 'hp 90)) '())
               (turtling-for-case 'Terran (list (hasheq 'id 2 'type 'liberator-ag 'x 130 'y 150 'hp 180)) '())
               (turtling-for-case 'Zerg (list (hasheq 'id 3 'type 'lurker-burrowed 'x 130 'y 150 'hp 200)) '())
               (turtling-for-case 'Protoss '() (list (hasheq 'id 4 'type 'shield-battery 'x 140 'y 150 'hp 150)))
               (turtling-for-case 'Terran '() (list (hasheq 'id 5 'type 'planetary-fortress 'x 125 'y 155 'hp 1500))))
          "T4.1: Mirror-Mind opponent-turtling? must fire on widow-mine-burrowed, liberator-ag, lurker-burrowed, shield-battery, & planetary-fortress"))

;; T4.2: `compute-calibrated-win-prob` & `step-mirror-mind-predictor!` temper `win-prob`
;;       when trailing by >= 2 bases (and/or high unscouted hexp), while leaving equal bases untouched!
(let* ([wp-equal-3v3
        (compute-calibrated-win-prob
         (hasheq 'frame 12000 'own-bases 3 'enemy-confirmed-bases 3)
         #:our-workers 75 #:enemy-workers 50
         #:our-army-supply 60 #:enemy-army-supply 50
         #:our-lost-value 500 #:enemy-lost-value 2000)]
       [wp-down-3v5-cap
        (compute-calibrated-win-prob
         (hasheq 'frame 12000 'own-bases 3 'enemy-confirmed-bases 5)
         #:our-workers 75 #:enemy-workers 50
         #:our-army-supply 60 #:enemy-army-supply 50
         #:our-lost-value 500 #:enemy-lost-value 2000)]
       [wp-down-3v6-even-army
        (compute-calibrated-win-prob
         (hasheq 'frame 12000 'own-bases 3 'enemy-confirmed-bases 6)
         #:our-workers 75 #:enemy-workers 50
         #:our-army-supply 60 #:enemy-army-supply 50
         #:our-lost-value 500 #:enemy-lost-value 2000)]
       [wp-down-3v8-fog-hexp
        (compute-calibrated-win-prob
         (hasheq 'frame 14000 'own-bases 3 'enemy-confirmed-bases 8 'hidden-expand-posterior 0.72)
         #:our-workers 66 #:enemy-workers 60
         #:our-army-supply 70 #:enemy-army-supply 0)]
       [sb-down-3v8-fog-hexp
        (compute-calibrated-snowball-adv
         (hasheq 'frame 14000 'own-bases 3 'enemy-confirmed-bases 8 'hidden-expand-posterior 0.72)
         #:our-workers 66 #:enemy-workers 60
         #:our-army-supply 70 #:enemy-army-supply 0)]
       ;; Early game (< 6:00) must NOT apply the >= 6:00 base damper
       [wp-early-unaffected
        (compute-calibrated-win-prob
         (hasheq 'frame 5000 'own-bases 2 'enemy-confirmed-bases 4)
         #:our-workers 40 #:enemy-workers 30
         #:our-army-supply 30 #:enemy-army-supply 10)]
       ;; End-to-end `step-mirror-mind-predictor!` signals-ht propagation check
       [mm (make-mirror-mind-state #:our-race 'Protoss #:enemy-race 'Terran)]
       [_ (step-mirror-mind-predictor!
           mm
           (hasheq 'frame 14000 'race 'Protoss 'enemy-race 'Terran
                   'base-x 32 'base-y 32 'natural-x 50 'natural-y 42
                   'enemy-x 160 'enemy-y 160 'enemy-expand-x 142 'enemy-expand-y 150
                   'worker-count 65 'army-supply 70
                   'enemy-confirmed-bases 7 'hidden-expand-posterior 0.75
                   'ally-units '()
                   'ally-buildings (list (hasheq 'id 1 'type 'nexus 'x 32 'y 32)
                                         (hasheq 'id 2 'type 'nexus 'x 50 'y 42)
                                         (hasheq 'id 3 'type 'nexus 'x 68 'y 30))
                   'enemy-units '() 'enemy-buildings '()))]
       [sig-wp (hash-ref (mirror-mind-state-signals-ht mm) 'win-prob 1.0)])
  (check! (and (> wp-equal-3v3 0.80)
               (<= wp-down-3v5-cap 0.72)
               (<= wp-down-3v6-even-army 0.72)
               (< wp-down-3v6-even-army (- wp-equal-3v3 0.15)))
          (format "T4.2a: Trailing 3v5 / 3v6 bases with <=1.25x army must damp & cap win-prob <= 0.72, got 3v3=~a 3v5=~a 3v6=~a"
                  wp-equal-3v3 wp-down-3v5-cap wp-down-3v6-even-army))
  (check! (and (<= wp-down-3v8-fog-hexp 0.66)
               (< sb-down-3v8-fog-hexp 0.50))
          (format "T4.2b: Trailing 3 vs 8 bases with fogged enemy army + hexp=0.72 must damp win-prob <= 0.66 (never 0.97-0.99!), got wp=~a sb=~a"
                  wp-down-3v8-fog-hexp sb-down-3v8-fog-hexp))
  (check! (> wp-early-unaffected 0.85)
          (format "T4.2c: Pre-6:00 (< 8064f) win-prob stays untouched by midgame base damper, got ~a"
                  wp-early-unaffected))
  (check! (<= sig-wp 0.68)
          (format "T4.2d: step-mirror-mind-predictor! signals-ht 'win-prob reflects base-deficit damper (<=0.68), got ~a"
                  sig-wp)))

;; =============================================================================
;; PART 5: Loop 86C Track A — Fog-of-War Enemy Base & Gas Estimation
;; =============================================================================

;; T5.1: `happy-path-expected-bases` scales smoothly to 5th & 6th base across Z/P/T
(check! (and (= (happy-path-expected-bases 'Zerg (exact-round (* 569 22.4))) 4)
             (= (happy-path-expected-bases 'Zerg (exact-round (* 570 22.4))) 5)
             (= (happy-path-expected-bases 'Zerg (exact-round (* 720 22.4))) 6)
             (= (happy-path-expected-bases 'Protoss (exact-round (* 689 22.4))) 4)
             (= (happy-path-expected-bases 'Protoss (exact-round (* 690 22.4))) 5)
             (= (happy-path-expected-bases 'Protoss (exact-round (* 840 22.4))) 6)
             (= (happy-path-expected-bases 'Terran (exact-round (* 719 22.4))) 4)
             (= (happy-path-expected-bases 'Terran (exact-round (* 720 22.4))) 5)
             (= (happy-path-expected-bases 'Terran (exact-round (* 870 22.4))) 6))
        "T5.1: happy-path-expected-bases must lift cleanly to 5th & 6th base at Z/P/T deadlines")

;; T5.2: `stopped-expanding?` past 6:00 (`>= 8064f`) MUST NOT freeze `eff-bases` at 2
;;       when 6 production buildings are visible in main/nat and >= 3 outer ring pads are stale,
;;       while `< 6:00` OR `overdue-pad-confirmed-empty?` STILL sets `stopped-expanding? = #t`!
(let* ([owm (make-opponent-world-model 'Protoss)]
       [six-gates-and-nat
        (list (hasheq 'id 4001 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
              (hasheq 'id 4002 'type 'nexus 'x 142.0 'y 150.0 'build-progress 1.0)
              (hasheq 'id 4003 'type 'gateway 'x 155.0 'y 155.0 'build-progress 1.0)
              (hasheq 'id 4004 'type 'gateway 'x 153.0 'y 155.0 'build-progress 1.0)
              (hasheq 'id 4005 'type 'gateway 'x 151.0 'y 155.0 'build-progress 1.0)
              (hasheq 'id 4006 'type 'gateway 'x 149.0 'y 155.0 'build-progress 1.0)
              (hasheq 'id 4007 'type 'gateway 'x 147.0 'y 155.0 'build-progress 1.0)
              (hasheq 'id 4008 'type 'gateway 'x 145.0 'y 155.0 'build-progress 1.0))]
       ;; At 10:00 (13440f >= 8064f) with 12 map pads (outer pads unscouted!):
       [s-10m (step-opponent-world-model!
               owm
               (mk-ring-obs 13440 'Protoss
                            (list (hasheq 'id 1 'type 'observer 'x 155.0 'y 155.0))
                            six-gates-and-nat
                            #:expansion-pads MAP-12-PADS))]
       ;; Confirm 3rd pad (125,155) genuinely empty -> NOW `stopped-expanding?` MUST be #t!
       [s-3rd-empty (step-opponent-world-model!
                     owm
                     (mk-ring-obs 13500 'Protoss
                                  (list (hasheq 'id 2 'type 'observer 'x 125.0 'y 155.0))
                                  '()))]
       ;; Pre-6:00 (7980f = 356s < 8064f): 6 Gateways on 2 bases -> still `stopped-expanding? = #t`!
       [owm-early (make-opponent-world-model 'Protoss)]
       [s-early (step-opponent-world-model!
                 owm-early
                 (mk-ring-obs 7980 'Protoss
                              (list (hasheq 'id 1 'type 'observer 'x 155.0 'y 155.0))
                              six-gates-and-nat
                              #:expansion-pads MAP-12-PADS))])
  (check! (and (not (opponent-world-summary-stopped-expanding? s-10m))
               (= (opponent-world-summary-confirmed-bases s-10m) 2)
               (= (owm-estimated-enemy-bases s-10m) 4)
               (= (owm-estimated-enemy-bases owm) 2)) ; note: after s-3rd-empty cleared 3rd, owm dropped back to 2!
          (format "T5.2a: At 10:00 with >=3 stale ring pads, 6 Gateways must NOT freeze eff-bases=2 (stop=~a conf=~a est10m=~a estAfterEmpty=~a)"
                  (opponent-world-summary-stopped-expanding? s-10m)
                  (opponent-world-summary-confirmed-bases s-10m)
                  (owm-estimated-enemy-bases s-10m)
                  (owm-estimated-enemy-bases owm)))
  (check! (and (opponent-world-summary-stopped-expanding? s-3rd-empty)
               (opponent-world-summary-stopped-expanding? s-early))
          (format "T5.2b: Confirmed-empty 3rd pad & pre-6:00 6-Gate surge still set stopped-expanding?=#t (empty=~a early=~a)"
                  (opponent-world-summary-stopped-expanding? s-3rd-empty)
                  (opponent-world-summary-stopped-expanding? s-early))))

;; T5.3: `owm-estimated-enemy-bases` & `owm-estimated-enemy-gases` across early game,
;;       deep fog (`10:00` & `14:30`), high observed gas spend, & clean purity of `confirmed-*`!
(let* ([owm (make-opponent-world-model 'Terran)]
       ;; Early game (< 60s, 0 seen/implied) -> est-bases=1, est-gases=0!
       [s-early (step-opponent-world-model!
                 owm
                 (mk-ring-obs 900 'Terran '() '() #:expansion-pads MAP-12-PADS))]
       ;; 10:00 (13440f) deep fog (only main known, 0 geysers directly seen):
       [s-10m (step-opponent-world-model! owm (mk-ring-obs 13440 'Terran '() '()))]
       ;; 14:30 (19488f) deep fog:
       [s-1430 (step-opponent-world-model! owm (mk-ring-obs 19488 'Terran '() '()))]
       ;; Spend-implied gas check: 6:30 (8736f = 390s >= 375s Terran 3rd deadline) with 2 confirmed
       ;; bases + unscouted outer pads (estB=3) & 8 Battlecruisers (2400G + tech -> >=5 implied gases!)
       [owm-spend (make-opponent-world-model 'Terran)]
       [heavy-gas-units
        (for/list ([i (in-range 8)])
          (hasheq 'id (+ 4100 i) 'type 'battlecruiser 'x 140.0 'y 140.0 'hp 550))]
       [s-spend (step-opponent-world-model!
                 owm-spend
                 (mk-ring-obs 8736 'Terran '()
                              (list (hasheq 'id 4150 'type 'command-center 'x 142.0 'y 150.0 'build-progress 1.0))
                              #:enemy-units heavy-gas-units
                              #:expansion-pads MAP-12-PADS))])
  (check! (and (= (owm-estimated-enemy-bases s-early) 1)
               (= (owm-estimated-enemy-gases s-early) 0)
               (= (owm-estimated-enemy-bases #f) 1)
               (= (owm-estimated-enemy-gases #f) 0))
          (format "T5.3a: <60s with 0 seen/implied & #f defaults stay estB=1, estG=0, got ~a/~a"
                  (owm-estimated-enemy-bases s-early) (owm-estimated-enemy-gases s-early)))
  (check! (and (= (opponent-world-summary-confirmed-bases s-10m) 1)
               (= (opponent-world-summary-confirmed-geysers s-10m) 0)
               (= (owm-estimated-enemy-bases s-10m) 4)
               (>= (owm-estimated-enemy-gases s-10m) 5)
               (= (owm-estimated-enemy-bases s-1430) 6)
               (>= (owm-estimated-enemy-gases s-1430) 8)
               (= (sub1 (vector-length (struct->vector s-1430))) 35))
          (format "T5.3b: Deep fog keeps confirmed pure (1/0) while estimating 4b/>=5g @10m & 6b/>=8g @14:30, got 10m=(~a,~a) 14:30=(~a,~a)"
                  (owm-estimated-enemy-bases s-10m) (owm-estimated-enemy-gases s-10m)
                  (owm-estimated-enemy-bases s-1430) (owm-estimated-enemy-gases s-1430)))
  (check! (and (= (owm-estimated-enemy-bases s-spend) 3)
               (>= (owm-estimated-enemy-gases s-spend) 5)
               (<= (owm-estimated-enemy-gases s-spend) 6))
          (format "T5.3c: Heavy observed gas spend (8 BCs @6:00) implies >=5 gases capped at 2*estB (<=6), got estB=~a estG=~a"
                  (owm-estimated-enemy-bases s-spend) (owm-estimated-enemy-gases s-spend))))

;; T5.4: MirrorMind `compute-opponent-shadow-ledger` `#:remembered-enemy-bases` / `#:remembered-enemy-gases`
;;       scales `predicted-enemy-bases` & `expected-gas` beyond 2 geysers cleanly across fog!
(let* ([mm-legacy (make-mirror-mind-state #:our-race 'Terran #:enemy-race 'Protoss)]
       [l-legacy (compute-opponent-shadow-ledger mm-legacy 13440 '() '())]
       [mm-rem (make-mirror-mind-state #:our-race 'Terran #:enemy-race 'Protoss)]
       [l-rem (compute-opponent-shadow-ledger mm-rem 13440 '() '()
                                              #:remembered-enemy-bases 5
                                              #:remembered-enemy-gases 6)]
       [mm-step (make-mirror-mind-state #:our-race 'Terran #:enemy-race 'Protoss)]
       [_ (step-mirror-mind-predictor!
           mm-step
           (hasheq 'frame 13440 'race 'Terran 'enemy-race 'Protoss
                   'base-x 32 'base-y 32 'natural-x 50 'natural-y 42
                   'enemy-x 160 'enemy-y 160 'enemy-expand-x 142 'enemy-expand-y 150
                   'enemy-estimated-bases 5 'enemy-estimated-gases 6
                   'ally-units '() 'ally-buildings '() 'enemy-units '() 'enemy-buildings '()))]
       [l-step (mirror-mind-state-last-shadow-ledger mm-step)])
  (check! (and (>= (shadow-ledger-predicted-enemy-bases l-rem) 5)
               (> (shadow-ledger-expected-gas l-rem) (+ (shadow-ledger-expected-gas l-legacy) 1200))
               (>= (shadow-ledger-predicted-enemy-bases l-step) 5)
               (= (shadow-ledger-expected-gas l-step) (shadow-ledger-expected-gas l-rem)))
          (format "T5.4: Remembered bases=5 gases=6 must lift predB>=5 & expected-gas (+1200G over legacy), got leg=(~a,~a) rem=(~a,~a) step=(~a,~a)"
                  (shadow-ledger-predicted-enemy-bases l-legacy) (shadow-ledger-expected-gas l-legacy)
                  (shadow-ledger-predicted-enemy-bases l-rem) (shadow-ledger-expected-gas l-rem)
                  (shadow-ledger-predicted-enemy-bases l-step) (shadow-ledger-expected-gas l-step))))

;; =============================================================================
;; PART 6: Loop 86D — SC2 `Snapshot` Tag-Churn Spatial Dedup Stress Tests
;; =============================================================================

;; T6.1: Feed the EXACT SAME 2 enemy TownHalls, 2 Geysers, 1 Bunker, and 1 Spine Crawler across
;;       10 consecutive alternating Visible / Snapshot tag IDs at the same `(x, y)` coordinates!
;;       MUST assert `confirmed-bases == 2`, `confirmed-geysers == 2`, `static-ground-count == 2`
;;       (NOT 20!), `enemy-turtle-posterior < 0.25`, preserved lowest positive `vespene-contents`,
;;       and MirrorMind `bldg-costs` counts each physical building ONCE!
(let* ([owm (make-opponent-world-model 'Terran)]
       [mm (make-mirror-mind-state #:our-race 'Protoss #:enemy-race 'Terran)]
       [last-sum #f])
  (for ([k (in-range 10)])
    (define f (+ 7000 (* k 100)))
    ;; Alternate between real Visible tags (5001..5006) and brand-new Snapshot tags every fog cycle!
    (define snapshot? (odd? k))
    (define tag-base (if snapshot? (+ 90000 (* k 100)) 5000))
    ;; Simulate CC -> OC morph on cycle 4+ and Snapshot zeroing vespene-contents!
    (define th1-type (if (>= k 4) 'orbital-command 'command-center))
    (define vcont1 (if snapshot? 0 (- 2250 (* k 80))))
    (define bldgs
      (list (hasheq 'id (+ tag-base 1) 'type th1-type 'x 160.0 'y 160.0 'build-progress 1.0)
            (hasheq 'id (+ tag-base 2) 'type 'command-center 'x 142.0 'y 150.0 'build-progress 1.0)
            (hasheq 'id (+ tag-base 3) 'type 'refinery 'x 164.0 'y 158.0 'build-progress 1.0 'vespene-contents vcont1)
            (hasheq 'id (+ tag-base 4) 'type 'refinery 'x 158.0 'y 166.0 'build-progress 1.0 'vespene-contents 2000)
            (hasheq 'id (+ tag-base 5) 'type 'bunker 'x 138.0 'y 148.0 'build-progress 1.0)
            (hasheq 'id (+ tag-base 6) 'type 'spine-crawler 'x 140.0 'y 144.0 'build-progress 1.0)))
    (set! last-sum
          (step-opponent-world-model!
           owm
           (mk-ring-obs f 'Terran
                        (list (hasheq 'id 1 'type 'observer 'x 148.0 'y 154.0))
                        bldgs
                        #:expansion-pads MAP-12-PADS)))
    (compute-opponent-shadow-ledger mm f '() bldgs #:base-x 32 #:base-y 32 #:nat-x 50 #:nat-y 42))
  (define bd (owm-enemy-turtle-breakdown last-sum))
  (define sg-cnt (hash-ref bd 'static-ground-count))
  (define turtle-p
    (compute-bayesian-enemy-turtle-posterior
     #:static-ground-count sg-cnt
     #:pf-count (hash-ref bd 'pf-count)
     #:static-aa-count (hash-ref bd 'static-aa-count)
     #:burrow-mine-count (hash-ref bd 'burrow-mine-count)
     #:siege-zone-count (hash-ref bd 'siege-zone-count)
     #:enemy-bases (opponent-world-summary-confirmed-bases last-sum)
     #:frame 8000))
  (define mm-bldg-cnt (hash-count (mirror-mind-state-seen-enemy-bldg-costs mm)))
  (define known-bldg-cnt (hash-count (opponent-world-model-known-bldgs owm)))
  (check! (and (= (opponent-world-summary-confirmed-bases last-sum) 2)
               (= (opponent-world-summary-confirmed-geysers last-sum) 2)
               (= sg-cnt 2)
               (= known-bldg-cnt 6)
               (< turtle-p 0.25))
          (format "T6.1a: 10-cycle Visible/Snapshot tag-churn must stay confB=2 confG=2 sg=2 knownB=6 turtle<0.25, got B=~a G=~a sg=~a knownB=~a p=~a"
                  (opponent-world-summary-confirmed-bases last-sum)
                  (opponent-world-summary-confirmed-geysers last-sum)
                  sg-cnt known-bldg-cnt turtle-p))
  (check! (= mm-bldg-cnt 6)
          (format "T6.1b: MirrorMind bldg-costs must count each of the 6 physical buildings ONCE across 10 tag-churn cycles, got ~a"
                  mm-bldg-cnt)))

;; T6.2: Adjacent 2x2 structures (`2.0t` center-to-center) MUST NOT falsely merge, AND
;;       same-pad geyser cap (`<= 2` geysers within `12t` of a base pad) prevents ghost 3rd geyser!
(let* ([owm (make-opponent-world-model 'Protoss)]
       [s1 (step-opponent-world-model!
            owm
            (mk-ring-obs
             8500 'Protoss
             (list (hasheq 'id 1 'type 'observer 'x 155.0 'y 155.0))
             ;; 4 adjacent 2x2 Photon Cannons spaced 2.0t apart + 3 geysers at same main pad (160,160)
             (list (hasheq 'id 6001 'type 'photon-cannon 'x 140.0 'y 150.0 'build-progress 1.0)
                   (hasheq 'id 6002 'type 'photon-cannon 'x 142.0 'y 150.0 'build-progress 1.0)
                   (hasheq 'id 6003 'type 'photon-cannon 'x 144.0 'y 150.0 'build-progress 1.0)
                   (hasheq 'id 6004 'type 'photon-cannon 'x 146.0 'y 150.0 'build-progress 1.0)
                   (hasheq 'id 6011 'type 'assimilator 'x 164.0 'y 158.0 'build-progress 1.0)
                   (hasheq 'id 6012 'type 'assimilator 'x 158.0 'y 166.0 'build-progress 1.0)
                   (hasheq 'id 6013 'type 'assimilator 'x 154.0 'y 156.0 'build-progress 1.0))
             #:expansion-pads MAP-12-PADS))]
       [sg (hash-ref (owm-enemy-turtle-breakdown s1) 'static-ground-count)])
  (check! (and (= sg 4)
               (= (opponent-world-summary-confirmed-geysers s1) 2))
          (format "T6.2: 4 adjacent 2.0t Cannons stay sg=4 (no false merge) & same-pad geysers cap at <=2, got sg=~a confG=~a"
                  sg (opponent-world-summary-confirmed-geysers s1))))

;; T6.3 (L86E): O(1) steady-state fast-path micro-benchmark (60 known enemy buildings x 200 steps)
;;              verifies OWM + MirrorMind ledger stay ultra-fast (< 2.0 ms/step)!
(let* ([owm (make-opponent-world-model 'Terran)]
       [mm (make-mirror-mind-state #:our-race 'Protoss #:enemy-race 'Terran)]
       [bldgs-60
        (for/list ([i (in-range 60)])
          (define col (modulo i 10))
          (define row (quotient i 10))
          (hasheq 'id (+ 7000 i)
                  'type (cond [(< i 4) 'command-center]
                              [(< i 10) 'refinery]
                              [(< i 20) 'barracks]
                              [else 'supply-depot])
                  'x (+ 100.0 (* col 5.0))
                  'y (+ 100.0 (* row 5.0))
                  'build-progress 1.0))]
       ;; Warm-up step to populate `known-bldgs` & `bldg-costs`
       [_ (step-opponent-world-model! owm (mk-ring-obs 10000 'Terran '() bldgs-60 #:expansion-pads MAP-12-PADS))]
       [_ (compute-opponent-shadow-ledger mm 10000 '() bldgs-60 #:base-x 32 #:base-y 32 #:nat-x 50 #:nat-y 42)]
       [t0 (current-inexact-monotonic-milliseconds)])
  (for ([step (in-range 1 201)])
    (define f (+ 10000 (* step 8)))
    (step-opponent-world-model! owm (mk-ring-obs f 'Terran '() bldgs-60))
    (compute-opponent-shadow-ledger mm f '() bldgs-60 #:base-x 32 #:base-y 32 #:nat-x 50 #:nat-y 42))
  (define dt-ms (- (current-inexact-monotonic-milliseconds) t0))
  (define avg-ms (/ dt-ms 200.0))
  (printf "  [L86E-bench] 60-bldg OWM+MirrorMind steady-state: avg=~a ms/step (~a ms / 200 steps)\n"
          (/ (exact-round (* avg-ms 1000.0)) 1000.0)
          (/ (exact-round (* dt-ms 10.0)) 10.0))
  (check! (< avg-ms 2.0)
          (format "T6.3: 60-bldg steady-state OWM+MirrorMind O(1) fast path must average < 2.0 ms/step, got ~a ms/step" avg-ms)))

(printf "l86-anti-turtle-belief-test: ~a passed, ~a failed\n" passed failed)
(when (> failed 0)
  (exit 1))
