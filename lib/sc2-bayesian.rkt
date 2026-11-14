#lang typed/racket/base

;; =============================================================================
;; `lib/sc2-bayesian.rkt`
;; Layer 0b Dedicated Typed Bayesian Inference, Log-Odds, Distribution Divergence,
;; & Fog-of-War Markov Diffusion Library.
;;
;; Single source of truth for all Bayesian inference in Mothman:
;;   - Prior <-> Odds <-> Log-Odds <-> Posterior transformations
;;   - Likelihood-ratio sequential Bayesian updating (`bayesian-posterior-from-likelihoods`)
;;   - Categorical / Dirichlet-smoothed branch normalization (`bayesian-categorical-posterior`)
;;   - Hellinger distribution distance (`hellinger-distance`)
;;   - Fog-of-War Markov-Bayesian sector diffusion (`fow-ghost-step-diffusion!`)
;;   - Signal-level bluff, feint, rush, hidden-expand, tech-switch & pad-camped evaluators
;; =============================================================================

(require racket/list
         racket/math
         "sc2-types.rkt")

(provide
 (struct-out bayesian-strategic-priors)
 DEFAULT-BAYESIAN-STRATEGIC-PRIORS
 prob->odds
 odds->prob
 prob->log-odds
 log-odds->prob
 bayesian-posterior-from-likelihoods
 bayesian-categorical-posterior
 hellinger-distance
 fow-ghost-step-diffusion!
 compute-bayesian-pad-camped-posterior
 evaluate-bluff-posterior-from-signals
 evaluate-strategic-posteriors-from-signals)

;; -----------------------------------------------------------------------------
;; 1. Canonical Default Priors & Scalar Odds / Sigmoid Conversions
;; -----------------------------------------------------------------------------

(: DEFAULT-BAYESIAN-STRATEGIC-PRIORS bayesian-strategic-priors)
(define DEFAULT-BAYESIAN-STRATEGIC-PRIORS
  (bayesian-strategic-priors
   0.08
   0.08
   0.10
   0.12
   0.14
   0.15
   (ann (hasheq) (HashTable Symbol Float))))

(: prob->odds (->* (Real) (Real) Float))
(define (prob->odds p [eps 1e-4])
  (define cp (clamp-prob p eps))
  (/ cp (- 1.0 cp)))

(: odds->prob (->* (Real) (Real Real) Float))
(define (odds->prob o [min-p 0.0] [max-p 1.0])
  (define fo (->float o))
  (cond
    [(or (nan? fo) (<= fo 0.0)) (clamp-real min-p 0.0 1.0)]
    [(infinite? fo) (clamp-real max-p 0.0 1.0)]
    [else (clamp-real (/ fo (+ 1.0 fo)) min-p max-p)]))

(: prob->log-odds (->* (Real) (Real) Float))
(define (prob->log-odds p [eps 1e-4])
  (define o (prob->odds p eps))
  (define l (log o))
  (if (real? l) (->float l) 0.0))

(: log-odds->prob (->* (Real) (Real Real) Float))
(define (log-odds->prob lo [min-p 0.0] [max-p 1.0])
  (define clamped-lo (clamp-real lo -30.0 30.0))
  (define sig (/ 1.0 (+ 1.0 (exp (- clamped-lo)))))
  (clamp-real sig min-p max-p))

;; -----------------------------------------------------------------------------
;; 2. Likelihood-Ratio Updating & Categorical Normalization
;; -----------------------------------------------------------------------------

;; General Bayesian odds-ratio update over a list of `(cons evidence-active? likelihood-ratio)` pairs.
;; Takes a prior probability P(H) in (0, 1) and multiplies the prior odds P(H)/(1 - P(H))
;; by each active positive/negative likelihood ratio, returning the calibrated posterior in [0.01, 0.99].
(: bayesian-posterior-from-likelihoods
   (->* (Any (Listof Any))
        (#:any-evidence? Any #:max-prior Real)
        Float))
(define (bayesian-posterior-from-likelihoods raw-prior evidence-likelihood-pairs
                                             #:any-evidence? [any-evidence-override 'auto]
                                             #:max-prior [raw-max-prior 0.99])
  (define max-p (clamp-real raw-max-prior 0.01 0.99))
  (define prior (clamp-real (safe-real raw-prior 0.10) 0.01 max-p))
  (define active-lrs : (Listof Float)
    (for/fold ([acc : (Listof Float) '()])
              ([p (in-list evidence-likelihood-pairs)])
      (if (and (pair? p)
               (car p)
               (let ([lr (cdr p)])
                 (and (real? lr) (not (nan? lr)) (not (infinite? lr)) (> lr 0.0))))
          (let ([lr (cdr p)])
            (if (real? lr) (cons (->float lr) acc) acc))
          acc)))
  (define has-ev? : Boolean
    (if (eq? any-evidence-override 'auto)
        (not (null? active-lrs))
        (and any-evidence-override #t)))
  (if (not has-ev?)
      prior
      (let ([odds (for/fold ([o : Float (prob->odds prior 0.01)])
                            ([lr (in-list active-lrs)])
                    (* o lr))])
        (odds->prob odds 0.01 0.99))))

;; Normalizes a hash table or association list of `Symbol -> weight` into a proper
;; categorical posterior distribution whose weights sum to 1.0.
(: bayesian-categorical-posterior
   (->* (Any)
        (#:min-weight Real #:dirichlet-alpha Real)
        (HashTable Symbol Float)))
(define (bayesian-categorical-posterior raw-weights
                                        #:min-weight [raw-min-w 1e-6]
                                        #:dirichlet-alpha [raw-alpha 0.0])
  (define min-w (max 1e-9 (->float raw-min-w)))
  (define alpha (max 0.0 (->float raw-alpha)))
  (define entries : (Listof (Pair Symbol Float))
    (cond
      [(hash? raw-weights)
       (for/fold ([acc : (Listof (Pair Symbol Float)) '()])
                 ([(k v) (in-hash raw-weights)])
         (if (symbol? k)
             (let ([w (max min-w (+ alpha (safe-finite-real v 0.0)))])
               (cons (cons k w) acc))
             acc))]
      [(list? raw-weights)
       (for/fold ([acc : (Listof (Pair Symbol Float)) '()])
                 ([p (in-list raw-weights)])
         (if (and (pair? p) (symbol? (car p)))
             (let ([k (car p)]
                   [w (max min-w (+ alpha (safe-finite-real (cdr p) 0.0)))])
               (cons (cons k w) acc))
             acc))]
      [else '()]))
  (define total-w : Float
    (max 1e-9
         (for/fold ([s : Float 0.0]) ([e (in-list entries)])
           (+ s (cdr e)))))
  (for/hasheq : (Immutable-HashTable Symbol Float) ([e (in-list entries)])
    (values (car e) (/ (cdr e) total-w))))

;; -----------------------------------------------------------------------------
;; 3. Distribution Divergence & Fog-of-War Markov Diffusion
;; -----------------------------------------------------------------------------

;; Hellinger distance between two discrete probability distributions P and Q in [0.0, 1.0].
(: hellinger-distance (-> (Listof Real) (Listof Real) Float))
(define (hellinger-distance dist-p dist-q)
  (define sum-sq : Float
    (for/fold ([s : Float 0.0])
              ([p (in-list dist-p)]
               [q (in-list dist-q)])
      (define sp (sqrt (max 0.0 (->float p))))
      (define sq (sqrt (max 0.0 (->float q))))
      (define d (- (if (real? sp) (->float sp) 0.0)
                   (if (real? sq) (->float sq) 0.0)))
      (+ s (* d d))))
  (define root-s (sqrt (max 0.0 sum-sq)))
  (define root-2 (sqrt 2.0))
  (clamp-real (/ (if (real? root-s) (->float root-s) 0.0)
                 (if (real? root-2) (->float root-2) 1.4142135623730951))
              0.0
              1.0))

;; Fog-of-War Markov Ghost Diffusion over coarse sector grid (e.g. 8x8 = 64 cells).
;; Conserves probability mass = 1.0, collapsing observed visible empty sectors to 0.
(: fow-ghost-step-diffusion! (->* ((Vectorof Float) (Listof Any)) (Real) (Vectorof Float)))
(define (fow-ghost-step-diffusion! belief-vec visible-cells [raw-alpha 0.20])
  (define n (vector-length belief-vec))
  (define alpha (clamp-real raw-alpha 0.0 1.0))
  (when (> n 0)
    (define next-vec : (Vectorof Float) (make-vector n 0.0))
    (for ([i (in-range n)])
      (define cur (vector-ref belief-vec i))
      (define left (vector-ref belief-vec (modulo (sub1 i) n)))
      (define right (vector-ref belief-vec (modulo (add1 i) n)))
      (define diffused (+ (* (- 1.0 alpha) cur)
                          (* (* 0.5 alpha) (+ left right))))
      (vector-set! next-vec i diffused))
    ;; Zero out sectors currently visible with no enemies
    (for ([vis-idx (in-list visible-cells)])
      (when (and (exact-integer? vis-idx) (>= vis-idx 0) (< vis-idx n))
        (vector-set! next-vec vis-idx 0.0)))
    ;; Re-normalize to sum = 1.0
    (define total : Float
      (for/fold ([s : Float 0.0]) ([v (in-vector next-vec)]) (+ s v)))
    (if (> total 1e-9)
        (for ([i (in-range n)])
          (vector-set! belief-vec i (/ (vector-ref next-vec i) total)))
        (let ([unif (/ 1.0 (->float n))])
          (for ([i (in-range n)])
            (vector-set! belief-vec i unif)))))
  belief-vec)

;; -----------------------------------------------------------------------------
;; 4. Strategic Signal Posterior Evaluators
;; -----------------------------------------------------------------------------

;; Computes calibrated Bayesian posterior P(pad-camped | observations, rush-posterior) in [0.01, 0.99].
(: compute-bayesian-pad-camped-posterior
   (->* ()
        (#:camp-building-observed? Any
         #:enemy-combat-count Any
         #:ally-defender-count Any
         #:total-ally-combat-count Any
         #:live-obs? Any
         #:dist-to-our-base Any
         #:dist-to-enemy-base Any
         #:rush-posterior Any
         #:prior Any)
        Float))
(define (compute-bayesian-pad-camped-posterior
         #:camp-building-observed? [camp-bldg? #f]
         #:enemy-combat-count [raw-enemy-cnt 0]
         #:ally-defender-count [raw-ally-near-cnt 0]
         #:total-ally-combat-count [raw-total-ally-cnt 0]
         #:live-obs? [live-obs? #f]
         #:dist-to-our-base [raw-dist-base 30.0]
         #:dist-to-enemy-base [raw-dist-enemy 90.0]
         #:rush-posterior [raw-rush-post 0.12]
         #:prior [raw-prior 0.12])
  (define enemy-cnt (max 0 (safe-exact-int raw-enemy-cnt 0)))
  (define ally-near-cnt (max 0 (safe-exact-int raw-ally-near-cnt 0)))
  (define total-ally-cnt (max 0 (safe-exact-int raw-total-ally-cnt 0)))
  (define dist-base (max 1.0 (safe-real raw-dist-base 30.0)))
  (define dist-enemy (max 1.0 (safe-real raw-dist-enemy 90.0)))
  (define rush-post (clamp-real (safe-real raw-rush-post 0.12) 0.01 0.99))
  (define multi-enemy-lr : Float
    (if (>= enemy-cnt 2)
        (* 14.0 (->float (expt 1.5 (min 4 (- enemy-cnt 2)))))
        1.0))
  (bayesian-posterior-from-likelihoods
   raw-prior
   (list
    ;; 1. Hard observation: enemy static defense or townhall structure on pad
    (cons (and camp-bldg? #t) 25.0)
    ;; 2. Hard observation: >= 2 enemy combat units camping the pad radius
    (cons (>= enemy-cnt 2) multi-enemy-lr)
    ;; 3. Hard observation: 1 enemy combat unit on pad in live game with no local escort
    (cons (and live-obs?
               (= enemy-cnt 1)
               (< ally-near-cnt enemy-cnt)
               (<= total-ally-cnt 2))
          11.0)
    ;; 4. Hard observation: 1 enemy combat unit on pad when defenders ARE available (contested/transient)
    (cons (and (= enemy-cnt 1)
               (not (and live-obs?
                         (< ally-near-cnt enemy-cnt)
                         (<= total-ally-cnt 2))))
          2.0)
    ;; 5. Strategic & spatial coupling: pad is on enemy side of map while opponent rush posterior is high
    (cons (and live-obs? (< dist-enemy dist-base) (>= rush-post 0.55) (>= enemy-cnt 1))
          1.8)
    ;; 6. Negative evidence: no enemy building or combat unit observed and friendly defenders control the area
    (cons (and (not camp-bldg?) (= enemy-cnt 0) (>= ally-near-cnt 1))
          0.20))))

;; Signal-level Bayesian bluff posterior P(bluff | E), decoupled from perception struct types.
(: evaluate-bluff-posterior-from-signals
   (->* ()
        (#:prior Real
         #:fake-build-count Integer
         #:res-cancel-status Symbol
         #:research-under-attack? Boolean
         #:combat-hallucination-bait? Boolean
         #:explicit-idle-bluff-count Integer
         #:active-research-count Integer
         #:preview-count Integer
         #:has-confirming-evidence? Boolean
         #:has-candidate-tech-branch? Boolean
         #:remaining-gas Real
         #:enemy-scouted-us? Boolean)
        Float))
(define (evaluate-bluff-posterior-from-signals
         #:prior [raw-prior 0.08]
         #:fake-build-count [fake-build-cnt 0]
         #:res-cancel-status [res-cancel-status 'none]
         #:research-under-attack? [res-under-atk? #f]
         #:combat-hallucination-bait? [combat-hallucination-bait? #f]
         #:explicit-idle-bluff-count [idle-bluff-cnt 0]
         #:active-research-count [active-res-cnt 0]
         #:preview-count [preview-cnt 0]
         #:has-confirming-evidence? [has-confirming-evidence? #f]
         #:has-candidate-tech-branch? [has-candidate-tech-branch? #f]
         #:remaining-gas [raw-rem-gas 0.0]
         #:enemy-scouted-us? [eff-scouted-us? #f])
  (define prior (clamp-real raw-prior 0.01 0.45))
  (define rem-gas (->float raw-rem-gas))
  (define any-evidence? : Boolean
    (or (> fake-build-cnt 0)
        (not (eq? res-cancel-status 'none))
        combat-hallucination-bait?
        (> idle-bluff-cnt 0)
        has-candidate-tech-branch?
        has-confirming-evidence?
        (> rem-gas 0.0)
        res-under-atk?))
  (define idle-or-branch-lr : (Option Float)
    (cond
      [(and (> idle-bluff-cnt 0)
            (not has-confirming-evidence?)
            (>= rem-gas 225.0))
       (if eff-scouted-us? 16.5 15.2)]
      [(and has-candidate-tech-branch?
            (not has-confirming-evidence?)
            (>= rem-gas 320.0))
       14.8]
      [(and has-candidate-tech-branch?
            (not has-confirming-evidence?)
            (>= rem-gas 225.0))
       2.5]
      [else #f]))
  (bayesian-posterior-from-likelihoods
   prior
   #:any-evidence? any-evidence?
   #:max-prior 0.45
   (list
    ;; Positive likelihood ratios (bluff / feint indicators)
    (cons (and any-evidence? (not res-under-atk?) (> fake-build-cnt 0))
          18.0)
    (cons (and any-evidence? (not res-under-atk?) (eq? res-cancel-status 'fake-research-bluff-canceled))
          15.0)
    (cons (and any-evidence? (not res-under-atk?) combat-hallucination-bait? (not has-confirming-evidence?))
          15.0)
    (cons (and any-evidence? (not res-under-atk?) idle-or-branch-lr)
          (or idle-or-branch-lr 1.0))
    ;; Negative likelihood ratios (confirming real commitment)
    (cons (and any-evidence? (> active-res-cnt 0))
          0.08)
    (cons (and any-evidence?
               (or (> preview-cnt 0)
                   (and has-confirming-evidence?
                        (= fake-build-cnt 0)
                        (not (eq? res-cancel-status 'fake-research-bluff-canceled)))))
          0.10)
    (cons (and any-evidence?
               (or res-under-atk?
                   (eq? res-cancel-status 'emergency-research-canceled-under-attack)
                   (eq? res-cancel-status 'research-forced-cancel-under-attack)))
          0.12))))

;; Signal-level Bayesian Strategic Priors & Posteriors evaluator across
;; bluff, feint, rush, hidden expansion, tech switch, and branch posteriors.
(: evaluate-strategic-posteriors-from-signals
   (->* (#:bluff-prior Real
         #:bluff-posterior Real
         #:frame Integer
         #:combat-count Integer
         #:unaccounted-minerals Real
         #:unaccounted-gas Real
         #:dark-matter-hypothesis Symbol
         #:predicted-enemy-bases Integer
         #:feint-or-poke-detected? Boolean
         #:proxy-or-rush-detected? Boolean
         #:branch-posteriors (HashTable Symbol Float))
        bayesian-strategic-priors))
(define (evaluate-strategic-posteriors-from-signals
         #:bluff-prior raw-bluff-prior
         #:bluff-posterior raw-bluff-post
         #:frame frame
         #:combat-count combat-cnt
         #:unaccounted-minerals rem-min
         #:unaccounted-gas rem-gas
         #:dark-matter-hypothesis dm-hyp
         #:predicted-enemy-bases pred-bases
         #:feint-or-poke-detected? feint-detected?
         #:proxy-or-rush-detected? proxy-rush?
         #:branch-posteriors branch-posteriors)
  (define bluff-prior (clamp-real raw-bluff-prior 0.01 0.45))
  (define bluff-post (clamp-real raw-bluff-post 0.01 0.99))
  (define feint-post
    (bayesian-posterior-from-likelihoods
     0.10
     #:any-evidence? #t
     (list
      (cons feint-detected? 8.5)
      (cons (and (>= combat-cnt 1) (<= combat-cnt 3) (>= rem-gas 180.0)) 3.2)
      (cons (>= bluff-post 0.55) 2.5))))
  (define rush-post
    (bayesian-posterior-from-likelihoods
     0.12
     #:any-evidence? #t
     (list
      (cons proxy-rush? 12.0)
      (cons (eq? dm-hyp 'proxy-production-or-all-in) 6.0)
      (cons (and (<= frame 2688) (>= combat-cnt 4)) 4.0)
      (cons (>= pred-bases 3) 0.15))))
  (define hidden-expand-post
    (bayesian-posterior-from-likelihoods
     0.14
     #:any-evidence? #t
     (list
      (cons (eq? dm-hyp 'hidden-expansion-or-macro-boom) 7.5)
      (cons (and (>= rem-min 400.0) (<= combat-cnt 3)) 3.5)
      (cons (>= rush-post 0.60) 0.20))))
  (define tech-switch-post
    (bayesian-posterior-from-likelihoods
     0.15
     #:any-evidence? #t
     (list
      (cons (eq? dm-hyp 'hidden-air-or-cloak-tech-switch) 6.5)
      (cons (>= rem-gas 200.0) 2.8)
      (cons (>= bluff-post 0.55) 3.5))))
  (bayesian-strategic-priors
   bluff-prior
   bluff-post
   feint-post
   rush-post
   hidden-expand-post
   tech-switch-post
   branch-posteriors))
