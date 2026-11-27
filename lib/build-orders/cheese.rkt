#lang racket/base

;; =============================================================================
;; `lib/build-orders/cheese.rkt`
;; Mothman Version C ("C is for Cheese") — Pro < 6:00 Cheese Playbooks
;;
;; Defines 18 typed/structured pro < 6:00 cheese playbooks (9 SC2 matchups x 2
;; profiles: primary + secondary) grounded in empirical LotV pro replays from
;; `replays/pro_corpus/` (TRUE, Rogue, SHIN, Kogoro, Maru, GuMiho, VOID, NULL,
;; sOs, MaNa, Bly) paired with canonical LotV pro cheeses for corpus gaps.
;;
;; Strictly read-only relative to `lib/build-orders.rkt` (requires it to build
;; canonical `build-order-spec` / `pro-bo-goal` / `pro-unit-timing` /
;; `pro-upgrade-timing` structs without modifying macro build orders).
;; =============================================================================

(require racket/list
         racket/math
         racket/string
         "../sc2-types.rkt"
         "../build-orders.rkt")

(provide
 (struct-out cheese-build-spec)
 lookup-cheese-build-spec
 list-cheese-profiles-for-matchup
 random-cheese-profiles-for-matchup
 select-cheese-build-spec
 all-cheese-build-specs
 cheese-followup-plan
 cheese-build-spec-for-followup)

;; -----------------------------------------------------------------------------
;; 1. Core Struct & Normalization Helpers
;; -----------------------------------------------------------------------------

(struct cheese-build-spec
  (id                   ;; Symbol: canonical profile ID (18 exact IDs)
   matchup              ;; MatchupSym: 'ZvZ | 'ZvT | 'ZvP | 'TvZ | 'TvT | 'TvP | 'PvZ | 'PvT | 'PvP
   race                 ;; KnownRace: 'Zerg | 'Terran | 'Protoss
   bo-spec              ;; build-order-spec (from `lib/sc2-types.rkt` / `lib/build-orders.rkt`)
   worker-cap           ;; Positive-Integer: hard worker ceiling during cheese phase
   max-bases            ;; Positive-Integer: max TownHalls during cheese phase (1, 2, or 3)
   proxy-kind           ;; Symbol: 'none | 'off-path-mid | 'close-cannon | 'proxy-spine | 'nydus-main
   proxy-dispatch-sec   ;; Real: clock seconds to pull proxy worker(s) (0.0 when 'none)
   proxy-worker-count   ;; Nonnegative-Integer: dedicated proxy workers (0, 1, or 2)
   proxy-buildings      ;; (Listof Symbol): ordered proxy structure symbols
   hit-trigger          ;; Hash: 'min-combat-supply, 'min-sec, 'key-unit-req, 'key-upgrade-req
   pull-workers-at-hit  ;; Nonnegative-Integer: non-gas workers to pull on commit (0 or N)
   fallback-macro-sec   ;; Real: clock seconds to release cheese lock if opponent holds
   army-comp            ;; (Listof Symbol): ordered combat unit priorities during cheese
   key-upgrades)        ;; (Listof Symbol): upgrade priorities during cheese
  #:transparent)

(define (make-hit-trigger min-combat-supply min-sec
                          [key-unit-req #f]
                          [key-upgrade-req #f])
  (hasheq 'min-combat-supply min-combat-supply
          'min-sec min-sec
          'key-unit-req key-unit-req
          'key-upgrade-req key-upgrade-req))

(define (coerce-race-input r)
  (cond
    [(symbol? r)
     (case (string->symbol (string-downcase (symbol->string r)))
       [(z zerg) 'Zerg]
       [(t terran) 'Terran]
       [(p protoss) 'Protoss]
       [(r x random) 'Random]
       [else r])]
    [(string? r)
     (define low (string-downcase (string-trim r)))
     (cond
       [(or (string=? low "z") (string=? low "zerg")) 'Zerg]
       [(or (string=? low "t") (string=? low "terran")) 'Terran]
       [(or (string=? low "p") (string=? low "protoss")) 'Protoss]
       [(or (string=? low "r") (string=? low "x") (string=? low "random")) 'Random]
       [else 'Unknown])]
    [else 'Unknown]))

(define (parse-matchup-token v)
  (define s
    (cond
      [(symbol? v) (string-upcase (symbol->string v))]
      [(string? v) (string-upcase (string-trim v))]
      [else #f]))
  (and s
       (case (string->symbol s)
         [(ZVZ) 'ZvZ] [(ZVT) 'ZvT] [(ZVP) 'ZvP]
         [(TVZ) 'TvZ] [(TVT) 'TvT] [(TVP) 'TvP]
         [(PVZ) 'PvZ] [(PVT) 'PvT] [(PVP) 'PvP]
         [else #f])))

(define (coerce-matchup-sym x [enemy-race #f])
  (cond
    [(and (not enemy-race) (matchup-sym? x)) x]
    [(and (not enemy-race) (parse-matchup-token x)) => values]
    [else
     (resolve-matchup-symbol (coerce-race-input x)
                             (coerce-race-input (or enemy-race 'Unknown)))]))

(define (coerce-profile-sym p)
  (cond
    [(not p) 'auto]
    [(symbol? p)
     (define low (string-downcase (symbol->string p)))
     (if (or (string=? low "") (string=? low "auto"))
         'auto
         (string->symbol low))]
    [(string? p)
     (define low (string-downcase (string-trim p)))
     (if (or (string=? low "") (string=? low "auto"))
         'auto
         (string->symbol low))]
    [else 'auto]))

(define (seed->nonneg-int seed)
  (cond
    [(exact-integer? seed) (abs seed)]
    [(finite-real? seed) (abs (exact-floor seed))]
    [(string? seed)
     ;; Deterministic FNV-1a 32-bit hash across processes/builds
     (for/fold ([h 2166136261]) ([b (in-bytes (string->bytes/utf-8 seed))])
       (bitwise-and (* (bitwise-xor h b) 16777619) #x7fffffff))]
    [(symbol? seed) (seed->nonneg-int (symbol->string seed))]
    [else 0]))

;; -----------------------------------------------------------------------------
;; 2. ZERG Version C Playbooks (6 Profiles: ZvZ, ZvP, ZvT)
;; -----------------------------------------------------------------------------

;; ZvZ Primary: TRUE > Serral (3:32, Abyssal Reef LE, WCS Valencia)
;; 13/12 Gas-Pool Speedling-Baneling All-In — 15 Drone cutoff @ 0:51, hits 2:45
(define ZvZ-13-12-LING-BANE
  (cheese-build-spec
   'zvz-13-12-ling-bane
   'ZvZ
   'Zerg
   (build-order-spec
    'ZvZ
    'Zerg
    "ZvZ 13/12 Gas-Pool Speedling-Baneling All-In (TRUE > Serral 3:32)"
    'one-base-all-in
    "12 Extractor / 13 Spawning Pool / 15 Drone hard cutoff into 1:12 Ling Speed, 1:32 Baneling Nest, and 2:45 Speedling-Baneling kill."
    (list
     (pro-bo-goal 'build    'extractor        1 13 #f             18.0)  ;; 0:18 (avoids 0:07 premature gas!)
     (pro-bo-goal 'build    'spawning-pool    1 13 #f             25.0)  ;; 0:25
     (pro-bo-goal 'train    'overlord         2 15 #f             51.0)  ;; 0:51
     (pro-bo-goal 'research 'metabolic-boost  1 14 'spawning-pool 72.0)  ;; 1:12 (done 2:31)
     (pro-bo-goal 'train    'zergling         6 14 'spawning-pool 75.0)  ;; 1:15
     (pro-bo-goal 'build    'baneling-nest    1 16 'spawning-pool 92.0)  ;; 1:32
     (pro-bo-goal 'train    'zergling        14 16 'spawning-pool 110.0) ;; 1:50
     (pro-bo-goal 'expand   'hatchery         2 18 'spawning-pool 145.0) ;; 2:25 macro larva hatch
     (pro-bo-goal 'morph    'baneling         4 18 'baneling-nest 151.0)) ;; 2:31
    '((1 . (15.0 .  0.0))
      (2 . (15.0 .  6.0))
      (3 . (15.0 . 18.0))
      (4 . (15.0 . 26.0))
      (5 . (15.0 . 32.0))
      (6 . (15.0 . 38.0))
      (7 . (28.0 . 46.0)))
    (list
     (pro-unit-timing 'overlord 2 15  51.0 #f)
     (pro-unit-timing 'zergling 8 14  89.0 'spawning-pool)
     (pro-unit-timing 'baneling 4 18 153.0 'baneling-nest)
     (pro-unit-timing 'zergling 24 22 180.0 'spawning-pool))
    (list
     (pro-upgrade-timing 'metabolic-boost 72.0 151.0 14 'spawning-pool)))
   15
   2
   'none
   0.0
   0
   '()
   (make-hit-trigger 10 150.0 'baneling 'metabolic-boost)
   0
   390.0
   '(baneling zergling)
   '(metabolic-boost)))

;; ZvZ Secondary: Bly vs Serral (4:03, Dreamcatcher LE)
;; 12-Pool Triple Proxy Spine Crawler + Zergling Flood — 15 Drone cutoff
(define ZvZ-12POOL-PROXY-SPINE
  (cheese-build-spec
   'zvz-12pool-proxy-spine
   'ZvZ
   'Zerg
   (build-order-spec
    'ZvZ
    'Zerg
    "ZvZ 12-Pool Proxy Spine Crawler Rush (Bly Blueprint)"
    'one-base-all-in
    "12 Spawning Pool @ 0:18 into immediate Lings + 3 Proxy Spine Crawlers on opponent's natural creep at 1:50 (zero Queen before Spines)."
    (list
     (pro-bo-goal 'build 'spawning-pool 1 12 #f             18.0)  ;; 0:18
     (pro-bo-goal 'train 'overlord      2 14 #f             36.0)  ;; 0:36
     (pro-bo-goal 'train 'zergling     10 14 'spawning-pool 60.0)  ;; 1:00 immediate Lings
     (pro-bo-goal 'build 'spine-crawler 3 15 'spawning-pool 110.0) ;; 1:50 3x proxy spines
     (pro-bo-goal 'train 'zergling     20 18 'spawning-pool 125.0)) ;; 2:05
    '((1 . (14.0 .  0.0))
      (2 . (15.0 .  8.0))
      (3 . (15.0 . 18.0))
      (4 . (15.0 . 24.0))
      (5 . (15.0 . 30.0))
      (6 . (18.0 . 36.0))
      (7 . (30.0 . 44.0)))
    (list
     (pro-unit-timing 'overlord 2 14  36.0 #f)
     (pro-unit-timing 'zergling 10 14  88.0 'spawning-pool)
     (pro-unit-timing 'zergling 22 18 145.0 'spawning-pool))
    '())
   15
   1
   'proxy-spine
   52.0
   2
   '(spine-crawler spine-crawler spine-crawler)
   (make-hit-trigger 6 105.0 'zergling #f)
   4
   360.0
   '(zergling)
   '()))

;; ZvP Primary: Rogue > Stats (4:57, Abyssal Reef LE)
;; 19-Drone 2-Base Speedling-Roach-Ravager All-In — 19 Drone cutoff @ 1:37, hits 4:00
(define ZvP-19D-SPEEDLING-ROACH-RAVAGER
  (cheese-build-spec
   'zvp-19d-speedling-roach-ravager
   'ZvP
   'Zerg
   (build-order-spec
    'ZvP
    'Zerg
    "ZvP 19-Drone 2-Base Speedling-Roach-Ravager All-In (Rogue > Stats 4:57)"
    'roach-ravager-timing
    "16 Gas / 17 Pool / 19 Natural Hatch / hard 19-Drone cutoff @ 1:37 into 2:07 Roach Warren, 3:05 Ling Speed, 7 Roaches -> 3 Ravagers + Speedling flood @ 4:00."
    (list
     (pro-bo-goal 'train    'overlord        2 14 #f             13.0)  ;; 0:13
     (pro-bo-goal 'build    'extractor       1 16 #f             46.0)  ;; 0:46
     (pro-bo-goal 'build    'spawning-pool   1 17 #f             50.0)  ;; 0:50
     (pro-bo-goal 'expand   'hatchery        2 18 #f             76.0)  ;; 1:16 (targets Pro 1:21 Nat Hatch)
     (pro-bo-goal 'research 'metabolic-boost 1 20 'spawning-pool 106.0) ;; 1:46 (done 3:05)
     (pro-bo-goal 'train    'zergling        4 20 'spawning-pool 110.0) ;; 1:50
     (pro-bo-goal 'train    'overlord        3 22 #f             116.0) ;; 1:56
     (pro-bo-goal 'train    'queen           1 21 'spawning-pool 118.0) ;; 1:58
     (pro-bo-goal 'build    'roach-warren    1 21 'spawning-pool 127.0) ;; 2:07
     (pro-bo-goal 'train    'overlord        4 23 #f             134.0) ;; 2:14
     (pro-bo-goal 'train    'roach           7 24 'roach-warren  165.0) ;; 2:45
     (pro-bo-goal 'train    'zergling       24 36 'spawning-pool 195.0) ;; 3:15
     (pro-bo-goal 'train    'overlord        5 38 #f             205.0) ;; 3:25
     (pro-bo-goal 'morph    'ravager         3 42 'roach-warren  235.0)) ;; 3:55
    '((1 . (16.0 .  0.0))
      (2 . (19.0 .  2.0))
      (3 . (19.0 . 12.0))
      (4 . (19.0 . 30.0))
      (5 . (19.0 . 42.0))
      (6 . (19.0 . 50.0))
      (7 . (34.0 . 58.0)))
    (list
     (pro-unit-timing 'overlord 2 14  13.0 #f)
     (pro-unit-timing 'zergling 4 20 116.0 'spawning-pool)
     (pro-unit-timing 'queen    1 21 133.0 'spawning-pool)
     (pro-unit-timing 'roach    7 24 186.0 'roach-warren)
     (pro-unit-timing 'ravager  3 42 253.0 'roach-warren)
     (pro-unit-timing 'zergling 24 40 240.0 'spawning-pool))
    (list
     (pro-upgrade-timing 'metabolic-boost 106.0 185.0 20 'spawning-pool)))
   19
   2
   'none
   0.0
   0
   '()
   (make-hit-trigger 24 225.0 'roach 'metabolic-boost)
   0
   390.0
   '(ravager roach zergling queen)
   '(metabolic-boost)))

;; ZvP Secondary: Canonical LotV 12-Pool Ling Flood (hits ~1:55 before Cyber/Adept!)
(define ZvP-12POOL-LING-FLOOD
  (cheese-build-spec
   'zvp-12pool-ling-flood
   'ZvP
   'Zerg
   (build-order-spec
    'ZvP
    'Zerg
    "ZvP 12-Pool Speedling Wall-Break Flood (Canonical LotV)"
    'one-base-all-in
    "12 Spawning Pool @ 0:18 / 14-Drone opening cap -> immediate 10-Zergling flood @ 1:12-1:25 -> 20 Natural Hatch + Ling Speed follow-up."
    (list
     (pro-bo-goal 'build    'spawning-pool   1 12 #f             18.0)  ;; 0:18
     (pro-bo-goal 'train    'overlord        2 14 #f             36.0)  ;; 0:36
     (pro-bo-goal 'train    'zergling       10 14 'spawning-pool 56.0)  ;; 0:56 immediate 10 Lings!
     (pro-bo-goal 'expand   'hatchery        2 20 'spawning-pool 98.0)  ;; 1:38 post-Ling Hatch #2
     (pro-bo-goal 'build    'extractor       1 20 'spawning-pool 102.0) ;; 1:42 post-Ling Gas #1
     (pro-bo-goal 'train    'queen           1 21 'spawning-pool 110.0) ;; 1:50
     (pro-bo-goal 'research 'metabolic-boost 1 22 'spawning-pool 130.0) ;; 2:10
     (pro-bo-goal 'train    'zergling       26 22 'spawning-pool 135.0))
    '((1 . (14.0 .  0.0))
      (2 . (14.0 . 10.0))
      (3 . (14.0 . 22.0))
      (4 . (16.0 . 32.0))
      (5 . (18.0 . 38.0))
      (6 . (24.0 . 44.0))
      (7 . (36.0 . 52.0)))
    (list
     (pro-unit-timing 'overlord 2 14  36.0 #f)
     (pro-unit-timing 'zergling 10 14  80.0 'spawning-pool)
     (pro-unit-timing 'zergling 24 22 165.0 'spawning-pool))
    (list
     (pro-upgrade-timing 'metabolic-boost 130.0 209.0 22 'spawning-pool)))
   14
   2
   'none
   0.0
   0
   '()
   (make-hit-trigger 5 95.0 'zergling #f)
   0
   360.0
   '(zergling queen)
   '(metabolic-boost)))

;; ZvT Primary: Kogoro > Earil (5:32, Odyssey LE)
;; 26-Drone 2-Base 2-Gas Roach-Ravager-Ling Bust — hits 5:00 with 12 Roaches + 4 Ravagers + 30 Lings
(define ZvT-26D-ROACH-RAVAGER-BUST
  (cheese-build-spec
   'zvt-26d-roach-ravager-bust
   'ZvT
   'Zerg
   (build-order-spec
    'ZvT
    'Zerg
    "ZvT 26-Drone 2-Gas Roach-Ravager-Ling Bunker Bust (Kogoro > Earil 5:32)"
    'roach-ravager-timing
    "13 Overlord / 16 Hatch @ 0:52 / 18 Gas / 17 Pool / 22 Gas #2 / 24 Roach Warren @ 2:15 -> 26-Drone cutoff into 12 Roaches + 4 Ravagers by 4:30."
    (list
     (pro-bo-goal 'train  'overlord      2 13 #f             13.0)  ;; 0:13
     (pro-bo-goal 'expand 'hatchery      2 16 #f             52.0)  ;; 0:52 Pro 16-Hatch!
     (pro-bo-goal 'build  'extractor     1 18 #f             65.0)  ;; 1:05
     (pro-bo-goal 'build  'spawning-pool 1 17 #f             68.0)  ;; 1:08
     (pro-bo-goal 'train  'overlord      3 19 #f             85.0)  ;; 1:25
     (pro-bo-goal 'train  'queen         2 20 'spawning-pool 110.0) ;; 1:50
     (pro-bo-goal 'train  'zergling      4 20 'spawning-pool 112.0) ;; 1:52
     (pro-bo-goal 'build  'extractor     2 22 'spawning-pool 124.0) ;; 2:04
     (pro-bo-goal 'build  'roach-warren  1 24 'spawning-pool 135.0) ;; 2:15
     (pro-bo-goal 'train  'overlord      4 26 #f             145.0) ;; 2:25
     (pro-bo-goal 'train  'overlord      5 30 #f             172.0) ;; 2:52
     (pro-bo-goal 'train  'roach        12 30 'roach-warren  180.0) ;; 3:00 Roaches BEFORE Lings!
     (pro-bo-goal 'morph  'ravager       4 44 'roach-warren  235.0) ;; 3:55
     (pro-bo-goal 'train  'zergling     24 48 'spawning-pool 250.0)) ;; 4:10
    '((1 . (15.0 .  0.0))
      (2 . (19.0 .  2.0))
      (3 . (26.0 .  6.0))
      (4 . (26.0 . 22.0))
      (5 . (26.0 . 44.0))
      (6 . (26.0 . 56.0))
      (7 . (42.0 . 64.0)))
    (list
     (pro-unit-timing 'overlord 2 13  12.0 #f)
     (pro-unit-timing 'zergling 4 18 112.0 'spawning-pool)
     (pro-unit-timing 'queen    2 20 128.0 'spawning-pool)
     (pro-unit-timing 'roach   12 32 217.0 'roach-warren)
     (pro-unit-timing 'ravager  4 54 305.0 'roach-warren)
     (pro-unit-timing 'zergling 24 44 270.0 'spawning-pool))
    '())
   26
   2
   'none
   0.0
   0
   '()
   (make-hit-trigger 28 280.0 'ravager #f)
   0
   390.0
   '(ravager roach zergling queen)
   '()))

;; ZvT Secondary: SHIN > LiquidClem (6:16 on Incorporeal LE, Nydus hits 5:23!)
;; 42-Drone 3-Hatch Queen-Speedling Nydus All-In — Nydus pops dE=11.0 @ 5:23
(define ZvT-42D-QUEEN-LING-NYDUS
  (cheese-build-spec
   'zvt-42d-queen-ling-nydus
   'ZvT
   'Zerg
   (build-order-spec
    'ZvT
    'Zerg
    "ZvT 42-Drone 3-Hatch Queen-Speedling Nydus All-In (SHIN > Clem 6:16)"
    'two-base-timing
    "14 Hatch / 18 Gas / 19 Pool / 21 3rd Hatch -> 42-Drone cutoff @ 4:00 into 7-9 Queens, Lair @ 4:44, Nydus Network @ 4:46, Nydus inside enemy main @ 5:23."
    (list
     (pro-bo-goal 'train    'overlord        2 14 #f             16.0)  ;; 0:16
     (pro-bo-goal 'expand   'hatchery        2 14 #f             45.0)  ;; 0:45
     (pro-bo-goal 'build    'extractor       1 18 #f             67.0)  ;; 1:07
     (pro-bo-goal 'build    'spawning-pool   1 19 #f             71.0)  ;; 1:11
     (pro-bo-goal 'expand   'hatchery        3 21 #f             120.0) ;; 2:00
     (pro-bo-goal 'train    'queen           4 21 'spawning-pool 125.0) ;; 2:05 fast Queens
     (pro-bo-goal 'train    'zergling        6 22 'spawning-pool 128.0) ;; 2:08 early safety Lings
     (pro-bo-goal 'research 'metabolic-boost 1 26 'spawning-pool 146.0) ;; 2:26 (done 3:45)
     (pro-bo-goal 'build    'extractor       2 36 'spawning-pool 210.0) ;; 3:30
     (pro-bo-goal 'train    'zergling       24 38 'spawning-pool 215.0) ;; 3:35 24 Lings by 4:30
     (pro-bo-goal 'train    'queen           7 42 'spawning-pool 220.0) ;; 3:40
     (pro-bo-goal 'morph    'lair            1 44 'spawning-pool 235.0) ;; 3:55 (done ~4:44)
     (pro-bo-goal 'train    'zergling       48 52 'spawning-pool 260.0) ;; 4:20
     (pro-bo-goal 'build    'nydus-network   1 56 'lair          286.0) ;; 4:46
     (pro-bo-goal 'build    'nydus-worm      1 64 'nydus-network 323.0)) ;; 5:23 inside main
    '((1 . (15.0 .  0.0))
      (2 . (20.0 .  2.0))
      (3 . (27.0 .  6.0))
      (4 . (42.0 . 18.0))
      (5 . (42.0 . 38.0))
      (6 . (42.0 . 56.0))
      (7 . (54.0 . 66.0)))
    (list
     (pro-unit-timing 'overlord 2 14  16.0 #f)
     (pro-unit-timing 'queen    4 24 154.0 'spawning-pool)
     (pro-unit-timing 'queen    7 44 250.0 'spawning-pool)
     (pro-unit-timing 'zergling 48 56 300.0 'spawning-pool))
    (list
     (pro-upgrade-timing 'metabolic-boost 146.0 225.0 26 'spawning-pool)))
   42
   3
   'nydus-main
   286.0
   0
   '(nydus-worm)
   (make-hit-trigger 22 310.0 'zergling 'metabolic-boost)
   0
   405.0
   '(queen zergling)
   '(metabolic-boost)))

;; -----------------------------------------------------------------------------
;; 3. TERRAN Version C Playbooks (6 Profiles: TvP, TvT, TvZ)
;; -----------------------------------------------------------------------------

;; TvP Primary: VITmaru > herO (5:13 on Ley Lines!)
;; 19-SCV Proxy 2-Rax Concussive Marauder All-In — Proxy dE=56-59, hits 3:26 w/ SCV pull
(define TvP-PROXY-2RAX-MARAUDER
  (cheese-build-spec
   'tvp-proxy-2rax-marauder
   'TvP
   'Terran
   (build-order-spec
    'TvP
    'Terran
    "TvP 19-SCV Proxy 2-Rax Concussive Marauder All-In (Maru > herO 5:13)"
    'one-base-all-in
    "0:04 dual-SCV off-path proxy (dE~56) -> 0:40/0:56 2x Proxy Barracks -> 1:27/1:43 2x Tech Labs -> 1:52 Orbital -> 2:13 Concussive (done 2:56) -> 3:26 7-Marauder + SCV-pull kill."
    (list
     (pro-bo-goal 'build    'supply-depot      1 13 #f                18.0)  ;; 0:18
     (pro-bo-goal 'build    'barracks          1 15 'supply-depot     40.0)  ;; 0:40 [PROXY]
     (pro-bo-goal 'build    'refinery          1 15 'supply-depot     45.0)  ;; 0:45
     (pro-bo-goal 'build    'barracks          2 15 'supply-depot     56.0)  ;; 0:56 [PROXY]
     (pro-bo-goal 'build    'barracks-techlab  1 17 'barracks         87.0)  ;; 1:27 [PROXY]
     (pro-bo-goal 'build    'barracks-techlab  2 17 'barracks         103.0) ;; 1:43 [PROXY]
     (pro-bo-goal 'build    'supply-depot      2 17 'barracks         104.0) ;; 1:44
     (pro-bo-goal 'morph    'orbital-command   1 17 'barracks         112.0) ;; 1:52
     (pro-bo-goal 'train    'marauder          2 19 'barracks-techlab 115.0) ;; 1:55
     (pro-bo-goal 'research 'concussive-shells 1 21 'barracks-techlab 133.0) ;; 2:13 (done 2:56)
     (pro-bo-goal 'build    'supply-depot      3 23 'barracks         150.0) ;; 2:30
     (pro-bo-goal 'train    'marauder          8 25 'barracks-techlab 175.0)) ;; 2:55 commit 8 Marauders before follow-up CC
    '((1 . (15.0 .  0.0))
      (2 . (17.0 .  2.0))
      (3 . (19.0 . 10.0))
      (4 . (19.0 . 18.0))
      (5 . (19.0 . 26.0))
      (6 . (19.0 . 30.0))
      (7 . (30.0 . 38.0)))
    (list
     (pro-unit-timing 'marauder 1 20 127.0 'barracks-techlab)
     (pro-unit-timing 'marauder 4 26 165.0 'barracks-techlab)
     (pro-unit-timing 'marauder 7 32 206.0 'barracks-techlab))
    (list
     (pro-upgrade-timing 'concussive-shells 133.0 176.0 21 'barracks-techlab)))
   19
   1
   'off-path-mid
   4.0
   2
   '(barracks barracks barracks-tech-lab barracks-tech-lab)
   (make-hit-trigger 12 195.0 'marauder 'concussive-shells)
   8
   390.0
   '(marauder)
   '(concussive-shells)))

;; TvP Secondary: inhale > Sky (5:03, Blueshift LE)
;; 1-Base 2-Gas Fast Cyclone-Bio Push — 24 SCV cutoff, hits 3:43 w/ 4 Cyclones + bio
(define TvP-1BASE-2GAS-CYCLONE
  (cheese-build-spec
   'tvp-1base-2gas-cyclone
   'TvP
   'Terran
   (build-order-spec
    'TvP
    'Terran
    "TvP 1-Base 2-Gas Fast Cyclone-Bio Push (inhale > Sky 5:03)"
    'one-base-all-in
    "15 Rax / 15+16 Double Gas / 19 Factory -> Factory TechLab -> 4x Cyclones ahead of Widow Mines & Starport, hitting @ 3:43."
    (list
     (pro-bo-goal 'build 'supply-depot     1 13 #f               17.0)  ;; 0:17
     (pro-bo-goal 'build 'barracks         1 15 'supply-depot    40.0)  ;; 0:40
     (pro-bo-goal 'build 'refinery         1 15 'supply-depot    44.0)  ;; 0:44
     (pro-bo-goal 'build 'refinery         2 16 'supply-depot    53.0)  ;; 0:53
     (pro-bo-goal 'build 'supply-depot     2 18 'barracks        89.0)  ;; 1:29
     (pro-bo-goal 'train 'marine           2 18 'barracks        95.0)  ;; 1:35 early home defense Marines
     (pro-bo-goal 'build 'factory          1 19 'barracks        103.0) ;; 1:43
     (pro-bo-goal 'build 'barracks-reactor 1 20 'barracks        108.0) ;; 1:48
     (pro-bo-goal 'build 'factory-techlab  1 20 'factory         112.0) ;; 1:52 TechLab required on Base75689 for Cyclones!
     (pro-bo-goal 'morph 'orbital-command  1 20 'barracks        117.0) ;; 1:57
     (pro-bo-goal 'build 'supply-depot     3 22 'barracks        142.0) ;; 2:22
     (pro-bo-goal 'train 'cyclone          4 23 'factory-techlab 155.0) ;; 2:35 4x Cyclones FIRST on TechLab Factory!
     (pro-bo-goal 'train 'widow-mine       2 34 'factory         210.0) ;; 3:30 Widow Mines AFTER >=3 Cyclones
     (pro-bo-goal 'build 'starport         1 38 'factory         228.0)) ;; 3:48 Starport AFTER Cyclones
    '((1 . (16.0 .  0.0))
      (2 . (19.0 .  2.0))
      (3 . (24.0 . 10.0))
      (4 . (24.0 . 20.0))
      (5 . (24.0 . 28.0))
      (6 . (26.0 . 36.0))
      (7 . (38.0 . 46.0)))
    (list
     (pro-unit-timing 'marine     2 20 107.0 'barracks)
     (pro-unit-timing 'cyclone    2 26 182.0 'factory-techlab)
     (pro-unit-timing 'cyclone    4 34 220.0 'factory-techlab)
     (pro-unit-timing 'widow-mine 2 38 245.0 'factory))
    '())
   24
   1
   'none
   0.0
   0
   '()
   (make-hit-trigger 14 215.0 'cyclone #f)
   0
   390.0
   '(cyclone widow-mine viking-fighter marauder marine)
   '()))

;; TvT Primary: Canonical LotV Pro Proxy 2-Rax Reaper (filling 0-replay TvT <6:45 gap)
;; 19-SCV Cutoff, Off-Path Proxy dE~52, hits 2:05 w/ 2 Reapers -> 6-8 Reapers by 3:00
(define TvT-PROXY-2RAX-REAPER
  (cheese-build-spec
   'tvt-proxy-2rax-reaper
   'TvT
   'Terran
   (build-order-spec
    'TvT
    'Terran
    "TvT 19-SCV Proxy 2-Rax Reaper All-In (Canonical LotV)"
    'one-base-all-in
    "0:04 dual-SCV off-path proxy (dE~52) -> 0:40/0:52 2x Proxy Barracks -> double home Refinery -> nonstop Reapers hitting @ 2:05 into Factory Hellion priority."
    (list
     (pro-bo-goal 'build 'supply-depot    1 13 #f            18.0)  ;; 0:18
     (pro-bo-goal 'build 'refinery        1 14 'supply-depot 30.0)  ;; 0:30
     (pro-bo-goal 'build 'barracks        1 15 'supply-depot 40.0)  ;; 0:40 [PROXY]
     (pro-bo-goal 'build 'barracks        2 15 'supply-depot 52.0)  ;; 0:52 [PROXY]
     (pro-bo-goal 'build 'refinery        2 16 'supply-depot 65.0)  ;; 1:05
     (pro-bo-goal 'train 'reaper          2 17 'barracks     85.0)  ;; 1:25
     (pro-bo-goal 'build 'supply-depot    2 18 'barracks     95.0)  ;; 1:35
     (pro-bo-goal 'morph 'orbital-command 1 19 'barracks     105.0) ;; 1:45
     (pro-bo-goal 'train 'reaper          6 21 'barracks     125.0) ;; 2:05
     (pro-bo-goal 'build 'factory         1 24 'barracks     165.0) ;; 2:45
     (pro-bo-goal 'build 'supply-depot    3 26 'barracks     175.0) ;; 2:55
     (pro-bo-goal 'train 'hellion         3 26 'factory      188.0)) ;; 3:08 Hellions before follow-up CC
    '((1 . (15.0 .  0.0))
      (2 . (19.0 .  4.0))
      (3 . (19.0 . 12.0))
      (4 . (19.0 . 20.0))
      (5 . (19.0 . 26.0))
      (6 . (22.0 . 32.0))
      (7 . (34.0 . 42.0)))
    (list
     (pro-unit-timing 'reaper  2 18 117.0 'barracks)
     (pro-unit-timing 'reaper  6 24 165.0 'barracks)
     (pro-unit-timing 'hellion 3 28 210.0 'factory))
    '())
   19
   1
   'off-path-mid
   4.0
   2
   '(barracks barracks)
   (make-hit-trigger 2 115.0 'reaper #f)
   0
   390.0
   '(reaper hellion cyclone marine)
   '()))

;; TvT Secondary: 1-Base 1-1-1 Tank-Marine-Viking + Forward Bunker (corroborated by HADB/Guitchauss)
(define TvT-1BASE-111-TANK-BUNKER
  (cheese-build-spec
   'tvt-1base-111-tank-bunker
   'TvT
   'Terran
   (build-order-spec
    'TvT
    'Terran
    "TvT 1-Base 1-1-1 Marine-Tank-Viking Containment Push (HADB/Guitchauss Blueprint)"
    'one-base-all-in
    "Double-gas 1-Base 1-1-1 Reactor Marines + Siege Tanks + Vikings with 23-SCV cutoff pushing @ 4:05 with forward Bunker."
    (list
     (pro-bo-goal 'build 'supply-depot     1 13 #f               17.0)  ;; 0:17
     (pro-bo-goal 'build 'barracks         1 15 'supply-depot    40.0)  ;; 0:40
     (pro-bo-goal 'build 'refinery         1 15 'supply-depot    43.0)  ;; 0:43
     (pro-bo-goal 'build 'refinery         2 16 'supply-depot    53.0)  ;; 0:53
     (pro-bo-goal 'build 'supply-depot     2 18 'barracks        86.0)  ;; 1:26
     (pro-bo-goal 'build 'factory          1 19 'barracks        103.0) ;; 1:43
     (pro-bo-goal 'morph 'orbital-command  1 19 'barracks        114.0) ;; 1:54
     (pro-bo-goal 'build 'barracks-reactor 1 20 'barracks        120.0) ;; 2:00
     (pro-bo-goal 'build 'factory-techlab  1 22 'factory         153.0) ;; 2:33
     (pro-bo-goal 'build 'starport         1 22 'factory         153.0) ;; 2:33
     (pro-bo-goal 'build 'supply-depot     3 23 'barracks        161.0) ;; 2:41
     (pro-bo-goal 'train 'siege-tank       2 28 'factory-techlab 185.0) ;; 3:05
     (pro-bo-goal 'train 'viking-fighter   2 32 'starport        200.0) ;; 3:20
     (pro-bo-goal 'train 'marine          12 34 'barracks        210.0))
    '((1 . (16.0 .  0.0))
      (2 . (19.0 .  3.0))
      (3 . (23.0 . 10.0))
      (4 . (23.0 . 22.0))
      (5 . (23.0 . 32.0))
      (6 . (23.0 . 40.0))
      (7 . (36.0 . 50.0)))
    (list
     (pro-unit-timing 'marine         8 28 195.0 'barracks)
     (pro-unit-timing 'siege-tank     2 34 225.0 'factory-techlab)
     (pro-unit-timing 'viking-fighter 2 38 240.0 'starport))
    '())
   23
   1
   'none
   0.0
   0
   '()
   (make-hit-trigger 20 240.0 'siege-tank #f)
   0
   390.0
   '(siege-tank viking-fighter medivac marine)
   '()))

;; TvZ Primary: Canonical Maru Proxy 2-Rax Bunker Rush (zero gas, 17 SCV cutoff, hits 2:05!)
(define TvZ-PROXY-2RAX-BUNKER
  (cheese-build-spec
   'tvz-proxy-2rax-bunker
   'TvZ
   'Terran
   (build-order-spec
    'TvZ
    'Terran
    "TvZ 17-SCV Proxy 2-Rax Marine-Bunker Rush (Canonical Maru)"
    'one-base-all-in
    "0:04 dual-SCV off-path proxy (dE~48) -> 0:40/0:52 2x Proxy Barracks (0 Gas) -> nonstop Marines + forward Bunker @ 1:45 denying Zerg natural."
    (list
     (pro-bo-goal 'build 'supply-depot    1 13 #f            18.0)  ;; 0:18
     (pro-bo-goal 'build 'barracks        1 15 'supply-depot 40.0)  ;; 0:40 [PROXY]
     (pro-bo-goal 'build 'barracks        2 15 'supply-depot 52.0)  ;; 0:52 [PROXY]
     (pro-bo-goal 'train 'marine          4 16 'barracks     86.0)  ;; 1:26
     (pro-bo-goal 'build 'supply-depot    2 17 'barracks     96.0)  ;; 1:36
     (pro-bo-goal 'morph 'orbital-command 1 17 'barracks     104.0) ;; 1:44
     (pro-bo-goal 'build 'bunker          1 18 'barracks     108.0) ;; 1:48 [PROXY]
     (pro-bo-goal 'train  'marine         12 20 'barracks     125.0) ;; 2:05
     (pro-bo-goal 'build  'supply-depot    3 24 'barracks     155.0) ;; 2:35
     (pro-bo-goal 'build  'refinery        1 25 'barracks     175.0)) ;; 2:55 gas ready for follow-up CC+Factory
    '((1 . (15.0 .  0.0))
      (2 . (17.0 .  4.0))
      (3 . (17.0 . 14.0))
      (4 . (17.0 . 22.0))
      (5 . (17.0 . 28.0))
      (6 . (20.0 . 34.0))
      (7 . (32.0 . 42.0)))
    (list
     (pro-unit-timing 'marine 4 18 112.0 'barracks)
     (pro-unit-timing 'marine 10 24 165.0 'barracks))
    '())
   17
   1
   'off-path-mid
   4.0
   2
   '(barracks barracks bunker)
   (make-hit-trigger 4 115.0 'marine #f)
   4
   360.0
   '(marine marauder)
   '()))

;; TvZ Secondary: lllllllllllI > zatic (4:38, Post-Youth LE)
;; Reaper-FE Fast 5-Hellion + Cloak/Fast Banshee Timing — kills 14-22 Drones @ 4:30
(define TvZ-REAPER-FE-HELLION-BANSHEE
  (cheese-build-spec
   'tvz-reaper-fe-hellion-banshee
   'TvZ
   'Terran
   (build-order-spec
    'TvZ
    'Terran
    "TvZ Reaper-FE Fast Reactor-Hellion + Banshee Timing (lllllllllllI 4:38)"
    'two-base-timing
    "Reaper FE -> 2:07 Factory -> 2:14 Rax Reactor -> 2:53 Starport -> 5 Hellions + Fast Banshee hitting @ 4:25 to roast Drone lines."
    (list
     (pro-bo-goal 'build    'supply-depot     1 13 #f               17.0)  ;; 0:17
     (pro-bo-goal 'build    'barracks         1 15 'supply-depot    40.0)  ;; 0:40 Pro 15-Rax first!
     (pro-bo-goal 'build    'refinery         1 16 'supply-depot    44.0)  ;; 0:44 Pro 16-Gas
     (pro-bo-goal 'train    'reaper           1 19 'barracks        86.0)  ;; 1:26 single Reaper ONLY
     (pro-bo-goal 'expand   'command-center   2 19 'barracks        98.0)  ;; 1:38 Pro Nat CC
     (pro-bo-goal 'build    'supply-depot     2 19 'barracks        110.0) ;; 1:50
     (pro-bo-goal 'morph    'orbital-command  1 19 'barracks        112.0) ;; 1:52
     (pro-bo-goal 'build    'factory          1 19 'barracks        114.0) ;; 1:54
     (pro-bo-goal 'build    'barracks-reactor 1 21 'barracks        122.0) ;; 2:02
     (pro-bo-goal 'build    'refinery         2 21 'barracks        126.0) ;; 2:06
     (pro-bo-goal 'build    'starport         1 24 'factory         156.0) ;; 2:36
     (pro-bo-goal 'train    'marine           6 28 'barracks        180.0) ;; 3:00 Reactor Marines
     (pro-bo-goal 'train    'hellion          6 28 'factory         186.0) ;; 3:06
     (pro-bo-goal 'build    'starport-techlab 1 30 'starport        192.0) ;; 3:12
     (pro-bo-goal 'morph    'orbital-command  2 30 'barracks        200.0) ;; 3:20
     (pro-bo-goal 'train    'banshee          2 34 'starport-techlab 220.0) ;; 3:40
     (pro-bo-goal 'research 'banshee-cloak    1 36 'starport-techlab 230.0) ;; 3:50
     (pro-bo-goal 'build    'barracks         2 44 'starport        260.0)) ;; 4:20 Pro Rax #2
    '((1 . (16.0 .  0.0))
      (2 . (19.0 .  1.0))
      (3 . (26.0 .  6.0))
      (4 . (32.0 . 14.0))
      (5 . (40.0 . 26.0))
      (6 . (44.0 . 36.0))
      (7 . (52.0 . 48.0)))
    (list
     (pro-unit-timing 'reaper  1 19 124.0 'barracks)
     (pro-unit-timing 'hellion 5 28 202.0 'factory)
     (pro-unit-timing 'banshee 1 36 245.0 'starport-techlab))
    (list
     (pro-upgrade-timing 'banshee-cloak 230.0 309.0 36 'starport-techlab)))
   44
   2
   'none
   0.0
   0
   '()
   (make-hit-trigger 12 245.0 'banshee #f)
   0
   390.0
   '(banshee hellion marine)
   '(banshee-cloak)))

;; -----------------------------------------------------------------------------
;; 4. PROTOSS Version C Playbooks (6 Profiles: PvZ, PvT, PvP)
;; -----------------------------------------------------------------------------

;; PvZ Primary: VOID > Wilshire (6:09) & NULL > Jimothy (6:21)
;; 32-Probe 2-Base 8-Gate Chargelot + Warp Prism All-In — hits 5:05 w/ 8-14 Chargelots + Prism
(define PvZ-32P-8GATE-CHARGELOT-PRISM
  (cheese-build-spec
   'pvz-32p-8gate-chargelot-prism
   'PvZ
   'Protoss
   (build-order-spec
    'PvZ
    'Protoss
    "PvZ 32-Probe 2-Base 8-Gate Chargelot + Warp Prism All-In (VOID/NULL 6:09-6:21)"
    'two-base-timing
    "19 Nexus -> 2:29 Twilight (Charge @ 3:00, done ~4:45) + 2:55 Robo (Warp Prism @ 4:30) -> hard 32-Probe cutoff @ 3:45 -> 8 Gateways -> 5:05 Chargelot Prism flood."
    (list
     (pro-bo-goal 'build    'pylon              1 13 #f                 20.0)  ;; 0:20
     (pro-bo-goal 'build    'gateway            1 15 'pylon             40.0)  ;; 0:40
     (pro-bo-goal 'build    'assimilator        1 16 'pylon             50.0)  ;; 0:50
     (pro-bo-goal 'expand   'nexus              2 19 #f                 87.0)  ;; 1:27
     (pro-bo-goal 'build    'cybernetics-core   1 20 'gateway           99.0)  ;; 1:39
     (pro-bo-goal 'build    'assimilator        2 20 'cybernetics-core  114.0) ;; 1:54
     (pro-bo-goal 'build    'pylon              2 21 'cybernetics-core  127.0) ;; 2:07
     (pro-bo-goal 'research 'warp-gate-research 1 22 'cybernetics-core  139.0) ;; 2:19 (done 3:59)
     (pro-bo-goal 'build    'twilight-council   1 23 'cybernetics-core  149.0) ;; 2:29
     (pro-bo-goal 'build    'robotics-facility  1 26 'cybernetics-core  175.0) ;; 2:55
     (pro-bo-goal 'research 'charge             1 28 'twilight-council  182.0) ;; 3:02 (done 4:42)
     (pro-bo-goal 'build    'gateway            2 31 'cybernetics-core  196.0) ;; 3:16
     (pro-bo-goal 'build    'gateway            4 35 'cybernetics-core  220.0) ;; 3:40
     (pro-bo-goal 'build    'gateway            6 36 'cybernetics-core  230.0) ;; 3:50
     (pro-bo-goal 'train    'warp-prism         1 36 'robotics-facility 232.0) ;; 3:52 (done 4:30)
     (pro-bo-goal 'build    'gateway            8 38 'cybernetics-core  255.0) ;; 4:15
     (pro-bo-goal 'train    'zealot            16 40 'gateway           265.0)) ;; 4:25
    '((1 . (17.0 .  0.0))
      (2 . (21.0 .  2.0))
      (3 . (27.0 .  4.0))
      (4 . (32.0 . 12.0))
      (5 . (32.0 . 30.0))
      (6 . (32.0 . 54.0))
      (7 . (44.0 . 62.0)))
    (list
     (pro-unit-timing 'adept      1 25 167.0 'cybernetics-core)
     (pro-unit-timing 'stalker    1 32 203.0 'cybernetics-core)
     (pro-unit-timing 'warp-prism 1 40 270.0 'robotics-facility)
     (pro-unit-timing 'zealot    14 48 295.0 'gateway))
    (list
     (pro-upgrade-timing 'warp-gate-research 139.0 239.0 22 'cybernetics-core)
     (pro-upgrade-timing 'charge             182.0 282.0 28 'twilight-council)))
   32
   2
   'none
   0.0
   0
   '()
   (make-hit-trigger 18 285.0 'zealot 'charge)
   0
   405.0
   '(warp-prism zealot stalker adept)
   '(warp-gate-research charge)))

;; PvZ Secondary: sOs / MaNa / VOID Pro Forge Cannon Rush (exact coords dE=13-19 @ 1:03-1:31)
(define PvZ-CANNON-RUSH
  (cheese-build-spec
   'pvz-cannon-rush
   'PvZ
   'Protoss
   (build-order-spec
    'PvZ
    'Protoss
    "PvZ 17-Probe Forge Cannon Rush (sOs / VOID Coords)"
    'one-base-all-in
    "0:18 home Pylon + dual-Probe dispatch -> 0:40 Forge -> 1:05 Proxy Pylon -> 1:28 Photon Cannons + Battery -> 2:06 Natural Nexus + Gateway + Cyber follow-up."
    (list
     (pro-bo-goal 'build  'pylon            1 13 #f       18.0)  ;; 0:18 home
     (pro-bo-goal 'build  'forge            1 15 'pylon   40.0)  ;; 0:40 home
     (pro-bo-goal 'build  'pylon            2 17 'forge   65.0)  ;; 1:05 [PROXY close]
     (pro-bo-goal 'build  'photon-cannon    1 17 'forge   88.0)  ;; 1:28 [PROXY close]
     (pro-bo-goal 'build  'pylon            3 17 'forge   92.0)  ;; 1:32 [PROXY wall]
     (pro-bo-goal 'build  'photon-cannon    3 17 'forge   105.0) ;; 1:45 [PROXY chain]
     (pro-bo-goal 'build  'gateway          1 19 'forge   125.0) ;; 2:05 post-Forge follow-up
     (pro-bo-goal 'expand 'nexus            2 18 'forge   126.0) ;; 2:06 Pro Nat Nexus behind cannons!
     (pro-bo-goal 'build  'photon-cannon    5 19 'forge   132.0) ;; 2:12
     (pro-bo-goal 'build  'assimilator      1 20 'gateway 142.0) ;; 2:22
     (pro-bo-goal 'build  'cybernetics-core 1 21 'gateway 150.0)) ;; 2:30 Pro Cyber follow-up
    '((1 . (16.0 .  0.0))
      (2 . (17.0 .  0.0))
      (3 . (17.0 .  6.0))
      (4 . (17.0 . 12.0))
      (5 . (17.0 . 18.0))
      (6 . (22.0 . 24.0))
      (7 . (34.0 . 36.0)))
    (list
     (pro-unit-timing 'zealot 2 18 165.0 'gateway))
    '())
   17
   2
   'close-cannon
   18.0
   2
   '(pylon photon-cannon pylon photon-cannon photon-cannon shield-battery photon-cannon photon-cannon)
   (make-hit-trigger 2 100.0 #f #f)
   0
   360.0
   '(stalker adept zealot)
   '()))

;; PvT Primary: Canonical LotV Proxy 4-Gate Zealot-Stalker (16-Probe cutoff, hits 2:35!)
(define PvT-PROXY-4GATE-ZEALOT-STALKER
  (cheese-build-spec
   'pvt-proxy-4gate-zealot-stalker
   'PvT
   'Protoss
   (build-order-spec
    'PvT
    'Protoss
    "PvT 16-Probe Proxy 4-Gate Zealot-Stalker All-In (Canonical LotV)"
    'one-base-all-in
    "0:18 Pylon + Probe dispatch -> 0:42 Proxy Pylon -> 15 Gate / 16 Gas / 18 Gas #2 / 19 Cyber @ 1:30 + WarpGate -> 3-4 Proxy Gates pumping Stalkers + Adepts."
    (list
     (pro-bo-goal 'build    'pylon              1 13 #f                18.0)  ;; 0:18 home
     (pro-bo-goal 'build    'pylon              2 15 #f                42.0)  ;; 0:42 [PROXY]
     (pro-bo-goal 'build    'gateway            1 15 'pylon            45.0)  ;; 0:45 [PROXY]
     (pro-bo-goal 'build    'assimilator        1 16 'pylon            48.0)  ;; 0:48 Gas #1
     (pro-bo-goal 'build    'gateway            2 17 'pylon            60.0)  ;; 1:00 [PROXY]
     (pro-bo-goal 'build    'assimilator        2 18 'pylon            65.0)  ;; 1:05 Gas #2
     (pro-bo-goal 'build    'cybernetics-core   1 19 'gateway          90.0)  ;; 1:30 Pro Cyber Core!
     (pro-bo-goal 'build    'pylon              3 19 'gateway          98.0)  ;; 1:38 [PROXY]
     (pro-bo-goal 'build    'gateway            3 20 'gateway          105.0) ;; 1:45 [PROXY]
     (pro-bo-goal 'research 'warp-gate-research 1 20 'cybernetics-core 118.0) ;; 1:58 WarpGate!
     (pro-bo-goal 'build    'gateway            4 20 'cybernetics-core 128.0) ;; 2:08 [PROXY]
     (pro-bo-goal 'train    'stalker            4 20 'cybernetics-core 135.0) ;; 2:15 ranged Stalkers
     (pro-bo-goal 'build    'pylon              4 26 'gateway          155.0))
    '((1 . (17.0 .  0.0))
      (2 . (20.0 .  6.0))
      (3 . (20.0 . 18.0))
      (4 . (20.0 . 26.0))
      (5 . (20.0 . 32.0))
      (6 . (22.0 . 38.0))
      (7 . (34.0 . 46.0)))
    (list
     (pro-unit-timing 'stalker 2 22 150.0 'cybernetics-core)
     (pro-unit-timing 'stalker 6 28 195.0 'cybernetics-core))
    (list
     (pro-upgrade-timing 'warp-gate-research 118.0 218.0 20 'cybernetics-core)))
   20
   1
   'off-path-mid
   18.0
   1
   '(pylon gateway gateway gateway pylon gateway)
   (make-hit-trigger 12 155.0 'stalker #f)
   0
   360.0
   '(stalker adept zealot)
   '(warp-gate-research)))

;; PvT Secondary: Canonical LotV Proxy Stargate Void Ray + Shield Battery (22-Probe cutoff, hits 3:15!)
(define PvT-PROXY-STARGATE-VOIDRAY
  (cheese-build-spec
   'pvt-proxy-stargate-voidray
   'PvT
   'Protoss
   (build-order-spec
    'PvT
    'Protoss
    "PvT 22-Probe Proxy Stargate Void Ray + Shield Battery All-In (Canonical LotV)"
    'one-base-all-in
    "15 Gate / Double Gas / 19 Cyber -> 1:35 Proxy Pylon -> 1:58 Proxy Stargate + 2x Void Rays FIRST + 2x Forward Shield Batteries (expand Nexus #2 in follow-up!)."
    (list
     (pro-bo-goal 'build    'pylon              1 13 #f                18.0)  ;; 0:18
     (pro-bo-goal 'build    'gateway            1 15 'pylon            40.0)  ;; 0:40
     (pro-bo-goal 'build    'assimilator        1 16 'pylon            48.0)  ;; 0:48
     (pro-bo-goal 'build    'assimilator        2 17 'pylon            58.0)  ;; 0:58
     (pro-bo-goal 'build    'cybernetics-core   1 19 'gateway          85.0)  ;; 1:25
     (pro-bo-goal 'build    'pylon              2 20 'cybernetics-core 95.0)  ;; 1:35 [PROXY]
     (pro-bo-goal 'build    'stargate           1 21 'cybernetics-core 118.0) ;; 1:58 [PROXY]
     (pro-bo-goal 'train    'stalker            2 21 'cybernetics-core 122.0) ;; 2:02
     (pro-bo-goal 'research 'warp-gate-research 1 21 'cybernetics-core 126.0) ;; 2:06 WarpGate
     (pro-bo-goal 'build    'shield-battery     1 22 'cybernetics-core 145.0) ;; 2:25 [PROXY]
     (pro-bo-goal 'train    'void-ray           2 23 'stargate         160.0) ;; 2:40 Void Ray #1 & #2 FIRST!
     (pro-bo-goal 'build    'shield-battery     2 26 'cybernetics-core 175.0) ;; 2:55 [PROXY]
     (pro-bo-goal 'build    'pylon              3 28 'stargate         188.0) ;; 3:08
     (pro-bo-goal 'build    'gateway            2 30 'stargate         198.0)) ;; 3:18 Gate #2 after Void Ray starts
    '((1 . (17.0 .  0.0))
      (2 . (21.0 .  2.0))
      (3 . (22.0 . 10.0))
      (4 . (22.0 . 20.0))
      (5 . (22.0 . 28.0))
      (6 . (24.0 . 36.0))
      (7 . (36.0 . 46.0)))
    (list
     (pro-unit-timing 'stalker  2 21 150.0 'cybernetics-core)
     (pro-unit-timing 'void-ray 1 25 190.0 'stargate)
     (pro-unit-timing 'void-ray 2 30 230.0 'stargate))
    (list
     (pro-upgrade-timing 'warp-gate-research 126.0 226.0 21 'cybernetics-core)))
   22
   1
   'off-path-mid
   65.0
   1
   '(pylon stargate shield-battery shield-battery)
   (make-hit-trigger 10 190.0 'void-ray #f)
   0
   390.0
   '(void-ray stalker oracle adept zealot)
   '(warp-gate-research)))

;; PvP Primary: VOID vs KaelThas & NULL vs Waderade Blueprint
;; 22-Probe Proxy Robo Immortal + Warp Prism + 3-Gate All-In (dE=34-48, hits 3:55)
(define PvP-PROXY-ROBO-IMMORTAL
  (cheese-build-spec
   'pvp-proxy-robo-immortal
   'PvP
   'Protoss
   (build-order-spec
    'PvP
    'Protoss
    "PvP 22-Probe Proxy Robo Immortal + Warp Prism All-In (VOID/NULL Blueprint)"
    'one-base-all-in
    "2-Gate Double Gas -> 1:43 Proxy Pylon (dE~42) -> 2:16 Proxy Robotics Facility -> Chrono 2x Immortals FIRST + Warp Prism + Proxy Gate #3 + Battery @ 3:55."
    (list
     (pro-bo-goal 'build    'pylon              1 13 #f                 18.0)  ;; 0:18
     (pro-bo-goal 'build    'gateway            1 15 'pylon             42.0)  ;; 0:42
     (pro-bo-goal 'build    'assimilator        1 16 'pylon             49.0)  ;; 0:49
     (pro-bo-goal 'build    'assimilator        2 17 'pylon             58.0)  ;; 0:58
     (pro-bo-goal 'build    'gateway            2 18 'pylon             71.0)  ;; 1:11
     (pro-bo-goal 'build    'cybernetics-core   1 20 'gateway           95.0)  ;; 1:35
     (pro-bo-goal 'build    'pylon              2 21 'gateway           103.0) ;; 1:43 [PROXY]
     (pro-bo-goal 'research 'warp-gate-research 1 22 'cybernetics-core  115.0) ;; 1:55
     (pro-bo-goal 'build    'robotics-facility  1 22 'cybernetics-core  136.0) ;; 2:16 [PROXY]
     (pro-bo-goal 'train    'stalker            4 22 'cybernetics-core  138.0) ;; 2:18
     (pro-bo-goal 'train    'immortal           2 24 'robotics-facility 165.0) ;; 2:45 Immortal #1 & #2 strictly FIRST!
     (pro-bo-goal 'train    'warp-prism         1 30 'robotics-facility 198.0) ;; 3:18 Prism right after Immortal #1
     (pro-bo-goal 'build    'gateway            3 32 'cybernetics-core  208.0) ;; 3:28 [PROXY]
     (pro-bo-goal 'build    'shield-battery     1 32 'cybernetics-core  212.0)) ;; 3:32 [PROXY]
    '((1 . (17.0 .  0.0))
      (2 . (22.0 .  4.0))
      (3 . (22.0 . 12.0))
      (4 . (22.0 . 22.0))
      (5 . (22.0 . 30.0))
      (6 . (24.0 . 38.0))
      (7 . (36.0 . 48.0)))
    (list
     (pro-unit-timing 'stalker    4 24 165.0 'cybernetics-core)
     (pro-unit-timing 'immortal   1 28 215.0 'robotics-facility)
     (pro-unit-timing 'warp-prism 1 32 245.0 'robotics-facility)
     (pro-unit-timing 'immortal   2 36 255.0 'robotics-facility))
    (list
     (pro-upgrade-timing 'warp-gate-research 115.0 215.0 22 'cybernetics-core)))
   22
   1
   'off-path-mid
   45.0
   1
   '(pylon robotics-facility gateway shield-battery)
   (make-hit-trigger 16 225.0 'immortal #f)
   0
   390.0
   '(immortal warp-prism stalker adept)
   '(warp-gate-research)))

;; PvP Secondary: Pro Forge Cannon Rush (exact VOID/sOs coords dE=13-19 @ 1:03-1:31)
(define PvP-CANNON-RUSH
  (cheese-build-spec
   'pvp-cannon-rush
   'PvP
   'Protoss
   (build-order-spec
    'PvP
    'Protoss
    "PvP 17-Probe Forge Cannon Rush (VOID / sOs Coords)"
    'one-base-all-in
    "0:18 home Pylon + dual-Probe dispatch -> 0:40 Forge -> 17-Probe cutoff -> 1:03 Proxy Pylon (dE~16) -> 1:27 Photon Cannons + Battery containment."
    (list
     (pro-bo-goal 'build 'pylon         1 13 #f     18.0)  ;; 0:18 home
     (pro-bo-goal 'build 'forge         1 15 'pylon 40.0)  ;; 0:40 home
     (pro-bo-goal 'build 'pylon         2 17 'forge 63.0)  ;; 1:03 [PROXY close]
     (pro-bo-goal 'build 'photon-cannon 1 17 'forge 87.0)  ;; 1:27 [PROXY close]
     (pro-bo-goal 'build 'pylon         3 17 'forge 92.0)  ;; 1:32 [PROXY wall]
     (pro-bo-goal 'build 'photon-cannon 3 17 'forge 103.0) ;; 1:43 [PROXY chain]
     (pro-bo-goal 'build 'photon-cannon 5 18 'forge 128.0) ;; 2:08 [PROXY follow-up]
     (pro-bo-goal 'build 'gateway       1 20 'forge 145.0)) ;; 2:25 post-Cannon follow-up
    '((1 . (16.0 .  0.0))
      (2 . (17.0 .  0.0))
      (3 . (17.0 .  6.0))
      (4 . (17.0 . 12.0))
      (5 . (17.0 . 18.0))
      (6 . (22.0 . 24.0))
      (7 . (34.0 . 36.0)))
    (list
     (pro-unit-timing 'zealot 2 18 160.0 'gateway))
    '())
   17
   1
   'close-cannon
   18.0
   2
   '(pylon photon-cannon pylon photon-cannon shield-battery photon-cannon photon-cannon photon-cannon)
   (make-hit-trigger 2 100.0 #f #f)
   0
   360.0
   '(stalker zealot)
   '()))

;; -----------------------------------------------------------------------------
;; 5. Registry & Public Lookup API (Exact Contract)
;; -----------------------------------------------------------------------------

;; Ordered primary-first, secondary-second per matchup (all 18 profiles)
(define CHEESE-PROFILES-BY-MATCHUP
  (hasheq
   'ZvZ (list ZvZ-13-12-LING-BANE ZvZ-12POOL-PROXY-SPINE)
   'ZvP (list ZvP-19D-SPEEDLING-ROACH-RAVAGER ZvP-12POOL-LING-FLOOD)
   'ZvT (list ZvT-26D-ROACH-RAVAGER-BUST ZvT-42D-QUEEN-LING-NYDUS)
   'TvP (list TvP-PROXY-2RAX-MARAUDER TvP-1BASE-2GAS-CYCLONE)
   'TvT (list TvT-PROXY-2RAX-REAPER TvT-1BASE-111-TANK-BUNKER)
   'TvZ (list TvZ-PROXY-2RAX-BUNKER TvZ-REAPER-FE-HELLION-BANSHEE)
   'PvZ (list PvZ-32P-8GATE-CHARGELOT-PRISM PvZ-CANNON-RUSH)
   'PvT (list PvT-PROXY-4GATE-ZEALOT-STALKER PvT-PROXY-STARGATE-VOIDRAY)
   'PvP (list PvP-PROXY-ROBO-IMMORTAL PvP-CANNON-RUSH)))

;; Random-Advantage Playbook Table (`Mothman-XC` when `started-as-random? = #t`):
;; Strictly fast hidden-information cheeses that exploit opponent not knowing
;; our race until ~1:05-1:30 (never slow 42d Nydus, Reaper-FE, 1-1-1 Tank, or
;; 4-Gate Zealot into sealed Terran walls).
(define RANDOM-CHEESE-PROFILES-BY-MATCHUP
  (hasheq
   'ZvZ (list ZvZ-12POOL-PROXY-SPINE ZvZ-13-12-LING-BANE)
   'ZvP (list ZvP-12POOL-LING-FLOOD ZvP-19D-SPEEDLING-ROACH-RAVAGER)
   'ZvT (list ZvT-26D-ROACH-RAVAGER-BUST)
   'TvP (list TvP-PROXY-2RAX-MARAUDER TvP-1BASE-2GAS-CYCLONE)
   'TvT (list TvT-PROXY-2RAX-REAPER)
   'TvZ (list TvZ-PROXY-2RAX-BUNKER)
   'PvZ (list PvZ-CANNON-RUSH PvZ-32P-8GATE-CHARGELOT-PRISM)
   'PvT (list PvT-PROXY-STARGATE-VOIDRAY)
   'PvP (list PvP-CANNON-RUSH PvP-PROXY-ROBO-IMMORTAL)))

;; Fast race-safe hidden-info defaults when enemy is also `'Random` / `'Unknown`
;; (until enemy race is scouted < 45s).
(define RANDOM-VS-UNKNOWN-CHEESE-BY-RACE
  (hasheq
   'Zerg    (list ZvZ-13-12-LING-BANE)
   'Terran  (list TvZ-PROXY-2RAX-BUNKER)
   'Protoss (list PvT-PROXY-STARGATE-VOIDRAY)))

(define all-cheese-build-specs
  (list
   ZvZ-13-12-LING-BANE
   ZvZ-12POOL-PROXY-SPINE
   ZvP-19D-SPEEDLING-ROACH-RAVAGER
   ZvP-12POOL-LING-FLOOD
   ZvT-26D-ROACH-RAVAGER-BUST
   ZvT-42D-QUEEN-LING-NYDUS
   TvP-PROXY-2RAX-MARAUDER
   TvP-1BASE-2GAS-CYCLONE
   TvT-PROXY-2RAX-REAPER
   TvT-1BASE-111-TANK-BUNKER
   TvZ-PROXY-2RAX-BUNKER
   TvZ-REAPER-FE-HELLION-BANSHEE
   PvZ-32P-8GATE-CHARGELOT-PRISM
   PvZ-CANNON-RUSH
   PvT-PROXY-4GATE-ZEALOT-STALKER
   PvT-PROXY-STARGATE-VOIDRAY
   PvP-PROXY-ROBO-IMMORTAL
   PvP-CANNON-RUSH))

(define CHEESE-SPECS-BY-ID
  (for/hasheq ([spec (in-list all-cheese-build-specs)])
    (values (cheese-build-spec-id spec) spec)))

;; Lookup a cheese-build-spec by exact profile ID (symbol or string; #f if unknown)
(define (lookup-cheese-build-spec id)
  (define key (coerce-profile-sym id))
  (if (eq? key 'auto)
      #f
      (hash-ref CHEESE-SPECS-BY-ID key #f)))

;; List ordered (primary, secondary) cheese-build-specs for a matchup.
;; Accepts either 1 arg (`'TvP` / `"TvP"`) or 2 args (`race enemy-race`).
(define (list-cheese-profiles-for-matchup matchup-or-race [enemy-race #f])
  (define m-sym (coerce-matchup-sym matchup-or-race enemy-race))
  (hash-ref CHEESE-PROFILES-BY-MATCHUP m-sym '()))

;; List ordered fast hidden-information cheese-build-specs for `Mothman-XC`
;; (`started-as-random? = #t`). Accepts 1-arg matchup (`'TvP` / `"TvP"`) or
;; 2-arg `(race enemy-race)`. When `enemy-race` is `'Random` / `'Unknown` / `#f`,
;; returns the race-safe fast hidden-info default until enemy race is scouted.
(define (random-cheese-profiles-for-matchup matchup-or-race [enemy-race #f])
  (cond
    [(and (not enemy-race) (matchup-sym? matchup-or-race))
     (hash-ref RANDOM-CHEESE-PROFILES-BY-MATCHUP matchup-or-race '())]
    [(and (not enemy-race) (parse-matchup-token matchup-or-race))
     => (lambda (m-sym) (hash-ref RANDOM-CHEESE-PROFILES-BY-MATCHUP m-sym '()))]
    [else
     (define my-r (normalize-known-race (coerce-race-input matchup-or-race)))
     (define er (coerce-race-input (or enemy-race 'Unknown)))
     (if (memq er '(Random Unknown))
         (hash-ref RANDOM-VS-UNKNOWN-CHEESE-BY-RACE my-r (list ZvZ-13-12-LING-BANE))
         (let ([m-sym (resolve-matchup-symbol my-r er)])
           (hash-ref RANDOM-CHEESE-PROFILES-BY-MATCHUP m-sym '())))]))

;; Select a cheese-build-spec for `(race enemy-race [profile 'auto] [seed 0]
;; #:started-as-random? [started-as-random? #f])`.
;; - Explicit known profile ID returns that exact spec (even if cross-matchup).
;; - `'auto` (or unknown/empty profile) deterministically selects from the
;;   Random-Advantage table when `started-as-random?` is `#t`, or the standard
;;   matchup table when `#f`, using `(modulo (seed->nonneg-int seed) len)`.
;; - Safe fallback for `'Random` / `'Unknown` enemy race.
(define (select-cheese-build-spec race enemy-race [profile 'auto] [seed 0]
                                  #:started-as-random? [started-as-random? #f])
  (define prof-sym (coerce-profile-sym profile))
  (define explicit (and (not (eq? prof-sym 'auto))
                        (lookup-cheese-build-spec prof-sym)))
  (cond
    [explicit explicit]
    [else
     (define pool
       (if started-as-random?
           (random-cheese-profiles-for-matchup race enemy-race)
           (hash-ref CHEESE-PROFILES-BY-MATCHUP (coerce-matchup-sym race enemy-race) '())))
     (if (pair? pool)
         (list-ref pool (modulo (seed->nonneg-int seed) (length pool)))
         ZvP-19D-SPEEDLING-ROACH-RAVAGER)]))

;; -----------------------------------------------------------------------------
;; 6. Loop 87D: State-Driven Post-Edge / Held Follow-Up & Transition Plans
;;    (All 18 Cheeses - consumed by `lib/bot-runtime.rkt` & `priority-macro-brain.rkt`)
;; -----------------------------------------------------------------------------

(define (make-followup-plan #:max-bases max-bases
                            #:worker-cap worker-cap
                            #:bo-steps bo-steps
                            #:army-comp army-comp
                            #:tech-upgrades tech-upgrades
                            #:edge-sec edge-sec
                            #:held-sec held-sec
                            #:graduate-sec graduate-sec)
  (hasheq 'max-bases max-bases
          'worker-cap worker-cap
          'bo-steps bo-steps
          'army-comp army-comp
          'tech-upgrades tech-upgrades
          'edge-sec (exact->inexact edge-sec)
          'held-sec (exact->inexact held-sec)
          'graduate-sec (exact->inexact graduate-sec)))

(define CHEESE-FOLLOWUP-PLANS-BY-ID
  (hasheq
   ;; ---- ZERG EARLY POOL (165s / 215s / 380s -> 3-base Roach-Lair macro conversion) ----
   'zvz-13-12-ling-bane
   (make-followup-plan
    #:max-bases 3 #:worker-cap 44
    #:edge-sec 165.0 #:held-sec 215.0 #:graduate-sec 380.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'hatchery             2 18 'spawning-pool 165.0)
     (pro-bo-goal 'train    'queen                3 24 'spawning-pool 185.0)
     (pro-bo-goal 'build    'roach-warren         1 28 'spawning-pool 205.0)
     (pro-bo-goal 'morph    'lair                 1 34 'spawning-pool 230.0)
     (pro-bo-goal 'expand   'hatchery             3 38 'spawning-pool 250.0)
     (pro-bo-goal 'build    'extractor            2 40 'spawning-pool 265.0)
     (pro-bo-goal 'research 'glial-reconstitution 1 44 'lair          295.0)
     (pro-bo-goal 'train    'roach                8 46 'roach-warren  310.0))
    #:army-comp '(ravager roach baneling zergling queen)
    #:tech-upgrades '(metabolic-boost glial-reconstitution zerg-missile-weapons-1))

   'zvz-12pool-proxy-spine
   (make-followup-plan
    #:max-bases 3 #:worker-cap 44
    #:edge-sec 165.0 #:held-sec 215.0 #:graduate-sec 380.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'hatchery             2 18 'spawning-pool 165.0)
     (pro-bo-goal 'build    'extractor            1 20 'spawning-pool 175.0)
     (pro-bo-goal 'train    'queen                3 22 'spawning-pool 185.0)
     (pro-bo-goal 'research 'metabolic-boost      1 24 'spawning-pool 195.0)
     (pro-bo-goal 'build    'roach-warren         1 28 'spawning-pool 210.0)
     (pro-bo-goal 'morph    'lair                 1 34 'spawning-pool 235.0)
     (pro-bo-goal 'expand   'hatchery             3 38 'spawning-pool 255.0)
     (pro-bo-goal 'research 'glial-reconstitution 1 44 'lair          300.0))
    #:army-comp '(roach ravager baneling zergling queen)
    #:tech-upgrades '(metabolic-boost glial-reconstitution))

   'zvp-12pool-ling-flood
   (make-followup-plan
    #:max-bases 3 #:worker-cap 44
    #:edge-sec 165.0 #:held-sec 215.0 #:graduate-sec 380.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'hatchery             2 20 'spawning-pool 165.0)
     (pro-bo-goal 'train    'queen                3 24 'spawning-pool 185.0)
     (pro-bo-goal 'build    'roach-warren         1 28 'spawning-pool 205.0)
     (pro-bo-goal 'build    'extractor            2 32 'spawning-pool 220.0)
     (pro-bo-goal 'morph    'lair                 1 36 'spawning-pool 235.0)
     (pro-bo-goal 'expand   'hatchery             3 40 'spawning-pool 255.0)
     (pro-bo-goal 'research 'glial-reconstitution 1 46 'lair          300.0)
     (pro-bo-goal 'train    'roach                8 48 'roach-warren  315.0))
    #:army-comp '(ravager roach zergling queen)
    #:tech-upgrades '(metabolic-boost glial-reconstitution zerg-missile-weapons-1))

   ;; ---- ZERG BUSTS & NYDUS (295s / 340s / 460s -> 3-base + Lair + +1 + Hydra/Spire close-out) ----
   'zvp-19d-speedling-roach-ravager
   (make-followup-plan
    #:max-bases 3 #:worker-cap 52
    #:edge-sec 295.0 #:held-sec 340.0 #:graduate-sec 460.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'hatchery               3 42 'spawning-pool     295.0)
     (pro-bo-goal 'build    'extractor              2 44 'spawning-pool     305.0)
     (pro-bo-goal 'morph    'lair                   1 46 'spawning-pool     315.0)
     (pro-bo-goal 'build    'evolution-chamber      1 50 'spawning-pool     330.0)
     (pro-bo-goal 'build    'extractor              3 54 'spawning-pool     345.0)
     (pro-bo-goal 'research 'glial-reconstitution   1 56 'lair              365.0)
     (pro-bo-goal 'research 'zerg-missile-weapons-1 1 58 'evolution-chamber 375.0)
     (pro-bo-goal 'build    'hydralisk-den          1 62 'lair              395.0)
     (pro-bo-goal 'train    'hydralisk              6 68 'hydralisk-den     425.0))
    #:army-comp '(ravager hydralisk roach zergling queen)
    #:tech-upgrades '(glial-reconstitution zerg-missile-weapons-1 grooved-spines))

   'zvt-26d-roach-ravager-bust
   (make-followup-plan
    #:max-bases 3 #:worker-cap 52
    #:edge-sec 295.0 #:held-sec 340.0 #:graduate-sec 460.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'hatchery               3 46 'spawning-pool     295.0)
     (pro-bo-goal 'morph    'lair                   1 48 'spawning-pool     305.0)
     (pro-bo-goal 'build    'evolution-chamber      1 52 'spawning-pool     320.0)
     (pro-bo-goal 'build    'extractor              3 54 'spawning-pool     330.0)
     (pro-bo-goal 'research 'glial-reconstitution   1 56 'lair              360.0)
     (pro-bo-goal 'research 'zerg-missile-weapons-1 1 58 'evolution-chamber 370.0)
     (pro-bo-goal 'build    'spire                  1 62 'lair              385.0)
     (pro-bo-goal 'train    'mutalisk               4 68 'spire             430.0))
    #:army-comp '(ravager roach mutalisk hydralisk zergling queen)
    #:tech-upgrades '(glial-reconstitution zerg-missile-weapons-1 zerg-ground-armor-1))

   'zvt-42d-queen-ling-nydus
   (make-followup-plan
    #:max-bases 3 #:worker-cap 54
    #:edge-sec 295.0 #:held-sec 340.0 #:graduate-sec 460.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'hatchery               3 44 'spawning-pool     295.0)
     (pro-bo-goal 'build    'extractor              3 50 'spawning-pool     315.0)
     (pro-bo-goal 'build    'evolution-chamber      1 54 'spawning-pool     325.0)
     (pro-bo-goal 'build    'roach-warren           1 56 'spawning-pool     335.0)
     (pro-bo-goal 'research 'zerg-missile-weapons-1 1 60 'evolution-chamber 355.0)
     (pro-bo-goal 'research 'glial-reconstitution   1 62 'lair              370.0)
     (pro-bo-goal 'build    'spire                  1 64 'lair              385.0)
     (pro-bo-goal 'train    'mutalisk               4 70 'spire             430.0))
    #:army-comp '(ravager roach mutalisk hydralisk queen zergling)
    #:tech-upgrades '(glial-reconstitution zerg-missile-weapons-1 zerg-ground-armor-1))

   ;; ---- TERRAN PROXIES (220s / 265s / 420s -> 2-base Bio-Tank-Medivac kill push) ----
   'tvp-proxy-2rax-marauder
   (make-followup-plan
    #:max-bases 2 #:worker-cap 44
    #:edge-sec 220.0 #:held-sec 265.0 #:graduate-sec 420.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'command-center  2 26 'barracks         220.0)
     (pro-bo-goal 'build    'refinery        2 28 'barracks         235.0)
     (pro-bo-goal 'build    'factory         1 30 'barracks         245.0)
     (pro-bo-goal 'research 'stimpack        1 32 'barracks-techlab 255.0)
     (pro-bo-goal 'morph    'orbital-command 2 34 'barracks         275.0)
     (pro-bo-goal 'build    'barracks        3 36 'barracks         285.0)
     (pro-bo-goal 'build    'starport        1 38 'factory          300.0)
     (pro-bo-goal 'build    'factory-techlab 1 40 'factory          310.0)
     (pro-bo-goal 'research 'combat-shield   1 42 'barracks-techlab 325.0)
     (pro-bo-goal 'train    'medivac         2 44 'starport         340.0)
     (pro-bo-goal 'train    'siege-tank      2 46 'factory-techlab  355.0))
    #:army-comp '(siege-tank medivac marauder marine)
    #:tech-upgrades '(stimpack combat-shield concussive-shells))

   'tvt-proxy-2rax-reaper
   (make-followup-plan
    #:max-bases 2 #:worker-cap 44
    #:edge-sec 220.0 #:held-sec 265.0 #:graduate-sec 420.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'command-center   2 26 'barracks         220.0)
     (pro-bo-goal 'build    'factory-techlab  1 28 'factory          235.0)
     (pro-bo-goal 'build    'starport         1 30 'factory          250.0)
     (pro-bo-goal 'build    'barracks-techlab 1 32 'barracks         260.0)
     (pro-bo-goal 'morph    'orbital-command  2 34 'barracks         275.0)
     (pro-bo-goal 'build    'barracks         3 36 'barracks         285.0)
     (pro-bo-goal 'research 'stimpack         1 38 'barracks-techlab 300.0)
     (pro-bo-goal 'train    'siege-tank       3 40 'factory-techlab  315.0)
     (pro-bo-goal 'train    'medivac          2 44 'starport         335.0)
     (pro-bo-goal 'research 'combat-shield    1 46 'barracks-techlab 355.0))
    #:army-comp '(siege-tank medivac viking-fighter hellion marine)
    #:tech-upgrades '(stimpack combat-shield))

   'tvz-proxy-2rax-bunker
   (make-followup-plan
    #:max-bases 2 #:worker-cap 44
    #:edge-sec 220.0 #:held-sec 265.0 #:graduate-sec 420.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'command-center   2 24 'barracks         220.0)
     (pro-bo-goal 'build    'refinery         2 26 'barracks         230.0)
     (pro-bo-goal 'build    'factory          1 28 'barracks         240.0)
     (pro-bo-goal 'build    'barracks-techlab 1 30 'barracks         255.0)
     (pro-bo-goal 'morph    'orbital-command  2 34 'barracks         275.0)
     (pro-bo-goal 'build    'barracks         3 36 'barracks         285.0)
     (pro-bo-goal 'build    'starport         1 38 'factory          295.0)
     (pro-bo-goal 'build    'factory-techlab  1 40 'factory          305.0)
     (pro-bo-goal 'research 'stimpack         1 42 'barracks-techlab 320.0)
     (pro-bo-goal 'train    'medivac          2 44 'starport         340.0)
     (pro-bo-goal 'train    'siege-tank       2 46 'factory-techlab  355.0)
     (pro-bo-goal 'research 'combat-shield    1 48 'barracks-techlab 370.0))
    #:army-comp '(siege-tank medivac hellion marauder marine)
    #:tech-upgrades '(stimpack combat-shield))

   ;; ---- TERRAN 1-BASE TECH (235s / 285s / 430s -> 2-base Bio-Tank-Medivac, zero T111 stall) ----
   'tvp-1base-2gas-cyclone
   (make-followup-plan
    #:max-bases 2 #:worker-cap 46
    #:edge-sec 235.0 #:held-sec 285.0 #:graduate-sec 430.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'command-center   2 34 'factory          235.0)
     (pro-bo-goal 'build    'barracks         2 36 'barracks         250.0)
     (pro-bo-goal 'build    'barracks-techlab 1 38 'barracks         265.0)
     (pro-bo-goal 'build    'starport         1 40 'factory          275.0)
     (pro-bo-goal 'morph    'orbital-command  2 42 'barracks         295.0)
     (pro-bo-goal 'build    'barracks         3 44 'barracks         305.0)
     (pro-bo-goal 'research 'stimpack         1 46 'barracks-techlab 320.0)
     (pro-bo-goal 'build    'factory-techlab  1 48 'factory          335.0)
     (pro-bo-goal 'train    'medivac          2 50 'starport         350.0)
     (pro-bo-goal 'train    'siege-tank       2 52 'factory-techlab  365.0)
     (pro-bo-goal 'research 'combat-shield    1 54 'barracks-techlab 385.0))
    #:army-comp '(siege-tank cyclone medivac viking-fighter marauder marine)
    #:tech-upgrades '(stimpack combat-shield))

   'tvt-1base-111-tank-bunker
   (make-followup-plan
    #:max-bases 2 #:worker-cap 46
    #:edge-sec 235.0 #:held-sec 285.0 #:graduate-sec 430.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'command-center   2 34 'factory          235.0)
     (pro-bo-goal 'build    'barracks         2 36 'barracks         250.0)
     (pro-bo-goal 'build    'barracks-techlab 1 38 'barracks         265.0)
     (pro-bo-goal 'morph    'orbital-command  2 42 'barracks         295.0)
     (pro-bo-goal 'build    'barracks         3 44 'barracks         305.0)
     (pro-bo-goal 'research 'stimpack         1 46 'barracks-techlab 320.0)
     (pro-bo-goal 'train    'medivac          2 48 'starport         335.0)
     (pro-bo-goal 'train    'siege-tank       4 50 'factory-techlab  350.0)
     (pro-bo-goal 'train    'viking-fighter   4 52 'starport         365.0)
     (pro-bo-goal 'research 'combat-shield    1 54 'barracks-techlab 385.0))
    #:army-comp '(siege-tank viking-fighter medivac marine)
    #:tech-upgrades '(stimpack combat-shield))

   ;; ---- TERRAN MACRO PRESSURE (270s / 310s / 440s -> 3rd CC + 5 Rax + +1/+1 Bio-Tank) ----
   'tvz-reaper-fe-hellion-banshee
   (make-followup-plan
    #:max-bases 3 #:worker-cap 56
    #:edge-sec 270.0 #:held-sec 310.0 #:graduate-sec 440.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'command-center           3 44 'starport         270.0)
     (pro-bo-goal 'build    'barracks                 3 46 'starport         280.0)
     (pro-bo-goal 'build    'barracks-techlab         1 48 'barracks         290.0)
     (pro-bo-goal 'build    'engineering-bay          2 52 'barracks         305.0)
     (pro-bo-goal 'research 'stimpack                 1 54 'barracks-techlab 315.0)
     (pro-bo-goal 'build    'factory-techlab          1 56 'factory          325.0)
     (pro-bo-goal 'research 'terran-infantry-weapons-1 1 58 'engineering-bay 335.0)
     (pro-bo-goal 'research 'terran-infantry-armor-1   1 60 'engineering-bay 340.0)
     (pro-bo-goal 'build    'barracks                 5 64 'barracks         355.0)
     (pro-bo-goal 'research 'combat-shield            1 66 'barracks-techlab 370.0)
     (pro-bo-goal 'train    'medivac                  2 68 'starport         380.0)
     (pro-bo-goal 'train    'siege-tank               3 70 'factory-techlab  395.0))
    #:army-comp '(siege-tank medivac banshee hellion marauder marine)
    #:tech-upgrades '(stimpack combat-shield terran-infantry-weapons-1 terran-infantry-armor-1))

   ;; ---- PROTOSS CANNON RUSHES (145s / 195s / 390s -> 2-base Robo Immortal + Prism contain) ----
   'pvz-cannon-rush
   (make-followup-plan
    #:max-bases 2 #:worker-cap 40
    #:edge-sec 145.0 #:held-sec 195.0 #:graduate-sec 390.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'nexus              2 18 'forge             145.0)
     (pro-bo-goal 'build    'gateway            1 19 'forge             150.0)
     (pro-bo-goal 'build    'assimilator        1 20 'gateway           160.0)
     (pro-bo-goal 'build    'cybernetics-core   1 21 'gateway           175.0)
     (pro-bo-goal 'build    'assimilator        2 24 'cybernetics-core  195.0)
     (pro-bo-goal 'build    'robotics-facility  1 26 'cybernetics-core  215.0)
     (pro-bo-goal 'research 'warp-gate-research 1 26 'cybernetics-core  220.0)
     (pro-bo-goal 'build    'gateway            3 30 'cybernetics-core  245.0)
     (pro-bo-goal 'train    'immortal           2 32 'robotics-facility 265.0)
     (pro-bo-goal 'train    'warp-prism         1 36 'robotics-facility 295.0))
    #:army-comp '(immortal warp-prism stalker adept zealot)
    #:tech-upgrades '(warp-gate-research protoss-ground-weapons-1))

   'pvp-cannon-rush
   (make-followup-plan
    #:max-bases 2 #:worker-cap 40
    #:edge-sec 145.0 #:held-sec 195.0 #:graduate-sec 390.0
    #:bo-steps
    (list
     (pro-bo-goal 'build    'gateway            1 19 'forge             145.0)
     (pro-bo-goal 'build    'assimilator        1 20 'gateway           155.0)
     (pro-bo-goal 'expand   'nexus              2 21 'gateway           170.0)
     (pro-bo-goal 'build    'cybernetics-core   1 22 'gateway           180.0)
     (pro-bo-goal 'build    'assimilator        2 24 'cybernetics-core  200.0)
     (pro-bo-goal 'build    'robotics-facility  1 26 'cybernetics-core  215.0)
     (pro-bo-goal 'research 'warp-gate-research 1 26 'cybernetics-core  220.0)
     (pro-bo-goal 'build    'gateway            3 30 'cybernetics-core  245.0)
     (pro-bo-goal 'train    'immortal           2 32 'robotics-facility 265.0)
     (pro-bo-goal 'train    'warp-prism         1 36 'robotics-facility 295.0))
    #:army-comp '(immortal warp-prism stalker adept zealot)
    #:tech-upgrades '(warp-gate-research protoss-ground-weapons-1))

   ;; ---- PROTOSS PROXIES (225s / 275s / 430s -> 2-base Twilight + Robo + 4-Gate, zero 1-base lockout) ----
   'pvt-proxy-4gate-zealot-stalker
   (make-followup-plan
    #:max-bases 2 #:worker-cap 42
    #:edge-sec 225.0 #:held-sec 275.0 #:graduate-sec 430.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'nexus             2 26 'cybernetics-core  225.0)
     (pro-bo-goal 'build    'twilight-council  1 28 'cybernetics-core  245.0)
     (pro-bo-goal 'build    'robotics-facility 1 32 'cybernetics-core  270.0)
     (pro-bo-goal 'research 'blink             1 34 'twilight-council  290.0)
     (pro-bo-goal 'build    'gateway           4 36 'cybernetics-core  305.0)
     (pro-bo-goal 'train    'observer          1 38 'robotics-facility 320.0)
     (pro-bo-goal 'train    'immortal          2 42 'robotics-facility 345.0))
    #:army-comp '(immortal observer stalker zealot adept)
    #:tech-upgrades '(warp-gate-research blink charge))

   'pvt-proxy-stargate-voidray
   (make-followup-plan
    #:max-bases 2 #:worker-cap 42
    #:edge-sec 225.0 #:held-sec 275.0 #:graduate-sec 430.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'nexus             2 28 'stargate          225.0)
     (pro-bo-goal 'build    'gateway           3 32 'cybernetics-core  245.0)
     (pro-bo-goal 'build    'twilight-council  1 34 'cybernetics-core  265.0)
     (pro-bo-goal 'build    'robotics-facility 1 36 'cybernetics-core  285.0)
     (pro-bo-goal 'research 'charge            1 38 'twilight-council  305.0)
     (pro-bo-goal 'build    'gateway           4 40 'cybernetics-core  320.0)
     (pro-bo-goal 'train    'observer          1 42 'robotics-facility 335.0)
     (pro-bo-goal 'train    'immortal          2 44 'robotics-facility 355.0))
    #:army-comp '(void-ray immortal observer stalker zealot)
    #:tech-upgrades '(warp-gate-research charge blink))

   'pvp-proxy-robo-immortal
   (make-followup-plan
    #:max-bases 2 #:worker-cap 42
    #:edge-sec 225.0 #:held-sec 275.0 #:graduate-sec 430.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'nexus             2 30 'robotics-facility 225.0)
     (pro-bo-goal 'build    'twilight-council  1 34 'cybernetics-core  250.0)
     (pro-bo-goal 'build    'gateway           4 36 'cybernetics-core  270.0)
     (pro-bo-goal 'research 'blink             1 38 'twilight-council  290.0)
     (pro-bo-goal 'train    'observer          1 40 'robotics-facility 305.0)
     (pro-bo-goal 'train    'immortal          3 42 'robotics-facility 325.0))
    #:army-comp '(immortal warp-prism observer stalker zealot)
    #:tech-upgrades '(warp-gate-research blink charge))

   ;; ---- PROTOSS 2-BASE ALL-IN (340s / 385s / 490s -> 3rd Nexus + Archon + +1 + Immortal) ----
   'pvz-32p-8gate-chargelot-prism
   (make-followup-plan
    #:max-bases 3 #:worker-cap 52
    #:edge-sec 340.0 #:held-sec 385.0 #:graduate-sec 490.0
    #:bo-steps
    (list
     (pro-bo-goal 'expand   'nexus                    3 50 'twilight-council  340.0)
     (pro-bo-goal 'build    'forge                    1 52 'gateway           355.0)
     (pro-bo-goal 'build    'templar-archive          1 56 'twilight-council  370.0)
     (pro-bo-goal 'research 'protoss-ground-weapons-1 1 58 'forge             390.0)
     (pro-bo-goal 'train    'immortal                 2 60 'robotics-facility 400.0)
     (pro-bo-goal 'train    'high-templar             4 64 'templar-archive   420.0)
     (pro-bo-goal 'morph    'archon                   2 68 'templar-archive   440.0))
    #:army-comp '(archon immortal warp-prism stalker zealot)
    #:tech-upgrades '(charge protoss-ground-weapons-1 warp-gate-research))))

;; Lookup the state-driven post-edge/held follow-up transition plan for any of
;; the 18 cheese profile IDs (accepts symbol, string, or `cheese-build-spec`).
(define (cheese-followup-plan id-or-spec)
  (define key
    (cond
      [(cheese-build-spec? id-or-spec) (cheese-build-spec-id id-or-spec)]
      [else (coerce-profile-sym id-or-spec)]))
  (if (eq? key 'auto)
      #f
      (hash-ref CHEESE-FOLLOWUP-PLANS-BY-ID key #f)))

;; Construct a 15-field `cheese-build-spec` overlaid with its follow-up plan
;; (`max-bases`, `worker-cap`, follow-up `bo-steps`, `army-comp`, `tech-upgrades`,
;; and `fallback-macro-sec = graduate-sec`) for `'follow-up` phase evaluation.
(define (cheese-build-spec-for-followup id-or-spec)
  (define base
    (if (cheese-build-spec? id-or-spec)
        id-or-spec
        (lookup-cheese-build-spec id-or-spec)))
  (define fu (and base (cheese-followup-plan base)))
  (cond
    [(and base fu)
     (define orig-bo (cheese-build-spec-bo-spec base))
     (define fu-wcap (exact->inexact (hash-ref fu 'worker-cap (cheese-build-spec-worker-cap base))))
     (define fu-curve
       (list (cons 1 (cons (min 17.0 fu-wcap) 0.0))
             (cons 2 (cons (min 22.0 fu-wcap) 6.0))
             (cons 3 (cons (min 30.0 fu-wcap) 16.0))
             (cons 4 (cons (min 38.0 fu-wcap) 28.0))
             (cons 5 (cons (min 44.0 fu-wcap) 40.0))
             (cons 6 (cons fu-wcap 52.0))
             (cons 7 (cons fu-wcap 66.0))
             (cons 8 (cons fu-wcap 80.0))))
     (define fu-bo
       (build-order-spec
        (build-order-spec-matchup orig-bo)
        (build-order-spec-race orig-bo)
        (string-append (build-order-spec-name orig-bo) " [Follow-Up]")
        'macro-transition
        "State-driven post-edge/held macro follow-up transition."
        (hash-ref fu 'bo-steps '())
        fu-curve
        (build-order-spec-unit-timings orig-bo)
        (build-order-spec-upgrade-timings orig-bo)))
     (cheese-build-spec
      (cheese-build-spec-id base)
      (cheese-build-spec-matchup base)
      (cheese-build-spec-race base)
      fu-bo
      (hash-ref fu 'worker-cap (cheese-build-spec-worker-cap base))
      (hash-ref fu 'max-bases (cheese-build-spec-max-bases base))
      (cheese-build-spec-proxy-kind base)
      (cheese-build-spec-proxy-dispatch-sec base)
      (cheese-build-spec-proxy-worker-count base)
      (cheese-build-spec-proxy-buildings base)
      (cheese-build-spec-hit-trigger base)
      0
      (hash-ref fu 'graduate-sec (cheese-build-spec-fallback-macro-sec base))
      (hash-ref fu 'army-comp (cheese-build-spec-army-comp base))
      (hash-ref fu 'tech-upgrades (cheese-build-spec-key-upgrades base)))]
    [else base]))
