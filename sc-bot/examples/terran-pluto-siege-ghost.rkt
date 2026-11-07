#lang racket/base

(require "../compiler/syntax.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/zerospace-mastermind.rkt"
         "../lib/bot-runtime.rkt")

(provide terran-pluto-siege-ghost-bot
         TERRAN-PLUTO-POSTURES
         TERRAN-PLUTO-STATE-MACHINE
         make-terran-pluto-runtime)

(define TERRAN-PLUTO-POSTURES
  '(OneRaxFE
    CrisisEarlyBust
    BunkerSiegeRecovery
    VesselGhostPush
    TerranDominionVictory))

(defstate-machine TERRAN-PLUTO-STATE-MACHINE OneRaxFE
  (OneRaxFE              -> CrisisEarlyBust BunkerSiegeRecovery)
  (CrisisEarlyBust       -> BunkerSiegeRecovery)
  (BunkerSiegeRecovery   -> VesselGhostPush)
  (VesselGhostPush       -> TerranDominionVictory)
  (TerranDominionVictory -> TerranDominionVictory))

(def-posture OneRaxFE
  #:when 'opening
  #:build (seq>> (bo-step '(train scv) 50 0 1)
                 (bo-step '(build supply-depot) 100 0 0)
                 (bo-step '(build barracks) 150 0 0)
                 (bo-step '(expand 50 56) 400 0 0))
  #:tactics '(barracks-depot-wall siege-tank-leapfrog ghost-emp-snipe)
  #:transitions '(CrisisEarlyBust BunkerSiegeRecovery))

(def-bot terran-pluto-siege-ghost-bot
  #:race 'Terran
  #:personality CLEM-TEMPO-MULTITASK-PERSONALITY
  #:postures TERRAN-PLUTO-POSTURES
  #:counter-table TERRAN-COUNTER-TREE
  #:macro-goals '((siege-tank . 5) (medivac . 2) (ghost . 3) (marine . 12))
  #:grade (sc-grade 'One 500 300 16 20 'saccade 'diffusion-prior)
  OneRaxFE)

(define (make-terran-pluto-runtime)
  (make-live-bot-runtime #:bot-name 'terran-pluto-siege-ghost
                         #:race 'Terran
                         #:personality CLEM-TEMPO-MULTITASK-PERSONALITY
                         #:cortex-profile 'Clem
                         #:postures TERRAN-PLUTO-POSTURES
                         #:state-machine TERRAN-PLUTO-STATE-MACHINE))
