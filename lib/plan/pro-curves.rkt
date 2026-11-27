#lang racket/base

;; =============================================================================
;; Compiled Pro-Corpus Matchup Curves (Loop 88A)
;;
;; Single source of truth for Pro-backed macro timing and curve targets across
;; all 9 matchups (PvP/PvT/PvZ/TvP/TvT/TvZ/ZvP/ZvT/ZvZ), compiled directly
;; from `tools/iteration-loop/pro_baselines.json` (298 LotV replays, 596
;; perspectives, 6,478 checkpoints).
;; =============================================================================

(require racket/list
         racket/match)

(provide SC2-FRAMES-PER-SEC
         (struct-out pro-matchup-curve)
         pro-matchup-key
         lookup-pro-matchup-curve
         pro-curve-interpolate
         pro-target-workers-at
         pro-target-army-supply-at
         pro-target-army-value-at
         pro-target-bases-at
         pro-target-prod-count-at
         pro-target-primary-prod-at
         pro-target-queens-at
         pro-natural-frame
         pro-natural-supply
         pro-third-frame
         pro-gas1-frame
         pro-gas2-frame
         pro-gas-worker-thresholds)

(define SC2-FRAMES-PER-SEC 22.4)

(struct pro-matchup-curve
  (key                   ;; symbol: 'PvP | 'PvT | ... | 'ZvZ
   race                  ;; 'Protoss | 'Terran | 'Zerg
   enemy-race            ;; 'Protoss | 'Terran | 'Zerg
   nat-sec               ;; flonum (seconds)
   nat-supply            ;; exact-integer
   third-sec             ;; flonum (seconds)
   gas1-sec              ;; flonum (seconds)
   gas2-sec              ;; flonum (seconds)
   prod1-sym             ;; symbol: 'gateway | 'barracks | 'spawning-pool
   prod1-sec             ;; flonum
   tech1-sym             ;; symbol: 'cybernetics-core | 'factory | 'lair
   tech1-sec             ;; flonum
   bases-6m              ;; flonum
   bases-8m              ;; flonum
   gas-worker-thresholds ;; list of 4 worker thresholds for geysers 1..4
   worker-curve          ;; list of (cons sec workers)
   army-sup-curve        ;; list of (cons sec army-supply)
   army-val-curve        ;; list of (cons sec army-value)
   prod-cnt-curve        ;; list of (cons sec total-prod-count)
   primary-prod-curve    ;; list of (cons sec primary-prod-count)
   queen-curve)          ;; list of (cons sec queen-count)
  #:transparent)

(define (mk-curve key race erace nat-s nat-sup third-s g1-s g2-s
                  p1-sym p1-s t1-sym t1-s b6 b8 g-thresh
                  w2 w4 w6 w8 w10
                  a2 a4 a6 a8 a10
                  v2 v4 v6 v8 v10
                  pc2 pc4 pc6 pc8 pc10
                  pp2 pp4 pp6 pp8 pp10
                  q2 q4 q6 q8 q10)
  (pro-matchup-curve
   key race erace
   nat-s nat-sup third-s g1-s g2-s
   p1-sym p1-s t1-sym t1-s b6 b8 g-thresh
   (list (cons 0.0 12.0) (cons 120.0 w2) (cons 240.0 w4) (cons 360.0 w6) (cons 480.0 w8) (cons 600.0 w10))
   (list (cons 0.0 0.0)  (cons 120.0 a2) (cons 240.0 a4) (cons 360.0 a6) (cons 480.0 a8) (cons 600.0 a10))
   (list (cons 0.0 0.0)  (cons 120.0 v2) (cons 240.0 v4) (cons 360.0 v6) (cons 480.0 v8) (cons 600.0 v10))
   (list (cons 0.0 0.0)  (cons 120.0 pc2) (cons 240.0 pc4) (cons 360.0 pc6) (cons 480.0 pc8) (cons 600.0 pc10))
   (list (cons 0.0 0.0)  (cons 120.0 pp2) (cons 240.0 pp4) (cons 360.0 pp6) (cons 480.0 pp8) (cons 600.0 pp10))
   (list (cons 0.0 0.0)  (cons 120.0 q2) (cons 240.0 q4) (cons 360.0 q6) (cons 480.0 q8) (cons 600.0 q10))))

;; Exact median curves from tools/iteration-loop/pro_baselines.json
;; (TvT m10 had sparse samples in pro_baselines.json, interpolated cleanly from TvT m8 + TvP/TvZ m10 slope.)
(define PRO-CURVES-TABLE
  (hasheq
   'PvP (mk-curve 'PvP 'Protoss 'Protoss
                  194.2 32 369.5 48.8 61.5
                  'gateway 41.0 'cybernetics-core 90.3 2.0 3.0 '(16 17 36 37)
                  21.0 27.0 38.0 45.5 51.5
                  1.0  11.0 24.0 43.0 57.0
                  0.0  662.5 1762.5 3175.0 3725.0
                  2.0  3.0  5.0  7.0  8.0
                  2.0  2.0  4.0  6.0  6.0
                  0.0  0.0  0.0  0.0  0.0)
   'PvT (mk-curve 'PvT 'Protoss 'Terran
                  93.1 20 245.4 46.5 107.8
                  'gateway 36.1 'cybernetics-core 84.3 3.0 3.0 '(16 20 36 39)
                  20.0 34.0 45.5 58.0 67.0
                  1.0  8.0  22.0 43.0 67.0
                  0.0  475.0 1575.0 3050.0 4850.0
                  1.0  3.0  4.0  8.0  9.0
                  1.0  2.0  3.0  7.0  8.0
                  0.0  0.0  0.0  0.0  0.0)
   'PvZ (mk-curve 'PvZ 'Protoss 'Zerg
                  86.2 20 235.8 49.3 103.7
                  'gateway 41.1 'cybernetics-core 94.9 3.0 3.0 '(16 20 36 39)
                  21.0 36.0 48.0 63.0 68.0
                  1.0  10.0 24.0 49.0 73.0
                  0.0  425.0 1675.0 3725.0 5415.0
                  1.0  3.0  6.0  9.0  10.0
                  1.0  2.0  5.0  8.0  8.0
                  0.0  0.0  0.0  0.0  0.0)
   'TvP (mk-curve 'TvP 'Terran 'Protoss
                  136.6 22 383.7 43.2 53.2
                  'barracks 40.3 'factory 103.5 2.0 3.0 '(15 20 35 40)
                  19.0 27.0 40.0 49.0 59.0
                  1.0  15.0 32.0 51.0 79.0
                  0.0  500.0 1600.0 2825.0 4450.0
                  1.0  4.0  5.0  6.0  7.0
                  1.0  2.0  3.0  4.0  5.0
                  0.0  0.0  0.0  0.0  0.0)
   'TvT (mk-curve 'TvT 'Terran 'Terran
                  108.6 20 377.1 45.9 150.4
                  'barracks 41.7 'factory 131.4 2.0 2.5 '(15 20 35 40)
                  19.0 26.5 39.5 45.5 55.0
                  1.0  12.5 36.0 52.0 76.0
                  0.0  450.0 2112.5 3200.0 4400.0
                  2.0  4.5  5.0  5.0  7.0
                  1.0  2.5  3.0  3.0  5.0
                  0.0  0.0  0.0  0.0  0.0)
   'TvZ (mk-curve 'TvZ 'Terran 'Zerg
                  103.2 20 257.1 43.4 138.3
                  'barracks 44.5 'factory 128.1 3.0 3.0 '(15 20 35 40)
                  19.0 28.0 43.5 56.0 58.0
                  1.0  12.5 29.0 54.0 80.0
                  0.0  400.0 1325.0 2875.0 4325.0
                  1.0  3.0  5.0  7.0  9.0
                  1.0  1.0  3.0  5.0  6.0
                  0.0  0.0  0.0  0.0  0.0)
   'ZvP (mk-curve 'ZvP 'Zerg 'Protoss
                  48.7 16 162.9 64.8 227.5
                  'spawning-pool 73.3 'lair 277.9 3.0 4.0 '(16 30 39 46)
                  19.0 33.5 51.0 62.0 73.0
                  1.0  14.0 26.5 58.0 86.0
                  0.0  600.0 1275.0 3000.0 5300.0
                  2.0  3.0  3.0  4.0  4.0
                  2.0  3.0  3.0  4.0  4.0
                  0.0  3.0  4.0  5.0  5.0)
   'ZvT (mk-curve 'ZvT 'Zerg 'Terran
                  52.5 17 172.0 68.0 233.3
                  'spawning-pool 71.1 'lair 262.0 3.0 4.0 '(16 30 39 46)
                  19.0 33.0 51.0 66.0 72.0
                  1.0  14.0 27.2 49.5 78.0
                  0.0  600.0 1525.0 3100.0 5150.0
                  2.0  3.0  3.0  4.0  5.0
                  2.0  3.0  3.0  4.0  5.0
                  0.0  3.0  5.0  5.0  5.0)
   'ZvZ (mk-curve 'ZvZ 'Zerg 'Zerg
                  51.1 17 158.7 67.8 240.8
                  'spawning-pool 71.9 'lair 279.2 3.0 3.0 '(16 30 39 46)
                  19.0 32.0 43.5 53.0 58.0
                  1.0  15.0 35.2 60.0 92.8
                  0.0  662.5 1575.0 3100.0 5200.0
                  2.0  3.0  3.0  3.0  4.0
                  2.0  3.0  3.0  3.0  4.0
                  0.0  2.0  3.0  3.0  3.0)))

(define (pro-matchup-key race enemy-race)
  (define r-ch
    (case race
      [(Protoss) "P"]
      [(Terran) "T"]
      [(Zerg) "Z"]
      [else "T"]))
  (define e-ch
    (case enemy-race
      [(Protoss) "P"]
      [(Terran) "T"]
      [(Zerg) "Z"]
      [else (case race [(Protoss) "T"] [(Terran) "Z"] [else "T"])]))
  (string->symbol (string-append r-ch "v" e-ch)))

(define (lookup-pro-matchup-curve race enemy-race)
  (hash-ref PRO-CURVES-TABLE (pro-matchup-key race enemy-race)
            (hash-ref PRO-CURVES-TABLE 'TvZ)))

(define (pro-curve-interpolate pts sec)
  (define s (max 0.0 (exact->inexact sec)))
  (cond
    [(null? pts) 0.0]
    [(<= s (caar pts)) (cdar pts)]
    [else
     (let loop ([prev (car pts)] [rest (cdr pts)])
       (cond
         [(null? rest) (cdr prev)]
         [(<= s (caar rest))
          (define x0 (car prev))
          (define y0 (cdr prev))
          (define x1 (caar rest))
          (define y1 (cdar rest))
          (define dx (- x1 x0))
          (if (<= dx 0.0)
              y1
              (+ y0 (* (- y1 y0) (/ (- s x0) dx))))]
         [else (loop (car rest) (cdr rest))]))]))

(define (frame->sec frame)
  (/ (max 0.0 (exact->inexact frame)) SC2-FRAMES-PER-SEC))

(define (pro-target-workers-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (pro-curve-interpolate (pro-matchup-curve-worker-curve c) (frame->sec frame)))

(define (pro-target-army-supply-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (pro-curve-interpolate (pro-matchup-curve-army-sup-curve c) (frame->sec frame)))

(define (pro-target-army-value-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (pro-curve-interpolate (pro-matchup-curve-army-val-curve c) (frame->sec frame)))

(define (pro-target-prod-count-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (pro-curve-interpolate (pro-matchup-curve-prod-cnt-curve c) (frame->sec frame)))

(define (pro-target-primary-prod-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (pro-curve-interpolate (pro-matchup-curve-primary-prod-curve c) (frame->sec frame)))

(define (pro-target-queens-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (pro-curve-interpolate (pro-matchup-curve-queen-curve c) (frame->sec frame)))

(define (pro-target-bases-at race enemy-race frame)
  (define c (lookup-pro-matchup-curve race enemy-race))
  (define sec (frame->sec frame))
  (define nat-s (pro-matchup-curve-nat-sec c))
  (define third-s (pro-matchup-curve-third-sec c))
  (define fourth-s (+ third-s 150.0))
  (define fifth-s (+ fourth-s 140.0))
  (cond
    [(>= sec fifth-s) 5]
    [(>= sec fourth-s) 4]
    [(>= sec third-s) 3]
    [(>= sec nat-s) 2]
    [else 1]))

(define (pro-natural-frame race enemy-race)
  (inexact->exact (round (* (pro-matchup-curve-nat-sec (lookup-pro-matchup-curve race enemy-race))
                            SC2-FRAMES-PER-SEC))))

(define (pro-natural-supply race enemy-race)
  (pro-matchup-curve-nat-supply (lookup-pro-matchup-curve race enemy-race)))

(define (pro-third-frame race enemy-race)
  (inexact->exact (round (* (pro-matchup-curve-third-sec (lookup-pro-matchup-curve race enemy-race))
                            SC2-FRAMES-PER-SEC))))

(define (pro-gas1-frame race enemy-race)
  (inexact->exact (round (* (pro-matchup-curve-gas1-sec (lookup-pro-matchup-curve race enemy-race))
                            SC2-FRAMES-PER-SEC))))

(define (pro-gas2-frame race enemy-race)
  (inexact->exact (round (* (pro-matchup-curve-gas2-sec (lookup-pro-matchup-curve race enemy-race))
                            SC2-FRAMES-PER-SEC))))

(define (pro-gas-worker-thresholds race enemy-race)
  (pro-matchup-curve-gas-worker-thresholds (lookup-pro-matchup-curve race enemy-race)))
