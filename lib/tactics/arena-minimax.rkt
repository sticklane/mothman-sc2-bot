#lang racket/base

;; =============================================================================
;; `lib/tactics/arena-minimax.rkt`
;; Multi-Depth Mirrored Tactical Micro Brain (`step-tactical-mirror-brain!`):
;;   - Spatial single-linkage arena clustering (`cluster-tactical-arenas`)
;;   - 2D kinematic & weapon-cooldown mirrored rollout (`simulate-mirrored-arena-pair`)
;;   - Regret-hedged minimax & commitment hysteresis (`evaluate-arena-minimax-and-regret!`)
;;   - Per-unit command synthesis gated by `order-ledger`
;; =============================================================================

(require racket/match
         racket/list
         racket/math
         racket/set
         racket/flonum
         racket/fixnum
         racket/unsafe/ops
         "../sc2-common.rkt"
         "../sc2-game-constants.rkt"
         "../sc2-combat-eval.rkt"
         "order-ledger.rkt"
         (only-in "zerg-burrow-micro.rkt"
                  plan-avoid-siege-tank-and-lurker-splash-zones
                  disruptor-nova-catchable-range))

(define KERNEL-FSTRIDE 19)
(define KERNEL-ISTRIDE 6)

(define (reset-bufs! dst-fl dst-fx src-fl src-fx n)
  (let ([fn (unsafe-fx* n KERNEL-FSTRIDE)]
        [ix (unsafe-fx* n KERNEL-ISTRIDE)])
    (let loop-f ([i 0])
      (when (unsafe-fx< i fn)
        (unsafe-flvector-set! dst-fl i (unsafe-flvector-ref src-fl i))
        (loop-f (unsafe-fx+ i 1))))
    (let loop-i ([i 0])
      (when (unsafe-fx< i ix)
        (unsafe-fxvector-set! dst-fx i (unsafe-fxvector-ref src-fx i))
        (loop-i (unsafe-fx+ i 1))))))

(define (step-side-buf! a-fl a-fx na o-fl o-fx ne act opp-det? side-z-idx opp-z-idx ally-side? ally-wc scratch params)
  ;; scratch[15] = elev-mult, scratch[5] = bv-sc, scratch[6] = bw-hp
  (let ([sz (unsafe-flvector-ref params side-z-idx)]
        [oz (unsafe-flvector-ref params opp-z-idx)])
    (cond
      [(unsafe-fl> sz (unsafe-fl+ oz 0.5)) (unsafe-flvector-set! scratch 15 1.15)]
      [(unsafe-fl< sz (unsafe-fl- oz 0.5)) (unsafe-flvector-set! scratch 15 0.85)]
      [else (unsafe-flvector-set! scratch 15 1.0)]))
  (define fallback-j
    (let loop ([j 0])
      (cond
        [(unsafe-fx>= j ne) -1]
        [else
         (define ob (unsafe-fx* j KERNEL-FSTRIDE))
         (if (and (unsafe-fl> (unsafe-flvector-ref o-fl ob) 0.0)
                  (unsafe-fl<= (unsafe-flvector-ref o-fl (unsafe-fx+ ob 18)) 0.0))
             j
             (loop (unsafe-fx+ j 1)))])))
  (when (unsafe-fx>= fallback-j 0)
    (define cloak-workers? (unsafe-fx= act 4))
    (define focus-or-chase? (or (unsafe-fx= act 0) (unsafe-fx= act 2)))
    (define retreat? (unsafe-fx= act 5))
    (define hold-choke? (unsafe-fx= act 6))
    (define flank? (unsafe-fx= act 3))
    (define stutter-kite? (or (unsafe-fx= act 1) cloak-workers?))
    (let uloop ([ui 0])
      (when (unsafe-fx< ui na)
        (define ub (unsafe-fx* ui KERNEL-FSTRIDE))
        (define uib (unsafe-fx* ui KERNEL-ISTRIDE))
        (when (and (unsafe-fl> (unsafe-flvector-ref a-fl ub) 0.0)
                   (unsafe-fl<= (unsafe-flvector-ref a-fl (unsafe-fx+ ub 18)) 0.0))
          (define-values (best-valid best-worker)
            (cond
              [focus-or-chase?
               (unsafe-flvector-set! scratch 5 -inf.0)
               (let oloop ([oj 0] [bv -1])
                 (if (unsafe-fx>= oj ne)
                     (values bv -1)
                     (let ([ob (unsafe-fx* oj KERNEL-FSTRIDE)]
                           [oib (unsafe-fx* oj KERNEL-ISTRIDE)])
                       (if (and (unsafe-fl> (unsafe-flvector-ref o-fl ob) 0.0)
                                (unsafe-fl<= (unsafe-flvector-ref o-fl (unsafe-fx+ ob 18)) 0.0)
                                (or (unsafe-fx= (unsafe-fxvector-ref o-fx (unsafe-fx+ oib 2)) 0) opp-det?)
                                (unsafe-fl> (if (unsafe-fx= (unsafe-fxvector-ref o-fx oib) 1)
                                                (unsafe-flvector-ref a-fl (unsafe-fx+ ub 6))
                                                (unsafe-flvector-ref a-fl (unsafe-fx+ ub 5)))
                                            0.0))
                           (let* ([dx (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ob 15))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 15)))]
                                  [dy (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ob 16))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 16)))]
                                  [d2 (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy))]
                                  [ehp-c (unsafe-flmax 1.0 (unsafe-fl+ (unsafe-flvector-ref o-fl ob)
                                                                       (unsafe-flvector-ref o-fl (unsafe-fx+ ob 2))))]
                                  [dps-num (unsafe-fl+ 5.0 (unsafe-fl+ (unsafe-flvector-ref o-fl (unsafe-fx+ ob 5))
                                                                       (unsafe-flvector-ref o-fl (unsafe-fx+ ob 6))))]
                                  [r (unsafe-flmax 1.0
                                                   (if (unsafe-fx= (unsafe-fxvector-ref o-fx oib) 1)
                                                       (unsafe-flvector-ref a-fl (unsafe-fx+ ub 8))
                                                       (unsafe-flvector-ref a-fl (unsafe-fx+ ub 7))))]
                                  [sc (if (unsafe-fl<= d2 (unsafe-fl* r r))
                                          (unsafe-fl/ dps-num ehp-c)
                                          (unsafe-fl/ (unsafe-fl* dps-num r)
                                                      (unsafe-fl* ehp-c (unsafe-flsqrt d2))))])
                             (if (unsafe-fl> sc (unsafe-flvector-ref scratch 5))
                                 (begin
                                   (unsafe-flvector-set! scratch 5 sc)
                                   (oloop (unsafe-fx+ oj 1) oj))
                                 (oloop (unsafe-fx+ oj 1) bv)))
                           (oloop (unsafe-fx+ oj 1) bv)))))]
              [cloak-workers?
               (unsafe-flvector-set! scratch 5 +inf.0)
               (unsafe-flvector-set! scratch 6 +inf.0)
               (let oloop ([oj 0] [bv -1] [bw -1])
                 (if (unsafe-fx>= oj ne)
                     (values bv bw)
                     (let ([ob (unsafe-fx* oj KERNEL-FSTRIDE)]
                           [oib (unsafe-fx* oj KERNEL-ISTRIDE)])
                       (if (and (unsafe-fl> (unsafe-flvector-ref o-fl ob) 0.0)
                                (unsafe-fl<= (unsafe-flvector-ref o-fl (unsafe-fx+ ob 18)) 0.0)
                                (or (unsafe-fx= (unsafe-fxvector-ref o-fx (unsafe-fx+ oib 2)) 0) opp-det?)
                                (unsafe-fl> (if (unsafe-fx= (unsafe-fxvector-ref o-fx oib) 1)
                                                (unsafe-flvector-ref a-fl (unsafe-fx+ ub 6))
                                                (unsafe-flvector-ref a-fl (unsafe-fx+ ub 5)))
                                            0.0))
                           (let* ([dx (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ob 15))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 15)))]
                                  [dy (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ob 16))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 16)))]
                                  [d2 (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy))]
                                  [w-match? (not (unsafe-fx= (unsafe-fxand (unsafe-fxvector-ref o-fx (unsafe-fx+ oib 4)) 16) 0))]
                                  [nbw (if w-match?
                                           (let ([ehp (unsafe-fl+ (unsafe-flvector-ref o-fl ob)
                                                                  (unsafe-flvector-ref o-fl (unsafe-fx+ ob 2)))])
                                             (if (unsafe-fl< ehp (unsafe-flvector-ref scratch 6))
                                                 (begin
                                                   (unsafe-flvector-set! scratch 6 ehp)
                                                   oj)
                                                 bw))
                                           bw)])
                             (if (unsafe-fl< d2 (unsafe-flvector-ref scratch 5))
                                 (begin
                                   (unsafe-flvector-set! scratch 5 d2)
                                   (oloop (unsafe-fx+ oj 1) oj nbw))
                                 (oloop (unsafe-fx+ oj 1) bv nbw)))
                           (oloop (unsafe-fx+ oj 1) bv bw)))))]
              [else
               (unsafe-flvector-set! scratch 5 +inf.0)
               (let oloop ([oj 0] [bv -1])
                 (if (unsafe-fx>= oj ne)
                     (values bv -1)
                     (let ([ob (unsafe-fx* oj KERNEL-FSTRIDE)]
                           [oib (unsafe-fx* oj KERNEL-ISTRIDE)])
                       (if (and (unsafe-fl> (unsafe-flvector-ref o-fl ob) 0.0)
                                (unsafe-fl<= (unsafe-flvector-ref o-fl (unsafe-fx+ ob 18)) 0.0)
                                (or (unsafe-fx= (unsafe-fxvector-ref o-fx (unsafe-fx+ oib 2)) 0) opp-det?)
                                (unsafe-fl> (if (unsafe-fx= (unsafe-fxvector-ref o-fx oib) 1)
                                                (unsafe-flvector-ref a-fl (unsafe-fx+ ub 6))
                                                (unsafe-flvector-ref a-fl (unsafe-fx+ ub 5)))
                                            0.0))
                           (let* ([dx (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ob 15))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 15)))]
                                  [dy (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ob 16))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 16)))]
                                  [d2 (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy))])
                             (if (unsafe-fl< d2 (unsafe-flvector-ref scratch 5))
                                 (begin
                                   (unsafe-flvector-set! scratch 5 d2)
                                   (oloop (unsafe-fx+ oj 1) oj))
                                 (oloop (unsafe-fx+ oj 1) bv)))
                           (oloop (unsafe-fx+ oj 1) bv)))))]))
          (define tidx
            (cond [(unsafe-fx>= best-worker 0) best-worker]
                  [(unsafe-fx>= best-valid 0) best-valid]
                  [else fallback-j]))
          (define can-hit? (unsafe-fx>= best-valid 0))
          (define tb (unsafe-fx* tidx KERNEL-FSTRIDE))
          (define tib (unsafe-fx* tidx KERNEL-ISTRIDE))
          (define t-fly? (unsafe-fx= (unsafe-fxvector-ref o-fx tib) 1))
          (define af (unsafe-fxvector-ref a-fx (unsafe-fx+ uib 4)))
          (let* ([ux (unsafe-flvector-ref a-fl (unsafe-fx+ ub 15))]
                 [uy (unsafe-flvector-ref a-fl (unsafe-fx+ ub 16))]
                 [dx (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ tb 15)) ux)]
                 [dy (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ tb 16)) uy)]
                 [dist (unsafe-flmax 0.25 (unsafe-flsqrt (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy))))]
                 [nx (unsafe-fl/ dx dist)]
                 [ny (unsafe-fl/ dy dist)]
                 [wrange (unsafe-fl* (unsafe-flvector-ref scratch 15)
                                     (unsafe-fl+ (if t-fly?
                                                     (unsafe-flvector-ref a-fl (unsafe-fx+ ub 8))
                                                     (unsafe-flvector-ref a-fl (unsafe-fx+ ub 7)))
                                                 (unsafe-fl+ (unsafe-flvector-ref a-fl (unsafe-fx+ ub 17))
                                                             (unsafe-flvector-ref o-fl (unsafe-fx+ tb 17)))))]
                 [spd (unsafe-flvector-ref a-fl (unsafe-fx+ ub 4))]
                 [cd (unsafe-flvector-ref a-fl (unsafe-fx+ ub 11))]
                 [dt (unsafe-flvector-ref params 4)])
            (cond
              [retreat?
               (define step-d (unsafe-fl* spd dt))
               (unsafe-flvector-set! a-fl (unsafe-fx+ ub 15) (unsafe-fl- ux (unsafe-fl* step-d nx)))
               (unsafe-flvector-set! a-fl (unsafe-fx+ ub 16) (unsafe-fl- uy (unsafe-fl* step-d ny)))]
              [(and can-hit? (unsafe-fl<= dist wrange) (unsafe-fl<= cd 0.0))
               (define drill-mult
                 (if (and ally-side?
                          (unsafe-fx>= ally-wc 3)
                          (not (unsafe-fx= (unsafe-fxand af 16) 0))
                          (unsafe-fl<= dist 4.0))
                     1.35
                     1.0))
               (define base-dps
                 (if t-fly?
                     (unsafe-flvector-ref a-fl (unsafe-fx+ ub 6))
                     (unsafe-flvector-ref a-fl (unsafe-fx+ ub 5))))
               (define tf (unsafe-fxvector-ref o-fx (unsafe-fx+ tib 4)))
               (define attr-mult
                 (cond
                   [(and (not (unsafe-fx= (unsafe-fxand af 1) 0))
                         (not (unsafe-fx= (unsafe-fxand tf 2) 0)))
                    1.45]
                   [(and (not (unsafe-fx= (unsafe-fxand af 4) 0))
                         (not (unsafe-fx= (unsafe-fxand tf 8) 0)))
                    1.55]
                   [else 1.0]))
               (define weapon-dps (if (unsafe-fl<= base-dps 0.0) 0.0 (unsafe-fl* base-dps attr-mult)))
               (define wperiod (unsafe-flvector-ref a-fl (unsafe-fx+ ub 9)))
               (define eff-dmg
                 (unsafe-flmax 1.0
                               (unsafe-fl- (unsafe-fl* (unsafe-flvector-ref scratch 15)
                                                       (unsafe-fl* drill-mult (unsafe-fl* weapon-dps wperiod)))
                                           (unsafe-flvector-ref o-fl (unsafe-fx+ tb 3)))))
               (define shd (unsafe-flvector-ref o-fl (unsafe-fx+ tb 2)))
               (cond
                 [(unsafe-fl>= shd eff-dmg)
                  (unsafe-flvector-set! o-fl (unsafe-fx+ tb 2) (unsafe-fl- shd eff-dmg))]
                 [else
                  (unsafe-flvector-set! o-fl (unsafe-fx+ tb 2) 0.0)
                  (unsafe-flvector-set! o-fl tb (unsafe-fl- (unsafe-flvector-ref o-fl tb) (unsafe-fl- eff-dmg shd)))])
               (define srad (unsafe-flvector-ref a-fl (unsafe-fx+ ub 12)))
               (when (unsafe-fl> srad 0.5)
                 (unsafe-flvector-set! scratch 16 (unsafe-fl* srad srad))
                 (unsafe-flvector-set! scratch 17 (unsafe-fl* (if flank? 0.25 0.50) eff-dmg))
                 (let aloop ([aj 0])
                   (when (unsafe-fx< aj ne)
                     (unless (unsafe-fx= aj tidx)
                       (define ab (unsafe-fx* aj KERNEL-FSTRIDE))
                       (define aib (unsafe-fx* aj KERNEL-ISTRIDE))
                       (when (and (unsafe-fl> (unsafe-flvector-ref o-fl ab) 0.0)
                                  (unsafe-fl<= (unsafe-flvector-ref o-fl (unsafe-fx+ ab 18)) 0.0)
                                  (or (unsafe-fx= (unsafe-fxvector-ref o-fx (unsafe-fx+ aib 2)) 0) opp-det?)
                                  (unsafe-fl> (if (unsafe-fx= (unsafe-fxvector-ref o-fx aib) 1)
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 6))
                                                  (unsafe-flvector-ref a-fl (unsafe-fx+ ub 5)))
                                              0.0))
                         (define adx (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ab 15))
                                                 (unsafe-flvector-ref o-fl (unsafe-fx+ tb 15))))
                         (define ady (unsafe-fl- (unsafe-flvector-ref o-fl (unsafe-fx+ ab 16))
                                                 (unsafe-flvector-ref o-fl (unsafe-fx+ tb 16))))
                         (when (unsafe-fl<= (unsafe-fl+ (unsafe-fl* adx adx) (unsafe-fl* ady ady))
                                            (unsafe-flvector-ref scratch 16))
                           (unsafe-flvector-set! o-fl ab
                                                 (unsafe-fl- (unsafe-flvector-ref o-fl ab)
                                                             (unsafe-flvector-ref scratch 17))))))
                     (aloop (unsafe-fx+ aj 1)))))
               (unsafe-flvector-set! a-fl (unsafe-fx+ ub 11) wperiod)
               (define move-dt (unsafe-flmax 0.0 (unsafe-fl- dt (unsafe-flvector-ref a-fl (unsafe-fx+ ub 10)))))
               (when (and (unsafe-fl> move-dt 0.0) stutter-kite?)
                 (define mdist (unsafe-fl* spd move-dt))
                 (unsafe-flvector-set! a-fl (unsafe-fx+ ub 15) (unsafe-fl- ux (unsafe-fl* mdist nx)))
                 (unsafe-flvector-set! a-fl (unsafe-fx+ ub 16) (unsafe-fl- uy (unsafe-fl* mdist ny))))]
              [(unsafe-fl> cd 0.0)
               (cond
                 [stutter-kite?
                  (define mdist (unsafe-fl* spd dt))
                  (unsafe-flvector-set! a-fl (unsafe-fx+ ub 15) (unsafe-fl- ux (unsafe-fl* mdist nx)))
                  (unsafe-flvector-set! a-fl (unsafe-fx+ ub 16) (unsafe-fl- uy (unsafe-fl* mdist ny)))]
                 [focus-or-chase?
                  (when (unsafe-fl> dist (unsafe-fl* 0.80 wrange))
                    (define mdist (unsafe-fl* spd dt))
                    (unsafe-flvector-set! a-fl (unsafe-fx+ ub 15) (unsafe-fl+ ux (unsafe-fl* mdist nx)))
                    (unsafe-flvector-set! a-fl (unsafe-fx+ ub 16) (unsafe-fl+ uy (unsafe-fl* mdist ny))))]
                 [flank?
                  (define mdist (unsafe-fl* 0.70 (unsafe-fl* spd dt)))
                  (unsafe-flvector-set! a-fl (unsafe-fx+ ub 15) (unsafe-fl+ ux (unsafe-fl* mdist (unsafe-fl- 0.0 ny))))
                  (unsafe-flvector-set! a-fl (unsafe-fx+ ub 16) (unsafe-fl+ uy (unsafe-fl* mdist nx)))]
                 [else (void)])]
              [(not hold-choke?)
               (define mdist (unsafe-fl* spd dt))
               (unsafe-flvector-set! a-fl (unsafe-fx+ ub 15) (unsafe-fl+ ux (unsafe-fl* mdist nx)))
               (unsafe-flvector-set! a-fl (unsafe-fx+ ub 16) (unsafe-fl+ uy (unsafe-fl* mdist ny)))])))
        (uloop (unsafe-fx+ ui 1))))))

(define (compute-net-val-buf! a-fl a-fx na e-fl e-fx ne params scratch out-idx)
  (unsafe-flvector-set! scratch 0 0.0)
  (unsafe-flvector-set! scratch 1 0.0)
  (define hl
    (let loop ([i 0] [hl 0])
      (if (unsafe-fx>= i na)
          hl
          (let* ([b (unsafe-fx* i KERNEL-FSTRIDE)]
                 [hp (unsafe-flvector-ref a-fl b)])
            (if (unsafe-fl> hp 0.0)
                (let ([c (unsafe-flvector-ref a-fl (unsafe-fx+ b 14))]
                      [sh (unsafe-flvector-ref a-fl (unsafe-fx+ b 2))]
                      [mhp (unsafe-flvector-ref a-fl (unsafe-fx+ b 1))])
                  (unsafe-flvector-set! scratch 0 (unsafe-fl+ (unsafe-flvector-ref scratch 0) c))
                  (unsafe-flvector-set! scratch 1
                    (unsafe-fl+ (unsafe-flvector-ref scratch 1)
                                (unsafe-fl* c (unsafe-fl/ (unsafe-fl+ hp sh)
                                                          (unsafe-flmax 1.0 (unsafe-fl+ mhp sh))))))
                  (loop (unsafe-fx+ i 1) hl))
                (let ([ib (unsafe-fx* i KERNEL-ISTRIDE)])
                  (loop (unsafe-fx+ i 1)
                        (if (not (unsafe-fx= (unsafe-fxand (unsafe-fxvector-ref a-fx (unsafe-fx+ ib 4)) 32) 0))
                            (unsafe-fx+ hl 1) hl))))))))
  (unsafe-flvector-set! scratch 2 0.0)
  (unsafe-flvector-set! scratch 3 0.0)
  (define wk
    (let loop ([j 0] [wk 0])
      (if (unsafe-fx>= j ne)
          wk
          (let* ([b (unsafe-fx* j KERNEL-FSTRIDE)]
                 [hp (unsafe-flvector-ref e-fl b)])
            (if (unsafe-fl> hp 0.0)
                (let ([c (unsafe-flvector-ref e-fl (unsafe-fx+ b 14))]
                      [sh (unsafe-flvector-ref e-fl (unsafe-fx+ b 2))]
                      [mhp (unsafe-flvector-ref e-fl (unsafe-fx+ b 1))])
                  (unsafe-flvector-set! scratch 2 (unsafe-fl+ (unsafe-flvector-ref scratch 2) c))
                  (unsafe-flvector-set! scratch 3
                    (unsafe-fl+ (unsafe-flvector-ref scratch 3)
                                (unsafe-fl* c (unsafe-fl/ (unsafe-fl+ hp sh)
                                                          (unsafe-flmax 1.0 (unsafe-fl+ mhp sh))))))
                  (loop (unsafe-fx+ j 1) wk))
                (let ([ib (unsafe-fx* j KERNEL-ISTRIDE)])
                  (loop (unsafe-fx+ j 1)
                        (if (not (unsafe-fx= (unsafe-fxand (unsafe-fxvector-ref e-fx (unsafe-fx+ ib 4)) 16) 0))
                            (unsafe-fx+ wk 1) wk))))))))
  (unsafe-flvector-set! scratch out-idx
    (unsafe-fl+ (unsafe-fl- (unsafe-fl- (unsafe-flvector-ref params 3) (unsafe-flvector-ref scratch 2))
                            (unsafe-fl- (unsafe-flvector-ref params 2) (unsafe-flvector-ref scratch 0)))
                (unsafe-fl+ (unsafe-fl* 0.45 (unsafe-fl- (unsafe-flvector-ref scratch 1)
                                                         (unsafe-flvector-ref scratch 3)))
                            (unsafe-fl- (unsafe-fl* (unsafe-flvector-ref params 10) (unsafe-fx->fl wk))
                                        (unsafe-fl* (unsafe-flvector-ref params 11) (unsafe-fx->fl hl)))))))

(define (sim-pair-score-buf! init-a-fl init-a-fx sim-a-fl sim-a-fx na
                             init-e-fl init-e-fx sim-e-fl sim-e-fx ne
                             trap-xy ntraps
                             our-act enemy-act
                             ally-det? enemy-det? check-stasis?
                             d1t d2t d3t params scratch out-idx)
  (reset-bufs! sim-a-fl sim-a-fx init-a-fl init-a-fx na)
  (reset-bufs! sim-e-fl sim-e-fx init-e-fl init-e-fx ne)
  (define cloak-harass? (unsafe-fx= our-act 4))
  (define check-traps? (and check-stasis? (or (unsafe-fx= our-act 0) (unsafe-fx= our-act 2) (unsafe-fx= our-act 6))))
  (define ntraps2 (unsafe-fx* ntraps 2))
  (unsafe-flvector-set! scratch 7 0.0)
  (unsafe-flvector-set! scratch 8 0.0)
  (let tloop ([tick 1])
    (when (unsafe-fx<= tick d3t)
      (define dt (unsafe-flvector-ref params 4))
      (define ally-wc
        (let loop ([i 0] [wc 0])
          (if (unsafe-fx>= i na)
              wc
              (let ([b (unsafe-fx* i KERNEL-FSTRIDE)]
                    [ib (unsafe-fx* i KERNEL-ISTRIDE)])
                (when (and cloak-harass?
                           (unsafe-fx= (unsafe-fxvector-ref sim-a-fx (unsafe-fx+ ib 3)) 1)
                           (unsafe-fl>= (unsafe-flvector-ref sim-a-fl (unsafe-fx+ b 13)) 25.0))
                  (unsafe-fxvector-set! sim-a-fx (unsafe-fx+ ib 2) 1))
                (let ([eta (unsafe-flvector-ref sim-a-fl (unsafe-fx+ b 18))])
                  (when (unsafe-fl> eta 0.0)
                    (unsafe-flvector-set! sim-a-fl (unsafe-fx+ b 18) (unsafe-flmax 0.0 (unsafe-fl- eta dt)))))
                (let ([cd (unsafe-flvector-ref sim-a-fl (unsafe-fx+ b 11))])
                  (when (unsafe-fl> cd 0.0)
                    (unsafe-flvector-set! sim-a-fl (unsafe-fx+ b 11) (unsafe-flmax 0.0 (unsafe-fl- cd dt)))))
                (loop (unsafe-fx+ i 1)
                      (if (and (unsafe-fl> (unsafe-flvector-ref sim-a-fl b) 0.0)
                               (not (unsafe-fx= (unsafe-fxand (unsafe-fxvector-ref sim-a-fx (unsafe-fx+ ib 4)) 16) 0)))
                          (unsafe-fx+ wc 1)
                          wc))))))
      (let loop ([j 0])
        (when (unsafe-fx< j ne)
          (define b (unsafe-fx* j KERNEL-FSTRIDE))
          (let ([eta (unsafe-flvector-ref sim-e-fl (unsafe-fx+ b 18))])
            (when (unsafe-fl> eta 0.0)
              (unsafe-flvector-set! sim-e-fl (unsafe-fx+ b 18) (unsafe-flmax 0.0 (unsafe-fl- eta dt)))))
          (let ([cd (unsafe-flvector-ref sim-e-fl (unsafe-fx+ b 11))])
            (when (unsafe-fl> cd 0.0)
              (unsafe-flvector-set! sim-e-fl (unsafe-fx+ b 11) (unsafe-flmax 0.0 (unsafe-fl- cd dt)))))
          (loop (unsafe-fx+ j 1))))
      (when check-traps?
        (define has-active-trap?
          (or (unsafe-fx> ntraps 0)
              (let loop ([j 0])
                (and (unsafe-fx< j ne)
                     (or (and (unsafe-fl> (unsafe-flvector-ref sim-e-fl (unsafe-fx* j KERNEL-FSTRIDE)) 0.0)
                              (unsafe-fx= (unsafe-fxvector-ref sim-e-fx (unsafe-fx+ (unsafe-fx* j KERNEL-ISTRIDE) 5)) 1))
                         (loop (unsafe-fx+ j 1)))))))
        (when has-active-trap?
          (let aloop ([i 0])
            (when (unsafe-fx< i na)
              (define b (unsafe-fx* i KERNEL-FSTRIDE))
              (define ib (unsafe-fx* i KERNEL-ISTRIDE))
              (define hp (unsafe-flvector-ref sim-a-fl b))
              (when (and (unsafe-fl> hp 0.0)
                         (unsafe-fx= (unsafe-fxvector-ref sim-a-fx ib) 0)
                         (unsafe-fl<= (unsafe-flvector-ref sim-a-fl (unsafe-fx+ b 7)) 4.5))
                (define near-trap?
                  (let ([ax (unsafe-flvector-ref sim-a-fl (unsafe-fx+ b 15))]
                        [ay (unsafe-flvector-ref sim-a-fl (unsafe-fx+ b 16))])
                    (or (let eloop ([j 0])
                          (and (unsafe-fx< j ne)
                               (let ([eb (unsafe-fx* j KERNEL-FSTRIDE)]
                                     [eib (unsafe-fx* j KERNEL-ISTRIDE)])
                                 (or (and (unsafe-fl> (unsafe-flvector-ref sim-e-fl eb) 0.0)
                                          (unsafe-fx= (unsafe-fxvector-ref sim-e-fx (unsafe-fx+ eib 5)) 1)
                                          (let ([dx (unsafe-fl- ax (unsafe-flvector-ref sim-e-fl (unsafe-fx+ eb 15)))]
                                                [dy (unsafe-fl- ay (unsafe-flvector-ref sim-e-fl (unsafe-fx+ eb 16)))])
                                            (unsafe-fl<= (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy)) 20.25)))
                                     (eloop (unsafe-fx+ j 1))))))
                        (let tscan ([ti 0])
                          (and (unsafe-fx< ti ntraps2)
                               (let ([dx (unsafe-fl- ax (unsafe-flvector-ref trap-xy ti))]
                                     [dy (unsafe-fl- ay (unsafe-flvector-ref trap-xy (unsafe-fx+ ti 1)))])
                                 (or (unsafe-fl<= (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy)) 20.25)
                                     (tscan (unsafe-fx+ ti 2)))))))))
                (when near-trap?
                  (unsafe-flvector-set! sim-a-fl b (unsafe-flmax 1.0 (unsafe-fl- hp (unsafe-fl* 18.0 dt))))))
              (aloop (unsafe-fx+ i 1))))))
      (step-side-buf! sim-a-fl sim-a-fx na sim-e-fl sim-e-fx ne our-act enemy-det? 0 1 #t ally-wc scratch params)
      (step-side-buf! sim-e-fl sim-e-fx ne sim-a-fl sim-a-fx na enemy-act ally-det? 1 0 #f ally-wc scratch params)
      (when (unsafe-fx= tick d1t)
        (compute-net-val-buf! sim-a-fl sim-a-fx na sim-e-fl sim-e-fx ne params scratch 7))
      (when (unsafe-fx= tick d2t)
        (compute-net-val-buf! sim-a-fl sim-a-fx na sim-e-fl sim-e-fx ne params scratch 8))
      (tloop (unsafe-fx+ tick 1))))
  (compute-net-val-buf! sim-a-fl sim-a-fx na sim-e-fl sim-e-fx ne params scratch 9)
  (unsafe-flvector-set! scratch out-idx
    (unsafe-fl+ (unsafe-fl+ (unsafe-fl* (unsafe-flvector-ref params 5) (unsafe-flvector-ref scratch 7))
                            (unsafe-fl* (unsafe-flvector-ref params 6) (unsafe-flvector-ref scratch 8)))
                (unsafe-fl* (unsafe-flvector-ref params 7) (unsafe-flvector-ref scratch 9)))))

(define (eval-arena-minimax-kernel! init-a-fl init-a-fx sim-a-fl sim-a-fx na
                                    init-e-fl init-e-fx sim-e-fl sim-e-fx ne
                                    trap-xy ntraps
                                    our-cands-fx n-our enemy-cands-fx n-en cur-committed-code
                                    ally-det? enemy-det? check-stasis?
                                    d1t d2t d3t
                                    params scratch out-vals)
  (define oa0 (unsafe-fxvector-ref our-cands-fx 0))
  (unsafe-flvector-set! scratch 10 +inf.0) ;; pred-val0
  (unsafe-flvector-set! scratch 16 +inf.0) ;; eng-min0 (ea != 5)
  (unsafe-flvector-set! scratch 17 0.0)    ;; eng-sum0 (ea != 5)
  (define-values (pred-idx pred-ea eng-cnt0)
    (let loop ([j 0] [best-j 0] [best-ea (unsafe-fxvector-ref enemy-cands-fx 0)] [ec 0])
      (if (unsafe-fx>= j n-en)
          (values best-j best-ea ec)
          (let ([ea (unsafe-fxvector-ref enemy-cands-fx j)])
            (sim-pair-score-buf! init-a-fl init-a-fx sim-a-fl sim-a-fx na
                                 init-e-fl init-e-fx sim-e-fl sim-e-fx ne
                                 trap-xy ntraps oa0 ea ally-det? enemy-det? check-stasis?
                                 d1t d2t d3t params scratch 14)
            (let* ([v (unsafe-flvector-ref scratch 14)]
                   [nec (if (unsafe-fx= ea 5)
                            ec
                            (begin
                              (when (unsafe-fl< v (unsafe-flvector-ref scratch 16))
                                (unsafe-flvector-set! scratch 16 v))
                              (unsafe-flvector-set! scratch 17
                                (unsafe-fl+ (unsafe-flvector-ref scratch 17) v))
                              (unsafe-fx+ ec 1)))])
              (if (unsafe-fl< v (unsafe-flvector-ref scratch 10))
                  (begin
                    (unsafe-flvector-set! scratch 10 v)
                    (loop (unsafe-fx+ j 1) j ea nec))
                  (loop (unsafe-fx+ j 1) best-j best-ea nec)))))))
  (unsafe-flvector-set! scratch 11 (unsafe-flvector-ref scratch 10)) ;; bval = sc0 = pred-val0
  (unsafe-flvector-set! scratch 12 (unsafe-flvector-ref scratch 10)) ;; cv
  ;; W7-TAC-3: Engaged-combat (`ea != 5`) min/mean tie-breaker so enemy `DisengageRetreat`
  ;; flattening the payoff matrix never hides StutterKiteBack's combat dominance.
  (unsafe-flvector-set! scratch 18
    (if (unsafe-fx> eng-cnt0 0)
        (unsafe-fl+ (unsafe-fl* 0.5 (unsafe-flvector-ref scratch 16))
                    (unsafe-fl* 0.5 (unsafe-fl/ (unsafe-flvector-ref scratch 17) (unsafe-fx->fl eng-cnt0))))
        (unsafe-flvector-ref scratch 10)))
  (define 1mlam (unsafe-flvector-ref params 8))
  (define lam (unsafe-flvector-ref params 9))
  (define-values (best-oa found-c?)
    (let oloop ([i 1] [bo oa0] [fc? (unsafe-fx= oa0 cur-committed-code)])
      (if (unsafe-fx>= i n-our)
          (values bo fc?)
          (let ([oa (unsafe-fxvector-ref our-cands-fx i)])
            (unsafe-flvector-set! scratch 13 0.0)    ;; vp
            (unsafe-flvector-set! scratch 14 +inf.0) ;; w
            (unsafe-flvector-set! scratch 16 +inf.0) ;; eng-min (ea != 5)
            (unsafe-flvector-set! scratch 17 0.0)    ;; eng-sum (ea != 5)
            (define eng-cnt
              (let eloop ([j 0] [ec 0])
                (if (unsafe-fx>= j n-en)
                    ec
                    (let ([ea (unsafe-fxvector-ref enemy-cands-fx j)])
                      (sim-pair-score-buf! init-a-fl init-a-fx sim-a-fl sim-a-fx na
                                           init-e-fl init-e-fx sim-e-fl sim-e-fx ne
                                           trap-xy ntraps oa ea ally-det? enemy-det? check-stasis?
                                           d1t d2t d3t params scratch 15)
                      (let* ([v (unsafe-flvector-ref scratch 15)]
                             [nec (if (unsafe-fx= ea 5)
                                      ec
                                      (begin
                                        (when (unsafe-fl< v (unsafe-flvector-ref scratch 16))
                                          (unsafe-flvector-set! scratch 16 v))
                                        (unsafe-flvector-set! scratch 17
                                          (unsafe-fl+ (unsafe-flvector-ref scratch 17) v))
                                        (unsafe-fx+ ec 1)))])
                        (when (unsafe-fx= j pred-idx)
                          (unsafe-flvector-set! scratch 13 v))
                        (when (unsafe-fl< v (unsafe-flvector-ref scratch 14))
                          (unsafe-flvector-set! scratch 14 v))
                        (eloop (unsafe-fx+ j 1) nec))))))
            (let* ([sc (unsafe-fl+ (unsafe-fl* 1mlam (unsafe-flvector-ref scratch 13))
                                   (unsafe-fl* lam (unsafe-flvector-ref scratch 14)))]
                   [eng-tie (if (unsafe-fx> eng-cnt 0)
                                (unsafe-fl+ (unsafe-fl* 0.5 (unsafe-flvector-ref scratch 16))
                                            (unsafe-fl* 0.5 (unsafe-fl/ (unsafe-flvector-ref scratch 17)
                                                                        (unsafe-fx->fl eng-cnt))))
                                sc)]
                   [bval (unsafe-flvector-ref scratch 11)]
                   [btie (unsafe-flvector-ref scratch 18)]
                   [match-c? (unsafe-fx= oa cur-committed-code)]
                   [nfc? (or fc? match-c?)]
                   [better?
                    (or (unsafe-fl> sc (unsafe-fl+ bval 1.5))
                        (and (unsafe-fl>= sc (unsafe-fl- bval 1.5))
                             (or (unsafe-fx= pred-ea 5)
                                 (unsafe-fl<= (unsafe-flabs (unsafe-fl- sc bval)) 1.5))
                             (unsafe-fl> eng-tie btie)))])
              (when match-c?
                (unsafe-flvector-set! scratch 12 sc))
              (if better?
                  (begin
                    (unsafe-flvector-set! scratch 11 sc)
                    (unsafe-flvector-set! scratch 18 eng-tie)
                    (oloop (unsafe-fx+ i 1) oa nfc?))
                  (oloop (unsafe-fx+ i 1) bo nfc?)))))))
  (unsafe-flvector-set! out-vals 0 (unsafe-flvector-ref scratch 11))
  (unsafe-flvector-set! out-vals 1 (unsafe-flvector-ref scratch (if found-c? 12 11)))
  (values best-oa pred-ea))

(define ARENA-MISSING (string->uninterned-symbol "arena-missing"))

(provide
 TACTICAL-MICRO-ACTION-SPACE
 (struct-out tactical-sim-unit)
 (struct-out tactical-arena)
 (struct-out tactical-horizon-eval)
 (struct-out mirrored-rollout-result)
 (struct-out arena-commitment-state)
 (struct-out tactical-mirror-brain)
 make-tactical-mirror-brain
 unit-hash->tactical-sim-unit
 sim-unit-weapon-dps-vs
 cluster-tactical-arenas
 simulate-mirrored-arena-pair
 evaluate-arena-minimax-and-regret!
 resolve-committed-micro-action!
 step-tactical-mirror-brain!)

(define TACTICAL-MICRO-ACTION-SPACE
  '(CommitFocusFire
    StutterKiteBack
    KiteForwardChase
    FlankSurround
    CloakHarassWorkers
    DisengageRetreat
    HoldChoke))

(struct tactical-sim-unit
  (id
   type
   side            ;; 'ally or 'enemy
   hp
   max-hp
   shield
   armor
   speed
   ground-dps
   air-dps
   ground-range
   air-range
   weapon-period
   damage-point
   weapon-cooldown
   splash-radius
   flying?
   detector?
   cloaked?
   can-cloak?
   energy
   cost
   x
   y
   radius
   eta-sec         ;; 0.0 if already in arena, > 0.0 for arriving reinforcements
   attr-flags      ;; fixnum bitmask: 1=anti-armor 2=armored 4=anti-light 8=light 16=worker 32=hero 64=barrier 128=aam 256=gs
   attr-mask       ;; fixnum LotV SC2-UNIT-ATTR-* bitmask
   collision-radius) ;; flonum collision radius
  #:mutable
  #:transparent)

(struct tactical-arena
  (id
   center-x
   center-y
   ally-units
   enemy-units
   enemy-workers
   enemy-structures
   reinforcing-allies
   reinforcing-enemies
   choke-x
   choke-y
   choke-span
   our-z
   enemy-z
   ally-has-detection?
   enemy-has-detection?)
  #:transparent)

(struct tactical-horizon-eval
  (depth-sec
   ally-surviving-cost
   enemy-surviving-cost
   ally-hp-ratio
   enemy-hp-ratio
   workers-killed
   hero-units-lost
   net-value)
  #:transparent)

(struct mirrored-rollout-result
  (our-action
   enemy-action
   d1-eval
   d2-eval
   d3-eval
   combined-value)
  #:transparent)

(struct arena-commitment-state
  (arena-id
   committed-action
   predicted-enemy-action
   focus-target-id
   committed-since-frame
   lock-until-frame
   enemy-action-regrets  ;; hash: action-sym -> cumulative score
   last-enemy-cx
   last-enemy-cy)
  #:mutable
  #:transparent)

(struct tactical-mirror-brain
  (arena-states          ;; mutable hash: arena-id -> arena-commitment-state
   active-arenas         ;; list of tactical-arena from latest step
   last-decisions)       ;; list of decision hashes from latest step
  #:mutable
  #:transparent)

(define (make-tactical-mirror-brain)
  (tactical-mirror-brain (make-hash) '() '()))

;; Untyped fast combat/geometry helpers avoiding Typed/Untyped hash chaperones in hot loops.
(define (fast-dist2d x1 y1 x2 y2)
  (define dx (- (if (flonum? x2) x2 (exact->inexact x2))
                (if (flonum? x1) x1 (exact->inexact x1))))
  (define dy (- (if (flonum? y2) y2 (exact->inexact y2))
                (if (flonum? y1) y1 (exact->inexact y1))))
  (sqrt (+ (* dx dx) (* dy dy))))

(define (fast-score-arena-focus-target combined-dps effective-hp dist attacker-range)
  (define dps-num (+ 5.0 (max 0.0 combined-dps)))
  (define hp-den (max 1.0 effective-hp))
  (define r-den (max 1.0 attacker-range))
  (define d-val (max 1.0 dist))
  (/ dps-num (* hp-den (max 1.0 (/ d-val r-den)))))

(define UNIT-STAT-CACHE (make-hasheq))

(define NEXT-UNIT-TYPE-IDX 0)

(define (fast-unit-stat-vec utype)
  (hash-ref!
   UNIT-STAT-CACHE
   utype
   (lambda ()
     (define stats (sc2-unit-combat-stats utype))
     (define m-cost (sc2-min-cost utype 50))
     (define g-cost (sc2-gas-cost utype 0))
     (define aflags
       (bitwise-ior
        (if (hash-ref ANTI-ARMOR-ATTACKERS utype #f) 1 0)
        (if (hash-ref ARMORED-TARGETS utype #f) 2 0)
        (if (hash-ref ANTI-LIGHT-ATTACKERS utype #f) 4 0)
        (if (hash-ref LIGHT-TARGETS utype #f) 8 0)
        (if (hash-ref WORKER-TYPE-SET utype #f) 16 0)
        (if (hash-ref HERO-LOSS-TYPE-SET utype #f) 32 0)))
     (define attr-mask (unit-attribute-mask utype))
     (define coll-rad (unit-collision-radius utype))
     (define tidx NEXT-UNIT-TYPE-IDX)
     (set! NEXT-UNIT-TYPE-IDX (unsafe-fx+ tidx 1))
     (vector-immutable
      (exact->inexact (+ m-cost (* 1.5 g-cost)))
      (exact->inexact (hash-ref stats 'max-hp 80))
      (exact->inexact (hash-ref stats 'max-shield 0))
      (exact->inexact (hash-ref stats 'armor 0))
      (exact->inexact (hash-ref stats 'speed 3.15))
      (exact->inexact (hash-ref stats 'ground-dps 10.0))
      (exact->inexact (hash-ref stats 'air-dps 0.0))
      (exact->inexact (hash-ref stats 'ground-range 5.0))
      (exact->inexact (hash-ref stats 'air-range 0.0))
      (max 0.16 (exact->inexact (hash-ref stats 'weapon-period 1.0)))
      (exact->inexact (hash-ref stats 'damage-point 0.10))
      (exact->inexact (hash-ref stats 'splash-radius 0.0))
      (eq? (hash-ref stats 'flying? #f) #t)
      (eq? (hash-ref stats 'detector? #f) #t)
      (eq? (hash-ref stats 'can-cloak? #f) #t)
      (exact->inexact (hash-ref stats 'radius 0.5))
      aflags
      attr-mask
      coll-rad
      tidx))))

(define ANTI-ARMOR-ATTACKERS
  (hasheq 'immortal #t 'marauder #t 'stalker #t 'siege-tank #t 'siege-tank-sieged #t
          'lurker-mp-burrowed #t 'lurker #t 'lurker-burrowed #t 'void-ray #t
          'corruptor #t 'viking #t 'ultralisk #t))
(define ARMORED-TARGETS
  (hasheq 'roach #t 'marauder #t 'stalker #t 'immortal #t 'siege-tank #t 'siege-tank-sieged #t
          'thor #t 'ultralisk #t 'colossus #t 'lurker-mp-burrowed #t 'lurker #t 'lurker-burrowed #t
          'viking #t 'void-ray #t 'corruptor #t 'battlecruiser #t 'carrier #t 'tempest #t))
(define ANTI-LIGHT-ATTACKERS
  (hasheq 'baneling #t 'hellion #t 'hellbat #t 'colossus #t 'oracle #t 'archon #t
          'adept #t 'reaper #t 'phoenix #t 'mutalisk #t))
(define LIGHT-TARGETS
  (hasheq 'zergling #t 'baneling #t 'hydralisk #t 'marine #t 'reaper #t 'hellion #t
          'zealot #t 'adept #t 'high-templar #t 'dark-templar #t 'sentry #t
          'drone #t 'scv #t 'probe #t 'mutalisk #t 'phoenix #t 'oracle #t))

(define WORKER-TYPE-SET (hasheq 'scv #t 'probe #t 'drone #t))
(define NONCOMBAT-TYPE-SET
  (hasheq 'drone #t 'scv #t 'probe #t 'larva #t 'egg #t 'overlord #t 'mule #t 'disruptor-phased #t))
(define HERO-LOSS-TYPE-SET
  (hasheq 'banshee #t 'oracle #t 'mutalisk #t 'medivac #t 'warp-prism #t
          'immortal #t 'siege-tank #t 'siege-tank-sieged #t 'colossus #t))
(define UNTARGETABLE-DECOY-SET
  (for/hasheq ([s (in-list SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS)]) (values s #t)))
(define STEALTH-SYM-SET
  (for/hasheq ([s (in-list SC2-CLOAKED-OR-BURROW-STEALTH-SYMS)]) (values s #t)))
(define ORDER-PROT-CACHE (make-hasheqv))
(define DETECTOR-SYM-CACHE (make-hasheq))
(define PRIORITY-MULT-CACHE-NO-STEALTH (make-hasheq))
(define PRIORITY-MULT-CACHE-STEALTH (make-hasheq))

(define (fast-order-protection-class ab-id)
  (hash-ref! ORDER-PROT-CACHE ab-id (lambda () (sc2-order-protection-class ab-id))))

(define (fast-detector-sym? sym)
  (hash-ref! DETECTOR-SYM-CACHE sym (lambda () (sc2-unit-is-detector-sym? sym))))

(define (fast-target-priority-mult sym stealth?)
  (hash-ref! (if stealth? PRIORITY-MULT-CACHE-STEALTH PRIORITY-MULT-CACHE-NO-STEALTH)
             sym
             (lambda () (sc2-target-priority-multiplier sym stealth?))))

(define ROLLOUT-CACHE-BY-STATE (make-weak-hasheq))

(define-syntax-rule (fast->fl v)
  (let ([x v])
    (if (flonum? x)
        x
        (if (fixnum? x)
            (unsafe-fx->fl x)
            (exact->inexact x)))))

(define-syntax-rule (same-num-fl? raw flv)
  (let ([r raw])
    (if (flonum? r)
        (fl= r flv)
        (and (fixnum? r) (fl= (unsafe-fx->fl r) flv)))))

(define (unit-buff-list-bits bfs)
  (let loop ([rem bfs] [bits 0])
    (if (null? rem)
        bits
        (let ([b (car rem)])
          (loop (cdr rem)
                (cond
                  [(or (eq? b 'immortal-overload) (eq? b 'immortal-barrier) (eqv? b 102))
                   (unsafe-fxior bits 64)]
                  [(or (eq? b 'anti-armor-missile) (eq? b 'anti-armor-missile-debuff))
                   (unsafe-fxior bits 128)]
                  [(or (eq? b 'guardian-shield) (eqv? b 18))
                   (unsafe-fxior bits 256)]
                  [else bits]))))))

(define (unit-buff-attr-bits u)
  (let ([bfs (hash-ref u 'buffs #f)])
    (if (pair? bfs)
        (unit-buff-list-bits bfs)
        0)))

;; W11-P0-4-rt (`w11-tac-2`): Distinguish SC2 undetected cloak (`cloak=1` / `'cloaked`)
;; from detected cloak (`cloak=2` / `'cloaked-detected`, which still sets `'cloaked #t` in obs).
(define (hash-undetected-cloak? u)
  (define cval (hash-ref u 'cloak #f))
  (cond
    [(or (eqv? cval 1) (eq? cval 'cloaked)) #t]
    [(or (eqv? cval 2) (eqv? cval 3) (memq cval '(cloaked-detected not-cloaked))) #f]
    [else (or (eq? (hash-ref u 'cloaked #f) #t)
              (eq? (hash-ref u 'burrowed #f) #t))]))

(define (unit-hash->tactical-sim-unit u [side 'ally] #:eta-sec [eta-sec 0.0])
  (define utype (hash-ref u 'type 'marine))
  (define weaponless-disruptor? (or (eq? utype 'disruptor) (eq? utype 'disruptor-phased)))
  ;; W12-P0-4-rt (`w12-tac-1` + Suite 5.18): An Oracle with live buff/beam/cooldown state
  ;; and WITHOUT active Pulsar Beam (`buff=56` / `'oracle-weapon` / `'pulsar-beam`) has NO
  ;; weapon and must never emit suicide `ATTACK (23)`. Synthetic stat hashes omitting those
  ;; live keys preserve nominal active-beam combat DPS.
  (define weaponless-beam-off-oracle?
    (and (eq? utype 'oracle)
         (or (hash-has-key? u 'buffs)
             (hash-has-key? u 'pulsar-beam-on?)
             (hash-has-key? u 'pulsar-beam-active?)
             (hash-has-key? u 'weapon-cooldown))
         (not (eq? (hash-ref u 'pulsar-beam-on? #f) #t))
         (not (eq? (hash-ref u 'pulsar-beam-active? #f) #t))
         (let ([bfs (hash-ref u 'buffs #f)])
           (not (and (pair? bfs)
                     (for/or ([b (in-list bfs)])
                       (or (eqv? b 56)
                           (eq? b 'oracle-weapon)
                           (eq? b 'pulsar-beam))))))))
  (define weaponless-caster? (or weaponless-disruptor? weaponless-beam-off-oracle?))
  (define sv (fast-unit-stat-vec utype))
  ;; W7-P0-1-rt: Live `runtime-obs-hash` stores combined `'hp = (+ health shield)` and
  ;; `'max-hp = (+ health-max shield-max)` alongside raw `'hull-hp` + `'shield`. Prefer
  ;; `'hull-hp` and hull-only `max-hp` so Protoss shields are never double-counted!
  (define has-hull-hp? (hash-has-key? u 'hull-hp))
  (define shd (flmax 0.0 (fast->fl (or (hash-ref u 'shield #f) (hash-ref u 'shields #f) (vector-ref sv 2)))))
  (define hp (flmax 1.0 (fast->fl (if has-hull-hp?
                                      (hash-ref u 'hull-hp (vector-ref sv 1))
                                      (hash-ref u 'hp (hash-ref u 'max-hp (vector-ref sv 1)))))))
  (define max-hp
    (flmax 1.0
           (if has-hull-hp?
               (let ([tbl-hull (vector-ref sv 1)]
                     [tbl-shd (vector-ref sv 2)])
                 (if (fl> tbl-hull 0.0)
                     (flmax hp tbl-hull)
                     (flmax hp (fl- (fast->fl (hash-ref u 'max-hp hp)) (flmax shd tbl-shd)))))
               (fast->fl (hash-ref u 'max-hp (vector-ref sv 1))))))
  (define wcd (fast->fl (hash-ref u 'weapon-cooldown 0.0)))
  (tactical-sim-unit
   (hash-ref u 'id 0)
   utype
   side
   hp
   max-hp
   shd
   (vector-ref sv 3)
   (fast->fl (hash-ref u 'speed (vector-ref sv 4)))
   (if weaponless-caster? 0.0 (vector-ref sv 5))
   (if weaponless-caster? 0.0 (vector-ref sv 6))
   (if weaponless-caster? 0.0 (vector-ref sv 7))
   (if weaponless-caster? 0.0 (vector-ref sv 8))
   (vector-ref sv 9)
   (vector-ref sv 10)
   (if (fl> wcd 0.0) wcd 0.0)
   (vector-ref sv 11)
   (eq? (hash-ref u 'flying? (vector-ref sv 12)) #t)
   (vector-ref sv 13)
   (hash-undetected-cloak? u)
   (vector-ref sv 14)
   (fast->fl (hash-ref u 'energy 0))
   (vector-ref sv 0)
   (fast->fl (hash-ref u 'x 32.5))
   (fast->fl (hash-ref u 'y 32.5))
   (fast->fl (hash-ref u 'radius (vector-ref sv 15)))
   (fast->fl eta-sec)
   (unsafe-fxior (vector-ref sv 16)
                 (unit-buff-attr-bits u)
                 (unsafe-fxlshift (hash-ref UNIT-REFRESH-FLAGS-HT utype 0) 10))
   (vector-ref sv 17)
   (vector-ref sv 18)))

(define (ensure-fl-sim-unit su)
  (if (and (flonum? (tactical-sim-unit-hp su))
           (flonum? (tactical-sim-unit-max-hp su))
           (flonum? (tactical-sim-unit-ground-dps su))
           (flonum? (tactical-sim-unit-x su))
           (flonum? (tactical-sim-unit-collision-radius su)))
      su
      (struct-copy tactical-sim-unit su
                   [hp (fast->fl (tactical-sim-unit-hp su))]
                   [max-hp (fast->fl (tactical-sim-unit-max-hp su))]
                   [shield (fast->fl (tactical-sim-unit-shield su))]
                   [armor (fast->fl (tactical-sim-unit-armor su))]
                   [speed (fast->fl (tactical-sim-unit-speed su))]
                   [ground-dps (fast->fl (tactical-sim-unit-ground-dps su))]
                   [air-dps (fast->fl (tactical-sim-unit-air-dps su))]
                   [ground-range (fast->fl (tactical-sim-unit-ground-range su))]
                   [air-range (fast->fl (tactical-sim-unit-air-range su))]
                   [weapon-period (fast->fl (tactical-sim-unit-weapon-period su))]
                   [damage-point (fast->fl (tactical-sim-unit-damage-point su))]
                   [weapon-cooldown (fast->fl (tactical-sim-unit-weapon-cooldown su))]
                   [splash-radius (fast->fl (tactical-sim-unit-splash-radius su))]
                   [energy (fast->fl (tactical-sim-unit-energy su))]
                   [cost (fast->fl (tactical-sim-unit-cost su))]
                   [x (fast->fl (tactical-sim-unit-x su))]
                   [y (fast->fl (tactical-sim-unit-y su))]
                   [radius (fast->fl (tactical-sim-unit-radius su))]
                   [eta-sec (fast->fl (tactical-sim-unit-eta-sec su))]
                   [collision-radius (fast->fl (tactical-sim-unit-collision-radius su))])))

(define (clone-tactical-sim-unit su)
  (struct-copy tactical-sim-unit (ensure-fl-sim-unit su)))

(define (reset-sim-units! srcs dsts)
  (let loop ([s srcs] [d dsts])
    (unless (or (null? s) (null? d))
      (define src (car s))
      (define dst (car d))
      (set-tactical-sim-unit-hp! dst (tactical-sim-unit-hp src))
      (set-tactical-sim-unit-shield! dst (tactical-sim-unit-shield src))
      (set-tactical-sim-unit-weapon-cooldown! dst (tactical-sim-unit-weapon-cooldown src))
      (set-tactical-sim-unit-cloaked?! dst (tactical-sim-unit-cloaked? src))
      (set-tactical-sim-unit-x! dst (tactical-sim-unit-x src))
      (set-tactical-sim-unit-y! dst (tactical-sim-unit-y src))
      (set-tactical-sim-unit-eta-sec! dst (tactical-sim-unit-eta-sec src))
      (loop (cdr s) (cdr d)))))

(define (cluster-tactical-arenas ally-units raw-enemy-units enemy-bldgs
                                 #:chokes [chokes '()]
                                 #:our-z [our-z 10]
                                 #:enemy-z [enemy-z 10])
  (define ally-vec-list
    (for/fold ([acc '()]) ([u (in-list ally-units)])
      (if (and (hash? u)
               (not (hash-ref NONCOMBAT-TYPE-SET (hash-ref u 'type #f) #f)))
          (cons (vector u
                        (hash-ref u 'id 0)
                        (fast->fl (hash-ref u 'x 32.5))
                        (fast->fl (hash-ref u 'y 32.5))
                        #f)
                acc)
          acc)))
  (cond
    [(null? ally-vec-list) '()]
    [else
     (define enemy-vecs
       (let loop ([rem raw-enemy-units] [acc '()])
         (if (null? rem)
             (reverse acc)
             (let ([e (car rem)])
               (if (and (hash? e)
                        (let ([ty (hash-ref e 'type #f)])
                          (and (not (hash-ref UNTARGETABLE-DECOY-SET ty #f))
                               (not (eq? (hash-ref e 'hallucination #f) #t)))))
                   (loop (cdr rem)
                         (cons (vector e
                                       (fast->fl (hash-ref e 'x 999.0))
                                       (fast->fl (hash-ref e 'y 999.0))
                                       (hash-ref e 'type #f)
                                       #f)
                               acc))
                   (loop (cdr rem) acc))))))
     (cond
       [(and (null? enemy-vecs) (null? enemy-bldgs)) '()]
       [else
        (define ally-vecs (list->vector (reverse ally-vec-list)))
        (define n-ca (vector-length ally-vecs))
        (define visited (make-vector n-ca #f))
        (define squads '())
        (define cluster-rad-fl (fast->fl SC2-TACTICAL-ARENA-CLUSTER-RADIUS))
        (define cluster-rad-sq (fl* cluster-rad-fl cluster-rad-fl))
        (for ([i (in-range n-ca)])
          (unless (vector-ref visited i)
            (vector-set! visited i #t)
            (define vi (vector-ref ally-vecs i))
            (define ux (vector-ref vi 2))
            (define uy (vector-ref vi 3))
            (define-values (cluster sx sy n-sq)
              (let loop ([j (add1 i)]
                         [acc '()]
                         [sx ux]
                         [sy uy]
                         [n-sq 1])
                (cond
                  [(>= j n-ca)
                   (values (cons vi (reverse acc)) sx sy n-sq)]
                  [(vector-ref visited j)
                   (loop (add1 j) acc sx sy n-sq)]
                  [else
                   (define vj (vector-ref ally-vecs j))
                   (define dx (fl- (vector-ref vj 2) ux))
                   (define dy (fl- (vector-ref vj 3) uy))
                   (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) cluster-rad-sq)
                       (begin
                         (vector-set! visited j #t)
                         (loop (add1 j)
                               (cons vj acc)
                               (fl+ sx (vector-ref vj 2))
                               (fl+ sy (vector-ref vj 3))
                               (add1 n-sq)))
                       (loop (add1 j) acc sx sy n-sq))])))
            (set! squads (cons (vector cluster (fl/ sx (exact->inexact n-sq)) (fl/ sy (exact->inexact n-sq))) squads))))

        (define bldg-vecs
          (for/list ([eb (in-list enemy-bldgs)])
            (vector eb
                    (fast->fl (hash-ref eb 'x 999.0))
                    (fast->fl (hash-ref eb 'y 999.0))
                    (hash-ref eb 'type 'pylon))))
        (define eng-rad SC2-TACTICAL-ARENA-ENGAGE-RADIUS)
        (define eng-rad-sq (* eng-rad eng-rad))
        (define reinf-rad-sq (fast->fl (* SC2-TACTICAL-REINFORCE-RADIUS SC2-TACTICAL-REINFORCE-RADIUS)))
        (define cluster-rad-sq2 (fast->fl (* SC2-TACTICAL-ARENA-CLUSTER-RADIUS SC2-TACTICAL-ARENA-CLUSTER-RADIUS)))
        (define eng-rad-sq-fl (fast->fl eng-rad-sq))
        ;; W11-P0-4-rt (`w11-tac-6` / `#30 P v Creepy`): Tempest weapon range is 15.0 + 1.9 = 16.9t!
        ;; Extend arena engage discovery to 18.5t (`342.25` sq-dist) for long-range capital/siege
        ;; enemies so armies being shelled at 16.0t enter arena-minimax instead of rally-retreating!
        (define siege-cap-eng-rad-sq-fl (flmax eng-rad-sq-fl 342.25))
        (define (get-ally-sim vi)
          (or (vector-ref vi 4)
              (let ([su (unit-hash->tactical-sim-unit (vector-ref vi 0) 'ally)])
                (vector-set! vi 4 su)
                su)))
        (define (get-enemy-sim ev)
          (or (vector-ref ev 4)
              (let ([su (unit-hash->tactical-sim-unit (vector-ref ev 0) 'enemy)])
                (vector-set! ev 4 su)
                su)))
        (define arenas '())
        (define seen-sectors (make-hasheqv))
        (for ([sqv (in-list (reverse squads))])
          (define sq (vector-ref sqv 0))
          (define cx (vector-ref sqv 1))
          (define cy (vector-ref sqv 2))
          (define cx-fl (fast->fl cx))
          (define cy-fl (fast->fl cy))
          (define local-enemy-vecs
            (for/list ([ev (in-list enemy-vecs)]
                       #:when (let* ([dx (fl- (fast->fl (vector-ref ev 1)) cx-fl)]
                                     [dy (fl- (fast->fl (vector-ref ev 2)) cy-fl)]
                                     [lim-sq (if (memq (vector-ref ev 3)
                                                       '(tempest carrier brood-lord broodlord battlecruiser siege-tank-sieged))
                                                 siege-cap-eng-rad-sq-fl
                                                 eng-rad-sq-fl)])
                                (fl<= (fl+ (fl* dx dx) (fl* dy dy)) lim-sq)))
              ev))
          (define local-enemy-bldgs
            (for/list ([bv (in-list bldg-vecs)]
                       #:when (let ([dx (fl- (fast->fl (vector-ref bv 1)) cx-fl)]
                                    [dy (fl- (fast->fl (vector-ref bv 2)) cy-fl)])
                                (fl<= (fl+ (fl* dx dx) (fl* dy dy)) eng-rad-sq-fl)))
              (vector-ref bv 0)))
          (when (or (not (null? local-enemy-vecs)) (not (null? local-enemy-bldgs)))
            (define enemy-workers
              (for/list ([ev (in-list local-enemy-vecs)]
                         #:when (hash-ref WORKER-TYPE-SET (vector-ref ev 3) #f))
                (vector-ref ev 0)))
            (define reinf-allies
              (let loop ([i 0] [acc '()])
                (if (= i n-ca)
                    (reverse acc)
                    (let* ([vi (vector-ref ally-vecs i)]
                           [dx (fl- (fast->fl (vector-ref vi 2)) cx-fl)]
                           [dy (fl- (fast->fl (vector-ref vi 3)) cy-fl)]
                           [d2 (fl+ (fl* dx dx) (fl* dy dy))])
                      (if (and (fl> d2 cluster-rad-sq2) (fl<= d2 reinf-rad-sq))
                          (let* ([base-su (get-ally-sim vi)]
                                 [spd (flmax 2.0 (tactical-sim-unit-speed base-su))]
                                 [d (flsqrt d2)])
                            (loop (add1 i) (cons (struct-copy tactical-sim-unit base-su [eta-sec (fl/ (fl- d 6.0) spd)]) acc)))
                          (loop (add1 i) acc))))))
            (define reinf-enemies
              (let loop ([rem enemy-vecs] [acc '()])
                (if (null? rem)
                    (reverse acc)
                    (let* ([ev (car rem)]
                           [dx (fl- (fast->fl (vector-ref ev 1)) cx-fl)]
                           [dy (fl- (fast->fl (vector-ref ev 2)) cy-fl)]
                           [d2 (fl+ (fl* dx dx) (fl* dy dy))])
                      (if (and (fl> d2 eng-rad-sq-fl) (fl<= d2 reinf-rad-sq))
                          (let* ([base-su (get-enemy-sim ev)]
                                 [spd (flmax 2.0 (tactical-sim-unit-speed base-su))]
                                 [d (flsqrt d2)])
                            (loop (cdr rem) (cons (struct-copy tactical-sim-unit base-su [eta-sec (fl/ (fl- d 6.0) spd)]) acc)))
                          (loop (cdr rem) acc))))))
            (define ally-sims (map get-ally-sim sq))
            (define enemy-sims (map get-enemy-sim local-enemy-vecs))
            (define ally-det? (ormap tactical-sim-unit-detector? ally-sims))
            (define enemy-det?
              (or (ormap tactical-sim-unit-detector? enemy-sims)
                  (ormap (lambda (eb) (vector-ref (fast-unit-stat-vec (hash-ref eb 'type 'pylon)) 13)) local-enemy-bldgs)))
            (define base-sector
              (+ (* 100 (fl->exact-integer (flfloor (fl/ cx-fl 16.0))))
                 (fl->exact-integer (flfloor (fl/ cy-fl 16.0)))))
            (define sec-occ (hash-ref seen-sectors base-sector 0))
            (hash-set! seen-sectors base-sector (+ sec-occ 1))
            (define sector-id
              (if (= sec-occ 0)
                  base-sector
                  (+ 1000000 (* sec-occ 100000) base-sector)))
            (set! arenas
                  (cons (tactical-arena
                         sector-id
                         cx cy
                         ally-sims
                         enemy-sims
                         enemy-workers
                         local-enemy-bldgs
                         reinf-allies
                         reinf-enemies
                         cx cy 10.0
                         our-z enemy-z
                         ally-det? enemy-det?)
                        arenas))))
        (reverse arenas)])]))

(define (sim-unit-weapon-dps-vs attacker target)
  (define base-dps
    (if (tactical-sim-unit-flying? target)
        (tactical-sim-unit-air-dps attacker)
        (tactical-sim-unit-ground-dps attacker)))
  (if (<= base-dps 0.0)
      0.0
      (let* ([af (tactical-sim-unit-attr-flags attacker)]
             [tf (tactical-sim-unit-attr-flags target)]
             [attr-mult
              (cond
                [(and (not (zero? (bitwise-and af 1)))
                      (not (zero? (bitwise-and tf 2))))
                 1.45]
                [(and (not (zero? (bitwise-and af 4)))
                      (not (zero? (bitwise-and tf 8))))
                 1.55]
                [else 1.0])])
        (* base-dps attr-mult))))

(define (sim-unit-weapon-range-vs attacker target)
  (if (tactical-sim-unit-flying? target)
      (tactical-sim-unit-air-range attacker)
      (tactical-sim-unit-ground-range attacker)))

(define (sim-unit-can-target? attacker target opp-has-detection?)
  (and (> (+ (tactical-sim-unit-hp target) (tactical-sim-unit-shield target)) 0.0)
       (<= (tactical-sim-unit-eta-sec attacker) 0.0)
       (<= (tactical-sim-unit-eta-sec target) 0.0)
       (or (not (tactical-sim-unit-cloaked? target)) opp-has-detection?)
       (> (if (tactical-sim-unit-flying? target)
              (tactical-sim-unit-air-dps attacker)
              (tactical-sim-unit-ground-dps attacker))
          0.0)))

(define (step-kinematic-side! actors opponents action opp-det? side-z opp-z ally-side?
                              arena dt ally-worker-count)
  (define elev-mult
    (cond
      [(fl> side-z (fl+ opp-z 0.5)) 1.15]
      [(fl< side-z (fl- opp-z 0.5)) 0.85]
      [else 1.0]))
  (define fallback-opp
    (let loop ([rem opponents])
      (cond
        [(null? rem) #f]
        [(let ([o (car rem)])
           (and (fl> (tactical-sim-unit-hp o) 0.0)
                (fl<= (tactical-sim-unit-eta-sec o) 0.0)))
         (car rem)]
        [else (loop (cdr rem))])))
  (when fallback-opp
    (define cloak-workers? (eq? action 'CloakHarassWorkers))
    (define focus-or-chase? (or (eq? action 'CommitFocusFire) (eq? action 'KiteForwardChase)))
    (define retreat? (eq? action 'DisengageRetreat))
    (define hold-choke? (eq? action 'HoldChoke))
    (define flank? (eq? action 'FlankSurround))
    (define stutter-kite? (or (eq? action 'StutterKiteBack) cloak-workers?))
    (let uloop ([rem-u actors])
      (unless (null? rem-u)
        (define u (car rem-u))
        (when (and (fl> (tactical-sim-unit-hp u) 0.0)
                   (fl<= (tactical-sim-unit-eta-sec u) 0.0))
          (define ux (tactical-sim-unit-x u))
          (define uy (tactical-sim-unit-y u))
          (define ug-dps (tactical-sim-unit-ground-dps u))
          (define ua-dps (tactical-sim-unit-air-dps u))
          (define ug-rng (tactical-sim-unit-ground-range u))
          (define ua-rng (tactical-sim-unit-air-range u))
          (define ug-rng-eff (flmax 1.0 ug-rng))
          (define ug-rng-eff2 (fl* ug-rng-eff ug-rng-eff))
          (define ua-rng-eff (flmax 1.0 ua-rng))
          (define ua-rng-eff2 (fl* ua-rng-eff ua-rng-eff))
          (define-values (best-valid best-worker)
            (cond
              [focus-or-chase?
               (let oloop ([rem-o opponents] [bv #f] [bv-sc -inf.0])
                 (if (null? rem-o)
                     (values bv #f)
                     (let ([o (car rem-o)])
                       (if (and (fl> (tactical-sim-unit-hp o) 0.0)
                                (fl<= (tactical-sim-unit-eta-sec o) 0.0)
                                (or (not (tactical-sim-unit-cloaked? o)) opp-det?)
                                (fl> (if (tactical-sim-unit-flying? o) ua-dps ug-dps) 0.0))
                           (let* ([fly? (tactical-sim-unit-flying? o)]
                                  [dx (fl- (tactical-sim-unit-x o) ux)]
                                  [dy (fl- (tactical-sim-unit-y o) uy)]
                                  [d2 (fl+ (fl* dx dx) (fl* dy dy))]
                                  [rng-eff (if fly? ua-rng-eff ug-rng-eff)]
                                  [rng2 (if fly? ua-rng-eff2 ug-rng-eff2)]
                                  [ehp-c (flmax 1.0 (fl+ (tactical-sim-unit-hp o) (tactical-sim-unit-shield o)))]
                                  [dps-num (fl+ 5.0 (fl+ (tactical-sim-unit-ground-dps o) (tactical-sim-unit-air-dps o)))]
                                  [sc (if (fl<= d2 rng2)
                                          (fl/ dps-num ehp-c)
                                          (fl/ (fl* dps-num rng-eff) (fl* ehp-c (flsqrt d2))))])
                             (if (fl> sc bv-sc)
                                 (oloop (cdr rem-o) o sc)
                                 (oloop (cdr rem-o) bv bv-sc)))
                           (oloop (cdr rem-o) bv bv-sc)))))]
              [cloak-workers?
               (let oloop ([rem-o opponents] [bv #f] [bv-sc +inf.0] [bw #f] [bw-hp +inf.0])
                 (if (null? rem-o)
                     (values bv bw)
                     (let ([o (car rem-o)])
                       (if (and (fl> (tactical-sim-unit-hp o) 0.0)
                                (fl<= (tactical-sim-unit-eta-sec o) 0.0)
                                (or (not (tactical-sim-unit-cloaked? o)) opp-det?)
                                (fl> (if (tactical-sim-unit-flying? o) ua-dps ug-dps) 0.0))
                           (let* ([dx (fl- (tactical-sim-unit-x o) ux)]
                                  [dy (fl- (tactical-sim-unit-y o) uy)]
                                  [d2 (fl+ (fl* dx dx) (fl* dy dy))]
                                  [w-match? (not (= (bitwise-and (tactical-sim-unit-attr-flags o) 16) 0))])
                             (define-values (nbw nbw-hp)
                               (if w-match?
                                   (let ([ehp (fl+ (tactical-sim-unit-hp o) (tactical-sim-unit-shield o))])
                                     (if (fl< ehp bw-hp)
                                         (values o ehp)
                                         (values bw bw-hp)))
                                   (values bw bw-hp)))
                             (if (fl< d2 bv-sc)
                                 (oloop (cdr rem-o) o d2 nbw nbw-hp)
                                 (oloop (cdr rem-o) bv bv-sc nbw nbw-hp)))
                           (oloop (cdr rem-o) bv bv-sc bw bw-hp)))))]
              [else
               (let oloop ([rem-o opponents] [bv #f] [bv-sc +inf.0])
                 (if (null? rem-o)
                     (values bv #f)
                     (let ([o (car rem-o)])
                       (if (and (fl> (tactical-sim-unit-hp o) 0.0)
                                (fl<= (tactical-sim-unit-eta-sec o) 0.0)
                                (or (not (tactical-sim-unit-cloaked? o)) opp-det?)
                                (fl> (if (tactical-sim-unit-flying? o) ua-dps ug-dps) 0.0))
                           (let* ([dx (fl- (tactical-sim-unit-x o) ux)]
                                  [dy (fl- (tactical-sim-unit-y o) uy)]
                                  [d2 (fl+ (fl* dx dx) (fl* dy dy))])
                             (if (fl< d2 bv-sc)
                                 (oloop (cdr rem-o) o d2)
                                 (oloop (cdr rem-o) bv bv-sc)))
                           (oloop (cdr rem-o) bv bv-sc)))))]))
          (define target (or best-worker best-valid fallback-opp))
          (define can-hit? (and best-valid #t))
          (define tx (tactical-sim-unit-x target))
          (define ty (tactical-sim-unit-y target))
          (define dx (fl- tx ux))
          (define dy (fl- ty uy))
          (define dist (flmax 0.25 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
          (define nx (fl/ dx dist))
          (define ny (fl/ dy dist))
          (define t-fly? (tactical-sim-unit-flying? target))
          (define wrange (fl* elev-mult
                              (fl+ (if t-fly? ua-rng ug-rng)
                                   (fl+ (tactical-sim-unit-radius u)
                                        (tactical-sim-unit-radius target)))))
          (define spd (tactical-sim-unit-speed u))
          (define cd (tactical-sim-unit-weapon-cooldown u))
          (define af (tactical-sim-unit-attr-flags u))
          (define drill-mult
            (if (and ally-side?
                     (>= ally-worker-count 3)
                     (not (= (bitwise-and af 16) 0))
                     (fl<= dist 4.0))
                1.35
                1.0))

          (cond
            [retreat?
             (define step-d (fl* spd dt))
             (set-tactical-sim-unit-x! u (fl- ux (fl* step-d nx)))
             (set-tactical-sim-unit-y! u (fl- uy (fl* step-d ny)))]

            [(and can-hit? (fl<= dist wrange) (fl<= cd 0.0))
             (define base-dps (if t-fly? ua-dps ug-dps))
             (define weapon-dps
               (if (fl<= base-dps 0.0)
                   0.0
                   (let* ([tf (tactical-sim-unit-attr-flags target)]
                          [attr-mult
                           (cond
                             [(and (not (= (bitwise-and af 1) 0))
                                   (not (= (bitwise-and tf 2) 0)))
                              1.45]
                             [(and (not (= (bitwise-and af 4) 0))
                                   (not (= (bitwise-and tf 8) 0)))
                              1.55]
                             [else 1.0])])
                     (fl* base-dps attr-mult))))
             (define burst-dmg
               (fl* elev-mult
                    (fl* drill-mult
                         (fl* weapon-dps
                              (tactical-sim-unit-weapon-period u)))))
             (define eff-dmg (flmax 1.0 (fl- burst-dmg (tactical-sim-unit-armor target))))
             (define shd (tactical-sim-unit-shield target))
             (cond
               [(fl>= shd eff-dmg)
                (set-tactical-sim-unit-shield! target (fl- shd eff-dmg))]
               [else
                (set-tactical-sim-unit-shield! target 0.0)
                (set-tactical-sim-unit-hp! target (fl- (tactical-sim-unit-hp target) (fl- eff-dmg shd)))])
             (define srad (tactical-sim-unit-splash-radius u))
             (when (fl> srad 0.5)
               (define srad-sq (fl* srad srad))
               (define splash-dmg (fl* (if flank? 0.25 0.50) eff-dmg))
               (let aloop ([rem-a opponents])
                 (unless (null? rem-a)
                   (define adj (car rem-a))
                   (when (and (not (eq? adj target))
                              (fl> (tactical-sim-unit-hp adj) 0.0)
                              (fl<= (tactical-sim-unit-eta-sec adj) 0.0)
                              (or (not (tactical-sim-unit-cloaked? adj)) opp-det?)
                              (fl> (if (tactical-sim-unit-flying? adj) ua-dps ug-dps) 0.0))
                     (define adx (fl- (tactical-sim-unit-x adj) tx))
                     (define ady (fl- (tactical-sim-unit-y adj) ty))
                     (when (fl<= (fl+ (fl* adx adx) (fl* ady ady)) srad-sq)
                       (set-tactical-sim-unit-hp! adj (fl- (tactical-sim-unit-hp adj) splash-dmg))))
                   (aloop (cdr rem-a)))))
             (set-tactical-sim-unit-weapon-cooldown! u (tactical-sim-unit-weapon-period u))
             (define move-dt (flmax 0.0 (fl- dt (tactical-sim-unit-damage-point u))))
             (when (and (fl> move-dt 0.0) stutter-kite?)
               (define mdist (fl* spd move-dt))
               (set-tactical-sim-unit-x! u (fl- ux (fl* mdist nx)))
               (set-tactical-sim-unit-y! u (fl- uy (fl* mdist ny))))]

            [(fl> cd 0.0)
             (cond
               [stutter-kite?
                (define mdist (fl* spd dt))
                (set-tactical-sim-unit-x! u (fl- ux (fl* mdist nx)))
                (set-tactical-sim-unit-y! u (fl- uy (fl* mdist ny)))]
               [focus-or-chase?
                (when (fl> dist (fl* 0.80 wrange))
                  (define mdist (fl* spd dt))
                  (set-tactical-sim-unit-x! u (fl+ ux (fl* mdist nx)))
                  (set-tactical-sim-unit-y! u (fl+ uy (fl* mdist ny))))]
               [flank?
                (define mdist (fl* 0.70 (fl* spd dt)))
                (set-tactical-sim-unit-x! u (fl+ ux (fl* mdist (fl- 0.0 ny))))
                (set-tactical-sim-unit-y! u (fl+ uy (fl* mdist nx)))]
               [else (void)])]

            [(not hold-choke?)
             (define mdist (fl* spd dt))
             (set-tactical-sim-unit-x! u (fl+ ux (fl* mdist nx)))
             (set-tactical-sim-unit-y! u (fl+ uy (fl* mdist ny)))]))
        (uloop (cdr rem-u))))))

(define (step-kinematic-and-combat-tick! sim-allies sim-enemies
                                         our-action enemy-action
                                         arena raw-dt
                                         [check-stasis? #t])
  (define dt (if (flonum? raw-dt) raw-dt (exact->inexact raw-dt)))
  (define ally-det? (tactical-arena-ally-has-detection? arena))
  (define enemy-det? (tactical-arena-enemy-has-detection? arena))
  (define our-z (let ([z (tactical-arena-our-z arena)]) (if (flonum? z) z (exact->inexact z))))
  (define enemy-z (let ([z (tactical-arena-enemy-z arena)]) (if (flonum? z) z (exact->inexact z))))
  (define cloak-harass? (eq? our-action 'CloakHarassWorkers))
  (define ally-worker-count
    (let loop ([rem sim-allies] [wc 0])
      (if (null? rem)
          wc
          (let ([u (car rem)])
            (when (and cloak-harass?
                       (tactical-sim-unit-can-cloak? u)
                       (fl>= (tactical-sim-unit-energy u) 25.0))
              (set-tactical-sim-unit-cloaked?! u #t))
            (let ([eta (tactical-sim-unit-eta-sec u)])
              (when (fl> eta 0.0)
                (set-tactical-sim-unit-eta-sec! u (flmax 0.0 (fl- eta dt)))))
            (let ([cd (tactical-sim-unit-weapon-cooldown u)])
              (when (fl> cd 0.0)
                (set-tactical-sim-unit-weapon-cooldown! u (flmax 0.0 (fl- cd dt)))))
            (loop (cdr rem)
                  (if (and (fl> (tactical-sim-unit-hp u) 0.0)
                           (not (= (bitwise-and (tactical-sim-unit-attr-flags u) 16) 0)))
                      (add1 wc)
                      wc))))))
  (let loop ([rem sim-enemies])
    (unless (null? rem)
      (define u (car rem))
      (let ([eta (tactical-sim-unit-eta-sec u)])
        (when (fl> eta 0.0)
          (set-tactical-sim-unit-eta-sec! u (flmax 0.0 (fl- eta dt)))))
      (let ([cd (tactical-sim-unit-weapon-cooldown u)])
        (when (fl> cd 0.0)
          (set-tactical-sim-unit-weapon-cooldown! u (flmax 0.0 (fl- cd dt)))))
      (loop (cdr rem))))

  ;; Oracle Stasis Ward hazard penalty: penalize CommitFocusFire / KiteForwardChase when an enemy
  ;; stasis trap is within 4.5 tiles of friendly short-range units, rewarding StutterKiteBack / FlankSurround
  (when (and check-stasis?
             (memq our-action '(CommitFocusFire KiteForwardChase HoldChoke))
             (or (for/or ([e (in-list sim-enemies)])
                   (and (fl> (tactical-sim-unit-hp e) 0.0)
                        (memq (tactical-sim-unit-type e) '(oracle-stasis-trap stasis-ward))))
                 (for/or ([eb (in-list (tactical-arena-enemy-structures arena))])
                   (and (hash? eb)
                        (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward))))))
    (for ([a (in-list sim-allies)]
          #:when (and (fl> (tactical-sim-unit-hp a) 0.0)
                      (not (tactical-sim-unit-flying? a))
                      (fl<= (tactical-sim-unit-ground-range a) 4.5)))
      (define ax (tactical-sim-unit-x a))
      (define ay (tactical-sim-unit-y a))
      (define near-trap?
        (or (for/or ([e (in-list sim-enemies)])
              (and (fl> (tactical-sim-unit-hp e) 0.0)
                   (memq (tactical-sim-unit-type e) '(oracle-stasis-trap stasis-ward))
                   (let ([dx (fl- ax (tactical-sim-unit-x e))]
                         [dy (fl- ay (tactical-sim-unit-y e))])
                     (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 20.25))))
            (for/or ([eb (in-list (tactical-arena-enemy-structures arena))])
              (and (hash? eb)
                   (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward))
                   (let ([dx (fl- ax (fast->fl (hash-ref eb 'x 999.0)))]
                         [dy (fl- ay (fast->fl (hash-ref eb 'y 999.0)))])
                     (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 20.25))))))
      (when near-trap?
        (set-tactical-sim-unit-hp! a (flmax 1.0 (fl- (tactical-sim-unit-hp a) (fl* 18.0 dt)))))))

  (step-kinematic-side! sim-allies sim-enemies our-action enemy-det? our-z enemy-z #t arena dt ally-worker-count)
  (step-kinematic-side! sim-enemies sim-allies enemy-action ally-det? enemy-z our-z #f arena dt ally-worker-count))

(define (compute-arena-horizon-metrics init-allies init-enemies sim-allies sim-enemies
                                      [given-init-ally-cost #f] [given-init-enemy-cost #f])
  (define init-ally-cost
    (fast->fl
     (or given-init-ally-cost
         (let loop ([r init-allies] [s 0.0]) (if (null? r) s (loop (cdr r) (+ s (tactical-sim-unit-cost (car r)))))))))
  (define init-enemy-cost
    (fast->fl
     (or given-init-enemy-cost
         (let loop ([r init-enemies] [s 0.0]) (if (null? r) s (loop (cdr r) (+ s (tactical-sim-unit-cost (car r)))))))))
  (define-values (surv-ally-cost ally-eff-hp-val hero-units-lost)
    (let loop ([r sim-allies] [sc 0.0] [ev 0.0] [hl 0])
      (if (null? r)
          (values sc ev hl)
          (let* ([a (car r)]
                 [hp (tactical-sim-unit-hp a)])
            (if (fl> hp 0.0)
                (let* ([c (tactical-sim-unit-cost a)]
                       [sh (tactical-sim-unit-shield a)]
                       [mhp (tactical-sim-unit-max-hp a)])
                  (loop (cdr r)
                        (fl+ sc c)
                        (fl+ ev (fl* c (fl/ (fl+ hp sh)
                                            (flmax 1.0 (fl+ mhp sh)))))
                        hl))
                (loop (cdr r) sc ev
                      (if (not (= (bitwise-and (tactical-sim-unit-attr-flags a) 32) 0)) (add1 hl) hl)))))))
  (define-values (surv-enemy-cost enemy-eff-hp-val workers-killed)
    (let loop ([r sim-enemies] [sc 0.0] [ev 0.0] [wk 0])
      (if (null? r)
          (values sc ev wk)
          (let* ([e (car r)]
                 [hp (tactical-sim-unit-hp e)])
            (if (fl> hp 0.0)
                (let* ([c (tactical-sim-unit-cost e)]
                       [sh (tactical-sim-unit-shield e)]
                       [mhp (tactical-sim-unit-max-hp e)])
                  (loop (cdr r)
                        (fl+ sc c)
                        (fl+ ev (fl* c (fl/ (fl+ hp sh)
                                            (flmax 1.0 (fl+ mhp sh)))))
                        wk))
                (loop (cdr r) sc ev
                      (if (not (= (bitwise-and (tactical-sim-unit-attr-flags e) 16) 0)) (add1 wk) wk)))))))
  (define trade-delta
    (fl- (fl- init-enemy-cost surv-enemy-cost)
         (fl- init-ally-cost surv-ally-cost)))
  (define hp-val-delta
    (fl* 0.45 (fl- ally-eff-hp-val enemy-eff-hp-val)))
  (define net-val
    (fl+ trade-delta
         (fl+ hp-val-delta
              (fl- (fl* (fast->fl SC2-WORKER-KILL-ECONOMIC-VALUE) (exact->inexact workers-killed))
                   (fl* (fast->fl SC2-HERO-UNIT-LOSS-PENALTY) (exact->inexact hero-units-lost))))))
  (values surv-ally-cost surv-enemy-cost init-ally-cost init-enemy-cost
          ally-eff-hp-val enemy-eff-hp-val workers-killed hero-units-lost net-val))

(define (evaluate-arena-horizon-state depth-sec init-allies init-enemies sim-allies sim-enemies
                                      [given-init-ally-cost #f] [given-init-enemy-cost #f])
  (define-values (surv-ally-cost surv-enemy-cost init-ally-cost init-enemy-cost
                  ally-eff-hp-val enemy-eff-hp-val workers-killed hero-units-lost net-val)
    (compute-arena-horizon-metrics init-allies init-enemies sim-allies sim-enemies
                                   given-init-ally-cost given-init-enemy-cost))
  (tactical-horizon-eval
   depth-sec
   surv-ally-cost
   surv-enemy-cost
   (/ ally-eff-hp-val (max 1.0 init-ally-cost))
   (/ enemy-eff-hp-val (max 1.0 init-enemy-cost))
   workers-killed
   hero-units-lost
   net-val))

(define (compress-arena-sim-units units [max-rep 4])
  (define n (length units))
  (if (<= n max-rep)
      units
      (let ([scale (/ (exact->inexact n) (exact->inexact max-rep))])
        (for/list ([u (in-list (take units max-rep))])
          (struct-copy tactical-sim-unit u
                       [hp (* scale (tactical-sim-unit-hp u))]
                       [max-hp (* scale (tactical-sim-unit-max-hp u))]
                       [shield (* scale (tactical-sim-unit-shield u))]
                       [ground-dps (* scale (tactical-sim-unit-ground-dps u))]
                       [air-dps (* scale (tactical-sim-unit-air-dps u))]
                       [cost (* scale (tactical-sim-unit-cost u))])))))

(define SIM-PAIR-DT-FL (exact->inexact (* 2.0 SC2-TACTICAL-SIM-DT-SEC)))
(define SIM-D1-TICKS (max 1 (exact-round (/ SC2-TACTICAL-DEPTH1-SEC (* 2.0 SC2-TACTICAL-SIM-DT-SEC)))))
(define SIM-D2-TICKS (max 2 (exact-round (/ SC2-TACTICAL-DEPTH2-SEC (* 2.0 SC2-TACTICAL-SIM-DT-SEC)))))
(define SIM-D3-TICKS (max 4 (exact-round (/ SC2-TACTICAL-DEPTH3-SEC (* 2.0 SC2-TACTICAL-SIM-DT-SEC)))))
(define SIM-D1-WEIGHT-FL (exact->inexact SC2-TACTICAL-DEPTH1-WEIGHT))
(define SIM-D2-WEIGHT-FL (exact->inexact SC2-TACTICAL-DEPTH2-WEIGHT))
(define SIM-D3-WEIGHT-FL (exact->inexact SC2-TACTICAL-DEPTH3-WEIGHT))
(define MINIMAX-LAMBDA-FL (exact->inexact SC2-TACTICAL-MINIMAX-LAMBDA))
(define MINIMAX-1-MINUS-LAMBDA-FL (fl- 1.0 MINIMAX-LAMBDA-FL))

(define (simulate-mirrored-arena-pair-score arena our-action enemy-action
                                             init-allies init-enemies
                                             sim-allies sim-enemies
                                             check-stasis?
                                             [given-init-ally-cost #f]
                                             [given-init-enemy-cost #f])
  (define init-ally-cost
    (fast->fl
     (or given-init-ally-cost
         (let loop ([r init-allies] [s 0.0]) (if (null? r) s (loop (cdr r) (fl+ s (tactical-sim-unit-cost (car r)))))))))
  (define init-enemy-cost
    (fast->fl
     (or given-init-enemy-cost
         (let loop ([r init-enemies] [s 0.0]) (if (null? r) s (loop (cdr r) (fl+ s (tactical-sim-unit-cost (car r)))))))))
  (reset-sim-units! init-allies sim-allies)
  (reset-sim-units! init-enemies sim-enemies)
  (define dt SIM-PAIR-DT-FL)
  (define d1-ticks SIM-D1-TICKS)
  (define d2-ticks SIM-D2-TICKS)
  (define d3-ticks SIM-D3-TICKS)

  (let-values ([(d1-val d2-val)
                (let tloop ([tick 1] [d1-val #f] [d2-val #f])
                  (cond
                    [(> tick d3-ticks) (values d1-val d2-val)]
                    [else
                     (step-kinematic-and-combat-tick! sim-allies sim-enemies our-action enemy-action arena dt check-stasis?)
                     (define nd1
                       (if (= tick d1-ticks)
                           (let-values ([(_sa _se _ia _ie _ah _eh _wk _hl nv)
                                         (compute-arena-horizon-metrics init-allies init-enemies sim-allies sim-enemies
                                                                        init-ally-cost init-enemy-cost)])
                             nv)
                           d1-val))
                     (define nd2
                       (if (= tick d2-ticks)
                           (let-values ([(_sa _se _ia _ie _ah _eh _wk _hl nv)
                                         (compute-arena-horizon-metrics init-allies init-enemies sim-allies sim-enemies
                                                                        init-ally-cost init-enemy-cost)])
                             nv)
                           d2-val))
                     (tloop (+ tick 1) nd1 nd2)]))])
    (define-values (_sa3 _se3 _ia3 _ie3 _ah3 _eh3 _wk3 _hl3 d3-val)
      (compute-arena-horizon-metrics init-allies init-enemies sim-allies sim-enemies
                                     init-ally-cost init-enemy-cost))
    (fl+ (fl+ (fl* SIM-D1-WEIGHT-FL (or d1-val d3-val))
              (fl* SIM-D2-WEIGHT-FL (or d2-val d3-val)))
         (fl* SIM-D3-WEIGHT-FL d3-val))))

(define (simulate-mirrored-arena-pair-fast arena our-action enemy-action
                                            init-allies init-enemies
                                            sim-allies sim-enemies
                                            check-stasis?
                                            [given-init-ally-cost #f]
                                            [given-init-enemy-cost #f])
  (define init-ally-cost
    (or given-init-ally-cost
        (let loop ([r init-allies] [s 0.0]) (if (null? r) s (loop (cdr r) (+ s (tactical-sim-unit-cost (car r))))))))
  (define init-enemy-cost
    (or given-init-enemy-cost
        (let loop ([r init-enemies] [s 0.0]) (if (null? r) s (loop (cdr r) (+ s (tactical-sim-unit-cost (car r))))))))
  (reset-sim-units! init-allies sim-allies)
  (reset-sim-units! init-enemies sim-enemies)
  (define dt (* 2.0 SC2-TACTICAL-SIM-DT-SEC))
  (define d1-ticks (max 1 (exact-round (/ SC2-TACTICAL-DEPTH1-SEC dt)))) ;; 1 tick (0.5s)
  (define d2-ticks (max 2 (exact-round (/ SC2-TACTICAL-DEPTH2-SEC dt)))) ;; 4 ticks (2.0s)
  (define d3-ticks (max 4 (exact-round (/ SC2-TACTICAL-DEPTH3-SEC dt)))) ;; 10 ticks (5.0s)

  (let-values ([(d1-eval d2-eval)
                (let tloop ([tick 1] [d1-eval #f] [d2-eval #f])
                  (cond
                    [(> tick d3-ticks) (values d1-eval d2-eval)]
                    [else
                     (step-kinematic-and-combat-tick! sim-allies sim-enemies our-action enemy-action arena dt check-stasis?)
                     (define nd1
                       (if (= tick d1-ticks)
                           (evaluate-arena-horizon-state SC2-TACTICAL-DEPTH1-SEC
                                                         init-allies init-enemies sim-allies sim-enemies
                                                         init-ally-cost init-enemy-cost)
                           d1-eval))
                     (define nd2
                       (if (= tick d2-ticks)
                           (evaluate-arena-horizon-state SC2-TACTICAL-DEPTH2-SEC
                                                         init-allies init-enemies sim-allies sim-enemies
                                                         init-ally-cost init-enemy-cost)
                           d2-eval))
                     (tloop (+ tick 1) nd1 nd2)]))])
    (define d3-eval
      (evaluate-arena-horizon-state SC2-TACTICAL-DEPTH3-SEC
                                    init-allies init-enemies sim-allies sim-enemies
                                    init-ally-cost init-enemy-cost))
    (define eff-d1 (or d1-eval d3-eval))
    (define eff-d2 (or d2-eval d3-eval))
    (define combined
      (+ (* SC2-TACTICAL-DEPTH1-WEIGHT (tactical-horizon-eval-net-value eff-d1))
         (* SC2-TACTICAL-DEPTH2-WEIGHT (tactical-horizon-eval-net-value eff-d2))
         (* SC2-TACTICAL-DEPTH3-WEIGHT (tactical-horizon-eval-net-value d3-eval))))
    (mirrored-rollout-result our-action enemy-action eff-d1 eff-d2 d3-eval combined)))

(define (simulate-mirrored-arena-pair arena our-action enemy-action
                                      #:init-allies [given-init-allies #f]
                                      #:init-enemies [given-init-enemies #f]
                                      #:sim-allies [given-sim-allies #f]
                                      #:sim-enemies [given-sim-enemies #f])
  (define init-allies
    (or given-init-allies
        (compress-arena-sim-units
         (append (tactical-arena-ally-units arena)
                 (tactical-arena-reinforcing-allies arena)))))
  (define init-enemies
    (or given-init-enemies
        (compress-arena-sim-units
         (append (tactical-arena-enemy-units arena)
                 (tactical-arena-reinforcing-enemies arena)))))
  (define sim-allies (or given-sim-allies (map clone-tactical-sim-unit init-allies)))
  (define sim-enemies (or given-sim-enemies (map clone-tactical-sim-unit init-enemies)))
  (define check-stasis?
    (or (for/or ([e (in-list init-enemies)])
          (memq (tactical-sim-unit-type e) '(oracle-stasis-trap stasis-ward)))
        (for/or ([eb (in-list (tactical-arena-enemy-structures arena))])
          (and (hash? eb)
               (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward))))))
  (simulate-mirrored-arena-pair-fast arena our-action enemy-action
                                     init-allies init-enemies
                                     sim-allies sim-enemies
                                     check-stasis?))

(define (candidate-actions-for-arena arena)
  (define has-cloak-or-harass?
    (ormap (lambda (a)
             (or (tactical-sim-unit-can-cloak? a)
                 (tactical-sim-unit-flying? a)
                 (memq (tactical-sim-unit-type a) '(banshee oracle mutalisk reaper adept))))
           (tactical-arena-ally-units arena)))
  (if (and has-cloak-or-harass? (not (null? (tactical-arena-enemy-workers arena))))
      TACTICAL-MICRO-ACTION-SPACE
      (remq 'CloakHarassWorkers TACTICAL-MICRO-ACTION-SPACE)))

(define (compress-two-arena-sim-lists prim reinf max-rep)
  (define n (+ (length prim) (length reinf)))
  (cond
    [(<= n max-rep)
     (if (null? reinf)
         (for/list ([u (in-list prim)]) (ensure-fl-sim-unit u))
         (let loop ([rem prim] [acc '()])
           (if (null? rem)
               (let loop2 ([rem2 reinf] [acc2 acc])
                 (if (null? rem2)
                     (reverse acc2)
                     (loop2 (cdr rem2) (cons (ensure-fl-sim-unit (car rem2)) acc2))))
               (loop (cdr rem) (cons (ensure-fl-sim-unit (car rem)) acc)))))]
    [else
     (define scale (fl/ (exact->inexact n) (exact->inexact max-rep)))
     (let loop ([rem prim] [reinf-rem reinf] [k max-rep] [acc '()])
       (cond
         [(<= k 0) (reverse acc)]
         [(pair? rem)
          (define u (ensure-fl-sim-unit (car rem)))
          (loop (cdr rem) reinf-rem (- k 1)
                (cons (struct-copy tactical-sim-unit u
                                   [hp (fl* scale (tactical-sim-unit-hp u))]
                                   [max-hp (fl* scale (tactical-sim-unit-max-hp u))]
                                   [shield (fl* scale (tactical-sim-unit-shield u))]
                                   [ground-dps (fl* scale (tactical-sim-unit-ground-dps u))]
                                   [air-dps (fl* scale (tactical-sim-unit-air-dps u))]
                                   [cost (fl* scale (tactical-sim-unit-cost u))])
                      acc))]
         [(pair? reinf-rem)
          (define u (ensure-fl-sim-unit (car reinf-rem)))
          (loop '() (cdr reinf-rem) (- k 1)
                (cons (struct-copy tactical-sim-unit u
                                   [hp (fl* scale (tactical-sim-unit-hp u))]
                                   [max-hp (fl* scale (tactical-sim-unit-max-hp u))]
                                   [shield (fl* scale (tactical-sim-unit-shield u))]
                                   [ground-dps (fl* scale (tactical-sim-unit-ground-dps u))]
                                   [air-dps (fl* scale (tactical-sim-unit-air-dps u))]
                                   [cost (fl* scale (tactical-sim-unit-cost u))])
                      acc))]
         [else (reverse acc)]))]))

(define ACTION-CODE-HT
  (hasheq 'CommitFocusFire 0 'StutterKiteBack 1 'KiteForwardChase 2
          'FlankSurround 3 'CloakHarassWorkers 4 'DisengageRetreat 5 'HoldChoke 6))
(define CODE->ACTION-VEC
  (vector-immutable 'CommitFocusFire 'StutterKiteBack 'KiteForwardChase
                    'FlankSurround 'CloakHarassWorkers 'DisengageRetreat 'HoldChoke))
(define ENEMY-CAND-FX (fxvector 0 1 2 3 5))
(define OUR-CAND-ALL-FX (fxvector 0 1 2 3 4 5 6))
(define OUR-CAND-NOCLOAK-FX (fxvector 0 1 2 3 5 6))
(define WORKER-VAL-FL (exact->inexact SC2-WORKER-KILL-ECONOMIC-VALUE))
(define HERO-PEN-FL (exact->inexact SC2-HERO-UNIT-LOSS-PENALTY))
(define EMPTY-TRAP-FL (flvector))

(define (pack-sim-units-to-buf! units flb fxb)
  (let loop ([rem units] [i 0])
    (unless (null? rem)
      (define su (car rem))
      (define b (* i 19))
      (define ib (* i 6))
      (flvector-set! flb b (tactical-sim-unit-hp su))
      (flvector-set! flb (+ b 1) (tactical-sim-unit-max-hp su))
      (flvector-set! flb (+ b 2) (tactical-sim-unit-shield su))
      (flvector-set! flb (+ b 3) (tactical-sim-unit-armor su))
      (flvector-set! flb (+ b 4) (tactical-sim-unit-speed su))
      (flvector-set! flb (+ b 5) (tactical-sim-unit-ground-dps su))
      (flvector-set! flb (+ b 6) (tactical-sim-unit-air-dps su))
      (flvector-set! flb (+ b 7) (tactical-sim-unit-ground-range su))
      (flvector-set! flb (+ b 8) (tactical-sim-unit-air-range su))
      (flvector-set! flb (+ b 9) (tactical-sim-unit-weapon-period su))
      (flvector-set! flb (+ b 10) (tactical-sim-unit-damage-point su))
      (flvector-set! flb (+ b 11) (tactical-sim-unit-weapon-cooldown su))
      (flvector-set! flb (+ b 12) (tactical-sim-unit-splash-radius su))
      (flvector-set! flb (+ b 13) (tactical-sim-unit-energy su))
      (flvector-set! flb (+ b 14) (tactical-sim-unit-cost su))
      (flvector-set! flb (+ b 15) (tactical-sim-unit-x su))
      (flvector-set! flb (+ b 16) (tactical-sim-unit-y su))
      (flvector-set! flb (+ b 17) (tactical-sim-unit-radius su))
      (flvector-set! flb (+ b 18) (tactical-sim-unit-eta-sec su))
      (fxvector-set! fxb ib (if (tactical-sim-unit-flying? su) 1 0))
      (fxvector-set! fxb (+ ib 1) (if (tactical-sim-unit-detector? su) 1 0))
      (fxvector-set! fxb (+ ib 2) (if (tactical-sim-unit-cloaked? su) 1 0))
      (fxvector-set! fxb (+ ib 3) (if (tactical-sim-unit-can-cloak? su) 1 0))
      (fxvector-set! fxb (+ ib 4) (tactical-sim-unit-attr-flags su))
      (fxvector-set! fxb (+ ib 5) (if (memq (tactical-sim-unit-type su) '(oracle-stasis-trap stasis-ward)) 1 0))
      (loop (cdr rem) (+ i 1)))))

(define (evaluate-arena-minimax-and-regret! brain arena frame #:strategic-opp-depth [_opp-d 1])
  (define aid (tactical-arena-id arena))
  (define states (tactical-mirror-brain-arena-states brain))
  (define cur-state (hash-ref states aid #f))
  (define raw-a (tactical-arena-ally-units arena))
  (define raw-e (tactical-arena-enemy-units arena))
  (define can-cloak-arena?
    (for/or ([u (in-list raw-a)])
      (and (tactical-sim-unit-can-cloak? u)
           (>= (tactical-sim-unit-energy u) SC2-BANSHEE-CLOAK-MIN-ENERGY))))
  (define our-cands-fx (if can-cloak-arena? OUR-CAND-ALL-FX OUR-CAND-NOCLOAK-FX))
  (define n-our (fxvector-length our-cands-fx))
  (define max-rep (if (> (+ (length raw-a) (length raw-e)) 16) 3 4))
  (define init-allies (compress-two-arena-sim-lists raw-a (tactical-arena-reinforcing-allies arena) max-rep))
  (define init-enemies (compress-two-arena-sim-lists raw-e (tactical-arena-reinforcing-enemies arena) max-rep))
  (define na (length init-allies))
  (define ne (length init-enemies))
  (define sim-allies-buf (let loop ([r init-allies] [acc '()]) (if (null? r) (reverse acc) (loop (cdr r) (cons (clone-tactical-sim-unit (car r)) acc)))))
  (define sim-enemies-buf (let loop ([r init-enemies] [acc '()]) (if (null? r) (reverse acc) (loop (cdr r) (cons (clone-tactical-sim-unit (car r)) acc)))))
  (define init-ally-cost
    (let loop ([r init-allies] [s 0.0]) (if (null? r) s (loop (cdr r) (fl+ s (tactical-sim-unit-cost (car r)))))))
  (define init-enemy-cost
    (let loop ([r init-enemies] [s 0.0]) (if (null? r) s (loop (cdr r) (fl+ s (tactical-sim-unit-cost (car r)))))))
  (define trap-coords
    (for/fold ([acc '()]) ([eb (in-list (tactical-arena-enemy-structures arena))])
      (if (and (hash? eb) (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward)))
          (cons (cons (fast->fl (hash-ref eb 'x 999.0)) (fast->fl (hash-ref eb 'y 999.0))) acc)
          acc)))
  (define enemy-has-trap?
    (let loop ([r init-enemies])
      (and (pair? r)
           (or (memq (tactical-sim-unit-type (car r)) '(oracle-stasis-trap stasis-ward))
               (loop (cdr r))))))
  (define check-stasis? (or enemy-has-trap? (pair? trap-coords)))
  (define ntraps (length trap-coords))
  (define trap-xy
    (if (zero? ntraps)
        EMPTY-TRAP-FL
        (let ([v (make-flvector (* 2 ntraps))])
          (for ([p (in-list trap-coords)] [i (in-naturals)])
            (flvector-set! v (* 2 i) (car p))
            (flvector-set! v (+ (* 2 i) 1) (cdr p)))
          v)))
  (define need-cap (max 16 na ne))
  (define bcache (hash-ref! ROLLOUT-CACHE-BY-STATE brain make-hasheqv))
  (define kpool
    (let ([existing (hash-ref bcache '__kernel-pool #f)])
      (if (and existing (>= (vector-ref existing 11) need-cap))
          existing
          (let ([v (vector (make-flvector (* need-cap 19)) (make-fxvector (* need-cap 6))
                           (make-flvector (* need-cap 19)) (make-fxvector (* need-cap 6))
                           (make-flvector (* need-cap 19)) (make-fxvector (* need-cap 6))
                           (make-flvector (* need-cap 19)) (make-fxvector (* need-cap 6))
                           (make-flvector 2)
                           (make-flvector 20)
                           (make-flvector 12)
                           need-cap)])
            (hash-set! bcache '__kernel-pool v)
            v))))
  (define ia-fl (vector-ref kpool 0))
  (define ia-fx (vector-ref kpool 1))
  (define sa-fl (vector-ref kpool 2))
  (define sa-fx (vector-ref kpool 3))
  (define ie-fl (vector-ref kpool 4))
  (define ie-fx (vector-ref kpool 5))
  (define se-fl (vector-ref kpool 6))
  (define se-fx (vector-ref kpool 7))
  (define out-vals (vector-ref kpool 8))
  (define scratch-fl (vector-ref kpool 9))
  (define params-fl (vector-ref kpool 10))
  (pack-sim-units-to-buf! init-allies ia-fl ia-fx)
  (pack-sim-units-to-buf! init-enemies ie-fl ie-fx)
  (define cur-committed-oa (and cur-state (arena-commitment-state-committed-action cur-state)))
  (define cur-committed-code (if cur-committed-oa (hash-ref ACTION-CODE-HT cur-committed-oa -1) -1))
  (flvector-set! params-fl 0 (let ([z (tactical-arena-our-z arena)]) (if (flonum? z) z (exact->inexact z))))
  (flvector-set! params-fl 1 (let ([z (tactical-arena-enemy-z arena)]) (if (flonum? z) z (exact->inexact z))))
  (flvector-set! params-fl 2 init-ally-cost)
  (flvector-set! params-fl 3 init-enemy-cost)
  (flvector-set! params-fl 4 SIM-PAIR-DT-FL)
  (flvector-set! params-fl 5 SIM-D1-WEIGHT-FL)
  (flvector-set! params-fl 6 SIM-D2-WEIGHT-FL)
  (flvector-set! params-fl 7 SIM-D3-WEIGHT-FL)
  (flvector-set! params-fl 8 MINIMAX-1-MINUS-LAMBDA-FL)
  (flvector-set! params-fl 9 MINIMAX-LAMBDA-FL)
  (flvector-set! params-fl 10 WORKER-VAL-FL)
  (flvector-set! params-fl 11 HERO-PEN-FL)
  (define-values (best-code pred-code)
    (eval-arena-minimax-kernel! ia-fl ia-fx sa-fl sa-fx na
                                ie-fl ie-fx se-fl se-fx ne
                                trap-xy ntraps
                                our-cands-fx n-our ENEMY-CAND-FX 5 cur-committed-code
                                (and (tactical-arena-ally-has-detection? arena) #t)
                                (and (tactical-arena-enemy-has-detection? arena) #t)
                                check-stasis?
                                SIM-D1-TICKS SIM-D2-TICKS SIM-D3-TICKS
                                params-fl scratch-fl out-vals))
  (define best-oa (vector-ref CODE->ACTION-VEC best-code))
  (define pred-enemy-action (vector-ref CODE->ACTION-VEC pred-code))
  (define best-val (flvector-ref out-vals 0))
  (define cur-val (flvector-ref out-vals 1))
  (define best-rollout
    (simulate-mirrored-arena-pair-fast arena best-oa pred-enemy-action
                                       init-allies init-enemies
                                       sim-allies-buf sim-enemies-buf
                                       check-stasis?
                                       init-ally-cost
                                       init-enemy-cost))
  (values best-oa pred-enemy-action best-val cur-val best-rollout))

(define (resolve-committed-micro-action! brain arena frame
                                         raw-best-action pred-enemy-action
                                         best-val cur-val)
  (define aid (tactical-arena-id arena))
  (define states (tactical-mirror-brain-arena-states brain))
  (define prev (hash-ref states aid #f))
  (cond
    [(not prev)
     (define lock-dur
       (if (memq raw-best-action '(DisengageRetreat CloakHarassWorkers))
           SC2-TACTICAL-RETREAT-LOCK-FRAMES
           SC2-TACTICAL-MIN-LOCK-FRAMES))
     (define st
       (arena-commitment-state aid raw-best-action pred-enemy-action 0
                               frame (+ frame lock-dur) (make-hasheq)
                               (tactical-arena-center-x arena)
                               (tactical-arena-center-y arena)))
     (hash-set! states aid st)
     (values raw-best-action #f)]
    [else
     (define prev-act (arena-commitment-state-committed-action prev))
     (define lock-until (arena-commitment-state-lock-until-frame prev))
     (define in-lock? (< frame lock-until))
     (define req-margin
       (if in-lock?
           (* SC2-TACTICAL-PREEMPT-MULTIPLIER SC2-TACTICAL-HYSTERESIS-BONUS)
           SC2-TACTICAL-HYSTERESIS-BONUS))
     (cond
       [(or (eq? raw-best-action prev-act)
            (<= (- best-val cur-val) req-margin))
        ;; Maintain current commitment (no order oscillation!)
        (set-arena-commitment-state-predicted-enemy-action! prev pred-enemy-action)
        (values prev-act #t)]
       [else
        ;; Genuine tactical shift exceeding hysteresis threshold
        (define lock-dur
          (if (memq raw-best-action '(DisengageRetreat CloakHarassWorkers))
              SC2-TACTICAL-RETREAT-LOCK-FRAMES
              SC2-TACTICAL-MIN-LOCK-FRAMES))
        (set-arena-commitment-state-committed-action! prev raw-best-action)
        (set-arena-commitment-state-predicted-enemy-action! prev pred-enemy-action)
        (set-arena-commitment-state-committed-since-frame! prev frame)
        (set-arena-commitment-state-lock-until-frame! prev (+ frame lock-dur))
        (values raw-best-action #f)])]))

;; Bitmask flags: 1 = shield unit, 2 = cloakable/burrowable unit, 4 = energy caster
(define UNIT-REFRESH-FLAGS-HT
  (let ([ht (make-hasheq)])
    (for ([s (in-list '(probe zealot stalker sentry adept high-templar dark-templar archon
                        immortal colossus disruptor phoenix void-ray voidray oracle
                        carrier tempest warp-prism warp-prism-phasing observer observer-siege-mode
                        mothership nexus pylon photon-cannon shield-battery gateway warp-gate))])
      (hash-set! ht s (bitwise-ior (hash-ref ht s 0) 1)))
    (for ([s (in-list '(drone zergling baneling roach ravager hydralisk lurker lurker-burrowed
                        infestor infestor-burrowed swarm-host swarm-host-burrowed ultralisk
                        ghost dark-templar banshee observer observer-siege-mode
                        widow-mine widow-mine-burrowed mothership))])
      (hash-set! ht s (bitwise-ior (hash-ref ht s 0) 2)))
    (for ([s (in-list '(queen infestor infestor-burrowed viper ravager overseer overseer-siege-mode
                        ghost medivac banshee raven battlecruiser thor
                        sentry high-templar phoenix oracle warp-prism mothership))])
      (hash-set! ht s (bitwise-ior (hash-ref ht s 0) 4)))
    (for/hasheq ([(k v) (in-hash ht)]) (values k v))))

(define ENEMY-PRIORITY-CONST-CACHE-T (make-hasheq))
(define ENEMY-PRIORITY-CONST-CACHE-F (make-hasheq))
(define SPATIAL-PLAN-BUCKETS (make-hasheqv))
(define SPATIAL-BUCKET-GEN 0)

(define (vec4> a b)
  (fl> (vector-ref a 4) (vector-ref b 4)))

(define-syntax-rule (unit-id-table-lookup tbl gen uid)
  (let ([slot (hash-ref tbl uid #f)])
    (and slot (eqv? (mcar slot) gen) (mcdr slot))))

(define (refresh-unit-id-table! tbl units gen)
  (when (and (> (hash-count tbl) 128)
             (> (hash-count tbl) (* 2 (length units))))
    (hash-clear! tbl))
  (let loop ([rem units] [cnt 0] [dup? #f] [all-imm? #t])
    (if (null? rem)
        (values cnt dup? all-imm?)
        (let ([u (car rem)])
          (if (hash? u)
              (let* ([imm? (and all-imm? (immutable? u))]
                     [uid (hash-ref u 'id -1)]
                     [slot (hash-ref tbl uid #f)])
                (cond
                  [(not slot)
                   (hash-set! tbl uid (mcons gen u))
                   (loop (cdr rem) (unsafe-fx+ cnt 1) dup? imm?)]
                  [(eq? (mcar slot) gen)
                   (set-mcdr! slot u)
                   (loop (cdr rem) cnt #t imm?)]
                  [else
                   (set-mcar! slot gen)
                   (set-mcdr! slot u)
                   (loop (cdr rem) (unsafe-fx+ cnt 1) dup? imm?)]))
              (loop (cdr rem) cnt dup? #f))))))

(define (fast-enemy-priority-const etype arena-has-stealth? su)
  (define ht (if arena-has-stealth? ENEMY-PRIORITY-CONST-CACHE-T ENEMY-PRIORITY-CONST-CACHE-F))
  (define cached (hash-ref ht etype #f))
  (or cached
      (let* ([det? (fast-detector-sym? etype)]
             [decoy-mult (fast-target-priority-mult etype arena-has-stealth?)]
             [eb-dps (+ 5.0 (tactical-sim-unit-ground-dps su) (tactical-sim-unit-air-dps su))]
             [eff-dps (if (and det? arena-has-stealth?) (max 22.0 eb-dps) eb-dps)]
             [v (* decoy-mult eff-dps)])
        (hash-set! ht etype v)
        v)))

(define-syntax-rule (fast-num=fl? raw flv)
  (let ([x raw])
    (cond
      [(flonum? x) (fl= x flv)]
      [(fixnum? x) (fl= (fx->fl x) flv)]
      [(real? x) (= x flv)]
      [else #f])))

(define (refresh-sim-unit-from-hash! su u [acx #f] [acy #f] [force-eta? #f])
  (define utype (hash-ref u 'type 'marine))
  (and (eq? utype (tactical-sim-unit-type su))
       (let* ([rx (hash-ref u 'x 32.5)]
              [ry (hash-ref u 'y 32.5)]
              [old-x (tactical-sim-unit-x su)]
              [old-y (tactical-sim-unit-y su)]
              [same-pos? (and (same-num-fl? rx old-x) (same-num-fl? ry old-y))]
              [ux (if same-pos? old-x (fast->fl rx))]
              [uy (if same-pos? old-y (fast->fl ry))])
         (and (or same-pos?
                  (and (fl<= (flabs (fl- ux old-x)) 4.5)
                       (fl<= (flabs (fl- uy old-y)) 4.5)))
              (let* ([mhp (tactical-sim-unit-max-hp su)]
                     [rhp (or (hash-ref u 'hull-hp #f) (hash-ref u 'hp mhp))]
                     [old-hp (tactical-sim-unit-hp su)]
                     [old-af (tactical-sim-unit-attr-flags su)]
                     [rflags (unsafe-fxand (unsafe-fxrshift old-af 10) 7)]
                     [wc (hash-ref u 'weapon-cooldown #f)]
                     [old-wc (tactical-sim-unit-weapon-cooldown su)])
                (unless (same-num-fl? rhp old-hp)
                  (let ([hp (let ([fhp (fast->fl rhp)])
                              (if (fl> fhp 1.0) fhp 1.0))])
                    (unless (fl= hp old-hp)
                      (set-tactical-sim-unit-hp! su hp))))
                (when (or (not (unsafe-fx= (unsafe-fxand rflags 1) 0))
                          (fl> (tactical-sim-unit-shield su) 0.0))
                  (let ([sh (or (hash-ref u 'shield #f) (hash-ref u 'shields #f))]
                        [old-sh (tactical-sim-unit-shield su)])
                    (when (and sh (not (same-num-fl? sh old-sh)))
                      (let ([fsh (let ([fs (fast->fl sh)])
                                   (if (fl> fs 0.0) fs 0.0))])
                        (unless (fl= fsh old-sh)
                          (set-tactical-sim-unit-shield! su fsh))))))
                (if wc
                    (unless (same-num-fl? wc old-wc)
                      (let ([fwc (let ([fw (fast->fl wc)])
                                   (if (fl> fw 0.0) fw 0.0))])
                        (unless (fl= fwc old-wc)
                          (set-tactical-sim-unit-weapon-cooldown! su fwc))))
                    (unless (fl= 0.0 old-wc)
                      (set-tactical-sim-unit-weapon-cooldown! su 0.0)))
                (when (or (not (unsafe-fx= (unsafe-fxand rflags 2) 0))
                          (tactical-sim-unit-can-cloak? su)
                          (tactical-sim-unit-cloaked? su))
                  (define clk? (hash-undetected-cloak? u))
                  (unless (eq? clk? (tactical-sim-unit-cloaked? su))
                    (set-tactical-sim-unit-cloaked?! su clk?)))
                (when (or (not (unsafe-fx= (unsafe-fxand rflags 4) 0))
                          (fl> (tactical-sim-unit-energy su) 0.0))
                  (let ([en (hash-ref u 'energy #f)]
                        [old-en (tactical-sim-unit-energy su)])
                    (when (and en (not (same-num-fl? en old-en)))
                      (set-tactical-sim-unit-energy! su (fast->fl en)))))
                (let* ([bfs (hash-ref u 'buffs #f)]
                       [bbits (if (pair? bfs) (unit-buff-list-bits bfs) 0)]
                       [new-af (unsafe-fxior (unsafe-fxand old-af 7231) bbits)])
                  (unless (unsafe-fx= new-af old-af)
                    (set-tactical-sim-unit-attr-flags! su new-af)))
                (when (or (not same-pos?) force-eta?)
                  (unless same-pos?
                    (set-tactical-sim-unit-x! su ux)
                    (set-tactical-sim-unit-y! su uy))
                  (when (and acx acy (fl> (tactical-sim-unit-eta-sec su) 0.0))
                    (define spd (flmax 2.0 (tactical-sim-unit-speed su)))
                    (define dx (fl- ux acx))
                    (define dy (fl- uy acy))
                    (define d (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))
                    (set-tactical-sim-unit-eta-sec! su (flmax 0.0 (fl/ (fl- d 6.0) spd)))))
                #t)))))

;; Lightweight position/type validation for reinforcing sim units so cached reuse-locked frames skip full hash sweeps.
(define (validate-reinf-unit-from-hash! su u)
  (and (eq? (hash-ref u 'type 'marine) (tactical-sim-unit-type su))
       (let* ([rx (hash-ref u 'x 32.5)]
              [ry (hash-ref u 'y 32.5)]
              [old-x (tactical-sim-unit-x su)]
              [old-y (tactical-sim-unit-y su)]
              [same-pos? (and (same-num-fl? rx old-x) (same-num-fl? ry old-y))])
         (or same-pos?
             (let ([ux (fast->fl rx)]
                   [uy (fast->fl ry)])
               (and (fl<= (flabs (fl- ux old-x)) 4.5)
                    (fl<= (flabs (fl- uy old-y)) 4.5)
                    (begin
                      (set-tactical-sim-unit-x! su ux)
                      (set-tactical-sim-unit-y! su uy)
                      #t)))))))

(define (refresh-arena-reinforcing! ar ally-by-id enemy-by-id id-gen enemy-id-gen)
  (define raw-cx (tactical-arena-center-x ar))
  (define raw-cy (tactical-arena-center-y ar))
  (define acx (if (flonum? raw-cx) raw-cx (exact->inexact raw-cx)))
  (define acy (if (flonum? raw-cy) raw-cy (exact->inexact raw-cy)))
  (define-syntax-rule (refresh-reinf-list! sus tbl gen)
    (let loop-u ([rem-u sus])
      (or (null? rem-u)
          (let* ([su (car rem-u)]
                 [uid (tactical-sim-unit-id su)]
                 [u (if gen (unit-id-table-lookup tbl gen uid) (hash-ref tbl uid #f))])
            (and u
                 (refresh-sim-unit-from-hash! su u acx acy #t)
                 (loop-u (cdr rem-u)))))))
  (and (refresh-reinf-list! (tactical-arena-reinforcing-allies ar) ally-by-id id-gen)
       (refresh-reinf-list! (tactical-arena-reinforcing-enemies ar) enemy-by-id enemy-id-gen)))

(define (refresh-cached-arenas! cached-arenas ally-by-id enemy-by-id
                                [id-gen #f]
                                [enemy-id-gen id-gen]
                                [su-last-ht #f]
                                [reinf-a-seen #f]
                                [reinf-e-seen #f])
  (when reinf-a-seen (hash-clear! reinf-a-seen))
  (when reinf-e-seen (hash-clear! reinf-e-seen))
  (define-syntax-rule (refresh-unit-list! sus tbl gen seen-tbl)
    (let loop-u ([rem-u sus])
      (if (null? rem-u)
          #t
          (let* ([su (car rem-u)]
                 [uid (tactical-sim-unit-id su)]
                 [u (if gen
                        (unit-id-table-lookup tbl gen uid)
                        (hash-ref tbl uid #f))])
            (and u
                 (if (and su-last-ht (immutable? u) (eq? (hash-ref su-last-ht su #f) u))
                     (begin
                       (when seen-tbl (hash-set! seen-tbl uid su))
                       #t)
                     (and (refresh-sim-unit-from-hash! su u #f #f)
                          (begin
                            (when (and su-last-ht (immutable? u))
                              (hash-set! su-last-ht su u))
                            (when seen-tbl (hash-set! seen-tbl uid su))
                            #t)))
                 (loop-u (cdr rem-u)))))))
  (define-syntax-rule (validate-reinf-list! sus tbl gen seen-tbl)
    (let loop-r ([rem-r sus])
      (if (null? rem-r)
          #t
          (let* ([su (car rem-r)]
                 [uid (tactical-sim-unit-id su)]
                 [cached-su (and seen-tbl (hash-ref seen-tbl uid #f))])
            (and (if cached-su
                     (and (eq? (tactical-sim-unit-type su) (tactical-sim-unit-type cached-su))
                          (let ([nx (tactical-sim-unit-x cached-su)]
                                [ny (tactical-sim-unit-y cached-su)]
                                [ox (tactical-sim-unit-x su)]
                                [oy (tactical-sim-unit-y su)])
                            (or (and (fl= ox nx) (fl= oy ny))
                                (and (fl<= (flabs (fl- nx ox)) 4.5)
                                     (fl<= (flabs (fl- ny oy)) 4.5)
                                     (begin
                                       (set-tactical-sim-unit-x! su nx)
                                       (set-tactical-sim-unit-y! su ny)
                                       #t)))))
                     (let ([u (if gen
                                  (unit-id-table-lookup tbl gen uid)
                                  (hash-ref tbl uid #f))])
                       (and u
                            (validate-reinf-unit-from-hash! su u)
                            (begin
                              (when seen-tbl (hash-set! seen-tbl uid su))
                              #t))))
                 (loop-r (cdr rem-r)))))))
  (let loop-arenas ([rem cached-arenas])
    (if (null? rem)
        #t
        (let ([ar (car rem)])
          (and (refresh-unit-list! (tactical-arena-ally-units ar) ally-by-id id-gen reinf-a-seen)
               (refresh-unit-list! (tactical-arena-enemy-units ar) enemy-by-id enemy-id-gen reinf-e-seen)
               (validate-reinf-list! (tactical-arena-reinforcing-allies ar) ally-by-id id-gen reinf-a-seen)
               (validate-reinf-list! (tactical-arena-reinforcing-enemies ar) enemy-by-id enemy-id-gen reinf-e-seen)
               (loop-arenas (cdr rem)))))))

(define (scan-target-vecs vecs ux uy best best-sc best-sc2)
  (let loop ([rem vecs] [b best] [bsc best-sc] [bsc2 best-sc2])
    (if (null? rem)
        (values b bsc bsc2)
        (let* ([ev (car rem)]
               [dx (fl- (vector-ref ev 2) ux)]
               [dy (fl- (vector-ref ev 3) uy)]
               [d2 (flmax 1.0 (fl+ (fl* dx dx) (fl* dy dy)))]
               [val (vector-ref ev 4)])
          (if (and (fl> bsc 0.0) (fl> val 0.0))
              (if (fl> (fl* val val) (fl* bsc2 d2))
                  (let ([sc (fl/ val (flsqrt d2))])
                    (loop (cdr rem) (vector-ref ev 0) sc (fl* sc sc)))
                  (loop (cdr rem) b bsc bsc2))
              (let ([sc (fl/ val (flsqrt d2))])
                (if (fl> sc bsc)
                    (loop (cdr rem) (vector-ref ev 0) sc (if (fl> sc 0.0) (fl* sc sc) 0.0))
                    (loop (cdr rem) b bsc bsc2))))))))

;; Cached LotV attacker-vs-target focus multiplier rows indexed by compact unit-type index.
;; Each entry is an 8-element flvector for state bits: (if sh? 1 0) | (if aam? 2 0) | (if gs? 4 0).
(define PAIR-FOCUS-PROF-CACHE (make-hasheq))

(define (fast-atk-focus-profile atk-type)
  (hash-ref!
   PAIR-FOCUS-PROF-CACHE
   atk-type
   (lambda ()
     (define ast (fast-unit-stat-vec atk-type))
     (define bmask (unit-primary-bonus-attr-mask atk-type))
     (define massive-bonus? (not (fx= (fxand bmask SC2-UNIT-ATTR-MASSIVE) 0)))
     (define nb-scale (if (fx> bmask 0) 0.75 1.0))
     (define max-b-scale (if massive-bonus? 3.25 2.55))
     ;; Admissible upper bounds (dps-ratio clamped to 3.5 max):
     ;;   non-bonus: max dps-ratio (~1.50 without AAM, ~1.85 with AAM) * nb-scale
     ;;   bonus: max dps-ratio (3.5) * max-b-scale
     (vector (make-vector 256 #f)
             ast
             bmask
             (fl* 1.40 nb-scale)
             (fl* 1.90 nb-scale)
             (fl* 3.5 max-b-scale)))))

(define (compute-pair-focus-flvec atk-type ast atk-bonus tgt-type)
  (define tgt-sv (fast-unit-stat-vec tgt-type))
  (define tgt-attr (vector-ref tgt-sv 17))
  (define tgt-flying? (vector-ref tgt-sv 12))
  (define base-gd (vector-ref ast 5))
  (define base-ad (vector-ref ast 6))
  (define use-air? (or tgt-flying? (and (eq? tgt-type 'colossus) (fl<= base-gd 0.0))))
  (define ref-dps (flmax 1.0 (if use-air? base-ad base-gd)))
  (define has-bonus? (fx> atk-bonus 0))
  (define bonus-match? (and has-bonus? (fx> (fxand atk-bonus tgt-attr) 0)))
  (define massive-match? (and has-bonus? (fx> (fxand (fxand atk-bonus SC2-UNIT-ATTR-MASSIVE) tgt-attr) 0)))
  (define attr-pref
    (cond
      [massive-match? 3.25]
      [bonus-match? 2.55]
      [has-bonus? 0.75]
      [else 1.0]))
  (define fv (make-flvector 8 1.0))
  (for ([s (in-range 8)])
    (define sh? (not (fx= (fxand s 1) 0)))
    (define aam? (not (fx= (fxand s 2) 0)))
    (define gs? (not (fx= (fxand s 4) 0)))
    (define exact-dps
      (compute-exact-weapon-dps-vs-target
       atk-type tgt-type
       #:target-shields (if sh? 999.0 0.0)
       #:aam-debuff? aam?
       #:guardian-shield? gs?))
    (define dps-ratio
      (if (fl<= exact-dps 0.0)
          0.25
          (flmin 3.5 (flmax 0.25 (fl/ exact-dps ref-dps)))))
    (unsafe-flvector-set! fv s (fl* dps-ratio attr-pref)))
  fv)

(define (lookup-pair-focus-flvec! row tidx atk-type ast atk-bonus tgt-type)
  (let ([cached (unsafe-vector-ref row tidx)])
    (or cached
        (let ([fv (compute-pair-focus-flvec atk-type ast atk-bonus tgt-type)])
          (unsafe-vector-set! row tidx fv)
          fv))))

(define (eval-ev-focus-mult row atk-type ast atk-bonus ev)
  (define tidx (unsafe-vector-ref ev 5))
  (define fv (lookup-pair-focus-flvec! row tidx atk-type ast atk-bonus (tactical-sim-unit-type (unsafe-vector-ref ev 0))))
  (define sb (unsafe-vector-ref ev 6))
  (define base-mult (unsafe-flvector-ref fv (unsafe-fxand sb 7)))
  (if (unsafe-fx= (unsafe-fxand sb 8) 0)
      base-mult
      (let* ([e (unsafe-vector-ref ev 0)]
             [ehp (flmax 1.0 (fl+ (tactical-sim-unit-hp e) (tactical-sim-unit-shield e)))])
        (fl* base-mult (fl/ ehp (fl+ ehp 100.0))))))

;; W10-TAC-4: Exact SC2 Crucio Shock Cannon 2.0t edge-to-edge minimum-range deadzone
;; (`center_dist < 2.0 + r_tank + r_target` is strictly untargetable in SC2, e.g. <3.25t for Zerglings).
(define (sieged-tank-in-min-range-deadzone? atk-type atk-r tgt-su raw-d2)
  (and (eq? atk-type 'siege-tank-sieged)
       (let ([min-c (fl+ 2.0 (fl+ atk-r (tactical-sim-unit-radius tgt-su)))])
         (fl< raw-d2 (fl* min-c min-c)))))

(define (scan-target-vecs/atk vecs ux uy best best-sc best-sc2 row atk-type ast atk-bonus [atk-r 0.875])
  (let loop ([rem vecs] [b best] [bsc best-sc] [bsc2 best-sc2])
    (if (null? rem)
        (values b bsc bsc2)
        (let* ([ev (car rem)]
               [dx (fl- (vector-ref ev 2) ux)]
               [dy (fl- (vector-ref ev 3) uy)]
               [raw-d2 (fl+ (fl* dx dx) (fl* dy dy))])
          (if (sieged-tank-in-min-range-deadzone? atk-type atk-r (vector-ref ev 0) raw-d2)
              (loop (cdr rem) b bsc bsc2)
              (let* ([d2 (flmax 1.0 raw-d2)]
                     [mult (eval-ev-focus-mult row atk-type ast atk-bonus ev)]
                     [val (fl* (vector-ref ev 4) mult)])
                (if (and (fl> bsc 0.0) (fl> val 0.0))
                    (if (fl> (fl* val val) (fl* bsc2 d2))
                        (let ([sc (fl/ val (flsqrt d2))])
                          (loop (cdr rem) (vector-ref ev 0) sc (fl* sc sc)))
                        (loop (cdr rem) b bsc bsc2))
                    (let ([sc (fl/ val (flsqrt d2))])
                      (if (fl> sc bsc)
                          (loop (cdr rem) (vector-ref ev 0) sc (if (fl> sc 0.0) (fl* sc sc) 0.0))
                          (loop (cdr rem) b bsc bsc2))))))))))

;; Pair of (#f . vecs) for small lists, or (#t . cell-list) where each cell is
;; (vector xmin xmax ymin ymax max-val sorted-vecs-desc-by-val cell-attr-or).
(define (build-target-spatial-plan vecs [pad-fl 0.0])
  (cond
    [(null? vecs) #f]
    [(null? (cdr vecs)) (cons #f vecs)]
    [(let loop ([rem vecs] [n 0]) (cond [(>= n 28) #f] [(null? rem) #t] [else (loop (cdr rem) (+ n 1))]))
     (cons #f vecs)]
    [else
     (define buckets SPATIAL-PLAN-BUCKETS)
     (when (> (hash-count buckets) 512)
       (hash-clear! buckets))
     (set! SPATIAL-BUCKET-GEN (+ SPATIAL-BUCKET-GEN 1))
     (define gen SPATIAL-BUCKET-GEN)
     (define bucket-slots '())
     (define inv-cs 0.3333333333333333)
     (for ([ev (in-list vecs)])
       (define ex (vector-ref ev 2))
       (define ey (vector-ref ev 3))
       (define cx (+ (fl->exact-integer (flfloor (fl* ex inv-cs))) 1024))
       (define cy (+ (fl->exact-integer (flfloor (fl* ey inv-cs))) 1024))
       (define key (+ (* cx 4096) cy))
       (define slot (hash-ref buckets key #f))
       (cond
         [(not slot)
          (define s (mcons gen (list ev)))
          (hash-set! buckets key s)
          (set! bucket-slots (cons s bucket-slots))]
         [(eqv? (mcar slot) gen)
          (set-mcdr! slot (cons ev (mcdr slot)))]
         [else
          (set-mcar! slot gen)
          (set-mcdr! slot (list ev))
          (set! bucket-slots (cons slot bucket-slots))]))
     (define cells
       (for/list ([slot (in-list bucket-slots)])
         (define evs (mcdr slot))
         (define ev0 (car evs))
         (define x0 (vector-ref ev0 2))
         (define y0 (vector-ref ev0 3))
         (define v0 (vector-ref ev0 4))
         (define a0 (let ([base-m (tactical-sim-unit-attr-mask (vector-ref ev0 0))])
                      (if (and (>= (vector-length ev0) 7)
                               (not (fx= (fxand (vector-ref ev0 6) 2) 0)))
                          (fxior base-m 1073741824)
                          base-m)))
         (let loop ([rem (cdr evs)] [xmin x0] [xmax x0] [ymin y0] [ymax y0] [vmax v0] [aor a0])
           (if (null? rem)
               (let ([sorted (cond
                               [(null? (cdr evs)) evs]
                               [(null? (cddr evs))
                                (let ([e1 (car evs)] [e2 (cadr evs)])
                                  (if (fl>= (vector-ref e1 4) (vector-ref e2 4))
                                      evs
                                      (list e2 e1)))]
                               [else
                                (sort evs vec4>)])])
                 (vector (fl- xmin pad-fl) (fl+ xmax pad-fl) (fl- ymin pad-fl) (fl+ ymax pad-fl) vmax sorted aor))
               (let* ([e (car rem)]
                      [x (vector-ref e 2)]
                      [y (vector-ref e 3)]
                      [v (vector-ref e 4)]
                      [am (tactical-sim-unit-attr-mask (vector-ref e 0))]
                      [am2 (if (and (>= (vector-length e) 7)
                                    (not (fx= (fxand (vector-ref e 6) 2) 0)))
                               (fxior am 1073741824)
                               am)])
                 (loop (cdr rem)
                       (if (fl< x xmin) x xmin)
                       (if (fl> x xmax) x xmax)
                       (if (fl< y ymin) y ymin)
                       (if (fl> y ymax) y ymax)
                       (if (fl> v vmax) v vmax)
                       (fxior aor am2)))))))
     (cons #t cells)]))

(define (cell-min-d2 cell ux uy)
  (define xmin (vector-ref cell 0))
  (define xmax (vector-ref cell 1))
  (define ymin (vector-ref cell 2))
  (define ymax (vector-ref cell 3))
  (define dx (cond [(fl< ux xmin) (fl- xmin ux)] [(fl> ux xmax) (fl- ux xmax)] [else 0.0]))
  (define dy (cond [(fl< uy ymin) (fl- ymin uy)] [(fl> uy ymax) (fl- uy ymax)] [else 0.0]))
  (flmax 1.0 (fl+ (fl* dx dx) (fl* dy dy))))

(define (scan-cell-vecs vecs min-d2 ux uy best best-sc best-sc2)
  (let loop ([rem vecs] [b best] [bsc best-sc] [bsc2 best-sc2])
    (if (null? rem)
        (values b bsc bsc2)
        (let* ([ev (car rem)]
               [val (vector-ref ev 4)])
          (if (and (fl> bsc 0.0) (fl> val 0.0) (fl<= (fl* val val) (fl* bsc2 min-d2)))
              (values b bsc bsc2)
              (let* ([dx (fl- (vector-ref ev 2) ux)]
                     [dy (fl- (vector-ref ev 3) uy)]
                     [d2 (flmax 1.0 (fl+ (fl* dx dx) (fl* dy dy)))])
                (if (and (fl> bsc 0.0) (fl> val 0.0))
                    (if (fl> (fl* val val) (fl* bsc2 d2))
                        (let ([sc (fl/ val (flsqrt d2))])
                          (loop (cdr rem) (vector-ref ev 0) sc (fl* sc sc)))
                        (loop (cdr rem) b bsc bsc2))
                    (let ([sc (fl/ val (flsqrt d2))])
                      (if (fl> sc bsc)
                          (loop (cdr rem) (vector-ref ev 0) sc (if (fl> sc 0.0) (fl* sc sc) 0.0))
                          (loop (cdr rem) b bsc bsc2))))))))))

(define (scan-cell-vecs/atk vecs min-d2 cell-ub ux uy best best-sc best-sc2 row atk-type ast atk-bonus [atk-r 0.875])
  (let loop ([rem vecs] [b best] [bsc best-sc] [bsc2 best-sc2])
    (if (null? rem)
        (values b bsc bsc2)
        (let* ([ev (car rem)]
               [base-val (vector-ref ev 4)]
               [ub-val (fl* base-val cell-ub)])
          (if (and (fl> bsc 0.0) (fl> ub-val 0.0) (fl<= (fl* ub-val ub-val) (fl* bsc2 min-d2)))
              (values b bsc bsc2)
              (let* ([dx (fl- (vector-ref ev 2) ux)]
                     [dy (fl- (vector-ref ev 3) uy)]
                     [raw-d2 (fl+ (fl* dx dx) (fl* dy dy))])
                (if (sieged-tank-in-min-range-deadzone? atk-type atk-r (vector-ref ev 0) raw-d2)
                    (loop (cdr rem) b bsc bsc2)
                    (let* ([d2 (flmax 1.0 raw-d2)]
                           [mult (eval-ev-focus-mult row atk-type ast atk-bonus ev)]
                           [val (fl* base-val mult)])
                      (if (and (fl> bsc 0.0) (fl> val 0.0))
                          (if (fl> (fl* val val) (fl* bsc2 d2))
                              (let ([sc (fl/ val (flsqrt d2))])
                                (loop (cdr rem) (vector-ref ev 0) sc (fl* sc sc)))
                              (loop (cdr rem) b bsc bsc2))
                          (let ([sc (fl/ val (flsqrt d2))])
                            (if (fl> sc bsc)
                                (loop (cdr rem) (vector-ref ev 0) sc (if (fl> sc 0.0) (fl* sc sc) 0.0))
                                (loop (cdr rem) b bsc bsc2))))))))))))

(define (cell-focus-ub c prof)
  (define bmask (vector-ref prof 2))
  (define aor (vector-ref c 6))
  (cond
    [(and (fx> bmask 0) (not (fx= (fxand aor bmask) 0)))
     (vector-ref prof 5)]
    [(not (fx= (fxand aor 1073741824) 0))
     (vector-ref prof 4)]
    [else
     (vector-ref prof 3)]))

(define (pick-best-target-from-plan plan ux uy best best-sc best-sc2 [attacker #f])
  (define fux (if (flonum? ux) ux (exact->inexact ux)))
  (define fuy (if (flonum? uy) uy (exact->inexact uy)))
  (define fbest-sc (if (flonum? best-sc) best-sc (exact->inexact best-sc)))
  (define fbest-sc2 (if (flonum? best-sc2) best-sc2 (exact->inexact best-sc2)))
  (define use-atk?
    (and attacker
         (let ([evs (and plan (if (car plan) (vector-ref (cadr plan) 5) (cdr plan)))])
           (and (pair? evs) (>= (vector-length (car evs)) 7)))))
  (define atk-type (and use-atk? (tactical-sim-unit-type attacker)))
  (define atk-r (if use-atk? (tactical-sim-unit-radius attacker) 0.875))
  (define atk-prof (and use-atk? (fast-atk-focus-profile atk-type)))
  (define atk-row (and atk-prof (vector-ref atk-prof 0)))
  (define atk-ast (and atk-prof (vector-ref atk-prof 1)))
  (define atk-bonus (and atk-prof (vector-ref atk-prof 2)))
  (cond
    [(not plan) (values best fbest-sc fbest-sc2)]
    [(not (car plan))
     (if use-atk?
         (scan-target-vecs/atk (cdr plan) fux fuy best fbest-sc fbest-sc2 atk-row atk-type atk-ast atk-bonus atk-r)
         (scan-target-vecs (cdr plan) fux fuy best fbest-sc fbest-sc2))]
    [else
     (define cells (cdr plan))
     ;; Seed with the spatially nearest cell so best-sc immediately prunes distant cells
     (define-values (first-c md2)
       (let loop ([rem (cdr cells)] [bc (car cells)] [bd2 (cell-min-d2 (car cells) fux fuy)])
         (if (null? rem)
             (values bc bd2)
             (let* ([c (car rem)]
                    [d2 (cell-min-d2 c fux fuy)])
               (if (fl< d2 bd2)
                   (loop (cdr rem) c d2)
                   (loop (cdr rem) bc bd2))))))
     (define-values (b0 bsc0 bsc20)
       (if use-atk?
           (let* ([cub (cell-focus-ub first-c atk-prof)]
                  [cmax (fl* (vector-ref first-c 4) cub)])
             (if (and (fl> fbest-sc 0.0) (fl> cmax 0.0) (fl<= (fl* cmax cmax) (fl* fbest-sc2 md2)))
                 (values best fbest-sc fbest-sc2)
                 (scan-cell-vecs/atk (vector-ref first-c 5) md2 cub fux fuy best fbest-sc fbest-sc2
                                     atk-row atk-type atk-ast atk-bonus atk-r)))
           (let ([cmax (vector-ref first-c 4)])
             (if (and (fl> fbest-sc 0.0) (fl> cmax 0.0) (fl<= (fl* cmax cmax) (fl* fbest-sc2 md2)))
                 (values best fbest-sc fbest-sc2)
                 (scan-cell-vecs (vector-ref first-c 5) md2 fux fuy best fbest-sc fbest-sc2)))))
     (let loop ([rem cells] [b b0] [bsc bsc0] [bsc2 bsc20])
       (if (null? rem)
           (values b bsc bsc2)
           (let ([c (car rem)])
             (if (eq? c first-c)
                 (loop (cdr rem) b bsc bsc2)
                 (let ([md2 (cell-min-d2 c fux fuy)])
                   (if use-atk?
                       (let* ([cub (cell-focus-ub c atk-prof)]
                              [cmax (fl* (vector-ref c 4) cub)])
                         (if (and (fl> bsc 0.0) (fl> cmax 0.0) (fl<= (fl* cmax cmax) (fl* bsc2 md2)))
                             (loop (cdr rem) b bsc bsc2)
                             (let-values ([(nb nbsc nbsc2)
                                           (scan-cell-vecs/atk (vector-ref c 5) md2 cub fux fuy b bsc bsc2
                                                               atk-row atk-type atk-ast atk-bonus atk-r)])
                               (loop (cdr rem) nb nbsc nbsc2))))
                       (let ([cmax (vector-ref c 4)])
                         (if (and (fl> bsc 0.0) (fl> cmax 0.0) (fl<= (fl* cmax cmax) (fl* bsc2 md2)))
                             (loop (cdr rem) b bsc bsc2)
                             (let-values ([(nb nbsc nbsc2)
                                           (scan-cell-vecs (vector-ref c 5) md2 fux fuy b bsc bsc2)])
                               (loop (cdr rem) nb nbsc nbsc2))))))))))]))

;; Direct `tactical-sim-unit` splash-commit evaluator avoiding 400-hash allocation per frame.
(define *ARENA-SPLASH-EXCLUDED-HT*
  (for/hasheq ([s (in-list
                   '(purification-nova disruptor-phased
                     observer observer-siege-mode overseer overseer-siege-mode
                     overlord warp-prism warp-prism-phasing interceptor
                     larva egg baneling-cocoon ravager-cocoon lurker-egg lurker-mp-egg
                     brood-lord-cocoon overlord-cocoon changeling changeling-zealot
                     changeling-zergling changeling-marine changeling-marine-shield
                     hatchery lair hive spawning-pool roach-warren baneling-nest
                     hydralisk-den lurker-den infestation-pit spire greater-spire
                     ultralisk-cavern nydus-network nydus-canal extractor spine-crawler
                     spore-crawler creep-tumor creep-tumor-burrowed
                     nexus pylon gateway warpgate assimilator cybernetics-core forge
                     photon-cannon shield-battery twilight-council templar-archives
                     dark-shrine stargate fleet-beacon robotics-facility robotics-bay
                     command-center orbital-command planetary-fortress supply-depot
                     supply-depot-lowered refinery barracks barracks-flying factory
                     factory-flying starport starport-flying engineering-bay armory
                     bunker missile-turret sensor-tower fusion-core ghost-academy))])
    (values s #t)))

(define *ARENA-SPLASH-WORKER-OR-FLY-HT*
  (for/hasheq ([s (in-list
                   '(drone scv probe mule
                     overlord overseer overseer-siege-mode mutalisk corruptor brood-lord viper
                     phoenix void-ray oracle carrier tempest mothership interceptor
                     observer observer-siege-mode warp-prism warp-prism-phasing
                     medivac viking-fighter viking banshee raven battlecruiser
                     liberator liberator-ag scourge))])
    (values s #t)))

(define *ARENA-SPLASH-UNIT-META-HT*
  (let ([sup-ht
         (hasheq
          'zergling 0.5 'zergling-burrowed 0.5 'baneling 0.5 'baneling-burrowed 0.5
          'queen 2.0 'roach 2.0 'roach-burrowed 2.0 'ravager 3.0 'ravager-burrowed 3.0
          'hydralisk 2.0 'hydralisk-burrowed 2.0 'lurker 3.0 'lurker-mp 3.0
          'lurker-burrowed 3.0 'lurker-mp-burrowed 3.0 'infestor 2.0 'infestor-burrowed 2.0
          'swarm-host 3.0 'swarm-host-burrowed 3.0 'mutalisk 2.0 'corruptor 2.0
          'viper 3.0 'brood-lord 4.0 'ultralisk 6.0 'ultralisk-burrowed 6.0
          'marine 1.0 'reaper 1.0 'marauder 2.0 'ghost 2.0
          'hellion 2.0 'hellbat 2.0 'hellion-tank 2.0 'widow-mine 2.0 'widow-mine-burrowed 2.0
          'siege-tank 3.0 'siege-tank-sieged 3.0 'cyclone 3.0 'thor 6.0 'thor-ap 6.0
          'viking 2.0 'viking-fighter 2.0 'viking-assault 2.0 'medivac 2.0
          'liberator 3.0 'liberator-ag 3.0 'raven 2.0 'banshee 3.0 'battlecruiser 6.0
          'zealot 2.0 'stalker 2.0 'sentry 2.0 'adept 2.0
          'high-templar 2.0 'dark-templar 2.0 'archon 4.0 'immortal 4.0
          'colossus 6.0 'disruptor 4.0 'phoenix 2.0 'void-ray 4.0
          'oracle 3.0 'carrier 6.0 'tempest 5.0 'mothership 6.0
          'drone 1.0 'scv 1.0 'probe 1.0)]
        [pw-ht
         (hasheq
          'zergling '(35.0 . 10.0) 'baneling '(30.0 . 20.0) 'queen '(175.0 . 12.0)
          'roach '(145.0 . 11.2) 'ravager '(120.0 . 14.0) 'hydralisk '(90.0 . 20.4)
          'lurker '(200.0 . 20.0) 'lurker-burrowed '(200.0 . 24.0)
          'lurker-mp '(200.0 . 20.0) 'lurker-mp-burrowed '(200.0 . 24.0)
          'mutalisk '(120.0 . 11.9) 'corruptor '(200.0 . 14.7) 'brood-lord '(225.0 . 22.4)
          'ultralisk '(500.0 . 57.4) 'marine '(45.0 . 9.8) 'marauder '(125.0 . 13.9)
          'reaper '(60.0 . 10.1) 'ghost '(100.0 . 14.4) 'hellion '(90.0 . 6.5)
          'hellbat '(135.0 . 16.8) 'hellion-tank '(135.0 . 16.8) 'cyclone '(130.0 . 22.4)
          'siege-tank '(175.0 . 26.0) 'siege-tank-sieged '(175.0 . 30.0)
          'thor '(400.0 . 50.0) 'viking '(135.0 . 14.0) 'viking-fighter '(135.0 . 14.0)
          'viking-assault '(135.0 . 16.8) 'medivac '(150.0 . 0.0)
          'liberator '(180.0 . 14.0) 'liberator-ag '(180.0 . 65.8)
          'banshee '(140.0 . 27.0) 'battlecruiser '(550.0 . 49.8)
          'zealot '(150.0 . 18.6) 'stalker '(160.0 . 13.4) 'sentry '(80.0 . 8.4)
          'adept '(140.0 . 9.6) 'high-templar '(80.0 . 8.0) 'dark-templar '(120.0 . 37.2)
          'archon '(360.0 . 25.0) 'immortal '(300.0 . 29.0)
          'colossus '(350.0 . 34.0) 'disruptor '(200.0 . 18.0)
          'phoenix '(180.0 . 14.0) 'void-ray '(250.0 . 22.4) 'oracle '(160.0 . 24.4)
          'carrier '(450.0 . 37.5) 'tempest '(300.0 . 16.8)
          'drone '(40.0 . 4.7) 'scv '(45.0 . 4.7) 'probe '(40.0 . 4.7))]
        [ht (make-hasheq)])
    (for ([k (in-hash-keys sup-ht)])
      (define pw (hash-ref pw-ht k '(80.0 . 10.0)))
      (hash-set! ht k (vector-immutable (hash-ref sup-ht k 1.0)
                                        (cdr pw)
                                        (not (hash-ref *ARENA-SPLASH-EXCLUDED-HT* k #f))
                                        (not (hash-ref *ARENA-SPLASH-WORKER-OR-FLY-HT* k #f)))))
    (for ([(k pw) (in-hash pw-ht)])
      (unless (hash-has-key? ht k)
        (hash-set! ht k (vector-immutable (hash-ref sup-ht k 1.0)
                                          (cdr pw)
                                          (not (hash-ref *ARENA-SPLASH-EXCLUDED-HT* k #f))
                                          (not (hash-ref *ARENA-SPLASH-WORKER-OR-FLY-HT* k #f))))))
    (for ([k (in-hash-keys *ARENA-SPLASH-EXCLUDED-HT*)])
      (hash-set! ht k (vector-immutable 1.0 10.0 #f #f)))
    (for/hasheq ([(k v) (in-hash ht)]) (values k v))))

(define *ARENA-DEFAULT-SPLASH-META* (vector-immutable 1.0 10.0 #t #t))

(define (arena-compute-points-arc-deg xs ys cx cy)
  (define n (length xs))
  (cond
    [(fx< n 2) 0.0]
    [else
     (define angs
       (sort
        (let loop ([rx xs] [ry ys] [acc '()])
          (if (null? rx)
              acc
              (let* ([dx (fl- (car rx) cx)]
                     [dy (fl- (car ry) cy)]
                     [deg (if (and (fl< (flabs dx) 1e-6) (fl< (flabs dy) 1e-6))
                              0.0
                              (let ([a (fl* (atan dy dx) 57.29577951308232)])
                                (if (fl< a 0.0) (fl+ a 360.0) a)))])
                (loop (cdr rx) (cdr ry) (cons deg acc)))))
        fl<))
     (define-values (best-gap prev)
       (for/fold ([bg 0.0] [p (car angs)]) ([a (in-list (cdr angs))])
         (values (flmax bg (fl- a p)) a)))
     (define wrap-gap (fl- (fl+ (car angs) 360.0) prev))
     (flmax 0.0 (flmin 360.0 (fl- 360.0 (flmax best-gap wrap-gap))))]))

(define (arena-hash-fl-pos h key)
  (define v (hash-ref h key #f))
  (cond
    [(flonum? v) (fl> v 0.0)]
    [(fixnum? v) (fx> v 0)]
    [(real? v) (> v 0)]
    [else #f]))

(define (arena-direct-should-commit-through-splash? ally-sims enemy-sims tank-lurker-hashes disp ratio has-detector?)
  (define timing-commit? (eq? disp 'execute-timing-attack-commit))
  (cond
    [(or (null? ally-sims) (null? enemy-sims)) timing-commit?]
    [else
     (define n-tanks 0)
     (define n-lurkers 0)
     (define n-colossi 0)
     (define n-disruptors 0)
     (define n-disruptors-cd 0)
     (define n-hts 0)
     (define sp-x '())
     (define sp-y '())
     (define sp-r2 '())
     (define sum-cx 0.0)
     (define sum-cy 0.0)
     (define n-sp 0)
     (for ([e (in-list tank-lurker-hashes)])
       (define et (hash-ref e 'type #f))
       (define thr-r
         (cond
           [(or (eq? et 'siege-tank-sieged)
                (and (eq? et 'siege-tank)
                     (or (hash-ref e 'sieged #f)
                         (hash-ref e 'sieged? #f)
                         (hash-ref e 'is-sieged? #f))))
            (set! n-tanks (fx+ n-tanks 1))
            13.5]
           [(or (eq? et 'lurker-burrowed)
                (eq? et 'lurker-mp-burrowed)
                (and (or (eq? et 'lurker) (eq? et 'lurker-mp))
                     (or (hash-ref e 'burrowed #f)
                         (hash-ref e 'burrowed? #f)
                         (hash-ref e 'is-burrowed? #f))))
            (set! n-lurkers (fx+ n-lurkers 1))
            10.5]
           [(eq? et 'colossus)
            (set! n-colossi (fx+ n-colossi 1))
            9.5]
           [(eq? et 'disruptor)
            (set! n-disruptors (fx+ n-disruptors 1))
            (when (or (arena-hash-fl-pos e 'nova-cooldown)
                      (arena-hash-fl-pos e 'cooldown-remaining)
                      (arena-hash-fl-pos e 'cooldown)
                      (arena-hash-fl-pos e 'weapon-cooldown)
                      (eq? (hash-ref e 'state #f) 'on-cooldown))
              (set! n-disruptors-cd (fx+ n-disruptors-cd 1)))
            12.0]
           [(eq? et 'high-templar)
            (set! n-hts (fx+ n-hts 1))
            10.5]
           [else 0.0]))
       (when (fl> thr-r 0.0)
         (define rx (hash-ref e 'x #f))
         (define ry (hash-ref e 'y #f))
         (when (and (real? rx) (real? ry))
           (define ex (fast->fl rx))
           (define ey (fast->fl ry))
           (when (and (fl= (fl- ex ex) 0.0) (fl= (fl- ey ey) 0.0))
             (set! sp-x (cons ex sp-x))
             (set! sp-y (cons ey sp-y))
             (set! sp-r2 (cons (fl* thr-r thr-r) sp-r2))
             (set! sum-cx (fl+ sum-cx ex))
             (set! sum-cy (fl+ sum-cy ey))
             (set! n-sp (fx+ n-sp 1))))))
     (cond
       [(and (not timing-commit?)
             (fx= (fx+ (fx+ n-tanks n-lurkers) (fx+ (fx+ n-colossi n-disruptors) n-hts)) 0))
        #f]
       [else
        (define need-eff? (not (real? ratio)))
        (define f-sup 0.0)
        (define f-ehp 0.0)
        (define f-dps 0.0)
        (for ([su (in-list ally-sims)])
          (define hp (tactical-sim-unit-hp su))
          (define sh (tactical-sim-unit-shield su))
          (define ehp (fl+ hp sh))
          (when (fl> ehp 0.0)
            (define meta (hash-ref *ARENA-SPLASH-UNIT-META-HT*
                                   (tactical-sim-unit-type su)
                                   *ARENA-DEFAULT-SPLASH-META*))
            (when (vector-ref meta 2)
              (set! f-sup (fl+ f-sup (vector-ref meta 0)))
              (when need-eff?
                (set! f-ehp (fl+ f-ehp ehp))
                (set! f-dps (fl+ f-dps (vector-ref meta 1)))))))
        (cond
          [(fl<= f-sup 0.0) #f]
          [else
           (define e-sup 0.0)
           (define e-ehp 0.0)
           (define e-dps 0.0)
           (for ([su (in-list enemy-sims)])
             (define hp (tactical-sim-unit-hp su))
             (define sh (tactical-sim-unit-shield su))
             (define ehp (fl+ hp sh))
             (when (fl> ehp 0.0)
               (define meta (hash-ref *ARENA-SPLASH-UNIT-META-HT*
                                      (tactical-sim-unit-type su)
                                      *ARENA-DEFAULT-SPLASH-META*))
               (when (vector-ref meta 2)
                 (set! e-sup (fl+ e-sup (vector-ref meta 0)))
                 (when need-eff?
                   (set! e-ehp (fl+ e-ehp ehp))
                   (set! e-dps (fl+ e-dps (vector-ref meta 1)))))))
           (define sup-ratio (fl/ f-sup (flmax 0.5 e-sup)))
           (define eff-ratio
             (if need-eff?
                 (let ([ep (fl* e-ehp e-dps)])
                   (if (fl> ep 0.0)
                       (fl/ (fl* f-ehp f-dps) ep)
                       (fl* sup-ratio sup-ratio)))
                 (fast->fl ratio)))
           (cond
             [timing-commit?
              (not (and (fx> n-lurkers 0)
                        (not has-detector?)
                        (or (fl< sup-ratio 0.90) (fl< eff-ratio 0.90))))]
             [(fl< sup-ratio 0.90) #f]
             [(and (fx> n-disruptors 0)
                   (fl>= (fl/ (exact->inexact n-disruptors-cd) (exact->inexact n-disruptors)) 0.50))
              #t]
             [(and (fx> n-colossi 0) (fl>= sup-ratio 1.20) (fl>= eff-ratio 1.50))
              #t]
             [(and (fx> n-hts 0) (fl>= sup-ratio 1.10) (fl>= eff-ratio 1.25))
              #t]
             [(or (and (fx> n-tanks 0) (fl>= sup-ratio 1.05))
                  (and (fx> n-lurkers 0) has-detector? (fl>= sup-ratio 1.15)))
              (define n-fg 0)
              (define in-cnt 0)
              (define fg-x '())
              (define fg-y '())
              (for ([su (in-list ally-sims)])
                (unless (tactical-sim-unit-flying? su)
                  (define hp (tactical-sim-unit-hp su))
                  (define sh (tactical-sim-unit-shield su))
                  (when (fl> (fl+ hp sh) 0.0)
                    (define meta (hash-ref *ARENA-SPLASH-UNIT-META-HT*
                                           (tactical-sim-unit-type su)
                                           *ARENA-DEFAULT-SPLASH-META*))
                    (when (vector-ref meta 3)
                      (define ux (tactical-sim-unit-x su))
                      (define uy (tactical-sim-unit-y su))
                      (set! n-fg (fx+ n-fg 1))
                      (set! fg-x (cons ux fg-x))
                      (set! fg-y (cons uy fg-y))
                      (when (let sloop ([sx sp-x] [sy sp-y] [sr2 sp-r2])
                              (and (pair? sx)
                                   (let ([dx (fl- ux (car sx))]
                                         [dy (fl- uy (car sy))])
                                     (or (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (car sr2))
                                         (sloop (cdr sx) (cdr sy) (cdr sr2))))))
                        (set! in-cnt (fx+ in-cnt 1)))))))
              (define frac-in-splash
                (if (or (fx= n-fg 0) (fx= n-sp 0))
                    0.0
                    (fl/ (exact->inexact in-cnt) (exact->inexact n-fg))))
              (or (and (fx> n-tanks 0) (fl>= sup-ratio 1.05) (fl>= frac-in-splash 0.55))
                  (and (fx> n-lurkers 0) has-detector? (fl>= sup-ratio 1.15) (fl>= frac-in-splash 0.55))
                  (and (fx> n-sp 0)
                       (fx>= n-fg 2)
                       (let ([arc (arena-compute-points-arc-deg
                                   fg-x fg-y
                                   (fl/ sum-cx (exact->inexact n-sp))
                                   (fl/ sum-cy (exact->inexact n-sp)))])
                         (or (and (fx> n-tanks 0) (fl>= sup-ratio 1.25) (fl>= eff-ratio 1.35) (fl>= arc 35.0))
                             (and (fx> n-lurkers 0) has-detector? (fl>= sup-ratio 1.35) (fl>= eff-ratio 1.25) (fl>= arc 45.0))))))]
             [else #f])])])]))

(define (step-tactical-mirror-brain! brain arg1 [arg2 #f]
                                     #:order-ledger [kw-ledger #f]
                                     #:record-ledger? [record-ledger? #t]
                                     #:chokes [chokes '()]
                                     #:strategic-opp-depth [opp-d 1]
                                     #:effects [kw-effects #f]
                                     #:tactical-disposition [kw-disp #f]
                                     #:lanchester-ratio [kw-lr #f]
                                     #:enemy-upgrades [kw-enemy-upgs #f]
                                     #:has-detector? [kw-has-detector? #f]
                                     #:combat-should-engage? [kw-combat-should-engage? #t]
                                     #:defending-home? [kw-defending-home? #f])
  (define-values (obs ledger)
    (if (hash? arg1)
        (values arg1 (or kw-ledger arg2))
        (values (if (hash? arg2) arg2 (hash)) (or kw-ledger arg1))))
  (define frame (hash-ref obs 'frame 0))
  (define base-x (hash-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X))
  (define base-y (hash-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y))
  (define nat-x (hash-ref obs 'natural-x SC2-DEFAULT-NATURAL-X))
  (define nat-y (hash-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define effects (or kw-effects (hash-ref obs 'effects '())))
  (define splash-tactical-disp
    (or kw-disp (hash-ref obs 'bo-tactical-disposition (hash-ref obs 'tactical-disposition #f))))
  (define splash-lanchester-ratio
    (or kw-lr (hash-ref obs 'lanchester-ratio #f)))
  (define splash-enemy-upgrades
    (or kw-enemy-upgs
        (hash-ref obs 'enemy-upgrades
                  (hash-ref obs 'observed-enemy-upgrades
                            (hash-ref obs 'mirror-observed-upgrades '())))))
  (define mirror-tact-target (hash-ref obs 'mirror-tactical-target #f))
  (define mirror-pred-unit (hash-ref obs 'mirror-predicted-enemy-unit #f))
  (define mirror-base-fx (fast->fl base-x))
  (define mirror-base-fy (fast->fl base-y))
  (define mirror-nat-fx (fast->fl nat-x))
  (define mirror-nat-fy (fast->fl nat-y))
  (define has-splash-effect?
    (and (pair? effects)
         (for/or ([eff (in-list effects)])
           (and (hash? eff)
                (or (memq (or (hash-ref eff 'type #f)
                              (hash-ref eff 'spell #f)
                              (hash-ref eff 'kind #f)
                              (hash-ref eff 'ability #f)
                              (hash-ref eff 'name 'none))
                          '(lurker-spines lurker-spine lurker-mp-spines
                            purification-nova purification-nova-explosion
                            disruptor-nova disruptor-phased
                            corrosive-bile psionic-storm psi-storm
                            nuke nuke-persistent))
                    (memq (hash-ref eff 'effect-id 0) '(7 11)))))))
  (define our-z (hash-ref obs 'our-terrain-z 10))
  (define enemy-z (hash-ref obs 'enemy-terrain-z 10))
  (define arena-supply-used
    (let ([raw (hash-ref obs 'supply-used 0)])
      (if (exact-integer? raw) raw 0)))

  (define brain-cache (hash-ref! ROLLOUT-CACHE-BY-STATE brain make-hasheqv))
  (define ally-id-cache (hash-ref! brain-cache '__ally-id-cache (lambda () (vector #f #f 0 0 #f))))
  (define enemy-id-cache (hash-ref! brain-cache '__enemy-id-cache (lambda () (vector #f #f 0 0 #f))))
  (define (ensure-unit-id-table! tbl-key id-cache units)
    (define tbl (hash-ref! brain-cache tbl-key make-hasheqv))
    (cond
      [(and (eq? units (vector-ref id-cache 0))
            (vector-ref id-cache 1))
       (values tbl (vector-ref id-cache 2) (vector-ref id-cache 3) (vector-ref id-cache 4))]
      [else
       (define g (unsafe-fx+ (vector-ref id-cache 2) 1))
       (define-values (cnt dup? all-imm?) (refresh-unit-id-table! tbl units g))
       (vector-set! id-cache 0 units)
       (vector-set! id-cache 1 all-imm?)
       (vector-set! id-cache 2 g)
       (vector-set! id-cache 3 cnt)
       (vector-set! id-cache 4 dup?)
       (values tbl g cnt dup?)]))
  (define ally-id-gen (vector-ref ally-id-cache 2))
  (define enemy-id-gen (vector-ref enemy-id-cache 2))
  (define len-au (length ally-units))
  (define len-eu (length enemy-units))
  (define len-eb (length enemy-bldgs))
  (define clen (length chokes))
  (define ally-by-id #f)
  (define enemy-by-id #f)
  (define cc (hash-ref brain-cache '__cluster-cache #f))
  (define su-last-ht (hash-ref! brain-cache '__su-last-ht make-hasheqv))
  (define reinf-a-seen (hash-ref! brain-cache '__reinf-a-seen make-hasheqv))
  (define reinf-e-seen (hash-ref! brain-cache '__reinf-e-seen make-hasheqv))
  (define arenas-from-cache? #f)
  (define arenas
    (or (and cc
             (pair? (vector-ref cc 7))
             (> frame (vector-ref cc 0))
             (< frame (vector-ref cc 1))
             (= len-au (vector-ref cc 2))
             (= len-eu (vector-ref cc 3))
             (= len-eb (vector-ref cc 4))
             (equal? our-z (vector-ref cc 5))
             (equal? enemy-z (vector-ref cc 6))
             (= clen (vector-ref cc 8))
             (let-values ([(abid ag acnt adup?) (ensure-unit-id-table! '__ally-by-id ally-id-cache ally-units)])
               (set! ally-by-id abid)
               (set! ally-id-gen ag)
               (and (not adup?)
                    (= acnt len-au)
                    (let-values ([(ebid eg ecnt edup?) (ensure-unit-id-table! '__enemy-by-id enemy-id-cache enemy-units)])
                      (set! enemy-by-id ebid)
                      (set! enemy-id-gen eg)
                      (and (not edup?)
                           (= ecnt len-eu)
                           (refresh-cached-arenas! (vector-ref cc 7) abid ebid ag eg su-last-ht reinf-a-seen reinf-e-seen)
                           (begin
                             (set! arenas-from-cache? #t)
                             (vector-set! cc 0 frame)
                             (vector-ref cc 7)))))))
        (let ([fresh (cluster-tactical-arenas ally-units enemy-units enemy-bldgs
                                              #:chokes chokes #:our-z our-z #:enemy-z enemy-z)])
          (hash-clear! su-last-ht)
          (when (and (pair? fresh) (or (>= len-au 16) (>= len-eu 16)))
            (let* ([raw-exp (+ frame 120)]
                   [exp-f (if (= (modulo raw-exp 16) 8) (+ raw-exp 4) raw-exp)])
              (hash-set! brain-cache '__cluster-cache
                         (vector frame exp-f len-au len-eu len-eb our-z enemy-z fresh clen))))
          fresh)))
  (unless ally-by-id
    (let-values ([(abid ag _acnt _adup?) (ensure-unit-id-table! '__ally-by-id ally-id-cache ally-units)])
      (set! ally-by-id abid)
      (set! ally-id-gen ag)))
  (set-tactical-mirror-brain-active-arenas! brain arenas)
  (cond
    [(null? arenas)
     (set-tactical-mirror-brain-last-decisions! brain '())
     (values '() (mutable-seteqv) '())]
    [else
     (define ev-pool-box (hash-ref! brain-cache '__ev-pool-box (lambda () (box (make-vector 256 #f)))))
     (define ev-pool (unbox ev-pool-box))
     (when (> (vector-length ev-pool) 1024)
       (set! ev-pool (make-vector 256 #f))
       (set-box! ev-pool-box ev-pool))
     (define ev-idx 0)
     (define actions '())
     (define committed-tags (mutable-seteqv))
     (define decisions '())
     (define (emit! act) (set! actions (cons act actions)))
     (define has-banshee-cloak?
       (let ([ru (hash-ref obs 'researched-upgrades ARENA-MISSING)])
         (if (eq? ru ARENA-MISSING)
             #t
             (and (memq 'banshee-cloak ru) #t))))

     (define states (tactical-mirror-brain-arena-states brain))
     (for ([arena (in-list arenas)]
           [a-idx (in-naturals)])
       (define aid (tactical-arena-id arena))
       (define acx (tactical-arena-center-x arena))
       (define acy (tactical-arena-center-y arena))
       (define a-cnt (length (tactical-arena-ally-units arena)))
       (define e-cnt (length (tactical-arena-enemy-units arena)))
       (define ra-cnt (length (tactical-arena-reinforcing-allies arena)))
       (define re-cnt (length (tactical-arena-reinforcing-enemies arena)))
       (define sig-ew (null? (tactical-arena-enemy-workers arena)))
       (define prev-st (hash-ref states aid #f))
       (define cached-entry (hash-ref brain-cache aid #f))
       (define reuse-locked?
         (and prev-st
              cached-entry
              (or (< frame (arena-commitment-state-lock-until-frame prev-st))
                  (< frame (vector-ref cached-entry 4)))
              (>= frame (arena-commitment-state-committed-since-frame prev-st))
              (let* ([ccx (vector-ref cached-entry 1)]
                     [ccy (vector-ref cached-entry 2)]
                     [dx (- (fast->fl acx) (fast->fl ccx))]
                     [dy (- (fast->fl acy) (fast->fl ccy))])
                (and (<= (abs (- a-cnt (vector-ref cached-entry 5))) 2)
                     (<= (abs (- e-cnt (vector-ref cached-entry 6))) 2)
                     (<= (abs (- ra-cnt (vector-ref cached-entry 7))) 2)
                     (<= (abs (- re-cnt (vector-ref cached-entry 8))) 2)
                     (eq? sig-ew (vector-ref cached-entry 9))
                     (<= (+ (* dx dx) (* dy dy)) 9.0)))))
       (define combat-suppress-arena?
         (and (not kw-combat-should-engage?)
              (not kw-defending-home?)))
       (define-values (raw-best pred-enemy best-val cur-val rollout raw-committed-act locked?)
         (if reuse-locked?
             (let ([cr (vector-ref cached-entry 3)])
               (values (vector-ref cr 0) (vector-ref cr 1) (vector-ref cr 2)
                       (vector-ref cr 3) (vector-ref cr 4)
                       (arena-commitment-state-committed-action prev-st) #t))
             (begin
               (when arenas-from-cache?
                 (unless enemy-by-id
                   (let-values ([(ebid eg _ecnt _edup?) (ensure-unit-id-table! '__enemy-by-id enemy-id-cache enemy-units)])
                     (set! enemy-by-id ebid)
                     (set! enemy-id-gen eg)))
                 (refresh-arena-reinforcing! arena ally-by-id enemy-by-id ally-id-gen enemy-id-gen))
               (let-values ([(rb pe bv cv ro)
                             (evaluate-arena-minimax-and-regret! brain arena frame #:strategic-opp-depth opp-d)])
                 (define-values (ca lk?)
                   (resolve-committed-micro-action! brain arena frame rb pe bv cv))
                 (let* ([base-exp (+ frame (if cached-entry 28 (+ 20 (* 4 (modulo a-idx 4)))))]
                        [next-exp (if (= (modulo base-exp 16) 8) (+ base-exp 4) base-exp)])
                   (hash-set! brain-cache
                              aid
                              (vector #f acx acy (vector rb pe bv cv ro) next-exp
                                      a-cnt e-cnt ra-cnt re-cnt sig-ew)))
                 (values rb pe bv cv ro ca lk?)))))
       ;; W18-P0-1-rt (`#8/#34/#35/#36` <3:30 Zergling/melee rush inside main/natural):
       ;; When >= 4 melee rushers are inside our home base before 4:00 (< 5400f), STAND AND FIGHT
       ;; (`CommitFocusFire`) — never backward-kite (`StutterKiteBack`/`DisengageRetreat`) across the mineral line!
       (define home-melee-rush-stand?
         (and kw-defending-home?
              (< frame 5400)
              (>= (for/sum ([e (in-list (tactical-arena-enemy-units arena))])
                    (if (and (fl> (tactical-sim-unit-ground-dps e) 0.0)
                             (fl<= (tactical-sim-unit-ground-range e) 1.5))
                        1
                        0))
                  4)))
       (define committed-act
         (cond
           [combat-suppress-arena? 'DisengageRetreat]
           ;; W18-P0-1-rt: Early melee rush inside main/natural -> STAND AND FIGHT (0% OBRet / 0% kite)!
           [(and home-melee-rush-stand?
                 (memq raw-committed-act '(DisengageRetreat StutterKiteBack)))
            'CommitFocusFire]
           ;; W7-P0-2-rt: Never retreat inside our own base when enemies are within 14t of TownHall!
           [(and kw-defending-home? (eq? raw-committed-act 'DisengageRetreat))
            'CommitFocusFire]
           [else raw-committed-act]))
       (define d1-val (tactical-horizon-eval-net-value (mirrored-rollout-result-d1-eval rollout)))
       (define d2-val (tactical-horizon-eval-net-value (mirrored-rollout-result-d2-eval rollout)))
       (define d3-val (tactical-horizon-eval-net-value (mirrored-rollout-result-d3-eval rollout)))

       (set! decisions
             (cons (hash 'arena-id (tactical-arena-id arena)
                         'committed-action committed-act
                         'predicted-enemy-action pred-enemy
                         'd1-value d1-val
                         'd2-value d2-val
                         'd3-value d3-val
                         'combined-value (mirrored-rollout-result-combined-value rollout)
                         'locked? locked?)
                   decisions))

       ;; Translate winning arena micro action into per-unit commands with cooldown & order-equivalence gating
       (define arena-workers (tactical-arena-enemy-workers arena))
       (define arena-ally-units (tactical-arena-ally-units arena))
       (define need-spatial-targets? (not (eq? committed-act 'DisengageRetreat)))
       (define-values (arena-has-stealth? any-ally-ground-dps? any-ally-air-dps?)
         (if need-spatial-targets?
             (let loop ([rem arena-ally-units] [st? #f] [gd? #f] [ad? #f])
               (if (null? rem)
                   (values st? gd? ad?)
                   (let ([a (car rem)])
                     (loop (cdr rem)
                           (or st?
                               (tactical-sim-unit-cloaked? a)
                               (and (hash-ref STEALTH-SYM-SET (tactical-sim-unit-type a) #f) #t))
                           (or gd? (fl> (tactical-sim-unit-ground-dps a) 0.0))
                           (or ad? (fl> (tactical-sim-unit-air-dps a) 0.0))))))
             (values #f #f #f)))
       (define g-plan-key (+ 1000000000 (* aid 4) 1))
       (define a-plan-key (+ 1000000000 (* aid 4) 2))
       (define cached-g (and need-spatial-targets? any-ally-ground-dps? (hash-ref brain-cache g-plan-key #f)))
       (define cached-a (and need-spatial-targets? any-ally-air-dps? (hash-ref brain-cache a-plan-key #f)))
       (define (resolve-enemy-splash-hash e etype)
         (unless enemy-by-id
           (let-values ([(ebid eg _ecnt _edup?) (ensure-unit-id-table! '__enemy-by-id enemy-id-cache enemy-units)])
             (set! enemy-by-id ebid)
             (set! enemy-id-gen eg)))
         (or (unit-id-table-lookup enemy-by-id enemy-id-gen (tactical-sim-unit-id e))
             (hash 'id (tactical-sim-unit-id e)
                   'type etype
                   'x (tactical-sim-unit-x e)
                   'y (tactical-sim-unit-y e)
                   'hp (tactical-sim-unit-hp e)
                   'shield (tactical-sim-unit-shield e)
                   'burrowed? (not (not (memq etype '(lurker-burrowed lurker-mp-burrowed))))
                   'sieged (eq? etype 'siege-tank-sieged))))
       (define arena-enemy-sims (tactical-arena-enemy-units arena))
       (define arena-ally-has-det? (or kw-has-detector? (tactical-arena-ally-has-detection? arena)))
       ;; W11-P0-4-rt (`w11-tac-2`): Never unit-target ATTACK (23) undetected `cloak=1` enemies
       ;; (SC2 strictly rejects them!). Still target detected `cloak=2` & visible `cloak=3` enemies.
       (define (enemy-sim-untargetable-cloak? e)
         (and (tactical-sim-unit-cloaked? e)
              (let ([uh (begin
                          (unless enemy-by-id
                            (let-values ([(ebid eg _ecnt _edup?)
                                          (ensure-unit-id-table! '__enemy-by-id enemy-id-cache enemy-units)])
                              (set! enemy-by-id ebid)
                              (set! enemy-id-gen eg)))
                          (unit-id-table-lookup enemy-by-id enemy-id-gen (tactical-sim-unit-id e)))])
                (if uh
                    (let ([cval (hash-ref uh 'cloak #f)])
                      (cond
                        [(or (eqv? cval 1) (eq? cval 'cloaked)) #t]
                        [(or (eqv? cval 2) (eqv? cval 3) (memq cval '(cloaked-detected not-cloaked))) #f]
                        [else (not arena-ally-has-det?)]))
                    (not arena-ally-has-det?)))))
       (define-values (first-arena-enemy enemy-has-aa? ground-vecs air-vecs arena-tank-lurkers-rev untargetable-cloaked-rev)
         (let loop ([rem arena-enemy-sims]
                    [first-e #f]
                    [aa? #f]
                    [gvecs '()]
                    [avecs '()]
                    [tlrev '()]
                    [uclkrev '()])
           (if (null? rem)
               (values first-e aa? (reverse gvecs) (reverse avecs) tlrev uclkrev)
               (let* ([e (car rem)]
                      [etype (tactical-sim-unit-type e)])
                 (cond
                   [(eq? etype 'disruptor-phased)
                    (loop (cdr rem)
                          first-e
                          aa?
                          gvecs
                          avecs
                          (cons (resolve-enemy-splash-hash e etype) tlrev)
                          uclkrev)]
                   [(enemy-sim-untargetable-cloak? e)
                    (loop (cdr rem)
                          first-e
                          (or aa? (fl> (tactical-sim-unit-air-dps e) 0.0))
                          gvecs
                          avecs
                          tlrev
                          (cons e uclkrev))]
                   [else
                    (let* ([ed-air (tactical-sim-unit-air-dps e)]
                           [flying? (tactical-sim-unit-flying? e)]
                           [colossus? (eq? etype 'colossus)]
                           [ev
                            (if need-spatial-targets?
                                (let* ([tact-mult
                                        (if (or mirror-tact-target mirror-pred-unit)
                                            (let ([zone-m
                                                   (cond
                                                     [(eq? mirror-tact-target 'main-mineral-line-drop-or-air)
                                                      (let ([mdx (fl- (tactical-sim-unit-x e) mirror-base-fx)]
                                                            [mdy (fl- (tactical-sim-unit-y e) mirror-base-fy)])
                                                        (if (fl<= (fl+ (fl* mdx mdx) (fl* mdy mdy)) 256.0)
                                                            (if (or flying?
                                                                    (memq etype '(medivac warp-prism warp-prism-phasing overlord-transport
                                                                                  liberator banshee oracle mutalisk dark-templar)))
                                                                1.45
                                                                1.25)
                                                            1.0))]
                                                     [(eq? mirror-tact-target 'natural-choke-timing-push)
                                                      (let ([ndx (fl- (tactical-sim-unit-x e) mirror-nat-fx)]
                                                            [ndy (fl- (tactical-sim-unit-y e) mirror-nat-fy)])
                                                        (if (fl<= (fl+ (fl* ndx ndx) (fl* ndy ndy)) 256.0)
                                                            1.25
                                                            1.0))]
                                                     [(eq? mirror-tact-target 'hidden-third-base-expansion)
                                                      (if (memq etype '(drone probe scv)) 1.35 1.10)]
                                                     [else 1.0])])
                                              (if (and mirror-pred-unit (eq? etype mirror-pred-unit))
                                                  (fl* zone-m 1.15)
                                                  zone-m))
                                            1.0)]
                                       [pconst (fl* (fast-enemy-priority-const etype arena-has-stealth? e) tact-mult)]
                                       [ehp (flmax 1e-6 (fl+ (tactical-sim-unit-hp e) (tactical-sim-unit-shield e)))]
                                       [tidx (vector-ref (fast-unit-stat-vec etype) 19)]
                                       [eflags (tactical-sim-unit-attr-flags e)]
                                       [sbits (unsafe-fxior
                                               (unsafe-fxior
                                                (if (fl> (tactical-sim-unit-shield e) 0.0) 1 0)
                                                (if (not (unsafe-fx= (unsafe-fxand eflags 128) 0)) 2 0))
                                               (unsafe-fxior
                                                (if (not (unsafe-fx= (unsafe-fxand eflags 256) 0)) 4 0)
                                                (if (not (unsafe-fx= (unsafe-fxand eflags 64) 0)) 8 0)))]
                                       [slot (begin
                                               (when (>= ev-idx (vector-length ev-pool))
                                                 (let* ([old-len (vector-length ev-pool)]
                                                        [new-v (make-vector (max 512 (* 2 old-len)) #f)])
                                                   (vector-copy! new-v 0 ev-pool)
                                                   (set! ev-pool new-v)
                                                   (set-box! ev-pool-box new-v)))
                                               (vector-ref ev-pool ev-idx))])
                                  (if slot
                                      (begin
                                        (vector-set! slot 0 e)
                                        (vector-set! slot 1 flying?)
                                        (vector-set! slot 2 (tactical-sim-unit-x e))
                                        (vector-set! slot 3 (tactical-sim-unit-y e))
                                        (vector-set! slot 4 (fl/ pconst ehp))
                                        (vector-set! slot 5 tidx)
                                        (vector-set! slot 6 sbits)
                                        (set! ev-idx (+ ev-idx 1))
                                        slot)
                                      (let ([v (vector e
                                                       flying?
                                                       (tactical-sim-unit-x e)
                                                       (tactical-sim-unit-y e)
                                                       (fl/ pconst ehp)
                                                       tidx
                                                       sbits)])
                                        (vector-set! ev-pool ev-idx v)
                                        (set! ev-idx (+ ev-idx 1))
                                        v)))
                                #f)]
                           [raw-e
                            (and (memq etype '(siege-tank-sieged
                                               lurker-burrowed lurker-mp-burrowed
                                               siege-tank lurker lurker-mp
                                               colossus disruptor high-templar))
                                 (resolve-enemy-splash-hash e etype))]
                           [tlrev2
                            (if (and raw-e
                                     (or (memq etype '(siege-tank-sieged lurker-burrowed lurker-mp-burrowed colossus disruptor high-templar))
                                         (and (eq? etype 'siege-tank)
                                              (or (hash-ref raw-e 'sieged #f)
                                                  (hash-ref raw-e 'is-sieged? #f)))
                                         (and (memq etype '(lurker lurker-mp))
                                              (or (hash-ref raw-e 'burrowed #f)
                                                  (hash-ref raw-e 'burrowed? #f)
                                                  (hash-ref raw-e 'is-burrowed? #f)
                                                  (hash-ref raw-e 'burrow-intent? #f)
                                                  (hash-ref raw-e 'burrow-intent #f)
                                                  (hash-ref raw-e 'burrowing? #f)
                                                  (hash-ref raw-e 'is-burrowing? #f)
                                                  (hash-ref raw-e 'preparing-burrow? #f)))))
                                (cons raw-e tlrev)
                                tlrev)])
                      (loop (cdr rem)
                            (or first-e e)
                            (or aa? (fl> ed-air 0.0))
                            (if (and ev (not flying?)) (cons ev gvecs) gvecs)
                            (if (and ev (or flying? colossus?)) (cons ev avecs) avecs)
                            tlrev2
                            uclkrev))])))))
       (define splash-hazard-present? (or (pair? arena-tank-lurkers-rev) has-splash-effect?))
       (define arena-commit-splash?
         (and splash-hazard-present?
              (not (eq? committed-act 'DisengageRetreat))
              (arena-direct-should-commit-through-splash?
               arena-ally-units
               arena-enemy-sims
               arena-tank-lurkers-rev
               splash-tactical-disp
               splash-lanchester-ratio
               (or kw-has-detector? (tactical-arena-ally-has-detection? arena)))))
       (define ally-meta-by-id (and splash-hazard-present? (make-hasheqv)))
       (define arena-splash-move-by-id
         (and splash-hazard-present?
              (let ([filtered-allies-rev
                     (for/fold ([acc '()])
                               ([su (in-list arena-ally-units)])
                       (let* ([uid (tactical-sim-unit-id su)]
                              [utype (tactical-sim-unit-type su)]
                              [u-hash (or (unit-id-table-lookup ally-by-id ally-id-gen uid)
                                          (hash 'id uid 'type utype
                                                'x (tactical-sim-unit-x su)
                                                'y (tactical-sim-unit-y su)
                                                'hp (tactical-sim-unit-hp su)
                                                'max-hp (tactical-sim-unit-max-hp su)
                                                'weapon-cooldown (tactical-sim-unit-weapon-cooldown su)))]
                              [u-ab-id (let ([raw-id (hash-ref u-hash 'order-ability-id 0)])
                                         (if (exact-integer? raw-id) raw-id 0))]
                              [ch-locked? (or (and (> u-ab-id 0)
                                                   (memq (fast-order-protection-class u-ab-id) '(channel morph cast-walk)))
                                              (and (hash-ref u-hash 'snipe-channel-locked? #f) #t)
                                              (eq? utype 'medivac)
                                              (eq? utype 'warp-prism)
                                              (eq? utype 'warp-prism-phasing)
                                              (eq? utype 'overlord-transport))]
                              [in-swing? (and ledger (order-ledger-unit-in-attack-swing? ledger u-hash frame))])
                         (hash-set! ally-meta-by-id uid (vector u-hash in-swing? ch-locked?))
                         (if (or (tactical-sim-unit-flying? su) in-swing? ch-locked?)
                             acc
                             (cons u-hash acc))))])
                (and (pair? filtered-allies-rev)
                     (let ([cmds (plan-avoid-siege-tank-and-lurker-splash-zones
                                  (reverse filtered-allies-rev)
                                  (reverse arena-tank-lurkers-rev)
                                  #:effects effects
                                  #:home-x base-x
                                  #:home-y base-y
                                  #:commit-through-splash? arena-commit-splash?
                                  #:enemy-upgrades splash-enemy-upgrades
                                  #:tactical-disposition splash-tactical-disp
                                  #:lanchester-ratio (or splash-lanchester-ratio 1.0))])
                       (and (pair? cmds)
                            (let ([ht (make-hasheqv)])
                              (for ([cmd (in-list cmds)])
                                (define uid (hash-ref cmd 'unit-id #f))
                                (define tx (hash-ref cmd 'target-x #f))
                                (define ty (hash-ref cmd 'target-y #f))
                                (when (and uid (real? tx) (real? ty))
                                  (hash-set! ht uid (vector tx ty (hash-ref cmd 'role #f)))))
                              ht)))))))
       (define (resolve-cached-spatial-plan pkey cached vecs)
         (cond
           [(null? vecs) #f]
           [(and cached
                 (< (- frame (vector-ref cached 0)) 20)
                 (>= frame (vector-ref cached 0))
                 (eq? arena-has-stealth? (vector-ref cached 1))
                 (>= (vector-length cached) 6)
                 (eq? mirror-tact-target (vector-ref cached 4))
                 (eq? mirror-pred-unit (vector-ref cached 5))
                 (let ([snap (vector-ref cached 2)])
                   (and (= (length vecs) (vector-length snap))
                        (let vloop ([rem vecs] [i 0])
                          (cond
                            [(null? rem) #t]
                            [else
                             (define ev (car rem))
                             (define sp (vector-ref snap i))
                             (and (eq? (vector-ref ev 0) (vector-ref sp 0))
                                  (fx= (vector-ref ev 6) (vector-ref sp 4))
                                  (fl<= (flabs (fl- (vector-ref ev 2) (vector-ref sp 1))) 0.65)
                                  (fl<= (flabs (fl- (vector-ref ev 3) (vector-ref sp 2))) 0.65)
                                  (fl<= (flabs (fl- (vector-ref ev 4) (vector-ref sp 3)))
                                        (fl* 0.25 (vector-ref sp 3)))
                                  (vloop (cdr rem) (+ i 1)))])))))
            (vector-ref cached 3)]
           [else
            (define plan (build-target-spatial-plan vecs 0.75))
            (when (and plan (car plan))
              (define snap
                (for/vector ([ev (in-list vecs)])
                  (vector-immutable (vector-ref ev 0) (vector-ref ev 2) (vector-ref ev 3) (vector-ref ev 4) (vector-ref ev 6))))
              (hash-set! brain-cache pkey (vector frame arena-has-stealth? snap plan mirror-tact-target mirror-pred-unit)))
            plan]))
       (define ground-plan (and need-spatial-targets? any-ally-ground-dps? (pair? ground-vecs)
                                (resolve-cached-spatial-plan g-plan-key cached-g ground-vecs)))
       (define air-plan (and need-spatial-targets? any-ally-air-dps? (pair? air-vecs)
                             (resolve-cached-spatial-plan a-plan-key cached-a air-vecs)))
       ;; W7-TAC-2: Precompute frontline allies committing to fire under DisengageRetreat so
       ;; trailing ranged allies (e.g. Marines 1t behind Marauders) extend fire radius by +2.0t
       ;; and support them instead of splitting off in pure MOVE!
       (define (nearest-hittable-enemy-for su)
         (define su-x (tactical-sim-unit-x su))
         (define su-y (tactical-sim-unit-y su))
         (define su-type (tactical-sim-unit-type su))
         (define su-r (tactical-sim-unit-radius su))
         (for/fold ([best-e #f] [best-d2 +inf.0] #:result best-e)
                   ([e (in-list arena-enemy-sims)])
           (if (enemy-sim-untargetable-cloak? e)
               (values best-e best-d2)
               (let ([wr-e
                      (if (and (eq? (tactical-sim-unit-type e) 'colossus)
                               (fl> (tactical-sim-unit-air-range su) 0.0)
                               (fl<= (tactical-sim-unit-ground-range su) 0.0))
                          (tactical-sim-unit-air-range su)
                          (sim-unit-weapon-range-vs su e))])
                 (if (fl<= wr-e 0.0)
                     (values best-e best-d2)
                     (let* ([dx (fl- su-x (tactical-sim-unit-x e))]
                            [dy (fl- su-y (tactical-sim-unit-y e))]
                            [d2 (fl+ (fl* dx dx) (fl* dy dy))])
                       (if (and (fl< d2 best-d2)
                                (not (sieged-tank-in-min-range-deadzone? su-type su-r e d2)))
                           (values e d2)
                           (values best-e best-d2))))))))
       ;; W8-TAC-3: Never let fragile High Templars suicide-`attack-unit` directly into an enemy
       ;; army when non-HT combat allies exist in the arena (matches Disruptor protection, fixes `p05`).
       (define arena-has-non-ht-ally?
         (ormap (lambda (a)
                  (not (memq (tactical-sim-unit-type a) '(high-templar disruptor disruptor-phased))))
                arena-ally-units))
       (define disengage-committed-pts
         (if (and (eq? committed-act 'DisengageRetreat) (pair? arena-enemy-sims))
             (for/fold ([pts '()]) ([au (in-list arena-ally-units)])
               (define aut (tactical-sim-unit-type au))
               (if (or (eq? aut 'disruptor)
                       (eq? aut 'disruptor-phased)
                       (and (eq? aut 'high-templar) arena-has-non-ht-ally?))
                   pts
                   (let ([ne (nearest-hittable-enemy-for au)])
                     (if (and ne
                              (not (memq (tactical-sim-unit-type ne)
                                         '(locust locust-mp locustmp locust-flying))))
                         (let* ([ax (tactical-sim-unit-x au)]
                                [ay (tactical-sim-unit-y au)]
                                [wr-a (if (and (eq? (tactical-sim-unit-type ne) 'colossus)
                                               (fl> (tactical-sim-unit-air-range au) 0.0)
                                               (fl<= (tactical-sim-unit-ground-range au) 0.0))
                                          (tactical-sim-unit-air-range au)
                                          (sim-unit-weapon-range-vs au ne))]
                                [d-a (fast-dist2d ax ay (tactical-sim-unit-x ne) (tactical-sim-unit-y ne))]
                                [wp-a (flmax 0.16 (exact->inexact (tactical-sim-unit-weapon-period au)))]
                                [kmin-a (flmax 0.22 (fl* 0.38 wp-a))]
                                [wcd-a (exact->inexact (tactical-sim-unit-weapon-cooldown au))]
                                [commits?
                                 (and (fl> wr-a 0.0)
                                      (or (and (fl<= wr-a 1.5) (fl<= d-a 8.5))
                                          (and (fl> wr-a 1.5)
                                               (fl<= d-a (fl+ wr-a 2.5))
                                               (fl< wcd-a kmin-a))))])
                           (if commits? (cons (cons ax ay) pts) pts))
                         pts))))
             '()))
       ;; W18-P0-3-rt (`Siege0DPS` `#17/#18/#25/#26/#31/#32/#33` — SmoothBrain Tanks, Thssprtssbt Colossi/Tempests):
       ;; Precompute enemy long-range siege/colossus/capital shellers in this arena once so squads
       ;; trapped inside their firing arc commit & shoot instead of 0-DPS backward kiting!
       (define arena-ally-cnt (length arena-ally-units))
       (define arena-enemy-siege-shellers
         (for/list ([e (in-list arena-enemy-sims)]
                    #:when (memq (tactical-sim-unit-type e)
                                 '(siege-tank-sieged colossus tempest carrier brood-lord broodlord battlecruiser)))
           (define et (tactical-sim-unit-type e))
           (define r2
             (cond
               [(eq? et 'siege-tank-sieged) 196.0] ;; 14.0t active shell zone
               [(eq? et 'colossus) 132.25]         ;; 11.5t ETL Colossus firing/approach band
               [else 342.25]))                     ;; 18.5t Tempest/Capital siege band
           (vector et (tactical-sim-unit-x e) (tactical-sim-unit-y e) r2)))
       (for ([su (in-list arena-ally-units)])
         (define uid (tactical-sim-unit-id su))
         (define utype (tactical-sim-unit-type su))
         (define ux (tactical-sim-unit-x su))
         (define uy (tactical-sim-unit-y su))
         (define w-cd (tactical-sim-unit-weapon-cooldown su))
         (set-add! committed-tags uid)

         ;; Find live unit hash for order-equivalence and backswing lock check
         (define cached-meta (and ally-meta-by-id (hash-ref ally-meta-by-id uid #f)))
         (define-values (u-hash in-swing? channel-or-morph-locked?)
           (if cached-meta
               (values (vector-ref cached-meta 0)
                       (vector-ref cached-meta 1)
                       (vector-ref cached-meta 2))
               (let* ([uh (or (unit-id-table-lookup ally-by-id ally-id-gen uid)
                              (hash 'id uid 'type utype 'x ux 'y uy 'weapon-cooldown w-cd))]
                      [isw? (and ledger (order-ledger-unit-in-attack-swing? ledger uh frame))]
                      [u-ab-id (let ([raw-id (hash-ref uh 'order-ability-id 0)])
                                 (if (exact-integer? raw-id) raw-id 0))]
                      [lock? (or (and (> u-ab-id 0)
                                      (memq (fast-order-protection-class u-ab-id) '(channel morph cast-walk)))
                                 (and (hash-ref uh 'snipe-channel-locked? #f) #t)
                                 (eq? utype 'medivac)
                                 (eq? utype 'warp-prism)
                                 (eq? utype 'warp-prism-phasing)
                                 (eq? utype 'overlord-transport))])
                 (values uh isw? lock?))))

         ;; Trigger Banshee cloak when researched (or in synthetic test without researched-upgrades key),
         ;; facing anti-air without detection, and energy >= 25
         (when (and (eq? utype 'banshee)
                    (not channel-or-morph-locked?)
                    has-banshee-cloak?
                    (not (tactical-sim-unit-cloaked? su))
                    (>= (tactical-sim-unit-energy su) SC2-BANSHEE-CLOAK-MIN-ENERGY)
                    (or (eq? committed-act 'CloakHarassWorkers)
                        (and enemy-has-aa? (not (tactical-arena-enemy-has-detection? arena)))))
           (emit! (list 'cast-spell uid 'cloak-banshee)))

         (define splash-move-pt (and arena-splash-move-by-id (hash-ref arena-splash-move-by-id uid #f)))
         (define spx (and splash-move-pt (vector-ref splash-move-pt 0)))
         (define spy (and splash-move-pt (vector-ref splash-move-pt 1)))
         (define sprole (and splash-move-pt (vector-ref splash-move-pt 2)))
         (define disruptor? (or (eq? utype 'disruptor) (eq? utype 'disruptor-phased)))
         (define weaponless-oracle?
           (and (eq? utype 'oracle)
                (fl<= (tactical-sim-unit-ground-dps su) 0.0)
                (fl<= (tactical-sim-unit-air-dps su) 0.0)))
         (define fragile-caster-no-atk?
           (or disruptor?
               weaponless-oracle?
               (and (eq? utype 'high-templar) arena-has-non-ht-ally?)))
         (define active-spell-dodge?
           (and splash-move-pt
                (or (memq sprole '(dodge-active-disruptor-nova avoid-aoe-splash-effect))
                    (and (not arena-commit-splash?)
                         (eq? sprole 'avoid-lurker-linear-spine-splash)))))
         (define target-su
           (and (not in-swing?)
                (not channel-or-morph-locked?)
                (not active-spell-dodge?)
                (cond
                  [(and (eq? committed-act 'CloakHarassWorkers)
                        (not (null? arena-workers))
                        (> (tactical-sim-unit-ground-dps su) 0.0))
                   (define best-w
                     (argmin (lambda (w0)
                               (define w (if enemy-by-id (or (unit-id-table-lookup enemy-by-id enemy-id-gen (hash-ref w0 'id -1)) w0) w0))
                               (+ (or (hash-ref w 'hull-hp #f) (hash-ref w 'hp 40))
                                  (or (hash-ref w 'shield #f) (hash-ref w 'shields 0))))
                             arena-workers))
                   (unit-hash->tactical-sim-unit
                    (if enemy-by-id (or (unit-id-table-lookup enemy-by-id enemy-id-gen (hash-ref best-w 'id -1)) best-w) best-w)
                    'enemy)]
                  [else
                   (define best-hittable
                     (let ([gdps (tactical-sim-unit-ground-dps su)]
                           [adps (tactical-sim-unit-air-dps su)])
                       (define-values (b1 sc1 sc21)
                         (if (and ground-plan (> gdps 0.0))
                             (pick-best-target-from-plan ground-plan ux uy #f -inf.0 0.0 su)
                             (values #f -inf.0 0.0)))
                       (define-values (b2 _sc2 _sc22)
                         (if (and air-plan (> adps 0.0))
                             (pick-best-target-from-plan air-plan ux uy b1 sc1 sc21 su)
                             (values b1 sc1 sc21)))
                       b2))
                   (cond
                     [best-hittable best-hittable]
                     [(and (eq? committed-act 'DisengageRetreat) first-arena-enemy)
                      (or (nearest-hittable-enemy-for su)
                          (and (not (eq? utype 'siege-tank-sieged)) first-arena-enemy))]
                     [else #f])])))
         ;; W18-P0-3-rt: Check whether this unit is already inside active Sieged Tank (<=14t),
         ;; Colossus (<=11.5t), or Tempest/Capital (<=18.5t) firing range!
         (define-values (unit-in-tank-or-colossus-fire? unit-in-any-siege-fire?)
           (if (null? arena-enemy-siege-shellers)
               (values #f #f)
               (for/fold ([tc? #f] [any? #f]) ([sv (in-list arena-enemy-siege-shellers)])
                 (define dx (fl- ux (vector-ref sv 1)))
                 (define dy (fl- uy (vector-ref sv 2)))
                 (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (vector-ref sv 3))
                     (let ([st (vector-ref sv 0)])
                       (values (or tc? (eq? st 'siege-tank-sieged) (eq? st 'colossus)) #t))
                     (values tc? any?)))))
         (define trapped-in-siege-zone?
           (and unit-in-tank-or-colossus-fire?
                (or kw-defending-home? (>= arena-ally-cnt 4))))
         ;; W11-P0-4-rt / W18-P0-3-rt (`w11-tac-1` / `novel-137` / `w18-tac-3` / `Siege0DPS`):
         ;; Allow ready-weapon units to fire before stepping in splash avoidance AND commit-close
         ;; when already trapped inside active Sieged Tank (<=14t) or Colossus (<=11.5t) fire
         ;; instead of 0-DPS pure-MOVE backward kiting (`avoid-colossus-sweep-standoff` / `avoid-siege-tank-standoff-edge`)!
         (define target-in-weapon-range?
           (and target-su
                (not fragile-caster-no-atk?)
                (let* ([wr (if (and (eq? (tactical-sim-unit-type target-su) 'colossus)
                                    (fl> (tactical-sim-unit-air-range su) 0.0)
                                    (fl<= (tactical-sim-unit-ground-range su) 0.0))
                               (tactical-sim-unit-air-range su)
                               (sim-unit-weapon-range-vs su target-su))]
                       [td (fast-dist2d ux uy
                                        (tactical-sim-unit-x target-su)
                                        (tactical-sim-unit-y target-su))])
                  (and (fl> wr 0.0)
                       (not (sieged-tank-in-min-range-deadzone? utype (tactical-sim-unit-radius su) target-su (fl* td td)))
                       (fl<= td
                             (cond
                               [(and trapped-in-siege-zone?
                                     splash-move-pt
                                     (not active-spell-dodge?))
                                (flmax 14.0 (fl+ wr 6.5))]
                               [(and splash-move-pt
                                     (not active-spell-dodge?)
                                     (eq? sprole 'commit-run-through-splash-concave))
                                (flmax 10.5 (fl+ wr 5.0))]
                               [(eq? committed-act 'DisengageRetreat)
                                (if (fl<= wr 1.5) 9.0 (fl+ wr 4.5))]
                               [else
                                (fl+ wr
                                     (fl+ (tactical-sim-unit-radius su)
                                          (tactical-sim-unit-radius target-su)))]))))))
         (define maxed-splash-breakthrough?
           (and arena-commit-splash?
                (>= arena-supply-used 185)))
         (define ready-to-shoot-during-splash-commit?
           (and splash-move-pt
                (not active-spell-dodge?)
                (or maxed-splash-breakthrough?
                    (and trapped-in-siege-zone?
                         target-in-weapon-range?
                         (memq sprole '(commit-run-through-splash-concave
                                        commit-run-through-disruptor-split
                                        siege-tank-deadzone-dive
                                        colossus-radial-split-dive
                                        avoid-siege-tank-splash-split
                                        avoid-siege-tank-standoff-edge
                                        avoid-colossus-sweep-standoff)))
                    (and target-in-weapon-range?
                         (<= w-cd SC2-WEAPON-KITE-COOLDOWN-THRESH)
                         (or arena-commit-splash?
                             (memq sprole '(commit-run-through-splash-concave
                                            commit-run-through-disruptor-split
                                            siege-tank-deadzone-dive
                                            colossus-radial-split-dive
                                            avoid-siege-tank-splash-split
                                            avoid-siege-tank-standoff-edge
                                            avoid-colossus-sweep-standoff)))))))
         (cond
           [(or in-swing? channel-or-morph-locked?) (void)]
           [(and splash-move-pt (not ready-to-shoot-during-splash-commit?))
            (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'move 0 spx spy frame))
              (when (and ledger record-ledger?)
                (order-ledger-record-issued! ledger uid 'move 'move #:target-x spx #:target-y spy #:frame frame))
              (emit! (list 'move uid spx spy)))]
           [else
            (cond
              [(and (not target-su) (pair? untargetable-cloaked-rev))
               ;; W11-P0-4-rt (`w11-tac-2`): Only undetected `cloak=1` enemies in arena -> pull back
               ;; cleanly via MOVE/kite instead of issuing SC2-rejected `ATTACK (23)`!
               (unless (eq? utype 'siege-tank-sieged)
                 (define nearest-clk
                   (for/fold ([bc (car untargetable-cloaked-rev)]
                              [bd2 +inf.0]
                              #:result bc)
                             ([ce (in-list untargetable-cloaked-rev)])
                     (define dx (fl- ux (tactical-sim-unit-x ce)))
                     (define dy (fl- uy (tactical-sim-unit-y ce)))
                     (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                     (if (fl< d2 bd2) (values ce d2) (values bc bd2))))
                 (define-values (kx ky)
                   (compute-kite-vector ux uy (tactical-sim-unit-x nearest-clk) (tactical-sim-unit-y nearest-clk) 5.0))
                 (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'kite 0 kx ky frame))
                   (when (and ledger record-ledger?)
                     (order-ledger-record-issued! ledger uid 'kite 'move #:target-x kx #:target-y ky #:frame frame))
                   (emit! (list 'kite uid kx ky))))]
              [target-su
               (define eid (tactical-sim-unit-id target-su))
               (define ex (tactical-sim-unit-x target-su))
               (define ey (tactical-sim-unit-y target-su))
               (case committed-act
                [(DisengageRetreat)
                 (define wr
                   (if (and (eq? (tactical-sim-unit-type target-su) 'colossus)
                            (fl> (tactical-sim-unit-air-range su) 0.0)
                            (fl<= (tactical-sim-unit-ground-range su) 0.0))
                       (tactical-sim-unit-air-range su)
                       (sim-unit-weapon-range-vs su target-su)))
                 (define edist (fast-dist2d ux uy ex ey))
                 (define non-free-t?
                   (not (memq (tactical-sim-unit-type target-su)
                              '(locust locust-mp locustmp locust-flying))))
                 (define w-period (flmax 0.16 (exact->inexact (tactical-sim-unit-weapon-period su))))
                 (define kite-cd-min (flmax 0.22 (fl* 0.38 w-period)))
                 (define has-weap? (and (not fragile-caster-no-atk?) non-free-t? (fl> wr 0.0)))
                 (define melee-fight?
                   (and has-weap?
                        (fl<= wr 1.5)
                        (or (fl<= edist 8.5)
                            (and unit-in-any-siege-fire?
                                 (or kw-defending-home? (>= arena-ally-cnt 4))
                                 (fl<= edist 14.5)))))
                 ;; W4-TAC-3 + W7-TAC-2: Fire when weapon is ready/nearly-ready up to `wr + 2.5`
                 ;; (or `wr + 4.5` when protecting a nearby committed ally within `<= 10.0t`, matching
                 ;; `W5-TAC-5` so Marines 1t behind committing Marauders fire instead of fleeing!);
                 ;; when on cooldown, step back <= 2.0t inside threat range instead of a full-map retreat!
                 (define protect-committed-ally?
                   (and (pair? disengage-committed-pts)
                        (for/or ([pt (in-list disengage-committed-pts)])
                          (define dx (fl- ux (car pt)))
                          (define dy (fl- uy (cdr pt)))
                          (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 100.0))))
                 ;; W9-P0-2-rt / W10-P0-3-rt / W11-P0-4-rt / W18-P0-3-rt (`Siege0DPS` `#17/#18/#25/#26/#31/#32/#33`):
                 ;; When trapped inside active Sieged Tank (<=14t), Colossus (<=11.5t), or Tempest/Capital (<=18.5t)
                 ;; firing arcs (including while targeting their Marine/Stalker screeners!), commit-close & shoot
                 ;; instead of 0-DPS backward kiting inside enemy range!
                 (define capital-siege-dive?
                   (and has-weap? (fl> wr 1.5)
                        (or (and (memq (tactical-sim-unit-type target-su)
                                       '(tempest carrier brood-lord broodlord battlecruiser))
                                 (>= arena-ally-cnt 3)
                                 (fl<= edist 18.5))
                            (and (eq? (tactical-sim-unit-type target-su) 'colossus)
                                 (>= arena-ally-cnt 3)
                                 (fl<= edist 12.0))
                            (and (eq? (tactical-sim-unit-type target-su) 'siege-tank-sieged)
                                 (or (and kw-defending-home? (>= arena-ally-cnt 3) (fl<= edist 15.5))
                                     (and (>= arena-ally-cnt 4) (fl<= edist 14.5))))
                            (and unit-in-any-siege-fire?
                                 (or kw-defending-home? (>= arena-ally-cnt 4))
                                 (fl<= edist (flmax 14.5 (fl+ wr 6.5)))))))
                (define ranged-stutter-fire?
                  (or capital-siege-dive?
                      (and has-weap? (fl> wr 1.5)
                           (fl<= edist (fl+ wr (if protect-committed-ally? 4.5 2.5)))
                           (fl< (exact->inexact w-cd) kite-cd-min))))
                (cond
                  [(eq? utype 'siege-tank-sieged)
                   (when (and has-weap?
                              (not (sieged-tank-in-min-range-deadzone? utype (tactical-sim-unit-radius su) target-su (fl* edist edist))))
                     (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                       (when (and ledger record-ledger?)
                         (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                       (emit! (list 'attack-unit uid eid))))]
                  [(or melee-fight? ranged-stutter-fire?)
                   (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                     (when (and ledger record-ledger?)
                       (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                     (emit! (list 'attack-unit uid eid)))]
                  [else
                   (let-values ([(kx ky)
                                 (if (and has-weap? (fl> wr 1.5) (fl<= edist (flmax (fl+ wr 3.0) 11.0)))
                                     (compute-kite-vector ux uy ex ey 2.0)
                                     (values base-x base-y))])
                     (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'kite 0 kx ky frame))
                       (when (and ledger record-ledger?)
                         (order-ledger-record-issued! ledger uid 'kite 'move #:target-x kx #:target-y ky #:frame frame))
                       (emit! (list 'kite uid kx ky))))])]

               [(StutterKiteBack CloakHarassWorkers)
                (define eff-wr
                  (if (and (eq? (tactical-sim-unit-type target-su) 'colossus)
                           (fl> (tactical-sim-unit-air-range su) 0.0)
                           (fl<= (tactical-sim-unit-ground-range su) 0.0))
                      (tactical-sim-unit-air-range su)
                      (sim-unit-weapon-range-vs su target-su)))
                (define w-period (flmax 0.16 (exact->inexact (tactical-sim-unit-weapon-period su))))
                (define kite-cd-min (flmax 0.22 (fl* 0.38 w-period)))
                (define shorter-threat-closing?
                  (and (fl> eff-wr 1.5)
                       (let* ([close-r (flmax 2.5 (fl- eff-wr 0.75))]
                              [close-r2 (fl* close-r close-r)])
                         (for/or ([e (in-list arena-enemy-sims)])
                           (define e-wr (sim-unit-weapon-range-vs e su))
                           (and (fl< e-wr eff-wr)
                                (let ([edx (fl- ux (tactical-sim-unit-x e))]
                                      [edy (fl- uy (tactical-sim-unit-y e))])
                                  (fl<= (fl+ (fl* edx edx) (fl* edy edy)) close-r2)))))))
                (cond
                  [fragile-caster-no-atk?
                   (define-values (kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE))
                   (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'kite 0 kx ky frame))
                     (when (and ledger record-ledger?)
                       (order-ledger-record-issued! ledger uid 'kite 'move #:target-x kx #:target-y ky #:frame frame))
                     (emit! (list 'kite uid kx ky)))]
                  [(and (not (eq? utype 'baneling))
                        (not (eq? utype 'siege-tank-sieged))
                        (fl> eff-wr 1.5)
                        (fl>= (exact->inexact w-cd) kite-cd-min)
                        (or (eq? committed-act 'CloakHarassWorkers)
                            shorter-threat-closing?))
                   (define-values (kx ky) (compute-kite-vector ux uy ex ey (min 2.0 SC2-KITE-STEP-DISTANCE)))
                   (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'kite 0 kx ky frame))
                     (when (and ledger record-ledger?)
                       (order-ledger-record-issued! ledger uid 'kite 'move #:target-x kx #:target-y ky #:frame frame))
                     (emit! (list 'kite uid kx ky)))]
                  [else
                   (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                     (when (and ledger record-ledger?)
                       (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                     (emit! (list 'attack-unit uid eid)))])]

               [(HoldChoke)
                (unless fragile-caster-no-atk?
                  (define dist-to-nat (fast-dist2d ux uy nat-x nat-y))
                  (if (<= dist-to-nat 3.5)
                      (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'hold-position 0 nat-x nat-y frame))
                        (when (and ledger record-ledger?)
                          (order-ledger-record-issued! ledger uid 'hold-position 'hold-position #:frame frame))
                        (emit! (list 'hold-position uid nat-x nat-y)))
                      (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                        (when (and ledger record-ledger?)
                          (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                        (emit! (list 'attack-unit uid eid)))))]

               [else ;; CommitFocusFire, KiteForwardChase, FlankSurround
                (unless fragile-caster-no-atk?
                  (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                    (when (and ledger record-ledger?)
                      (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                    (emit! (list 'attack-unit uid eid))))])])])))

     (set-tactical-mirror-brain-last-decisions! brain (reverse decisions))
     (values (reverse actions) committed-tags (reverse decisions))]))
