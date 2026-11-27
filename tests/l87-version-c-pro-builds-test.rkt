#lang racket/base

;; =============================================================================
;; Loop 87C Version C Pro-Execution Playbook Suite
;; (`tests/l87-version-c-pro-builds-test.rkt`)
;;
;; Verifies all 9 Pro-replay build-order fixes in `lib/build-orders/cheese.rkt`
;; and `evaluate-cheese-bo-next-step` / `cheese-spec-allowed-sym-hash` in
;; `lib/priority-macro-brain.rkt`:
;;   1. `cheese-build-spec` struct arity unchanged (15 fields) & all 18 specs monotonic
;;   2. `zvp-12pool-ling-flood`: 14-Drone opening cap, 10 Lings before Hatch #2 / Gas
;;   3. `zvt-26d-roach-ravager-bust` & `zvz-13-12-ling-bane`: 16-Hatch opener,
;;      no 0:07 Gas1, Roaches BEFORE 24 Lings
;;   4. `zvt-42d-queen-ling-nydus`: early Queen 4 @ 21/125s + safety Lings 6 & 24
;;   5. `zvz-12pool-proxy-spine`: 3 Proxy Spines, 52s dispatch, zero Queen in BO/comp
;;   6. `tvp-1base-2gas-cyclone`: early Marines, 4 Cyclones BEFORE delayed Starport
;;   7. `tvz-reaper-fe-hellion-banshee`: 15 Rax -> 16 Gas, zero Reaper in army-comp,
;;      44 SCV cap, Barracks #2 @ 4:20
;;   8. `pvz-cannon-rush` & `pvp-cannon-rush`: Forge-gated Gateway, 5 Cannons + Battery,
;;      PvZ 2-base Nexus + Cyber follow-up
;;   9. `pvt-proxy-4gate`, `pvt-proxy-stargate`, `pvp-proxy-robo`, `zvp-19d`, and
;;      Terran proxy follow-ups (`tvp-proxy-2rax-marauder`, `tvt-proxy-2rax-reaper`,
;;      `tvz-proxy-2rax-bunker`)
;;  10. `evaluate-cheese-bo-next-step` Overlord pending-supply satisfaction & due? guard
;; =============================================================================

(require racket/list
         racket/match
         "../lib/sc2-types.rkt"
         "../lib/build-orders.rkt"
         "../lib/build-orders/cheese.rkt"
         "../lib/priority-macro-brain.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check! pred msg)
  (if pred
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (eprintf "FAIL: ~a\n" msg))))

(define (find-bo-step spec kind sym [min-cnt 1])
  (findf (lambda (g)
           (and (eq? (pro-bo-goal-kind g) kind)
                (eq? (pro-bo-goal-target-sym g) sym)
                (>= (pro-bo-goal-target-count g) min-cnt)))
         (build-order-spec-steps (cheese-build-spec-bo-spec spec))))

(define (bo-step-index spec kind sym [min-cnt 1])
  (for/first ([g (in-list (build-order-spec-steps (cheese-build-spec-bo-spec spec)))]
              [i (in-naturals)]
              #:when (and (eq? (pro-bo-goal-kind g) kind)
                          (eq? (pro-bo-goal-target-sym g) sym)
                          (>= (pro-bo-goal-target-count g) min-cnt)))
    i))

;; 1. ABI stability & global monotonicity across all 18 specs
(let ()
  (define s0 (first all-cheese-build-specs))
  (check! (= (length (vector->list (struct->vector s0))) 16)
          (format "1a. cheese-build-spec struct arity must remain 15 fields (vector len 16); got=~a"
                  (length (vector->list (struct->vector s0)))))
  (check! (for/and ([spec (in-list all-cheese-build-specs)])
            (define secs (map pro-bo-goal-target-sec (build-order-spec-steps (cheese-build-spec-bo-spec spec))))
            (and (pair? secs)
                 (andmap (lambda (t) (and (> t 0.0) (<= t 360.0))) secs)
                 (for/and ([a (in-list secs)] [b (in-list (cdr secs))]) (<= a b))))
          "1b. All 18 cheese specs must have monotonic target-sec within (0, 360]"))

;; 2. zvp-12pool-ling-flood
(let* ([spec (lookup-cheese-build-spec 'zvp-12pool-ling-flood)]
       [ling-i (bo-step-index spec 'train 'zergling 10)]
       [hatch-i (bo-step-index spec 'expand 'hatchery 2)]
       [gas-i (bo-step-index spec 'build 'extractor 1)]
       [hatch-g (find-bo-step spec 'expand 'hatchery 2)])
  (check! (and (= (cheese-build-spec-worker-cap spec) 14)
               ling-i hatch-i gas-i
               (< ling-i hatch-i)
               (< ling-i gas-i)
               (>= (pro-bo-goal-min-supply hatch-g) 20)
               (>= (pro-bo-goal-target-sec hatch-g) 95.0))
          (format "2. zvp-12pool-ling-flood must cap opening Drones at 14 and train 10 Lings before 20-sup/95s+ Hatch/Gas; wcap=~a ling=~a hatch=~a gas=~a"
                  (cheese-build-spec-worker-cap spec) ling-i hatch-i gas-i)))

;; 3. zvt-26d-roach-ravager-bust & zvz-13-12-ling-bane
(let* ([rr (lookup-cheese-build-spec 'zvt-26d-roach-ravager-bust)]
       [hatch-i (bo-step-index rr 'expand 'hatchery 2)]
       [gas1-i (bo-step-index rr 'build 'extractor 1)]
       [pool-i (bo-step-index rr 'build 'spawning-pool 1)]
       [gas2-i (bo-step-index rr 'build 'extractor 2)]
       [roach-i (bo-step-index rr 'train 'roach 12)]
       [ling24-i (bo-step-index rr 'train 'zergling 24)]
       [hatch-g (find-bo-step rr 'expand 'hatchery 2)]
       [gas1-g (find-bo-step rr 'build 'extractor 1)]
       [zvz1 (lookup-cheese-build-spec 'zvz-13-12-ling-bane)]
       [zvz-gas1 (find-bo-step zvz1 'build 'extractor 1)])
  (check! (and hatch-i gas1-i pool-i gas2-i roach-i ling24-i
               (< hatch-i gas1-i)
               (< hatch-i pool-i)
               (< hatch-i gas2-i)
               (< roach-i ling24-i)
               (<= (pro-bo-goal-target-sec hatch-g) 55.0)
               (>= (pro-bo-goal-target-sec gas1-g) 60.0)
               (>= (pro-bo-goal-min-supply zvz-gas1) 13)
               (>= (pro-bo-goal-target-sec zvz-gas1) 18.0))
          (format "3. zvt-26d-rr Pro 16-Hatch + Roaches-first & zvz-13-12 Gas1 fix failed; hatch=~a gas1=~a roach=~a ling24=~a zvzGas=(~a,~a)"
                  hatch-i gas1-i roach-i ling24-i
                  (pro-bo-goal-min-supply zvz-gas1) (pro-bo-goal-target-sec zvz-gas1))))

;; 4. zvt-42d-queen-ling-nydus
(let* ([nyd (lookup-cheese-build-spec 'zvt-42d-queen-ling-nydus)]
       [q4 (find-bo-step nyd 'train 'queen 4)]
       [l6 (find-bo-step nyd 'train 'zergling 6)]
       [l24 (find-bo-step nyd 'train 'zergling 24)]
       [lair-g (find-bo-step nyd 'morph 'lair 1)])
  (check! (and q4 l6 l24 lair-g
               (<= (pro-bo-goal-min-supply q4) 21)
               (<= (pro-bo-goal-target-sec q4) 126.0)
               (<= (pro-bo-goal-min-supply l6) 22)
               (<= (pro-bo-goal-target-sec l6) 130.0)
               (<= (pro-bo-goal-min-supply l24) 38)
               (<= (pro-bo-goal-target-sec l24) 220.0))
          (format "4. zvt-42d-queen-ling-nydus must include early Queen 4 & Lings 6/24; q4=~s l6=~s l24=~s"
                  q4 l6 l24)))

;; 5. zvz-12pool-proxy-spine
(let* ([sp (lookup-cheese-build-spec 'zvz-12pool-proxy-spine)]
       [q-step (find-bo-step sp 'train 'queen 1)])
  (check! (and (not q-step)
               (not (memq 'queen (cheese-build-spec-army-comp sp)))
               (= (count (lambda (x) (eq? x 'spine-crawler)) (cheese-build-spec-proxy-buildings sp)) 3)
               (<= (cheese-build-spec-proxy-dispatch-sec sp) 55.0))
          (format "5. zvz-12pool-proxy-spine must drop 3 proxy Spines w/o Queen before Spines; q=~s comp=~s pb=~s disp=~a"
                  q-step (cheese-build-spec-army-comp sp)
                  (cheese-build-spec-proxy-buildings sp)
                  (cheese-build-spec-proxy-dispatch-sec sp))))

;; 6. tvp-1base-2gas-cyclone (Loop 87E: restore FactoryTechLab ahead of Cyclone on Base75689,
;;    gate Widow Mine behind >=3 Cyclones, and verify macro-brain schedules FactoryTechLab -> Cyclone!)
(let* ([cyc (lookup-cheese-build-spec 'tvp-1base-2gas-cyclone)]
       [m2 (find-bo-step cyc 'train 'marine 2)]
       [fac-i (bo-step-index cyc 'build 'factory 1)]
       [ftl-i (bo-step-index cyc 'build 'factory-techlab 1)]
       [ftl-g (find-bo-step cyc 'build 'factory-techlab 1)]
       [c4-i (bo-step-index cyc 'train 'cyclone 4)]
       [c4-g (find-bo-step cyc 'train 'cyclone 4)]
       [wm2-i (bo-step-index cyc 'train 'widow-mine 2)]
       [sp-i (bo-step-index cyc 'build 'starport 1)]
       [sp-g (find-bo-step cyc 'build 'starport 1)])
  (reset-macro-escrow-tracker!)
  (define d-need-ftl
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 2688 ;; 120s
      #:minerals 200 #:gas 150 #:supply-used 22 #:supply-cap 39 #:supply-left 17
      #:workers 19 #:active-bases 1 #:mineral-harvesters 13 #:gas-harvesters 6
      #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'barracks-reactor 1 'refinery 2 'factory 1)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'barracks-reactor 1 'refinery 2 'factory 1)
      #:unit-counts (hasheq 'scv 19 'marine 2)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'factory 1))
     #:cheese-spec cyc))
  (reset-macro-escrow-tracker!)
  (define d-train-cyc
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 3584 ;; 160s
      #:minerals 250 #:gas 150 #:supply-used 26 #:supply-cap 47 #:supply-left 21
      #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
      #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1 'barracks-reactor 1 'refinery 2 'factory 1 'factory-techlab 1)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1 'barracks-reactor 1 'refinery 2 'factory 1 'factory-techlab 1)
      #:unit-counts (hasheq 'scv 22 'marine 4)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'factory 1 'factory-techlab 1))
     #:cheese-spec cyc))
  (check! (and (= (cheese-build-spec-max-bases cyc) 1)
               m2 fac-i ftl-i ftl-g c4-i c4-g wm2-i sp-i
               (< fac-i ftl-i)
               (< ftl-i c4-i)
               (< c4-i wm2-i)
               (< wm2-i sp-i)
               (<= (pro-bo-goal-target-sec ftl-g) 115.0)
               (eq? (pro-bo-goal-prereq-ready-sym c4-g) 'factory-techlab)
               (<= (pro-bo-goal-target-sec m2) 100.0)
               (>= (pro-bo-goal-min-supply sp-g) 38)
               (>= (pro-bo-goal-target-sec sp-g) 220.0)
               (eq? (car (cheese-build-spec-army-comp cyc)) 'cyclone)
               (memq 'factory-techlab (macro-brain-decision-scheduled-ids d-need-ftl))
               (not (memq 'widow-mine (macro-brain-decision-scheduled-ids d-need-ftl)))
               (memq 'cyclone (macro-brain-decision-scheduled-ids d-train-cyc))
               (not (memq 'widow-mine (macro-brain-decision-scheduled-ids d-train-cyc))))
          (format "6. tvp-1base-2gas-cyclone FactoryTechLab->Cyclone gate failed; ftl=~a c4=~a wm2=~a sp=~a needFtl=~s trainCyc=~s"
                  ftl-i c4-i wm2-i sp-i
                  (macro-brain-decision-scheduled-ids d-need-ftl)
                  (macro-brain-decision-scheduled-ids d-train-cyc))))

;; 7. tvz-reaper-fe-hellion-banshee
(let* ([rfe (lookup-cheese-build-spec 'tvz-reaper-fe-hellion-banshee)]
       [rax1-i (bo-step-index rfe 'build 'barracks 1)]
       [ref1-i (bo-step-index rfe 'build 'refinery 1)]
       [rep1-i (bo-step-index rfe 'train 'reaper 1)]
       [cc2-i (bo-step-index rfe 'expand 'command-center 2)]
       [rax2-g (find-bo-step rfe 'build 'barracks 2)]
       [mar6-g (find-bo-step rfe 'train 'marine 6)])
  (check! (and rax1-i ref1-i rep1-i cc2-i rax2-g mar6-g
               (< rax1-i ref1-i)
               (< rep1-i cc2-i)
               (not (memq 'reaper (cheese-build-spec-army-comp rfe)))
               (equal? (cheese-build-spec-army-comp rfe) '(banshee hellion marine))
               (= (cheese-build-spec-worker-cap rfe) 44)
               (<= (pro-bo-goal-target-sec rax2-g) 265.0))
          (format "7. tvz-reaper-fe-hellion-banshee Pro specs failed; rax1=~a ref1=~a rep1=~a cc2=~a wcap=~a comp=~s rax2=~s"
                  rax1-i ref1-i rep1-i cc2-i (cheese-build-spec-worker-cap rfe)
                  (cheese-build-spec-army-comp rfe) rax2-g)))

;; 8. pvz-cannon-rush & pvp-cannon-rush
(let* ([pvz-c (lookup-cheese-build-spec 'pvz-cannon-rush)]
       [pvp-c (lookup-cheese-build-spec 'pvp-cannon-rush)]
       [pvz-g1 (find-bo-step pvz-c 'build 'gateway 1)]
       [pvz-nx2 (find-bo-step pvz-c 'expand 'nexus 2)]
       [pvz-cyb (find-bo-step pvz-c 'build 'cybernetics-core 1)]
       [pvp-g1 (find-bo-step pvp-c 'build 'gateway 1)])
  (check! (and pvz-g1 pvz-nx2 pvz-cyb pvp-g1
               (eq? (pro-bo-goal-prereq-ready-sym pvz-g1) 'forge)
               (>= (pro-bo-goal-min-supply pvz-g1) 19)
               (= (cheese-build-spec-max-bases pvz-c) 2)
               (<= (pro-bo-goal-target-sec pvz-nx2) 130.0)
               (>= (count (lambda (x) (eq? x 'photon-cannon)) (cheese-build-spec-proxy-buildings pvz-c)) 5)
               (memq 'shield-battery (cheese-build-spec-proxy-buildings pvz-c))
               (eq? (pro-bo-goal-prereq-ready-sym pvp-g1) 'forge)
               (>= (pro-bo-goal-target-sec pvp-g1) 140.0)
               (>= (count (lambda (x) (eq? x 'photon-cannon)) (cheese-build-spec-proxy-buildings pvp-c)) 5)
               (memq 'shield-battery (cheese-build-spec-proxy-buildings pvp-c)))
          (format "8. Cannon Rush Pro specs failed; pvzG1=~s pvzNx2=~s pvpG1=~s" pvz-g1 pvz-nx2 pvp-g1)))

;; 9a. pvt-proxy-4gate-zealot-stalker, pvt-proxy-stargate-voidray, pvp-proxy-robo-immortal, zvp-19d
;;     (Loop 87D: pvt-proxy-stargate trains VoidRay #1 BEFORE follow-up Nexus #2; pvp-proxy-robo trains Immortal #1 BEFORE WarpPrism!)
(let* ([p4g (lookup-cheese-build-spec 'pvt-proxy-4gate-zealot-stalker)]
       [psg (lookup-cheese-build-spec 'pvt-proxy-stargate-voidray)]
       [psg-fu (cheese-followup-plan 'pvt-proxy-stargate-voidray)]
       [probo (lookup-cheese-build-spec 'pvp-proxy-robo-immortal)]
       [zvp19 (lookup-cheese-build-spec 'zvp-19d-speedling-roach-ravager)])
  (check! (and (find-bo-step p4g 'build 'assimilator 1)
               (find-bo-step p4g 'build 'assimilator 2)
               (find-bo-step p4g 'build 'cybernetics-core 1)
               (find-bo-step p4g 'research 'warp-gate-research 1)
               (= (cheese-build-spec-worker-cap p4g) 20)
               (equal? (cheese-build-spec-army-comp p4g) '(stalker adept zealot))
               (= (cheese-build-spec-max-bases psg) 1)
               (= (cheese-build-spec-worker-cap psg) 22)
               (not (find-bo-step psg 'expand 'nexus 2))
               (find-bo-step psg 'train 'void-ray 2)
               (<= (pro-bo-goal-target-sec (find-bo-step psg 'train 'void-ray 2)) 165.0)
               (find-bo-step psg 'research 'warp-gate-research 1)
               (= (count (lambda (x) (eq? x 'shield-battery)) (cheese-build-spec-proxy-buildings psg)) 2)
               (eq? (car (cheese-build-spec-army-comp psg)) 'void-ray)
               (hash? psg-fu)
               (= (hash-ref psg-fu 'max-bases) 2)
               (findf (lambda (g) (and (eq? (pro-bo-goal-kind g) 'expand) (eq? (pro-bo-goal-target-sym g) 'nexus)))
                      (hash-ref psg-fu 'bo-steps))
               (<= (cheese-build-spec-proxy-dispatch-sec probo) 45.0)
               (equal? (cheese-build-spec-army-comp probo) '(immortal warp-prism stalker adept))
               (< (bo-step-index probo 'train 'immortal 2) (bo-step-index probo 'train 'warp-prism 1))
               (< (bo-step-index probo 'train 'immortal 2) (bo-step-index probo 'build 'gateway 3))
               (<= (pro-bo-goal-target-sec (find-bo-step zvp19 'expand 'hatchery 2)) 78.0))
          "9a. Protoss proxy 4gate/SG/Robo & zvp-19d Pro specs failed"))

;; 9b. Terran proxy opening 1-base focus + state-driven follow-up CC #2
;;     (`tvp-proxy-2rax-marauder`, `tvt-proxy-2rax-reaper`, `tvz-proxy-2rax-bunker`)
(let* ([tmar (lookup-cheese-build-spec 'tvp-proxy-2rax-marauder)]
       [trep (lookup-cheese-build-spec 'tvt-proxy-2rax-reaper)]
       [tbun (lookup-cheese-build-spec 'tvz-proxy-2rax-bunker)]
       [tmar-fu (cheese-followup-plan 'tvp-proxy-2rax-marauder)]
       [trep-fu (cheese-followup-plan 'tvt-proxy-2rax-reaper)]
       [tbun-fu (cheese-followup-plan 'tvz-proxy-2rax-bunker)])
  (check! (and (= (cheese-build-spec-max-bases tmar) 1)
               (not (find-bo-step tmar 'expand 'command-center 2))
               (equal? (cheese-build-spec-army-comp tmar) '(marauder))
               (= (cheese-build-spec-max-bases trep) 1)
               (not (find-bo-step trep 'expand 'command-center 2))
               (find-bo-step trep 'train 'hellion 3)
               (< (bo-step-index trep 'build 'factory 1) (bo-step-index trep 'train 'hellion 3))
               (= (cheese-build-spec-max-bases tbun) 1)
               (not (find-bo-step tbun 'expand 'command-center 2))
               (find-bo-step tbun 'build 'refinery 1)
               ;; Follow-up plans carry CC #2 + 2-base Bio-Tank-Medivac cleanly!
               (andmap (lambda (fu)
                         (and (hash? fu)
                              (= (hash-ref fu 'max-bases) 2)
                              (>= (hash-ref fu 'worker-cap) 44)
                              (findf (lambda (g)
                                       (and (eq? (pro-bo-goal-kind g) 'expand)
                                            (eq? (pro-bo-goal-target-sym g) 'command-center)))
                                     (hash-ref fu 'bo-steps))))
                       (list tmar-fu trep-fu tbun-fu)))
          "9b. Terran proxy opening 1-base focus + follow-up CC #2 plans failed"))

;; 10. `evaluate-cheese-bo-next-step`: Overlord pending-supply accounting & premature `build` due? guard
(let ()
  (define z12 (lookup-cheese-build-spec 'zvp-12pool-ling-flood))
  ;; With 1 Overlord alive + 8 pending-supply (1 Overlord egg in flight), Overlord #2 goal is satisfied!
  (define ev-ov
    (evaluate-cheese-bo-next-step
     z12
     #:frame 900
     #:minerals 200 #:gas 0 #:supply-used 14 #:supply-left 0 #:pending-supply 8
     #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
     #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
     #:unit-counts (hasheq 'drone 13 'overlord 1)))
  (define ag-ov (pro-bo-eval-result-active-goal ev-ov))
  ;; Cannon Rush at 75s (frame 1680) with 19 supply: Gateway #1 @ 125s must NOT trigger 50s early!
  (define pvz-c (lookup-cheese-build-spec 'pvz-cannon-rush))
  (define ev-can
    (evaluate-cheese-bo-next-step
     pvz-c
     #:frame 1680
     #:minerals 200 #:gas 0 #:supply-used 19 #:supply-left 4 #:pending-supply 0
     #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'forge 1 'photon-cannon 3)
     #:total-building-counts (hasheq 'nexus 1 'pylon 3 'forge 1 'photon-cannon 3)
     #:unit-counts (hasheq 'probe 17)))
  (define ag-can (pro-bo-eval-result-active-goal ev-can))
  (check! (and ag-ov
               (eq? (pro-bo-goal-target-sym ag-ov) 'zergling)
               (or (not ag-can)
                   (not (eq? (pro-bo-goal-target-sym ag-can) 'gateway))))
          (format "10. evaluate-cheese-bo-next-step Overlord egg & due? guard failed; ov=~s can=~s"
                  ag-ov ag-can)))

;; 11. Loop 87D: All 18 `(cheese-followup-plan id)` contracts + `(cheese-build-spec-for-followup id)` ABI
(let ()
  (define required-keys
    '(max-bases worker-cap bo-steps army-comp tech-upgrades edge-sec held-sec graduate-sec))
  (check! (and (= (length all-cheese-build-specs) 18)
               (not (cheese-followup-plan 'unknown-profile-id))
               (not (cheese-followup-plan 'auto))
               (for/and ([spec (in-list all-cheese-build-specs)])
                 (define id (cheese-build-spec-id spec))
                 (define fu (cheese-followup-plan id))
                 (define fu-by-spec (cheese-followup-plan spec))
                 (define merged (cheese-build-spec-for-followup spec))
                 (and (hash? fu)
                      (equal? fu fu-by-spec)
                      (andmap (lambda (k) (hash-has-key? fu k)) required-keys)
                      (>= (hash-ref fu 'max-bases) 2)
                      (<= (hash-ref fu 'max-bases) 3)
                      (>= (hash-ref fu 'max-bases) (cheese-build-spec-max-bases spec))
                      (> (hash-ref fu 'worker-cap) (cheese-build-spec-worker-cap spec))
                      (<= (hash-ref fu 'worker-cap) 56)
                      (let ([es (hash-ref fu 'edge-sec)]
                            [hs (hash-ref fu 'held-sec)]
                            [gs (hash-ref fu 'graduate-sec)])
                        (and (real? es) (real? hs) (real? gs) (< 0.0 es hs gs)))
                      (let* ([steps (hash-ref fu 'bo-steps)]
                             [secs (map pro-bo-goal-target-sec steps)])
                        (and (pair? steps)
                             (andmap pro-bo-goal? steps)
                             (andmap (lambda (g) (not (not (lookup-sc2-tech-node (pro-bo-goal-target-sym g))))) steps)
                             (for/and ([a (in-list secs)] [b (in-list (cdr secs))]) (<= a b))))
                      (let ([comp (hash-ref fu 'army-comp)]
                            [upgs (hash-ref fu 'tech-upgrades)])
                        (and (pair? comp)
                             (andmap (lambda (u) (not (not (lookup-sc2-tech-node u)))) comp)
                             (pair? upgs)
                             (andmap (lambda (u) (not (not (lookup-sc2-tech-node u)))) upgs)))
                      ;; `cheese-build-spec-for-followup` preserves 15-field ABI
                      (cheese-build-spec? merged)
                      (= (length (vector->list (struct->vector merged))) 16)
                      (= (cheese-build-spec-max-bases merged) (hash-ref fu 'max-bases))
                      (= (cheese-build-spec-worker-cap merged) (hash-ref fu 'worker-cap)))))
          "11. All 18 cheese-followup-plan entries & cheese-build-spec-for-followup contracts failed"))

;; 12. Loop 87D: `step-priority-macro-brain` `'build` -> `'follow-up` -> `'fallback` transition
;;     clears Terran 1-base locks (`terran_111_opening_stall`) & Protoss 1-base lockout (`one_base_lockout`)
(let ()
  (define tmar (lookup-cheese-build-spec 'tvp-proxy-2rax-marauder))
  (define st-t
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Protoss #:frame 5152 ;; 230s (>= edge-sec 220s)
     #:minerals 450 #:gas 150 #:supply-used 28 #:supply-cap 47 #:supply-left 19
     #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 2 'barracks-techlab 2 'refinery 1)
     #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 2 'barracks-techlab 2 'refinery 1)
     #:unit-counts (hasheq 'scv 19 'marauder 6)
     #:researched-upgrades '(concussive-shells)
     #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'barracks-techlab 2)))
  (reset-macro-escrow-tracker!)
  (define d-build (step-priority-macro-brain st-t #:cheese-spec tmar #:cheese-phase 'build))
  (reset-macro-escrow-tracker!)
  (define d-fu-kw (step-priority-macro-brain st-t #:cheese-spec tmar #:cheese-phase 'follow-up))
  (reset-macro-escrow-tracker!)
  (define st-t-ms
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Protoss #:frame 5152
     #:minerals 450 #:gas 150 #:supply-used 28 #:supply-cap 47 #:supply-left 19
     #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 2 'barracks-techlab 2 'refinery 1)
     #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 2 'barracks-techlab 2 'refinery 1)
     #:unit-counts (hasheq 'scv 19 'marauder 6)
     #:researched-upgrades '(concussive-shells)
     #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'barracks-techlab 2)
     #:mirror-signals (hasheq 'cheese-phase 'follow-up)))
  (define d-fu-ms (step-priority-macro-brain st-t-ms #:cheese-spec tmar))
  ;; Protoss 4-Gate enters `'follow-up` -> expands Nexus #2 cleanly!
  (define p4g (lookup-cheese-build-spec 'pvt-proxy-4gate-zealot-stalker))
  (define st-p
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 5264 ;; 235s (>= edge-sec 225s)
     #:minerals 450 #:gas 150 #:supply-used 34 #:supply-cap 47 #:supply-left 13
     #:workers 20 #:active-bases 1 #:mineral-harvesters 14 #:gas-harvesters 6
     #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 4 'cybernetics-core 1 'assimilator 2)
     #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 4 'cybernetics-core 1 'assimilator 2)
     #:unit-counts (hasheq 'probe 20 'stalker 7)
     #:researched-upgrades '(warp-gate-research)
     #:open-facility-slots (hasheq 'townhall 1 'gateway 4)))
  (reset-macro-escrow-tracker!)
  (define d-p-build (step-priority-macro-brain st-p #:cheese-spec p4g #:cheese-phase 'build))
  (reset-macro-escrow-tracker!)
  (define d-p-fu (step-priority-macro-brain st-p #:cheese-spec p4g #:cheese-phase 'follow-up))
  (check! (and (not (memq 'command-center (macro-brain-decision-scheduled-ids d-build)))
               (memq 'command-center (macro-brain-decision-scheduled-ids d-fu-kw))
               (memq 'command-center (macro-brain-decision-scheduled-ids d-fu-ms))
               (not (memq 'nexus (macro-brain-decision-scheduled-ids d-p-build)))
               (memq 'nexus (macro-brain-decision-scheduled-ids d-p-fu)))
          (format "12. 'follow-up phase must unlock CC #2 & Nexus #2 while 'build holds 1-base commit; tBuild=~s tFuKw=~s tFuMs=~s pBuild=~s pFu=~s"
                  (macro-brain-decision-scheduled-ids d-build)
                  (macro-brain-decision-scheduled-ids d-fu-kw)
                  (macro-brain-decision-scheduled-ids d-fu-ms)
                  (macro-brain-decision-scheduled-ids d-p-build)
                  (macro-brain-decision-scheduled-ids d-p-fu))))

;; 13. Loop 87D: Zerg lifted-Terran close-out (`Lair -> Spire -> Mutalisk`, even during cheese!)
;;     while NOT falsely triggering on an early 2:15 Barracks addon-swap lift!
(let ()
  (define zrr (lookup-cheese-build-spec 'zvt-26d-roach-ravager-bust))
  ;; (a) At 2:15 (frame 3024) with barracks-flying (normal Terran addon swap): NO panic Lair/Spire!
  (reset-macro-escrow-tracker!)
  (define d-early-swap
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 3024
      #:minerals 250 #:gas 150 #:supply-used 28 #:supply-cap 44 #:supply-left 16
      #:workers 22 #:active-bases 2 #:mineral-harvesters 19 #:gas-harvesters 3
      #:army-supply 6 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
      #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
      #:unit-counts (hasheq 'drone 22 'queen 2 'zergling 4 'overlord 4)
      #:enemy-building-counts (hasheq 'command-center 2 'barracks-flying 1)
      #:open-facility-slots (hasheq 'townhall 2 'larva 4))
     #:cheese-spec zrr))
  ;; (b) At 5:30 (frame 7392) with command-center-flying during zvt-26d-rr cheese, no Lair yet -> schedules Lair!
  (reset-macro-escrow-tracker!)
  (define d-lifted-lair
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 7392
      #:minerals 300 #:gas 150 #:supply-used 58 #:supply-cap 72 #:supply-left 14
      #:workers 26 #:active-bases 2 #:mineral-harvesters 20 #:gas-harvesters 6
      #:army-supply 32 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
      #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
      #:unit-counts (hasheq 'drone 26 'queen 2 'roach 10 'ravager 4 'overlord 7)
      #:enemy-building-counts (hasheq 'command-center-flying 1)
      #:open-facility-slots (hasheq 'townhall 2 'larva 5))
     #:cheese-spec zrr))
  ;; (c) With Lair ready + lifted Terran CC -> schedules Spire!
  (reset-macro-escrow-tracker!)
  (define d-lifted-spire
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 8200
      #:minerals 350 #:gas 250 #:supply-used 62 #:supply-cap 80 #:supply-left 18
      #:workers 26 #:active-bases 2 #:mineral-harvesters 20 #:gas-harvesters 6
      #:army-supply 36 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 2)
      #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 2)
      #:unit-counts (hasheq 'drone 26 'queen 2 'roach 12 'ravager 4 'overlord 8)
      #:enemy-building-counts (hasheq 'command-center-flying 1)
      #:open-facility-slots (hasheq 'townhall 2 'larva 5))
     #:cheese-spec zrr))
  ;; (d) With Spire ready + mirror-signal `'enemy-has-lifted-bldg? #t` -> schedules Mutalisk!
  (reset-macro-escrow-tracker!)
  (define d-lifted-muta
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 9400
      #:minerals 300 #:gas 250 #:supply-used 64 #:supply-cap 80 #:supply-left 16
      #:workers 26 #:active-bases 2 #:mineral-harvesters 20 #:gas-harvesters 6
      #:army-supply 38 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'spire 1 'extractor 2)
      #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'spire 1 'extractor 2)
      #:unit-counts (hasheq 'drone 26 'queen 2 'roach 12 'ravager 4 'overlord 8)
      #:mirror-signals (hasheq 'enemy-has-lifted-bldg? #t)
      #:open-facility-slots (hasheq 'townhall 2 'larva 5))
     #:cheese-spec zrr))
  (check! (and (not (memq 'lair (macro-brain-decision-scheduled-ids d-early-swap)))
               (memq 'lair (macro-brain-decision-scheduled-ids d-lifted-lair))
               (memq 'spire (macro-brain-decision-scheduled-ids d-lifted-spire))
               (or (memq 'mutalisk (macro-brain-decision-scheduled-ids d-lifted-muta))
                   (memq 'corruptor (macro-brain-decision-scheduled-ids d-lifted-muta))))
          (format "13. Zerg lifted-Terran close-out failed; earlySwap=~s lair=~s spire=~s muta=~s"
                  (macro-brain-decision-scheduled-ids d-early-swap)
                  (macro-brain-decision-scheduled-ids d-lifted-lair)
                  (macro-brain-decision-scheduled-ids d-lifted-spire)
                  (macro-brain-decision-scheduled-ids d-lifted-muta))))

(printf "l87-version-c-pro-builds-test: ~a passed, ~a failed\n" pass-count fail-count)
(unless (= fail-count 0)
  (exit 1))
