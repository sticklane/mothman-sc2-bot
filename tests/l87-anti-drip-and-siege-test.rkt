#lang racket/base

;; =============================================================================
;; Loop 87 Track 3: Home-Defense Anti-Drip-Feed Pocket Staging, All-Race
;; Natural Reinforce Batching, Winning-Lead Choke-Hold Tuning & Home Stealth
;; Detector Retention Tests
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/sc2-game-constants.rkt"
         "../lib/tactics/staging-groups.rkt"
         "../lib/tactics/mode-and-stealth-safety.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check-true name expr [detail ""])
  (if expr
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected truthy (~a)\n" name detail))))

(define (check-equal name actual expected)
  (if (equal? actual expected)
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected ~s, got ~s\n" name expected actual))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-u id sym x y
              #:hp [hp 100.0]
              #:shield [sh 0.0]
              #:flying? [fl? #f]
              #:bp [bp 1.0]
              #:cloaked? [cloaked? #f]
              #:cloak [cloak 0])
  (hasheq 'id id 'type sym 'x x 'y y
          'hp hp 'max-hp hp
          'shields sh 'max-shields sh
          'flying? fl? 'build-progress bp
          'cloaked? cloaked? 'cloak cloak
          'display-type 1 'snapshot? #f))

;; =============================================================================
;; 1. Home-Defense Anti-Drip-Feed Pocket Staging (step-staging-groups!)
;; =============================================================================
(printf "[1/5] Testing Home-Defense Anti-Drip-Feed Pocket Staging...\n")

(define p-probes (list (mk-u 1001 'probe 28.0 32.5 #:hp 20.0 #:shield 20.0)))
(define p-bldgs-2b
  (list (mk-u 1010 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
        (mk-u 1011 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
        (mk-u 1012 'gateway 36.0 36.0 #:hp 500.0 #:shield 500.0)
        (mk-u 1013 'gateway 39.0 36.0 #:hp 500.0 #:shield 500.0)))
;; 12 enemy Marauders = 12 * 125 = 1500 resource value besieging Natural (62.5, 32.5)
(define nat-besiegers-1500
  (for/list ([i (in-range 12)])
    (mk-u (+ 8000 i) 'marauder 68.0 (+ 29.5 (* 0.5 i)) #:hp 125.0)))

;; 1a. 1..3 fresh Stalkers in Main stage inside safe pocket (NO 0.15x trickle!),
;;     engaged unit <= 14t from besiegers is NEVER pulled, and 6 Stalkers (1050 >= 0.65*1500=975)
;;     release ALL together as ONE synchronized wave and graduate cleanly!
(let ()
  (define mgr (make-staging-group-manager))
  (define leases (make-hasheqv))
  (define engaged-stalker (mk-u 1199 'stalker 58.0 32.5 #:hp 80.0 #:shield 80.0)) ;; 10t from besiegers!
  (define pocket-3
    (list (mk-u 1101 'stalker 34.0 32.5 #:hp 80.0 #:shield 80.0)
          (mk-u 1102 'stalker 35.0 32.5 #:hp 80.0 #:shield 80.0)
          (mk-u 1103 'stalker 36.0 32.5 #:hp 80.0 #:shield 80.0)))
  (define r1
    (step-staging-groups! mgr #:frame 6000 #:live-obs? #t
                          #:ally-units (append p-probes (cons engaged-stalker pocket-3))
                          #:combat-units (cons engaged-stalker pocket-3)
                          #:ally-buildings p-bldgs-2b
                          #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t
                          #:enemy-near-main? #f
                          #:role-leases leases
                          #:in-production-counts (hasheq 'stalker 3)))
  (define anch (hash-ref (staging-step-result-anchors r1) 'main-reinforce #f))
  (check-true "l87-1a-3-spawns-stage-in-home-pocket-under-nat-siege"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r1))
                   (set-member? (staging-step-result-handled-tags r1) 1101)
                   (set-member? (staging-step-result-handled-tags r1) 1102)
                   (set-member? (staging-step-result-handled-tags r1) 1103))
              (format "stg=~a handled=~a"
                      (staging-step-result-staging-groups r1)
                      (staging-step-result-handled-tags r1)))
  (check-true "l87-1a-engaged-unit-within-14t-never-pulled-into-pocket"
              (not (set-member? (staging-step-result-handled-tags r1) 1199))
              (format "handled=~a" (staging-step-result-handled-tags r1)))
  (check-true "l87-1a-pocket-anchor-safe-in-main-and-uses-attack-pos-only"
              (and (pair? anch)
                   (< (dist2d (car anch) (cdr anch) 32.5 32.5) 14.0)
                   (> (dist2d (car anch) (cdr anch) 68.0 32.5) 16.0)
                   (not (ormap (lambda (a) (eq? (car a) 'move)) (staging-step-result-actions r1))))
              (format "anch=~a acts=~a" anch (staging-step-result-actions r1)))

  ;; Add 3 more Stalkers -> 6 total in Main (6 * 175 = 1050 >= 0.65 * 1500 = 975) -> synchronized wave release!
  (define pocket-6
    (append pocket-3
            (list (mk-u 1104 'stalker 34.5 33.5 #:hp 80.0 #:shield 80.0)
                  (mk-u 1105 'stalker 35.5 33.5 #:hp 80.0 #:shield 80.0)
                  (mk-u 1106 'stalker 36.5 33.5 #:hp 80.0 #:shield 80.0))))
  (define r2
    (step-staging-groups! mgr #:frame 6048 #:live-obs? #t
                          #:ally-units (append p-probes pocket-6)
                          #:combat-units pocket-6
                          #:ally-buildings p-bldgs-2b
                          #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t
                          #:enemy-near-main? #f
                          #:role-leases leases
                          #:in-production-counts (hasheq 'stalker 2)))
  (check-true "l87-1a-parity-ge-0.65x-releases-entire-pocket-simultaneously"
              (and (memq 'main-reinforce (staging-step-result-dispatched-groups r2))
                   (not (memq 'main-reinforce (staging-step-result-staging-groups r2)))
                   (set-empty? (staging-step-result-handled-tags r2))
                   (not (hash-has-key? leases 1101)))
              (format "disp=~a stg=~a handled=~a"
                      (staging-step-result-dispatched-groups r2)
                      (staging-step-result-staging-groups r2)
                      (staging-step-result-handled-tags r2)))

  ;; Next frame (+16f) AND later (+200f): graduated midgame units are NEVER recaptured into Main pocket!
  (define r3
    (step-staging-groups! mgr #:frame 6064 #:live-obs? #t
                          #:ally-units (append p-probes pocket-6)
                          #:combat-units pocket-6
                          #:ally-buildings p-bldgs-2b
                          #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t
                          #:enemy-near-main? #f))
  (define survivors-2 (take pocket-6 2))
  (define r4-never-recapture
    (step-staging-groups! mgr #:frame 6248 #:live-obs? #t
                          #:ally-units (append p-probes survivors-2)
                          #:combat-units survivors-2
                          #:ally-buildings p-bldgs-2b
                          #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t
                          #:enemy-near-main? #f))
  (check-true "l87c-1a-graduated-units-never-recaptured-short-or-late"
              (and (not (memq 'main-reinforce (staging-step-result-staging-groups r3)))
                   (set-empty? (staging-step-result-handled-tags r3))
                   (not (memq 'main-reinforce (staging-step-result-staging-groups r4-never-recapture)))
                   (set-empty? (staging-step-result-handled-tags r4-never-recapture)))
              (format "r3-h=~a r4-h=~a"
                      (staging-step-result-handled-tags r3)
                      (staging-step-result-handled-tags r4-never-recapture))))

;; 1b. >= 18 combat supply releases pocket even against huge 3500-val siege (28 Marauders)
(let ()
  (define mgr (make-staging-group-manager))
  (define huge-besiegers
    (for/list ([i (in-range 28)])
      (mk-u (+ 8100 i) 'marauder 68.0 (+ 26.0 (* 0.4 i)) #:hp 125.0))) ;; 3500 val -> 0.65x = 2275
  (define stalkers-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 1200 i) 'stalker (+ 33.0 (* 0.4 i)) 32.5 #:hp 80.0 #:shield 80.0))) ;; 16 sup, 1400 val
  (define r-hold
    (step-staging-groups! mgr #:frame 7000 #:live-obs? #t
                          #:ally-units (append p-probes stalkers-8)
                          #:combat-units stalkers-8
                          #:ally-buildings p-bldgs-2b
                          #:enemy-units huge-besiegers
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  (define stalkers-9
    (append stalkers-8 (list (mk-u 1209 'stalker 36.5 32.5 #:hp 80.0 #:shield 80.0)))) ;; 18 sup!
  (define r-rel
    (step-staging-groups! mgr #:frame 7024 #:live-obs? #t
                          #:ally-units (append p-probes stalkers-9)
                          #:combat-units stalkers-9
                          #:ally-buildings p-bldgs-2b
                          #:enemy-units huge-besiegers
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  (check-true "l87-1b-16sup-holds-and-18sup-releases-vs-huge-siege"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-hold))
                   (memq 'main-reinforce (staging-step-result-dispatched-groups r-rel))
                   (set-empty? (staging-step-result-handled-tags r-rel)))
              (format "hold=~a rel-disp=~a rel-h=~a"
                      (staging-step-result-staging-groups r-hold)
                      (staging-step-result-dispatched-groups r-rel)
                      (staging-step-result-handled-tags r-rel))))

;; 1c. Bounded 224f anti-stall: 3 units (< 4) do NOT trickle at +230f; 4 units (>= 4) release at +224f!
(let ()
  (define mgr3 (make-staging-group-manager))
  (define st3 (for/list ([i (in-range 3)]) (mk-u (+ 1300 i) 'stalker (+ 34.0 (* 0.5 i)) 32.5 #:hp 80.0 #:shield 80.0)))
  (void (step-staging-groups! mgr3 #:frame 7000 #:live-obs? #t
                              #:ally-units (append p-probes st3) #:combat-units st3
                              #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                              #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                              #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                              #:under-home-attack? #t #:in-production-counts (hasheq 'stalker 2)))
  (define r3-late
    (step-staging-groups! mgr3 #:frame 7230 #:live-obs? #t
                          #:ally-units (append p-probes st3) #:combat-units st3
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t #:in-production-counts (hasheq 'stalker 2)))
  (define st4 (append st3 (list (mk-u 1303 'stalker 36.0 32.5 #:hp 80.0 #:shield 80.0))))
  (define r4-antistall
    (step-staging-groups! mgr3 #:frame 7240 #:live-obs? #t
                          #:ally-units (append p-probes st4) #:combat-units st4
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t #:in-production-counts (hasheq 'stalker 2)))
  (check-true "l87-1c-antistall-224f-requires-ge4-units"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r3-late))
                   (memq 'main-reinforce (staging-step-result-dispatched-groups r4-antistall))
                   (set-empty? (staging-step-result-handled-tags r4-antistall)))
              (format "r3=~a r4-disp=~a"
                      (staging-step-result-staging-groups r3-late)
                      (staging-step-result-dispatched-groups r4-antistall))))

;; 1d. Instant Main-Breach Scramble: enemy-near-main? = #t immediately scrambles pocket & clears lease!
(let ()
  (define mgr (make-staging-group-manager))
  (define leases (make-hasheqv))
  (define st2 (list (mk-u 1401 'stalker 34.0 32.5 #:hp 80.0 #:shield 80.0)
                    (mk-u 1402 'stalker 35.0 32.5 #:hp 80.0 #:shield 80.0)))
  (define r-stg
    (step-staging-groups! mgr #:frame 8000 #:live-obs? #t
                          #:ally-units (append p-probes st2) #:combat-units st2
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t #:enemy-near-main? #f
                          #:role-leases leases))
  (define r-breach
    (step-staging-groups! mgr #:frame 8016 #:live-obs? #t
                          #:ally-units (append p-probes st2) #:combat-units st2
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t #:enemy-near-main? #t
                          #:role-leases leases))
  (check-true "l87-1d-main-breach-scrambles-pocket-immediately"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-stg))
                   (set-member? (staging-step-result-handled-tags r-stg) 1401)
                   (not (memq 'main-reinforce (staging-step-result-staging-groups r-breach)))
                   (set-empty? (staging-step-result-handled-tags r-breach))
                   (not (hash-has-key? leases 1401)))
              (format "stg=~a breach-stg=~a breach-h=~a lease=~a"
                      (staging-step-result-staging-groups r-stg)
                      (staging-step-result-staging-groups r-breach)
                      (staging-step-result-handled-tags r-breach)
                      (hash-ref leases 1401 #f))))

;; 1e. 3rd-base siege with safe Natural rally captures Natural spawns under defensive-muster-active?
(let ()
  (define mgr (make-staging-group-manager))
  (define scvs (list (mk-u 1501 'scv 28.0 32.5 #:hp 45.0)))
  (define t-bldgs-3b
    (list (mk-u 1510 'orbital-command 32.5 32.5)
          (mk-u 1511 'orbital-command 62.5 32.5)
          (mk-u 1512 'command-center 102.0 32.5)
          (mk-u 1513 'barracks 65.0 35.0)))
  (define third-besiegers
    (for/list ([i (in-range 10)])
      (mk-u (+ 8200 i) 'stalker 108.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))) ;; 1750 val at 3rd!
  (define nat-spawns
    (list (mk-u 1521 'marauder 66.0 32.5 #:hp 125.0)
          (mk-u 1522 'marauder 67.0 32.5 #:hp 125.0)))
  (define r-3rd
    (step-staging-groups! mgr #:frame 9000 #:live-obs? #t
                          #:ally-units (append scvs nat-spawns) #:combat-units nat-spawns
                          #:ally-buildings t-bldgs-3b #:enemy-units third-besiegers
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5 #:third-x 102.0 #:third-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t #:defensive-muster-active? #t))
  (check-true "l87-1e-3rd-siege-stages-safe-natural-spawns-during-muster"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-3rd))
                   (set-member? (staging-step-result-handled-tags r-3rd) 1521)
                   (set-member? (staging-step-result-handled-tags r-3rd) 1522))
              (format "stg=~a handled=~a"
                      (staging-step-result-staging-groups r-3rd)
                      (staging-step-result-handled-tags r-3rd))))

;; 1f. Loop 87C Track 2 CRITICAL INVARIANT: NEVER split an active home fight!
;;     (i) When >= 3 units OR >= 6 supply are actively defending within <= 18t of besiegers,
;;         home-pocket-hold? is STRICTLY #f (all fresh Main spawns & staged units release immediately!).
;;     (ii) zergling, colossus, and adept stay excluded from home-pocket-hold? so active fighters
;;          immediately reinforce our Natural/3rd!
(let ()
  ;; (i-a) 3 Stalkers (6 sup) actively defending Natural -> fresh Main spawns NEVER held in pocket!
  (define mgr-act-p (make-staging-group-manager))
  (define active-def-3
    (list (mk-u 1601 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)
          (mk-u 1602 'stalker 57.0 33.0 #:hp 80.0 #:shield 80.0)
          (mk-u 1603 'stalker 58.0 32.0 #:hp 80.0 #:shield 80.0)))
  (define fresh-main-2
    (list (mk-u 1611 'stalker 34.0 32.5 #:hp 80.0 #:shield 80.0)
          (mk-u 1612 'stalker 35.0 32.5 #:hp 80.0 #:shield 80.0)))
  ;; First verify post-wipe (0 active defenders) DOES hold fresh-main-2, then once active-def-3 engages,
  ;; fresh-main-2 is IMMEDIATELY released!
  (define r-wipe
    (step-staging-groups! mgr-act-p #:frame 9100 #:live-obs? #t
                          #:ally-units (append p-probes fresh-main-2) #:combat-units fresh-main-2
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  (define r-active-fight
    (step-staging-groups! mgr-act-p #:frame 9116 #:live-obs? #t
                          #:ally-units (append p-probes active-def-3 fresh-main-2)
                          #:combat-units (append active-def-3 fresh-main-2)
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  ;; (i-b) 3 Marines (3 units, 3 sup) actively defending Natural -> also forces home-pocket-hold? = #f!
  (define mgr-act-t (make-staging-group-manager))
  (define t-bldgs-2b
    (list (mk-u 1630 'orbital-command 32.5 32.5)
          (mk-u 1631 'orbital-command 62.5 32.5)
          (mk-u 1632 'barracks 36.0 35.0)))
  (define active-m3
    (list (mk-u 1635 'marine 56.0 32.5 #:hp 45.0)
          (mk-u 1636 'marine 57.0 32.5 #:hp 45.0)
          (mk-u 1637 'marine 58.0 32.5 #:hp 45.0)))
  (define fresh-m2
    (list (mk-u 1641 'marine 34.0 32.5 #:hp 45.0)
          (mk-u 1642 'marine 35.0 32.5 #:hp 45.0)))
  (define r-active-m3
    (step-staging-groups! mgr-act-t #:frame 9150 #:live-obs? #t
                          #:ally-units (append (list (mk-u 1639 'scv 28.0 32.5)) active-m3 fresh-m2)
                          #:combat-units (append active-m3 fresh-m2)
                          #:ally-buildings t-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  ;; (ii) zergling, colossus, and adept stay excluded from home-pocket-hold? even post-wipe!
  (define mgr-excl (make-staging-group-manager))
  (define z-bldgs (list (mk-u 1650 'lair 32.5 32.5) (mk-u 1651 'hatchery 62.5 32.5)))
  (define z-mix
    (list (mk-u 1661 'zergling 34.0 32.5 #:hp 35.0)
          (mk-u 1662 'roach 35.0 32.5 #:hp 145.0)))
  (define r-z-excl
    (step-staging-groups! mgr-excl #:frame 9200 #:live-obs? #t
                          #:ally-units (append (list (mk-u 1659 'drone 28.0 32.5)) z-mix)
                          #:combat-units z-mix
                          #:ally-buildings z-bldgs #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  (define mgr-col (make-staging-group-manager))
  (define p-col-mix
    (list (mk-u 1671 'colossus 34.0 32.5 #:hp 200.0 #:shield 150.0)
          (mk-u 1672 'adept 34.5 32.5 #:hp 70.0 #:shield 70.0)
          (mk-u 1673 'stalker 35.0 32.5 #:hp 80.0 #:shield 80.0)))
  (define r-p-excl
    (step-staging-groups! mgr-col #:frame 9220 #:live-obs? #t
                          #:ally-units (append p-probes p-col-mix) #:combat-units p-col-mix
                          #:ally-buildings p-bldgs-2b #:enemy-units nat-besiegers-1500
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t))
  (check-true "l87c-1f-active-home-defense-disables-pocket-and-releases-reinforcements"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-wipe))
                   (set-member? (staging-step-result-handled-tags r-wipe) 1611)
                   (not (memq 'main-reinforce (staging-step-result-staging-groups r-active-fight)))
                   (set-empty? (staging-step-result-handled-tags r-active-fight))
                   (not (memq 'main-reinforce (staging-step-result-staging-groups r-active-m3)))
                   (set-empty? (staging-step-result-handled-tags r-active-m3)))
              (format "wipe=~a active-p=~a active-t=~a"
                      (staging-step-result-handled-tags r-wipe)
                      (staging-step-result-handled-tags r-active-fight)
                      (staging-step-result-handled-tags r-active-m3)))
  (check-true "l87c-1f-zergling-colossus-adept-excluded-from-home-pocket"
              (and (not (set-member? (staging-step-result-handled-tags r-z-excl) 1661))
                   (set-member? (staging-step-result-handled-tags r-z-excl) 1662)
                   (not (set-member? (staging-step-result-handled-tags r-p-excl) 1671))
                   (not (set-member? (staging-step-result-handled-tags r-p-excl) 1672))
                   (set-member? (staging-step-result-handled-tags r-p-excl) 1673))
              (format "z-h=~a p-h=~a"
                      (staging-step-result-handled-tags r-z-excl)
                      (staging-step-result-handled-tags r-p-excl))))

;; =============================================================================
;; 2. Offensive 'main-reinforce Trickle-Gap Fixes (All-Race Nat & Midgame Lead)
;; =============================================================================
(printf "[2/5] Testing All-Race Natural Capture & Midgame Combat-Lead Batching...\n")

;; 2a. Terran Natural Barracks spawns & Zerg Natural Hatchery spawns batch into 'main-reinforce!
(let ()
  ;; Terran with Natural Barracks at (66, 35)
  (define mgr-t (make-staging-group-manager))
  (define t-scv (list (mk-u 2001 'scv 28.0 32.5 #:hp 45.0)))
  (define t-bldgs
    (list (mk-u 2010 'orbital-command 32.5 32.5)
          (mk-u 2011 'orbital-command 62.5 32.5)
          (mk-u 2012 'barracks 66.0 35.0)))
  (define t-front (for/list ([i (in-range 5)]) (mk-u (+ 2020 i) 'marauder 115.0 (+ 110.0 i) #:hp 125.0)))
  (define t-nat-spawns (list (mk-u 2031 'marauder 68.5 32.5 #:hp 125.0)
                             (mk-u 2032 'marine 67.5 34.0 #:hp 45.0)))
  (define r-t
    (step-staging-groups! mgr-t #:frame 7500 #:live-obs? #t
                          #:ally-units (append t-scv t-front t-nat-spawns)
                          #:combat-units (append t-front t-nat-spawns)
                          #:ally-buildings t-bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'marauder 2)))
  ;; Zerg with Natural Hatchery at (62.5, 32.5)
  (define mgr-z (make-staging-group-manager))
  (define z-drone (list (mk-u 2101 'drone 28.0 32.5 #:hp 40.0)))
  (define z-bldgs
    (list (mk-u 2110 'lair 32.5 32.5)
          (mk-u 2111 'hatchery 62.5 32.5)))
  (define z-front (for/list ([i (in-range 5)]) (mk-u (+ 2120 i) 'roach 115.0 (+ 110.0 i) #:hp 145.0)))
  (define z-nat-spawns (list (mk-u 2131 'roach 68.5 32.5 #:hp 145.0)
                             (mk-u 2132 'hydralisk 67.5 34.0 #:hp 90.0)))
  (define r-z
    (step-staging-groups! mgr-z #:frame 7500 #:live-obs? #t
                          #:ally-units (append z-drone z-front z-nat-spawns)
                          #:combat-units (append z-front z-nat-spawns)
                          #:ally-buildings z-bldgs #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:in-production-counts (hasheq 'roach 2)))
  (check-true "l87-2a-terran-and-zerg-natural-spawns-batch-into-main-reinforce"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-t))
                   (set-member? (staging-step-result-handled-tags r-t) 2031)
                   (set-member? (staging-step-result-handled-tags r-t) 2032)
                   (memq 'main-reinforce (staging-step-result-staging-groups r-z))
                   (set-member? (staging-step-result-handled-tags r-z) 2131)
                   (set-member? (staging-step-result-handled-tags r-z) 2132))
              (format "t-stg=~a t-h=~a z-stg=~a z-h=~a"
                      (staging-step-result-staging-groups r-t)
                      (staging-step-result-handled-tags r-t)
                      (staging-step-result-staging-groups r-z)
                      (staging-step-result-handled-tags r-z))))

;; 2b. ally-combat-supply = 50 at supply-used = 120 (and 170) does NOT disable 'main-reinforce;
;;     supply-used = 180 DOES force-dispatch 'main-reinforce!
(let ()
  (define mgr-mid (make-staging-group-manager))
  (define p-front (for/list ([i (in-range 5)]) (mk-u (+ 2200 i) 'stalker 115.0 (+ 110.0 i) #:hp 80.0 #:shield 80.0)))
  (define p-home (list (mk-u 2211 'stalker 35.0 32.5 #:hp 80.0 #:shield 80.0)
                       (mk-u 2212 'stalker 36.0 32.5 #:hp 80.0 #:shield 80.0)))
  (define r-mid120
    (step-staging-groups! mgr-mid #:frame 8000 #:live-obs? #t
                          #:ally-units (append p-probes p-front p-home)
                          #:combat-units (append p-front p-home)
                          #:ally-buildings p-bldgs-2b #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:supply-used 120
                          #:ally-combat-supply 50
                          #:enemy-believed-supply 20
                          #:in-production-counts (hasheq 'stalker 2)))
  (define r-mid170
    (step-staging-groups! mgr-mid #:frame 8024 #:live-obs? #t
                          #:ally-units (append p-probes p-front p-home)
                          #:combat-units (append p-front p-home)
                          #:ally-buildings p-bldgs-2b #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:supply-used 170
                          #:ally-combat-supply 70
                          #:enemy-believed-supply 30
                          #:in-production-counts (hasheq 'stalker 2)))
  (define r-cap180
    (step-staging-groups! mgr-mid #:frame 8048 #:live-obs? #t
                          #:ally-units (append p-probes p-front p-home)
                          #:combat-units (append p-front p-home)
                          #:ally-buildings p-bldgs-2b #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:supply-used 180
                          #:ally-combat-supply 80
                          #:enemy-believed-supply 40))
  (check-true "l87-2b-midgame-50-combat-sup-keeps-batching-and-180-dispatches"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-mid120))
                   (set-member? (staging-step-result-handled-tags r-mid120) 2211)
                   (memq 'main-reinforce (staging-step-result-staging-groups r-mid170))
                   (memq 'main-reinforce (staging-step-result-dispatched-groups r-cap180))
                   (set-empty? (staging-step-result-handled-tags r-cap180)))
              (format "mid120=~a mid170=~a cap180-disp=~a"
                      (staging-step-result-staging-groups r-mid120)
                      (staging-step-result-staging-groups r-mid170)
                      (staging-step-result-dispatched-groups r-cap180))))

;; =============================================================================
;; 3. Winning-Lead Choke-Hold Tuning (update-choke-attrition-breaker!)
;; =============================================================================
(printf "[3/5] Testing Winning-Lead Choke-Hold Tuning...\n")

(define (make-stalker-wave start-id n x y)
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) 'stalker (+ x (* 0.2 i)) y)))

(define choke-bldgs (list (mk-u 900 'bunker 100.0 100.0) (mk-u 901 'bunker 102.0 102.0)))

;; 3a. 1.15x winning army with >= 2 siege breakers releases immediately; 1.05x still holds;
;;     0.0 combat-val with 0.0 enemy-val does NOT falsely release!
(let ()
  (define cst (make-choke-attrition-state))
  (define w8 (make-stalker-wave 3000 8 100.0 100.0))
  (void (update-choke-attrition-breaker! cst #:frame 10000 #:combat-units w8 #:enemy-buildings choke-bldgs))
  (define v-hold-low
    (update-choke-attrition-breaker! cst #:frame 10024 #:combat-units '() #:enemy-buildings choke-bldgs
                                     #:our-siege-breaker-count 2
                                     #:our-combat-val 2100.0 #:known-enemy-val 2000.0)) ;; 1.05x < 1.15x
  (check-equal "l87-3a-1.05x-with-2-siege-still-holds" (choke-attrition-verdict-hold-active? v-hold-low) #t)
  (define v-hold-zero
    (update-choke-attrition-breaker! cst #:frame 10048 #:combat-units '() #:enemy-buildings choke-bldgs
                                     #:our-siege-breaker-count 2
                                     #:our-combat-val 0.0 #:known-enemy-val 0.0))
  (check-equal "l87-3a-zero-combat-val-does-not-falsely-release"
               (choke-attrition-verdict-hold-active? v-hold-zero) #t)
  (define v-rel-115
    (update-choke-attrition-breaker! cst #:frame 10072 #:combat-units '() #:enemy-buildings choke-bldgs
                                     #:our-siege-breaker-count 2
                                     #:our-combat-val 2300.0 #:known-enemy-val 2000.0)) ;; 1.15x exact!
  (check-equal "l87-3a-1.15x-with-2-siege-releases-immediately"
               (choke-attrition-verdict-hold-active? v-rel-115) #f)
  (check-equal "l87-3a-1.15x-with-2-siege-reason"
               (choke-attrition-verdict-release-reason v-rel-115) 'siege-ready)

  ;; Winning 6m midgame lead (2150 vs 1025, 2 Immortals + 3 Colossi = 5 siege) NEVER enters hold!
  (define cst-6m (make-choke-attrition-state))
  (void (update-choke-attrition-breaker! cst-6m #:frame 8000 #:combat-units w8 #:enemy-buildings choke-bldgs))
  (define v-6m
    (update-choke-attrition-breaker! cst-6m #:frame 8024 #:combat-units '() #:enemy-buildings choke-bldgs
                                     #:our-siege-breaker-count 5
                                     #:our-combat-val 2150.0 #:known-enemy-val 1025.0))
  (check-equal "l87-3a-6m-winning-lead-never-enters-hold"
               (choke-attrition-verdict-hold-active? v-6m) #f))

;; 3b. Non-turtle (turtle < 0.35) + cooling rolling loss (< 800.0) releases active hold early,
;;     while confirmed turtle (>= 0.35) continues holding!
(let ()
  (define (run-cooling-case turtle-post)
    (define cst (make-choke-attrition-state))
    (define w5 (make-stalker-wave 3100 5 100.0 100.0)) ;; 875 val
    (define w3 (make-stalker-wave 3110 3 100.0 100.0)) ;; 525 val
    (void (update-choke-attrition-breaker! cst #:frame 10000 #:combat-units (append w5 w3)
                                           #:enemy-buildings choke-bldgs #:enemy-turtle-posterior turtle-post))
    ;; Lose first 5 (875) at frame 10024 (< 1200 -> no hold yet)
    (void (update-choke-attrition-breaker! cst #:frame 10024 #:combat-units w3
                                           #:enemy-buildings choke-bldgs #:enemy-turtle-posterior turtle-post))
    ;; Lose remaining 3 (525) at frame 10600 -> total 1400 >= 1200 -> enters hold at 10600!
    (define v-enter
      (update-choke-attrition-breaker! cst #:frame 10600 #:combat-units '()
                                       #:enemy-buildings choke-bldgs #:enemy-turtle-posterior turtle-post))
    ;; At frame 11400: 10024 batch expired (> 1344f), remaining active-loss = 525 (< 800), hold age = 800f (< 1344f)
    (define v-cool
      (update-choke-attrition-breaker! cst #:frame 11400 #:combat-units '()
                                       #:enemy-buildings choke-bldgs #:enemy-turtle-posterior turtle-post))
    (values v-enter v-cool))
  (define-values (v-nt-enter v-nt-cool) (run-cooling-case 0.20))
  (define-values (v-tt-enter v-tt-cool) (run-cooling-case 0.50))
  (check-equal "l87-3b-nonturtle-enters-hold-at-1400-loss"
               (choke-attrition-verdict-hold-active? v-nt-enter) #t)
  (check-equal "l87-3b-nonturtle-releases-when-loss-cools-under-800"
               (choke-attrition-verdict-hold-active? v-nt-cool) #f)
  (check-equal "l87-3b-nonturtle-cooling-release-reason"
               (choke-attrition-verdict-release-reason v-nt-cool) 'low-attrition)
  (check-equal "l87-3b-confirmed-turtle-still-holds-at-525-cooling"
               (and (choke-attrition-verdict-hold-active? v-tt-enter)
                    (choke-attrition-verdict-hold-active? v-tt-cool))
               #t))

;; =============================================================================
;; 4. Home Stealth Detector Retention & Anti-Oscillation (mode-and-stealth-safety)
;; =============================================================================
(printf "[4/5] Testing Home Stealth Detector Retention & Anti-Oscillation...\n")

(define army-fwd
  (list (mk-u 4010 'stalker 110.0 100.0)
        (mk-u 4011 'stalker 111.0 99.0)
        (mk-u 4012 'immortal 109.0 101.0)
        (mk-u 4013 'colossus 110.0 100.0)))
(define own-ths (list (cons 30.0 30.0) (cons 60.0 30.0)))

;; 4a. Sole completed detector (Observer/Overseer/Raven, even with an incomplete 2nd detector)
;;     is NEVER stolen under home-stealth? = #t!
(for ([spec (in-list '((4101 observer) (4102 overseer) (4103 raven)))])
  (define did (first spec))
  (define dsym (second spec))
  (define-values (cmds ids)
    (plan-mobile-detector-army-escort
     #:detectors (list (mk-u did dsym 55.0 55.0 #:flying? #t #:bp 1.0)
                       (mk-u (+ did 10) dsym 32.0 30.0 #:flying? #t #:bp 0.5)) ;; incomplete!
     #:combat-units army-fwd
     #:enemy-units (list (mk-u 4901 'banshee 62.0 30.0 #:flying? #t #:cloaked? #t #:cloak 1))
     #:enemy-buildings '()
     #:own-townhall-pts own-ths
     #:attack-target-xy (cons 150.0 100.0)
     #:active-home-stealth? #t))
  (check-equal (format "l87-4a-sole-completed-~a-never-stolen-under-home-stealth" dsym) cmds '())
  (check-true  (format "l87-4a-sole-completed-~a-unclaimed" dsym) (set-empty? ids)))

;; 4b. Threatened Natural with cloaked Banshee: detector closest to threatened Natural (802)
;;     is reserved at Natural, and detector sitting at safe Main (801) escorts forward army!
(let ()
  (define det-safe-main (mk-u 4801 'observer 31.0 30.0 #:flying? #t)) ;; 1t from safe Main, 29t from Nat
  (define det-nat-guard (mk-u 4802 'observer 58.0 30.0 #:flying? #t)) ;; 2t from threatened Nat!
  (define banshee-nat (mk-u 4905 'banshee 62.0 30.0 #:flying? #t #:cloaked? #t #:cloak 1))
  (define-values (cmds ids)
    (plan-mobile-detector-army-escort
     #:detectors (list det-safe-main det-nat-guard)
     #:combat-units army-fwd
     #:enemy-units (list banshee-nat)
     #:enemy-buildings '()
     #:own-townhall-pts own-ths
     #:attack-target-xy (cons 150.0 100.0)
     #:active-home-stealth? #t))
  (check-true "l87-4b-reserves-detector-at-threatened-nat-and-sends-safe-main-det"
              (and (= (length cmds) 1)
                   (= (second (first cmds)) 4801)
                   (set-member? ids 4801)
                   (not (set-member? ids 4802)))
              (format "cmds=~a ids=~a" cmds ids)))

;; 4c. Anti-Oscillation: equidistant / jittering detectors across reversed input orders
;;     deterministically pin the SAME home detector and SAME escort detector every step!
(let ()
  (define steps
    (list (list (mk-u 4810 'observer 40.0 30.0 #:flying? #t)
                (mk-u 4811 'observer 40.2 30.0 #:flying? #t))
          (list (mk-u 4811 'observer 40.1 30.0 #:flying? #t)
                (mk-u 4810 'observer 40.7 30.0 #:flying? #t)) ;; 4810 jitters +0.7t within same 2t bucket
          (list (mk-u 4810 'observer 40.5 30.0 #:flying? #t)
                (mk-u 4811 'observer 40.0 30.0 #:flying? #t))
          (list (mk-u 4811 'observer 40.3 30.0 #:flying? #t)
                (mk-u 4810 'observer 40.6 30.0 #:flying? #t))))
  (define escort-picks
    (for/list ([dets (in-list steps)])
      (define-values (cmds ids)
        (plan-mobile-detector-army-escort
         #:detectors dets
         #:combat-units army-fwd
         #:enemy-units '()
         #:enemy-buildings '()
         #:own-townhall-pts (list (cons 30.0 30.0))
         #:attack-target-xy (cons 150.0 100.0)
         #:active-home-stealth? #t))
      (and (= (length cmds) 1) (second (first cmds)))))
  (check-equal "l87-4c-anti-oscillation-deterministic-across-jitter-and-order"
               escort-picks '(4811 4811 4811 4811)))

;; =============================================================================
;; 5. Loop 87B Track E: Free-Unit (Locust / Broodling / Interceptor) Anti-Bait
;;    & Post-Wave Counter-Push Window
;; =============================================================================
(printf "[5/5] Testing Free-Unit Anti-Bait & Post-Wave Counter-Push...\n")

;; 5a + 5b: Active Locust wave near Natural holds defensive pocket (no 1-by-1 streaming into
;;          free Locusts!), and immediately dispatches assembled wave once Locusts expire!
(let ()
  (define mgr (make-staging-group-manager))
  (define scvs (list (mk-u 5001 'scv 28.0 32.5 #:hp 45.0)))
  (define t-bldgs
    (list (mk-u 5010 'orbital-command 32.5 32.5)
          (mk-u 5011 'orbital-command 62.5 32.5)
          (mk-u 5012 'barracks 36.0 35.0)))
  (define t-front
    (for/list ([i (in-range 5)]) (mk-u (+ 5020 i) 'marauder 115.0 (+ 110.0 i) #:hp 125.0)))
  (define home-marines-5
    (for/list ([i (in-range 5)]) (mk-u (+ 5030 i) 'marine (+ 34.0 (* 0.4 i)) 32.5 #:hp 45.0)))
  ;; 16 free Locusts swarming Natural (68, 32.5)
  (define locust-wave-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8500 i) 'locust-mp 68.0 (+ 28.0 (* 0.5 i)) #:hp 50.0)))
  ;; During active Locust wave: Marines hold safely in pocket (NO trickle scramble into Locusts!)
  (define r-during
    (step-staging-groups! mgr #:frame 11000 #:live-obs? #t
                          #:ally-units (append scvs t-front home-marines-5)
                          #:combat-units (append t-front home-marines-5)
                          #:ally-buildings t-bldgs
                          #:enemy-units locust-wave-16
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #t
                          #:in-production-counts (hasheq 'marine 4)))
  ;; Locust wave expires at frame 11120 -> post-free-summon counter-push window immediately dispatches!
  (define r-after
    (step-staging-groups! mgr #:frame 11120 #:live-obs? #t
                          #:ally-units (append scvs t-front home-marines-5)
                          #:combat-units (append t-front home-marines-5)
                          #:ally-buildings t-bldgs
                          #:enemy-units '()
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:enemy-anchor-x 167.5 #:enemy-anchor-y 167.5
                          #:under-home-attack? #f
                          #:in-production-counts (hasheq 'marine 4)))
  (check-true "l87b-5a-active-locust-wave-holds-defensive-pocket-without-scrambling"
              (and (memq 'main-reinforce (staging-step-result-staging-groups r-during))
                   (set-member? (staging-step-result-handled-tags r-during) 5030)
                   (set-member? (staging-step-result-handled-tags r-during) 5034))
              (format "stg=~a handled=~a"
                      (staging-step-result-staging-groups r-during)
                      (staging-step-result-handled-tags r-during)))
  (check-true "l87b-5b-post-locust-cooldown-immediately-dispatches-counter-push"
              (and (memq 'main-reinforce (staging-step-result-dispatched-groups r-after))
                   (set-empty? (staging-step-result-handled-tags r-after)))
              (format "disp=~a stg=~a handled=~a"
                      (staging-step-result-dispatched-groups r-after)
                      (staging-step-result-staging-groups r-after)
                      (staging-step-result-handled-tags r-after))))

;; 5c: Choke-attrition breaker recognizes Swarm Host + Locust waves (>= 8 Locusts / >= 2 SHs)
;;     so trading >= 1200 army into free Locusts blacklists that zone & pivots to soft outer base!
(let ()
  (define cst (make-choke-attrition-state))
  (define w8 (make-stalker-wave 5200 8 100.0 100.0)) ;; 1400 val
  (define locusts-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 8600 i) 'locust-mp (+ 102.0 (* 0.3 i)) 100.0 #:hp 50.0)))
  (void (update-choke-attrition-breaker! cst #:frame 12000 #:combat-units w8
                                         #:enemy-units locusts-10 #:enemy-turtle-posterior 0.10))
  (define v-locust
    (update-choke-attrition-breaker! cst #:frame 12024 #:combat-units '()
                                     #:enemy-units locusts-10 #:enemy-turtle-posterior 0.10
                                     #:soft-alt-xy (cons 155.0 55.0)
                                     #:soft-alt-score 80.0))
  (check-equal "l87b-5c-locust-attrition-zone-pivots-to-soft-outer-base"
               (choke-attrition-verdict-release-reason v-locust) 'outer-pivot)
  (check-true  "l87b-5c-locust-attrition-zone-blacklisted"
               (choke-attrition-zone-blacklisted? cst (cons 100.0 100.0) 12050)))

(printf "\n=============================================================================\n")
(printf "l87-anti-drip-and-siege-test: ~a PASSED, ~a FAILED\n" pass-count fail-count)
(printf "=============================================================================\n")
(when (> fail-count 0) (exit 1))
