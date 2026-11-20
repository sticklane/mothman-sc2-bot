#lang racket/base

;; =============================================================================
;; `tools/score-replay-batch.rkt` — Fast Parallel Single-Pass Replay & Log Scorer
;;
;; Single-pass MPQ/tracker + streaming log forensic scorer for AI Arena and local
;; parallel SC2 arena runs (`tools/run-local-sc2-arena.py`). Parallelizes across
;; CPU cores via `racket/place`, runs 5 automatic anomaly detectors, computes
;; per-race and per-matchup macro timing distributions for pro-data comparison,
;; and supports `--compare <baseline.json>` side-by-side deltas.
;;
;; Usage:
;;   raco make tools/score-replay-batch.rkt
;;   racket tools/score-replay-batch.rkt [flags] <run_dir>
;;
;; Flags:
;;   --bot-prefix <str>      Our bot name substring (default: Mothman)
;;   --json <path>           Write structured v2 JSON report
;;   --compare <base.json>   Print before/after delta table against baseline JSON
;;   --anomalies             Print detailed forensic dossier for flagged anomalies
;;   --verbose               Print per-match units, buildings, and log breakdown
;;   -j, --jobs <N>          Parallel worker places (default: 8)
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/place
         racket/port
         racket/set
         racket/string
         racket/runtime-path
         file/unzip
         json
         "../lib/sc2-mpq-replay-parser.rkt")

(provide score-batch-worker-main)

(define-runtime-path THIS-MODULE "score-replay-batch.rkt")

;; -----------------------------------------------------------------------------
;; Formatting & Statistical Helpers
;; -----------------------------------------------------------------------------

(define (r0 x) (~r (if (real? x) x 0) #:precision 0))
(define (r1 x) (~r (if (real? x) x 0.0) #:precision '(= 1)))
(define (r2 x) (~r (if (real? x) x 0.0) #:precision '(= 2)))

(define (round1 x)
  (/ (round (* (exact->inexact x) 10.0)) 10.0))

(define (round2 x)
  (/ (round (* (exact->inexact x) 100.0)) 100.0))

(define (pad-r s w)
  (define str (format "~a" s))
  (if (>= (string-length str) w)
      (substring str 0 w)
      (string-append str (make-string (- w (string-length str)) #\space))))

(define (fmt-mmss sec)
  (define s (max 0 (inexact->exact (round (if (real? sec) sec 0.0)))))
  (format "~a:~a"
          (quotient s 60)
          (~r (modulo s 60) #:min-width 2 #:pad-string "0")))

(define (safe-num v [d 0])
  (if (and (real? v) (not (nan? v)) (not (infinite? v))) v d))

(define (b->s v)
  (cond [(bytes? v) (bytes->string/utf-8 v #\?)]
        [(string? v) v]
        [else (format "~a" v)]))

(define (top-k-pairs ht k)
  (define sorted (sort (hash->list ht) > #:key cdr))
  (take sorted (min k (length sorted))))

(define (percentile-sorted sorted-vals p)
  (define n (length sorted-vals))
  (cond
    [(= n 0) #f]
    [(= n 1) (exact->inexact (car sorted-vals))]
    [else
     (define idx (min (sub1 n) (max 0 (inexact->exact (round (* p (sub1 n)))))))
     (exact->inexact (list-ref sorted-vals idx))]))

(define (num-dist vals)
  (define clean (sort (filter real? vals) <))
  (define n (length clean))
  (if (= n 0)
      (hasheq 'n 0 'mean #f 'median #f 'p25 #f 'p75 #f)
      (hasheq 'n n
              'mean (round1 (/ (for/sum ([v (in-list clean)]) (exact->inexact v)) n))
              'median (round1 (percentile-sorted clean 0.50))
              'p25 (round1 (percentile-sorted clean 0.25))
              'p75 (round1 (percentile-sorted clean 0.75)))))

(define (race-initial r)
  (cond
    [(string-prefix? (string-downcase r) "p") "P"]
    [(string-prefix? (string-downcase r) "t") "T"]
    [(string-prefix? (string-downcase r) "z") "Z"]
    [else "?"]))

;; -----------------------------------------------------------------------------
;; Domain Unit/Structure Classification Sets (General SC2 LotV Physics)
;; -----------------------------------------------------------------------------

(define NON-COMBAT-UNIT-SET
  (set "Drone" "SCV" "Probe" "Larva" "Egg" "Overlord" "MULE" "Broodling"
       "Interceptor" "CreepTumor" "CreepTumorBurrowed" "CreepTumorQueen"
       "BeaconArmy" "MineralField" "VespeneGeyser" "KD8Charge" "ForceField"
       "AutoTurret" "LocustMP" "LocustMPFlying" "AdeptPhaseShift" "DisruptorPhased"
       "ParasiticBombDummy" "InvisibleTargetDummy" "PointDefenseDrone"
       "OverlordCocoon" "TransportOverlordCocoon" "BanelingCocoon" "RavagerCocoon"
       "LurkerMPEgg" "BroodLordCocoon" "CreepTumorMissile"))

(define WORKER-UNIT-SET
  (set "Drone" "SCV" "Probe"))

(define WARPABLE-UNIT-SET
  (set "Zealot" "Stalker" "Adept" "Sentry" "HighTemplar" "DarkTemplar"))

(define TOWNHALL-SET
  (set "Hatchery" "Lair" "Hive" "CommandCenter" "OrbitalCommand" "PlanetaryFortress"
       "CommandCenterFlying" "OrbitalCommandFlying" "Nexus"))

(define GAS-BLDG-SET
  (set "Extractor" "ExtractorRich" "Refinery" "RefineryRich" "Assimilator" "AssimilatorRich"))

(define SUPPLY-BLDG-SET
  (set "Pylon" "SupplyDepot" "SupplyDepotLowered" "Overlord"))

(define PROD1-BLDG-SET
  (set "Gateway" "WarpGate" "Barracks" "SpawningPool"))

(define TECH1-BLDG-SET
  (set "CyberneticsCore" "Factory" "Lair" "RoachWarren" "BanelingNest"))

(define TECH2-BLDG-SET
  (set "RoboticsFacility" "Stargate" "TwilightCouncil"
       "Starport" "StarportFlying"
       "HydraliskDen" "Spire" "LurkerDenMP" "InfestationPit"))

;; W15-LOOP-2: T3 tech structures for flexible T3 timing & premature-starve auditing
(define TECH3-BLDG-SET
  (set "GhostAcademy" "FusionCore"
       "TemplarArchive" "DarkShrine" "FleetBeacon" "RoboticsBay"
       "UltraliskCavern" "GreaterSpire" "Hive"))

(define PROD-FACILITY-SET
  (set "Gateway" "WarpGate" "RoboticsFacility" "Stargate"
       "Barracks" "BarracksFlying" "Factory" "FactoryFlying" "Starport" "StarportFlying"
       "Hatchery" "Lair" "Hive"))

(define PRIMARY-PROD-SET
  (set "Gateway" "WarpGate"
       "Barracks" "BarracksFlying"
       "Hatchery" "Lair" "Hive"))

(define TECH-PROD-SET
  (set "RoboticsFacility" "Stargate" "TwilightCouncil"
       "Factory" "FactoryFlying" "Starport" "StarportFlying"
       "HydraliskDen" "Spire" "GreaterSpire" "RoachWarren" "BanelingNest"))

(define (canon-opening-bldg ut)
  (cond
    [(or (string=? ut "WarpGate") (string=? ut "Gateway")) "Gateway"]
    [(or (string=? ut "SupplyDepotLowered") (string=? ut "SupplyDepot")) "SupplyDepot"]
    [(string=? ut "BarracksFlying") "Barracks"]
    [(string=? ut "FactoryFlying") "Factory"]
    [(string=? ut "StarportFlying") "Starport"]
    [(member ut '("CommandCenter" "CommandCenterFlying" "OrbitalCommand" "OrbitalCommandFlying" "PlanetaryFortress")) "CommandCenter"]
    [(member ut '("Hatchery" "Lair" "Hive")) "Hatchery"]
    [else ut]))

(define SCOUT-IGNORE-SET
  (set "Larva" "Egg" "CreepTumor" "CreepTumorBurrowed" "CreepTumorQueen"
       "Broodling" "Interceptor" "AdeptPhaseShift" "KD8Charge" "ForceField"
       "MULE" "AutoTurret" "LocustMP" "LocustMPFlying"))

;; Zerg combat unit resource value (min + gas) for `zerg_non_ling_army_pct` (W8-LOOP-2)
(define ZERG-COMBAT-COST-HT
  (hash "Zergling" 25
        "Baneling" 75
        "Roach" 100
        "Ravager" 200
        "Hydralisk" 150
        "LurkerMP" 300
        "LurkerMPBurrowed" 300
        "Mutalisk" 200
        "Corruptor" 250
        "Infestor" 250
        "InfestorBurrowed" 250
        "SwarmHostMP" 175
        "SwarmHostBurrowedMP" 175
        "Viper" 300
        "Ultralisk" 475
        "BroodLord" 550))

;; W9-LOOP-2: Long-range siege/capital unit set & core-12 opponent cohort set
(define SIEGE-CAPITAL-UNIT-SET
  (set "Tempest" "SiegeTank" "SiegeTankSieged" "Colossus" "Carrier"
       "BroodLord" "LurkerMP" "LurkerMPBurrowed"))

;; W10-LOOP-2: Cloaked threat unit set & Pro v2 8m army-value reference medians
(define CLOAK-THREAT-UNIT-SET
  (set "Banshee" "DarkTemplar" "LurkerMP" "LurkerMPBurrowed"))

;; W11-LOOP-2: Pro v2 4m army-value reference medians
(define PRO-ARMY-VAL-4M-BY-RACE
  (hash "Protoss" 500.0
        "Terran"  450.0
        "Zerg"    625.0))

(define PRO-ARMY-VAL-8M-BY-RACE
  (hash "Protoss" 3312.5
        "Terran"  2850.0
        "Zerg"    3062.5))

(define CORE-12-OPPONENTS-LC
  (set "titania" "monsterbot" "chance" "puck" "oberon" "rustynikolaj"
       "mini-puck" "sludgement2-revived" "thssprtssbt" "creepy_strategies"
       "smoothbrain" "12poolbot"))

(define (load-core-opponent-set)
  (define roster-p "/home/sjaconette/sc2-local-arena/bots/roster.json")
  (if (file-exists? roster-p)
      (with-handlers ([exn:fail? (lambda (_e) CORE-12-OPPONENTS-LC)])
        (define js (call-with-input-file roster-p read-json))
        (define items (cond [(list? js) js]
                            [(and (hash? js) (list? (hash-ref js 'bots #f))) (hash-ref js 'bots)]
                            [else '()]))
        (define cs
          (for/set ([e (in-list items)]
                    #:when (and (hash? e)
                                (eq? (hash-ref e 'gauntlet_core #f) #t)
                                (string? (hash-ref e 'name #f))))
            (string-downcase (hash-ref e 'name))))
        (if (set-empty? cs) CORE-12-OPPONENTS-LC cs))
      CORE-12-OPPONENTS-LC))

(define ACTIVE-CORE-OPP-SET (load-core-opponent-set))

(define (classify-opp-cohort opp-name)
  (if (and (string? opp-name)
           (set-member? ACTIVE-CORE-OPP-SET (string-downcase (string-trim opp-name))))
      "core_12"
      "unseen_6"))

(define CREEP-TUMOR-SET
  (set "CreepTumor" "CreepTumorBurrowed" "CreepTumorQueen"))

;; Real win-condition structures (SC2 eliminates a player when 0 remain)
(define WIN-BLDG-SET
  (set "Hatchery" "Lair" "Hive" "SpawningPool" "EvolutionChamber" "RoachWarren"
       "BanelingNest" "HydraliskDen" "LurkerDenMP" "Spire" "GreaterSpire"
       "InfestationPit" "UltraliskCavern" "NydusNetwork" "NydusCanal"
       "SpineCrawler" "SpineCrawlerUprooted" "SporeCrawler" "SporeCrawlerUprooted"
       "Extractor" "ExtractorRich"
       "CommandCenter" "CommandCenterFlying" "OrbitalCommand" "OrbitalCommandFlying"
       "PlanetaryFortress" "SupplyDepot" "SupplyDepotLowered" "Refinery" "RefineryRich"
       "Barracks" "BarracksFlying" "BarracksTechLab" "BarracksReactor"
       "Factory" "FactoryFlying" "FactoryTechLab" "FactoryReactor"
       "Starport" "StarportFlying" "StarportTechLab" "StarportReactor"
       "EngineeringBay" "Armory" "GhostAcademy" "FusionCore"
       "Bunker" "MissileTurret" "SensorTower"
       "Nexus" "Pylon" "Assimilator" "AssimilatorRich" "Gateway" "WarpGate"
       "CyberneticsCore" "Forge" "PhotonCannon" "ShieldBattery" "TwilightCouncil"
       "RoboticsFacility" "RoboticsBay" "Stargate" "FleetBeacon"
       "TemplarArchive" "DarkShrine"))

(define COMBAT-AIR-SET
  (set "Tempest" "VoidRay" "Carrier" "Oracle" "Phoenix" "Mothership"
       "Banshee" "Battlecruiser" "Liberator" "LiberatorAG" "VikingFighter"
       "Mutalisk" "BroodLord" "Corruptor"))

(define AA-UNIT-SET
  (set "Corruptor" "Hydralisk" "Mutalisk" "Queen" "SporeCrawler"
       "Marine" "VikingFighter" "Thor" "ThorAP" "Cyclone" "Battlecruiser" "MissileTurret"
       "Stalker" "Phoenix" "VoidRay" "Tempest" "Carrier" "Archon" "Sentry" "PhotonCannon"))

(define AA-TECH-BLDG-SET
  (set "Lair" "Hive" "Spire" "GreaterSpire" "HydraliskDen"
       "Starport" "Armory" "Barracks"
       "CyberneticsCore" "Stargate" "FleetBeacon"))

(define WORKER-SET
  (set "Drone" "SCV" "Probe"))

;; -----------------------------------------------------------------------------
;; Pre-compiled Log Scanning Regexes (zero per-line regex compilation)
;; -----------------------------------------------------------------------------

(define RX-STEP-MS     #px"step_ms=([0-9]+(?:\\.[0-9]+)?)")
(define RX-TR-MS       #px"tr_ms=([0-9]+(?:\\.[0-9]+)?)")
(define RX-FRAME       #px"f=([0-9]+)")
(define RX-PRIO-FULL   #px"f=([0-9]+).*?bank=([0-9]+)M/([0-9]+)G sup=([0-9]+)/([0-9]+).*?saving_for=([a-z0-9-]+)\\(floor=([0-9]+)M/([0-9]+)G\\)")
(define RX-SAVING-FALL #px"saving_for=([a-z0-9-]+)")
(define RX-SCHED-PROD  #px"sched=\\([^)]*\\b(barracks|gateway|factory|starport)@")
(define RX-SCHED-EXP   #px"sched=\\([^)]*\\b(nexus|command-center|hatchery)@")
(define RX-SCHED-SPIRE #px"sched=\\([^)]*\\bspire@")
(define RX-BLOCKED     #px"([a-z0-9-]+)\\(blocked-by-escrow")
(define RX-HEXP        #px"hexp=([0-9]+\\.[0-9]+)")
(define RX-RUSH        #px"rush=([0-9]+\\.[0-9]+)")
(define RX-ERR-KV      #px"([A-Za-z0-9_]+)=([0-9]+)")
(define RX-MATCH-ID    #px"^([0-9]+)_")
(define RX-REPLAY-EXT  #px"\\.SC2Replay$")

;; -----------------------------------------------------------------------------
;; Streaming Log Telemetry & Anomaly Extractor (Single-Pass, Low Allocation)
;; -----------------------------------------------------------------------------

(define (make-log-acc)
  (hasheq 'has-logs? #f
          'prio-total 0
          'state-total 0
          'pos-attack 0
          'pos-hold 0
          'pos-retreat 0
          'retreat-frames '()
          'pos-by-min (make-hasheqv) ; min -> (vector atk hld ret)
          'hexp-high 0
          'rush-high 0
          'saving-counts (make-hash)
          'blocked-counts (make-hash)
          'max-escrow-streak-len 0
          'max-escrow-streak-target "none"
          'cur-streak-len 0
          'cur-streak-target "none"
          ;; Escrow lockout detectors
          'hb-cur-len 0
          'hb-cur-tgt "none"
          'hb-cur-start-f 0
          'hb-cur-peak-m 0
          'hb-windows '() ; list of (hash 'target 'ticks 'start_sec 'end_sec 'peak_min)
          'gs-cur-len 0
          'gs-cur-tgt "none"
          'gs-cur-start-f 0
          'gs-cur-peak-m 0
          'gs-cur-min-g 9999
          'gs-windows '()
          ;; W11-LOOP-2: Gas-rich / mineral-starved stall ticks (gas>=200 & min<100, unmaxed)
          'gas-rich-min-starved-ticks 0
          'gas-rich-min-starved-peak-gas 0
          ;; W13-LOOP-2: Production building placement stall ticks (barracks/gateway/factory/starport scheduled with >=150M)
          'prod-stall-ticks 0
          'prod-stall-cur-streak 0
          'prod-stall-cur-bldg ""
          'prod-stall-max-streak 0
          'prod-stall-max-bldg ""
          'prod-stall-counts (make-hash)
          ;; L19-LOOP-2: Expansion scheduled & Spire scheduled counters (for 1BaseLock & SpireDrop forensics)
          'exp-sched-ticks 0
          'spire-sched-ticks 0
          'step-ms '()
          'tr-ms '()
          'action-err-total 0
          'action-err-counts (make-hash)
          'crashes '()))

(define (flush-hb-window! acc end-f)
  (define len (hash-ref acc 'hb-cur-len 0))
  (when (>= len 5)
    (define win (hasheq 'kind "high_bank_escrow"
                        'target (hash-ref acc 'hb-cur-tgt "none")
                        'ticks len
                        'start_sec (round1 (/ (hash-ref acc 'hb-cur-start-f 0) 22.4))
                        'end_sec (round1 (/ end-f 22.4))
                        'peak_min (hash-ref acc 'hb-cur-peak-m 0)))
    (hash-set! acc 'hb-windows (cons win (hash-ref acc 'hb-windows '()))))
  (hash-set! acc 'hb-cur-len 0)
  (hash-set! acc 'hb-cur-tgt "none")
  (hash-set! acc 'hb-cur-peak-m 0))

(define (flush-gs-window! acc end-f)
  (define len (hash-ref acc 'gs-cur-len 0))
  (when (>= len 5)
    (define win (hasheq 'kind "gas_starved_min_lockout"
                        'target (hash-ref acc 'gs-cur-tgt "none")
                        'ticks len
                        'start_sec (round1 (/ (hash-ref acc 'gs-cur-start-f 0) 22.4))
                        'end_sec (round1 (/ end-f 22.4))
                        'peak_min (hash-ref acc 'gs-cur-peak-m 0)
                        'min_gas (hash-ref acc 'gs-cur-min-g 0)))
    (hash-set! acc 'gs-windows (cons win (hash-ref acc 'gs-windows '()))))
  (hash-set! acc 'gs-cur-len 0)
  (hash-set! acc 'gs-cur-tgt "none")
  (hash-set! acc 'gs-cur-peak-m 0)
  (hash-set! acc 'gs-cur-min-g 9999))

(define (scan-log-port! acc in is-stderr?)
  ;; Mutate a local mutable hash for fast inner loop, then freeze at end.
  (define m (make-hasheq))
  (for ([(k v) (in-hash acc)]) (hash-set! m k v))
  (define saving-ht (hash-ref m 'saving-counts))
  (define blocked-ht (hash-ref m 'blocked-counts))
  (define err-ht (hash-ref m 'action-err-counts))
  (define pos-by-min (hash-ref m 'pos-by-min))
  (define prio-total (hash-ref m 'prio-total))
  (define state-total (hash-ref m 'state-total))
  (define pos-atk (hash-ref m 'pos-attack))
  (define pos-hld (hash-ref m 'pos-hold))
  (define pos-ret (hash-ref m 'pos-retreat))
  (define ret-frames (hash-ref m 'retreat-frames))
  (define hexp-hi (hash-ref m 'hexp-high))
  (define rush-hi (hash-ref m 'rush-high))
  (define step-ms (hash-ref m 'step-ms))
  (define tr-ms (hash-ref m 'tr-ms '()))
  (define err-tot (hash-ref m 'action-err-total))
  (define max-slen (hash-ref m 'max-escrow-streak-len))
  (define max-stgt (hash-ref m 'max-escrow-streak-target))
  (define cur-slen (hash-ref m 'cur-streak-len))
  (define cur-stgt (hash-ref m 'cur-streak-target))
  (define grms-ticks (hash-ref m 'gas-rich-min-starved-ticks 0))
  (define grms-peak-gas (hash-ref m 'gas-rich-min-starved-peak-gas 0))
  (define pstall-ticks (hash-ref m 'prod-stall-ticks 0))
  (define pstall-cur-streak (hash-ref m 'prod-stall-cur-streak 0))
  (define pstall-cur-bldg (hash-ref m 'prod-stall-cur-bldg ""))
  (define pstall-max-streak (hash-ref m 'prod-stall-max-streak 0))
  (define pstall-max-bldg (hash-ref m 'prod-stall-max-bldg ""))
  (define pstall-ht (hash-ref m 'prod-stall-counts))
  (define exp-sched-ticks (hash-ref m 'exp-sched-ticks 0))
  (define spire-sched-ticks (hash-ref m 'spire-sched-ticks 0))
  (define crashes (hash-ref m 'crashes))
  (define last-prio-f 0)

  (for ([ln (in-lines in 'any)])
    (cond
      [(string-prefix? ln "[SCBOT_PRIORITY]")
       (set! prio-total (add1 prio-total))
       (when (string-contains? ln "step_ms=")
         (define mm (regexp-match RX-STEP-MS ln))
         (when mm
           (define v (string->number (cadr mm)))
           (when v (set! step-ms (cons v step-ms)))))
       (when (string-contains? ln "tr_ms=")
         (define mt (regexp-match RX-TR-MS ln))
         (when mt
           (define v (string->number (cadr mt)))
           (when v (set! tr-ms (cons v tr-ms)))))
       (define mp (regexp-match RX-PRIO-FULL ln))
       (define-values (fr bmin bgas su tgt fmin fgas)
         (if mp
             (values (or (string->number (list-ref mp 1)) 0)
                     (or (string->number (list-ref mp 2)) 0)
                     (or (string->number (list-ref mp 3)) 0)
                     (or (string->number (list-ref mp 4)) 0)
                     (list-ref mp 6)
                     (or (string->number (list-ref mp 7)) 0)
                     (or (string->number (list-ref mp 8)) 0))
             (let ([mf (regexp-match RX-FRAME ln)]
                   [ms2 (regexp-match RX-SAVING-FALL ln)])
               (values (if mf (or (string->number (cadr mf)) 0) 0)
                       0 0 0 (if ms2 (cadr ms2) "none") 0 0))))
       (set! last-prio-f fr)
       (hash-update! saving-ht tgt add1 0)
       ;; Escrow streak tracking
       (cond
         [(string=? tgt "none")
          (set! cur-stgt "none")
          (set! cur-slen 0)]
         [(string=? tgt cur-stgt)
          (set! cur-slen (add1 cur-slen))
          (when (> cur-slen max-slen)
            (set! max-slen cur-slen)
            (set! max-stgt tgt))]
         [else
          (set! cur-stgt tgt)
          (set! cur-slen 1)
          (when (> cur-slen max-slen)
            (set! max-slen cur-slen)
            (set! max-stgt tgt))])
       ;; High-bank mineral escrow lockout detector (bank >= 300M, saving != none, not maxed)
       (if (and (not (string=? tgt "none"))
                (>= bmin 300)
                (< su 194)
                (> fr 672))
           (begin
             (when (= (hash-ref m 'hb-cur-len 0) 0)
               (hash-set! m 'hb-cur-start-f fr)
               (hash-set! m 'hb-cur-tgt tgt)
               (hash-set! m 'hb-cur-peak-m bmin))
             (hash-set! m 'hb-cur-len (add1 (hash-ref m 'hb-cur-len 0)))
             (when (> bmin (hash-ref m 'hb-cur-peak-m 0))
               (hash-set! m 'hb-cur-peak-m bmin)))
           (flush-hb-window! m fr))
       ;; Gas-starved mineral lockout detector (bank >= 180M, gas < 60G, gas floor >= 100G)
       (if (and (not (string=? tgt "none"))
                (>= bmin 180)
                (< bgas 60)
                (>= fgas 100)
                (>= fmin 100)
                (< su 194))
           (begin
             (when (= (hash-ref m 'gs-cur-len 0) 0)
               (hash-set! m 'gs-cur-start-f fr)
               (hash-set! m 'gs-cur-tgt tgt)
               (hash-set! m 'gs-cur-peak-m bmin)
               (hash-set! m 'gs-cur-min-g bgas))
             (hash-set! m 'gs-cur-len (add1 (hash-ref m 'gs-cur-len 0)))
             (when (> bmin (hash-ref m 'gs-cur-peak-m 0))
               (hash-set! m 'gs-cur-peak-m bmin))
             (when (< bgas (hash-ref m 'gs-cur-min-g 9999))
               (hash-set! m 'gs-cur-min-g bgas)))
           (flush-gs-window! m fr))
       ;; W11-LOOP-2: Gas-rich / mineral-starved production stall ticks (vespene >= 200 & minerals < 100)
       (when (and mp (>= bgas 200) (< bmin 100) (< su 194))
         (set! grms-ticks (add1 grms-ticks))
         (when (> bgas grms-peak-gas)
           (set! grms-peak-gas bgas)))
       ;; W13-LOOP-2: Production building placement stall ticks (barracks/gateway/factory/starport scheduled with >=150M)
       (define pstall-m
         (and mp (>= bmin 150) (< su 194)
              (string-contains? ln "sched=(")
              (regexp-match RX-SCHED-PROD ln)))
       (cond
         [pstall-m
          (define pb (cadr pstall-m))
          (set! pstall-ticks (add1 pstall-ticks))
          (hash-update! pstall-ht pb add1 0)
          (if (string=? pb pstall-cur-bldg)
              (set! pstall-cur-streak (add1 pstall-cur-streak))
              (begin (set! pstall-cur-bldg pb)
                     (set! pstall-cur-streak 1)))
          (when (> pstall-cur-streak pstall-max-streak)
            (set! pstall-max-streak pstall-cur-streak)
            (set! pstall-max-bldg pb))]
         [else
          (set! pstall-cur-bldg "")
          (set! pstall-cur-streak 0)])
       ;; L19-LOOP-2: Track Brain-scheduled expansion ticks (>=300M) & Spire ticks (>=200M/200G)
       (when (and mp (< su 194) (string-contains? ln "sched=("))
         (when (and (>= bmin 300) (regexp-match? RX-SCHED-EXP ln))
           (set! exp-sched-ticks (add1 exp-sched-ticks)))
         (when (and (>= bmin 200) (>= bgas 200) (regexp-match? RX-SCHED-SPIRE ln))
           (set! spire-sched-ticks (add1 spire-sched-ticks))))
       ;; Blocked-by-escrow counts
       (when (string-contains? ln "blocked-by-escrow")
         (for ([bm (in-list (regexp-match* RX-BLOCKED ln #:match-select cadr))])
           (hash-update! blocked-ht bm add1 0)))]
      [(string-prefix? ln "[SCBOT_STATE]")
       (set! state-total (add1 state-total))
       (when (string-contains? ln "step_ms=")
         (define mm (regexp-match RX-STEP-MS ln))
         (when mm
           (define v (string->number (cadr mm)))
           (when v (set! step-ms (cons v step-ms)))))
       (when (string-contains? ln "tr_ms=")
         (define mt (regexp-match RX-TR-MS ln))
         (when mt
           (define v (string->number (cadr mt)))
           (when v (set! tr-ms (cons v tr-ms)))))
       (define mf (regexp-match RX-FRAME ln))
       (define st-fr (if mf (or (string->number (cadr mf)) 0) 0))
       (define minute (quotient st-fr 1344))
       (define pvec (hash-ref! pos-by-min minute (lambda () (vector 0 0 0))))
       (cond
         [(string-contains? ln "pos=attack")
          (set! pos-atk (add1 pos-atk))
          (vector-set! pvec 0 (add1 (vector-ref pvec 0)))]
         [(string-contains? ln "pos=retreat")
          (set! pos-ret (add1 pos-ret))
          (set! ret-frames (cons st-fr ret-frames))
          (vector-set! pvec 2 (add1 (vector-ref pvec 2)))]
         [(string-contains? ln "pos=hold")
          (set! pos-hld (add1 pos-hld))
          (vector-set! pvec 1 (add1 (vector-ref pvec 1)))])
       (when (string-contains? ln "hexp=")
         (define mh (regexp-match RX-HEXP ln))
         (when (and mh (>= (or (string->number (cadr mh)) 0.0) 0.70))
           (set! hexp-hi (add1 hexp-hi))))
       (when (string-contains? ln "rush=")
         (define mr (regexp-match RX-RUSH ln))
         (when (and mr (>= (or (string->number (cadr mr)) 0.0) 0.50))
           (set! rush-hi (add1 rush-hi))))]
      [(string-prefix? ln "[SCBOT_ACTION_ERR]")
       (for ([pair-m (in-list (regexp-match* RX-ERR-KV ln #:match-select values))])
         (define k (cadr pair-m))
         (define c (or (string->number (caddr pair-m)) 0))
         (unless (or (string=? k "f") (string=? k "total") (string=? k "loop") (= c 0))
           (hash-update! err-ht k (lambda (old) (+ old c)) 0)
           (set! err-tot (+ err-tot c))))]
      [(and is-stderr?
            (< (length crashes) 5)
            (not (string-prefix? ln "[SCBOT_"))
            (not (string-prefix? ln "{"))
            (not (string-prefix? ln "Tag:"))
            (let ([low (string-downcase ln)])
              (or (string-contains? low "error")
                  (string-contains? low "exception")
                  (string-contains? low "contract")
                  (string-contains? low "crash")
                  (string-contains? low "context..."))))
       (set! crashes (cons ln crashes))]))

  (flush-hb-window! m last-prio-f)
  (flush-gs-window! m last-prio-f)
  (hash-set* acc
             'has-logs? #t
             'prio-total prio-total
             'state-total state-total
             'pos-attack pos-atk
             'pos-hold pos-hld
             'pos-retreat pos-ret
             'retreat-frames ret-frames
             'hexp-high hexp-hi
             'rush-high rush-hi
             'step-ms step-ms
             'tr-ms tr-ms
             'action-err-total err-tot
             'max-escrow-streak-len max-slen
             'max-escrow-streak-target max-stgt
             'cur-streak-len cur-slen
             'cur-streak-target cur-stgt
             'hb-windows (reverse (hash-ref m 'hb-windows '()))
             'gs-windows (reverse (hash-ref m 'gs-windows '()))
             'gas-rich-min-starved-ticks grms-ticks
             'gas-rich-min-starved-peak-gas grms-peak-gas
             'prod-stall-ticks pstall-ticks
             'prod-stall-cur-streak pstall-cur-streak
             'prod-stall-cur-bldg pstall-cur-bldg
             'prod-stall-max-streak pstall-max-streak
             'prod-stall-max-bldg pstall-max-bldg
             'exp-sched-ticks exp-sched-ticks
             'spire-sched-ticks spire-sched-ticks
             'crashes crashes))

(define (scan-log-zip! acc zpath)
  (with-handlers ([exn:fail? (lambda (_e) acc)])
    (define cur acc)
    (unzip zpath
           (lambda (raw-name dir? in)
             (unless dir?
               (define nm (string-downcase (path->string (file-name-from-path (bytes->path raw-name)))))
               (when (or (string-contains? nm "stdout")
                         (string-contains? nm "stderr")
                         (string-suffix? nm ".log")
                         (string-suffix? nm ".txt"))
                 (set! cur (scan-log-port! cur in (string-contains? nm "stderr")))))))
    cur))

(define (scan-plain-log-file! acc fpath [force-stderr? #f])
  (with-handlers ([exn:fail? (lambda (_e) acc)])
    (define nm (string-downcase (path->string (file-name-from-path fpath))))
    (call-with-input-file fpath
      (lambda (in)
        (scan-log-port! acc in (or force-stderr?
                                   (string-contains? nm "stderr")
                                   (string-contains? nm "mothman"))))
      #:mode 'text)))

;; -----------------------------------------------------------------------------
;; Match & Log Discovery (AI Arena flat caches AND local parallel runner layouts)
;; -----------------------------------------------------------------------------

(define (extract-match-id-from-name bn)
  (define m (regexp-match RX-MATCH-ID bn))
  (and m (string->number (cadr m))))

(define (load-summary-meta-map root-dir)
  (define tbl (make-hash))
  (for ([p (in-list (find-files file-exists? root-dir))])
    (define bn (path->string (file-name-from-path p)))
    (cond
      [(string-suffix? bn "_meta.json")
       (define mid (extract-match-id-from-name bn))
       (when mid
         (with-handlers ([exn:fail? void])
           (define js (call-with-input-file p read-json))
           (when (hash? js) (hash-set! tbl mid js))))]
      [(or (string-contains? bn "summary.json") (string=? bn "results.json"))
       (with-handlers ([exn:fail? void])
         (define js (call-with-input-file p read-json))
         (define run-timeout-sec
           (and (hash? js)
                (let ([tv (hash-ref js 'timeout_sec #f)])
                  (and (real? tv) tv))))
         (define ms (cond [(and (hash? js) (list? (hash-ref js 'matches #f))) (hash-ref js 'matches)]
                          [(list? js) js]
                          [else '()]))
         (for ([m0 (in-list ms)] #:when (hash? m0))
           (define m (if run-timeout-sec (hash-set m0 'run_timeout_sec run-timeout-sec) m0))
           (define mid (or (hash-ref m 'match_id #f) (hash-ref m 'id #f) (hash-ref m 'index #f)))
           (when mid (hash-set! tbl mid m))
           (define slg (hash-ref m 'slug #f))
           (when (and (string? slg) (not (string=? slg "")))
             (hash-set! tbl slg m))
           (define rfn (hash-ref m 'replay_path #f))
           (when (and (string? rfn) (not (string=? rfn "")))
             (hash-set! tbl (path->string (file-name-from-path (string->path rfn))) m))))]))
  tbl)

(define (find-associated-logs replay-path meta bot-prefix)
  (define dir (path-only replay-path))
  (define bn (path->string (file-name-from-path replay-path)))
  (define stem (regexp-replace RX-REPLAY-EXT bn ""))
  (define mid (extract-match-id-from-name bn))
  (define bp-low (string-downcase bot-prefix))
  (define zips '())
  (define plains '())
  ;; 1. Explicit `our_log_path` from local runner `summary.json`
  (define meta-our-log (and (hash? meta) (hash-ref meta 'our_log_path #f)))
  (when (and (string? meta-our-log) (not (string=? meta-our-log "")) (file-exists? meta-our-log))
    (set! plains (cons (string->path meta-our-log) plains)))
  ;; 2. Same directory (AI Arena flat caches or per-match subdir)
  (when (and (null? plains) dir (directory-exists? dir))
    (define entries (directory-list dir #:build? #t))
    (define single-replay-dir?
      (= (count (lambda (q) (string-suffix? (path->string q) ".SC2Replay")) entries) 1))
    (for ([p (in-list entries)] #:when (file-exists? p))
      (define fbn (path->string (file-name-from-path p)))
      (define low (string-downcase fbn))
      (define match-by-id? (and mid (string-prefix? fbn (format "~a_" mid))))
      (define match-by-stem? (string-prefix? fbn stem))
      (define tail-low
        (if (and match-by-stem? (> (string-length fbn) (add1 (string-length stem))))
            (string-downcase (substring fbn (add1 (string-length stem))))
            low))
      (define is-controller-or-opp?
        (or (string-contains? low "_controller.log")
            (and match-by-stem?
                 (string-suffix? tail-low ".log")
                 (not (string-contains? tail-low bp-low))
                 (not (string-contains? tail-low "stdout"))
                 (not (string-contains? tail-low "stderr")))))
      (define match-in-own-dir?
        (and single-replay-dir?
             (or (string-contains? tail-low bp-low)
                 (string-contains? low "stdout")
                 (string-contains? low "stderr"))))
      (cond
        [(and (string-suffix? low ".zip")
              (or match-by-id? match-by-stem? single-replay-dir?)
              (string-contains? low "log"))
         (set! zips (cons p zips))]
        [(and (not is-controller-or-opp?)
              (or (string-suffix? low ".log")
                  (string-suffix? low ".stdout")
                  (string-suffix? low ".stderr")
                  (string-contains? low "stdout")
                  (string-contains? low "stderr"))
              (not (string-suffix? low ".sc2replay"))
              (not (string-suffix? low ".json"))
              (or match-by-id? match-by-stem? match-in-own-dir?))
         (set! plains (cons p plains))])))
  ;; 3. Sibling `../logs/<stem>_*<bot-prefix>*.log` (used by `tools/run-local-sc2-arena.py`)
  (define parent-dir (and dir (simplify-path (build-path dir 'up))))
  (define sibling-logs (and parent-dir (build-path parent-dir "logs")))
  (define stem-pfx (string-append stem "_"))
  (when (and (null? plains) (null? zips) sibling-logs (directory-exists? sibling-logs))
    (for ([p (in-list (directory-list sibling-logs #:build? #t))] #:when (file-exists? p))
      (define fbn (path->string (file-name-from-path p)))
      (when (string-prefix? fbn stem-pfx)
        (define tail-low (string-downcase (substring fbn (string-length stem-pfx))))
        (when (and (not (string-contains? tail-low "controller"))
                   (or (string-contains? tail-low bp-low)
                       (string-contains? tail-low "stderr")
                       (string-contains? tail-low "stdout")))
          (if (string-suffix? tail-low ".zip")
              (set! zips (cons p zips))
              (set! plains (cons p plains)))))))
  (values (remove-duplicates zips equal?) (remove-duplicates plains equal?)))

;; -----------------------------------------------------------------------------
;; True Single-Pass MPQ + Tracker Forensic Extractor
;; -----------------------------------------------------------------------------

(define (decode-race-str s)
  (cond
    [(or (string-contains? s "Terr") (string=? s "T")) "Terran"]
    [(or (string-contains? s "Prot") (string=? s "P")) "Protoss"]
    [(or (string-contains? s "Zerg") (string=? s "Z")) "Zerg"]
    [(or (string-contains? s "Rand") (string=? s "R")) "Random"]
    [else s]))

(define (decode-result-sym v)
  (cond
    [(equal? v 1) "Win"]
    [(equal? v 2) "Loss"]
    [else "Unknown"]))

(define (stat-near-sec sbm-pid target-sec)
  (define best #f)
  (define best-d 1e9)
  (for ([(_m h) (in-hash sbm-pid)])
    (define s (safe-num (hash-ref h 'sec 0.0) 0.0))
    (define d (abs (- s target-sec)))
    (when (and (<= d 40.0) (< d best-d))
      (set! best h)
      (set! best-d d)))
  best)

(define (last-stat sbm-pid)
  (if (hash-empty? sbm-pid)
      #f
      (hash-ref sbm-pid (apply max (hash-keys sbm-pid)) #f)))

(define (peak-stat sbm-pid fn)
  (for/fold ([mx 0]) ([(_m h) (in-hash sbm-pid)])
    (max mx (fn h))))

(define (avg-stat sbm-pid fn)
  (define n (hash-count sbm-pid))
  (if (= n 0)
      0.0
      (/ (for/sum ([(_m h) (in-hash sbm-pid)]) (exact->inexact (fn h))) n)))

(define (parse-and-score-single-pass replay-path meta bot-prefix)
  (define bn (path->string (file-name-from-path replay-path)))
  (with-handlers ([exn:fail? (lambda (e) (hasheq 'file bn 'error (exn-message e)))])
    ;; Single MPQ read + single tracker decode!
    (define mpq (read-mpq-files replay-path #:filenames '("replay.details" "replay.tracker.events")))
    (unless (and mpq
                 (hash-has-key? mpq "replay.details")
                 (hash-has-key? mpq "replay.tracker.events"))
      (error 'score-replay "Missing replay.details or replay.tracker.events"))
    (define user-data (hash-ref mpq "_user_data" #""))
    (define header-loops
      (if (> (bytes-length user-data) 0)
          (with-handlers ([exn:fail? (lambda (_e) 0)])
            (define-values (hdr _pos) (decode-versioned user-data 0))
            (define ver (if (hash? hdr) (hash-ref hdr 1 (hasheqv)) (hasheqv)))
            (if (hash? ver) (hash-ref ver 3 0) 0))
          0))
    (define-values (details _dpos) (decode-versioned (hash-ref mpq "replay.details") 0))
    (define plist (if (hash? details) (hash-ref details 0 '()) '()))
    (define map-name (if (hash? details) (b->s (hash-ref details 1 #"Unknown Map")) "Unknown Map"))
    (define tracker-events (decode-tracker-stream (hash-ref mpq "replay.tracker.events")))

    ;; Pass 0 (prefix gl == 0): resolve slot -> pid & Frame-0 rolled race
    (define slot->pid (make-hasheqv))
    (define f0-rolled-race (make-hasheqv))
    (for ([ev (in-list tracker-events)] #:break (> (car ev) 0))
      (define ev-id (cadr ev))
      (define pl (caddr ev))
      (when (hash? pl)
        (cond
          [(= ev-id 9)
           (define pid (hash-ref pl 0 0))
           (define ptype (hash-ref pl 1 0))
           (define slot (hash-ref pl 3 #f))
           (when (and (memv ptype '(1 2)) (exact-integer? slot) (< slot (length plist)))
             (hash-set! slot->pid slot pid))]
          [(= ev-id 1)
           (define cp (hash-ref pl 3 0))
           (when (memv cp '(1 2))
             (define ut (b->s (hash-ref pl 2 #"")))
             (cond
               [(or (string=? ut "Hatchery") (string=? ut "Drone")) (hash-set! f0-rolled-race cp "Zerg")]
               [(or (string=? ut "CommandCenter") (string=? ut "SCV")) (hash-set! f0-rolled-race cp "Terran")]
               [(or (string=? ut "Nexus") (string=? ut "Probe")) (hash-set! f0-rolled-race cp "Protoss")]))])))

    ;; Build player metadata table
    (define players (make-hasheqv))
    (for ([p (in-list plist)] [slot (in-naturals)])
      (when (hash? p)
        (define pid (hash-ref slot->pid slot (add1 slot)))
        (when (memv pid '(1 2))
          (define pname (b->s (hash-ref p 0 #"Unknown")))
          (define decl-race (decode-race-str (b->s (hash-ref p 2 #"Unknown"))))
          (define act-race (hash-ref f0-rolled-race pid decl-race))
          (define res (decode-result-sym (hash-ref p 8 0)))
          (hash-set! players pid (hasheq 'pid pid 'name pname 'declared_race decl-race
                                         'actual_race act-race 'result res)))))

    (define p1 (hash-ref players 1 (hasheq)))
    (define p2 (hash-ref players 2 (hasheq)))
    (define n1 (format "~a" (hash-ref p1 'name "")))
    (define n2 (format "~a" (hash-ref p2 'name "")))
    (define bp-low (string-downcase bot-prefix))
    (define m1? (string-contains? (string-downcase n1) bp-low))
    (define m2? (string-contains? (string-downcase n2) bp-low))
    (define our-pid
      (cond
        [(and m1? (not m2?)) 1]
        [(and m2? (not m1?)) 2]
        [(and m1? m2?) 'mirror]
        [else 1]))
    (if (eq? our-pid 'mirror)
        (hasheq 'file bn 'skip 'mirror)
        (let ()
          (define opp-pid (if (= our-pid 1) 2 1))
          (define our-p (hash-ref players our-pid (hasheq)))
          (define opp-p (hash-ref players opp-pid (hasheq)))
          (define our-bot (format "~a" (or (hash-ref meta 'bot1 #f)
                                           (hash-ref meta 'bot #f)
                                           (hash-ref meta 'our_bot_name #f)
                                           (hash-ref our-p 'name "Mothman"))))
          (define opp-bot (format "~a" (or (hash-ref meta 'bot2 #f)
                                           (hash-ref meta 'opp #f)
                                           (hash-ref meta 'opp_bot_name #f)
                                           (hash-ref opp-p 'name "Opponent"))))
          (define our-race (format "~a" (hash-ref our-p 'actual_race "?")))
          (define opp-race (format "~a" (hash-ref opp-p 'actual_race "?")))
          (define matchup (format "~av~a" (race-initial our-race) (race-initial opp-race)))

          ;; Single pass over all tracker events
          (define stats-by-min (hasheqv 1 (make-hasheqv) 2 (make-hasheqv)))
          (define total-stat-ev (make-hasheqv '((1 . 0) (2 . 0))))
          (define sb-steps (make-hasheqv '((1 . 0) (2 . 0))))
          (define upg-cnt (make-hasheqv '((1 . 0) (2 . 0))))
          (define th-timings (make-hasheqv '((1 . ()) (2 . ()))))
          (define gas-timings (make-hasheqv '((1 . ()) (2 . ()))))
          (define sup-timings (make-hasheqv '((1 . ()) (2 . ()))))
          (define prod1-sec (make-hasheqv))
          (define prod-bldg-timings (make-hasheqv '((1 . ()) (2 . ()))))
          (define tech1-sec (make-hasheqv))
          (define tech2-sec (make-hasheqv))
          (define t3-first-sec #f)
          (define t3-first-bldg #f)
          (define t3-bases-at-start #f)
          (define orbital1-sec (make-hasheqv))
          (define lair-sec (make-hasheqv))
          (define aa-tech-first-sec (make-hasheqv))
          ;; W15-LOOP-2: Frame-0 neutral mineral bounds for map_symmetry_kind inference
          (define min-x0 +inf.0) (define max-x0 -inf.0)
          (define min-y0 +inf.0) (define max-y0 -inf.0)
          ;; Pro-benchmarking trackers: opening BO, production lifecycles, upgrades, early scout
          (define opening-bo-rev '())
          (define opening-bldg5-rev '())
          (define opening-ol-cnt 0)
          (define prod-lifespans (make-hasheqv)) ; our tag -> (vector ut start-sec died-sec)
          (define upg-timings (make-hasheq))     ; sym -> first-completion sec
          (define idx->owner-type (make-hasheqv)) ; tracker unitTagIndex -> (cons pid ut)
          (define our-main-xy #f)
          (define opp-main-xy #f)
          (define base-dist #f)
          (define first-scout-cross-sec #f)
          (define first-scout-unit-type #f)
          (define our-units-ht (make-hash))
          (define opp-units-ht (make-hash))
          (define our-bldgs-ht (make-hash))
          (define our-deaths-by-min (make-hasheqv))
          (define opp-deaths-by-min (make-hasheqv))
          ;; Live entity tracking for surviving-at-end & self-cancel detection
          (define unit-owner (make-hasheqv))
          (define unit-type (make-hasheqv))
          (define unit-xy (make-hasheqv))
          (define unit-init-sec (make-hasheqv))
          (define unit-done (make-hasheqv))
          (define alive-opp (make-hasheqv))
          ;; Self-cancel buckets: (list type bx by) -> (list count t-first t-last sample-x sample-y)
          (define self-cancel-buckets (make-hash))
          ;; Air vs AA tracking
          (define opp-air-cnt 0)
          (define opp-air-first-sec #f)
          (define opp-air-types (make-hash))
          (define our-aa-unit-cnt 0)
          (define opp-cloak-killed-cnt 0)
          ;; W7-LOOP-2: Endgame home-stall (>=40 army sup sitting <=45t of home while opp <20)
          ;; and own-base-under-attack buckets (for exact own_base_retreat_frames)
          (define our-th-coords '())
          (define idx->combat-pid (make-hasheqv)) ; tracker unitTagIndex -> pid (combat units only)
          (define own-base-attack-buckets (make-hasheqv)) ; (quotient gl 224) -> #t (<= 28t)
          (define own-terr-attack-buckets (make-hasheqv)) ; (quotient gl 224) -> #t (<= 38t, W12-LOOP-2)
          ;; W12-LOOP-2: Pre-3:30 early-rush idle-bank tracking (minerals >= 250 while army_sup <= 4)
          (define early-rush-idle-bank-ticks 0)
          (define early-rush-idle-bank-post100-ticks 0)
          (define early-rush-idle-bank-peak-min 0)
          ;; W16-LOOP-2: Production idle-bank freeze (>=600M, sup_left>=10, <190 sup, 0 units trained >=45s)
          (define our-prod-alive-tags (make-hasheqv))
          (define last-our-unit-train-sec 0.0)
          (define idle-bank-freeze-start-sec #f)
          (define idle-bank-freeze-cur-peak 0)
          (define prod-idle-bank-freeze-max-sec 0.0)
          (define prod-idle-bank-freeze-start #f)
          (define prod-idle-bank-freeze-end #f)
          (define prod-idle-bank-freeze-peak-min 0)
          (define (mark-our-unit-trained! s)
            (set! last-our-unit-train-sec s)
            (set! idle-bank-freeze-start-sec #f)
            (set! idle-bank-freeze-cur-peak 0))
          ;; W17-LOOP-2: Gas zero-harvest freeze (>=90s w/ gas<50, >=1 ready gas bldg, workers>=20, <16 gas mined)
          (define our-ready-gas-tags (make-hasheqv))
          (define prev-our-gas 0)
          (define gas-zero-cur-start #f)
          (define gas-zero-cur-mined 0.0)
          (define gas-zero-freeze-max-sec 0.0)
          (define gas-zero-freeze-start #f)
          (define gas-zero-freeze-end #f)
          (define gas-zero-freeze-ready-gas 0)
          (define gas-zero-freeze-mined 0.0)
          (define last-opp-asup 0)
          (define prev-our-stat-sec 0.0)
          (define prev-our-killed 0)
          (define last-away-combat-sec -999.0)
          (define home-stall-streak-sec 0.0)
          (define max-home-stall-sec 0.0)
          ;; W8-LOOP-2: Zerg non-Ling combat value tracking at 6m-10m
          (define our-zerg? (string=? our-race "Zerg"))
          (define zerg-combat-spans '()) ; list of (vector cost is-ling? start-sec died-sec)
          (define zerg-combat-live (make-hasheqv)) ; tag -> current vector
          (define (min-dist2-to-our-th px py)
            (for/fold ([best +inf.0]) ([tc (in-list our-th-coords)])
              (define dx (- px (car tc)))
              (define dy (- py (cdr tc)))
              (define d2 (+ (* dx dx) (* dy dy)))
              (if (< d2 best) d2 best)))
          (define max-tracker-loop 0)

          (for ([ev (in-list tracker-events)])
            (define gl (car ev))
            (define eid (cadr ev))
            (define pl (caddr ev))
            (when (> gl max-tracker-loop) (set! max-tracker-loop gl))
            (when (hash? pl)
              (define sec (/ gl 22.4))
              (case eid
                [(0) ; SPlayerStatsEvent
                 (define p (hash-ref pl 0 0))
                 (define st (hash-ref pl 1 #f))
                 (when (and (memv p '(1 2)) (hash? st))
                   (define fu (quotient (hash-ref st 29 0) 4096))
                   (define fm (quotient (hash-ref st 30 0) 4096))
                   (define w-cur (hash-ref st 4 0))
                   (define k-min (+ (hash-ref st 23 0) (hash-ref st 24 0) (hash-ref st 25 0)))
                   (define k-gas (+ (hash-ref st 26 0) (hash-ref st 27 0) (hash-ref st 28 0)))
                   (define cur-asup (max 0 (- fu w-cur)))
                   (cond
                     [(= p opp-pid)
                      (set! last-opp-asup cur-asup)]
                     [(= p our-pid)
                      (define kval (+ k-min k-gas))
                      (define dt (max 0.0 (- sec prev-our-stat-sec)))
                      (when (>= (- kval prev-our-killed) 150)
                        (set! last-away-combat-sec sec))
                      (define away-active? (<= (- sec last-away-combat-sec) 25.0))
                      (if (and (>= cur-asup 40)
                               (< last-opp-asup 20)
                               (not away-active?)
                               (> prev-our-stat-sec 0.0))
                          (begin
                            (set! home-stall-streak-sec (+ home-stall-streak-sec dt))
                            (when (> home-stall-streak-sec max-home-stall-sec)
                              (set! max-home-stall-sec home-stall-streak-sec)))
                          (set! home-stall-streak-sec 0.0))
                      ;; W16-LOOP-2: Track idle-bank production freeze (>=600M, sup_left>=10, <190 sup, 0 units trained >=45s)
                      (define mc-now (hash-ref st 0 0))
                      (if (and (> gl 0)
                               (>= mc-now 600)
                               (< fu 190)
                               (>= (- fm fu) 10)
                               (> (hash-count our-prod-alive-tags) 0)
                               (not (and (>= cur-asup 60) (<= last-opp-asup 10))))
                          (let ()
                            (unless idle-bank-freeze-start-sec
                              (set! idle-bank-freeze-start-sec (max last-our-unit-train-sec prev-our-stat-sec)))
                            (define cur-f-dur (max 0.0 (- sec idle-bank-freeze-start-sec)))
                            (when (> mc-now idle-bank-freeze-cur-peak)
                              (set! idle-bank-freeze-cur-peak mc-now))
                            (when (> cur-f-dur prod-idle-bank-freeze-max-sec)
                              (set! prod-idle-bank-freeze-max-sec cur-f-dur)
                              (set! prod-idle-bank-freeze-start (round1 idle-bank-freeze-start-sec))
                              (set! prod-idle-bank-freeze-end (round1 sec))
                              (set! prod-idle-bank-freeze-peak-min idle-bank-freeze-cur-peak)))
                          (begin
                            (set! idle-bank-freeze-start-sec #f)
                            (set! idle-bank-freeze-cur-peak 0)))
                      ;; W17-LOOP-2: Gas zero-harvest freeze (>=90s w/ gas<50, >=1 ready gas bldg, workers>=20, <16 gas mined)
                      (define gc-now (hash-ref st 1 0))
                      (define grate-now (hash-ref st 3 0))
                      (define r-gas-cnt (hash-count our-ready-gas-tags))
                      (if (and (> gl 0)
                               (< gc-now 50)
                               (>= r-gas-cnt 1)
                               (>= w-cur 20)
                               (<= grate-now 15))
                          (let ()
                            (unless gas-zero-cur-start
                              (set! gas-zero-cur-start prev-our-stat-sec)
                              (set! gas-zero-cur-mined 0.0))
                            (define dm (max (exact->inexact (max 0 (- gc-now prev-our-gas)))
                                            (* (/ grate-now 60.0) dt)))
                            (set! gas-zero-cur-mined (+ gas-zero-cur-mined dm))
                            (if (< gas-zero-cur-mined 16.0)
                                (let ([gdur (max 0.0 (- sec gas-zero-cur-start))])
                                  (when (> gdur gas-zero-freeze-max-sec)
                                    (set! gas-zero-freeze-max-sec gdur)
                                    (set! gas-zero-freeze-start (round1 gas-zero-cur-start))
                                    (set! gas-zero-freeze-end (round1 sec))
                                    (set! gas-zero-freeze-ready-gas r-gas-cnt)
                                    (set! gas-zero-freeze-mined (round1 gas-zero-cur-mined))))
                                (begin
                                  (set! gas-zero-cur-start #f)
                                  (set! gas-zero-cur-mined 0.0))))
                          (begin
                            (set! gas-zero-cur-start #f)
                            (set! gas-zero-cur-mined 0.0)))
                      (set! prev-our-gas gc-now)
                      (set! prev-our-stat-sec sec)
                      (set! prev-our-killed kval)
                      ;; W12-LOOP-2: Track pre-3:30 idle bank (min_cur >= 250 while army_sup <= 4)
                      (when (and (<= gl 4704) (>= (hash-ref st 0 0) 250) (<= cur-asup 4))
                        (define mc0 (hash-ref st 0 0))
                        (set! early-rush-idle-bank-ticks (add1 early-rush-idle-bank-ticks))
                        (when (>= sec 100.0)
                          (set! early-rush-idle-bank-post100-ticks (add1 early-rush-idle-bank-post100-ticks)))
                        (when (> mc0 early-rush-idle-bank-peak-min)
                          (set! early-rush-idle-bank-peak-min mc0)))])
                   ;; W16-LOOP-2: Exclude post-death `food_made == 0` (`sup=0/0`) ticks from supply_block_pct
                   (when (> fm 0)
                     (hash-update! total-stat-ev p add1 0)
                     (when (and (>= fu fm) (< fm 200) (> gl 224))
                       (hash-update! sb-steps p add1 0)))
                   (define minute (exact-floor (/ sec 60.0)))
                   (hash-set! (hash-ref stats-by-min p)
                              minute
                              (hasheq 'sec (round1 sec)
                                      'loop gl
                                      'min_cur (hash-ref st 0 0)
                                      'gas_cur (hash-ref st 1 0)
                                      'workers w-cur
                                      'food_used fu
                                      'food_made fm
                                      'army_min (hash-ref st 11 0)
                                      'army_gas (hash-ref st 14 0)
                                      'killed_min k-min
                                      'killed_gas k-gas)))]
                [(1 6) ; SUnitBornEvent (1) or SUnitInitEvent (6)
                 (define u-idx (hash-ref pl 0 0))
                 (define tag (bitwise-ior (arithmetic-shift u-idx 18)
                                          (hash-ref pl 1 0)))
                 (define p (hash-ref pl 3 0))
                 (define ut (b->s (hash-ref pl 2 #"")))
                 (define ux (hash-ref pl 5 0))
                 (define uy (hash-ref pl 6 0))
                 (hash-set! unit-owner tag p)
                 (hash-set! unit-type tag ut)
                 (hash-set! unit-xy tag (cons ux uy))
                 (when (and (= p our-pid) (not first-scout-cross-sec) (<= sec 360.0))
                   (hash-set! idx->owner-type u-idx ut))
                 (when (and (memv p '(1 2))
                            (or (= eid 1) (set-member? WARPABLE-UNIT-SET ut))
                            (not (set-member? NON-COMBAT-UNIT-SET ut))
                            (not (set-member? SCOUT-IGNORE-SET ut))
                            (not (set-member? WIN-BLDG-SET ut))
                            (not (string-prefix? ut "Beacon")))
                   (hash-set! idx->combat-pid u-idx p))
                 (when (and (= p our-pid) (set-member? TOWNHALL-SET ut))
                   (set! our-th-coords (cons (cons (exact->inexact ux) (exact->inexact uy)) our-th-coords)))
                 (when (and our-zerg? (= p our-pid) (= eid 1) (<= sec 615.0))
                   (define zc (hash-ref ZERG-COMBAT-COST-HT ut #f))
                   (when zc
                     (define v (vector zc (string=? ut "Zergling") sec +inf.0))
                     (set! zerg-combat-spans (cons v zerg-combat-spans))
                     (hash-set! zerg-combat-live tag v)))
                 (when (= eid 6)
                   (hash-set! unit-init-sec tag sec))
                 (when (= p opp-pid)
                   (hash-set! alive-opp tag (list ut ux uy)))
                 ;; Frame-0 neutral mineral bounds for symmetry inference (zero map-name checks)
                 (when (and (= gl 0) (= eid 1) (string-contains? ut "MineralField"))
                   (define fx0 (exact->inexact ux))
                   (define fy0 (exact->inexact uy))
                   (when (< fx0 min-x0) (set! min-x0 fx0))
                   (when (> fx0 max-x0) (set! max-x0 fx0))
                   (when (< fy0 min-y0) (set! min-y0 fy0))
                   (when (> fy0 max-y0) (set! max-y0 fy0)))
                 ;; Frame-0 main base coordinates & starting townhall lifecycle
                 (when (and (= gl 0) (set-member? TOWNHALL-SET ut))
                   (cond
                     [(= p our-pid)
                      (unless our-main-xy (set! our-main-xy (cons (exact->inexact ux) (exact->inexact uy))))
                      (hash-set! prod-lifespans tag (vector ut 0.0 +inf.0))
                      (hash-set! our-prod-alive-tags tag #t)]
                     [(= p opp-pid)
                      (unless opp-main-xy (set! opp-main-xy (cons (exact->inexact ux) (exact->inexact uy))))])
                   (when (and our-main-xy opp-main-xy (not base-dist))
                     (set! base-dist (max 1.0 (sqrt (+ (sqr (- (car opp-main-xy) (car our-main-xy)))
                                                       (sqr (- (cdr opp-main-xy) (cdr our-main-xy)))))))))
                 (when (and (> gl 0) (memv p '(1 2)))
                   ;; Track our production, tech-prod, base, and Queen lifecycles for 4m/6m/8m/10m curves
                   (when (and (= p our-pid)
                              (<= sec 615.0)
                              (or (set-member? TOWNHALL-SET ut)
                                  (set-member? PROD-FACILITY-SET ut)
                                  (set-member? TECH-PROD-SET ut)
                                  (string=? ut "Queen")))
                     (hash-set! prod-lifespans tag (vector ut sec +inf.0)))
                   ;; Canonical opening BO (first 8 structures / key opening events + 5-building signature)
                   (when (and (= p our-pid) (= eid 6)
                              (< (length opening-bldg5-rev) 5)
                              (not (set-member? WARPABLE-UNIT-SET ut))
                              (not (set-member? CREEP-TUMOR-SET ut)))
                     (set! opening-bldg5-rev (cons (canon-opening-bldg ut) opening-bldg5-rev)))
                   (when (and (= p our-pid) (< (length opening-bo-rev) 8))
                     (cond
                       [(and (= eid 6)
                             (not (set-member? WARPABLE-UNIT-SET ut))
                             (not (set-member? CREEP-TUMOR-SET ut)))
                        (set! opening-bo-rev (cons (list ut (round1 sec)) opening-bo-rev))]
                       [(and (= eid 1) (string=? ut "Overlord") (< opening-ol-cnt 2))
                        (set! opening-ol-cnt (add1 opening-ol-cnt))
                        (set! opening-bo-rev (cons (list ut (round1 sec)) opening-bo-rev))]))
                   ;; Macro structure timing captures
                   (when (set-member? TOWNHALL-SET ut)
                     (hash-update! th-timings p (lambda (lst) (cons (round1 sec) lst))))
                   (when (and (= eid 6) (set-member? GAS-BLDG-SET ut))
                     (hash-update! gas-timings p (lambda (lst) (cons (round1 sec) lst))))
                   (when (and (set-member? SUPPLY-BLDG-SET ut)
                              (or (= eid 6) (string=? ut "Overlord")))
                     (hash-update! sup-timings p (lambda (lst) (cons (round1 sec) lst))))
                   (when (set-member? PROD1-BLDG-SET ut)
                     (unless (hash-has-key? prod1-sec p)
                       (hash-set! prod1-sec p (round1 sec)))
                     (when (= eid 6)
                       (hash-update! prod-bldg-timings p (lambda (lst) (cons (round1 sec) lst)))))
                   (when (and (set-member? TECH1-BLDG-SET ut) (not (hash-has-key? tech1-sec p)))
                     (hash-set! tech1-sec p (round1 sec)))
                   (when (and (set-member? TECH2-BLDG-SET ut) (not (hash-has-key? tech2-sec p)))
                     (hash-set! tech2-sec p (round1 sec)))
                   (when (and (= p our-pid) (not t3-first-sec) (set-member? TECH3-BLDG-SET ut))
                     (set! t3-first-sec (round1 sec))
                     (set! t3-first-bldg ut)
                     (set! t3-bases-at-start (add1 (length (hash-ref th-timings our-pid '())))))
                   (when (and (set-member? AA-TECH-BLDG-SET ut) (not (hash-has-key? aa-tech-first-sec p)))
                     (hash-set! aa-tech-first-sec p (round1 sec)))
                   ;; Unit & building production counts
                   (cond
                     [(= eid 6)
                      (when (= p our-pid)
                        (if (set-member? WARPABLE-UNIT-SET ut)
                            (begin
                              (mark-our-unit-trained! sec)
                              (hash-update! our-units-ht ut add1 0)
                              (when (set-member? AA-UNIT-SET ut)
                                (set! our-aa-unit-cnt (add1 our-aa-unit-cnt))))
                            (hash-update! our-bldgs-ht ut add1 0)))
                      (when (and (= p opp-pid) (set-member? WARPABLE-UNIT-SET ut))
                        (hash-update! opp-units-ht ut add1 0))]
                     [(= eid 1)
                      (define keep-unit?
                        (and (not (set-member? NON-COMBAT-UNIT-SET ut))
                             (not (string-prefix? ut "Beacon"))
                             (not (string-contains? ut "Cocoon"))
                             (not (string-contains? ut "Egg"))
                             (not (string-contains? ut "Mineral"))
                             (not (string-contains? ut "Vespene"))))
                      (when (and (= p our-pid)
                                 (or (set-member? WORKER-UNIT-SET ut)
                                     (and keep-unit?
                                          (not (string-prefix? ut "Changeling")))))
                        (mark-our-unit-trained! sec))
                      (when keep-unit?
                        (cond
                          [(= p our-pid)
                           (hash-update! our-units-ht ut add1 0)
                           (when (set-member? AA-UNIT-SET ut)
                             (set! our-aa-unit-cnt (add1 our-aa-unit-cnt)))]
                          [(= p opp-pid)
                           (hash-update! opp-units-ht ut add1 0)
                           (when (set-member? COMBAT-AIR-SET ut)
                             (set! opp-air-cnt (add1 opp-air-cnt))
                             (unless opp-air-first-sec (set! opp-air-first-sec (round1 sec)))
                             (hash-update! opp-air-types ut add1 0))]))]))]
                [(7) ; SUnitDoneEvent
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (hash-set! unit-done tag #t)
                 (when (= (hash-ref unit-owner tag 0) our-pid)
                   (define ut (hash-ref unit-type tag ""))
                   (when (or (set-member? TOWNHALL-SET ut)
                             (set-member? PROD-FACILITY-SET ut))
                     (hash-set! our-prod-alive-tags tag #t))
                   (when (set-member? GAS-BLDG-SET ut)
                     (hash-set! our-ready-gas-tags tag #t)))]
                [(3) ; SUnitOwnerChangeEvent
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (define p (hash-ref pl 2 0))
                 (hash-set! unit-owner tag p)
                 (unless (= p our-pid)
                   (hash-remove! our-ready-gas-tags tag))
                 (if (= p opp-pid)
                     (let ([xy (hash-ref unit-xy tag '(0 . 0))])
                       (hash-set! alive-opp tag (list (hash-ref unit-type tag "?") (car xy) (cdr xy))))
                     (hash-remove! alive-opp tag))]
                [(4) ; SUnitTypeChangeEvent (morphs: Orbital, Lair, Hive, WarpGate, Ravager, Lurker, etc.)
                 (define u-idx (hash-ref pl 0 0))
                 (define tag (bitwise-ior (arithmetic-shift u-idx 18)
                                          (hash-ref pl 1 0)))
                 (define ut (b->s (hash-ref pl 2 #"")))
                 (define p (hash-ref unit-owner tag 0))
                 (when (not (string=? ut ""))
                   (hash-set! unit-type tag ut)
                   (when (and (= p our-pid) (not first-scout-cross-sec) (<= sec 360.0))
                     (hash-set! idx->owner-type u-idx ut))
                   (when (and our-zerg? (= p our-pid) (<= sec 615.0))
                     (define zc (hash-ref ZERG-COMBAT-COST-HT ut #f))
                     (when zc
                       (define old-v (hash-ref zerg-combat-live tag #f))
                       (when old-v (vector-set! old-v 3 sec))
                       (define v (vector zc (string=? ut "Zergling") sec +inf.0))
                       (set! zerg-combat-spans (cons v zerg-combat-spans))
                       (hash-set! zerg-combat-live tag v)))
                   (when (= p opp-pid)
                     (define xy (hash-ref unit-xy tag '(0 . 0)))
                     (hash-set! alive-opp tag (list ut (car xy) (cdr xy))))
                   (when (and (> gl 0) (memv p '(1 2)))
                     (when (and (= p our-pid) (< (length opening-bo-rev) 8)
                                (or (string=? ut "OrbitalCommand") (string=? ut "Lair")))
                       (set! opening-bo-rev (cons (list ut (round1 sec)) opening-bo-rev)))
                     (when (and (string=? ut "OrbitalCommand") (not (hash-has-key? orbital1-sec p)))
                       (hash-set! orbital1-sec p (round1 sec)))
                     (when (and (string=? ut "Lair") (not (hash-has-key? lair-sec p)))
                       (hash-set! lair-sec p (round1 sec))
                       (unless (hash-has-key? tech1-sec p) (hash-set! tech1-sec p (round1 sec)))
                       (unless (hash-has-key? aa-tech-first-sec p) (hash-set! aa-tech-first-sec p (round1 sec))))
                     (when (and (string=? ut "GreaterSpire") (not (hash-has-key? aa-tech-first-sec p)))
                       (hash-set! aa-tech-first-sec p (round1 sec)))
                     (when (and (= p our-pid) (not t3-first-sec) (set-member? TECH3-BLDG-SET ut))
                       (set! t3-first-sec (round1 sec))
                       (set! t3-first-bldg ut)
                       (set! t3-bases-at-start (add1 (length (hash-ref th-timings our-pid '())))))))]
                [(8) ; SUnitPositionsEvent — early scout crossing + away-from-home + own-base threat
                 (when our-main-xy
                   (define fidx (hash-ref pl 0 0))
                   (define items (hash-ref pl 1 '()))
                   (define ox (car our-main-xy)) (define oy (cdr our-main-xy))
                   (define check-scout? (and (not first-scout-cross-sec) (<= sec 360.0) opp-main-xy base-dist))
                   (define ex (if opp-main-xy (car opp-main-xy) 0.0))
                   (define ey (if opp-main-xy (cdr opp-main-xy) 0.0))
                   (define min-home-d (if base-dist (* 0.45 base-dist) 9999.0))
                   (define max-opp-d (if base-dist (* 0.75 base-dist) 0.0))
                   (define atk-bkt (quotient gl 224))
                   (let loop ([rem items] [cidx fidx])
                     (when (and (pair? rem) (pair? (cdr rem)) (pair? (cddr rem)))
                       (define nidx (+ cidx (first rem)))
                       (define px (exact->inexact (second rem)))
                       (define py (exact->inexact (third rem)))
                       (when (and check-scout? (not first-scout-cross-sec))
                         (define ut (hash-ref idx->owner-type nidx #f))
                         (when ut
                           (unless (or (set-member? WIN-BLDG-SET ut)
                                       (set-member? SCOUT-IGNORE-SET ut)
                                       (string-prefix? ut "Beacon"))
                             (define dh (sqrt (+ (sqr (- px ox)) (sqr (- py oy)))))
                             (define de (sqrt (+ (sqr (- px ex)) (sqr (- py ey)))))
                             (when (and (>= dh min-home-d) (<= de max-opp-d))
                               (set! first-scout-cross-sec (round1 sec))
                               (set! first-scout-unit-type ut)))))
                       (define cpid (hash-ref idx->combat-pid nidx #f))
                       (when cpid
                         (cond
                           [(= cpid our-pid)
                            (define dx (- px ox)) (define dy (- py oy))
                            (when (> (+ (* dx dx) (* dy dy)) 2025.0) ; > 45.0 tiles from own main
                              (set! last-away-combat-sec sec))]
                           [(= cpid opp-pid)
                            (define d2th (min-dist2-to-our-th px py))
                            (when (<= d2th 1444.0) ; <= 38.0 tiles (own territory)
                              (hash-set! own-terr-attack-buckets atk-bkt #t)
                              (when (<= d2th 784.0) ; <= 28.0 tiles (own base)
                                (hash-set! own-base-attack-buckets atk-bkt #t)))]))
                       (loop (cdddr rem) nidx))))]
                [(2) ; SUnitDiedEvent
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (define p (hash-ref unit-owner tag 0))
                 (define ut (hash-ref unit-type tag "?"))
                 (define killer-pid (hash-ref pl 2 #f))
                 (hash-remove! alive-opp tag)
                 (hash-remove! our-prod-alive-tags tag)
                 (hash-remove! our-ready-gas-tags tag)
                 (define ls (hash-ref prod-lifespans tag #f))
                 (when ls (vector-set! ls 2 sec))
                 (when our-zerg?
                   (define zold (hash-ref zerg-combat-live tag #f))
                   (when zold
                     (vector-set! zold 3 sec)
                     (hash-remove! zerg-combat-live tag)))
                 ;; Mark own-base-under-attack buckets when combat/worker deaths happen near our bases
                 (when (and (> gl 100)
                            (pair? our-th-coords)
                            (not (is-morph-death? ut killer-pid))
                            (or (and (= p our-pid) (equal? killer-pid opp-pid))
                                (and (= p opp-pid)
                                     (not (set-member? NON-COMBAT-UNIT-SET ut))
                                     (not (set-member? SCOUT-IGNORE-SET ut)))))
                   (define dx (exact->inexact (hash-ref pl 3 -9999)))
                   (define dy (exact->inexact (hash-ref pl 4 -9999)))
                   (define d2th (min-dist2-to-our-th dx dy))
                   (when (<= d2th 1444.0)
                     (define atk-b (quotient gl 224))
                     (hash-set! own-terr-attack-buckets atk-b #t)
                     (when (<= d2th 784.0)
                       (hash-set! own-base-attack-buckets atk-b #t))))
                 ;; Also detect early scout killed in enemy territory between SUnitPositions ticks
                 (when (and (not first-scout-cross-sec)
                            (= p our-pid)
                            (<= sec 360.0)
                            (> gl 100)
                            killer-pid
                            our-main-xy opp-main-xy base-dist
                            (not (set-member? WIN-BLDG-SET ut))
                            (not (set-member? SCOUT-IGNORE-SET ut))
                            (not (string-prefix? ut "Beacon")))
                   (define dx (exact->inexact (hash-ref pl 3 0)))
                   (define dy (exact->inexact (hash-ref pl 4 0)))
                   (define dh (sqrt (+ (sqr (- dx (car our-main-xy))) (sqr (- dy (cdr our-main-xy))))))
                   (define de (sqrt (+ (sqr (- dx (car opp-main-xy))) (sqr (- dy (cdr opp-main-xy))))))
                   (when (and (>= dh (* 0.45 base-dist)) (<= de (* 0.75 base-dist)))
                     (set! first-scout-cross-sec (round1 sec))
                     (set! first-scout-unit-type ut)))
                 (when (and (= p opp-pid)
                            (equal? killer-pid our-pid)
                            (set-member? CLOAK-THREAT-UNIT-SET ut))
                   (set! opp-cloak-killed-cnt (add1 opp-cloak-killed-cnt)))
                 ;; Self-cancel detector: our initiated building died by our own pid before completion within 15s
                 (when (and (= p our-pid)
                            (equal? killer-pid our-pid)
                            (hash-has-key? unit-init-sec tag)
                            (not (hash-ref unit-done tag #f))
                            (not (set-member? WARPABLE-UNIT-SET ut)))
                   (define init-s (hash-ref unit-init-sec tag sec))
                   (when (<= (- sec init-s) 18.0)
                     (define xy (hash-ref unit-xy tag '(0 . 0)))
                     (define bkey (list ut (quotient (car xy) 8) (quotient (cdr xy) 8)))
                     (define prev (hash-ref self-cancel-buckets bkey #f))
                     (if prev
                         (hash-set! self-cancel-buckets bkey
                                    (list (add1 (first prev)) (second prev) (round1 sec)
                                          (fourth prev) (fifth prev)))
                         (hash-set! self-cancel-buckets bkey
                                    (list 1 (round1 sec) (round1 sec) (car xy) (cdr xy))))))
                 ;; Combat death count by minute
                 (when (and (> gl 0)
                            (memv p '(1 2))
                            (not (set-member? NON-COMBAT-UNIT-SET ut))
                            (not (string-prefix? ut "Beacon"))
                            (not (is-morph-death? ut killer-pid)))
                   (define m (exact-floor (/ sec 60.0)))
                   (if (= p our-pid)
                       (hash-update! our-deaths-by-min m add1 0)
                       (hash-update! opp-deaths-by-min m add1 0)))]
                [(5) ; SUpgradeEvent
                 (define p (hash-ref pl 0 0))
                 (define upg (b->s (hash-ref pl 1 #"")))
                 (when (and (memv p '(1 2))
                            (not (string=? upg ""))
                            (not (string-prefix? upg "Spray"))
                            (not (string-prefix? upg "RewardDance")))
                   (hash-update! upg-cnt p add1 0)
                   (when (and (= p our-pid) (> gl 0))
                     (define ulow (string-downcase upg))
                     (define s1 (round1 sec))
                     (define (rec-upg! k)
                       (unless (hash-has-key? upg-timings k) (hash-set! upg-timings k s1))
                       (unless (hash-has-key? upg-timings 'first_combat_upg_sec)
                         (hash-set! upg-timings 'first_combat_upg_sec s1)))
                     (cond
                       [(string=? ulow "warpgateresearch") (rec-upg! 'warpgate_sec)]
                       [(string=? ulow "blinktech") (rec-upg! 'blink_sec)]
                       [(string=? ulow "charge") (rec-upg! 'charge_sec)]
                       [(string=? ulow "stimpack") (rec-upg! 'stim_sec)]
                       [(string=? ulow "shieldwall") (rec-upg! 'combat_shield_sec)]
                       [(string=? ulow "punishergrenades") (rec-upg! 'concussive_sec)]
                       [(string=? ulow "zerglingmovementspeed") (rec-upg! 'ling_speed_sec)]
                       [(string=? ulow "centrificalhooks") (rec-upg! 'bane_speed_sec)]
                       [(string=? ulow "glialreconstitution") (rec-upg! 'roach_speed_sec)]
                       [(or (string-contains? ulow "weaponslevel1")) (rec-upg! 'plus1_atk_sec)]
                       [(or (string-contains? ulow "armorslevel1")) (rec-upg! 'plus1_arm_sec)])))])))

          ;; Duration & Result
          (define total-loops (max header-loops max-tracker-loop))
          (define dur (round1 (/ total-loops 22.4)))
          (define raw-res
            (string-downcase
             (format "~a" (or (hash-ref meta 'outcome #f)
                              (hash-ref meta 'result #f)
                              (hash-ref our-p 'result "unknown")))))
          (define res
            (cond
              [(string-contains? raw-res "win") 'win]
              [(string-contains? raw-res "tie") 'tie]
              [(string-contains? raw-res "loss") 'loss]
              [(>= dur 2390.0) 'tie]
              [else 'unknown]))
          (define opp-early-crash?
            (and (eq? res 'win) (<= total-loops 300)))

          ;; Runner summary.json wall & step latency telemetry (gracefully #f when absent)
          (define wall-sec
            (let ([v (hash-ref meta 'wall_sec #f)])
              (and (real? v) (round1 v))))
          (define run-timeout-sec
            (let ([v (hash-ref meta 'run_timeout_sec #f)])
              (and (real? v) (exact->inexact v))))
          (define runner-timed-out? (eq? (hash-ref meta 'timed_out #f) #t))
          (define our-tel
            (let ([t (hash-ref meta 'our_telemetry #f)])
              (if (hash? t) t (hasheq))))
          (define (tel-ms k)
            (let ([v (hash-ref our-tel k #f)])
              (and (real? v) (round2 v))))
          (define tel-avg-obs-ms (tel-ms 'avg_obs_ms))
          (define tel-avg-rt-ms (tel-ms 'avg_runtime_ms))
          (define tel-avg-tr-ms (tel-ms 'avg_translate_ms))
          (define tel-p95-tr-ms (or (tel-ms 'p95_translate_ms) (tel-ms 'tr_p95_ms)))
          (define tel-avg-step-ms (tel-ms 'avg_step_ms))
          (define tel-p95-step-ms (tel-ms 'p95_step_ms))
          (define tel-max-step-ms (tel-ms 'max_step_ms))

          ;; Core stats extraction
          (define our-s (hash-ref stats-by-min our-pid))
          (define opp-s (hash-ref stats-by-min opp-pid))
          (define our-last (or (last-stat our-s) (hasheq)))
          (define opp-last (or (last-stat opp-s) (hasheq)))
          (define killed-val (+ (safe-num (hash-ref our-last 'killed_min 0))
                                (safe-num (hash-ref our-last 'killed_gas 0))))
          (define lost-val (+ (safe-num (hash-ref opp-last 'killed_min 0))
                              (safe-num (hash-ref opp-last 'killed_gas 0))))
          (define trade-ratio (round2 (/ (+ killed-val 100.0) (+ lost-val 100.0))))

          (define our-ths-list (reverse (hash-ref th-timings our-pid '())))
          (define opp-ths-list (reverse (hash-ref th-timings opp-pid '())))
          (define our-gas-list (reverse (hash-ref gas-timings our-pid '())))
          (define our-sup-list (reverse (hash-ref sup-timings our-pid '())))
          (define our-bases (add1 (length our-ths-list)))
          (define opp-bases (add1 (length opp-ths-list)))

          (define (w-at sbm-p t)
            (define h (stat-near-sec sbm-p t))
            (and h (safe-num (hash-ref h 'workers 0))))
          (define (army-val-at sbm-p t)
            (define h (stat-near-sec sbm-p t))
            (and h (+ (safe-num (hash-ref h 'army_min 0))
                      (safe-num (hash-ref h 'army_gas 0)))))
          (define (army-sup-at sbm-p t)
            (define h (stat-near-sec sbm-p t))
            (and h (max 0 (- (safe-num (hash-ref h 'food_used 0))
                             (safe-num (hash-ref h 'workers 0))))))

          (define our-w2 (w-at our-s 120.0)) (define opp-w2 (w-at opp-s 120.0))
          (define our-w4 (w-at our-s 240.0)) (define opp-w4 (w-at opp-s 240.0))
          (define our-w6 (w-at our-s 360.0)) (define opp-w6 (w-at opp-s 360.0))
          (define our-w8 (w-at our-s 480.0)) (define opp-w8 (w-at opp-s 480.0))
          (define our-w10 (w-at our-s 600.0)) (define opp-w10 (w-at opp-s 600.0))
          (define a2 (army-val-at our-s 120.0))
          (define a4 (army-val-at our-s 240.0))
          (define a6 (army-val-at our-s 360.0))
          (define a8 (army-val-at our-s 480.0))
          (define a10 (army-val-at our-s 600.0))
          (define asup2 (army-sup-at our-s 120.0))
          (define asup4 (army-sup-at our-s 240.0))
          (define asup6 (army-sup-at our-s 360.0))
          (define asup8 (army-sup-at our-s 480.0))
          (define asup10 (army-sup-at our-s 600.0))
          (define a2w-4m (and a4 our-w4 (> our-w4 0) (round1 (/ (exact->inexact a4) our-w4))))
          (define a2w-6m (and a6 our-w6 (> our-w6 0) (round1 (/ (exact->inexact a6) our-w6))))
          (define a2w-8m (and a8 our-w8 (> our-w8 0) (round1 (/ (exact->inexact a8) our-w8))))
          (define a2w-10m (and a10 our-w10 (> our-w10 0) (round1 (/ (exact->inexact a10) our-w10))))
          (define pro-a4-ref (hash-ref PRO-ARMY-VAL-4M-BY-RACE our-race #f))
          (define army-val-4m-ratio-vs-pro
            (and a4 pro-a4-ref (> pro-a4-ref 0.0) (round2 (/ (exact->inexact a4) pro-a4-ref))))
          (define pro-a8-ref (hash-ref PRO-ARMY-VAL-8M-BY-RACE our-race #f))
          (define army-val-8m-ratio-vs-pro
            (and a8 pro-a8-ref (> pro-a8-ref 0.0) (round2 (/ (exact->inexact a8) pro-a8-ref))))

          ;; Production, base, tech-prod, and Queen counts alive at 4m/6m/8m/10m
          (define (alive-cnt-at t pred)
            (and (>= dur (- t 15.0))
                 (for/sum ([(_tag vec) (in-hash prod-lifespans)]
                           #:when (and (<= (vector-ref vec 1) t)
                                       (< t (vector-ref vec 2))
                                       (pred (vector-ref vec 0))))
                   1)))
          (define (is-th? ut) (set-member? TOWNHALL-SET ut))
          (define (is-prod? ut) (set-member? PROD-FACILITY-SET ut))
          (define (is-pprod? ut) (set-member? PRIMARY-PROD-SET ut))
          (define (is-tprod? ut) (set-member? TECH-PROD-SET ut))
          (define (is-queen? ut) (string=? ut "Queen"))
          (define bases-4m (alive-cnt-at 240.0 is-th?))
          (define bases-6m (alive-cnt-at 360.0 is-th?))
          (define bases-8m (alive-cnt-at 480.0 is-th?))
          (define bases-10m (alive-cnt-at 600.0 is-th?))
          (define prod-4m (alive-cnt-at 240.0 is-prod?))
          (define prod-6m (alive-cnt-at 360.0 is-prod?))
          (define prod-8m (alive-cnt-at 480.0 is-prod?))
          (define prod-10m (alive-cnt-at 600.0 is-prod?))
          (define pprod-4m (alive-cnt-at 240.0 is-pprod?))
          (define pprod-6m (alive-cnt-at 360.0 is-pprod?))
          (define pprod-8m (alive-cnt-at 480.0 is-pprod?))
          (define pprod-10m (alive-cnt-at 600.0 is-pprod?))
          (define tprod-4m (alive-cnt-at 240.0 is-tprod?))
          (define tprod-6m (alive-cnt-at 360.0 is-tprod?))
          (define tprod-8m (alive-cnt-at 480.0 is-tprod?))
          (define tprod-10m (alive-cnt-at 600.0 is-tprod?))
          (define queens-4m (alive-cnt-at 240.0 is-queen?))
          (define queens-6m (alive-cnt-at 360.0 is-queen?))
          (define queens-8m (alive-cnt-at 480.0 is-queen?))
          (define queens-10m (alive-cnt-at 600.0 is-queen?))

          ;; Early scouting & opening BO / upgrade timings
          (define our-prod-list (reverse (hash-ref prod-bldg-timings our-pid '())))
          (define enemy-first-seen-sec
            (let ([lp (hash-ref our-tel 'enemy_first_seen_loop #f)])
              (and (real? lp) (> lp 0) (round1 (/ (exact->inexact lp) 22.4)))))
          (define first-scout-sec (or first-scout-cross-sec enemy-first-seen-sec))
          (define opening-bo (reverse opening-bo-rev))
          (define opening-seq5
            (and (pair? opening-bldg5-rev)
                 (string-join (reverse opening-bldg5-rev) "->")))
          (define upg-timings-imm
            (for/hasheq ([(k v) (in-hash upg-timings)]) (values k v)))

          (define our-pk-w (peak-stat our-s (lambda (h) (safe-num (hash-ref h 'workers 0)))))
          (define opp-pk-w (peak-stat opp-s (lambda (h) (safe-num (hash-ref h 'workers 0)))))
          (define our-pk-army (peak-stat our-s (lambda (h) (+ (safe-num (hash-ref h 'army_min 0))
                                                              (safe-num (hash-ref h 'army_gas 0))))))
          (define opp-pk-army (peak-stat opp-s (lambda (h) (+ (safe-num (hash-ref h 'army_min 0))
                                                              (safe-num (hash-ref h 'army_gas 0))))))
          (define our-pk-sup (peak-stat our-s (lambda (h) (safe-num (hash-ref h 'food_used 0)))))
          (define opp-pk-sup (peak-stat opp-s (lambda (h) (safe-num (hash-ref h 'food_used 0)))))
          (define our-avg-min (round1 (avg-stat our-s (lambda (h) (safe-num (hash-ref h 'min_cur 0))))))
          (define our-avg-gas (round1 (avg-stat our-s (lambda (h) (safe-num (hash-ref h 'gas_cur 0))))))
          (define our-pk-min (peak-stat our-s (lambda (h) (safe-num (hash-ref h 'min_cur 0)))))
          (define our-pk-gas (peak-stat our-s (lambda (h) (safe-num (hash-ref h 'gas_cur 0)))))
          (define upgs (hash-ref upg-cnt our-pid 0))
          (define tot-ev (max 1 (hash-ref total-stat-ev our-pid 1)))
          (define sb-ev (hash-ref sb-steps our-pid 0))
          (define sb-pct (round1 (* 100.0 (/ sb-ev tot-ev))))

          ;; W15-LOOP-2: Infer map_symmetry_kind from frame-0 neutral mineral bounds & main spawns (zero map-name checks)
          (define map-symmetry-kind
            (cond
              [(and our-main-xy opp-main-xy (< min-x0 max-x0) (< min-y0 max-y0))
               (define cx (* 0.5 (+ min-x0 max-x0)))
               (define cy (* 0.5 (+ min-y0 max-y0)))
               (define ox (car our-main-xy)) (define oy (cdr our-main-xy))
               (define ex (car opp-main-xy)) (define ey (cdr opp-main-xy))
               (define (d2 a b) (+ (sqr (- a ex)) (sqr (- b ey))))
               (define cands
                 (list (cons "rotational-180"       (d2 (- (* 2.0 cx) ox) (- (* 2.0 cy) oy)))
                       (cons "mirror-horizontal"    (d2 (- (* 2.0 cx) ox) oy))
                       (cons "mirror-vertical"      (d2 ox (- (* 2.0 cy) oy)))
                       (cons "mirror-diagonal-main" (d2 (+ cx (- oy cy)) (+ cy (- ox cx))))
                       (cons "mirror-diagonal-anti" (d2 (- cx (- oy cy)) (- cy (- ox cx))))))
               (define best (argmin cdr cands))
               (if (<= (cdr best) 100.0) (car best) "asymmetric")]
              [else "unknown"]))

          ;; W15-LOOP-2: Premature T3 starvation guard (catches #5132983/#5132984 style <=4:30 low-eco T3 loss)
          (define t3-premature-starve?
            (and (real? t3-first-sec)
                 (<= t3-first-sec 270.0)
                 (exact-integer? t3-bases-at-start)
                 (<= t3-bases-at-start 2)
                 (eq? res 'loss)
                 (or (<= dur 420.0)
                     (and (real? our-w4) (< our-w4 24)))))

          (define macro-timings
            (hasheq 'nat_sec (and (>= (length our-ths-list) 1) (first our-ths-list))
                    'third_sec (and (>= (length our-ths-list) 2) (second our-ths-list))
                    'fourth_sec (and (>= (length our-ths-list) 3) (third our-ths-list))
                    'gas1_sec (and (>= (length our-gas-list) 1) (first our-gas-list))
                    'gas2_sec (and (>= (length our-gas-list) 2) (second our-gas-list))
                    'supply1_sec (and (>= (length our-sup-list) 1) (first our-sup-list))
                    'supply2_sec (and (>= (length our-sup-list) 2) (second our-sup-list))
                    'prod1_sec (hash-ref prod1-sec our-pid #f)
                    'prod2_sec (and (>= (length our-prod-list) 2) (second our-prod-list))
                    'prod3_sec (and (>= (length our-prod-list) 3) (third our-prod-list))
                    'tech1_sec (hash-ref tech1-sec our-pid #f)
                    'tech2_sec (hash-ref tech2-sec our-pid #f)
                    't3_first_sec t3-first-sec
                    't3_bases_at_start t3-bases-at-start
                    'orbital1_sec (hash-ref orbital1-sec our-pid #f)
                    'lair_sec (hash-ref lair-sec our-pid #f)
                    'w2m our-w2 'w4m our-w4 'w6m our-w6 'w8m our-w8 'w10m our-w10
                    'bases_4m bases-4m 'bases_6m bases-6m 'bases_8m bases-8m 'bases_10m bases-10m
                    'prod_cnt_4m prod-4m 'prod_cnt_6m prod-6m 'prod_cnt_8m prod-8m 'prod_cnt_10m prod-10m
                    'prod_count_4m prod-4m 'prod_count_6m prod-6m 'prod_count_8m prod-8m 'prod_count_10m prod-10m
                    'primary_prod_4m pprod-4m 'primary_prod_6m pprod-6m 'primary_prod_8m pprod-8m 'primary_prod_10m pprod-10m
                    'tech_prod_4m tprod-4m 'tech_prod_6m tprod-6m 'tech_prod_8m tprod-8m 'tech_prod_10m tprod-10m
                    'queens_4m queens-4m 'queens_6m queens-6m 'queens_8m queens-8m 'queens_10m queens-10m
                    'army_val_2m a2 'army_val_4m a4 'army_val_6m a6 'army_val_8m a8 'army_val_10m a10
                    'army_sup_2m asup2 'army_sup_4m asup4 'army_sup_6m asup6 'army_sup_8m asup8 'army_sup_10m asup10
                    'army_to_worker_4m a2w-4m 'army_to_worker_6m a2w-6m
                    'army_to_worker_8m a2w-8m 'army_to_worker_10m a2w-10m
                    'army_val_4m_ratio_vs_pro army-val-4m-ratio-vs-pro
                    'army_val_8m_ratio_vs_pro army-val-8m-ratio-vs-pro
                    'first_scout_sec first-scout-sec
                    'first_scout_cross_sec first-scout-cross-sec
                    'enemy_first_seen_sec enemy-first-seen-sec
                    'warpgate_sec (hash-ref upg-timings 'warpgate_sec #f)
                    'blink_sec (hash-ref upg-timings 'blink_sec #f)
                    'charge_sec (hash-ref upg-timings 'charge_sec #f)
                    'stim_sec (hash-ref upg-timings 'stim_sec #f)
                    'combat_shield_sec (hash-ref upg-timings 'combat_shield_sec #f)
                    'concussive_sec (hash-ref upg-timings 'concussive_sec #f)
                    'ling_speed_sec (hash-ref upg-timings 'ling_speed_sec #f)
                    'bane_speed_sec (hash-ref upg-timings 'bane_speed_sec #f)
                    'roach_speed_sec (hash-ref upg-timings 'roach_speed_sec #f)
                    'plus1_atk_sec (hash-ref upg-timings 'plus1_atk_sec #f)
                    'plus1_arm_sec (hash-ref upg-timings 'plus1_arm_sec #f)
                    'first_combat_upg_sec (hash-ref upg-timings 'first_combat_upg_sec #f)))

          ;; Surviving enemy breakdown (win-condition structures vs CreepTumor/Overlord/etc.)
          (define surv-win-ht (make-hash))
          (define surv-win-locs '())
          (define surv-nonwin-ht (make-hash))
          (for ([(_tag info) (in-hash alive-opp)])
            (define ut (first info))
            (define ux (second info))
            (define uy (third info))
            (unless (or (string-prefix? ut "Beacon")
                        (member ut '("Larva" "Egg" "Broodling" "Interceptor")))
              (cond
                [(set-member? WIN-BLDG-SET ut)
                 (hash-update! surv-win-ht ut add1 0)
                 (when (< (length surv-win-locs) 8)
                   (set! surv-win-locs (cons (format "~a(~a,~a)" ut ux uy) surv-win-locs)))]
                [else
                 (hash-update! surv-nonwin-ht ut add1 0)])))
          (define surv-win-total (for/sum ([(_k v) (in-hash surv-win-ht)]) v))

          ;; Scan associated logs
          (define-values (zips plains) (find-associated-logs replay-path meta bot-prefix))
          (define log-acc
            (let* ([a0 (make-log-acc)]
                   [a1 (for/fold ([a a0]) ([z (in-list zips)]) (scan-log-zip! a z))]
                   [a2 (for/fold ([a a1]) ([f (in-list plains)]) (scan-plain-log-file! a f))])
              a2))
          (define pos-by-min (hash-ref log-acc 'pos-by-min))

          ;; -----------------------------------------------------------------
          ;; Automatic Forensic Anomaly Detectors (Single-Pass, Zero Greps!)
          ;; -----------------------------------------------------------------

          ;; Detector 1: Zero-Fire / Suicide-Kite Retreat Collapse Windows
          (define mins-sorted (sort (hash-keys our-s) <))
          (define collapse-mins '())
          (define prev-k 0) (define prev-l 0)
          (for ([m (in-list mins-sorted)])
            (define h1 (hash-ref our-s m))
            (define h2 (hash-ref opp-s m (hasheq)))
            (define cur-k (+ (safe-num (hash-ref h1 'killed_min 0)) (safe-num (hash-ref h1 'killed_gas 0))))
            (define cur-l (+ (safe-num (hash-ref h2 'killed_min 0)) (safe-num (hash-ref h2 'killed_gas 0))))
            (define dk (max 0 (- cur-k prev-k)))
            (define dl (max 0 (- cur-l prev-l)))
            (set! prev-k cur-k) (set! prev-l cur-l)
            (define od (hash-ref our-deaths-by-min m 0))
            (define ok (hash-ref opp-deaths-by-min m 0))
            (define m-ratio (/ (+ dk 50.0) (+ dl 50.0)))
            (when (and (>= m 2)
                       (or (and (>= dl 1200) (< m-ratio 0.22))
                           (and (>= od 10) (< (/ (+ ok 0.5) (+ od 0.5)) 0.18))))
              (define pv (hash-ref pos-by-min m #(0 0 0)))
              (define ptot (+ (vector-ref pv 0) (vector-ref pv 1) (vector-ref pv 2)))
              (define ret-pct (if (> ptot 0) (round1 (* 100.0 (/ (vector-ref pv 2) ptot))) #f))
              (set! collapse-mins
                    (cons (hasheq 'min (add1 m) 'lost dl 'killed dk 'deaths od 'kills ok
                                  'ratio (round2 m-ratio) 'retreat_pct ret-pct)
                          collapse-mins))))
          (define collapse-ordered (reverse collapse-mins))
          (define zero-fire-retreat-anomaly
            (if (null? collapse-ordered)
                #f
                (let* ([tot-dl (for/sum ([c (in-list collapse-ordered)]) (hash-ref c 'lost 0))]
                       [tot-dk (for/sum ([c (in-list collapse-ordered)]) (hash-ref c 'killed 0))]
                       [tot-od (for/sum ([c (in-list collapse-ordered)]) (hash-ref c 'deaths 0))]
                       [tot-ok (for/sum ([c (in-list collapse-ordered)]) (hash-ref c 'kills 0))]
                       [rpcts (filter real? (map (lambda (c) (hash-ref c 'retreat_pct #f)) collapse-ordered))]
                       [avg-ret (if (pair? rpcts) (round1 (/ (apply + rpcts) (length rpcts))) #f)]
                       [is-retreat-driven? (and avg-ret (>= avg-ret 35.0))])
                  (hasheq 'minutes (map (lambda (c) (hash-ref c 'min)) collapse-ordered)
                          'lost_val tot-dl 'killed_val tot-dk
                          'deaths tot-od 'kills tot-ok
                          'trade_ratio (round2 (/ (+ tot-dk 50.0) (+ tot-dl 50.0)))
                          'avg_retreat_pct avg-ret
                          'retreat_driven is-retreat-driven?))))

          ;; Detector 2: Mineral / Gas Escrow Lockout Windows
          (define escrow-lockouts
            (append (hash-ref log-acc 'hb-windows '())
                    (hash-ref log-acc 'gs-windows '())))

          ;; Detector 3: Structure Self-Cancel Loops (>= 3 rapid self-cancels in same region)
          (define self-cancel-loops
            (for/list ([(bkey info) (in-hash self-cancel-buckets)]
                       #:when (>= (first info) 3))
              (hasheq 'type (first bkey)
                      'count (first info)
                      'start_sec (second info)
                      'end_sec (third info)
                      'x (fourth info)
                      'y (fifth info))))

          ;; Detector 4: Endgame Stall / Idle-Army-While-Ahead Windows
          (define stall-mins '())
          (define prev-k2 0)
          (for ([m (in-list mins-sorted)])
            (define h1 (hash-ref our-s m))
            (define h2 (hash-ref opp-s m (hasheq)))
            (define cur-k (+ (safe-num (hash-ref h1 'killed_min 0)) (safe-num (hash-ref h1 'killed_gas 0))))
            (define dk (max 0 (- cur-k prev-k2)))
            (set! prev-k2 cur-k)
            (define a1 (+ (safe-num (hash-ref h1 'army_min 0)) (safe-num (hash-ref h1 'army_gas 0))))
            (define a2 (+ (safe-num (hash-ref h2 'army_min 0)) (safe-num (hash-ref h2 'army_gas 0))))
            (define f1 (safe-num (hash-ref h1 'food_used 0)))
            (when (and (>= m 10)
                       (<= dk 300)
                       (or (>= a1 3500) (>= f1 140))
                       (>= a1 (* 1.25 (max 500 a2))))
              (set! stall-mins (cons (list (add1 m) a1 a2 f1) stall-mins))))
          (define stall-ordered (reverse stall-mins))
          (define endgame-stall-anomaly
            (if (< (length stall-ordered) 4)
                #f
                (let* ([has-creep-or-ol? (or (> (hash-ref surv-nonwin-ht "CreepTumorQueen" 0) 0)
                                             (> (hash-ref surv-nonwin-ht "CreepTumorBurrowed" 0) 0)
                                             (> (hash-ref surv-nonwin-ht "Overlord" 0) 0))]
                       [few-win-bldgs? (<= surv-win-total 2)])
                  (hasheq 'stall_minutes (length stall-ordered)
                          'start_min (first (first stall-ordered))
                          'end_min (first (last stall-ordered))
                          'peak_army_during_stall (apply max (map second stall-ordered))
                          'surviving_win_bldgs surv-win-total
                          'surviving_win_locs (reverse surv-win-locs)
                          'creep_or_ol_present has-creep-or-ol?
                          'creep_or_ol_blocked (and few-win-bldgs? has-creep-or-ol?)))))

          ;; Detector 5: Air-Threat vs AA/Tech Starvation
          (define our-lair-s (hash-ref lair-sec our-pid #f))
          (define our-aa-tech-s (hash-ref aa-tech-first-sec our-pid #f))
          (define air-aa-starvation
            (and (>= opp-air-cnt 3)
                 opp-air-first-sec
                 (>= (- dur opp-air-first-sec) 90.0)
                 (let ([zerg-no-lair? (and (string=? our-race "Zerg") (not our-lair-s))]
                       [low-aa-units? (< our-aa-unit-cnt (max 3 (quotient opp-air-cnt 2)))]
                       [no-aa-tech? (not our-aa-tech-s)])
                   (and (or zerg-no-lair? no-aa-tech? low-aa-units?)
                        (hasheq 'opp_air_count opp-air-cnt
                                'opp_air_first_sec opp-air-first-sec
                                'opp_air_types (for/list ([p (in-list (top-k-pairs opp-air-types 4))])
                                                 (format "~a:~a" (car p) (cdr p)))
                                'our_aa_units our-aa-unit-cnt
                                'our_aa_tech_sec our-aa-tech-s
                                'our_lair_sec our-lair-s)))))

          ;; W7-LOOP-2: Compute exact own_base_retreat_frames & endgame_home_stall_sec
          (define endgame-home-stall-sec (round1 max-home-stall-sec))
          (define endgame-home-stall-anomaly
            (and (>= max-home-stall-sec 90.0)
                 (hasheq 'max_streak_sec endgame-home-stall-sec)))
          (define-values (own-base-retreat-frames own-base-retreat-ticks)
            (let ([rfs (reverse (hash-ref log-acc 'retreat-frames '()))])
              (for/fold ([frames 0] [ticks 0] [prev-fr #f] #:result (values frames ticks))
                        ([fr (in-list rfs)])
                (define b (quotient fr 224))
                (if (or (hash-has-key? own-base-attack-buckets b)
                        (hash-has-key? own-base-attack-buckets (sub1 b))
                        (hash-has-key? own-base-attack-buckets (add1 b)))
                    (let ([step-f (if (and prev-fr (> fr prev-fr) (<= (- fr prev-fr) 96))
                                      (- fr prev-fr)
                                      44)])
                      (values (+ frames step-f) (add1 ticks) fr))
                    (values frames ticks #f)))))
          (define own-base-retreat-anomaly
            (and (>= own-base-retreat-frames 440)
                 (hasheq 'frames own-base-retreat-frames
                         'ticks own-base-retreat-ticks
                         'sec (round1 (/ own-base-retreat-frames 22.4)))))
          ;; W12-LOOP-2: Own-territory retreat frames (enemies <= 38t of any friendly base)
          (define-values (own-terr-retreat-frames own-terr-retreat-ticks)
            (let ([rfs (reverse (hash-ref log-acc 'retreat-frames '()))])
              (for/fold ([frames 0] [ticks 0] [prev-fr #f] #:result (values frames ticks))
                        ([fr (in-list rfs)])
                (define b (quotient fr 224))
                (if (or (hash-has-key? own-terr-attack-buckets b)
                        (hash-has-key? own-terr-attack-buckets (sub1 b))
                        (hash-has-key? own-terr-attack-buckets (add1 b)))
                    (let ([step-f (if (and prev-fr (> fr prev-fr) (<= (- fr prev-fr) 96))
                                      (- fr prev-fr)
                                      44)])
                      (values (+ frames step-f) (add1 ticks) fr))
                    (values frames ticks #f)))))
          (define own-terr-retreat-anomaly
            (and (>= own-terr-retreat-frames 440)
                 (hasheq 'frames own-terr-retreat-frames
                         'ticks own-terr-retreat-ticks
                         'sec (round1 (/ own-terr-retreat-frames 22.4)))))
          ;; W12-LOOP-2: Pre-3:30 early-rush idle-bank loss detector (minerals >= 250 while army_sup <= 4)
          (define early-rush-idle-bank-3m?
            (and (eq? res 'loss)
                 (or (and (<= dur 240.0) (>= early-rush-idle-bank-ticks 2))
                     (and (<= dur 380.0) (>= early-rush-idle-bank-post100-ticks 2)))))
          (define early-rush-idle-bank-3m-anomaly
            (and early-rush-idle-bank-3m?
                 (hasheq 'ticks early-rush-idle-bank-ticks
                         'post100_ticks early-rush-idle-bank-post100-ticks
                         'peak_min early-rush-idle-bank-peak-min
                         'duration_sec dur)))

          ;; W8-LOOP-2: Protoss non-combat Robo waste (Observer > 2 @ 100, WarpPrism > 1 @ 250)
          ;; and Zerg non-Ling combat value share at 6m-10m
          (define obs-built (hash-ref our-units-ht "Observer" 0))
          (define wp-built (+ (hash-ref our-units-ht "WarpPrism" 0)
                              (hash-ref our-units-ht "WarpPrismPhasing" 0)))
          (define non-combat-robo-waste-val
            (if (string=? our-race "Protoss")
                (+ (* (max 0 (- obs-built 2)) 100)
                   (* (max 0 (- wp-built 1)) 250))
                0))
          (define non-combat-robo-waste-anomaly
            (and (>= non-combat-robo-waste-val 500)
                 (hasheq 'waste_val non-combat-robo-waste-val
                         'observers obs-built
                         'warp_prisms wp-built)))
          (define zerg-non-ling-army-pct
            (and our-zerg?
                 (let-values ([(nl-tot all-tot)
                               (for/fold ([nl 0] [tot 0]) ([t (in-list '(360.0 480.0 600.0))]
                                                           #:when (>= dur (- t 15.0)))
                                 (for/fold ([nl2 nl] [tot2 tot]) ([v (in-list zerg-combat-spans)]
                                                                  #:when (and (<= (vector-ref v 2) t)
                                                                              (< t (vector-ref v 3))))
                                   (define c (vector-ref v 0))
                                   (values (if (vector-ref v 1) nl2 (+ nl2 c))
                                           (+ tot2 c))))])
                   (and (> all-tot 0)
                        (round1 (* 100.0 (/ (exact->inexact nl-tot) all-tot)))))))

          ;; W9-LOOP-2: Siege-range 0-DPS loss detector (>=15 combat deaths at <0.10x vs Tempest/Tank/Colossus/Carrier)
          (define opp-siege-types-ht (make-hash))
          (define opp-siege-cnt
            (for/sum ([(ut cnt) (in-hash opp-units-ht)]
                      #:when (set-member? SIEGE-CAPITAL-UNIT-SET ut))
              (hash-set! opp-siege-types-ht ut cnt)
              cnt))
          (define our-combat-deaths-total
            (for/sum ([(_m c) (in-hash our-deaths-by-min)]) c))
          (define zfr-deaths
            (if (hash? zero-fire-retreat-anomaly) (hash-ref zero-fire-retreat-anomaly 'deaths 0) 0))
          (define zfr-ratio
            (if (hash? zero-fire-retreat-anomaly) (hash-ref zero-fire-retreat-anomaly 'trade_ratio 1.0) 1.0))
          (define siege-zero-dps-loss?
            (and (eq? res 'loss)
                 (>= opp-siege-cnt 2)
                 (or (and (>= our-combat-deaths-total 15) (< trade-ratio 0.10))
                     (and (>= zfr-deaths 15) (< zfr-ratio 0.10)))))
          (define siege-zero-dps-loss-anomaly
            (and siege-zero-dps-loss?
                 (hasheq 'opp_siege_count opp-siege-cnt
                         'opp_siege_types (for/list ([p (in-list (top-k-pairs opp-siege-types-ht 4))])
                                            (format "~a:~a" (car p) (cdr p)))
                         'our_deaths (max our-combat-deaths-total zfr-deaths)
                         'trade_ratio trade-ratio
                         'collapse_ratio zfr-ratio)))
          ;; W10-LOOP-2: Cloaked-unit damage loss detector (>=3 Banshee/DT/Lurker with <=0.15x trade or 0 killed)
          (define opp-cloak-types-ht (make-hash))
          (define opp-cloak-cnt
            (for/sum ([(ut cnt) (in-hash opp-units-ht)]
                      #:when (set-member? CLOAK-THREAT-UNIT-SET ut))
              (hash-set! opp-cloak-types-ht ut cnt)
              cnt))
          (define cloaked-unit-damage-loss?
            (and (eq? res 'loss)
                 (>= opp-cloak-cnt 3)
                 (or (<= trade-ratio 0.15)
                     (= opp-cloak-killed-cnt 0))))
          (define cloaked-unit-damage-loss-anomaly
            (and cloaked-unit-damage-loss?
                 (hasheq 'opp_cloak_count opp-cloak-cnt
                         'opp_cloak_killed opp-cloak-killed-cnt
                         'opp_cloak_types (for/list ([p (in-list (top-k-pairs opp-cloak-types-ht 4))])
                                            (format "~a:~a" (car p) (cdr p)))
                         'trade_ratio trade-ratio)))
          (define opp-cohort (classify-opp-cohort opp-bot))

          ;; W11-LOOP-2: Gas-rich / mineral-starved stall detector (>= 30 [SCBOT_PRIORITY] ticks of gas>=200 & min<100)
          (define gas-rich-min-starved-ticks (hash-ref log-acc 'gas-rich-min-starved-ticks 0))
          (define gas-rich-min-starved-peak-gas (hash-ref log-acc 'gas-rich-min-starved-peak-gas 0))
          (define gas-rich-min-starved? (>= gas-rich-min-starved-ticks 30))
          (define gas-rich-min-starved-anomaly
            (and gas-rich-min-starved?
                 (hasheq 'ticks gas-rich-min-starved-ticks
                         'peak_gas gas-rich-min-starved-peak-gas
                         'avg_min our-avg-min
                         'avg_gas our-avg-gas)))

          ;; W13-LOOP-2: Production building placement stall (>=30 ticks or >=8 streak on <300s match)
          ;; and PvP Natural Nexus delay (PvP Nat@ > 210s)
          (define prod-placement-stall-ticks (hash-ref log-acc 'prod-stall-ticks 0))
          (define prod-placement-stall-max-streak (hash-ref log-acc 'prod-stall-max-streak 0))
          (define prod-placement-stall-max-bldg (hash-ref log-acc 'prod-stall-max-bldg ""))
          (define prod-placement-stall-counts (hash-ref log-acc 'prod-stall-counts (make-hash)))
          (define prod-placement-stall?
            (or (>= prod-placement-stall-ticks 30)
                (and (<= dur 300.0) (>= prod-placement-stall-max-streak 8))))
          (define prod-placement-stall-anomaly
            (and prod-placement-stall?
                 (hasheq 'ticks prod-placement-stall-ticks
                         'max_streak prod-placement-stall-max-streak
                         'top_bldg prod-placement-stall-max-bldg
                         'by_bldg (for/list ([p (in-list (top-k-pairs prod-placement-stall-counts 4))])
                                    (format "~a:~a" (car p) (cdr p))))))
          (define our-nat-sec-val (hash-ref macro-timings 'nat_sec #f))
          (define pvp-nat-delay-flag?
            (and (string=? matchup "PvP")
                 (>= dur 210.0)
                 (or (not (real? our-nat-sec-val))
                     (> our-nat-sec-val 210.0))))
          (define pvp-nat-delay-anomaly
            (and pvp-nat-delay-flag?
                 (hasheq 'nat_sec our-nat-sec-val
                         'duration_sec dur)))
          ;; W16-LOOP-2: Production idle-bank freeze (>=600M, sup_left>=10, <190 sup, 0 units trained >=45s)
          (define prod-idle-bank-freeze?
            (>= prod-idle-bank-freeze-max-sec 45.0))
          (define prod-idle-bank-freeze-anomaly
            (and prod-idle-bank-freeze?
                 (hasheq 'max_sec (round1 prod-idle-bank-freeze-max-sec)
                         'start_sec prod-idle-bank-freeze-start
                         'end_sec prod-idle-bank-freeze-end
                         'peak_min prod-idle-bank-freeze-peak-min)))
          ;; W17-LOOP-2: Gas zero-harvest freeze (>=90s w/ gas<50, >=1 ready gas bldg, workers>=20, <16 gas mined)
          (define gas-zero-harvest-freeze?
            (>= gas-zero-freeze-max-sec 90.0))
          (define gas-zero-harvest-freeze-anomaly
            (and gas-zero-harvest-freeze?
                 (hasheq 'max_sec (round1 gas-zero-freeze-max-sec)
                         'start_sec gas-zero-freeze-start
                         'end_sec gas-zero-freeze-end
                         'ready_gas gas-zero-freeze-ready-gas
                         'gas_mined gas-zero-freeze-mined)))
          ;; L19-LOOP-2: 1-Base Lockout (our_bases <= 1 && dur >= 400s) & Spire Scheduled Drop
          (define exp-saving-key
            (cond [(string=? our-race "Protoss") "nexus"]
                  [(string=? our-race "Terran") "command-center"]
                  [else "hatchery"]))
          (define exp-saving-ticks
            (hash-ref (hash-ref log-acc 'saving-counts (make-hash)) exp-saving-key 0))
          (define exp-sched-ticks (hash-ref log-acc 'exp-sched-ticks 0))
          (define one-base-lockout?
            (and (<= our-bases 1)
                 (>= dur 400.0)))
          (define one-base-lockout-anomaly
            (and one-base-lockout?
                 (hasheq 'our_bases our-bases
                         'opp_bases opp-bases
                         'duration_sec (round1 dur)
                         'exp_saving_ticks exp-saving-ticks
                         'exp_sched_ticks exp-sched-ticks)))
          (define spire-sched-ticks (hash-ref log-acc 'spire-sched-ticks 0))
          (define spire-built-cnt
            (+ (hash-ref our-bldgs-ht "Spire" 0)
               (hash-ref our-bldgs-ht "GreaterSpire" 0)))
          (define spire-sched-drop?
            (and (string=? our-race "Zerg")
                 (or (and (>= spire-sched-ticks 2) (= spire-built-cnt 0))
                     (>= spire-sched-ticks 5))))
          (define spire-sched-drop-anomaly
            (and spire-sched-drop?
                 (hasheq 'spire_sched_ticks spire-sched-ticks
                         'spire_built_cnt spire-built-cnt)))

          (define anomalies
            (hasheq 'zero_fire_retreat zero-fire-retreat-anomaly
                    'escrow_lockouts escrow-lockouts
                    'self_cancel_loops self-cancel-loops
                    'endgame_stall endgame-stall-anomaly
                    'endgame_home_stall endgame-home-stall-anomaly
                    'own_base_retreat own-base-retreat-anomaly
                    'own_territory_retreat own-terr-retreat-anomaly
                    'early_rush_idle_bank_3m early-rush-idle-bank-3m-anomaly
                    'non_combat_robo_waste non-combat-robo-waste-anomaly
                    'siege_range_zero_dps_loss siege-zero-dps-loss-anomaly
                    'cloaked_unit_damage_loss cloaked-unit-damage-loss-anomaly
                    'gas_rich_min_starved gas-rich-min-starved-anomaly
                    'gas_zero_harvest_freeze gas-zero-harvest-freeze-anomaly
                    'prod_placement_stall prod-placement-stall-anomaly
                    'prod_idle_bank_freeze prod-idle-bank-freeze-anomaly
                    'pvp_nat_delay pvp-nat-delay-anomaly
                    'one_base_lockout one-base-lockout-anomaly
                    'spire_sched_drop spire-sched-drop-anomaly
                    'air_aa_starvation air-aa-starvation))

          ;; Classify 0-combat opponent disconnects (e.g., mid-early client drop) separately from real combat wins
          (define opp-zero-combat-dc?
            (and (eq? res 'win)
                 (not opp-early-crash?)
                 (<= dur 300.0)
                 (= killed-val 0)
                 (= lost-val 0)
                 (= our-pk-army 0)
                 (= opp-pk-army 0)))
          (define opp-fault? (or opp-early-crash? opp-zero-combat-dc?))

          ;; Distinguish CPU wall-timeout ties vs 30m loop-cap ties vs combat stalls
          (define loop-cap-tie? (and (eq? res 'tie) (>= dur 1780.0)))
          (define wall-timeout-tie?
            (and (eq? res 'tie)
                 (not loop-cap-tie?)
                 (or runner-timed-out?
                     (and wall-sec
                          (>= wall-sec (if run-timeout-sec (* 0.90 run-timeout-sec) 480.0))))))
          ;; W18-LOOP-2: Winning ties clipped by CPU wall-timeout (trade >= 1.25x OR pkA >= 1.15x opp)
          (define wall-timeout-winning-tie?
            (and wall-timeout-tie?
                 (or (>= trade-ratio 1.25)
                     (and (> our-pk-army 0)
                          (>= our-pk-army (* 1.15 opp-pk-army))))))
          (define tie-cause
            (cond
              [(not (eq? res 'tie)) #f]
              [loop-cap-tie? "loop_cap_30m"]
              [(and wall-timeout-tie? (hash? endgame-stall-anomaly)) "cpu_wall_timeout_and_stall"]
              [wall-timeout-tie? "cpu_wall_timeout"]
              [(hash? endgame-stall-anomaly) "endgame_stall"]
              [else "other_tie"]))

          (define step-sorted (sort (hash-ref log-acc 'step-ms '()) <))
          (define step-p50 (percentile-sorted step-sorted 0.50))
          (define step-p95 (percentile-sorted step-sorted 0.95))
          (define log-step-max (and (pair? step-sorted) (round2 (last step-sorted))))
          (define true-step-max
            (cond
              [(and tel-max-step-ms log-step-max) (max tel-max-step-ms log-step-max)]
              [tel-max-step-ms tel-max-step-ms]
              [else log-step-max]))
          (define eff-p95-step-ms
            (or tel-p95-step-ms (and step-p95 (round2 step-p95))))
          ;; W17-LOOP-2: Wire translator p95 latency (exact if telemetry/logs emit p95_translate_ms/tr_ms,
          ;; else proportional p95 share from avg_translate_ms / avg_step_ms catching #18-style cache thrash!)
          (define tr-sorted (sort (hash-ref log-acc 'tr-ms '()) <))
          (define log-tr-p95 (percentile-sorted tr-sorted 0.95))
          (define eff-tr-p95-ms
            (or tel-p95-tr-ms
                (and log-tr-p95 (round2 log-tr-p95))
                (and tel-avg-tr-ms eff-p95-step-ms tel-avg-step-ms (> tel-avg-step-ms 0.0)
                     (round2 (max tel-avg-tr-ms (* eff-p95-step-ms (/ tel-avg-tr-ms tel-avg-step-ms)))))
                tel-avg-tr-ms))

          ;; Build crisp signatures list
          (define sigs '())
          (define (add-sig! s) (set! sigs (cons s sigs)))
          (when opp-early-crash? (add-sig! "OPP_EARLY_CRASH"))
          (when opp-zero-combat-dc? (add-sig! "OPP_ZERO_COMBAT_DC"))
          (when loop-cap-tie? (add-sig! "STALEMATE_TIE"))
          (when wall-timeout-tie?
            (add-sig! (format "WALL_TIMEOUT_TIE(~as,rt=~a/tr=~ams)"
                              (if wall-sec (r0 wall-sec) "?")
                              (if tel-avg-rt-ms (r1 tel-avg-rt-ms) "-")
                              (if tel-avg-tr-ms (r1 tel-avg-tr-ms) "-"))))
          (when wall-timeout-winning-tie?
            (add-sig! (format "WALL_TIMEOUT_WINNING_TIE(~ax)" (r2 trade-ratio))))
          (when (and true-step-max (>= true-step-max 500.0))
            (add-sig! (format "STEP_SPIKE(~ams)" (r0 true-step-max))))
          (when (and eff-tr-p95-ms (>= eff-tr-p95-ms 30.0))
            (add-sig! (format "TR_P95_SPIKE(~ams)" (r1 eff-tr-p95-ms))))
          (when endgame-stall-anomaly
            (add-sig! (if (hash-ref endgame-stall-anomaly 'creep_or_ol_blocked #f)
                          (format "ENDGAME_STALL_CREEP_OL(~am,~ab)"
                                  (hash-ref endgame-stall-anomaly 'stall_minutes)
                                  (hash-ref endgame-stall-anomaly 'surviving_win_bldgs))
                          (format "ENDGAME_STALL(~am)"
                                  (hash-ref endgame-stall-anomaly 'stall_minutes)))))
          (when endgame-home-stall-anomaly
            (add-sig! (format "ENDGAME_HOME_STALL(~as)" (r0 endgame-home-stall-sec))))
          (when own-base-retreat-anomaly
            (add-sig! (format "OWN_BASE_RETREAT(~af)" own-base-retreat-frames)))
          (when (and own-terr-retreat-anomaly
                     (> own-terr-retreat-frames own-base-retreat-frames))
            (add-sig! (format "OWN_TERR_RETREAT(~af)" own-terr-retreat-frames)))
          (when early-rush-idle-bank-3m-anomaly
            (add-sig! (format "EARLY_RUSH_IDLE_BANK_3M(~at,pk=~aM)"
                              early-rush-idle-bank-ticks
                              early-rush-idle-bank-peak-min)))
          (when non-combat-robo-waste-anomaly
            (add-sig! (format "ROBO_NONCOMBAT_WASTE(~a,Obs=~a,WP=~a)"
                              non-combat-robo-waste-val obs-built wp-built)))
          (when siege-zero-dps-loss-anomaly
            (add-sig! (format "SIEGE_ZERO_DPS_LOSS(~ax,~ad,~a)"
                              (r2 (min trade-ratio zfr-ratio))
                              (hash-ref siege-zero-dps-loss-anomaly 'our_deaths)
                              (string-join (hash-ref siege-zero-dps-loss-anomaly 'opp_siege_types) "+"))))
          (when cloaked-unit-damage-loss-anomaly
            (add-sig! (format "CLOAK_DAMAGE_LOSS(~ax,k=~a,~a)"
                              (r2 trade-ratio)
                              opp-cloak-killed-cnt
                              (string-join (hash-ref cloaked-unit-damage-loss-anomaly 'opp_cloak_types) "+"))))
          (when zero-fire-retreat-anomaly
            (add-sig! (if (hash-ref zero-fire-retreat-anomaly 'retreat_driven #f)
                          (format "SUICIDE_KITE_RETREAT(~ax,ret=~a%)"
                                  (hash-ref zero-fire-retreat-anomaly 'trade_ratio)
                                  (r0 (hash-ref zero-fire-retreat-anomaly 'avg_retreat_pct 0)))
                          (format "TRADE_COLLAPSE(~ax,~am)"
                                  (hash-ref zero-fire-retreat-anomaly 'trade_ratio)
                                  (length (hash-ref zero-fire-retreat-anomaly 'minutes))))))
          (when (pair? self-cancel-loops)
            (define c0 (car self-cancel-loops))
            (add-sig! (format "SELF_CANCEL_LOOP(~ax~a)" (hash-ref c0 'count) (hash-ref c0 'type))))
          (when air-aa-starvation
            (add-sig! (format "AIR_AA_STARVE(~aAir/AA=~a)"
                              (hash-ref air-aa-starvation 'opp_air_count)
                              (hash-ref air-aa-starvation 'our_aa_units))))
          (when (pair? escrow-lockouts)
            (define e0 (car escrow-lockouts))
            (add-sig! (format "ESCROW_LOCKOUT(~a:~a,~aM)"
                              (if (string=? (hash-ref e0 'kind) "gas_starved_min_lockout") "gas" "bank")
                              (hash-ref e0 'target)
                              (hash-ref e0 'peak_min))))
          (when gas-rich-min-starved-anomaly
            (add-sig! (format "GAS_RICH_MIN_STARVED(~at,pk=~aG)"
                              gas-rich-min-starved-ticks
                              gas-rich-min-starved-peak-gas)))
          (when prod-placement-stall-anomaly
            (add-sig! (format "PROD_PLACE_STALL(~at,~ax~a)"
                              prod-placement-stall-ticks
                              prod-placement-stall-max-streak
                              prod-placement-stall-max-bldg)))
          (when prod-idle-bank-freeze-anomaly
            (add-sig! (format "PROD_IDLE_BANK_FREEZE(~as,pk=~aM)"
                              (r0 prod-idle-bank-freeze-max-sec)
                              prod-idle-bank-freeze-peak-min)))
          (when gas-zero-harvest-freeze-anomaly
            (add-sig! (format "GAS_ZERO_HARVEST_FREEZE(~as,~ag)"
                              (r0 gas-zero-freeze-max-sec)
                              gas-zero-freeze-ready-gas)))
          (when pvp-nat-delay-anomaly
            (add-sig! (format "PVP_NAT_DELAY(~as)"
                              (if (real? our-nat-sec-val) (r0 our-nat-sec-val) "NONE"))))
          (when one-base-lockout-anomaly
            (add-sig! (format "ONE_BASE_LOCKOUT(B=~a/~a,sav=~at,sch=~at)"
                              our-bases opp-bases exp-saving-ticks exp-sched-ticks)))
          (when spire-sched-drop-anomaly
            (add-sig! (format "SPIRE_SCHED_DROP(sch=~at,built=~a)"
                              spire-sched-ticks spire-built-cnt)))
          (when (and (not (eq? res 'win)) (< trade-ratio 0.50) (>= lost-val 1500))
            (add-sig! "SEVERE_BAD_TRADES(<0.5x)"))
          (when (and (not (eq? res 'win)) (<= dur 330.0)) (add-sig! "EARLY_RUSH_LOSS"))
          (when (and our-w4 (< our-w4 22) (>= dur 260.0)) (add-sig! "EARLY_WORKER_STALL(W@4m<22)"))
          (when (and (>= dur 420.0) (< our-pk-army (* 0.45 (max 1000 opp-pk-army))))
            (add-sig! "SEVERE_ARMY_DEFICIT"))
          (when (>= sb-pct 12.0) (add-sig! "HIGH_SUPPLY_BLOCK(>=12%)"))
          (when (>= our-avg-min 900.0) (add-sig! "HIGH_UNSPENT_BANK(>=900M)"))
          (when (and (>= dur 540.0) (= upgs 0)) (add-sig! "ZERO_UPGRADES"))
          (when (> (hash-ref log-acc 'action-err-total 0) 20) (add-sig! "HIGH_ACTION_REJECTS(>20)"))
          (when (pair? (hash-ref log-acc 'crashes '())) (add-sig! "STDERR_EXCEPTION"))

          (define mid (extract-match-id-from-name bn))
          (define match-label
            (cond [mid (number->string mid)]
                  [(> (string-length bn) 16) (substring bn 0 16)]
                  [else bn]))

          (hasheq 'id match-label
                  'file bn
                  'map_name map-name
                  'our_bot our-bot
                  'opp_bot opp-bot
                  'opp_cohort opp-cohort
                  'our_race our-race
                  'opp_race opp-race
                  'matchup matchup
                  'result (symbol->string res)
                  'opp_early_crash opp-early-crash?
                  'opp_zero_combat_dc opp-zero-combat-dc?
                  'opp_fault opp-fault?
                  'tie_cause tie-cause
                  'wall_timeout_tie wall-timeout-tie?
                  'wall_timeout_winning_tie wall-timeout-winning-tie?
                  'wall_sec wall-sec
                  'duration_sec dur
                  'killed_val killed-val
                  'lost_val lost-val
                  'trade_ratio trade-ratio
                  'our_bases our-bases
                  'opp_bases opp-bases
                  'our_w2 our-w2 'opp_w2 opp-w2
                  'our_w4 our-w4 'opp_w4 opp-w4
                  'our_w6 our-w6 'opp_w6 opp-w6
                  'our_w8 our-w8 'opp_w8 opp-w8
                  'our_w10 our-w10 'opp_w10 opp-w10
                  'army_to_worker_4m a2w-4m
                  'army_to_worker_6m a2w-6m
                  'army_to_worker_8m a2w-8m
                  'army_to_worker_10m a2w-10m
                  'first_scout_sec first-scout-sec
                  'first_scout_cross_sec first-scout-cross-sec
                  'enemy_first_seen_sec enemy-first-seen-sec
                  'first_scout_unit first-scout-unit-type
                  'first_scout_unit_type first-scout-unit-type
                  'opening_bo opening-bo
                  'opening_bo_sequence opening-seq5
                  'opening_seq5 opening-seq5
                  'upgrade_timings upg-timings-imm
                  'our_peak_workers our-pk-w
                  'opp_peak_workers opp-pk-w
                  'our_peak_army our-pk-army
                  'opp_peak_army opp-pk-army
                  'our_peak_supply our-pk-sup
                  'opp_peak_supply opp-pk-sup
                  'our_avg_min our-avg-min
                  'our_avg_gas our-avg-gas
                  'our_peak_min our-pk-min
                  'our_peak_gas our-pk-gas
                  'upgrades upgs
                  'supply_block_pct sb-pct
                  'macro_timings macro-timings
                  'our_top_units (for/list ([p (in-list (top-k-pairs our-units-ht 6))])
                                   (format "~a:~a" (car p) (cdr p)))
                  'opp_top_units (for/list ([p (in-list (top-k-pairs opp-units-ht 6))])
                                   (format "~a:~a" (car p) (cdr p)))
                  'our_top_bldgs (for/list ([p (in-list (top-k-pairs our-bldgs-ht 6))])
                                   (format "~a:~a" (car p) (cdr p)))
                  'surviving_enemy_win_bldgs surv-win-total
                  'surviving_enemy_win_locs (reverse surv-win-locs)
                  'surviving_enemy_nonwin (for/list ([p (in-list (top-k-pairs surv-nonwin-ht 5))])
                                            (format "~a:~a" (car p) (cdr p)))
                  'anomalies anomalies
                  'has_logs (hash-ref log-acc 'has-logs? #f)
                  'action_rejects (hash-ref log-acc 'action-err-total 0)
                  'action_err_top (for/list ([p (in-list (top-k-pairs (hash-ref log-acc 'action-err-counts) 4))])
                                    (list (car p) (cdr p)))
                  'pos_attack (hash-ref log-acc 'pos-attack 0)
                  'pos_hold (hash-ref log-acc 'pos-hold 0)
                  'pos_retreat (hash-ref log-acc 'pos-retreat 0)
                  'endgame_home_stall_sec endgame-home-stall-sec
                  'own_base_retreat_frames own-base-retreat-frames
                  'own_base_retreat_ticks own-base-retreat-ticks
                  'own_territory_retreat_frames own-terr-retreat-frames
                  'own_territory_retreat_ticks own-terr-retreat-ticks
                  'early_rush_idle_bank_3m early-rush-idle-bank-3m?
                  'early_rush_idle_bank_ticks early-rush-idle-bank-ticks
                  'early_rush_idle_bank_peak_min early-rush-idle-bank-peak-min
                  'non_combat_robo_waste_val non-combat-robo-waste-val
                  'zerg_non_ling_army_pct zerg-non-ling-army-pct
                  'siege_range_zero_dps_loss siege-zero-dps-loss?
                  'cloaked_unit_damage_loss cloaked-unit-damage-loss?
                  'opp_cloak_killed_cnt opp-cloak-killed-cnt
                  'army_val_4m_ratio_vs_pro army-val-4m-ratio-vs-pro
                  'army_val_8m_ratio_vs_pro army-val-8m-ratio-vs-pro
                  'gas_rich_min_starved_ticks gas-rich-min-starved-ticks
                  'gas_rich_min_starved gas-rich-min-starved?
                  'prod_placement_stall_ticks prod-placement-stall-ticks
                  'prod_placement_stall_max_streak prod-placement-stall-max-streak
                  'prod_placement_stall prod-placement-stall?
                  'prod_idle_bank_freeze prod-idle-bank-freeze?
                  'prod_idle_bank_freeze_sec (round1 prod-idle-bank-freeze-max-sec)
                  'prod_idle_bank_freeze_peak_min prod-idle-bank-freeze-peak-min
                  'gas_zero_harvest_freeze gas-zero-harvest-freeze?
                  'gas_zero_harvest_freeze_sec (round1 gas-zero-freeze-max-sec)
                  'gas_zero_harvest_freeze_ready_gas gas-zero-freeze-ready-gas
                  'pvp_nat_delay_flag pvp-nat-delay-flag?
                  'one_base_lockout one-base-lockout?
                  'one_base_lockout_exp_saving_ticks exp-saving-ticks
                  'one_base_lockout_exp_sched_ticks exp-sched-ticks
                  'spire_sched_drop spire-sched-drop?
                  'spire_sched_ticks spire-sched-ticks
                  'spire_built_cnt spire-built-cnt
                  'map_symmetry_kind map-symmetry-kind
                  't3_first_sec t3-first-sec
                  't3_first_bldg t3-first-bldg
                  't3_bases_at_start t3-bases-at-start
                  't3_premature_starve t3-premature-starve?
                  'hexp_high (hash-ref log-acc 'hexp-high 0)
                  'rush_high (hash-ref log-acc 'rush-high 0)
                  'saving_top (for/list ([p (in-list (top-k-pairs (hash-ref log-acc 'saving-counts) 5))])
                                (list (car p) (cdr p)))
                  'blocked_top (for/list ([p (in-list (top-k-pairs (hash-ref log-acc 'blocked-counts) 5))])
                                 (list (car p) (cdr p)))
                  'max_escrow_streak_len (hash-ref log-acc 'max-escrow-streak-len 0)
                  'max_escrow_streak_target (hash-ref log-acc 'max-escrow-streak-target "none")
                  'avg_obs_ms tel-avg-obs-ms
                  'avg_runtime_ms tel-avg-rt-ms
                  'avg_translate_ms tel-avg-tr-ms
                  'tr_p95_ms eff-tr-p95-ms
                  'avg_step_ms tel-avg-step-ms
                  'p95_step_ms eff-p95-step-ms
                  'max_step_ms true-step-max
                  'step_p50 (and step-p50 (round2 step-p50))
                  'step_p95 eff-p95-step-ms
                  'step_max true-step-max
                  'log_step_max log-step-max
                  'crashes (reverse (hash-ref log-acc 'crashes '()))
                  'signatures (reverse sigs))))))

;; -----------------------------------------------------------------------------
;; Parallel Worker Place Entrypoint
;; -----------------------------------------------------------------------------

(define (score-batch-worker-main ch)
  (define job (place-channel-get ch))
  (define paths (first job))
  (define meta-alist (second job))
  (define bot-prefix (third job))
  (define meta-tbl (make-hash meta-alist))
  (define results
    (for/list ([pstr (in-list paths)])
      (define p (string->path pstr))
      (define bn (path->string (file-name-from-path p)))
      (define stem (regexp-replace RX-REPLAY-EXT bn ""))
      (define mid (extract-match-id-from-name bn))
      (define meta (or (and mid (hash-ref meta-tbl mid #f))
                       (hash-ref meta-tbl bn #f)
                       (hash-ref meta-tbl stem #f)
                       (hasheq)))
      (parse-and-score-single-pass p meta bot-prefix)))
  (place-channel-put ch results))

(define (score-replays-parallel replays meta-tbl bot-prefix jobs)
  (define n (length replays))
  (define eff-jobs (max 1 (min jobs (max 1 (quotient n 2)))))
  (cond
    [(or (<= eff-jobs 1) (<= n 3) (not (place-enabled?)))
     (for/list ([p (in-list replays)])
       (define bn (path->string (file-name-from-path p)))
       (define stem (regexp-replace RX-REPLAY-EXT bn ""))
       (define mid (extract-match-id-from-name bn))
       (define meta (or (and mid (hash-ref meta-tbl mid #f))
                        (hash-ref meta-tbl bn #f)
                        (hash-ref meta-tbl stem #f)
                        (hasheq)))
       (parse-and-score-single-pass p meta bot-prefix))]
    [else
     (define meta-alist (hash->list meta-tbl))
     (define path-strs (map path->string replays))
     ;; Round-robin sharding balances long ties across workers!
     (define buckets (make-vector eff-jobs '()))
     (for ([ps (in-list path-strs)] [i (in-naturals)])
       (define bi (modulo i eff-jobs))
       (vector-set! buckets bi (cons ps (vector-ref buckets bi))))
     (define active-buckets
       (for/list ([b (in-vector buckets)] #:when (pair? b))
         (reverse b)))
     (define places
       (for/list ([chunk (in-list active-buckets)])
         (define p (dynamic-place THIS-MODULE 'score-batch-worker-main))
         (place-channel-put p (list chunk meta-alist bot-prefix))
         p))
     (define out (apply append (for/list ([p (in-list places)]) (place-channel-get p))))
     (for ([p (in-list places)]) (place-wait p))
     (sort out string<? #:key (lambda (r) (format "~a" (hash-ref r 'file ""))))]))

;; -----------------------------------------------------------------------------
;; Structured Aggregation (All, Clean, Per-Race, Per-Matchup, Anomalies)
;; -----------------------------------------------------------------------------

(define (aggregate-slice rows)
  (define n (length rows))
  (if (= n 0)
      (hasheq 'n 0)
      (let ()
        (define wins (count (lambda (r) (equal? (hash-ref r 'result "") "win")) rows))
        (define losses (count (lambda (r) (equal? (hash-ref r 'result "") "loss")) rows))
        (define ties (count (lambda (r) (equal? (hash-ref r 'result "") "tie")) rows))
        (define tot-k (for/sum ([r (in-list rows)]) (hash-ref r 'killed_val 0)))
        (define tot-l (for/sum ([r (in-list rows)]) (hash-ref r 'lost_val 0)))
        (define agg-tr (round2 (/ (+ tot-k 100.0) (+ tot-l 100.0))))
        (define tr-sorted (sort (map (lambda (r) (exact->inexact (hash-ref r 'trade_ratio 0.0))) rows) <))
        (define med-tr (round2 (or (percentile-sorted tr-sorted 0.50) 0.0)))
        (define (avg-field k)
          (round1 (/ (for/sum ([r (in-list rows)]) (exact->inexact (safe-num (hash-ref r k 0) 0))) n)))
        (define (avg-field2 k)
          (round2 (/ (for/sum ([r (in-list rows)]) (exact->inexact (safe-num (hash-ref r k 0) 0))) n)))
        (define (avg-opt k)
          (define vs (filter real? (map (lambda (r) (hash-ref r k #f)) rows)))
          (and (pair? vs) (round1 (/ (apply + vs) (length vs)))))
        (define (avg-opt2 k)
          (define vs (filter real? (map (lambda (r) (hash-ref r k #f)) rows)))
          (and (pair? vs) (round2 (/ (apply + vs) (length vs)))))
        (define (max-opt k)
          (define vs (filter real? (map (lambda (r) (hash-ref r k #f)) rows)))
          (and (pair? vs) (round1 (apply max vs))))
        (define (max-opt2 k)
          (define vs (filter real? (map (lambda (r) (hash-ref r k #f)) rows)))
          (and (pair? vs) (round2 (apply max vs))))
        (define (timing-dist k)
          (num-dist (map (lambda (r) (hash-ref (hash-ref r 'macro_timings (hasheq)) k #f)) rows)))
        ;; Anomaly counts
        (define (anom-cnt pred)
          (count (lambda (r) (pred (hash-ref r 'anomalies (hasheq)))) rows))
        (define sig-ht (make-hash))
        (for ([r (in-list rows)])
          (for ([s (in-list (hash-ref r 'signatures '()))])
            (define base-s (car (string-split s "(")))
            (hash-update! sig-ht base-s add1 0)))
        (define wall-timeout-ties (count (lambda (r) (eq? (hash-ref r 'wall_timeout_tie #f) #t)) rows))
        (define wall-timeout-winning-ties (count (lambda (r) (eq? (hash-ref r 'wall_timeout_winning_tie #f) #t)) rows))
        (define opp-zero-combat-dcs (count (lambda (r) (eq? (hash-ref r 'opp_zero_combat_dc #f) #t)) rows))
        (define step-spike-500-cnt
          (count (lambda (r) (let ([v (hash-ref r 'step_max #f)]) (and (real? v) (>= v 500.0)))) rows))
        (define scout-unit-ht (make-hash))
        (define open-seq-ht (make-hash))
        (define map-sym-ht (make-hash))
        (for ([r (in-list rows)])
          (define su (hash-ref r 'first_scout_unit_type #f))
          (when (string? su) (hash-update! scout-unit-ht su add1 0))
          (define oseq (hash-ref r 'opening_seq5 #f))
          (when (string? oseq) (hash-update! open-seq-ht oseq add1 0))
          (define ms (hash-ref r 'map_symmetry_kind #f))
          (when (string? ms) (hash-update! map-sym-ht ms add1 0)))
        (hasheq 'n n
                'wins wins 'losses losses 'ties ties
                'win_rate_pct (round1 (* 100.0 (/ wins n)))
                'non_loss_pct (round1 (* 100.0 (/ (+ wins ties) n)))
                'killed_val tot-k 'lost_val tot-l
                'trade_agg agg-tr 'trade_med med-tr
                'avg_dur_sec (avg-field 'duration_sec)
                'avg_wall_sec (avg-opt 'wall_sec)
                'avg_obs_ms (avg-opt2 'avg_obs_ms)
                'avg_runtime_ms (avg-opt2 'avg_runtime_ms)
                'avg_translate_ms (avg-opt2 'avg_translate_ms)
                'avg_tr_p95_ms (avg-opt2 'tr_p95_ms)
                'worst_tr_p95_ms (max-opt2 'tr_p95_ms)
                'avg_step_ms (avg-opt2 'avg_step_ms)
                'avg_p95_step_ms (avg-opt2 'p95_step_ms)
                'max_step_ms (max-opt 'step_max)
                'step_spike_500ms_count step-spike-500-cnt
                'wall_timeout_ties wall-timeout-ties
                'wall_timeout_winning_ties wall-timeout-winning-ties
                'opp_zero_combat_dcs opp-zero-combat-dcs
                'endgame_home_stall_count (count (lambda (r) (>= (safe-num (hash-ref r 'endgame_home_stall_sec 0.0) 0.0) 90.0)) rows)
                'avg_endgame_home_stall_sec (avg-field 'endgame_home_stall_sec)
                'total_own_base_retreat_frames (for/sum ([r (in-list rows)]) (hash-ref r 'own_base_retreat_frames 0))
                'own_base_retreat_matches (count (lambda (r) (>= (hash-ref r 'own_base_retreat_frames 0) 440)) rows)
                'total_own_territory_retreat_frames (for/sum ([r (in-list rows)]) (hash-ref r 'own_territory_retreat_frames 0))
                'own_territory_retreat_matches (count (lambda (r) (>= (hash-ref r 'own_territory_retreat_frames 0) 440)) rows)
                'early_rush_idle_bank_3m_losses (count (lambda (r) (eq? (hash-ref r 'early_rush_idle_bank_3m #f) #t)) rows)
                'total_non_combat_robo_waste_val (for/sum ([r (in-list rows)]) (hash-ref r 'non_combat_robo_waste_val 0))
                'non_combat_robo_waste_matches (count (lambda (r) (>= (hash-ref r 'non_combat_robo_waste_val 0) 500)) rows)
                'avg_zerg_non_ling_army_pct (avg-opt 'zerg_non_ling_army_pct)
                'siege_range_zero_dps_losses (count (lambda (r) (eq? (hash-ref r 'siege_range_zero_dps_loss #f) #t)) rows)
                'cloaked_unit_damage_losses (count (lambda (r) (eq? (hash-ref r 'cloaked_unit_damage_loss #f) #t)) rows)
                'army_val_4m_ratio_vs_pro
                (let ([vs (sort (filter real? (map (lambda (r) (hash-ref r 'army_val_4m_ratio_vs_pro #f)) rows)) <)])
                  (and (pair? vs) (round2 (percentile-sorted vs 0.50))))
                'army_val_4m_ratio_vs_pro_mean (avg-opt2 'army_val_4m_ratio_vs_pro)
                'army_val_8m_ratio_vs_pro
                (let ([vs (sort (filter real? (map (lambda (r) (hash-ref r 'army_val_8m_ratio_vs_pro #f)) rows)) <)])
                  (and (pair? vs) (round2 (percentile-sorted vs 0.50))))
                'army_val_8m_ratio_vs_pro_mean (avg-opt2 'army_val_8m_ratio_vs_pro)
                'total_gas_rich_min_starved_ticks (for/sum ([r (in-list rows)]) (hash-ref r 'gas_rich_min_starved_ticks 0))
                'gas_rich_min_starved_matches (count (lambda (r) (eq? (hash-ref r 'gas_rich_min_starved #f) #t)) rows)
                'total_prod_placement_stall_ticks (for/sum ([r (in-list rows)]) (hash-ref r 'prod_placement_stall_ticks 0))
                'prod_placement_stall_matches (count (lambda (r) (eq? (hash-ref r 'prod_placement_stall #f) #t)) rows)
                'prod_idle_bank_freeze_matches (count (lambda (r) (eq? (hash-ref r 'prod_idle_bank_freeze #f) #t)) rows)
                'gas_zero_harvest_freeze_matches (count (lambda (r) (eq? (hash-ref r 'gas_zero_harvest_freeze #f) #t)) rows)
                'pvp_nat_delay_matches (count (lambda (r) (eq? (hash-ref r 'pvp_nat_delay_flag #f) #t)) rows)
                'one_base_lockout_matches (count (lambda (r) (eq? (hash-ref r 'one_base_lockout #f) #t)) rows)
                'spire_sched_drop_matches (count (lambda (r) (eq? (hash-ref r 'spire_sched_drop #f) #t)) rows)
                't3_started_matches (count (lambda (r) (real? (hash-ref r 't3_first_sec #f))) rows)
                't3_early_2base_matches (count (lambda (r) (let ([b (hash-ref r 't3_bases_at_start #f)]) (and (exact-integer? b) (<= b 2)))) rows)
                't3_premature_starve_matches (count (lambda (r) (eq? (hash-ref r 't3_premature_starve #f) #t)) rows)
                'map_symmetry_counts (for/list ([p (in-list (top-k-pairs map-sym-ht 6))]) (list (car p) (cdr p)))
                'our_bases (avg-field2 'our_bases)
                'opp_bases (avg-field2 'opp_bases)
                'our_w2 (avg-opt 'our_w2) 'opp_w2 (avg-opt 'opp_w2)
                'our_w4 (avg-opt 'our_w4) 'opp_w4 (avg-opt 'opp_w4)
                'our_w6 (avg-opt 'our_w6) 'opp_w6 (avg-opt 'opp_w6)
                'our_w8 (avg-opt 'our_w8) 'opp_w8 (avg-opt 'opp_w8)
                'our_w10 (avg-opt 'our_w10) 'opp_w10 (avg-opt 'opp_w10)
                'our_peak_workers (avg-field 'our_peak_workers)
                'opp_peak_workers (avg-field 'opp_peak_workers)
                'our_peak_army (round1 (avg-field 'our_peak_army))
                'opp_peak_army (round1 (avg-field 'opp_peak_army))
                'our_peak_supply (avg-field 'our_peak_supply)
                'opp_peak_supply (avg-field 'opp_peak_supply)
                'our_avg_min (avg-field 'our_avg_min)
                'our_avg_gas (avg-field 'our_avg_gas)
                'supply_block_pct (avg-field 'supply_block_pct)
                'upgrades (avg-field 'upgrades)
                'action_rejects (for/sum ([r (in-list rows)]) (hash-ref r 'action_rejects 0))
                'logged (count (lambda (r) (hash-ref r 'has_logs #f)) rows)
                'first_scout_unit_counts (for/list ([p (in-list (top-k-pairs scout-unit-ht 6))])
                                           (list (car p) (cdr p)))
                'top_opening_sequences (for/list ([p (in-list (top-k-pairs open-seq-ht 5))])
                                         (list (car p) (cdr p)))
                'macro_timing_dists
                (hasheq 'w2m (timing-dist 'w2m)
                        'w4m (timing-dist 'w4m)
                        'w6m (timing-dist 'w6m)
                        'w8m (timing-dist 'w8m)
                        'w10m (timing-dist 'w10m)
                        'nat_sec (timing-dist 'nat_sec)
                        'third_sec (timing-dist 'third_sec)
                        'gas1_sec (timing-dist 'gas1_sec)
                        'gas2_sec (timing-dist 'gas2_sec)
                        'supply1_sec (timing-dist 'supply1_sec)
                        'prod1_sec (timing-dist 'prod1_sec)
                        'prod2_sec (timing-dist 'prod2_sec)
                        'prod3_sec (timing-dist 'prod3_sec)
                        'tech1_sec (timing-dist 'tech1_sec)
                        'tech2_sec (timing-dist 'tech2_sec)
                        't3_first_sec (timing-dist 't3_first_sec)
                        'orbital1_sec (timing-dist 'orbital1_sec)
                        'lair_sec (timing-dist 'lair_sec)
                        'bases_4m (timing-dist 'bases_4m)
                        'bases_6m (timing-dist 'bases_6m)
                        'bases_8m (timing-dist 'bases_8m)
                        'bases_10m (timing-dist 'bases_10m)
                        'prod_cnt_4m (timing-dist 'prod_cnt_4m)
                        'prod_cnt_6m (timing-dist 'prod_cnt_6m)
                        'prod_cnt_8m (timing-dist 'prod_cnt_8m)
                        'prod_cnt_10m (timing-dist 'prod_cnt_10m)
                        'prod_count_4m (timing-dist 'prod_count_4m)
                        'prod_count_6m (timing-dist 'prod_count_6m)
                        'prod_count_8m (timing-dist 'prod_count_8m)
                        'prod_count_10m (timing-dist 'prod_count_10m)
                        'primary_prod_4m (timing-dist 'primary_prod_4m)
                        'primary_prod_6m (timing-dist 'primary_prod_6m)
                        'primary_prod_8m (timing-dist 'primary_prod_8m)
                        'primary_prod_10m (timing-dist 'primary_prod_10m)
                        'tech_prod_4m (timing-dist 'tech_prod_4m)
                        'tech_prod_6m (timing-dist 'tech_prod_6m)
                        'tech_prod_8m (timing-dist 'tech_prod_8m)
                        'tech_prod_10m (timing-dist 'tech_prod_10m)
                        'queens_4m (timing-dist 'queens_4m)
                        'queens_6m (timing-dist 'queens_6m)
                        'queens_8m (timing-dist 'queens_8m)
                        'queens_10m (timing-dist 'queens_10m)
                        'army_val_2m (timing-dist 'army_val_2m)
                        'army_val_4m (timing-dist 'army_val_4m)
                        'army_val_6m (timing-dist 'army_val_6m)
                        'army_val_8m (timing-dist 'army_val_8m)
                        'army_val_10m (timing-dist 'army_val_10m)
                        'army_sup_2m (timing-dist 'army_sup_2m)
                        'army_sup_4m (timing-dist 'army_sup_4m)
                        'army_sup_6m (timing-dist 'army_sup_6m)
                        'army_sup_8m (timing-dist 'army_sup_8m)
                        'army_sup_10m (timing-dist 'army_sup_10m)
                        'army_to_worker_4m (timing-dist 'army_to_worker_4m)
                        'army_to_worker_6m (timing-dist 'army_to_worker_6m)
                        'army_to_worker_8m (timing-dist 'army_to_worker_8m)
                        'army_to_worker_10m (timing-dist 'army_to_worker_10m)
                        'army_val_4m_ratio_vs_pro (timing-dist 'army_val_4m_ratio_vs_pro)
                        'army_val_8m_ratio_vs_pro (timing-dist 'army_val_8m_ratio_vs_pro)
                        'first_scout_sec (timing-dist 'first_scout_sec)
                        'first_scout_cross_sec (timing-dist 'first_scout_cross_sec)
                        'enemy_first_seen_sec (timing-dist 'enemy_first_seen_sec)
                        'warpgate_sec (timing-dist 'warpgate_sec)
                        'blink_sec (timing-dist 'blink_sec)
                        'charge_sec (timing-dist 'charge_sec)
                        'stim_sec (timing-dist 'stim_sec)
                        'combat_shield_sec (timing-dist 'combat_shield_sec)
                        'concussive_sec (timing-dist 'concussive_sec)
                        'ling_speed_sec (timing-dist 'ling_speed_sec)
                        'bane_speed_sec (timing-dist 'bane_speed_sec)
                        'roach_speed_sec (timing-dist 'roach_speed_sec)
                        'plus1_atk_sec (timing-dist 'plus1_atk_sec)
                        'plus1_arm_sec (timing-dist 'plus1_arm_sec)
                        'first_combat_upg_sec (timing-dist 'first_combat_upg_sec))
                'anomaly_counts
                (hasheq 'zero_fire_retreat (anom-cnt (lambda (a) (and (hash? (hash-ref a 'zero_fire_retreat #f)) #t)))
                        'suicide_kite_retreat
                        (anom-cnt (lambda (a)
                                    (define z (hash-ref a 'zero_fire_retreat #f))
                                    (and (hash? z) (eq? (hash-ref z 'retreat_driven #f) #t))))
                        'escrow_lockout (anom-cnt (lambda (a) (pair? (hash-ref a 'escrow_lockouts '()))))
                        'self_cancel_loop (anom-cnt (lambda (a) (pair? (hash-ref a 'self_cancel_loops '()))))
                        'endgame_stall (anom-cnt (lambda (a) (and (hash? (hash-ref a 'endgame_stall #f)) #t)))
                        'endgame_home_stall (anom-cnt (lambda (a) (and (hash? (hash-ref a 'endgame_home_stall #f)) #t)))
                        'own_base_retreat (anom-cnt (lambda (a) (and (hash? (hash-ref a 'own_base_retreat #f)) #t)))
                        'own_territory_retreat (anom-cnt (lambda (a) (and (hash? (hash-ref a 'own_territory_retreat #f)) #t)))
                        'early_rush_idle_bank_3m (anom-cnt (lambda (a) (and (hash? (hash-ref a 'early_rush_idle_bank_3m #f)) #t)))
                        'non_combat_robo_waste (anom-cnt (lambda (a) (and (hash? (hash-ref a 'non_combat_robo_waste #f)) #t)))
                        'siege_range_zero_dps_losses (anom-cnt (lambda (a) (and (hash? (hash-ref a 'siege_range_zero_dps_loss #f)) #t)))
                        'cloaked_unit_damage_losses (anom-cnt (lambda (a) (and (hash? (hash-ref a 'cloaked_unit_damage_loss #f)) #t)))
                        'gas_rich_min_starved (anom-cnt (lambda (a) (and (hash? (hash-ref a 'gas_rich_min_starved #f)) #t)))
                        'gas_zero_harvest_freeze (anom-cnt (lambda (a) (and (hash? (hash-ref a 'gas_zero_harvest_freeze #f)) #t)))
                        'prod_placement_stall (anom-cnt (lambda (a) (and (hash? (hash-ref a 'prod_placement_stall #f)) #t)))
                        'prod_idle_bank_freeze (anom-cnt (lambda (a) (and (hash? (hash-ref a 'prod_idle_bank_freeze #f)) #t)))
                        'pvp_nat_delay (anom-cnt (lambda (a) (and (hash? (hash-ref a 'pvp_nat_delay #f)) #t)))
                        'one_base_lockout (anom-cnt (lambda (a) (and (hash? (hash-ref a 'one_base_lockout #f)) #t)))
                        'spire_sched_drop (anom-cnt (lambda (a) (and (hash? (hash-ref a 'spire_sched_drop #f)) #t)))
                        'air_aa_starvation (anom-cnt (lambda (a) (and (hash? (hash-ref a 'air_aa_starvation #f)) #t)))
                        'wall_timeout_tie wall-timeout-ties
                        'wall_timeout_winning_tie wall-timeout-winning-ties
                        'step_spike_500ms step-spike-500-cnt
                        'tr_p95_spike_30ms (count (lambda (r) (let ([v (hash-ref r 'tr_p95_ms #f)]) (and (real? v) (>= v 30.0)))) rows)
                        'opp_zero_combat_dc opp-zero-combat-dcs)
                'top_signatures (for/list ([p (in-list (top-k-pairs sig-ht 6))])
                                  (list (car p) (cdr p)))))))

(define (print-agg-line label agg)
  (when (> (hash-ref agg 'n 0) 0)
    (define ac (hash-ref agg 'anomaly_counts (hasheq)))
    (printf "  ~a (n=~a): ~aW-~aL-~aT (Win=~a%, NonLoss=~a%) | Trade: agg=~ax med=~ax (~a/~a)\n"
            label (hash-ref agg 'n)
            (hash-ref agg 'wins) (hash-ref agg 'losses) (hash-ref agg 'ties)
            (r1 (hash-ref agg 'win_rate_pct)) (r1 (hash-ref agg 'non_loss_pct))
            (r2 (hash-ref agg 'trade_agg)) (r2 (hash-ref agg 'trade_med))
            (hash-ref agg 'killed_val) (hash-ref agg 'lost_val))
    (printf "    Dur=~a | Base=~a/~a | W@4m=~a/~a W@6m=~a/~a | PkW=~a/~a | PkArmy=~a/~a | Bank=~aM/~aG | SB=~a% | Upg=~a\n"
            (fmt-mmss (hash-ref agg 'avg_dur_sec 0))
            (r2 (hash-ref agg 'our_bases 0)) (r2 (hash-ref agg 'opp_bases 0))
            (if (hash-ref agg 'our_w4 #f) (r1 (hash-ref agg 'our_w4)) "-")
            (if (hash-ref agg 'opp_w4 #f) (r1 (hash-ref agg 'opp_w4)) "-")
            (if (hash-ref agg 'our_w6 #f) (r1 (hash-ref agg 'our_w6)) "-")
            (if (hash-ref agg 'opp_w6 #f) (r1 (hash-ref agg 'opp_w6)) "-")
            (r1 (hash-ref agg 'our_peak_workers 0)) (r1 (hash-ref agg 'opp_peak_workers 0))
            (r0 (hash-ref agg 'our_peak_army 0)) (r0 (hash-ref agg 'opp_peak_army 0))
            (r0 (hash-ref agg 'our_avg_min 0)) (r0 (hash-ref agg 'our_avg_gas 0))
            (r1 (hash-ref agg 'supply_block_pct 0)) (r1 (hash-ref agg 'upgrades 0)))
    (define rt-ms (hash-ref agg 'avg_runtime_ms #f))
    (define tr-ms (hash-ref agg 'avg_translate_ms #f))
    (define tr95-ms (hash-ref agg 'worst_tr_p95_ms #f))
    (define p95-ms (hash-ref agg 'avg_p95_step_ms #f))
    (define mx-ms (hash-ref agg 'max_step_ms #f))
    (define lat-str
      (if (or rt-ms tr-ms mx-ms)
          (format " | Lat(rt/tr/tr95max/p95/max)=~a/~a/~a/~a/~ams | WallTies=~a(Win=~a) | Spikes>=500=~a"
                  (if rt-ms (r1 rt-ms) "-")
                  (if tr-ms (r1 tr-ms) "-")
                  (if tr95-ms (r1 tr95-ms) "-")
                  (if p95-ms (r1 p95-ms) "-")
                  (if mx-ms (r0 mx-ms) "-")
                  (hash-ref agg 'wall_timeout_ties 0)
                  (hash-ref agg 'wall_timeout_winning_ties 0)
                  (hash-ref agg 'step_spike_500ms_count 0))
          ""))
    (printf "    Anomalies: SuicideKite=~a(Collapse=~a) | EscrowLock=~a | SelfCancel=~a | EndgameStall=~a | AirAAStarve=~a | 1BaseLock=~a | SpireDrop=~a~a\n"
            (hash-ref ac 'suicide_kite_retreat 0)
            (hash-ref ac 'zero_fire_retreat 0)
            (hash-ref ac 'escrow_lockout 0)
            (hash-ref ac 'self_cancel_loop 0)
            (hash-ref ac 'endgame_stall 0)
            (hash-ref ac 'air_aa_starvation 0)
            (hash-ref ac 'one_base_lockout 0)
            (hash-ref ac 'spire_sched_drop 0)
            lat-str)))

;; -----------------------------------------------------------------------------
;; `--compare <baseline.json>` Diff Printer (Works with v1 & v2 JSONs!)
;; -----------------------------------------------------------------------------

(define (extract-slice-from-json js slice-key)
  (define ov (hash-ref js 'overall #f))
  (cond
    [(and (hash? ov) (hash-has-key? ov slice-key))
     (hash-ref ov slice-key)]
    [(and (hash? (hash-ref js 'by_race #f)) (hash-has-key? (hash-ref js 'by_race) slice-key))
     (hash-ref (hash-ref js 'by_race) slice-key)]
    [else
     ;; Fallback for v1 JSONs without precomputed `overall`/`by_race`: aggregate `matches` directly!
     (define ms (hash-ref js 'matches '()))
     (define filtered
       (case slice-key
         [(all) ms]
         [(clean) (filter (lambda (m)
                            (not (or (eq? (hash-ref m 'opp_early_crash #f) #t)
                                     (and (equal? (hash-ref m 'result "") "win")
                                          (<= (safe-num (hash-ref m 'duration_sec 999.0) 999.0) 15.0)))))
                          ms)]
         [else (filter (lambda (m)
                         (and (equal? (hash-ref m 'our_race "") (symbol->string slice-key))
                              (not (or (eq? (hash-ref m 'opp_early_crash #f) #t)
                                       (and (equal? (hash-ref m 'result "") "win")
                                            (<= (safe-num (hash-ref m 'duration_sec 999.0) 999.0) 15.0))))))
                       ms)]))
     (aggregate-slice filtered)]))

(define (fmt-delta cur base [prec 1] [suffix ""])
  (if (and (real? cur) (real? base))
      (let* ([d (- cur base)]
             [sgn (if (>= d 0) "+" "")])
        (format "~a->~a(~a~a~a)"
                (~r base #:precision prec) (~r cur #:precision prec)
                sgn (~r d #:precision prec) suffix))
      "-"))

(define (print-compare-table base-path cur-json)
  (with-handlers ([exn:fail? (lambda (e) (printf "\n[WARN] Could not load --compare ~a: ~a\n" base-path (exn-message e)))])
    (define base-js (call-with-input-file base-path read-json))
    (printf "\n================================================================================================================================\n")
    (printf "  BEFORE -> AFTER COMPARISON vs ~a\n" base-path)
    (printf "================================================================================================================================\n")
    (printf "~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a\n"
            (pad-r "Slice" 12) (pad-r "W-L-T (Base->Cur)" 19) (pad-r "TradeAgg" 18)
            (pad-r "W@4m" 16) (pad-r "W@6m" 16) (pad-r "PkArmy" 18)
            (pad-r "Bases" 18) (pad-r "SupBlk%" 18) "Upgs")
    (printf "~a\n" (make-string 146 #\-))
    (for ([entry (in-list '((all . "ALL") (clean . "CLEAN") (Protoss . "Protoss(cl)") (Terran . "Terran(cl)") (Zerg . "Zerg(cl)")))])
      (define sk (car entry))
      (define lbl (cdr entry))
      (define b (extract-slice-from-json base-js sk))
      (define c (extract-slice-from-json cur-json sk))
      (when (and (> (hash-ref b 'n 0) 0) (> (hash-ref c 'n 0) 0))
        (define wlt (format "~a-~a-~a -> ~a-~a-~a"
                            (hash-ref b 'wins) (hash-ref b 'losses) (hash-ref b 'ties)
                            (hash-ref c 'wins) (hash-ref c 'losses) (hash-ref c 'ties)))
        (printf "~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a\n"
                (pad-r lbl 12)
                (pad-r wlt 19)
                (pad-r (fmt-delta (hash-ref c 'trade_agg) (hash-ref b 'trade_agg) 2 "x") 18)
                (pad-r (fmt-delta (hash-ref c 'our_w4) (hash-ref b 'our_w4) 1) 16)
                (pad-r (fmt-delta (hash-ref c 'our_w6) (hash-ref b 'our_w6) 1) 16)
                (pad-r (fmt-delta (hash-ref c 'our_peak_army) (hash-ref b 'our_peak_army) 0) 18)
                (pad-r (fmt-delta (hash-ref c 'our_bases) (hash-ref b 'our_bases) 2) 18)
                (pad-r (fmt-delta (hash-ref c 'supply_block_pct) (hash-ref b 'supply_block_pct) 1 "%") 18)
                (fmt-delta (hash-ref c 'upgrades) (hash-ref b 'upgrades) 1))))))

;; -----------------------------------------------------------------------------
;; Detailed Automatic Forensic Anomaly Dossier (`--anomalies`)
;; -----------------------------------------------------------------------------

(define (print-anomaly-dossier rows)
  (printf "\n================================================================================================================================\n")
  (printf "  AUTOMATIC FORENSIC ANOMALY DOSSIER (Single-Pass Detectors)\n")
  (printf "================================================================================================================================\n")
  (define (section title items fmt-fn)
    (printf "\n--- ~a (n=~a) ---\n" title (length items))
    (for ([it (in-list items)]) (fmt-fn it)))

  (section "1. Zero-Fire / Suicide-Kite Retreat Collapse Windows"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'zero_fire_retreat #f))) rows)
           (lambda (r)
             (define z (hash-ref (hash-ref r 'anomalies) 'zero_fire_retreat))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | mins=~a | K/L=~a/~a (~ax) deaths/kills=~a/~a | avgRetreat=~a% ~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref z 'minutes) (hash-ref z 'killed_val) (hash-ref z 'lost_val)
                     (r2 (hash-ref z 'trade_ratio)) (hash-ref z 'deaths) (hash-ref z 'kills)
                     (or (hash-ref z 'avg_retreat_pct) "-")
                     (if (hash-ref z 'retreat_driven) "[RETREAT-DRIVEN]" ""))))

  (section "2. Mineral / Gas Escrow Lockout Windows"
           (filter (lambda (r) (pair? (hash-ref (hash-ref r 'anomalies) 'escrow_lockouts '()))) rows)
           (lambda (r)
             (define es (hash-ref (hash-ref r 'anomalies) 'escrow_lockouts))
             (printf "  #~a ~a v ~a ~a(~a): ~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (hash-ref r 'opp_bot)
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (string-join
                      (for/list ([w (in-list (take es (min 3 (length es))))])
                        (format "~a(~a, ~a-~as, ~a ticks, pk=~aM~a)"
                                (hash-ref w 'kind) (hash-ref w 'target)
                                (r0 (hash-ref w 'start_sec)) (r0 (hash-ref w 'end_sec))
                                (hash-ref w 'ticks) (hash-ref w 'peak_min)
                                (if (hash-has-key? w 'min_gas) (format ",minG=~a" (hash-ref w 'min_gas)) "")))
                      "; "))))

  (section "3. Structure Self-Cancel Loops (>=3 rapid self-cancels in same region)"
           (filter (lambda (r) (pair? (hash-ref (hash-ref r 'anomalies) 'self_cancel_loops '()))) rows)
           (lambda (r)
             (for ([c (in-list (hash-ref (hash-ref r 'anomalies) 'self_cancel_loops))])
               (printf "  #~a ~a v ~a: ~a x~a near (~a,~a) during ~a-~as\n"
                       (hash-ref r 'id) (hash-ref r 'our_bot) (hash-ref r 'opp_bot)
                       (hash-ref c 'type) (hash-ref c 'count) (hash-ref c 'x) (hash-ref c 'y)
                       (r0 (hash-ref c 'start_sec)) (r0 (hash-ref c 'end_sec))))))

  (section "4. Endgame Stall / Idle-Army-While-Ahead Windows"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'endgame_stall #f))) rows)
           (lambda (r)
             (define s (hash-ref (hash-ref r 'anomalies) 'endgame_stall))
             (printf "  #~a ~a v ~a ~a(~a): stalled ~am (m~a-m~a, pkArmy=~a) | wall=~as rt/tr=~a/~ams | survWinBldgs=~a ~a | nonWin=~a ~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (hash-ref r 'opp_bot)
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref s 'stall_minutes) (hash-ref s 'start_min) (hash-ref s 'end_min)
                     (hash-ref s 'peak_army_during_stall)
                     (or (hash-ref r 'wall_sec) "-")
                     (if (hash-ref r 'avg_runtime_ms #f) (r1 (hash-ref r 'avg_runtime_ms)) "-")
                     (if (hash-ref r 'avg_translate_ms #f) (r1 (hash-ref r 'avg_translate_ms)) "-")
                     (hash-ref s 'surviving_win_bldgs)
                     (hash-ref s 'surviving_win_locs) (hash-ref r 'surviving_enemy_nonwin)
                     (if (hash-ref s 'creep_or_ol_blocked) "[CREEP/OL-BLOCKED]" ""))))

  (section "5. Air-Threat vs AA/Tech Starvation"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'air_aa_starvation #f))) rows)
           (lambda (r)
             (define a (hash-ref (hash-ref r 'anomalies) 'air_aa_starvation))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a): oppAir=~a (1st@~as ~a) | ourAA=~a aaTech@~a lair@~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref a 'opp_air_count) (r0 (hash-ref a 'opp_air_first_sec))
                     (hash-ref a 'opp_air_types) (hash-ref a 'our_aa_units)
                     (or (hash-ref a 'our_aa_tech_sec) "NONE")
                     (or (hash-ref a 'our_lair_sec) "NONE"))))

  (section "6. CPU Wall-Timeout Ties, Step Spikes (>=500ms), Wire tr_p95 (>=30ms) & Opp Zero-Combat DCs"
           (filter (lambda (r)
                     (or (eq? (hash-ref r 'wall_timeout_tie #f) #t)
                         (let ([mx (hash-ref r 'step_max #f)]) (and (real? mx) (>= mx 500.0)))
                         (let ([tr95 (hash-ref r 'tr_p95_ms #f)]) (and (real? tr95) (>= tr95 30.0)))
                         (eq? (hash-ref r 'opp_zero_combat_dc #f) #t)
                         (eq? (hash-ref r 'opp_early_crash #f) #t)))
                   rows)
           (lambda (r)
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | wall=~as | rt/tr/tr95/p95/max=~a/~a/~a/~a/~ams | tieCause=~a~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (or (hash-ref r 'wall_sec) "-")
                     (if (hash-ref r 'avg_runtime_ms #f) (r1 (hash-ref r 'avg_runtime_ms)) "-")
                     (if (hash-ref r 'avg_translate_ms #f) (r1 (hash-ref r 'avg_translate_ms)) "-")
                     (if (hash-ref r 'tr_p95_ms #f) (r1 (hash-ref r 'tr_p95_ms)) "-")
                     (if (hash-ref r 'p95_step_ms #f) (r1 (hash-ref r 'p95_step_ms)) "-")
                     (if (hash-ref r 'step_max #f) (r0 (hash-ref r 'step_max)) "-")
                     (or (hash-ref r 'tie_cause) "-")
                     (cond
                       [(eq? (hash-ref r 'opp_early_crash #f) #t) " [OPP_EARLY_CRASH]"]
                       [(eq? (hash-ref r 'opp_zero_combat_dc #f) #t) " [OPP_ZERO_COMBAT_DC]"]
                       [(eq? (hash-ref r 'wall_timeout_winning_tie #f) #t) " [WINNING_TIE]"]
                       [(let ([tr95 (hash-ref r 'tr_p95_ms #f)]) (and (real? tr95) (>= tr95 30.0))) " [TR_P95_SPIKE]"]
                       [else ""]))))

  (section "7. Gas-Rich / Mineral-Starved Production Stalls (>=30 ticks of gas>=200 & min<100)"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'gas_rich_min_starved #f))) rows)
           (lambda (r)
             (define g (hash-ref (hash-ref r 'anomalies) 'gas_rich_min_starved))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | ticks=~a | pkG=~a | avgBank=~aM/~aG\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref g 'ticks) (hash-ref g 'peak_gas)
                     (r0 (hash-ref g 'avg_min 0)) (r0 (hash-ref g 'avg_gas 0)))))

  (section "8. Early-Rush Idle Bank Losses (pre-3:30 min>=250 & army_sup<=4)"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'early_rush_idle_bank_3m #f))) rows)
           (lambda (r)
             (define e (hash-ref (hash-ref r 'anomalies) 'early_rush_idle_bank_3m))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | ticks=~a (post100=~a) | pkM=~aM\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref e 'ticks) (hash-ref e 'post100_ticks) (hash-ref e 'peak_min))))

  (section "9. Production Placement Stalls (>=30t or >=8-streak <5m w/ >=150M) & PvP Nat Delays (>210s)"
           (filter (lambda (r)
                     (or (hash? (hash-ref (hash-ref r 'anomalies) 'prod_placement_stall #f))
                         (hash? (hash-ref (hash-ref r 'anomalies) 'pvp_nat_delay #f))))
                   rows)
           (lambda (r)
             (define ps (hash-ref (hash-ref r 'anomalies) 'prod_placement_stall #f))
             (define pn (hash-ref (hash-ref r 'anomalies) 'pvp_nat_delay #f))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | ~a~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (if (hash? ps)
                         (format "ProdStall=~at (maxStreak=~a ~a ~a)"
                                 (hash-ref ps 'ticks) (hash-ref ps 'max_streak)
                                 (hash-ref ps 'top_bldg) (hash-ref ps 'by_bldg))
                         "")
                     (if (hash? pn)
                         (format "~aPvPNatDelay=~as"
                                 (if (hash? ps) " | " "")
                                 (or (hash-ref pn 'nat_sec) "NONE"))
                         ""))))

  (section "10. Production Idle-Bank Freezes (>=600M, sup_left>=10, <190 sup, 0 units trained >=45s)"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'prod_idle_bank_freeze #f))) rows)
           (lambda (r)
             (define fz (hash-ref (hash-ref r 'anomalies) 'prod_idle_bank_freeze))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | freeze=~as (~as-~as) | pkM=~aM\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (r1 (hash-ref fz 'max_sec 0.0))
                     (or (hash-ref fz 'start_sec #f) "?")
                     (or (hash-ref fz 'end_sec #f) "?")
                     (hash-ref fz 'peak_min 0))))

  (section "11. Gas Zero-Harvest Freezes (>=90s w/ gas<50, >=1 ready gas bldg, workers>=20, <16 gas mined)"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'gas_zero_harvest_freeze #f))) rows)
           (lambda (r)
             (define gz (hash-ref (hash-ref r 'anomalies) 'gas_zero_harvest_freeze))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | freeze=~as (~as-~as) | readyGas=~a | mined=~aG\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (r1 (hash-ref gz 'max_sec 0.0))
                     (or (hash-ref gz 'start_sec #f) "?")
                     (or (hash-ref gz 'end_sec #f) "?")
                     (hash-ref gz 'ready_gas 0)
                     (r1 (hash-ref gz 'gas_mined 0.0)))))

  (section "12. 1-Base Lockouts (our_bases<=1 & dur>=400s)"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'one_base_lockout #f))) rows)
           (lambda (r)
             (define ob (hash-ref (hash-ref r 'anomalies) 'one_base_lockout))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | Bases=~a/~a | expSav=~at | expSched=~at\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref ob 'our_bases 1)
                     (hash-ref ob 'opp_bases 0)
                     (hash-ref ob 'exp_saving_ticks 0)
                     (hash-ref ob 'exp_sched_ticks 0))))

  (section "13. Spire Scheduled Drops (Zerg sched=(spire@) >=200M/200G w/ 0 built or >=5 retries)"
           (filter (lambda (r) (hash? (hash-ref (hash-ref r 'anomalies) 'spire_sched_drop #f))) rows)
           (lambda (r)
             (define sd (hash-ref (hash-ref r 'anomalies) 'spire_sched_drop))
             (printf "  #~a ~a(~a) v ~a(~a) ~a(~a) | spireSched=~at | spireBuilt=~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
                     (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref sd 'spire_sched_ticks 0)
                     (hash-ref sd 'spire_built_cnt 0)))))

;; -----------------------------------------------------------------------------
;; Main CLI Driver
;; -----------------------------------------------------------------------------

(module+ main
  (define t0 (current-inexact-milliseconds))
  (define bot-prefix "Mothman")
  (define json-out #f)
  (define compare-path #f)
  (define show-anomalies? #f)
  (define verbose? #f)
  (define jobs 'auto)

  (define target-dir
    (command-line
     #:program "score-replay-batch.rkt"
     #:once-each
     [("--bot-prefix") pfx "Substring identifying our bot (default: Mothman)" (set! bot-prefix pfx)]
     [("--json") path "Write structured v2 JSON report" (set! json-out path)]
     [("--compare") path "Compare against a baseline JSON report" (set! compare-path path)]
     [("--anomalies") "Print detailed automatic forensic anomaly dossier" (set! show-anomalies? #t)]
     [("--verbose") "Print per-match units, buildings, and log breakdown" (set! verbose? #t)]
     [("-j" "--jobs") n "Parallel worker places (default: auto = 1 for <=50 replays, 4 for larger batches)"
                      (set! jobs (max 1 (or (string->number n) 1)))]
     #:args (dir)
     dir))

  (unless (directory-exists? target-dir)
    (eprintf "Error: directory not found: ~a\n" target-dir)
    (exit 1))

  (define meta-tbl (load-summary-meta-map target-dir))
  (define replays
    (sort (filter (lambda (p) (string-suffix? (path->string p) ".SC2Replay"))
                  (find-files file-exists? target-dir))
          string<? #:key path->string))

  (when (null? replays)
    (eprintf "No .SC2Replay files found under ~a\n" target-dir)
    (exit 1))

  (define eff-jobs
    (if (eq? jobs 'auto)
        (if (> (length replays) 50) (min 4 (max 1 (processor-count))) 1)
        jobs))
  (define raw-results (score-replays-parallel replays meta-tbl bot-prefix eff-jobs))
  (define mirrors (filter (lambda (r) (eq? (hash-ref r 'skip #f) 'mirror)) raw-results))
  (define errors (filter (lambda (r) (hash-has-key? r 'error)) raw-results))
  (define scored
    (filter (lambda (r) (and (not (hash-has-key? r 'skip)) (not (hash-has-key? r 'error))))
            raw-results))
  (define clean-scored
    (filter (lambda (r)
              (not (or (hash-ref r 'opp_fault #f)
                       (hash-ref r 'opp_early_crash #f)
                       (hash-ref r 'opp_zero_combat_dc #f))))
            scored))

  (define elapsed-ms (inexact->exact (round (- (current-inexact-milliseconds) t0))))

  (printf "================================================================================================================================\n")
  (printf "  REPLAY BATCH FORENSIC SCOREBOARD: ~a  (replays=~a, scored=~a, clean=~a, mirror=~a, err=~a, ~ams @ j=~a)\n"
          target-dir (length replays) (length scored) (length clean-scored) (length mirrors) (length errors) elapsed-ms eff-jobs)
  (printf "================================================================================================================================\n")
  (printf "~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a\n"
          (pad-r "ID/Match" 9) (pad-r "Bot(R) vs Opp(R)" 31) (pad-r "Res(Time)" 10)
          (pad-r "Trade(K/L)" 17) (pad-r "Base" 5) (pad-r "W@4m" 5) (pad-r "W@6m" 5)
          (pad-r "PkW" 5) (pad-r "PkArmy" 11) (pad-r "Bank(Avg)" 9)
          (pad-r "SB%" 5) (pad-r "Rej" 4) "Top Signatures")
  (printf "~a\n" (make-string 142 #\-))

  (for ([r (in-list scored)])
    (define matchup-str
      (format "~a(~a) v ~a(~a)"
              (hash-ref r 'our_bot) (race-initial (hash-ref r 'our_race))
              (hash-ref r 'opp_bot) (race-initial (hash-ref r 'opp_race))))
    (define res-str
      (format "~a(~a)"
              (string-upcase (substring (hash-ref r 'result "?") 0 1))
              (fmt-mmss (hash-ref r 'duration_sec 0))))
    (define tr-str (format "~ax(~a/~a)" (r2 (hash-ref r 'trade_ratio))
                           (hash-ref r 'killed_val) (hash-ref r 'lost_val)))
    (define base-str (format "~a/~a" (hash-ref r 'our_bases) (hash-ref r 'opp_bases)))
    (define w4-str (if (hash-ref r 'our_w4) (format "~a/~a" (hash-ref r 'our_w4) (or (hash-ref r 'opp_w4) "-")) "-"))
    (define w6-str (if (hash-ref r 'our_w6) (format "~a/~a" (hash-ref r 'our_w6) (or (hash-ref r 'opp_w6) "-")) "-"))
    (define pkw-str (format "~a/~a" (hash-ref r 'our_peak_workers) (hash-ref r 'opp_peak_workers)))
    (define pka-str (format "~a/~a" (hash-ref r 'our_peak_army) (hash-ref r 'opp_peak_army)))
    (define bnk-str (format "~a/~a" (r0 (hash-ref r 'our_avg_min)) (r0 (hash-ref r 'our_avg_gas))))
    (define sb-str (format "~a%" (r1 (hash-ref r 'supply_block_pct))))
    (define rej-str (if (hash-ref r 'has_logs) (number->string (hash-ref r 'action_rejects)) "-"))
    (define sig-str (string-join (take (hash-ref r 'signatures) (min 3 (length (hash-ref r 'signatures)))) ", "))
    (printf "~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a\n"
            (pad-r (hash-ref r 'id) 9) (pad-r matchup-str 31) (pad-r res-str 10)
            (pad-r tr-str 17) (pad-r base-str 5) (pad-r w4-str 5) (pad-r w6-str 5)
            (pad-r pkw-str 5) (pad-r pka-str 11) (pad-r bnk-str 9)
            (pad-r sb-str 5) (pad-r rej-str 4) sig-str)
    (when verbose?
      (define mt (hash-ref r 'macro_timings))
      (printf "    Timings: Sup1@~a Prod1@~a Gas1@~a Tech1@~a Nat@~a 3rd@~a OC1@~a | Units: ~a | Opp: ~a\n"
              (or (hash-ref mt 'supply1_sec) "-") (or (hash-ref mt 'prod1_sec) "-")
              (or (hash-ref mt 'gas1_sec) "-") (or (hash-ref mt 'tech1_sec) "-")
              (or (hash-ref mt 'nat_sec) "-") (or (hash-ref mt 'third_sec) "-")
              (or (hash-ref mt 'orbital1_sec) "-")
              (string-join (hash-ref r 'our_top_units) " ")
              (string-join (hash-ref r 'opp_top_units) " "))
      (when (hash-ref r 'has_logs)
        (printf "    [LOG] pos(atk/hld/ret)=~a/~a/~a step(p50/p95)=~a/~ams saving=~a blocked=~a\n"
                (hash-ref r 'pos_attack) (hash-ref r 'pos_hold) (hash-ref r 'pos_retreat)
                (or (hash-ref r 'step_p50) "-") (or (hash-ref r 'step_p95) "-")
                (hash-ref r 'saving_top) (hash-ref r 'blocked_top)))))

  ;; Compute all structured aggregates
  (define agg-all (aggregate-slice scored))
  (define agg-clean (aggregate-slice clean-scored))
  (define by-race
    (for/hasheq ([rc (in-list '("Protoss" "Terran" "Zerg"))])
      (values (string->symbol rc)
              (aggregate-slice (filter (lambda (r) (string=? (hash-ref r 'our_race) rc)) clean-scored)))))
  (define by-matchup
    (for/hasheq ([mu (in-list '("PvP" "PvT" "PvZ" "TvP" "TvT" "TvZ" "ZvP" "ZvT" "ZvZ"))])
      (values (string->symbol mu)
              (aggregate-slice (filter (lambda (r) (string=? (hash-ref r 'matchup) mu)) clean-scored)))))
  (define by-result
    (for/hasheq ([rs (in-list '("win" "loss" "tie"))])
      (values (string->symbol rs)
              (aggregate-slice (filter (lambda (r) (string=? (hash-ref r 'result) rs)) clean-scored)))))
  ;; W9-LOOP-2: 54-match full-roster generalization cohort split (`core_12` vs `unseen_6`)
  (define core12-rows (filter (lambda (r) (equal? (hash-ref r 'opp_cohort "core_12") "core_12")) clean-scored))
  (define unseen6-rows (filter (lambda (r) (equal? (hash-ref r 'opp_cohort "core_12") "unseen_6")) clean-scored))
  (define unseen6-all-rows (filter (lambda (r) (equal? (hash-ref r 'opp_cohort "core_12") "unseen_6")) scored))
  (define agg-core12 (aggregate-slice core12-rows))
  (define agg-unseen6 (aggregate-slice unseen6-rows))
  (define by-cohort (hasheq 'core_12 agg-core12 'unseen_6 agg-unseen6))
  ;; W14-LOOP-2: Per-opponent `unseen_6_breakdown` for 54-match full-roster ship scorecard
  (define unseen6-opps
    (sort (remove-duplicates (map (lambda (r) (hash-ref r 'opp_bot "Unknown")) unseen6-all-rows))
          string-ci<?))
  (define unseen6-breakdown
    (for/hasheq ([opp (in-list unseen6-opps)])
      (define all-rs (filter (lambda (r) (equal? (hash-ref r 'opp_bot "") opp)) unseen6-all-rows))
      (define cl-rs (filter (lambda (r) (equal? (hash-ref r 'opp_bot "") opp)) unseen6-rows))
      (define agg (aggregate-slice cl-rs))
      (define faults (- (length all-rs) (length cl-rs)))
      (define race-summary
        (string-join
         (for/list ([rc (in-list '("Protoss" "Terran" "Zerg"))])
           (define rs-rc (filter (lambda (r) (string=? (hash-ref r 'our_race "") rc)) cl-rs))
           (if (null? rs-rc)
               (format "~a:-" (race-initial rc))
               (format "~a:~a"
                       (race-initial rc)
                       (string-join
                        (map (lambda (r) (string-upcase (substring (hash-ref r 'result "?") 0 1))) rs-rc)
                        ""))))
         " "))
      (values (string->symbol opp)
              (hasheq 'opp_bot opp
                      'n (length cl-rs)
                      'n_total (length all-rs)
                      'opp_faults faults
                      'wins (hash-ref agg 'wins 0)
                      'losses (hash-ref agg 'losses 0)
                      'ties (hash-ref agg 'ties 0)
                      'win_rate_pct (hash-ref agg 'win_rate_pct 0.0)
                      'non_loss_pct (hash-ref agg 'non_loss_pct 0.0)
                      'trade_agg (hash-ref agg 'trade_agg 0.0)
                      'trade_med (hash-ref agg 'trade_med 0.0)
                      'killed_val (hash-ref agg 'killed_val 0)
                      'lost_val (hash-ref agg 'lost_val 0)
                      'cloak_loss (hash-ref agg 'cloaked_unit_damage_losses 0)
                      'siege_0dps (hash-ref agg 'siege_range_zero_dps_losses 0)
                      'supply_block_pct (hash-ref agg 'supply_block_pct 0.0)
                      'our_peak_army (hash-ref agg 'our_peak_army 0.0)
                      'avg_dur_sec (hash-ref agg 'avg_dur_sec 0.0)
                      'by_race race-summary))))

  (printf "\n================================================================================================================================\n")
  (printf "  AGGREGATE SUMMARY (Clean excludes opponent loop<=300 crashes & 0-combat disconnects)\n")
  (printf "================================================================================================================================\n")
  (print-agg-line "ALL_MATCHES  " agg-all)
  (when (< (length clean-scored) (length scored))
    (print-agg-line "CLEAN_MATCHES" agg-clean))
  (when (pair? unseen6-all-rows)
    (print-agg-line "COHORT=CORE12" agg-core12)
    (print-agg-line "COHORT=UNSEEN" agg-unseen6)
    (printf "\n  UNSEEN-6 GENERALIZATION BREAKDOWN (n_clean=~a / n_total=~a):\n"
            (length unseen6-rows) (length unseen6-all-rows))
    (for ([opp (in-list unseen6-opps)])
      (define b (hash-ref unseen6-breakdown (string->symbol opp)))
      (printf "    ~a | ~aW-~aL-~aT (n=~a/~a, ~a) | TradeAgg=~ax (~a/~a) | CloakLoss=~a | Siege0=~a | PkArmy=~a | SB=~a%\n"
              (pad-r opp 18)
              (hash-ref b 'wins) (hash-ref b 'losses) (hash-ref b 'ties)
              (hash-ref b 'n) (hash-ref b 'n_total) (hash-ref b 'by_race)
              (r2 (hash-ref b 'trade_agg)) (hash-ref b 'killed_val) (hash-ref b 'lost_val)
              (hash-ref b 'cloak_loss) (hash-ref b 'siege_0dps)
              (r0 (hash-ref b 'our_peak_army)) (r1 (hash-ref b 'supply_block_pct)))))
  (for ([rc (in-list '(Protoss Terran Zerg))])
    (print-agg-line (format "RACE=~a" (pad-r rc 8)) (hash-ref by-race rc)))
  (for ([rs (in-list '(win loss tie))])
    (print-agg-line (format "RES=~a" (pad-r (string-upcase (symbol->string rs)) 9)) (hash-ref by-result rs)))

  ;; Aggregate log telemetry
  (define logged-rows (filter (lambda (r) (hash-ref r 'has_logs #f)) scored))
  (define log-telemetry
    (if (null? logged-rows)
        (hasheq 'logged_matches 0)
        (let ([g-sav (make-hash)] [g-blk (make-hash)] [g-err (make-hash)])
          (for ([r (in-list logged-rows)])
            (for ([p (in-list (hash-ref r 'saving_top '()))])
              (hash-update! g-sav (first p) (lambda (o) (+ o (second p))) 0))
            (for ([p (in-list (hash-ref r 'blocked_top '()))])
              (hash-update! g-blk (first p) (lambda (o) (+ o (second p))) 0))
            (for ([p (in-list (hash-ref r 'action_err_top '()))])
              (hash-update! g-err (first p) (lambda (o) (+ o (second p))) 0)))
          (define p50s (sort (filter real? (map (lambda (r) (hash-ref r 'step_p50 #f)) logged-rows)) <))
          (define p95s (sort (filter real? (map (lambda (r) (hash-ref r 'step_p95 #f)) logged-rows)) <))
          (define lt
            (hasheq 'logged_matches (length logged-rows)
                    'pos_attack (for/sum ([r (in-list logged-rows)]) (hash-ref r 'pos_attack 0))
                    'pos_hold (for/sum ([r (in-list logged-rows)]) (hash-ref r 'pos_hold 0))
                    'pos_retreat (for/sum ([r (in-list logged-rows)]) (hash-ref r 'pos_retreat 0))
                    'hexp_high (for/sum ([r (in-list logged-rows)]) (hash-ref r 'hexp_high 0))
                    'rush_high (for/sum ([r (in-list logged-rows)]) (hash-ref r 'rush_high 0))
                    'action_rejects_total (for/sum ([r (in-list logged-rows)]) (hash-ref r 'action_rejects 0))
                    'step_ms_p50_med (and (pair? p50s) (round2 (percentile-sorted p50s 0.50)))
                    'step_ms_p95_med (and (pair? p95s) (round2 (percentile-sorted p95s 0.50)))
                    'top_saving_for (for/list ([p (in-list (top-k-pairs g-sav 8))]) (list (car p) (cdr p)))
                    'top_blocked_by_escrow (for/list ([p (in-list (top-k-pairs g-blk 8))]) (list (car p) (cdr p)))
                    'top_action_errors (for/list ([p (in-list (top-k-pairs g-err 8))]) (list (car p) (cdr p)))))
          (printf "\n  AGGREGATE LOG TELEMETRY (logged=~a/~a | step p50=~ams p95=~ams):\n"
                  (length logged-rows) (length scored)
                  (or (hash-ref lt 'step_ms_p50_med) "-") (or (hash-ref lt 'step_ms_p95_med) "-"))
          (printf "    [SCBOT_STATE]    pos(atk/hld/ret)=~a/~a/~a | hexp>=0.7=~a | rush>=0.5=~a\n"
                  (hash-ref lt 'pos_attack) (hash-ref lt 'pos_hold) (hash-ref lt 'pos_retreat)
                  (hash-ref lt 'hexp_high) (hash-ref lt 'rush_high))
          (printf "    [SCBOT_PRIORITY] top saving_for=~a\n" (hash-ref lt 'top_saving_for))
          (printf "    [SCBOT_PRIORITY] top blocked=~a\n" (hash-ref lt 'top_blocked_by_escrow))
          lt)))

  (when show-anomalies?
    (print-anomaly-dossier scored))

  (define out-json
    (hasheq 'schema_version 2
            'dir target-dir
            'elapsed_ms elapsed-ms
            'jobs eff-jobs
            'counts (hasheq 'replays (length replays)
                            'scored (length scored)
                            'clean (length clean-scored)
                            'mirror_skip (length mirrors)
                            'parse_errors (length errors))
            'overall (hasheq 'all agg-all 'clean agg-clean)
            'summary (hasheq 'core_12 agg-core12 'unseen_6 agg-unseen6 'unseen_6_breakdown unseen6-breakdown)
            'by_cohort by-cohort
            'unseen_6_breakdown unseen6-breakdown
            'by_race by-race
            'by_matchup by-matchup
            'by_result by-result
            'log_telemetry log-telemetry
            'matches scored))

  (when compare-path
    (print-compare-table compare-path out-json))

  (when json-out
    (call-with-output-file json-out
      (lambda (out) (write-json out-json out))
      #:exists 'replace)
    (printf "\nWrote v2 JSON report -> ~a\n" json-out)))
