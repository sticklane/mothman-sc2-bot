#lang racket/base

;; =============================================================================
;; Loop 68 Lane C Verification Suite (`lib/tactics/`)
;; Covers:
;;   1. C1.1 / C1.3: Zero unconditional Overseer auto-Oversight oscillation
;;   2. C1.1 / C1.2: Map-wide cloak/burrow/stealth immediate OverseerSiegeMode unmorph
;;   3. C1.3: Explicit `oversight-desired?` opt-in guard (allowed only when safe & no cloak/burrow)
;;   4. C2.1 / C2.2 / C2.3: Range-10/14 Tempest arena discovery (`19.5t <= 21.0t`) &
;;      AA closure (`attack-unit`) under `DisengageRetreat` for Vikings/Corruptors/Stalkers
;;   5. C2.3: Ground `< 0.85x` `DisengageRetreat` strictly preserved (`2` Stalkers vs `6` Marauders)
;; =============================================================================

(require racket/list
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/tactics/arena-minimax.rkt")

(define tests-run 0)
(define tests-failed 0)

(define (check-true name pred [detail ""])
  (set! tests-run (+ tests-run 1))
  (unless pred
    (set! tests-failed (+ tests-failed 1))
    (eprintf "FAIL [~a]: ~a\n" name detail)))

(define (mk-u id type x y
              #:hp [hp 100.0]
              #:max-hp [max-hp hp]
              #:shield [shield 0.0]
              #:max-shield [max-shield shield]
              #:energy [energy 0.0]
              #:flying [flying? #f]
              #:cloak [cloak #f]
              #:cloaked [cloaked? #f]
              #:burrowed [burrowed? #f]
              #:display-type [display-type 1]
              #:weapon-cooldown [wcd 0.0]
              #:oversight-desired? [oversight-desired? #f]
              #:has-oversight-key? [has-oversight-key? #f])
  (define base
    (hash 'id id 'tag id 'type type 'x x 'y y
          'hp hp 'hull-hp hp 'max-hp max-hp
          'shield shield 'shields shield 'max-shield max-shield
          'energy energy 'flying? flying? 'is-flying flying?
          'display-type display-type
          'weapon-cooldown wcd))
  (define h1 (if cloak (hash-set base 'cloak cloak) base))
  (define h2 (if cloaked? (hash-set h1 'cloaked #t) h1))
  (define h3 (if burrowed? (hash-set h2 'burrowed #t) h2))
  (if (or oversight-desired? has-oversight-key?)
      (hash-set h3 'oversight-desired? oversight-desired?)
      h3))

(define (abilities-of dirs)
  (map spell-directive-ability dirs))

;; -----------------------------------------------------------------------------
;; 1. Zero Auto-Oversight Oscillation (C1.3)
;; -----------------------------------------------------------------------------
(let ()
  (define ov-absent
    (mk-u 1001 'overseer 55.0 55.0 #:hp 200.0 #:energy 20.0 #:flying #t))
  (define dirs-absent
    (plan-zerg-spellcaster-micro (list ov-absent) '()
                                 #:current-frame 4200
                                 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-no-auto-oversight-when-flag-absent"
              (null? dirs-absent)
              (format "Expected no directives for mobile overseer (>25t from home, en=20, 0 enemies), got ~a"
                      (abilities-of dirs-absent)))

  (define ov-false
    (mk-u 1002 'overseer 55.0 55.0 #:hp 200.0 #:energy 20.0 #:flying #t
          #:oversight-desired? #f #:has-oversight-key? #t))
  (define dirs-false
    (plan-zerg-spellcaster-micro (list ov-false) '()
                                 #:current-frame 4216
                                 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-no-auto-oversight-when-flag-false"
              (null? dirs-false)
              (format "Expected no directives when oversight-desired?=#f, got ~a"
                      (abilities-of dirs-false))))

;; -----------------------------------------------------------------------------
;; 2. Map-Wide Cloak/Burrow & Non-Desired Immediate Unmorph (C1.1 + C1.2)
;; -----------------------------------------------------------------------------
(let ()
  (define rooted-wanted
    (mk-u 2001 'overseer-siege-mode 55.0 55.0 #:hp 200.0 #:energy 20.0 #:flying #t
          #:oversight-desired? #t))
  (define rooted-unwanted
    (mk-u 2002 'overseer-siege-mode 55.0 55.0 #:hp 200.0 #:energy 20.0 #:flying #t))

  ;; (a) Cloaked Banshee 45t away (aa-near? = #f) -> immediate morph-overseer-mode
  (define far-banshee
    (mk-u 2901 'banshee 100.0 55.0 #:hp 140.0 #:flying #t #:cloak 1 #:cloaked #t))
  (define d-banshee
    (plan-zerg-spellcaster-micro (list rooted-wanted) (list far-banshee)
                                 #:current-frame 5000 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-rooted-overseer-unmorphs-on-far-cloaked-banshee"
              (equal? (abilities-of d-banshee) '(morph-overseer-mode))
              (format "Expected '(morph-overseer-mode) vs cloaked Banshee 45t away, got ~a"
                      (abilities-of d-banshee)))

  ;; (b) Burrowed Lurker 50t away -> immediate morph-overseer-mode
  (define far-lurker
    (mk-u 2902 'lurker-burrowed 105.0 55.0 #:hp 200.0 #:burrowed #t))
  (define d-lurker
    (plan-zerg-spellcaster-micro (list rooted-wanted) (list far-lurker)
                                 #:current-frame 5016 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-rooted-overseer-unmorphs-on-far-burrowed-lurker"
              (equal? (abilities-of d-lurker) '(morph-overseer-mode))
              (format "Expected '(morph-overseer-mode) vs burrowed Lurker 50t away, got ~a"
                      (abilities-of d-lurker)))

  ;; (c) Hidden display-type=3 enemy 50t away -> immediate morph-overseer-mode
  (define far-hidden
    (mk-u 2903 'marine 105.0 55.0 #:hp 45.0 #:display-type 3))
  (define d-hidden
    (plan-zerg-spellcaster-micro (list rooted-wanted) (list far-hidden)
                                 #:current-frame 5032 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-rooted-overseer-unmorphs-on-hidden-display-type-3"
              (equal? (abilities-of d-hidden) '(morph-overseer-mode))
              (format "Expected '(morph-overseer-mode) vs display-type=3 enemy, got ~a"
                      (abilities-of d-hidden)))

  ;; (d) 0 enemies and oversight-desired? absent -> unmorph immediately to restore mobility
  (define d-unwanted
    (plan-zerg-spellcaster-micro (list rooted-unwanted) '()
                                 #:current-frame 5048 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-rooted-overseer-unmorphs-when-oversight-not-desired"
              (equal? (abilities-of d-unwanted) '(morph-overseer-mode))
              (format "Expected '(morph-overseer-mode) when oversight-desired? absent, got ~a"
                      (abilities-of d-unwanted)))

  ;; (e) Burrowed Roach (type 'roach-burrowed only, without explicit 'burrowed flag) -> immediate unmorph
  (define far-roach-burrowed
    (mk-u 2905 'roach-burrowed 105.0 55.0 #:hp 145.0))
  (define d-roach-b
    (plan-zerg-spellcaster-micro (list rooted-wanted) (list far-roach-burrowed)
                                 #:current-frame 5060 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-rooted-overseer-unmorphs-on-raw-roach-burrowed-type"
              (equal? (abilities-of d-roach-b) '(morph-overseer-mode))
              (format "Expected '(morph-overseer-mode) vs raw 'roach-burrowed type, got ~a"
                      (abilities-of d-roach-b)))

  ;; (f) Creep Tumor excluded from cloak/burrow trigger -> rooted + oversight-desired? stays rooted
  (define far-tumor
    (mk-u 2904 'creep-tumor-burrowed 80.0 55.0 #:hp 50.0 #:burrowed #t))
  (define d-tumor
    (plan-zerg-spellcaster-micro (list rooted-wanted) (list far-tumor)
                                 #:current-frame 5064 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-creep-tumor-does-not-false-trigger-overseer-unmorph"
              (not (memq 'morph-overseer-mode (abilities-of d-tumor)))
              (format "Creep tumor must not trigger unmorph when oversight-desired?=#t; got ~a"
                      (abilities-of d-tumor))))

;; -----------------------------------------------------------------------------
;; 3. Explicit `oversight-desired? = #t` Guard (C1.3)
;; -----------------------------------------------------------------------------
(let ()
  (define ov-optin
    (mk-u 3001 'overseer 55.0 55.0 #:hp 200.0 #:energy 20.0 #:flying #t
          #:oversight-desired? #t))
  (define far-marine (mk-u 3901 'marine 95.0 55.0 #:hp 45.0))
  (define near-marine (mk-u 3902 'marine 62.0 55.0 #:hp 45.0))
  (define far-dt (mk-u 3903 'dark-templar 105.0 55.0 #:hp 40.0 #:shield 80.0))
  (define far-banshee (mk-u 3904 'banshee 105.0 55.0 #:hp 140.0 #:flying #t))
  (define far-wm (mk-u 3905 'widow-mine-burrowed 105.0 55.0 #:hp 90.0 #:burrowed #t))

  ;; Safe + no cloak/burrow -> emits morph-oversight-mode
  (define d-ok
    (plan-zerg-spellcaster-micro (list ov-optin) (list far-marine)
                                 #:current-frame 6000 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-explicit-oversight-allowed-when-safe-and-no-cloak"
              (equal? (abilities-of d-ok) '(morph-oversight-mode))
              (format "Expected '(morph-oversight-mode) when safe & no cloak/burrow, got ~a"
                      (abilities-of d-ok)))

  ;; Suppressed when Dark Templar exists anywhere on map
  (define d-dt
    (plan-zerg-spellcaster-micro (list ov-optin) (list far-dt)
                                 #:current-frame 6016 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-explicit-oversight-suppressed-by-far-dark-templar"
              (not (memq 'morph-oversight-mode (abilities-of d-dt)))
              (format "Expected no morph-oversight-mode with DT on map, got ~a"
                      (abilities-of d-dt)))

  ;; Suppressed when Banshee exists anywhere on map
  (define d-ban
    (plan-zerg-spellcaster-micro (list ov-optin) (list far-banshee)
                                 #:current-frame 6032 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-explicit-oversight-suppressed-by-far-banshee"
              (not (memq 'morph-oversight-mode (abilities-of d-ban)))
              (format "Expected no morph-oversight-mode with Banshee on map, got ~a"
                      (abilities-of d-ban)))

  ;; Suppressed when Widow Mine exists anywhere on map
  (define d-wm
    (plan-zerg-spellcaster-micro (list ov-optin) (list far-wm)
                                 #:current-frame 6048 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-explicit-oversight-suppressed-by-far-widow-mine"
              (not (memq 'morph-oversight-mode (abilities-of d-wm)))
              (format "Expected no morph-oversight-mode with Widow Mine on map, got ~a"
                      (abilities-of d-wm)))

  ;; Suppressed when AA is within 10.8t
  (define d-aa
    (plan-zerg-spellcaster-micro (list ov-optin) (list near-marine)
                                 #:current-frame 6064 #:home-x 20.0 #:home-y 20.0))
  (check-true "L68-C1-explicit-oversight-suppressed-by-near-aa"
              (not (memq 'morph-oversight-mode (abilities-of d-aa)))
              (format "Expected no morph-oversight-mode with AA within 10.8t, got ~a"
                      (abilities-of d-aa))))

;; -----------------------------------------------------------------------------
;; 4. Tempest Range-10/14 Arena Discovery (`19.5t`) & AA Closure (C2.1 + C2.2 + C2.3)
;; -----------------------------------------------------------------------------
(let ()
  (define (mk-arena-obs frame allies enemies)
    (hash 'frame frame
          'base-x 20.0 'base-y 20.0
          'natural-x 38.0 'natural-y 22.0
          'enemy-base-x 140.0 'enemy-base-y 140.0
          'ally-units allies
          'enemy-units enemies
          'enemy-buildings '()
          'map-width 160 'map-height 160))

  (define tempests-3
    (list (mk-u 4901 'tempest 79.5 59.5 #:hp 200.0 #:shield 100.0 #:flying #t)
          (mk-u 4902 'tempest 79.5 60.0 #:hp 200.0 #:shield 100.0 #:flying #t)
          (mk-u 4903 'tempest 79.5 60.5 #:hp 200.0 #:shield 100.0 #:flying #t)))

  ;; (a) Arena discovery at 19.5t includes all 3 Tempests without double-counting in reinforcing-enemies
  (define vikings-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 4101 i) 'viking-fighter 60.0 (+ 59.25 (* 0.5 i)) #:hp 135.0 #:flying #t)))
  (define arenas-195 (cluster-tactical-arenas vikings-4 tempests-3 '()))
  (check-true "L68-C2-arena-discovers-tempests-at-19.5t-no-reinf-dup"
              (and (= (length arenas-195) 1)
                   (= (length (tactical-arena-enemy-units (car arenas-195))) 3)
                   (= (length (tactical-arena-reinforcing-enemies (car arenas-195))) 0))
              (format "arenas=~a e=~a re=~a"
                      (length arenas-195)
                      (and (pair? arenas-195) (length (tactical-arena-enemy-units (car arenas-195))))
                      (and (pair? arenas-195) (length (tactical-arena-reinforcing-enemies (car arenas-195))))))

  ;; (b) 4 Vikings under DisengageRetreat vs 3 Tempests at 19.5t -> ALL 4 emit attack-unit (0 kite)
  (define-values (acts-vik4 _tags-vik4 decs-vik4)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 8000 vikings-4 tempests-3)
                                 #:combat-should-engage? #f
                                 #:defending-home? #f))
  (define vik4-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-vik4))
  (define vik4-kites (filter (lambda (a) (and (pair? a) (memq (car a) '(kite move)))) acts-vik4))
  (check-true "L68-C2-4-vikings-disengage-close-on-tempests-at-19.5t"
              (and (pair? decs-vik4)
                   (eq? (hash-ref (car decs-vik4) 'committed-action #f) 'DisengageRetreat)
                   (= (length vik4-atks) 4)
                   (null? vik4-kites)
                   (andmap (lambda (a) (memv (caddr a) '(4901 4902 4903))) vik4-atks))
              (format "decs=~a acts=~a" decs-vik4 acts-vik4))

  ;; (c) 2 dedicated AA flyers (Vikings & Corruptors) under DisengageRetreat vs 3 Tempests at 19.5t -> attack-unit
  (define vikings-2 (take vikings-4 2))
  (define-values (acts-vik2 _t2 decs-vik2)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 8016 vikings-2 tempests-3)
                                 #:combat-should-engage? #f
                                 #:defending-home? #f))
  (define corruptors-2
    (list (mk-u 4201 'corruptor 60.0 59.5 #:hp 200.0 #:flying #t)
          (mk-u 4202 'corruptor 60.0 60.5 #:hp 200.0 #:flying #t)))
  (define-values (acts-cor2 _tc2 decs-cor2)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 8032 corruptors-2 tempests-3)
                                 #:combat-should-engage? #f
                                 #:defending-home? #f))
  (check-true "L68-C2-2-aa-flyers-disengage-close-on-tempests-at-19.5t"
              (and (= (length (filter (lambda (a) (eq? (car a) 'attack-unit)) acts-vik2)) 2)
                   (= (length (filter (lambda (a) (eq? (car a) 'attack-unit)) acts-cor2)) 2))
              (format "vik2=~a cor2=~a" acts-vik2 acts-cor2))

  ;; (d) 4 Stalkers under DisengageRetreat vs 3 Tempests at 19.5t -> ALL 4 emit attack-unit (0 kite)
  (define stalkers-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 4301 i) 'stalker 60.0 (+ 59.25 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define-values (acts-st4 _ts4 decs-st4)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 8048 stalkers-4 tempests-3)
                                 #:combat-should-engage? #f
                                 #:defending-home? #f))
  (define st4-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-st4))
  (define st4-kites (filter (lambda (a) (and (pair? a) (memq (car a) '(kite move)))) acts-st4))
  (check-true "L68-C2-4-stalkers-disengage-close-on-tempests-at-19.5t"
              (and (pair? decs-st4)
                   (eq? (hash-ref (car decs-st4) 'committed-action #f) 'DisengageRetreat)
                   (= (length st4-atks) 4)
                   (null? st4-kites)
                   (andmap (lambda (a) (memv (caddr a) '(4901 4902 4903))) st4-atks))
              (format "decs=~a acts=~a" decs-st4 acts-st4))

  ;; (e) Ground-only Roaches (air-dps=0) vs 3 Tempests at 19.5t MUST NOT suicide attack-unit
  (define roaches-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 4401 i) 'roach 60.0 (+ 59.25 (* 0.5 i)) #:hp 145.0)))
  (define-values (acts-r4 _tr4 _decs-r4)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 8064 roaches-4 tempests-3)
                                 #:combat-should-engage? #f
                                 #:defending-home? #f))
  (check-true "L68-C2-ground-only-roaches-never-suicide-dive-tempests"
              (null? (filter (lambda (a) (eq? (car a) 'attack-unit)) acts-r4))
              (format "Ground-only Roaches must not emit attack-unit vs Tempests; acts=~a" acts-r4))

  ;; ---------------------------------------------------------------------------
  ;; 5. Ground `< 0.85x` DisengageRetreat Strictly Preserved (C2.3)
  ;; ---------------------------------------------------------------------------
  (define stalkers-2
    (list (mk-u 5101 'stalker 60.0 59.5 #:hp 80.0 #:shield 80.0)
          (mk-u 5102 'stalker 60.0 60.5 #:hp 80.0 #:shield 80.0)))
  (define marauders-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 5901 i) 'marauder 72.0 (+ 58.75 (* 0.5 i)) #:hp 125.0)))

  ;; Forced DisengageRetreat
  (define-values (acts-gnd-forced _tg1 decs-gnd-forced)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 9000 stalkers-2 marauders-6)
                                 #:combat-should-engage? #f
                                 #:defending-home? #f))
  (define gnd-forced-kites (filter (lambda (a) (and (pair? a) (eq? (car a) 'kite))) acts-gnd-forced))
  (define gnd-forced-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-gnd-forced))
  (check-true "L68-C2-2-stalkers-vs-6-marauders-at-12t-clean-disengage"
              (and (pair? decs-gnd-forced)
                   (eq? (hash-ref (car decs-gnd-forced) 'committed-action #f) 'DisengageRetreat)
                   (= (length gnd-forced-kites) 2)
                   (null? gnd-forced-atks))
              (format "decs=~a acts=~a" decs-gnd-forced acts-gnd-forced))

  ;; Natural minimax (outnumbered 2 Stalkers vs 6 Marauders at 12.0t)
  (define-values (acts-gnd-nat _tg2 decs-gnd-nat)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain)
                                 (mk-arena-obs 9016 stalkers-2 marauders-6)
                                 #:combat-should-engage? #t
                                 #:defending-home? #f))
  (define gnd-nat-kites (filter (lambda (a) (and (pair? a) (eq? (car a) 'kite))) acts-gnd-nat))
  (define gnd-nat-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-gnd-nat))
  (check-true "L68-C2-2-stalkers-vs-6-marauders-natural-minimax-disengage"
              (and (pair? decs-gnd-nat)
                   (eq? (hash-ref (car decs-gnd-nat) 'committed-action #f) 'DisengageRetreat)
                   (= (length gnd-nat-kites) 2)
                   (null? gnd-nat-atks))
              (format "decs=~a acts=~a" decs-gnd-nat acts-gnd-nat)))

(printf "l68-tactics-cloak-aa-test: ~a/~a passed\n" (- tests-run tests-failed) tests-run)
(when (> tests-failed 0)
  (exit 1))
