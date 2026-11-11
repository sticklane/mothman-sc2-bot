#lang racket/base

(require racket/cmdline
         racket/match
         racket/path
         racket/string
         "../lib/bot-runtime.rkt")

;; Persistent stdin/stdout S-expression IPC subprocess invoked by `SC2BurnySexpBridge`
;; Reads one `(frame-state ...)` S-expression per line and outputs one `((op ...) ...)` line.

(define bot-file (make-parameter "bots/Mothman.rkt"))
(define race-arg (make-parameter "zerg"))
(define posture-arg (make-parameter "Macro12Hatch"))

(command-line
 #:program "racket_sc2_ipc_bot"
 #:once-each
 [("--bot") b "Path to #lang sc-bot .rkt file" (bot-file b)]
 [("--race") r "Bot race" (race-arg r)]
 [("--posture") p "Initial posture" (posture-arg p)]
 #:args _rest
 (void))

(define runtime
  (make-live-bot-runtime
   #:bot-name (string->symbol (path->string (file-name-from-path (string->path (bot-file)))))
   #:race (string->symbol (race-arg))
   #:initial-posture (string->symbol (posture-arg))))

(define ipc-enemy-pos-cache (make-hasheqv))

(let loop ()
  (define line (read-line (current-input-port) 'any))
  (unless (eof-object? line)
    (define trimmed (string-trim line))
    (cond
      [(or (string=? trimmed "") (string=? trimmed "(quit)"))
       (void)]
      [else
       (with-handlers ([exn:fail? (lambda (_e)
                                    (printf "()\n")
                                    (flush-output))])
         (define sexp (read (open-input-string trimmed)))
         (if (equal? sexp '(quit))
             (void)
             (let* ([obs (parse-frame-state-sexp sexp)]
                    [raw-cmds (runtime-step-sexp! runtime obs)]
                    [cmds (sanitize-stale-target-actions raw-cmds obs #:pos-cache ipc-enemy-pos-cache)])
               (printf "~s\n" cmds)
               (flush-output)
               (loop))))])))
