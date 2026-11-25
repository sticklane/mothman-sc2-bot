#lang racket/base

;; =============================================================================
;; Loop 75 Lane C Unit Tests:
;;   1. Strict Air-to-Ground Combat Attacker Filter (`enemy-air-pts` & 14t radius)
;;   2. Durable Zerg Frontline Anchor (`roach`/`ultralisk`/`baneling` >= 2)
;;   3. Zerg Pure-Ling Fallback (`< 2` durable frontliners)
;;   4. Zerg Mid-Screen Calibration (`(2.4, 5.5, 16.0)`, `wr + 0.5`, `fproj - 0.5`)
;;      with Zero In-Range Shot Cancellation
;;   5. Protoss `PROTOSS-MID-SYMS` `(1.2, 8.0, 14.0)` & `wr + 1.0` Preservation
;; =============================================================================

(require racket/list
         racket/math
         "../lib/tactics/concave-positioning.rkt")

(define pass-cnt 0)
(define fail-cnt 0)

(define (check-true name cond [detail ""])
  (if cond
      (set! pass-cnt (add1 pass-cnt))
      (begin
        (set! fail-cnt (add1 fail-cnt))
        (eprintf "FAIL [~a]: ~a\n" name detail))))

(define (mk-u id type x y #:hp [hp 100.0] #:shield [sh 0.0] #:flying [fly #f])
  (hasheq 'id id
          'type type
          'x x
          'y y
          'hp hp
          'max-hp hp
          'shield sh
          'shields sh
          'flying? fly
          'flying fly
          'is-flying fly
          'display-type 1))

;; -----------------------------------------------------------------------------
;; 1. Strict Air-to-Ground Combat Attacker Filter (`enemy-air-pts` & 14.0t radius)
;; -----------------------------------------------------------------------------
(let ()
  (define z1 (mk-u 1001 'zealot 70.0 50.0 #:hp 100.0 #:shield 50.0))
  (define s-inv (mk-u 1002 'stalker 73.0 50.0 #:hp 80.0 #:shield 80.0)) ;; d=11t to x=84
  (define e-mar (mk-u 2001 'marine 84.0 50.0 #:hp 45.0))

  ;; (a) Support / AA-only flyers MUST be excluded from `enemy-air-pts` even with `flying? = #t`
  (define support-air
    (list (mk-u 2010 'medivac 81.0 50.0 #:flying #t)
          (mk-u 2011 'warp-prism 81.0 51.0 #:flying #t)
          (mk-u 2012 'warp-prism-phasing 81.0 49.0 #:flying #t)
          (mk-u 2013 'raven 82.0 50.0 #:flying #t)
          (mk-u 2014 'viper 82.0 51.0 #:flying #t)
          (mk-u 2015 'overlord 82.0 49.0 #:flying #t)
          (mk-u 2016 'overlord-transport 82.0 48.0 #:flying #t)
          (mk-u 2017 'overseer 82.0 52.0 #:flying #t)
          (mk-u 2018 'observer 82.0 53.0 #:flying #t)
          (mk-u 2019 'corruptor 81.0 52.0 #:flying #t)
          (mk-u 2020 'viking-fighter 81.0 48.0 #:flying #t)))
  (define ctx-supp (build-combat-positioning-context (list z1 s-inv) (cons e-mar support-air)))
  (check-true "l75-c1-support-and-aa-only-air-excluded-from-enemy-air-pts"
              (null? (combat-pos-ctx-enemy-air-pts ctx-supp))
              (format "enemy-air-pts=~a" (combat-pos-ctx-enemy-air-pts ctx-supp)))

  ;; (b) Protoss Stalker at 11t vs Terran Marine + Medivac (8t away) STILL holds behind Zealot!
  (define ctx-med (build-combat-positioning-context (list z1 s-inv)
                                                    (list e-mar (mk-u 2021 'medivac 81.0 50.0 #:flying #t))))
  (define-values (shx shy) (compute-front-to-back-advance-pt ctx-med s-inv 84.0 50.0 6.0))
  (check-true "l75-c1-stalker-holds-behind-zealot-when-only-medivac-air"
              (and shx shy (<= (abs (- shx 68.8)) 0.15))
              (format "shx=~a shy=~a" shx shy))

  ;; (c) Real combat air attackers ARE collected in `enemy-air-pts`
  (define combat-air
    (list (mk-u 2030 'mutalisk 85.0 50.0 #:flying #t)
          (mk-u 2031 'banshee 85.0 51.0 #:flying #t)
          (mk-u 2032 'oracle 85.0 49.0 #:flying #t)
          (mk-u 2033 'void-ray 86.0 50.0 #:flying #t)
          (mk-u 2034 'liberator-ag 86.0 51.0 #:flying #t)
          (mk-u 2035 'battlecruiser 86.0 49.0 #:flying #t)
          (mk-u 2036 'carrier 87.0 50.0 #:flying #t)
          (mk-u 2037 'tempest 87.0 51.0 #:flying #t)
          (mk-u 2038 'brood-lord 87.0 49.0 #:flying #t)
          (mk-u 2039 'phoenix 85.0 52.0 #:flying #t)))
  (define ctx-cair (build-combat-positioning-context (list z1 s-inv) (cons e-mar combat-air)))
  (check-true "l75-c1-combat-air-attackers-included-in-enemy-air-pts"
              (= (length (combat-pos-ctx-enemy-air-pts ctx-cair)) (length combat-air))
              (format "len=~a expected=~a" (length (combat-pos-ctx-enemy-air-pts ctx-cair)) (length combat-air)))

  ;; (d) Banshee / Mutalisk within <= 14.0t (12.0t) exempts Stalker from hold (`#f`)
  (define ctx-ban-12 (build-combat-positioning-context (list z1 s-inv)
                                                       (list e-mar (mk-u 2040 'banshee 85.0 50.0 #:flying #t))))
  (define ctx-muta-12 (build-combat-positioning-context (list z1 s-inv)
                                                        (list e-mar (mk-u 2041 'mutalisk 85.0 50.0 #:flying #t))))
  (define-values (bx12 _by12) (compute-front-to-back-advance-pt ctx-ban-12 s-inv 84.0 50.0 6.0))
  (define-values (mx12 _my12) (compute-front-to-back-advance-pt ctx-muta-12 s-inv 84.0 50.0 6.0))
  (check-true "l75-c1-banshee-or-mutalisk-within-14t-disables-aa-hold"
              (and (not bx12) (not mx12))
              (format "bx12=~a mx12=~a" bx12 mx12))

  ;; (e) Banshee at 15.0t (> 14.0t tightened threshold) STILL allows ground role screening!
  (define ctx-ban-15 (build-combat-positioning-context (list z1 s-inv)
                                                       (list e-mar (mk-u 2042 'banshee 88.0 50.0 #:flying #t))))
  (define-values (bx15 _by15) (compute-front-to-back-advance-pt ctx-ban-15 s-inv 84.0 50.0 6.0))
  (check-true "l75-c1-banshee-beyond-14t-allows-ground-screening"
              (and bx15 (<= (abs (- bx15 68.8)) 0.15))
              (format "bx15=~a" bx15)))

;; -----------------------------------------------------------------------------
;; 2. Durable Zerg Frontline Anchor (`roach`/`ultralisk`/`baneling` >= 2)
;; -----------------------------------------------------------------------------
(let ()
  (define e-marines
    (for/list ([i (in-range 6)]) (mk-u (+ 3900 i) 'marine 84.0 (+ 48.0 (* 0.8 i)) #:hp 45.0)))
  (define roaches-4
    (for/list ([i (in-range 4)]) (mk-u (+ 3000 i) 'roach 70.0 (+ 48.5 (* 1.0 i)) #:hp 145.0)))
  (define flank-lings-12
    (for/list ([i (in-range 12)]) (mk-u (+ 3100 i) 'zergling 80.0 (+ 44.0 (* 1.0 i)) #:hp 35.0)))
  (define hydra-inv (mk-u 3201 'hydralisk 72.0 50.0 #:hp 90.0))
  (define rav-inv   (mk-u 3202 'ravager   74.0 50.0 #:hp 120.0))

  ;; (a) 4 Roaches at x=70 + 12 fast flanking Zerglings at x=80 -> `z-front-cx` anchored at 70.0 (Roaches!)
  ;;     and Hydralisk at x=72 (d=12t) holds cleanly behind Roaches (`hx < 68.0`, ~67.6)!
  (define ctx-dur (build-combat-positioning-context (append roaches-4 flank-lings-12 (list hydra-inv rav-inv))
                                                    e-marines))
  (define-values (hx hy) (compute-front-to-back-advance-pt ctx-dur hydra-inv 84.0 50.0 6.0))
  (define-values (rx _ry) (compute-front-to-back-advance-pt ctx-dur rav-inv 84.0 50.0 6.0))
  (check-true "l75-c2-zerg-durable-roach-anchor-ignores-flanking-zerglings"
              (and (= (combat-pos-ctx-z-front-cnt ctx-dur) 4)
                   (<= (abs (- (combat-pos-ctx-z-front-cx ctx-dur) 70.0)) 0.05)
                   hx hy (< hx 68.0) (<= (abs (- hx 67.6)) 0.20)
                   rx (< rx 68.0))
              (format "zfc=~a zfcx=~a h=(~a,~a) rx=~a"
                      (combat-pos-ctx-z-front-cnt ctx-dur)
                      (combat-pos-ctx-z-front-cx ctx-dur)
                      hx hy rx))

  ;; (b) Ultralisk (2) & Baneling (2) durable anchors also prevent flanking Zergling skew
  (define ultras-2 (list (mk-u 3301 'ultralisk 70.0 49.0 #:hp 500.0)
                         (mk-u 3302 'ultralisk 70.0 51.0 #:hp 500.0)))
  (define banes-2  (list (mk-u 3303 'baneling 70.0 49.0 #:hp 30.0)
                         (mk-u 3304 'baneling 70.0 51.0 #:hp 30.0)))
  (define ctx-ultra (build-combat-positioning-context (append ultras-2 flank-lings-12 (list hydra-inv)) e-marines))
  (define ctx-bane  (build-combat-positioning-context (append banes-2 flank-lings-12 (list hydra-inv)) e-marines))
  (check-true "l75-c2-ultralisk-and-baneling-durable-anchors-work"
              (and (= (combat-pos-ctx-z-front-cnt ctx-ultra) 2)
                   (<= (abs (- (combat-pos-ctx-z-front-cx ctx-ultra) 70.0)) 0.05)
                   (= (combat-pos-ctx-z-front-cnt ctx-bane) 2)
                   (<= (abs (- (combat-pos-ctx-z-front-cx ctx-bane) 70.0)) 0.05))
              (format "ultra=(~a,~a) bane=(~a,~a)"
                      (combat-pos-ctx-z-front-cnt ctx-ultra) (combat-pos-ctx-z-front-cx ctx-ultra)
                      (combat-pos-ctx-z-front-cnt ctx-bane) (combat-pos-ctx-z-front-cx ctx-bane)))

  ;; (c) Pure-Ling fallback (`0` Roaches + `10` Zerglings at x=70) & single-Roach fallback (`1 < 2`)
  (define lings-10 (for/list ([i (in-range 10)]) (mk-u (+ 3400 i) 'zergling 70.0 (+ 45.5 (* 1.0 i)) #:hp 35.0)))
  (define ctx-pure-ling (build-combat-positioning-context (cons hydra-inv lings-10) e-marines))
  (define-values (lhx _lhy) (compute-front-to-back-advance-pt ctx-pure-ling hydra-inv 84.0 50.0 6.0))
  (define ctx-one-roach (build-combat-positioning-context (cons (first roaches-4) (cons hydra-inv lings-10)) e-marines))
  (check-true "l75-c2-pure-ling-and-lt2-durable-fallback-preserved"
              (and (= (combat-pos-ctx-z-front-cnt ctx-pure-ling) 10)
                   (<= (abs (- (combat-pos-ctx-z-front-cx ctx-pure-ling) 70.0)) 0.05)
                   lhx (< lhx 68.0)
                   (= (combat-pos-ctx-z-front-cnt ctx-one-roach) 11))
              (format "pure=(~a,~a,lhx=~a) one-r-cnt=~a"
                      (combat-pos-ctx-z-front-cnt ctx-pure-ling)
                      (combat-pos-ctx-z-front-cx ctx-pure-ling)
                      lhx
                      (combat-pos-ctx-z-front-cnt ctx-one-roach))))

;; -----------------------------------------------------------------------------
;; 3. Zerg Mid-Screen Calibration, Zero Shot Cancellation & Protoss 5d2 Preservation
;; -----------------------------------------------------------------------------
(let ()
  (define e-mar (list (mk-u 4901 'marine 84.0 50.0 #:hp 45.0)))
  (define r-front (list (mk-u 4001 'roach 70.0 49.5 #:hp 145.0)
                        (mk-u 4002 'roach 70.0 50.5 #:hp 145.0)))

  ;; (a) Zero in-range shot cancellation: Hydralisk (`wr=6.0`) at d=5.8t and d=6.5t (`<= wr + 0.5`) -> `#f`!
  (define h-inrange-58 (mk-u 4101 'hydralisk 78.2 50.0 #:hp 90.0)) ;; d=5.8t
  (define h-inrange-65 (mk-u 4102 'hydralisk 77.5 50.0 #:hp 90.0)) ;; d=6.5t
  (define ctx-z (build-combat-positioning-context (append r-front (list h-inrange-58 h-inrange-65)) e-mar))
  (define-values (x58 _y58) (compute-front-to-back-advance-pt ctx-z h-inrange-58 84.0 50.0 6.0))
  (define-values (x65 _y65) (compute-front-to-back-advance-pt ctx-z h-inrange-65 84.0 50.0 6.0))
  (check-true "l75-c3-hydra-never-cancels-in-range-shot-le-wr-plus-0.5"
              (and (not x58) (not x65))
              (format "x58=~a x65=~a" x58 x65))

  ;; (b) Unupgraded Hydralisk (`wr=5.0`) at d=5.8t (`> 5.5` and `>= 5.5` min-app-d) holds behind Roaches;
  ;;     at d=5.4t (`< 5.5`) returns `#f`!
  (define r-close (list (mk-u 4003 'roach 76.0 49.5 #:hp 145.0)
                        (mk-u 4004 'roach 76.0 50.5 #:hp 145.0)))
  (define h-wr5-58 (mk-u 4103 'hydralisk 78.2 50.0 #:hp 90.0)) ;; d=5.8t > 5.5
  (define h-wr5-54 (mk-u 4104 'hydralisk 78.6 50.0 #:hp 90.0)) ;; d=5.4t < 5.5
  (define ctx-z5 (build-combat-positioning-context (append r-close (list h-wr5-58 h-wr5-54)) e-mar))
  (define-values (xw58 _yw58) (compute-front-to-back-advance-pt ctx-z5 h-wr5-58 84.0 50.0 5.0))
  (define-values (xw54 _yw54) (compute-front-to-back-advance-pt ctx-z5 h-wr5-54 84.0 50.0 5.0))
  (check-true "l75-c3-hydra-wr5-screens-at-5.8t-and-skips-at-5.4t"
              (and xw58 (<= (abs (- xw58 (- 76.0 2.4))) 0.15)
                   (not xw54))
              (format "xw58=~a xw54=~a" xw58 xw54))

  ;; (c) Tightened inversion threshold (`u-proj >= fproj - 0.5`):
  ;;     Hydra at x=69.6 (`fproj - 0.4`) smoothly tucks behind; Hydra at x=69.2 (`fproj - 0.8`) is NOT held!
  (define h-level  (mk-u 4105 'hydralisk 69.6 50.0 #:hp 90.0))
  (define h-behind (mk-u 4106 'hydralisk 69.2 50.0 #:hp 90.0))
  (define ctx-lvl (build-combat-positioning-context (append r-front (list h-level h-behind)) e-mar))
  (define-values (xlvl _ylvl) (compute-front-to-back-advance-pt ctx-lvl h-level 84.0 50.0 6.0))
  (define-values (xbhd _ybhd) (compute-front-to-back-advance-pt ctx-lvl h-behind 84.0 50.0 6.0))
  (check-true "l75-c3-inversion-threshold-fproj-minus-0.5"
              (and xlvl (<= (abs (- xlvl 67.6)) 0.15)
                   (not xbhd))
              (format "xlvl=~a xbhd=~a" xlvl xbhd))

  ;; (d) Protoss `PROTOSS-MID-SYMS` preserves exact `(1.2, 8.0, 14.0)` & `wr + 1.0` (`5d2` contract!)
  (define z-front (mk-u 4201 'zealot 70.0 50.0 #:hp 100.0 #:shield 50.0))
  (define st-ok   (mk-u 4202 'stalker 73.0 50.0 #:hp 80.0 #:shield 80.0)) ;; d=11t
  (define st-75   (mk-u 4203 'stalker 76.5 50.0 #:hp 80.0 #:shield 80.0)) ;; d=7.5t < 8.0
  (define st-150  (mk-u 4204 'stalker 69.0 50.0 #:hp 80.0 #:shield 80.0)) ;; d=15.0t > 14.0
  (define ctx-p (build-combat-positioning-context (list z-front st-ok st-75 st-150) e-mar))
  (define-values (px-ok _py-ok) (compute-front-to-back-advance-pt ctx-p st-ok 84.0 50.0 6.0))
  (define-values (px-75 _py-75) (compute-front-to-back-advance-pt ctx-p st-75 84.0 50.0 6.0))
  (define-values (px-15 _py-15) (compute-front-to-back-advance-pt ctx-p st-150 84.0 50.0 6.0))
  (check-true "l75-c3-protoss-mid-syms-1.2-8.0-14.0-preserved"
              (and px-ok (<= (abs (- px-ok 68.8)) 0.15)
                   (not px-75)
                   (not px-15))
              (format "ok=~a d75=~a d150=~a" px-ok px-75 px-15)))

(printf "l75-concave-layering-test: ~a/~a passed\n" pass-cnt (+ pass-cnt fail-cnt))
(when (> fail-cnt 0)
  (exit 1))
