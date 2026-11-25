#lang racket/base

;; =============================================================================
;; Loop 73 Lane C Verification Suite (`lib/sc2-protobuf-ws.rkt`)
;; Covers:
;;   1. Zerg Larva multi-tag coalescing (`1342..1356`) in `SC2-WIRE-COALESCABLE-ABILITIES`
;;      (1 packet per ability, sorted tags, `ev-cost = 2` vs `2K`; mixed abilities separate;
;;      Terran Reactored Barracks `560` strictly UNCOALESCED!)
;;   2. Isolated `SC2-GOV-LAST-P1-TRAIN-LOOP` rescue vs. Creep Tumor (`1733`) & Baneling morph (`4121`)
;;      spam: overdue `>= 12`-loop training/supply rescues BEFORE tumors/morphs & BEFORE P0 spells,
;;      while strictly bounding `1a-pre` rescues to `<= 3` (zero double-rescue).
;;   3. `1c` (`>= 8`-loop) training/supply rescue runs BEFORE P0 mode switches even when a Creep Tumor
;;      emitted 4 loops earlier.
;;   4. Training/supply ordering ahead of morphs/tumors in normal `p1-cmds` drain under tight tokens
;;      (`881` Pylon & `917` Stalker emit ahead of `1733`/`4121`).
;;   5. Match rewind reset clears `SC2-GOV-LAST-P1-TRAIN-LOOP` back to `-1000`.
;;   6. Existing `l65-c2` two-prong & `w7-p0-2-wire-gov` multi-squad P2 invariants remain intact.
;; =============================================================================

(require racket/list
         "../lib/sc2-protobuf-ws.rkt")

(define tests-run 0)
(define tests-failed 0)

(define (check-true name pred [detail ""])
  (set! tests-run (+ tests-run 1))
  (unless pred
    (set! tests-failed (+ tests-failed 1))
    (eprintf "FAIL [~a]: ~a\n" name detail)))

(define (cmd-abilities cmds)
  (for/list ([c (in-list cmds)] #:when (sc2-raw-unit-command? c))
    (sc2-raw-unit-command-ability-id c)))

;; -----------------------------------------------------------------------------
;; 1. Zerg Larva Coalescing & Terran Reactor Non-Coalescing
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 6 separate 1-Larva TrainZergling (`1343`) commands coalesce into ONE sorted-tag packet!
  ;;     With burst-capacity = 4.0 (init tokens = 4.0), 6 uncoalesced cmds would cost 12 tokens
  ;;     and only emit 2; coalesced into 1 packet (`ev-cost = 2`) emits ALL 6 Larvae in 1 packet!
  (define gov1 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0 #:burst-capacity 4.0))
  (define larva-lings
    (list (sc2-raw-unit-command 1343 #f 0 '(906) #f)
          (sc2-raw-unit-command 1343 #f 0 '(902) #f)
          (sc2-raw-unit-command 1343 #f 0 '(905) #f)
          (sc2-raw-unit-command 1343 #f 0 '(901) #f)
          (sc2-raw-unit-command 1343 #f 0 '(904) #f)
          (sc2-raw-unit-command 1343 #f 0 '(903) #f)))
  (define out1 (govern-sc2-wire-actions! gov1 larva-lings 100))
  (check-true "l73-c1-6-larva-train-zergling-coalesce-into-1-sorted-packet"
              (and (= (length out1) 1)
                   (= (sc2-raw-unit-command-ability-id (first out1)) 1343)
                   (equal? (sc2-raw-unit-command-unit-tags (first out1))
                           '(901 902 903 904 905 906)))
              (format "out1=~a" out1))

  ;; (b) Mixed abilities: 3x TrainZergling (`1343`) + 2x TrainRoach (`1351`) -> 2 coalesced packets
  (define gov1b (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define mixed-larvae
    (list (sc2-raw-unit-command 1343 #f 0 '(913) #f)
          (sc2-raw-unit-command 1351 #f 0 '(922) #f)
          (sc2-raw-unit-command 1343 #f 0 '(911) #f)
          (sc2-raw-unit-command 1351 #f 0 '(921) #f)
          (sc2-raw-unit-command 1343 #f 0 '(912) #f)))
  (define out1b (govern-sc2-wire-actions! gov1b mixed-larvae 100))
  (check-true "l73-c1-mixed-larva-abilities-produce-1-packet-per-ability"
              (and (= (length out1b) 2)
                   (= (sc2-raw-unit-command-ability-id (first out1b)) 1343)
                   (equal? (sc2-raw-unit-command-unit-tags (first out1b)) '(911 912 913))
                   (= (sc2-raw-unit-command-ability-id (second out1b)) 1351)
                   (equal? (sc2-raw-unit-command-unit-tags (second out1b)) '(921 922)))
              (format "out1b=~a" out1b))

  ;; (c) Terran Reactored Barracks (two `560` TrainMarine commands on the SAME building tag)
  ;;     MUST remain 2 separate commands (never collapsed by coalescer!)
  (define gov1c (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define reactor-rax-2
    (list (sc2-raw-unit-command 560 #f 0 '(5001) #f)
          (sc2-raw-unit-command 560 #f 0 '(5001) #f)))
  (define out1c (govern-sc2-wire-actions! gov1c reactor-rax-2 100))
  (check-true "l73-c1-terran-reactor-barracks-same-tag-never-coalesced"
              (and (= (length out1c) 2)
                   (andmap (lambda (c)
                             (and (= (sc2-raw-unit-command-ability-id c) 560)
                                  (equal? (sc2-raw-unit-command-unit-tags c) '(5001))))
                           out1c))
              (format "out1c=~a" out1c)))

;; -----------------------------------------------------------------------------
;; 2. Isolated P1 Training Rescue vs. Creep Tumor / Baneling Morph Spam (`1a-pre`)
;; -----------------------------------------------------------------------------
(let ()
  ;; Setup: burst-capacity = 4.0, target-apm = 480.0 (~0.3571 tokens/loop).
  ;; Loop 100: emit 1733 (Creep Tumor) + 4121 (Baneling morph) -> tokens 4.0 -> 0.0,
  ;;           SC2-GOV-LAST-P1-LOOP = 100, SC2-GOV-LAST-P1-TRAIN-LOOP remains -1000 (stale!).
  ;; Loop 108 (+8f = +2.857t): P0 spell 251 (`2.857 -> 0.857`) + `1c` (`dt=8`) emits 1733 (`0.857 -> -1.143`),
  ;;           setting SC2-GOV-LAST-P1-LOOP = 108 while SC2-GOV-LAST-P1-TRAIN-LOOP stays -1000!
  ;; Loop 112 (+4f = +1.429t -> tokens = +0.286 < 2.0 normal P1 cost; `dt(LAST-P1-LOOP) = 4 < 12`):
  ;;           Send `[1733, 4121, 1343, 1344]` alongside P0 active spells (`251` Inject, `1664` Transfuse).
  ;;           Isolated `SC2-GOV-LAST-P1-TRAIN-LOOP` (`>= 12` loops) MUST rescue BOTH `1343` & `1344`
  ;;           (`0.286 -> -1.714 -> -3.714`) BEFORE `1733`/`4121` AND BEFORE P0 spells!
  (define gov2 (make-wire-apm-governor #:target-apm 480.0 #:hard-cap-apm 595.0 #:burst-capacity 4.0))
  (void (govern-sc2-wire-actions!
         gov2
         (list (sc2-raw-unit-command 1733 (sc2-point2d 50.0 50.0) 0 '(7001) #f)
               (sc2-raw-unit-command 4121 #f 0 '(7002) #f))
         100))
  (void (govern-sc2-wire-actions!
         gov2
         (list (sc2-raw-unit-command 1733 (sc2-point2d 52.0 50.0) 0 '(7003) #f)
               (sc2-raw-unit-command 251 #f 7100 '(7010) #f))
         108))
  (define out-112
    (govern-sc2-wire-actions!
     gov2
     (list (sc2-raw-unit-command 1733 (sc2-point2d 54.0 50.0) 0 '(7004) #f)
           (sc2-raw-unit-command 4121 #f 0 '(7005) #f)
           (sc2-raw-unit-command 1343 #f 0 '(7020) #f)
           (sc2-raw-unit-command 1344 #f 0 '(7021) #f)
           (sc2-raw-unit-command 251 #f 7100 '(7012) #f)
           (sc2-raw-unit-command 1664 #f 7101 '(7013) #f))
     112))
  (define abs-112 (cmd-abilities out-112))
  (check-true "l73-c2-isolated-p1-train-rescue-beats-tumors-morphs-and-p0-spells"
              (equal? abs-112 '(1343 1344))
              (format "Expected '(1343 1344) rescued ahead of 1733/4121 & P0 spells; got ~a" abs-112))

  ;; Also test with 4 distinct training/supply commands when tokens = 1.0 -> `1a-pre` rescues AT MOST 3
  ;; (and does NOT double-rescue with general P1 rescue!)
  (define gov2b (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 485.0 #:burst-capacity 1.0))
  ;; Tokens start at 1.0 (< 2.0 normal P1 cost); `1a-pre` floor = -4.0 allows 2 cmds (1.0 -> -1.0 -> -3.0);
  ;; use burst = 3.0 & drain to 2.0, wait: with burst = 2.0 at loop 100, normal P1 drain emits 1x 1733 (2.0->0.0),
  ;; then at loop 112 (tokens ~1.78), 1a-pre (floor -4.0, max-count 3) can emit 2 cmds (1.78 -> -0.22 -> -2.22),
  ;; or with burst = 5.0 at loop 100 emit 2x 1733 (5.0 -> 1.0) -> wait, use same-tag drain to sit at ~2.5 tokens
  ;; and verify total rescued in 1a-pre + P0 ordering never exceeds 3 even with 5 train+tumor cmds + P0 spells!
  (define gov2c (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0 #:burst-capacity 2.0))
  (define out-cap3
    (govern-sc2-wire-actions!
     gov2c
     (list (sc2-raw-unit-command 1733 (sc2-point2d 50.0 50.0) 0 '(7101) #f)
           (sc2-raw-unit-command 4121 #f 0 '(7102) #f)
           (sc2-raw-unit-command 1343 #f 0 '(7103) #f)
           (sc2-raw-unit-command 1344 #f 0 '(7104) #f)
           (sc2-raw-unit-command 1351 #f 0 '(7105) #f)
           (sc2-raw-unit-command 1632 #f 0 '(7106) #f)
           (sc2-raw-unit-command 251 #f 7199 '(7107) #f))
     100))
  (define abs-cap3 (cmd-abilities out-cap3))
  (check-true "l73-c2-1a-pre-train-rescue-capped-at-3-no-double-rescue"
              (and (= (length abs-cap3) 3)
                   (equal? abs-cap3 '(1343 1344 1351))
                   (not (memv 1733 abs-cap3))
                   (not (memv 4121 abs-cap3)))
              (format "Expected exactly 3 train/supply cmds '(1343 1344 1351) rescued, got ~a" abs-cap3)))

;; -----------------------------------------------------------------------------
;; 3. Step `1c` (`>= 8`-loop) Isolated Training Rescue Beats P0 Mode Switches
;; -----------------------------------------------------------------------------
(let ()
  (define gov3 (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 485.0 #:burst-capacity 2.0))
  ;; Loop 100: emit TrainMarine (560) -> sets BOTH LAST-P1-LOOP=100 and LAST-P1-TRAIN-LOOP=100 (tokens: 2.0->0.0)
  (void (govern-sc2-wire-actions! gov3 (list (sc2-raw-unit-command 560 #f 0 '(7301) #f)) 100))
  ;; Loop 104: refill = 4*(200/1344) = 0.595t; emit non-training P1 (321 BuildBarracks, no wait, tokens=0.595 < 2.0).
  ;; Use burst=4.0: loop 100 emits 560 (4->2); loop 104 emits 321 (2.595->0.595) setting LAST-P1-LOOP=104 while LAST-P1-TRAIN-LOOP=100!
  (define gov3b (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 485.0 #:burst-capacity 4.0))
  (void (govern-sc2-wire-actions! gov3b (list (sc2-raw-unit-command 560 #f 0 '(7301) #f)) 100))
  (void (govern-sc2-wire-actions! gov3b (list (sc2-raw-unit-command 321 (sc2-point2d 30.0 30.0) 0 '(7302) #f)) 104))
  ;; Loop 108 (+8f since LAST-P1-TRAIN-LOOP=100 -> `1c` fires!; +4f since LAST-P1-LOOP=104 -> general `1c` does NOT fire!):
  ;; Send non-urgent P0 mode switch (388 SiegeMode, floor -1.0) + SupplyDepot (319) + TrainMarine (560).
  ;; Tokens at 108 = ~1.19 -> `1c` (floor -3.0) runs BEFORE `1d` mode switch (388), rescuing 319 & 560!
  (define out-108
    (govern-sc2-wire-actions!
     gov3b
     (list (sc2-raw-unit-command 388 #f 0 '(7310) #f)
           (sc2-raw-unit-command 319 (sc2-point2d 32.0 32.0) 0 '(7311) #f)
           (sc2-raw-unit-command 560 #f 0 '(7312) #f))
     108))
  (define abs-108 (cmd-abilities out-108))
  (check-true "l73-c2-step-1c-8-loop-train-rescue-beats-p0-mode-switch"
              (and (memv 319 abs-108)
                   (memv 560 abs-108)
                   (not (memv 388 abs-108)))
              (format "Expected 319 & 560 rescued at 1c ahead of 388 mode-switch; got ~a" abs-108)))

;; -----------------------------------------------------------------------------
;; 4. Training/Supply Ordering Ahead of Morphs/Tumors in Normal `p1-cmds` Drain
;; -----------------------------------------------------------------------------
(let ()
  ;; Warm BOTH trackers at loop 100 so neither `1a-pre` nor `1c` fires at loop 104!
  ;; With burst-capacity = 6.0 and 1 warm-up cmd at loop 100 (`6.0 -> 4.0`, +~0.6 at loop 104 -> ~4.6 tokens),
  ;; normal `p1-cmds` drain (floor 0.0) can fit EXACTLY 2 commands (4.6 -> 2.6 -> 0.6).
  ;; Input order places 1733 & 4121 FIRST, followed by 881 (Pylon) & 917 (Stalker).
  ;; Partition MUST emit 881 & 917 ahead of 1733 & 4121!
  (define gov4 (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 485.0 #:burst-capacity 6.0))
  (void (govern-sc2-wire-actions! gov4 (list (sc2-raw-unit-command 1006 #f 0 '(7400) #f)) 100))
  (define out-104
    (govern-sc2-wire-actions!
     gov4
     (list (sc2-raw-unit-command 1733 (sc2-point2d 50.0 50.0) 0 '(7401) #f)
           (sc2-raw-unit-command 4121 #f 0 '(7402) #f)
           (sc2-raw-unit-command 881 (sc2-point2d 30.0 30.0) 0 '(7403) #f)
           (sc2-raw-unit-command 917 #f 0 '(7404) #f))
     104))
  (define abs-104 (cmd-abilities out-104))
  (check-true "l73-c2-normal-p1-drain-orders-supply-and-train-ahead-of-tumors-and-morphs"
              (equal? abs-104 '(881 917))
              (format "Expected '(881 917) emitted ahead of 1733/4121 under tight tokens, got ~a" abs-104)))

;; -----------------------------------------------------------------------------
;; 5. Match Rewind Reset Clears `SC2-GOV-LAST-P1-TRAIN-LOOP`
;; -----------------------------------------------------------------------------
(let ()
  (define gov5 (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 485.0 #:burst-capacity 4.0))
  ;; Match 1 at loop 5000: emit TrainDrone (1342) -> LAST-P1-TRAIN-LOOP = 5000
  (void (govern-sc2-wire-actions! gov5 (list (sc2-raw-unit-command 1342 #f 0 '(7501) #f)) 5000))
  ;; Rewind to Match 2 loop 100: resets LAST-P1-TRAIN-LOOP -> -1000 & tokens -> 4.0;
  ;; Drain tokens on Creep Tumor + P0 spells at loop 100 & 104 (keeping LAST-P1-LOOP = 104, LAST-P1-TRAIN-LOOP = -1000!),
  ;; then at loop 108 (dt since LAST-P1-LOOP = 4 < 12, dt since reset LAST-P1-TRAIN-LOOP = 1108 >= 12),
  ;; TrainOverlord (1344) MUST rescue in `1a-pre`! (If LAST-P1-TRAIN-LOOP stayed 5000, `108 - 5000 = -4892 < 12` would FAIL!)
  (void (govern-sc2-wire-actions!
         gov5
         (list (sc2-raw-unit-command 1733 (sc2-point2d 40.0 40.0) 0 '(7502) #f)
               (sc2-raw-unit-command 251 #f 7590 '(7503) #f)
               (sc2-raw-unit-command 1664 #f 7591 '(7504) #f))
         100))
  (void (govern-sc2-wire-actions!
         gov5
         (list (sc2-raw-unit-command 1733 (sc2-point2d 42.0 40.0) 0 '(7505) #f)
               (sc2-raw-unit-command 251 #f 7590 '(7506) #f))
         104))
  (define out-rewind
    (govern-sc2-wire-actions!
     gov5
     (list (sc2-raw-unit-command 1733 (sc2-point2d 44.0 40.0) 0 '(7507) #f)
           (sc2-raw-unit-command 1344 #f 0 '(7508) #f)
           (sc2-raw-unit-command 251 #f 7590 '(7509) #f))
     108))
  (define abs-rewind (cmd-abilities out-rewind))
  (check-true "l73-c2-match-rewind-resets-last-p1-train-loop"
              (and (memv 1344 abs-rewind)
                   (= (first abs-rewind) 1344))
              (format "Expected 1344 rescued first after match rewind; got ~a" abs-rewind)))

;; -----------------------------------------------------------------------------
;; 6. Multi-Prong P2 & Large-Squad Anti-Starvation Preserved Under New P1 Partition
;; -----------------------------------------------------------------------------
(let ()
  (define prong-a (sc2-raw-unit-command 23 (sc2-point2d 140.0 40.0) 0 (for/list ([i (in-range 10)]) (+ 7600 i)) #f))
  (define prong-b (sc2-raw-unit-command 23 (sc2-point2d 40.0 140.0) 0 (for/list ([i (in-range 4)]) (+ 7620 i)) #f))
  (define gov6 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0 #:burst-capacity 3.5))
  (void (govern-sc2-wire-actions! gov6 (list (sc2-raw-unit-command 1343 #f 0 '(7639) #f)) 196))
  (define p1-noise (for/list ([i (in-range 4)]) (sc2-raw-unit-command 1343 #f 0 (list (+ 7640 i)) #f)))
  (define out6 (govern-sc2-wire-actions! gov6 (append p1-noise (list prong-a prong-b)) 200))
  (define out6-23 (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) out6))
  (check-true "l73-c2-two-prong-p2-preserved-with-coalesced-larva-p1-noise"
              (= (length out6-23) 2)
              (format "Expected both 23 prongs emitted, got ~a" out6)))

(printf "l73-wire-governor-test: ~a/~a passed\n" (- tests-run tests-failed) tests-run)
(when (> tests-failed 0)
  (exit 1))
