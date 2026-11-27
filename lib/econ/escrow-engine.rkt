#lang racket/base

;; =============================================================================
;; General Time-Horizon Slack Escrow & Closed-Loop Flow Allocation Engine
;; (Loop 88A)
;;
;; Single physics-driven engine replacing ad-hoc `*-ignores-*-escrow?` bypasses,
;; `pure-gas-starved?` magic cutoffs, static bank-threshold gas pulls, and
;; Zeno's-Paradox worker drains:
;;   1. Live LotV Income Rate Estimator (`compute-live-income-rates`)
;;   2. Time-Horizon Slack Escrow (`compute-escrow-slack`, `escrow-allows-disjoint-spend?`)
;;   3. Closed-Loop Flow Production & Expansion Governor (`compute-flow-balance`)
;;   4. Forward In-Progress Tech Lookahead (`compute-forward-tech-demand`)
;;   5. Closed-Loop Physical-Refusal Guard (`refusal-active?`)
;; =============================================================================

(require racket/list
         racket/match
         "../sc2-game-constants.rkt"
         "../plan/macro-game-plan.rkt")

(provide (struct-out escrow-slack-result)
         (struct-out escrow-flow-report)
         SC2-MINERAL-RATE-PER-WORKER-MIN
         SC2-GAS-RATE-PER-WORKER-MIN
         SC2-MULE-MIN-RATE-PER-ORBITAL-MIN
         DEFAULT-ESCROW-HORIZON-SEC
         DEFAULT-T0-PROTECT-SEC
         DEFAULT-FORWARD-TECH-LOOKAHEAD-SEC
         compute-live-income-rates
         refusal-active?
         compute-escrow-slack
         escrow-allows-disjoint-spend?
         compute-forward-tech-demand
         compute-flow-balance
         escrow-flow-report->sat-kwargs)

;; LotV SC2 engine steady-state harvesting physics constants:
;;   - Saturated mineral worker: ~58 minerals/min (~0.967 M/sec)
;;   - Gas worker: ~54 gas/min (~0.90 G/sec)
;;   - Orbital Command MULE (225M / 64s ~ 210 M/min steady state per active OC)
(define SC2-MINERAL-RATE-PER-WORKER-MIN 58.0)
(define SC2-GAS-RATE-PER-WORKER-MIN     54.0)
(define SC2-MULE-MIN-RATE-PER-ORBITAL-MIN 210.0)

(define DEFAULT-ESCROW-HORIZON-SEC 26.0) ; governor-param: covers 150G upgrade on 2 geysers (~24s)
(define DEFAULT-CORE-ESCROW-HORIZON-SEC 36.0)
(define DEFAULT-T0-PROTECT-SEC 2.5) ; governor-param: blocks Zeno's Paradox (<2.5s funding lock) while allowing early 3s+ disjoint workers
(define DEFAULT-CORE-GAS-LOCK-SEC 6.0) ; governor-param: no unmined-mineral borrow on reported floor in final 6s of T1 core gas
(define DEFAULT-FORWARD-TECH-LOOKAHEAD-SEC 25.0)
(define FLOW-DEMAND-HORIZON-SEC 30.0) ; physics: 30s steady-state resource flow horizon (0.5 min)

(struct escrow-slack-result
  (should-escrow?      ;; boolean: #f if unfundable past horizon or physically refused
   t-min-sec           ;; flonum: seconds to gather mineral deficit
   t-gas-sec           ;; flonum: seconds to gather gas deficit
   t-fund-sec          ;; flonum: max(t-min-sec, t-gas-sec)
   mineral-slack       ;; flonum: minerals spendable now with 0-frame delay to A
   gas-slack           ;; flonum: gas spendable now with 0-frame delay to A
   gas-bound?          ;; boolean: t-gas-sec > t-min-sec + 1.5s
   near-ready?         ;; boolean: t-fund-sec <= DEFAULT-T0-PROTECT-SEC
   effective-min-floor ;; exact-nonnegative-integer
   effective-gas-floor);; exact-nonnegative-integer
  #:transparent)

(struct escrow-flow-report
  (m-rate-per-min          ;; flonum
   g-rate-per-min          ;; flonum
   m-drain-per-min         ;; flonum (active production + workers)
   g-drain-per-min         ;; flonum (active production)
   forward-tech-m-per-min  ;; flonum (imminent completing tech <= 25s)
   forward-tech-g-per-min  ;; flonum (imminent completing tech <= 25s)
   mineral-demand-rate     ;; flonum (m-drain + forward-tech-m)
   gas-demand-rate         ;; flonum (g-drain + forward-tech-g)
   desired-gas-workers     ;; exact-nonnegative-integer (closed-form G* for worker-saturation-policy)
   need-more-production?   ;; boolean (M_rate > 1.15 * M_drain)
   need-more-gas-geysers?  ;; boolean (G_demand > 1.15 * G_rate and open geysers exist)
   need-expansion?         ;; boolean (saturation >= 85%, depleting, or OWM/Pro base target ahead)
   forward-tech-gas-reserve) ;; exact-nonnegative-integer (gas to pre-bank for imminent Spire/FTL/RoboBay)
  #:transparent)

(define (safe-count ht sym)
  (if (hash? ht)
      (let ([v (hash-ref ht sym 0)])
        (if (real? v) (max 0 (inexact->exact (floor v))) 0))
      0))

;; 1. Live Income Rate Estimation (returns m-rate-per-sec, g-rate-per-sec)
(define (compute-live-income-rates mineral-harvesters gas-harvesters workers ready-bldg-counts race)
  (define g-bldgs
    (+ (safe-count ready-bldg-counts 'extractor)
       (safe-count ready-bldg-counts 'assimilator)
       (safe-count ready-bldg-counts 'refinery)))
  (define harv-explicit?
    (or (and (exact-integer? mineral-harvesters) (> mineral-harvesters 0))
        (and (exact-integer? gas-harvesters) (> gas-harvesters 0))))
  (define est-g-harv
    (if harv-explicit?
        (min (max 0 (if (exact-integer? gas-harvesters) gas-harvesters 0)) (* 3 g-bldgs))
        (min (max 0 (quotient workers 4)) (* 3 g-bldgs))))
  (define est-m-harv
    (if (and (exact-integer? mineral-harvesters) (> mineral-harvesters 0))
        (if (> workers 0)
            (min mineral-harvesters (max 0 (- workers est-g-harv)))
            mineral-harvesters)
        (max 0 (- workers est-g-harv))))
  (define oc-cnt (if (eq? race 'Terran) (safe-count ready-bldg-counts 'orbital-command) 0))
  (define m-per-min
    (+ (* (exact->inexact est-m-harv) SC2-MINERAL-RATE-PER-WORKER-MIN)
       (* (exact->inexact oc-cnt) SC2-MULE-MIN-RATE-PER-ORBITAL-MIN)))
  (define g-per-min
    (* (exact->inexact est-g-harv) SC2-GAS-RATE-PER-WORKER-MIN))
  (values (/ m-per-min 60.0) (/ g-per-min 60.0)))

;; 2. Closed-Loop Physical Refusal Check
;; Accepts #f, a hash mapping sym -> ttl-frame / (cons reason ttl-frame) / #t,
;; or a raw wire refusal list of (list bldg-sym reason cur-loop) with 112-frame TTL.
(define WIRE-REFUSAL-DEFAULT-TTL-FRAMES 112) ; physics: 5s at 22.4 fps

(define (refusal-active? physical-refusals sym frame)
  (and (symbol? sym)
       (cond
         [(hash? physical-refusals)
          (let ([entry (hash-ref physical-refusals sym #f)])
            (cond
              [(exact-integer? entry) (>= entry frame)]
              [(real? entry) (>= entry frame)]
              [(and (pair? entry) (real? (cdr entry))) (>= (cdr entry) frame)]
              [(eq? entry #t) #t]
              [else #f]))]
         [(list? physical-refusals)
          (ormap (lambda (tup)
                   (and (list? tup)
                        (>= (length tup) 3)
                        (eq? (car tup) sym)
                        (real? (caddr tup))
                        (>= (+ (caddr tup) WIRE-REFUSAL-DEFAULT-TTL-FRAMES) frame)))
                 physical-refusals)]
         [else #f])))

;; 3. Time-Horizon Slack Escrow Calculation
;; Computes exact funding time T_fund(A) and zero-delay disjoint-slot slack
;; (M_slack, G_slack). Never holds blocking escrow on physically refused items
;; or items unfundable within horizon.
(define (compute-escrow-slack
         #:item-sym item-sym
         #:item-min-cost a-min
         #:item-gas-cost a-gas
         #:tier [tier 'T2]
         #:rem-min rem-min
         #:rem-gas rem-gas
         #:m-rate-sec m-rate
         #:g-rate-sec g-rate
         #:frame [frame 0]
         #:physical-refusals [physical-refusals #f]
         #:horizon-sec [horizon-sec #f]
         #:protect-sec [protect-sec DEFAULT-T0-PROTECT-SEC])
  (define mc (max 0.0 (exact->inexact a-min)))
  (define gc (max 0.0 (exact->inexact a-gas)))
  (define rm (max 0.0 (exact->inexact rem-min)))
  (define rg (max 0.0 (exact->inexact rem-gas)))
  (define mr (max 0.0 (exact->inexact m-rate)))
  (define gr (max 0.0 (exact->inexact g-rate)))
  (define m-def (max 0.0 (- mc rm)))
  (define g-def (max 0.0 (- gc rg)))
  (define t-min
    (cond
      [(<= m-def 0.0) 0.0]
      [(<= mr 0.01) +inf.0]
      [else (/ m-def mr)]))
  (define t-gas
    (cond
      [(<= g-def 0.0) 0.0]
      [(<= gr 0.01) +inf.0]
      [else (/ g-def gr)]))
  (define t-fund (max t-min t-gas))
  (define max-h
    (if (real? horizon-sec)
        (exact->inexact horizon-sec)
        (case tier
          [(T0) 60.0] ; governor-param: T0 survival/core horizon
          [(T1) DEFAULT-CORE-ESCROW-HORIZON-SEC]
          [else DEFAULT-ESCROW-HORIZON-SEC])))
  (define refused? (refusal-active? physical-refusals item-sym frame))
  (define fundable? (and (not refused?) (<= t-fund max-h)))
  (define near-ready? (<= t-fund (exact->inexact protect-sec)))
  (define mineral-near-ready? (and (> m-def 0.0) near-ready?))
  (define core-gas-near-ready? (and (eq? tier 'T1) (> g-def 0.0) (<= t-gas DEFAULT-CORE-GAS-LOCK-SEC)))
  (define gas-bound? (and (> g-def 0.0) (> t-gas (+ t-min 1.5))))
  (define-values (m-slack g-slack)
    (cond
      [(not fundable?) (values rm rg)]
      [(or (eq? tier 'T0) mineral-near-ready?) (values 0.0 0.0)]
      [else
       (values (max 0.0 (- (+ rm (* mr t-fund)) mc))
               (max 0.0 (- (+ rg (* gr t-fund)) gc)))]))
  (define eff-m-floor
    (cond
      [(not fundable?) 0]
      [(or (eq? tier 'T0) mineral-near-ready? core-gas-near-ready? (<= m-slack 0.5))
       (max 0 (inexact->exact (ceiling mc)))]
      [else (max 0 (inexact->exact (floor (- rm m-slack))))]))
  (define eff-g-floor
    (cond
      [(not fundable?) 0]
      [(<= gc 0.0) 0]
      [(or (> g-def 0.0) (<= g-slack 0.5))
       (max 0 (inexact->exact (ceiling gc)))]
      [else (max 0 (inexact->exact (floor (- rg g-slack))))]))
  (escrow-slack-result
   fundable? t-min t-gas t-fund m-slack g-slack gas-bound? near-ready?
   eff-m-floor eff-g-floor))

;; Pure general check: may candidate B (cost b-min/b-gas on producer slot b-slot)
;; spend alongside escrowed goal A (slack-res on slot a-slot) without delaying A?
(define (escrow-allows-disjoint-spend?
         slack-res
         #:a-slot a-slot
         #:a-tier [a-tier 'T2]
         #:a-cat [a-cat 'combat-unit]
         #:b-slot b-slot
         #:b-cat b-cat
         #:b-min-cost b-min
         #:b-gas-cost b-gas
         #:m-rate-sec [m-rate 0.0]
         #:rem-min [rem-min 0]
         #:rem-gas [rem-gas 0]
         #:open-larva-cnt [open-larva-cnt 0]
         #:open-slot-cnt [open-slot-cnt 1])
  (define bm (max 0.0 (exact->inexact b-min)))
  (define bg (max 0.0 (exact->inexact b-gas)))
  (define surplus-larva-gas-bound?
    (and (eq? b-slot 'larva)
         (eq? a-slot 'larva)
         (>= open-larva-cnt 3)
         (escrow-slack-result-gas-bound? slack-res)))
  (define surplus-facility-gas-bound?
    (and (eq? b-slot a-slot)
         (not (memq b-slot '(worker larva)))
         (>= open-slot-cnt 2)
         (escrow-slack-result-gas-bound? slack-res)))
  (define disjoint-slot?
    (or (not (eq? b-slot a-slot))
        surplus-larva-gas-bound?
        surplus-facility-gas-bound?))
  (define worker-walk-slack
    ;; Physics: a worker walking ~3-4 tiles to place a gas-bound building takes ~1s
    ;; before deducting minerals on the map, giving +1.0s * m-rate extra mineral slack.
    (if (and (eq? a-slot 'worker)
             (not (eq? a-tier 'T0))
             (escrow-slack-result-gas-bound? slack-res))
        (* 1.0 (max 0.0 (exact->inexact m-rate)))
        0.0))
  (cond
    [(not (escrow-slack-result-should-escrow? slack-res)) #t]
    [(eq? b-cat 'supply) #t]
    [(not disjoint-slot?) #f]
    [(and (<= bm (+ (escrow-slack-result-mineral-slack slack-res) worker-walk-slack))
          (<= bg (escrow-slack-result-gas-slack slack-res)))
     #t]
    ;; Disjoint P/T TownHall worker (50M/0G) during non-T0 escrow ONLY when A is
    ;; NOT within the 3.5s funding lock (eliminates Zeno's Paradox where 50M SCV
    ;; steals the last 26M from a 100M Medivac 1.5s from funding, while letting
    ;; 3rd/4th expansions >3.5s out keep training workers and pausing within 3.5s!).
    [(and (eq? b-cat 'worker)
          (eq? b-slot 'townhall)
          (= bg 0.0)
          (not (eq? a-tier 'T0))
          (not (eq? a-cat 'supply))
          (not (escrow-slack-result-near-ready? slack-res))
          (>= m-rate 8.0)
          (>= (- rem-min bm) 0))
     #t]
    ;; Disjoint-slot gas-dump combat morph (e.g. Ravager 25M/75G at 520G excess gas)
    ;; during non-T0/T1 late tech escrow (e.g. Hive) when not near-ready.
    [(and (eq? b-cat 'combat-unit)
          (eq? a-tier 'T3)
          (not (escrow-slack-result-near-ready? slack-res))
          (> bg bm)
          (<= bm 25.0) ; physics: low-mineral gas-heavy morph (<=25M)
          (<= bg (escrow-slack-result-gas-slack slack-res))
          (>= (- rem-min bm) 0))
     #t]
    ;; Non-T0 unit-morph escrow (e.g. Ravager morphing from Roach) waiting >3.5s on gas
    ;; never freezes >=3 open Larvae from producing low-gas (<=25G) base army units.
    [(and (eq? b-cat 'combat-unit)
          (eq? b-slot 'larva)
          (memq a-slot '(roach zergling hydralisk corruptor))
          (not (memq a-tier '(T0 T1)))
          (>= open-larva-cnt 3)
          (> (escrow-slack-result-t-gas-sec slack-res) 3.5)
          (<= bg 25.0) ; physics: low-gas base army unit (<=25G)
          (>= (- rem-min bm) 0)
          (>= (- rem-gas bg) 0))
     #t]
    [else #f]))

;; 4. Forward In-Progress Tech Lookahead (<= 25s to completion)
;; `in-progress-tech-etas` is either #f or a hash mapping tech-bldg-sym -> eta-sec.
;; Pre-includes imminent unit/upgrade gas & mineral demand so gas is banked BEFORE
;; Spire / FactoryTechLab / Starport / RoboticsBay / TemplarArchive pops!
(define FORWARD-TECH-DEMAND-TABLE
  (hasheq
   'spire             (cons 240.0 300.0)  ;; ~2-3 Corruptors/Mutalisks burst on pop
   'greater-spire     (cons 225.0 225.0)
   'hydralisk-den     (cons 240.0 150.0)
   'lurker-den        (cons 150.0 240.0)
   'lair              (cons 150.0 150.0)
   'hive              (cons 200.0 200.0)
   'factory-techlab   (cons 220.0 200.0)  ;; Siege Tank / Cyclone cadence on pop
   'starport          (cons 180.0 180.0)  ;; Medivac / Viking / Raven cadence
   'starport-techlab  (cons 150.0 240.0)
   'robotics-facility (cons 275.0 140.0)  ;; Immortal / Observer on pop
   'robotics-bay      (cons 300.0 240.0)  ;; Colossus #1 pre-bank
   'stargate          (cons 250.0 180.0)
   'templar-archive   (cons 150.0 280.0)
   'dark-shrine       (cons 200.0 200.0)))

(define (compute-forward-tech-demand in-progress-tech-etas [lookahead-sec DEFAULT-FORWARD-TECH-LOOKAHEAD-SEC])
  (if (not (hash? in-progress-tech-etas))
      (values 0.0 0.0 0)
      (for/fold ([m-dem 0.0] [g-dem 0.0] [g-res 0])
                ([(sym eta) (in-hash in-progress-tech-etas)])
        (define entry (hash-ref FORWARD-TECH-DEMAND-TABLE sym #f))
        (if (and entry (real? eta) (>= eta 0.0) (<= eta lookahead-sec))
            (let* ([w (max 0.25 (- 1.0 (/ (exact->inexact eta) (max 1.0 lookahead-sec))))]
                   [dm (* w (car entry))]
                   [dg (* w (cdr entry))]
                   [res-add (inexact->exact (round (* w (min 150.0 (* 0.5 (cdr entry))))))])
              (values (+ m-dem dm) (+ g-dem dg) (min 200 (+ g-res res-add))))
            (values m-dem g-dem g-res)))))

;; Pure stoichiometry helper: derives target gas/mineral ratio from declarative
;; `macro-game-plan` comp-mix and sums unbuilt planned tech-root gas costs from
;; SC2 game constants (zero race hardcodes).
(define (compute-plan-gas-stoichiometry plan total-bldg-counts)
  (if (not (macro-game-plan? plan))
      (values 0.0 0.0)
      (let* ([mix (macro-game-plan-comp-mix plan)]
             [roots (macro-game-plan-desired-tech-roots plan)]
             [w-m (for/sum ([(sym w) (in-hash mix)])
                    (* (exact->inexact w) (exact->inexact (sc2-min-cost sym 50))))]
             [w-g (for/sum ([(sym w) (in-hash mix)])
                    (* (exact->inexact w) (exact->inexact (sc2-gas-cost sym 0))))]
             [gas-ratio (if (> w-m 1.0) (min 0.85 (/ w-g w-m)) 0.0)]
             [unbuilt-tech-g
              (for/sum ([r (in-list roots)])
                (if (= (safe-count total-bldg-counts r) 0)
                    (exact->inexact (sc2-gas-cost r 0))
                    0.0))])
        (values gas-ratio (min 300.0 unbuilt-tech-g))))) ; physics: cap 1-min unbuilt tech-root gas queue

;; 5. Closed-Loop Flow Production, Gas Demand & Expansion Governor
(define (compute-flow-balance
         #:plan plan
         #:race race
         #:minerals cur-min
         #:gas cur-gas
         #:workers workers
         #:active-bases active-bases
         #:total-bases total-bases
         #:mineral-harvesters mineral-harvesters
         #:gas-harvesters gas-harvesters
         #:ready-bldg-counts ready-bldg-counts
         #:total-bldg-counts total-bldg-counts
         #:depleting-bases [depleting-bases 0]
         #:in-progress-tech-etas [in-progress-tech-etas #f]
         #:active-escrow-gas-floor [active-escrow-gas-floor 0])
  (define-values (m-rate-sec g-rate-sec)
    (compute-live-income-rates mineral-harvesters gas-harvesters workers ready-bldg-counts race))
  (define m-rate-min (* 60.0 m-rate-sec))
  (define g-rate-min (* 60.0 g-rate-sec))

  ;; Estimate steady-state mineral & gas drain capacity of ready AND in-progress facilities
  ;; using standard SC2 LotV production cycle costs (per minute):
  (define (rc sym) (safe-count ready-bldg-counts sym))
  (define (tc sym) (safe-count total-bldg-counts sym))
  (define (ip sym) (max 0 (- (tc sym) (rc sym))))
  (define comp-mix (if (macro-game-plan? plan) (macro-game-plan-comp-mix plan) (hasheq)))
  (define w-cap (if (macro-game-plan? plan) (macro-game-plan-worker-target-cap plan) 66))
  (define workers-still-needed? (< workers w-cap))

  (define-values (m-drain-min g-drain-min)
    (case race
      [(Terran)
       (define rax-cnt (rc 'barracks))
       (define rax-rx  (rc 'barracks-reactor))
       (define rax-tl  (rc 'barracks-techlab))
       (define fac-cnt (rc 'factory))
       (define fac-tl  (rc 'factory-techlab))
       (define sp-cnt  (rc 'starport))
       (define th-cnt  (max 1 active-bases))
       ;; 18s Marine (50M -> 166M/m; Reactor = 333M/m); 21s Marauder (100M/25G -> 285M/71G/m)
       ;; 32s Tank (150M/125G -> 281M/234G/m); 30s Medivac/Viking (125M/85G -> 250M/170G/m)
       ;; 12s SCV (50M -> 250M/m per CC while < w-cap)
       (define rax-tl-used (min rax-cnt rax-tl))
       (define rax-rx-used (min (max 0 (- rax-cnt rax-tl-used)) rax-rx))
       (define fac-tl-used (min fac-cnt fac-tl))
       (define rax-m (+ (* (max 0 (- rax-cnt rax-rx-used rax-tl-used)) 166.0)
                        (* rax-rx-used 333.0)
                        (* rax-tl-used 260.0)))
       (define rax-g (* rax-tl-used 65.0))
       (define fac-m (+ (* fac-tl-used 270.0) (* (max 0 (- fac-cnt fac-tl-used)) 220.0)))
       (define fac-g (+ (* fac-tl-used 225.0) (* (max 0 (- fac-cnt fac-tl-used)) 75.0)))
       (define sp-m  (* sp-cnt 240.0))
       (define sp-g  (* sp-cnt 175.0))
       (define inprog-g
         (* 0.65 (+ (* (ip 'barracks-techlab) 65.0)
                    (* (ip 'factory) 150.0)
                    (* (ip 'factory-techlab) 150.0)
                    (* (ip 'starport) 175.0))))
       (define scv-m (if workers-still-needed? (* th-cnt 250.0) 0.0))
       (values (+ rax-m fac-m sp-m scv-m) (+ rax-g fac-g sp-g inprog-g))]
      [(Protoss)
       (define gw-cnt (+ (rc 'gateway) (rc 'warp-gate)))
       (define robo-cnt (rc 'robotics-facility))
       (define rbay? (> (rc 'robotics-bay) 0))
       (define sg-cnt (rc 'stargate))
       (define th-cnt (max 1 active-bases))
       ;; Gateway average mix (~28s cycle: Stalker 125M/50G vs Zealot 100M/0G)
       (define w-st (hash-ref comp-mix 'stalker 0.35))
       (define w-ze (hash-ref comp-mix 'zealot 0.20))
       (define gw-gas-frac (/ w-st (max 0.1 (+ w-st w-ze))))
       (define gw-m (* gw-cnt (+ (* gw-gas-frac 265.0) (* (- 1.0 gw-gas-frac) 215.0))))
       (define gw-g (* gw-cnt (* gw-gas-frac 108.0)))
       ;; Robo: Immortal (275M/100G / 39s -> 423M/154G/m) or Colossus (300M/200G / 54s -> 333M/222G/m)
       (define robo-m (* robo-cnt (if rbay? 360.0 400.0)))
       (define robo-g (* robo-cnt (if rbay? 210.0 155.0)))
       (define sg-m (* sg-cnt 350.0))
       (define sg-g (* sg-cnt 220.0))
       (define inprog-g
         (* 0.65 (+ (* (ip 'robotics-facility) 155.0)
                    (* (ip 'robotics-bay) 210.0)
                    (* (ip 'stargate) 220.0))))
       (define probe-m (if workers-still-needed? (* th-cnt 250.0) 0.0))
       (values (+ gw-m robo-m sg-m probe-m) (+ gw-g robo-g sg-g inprog-g))]
      [(Zerg)
       ;; Zerg Larva supply: ~8.0 larva/min per injected Hatchery (5.5 uninjected).
       ;; Bill only unit lines whose tech structure is actually ready, and normalize
       ;; across Drones + Overlords so 1 larva is never double-billed; add steady-state
       ;; Queen mineral drain (~150M/m per active Hatchery).
       (define hatch-cnt (max 1 (+ (rc 'hatchery) (rc 'lair) (rc 'hive))))
       (define q-cnt (safe-count ready-bldg-counts 'spawning-pool))
       (define larva-per-min (* hatch-cnt (if (> q-cnt 0) 8.0 5.5)))
       (define w-ro  (if (> (rc 'roach-warren) 0) (hash-ref comp-mix 'roach 0.0) 0.0))
       (define w-rav (if (> (rc 'roach-warren) 0) (hash-ref comp-mix 'ravager 0.0) 0.0))
       (define w-hy  (if (> (rc 'hydralisk-den) 0) (hash-ref comp-mix 'hydralisk 0.0) 0.0))
       (define w-co  (if (> (+ (rc 'spire) (rc 'greater-spire)) 0)
                         (+ (hash-ref comp-mix 'corruptor 0.0) (hash-ref comp-mix 'mutalisk 0.0))
                         0.0))
       (define w-li  (if (> q-cnt 0) (hash-ref comp-mix 'zergling 0.0) 0.0))
       (define w-ba  (if (> (rc 'baneling-nest) 0) (hash-ref comp-mix 'baneling 0.0) 0.0))
       (define w-dr  (if workers-still-needed? 0.30 0.0)) ; physics: ~30% larva share for Drones while < w-cap
       (define w-ov  0.15) ; physics: ~1 Overlord (100M/0G) per ~6-7 larva
       (define w-tot (max 0.1 (+ w-ro w-rav w-hy w-co w-li w-ba w-dr w-ov)))
       (define avg-m
         (/ (+ (* w-ro 75.0) (* w-rav 100.0) (* w-hy 100.0) (* w-co 150.0)
               (* w-li 50.0) (* w-ba 75.0) (* w-dr 50.0) (* w-ov 100.0))
            w-tot))
       (define avg-g
         (/ (+ (* w-ro 25.0) (* w-rav 100.0) (* w-hy 50.0) (* w-co 100.0) (* w-ba 25.0))
            w-tot))
       (define inprog-g
         (* 0.65 (+ (* (ip 'spire) 240.0)
                    (* (ip 'hydralisk-den) 150.0)
                    (* (ip 'lair) 120.0))))
       (define queen-m (* (max 1 active-bases) 150.0)) ; physics: steady-state Queen mineral drain (150M/0G)
       (values (+ (* larva-per-min (max 50.0 avg-m)) queen-m)
               (+ (* larva-per-min avg-g) inprog-g))]
      [else (values 400.0 100.0)]))

  ;; Add forward lookahead for imminent completing tech buildings (<= 25s)
  (define-values (fwd-m-min fwd-g-min fwd-g-res)
    (compute-forward-tech-demand in-progress-tech-etas))

  ;; Also account for pending upgrade / tech demand if plan wants catch-up upgrades
  (define upg-g-add (if (and (macro-game-plan? plan) (macro-game-plan-upgrade-catchup-urgent? plan)) 100.0 0.0))
  (define ready-geysers
    (+ (rc 'extractor) (rc 'assimilator) (rc 'refinery)))
  (define total-geysers
    (+ (tc 'extractor) (tc 'assimilator) (tc 'refinery)))
  (define-values (plan-gas-ratio unbuilt-tech-g-min)
    (compute-plan-gas-stoichiometry plan total-bldg-counts))
  (define actual-facility-g-demand (+ g-drain-min fwd-g-min upg-g-add))
  (define stoich-g-demand
    (if (> ready-geysers 0)
        (+ unbuilt-tech-g-min (* 0.50 plan-gas-ratio m-rate-min))
        unbuilt-tech-g-min))
  (define m-demand-min (+ m-drain-min fwd-m-min))
  (define g-demand-min (max actual-facility-g-demand stoich-g-demand))

  ;; Closed-form 30s physics target gas workers G* coupled to mineral-feasible burn:
  ;; takes a clean `max` floor between `active-escrow-gas-floor` and horizon burn
  ;; `eff-g-burn-H + fwd-g-res` (NEVER additive, so high-gas escrows like Colossus
  ;; 200G or Tank 125G never double-count on top of 30s burn!).
  (define h-frac (/ FLOW-DEMAND-HORIZON-SEC 60.0))
  (define m-need (max 0.0 (- (* m-demand-min h-frac) (exact->inexact cur-min))))
  (define m-avail-H (+ (exact->inexact cur-min) (* m-rate-min h-frac)))
  (define eff-gas-ratio (min 0.85 (/ g-demand-min (max 1.0 m-demand-min)))) ; physics: stoichiometric gas/mineral cap
  (define eff-g-burn-H (min (* g-demand-min h-frac) (* m-avail-H eff-gas-ratio)))
  (define target-g-H
    (max (exact->inexact active-escrow-gas-floor)
         (+ eff-g-burn-H (exact->inexact fwd-g-res))))
  (define g-need (max 0.0 (- target-g-H (exact->inexact cur-gas))))
  (define denom (+ (/ m-need SC2-MINERAL-RATE-PER-WORKER-MIN)
                   (/ g-need SC2-GAS-RATE-PER-WORKER-MIN)))
  (define g-star
    (cond
      [(= ready-geysers 0) 0]
      [(<= g-need 0.0) 0]
      [(<= denom 0.01) 0]
      [else
       (min (* 3 ready-geysers)
            (max 0 (inexact->exact (round (* (exact->inexact workers)
                                             (/ (/ g-need SC2-GAS-RATE-PER-WORKER-MIN) denom))))))]))

  (define need-more-prod?
    (and (> m-rate-min (* 1.15 (max 250.0 m-drain-min)))
         (>= cur-min 150))) ; physics: 1 production facility cost (Rax/Gateway = 150M)
  (define need-more-gas?
    (and (> actual-facility-g-demand (* 1.15 (max 60.0 g-rate-min)))
         (< total-geysers (* 2 (max 1 total-bases)))
         (>= workers 15)))
  (define sat-ratio (/ (exact->inexact (max 0 workers))
                       (exact->inexact (max 1 (* 16 (max 1 active-bases))))))
  (define target-bases (if (macro-game-plan? plan) (macro-game-plan-target-bases plan) 2))
  (define army-def? (and (macro-game-plan? plan) (macro-game-plan-army-deficit? plan)))
  (define cheese-on? (and (macro-game-plan? plan) (macro-game-plan-cheese-active? plan)))
  (define need-exp?
    (and (not cheese-on?)
         (or (>= sat-ratio 0.85)
             (> depleting-bases 0)
             (and (> target-bases total-bases) (not army-def?)))))

  (escrow-flow-report
   m-rate-min g-rate-min m-drain-min g-drain-min
   fwd-m-min fwd-g-min m-demand-min g-demand-min
   g-star need-more-prod? need-more-gas? need-exp? fwd-g-res))

;; Clean handoff helper matching Track 1 `worker-saturation-policy.rkt` kwargs!
(define (escrow-flow-report->sat-kwargs rep)
  (if (escrow-flow-report? rep)
      (hasheq 'mineral-demand-rate (escrow-flow-report-mineral-demand-rate rep)
              'gas-demand-rate (escrow-flow-report-gas-demand-rate rep)
              'desired-gas-workers (escrow-flow-report-desired-gas-workers rep))
      (hasheq 'mineral-demand-rate #f
              'gas-demand-rate #f
              'desired-gas-workers #f)))
