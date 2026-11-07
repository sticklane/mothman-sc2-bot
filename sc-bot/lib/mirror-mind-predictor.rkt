#lang racket/base

;; =============================================================================
;; Layer 1c: Generic Recursive k-Level Mirror-Mind Opponent Predictor
;; (`lib/mirror-mind-predictor.rkt`)
;;
;; Models the opponent as at least as smart and capable as we are using a
;; generic recursive k-level cognitive hierarchy (default depth d = 2):
;;
;;   - Depth 0 (Observational Baseline):
;;       Reacts strictly to currently visible enemy units right now.
;;   - Depth 1 (First-Order Opponent Prediction):
;;       Uses what we know about the OPPONENT (visible units/structures,
;;       zero-supply-block Shadow Economy & Dark-Matter Resource Ledger, and
;;       Action-Lens inverse planning) to predict what the opponent is building
;;       and where they will strike next:
;;         u_opp^(1), tau_opp^(1)  --->  our response u_self^(1)
;;   - Depth 2 (Second-Order Mirror Prediction — Default):
;;       Uses what we know about the OPPONENT and OURSELVES (our own units,
;;       structures, economy, and whether the opponent scouted/engaged us) to
;;       predict THEIR prediction about US (u_self_in_opp_mind^(1)), predicts
;;       how a rational opponent will counter their prediction of us
;;       (u_opp^(2), tau_opp^(2)), and computes our preemptive counter
;;       (u_self^(2), tau_self^(2)).
;;   - Depth k >= 3 (Arbitrary Recursive Depth):
;;       Inductively applies the mutual best-response operator:
;;         Level k predicts the other agent's Level (k-1) prediction and
;;         computes the rational strategic + tactical counter-response.
;;
;; Tracks closed-loop prediction accuracy across depths (d = 1, 2, 3, ...) and
;; dynamically selects the active depth (defaulting to d = 2, stepping down to
;; d = 1 if the opponent plays a non-reactive 1-level script, or escalating to
;; d = 3 against a hyper-reactive opponent when d = 2 accuracy is high).
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/set
         "zerospace-mastermind.rkt")

(provide (struct-out shadow-ledger)
         (struct-out action-lens-reading)
         (struct-out depth-node)
         (struct-out mirror-forecast)
         (struct-out diagnostic-probe)
         (struct-out mirror-toolbox-allocation)
         (struct-out mirror-mind-state)
         make-mirror-mind-state
         unit-resource-cost
         unit-to-archetype
         compute-opponent-shadow-ledger
         interpret-opponent-actions
         predict-at-depth
         build-mirror-hierarchy
         issue-diagnostic-depth-probe!
         record-diagnostic-probe-response!
         evaluate-pending-diagnostic-probes!
         choose-optimal-mirror-depth
         compute-mirror-toolbox-allocation
         infer-mirror-counter-plan
         predict-opponent-tactical-target
         resolve-pending-forecasts!
         select-mirror-trust-mode
         step-mirror-mind-predictor!)

;; =============================================================================
;; 1. Unit & Structure Cost Table (Minerals . Gas)
;; =============================================================================

(define UNIT-COST-TABLE
  (hash
   ;; Zerg
   'drone             (cons 50 0)
   'zergling          (cons 25 0)
   'baneling          (cons 50 25)
   'queen             (cons 150 0)
   'roach             (cons 75 25)
   'ravager           (cons 100 100)
   'hydralisk         (cons 100 50)
   'lurker            (cons 150 150)
   'mutalisk          (cons 100 100)
   'corruptor         (cons 150 100)
   'ultralisk         (cons 300 200)
   'brood-lord        (cons 300 250)
   'infestor          (cons 100 150)
   'viper             (cons 100 200)
   'overlord          (cons 100 0)
   'overseer          (cons 150 50)
   'hatchery          (cons 300 0)
   'lair              (cons 450 100)
   'hive              (cons 650 250)
   'spawning-pool     (cons 200 0)
   'extractor         (cons 25 0)
   'roach-warren      (cons 150 0)
   'baneling-nest     (cons 100 50)
   'hydralisk-den     (cons 100 100)
   'lurker-den        (cons 100 150)
   'spire             (cons 200 200)
   'infestation-pit   (cons 100 100)
   'ultralisk-cavern  (cons 150 200)
   'spine-crawler     (cons 100 0)
   'spore-crawler     (cons 75 0)
   'sunken-colony     (cons 125 0)
   ;; Terran
   'scv               (cons 50 0)
   'marine            (cons 50 0)
   'marauder          (cons 100 25)
   'reaper            (cons 50 50)
   'ghost             (cons 150 125)
   'hellion           (cons 100 0)
   'hellbat           (cons 100 0)
   'widow-mine        (cons 75 25)
   'cyclone           (cons 150 100)
   'siege-tank        (cons 150 125)
   'siege-tank-sieged (cons 150 125)
   'thor              (cons 300 200)
   'viking            (cons 150 75)
   'medivac           (cons 100 100)
   'liberator         (cons 150 125)
   'banshee           (cons 150 100)
   'raven             (cons 100 150)
   'battlecruiser     (cons 400 300)
   'command-center    (cons 400 0)
   'orbital-command   (cons 550 0)
   'planetary-fortress (cons 550 150)
   'supply-depot      (cons 100 0)
   'refinery          (cons 75 0)
   'barracks          (cons 150 0)
   'barracks-techlab  (cons 50 25)
   'barracks-reactor  (cons 50 50)
   'factory           (cons 150 100)
   'factory-techlab   (cons 50 25)
   'starport          (cons 150 100)
   'engineering-bay   (cons 125 0)
   'armory            (cons 150 100)
   'fusion-core       (cons 150 150)
   'bunker            (cons 100 0)
   'missile-turret    (cons 100 0)
   ;; Protoss
   'probe             (cons 50 0)
   'zealot            (cons 100 0)
   'stalker           (cons 125 50)
   'sentry            (cons 50 100)
   'adept             (cons 100 25)
   'high-templar      (cons 50 150)
   'dark-templar      (cons 125 125)
   'archon            (cons 175 275)
   'observer          (cons 25 75)
   'warp-prism        (cons 250 0)
   'immortal          (cons 275 100)
   'colossus          (cons 300 200)
   'disruptor         (cons 150 150)
   'phoenix           (cons 150 100)
   'void-ray          (cons 250 150)
   'oracle            (cons 150 150)
   'tempest           (cons 250 175)
   'carrier           (cons 350 250)
   'nexus             (cons 400 0)
   'pylon             (cons 100 0)
   'assimilator       (cons 75 0)
   'gateway           (cons 150 0)
   'warpgate          (cons 150 0)
   'forge             (cons 150 0)
   'cybernetics-core  (cons 150 0)
   'photon-cannon     (cons 150 0)
   'shield-battery    (cons 100 0)
   'twilight-council  (cons 150 100)
   'stargate          (cons 150 150)
   'robotics-facility (cons 150 100)
   'robotics-bay      (cons 150 150)
   'robotics-support-bay (cons 150 150)
   'templar-archive   (cons 150 200)
   'dark-shrine       (cons 150 150)
   'fleet-beacon      (cons 300 200)))

(define (unit-resource-cost unit-sym)
  (hash-ref UNIT-COST-TABLE unit-sym (cons 100 25)))

(define (unit-type-sym u)
  (define t (hash-ref u 'type 'unknown))
  (if (symbol? t) t (string->symbol (format "~a" t))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x2 x1)) (sqr (- y2 y1)))))

;; =============================================================================
;; 2. Structs for Shadow Economy, Action Lens, Depth Nodes & Mirror-Mind State
;; =============================================================================

(struct shadow-ledger
  (expected-minerals
   expected-gas
   accounted-minerals
   accounted-gas
   unaccounted-minerals
   unaccounted-gas
   estimated-workers
   dark-matter-hypothesis)
  #:transparent)

(struct action-lens-reading
  (opponent-scouted-us?
   feint-or-poke-detected?
   opponent-turtling?
   early-gas-commitment?
   missing-natural-expansion?
   proxy-or-rush-detected?
   inferred-intent)
  #:transparent)

;; Represents the prediction produced at recursive depth `depth`:
;;   - depth = 0: Direct observation of opponent -> our direct counter
;;   - depth = 1: What we predict the opponent will do given what we know about
;;                them -> our counter to that prediction
;;   - depth = 2: What we predict the opponent predicts about US (given what
;;                they know about us and themselves), how they will counter our
;;                predicted plan -> our counter to their counter
;;   - depth = k: k-th order recursive belief & counter-response
(struct depth-node
  (depth
   opp-belief-about-us       ; symbol: what opponent thinks we are doing at depth k-1
   predicted-enemy-unit      ; symbol: what opponent builds at depth k
   our-response-unit         ; symbol: what we build to counter `predicted-enemy-unit`
   strategic-hypothesis      ; symbol: strategic plan attributed to opponent at depth k
   tactical-target           ; symbol: where opponent strikes at depth k
   target-x                  ; integer
   target-y)                 ; integer
  #:transparent)

(struct mirror-forecast
  (created-frame
   deadline-frame
   depth                     ; integer: which depth (1, 2, 3, ...) generated this forecast
   strategic-hypothesis
   predicted-enemy-unit
   tactical-target
   target-x
   target-y)
  #:transparent)

;; Active Diagnostic Depth-Probe (Foosball Tournament Principle):
;; Best players issue low-cost tests over the course of a match and watch how
;; the opponent responds to infer the opponent's cognitive depth d*:
;;   - 'no-reaction                      -> Opponent is Depth 0/1 (do NOT over-complicate past d=1!)
;;   - 'direct-counter                   -> Opponent is Depth 1 (we play d=2)
;;   - 'second-order-pivot-or-cancel     -> Opponent is Depth 2 (we escalate to d=3)
;;   - 'higher-order-bait-or-double-reverse -> Opponent is Depth 3+ (we escalate to d=4..5!)
(struct diagnostic-probe
  (id
   probe-type                ; 'tech-reveal-probe | 'feint-tempo-probe
   issued-frame
   deadline-frame
   probe-x
   probe-y
   baseline-enemy-arch
   baseline-enemy-x
   baseline-enemy-y)
  #:transparent)

;; Snowball-Bounded Toolbox Allocation (SC2 Snowball Principle):
;; In a snowball game like StarCraft II, cognitive depth is NEVER the primary
;; strategic or tactical determinant — it is strictly another tool in the toolbox
;; (bounded to <= 25% of marginal unit-mix decisions, 0% during crisis defense,
;; and never allowed to override core macro/snowball posture transitions).
(struct mirror-toolbox-allocation
  (lanchester-ratio          ; flonum: (W_self * D_self) / max(1, W_opp * D_opp)
   snowball-state            ; 'crisis-deficit | 'contested-even | 'snowball-advantage
   toolbox-weight            ; flonum in [0.0, 0.25] (strictly capped at 0.25)
   primary-macro-weight      ; flonum in [0.75, 1.00] (= 1.0 - toolbox-weight)
   toolbox-role              ; 'survival-fundamentals-only | 'snowball-watchtower-only | 'depth1-direct-counter-only | 'marginal-toolbox-hedge
   allow-unit-hedge?         ; boolean: #t only when toolbox-weight >= 0.12
   allow-posture-override?)  ; boolean: ALWAYS #f (depth never overrides SC2 macro/snowball posture)
  #:transparent)

(struct mirror-mind-state
  (our-race
   enemy-race
   default-depth             ; integer (usually 2)
   active-depth              ; integer (dynamically chosen depth, 1..5+)
   auto-adapt-depth?         ; boolean
   depth-accuracies          ; mutable hash: depth -> flonum in [0.0, 1.0]
   inferred-opponent-depth   ; integer: opponent's estimated depth d* (0..4+), initialized to 1
   diagnostic-probes         ; list of pending diagnostic-probe
   probes-completed          ; integer: number of resolved diagnostic probes
   last-probe-response       ; symbol: 'untested | 'no-reaction | 'direct-counter | 'second-order-pivot-or-cancel | 'higher-order-bait-or-double-reverse
   toolbox-allocation        ; mirror-toolbox-allocation
   seen-enemy-unit-costs     ; mutable hash: id -> (cons min gas)
   seen-enemy-bldg-costs     ; mutable hash: id -> (cons min gas)
   ever-scouted-by-enemy?    ; boolean
   pending-forecasts         ; list of mirror-forecast
   resolved-hits             ; integer
   resolved-total            ; integer
   strategic-accuracy        ; flonum in [0.0, 1.0]
   tactical-accuracy         ; flonum in [0.0, 1.0]
   overall-accuracy          ; flonum in [0.0, 1.0]
   trust-mode                ; 'level2-preemptive-mirror | 'balanced-bayesian-hedged | 'skeptical-observational-fallback
   last-shadow-ledger        ; shadow-ledger
   last-action-reading       ; action-lens-reading
   last-hierarchy            ; list of depth-node for d = 0 .. max-d
   opp-belief-about-us       ; symbol (what opponent predicts we are doing)
   predicted-enemy-unit      ; symbol (opponent unit at active-depth)
   preemptive-counter-unit   ; symbol (our counter unit at active-depth)
   strategic-hypothesis      ; symbol
   tactical-target           ; symbol
   tactical-x                ; integer
   tactical-y)               ; integer
  #:mutable
  #:transparent)

(define (make-mirror-mind-state #:our-race [our-race 'Zerg]
                                #:enemy-race [enemy-race 'Terran]
                                #:depth [depth 2]
                                #:auto-adapt-depth? [auto-adapt-depth? #t])
  (define d-acc (make-hash (list (cons 0 0.60)
                                 (cons 1 0.64)
                                 (cons 2 0.68)
                                 (cons 3 0.62)
                                 (cons 4 0.58)
                                 (cons 5 0.55))))
  (mirror-mind-state
   our-race
   enemy-race
   depth
   depth
   auto-adapt-depth?
   d-acc
   1
   '()
   0
   'untested
   (mirror-toolbox-allocation 1.0 'contested-even 0.18 0.82 'marginal-toolbox-hedge #t #f)
   (make-hash)
   (make-hash)
   #f
   '()
   2
   3
   0.68
   0.66
   0.67
   'level2-preemptive-mirror
   (shadow-ledger 1000 0 1000 0 0 0 12 'accounted-visible-macro)
   (action-lens-reading #f #f #f #f #f #f 'standard-rational-macro)
   '()
   'roach-ravager
   'marine
   'baneling
   'standard-rational-macro
   'center-map-staging
   1024
   1024))

;; =============================================================================
;; 3. Component 1: Shadow Economy & Dark-Matter Resource Ledger
;; =============================================================================

(define (compute-opponent-shadow-ledger mstate frame enemy-units enemy-bldgs
                                        #:base-x [base-x 700]
                                        #:base-y [base-y 760])
  (define unit-costs (mirror-mind-state-seen-enemy-unit-costs mstate))
  (define bldg-costs (mirror-mind-state-seen-enemy-bldg-costs mstate))

  (for ([u (in-list enemy-units)])
    (define uid (hash-ref u 'id #f))
    (define utype (unit-type-sym u))
    (when uid
      (hash-set! unit-costs uid (unit-resource-cost utype))))

  (for ([b (in-list enemy-bldgs)])
    (define bid (hash-ref b 'id #f))
    (define btype (unit-type-sym b))
    (when bid
      (hash-set! bldg-costs bid (unit-resource-cost btype))))

  ;; Rational opponent worker curve: starts at 12 workers, adds ~1 worker every
  ;; 268 frames (12s) with zero supply blocks, up to 66 workers.
  (define est-workers
    (min 66 (+ 12 (quotient (max 0 frame) 268))))

  (define avg-workers (/ (+ 12.0 est-workers) 2.0))
  (define expected-minerals
    (exact-round (+ 1050.0 (* frame avg-workers 0.036))))
  (define gas-frames (max 0 (- frame 700)))
  (define expected-gas
    (exact-round (* gas-frames 0.19)))

  (define seen-unit-min
    (for/sum ([c (in-hash-values unit-costs)]) (car c)))
  (define seen-unit-gas
    (for/sum ([c (in-hash-values unit-costs)]) (cdr c)))
  (define seen-bldg-min
    (for/sum ([c (in-hash-values bldg-costs)]) (car c)))
  (define seen-bldg-gas
    (for/sum ([c (in-hash-values bldg-costs)]) (cdr c)))

  (define inferred-worker-spend (* (max 0 (- est-workers 12)) 50))
  (define inferred-supply-spend (* (quotient (max 0 (- est-workers 14)) 8) 100))

  (define accounted-minerals
    (+ 1000 inferred-worker-spend inferred-supply-spend seen-unit-min seen-bldg-min))
  (define accounted-gas
    (+ seen-unit-gas seen-bldg-gas))

  (define delta-min (max 0 (- expected-minerals accounted-minerals)))
  (define delta-gas (max 0 (- expected-gas accounted-gas)))

  (define enemy-townhalls
    (filter (lambda (b)
              (memq (unit-type-sym b)
                    '(nexus command-center orbital-command planetary-fortress
                      hatchery lair hive)))
            enemy-bldgs))

  (define enemy-near-us?
    (ormap (lambda (e)
             (<= (dist2d base-x base-y
                         (hash-ref e 'x 1600)
                         (hash-ref e 'y 1600))
                 500))
           (append enemy-units enemy-bldgs)))

  (define hypothesis
    (cond
      [(and enemy-near-us?
            (= (+ seen-unit-gas seen-bldg-gas) 0)
            (>= (length enemy-units) 3))
       'proxy-production-or-all-in]
      [(and (>= delta-gas 200) (< seen-unit-gas 150))
       'hidden-air-or-cloak-tech-switch]
      [(and (>= frame 2200)
            (<= (length enemy-townhalls) 1)
            (>= delta-min 450)
            enemy-near-us?)
       'proxy-production-or-all-in]
      [(and (>= frame 2200)
            (<= (length enemy-townhalls) 1)
            (>= delta-min 450))
       'hidden-expansion-or-macro-boom]
      [(and (>= delta-min 500) (>= delta-gas 100))
       'imminent-fog-timing-wave]
      [else
       'accounted-visible-macro]))

  (define ledger
    (shadow-ledger expected-minerals
                   expected-gas
                   accounted-minerals
                   accounted-gas
                   delta-min
                   delta-gas
                   est-workers
                   hypothesis))
  (set-mirror-mind-state-last-shadow-ledger! mstate ledger)
  ledger)

;; =============================================================================
;; 4. Component 2: Action-Lens Inverse Planner (`interpret-opponent-actions`)
;; =============================================================================

(define (interpret-opponent-actions mstate frame enemy-units enemy-bldgs ledger
                                    #:base-x [base-x 700]
                                    #:base-y [base-y 760]
                                    #:nat-x [nat-x 1024]
                                    #:nat-y [nat-y 1120])
  (define scout-now?
    (ormap (lambda (u)
             (and (memq (unit-type-sym u)
                        '(probe scv drone overlord overseer reaper adept
                          observer phoenix hallucination mutalisk))
                  (<= (dist2d base-x base-y
                              (hash-ref u 'x 1600)
                              (hash-ref u 'y 1600))
                      480)))
           enemy-units))
  (when scout-now?
    (set-mirror-mind-state-ever-scouted-by-enemy?! mstate #t))
  (define scouted-us? (mirror-mind-state-ever-scouted-by-enemy? mstate))

  (define mobile-poke-count
    (count (lambda (u)
             (and (memq (unit-type-sym u)
                        '(reaper hellion adept stalker zergling roach mutalisk oracle banshee))
                  (<= (dist2d nat-x nat-y
                              (hash-ref u 'x 1600)
                              (hash-ref u 'y 1600))
                      420)))
           enemy-units))
  (define feint-detected?
    (and (>= mobile-poke-count 1)
         (<= (length enemy-units) 4)
         (or (>= (shadow-ledger-unaccounted-gas ledger) 150)
             (>= (shadow-ledger-unaccounted-minerals ledger) 400))))

  (define opponent-turtling?
    (ormap (lambda (e)
             (memq (unit-type-sym e)
                   '(bunker photon-cannon shield-battery spine-crawler
                     planetary-fortress siege-tank siege-tank-sieged)))
           (append enemy-units enemy-bldgs)))

  (define gas-bldgs
    (count (lambda (b)
             (memq (unit-type-sym b) '(refinery assimilator extractor)))
           enemy-bldgs))
  (define early-gas?
    (or (>= gas-bldgs 2)
        (>= (shadow-ledger-unaccounted-gas ledger) 200)))

  (define enemy-townhalls
    (count (lambda (b)
             (memq (unit-type-sym b)
                   '(nexus command-center orbital-command planetary-fortress
                     hatchery lair hive)))
           enemy-bldgs))
  (define missing-nat?
    (and (>= frame 2688) (<= enemy-townhalls 1)))

  (define proxy-or-rush?
    (or (ormap (lambda (b)
                 (<= (dist2d base-x base-y
                             (hash-ref b 'x 1600)
                             (hash-ref b 'y 1600))
                     600))
               enemy-bldgs)
        (and (< frame 2688)
             (>= (count (lambda (u)
                          (<= (dist2d nat-x nat-y
                                      (hash-ref u 'x 1600)
                                      (hash-ref u 'y 1600))
                              450))
                        enemy-units)
                 3))))

  (define inferred-intent
    (cond
      [proxy-or-rush?            'immediate-proxy-or-early-all-in]
      [feint-detected?           'front-poke-masking-drop-or-tech-switch]
      [(eq? (shadow-ledger-dark-matter-hypothesis ledger)
            'hidden-air-or-cloak-tech-switch)
       'hidden-air-or-cloak-transition]
      [(eq? (shadow-ledger-dark-matter-hypothesis ledger)
            'hidden-expansion-or-macro-boom)
       'hidden-ninja-expansion-or-macro-boom]
      [opponent-turtling?        'defensive-turtle-into-late-game-tech]
      [(and scouted-us? early-gas?) 'targeted-counter-tech-transition]
      [missing-nat?              'one-base-timing-attack-preparation]
      [else                      'standard-rational-macro]))

  (define reading
    (action-lens-reading scouted-us?
                         feint-detected?
                         opponent-turtling?
                         early-gas?
                         missing-nat?
                         proxy-or-rush?
                         inferred-intent))
  (set-mirror-mind-state-last-action-reading! mstate reading)
  reading)

;; =============================================================================
;; 5. Component 3: Generic Recursive k-Level Cognitive Hierarchy (`predict-at-depth`)
;; =============================================================================
;;
;; Let's trace how each depth works generically:
;;   - Depth 0 (Observational):
;;       Uses only currently visible enemy units (`observed-enemy-archetype`),
;;       assuming no hidden tech transition.
;;   - Depth 1 (First-Order — "Predict opponent from what we know about them"):
;;       Integrates opponent's visible units, Dark-Matter Resource Ledger, and
;;       Action-Lens reading to predict what the opponent is building (`u_opp^(1)`)
;;       and where they will attack (`tau_opp^(1)`), and selects our direct
;;       counter (`u_self^(1)`).
;;   - Depth 2 (Second-Order — "Predict opponent's prediction about US"):
;;       First applies Depth-1 inference FROM THE OPPONENT'S PERSPECTIVE looking
;;       at our own units, buildings, and expansion timing to determine what a
;;       smart opponent predicts WE are doing (`opp-belief-about-us`).
;;       Then predicts what unit (`u_opp^(2)`) and tactical strike (`tau_opp^(2)`)
;;       the opponent will choose to counter their prediction of us, and selects
;;       our preemptive counter (`u_self^(2)`).
;;   - Depth k >= 3 (k-th Order Induction):
;;       Takes the (k-1)-th node, treats our (k-1)-th response unit
;;       (`our-response-unit` at depth k-1) as the opponent's updated belief
;;       about us at depth k, predicts the opponent's counter to that
;;       (`u_opp^(k)`), shifts the tactical vector to counter-ambush, and
;;       computes our k-th response (`u_self^(k)`).

(define ALL-RATIONAL-TECH
  '(spawning-pool roach-warren baneling-nest lair hydralisk-den spire lurker-den
    barracks factory starport
    gateway cybernetics-core robotics-facility robotics-bay stargate twilight-council))

(define (unit-to-archetype unit-sym)
  (case unit-sym
    [(marine marauder reaper ghost medivac)           'bio-ball]
    [(siege-tank hellion cyclone thor widow-mine)     'mech-siege]
    [(stalker colossus immortal archon disruptor)     'stalker-colossus]
    [(void-ray carrier tempest oracle phoenix
      banshee battlecruiser liberator)                'sky-toss]
    [(zergling baneling hydralisk lurker)             'ling-bane-hydra]
    [(roach ravager)                                  'roach-ravager]
    [(mutalisk corruptor brood-lord)                  'muta-flock]
    [else                                             'early-rush]))

(define (archetype-signature-unit race arch)
  (case arch
    [(bio-ball)         'marauder]
    [(mech-siege)       'siege-tank]
    [(stalker-colossus) 'colossus]
    [(sky-toss)         (case race [(Terran) 'banshee] [(Zerg) 'mutalisk] [else 'void-ray])]
    [(ling-bane-hydra)  'hydralisk]
    [(roach-ravager)    'roach]
    [(muta-flock)       'mutalisk]
    [else               (case race [(Terran) 'marine] [(Protoss) 'zealot] [else 'zergling])]))

(define (race-hidden-gas-threat enemy-race)
  (case enemy-race
    [(Protoss) 'void-ray]
    [(Terran)  'banshee]
    [(Zerg)    'mutalisk]
    [else      'void-ray]))

(define (counter-unit-for-race race target-archetype available-tech minerals gas)
  (define tree (get-race-counter-tree race))
  (define res
    (resolve-demand-pull tree
                         target-archetype
                         (if (null? available-tech) ALL-RATIONAL-TECH available-tech)
                         #:minerals (max 250 minerals)
                         #:gas (max 150 gas)))
  (if (hash? res)
      (hash-ref res 'selected-unit 'roach)
      res))

;; What does the opponent predict about US at depth 1 (using what they know
;; about us and what we have built/expanded)?
(define (infer-opponent-belief-about-us mstate ally-units ally-bldgs)
  (define our-race (mirror-mind-state-our-race mstate))
  (define bldg-syms (map unit-type-sym ally-bldgs))
  (define visible-arch (classify-enemy-archetype ally-units))
  (cond
    ;; If we have Spire/Stargate/Starport, a smart opponent predicts air/tech
    [(or (memq 'spire bldg-syms) (memq 'stargate bldg-syms))
     (if (eq? our-race 'Zerg) 'muta-flock 'sky-toss)]
    [(memq 'robotics-facility bldg-syms)
     'stalker-colossus]
    [(memq 'factory bldg-syms)
     'mech-siege]
    [(not (memq visible-arch '(early-rush standard-macro)))
     visible-arch]
    ;; Even if our army is small/early, a smart opponent infers our race's
    ;; core midgame doctrine from our race & opening structures
    [else
     (case our-race
       [(Zerg)    (if (memq 'roach-warren bldg-syms) 'roach-ravager 'ling-bane-hydra)]
       [(Protoss) 'stalker-colossus]
       [(Terran)  'bio-ball]
       [else      'roach-ravager])]))

;; Base tactical target at Depth 1 (based on opponent's capabilities & actions)
(define (tactical-target-at-depth-1 mstate obs)
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))
  (define ledger (mirror-mind-state-last-shadow-ledger mstate))
  (define reading (mirror-mind-state-last-action-reading mstate))

  (cond
    [(or (action-lens-reading-feint-or-poke-detected? reading)
         (eq? (shadow-ledger-dark-matter-hypothesis ledger)
              'hidden-air-or-cloak-tech-switch))
     (values 'main-mineral-line-drop-or-air base-x base-y)]
    [(or (action-lens-reading-proxy-or-rush-detected? reading)
         (action-lens-reading-missing-natural-expansion? reading)
         (eq? (shadow-ledger-dark-matter-hypothesis ledger)
              'imminent-fog-timing-wave))
     (values 'natural-choke-timing-push nat-x nat-y)]
    [(eq? (shadow-ledger-dark-matter-hypothesis ledger)
          'hidden-expansion-or-macro-boom)
     (values 'hidden-third-base-expansion
             (exact-round (* 0.5 (+ nat-x enemy-x)))
             (exact-round (* 0.5 (+ nat-y enemy-y))))]
    [else
     (values 'center-map-staging
             (exact-round (* 0.5 (+ nat-x enemy-x)))
             (exact-round (* 0.5 (+ nat-y enemy-y))))]))

;; Tactical target at Depth k >= 2:
;; Given where the opponent expects US to be at depth (k-1), where will a smart
;; opponent strike to exploit our predicted positioning?
(define (tactical-target-at-higher-depth prev-target obs)
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))
  (case prev-target
    ;; If at depth k-1 the focus was the natural choke, a depth-k opponent
    ;; predicts we will mass at the natural choke and therefore routes a drop
    ;; or air backstab into our main mineral line!
    [(natural-choke-timing-push)
     (values 'main-mineral-line-drop-or-air base-x base-y)]
    ;; If at depth k-1 the focus was our main mineral line, a depth-k opponent
    ;; predicts we pulled defenders back into our main and therefore hits our
    ;; exposed natural/third expansion!
    [(main-mineral-line-drop-or-air)
     (values 'natural-choke-timing-push nat-x nat-y)]
    ;; If at depth k-1 the focus was center-map staging, a depth-k opponent
    ;; flanks the natural choke or takes a hidden third
    [(center-map-staging)
     (values 'natural-choke-timing-push nat-x nat-y)]
    [else
     (values 'center-map-staging
             (exact-round (* 0.5 (+ nat-x enemy-x)))
             (exact-round (* 0.5 (+ nat-y enemy-y))))]))

;; Generic recursive predictor for any depth d >= 0
(define (predict-at-depth mstate depth obs
                          #:our-tech [our-tech ALL-RATIONAL-TECH]
                          #:our-minerals [our-minerals 300]
                          #:our-gas [our-gas 150])
  (define our-race (mirror-mind-state-our-race mstate))
  (define enemy-race (mirror-mind-state-enemy-race mstate))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))
  (define ledger (mirror-mind-state-last-shadow-ledger mstate))
  (define reading (mirror-mind-state-last-action-reading mstate))

  (cond
    ;; -------------------------------------------------------------------------
    ;; DEPTH 0: Pure Observational Baseline (No theory of mind)
    ;; -------------------------------------------------------------------------
    [(<= depth 0)
     (define obs-enemy-arch (classify-enemy-archetype enemy-units))
     (define obs-enemy-unit (archetype-signature-unit enemy-race obs-enemy-arch))
     (define our-d0-unit
       (counter-unit-for-race our-race obs-enemy-arch our-tech our-minerals our-gas))
     (depth-node 0
                 'none
                 obs-enemy-unit
                 our-d0-unit
                 'direct-visible-observation
                 'visible-enemy-front
                 enemy-x
                 enemy-y)]

    ;; -------------------------------------------------------------------------
    ;; DEPTH 1: First-Order Opponent Prediction
    ;; ("Use what we know about the opponent to predict what they will do")
    ;; -------------------------------------------------------------------------
    [(= depth 1)
     (define obs-enemy-arch (classify-enemy-archetype enemy-units))
     (define d1-enemy-unit
       (cond
         [(eq? (shadow-ledger-dark-matter-hypothesis ledger)
               'hidden-air-or-cloak-tech-switch)
          (race-hidden-gas-threat enemy-race)]
         [(action-lens-reading-opponent-turtling? reading)
          (case enemy-race
            [(Terran)  'siege-tank]
            [(Protoss) 'colossus]
            [(Zerg)    'lurker]
            [else      'siege-tank])]
         [else
          (archetype-signature-unit enemy-race obs-enemy-arch)]))
     (define d1-enemy-arch (unit-to-archetype d1-enemy-unit))
     (define our-d1-unit
       (counter-unit-for-race our-race d1-enemy-arch our-tech our-minerals our-gas))
     (define-values (tact-sym tx ty) (tactical-target-at-depth-1 mstate obs))
     (depth-node 1
                 'unmodeled-at-d1
                 d1-enemy-unit
                 our-d1-unit
                 (action-lens-reading-inferred-intent reading)
                 tact-sym
                 tx
                 ty)]

    ;; -------------------------------------------------------------------------
    ;; DEPTH 2: Second-Order Mirror Prediction (Default)
    ;; ("Use what we know about the opponent AND ourselves to predict their
    ;;   predictions about us, and how they will counter us")
    ;; -------------------------------------------------------------------------
    [(= depth 2)
     (define d1-node
       (predict-at-depth mstate 1 obs
                         #:our-tech our-tech
                         #:our-minerals our-minerals
                         #:our-gas our-gas))
     ;; Step 1: What does the opponent predict WE are doing (their d=1 model of us)?
     (define opp-belief-arch
       (infer-opponent-belief-about-us mstate ally-units ally-bldgs))
     ;; Step 2: What unit will a rational opponent of `enemy-race` build to
     ;; counter their prediction of us (`opp-belief-arch`), modulated by their
     ;; Dark-Matter gas ledger?
     (define d2-enemy-unit
       (if (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                'hidden-air-or-cloak-tech-switch)
           (race-hidden-gas-threat enemy-race)
           (counter-unit-for-race enemy-race opp-belief-arch ALL-RATIONAL-TECH 400 250)))
     ;; Step 3: What unit do WE build at Depth 2 to preemptively counter `d2-enemy-unit`?
     (define d2-enemy-arch (unit-to-archetype d2-enemy-unit))
     (define our-d2-unit
       (counter-unit-for-race our-race d2-enemy-arch our-tech our-minerals our-gas))
     ;; Step 4: Tactical mirror at Depth 2
     (define-values (tact-sym tx ty)
       (if (action-lens-reading-feint-or-poke-detected? reading)
           (values 'main-mineral-line-drop-or-air
                   (hash-ref obs 'base-x 700)
                   (hash-ref obs 'base-y 760))
           (tactical-target-at-depth-1 mstate obs)))
     (depth-node 2
                 opp-belief-arch
                 d2-enemy-unit
                 our-d2-unit
                 (action-lens-reading-inferred-intent reading)
                 tact-sym
                 tx
                 ty)]

    ;; -------------------------------------------------------------------------
    ;; DEPTH k >= 3: Arbitrary Higher-Order Recursive Mirror Prediction
    ;; ("Predict their reaction to our (k-1)-th response, and so on")
    ;; -------------------------------------------------------------------------
    [else
     (define prev-node
       (predict-at-depth mstate (sub1 depth) obs
                         #:our-tech our-tech
                         #:our-minerals our-minerals
                         #:our-gas our-gas))
     ;; At depth k, the opponent anticipates our (k-1)-th response unit
     (define opp-belief-arch
       (unit-to-archetype (depth-node-our-response-unit prev-node)))
     ;; And builds the rational counter to our (k-1)-th response
     (define dk-enemy-unit
       (counter-unit-for-race enemy-race opp-belief-arch ALL-RATIONAL-TECH 400 250))
     (define dk-enemy-arch (unit-to-archetype dk-enemy-unit))
     ;; And we build the counter to their depth-k unit
     (define our-dk-unit
       (counter-unit-for-race our-race dk-enemy-arch our-tech our-minerals our-gas))
     (define-values (tact-sym tx ty)
       (tactical-target-at-higher-depth (depth-node-tactical-target prev-node) obs))
     (depth-node depth
                 opp-belief-arch
                 dk-enemy-unit
                 our-dk-unit
                 (depth-node-strategic-hypothesis prev-node)
                 tact-sym
                 tx
                 ty)]))

;; Build the full hierarchy of depth nodes from 0 up to max-depth (at least 4)
(define (build-mirror-hierarchy mstate obs
                                #:max-depth [max-depth #f]
                                #:our-tech [our-tech ALL-RATIONAL-TECH]
                                #:our-minerals [our-minerals 300]
                                #:our-gas [our-gas 150])
  (define top-d
    (max 4
         (or max-depth (mirror-mind-state-default-depth mstate))
         (add1 (mirror-mind-state-inferred-opponent-depth mstate))))
  (define nodes
    (for/list ([d (in-range 0 (add1 top-d))])
      (predict-at-depth mstate d obs
                        #:our-tech our-tech
                        #:our-minerals our-minerals
                        #:our-gas our-gas)))
  (set-mirror-mind-state-last-hierarchy! mstate nodes)
  nodes)

;; =============================================================================
;; 5b. Active Diagnostic Depth-Probing & Snowball-Bounded Toolbox
;;     (Foosball Tournament & SC2 Snowball Principles)
;; =============================================================================

;; Issue a low-cost diagnostic probe over the course of a match to test how the
;; opponent reacts and infer their true cognitive depth d*.
(define (issue-diagnostic-depth-probe! mstate frame enemy-units
                                       #:probe-type [probe-type 'feint-tempo-probe]
                                       #:probe-x [probe-x 1180]
                                       #:probe-y [probe-y 1180])
  (define base-arch (classify-enemy-archetype enemy-units))
  (define avg-ex
    (if (null? enemy-units)
        1600
        (quotient (for/sum ([e (in-list enemy-units)]) (hash-ref e 'x 1600))
                  (length enemy-units))))
  (define avg-ey
    (if (null? enemy-units)
        1600
        (quotient (for/sum ([e (in-list enemy-units)]) (hash-ref e 'y 1600))
                  (length enemy-units))))
  (define pid (add1 (mirror-mind-state-probes-completed mstate)))
  (define p
    (diagnostic-probe pid
                      probe-type
                      frame
                      (+ frame 224)
                      probe-x
                      probe-y
                      base-arch
                      avg-ex
                      avg-ey))
  (set-mirror-mind-state-diagnostic-probes!
   mstate
   (append (mirror-mind-state-diagnostic-probes mstate) (list p)))
  p)

;; Record an observed opponent response to a diagnostic probe and update both
;; `inferred-opponent-depth` (d*) and per-depth accuracies:
;;   - 'no-reaction                      -> d* = 0 (we use active-depth = 1; do NOT over-complicate!)
;;   - 'direct-counter                   -> d* = 1 (we use active-depth = 2)
;;   - 'second-order-pivot-or-cancel     -> d* = 2 (we escalate to active-depth = 3)
;;   - 'higher-order-bait-or-double-reverse -> d* = 3+ (we escalate to active-depth = 4..5!)
(define (record-diagnostic-probe-response! mstate response-sym)
  (define d-acc (mirror-mind-state-depth-accuracies mstate))
  (set-mirror-mind-state-last-probe-response! mstate response-sym)
  (set-mirror-mind-state-probes-completed!
   mstate (add1 (mirror-mind-state-probes-completed mstate)))
  (case response-sym
    [(no-reaction)
     ;; Opponent is executing a fixed 0/1-level script — Occam's Razor: step down to Depth 1!
     (set-mirror-mind-state-inferred-opponent-depth! mstate 0)
     (hash-set! d-acc 1 (min 0.96 (+ (hash-ref d-acc 1 0.64) 0.14)))
     (hash-set! d-acc 2 (max 0.25 (- (hash-ref d-acc 2 0.68) 0.10)))]
    [(direct-counter)
     ;; Opponent reacts directly to what we show (d* = 1) -> we play Depth 2
     (set-mirror-mind-state-inferred-opponent-depth! mstate 1)
     (hash-set! d-acc 2 (min 0.96 (max (+ (hash-ref d-acc 1 0.64) 0.04)
                                       (+ (hash-ref d-acc 2 0.68) 0.12))))]
    [(second-order-pivot-or-cancel)
     ;; Opponent anticipates our counter to what we scouted (d* = 2) -> we play Depth 3
     (set-mirror-mind-state-inferred-opponent-depth! mstate 2)
     (hash-set! d-acc 3 (min 0.96 (max (+ (hash-ref d-acc 2 0.68) 0.08)
                                       (+ (hash-ref d-acc 3 0.62) 0.16))))]
    [(higher-order-bait-or-double-reverse)
     ;; Elite opponent staging false tells / double-reversals ("they know that I know
     ;; that they know that I know") -> escalate opponent depth d* up to 3..4 (our depth 4..5)!
     (define prev-opp-d (mirror-mind-state-inferred-opponent-depth mstate))
     (define new-opp-d (min 4 (max 3 (add1 prev-opp-d))))
     (set-mirror-mind-state-inferred-opponent-depth! mstate new-opp-d)
     (define target-our-d (add1 new-opp-d))
     (hash-set! d-acc target-our-d
                (min 0.96 (+ (hash-ref d-acc target-our-d 0.58) 0.20)))])
  (choose-optimal-mirror-depth mstate))

;; Evaluate any pending diagnostic probes whose observation window has elapsed
(define (evaluate-pending-diagnostic-probes! mstate frame enemy-units reading)
  (define probes (mirror-mind-state-diagnostic-probes mstate))
  (define remaining '())
  (for ([p (in-list probes)])
    (cond
      [(>= frame (diagnostic-probe-deadline-frame p))
       (define cur-arch (classify-enemy-archetype enemy-units))
       (define avg-ex
         (if (null? enemy-units)
             (diagnostic-probe-baseline-enemy-x p)
             (quotient (for/sum ([e (in-list enemy-units)]) (hash-ref e 'x 1600))
                       (length enemy-units))))
       (define avg-ey
         (if (null? enemy-units)
             (diagnostic-probe-baseline-enemy-y p)
             (quotient (for/sum ([e (in-list enemy-units)]) (hash-ref e 'y 1600))
                       (length enemy-units))))
       (define move-delta
         (dist2d (diagnostic-probe-baseline-enemy-x p)
                 (diagnostic-probe-baseline-enemy-y p)
                 avg-ex avg-ey))
       (define arch-changed?
         (not (eq? cur-arch (diagnostic-probe-baseline-enemy-arch p))))
       (define feint?
         (and reading (action-lens-reading-feint-or-poke-detected? reading)))
       (define scouted?
         (and reading (action-lens-reading-opponent-scouted-us? reading)))
       (define inferred-resp
         (cond
           [(and feint? arch-changed?) 'higher-order-bait-or-double-reverse]
           [(and scouted? (or arch-changed? (> move-delta 220))) 'second-order-pivot-or-cancel]
           [(or arch-changed? (> move-delta 120)) 'direct-counter]
           [else 'no-reaction]))
       (record-diagnostic-probe-response! mstate inferred-resp)]
      [else
       (set! remaining (cons p remaining))]))
  (set-mirror-mind-state-diagnostic-probes! mstate (reverse remaining)))

;; Dynamically choose the active depth level based on:
;;   1. Occam's Razor Low-End Guard: Do NOT over-complicate past Depth 1 when
;;      the opponent shows 'no-reaction or Depth 1 outperforms Depth 2.
;;   2. Default Competitive Depth (usually 2).
;;   3. High-End Multi-Layer Escalation (Depth 3, 4, 5): When diagnostic probes
;;      detect higher-order baiting/double-reversals or higher-depth accuracy leads.
(define (choose-optimal-mirror-depth mstate)
  (define def-d (mirror-mind-state-default-depth mstate))
  (cond
    [(not (mirror-mind-state-auto-adapt-depth? mstate))
      (set-mirror-mind-state-active-depth! mstate def-d)
      def-d]
    [else
     (define d-acc (mirror-mind-state-depth-accuracies mstate))
     (define acc-1 (hash-ref d-acc 1 0.64))
     (define acc-2 (hash-ref d-acc 2 0.68))
     (define acc-3 (hash-ref d-acc 3 0.62))
     (define acc-4 (hash-ref d-acc 4 0.58))
     (define acc-5 (hash-ref d-acc 5 0.55))
     (define overall (mirror-mind-state-overall-accuracy mstate))
     (define probe-resp (mirror-mind-state-last-probe-response mstate))
     (define opp-d (mirror-mind-state-inferred-opponent-depth mstate))
     (define chosen
       (cond
         ;; Low-End Occam's Razor: opponent ignores probes ('no-reaction) or accuracy is low -> Depth 1!
         [(eq? probe-resp 'no-reaction) 1]
         [(< overall 0.45) 1]
         [(and (not (eq? probe-resp 'direct-counter))
               (> acc-1 (+ acc-2 0.08)))
          1]
         ;; Extreme High-End Escalation ("they know that I know that they know that I know"):
         [(and (eq? probe-resp 'higher-order-bait-or-double-reverse) (>= opp-d 4)) 5]
         [(or (eq? probe-resp 'higher-order-bait-or-double-reverse)
              (>= opp-d 3)
              (> acc-4 (+ acc-3 0.06)))
          4]
         [(or (eq? probe-resp 'second-order-pivot-or-cancel)
              (= opp-d 2)
              (and (>= acc-2 0.70) (> acc-3 (+ acc-2 0.06))))
          3]
         [(eq? probe-resp 'direct-counter) 2]
         [(and (> def-d 2) (>= (hash-ref d-acc def-d 0.60) 0.58))
          def-d]
         [else def-d]))
     (set-mirror-mind-state-active-depth! mstate chosen)
     chosen]))

;; Compute the Snowball-Bounded Toolbox Allocation:
;; Ensures that in a snowball game like StarCraft II, Mirror-Mind depth is NEVER
;; the main strategic or tactical determinant — just a bounded tool in the toolbox
;; (strictly <= 0.25 weight, 0.0 during crisis, 0.08 when snowballing ahead, and
;; allow-posture-override? = #f always).
(define (compute-mirror-toolbox-allocation mstate ally-units enemy-units
                                           #:crisis? [crisis? #f])
  (define worker-syms '(drone scv probe))
  (define ally-combat
    (filter (lambda (u) (not (memq (unit-type-sym u) worker-syms))) ally-units))
  (define enemy-combat
    (filter (lambda (u) (not (memq (unit-type-sym u) worker-syms))) enemy-units))
  (define ally-power
    (for/sum ([u (in-list ally-combat)])
      (* (max 10 (hash-ref u 'hp 45)) (max 4 (hash-ref u 'dps 8)))))
  (define enemy-power
    (for/sum ([u (in-list enemy-combat)])
      (* (max 10 (hash-ref u 'hp 45)) (max 4 (hash-ref u 'dps 8)))))
  (define lanchester-ratio
    (cond
      [(and (zero? ally-power) (zero? enemy-power)) 1.0]
      [(zero? enemy-power) 2.0]
      [else (exact->inexact (/ ally-power (max 1 enemy-power)))]))

  (define snowball-state
    (cond
      [(or crisis? (< lanchester-ratio 0.55)) 'crisis-deficit]
      [(>= lanchester-ratio 1.45)             'snowball-advantage]
      [else                                   'contested-even]))

  (define overall-acc (mirror-mind-state-overall-accuracy mstate))
  (define active-d (mirror-mind-state-active-depth mstate))
  (define raw-weight
    (cond
      ;; Existential crisis: 0% mind-games, 100% survival macro & direct defense!
      [(eq? snowball-state 'crisis-deficit) 0.0]
      ;; Decisive Lanchester snowball lead: don't get cute or over-pivot; keep 8% watchtower weight
      [(eq? snowball-state 'snowball-advantage) 0.08]
      ;; Low-depth opponent (Depth 1) or skeptical fallback: capped at 10% direct counter weight
      [(or (<= active-d 1) (< overall-acc 0.50)) 0.10]
      ;; Contested even game: bounded toolbox hedge in [0.12, 0.25]
      [else
       (min 0.25 (max 0.12 (* 0.28 (- overall-acc 0.35))))]))

  (define primary-macro-w (- 1.0 raw-weight))
  (define role
    (cond
      [(eq? snowball-state 'crisis-deficit)     'survival-fundamentals-only]
      [(eq? snowball-state 'snowball-advantage) 'snowball-watchtower-only]
      [(<= active-d 1)                          'depth1-direct-counter-only]
      [else                                     'marginal-toolbox-hedge]))
  (define allow-hedge? (and (>= raw-weight 0.12) (eq? role 'marginal-toolbox-hedge)))
  (define alloc
    (mirror-toolbox-allocation lanchester-ratio
                               snowball-state
                               raw-weight
                               primary-macro-w
                               role
                               allow-hedge?
                               #f))
  (set-mirror-mind-state-toolbox-allocation! mstate alloc)
  alloc)

;; Compatibility wrapper returning (values predicted-enemy-unit chosen-counter-unit d0-counter-unit)
(define (infer-mirror-counter-plan mstate ally-units enemy-units
                                   #:depth [depth-override #f]
                                   #:our-minerals [our-minerals 300]
                                   #:our-gas [our-gas 150]
                                   #:our-tech [our-tech ALL-RATIONAL-TECH])
  (define obs (hash 'ally-units ally-units
                    'ally-buildings '()
                    'enemy-units enemy-units))
  (define chosen-d (or depth-override (choose-optimal-mirror-depth mstate)))
  (define nodes
    (build-mirror-hierarchy mstate obs
                            #:max-depth (max 4 chosen-d (mirror-mind-state-default-depth mstate))
                            #:our-tech our-tech
                            #:our-minerals our-minerals
                            #:our-gas our-gas))
  (define active-node
    (or (findf (lambda (n) (= (depth-node-depth n) chosen-d)) nodes)
        (last nodes)))
  (define d0-node (first nodes))

  (set-mirror-mind-state-opp-belief-about-us!
   mstate (depth-node-opp-belief-about-us active-node))
  (set-mirror-mind-state-predicted-enemy-unit!
   mstate (depth-node-predicted-enemy-unit active-node))

  ;; Modulate final unit commitment by trust-mode & toolbox allocation
  (define alloc (compute-mirror-toolbox-allocation mstate ally-units enemy-units))
  (define final-counter-unit
    (cond
      [(or (eq? (mirror-mind-state-trust-mode mstate) 'skeptical-observational-fallback)
           (eq? (mirror-toolbox-allocation-toolbox-role alloc) 'survival-fundamentals-only))
       (depth-node-our-response-unit d0-node)]
      [else
       (depth-node-our-response-unit active-node)]))

  (set-mirror-mind-state-preemptive-counter-unit! mstate final-counter-unit)
  (values (depth-node-predicted-enemy-unit active-node)
          final-counter-unit
          (depth-node-our-response-unit d0-node)))

;; =============================================================================
;; 6. Component 4: Tactical Vulnerability Mirror (`predict-opponent-tactical-target`)
;; =============================================================================

(define (predict-opponent-tactical-target mstate obs)
  (define active-d (mirror-mind-state-active-depth mstate))
  (define node (predict-at-depth mstate active-d obs))
  (define target-sym (depth-node-tactical-target node))
  (define tx (depth-node-target-x node))
  (define ty (depth-node-target-y node))
  (set-mirror-mind-state-tactical-target! mstate target-sym)
  (set-mirror-mind-state-tactical-x! mstate tx)
  (set-mirror-mind-state-tactical-y! mstate ty)
  (values target-sym tx ty))

;; =============================================================================
;; 7. Component 5: Closed-Loop Forecast Resolution & Per-Depth Accuracy
;; =============================================================================

(define (select-mirror-trust-mode overall-acc)
  (cond
    [(>= overall-acc 0.65) 'level2-preemptive-mirror]
    [(>= overall-acc 0.45) 'balanced-bayesian-hedged]
    [else                  'skeptical-observational-fallback]))

(define (resolve-pending-forecasts! mstate frame enemy-units enemy-bldgs)
  (define pending (mirror-mind-state-pending-forecasts mstate))
  (define d-acc (mirror-mind-state-depth-accuracies mstate))
  (define all-enemy (append enemy-units enemy-bldgs))
  (define enemy-types (map unit-type-sym all-enemy))
  (define observed-arch (classify-enemy-archetype enemy-units))
  (define alpha 0.25)

  (define still-pending '())
  (for ([fc (in-list pending)])
    (define fc-depth (mirror-forecast-depth fc))
    (define pred-unit (mirror-forecast-predicted-enemy-unit fc))
    (define pred-arch (unit-to-archetype pred-unit))
    (define tx (mirror-forecast-target-x fc))
    (define ty (mirror-forecast-target-y fc))
    (define deadline (mirror-forecast-deadline-frame fc))

    (define strat-hit?
      (or (memq pred-unit enemy-types)
          (and (not (null? enemy-units))
               (eq? pred-arch observed-arch))))

    (define tact-hit?
      (ormap (lambda (e)
               (<= (dist2d tx ty (hash-ref e 'x 1600) (hash-ref e 'y 1600)) 360))
             all-enemy))

    (cond
      [(or strat-hit? tact-hit?)
       (define new-strat
         (+ (* (- 1.0 alpha) (mirror-mind-state-strategic-accuracy mstate))
            (* alpha (if strat-hit? 1.0 0.75))))
       (define new-tact
         (+ (* (- 1.0 alpha) (mirror-mind-state-tactical-accuracy mstate))
            (* alpha (if tact-hit? 1.0 0.75))))
       (set-mirror-mind-state-strategic-accuracy! mstate (min 0.98 new-strat))
       (set-mirror-mind-state-tactical-accuracy! mstate (min 0.98 new-tact))
       ;; Update per-depth accuracy for `fc-depth`
       (define old-d-acc (hash-ref d-acc fc-depth 0.65))
       (hash-set! d-acc fc-depth (min 0.98 (+ (* (- 1.0 alpha) old-d-acc) (* alpha 1.0))))
       (set-mirror-mind-state-resolved-hits!
        mstate (add1 (mirror-mind-state-resolved-hits mstate)))
       (set-mirror-mind-state-resolved-total!
        mstate (add1 (mirror-mind-state-resolved-total mstate)))]

      [(> frame deadline)
       (when (not (null? enemy-units))
         (define new-strat
           (* (- 1.0 alpha) (mirror-mind-state-strategic-accuracy mstate)))
         (define new-tact
           (* (- 1.0 alpha) (mirror-mind-state-tactical-accuracy mstate)))
         (set-mirror-mind-state-strategic-accuracy! mstate (max 0.15 new-strat))
         (set-mirror-mind-state-tactical-accuracy! mstate (max 0.15 new-tact))
         (define old-d-acc (hash-ref d-acc fc-depth 0.65))
         (hash-set! d-acc fc-depth (max 0.15 (* (- 1.0 alpha) old-d-acc)))
         (set-mirror-mind-state-resolved-total!
          mstate (add1 (mirror-mind-state-resolved-total mstate))))]

      [else
       (set! still-pending (cons fc still-pending))]))

  (set-mirror-mind-state-pending-forecasts! mstate (reverse still-pending))
  (define overall
    (+ (* 0.55 (mirror-mind-state-strategic-accuracy mstate))
       (* 0.45 (mirror-mind-state-tactical-accuracy mstate))))
  (set-mirror-mind-state-overall-accuracy! mstate overall)
  (set-mirror-mind-state-trust-mode! mstate (select-mirror-trust-mode overall))
  (choose-optimal-mirror-depth mstate)
  overall)

;; =============================================================================
;; 8. Top-Level Step (`step-mirror-mind-predictor!`)
;; =============================================================================

(define (step-mirror-mind-predictor! mstate obs)
  (define frame (hash-ref obs 'frame 0))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define minerals (hash-ref obs 'minerals 200))
  (define gas (hash-ref obs 'gas 100))
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))

  ;; Auto-detect enemy race from observed enemy units/buildings
  (define detected-enemy-race
    (for/or ([e (in-list (append enemy-units enemy-bldgs))])
      (case (unit-type-sym e)
        [(probe zealot stalker sentry adept high-templar dark-templar archon
          immortal colossus void-ray carrier oracle phoenix nexus pylon gateway
          cybernetics-core photon-cannon stargate robotics-facility)
         'Protoss]
        [(scv marine marauder reaper ghost hellion widow-mine cyclone siege-tank
          thor viking medivac banshee battlecruiser command-center orbital-command
          supply-depot barracks factory starport bunker)
         'Terran]
        [(drone zergling baneling queen roach ravager hydralisk lurker mutalisk
          corruptor ultralisk brood-lord overlord overseer hatchery lair hive
          spawning-pool roach-warren hydralisk-den spire)
         'Zerg]
        [else #f])))
  (when detected-enemy-race
    (set-mirror-mind-state-enemy-race! mstate detected-enemy-race))

  ;; 1. Resolve any pending forecasts against current observations
  (resolve-pending-forecasts! mstate frame enemy-units enemy-bldgs)

  ;; 2. Compute Opponent Shadow Economy & Dark-Matter Resource Ledger
  (define ledger
    (compute-opponent-shadow-ledger mstate frame enemy-units enemy-bldgs
                                    #:base-x base-x #:base-y base-y))

  ;; 3. Interpret Observed Opponent Actions through Rational Lens
  (define reading
    (interpret-opponent-actions mstate frame enemy-units enemy-bldgs ledger
                                #:base-x base-x #:base-y base-y
                                #:nat-x nat-x #:nat-y nat-y))

  ;; 3b. Evaluate pending diagnostic probes & periodically issue a new test probe
  (evaluate-pending-diagnostic-probes! mstate frame enemy-units reading)
  (when (and (> frame 672)
             (null? (mirror-mind-state-diagnostic-probes mstate))
             (zero? (modulo frame 1344)))
    (issue-diagnostic-depth-probe! mstate frame enemy-units
                                   #:probe-type 'feint-tempo-probe
                                   #:probe-x nat-x
                                   #:probe-y nat-y))

  (define strat-hyp (action-lens-reading-inferred-intent reading))
  (set-mirror-mind-state-strategic-hypothesis! mstate strat-hyp)

  ;; 4. Compute Snowball-Bounded Toolbox Allocation (depth is just a tool, <= 25% weight)
  (define crisis-now? (action-lens-reading-proxy-or-rush-detected? reading))
  (define alloc
    (compute-mirror-toolbox-allocation mstate ally-units enemy-units #:crisis? crisis-now?))

  ;; 5. Build full recursive k-level hierarchy (d = 0, 1, 2, 3, 4, ...) and select active depth
  (define our-tech-syms (map unit-type-sym ally-bldgs))
  (define eff-tech (if (null? our-tech-syms) ALL-RATIONAL-TECH our-tech-syms))
  (define active-d (choose-optimal-mirror-depth mstate))
  (define nodes
    (build-mirror-hierarchy mstate obs
                            #:max-depth (max 4 active-d)
                            #:our-tech eff-tech
                            #:our-minerals minerals
                            #:our-gas gas))
  (define active-node
    (or (findf (lambda (n) (= (depth-node-depth n) active-d)) nodes)
        (last nodes)))
  (define d0-node (first nodes))

  (define pred-enemy-unit (depth-node-predicted-enemy-unit active-node))
  (define chosen-counter-unit
    (if (or (eq? (mirror-mind-state-trust-mode mstate) 'skeptical-observational-fallback)
            (eq? (mirror-toolbox-allocation-toolbox-role alloc) 'survival-fundamentals-only))
        (depth-node-our-response-unit d0-node)
        (depth-node-our-response-unit active-node)))
  (define tact-target (depth-node-tactical-target active-node))
  (define tx (depth-node-target-x active-node))
  (define ty (depth-node-target-y active-node))

  (set-mirror-mind-state-opp-belief-about-us!
   mstate (depth-node-opp-belief-about-us active-node))
  (set-mirror-mind-state-predicted-enemy-unit! mstate pred-enemy-unit)
  (set-mirror-mind-state-preemptive-counter-unit! mstate chosen-counter-unit)
  (set-mirror-mind-state-tactical-target! mstate tact-target)
  (set-mirror-mind-state-tactical-x! mstate tx)
  (set-mirror-mind-state-tactical-y! mstate ty)

  ;; 6. Enqueue timestamped forecasts for depths 1..4 so we can compare
  ;;    which depth level best predicts this specific opponent!
  (when (< (length (mirror-mind-state-pending-forecasts mstate)) 12)
    (define new-fcs
      (for/list ([n (in-list nodes)]
                 #:when (and (>= (depth-node-depth n) 1)
                             (<= (depth-node-depth n) 4)))
        (mirror-forecast frame
                         (+ frame 1344)
                         (depth-node-depth n)
                         (depth-node-strategic-hypothesis n)
                         (depth-node-predicted-enemy-unit n)
                         (depth-node-tactical-target n)
                         (depth-node-target-x n)
                         (depth-node-target-y n))))
    (set-mirror-mind-state-pending-forecasts!
     mstate
     (append (mirror-mind-state-pending-forecasts mstate) new-fcs)))

  ;; 7. Emit Mirror-Mind S-expression directives (including active depth `active-d` and toolbox role)
  (define acc-pct
    (exact-round (* 100.0 (mirror-mind-state-overall-accuracy mstate))))
  (define trust-mode (mirror-mind-state-trust-mode mstate))

  (define actions
    (list (list 'mirror-prediction
                active-d
                strat-hyp
                tact-target
                pred-enemy-unit
                chosen-counter-unit
                acc-pct
                trust-mode
                (mirror-mind-state-inferred-opponent-depth mstate)
                (exact-round (* 100.0 (mirror-toolbox-allocation-toolbox-weight alloc)))
                (mirror-toolbox-allocation-toolbox-role alloc))))

  (define scout-actions
    (if (or (eq? trust-mode 'skeptical-observational-fallback)
            (memq (shadow-ledger-dark-matter-hypothesis ledger)
                  '(hidden-expansion-or-macro-boom hidden-air-or-cloak-tech-switch)))
        (list (list 'scout-sector 1 enemy-x enemy-y)
              (list 'scout-sector 2 tx ty))
        '()))

  (append actions scout-actions))
