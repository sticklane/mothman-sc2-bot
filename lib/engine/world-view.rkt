#lang racket/base

;; =============================================================================
;; `lib/engine/world-view.rkt`
;; Layer 1 Immutable World Snapshot (Read-Only View for L2 Proposers & L3 Arbiter)
;;
;; Pure L0-only leaf module (depends ONLY on `sc2-types.rkt` and `sc2-common.rkt`).
;; Captures the single-step sanitized observation, same-frame opponent world
;; model summary, Mirror-Mind belief reading, spatio-temporal reachability, and
;; economy/threat snapshot so L2 domain proposers read consistent state without
;; reaching into giant mutable runtime contexts.
;; =============================================================================

(require (only-in "../sc2-types.rkt" normalize-race)
         "../sc2-common.rkt")

(provide
 (struct-out world-view)
 make-world-view
 world-view-extra
 world-view-with-extra)

(struct world-view
  (frame                 ;; exact-nonneg-integer
   race                  ;; symbol ('Zerg | 'Terran | 'Protoss | 'Random)
   enemy-race            ;; symbol ('Zerg | 'Terran | 'Protoss | 'Random | 'Unknown)
   live-obs?             ;; boolean
   obs                   ;; immutable sanitized observation hash
   posture               ;; symbol
   fap-score             ;; flonum
   owm-summary           ;; opponent-world-summary or #f (same-frame L1 update)
   mirror-summary        ;; mirror-mind-state / reading or #f
   reachability          ;; spatio-temporal reachability reading or #f
   base-x                ;; flonum
   base-y                ;; flonum
   nat-x                 ;; flonum
   nat-y                 ;; flonum
   third-x               ;; flonum
   third-y               ;; flonum
   enemy-x               ;; flonum
   enemy-y               ;; flonum
   minerals              ;; exact-nonneg-integer
   gas                   ;; exact-nonneg-integer
   supply-used           ;; exact-nonneg-integer
   supply-cap            ;; exact-nonneg-integer
   supply-left           ;; exact-integer
   larva-count           ;; exact-nonneg-integer
   ally-units            ;; list of unit hashes
   ally-buildings        ;; list of building hashes
   enemy-units           ;; list of unit hashes
   enemy-buildings       ;; list of building hashes
   under-attack?         ;; boolean
   enemy-near-main?      ;; boolean
   requires-anti-air?    ;; boolean
   requires-detection?   ;; boolean
   extras)               ;; immutable hasheq for forward-compatible Phase B/C data
  #:transparent)

(define (make-world-view
         #:frame [frame 0]
         #:race [race 'Random]
         #:enemy-race [enemy-race 'Unknown]
         #:live-obs? [live-obs? #f]
         #:obs [obs (hasheq)]
         #:posture [posture 'MacroStandard]
         #:fap-score [fap-score 0.0]
         #:owm-summary [owm-summary #f]
         #:mirror-summary [mirror-summary #f]
         #:reachability [reachability #f]
         #:base-x [base-x 32.5]
         #:base-y [base-y 32.5]
         #:nat-x [nat-x 45.0]
         #:nat-y [nat-y 45.0]
         #:third-x [third-x 60.0]
         #:third-y [third-y 60.0]
         #:enemy-x [enemy-x 160.5]
         #:enemy-y [enemy-y 160.5]
         #:minerals [minerals 0]
         #:gas [gas 0]
         #:supply-used [supply-used 0]
         #:supply-cap [supply-cap 0]
         #:supply-left [supply-left #f]
         #:larva-count [larva-count 0]
         #:ally-units [ally-units '()]
         #:ally-buildings [ally-buildings '()]
         #:enemy-units [enemy-units '()]
         #:enemy-buildings [enemy-buildings '()]
         #:under-attack? [under-attack? #f]
         #:enemy-near-main? [enemy-near-main? #f]
         #:requires-anti-air? [requires-anti-air? #f]
         #:requires-detection? [requires-detection? #f]
         #:extras [extras (hasheq)])
  (define s-used (safe-nonneg-int supply-used 0))
  (define s-cap (safe-nonneg-int supply-cap 0))
  (define s-left (if (exact-integer? supply-left) supply-left (- s-cap s-used)))
  (define im-obs
    (cond
      [(and (hash? obs) (immutable? obs)) obs]
      [(hash? obs) (for/hasheq ([(k v) (in-hash obs)]) (values k v))]
      [else (hasheq)]))
  (define im-extras
    (cond
      [(and (hash? extras) (immutable? extras)) extras]
      [(hash? extras) (for/hasheq ([(k v) (in-hash extras)]) (values k v))]
      [else (hasheq)]))
  (world-view
   (safe-nonneg-int frame 0)
   (normalize-race race)
   (normalize-race enemy-race)
   (not (not live-obs?))
   im-obs
   (if (symbol? posture) posture 'MacroStandard)
   (safe-finite-real fap-score 0.0)
   owm-summary
   mirror-summary
   reachability
   (safe-finite-real base-x 32.5)
   (safe-finite-real base-y 32.5)
   (safe-finite-real nat-x 45.0)
   (safe-finite-real nat-y 45.0)
   (safe-finite-real third-x 60.0)
   (safe-finite-real third-y 60.0)
   (safe-finite-real enemy-x 160.5)
   (safe-finite-real enemy-y 160.5)
   (safe-nonneg-int minerals 0)
   (safe-nonneg-int gas 0)
   s-used
   s-cap
   s-left
   (safe-nonneg-int larva-count 0)
   (safe-list ally-units)
   (safe-list ally-buildings)
   (safe-list enemy-units)
   (safe-list enemy-buildings)
   (not (not under-attack?))
   (not (not enemy-near-main?))
   (not (not requires-anti-air?))
   (not (not requires-detection?))
   im-extras))

(define (world-view-extra wv key [default #f])
  (if (world-view? wv)
      (hash-ref (world-view-extras wv) key default)
      default))

(define (world-view-with-extra wv key val)
  (struct-copy world-view wv
               [extras (hash-set (world-view-extras wv) key val)]))
