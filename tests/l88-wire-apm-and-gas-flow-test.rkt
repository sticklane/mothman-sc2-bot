#lang racket/base

;; =============================================================================
;; Loop 88A Track 1 Unit Test Suite (`tests/l88-wire-apm-and-gas-flow-test.rkt`)
;;
;; Verifies all 3 Track 1 deliverables:
;;   1. Single-cap, zero-hardcoded-threshold `wire-apm-governor` (`lib/sc2-protobuf-ws.rkt`):
;;      - Quiet macro -> micro uses >92% of cap C (no artificial 78% wall!)
;;      - Surging macro -> live EMA reserve R_high(t) protects P0 & Core P1 with 0 drops
;;      - Stage 1 per-unit refractory (`16f` SCV repair, `8f` combat bypassed on >1.5t shift
;;        or new target-tag, `10f` mode-switch, `24f` land), `<5M` repair suppression,
;;        tag-level obs noop stripping on urgent-survival `23/16` & repair, unchanged repair
;;        backoff, and Depot `558` cooldown fix (only cleared on APM budget drop!)
;;      - Continuous value density `V(c)/ev-cost` with selection affinity, `V_cam < V_micro`,
;;        and 0 `token_bucket` drops on `V >= V_macro`!
;;   2. Closed-form SC2 physics flow-balanced gas saturation (`worker-saturation-policy.rkt`
;;      + `saturate-workers-and-gas-commands` pass-through):
;;      - High gas demand (Colossus/HT/Ravager) at 220G/100M keeps gas workers (0 false pull)
;;      - Mineral-heavy demand at 220G/80M pulls excess gas immediately (anti-GRM)
;;      - Explicit `#:desired-gas-workers` respected & clamped to physical limits
;;      - +-1w deadband & 112f opposite cooldown prevent pull/refill thrash
;;      - Physical mined-out evacuation & 6-worker mineral backbone
;;   3. Threat-aware safe-base tech placement + wire refusal signal (`lib/sc2-protobuf-ws.rkt`):
;;      - Zerg `spawning-pool` & `spire` shift from threatened Main (enemy air fleet OR recent
;;        building death) to safe living Natural/3rd Hatchery
;;      - Protoss fragile tech (`robotics-facility` / `templar-archive`) shifts to safe Pylon
;;      - Terran tech (`factory` / `starport`) shifts to safe living base
;;      - Impossible placement records typed refusal via `drain-wire-placement-refusals!`
;;        (`'no-creep`, `'no-power`, `'no-worker`) and drains idempotently!
;; =============================================================================

(require racket/list
         racket/format
         "../lib/plan/worker-saturation-policy.rkt"
         "../lib/sc2-protobuf-ws.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (hypot dx dy) (sqrt (+ (* dx dx) (* dy dy))))

(define (mk-unit tag utype alliance x y
                 #:hp [hp 200.0]
                 #:hp-max [hp-max hp]
                 #:sh [sh 200.0]
                 #:rad [rad 1.0]
                 #:bp [bp 1.0]
                 #:powered? [powered? #t]
                 #:flying? [flying? #f]
                 #:orders [orders '()]
                 #:mins [mins 0]
                 #:vesp [vesp 0]
                 #:asgn [asgn 0]
                 #:ideal [ideal 0])
  (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
            (sc2-point3d x y 10.0) 0.0 rad bp 0 #f #t #f
            hp hp-max sh sh 50.0 200.0 mins vesp
            flying? #f #f powered? #f
            orders 0 '() 0 0 0.0 0 asgn ideal 0 '() 0 0))

(define (mk-mins base-tag cx cy dx-off)
  (for/list ([i (in-range 6)])
    (mk-unit (+ base-tag i) 341 3 (+ cx dx-off) (+ cy (* (- i 2.5) 1.5))
             #:hp 1000.0 #:sh 0.0 #:rad 1.0 #:mins 1500)))

(define (mk-gi self-race enemy-race)
  (define w 128)
  (define h 128)
  (define pl-bytes (make-bytes (* w h) 1))
  (define pa-bytes (make-bytes (* w h) 1))
  (define th-bytes (make-bytes (* w h) 200))
  (for* ([y (in-range h)]
         [x (in-range w)])
    (define idx (+ x (* y w)))
    (when (or (< x 6) (> x 120) (< y 6) (> y 120))
      (bytes-set! pl-bytes idx 0)
      (bytes-set! pa-bytes idx 0)))
  (sc2-game-info
   "TestArena" "TestArena.SC2Map"
   (list (hash 'player-id 1 'race-requested self-race 'race-actual self-race)
         (hash 'player-id 2 'race-requested enemy-race 'race-actual enemy-race))
   (cons w h)
   (hash 'x0 6 'y0 6 'x1 120 'y1 120)
   (list (sc2-point2d 30.0 32.0) (sc2-point2d 98.0 96.0))
   (sc2-image-grid 8 w h pa-bytes #f #f)
   (sc2-image-grid 8 w h th-bytes #f #f)
   (sc2-image-grid 8 w h pl-bytes #f #f)))

(define (mk-obs loop mins gas units
                #:power-sources [ps '()]
                #:dead-tags [dead-tags '()]
                #:food-used [fu 40]
                #:food-cap [fc 60])
  (sc2-observation loop
                   (sc2-player-common 1 mins gas fc fu 0 0 0 0 0 0)
                   units '() ps #f dead-tags '() '() '() '() '()))

(define (first-cmd-pt cmds ab-id)
  (define c
    (findf (lambda (x)
             (and (sc2-raw-unit-command? x)
                  (= (sc2-raw-unit-command-ability-id x) ab-id)))
           cmds))
  (and c (sc2-raw-unit-command-target-pos c)))

(define (gov-rolling-used g)
  (for/sum ([ev (in-list (vector-ref (struct->vector g) 8))]) (cdr ev)))

;; =============================================================================
;; SECTION 1: Single-Cap, Zero-Hardcoded-Threshold `wire-apm-governor`
;; =============================================================================
(printf "[1/3] Testing single-cap zero-hardcoded-tier APM governor & Stage 1 spam filter...\n")

;; 1a: Quiet macro -> combat micro uses >92% of cap C across a full 60s window (no 78% static choke!)
(let ()
  (define gov (make-wire-apm-governor #:max-apm 500.0))
  (for ([step (in-range 1 175)])
    (define lp (* step 8))
    (define batch
      (list (sc2-raw-unit-command 23 (sc2-point2d (+ 40.0 (remainder step 30)) 50.0) 0
                                  (list (+ 10000 (* step 4)) (+ 10001 (* step 4))) #f)
            (sc2-raw-unit-command 16 (sc2-point2d (+ 50.0 (remainder step 25)) 60.0) 0
                                  (list (+ 20000 step)) #f)))
    (void (govern-sc2-wire-actions! gov batch lp)))
  (define used (gov-rolling-used gov))
  (check! (and (>= used 460) (<= used 500))
          (format "1a. Quiet-macro micro must exceed 92%% of cap 500 without 78%% choke; used=~a" used)))

;; 1b: Surging macro -> live EMA reserve R_high(t) automatically protects P0 & Core P1 with 0 drops!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 500.0))
  ;; Warm up real macro demand (Inject + Train + Build) alongside micro bursts over 30s
  (for ([step (in-range 1 85)])
    (define lp (* step 8))
    (define macro-cmds
      (if (= (modulo step 3) 0)
          (list (sc2-raw-unit-command 251 #f 99001 (list (+ 30000 step)) #f)
                (sc2-raw-unit-command 1343 #f 0 (list (+ 31000 step)) #f)
                (sc2-raw-unit-command 881 (sc2-point2d (+ 20.0 (remainder step 20)) 30.0) 0
                                      (list (+ 32000 step)) #f))
          '()))
    (define micro-cmds
      (for/list ([k (in-range 4)])
        (sc2-raw-unit-command 23 (sc2-point2d (+ 60.0 (* 2.0 k)) (+ 40.0 (remainder step 20))) 0
                              (list (+ 35000 (* step 10) k)) #f)))
    (void (govern-sc2-wire-actions! gov (append micro-cmds macro-cmds) lp)))
  (define used-mid (gov-rolling-used gov))
  ;; Now inject a full macro + P0 burst simultaneously with P2 micro flood:
  ;; ALL P0 & Core P1 commands MUST emit with 0 P0 / 0 Core-P1 drops!
  (reset-wire-apm-drop-stats! gov)
  (define surge-batch
    (list (sc2-raw-unit-command 23 (sc2-point2d 80.0 80.0) 0 '(39001) #f)
          (sc2-raw-unit-command 23 (sc2-point2d 82.0 82.0) 0 '(39002) #f)
          (sc2-raw-camera-move 90.0 90.0 0.0)
          (sc2-raw-unit-command 251 #f 99001 '(39101) #f)
          (sc2-raw-unit-command 3755 #f 99002 '(39102) #f)
          (sc2-raw-unit-command 399 (sc2-point2d 70.0 70.0) 0 '(39103) #f)
          (sc2-raw-unit-command 881 (sc2-point2d 38.0 38.0) 0 '(39104) #f)
          (sc2-raw-unit-command 1343 #f 0 '(39105) #f)
          (sc2-raw-unit-command 560 #f 0 '(39106) #f)
          (sc2-raw-unit-command 171 #f 99003 '(39107) #f)))
  (define out-surge (govern-sc2-wire-actions! gov surge-batch 700))
  (define emitted-abs (map sc2-raw-unit-command-ability-id (filter sc2-raw-unit-command? out-surge)))
  (define st (get-wire-apm-drop-stats gov))
  (define p0-drops (hash-ref (hash-ref st 'by_tier) 'P0 -1))
  (define p1-drops (hash-ref (hash-ref st 'by_tier) 'P1 -1))
  (check! (and (< used-mid 500)
               (= p0-drops 0)
               (= p1-drops 0)
               (andmap (lambda (ab) (not (not (memv ab emitted-abs))))
                       '(251 3755 399 881 1343 560 171)))
          (format "1b. Live EMA reserve must protect P0/Core-P1 under surge; usedMid=~a p0=~a p1=~a abs=~a"
                  used-mid p0-drops p1-drops emitted-abs)))

;; 1c: Per-unit refractory on SCV repair (3685) survives +-1 SCV squad change, suppresses <5M,
;;     and backs off unchanged rejected repair!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0))
  (define obs-rich (mk-obs 1000 100 0 (list (mk-unit 4001 45 1 30.0 30.0)
                                            (mk-unit 4002 45 1 31.0 30.0)
                                            (mk-unit 4003 45 1 32.0 30.0))))
  (define obs-poor (mk-obs 1020 3 0 (list (mk-unit 4001 45 1 30.0 30.0))))
  ;; Step 1 (loop 1000): SCVs 4001 & 4002 repair Bunker 4900 -> both emit
  (define r1 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 3685 #f 4900 '(4001 4002) #f)) 1000 obs-rich))
  ;; Step 2 (loop 1004, +4f < 16f): SCV 4003 joins squad (4001 4002 4003) -> ONLY 4003 emits!
  (define r2 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 3685 #f 4900 '(4001 4002 4003) #f)) 1004 obs-rich))
  ;; Step 3 (loop 1008, +8f < 16f): SCV 4001 switches to DIFFERENT target 4901 -> 0 latency bypass!
  (define r3 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 3685 #f 4901 '(4001) #f)) 1008 obs-rich))
  ;; Step 4 (loop 1020, >= 16f, minerals=3 < 5): suppressed pre-budget with 0 APM drops!
  (define r4 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 3685 #f 4900 '(4001) #f)) 1020 obs-poor))
  ;; Step 5 (unchanged repair backoff): emit at 2000 with empty obs orders, wait +16f (2016) -> passes & sets streak=2 (48f cd),
  ;;         then at +20f (2036 < 48f) with unchanged obs -> backed off!
  (define gov-bo (make-wire-apm-governor #:max-apm 760.0))
  (define scv-u (mk-unit 4101 45 1 30.0 30.0 #:orders '()))
  (define bo-obs1 (mk-obs 2000 100 0 (list scv-u)))
  (define bo-obs2 (mk-obs 2016 100 0 (list scv-u)))
  (define bo-obs3 (mk-obs 2036 100 0 (list scv-u)))
  (define b1 (govern-sc2-wire-actions! gov-bo (list (sc2-raw-unit-command 3685 #f 4950 '(4101) #f)) 2000 bo-obs1))
  (define b2 (govern-sc2-wire-actions! gov-bo (list (sc2-raw-unit-command 3685 #f 4950 '(4101) #f)) 2016 bo-obs2))
  (define b3 (govern-sc2-wire-actions! gov-bo (list (sc2-raw-unit-command 3685 #f 4950 '(4101) #f)) 2036 bo-obs3))
  (check! (and (= (length r1) 1)
               (= (length r2) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first r2)) '(4003))
               (= (length r3) 1)
               (null? r4)
               (= (hash-ref (get-wire-apm-drop-stats gov) 'total -1) 0)
               (= (length b1) 1)
               (= (length b2) 1)
               (null? b3))
          (format "1c. Per-unit repair refractory / <5M suppress / unchanged backoff failed: r2=~a r3=~a r4=~a b=~a/~a/~a"
                  r2 r3 r4 (length b1) (length b2) (length b3))))

;; 1d: Urgent survival 23/16 tag-level obs noop + per-unit 8f refractory + instant >1.5t shift bypass!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0))
  (define u1 (mk-unit 4201 74 1 50.0 50.0 #:orders (list (sc2-unit-order 23 (sc2-point3d 60.0 60.0 10.0) 0 0.0))))
  (define u2 (mk-unit 4202 74 1 51.0 50.0 #:orders '()))
  (define u3 (mk-unit 4203 74 1 52.0 50.0 #:orders '()))
  (define obs0 (mk-obs 1000 100 0 (list u1 u2 u3)))
  ;; u1 already attacking (60,60) -> stripped even though urgent-survival-cmd? = #t; u2 passes!
  (define o1 (govern-sc2-wire-actions!
              gov
              (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 60.2 60.1) 0 '(4201 4202) #f)))
              1000 obs0))
  ;; +4f (<8f): u2 + new u3 sent to same target (60.5, 60.2) (<=1.5t) -> u2 stripped by per-unit refractory, ONLY u3 emits!
  (define o2 (govern-sc2-wire-actions!
              gov
              (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 60.5 60.2) 0 '(4202 4203) #f)))
              1004 obs0))
  ;; +4f (<8f): u2 & u3 shift target > 1.5t to (65.0, 60.0) -> BOTH bypass immediately at 0 latency!
  (define o3 (govern-sc2-wire-actions!
              gov
              (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 65.0 60.0) 0 '(4202 4203) #f)))
              1004 obs0))
  (check! (and (= (length o1) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first o1)) '(4202))
               (= (length o2) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first o2)) '(4203))
               (= (length o3) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first o3)) '(4202 4203))
               (= (hash-ref (get-wire-apm-drop-stats gov) 'total -1) 0))
          (format "1d. Urgent 23/16 obs noop + per-unit refractory + >1.5t shift failed: o1=~a o2=~a o3=~a" o1 o2 o3)))

;; 1e: Depot 558 cooldown fix (unchanged backoff does NOT clear SC2-DEPOT-TOGGLE-COOLDOWN; APM drop DOES!)
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0))
  (define dep-u (mk-unit 4301 47 1 40.0 40.0 #:orders '()))
  (define obs1 (mk-obs 1000 100 0 (list dep-u)))
  (define obs2 (mk-obs 1012 100 0 (list dep-u)))
  (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN 4301 1000)
  (define d1 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 558 #f 0 '(4301) #f)) 1000 obs1))
  ;; +12f (< 24f unchanged p0-mode backoff, > 10f mode refractory): dropped by unchanged-backoff -> cooldown MUST stay set!
  (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN 4301 1012)
  (define d2 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 558 #f 0 '(4301) #f)) 1012 obs2))
  (define cd-kept-after-backoff? (hash-has-key? SC2-DEPOT-TOGGLE-COOLDOWN 4301))
  ;; Genuine APM budget drop (tight cap=0 via used=2 on cap=2):
  ;; 558 (Raise) MUST keep cooldown (prevents drop loops!), while fresh 556 (Lower) clears cooldown!
  (define gov-tight (make-wire-apm-governor #:max-apm 2.0))
  (void (govern-sc2-wire-actions! gov-tight (list (sc2-raw-unit-command 251 #f 99001 '(4399) #f)) 2000))
  (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN 4302 2004)
  (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN 4303 2004)
  (define d3 (govern-sc2-wire-actions! gov-tight
                                       (list (sc2-raw-unit-command 558 #f 0 '(4302) #f)
                                             (sc2-raw-unit-command 556 #f 0 '(4303) #f))
                                       2004))
  (define cd-558-kept-on-apm-drop? (hash-has-key? SC2-DEPOT-TOGGLE-COOLDOWN 4302))
  (define cd-556-cleared-on-apm-drop? (not (hash-has-key? SC2-DEPOT-TOGGLE-COOLDOWN 4303)))
  (hash-remove! SC2-DEPOT-TOGGLE-COOLDOWN 4301)
  (hash-remove! SC2-DEPOT-TOGGLE-COOLDOWN 4302)
  (check! (and (= (length d1) 1)
               (null? d2)
               cd-kept-after-backoff?
               (null? d3)
               cd-558-kept-on-apm-drop?
               cd-556-cleared-on-apm-drop?)
          (format "1e. Depot 558/556 cooldown fix failed: d1=~a d2=~a kept=~a d3=~a k558=~a c556=~a"
                  (length d1) (length d2) cd-kept-after-backoff? (length d3)
                  cd-558-kept-on-apm-drop? cd-556-cleared-on-apm-drop?)))

;; 1f: Continuous value ordering: V_cam < V_micro strictly & 0 token_bucket drops on V >= V_macro!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0 #:burst-capacity 2.0))
  ;; Drain 5s burst damper to 0.0 via 1 combat cmd, then send P0 Inject (251) + Core P1 Train (560) + Pro-Cam + Combat (23)
  (void (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 23 (sc2-point2d 50.0 50.0) 0 '(4400) #f)) 1000))
  (reset-wire-apm-drop-stats! gov)
  (define pcam (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 80.0 80.0 0.0) 40.0 #:base-snapped? #t #:crisis? #f))
  (define out-tight
    (govern-sc2-wire-actions!
     gov
     (list pcam
           (sc2-raw-unit-command 23 (sc2-point2d 70.0 70.0) 0 '(4401) #f)
           (sc2-raw-unit-command 251 #f 99001 '(4402) #f)
           (sc2-raw-unit-command 560 #f 0 '(4403) #f))
     1001))
  (define tight-abs (map sc2-raw-unit-command-ability-id (filter sc2-raw-unit-command? out-tight)))
  (define st-tight (get-wire-apm-drop-stats gov))
  ;; Under rolling cap=2 with fresh budget: combat micro (23) MUST beat pro-camera (V_cam < V_micro)!
  (define gov-cam (make-wire-apm-governor #:max-apm 2.0))
  (define pcam2 (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 90.0 90.0 0.0) 40.0 #:base-snapped? #t #:crisis? #f))
  (define out-cam
    (govern-sc2-wire-actions!
     gov-cam
     (list pcam2
           (sc2-raw-unit-command 23 (sc2-point2d 75.0 75.0) 0 '(4410 4411) #f))
     1000))
  (check! (and (not (not (memv 251 tight-abs)))
               (not (not (memv 560 tight-abs)))
               (= (hash-ref (hash-ref st-tight 'by_tier) 'P0 -1) 0)
               (= (hash-ref (hash-ref st-tight 'by_tier) 'P1 -1) 0)
               (= (length out-cam) 1)
               (sc2-raw-unit-command? (first out-cam))
               (= (sc2-raw-unit-command-ability-id (first out-cam)) 23))
          (format "1f. V_cam < V_micro & 0 token_bucket drops on V>=V_macro failed: tight=~a st=~a cam=~a"
                  tight-abs st-tight out-cam)))

;; 1g (Loop 88B): 3685/316 already-repairing live damaged ally suppresses target-flip ping-pong,
;;                allows immediate switch once target heals/dies, & coalesces mixed 316/3685!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0))
  (define bnk-dmg (mk-unit 4960 24 1 40.0 40.0 #:hp 220.0 #:hp-max 400.0))
  (define bnk-full (mk-unit 4960 24 1 40.0 40.0 #:hp 400.0 #:hp-max 400.0))
  (define tnk-dmg (mk-unit 4961 33 1 43.0 40.0 #:hp 110.0 #:hp-max 175.0))
  (define scv-busy (mk-unit 4971 45 1 39.0 40.0 #:orders (list (sc2-unit-order 3685 #f 4960 0.0))))
  (define scv-idle1 (mk-unit 4972 45 1 39.5 41.0 #:orders '()))
  (define scv-idle2 (mk-unit 4973 45 1 40.5 41.0 #:orders '()))
  ;; SCV 4971 is already repairing live damaged Bunker 4960 -> retarget to Tank 4961 MUST suppress!
  (define obs-dmg (mk-obs 3000 100 0 (list bnk-dmg tnk-dmg scv-busy scv-idle1 scv-idle2)))
  (define flip-out
    (govern-sc2-wire-actions!
     gov
     (list (sc2-raw-unit-command 3685 #f 4961 '(4971) #f))
     3000 obs-dmg))
  ;; Mixed 316 & 3685 on same target 4961 from idle SCVs 4972 + 4973 -> coalesce into 1 packet!
  (define coal-out
    (govern-sc2-wire-actions!
     gov
     (list (sc2-raw-unit-command 316 #f 4961 '(4972) #f)
           (sc2-raw-unit-command 3685 #f 4961 '(4973) #f))
     3000 obs-dmg))
  ;; 4f later while Tank 4961 is still live & damaged -> SCV 4972 flipping back to Bunker 4960 blocked by 16f refractory!
  (define lag-flip-out
    (govern-sc2-wire-actions!
     gov
     (list (sc2-raw-unit-command 3685 #f 4960 '(4972) #f))
     3004 obs-dmg))
  ;; Once Bunker 4960 is full HP -> SCV 4971 switches immediately to Tank 4961 at 0 latency!
  (define obs-healed (mk-obs 3008 100 0 (list bnk-full tnk-dmg scv-busy)))
  (define switch-out
    (govern-sc2-wire-actions!
     gov
     (list (sc2-raw-unit-command 3685 #f 4961 '(4971) #f))
     3008 obs-healed))
  (check! (and (null? flip-out)
               (= (length coal-out) 1)
               (= (sc2-raw-unit-command-ability-id (first coal-out)) 3685)
               (equal? (sc2-raw-unit-command-unit-tags (first coal-out)) '(4972 4973))
               (null? lag-flip-out)
               (= (length switch-out) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first switch-out)) '(4971))
               (= (hash-ref (get-wire-apm-drop-stats gov) 'total -1) 0))
          (format "1g. 3685 live-damaged-ally target-flip & coalesce failed: flip=~a coal=~a lag=~a sw=~a"
                  flip-out coal-out lag-flip-out switch-out)))

;; 1h (Loop 88B): 556/558 Supply Depot 24f shared per-depot refractory + already-morphed Stage 1a noop!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0))
  ;; Already raised (utype=19) strips 558; already lowered (utype=47) strips 556 with 0 APM drops!
  (define obs-noop
    (mk-obs 4000 100 0 (list (mk-unit 4801 19 1 40.0 40.0)
                             (mk-unit 4802 47 1 42.0 40.0))))
  (define noop-out
    (govern-sc2-wire-actions!
     gov
     (list (sc2-raw-unit-command 558 #f 0 '(4801) #f)
           (sc2-raw-unit-command 556 #f 0 '(4802) #f))
     4000 obs-noop))
  ;; 24f shared per-depot refractory suppresses repeat 558 and opposite 556 oscillation < 24f,
  ;; allows one urgent-556 transit lower, blocks urgent-556 -> 558 flip-back for 24f, & allows at +24f!
  (define e0 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 558 #f 0 '(4810) #f)) 4100))
  (define e1 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 558 #f 0 '(4810) #f)) 4112))
  (define e2 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 556 #f 0 '(4810) #f)) 4116))
  (define e-urg (govern-sc2-wire-actions!
                 gov
                 (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 556 #f 0 '(4810) #f)))
                 4118))
  (define e-flip (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 558 #f 0 '(4810) #f)) 4124))
  (define e3 (govern-sc2-wire-actions! gov (list (sc2-raw-unit-command 558 #f 0 '(4810) #f)) 4142))
  (check! (and (null? noop-out)
               (= (length e0) 1)
               (null? e1)
               (null? e2)
               (= (length e-urg) 1)
               (null? e-flip)
               (= (length e3) 1)
               (= (hash-ref (get-wire-apm-drop-stats gov) 'total -1) 0))
          (format "1h. 556/558 24f per-depot refractory, anti-flip-back & noop strip failed: noop=~a e=~a/~a/~a/urg=~a/flip=~a/~a"
                  noop-out (length e0) (length e1) (length e2) (length e-urg) (length e-flip) (length e3))))

;; 1i (Loop 88C): Urgent-survival 558 (blocked depot) & urgent 3685 (blocked SCV) BOTH obey
;;                Stage 1b refractory + per-unit Stage 1c exponential backoff even across squad changes!
(let ()
  (define gov (make-wire-apm-governor #:max-apm 760.0))
  (define dep-blk (mk-unit 4851 47 1 40.0 40.0 #:orders '()))
  (define dep-new (mk-unit 4852 47 1 42.0 40.0 #:orders '()))
  (define obs-d1 (mk-obs 5000 100 0 (list dep-blk dep-new)))
  ;; Urgent 558 on blocked depot 4851 at 5000 -> emits (streak 1, 24f cd)
  (define u0 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 558 #f 0 '(4851) #f))) 5000 obs-d1))
  ;; +12f (< 24f): urgent 558 on 4851 MUST be suppressed by Stage 1b 24f refractory!
  (define u1 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 558 #f 0 '(4851) #f))) 5012 obs-d1))
  ;; +24f (5024): 4851 still lowered (unchanged) -> retries once & escalates to streak 2 (64f cd)!
  (define u2 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 558 #f 0 '(4851) #f))) 5024 obs-d1))
  ;; +32f later (5056 < 5024+64=5088) with NEW depot 4852 added to batch: 4851 stays backed off, ONLY 4852 emits!
  (define u3 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 558 #f 0 '(4851 4852) #f))) 5056 obs-d1))
  ;; Urgent 3685 per-SCV Stage 1c backoff surviving +-1 SCV squad change!
  (define scv-blk (mk-unit 4861 45 1 30.0 30.0 #:orders '()))
  (define scv-new (mk-unit 4862 45 1 31.0 30.0 #:orders '()))
  (define obs-r (mk-obs 6000 100 0 (list scv-blk scv-new)))
  (define r0 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 3685 #f 4990 '(4861) #f))) 6000 obs-r))
  (define r1 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 3685 #f 4990 '(4861) #f))) 6016 obs-r))
  ;; +20f later (6036 < 6016+48=6064) with scv-new joining squad: 4861 stays backed off, ONLY 4862 emits!
  (define r2 (govern-sc2-wire-actions! gov (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 3685 #f 4990 '(4861 4862) #f))) 6036 obs-r))
  (check! (and (= (length u0) 1)
               (null? u1)
               (= (length u2) 1)
               (= (length u3) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first u3)) '(4852))
               (= (length r0) 1)
               (= (length r1) 1)
               (= (length r2) 1)
               (equal? (sc2-raw-unit-command-unit-tags (first r2)) '(4862))
               (= (hash-ref (get-wire-apm-drop-stats gov) 'total -1) 0))
          (format "1i. Urgent 558/3685 per-unit refractory & Stage 1c backoff failed: u=~a/~a/~a/~a r=~a/~a/~a"
                  u0 u1 u2 u3 r0 r1 r2)))

;; 1j (Loop 88D): Stage-2 drop 16f refractory stops 3685/3678/558 drop loops, 3678 Land gets
;;                Stage 1c per-unit backoff (24f->64f), & urgent 23/16 drops never inflate P0!
(let ()
  ;; (i) Stage-2 rolling-cap drop of 3685/3678/558 stamps 16f refractory -> retry at +4f causes 0 extra drops!
  (define gov-drop (make-wire-apm-governor #:max-apm 2.0))
  (void (govern-sc2-wire-actions! gov-drop (list (sc2-raw-unit-command 251 #f 99001 '(4880) #f)) 7000))
  (reset-wire-apm-drop-stats! gov-drop)
  (define drop-batch
    (list (sc2-raw-unit-command 3685 #f 4990 '(4881) #f)
          (sc2-raw-unit-command 3678 (sc2-point2d 40.0 40.0) 0 '(4882) #f)
          (sc2-raw-unit-command 558 #f 0 '(4883) #f)))
  (void (govern-sc2-wire-actions! gov-drop drop-batch 7004))
  (define drops-after-1 (hash-ref (get-wire-apm-drop-stats gov-drop) 'total -1))
  ;; +4f (< 16f drop refractory): all 3 suppressed in Stage 1b -> ZERO additional APM drops!
  (void (govern-sc2-wire-actions! gov-drop drop-batch 7008))
  (define drops-after-2 (hash-ref (get-wire-apm-drop-stats gov-drop) 'total -1))
  ;; (ii) 3678 Land gets Stage 1c per-unit exponential backoff (24f -> 64f) on unchanged flying building!
  (define gov-land (make-wire-apm-governor #:max-apm 760.0))
  (define fly-rax (mk-unit 4891 46 1 40.0 40.0 #:flying? #t #:orders '()))
  (define obs-l (mk-obs 8000 100 0 (list fly-rax)))
  (define l0 (govern-sc2-wire-actions! gov-land (list (sc2-raw-unit-command 3678 (sc2-point2d 42.0 42.0) 0 '(4891) #f)) 8000 obs-l))
  (define l1 (govern-sc2-wire-actions! gov-land (list (sc2-raw-unit-command 3678 (sc2-point2d 42.0 42.0) 0 '(4891) #f)) 8024 obs-l))
  ;; +32f later (8056 < 8024+64=8088): backed off in Stage 1c!
  (define l2 (govern-sc2-wire-actions! gov-land (list (sc2-raw-unit-command 3678 (sc2-point2d 42.0 42.0) 0 '(4891) #f)) 8056 obs-l))
  ;; (iii) Urgent 23/16 drops NEVER count as P0 or P1 drops (tier 2 combat)!
  (define gov-u23 (make-wire-apm-governor #:max-apm 2.0))
  (void (govern-sc2-wire-actions! gov-u23 (list (sc2-raw-unit-command 251 #f 99001 '(4895) #f)) 9000))
  (reset-wire-apm-drop-stats! gov-u23)
  (void (govern-sc2-wire-actions!
         gov-u23
         (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 30.0 30.0) 0 '(4896) #f)))
         9004))
  (define u23-st (get-wire-apm-drop-stats gov-u23))
  (check! (and (= drops-after-1 3)
               (= drops-after-2 3)
               (= (length l0) 1)
               (= (length l1) 1)
               (null? l2)
               (= (hash-ref (hash-ref u23-st 'by_tier) 'P0 -1) 0)
               (= (hash-ref (hash-ref u23-st 'by_tier) 'P1 -1) 0)
               (= (hash-ref (hash-ref u23-st 'by_tier) 'P2 -1) 1))
          (format "1j. Stage-2 drop refractory / 3678 Stage 1c / urgent-23 tier failed: d=~a/~a l=~a/~a/~a u23=~a"
                  drops-after-1 drops-after-2 (length l0) (length l1) (length l2) u23-st)))

;; =============================================================================
;; SECTION 2: Closed-Form SC2 Physics Flow-Balanced Gas Saturation
;; =============================================================================
(printf "[2/3] Testing closed-form SC2 physics flow-balanced gas saturation...\n")

;; 2a: Direct physics verification of `compute-flow-balanced-gas-target`
(let ()
  ;; High gas demand (Colossus/HT/Upgrade: m=700, g=600) at 220G/100M on 45w, 4 geysers -> G* >= 6 (0 false pull!)
  (define g-heavy (compute-flow-balanced-gas-target 45 4 100 220
                                                    #:mineral-demand-rate 700.0
                                                    #:gas-demand-rate 600.0))
  ;; Mineral-heavy demand (Marine/Zealot/Expand: m=1500, g=120) at 220G/80M on 45w, 4 geysers -> G* = 0 (anti-GRM!)
  (define m-heavy (compute-flow-balanced-gas-target 45 4 80 220
                                                    #:mineral-demand-rate 1500.0
                                                    #:gas-demand-rate 120.0))
  ;; Explicit Escrow Engine `#:desired-gas-workers 7` honored & clamped to physical slots
  (define g-explicit (compute-flow-balanced-gas-target 45 4 100 220 #:desired-gas-workers 7))
  (define g-clamped  (compute-flow-balanced-gas-target 8 4 100 50 #:desired-gas-workers 9))
  ;; Mined-out local base (`owned-mins = 0`) with gas-skewed bank -> G* = 0 (physical evac!)
  (define g-mined-out (compute-flow-balanced-gas-target 30 3 50 250 #:owned-mineral-count 0))
  (check! (and (>= g-heavy 6)
               (= m-heavy 0)
               (= g-explicit 7)
               (= g-clamped 2) ;; 8w - 6w mineral backbone = max 2 gas workers!
               (= g-mined-out 0))
          (format "2a. Flow-balanced physics G* failed: gHeavy=~a mHeavy=~a exp=~a clamp=~a minedOut=~a"
                  g-heavy m-heavy g-explicit g-clamped g-mined-out)))

;; 2b: End-to-end `saturate-workers-and-gas-commands` pass-through of demand kwargs
(let ()
  (define gi (mk-gi 'Protoss 'Terran))
  (define nex (mk-unit 5001 59 1 30.0 32.0 #:rad 2.5 #:asgn 14 #:ideal 16))
  (define g1  (mk-unit 5010 61 1 30.0 24.0 #:rad 1.5 #:vesp 2000 #:asgn 3 #:ideal 3))
  (define g2  (mk-unit 5011 61 1 36.0 24.0 #:rad 1.5 #:vesp 2000 #:asgn 3 #:ideal 3))
  (define mins (mk-mins 5100 30.0 32.0 -6.0))
  (define min-probes
    (for/list ([i (in-range 14)])
      (mk-unit (+ 5200 i) 84 1 25.0 (+ 28.0 (* 0.4 i))
               #:orders (list (sc2-unit-order 298 #f (+ 5100 (modulo i 6)) 0.0)))))
  (define gas-probes
    (append (for/list ([i (in-range 3)])
              (mk-unit (+ 5300 i) 84 1 30.0 25.0 #:orders (list (sc2-unit-order 298 #f 5010 0.0))))
            (for/list ([i (in-range 3)])
              (mk-unit (+ 5310 i) 84 1 36.0 25.0 #:orders (list (sc2-unit-order 298 #f 5011 0.0))))))
  (define all-u (append (list nex g1 g2) mins min-probes gas-probes))
  ;; Reset sat state cleanly via rewind
  (void (saturate-workers-and-gas-commands (mk-obs 4 20 30 all-u) #:game-info gi))
  ;; High gas demand (Colossus/HT) at 100M / 220G -> ZERO gas pullbacks!
  (define cmds-hi
    (saturate-workers-and-gas-commands
     (mk-obs 6000 100 220 all-u)
     #:game-info gi
     #:mineral-demand-rate 600.0
     #:gas-demand-rate 550.0))
  (define pulled-hi
    (count (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (memv (sc2-raw-unit-command-ability-id c) '(298 3666))
                  (ormap (lambda (t) (and (>= t 5300) (<= t 5312)))
                         (sc2-raw-unit-command-unit-tags c))))
           cmds-hi))
  ;; Mineral-heavy demand (Zealot/Expand) at same 100M / 220G -> pulls gas probes immediately!
  (void (saturate-workers-and-gas-commands (mk-obs 4 20 30 all-u) #:game-info gi))
  (define cmds-lo
    (saturate-workers-and-gas-commands
     (mk-obs 6000 100 220 all-u)
     #:game-info gi
     #:mineral-demand-rate 1500.0
     #:gas-demand-rate 100.0))
  (define pulled-lo
    (for/sum ([c (in-list cmds-lo)]
              #:when (and (sc2-raw-unit-command? c)
                          (memv (sc2-raw-unit-command-ability-id c) '(298 3666))))
      (count (lambda (t) (and (>= t 5300) (<= t 5312)))
             (sc2-raw-unit-command-unit-tags c))))
  (check! (and (= pulled-hi 0) (>= pulled-lo 3))
          (format "2b. saturate-workers-and-gas-commands demand pass-through failed: pulledHi=~a pulledLo=~a"
                  pulled-hi pulled-lo)))

;; 2c (Loop 88B): Smooth flow-gas hysteresis deadband (no hard G*=0 bypass) + <=2w per 112f cooldown!
(let ()
  (define b1 (sat-base-info 1 'orbital-command 30.0 30.0 #t #f 14 16 #f '(501 502)))
  (define b2 (sat-base-info 2 'orbital-command 60.0 30.0 #t #f 10 16 #f '(503 504)))
  (define m1 (sat-mineral-info 501 25.0 30.0 1500 1 #t))
  (define m2 (sat-mineral-info 502 25.0 32.0 1500 1 #t))
  (define m3 (sat-mineral-info 503 65.0 30.0 1500 2 #t))
  (define m4 (sat-mineral-info 504 65.0 32.0 1500 2 #t))
  (define (pull-cnt ds)
    (for/sum ([d (in-list ds)]
              #:when (and (eq? (sat-directive-kind d) 'harvest-gather)
                          (memq (sat-directive-reason d)
                                '(gas-pull-grms-urgent gas-pull-routine gas-pull-early gas-pull-mined-out-evac))))
      (length (sat-directive-unit-tags d))))
  (define min-ws
    (for/list ([i (in-range 22)])
      (sat-worker-info (+ 7100 i) 'scv 26.0 30.0 298 501 #f #f #f #f)))
  ;; (i) cur=1, G*=0 at non-overflow gas (140G <= 2x horizon=200G): +-1w deadband MUST NOT pull last SCV!
  (define st1 (make-worker-sat-state))
  (define ws-1g (append min-ws (list (sat-worker-info 7201 'scv 30.0 25.0 298 10 #f #f #f #f))))
  (define d-deadband
    (evaluate-worker-saturation-policy!
     st1 #:loop 4000 #:race 'Terran #:minerals 100 #:gas 140
     #:workers ws-1g #:bases (list b1 b2)
     #:gas-buildings (list (sat-gas-info 10 'refinery 30.0 24.0 #t 2000 1 3 1 #f))
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 200.0 #:desired-gas-workers 0))
  ;; (ii) cur=6, G*=0 at non-overflow gas (140G): smooth pull capped at <=2w, throttled during 112f cd, resumes at +112f!
  (define st2 (make-worker-sat-state))
  (define ws-6g
    (append min-ws
            (for/list ([i (in-range 3)]) (sat-worker-info (+ 7300 i) 'scv 30.0 25.0 298 10 #f #f #f #f))
            (for/list ([i (in-range 3)]) (sat-worker-info (+ 7310 i) 'scv 60.0 25.0 298 11 #f #f #f #f))))
  (define ws-4g
    (append min-ws
            (for/list ([i (in-range 2)]) (sat-worker-info (+ 7300 i) 'scv 30.0 25.0 298 10 #f #f #f #f))
            (for/list ([i (in-range 2)]) (sat-worker-info (+ 7310 i) 'scv 60.0 25.0 298 11 #f #f #f #f))))
  (define g1-3 (sat-gas-info 10 'refinery 30.0 24.0 #t 2000 3 3 1 #f))
  (define g2-3 (sat-gas-info 11 'refinery 60.0 24.0 #t 2000 3 3 2 #f))
  (define g1-2 (sat-gas-info 10 'refinery 30.0 24.0 #t 2000 2 3 1 #f))
  (define g2-2 (sat-gas-info 11 'refinery 60.0 24.0 #t 2000 2 3 2 #f))
  (define d-sm1
    (evaluate-worker-saturation-policy!
     st2 #:loop 5000 #:race 'Terran #:minerals 100 #:gas 140
     #:workers ws-6g #:bases (list b1 b2) #:gas-buildings (list g1-3 g2-3)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 200.0 #:desired-gas-workers 0))
  (define d-sm-cd
    (evaluate-worker-saturation-policy!
     st2 #:loop 5016 #:race 'Terran #:minerals 100 #:gas 140
     #:workers ws-4g #:bases (list b1 b2) #:gas-buildings (list g1-2 g2-2)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 200.0 #:desired-gas-workers 0))
  (define d-sm2
    (evaluate-worker-saturation-policy!
     st2 #:loop 5116 #:race 'Terran #:minerals 100 #:gas 140
     #:workers ws-4g #:bases (list b1 b2) #:gas-buildings (list g1-2 g2-2)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 200.0 #:desired-gas-workers 0))
  ;; (iii) Mineral-paired gas overflow (336G / 44M with high nominal g-dem=400 -> 2x horizon=400G > 336G,
  ;;       yet cur-gas 336G >> mineral-paired burn!): pulls 4w immediately & drains again at +48f (NOT 112f)!
  (define st3 (make-worker-sat-state))
  (define d-ovf1
    (evaluate-worker-saturation-policy!
     st3 #:loop 6000 #:race 'Terran #:minerals 44 #:gas 336
     #:workers ws-6g #:bases (list b1 b2) #:gas-buildings (list g1-3 g2-3)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 400.0 #:desired-gas-workers 0))
  (define d-ovf-cd
    (evaluate-worker-saturation-policy!
     st3 #:loop 6024 #:race 'Terran #:minerals 44 #:gas 336
     #:workers ws-4g #:bases (list b1 b2) #:gas-buildings (list g1-2 g2-2)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 400.0 #:desired-gas-workers 0))
  (define d-ovf2
    (evaluate-worker-saturation-policy!
     st3 #:loop 6052 #:race 'Terran #:minerals 44 #:gas 336
     #:workers ws-4g #:bases (list b1 b2) #:gas-buildings (list g1-2 g2-2)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 400.0 #:desired-gas-workers 0))
  (check! (and (= (pull-cnt d-deadband) 0)
               (= (pull-cnt d-sm1) 2)
               (= (pull-cnt d-sm-cd) 0)
               (= (pull-cnt d-sm2) 2)
               (= (pull-cnt d-ovf1) 4)
               (= (pull-cnt d-ovf-cd) 0)
               (= (pull-cnt d-ovf2) 4))
          (format "2c. Smooth flow-gas hysteresis & mineral-paired 4w/48f overflow drain failed: db=~a sm1=~a cd=~a sm2=~a ovf=~a/~a/~a"
                  (pull-cnt d-deadband) (pull-cnt d-sm1) (pull-cnt d-sm-cd) (pull-cnt d-sm2)
                  (pull-cnt d-ovf1) (pull-cnt d-ovf-cd) (pull-cnt d-ovf2))))

;; =============================================================================
;; SECTION 3: Threat-Aware Safe-Base Tech Placement + Wire Refusal Signal
;; =============================================================================
(printf "[3/3] Testing threat-aware safe-base tech placement & refusal signals...\n")

;; 3a: Zerg Spawning Pool & Spire shift from Main under enemy air fleet (Tempests)
;;     OR recent friendly building death to safe living Natural Hatchery!
(let ()
  (define gi (mk-gi 'Zerg 'Protoss))
  (define main-h (mk-unit 6001 86 1 30.0 32.0 #:rad 2.5))
  (define nat-h  (mk-unit 6002 86 1 64.0 32.0 #:rad 2.5))
  (define main-mins (mk-mins 6100 30.0 32.0 -6.0))
  (define nat-mins  (mk-mins 6110 64.0 32.0 6.0))
  (define drones (list (mk-unit 6201 104 1 32.0 34.0)
                       (mk-unit 6202 104 1 62.0 34.0)))
  (define safe-units (append (list main-h nat-h) main-mins nat-mins drones))
  ;; Reset state & verify peaceful Main still anchors SpawningPool near Main
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 200 100 safe-units) #:game-info gi))
  (define cmds-peace
    (translate-bot-actions->sc2-raw-commands
     '((build spawning-pool 30 32))
     (mk-obs 5000 300 200 safe-units)
     #:game-info gi))
  (define pt-peace (first-cmd-pt cmds-peace 1155))
  ;; Now hover 3 enemy Tempests (496, flying=#t) over Main (32, 34) -> Spire MUST shift to safe Natural (64, 32)!
  (define tempests
    (list (mk-unit 6901 496 4 32.0 34.0 #:flying? #t)
          (mk-unit 6902 496 4 34.0 32.0 #:flying? #t)
          (mk-unit 6903 496 4 28.0 35.0 #:flying? #t)))
  (define cmds-air
    (translate-bot-actions->sc2-raw-commands
     '((build spire 30 32))
     (mk-obs 5100 300 300 (append safe-units tempests))
     #:game-info gi))
  (define pt-air (first-cmd-pt cmds-air 1158))
  ;; Now test recent friendly building death in Main (even after enemy leaves!):
  ;; Step 1: Observe living SpawningPool (6050) in Main at loop 6000
  (define pool-main (mk-unit 6050 89 1 28.0 36.0 #:rad 1.5))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 200 100 safe-units) #:game-info gi))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 6000 300 200 (cons pool-main safe-units)) #:game-info gi))
  ;; Step 2: Pool 6050 dies (`dead-tags = '(6050)`) at loop 6040 -> rebuilding SpawningPool MUST shift to safe Natural!
  (define cmds-death
    (translate-bot-actions->sc2-raw-commands
     '((build spawning-pool 30 32))
     (mk-obs 6040 300 200 safe-units #:dead-tags '(6050))
     #:game-info gi))
  (define pt-death (first-cmd-pt cmds-death 1155))
  (check! (and (sc2-point2d? pt-peace)
               (< (hypot (- (sc2-point2d-x pt-peace) 30.0) (- (sc2-point2d-y pt-peace) 32.0)) 15.0)
               (sc2-point2d? pt-air)
               (< (hypot (- (sc2-point2d-x pt-air) 64.0) (- (sc2-point2d-y pt-air) 32.0)) 15.0)
               (sc2-point2d? pt-death)
               (< (hypot (- (sc2-point2d-x pt-death) 64.0) (- (sc2-point2d-y pt-death) 32.0)) 15.0))
          (format "3a. Zerg safe-base tech shift failed: peace=~a air=~a death=~a" pt-peace pt-air pt-death)))

;; 3b: Protoss fragile tech (`templar-archive`) shifts to safe Natural Pylon when Main is threatened!
(let ()
  (define gi (mk-gi 'Protoss 'Terran))
  (define nex1 (mk-unit 7001 59 1 30.0 32.0 #:rad 2.5))
  (define nex2 (mk-unit 7002 59 1 68.0 32.0 #:rad 2.5))
  (define py1  (mk-unit 7011 60 1 34.0 36.0 #:rad 1.0))
  (define py2  (mk-unit 7012 60 1 72.0 36.0 #:rad 1.0))
  (define prb1 (mk-unit 7201 84 1 32.0 34.0))
  (define prb2 (mk-unit 7202 84 1 70.0 34.0))
  (define ps   (list (sc2-power-source 7011 (sc2-point3d 34.0 36.0 10.0) 6.5)
                     (sc2-power-source 7012 (sc2-point3d 72.0 36.0 10.0) 6.5)))
  (define enemy-bcs (list (mk-unit 7901 57 4 33.0 35.0 #:flying? #t)))
  (define p-units (list nex1 nex2 py1 py2 prb1 prb2))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 300 300 p-units #:power-sources ps) #:game-info gi))
  (define cmds-p
    (translate-bot-actions->sc2-raw-commands
     '((build templar-archive 34 36))
     (mk-obs 7000 300 300 (append p-units enemy-bcs) #:power-sources ps)
     #:game-info gi))
  (define pt-p (first-cmd-pt cmds-p 890))
  (check! (and (sc2-point2d? pt-p)
               (< (hypot (- (sc2-point2d-x pt-p) 72.0) (- (sc2-point2d-y pt-p) 36.0)) 8.0))
          (format "3b. Protoss fragile tech safe-base shift failed: pt=~a" pt-p)))

;; 3c: Terran tech (`starport`) shifts to safe Natural CC when Main is threatened!
(let ()
  (define gi (mk-gi 'Terran 'Protoss))
  (define cc1  (mk-unit 8001 18 1 30.0 32.0 #:rad 2.5))
  (define cc2  (mk-unit 8002 18 1 68.0 32.0 #:rad 2.5))
  (define scv1 (mk-unit 8201 45 1 32.0 34.0))
  (define scv2 (mk-unit 8202 45 1 70.0 34.0))
  (define enemy-temp (list (mk-unit 8901 496 4 32.0 34.0 #:flying? #t)))
  (define t-units (list cc1 cc2 scv1 scv2))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 300 300 t-units) #:game-info gi))
  (define cmds-t
    (translate-bot-actions->sc2-raw-commands
     '((build starport 32 34))
     (mk-obs 7200 300 300 (append t-units enemy-temp))
     #:game-info gi))
  (define pt-t (first-cmd-pt cmds-t 329))
  (check! (and (sc2-point2d? pt-t)
               (< (hypot (- (sc2-point2d-x pt-t) 68.0) (- (sc2-point2d-y pt-t) 32.0)) 16.0))
          (format "3c. Terran tech safe-base shift failed: pt=~a" pt-t)))

;; 3d: Typed wire refusal export (`drain-wire-placement-refusals!` & `get-last-wire-placement-refusals`)
(let ()
  (define gi-p (mk-gi 'Protoss 'Terran))
  (define nex-only (list (mk-unit 9001 59 1 30.0 32.0 #:rad 2.5)
                         (mk-unit 9002 84 1 32.0 34.0)))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 300 200 nex-only) #:game-info gi-p))
  ;; Protoss Robotics Facility with ZERO Pylons -> `'no-power` refusal!
  (void (translate-bot-actions->sc2-raw-commands
         '((build robotics-facility 32 34))
         (mk-obs 7400 300 200 nex-only)
         #:game-info gi-p))
  (define snap-p (get-last-wire-placement-refusals))
  (define drained-p (drain-wire-placement-refusals!))
  (define drained-p2 (drain-wire-placement-refusals!))
  ;; Zerg Spire with ZERO Hatcheries/creep and blocked placement grid -> `'no-creep` refusal!
  (define gi-z-blocked
    (let* ([w 128] [h 128]
           [pl (make-bytes (* w h) 0)]
           [pa (make-bytes (* w h) 0)]
           [th (make-bytes (* w h) 200)])
      (sc2-game-info
       "Blocked" "Blocked.SC2Map"
       (list (hash 'player-id 1 'race-requested 'Zerg 'race-actual 'Zerg)
             (hash 'player-id 2 'race-requested 'Protoss 'race-actual 'Protoss))
       (cons w h) (hash 'x0 6 'y0 6 'x1 120 'y1 120)
       (list (sc2-point2d 30.0 32.0) (sc2-point2d 98.0 96.0))
       (sc2-image-grid 8 w h pa #f #f)
       (sc2-image-grid 8 w h th #f #f)
       (sc2-image-grid 8 w h pl #f #f))))
  (define drone-only (list (mk-unit 9101 104 1 32.0 34.0)))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 300 200 drone-only) #:game-info gi-z-blocked))
  (void (translate-bot-actions->sc2-raw-commands
         '((build spire 32 34))
         (mk-obs 7500 300 200 drone-only)
         #:game-info gi-z-blocked))
  (define drained-z (drain-wire-placement-refusals!))
  ;; Workerless build -> `'no-worker` refusal!
  (define gi-t (mk-gi 'Terran 'Zerg))
  (define cc-no-scv (list (mk-unit 9201 18 1 30.0 32.0 #:rad 2.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (mk-obs 4 300 200 cc-no-scv) #:game-info gi-t))
  (void (translate-bot-actions->sc2-raw-commands
         '((build factory 34 34))
         (mk-obs 7600 300 200 cc-no-scv)
         #:game-info gi-t))
  (define drained-t (drain-wire-placement-refusals!))
  (check! (and (equal? snap-p drained-p)
               (null? drained-p2)
               (ormap (lambda (r) (and (eq? (first r) 'robotics-facility) (eq? (second r) 'no-power))) drained-p)
               (ormap (lambda (r) (and (eq? (first r) 'spire) (eq? (second r) 'no-creep))) drained-z)
               (ormap (lambda (r) (and (eq? (first r) 'factory) (eq? (second r) 'no-worker))) drained-t))
          (format "3d. Wire placement refusal export failed: p=~a p2=~a z=~a t=~a"
                  drained-p drained-p2 drained-z drained-t)))

(printf "l88-wire-apm-and-gas-flow-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
