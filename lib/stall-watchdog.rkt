#lang racket/base

;; =============================================================================
;; Generalized 4-Law Stall Watchdog (`lib/stall-watchdog.rkt`)
;;
;; Pure, race-general, opponent-agnostic anti-stall invariants (< 0.05ms/call):
;;   Law 1 (Bounded Goal Progress & Escrow Unstick):
;;     `wd-update-goal-progress!` + `wd-goal-on-cooldown?`
;;     Tracks any affordable macro goal whose count fails to advance:
;;       >=  32f (~1.4s): 'stage1-check-builder
;;       >=  64f (~2.9s): 'stage2-expand-ring
;;       >= 112f (~5.0s): 'stage3-release-escrow (sets 160f cooldown on goal-sym)
;;   Law 2 (Economy / Worker / Gas Equilibrium):
;;     `wd-gas-valve-mode`, `wd-zero-income-recovery?`, `wd-worker-plateau-floor?`
;;     - Dynamic gas-valve: pull excess gas workers at gas>=450 & min<200 & sup<175;
;;       force-saturate empty geysers at sec>=300 & workers>=16 & vesp<=0.
;;     - Zero-income recovery: workers>=5 & min-rate<=0 for >=48f (not worker rush).
;;     - Worker plateau floor: workers<target flat >=160f with TH/larva & not worker rush.
;;   Law 3 (Preemptive Supply Headroom & Idle-Bank Flush):
;;     `wd-preemptive-supply-urgent?`, `wd-idle-bank-flush?`
;;     - Dynamic supply headroom scaling with supply & active production count.
;;     - Continuous idle-bank flush (>=96f floating >=500M, or >=150M early rush,
;;       not supply-capped, with idle production/larva).
;;   Law 4 (Halted Terran Construction Recovery):
;;     `wd-update-halted-buildings!`
;;     - Detects any incomplete Terran structure (`build_progress < 1.0`) whose
;;       progress is unchanged for >=24f and returns its unit tags for P0 SCV resume.
;;
;; Zero global mutable state: all temporal state lives in caller-owned `wd-st`
;; created by `(make-stall-watchdog-state)`.
;; =============================================================================

(provide
 make-stall-watchdog-state
 reset-stall-watchdog-state!
 wd-update-goal-progress!
 wd-goal-on-cooldown?
 wd-gas-valve-mode
 wd-zero-income-recovery?
 wd-dynamic-supply-headroom
 wd-preemptive-supply-urgent?
 wd-idle-bank-flush?
 wd-worker-plateau-floor?
 wd-update-halted-buildings!)

;; Constants (22.4 game loops / sec at Faster speed)
(define STAGE1-FRAMES 32)
(define STAGE2-FRAMES 64)
(define STAGE3-FRAMES 112)
;; L50-W1 (`#1200`/`#1201` Fix 1A): Expansions require a 6-12s worker walk from main
;; minerals to the natural/3rd pad before construction starts — give expansion goals
;; full 280f (~12.5s) walk grace before stage3-release-escrow cooldown!
(define EXPAND-STAGE1-FRAMES 96)
(define EXPAND-STAGE2-FRAMES 192)
(define EXPAND-STAGE3-FRAMES 280)
(define EXPANSION-SYMS '(command-center nexus hatchery))
(define GOAL-COOLDOWN-FRAMES 160)
(define ZERO-INCOME-FRAMES 48)
(define IDLE-BANK-FRAMES 96)
(define WORKER-PLATEAU-FRAMES 160)
(define HALTED-BLDG-FRAMES 24)
(define STALE-GAP-FRAMES 96)

(define (make-stall-watchdog-state)
  (make-hasheq))

(define (reset-stall-watchdog-state! wd-st)
  (when (hash? wd-st)
    (hash-clear! wd-st))
  wd-st)

(define (ensure-subhash! wd-st key)
  (define cur (hash-ref wd-st key #f))
  (if (hash? cur)
      cur
      (let ([h (make-hasheq)])
        (hash-set! wd-st key h)
        h)))

;; -----------------------------------------------------------------------------
;; Law 1: Bounded Goal Progress & Escrow Cooldown
;; -----------------------------------------------------------------------------

(define (wd-goal-on-cooldown? wd-st goal-sym frame)
  (and (hash? wd-st)
       goal-sym
       (let ([cds (hash-ref wd-st 'goal-cooldowns #f)])
         (and (hash? cds)
              (let ([exp-f (hash-ref cds goal-sym #f)])
                (cond
                  [(not (number? exp-f)) #f]
                  ;; Guard against backward frame reset across new games / tests
                  [(or (>= frame exp-f)
                       (> (- exp-f frame) GOAL-COOLDOWN-FRAMES))
                   (hash-remove! cds goal-sym)
                   #f]
                  [else #t]))))))

(define (wd-update-goal-progress! wd-st goal-sym affordable? current-cnt frame)
  (cond
    [(or (not (hash? wd-st)) (not goal-sym))
     'ok]
    [(wd-goal-on-cooldown? wd-st goal-sym frame)
     'stage3-release-escrow]
    [(not affordable?)
     (define prog (hash-ref wd-st 'goal-progress #f))
     (when (hash? prog)
       (hash-remove! prog goal-sym))
     'ok]
    [else
     (define prog (ensure-subhash! wd-st 'goal-progress))
     (define cds  (ensure-subhash! wd-st 'goal-cooldowns))
     (define cur-cnt (if (number? current-cnt) current-cnt 0))
     (define prev (hash-ref prog goal-sym #f))
     (cond
       [(or (not (pair? prev))
            (< frame (caddr prev))
            (> cur-cnt (cadr prev))
            (> (- frame (caddr prev)) STALE-GAP-FRAMES))
        (hash-set! prog goal-sym (list frame cur-cnt frame))
        'ok]
       [else
        (define start-f (car prev))
        (define start-cnt (min cur-cnt (cadr prev)))
        (define elapsed (- frame start-f))
        (define exp-goal? (memq goal-sym EXPANSION-SYMS))
        (define s1-frames (if exp-goal? EXPAND-STAGE1-FRAMES STAGE1-FRAMES))
        (define s2-frames (if exp-goal? EXPAND-STAGE2-FRAMES STAGE2-FRAMES))
        (define s3-frames (if exp-goal? EXPAND-STAGE3-FRAMES STAGE3-FRAMES))
        (cond
          [(>= elapsed s3-frames)
           (hash-set! cds goal-sym (+ frame GOAL-COOLDOWN-FRAMES))
           (hash-remove! prog goal-sym)
           'stage3-release-escrow]
          [(>= elapsed s2-frames)
           (hash-set! prog goal-sym (list start-f start-cnt frame))
           'stage2-expand-ring]
          [(>= elapsed s1-frames)
           (hash-set! prog goal-sym (list start-f start-cnt frame))
           'stage1-check-builder]
          [else
           (hash-set! prog goal-sym (list start-f start-cnt frame))
           'ok])])]))

;; -----------------------------------------------------------------------------
;; Law 2: Gas Valve, Zero-Income Recovery & Worker Plateau Floor
;; -----------------------------------------------------------------------------

(define (wd-gas-valve-mode minerals gas vesp-rate workers ready-gas-bldgs food-used sec)
  (cond
    [(or (and (>= gas 380)
              (< minerals 200)
              (< food-used 175))
         (and (>= gas 600)
              (< minerals 150)))
     'pull-to-minerals]
    [(and (>= sec 300)
          (>= workers 16)
          (<= vesp-rate 0)
          (> ready-gas-bldgs 0))
     'force-saturate-gas]
    [else 'normal]))

(define (wd-zero-income-recovery? wd-st workers min-rate frame under-worker-rush?)
  (cond
    [(not (hash? wd-st)) #f]
    [(or (< workers 5)
         (> min-rate 0)
         under-worker-rush?)
     (hash-remove! wd-st 'zero-income-start)
     #f]
    [else
     (define prev (hash-ref wd-st 'zero-income-start #f))
     (cond
       [(or (not (pair? prev))
            (< frame (cdr prev))
            (> (- frame (cdr prev)) STALE-GAP-FRAMES))
        (hash-set! wd-st 'zero-income-start (cons frame frame))
        #f]
       [else
        (define start-f (car prev))
        (hash-set! wd-st 'zero-income-start (cons start-f frame))
        (>= (- frame start-f) ZERO-INCOME-FRAMES)])]))

(define (wd-worker-plateau-floor? wd-st workers target-workers th-or-larva-avail? early-worker-rush? frame)
  (cond
    [(not (hash? wd-st)) #f]
    [(or (>= workers target-workers)
         (not th-or-larva-avail?)
         early-worker-rush?)
     (hash-remove! wd-st 'worker-plateau)
     #f]
    [else
     (define prev (hash-ref wd-st 'worker-plateau #f))
     (cond
       [(or (not (pair? prev))
            (< frame (caddr prev))
            (> workers (cadr prev))
            (> (- frame (caddr prev)) WORKER-PLATEAU-FRAMES))
        (hash-set! wd-st 'worker-plateau (list frame workers frame))
        #f]
       [else
        (define start-f (car prev))
        (define min-w (min workers (cadr prev)))
        (hash-set! wd-st 'worker-plateau (list start-f min-w frame))
        (>= (- frame start-f) WORKER-PLATEAU-FRAMES)])]))

;; -----------------------------------------------------------------------------
;; Law 3: Preemptive Supply Headroom & Idle-Bank Flush
;; -----------------------------------------------------------------------------

(define (wd-dynamic-supply-headroom food-used active-prod-count race [food-made #f])
  (define prod (max 0 (if (number? active-prod-count) active-prod-count 0)))
  (define p-scaled
    (if (eq? race 'Protoss)
        (inexact->exact (ceiling (* 1.5 prod)))
        prod))
  (cond
    [(and (number? food-made) (<= food-made 14)) 1]
    [(and (number? food-made) (= food-made 15)) (if (eq? race 'Terran) 2 1)]
    ;; L50-W1 (`#1200`/`#1201` Fix 1B) + L50-W2 (`#1212`/`#1213` W2-1 `#05 PvZ` 20/23 Pylon #2) +
    ;; L51-1B (`#1235`/`#1240` `H2H #05 PvZ` `22/23` block): At `19..23` on `food-made == 23`
    ;; with Gateway ready (`prod >= 1`), trigger headroom `4` so Pylon #2 starts at `19/23`
    ;; before a +2 Zealot + +1 Probe hits `22/23`; keep `24..37` at `3` and Terran unchanged!
    [(and (eq? race 'Protoss)
          (number? food-made)
          (= food-made 23)
          (>= prod 1)
          (>= food-used 19))
     4]
    [(< food-used 19) (if (eq? race 'Terran) 2 1)]
    [(< food-used 28) (if (eq? race 'Protoss) 3 2)]
    [(< food-used 38) 3]
    ;; L49-W1B (`#1156`/`#1157` Zerg 3+ base Overlord headroom): 3+ injected Hatcheries
    ;; dump 9-16 Larvae in one wave (12-24 supply!), so scale headroom to +12..16 supply!
    [(and (eq? race 'Zerg) (>= prod 3) (>= food-used 44))
     (cond
       [(< food-used 75)  (min 14 (max 12 (+ 6 (* 2 prod))))]
       [(< food-used 115) (min 16 (max 14 (+ 6 (* 2 prod))))]
       [else 16])]
    [(< prod 3) 4]
    [(< food-used 75) (min 11 (max 6 (+ 3 p-scaled)))]
    [(< food-used 125) (min 14 (max 8 (+ 4 p-scaled)))]
    [else (min 16 (max 10 (+ 5 p-scaled)))]))

(define (wd-preemptive-supply-urgent? food-used food-made pending-supply active-prod-count race)
  (and (< food-made 195)
       (= pending-supply 0)
       (<= (- food-made food-used)
           (wd-dynamic-supply-headroom food-used active-prod-count race food-made))))

(define (wd-idle-bank-flush? wd-st minerals supply-capped? idle-prod-or-larva? early-rush? frame)
  (define min-thresh (if early-rush? 150 500))
  (cond
    [(not (hash? wd-st)) #f]
    [(or (< minerals min-thresh)
         supply-capped?
         (not idle-prod-or-larva?))
     (hash-remove! wd-st 'idle-bank-start)
     #f]
    [else
     (define prev (hash-ref wd-st 'idle-bank-start #f))
     (cond
       [(or (not (pair? prev))
            (< frame (cdr prev))
            (> (- frame (cdr prev)) STALE-GAP-FRAMES))
        (hash-set! wd-st 'idle-bank-start (cons frame frame))
        #f]
       [else
        (define start-f (car prev))
        (hash-set! wd-st 'idle-bank-start (cons start-f frame))
        (>= (- frame start-f) IDLE-BANK-FRAMES)])]))

;; -----------------------------------------------------------------------------
;; Law 4: Halted Terran Construction Detection
;; Accepts list of `(tag . progress)`, `(list tag progress)`, or unit hashes
;; containing `'id`/`'tag` and `'build-progress`/`'build_progress`.
;; -----------------------------------------------------------------------------

(define (extract-bldg-tag-and-progress entry)
  (cond
    [(hash? entry)
     (define tag (or (hash-ref entry 'id #f) (hash-ref entry 'tag #f)))
     (define prog (or (hash-ref entry 'build-progress #f)
                      (hash-ref entry 'build_progress #f)
                      1.0))
     (values tag prog)]
    [(and (pair? entry) (pair? (cdr entry)))
     (values (car entry) (cadr entry))]
    [(pair? entry)
     (values (car entry) (cdr entry))]
    [else (values #f 1.0)]))

(define (wd-update-halted-buildings! wd-st incomplete-terran-bldgs frame)
  (cond
    [(not (hash? wd-st)) '()]
    [else
     (define trk (ensure-subhash! wd-st 'halted-bldgs))
     (define seen (make-hasheq))
     (define halted '())
     (for ([entry (in-list (if (list? incomplete-terran-bldgs) incomplete-terran-bldgs '()))])
       (define-values (tag prog) (extract-bldg-tag-and-progress entry))
       (when (and tag (number? prog) (< prog 1.0))
         (hash-set! seen tag #t)
         (define prev (hash-ref trk tag #f))
         (cond
           [(or (not (pair? prev))
                (< frame (caddr prev))
                (> (- prog (cadr prev)) 1e-6)
                (> (- frame (caddr prev)) STALE-GAP-FRAMES))
            (hash-set! trk tag (list frame prog frame))]
           [else
            (define start-f (car prev))
            (define last-prog (cadr prev))
            (hash-set! trk tag (list start-f last-prog frame))
            (when (>= (- frame start-f) HALTED-BLDG-FRAMES)
              (set! halted (cons tag halted)))])))
     ;; Prune completed or destroyed buildings
     (for ([old-tag (in-list (hash-keys trk))])
       (unless (hash-has-key? seen old-tag)
         (hash-remove! trk old-tag)))
     (reverse halted)]))
