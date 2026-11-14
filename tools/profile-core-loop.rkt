#lang racket/base

;; =============================================================================
;; Mothman SC2 Core Loop Latency Profiler (`tools/profile-core-loop.rkt`)
;;
;; Benchmarks `step-live-bot-runtime!` across synthetic 1v1 frames:
;;   - Races : Zerg, Terran, Protoss, Random
;;   - Tiers : early (frame 1344), mid (frame 5376),
;;             heavy-200v200 (frame 12000: 80 ally, 80 enemy, 40 buildings,
;;                            full 176x176 pathing/placement/height map-grids)
;;
;; CLI:
;;   racket tools/profile-core-loop.rkt [--summary] [--verify] [--iters N]
;;                                      [--warmup N] [--budget-us US]
;;                                      [--race RACE] [--tier TIER]
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/math
         "../lib/bot-runtime.rkt")

(provide make-synthetic-map-grids
         make-scenario-obs
         compute-timing-stats
         profile-scenario
         profile-all-scenarios)

(define DEFAULT-BUDGET-US 4000.0)
(define DEFAULT-WARMUP-ITERS 5)
(define DEFAULT-MEASURED-ITERS 25)

(define PROFILE-RACES '(Zerg Terran Protoss Random))
(define PROFILE-TIERS '(early mid heavy-200v200))

;; -----------------------------------------------------------------------------
;; Synthetic 176x176 Terrain Grids (`pathing-ref`, `placement-ref`, `height-ref`)
;; -----------------------------------------------------------------------------

(define (make-synthetic-map-grids [w 176] [h 176])
  (define total (* w h))
  (define path-b (make-bytes total 0))
  (define place-b (make-bytes total 0))
  (define height-b (make-bytes total 10))
  (for* ([y (in-range h)]
         [x (in-range w)])
    (define idx (+ (* y w) x))
    (define in-bounds? (and (>= x 8) (< x (- w 8)) (>= y 8) (< y (- h 8))))
    (define ally-main? (and (>= x 18) (<= x 44) (>= y 18) (<= y 44)))
    (define enemy-main? (and (>= x (- w 45)) (<= x (- w 19))
                             (>= y (- h 45)) (<= y (- h 19))))
    (define ally-ramp? (and (>= x 44) (<= x 47) (>= y 30) (<= y 37)))
    (define enemy-ramp? (and (>= x (- w 48)) (<= x (- w 45))
                             (>= y (- h 38)) (<= y (- h 31))))
    (define ally-cliff?
      (and (not ally-ramp?)
           (or (and (>= x 45) (<= x 46) (>= y 18) (<= y 46))
               (and (>= y 45) (<= y 46) (>= x 18) (<= x 46)))))
    (define enemy-cliff?
      (and (not enemy-ramp?)
           (or (and (>= x (- w 47)) (<= x (- w 46))
                    (>= y (- h 47)) (<= y (- h 19)))
               (and (>= y (- h 47)) (<= y (- h 46))
                    (>= x (- w 47)) (<= x (- w 19))))))
    (define center-rock?
      (and (>= x 86) (<= x 89) (>= y 86) (<= y 89)))
    (define pathable?
      (and in-bounds? (not ally-cliff?) (not enemy-cliff?) (not center-rock?)))
    (define placeable?
      (and pathable? (not ally-ramp?) (not enemy-ramp?)))
    (define z
      (cond
        [(or ally-main? enemy-main?) 12]
        [(or ally-ramp? enemy-ramp?) 11]
        [else 10]))
    (bytes-set! path-b idx (if pathable? 1 0))
    (bytes-set! place-b idx (if placeable? 1 0))
    (bytes-set! height-b idx z))
  (define (clamp-idx ix iy)
    (define x (if (exact-integer? ix) ix (inexact->exact (floor ix))))
    (define y (if (exact-integer? iy) iy (inexact->exact (floor iy))))
    (and (>= x 0) (< x w) (>= y 0) (< y h) (+ (* y w) x)))
  (hash 'width w
        'height h
        'pathing-ref (lambda (ix iy)
                       (define idx (clamp-idx ix iy))
                       (if idx (bytes-ref path-b idx) 0))
        'placement-ref (lambda (ix iy)
                         (define idx (clamp-idx ix iy))
                         (if idx (bytes-ref place-b idx) 0))
        'height-ref (lambda (ix iy)
                      (define idx (clamp-idx ix iy))
                      (if idx (bytes-ref height-b idx) 0))))

;; -----------------------------------------------------------------------------
;; Synthetic Unit / Building Generators
;; -----------------------------------------------------------------------------

(define (make-unit id utype x y
                   #:hp [hp 80]
                   #:max-hp [max-hp hp]
                   #:shield [shield 0]
                   #:max-shield [max-shield shield]
                   #:energy [energy 0]
                   #:max-energy [max-energy (if (> energy 0) 200 0)]
                   #:z [z 10]
                   #:flying? [flying? #f]
                   #:burrowed? [burrowed? #f]
                   #:cloaked? [cloaked? #f]
                   #:cooldown [cooldown 0.0])
  (hash 'id id
        'type utype
        'x x
        'y y
        'z z
        'hp hp
        'max-hp max-hp
        'shield shield
        'max-shield max-shield
        'energy energy
        'max-energy max-energy
        'weapon-cooldown cooldown
        'is-flying flying?
        'burrowed burrowed?
        'cloaked cloaked?
        'build-progress 1.0
        'orders '()))

(define (make-bldg id btype x y
                   #:hp [hp 850]
                   #:max-hp [max-hp hp]
                   #:shield [shield 0]
                   #:max-shield [max-shield shield]
                   #:energy [energy 0]
                   #:max-energy [max-energy (if (> energy 0) 200 0)]
                   #:z [z 12]
                   #:progress [progress 1.0])
  (hash 'id id
        'type btype
        'x x
        'y y
        'z z
        'hp hp
        'max-hp max-hp
        'shield shield
        'max-shield max-shield
        'energy energy
        'max-energy max-energy
        'build-progress progress
        'orders '()))

(define (spawn-worker-line start-id worker-type count base-x base-y z)
  (for/list ([i (in-range count)])
    (define angle (* 0.35 i))
    (make-unit (+ start-id i)
               worker-type
               (+ base-x (* 3.2 (cos angle)))
               (+ base-y (* 3.2 (sin angle)))
               #:hp (if (eq? worker-type 'scv) 45 40)
               #:max-hp (if (eq? worker-type 'scv) 45 40)
               #:shield (if (eq? worker-type 'probe) 20 0)
               #:max-shield (if (eq? worker-type 'probe) 20 0)
               #:z z)))

(define (spawn-spec-units start-id specs cx cy spread z)
  (define-values (rev-units _next-id)
    (for/fold ([acc '()] [uid start-id])
              ([spec (in-list specs)])
      (define utype (first spec))
      (define cnt (second spec))
      (define hp (third spec))
      (define sh (fourth spec))
      (define en (fifth spec))
      (define fly? (sixth spec))
      (define units-for-spec
        (for/list ([k (in-range cnt)])
          (define idx (+ (- uid start-id) k))
          (define dx (- (modulo (* idx 7) spread) (/ spread 2.0)))
          (define dy (- (modulo (* idx 11) spread) (/ spread 2.0)))
          (make-unit (+ uid k)
                     utype
                     (+ cx dx)
                     (+ cy dy)
                     #:hp hp
                     #:max-hp (+ hp 15)
                     #:shield sh
                     #:max-shield (if (> sh 0) (+ sh 20) 0)
                     #:energy en
                     #:z z
                     #:flying? fly?
                     #:burrowed? (and (eq? utype 'lurker) (even? k))
                     #:cloaked? (eq? utype 'ghost))))
      (values (append (reverse units-for-spec) acc) (+ uid cnt))))
  (reverse rev-units))

(define (effective-race-for-profile race tier)
  (if (eq? race 'Random)
      (case tier
        [(early) 'Protoss]
        [(mid) 'Terran]
        [else 'Protoss])
      race))

(define (opponent-race-for-ally ally-eff-race)
  (case ally-eff-race
    [(Zerg) 'Terran]
    [(Terran) 'Protoss]
    [else 'Zerg]))

(define (build-early-roster eff-race)
  (define opp-race (opponent-race-for-ally eff-race))
  (define-values (ally-units ally-bldgs)
    (case eff-race
      [(Zerg)
       (values
        (append
         (spawn-worker-line 101 'drone 16 32.5 32.5 12)
         (list (make-unit 150 'overlord 48.0 42.0 #:hp 200 #:z 10 #:flying? #t)
               (make-unit 151 'zergling 46.5 34.0 #:hp 35 #:z 11)))
        (list (make-bldg 201 'hatchery 32.5 32.5 #:hp 1500 #:z 12)
              (make-bldg 202 'spawning-pool 29.0 29.5 #:hp 1000 #:z 12)
              (make-bldg 203 'extractor 26.0 34.0 #:hp 500 #:z 12)
              (make-bldg 204 'hatchery 52.5 36.5 #:hp 1050 #:max-hp 1500 #:z 10 #:progress 0.7)))]
      [(Terran)
       (values
        (append
         (spawn-worker-line 101 'scv 16 32.5 32.5 12)
         (list (make-unit 150 'reaper 54.0 40.0 #:hp 60 #:z 10)
               (make-unit 151 'marine 44.5 33.5 #:hp 45 #:z 11)))
        (list (make-bldg 201 'command-center 32.5 32.5 #:hp 1500 #:z 12)
              (make-bldg 202 'supply-depot 45.0 31.0 #:hp 400 #:z 12)
              (make-bldg 203 'barracks 45.0 34.0 #:hp 1000 #:z 12)
              (make-bldg 204 'refinery 26.0 34.0 #:hp 500 #:z 12)))]
      [else
       (values
        (append
         (spawn-worker-line 101 'probe 16 32.5 32.5 12)
         (list (make-unit 150 'adept 54.0 39.0 #:hp 70 #:shield 70 #:z 10)
               (make-unit 151 'stalker 44.5 34.0 #:hp 80 #:shield 80 #:z 11)))
        (list (make-bldg 201 'nexus 32.5 32.5 #:hp 1000 #:shield 1000 #:energy 50 #:z 12)
              (make-bldg 202 'pylon 44.0 31.0 #:hp 200 #:shield 200 #:z 12)
              (make-bldg 203 'gateway 45.5 34.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 204 'cybernetics-core 43.0 36.5 #:hp 550 #:shield 550 #:z 12)))]))
  (define-values (enemy-units enemy-bldgs)
    (case opp-race
      [(Terran)
       (values (list (make-unit 501 'reaper 58.0 42.0 #:hp 60 #:z 10)
                     (make-unit 502 'scv 144.5 144.5 #:hp 45 #:z 12))
               (list (make-bldg 601 'command-center 144.5 144.5 #:hp 1500 #:z 12)
                     (make-bldg 602 'barracks 133.0 142.0 #:hp 1000 #:z 12)))]
      [(Protoss)
       (values (list (make-unit 501 'probe 58.0 42.0 #:hp 20 #:shield 20 #:z 10)
                     (make-unit 502 'adept 126.0 136.0 #:hp 70 #:shield 70 #:z 10))
               (list (make-bldg 601 'nexus 144.5 144.5 #:hp 1000 #:shield 1000 #:z 12)
                     (make-bldg 602 'gateway 133.0 142.0 #:hp 500 #:shield 500 #:z 12)))]
      [else
       (values (list (make-unit 501 'overlord 58.0 42.0 #:hp 200 #:z 10 #:flying? #t)
                     (make-unit 502 'zergling 126.0 136.0 #:hp 35 #:z 10))
               (list (make-bldg 601 'hatchery 144.5 144.5 #:hp 1500 #:z 12)
                     (make-bldg 602 'spawning-pool 140.0 140.0 #:hp 1000 #:z 12)))]))
  (values ally-units ally-bldgs enemy-units enemy-bldgs))

(define (build-mid-roster eff-race)
  (define opp-race (opponent-race-for-ally eff-race))
  (define-values (ally-units ally-bldgs)
    (case eff-race
      [(Zerg)
       (values
        (append
         (spawn-worker-line 101 'drone 20 32.5 32.5 12)
         (spawn-worker-line 121 'drone 22 52.5 36.5 10)
         (spawn-spec-units
          150
          '((queen 4 175 0 95 #f)
            (overlord 4 200 0 0 #t)
            (zergling 10 35 0 0 #f)
            (roach 4 145 0 0 #f)
            (ravager 2 120 0 0 #f))
          72.0 64.0 12 10))
        (list (make-bldg 201 'hatchery 32.5 32.5 #:hp 1500 #:z 12)
              (make-bldg 202 'lair 52.5 36.5 #:hp 2000 #:z 10)
              (make-bldg 203 'hatchery 74.5 52.5 #:hp 1500 #:z 10)
              (make-bldg 204 'spawning-pool 29.0 29.5 #:hp 1000 #:z 12)
              (make-bldg 205 'roach-warren 30.0 37.5 #:hp 850 #:z 12)
              (make-bldg 206 'evolution-chamber 36.0 30.0 #:hp 750 #:z 12)
              (make-bldg 207 'extractor 26.0 34.0 #:hp 500 #:z 12)
              (make-bldg 208 'extractor 55.5 31.0 #:hp 500 #:z 10)
              (make-bldg 209 'spine-crawler 57.5 39.5 #:hp 300 #:z 10)
              (make-bldg 210 'spore-crawler 34.5 36.0 #:hp 400 #:z 12)))]
      [(Terran)
       (values
        (append
         (spawn-worker-line 101 'scv 20 32.5 32.5 12)
         (spawn-worker-line 121 'scv 22 52.5 36.5 10)
         (spawn-spec-units
          150
          '((marine 14 45 0 0 #f)
            (marauder 4 125 0 0 #f)
            (siege-tank 3 175 0 0 #f)
            (medivac 2 150 0 85 #t)
            (viking-fighter 1 135 0 0 #t))
          72.0 64.0 12 10))
        (list (make-bldg 201 'orbital-command 32.5 32.5 #:hp 1500 #:energy 75 #:z 12)
              (make-bldg 202 'orbital-command 52.5 36.5 #:hp 1500 #:energy 50 #:z 10)
              (make-bldg 203 'supply-depot 45.0 31.0 #:hp 400 #:z 12)
              (make-bldg 204 'supply-depot 45.0 36.0 #:hp 400 #:z 12)
              (make-bldg 205 'barracks 36.0 29.0 #:hp 1000 #:z 12)
              (make-bldg 206 'barracks 39.0 29.0 #:hp 1000 #:z 12)
              (make-bldg 207 'factory 35.0 37.5 #:hp 1250 #:z 12)
              (make-bldg 208 'starport 39.0 37.5 #:hp 1300 #:z 12)
              (make-bldg 209 'engineering-bay 29.0 36.0 #:hp 850 #:z 12)
              (make-bldg 210 'bunker 56.5 40.0 #:hp 400 #:z 10)))]
      [else
       (values
        (append
         (spawn-worker-line 101 'probe 20 32.5 32.5 12)
         (spawn-worker-line 121 'probe 22 52.5 36.5 10)
         (spawn-spec-units
          150
          '((zealot 8 100 50 0 #f)
            (stalker 8 80 80 0 #f)
            (adept 3 70 70 0 #f)
            (sentry 2 40 40 100 #f)
            (immortal 2 200 100 0 #f)
            (observer 1 40 20 0 #t))
          72.0 64.0 12 10))
        (list (make-bldg 201 'nexus 32.5 32.5 #:hp 1000 #:shield 1000 #:energy 90 #:z 12)
              (make-bldg 202 'nexus 52.5 36.5 #:hp 1000 #:shield 1000 #:energy 60 #:z 10)
              (make-bldg 203 'pylon 44.0 31.0 #:hp 200 #:shield 200 #:z 12)
              (make-bldg 204 'pylon 50.0 41.0 #:hp 200 #:shield 200 #:z 10)
              (make-bldg 205 'gateway 45.5 34.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 206 'gateway 39.0 29.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 207 'cybernetics-core 43.0 36.5 #:hp 550 #:shield 550 #:z 12)
              (make-bldg 208 'forge 29.0 30.0 #:hp 400 #:shield 400 #:z 12)
              (make-bldg 209 'robotics-facility 36.0 38.0 #:hp 450 #:shield 450 #:z 12)
              (make-bldg 210 'shield-battery 55.5 39.5 #:hp 150 #:shield 150 #:energy 100 #:z 10)))]))
  (define-values (enemy-units enemy-bldgs)
    (case opp-race
      [(Terran)
       (values (spawn-spec-units
                501
                '((marine 12 45 0 0 #f)
                  (marauder 4 125 0 0 #f)
                  (siege-tank 2 175 0 0 #f)
                  (medivac 2 150 0 80 #t)
                  (scv 4 45 0 0 #f))
                88.0 82.0 14 10)
               (list (make-bldg 601 'orbital-command 144.5 144.5 #:hp 1500 #:z 12)
                     (make-bldg 602 'orbital-command 124.5 138.5 #:hp 1500 #:z 10)
                     (make-bldg 603 'barracks 131.0 140.0 #:hp 1000 #:z 12)
                     (make-bldg 604 'factory 134.0 140.0 #:hp 1250 #:z 12)
                     (make-bldg 605 'supply-depot 130.0 137.0 #:hp 400 #:z 12)
                     (make-bldg 606 'bunker 120.5 135.0 #:hp 400 #:z 10)))]
      [(Protoss)
       (values (spawn-spec-units
                501
                '((zealot 8 100 50 0 #f)
                  (stalker 8 80 80 0 #f)
                  (sentry 2 40 40 90 #f)
                  (immortal 2 200 100 0 #f)
                  (probe 4 20 20 0 #f))
                88.0 82.0 14 10)
               (list (make-bldg 601 'nexus 144.5 144.5 #:hp 1000 #:shield 1000 #:z 12)
                     (make-bldg 602 'nexus 124.5 138.5 #:hp 1000 #:shield 1000 #:z 10)
                     (make-bldg 603 'gateway 133.0 142.0 #:hp 500 #:shield 500 #:z 12)
                     (make-bldg 604 'cybernetics-core 136.0 142.0 #:hp 550 #:shield 550 #:z 12)
                     (make-bldg 605 'pylon 131.0 139.0 #:hp 200 #:shield 200 #:z 12)
                     (make-bldg 606 'shield-battery 121.0 135.0 #:hp 150 #:shield 150 #:z 10)))]
      [else
       (values (spawn-spec-units
                501
                '((zergling 12 35 0 0 #f)
                  (roach 6 145 0 0 #f)
                  (ravager 2 120 0 0 #f)
                  (drone 4 40 0 0 #f))
                88.0 82.0 14 10)
               (list (make-bldg 601 'hatchery 144.5 144.5 #:hp 1500 #:z 12)
                     (make-bldg 602 'lair 124.5 138.5 #:hp 2000 #:z 10)
                     (make-bldg 603 'spawning-pool 140.0 140.0 #:hp 1000 #:z 12)
                     (make-bldg 604 'roach-warren 138.0 143.0 #:hp 850 #:z 12)
                     (make-bldg 605 'spine-crawler 121.0 134.0 #:hp 300 #:z 10)
                     (make-bldg 606 'spore-crawler 146.0 141.0 #:hp 400 #:z 12)))]))
  (values ally-units ally-bldgs enemy-units enemy-bldgs))

(define (build-heavy-200v200-roster eff-race)
  (define opp-race (opponent-race-for-ally eff-race))
  ;; Exact target counts: 80 ally units, 80 enemy units, 40 buildings (24 ally + 16 enemy).
  (define-values (ally-units ally-bldgs)
    (case eff-race
      [(Zerg)
       (values
        (append
         (spawn-worker-line 101 'drone 22 32.5 32.5 12)
         (spawn-worker-line 123 'drone 22 52.5 36.5 10)
         (spawn-spec-units
          145
          '((queen 5 160 0 110 #f)
            (overlord 3 200 0 0 #t)
            (overseer 2 200 0 90 #t)
            (zergling 12 28 0 0 #f)
            (baneling 3 30 0 0 #f)
            (roach 4 125 0 0 #f)
            (ravager 2 110 0 0 #f)
            (hydralisk 3 75 0 0 #f)
            (lurker 1 180 0 0 #f)
            (viper 1 150 0 140 #t))
          84.0 80.0 18 10))
        (list (make-bldg 201 'hatchery 32.5 32.5 #:hp 1500 #:z 12)
              (make-bldg 202 'lair 52.5 36.5 #:hp 2000 #:z 10)
              (make-bldg 203 'hive 74.5 52.5 #:hp 2500 #:z 10)
              (make-bldg 204 'hatchery 96.5 68.5 #:hp 1500 #:z 10)
              (make-bldg 205 'spawning-pool 29.0 29.5 #:hp 1000 #:z 12)
              (make-bldg 206 'roach-warren 30.0 37.5 #:hp 850 #:z 12)
              (make-bldg 207 'baneling-nest 34.0 37.5 #:hp 850 #:z 12)
              (make-bldg 208 'hydralisk-den 38.0 35.0 #:hp 850 #:z 12)
              (make-bldg 209 'lurker-den 38.0 31.0 #:hp 850 #:z 12)
              (make-bldg 210 'infestation-pit 35.0 28.0 #:hp 850 #:z 12)
              (make-bldg 211 'evolution-chamber 30.0 26.0 #:hp 750 #:z 12)
              (make-bldg 212 'evolution-chamber 33.0 26.0 #:hp 750 #:z 12)
              (make-bldg 213 'spire 26.5 29.5 #:hp 850 #:z 12)
              (make-bldg 214 'nydus-network 26.5 36.5 #:hp 850 #:z 12)
              (make-bldg 215 'extractor 26.0 34.0 #:hp 500 #:z 12)
              (make-bldg 216 'extractor 55.5 31.0 #:hp 500 #:z 10)
              (make-bldg 217 'extractor 78.0 47.0 #:hp 500 #:z 10)
              (make-bldg 218 'extractor 99.0 63.0 #:hp 500 #:z 10)
              (make-bldg 219 'extractor 71.0 56.0 #:hp 500 #:z 10)
              (make-bldg 220 'spine-crawler 58.0 40.0 #:hp 260 #:max-hp 300 #:z 10)
              (make-bldg 221 'spine-crawler 79.0 56.0 #:hp 280 #:max-hp 300 #:z 10)
              (make-bldg 222 'spine-crawler 100.0 71.0 #:hp 250 #:max-hp 300 #:z 10)
              (make-bldg 223 'spore-crawler 34.5 36.0 #:hp 400 #:z 12)
              (make-bldg 224 'spore-crawler 51.0 40.5 #:hp 400 #:z 10)))]
      [(Terran)
       (values
        (append
         (spawn-worker-line 101 'scv 22 32.5 32.5 12)
         (spawn-worker-line 123 'scv 22 52.5 36.5 10)
         (spawn-spec-units
          145
          '((marine 18 35 0 0 #f)
            (marauder 6 105 0 0 #f)
            (siege-tank 3 160 0 0 #f)
            (medivac 4 135 0 95 #t)
            (viking-fighter 2 125 0 0 #t)
            (liberator 2 180 0 0 #t)
            (ghost 1 90 0 120 #f))
          84.0 80.0 18 10))
        (list (make-bldg 201 'orbital-command 32.5 32.5 #:hp 1500 #:energy 100 #:z 12)
              (make-bldg 202 'orbital-command 52.5 36.5 #:hp 1500 #:energy 85 #:z 10)
              (make-bldg 203 'planetary-fortress 74.5 52.5 #:hp 1350 #:max-hp 1500 #:z 10)
              (make-bldg 204 'command-center 96.5 68.5 #:hp 1500 #:z 10)
              (make-bldg 205 'supply-depot 45.0 31.0 #:hp 400 #:z 12)
              (make-bldg 206 'supply-depot 45.0 36.0 #:hp 400 #:z 12)
              (make-bldg 207 'supply-depot 28.0 27.0 #:hp 400 #:z 12)
              (make-bldg 208 'supply-depot 30.0 27.0 #:hp 400 #:z 12)
              (make-bldg 209 'supply-depot 32.0 27.0 #:hp 400 #:z 12)
              (make-bldg 210 'supply-depot 34.0 27.0 #:hp 400 #:z 12)
              (make-bldg 211 'barracks 36.0 29.0 #:hp 1000 #:z 12)
              (make-bldg 212 'barracks 39.0 29.0 #:hp 1000 #:z 12)
              (make-bldg 213 'barracks 36.0 35.0 #:hp 1000 #:z 12)
              (make-bldg 214 'barracks 39.0 35.0 #:hp 1000 #:z 12)
              (make-bldg 215 'factory 35.0 39.0 #:hp 1250 #:z 12)
              (make-bldg 216 'factory 39.0 39.0 #:hp 1250 #:z 12)
              (make-bldg 217 'starport 31.0 39.0 #:hp 1300 #:z 12)
              (make-bldg 218 'engineering-bay 27.0 36.0 #:hp 850 #:z 12)
              (make-bldg 219 'engineering-bay 27.0 39.0 #:hp 850 #:z 12)
              (make-bldg 220 'armory 29.0 42.0 #:hp 750 #:z 12)
              (make-bldg 221 'ghost-academy 33.0 42.0 #:hp 1250 #:z 12)
              (make-bldg 222 'bunker 57.0 40.0 #:hp 340 #:max-hp 400 #:z 10)
              (make-bldg 223 'bunker 79.0 56.0 #:hp 380 #:max-hp 400 #:z 10)
              (make-bldg 224 'missile-turret 35.0 32.0 #:hp 250 #:z 12)))]
      [else
       (values
        (append
         (spawn-worker-line 101 'probe 22 32.5 32.5 12)
         (spawn-worker-line 123 'probe 22 52.5 36.5 10)
         (spawn-spec-units
          145
          '((zealot 10 85 30 0 #f)
            (stalker 10 75 55 0 #f)
            (adept 4 65 55 0 #f)
            (sentry 3 40 35 100 #f)
            (immortal 3 190 70 0 #f)
            (high-templar 2 40 40 135 #f)
            (disruptor 2 100 100 0 #f)
            (phoenix 1 120 60 65 #t)
            (observer 1 40 20 0 #t))
          84.0 80.0 18 10))
        (list (make-bldg 201 'nexus 32.5 32.5 #:hp 1000 #:shield 1000 #:energy 110 #:z 12)
              (make-bldg 202 'nexus 52.5 36.5 #:hp 1000 #:shield 1000 #:energy 90 #:z 10)
              (make-bldg 203 'nexus 74.5 52.5 #:hp 1000 #:shield 1000 #:energy 75 #:z 10)
              (make-bldg 204 'nexus 96.5 68.5 #:hp 1000 #:shield 1000 #:energy 50 #:z 10)
              (make-bldg 205 'pylon 44.0 31.0 #:hp 200 #:shield 200 #:z 12)
              (make-bldg 206 'pylon 50.0 41.0 #:hp 200 #:shield 200 #:z 10)
              (make-bldg 207 'pylon 72.0 56.0 #:hp 200 #:shield 200 #:z 10)
              (make-bldg 208 'pylon 94.0 72.0 #:hp 200 #:shield 200 #:z 10)
              (make-bldg 209 'pylon 29.0 36.0 #:hp 200 #:shield 200 #:z 12)
              (make-bldg 210 'pylon 35.0 27.0 #:hp 200 #:shield 200 #:z 12)
              (make-bldg 211 'pylon 40.0 38.0 #:hp 200 #:shield 200 #:z 12)
              (make-bldg 212 'gateway 45.5 34.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 213 'gateway 39.0 29.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 214 'gateway 36.0 29.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 215 'gateway 41.0 34.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 216 'gateway 48.0 38.0 #:hp 500 #:shield 500 #:z 10)
              (make-bldg 217 'cybernetics-core 43.0 36.5 #:hp 550 #:shield 550 #:z 12)
              (make-bldg 218 'forge 29.0 30.0 #:hp 400 #:shield 400 #:z 12)
              (make-bldg 219 'forge 31.0 28.0 #:hp 400 #:shield 400 #:z 12)
              (make-bldg 220 'twilight-council 34.0 39.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 221 'robotics-facility 37.0 39.0 #:hp 450 #:shield 450 #:z 12)
              (make-bldg 222 'robotics-bay 37.0 42.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 223 'templar-archives 31.0 41.0 #:hp 500 #:shield 500 #:z 12)
              (make-bldg 224 'shield-battery 56.0 39.5 #:hp 150 #:shield 150 #:energy 100 #:z 10)))]))
  (define-values (enemy-units enemy-bldgs)
    (case opp-race
      [(Terran)
       (values (spawn-spec-units
                501
                '((scv 20 45 0 0 #f)
                  (marine 26 35 0 0 #f)
                  (marauder 12 105 0 0 #f)
                  (siege-tank 6 165 0 0 #f)
                  (medivac 6 140 0 90 #t)
                  (viking-fighter 6 130 0 0 #t)
                  (liberator 2 180 0 0 #t)
                  (ghost 2 90 0 110 #f))
                92.0 88.0 18 10)
               (list (make-bldg 601 'orbital-command 144.5 144.5 #:hp 1500 #:z 12)
                     (make-bldg 602 'orbital-command 124.5 138.5 #:hp 1500 #:z 10)
                     (make-bldg 603 'planetary-fortress 106.5 120.5 #:hp 1500 #:z 10)
                     (make-bldg 604 'supply-depot 130.0 137.0 #:hp 400 #:z 12)
                     (make-bldg 605 'supply-depot 130.0 139.0 #:hp 400 #:z 12)
                     (make-bldg 606 'supply-depot 130.0 141.0 #:hp 400 #:z 12)
                     (make-bldg 607 'barracks 133.0 140.0 #:hp 1000 #:z 12)
                     (make-bldg 608 'barracks 136.0 140.0 #:hp 1000 #:z 12)
                     (make-bldg 609 'barracks 133.0 144.0 #:hp 1000 #:z 12)
                     (make-bldg 610 'factory 136.0 144.0 #:hp 1250 #:z 12)
                     (make-bldg 611 'factory 139.0 144.0 #:hp 1250 #:z 12)
                     (make-bldg 612 'starport 139.0 140.0 #:hp 1300 #:z 12)
                     (make-bldg 613 'engineering-bay 142.0 138.0 #:hp 850 #:z 12)
                     (make-bldg 614 'armory 145.0 138.0 #:hp 750 #:z 12)
                     (make-bldg 615 'bunker 120.5 134.0 #:hp 400 #:z 10)
                     (make-bldg 616 'missile-turret 146.0 141.0 #:hp 250 #:z 12)))]
      [(Protoss)
       (values (spawn-spec-units
                501
                '((probe 20 20 20 0 #f)
                  (zealot 18 80 40 0 #f)
                  (stalker 18 75 65 0 #f)
                  (adept 6 70 60 0 #f)
                  (sentry 4 40 40 90 #f)
                  (immortal 6 190 90 0 #f)
                  (high-templar 4 40 40 120 #f)
                  (disruptor 2 100 100 0 #f)
                  (colossus 2 200 150 0 #f))
                92.0 88.0 18 10)
               (list (make-bldg 601 'nexus 144.5 144.5 #:hp 1000 #:shield 1000 #:z 12)
                     (make-bldg 602 'nexus 124.5 138.5 #:hp 1000 #:shield 1000 #:z 10)
                     (make-bldg 603 'nexus 106.5 120.5 #:hp 1000 #:shield 1000 #:z 10)
                     (make-bldg 604 'pylon 131.0 139.0 #:hp 200 #:shield 200 #:z 12)
                     (make-bldg 605 'pylon 122.0 136.0 #:hp 200 #:shield 200 #:z 10)
                     (make-bldg 606 'pylon 104.0 118.0 #:hp 200 #:shield 200 #:z 10)
                     (make-bldg 607 'gateway 133.0 142.0 #:hp 500 #:shield 500 #:z 12)
                     (make-bldg 608 'gateway 136.0 142.0 #:hp 500 #:shield 500 #:z 12)
                     (make-bldg 609 'gateway 139.0 142.0 #:hp 500 #:shield 500 #:z 12)
                     (make-bldg 610 'cybernetics-core 133.0 138.0 #:hp 550 #:shield 550 #:z 12)
                     (make-bldg 611 'forge 142.0 139.0 #:hp 400 #:shield 400 #:z 12)
                     (make-bldg 612 'twilight-council 140.0 136.0 #:hp 500 #:shield 500 #:z 12)
                     (make-bldg 613 'robotics-facility 137.0 136.0 #:hp 450 #:shield 450 #:z 12)
                     (make-bldg 614 'templar-archives 143.0 136.0 #:hp 500 #:shield 500 #:z 12)
                     (make-bldg 615 'photon-cannon 121.0 135.0 #:hp 150 #:shield 150 #:z 10)
                     (make-bldg 616 'shield-battery 120.0 133.0 #:hp 150 #:shield 150 #:z 10)))]
      [else
       (values (spawn-spec-units
                501
                '((drone 20 40 0 0 #f)
                  (zergling 24 30 0 0 #f)
                  (baneling 8 30 0 0 #f)
                  (roach 10 130 0 0 #f)
                  (ravager 4 115 0 0 #f)
                  (hydralisk 8 80 0 0 #f)
                  (lurker 2 185 0 0 #f)
                  (corruptor 2 200 0 0 #t)
                  (queen 2 175 0 100 #f))
                92.0 88.0 18 10)
               (list (make-bldg 601 'hatchery 144.5 144.5 #:hp 1500 #:z 12)
                     (make-bldg 602 'lair 124.5 138.5 #:hp 2000 #:z 10)
                     (make-bldg 603 'hive 106.5 120.5 #:hp 2500 #:z 10)
                     (make-bldg 604 'spawning-pool 140.0 140.0 #:hp 1000 #:z 12)
                     (make-bldg 605 'roach-warren 138.0 143.0 #:hp 850 #:z 12)
                     (make-bldg 606 'baneling-nest 135.0 143.0 #:hp 850 #:z 12)
                     (make-bldg 607 'hydralisk-den 135.0 140.0 #:hp 850 #:z 12)
                     (make-bldg 608 'lurker-den 132.0 140.0 #:hp 850 #:z 12)
                     (make-bldg 609 'evolution-chamber 142.0 138.0 #:hp 750 #:z 12)
                     (make-bldg 610 'evolution-chamber 145.0 138.0 #:hp 750 #:z 12)
                     (make-bldg 611 'spire 147.0 140.0 #:hp 850 #:z 12)
                     (make-bldg 612 'extractor 149.0 145.0 #:hp 500 #:z 12)
                     (make-bldg 613 'extractor 128.0 143.0 #:hp 500 #:z 10)
                     (make-bldg 614 'spine-crawler 120.0 134.0 #:hp 300 #:z 10)
                     (make-bldg 615 'spine-crawler 103.0 116.0 #:hp 300 #:z 10)
                     (make-bldg 616 'spore-crawler 146.0 141.0 #:hp 400 #:z 12)))]))
  (values ally-units ally-bldgs enemy-units enemy-bldgs))

(define (make-scenario-obs race tier map-grids [frame-offset 0])
  (define eff-race (effective-race-for-profile race tier))
  (define base-frame
    (case tier
      [(early) 1344]
      [(mid) 5376]
      [else 12000]))
  (define-values (ally-units ally-bldgs enemy-units enemy-bldgs)
    (case tier
      [(early) (build-early-roster eff-race)]
      [(mid) (build-mid-roster eff-race)]
      [else (build-heavy-200v200-roster eff-race)]))
  (define-values (minerals gas supply-used supply-cap harv-m ideal-m harv-g ideal-g army-sup upgs pend-upgs effects)
    (case tier
      [(early)
       (values 240 120 20 26 14 16 2 3 4 '() '() '())]
      [(mid)
       (values 520 340 94 112 36 32 6 6 52
               '(zerg-metabolic-boost terran-stimpack protoss-warpgate)
               '(zerg-missile-weapons-1)
               '())]
      [else
       (values 1150 780 186 200 38 36 12 12 142
               '(zerg-metabolic-boost zerg-glial-reconstitution zerg-ground-carapace-2
                 terran-stimpack terran-combat-shield protoss-warpgate protoss-blink)
               '(zerg-ground-carapace-3 terran-infantry-weapons-3 protoss-ground-weapons-3)
               (list (hash 'type 'psionic-storm 'x 88.0 'y 84.0)
                     (hash 'type 'corrosive-bile 'x 90.0 'y 86.0)))]))
  (hash 'frame (+ base-frame frame-offset)
        'race race
        'enemy-race (opponent-race-for-ally eff-race)
        'opponent-requested-race (if (eq? race 'Random) 'Random (opponent-race-for-ally eff-race))
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'supply-left (max 0 (- supply-cap supply-used))
        'pending-supply 0
        'pending-workers 1
        'depleting-bases 0
        'busy-facilities 2
        'busy-townhalls 1
        'enemy-workers-killed (if (eq? tier 'heavy-200v200) 9 1)
        'mineral-patch-id 9001
        'mineral-harvesters harv-m
        'ideal-mineral-harvesters ideal-m
        'gas-harvesters harv-g
        'ideal-gas-harvesters ideal-g
        'army-supply army-sup
        'our-terrain-z 12
        'enemy-terrain-z 12
        'base-x 32.5
        'base-y 32.5
        'natural-x 52.5
        'natural-y 36.5
        'third-x 74.5
        'third-y 52.5
        'enemy-x 144.5
        'enemy-y 144.5
        'enemy-expand-x 124.5
        'enemy-expand-y 138.5
        'ally-units ally-units
        'ally-buildings ally-bldgs
        'enemy-units enemy-units
        'enemy-buildings enemy-bldgs
        'effects effects
        'visible-sectors '(0 1 2 3 9 10 18 19 27 28 36 45)
        'researched-upgrades upgs
        'pending-upgrades pend-upgs
        'expansion-candidates (list (cons 52.5 36.5)
                                    (cons 74.5 52.5)
                                    (cons 96.5 68.5)
                                    (cons 124.5 138.5))
        'map-grids map-grids))

;; -----------------------------------------------------------------------------
;; Timing Statistics & Scenario Runner
;; -----------------------------------------------------------------------------

(define (compute-timing-stats samples-us)
  (when (null? samples-us)
    (error 'compute-timing-stats "expected non-empty timing sample list"))
  (define sorted (list->vector (sort samples-us <)))
  (define n (vector-length sorted))
  (define min-v (vector-ref sorted 0))
  (define max-v (vector-ref sorted (sub1 n)))
  (define median-v
    (if (odd? n)
        (vector-ref sorted (quotient n 2))
        (* 0.5 (+ (vector-ref sorted (sub1 (quotient n 2)))
                  (vector-ref sorted (quotient n 2))))))
  (define p95-idx (min (sub1 n) (max 0 (sub1 (inexact->exact (ceiling (* 0.95 n)))))))
  (define p95-v (vector-ref sorted p95-idx))
  (define mean-v (/ (for/sum ([v (in-vector sorted)]) v) (exact->inexact n)))
  (hash 'count n
        'min-us min-v
        'median-us median-v
        'p95-us p95-v
        'max-us max-v
        'mean-us mean-v))

(define (profile-scenario race tier map-grids
                          #:warmup [warmup DEFAULT-WARMUP-ITERS]
                          #:iters [iters DEFAULT-MEASURED-ITERS])
  (define rt (make-live-bot-runtime #:bot-name (string->symbol (format "prof-~a-~a" race tier))
                                    #:race race))
  (define warm-obs
    (for/list ([w (in-range warmup)])
      (make-scenario-obs race tier map-grids (* w 4))))
  (define meas-obs
    (for/list ([i (in-range iters)])
      (make-scenario-obs race tier map-grids (* (+ warmup i) 4))))
  (for ([obs (in-list warm-obs)])
    (void (step-live-bot-runtime! rt obs)))
  (define samples-us
    (for/list ([obs (in-list meas-obs)])
      (define t0 (current-inexact-monotonic-milliseconds))
      (void (step-live-bot-runtime! rt obs))
      (define t1 (current-inexact-monotonic-milliseconds))
      (* 1000.0 (- t1 t0))))
  (define stats (compute-timing-stats samples-us))
  (define sample0 (first meas-obs))
  (hash-set* stats
             'race race
             'tier tier
             'frame (hash-ref sample0 'frame)
             'ally-units (length (hash-ref sample0 'ally-units))
             'enemy-units (length (hash-ref sample0 'enemy-units))
             'buildings (+ (length (hash-ref sample0 'ally-buildings))
                           (length (hash-ref sample0 'enemy-buildings)))))

(define (profile-all-scenarios #:races [races PROFILE-RACES]
                               #:tiers [tiers PROFILE-TIERS]
                               #:warmup [warmup DEFAULT-WARMUP-ITERS]
                               #:iters [iters DEFAULT-MEASURED-ITERS])
  (define map-grids (make-synthetic-map-grids 176 176))
  (for*/list ([race (in-list races)]
              [tier (in-list tiers)])
    (profile-scenario race tier map-grids #:warmup warmup #:iters iters)))

;; -----------------------------------------------------------------------------
;; CLI Reporting & Verification
;; -----------------------------------------------------------------------------

(define (fmt-us v)
  (real->decimal-string v 1))

(define (print-scenario-table results budget-us)
  (printf "~a ~a ~a ~a ~a ~a ~a ~a ~a\n"
          (~a "RACE" #:min-width 8)
          (~a "TIER" #:min-width 14)
          (~a "FRAME" #:min-width 6 #:align 'right)
          (~a "U/E/B" #:min-width 10 #:align 'right)
          (~a "MIN_US" #:min-width 9 #:align 'right)
          (~a "MED_US" #:min-width 9 #:align 'right)
          (~a "P95_US" #:min-width 9 #:align 'right)
          (~a "MAX_US" #:min-width 9 #:align 'right)
          (~a "STATUS" #:min-width 6))
  (for ([r (in-list results)])
    (define p95 (hash-ref r 'p95-us))
    (define ok? (< p95 budget-us))
    (define counts-str
      (format "~a/~a/~a"
              (hash-ref r 'ally-units)
              (hash-ref r 'enemy-units)
              (hash-ref r 'buildings)))
    (printf "~a ~a ~a ~a ~a ~a ~a ~a ~a\n"
            (~a (hash-ref r 'race) #:min-width 8)
            (~a (hash-ref r 'tier) #:min-width 14)
            (~a (hash-ref r 'frame) #:min-width 6 #:align 'right)
            (~a counts-str #:min-width 10 #:align 'right)
            (~a (fmt-us (hash-ref r 'min-us)) #:min-width 9 #:align 'right)
            (~a (fmt-us (hash-ref r 'median-us)) #:min-width 9 #:align 'right)
            (~a (fmt-us p95) #:min-width 9 #:align 'right)
            (~a (fmt-us (hash-ref r 'max-us)) #:min-width 9 #:align 'right)
            (~a (if ok? "PASS" "FAIL") #:min-width 6))))

(define (print-summary-line results budget-us)
  (define total (length results))
  (define passed (count (lambda (r) (< (hash-ref r 'p95-us) budget-us)) results))
  (define worst-p95 (if (null? results) 0.0 (apply max (map (lambda (r) (hash-ref r 'p95-us)) results))))
  (define worst-max (if (null? results) 0.0 (apply max (map (lambda (r) (hash-ref r 'max-us)) results))))
  (printf "\nSUMMARY: ~a/~a scenarios p95 < ~a us (~a ms) | worst_p95=~a us | worst_max=~a us\n"
          passed
          total
          (fmt-us budget-us)
          (real->decimal-string (/ budget-us 1000.0) 2)
          (fmt-us worst-p95)
          (fmt-us worst-max)))

(module+ main
  (define summary? #f)
  (define verify? #f)
  (define iters DEFAULT-MEASURED-ITERS)
  (define warmup DEFAULT-WARMUP-ITERS)
  (define budget-us DEFAULT-BUDGET-US)
  (define race-filter 'all)
  (define tier-filter 'all)

  (command-line
   #:program "profile-core-loop"
   #:once-each
   [("--summary") "Print concise summary line alongside scenario timings"
                  (set! summary? #t)]
   [("--verify") "Assert every scenario p95 < budget-us (default 4000 us / 4.0 ms)"
                 (set! verify? #t)]
   [("--iters") n "Measured iterations per scenario (default 25)"
                (let ([v (string->number n)])
                  (unless (exact-positive-integer? v)
                    (error 'profile-core-loop "--iters must be a positive integer, got ~a" n))
                  (set! iters v))]
   [("--warmup") n "Warmup iterations per scenario (default 5)"
                 (let ([v (string->number n)])
                   (unless (exact-nonnegative-integer? v)
                     (error 'profile-core-loop "--warmup must be a non-negative integer, got ~a" n))
                   (set! warmup v))]
   [("--budget-us") us "Verification p95 budget in microseconds (default 4000.0)"
                    (let ([v (string->number us)])
                      (unless (and (real? v) (> v 0))
                        (error 'profile-core-loop "--budget-us must be positive real, got ~a" us))
                      (set! budget-us (exact->inexact v)))]
   [("--race") r "Filter race: Zerg, Terran, Protoss, Random, or all"
               (set! race-filter (string->symbol r))]
   [("--tier") t "Filter tier: early, mid, heavy-200v200, or all"
               (set! tier-filter (string->symbol t))])

  (define races (if (eq? race-filter 'all) PROFILE-RACES (list race-filter)))
  (define tiers (if (eq? tier-filter 'all) PROFILE-TIERS (list tier-filter)))
  (define results
    (profile-all-scenarios #:races races
                           #:tiers tiers
                           #:warmup warmup
                           #:iters iters))
  (print-scenario-table results budget-us)
  (when (or summary? verify?)
    (print-summary-line results budget-us))
  (when verify?
    (define failing
      (filter (lambda (r) (>= (hash-ref r 'p95-us) budget-us)) results))
    (unless (null? failing)
      (eprintf "VERIFY FAILED: ~a scenario(s) exceeded p95 budget ~a us\n"
               (length failing)
               (fmt-us budget-us))
      (exit 1))))
