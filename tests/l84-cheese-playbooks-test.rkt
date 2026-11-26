#lang racket/base

;; =============================================================================
;; Loop 84 Unit Test Suite (`tests/l84-cheese-playbooks-test.rkt`)
;;
;; Verifies Mothman Version C ("C is for Cheese") playbooks & lookup/selection
;; API in `lib/build-orders/cheese.rkt`:
;;   1. Exact 18 profile IDs, zero duplicates, `lookup-cheese-build-spec`
;;   2. All 9/9 SC2 matchups via `list-cheese-profiles-for-matchup` (1-arg & 2-arg)
;;   3. `build-order-spec` validity, monotonic `< 6:00` steps, supply-curve
;;      timing-cut enforcement via `pro-supply-curve-target-for-spec`
;;   4. Worker caps, max bases, proxy metadata invariants, hit triggers,
;;      worker-pull counts, and `fallback-macro-sec` release windows
;;   5. `select-cheese-build-spec` explicit overrides, deterministic integer &
;;      string seeding, and `'Random` / `'Unknown` / malformed input fallbacks
;;   6. Read-only isolation from standard macro `lib/build-orders.rkt`
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         racket/string
         "../lib/sc2-types.rkt"
         "../lib/build-orders.rkt"
         "../lib/build-orders/cheese.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check-test name pred [detail ""])
  (if pred
      (begin
        (set! pass-count (add1 pass-count))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "  [FAIL] ~a~a\n"
                name
                (if (string=? detail "") "" (format " (~a)" detail))))))

(define EXPECTED-MATCHUP-PROFILES
  (list
   (list 'ZvZ 'Zerg    'Zerg    'zvz-13-12-ling-bane            'zvz-12pool-proxy-spine)
   (list 'ZvP 'Zerg    'Protoss 'zvp-19d-speedling-roach-ravager 'zvp-12pool-ling-flood)
   (list 'ZvT 'Zerg    'Terran  'zvt-26d-roach-ravager-bust     'zvt-42d-queen-ling-nydus)
   (list 'TvP 'Terran  'Protoss 'tvp-proxy-2rax-marauder        'tvp-1base-2gas-cyclone)
   (list 'TvT 'Terran  'Terran  'tvt-proxy-2rax-reaper          'tvt-1base-111-tank-bunker)
   (list 'TvZ 'Terran  'Zerg    'tvz-proxy-2rax-bunker          'tvz-reaper-fe-hellion-banshee)
   (list 'PvZ 'Protoss 'Zerg    'pvz-32p-8gate-chargelot-prism  'pvz-cannon-rush)
   (list 'PvT 'Protoss 'Terran  'pvt-proxy-4gate-zealot-stalker 'pvt-proxy-stargate-voidray)
   (list 'PvP 'Protoss 'Protoss 'pvp-proxy-robo-immortal        'pvp-cannon-rush)))

(define EXPECTED-18-IDS
  (for*/list ([row (in-list EXPECTED-MATCHUP-PROFILES)]
              [pid (in-list (list (fourth row) (fifth row)))])
    pid))

(define VALID-PROXY-KINDS
  '(none off-path-mid close-cannon proxy-spine nydus-main))

(define VALID-TIMING-CUT-ARCHETYPES
  '(two-base-timing one-base-all-in roach-ravager-timing bio-timing-allin))

(define VALID-GOAL-KINDS
  '(build expand morph train research))

;; =============================================================================
;; Group 1: Exact 18 Profile IDs & `lookup-cheese-build-spec`
;; =============================================================================
(printf "\n=== Group 1: Registry & Exact 18 Profile IDs ===\n")

(let ()
  (define actual-ids (map cheese-build-spec-id all-cheese-build-specs))
  (check-test "all-cheese-build-specs-count-is-18"
              (= (length all-cheese-build-specs) 18)
              (format "got=~a" (length all-cheese-build-specs)))
  (check-test "all-cheese-build-specs-all-structs"
              (andmap cheese-build-spec? all-cheese-build-specs))
  (check-test "all-cheese-build-specs-zero-duplicates"
              (= (set-count (list->set actual-ids)) 18)
              (format "unique=~a" (set-count (list->set actual-ids))))
  (check-test "all-cheese-build-specs-exact-18-ids"
              (equal? (list->set actual-ids) (list->set EXPECTED-18-IDS))
              (format "diff=~a" (set-symmetric-difference (list->set actual-ids)
                                                          (list->set EXPECTED-18-IDS))))
  (check-test "lookup-cheese-build-spec-all-18-symbol-and-string-forms"
              (for/and ([pid (in-list EXPECTED-18-IDS)])
                (define s1 (lookup-cheese-build-spec pid))
                (define s2 (lookup-cheese-build-spec (symbol->string pid)))
                (define s3 (lookup-cheese-build-spec (string-upcase (symbol->string pid))))
                (define s4 (lookup-cheese-build-spec (format "  ~a  " pid)))
                (and (cheese-build-spec? s1)
                     (eq? (cheese-build-spec-id s1) pid)
                     (equal? s1 s2)
                     (equal? s1 s3)
                     (equal? s1 s4))))
  (check-test "lookup-cheese-build-spec-rejects-auto-and-unknowns"
              (and (eq? (lookup-cheese-build-spec 'auto) #f)
                   (eq? (lookup-cheese-build-spec "auto") #f)
                   (eq? (lookup-cheese-build-spec "AUTO") #f)
                   (eq? (lookup-cheese-build-spec "") #f)
                   (eq? (lookup-cheese-build-spec #f) #f)
                   (eq? (lookup-cheese-build-spec 'nonexistent-cheese) #f)
                   (eq? (lookup-cheese-build-spec "unknown-profile") #f)
                   (eq? (lookup-cheese-build-spec 12345) #f))))

;; =============================================================================
;; Group 2: All 9/9 Matchups via `list-cheese-profiles-for-matchup`
;; =============================================================================
(printf "\n=== Group 2: 9/9 Matchups Coverage & Ordering ===\n")

(let ()
  (define (race->short-str r)
    (case r [(Zerg) "Z"] [(Terran) "T"] [(Protoss) "P"]))

  (for ([row (in-list EXPECTED-MATCHUP-PROFILES)])
    (define m-sym     (first row))
    (define my-race   (second row))
    (define opp-race  (third row))
    (define pri-id    (fourth row))
    (define sec-id    (fifth row))
    (define expected-pair (list pri-id sec-id))

    (define p-1arg-sym   (list-cheese-profiles-for-matchup m-sym))
    (define p-1arg-lo    (list-cheese-profiles-for-matchup (string->symbol (string-downcase (symbol->string m-sym)))))
    (define p-1arg-str   (list-cheese-profiles-for-matchup (symbol->string m-sym)))
    (define p-1arg-ustr  (list-cheese-profiles-for-matchup (format " ~a " (string-upcase (symbol->string m-sym)))))
    (define p-2arg-sym   (list-cheese-profiles-for-matchup my-race opp-race))
    (define p-2arg-str   (list-cheese-profiles-for-matchup (string-downcase (symbol->string my-race))
                                                           (string-downcase (symbol->string opp-race))))
    (define p-2arg-short (list-cheese-profiles-for-matchup (race->short-str my-race)
                                                           (race->short-str opp-race)))

    (check-test (format "matchup-~a-exact-primary-secondary-all-call-forms" m-sym)
                (and (= (length p-1arg-sym) 2)
                     (equal? (map cheese-build-spec-id p-1arg-sym) expected-pair)
                     (equal? p-1arg-sym p-1arg-lo)
                     (equal? p-1arg-sym p-1arg-str)
                     (equal? p-1arg-sym p-1arg-ustr)
                     (equal? p-1arg-sym p-2arg-sym)
                     (equal? p-1arg-sym p-2arg-str)
                     (equal? p-1arg-sym p-2arg-short))
                (format "got=~a" (map cheese-build-spec-id p-1arg-sym)))

    (check-test (format "matchup-~a-race-and-bo-spec-consistency" m-sym)
                (for/and ([spec (in-list p-1arg-sym)])
                  (define bo (cheese-build-spec-bo-spec spec))
                  (and (eq? (cheese-build-spec-matchup spec) m-sym)
                       (eq? (cheese-build-spec-race spec) my-race)
                       (build-order-spec? bo)
                       (eq? (build-order-spec-matchup bo) m-sym)
                       (eq? (build-order-spec-race bo) my-race))))))

;; =============================================================================
;; Group 3: `build-order-spec`, Steps & Supply Curve Validation (All 18)
;; =============================================================================
(printf "\n=== Group 3: build-order-spec Steps & Supply Curves ===\n")

(for ([spec (in-list all-cheese-build-specs)])
  (define pid (cheese-build-spec-id spec))
  (define bo (cheese-build-spec-bo-spec spec))
  (define steps (build-order-spec-steps bo))
  (define curve (build-order-spec-supply-curve bo))
  (define u-timings (build-order-spec-unit-timings bo))
  (define upg-timings (build-order-spec-upgrade-timings bo))
  (define wcap (cheese-build-spec-worker-cap spec))

  (define steps-valid?
    (and (pair? steps)
         (for/and ([g (in-list steps)])
           (and (pro-bo-goal? g)
                (memq (pro-bo-goal-kind g) VALID-GOAL-KINDS)
                (symbol? (pro-bo-goal-target-sym g))
                (exact-positive-integer? (pro-bo-goal-target-count g))
                (exact-nonnegative-integer? (pro-bo-goal-min-supply g))
                (or (not (pro-bo-goal-prereq-ready-sym g))
                    (symbol? (pro-bo-goal-prereq-ready-sym g)))
                (finite-real? (pro-bo-goal-target-sec g))
                (> (pro-bo-goal-target-sec g) 0.0)
                (<= (pro-bo-goal-target-sec g) 360.0)))))

  (define secs (map pro-bo-goal-target-sec steps))
  (define steps-monotonic?
    (for/and ([a (in-list secs)] [b (in-list (cdr secs))])
      (<= a b)))

  (define curve-valid?
    (and (= (length curve) 7)
         (equal? (map car curve) '(1 2 3 4 5 6 7))
         (for/and ([pt (in-list curve)])
           (define w (car (cdr pt)))
           (define a (cdr (cdr pt)))
           (and (finite-real? w) (>= w 12.0) (<= w 70.0)
                (finite-real? a) (>= a 0.0)))))

  (define timings-valid?
    (and (for/and ([ut (in-list u-timings)])
           (and (pro-unit-timing? ut)
                (symbol? (pro-unit-timing-unit-sym ut))
                (exact-positive-integer? (pro-unit-timing-target-count ut))
                (finite-real? (pro-unit-timing-target-sec ut))
                (> (pro-unit-timing-target-sec ut) 0.0)))
         (for/and ([up (in-list upg-timings)])
           (and (pro-upgrade-timing? up)
                (symbol? (pro-upgrade-timing-upgrade-sym up))
                (finite-real? (pro-upgrade-timing-start-sec up))
                (finite-real? (pro-upgrade-timing-complete-sec up))
                (> (pro-upgrade-timing-start-sec up) 0.0)
                (< (pro-upgrade-timing-start-sec up)
                   (pro-upgrade-timing-complete-sec up))))))

  ;; Verify `pro-supply-curve-target-for-spec` at 3:00 (4032 frames) with 2 bases
  ;; respects the timing-cut archetype and does NOT inflate workers to 44!
  (define-values (tw-3m ta-3m) (pro-supply-curve-target-for-spec bo 4032 2))
  (define timing-cut-respected?
    (and (memq (build-order-spec-archetype bo) VALID-TIMING-CUT-ARCHETYPES)
         (exact-integer? tw-3m)
         (exact-integer? ta-3m)
         (<= tw-3m (max 16 wcap))
         (< tw-3m 44)))

  (check-test (format "bo-spec-valid-~a" pid)
              (and (non-empty-string? (build-order-spec-name bo))
                   (non-empty-string? (build-order-spec-description bo))
                   steps-valid?
                   steps-monotonic?
                   curve-valid?
                   timings-valid?
                   timing-cut-respected?)
              (format "steps=~a mono=~a curve=~a timings=~a cut=~a (tw3m=~a wcap=~a)"
                      steps-valid? steps-monotonic? curve-valid? timings-valid?
                      timing-cut-respected? tw-3m wcap)))

;; =============================================================================
;; Group 4: Worker Caps, Proxy Metadata, Hit Triggers & Fallback Windows
;; =============================================================================
(printf "\n=== Group 4: Cheese Metadata, Proxy Contracts & Hit Triggers ===\n")

(for ([spec (in-list all-cheese-build-specs)])
  (define pid       (cheese-build-spec-id spec))
  (define wcap      (cheese-build-spec-worker-cap spec))
  (define mbases    (cheese-build-spec-max-bases spec))
  (define pkind     (cheese-build-spec-proxy-kind spec))
  (define psec      (cheese-build-spec-proxy-dispatch-sec spec))
  (define pworkers  (cheese-build-spec-proxy-worker-count spec))
  (define pbldgs    (cheese-build-spec-proxy-buildings spec))
  (define htrig     (cheese-build-spec-hit-trigger spec))
  (define pull-w    (cheese-build-spec-pull-workers-at-hit spec))
  (define fb-sec    (cheese-build-spec-fallback-macro-sec spec))
  (define acomp     (cheese-build-spec-army-comp spec))
  (define kupgs     (cheese-build-spec-key-upgrades spec))

  (define proxy-consistent?
    (cond
      [(eq? pkind 'none)
       (and (= pworkers 0)
            (= psec 0.0)
            (null? pbldgs))]
      [(eq? pkind 'nydus-main)
       (and (= pworkers 0)
            (> psec 0.0)
            (equal? pbldgs '(nydus-worm)))]
      [(memq pkind '(off-path-mid close-cannon proxy-spine))
       (and (exact-positive-integer? pworkers)
            (<= pworkers 2)
            (> psec 0.0)
            (< psec 180.0)
            (pair? pbldgs)
            (andmap symbol? pbldgs))]
      [else #f]))

  (define htrig-valid?
    (and (hash? htrig)
         (hash-has-key? htrig 'min-combat-supply)
         (hash-has-key? htrig 'min-sec)
         (hash-has-key? htrig 'key-unit-req)
         (hash-has-key? htrig 'key-upgrade-req)
         (let ([mcs (hash-ref htrig 'min-combat-supply)]
               [ms  (hash-ref htrig 'min-sec)]
               [ku  (hash-ref htrig 'key-unit-req)]
               [kug (hash-ref htrig 'key-upgrade-req)])
           (and (exact-nonnegative-integer? mcs)
                (finite-real? ms)
                (> ms 0.0)
                (< ms 360.0)
                (or (not ku) (symbol? ku))
                (or (not kug) (symbol? kug))
                (> fb-sec ms)))))

  (check-test (format "metadata-valid-~a" pid)
              (and (exact-positive-integer? wcap) (>= wcap 14) (<= wcap 45)
                   (memv mbases '(1 2 3))
                   (memq pkind VALID-PROXY-KINDS)
                   proxy-consistent?
                   htrig-valid?
                   (exact-nonnegative-integer? pull-w) (<= pull-w wcap)
                   (finite-real? fb-sec) (>= fb-sec 360.0) (<= fb-sec 420.0)
                   (pair? acomp) (andmap symbol? acomp)
                   (list? kupgs) (andmap symbol? kupgs))
              (format "wcap=~a mbases=~a pkind=~a pcons=~a htrig=~a pull=~a fb=~a"
                      wcap mbases pkind proxy-consistent? htrig-valid? pull-w fb-sec)))

;; Spot-check key pro playbook contracts explicitly
(let ()
  (define zvz1 (lookup-cheese-build-spec 'zvz-13-12-ling-bane))
  (define zvz2 (lookup-cheese-build-spec 'zvz-12pool-proxy-spine))
  (define zvp1 (lookup-cheese-build-spec 'zvp-19d-speedling-roach-ravager))
  (define zvt1 (lookup-cheese-build-spec 'zvt-26d-roach-ravager-bust))
  (define zvt2 (lookup-cheese-build-spec 'zvt-42d-queen-ling-nydus))
  (define tvp1 (lookup-cheese-build-spec 'tvp-proxy-2rax-marauder))
  (define tvt1 (lookup-cheese-build-spec 'tvt-proxy-2rax-reaper))
  (define tvz1 (lookup-cheese-build-spec 'tvz-proxy-2rax-bunker))
  (define pvz1 (lookup-cheese-build-spec 'pvz-32p-8gate-chargelot-prism))
  (define pvz2 (lookup-cheese-build-spec 'pvz-cannon-rush))
  (define pvt1 (lookup-cheese-build-spec 'pvt-proxy-4gate-zealot-stalker))
  (define pvt2 (lookup-cheese-build-spec 'pvt-proxy-stargate-voidray))
  (define pvp1 (lookup-cheese-build-spec 'pvp-proxy-robo-immortal))
  (define pvp2 (lookup-cheese-build-spec 'pvp-cannon-rush))

  (check-test "spot-pro-worker-cutoffs"
              (and (= (cheese-build-spec-worker-cap zvz1) 15)
                   (= (cheese-build-spec-worker-cap zvp1) 19)
                   (= (cheese-build-spec-worker-cap zvt1) 26)
                   (= (cheese-build-spec-worker-cap zvt2) 42)
                   (= (cheese-build-spec-worker-cap pvz1) 32)
                   (= (cheese-build-spec-worker-cap pvz2) 17)
                   (= (cheese-build-spec-worker-cap pvp2) 17)))

  (check-test "spot-proxy-archetypes-and-buildings"
              (and (eq? (cheese-build-spec-proxy-kind zvz2) 'proxy-spine)
                   (memq 'spine-crawler (cheese-build-spec-proxy-buildings zvz2))
                   (eq? (cheese-build-spec-proxy-kind zvt2) 'nydus-main)
                   (equal? (cheese-build-spec-proxy-buildings zvt2) '(nydus-worm))
                   (eq? (cheese-build-spec-proxy-kind tvp1) 'off-path-mid)
                   (equal? (cheese-build-spec-proxy-buildings tvp1)
                           '(barracks barracks barracks-tech-lab barracks-tech-lab))
                   (eq? (cheese-build-spec-proxy-kind tvt1) 'off-path-mid)
                   (eq? (cheese-build-spec-proxy-kind tvz1) 'off-path-mid)
                   (memq 'bunker (cheese-build-spec-proxy-buildings tvz1))
                   (eq? (cheese-build-spec-proxy-kind pvz2) 'close-cannon)
                   (memq 'photon-cannon (cheese-build-spec-proxy-buildings pvz2))
                   (eq? (cheese-build-spec-proxy-kind pvp2) 'close-cannon)
                   (= (cheese-build-spec-proxy-worker-count pvz2) 2)
                   (= (cheese-build-spec-proxy-worker-count pvp2) 2)
                   (eq? (cheese-build-spec-proxy-kind pvt1) 'off-path-mid)
                   (eq? (cheese-build-spec-proxy-kind pvt2) 'off-path-mid)
                   (memq 'stargate (cheese-build-spec-proxy-buildings pvt2))
                   (eq? (cheese-build-spec-proxy-kind pvp1) 'off-path-mid)
                   (memq 'robotics-facility (cheese-build-spec-proxy-buildings pvp1))))

  (check-test "spot-worker-pull-cheeses"
              (and (> (cheese-build-spec-pull-workers-at-hit zvz2) 0)
                   (> (cheese-build-spec-pull-workers-at-hit tvp1) 0)
                   (> (cheese-build-spec-pull-workers-at-hit tvz1) 0)
                   (= (cheese-build-spec-pull-workers-at-hit pvz1) 0)))

  ;; Loop 84C: `zvt-42d-queen-ling-nydus` commits cleanly at 22 combat supply
  ;; when the 5:30 Nydus pops instead of stalling until `fallback@405s`.
  (check-test "l84c-zvt-nydus-hit-trigger-min-combat-supply-is-22"
              (= (hash-ref (cheese-build-spec-hit-trigger zvt2) 'min-combat-supply) 22)
              (format "got=~a" (hash-ref (cheese-build-spec-hit-trigger zvt2) 'min-combat-supply)))

  ;; Loop 84B: High-value tech/key units MUST precede mineral-dump filler
  ;; (`zealot`, `zergling`, `marine`) in `army-comp` so Stage 7 production
  ;; never starves Warp Prism, Immortal, Void Ray, Siege Tank, Banshee,
  ;; Ravager/Roach, Baneling, Cyclone, or 42d Nydus Queens.
  (let ()
    (define (precedes? lst a b)
      (define ia (index-of lst a eq?))
      (define ib (index-of lst b eq?))
      (and ia ib (< ia ib)))
    (define tvp2 (lookup-cheese-build-spec 'tvp-1base-2gas-cyclone))
    (define tvt2 (lookup-cheese-build-spec 'tvt-1base-111-tank-bunker))
    (define tvz2 (lookup-cheese-build-spec 'tvz-reaper-fe-hellion-banshee))

    (check-test "l84b-army-comp-tech-units-precede-mineral-dump-filler"
                (and
                 ;; Protoss tech-first ordering
                 (eq? (car (cheese-build-spec-army-comp pvz1)) 'warp-prism)
                 (precedes? (cheese-build-spec-army-comp pvz1) 'warp-prism 'zealot)
                 (eq? (car (cheese-build-spec-army-comp pvp1)) 'immortal)
                 (precedes? (cheese-build-spec-army-comp pvp1) 'immortal 'zealot)
                 (precedes? (cheese-build-spec-army-comp pvp1) 'warp-prism 'zealot)
                 (eq? (car (cheese-build-spec-army-comp pvt2)) 'void-ray)
                 (precedes? (cheese-build-spec-army-comp pvt2) 'void-ray 'zealot)
                 (precedes? (cheese-build-spec-army-comp pvt2) 'oracle 'zealot)
                 ;; Terran tech-first ordering
                 (precedes? (cheese-build-spec-army-comp tvp1) 'marauder 'marine)
                 (precedes? (cheese-build-spec-army-comp tvp2) 'cyclone 'marine)
                 (precedes? (cheese-build-spec-army-comp tvp2) 'viking-fighter 'marine)
                 (precedes? (cheese-build-spec-army-comp tvp2) 'widow-mine 'marine)
                 (precedes? (cheese-build-spec-army-comp tvp2) 'marauder 'marine)
                 (precedes? (cheese-build-spec-army-comp tvt1) 'reaper 'marine)
                 (precedes? (cheese-build-spec-army-comp tvt1) 'hellion 'marine)
                 (precedes? (cheese-build-spec-army-comp tvt2) 'siege-tank 'marine)
                 (precedes? (cheese-build-spec-army-comp tvt2) 'viking-fighter 'marine)
                 (precedes? (cheese-build-spec-army-comp tvt2) 'medivac 'marine)
                 (eq? (car (cheese-build-spec-army-comp tvz2)) 'banshee)
                 (precedes? (cheese-build-spec-army-comp tvz2) 'banshee 'marine)
                 (precedes? (cheese-build-spec-army-comp tvz2) 'hellion 'marine)
                 ;; Zerg tech-first ordering
                 (precedes? (cheese-build-spec-army-comp zvz1) 'baneling 'zergling)
                 (precedes? (cheese-build-spec-army-comp zvp1) 'ravager 'zergling)
                 (precedes? (cheese-build-spec-army-comp zvp1) 'roach 'zergling)
                 (precedes? (cheese-build-spec-army-comp zvt1) 'ravager 'zergling)
                 (precedes? (cheese-build-spec-army-comp zvt1) 'roach 'zergling)
                 (precedes? (cheese-build-spec-army-comp zvt2) 'queen 'zergling)))

    (define MINERAL-DUMP-FILLER '(zealot zergling marine))
    (define HIGH-VALUE-TECH-UNITS
      '(warp-prism immortal void-ray oracle siege-tank viking-fighter medivac
        banshee hellion cyclone widow-mine reaper ravager roach baneling))
    (check-test "l84b-all-18-no-mineral-filler-before-high-value-tech"
                (for/and ([spec (in-list all-cheese-build-specs)])
                  (define comp (cheese-build-spec-army-comp spec))
                  (define first-filler-idx
                    (for/first ([u (in-list comp)]
                                [i (in-naturals)]
                                #:when (memq u MINERAL-DUMP-FILLER))
                      i))
                  (if (not first-filler-idx)
                      #t
                      (for/and ([u (in-list comp)]
                                [i (in-naturals)]
                                #:when (memq u HIGH-VALUE-TECH-UNITS))
                        (< i first-filler-idx))))
                (format "comps=~a"
                        (map (lambda (s) (cons (cheese-build-spec-id s)
                                               (cheese-build-spec-army-comp s)))
                             all-cheese-build-specs)))))

;; =============================================================================
;; Group 5: `select-cheese-build-spec` Determinism, Overrides & Safe Fallbacks
;; =============================================================================
(printf "\n=== Group 5: Selection, Seeding & Random/Unknown Fallbacks ===\n")

(let ()
  ;; Default 2-arg call returns primary for all 9 matchups
  (check-test "select-default-returns-primary-for-all-9-matchups"
              (for/and ([row (in-list EXPECTED-MATCHUP-PROFILES)])
                (define s (select-cheese-build-spec (second row) (third row)))
                (eq? (cheese-build-spec-id s) (fourth row))))

  ;; Deterministic integer seed rotation across all 9 matchups
  (check-test "select-integer-seed-rotation-all-9-matchups"
              (for/and ([row (in-list EXPECTED-MATCHUP-PROFILES)])
                (define r (second row))
                (define e (third row))
                (define pri (fourth row))
                (define sec (fifth row))
                (and (eq? (cheese-build-spec-id (select-cheese-build-spec r e 'auto 0)) pri)
                     (eq? (cheese-build-spec-id (select-cheese-build-spec r e 'auto 1)) sec)
                     (eq? (cheese-build-spec-id (select-cheese-build-spec r e 'auto 2)) pri)
                     (eq? (cheese-build-spec-id (select-cheese-build-spec r e 'auto 3)) sec)
                     (eq? (cheese-build-spec-id (select-cheese-build-spec r e 'auto -1)) sec)
                     (eq? (cheese-build-spec-id (select-cheese-build-spec r e 'auto 1.9)) sec))))

  ;; Non-finite float seeds (`+nan.0`, `+inf.0`, `-inf.0`) never crash
  (check-test "select-nonfinite-seeds-safe"
              (and (cheese-build-spec? (select-cheese-build-spec 'Terran 'Protoss 'auto +nan.0))
                   (cheese-build-spec? (select-cheese-build-spec 'Terran 'Protoss 'auto +inf.0))
                   (cheese-build-spec? (select-cheese-build-spec 'Terran 'Protoss 'auto -inf.0))
                   (cheese-build-spec? (select-cheese-build-spec 'Terran 'Protoss 'auto #f))))

  ;; String opponent-ID seeds are 100% deterministic AND hit both profiles across opponents
  (let* ([opp-names '("MicroMachine" "SicToss" "who" "CutterSlayer" "oberon"
                      "VeTerran-revived" "ModBotNewBuilds" "AxeFighter"
                      "Clicadinha" "PolyMorph")]
         [picks-1 (map (lambda (o) (cheese-build-spec-id (select-cheese-build-spec 'Terran 'Protoss 'auto o)))
                       opp-names)]
         [picks-2 (map (lambda (o) (cheese-build-spec-id (select-cheese-build-spec 'Terran 'Protoss 'auto o)))
                       opp-names)])
    (check-test "select-string-seed-deterministic"
                (equal? picks-1 picks-2))
    (check-test "select-string-seed-covers-both-primary-and-secondary"
                (and (memq 'tvp-proxy-2rax-marauder picks-1)
                     (memq 'tvp-1base-2gas-cyclone picks-1))
                (format "picks=~a" picks-1)))

  ;; Explicit profile override (symbol, string, cross-matchup, and unknown fallback)
  (check-test "select-explicit-profile-override-and-unknown-fallback"
              (and (eq? (cheese-build-spec-id
                         (select-cheese-build-spec 'Terran 'Protoss 'tvp-1base-2gas-cyclone 0))
                        'tvp-1base-2gas-cyclone)
                   (eq? (cheese-build-spec-id
                         (select-cheese-build-spec 'Terran 'Protoss "tvp-1base-2gas-cyclone" 0))
                        'tvp-1base-2gas-cyclone)
                   (eq? (cheese-build-spec-id
                         (select-cheese-build-spec 'Protoss 'Zerg 'pvz-cannon-rush 0))
                        'pvz-cannon-rush)
                   ;; Cross-matchup explicit override (e.g. CLI --cheese-profile testing)
                   (eq? (cheese-build-spec-id
                         (select-cheese-build-spec 'Zerg 'Terran 'zvz-13-12-ling-bane 0))
                        'zvz-13-12-ling-bane)
                   ;; Unknown explicit profile ID safely falls back to matchup auto
                   (eq? (cheese-build-spec-id
                         (select-cheese-build-spec 'Protoss 'Terran 'not-a-real-profile 0))
                        'pvt-proxy-4gate-zealot-stalker)
                   (eq? (cheese-build-spec-id
                         (select-cheese-build-spec 'Protoss 'Terran "not-a-real-profile" 1))
                        'pvt-proxy-stargate-voidray)))

  ;; Safe fallback for 'Random, 'Unknown, #f, single-letter, and malformed race inputs
  (let ([z-rand  (select-cheese-build-spec 'Zerg    'Random)]
        [t-rand  (select-cheese-build-spec 'Terran  'Random)]
        [p-rand  (select-cheese-build-spec 'Protoss 'Random)]
        [z-unk   (select-cheese-build-spec 'Zerg    'Unknown)]
        [t-false (select-cheese-build-spec 'Terran  #f)]
        [p-rstr  (select-cheese-build-spec "P"      "R")]
        [r-r     (select-cheese-build-spec 'Random  'Random)]
        [x-x     (select-cheese-build-spec "X"      "")]
        [f-f     (select-cheese-build-spec #f       #f)])
    (check-test "select-random-enemy-preserves-own-race"
                (and (cheese-build-spec? z-rand) (eq? (cheese-build-spec-race z-rand) 'Zerg)
                     (cheese-build-spec? t-rand) (eq? (cheese-build-spec-race t-rand) 'Terran)
                     (cheese-build-spec? p-rand) (eq? (cheese-build-spec-race p-rand) 'Protoss)
                     (cheese-build-spec? z-unk)  (eq? (cheese-build-spec-race z-unk)  'Zerg)
                     (cheese-build-spec? t-false)(eq? (cheese-build-spec-race t-false)'Terran)
                     (cheese-build-spec? p-rstr) (eq? (cheese-build-spec-race p-rstr) 'Protoss))
                (format "races=(~a ~a ~a ~a ~a ~a)"
                        (cheese-build-spec-race z-rand)
                        (cheese-build-spec-race t-rand)
                        (cheese-build-spec-race p-rand)
                        (cheese-build-spec-race z-unk)
                        (cheese-build-spec-race t-false)
                        (cheese-build-spec-race p-rstr)))
    (check-test "select-unknown-own-race-never-crashes"
                (and (cheese-build-spec? r-r)
                     (cheese-build-spec? x-x)
                     (cheese-build-spec? f-f)))))

;; =============================================================================
;; Group 6: Isolation from Standard Macro `lib/build-orders.rkt`
;; =============================================================================
(printf "\n=== Group 6: Read-Only Isolation from Standard Macro Build Orders ===\n")

(let ()
  (check-test "standard-macro-build-orders-untouched-and-distinct-from-cheese"
              (for/and ([row (in-list EXPECTED-MATCHUP-PROFILES)])
                (define r (second row))
                (define e (third row))
                (define macro-bo (lookup-build-order-for-matchup r e))
                (define cheese-spec (select-cheese-build-spec r e 'auto 0))
                (and (build-order-spec? macro-bo)
                     (not (equal? (build-order-spec-name macro-bo)
                                  (build-order-spec-name (cheese-build-spec-bo-spec cheese-spec))))))))

(printf "\n=== Results: ~a/~a passed (~a failed) ===\n"
        pass-count (+ pass-count fail-count) fail-count)
(unless (= fail-count 0)
  (exit 1))
