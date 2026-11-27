#lang racket/base

;; =============================================================================
;; Loop 87 Track 5 Unit Test Suite (`tests/l87-owm-full-belief-telemetry-test.rkt`)
;;
;; Verifies full 7-dimension Opponent World Model belief telemetry & logging:
;;   1. Zero struct ABI change (`opponent-world-summary` = 35 fields,
;;      `bot-mind-log-snapshot` = 14 fields).
;;   2. Instantaneous `min-rate-per-min` (`M/min`) & `gas-rate-per-min` (`G/min`)
;;      from the final step of `integrate-opponent-economy` (stored in weak
;;      side-tables, sensitive to base/gas count and worker kills, 0 at f=0).
;;   3. `owm-belief-telemetry-snapshot` across Terran, Protoss, and Zerg:
;;      - Bases (`confirmed-bases`, `estimated-bases`) & Gases
;;      - Workers (`est-workers`, `seen-workers`)
;;      - Income (`est-min-rate`, `est-gas-rate`, `cum-min`, `cum-gas`)
;;      - Production facilities (`prod`): spatially-deduped `known-bldgs` +
;;        `warp-gate -> gateway` normalization + tech-implied `>= 1` +
;;        Zerg `hatchery`/`lair`/`hive` tiering
;;      - Upgrades (`upgrades`): OWM observed/inferred + real `mirror-mind-state`
;;        `last-tech-observation` merge, sorted & deduplicated
;;      - Combat units (`units`): alive combat counts excluding workers,
;;        Overlords, free summons, and static structures
;;      - Unseen resources & `believed-army-val`
;;   4. `format-owm-belief-log-line` exact single-line `[SCBOT_OWM]` format,
;;      strict regex round-trip, sorted keys, zero spaces in parens, zero
;;      em/en dashes, and total safety on empty / `#f` / unstepped inputs.
;; =============================================================================

(require racket/list
         racket/string
         "../lib/opponent-world-model.rkt"
         "../lib/sc2-logging.rkt"
         (only-in "../lib/mirror-mind-predictor.rkt"
                  make-mirror-mind-state
                  step-mirror-mind-predictor!))

(define pass-count 0)
(define fail-count 0)

(define (check-true name expr [detail ""])
  (if expr
      (begin
        (set! pass-count (add1 pass-count))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "  [FAIL] ~a~a\n"
                name
                (if (string=? detail "") "" (format " (~a)" detail))))))

(define (check-equal name actual expected)
  (check-true name
              (equal? actual expected)
              (format "expected=~s got=~s" expected actual)))

(define OWM-LOG-RX
  #px"^\\[SCBOT_OWM\\] f=([0-9]+) b=([0-9]+)/([0-9]+) g=([0-9]+)/([0-9]+) w=([0-9]+)/([0-9]+) inc=([0-9]+)M/([0-9]+)G prod=\\(([^ )]*)\\) upg=\\(([^ )]*)\\) units=\\(([^ )]*)\\) unseen=([0-9]+)M/([0-9]+)G arm=([0-9]+)$")

(define (parse-kv-csv s)
  (if (string=? s "")
      (hasheq)
      (for/hasheq ([tok (in-list (string-split s ","))])
        (define parts (string-split tok ":"))
        (values (string->symbol (first parts))
                (string->number (second parts))))))

(define (parse-upg-csv s)
  (if (string=? s "")
      '()
      (map string->symbol (string-split s ","))))

(define (mk-obs frame erace ally-units enemy-bldgs enemy-units
                #:workers-killed [wk 0]
                #:dead-tags [dead-tags '()])
  (hasheq 'frame frame
          'enemy-race erace
          'base-x 32.0 'base-y 32.0
          'natural-x 50.0 'natural-y 42.0
          'enemy-x 160.0 'enemy-y 160.0
          'enemy-exp-x 142.0 'enemy-exp-y 150.0
          'enemy-third-x 125.0 'enemy-third-y 155.0
          'enemy-fourth-x 155.0 'enemy-fourth-y 120.0
          'ally-units ally-units
          'enemy-buildings enemy-bldgs
          'enemy-units enemy-units
          'enemy-workers-killed wk
          'dead-unit-tags dead-tags))

;; =============================================================================
;; Group 1: Strict Struct ABI Invariants (`35` / `14`) & f=0 Baseline
;; =============================================================================
(printf "\n=== Group 1: ABI Invariants & f=0 Baseline ===\n")

(let* ([owm (make-opponent-world-model 'Terran)]
       [s0 (step-opponent-world-model! owm (mk-obs 0 'Terran '() '() '()))]
       [snap0 (owm-belief-telemetry-snapshot owm #f 0)]
       [line0 (format-owm-belief-log-line snap0)]
       [rec (extract-bot-step-log-record (hasheq 'frame 0 'race 'Protoss 'enemy-race 'Terran))])
  (check-equal "abi-opponent-world-summary-35-fields"
               (sub1 (vector-length (struct->vector s0)))
               35)
  (check-equal "abi-bot-mind-log-snapshot-14-fields"
               (sub1 (vector-length (struct->vector (bot-step-log-record-mind rec))))
               14)
  (check-equal "f0-est-min-rate-is-0" (hash-ref snap0 'est-min-rate) 0)
  (check-equal "f0-est-gas-rate-is-0" (hash-ref snap0 'est-gas-rate) 0)
  (check-equal "f0-owm-rate-accessors-match"
               (list (owm-estimated-min-rate owm)
                     (owm-estimated-gas-rate owm)
                     (owm-estimated-min-rate s0)
                     (owm-estimated-gas-rate s0))
               '(0 0 0 0))
  (check-true "f0-log-line-matches-regex" (not (not (regexp-match OWM-LOG-RX line0))) line0)
  (check-true "f0-log-line-has-inc-0M-0G" (string-contains? line0 "inc=0M/0G") line0))

;; =============================================================================
;; Group 2: Terran Midgame -- Spatial Dedup, Tech-Implied Prod, Income, Real mmstate
;; =============================================================================
(printf "\n=== Group 2: Terran 7-Dimension Snapshot & Real mmstate Merge ===\n")

(let* ([owm (make-opponent-world-model 'Terran)]
       [ebldgs
        (list (hasheq 'id 101 'type 'orbital-command 'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 102 'type 'command-center  'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 103 'type 'refinery        'x 165.0 'y 155.0 'hp 500  'build-progress 1.0 'vespene-contents 1600)
              (hasheq 'id 104 'type 'refinery        'x 155.0 'y 165.0 'hp 500  'build-progress 1.0 'vespene-contents 1800)
              (hasheq 'id 105 'type 'barracks        'x 150.0 'y 152.0 'hp 1000 'build-progress 1.0)
              ;; Duplicate snapshot tag at nearly identical coords (< 2.5t) -> must dedup!
              (hasheq 'id 199 'type 'barracks        'x 150.5 'y 152.5 'hp 1000 'build-progress 1.0)
              (hasheq 'id 106 'type 'barracks-flying 'x 144.0 'y 144.0 'hp 1000 'build-progress 1.0)
              (hasheq 'id 107 'type 'bunker          'x 138.0 'y 148.0 'hp 400  'build-progress 1.0))]
       [eunits
        (list (hasheq 'id 201 'type 'marine  'x 136.0 'y 146.0 'hp 55 'max-hp 55 'attack-upgrade-level 1)
              (hasheq 'id 202 'type 'marine  'x 136.5 'y 146.5 'hp 55 'max-hp 55 'attack-upgrade-level 1)
              (hasheq 'id 203 'type 'marine  'x 137.0 'y 146.0 'hp 55 'max-hp 55 'attack-upgrade-level 1)
              (hasheq 'id 204 'type 'marine  'x 137.5 'y 146.5 'hp 55 'max-hp 55 'attack-upgrade-level 1)
              ;; Banshee implies unseen Factory + Starport!
              (hasheq 'id 205 'type 'banshee 'x 130.0 'y 140.0 'hp 140 'max-hp 140)
              ;; 3 seen SCVs -> counted in `seen-workers`, excluded from `units`
              (hasheq 'id 210 'type 'scv     'x 161.0 'y 162.0 'hp 45 'max-hp 45)
              (hasheq 'id 211 'type 'scv     'x 162.0 'y 161.0 'hp 45 'max-hp 45)
              (hasheq 'id 212 'type 'scv     'x 143.0 'y 151.0 'hp 45 'max-hp 45)
              ;; Free summon MULE -> excluded from `units`
              (hasheq 'id 213 'type 'mule    'x 161.5 'y 161.5 'hp 60 'max-hp 60))]
       [obs-early (mk-obs 3584 'Terran '()
                          (list (hasheq 'id 101 'type 'orbital-command 'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)
                                (hasheq 'id 102 'type 'command-center  'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0))
                          '())]
       [_early (step-opponent-world-model! owm obs-early)]
       [obs (mk-obs 8064 'Terran '() ebldgs eunits)]
       [sum (step-opponent-world-model! owm obs)]
       ;; Real `mirror-mind-state` observing stimpack + cloaking-field + +1 armor
       [mm (make-mirror-mind-state #:our-race 'Protoss #:enemy-race 'Terran)]
       [_ (step-mirror-mind-predictor!
           mm
           (hasheq 'frame 8064
                   'our-race 'Protoss
                   'enemy-race 'Terran
                   'minerals 200 'gas 100
                   'enemy-buildings ebldgs
                   'enemy-units
                   (list (hasheq 'id 201 'type 'marine 'x 136.0 'y 146.0
                                 'hp 55 'max-hp 55 'attack-upgrade-level 1 'armor-upgrade-level 1
                                 'buffs '(stimpack))
                         (hasheq 'id 205 'type 'banshee 'x 130.0 'y 140.0
                                 'hp 140 'max-hp 140 'spells '(cloaking-field)))))]
       [snap-owm (owm-belief-telemetry-snapshot owm mm 8064)]
       [snap-sum (owm-belief-telemetry-snapshot sum mm 8064)]
       [snap-no-mm (owm-belief-telemetry-snapshot owm #f 8064)])

  (check-true "terran-all-17-keys-present"
              (for/and ([k (in-list '(frame confirmed-bases estimated-bases
                                      confirmed-gases estimated-gases
                                      est-workers seen-workers
                                      est-min-rate est-gas-rate cum-min cum-gas
                                      prod upgrades units
                                      unseen-min unseen-gas believed-army-val))])
                (hash-has-key? snap-owm k)))
  (check-equal "terran-owm-and-summary-snapshots-identical" snap-owm snap-sum)
  (check-equal "terran-frame" (hash-ref snap-owm 'frame) 8064)
  (check-equal "terran-confirmed-bases" (hash-ref snap-owm 'confirmed-bases) 2)
  (check-true "terran-estimated-bases-ge-2" (>= (hash-ref snap-owm 'estimated-bases) 2))
  (check-equal "terran-confirmed-gases" (hash-ref snap-owm 'confirmed-gases) 2)
  (check-true "terran-estimated-gases-ge-2" (>= (hash-ref snap-owm 'estimated-gases) 2))
  (check-true "terran-est-workers-plausible" (> (hash-ref snap-owm 'est-workers) 25)
              (format "est-w=~a" (hash-ref snap-owm 'est-workers)))
  (check-equal "terran-seen-workers" (hash-ref snap-owm 'seen-workers) 3)
  (check-true "terran-income-rates-plausible"
              (and (> (hash-ref snap-owm 'est-min-rate) 1000)
                   (< (hash-ref snap-owm 'est-min-rate) 4500)
                   (> (hash-ref snap-owm 'est-gas-rate) 150)
                   (< (hash-ref snap-owm 'est-gas-rate) 1200)
                   (> (hash-ref snap-owm 'cum-min) 4000)
                   (> (hash-ref snap-owm 'cum-gas) 400))
              (format "mrate=~a grate=~a cumM=~a cumG=~a"
                      (hash-ref snap-owm 'est-min-rate)
                      (hash-ref snap-owm 'est-gas-rate)
                      (hash-ref snap-owm 'cum-min)
                      (hash-ref snap-owm 'cum-gas)))
  ;; Prod: 2 deduped Barracks (NOT 3!) + tech-implied Factory(1) + Starport(1), NO Bunker/CC/Refinery
  (check-equal "terran-prod-dedup-and-implied"
               (hash-ref snap-owm 'prod)
               (hasheq 'barracks 2 'factory 1 'starport 1))
  ;; Units: combat-only projection (Marine >= 4, Banshee >= 1; strictly NO SCVs, NO MULEs, NO hallucinated types)
  (check-true "terran-units-combat-only"
              (let ([u (hash-ref snap-owm 'units)])
                (and (>= (hash-ref u 'marine 0) 4)
                     (>= (hash-ref u 'banshee 0) 1)
                     (= (hash-count u) 2)
                     (not (hash-has-key? u 'scv))
                     (not (hash-has-key? u 'mule))))
              (format "got=~s" (hash-ref snap-owm 'units)))
  ;; Upgrades: OWM alone catches combat-shield + exact terran-infantry-weapons-1 (deduping enemy-weapons-1)
  (check-equal "terran-upgrades-owm-only"
               (hash-ref snap-no-mm 'upgrades)
               '(combat-shield terran-infantry-weapons-1))
  ;; Upgrades merged with real mmstate: includes stimpack, cloaking-field, enemy-armor-1, sorted!
  (check-true "terran-upgrades-merged-with-real-mmstate"
              (let ([upgs (hash-ref snap-owm 'upgrades)])
                (and (member 'combat-shield upgs)
                     (member 'terran-infantry-weapons-1 upgs)
                     (not (member 'enemy-weapons-1 upgs))
                     (member 'enemy-armor-1 upgs)
                     (member 'stimpack upgs)
                     (member 'cloaking-field upgs)
                     (equal? upgs (sort (remove-duplicates upgs) symbol<?))))
              (format "upgs=~s" (hash-ref snap-owm 'upgrades)))

  ;; Exact `[SCBOT_OWM]` formatting + regex round-trip check
  (define line (format-owm-belief-log-line snap-owm))
  (define m (regexp-match OWM-LOG-RX line))
  (check-true "terran-log-line-exact-regex" (not (not m)) line)
  (check-true "terran-log-line-zero-em-or-en-dash"
              (and (not (string-contains? line "\u2014"))
                   (not (string-contains? line "\u2013"))))
  (when m
    (check-equal "rt-frame" (string->number (list-ref m 1)) (hash-ref snap-owm 'frame))
    (check-equal "rt-conf-b" (string->number (list-ref m 2)) (hash-ref snap-owm 'confirmed-bases))
    (check-equal "rt-est-b" (string->number (list-ref m 3)) (hash-ref snap-owm 'estimated-bases))
    (check-equal "rt-conf-g" (string->number (list-ref m 4)) (hash-ref snap-owm 'confirmed-gases))
    (check-equal "rt-est-g" (string->number (list-ref m 5)) (hash-ref snap-owm 'estimated-gases))
    (check-equal "rt-est-w" (string->number (list-ref m 6)) (hash-ref snap-owm 'est-workers))
    (check-equal "rt-seen-w" (string->number (list-ref m 7)) (hash-ref snap-owm 'seen-workers))
    (check-equal "rt-mrate" (string->number (list-ref m 8)) (hash-ref snap-owm 'est-min-rate))
    (check-equal "rt-grate" (string->number (list-ref m 9)) (hash-ref snap-owm 'est-gas-rate))
    (check-equal "rt-prod-exact-sorted-csv" (list-ref m 10) "barracks:2,factory:1,starport:1")
    (check-equal "rt-prod-parsed" (parse-kv-csv (list-ref m 10)) (hash-ref snap-owm 'prod))
    (check-equal "rt-upg-parsed" (parse-upg-csv (list-ref m 11)) (hash-ref snap-owm 'upgrades))
    (check-equal "rt-units-exact-sorted-csv"
                 (list-ref m 12)
                 (format "banshee:~a,marine:~a"
                         (hash-ref (hash-ref snap-owm 'units) 'banshee 0)
                         (hash-ref (hash-ref snap-owm 'units) 'marine 0)))
    (check-equal "rt-units-parsed" (parse-kv-csv (list-ref m 12)) (hash-ref snap-owm 'units))
    (check-equal "rt-unseen-m" (string->number (list-ref m 13)) (hash-ref snap-owm 'unseen-min))
    (check-equal "rt-unseen-g" (string->number (list-ref m 14)) (hash-ref snap-owm 'unseen-gas))
    (check-equal "rt-arm-val" (string->number (list-ref m 15)) (hash-ref snap-owm 'believed-army-val)))

  ;; Worker-kill sensitivity: killing 20 workers lowers instantaneous mineral income rate
  (define owm-harassed (make-opponent-world-model 'Terran))
  (step-opponent-world-model! owm-harassed obs-early)
  (step-opponent-world-model! owm-harassed (mk-obs 8064 'Terran '() ebldgs eunits #:workers-killed 20))
  (check-true "terran-worker-kills-reduce-est-min-rate"
              (< (owm-estimated-min-rate owm-harassed)
                 (owm-estimated-min-rate owm))
              (format "harassed=~a unharassed=~a"
                      (owm-estimated-min-rate owm-harassed)
                      (owm-estimated-min-rate owm))))

;; =============================================================================
;; Group 3: Protoss -- WarpGate -> Gateway Merge, Implied Robo, Shield Upgrades
;; =============================================================================
(printf "\n=== Group 3: Protoss WarpGate Merge & Implied Facilities ===\n")

(let* ([owm (make-opponent-world-model 'Protoss)]
       [ebldgs
        (list (hasheq 'id 301 'type 'nexus       'x 160.0 'y 160.0 'hp 1000 'build-progress 1.0)
              (hasheq 'id 302 'type 'nexus       'x 142.0 'y 150.0 'hp 1000 'build-progress 1.0)
              (hasheq 'id 303 'type 'gateway     'x 152.0 'y 156.0 'hp 500  'build-progress 1.0)
              (hasheq 'id 304 'type 'warp-gate   'x 148.0 'y 152.0 'hp 500  'build-progress 1.0)
              (hasheq 'id 305 'type 'warpgate    'x 144.0 'y 148.0 'hp 500  'build-progress 1.0)
              (hasheq 'id 306 'type 'assimilator 'x 165.0 'y 155.0 'hp 450  'build-progress 1.0))]
       [eunits
        (list (hasheq 'id 401 'type 'immortal 'x 136.0 'y 144.0 'hp 200 'max-hp 200 'shield-upgrade-level 1)
              (hasheq 'id 402 'type 'stalker  'x 135.0 'y 145.0 'hp 80  'max-hp 80)
              (hasheq 'id 403 'type 'stalker  'x 134.0 'y 145.0 'hp 80  'max-hp 80)
              (hasheq 'id 404 'type 'probe    'x 161.0 'y 161.0 'hp 20  'max-hp 20)
              (hasheq 'id 405 'type 'probe    'x 162.0 'y 162.0 'hp 20  'max-hp 20)
              ;; Hallucinated Phoenix must NOT imply Stargate or appear in units!
              (hasheq 'id 406 'type 'phoenix  'x 120.0 'y 120.0 'hp 120 'is-hallucination #t))]
       [_ (step-opponent-world-model! owm (mk-obs 6720 'Protoss '() ebldgs eunits))]
       [snap (owm-belief-telemetry-snapshot owm #f 6720)])
  (check-equal "protoss-prod-merges-warpgate-and-implies-robo"
               (hash-ref snap 'prod)
               (hasheq 'gateway 3 'robotics-facility 1))
  (check-equal "protoss-units-excludes-probes-and-hallucinations"
               (hash-ref snap 'units)
               (hasheq 'immortal 1 'stalker 2))
  (check-equal "protoss-seen-workers" (hash-ref snap 'seen-workers) 2)
  (check-true "protoss-upgrades-warpgate-and-shields"
              (and (member 'warp-gate-research (hash-ref snap 'upgrades))
                   (member 'protoss-shields-1 (hash-ref snap 'upgrades))
                   (not (member 'enemy-shields-1 (hash-ref snap 'upgrades)))
                   #t)
              (format "upgs=~s" (hash-ref snap 'upgrades))))

;; =============================================================================
;; Group 4: Zerg -- Hatchery/Lair/Hive Tiering, Overlord/Locust Exclusion
;; =============================================================================
(printf "\n=== Group 4: Zerg Hatch/Lair/Hive Tiering & Summon Exclusion ===\n")

(let* ([owm (make-opponent-world-model 'Zerg)]
       [ebldgs-lair
        (list (hasheq 'id 501 'type 'lair     'x 160.0 'y 160.0 'hp 2000 'build-progress 1.0)
              (hasheq 'id 502 'type 'hatchery 'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 503 'type 'hatchery 'x 125.0 'y 155.0 'hp 1500 'build-progress 1.0))]
       [eunits
        (list (hasheq 'id 601 'type 'zergling 'x 120.0 'y 140.0 'hp 35 'max-hp 35 'speed 4.7)
              (hasheq 'id 602 'type 'zergling 'x 121.0 'y 140.0 'hp 35 'max-hp 35 'speed 4.7)
              (hasheq 'id 603 'type 'mutalisk 'x 118.0 'y 138.0 'hp 120 'max-hp 120)
              (hasheq 'id 604 'type 'drone    'x 161.0 'y 161.0 'hp 40 'max-hp 40)
              (hasheq 'id 605 'type 'overlord 'x 158.0 'y 158.0 'hp 200 'max-hp 200)
              (hasheq 'id 606 'type 'locust   'x 115.0 'y 135.0 'hp 50 'max-hp 50))]
       [_ (step-opponent-world-model! owm (mk-obs 9408 'Zerg '() ebldgs-lair eunits))]
       [snap-lair (owm-belief-telemetry-snapshot owm #f 9408)]
       ;; Now main Lair morphs to Hive at (160,160) -> must replace Lair, never double-count!
       [ebldgs-hive
        (list (hasheq 'id 501 'type 'hive     'x 160.0 'y 160.0 'hp 2500 'build-progress 1.0)
              (hasheq 'id 502 'type 'hatchery 'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 503 'type 'hatchery 'x 125.0 'y 155.0 'hp 1500 'build-progress 1.0))]
       [_ (step-opponent-world-model! owm (mk-obs 11200 'Zerg '() ebldgs-hive eunits))]
       [snap-hive (owm-belief-telemetry-snapshot owm #f 11200)])
  ;; At 7:00 (`9408f`, Zerg 4-base happy path), `est-bases = 4` -> `hatchery + lair = 4` (3 + 1),
  ;; and morphing Lair -> Hive yields `hatchery + hive = est-bases` with ZERO phantom `lair`!
  (check-equal "zerg-prod-lair-plus-est-bases-hatch"
               (hash-ref snap-lair 'prod)
               (hasheq 'hatchery (sub1 (hash-ref snap-lair 'estimated-bases)) 'lair 1))
  (check-equal "zerg-prod-hive-replaces-lair-no-phantom-lair"
               (hash-ref snap-hive 'prod)
               (hasheq 'hatchery (sub1 (hash-ref snap-hive 'estimated-bases)) 'hive 1))
  (check-true "zerg-units-excludes-drone-overlord-locust-and-includes-queens"
              (let ([u (hash-ref snap-lair 'units)])
                (and (>= (hash-ref u 'zergling 0) 2)
                     (>= (hash-ref u 'mutalisk 0) 1)
                     (>= (hash-ref u 'queen 0) 3)
                     (not (hash-has-key? u 'drone))
                     (not (hash-has-key? u 'overlord))
                     (not (hash-has-key? u 'locust))))
              (format "got=~s" (hash-ref snap-lair 'units)))
  (check-equal "zerg-seen-workers" (hash-ref snap-lair 'seen-workers) 1)
  (check-true "zerg-upgrades-ling-speed"
              (and (member 'zergling-movementspeed (hash-ref snap-lair 'upgrades)) #t)))

;; =============================================================================
;; Group 5: Edge Cases, Unstepped OWM & Formatter Total Safety
;; =============================================================================
(printf "\n=== Group 5: Edge Cases & Formatter Total Safety ===\n")

(let* ([fresh-owm (make-opponent-world-model 'Zerg)]
       [snap-fresh (owm-belief-telemetry-snapshot fresh-owm)]
       [snap-false (owm-belief-telemetry-snapshot #f)]
       [line-fresh (format-owm-belief-log-line snap-fresh)]
       [line-false (format-owm-belief-log-line #f)]
       [line-dirty (format-owm-belief-log-line
                    (hasheq 'frame 448
                            'confirmed-bases 1 'estimated-bases 2
                            'confirmed-gases 0 'estimated-gases 1
                            'est-workers 22 'seen-workers 4
                            'est-min-rate 1020 'est-gas-rate 115
                            'prod (hasheq 'starport 1 'barracks 2 'zero-bldg 0)
                            'upgrades '(stimpack combat-shield stimpack unknown)
                            'units (hasheq 'marine 6 'banshee 1)
                            'unseen-min 300 'unseen-gas 75
                            'believed-army-val 950))])
  (check-true "fresh-owm-log-line-valid" (not (not (regexp-match OWM-LOG-RX line-fresh))) line-fresh)
  (check-true "false-snap-log-line-valid" (not (not (regexp-match OWM-LOG-RX line-false))) line-false)
  (check-equal "false-snap-frame-0" (hash-ref snap-false 'frame) 0)
  (check-equal "dirty-snap-sorted-deduped-exact"
               line-dirty
               "[SCBOT_OWM] f=448 b=1/2 g=0/1 w=22/4 inc=1020M/115G prod=(barracks:2,starport:1) upg=(combat-shield,stimpack) units=(banshee:1,marine:6) unseen=300M/75G arm=950"))

;; =============================================================================
;; Group 6: Loop 87B 7-Dimension General SC2 Calibrations
;; =============================================================================
(printf "\n=== Group 6: Loop 87B 7-Dimension General Calibrations ===\n")

;; 6.1 Worker Rebuild Recovery (old kills rebuild cleanly; fresh kills drop immediately)
(let* ([owm (make-opponent-world-model 'Terran)]
       [ccs-2b (list (hasheq 'id 701 'type 'orbital-command 'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)
                     (hasheq 'id 702 'type 'command-center  'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0))]
       [ccs-3b (append ccs-2b
                       (list (hasheq 'id 703 'type 'command-center 'x 125.0 'y 155.0 'hp 1500 'build-progress 1.0)))]
       [_ (step-opponent-world-model! owm (mk-obs 3360 'Terran '() ccs-2b '()))]
       [s-pre (step-opponent-world-model! owm (mk-obs 5300 'Terran '() ccs-2b '()))]
       ;; Kill 18 SCVs right at 4:00 (5376f)
       [s-hit (step-opponent-world-model! owm (mk-obs 5376 'Terran '() ccs-2b '() #:workers-killed 18))]
       ;; Advance 5 minutes with 3 CCs and no new kills -> opponent rebuilds workers!
       [_ (step-opponent-world-model! owm (mk-obs 8064 'Terran '() ccs-3b '() #:workers-killed 18))]
       [s-rec (step-opponent-world-model! owm (mk-obs 12096 'Terran '() ccs-3b '() #:workers-killed 18))]
       [snap-rec (owm-belief-telemetry-snapshot owm #f 12096)])
  (check-true "l87b-fresh-worker-kills-drop-immediately"
              (< (opponent-world-summary-estimated-workers s-hit)
                 (opponent-world-summary-estimated-workers s-pre))
              (format "pre=~a hit=~a"
                      (opponent-world-summary-estimated-workers s-pre)
                      (opponent-world-summary-estimated-workers s-hit)))
  (check-true "l87b-old-worker-kills-rebuild-over-time"
              (and (>= (hash-ref snap-rec 'est-workers) 45)
                   (>= (hash-ref snap-rec 'est-min-rate) 1700))
              (format "rec-w=~a rec-mrate=~a"
                      (hash-ref snap-rec 'est-workers)
                      (hash-ref snap-rec 'est-min-rate))))

;; 6.2 SC2 Faster Gas Harvest Rate + Early/Mid Gas Priors (respecting gas-free scout!)
(let* ([owm-unsc (make-opponent-world-model 'Terran)]
       [s-2m-unsc (step-opponent-world-model! owm-unsc (mk-obs 2688 'Terran '() '() '()))]
       [snap-2m-unsc (owm-belief-telemetry-snapshot owm-unsc #f 2688)]
       ;; Main swept gas-free at 2:00 (ally inside enemy main, 0 geysers seen) -> estG=0, grate=0
       [owm-gasfree (make-opponent-world-model 'Zerg)]
       [_ (step-opponent-world-model!
           owm-gasfree
           (mk-obs 2688 'Zerg
                   (list (hasheq 'id 1 'type 'probe 'x 159.0 'y 159.0))
                   (list (hasheq 'id 801 'type 'spawning-pool 'x 156.0 'y 156.0 'hp 1000 'build-progress 1.0))
                   '()))]
       [snap-gasfree (owm-belief-telemetry-snapshot owm-gasfree #f 2688)]
       ;; 8:00 (10752f) 3-base midgame -> g-per-base ~1.5 => est-g >= 4, gas-rate >= 400
       [owm-8m (make-opponent-world-model 'Protoss)]
       [nex-3b (list (hasheq 'id 810 'type 'nexus 'x 160.0 'y 160.0 'hp 1000 'build-progress 1.0)
                     (hasheq 'id 811 'type 'nexus 'x 142.0 'y 150.0 'hp 1000 'build-progress 1.0)
                     (hasheq 'id 812 'type 'nexus 'x 125.0 'y 155.0 'hp 1000 'build-progress 1.0))]
       [_ (step-opponent-world-model! owm-8m (mk-obs 4480 'Protoss '() (take nex-3b 2) '()))]
       [_ (step-opponent-world-model! owm-8m (mk-obs 10752 'Protoss '() nex-3b '()))]
       [snap-8m (owm-belief-telemetry-snapshot owm-8m #f 10752)])
  (check-true "l87b-2m-unscouted-early-gas-prior-and-pure-confirmed"
              (and (= (opponent-world-summary-confirmed-geysers s-2m-unsc) 0)
                   (>= (hash-ref snap-2m-unsc 'estimated-gases) 1)
                   (>= (hash-ref snap-2m-unsc 'est-gas-rate) 120))
              (format "confG=~a estG=~a grate=~a"
                      (opponent-world-summary-confirmed-geysers s-2m-unsc)
                      (hash-ref snap-2m-unsc 'estimated-gases)
                      (hash-ref snap-2m-unsc 'est-gas-rate)))
  (check-true "l87b-2m-swept-gas-free-main-stays-zero"
              (and (= (hash-ref snap-gasfree 'estimated-gases) 0)
                   (= (hash-ref snap-gasfree 'est-gas-rate) 0))
              (format "estG=~a grate=~a"
                      (hash-ref snap-gasfree 'estimated-gases)
                      (hash-ref snap-gasfree 'est-gas-rate)))
  (check-true "l87b-8m-3base-midgame-gas-scaling"
              (and (>= (hash-ref snap-8m 'estimated-gases) 4)
                   (>= (hash-ref snap-8m 'est-gas-rate) 400))
              (format "estG=~a grate=~a"
                      (hash-ref snap-8m 'estimated-gases)
                      (hash-ref snap-8m 'est-gas-rate))))

;; 6.3 Econ-Scaled Production Facilities (Terran 3b Bio/Tank & Protoss 3b Gateway)
(let* ([owm-t (make-opponent-world-model 'Terran)]
       [t-units
        (append (for/list ([i (in-range 10)])
                  (hasheq 'id (+ 900 i) 'type 'marine 'x 130.0 'y 130.0 'hp 45 'max-hp 45))
                (for/list ([i (in-range 4)])
                  (hasheq 'id (+ 920 i) 'type 'siege-tank 'x 132.0 'y 132.0 'hp 175 'max-hp 175)))]
       [_ (step-opponent-world-model!
           owm-t
           (mk-obs 9408 'Terran '()
                   (list (hasheq 'id 950 'type 'command-center 'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
                         (hasheq 'id 951 'type 'command-center 'x 125.0 'y 155.0 'hp 1500 'build-progress 1.0))
                   t-units))]
       [snap-t (owm-belief-telemetry-snapshot owm-t #f 9408)]
       [pt (hash-ref snap-t 'prod)]
       [owm-p (make-opponent-world-model 'Protoss)]
       [p-units (for/list ([i (in-range 8)])
                  (hasheq 'id (+ 960 i) 'type 'stalker 'x 130.0 'y 130.0 'hp 80 'max-hp 80))]
       [_ (step-opponent-world-model!
           owm-p
           (mk-obs 9408 'Protoss '()
                   (list (hasheq 'id 970 'type 'nexus 'x 142.0 'y 150.0 'hp 1000 'build-progress 1.0)
                         (hasheq 'id 971 'type 'nexus 'x 125.0 'y 155.0 'hp 1000 'build-progress 1.0))
                   p-units))]
       [snap-p (owm-belief-telemetry-snapshot owm-p #f 9408)]
       [pp (hash-ref snap-p 'prod)])
  (check-true "l87b-terran-3b-econ-scaled-prod"
              (and (>= (hash-ref pt 'barracks 0) 3)
                   (>= (hash-ref pt 'factory 0) 2)
                   (>= (hash-ref pt 'starport 0) 1))
              (format "prod=~s" pt))
  (check-true "l87b-protoss-3b-econ-scaled-gateway"
              (>= (hash-ref pp 'gateway 0) 4)
              (format "prod=~s" pp)))

;; 6.4 Upgrade Alias (`burrow-or-subterranean-tech -> burrow` Zerg only) + Direct & Evidence-Backed Inference
(let* ([owm-z (make-opponent-world-model 'Zerg)]
       [z-bldgs
        (list (hasheq 'id 1030 'type 'evolution-chamber 'x 158.0 'y 158.0 'hp 750 'build-progress 1.0)
              (hasheq 'id 1031 'type 'hydralisk-den     'x 156.0 'y 156.0 'hp 850 'build-progress 1.0)
              (hasheq 'id 1032 'type 'lair              'x 160.0 'y 160.0 'hp 2000 'build-progress 1.0))]
       [z-units
        (append (for/list ([i (in-range 5)])
                  (hasheq 'id (+ 1000 i) 'type 'roach 'x 120.0 'y 120.0 'hp 145 'max-hp 145
                          'speed 3.0 'attack-upgrade-level 1))
                (for/list ([i (in-range 4)])
                  (hasheq 'id (+ 1010 i) 'type 'hydralisk 'x 122.0 'y 122.0 'hp 90 'max-hp 90))
                (list (hasheq 'id 1019 'type 'zergling 'x 121.0 'y 121.0 'hp 35 'max-hp 35 'speed 4.7)
                      (hasheq 'id 1020 'type 'roach-burrowed 'x 124.0 'y 124.0 'hp 145 'max-hp 145)))]
       ;; First observe completed HydraDen at 6:00 (`8064f`) so >= 45s (`1008f`) elapses by 7:00 (`9408f`)
       [_ (step-opponent-world-model! owm-z (mk-obs 8064 'Zerg '() z-bldgs '()))]
       [_ (step-opponent-world-model! owm-z (mk-obs 9408 'Zerg '() z-bldgs z-units))]
       [snap-z (owm-belief-telemetry-snapshot
                owm-z (hasheq 'observed-upgrades '(burrow-or-subterranean-tech)) 9408)]
       [uz (hash-ref snap-z 'upgrades)]
       ;; Terran with Widow Mine (`burrow-or-subterranean-tech` from mmstate must NOT emit `burrow`!)
       ;; + Cloaked Banshee (`cloak=1`) + 3 Marauders + 10 Marines + EBay @ 7:00
       [owm-t (make-opponent-world-model 'Terran)]
       [t-units
        (append (for/list ([i (in-range 10)])
                  (hasheq 'id (+ 1100 i) 'type 'marine 'x 130.0 'y 130.0 'hp 45 'max-hp 45 'attack-upgrade-level 1))
                (for/list ([i (in-range 3)])
                  (hasheq 'id (+ 1120 i) 'type 'marauder 'x 131.0 'y 131.0 'hp 125 'max-hp 125))
                (list (hasheq 'id 1130 'type 'banshee 'x 125.0 'y 125.0 'hp 140 'max-hp 140 'cloak 1)
                      (hasheq 'id 1131 'type 'widow-mine-burrowed 'x 128.0 'y 128.0 'hp 90 'max-hp 90)))]
       [_ (step-opponent-world-model!
           owm-t
           (mk-obs 9408 'Terran '()
                   (list (hasheq 'id 1140 'type 'engineering-bay 'x 158.0 'y 158.0 'hp 850 'build-progress 1.0))
                   t-units))]
       [snap-t (owm-belief-telemetry-snapshot
                owm-t (hasheq 'observed-upgrades '(burrow-or-subterranean-tech)) 9408)]
       [ut (hash-ref snap-t 'upgrades)])
  (check-true "l87b-zerg-burrow-alias-and-timing-upgrades"
              (and (member 'burrow uz)
                   (not (member 'burrow-or-subterranean-tech uz))
                   (member 'zergling-movementspeed uz)
                   (member 'glial-reconstitution uz)
                   (member 'grooved-spines uz)
                   (member 'zerg-missile-weapons-1 uz)
                   (not (member 'enemy-weapons-1 uz))
                   #t)
              (format "uz=~s" uz))
  (check-true "l87b-terran-cloak-concussive-inf1-and-no-widowmine-burrow-fp"
              (and (not (member 'burrow ut))
                   (not (member 'burrow-or-subterranean-tech ut))
                   (member 'cloaking-field ut)
                   (member 'concussive-shells ut)
                   (member 'stimpack ut)
                   (member 'terran-infantry-weapons-1 ut)
                   ;; Generic `enemy-weapons-1` deduplicated once `terran-infantry-weapons-1` is present!
                   (not (member 'enemy-weapons-1 ut))
                   #t)
              (format "ut=~s" ut)))

;; 6.5 Unweighted `believed-army-val` & 6.6 Fog-Retained Core Unit Projection
(let* ([owm (make-opponent-world-model 'Terran)]
       [ccs (list (hasheq 'id 1201 'type 'orbital-command 'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)
                  (hasheq 'id 1202 'type 'command-center  'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
                  (hasheq 'id 1203 'type 'refinery        'x 165.0 'y 155.0 'hp 500  'build-progress 1.0)
                  (hasheq 'id 1204 'type 'refinery        'x 155.0 'y 165.0 'hp 500  'build-progress 1.0))]
       [army (append (for/list ([i (in-range 8)])
                       (hasheq 'id (+ 1210 i) 'type 'marine 'x 130.0 'y 130.0 'hp 45 'max-hp 45))
                     (for/list ([i (in-range 2)])
                       (hasheq 'id (+ 1220 i) 'type 'siege-tank 'x 132.0 'y 132.0 'hp 175 'max-hp 175)))]
       [_ (step-opponent-world-model! owm (mk-obs 3360 'Terran '() ccs '()))]
       [s-5m (step-opponent-world-model! owm (mk-obs 6720 'Terran '() ccs army))]
       [snap-5m (owm-belief-telemetry-snapshot owm #f 6720)]
       ;; Now lose vision of the army for 140s (3136f > 2464f `known-units` age-out!)
       [_ (step-opponent-world-model! owm (mk-obs 9856 'Terran '() ccs '()))]
       [snap-fog (owm-belief-telemetry-snapshot owm #f 9856)]
       [ufog (hash-ref snap-fog 'units)])
  (check-true "l87b-unweighted-army-val-le-weighted-tactical"
              (and (> (hash-ref snap-5m 'believed-army-val) 0)
                   (<= (hash-ref snap-5m 'believed-army-val)
                       (opponent-world-summary-believed-total-army-value s-5m)))
              (format "unweighted=~a weighted=~a"
                      (hash-ref snap-5m 'believed-army-val)
                      (opponent-world-summary-believed-total-army-value s-5m)))
  (check-true "l87b-fog-retained-unit-projection-no-collapse-to-empty-no-hallucination"
              (and (> (hash-ref ufog 'marine 0) 0)
                   (> (hash-ref ufog 'siege-tank 0) 0)
                   (= (hash-count ufog) 2)
                   (not (hash-has-key? ufog 'thor))
                   (not (hash-has-key? ufog 'battlecruiser)))
              (format "ufog=~s arm=~a" ufog (hash-ref snap-fog 'believed-army-val))))

;; =============================================================================
;; Group 7: Loop 87C Track 1 -- High-Precision Upgrade Inference & Zero-FP Guards
;; =============================================================================
(printf "\n=== Group 7: Loop 87C Track 1 Upgrade Precision & Zero-FP Guards ===\n")

;; 7.1 Zero-FP 0-Upgrade Zerg Opponent (3 bases, 30 slow Roaches, 20 slow Lings, fresh Hydras, Lair, 1 Evo)
;; Must emit ZERO false-positive timed Zerg upgrades!
(let* ([owm (make-opponent-world-model 'Zerg)]
       [z-bldgs
        (list (hasheq 'id 2001 'type 'lair              'x 160.0 'y 160.0 'hp 2000 'build-progress 1.0)
              (hasheq 'id 2002 'type 'hatchery          'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 2003 'type 'hatchery          'x 125.0 'y 155.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 2004 'type 'extractor         'x 165.0 'y 155.0 'hp 500  'build-progress 1.0)
              (hasheq 'id 2005 'type 'roach-warren      'x 155.0 'y 155.0 'hp 850  'build-progress 1.0)
              (hasheq 'id 2006 'type 'evolution-chamber 'x 153.0 'y 153.0 'hp 750  'build-progress 1.0))]
       ;; Step 1 at 10:00 (13440f) and Step 2 (+22f ~= 0.98s later) with slow on-creep speeds:
       ;; Slowling on creep <= 5.37 t/s (move 5.1t in 0.98s -> 5.20 t/s),
       ;; Slow Roach on creep <= 4.095 t/s (move 3.9t in 0.98s -> 3.97 t/s),
       ;; Fresh slow Hydra on creep <= 4.095 t/s (move 3.8t in 0.98s -> 3.87 t/s),
       ;; ALL explicitly attack-upgrade-level=0 & armor-upgrade-level=0!
       [mk-slow-z
        (lambda (dx-ling dx-roach dx-hydra)
          (append
           (for/list ([i (in-range 12)])
             (hasheq 'id (+ 2100 i) 'type 'zergling 'x (+ 110.0 dx-ling) 'y (+ 120.0 (* 0.5 i))
                     'hp 35 'max-hp 35 'attack-upgrade-level 0 'armor-upgrade-level 0))
           (for/list ([i (in-range 18)])
             (hasheq 'id (+ 2200 i) 'type 'roach 'x (+ 115.0 dx-roach) 'y (+ 120.0 (* 0.5 i))
                     'hp 145 'max-hp 145 'attack-upgrade-level 0 'armor-upgrade-level 0))
           (for/list ([i (in-range 8)])
             (hasheq 'id (+ 2300 i) 'type 'hydralisk 'x (+ 118.0 dx-hydra) 'y (+ 120.0 (* 0.5 i))
                     'hp 90 'max-hp 90 'attack-upgrade-level 0 'armor-upgrade-level 0))))]
       [_ (step-opponent-world-model! owm (mk-obs 13440 'Zerg '() z-bldgs (mk-slow-z 0.0 0.0 0.0)))]
       [_ (step-opponent-world-model! owm (mk-obs 13462 'Zerg '() z-bldgs (mk-slow-z 5.1 3.9 3.8)))]
       [_ (step-opponent-world-model! owm (mk-obs 13484 'Zerg '() z-bldgs (mk-slow-z 10.2 7.8 7.6)))]
       [snap (owm-belief-telemetry-snapshot owm #f 13484)]
       [upgs (hash-ref snap 'upgrades)])
  (check-equal "l87c-zero-upgrade-zerg-emits-zero-fp-upgrades" upgs '()))

;; 7.2 Kinematic Speed Observation (Speedling, Speed Roach, Tunneling Claws, Speed Hydra, Speed Overlord, Charge Zealot)
(let* ([owm-z (make-opponent-world-model 'Zerg)]
       [step-z!
        (lambda (f dx-ling dx-roach dx-burr dx-hydra dx-ovi)
          (step-opponent-world-model!
           owm-z
           (mk-obs f 'Zerg '() '()
                   (list (hasheq 'id 3001 'type 'zergling       'x (+ 100.0 dx-ling)  'y 100.0 'hp 35  'max-hp 35)
                         (hasheq 'id 3002 'type 'roach          'x (+ 100.0 dx-roach) 'y 105.0 'hp 145 'max-hp 145)
                         (hasheq 'id 3003 'type 'roach-burrowed 'x (+ 100.0 dx-burr)  'y 110.0 'hp 145 'max-hp 145 'is-burrowed #t)
                         (hasheq 'id 3004 'type 'hydralisk      'x (+ 100.0 dx-hydra) 'y 115.0 'hp 90  'max-hp 90)
                         (hasheq 'id 3005 'type 'overlord       'x (+ 100.0 dx-ovi)   'y 120.0 'hp 200 'max-hp 200)))))]
       ;; dt = 22f (~0.982s) per step:
       ;; Speedling off creep = 6.58 t/s -> dx=6.5 (6.62 t/s >= 5.85)
       ;; Speed Roach on creep = 5.46 t/s -> dx=5.2 (5.29 t/s >= 4.50)
       ;; Tunneling Claws burrowed Roach = 2.80 t/s -> dx=2.6 (2.65 t/s >= 0.8)
       ;; Speed Hydra on creep = 5.12 t/s -> dx=4.9 (4.99 t/s >= 4.45)
       ;; Speed Overlord = 2.63 t/s -> dx=2.5 (2.55 t/s >= 1.65)
       [_ (step-z! 9000 0.0  0.0  0.0 0.0 0.0)]
       [_ (step-z! 9022 6.5  5.2  2.6 4.9 2.5)]
       [_ (step-z! 9044 13.0 10.4 5.2 9.8 5.0)]
       [uz (hash-ref (owm-belief-telemetry-snapshot owm-z #f 9044) 'upgrades)]
       ;; Protoss Charge Zealot kinematic speed (>= 3.85 t/s) vs Slow Zealot (3.15 t/s)
       [owm-p-fast (make-opponent-world-model 'Protoss)]
       [_ (step-opponent-world-model! owm-p-fast (mk-obs 8000 'Protoss '() '() (list (hasheq 'id 3101 'type 'zealot 'x 100.0 'y 100.0 'hp 150 'max-hp 150))))]
       [_ (step-opponent-world-model! owm-p-fast (mk-obs 8022 'Protoss '() '() (list (hasheq 'id 3101 'type 'zealot 'x 104.6 'y 100.0 'hp 150 'max-hp 150))))]
       [_ (step-opponent-world-model! owm-p-fast (mk-obs 8044 'Protoss '() '() (list (hasheq 'id 3101 'type 'zealot 'x 109.2 'y 100.0 'hp 150 'max-hp 150))))]
       [up-fast (hash-ref (owm-belief-telemetry-snapshot owm-p-fast #f 8044) 'upgrades)]
       [owm-p-slow (make-opponent-world-model 'Protoss)]
       [_ (step-opponent-world-model! owm-p-slow (mk-obs 8000 'Protoss '() '() (list (hasheq 'id 3102 'type 'zealot 'x 100.0 'y 100.0 'hp 150 'max-hp 150))))]
       [_ (step-opponent-world-model! owm-p-slow (mk-obs 8022 'Protoss '() '() (list (hasheq 'id 3102 'type 'zealot 'x 103.0 'y 100.0 'hp 150 'max-hp 150))))]
       [_ (step-opponent-world-model! owm-p-slow (mk-obs 8044 'Protoss '() '() (list (hasheq 'id 3102 'type 'zealot 'x 106.0 'y 100.0 'hp 150 'max-hp 150))))]
       [up-slow (hash-ref (owm-belief-telemetry-snapshot owm-p-slow #f 8044) 'upgrades)])
  (check-true "l87c-kinematic-detects-all-5-zerg-speed-and-tunneling-upgrades"
              (and (member 'zergling-movementspeed uz)
                   (member 'glial-reconstitution uz)
                   (member 'tunneling-claws uz)
                   (member 'burrow uz)
                   (member 'muscular-augments uz)
                   (member 'pneumatized-carapace uz)
                   #t)
              (format "uz=~s" uz))
  (check-true "l87c-kinematic-charge-fires-on-fast-zealot-not-slow-zealot"
              (and (member 'charge up-fast)
                   (not (member 'charge up-slow))
                   #t)
              (format "fast=~s slow=~s" up-fast up-slow)))

;; 7.2b Live 4-frame step cadence kinematic accumulation (verifies 16f anchor window works at step_size=4)
(let* ([owm-4f (make-opponent-world-model 'Zerg)])
  (for ([k (in-range 0 10)]) ; f = 9000, 9004, ..., 9036 (9 steps of 4f = 36f -> 2 full 16f windows!)
    (define f (+ 9000 (* k 4)))
    (define dt-s (/ (exact->inexact (* k 4)) 22.4))
    (step-opponent-world-model!
     owm-4f
     (mk-obs f 'Zerg '() '()
             (list (hasheq 'id 3151 'type 'zergling       'x (+ 100.0 (* 6.58 dt-s)) 'y 100.0 'hp 35  'max-hp 35)
                   (hasheq 'id 3152 'type 'overlord       'x (+ 100.0 (* 2.63 dt-s)) 'y 105.0 'hp 200 'max-hp 200)
                   (hasheq 'id 3153 'type 'roach-burrowed 'x (+ 100.0 (* 2.80 dt-s)) 'y 110.0 'hp 145 'max-hp 145 'is-burrowed #t)))))
  (define u4f (hash-ref (owm-belief-telemetry-snapshot owm-4f #f 9036) 'upgrades))
  (check-true "l87c-4frame-cadence-kinematics-detect-speedling-overlord-tunneling"
              (and (member 'zergling-movementspeed u4f)
                   (member 'pneumatized-carapace u4f)
                   (member 'tunneling-claws u4f)
                   (member 'burrow u4f)
                   #t)
              (format "u4f=~s" u4f)))

;; 7.3 Direct Tier 1..2 Per-Unit Upgrade Mapping + Dedup & Terran Unupgraded Refutation
(let* ([owm-z (make-opponent-world-model 'Zerg)]
       [_ (step-opponent-world-model!
           owm-z
           (mk-obs 12000 'Zerg '() '()
                   (list (hasheq 'id 3201 'type 'roach 'x 110.0 'y 110.0 'hp 145 'max-hp 145
                                 'attack-upgrade-level 2 'armor-upgrade-level 1))))]
       [uz (hash-ref (owm-belief-telemetry-snapshot owm-z #f 12000) 'upgrades)]
       ;; Terran with 15 unupgraded 45-HP Marines (`atk=0`, `arm=0`), EBay, 3 CCs, TechLab @ 10:00:
       ;; Refutes combat-shield, terran-infantry-weapons-1, and terran-infantry-armor-1!
       ;; Meanwhile direct `buffs '(stimpack)` still detects stimpack immediately!
       [owm-t (make-opponent-world-model 'Terran)]
       [t-bldgs
        (list (hasheq 'id 3301 'type 'command-center  'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 3302 'type 'command-center  'x 142.0 'y 150.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 3303 'type 'command-center  'x 125.0 'y 155.0 'hp 1500 'build-progress 1.0)
              (hasheq 'id 3304 'type 'engineering-bay 'x 155.0 'y 155.0 'hp 850  'build-progress 1.0)
              (hasheq 'id 3305 'type 'barracks-techlab 'x 152.0 'y 152.0 'hp 400 'build-progress 1.0))]
       [t-units
        (for/list ([i (in-range 15)])
          (hasheq 'id (+ 3310 i) 'type 'marine 'x (+ 120.0 (* 0.5 i)) 'y 120.0
                  'hp 45 'max-hp 45 'attack-upgrade-level 0 'armor-upgrade-level 0
                  'buffs (if (= i 0) '(stimpack) '())))]
       [_ (step-opponent-world-model! owm-t (mk-obs 13440 'Terran '() t-bldgs t-units))]
       [ut (hash-ref (owm-belief-telemetry-snapshot owm-t #f 13440) 'upgrades)])
  (check-true "l87c-direct-zerg-tier2-missile-and-carapace-dedups-generics"
              (and (member 'zerg-missile-weapons-1 uz)
                   (member 'zerg-missile-weapons-2 uz)
                   (member 'zerg-ground-carapace-1 uz)
                   (not (member 'enemy-weapons-1 uz))
                   (not (member 'enemy-weapons-2 uz))
                   (not (member 'enemy-armor-1 uz))
                   #t)
              (format "uz=~s" uz))
  (check-true "l87c-terran-45hp-0-0-marines-refute-cs-and-1-1-while-buff-detects-stim"
              (and (member 'stimpack ut)
                   (not (member 'combat-shield ut))
                   (not (member 'terran-infantry-weapons-1 ut))
                   (not (member 'terran-infantry-armor-1 ut))
                   #t)
              (format "ut=~s" ut)))

;; 7.4 HydraDen Research-Duration Physics (`71s + 71s`) & Ling/Bane Synergy
(let* ([owm-h (make-opponent-world-model 'Zerg)]
       [h-bldgs (list (hasheq 'id 3401 'type 'hydralisk-den 'x 156.0 'y 156.0 'hp 850 'build-progress 1.0))]
       [h-units (for/list ([i (in-range 6)])
                  (hasheq 'id (+ 3410 i) 'type 'hydralisk 'x (+ 120.0 (* 0.5 i)) 'y 120.0
                          'hp 90 'max-hp 90 'attack-upgrade-level 0 'armor-upgrade-level 0))]
       [_ (step-opponent-world-model! owm-h (mk-obs 10000 'Zerg '() h-bldgs h-units))]
       [u-fresh (hash-ref (owm-belief-telemetry-snapshot owm-h #f 10000) 'upgrades)]
       ;; +54s later (11200f): enough for Grooved Spines (>= 45s), NOT Muscular Augments!
       [_ (step-opponent-world-model! owm-h (mk-obs 11200 'Zerg '() h-bldgs h-units))]
       [u-mid (hash-ref (owm-belief-telemetry-snapshot owm-h #f 11200) 'upgrades)]
       ;; +223s later at 15000f (~11:10): enough for BOTH Grooved Spines + Muscular Augments!
       [_ (step-opponent-world-model! owm-h (mk-obs 15000 'Zerg '() h-bldgs h-units))]
       [u-late (hash-ref (owm-belief-telemetry-snapshot owm-h #f 15000) 'upgrades)]
       ;; Confirmed Ling/Bane synergy past 4:30 (6048f) -> zergling-movementspeed
       [owm-lb (make-opponent-world-model 'Zerg)]
       [_ (step-opponent-world-model!
           owm-lb
           (mk-obs 6200 'Zerg '()
                   (list (hasheq 'id 3501 'type 'extractor     'x 165.0 'y 155.0 'hp 500 'build-progress 1.0)
                         (hasheq 'id 3502 'type 'baneling-nest 'x 155.0 'y 155.0 'hp 850 'build-progress 1.0))
                   (for/list ([i (in-range 8)])
                     (hasheq 'id (+ 3510 i) 'type 'zergling 'x (+ 120.0 (* 0.5 i)) 'y 120.0 'hp 35 'max-hp 35))))]
       [u-lb (hash-ref (owm-belief-telemetry-snapshot owm-lb #f 6200) 'upgrades)])
  (check-true "l87c-hydraden-fresh-no-premature-range-or-speed"
              (and (not (member 'grooved-spines u-fresh))
                   (not (member 'muscular-augments u-fresh)))
              (format "u-fresh=~s" u-fresh))
  (check-true "l87c-hydraden-mid-fires-grooved-only"
              (and (member 'grooved-spines u-mid)
                   (not (member 'muscular-augments u-mid))
                   #t)
              (format "u-mid=~s" u-mid))
  (check-true "l87c-hydraden-late-fires-both-grooved-and-muscular"
              (and (member 'grooved-spines u-late)
                   (member 'muscular-augments u-late)
                   #t)
              (format "u-late=~s" u-late))
  (check-true "l87c-confirmed-ling-bane-synergy-fires-ling-speed"
              (and (member 'zergling-movementspeed u-lb) #t)
              (format "u-lb=~s" u-lb)))

(printf "\n=== Results: ~a/~a passed (~a failed) ===\n"
        pass-count (+ pass-count fail-count) fail-count)
(unless (= fail-count 0)
  (exit 1))
