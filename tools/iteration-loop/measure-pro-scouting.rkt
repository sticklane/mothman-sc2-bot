#lang racket/base
;; tools/iteration-loop/measure-pro-scouting.rkt
;;
;; Empirically extracts comprehensive Pro LotV benchmarks directly from
;; `replays/pro_corpus/*.SC2Replay` across Race & all 9 Matchups:
;;   1. Early scouting unit types & departure/arrival timings (Probe, SCV, Reaper, Overlord, Drone)
;;   2. Opening build-order sequence & median timestamps (Supply1, Prod1, Gas1, Nat, Tech1, Gas2, Prod2, 3rd)
;;   3. Production-facility count curves at 4m, 6m, 8m (Gates/Robo/SG, Rax/Fact/Port, Hatches/Queens)
;;   4. Worker, Army-Value, Army-Supply & ArmyVal/Worker curves at 2m, 4m, 6m, 8m, 10m
;;   5. Key upgrade & tech completion/start timings (WarpGate, Stim, LingSpeed, +1, Lair, Orbital, etc.)
;;
;; Usage:
;;   racket tools/iteration-loop/measure-pro-scouting.rkt [--max-replays 400] [--out-json path]

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/string
         racket/cmdline
         json
         "../../lib/sc2-mpq-replay-parser.rkt")

(define max-replays (make-parameter 400))
(define out-json (make-parameter #f))

(command-line
 #:program "measure-pro-scouting.rkt"
 #:once-each
 [("--max-replays") n "Max LotV pro replays to scan (default 400)"
                    (max-replays (string->number n))]
 [("--out-json") p "Optional path to write JSON summary"
                 (out-json p)])

(define (b->s v)
  (cond [(bytes? v) (bytes->string/utf-8 v #\?)]
        [(string? v) v]
        [else (~a v)]))

(define (dist2d x1 y1 x2 y2)
  (let ([dx (- x1 x2)] [dy (- y1 y2)])
    (sqrt (+ (* dx dx) (* dy dy)))))

(define (median xs)
  (if (null? xs)
      #f
      (let* ([s (sort xs <)]
             [n (length s)]
             [m (quotient n 2)])
        (if (odd? n)
            (list-ref s m)
            (* 0.5 (+ (list-ref s (sub1 m)) (list-ref s m)))))))

(define (pct xs p)
  (if (null? xs)
      #f
      (let* ([s (sort xs <)]
             [n (length s)]
             [idx (min (sub1 n) (max 0 (inexact->exact (floor (* p (sub1 n))))))])
        (list-ref s idx))))

(define (round1 x) (and x (/ (round (* 10.0 x)) 10.0)))

(define (canon-race r)
  (cond
    [(not (string? r)) #f]
    [(regexp-match? #rx"(?i:protoss)" r) "Protoss"]
    [(regexp-match? #rx"(?i:terran)" r) "Terran"]
    [(regexp-match? #rx"(?i:zerg)" r) "Zerg"]
    [else #f]))

(define (race-letter r)
  (cond [(string=? r "Protoss") "P"]
        [(string=? r "Terran") "T"]
        [(string=? r "Zerg") "Z"]
        [else "?"]))

(define (worker-type? u) (member u '("Probe" "SCV" "Drone")))
(define (overlord-type? u) (member u '("Overlord" "Overseer")))
(define (early-scout-unit? u)
  (member u '("Probe" "SCV" "Drone" "Overlord" "Reaper" "Adept" "Zergling" "Marine" "Stalker" "Hellion" "Phoenix" "Oracle")))

(define (canon-bldg-type u)
  (cond
    [(member u '("Gateway" "WarpGate")) "Gateway"]
    [(member u '("SupplyDepot" "SupplyDepotLowered")) "SupplyDepot"]
    [(member u '("Barracks" "BarracksFlying")) "Barracks"]
    [(member u '("Factory" "FactoryFlying")) "Factory"]
    [(member u '("Starport" "StarportFlying")) "Starport"]
    [(member u '("CommandCenter" "CommandCenterFlying" "OrbitalCommand" "OrbitalCommandFlying" "PlanetaryFortress")) "CommandCenter"]
    [(member u '("Hatchery" "Lair" "Hive")) "Hatchery"]
    [else u]))

(define (prod-bldg-for-race? race cu)
  (cond
    [(string=? race "Protoss") (member cu '("Gateway" "RoboticsFacility" "Stargate"))]
    [(string=? race "Terran")  (member cu '("Barracks" "Factory" "Starport"))]
    [(string=? race "Zerg")    (member cu '("Hatchery"))]
    [else #f]))

(define (opening-struct? u)
  (member u '("Pylon" "Gateway" "Assimilator" "CyberneticsCore" "Nexus" "RoboticsFacility" "TwilightCouncil" "Stargate" "Forge"
              "SupplyDepot" "Barracks" "Refinery" "CommandCenter" "Factory" "Starport" "EngineeringBay" "Bunker"
              "Hatchery" "SpawningPool" "Extractor" "RoachWarren" "BanelingNest" "EvolutionChamber")))

(define (upgrade-key u)
  (cond
    [(string=? u "WarpGateResearch") 'warp_gate]
    [(string=? u "Stimpack") 'stimpack]
    [(string=? u "ShieldWall") 'combat_shield]
    [(string=? u "zerglingmovementspeed") 'ling_speed]
    [(string=? u "GlialReconstitution") 'roach_speed]
    [(string=? u "BlinkTech") 'blink]
    [(string=? u "Charge") 'charge]
    [(regexp-match? #rx"GroundWeaponsLevel1|InfantryWeaponsLevel1|MeleeAttacksLevel1|MissileAttacksLevel1" u) 'plus1_atk]
    [(regexp-match? #rx"GroundArmorsLevel1|InfantryArmorsLevel1|GroundCarapaceLevel1" u) 'plus1_arm]
    [else #f]))

(define MINUTE-LOOPS '((2 . 2688) (4 . 5376) (6 . 8064) (8 . 10752) (10 . 13440)))

(define (analyze-replay path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define mpq (read-mpq-files path #:filenames '("replay.tracker.events")))
    (unless (hash? mpq) (error 'skip))
    (define trk-raw (hash-ref mpq "replay.tracker.events" #f))
    (unless trk-raw (error 'skip))

    ;; Identify actual races from starting TownHall (handles Random cleanly!)
    (define evs (decode-tracker-stream trk-raw))
    (define start-xy (make-hasheqv))
    (define pid->race (make-hasheqv))
    (define init-workers (make-hasheqv))
    (for ([ev (in-list evs)] #:break (> (car ev) 16))
      (define gl (car ev))
      (define eid (cadr ev))
      (define h (caddr ev))
      (when (= eid 1)
        (define pid (hash-ref h 3 0))
        (define ut (b->s (hash-ref h 2 #"")))
        (define x (hash-ref h 5 0))
        (define y (hash-ref h 6 0))
        (when (memv pid '(1 2))
          (cond
            [(string=? ut "Nexus") (hash-set! start-xy pid (cons (exact->inexact x) (exact->inexact y))) (hash-set! pid->race pid "Protoss")]
            [(string=? ut "CommandCenter") (hash-set! start-xy pid (cons (exact->inexact x) (exact->inexact y))) (hash-set! pid->race pid "Terran")]
            [(string=? ut "Hatchery") (hash-set! start-xy pid (cons (exact->inexact x) (exact->inexact y))) (hash-set! pid->race pid "Zerg")]
            [(worker-type? ut) (hash-update! init-workers pid add1 0)]))))
    ;; Strict LotV 12-worker filter
    (unless (and (= (hash-count start-xy) 2)
                 (= (hash-count pid->race) 2)
                 (>= (hash-ref init-workers 1 0) 11)
                 (>= (hash-ref init-workers 2 0) 11))
      (error 'skip))

    ;; Live unit tracking
    (define idx->info (make-hasheqv)) ;; tag-index -> (vector pid utype born-gl)
    (define alive-workers (make-hasheqv '((1 . 0) (2 . 0))))
    (define alive-bldgs (make-hash))  ;; (cons pid canon-bldg) -> int
    (define alive-queens (make-hasheqv '((1 . 0) (2 . 0))))

    ;; Scouting trackers (up to 4:00 = gl 5376)
    (define worker-leave-gl (make-hasheqv)) ;; pid -> (cons est-send-gl obs-gl)
    (define worker-leave-w (make-hasheqv))
    (define worker-arrive-gl (make-hasheqv))
    (define ov-leave-gl (make-hasheqv))
    (define ov-arrive-gl (make-hasheqv))
    (define reaper-arrive-gl (make-hasheqv))
    (define first-any (make-hasheqv)) ;; pid -> (list gl utype)

    ;; Opening BO sequence (first 7 structures after gl>16)
    (define bo-seq (make-hasheqv '((1 . ()) (2 . ()))))
    ;; Key tech/upgrade timestamps (sec)
    (define tech-times (make-hasheqv '((1 . ()) (2 . ())))) ;; pid -> hash
    (hash-set! tech-times 1 (make-hasheq))
    (hash-set! tech-times 2 (make-hasheq))
    (define (rec-tech! pid k gl)
      (define ht (hash-ref tech-times pid))
      (unless (hash-has-key? ht k)
        (hash-set! ht k (/ gl 22.4))))

    ;; Minute snapshots: pid -> hash(min -> hash)
    (define snaps (make-hasheqv))
    (hash-set! snaps 1 (make-hasheqv))
    (hash-set! snaps 2 (make-hasheqv))
    (define latest-stats (make-hasheqv)) ;; pid -> (list workers army-val army-sup)

    (define next-min-idx 0)
    (define (capture-minute! m)
      (for ([pid (in-list '(1 2))])
        (define race (hash-ref pid->race pid))
        (define st (hash-ref latest-stats pid #f))
        (when st
          (define w (first st))
          (define av (second st))
          (define asup (third st))
          (define prod-cnt
            (cond
              [(string=? race "Protoss")
               (+ (hash-ref alive-bldgs (cons pid "Gateway") 0)
                  (hash-ref alive-bldgs (cons pid "RoboticsFacility") 0)
                  (hash-ref alive-bldgs (cons pid "Stargate") 0))]
              [(string=? race "Terran")
               (+ (hash-ref alive-bldgs (cons pid "Barracks") 0)
                  (hash-ref alive-bldgs (cons pid "Factory") 0)
                  (hash-ref alive-bldgs (cons pid "Starport") 0))]
              [else (hash-ref alive-bldgs (cons pid "Hatchery") 0)]))
          (define gates (hash-ref alive-bldgs (cons pid "Gateway") 0))
          (define rax (hash-ref alive-bldgs (cons pid "Barracks") 0))
          (define hatches (hash-ref alive-bldgs (cons pid "Hatchery") 0))
          (define queens (hash-ref alive-queens pid 0))
          (hash-set! (hash-ref snaps pid) m
                     (hasheq 'workers w 'army_val av 'army_sup asup
                             'a2w (if (> w 0) (/ av w) 0.0)
                             'prod_cnt prod-cnt
                             'primary_prod (cond [(string=? race "Protoss") gates]
                                                 [(string=? race "Terran") rax]
                                                 [else hatches])
                             'queens queens)))))

    (for ([ev (in-list evs)] #:break (> (car ev) 14000))
      (define gl (car ev))
      (define eid (cadr ev))
      (define h (caddr ev))
      (let loop-m ()
        (when (and (< next-min-idx (length MINUTE-LOOPS))
                   (>= gl (cdr (list-ref MINUTE-LOOPS next-min-idx))))
          (capture-minute! (car (list-ref MINUTE-LOOPS next-min-idx)))
          (set! next-min-idx (add1 next-min-idx))
          (loop-m)))
      (cond
        [(= eid 0) ;; SPlayerStatsEvent (matches lib/sc2-mpq-replay-parser.rkt:878-895!)
         (define pid (hash-ref h 0 0))
         (define st (hash-ref h 1 #f))
         (when (and (memv pid '(1 2)) (hash? st))
           (define w (exact->inexact (hash-ref st 4 0)))
           (define amin (exact->inexact (hash-ref st 11 0)))
           (define agas (exact->inexact (hash-ref st 14 0)))
           (define food-used (/ (exact->inexact (hash-ref st 29 0)) 4096.0))
           (define asup (max 0.0 (- food-used w)))
           (hash-set! latest-stats pid (list w (+ amin agas) asup)))]
        [(or (= eid 1) (= eid 6)) ;; SUnitBornEvent / SUnitInitEvent
         (define tidx (hash-ref h 0 -1))
         (define pid (hash-ref h 3 0))
         (define ut (b->s (hash-ref h 2 #"")))
         (when (and (>= tidx 0) (memv pid '(1 2)))
           (hash-set! idx->info tidx (vector pid ut gl))
           (when (and (= eid 1) (worker-type? ut))
             (hash-update! alive-workers pid add1 0))
           (when (and (= eid 1) (string=? ut "Queen"))
             (hash-update! alive-queens pid add1 0))
           (define cu (canon-bldg-type ut))
           (when (or (= eid 6) (and (= eid 1) (<= gl 16) (member cu '("Hatchery" "Nexus" "CommandCenter"))))
             (when (opening-struct? cu)
               (hash-update! alive-bldgs (cons pid cu) add1 0)
               (when (> gl 16)
                 (define cur-seq (hash-ref bo-seq pid))
                 (when (< (length cur-seq) 8)
                   (hash-set! bo-seq pid (append cur-seq (list (cons cu (/ gl 22.4))))))
                 (cond
                   [(string=? cu "Factory") (rec-tech! pid 'factory gl)]
                   [(string=? cu "Starport") (rec-tech! pid 'starport gl)]
                   [(string=? cu "RoboticsFacility") (rec-tech! pid 'robo gl)]
                   [(string=? cu "TwilightCouncil") (rec-tech! pid 'twilight gl)]
                   [(string=? cu "Stargate") (rec-tech! pid 'stargate gl)]
                   [(string=? cu "CyberneticsCore") (rec-tech! pid 'cyber gl)]
                   [(string=? cu "SpawningPool") (rec-tech! pid 'pool gl)]
                   [(string=? cu "RoachWarren") (rec-tech! pid 'roach_warren gl)]
                   [(string=? cu "BanelingNest") (rec-tech! pid 'bane_nest gl)])))))]
        [(= eid 4) ;; SUnitTypeChangeEvent (Lair, Hive, Orbital, WarpGate, etc.)
         (define tidx (hash-ref h 0 -1))
         (define new-ut (b->s (hash-ref h 2 #"")))
         (define info (hash-ref idx->info tidx #f))
         (when info
           (define pid (vector-ref info 0))
           (vector-set! info 1 new-ut)
           (cond
             [(string=? new-ut "Lair") (rec-tech! pid 'lair gl)]
             [(string=? new-ut "Hive") (rec-tech! pid 'hive gl)]
             [(string=? new-ut "OrbitalCommand") (rec-tech! pid 'orbital gl)]))]
        [(= eid 5) ;; SUpgradeEvent (completion time!)
         (define pid (hash-ref h 0 0))
         (define upg (b->s (hash-ref h 1 #"")))
         (define uk (upgrade-key upg))
         (when (and (memv pid '(1 2)) uk (> gl 16))
           (rec-tech! pid uk gl))]
        [(= eid 2) ;; SUnitDiedEvent (also captures scouts killed in enemy base between SUnitPositions ticks!)
         (define tidx (hash-ref h 0 -1))
         (define info (hash-ref idx->info tidx #f))
         (when info
           (define pid (vector-ref info 0))
           (define ut (vector-ref info 1))
           (when (and (> gl 100) (<= gl 5600) (worker-type? ut))
             (define dx (exact->inexact (hash-ref h 3 0)))
             (define dy (exact->inexact (hash-ref h 4 0)))
             (define opp (if (= pid 1) 2 1))
             (define hxy (hash-ref start-xy pid))
             (define exy (hash-ref start-xy opp))
             (define d-home (dist2d dx dy (car hxy) (cdr hxy)))
             (define d-enemy (dist2d dx dy (car exy) (cdr exy)))
             (define map-d (dist2d (car hxy) (cdr hxy) (car exy) (cdr exy)))
             (when (and (> d-home 34.0) (< d-enemy (* 0.85 map-d)) (not (hash-has-key? worker-leave-gl pid)))
               (define est-send-gl (max 0 (inexact->exact (round (- gl (* 22.4 (/ (max 0.0 (- d-home 8.0)) 3.94)))))))
               (hash-set! worker-leave-gl pid (cons est-send-gl gl))
               (hash-set! worker-leave-w pid (hash-ref alive-workers pid 12)))
             (when (and (<= d-enemy 34.0) (not (hash-has-key? worker-arrive-gl pid)))
               (hash-set! worker-arrive-gl pid gl))
             (when (and (<= d-enemy 42.0) (not (hash-has-key? first-any pid)))
               (hash-set! first-any pid (list gl ut))))
           (when (worker-type? ut)
             (hash-update! alive-workers pid (lambda (v) (max 0 (sub1 v))) 0))
           (when (string=? ut "Queen")
             (hash-update! alive-queens pid (lambda (v) (max 0 (sub1 v))) 0))
           (define cu (canon-bldg-type ut))
           (when (opening-struct? cu)
             (hash-update! alive-bldgs (cons pid cu) (lambda (v) (max 0 (sub1 v))) 0)))
         (hash-remove! idx->info tidx)]
        [(and (= eid 8) (<= gl 5600)) ;; SUnitPositionsEvent (first 4:10 for scouting!)
         (define first-idx (hash-ref h 0 0))
         (define items (hash-ref h 1 '()))
         (let loop ([rem items] [cur-idx first-idx])
           (when (and (pair? rem) (pair? (cdr rem)) (pair? (cddr rem)))
             (define uidx (+ cur-idx (car rem)))
             (define ux (exact->inexact (cadr rem)))
             (define uy (exact->inexact (caddr rem)))
             (define info (hash-ref idx->info uidx #f))
             (when (and info (> gl 100))
               (define pid (vector-ref info 0))
               (define ut (vector-ref info 1))
               (define opp (if (= pid 1) 2 1))
               (define hxy (hash-ref start-xy pid))
               (define exy (hash-ref start-xy opp))
               (define d-home (dist2d ux uy (car hxy) (cdr hxy)))
               (define d-enemy (dist2d ux uy (car exy) (cdr exy)))
               (define map-d (dist2d (car hxy) (cdr hxy) (car exy) (cdr exy)))
               (define cur-w (hash-ref alive-workers pid 12))
               (when (worker-type? ut)
                 (when (and (not (hash-has-key? worker-leave-gl pid))
                            (> d-home 34.0)
                            (< d-enemy (* 0.85 map-d)))
                   (define est-send-gl (max 0 (inexact->exact (round (- gl (* 22.4 (/ (max 0.0 (- d-home 8.0)) 3.94)))))))
                   (hash-set! worker-leave-gl pid (cons est-send-gl gl))
                   (hash-set! worker-leave-w pid cur-w))
                 (when (and (not (hash-has-key? worker-arrive-gl pid))
                            (<= d-enemy 34.0))
                   (hash-set! worker-arrive-gl pid gl)))
               (when (overlord-type? ut)
                 (when (and (not (hash-has-key? ov-leave-gl pid))
                            (> d-home 28.0)
                            (< d-enemy (* 0.85 map-d)))
                   (hash-set! ov-leave-gl pid gl))
                 (when (and (not (hash-has-key? ov-arrive-gl pid))
                            (<= d-enemy 44.0))
                   (hash-set! ov-arrive-gl pid gl)))
               (when (and (string=? ut "Reaper")
                          (not (hash-has-key? reaper-arrive-gl pid))
                          (<= d-enemy 40.0))
                 (hash-set! reaper-arrive-gl pid gl))
               (when (and (not (hash-has-key? first-any pid))
                          (<= d-enemy 42.0)
                          (early-scout-unit? ut))
                 (hash-set! first-any pid (list gl ut))))
             (loop (cdddr rem) uidx)))]))

    (for/list ([pid (in-list '(1 2))])
      (define opp (if (= pid 1) 2 1))
      (define r (hash-ref pid->race pid))
      (define orace (hash-ref pid->race opp))
      (define mu (string-append (race-letter r) "v" (race-letter orace)))
      (define wl (hash-ref worker-leave-gl pid #f))
      (hasheq 'race r
              'matchup mu
              'worker_sent? (if wl #t #f)
              'worker_est_send_sec (and wl (/ (car wl) 22.4))
              'worker_arrive_sec (let ([v (hash-ref worker-arrive-gl pid #f)]) (and v (/ v 22.4)))
              'worker_cnt_at_cross (hash-ref worker-leave-w pid #f)
              'overlord_sent? (hash-has-key? ov-leave-gl pid)
              'overlord_arrive_sec (let ([v (hash-ref ov-arrive-gl pid #f)]) (and v (/ v 22.4)))
              'reaper_arrive_sec (let ([v (hash-ref reaper-arrive-gl pid #f)]) (and v (/ v 22.4)))
              'first_scout_unit (let ([v (hash-ref first-any pid #f)]) (and v (cadr v)))
              'first_scout_arrive_sec (let ([v (hash-ref first-any pid #f)]) (and v (/ (car v) 22.4)))
              'bo_seq (hash-ref bo-seq pid)
              'tech_times (hash-ref tech-times pid)
              'snaps (hash-ref snaps pid)))))

(define corpus-dir (build-path (current-directory) "replays" "pro_corpus"))
(define all-files (sort (filter (lambda (p) (regexp-match? #rx"\\.SC2Replay$" (path->string p)))
                                (directory-list corpus-dir #:build? #t))
                        string<? #:key path->string))
(define step (max 1 (quotient (length all-files) (max 1 (max-replays)))))
(define sampled
  (for/list ([f (in-list all-files)] [i (in-naturals)] #:when (= (modulo i step) 0))
    f))
(define files (take sampled (min (max-replays) (length sampled))))

(define t0 (current-inexact-milliseconds))
(define rows '())
(define ok-replays 0)
(for ([f (in-list files)])
  (define r (analyze-replay f))
  (when r
    (set! ok-replays (add1 ok-replays))
    (set! rows (append r rows))))
(define elapsed (inexact->exact (round (- (current-inexact-milliseconds) t0))))

(define (summarize group-rows)
  (define n (length group-rows))
  (define w-sent (filter (lambda (r) (hash-ref r 'worker_sent? #f)) group-rows))
  (define w-est (filter number? (map (lambda (r) (hash-ref r 'worker_est_send_sec #f)) group-rows)))
  (define w-arr (filter number? (map (lambda (r) (hash-ref r 'worker_arrive_sec #f)) group-rows)))
  (define w-cnt (filter number? (map (lambda (r) (hash-ref r 'worker_cnt_at_cross #f)) group-rows)))
  (define ov-arr (filter number? (map (lambda (r) (hash-ref r 'overlord_arrive_sec #f)) group-rows)))
  (define rp-arr (filter number? (map (lambda (r) (hash-ref r 'reaper_arrive_sec #f)) group-rows)))
  (define fa-arr (filter number? (map (lambda (r) (hash-ref r 'first_scout_arrive_sec #f)) group-rows)))
  (define unit-counts (make-hash))
  (for ([r (in-list group-rows)])
    (define u (hash-ref r 'first_scout_unit #f))
    (when u (hash-update! unit-counts u add1 0)))
  (define top-units
    (for/list ([p (in-list (take (sort (hash->list unit-counts) > #:key cdr) (min 4 (hash-count unit-counts))))])
      (format "~a:~a%" (car p) (inexact->exact (round (* 100.0 (/ (cdr p) (max 1 n))))))))

  ;; Top opening BO sequences (first 5 structures)
  (define bo-counts (make-hash))
  (for ([r (in-list group-rows)])
    (define seq (hash-ref r 'bo_seq '()))
    (when (>= (length seq) 4)
      (define key (string-join (map car (take seq (min 5 (length seq)))) "->"))
      (hash-update! bo-counts key add1 0)))
  (define top-bos
    (for/list ([p (in-list (take (sort (hash->list bo-counts) > #:key cdr) (min 3 (hash-count bo-counts))))])
      (format "~a (~a%)" (car p) (inexact->exact (round (* 100.0 (/ (cdr p) (max 1 n))))))))

  ;; Minute curves
  (define curves
    (for/hasheq ([mp (in-list MINUTE-LOOPS)])
      (define m (car mp))
      (define ms (filter hash? (map (lambda (r) (hash-ref (hash-ref r 'snaps) m #f)) group-rows)))
      (values (string->symbol (format "m~a" m))
              (hasheq 'n (length ms)
                      'workers_med (round1 (median (map (lambda (s) (hash-ref s 'workers)) ms)))
                      'army_val_med (round1 (median (map (lambda (s) (hash-ref s 'army_val)) ms)))
                      'army_sup_med (round1 (median (map (lambda (s) (hash-ref s 'army_sup)) ms)))
                      'a2w_med (round1 (median (map (lambda (s) (hash-ref s 'a2w)) ms)))
                      'prod_cnt_med (round1 (median (map (lambda (s) (hash-ref s 'prod_cnt)) ms)))
                      'primary_prod_med (round1 (median (map (lambda (s) (hash-ref s 'primary_prod)) ms)))
                      'queens_med (round1 (median (map (lambda (s) (hash-ref s 'queens)) ms)))))))

  ;; Key tech & upgrade median timings
  (define tech-keys '(cyber robo twilight stargate factory starport orbital pool roach_warren bane_nest lair hive
                      warp_gate stimpack combat_shield ling_speed roach_speed blink charge plus1_atk plus1_arm))
  (define tech-meds
    (for/hasheq ([tk (in-list tech-keys)]
                 #:do [(define vals (filter number? (map (lambda (r) (hash-ref (hash-ref r 'tech_times) tk #f)) group-rows)))]
                 #:when (>= (length vals) (max 3 (quotient n 10))))
      (values tk (round1 (median vals)))))

  (hasheq 'n n
          'scouting
          (hasheq 'worker_scout_pct (round1 (* 100.0 (/ (length w-sent) (max 1 n))))
                  'worker_est_send_sec_p25 (round1 (pct w-est 0.25))
                  'worker_est_send_sec_med (round1 (median w-est))
                  'worker_est_send_sec_p75 (round1 (pct w-est 0.75))
                  'worker_arrive_sec_med (round1 (median w-arr))
                  'worker_cnt_at_cross_med (round1 (median w-cnt))
                  'overlord_arrive_sec_med (round1 (median ov-arr))
                  'reaper_arrive_sec_med (round1 (median rp-arr))
                  'first_scout_arrive_sec_med (round1 (median fa-arr))
                  'first_scout_top_units top-units)
          'top_opening_sequences top-bos
          'minute_curves curves
          'tech_and_upgrade_sec_med tech-meds))

(define by-race
  (for/hasheq ([rc (in-list '("Protoss" "Terran" "Zerg"))])
    (values (string->symbol rc) (summarize (filter (lambda (r) (string=? (hash-ref r 'race) rc)) rows)))))
(define by-mu
  (for/hasheq ([mu (in-list '("PvP" "PvT" "PvZ" "TvP" "TvT" "TvZ" "ZvP" "ZvT" "ZvZ"))])
    (values (string->symbol mu) (summarize (filter (lambda (r) (string=? (hash-ref r 'matchup) mu)) rows)))))

(printf "Scanned ~a/~a LotV Pro Replays (~a perspectives) in ~ams\n\n" ok-replays (length files) (length rows) elapsed)
(printf "### 1. Pro Early-Scout Timings & Units (Replays=~a)\n" ok-replays)
(printf "| Slice | n | WorkerScout% | EstSend (p25/med/p75) | W@Cross | WorkerArr | OvArr | ReaperArr | 1stArr | Top 1st Scout Units |\n")
(printf "|---|---:|---:|---|---:|---:|---:|---:|---:|---|\n")
(define (print-scout-row label h)
  (define sc (hash-ref h 'scouting))
  (printf "| **~a** | ~a | ~a% | ~a / **~a** / ~as | ~a | ~as | ~as | ~as | ~as | ~a |\n"
          label (hash-ref h 'n) (hash-ref sc 'worker_scout_pct)
          (or (hash-ref sc 'worker_est_send_sec_p25) "-")
          (or (hash-ref sc 'worker_est_send_sec_med) "-")
          (or (hash-ref sc 'worker_est_send_sec_p75) "-")
          (or (hash-ref sc 'worker_cnt_at_cross_med) "-")
          (or (hash-ref sc 'worker_arrive_sec_med) "-")
          (or (hash-ref sc 'overlord_arrive_sec_med) "-")
          (or (hash-ref sc 'reaper_arrive_sec_med) "-")
          (or (hash-ref sc 'first_scout_arrive_sec_med) "-")
          (string-join (hash-ref sc 'first_scout_top_units) ", ")))
(for ([rc (in-list '(Protoss Terran Zerg))])
  (print-scout-row (symbol->string rc) (hash-ref by-race rc)))
(printf "\n")
(for ([mu (in-list '(PvP PvT PvZ TvP TvT TvZ ZvP ZvT ZvZ))])
  (print-scout-row (symbol->string mu) (hash-ref by-mu mu)))

(printf "\n### 2. Pro Production, Worker & Army Curves (4m / 6m / 8m) & Top Opening BO\n")
(printf "| Slice | W 4m/6m/8m | ArmyVal 4m/6m/8m | ProdFac 4m/6m/8m | Top Opening BO |\n")
(printf "|---|---|---|---|---|\n")
(for ([mu (in-list '(PvP PvT PvZ TvP TvT TvZ ZvP ZvT ZvZ))])
  (define h (hash-ref by-mu mu))
  (define cv (hash-ref h 'minute_curves))
  (define (g m k) (or (hash-ref (hash-ref cv m) k #f) "-"))
  (printf "| **~a** | ~a / ~a / ~a | ~a / ~a / ~a | ~a / ~a / ~a | ~a |\n"
          mu
          (g 'm4 'workers_med) (g 'm6 'workers_med) (g 'm8 'workers_med)
          (g 'm4 'army_val_med) (g 'm6 'army_val_med) (g 'm8 'army_val_med)
          (g 'm4 'prod_cnt_med) (g 'm6 'prod_cnt_med) (g 'm8 'prod_cnt_med)
          (if (pair? (hash-ref h 'top_opening_sequences)) (car (hash-ref h 'top_opening_sequences)) "-")))

(when (out-json)
  (call-with-output-file (out-json) #:exists 'replace
    (lambda (p)
      (write-json (hasheq 'replays_scanned ok-replays
                          'perspectives (length rows)
                          'by_race by-race
                          'by_matchup by-mu)
                  p))))
