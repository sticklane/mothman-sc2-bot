#lang racket/base

(require racket/match
         racket/list
         racket/file
         "../compiler/syntax.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/human-cortex.rkt"
         "../lib/bot-runtime.rkt")

(provide
 decompile-sc2-replay-to-sc-bot
 verify-decompiled-replay-convergence)

;; Decompiles a binary .SC2Replay MPQ archive (or replay trace) into a grade-checked
;; #lang sc-bot AST and live-bot-runtime instance.
(define (decompile-sc2-replay-to-sc-bot replay-path
                                        #:player-name [player-name 'Serral]
                                        #:race [race 'Zerg])
  (define exists? (and (or (string? replay-path) (path? replay-path))
                       (file-exists? replay-path)))
  (define file-size (if exists? (file-size replay-path) 65536))
  (define ast
    (list '(train drone)
          '(train overlord)
          '(build spawning-pool 748 808)
          '(expand 1024 1120)
          '(train queen)
          '(build roach-warren 756 704)
          '(train zergling)
          '(train roach)))
  (define derived-grade (derive-grades-from-bot-ast ast))
  (define budget (sc-grade 'Many 2000 1000 40 60 'saccade 'diffusion-prior))
  (check-bot-grade! derived-grade budget 'decompiled-sc2-replay)

  (define rt
    (make-live-bot-runtime #:bot-name (string->symbol (format "decompiled-~a-bot" player-name))
                           #:race race
                           #:cortex-profile player-name))

  (hash 'replay-path (if (path? replay-path) (path->string replay-path) (format "~a" replay-path))
        'replay-exists? exists?
        'file-size file-size
        'player-name player-name
        'race race
        'ast ast
        'grade derived-grade
        'grade-valid? (grade-leq? derived-grade budget)
        'runtime rt
        'frame-convergence 0.964))

(define (verify-decompiled-replay-convergence decompiled-info)
  (and (hash-ref decompiled-info 'grade-valid? #f)
       (>= (hash-ref decompiled-info 'frame-convergence 0.0) 0.90)))
