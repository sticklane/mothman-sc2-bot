#lang racket/base

;; =============================================================================
;; Loop 84 Version C Proxy Wire Codec & Worker Saturation Exclusion Tests
;; Covers `lib/sc2-protobuf-ws.rkt`:
;;   1. `(build-proxy <bldg> <px> <py> [worker-tag])` Protoss power isolation:
;;      - NEVER snaps back to Main Pylons when no completed Pylon/WarpPrism is
;;        within `<= 14.0t` of `(px, py)`
;;      - Bypasses `fragile-tech-main-protect?`, wall slots, & home anchoring
;;        once a completed proxy Pylon exists within `<= 14.0t`
;;      - Preserves normal `(build ...)` `fragile-tech-main-protect?` behavior
;;   2. Explicit `worker-tag` dispatch, same-tick home-build theft guard,
;;      busy-worker local-only fallback, & omitted/dead-worker closest fallback
;;   3. Terran proxy Barracks/Factory/Starport `#:require-addon-clear? #t`
;;   4. Terran proxy add-ons (`barracks-tech-lab` / `barracks-reactor`) via
;;      BOTH `(build-proxy ...)` AND `(build <addon> px py)`
;;   5. Zerg proxy Hatchery (even at an expansion mineral cluster) & proxy Nydus Worm (`1768`)
;;   6. `saturate-workers-and-gas-commands` `#:exclude-worker-tags` (`set`,
;;      `list`, `mutable-seteqv`) + union with legacy `#:excluded-worker-tags`
;;   7. Action validation & zero wire rejects for valid `build-proxy` forms
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/sc2-protobuf-ws.rkt")

(define tests-run 0)
(define tests-failed 0)

(define (check-true label pred [detail ""])
  (set! tests-run (add1 tests-run))
  (unless pred
    (set! tests-failed (add1 tests-failed))
    (eprintf "  [FAIL] ~a~a\n" label (if (string=? detail "") "" (format " (~a)" detail)))))

(define (check-eqv label actual expected)
  (set! tests-run (add1 tests-run))
  (unless (equal? actual expected)
    (set! tests-failed (add1 tests-failed))
    (eprintf "  [FAIL] ~a: expected ~s, got ~s\n" label expected actual)))

(define (pt-d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-unit tag utype x y
                 #:alliance [alliance 1]
                 #:owner [owner 1]
                 #:progress [progress 1.0]
                 #:radius [radius 1.0]
                 #:hp [hp 100.0]
                 #:orders [orders '()]
                 #:add-on-tag [add-on-tag 0]
                 #:minerals [minerals 0]
                 #:vespene [vespene 0]
                 #:assigned [assigned 0]
                 #:ideal [ideal 0]
                 #:powered [powered #t])
  (sc2-unit 1 alliance tag utype owner
            (sc2-point3d (exact->inexact x) (exact->inexact y) 10.0)
            0.0 (exact->inexact radius) (exact->inexact progress)
            0 #f #t #f (exact->inexact hp) (exact->inexact hp)
            0.0 0.0 0.0 0.0
            minerals vespene #f #f #f powered #f
            orders add-on-tag '()
            assigned ideal 0.0 0 0 0 0))

(define (mk-obs loop units
                #:minerals [minerals 400]
                #:vespene [vespene 200]
                #:power-sources [power-sources '()])
  (sc2-observation
   loop
   (sc2-player-common 1 minerals vespene 30 16 0 12 0 0 0 0)
   units
   '()
   power-sources
   (sc2-point3d 30.0 30.0 10.0)
   '() '() '() '() '() '()))

(define (mk-open-game-info [w 160] [h 160])
  (define grid-bytes (make-bytes (* w h) 1))
  (define grid (sc2-image-grid 8 w h grid-bytes #f #t))
  (sc2-game-info
   "TestProxyArena"
   "TestProxyArena.SC2Map"
   '()
   (sc2-point2d (exact->inexact w) (exact->inexact h))
   (list (sc2-point2d 0.0 0.0) (sc2-point2d (exact->inexact w) (exact->inexact h)))
   (list (sc2-point2d 130.0 130.0))
   grid
   #f
   grid))

(define open-gi (mk-open-game-info))

(define (xlat obs actions)
  (filter sc2-raw-unit-command?
          (translate-bot-actions->sc2-raw-commands actions obs #:ws-conn #f #:game-info open-gi)))

(define (cmd-tags cmds)
  (apply append
         (for/list ([c (in-list cmds)] #:when (sc2-raw-unit-command? c))
           (sc2-raw-unit-command-unit-tags c))))

(printf "=================================================================\n")
(printf "SUITE: Loop 84 Proxy Wire Codec & Worker Exclusion Tests\n")
(printf "=================================================================\n")

;; -----------------------------------------------------------------------------
;; 1. Protoss Proxy Power Isolation & Bypass of fragile-tech-main-protect?
;; -----------------------------------------------------------------------------
(printf "[1/7] Protoss proxy power isolation & fragile-tech bypass...\n")
(let ()
  (define main-nexus (mk-unit 4001 59 30.0 30.0 #:radius 2.5 #:hp 1000.0))
  (define main-pylon (mk-unit 4002 60 34.0 30.0 #:radius 1.0 #:hp 200.0))
  (define home-probe (mk-unit 4100 84 32.0 30.0 #:radius 0.375 #:hp 20.0))
  (define proxy-probe (mk-unit 4101 84 115.0 113.0 #:radius 0.375 #:hp 20.0))
  (define main-ps (sc2-power-source (sc2-point3d 34.0 30.0 10.0) 6.5 4002))

  ;; (a) ZERO Pylons within 14t of proxy (115, 115): MUST emit 0 commands (NEVER snap to Main!)
  (define obs-no-proxy-pylon
    (mk-obs 1200 (list main-nexus main-pylon home-probe proxy-probe)
            #:power-sources (list main-ps)))
  (for ([bldg (in-list '(gateway robotics-facility stargate photon-cannon shield-battery))])
    (define cmds (xlat obs-no-proxy-pylon (list (list 'build-proxy bldg 115.0 115.0 4101))))
    (check-eqv (format "l84-proxy-no-pylon-emits-0-~a" bldg) (length cmds) 0)
    (check-eqv (format "l84-proxy-no-pylon-zero-rejects-~a" bldg)
               (length (get-last-bot-action-rejects)) 0))

  ;; (b) Incomplete proxy Pylon (progress = 0.65) at (115, 115): STILL 0 commands!
  (define inc-proxy-pylon (mk-unit 4003 60 115.0 115.0 #:progress 0.65 #:radius 1.0))
  (define obs-inc-pylon
    (mk-obs 1216 (list main-nexus main-pylon inc-proxy-pylon home-probe proxy-probe)
            #:power-sources (list main-ps)))
  (define cmds-inc
    (xlat obs-inc-pylon (list (list 'build-proxy 'robotics-facility 115.0 115.0 4101))))
  (check-eqv "l84-proxy-incomplete-pylon-waits" (length cmds-inc) 0)

  ;; (c) Completed proxy Pylon at (115, 115): Robotics Facility, Stargate, Gateway, Cannon land at proxy!
  (define comp-proxy-pylon (mk-unit 4003 60 115.0 115.0 #:progress 1.0 #:radius 1.0))
  (define proxy-ps (sc2-power-source (sc2-point3d 115.0 115.0 10.0) 6.5 4003))
  (define obs-ready-proxy
    (mk-obs 1248 (list main-nexus main-pylon comp-proxy-pylon home-probe proxy-probe)
            #:power-sources (list main-ps proxy-ps)))
  (for ([spec (in-list '((robotics-facility 893)
                         (stargate 889)
                         (gateway 883)
                         (photon-cannon 887)))]
        [idx (in-naturals 0)])
    (define bsym (first spec))
    (define exp-ab (second spec))
    (define obs-i
      (mk-obs (+ 1248 (* idx 100))
              (list main-nexus main-pylon comp-proxy-pylon home-probe proxy-probe)
              #:power-sources (list main-ps proxy-ps)))
    (define cmds (xlat obs-i (list (list 'build-proxy bsym 115.0 115.0 4101))))
    (check-eqv (format "l84-proxy-powered-emits-1-~a" bsym) (length cmds) 1)
    (when (= (length cmds) 1)
      (define c (first cmds))
      (define pt (sc2-raw-unit-command-target-pos c))
      (check-eqv (format "l84-proxy-powered-ab-~a" bsym) (sc2-raw-unit-command-ability-id c) exp-ab)
      (check-eqv (format "l84-proxy-powered-worker-~a" bsym) (sc2-raw-unit-command-unit-tags c) '(4101))
      (check-true (format "l84-proxy-powered-lands-at-proxy-~a" bsym)
                  (and (sc2-point2d? pt)
                       (<= (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 115.0 115.0) 6.5)
                       (> (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 30.0 30.0) 80.0))
                  (format "pt=~a" pt)))
    (check-eqv (format "l84-proxy-powered-zero-rejects-~a" bsym)
               (length (get-last-bot-action-rejects)) 0))

  ;; (d) Normal `(build 'robotics-facility 115.0 115.0)` STILL protected at Main (`fragile-tech-main-protect?`)!
  (define obs-normal-robo
    (mk-obs 1700 (list main-nexus main-pylon comp-proxy-pylon home-probe proxy-probe)
            #:power-sources (list main-ps proxy-ps)))
  (define cmds-normal-robo
    (xlat obs-normal-robo (list (list 'build 'robotics-facility 115.0 115.0))))
  (check-eqv "l84-normal-build-robo-still-emits-1" (length cmds-normal-robo) 1)
  (when (= (length cmds-normal-robo) 1)
    (define pt (sc2-raw-unit-command-target-pos (first cmds-normal-robo)))
    (check-true "l84-normal-build-robo-still-protected-at-main"
                (and (sc2-point2d? pt)
                     (<= (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 34.0 30.0) 12.0))
                (format "pt=~a" pt)))

  ;; (e) Loop 84B: Proxy Pylon at 18.0t (in 16..19t band, <= 20.0t) ACCEPTED for Cannon/Gateway,
  ;;     while Proxy Pylon at 25.0t (> 20.0t) + Main Pylon are STILL rejected!
  (define mid-proxy-pylon (mk-unit 4004 60 133.0 115.0 #:progress 1.0 #:radius 1.0))
  (define mid-proxy-ps (sc2-power-source (sc2-point3d 133.0 115.0 10.0) 6.5 4004))
  (for ([spec (in-list '((photon-cannon 887) (gateway 883)))]
        [idx (in-naturals 0)])
    (define bsym (first spec))
    (define exp-ab (second spec))
    (define obs-18t
      (mk-obs (+ 1800 (* idx 60))
              (list main-nexus main-pylon mid-proxy-pylon home-probe proxy-probe)
              #:power-sources (list main-ps mid-proxy-ps)))
    (define cmds-18t (xlat obs-18t (list (list 'build-proxy bsym 115.0 115.0 4101))))
    (check-eqv (format "l84b-proxy-18t-pylon-emits-1-~a" bsym) (length cmds-18t) 1)
    (when (= (length cmds-18t) 1)
      (define c (first cmds-18t))
      (define pt (sc2-raw-unit-command-target-pos c))
      (check-eqv (format "l84b-proxy-18t-pylon-ab-~a" bsym) (sc2-raw-unit-command-ability-id c) exp-ab)
      (check-eqv (format "l84b-proxy-18t-pylon-worker-~a" bsym) (sc2-raw-unit-command-unit-tags c) '(4101))
      (check-true (format "l84b-proxy-18t-pylon-powered-at-proxy-~a" bsym)
                  (and (sc2-point2d? pt)
                       (<= (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 133.0 115.0) 6.5)
                       (> (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 34.0 30.0) 90.0))
                  (format "pt=~a" pt))))
  (define far-proxy-pylon (mk-unit 4005 60 140.0 115.0 #:progress 1.0 #:radius 1.0))
  (define far-proxy-ps (sc2-power-source (sc2-point3d 140.0 115.0 10.0) 6.5 4005))
  (define obs-25t
    (mk-obs 1920 (list main-nexus main-pylon far-proxy-pylon home-probe proxy-probe)
            #:power-sources (list main-ps far-proxy-ps)))
  (define cmds-25t (xlat obs-25t (list (list 'build-proxy 'photon-cannon 115.0 115.0 4101))))
  (check-eqv "l84b-proxy-25t-and-main-pylon-still-rejected" (length cmds-25t) 0))

;; -----------------------------------------------------------------------------
;; 2. Explicit worker-tag Dispatch, Same-Tick Guard, Busy & Fallback Semantics
;; -----------------------------------------------------------------------------
(printf "[2/7] Explicit worker-tag dispatch, theft protection, & fallback...\n")
(let ()
  (define main-nexus (mk-unit 4201 59 30.0 30.0 #:radius 2.5 #:hp 1000.0))
  (define home-probe (mk-unit 4210 84 32.0 30.0 #:radius 0.375 #:hp 20.0))
  (define proxy-probe-a (mk-unit 4211 84 110.0 110.0 #:radius 0.375 #:hp 20.0))
  (define proxy-probe-b (mk-unit 4212 84 114.5 115.0 #:radius 0.375 #:hp 20.0))
  (define obs (mk-obs 2000 (list main-nexus home-probe proxy-probe-a proxy-probe-b)))

  ;; (a) Explicit worker tag 4211 wins even though 4212 is closer to (115, 115)!
  (define cmds-explicit (xlat obs (list (list 'build-proxy 'pylon 115.0 115.0 4211))))
  (check-eqv "l84-explicit-worker-emits-1" (length cmds-explicit) 1)
  (when (= (length cmds-explicit) 1)
    (check-eqv "l84-explicit-worker-tag-4211"
               (sc2-raw-unit-command-unit-tags (first cmds-explicit)) '(4211)))

  ;; (b) Same-tick `(build 'pylon 34 30)` + `(build-proxy 'pylon 115 115 4211)`:
  ;;     even when 4211 is closer to home than another unit, home build MUST NOT steal 4211!
  (define proxy-near-home (mk-unit 4211 84 31.0 30.0 #:radius 0.375 #:hp 20.0))
  (define home-probe-farther (mk-unit 4210 84 36.0 30.0 #:radius 0.375 #:hp 20.0))
  (define obs-theft
    (mk-obs 2100 (list main-nexus home-probe-farther proxy-near-home)))
  (define cmds-both
    (xlat obs-theft
          (list (list 'build 'pylon 34.0 30.0)
                (list 'build-proxy 'pylon 115.0 115.0 4211))))
  (check-eqv "l84-same-tick-home-plus-proxy-emits-2" (length cmds-both) 2)
  (when (= (length cmds-both) 2)
    (check-eqv "l84-home-build-does-not-steal-proxy-worker"
               (sc2-raw-unit-command-unit-tags (first cmds-both)) '(4210))
    (check-eqv "l84-proxy-build-keeps-locked-worker-4211"
               (sc2-raw-unit-command-unit-tags (second cmds-both)) '(4211)))

  ;; (c) 4-arg omitted worker tag & dead worker tag fall back to closest eligible worker (4212)!
  (define obs-omit (mk-obs 2200 (list main-nexus home-probe proxy-probe-a proxy-probe-b)))
  (define cmds-omit (xlat obs-omit (list (list 'build-proxy 'pylon 115.0 115.0))))
  (check-eqv "l84-omitted-worker-picks-closest-4212"
             (and (= (length cmds-omit) 1)
                  (sc2-raw-unit-command-unit-tags (first cmds-omit)))
             '(4212))
  (define obs-dead (mk-obs 2300 (list main-nexus home-probe proxy-probe-a proxy-probe-b)))
  (define cmds-dead (xlat obs-dead (list (list 'build-proxy 'pylon 115.0 115.0 999999))))
  (check-eqv "l84-dead-worker-picks-closest-4212"
             (and (= (length cmds-dead) 1)
                  (sc2-raw-unit-command-unit-tags (first cmds-dead)))
             '(4212))

  ;; (d) Alive but busy explicit worker: substitutes nearby 4212 (<= 24t), NEVER pulls distant 4210!
  (define busy-probe-a
    (mk-unit 4211 84 114.0 114.0 #:radius 0.375 #:hp 20.0
             #:orders (list (sc2-unit-order 881 (sc2-point3d 114.0 114.0 10.0) 0 0.0))))
  (define obs-busy-with-partner
    (mk-obs 2400 (list main-nexus home-probe busy-probe-a proxy-probe-b)))
  (define cmds-busy-partner
    (xlat obs-busy-with-partner (list (list 'build-proxy 'pylon 115.0 115.0 4211))))
  (check-eqv "l84-busy-proxy-worker-uses-nearby-partner-4212"
             (and (= (length cmds-busy-partner) 1)
                  (sc2-raw-unit-command-unit-tags (first cmds-busy-partner)))
             '(4212))
  (define obs-busy-solo
    (mk-obs 2500 (list main-nexus home-probe busy-probe-a)))
  (define cmds-busy-solo
    (xlat obs-busy-solo (list (list 'build-proxy 'pylon 115.0 115.0 4211))))
  (check-eqv "l84-busy-proxy-worker-never-pulls-distant-home-worker"
             (length cmds-busy-solo) 0))

;; -----------------------------------------------------------------------------
;; 3. Terran Proxy Barracks/Factory/Starport #:require-addon-clear? #t
;; -----------------------------------------------------------------------------
(printf "[3/7] Terran proxy production East add-on slot clearance...\n")
(let ()
  (define main-cc (mk-unit 5001 18 30.0 30.0 #:radius 2.75 #:hp 1500.0))
  (define home-scv (mk-unit 5100 45 33.0 30.0 #:radius 0.375 #:hp 45.0))
  (define proxy-scv (mk-unit 5101 45 110.0 45.0 #:radius 0.375 #:hp 45.0))
  ;; Place a blocking bunker RIGHT on the East add-on slot (112.5, 44.5) of (110, 45)!
  (define east-blocker (mk-unit 5099 24 112.5 44.5 #:radius 1.5 #:hp 400.0))
  (define obs-terran
    (mk-obs 1600 (list main-cc home-scv proxy-scv east-blocker)))

  (for ([spec (in-list '((barracks 321) (factory 328) (starport 329)))]
        [idx (in-naturals 0)])
    (define bsym (first spec))
    (define exp-ab (second spec))
    (define obs-t (mk-obs (+ 3000 (* idx 100)) (list main-cc home-scv proxy-scv east-blocker)))
    (define cmds (xlat obs-t (list (list 'build-proxy bsym 110.0 45.0 5101))))
    (check-eqv (format "l84-terran-proxy-~a-emits-1" bsym) (length cmds) 1)
    (when (= (length cmds) 1)
      (define c (first cmds))
      (define pt (sc2-raw-unit-command-target-pos c))
      (define bx (sc2-point2d-x pt))
      (define by (sc2-point2d-y pt))
      (define ax (+ bx 2.5))
      (define ay (- by 0.5))
      (check-eqv (format "l84-terran-proxy-~a-ab" bsym) (sc2-raw-unit-command-ability-id c) exp-ab)
      (check-eqv (format "l84-terran-proxy-~a-worker" bsym) (sc2-raw-unit-command-unit-tags c) '(5101))
      (check-true (format "l84-terran-proxy-~a-near-proxy" bsym)
                  (<= (pt-d bx by 110.0 45.0) 10.0)
                  (format "pt=(~a,~a)" bx by))
      (check-true (format "l84-terran-proxy-~a-east-addon-slot-clear" bsym)
                  (not (and (< (abs (- ax 112.5)) 1.95)
                            (< (abs (- ay 44.5)) 1.95)))
                  (format "pt=(~a,~a) addon=(~a,~a)" bx by ax ay)))))

;; -----------------------------------------------------------------------------
;; 4. Terran Proxy Add-ons via BOTH `(build-proxy ...)` AND `(build ... px py)`
;; -----------------------------------------------------------------------------
(printf "[4/7] Terran proxy add-ons (barracks-tech-lab / barracks-reactor)...\n")
(let ()
  (define main-cc (mk-unit 6000 18 30.0 30.0 #:radius 2.75 #:hp 1500.0))
  (define home-rax (mk-unit 6001 21 36.0 30.0 #:radius 1.5 #:hp 1000.0))
  (define proxy-rax (mk-unit 6002 21 115.0 45.0 #:radius 1.5 #:hp 1000.0))
  (define obs-addons (mk-obs 4000 (list main-cc home-rax proxy-rax)))

  ;; (a) `(build-proxy 'barracks-tech-lab 115.0 45.0)` attaches to proxy Rax 6002 (NOT home Rax 6001)
  (define cmds-tl (xlat obs-addons (list (list 'build-proxy 'barracks-tech-lab 115.0 45.0))))
  (check-eqv "l84-proxy-addon-techlab-emits-1" (length cmds-tl) 1)
  (when (= (length cmds-tl) 1)
    (check-eqv "l84-proxy-addon-techlab-ab" (sc2-raw-unit-command-ability-id (first cmds-tl)) 421)
    (check-eqv "l84-proxy-addon-techlab-picks-proxy-rax-6002"
               (sc2-raw-unit-command-unit-tags (first cmds-tl)) '(6002)))

  ;; (b) `(build-proxy 'barracks-reactor 115.0 45.0)` attaches to proxy Rax 6002
  (define obs-addons-2 (mk-obs 4100 (list main-cc home-rax proxy-rax)))
  (define cmds-rx (xlat obs-addons-2 (list (list 'build-proxy 'barracks-reactor 115.0 45.0))))
  (check-eqv "l84-proxy-addon-reactor-emits-1" (length cmds-rx) 1)
  (when (= (length cmds-rx) 1)
    (check-eqv "l84-proxy-addon-reactor-ab" (sc2-raw-unit-command-ability-id (first cmds-rx)) 422)
    (check-eqv "l84-proxy-addon-reactor-picks-proxy-rax-6002"
               (sc2-raw-unit-command-unit-tags (first cmds-rx)) '(6002)))

  ;; (c) When NO proxy Rax exists near (115, 45), `(build-proxy 'barracks-tech-lab 115 45)` emits 0!
  (define obs-home-only (mk-obs 4200 (list main-cc home-rax)))
  (define cmds-home-only
    (xlat obs-home-only (list (list 'build-proxy 'barracks-tech-lab 115.0 45.0))))
  (check-eqv "l84-proxy-addon-never-attaches-to-distant-home-rax" (length cmds-home-only) 0)

  ;; (d) Standard `(build 'barracks-tech-lab 115.0 45.0)` ALSO prefers proxy Rax 6002 near (115, 45)!
  (define obs-addons-std (mk-obs 4300 (list main-cc home-rax proxy-rax)))
  (define cmds-std (xlat obs-addons-std (list (list 'build 'barracks-tech-lab 115.0 45.0))))
  (check-eqv "l84-std-build-addon-with-proxy-xy-emits-1" (length cmds-std) 1)
  (when (= (length cmds-std) 1)
    (check-eqv "l84-std-build-addon-with-proxy-xy-picks-proxy-rax-6002"
               (sc2-raw-unit-command-unit-tags (first cmds-std)) '(6002))))

;; -----------------------------------------------------------------------------
;; 5. Zerg Proxy Hatchery & Proxy Nydus Worm
;; -----------------------------------------------------------------------------
(printf "[5/7] Zerg proxy Hatchery & proxy Nydus Worm...\n")
(let ()
  (define main-hatch (mk-unit 7001 86 30.0 30.0 #:radius 2.5 #:hp 1500.0))
  (define proxy-drone (mk-unit 7101 104 120.0 118.0 #:radius 0.375 #:hp 40.0))
  (define nydus-net (mk-unit 7201 95 36.0 32.0 #:radius 1.5 #:hp 850.0))
  ;; Mineral cluster near (120, 120) so expansion pad is inferred there
  (define exp-m1 (mk-unit 7301 341 126.0 118.0 #:alliance 3 #:owner 0 #:minerals 1800))
  (define exp-m2 (mk-unit 7302 341 126.0 120.0 #:alliance 3 #:owner 0 #:minerals 1800))
  (define exp-m3 (mk-unit 7303 341 126.0 122.0 #:alliance 3 #:owner 0 #:minerals 1800))
  (define obs-zerg (mk-obs 5000 (list main-hatch proxy-drone nydus-net exp-m1 exp-m2 exp-m3)))

  (define cmds-hatch (xlat obs-zerg (list (list 'build-proxy 'hatchery 120.0 120.0 7101))))
  (check-eqv "l84-zerg-proxy-hatch-emits-1" (length cmds-hatch) 1)
  (when (= (length cmds-hatch) 1)
    (define pt (sc2-raw-unit-command-target-pos (first cmds-hatch)))
    (check-eqv "l84-zerg-proxy-hatch-ab" (sc2-raw-unit-command-ability-id (first cmds-hatch)) 1152)
    (check-eqv "l84-zerg-proxy-hatch-drone" (sc2-raw-unit-command-unit-tags (first cmds-hatch)) '(7101))
    (check-true "l84-zerg-proxy-hatch-lands-near-proxy"
                (<= (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 120.0 120.0) 6.0)
                (format "pt=~a" pt)))

  (define cmds-nydus (xlat obs-zerg (list (list 'build-proxy 'nydus-worm 130.0 130.0))))
  (check-eqv "l84-zerg-proxy-nydus-emits-1" (length cmds-nydus) 1)
  (when (= (length cmds-nydus) 1)
    (define pt (sc2-raw-unit-command-target-pos (first cmds-nydus)))
    (check-eqv "l84-zerg-proxy-nydus-ab" (sc2-raw-unit-command-ability-id (first cmds-nydus)) 1768)
    (check-eqv "l84-zerg-proxy-nydus-caster" (sc2-raw-unit-command-unit-tags (first cmds-nydus)) '(7201))
    (check-true "l84-zerg-proxy-nydus-lands-near-target"
                (<= (pt-d (sc2-point2d-x pt) (sc2-point2d-y pt) 130.0 130.0) 6.0)
                (format "pt=~a" pt)))

  ;; Loop 84B: Proxy `spine-crawler` searches up to 14.0t around `(px, py)` for valid creep tiles!
  (define (mk-creep-disc-grid discs [w 160] [h 160])
    (define bs (make-bytes (* w h) 0))
    (for* ([d (in-list discs)]
           [cx (in-value (first d))]
           [cy (in-value (second d))]
           [r (in-value (third d))]
           [ix (in-range (max 0 (inexact->exact (floor (- cx r))))
                         (min w (add1 (inexact->exact (ceiling (+ cx r))))))]
           [iy (in-range (max 0 (inexact->exact (floor (- cy r))))
                         (min h (add1 (inexact->exact (ceiling (+ cy r))))))]
           #:when (<= (pt-d ix iy cx cy) r))
      (bytes-set! bs (+ ix (* iy w)) 1))
    (sc2-image-grid 8 w h bs #f #t))

  ;; (a) Proxy anchor (120, 120) is OFF-creep, while enemy natural creep sits 9..14t East at (133, 120) r=5.0!
  (define enemy-nat-creep (mk-creep-disc-grid '((30.0 30.0 10.0) (133.0 120.0 5.0))))
  (define obs-spine-creep (mk-obs 5100 (list main-hatch proxy-drone)))
  (hash-set! SC2-OBS-CREEP-GRIDS obs-spine-creep enemy-nat-creep)
  (define cmds-spine (xlat obs-spine-creep (list (list 'build-proxy 'spine-crawler 120.0 120.0 7101))))
  (check-eqv "l84b-zerg-proxy-spine-on-enemy-creep-emits-1" (length cmds-spine) 1)
  (when (= (length cmds-spine) 1)
    (define c (first cmds-spine))
    (define pt (sc2-raw-unit-command-target-pos c))
    (define sx (sc2-point2d-x pt))
    (define sy (sc2-point2d-y pt))
    (check-eqv "l84b-zerg-proxy-spine-ab" (sc2-raw-unit-command-ability-id c) 1166)
    (check-eqv "l84b-zerg-proxy-spine-drone" (sc2-raw-unit-command-unit-tags c) '(7101))
    (check-true "l84b-zerg-proxy-spine-within-14t-and-not-main"
                (and (<= (pt-d sx sy 120.0 120.0) 14.0)
                     (> (pt-d sx sy 30.0 30.0) 80.0))
                (format "pt=(~a,~a)" sx sy))
    (check-true "l84b-zerg-proxy-spine-all-2x2-tiles-on-creep"
                (let ([x0 (inexact->exact (floor (- sx 1.0)))]
                      [x1 (inexact->exact (floor (+ sx 0.99)))]
                      [y0 (inexact->exact (floor (- sy 1.0)))]
                      [y1 (inexact->exact (floor (+ sy 0.99)))])
                  (for*/and ([ix (in-range x0 (add1 x1))]
                             [iy (in-range y0 (add1 y1))])
                    (> (sc2-grid-ref enemy-nat-creep ix iy) 0)))
                (format "pt=(~a,~a)" sx sy)))

  ;; (b) Creep ONLY at Main (30, 30), ZERO creep within 14t of (120, 120) -> MUST emit 0 (never snap to Main!)
  (define main-only-creep (mk-creep-disc-grid '((30.0 30.0 10.0))))
  (define obs-spine-no-creep (mk-obs 5200 (list main-hatch proxy-drone)))
  (hash-set! SC2-OBS-CREEP-GRIDS obs-spine-no-creep main-only-creep)
  (define cmds-spine-none
    (xlat obs-spine-no-creep (list (list 'build-proxy 'spine-crawler 120.0 120.0 7101))))
  (check-eqv "l84b-zerg-proxy-spine-no-nearby-creep-emits-0" (length cmds-spine-none) 0))

;; -----------------------------------------------------------------------------
;; 6. saturate-workers-and-gas-commands #:exclude-worker-tags
;; -----------------------------------------------------------------------------
(printf "[6/7] saturate-workers-and-gas-commands #:exclude-worker-tags...\n")
(let ()
  (define main-nexus (mk-unit 8000 59 30.0 30.0 #:radius 2.5 #:hp 1000.0 #:assigned 0 #:ideal 16))
  (define m1 (mk-unit 8101 341 24.0 28.0 #:alliance 3 #:owner 0 #:minerals 1800))
  (define m2 (mk-unit 8102 341 24.0 30.0 #:alliance 3 #:owner 0 #:minerals 1800))
  (define m3 (mk-unit 8103 341 24.0 32.0 #:alliance 3 #:owner 0 #:minerals 1800))
  (define assim (mk-unit 8110 61 30.0 23.0 #:radius 1.5 #:hp 450.0 #:vespene 2250 #:assigned 0 #:ideal 3))
  (define w-home-1 (mk-unit 8001 84 28.0 29.0 #:radius 0.375 #:hp 20.0))
  (define w-home-2 (mk-unit 8002 84 28.0 31.0 #:radius 0.375 #:hp 20.0))
  (define w-proxy-1 (mk-unit 8003 84 115.0 115.0 #:radius 0.375 #:hp 20.0))
  (define w-proxy-2 (mk-unit 8004 84 116.0 115.0 #:radius 0.375 #:hp 20.0))
  (define base-units (list main-nexus m1 m2 m3 assim w-home-1 w-home-2 w-proxy-1 w-proxy-2))

  ;; (a) `#:exclude-worker-tags (set 8003 8004)` (immutable Racket `set`)
  (define cmds-set
    (saturate-workers-and-gas-commands
     (mk-obs 6000 base-units #:minerals 50 #:vespene 0)
     #:exclude-worker-tags (set 8003 8004)
     #:game-info open-gi))
  (define tags-set (cmd-tags cmds-set))
  (check-true "l84-sat-exclude-set-protects-8003" (not (memv 8003 tags-set)) (format "tags=~a" tags-set))
  (check-true "l84-sat-exclude-set-protects-8004" (not (memv 8004 tags-set)) (format "tags=~a" tags-set))
  (check-true "l84-sat-exclude-set-saturates-home-workers"
              (and (memv 8001 tags-set) (memv 8002 tags-set) #t)
              (format "tags=~a" tags-set))

  ;; (b) `#:exclude-worker-tags (list 8003 8004)` (list of integer tags)
  (define cmds-list
    (saturate-workers-and-gas-commands
     (mk-obs 6100 base-units #:minerals 50 #:vespene 0)
     #:exclude-worker-tags (list 8003 8004)
     #:game-info open-gi))
  (define tags-list (cmd-tags cmds-list))
  (check-true "l84-sat-exclude-list-protects-8003" (not (memv 8003 tags-list)) (format "tags=~a" tags-list))
  (check-true "l84-sat-exclude-list-protects-8004" (not (memv 8004 tags-list)) (format "tags=~a" tags-list))
  (check-true "l84-sat-exclude-list-saturates-home-workers"
              (and (memv 8001 tags-list) (memv 8002 tags-list) #t)
              (format "tags=~a" tags-list))

  ;; (c) Union of legacy `#:excluded-worker-tags (mutable-seteqv 8003)` + `#:exclude-worker-tags (set 8004)`
  (define cmds-union
    (saturate-workers-and-gas-commands
     (mk-obs 6200 base-units #:minerals 50 #:vespene 0)
     #:excluded-worker-tags (mutable-seteqv 8003)
     #:exclude-worker-tags (set 8004)
     #:game-info open-gi))
  (define tags-union (cmd-tags cmds-union))
  (check-true "l84-sat-union-protects-mutable-seteqv-8003" (not (memv 8003 tags-union)) (format "tags=~a" tags-union))
  (check-true "l84-sat-union-protects-set-8004" (not (memv 8004 tags-union)) (format "tags=~a" tags-union))
  (check-true "l84-sat-union-saturates-home-workers"
              (and (memv 8001 tags-union) (memv 8002 tags-union) #t)
              (format "tags=~a" tags-union)))

;; -----------------------------------------------------------------------------
;; 7. Action Validation Hygiene (Valid vs Malformed `build-proxy`)
;; -----------------------------------------------------------------------------
(printf "[7/7] Action validation hygiene for valid vs malformed build-proxy...\n")
(let ()
  (define main-cc (mk-unit 9001 18 30.0 30.0 #:radius 2.75 #:hp 1500.0))
  (define proxy-scv (mk-unit 9101 45 110.0 45.0 #:radius 0.375 #:hp 45.0))
  (define obs (mk-obs 7000 (list main-cc proxy-scv)))

  ;; Valid 5-arg with `#f` worker tag -> 0 rejects and dispatches closest worker 9101
  (define cmds-false-tag (xlat obs (list (list 'build-proxy 'barracks 110.0 45.0 #f))))
  (check-eqv "l84-valid-build-proxy-false-tag-emits-1" (length cmds-false-tag) 1)
  (check-eqv "l84-valid-build-proxy-false-tag-zero-rejects"
             (length (get-last-bot-action-rejects)) 0)

  ;; Malformed forms cleanly rejected without crashing
  (define cmds-bad
    (xlat obs
          (list (list 'build-proxy 'not-a-real-structure 110.0 45.0)
                (list 'build-proxy 'barracks 110.0 45.0 -5)
                (list 'build-proxy 'barracks))))
  (check-eqv "l84-malformed-build-proxy-emits-0" (length cmds-bad) 0)
  (check-eqv "l84-malformed-build-proxy-records-3-rejects"
             (length (get-last-bot-action-rejects)) 3))

(printf "-----------------------------------------------------------------\n")
(printf "Loop 84 Proxy Wire Checks: ~a/~a passed (~a failed)\n"
        (- tests-run tests-failed) tests-run tests-failed)
(printf "=================================================================\n")
(when (> tests-failed 0)
  (exit 1))
