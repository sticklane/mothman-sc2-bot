#lang racket/base

(require "../compiler/syntax.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/sc2-combat-eval.rkt"
         "../lib/bot-runtime.rkt")

(provide zerg-overmind-12hatch-bot
         ZERG-OVERMIND-POSTURES
         ZERG-OVERMIND-STATE-MACHINE
         make-zerg-overmind-runtime)

;; #:race 'Zerg
;; (def-posture Macro12Hatch)

(define ZERG-OVERMIND-POSTURES
  '(Macro12Hatch
    CrisisZealotRush
    SunkenLairRecovery
    MutaLurkerContain
    SwarmVictory))

(defstate-machine ZERG-OVERMIND-STATE-MACHINE Macro12Hatch
  (Macro12Hatch       -> CrisisZealotRush SunkenLairRecovery)
  (CrisisZealotRush   -> SunkenLairRecovery)
  (SunkenLairRecovery -> MutaLurkerContain)
  (MutaLurkerContain  -> SwarmVictory)
  (SwarmVictory       -> SwarmVictory))

(def-posture Macro12Hatch
  #:when 'opening
  #:build (seq>> (bo-step '(train drone) 50 0 1)
                 (bo-step '(train overlord) 100 0 0)
                 (bo-step '(expand 50 56) 300 0 0)
                 (bo-step '(build spawning-pool) 150 0 0))
  #:tactics '(scout-overlord spread-creep)
  #:transitions '(CrisisZealotRush SunkenLairRecovery))

(def-bot zerg-overmind-12hatch-bot
  #:race 'Zerg
  #:personality SCARLETT-CREEP-SWARM-PERSONALITY
  #:postures ZERG-OVERMIND-POSTURES
  #:counter-table ZERG-COUNTER-TREE
  #:macro-goals '((mutalisk . 6) (lurker . 4) (zergling . 16))
  #:grade (sc-grade 'One 450 200 12 18 'saccade 'diffusion-prior)
  Macro12Hatch)

(define (make-zerg-overmind-runtime)
  (make-live-bot-runtime #:bot-name 'zerg-overmind-12hatch
                         #:race 'Zerg
                         #:personality SCARLETT-CREEP-SWARM-PERSONALITY
                         #:cortex-profile 'Serral
                         #:postures ZERG-OVERMIND-POSTURES
                         #:state-machine ZERG-OVERMIND-STATE-MACHINE))
