#lang racket/base

;; =============================================================================
;; Loop 88A Track 4 Verification Suite:
;;   1. Single-Authority L2 Spend Bridge (`l2-execute-macro-decision!`) &
;;      Zero Out-of-Band Mineral Theft (Starport/Orbital, Medivac/Bunker,
;;      SiegeTank, E-Bay without `#:bypass-escrow? #t`)
;;   2. Closed-Loop Physical-Refusal Feedback (`rt` <-> Wire <-> Brain) &
;;      Safe-Base Tech Rebuild Relocation
;;   3. Goal-Driven Terran Addon Swap (Factory TechLab vs Reactor Lock)
;;   4. Deleted Duplicate `wd-gas-mode` + Demand Flow Export + Repair Dedup
;;   5. 7-Dim OWM Control Bridge + Unified Tactical Operation Controller +
;;      Decoupled Delay Harass + All-Race Uphill Brake + ABI Preservation
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/econ/escrow-engine.rkt"
         "../lib/tactics/operation-controller.rkt"
         "../lib/tactics/concave-positioning.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check-test name pred [detail ""])
  (if pred
      (begin
        (set! pass-count (add1 pass-count))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "  [FAIL] ~a :: ~a\n" name detail))))

(define (mk-u id sym x y
              #:hp [hp 100.0]
              #:max-hp [max-hp hp]
              #:shield [sh 0.0]
              #:max-shield [max-sh sh]
              #:z [z 10.0]
              #:build-progress [bp 1.0]
              #:order-count [oc 0]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:addon [addon #f]
              #:add-on-tag [atag 0]
              #:assigned-harvesters [ah #f]
              #:ideal-harvesters [ih #f]
              #:vespene-contents [vc #f]
              #:weapon-cooldown [wcd 0.0])
  (define h0
    (hash 'id id 'type sym 'x x 'y y 'z z
          'hp hp 'max-hp max-hp 'shield sh 'max-shield max-sh
          'build-progress bp 'order-count oc 'order-ability-id oab
          'order-target-id otid 'display-type 1 'snapshot? #f
          'weapon-cooldown wcd))
  (define h1 (if addon (hash-set h0 'addon addon) h0))
  (define h2 (if (> atag 0) (hash-set h1 'add-on-tag atag) h1))
  (define h3 (if ah (hash-set h2 'assigned-harvesters ah) h2))
  (define h4 (if ih (hash-set h3 'ideal-harvesters ih) h3))
  (if vc (hash-set h4 'vespene-contents vc) h4))

(define (mk-workers sym n start-id [bx 32.5] [by 32.5])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) sym
          (+ bx -3.0 (* 0.25 (modulo i 8)))
          (+ by -2.0 (* 0.25 (quotient i 8)))
          #:hp 45.0)))

(define (mk-live-obs #:race race
                     #:enemy-race enemy-race
                     #:frame frame
                     #:minerals [minerals 200]
                     #:gas [gas 150]
                     #:supply-used [sup-used 40]
                     #:supply-cap [sup-cap 62]
                     #:army-supply [army-sup 14]
                     #:mineral-harvesters [mharv 24]
                     #:vespene-harvesters [vharv 6]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:mineral-patches [mps '()]
                     #:extra [extra (hasheq)])
  (define base
    (hash 'frame frame
          'race race
          'enemy-race enemy-race
          'minerals minerals
          'gas gas
          'supply-used sup-used
          'supply-cap sup-cap
          'supply-left (max 0 (- sup-cap sup-used))
          'army-supply army-sup
          'mineral-harvesters mharv
          'vespene-harvesters vharv
          'base-x 32.5 'base-y 32.5
          'natural-x 62.5 'natural-y 32.5
          'third-x 62.5 'third-y 62.5
          'enemy-x 136.0 'enemy-y 136.0
          'enemy-expand-x 118.0 'enemy-expand-y 136.0
          'map-width 176.0 'map-height 176.0
          'expansion-locations (list (cons 62.5 32.5) (cons 62.5 62.5) (cons 92.5 32.5))
          'ally-units au
          'ally-buildings ab
          'enemy-units eu
          'enemy-buildings eb
          'mineral-patches (if (pair? mps)
                               mps
                               (list (hasheq 'id 9901 'type 'mineral-field
                                             'x 26.5 'y 32.5 'mineral-contents 1500)))))
  (for/fold ([h base]) ([(k v) (in-hash extra)])
    (hash-set h k v)))

(printf "=== Loop 88A Track 4 Single-Authority Runtime Tests ===\n")

;; -----------------------------------------------------------------------------
;; T1: Single-Authority Spend Bridge (`l2-execute-macro-decision!`)
;; -----------------------------------------------------------------------------
(let ()
  ;; T1a: Starport scheduled at 153M/189G with idle CC -> Starport executes FIRST,
  ;; out-of-band OrbitalCommand does NOT steal Starport's 150M!
  (define rt-sp (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-sp
    (list (mk-u 1001 'orbital-command 32.5 32.5 #:hp 1500.0)
          (mk-u 1002 'command-center 62.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 1003 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 1004 'supply-depot 45.0 34.0 #:hp 400.0)
          (mk-u 1005 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1006 'factory 38.0 38.0 #:hp 1250.0 #:order-count 1)
          (mk-u 1007 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)
          (mk-u 1008 'refinery 36.5 28.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)))
  (define units-sp
    (append (mk-workers 'scv 28 1100)
            (for/list ([i (in-range 6)]) (mk-u (+ 1200 i) 'marine 50.0 34.0 #:hp 45.0))))
  (define acts-sp
    (step-layer2-economy!
     rt-sp
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 4688
                  #:minerals 153 #:gas 189 #:supply-used 36 #:supply-cap 54 #:army-supply 6
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:ally-buildings bldgs-sp #:ally-units units-sp)))
  (define built-starport?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'starport))) acts-sp))
  (define stole-orbital?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (member 'orbital-command a))) acts-sp))
  (check-test "T1a-starport-executes-before-out-of-band-orbital"
              (and built-starport? (not stole-orbital?))
              (format "starport=~a orbital=~a acts=~a" built-starport? stole-orbital? acts-sp))

  ;; T1b: Medivac scheduled at 100M/188G with idle Starport -> Medivac trains FIRST,
  ;; out-of-band Bunker does NOT steal Medivac's 100M!
  (define rt-med (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-med
    (list (mk-u 2001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 2002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 2003 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 2004 'supply-depot 45.0 34.0 #:hp 400.0)
          (mk-u 2005 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 2006 'factory 38.0 38.0 #:hp 1250.0 #:order-count 1)
          (mk-u 2007 'starport 34.0 40.0 #:hp 1300.0 #:order-count 0)
          (mk-u 2008 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)))
  (define units-med
    (append (mk-workers 'scv 34 2100)
            (for/list ([i (in-range 10)]) (mk-u (+ 2200 i) 'marine 55.0 34.0 #:hp 45.0))))
  (define enemies-med
    (for/list ([i (in-range 4)]) (mk-u (+ 2900 i) 'stalker 95.0 95.0 #:hp 80.0 #:shield 80.0)))
  (define acts-med
    (step-layer2-economy!
     rt-med
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 8764
                  #:minerals 100 #:gas 188 #:supply-used 46 #:supply-cap 70 #:army-supply 12
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-buildings bldgs-med #:ally-units units-med #:enemy-units enemies-med)))
  (define trained-medivac?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'medivac))) acts-med))
  (define stole-bunker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) acts-med))
  (check-test "T1b-medivac-executes-before-out-of-band-bunker"
              (and trained-medivac? (not stole-bunker?))
              (format "medivac=~a bunker=~a acts=~a" trained-medivac? stole-bunker? acts-med))

  ;; T1c: Siege Tank scheduled with ready FactoryTechLab at 155M/130G -> trains Siege Tank immediately!
  (define rt-tk (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-tk
    (list (mk-u 3001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3002 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 3003 'supply-depot 45.0 34.0 #:hp 400.0)
          (mk-u 3004 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 3005 'factory 38.0 38.0 #:hp 1250.0 #:order-count 0 #:addon 'techlab #:add-on-tag 3006)
          (mk-u 3006 'factory-techlab 40.5 37.5 #:hp 400.0)
          (mk-u 3007 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)
          (mk-u 3008 'refinery 36.5 28.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)))
  (define units-tk
    (append (mk-workers 'scv 26 3100)
            (for/list ([i (in-range 6)]) (mk-u (+ 3200 i) 'marine 50.0 34.0 #:hp 45.0))))
  (define acts-tk
    (step-layer2-economy!
     rt-tk
     (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 4500
                  #:minerals 155 #:gas 130 #:supply-used 34 #:supply-cap 54 #:army-supply 8
                  #:mineral-harvesters 20 #:vespene-harvesters 6
                  #:ally-buildings bldgs-tk #:ally-units units-tk)))
  (define trained-tank?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'siege-tank))) acts-tk))
  (check-test "T1c-siege-tank-trains-immediately-on-ready-factory-techlab"
              trained-tank?
              (format "acts=~a" acts-tk)))

;; -----------------------------------------------------------------------------
;; T2: Closed-Loop Physical-Refusal Feedback & Safe-Base Tech Relocation
;; -----------------------------------------------------------------------------
(let ()
  ;; T2a: Main Hatchery under enemy Tempests, safe Natural Hatchery alive -> Spire/Pool relocates near Natural!
  (define rt-rel (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define bldgs-rel
    (list (mk-u 4001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 4002 'hatchery 92.5 32.5 #:hp 1500.0)
          (mk-u 4003 'extractor 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)
          (mk-u 4004 'extractor 88.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)))
  (define units-rel
    (append (mk-workers 'drone 32 4100 92.5 32.5)
            (list (mk-u 4201 'overlord 92.5 32.5 #:hp 200.0))))
  (define enemies-rel
    (for/list ([i (in-range 6)])
      (mk-u (+ 4900 i) 'tempest (+ 32.5 (* 0.5 i)) 34.0 #:hp 200.0 #:shield 100.0)))
  (define acts-rel
    (step-layer2-economy!
     rt-rel
     (mk-live-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 13500
                  #:minerals 1400 #:gas 600 #:supply-used 36 #:supply-cap 70 #:army-supply 0
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-buildings bldgs-rel #:ally-units units-rel #:enemy-units enemies-rel)))
  (define safe-tech-build
    (findf (lambda (a)
             (and (pair? a) (eq? (car a) 'build)
                  (memq (second a) '(spawning-pool spire))
                  (>= (length a) 4)
                  (> (abs (- (third a) 32.5)) 20.0)))
           acts-rel))
  (check-test "T2a-contested-main-tech-rebuild-relocates-to-safe-living-base"
              (and safe-tech-build #t)
              (format "acts=~a" acts-rel))

  ;; T2b: Wire-reported refusal list ingests into `rt-active-physical-refusals` in exact
  ;; `refusal-active?` `(cons reason exp-frame)` format and expires after TTL!
  (define rt-ref (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define ref-ht-1
    (rt-active-physical-refusals rt-ref 10000 '((spire no-creep 10000))))
  (define ref-active-1? (refusal-active? ref-ht-1 'spire 10020))
  (define ref-expired? (not (refusal-active? (rt-active-physical-refusals rt-ref 10200) 'spire 10200)))
  (check-test "T2b-physical-refusal-wire-ingest-escrow-compat-and-ttl-expiry"
              (and (hash-has-key? ref-ht-1 'spire) ref-active-1? ref-expired?)
              (format "ref-ht=~a active=~a expired=~a" ref-ht-1 ref-active-1? ref-expired?))

  ;; T2c: When ALL bases are contested (`no-safe-placement`), refusal feeds into next-step Brain
  ;; so Brain drops blocking `'spire` escrow instead of deadlocking!
  (define rt-allc (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (rt-record-physical-refusal! rt-allc 'spire 'no-safe-placement 13600 112)
  (define res-allc
    (step-live-bot-runtime!
     rt-allc
     (mk-live-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 13604
                  #:minerals 1800 #:gas 900 #:supply-used 40 #:supply-cap 78 #:army-supply 4
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-buildings (list (mk-u 4501 'lair 32.5 32.5 #:hp 2000.0)
                                         (mk-u 4502 'spawning-pool 36.0 34.0 #:hp 1000.0)
                                         (mk-u 4503 'extractor 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3))
                  #:ally-units (append (mk-workers 'drone 30 4600)
                                       (list (mk-u 4690 'larva 33.0 33.0 #:hp 25.0)
                                             (mk-u 4691 'larva 33.5 33.0 #:hp 25.0)))
                  #:enemy-units enemies-rel)))
  (define tel-allc (hash-ref res-allc 'telemetry))
  (define saving-allc (hash-ref tel-allc 'prio-saving-for 'none))
  (check-test "T2c-active-physical-refusal-prevents-blocking-spire-escrow"
              (not (eq? saving-allc 'spire))
              (format "saving=~a" saving-allc)))

;; -----------------------------------------------------------------------------
;; T3: Goal-Driven Terran Addon Swap (Prevents Reactor-Locked Factory vs Stalkers)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-sw (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-sw
    (list (mk-u 5001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 5002 'command-center 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 5003 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 5004 'supply-depot 45.0 34.0 #:hp 400.0)
          (mk-u 5005 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 0 #:addon 'reactor #:add-on-tag 5006)
          (mk-u 5006 'barracks-reactor 46.5 35.5 #:hp 400.0)
          (mk-u 5007 'factory 38.0 38.0 #:hp 1250.0 #:order-count 0)
          (mk-u 5008 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 5009 'refinery 36.5 28.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))
  (define units-sw
    (append (mk-workers 'scv 28 5100)
            (for/list ([i (in-range 6)]) (mk-u (+ 5200 i) 'marine 52.0 34.0 #:hp 45.0))))
  (define enemies-sw
    (for/list ([i (in-range 8)]) (mk-u (+ 5900 i) 'stalker 110.0 110.0 #:hp 80.0 #:shield 80.0)))
  (define acts-sw
    (step-layer2-economy!
     rt-sw
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 4600
                  #:minerals 180 #:gas 140 #:supply-used 36 #:supply-cap 54 #:army-supply 8
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:ally-buildings bldgs-sw #:ally-units units-sw #:enemy-units enemies-sw)))
  (define bad-reactor-swap?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'terran-addon-swap)
                  (= (second a) 5005) (= (third a) 5007)))
           acts-sw))
  (check-test "T3a-goal-driven-addon-swap-does-not-lock-factory-onto-reactor-when-tanks-desired"
              (not bad-reactor-swap?)
              (format "acts=~a desired-addons=~a"
                      acts-sw (hash-ref (rt-door-state rt-sw) 'l88-desired-addons #f)))

  ;; T3b: Save-cancelled / contested FactoryTechLab pad blocks 4-frame rebuild loop across BOTH
  ;; `l2-execute-macro-decision!` and `l2-terran-phase2`, records typed `'site-contested` refusal
  ;; to Brain, respects `l2-save-cancel-rebuild-ready?`, and resumes once cleared + cooled down!
  (define rt-sc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-sc-base
    (list (mk-u 5501 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 5502 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 5503 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 5504 'supply-depot 45.0 34.0 #:hp 400.0)
          (mk-u 5505 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 1 #:addon 'reactor #:add-on-tag 5506)
          (mk-u 5506 'barracks-reactor 46.5 35.5 #:hp 400.0)
          (mk-u 5511 'starport 34.0 40.0 #:hp 1300.0 #:order-count 1 #:addon 'reactor #:add-on-tag 5512)
          (mk-u 5512 'starport-reactor 36.5 39.5 #:hp 400.0)
          (mk-u 5513 'engineering-bay 30.0 38.0 #:hp 850.0 #:order-count 1)
          (mk-u 5509 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)
          (mk-u 5510 'refinery 36.5 28.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800)))
  (define units-sc
    (append (mk-workers 'scv 32 5600)
            (for/list ([i (in-range 14)]) (mk-u (+ 5700 i) 'marine 52.0 34.0 #:hp 45.0))))
  (define stalkers-at-pad
    (for/list ([i (in-range 3)]) (mk-u (+ 5800 i) 'stalker 46.5 (+ 37.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define stalkers-far
    (for/list ([i (in-range 3)]) (mk-u (+ 5800 i) 'stalker 110.0 (+ 110.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  ;; Step 1 (f=10489): Dying in-progress FactoryTechLab under Stalker fire (`6.0t` from pad, `8.5t` from Factory) -> save-cancel!
  (define acts-sc1
    (step-layer2-economy!
     rt-sc
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10489
                  #:minerals 250 #:gas 180 #:supply-used 46 #:supply-cap 70 #:army-supply 14
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-buildings (append bldgs-sc-base
                                           (list (mk-u 5507 'factory 38.0 38.0 #:hp 1250.0 #:order-count 1 #:addon 'techlab #:add-on-tag 5508)
                                                 (mk-u 5508 'factory-techlab 40.5 37.5 #:hp 20.0 #:max-hp 400.0 #:build-progress 0.40)))
                  #:ally-units units-sc #:enemy-units stalkers-at-pad)))
  (define canceled-ftl? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cancel) (= (second a) 5508))) acts-sc1))
  ;; Step 2 (f=10493, +4f): Bare Factory with Stalkers still shooting pad -> MUST NOT rebuild & MUST record `'site-contested` refusal!
  (define bldgs-sc-bare (append bldgs-sc-base (list (mk-u 5507 'factory 38.0 38.0 #:hp 1250.0 #:order-count 0))))
  (define acts-sc2
    (step-layer2-economy!
     rt-sc
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10493
                  #:minerals 250 #:gas 180 #:supply-used 46 #:supply-cap 70 #:army-supply 14
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-buildings bldgs-sc-bare #:ally-units units-sc #:enemy-units stalkers-at-pad)))
  (define rebuilt-at-4f? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory-techlab))) acts-sc2))
  (define ref-ht-sc2 (rt-active-physical-refusals rt-sc 10493))
  (define ref-rec-sc2 (hash-ref ref-ht-sc2 'factory-techlab #f))
  (define recorded-contested-refusal? (and (pair? ref-rec-sc2) (eq? (car ref-rec-sc2) 'site-contested)))
  ;; Step 3 (f=10505, +16f, even with Stalkers retreated far): STILL respects `l2-save-cancel-rebuild-ready?` (`60f` cooldown)!
  (define acts-sc3
    (step-layer2-economy!
     rt-sc
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10505
                  #:minerals 250 #:gas 180 #:supply-used 46 #:supply-cap 70 #:army-supply 14
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-buildings bldgs-sc-bare #:ally-units units-sc #:enemy-units stalkers-far)))
  (define rebuilt-in-cd? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory-techlab))) acts-sc3))
  ;; Step 4 (f=10750, > 60f cooldown + Stalkers far away): Rebuilds cleanly!
  (define acts-sc4
    (step-layer2-economy!
     rt-sc
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10750
                  #:minerals 250 #:gas 180 #:supply-used 46 #:supply-cap 70 #:army-supply 14
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-buildings bldgs-sc-bare #:ally-units units-sc #:enemy-units stalkers-far)))
  (define rebuilt-after-clear? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory-techlab))) acts-sc4))
  (check-test "T3b-contested-or-save-cancelled-addon-pad-blocks-rebuild-loop-and-records-refusal"
              (and canceled-ftl? (not rebuilt-at-4f?) recorded-contested-refusal? (not rebuilt-in-cd?) rebuilt-after-clear?)
              (format "cancel=~a reb4f=~a ref=~a rebCd=~a rebClear=~a acts2=~a acts4=~a"
                      canceled-ftl? rebuilt-at-4f? ref-rec-sc2 rebuilt-in-cd? rebuilt-after-clear? acts-sc2 acts-sc4)))

;; -----------------------------------------------------------------------------
;; T4: Deleted Duplicate `wd-gas-mode` + Demand Flow Export + Repair Dedup
;; -----------------------------------------------------------------------------
(let ()
  (define rt-g (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define bldgs-g
    (list (mk-u 6001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 6002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 6003 'assimilator 28.5 36.5 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1600)
          (mk-u 6004 'assimilator 36.5 28.5 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1600)
          (mk-u 6005 'gateway 42.0 36.0 #:hp 500.0 #:shield 500.0)
          (mk-u 6006 'robotics-facility 40.0 40.0 #:hp 450.0 #:shield 450.0)))
  (define units-g
    (append (for/list ([i (in-range 3)]) (mk-u (+ 6100 i) 'probe 29.0 36.0 #:hp 20.0 #:shield 20.0 #:order-ability-id 295 #:order-target-id 6003))
            (for/list ([i (in-range 3)]) (mk-u (+ 6105 i) 'probe 36.0 29.0 #:hp 20.0 #:shield 20.0 #:order-ability-id 295 #:order-target-id 6004))
            (mk-workers 'probe 30 6120)))
  (define res-g
    (step-live-bot-runtime!
     rt-g
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7200
                  #:minerals 80 #:gas 250 #:supply-used 72 #:supply-cap 94 #:army-supply 30
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-buildings bldgs-g #:ally-units units-g)))
  (define acts-g (hash-ref res-g 'actions))
  (define no-dup-rebal?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'rebalance-gas-to-minerals))) acts-g)))
  (define has-demand-export?
    (and (real? (hash-ref res-g 'mineral-demand-rate #f))
         (real? (hash-ref res-g 'gas-demand-rate #f))
         (exact-nonnegative-integer? (hash-ref res-g 'desired-gas-workers #f))))
  (check-test "T4a-wd-gas-mode-deleted-and-flow-demand-exported-in-step-res"
              (and no-dup-rebal? has-demand-export?)
              (format "noDupRebal=~a mDem=~a gDem=~a desG=~a"
                      no-dup-rebal?
                      (hash-ref res-g 'mineral-demand-rate #f)
                      (hash-ref res-g 'gas-demand-rate #f)
                      (hash-ref res-g 'desired-gas-workers #f)))

  ;; T4b: Proxy bunker SCV repair dedups across consecutive frames and suppresses at < 5M!
  (define rt-rep (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                        #:cheese-mode? #t #:cheese-profile 'tvz-proxy-2rax-bunker))
  (hash-set! (rt-cheese-state rt-rep) 'proxy-xy (cons 120.0 120.0))
  (hash-set! (rt-cheese-state rt-rep) 'proxy-wp (cons 100.0 100.0))
  (define bldgs-rep
    (list (mk-u 6501 'command-center 32.5 32.5 #:hp 1500.0)
          (mk-u 6502 'bunker 120.0 120.0 #:hp 220.0 #:max-hp 400.0)))
  (define units-rep
    (list (mk-u 6601 'scv 119.0 120.0 #:hp 45.0)
          (mk-u 6602 'marine 121.0 120.0 #:hp 45.0)))
  (define enemies-rep
    (list (mk-u 6901 'zergling 124.0 120.0 #:hp 35.0)))
  (define obs-rep-1
    (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 2600 #:minerals 50 #:gas 0
                 #:supply-used 18 #:supply-cap 23 #:army-supply 1
                 #:ally-buildings bldgs-rep #:ally-units units-rep #:enemy-units enemies-rep))
  (define acts-rep-1 (hash-ref (step-live-bot-runtime! rt-rep obs-rep-1) 'actions '()))
  (define acts-rep-2 (hash-ref (step-live-bot-runtime! rt-rep (hash-set obs-rep-1 'frame 2604)) 'actions '()))
  (define rt-rep0 (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                         #:cheese-mode? #t #:cheese-profile 'tvz-proxy-2rax-bunker))
  (hash-set! (rt-cheese-state rt-rep0) 'proxy-xy (cons 120.0 120.0))
  (hash-set! (rt-cheese-state rt-rep0) 'proxy-wp (cons 100.0 100.0))
  (define acts-rep-0min (hash-ref (step-live-bot-runtime! rt-rep0 (hash-set obs-rep-1 'minerals 0)) 'actions '()))
  (define (repair-action? a)
    (and (pair? a)
         (or (eq? (car a) 'repair)
             (and (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'repair)))))
  (define rep1-cnt (count repair-action? acts-rep-1))
  (define rep2-cnt (count repair-action? acts-rep-2))
  (define rep0-cnt (count repair-action? acts-rep-0min))
  (check-test "T4b-proxy-bunker-repair-order-ledger-dedup-and-zero-mineral-guard"
              (and (= rep1-cnt 1) (= rep2-cnt 0) (= rep0-cnt 0))
              (format "rep1=~a rep2=~a rep0min=~a" rep1-cnt rep2-cnt rep0-cnt)))

;; -----------------------------------------------------------------------------
;; T5: Unified Operation Controller + Decoupled Delay Harass + All-Race Uphill + ABI
;; -----------------------------------------------------------------------------
(let ()
  ;; T5a: Unified Tactical Operation Controller populates `l88-tactical-op-plan` and
  ;; decouples `delay-harass-allowed?` when outnumbered outside home threat!
  (define rt-op (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define bldgs-op
    (list (mk-u 7001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 7002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)))
  (define units-op
    (append (mk-workers 'probe 34 7100)
            (for/list ([i (in-range 6)]) (mk-u (+ 7200 i) 'stalker (+ 58.0 (* 0.4 i)) 34.0 #:hp 80.0 #:shield 80.0))))
  (define enemies-op
    (for/list ([i (in-range 14)]) (mk-u (+ 7900 i) 'roach (+ 105.0 (* 0.4 i)) 105.0 #:hp 145.0)))
  (define res-op
    (step-live-bot-runtime!
     rt-op
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6000
                  #:minerals 250 #:gas 150 #:supply-used 46 #:supply-cap 62 #:army-supply 12
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-buildings bldgs-op #:ally-units units-op #:enemy-units enemies-op)))
  (define ds-op (rt-door-state rt-op))
  (define op-plan (hash-ref ds-op 'l88-tactical-op-plan #f))
  (define op-mode (hash-ref ds-op 'l88-op-mode #f))
  (define delay-ok? (hash-ref ds-op 'l88-delay-harass-allowed? #f))
  (check-test "T5a-unified-operation-controller-wired-with-decoupled-delay-harass"
              (and (tactical-op-plan? op-plan)
                   (memq op-mode '(regroup-stage pre-arc-hold retreat-regroup))
                   delay-ok?)
              (format "mode=~a delay=~a plan=~a" op-mode delay-ok? op-plan))

  ;; T5b: Active home defense (`<= 14t` of main) switches to `'defend-home` and blocks delay harass!
  (define rt-hd (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define enemies-hd
    (for/list ([i (in-range 10)]) (mk-u (+ 7950 i) 'roach (+ 38.0 (* 0.4 i)) 34.0 #:hp 145.0)))
  (define units-hd
    (append (mk-workers 'probe 34 7300)
            (for/list ([i (in-range 6)]) (mk-u (+ 7400 i) 'stalker (+ 35.0 (* 0.4 i)) 33.0 #:hp 80.0 #:shield 80.0))))
  (step-live-bot-runtime!
   rt-hd
   (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6000
                #:minerals 250 #:gas 150 #:supply-used 46 #:supply-cap 62 #:army-supply 12
                #:mineral-harvesters 28 #:vespene-harvesters 6
                #:ally-buildings bldgs-op #:ally-units units-hd #:enemy-units enemies-hd))
  (define ds-hd (rt-door-state rt-hd))
  (check-test "T5b-active-home-defense-selects-defend-home-and-never-splits-home-fight"
              (and (eq? (hash-ref ds-hd 'l88-op-mode #f) 'defend-home)
                   (not (hash-ref ds-hd 'l88-delay-harass-allowed? #t)))
              (format "mode=~a delay=~a"
                      (hash-ref ds-hd 'l88-op-mode #f)
                      (hash-ref ds-hd 'l88-delay-harass-allowed? #f)))

  ;; T5c: All-race uphill ramp brake holds Protoss Stalker & Terran Marine outside uphill Siege Tank
  (define p-stalker (mk-u 8001 'stalker 50.0 50.0 #:hp 80.0 #:shield 80.0 #:z 8.0))
  (define t-marine  (mk-u 8002 'marine  50.0 50.0 #:hp 45.0 #:z 8.0))
  (define e-tank    (mk-u 8901 'siege-tank-sieged 60.0 50.0 #:hp 175.0 #:z 10.5))
  (define pos-p (build-combat-positioning-context (list p-stalker) (list e-tank)))
  (define pos-t (build-combat-positioning-context (list t-marine)  (list e-tank)))
  (define-values (px py) (all-race-uphill-ramp-hold-pt pos-p p-stalker))
  (define-values (tx ty) (all-race-uphill-ramp-hold-pt pos-t t-marine))
  (check-test "T5c-all-race-uphill-ramp-brake-covers-protoss-and-terran"
              (and px py tx ty)
              (format "protoss=(~a,~a) terran=(~a,~a)" px py tx ty))

  ;; T5d: `live-bot-runtime` ABI arity stays 19 and reset clears new weak states cleanly!
  (define rt-abi (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define-values (_st arity _ac _m _p _im _s _sk) (struct-type-info struct:live-bot-runtime))
  (rt-record-physical-refusal! rt-abi 'spire 'no-safe-placement 5000 100)
  (reset-wave3-tactical-state! rt-abi)
  (check-test "T5d-live-bot-runtime-arity-19-and-clean-reset"
              (and (= arity 19)
                   (hash-empty? (rt-active-physical-refusals rt-abi 5010)))
              (format "arity=~a refusals=~a" arity (rt-active-physical-refusals rt-abi 5010)))

  ;; T5e: Single-authority `eff-fap-posture` & `l34-defending-home?` from canonical `l88-op-mode`!
  ;; Enemies at 20t from Natural (`> 14t`, `<= 26t`) trigger `'defend-home`, set `l34-defending-home? = #t`,
  ;; and NEVER log `pos=retreat` even if raw 1D FAP is negative; mid-map `'retreat-regroup` logs `'retreat`!
  (define rt-dh20 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define bldgs-dh20
    (list (mk-u 8501 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 8502 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 8503 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 8504 'roach-warren 36.0 37.0 #:hp 850.0)))
  (define units-dh20
    (append (mk-workers 'drone 34 8600)
            (for/list ([i (in-range 10)]) (mk-u (+ 8700 i) 'roach (+ 72.0 (* 0.3 i)) 32.5 #:hp 145.0))
            (list (mk-u 8750 'zergling 115.0 115.0 #:hp 35.0))))
  (define enemies-dh20
    (append (for/list ([i (in-range 8)]) (mk-u (+ 8800 i) 'marine (+ 82.5 (* 0.3 i)) 32.5 #:hp 45.0))
            (for/list ([i (in-range 14)]) (mk-u (+ 8820 i) 'marauder (+ 118.0 (* 0.3 i)) 115.0 #:hp 125.0))))
  (define res-dh20
    (step-live-bot-runtime!
     rt-dh20
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7200
                  #:minerals 300 #:gas 150 #:supply-used 56 #:supply-cap 78 #:army-supply 22
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-buildings bldgs-dh20 #:ally-units units-dh20 #:enemy-units enemies-dh20)))
  (define ds-dh20 (rt-door-state rt-dh20))
  (define tel-dh20 (hash-ref res-dh20 'telemetry))
  (define mode-dh20 (hash-ref ds-dh20 'l88-op-mode #f))
  (define def-home-dh20? (hash-ref ds-dh20 'l34-defending-home? #f))
  (define pos-dh20 (hash-ref tel-dh20 'fap-posture #f))
  ;; Control: Outgunned mid-map clash (`~60t` from Natural) triggers `'retreat-regroup` -> logs `'retreat`!
  (define rt-ret (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define units-ret
    (append (mk-workers 'drone 34 8650)
            (for/list ([i (in-range 4)]) (mk-u (+ 8760 i) 'roach (+ 105.0 (* 0.3 i)) 80.0 #:hp 145.0))))
  (define enemies-ret
    (for/list ([i (in-range 14)]) (mk-u (+ 8860 i) 'marauder (+ 110.0 (* 0.3 i)) 80.0 #:hp 125.0)))
  (define res-ret
    (step-live-bot-runtime!
     rt-ret
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7200
                  #:minerals 300 #:gas 150 #:supply-used 42 #:supply-cap 78 #:army-supply 8
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-buildings bldgs-dh20 #:ally-units units-ret #:enemy-units enemies-ret)))
  (define mode-ret (hash-ref (rt-door-state rt-ret) 'l88-op-mode #f))
  (define pos-ret (hash-ref (hash-ref res-ret 'telemetry) 'fap-posture #f))
  (check-test "T5e-defend-home-at-20t-sets-l34-defending-home-and-never-logs-retreat"
              (and (eq? mode-dh20 'defend-home)
                   def-home-dh20?
                   (memq pos-dh20 '(attack hold))
                   (eq? mode-ret 'retreat-regroup)
                   (eq? pos-ret 'retreat))
              (format "dh20(mode=~a defHome=~a pos=~a) ret(mode=~a pos=~a)"
                      mode-dh20 def-home-dh20? pos-dh20 mode-ret pos-ret))

  ;; T5f: Home-perimeter clash at `35t` (`26t < 35t <= 38t` from Natural Hatchery) sets
  ;; `l34-army-at-home? = #t` and NEVER logs `pos=retreat` even when outnumbered!
  (define rt-hp35 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define units-hp35
    (append (mk-workers 'drone 34 8670)
            (for/list ([i (in-range 4)]) (mk-u (+ 8770 i) 'roach (+ 94.0 (* 0.3 i)) 32.5 #:hp 145.0))))
  (define enemies-hp35
    (for/list ([i (in-range 14)]) (mk-u (+ 8880 i) 'marauder (+ 97.5 (* 0.3 i)) 32.5 #:hp 125.0)))
  (define res-hp35
    (step-live-bot-runtime!
     rt-hp35
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7200
                  #:minerals 300 #:gas 150 #:supply-used 42 #:supply-cap 78 #:army-supply 8
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-buildings bldgs-dh20 #:ally-units units-hp35 #:enemy-units enemies-hp35)))
  (define ds-hp35 (rt-door-state rt-hp35))
  (define at-home-hp35? (hash-ref ds-hp35 'l34-army-at-home? #f))
  (define pos-hp35 (hash-ref (hash-ref res-hp35 'telemetry) 'fap-posture #f))
  (check-test "T5f-home-perimeter-35t-sets-army-at-home-and-never-logs-retreat"
              (and at-home-hp35? (memq pos-hp35 '(attack hold)))
              (format "atHome=~a mode=~a pos=~a"
                      at-home-hp35? (hash-ref ds-hp35 'l88-op-mode #f) pos-hp35)))

(printf "\n=== Summary: ~a passed, ~a failed ===\n" pass-count fail-count)
(unless (= fail-count 0) (exit 1))
