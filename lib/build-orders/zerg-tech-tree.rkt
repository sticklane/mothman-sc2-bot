#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zerg-tech-tree.rkt`
;; Zerg opponent build-order & tech progression tree for Bayesian scouting.
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZERG-BUILD-ORDER-TREE)

(: ZERG-BUILD-ORDER-TREE (Listof build-order-tree-node))
(define ZERG-BUILD-ORDER-TREE
  (list
   (build-order-tree-node
    'zerg-root-hatchery 'Zerg #f
    '(zerg-spawning-pool zerg-hatch-first-pool)
    '(hatchery) '(hatchery)
    '(drone overlord zergling) '()
    'early-rush 0 0 300 0 0 0.08)
   (build-order-tree-node
    'zerg-spawning-pool 'Zerg 'zerg-root-hatchery
    '(zerg-hatch-first-pool zerg-baneling-nest zerg-roach-warren)
    '(hatchery spawning-pool) '(spawning-pool)
    '(zergling queen) '(zergling-movementspeed)
    'early-rush 400 0 200 0 720 0.16)
   (build-order-tree-node
    'zerg-hatch-first-pool 'Zerg 'zerg-spawning-pool
    '(zerg-baneling-nest zerg-roach-warren zerg-lair-tech)
    '(hatchery spawning-pool extractor) '(hatchery extractor)
    '(zergling queen) '(zergling-movementspeed burrow)
    'ling-bane-hydra 750 1 325 0 960 0.18)
   (build-order-tree-node
    'zerg-baneling-nest 'Zerg 'zerg-spawning-pool
    '(zerg-lair-tech)
    '(hatchery spawning-pool extractor baneling-nest) '(baneling-nest)
    '(baneling zergling queen) '(zergling-movementspeed centrifical-hooks)
    'ling-bane-hydra 1350 1 100 50 672 0.14)
   (build-order-tree-node
    'zerg-roach-warren 'Zerg 'zerg-spawning-pool
    '(zerg-lair-tech)
    '(hatchery spawning-pool extractor roach-warren) '(roach-warren)
    '(roach ravager zergling queen) '(glial-reconstitution burrow)
    'roach-ravager 1400 1 150 0 605 0.20)
   (build-order-tree-node
    'zerg-lair-tech 'Zerg 'zerg-roach-warren
    '(zerg-hydralisk-den zerg-spire-muta zerg-infestation-pit)
    '(hatchery spawning-pool extractor roach-warren lair) '(lair)
    '(overseer roach ravager zergling queen) '(glial-reconstitution pneumatized-carapace)
    'roach-ravager 2400 2 150 100 896 0.16)
   (build-order-tree-node
    'zerg-hydralisk-den 'Zerg 'zerg-lair-tech
    '(zerg-lurker-den zerg-hive-tech)
    '(hatchery spawning-pool extractor lair hydralisk-den) '(hydralisk-den)
    '(hydralisk roach ravager zergling) '(grooved-spines muscular-augments)
    'ling-bane-hydra 3200 2 100 100 650 0.16)
   (build-order-tree-node
    'zerg-spire-muta 'Zerg 'zerg-lair-tech
    '(zerg-hive-tech zerg-greater-spire-broodlord)
    '(hatchery spawning-pool extractor lair spire) '(spire)
    '(mutalisk corruptor zergling baneling) '(zerg-flyer-weapons-1 zerg-flyer-armor-1)
    'muta-flock 3300 2 200 200 960 0.12)
   (build-order-tree-node
    'zerg-lurker-den 'Zerg 'zerg-hydralisk-den
    '(zerg-hive-tech)
    '(hatchery spawning-pool extractor lair hydralisk-den lurker-den) '(lurker-den)
    '(lurker hydralisk roach ravager) '(adaptive-talons seismic-spines)
    'ling-bane-hydra 4200 3 100 150 896 0.10)
   (build-order-tree-node
    'zerg-infestation-pit 'Zerg 'zerg-lair-tech
    '(zerg-hive-tech)
    '(hatchery spawning-pool extractor lair infestation-pit) '(infestation-pit)
    '(infestor swarm-host roach hydralisk) '(pathogen-glands neural-parasite)
    'ling-bane-hydra 4100 3 100 100 806 0.07)
   (build-order-tree-node
    'zerg-hive-tech 'Zerg 'zerg-infestation-pit
    '(zerg-ultralisk-cavern zerg-greater-spire-broodlord)
    '(hatchery spawning-pool extractor lair infestation-pit hive) '(hive)
    '(viper hydralisk lurker infestor) '(adrenal-glands zerg-melee-weapons-3)
    'ling-bane-hydra 5400 4 200 150 960 0.06)
   (build-order-tree-node
    'zerg-ultralisk-cavern 'Zerg 'zerg-hive-tech
    '()
    '(hatchery spawning-pool extractor lair infestation-pit hive ultralisk-cavern) '(ultralisk-cavern)
    '(ultralisk zergling baneling corruptor viper) '(chitinous-plating anabolic-synthesis)
    'ling-bane-hydra 6200 4 150 200 896 0.05)
   (build-order-tree-node
    'zerg-greater-spire-broodlord 'Zerg 'zerg-hive-tech
    '()
    '(hatchery spawning-pool extractor lair infestation-pit hive spire greater-spire) '(greater-spire)
    '(brood-lord corruptor mutalisk viper) '(zerg-flyer-weapons-3)
    'muta-flock 6400 4 100 150 960 0.05)))
