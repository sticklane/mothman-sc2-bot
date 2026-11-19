#lang racket/base

;; =============================================================================
;; `tools/benchmark-pro-divergence.rkt`
;;
;; Dual-Perspective Pro-Replay Prioritization & Macro Divergence Benchmark
;;
;; Evaluates Mothman's prioritization and execution layers against ground-truth
;; professional LotV 1v1 trajectories from BOTH player perspectives:
;;   Part 1: `step-priority-macro-brain` across all checkpoints in
;;           `data/pro_starvation_checkpoints.sexp` (`n = 6,478`).
;;   Part 2: Full `step-live-bot-runtime!` (Brain + Layer 2 + Layer 3/4) on
;;           reconstructed spatial snapshots from `replays/pro_corpus/`
;;           (enabled via `--spatial`, default `--max-replays 80`), plus
;;           canonical scouted `12-pool` reactive opening probes (`PvZ`, `TvZ`,
;;           `ZvZ`).
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/runtime-path
         racket/set
         racket/string
         "../lib/sc2-mpq-replay-parser.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/priority-macro-brain.rkt"
         "../lib/bot-runtime.rkt")

(define-runtime-path DEFAULT-CP-PATH "../data/pro_starvation_checkpoints.sexp")
(define-runtime-path DEFAULT-PRO-DIR "../replays/pro_corpus")
(define-runtime-path TELEMETRY-JSONL-PATH "../data/racket_native_match_telemetry.jsonl")

(define (b->s v)
  (cond
    [(bytes? v) (bytes->string/utf-8 v #\?)]
    [(string? v) v]
    [else (format "~a" v)]))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (pct num den)
  (if (<= den 0) 0.0 (/ (* 100.0 num) den)))

(define (r1 x) (~r x #:precision '(= 1)))

(define (alist->hasheq pairs)
  (for/hasheq ([p (in-list pairs)]
               #:when (and (list? p) (= (length p) 2) (symbol? (car p))))
    (values (car p) (cadr p))))

(define WORKER-STRS '("Drone" "SCV" "Probe"))
(define TH-STRS '("Hatchery" "Lair" "Hive" "CommandCenter" "OrbitalCommand" "PlanetaryFortress" "Nexus"))
(define GAS-STRS '("Extractor" "Refinery" "Assimilator"))

(define BLDG-STRS
  (list->set
   '("CommandCenter" "OrbitalCommand" "PlanetaryFortress"
     "Barracks" "Factory" "Starport" "SupplyDepot" "SupplyDepotLowered"
     "EngineeringBay" "Armory" "GhostAcademy" "FusionCore"
     "Bunker" "MissileTurret" "SensorTower" "Refinery"
     "BarracksTechLab" "BarracksReactor" "FactoryTechLab" "FactoryReactor"
     "StarportTechLab" "StarportReactor" "TechLab" "Reactor"
     "Nexus" "Pylon" "Gateway" "WarpGate" "CyberneticsCore" "Forge"
     "PhotonCannon" "ShieldBattery" "TwilightCouncil" "Stargate"
     "RoboticsFacility" "RoboticsBay" "FleetBeacon" "TemplarArchive"
     "DarkShrine" "Assimilator"
     "Hatchery" "Lair" "Hive" "SpawningPool" "BanelingNest"
     "RoachWarren" "HydraliskDen" "LurkerDenMP" "Spire" "GreaterSpire"
     "InfestationPit" "UltraliskCavern" "EvolutionChamber"
     "SpineCrawler" "SporeCrawler" "NydusNetwork" "Extractor")))

(define TRACKER->SYM
  (hash "Drone" 'drone "SCV" 'scv "Probe" 'probe "Larva" 'larva
        "Overlord" 'overlord "Overseer" 'overseer
        "Zergling" 'zergling "Baneling" 'baneling "Queen" 'queen
        "Roach" 'roach "Ravager" 'ravager "Hydralisk" 'hydralisk
        "LurkerMP" 'lurker "Mutalisk" 'mutalisk "Corruptor" 'corruptor
        "BroodLord" 'brood-lord "Infestor" 'infestor "SwarmHostMP" 'swarm-host
        "Viper" 'viper "Ultralisk" 'ultralisk
        "Marine" 'marine "Marauder" 'marauder "Reaper" 'reaper "Ghost" 'ghost
        "Hellion" 'hellion "HellionTank" 'hellbat "WidowMine" 'widow-mine
        "SiegeTank" 'siege-tank "SiegeTankSieged" 'siege-tank
        "Cyclone" 'cyclone "Thor" 'thor "ThorAP" 'thor
        "VikingFighter" 'viking-fighter "VikingAssault" 'viking-fighter
        "Medivac" 'medivac "Liberator" 'liberator "Raven" 'raven
        "Banshee" 'banshee "Battlecruiser" 'battlecruiser
        "Zealot" 'zealot "Stalker" 'stalker "Sentry" 'sentry "Adept" 'adept
        "HighTemplar" 'high-templar "DarkTemplar" 'dark-templar "Archon" 'archon
        "Observer" 'observer "WarpPrism" 'warp-prism "Immortal" 'immortal
        "Colossus" 'colossus "Disruptor" 'disruptor
        "Phoenix" 'phoenix "VoidRay" 'void-ray "Oracle" 'oracle
        "Tempest" 'tempest "Carrier" 'carrier "Mothership" 'mothership
        "Hatchery" 'hatchery "Lair" 'lair "Hive" 'hive
        "SpawningPool" 'spawning-pool "Extractor" 'extractor
        "BanelingNest" 'baneling-nest "RoachWarren" 'roach-warren
        "EvolutionChamber" 'evolution-chamber "HydraliskDen" 'hydralisk-den
        "LurkerDenMP" 'lurker-den "Spire" 'spire "GreaterSpire" 'greater-spire
        "InfestationPit" 'infestation-pit "UltraliskCavern" 'ultralisk-cavern
        "SpineCrawler" 'spine-crawler "SporeCrawler" 'spore-crawler
        "NydusNetwork" 'nydus-network
        "CommandCenter" 'command-center "OrbitalCommand" 'orbital-command
        "PlanetaryFortress" 'planetary-fortress "SupplyDepot" 'supply-depot
        "SupplyDepotLowered" 'supply-depot-lowered "Refinery" 'refinery
        "Barracks" 'barracks "BarracksTechLab" 'barracks-techlab
        "BarracksReactor" 'barracks-reactor "Factory" 'factory
        "FactoryTechLab" 'factory-techlab "FactoryReactor" 'factory-reactor
        "Starport" 'starport "StarportTechLab" 'starport-techlab
        "StarportReactor" 'starport-reactor "EngineeringBay" 'engineering-bay
        "Armory" 'armory "GhostAcademy" 'ghost-academy "FusionCore" 'fusion-core
        "Bunker" 'bunker "MissileTurret" 'missile-turret
        "Nexus" 'nexus "Pylon" 'pylon "Assimilator" 'assimilator
        "Gateway" 'gateway "WarpGate" 'warp-gate "CyberneticsCore" 'cybernetics-core
        "Forge" 'forge "PhotonCannon" 'photon-cannon "ShieldBattery" 'shield-battery
        "TwilightCouncil" 'twilight-council "RoboticsFacility" 'robotics-facility
        "RoboticsBay" 'robotics-bay "Stargate" 'stargate "FleetBeacon" 'fleet-beacon
        "TemplarArchive" 'templar-archive "DarkShrine" 'dark-shrine))

;; -----------------------------------------------------------------------------
;; Part 1: `step-priority-macro-brain` Checkpoint Divergence Audit
;; -----------------------------------------------------------------------------

(define (run-brain-checkpoint-benchmark checkpoint-path)
  (define stats (make-hash))
  (define (inc! k) (hash-update! stats k add1 0))
  (call-with-input-file checkpoint-path
    (lambda (in)
      (let loop ()
        (define rec (read in))
        (unless (eof-object? rec)
          (match rec
            [(list 'pro-cp _rid _pidx race opp-race frame minerals gas sup-used sup-cap pend-sup
                   workers bases threat-sup rb-al tb-al uc-al upgs fut15)
             (define rb (alist->hasheq rb-al))
             (define tb (alist->hasheq tb-al))
             (define uc (alist->hasheq uc-al))
             (define sup-left (- sup-cap sup-used))
             (define army-sup
               (for/sum ([(s c) (in-hash uc)] #:when (not (memq s '(drone scv probe overlord))))
                 (define nd (lookup-sc2-tech-node s))
                 (* c (if nd (sc2-tech-node-supply-cost nd) 1))))
             ;; Realistic base-attack vs map-wide threat distinction:
             ;; Only treat as active in-base crisis when threat >= 6 AND threat > army-supply!
             (define under-atk?
               (and (>= threat-sup 6)
                    (> threat-sup army-sup)))
             (define ws
               (make-macro-world-state
                #:race race #:enemy-race opp-race #:frame frame
                #:minerals minerals #:gas gas
                #:supply-used sup-used #:supply-cap sup-cap
                #:supply-left sup-left #:pending-supply pend-sup
                #:workers workers #:active-bases bases
                #:ready-building-counts rb #:total-building-counts tb
                #:unit-counts uc #:researched-upgrades upgs
                #:army-supply army-sup #:enemy-threat-supply threat-sup
                #:under-attack? under-atk?
                #:peak-supply-reached sup-used))
             (define dec (step-priority-macro-brain ws))
             (define sched-ids (macro-brain-decision-scheduled-ids dec))
             (define saving-for (macro-brain-decision-saving-for dec))
             (define cat-ht (priority-schedule-result-category-utilities
                             (macro-brain-decision-priority-schedule dec)))
             (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
             (define w-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
             (define exp-sym (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
             (define gas-sym (case race [(Zerg) 'extractor] [(Terran) 'refinery] [else 'assimilator]))

             (define pro-built-w? (not (not (memq w-sym fut15))))
             (define pro-built-exp? (not (not (memq exp-sym fut15))))
             (define pro-built-gas? (not (not (memq gas-sym fut15))))
             (define brain-sched-w? (not (not (memq w-sym sched-ids))))
             (define w-entry (findf (lambda (e) (eq? (priority-decision-entry-id e) w-sym)) trace))
             (define w-rank (if w-entry (priority-decision-entry-rank w-entry) 99))
             (define w-util (if w-entry (priority-decision-entry-utility-score w-entry) 0.0))

             (inc! 'total-cps)
             (define race-cap (case race [(Zerg) 76] [(Protoss) 70] [else 66]))
             (when (and pro-built-w? (< workers race-cap) (>= minerals 50) (>= sup-left 1))
               (define th-bkt (if (> threat-sup 0) 'threat>0 'peaceful))
               (inc! (list 'pro-w-tot race th-bkt))
               (when brain-sched-w? (inc! (list 'brain-sched-w race th-bkt)))
               (when (<= w-rank 3) (inc! (list 'brain-w-top3 race th-bkt)))
               (when (< w-util 50.0) (inc! (list 'brain-w-util<50 race th-bkt))))

             (when (and (not pro-built-gas?) (< workers 38))
               (inc! (list 'pro-nogas-u38 race))
               (when (or (memq gas-sym sched-ids) (eq? saving-for gas-sym))
                 (inc! (list 'brain-premature-gas race))))

             (when (and pro-built-exp? (>= minerals 200))
               (inc! (list 'pro-exp-tot race))
               (when (or (memq exp-sym sched-ids) (eq? saving-for exp-sym))
                 (inc! (list 'brain-exp-hit race))))

             (when (eq? race 'Zerg)
               (define z-t2t3
                 (filter (lambda (s)
                           (memq s '(lair hive hydralisk-den lurker-den spire greater-spire
                                     infestation-pit ultralisk-cavern hydralisk lurker
                                     mutalisk corruptor brood-lord viper)))
                         fut15))
               (when (pair? z-t2t3)
                 (inc! 'zerg-t2t3-tot)
                 (when (ormap (lambda (s) (or (memq s sched-ids) (eq? saving-for s))) z-t2t3)
                   (inc! 'zerg-t2t3-hit))))]
            [_ (void)])
          (loop)))))
  stats)

;; -----------------------------------------------------------------------------
;; Part 2: Reconstructed Spatial Snapshot & Reactive-Opening Runtime Benchmark
;; -----------------------------------------------------------------------------

(define (extract-replay-spatial-snaps path)
  (with-handlers ([exn:fail? (lambda (_e) '())])
    (define parsed (parse-sc2-replay path))
    (define pls (hash-ref parsed 'players (hasheqv)))
    (define p1 (hash-ref pls 1 #f))
    (define p2 (hash-ref pls 2 #f))
    (define dur (hash-ref parsed 'duration_sec 0.0))
    (if (not (and p1 p2 (>= dur 90.0)))
        '()
        (let ()
          (define r1 (hash-ref p1 'actual_race "?"))
          (define r2 (hash-ref p2 'actual_race "?"))
          (define mpq (read-mpq-files path #:filenames '("replay.tracker.events")))
          (define trk (hash-ref mpq "replay.tracker.events" #f))
          (if (not (and trk
                        (member r1 '("Zerg" "Terran" "Protoss"))
                        (member r2 '("Zerg" "Terran" "Protoss"))))
              '()
              (let ()
                (define evs (decode-tracker-stream trk))
                (define f0-w (make-hasheqv '((1 . 0) (2 . 0))))
                (define start-xy (make-hasheqv))
                (define f0-res '())
                (for ([ev (in-list evs)] #:when (and (= (car ev) 0) (= (cadr ev) 1)))
                  (define pl (caddr ev))
                  (define cp (hash-ref pl 3 0))
                  (define ut (b->s (hash-ref pl 2 #"")))
                  (define ux (exact->inexact (hash-ref pl 5 0)))
                  (define uy (exact->inexact (hash-ref pl 6 0)))
                  (cond
                    [(and (= cp 0) (or (string-contains? ut "Mineral") (string-contains? ut "Vespene")))
                     (set! f0-res (cons (cons ux uy) f0-res))]
                    [(memv cp '(1 2))
                     (when (member ut WORKER-STRS) (hash-update! f0-w cp add1 0))
                     (when (member ut '("Hatchery" "CommandCenter" "Nexus"))
                       (hash-set! start-xy cp (cons ux uy)))]))
                (if (not (and (= (hash-ref f0-w 1 0) 12)
                              (= (hash-ref f0-w 2 0) 12)
                              (= (hash-count start-xy) 2)))
                    '()
                    (let ()
                      (define base-centroids
                        (let cloop ([rem f0-res] [cls '()])
                          (if (null? rem)
                              (map (lambda (c)
                                     (cons (/ (for/sum ([q (in-list c)]) (car q)) (length c))
                                           (/ (for/sum ([q (in-list c)]) (cdr q)) (length c))))
                                   cls)
                              (let* ([pt (car rem)] [px (car pt)] [py (cdr pt)])
                                (let floop ([cs cls] [acc '()])
                                  (cond
                                    [(null? cs) (cloop (cdr rem) (cons (list pt) cls))]
                                    [else
                                     (define c (car cs))
                                     (define cx (/ (for/sum ([q (in-list c)]) (car q)) (length c)))
                                     (define cy (/ (for/sum ([q (in-list c)]) (cdr q)) (length c)))
                                     (if (<= (dist2d px py cx cy) 14.0)
                                         (cloop (cdr rem) (append (reverse acc) (list (cons pt c)) (cdr cs)))
                                         (floop (cdr cs) (cons c acc)))]))))))
                      (define pid->bases (make-hasheqv))
                      (for ([pid '(1 2)])
                        (define sxy (hash-ref start-xy pid '(32.0 . 32.0)))
                        (hash-set! pid->bases pid
                                   (sort base-centroids < #:key (lambda (c) (dist2d (car c) (cdr c) (car sxy) (cdr sxy))))))

                      (define utag->type (make-hasheqv))
                      (define utag->pid (make-hasheqv))
                      (define utag->xy (make-hasheqv))
                      (define utag->done? (make-hasheqv))
                      (define alive (mutable-seteqv))
                      (define cur-w (make-hasheqv '((1 . 0) (2 . 0))))
                      (define cur-mb (make-hasheqv '((1 . 50) (2 . 50))))
                      (define cur-gb (make-hasheqv '((1 . 0) (2 . 0))))
                      (define cur-su (make-hasheqv '((1 . 12.0) (2 . 12.0))))
                      (define cur-sc (make-hasheqv '((1 . 15.0) (2 . 15.0))))
                      (define all-prod (make-hasheqv '((1 . ()) (2 . ()))))
                      (define next-rt '(2016 3024 4032 5040 6048 7056 8064 9072 10080))
                      (define snaps '())

                      (define (capture! gl)
                        (for ([pid '(1 2)])
                          (define opp (if (= pid 1) 2 1))
                          (define r-str (if (= pid 1) r1 r2))
                          (define or-str (if (= opp 1) r1 r2))
                          (define own-bs (hash-ref pid->bases pid))
                          (define opp-bs (hash-ref pid->bases opp))
                          (define b0 (if (pair? own-bs) (car own-bs) '(32.0 . 32.0)))
                          (define b1 (if (>= (length own-bs) 2) (cadr own-bs) (cons (+ (car b0) 20.0) (cdr b0))))
                          (define b2 (if (>= (length own-bs) 3) (caddr own-bs) (cons (+ (car b0) 40.0) (cdr b0))))
                          (define e0 (if (pair? opp-bs) (car opp-bs) '(152.0 . 152.0)))
                          (define ally-u '())
                          (define ally-b '())
                          (define enemy-u '())
                          (define enemy-b '())
                          (define g-cnt 0)
                          (define z-ready-ths 0)
                          (define explicit-larva 0)
                          (for ([utag (in-set alive)])
                            (define upid (hash-ref utag->pid utag 0))
                            (define ut-str (hash-ref utag->type utag ""))
                            (define sym (hash-ref TRACKER->SYM ut-str #f))
                            (when (and sym (memv upid '(1 2)))
                              (define xy (hash-ref utag->xy utag '(32.0 . 32.0)))
                              (define done? (hash-ref utag->done? utag #t))
                              (define is-b? (set-member? BLDG-STRS ut-str))
                              (cond
                                [(= upid pid)
                                 (if is-b?
                                     (begin
                                       (when (and done? (member ut-str GAS-STRS)) (set! g-cnt (add1 g-cnt)))
                                       (when (and done? (member ut-str '("Hatchery" "Lair" "Hive")))
                                         (set! z-ready-ths (add1 z-ready-ths)))
                                       (set! ally-b (cons (hash 'id utag 'type sym 'x (car xy) 'y (cdr xy)
                                                                'hp 1000 'max-hp 1000
                                                                'build-progress (if done? 1.0 0.5)
                                                                'powered? #t 'vespene-contents 1500)
                                                          ally-b)))
                                     (let ([synth-hp (if (memq sym '(overlord overseer overlord-transport))
                                                         200
                                                         45)])
                                       (when (eq? sym 'larva) (set! explicit-larva (add1 explicit-larva)))
                                       (set! ally-u (cons (hash 'id utag 'type sym 'x (car xy) 'y (cdr xy)
                                                                'hp synth-hp 'max-hp synth-hp)
                                                          ally-u))))]
                                [else
                                 (define d-own (min (dist2d (car xy) (cdr xy) (car b0) (cdr b0))
                                                    (dist2d (car xy) (cdr xy) (car b1) (cdr b1))))
                                 (when (<= d-own 32.0)
                                   (if is-b?
                                       (set! enemy-b (cons (hash 'id utag 'type sym 'x (car xy) 'y (cdr xy)
                                                                 'hp 1000 'max-hp 1000
                                                                 'build-progress (if done? 1.0 0.5))
                                                           enemy-b))
                                       (set! enemy-u (cons (hash 'id utag 'type sym 'x (car xy) 'y (cdr xy) 'hp 60)
                                                           enemy-u))))])))
                          ;; Tracker events do not reliably keep idle Larva alive; synthesize 3 per ready Hatchery when 0 explicit
                          (when (and (equal? r-str "Zerg") (= explicit-larva 0) (> z-ready-ths 0))
                            (for ([li (in-range (* 3 z-ready-ths))])
                              (set! ally-u (cons (hash 'id (+ 950000 li) 'type 'larva
                                                       'x (car b0) 'y (cdr b0) 'hp 25)
                                                 ally-u))))
                          (define wk (hash-ref cur-w pid 12))
                          (define vharv (min wk (* 3 g-cnt)))
                          (define mharv (max 0 (- wk vharv)))
                          (define su (inexact->exact (round (hash-ref cur-su pid 12.0))))
                          (define sc (max su (inexact->exact (round (hash-ref cur-sc pid 15.0)))))
                          (set! snaps
                                (cons (list pid gl (string->symbol r-str) (string->symbol or-str)
                                            (hash 'frame gl
                                                  'race (string->symbol r-str)
                                                  'enemy-race (string->symbol or-str)
                                                  'minerals (max 0 (hash-ref cur-mb pid 50))
                                                  'gas (max 0 (hash-ref cur-gb pid 0))
                                                  'supply-used su 'supply-cap sc 'supply-left (max 0 (- sc su))
                                                  'mineral-harvesters mharv 'vespene-harvesters vharv
                                                  'base-x (car b0) 'base-y (cdr b0)
                                                  'natural-x (car b1) 'natural-y (cdr b1)
                                                  'third-x (car b2) 'third-y (cdr b2)
                                                  'enemy-x (car e0) 'enemy-y (cdr e0)
                                                  'expansion-candidates (map (lambda (p) (list (car p) (cdr p)))
                                                                             (drop own-bs (min 1 (length own-bs))))
                                                  'ally-units ally-u 'ally-buildings ally-b
                                                  'enemy-units enemy-u 'enemy-buildings enemy-b))
                                      snaps))))

                      (for ([ev (in-list evs)])
                        (define gl (car ev))
                        (define eid (cadr ev))
                        (define pl (caddr ev))
                        (let rloop ()
                          (when (and (pair? next-rt) (>= gl (car next-rt)))
                            (define rg (car next-rt))
                            (set! next-rt (cdr next-rt))
                            (capture! rg)
                            (rloop)))
                        (when (hash? pl)
                          (case eid
                            [(0)
                             (define pid (hash-ref pl 0 0))
                             (define st (hash-ref pl 1 #f))
                             (when (and (memv pid '(1 2)) (hash? st))
                               (hash-set! cur-mb pid (hash-ref st 0 0))
                               (hash-set! cur-gb pid (hash-ref st 1 0))
                               (hash-set! cur-su pid (/ (hash-ref st 29 49152) 4096.0))
                               (hash-set! cur-sc pid (/ (hash-ref st 30 61440) 4096.0)))]
                            [(1 6)
                             (define utag (+ (arithmetic-shift (hash-ref pl 0 0) 18) (hash-ref pl 1 0)))
                             (define pid (hash-ref pl 3 0))
                             (define ut (b->s (hash-ref pl 2 #"")))
                             (define ux (exact->inexact (hash-ref pl 5 0)))
                             (define uy (exact->inexact (hash-ref pl 6 0)))
                             (when (memv pid '(1 2))
                               (define fresh? (not (set-member? alive utag)))
                               (hash-set! utag->type utag ut)
                               (hash-set! utag->pid utag pid)
                               (hash-set! utag->xy utag (cons ux uy))
                               (hash-set! utag->done? utag (= eid 1))
                               (when fresh?
                                 (set-add! alive utag)
                                 (when (member ut WORKER-STRS) (hash-update! cur-w pid add1 0))
                                 (when (> gl 0)
                                   (define sym (hash-ref TRACKER->SYM ut #f))
                                   (when sym
                                     (hash-update! all-prod pid (lambda (ls) (cons (cons gl sym) ls)) '())))))]
                            [(7)
                             (define utag (+ (arithmetic-shift (hash-ref pl 0 0) 18) (hash-ref pl 1 0)))
                             (hash-set! utag->done? utag #t)]
                            [(4)
                             (define utag (+ (arithmetic-shift (hash-ref pl 0 0) 18) (hash-ref pl 1 0)))
                             (define pid (hash-ref utag->pid utag 0))
                             (define nut (b->s (hash-ref pl 2 #"")))
                             (when (memv pid '(1 2))
                               (hash-set! utag->type utag nut)
                               (define sym (hash-ref TRACKER->SYM nut #f))
                               (when (and (> gl 0) sym)
                                 (hash-update! all-prod pid (lambda (ls) (cons (cons gl sym) ls)) '())))]
                            [(2)
                             (define utag (+ (arithmetic-shift (hash-ref pl 0 0) 18) (hash-ref pl 1 0)))
                             (define pid (hash-ref utag->pid utag 0))
                             (define ut (hash-ref utag->type utag ""))
                             (when (and (memv pid '(1 2)) (set-member? alive utag))
                               (set-remove! alive utag)
                               (when (member ut WORKER-STRS)
                                 (hash-update! cur-w pid (lambda (v) (max 0 (sub1 v))) 0)))])))

                      (define p1-ev (reverse (hash-ref all-prod 1 '())))
                      (define p2-ev (reverse (hash-ref all-prod 2 '())))
                      (for/list ([rs (in-list (reverse snaps))])
                        (match-define (list pid gl r-sym or-sym obs-ht) rs)
                        (define pevs (if (= pid 1) p1-ev p2-ev))
                        (define fut-syms
                          (remove-duplicates
                           (for/list ([e (in-list pevs)]
                                      #:when (and (>= (car e) gl) (<= (car e) (+ gl 336))))
                             (cdr e))
                           eq?))
                        (list pid gl r-sym or-sym obs-ht fut-syms))))))))))

(define (run-reactive-opening-probes)
  ;; Probe 1: PvZ @ 1:03 (frame 1420), Gateway scout Probe reaches Zerg main and sees a finished
  ;; 12-Pool (`spawning-pool` ready, 0 enemy natural hatchery, 0 zerglings hatched yet), 400M bank.
  ;; Pro response: Cybernetics Core (+ Zealot) BEFORE 2nd Nexus!
  (define pvz-rt (make-live-bot-runtime #:race 'Protoss))
  (define pvz-obs
    (hash 'frame 1420 'race 'Protoss 'enemy-race 'Zerg
          'minerals 400 'gas 50 'supply-used 19 'supply-cap 23 'supply-left 4
          'mineral-harvesters 16 'vespene-harvesters 3
          'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
          'enemy-x 152.0 'enemy-y 152.0
          'expansion-candidates '((52.0 36.0) (72.0 40.0))
          'ally-units (append (for/list ([i (in-range 18)])
                                (hash 'id (+ 100 i) 'type 'probe 'x 33.0 'y 33.0 'hp 40))
                              (list (hash 'id 199 'type 'probe 'x 150.0 'y 150.0 'hp 40)))
          'ally-buildings (list (hash 'id 1 'type 'nexus 'x 32.0 'y 32.0 'build-progress 1.0 'powered? #t)
                                (hash 'id 2 'type 'pylon 'x 38.0 'y 34.0 'build-progress 1.0 'powered? #t)
                                (hash 'id 3 'type 'gateway 'x 40.0 'y 34.0 'build-progress 1.0 'powered? #t)
                                (hash 'id 4 'type 'assimilator 'x 28.0 'y 32.0 'build-progress 1.0 'powered? #t 'vespene-contents 1500))
          'enemy-units '()
          'enemy-buildings (list (hash 'id 601 'type 'hatchery 'x 152.0 'y 152.0 'build-progress 1.0)
                                 (hash 'id 602 'type 'spawning-pool 'x 148.0 'y 150.0 'build-progress 1.0))))
  (define pvz-acts (hash-ref (step-live-bot-runtime! pvz-rt pvz-obs) 'actions '()))
  (define pvz-built-core?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'cybernetics-core))) pvz-acts))
  (define pvz-trained-zealot?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (cadr a) 'zealot))) pvz-acts))
  (define pvz-built-nexus?
    (ormap (lambda (a)
             (and (pair? a)
                  (or (eq? (car a) 'expand)
                      (and (eq? (car a) 'build) (eq? (cadr a) 'nexus)))))
           pvz-acts))
  (define pvz-core-before-nexus? (and pvz-built-core? pvz-trained-zealot? (not pvz-built-nexus?)))

  ;; Probe 2: TvZ @ 1:55 (frame 2576), Terran has Barracks + Orbital + CC2 building + 150M/100G:
  ;; Pro response: Factory + BarracksReactor BEFORE BarracksTechLab!
  (define tvz-ws
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Zerg #:frame 2576
     #:minerals 200 #:gas 100
     #:supply-used 22 #:supply-cap 31 #:supply-left 9 #:pending-supply 0
     #:workers 19 #:active-bases 2
     #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 1 'barracks 1 'refinery 1)
     #:total-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 2 'barracks 1 'refinery 1)
     #:unit-counts (hasheq 'scv 19 'reaper 1 'marine 1)
     #:researched-upgrades '()
     #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f #:peak-supply-reached 22))
  (define tvz-dec (step-priority-macro-brain tvz-ws))
  (define tvz-sched (macro-brain-decision-scheduled-ids tvz-dec))
  (define tvz-save (macro-brain-decision-saving-for tvz-dec))
  (define tvz-factory-or-reactor-first?
    (and (or (memq 'factory tvz-sched) (eq? tvz-save 'factory)
             (memq 'barracks-reactor tvz-sched) (eq? tvz-save 'barracks-reactor))
         (not (memq 'barracks-techlab tvz-sched))))

  (hasheq 'pvz-12pool-core-before-nexus? pvz-core-before-nexus?
          'pvz-actions pvz-acts
          'tvz-factory-reactor-before-techlab? tvz-factory-or-reactor-first?
          'tvz-sched tvz-sched))

(module+ main
  (define run-spatial? #f)
  (define max-replays 80)
  (command-line
   #:program "benchmark-pro-divergence"
   #:once-each
   [("--spatial") "Also evaluate full `step-live-bot-runtime!` on reconstructed replay snapshots"
                  (set! run-spatial? #t)]
   [("--max-replays") n "Max LotV replays to parse in --spatial mode (default: 80)"
                      (set! max-replays (max 1 (or (string->number n) 80)))])

  ;; Preserve `data/racket_native_match_telemetry.jsonl` byte-for-byte
  (define saved-telemetry-bytes
    (and (file-exists? TELEMETRY-JSONL-PATH)
         (file->bytes TELEMETRY-JSONL-PATH)))

  (dynamic-wind
    void
    (lambda ()
      (define bs (run-brain-checkpoint-benchmark DEFAULT-CP-PATH))
      (printf "================================================================================\n")
      (printf "  PRO-REPLAY DUAL-PERSPECTIVE DIVERGENCE BENCHMARK\n")
      (printf "================================================================================\n")
      (printf "Part 1 — `step-priority-macro-brain` on ~a Pro Checkpoints:\n"
              (hash-ref bs 'total-cps 0))
      (for ([rsym '(Terran Protoss Zerg)])
        (for ([tb '(peaceful threat>0)])
          (define tot (hash-ref bs (list 'pro-w-tot rsym tb) 0))
          (define hit (hash-ref bs (list 'brain-sched-w rsym tb) 0))
          (define top3 (hash-ref bs (list 'brain-w-top3 rsym tb) 0))
          (define u50 (hash-ref bs (list 'brain-w-util<50 rsym tb) 0))
          (printf "  [~a | ~a] Pro Built Worker (n=~a): Recall=~a% | Rank<=3=~a% | Util<50=~a%\n"
                  rsym tb tot (r1 (pct hit tot)) (r1 (pct top3 tot)) (r1 (pct u50 tot))))
        (define ngt (hash-ref bs (list 'pro-nogas-u38 rsym) 0))
        (define pg (hash-ref bs (list 'brain-premature-gas rsym) 0))
        (define expt (hash-ref bs (list 'pro-exp-tot rsym) 0))
        (define exph (hash-ref bs (list 'brain-exp-hit rsym) 0))
        (printf "  [~a] Premature Gas (<38w)=~a% (n=~a) | Pro Expand Recall=~a% (n=~a)\n"
                rsym (r1 (pct pg ngt)) ngt (r1 (pct exph expt)) expt))
      (printf "  [Zerg T2/T3 Transitions] Pro T2/T3 Recall=~a% (n=~a)\n"
              (r1 (pct (hash-ref bs 'zerg-t2t3-hit 0) (hash-ref bs 'zerg-t2t3-tot 0)))
              (hash-ref bs 'zerg-t2t3-tot 0))

      (define probes (run-reactive-opening-probes))
      (printf "\nPart 2 — Pro Scouting & Opening Reactivity Probes:\n")
      (printf "  [PvZ vs Scouted 12-Pool @ 1:25] Core-Before-Nexus: ~a (actions=~s)\n"
              (if (hash-ref probes 'pvz-12pool-core-before-nexus?) "PASS" "FAIL")
              (hash-ref probes 'pvz-actions))
      (printf "  [TvZ Opening @ 1:55] Factory/Reactor Before TechLab: ~a (sched=~s)\n"
              (if (hash-ref probes 'tvz-factory-reactor-before-techlab?) "PASS" "FAIL")
              (hash-ref probes 'tvz-sched))

      (when run-spatial?
        (define all-files
          (sort (for/list ([p (in-directory DEFAULT-PRO-DIR)]
                           #:when (and (file-exists? p)
                                       (string-suffix? (path->string p) ".SC2Replay")
                                       (not (string-contains? (string-downcase (path->string p)) "battlepoker"))))
                  p)
                path<?))
        (define snaps '())
        (define parsed-cnt 0)
        (for ([f (in-list all-files)] #:break (>= parsed-cnt max-replays))
          (define s (extract-replay-spatial-snaps f))
          (when (pair? s)
            (set! parsed-cnt (add1 parsed-cnt))
            (set! snaps (append s snaps))))
        (define l2 (make-hash))
        (define (inc2! k) (hash-update! l2 k add1 0))
        (for ([rs (in-list snaps)])
          (match-define (list _pid _gl r-sym _or-sym obs-ht fut-syms) rs)
          (with-handlers ([exn:fail? (lambda (_e) (inc2! 'exn))])
            (define rt (make-live-bot-runtime #:race r-sym))
            (define out (step-live-bot-runtime! rt obs-ht))
            (define acts (hash-ref out 'actions '()))
            (define tel (live-bot-runtime-last-telemetry rt))
            (define prio-ht (hash-ref tel 'priority-summary (hash)))
            (define b-sched (hash-ref prio-ht 'scheduled-ids '()))
            (define w-sym (case r-sym [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
            (define exp-sym (case r-sym [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
            (define gas-sym (case r-sym [(Zerg) 'extractor] [(Terran) 'refinery] [else 'assimilator]))
            (define workers (+ (hash-ref obs-ht 'mineral-harvesters 0) (hash-ref obs-ht 'vespene-harvesters 0)))
            (define minerals (hash-ref obs-ht 'minerals 0))
            (define sup-left (hash-ref obs-ht 'supply-left 0))
            (define vis-enemy?
              (pair? (filter (lambda (e) (not (memq (hash-ref e 'type 'unknown) '(drone scv probe overlord observer))))
                             (hash-ref obs-ht 'enemy-units '()))))
            (define tb (if vis-enemy? 'enemy-visible 'peaceful))
            (define emitted-w?
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (cadr a) w-sym))) acts))
            (define emitted-exp?
              (ormap (lambda (a)
                       (and (pair? a)
                            (or (eq? (car a) 'expand)
                                (and (eq? (car a) 'build) (eq? (cadr a) exp-sym)))))
                     acts))
            (define emitted-gas?
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) gas-sym))) acts))
            (define race-cap (case r-sym [(Zerg) 76] [(Protoss) 70] [else 66]))
            (inc2! 'tot)
            (when (and (memq w-sym fut-syms) (< workers race-cap) (>= minerals 50) (>= sup-left 1))
              (inc2! (list 'pro-w r-sym tb))
              (when (memq w-sym b-sched) (inc2! (list 'brain-w r-sym tb)))
              (when emitted-w? (inc2! (list 'l2-w r-sym tb)))
              (when (and (memq w-sym b-sched) (not emitted-w?))
                (inc2! (list 'l2-veto-w r-sym tb))))
            (when (and (not (memq gas-sym fut-syms)) (< workers 40))
              (inc2! (list 'nogas r-sym))
              (when emitted-gas? (inc2! (list 'l2-pgas r-sym))))
            (when (and (memq exp-sym fut-syms) (>= minerals (if (eq? r-sym 'Zerg) 300 400)))
              (inc2! (list 'exp-tot r-sym))
              (when emitted-exp? (inc2! (list 'l2-exp r-sym))))))

        (printf "\nPart 3 — Full `step-live-bot-runtime!` on ~a Spatial Snapshots (~a LotV Replays, exns=~a):\n"
                (hash-ref l2 'tot 0) parsed-cnt (hash-ref l2 'exn 0))
        (for ([rsym '(Terran Protoss Zerg)])
          (for ([tb '(peaceful enemy-visible)])
            (define tot (hash-ref l2 (list 'pro-w rsym tb) 0))
            (define bw (hash-ref l2 (list 'brain-w rsym tb) 0))
            (define lw (hash-ref l2 (list 'l2-w rsym tb) 0))
            (define vw (hash-ref l2 (list 'l2-veto-w rsym tb) 0))
            (printf "  [~a | ~a] Pro Built Worker & Affordable (n=~a): Brain=~a% | Layer-2 Emitted=~a% | L2 Vetoed Brain=~a%\n"
                    rsym tb tot (r1 (pct bw tot)) (r1 (pct lw tot)) (r1 (pct vw (max 1 bw)))))
          (define ngt (hash-ref l2 (list 'nogas rsym) 0))
          (define pgl2 (hash-ref l2 (list 'l2-pgas rsym) 0))
          (define expt (hash-ref l2 (list 'exp-tot rsym) 0))
          (define expl2 (hash-ref l2 (list 'l2-exp rsym) 0))
          (printf "  [~a] L2 Premature Gas (<40w)=~a% (n=~a) | L2 Affordable Pro Expand Recall=~a% (n=~a)\n"
                  rsym (r1 (pct pgl2 ngt)) ngt (r1 (pct expl2 expt)) expt))))
    (lambda ()
      (when saved-telemetry-bytes
        (display-to-file saved-telemetry-bytes TELEMETRY-JSONL-PATH #:exists 'replace)))))
