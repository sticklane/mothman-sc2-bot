#lang racket/base

;; =============================================================================
;; `lib/tactics/order-ledger.rkt`
;; In-Progress Order Ledger, Command Deduplication, Build-Site Reservation &
;; Order Reconciler + Kite/Focus-Fire Execution Helpers.
;; =============================================================================

(require racket/match
         racket/list
         racket/math
         racket/set
         racket/string
         "../sc2-common.rkt"
         "../sc2-game-constants.rkt"
         (only-in "../sc2-geometry.rkt"
                  snap-2x2-coord
                  snap-3x3-coord)
         "../sc2-combat-eval.rkt")

(provide
 (struct-out tracked-order)
 (struct-out reserved-build-site)
 (struct-out in-progress-order-ledger)
 KNOWN-BUILDING-ORDER-SYMS
 classify-engine-order-kind
 engine-order-target-symbol
 make-order-ledger
 order-ledger-reconcile-observation!
 order-ledger-record-issued!
 order-ledger-unit-active-order
 order-ledger-unit-has-active-build?
 order-ledger-pending-count-for-type
 order-ledger-facility-busy?
 order-ledger-unit-in-attack-swing?
 order-ledger-order-equivalent?
 order-ledger-reserve-build-site!
 order-ledger-resolve-build-coords!
 select-focus-fire-target
 compute-kite-vector)

(struct tracked-order
  (unit-id
   kind          ;; 'build 'expand 'train 'morph 'research 'attack-unit 'attack-pos 'kite 'move 'hold-position 'cast-spell
   ability-sym   ;; symbol e.g. 'pylon 'overlord 'attack 'move 'cloak-banshee
   target-id     ;; integer unit tag or 0
   target-x      ;; real world X or #f
   target-y      ;; real world Y or #f
   issued-frame  ;; frame when first observed/issued
   last-seen-frame
   progress      ;; 0.0 .. 1.0
   source)       ;; 'engine or 'issued
  #:mutable
  #:transparent)

(struct reserved-build-site
  (bldg-sym
   x
   y
   builder-id
   issued-frame
   expires-frame)
  #:mutable
  #:transparent)

(struct in-progress-order-ledger
  (unit-orders       ;; mutable hash: unit-id -> tracked-order
   type-order-counts ;; mutable hash: ability-sym -> count of active orders
   reserved-sites    ;; list of reserved-build-site
   step-issued-units);; mutable seteqv of unit-ids already given an order on current step
  #:mutable
  #:transparent)

(define (make-order-ledger)
  (in-progress-order-ledger (make-hasheqv) (make-hasheq) '() (mutable-seteqv)))

(define KNOWN-BUILDING-ORDER-SYMS
  '(command-center orbital-command planetary-fortress supply-depot refinery
    barracks barracks-techlab barracks-tech-lab barracks-reactor
    factory factory-techlab factory-tech-lab factory-reactor
    starport starport-techlab starport-tech-lab starport-reactor
    tech-lab techlab reactor
    engineering-bay missile-turret bunker sensor-tower ghost-academy armory fusion-core
    nexus pylon assimilator gateway warp-gate warpgate forge cybernetics-core
    photon-cannon shield-battery twilight-council stargate
    templar-archive templar-archives dark-shrine robotics-bay robotics-support-bay
    robotics-facility fleet-beacon
    hatchery lair hive extractor spawning-pool evolution-chamber roach-warren baneling-nest
    spine-crawler spore-crawler hydralisk-den lurker-den lurker-den-mp spire greater-spire
    infestation-pit nydus-network nydus-worm nydus-canal ultralisk-cavern))

(define (classify-engine-order-kind ab-id ab-sym)
  (define canon (sc2-canonical-order-ability ab-id))
  (define s (if ab-sym (symbol->string ab-sym) ""))
  (cond
    [(or (eq? canon 'attack) (eq? ab-sym 'attack) (eq? ab-sym 'attack-attack))
     'attack]
    [(or (eq? canon 'move) (eq? ab-sym 'move) (eq? ab-sym 'smart))
     'move]
    [(or (eq? canon 'hold-position) (eq? ab-sym 'hold-position))
     'hold-position]
    [(or (eq? canon 'patrol) (eq? ab-sym 'patrol))
     'patrol]
    [(or (memq canon '(harvest-gather harvest-return))
         (memq ab-sym '(harvest harvest-gather harvest-return)))
     'harvest]
    [(or (eq? canon 'repair) (eq? ab-sym 'repair))
     'repair]
    [(or (eq? canon 'lift) (memq ab-sym '(lift lift-building)))
     'lift]
    [(or (eq? canon 'land) (memq ab-sym '(land land-building)))
     'land]
    [(or (memq canon '(burrow-down burrow-up uproot root))
         (memq ab-sym '(burrow-down burrow-up uproot root)))
     (if (symbol? canon) canon ab-sym)]
    [(or (memv ab-id '(318 880 1152))
         (memq ab-sym '(build-command-center build-nexus build-hatchery
                        command-center nexus hatchery expand)))
     'expand]
    [(memv ab-id '(1216 1218 1220 2112 1516 1450 1518))
     'morph]
    [(or (memq canon '(build-techlab build-reactor build-lurker-den build-shield-battery))
         (memv ab-id '(319 320 321 322 323 324 326 327 328 329 331 333
                       3682 3683 421 422 454 455 487 488
                       881 882 883 884 885 886 887 889 890 891 892 893 894 895 1909
                       1154 1155 1156 1157 1158 1159 1160 1161 1162 1163 1165 1166 1167 1768))
         (string-prefix? s "build-")
         (memq ab-sym KNOWN-BUILDING-ORDER-SYMS))
     'build]
    [(string-prefix? s "train-")
     'train]
    [(string-prefix? s "morph-")
     'morph]
    [(string-prefix? s "research-")
     'research]
    [else 'cast-spell]))

(define (engine-order-target-symbol ab-id ab-sym)
  (define canon (sc2-canonical-order-ability ab-id))
  (define s (if ab-sym (symbol->string ab-sym) ""))
  (cond
    [(= ab-id 318)  'command-center]
    [(= ab-id 319)  'supply-depot]
    [(= ab-id 320)  'refinery]
    [(= ab-id 321)  'barracks]
    [(= ab-id 322)  'engineering-bay]
    [(= ab-id 323)  'missile-turret]
    [(= ab-id 324)  'bunker]
    [(= ab-id 326)  'sensor-tower]
    [(= ab-id 327)  'ghost-academy]
    [(= ab-id 328)  'factory]
    [(= ab-id 329)  'starport]
    [(= ab-id 331)  'armory]
    [(= ab-id 333)  'fusion-core]
    [(= ab-id 3682) 'tech-lab]
    [(= ab-id 3683) 'reactor]
    [(= ab-id 421)  'barracks-techlab]
    [(= ab-id 422)  'barracks-reactor]
    [(= ab-id 454)  'factory-techlab]
    [(= ab-id 455)  'factory-reactor]
    [(= ab-id 487)  'starport-techlab]
    [(= ab-id 488)  'starport-reactor]
    [(= ab-id 880)  'nexus]
    [(= ab-id 881)  'pylon]
    [(= ab-id 882)  'assimilator]
    [(= ab-id 883)  'gateway]
    [(= ab-id 884)  'forge]
    [(= ab-id 885)  'fleet-beacon]
    [(= ab-id 886)  'twilight-council]
    [(= ab-id 887)  'photon-cannon]
    [(= ab-id 889)  'stargate]
    [(= ab-id 890)  'templar-archive]
    [(= ab-id 891)  'dark-shrine]
    [(= ab-id 892)  'robotics-bay]
    [(= ab-id 893)  'robotics-facility]
    [(= ab-id 894)  'cybernetics-core]
    [(eq? canon 'build-shield-battery) 'shield-battery]
    [(= ab-id 1152) 'hatchery]
    [(= ab-id 1154) 'extractor]
    [(= ab-id 1155) 'spawning-pool]
    [(= ab-id 1156) 'evolution-chamber]
    [(= ab-id 1157) 'hydralisk-den]
    [(= ab-id 1158) 'spire]
    [(= ab-id 1159) 'ultralisk-cavern]
    [(= ab-id 1160) 'infestation-pit]
    [(= ab-id 1161) 'nydus-network]
    [(= ab-id 1162) 'baneling-nest]
    [(eq? canon 'build-lurker-den) 'lurker-den]
    [(= ab-id 1165) 'roach-warren]
    [(= ab-id 1166) 'spine-crawler]
    [(= ab-id 1167) 'spore-crawler]
    [(= ab-id 1768) 'nydus-worm]
    [(= ab-id 1344) 'overlord]
    [(= ab-id 524)  'scv]
    [(= ab-id 1006) 'probe]
    [(= ab-id 1342) 'drone]
    [(= ab-id 1216) 'lair]
    [(= ab-id 1218) 'hive]
    [(= ab-id 1220) 'greater-spire]
    [(= ab-id 1516) 'orbital-command]
    [(= ab-id 1450) 'planetary-fortress]
    [(= ab-id 1518) 'warp-gate]
    [(= ab-id 251)  'inject-larva]
    [(= ab-id 1694) 'spawn-creep-tumor]
    [(= ab-id 1733) 'spread-creep-tumor]
    [(string-prefix? s "build-")
     (sc2-canonical-structure-sym (string->symbol (substring s 6)))]
    [(string-prefix? s "train-")
     (string->symbol (substring s 6))]
    [(string-prefix? s "morph-")
     (define raw (string->symbol (substring s 6)))
     (if (set-member? SC2-ALL-STRUCTURE-SYMS raw)
         (sc2-canonical-structure-sym raw)
         raw)]
    [(string-prefix? s "research-")
     (string->symbol (substring s 9))]
    [ab-sym
     (if (set-member? SC2-ALL-STRUCTURE-SYMS ab-sym)
         (sc2-canonical-structure-sym ab-sym)
         ab-sym)]
    [(symbol? canon) canon]
    [else 'unknown]))

;; Per-ledger step-issued count table so Reactor facilities (2 slots) are only
;; marked busy after BOTH slots are filled (`order-cnt + step-issued >= max-slots`).
(define LEDGER-STEP-ISSUED-COUNTS (make-weak-hasheq))
(define (ledger-get-step-counts-table ledger)
  (hash-ref! LEDGER-STEP-ISSUED-COUNTS ledger make-hasheqv))

(define (normalize-in-progress-order-entry entry race-hint)
  (define default-th
    (case race-hint
      [(Zerg zerg) 'hatchery]
      [(Protoss protoss) 'nexus]
      [else 'command-center]))
  (cond
    [(symbol? entry)
     (if (eq? entry 'expand)
         default-th
         (engine-order-target-symbol 0 entry))]
    [(hash? entry)
     (define raw-sym
       (or (hash-ref entry 'type #f)
           (hash-ref entry 'target #f)
           (hash-ref entry 'building #f)
           (hash-ref entry 'ability-sym #f)))
     (define raw-id (hash-ref entry 'ability-id 0))
     (define resolved (engine-order-target-symbol (if (exact-integer? raw-id) raw-id 0) raw-sym))
     (if (eq? resolved 'expand) default-th resolved)]
    [(pair? entry)
     (match entry
       [(list 'expand (? symbol? th-sym) _ ...) (sc2-canonical-structure-sym th-sym)]
       [(list 'expand _ ...) default-th]
       [(list (or 'build 'morph 'train 'research) (? symbol? sym) _ ...)
        (engine-order-target-symbol 0 sym)]
       [(cons (? symbol? sym) _)
        (engine-order-target-symbol 0 sym)]
       [_ 'unknown])]
    [else 'unknown]))

(define (order-ledger-reconcile-observation! ledger obs)
  (define frame (hash-ref obs 'frame 0))
  (define u-orders (in-progress-order-ledger-unit-orders ledger))
  (define t-counts (in-progress-order-ledger-type-order-counts ledger))
  (hash-clear! t-counts)
  (set-clear! (in-progress-order-ledger-step-issued-units ledger))
  (hash-clear! (ledger-get-step-counts-table ledger))

  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define all-allies (append ally-units ally-bldgs))
  (define alive-ids (mutable-seteqv))

  (define (bldg-matches-order? b tsym uid o-tgt-id o-tx o-ty [ux #f] [uy #f])
    (and (hash? b)
         (sc2-structure-matches-target? (hash-ref b 'type #f) tsym)
         (let ([bid (hash-ref b 'id 0)]
               [bx (hash-ref b 'x #f)]
               [by (hash-ref b 'y #f)]
               [in-tr? (hash-ref b 'in-transit? #f)]
               [inc? (< (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)])
           (or (and (> uid 0)
                    (or (= bid (+ 9000000 uid))
                        (and (>= bid 9000000) (= (modulo (- bid 9000000) 100000) uid))))
               (and (> o-tgt-id 0) (= bid o-tgt-id))
               (and (or in-tr? inc?)
                    (cond
                      [(and (real? o-tx) (real? o-ty) (real? bx) (real? by))
                       (<= (dist2d o-tx o-ty bx by) 4.0)]
                      [(and (real? ux) (real? uy) (real? bx) (real? by))
                       (<= (dist2d ux uy bx by) 4.0)]
                      [(not (and (real? bx) (real? by)))
                       #t]
                      [(and (>= uid 800000) (not (and (real? o-tx) (real? o-ty))))
                       in-tr?]
                      [else #f]))))))

  ;; 1. Ingest live SC2 engine orders from all allied units and structures (including multi-order Reactors)
  (for ([u (in-list all-allies)] #:when (hash? u))
    (define uid (hash-ref u 'id 0))
    (set-add! alive-ids uid)
    (define utype (hash-ref u 'type #f))
    (define ux (hash-ref u 'x #f))
    (define uy (hash-ref u 'y #f))
    (define eng-orders (hash-ref u 'orders '()))
    (define ab-id (hash-ref u 'order-ability-id 0))
    (define ab-sym (or (hash-ref u 'order-ability-sym #f)
                       (and (hash-ref u 'has-build-order? #f)
                            (hash-ref u 'build-target #f))))
    (define tgt-id (hash-ref u 'order-target-id (hash-ref u 'engaged-target-tag 0)))
    (define tgt-x (hash-ref u 'order-target-x #f))
    (define tgt-y (hash-ref u 'order-target-y #f))
    (define prog (hash-ref u 'order-progress 0.0))
    (cond
      [(or (pair? eng-orders) (> ab-id 0) ab-sym)
       (define order-specs
         (if (pair? eng-orders)
             (for/list ([o (in-list eng-orders)]
                        [idx (in-naturals)])
               (if (hash? o)
                   (list (hash-ref o 'ability-id (if (= idx 0) ab-id 0))
                         (hash-ref o 'ability-sym (if (= idx 0) ab-sym #f))
                         (hash-ref o 'target-id (if (= idx 0) tgt-id 0))
                         (hash-ref o 'target-x (if (= idx 0) tgt-x #f))
                         (hash-ref o 'target-y (if (= idx 0) tgt-y #f))
                         (hash-ref o 'progress (if (= idx 0) prog 0.0)))
                   (list ab-id ab-sym tgt-id tgt-x tgt-y prog)))
             (list (list ab-id ab-sym tgt-id tgt-x tgt-y prog))))
       (for ([spec (in-list order-specs)]
             [idx (in-naturals)])
         (match-define (list o-ab-id o-ab-sym o-tgt-id o-tx o-ty o-prog) spec)
         (define kind (classify-engine-order-kind o-ab-id o-ab-sym))
         (define tsym (engine-order-target-symbol o-ab-id o-ab-sym))
         (when (= idx 0)
           (define prev (hash-ref u-orders uid #f))
           (define issued-f
             (if (and prev (eq? (tracked-order-ability-sym prev) tsym))
                 (tracked-order-issued-frame prev)
                 frame))
           (hash-set! u-orders uid
                      (tracked-order uid kind tsym o-tgt-id o-tx o-ty
                                     issued-f frame o-prog 'engine)))
         (define already-in-ally-bldgs?
           (and (memq kind '(build expand))
                (ormap (lambda (b)
                         (bldg-matches-order? b tsym uid o-tgt-id o-tx o-ty ux uy))
                       ally-bldgs)))
         (define cocoon-self-morph?
           (and (eq? kind 'morph)
                (memq utype '(baneling-cocoon ravager-cocoon lurker-egg lurker-mp-egg
                              brood-lord-cocoon overlord-cocoon))))
         (unless (or already-in-ally-bldgs? cocoon-self-morph?)
           (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0)))))]
      [else
       ;; Unit has no engine order; keep recently issued order only within short latency window
       (define prev (hash-ref u-orders uid #f))
       (when prev
         (define age (- frame (tracked-order-issued-frame prev)))
         (define ttl
           (if (memq (tracked-order-kind prev) '(build expand))
               SC2-ORDER-LEDGER-TTL-FRAMES
               8))
         (if (<= age ttl)
             (hash-set! t-counts
                        (tracked-order-ability-sym prev)
                        (add1 (hash-ref t-counts (tracked-order-ability-sym prev) 0)))
             (hash-remove! u-orders uid)))]))

  ;; 1b. Ingest explicit en-route worker build orders from `(hash-ref obs 'in-progress-orders '())`
  (define obs-in-prog (hash-ref obs 'in-progress-orders '()))
  (when (list? obs-in-prog)
    (define race-hint (hash-ref obs 'race 'Terran))
    (for ([entry (in-list obs-in-prog)])
      (define tsym (normalize-in-progress-order-entry entry race-hint))
      (when (and (symbol? tsym) (not (eq? tsym 'unknown)))
        (define e-uid (if (hash? entry) (hash-ref entry 'unit-id 0) 0))
        (define e-tid (if (hash? entry) (hash-ref entry 'target-id 0) 0))
        (define e-tx (if (hash? entry) (hash-ref entry 'target-x #f) #f))
        (define e-ty (if (hash? entry) (hash-ref entry 'target-y #f) #f))
        (define already-recorded-by-unit?
          (and (> e-uid 0)
               (let ([uo (hash-ref u-orders e-uid #f)])
                 (and uo
                      (eq? (tracked-order-source uo) 'engine)
                      (sc2-structure-matches-target? (tracked-order-ability-sym uo) tsym)))))
        (define already-under-construction?
          (if (or (> e-uid 0) (> e-tid 0) (and (real? e-tx) (real? e-ty)))
              (ormap (lambda (b)
                       (bldg-matches-order? b tsym e-uid e-tid e-tx e-ty))
                     ally-bldgs)
              (ormap (lambda (b)
                       (and (hash? b)
                            (sc2-structure-matches-target? (hash-ref b 'type #f) tsym)
                            (or (hash-ref b 'in-transit? #f)
                                (< (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))))
                     ally-bldgs)))
        (unless (or already-recorded-by-unit? already-under-construction?)
          (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0)))))))

  ;; 2. Prune dead units, materialized build/expand pseudo-orders, or expired pseudo-unit orders
  (define pseudo-build-ttl (min 16 SC2-ORDER-LEDGER-TTL-FRAMES))
  (for ([(uid tord) (in-hash (hash-copy u-orders))])
    (when (not (set-member? alive-ids uid))
      (define tkind (tracked-order-kind tord))
      (define tsym (tracked-order-ability-sym tord))
      (define age (- frame (tracked-order-issued-frame tord)))
      (define pseudo-uid? (>= uid 800000))
      (define max-ttl (if pseudo-uid? pseudo-build-ttl 12))
      (define bldg-materialized?
        (and (memq tkind '(build expand))
             (ormap (lambda (b)
                      (bldg-matches-order? b tsym uid
                                           (tracked-order-target-id tord)
                                           (tracked-order-target-x tord)
                                           (tracked-order-target-y tord)))
                    ally-bldgs)))
      (define morph-already-counted?
        (and (eq? tkind 'morph)
             (or (> (hash-ref t-counts tsym 0) 0)
                 (ormap (lambda (a)
                          (and (hash? a)
                               (let ([at (hash-ref a 'type #f)])
                                 (or (sc2-structure-matches-target? at tsym)
                                     (memq at (sc2-unit-equivalent-syms tsym))))))
                        all-allies))))
      (cond
        [(or bldg-materialized? morph-already-counted? (< age 0) (> age max-ttl))
         (hash-remove! u-orders uid)]
        [(and (memq tkind '(build expand))
              (<= age (if pseudo-uid? pseudo-build-ttl 8))
              (or pseudo-uid? (<= (hash-ref t-counts tsym 0) 0)))
         (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0)))]
        [(and (eq? tkind 'morph)
              (<= age 8)
              (<= (hash-ref t-counts tsym 0) 0))
         (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0)))])))

  ;; 3. Prune build-site reservations that have materialized as buildings or expired
  (define active-sites
    (filter
     (lambda (site)
       (define bsym (reserved-build-site-bldg-sym site))
       (define sx (reserved-build-site-x site))
       (define sy (reserved-build-site-y site))
       (define materialized?
         (ormap (lambda (b)
                  (and (hash? b)
                       (sc2-structure-matches-target? (hash-ref b 'type #f) bsym)
                       (<= (dist2d sx sy (hash-ref b 'x 0.0) (hash-ref b 'y 0.0))
                           SC2-BUILD-SITE-MIN-CLEARANCE)))
                ally-bldgs))
       (and (not materialized?)
            (<= frame (reserved-build-site-expires-frame site))))
     (in-progress-order-ledger-reserved-sites ledger)))
  (set-in-progress-order-ledger-reserved-sites! ledger active-sites)
  ledger)

(define (order-ledger-record-issued! ledger arg1 arg2 [arg3 #f] [arg4 #f] [arg5 #f] [arg6 0]
                                     #:target-id [kw-target-id #f]
                                     #:target-x [kw-target-x #f]
                                     #:target-y [kw-target-y #f]
                                     #:frame [kw-frame #f])
  ;; Supports:
  ;;  1. `(order-ledger-record-issued! ledger frame act)` where `act` is an action S-expr
  ;;  2. `(order-ledger-record-issued! ledger uid kind ability-sym tx ty frame)`
  ;;  3. `(order-ledger-record-issued! ledger uid kind ability-sym #:target-id ...)`
  (define (unit-id-list v)
    (cond
      [(exact-integer? v) (list v)]
      [(and (list? v) (andmap exact-integer? v)) v]
      [else '()]))
  (cond
    [(and (exact-integer? arg1) (pair? arg2) (not arg3))
     (define frame (or kw-frame arg1))
     (define act arg2)
     (match act
       [(list (and (or 'attack 'attack-unit) k) uids (? exact-integer? tid))
        (for ([uid (in-list (unit-id-list uids))])
          (order-ledger-record-issued! ledger uid k k #:target-id tid #:frame frame))
        ledger]
       [(list (and (or 'kite 'move 'retreat 'attack-pos) k) uids (? real? tx) (? real? ty))
        (for ([uid (in-list (unit-id-list uids))])
          (order-ledger-record-issued! ledger uid k k #:target-x tx #:target-y ty #:frame frame))
        ledger]
       [(list 'hold-position uids)
        (for ([uid (in-list (unit-id-list uids))])
          (order-ledger-record-issued! ledger uid 'hold-position 'hold-position #:frame frame))
        ledger]
       [(list 'train-unit uids (? symbol? usym))
        (for ([uid (in-list (unit-id-list uids))])
          (order-ledger-record-issued! ledger uid 'train usym #:frame frame))
        ledger]
       [(list 'morph uids (? symbol? msym))
        (for ([uid (in-list (unit-id-list uids))])
          (order-ledger-record-issued! ledger uid 'morph msym #:frame frame))
        ledger]
       [(list (or 'cast 'cast-spell) uids (? symbol? sp) rest ...)
        (define point-targeted?
          (and (>= (length rest) 2) (real? (first rest)) (real? (second rest))))
        (define tid
          (if (and (not point-targeted?) (= (length rest) 1) (exact-integer? (first rest)))
              (first rest)
              0))
        (define tx (if point-targeted? (first rest) #f))
        (define ty (if point-targeted? (second rest) #f))
        (for ([uid (in-list (unit-id-list uids))])
          (order-ledger-record-issued! ledger uid 'cast-spell sp
                                       #:target-id tid #:target-x tx #:target-y ty #:frame frame))
        ledger]
       [_ ledger])]
    [else
     (define uid arg1)
     (define kind arg2)
     (define ability-sym
       (if (and (symbol? arg3)
                (memq kind '(build expand morph))
                (set-member? SC2-ALL-STRUCTURE-SYMS arg3))
           (sc2-canonical-structure-sym arg3)
           arg3))
     (define target-id (or kw-target-id 0))
     (define target-x (or kw-target-x (and (real? arg4) arg4)))
     (define target-y (or kw-target-y (and (real? arg5) arg5)))
     (define frame (or kw-frame (if (exact-integer? arg6) arg6 0)))
     (define u-orders (in-progress-order-ledger-unit-orders ledger))
     (define t-counts (in-progress-order-ledger-type-order-counts ledger))
     (when (and (exact-integer? uid) (> uid 0))
       (define prev (hash-ref u-orders uid #f))
       (define prev-step-cnt (hash-ref (ledger-get-step-counts-table ledger) uid 0))
       (define reactor-second-train-slot?
         (and prev
              (eq? (tracked-order-kind prev) 'train)
              (eq? kind 'train)
              (= prev-step-cnt 1)))
       (when (and prev (not reactor-second-train-slot?))
         (define prev-sym (tracked-order-ability-sym prev))
         (when prev-sym
           (define next-cnt (sub1 (hash-ref t-counts prev-sym 0)))
           (if (<= next-cnt 0)
               (hash-remove! t-counts prev-sym)
               (hash-set! t-counts prev-sym next-cnt))))
       (set-add! (in-progress-order-ledger-step-issued-units ledger) uid)
       (hash-update! (ledger-get-step-counts-table ledger) uid add1 0)
       (hash-set! u-orders uid
                  (tracked-order uid kind ability-sym target-id target-x target-y
                                 frame frame 0.0 'issued)))
     (when ability-sym
       (hash-set! t-counts ability-sym (add1 (hash-ref t-counts ability-sym 0))))
     ledger]))

(define (order-ledger-unit-active-order ledger uid)
  (hash-ref (in-progress-order-ledger-unit-orders ledger) uid #f))

(define (order-ledger-unit-has-active-build? ledger uid [u-hash #f])
  (or (and (hash? u-hash)
           (or (eq? (hash-ref u-hash 'has-build-order? #f) #t)
               (memq (hash-ref u-hash 'order-kind #f) '(build expand))))
      (let ([tord (order-ledger-unit-active-order ledger uid)])
        (and tord (memq (tracked-order-kind tord) '(build expand)) #t))))

(define (order-ledger-pending-count-for-type ledger target-sym [_frame 0])
  (define t-counts (in-progress-order-ledger-type-order-counts ledger))
  (if (and (symbol? target-sym) (set-member? SC2-ALL-STRUCTURE-SYMS target-sym))
      (let ([canon (sc2-canonical-structure-sym target-sym)])
        (if (eq? canon target-sym)
            (hash-ref t-counts canon 0)
            (+ (hash-ref t-counts canon 0) (hash-ref t-counts target-sym 0))))
      (hash-ref t-counts target-sym 0)))

(define (order-ledger-facility-busy? ledger bldg-hash [_frame 0])
  (define bid (hash-ref bldg-hash 'id 0))
  (define prog (hash-ref bldg-hash 'build-progress 1.0))
  (cond
    [(or (< prog SC2-BUILD-COMPLETE-PROGRESS)
         (hash-ref bldg-hash 'in-transit? #f)
         (hash-ref bldg-hash 'flying? #f)
         (and (sc2-structure-requires-pylon-power? (hash-ref bldg-hash 'type 'unknown))
              (eq? (hash-ref bldg-hash 'powered? #t) #f)))
     #t]
    [else
     (define order-cnt
       (max (hash-ref bldg-hash 'order-count 0)
            (length (hash-ref bldg-hash 'orders '()))))
     (define addon-val (hash-ref bldg-hash 'addon #f))
     (define addon-type (hash-ref bldg-hash 'addon-type #f))
     (define addon-ready? (not (eq? (hash-ref bldg-hash 'addon-ready? #t) #f)))
     (define has-reactor?
       (and addon-ready?
            (not (eq? addon-val 'addon-building))
            (or (eq? addon-val 'reactor)
                (memq addon-type '(barracks-reactor factory-reactor starport-reactor)))))
     (define max-slots (if has-reactor? 2 1))
     (define step-counts (ledger-get-step-counts-table ledger))
     (define step-cnt
       (max (hash-ref step-counts bid 0)
            (if (set-member? (in-progress-order-ledger-step-issued-units ledger) bid) 1 0)))
     (>= (+ order-cnt step-cnt) max-slots)]))

;; Returns #t if combat unit `u` is currently in its weapon attack-point / backswing lock
;; or within its minimum commitment window so a new order should NOT cancel its shot!
(define (order-ledger-unit-in-attack-swing? ledger u [frame 0])
  (define uid (hash-ref u 'id 0))
  (define utype (hash-ref u 'type 'marine))
  (define stats (sc2-unit-combat-stats utype))
  (define w-period (hash-ref stats 'weapon-period 1.0))
  (define w-cd (hash-ref u 'weapon-cooldown 0.0))
  (define engaged-id (hash-ref u 'engaged-target-tag 0))
  (define ab-id (hash-ref u 'order-ability-id 0))
  (define tord (order-ledger-unit-active-order ledger uid))
  (or ;; 1. Already given a higher-priority command on this exact step
      (set-member? (in-progress-order-ledger-step-issued-units ledger) uid)
      ;; 2. Actively attacking an engaged target and winding up attack point (cd <= 0.08)
      (and (> engaged-id 0)
           (= ab-id 23)
           (<= w-cd SC2-WEAPON-READY-COOLDOWN-THRESH)
           (> (hash-ref stats 'damage-point 0.10) 0.08))
      ;; 3. Just fired within the last 2 frames (prevent post-damage-point state flicker)
      (and (> w-period 0.3)
           (> w-cd (- w-period 0.08)))
      ;; 4. Recently committed to a tactical order within SC2-TACTICAL-MIN-LOCK-FRAMES
      (and tord
           (> frame (tracked-order-issued-frame tord))
           (memq (tracked-order-kind tord) '(attack-unit kite retreat CloakHarassWorkers))
           (< (- frame (tracked-order-issued-frame tord)) SC2-TACTICAL-MIN-LOCK-FRAMES))))

;; Checks whether issuing `(kind target-id tx ty)` to `uid` is redundant with `uid`'s
;; currently active order in the SC2 engine or ledger.
(define (order-ledger-order-equivalent? ledger u kind target-id tx ty [frame 0])
  (define uid (if (hash? u) (hash-ref u 'id 0) u))
  (cond
    [(set-member? (in-progress-order-ledger-step-issued-units ledger) uid) #t]
    [else
     (define tord (order-ledger-unit-active-order ledger uid))
     (define u-ab-id (if (hash? u) (hash-ref u 'order-ability-id 0) 0))
     (define u-canon (sc2-canonical-order-ability u-ab-id))
     (define u-tgt-id (if (hash? u) (hash-ref u 'order-target-id (hash-ref u 'engaged-target-tag 0)) 0))
     (define u-tx (if (hash? u) (hash-ref u 'order-target-x #f) #f))
     (define u-ty (if (hash? u) (hash-ref u 'order-target-y #f) #f))
     (or
      ;; Check live engine order on unit hash via canonical SC2 ability mapping
      (and (memq kind '(attack attack-unit))
           (eq? u-canon 'attack)
           (> target-id 0)
           (= u-tgt-id target-id))
      (and (memq kind '(move kite retreat mineral-walk))
           (eq? u-canon 'move)
           (real? tx) (real? ty) (real? u-tx) (real? u-ty)
           (<= (dist2d tx ty u-tx u-ty) SC2-ORDER-EQUIV-DIST-TOLERANCE))
      (and (eq? kind 'attack-pos)
           (eq? u-canon 'attack)
           (real? tx) (real? ty) (real? u-tx) (real? u-ty)
           (<= (dist2d tx ty u-tx u-ty) SC2-ORDER-EQUIV-DIST-TOLERANCE))
      (and (eq? kind 'patrol)
           (eq? u-canon 'patrol)
           (real? tx) (real? ty) (real? u-tx) (real? u-ty)
           (<= (dist2d tx ty u-tx u-ty) SC2-ORDER-EQUIV-DIST-TOLERANCE))
      (and (eq? kind 'hold-position)
           (eq? u-canon 'hold-position))
      (and (eq? kind 'stop)
           (eq? u-canon 'stop))
      (and (memq kind '(harvest harvest-gather harvest-return))
           (memq u-canon '(harvest-gather harvest-return))
           (or (<= target-id 0) (= u-tgt-id target-id) (eq? u-canon 'harvest-return)))
      (and (eq? kind 'repair)
           (eq? u-canon 'repair)
           (or (<= target-id 0) (= u-tgt-id target-id)))
      (and (memq kind '(lift lift-building))
           (eq? u-canon 'lift))
      (and (memq kind '(land land-building))
           (eq? u-canon 'land)
           (or (not (and (real? tx) (real? ty) (real? u-tx) (real? u-ty)))
               (<= (dist2d tx ty u-tx u-ty) 1.0)))
      (and (eq? kind 'burrow-down)
           (eq? u-canon 'burrow-down))
      (and (eq? kind 'burrow-up)
           (eq? u-canon 'burrow-up))
      ;; Check ledger tracked order
      (and tord
           (<= (- frame (tracked-order-last-seen-frame tord)) 12)
           (or (and (memq kind '(attack attack-unit))
                    (memq (tracked-order-kind tord) '(attack attack-unit))
                    (> target-id 0)
                    (= (tracked-order-target-id tord) target-id))
               (and (memq kind '(harvest harvest-gather harvest-return))
                    (memq (tracked-order-kind tord) '(harvest harvest-gather harvest-return))
                    (or (<= target-id 0) (= (tracked-order-target-id tord) target-id)))
               (and (eq? kind 'repair)
                    (eq? (tracked-order-kind tord) 'repair)
                    (or (<= target-id 0) (= (tracked-order-target-id tord) target-id)))
               (and (memq kind '(lift lift-building))
                    (memq (tracked-order-kind tord) '(lift lift-building)))
               (and (memq kind '(land land-building))
                    (memq (tracked-order-kind tord) '(land land-building))
                    (real? tx) (real? ty)
                    (real? (tracked-order-target-x tord))
                    (real? (tracked-order-target-y tord))
                    (<= (dist2d tx ty
                                (tracked-order-target-x tord)
                                (tracked-order-target-y tord))
                        1.0))
               (and (memq kind '(move kite retreat attack-pos patrol))
                    (eq? (tracked-order-kind tord) kind)
                    (real? tx) (real? ty)
                    (real? (tracked-order-target-x tord))
                    (real? (tracked-order-target-y tord))
                    (<= (dist2d tx ty
                                (tracked-order-target-x tord)
                                (tracked-order-target-y tord))
                        SC2-ORDER-EQUIV-DIST-TOLERANCE)))))]))

(define (order-ledger-reserve-build-site! ledger bldg-sym x y [builder-id 0] [frame 0])
  (define canon-sym
    (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define site
    (reserved-build-site canon-sym
                         (exact->inexact x)
                         (exact->inexact y)
                         builder-id
                         frame
                         (+ frame SC2-BUILD-SITE-RESERVATION-TTL)))
  (set-in-progress-order-ledger-reserved-sites!
   ledger
   (cons site (in-progress-order-ledger-reserved-sites ledger)))
  site)

;; Ensures a proposed build coordinate `(x, y)` does not collide with any active
;; `reserved-build-site`, `reserved-aabb`, expansion pad, or existing `ally-buildings`
;; (using exact Chebyshev `sc2-structure-half-dims` + `aabb-overlaps?` and reserving
;; `(bx + 2.5, by - 0.5)` East add-on pads for `barracks`/`factory`/`starport`),
;; spiraling outward if needed and reserving the chosen site.
(define (order-ledger-resolve-build-coords! ledger bldg-sym raw-x raw-y
                                            [ally-bldgs '()]
                                            [pos-frame 0]
                                            [pos-clearance SC2-BUILD-SITE-MIN-CLEARANCE]
                                            #:builder-id [builder-id 0]
                                            #:frame [kw-frame #f]
                                            #:clearance [kw-clearance #f]
                                            #:expansion-pads [expansion-pads '()]
                                            #:exact-wall-slot? [exact-wall-slot? #f]
                                            #:reserved-aabbs [reserved-aabbs '()])
  (define frame (or kw-frame pos-frame))
  (define _unused-clearance (or kw-clearance pos-clearance))
  (define sites (in-progress-order-ledger-reserved-sites ledger))
  (define canon-bldg
    (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define-values (cand-hw cand-hh)
    (if (symbol? canon-bldg) (sc2-structure-half-dims canon-bldg) (values 1.5 1.5)))
  (define is-townhall?
    (or (memq bldg-sym SC2-TOWNHALL-STRUCTURE-SYMS)
        (memq canon-bldg SC2-TOWNHALL-STRUCTURE-SYMS)))
  (define is-3x3-addon-fac? (memq canon-bldg '(barracks factory starport)))
  (define odd-footprint? (sc2-odd-footprint-structure? canon-bldg))
  (define snap-fn (if odd-footprint? snap-3x3-coord snap-2x2-coord))

  ;; Build exact Chebyshev AABB lists for physical footprints vs reserved Terran add-on pads
  (define physical-aabbs '())
  (define addon-pad-aabbs '())
  (define (push-phys! box) (set! physical-aabbs (cons box physical-aabbs)))
  (define (push-addon! box) (set! addon-pad-aabbs (cons box addon-pad-aabbs)))

  (for ([r (in-list (if (list? reserved-aabbs) reserved-aabbs '()))]
        #:when (and (reserved-aabb? r)
                    (or (<= (reserved-aabb-expires-frame r) 0)
                        (> (reserved-aabb-expires-frame r) frame))))
    (if (eq? (reserved-aabb-kind r) 'addon-pad)
        (push-addon! r)
        (push-phys! r)))

  (for ([s (in-list sites)])
    (define sx (reserved-build-site-x s))
    (define sy (reserved-build-site-y s))
    (define raw-st (reserved-build-site-bldg-sym s))
    (define stype (if (symbol? raw-st) (sc2-canonical-structure-sym raw-st) raw-st))
    (define-values (shw shh)
      (if (symbol? stype) (sc2-structure-half-dims stype) (values 1.5 1.5)))
    (define exp-f (reserved-build-site-expires-frame s))
    (when (<= frame exp-f)
      (push-phys! (reserved-aabb sx sy shw shh 'reserved-site (reserved-build-site-builder-id s) exp-f))
      (when (memq stype '(barracks factory starport))
        (push-addon! (reserved-aabb (+ sx SC2-TERRAN-ADDON-OFFSET-X)
                                    (+ sy SC2-TERRAN-ADDON-OFFSET-Y)
                                    1.0 1.0 'addon-pad (reserved-build-site-builder-id s) exp-f)))))

  (for ([b (in-list (if (list? ally-bldgs) ally-bldgs '()))]
        #:when (hash? b))
    (define raw-bt (hash-ref b 'type #f))
    (define flying?
      (or (memq raw-bt '(barracks-flying factory-flying starport-flying
                         command-center-flying orbital-command-flying
                         spine-crawler-uprooted spore-crawler-uprooted))
          (eq? (hash-ref b 'flying? #f) #t)
          (eq? (hash-ref b 'is-flying #f) #t)))
    (unless flying?
      (define bx (exact->inexact (hash-ref b 'x 0.0)))
      (define by (exact->inexact (hash-ref b 'y 0.0)))
      (define btype (if (symbol? raw-bt) (sc2-canonical-structure-sym raw-bt) raw-bt))
      (define-values (bhw bhh)
        (if (symbol? btype) (sc2-structure-half-dims btype) (values 1.5 1.5)))
      (define bid (hash-ref b 'id 0))
      (push-phys! (reserved-aabb bx by bhw bhh 'ally-bldg bid 0))
      (when (memq btype '(barracks factory starport))
        (push-addon! (reserved-aabb (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                    (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                    1.0 1.0 'addon-pad bid 0)))))

  (define (overlaps-phys? cx cy hw hh)
    (ormap (lambda (b) (aabb-overlaps? cx cy hw hh b)) physical-aabbs))

  (define (overlaps-addon-pad? cx cy hw hh)
    (ormap (lambda (b) (aabb-overlaps? cx cy hw hh b)) addon-pad-aabbs))

  (define (overlaps-expansion-pad? cx cy)
    (and (not is-townhall?)
         (list? expansion-pads)
         (ormap (lambda (p)
                  (define-values (ok? px py)
                    (cond
                      [(and (pair? p) (real? (car p)) (real? (cdr p)))
                       (values #t (exact->inexact (car p)) (exact->inexact (cdr p)))]
                      [(and (pair? p) (real? (car p)) (pair? (cdr p)) (real? (cadr p)))
                       (values #t (exact->inexact (car p)) (exact->inexact (cadr p)))]
                      [(hash? p)
                       (values #t
                               (exact->inexact (hash-ref p 'x -999.0))
                               (exact->inexact (hash-ref p 'y -999.0)))]
                      [(reserved-aabb? p)
                       (values #t (reserved-aabb-cx p) (reserved-aabb-cy p))]
                      [else (values #f 0.0 0.0)]))
                  (and ok?
                       (< (max (abs (- cx px)) (abs (- cy py))) 4.5)))
                expansion-pads)))

  (define (in-playable-bounds? cx cy)
    (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
         (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)))

  (define (spot-free? cx cy)
    (define new-ax (+ cx SC2-TERRAN-ADDON-OFFSET-X))
    (define new-ay (+ cy SC2-TERRAN-ADDON-OFFSET-Y))
    (and (in-playable-bounds? cx cy)
         (not (overlaps-expansion-pad? cx cy))
         (not (overlaps-phys? cx cy cand-hw cand-hh))
         (not (overlaps-addon-pad? cx cy cand-hw cand-hh))
         (or (not is-3x3-addon-fac?)
             exact-wall-slot?
             (and (in-playable-bounds? new-ax new-ay)
                  (not (overlaps-expansion-pad? new-ax new-ay))
                  (not (overlaps-phys? new-ax new-ay 1.0 1.0))
                  (not (overlaps-addon-pad? new-ax new-ay 1.0 1.0))))))

  (cond
    ;; Exact ramp/choke wall slot: preserve `(raw-x, raw-y)` unchanged if physically non-overlapping!
    [(and exact-wall-slot?
          (in-playable-bounds? raw-x raw-y)
          (not (overlaps-expansion-pad? (exact->inexact raw-x) (exact->inexact raw-y)))
          (not (overlaps-phys? (exact->inexact raw-x) (exact->inexact raw-y) cand-hw cand-hh)))
     (order-ledger-reserve-build-site! ledger canon-bldg raw-x raw-y builder-id frame)
     (values raw-x raw-y)]
    [else
     (define x0 (snap-fn raw-x))
     (define y0 (snap-fn raw-y))
     (define-values (chosen-x chosen-y)
       (if (spot-free? x0 y0)
           (values x0 y0)
           (let search ([r 3.0])
             (if (> r 18.0)
                 (values x0 y0)
                 (let ([found
                        (for*/first ([dx (in-list (list 0.0 r (- r)))]
                                     [dy (in-list (list 0.0 r (- r)))]
                                     #:when (and (or (not (zero? dx)) (not (zero? dy)))
                                                 (spot-free? (snap-fn (+ x0 dx))
                                                             (snap-fn (+ y0 dy)))))
                          (cons (snap-fn (+ x0 dx)) (snap-fn (+ y0 dy))))])
                   (if found
                       (values (car found) (cdr found))
                       (search (+ r 3.0))))))))
     (order-ledger-reserve-build-site! ledger canon-bldg chosen-x chosen-y builder-id frame)
     (values chosen-x chosen-y)]))
