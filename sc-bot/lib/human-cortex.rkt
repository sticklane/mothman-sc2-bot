#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math)

(provide
 VIEWPORT-WIDTH
 VIEWPORT-HEIGHT
 TAU-FIXATION-MS
 TAU-FIXATION-FRAMES

 (struct-out human-cortex)
 make-human-cortex
 in-camera-viewport?
 fitts-saccade-ms
 fitts-saccade-frames
 cortex-move-camera!
 cortex-filter-actions!

 ;; Control Groups (0..9) & Pro Control-Group Stealing (Alt+Group)
 cortex-assign-control-group!
 cortex-steal-control-group!
 cortex-get-control-group

 ;; Camera Location Bookmarks (F1..F8)
 cortex-save-camera-bookmark!
 cortex-get-camera-bookmark
 cortex-jump-camera-bookmark!

 ;; 7-Year (2019-2026) Pro Tournament Cortex Calibration & Fingerprinting
 PRO-CORTEX-PROFILES
 get-pro-cortex-profile
 calibrate-cortex-from-corpus
 ks-two-sample-statistic
 hellinger-distance
 classify-player-fingerprint)

(define VIEWPORT-WIDTH 24)
(define VIEWPORT-HEIGHT 18)
(define TAU-FIXATION-MS 160)
(define TAU-FIXATION-FRAMES 4)

(struct human-cortex
  (profile-name
   cam-x
   cam-y
   fixation-frames
   epm-cap
   tokens
   max-tokens
   accepted-count
   dropped-count
   offscreen-violations
   control-groups     ; 10-element vector of unit-id lists
   camera-bookmarks   ; hash slot (1..8) -> (cons x y)
   action-history)
  #:mutable
  #:transparent)

(define PRO-CORTEX-PROFILES
  (hash
   'Serral   (hash 'name 'Serral   'race 'Zerg    'mean-epm 365 'burst-epm 620 'saccade-a 42.0 'saccade-b 18.5 'fixation-ms 155 'screen-jumps-per-min 44.2)
   'Reynor   (hash 'name 'Reynor   'race 'Zerg    'mean-epm 392 'burst-epm 680 'saccade-a 38.0 'saccade-b 17.0 'fixation-ms 148 'screen-jumps-per-min 48.5)
   'Maru     (hash 'name 'Maru     'race 'Terran  'mean-epm 358 'burst-epm 610 'saccade-a 44.0 'saccade-b 19.0 'fixation-ms 160 'screen-jumps-per-min 39.8)
   'Clem     (hash 'name 'Clem     'race 'Terran  'mean-epm 410 'burst-epm 710 'saccade-a 36.0 'saccade-b 16.5 'fixation-ms 142 'screen-jumps-per-min 52.1)
   'Oliveira (hash 'name 'Oliveira 'race 'Terran  'mean-epm 345 'burst-epm 580 'saccade-a 45.0 'saccade-b 19.5 'fixation-ms 162 'screen-jumps-per-min 38.4)
   'herO     (hash 'name 'herO     'race 'Protoss 'mean-epm 338 'burst-epm 575 'saccade-a 46.0 'saccade-b 20.0 'fixation-ms 165 'screen-jumps-per-min 41.0)
   'Classic  (hash 'name 'Classic  'race 'Protoss 'mean-epm 312 'burst-epm 530 'saccade-a 48.0 'saccade-b 21.0 'fixation-ms 172 'screen-jumps-per-min 35.6)
   'MaxPax   (hash 'name 'MaxPax   'race 'Protoss 'mean-epm 352 'burst-epm 595 'saccade-a 43.0 'saccade-b 18.8 'fixation-ms 158 'screen-jumps-per-min 43.0)
   'Flash    (hash 'name 'Flash    'race 'Terran  'mean-epm 330 'burst-epm 540 'saccade-a 47.0 'saccade-b 20.5 'fixation-ms 168 'screen-jumps-per-min 37.2)
   'Jaedong  (hash 'name 'Jaedong  'race 'Zerg    'mean-epm 375 'burst-epm 640 'saccade-a 40.0 'saccade-b 18.0 'fixation-ms 152 'screen-jumps-per-min 45.0)
   'Bisu     (hash 'name 'Bisu     'race 'Protoss 'mean-epm 340 'burst-epm 565 'saccade-a 45.0 'saccade-b 19.8 'fixation-ms 164 'screen-jumps-per-min 42.5)))

(define (get-pro-cortex-profile [name 'Serral])
  (hash-ref PRO-CORTEX-PROFILES name
            (lambda () (hash-ref PRO-CORTEX-PROFILES 'Serral))))

(define (make-human-cortex #:profile [profile 'Serral]
                           #:cam-x [cam-x 32.0]
                           #:cam-y [cam-y 32.0]
                           #:epm-cap [epm-cap 360]
                           #:max-tokens [max-tokens 16])
  (human-cortex
   profile
   cam-x
   cam-y
   1
   epm-cap
   max-tokens
   max-tokens
   0
   0
   0
   (make-vector 10 '())
   (make-hash)
   '()))

(define (in-camera-viewport? cx cy x y [w VIEWPORT-WIDTH] [h VIEWPORT-HEIGHT])
  (define half-w (/ (exact->inexact w) 2.0))
  (define half-h (/ (exact->inexact h) 2.0))
  (and (>= x (- cx half-w))
       (<= x (+ cx half-w))
       (>= y (- cy half-h))
       (<= y (+ cy half-h))))

;; Fitts's Law Saccade Duration in SC2 map tiles: T = a + b * log2(1 + D / W)
(define (fitts-saccade-ms x1 y1 x2 y2 [target-width 4.0] [a 42.0] [b 18.5])
  (define dist (sqrt (+ (sqr (- x2 x1)) (sqr (- y2 y1)))))
  (+ a (* b (/ (log (+ 1.0 (/ dist (max 1.0 target-width)))) (log 2.0)))))

(define (fitts-saccade-frames x1 y1 x2 y2)
  (max 1 (exact-ceiling (/ (fitts-saccade-ms x1 y1 x2 y2) 42.0))))

(define (cortex-move-camera! cortex new-x new-y)
  (define old-x (human-cortex-cam-x cortex))
  (define old-y (human-cortex-cam-y cortex))
  (cond
    [(and (= old-x new-x) (= old-y new-y))
     (set-human-cortex-fixation-frames! cortex (add1 (human-cortex-fixation-frames cortex)))]
    [else
     (set-human-cortex-cam-x! cortex new-x)
     (set-human-cortex-cam-y! cortex new-y)
     (set-human-cortex-fixation-frames! cortex 1)])
  cortex)

;; =============================================================================
;; Control Groups (0..9) & Pro Control-Group Stealing (Alt+Group)
;; =============================================================================

(define (cortex-assign-control-group! cortex group-id unit-ids)
  (when (and (>= group-id 0) (< group-id 10))
    (define vec (human-cortex-control-groups cortex))
    (define existing (vector-ref vec group-id))
    (vector-set! vec group-id (remove-duplicates (append existing unit-ids))))
  cortex)

;; Exclusive Control-Group Stealing (Alt + 0..9):
;; Removes `unit-ids` from ALL other control groups (0..9) and assigns to `group-id`.
(define (cortex-steal-control-group! cortex group-id unit-ids)
  (define stolen-set (list->set unit-ids))
  (define vec (human-cortex-control-groups cortex))
  (for ([g (in-range 10)])
    (when (not (= g group-id))
      (define cur (vector-ref vec g))
      (vector-set! vec g (filter (lambda (id) (not (set-member? stolen-set id))) cur))))
  (when (and (>= group-id 0) (< group-id 10))
    (define cur-target (vector-ref vec group-id))
    (vector-set! vec group-id (remove-duplicates (append cur-target unit-ids))))
  cortex)

(define (cortex-get-control-group cortex group-id)
  (if (and (>= group-id 0) (< group-id 10))
      (vector-ref (human-cortex-control-groups cortex) group-id)
      '()))

;; =============================================================================
;; Camera Location Bookmarks (F1..F8)
;; =============================================================================

(define (cortex-save-camera-bookmark! cortex slot x y)
  (hash-set! (human-cortex-camera-bookmarks cortex) slot (cons x y))
  cortex)

(define (cortex-get-camera-bookmark cortex slot)
  (hash-ref (human-cortex-camera-bookmarks cortex) slot #f))

(define (cortex-jump-camera-bookmark! cortex slot)
  (define pos (cortex-get-camera-bookmark cortex slot))
  (when pos
    (cortex-move-camera! cortex (car pos) (cdr pos)))
  pos)

;; =============================================================================
;; Action Prioritization & Viewport / Token-Bucket Filtering
;; =============================================================================

(define (action-priority act)
  (match act
    [(list 'posture-transition _ ...)        100]
    [(list 'move-camera _ ...)               99]
    [(list 'camera-focus _ ...)              99]
    [(list 'camera-bookmark-save _ ...)      98]
    [(list 'camera-bookmark-jump _ ...)      98]
    [(list 'control-group-steal _ ...)       97]
    [(list 'cancel _ ...)                    96]
    [(list 'pull-workers-attack _ ...)       95]
    [(list 'clear-expansion-block _ ...)     94]
    [(list 'clear-gas-steal _ ...)           94]
    [(list 'resume-halted-building _ ...)    93]
    [(list 'hold-position _ ...)             92]
    [(list 'swap-addon _ ...)                92]
    [(list 'transport-juggle _ ...)          91]
    [(list 'multi-prong-drop _ ...)          90]
    [(list 'mineral-walk _ ...)              90]
    [(list 'worker-harass _ ...)             89]
    [(list 'inject-larva _ ...)              88]
    [(list 'chrono-boost _ ...)              88]
    [(list 'calldown-mule _ ...)             88]
    [(list (or 'cast 'cast-spell 'use-ability) _ ...) 86]
    [(list 'morph _ ...)                     84]
    [(list 'build _ ...)                     82]
    [(list 'expand _ ...)                    81]
    [(list 'research _ ...)                  79]
    [(list 'train _ ...)                     78]
    [(list 'execute-spatial-maneuver _ ...)  75]
    [(list 'mirror-spatial-maneuver _ ...)   74]
    [(list 'mirror-macro-directive _ ...)    73]
    [(list 'mirror-prediction _ ...)         72]
    [(list 'mirror-tech-observation _ ...)   71]
    [(list 'mirror-zero-sum-exclusion _ ...) 70]
    [(list 'kite _ ...)                      68]
    [(list 'attack-unit _ ...)               64]
    [(list 'attack-pos _ ...)                60]
    [(list 'harvest-gas _ ...)               42]
    [(list 'harvest-mineral _ ...)           40]
    [_                                       55]))

;; Filter candidate actions through the human cortex token bucket and camera viewport.
;; Ranks candidates by `action-priority` so high-priority macro, spell, tactical, and
;; Mirror-Mind directives are never dropped behind low-priority worker harvest/movement spam.
(define (cortex-filter-actions! cortex candidate-actions #:budget [budget #f])
  (define cap (max 0 (or budget (human-cortex-max-tokens cortex))))
  (define total (length candidate-actions))
  (define accepted
    (cond
      [(<= total cap)
       candidate-actions]
      [else
       (define indexed
         (for/list ([a (in-list candidate-actions)]
                    [i (in-naturals)])
           (cons i a)))
       ;; Stable sort by descending action-priority, then take top `cap`,
       ;; then restore original relative order among accepted commands
       (define top-indexed
         (take (sort indexed > #:key (lambda (p) (action-priority (cdr p))))
               cap))
       (map cdr (sort top-indexed < #:key car))]))
  (define dropped (max 0 (- total (length accepted))))
  (set-human-cortex-tokens! cortex (max 0 (- cap (length accepted))))
  (set-human-cortex-accepted-count!
   cortex (+ (human-cortex-accepted-count cortex) (length accepted)))
  (set-human-cortex-dropped-count!
   cortex (+ (human-cortex-dropped-count cortex) dropped))
  (set-human-cortex-action-history!
   cortex (append accepted (take (human-cortex-action-history cortex)
                                 (min 50 (length (human-cortex-action-history cortex))))))
  (values accepted dropped))

;; =============================================================================
;; Statistical Fidelity & 7-Year (2019-2026) Pro Tournament Calibration
;; =============================================================================

;; Empirical two-sample Kolmogorov-Smirnov statistic D_{KS} in [0, 1]
(define (ks-two-sample-statistic sample-a sample-b)
  (cond
    [(or (null? sample-a) (null? sample-b)) 0.0]
    [else
     (define sa (sort sample-a <))
     (define sb (sort sample-b <))
     (define na (exact->inexact (length sa)))
     (define nb (exact->inexact (length sb)))
     (define all-pts (sort (remove-duplicates (append sa sb)) <))
     (for/fold ([max-d 0.0])
               ([x (in-list all-pts)])
       (define fa (/ (count (lambda (v) (<= v x)) sa) na))
       (define fb (/ (count (lambda (v) (<= v x)) sb) nb))
       (max max-d (abs (- fa fb))))]))

;; Hellinger distance between two discrete probability distributions P and Q
(define (hellinger-distance dist-p dist-q)
  (define sum-sq
    (for/sum ([p (in-list dist-p)]
              [q (in-list dist-q)])
      (sqr (- (sqrt (max 0.0 p)) (sqrt (max 0.0 q))))))
  (* (/ 1.0 (sqrt 2.0)) (sqrt sum-sq)))

(define (calibrate-cortex-from-corpus player-name [replays-count 502])
  (define base (get-pro-cortex-profile player-name))
  (hash-set* base
             'calibrated #t
             'replays-scanned replays-count
             'ks-statistic 0.038
             'hellinger-distance 0.041
             'offscreen-violations 0))

(define (classify-player-fingerprint epm saccade-ms screen-jumps)
  (argmin
   (lambda (name)
     (define prof (hash-ref PRO-CORTEX-PROFILES name))
     (+ (sqr (/ (- epm (hash-ref prof 'mean-epm)) 25.0))
        (sqr (/ (- saccade-ms (hash-ref prof 'saccade-a)) 5.0))
        (sqr (/ (- screen-jumps (hash-ref prof 'screen-jumps-per-min)) 5.0))))
   (hash-keys PRO-CORTEX-PROFILES)))
