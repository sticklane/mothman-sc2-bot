#lang racket/base

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/sc2-placement.rkt"
         "../lib/opponent-world-model.rkt")

;; =============================================================================
;; Loop 37 (`L37-P0-2`) Terran Tank-Starvation, OC Scan/Turret, North-vs-South
;; 4-Corner Placement Symmetry (NW/NE/SW/SE), and ZvT Mobile-AA / Baneling Suite
;; =============================================================================

(define total-checks 0)
(define failed-checks 0)

(define (check-true name cond-val [detail ""])
  (set! total-checks (add1 total-checks))
  (unless cond-val
    (set! failed-checks (add1 failed-checks))
    (eprintf "FAIL [~a]: ~a\n" name detail)))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:cloak [cloak 3]
              #:flying? [flying? #f]
              #:build-progress [bp 1.0] #:order-count [oc 0]
              #:order-ability-id [oab 0]
              #:addon [addon #f]
              #:assigned-harvesters [ah 0] #:ideal-harvesters [ih 0])
  (define h
    (hash 'id id 'type type 'x x 'y y
          'hp hp 'max-hp max-hp
          'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
          'energy energy 'cloak cloak 'display-type 1
          'flying? flying? 'is-flying flying?
          'build-progress bp 'order-count oc 'order-ability-id oab
          'powered? #t
          'assigned-harvesters ah 'ideal-harvesters ih))
  (if addon (hash-set h 'addon addon) h))

(define (mk-mineral-arc bx by dir-x dir-y)
  ;; Places 8 mineral patches at ~6.5t in direction (dir-x, dir-y) from (bx, by)
  (define len (max 1e-6 (sqrt (+ (* dir-x dir-x) (* dir-y dir-y)))))
  (define ux (/ dir-x len))
  (define uy (/ dir-y len))
  (define px (- uy))
  (define py ux)
  (for/list ([i (in-range 8)])
    (define lat (* (- i 3.5) 1.3))
    (hash 'id (+ 90000 i)
          'x (+ bx (* 6.5 ux) (* lat px))
          'y (+ by (* 6.5 uy) (* lat py))
          'mineral-contents 1500)))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 100]
                     #:supply-used [su 44]
                     #:supply-cap [sc 70]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 56.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 140.0] #:enemy-y [ey 120.0]
                     #:mineral-patches [mps #f]
                     #:map-grids [mgrids #f])
  (define default-mps (or mps (mk-mineral-arc bx by -1.0 -1.0)))
  (define base-h
    (hash 'race race 'enemy-race enemy-race 'frame frame
          'live-obs? #t 'live-game? #t
          'mineral-harvesters 28 'gas-harvesters 6
          'minerals minerals 'gas gas
          'supply-used su 'supply-cap sc
          'ally-units au 'ally-buildings ab
          'enemy-units eu 'enemy-buildings eb
          'base-x bx 'base-y by 'nat-x nx 'nat-y ny
          'natural-x nx 'natural-y ny
          'enemy-x ex 'enemy-y ey
          'mineral-patches default-mps
          'expansion-pads (list (cons nx ny) (cons (+ bx (* 0.5 (- ex bx))) by))
          'map-width 168 'map-height 168))
  (if mgrids (hash-set base-h 'map-grids mgrids) base-h))

(define (find-build-cmd acts sym)
  (for/first ([a (in-list acts)]
              #:when (and (pair? a)
                          (memq (car a) '(build build-structure))
                          (>= (length a) 4)
                          (eq? (cadr a) sym)))
    a))

(define (has-build-sym? acts sym)
  (and (find-build-cmd acts sym) #t))

(define (has-train-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (memq (car a) '(train train-unit))
         (>= (length a) 2)
         (eq? (cadr a) sym))))

(define (count-morph-sym acts sym)
  (for/sum ([a (in-list acts)])
    (if (and (pair? a)
             (eq? (car a) 'morph)
             (>= (length a) 2)
             (or (eq? (cadr a) sym)
                 (and (>= (length a) 3) (eq? (caddr a) sym))))
        1
        0)))

(define (has-spell-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (eq? (car a) 'cast-spell)
         (>= (length a) 3)
         (eq? (caddr a) sym))))

(define (mk-rt race) (make-live-bot-runtime #:race race))
(define (run-acts! rt obs) (hash-ref (step-live-bot-runtime! rt obs) 'actions '()))

;; =============================================================================
;; 1. Terran Tank-Starvation Fix (`bot-runtime.rkt:19776-19779`), `[100M..150M)`
;;    Hold, & `Barracks #3+` Gate on `CC #2`
;; =============================================================================

;; L37-T1a: TvT 2-base Terran with ready Factory-TL, 0 Tanks, 175M/150G trains siege-tank FIRST
(let* ([rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 28)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [marines (for/list ([i (in-range 8)]) (mk-u (+ 100 i) 'marine 48.0 (+ 32.0 (* 0.4 i))))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 25.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                    (mk-u 202 'orbital-command 56.5 32.5 #:energy 25.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
                    (mk-u 203 'supply-depot 42.0 34.0)
                    (mk-u 204 'supply-depot 42.0 36.0)
                    (mk-u 205 'barracks 40.5 36.5)
                    (mk-u 206 'barracks 40.5 41.5)
                    (mk-u 207 'factory 38.5 30.5 #:addon 'factory-techlab)
                    (mk-u 208 'factory-techlab 41.0 30.0)
                    (mk-u 209 'starport 38.5 24.5)
                    (mk-u 210 'refinery 28.0 26.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                    (mk-u 211 'refinery 26.0 28.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                    (mk-u 212 'refinery 52.0 26.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                    (mk-u 213 'refinery 54.0 26.0 #:assigned-harvesters 3 #:ideal-harvesters 3))]
       [obs (mk-live-obs 'Terran 'Terran 6200
                         #:minerals 175 #:gas 150 #:supply-used 46 #:supply-cap 78
                         #:ally-units (append scvs marines)
                         #:ally-buildings bldgs
                         #:enemy-buildings (list (mk-u 950 'command-center 140.0 120.0)))]
       [res (step-live-bot-runtime! rt obs)]
       [acts (hash-ref res 'actions '())])
  (check-true "L37-T1a-tvt-trains-siege-tank-before-scv-or-marine"
              (has-train-sym? acts 'siege-tank)
              (format "acts=~a" acts)))

;; L37-T1b: TvT `[100M..150M)` hold (`min=120, gas=150`, ready Factory-TL, 0 Tanks) holds SCV/Marine
(let* ([rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 26)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [marines (for/list ([i (in-range 6)]) (mk-u (+ 100 i) 'marine 48.0 (+ 32.0 (* 0.4 i))))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 25.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                    (mk-u 202 'orbital-command 56.5 32.5 #:energy 25.0 #:assigned-harvesters 10 #:ideal-harvesters 16)
                    (mk-u 203 'supply-depot 42.0 34.0)
                    (mk-u 204 'supply-depot 42.0 36.0)
                    (mk-u 205 'barracks 40.5 36.5)
                    (mk-u 206 'factory 38.5 30.5 #:addon 'factory-techlab)
                    (mk-u 207 'factory-techlab 41.0 30.0))]
       [obs (mk-live-obs 'Terran 'Terran 5800
                         #:minerals 120 #:gas 150 #:supply-used 42 #:supply-cap 78
                         #:ally-units (append scvs marines)
                         #:ally-buildings bldgs)]
       [res (step-live-bot-runtime! rt obs)]
       [acts (hash-ref res 'actions '())])
  (check-true "L37-T1b-tvt-100-to-150m-holds-scv-and-marine-for-tank"
              (and (not (has-train-sym? acts 'scv))
                   (not (has-train-sym? acts 'marine))
                   (not (has-train-sym? acts 'marauder)))
              (format "acts=~a" acts)))

;; L37-T1c: TvP with Medivac #1 out, ready Factory-TL, 0 Tanks, 175M/140G trains siege-tank first
(let* ([rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 28)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [marines (for/list ([i (in-range 8)]) (mk-u (+ 100 i) 'marine 48.0 (+ 32.0 (* 0.4 i))))]
       [medivacs (list (mk-u 150 'medivac 46.0 32.0 #:flying? #t))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 25.0)
                    (mk-u 202 'orbital-command 56.5 32.5 #:energy 25.0)
                    (mk-u 203 'supply-depot 42.0 34.0)
                    (mk-u 204 'supply-depot 42.0 36.0)
                    (mk-u 205 'barracks 40.5 36.5 #:addon 'barracks-techlab)
                    (mk-u 206 'barracks-techlab 43.0 36.0)
                    (mk-u 207 'factory 38.5 30.5 #:addon 'factory-techlab)
                    (mk-u 208 'factory-techlab 41.0 30.0)
                    (mk-u 209 'starport 38.5 24.5)
                    (mk-u 210 'refinery 28.0 26.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                    (mk-u 211 'refinery 26.0 28.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                    (mk-u 212 'refinery 52.0 26.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                    (mk-u 213 'refinery 54.0 26.0 #:assigned-harvesters 3 #:ideal-harvesters 3))]
       [obs (mk-live-obs 'Terran 'Protoss 6200
                         #:minerals 175 #:gas 140 #:supply-used 48 #:supply-cap 78
                         #:ally-units (append scvs marines medivacs)
                         #:ally-buildings bldgs
                         #:enemy-buildings (list (mk-u 950 'nexus 140.0 120.0)))]
       [res (step-live-bot-runtime! rt obs)]
       [acts (hash-ref res 'actions '())])
  (check-true "L37-T1c-tvp-trains-siege-tank-priority"
              (has-train-sym? acts 'siege-tank)
              (format "acts=~a" acts)))

;; L37-T1d: Peaceful 1-base Terran with 2 Barracks & 350M does NOT build Barracks #3 before CC #2
(let* ([rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 20)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [marines (for/list ([i (in-range 6)]) (mk-u (+ 100 i) 'marine 44.0 (+ 32.0 (* 0.4 i))))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 25.0)
                    (mk-u 202 'supply-depot 42.0 34.0)
                    (mk-u 203 'supply-depot 42.0 36.0)
                    (mk-u 204 'barracks 40.5 36.5)
                    (mk-u 205 'barracks 40.5 41.5)
                    (mk-u 206 'factory 38.5 30.5)
                    (mk-u 207 'starport 38.5 24.5))]
       [obs (mk-live-obs 'Terran 'Protoss 4800
                         #:minerals 350 #:gas 50 #:supply-used 30 #:supply-cap 54
                         #:ally-units (append scvs marines)
                         #:ally-buildings bldgs)]
       [res (step-live-bot-runtime! rt obs)]
       [acts (hash-ref res 'actions '())])
  (check-true "L37-T1d-1base-gates-barracks3-on-cc2"
              (not (has-build-sym? acts 'barracks))
              (format "acts=~a" acts)))

;; =============================================================================
;; 2. Terran OC Scan Energy Reserve & Urgent Anti-DT Turret (`#74 TvP who`)
;; =============================================================================

;; L37-T2a: OC at 75e with OWM-known dark-templar & 0 ready Turrets suppresses MULE (reserves 50e scan)
(let* ([rt (mk-rt 'Terran)]
       ;; Prime OWM with an earlier DT observation at frame 5400
       [scvs (for/list ([i (in-range 24)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 75.0)
                    (mk-u 202 'command-center 56.5 32.5)
                    (mk-u 203 'supply-depot 42.0 34.0)
                    (mk-u 204 'barracks 40.5 36.5))]
       [obs1 (mk-live-obs 'Terran 'Protoss 5400
                          #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                          #:ally-units scvs #:ally-buildings bldgs
                          #:enemy-units (list (mk-u 901 'dark-templar 52.0 34.0 #:cloak 1)))]
       [_ (step-live-bot-runtime! rt obs1)]
       ;; Next step (frame 5500): DT briefly out of vision, OC at 75e, still 0 Turrets/0 Ravens
       [obs2 (mk-live-obs 'Terran 'Protoss 5500
                          #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                          #:ally-units scvs #:ally-buildings bldgs
                          #:enemy-units '())]
       [res2 (step-live-bot-runtime! rt obs2)]
       [acts2 (hash-ref res2 'actions '())])
  (check-true "L37-T2a-oc-75e-suppresses-mule-under-unturretted-dt-threat"
              (not (has-spell-sym? acts2 'calldown-mule))
              (format "acts2=~a" acts2)))

;; L37-T2b: OC at 105e under un-turreted DT threat (no visible DT) CAN cast MULE while keeping 55e banked
(let* ([rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 24)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 105.0)
                    (mk-u 202 'supply-depot 42.0 34.0)
                    (mk-u 203 'barracks 40.5 36.5))]
       [obs (mk-live-obs 'Terran 'Protoss 5500
                         #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                         #:ally-units scvs #:ally-buildings bldgs)]
       [res (step-live-bot-runtime! rt obs)]
       [acts (hash-ref res 'actions '())])
  (check-true "L37-T2b-oc-105e-casts-mule-keeping-50e-scan"
              (has-spell-sym? acts 'calldown-mule)
              (format "acts=~a" acts)))

;; L37-T2c: Ready EngineeringBay + DT threat at 120M emits missile-turret BEFORE Barracks/Starport/Reactor
(let* ([rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 24)]) (mk-u (+ 10 i) 'scv 30.0 (+ 30.0 (* 0.3 i))))]
       [bldgs (list (mk-u 201 'orbital-command 32.5 32.5 #:energy 40.0)
                    (mk-u 202 'orbital-command 56.5 32.5 #:energy 40.0)
                    (mk-u 203 'supply-depot 42.0 34.0)
                    (mk-u 204 'barracks 40.5 36.5)
                    (mk-u 205 'barracks 40.5 41.5)
                    (mk-u 206 'factory 38.5 30.5)
                    (mk-u 207 'engineering-bay 36.0 38.0))]
       [obs (mk-live-obs 'Terran 'Protoss 5800
                         #:minerals 120 #:gas 100 #:supply-used 34 #:supply-cap 62
                         #:ally-units scvs #:ally-buildings bldgs
                         #:enemy-units (list (mk-u 901 'dark-templar 54.0 32.5 #:cloak 2)))]
       [res (step-live-bot-runtime! rt obs)]
       [acts (hash-ref res 'actions '())])
  (check-true "L37-T2c-urgent-turret-beats-barracks-starport-reactor"
              (has-build-sym? acts 'missile-turret)
              (format "acts=~a" acts)))

;; =============================================================================
;; 3. North-vs-South 4-Corner Rotation Symmetry (`NW / NE / SW / SE`, `#846`)
;; =============================================================================

;; Corner specs: (name base-x base-y nat-x nat-y enemy-x enemy-y min-dx min-dy)
;; Note: `(away-x, away-y) = (-min-dx, -min-dy)` points into the safe main interior!
(define 4-corners
  (list (list 'SW  32.5  32.5  56.5  32.5 135.5 135.5 -1.0 -1.0)
        (list 'SE 135.5  32.5 111.5  32.5  32.5 135.5  1.0 -1.0)
        (list 'NE 135.5 135.5 111.5 135.5  32.5  32.5  1.0  1.0)
        (list 'NW  32.5 135.5  56.5 135.5 135.5  32.5 -1.0  1.0)))

;; L37-T3a: Terran SupplyDepot #3 stays strictly interior (dot with away > 0) on ALL 4 corners!
(let ([bad '()])
  (for ([c (in-list 4-corners)])
    (match-define (list cname bx by nx ny ex ey mdx mdy) c)
    (define away-x (- mdx))
    (define away-y (- mdy))
    (define mps (mk-mineral-arc bx by mdx mdy))
    (define rt (mk-rt 'Terran))
    (define scvs (for/list ([i (in-range 22)]) (mk-u (+ 10 i) 'scv bx by)))
    (define bldgs
      (list (mk-u 201 'orbital-command bx by #:energy 20.0)
            (mk-u 202 'supply-depot (+ bx (* 8.0 away-x)) (+ by (* 2.0 away-y)))
            (mk-u 203 'supply-depot (+ bx (* 8.0 away-x)) (+ by (* 5.0 away-y)))
            (mk-u 204 'barracks (+ bx (* 6.0 away-x)) (+ by (* 6.0 away-y)))))
    (define obs
      (mk-live-obs 'Terran 'Zerg 3600
                   #:minerals 200 #:gas 25 #:supply-used 28 #:supply-cap 31
                   #:ally-units scvs #:ally-buildings bldgs
                   #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
                   #:enemy-x ex #:enemy-y ey #:mineral-patches mps))
    (define acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '()))
    (define dep-cmd (find-build-cmd acts 'supply-depot))
    (unless (and dep-cmd
                 (let* ([dx (- (caddr dep-cmd) bx)]
                        [dy (- (cadddr dep-cmd) by)]
                        [dot (+ (* dx away-x) (* dy away-y))])
                   (> dot 0.5)))
      (set! bad (cons (list cname dep-cmd) bad))))
  (check-true "L37-T3a-terran-depot3-interior-all-4-corners"
              (null? bad)
              (format "non-interior corners: ~a" bad)))

;; L37-T3b: Protoss Pylon #2 stays strictly interior (dot with away > 0) on ALL 4 corners!
(let ([bad '()])
  (for ([c (in-list 4-corners)])
    (match-define (list cname bx by nx ny ex ey mdx mdy) c)
    (define away-x (- mdx))
    (define away-y (- mdy))
    (define mps (mk-mineral-arc bx by mdx mdy))
    (define rt (mk-rt 'Protoss))
    (define probes (for/list ([i (in-range 20)]) (mk-u (+ 10 i) 'probe bx by)))
    (define bldgs
      (list (mk-u 201 'nexus bx by)
            (mk-u 202 'pylon (+ bx (* 8.0 away-x)) (+ by (* 3.0 away-y)))
            (mk-u 203 'gateway (+ bx (* 6.0 away-x)) (+ by (* 5.0 away-y)))))
    (define obs
      (mk-live-obs 'Protoss 'Terran 2800
                   #:minerals 180 #:gas 25 #:supply-used 21 #:supply-cap 23
                   #:ally-units probes #:ally-buildings bldgs
                   #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
                   #:enemy-x ex #:enemy-y ey #:mineral-patches mps))
    (define acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '()))
    (define py-cmd (find-build-cmd acts 'pylon))
    (unless (and py-cmd
                 (let* ([dx (- (caddr py-cmd) bx)]
                        [dy (- (cadddr py-cmd) by)]
                        [dot (+ (* dx away-x) (* dy away-y))])
                   (> dot 0.5)))
      (set! bad (cons (list cname py-cmd) bad))))
  (check-true "L37-T3b-protoss-pylon2-interior-all-4-corners"
              (null? bad)
              (format "non-interior corners: ~a" bad)))

;; L37-T3c: `select-pylon-power-anchor` (sc2-placement.rkt) is interior on ALL 4 corners for Pylon #2 & Nat Pylon
(let ([bad '()])
  (for ([c (in-list 4-corners)])
    (match-define (list cname bx by nx ny _ex _ey mdx mdy) c)
    (define away-x (- mdx))
    (define away-y (- mdy))
    (define mps (mk-mineral-arc bx by mdx mdy))
    (define-values (p2x p2y _e2)
      (select-pylon-power-anchor #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
                                 #:protoss-pylon-count 1 #:active-bases 1
                                 #:mineral-patches mps))
    (define dot2 (+ (* (- p2x bx) away-x) (* (- p2y by) away-y)))
    ;; Nat Pylon (pylon-cnt=3, active-bases=2): should step from nat TOWARD base (interior)
    (define-values (pnx pny _en)
      (select-pylon-power-anchor #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
                                 #:protoss-pylon-count 3 #:active-bases 2
                                 #:mineral-patches mps))
    (define dot-nat (+ (* (- pnx nx) (- bx nx)) (* (- pny ny) (- by ny))))
    (unless (and (> dot2 0.5) (> dot-nat 0.5))
      (set! bad (cons (list cname p2x p2y dot2 pnx pny dot-nat) bad))))
  (check-true "L37-T3c-select-pylon-power-anchor-symmetric-all-4-corners"
              (null? bad)
              (format "bad corners: ~a" bad)))

;; L37-T3d: `solve-choke-wall-in` Protoss wall projects Pylon behind wall along (ramp-dx, ramp-dy) on all 4 quadrants
(let ([bad '()])
  (for ([rvec (in-list '((SW 1.0 1.0) (SE -1.0 1.0) (NE -1.0 -1.0) (NW 1.0 -1.0)))])
    (match-define (list cname rdx rdy) rvec)
    (define sol (solve-choke-wall-in 80.0 80.0 9 #:preset 'protoss-ffe #:ramp-dx rdx #:ramp-dy rdy))
    (define pls (hash-ref sol 'placements '()))
    (define pyl (findf (lambda (p) (eq? (hash-ref p 'type #f) 'pylon)) pls))
    (define gw  (findf (lambda (p) (eq? (hash-ref p 'type #f) 'gateway)) pls))
    (define dot-pyl (and pyl (+ (* (- (hash-ref pyl 'x 80.0) 80.0) rdx)
                                (* (- (hash-ref pyl 'y 80.0) 80.0) rdy))))
    (define dot-gw  (and gw  (+ (* (- (hash-ref gw 'x 80.0) 80.0) rdx)
                                (* (- (hash-ref gw 'y 80.0) 80.0) rdy))))
    (unless (and (wall-solution-valid-ref sol)
                 dot-pyl dot-gw
                 (< dot-pyl dot-gw))
      (set! bad (cons (list cname dot-pyl dot-gw) bad))))
  (check-true "L37-T3d-protoss-choke-wall-rotates-with-ramp-dir"
              (null? bad)
              (format "bad quadrants: ~a" bad)))

;; L37-T3e: Zerg SporeCrawler lands toward each base's mineral line on ALL 4 corners (not hardcoded +3,+3!)
(let ([bad '()])
  (for ([c (in-list 4-corners)])
    (match-define (list cname bx by nx ny ex ey mdx mdy) c)
    (define mps (mk-mineral-arc bx by mdx mdy))
    (define rt (mk-rt 'Zerg))
    (define drones (for/list ([i (in-range 22)]) (mk-u (+ 10 i) 'drone bx by)))
    (define queens (list (mk-u 80 'queen bx by) (mk-u 81 'queen (+ bx (* -3.0 mdx)) (+ by (* -3.0 mdy)))))
    (define bldgs (list (mk-u 201 'hatchery bx by)
                        (mk-u 202 'spawning-pool (+ bx (* -5.0 mdx)) (+ by (* -5.0 mdy)))
                        (mk-u 203 'extractor (+ bx (* 5.0 mdx)) (+ by (* 5.0 mdy)))
                        (mk-u 204 'extractor (+ bx (* 4.0 mdx)) (+ by (* 6.0 mdy)))))
    (define obs
      (mk-live-obs 'Zerg 'Terran 4800
                   #:minerals 150 #:gas 50 #:supply-used 28 #:supply-cap 44
                   #:ally-units (append drones queens (list (mk-u 150 'overlord bx by #:flying? #t)))
                   #:ally-buildings bldgs
                   #:enemy-units (list (mk-u 901 'banshee (+ bx (* -10.0 mdx)) (+ by (* -10.0 mdy)) #:flying? #t #:cloak 2))
                   #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
                   #:enemy-x ex #:enemy-y ey #:mineral-patches mps))
    (define acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '()))
    (define sp-cmd (find-build-cmd acts 'spore-crawler))
    (unless (and sp-cmd
                 (let* ([dx (- (caddr sp-cmd) bx)]
                        [dy (- (cadddr sp-cmd) by)]
                        [dot (+ (* dx mdx) (* dy mdy))])
                   (> dot 0.0)))
      (set! bad (cons (list cname sp-cmd) bad))))
  (check-true "L37-T3e-zerg-spore-crawler-tracks-mineral-line-all-4-corners"
              (null? bad)
              (format "bad corners: ~a" bad)))

;; L37-T3f: Terran SupplyDepot #3 with real buildable map-grids on NW routes through pro-simcity
(let* ([w 168] [h 168]
       [n (* w h)]
       [pgrid (make-bytes n 1)]
       [bgrid (make-bytes n 1)]
       [hgrid (make-bytes n 120)]
       ;; Put a high-ground plateau around NW (bx=32.5, by=135.5) and low-ground elsewhere
       [_ (for* ([y (in-range 110 158)] [x (in-range 12 62)])
            (bytes-set! hgrid (+ x (* y w)) 160))]
       ;; Mark a ramp/choke wall area buildable at high ground
       [mgrids (hash 'width w 'height h
                     'pathing-grid pgrid 'placement-grid bgrid 'terrain-height hgrid)]
       [bx 32.5] [by 135.5] [nx 56.5] [ny 135.5]
       [mps (mk-mineral-arc bx by -1.0 1.0)]
       [rt (mk-rt 'Terran)]
       [scvs (for/list ([i (in-range 22)]) (mk-u (+ 10 i) 'scv bx by))]
       [bldgs (list (mk-u 201 'orbital-command bx by #:energy 20.0)
                    (mk-u 202 'supply-depot 48.0 132.0)
                    (mk-u 203 'supply-depot 48.0 138.0)
                    (mk-u 204 'barracks 42.5 130.5))]
       [obs (mk-live-obs 'Terran 'Zerg 3800
                         #:minerals 200 #:gas 25 #:supply-used 28 #:supply-cap 31
                         #:ally-units scvs #:ally-buildings bldgs
                         #:base-x bx #:base-y by #:nat-x nx #:nat-y ny
                         #:enemy-x 135.5 #:enemy-y 32.5
                         #:mineral-patches mps #:map-grids mgrids)]
       [acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '())]
       [dep-cmd (find-build-cmd acts 'supply-depot)])
  (check-true "L37-T3f-terran-nw-depot3-uses-simcity-on-high-ground"
              (and dep-cmd
                   (let ([dx (exact-floor (caddr dep-cmd))]
                         [dy (exact-floor (cadddr dep-cmd))])
                     (and (>= dx 12) (< dx 62) (>= dy 110) (< dy 158)
                          (= (bytes-ref hgrid (+ dx (* dy w))) 160))))
              (format "dep-cmd=~a" dep-cmd)))

;; =============================================================================
;; 4. Zerg ZvT L2 Enforcement (`#25/#73` Banshees & `#34` Bio Banelings)
;; =============================================================================

;; L37-T4a: Confirmed single Banshee rushes Lair ahead of RoachWarren/BanelingNest
(let* ([rt (mk-rt 'Zerg)]
       [drones (for/list ([i (in-range 28)]) (mk-u (+ 10 i) 'drone 30.0 (+ 30.0 (* 0.3 i))))]
       [lings (for/list ([i (in-range 8)]) (mk-u (+ 100 i) 'zergling 44.0 (+ 32.0 (* 0.4 i))))]
       [bldgs (list (mk-u 201 'hatchery 32.5 32.5)
                    (mk-u 202 'hatchery 56.5 32.5)
                    (mk-u 203 'spawning-pool 38.0 34.0)
                    (mk-u 204 'extractor 30.0 26.0))]
       [obs (mk-live-obs 'Zerg 'Terran 4200
                         #:minerals 180 #:gas 110 #:supply-used 36 #:supply-cap 52
                         #:ally-units (append drones lings)
                         #:ally-buildings bldgs
                         #:enemy-units (list (mk-u 901 'banshee 50.0 32.5 #:flying? #t)))]
       [acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '())])
  (check-true "L37-T4a-zvt-banshee-rushes-lair-ahead-of-rw-bn"
              (and (> (count-morph-sym acts 'lair) 0)
                   (not (has-build-sym? acts 'roach-warren))
                   (not (has-build-sym? acts 'baneling-nest)))
              (format "acts=~a" acts)))

;; L37-T4b: Confirmed Banshee + ready Lair at 150M/110G builds hydralisk-den (not blocked by 200G Spire!)
(let* ([rt (mk-rt 'Zerg)]
       [drones (for/list ([i (in-range 34)]) (mk-u (+ 10 i) 'drone 30.0 (+ 30.0 (* 0.3 i))))]
       [queens (for/list ([i (in-range 5)]) (mk-u (+ 80 i) 'queen 36.0 (+ 32.0 (* 0.5 i))))]
       [bldgs (list (mk-u 201 'lair 32.5 32.5)
                    (mk-u 202 'hatchery 56.5 32.5)
                    (mk-u 203 'spawning-pool 38.0 34.0)
                    (mk-u 204 'spore-crawler 29.0 29.0)
                    (mk-u 205 'spore-crawler 54.0 29.0))]
       [obs (mk-live-obs 'Zerg 'Terran 5600
                         #:minerals 160 #:gas 115 #:supply-used 46 #:supply-cap 66
                         #:ally-units (append drones queens (list (mk-u 150 'overseer 36.0 36.0 #:flying? #t)))
                         #:ally-buildings bldgs
                         #:enemy-units (list (mk-u 901 'banshee 46.0 32.5 #:flying? #t)
                                             (mk-u 902 'banshee 47.0 33.5 #:flying? #t)))]
       [acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '())])
  (check-true "L37-T4b-zvt-banshee-builds-hydra-den-at-115g"
              (has-build-sym? acts 'hydralisk-den)
              (format "acts=~a" acts)))

;; L37-T4c: Confirmed Banshee + ready HydraliskDen trains hydralisk (and ready Spire trains corruptor)
(let* ([rt1 (mk-rt 'Zerg)]
       [drones (for/list ([i (in-range 36)]) (mk-u (+ 10 i) 'drone 30.0 (+ 30.0 (* 0.3 i))))]
       [queens (for/list ([i (in-range 4)]) (mk-u (+ 80 i) 'queen 35.0 (+ 32.0 (* 0.5 i))))]
       [ovls (for/list ([i (in-range 4)]) (mk-u (+ 140 i) 'overlord 35.0 (+ 35.0 i) #:flying? #t))]
       [larvae (for/list ([i (in-range 5)]) (mk-u (+ 160 i) 'larva 34.0 (+ 32.0 (* 0.2 i))))]
       [bldgs1 (list (mk-u 201 'lair 32.5 32.5)
                     (mk-u 202 'hatchery 56.5 32.5)
                     (mk-u 203 'spawning-pool 38.0 34.0)
                     (mk-u 204 'hydralisk-den 38.0 38.0)
                     (mk-u 205 'spore-crawler 29.0 29.0)
                     (mk-u 210 'spore-crawler 54.0 29.0)
                     (mk-u 206 'extractor 28.0 26.0)
                     (mk-u 207 'extractor 26.0 28.0)
                     (mk-u 208 'extractor 52.0 26.0)
                     (mk-u 209 'extractor 54.0 26.0))]
       [obs1 (mk-live-obs 'Zerg 'Terran 6200
                          #:minerals 220 #:gas 120 #:supply-used 48 #:supply-cap 72
                          #:ally-units (append drones queens ovls larvae
                                               (list (mk-u 150 'overseer 36.0 36.0 #:flying? #t)
                                                     (mk-u 151 'overseer 54.0 36.0 #:flying? #t)))
                          #:ally-buildings bldgs1
                          #:enemy-units (list (mk-u 901 'banshee 46.0 32.5 #:flying? #t)
                                              (mk-u 902 'banshee 47.0 33.5 #:flying? #t)))]
       [acts1 (hash-ref (step-live-bot-runtime! rt1 obs1) 'actions '())]
       [rt2 (mk-rt 'Zerg)]
       [bldgs2 (list (mk-u 201 'lair 32.5 32.5)
                     (mk-u 202 'hatchery 56.5 32.5)
                     (mk-u 203 'spawning-pool 38.0 34.0)
                     (mk-u 204 'spire 38.0 38.0)
                     (mk-u 205 'spore-crawler 29.0 29.0)
                     (mk-u 210 'spore-crawler 54.0 29.0)
                     (mk-u 206 'extractor 28.0 26.0)
                     (mk-u 207 'extractor 26.0 28.0)
                     (mk-u 208 'extractor 52.0 26.0)
                     (mk-u 209 'extractor 54.0 26.0))]
       [obs2 (mk-live-obs 'Zerg 'Terran 6400
                          #:minerals 220 #:gas 140 #:supply-used 48 #:supply-cap 72
                          #:ally-units (append drones queens ovls larvae
                                               (list (mk-u 150 'overseer 36.0 36.0 #:flying? #t)
                                                     (mk-u 151 'overseer 54.0 36.0 #:flying? #t)))
                          #:ally-buildings bldgs2
                          #:enemy-units (list (mk-u 901 'banshee 46.0 32.5 #:flying? #t)
                                              (mk-u 902 'banshee 47.0 33.5 #:flying? #t)))]
       [acts2 (hash-ref (step-live-bot-runtime! rt2 obs2) 'actions '())])
  (check-true "L37-T4c-zvt-banshee-trains-hydralisk-and-corruptor"
              (and (has-train-sym? acts1 'hydralisk)
                   (has-train-sym? acts2 'corruptor))
              (format "acts1=~a acts2=~a" acts1 acts2)))

;; L37-T4d: ZvT vs >= 18 Terran Marines with ready BanelingNest actively morphs Banelings (batch!)
(let* ([rt (mk-rt 'Zerg)]
       [drones (for/list ([i (in-range 40)]) (mk-u (+ 10 i) 'drone 30.0 (+ 30.0 (* 0.3 i))))]
       [queens (for/list ([i (in-range 4)]) (mk-u (+ 80 i) 'queen 35.0 (+ 32.0 (* 0.5 i))))]
       [ovls (for/list ([i (in-range 4)]) (mk-u (+ 140 i) 'overlord 35.0 (+ 35.0 i) #:flying? #t))]
       [lings (for/list ([i (in-range 20)]) (mk-u (+ 100 i) 'zergling 50.0 (+ 32.0 (* 0.3 i))))]
       [marines (for/list ([i (in-range 18)]) (mk-u (+ 900 i) 'marine 72.0 (+ 32.0 (* 0.4 i))))]
       [bldgs (list (mk-u 201 'lair 32.5 32.5)
                    (mk-u 202 'hatchery 56.5 32.5)
                    (mk-u 203 'hatchery 32.5 64.5)
                    (mk-u 204 'spawning-pool 38.0 34.0)
                    (mk-u 205 'baneling-nest 38.0 28.0)
                    (mk-u 206 'extractor 28.0 26.0)
                    (mk-u 207 'extractor 26.0 28.0)
                    (mk-u 208 'extractor 52.0 26.0)
                    (mk-u 209 'extractor 54.0 26.0))]
       [obs (mk-live-obs 'Zerg 'Terran 7200
                         #:minerals 350 #:gas 200 #:supply-used 60 #:supply-cap 90
                         #:ally-units (append drones queens ovls lings)
                         #:ally-buildings bldgs
                         #:enemy-units marines)]
       [acts (hash-ref (step-live-bot-runtime! rt obs) 'actions '())]
       [bmorphs (count-morph-sym acts 'baneling)])
  (check-true "L37-T4d-zvt-heavy-bio-morphs-banelings"
              (>= bmorphs 2)
              (format "bmorphs=~a acts=~a" bmorphs acts)))

(printf "L37-RUNTIME-PLACEMENT-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks) total-checks failed-checks)
(when (> failed-checks 0)
  (exit 1))
