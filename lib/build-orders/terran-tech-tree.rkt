#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/terran-tech-tree.rkt`
;; Terran opponent build-order & tech progression tree for Bayesian scouting.
;; =============================================================================

(require "../sc2-types.rkt")

(provide TERRAN-BUILD-ORDER-TREE)

(: TERRAN-BUILD-ORDER-TREE (Listof build-order-tree-node))
(define TERRAN-BUILD-ORDER-TREE
  (list
   (build-order-tree-node
    'terran-root-cc 'Terran #f
    '(terran-barracks-open)
    '(command-center supply-depot) '(command-center supply-depot)
    '(scv marine) '()
    'early-rush 0 0 500 0 0 0.08)
   (build-order-tree-node
    'terran-barracks-open 'Terran 'terran-root-cc
    '(terran-reaper-expand terran-bio-techlab-stim terran-factory-tech)
    '(command-center supply-depot barracks refinery) '(barracks refinery)
    '(marine reaper) '()
    'bio-ball 480 1 225 0 720 0.18)
   (build-order-tree-node
    'terran-reaper-expand 'Terran 'terran-barracks-open
    '(terran-bio-techlab-stim terran-factory-tech)
    '(command-center orbital-command supply-depot barracks barracks-reactor refinery) '(orbital-command barracks-reactor)
    '(marine reaper) '()
    'bio-ball 1050 1 200 50 672 0.18)
   (build-order-tree-node
    'terran-bio-techlab-stim 'Terran 'terran-barracks-open
    '(terran-factory-tech terran-starport-medivac-bio)
    '(command-center orbital-command supply-depot barracks barracks-techlab refinery engineering-bay) '(barracks-techlab engineering-bay)
    '(marauder marine) '(stimpack combat-shield concussive-shells)
    'bio-ball 1500 1 175 25 650 0.22)
   (build-order-tree-node
    'terran-factory-tech 'Terran 'terran-barracks-open
    '(terran-factory-siege-tank terran-starport-medivac-bio terran-starport-cloak-banshee)
    '(command-center orbital-command supply-depot barracks factory refinery) '(factory)
    '(hellion widow-mine marine) '(drilling-claws infernal-pre-igniter)
    'mech-siege 1800 1 150 100 720 0.16)
   (build-order-tree-node
    'terran-factory-siege-tank 'Terran 'terran-factory-tech
    '(terran-armory-heavy-mech terran-starport-medivac-bio terran-starport-viking-liberator)
    '(command-center orbital-command supply-depot barracks factory factory-techlab refinery) '(factory-techlab)
    '(siege-tank cyclone hellion marine marauder) '(siege-mode)
    'mech-siege 2350 2 50 25 403 0.18)
   (build-order-tree-node
    'terran-starport-medivac-bio 'Terran 'terran-factory-tech
    '(terran-starport-viking-liberator terran-ghost-academy-late)
    '(command-center orbital-command supply-depot barracks barracks-techlab factory starport refinery) '(starport)
    '(medivac marauder marine siege-tank widow-mine) '(stimpack combat-shield)
    'bio-ball 2650 2 150 100 672 0.18)
   (build-order-tree-node
    'terran-starport-cloak-banshee 'Terran 'terran-factory-tech
    '(terran-fusion-battlecruiser terran-starport-viking-liberator)
    '(command-center orbital-command supply-depot barracks factory starport starport-techlab refinery) '(starport starport-techlab)
    '(banshee raven viking hellion) '(cloaking-field)
    'sky-toss 2750 2 200 125 784 0.10)
   (build-order-tree-node
    'terran-starport-viking-liberator 'Terran 'terran-starport-medivac-bio
    '(terran-fusion-battlecruiser terran-armory-heavy-mech)
    '(command-center orbital-command supply-depot barracks factory starport refinery) '(starport)
    '(viking liberator medivac siege-tank marauder) '(advanced-ballistics)
    'sky-toss 3400 2 150 100 672 0.10)
   (build-order-tree-node
    'terran-armory-heavy-mech 'Terran 'terran-factory-siege-tank
    '(terran-fusion-battlecruiser)
    '(command-center orbital-command supply-depot barracks factory factory-techlab armory refinery) '(armory)
    '(thor siege-tank hellbat cyclone) '(terran-vehicle-weapons-1 terran-vehicle-and-ship-plating-1)
    'mech-siege 3600 3 150 100 806 0.10)
   (build-order-tree-node
    'terran-ghost-academy-late 'Terran 'terran-starport-medivac-bio
    '()
    '(command-center orbital-command supply-depot barracks barracks-techlab factory starport ghost-academy refinery) '(ghost-academy)
    '(ghost marauder marine medivac liberator) '(personal-cloaking)
    'bio-ball 4400 3 150 50 650 0.06)
   (build-order-tree-node
    'terran-fusion-battlecruiser 'Terran 'terran-starport-cloak-banshee
    '()
    '(command-center orbital-command supply-depot barracks factory starport starport-techlab fusion-core refinery) '(fusion-core)
    '(battlecruiser viking liberator siege-tank) '(weapon-refit)
    'sky-toss 4600 3 150 150 896 0.06)))
