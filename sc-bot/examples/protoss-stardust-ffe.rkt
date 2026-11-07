#lang racket/base

(require "../compiler/syntax.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/zerospace-mastermind.rkt"
         "../lib/bot-runtime.rkt")

(provide protoss-stardust-ffe-bot
         PROTOSS-STARDUST-POSTURES
         PROTOSS-STARDUST-STATE-MACHINE
         make-protoss-stardust-runtime)

(define PROTOSS-STARDUST-POSTURES
  '(ForgeFastExpand
    CrisisZerglingFlood
    CannonWallRecovery
    DragoonReaverVanguard
    ProtossArmadaVictory))

(defstate-machine PROTOSS-STARDUST-STATE-MACHINE ForgeFastExpand
  (ForgeFastExpand       -> CrisisZerglingFlood CannonWallRecovery)
  (CrisisZerglingFlood   -> CannonWallRecovery)
  (CannonWallRecovery    -> DragoonReaverVanguard)
  (DragoonReaverVanguard -> ProtossArmadaVictory)
  (ProtossArmadaVictory  -> ProtossArmadaVictory))

(def-posture ForgeFastExpand
  #:when 'opening
  #:build (seq>> (bo-step '(train probe) 50 0 1)
                 (bo-step '(build pylon) 100 0 0)
                 (bo-step '(build forge) 150 0 0)
                 (bo-step '(build photon-cannon) 150 0 0)
                 (bo-step '(expand 50 56) 400 0 0))
  #:tactics '(ffe-choke-wall hold-position-zealot-door-guard)
  #:transitions '(CrisisZerglingFlood CannonWallRecovery))

(def-bot protoss-stardust-ffe-bot
  #:race 'Protoss
  #:personality MARV-MACRO-OPEN-PERSONALITY
  #:postures PROTOSS-STARDUST-POSTURES
  #:counter-table PROTOSS-COUNTER-TREE
  #:macro-goals '((stalker . 8) (immortal . 2) (warp-prism . 1) (zealot . 8))
  #:grade (sc-grade 'One 500 250 14 16 'saccade 'diffusion-prior)
  ForgeFastExpand)

(define (make-protoss-stardust-runtime)
  (make-live-bot-runtime #:bot-name 'protoss-stardust-ffe
                         #:race 'Protoss
                         #:personality MARV-MACRO-OPEN-PERSONALITY
                         #:cortex-profile 'herO
                         #:postures PROTOSS-STARDUST-POSTURES
                         #:state-machine PROTOSS-STARDUST-STATE-MACHINE))
