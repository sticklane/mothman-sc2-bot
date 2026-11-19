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
(define RX-FRAME       #px"f=([0-9]+)")
(define RX-PRIO-FULL   #px"f=([0-9]+).*?bank=([0-9]+)M/([0-9]+)G sup=([0-9]+)/([0-9]+).*?saving_for=([a-z0-9-]+)\\(floor=([0-9]+)M/([0-9]+)G\\)")
(define RX-SAVING-FALL #px"saving_for=([a-z0-9-]+)")
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
          'step-ms '()
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
  (define hexp-hi (hash-ref m 'hexp-high))
  (define rush-hi (hash-ref m 'rush-high))
  (define step-ms (hash-ref m 'step-ms))
  (define err-tot (hash-ref m 'action-err-total))
  (define max-slen (hash-ref m 'max-escrow-streak-len))
  (define max-stgt (hash-ref m 'max-escrow-streak-target))
  (define cur-slen (hash-ref m 'cur-streak-len))
  (define cur-stgt (hash-ref m 'cur-streak-target))
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
       (define mf (regexp-match RX-FRAME ln))
       (define minute (if mf (quotient (or (string->number (cadr mf)) 0) 1344) 0))
       (define pvec (hash-ref! pos-by-min minute (lambda () (vector 0 0 0))))
       (cond
         [(string-contains? ln "pos=attack")
          (set! pos-atk (add1 pos-atk))
          (vector-set! pvec 0 (add1 (vector-ref pvec 0)))]
         [(string-contains? ln "pos=retreat")
          (set! pos-ret (add1 pos-ret))
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
             'hexp-high hexp-hi
             'rush-high rush-hi
             'step-ms step-ms
             'action-err-total err-tot
             'max-escrow-streak-len max-slen
             'max-escrow-streak-target max-stgt
             'cur-streak-len cur-slen
             'cur-streak-target cur-stgt
             'hb-windows (reverse (hash-ref m 'hb-windows '()))
             'gs-windows (reverse (hash-ref m 'gs-windows '()))
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
         (define ms (cond [(and (hash? js) (list? (hash-ref js 'matches #f))) (hash-ref js 'matches)]
                          [(list? js) js]
                          [else '()]))
         (for ([m (in-list ms)] #:when (hash? m))
           (define mid (or (hash-ref m 'match_id #f) (hash-ref m 'id #f)))
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
          (define tech1-sec (make-hasheqv))
          (define orbital1-sec (make-hasheqv))
          (define lair-sec (make-hasheqv))
          (define aa-tech-first-sec (make-hasheqv))
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
                   (hash-update! total-stat-ev p add1 0)
                   (when (and (>= fu fm) (< fm 200) (> gl 224))
                     (hash-update! sb-steps p add1 0))
                   (define minute (exact-floor (/ sec 60.0)))
                   (hash-set! (hash-ref stats-by-min p)
                              minute
                              (hasheq 'sec (round1 sec)
                                      'loop gl
                                      'min_cur (hash-ref st 0 0)
                                      'gas_cur (hash-ref st 1 0)
                                      'workers (hash-ref st 4 0)
                                      'food_used fu
                                      'food_made fm
                                      'army_min (hash-ref st 11 0)
                                      'army_gas (hash-ref st 14 0)
                                      'killed_min (+ (hash-ref st 23 0) (hash-ref st 24 0) (hash-ref st 25 0))
                                      'killed_gas (+ (hash-ref st 26 0) (hash-ref st 27 0) (hash-ref st 28 0)))))]
                [(1 6) ; SUnitBornEvent (1) or SUnitInitEvent (6)
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (define p (hash-ref pl 3 0))
                 (define ut (b->s (hash-ref pl 2 #"")))
                 (define ux (hash-ref pl 5 0))
                 (define uy (hash-ref pl 6 0))
                 (hash-set! unit-owner tag p)
                 (hash-set! unit-type tag ut)
                 (hash-set! unit-xy tag (cons ux uy))
                 (when (= eid 6)
                   (hash-set! unit-init-sec tag sec))
                 (when (= p opp-pid)
                   (hash-set! alive-opp tag (list ut ux uy)))
                 (when (and (> gl 0) (memv p '(1 2)))
                   ;; Macro structure timing captures
                   (when (set-member? TOWNHALL-SET ut)
                     (hash-update! th-timings p (lambda (lst) (cons (round1 sec) lst))))
                   (when (and (= eid 6) (set-member? GAS-BLDG-SET ut))
                     (hash-update! gas-timings p (lambda (lst) (cons (round1 sec) lst))))
                   (when (and (set-member? SUPPLY-BLDG-SET ut)
                              (or (= eid 6) (string=? ut "Overlord")))
                     (hash-update! sup-timings p (lambda (lst) (cons (round1 sec) lst))))
                   (when (and (set-member? PROD1-BLDG-SET ut) (not (hash-has-key? prod1-sec p)))
                     (hash-set! prod1-sec p (round1 sec)))
                   (when (and (set-member? TECH1-BLDG-SET ut) (not (hash-has-key? tech1-sec p)))
                     (hash-set! tech1-sec p (round1 sec)))
                   (when (and (set-member? AA-TECH-BLDG-SET ut) (not (hash-has-key? aa-tech-first-sec p)))
                     (hash-set! aa-tech-first-sec p (round1 sec)))
                   ;; Unit & building production counts
                   (cond
                     [(= eid 6)
                      (when (= p our-pid)
                        (if (set-member? WARPABLE-UNIT-SET ut)
                            (begin
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
                 (hash-set! unit-done tag #t)]
                [(3) ; SUnitOwnerChangeEvent
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (define p (hash-ref pl 2 0))
                 (hash-set! unit-owner tag p)
                 (if (= p opp-pid)
                     (let ([xy (hash-ref unit-xy tag '(0 . 0))])
                       (hash-set! alive-opp tag (list (hash-ref unit-type tag "?") (car xy) (cdr xy))))
                     (hash-remove! alive-opp tag))]
                [(4) ; SUnitTypeChangeEvent (morphs: Orbital, Lair, Hive, WarpGate, Ravager, Lurker, etc.)
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (define ut (b->s (hash-ref pl 2 #"")))
                 (define p (hash-ref unit-owner tag 0))
                 (when (not (string=? ut ""))
                   (hash-set! unit-type tag ut)
                   (when (= p opp-pid)
                     (define xy (hash-ref unit-xy tag '(0 . 0)))
                     (hash-set! alive-opp tag (list ut (car xy) (cdr xy))))
                   (when (and (> gl 0) (memv p '(1 2)))
                     (when (and (string=? ut "OrbitalCommand") (not (hash-has-key? orbital1-sec p)))
                       (hash-set! orbital1-sec p (round1 sec)))
                     (when (and (string=? ut "Lair") (not (hash-has-key? lair-sec p)))
                       (hash-set! lair-sec p (round1 sec))
                       (unless (hash-has-key? tech1-sec p) (hash-set! tech1-sec p (round1 sec)))
                       (unless (hash-has-key? aa-tech-first-sec p) (hash-set! aa-tech-first-sec p (round1 sec))))
                     (when (and (string=? ut "GreaterSpire") (not (hash-has-key? aa-tech-first-sec p)))
                       (hash-set! aa-tech-first-sec p (round1 sec)))))]
                [(2) ; SUnitDiedEvent
                 (define tag (bitwise-ior (arithmetic-shift (hash-ref pl 0 0) 18)
                                          (hash-ref pl 1 0)))
                 (define p (hash-ref unit-owner tag 0))
                 (define ut (hash-ref unit-type tag "?"))
                 (define killer-pid (hash-ref pl 2 #f))
                 (hash-remove! alive-opp tag)
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
                   (hash-update! upg-cnt p add1 0))])))

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

          (define our-w2 (w-at our-s 120.0)) (define opp-w2 (w-at opp-s 120.0))
          (define our-w4 (w-at our-s 240.0)) (define opp-w4 (w-at opp-s 240.0))
          (define our-w6 (w-at our-s 360.0)) (define opp-w6 (w-at opp-s 360.0))
          (define our-w8 (w-at our-s 480.0)) (define opp-w8 (w-at opp-s 480.0))
          (define a6 (army-val-at our-s 360.0))
          (define a8 (army-val-at our-s 480.0))
          (define a2w-6m (and a6 our-w6 (> our-w6 0) (round1 (/ (exact->inexact a6) our-w6))))
          (define a2w-8m (and a8 our-w8 (> our-w8 0) (round1 (/ (exact->inexact a8) our-w8))))

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

          (define macro-timings
            (hasheq 'nat_sec (and (>= (length our-ths-list) 1) (first our-ths-list))
                    'third_sec (and (>= (length our-ths-list) 2) (second our-ths-list))
                    'fourth_sec (and (>= (length our-ths-list) 3) (third our-ths-list))
                    'gas1_sec (and (>= (length our-gas-list) 1) (first our-gas-list))
                    'gas2_sec (and (>= (length our-gas-list) 2) (second our-gas-list))
                    'supply1_sec (and (>= (length our-sup-list) 1) (first our-sup-list))
                    'supply2_sec (and (>= (length our-sup-list) 2) (second our-sup-list))
                    'prod1_sec (hash-ref prod1-sec our-pid #f)
                    'tech1_sec (hash-ref tech1-sec our-pid #f)
                    'orbital1_sec (hash-ref orbital1-sec our-pid #f)
                    'lair_sec (hash-ref lair-sec our-pid #f)
                    'w2m our-w2 'w4m our-w4 'w6m our-w6 'w8m our-w8
                    'army_to_worker_6m a2w-6m 'army_to_worker_8m a2w-8m))

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

          (define anomalies
            (hasheq 'zero_fire_retreat zero-fire-retreat-anomaly
                    'escrow_lockouts escrow-lockouts
                    'self_cancel_loops self-cancel-loops
                    'endgame_stall endgame-stall-anomaly
                    'air_aa_starvation air-aa-starvation))

          ;; Build crisp signatures list
          (define sigs '())
          (define (add-sig! s) (set! sigs (cons s sigs)))
          (when (and (eq? res 'tie) (>= dur 1780.0)) (add-sig! "STALEMATE_TIE"))
          (when endgame-stall-anomaly
            (add-sig! (if (hash-ref endgame-stall-anomaly 'creep_or_ol_blocked #f)
                          (format "ENDGAME_STALL_CREEP_OL(~am,~ab)"
                                  (hash-ref endgame-stall-anomaly 'stall_minutes)
                                  (hash-ref endgame-stall-anomaly 'surviving_win_bldgs))
                          (format "ENDGAME_STALL(~am)"
                                  (hash-ref endgame-stall-anomaly 'stall_minutes)))))
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

          (define step-sorted (sort (hash-ref log-acc 'step-ms '()) <))
          (define step-p50 (percentile-sorted step-sorted 0.50))
          (define step-p95 (percentile-sorted step-sorted 0.95))
          (define step-max (and (pair? step-sorted) (round2 (last step-sorted))))
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
                  'our_race our-race
                  'opp_race opp-race
                  'matchup matchup
                  'result (symbol->string res)
                  'opp_early_crash opp-early-crash?
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
                  'army_to_worker_6m a2w-6m
                  'army_to_worker_8m a2w-8m
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
                  'hexp_high (hash-ref log-acc 'hexp-high 0)
                  'rush_high (hash-ref log-acc 'rush-high 0)
                  'saving_top (for/list ([p (in-list (top-k-pairs (hash-ref log-acc 'saving-counts) 5))])
                                (list (car p) (cdr p)))
                  'blocked_top (for/list ([p (in-list (top-k-pairs (hash-ref log-acc 'blocked-counts) 5))])
                                 (list (car p) (cdr p)))
                  'max_escrow_streak_len (hash-ref log-acc 'max-escrow-streak-len 0)
                  'max_escrow_streak_target (hash-ref log-acc 'max-escrow-streak-target "none")
                  'step_p50 (and step-p50 (round2 step-p50))
                  'step_p95 (and step-p95 (round2 step-p95))
                  'step_max step-max
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
        (hasheq 'n n
                'wins wins 'losses losses 'ties ties
                'win_rate_pct (round1 (* 100.0 (/ wins n)))
                'non_loss_pct (round1 (* 100.0 (/ (+ wins ties) n)))
                'killed_val tot-k 'lost_val tot-l
                'trade_agg agg-tr 'trade_med med-tr
                'avg_dur_sec (avg-field 'duration_sec)
                'our_bases (avg-field2 'our_bases)
                'opp_bases (avg-field2 'opp_bases)
                'our_w2 (avg-opt 'our_w2) 'opp_w2 (avg-opt 'opp_w2)
                'our_w4 (avg-opt 'our_w4) 'opp_w4 (avg-opt 'opp_w4)
                'our_w6 (avg-opt 'our_w6) 'opp_w6 (avg-opt 'opp_w6)
                'our_w8 (avg-opt 'our_w8) 'opp_w8 (avg-opt 'opp_w8)
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
                'macro_timing_dists
                (hasheq 'w2m (timing-dist 'w2m)
                        'w4m (timing-dist 'w4m)
                        'w6m (timing-dist 'w6m)
                        'w8m (timing-dist 'w8m)
                        'nat_sec (timing-dist 'nat_sec)
                        'third_sec (timing-dist 'third_sec)
                        'gas1_sec (timing-dist 'gas1_sec)
                        'supply1_sec (timing-dist 'supply1_sec)
                        'prod1_sec (timing-dist 'prod1_sec)
                        'tech1_sec (timing-dist 'tech1_sec)
                        'orbital1_sec (timing-dist 'orbital1_sec)
                        'army_to_worker_6m (timing-dist 'army_to_worker_6m)
                        'army_to_worker_8m (timing-dist 'army_to_worker_8m))
                'anomaly_counts
                (hasheq 'zero_fire_retreat (anom-cnt (lambda (a) (and (hash? (hash-ref a 'zero_fire_retreat #f)) #t)))
                        'suicide_kite_retreat
                        (anom-cnt (lambda (a)
                                    (define z (hash-ref a 'zero_fire_retreat #f))
                                    (and (hash? z) (eq? (hash-ref z 'retreat_driven #f) #t))))
                        'escrow_lockout (anom-cnt (lambda (a) (pair? (hash-ref a 'escrow_lockouts '()))))
                        'self_cancel_loop (anom-cnt (lambda (a) (pair? (hash-ref a 'self_cancel_loops '()))))
                        'endgame_stall (anom-cnt (lambda (a) (and (hash? (hash-ref a 'endgame_stall #f)) #t)))
                        'air_aa_starvation (anom-cnt (lambda (a) (and (hash? (hash-ref a 'air_aa_starvation #f)) #t))))
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
    (printf "    Anomalies: SuicideKite=~a(Collapse=~a) | EscrowLock=~a | SelfCancel=~a | EndgameStall=~a | AirAAStarve=~a\n"
            (hash-ref ac 'suicide_kite_retreat 0)
            (hash-ref ac 'zero_fire_retreat 0)
            (hash-ref ac 'escrow_lockout 0)
            (hash-ref ac 'self_cancel_loop 0)
            (hash-ref ac 'endgame_stall 0)
            (hash-ref ac 'air_aa_starvation 0))))

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
             (printf "  #~a ~a v ~a ~a(~a): stalled ~am (m~a-m~a, pkArmy=~a) | survWinBldgs=~a ~a | nonWin=~a ~a\n"
                     (hash-ref r 'id) (hash-ref r 'our_bot) (hash-ref r 'opp_bot)
                     (string-upcase (substring (hash-ref r 'result) 0 1)) (fmt-mmss (hash-ref r 'duration_sec))
                     (hash-ref s 'stall_minutes) (hash-ref s 'start_min) (hash-ref s 'end_min)
                     (hash-ref s 'peak_army_during_stall) (hash-ref s 'surviving_win_bldgs)
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
                     (or (hash-ref a 'our_lair_sec) "NONE")))))

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
    (filter (lambda (r) (not (hash-ref r 'opp_early_crash #f))) scored))

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

  (printf "\n================================================================================================================================\n")
  (printf "  AGGREGATE SUMMARY (Clean excludes opponent loop<=300 instant crashes)\n")
  (printf "================================================================================================================================\n")
  (print-agg-line "ALL_MATCHES  " agg-all)
  (when (< (length clean-scored) (length scored))
    (print-agg-line "CLEAN_MATCHES" agg-clean))
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
