#lang racket/base

;; =============================================================================
;; `lib/engine/arbiter.rkt`
;; Layer 3 Unified Priority & Arbitration Engine
;;
;; Pure L0-only leaf module (`#lang racket/base` for < 0.15 ms/step hot-path
;; speed with zero Typed/Untyped chaperone overhead).
;;
;; Single override decision-maker across 4 scarce budgets:
;;   1. Resources & Facilities (minerals, gas, supply, larva, facility slots/tags,
;;      plus centralized `blocking-escrow?` floors)
;;   2. Unit Tag Ownership & Leases (single canonical `role-leases` registry
;;      using L0 `unit-role-lease` structs + `allow-partial?` squad narrowing)
;;   3. Macro Energy (OC / Nexus / Queen pools + reserve floors)
;;   4. Attention / APM Budget (`P0..P4` QoS floors)
;;
;; Supports BOTH:
;;   - Same-step ranked `alternatives` cascade (max depth 3) evaluated in-place
;;     before recording a rejection
;;   - Cross-step bounded per-module `override-signal` ring buffers (`cap=32`,
;;     automatic frame-rewind reset) queried via `arbiter-feedback-for` and
;;     `arbiter-recent-override-count` for hysteresis-guarded proposer adaptation
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         (only-in "../sc2-game-constants.rkt"
                  unit-role-lease
                  unit-role-lease?
                  unit-role-lease-role
                  unit-role-lease-priority
                  unit-role-lease-expires-frame
                  role-lease-priority))

(provide
 ARBITER-OVERRIDE-REASONS
 arbiter-override-reason?
 arbiter-role-priority
 (struct-out proposal-cost)
 make-proposal-cost
 (struct-out proposal-claim)
 make-proposal-claim
 (struct-out proposal-energy)
 make-proposal-energy
 (struct-out proposal)
 make-proposal
 (struct-out override-signal)
 (struct-out arbiter-budget-snapshot)
 make-arbiter-budget-snapshot
 (struct-out arbiter-ledger)
 make-arbiter-ledger
 reset-arbiter-ledger!
 (struct-out arbiter-result)
 arbiter-resolve!
 arbiter-feedback-for
 arbiter-recent-override-count
 arbiter-telemetry-summary)

;; =============================================================================
;; Canonical Override Reason Enum & Role Priority Alignment
;; =============================================================================

(define ARBITER-OVERRIDE-REASONS
  '(budget-mineral
    budget-gas
    budget-supply
    budget-larva
    facility-busy
    unit-claimed-higher-priority
    energy-reserved
    threat-veto
    apm-cap-deferred
    superseded-by-alternative))

(define (arbiter-override-reason? sym)
  (and (symbol? sym) (not (not (memq sym ARBITER-OVERRIDE-REASONS)))))

;; Fast untyped lookup aligned with `role-lease-priority` in `sc2-game-constants.rkt`,
;; extended with operational/tactical roles (`home-defense`, `micro-spell`, `concave`).
(define (arbiter-role-priority role)
  (case role
    [(builder)         100]
    [(inject-queen)     95]
    [(door-guard)       90]
    [(mule)             90]
    [(home-defense)     88]
    [(evac)             85]
    [(cargo-returner)   80]
    [(detector-escort)  75]
    [(scout)            70]
    [(spotter)          68]
    [(creep-queen)      65]
    [(micro-spell)      60]
    [(strike-group)     55]
    [(staging-group)    50]
    [(concave)          30]
    [(army)             20]
    [(harvester)        10]
    [else (role-lease-priority role)]))

;; =============================================================================
;; Core Immutable Proposal, Budget, Signal & Result Structs
;; =============================================================================

(struct proposal-cost
  (minerals          ;; exact-nonneg-integer
   gas               ;; exact-nonneg-integer
   supply            ;; exact-nonneg-integer
   larva             ;; exact-nonneg-integer
   facility-slot     ;; symbol or #f
   facility-tag)     ;; exact-integer or #f
  #:constructor-name raw-proposal-cost
  #:transparent)

(define (make-proposal-cost
         #:minerals [minerals 0]
         #:gas [gas 0]
         #:supply [supply 0]
         #:larva [larva 0]
         #:facility-slot [facility-slot #f]
         #:facility-tag [facility-tag #f])
  (raw-proposal-cost
   (max 0 (if (exact-integer? minerals) minerals (exact-round minerals)))
   (max 0 (if (exact-integer? gas) gas (exact-round gas)))
   (max 0 (if (exact-integer? supply) supply (exact-round supply)))
   (max 0 (if (exact-integer? larva) larva (exact-round larva)))
   (if (symbol? facility-slot) facility-slot #f)
   (if (and (exact-integer? facility-tag) (> facility-tag 0)) facility-tag #f)))

(struct proposal-claim
  (unit-tags         ;; (listof exact-integer)
   role              ;; symbol matching `arbiter-role-priority`
   lease-ttl         ;; exact-nonneg-integer (0 = single-step only, >0 = persistent lease)
   allow-partial?    ;; boolean
   min-units)        ;; exact-nonneg-integer
  #:constructor-name raw-proposal-claim
  #:transparent)

(define (make-proposal-claim
         unit-tags
         #:role [role 'army]
         #:lease-ttl [lease-ttl 0]
         #:allow-partial? [allow-partial? #f]
         #:min-units [min-units 1])
  (define clean-tags
    (if (list? unit-tags)
        (for/list ([t (in-list unit-tags)]
                   #:when (and (exact-integer? t) (> t 0)))
          t)
        '()))
  (raw-proposal-claim
   clean-tags
   (if (symbol? role) role 'army)
   (max 0 (if (exact-integer? lease-ttl) lease-ttl 0))
   (not (not allow-partial?))
   (max 0 (if (exact-integer? min-units) min-units 1))))

(struct proposal-energy
  (caster-tag        ;; exact-integer UnitTag
   caster-type       ;; 'orbital-command | 'nexus | 'queen
   energy-cost       ;; flonum
   reserve-floor)    ;; flonum energy locked after cast (or reserved for higher-priority spells)
  #:constructor-name raw-proposal-energy
  #:transparent)

(define (make-proposal-energy
         caster-tag
         caster-type
         energy-cost
         #:reserve-floor [reserve-floor 0.0])
  (raw-proposal-energy
   (if (and (exact-integer? caster-tag) (> caster-tag 0)) caster-tag 0)
   (if (symbol? caster-type) caster-type 'unknown)
   (max 0.0 (exact->inexact energy-cost))
   (max 0.0 (exact->inexact reserve-floor))))

(struct proposal
  (id                ;; symbol or pair
   source-module     ;; symbol
   domain            ;; 'macro | 'energy | 'ops | 'micro | 'camera
   priority          ;; real (higher wins)
   cost-spec         ;; proposal-cost or #f
   claim-spec        ;; proposal-claim or #f
   energy-spec       ;; proposal-energy or #f
   attention-tier    ;; exact-integer 0..4
   action            ;; action s-exp, list of actions, or (unclaimed-tags -> actions) thunk
   alternatives      ;; (listof proposal)
   rationale         ;; symbol or string
   blocking-escrow?) ;; boolean
  #:transparent)

(define (make-proposal
         id
         source-module
         domain
         priority
         action
         #:cost [cost #f]
         #:claim [claim #f]
         #:energy [energy #f]
         #:attention-tier [attention-tier 2]
         #:alternatives [alternatives '()]
         #:rationale [rationale 'unspecified]
         #:blocking-escrow? [blocking-escrow? #f])
  (proposal
   id
   (if (symbol? source-module) source-module 'unknown)
   (if (symbol? domain) domain 'micro)
   (if (real? priority) (exact->inexact priority) 0.0)
   (if (proposal-cost? cost) cost #f)
   (if (proposal-claim? claim) claim #f)
   (if (proposal-energy? energy) energy #f)
   (max 0 (min 4 (if (exact-integer? attention-tier) attention-tier 2)))
   action
   (if (list? alternatives) alternatives '())
   rationale
   (not (not blocking-escrow?))))

(struct override-signal
  (frame             ;; exact-nonneg-integer
   proposal-id       ;; symbol or pair
   source-module     ;; symbol
   domain            ;; symbol
   reason            ;; symbol in ARBITER-OVERRIDE-REASONS
   winner-id         ;; symbol/pair or #f
   winner-module     ;; symbol or #f
   winner-priority   ;; real or #f
   details)          ;; immutable hash
  #:transparent)

(struct arbiter-budget-snapshot
  (minerals               ;; exact-nonneg-integer
   gas                    ;; exact-nonneg-integer
   supply-left            ;; exact-integer
   larva-count            ;; exact-nonneg-integer
   open-facility-slots    ;; hash: slot-sym -> exact-nonneg-integer
   busy-facility-tags     ;; seteqv of busy facility UnitTags
   caster-energy-by-tag   ;; hasheqv: UnitTag -> flonum
   caster-reserve-by-tag  ;; hasheqv: UnitTag -> (vector floor owner-module owner-id owner-prio) or (cons floor owner-module)
   apm-tokens-available   ;; flonum (or +inf.0 when ungoverned)
   apm-tier-floors)       ;; vector of 5 flonums (P0..P4 QoS floors)
  #:transparent)

(define (make-arbiter-budget-snapshot
         #:minerals [minerals 0]
         #:gas [gas 0]
         #:supply-left [supply-left 200]
         #:larva-count [larva-count 0]
         #:open-facility-slots [open-facility-slots (hasheq)]
         #:busy-facility-tags [busy-facility-tags (seteqv)]
         #:caster-energy-by-tag [caster-energy-by-tag (hasheqv)]
         #:caster-reserve-by-tag [caster-reserve-by-tag (hasheqv)]
         #:apm-tokens-available [apm-tokens-available +inf.0]
         #:apm-tier-floors [apm-tier-floors #(0.0 0.0 0.0 0.0 0.0)])
  (define floors
    (if (and (vector? apm-tier-floors) (= (vector-length apm-tier-floors) 5))
        apm-tier-floors
        #(0.0 0.0 0.0 0.0 0.0)))
  (arbiter-budget-snapshot
   (max 0 (if (exact-integer? minerals) minerals (exact-round minerals)))
   (max 0 (if (exact-integer? gas) gas (exact-round gas)))
   (if (exact-integer? supply-left) supply-left (exact-round supply-left))
   (max 0 (if (exact-integer? larva-count) larva-count (exact-round larva-count)))
   (if (hash? open-facility-slots) open-facility-slots (hasheq))
   (if (set? busy-facility-tags) busy-facility-tags (seteqv))
   (if (hash? caster-energy-by-tag) caster-energy-by-tag (hasheqv))
   (if (hash? caster-reserve-by-tag) caster-reserve-by-tag (hasheqv))
   (if (real? apm-tokens-available) (exact->inexact apm-tokens-available) +inf.0)
   floors))

;; =============================================================================
;; Persistent Per-Runtime Ledger & Bounded O(1) Ring Buffer
;; =============================================================================

(struct feedback-ring
  (vec               ;; fixed-length mutable vector of override-signal or #f
   [head #:mutable]  ;; next write index 0..cap-1
   [count #:mutable]);; number of populated slots 0..cap
  #:transparent)

(define (make-feedback-ring cap)
  (feedback-ring (make-vector cap #f) 0 0))

(define (feedback-ring-push! ring sig)
  (define vec (feedback-ring-vec ring))
  (define cap (vector-length vec))
  (define h (feedback-ring-head ring))
  (vector-set! vec h sig)
  (set-feedback-ring-head! ring (let ([nh (add1 h)]) (if (= nh cap) 0 nh)))
  (define c (feedback-ring-count ring))
  (when (< c cap)
    (set-feedback-ring-count! ring (add1 c))))

(struct arbiter-ledger
  ([last-frame #:mutable]
   role-leases        ;; mutable hasheqv: UnitTag -> unit-role-lease
   feedback-rings     ;; mutable hasheq: source-module -> feedback-ring
   reason-counters    ;; mutable hash: (cons source-module reason) -> exact-nonneg-integer
   ring-cap)          ;; exact-positive-integer
  #:transparent)

(define (make-arbiter-ledger #:ring-cap [ring-cap 32])
  (define cap (max 1 (if (exact-integer? ring-cap) ring-cap 32)))
  (arbiter-ledger -1 (make-hasheqv) (make-hasheq) (make-hash) cap))

(define (reset-arbiter-ledger! ledger)
  (when (arbiter-ledger? ledger)
    (set-arbiter-ledger-last-frame! ledger -1)
    (hash-clear! (arbiter-ledger-role-leases ledger))
    (hash-clear! (arbiter-ledger-feedback-rings ledger))
    (hash-clear! (arbiter-ledger-reason-counters ledger))))

(define (ledger-record-signal! ledger sig)
  (define src (override-signal-source-module sig))
  (define rsn (override-signal-reason sig))
  (define rings (arbiter-ledger-feedback-rings ledger))
  (define ring
    (hash-ref! rings src (lambda () (make-feedback-ring (arbiter-ledger-ring-cap ledger)))))
  (feedback-ring-push! ring sig)
  (define ctrs (arbiter-ledger-reason-counters ledger))
  (define key (cons src rsn))
  (hash-set! ctrs key (add1 (hash-ref ctrs key 0))))

(struct arbiter-result
  (accepted-proposals     ;; (listof proposal)
   approved-actions       ;; (listof any)
   escrow-reservations    ;; (listof (list proposal-id source-module min-floor gas-floor))
   override-signals       ;; (listof override-signal)
   claimed-tags           ;; immutable seteqv
   telemetry-summary)     ;; immutable hasheq
  #:transparent)

;; =============================================================================
;; Helpers for Reserve Normalization, Action Materialization & Threat Veto
;; =============================================================================

(define (parse-energy-reserve-entry entry)
  (cond
    [(and (vector? entry) (= (vector-length entry) 4))
     (values (exact->inexact (vector-ref entry 0))
             (vector-ref entry 1)
             (vector-ref entry 2)
             (exact->inexact (vector-ref entry 3)))]
    [(pair? entry)
     (values (exact->inexact (car entry))
             (cdr entry)
             (cdr entry)
             850.0)]
    [(real? entry)
     (values (exact->inexact entry) 'energy-reserve 'energy-reserve 850.0)]
    [else
     (values 0.0 #f #f 0.0)]))

(define (normalize-veto-result res)
  (cond
    [(not res) (values #f #f #f #f (hasheq))]
    [(and (list? res) (>= (length res) 3))
     (values #t
             (first res)
             (second res)
             (third res)
             (if (and (>= (length res) 4) (hash? (fourth res)))
                 (fourth res)
                 (hasheq)))]
    [(hash? res)
     (values #t
             (hash-ref res 'winner-id 'threat-veto)
             (hash-ref res 'winner-module 'home-defense)
             (hash-ref res 'winner-priority 900.0)
             res)]
    [else
     (values #t 'threat-veto 'home-defense 900.0 (hasheq))]))

(define (append-materialized-actions! acc-box act chosen-tags)
  (define resolved (if (procedure? act) (act chosen-tags) act))
  (cond
    [(or (not resolved) (null? resolved)) (void)]
    [(and (pair? resolved) (pair? (car resolved)))
     ;; list of action s-expressions
     (for ([a (in-list resolved)])
       (when (pair? a)
         (set-box! acc-box (cons a (unbox acc-box)))))]
    [(pair? resolved)
     (set-box! acc-box (cons resolved (unbox acc-box)))]
    [else (void)]))

;; =============================================================================
;; Top-Level Deterministic 4-Budget Arbitration (`arbiter-resolve!`)
;; =============================================================================

(define (arbiter-resolve! ledger frame budget-snapshot proposals
                          #:threat-veto-fn [threat-veto-fn #f]
                          #:max-alt-depth [max-alt-depth 3])
  (define cur-frame (max 0 (if (exact-integer? frame) frame 0)))
  (define last-f (arbiter-ledger-last-frame ledger))
  ;; Automatic rewind / cross-test stale-gap reset (matches Loop 60 >1200f rule)
  (when (and (>= last-f 0)
             (or (< cur-frame last-f)
                 (> (- cur-frame last-f) 1200)))
    (reset-arbiter-ledger! ledger))
  (set-arbiter-ledger-last-frame! ledger cur-frame)

  ;; Prune expired persistent leases
  (define role-leases (arbiter-ledger-role-leases ledger))
  (when (> (hash-count role-leases) 0)
    (define expired-tags
      (for/list ([(t lease) (in-hash role-leases)]
                 #:when (or (not (unit-role-lease? lease))
                            (<= (unit-role-lease-expires-frame lease) cur-frame)))
        t))
    (for ([t (in-list expired-tags)])
      (hash-remove! role-leases t)))

  ;; Mutable per-step working budgets
  (define rem-min (arbiter-budget-snapshot-minerals budget-snapshot))
  (define rem-gas (arbiter-budget-snapshot-gas budget-snapshot))
  (define rem-sup (arbiter-budget-snapshot-supply-left budget-snapshot))
  (define rem-larva (arbiter-budget-snapshot-larva-count budget-snapshot))
  (define rem-slots (make-hasheq))
  (for ([(slot cnt) (in-hash (arbiter-budget-snapshot-open-facility-slots budget-snapshot))])
    (hash-set! rem-slots slot (max 0 (if (exact-integer? cnt) cnt 0))))
  (define slot-holders (make-hasheq))
  (define used-fac-tags (mutable-seteqv))
  (for ([ft (in-set (arbiter-budget-snapshot-busy-facility-tags budget-snapshot))])
    (set-add! used-fac-tags ft))
  (define fac-tag-holders (make-hasheqv))

  (define rem-energy (make-hasheqv))
  (for ([(ctag en) (in-hash (arbiter-budget-snapshot-caster-energy-by-tag budget-snapshot))])
    (hash-set! rem-energy ctag (exact->inexact en)))
  (define energy-reserves (make-hasheqv))
  (for ([(ctag ent) (in-hash (arbiter-budget-snapshot-caster-reserve-by-tag budget-snapshot))])
    (define-values (fl mod wid wprio) (parse-energy-reserve-entry ent))
    (when (> fl 0.0)
      (hash-set! energy-reserves ctag (vector fl mod wid wprio))))

  (define rem-apm (arbiter-budget-snapshot-apm-tokens-available budget-snapshot))
  (define apm-floors (arbiter-budget-snapshot-apm-tier-floors budget-snapshot))

  ;; Per-step unit claim map: tag -> (vector prio role-prio role source-module proposal-id)
  (define step-claimed (make-hasheqv))

  ;; Centralized escrow floors & winners
  (define escrow-min-floor 0)
  (define escrow-gas-floor 0)
  (define escrow-min-winner #f)
  (define escrow-gas-winner #f)
  (define escrow-reservations-rev '())

  ;; Outputs
  (define accepted-rev '())
  (define actions-box (box '()))
  (define signals-rev '())
  (define step-reason-counts (make-hasheq))
  (define alt-count 0)
  (define rej-count 0)

  (define (record-step-signal! sig)
    (set! signals-rev (cons sig signals-rev))
    (define r (override-signal-reason sig))
    (hash-set! step-reason-counts r (add1 (hash-ref step-reason-counts r 0)))
    (ledger-record-signal! ledger sig))

  ;; Stable descending sort by priority (preserving input order on ties)
  (define indexed
    (for/list ([p (in-list proposals)]
               [i (in-naturals)]
               #:when (proposal? p))
      (cons i p)))
  (define sorted-proposals
    (map cdr
         (sort indexed
               (lambda (a b)
                 (define pa (proposal-priority (cdr a)))
                 (define pb (proposal-priority (cdr b)))
                 (if (= pa pb)
                     (< (car a) (car b))
                     (> pa pb))))))

  ;; Evaluates constraints for `p`. Returns:
  ;;   (values #t chosen-tags #f #f #f #f #f) on success
  ;;   (values #f '() reason w-id w-mod w-prio details) on failure
  (define (check-proposal p)
    ;; (a) Threat veto
    (define-values (vetoed? v-id v-mod v-prio v-details)
      (if (procedure? threat-veto-fn)
          (normalize-veto-result (threat-veto-fn p))
          (values #f #f #f #f (hasheq))))
    (cond
      [vetoed?
       (values #f '() 'threat-veto v-id v-mod v-prio v-details)]
      [else
       ;; (b) Unit tag claims (same-step claims + persistent higher-role leases)
       (define cl (proposal-claim-spec p))
       (define-values (claim-ok? chosen-tags c-wid c-wmod c-wprio c-details)
         (if (not cl)
             (values #t '() #f #f #f (hasheq))
             (let* ([req-tags (proposal-claim-unit-tags cl)]
                    [caller-role (proposal-claim-role cl)]
                    [caller-rprio (arbiter-role-priority caller-role)]
                    [allow-part? (proposal-claim-allow-partial? cl)]
                    [min-u (proposal-claim-min-units cl)])
               (define free-rev '())
               (define contested-rev '())
               (define top-wprio -1.0)
               (define top-wid #f)
               (define top-wmod #f)
               (define top-wrole #f)
               (for ([t (in-list req-tags)])
                 (define sc (hash-ref step-claimed t #f))
                 (cond
                   [sc
                    (set! contested-rev (cons t contested-rev))
                    (define wp (vector-ref sc 0))
                    (when (> wp top-wprio)
                      (set! top-wprio wp)
                      (set! top-wrole (vector-ref sc 2))
                      (set! top-wmod (vector-ref sc 3))
                      (set! top-wid (vector-ref sc 4)))]
                   [else
                    (define pl (hash-ref role-leases t #f))
                    (if (and (unit-role-lease? pl)
                             (> (unit-role-lease-expires-frame pl) cur-frame)
                             (> (unit-role-lease-priority pl) caller-rprio))
                        (let ([lp (exact->inexact (unit-role-lease-priority pl))]
                              [lr (unit-role-lease-role pl)])
                          (set! contested-rev (cons t contested-rev))
                          (when (> lp top-wprio)
                            (set! top-wprio lp)
                            (set! top-wrole lr)
                            (set! top-wmod lr)
                            (set! top-wid lr)))
                        (set! free-rev (cons t free-rev)))]))
               (define free-tags (reverse free-rev))
               (define contested-tags (reverse contested-rev))
               (cond
                 [(null? contested-tags)
                  (values #t req-tags #f #f #f (hasheq))]
                 [(and allow-part? (>= (length free-tags) min-u))
                  (values #t free-tags #f #f #f (hasheq))]
                 [else
                  (values #f
                          '()
                          top-wid
                          top-wmod
                          top-wprio
                          (hasheq 'contested-tags contested-tags
                                  'free-tags free-tags
                                  'caller-role caller-role
                                  'winner-role top-wrole))]))))
       (cond
         [(not claim-ok?)
          (values #f '() 'unit-claimed-higher-priority c-wid c-wmod c-wprio c-details)]
         [else
          ;; (c) Macro energy
          (define en (proposal-energy-spec p))
          (define-values (en-ok? e-wid e-wmod e-wprio e-details)
            (if (not en)
                (values #t #f #f #f (hasheq))
                (let* ([ctag (proposal-energy-caster-tag en)]
                       [ecost (proposal-energy-energy-cost en)]
                       [avail (hash-ref rem-energy ctag 0.0)]
                       [res-vec (hash-ref energy-reserves ctag #f)]
                       [apply-res?
                        (and res-vec
                             (not (eq? (proposal-source-module p) (vector-ref res-vec 1)))
                             (< (proposal-priority p) (vector-ref res-vec 3)))]
                       [res-fl (if apply-res? (vector-ref res-vec 0) 0.0)]
                       [eff-avail (- avail res-fl)])
                  (if (>= eff-avail ecost)
                      (values #t #f #f #f (hasheq))
                      (values #f
                              (if apply-res? (vector-ref res-vec 2) 'energy-pool)
                              (if apply-res? (vector-ref res-vec 1) 'energy-pool)
                              (if apply-res? (vector-ref res-vec 3) #f)
                              (hasheq 'caster-tag ctag
                                      'needed ecost
                                      'available avail
                                      'reserved-floor res-fl
                                      'shortfall (- ecost eff-avail)))))))
          (cond
            [(not en-ok?)
             (values #f '() 'energy-reserved e-wid e-wmod e-wprio e-details)]
            [else
             ;; (d) Resources & Facilities
             (define cost (proposal-cost-spec p))
             (define-values (cost-ok? cost-rsn r-wid r-wmod r-wprio r-details)
               (if (not cost)
                   (values #t #f #f #f #f (hasheq))
                   (let ([c-min (proposal-cost-minerals cost)]
                         [c-gas (proposal-cost-gas cost)]
                         [c-sup (proposal-cost-supply cost)]
                         [c-larva (proposal-cost-larva cost)]
                         [c-slot (proposal-cost-facility-slot cost)]
                         [c-ftag (proposal-cost-facility-tag cost)])
                     (cond
                       [(and c-ftag (set-member? used-fac-tags c-ftag))
                        (define fh (hash-ref fac-tag-holders c-ftag #f))
                        (values #f 'facility-busy
                                (and fh (vector-ref fh 2))
                                (if fh (vector-ref fh 1) 'busy-facility)
                                (and fh (vector-ref fh 0))
                                (hasheq 'facility-tag c-ftag))]
                       [(and c-slot (<= (hash-ref rem-slots c-slot 0) 0))
                        (define sh (hash-ref slot-holders c-slot #f))
                        (values #f 'facility-busy
                                (and sh (vector-ref sh 2))
                                (if sh (vector-ref sh 1) 'facility-pool)
                                (and sh (vector-ref sh 0))
                                (hasheq 'facility-slot c-slot))]
                       [(> c-larva rem-larva)
                        (values #f 'budget-larva #f 'larva-pool #f
                                (hasheq 'needed c-larva 'available rem-larva 'shortfall (- c-larva rem-larva)))]
                       [(> c-sup rem-sup)
                        (values #f 'budget-supply #f 'supply-pool #f
                                (hasheq 'needed c-sup 'available rem-sup 'shortfall (- c-sup rem-sup)))]
                       [else
                        (define avail-min (max 0 (- rem-min escrow-min-floor)))
                        (define avail-gas (max 0 (- rem-gas escrow-gas-floor)))
                        (cond
                          [(and (> c-min 0) (< avail-min c-min))
                           (when (proposal-blocking-escrow? p)
                             (when (> c-min escrow-min-floor)
                               (set! escrow-min-floor c-min)
                               (set! escrow-min-winner p))
                             (when (> c-gas escrow-gas-floor)
                               (set! escrow-gas-floor c-gas)
                               (set! escrow-gas-winner p))
                             (set! escrow-reservations-rev
                                   (cons (list (proposal-id p) (proposal-source-module p) c-min c-gas)
                                         escrow-reservations-rev)))
                           (define due-to-escrow? (and (>= rem-min c-min) (proposal? escrow-min-winner)))
                           (values #f 'budget-mineral
                                   (and due-to-escrow? (proposal-id escrow-min-winner))
                                   (if due-to-escrow? (proposal-source-module escrow-min-winner) 'mineral-bank)
                                   (and due-to-escrow? (proposal-priority escrow-min-winner))
                                   (hasheq 'needed c-min
                                           'available avail-min
                                           'raw-minerals rem-min
                                           'escrow-floor escrow-min-floor
                                           'shortfall (- c-min avail-min)))]
                          [(and (> c-gas 0) (< avail-gas c-gas))
                           (when (proposal-blocking-escrow? p)
                             (when (> c-min escrow-min-floor)
                               (set! escrow-min-floor c-min)
                               (set! escrow-min-winner p))
                             (when (> c-gas escrow-gas-floor)
                               (set! escrow-gas-floor c-gas)
                               (set! escrow-gas-winner p))
                             (set! escrow-reservations-rev
                                   (cons (list (proposal-id p) (proposal-source-module p) c-min c-gas)
                                         escrow-reservations-rev)))
                           (define due-to-escrow? (and (>= rem-gas c-gas) (proposal? escrow-gas-winner)))
                           (values #f 'budget-gas
                                   (and due-to-escrow? (proposal-id escrow-gas-winner))
                                   (if due-to-escrow? (proposal-source-module escrow-gas-winner) 'gas-bank)
                                   (and due-to-escrow? (proposal-priority escrow-gas-winner))
                                   (hasheq 'needed c-gas
                                           'available avail-gas
                                           'raw-gas rem-gas
                                           'escrow-floor escrow-gas-floor
                                           'shortfall (- c-gas avail-gas)))]
                          [else
                           (values #t #f #f #f #f (hasheq))])]))))
             (cond
               [(not cost-ok?)
                (values #f '() cost-rsn r-wid r-wmod r-wprio r-details)]
               [else
                ;; (e) Attention / APM QoS budget
                (define tier (proposal-attention-tier p))
                (define floor-t (vector-ref apm-floors tier))
                (if (and (not (infinite? rem-apm))
                         (< (- rem-apm floor-t) 1.0))
                    (values #f '() 'apm-cap-deferred 'apm-governor 'apm-governor #f
                            (hasheq 'tier tier 'tokens-available rem-apm 'tier-floor floor-t))
                    (values #t chosen-tags #f #f #f #f (hasheq)))])])])]))

  (define (commit-proposal! p chosen-tags)
    (define cost (proposal-cost-spec p))
    (when cost
      (set! rem-min (max 0 (- rem-min (proposal-cost-minerals cost))))
      (set! rem-gas (max 0 (- rem-gas (proposal-cost-gas cost))))
      (set! rem-sup (- rem-sup (proposal-cost-supply cost)))
      (set! rem-larva (max 0 (- rem-larva (proposal-cost-larva cost))))
      (define slot (proposal-cost-facility-slot cost))
      (when slot
        (hash-set! rem-slots slot (max 0 (sub1 (hash-ref rem-slots slot 0))))
        (hash-set! slot-holders slot
                   (vector (proposal-priority p) (proposal-source-module p) (proposal-id p))))
      (define ftag (proposal-cost-facility-tag cost))
      (when ftag
        (set-add! used-fac-tags ftag)
        (hash-set! fac-tag-holders ftag
                   (vector (proposal-priority p) (proposal-source-module p) (proposal-id p)))))
    (define cl (proposal-claim-spec p))
    (when cl
      (define role (proposal-claim-role cl))
      (define rprio (arbiter-role-priority role))
      (define ttl (proposal-claim-lease-ttl cl))
      (define claim-rec (vector (proposal-priority p) rprio role (proposal-source-module p) (proposal-id p)))
      (for ([t (in-list chosen-tags)])
        (hash-set! step-claimed t claim-rec)
        (when (> ttl 0)
          (hash-set! role-leases t
                     (unit-role-lease role rprio 0 0.0 0.0 (+ cur-frame ttl))))))
    (define en (proposal-energy-spec p))
    (when en
      (define ctag (proposal-energy-caster-tag en))
      (define avail (hash-ref rem-energy ctag 0.0))
      (hash-set! rem-energy ctag (max 0.0 (- avail (proposal-energy-energy-cost en))))
      (define rfl (proposal-energy-reserve-floor en))
      (when (> rfl 0.0)
        (define prev (hash-ref energy-reserves ctag #f))
        (when (or (not prev) (> rfl (vector-ref prev 0)))
          (hash-set! energy-reserves ctag
                     (vector rfl (proposal-source-module p) (proposal-id p) (proposal-priority p))))))
    (unless (infinite? rem-apm)
      (set! rem-apm (max 0.0 (- rem-apm 1.0))))
    (set! accepted-rev (cons p accepted-rev))
    (append-materialized-actions! actions-box (proposal-action p) chosen-tags))

  ;; Returns accepted proposal struct on success, or #f on failure
  (define (try-schedule! p depth)
    (define-values (ok? chosen-tags rsn w-id w-mod w-prio details)
      (check-proposal p))
    (cond
      [ok?
       (commit-proposal! p chosen-tags)
       p]
      [else
       (define alts (proposal-alternatives p))
       (define accepted-alt
         (and (< depth max-alt-depth)
              (pair? alts)
              (let loop ([rem alts])
                (cond
                  [(null? rem) #f]
                  [(not (proposal? (car rem))) (loop (cdr rem))]
                  [else
                   (define res (try-schedule! (car rem) (add1 depth)))
                   (if res res (loop (cdr rem)))]))))
       (cond
         [accepted-alt
          (when (= depth 0)
            (set! alt-count (add1 alt-count))
            (record-step-signal!
             (override-signal
              cur-frame
              (proposal-id p)
              (proposal-source-module p)
              (proposal-domain p)
              'superseded-by-alternative
              w-id
              w-mod
              w-prio
              (hasheq 'primary-reason rsn
                      'primary-details details
                      'accepted-alt-id (proposal-id accepted-alt)
                      'accepted-alt-module (proposal-source-module accepted-alt)))))
          accepted-alt]
         [else
          (when (= depth 0)
            (set! rej-count (add1 rej-count))
            (record-step-signal!
             (override-signal
              cur-frame
              (proposal-id p)
              (proposal-source-module p)
              (proposal-domain p)
              rsn
              w-id
              w-mod
              w-prio
              details)))
          #f])]))

  (for ([p (in-list sorted-proposals)])
    (try-schedule! p 0))

  (define claimed-set
    (for/seteqv ([t (in-hash-keys step-claimed)]) t))
  (define by-reason-im
    (for/hasheq ([(k v) (in-hash step-reason-counts)]) (values k v)))
  (define saving-sym
    (cond
      [(proposal? escrow-min-winner) (proposal-id escrow-min-winner)]
      [(proposal? escrow-gas-winner) (proposal-id escrow-gas-winner)]
      [else 'none]))
  (define tel-sum
    (hasheq 'frame cur-frame
            'accepted-count (length accepted-rev)
            'alternative-count alt-count
            'rejected-count rej-count
            'claimed-tag-count (set-count claimed-set)
            'saving-for saving-sym
            'escrow-min-floor escrow-min-floor
            'escrow-gas-floor escrow-gas-floor
            'by-reason by-reason-im))
  (arbiter-result
   (reverse accepted-rev)
   (reverse (unbox actions-box))
   (reverse escrow-reservations-rev)
   (reverse signals-rev)
   claimed-set
   tel-sum))

;; =============================================================================
;; Cross-Step Override Feedback Query & Telemetry Summary API
;; =============================================================================

;; Returns matching override-signal records newest-first.
(define (arbiter-feedback-for ledger source-module
                              #:since-frame [since-frame 0]
                              #:reason [reason #f])
  (define ring (and (arbiter-ledger? ledger)
                    (hash-ref (arbiter-ledger-feedback-rings ledger) source-module #f)))
  (if (not ring)
      '()
      (let* ([vec (feedback-ring-vec ring)]
             [cap (vector-length vec)]
             [cnt (feedback-ring-count ring)]
             [head (feedback-ring-head ring)])
        (for/fold ([acc '()] #:result (reverse acc))
                  ([offset (in-range 1 (add1 cnt))])
          (define idx (modulo (- head offset) cap))
          (define sig (vector-ref vec idx))
          (if (and (override-signal? sig)
                   (>= (override-signal-frame sig) since-frame)
                   (or (not reason) (eq? (override-signal-reason sig) reason)))
              (cons sig acc)
              acc)))))

;; Zero-allocation hysteresis window counter for proposer adaptation.
(define (arbiter-recent-override-count ledger source-module reason cur-frame
                                       #:window-frames [window-frames 224])
  (define ring (and (arbiter-ledger? ledger)
                    (hash-ref (arbiter-ledger-feedback-rings ledger) source-module #f)))
  (if (not ring)
      0
      (let* ([vec (feedback-ring-vec ring)]
             [cap (vector-length vec)]
             [cnt (feedback-ring-count ring)]
             [head (feedback-ring-head ring)]
             [min-f (- cur-frame (max 0 window-frames))])
        (for/fold ([n 0]) ([offset (in-range 1 (add1 cnt))])
          (define idx (modulo (- head offset) cap))
          (define sig (vector-ref vec idx))
          (if (and (override-signal? sig)
                   (>= (override-signal-frame sig) min-f)
                   (<= (override-signal-frame sig) cur-frame)
                   (or (not reason) (eq? (override-signal-reason sig) reason)))
              (add1 n)
              n)))))

(define (arbiter-telemetry-summary ledger)
  (if (not (arbiter-ledger? ledger))
      (hasheq 'total-overrides 0 'by-reason (hasheq) 'by-module (hasheq) 'top-pairs '())
      (let ([by-r (make-hasheq)]
            [by-m (make-hasheq)]
            [pairs '()]
            [total 0])
        (for ([(k cnt) (in-hash (arbiter-ledger-reason-counters ledger))])
          (define src (car k))
          (define rsn (cdr k))
          (set! total (+ total cnt))
          (hash-set! by-r rsn (+ (hash-ref by-r rsn 0) cnt))
          (hash-set! by-m src (+ (hash-ref by-m src 0) cnt))
          (set! pairs (cons (list src rsn cnt) pairs)))
        (define sorted-pairs
          (sort pairs (lambda (a b) (> (third a) (third b)))))
        (hasheq 'total-overrides total
                'by-reason (for/hasheq ([(k v) (in-hash by-r)]) (values k v))
                'by-module (for/hasheq ([(k v) (in-hash by-m)]) (values k v))
                'top-pairs (take sorted-pairs (min 12 (length sorted-pairs)))))))
