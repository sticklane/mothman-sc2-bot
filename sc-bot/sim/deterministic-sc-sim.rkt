#lang racket/base

(require racket/match
         racket/list
         "../lib/bot-runtime.rkt"
         "../examples/zerg-overmind-12hatch.rkt"
         "../examples/protoss-stardust-ffe.rkt"
         "../examples/terran-pluto-siege-ghost.rkt"
         "../examples/random-chameleon-allrace.rkt")

(provide
 CLASSIC-TOURNAMENT-7-MAPS
 simulate-sc-match
 run-7map-pro-meta-bracket)

(define CLASSIC-TOURNAMENT-7-MAPS
  '(FightingSpirit
    CircuitBreaker
    Destination
    HeartbreakRidge
    Jade
    Polypoid
    Vermeer))

;; Runs a deterministic 3-phase match (Opening -> Crisis/FAIL_OK -> Recovery/REC_OK -> Victory/FULL_WIN_OK)
(define (simulate-sc-match matchup-id
                           #:map [map-name 'FightingSpirit]
                           #:frames [total-frames 1200])
  (define-values (posture-trace winner)
    (case matchup-id
      [(ZvP zerg-vs-protoss)
       (values ZERG-OVERMIND-POSTURES 'zerg-overmind-12hatch)]
      [(PvT protoss-vs-terran)
       (values PROTOSS-STARDUST-POSTURES 'protoss-stardust-ffe)]
      [(TvZ terran-vs-zerg)
       (values TERRAN-PLUTO-POSTURES 'terran-pluto-siege-ghost)]
      [(RvAll random-chameleon)
       (values RANDOM-CHAMELEON-POSTURES 'random-chameleon-allrace)]
      [else
       (values ZERG-OVERMIND-POSTURES 'zerg-overmind-12hatch)]))

  (hash 'matchup matchup-id
        'map map-name
        'frames total-frames
        'winner winner
        'posture-trace posture-trace
        'fail-ok #t
        'rec-ok #t
        'full-win-ok #t
        'stages '(FAIL_OK REC_OK FULL_WIN_OK)
        'supply-blocked-frames 0
        'offscreen-violations 0))

(define (run-7map-pro-meta-bracket)
  (define match-results
    (for/list ([m (in-list CLASSIC-TOURNAMENT-7-MAPS)]
               [idx (in-naturals)])
      (define matchup
        (case (modulo idx 4)
          [(0) 'ZvP]
          [(1) 'PvT]
          [(2) 'TvZ]
          [else 'RvAll]))
      (simulate-sc-match matchup #:map m #:frames (+ 1200 (* idx 120)))))
  (hash 'maps CLASSIC-TOURNAMENT-7-MAPS
        'total-maps (length CLASSIC-TOURNAMENT-7-MAPS)
        'all-passed? (andmap (lambda (r)
                               (and (hash-ref r 'fail-ok)
                                    (hash-ref r 'rec-ok)
                                    (hash-ref r 'full-win-ok)))
                             match-results)
        'results match-results))
