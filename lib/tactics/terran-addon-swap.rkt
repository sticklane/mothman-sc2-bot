#lang racket/base

;; =============================================================================
;; `lib/tactics/terran-addon-swap.rkt`
;; Pro Terran Production Building Lift-Off & Add-On Swapping Coordination:
;;   - 448-loop (`20.0s`) per-building relift cooldown
;;   - 1-to-1 add-on claim lock & donor offset landing pad tracking
;;   - 18-tile enemy threat abort guard
;; =============================================================================

(require racket/match
         racket/list
         racket/math
         "../sc2-common.rkt"
         "../sc2-game-constants.rkt")

(provide
 SC2-TERRAN-ADDON-RELIFT-COOLDOWN-FRAMES
 plan-terran-addon-swap)

;; Module-level anti-thrash state for Terran add-on swaps:
;; - `TERRAN-RELIFT-COOLDOWN-UNTIL`: `bldg-tag -> cooldown-until-frame` (`448` loops = `20.0s`)
;; - `TERRAN-DONOR-OFFSET-PAD`: `donor-tag -> (list issued-frame expires-frame pad-x pad-y donated-ax donated-ay)`
;; - `TERRAN-ADDON-CLAIM-LOCK`: `addon-key -> (list claimer-tag issued-frame expires-frame)`
(define SC2-TERRAN-ADDON-RELIFT-COOLDOWN-FRAMES 448)
(define TERRAN-RELIFT-COOLDOWN-UNTIL (make-hasheqv))
(define TERRAN-DONOR-OFFSET-PAD      (make-hasheqv))
(define TERRAN-ADDON-CLAIM-LOCK      (make-hasheqv))
(define LAST-TERRAN-SWAP-OBS-FRAME   (box -1))

;; Pro Terran Building Lift-Off & Add-On Swapping:
;; Swaps idle `Barracks` / `Factory` / `Starport` onto a pre-built `TechLab` or `Reactor`
;; with strict anti-thrash invariants:
;;   1. Both donor and recipient must have `build-progress >= 0.999`,
;;   2. Never strip `factory-techlab` off a `Factory` unless `allow-factory-techlab-strip?` is `#t`,
;;   3. Abort swaps (`'()`) when any enemy combat threat is within `18.0` tiles of `(base-x, base-y)`,
;;   4. Enforce a 1-to-1 add-on claim lock (at most 1 lifted/claiming building per free add-on)
;;      and a `448`-loop (`20s`) per-building re-lift cooldown, landing donors at `(donor-x, donor-y + 4.0)`.
(define (plan-terran-addon-swap obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define frame (hash-ref sanitized-obs 'frame 0))
  (when (or (<= frame 0) (< frame (unbox LAST-TERRAN-SWAP-OBS-FRAME)))
    (hash-clear! TERRAN-RELIFT-COOLDOWN-UNTIL)
    (hash-clear! TERRAN-DONOR-OFFSET-PAD)
    (hash-clear! TERRAN-ADDON-CLAIM-LOCK))
  (set-box! LAST-TERRAN-SWAP-OBS-FRAME frame)

  (define base-x (exact->inexact (hash-ref sanitized-obs 'base-x 32.0)))
  (define base-y (exact->inexact (hash-ref sanitized-obs 'base-y 32.0)))
  (define ally-bldgs (filter hash? (hash-ref sanitized-obs 'ally-buildings '())))
  (define enemy-units (filter hash? (hash-ref sanitized-obs 'enemy-units '())))

  ;; Abort swaps immediately when any enemy combat threat is within 18.0 tiles of `(base-x, base-y)`
  (define enemy-threat-near-base?
    (ormap (lambda (e)
             (define et (hash-ref e 'type 'unknown))
             (and (not (sc2-non-combat-or-summon-sym? et))
                  (not (memq et '(larva egg drone probe scv drone-burrowed)))
                  (not (hash-ref e 'is-hallucination #f))
                  (<= (dist2d base-x base-y
                              (exact->inexact (hash-ref e 'x 999.0))
                              (exact->inexact (hash-ref e 'y 999.0)))
                      18.0)))
           enemy-units))
  (cond
    [enemy-threat-near-base? '()]
    [else
     (define addon-syms
       '(barracks-techlab barracks-tech-lab barracks-reactor
         factory-techlab factory-tech-lab factory-reactor
         starport-techlab starport-tech-lab starport-reactor
         tech-lab techlab reactor))
     (define (bldg-complete? b)
       (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))
     (define all-ally-addons
       (filter (lambda (b)
                 (and (memq (hash-ref b 'type 'unknown) addon-syms)
                      (bldg-complete? b)))
               ally-bldgs))
     (define attached-addon-ids
       (for/fold ([acc '()]) ([b (in-list ally-bldgs)])
         (define atag (hash-ref b 'add-on-tag 0))
         (if (and (exact-integer? atag) (> atag 0))
             (cons atag acc)
             acc)))
     (define (bldg-is-flying-prod? b)
       (define bt (hash-ref b 'type 'unknown))
       (or (memq bt '(barracks-flying factory-flying starport-flying))
           (and (memq bt '(barracks factory starport))
                (or (eq? (hash-ref b 'flying? #f) #t)
                    (eq? (hash-ref b 'is-flying #f) #t)))))
     (define (bldg-has-addon? b)
       (or (eq? (hash-ref b 'has-addon? #f) #t)
           (not (not (hash-ref b 'addon #f)))
           (> (hash-ref b 'add-on-tag 0) 0)
           (let ([bx (exact->inexact (hash-ref b 'x 0.0))]
                 [by (exact->inexact (hash-ref b 'y 0.0))])
             (ormap (lambda (ad)
                      (<= (dist2d (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                  (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                  (exact->inexact (hash-ref ad 'x 9999.0))
                                  (exact->inexact (hash-ref ad 'y 9999.0)))
                          1.25))
                    all-ally-addons))))
     (define (bldg-attached-addon-sym b)
       (define explicit (hash-ref b 'addon #f))
       (cond
         [(symbol? explicit) explicit]
         [else
          (define atag (hash-ref b 'add-on-tag 0))
          (define by-tag
            (and (exact-integer? atag) (> atag 0)
                 (findf (lambda (ad) (= (hash-ref ad 'id -1) atag)) all-ally-addons)))
          (cond
            [by-tag (hash-ref by-tag 'type 'unknown)]
            [else
             (define bx (exact->inexact (hash-ref b 'x 0.0)))
             (define by (exact->inexact (hash-ref b 'y 0.0)))
             (define near-ad
               (findf (lambda (ad)
                        (<= (dist2d (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                    (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                    (exact->inexact (hash-ref ad 'x 9999.0))
                                    (exact->inexact (hash-ref ad 'y 9999.0)))
                            1.25))
                      all-ally-addons))
             (if near-ad (hash-ref near-ad 'type 'unknown) 'unknown)])]))

     (define ally-bldg-by-id
       (for/hasheqv ([b (in-list ally-bldgs)]
                     #:when (exact-integer? (hash-ref b 'id #f)))
         (values (hash-ref b 'id) b)))

     ;; Prune expired or satisfied add-on claims and donor offset records
     (for ([(akey entry) (in-hash (hash-copy TERRAN-ADDON-CLAIM-LOCK))])
       (match-define (list ctag _if exp-f) entry)
       (define cb (hash-ref ally-bldg-by-id ctag #f))
       (when (or (and (> frame 0) (>= frame exp-f))
                 (not cb)
                 (and (not (bldg-is-flying-prod? cb)) (bldg-has-addon? cb)))
         (hash-remove! TERRAN-ADDON-CLAIM-LOCK akey)))
     (for ([(dtag entry) (in-hash (hash-copy TERRAN-DONOR-OFFSET-PAD))])
       (match-define (list _if exp-f pad-x pad-y _dax _day) entry)
       (define db (hash-ref ally-bldg-by-id dtag #f))
       (when (or (and (> frame 0) (>= frame exp-f))
                 (not db)
                 (and (not (bldg-is-flying-prod? db))
                      (<= (dist2d (exact->inexact (hash-ref db 'x 0.0))
                                  (exact->inexact (hash-ref db 'y 0.0))
                                  pad-x pad-y)
                          1.5)))
         (hash-remove! TERRAN-DONOR-OFFSET-PAD dtag)))

     (define (addon-claim-key ad)
       (define aid (hash-ref ad 'id 0))
       (if (and (exact-integer? aid) (> aid 0))
           aid
           (+ (* 10000 (exact-round (* 2.0 (exact->inexact (hash-ref ad 'x 0.0)))))
              (exact-round (* 2.0 (exact->inexact (hash-ref ad 'y 0.0)))))))

     (define (addon-claim-key-xy ax ay [ad-opt #f])
       (if ad-opt
           (addon-claim-key ad-opt)
           (+ (* 10000 (exact-round (* 2.0 ax)))
              (exact-round (* 2.0 ay)))))

     (define (bldg-on-relift-cooldown? bid)
       (and (> frame 0)
            (< frame (hash-ref TERRAN-RELIFT-COOLDOWN-UNTIL bid 0))))

     (define (bldg-donated-addon? bid ax ay)
       (define dentry (hash-ref TERRAN-DONOR-OFFSET-PAD bid #f))
       (and dentry
            (<= (dist2d ax ay (fifth dentry) (sixth dentry)) 2.0)))

     (define (addon-available-for-bldg? ad bid)
       (define ax (exact->inexact (hash-ref ad 'x 34.5)))
       (define ay (exact->inexact (hash-ref ad 'y 31.5)))
       (and (not (bldg-donated-addon? bid ax ay))
            (let ([lock (hash-ref TERRAN-ADDON-CLAIM-LOCK (addon-claim-key ad) #f)]
                  [xy-lock (hash-ref TERRAN-ADDON-CLAIM-LOCK (addon-claim-key-xy ax ay #f) #f)])
              (and (or (not lock) (= (first lock) bid))
                   (or (not xy-lock) (= (first xy-lock) bid))))))

     (define (claim-addon-for-bldg! ad-or-false ax ay bid)
       (when (> bid 0)
         (define exp-f (+ (max 1 frame) SC2-TERRAN-ADDON-RELIFT-COOLDOWN-FRAMES))
         (when ad-or-false
           (hash-set! TERRAN-ADDON-CLAIM-LOCK (addon-claim-key ad-or-false) (list bid frame exp-f)))
         (hash-set! TERRAN-ADDON-CLAIM-LOCK (addon-claim-key-xy ax ay #f) (list bid frame exp-f))))

     (define orphaned-addons
       (filter (lambda (ad)
                 (define aid (hash-ref ad 'id 0))
                 (define ax (exact->inexact (hash-ref ad 'x 34.5)))
                 (define ay (exact->inexact (hash-ref ad 'y 31.5)))
                 (and (not (memv aid attached-addon-ids))
                      (not (ormap (lambda (b)
                                    (and (memq (hash-ref b 'type 'unknown) '(barracks factory starport))
                                         (not (bldg-is-flying-prod? b))
                                         (<= (dist2d (- ax SC2-TERRAN-ADDON-OFFSET-X)
                                                     (+ ay (- SC2-TERRAN-ADDON-OFFSET-Y))
                                                     (exact->inexact (hash-ref b 'x 9999.0))
                                                     (exact->inexact (hash-ref b 'y 9999.0)))
                                             1.25)))
                                  ally-bldgs))))
               all-ally-addons))
     (define explicit-free-addons (filter hash? (hash-ref sanitized-obs 'free-addons '())))
     (define free-addons
       (append explicit-free-addons
               (filter (lambda (ad)
                         (not (ormap (lambda (ef)
                                       (equal? (hash-ref ef 'id -1) (hash-ref ad 'id -2)))
                                     explicit-free-addons)))
                       orphaned-addons)))

     (define idle-lifted-list
       (filter (lambda (b)
                 (and (bldg-is-flying-prod? b)
                      (not (hash-ref b 'busy? #f))
                      (= (hash-ref b 'order-count 0) 0)))
               ally-bldgs))

     ;; Separate lifted donors (which MUST land at `(donor-x, donor-y + 4.0)` away from the add-on
     ;; they just donated!) from lifted recipients/other idle lifted buildings.
     (define lifted-donor
       (findf (lambda (b) (hash-has-key? TERRAN-DONOR-OFFSET-PAD (hash-ref b 'id 0)))
              idle-lifted-list))
     (define idle-lifted-recipient
       (findf (lambda (b) (not (hash-has-key? TERRAN-DONOR-OFFSET-PAD (hash-ref b 'id 0))))
              idle-lifted-list))

     (define bare-fac-or-port
       (findf (lambda (b)
                (define bid (hash-ref b 'id 0))
                (and (memq (hash-ref b 'type 'unknown) '(factory starport))
                     (bldg-complete? b)
                     (not (bldg-is-flying-prod? b))
                     (not (bldg-has-addon? b))
                     (not (hash-ref b 'busy? #f))
                     (or (not (bldg-on-relift-cooldown? bid))
                         (ormap (lambda (ad)
                                  (define lk (hash-ref TERRAN-ADDON-CLAIM-LOCK (addon-claim-key ad) #f))
                                  (and lk (= (first lk) bid)))
                                free-addons))))
              ally-bldgs))

     ;; Donor eligibility:
     ;; - Must be complete (`build-progress >= 0.999`), grounded, idle, and NOT on `448`-loop cooldown.
     ;; - Never strip `factory-techlab` off a `Factory` unless `allow-factory-techlab-strip?` is `#t`.
     ;; - In live games (`mineral-harvesters` present), never strip `barracks-techlab` off a `Barracks`;
     ;;   only swap `Reactor`s!
     (define allow-fac-tl-strip? (eq? (hash-ref sanitized-obs 'allow-factory-techlab-strip? #f) #t))
     (define allow-rax-tl-strip?
       (or (eq? (hash-ref sanitized-obs 'allow-barracks-techlab-strip? #f) #t)
           (not (hash-has-key? sanitized-obs 'mineral-harvesters))))
     (define donor-rax-or-fac
       (findf (lambda (b)
                (define bid (hash-ref b 'id 0))
                (define btype (hash-ref b 'type 'unknown))
                (and (memq btype '(barracks factory))
                     (bldg-complete? b)
                     (not (bldg-is-flying-prod? b))
                     (bldg-has-addon? b)
                     (not (hash-ref b 'busy? #f))
                     (not (bldg-on-relift-cooldown? bid))
                     (cond
                       [(eq? btype 'barracks)
                        (or allow-rax-tl-strip?
                            (memq (bldg-attached-addon-sym b) '(barracks-reactor reactor)))]
                       [else
                        (or allow-fac-tl-strip?
                            (memq (bldg-attached-addon-sym b) '(factory-reactor reactor)))])))
              ally-bldgs))

     (define donor-land-actions
       (if lifted-donor
           (let* ([did (hash-ref lifted-donor 'id 0)]
                  [drec (hash-ref TERRAN-DONOR-OFFSET-PAD did)]
                  [pad-x (third drec)]
                  [pad-y (fourth drec)])
             (list (list 'land-building did pad-x pad-y)))
           '()))

     (define recipient-or-swap-actions
       (cond
         ;; Case 0a: Idle lifted non-donor Barracks/Factory/Starport + unclaimed/owned free TechLab/Reactor -> land & attach!
         [(and idle-lifted-recipient
               (findf (lambda (ad) (addon-available-for-bldg? ad (hash-ref idle-lifted-recipient 'id 0)))
                      free-addons))
          => (lambda (addon)
               (define rid (hash-ref idle-lifted-recipient 'id 0))
               (define ax (exact->inexact (hash-ref addon 'x (+ base-x 6.5))))
               (define ay (exact->inexact (hash-ref addon 'y (+ base-y 3.5))))
               (claim-addon-for-bldg! addon ax ay rid)
               (when (> frame 0)
                 (hash-set! TERRAN-RELIFT-COOLDOWN-UNTIL rid (+ frame SC2-TERRAN-ADDON-RELIFT-COOLDOWN-FRAMES)))
               (list (list 'terran-addon-swap 0 rid ax ay)))]
         ;; Case 0b: Stranded idle lifted non-donor Barracks/Factory/Starport with no available free add-on -> land on clear ground!
         [idle-lifted-recipient
          (define bx (exact->inexact (hash-ref idle-lifted-recipient 'x (+ base-x 4.0))))
          (define by (exact->inexact (hash-ref idle-lifted-recipient 'y (+ base-y 4.0))))
          (list (list 'land-building (hash-ref idle-lifted-recipient 'id 0) bx by))]
         ;; Case 1: Free unattached TechLab/Reactor available + completed bare grounded Barracks/Factory/Starport
         [(and (not (null? free-addons))
               (let ([cand-rec
                      (or bare-fac-or-port
                          (findf (lambda (b)
                                   (define bid (hash-ref b 'id 0))
                                   (and (eq? (hash-ref b 'type 'unknown) 'barracks)
                                        (bldg-complete? b)
                                        (not (bldg-is-flying-prod? b))
                                        (not (bldg-has-addon? b))
                                        (not (hash-ref b 'busy? #f))
                                        (not (bldg-on-relift-cooldown? bid))))
                                 ally-bldgs))])
                 (and cand-rec
                      (let ([avail-ad (findf (lambda (ad) (addon-available-for-bldg? ad (hash-ref cand-rec 'id 0)))
                                             free-addons)])
                        (and avail-ad (cons cand-rec avail-ad))))))
          => (lambda (pair-ca)
               (define receiver (car pair-ca))
               (define addon (cdr pair-ca))
               (define rid (hash-ref receiver 'id 0))
               (define ax (exact->inexact (hash-ref addon 'x 34.5)))
               (define ay (exact->inexact (hash-ref addon 'y 31.5)))
               (claim-addon-for-bldg! addon ax ay rid)
               (list (list 'terran-addon-swap 0 rid ax ay)))]
         ;; Case 2: Active pro swap (`frame >= SC2-TERRAN-FIRST-ADDON-SWAP-FRAME`), only when no free add-ons exist
         [(and (null? donor-land-actions)
               (null? free-addons)
               bare-fac-or-port
               donor-rax-or-fac
               (not (eq? (hash-ref bare-fac-or-port 'type 'unknown)
                         (hash-ref donor-rax-or-fac 'type 'unknown)))
               (>= frame SC2-TERRAN-FIRST-ADDON-SWAP-FRAME))
          (define did (hash-ref donor-rax-or-fac 'id 0))
          (define rid (hash-ref bare-fac-or-port 'id 0))
          (define dx (exact->inexact (hash-ref donor-rax-or-fac 'x 32.0)))
          (define dy (exact->inexact (hash-ref donor-rax-or-fac 'y 32.0)))
          (define ax (exact->inexact (hash-ref donor-rax-or-fac 'addon-x (+ dx 2.5))))
          (define ay (exact->inexact (hash-ref donor-rax-or-fac 'addon-y (- dy 0.5))))
          (define donor-ad
            (findf (lambda (ad)
                     (<= (dist2d ax ay
                                 (exact->inexact (hash-ref ad 'x 9999.0))
                                 (exact->inexact (hash-ref ad 'y 9999.0)))
                         1.25))
                   all-ally-addons))
          (define exp-f (+ frame SC2-TERRAN-ADDON-RELIFT-COOLDOWN-FRAMES))
          (hash-set! TERRAN-RELIFT-COOLDOWN-UNTIL did exp-f)
          (hash-set! TERRAN-DONOR-OFFSET-PAD did (list frame exp-f dx (+ dy 4.0) ax ay))
          (claim-addon-for-bldg! donor-ad ax ay rid)
          (list (list 'terran-addon-swap did rid ax ay))]
         [else '()]))

     (append donor-land-actions recipient-or-swap-actions)]))
