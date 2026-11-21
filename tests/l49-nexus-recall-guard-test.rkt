#lang racket/base

;; =============================================================================
;; Loop 49 Wave 2: `nexus-recall-save` Fresh-Squad & Stealth-Snipe Guard Tests
;; (`tests/l49-nexus-recall-guard-test.rkt`)
;;
;; Verifies `#1169` Fix #1 / `#1171` Track 3 in
;; `lib/plan/map-elements-and-experiments.rkt`:
;;   1. Stealth-snipe squad (`>= 2` DTs + `>= 2` anti-detector allies vs `<= 3`
;;      mobile detectors `overseer`/`observer`/`raven`, `0` static detectors)
;;      MUST NOT trigger premature `nexus-recall-save` (even when DTs stage back
;;      `13t` or take partial damage).
;;   2. Fresh, unhurt non-stealth squad (`avg hp+shield ratio >= 0.78`) facing
;;      non-catastrophic `1.5x..2.75x` enemy power MUST NOT prematurely recall.
;;   3. Hurt squad (`avg hp+shield ratio < 0.78`) facing `> 1.5x` enemy power
;;      MUST still fire `nexus-recall-save`.
;;   4. Stealth-snipe squad with anti-detectors lost (`< 2`) and hurt (`< 0.78`)
;;      or facing `>= 4` mobile detectors MUST still fire `nexus-recall-save`.
;;   5. Preservation (`L46-T1a`): `0` detectors -> no recall; `5` detected DTs
;;      (w/ Turret) or `5` Zealots facing catastrophic `>= 2.8x` ambush -> recall.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/plan/map-elements-and-experiments.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (mk-u tag sym x y #:hp [hp 100.0] #:max-hp [max-hp #f]
              #:shield [sh 0.0] #:max-shield [max-sh #f]
              #:energy [en 0.0] #:cloak [clk 0] #:cloaked? [cloaked? #f])
  (define h
    (hasheq 'id tag 'type sym 'x x 'y y 'hp hp 'shield sh
            'energy en 'cloak clk 'cloaked cloaked? 'build-progress 1.0))
  (define h1 (if max-hp (hash-set h 'max-hp max-hp) h))
  (if max-sh (hash-set h1 'max-shield max-sh) h1))

(define (has-recall? dirs)
  (not (not (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'nexus-recall-save)) dirs))))

(define home-nexus (mk-u 100 'nexus 32.0 138.0 #:hp 1000.0 #:shield 1000.0 #:energy 100.0))

;; (1) d04 exact repro: 4 DTs staged back + 4 Stalkers + 4 Phoenixes vs 12 Roaches + 3 Ravagers + 2 Overseers
;;     (even when DTs are > 12t from forward centroid so local `e-pow > 1.5 * a-pow` AND even if slightly hurt!)
(define d04-allies
  (append
   (for/list ([i (in-range 4)])
     (mk-u (+ 201 i) 'dark-templar 72.0 (+ 86.0 (* 0.5 i)) #:hp 45.0 #:shield 80.0 #:cloak 2 #:cloaked? #t))
   (for/list ([i (in-range 4)])
     (mk-u (+ 211 i) 'stalker 85.0 (+ 86.0 (* 0.5 i)) #:hp 80.0 #:shield 70.0))
   (for/list ([i (in-range 4)])
     (mk-u (+ 221 i) 'phoenix 86.0 (+ 86.0 (* 0.5 i)) #:hp 120.0 #:shield 50.0))))
(define d04-enemies
  (append
   (for/list ([i (in-range 12)])
     (mk-u (+ 8001 i) 'roach 91.0 (+ 84.0 (* 0.6 i)) #:hp 145.0))
   (for/list ([i (in-range 3)])
     (mk-u (+ 8050 i) 'ravager 92.5 (+ 86.0 (* 0.8 i)) #:hp 120.0))
   (for/list ([i (in-range 2)])
     (mk-u (+ 8080 i) 'overseer 91.5 (+ 87.0 (* 1.0 i)) #:hp 200.0))))
(define dirs-d04
  (plan-warp-prism-and-recall-tactics
   d04-allies (list home-nexus) d04-enemies
   #:frame 100 #:home-x 32.0 #:home-y 138.0 #:enemy-x 92.0 #:enemy-y 88.0))
(check! (not (has-recall? dirs-d04))
        (format "L49-Recall(1) d04 stealth-snipe squad (4 DT + 4 Stalker + 4 Phoenix vs 2 Overseers) MUST NOT recall: dirs=~a"
                dirs-d04))

;; (2) Stealth-snipe squad vs 3 Ravens + heavy Bio/Tank (even when hurt < 0.78!) MUST NOT recall while sniping <= 3 mobile detectors
(define d05-allies-hurt
  (append
   (for/list ([i (in-range 2)])
     (mk-u (+ 301 i) 'dark-templar 80.0 (+ 87.0 (* 0.5 i)) #:hp 40.0 #:shield 20.0 #:cloak 2 #:cloaked? #t))
   (for/list ([i (in-range 2)])
     (mk-u (+ 311 i) 'phoenix 82.0 (+ 87.0 (* 0.5 i)) #:hp 80.0 #:shield 10.0))))
(define d05-enemies
  (append
   (for/list ([i (in-range 16)])
     (mk-u (+ 8201 i) 'marine 86.0 (+ 85.0 (* 0.4 i)) #:hp 45.0))
   (for/list ([i (in-range 3)])
     (mk-u (+ 8250 i) 'raven 87.0 (+ 86.0 (* 1.0 i)) #:hp 140.0))))
(define dirs-d05
  (plan-warp-prism-and-recall-tactics
   d05-allies-hurt (list home-nexus) d05-enemies
   #:frame 200 #:home-x 32.0 #:home-y 138.0 #:enemy-x 87.0 #:enemy-y 88.0))
(check! (not (has-recall? dirs-d05))
        (format "L49-Recall(2) Stealth-snipe squad (2 DT + 2 Phoenix vs 3 Ravens) MUST NOT recall: dirs=~a"
                dirs-d05))

;; (3) Fresh unhurt non-stealth squad (`avg hp+shield ratio = 0.90 >= 0.78`) facing ~1.8x enemy power (< 2.8x):
;;     MUST NOT prematurely recall!
(define fresh-stalkers
  (for/list ([i (in-range 4)])
    (mk-u (+ 401 i) 'stalker 82.0 (+ 87.0 (* 0.5 i)) #:hp 80.0 #:max-hp 80.0 #:shield 64.0 #:max-shield 80.0)))
(define roaches-9
  (for/list ([i (in-range 9)])
    (mk-u (+ 8401 i) 'roach 88.0 (+ 85.0 (* 0.6 i)) #:hp 145.0)))
(define dirs-fresh
  (plan-warp-prism-and-recall-tactics
   fresh-stalkers (list home-nexus) roaches-9
   #:frame 400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 88.0 #:enemy-y 88.0))
(check! (not (has-recall? dirs-fresh))
        (format "L49-Recall(3) Fresh unhurt squad (avg ratio 0.90 >= 0.78) at 1.8x enemy power MUST NOT recall: dirs=~a"
                dirs-fresh))

;; (4) Hurt non-stealth squad (`avg hp+shield ratio = 0.44 < 0.78`) facing same ~1.8x enemy power:
;;     MUST recall cleanly to save the wounded squad!
(define hurt-stalkers
  (for/list ([i (in-range 4)])
    (mk-u (+ 451 i) 'stalker 82.0 (+ 87.0 (* 0.5 i)) #:hp 60.0 #:max-hp 80.0 #:shield 10.0 #:max-shield 80.0)))
(define dirs-hurt
  (plan-warp-prism-and-recall-tactics
   hurt-stalkers (list home-nexus) roaches-9
   #:frame 400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 88.0 #:enemy-y 88.0))
(check! (has-recall? dirs-hurt)
        (format "L49-Recall(4) Hurt squad (avg ratio 0.44 < 0.78) overwhelmed >1.5x MUST fire nexus-recall-save: dirs=~a"
                dirs-hurt))

;; (5) Negative guard: Stealth squad with anti-detectors wiped (<2) & hurt (<0.78) vs 2 Overseers + 12 Roaches:
;;     MUST fire nexus-recall-save!
(define broken-snipe-allies
  (list
   (mk-u 501 'dark-templar 82.0 87.0 #:hp 30.0 #:max-hp 45.0 #:shield 10.0 #:max-shield 80.0 #:cloak 2 #:cloaked? #t)
   (mk-u 502 'dark-templar 82.5 87.5 #:hp 30.0 #:max-hp 45.0 #:shield 10.0 #:max-shield 80.0 #:cloak 2 #:cloaked? #t)
   (mk-u 503 'phoenix 83.0 87.0 #:hp 60.0 #:max-hp 120.0 #:shield 0.0 #:max-shield 60.0)))
(define dirs-broken-snipe
  (plan-warp-prism-and-recall-tactics
   broken-snipe-allies (list home-nexus) d04-enemies
   #:frame 500 #:home-x 32.0 #:home-y 138.0 #:enemy-x 92.0 #:enemy-y 88.0))
(check! (has-recall? dirs-broken-snipe)
        (format "L49-Recall(5) Hurt DT squad with <2 anti-detector allies vs 2 Overseers MUST recall: dirs=~a"
                dirs-broken-snipe))

;; (6) L46-T1a preservation: 0 detectors -> no recall; 5 detected DTs (w/ Turret) or 5 Zealots vs 38 Terran (>= 2.8x) -> recall!
(define dts-5
  (for/list ([i (in-range 5)])
    (mk-u (+ 601 i) 'dark-templar (+ 80.0 (* 0.5 i)) 88.0 #:hp 40.0 #:shield 80.0 #:cloaked? #t #:cloak 1)))
(define zealots-5
  (for/list ([i (in-range 5)])
    (mk-u (+ 651 i) 'zealot (+ 80.0 (* 0.5 i)) 88.0 #:hp 100.0 #:shield 50.0)))
(define terran-38
  (append
   (for/list ([i (in-range 24)])
     (mk-u (+ 8601 i) 'marine (+ 82.0 (* 0.4 (modulo i 6))) (+ 86.0 (* 0.5 (quotient i 6))) #:hp 55.0))
   (for/list ([i (in-range 8)])
     (mk-u (+ 8650 i) 'marauder (+ 83.0 (* 0.4 i)) 89.0 #:hp 125.0))
   (for/list ([i (in-range 6)])
     (mk-u (+ 8680 i) 'siege-tank-sieged (+ 85.0 (* 0.6 i)) 88.0 #:hp 175.0))))
(define turret-near (mk-u 8901 'missile-turret 84.0 88.0 #:hp 250.0))
(define dirs-p15-nodet
  (plan-warp-prism-and-recall-tactics
   dts-5 (list home-nexus) terran-38
   #:frame 1400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 84.0 #:enemy-y 88.0 #:enemy-buildings '()))
(define dirs-p15-turret
  (plan-warp-prism-and-recall-tactics
   dts-5 (list home-nexus) terran-38
   #:frame 1400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 84.0 #:enemy-y 88.0 #:enemy-buildings (list turret-near)))
(define dirs-l46-zealots
  (plan-warp-prism-and-recall-tactics
   zealots-5 (list home-nexus) terran-38
   #:frame 1400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 84.0 #:enemy-y 88.0))
(check! (and (not (has-recall? dirs-p15-nodet))
             (has-recall? dirs-p15-turret)
             (has-recall? dirs-l46-zealots))
        (format "L49-Recall(6) L46-T1a preservation failed: nodet=~a turret=~a zealots=~a"
                (has-recall? dirs-p15-nodet)
                (has-recall? dirs-p15-turret)
                (has-recall? dirs-l46-zealots)))

(printf "l49-nexus-recall-guard-test: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
