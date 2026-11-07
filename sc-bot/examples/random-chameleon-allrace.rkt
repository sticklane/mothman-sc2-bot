#lang racket/base

(require "../compiler/syntax.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/zerospace-mastermind.rkt"
         "../lib/bot-runtime.rkt")

(provide random-chameleon-allrace-bot
         RANDOM-CHAMELEON-POSTURES
         RANDOM-CHAMELEON-STATE-MACHINE
         make-random-chameleon-runtime)

(define RANDOM-CHAMELEON-POSTURES
  '(RandomRollOpening
    EarlyScoutCrisis
    AdaptiveCounterRecovery
    TriRaceMidgamePush
    ChameleonSupremeVictory))

(defstate-machine RANDOM-CHAMELEON-STATE-MACHINE RandomRollOpening
  (RandomRollOpening       -> EarlyScoutCrisis AdaptiveCounterRecovery)
  (EarlyScoutCrisis        -> AdaptiveCounterRecovery)
  (AdaptiveCounterRecovery -> TriRaceMidgamePush)
  (TriRaceMidgamePush      -> ChameleonSupremeVictory)
  (ChameleonSupremeVictory -> ChameleonSupremeVictory))

(def-posture RandomRollOpening
  #:when 'frame-0-race-roll
  #:build (seq>> (bo-step '(train drone) 50 0 1)
                 (bo-step '(train overlord) 100 0 0)
                 (bo-step '(expand 50 56) 300 0 0))
  #:tactics '(frame-0-race-morph adaptive-counter-pull)
  #:transitions '(EarlyScoutCrisis AdaptiveCounterRecovery))

(def-bot random-chameleon-allrace-bot
  #:race 'Random
  #:personality CLEM-TEMPO-MULTITASK-PERSONALITY
  #:postures RANDOM-CHAMELEON-POSTURES
  #:counter-table ZERG-COUNTER-TREE
  #:macro-goals '((roach . 6) (stalker . 6) (siege-tank . 4))
  #:grade (sc-grade 'One 500 300 16 20 'saccade 'diffusion-prior)
  RandomRollOpening)

(define (make-random-chameleon-runtime)
  (make-live-bot-runtime #:bot-name 'random-chameleon-allrace
                         #:race 'Random
                         #:personality CLEM-TEMPO-MULTITASK-PERSONALITY
                         #:cortex-profile 'Serral
                         #:postures RANDOM-CHAMELEON-POSTURES
                         #:state-machine RANDOM-CHAMELEON-STATE-MACHINE))
