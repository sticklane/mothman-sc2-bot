#lang racket/base

;; =============================================================================
;; `lib/plan/worker-saturation-policy.rkt`
;; Architecture Phase C2 (Loop 66) — Pure L2a Worker, Gas, Rally & MULE
;; Saturation Policy Leaf (L0-Only)
;;
;; Architectural Purity (Guard `9h`):
;;   - Pure `#lang racket/base` L2a leaf importing ONLY Racket stdlib + L0
;;     (`../sc2-game-constants.rkt`, `../sc2-common.rkt`).
;;   - ZERO imports of `sc2-protobuf-ws.rkt`, `bot-runtime.rkt`,
;;     `priority-macro-brain.rkt`, `econ-ledger.rkt`, `engine/*`, `tactics/*`,
;;     or any other `plan/*` module.
;;   - Encapsulates ALL 20 mutable saturation trackers cleanly inside
;;     `worker-sat-state` (with automatic frame-rewind reset) so callers/tests
;;     can isolate multiple states with zero module-global interference.
;;
;; Sub-sections preserved with 100% parity + Loop 66 hysteresis feedback:
;;   - Sec 0 : 3-Race TownHall `RALLY_WORKERS` (`'rally-workers`, 3690)
;;   - Sec 0a: Zero-gas-freeze rescue (300f latch, rotation, 180f stuck refresh)
;;             & 8s (`180f`) 0-worker live-geyser auto-resat
;;   - Sec 0b: Offline/mined-out base worker evacuation (`'harvest-gather`, urgent)
;;   - Sec 1 : Idle worker recovery onto under-saturated online bases (or safe
;;             map minerals when owned bases are mined out)
;;   - Sec 2 : Gas building refill (respecting mineral floor, `350G/600G` float
;;             caps, `worker-crisis-gas-evac?`, `mined-out-gas-evac?`, `112f`
;;             pull->fill opposite cooldown, and `#:gas-starvation-boost?` 2w/step)
;;   - Sec 3 : Inter-base over-saturated mineral transfer (`<= 6048` early natural
;;             split + `> 6048` strict `>= +2` over-sat, `2x` cd on APM backoff)
;;   - Sec 4 : Gas pullback under hysteresis latch (suppressed `< 300G` under
;;             `#:gas-starvation-boost?`, preserving crisis/mined-out evac)
;;   - Sec 5 : Idle MULE re-tasking onto nearby safe mineral patches
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         racket/set
         (only-in "../sc2-game-constants.rkt"
                  SC2-IDEAL-WORKERS-PER-MINERAL-LINE
                  SC2-IDEAL-WORKERS-PER-GEYSER
                  SC2-BASE-RESOURCE-RADIUS
                  SC2-GAS-FLOAT-REBALANCE-THRESH
                  SC2-GAS-FLOAT-PULL-THRESHOLD
                  SC2-GAS-HARVESTER-EXCLUSION-RADIUS)
         (only-in "../sc2-common.rkt"
                  safe-int
                  safe-real))

(provide
 (struct-out worker-sat-state)
 make-worker-sat-state
 reset-worker-sat-state!
 (struct-out sat-worker-info)
 (struct-out sat-base-info)
 (struct-out sat-gas-info)
 (struct-out sat-mineral-info)
 (struct-out sat-mule-info)
 (struct-out sat-directive)
 evaluate-worker-saturation-policy!
 worker-sat-gas-pull-latch-box)

;; =============================================================================
;; 1. Frozen Descriptor Structs & Per-Match Mutable State (`worker-sat-state`)
;; =============================================================================

(struct sat-worker-info
  (tag unit-type x y order-ability-id order-target-tag carrying-minerals? carrying-gas?
   excluded? lease-protected?)
  #:transparent)

(struct sat-base-info
  (tag unit-type x y ready? flying? assigned-harvesters ideal-harvesters
   enemy-threat-near? mineral-patch-tags)
  #:transparent)

(struct sat-gas-info
  (tag unit-type x y ready? vespene-contents assigned-harvesters ideal-harvesters
   nearest-base-tag enemy-threat-near?)
  #:transparent)

(struct sat-mineral-info
  (tag x y mineral-contents owner-base-tag safe-for-mule?)
  #:transparent)

(struct sat-mule-info
  (tag x y idle?)
  #:transparent)

;; Typed policy outputs translated 1:1 by wire codec into SC2 raw commands:
;;   kind = 'rally-workers   -> ability 3690 (unit-tags = (list th-tag), target-tag = patch-tag)
;;   kind = 'harvest-gather  -> ability 3666 (unit-tags = worker/mule tags, target-tag = target-tag)
(struct sat-directive
  (kind unit-tags target-tag urgent? reason)
  #:transparent)

(struct worker-sat-state
  (last-loop                      ;; (box exact-integer?)
   transfer-cooldown-until        ;; hasheqv: worker-tag -> loop
   gas-pull-hysteresis-latch      ;; (box boolean?)
   zero-gas-streak-start-loop     ;; (box (or/c #f exact-integer?))
   zero-gas-last-vespene          ;; (box (or/c #f exact-integer?))
   zero-gas-rescue-latch          ;; (box boolean?)
   zero-gas-rescue-rotation-idx   ;; (box exact-integer?)
   zero-gas-rescue-last-rotate    ;; (box (or/c #f exact-integer?))
   zero-gas-rescue-last-refresh   ;; (box (or/c #f exact-integer?))
   gas-bldg-zero-workers-since    ;; hasheqv: gas-tag -> loop
   th-worker-rally-target         ;; hasheqv: th-tag -> (vector dst-th-tag patch-tag last-loop was-flying?)
   evac-last-loop                 ;; hasheqv: grp-key -> loop
   idle-last-loop                 ;; hasheqv: worker-tag -> loop
   xfer-base-cooldown             ;; hasheqv: src-th-tag -> loop
   gas-rescue-last-loop           ;; hasheqv: gas-tag -> loop
   gas-fill-last-loop             ;; hasheqv: gas-tag -> (cons loop eff-assigned)
   gas-pull-last-loop             ;; (box (cons loop eff-active-gas-workers))
   gas-last-fill-global           ;; (box exact-integer?)
   gas-last-pull-global           ;; (box exact-integer?)
   mule-idle-last-loop            ;; hasheqv: mule-tag -> loop
   worker-patch-assignment)       ;; hasheqv: worker-tag -> mineral-tag
  #:transparent)

(define (make-worker-sat-state)
  (worker-sat-state
   (box 0)
   (make-hasheqv)
   (box #f)
   (box #f)
   (box #f)
   (box #f)
   (box 0)
   (box #f)
   (box #f)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (box (cons -1000 0))
   (box -1000)
   (box -1000)
   (make-hasheqv)
   (make-hasheqv)))

(define (reset-worker-sat-state! st)
  (set-box! (worker-sat-state-last-loop st) 0)
  (hash-clear! (worker-sat-state-transfer-cooldown-until st))
  (set-box! (worker-sat-state-gas-pull-hysteresis-latch st) #f)
  (set-box! (worker-sat-state-zero-gas-streak-start-loop st) #f)
  (set-box! (worker-sat-state-zero-gas-last-vespene st) #f)
  (set-box! (worker-sat-state-zero-gas-rescue-latch st) #f)
  (set-box! (worker-sat-state-zero-gas-rescue-rotation-idx st) 0)
  (set-box! (worker-sat-state-zero-gas-rescue-last-rotate st) #f)
  (set-box! (worker-sat-state-zero-gas-rescue-last-refresh st) #f)
  (hash-clear! (worker-sat-state-gas-bldg-zero-workers-since st))
  (hash-clear! (worker-sat-state-th-worker-rally-target st))
  (hash-clear! (worker-sat-state-evac-last-loop st))
  (hash-clear! (worker-sat-state-idle-last-loop st))
  (hash-clear! (worker-sat-state-xfer-base-cooldown st))
  (hash-clear! (worker-sat-state-gas-rescue-last-loop st))
  (hash-clear! (worker-sat-state-gas-fill-last-loop st))
  (set-box! (worker-sat-state-gas-pull-last-loop st) (cons -1000 0))
  (set-box! (worker-sat-state-gas-last-fill-global st) -1000)
  (set-box! (worker-sat-state-gas-last-pull-global st) -1000)
  (hash-clear! (worker-sat-state-mule-idle-last-loop st))
  (hash-clear! (worker-sat-state-worker-patch-assignment st))
  (void))

(define (worker-sat-gas-pull-latch-box st)
  (worker-sat-state-gas-pull-hysteresis-latch st))

;; =============================================================================
;; 2. Fast Flonum Geometry & Ability Predicates
;; =============================================================================

(define (fl-num v)
  (if (flonum? v)
      v
      (exact->inexact (safe-real v 0.0))))

(define (fl-dist x1 y1 x2 y2)
  (define dx (fl- x1 x2))
  (define dy (fl- y1 y2))
  (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))

(define (gather-ability-id? ab)
  (and (exact-integer? ab)
       (memv ab '(166 295 298 1183 3666))
       #t))

(define (return-ability-id? ab)
  (and (exact-integer? ab)
       (memv ab '(296 299 302 1184 3667))
       #t))

(define (attack-ability-id? ab)
  (and (exact-integer? ab)
       (memv ab '(23 3674 3675))
       #t))

(define (threat-flag? v)
  (cond
    [(real? v) (> v 0.0)]
    [else (and v #t)]))

(define (threat-score v)
  (cond
    [(real? v) (fl-num v)]
    [v 1000.0]
    [else 0.0]))

(define (base-is-flying? b)
  (or (sat-base-info-flying? b)
      (memq (sat-base-info-unit-type b) '(command-center-flying orbital-command-flying))
      (memv (sat-base-info-unit-type b) '(136 134))))

(define (worker-ab w)
  (safe-int (sat-worker-info-order-ability-id w) 0))

(define (worker-tgt w)
  (safe-int (sat-worker-info-order-target-tag w) 0))

(define (worker-idle? w)
  (= (worker-ab w) 0))

(define (classify-base-minerals b min-infos min-by-tag [radius 11.5] [max-patches 8])
  (define bx (fl-num (sat-base-info-x b)))
  (define by (fl-num (sat-base-info-y b)))
  (define btag (sat-base-info-tag b))
  (define explicit-tags (sat-base-info-mineral-patch-tags b))
  (define raw-mins
    (cond
      [(and (list? explicit-tags) (pair? explicit-tags))
       (for/list ([mtag (in-list explicit-tags)]
                  #:when (hash-has-key? min-by-tag mtag))
         (hash-ref min-by-tag mtag))]
      [else
       (for/list ([m (in-list min-infos)]
                  #:when (or (equal? (sat-mineral-info-owner-base-tag m) btag)
                             (fl<= (fl-dist bx by
                                            (fl-num (sat-mineral-info-x m))
                                            (fl-num (sat-mineral-info-y m)))
                                   radius)))
         m)]))
  (define with-dist
    (for/list ([m (in-list raw-mins)])
      (cons (fl-dist bx by (fl-num (sat-mineral-info-x m)) (fl-num (sat-mineral-info-y m))) m)))
  (define sorted-pairs (sort with-dist fl< #:key car))
  (define capped
    (map cdr (if (> (length sorted-pairs) max-patches)
                 (take sorted-pairs max-patches)
                 sorted-pairs)))
  (define near-cnt (quotient (length capped) 2))
  (values (take capped near-cnt) (drop capped near-cnt) capped))

;; =============================================================================
;; 3. Main Pure Policy Evaluator (`evaluate-worker-saturation-policy!`)
;; =============================================================================

(define (evaluate-worker-saturation-policy!
         st
         #:loop cur-loop-raw
         #:race race-sym
         #:minerals cur-min-raw
         #:gas cur-gas-raw
         #:workers worker-infos
         #:bases base-infos
         #:gas-buildings gas-infos
         #:minerals-fields min-infos
         #:mules [mule-infos '()]
         #:heavy-worker-rush-active? [heavy-rush? #f]
         #:gas-starvation-boost? [gas-starvation-boost? #f]
         #:apm-pressure-backoff? [apm-pressure-backoff? #f])
  (define cur-loop (safe-int cur-loop-raw 0))
  (define cur-min (safe-int cur-min-raw 0))
  (define cur-gas (safe-int cur-gas-raw 0))
  (define prev-loop (unbox (worker-sat-state-last-loop st)))
  (when (or (< cur-loop prev-loop)
            (and (<= cur-loop 8) (> prev-loop 8)))
    (reset-worker-sat-state! st))
  (set-box! (worker-sat-state-last-loop st) cur-loop)

  (define xfer-cd-ht (worker-sat-state-transfer-cooldown-until st))
  (define gas-pull-latch-box (worker-sat-state-gas-pull-hysteresis-latch st))
  (define zg-streak-box (worker-sat-state-zero-gas-streak-start-loop st))
  (define zg-last-v-box (worker-sat-state-zero-gas-last-vespene st))
  (define zg-rescue-box (worker-sat-state-zero-gas-rescue-latch st))
  (define zg-rot-idx-box (worker-sat-state-zero-gas-rescue-rotation-idx st))
  (define zg-last-rot-box (worker-sat-state-zero-gas-rescue-last-rotate st))
  (define zg-last-ref-box (worker-sat-state-zero-gas-rescue-last-refresh st))
  (define gas-zero-since-ht (worker-sat-state-gas-bldg-zero-workers-since st))
  (define th-rally-ht (worker-sat-state-th-worker-rally-target st))
  (define evac-last-ht (worker-sat-state-evac-last-loop st))
  (define idle-last-ht (worker-sat-state-idle-last-loop st))
  (define xfer-base-cd-ht (worker-sat-state-xfer-base-cooldown st))
  (define gas-rescue-last-ht (worker-sat-state-gas-rescue-last-loop st))
  (define gas-fill-last-ht (worker-sat-state-gas-fill-last-loop st))
  (define gas-pull-last-box (worker-sat-state-gas-pull-last-loop st))
  (define gas-last-fill-box (worker-sat-state-gas-last-fill-global st))
  (define gas-last-pull-box (worker-sat-state-gas-last-pull-global st))
  (define mule-idle-ht (worker-sat-state-mule-idle-last-loop st))
  (define patch-assign-ht (worker-sat-state-worker-patch-assignment st))

  (define safe-workers (if (list? worker-infos) worker-infos '()))
  (define safe-bases (if (list? base-infos) base-infos '()))
  (define safe-gas (if (list? gas-infos) gas-infos '()))
  (define safe-mins (if (list? min-infos) min-infos '()))
  (define safe-mules (if (list? mule-infos) mule-infos '()))

  ;; Active eligible workers: exclude commanded/excluded and lease-protected workers upfront
  (define workers
    (filter (lambda (w)
              (and (sat-worker-info? w)
                   (not (sat-worker-info-excluded? w))
                   (not (sat-worker-info-lease-protected? w))))
            safe-workers))
  (define idle-workers (filter worker-idle? workers))

  ;; Index mineral fields by tag
  (define min-by-tag
    (for/hasheqv ([m (in-list safe-mins)])
      (values (sat-mineral-info-tag m) m)))

  ;; Classify TownHalls (grounded ready, flying, and coming-online)
  (define flying-townhalls (filter base-is-flying? safe-bases))
  (define grounded-townhalls (filter (lambda (b) (not (base-is-flying? b))) safe-bases))
  (define ready-townhalls (filter sat-base-info-ready? grounded-townhalls))

  ;; Per-base mineral patch classification (near/far/all, cached once per step)
  (define th-mins-classified-ht (make-hasheqv))
  (define (classify-th-mins-cached th)
    (define ttag (sat-base-info-tag th))
    (or (hash-ref th-mins-classified-ht ttag #f)
        (let-values ([(n f s) (classify-base-minerals th safe-mins min-by-tag 11.5 8)])
          (define v (vector n f s))
          (hash-set! th-mins-classified-ht ttag v)
          v)))
  (define (minerals-near-th th)
    (vector-ref (classify-th-mins-cached th) 2))

  (define (th-combat-unsafe? th)
    (threat-flag? (sat-base-info-enemy-threat-near? th)))
  (define (th-safety-score th)
    (threat-score (sat-base-info-enemy-threat-near? th)))
  (define (th-local-offline? th)
    (or (null? (minerals-near-th th))
        (th-combat-unsafe? th)))

  (define safe-gas-ready-townhalls
    (filter (lambda (th) (not (th-combat-unsafe? th))) ready-townhalls))

  (define-values (offline-townhalls online-ready-townhalls)
    (let lp ([rem ready-townhalls] [off '()] [on '()])
      (cond
        [(null? rem) (values (reverse off) (reverse on))]
        [(th-local-offline? (car rem))
         (lp (cdr rem) (cons (car rem) off) on)]
        [else
         (lp (cdr rem) off (cons (car rem) on))])))

  (define coming-online-townhalls
    (filter (lambda (th)
              (and (not (sat-base-info-ready? th))
                   (not (null? (minerals-near-th th)))
                   (not (th-combat-unsafe? th))))
            grounded-townhalls))

  (define online-townhalls (append online-ready-townhalls coming-online-townhalls))
  (define safe-online-townhalls
    (sort online-townhalls fl< #:key th-safety-score))

  ;; Gas buildings: filter out depleted `vespene-contents <= 0` when live contents exist
  (define all-ready-gas-bldgs (filter sat-gas-info-ready? safe-gas))
  (define has-live-gas-contents?
    (ormap (lambda (g) (> (safe-int (sat-gas-info-vespene-contents g) 0) 0))
           all-ready-gas-bldgs))
  (define (gas-bldg-depleted? g)
    (define vc (safe-int (sat-gas-info-vespene-contents g) 0))
    (define ih (safe-int (sat-gas-info-ideal-harvesters g) 0))
    (if has-live-gas-contents?
        (<= vc 0)
        (and (<= vc 0) (<= ih 0))))
  (define ready-gas-bldgs
    (filter (lambda (g) (not (gas-bldg-depleted? g))) all-ready-gas-bldgs))
  (define depleted-gas-tags
    (for/seteqv ([g (in-list all-ready-gas-bldgs)]
                 #:when (gas-bldg-depleted? g))
      (sat-gas-info-tag g)))
  (define all-gas-tags
    (for/seteqv ([g (in-list ready-gas-bldgs)])
      (sat-gas-info-tag g)))

  ;; Single-pass worker target index
  (define in-flight-target-counts (make-hasheqv))
  (for ([w (in-list workers)])
    (define tt (worker-tgt w))
    (when (> tt 0)
      (hash-set! in-flight-target-counts tt (add1 (hash-ref in-flight-target-counts tt 0)))))
  (define (in-flight-targeting tag)
    (hash-ref in-flight-target-counts tag 0))

  ;; Worker cargo predicates
  (define (worker-carrying-gas? w)
    (or (and (sat-worker-info-carrying-gas? w) #t)
        (and (return-ability-id? (worker-ab w))
             (set-member? all-gas-tags (worker-tgt w)))))
  (define (worker-carrying-cargo? w)
    (or (and (sat-worker-info-carrying-minerals? w) #t)
        (worker-carrying-gas? w)))
  (define (worker-returning-cargo? w)
    (or (worker-carrying-cargo? w)
        (return-ability-id? (worker-ab w))))

  ;; Owned base minerals & near/far maps
  (define owned-base-minerals
    (cond
      [(pair? online-townhalls)
       (remove-duplicates (append* (map minerals-near-th online-townhalls))
                          (lambda (a b) (= (sat-mineral-info-tag a) (sat-mineral-info-tag b))))]
      [(null? ready-townhalls) safe-mins]
      [else '()]))

  (define th-near-ht (make-hasheqv))
  (define th-far-ht (make-hasheqv))
  (define th-min-tags-ht (make-hasheqv))
  (define min-is-far-ht (make-hasheqv))
  (define min-th-dist-online (make-hasheqv))
  (for ([th (in-list online-townhalls)])
    (define th-tag (sat-base-info-tag th))
    (define tx (fl-num (sat-base-info-x th)))
    (define ty (fl-num (sat-base-info-y th)))
    (define mc-v (classify-th-mins-cached th))
    (define near-m (vector-ref mc-v 0))
    (define far-m (vector-ref mc-v 1))
    (define all-m (vector-ref mc-v 2))
    (hash-set! th-near-ht th-tag near-m)
    (hash-set! th-far-ht th-tag far-m)
    (hash-set! th-min-tags-ht th-tag (for/seteqv ([m (in-list all-m)]) (sat-mineral-info-tag m)))
    (for ([m (in-list all-m)])
      (define mtag (sat-mineral-info-tag m))
      (define d (fl-dist tx ty (fl-num (sat-mineral-info-x m)) (fl-num (sat-mineral-info-y m))))
      (define prev-d (hash-ref min-th-dist-online mtag +inf.0))
      (when (fl< d prev-d)
        (hash-set! min-th-dist-online mtag d)
        (hash-set! min-is-far-ht mtag (and (memq m far-m) #t)))))

  (define (th-effective-ideal th)
    (define ih (safe-int (sat-base-info-ideal-harvesters th) 0))
    (if (> ih 0)
        ih
        (min SC2-IDEAL-WORKERS-PER-MINERAL-LINE
             (* 2 (length (minerals-near-th th))))))

  (define (th-workers-targeting-mins th)
    (define tset (hash-ref th-min-tags-ht (sat-base-info-tag th) (seteqv)))
    (count (lambda (w)
             (and (gather-ability-id? (worker-ab w))
                  (set-member? tset (worker-tgt w))))
           workers))

  (define (th-effective-assigned th)
    (define asgn (safe-int (sat-base-info-assigned-harvesters th) 0))
    (if (not (sat-base-info-ready? th))
        (max asgn (th-workers-targeting-mins th))
        asgn))

  (define (gas-eff-assigned g)
    (max (safe-int (sat-gas-info-assigned-harvesters g) 0)
         (in-flight-targeting (sat-gas-info-tag g))))

  (define active-gas-worker-count
    (count (lambda (w)
             (or (worker-carrying-gas? w)
                 (set-member? all-gas-tags (worker-tgt w))))
           workers))
  (define eff-active-gas-workers
    (max active-gas-worker-count
         (for/sum ([g (in-list ready-gas-bldgs)]) (gas-eff-assigned g))))

  (define (gas-near-any-th? gb th-list)
    (or (null? ready-townhalls)
        (let ([nb (sat-gas-info-nearest-base-tag gb)]
              [gx (fl-num (sat-gas-info-x gb))]
              [gy (fl-num (sat-gas-info-y gb))])
          (ormap (lambda (th)
                   (or (and nb (equal? nb (sat-base-info-tag th)))
                       (fl<= (fl-dist gx gy
                                      (fl-num (sat-base-info-x th))
                                      (fl-num (sat-base-info-y th)))
                             (fl-num SC2-BASE-RESOURCE-RADIUS))))
                 th-list))))

  (define (gas-bldg-threat-score gb)
    (threat-score (sat-gas-info-enemy-threat-near? gb)))
  (define (gas-bldg-lethal-slaughter? gb)
    (define v (sat-gas-info-enemy-threat-near? gb))
    (and (real? v) (>= v 5000.0)))

  ;; Zero-gas-freeze rescue state machine (300f streak -> latch until >= 150G; 224f rotate; 180f refresh)
  (define zero-gas-monitor-active?
    (and (< cur-gas 150)
         (>= (length workers) 12)
         (pair? ready-gas-bldgs)
         (not heavy-rush?)))
  (define prev-zero-gas-vespene (unbox zg-last-v-box))
  (cond
    [(not zero-gas-monitor-active?)
     (set-box! zg-streak-box #f)
     (set-box! zg-rescue-box #f)
     (set-box! zg-rot-idx-box 0)
     (set-box! zg-last-rot-box #f)
     (set-box! zg-last-ref-box #f)
     (set-box! zg-last-v-box cur-gas)]
    [(and (real? prev-zero-gas-vespene) (> cur-gas prev-zero-gas-vespene))
     (set-box! zg-streak-box #f)
     (set-box! zg-last-ref-box #f)
     (when (unbox zg-rescue-box)
       (set-box! zg-last-rot-box cur-loop))
     (set-box! zg-last-v-box cur-gas)]
    [else
     (define start-loop
       (or (unbox zg-streak-box)
           (begin
             (set-box! zg-streak-box cur-loop)
             cur-loop)))
     (cond
       [(not (unbox zg-rescue-box))
        (when (>= (- cur-loop start-loop) 300)
          (set-box! zg-rescue-box #t)
          (set-box! zg-rot-idx-box 0)
          (set-box! zg-last-rot-box cur-loop)
          (set-box! zg-last-ref-box cur-loop))]
       [else
        (define rot-base (or (unbox zg-last-rot-box) start-loop))
        (when (>= (- cur-loop rot-base) 224)
          (set-box! zg-rot-idx-box (add1 (unbox zg-rot-idx-box)))
          (set-box! zg-last-rot-box cur-loop))])
     (set-box! zg-last-v-box cur-gas)])

  (define non-lethal-ready-gas-bldgs
    (filter (lambda (gb) (not (gas-bldg-lethal-slaughter? gb))) ready-gas-bldgs))
  (define sorted-rescue-gas-bldgs
    (if (and (unbox zg-rescue-box) (pair? non-lethal-ready-gas-bldgs))
        (sort non-lethal-ready-gas-bldgs
              (lambda (a b)
                (define sa (gas-bldg-threat-score a))
                (define sb (gas-bldg-threat-score b))
                (cond
                  [(not (fl= sa sb)) (fl< sa sb)]
                  [else
                   (define na (if (gas-near-any-th? a ready-townhalls) 0 1))
                   (define nb (if (gas-near-any-th? b ready-townhalls) 0 1))
                   (if (not (= na nb))
                       (< na nb)
                       (< (sat-gas-info-tag a) (sat-gas-info-tag b)))])))
        '()))
  (define-values (gas-zero-freeze-rescue-bldg
                  gas-zero-freeze-backup-bldg
                  gas-zero-freeze-protected-bldgs)
    (cond
      [(null? sorted-rescue-gas-bldgs) (values #f #f '())]
      [else
       (define n-res (length sorted-rescue-gas-bldgs))
       (define rot-idx (unbox zg-rot-idx-box))
       (define act-idx (modulo rot-idx n-res))
       (define act-gb (list-ref sorted-rescue-gas-bldgs act-idx))
       (define bkp-cand
         (and (>= n-res 2)
              (list-ref sorted-rescue-gas-bldgs (modulo (add1 act-idx) n-res))))
       (define bkp-gb
         (and bkp-cand
              (or (> rot-idx 0)
                  (fl< (gas-bldg-threat-score bkp-cand) 5000.0))
              bkp-cand))
       (define top2-safe (take sorted-rescue-gas-bldgs (min 2 n-res)))
       (define prot-list
         (remove-duplicates
          (append top2-safe (filter values (list act-gb bkp-gb)))
          (lambda (a b) (= (sat-gas-info-tag a) (sat-gas-info-tag b)))))
       (values act-gb bkp-gb prot-list)]))
  (define gas-zero-freeze-rescue? (and gas-zero-freeze-rescue-bldg #t))

  ;; Safe vs emergency under-saturated gas buildings
  (define safe-ready-gas-bldgs
    (filter (lambda (u)
              (and (gas-near-any-th? u safe-gas-ready-townhalls)
                   (not (threat-flag? (sat-gas-info-enemy-threat-near? u)))))
            ready-gas-bldgs))
  (define safe-under-gas
    (sort
     (filter (lambda (u)
               (< (gas-eff-assigned u)
                  (max SC2-IDEAL-WORKERS-PER-GEYSER (safe-int (sat-gas-info-ideal-harvesters u) 0))))
             safe-ready-gas-bldgs)
     (lambda (a b)
       (define sa (gas-bldg-threat-score a))
       (define sb (gas-bldg-threat-score b))
       (if (fl< (flabs (fl- sa sb)) 200.0)
           (< (gas-eff-assigned a) (gas-eff-assigned b))
           (fl< sa sb)))))

  (define (emergency-gas-score gb)
    (fl+ (gas-bldg-threat-score gb)
         (if (gas-near-any-th? gb ready-townhalls) 0.0 150.0)))
  (define emergency-protected-gas-bldgs
    (if (and (null? safe-ready-gas-bldgs)
             (< cur-gas 300)
             (pair? ready-gas-bldgs))
        (let ([sorted (sort ready-gas-bldgs fl< #:key emergency-gas-score)])
          (take sorted (min 2 (length sorted))))
        '()))
  (define under-gas
    (cond
      [(pair? safe-under-gas) safe-under-gas]
      [(and (< cur-gas 250)
            (< eff-active-gas-workers 3)
            (pair? emergency-protected-gas-bldgs))
       (sort
        (filter (lambda (u)
                  (< (gas-eff-assigned u)
                     (max SC2-IDEAL-WORKERS-PER-GEYSER (safe-int (sat-gas-info-ideal-harvesters u) 0))))
                emergency-protected-gas-bldgs)
        (lambda (a b)
          (define sa (emergency-gas-score a))
          (define sb (emergency-gas-score b))
          (if (fl< (flabs (fl- sa sb)) 200.0)
              (< (gas-eff-assigned a) (gas-eff-assigned b))
              (fl< sa sb))))]
      [else '()]))

  (define under-townhalls
    (sort
     (filter (lambda (th)
               (and (pair? (minerals-near-th th))
                    (< (th-effective-assigned th) (th-effective-ideal th))))
             online-townhalls)
     fl<
     #:key th-safety-score))
  (define over-townhalls
    (filter (lambda (th)
              (> (safe-int (sat-base-info-assigned-harvesters th) 0)
                 (th-effective-ideal th)))
            online-ready-townhalls))

  ;; Output directive accumulator
  (define commanded-this-frame (mutable-seteqv))
  (define directives-rev '())
  (define (emit-dir! kind tags target-tag urgent? reason)
    (when (pair? tags)
      (set! directives-rev
            (cons (sat-directive kind tags target-tag (and urgent? #t) reason)
                  directives-rev))))
  (define (issue-gather! w target-tag
                         #:urgent? [urgent? #f]
                         #:reason [reason 'gather]
                         #:allow-carrying-mineral? [allow-carrying-mineral? #f]
                         #:allow-carrying-gas? [allow-carrying-gas? #f])
    (when (or (not (worker-carrying-cargo? w))
              (and allow-carrying-mineral? (not (worker-carrying-gas? w)))
              allow-carrying-gas?)
      (define wtag (sat-worker-info-tag w))
      (set-add! commanded-this-frame wtag)
      (emit-dir! 'harvest-gather (list wtag) target-tag urgent? reason)))

  (define owned-min-by-tag
    (for/hasheqv ([m (in-list owned-base-minerals)])
      (values (sat-mineral-info-tag m) m)))

  ;; ===========================================================================
  ;; Sec 0: 3-Race Automatic TownHall Worker-Rally Manager (`'rally-workers` 3690)
  ;;   Loop 66: `apm-pressure-backoff?` doubles routine saturation cooldown (224 -> 448f)
  ;; ===========================================================================
  (for ([fth (in-list flying-townhalls)])
    (hash-set! th-rally-ht (sat-base-info-tag fth) (vector 0 0 -1000 #t)))
  (when (and (not heavy-rush?)
             (pair? ready-townhalls)
             (pair? online-townhalls))
    (define has-live-min-contents?
      (ormap (lambda (m) (> (safe-int (sat-mineral-info-mineral-contents m) 0) 0)) safe-mins))
    (define live-rally-min-by-tag
      (for/hasheqv ([m (in-list safe-mins)]
                    #:when (or (not has-live-min-contents?)
                               (> (safe-int (sat-mineral-info-mineral-contents m) 0) 0)))
        (values (sat-mineral-info-tag m) m)))
    (define under-th-by-tag
      (for/hasheqv ([u (in-list under-townhalls)])
        (values (sat-base-info-tag u) u)))
    (define (th-not-rallied-to? cand-th src-tag)
      (define cprev (hash-ref th-rally-ht (sat-base-info-tag cand-th) #f))
      (not (and cprev (= (vector-ref cprev 0) src-tag))))
    (define open3-under-townhalls
      (filter (lambda (u)
                (>= (- (th-effective-ideal u) (th-effective-assigned u)) 3))
              under-townhalls))
    (define (pick-best-under-for src-th-tag)
      (define cands
        (filter (lambda (u)
                  (and (not (= (sat-base-info-tag u) src-th-tag))
                       (th-not-rallied-to? u src-th-tag)))
                open3-under-townhalls))
      (and (pair? cands)
           (argmin (lambda (u)
                     (fl+ (fl* 1000.0 (th-safety-score u))
                          (exact->inexact (th-effective-assigned u))))
                   cands)))
    (define safe-online-by-tag
      (for/hasheqv ([u (in-list safe-online-townhalls)])
        (values (sat-base-info-tag u) u)))
    (define best-safe-th
      (or (and (pair? under-townhalls)
               (argmin (lambda (u)
                         (fl+ (fl* 1000.0 (th-safety-score u))
                              (exact->inexact (th-effective-assigned u))))
                       under-townhalls))
          (and (pair? safe-online-townhalls) (first safe-online-townhalls))))
    (for ([th (in-list ready-townhalls)])
      (define th-tag (sat-base-info-tag th))
      (define prev (hash-ref th-rally-ht th-tag #f))
      (define prev-dst-th-tag (if prev (vector-ref prev 0) 0))
      (define cur-ptag (if prev (vector-ref prev 1) 0))
      (define last-set-loop (if prev (vector-ref prev 2) -1000))
      (define was-flying? (and prev (vector-ref prev 3)))
      (define rallied-elsewhere? (and (> prev-dst-th-tag 0) (not (= prev-dst-th-tag th-tag))))
      (define sticky-under-th
        (let ([u (and rallied-elsewhere? (hash-ref under-th-by-tag prev-dst-th-tag #f))])
          (and u (th-not-rallied-to? u th-tag) u)))
      (define best-under-for-th (pick-best-under-for th-tag))
      (define best-safe-for-th
        (or best-under-for-th
            (let ([safe-others
                   (filter (lambda (u)
                             (and (not (= (sat-base-info-tag u) th-tag))
                                  (th-not-rallied-to? u th-tag)))
                           safe-online-townhalls)])
              (and (pair? safe-others) (first safe-others)))
            best-safe-th))
      (define th-asgn (th-effective-assigned th))
      (define th-idl (th-effective-ideal th))
      (define th-off? (th-local-offline? th))
      (define dst-th
        (cond
          [th-off?
           (or sticky-under-th
               (and rallied-elsewhere?
                    (let ([su (hash-ref safe-online-by-tag prev-dst-th-tag #f)])
                      (and su (th-not-rallied-to? su th-tag) su)))
               best-safe-for-th)]
          [(and (>= (- th-asgn th-idl) 2)
                (or sticky-under-th best-under-for-th))
           (or sticky-under-th best-under-for-th)]
          ;; Loop 72 A2: After 4:30 (> 6048f), rally saturated (>= ideal) TH straight onto a safe
          ;; under-saturated 3rd/4th base (deficit >= 4) instead of waiting for +2 oversaturation!
          [(and (> cur-loop 6048)
                (>= th-asgn th-idl)
                (let ([u (or sticky-under-th best-under-for-th)])
                  (and u (>= (- (th-effective-ideal u) (th-effective-assigned u)) 4))))
           (or sticky-under-th best-under-for-th)]
          [(and rallied-elsewhere?
                (or sticky-under-th best-under-for-th)
                (> th-asgn (max 0 (- th-idl 3))))
           (or sticky-under-th best-under-for-th)]
          [else th]))
      (when dst-th
        (define dst-th-tag (sat-base-info-tag dst-th))
        (define dst-min-tags (hash-ref th-min-tags-ht dst-th-tag (seteqv)))
        (define cur-valid?
          (and (not was-flying?)
               (> cur-ptag 0)
               (set-member? dst-min-tags cur-ptag)
               (hash-has-key? live-rally-min-by-tag cur-ptag)))
        (unless cur-valid?
          (define dst-live-mins
            (filter (lambda (m) (hash-has-key? live-rally-min-by-tag (sat-mineral-info-tag m)))
                    (minerals-near-th dst-th)))
          (define prev-patch-dead?
            (and (> cur-ptag 0)
                 (not (hash-has-key? live-rally-min-by-tag cur-ptag))))
          (define urgent-rerally?
            (or (not prev)
                was-flying?
                (= cur-ptag 0)
                prev-patch-dead?))
          (define base-rally-cd
            (cond
              [urgent-rerally? 32]
              [th-off? 112]
              [else 224]))
          (define rally-cd
            (if (and apm-pressure-backoff? (not urgent-rerally?) (not th-off?))
                (* 2 base-rally-cd)
                base-rally-cd))
          (when (and (pair? dst-live-mins)
                     (>= (- cur-loop last-set-loop) rally-cd))
            (define dst-near-set
              (for/seteqv ([m (in-list (hash-ref th-near-ht dst-th-tag '()))])
                (sat-mineral-info-tag m)))
            (define best-rally-min
              (argmax (lambda (m)
                        (define mtag (sat-mineral-info-tag m))
                        (fl+ (fl* 10.0 (exact->inexact (safe-int (sat-mineral-info-mineral-contents m) 0)))
                             (if (set-member? dst-near-set mtag) 500.0 0.0)))
                      dst-live-mins))
            (define dst-ptag (sat-mineral-info-tag best-rally-min))
            (hash-set! th-rally-ht th-tag (vector dst-th-tag dst-ptag cur-loop #f))
            (emit-dir! 'rally-workers
                       (list th-tag)
                       dst-ptag
                       urgent-rerally?
                       (cond
                         [was-flying? 'rally-cc-landed]
                         [prev-patch-dead? 'rally-patch-mined-out]
                         [th-off? 'rally-combat-divert]
                         [(not prev) 'rally-initial]
                         [else 'rally-rebalance])))))))

  ;; Patch worker counts & distance index for slot pairing
  (define min-th-dist
    (for/hasheqv ([m (in-list owned-base-minerals)])
      (define mtag (sat-mineral-info-tag m))
      (define mx (fl-num (sat-mineral-info-x m)))
      (define my (fl-num (sat-mineral-info-y m)))
      (define th-d
        (if (hash-has-key? min-th-dist-online mtag)
            (hash-ref min-th-dist-online mtag)
            (if (null? ready-townhalls)
                0.0
                (for/fold ([best +inf.0]) ([th (in-list ready-townhalls)])
                  (flmin best (fl-dist (fl-num (sat-base-info-x th))
                                       (fl-num (sat-base-info-y th))
                                       mx my))))))
      (values mtag th-d)))
  (define patch-worker-counts (make-hasheqv))
  (for ([w (in-list workers)])
    (define wtag (sat-worker-info-tag w))
    (define ord-tgt
      (and (gather-ability-id? (worker-ab w))
           (hash-has-key? owned-min-by-tag (worker-tgt w))
           (worker-tgt w)))
    (define eff-tgt
      (or ord-tgt
          (let ([a (hash-ref patch-assign-ht wtag #f)])
            (and a (hash-has-key? owned-min-by-tag a) a))))
    (when eff-tgt
      (hash-set! patch-worker-counts eff-tgt (add1 (hash-ref patch-worker-counts eff-tgt 0)))))

  ;; Priority slot selector: 1st Near -> 1st Far -> 2nd Near -> 2nd Far
  (define (pick-best-slot-patch w cand-mins)
    (define wx (fl-num (sat-worker-info-x w)))
    (define wy (fl-num (sat-worker-info-y w)))
    (define under2-mins
      (filter (lambda (m) (< (hash-ref patch-worker-counts (sat-mineral-info-tag m) 0) 2))
              cand-mins))
    (if (pair? under2-mins)
        (argmin (lambda (m)
                  (define mtag (sat-mineral-info-tag m))
                  (define cnt (hash-ref patch-worker-counts mtag 0))
                  (define far? (hash-ref min-is-far-ht mtag #f))
                  (fl+ (fl* 100.0 (exact->inexact cnt))
                       (fl+ (if far? 25.0 0.0)
                            (fl+ (hash-ref min-th-dist mtag 0.0)
                                 (fl* 0.05 (fl-dist wx wy
                                                    (fl-num (sat-mineral-info-x m))
                                                    (fl-num (sat-mineral-info-y m))))))))
                under2-mins)
        (argmin (lambda (m)
                  (define mtag (sat-mineral-info-tag m))
                  (define cnt (hash-ref patch-worker-counts mtag 0))
                  (define far? (hash-ref min-is-far-ht mtag #f))
                  (fl+ (fl* 100.0 (exact->inexact cnt))
                       (fl+ (if far? 25.0 0.0)
                            (fl* 0.1 (fl-dist wx wy
                                              (fl-num (sat-mineral-info-x m))
                                              (fl-num (sat-mineral-info-y m)))))))
                cand-mins)))

  ;; Loop 66 hysteresis feedback flag: active when `gas-starvation-boost?` & `cur-gas < 300`
  (define gas-boost-active? (and gas-starvation-boost? (< cur-gas 300)))

  ;; ===========================================================================
  ;; Sec 0a: Zero-Gas-Freeze Rescue & 8s (`180f`) 0-Worker Geyser Auto-Resat
  ;; ===========================================================================
  (define midgame-multi-base-gas?
    (and (> cur-loop 4032) (>= (length online-townhalls) 2)))
  (define gas-8s-resat-blocked?
    (or heavy-rush?
        (and (<= (length workers) 12) (>= cur-gas 150) (< cur-min 120))
        (and (null? owned-base-minerals) (>= cur-gas 500) (< cur-min 200))
        (and (not gas-boost-active?)
             (or (if midgame-multi-base-gas?
                     (or (and (>= cur-gas 200) (< cur-min 110))
                         (and (>= cur-gas 260) (< cur-min 160))
                         (and (>= cur-gas 400) (< cur-min 250)))
                     (or (and (>= cur-gas 180) (< cur-min 160))
                         (and (>= cur-gas SC2-GAS-FLOAT-REBALANCE-THRESH) (< cur-min 250))))
                 (and (> cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD) (< cur-min 450))
                 (and (>= cur-gas (if midgame-multi-base-gas? 140 130))
                      (unbox gas-pull-latch-box))))))
  (define live-ready-gas-tag-set all-gas-tags)
  (for ([k (in-list (hash-keys gas-zero-since-ht))]
        #:unless (set-member? live-ready-gas-tag-set k))
    (hash-remove! gas-zero-since-ht k))
  (define zero-worker-8s-resat-bldgs
    (for/list ([gb (in-list ready-gas-bldgs)]
               #:when (let* ([gtag (sat-gas-info-tag gb)]
                             [eligible?
                              (and (= (gas-eff-assigned gb) 0)
                                   (>= (length workers) 12)
                                   (not gas-8s-resat-blocked?)
                                   (not (gas-bldg-lethal-slaughter? gb))
                                   (fl< (gas-bldg-threat-score gb) 5000.0)
                                   (or (< cur-gas 150)
                                       (gas-near-any-th? gb safe-gas-ready-townhalls)))])
                        (cond
                          [eligible?
                           (define since-l (hash-ref! gas-zero-since-ht gtag cur-loop))
                           (>= (- cur-loop since-l) 180)]
                          [else
                           (hash-remove! gas-zero-since-ht gtag)
                           #f])))
      gb))

  (define online-gas-tags
    (for/seteqv ([gb (in-list (append safe-ready-gas-bldgs
                                      emergency-protected-gas-bldgs
                                      gas-zero-freeze-protected-bldgs
                                      zero-worker-8s-resat-bldgs))])
      (sat-gas-info-tag gb)))

  (define rescue-issued-this-frame? #f)
  (define (assign-rescue-workers! rgb cap #:force-stuck-refresh? [force-stuck-refresh? #f])
    (when rgb
      (define rtag (sat-gas-info-tag rgb))
      (define rgx (fl-num (sat-gas-info-x rgb)))
      (define rgy (fl-num (sat-gas-info-y rgb)))
      (define target-w (min cap (max SC2-IDEAL-WORKERS-PER-GEYSER
                                     (safe-int (sat-gas-info-ideal-harvesters rgb) 0))))
      (define cur-assigned (gas-eff-assigned rgb))
      (define need (if force-stuck-refresh? target-w (max 0 (- target-w cur-assigned))))
      (define last-res-loop (hash-ref gas-rescue-last-ht rtag -1000))
      (when (and (> need 0)
                 (or force-stuck-refresh?
                     (>= (- cur-loop last-res-loop) 48)))
        (define rescue-cands
          (filter (lambda (w)
                    (and (not (set-member? commanded-this-frame (sat-worker-info-tag w)))
                         (not (worker-carrying-gas? w))
                         (not (if force-stuck-refresh?
                                  (= (worker-tgt w) rtag)
                                  (set-member? online-gas-tags (worker-tgt w))))))
                  workers))
        (define ranked-rescue
          (sort rescue-cands
                fl<
                #:key (lambda (w)
                        (fl+ (cond
                               [(and (not (worker-carrying-cargo? w)) (worker-idle? w)) 0.0]
                               [(not (worker-carrying-cargo? w)) 100.0]
                               [else 500.0])
                             (fl-dist rgx rgy
                                      (fl-num (sat-worker-info-x w))
                                      (fl-num (sat-worker-info-y w)))))))
        (define chosen-rescue (take ranked-rescue (min need (length ranked-rescue))))
        (when (pair? chosen-rescue)
          (hash-set! gas-rescue-last-ht rtag cur-loop)
          (define rescue-p1?
            (or (<= cur-loop 2688)
                (and gas-zero-freeze-rescue? (= eff-active-gas-workers 0))))
          (for ([rw (in-list chosen-rescue)])
            (set! rescue-issued-this-frame? #t)
            (issue-gather! rw rtag
                           #:urgent? rescue-p1?
                           #:reason 'gas-zero-freeze-rescue
                           #:allow-carrying-mineral? #t))))))

  (when gas-zero-freeze-rescue?
    (define stuck-refresh-due?
      (let ([ref-base (or (unbox zg-last-ref-box) (unbox zg-streak-box))])
        (and (real? ref-base)
             (>= (- cur-loop ref-base) 180)
             (>= (gas-eff-assigned gas-zero-freeze-rescue-bldg)
                 (min 3 (max SC2-IDEAL-WORKERS-PER-GEYSER
                             (safe-int (sat-gas-info-ideal-harvesters gas-zero-freeze-rescue-bldg) 0)))))))
    (assign-rescue-workers! gas-zero-freeze-rescue-bldg 3 #:force-stuck-refresh? stuck-refresh-due?)
    (when stuck-refresh-due?
      (set-box! zg-last-ref-box cur-loop))
    (assign-rescue-workers! gas-zero-freeze-backup-bldg 2))
  (when (and (pair? zero-worker-8s-resat-bldgs) (not gas-zero-freeze-rescue?))
    (define sorted-8s (sort zero-worker-8s-resat-bldgs fl< #:key gas-bldg-threat-score))
    (for ([gb (in-list sorted-8s)])
      (assign-rescue-workers! gb 3)))

  ;; ===========================================================================
  ;; Sec 0b: Offline Base Evacuation & Orphaned Worker Recovery (NEVER throttled by APM backoff!)
  ;; ===========================================================================
  (when (and (not heavy-rush?)
             (pair? owned-base-minerals)
             (pair? safe-online-townhalls))
    (define evac-dst-th
      (if (pair? under-townhalls) (first under-townhalls) (first safe-online-townhalls)))
    (define evac-cand-mins (minerals-near-th evac-dst-th))
    (define offline-min-tags
      (for/fold ([s (seteqv)]) ([oth (in-list offline-townhalls)])
        (for/fold ([s2 s]) ([m (in-list (minerals-near-th oth))])
          (define mtag (sat-mineral-info-tag m))
          (if (hash-has-key? owned-min-by-tag mtag) s2 (set-add s2 mtag)))))
    (define all-owned-ths (append ready-townhalls coming-online-townhalls))
    (when (pair? evac-cand-mins)
      (define evac-groups (make-hasheqv))
      (for ([w (in-list workers)]
            #:when (let* ([wtag (sat-worker-info-tag w)]
                          [wx (fl-num (sat-worker-info-x w))]
                          [wy (fl-num (sat-worker-info-y w))]
                          [ab (worker-ab w)]
                          [tgt (worker-tgt w)]
                          [targeting-online-min?
                           (and (gather-ability-id? ab)
                                (hash-has-key? owned-min-by-tag tgt))]
                          [targeting-online-gas?
                           (and (> tgt 0) (set-member? online-gas-tags tgt))]
                          [targeting-depleted-gas?
                           (and (> tgt 0) (set-member? depleted-gas-tags tgt))]
                          [unleashed-attack-chase?
                           (and (pair? all-owned-ths)
                                (attack-ability-id? ab)
                                (for/and ([th (in-list all-owned-ths)])
                                  (fl> (fl-dist wx wy
                                                (fl-num (sat-base-info-x th))
                                                (fl-num (sat-base-info-y th)))
                                       22.0)))]
                          [targeting-offline-or-orphan-min?
                           (and (gather-ability-id? ab)
                                (or (set-member? offline-min-tags tgt)
                                    (and (> tgt 0)
                                         (not (set-member? all-gas-tags tgt))
                                         (not (hash-has-key? owned-min-by-tag tgt)))))]
                          [near-offline-th?
                           (and (pair? offline-townhalls)
                                (ormap (lambda (oth)
                                         (fl<= (fl-dist wx wy
                                                        (fl-num (sat-base-info-x oth))
                                                        (fl-num (sat-base-info-y oth)))
                                               (fl-num SC2-BASE-RESOURCE-RADIUS)))
                                       offline-townhalls)
                                (for/and ([onth (in-list online-townhalls)])
                                  (fl> (fl-dist wx wy
                                                (fl-num (sat-base-info-x onth))
                                                (fl-num (sat-base-info-y onth)))
                                       (fl-num SC2-BASE-RESOURCE-RADIUS))))])
                     (and (not (set-member? commanded-this-frame wtag))
                          (not (worker-carrying-cargo? w))
                          (not (worker-carrying-gas? w))
                          (not targeting-online-gas?)
                          (not targeting-online-min?)
                          (or targeting-offline-or-orphan-min?
                              targeting-depleted-gas?
                              unleashed-attack-chase?
                              (and near-offline-th? (not (worker-returning-cargo? w)))))))
        (define wx (fl-num (sat-worker-info-x w)))
        (define wy (fl-num (sat-worker-info-y w)))
        (define src-oth
          (for/first ([oth (in-list offline-townhalls)]
                      #:when (fl<= (fl-dist wx wy
                                            (fl-num (sat-base-info-x oth))
                                            (fl-num (sat-base-info-y oth)))
                                   (fl-num SC2-BASE-RESOURCE-RADIUS)))
            (sat-base-info-tag oth)))
        (define grp-key (or src-oth 0))
        (hash-update! evac-groups grp-key (lambda (prev) (cons w prev)) '()))
      (define evac-cd (if (> cur-loop 4032) 32 24))
      (for ([(grp-key grp-ws-rev) (in-hash evac-groups)])
        (when (>= (- cur-loop (hash-ref evac-last-ht grp-key -1000)) evac-cd)
          (define grp-ws (reverse grp-ws-rev))
          (define best-min (pick-best-slot-patch (first grp-ws) evac-cand-mins))
          (define bmtag (sat-mineral-info-tag best-min))
          (define evac-wtags
            (for/list ([w (in-list grp-ws)])
              (define wtag (sat-worker-info-tag w))
              (set-add! commanded-this-frame wtag)
              (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
              (hash-set! patch-assign-ht wtag bmtag)
              wtag))
          (when (pair? evac-wtags)
            (hash-set! evac-last-ht grp-key cur-loop)
            (emit-dir! 'harvest-gather evac-wtags bmtag #t 'offline-base-evac))))))

  ;; Safe map minerals fallback when all owned bases are mined out
  (define safe-map-minerals
    (if (null? owned-base-minerals)
        (let* ([has-live? (ormap (lambda (m) (> (safe-int (sat-mineral-info-mineral-contents m) 0) 0)) safe-mins)]
               [safe-live (filter (lambda (m)
                                    (and (sat-mineral-info-safe-for-mule? m)
                                         (or (not has-live?)
                                             (> (safe-int (sat-mineral-info-mineral-contents m) 0) 0))))
                                  safe-mins)])
          safe-live)
        '()))
  (define (pick-nearest-safe-map-mineral w cand-mins)
    (define wx (fl-num (sat-worker-info-x w)))
    (define wy (fl-num (sat-worker-info-y w)))
    (argmin (lambda (m)
              (define cnt (hash-ref patch-worker-counts (sat-mineral-info-tag m) 0))
              (fl+ (fl-dist wx wy (fl-num (sat-mineral-info-x m)) (fl-num (sat-mineral-info-y m)))
                   (fl* 1.5 (exact->inexact cnt))))
            cand-mins))

  ;; ===========================================================================
  ;; Sec 1: Idle Worker Recovery (NEVER throttled by APM backoff!)
  ;; ===========================================================================
  (cond
    [(and (not heavy-rush?) (pair? idle-workers) (pair? owned-base-minerals))
     (cond
       [(<= cur-loop 2688)
        (define candidate-mins
          (if (pair? under-townhalls)
              (minerals-near-th (first under-townhalls))
              owned-base-minerals))
        (define sorted-cand-mins
          (sort candidate-mins fl< #:key (lambda (m) (hash-ref min-th-dist (sat-mineral-info-tag m) 999.0))))
        (for ([w (in-list idle-workers)]
              #:when (and (not (set-member? commanded-this-frame (sat-worker-info-tag w)))
                          (not (worker-returning-cargo? w))))
          (define wtag (sat-worker-info-tag w))
          (define best-min (pick-best-slot-patch w sorted-cand-mins))
          (define bmtag (sat-mineral-info-tag best-min))
          (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
          (hash-set! patch-assign-ht wtag bmtag)
          (issue-gather! w bmtag #:urgent? #t #:reason 'idle-worker-recovery))]
       [else
        (define idle-cd (if (> cur-loop 4032) 32 24))
        (define idle-by-dst (make-hasheqv))
        (define dst-cand-mins-ht (make-hasheqv))
        (for ([w (in-list idle-workers)]
              #:when (let ([wtag (sat-worker-info-tag w)])
                       (and (not (set-member? commanded-this-frame wtag))
                            (not (worker-carrying-cargo? w))
                            (not (worker-returning-cargo? w))
                            (>= (- cur-loop (hash-ref idle-last-ht wtag -1000)) idle-cd))))
          (define dst-th
            (cond
              [(pair? under-townhalls) (first under-townhalls)]
              [(pair? safe-online-townhalls)
               (define wx (fl-num (sat-worker-info-x w)))
               (define wy (fl-num (sat-worker-info-y w)))
               (argmin (lambda (th)
                         (fl-dist wx wy (fl-num (sat-base-info-x th)) (fl-num (sat-base-info-y th))))
                       safe-online-townhalls)]
              [else #f]))
          (define dkey (if dst-th (sat-base-info-tag dst-th) 0))
          (unless (hash-has-key? dst-cand-mins-ht dkey)
            (hash-set! dst-cand-mins-ht dkey
                       (if (and dst-th (pair? (minerals-near-th dst-th)))
                           (minerals-near-th dst-th)
                           owned-base-minerals)))
          (hash-update! idle-by-dst dkey (lambda (prev) (cons w prev)) '()))
        (for ([(dkey grp-rev) (in-hash idle-by-dst)])
          (define grp (reverse grp-rev))
          (define cmins (hash-ref dst-cand-mins-ht dkey owned-base-minerals))
          (when (and (pair? grp) (pair? cmins))
            (define best-min (pick-best-slot-patch (first grp) cmins))
            (define bmtag (sat-mineral-info-tag best-min))
            (define wtags
              (for/list ([w (in-list grp)])
                (define wtag (sat-worker-info-tag w))
                (set-add! commanded-this-frame wtag)
                (hash-set! idle-last-ht wtag cur-loop)
                (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
                (hash-set! patch-assign-ht wtag bmtag)
                wtag))
            (emit-dir! 'harvest-gather wtags bmtag #t 'idle-worker-recovery)))])]
    [(and (not heavy-rush?) (null? owned-base-minerals) (pair? safe-map-minerals))
     (for ([w (in-list idle-workers)]
           #:when (let ([wtag (sat-worker-info-tag w)])
                    (and (not (set-member? commanded-this-frame wtag))
                         (not (worker-returning-cargo? w))
                         (or (<= cur-loop 2688)
                             (>= (- cur-loop (hash-ref idle-last-ht wtag -1000)) 24)))))
       (define wtag (sat-worker-info-tag w))
       (hash-set! idle-last-ht wtag cur-loop)
       (define best-min (pick-nearest-safe-map-mineral w safe-map-minerals))
       (define bmtag (sat-mineral-info-tag best-min))
       (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
       (issue-gather! w bmtag #:urgent? #f #:reason 'idle-long-distance-mine))])

  ;; ===========================================================================
  ;; Sec 2: Gas Building Refill + Hysteresis Latch Update
  ;;   Loop 66: `gas-starvation-boost?` (`cur-gas < 300`) suppresses early pullback
  ;;            and raises refill cap from 1 -> 2 workers/step (up to ideal <= 3)!
  ;; ===========================================================================
  (define self-is-zerg? (eq? race-sym 'Zerg))
  (cond
    [(if midgame-multi-base-gas?
         (or (and (>= cur-gas 200) (< cur-min 110))
             (and (>= cur-gas 260) (< cur-min 160))
             (and (>= cur-gas 400) (< cur-min 250))
             (and (> cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD) (< cur-min 450)))
         (or (and (>= cur-gas 180) (< cur-min 160))
             (and (>= cur-gas SC2-GAS-FLOAT-REBALANCE-THRESH) (< cur-min 250))
             (and (> cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD) (< cur-min 450))))
     (set-box! gas-pull-latch-box #t)]
    [(or (>= cur-min 450)
         (and (<= cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD)
              (if midgame-multi-base-gas?
                  (or (< cur-gas 140) (>= cur-min 280))
                  (or (< cur-gas 130) (>= cur-min 280)))))
     (set-box! gas-pull-latch-box #f)])

  (define zerg-post-speed-surge-active?
    (and self-is-zerg?
         (< cur-loop 5040)
         (>= (length online-townhalls) 2)
         (< (length workers) 28)
         (< cur-min 250)
         (>= cur-gas 108)))
  (define worker-crisis-gas-evac?
    (and (<= (length workers) 12)
         (>= cur-gas 150)
         (< cur-min 120)))
  (define mined-out-safe-map-minerals
    (if (and (null? owned-base-minerals) (>= cur-gas 500) (< cur-min 200))
        safe-map-minerals
        '()))
  (define mined-out-gas-starved?
    (and (null? owned-base-minerals)
         (>= cur-gas 500)
         (< cur-min 200)))
  (define mined-out-gas-evac?
    (and mined-out-gas-starved?
         (pair? mined-out-safe-map-minerals)))
  (define gas-over-banked?
    (or worker-crisis-gas-evac?
        mined-out-gas-starved?
        (and (not gas-boost-active?)
             (unbox gas-pull-latch-box))))
  (define gas-pull-to-zero-now?
    (or worker-crisis-gas-evac?
        mined-out-gas-starved?
        (and gas-over-banked?
             (or (>= cur-gas 300)
                 (and (>= cur-gas 260) (< cur-min 120))))))
  (define gas-resaturate-blocked?
    (or gas-pull-to-zero-now?
        heavy-rush?
        (and gas-over-banked? (>= eff-active-gas-workers 1))
        (and zerg-post-speed-surge-active? (not gas-boost-active?) (>= eff-active-gas-workers 1))))

  (define (req-mineral-workers-for-gas-slot g)
    (cond
      [(= g 0) 6]
      [(= g 1) 8]
      [(= g 2) 10]
      [(< g 6) (if (or (>= cur-min 300) gas-boost-active?) 10 18)]
      [else    (if (>= cur-min 400) 14 28)]))
  (define min-mineral-workers-for-next-gas
    (req-mineral-workers-for-gas-slot eff-active-gas-workers))

  (when (and (not rescue-issued-this-frame?)
             (pair? under-gas)
             (or (and (null? owned-base-minerals) (not mined-out-gas-starved?))
                 (>= (- (length workers) active-gas-worker-count)
                     min-mineral-workers-for-next-gas))
             (not gas-resaturate-blocked?))
    (define gb (first under-gas))
    (define gtag (sat-gas-info-tag gb))
    (define gb-asgn (gas-eff-assigned gb))
    (define gx (fl-num (sat-gas-info-x gb)))
    (define gy (fl-num (sat-gas-info-y gb)))
    (define zero-gas-workers-now? (= eff-active-gas-workers 0))
    (define prev-fill (hash-ref gas-fill-last-ht gtag #f))
    (define fill-retry-cd (if (and zero-gas-workers-now? (< cur-gas 100)) 24 32))
    (define fill-retry-throttled?
      (and prev-fill
           (< (- cur-loop (car prev-fill)) fill-retry-cd)
           (<= gb-asgn (cdr prev-fill))))
    (define fill-opp-throttled?
      (and (< (- cur-loop (unbox gas-last-pull-box)) 112)
           (not (and zero-gas-workers-now? (< cur-gas 100)))
           (not gas-boost-active?)))
    (when (and (not fill-retry-throttled?) (not fill-opp-throttled?))
      (define (eligible-for-gas? w)
        (and (not (set-member? commanded-this-frame (sat-worker-info-tag w)))
             (not (worker-carrying-cargo? w))
             (not (worker-returning-cargo? w))
             (not (set-member? all-gas-tags (worker-tgt w)))
             (or zero-gas-workers-now?
                 (worker-idle? w)
                 (for/and ([other-gb (in-list ready-gas-bldgs)])
                   (fl> (fl-dist (fl-num (sat-gas-info-x other-gb))
                                 (fl-num (sat-gas-info-y other-gb))
                                 (fl-num (sat-worker-info-x w))
                                 (fl-num (sat-worker-info-y w)))
                        (fl-num SC2-GAS-HARVESTER-EXCLUSION-RADIUS))))))
      (define eligible-idle (filter eligible-for-gas? idle-workers))
      (define eligible-all (filter eligible-for-gas? workers))
      (define fallback-carrying-min
        (if (and (null? eligible-idle)
                 (null? eligible-all)
                 zero-gas-workers-now?
                 (< cur-gas 180))
            (filter (lambda (w)
                      (and (not (set-member? commanded-this-frame (sat-worker-info-tag w)))
                           (not (worker-carrying-gas? w))
                           (not (set-member? all-gas-tags (worker-tgt w)))))
                    workers)
            '()))
      (define-values (candidate-workers allow-carry?)
        (cond
          [(pair? eligible-idle) (values eligible-idle #f)]
          [(pair? eligible-all) (values eligible-all #f)]
          [else (values fallback-carrying-min #t)]))
      (when (pair? candidate-workers)
        (define gb-ideal (min 3 (max SC2-IDEAL-WORKERS-PER-GEYSER
                                     (safe-int (sat-gas-info-ideal-harvesters gb) 0))))
        (define gb-need (min 3 (max 0 (- gb-ideal gb-asgn))))
        (define cur-min-workers (- (length workers) active-gas-worker-count))
        (define max-fill-by-floor
          (if (null? owned-base-minerals)
              gb-need
              (let loop ([k 0] [g eff-active-gas-workers] [m cur-min-workers])
                (define req-m (req-mineral-workers-for-gas-slot g))
                (if (and (< k gb-need) (>= m req-m))
                    (loop (add1 k) (add1 g) (sub1 m))
                    k))))
        (define fill-cap
          (cond
            [gas-boost-active?
             (min (if allow-carry? 2 3) max-fill-by-floor)]
            [(or allow-carry? gas-over-banked? zerg-post-speed-surge-active?)
             (min 1 max-fill-by-floor)]
            [else max-fill-by-floor]))
        (when (> fill-cap 0)
          (define ranked-gas-ws
            (sort candidate-workers
                  fl<
                  #:key (lambda (w)
                          (fl-dist gx gy
                                   (fl-num (sat-worker-info-x w))
                                   (fl-num (sat-worker-info-y w))))))
          (define chosen-gas-ws (take ranked-gas-ws (min fill-cap (length ranked-gas-ws))))
          (define fill-wtags
            (for/list ([w (in-list chosen-gas-ws)]
                       #:when (or (not (worker-carrying-cargo? w))
                                  (and allow-carry? (not (worker-carrying-gas? w)))))
              (define wtag (sat-worker-info-tag w))
              (set-add! commanded-this-frame wtag)
              wtag))
          (when (pair? fill-wtags)
            (hash-set! gas-fill-last-ht gtag (cons cur-loop gb-asgn))
            (set-box! gas-last-fill-box cur-loop)
            (define fill-p1?
              (or (<= cur-loop 2688)
                  zero-gas-workers-now?
                  gas-boost-active?
                  (and (< cur-gas 180) (not gas-resaturate-blocked?))))
            (emit-dir! 'harvest-gather fill-wtags gtag fill-p1?
                       (if gas-boost-active? 'gas-refill-boosted 'gas-refill)))))))

  ;; ===========================================================================
  ;; Sec 3: Inter-Base Over-Saturated Mineral Transfer
  ;;   Loop 66: `apm-pressure-backoff?` doubles per-base cooldown (`48 -> 96f`)
  ;; ===========================================================================
  (when (and (not heavy-rush?)
             (pair? under-townhalls)
             (pair? owned-base-minerals))
    (define dst-th
      (argmin (lambda (th)
                (fl+ (fl* 1000.0 (th-safety-score th))
                     (exact->inexact (th-effective-assigned th))))
              under-townhalls))
    (define dx (fl-num (sat-base-info-x dst-th)))
    (define dy (fl-num (sat-base-info-y dst-th)))
    (define dst-tag (sat-base-info-tag dst-th))
    (define dst-ih (th-effective-ideal dst-th))
    (define dst-deficit (max 0 (- dst-ih (th-effective-assigned dst-th))))
    (define dst-mins (minerals-near-th dst-th))
    (define dst-near-mins (hash-ref th-near-ht dst-tag '()))
    (define dst-min-tags (for/seteqv ([m (in-list dst-mins)]) (sat-mineral-info-tag m)))
    (define in-flight-to-dst
      (count (lambda (w)
               (and (fl> (fl-dist dx dy
                                  (fl-num (sat-worker-info-x w))
                                  (fl-num (sat-worker-info-y w)))
                         8.0)
                    (set-member? dst-min-tags (worker-tgt w))))
             workers))
    (define dst-near-slots-needed
      (for/sum ([m (in-list dst-near-mins)])
        (max 0 (- 2 (hash-ref patch-worker-counts (sat-mineral-info-tag m) 0)))))
    (define early-natural-split?
      (and (<= cur-loop 6048)
           (>= (length dst-mins) 4)
           (< (th-effective-assigned dst-th) 8)))
    ;; Loop 72 A2: Post-4:30 (> 6048f) safe 3rd/4th-base kickstart (never drop any donor < 12!)
    (define midgame-newbase-kickstart?
      (and (> cur-loop 6048)
           (>= (length online-ready-townhalls) 3)
           (>= (length dst-mins) 6)
           (< (th-effective-assigned dst-th) 6)))
    (define midgame-donors
      (if midgame-newbase-kickstart?
          (filter (lambda (th)
                    (and (not (= (sat-base-info-tag th) dst-tag))
                         (>= (th-effective-assigned th) 15)))
                  online-ready-townhalls)
          '()))
    (define donor-min-workers (if early-natural-split? 12 14))
    (define donor-keep-workers (if early-natural-split? 10 13))
    (define donor-candidates
      (if (<= cur-loop 6048)
          (filter (lambda (th)
                    (and (not (= (sat-base-info-tag th) dst-tag))
                         (>= (th-effective-assigned th) donor-min-workers)))
                  online-ready-townhalls)
          '()))
    (define-values (src-th _src-surplus transfer-limit transfer-eligible?)
      (cond
        [(pair? over-townhalls)
         (define sth (first over-townhalls))
         (define sth-surp (max 0 (- (safe-int (sat-base-info-assigned-harvesters sth) 0)
                                    (th-effective-ideal sth))))
         (define rem-surp (max 0 (- sth-surp in-flight-to-dst)))
         (define rem-def (max 0 (- dst-deficit in-flight-to-dst)))
         (define lim (min (cond
                            [(and (> cur-loop 6048) (>= rem-surp 4) (>= rem-def 4)) 4]
                            [(or early-natural-split? (>= rem-surp 2)) 2]
                            [else 1])
                          rem-surp rem-def))
         (values sth
                 sth-surp
                 lim
                 (and (not (= (sat-base-info-tag sth) dst-tag))
                      (if (> cur-loop 6048)
                          (or (>= sth-surp 2)
                              (and (>= sth-surp 1) (< (th-effective-assigned dst-th) 8)))
                          (>= (+ sth-surp dst-deficit) 2))
                      (> lim 0)))]
        [(and (<= cur-loop 6048) (pair? donor-candidates) (> dst-near-slots-needed 0))
         (define sth (argmax th-effective-assigned donor-candidates))
         (define sth-surp (max 0 (- (th-effective-assigned sth) donor-keep-workers)))
         (define rem-near (max 0 (- dst-near-slots-needed in-flight-to-dst)))
         (define rem-surp (max 0 (- sth-surp in-flight-to-dst)))
         (define rem-def (max 0 (- dst-deficit in-flight-to-dst)))
         (define lim (min (if (or early-natural-split? (>= rem-surp 2)) 2 1) rem-near rem-surp rem-def))
         (values sth sth-surp lim (> lim 0))]
        [(and midgame-newbase-kickstart? (pair? midgame-donors))
         (define sth (argmax th-effective-assigned midgame-donors))
         (define sth-surp (max 0 (- (th-effective-assigned sth) 12)))
         (define rem-surp (max 0 (- sth-surp in-flight-to-dst)))
         (define rem-def (max 0 (- (- 6 (th-effective-assigned dst-th)) in-flight-to-dst)))
         (define lim (min 4 rem-surp rem-def))
         (values sth sth-surp lim (> lim 0))]
        [else (values #f 0 0 #f)]))
    (define xfer-base-cd (if apm-pressure-backoff? 96 48))
    (when (and src-th
               transfer-eligible?
               (pair? dst-mins)
               (>= (- cur-loop (hash-ref xfer-base-cd-ht (sat-base-info-tag src-th) -1000))
                   xfer-base-cd))
      (define sx (fl-num (sat-base-info-x src-th)))
      (define sy (fl-num (sat-base-info-y src-th)))
      (define transferable
        (filter (lambda (w)
                  (define wtag (sat-worker-info-tag w))
                  (define wx (fl-num (sat-worker-info-x w)))
                  (define wy (fl-num (sat-worker-info-y w)))
                  (define tgt (worker-tgt w))
                  (and (not (set-member? commanded-this-frame wtag))
                       (>= cur-loop (hash-ref xfer-cd-ht wtag 0))
                       (not (worker-carrying-cargo? w))
                       (not (worker-returning-cargo? w))
                       (not (set-member? all-gas-tags tgt))
                       (not (set-member? dst-min-tags tgt))
                       (fl<= (fl-dist sx sy wx wy) (fl-num SC2-BASE-RESOURCE-RADIUS))
                       (for/and ([gb (in-list ready-gas-bldgs)])
                         (fl> (fl-dist (fl-num (sat-gas-info-x gb))
                                       (fl-num (sat-gas-info-y gb))
                                       wx wy)
                              (fl-num SC2-GAS-HARVESTER-EXCLUSION-RADIUS)))))
                workers))
      (when (pair? transferable)
        (define (xfer-worker-score w)
          (define wtag (sat-worker-info-tag w))
          (define wx (fl-num (sat-worker-info-x w)))
          (define wy (fl-num (sat-worker-info-y w)))
          (define ord-tgt (and (gather-ability-id? (worker-ab w)) (worker-tgt w)))
          (define eff-tgt (or ord-tgt (hash-ref patch-assign-ht wtag #f)))
          (define patch-far?
            (if (and eff-tgt (hash-has-key? min-is-far-ht eff-tgt))
                (hash-ref min-is-far-ht eff-tgt #f)
                (fl>= (fl-dist sx sy wx wy) 6.75)))
          (fl+ (if patch-far? -25.0 25.0)
               (fl+ (if (worker-idle? w) -5.0 0.0)
                    (fl* 0.1 (fl-dist dx dy wx wy)))))
        (define ranked-xfers (sort transferable fl< #:key xfer-worker-score))
        (define chosen-xfers (take ranked-xfers (min transfer-limit (length ranked-xfers))))
        (when (pair? chosen-xfers)
          (hash-set! xfer-base-cd-ht (sat-base-info-tag src-th) cur-loop)
          (cond
            [early-natural-split?
             (for ([chosen-w (in-list chosen-xfers)])
               (define wtag (sat-worker-info-tag chosen-w))
               (define best-dst-min (pick-best-slot-patch chosen-w dst-mins))
               (define bmtag (sat-mineral-info-tag best-dst-min))
               (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
               (hash-set! patch-assign-ht wtag bmtag)
               (hash-set! xfer-cd-ht wtag (+ cur-loop 96))
               (issue-gather! chosen-w bmtag #:urgent? #t #:reason 'early-natural-transfer))]
            [else
             (define best-dst-min (pick-best-slot-patch (first chosen-xfers) dst-mins))
             (define bmtag (sat-mineral-info-tag best-dst-min))
             (define xfer-wtags
               (for/list ([chosen-w (in-list chosen-xfers)])
                 (define wtag (sat-worker-info-tag chosen-w))
                 (set-add! commanded-this-frame wtag)
                 (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
                 (hash-set! patch-assign-ht wtag bmtag)
                 (hash-set! xfer-cd-ht wtag (+ cur-loop 96))
                 wtag))
             (emit-dir! 'harvest-gather xfer-wtags bmtag #f 'inter-base-transfer)])))))

  ;; ===========================================================================
  ;; Sec 4: Gas Pullback Back to Minerals Under Hysteresis Latch
  ;;   Loop 66: Suppressed while `gas-starvation-boost?` & `cur-gas < 300`
  ;;            (still honoring `worker-crisis-gas-evac?` & `mined-out-gas-starved?`)
  ;; ===========================================================================
  (define grms-urgent-pull?
    (and gas-over-banked? (>= cur-gas 200) (< cur-min 110)))
  (define gas-pull-target-floor
    (cond
      [gas-pull-to-zero-now? 0]
      [(or gas-over-banked? (and zerg-post-speed-surge-active? (not gas-boost-active?))) 1]
      [else eff-active-gas-workers]))
  (define max-gas-pulls-this-step
    (if (and (not gas-zero-freeze-rescue?)
             (or (not gas-boost-active?)
                 worker-crisis-gas-evac?
                 mined-out-gas-starved?)
             (or gas-over-banked? zerg-post-speed-surge-active?))
        (let ([per-step-cap (if (>= eff-active-gas-workers 4) 3 2)])
          (min per-step-cap (max 0 (- eff-active-gas-workers gas-pull-target-floor))))
        0))
  (define gas-pull-cand-mins
    (cond
      [(and (pair? under-townhalls) (pair? owned-base-minerals))
       (minerals-near-th (first under-townhalls))]
      [(pair? owned-base-minerals) owned-base-minerals]
      [mined-out-gas-evac? mined-out-safe-map-minerals]
      [else '()]))
  (define prev-pull-state (unbox gas-pull-last-box))
  (define pull-retry-throttled?
    (and (< (- cur-loop (car prev-pull-state)) 32)
         (>= eff-active-gas-workers (cdr prev-pull-state))))
  (define pull-opp-throttled?
    (and (< (- cur-loop (unbox gas-last-fill-box)) 112)
         (not grms-urgent-pull?)
         (not worker-crisis-gas-evac?)
         (not mined-out-gas-evac?)))
  (when (and (> max-gas-pulls-this-step 0)
             (not pull-retry-throttled?)
             (not pull-opp-throttled?)
             (pair? gas-pull-cand-mins)
             (pair? ready-gas-bldgs))
    (define cand-mins gas-pull-cand-mins)
    (define (targeting-gas-bldg? w)
      (set-member? all-gas-tags (worker-tgt w)))
    (define allow-carrying-gas-pull?
      (or (and (>= cur-gas 200) (< cur-min 120))
          worker-crisis-gas-evac?
          mined-out-gas-evac?))
    (define non-carrying-gas-workers
      (filter (lambda (w)
                (and (not (set-member? commanded-this-frame (sat-worker-info-tag w)))
                     (not (worker-carrying-cargo? w))
                     (not (worker-returning-cargo? w))
                     (targeting-gas-bldg? w)))
              workers))
    (define carrying-gas-workers
      (if allow-carrying-gas-pull?
          (filter (lambda (w)
                    (and (not (set-member? commanded-this-frame (sat-worker-info-tag w)))
                         (or (worker-carrying-gas? w)
                             (and (or (worker-carrying-cargo? w) (worker-returning-cargo? w))
                                  (targeting-gas-bldg? w)))))
                  workers)
          '()))
    (define pull-candidates (append non-carrying-gas-workers carrying-gas-workers))
    (define chosen-pulls
      (take pull-candidates (min max-gas-pulls-this-step (length pull-candidates))))
    (when (pair? chosen-pulls)
      (set-box! gas-pull-last-box (cons cur-loop eff-active-gas-workers))
      (set-box! gas-last-pull-box cur-loop)
      (cond
        [(and (null? owned-base-minerals) mined-out-gas-evac?)
         (for ([gw (in-list chosen-pulls)])
           (define best-min (pick-nearest-safe-map-mineral gw cand-mins))
           (define bmtag (sat-mineral-info-tag best-min))
           (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
           (issue-gather! gw bmtag
                          #:urgent? (<= cur-loop 2688)
                          #:reason 'gas-pull-mined-out-evac
                          #:allow-carrying-gas? allow-carrying-gas-pull?))]
        [(<= cur-loop 2688)
         (for ([gw (in-list chosen-pulls)])
           (define wtag (sat-worker-info-tag gw))
           (define best-min (pick-best-slot-patch gw cand-mins))
           (define bmtag (sat-mineral-info-tag best-min))
           (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
           (hash-set! patch-assign-ht wtag bmtag)
           (issue-gather! gw bmtag
                          #:urgent? #t
                          #:reason 'gas-pull-early
                          #:allow-carrying-gas? allow-carrying-gas-pull?))]
        [else
         (define best-min (pick-best-slot-patch (first chosen-pulls) cand-mins))
         (define bmtag (sat-mineral-info-tag best-min))
         (define pull-wtags
           (for/list ([gw (in-list chosen-pulls)]
                      #:when (or (not (worker-carrying-cargo? gw))
                                 allow-carrying-gas-pull?))
             (define wtag (sat-worker-info-tag gw))
             (set-add! commanded-this-frame wtag)
             (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
             (hash-set! patch-assign-ht wtag bmtag)
             wtag))
         (when (pair? pull-wtags)
           (emit-dir! 'harvest-gather pull-wtags bmtag grms-urgent-pull?
                      (if grms-urgent-pull? 'gas-pull-grms-urgent 'gas-pull-routine)))])))

  ;; ===========================================================================
  ;; Sec 5: Idle MULE Re-Tasking Onto Nearby Safe Mineral Patches
  ;; ===========================================================================
  (when (and (pair? owned-base-minerals) (pair? safe-mules))
    (for ([m (in-list safe-mules)]
          #:when (and (sat-mule-info? m)
                      (sat-mule-info-idle? m)
                      (>= (- cur-loop (hash-ref mule-idle-ht (sat-mule-info-tag m) -1000)) 24)))
      (define mtag (sat-mule-info-tag m))
      (define ux (fl-num (sat-mule-info-x m)))
      (define uy (fl-num (sat-mule-info-y m)))
      (define near-owned-mins
        (filter (lambda (mp)
                  (define mx (fl-num (sat-mineral-info-x mp)))
                  (define my (fl-num (sat-mineral-info-y mp)))
                  (and (sat-mineral-info-safe-for-mule? mp)
                       (fl<= (fl-dist ux uy mx my) 14.0)
                       (or (null? ready-townhalls)
                           (ormap (lambda (th)
                                    (fl<= (fl-dist mx my
                                                   (fl-num (sat-base-info-x th))
                                                   (fl-num (sat-base-info-y th)))
                                          12.0))
                                  ready-townhalls))))
                owned-base-minerals))
      (when (pair? near-owned-mins)
        (define best-m
          (argmin (lambda (mp)
                    (fl-dist ux uy (fl-num (sat-mineral-info-x mp)) (fl-num (sat-mineral-info-y mp))))
                  near-owned-mins))
        (hash-set! mule-idle-ht mtag cur-loop)
        (emit-dir! 'harvest-gather
                   (list mtag)
                   (sat-mineral-info-tag best-m)
                   (<= cur-loop 2688)
                   'mule-idle-retask))))

  (reverse directives-rev))
