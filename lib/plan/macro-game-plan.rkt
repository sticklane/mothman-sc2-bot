#lang racket/base

;; =============================================================================
;; Declarative Pro-Backed Macro Game Plan (Loop 88A)
;;
;; Pure declarative layer: states WHAT we want given Pro-corpus matchup curves
;; (`lib/plan/pro-curves.rkt`), all 7 calibrated Opponent World Model dimensions
;; (`lib/opponent-world-model.rkt`), live threat/scouting, and optional Version C
;; cheese specification (`lib/build-orders/cheese.rkt`).
;;
;; Contains ZERO escrow floors, ZERO bank cutoffs, and ZERO `ignores-escrow`
;; workarounds: those decisions belong strictly to `lib/econ/escrow-engine.rkt`.
;; =============================================================================

(require racket/list
         racket/match
         "pro-curves.rkt"
         "../opponent-world-model.rkt"
         "../build-orders/cheese.rkt")

(provide (struct-out macro-game-plan)
         build-macro-game-plan
         macro-game-plan-desired-addons
         macro-game-plan-comp-weight
         macro-game-plan-tier-for-category)

(struct macro-game-plan
  (race                        ;; 'Protoss | 'Terran | 'Zerg
   enemy-race                  ;; 'Protoss | 'Terran | 'Zerg | 'Random | 'Unknown
   frame                       ;; exact-nonnegative-integer
   posture                     ;; 'defend-rush | 'counter-timing | 'macro-expand | 'anti-turtle | 'cheese-commit
   worker-target-cap           ;; exact-nonnegative-integer
   pro-worker-target           ;; flonum (interpolated from pro-curves.rkt)
   target-bases                ;; exact-positive-integer
   target-gas-geysers          ;; exact-nonnegative-integer
   army-parity-floor           ;; flonum (applies to ALL 3 races)
   army-deficit?               ;; boolean
   upgrade-catchup-urgent?     ;; boolean (driven by OWM/mirror upgrade delta)
   tech-defense-urgent?        ;; boolean (driven by OWM hidden-gas-tech-risk? / unaccounted-gas)
   expand-urgency              ;; flonum in [0.0, 2.0]
   comp-mix                    ;; immutable hasheq: unit-sym -> weight (sum ~ 1.0)
   desired-factory-techlab?    ;; boolean (goal-driven Terran addon target)
   desired-starport-techlab?   ;; boolean (goal-driven Terran addon target)
   desired-factory-techlab-cnt ;; exact-nonnegative-integer
   desired-starport-techlab-cnt;; exact-nonnegative-integer
   desired-tech-roots          ;; list of prerequisite/tech symbols required by comp-mix
   owm-signals-used            ;; immutable hasheq summarizing all 7 OWM dimensions read
   cheese-active?)             ;; boolean
  #:transparent)

(define (safe-ht-count ht sym)
  (if (hash? ht)
      (let ([v (hash-ref ht sym 0)])
        (if (real? v) (max 0 (inexact->exact (floor v))) 0))
      0))

(define (safe-ht-sum ht syms)
  (if (hash? ht)
      (for/sum ([s (in-list syms)]) (safe-ht-count ht s))
      0))

(define (safe-sig-real ht key default)
  (if (hash? ht)
      (let ([v (hash-ref ht key default)])
        (if (real? v) (exact->inexact v) default))
      default))

(define (safe-sig-bool ht key default)
  (if (hash? ht)
      (eq? (hash-ref ht key default) #t)
      default))

;; Extract all 7 calibrated OWM dimensions cleanly from `owm-summary` struct (if
;; present) with graceful fallback to `mirror-signals` hash for unit tests.
(define (extract-7dim-owm-signals owm-summary mirror-signals frame race enemy-race)
  (define has-owm? (opponent-world-summary? owm-summary))
  ;; Dim 1: Economy (estimated workers, live mineral/gas rates, workers killed)
  (define est-workers
    (if has-owm?
        (exact->inexact (opponent-world-summary-estimated-workers owm-summary))
        (safe-sig-real mirror-signals 'enemy-workers
                       (pro-target-workers-at enemy-race race frame))))
  (define est-min-rate
    (if has-owm?
        (exact->inexact (owm-estimated-min-rate owm-summary))
        (safe-sig-real mirror-signals 'owm-estimated-min-rate 0.0)))
  (define est-gas-rate
    (if has-owm?
        (exact->inexact (owm-estimated-gas-rate owm-summary))
        (safe-sig-real mirror-signals 'owm-estimated-gas-rate 0.0)))
  (define workers-killed
    (if has-owm?
        (opponent-world-summary-workers-killed owm-summary)
        (inexact->exact (floor (safe-sig-real mirror-signals 'workers-killed 0.0)))))

  ;; Dim 2: Expansion / Map Control
  (define est-bases
    (if has-owm?
        (max 1
             (opponent-world-summary-confirmed-bases owm-summary)
             (owm-estimated-enemy-bases owm-summary))
        (max 1 (inexact->exact (floor (safe-sig-real mirror-signals 'enemy-bases 1.0))))))
  (define happy-bases
    (if has-owm?
        (max 1 (opponent-world-summary-happy-expected-bases owm-summary))
        est-bases))
  (define stopped-expanding?
    (if has-owm?
        (and (opponent-world-summary-stopped-expanding? owm-summary) #t)
        (safe-sig-bool mirror-signals 'opp-stopped-expanding? #f)))
  (define exp-ambiguity?
    (if has-owm?
        (and (opponent-world-summary-unscouted-expansion-ambiguity? owm-summary) #t)
        (safe-sig-bool mirror-signals 'unscouted-expansion-ambiguity? #f)))

  ;; Dim 3: Gas & Tech Trajectory
  (define est-geysers
    (if has-owm?
        (max 0
             (opponent-world-summary-confirmed-geysers owm-summary)
             (owm-estimated-enemy-gases owm-summary))
        (max 0 (inexact->exact (floor (safe-sig-real mirror-signals 'enemy-geysers 0.0))))))
  (define hidden-gas-tech?
    (if has-owm?
        (and (opponent-world-summary-hidden-gas-tech-risk? owm-summary) #t)
        (safe-sig-bool mirror-signals 'hidden-gas-tech-risk? #f)))
  (define unseen-min
    (if has-owm?
        (max 0.0 (exact->inexact (opponent-world-summary-unaccounted-minerals owm-summary)))
        (max 0.0 (safe-sig-real mirror-signals 'unaccounted-minerals 0.0))))
  (define unseen-gas
    (if has-owm?
        (max 0.0 (exact->inexact (opponent-world-summary-unaccounted-gas owm-summary)))
        (max 0.0 (safe-sig-real mirror-signals 'unaccounted-gas 0.0))))

  ;; Dim 4: Production Capacity
  (define enemy-prod-cnt
    (if has-owm?
        (max (opponent-world-summary-production-facility-count owm-summary)
             (owm-home-prod-count owm-summary))
        (max 0 (inexact->exact (floor (safe-sig-real mirror-signals 'enemy-prod-count 0.0))))))

  ;; Dim 5: Army Composition & Believed Army Value/Supply
  (define believed-army-sup
    (max (if has-owm?
             (exact->inexact (opponent-world-summary-believed-total-army-supply owm-summary))
             0.0)
         (safe-sig-real mirror-signals 'believed-enemy-army-supply 0.0)))
  (define believed-army-val
    (max (if has-owm?
             (exact->inexact (opponent-world-summary-believed-total-army-value owm-summary))
             0.0)
         (safe-sig-real mirror-signals 'believed-enemy-army-value 0.0)))
  (define enemy-siege-cnt
    (if has-owm?
        (opponent-world-summary-enemy-siege-or-turtle-count owm-summary)
        (max 0 (inexact->exact (floor (safe-sig-real mirror-signals 'enemy-siege-count 0.0))))))

  ;; Dim 6: Upgrade Delta
  (define enemy-upg-adv
    (safe-sig-real mirror-signals 'mirror-enemy-upgrade-advantage 0.0))

  ;; Dim 7: Posture / Aggression
  (define rush-prob (safe-sig-real mirror-signals 'rush-prob 0.0))
  (define proxy-prob (safe-sig-real mirror-signals 'proxy-all-in-posterior 0.0))
  (define turtle-prob (safe-sig-real mirror-signals 'enemy-turtle-posterior 0.0))

  (hasheq 'has-owm? has-owm?
          'estimated-workers est-workers
          'estimated-min-rate est-min-rate
          'estimated-gas-rate est-gas-rate
          'workers-killed workers-killed
          'estimated-bases est-bases
          'happy-expected-bases happy-bases
          'stopped-expanding? stopped-expanding?
          'unscouted-expansion-ambiguity? exp-ambiguity?
          'estimated-geysers est-geysers
          'hidden-gas-tech-risk? hidden-gas-tech?
          'unaccounted-minerals unseen-min
          'unaccounted-gas unseen-gas
          'enemy-prod-count enemy-prod-cnt
          'believed-army-supply believed-army-sup
          'believed-army-value believed-army-val
          'enemy-siege-count enemy-siege-cnt
          'enemy-upgrade-advantage enemy-upg-adv
          'rush-prob rush-prob
          'proxy-prob proxy-prob
          'turtle-prob turtle-prob))

(define (normalize-weights pairs)
  (define total (for/sum ([p (in-list pairs)]) (max 0.0 (exact->inexact (cdr p)))))
  (if (<= total 0.0)
      (hasheq)
      (for/fold ([ht (hasheq)]) ([p (in-list pairs)])
        (define w (/ (max 0.0 (exact->inexact (cdr p))) total))
        (if (> w 0.0)
            (hash-set ht (car p) (+ (hash-ref ht (car p) 0.0) w))
            ht))))

;; Declarative target composition weights derived from matchup, observed enemy
;; army, OWM signals, and optional Version C cheese playbook.
(define (compute-target-comp-mix race enemy-race enemy-u-counts enemy-b-counts
                                 owm-ht cheese-spec cheese-active?)
  (cond
    [(and cheese-active? (cheese-build-spec? cheese-spec)
          (pair? (cheese-build-spec-army-comp cheese-spec)))
     (define cs (cheese-build-spec-army-comp cheese-spec))
     (define n (length cs))
     (normalize-weights
      (for/list ([sym (in-list cs)] [i (in-naturals)])
        (cons sym (exact->inexact (max 1 (- n i))))))]
    [else
     (define enemy-cap-air
       (safe-ht-sum enemy-u-counts '(tempest carrier battlecruiser mothership brood-lord)))
     (define enemy-air
       (+ enemy-cap-air
          (safe-ht-sum enemy-u-counts '(void-ray phoenix banshee mutalisk liberator liberator-ag viking-fighter corruptor oracle))))
     (define enemy-armored
       (safe-ht-sum enemy-u-counts '(stalker immortal colossus roach ravager marauder siege-tank siege-tank-sieged thor ultralisk)))
     (define enemy-bio-light
       (safe-ht-sum enemy-u-counts '(marine zergling zealot adept hydralisk baneling)))
     (define enemy-tanks
       (safe-ht-sum enemy-u-counts '(siege-tank siege-tank-sieged)))
     (define enemy-colossi
       (safe-ht-count enemy-u-counts 'colossus))
     (define enemy-cloak
       (+ (safe-ht-sum enemy-u-counts '(banshee dark-templar lurker lurker-burrowed ghost widow-mine-burrowed))
          (safe-ht-sum enemy-b-counts '(dark-shrine lurker-den))))
     (define hidden-gas? (hash-ref owm-ht 'hidden-gas-tech-risk? #f))
     (define turtle? (>= (hash-ref owm-ht 'turtle-prob 0.0) 0.45))

     (case race
       [(Terran)
        (define w-marine    (if (>= enemy-air 3) 0.34 0.38))
        (define w-marauder  (if (or (eq? enemy-race 'Protoss) (>= enemy-armored 4)) 0.22 0.12))
        (define w-tank      (cond
                              [(eq? enemy-race 'Terran) 0.28]
                              [(>= enemy-armored 3) 0.20]
                              [(>= enemy-tanks 1) 0.26]
                              [else 0.16]))
        (define w-medivac   0.14)
        (define w-viking    (cond
                              [(or (>= enemy-cap-air 1) (>= enemy-colossi 1)) 0.26]
                              [(>= enemy-air 2) 0.18]
                              [(eq? enemy-race 'Terran) 0.08]
                              [else 0.0]))
        (define w-raven     (if (or (> enemy-cloak 0) hidden-gas? turtle?) 0.06 0.0))
        (define w-liberator (if (or turtle? (>= enemy-armored 6)) 0.08 0.0))
        (normalize-weights
         (list (cons 'marine w-marine)
               (cons 'marauder w-marauder)
               (cons 'siege-tank w-tank)
               (cons 'medivac w-medivac)
               (cons 'viking-fighter w-viking)
               (cons 'raven w-raven)
               (cons 'liberator w-liberator)))]
       [(Protoss)
        (define w-stalker   (cond
                              [(>= enemy-air 2) 0.44]
                              [(eq? enemy-race 'Protoss) 0.36]
                              [else 0.32]))
        (define w-zealot    (if (>= enemy-air 4) 0.10 0.24))
        (define w-immortal  (if (or (>= enemy-armored 3) (eq? enemy-race 'Protoss) (eq? enemy-race 'Zerg)) 0.22 0.14))
        (define w-colossus  (if (and (>= enemy-bio-light 6) (<= enemy-cap-air 0)) 0.16 0.06))
        (define w-void-ray  (if (>= enemy-cap-air 1) 0.24 0.0))
        (define w-observer  (if (or (> enemy-cloak 0) hidden-gas?) 0.06 0.03))
        (define w-prism     0.04)
        (normalize-weights
         (list (cons 'stalker w-stalker)
               (cons 'zealot w-zealot)
               (cons 'immortal w-immortal)
               (cons 'colossus w-colossus)
               (cons 'void-ray w-void-ray)
               (cons 'observer w-observer)
               (cons 'warp-prism w-prism)))]
       [(Zerg)
        (define w-corruptor (cond
                              [(>= enemy-cap-air 1) 0.42]
                              [(>= enemy-air 4) 0.24]
                              [else 0.0]))
        (define w-hydra     (cond
                              [(>= enemy-air 2) 0.34]
                              [(eq? enemy-race 'Protoss) 0.24]
                              [else 0.18]))
        (define w-roach     (if (>= enemy-cap-air 2) 0.10 0.28))
        (define w-ravager   (if (or (>= enemy-tanks 2) turtle?) 0.22 0.12))
        (define w-zergling  (if (>= enemy-cap-air 2) 0.08 0.18))
        (define w-baneling  (if (and (>= enemy-bio-light 8) (<= enemy-cap-air 0)) 0.14 0.04))
        (define w-overseer  (if (or (> enemy-cloak 0) hidden-gas?) 0.04 0.02))
        (normalize-weights
         (list (cons 'corruptor w-corruptor)
               (cons 'hydralisk w-hydra)
               (cons 'roach w-roach)
               (cons 'ravager w-ravager)
               (cons 'zergling w-zergling)
               (cons 'baneling w-baneling)
               (cons 'overseer w-overseer)))]
       [else (hasheq)])]))

;; Derive desired tech roots directly from `comp-mix` so the Escrow Engine's DAG
;; root promoter guarantees required tech buildings are never starved.
(define (comp-mix->tech-roots race comp-mix)
  (define (want? sym thresh) (>= (hash-ref comp-mix sym 0.0) thresh))
  (case race
    [(Terran)
     (append
      (if (or (want? 'siege-tank 0.10) (want? 'cyclone 0.10) (want? 'thor 0.05))
          '(factory factory-techlab)
          '())
      (if (or (want? 'medivac 0.08) (want? 'viking-fighter 0.08) (want? 'liberator 0.05) (want? 'raven 0.04))
          '(starport)
          '())
      (if (or (want? 'raven 0.04) (want? 'banshee 0.05) (want? 'battlecruiser 0.05))
          '(starport-techlab)
          '()))]
    [(Protoss)
     (append
      (if (or (want? 'immortal 0.10) (want? 'observer 0.03) (want? 'warp-prism 0.03) (want? 'colossus 0.05))
          '(robotics-facility)
          '())
      (if (want? 'colossus 0.10) '(robotics-bay) '())
      (if (or (want? 'void-ray 0.10) (want? 'phoenix 0.08) (want? 'tempest 0.05))
          '(stargate)
          '()))]
    [(Zerg)
     (append
      (if (or (want? 'roach 0.10) (want? 'ravager 0.08)) '(roach-warren) '())
      (if (want? 'baneling 0.08) '(baneling-nest) '())
      (if (or (want? 'hydralisk 0.12) (want? 'corruptor 0.10) (want? 'overseer 0.02)) '(lair) '())
      (if (want? 'hydralisk 0.12) '(hydralisk-den) '())
      (if (want? 'corruptor 0.15) '(spire) '()))]
    [else '()]))

(define (build-macro-game-plan
         #:race race
         #:enemy-race enemy-race
         #:frame frame
         #:workers workers
         #:active-bases active-bases
         #:total-bases total-bases
         #:army-supply army-supply
         #:enemy-threat-supply enemy-threat-supply
         #:under-attack? under-attack?
         #:enemy-unit-counts [enemy-u-counts (hasheq)]
         #:enemy-building-counts [enemy-b-counts (hasheq)]
         #:ready-bldg-counts [ready-bldg-counts (hasheq)]
         #:total-bldg-counts [total-bldg-counts (hasheq)]
         #:unit-counts [unit-counts (hasheq)]
         #:owm-summary [owm-summary #f]
         #:mirror-signals [mirror-signals #f]
         #:cheese-spec [cheese-spec #f]
         #:cheese-phase [cheese-phase #f])
  (define cheese-active?
    (and (cheese-build-spec? cheese-spec)
         (not (memq cheese-phase '(fallback follow-up done)))))
  (define curve (lookup-pro-matchup-curve race enemy-race))
  (define owm-ht (extract-7dim-owm-signals owm-summary mirror-signals frame race enemy-race))

  (define pro-w (pro-target-workers-at race enemy-race frame))
  (define pro-bases (pro-target-bases-at race enemy-race frame))
  (define pro-army-sup (pro-target-army-supply-at race enemy-race frame))
  (define nat-f (pro-natural-frame race enemy-race))

  (define enemy-bases (hash-ref owm-ht 'estimated-bases 1))
  (define enemy-workers (hash-ref owm-ht 'estimated-workers 12.0))
  (define enemy-geysers (hash-ref owm-ht 'estimated-geysers 0))
  (define stopped-exp? (hash-ref owm-ht 'stopped-expanding? #f))
  (define hidden-gas? (hash-ref owm-ht 'hidden-gas-tech-risk? #f))
  (define unseen-gas (hash-ref owm-ht 'unaccounted-gas 0.0))
  (define believed-army-sup (hash-ref owm-ht 'believed-army-supply 0.0))
  (define enemy-upg-adv (hash-ref owm-ht 'enemy-upgrade-advantage 0.0))
  (define rush-prob (hash-ref owm-ht 'rush-prob 0.0))
  (define proxy-prob (hash-ref owm-ht 'proxy-prob 0.0))
  (define turtle-prob (hash-ref owm-ht 'turtle-prob 0.0))
  (define enemy-siege-cnt (hash-ref owm-ht 'enemy-siege-count 0))

  ;; Posture classification from live threat + 7-dim OWM
  (define posture
    (cond
      [cheese-active? 'cheese-commit]
      [(or (and under-attack? (< army-supply (* 1.15 (max 4.0 enemy-threat-supply))))
           (>= rush-prob 0.55)
           (>= proxy-prob 0.55))
       'defend-rush]
      [(or stopped-exp?
           (and (> believed-army-sup 0.0)
                (< army-supply (* 0.70 believed-army-sup))))
       'counter-timing]
      [(or (>= turtle-prob 0.45) (>= enemy-siege-cnt 3))
       'anti-turtle]
      [else 'macro-expand]))

  ;; Target bases: Pro-curve + OWM enemy-base lead (Zerg +1 base lead; anti-turtle +1)
  (define matchup-base-lead (if (eq? race 'Zerg) 1 0))
  (define raw-target-bases
    (if cheese-active?
        (cheese-build-spec-max-bases cheese-spec)
        (min 6
             (max pro-bases
                  (+ enemy-bases matchup-base-lead
                     (if (eq? posture 'anti-turtle) 1 0))))))

  ;; Worker target cap: Pro-backed max saturation per active/pending base, adjusted
  ;; by Version C cap when active.
  (define race-macro-cap (case race [(Zerg) 76] [(Protoss) 70] [else 66]))
  (define pending-bases (max 0 (- total-bases active-bases)))
  (define worker-target-cap
    (if cheese-active?
        (cheese-build-spec-worker-cap cheese-spec)
        (min race-macro-cap
             (max (inexact->exact (ceiling pro-w))
                  (+ (* 22 active-bases) (* 10 pending-bases))))))

  ;; Army parity floor for ALL 3 races (lifts legacy Zerg-only gate at L6661!)
  ;; Driven by calibrated OWM/mirror `believed-army-sup` & LotV 16-worker mineral-line
  ;; saturation milestones (1-base = 16w, 2-base = 32w, 3-base = 52w) so Protoss & Terran
  ;; also halt greed and build parity army against unseen/believed enemy army balls.
  (define army-parity-floor
    (cond
      [(or (< frame nat-f) (<= believed-army-sup 0.0)) 0.0]
      [(and stopped-exp? (>= workers 16)) ; physics: 1 saturated mineral line (16w)
       (* 0.85 believed-army-sup)]
      [(>= workers 52) ; physics: 3-base economy saturation threshold
       (* 0.80 believed-army-sup)]
      [(>= workers 32) ; physics: 2 saturated mineral lines (2 * 16w)
       (* 0.60 believed-army-sup)]
      [else 0.0]))
  (define army-deficit?
    (and (> army-parity-floor 0.0)
         (< (exact->inexact army-supply) army-parity-floor)))

  ;; Upgrade catch-up urgency from Dim 6 (OWM/Mirror upgrade delta)
  (define upgrade-catchup-urgent?
    (and (>= enemy-upg-adv 1.0)
         (not (eq? posture 'defend-rush))
         (>= active-bases 2)))

  ;; Tech/cloak defense urgency from Dim 3 (OWM hidden gas tech + unaccounted gas)
  (define tech-defense-urgent?
    (or hidden-gas?
        (and (>= enemy-geysers 2) (>= unseen-gas 150.0))))

  ;; Continuous expansion urgency [0.0, 2.0]
  (define worker-sat-ratio
    (/ (exact->inexact (max 0 workers))
       (exact->inexact (max 1 (* 16 (max 1 active-bases))))))
  (define expand-urgency
    (cond
      [cheese-active? (if (< total-bases raw-target-bases) 0.8 0.0)]
      [(eq? posture 'defend-rush) 0.0]
      [(>= total-bases raw-target-bases)
       (if (>= worker-sat-ratio 0.95) 0.7 0.0)]
      [else
       (min 2.0
            (+ (if (> raw-target-bases total-bases) 0.8 0.0)
               (if (>= worker-sat-ratio 0.85) 0.6 0.0)
               (if (> enemy-workers (+ workers 6)) 0.3 0.0)
               (if (eq? posture 'anti-turtle) 0.4 0.0)
               (if army-deficit? -0.5 0.0)))]))

  ;; Target composition & derived Terran addon goals (fixes Reactor-locked Factory!)
  (define comp-mix
    (compute-target-comp-mix race enemy-race enemy-u-counts enemy-b-counts
                             owm-ht cheese-spec cheese-active?))
  (define desired-tech-roots (comp-mix->tech-roots race comp-mix))

  (define fac-cnt (max 1 (safe-ht-count total-bldg-counts 'factory)))
  (define sp-cnt  (max 1 (safe-ht-count total-bldg-counts 'starport)))
  (define need-fac-tl?
    (and (eq? race 'Terran)
         (or (>= (hash-ref comp-mix 'siege-tank 0.0) 0.08)
             (>= (hash-ref comp-mix 'cyclone 0.0) 0.08)
             (>= (hash-ref comp-mix 'thor 0.0) 0.05))))
  (define need-sp-tl?
    (and (eq? race 'Terran)
         (or (>= (hash-ref comp-mix 'raven 0.0) 0.04)
             (>= (hash-ref comp-mix 'banshee 0.0) 0.05)
             (>= (hash-ref comp-mix 'battlecruiser 0.0) 0.05))))
  (define desired-fac-tl-cnt (if need-fac-tl? fac-cnt 0))
  (define desired-sp-tl-cnt  (if need-sp-tl? (min 1 sp-cnt) 0))

  ;; Target geysers from Pro worker thresholds + gas-heavy comp tilt
  (define g-thresh (pro-matchup-curve-gas-worker-thresholds curve))
  (define base-geysers
    (for/sum ([wt (in-list g-thresh)])
      (if (>= workers wt) 1 0)))
  (define target-gas-geysers
    (min (* 2 (max 1 total-bases))
         (max base-geysers
              (if (or need-fac-tl?
                      (>= (hash-ref comp-mix 'corruptor 0.0) 0.15)
                      (>= (hash-ref comp-mix 'colossus 0.0) 0.10))
                  (min (* 2 (max 1 active-bases)) 2)
                  0))))

  (macro-game-plan
   race enemy-race frame posture
   worker-target-cap pro-w raw-target-bases target-gas-geysers
   army-parity-floor army-deficit? upgrade-catchup-urgent? tech-defense-urgent?
   expand-urgency comp-mix
   need-fac-tl? need-sp-tl? desired-fac-tl-cnt desired-sp-tl-cnt
   desired-tech-roots owm-ht cheese-active?))

(define (macro-game-plan-desired-addons plan)
  (if (macro-game-plan? plan)
      (hasheq 'factory-techlab? (macro-game-plan-desired-factory-techlab? plan)
              'starport-techlab? (macro-game-plan-desired-starport-techlab? plan)
              'factory-techlab-count (macro-game-plan-desired-factory-techlab-cnt plan)
              'starport-techlab-count (macro-game-plan-desired-starport-techlab-cnt plan))
      (hasheq 'factory-techlab? #f
              'starport-techlab? #f
              'factory-techlab-count 0
              'starport-techlab-count 0)))

(define (macro-game-plan-comp-weight plan sym)
  (if (macro-game-plan? plan)
      (hash-ref (macro-game-plan-comp-mix plan) sym 0.0)
      0.0))

(define (macro-game-plan-tier-for-category cat urgent?)
  (cond
    [(or (eq? cat 'supply) urgent?) 'T0]
    [(memq cat '(counter-tech expansion)) 'T1]
    [(memq cat '(combat-unit worker)) 'T2]
    [(memq cat '(production-scaling tech-upgrade)) 'T3]
    [else 'T4]))
