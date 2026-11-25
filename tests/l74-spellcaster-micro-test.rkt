#lang racket/base

;; =============================================================================
;; Loop 74 Lane C Verification Suite (`lib/tactics/`)
;; Covers:
;;   1. C1a: Hydralisk Transfuse (`missing-hp >= 35.0`, `< 0.72` HP, `13.5t` post-4m approach)
;;   2. C1b: Viper Consume-First (`en < 75.0`, `32.0t` search, `10.0t` safety) & `75..99e` Abduct
;;   3. C2a: Abandoned `siege-tank-sieged` Emergency Unsiege-Retreat (`0` screen in `8t`, enemy `< 6t`,
;;           `48f` dwell) & friendly Bio/Bunker preservation
;;   4. C2b: Liberator Defender Mode (`2558` point-target clamped `<= 4.8t`) & Fighter Unsiege (`2560`
;;           no-target, `64f` dwell), plus real wire translation with `0` rejects
;;   5. C3:  Medivac Focus-Fire Bio Rescue (`0.22` single-attacker preserved for `w11-tac-5` vs
;;           `0.35` under `>= 2` attackers focus-fire)
;; =============================================================================

(require racket/list
         racket/math
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/tactics/unit-mode-micro.rkt"
         "../lib/tactics/transport-drop-micro.rkt"
         "../lib/sc2-protobuf-ws.rkt")

(define tests-run 0)
(define tests-failed 0)

(define (check-true name pred [detail ""])
  (set! tests-run (+ tests-run 1))
  (unless pred
    (set! tests-failed (+ tests-failed 1))
    (eprintf "FAIL [~a]: ~a\n" name detail)))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-u id type x y
              #:hp [hp 100.0]
              #:max-hp [max-hp hp]
              #:shield [shield 0.0]
              #:max-shield [max-shield shield]
              #:energy [energy 0.0]
              #:flying [flying? #f]
              #:is-building [is-building? #f])
  (hash 'id id 'tag id 'type type 'x x 'y y
        'hp hp 'hull-hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield
        'energy energy
        'flying? flying? 'is-flying flying?
        'is-building is-building? 'building? is-building?))

(define (mk-raw-u tag utype alliance x y #:hp [hp 100.0] #:max-hp [max-hp hp] #:flying [fly? #f])
  (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
            (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 0.75 1.0 0 #f #f #f
            hp max-hp 0.0 0.0 0.0 0.0 0 0 fly? #f #f #t #f
            '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))

;; -----------------------------------------------------------------------------
;; 1. C1a: Hydralisk Transfuse (`>= 35` missing HP, `13.5t` post-4m approach)
;; -----------------------------------------------------------------------------
(let ()
  (define q1 (mk-u 1001 'queen 50.0 50.0 #:hp 175.0 #:max-hp 175.0 #:energy 55.0))
  (define hydra-50 (mk-u 1002 'hydralisk 63.0 50.0 #:hp 50.0 #:max-hp 90.0))
  (define hydra-70 (mk-u 1003 'hydralisk 55.0 50.0 #:hp 70.0 #:max-hp 90.0))
  (define roach-105 (mk-u 1004 'roach 55.0 50.0 #:hp 105.0 #:max-hp 145.0))

  (define d-hydra50
    (plan-zerg-spellcaster-micro (list q1 hydra-50) '() #:current-frame 6000))
  (check-true "l74-c1-queen-transfuses-50hp-hydralisk-at-13t-post-4m"
              (and (= (length d-hydra50) 1)
                   (eq? (spell-directive-ability (first d-hydra50)) 'transfusion)
                   (= (spell-directive-target-tag (first d-hydra50)) 1002))
              (format "d-hydra50=~a" d-hydra50))

  (define d-hydra70
    (plan-zerg-spellcaster-micro (list q1 hydra-70) '() #:current-frame 6000))
  (check-true "l74-c1-queen-skips-70hp-hydralisk-missing-only-20"
              (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'transfusion)) d-hydra70))
              (format "d-hydra70=~a" d-hydra70))

  (define d-roach105
    (plan-zerg-spellcaster-micro (list q1 roach-105) '() #:current-frame 6000))
  (check-true "l74-c1-non-hydralisk-still-requires-50-missing-hp"
              (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'transfusion)) d-roach105))
              (format "d-roach105=~a" d-roach105)))

;; -----------------------------------------------------------------------------
;; 2. C1b: Viper Consume-First (`en < 75.0`) & `75..99e` Abduct
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 50e Viper out of 10t enemy range Consumes 1000-HP Hatchery 28t away
  (define vip-50 (mk-u 2001 'viper 50.0 50.0 #:hp 150.0 #:max-hp 150.0 #:energy 50.0 #:flying #t))
  (define hatch-far (mk-u 2010 'hatchery 22.0 50.0 #:hp 1000.0 #:max-hp 1500.0 #:is-building #t))
  (define enemy-115 (mk-u 2901 'marine 61.5 50.0 #:hp 45.0 #:max-hp 45.0))
  (define d-cons
    (plan-zerg-spellcaster-micro (list vip-50) (list enemy-115)
                                 #:ally-buildings (list hatch-far)
                                 #:current-frame 9000))
  (check-true "l74-c1-50e-viper-consumes-hatchery-28t-away-first"
              (and (= (length d-cons) 1)
                   (eq? (spell-directive-ability (first d-cons)) 'viper-consume)
                   (= (spell-directive-target-tag (first d-cons)) 2010))
              (format "d-cons=~a" d-cons))

  ;; (b) 80e Viper with 2 friendly Roaches within 10t Abducts a Sieged Tank at 10.5t
  (define vip-80 (mk-u 2002 'viper 50.0 50.0 #:hp 150.0 #:max-hp 150.0 #:energy 80.0 #:flying #t))
  (define roach-a (mk-u 2021 'roach 42.0 50.0 #:hp 145.0 #:max-hp 145.0))
  (define roach-b (mk-u 2022 'roach 42.5 51.0 #:hp 145.0 #:max-hp 145.0))
  (define enemy-tank (mk-u 2902 'siege-tank-sieged 60.5 50.0 #:hp 175.0 #:max-hp 175.0))
  (define d-abd
    (plan-zerg-spellcaster-micro (list vip-80 roach-a roach-b) (list enemy-tank)
                                 #:current-frame 9050))
  (check-true "l74-c1-80e-viper-with-2-roaches-abducts-tank-at-10.5t"
              (and (= (length d-abd) 1)
                   (eq? (spell-directive-ability (first d-abd)) 'abduct)
                   (= (spell-directive-target-tag (first d-abd)) 2902))
              (format "d-abd=~a" d-abd))

  ;; (c) 110e Viper with >= 2 ranged enemies at 10.5t still casts Blinding Cloud ahead of Abduct
  (define vip-110 (mk-u 2003 'viper 50.0 50.0 #:hp 150.0 #:max-hp 150.0 #:energy 110.0 #:flying #t))
  (define enemy-tank2 (mk-u 2903 'siege-tank-sieged 60.5 51.0 #:hp 175.0 #:max-hp 175.0))
  (define d-bc
    (plan-zerg-spellcaster-micro (list vip-110 roach-a roach-b) (list enemy-tank enemy-tank2)
                                 #:current-frame 9100))
  (check-true "l74-c1-110e-viper-still-prioritizes-blinding-cloud-over-abduct"
              (and (= (length d-bc) 1)
                   (eq? (spell-directive-ability (first d-bc)) 'blinding-cloud))
              (format "d-bc=~a" d-bc)))

;; -----------------------------------------------------------------------------
;; 3. C2a: Abandoned `siege-tank-sieged` Emergency Unsiege-Retreat (Tightened Guards)
;; -----------------------------------------------------------------------------
(let ()
  (define tank-full (mk-u 3001 'siege-tank-sieged 70.0 70.0 #:hp 175.0 #:max-hp 175.0))
  (define tank-dmg  (mk-u 3002 'siege-tank-sieged 70.0 70.0 #:hp 100.0 #:max-hp 175.0))
  (define tank-sib  (mk-u 3003 'siege-tank-sieged 64.0 70.0 #:hp 175.0 #:max-hp 175.0))
  (define z-dead-1  (mk-u 3901 'zealot 72.5 70.0 #:hp 100.0 #:shield 50.0))
  (define r-close-1 (mk-u 3902 'roach  74.2 70.0 #:hp 145.0 #:max-hp 145.0))
  (define r-close-2 (mk-u 3903 'roach  74.2 70.8 #:hp 145.0 #:max-hp 145.0))
  (define r-active  (mk-u 3904 'roach  78.0 70.0 #:hp 145.0 #:max-hp 145.0))
  (define mar-1     (mk-u 3011 'marine 66.5 70.0 #:hp 45.0 #:max-hp 45.0))
  (define mar-2     (mk-u 3012 'marine 66.5 71.0 #:hp 45.0 #:max-hp 45.0))
  (define bnk-1     (mk-u 3013 'bunker 65.5 70.0 #:hp 400.0 #:max-hp 400.0 #:is-building #t))
  (define oc-base   (mk-u 3014 'orbital-command 58.0 70.0 #:hp 1500.0 #:max-hp 1500.0 #:is-building #t))
  (define cc-base   (mk-u 3015 'command-center  56.5 70.0 #:hp 1500.0 #:max-hp 1500.0 #:is-building #t))

  (define (has-unsiege? acts)
    (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'unsiege-mode)))
                acts)
         #t))
  (define (plan-unsiege-sexps allies enemies tr frame)
    (sync-unit-mode-tracker! tr allies enemies frame)
    (map unit-mode-directive->sexp
         (plan-siege-tank-emergency-unsiege allies enemies #:tracker tr #:current-frame frame)))

  ;; (a) Loop 80B: `step-unit-mode-micro!` does NOT auto-unsiege tanks in ladder fights,
  ;;     while the pure exported `plan-siege-tank-emergency-unsiege` helper still emits
  ;;     `(cast-spell 3001 'unsiege-mode)` for an isolated deadzone tank!
  (define acts-step-no-auto
    (step-unit-mode-micro! (list tank-full) (list z-dead-1)
                           #:tracker (make-unit-mode-tracker) #:current-frame 1000))
  (define tr-tk (make-unit-mode-tracker))
  (define acts-aband
    (plan-unsiege-sexps (list tank-full) (list z-dead-1) tr-tk 1000))
  (check-true "l74-c2-isolated-tank-unsieges-vs-deadzone-enemy"
              (and (not (has-unsiege? acts-step-no-auto))
                   (and (member '(cast-spell 3001 unsiege-mode) acts-aband) #t))
              (format "step=~a acts-aband=~a" acts-step-no-auto acts-aband))

  ;; (b) Dwell cooldown (112f): a freshly sieged tank (mobile at 950 -> sieged at 1000)
  ;;     stays locked at frame 1111 (111f < 112f) and unlocks at frame 1112 (112f >= 112f);
  ;;     repeat call after unsiege at frame 1020 is also blocked.
  (define tr-fresh (make-unit-mode-tracker))
  (define tank-mob (mk-u 3004 'siege-tank 70.0 70.0 #:hp 175.0 #:max-hp 175.0))
  (define tank-sg4 (mk-u 3004 'siege-tank-sieged 70.0 70.0 #:hp 175.0 #:max-hp 175.0))
  (sync-unit-mode-tracker! tr-fresh (list tank-mob) '() 950)
  (define acts-fresh-0
    (plan-unsiege-sexps (list tank-sg4) (list z-dead-1) tr-fresh 1000))
  (define acts-fresh-111
    (plan-unsiege-sexps (list tank-sg4) (list z-dead-1) tr-fresh 1111))
  (define acts-fresh-112
    (plan-unsiege-sexps (list tank-sg4) (list z-dead-1) tr-fresh 1112))
  (define acts-cd-repeat
    (plan-unsiege-sexps (list tank-full) (list z-dead-1) tr-tk 1020))
  (check-true "l74-c2-abandoned-tank-respects-112f-dwell-cooldown"
              (and (not (has-unsiege? acts-fresh-0))
                   (not (has-unsiege? acts-fresh-111))
                   (and (member '(cast-spell 3004 unsiege-mode) acts-fresh-112) #t)
                   (not (has-unsiege? acts-cd-repeat)))
              (format "f0=~a f111=~a f112=~a rep=~a"
                      acts-fresh-0 acts-fresh-111 acts-fresh-112 acts-cd-repeat))

  ;; (c) Isolated damaged Tank (< 65% HP) + >= 2 close ground threats (< 5.0t, outside 4.5t active band) -> unsieges;
  ;;     single threat at 4.2t does NOT trigger unsiege!
  (define acts-dmg-2
    (plan-unsiege-sexps (list tank-dmg) (list r-close-1 r-close-2)
                        (make-unit-mode-tracker) 1200))
  (define acts-dmg-1
    (plan-unsiege-sexps (list tank-dmg) (list r-close-1)
                        (make-unit-mode-tracker) 1200))
  (check-true "l74-c2-damaged-tank-requires-2-close-threats-under-5t"
              (and (and (member '(cast-spell 3002 unsiege-mode) acts-dmg-2) #t)
                   (not (has-unsiege? acts-dmg-1)))
              (format "dmg2=~a dmg1=~a" acts-dmg-2 acts-dmg-1))

  ;; (d) Base defense guard: Tank <= 14.0t from owned Orbital Command or Command Center NEVER unsieges!
  (define acts-oc
    (plan-unsiege-sexps (list tank-full oc-base) (list z-dead-1)
                        (make-unit-mode-tracker) 1250))
  (define acts-cc
    (plan-unsiege-sexps (list tank-dmg cc-base) (list r-close-1 r-close-2)
                        (make-unit-mode-tracker) 1250))
  (check-true "l74-c2-base-defending-tank-within-14t-never-unsieges"
              (and (not (has-unsiege? acts-oc))
                   (not (has-unsiege? acts-cc)))
              (format "oc=~a cc=~a" acts-oc acts-cc))

  ;; (e) Sibling Sieged Tank guard: another live sieged tank within <= 8.0t (6.0t) covers it -> stays sieged!
  (define acts-sib
    (plan-unsiege-sexps (list tank-full tank-sib) (list z-dead-1)
                        (make-unit-mode-tracker) 1300))
  (check-true "l74-c2-sibling-sieged-tank-within-8t-stays-sieged"
              (not (has-unsiege? acts-sib))
              (format "acts-sib=~a" acts-sib))

  ;; (f) Active siege firing guard: enemy in [4.5, 12.5]t splash firing range (8.0t) -> NEVER packs up mid-volley!
  (define acts-active
    (plan-unsiege-sexps (list tank-full) (list z-dead-1 r-active)
                        (make-unit-mode-tracker) 1350))
  (check-true "l74-c2-actively-shelling-tank-with-target-in-4.5-12.5t-never-unsieges"
              (not (has-unsiege? acts-active))
              (format "acts-active=~a" acts-active))

  ;; (g) Screened Tank (2 Marines at 3.5t) or Bunker within 8t -> stays sieged!
  (define acts-screened
    (plan-unsiege-sexps (list tank-full mar-1 mar-2) (list z-dead-1)
                        (make-unit-mode-tracker) 1400))
  (define acts-bunker
    (plan-unsiege-sexps (list tank-full bnk-1) (list z-dead-1)
                        (make-unit-mode-tracker) 1400))
  (check-true "l74-c2-screened-or-bunker-tank-never-unsieges"
              (and (not (has-unsiege? acts-screened))
                   (not (has-unsiege? acts-bunker)))
              (format "screened=~a bunker=~a" acts-screened acts-bunker)))

;; -----------------------------------------------------------------------------
;; 4. C2b: Liberator Defender Mode (`2558`), Fighter Unsiege (`2560`), & Wire Check
;; -----------------------------------------------------------------------------
(let ()
  (define lib-f (mk-u 3101 'liberator 70.0 70.0 #:hp 180.0 #:max-hp 180.0 #:flying #t))
  (define lib-d (mk-u 3102 'liberator-ag 70.0 70.0 #:hp 180.0 #:max-hp 180.0 #:flying #t))
  (define roaches-3
    (list (mk-u 3911 'roach 78.0 69.5 #:hp 145.0 #:max-hp 145.0)
          (mk-u 3912 'roach 78.0 70.0 #:hp 145.0 #:max-hp 145.0)
          (mk-u 3913 'roach 78.0 70.5 #:hp 145.0 #:max-hp 145.0)))
  (define mutas-3
    (list (mk-u 3921 'mutalisk 74.0 69.0 #:hp 120.0 #:max-hp 120.0 #:flying #t)
          (mk-u 3922 'mutalisk 74.0 70.0 #:hp 120.0 #:max-hp 120.0 #:flying #t)
          (mk-u 3923 'mutalisk 74.0 71.0 #:hp 120.0 #:max-hp 120.0 #:flying #t)))

  ;; (a) Liberator near 3 Roaches at 8.0t -> 5-element `(cast-spell 3101 'morph-liberator-ag tx ty)`
  ;;     with cast point clamped <= 4.8t!
  (define tr-lib (make-unit-mode-tracker))
  (define acts-ag
    (step-unit-mode-micro! (list lib-f) roaches-3 #:tracker tr-lib #:current-frame 2000))
  (define ag-cmd (and (pair? acts-ag) (first acts-ag)))
  (check-true "l74-c2-liberator-sieges-ag-5-elem-clamped-le-4.8t"
              (and (list? ag-cmd)
                   (= (length ag-cmd) 5)
                   (eq? (first ag-cmd) 'cast-spell)
                   (= (second ag-cmd) 3101)
                   (eq? (third ag-cmd) 'morph-liberator-ag)
                   (<= (dist2d 70.0 70.0 (fourth ag-cmd) (fifth ag-cmd)) 4.81))
              (format "acts-ag=~a" acts-ag))

  ;; (b) Liberator refuses to siege into Defender Mode when >= 3 uncontested enemy AA air <= 7t
  (define acts-aa-block
    (step-unit-mode-micro! (list lib-f) (append roaches-3 mutas-3)
                           #:tracker (make-unit-mode-tracker) #:current-frame 2000))
  (check-true "l74-c2-liberator-skips-ag-under-uncontested-mutalisks"
              (null? acts-aa-block)
              (format "acts-aa-block=~a" acts-aa-block))

  ;; (c) Liberator-AG with 0 ground enemies within 11.5t -> 3-element `(cast-spell 3102 'morph-liberator-aa)`
  (define tr-lib-d (make-unit-mode-tracker))
  (define acts-aa
    (step-unit-mode-micro! (list lib-d) '() #:tracker tr-lib-d #:current-frame 2100))
  (check-true "l74-c2-liberator-ag-unsieges-aa-3-elem-when-zone-empty"
              (equal? acts-aa '((cast-spell 3102 morph-liberator-aa)))
              (format "acts-aa=~a" acts-aa))

  ;; (d) Dwell cooldown (< 64f) blocks repeat unsiege spam
  (define acts-aa-cd
    (step-unit-mode-micro! (list lib-d) '() #:tracker tr-lib-d #:current-frame 2120))
  (check-true "l74-c2-liberator-respects-64f-dwell-cooldown"
              (null? acts-aa-cd)
              (format "acts-aa-cd=~a" acts-aa-cd))

  ;; (e) Full wire translation verification (`2558` point-target, `2560` & `390` no-target, `0` rejects!)
  (reset-typed-command-gate-stats!)
  (define wire-obs
    (sc2-observation 2200 (sc2-player-common 1 200 100 40 20 12 12 0 0 0 0)
                     (list (mk-raw-u 3101 689 1 70.0 70.0 #:hp 180.0 #:flying #t)
                           (mk-raw-u 3102 734 1 70.0 70.0 #:hp 180.0 #:flying #t)
                           (mk-raw-u 3001 32  1 70.0 70.0 #:hp 175.0 #:flying #f))
                     '() '() #f '() '() '() '() '() '()))
  (define wire-cmds
    (translate-bot-actions->sc2-raw-commands
     (list ag-cmd
           '(cast-spell 3102 morph-liberator-aa)
           '(cast-spell 3001 unsiege-mode))
     wire-obs))
  (define c-2558 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2558))) wire-cmds))
  (define c-2560 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2560))) wire-cmds))
  (define c-390  (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 390))) wire-cmds))
  (check-true "l74-c2-wire-translates-2558-2560-390-with-zero-rejects"
              (and (= (get-total-bot-action-reject-count) 0)
                   (sc2-raw-unit-command? c-2558)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-2558))
                   (sc2-raw-unit-command? c-2560)
                   (not (sc2-raw-unit-command-target-pos c-2560))
                   (sc2-raw-unit-command? c-390)
                   (not (sc2-raw-unit-command-target-pos c-390)))
              (format "rej=~a cmds=~a" (get-total-bot-action-reject-count) wire-cmds)))

;; -----------------------------------------------------------------------------
;; 5. C3: Medivac Focus-Fire Bio Rescue (`w11-tac-5` preserved!)
;; -----------------------------------------------------------------------------
(let ()
  (define mar-30pct (mk-u 4001 'marauder 70.0 70.0 #:hp 37.5 #:max-hp 125.0))
  (define mar-20pct (mk-u 4002 'marauder 70.0 70.0 #:hp 25.0 #:max-hp 125.0))
  (define st-1 (mk-u 4901 'stalker 74.0 70.0 #:hp 80.0 #:shield 80.0))
  (define st-2 (mk-u 4902 'stalker 74.0 71.0 #:hp 80.0 #:shield 80.0))
  (define st-3 (mk-u 4903 'stalker 74.0 69.0 #:hp 80.0 #:shield 80.0))
  (define ult-1 (mk-u 4904 'ultralisk 71.2 70.0 #:hp 500.0 #:max-hp 500.0))

  ;; (a) 30% HP Marauder vs 1 attacker, no AoE -> stays fighting under Medivac heal beam (`score = 0.0`)!
  (define sc-1atk
    (save-pickup-candidate-priority 'medivac mar-30pct (list st-1) '() 8))
  (check-true "l74-c3-30pct-marauder-with-1-attacker-stays-under-medivac-heal"
              (= sc-1atk 0.0)
              (format "Expected 0.0 (w11-tac-5 preserved), got ~a" sc-1atk))

  ;; (b) Loop 80B: 30% HP Marauder stays fighting under Medivac heal beam (`0.22` threshold restored; `score = 0.0`)!
  (define sc-3atk
    (save-pickup-candidate-priority 'medivac mar-30pct (list st-1 st-2 st-3) '() 8))
  (check-true "l74-c3-30pct-marauder-stays-fighting-at-0.22-threshold"
              (= sc-3atk 0.0)
              (format "Expected 0.0 at 30%% HP (Loop 80B 0.22 threshold), got ~a" sc-3atk))

  ;; (c) 20% HP Marauder (< 0.22) vs 1 Ultralisk (`novel-84`) -> still rescued (`score > 0.0`)!
  (define sc-20pct
    (save-pickup-candidate-priority 'medivac mar-20pct (list ult-1) '() 8))
  (check-true "l74-c3-20pct-marauder-still-rescued-unconditionally"
              (> sc-20pct 0.0)
              (format "Expected > 0.0 at 20%% HP, got ~a" sc-20pct)))

(printf "l74-spellcaster-micro-test: ~a/~a passed\n" (- tests-run tests-failed) tests-run)
(when (> tests-failed 0)
  (exit 1))
