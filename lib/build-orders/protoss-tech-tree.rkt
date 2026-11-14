#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/protoss-tech-tree.rkt`
;; Protoss opponent build-order & tech progression tree for Bayesian scouting.
;; =============================================================================

(require "../sc2-types.rkt")

(provide PROTOSS-BUILD-ORDER-TREE)

(: PROTOSS-BUILD-ORDER-TREE (Listof build-order-tree-node))
(define PROTOSS-BUILD-ORDER-TREE
  (list
   (build-order-tree-node
    'protoss-root-nexus 'Protoss #f
    '(protoss-gateway-open)
    '(nexus pylon) '(nexus pylon)
    '(probe zealot) '()
    'early-rush 0 0 500 0 0 0.08)
   (build-order-tree-node
    'protoss-gateway-open 'Protoss 'protoss-root-nexus
    '(protoss-cybernetics-core)
    '(nexus pylon gateway assimilator) '(gateway assimilator)
    '(zealot) '()
    'early-rush 480 1 225 0 720 0.15)
   (build-order-tree-node
    'protoss-cybernetics-core 'Protoss 'protoss-gateway-open
    '(protoss-twilight-council protoss-robotics-facility protoss-stargate-air)
    '(nexus pylon gateway cybernetics-core assimilator) '(cybernetics-core)
    '(stalker adept sentry zealot) '(warp-gate-research)
    'stalker-colossus 1050 1 150 0 672 0.22)
   (build-order-tree-node
    'protoss-twilight-council 'Protoss 'protoss-cybernetics-core
    '(protoss-templar-archive-archon protoss-dark-shrine-dt protoss-robotics-facility)
    '(nexus pylon gateway cybernetics-core twilight-council assimilator) '(twilight-council)
    '(stalker adept zealot sentry) '(blink charge resonating-glaives)
    'stalker-colossus 2000 2 150 100 672 0.16)
   (build-order-tree-node
    'protoss-robotics-facility 'Protoss 'protoss-cybernetics-core
    '(protoss-robotics-bay-colossus protoss-twilight-council)
    '(nexus pylon gateway cybernetics-core robotics-facility assimilator) '(robotics-facility)
    '(immortal observer warp-prism stalker zealot) '(gravitic-boosters)
    'stalker-colossus 2000 2 150 100 720 0.18)
   (build-order-tree-node
    'protoss-stargate-air 'Protoss 'protoss-cybernetics-core
    '(protoss-fleet-beacon-carrier protoss-robotics-facility)
    '(nexus pylon gateway cybernetics-core stargate assimilator) '(stargate)
    '(void-ray oracle phoenix stalker adept) '(protoss-air-weapons-1)
    'sky-toss 2000 2 150 150 750 0.14)
   (build-order-tree-node
    'protoss-templar-archive-archon 'Protoss 'protoss-twilight-council
    '(protoss-robotics-bay-colossus)
    '(nexus pylon gateway cybernetics-core twilight-council templar-archive assimilator) '(templar-archive)
    '(archon high-templar zealot stalker immortal) '(psi-storm-tech charge)
    'stalker-colossus 3200 3 150 200 672 0.12)
   (build-order-tree-node
    'protoss-dark-shrine-dt 'Protoss 'protoss-twilight-council
    '(protoss-templar-archive-archon)
    '(nexus pylon gateway cybernetics-core twilight-council dark-shrine assimilator) '(dark-shrine)
    '(dark-templar archon stalker zealot) '(shadow-stride)
    'stalker-colossus 3100 2 150 150 896 0.07)
   (build-order-tree-node
    'protoss-robotics-bay-colossus 'Protoss 'protoss-robotics-facility
    '(protoss-templar-archive-archon)
    '(nexus pylon gateway cybernetics-core robotics-facility robotics-bay assimilator) '(robotics-bay)
    '(colossus disruptor immortal stalker sentry) '(extended-thermal-lance)
    'stalker-colossus 3300 3 150 150 784 0.14)
   (build-order-tree-node
    'protoss-fleet-beacon-carrier 'Protoss 'protoss-stargate-air
    '()
    '(nexus pylon gateway cybernetics-core stargate fleet-beacon assimilator) '(fleet-beacon)
    '(carrier tempest void-ray oracle mothership) '(anion-pulse-crystals)
    'sky-toss 4300 3 300 200 840 0.08)))
