#lang racket/base

;; =============================================================================
;; `tests/worker-saturation-policy-test.rkt`
;; Standalone Unit & Performance Test Suite for:
;;   1. `lib/plan/worker-saturation-policy.rkt` (Pure L2a, L0-only, zero SC2 wire)
;;   2. `lib/priority-macro-brain.rkt` Section 2.3 Arbiter Override Consumers
;;      (`#:arbiter-gas-override-count` & `#:arbiter-facility-override-count`)
;; =============================================================================

(require racket/list
         racket/math
         (only-in "../lib/econ-ledger.rkt"
                  priority-schedule-result-category-utilities)
         "../lib/plan/worker-saturation-policy.rkt"
         "../lib/priority-macro-brain.rkt")

(define passed 0)
(define failed 0)

(define (check! cond-val msg)
  (if cond-val
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "[FAIL] ~a\n" msg))))

;; Helper constructors for clean readable fixtures
(define (mk-w tag x y
              #:type [ut 'probe]
              #:ab [ab 0]
              #:tgt [tgt 0]
              #:min? [min? #f]
              #:gas? [gas? #f]
              #:excl? [excl? #f]
              #:lease? [lease? #f])
  (sat-worker-info tag ut x y ab tgt min? gas? excl? lease?))

(define (mk-b tag x y
              #:type [ut 'nexus]
              #:ready? [ready? #t]
              #:flying? [flying? #f]
              #:asgn [asgn 12]
              #:ideal [ideal 16]
              #:threat [threat #f]
              #:patches [patches '()])
  (sat-base-info tag ut x y ready? flying? asgn ideal threat patches))

(define (mk-g tag x y
              #:type [ut 'assimilator]
              #:ready? [ready? #t]
              #:vesp [vesp 2000]
              #:asgn [asgn 0]
              #:ideal [ideal 3]
              #:base [nb #f]
              #:threat [threat #f])
  (sat-gas-info tag ut x y ready? vesp asgn ideal nb threat))

(define (mk-m tag x y
              #:mins [mins 1500]
              #:owner [owner #f]
              #:safe? [safe? #t])
  (sat-mineral-info tag x y mins owner safe?))

(define (rally-dirs ds) (filter (lambda (d) (eq? (sat-directive-kind d) 'rally-workers)) ds))
(define (gather-dirs ds) (filter (lambda (d) (eq? (sat-directive-kind d) 'harvest-gather)) ds))

(define (cand-u dec sym)
  (hash-ref (hash-ref (priority-schedule-result-category-utilities
                       (macro-brain-decision-priority-schedule dec))
                      'candidate-utilities (hasheq))
            sym 0.0))

;; =============================================================================
;; 1. State Isolation, Legacy Latch Box Alias & Frame-Rewind Full Reset
;; =============================================================================
(let ()
  (define st1 (make-worker-sat-state))
  (define st2 (make-worker-sat-state))
  (define b1 (mk-b 1 30.0 30.0 #:asgn 12 #:ideal 16 #:patches '(501 502)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 24.0 32.0 #:owner 1))
  (define g1 (mk-g 10 30.0 24.0 #:asgn 3 #:ideal 3 #:base 1))
  (define ws
    (append (for/list ([i (in-range 12)]) (mk-w (+ 100 i) 26.0 (+ 28.0 (* 0.3 i)) #:ab 298 #:tgt 501))
            (for/list ([i (in-range 3)]) (mk-w (+ 200 i) 30.0 25.0 #:ab 298 #:tgt 10))))

  ;; Trigger high-gas pull latch on st1 ONLY; st2's latch box MUST stay #f!
  (evaluate-worker-saturation-policy!
   st1 #:loop 2000 #:race 'Protoss #:minerals 100 #:gas 400
   #:workers ws #:bases (list b1) #:gas-buildings (list g1) #:minerals-fields (list m1 m2))
  (check! (and (unbox (worker-sat-gas-pull-latch-box st1))
               (not (unbox (worker-sat-gas-pull-latch-box st2))))
          "L66-WS(1): Two independent worker-sat-state instances isolate latch & trackers cleanly")

  ;; Frame rewind (`cur-loop < prev-loop`) resets latch, rally table, and cooldowns completely!
  (evaluate-worker-saturation-policy!
   st1 #:loop 100 #:race 'Protoss #:minerals 200 #:gas 50
   #:workers ws #:bases (list b1) #:gas-buildings (list g1) #:minerals-fields (list m1 m2))
  (check! (and (not (unbox (worker-sat-gas-pull-latch-box st1)))
               (= (unbox (worker-sat-state-last-loop st1)) 100)
               (= (hash-count (worker-sat-state-evac-last-loop st1)) 0))
          "L66-WS(2): Frame rewind auto-resets worker-sat-state cleanly"))

;; =============================================================================
;; 2. Sec 0: 3-Race RALLY_WORKERS (`'rally-workers`), Dedup, Mined-Out & CC Land
;; =============================================================================
(let ()
  (define st (make-worker-sat-state))
  (define m1 (mk-m 501 25.0 30.0 #:mins 1500 #:owner 1))
  (define m2 (mk-m 502 24.0 32.0 #:mins 1200 #:owner 1))
  (define m1-empty (mk-m 501 25.0 30.0 #:mins 0 #:owner 1))
  (define b1 (mk-b 1 30.0 30.0 #:type 'command-center #:asgn 12 #:ideal 16 #:patches '(501 502)))
  (define d1 (rally-dirs (evaluate-worker-saturation-policy!
                          st #:loop 200 #:race 'Terran #:minerals 200 #:gas 0
                          #:workers '() #:bases (list b1) #:gas-buildings '() #:minerals-fields (list m1 m2))))
  ;; Zero re-emit while current rallied patch is still live!
  (define d2 (rally-dirs (evaluate-worker-saturation-policy!
                          st #:loop 300 #:race 'Terran #:minerals 200 #:gas 0
                          #:workers '() #:bases (list b1) #:gas-buildings '() #:minerals-fields (list m1 m2))))
  ;; Mined-out patch triggers urgent re-rally onto surviving patch m2!
  (define d3 (rally-dirs (evaluate-worker-saturation-policy!
                          st #:loop 400 #:race 'Terran #:minerals 200 #:gas 0
                          #:workers '() #:bases (list b1) #:gas-buildings '() #:minerals-fields (list m1-empty m2))))
  ;; Flying CC resets state, landing triggers immediate re-rally!
  (define b1-fly (mk-b 1 45.0 30.0 #:type 'command-center-flying #:flying? #t #:asgn 0 #:ideal 0))
  (define b1-land (mk-b 1 60.0 30.0 #:type 'command-center #:asgn 0 #:ideal 16 #:patches '(503)))
  (define m3 (mk-m 503 65.0 30.0 #:mins 1500 #:owner 1))
  (void (evaluate-worker-saturation-policy!
         st #:loop 500 #:race 'Terran #:minerals 200 #:gas 0
         #:workers '() #:bases (list b1-fly) #:gas-buildings '() #:minerals-fields (list m2 m3)))
  (define d4 (rally-dirs (evaluate-worker-saturation-policy!
                          st #:loop 532 #:race 'Terran #:minerals 200 #:gas 0
                          #:workers '() #:bases (list b1-land) #:gas-buildings '() #:minerals-fields (list m2 m3))))
  (check! (and (= (length d1) 1)
               (equal? (sat-directive-unit-tags (first d1)) '(1))
               (= (sat-directive-target-tag (first d1)) 501)
               (null? d2)
               (= (length d3) 1)
               (= (sat-directive-target-tag (first d3)) 502)
               (sat-directive-urgent? (first d3))
               (= (length d4) 1)
               (= (sat-directive-target-tag (first d4)) 503)
               (sat-directive-urgent? (first d4)))
          (format "L66-WS(3): Sec 0 RALLY_WORKERS initial/dedup/mined-out/CC-land (d1=~a d2=~a d3=~a d4=~a)"
                  d1 d2 d3 d4)))

;; =============================================================================
;; 3. Sec 0b Offline Base Evacuation (`urgent? = #t`) & Sec 1 Idle / Exclusion / Lease
;; =============================================================================
(let ()
  (define st (make-worker-sat-state))
  (define b-off (mk-b 1 30.0 30.0 #:asgn 8 #:ideal 16 #:threat #t #:patches '(501)))
  (define b-on  (mk-b 2 62.0 30.0 #:asgn 2 #:ideal 16 #:threat #f #:patches '(502 503)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 67.0 30.0 #:owner 2))
  (define m3 (mk-m 503 68.0 32.0 #:owner 2))
  (define evac-ws
    (for/list ([i (in-range 5)])
      (mk-w (+ 300 i) (+ 26.0 (* 0.3 i)) 30.0 #:ab 298 #:tgt 501)))
  (define idle-ok (mk-w 310 60.0 30.0 #:ab 0 #:tgt 0))
  (define idle-excl (mk-w 311 60.5 30.0 #:ab 0 #:tgt 0 #:excl? #t))
  (define idle-lease (mk-w 312 61.0 30.0 #:ab 0 #:tgt 0 #:lease? #t))
  (define ds
    (evaluate-worker-saturation-policy!
     st #:loop 8000 #:race 'Protoss #:minerals 200 #:gas 50
     #:workers (append evac-ws (list idle-ok idle-excl idle-lease))
     #:bases (list b-off b-on) #:gas-buildings '() #:minerals-fields (list m1 m2 m3)))
  (define gds (gather-dirs ds))
  (define all-cmd-tags (apply append (map sat-directive-unit-tags gds)))
  (define evac-d (findf (lambda (d) (eq? (sat-directive-reason d) 'offline-base-evac)) gds))
  (define idle-d (findf (lambda (d) (eq? (sat-directive-reason d) 'idle-worker-recovery)) gds))
  (check! (and evac-d
               (sat-directive-urgent? evac-d)
               (= (length (sat-directive-unit-tags evac-d)) 5)
               (memv (sat-directive-target-tag evac-d) '(502 503))
               idle-d
               (sat-directive-urgent? idle-d)
               (equal? (sat-directive-unit-tags idle-d) '(310))
               (not (memv 311 all-cmd-tags))
               (not (memv 312 all-cmd-tags)))
          (format "L66-WS(4): Sec 0b urgent coalesced evac + Sec 1 idle rescue skips excluded/leased (gds=~a)" gds)))

;; =============================================================================
;; 4. Sec 0a/2/4: Gas Fill, Float Hysteresis, Worker-Crisis Evac & Zero-Gas Rescue
;; =============================================================================
(let ()
  ;; (4a) Worker-crisis gas evac (`<= 12w`, `>= 150G`, `< 120M`) pulls gas workers to 0!
  (define st-c (make-worker-sat-state))
  (define b1 (mk-b 1 30.0 30.0 #:asgn 8 #:ideal 16 #:patches '(501 502)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 25.0 32.0 #:owner 1))
  (define g1 (mk-g 10 30.0 24.0 #:asgn 2 #:ideal 3 #:base 1))
  (define ws-crisis
    (append (for/list ([i (in-range 8)]) (mk-w (+ 400 i) 26.0 30.0 #:ab 298 #:tgt 501))
            (list (mk-w 420 30.0 25.0 #:ab 298 #:tgt 10)
                  (mk-w 421 30.2 25.0 #:ab 298 #:tgt 10))))
  (define dc (gather-dirs (evaluate-worker-saturation-policy!
                           st-c #:loop 5000 #:race 'Zerg #:minerals 80 #:gas 180
                           #:workers ws-crisis #:bases (list b1) #:gas-buildings (list g1)
                           #:minerals-fields (list m1 m2))))
  (check! (and (= (length dc) 1)
               (equal? (sat-directive-unit-tags (first dc)) '(420 421))
               (memv (sat-directive-target-tag (first dc)) '(501 502)))
          (format "L66-WS(5): Worker-crisis gas evac (<=12w, >=150G, <120M) pulls gas workers to minerals (dc=~a)" dc))

  ;; (4b) Zero-gas-freeze rescue (`300f` streak at `< 150G` with `>= 12w`) assigns 3 workers & rotates after `224f`!
  (define st-z (make-worker-sat-state))
  (define b-z-off (mk-b 1 30.0 30.0 #:asgn 14 #:ideal 16 #:threat #t #:patches '(501)))
  (define g-z1 (mk-g 11 30.0 24.0 #:asgn 0 #:ideal 3 #:base 1 #:threat 100.0))
  (define g-z2 (mk-g 12 36.0 24.0 #:asgn 0 #:ideal 3 #:base 1 #:threat 200.0))
  (define ws-14 (for/list ([i (in-range 14)]) (mk-w (+ 450 i) 26.0 (+ 28.0 (* 0.2 i)) #:ab 298 #:tgt 501)))
  ;; Start streak at loop 10000 (not yet 300f -> no rescue)
  (define dz0 (gather-dirs (evaluate-worker-saturation-policy!
                            st-z #:loop 10000 #:race 'Protoss #:minerals 200 #:gas 40
                            #:workers ws-14 #:bases (list b-z-off) #:gas-buildings (list g-z1 g-z2)
                            #:minerals-fields (list m1))))
  ;; At loop 10300 (`+300f` without gas gain) -> rescue latches & assigns 3 workers to lowest-threat geyser 11!
  (define dz1 (gather-dirs (evaluate-worker-saturation-policy!
                            st-z #:loop 10300 #:race 'Protoss #:minerals 200 #:gas 40
                            #:workers ws-14 #:bases (list b-z-off) #:gas-buildings (list g-z1 g-z2)
                            #:minerals-fields (list m1))))
  (define dz1-to-11 (filter (lambda (d) (= (sat-directive-target-tag d) 11)) dz1))
  ;; At loop 10524 (`+224f` still 0 gas gain) -> rotation idx advances to 1 (geyser 12 primary)!
  (void (evaluate-worker-saturation-policy!
         st-z #:loop 10524 #:race 'Protoss #:minerals 200 #:gas 40
         #:workers ws-14 #:bases (list b-z-off) #:gas-buildings (list g-z1 g-z2)
         #:minerals-fields (list m1)))
  (check! (and (not (ormap (lambda (d) (eq? (sat-directive-reason d) 'gas-zero-freeze-rescue)) dz0))
               (unbox (worker-sat-state-zero-gas-rescue-latch st-z))
               (= (length dz1-to-11) 3)
               (= (unbox (worker-sat-state-zero-gas-rescue-rotation-idx st-z)) 1))
          (format "L66-WS(6): Zero-gas-freeze rescue latches at +300f (3w to safest geyser) & rotates at +224f (dz1-11=~a rot=~a)"
                  (length dz1-to-11) (unbox (worker-sat-state-zero-gas-rescue-rotation-idx st-z)))))

;; =============================================================================
;; 5. Loop 66 Feedback: `#:gas-starvation-boost? #t` & `#:apm-pressure-backoff? #t`
;; =============================================================================
(let ()
  ;; (5a) `#:gas-starvation-boost? #t` suppresses `< 300G` gas pullback while `boost=#f` pulls!
  (define b1 (mk-b 1 30.0 30.0 #:asgn 14 #:ideal 16 #:patches '(501 502)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 25.0 32.0 #:owner 1))
  (define g1 (mk-g 10 30.0 24.0 #:asgn 3 #:ideal 3 #:base 1))
  (define ws-pull
    (append (for/list ([i (in-range 14)]) (mk-w (+ 500 i) 26.0 30.0 #:ab 298 #:tgt 501))
            (for/list ([i (in-range 3)]) (mk-w (+ 520 i) 30.0 25.0 #:ab 298 #:tgt 10))))
  (define st-nob (make-worker-sat-state))
  (define st-bst (make-worker-sat-state))
  (define d-nob (gather-dirs (evaluate-worker-saturation-policy!
                              st-nob #:loop 6000 #:race 'Protoss #:minerals 100 #:gas 240
                              #:workers ws-pull #:bases (list b1) #:gas-buildings (list g1)
                              #:minerals-fields (list m1 m2)
                              #:gas-starvation-boost? #f)))
  (define d-bst (gather-dirs (evaluate-worker-saturation-policy!
                              st-bst #:loop 6000 #:race 'Protoss #:minerals 100 #:gas 240
                              #:workers ws-pull #:bases (list b1) #:gas-buildings (list g1)
                              #:minerals-fields (list m1 m2)
                              #:gas-starvation-boost? #t)))
  ;; (5b) `#:gas-starvation-boost? #t` raises carrying-fallback gas refill cap from 1 -> 2 workers/step
  ;;      AND respects `vespene-contents > 0` & `worker-crisis-gas-evac?`!
  (define st-rf1 (make-worker-sat-state))
  (define st-rf2 (make-worker-sat-state))
  (define g-empty-w (mk-g 20 30.0 24.0 #:asgn 0 #:ideal 3 #:vesp 2000 #:base 1))
  (define ws-all-carry
    (for/list ([i (in-range 14)])
      (mk-w (+ 540 i) 26.0 (+ 28.0 (* 0.2 i)) #:ab 298 #:tgt 501 #:min? #t)))
  (define rf-nob (gather-dirs (evaluate-worker-saturation-policy!
                               st-rf1 #:loop 6200 #:race 'Protoss #:minerals 200 #:gas 80
                               #:workers ws-all-carry #:bases (list b1) #:gas-buildings (list g-empty-w)
                               #:minerals-fields (list m1 m2)
                               #:gas-starvation-boost? #f)))
  (define rf-bst (gather-dirs (evaluate-worker-saturation-policy!
                               st-rf2 #:loop 6200 #:race 'Protoss #:minerals 200 #:gas 80
                               #:workers ws-all-carry #:bases (list b1) #:gas-buildings (list g-empty-w)
                               #:minerals-fields (list m1 m2)
                               #:gas-starvation-boost? #t)))
  ;; Depleted geyser (`vesp = 0`) STILL never refilled even with `gas-starvation-boost? = #t`!
  (define st-dep (make-worker-sat-state))
  (define g-dep (mk-g 21 30.0 24.0 #:asgn 0 #:ideal 0 #:vesp 0 #:base 1))
  (define rf-dep (gather-dirs (evaluate-worker-saturation-policy!
                               st-dep #:loop 6200 #:race 'Protoss #:minerals 200 #:gas 80
                               #:workers ws-all-carry #:bases (list b1) #:gas-buildings (list g-dep)
                               #:minerals-fields (list m1 m2)
                               #:gas-starvation-boost? #t)))
  (check! (and (= (length d-nob) 1)
               (null? d-bst)
               (= (length rf-nob) 1)
               (= (length (sat-directive-unit-tags (first rf-nob))) 1)
               (= (length rf-bst) 1)
               (= (length (sat-directive-unit-tags (first rf-bst))) 2)
               (null? rf-dep))
          (format "L66-WS(7): gas-starvation-boost? suppresses <300G pullback & raises refill cap 1->2w/step (nob=~a bst=~a rf1=~a rf2=~a dep=~a)"
                  d-nob d-bst rf-nob rf-bst rf-dep))

  ;; (5c) `#:apm-pressure-backoff? #t` doubles routine transfer (`48->96f`) & rally (`224->448f`) cooldowns,
  ;;      while NEVER throttling urgent Sec 0b evac (`32f`) or Sec 1 idle rescue (`32f`)!
  (define st-apm (make-worker-sat-state))
  (define b-main (mk-b 1 30.0 30.0 #:asgn 18 #:ideal 16 #:patches '(501)))
  (define b-nat  (mk-b 2 62.0 30.0 #:asgn 2 #:ideal 16 #:patches '(502 503)))
  (define m-nat1 (mk-m 502 67.0 30.0 #:owner 2))
  (define m-nat2 (mk-m 503 68.0 32.0 #:owner 2))
  (define ws-xfer
    (for/list ([i (in-range 10)])
      (mk-w (+ 600 i) 26.0 (+ 28.0 (* 0.2 i)) #:ab 298 #:tgt 501)))
  ;; First transfer at loop 7000 succeeds
  (define x0 (gather-dirs (evaluate-worker-saturation-policy!
                           st-apm #:loop 7000 #:race 'Protoss #:minerals 200 #:gas 50
                           #:workers ws-xfer #:bases (list b-main b-nat) #:gas-buildings '()
                           #:minerals-fields (list m1 m-nat1 m-nat2)
                           #:apm-pressure-backoff? #t)))
  ;; At `+60f` (`7060`, >= 48f normal cd, < 96f 2x backoff cd!): transfer MUST be throttled!
  (define x-60 (gather-dirs (evaluate-worker-saturation-policy!
                             st-apm #:loop 7060 #:race 'Protoss #:minerals 200 #:gas 50
                             #:workers ws-xfer #:bases (list b-main b-nat) #:gas-buildings '()
                             #:minerals-fields (list m1 m-nat1 m-nat2)
                             #:apm-pressure-backoff? #t)))
  ;; At `+96f` (`7096`, >= 96f 2x backoff cd!): transfer fires cleanly!
  (define x-96 (gather-dirs (evaluate-worker-saturation-policy!
                             st-apm #:loop 7096 #:race 'Protoss #:minerals 200 #:gas 50
                             #:workers ws-xfer #:bases (list b-main b-nat) #:gas-buildings '()
                             #:minerals-fields (list m1 m-nat1 m-nat2)
                             #:apm-pressure-backoff? #t)))
  ;; Urgent idle worker recovery at `+32f` MUST STILL fire unthrottled under `apm-pressure-backoff? = #t`!
  (define st-apm-idle (make-worker-sat-state))
  (define w-idle1 (mk-w 650 60.0 30.0 #:ab 0 #:tgt 0))
  (define i0 (gather-dirs (evaluate-worker-saturation-policy!
                           st-apm-idle #:loop 7000 #:race 'Protoss #:minerals 200 #:gas 50
                           #:workers (list w-idle1) #:bases (list b-nat) #:gas-buildings '()
                           #:minerals-fields (list m-nat1 m-nat2)
                           #:apm-pressure-backoff? #t)))
  (define i32 (gather-dirs (evaluate-worker-saturation-policy!
                            st-apm-idle #:loop 7032 #:race 'Protoss #:minerals 200 #:gas 50
                            #:workers (list w-idle1) #:bases (list b-nat) #:gas-buildings '()
                            #:minerals-fields (list m-nat1 m-nat2)
                            #:apm-pressure-backoff? #t)))
  (check! (and (= (length x0) 1)
               (null? x-60)
               (= (length x-96) 1)
               (= (length i0) 1)
               (= (length i32) 1))
          (format "L66-WS(8): apm-pressure-backoff? doubles transfer cd (48->96f) without throttling idle rescue (x0=~a x60=~a x96=~a i0=~a i32=~a)"
                  (length x0) (length x-60) (length x-96) (length i0) (length i32))))

;; =============================================================================
;; 6. Sec 5: Idle MULE Re-Tasking Onto Nearby Safe Mineral Patch
;; =============================================================================
(let ()
  (define st (make-worker-sat-state))
  (define b1 (mk-b 1 30.0 30.0 #:type 'orbital-command #:asgn 12 #:ideal 16 #:patches '(501 502)))
  (define m-unsafe (mk-m 501 27.0 30.0 #:owner 1 #:safe? #f))
  (define m-safe   (mk-m 502 25.0 32.0 #:owner 1 #:safe? #t))
  (define mule-idle (sat-mule-info 701 28.0 30.0 #t))
  (define mule-busy (sat-mule-info 702 28.0 31.0 #f))
  (define dm1 (gather-dirs (evaluate-worker-saturation-policy!
                            st #:loop 4000 #:race 'Terran #:minerals 200 #:gas 50
                            #:workers '() #:bases (list b1) #:gas-buildings '()
                            #:minerals-fields (list m-unsafe m-safe)
                            #:mules (list mule-idle mule-busy))))
  ;; 24f cooldown blocks duplicate re-task at +12f
  (define dm2 (gather-dirs (evaluate-worker-saturation-policy!
                            st #:loop 4012 #:race 'Terran #:minerals 200 #:gas 50
                            #:workers '() #:bases (list b1) #:gas-buildings '()
                            #:minerals-fields (list m-unsafe m-safe)
                            #:mules (list mule-idle mule-busy))))
  (check! (and (= (length dm1) 1)
               (equal? (sat-directive-unit-tags (first dm1)) '(701))
               (= (sat-directive-target-tag (first dm1)) 502)
               (not (sat-directive-urgent? (first dm1)))
               (null? dm2))
          (format "L66-WS(9): Sec 5 idle MULE picks nearby safe mineral patch & honors 24f cd (dm1=~a dm2=~a)" dm1 dm2)))

;; =============================================================================
;; 7. Section 2.3: `priority-macro-brain` Arbiter Override-Feedback Consumers
;;    - `#:arbiter-gas-override-count >= 3` (`gas < 150`, `< 2*bases`) -> +20.0
;;    - `#:arbiter-facility-override-count >= 4` (`min >= 400`, not under-attack?) -> +20.0
;;    - Below-threshold counts (`2` / `3`) trigger ZERO boost (anti-oscillation!)
;; =============================================================================
(let ()
  (define ws-gas-test
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 6000
     #:minerals 250 #:gas 80 #:supply-used 46 #:supply-cap 62 #:supply-left 16 #:pending-supply 0
     #:workers 32 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 3
     #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 1)
     #:total-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 1)
     #:unit-counts (hasheq 'probe 32 'stalker 5 'zealot 2)
     #:open-facility-slots (hasheq 'townhall 2 'gateway 2)))
  (reset-macro-escrow-tracker!)
  (define d-g0 (step-priority-macro-brain ws-gas-test #:arbiter-gas-override-count 0))
  (reset-macro-escrow-tracker!)
  (define d-g2 (step-priority-macro-brain ws-gas-test #:arbiter-gas-override-count 2))
  (reset-macro-escrow-tracker!)
  (define d-g3 (step-priority-macro-brain ws-gas-test #:arbiter-gas-override-count 3))
  (define ug0 (cand-u d-g0 'assimilator))
  (define ug2 (cand-u d-g2 'assimilator))
  (define ug3 (cand-u d-g3 'assimilator))
  ;; Gas >= 150 must suppress boost
  (define ws-gas-rich
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 6000
     #:minerals 250 #:gas 200 #:supply-used 46 #:supply-cap 62 #:supply-left 16 #:pending-supply 0
     #:workers 32 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 3
     #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 1)
     #:total-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 1)
     #:unit-counts (hasheq 'probe 32 'stalker 5 'zealot 2)
     #:open-facility-slots (hasheq 'townhall 2 'gateway 2)))
  (reset-macro-escrow-tracker!)
  (define d-gr0 (step-priority-macro-brain ws-gas-rich #:arbiter-gas-override-count 0))
  (reset-macro-escrow-tracker!)
  (define d-gr5 (step-priority-macro-brain ws-gas-rich #:arbiter-gas-override-count 5))
  ;; Also verify gas candidate injection when 2/4 geysers exist & arbiter-gas-overrides >= 3!
  (define ws-gas-inject
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 6000
     #:minerals 250 #:gas 80 #:supply-used 46 #:supply-cap 62 #:supply-left 16 #:pending-supply 0
     #:workers 32 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 6
     #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 2)
     #:total-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 2)
     #:unit-counts (hasheq 'probe 32 'stalker 5 'zealot 2)
     #:open-facility-slots (hasheq 'townhall 2 'gateway 2)))
  (reset-macro-escrow-tracker!)
  (define d-gi2 (step-priority-macro-brain ws-gas-inject #:arbiter-gas-override-count 2))
  (reset-macro-escrow-tracker!)
  (define d-gi3 (step-priority-macro-brain ws-gas-inject #:arbiter-gas-override-count 3))
  (check! (and (> ug0 0.0)
               (= ug2 ug0)
               (< (abs (- (- ug3 ug0) 20.0)) 0.01)
               (= (cand-u d-gr5 'assimilator) (cand-u d-gr0 'assimilator))
               (= (cand-u d-gi2 'assimilator) 0.0)
               (> (cand-u d-gi3 'assimilator) 0.0))
          (format "L66-MB(1): Arbiter gas override boost +20.0 at >=3 (<150G, <2*bases) & 0 at 2 or >=150G (u0=~a u2=~a u3=~a gi2=~a gi3=~a)"
                  ug0 ug2 ug3 (cand-u d-gi2 'assimilator) (cand-u d-gi3 'assimilator)))

  ;; Facility bottleneck scaling: >=4 overrides, >=400M, (not under-attack?) -> +20.0 on primary prod
  (define ws-fac-test
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Zerg #:frame 7500
     #:minerals 520 #:gas 180 #:supply-used 64 #:supply-cap 86 #:supply-left 22 #:pending-supply 0
     #:workers 40 #:active-bases 2 #:mineral-harvesters 32 #:gas-harvesters 8
     #:army-supply 24 #:enemy-threat-supply 0 #:under-attack? #f
     #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'factory 1 'starport 1 'refinery 4)
     #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'factory 1 'starport 1 'refinery 4)
     #:unit-counts (hasheq 'scv 40 'marine 14 'siege-tank 2 'medivac 2)
     #:open-facility-slots (hasheq 'townhall 2 'barracks 0 'factory 0 'starport 0)))
  (reset-macro-escrow-tracker!)
  (define d-f0 (step-priority-macro-brain ws-fac-test #:arbiter-facility-override-count 0))
  (reset-macro-escrow-tracker!)
  (define d-f3 (step-priority-macro-brain ws-fac-test #:arbiter-facility-override-count 3))
  (reset-macro-escrow-tracker!)
  (define d-f4 (step-priority-macro-brain ws-fac-test #:arbiter-facility-override-count 4))
  (define uf0 (cand-u d-f0 'barracks))
  (define uf3 (cand-u d-f3 'barracks))
  (define uf4 (cand-u d-f4 'barracks))
  ;; Under-attack? = #t must suppress facility scaling boost!
  (define ws-fac-atk
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Zerg #:frame 7500
     #:minerals 520 #:gas 180 #:supply-used 64 #:supply-cap 86 #:supply-left 22 #:pending-supply 0
     #:workers 40 #:active-bases 2 #:mineral-harvesters 32 #:gas-harvesters 8
     #:army-supply 24 #:enemy-threat-supply 14 #:under-attack? #t
     #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'factory 1 'starport 1 'refinery 4)
     #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'factory 1 'starport 1 'refinery 4)
     #:unit-counts (hasheq 'scv 40 'marine 14 'siege-tank 2 'medivac 2)
     #:open-facility-slots (hasheq 'townhall 2 'barracks 0 'factory 0 'starport 0)))
  (reset-macro-escrow-tracker!)
  (define d-fa0 (step-priority-macro-brain ws-fac-atk #:arbiter-facility-override-count 0))
  (reset-macro-escrow-tracker!)
  (define d-fa5 (step-priority-macro-brain ws-fac-atk #:arbiter-facility-override-count 5))
  (check! (and (> uf0 0.0)
               (= uf3 uf0)
               (< (abs (- (- uf4 uf0) 20.0)) 0.01)
               (= (cand-u d-fa5 'barracks) (cand-u d-fa0 'barracks)))
          (format "L66-MB(2): Arbiter facility override boost +20.0 at >=4 (>=400M, safe) & 0 at 3 or under-attack (u0=~a u3=~a u4=~a)"
                  uf0 uf3 uf4)))

;; =============================================================================
;; 8. Steady-State CPU Performance Benchmark (< 0.10 ms/step)
;; =============================================================================
(let ()
  (define st (make-worker-sat-state))
  (define bases
    (list (mk-b 1 30.0 30.0 #:asgn 16 #:ideal 16 #:patches '(1001 1002 1003 1004 1005 1006 1007 1008))
          (mk-b 2 62.0 30.0 #:asgn 16 #:ideal 16 #:patches '(1009 1010 1011 1012 1013 1014 1015 1016))
          (mk-b 3 30.0 64.0 #:asgn 10 #:ideal 16 #:patches '(1017 1018 1019 1020 1021 1022 1023 1024))))
  (define mins
    (append (for/list ([i (in-range 8)]) (mk-m (+ 1001 i) 24.0 (+ 26.0 (* 1.0 i)) #:owner 1))
            (for/list ([i (in-range 8)]) (mk-m (+ 1009 i) 68.0 (+ 26.0 (* 1.0 i)) #:owner 2))
            (for/list ([i (in-range 8)]) (mk-m (+ 1017 i) 24.0 (+ 60.0 (* 1.0 i)) #:owner 3))))
  (define gas-bs
    (list (mk-g 2001 30.0 24.0 #:asgn 3 #:ideal 3 #:base 1)
          (mk-g 2002 36.0 24.0 #:asgn 3 #:ideal 3 #:base 1)
          (mk-g 2003 62.0 24.0 #:asgn 3 #:ideal 3 #:base 2)
          (mk-g 2004 68.0 24.0 #:asgn 2 #:ideal 3 #:base 2)))
  (define ws
    (for/list ([i (in-range 40)])
      (mk-w (+ 3000 i) (+ 25.0 (modulo i 8)) (+ 26.0 (quotient i 8))
            #:ab 298 #:tgt (+ 1001 (modulo i 24)))))
  (define mules (list (sat-mule-info 4001 26.0 29.0 #f) (sat-mule-info 4002 65.0 29.0 #f)))
  (define n-iters 200)
  (define t0 (current-inexact-monotonic-milliseconds))
  (for ([k (in-range n-iters)])
    (evaluate-worker-saturation-policy!
     st #:loop (+ 6000 (* k 4)) #:race 'Terran #:minerals 350 #:gas 120
     #:workers ws #:bases bases #:gas-buildings gas-bs #:minerals-fields mins #:mules mules))
  (define avg-ms (/ (- (current-inexact-monotonic-milliseconds) t0) n-iters))
  (check! (< avg-ms 0.15)
          (format "L66-WS(10): Steady-state CPU < 0.15 ms/step (got ~a ms/step)"
                  (/ (round (* avg-ms 10000.0)) 10000.0)))
  (printf "worker-saturation-policy-test: ~a/~a passed (~a failed) [avg=~a ms/step]\n"
          passed (+ passed failed) failed (/ (round (* avg-ms 10000.0)) 10000.0)))

(when (> failed 0)
  (exit 1))
