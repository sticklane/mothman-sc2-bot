#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/zerg-burrow-micro.rkt`
;; Zerg Burrow & Unburrow Micro Logic (Typed Racket):
;;   - Roach `TunnelingClaws` low-HP burrow regeneration & tunnel-kite escape
;;   - Infestor burrow-approach, Neural Parasite / Fungal Growth cast & retreat
;;   - Lurker burrow-range siege & unburrow repositioning helpers
;;   - Drone harass-evade burrow & safe unburrow helpers
;; =============================================================================

(require racket/list
         racket/math
         racket/flonum
         racket/fixnum
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-game-constants.rkt"
         "../sc2-combat-eval.rkt")

(module dyn-hash-ops racket/base
  (require racket/flonum
           racket/fixnum)
  (provide dyn-hash-ref
           dyn-hash-has-key?
           fast-units-have-any-type?
           fast-counter-burrow-needed?
           fast-counter-burrow-preflight
           fast-dodge-obs-header
           fast-extract-burrow-allies
           fast-unit-revealed?
           fast-dodge-fallback-state
           fast-build-enemy-detectors
           fast-build-enemy-xy
           fast-flvec-det-within?
           fast-flvec-xy-within?
           fast-disruptor-nova-catchable-range
           fast-should-commit-through-splash?
           fast-plan-avoid-siege-tank-and-lurker-splash-zones)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (if (procedure? default)
            (hash-ref h k (lambda () default))
            (hash-ref h k default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))
  (define (fast-units-have-any-type? units syms)
    (for/or ([u (in-list units)])
      (and (hash? u) (not (not (memq (hash-ref u 'type 'unknown) syms))))))
  (define *potential-burrowers*
    '(zergling roach hydralisk baneling infestor swarm-host ultralisk
      lurker lurker-mp queen drone ravager infested-terran widow-mine unknown))
  (define (fast-by-type-has-any? by-type syms)
    (for/or ([s (in-list syms)])
      (define v (hash-ref by-type s #f))
      (or (pair? v) (and (real? v) (> v 0)))))
  (define (fast-enemy-burrowed-or-hidden? eu burrowed-syms hidden-display)
    (for/or ([e (in-list eu)])
      (and (hash? e)
           (let ([ut (hash-ref e 'type 'unknown)])
             (or (and (symbol? ut) (not (not (memq ut burrowed-syms))))
                 (and (or (not (symbol? ut)) (memq ut *potential-burrowers*))
                      (not (not (hash-ref e 'burrowed #f))))
                 (eq? (hash-ref e 'display-type 1) hidden-display))))))
  (define (fast-counter-burrow-needed? obs tr-rings rem-arg
                                       mobile-det-syms static-det-syms burrowed-syms
                                       hidden-display)
    (cond
      [(or (> (hash-count tr-rings) 0) (pair? rem-arg)) #t]
      [(not (hash? obs)) #f]
      [else
       (define obs-rem (hash-ref obs 'remembered-burrows '()))
       (define ripples (hash-ref obs 'shimmer-and-burrow-ripples '()))
       (cond
         [(or (pair? obs-rem) (pair? ripples)) #t]
         [else
          (define a-by-type (hash-ref obs 'ally-by-type #f))
          (define au (let ([v (hash-ref obs 'ally-units '())]) (if (list? v) v '())))
          (define mob-det?
            (if (and (hash? a-by-type) (> (hash-count a-by-type) 0))
                (fast-by-type-has-any? a-by-type mobile-det-syms)
                (fast-units-have-any-type? au mobile-det-syms)))
          (cond
            [mob-det? #t]
            [(and (hash-ref obs 'sweep-before-moveout? #f)
                  (let ([ab (let ([v (hash-ref obs 'ally-buildings '())]) (if (list? v) v '()))])
                    (or (fast-units-have-any-type? ab static-det-syms)
                        (if (and (hash? a-by-type) (> (hash-count a-by-type) 0))
                            (fast-by-type-has-any? a-by-type static-det-syms)
                            (fast-units-have-any-type? au static-det-syms)))))
             #t]
            [else
             (define eu (let ([v (hash-ref obs 'enemy-units '())]) (if (list? v) v '())))
             (fast-enemy-burrowed-or-hidden? eu burrowed-syms hidden-display)])])]))
  (define (fast-counter-burrow-preflight obs tr-rings rem-arg
                                         mobile-det-syms static-det-syms burrowed-syms
                                         hidden-display)
    (define s-obs (if (hash? obs) obs (hasheq)))
    (define au (let ([v (hash-ref s-obs 'ally-units '())]) (if (list? v) v '())))
    (define ab (let ([v (hash-ref s-obs 'ally-buildings '())]) (if (list? v) v '())))
    (define eu (let ([v (hash-ref s-obs 'enemy-units '())]) (if (list? v) v '())))
    (define obs-rem (let ([v (hash-ref s-obs 'remembered-burrows '())]) (if (list? v) v '())))
    (define ripples (let ([v (hash-ref s-obs 'shimmer-and-burrow-ripples '())]) (if (list? v) v '())))
    (define sweep-flag? (not (not (hash-ref s-obs 'sweep-before-moveout? #f))))
    (define a-by-type (hash-ref s-obs 'ally-by-type #f))
    (define mob-det?
      (if (and (hash? a-by-type) (> (hash-count a-by-type) 0))
          (fast-by-type-has-any? a-by-type mobile-det-syms)
          (fast-units-have-any-type? au mobile-det-syms)))
    (define-values (bur? hid?)
      (let loop ([es eu] [b? #f] [h? #f])
        (cond
          [(or (null? es) (and b? h?)) (values b? h?)]
          [else
           (define e (car es))
           (if (hash? e)
               (let* ([ut (hash-ref e 'type 'unknown)]
                      [eb? (or b?
                               (and (symbol? ut) (not (not (memq ut burrowed-syms))))
                               (and (or (not (symbol? ut)) (memq ut *potential-burrowers*))
                                    (not (not (hash-ref e 'burrowed #f)))))]
                      [eh? (or eb? h? (eq? (hash-ref e 'display-type 1) hidden-display))])
                 (loop (cdr es) eb? eh?))
               (loop (cdr es) b? h?))])))
    (define stat-det?
      (and (or bur? sweep-flag?)
           (or (fast-units-have-any-type? ab static-det-syms)
               (if (and (hash? a-by-type) (> (hash-count a-by-type) 0))
                   (fast-by-type-has-any? a-by-type static-det-syms)
                   (fast-units-have-any-type? au static-det-syms)))))
    (define ring-work?
      (or (> (hash-count tr-rings) 0)
          (pair? obs-rem)
          (pair? rem-arg)
          (and sweep-flag? stat-det?)))
    (define need-work?
      (or mob-det? hid? (pair? ripples) ring-work?))
    (values need-work? s-obs au ab eu obs-rem ripples sweep-flag? mob-det? bur? hid? stat-det?))

  (define (safe-fl v def)
    (if (rational? v)
        (real->double-flonum v)
        (real->double-flonum def)))

  (define (safe-int v def)
    (cond
      [(exact-integer? v) v]
      [(rational? v)
       (inexact->exact (truncate v))]
      [else def]))

  (define (fast-dodge-obs-header obs def-bx def-by)
    (define s-obs (if (hash? obs) obs (hasheq)))
    (define frame (safe-int (hash-ref s-obs 'frame 0) 0))
    (define upgrades (let ([v (hash-ref s-obs 'researched-upgrades '())]) (if (list? v) v '())))
    (define has-burrow?
      (let ([flag (hash-ref s-obs 'burrow-researched? 'unset)])
        (if (boolean? flag)
            flag
            (not (not (or (memq 'burrow upgrades)
                          (memq 'burrow-upgrade upgrades)
                          (memq 'tunneling-claws upgrades)
                          (memv 64 upgrades)))))))
    (define has-tunneling?
      (not (not (or (memq 'tunneling-claws upgrades)
                    (hash-ref s-obs 'tunneling-claws? #f)))))
    (define bx (safe-fl (hash-ref s-obs 'base-x def-bx) 32.0))
    (define by (safe-fl (hash-ref s-obs 'base-y def-by) 32.0))
    (define eu (let ([v (hash-ref s-obs 'enemy-units '())]) (if (list? v) v '())))
    (define eb (let ([v (hash-ref s-obs 'enemy-buildings '())]) (if (list? v) v '())))
    (define e1 (let ([v (hash-ref s-obs 'enemy-effects '())]) (if (list? v) v '())))
    (define e2 (let ([v (hash-ref s-obs 'active-effects '())]) (if (list? v) v '())))
    (define e3 (let ([v (hash-ref s-obs 'effects '())]) (if (list? v) v '())))
    (values frame upgrades has-burrow? has-tunneling? bx by eu eb e1 e2 e3))

  (define (fast-extract-burrow-allies ally-units burrowable-syms burrowed-syms bx by)
    (let loop ([us ally-units] [acc '()])
      (cond
        [(null? us) (reverse acc)]
        [else
         (define u (car us))
         (if (hash? u)
             (let ([utype (let ([t (hash-ref u 'type 'unknown)]) (if (symbol? t) t 'unknown))])
               (if (memq utype burrowable-syms)
                   (let* ([raw-uid (hash-ref u 'id 0)]
                          [uid (safe-int raw-uid 0)]
                          [ux (safe-fl (hash-ref u 'x bx) bx)]
                          [uy (safe-fl (hash-ref u 'y by) by)]
                          [raw-hp (or (hash-ref u 'hp #f) (hash-ref u 'health #f) 100.0)]
                          [hp (flmax 0.0 (safe-fl raw-hp 100.0))]
                          [raw-mhp (or (hash-ref u 'max-hp #f) (hash-ref u 'health-max #f) (flmax 1.0 hp))]
                          [mhp (flmax 1.0 (safe-fl raw-mhp (flmax 1.0 hp)))]
                          [bur? (not (not (or (memq utype burrowed-syms)
                                              (hash-ref u 'burrowed #f)
                                              (hash-ref u 'is-burrowed? #f))))])
                     (loop (cdr us)
                           (cons (vector-immutable u raw-uid uid utype ux uy hp mhp bur?)
                                 acc)))
                   (loop (cdr us) acc)))
             (loop (cdr us) acc))])))

  (define (fast-unit-revealed? u)
    (and (hash? u)
         (or (not (not (hash-ref u 'revealed? #f)))
             (not (not (hash-ref u 'detected? #f)))
             (eqv? (hash-ref u 'cloak 0) 2)
             (eq? (hash-ref u 'cloak #f) 'cloaked-detected)
             (let ([buffs (hash-ref u 'buffs '())])
               (and (list? buffs)
                    (for/or ([b (in-list buffs)])
                      ;; W12-P0-4-rt (`w12-tac-1`): Official SC2 buff ID for OracleRevelation is 49 (NOT 281 ChronoBoost!).
                      (or (not (not (memq b '(oracle-revelation revelation 49 99))))
                          (and (exact-integer? b) (= b 49)))))))))

  (define (fast-dodge-fallback-state u frame bur? default-hp)
    (define php (safe-fl (hash-ref u 'prev-hp default-hp) default-hp))
    (define lb (safe-int (hash-ref u 'last-burrow-frame (if bur? frame -1000)) -1000))
    (define lu (safe-int (hash-ref u 'last-unburrow-frame -1000) -1000))
    (values php lb lu))

  (define (fast-build-enemy-detectors eu eb e1 e2 e3 mob-syms stat-syms eff-syms complete-prog)
    (define raw '())
    (for ([e (in-list eu)])
      (when (hash? e)
        (define et (let ([t (hash-ref e 'type 'unknown)]) (if (symbol? t) t 'unknown)))
        (when (or (memq et mob-syms)
                  (and (memq et stat-syms)
                       (>= (safe-fl (hash-ref e 'build-progress 1.0) 1.0) complete-prog)))
          (set! raw (list* (safe-fl (hash-ref e 'x 9999.0) 9999.0)
                           (safe-fl (hash-ref e 'y 9999.0) 9999.0)
                           0.0
                           raw)))))
    (for ([b (in-list eb)])
      (when (hash? b)
        (define bt (let ([t (hash-ref b 'type 'unknown)]) (if (symbol? t) t 'unknown)))
        (when (and (memq bt stat-syms)
                   (>= (safe-fl (hash-ref b 'build-progress 1.0) 1.0) complete-prog))
          (set! raw (list* (safe-fl (hash-ref b 'x 9999.0) 9999.0)
                           (safe-fl (hash-ref b 'y 9999.0) 9999.0)
                           0.0
                           raw)))))
    (for ([eff-list (in-list (list e1 e2 e3))])
      (for ([eff (in-list eff-list)])
        (when (hash? eff)
          (define et-raw (or (hash-ref eff 'type #f) (hash-ref eff 'spell #f) 'unknown))
          (define et (if (symbol? et-raw) et-raw 'unknown))
          (when (or (memq et eff-syms)
                    (memv (safe-int (hash-ref eff 'effect-id 0) 0) '(6 399 2146)))
            (define er (safe-fl (hash-ref eff 'radius 11.0) 11.0))
            (set! raw (list* (safe-fl (hash-ref eff 'x 9999.0) 9999.0)
                             (safe-fl (hash-ref eff 'y 9999.0) 9999.0)
                             er
                             raw))))))
    (define n (quotient (length raw) 3))
    (define fv (make-flvector (* 3 n) 0.0))
    (let loop ([xs raw] [i 0])
      (unless (null? xs)
        (flvector-set! fv i (car xs))
        (flvector-set! fv (fx+ i 1) (cadr xs))
        (flvector-set! fv (fx+ i 2) (caddr xs))
        (loop (cdddr xs) (fx+ i 3))))
    (values fv (* 3 n)))

  (define (fast-build-enemy-xy eu syms)
    (define raw '())
    (for ([e (in-list eu)])
      (when (hash? e)
        (define et (let ([t (hash-ref e 'type 'unknown)]) (if (symbol? t) t 'unknown)))
        (when (memq et syms)
          (set! raw (list* (safe-fl (hash-ref e 'x 9999.0) 9999.0)
                           (safe-fl (hash-ref e 'y 9999.0) 9999.0)
                           raw)))))
    (define n (quotient (length raw) 2))
    (define fv (make-flvector (* 2 n) 0.0))
    (let loop ([xs raw] [i 0])
      (unless (null? xs)
        (flvector-set! fv i (car xs))
        (flvector-set! fv (fx+ i 1) (cadr xs))
        (loop (cddr xs) (fx+ i 2))))
    (values fv (* 2 n)))

  (define (fast-flvec-det-within? fv len ux uy base-radius)
    (let loop ([i 0])
      (cond
        [(fx>= i len) #f]
        [else
         (define mr (flvector-ref fv (fx+ i 2)))
         (define r (if (fl> mr base-radius) mr base-radius))
         (define dx (flabs (fl- ux (flvector-ref fv i))))
         (if (fl<= dx r)
             (let ([dy (flabs (fl- uy (flvector-ref fv (fx+ i 1))))])
               (if (and (fl<= dy r)
                        (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (fl* r r)))
                   #t
                   (loop (fx+ i 3))))
             (loop (fx+ i 3)))])))

  (define (fast-flvec-xy-within? fv len ux uy radius)
    (define r2 (fl* radius radius))
    (let loop ([i 0])
      (cond
        [(fx>= i len) #f]
        [else
         (define dx (flabs (fl- ux (flvector-ref fv i))))
         (if (fl<= dx radius)
             (let ([dy (flabs (fl- uy (flvector-ref fv (fx+ i 1))))])
               (if (and (fl<= dy radius)
                        (fl<= (fl+ (fl* dx dx) (fl* dy dy)) r2))
                   #t
                   (loop (fx+ i 2))))
             (loop (fx+ i 2)))])))

  (define (splash-fl v default)
    (cond
      [(flonum? v)
       (if (and (fl> v -inf.0) (fl< v +inf.0)) v default)]
      [(fixnum? v) (exact->inexact v)]
      [(real? v)
       (let ([f (exact->inexact v)])
         (if (rational? f) f default))]
      [else default]))

  (define (splash-sym v)
    (cond
      [(symbol? v) v]
      [(string? v) (string->symbol (string-downcase v))]
      [else 'unknown]))

  ;; Canonicalize CamelCase / lowercase compact unit names & SC2 type IDs in O(1)
  (define *splash-type-alias-table*
    (hasheq
     'siegetanksieged 'siege-tank-sieged
     'siegetank 'siege-tank
     'lurkermpburrowed 'lurker-mp-burrowed
     'lurkermp 'lurker-mp
     'lurkerburrowed 'lurker-burrowed
     'hightemplar 'high-templar
     'darktemplar 'dark-templar
     'disruptorphased 'disruptor-phased
     'disruptorphaser 'disruptor-phased
     'disruptor-phaser 'disruptor-phased
     'purificationnova 'purification-nova
     'disruptornova 'purification-nova
     'widowmine 'widow-mine
     'widowmineburrowed 'widow-mine-burrowed
     'broodlord 'brood-lord
     'swarmhost 'swarm-host
     'voidray 'void-ray
     'helliontank 'hellion-tank))

  (define (splash-unit-type-by-id u)
    (define uid (or (hash-ref u 'unit_type #f) (hash-ref u 'unit-type 0)))
    (cond
      [(equal? uid 694) 'disruptor]
      [(equal? uid 733) 'disruptor-phased]
      [(equal? uid 33) 'siege-tank-sieged]
      [(equal? uid 91) 'lurker-mp-burrowed]
      [(equal? uid 4) 'colossus]
      [(equal? uid 75) 'high-templar]
      [else 'unknown]))

  (define (splash-unit-type u)
    (define raw (hash-ref u 'type #f))
    (cond
      [(symbol? raw)
       (if (eq? raw 'unknown)
           (splash-unit-type-by-id u)
           (hash-ref *splash-type-alias-table* raw raw))]
      [(string? raw)
       (define sym (string->symbol (string-downcase raw)))
       (if (eq? sym 'unknown)
           (splash-unit-type-by-id u)
           (hash-ref *splash-type-alias-table* sym sym))]
      [else
       (splash-unit-type-by-id u)]))

  (define *splash-nova-unit-syms*
    '(disruptor-phased disruptor-phaser purification-nova disruptor-nova nova))

  ;; Base LotV speed (Faster tiles/sec) for fast O(1) speed-aware nova standoff checks
  (define *splash-unit-speed-table*
    (hasheq
     'scv 3.94 'probe 3.94 'drone 3.94 'mule 3.94
     'marine 3.15 'marauder 3.15 'reaper 5.25 'ghost 3.94
     'hellion 5.95 'hellbat 3.15 'hellion-tank 3.15 'widow-mine 3.94
     'cyclone 4.13 'siege-tank 3.15 'thor 2.62 'thor-ap 2.62
     'viking-assault 3.15 'zergling 4.13 'baneling 3.50 'queen 1.31
     'roach 3.15 'ravager 3.85 'hydralisk 3.15 'lurker 4.13 'lurker-mp 4.13
     'infestor 3.15 'swarm-host 4.13 'ultralisk 4.13 'broodling 5.37
     'zealot 3.15 'stalker 4.13 'sentry 3.15 'adept 3.50
     'high-templar 2.62 'dark-templar 3.94 'archon 3.94
     'immortal 3.15 'colossus 3.15 'disruptor 3.15))

  (define (splash-unit-speed u ut)
    (define raw-s (hash-ref u 'speed #f))
    (cond
      [(and (real? raw-s) (> raw-s 0.0)) (splash-fl raw-s 3.15)]
      [else
       (define base (hash-ref *splash-unit-speed-table* ut 3.15))
       (define stim?
         (and (or (eq? ut 'marine) (eq? ut 'marauder))
              (or (hash-ref u 'stimmed? #f) (hash-ref u 'stimmed #f) (hash-ref u 'stim? #f))))
       (define ling-spd? (and (eq? ut 'zergling)
                              (or (hash-ref u 'metabolic-boost? #f)
                                  (hash-ref u 'speed-upgraded? #f)
                                  (hash-ref u 'fast? #f))))
       (define creep? (hash-ref u 'on-creep? #f))
       (define adj
         (cond
           [stim? (fl* base 1.5)]
           [ling-spd? 6.58]
           [else base]))
       (if creep? (fl* adj 1.3) adj)]))

  ;; LotV per-unit supply (1 zergling = 0.5 supply, 1 ravager/lurker = 3.0, etc.)
  (define *splash-unit-supply-table*
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
     'drone 1.0 'scv 1.0 'probe 1.0))

  ;; Combat power (ehp . dps) from sc2-game-constants for fallback Lanchester estimate
  (define *splash-unit-power-table*
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
     'drone '(40.0 . 4.7) 'scv '(45.0 . 4.7) 'probe '(40.0 . 4.7)))

  (define (splash-unit-supply u ut)
    (define raw (hash-ref u 'supply #f))
    (if (and (real? raw) (> raw 0.0))
        (splash-fl raw 1.0)
        (hash-ref *splash-unit-supply-table* ut 1.0)))

  (define (splash-upgrade-present? upgrades target-syms)
    (for/or ([up (in-list upgrades)])
      (define sym
        (cond
          [(symbol? up) up]
          [(string? up) (string->symbol (string-downcase up))]
          [else #f]))
      (and sym (not (not (memq sym target-syms))))))

  (define *etl-upgrade-syms*
    '(extended-thermal-lance extendedthermallance thermal-lance thermallance
      colossus-range protoss-extended-thermal-lance))

  (define *seismic-upgrade-syms*
    '(seismic-spines seismicspines lurker-range lurkerrange zerg-seismic-spines))

  (define (fast-disruptor-nova-catchable-range unit-speed-tps clumped? ready?)
    (if (not ready?)
        0.0
        (let* ([spd (flmax 0.0 (splash-fl unit-speed-tps 3.15))]
               [raw (fl+ (fl- 14.25 (fl* 1.85 spd))
                         (if clumped? 1.0 0.0))])
          (flmax 6.5 (flmin 13.5 raw)))))

  (define (splash-disruptor-on-cooldown? e)
    (or (fl> (splash-fl (hash-ref e 'nova-cooldown #f) 0.0) 0.0)
        (fl> (splash-fl (hash-ref e 'cooldown-remaining #f) 0.0) 0.0)
        (fl> (splash-fl (hash-ref e 'cooldown #f) 0.0) 0.0)
        (fl> (splash-fl (hash-ref e 'weapon-cooldown #f) 0.0) 0.0)
        (eq? (splash-sym (hash-ref e 'state #f)) 'on-cooldown)))

  (define (splash-burrowed-lurker? e et)
    (or (memq et '(lurker-burrowed lurker-mp-burrowed))
        (and (memq et '(lurker lurker-mp))
             (or (hash-ref e 'burrowed #f)
                 (hash-ref e 'burrowed? #f)
                 (hash-ref e 'is-burrowed? #f)))))

  (define (splash-sieged-tank? e et)
    (or (eq? et 'siege-tank-sieged)
        (and (eq? et 'siege-tank)
             (or (hash-ref e 'sieged #f)
                 (hash-ref e 'sieged? #f)
                 (hash-ref e 'is-sieged? #f)))))

  ;; Compute minimal angular arc span [0, 360] around centroid (cx, cy) without wrap-around errors
  (define (compute-points-arc-deg xs ys cx cy)
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
       (define first-a (car angs))
       (define-values (prev max-gap)
         (for/fold ([p first-a] [mg 0.0])
                   ([a (in-list (cdr angs))])
           (define g (fl- a p))
           (values a (if (fl> g mg) g mg))))
       (define wrap-gap (fl- (fl+ first-a 360.0) prev))
       (define best-gap (if (fl> wrap-gap max-gap) wrap-gap max-gap))
       (flmax 0.0 (flmin 360.0 (fl- 360.0 best-gap)))]))

  (define (fast-should-commit-through-splash? friendly-units enemy-units disp ratio has-detector? arc-deg)
    (define timing-commit? (eq? disp 'execute-timing-attack-commit))
    (cond
      [(or (null? friendly-units) (null? enemy-units))
       timing-commit?]
      [else
       (define need-eff? (not (real? ratio)))
       ;; 1. Scan enemy-units FIRST so battles without splash enemies exit before scanning allies.
       (define e-sup 0.0)
       (define e-ehp 0.0)
       (define e-dps 0.0)
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

       (for ([e (in-list enemy-units)])
         (when (hash? e)
           (define ut (splash-unit-type e))
           (unless (or (hash-ref *splash-commit-skip-set* ut #f)
                       (hash-ref e 'is-building? #f)
                       (hash-ref e 'structure? #f))
             (define raw-hp (or (hash-ref e 'hp #f) (hash-ref e 'health #f)))
             (define raw-sh (or (hash-ref e 'shield #f) (hash-ref e 'shields #f)))
             (define hp+sh
               (if (or (real? raw-hp) (real? raw-sh))
                   (fl+ (splash-fl raw-hp 0.0) (splash-fl raw-sh 0.0))
                   +nan.0))
             (define alive? (if (rational? hp+sh) (fl> hp+sh 0.0) #t))
             (when alive?
               (set! e-sup (fl+ e-sup (splash-unit-supply e ut)))
               (when need-eff?
                 (define pw (hash-ref *splash-unit-power-table* ut '(80.0 . 10.0)))
                 (set! e-ehp (fl+ e-ehp (if (rational? hp+sh) hp+sh (car pw))))
                 (set! e-dps (fl+ e-dps (cdr pw))))
               (define thr-r 0.0)
               (case ut
                 [(siege-tank-sieged)
                  (set! n-tanks (fx+ n-tanks 1))
                  (set! thr-r 13.5)]
                 [(siege-tank)
                  (when (or (hash-ref e 'sieged #f)
                            (hash-ref e 'sieged? #f)
                            (hash-ref e 'is-sieged? #f))
                    (set! n-tanks (fx+ n-tanks 1))
                    (set! thr-r 13.5))]
                 [(lurker-burrowed lurker-mp-burrowed)
                  (set! n-lurkers (fx+ n-lurkers 1))
                  (set! thr-r 10.5)]
                 [(lurker lurker-mp)
                  (when (or (hash-ref e 'burrowed #f)
                            (hash-ref e 'burrowed? #f)
                            (hash-ref e 'is-burrowed? #f))
                    (set! n-lurkers (fx+ n-lurkers 1))
                    (set! thr-r 10.5))]
                 [(colossus)
                  (set! n-colossi (fx+ n-colossi 1))
                  (set! thr-r 9.5)]
                 [(disruptor)
                  (set! n-disruptors (fx+ n-disruptors 1))
                  (when (splash-disruptor-on-cooldown? e)
                    (set! n-disruptors-cd (fx+ n-disruptors-cd 1)))
                  (set! thr-r 12.0)]
                 [(high-templar)
                  (set! n-hts (fx+ n-hts 1))
                  (set! thr-r 10.5)])
               (when (fl> thr-r 0.0)
                 (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                 (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                 (when (and (rational? ex) (rational? ey))
                   (set! sp-x (cons ex sp-x))
                   (set! sp-y (cons ey sp-y))
                   (set! sp-r2 (cons (fl* thr-r thr-r) sp-r2))
                   (set! sum-cx (fl+ sum-cx ex))
                   (set! sum-cy (fl+ sum-cy ey))
                   (set! n-sp (fx+ n-sp 1))))))))

       (define n-splash (fx+ (fx+ n-tanks n-lurkers) (fx+ (fx+ n-colossi n-disruptors) n-hts)))
       (cond
         [(and (fx= n-splash 0) (not timing-commit?))
          #f]
         [else
          ;; 2. Accumulate fg-x/fg-y ONLY when enemy has tanks or lurkers (and not timing-commit).
          (define need-fg? (and (not timing-commit?) (or (fx> n-tanks 0) (fx> n-lurkers 0))))
          (define f-sup 0.0)
          (define f-ehp 0.0)
          (define f-dps 0.0)
          (define fg-x '())
          (define fg-y '())
          (for ([u (in-list friendly-units)])
            (when (hash? u)
              (define ut (splash-unit-type u))
              (unless (or (hash-ref *splash-commit-skip-set* ut #f)
                          (hash-ref u 'is-building? #f)
                          (hash-ref u 'structure? #f))
                (define raw-hp (or (hash-ref u 'hp #f) (hash-ref u 'health #f)))
                (define raw-sh (or (hash-ref u 'shield #f) (hash-ref u 'shields #f)))
                (define hp+sh
                  (if (or (real? raw-hp) (real? raw-sh))
                      (fl+ (splash-fl raw-hp 0.0) (splash-fl raw-sh 0.0))
                      +nan.0))
                (define alive? (if (rational? hp+sh) (fl> hp+sh 0.0) #t))
                (when alive?
                  (set! f-sup (fl+ f-sup (splash-unit-supply u ut)))
                  (when need-eff?
                    (define pw (hash-ref *splash-unit-power-table* ut '(80.0 . 10.0)))
                    (set! f-ehp (fl+ f-ehp (if (rational? hp+sh) hp+sh (car pw))))
                    (set! f-dps (fl+ f-dps (cdr pw))))
                  (when need-fg?
                    (unless (or (hash-ref *splash-flying-set* ut #f)
                                (hash-ref *splash-worker-set* ut #f)
                                (hash-ref u 'is-flying? #f)
                                (hash-ref u 'flying #f)
                                (hash-ref u 'air? #f))
                      (define ux (splash-fl (hash-ref u 'x #f) +nan.0))
                      (define uy (splash-fl (hash-ref u 'y #f) +nan.0))
                      (when (and (rational? ux) (rational? uy))
                        (set! fg-x (cons ux fg-x))
                        (set! fg-y (cons uy fg-y)))))))))

          (define sup-ratio
            (if (fl<= f-sup 0.0)
                0.0
                (fl/ f-sup (flmax 0.5 e-sup))))
          (define eff-ratio
            (if (not need-eff?)
                (splash-fl ratio 1.0)
                (let ([ep (fl* e-ehp e-dps)])
                  (if (fl> ep 0.0)
                      (fl/ (fl* f-ehp f-dps) ep)
                      (if (fl> f-sup 0.0) (fl* sup-ratio sup-ratio) 1.0)))))
          (cond
            [(fl<= f-sup 0.0) #f]
            [timing-commit?
             (not (and (fx> n-lurkers 0)
                       (not has-detector?)
                       (or (fl< sup-ratio 0.90) (fl< eff-ratio 0.90))))]
            [(and (fx> n-disruptors 0)
                  (fl>= (fl/ (exact->inexact n-disruptors-cd) (exact->inexact n-disruptors)) 0.50)
                  (fl>= sup-ratio 0.90))
             #t]
            [(and (fx> n-colossi 0)
                  (fl>= sup-ratio 1.20)
                  (fl>= eff-ratio 1.50))
             #t]
            [(and (fx> n-hts 0)
                  (fl>= sup-ratio 1.10)
                  (fl>= eff-ratio 1.25))
             #t]
            [else
             ;; Strictly lazy arc check (only when Tank or detected-Lurker ratio passes)
             (define tank-arc-ok?
               (and (fx> n-tanks 0) (fl>= sup-ratio 1.25) (fl>= eff-ratio 1.35)))
             (define lurk-arc-ok?
               (and (fx> n-lurkers 0) has-detector? (fl>= sup-ratio 1.35) (fl>= eff-ratio 1.25)))
             (define arc-commit?
               (and (or tank-arc-ok? lurk-arc-ok?)
                    (let ([arc (cond
                                 [(real? arc-deg) (splash-fl arc-deg 0.0)]
                                 [(and (fx> n-sp 0) (fx>= (length fg-x) 2))
                                  (compute-points-arc-deg fg-x fg-y
                                                          (fl/ sum-cx (exact->inexact n-sp))
                                                          (fl/ sum-cy (exact->inexact n-sp)))]
                                 [else 0.0])])
                      (or (and tank-arc-ok? (fl>= arc 35.0))
                          (and lurk-arc-ok? (fl>= arc 45.0))))))
             (or arc-commit?
                 ;; Strictly lazy frac-in-splash check (only when arc failed & ratio qualifies)
                 (and (or (and (fx> n-tanks 0) (fl>= sup-ratio 1.05))
                          (and (fx> n-lurkers 0) has-detector? (fl>= sup-ratio 1.15)))
                      (let ([n-fg (length fg-x)])
                        (and (fx> n-fg 0)
                             (fx> n-sp 0)
                             (let loop ([uxs fg-x] [uys fg-y] [in-cnt 0])
                               (if (null? uxs)
                                   (fl>= (fl/ (exact->inexact in-cnt) (exact->inexact n-fg)) 0.55)
                                   (let ([ux (car uxs)] [uy (car uys)])
                                     (define hit?
                                       (let sloop ([sx sp-x] [sy sp-y] [sr2 sp-r2])
                                         (and (pair? sx)
                                              (let ([dx (fl- ux (car sx))]
                                                    [dy (fl- uy (car sy))])
                                                (or (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (car sr2))
                                                    (sloop (cdr sx) (cdr sy) (cdr sr2)))))))
                                     (loop (cdr uxs) (cdr uys) (if hit? (fx+ in-cnt 1) in-cnt)))))))))])])]))

  (define (splash-syms->hasheq syms)
    (for/hasheq ([s (in-list syms)])
      (values s #t)))

  (define *splash-flying-types*
    '(overlord overseer overseer-siege-mode mutalisk corruptor brood-lord viper
      phoenix void-ray oracle carrier tempest mothership interceptor
      observer observer-siege-mode warp-prism warp-prism-phasing
      medivac viking-fighter viking banshee raven battlecruiser
      liberator liberator-ag scourge))

  (define *splash-noncombat-or-structure-types*
    '(larva egg baneling-cocoon ravager-cocoon lurker-egg lurker-mp-egg
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
      bunker missile-turret sensor-tower fusion-core ghost-academy))

  (define *splash-worker-types*
    '(drone scv probe mule))

  (define *splash-deadzone-dive-types*
    '(zergling zealot ultralisk hellion-tank hellbat roach immortal stalker marine marauder))

  (define *splash-burrow-intent-syms*
    '(burrow burrow-down burrowing morph-lurker-burrowed))

  (define *splash-nova-set*
    (splash-syms->hasheq *splash-nova-unit-syms*))

  (define *splash-flying-set*
    (splash-syms->hasheq *splash-flying-types*))

  (define *splash-noncombat-or-structure-set*
    (splash-syms->hasheq *splash-noncombat-or-structure-types*))

  (define *splash-commit-skip-set*
    (splash-syms->hasheq
     (append *splash-noncombat-or-structure-types*
             *splash-nova-unit-syms*
             '(observer overseer overseer-siege-mode overlord warp-prism warp-prism-phasing interceptor))))

  (define *splash-worker-set*
    (splash-syms->hasheq *splash-worker-types*))

  (define *splash-deadzone-dive-set*
    (splash-syms->hasheq *splash-deadzone-dive-types*))

  (define *splash-hazard-ally-skip-set*
    (splash-syms->hasheq
     (append *splash-noncombat-or-structure-types* *splash-flying-types*)))

  (define *splash-hazard-enemy-set*
    (splash-syms->hasheq
     (append *splash-nova-unit-syms*
             '(disruptor colossus lurker lurker-mp lurker-burrowed lurker-mp-burrowed
               siege-tank siege-tank-sieged high-templar))))

  (define (fast-plan-avoid-siege-tank-and-lurker-splash-zones
           ally-units enemy-units effects home-x home-y
           [commit-through-splash? #f]
           [enemy-upgrades '()]
           [tactical-disposition #f]
           [lanchester-ratio 1.0])
    (define effective-commit?
      (or (not (not commit-through-splash?))
          (eq? tactical-disposition 'execute-timing-attack-commit)))
    (define has-etl-upgrade?
      (and (pair? enemy-upgrades) (splash-upgrade-present? enemy-upgrades *etl-upgrade-syms*)))
    (define has-seismic-lurker?
      (and (pair? enemy-upgrades) (splash-upgrade-present? enemy-upgrades *seismic-upgrade-syms*)))

    ;; 1. Collect hazard AoE zones, spine effects & active Nova projectiles from effects list
    (define spine-effects '())
    (define aoe-effects '())
    (define active-novas '())
    (when (pair? effects)
      (for ([eff (in-list effects)])
        (when (hash? eff)
          (define raw-kind
            (let ([t (hash-ref eff 'type #f)])
              (if t
                  t
                  (let ([s (hash-ref eff 'spell #f)])
                    (if s
                        s
                        (or (hash-ref eff 'kind #f)
                            (hash-ref eff 'ability #f)
                            (hash-ref eff 'name 'unknown)))))))
          (define raw-sym (splash-sym raw-kind))
          (define kind (hash-ref *splash-type-alias-table* raw-sym raw-sym))
          (define eff-id (hash-ref eff 'effect-id 0))
          (define norm-kind
            (cond
              [(eq? kind 'unknown)
               (cond
                 [(equal? eff-id 11) 'corrosive-bile]
                 [(equal? eff-id 7) 'nuke-persistent]
                 [else 'unknown])]
              [else kind]))
          (define ex (splash-fl (hash-ref eff 'x #f) +nan.0))
          (define ey (splash-fl (hash-ref eff 'y #f) +nan.0))
          (when (and (rational? ex) (rational? ey))
            (cond
              [(hash-ref *splash-nova-set* norm-kind #f)
               (set! active-novas (cons (cons ex ey) active-novas))]
              [(memq norm-kind '(lurker-spines lurker-spine lurker-mp-spines))
               (define tx (splash-fl (or (hash-ref eff 'target-x #f) (hash-ref eff 'end-x #f)) +nan.0))
               (define ty (splash-fl (or (hash-ref eff 'target-y #f) (hash-ref eff 'end-y #f)) +nan.0))
               (define dx (splash-fl (or (hash-ref eff 'dx #f) (hash-ref eff 'dir-x #f)) +nan.0))
               (define dy (splash-fl (or (hash-ref eff 'dy #f) (hash-ref eff 'dir-y #f)) +nan.0))
               (set! spine-effects (cons (vector ex ey tx ty dx dy) spine-effects))]
              [(memq norm-kind '(corrosive-bile psionic-storm psi-storm nuke nuke-persistent))
               (define raw-r (hash-ref eff 'radius #f))
               (define def-r
                 (cond
                   [(eq? norm-kind 'corrosive-bile) 1.0]
                   [(memq norm-kind '(nuke nuke-persistent)) 8.0]
                   [else 1.75]))
               (define eff-r (flmax 0.5 (splash-fl raw-r def-r)))
               (define trig-r (if (real? raw-r) (fl+ eff-r 0.35) eff-r))
               (set! aoe-effects (cons (vector norm-kind ex ey eff-r trig-r) aoe-effects))])))))

    ;; 2. Fast preflight scan of enemy-units for Lurkers, Tanks, Colossi, Disruptors & Novas
    (define burrowed-lurkers '())
    (define intent-lurkers '())
    (define sieged-tanks '())
    (define enemy-colossi '())
    (define enemy-disruptors '())
    (define enemy-hts '())
    (define need-ht-pts? (and effective-commit? (pair? aoe-effects)))
    (when (pair? enemy-units)
      (for ([e (in-list enemy-units)])
        (when (hash? e)
          (define et (splash-unit-type e))
          (when (hash-ref *splash-hazard-enemy-set* et #f)
            (define raw-hp (or (hash-ref e 'hp #f) (hash-ref e 'health #f)))
            (define raw-sh (or (hash-ref e 'shield #f) (hash-ref e 'shields #f)))
            (define alive?
              (if (or (real? raw-hp) (real? raw-sh))
                  (fl> (fl+ (splash-fl raw-hp 0.0) (splash-fl raw-sh 0.0)) 0.0)
                  #t))
            (when alive?
              (case et
                [(disruptor)
                 (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                 (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                 (when (and (rational? ex) (rational? ey))
                   (set! enemy-disruptors
                         (cons (vector ex ey (splash-disruptor-on-cooldown? e)) enemy-disruptors)))]
                [(colossus)
                 (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                 (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                 (when (and (rational? ex) (rational? ey))
                   (define etl?
                     (or has-etl-upgrade?
                         (hash-ref e 'extended-thermal-lance #f)
                         (hash-ref e 'has-etl? #f)
                         (fl>= (splash-fl (hash-ref e 'range #f) 0.0) 8.5)))
                   (set! enemy-colossi (cons (vector ex ey (if etl? 10.2 8.5)) enemy-colossi)))]
                [(lurker-burrowed lurker-mp-burrowed)
                 (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                 (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                 (when (and (rational? ex) (rational? ey))
                   (when (or (hash-ref e 'seismic-spines #f)
                             (hash-ref e 'seismic-spines? #f)
                             (fl>= (splash-fl (hash-ref e 'range #f) 0.0) 9.5))
                     (set! has-seismic-lurker? #t))
                   (set! burrowed-lurkers (cons (cons ex ey) burrowed-lurkers)))]
                [(lurker lurker-mp)
                 (cond
                   [(or (hash-ref e 'burrowed #f)
                        (hash-ref e 'burrowed? #f)
                        (hash-ref e 'is-burrowed? #f))
                    (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                    (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                    (when (and (rational? ex) (rational? ey))
                      (when (or (hash-ref e 'seismic-spines #f)
                                (hash-ref e 'seismic-spines? #f)
                                (fl>= (splash-fl (hash-ref e 'range #f) 0.0) 9.5))
                        (set! has-seismic-lurker? #t))
                      (set! burrowed-lurkers (cons (cons ex ey) burrowed-lurkers)))]
                   [(or (hash-ref e 'burrow-intent? #f)
                        (hash-ref e 'burrow-intent #f)
                        (hash-ref e 'burrowing? #f)
                        (hash-ref e 'is-burrowing? #f)
                        (hash-ref e 'preparing-burrow? #f)
                        (memq (splash-sym (hash-ref e 'intent #f)) *splash-burrow-intent-syms*)
                        (memq (splash-sym (hash-ref e 'order #f)) *splash-burrow-intent-syms*)
                        (memq (splash-sym (hash-ref e 'ability #f)) *splash-burrow-intent-syms*)
                        (fl> (splash-fl (hash-ref e 'burrow-progress #f) 0.0) 0.0))
                    (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                    (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                    (when (and (rational? ex) (rational? ey))
                      (when (or (hash-ref e 'seismic-spines #f)
                                (hash-ref e 'seismic-spines? #f)
                                (fl>= (splash-fl (hash-ref e 'range #f) 0.0) 9.5))
                        (set! has-seismic-lurker? #t))
                      (set! intent-lurkers (cons (cons ex ey) intent-lurkers)))])]
                [(siege-tank-sieged)
                 (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                 (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                 (when (and (rational? ex) (rational? ey))
                   (set! sieged-tanks (cons (cons ex ey) sieged-tanks)))]
                [(siege-tank)
                 (when (or (hash-ref e 'sieged #f)
                           (hash-ref e 'sieged? #f)
                           (hash-ref e 'is-sieged? #f))
                   (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                   (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                   (when (and (rational? ex) (rational? ey))
                     (set! sieged-tanks (cons (cons ex ey) sieged-tanks))))]
                [(high-templar)
                 (when need-ht-pts?
                   (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                   (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                   (when (and (rational? ex) (rational? ey))
                     (set! enemy-hts (cons (cons ex ey) enemy-hts))))]
                [else
                 (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                 (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                 (when (and (rational? ex) (rational? ey))
                   (set! active-novas (cons (cons ex ey) active-novas)))]))))))

    ;; Early exit when zero splash threats or hazard AoE effects exist
    (cond
      [(and (null? spine-effects)
            (null? aoe-effects)
            (null? active-novas)
            (null? enemy-disruptors)
            (null? enemy-colossi)
            (null? burrowed-lurkers)
            (null? intent-lurkers)
            (null? sieged-tanks))
       '()]
      [else
       ;; 3. Collect friendly ground units directly into unboxed arrays (zero tuple boxing)
       (define need-speed? (pair? enemy-disruptors))
       (define nmax (length ally-units))
       (define ax (make-flvector nmax 0.0))
       (define ay (make-flvector nmax 0.0))
       (define aspd (make-flvector nmax 3.15))
       (define auid (make-vector nmax #f))
       (define acombat (make-vector nmax #f))
       (define adive (make-vector nmax #f))
       (define n 0)
       (for ([u (in-list ally-units)])
         (when (hash? u)
           (define ut (splash-unit-type u))
           (unless (or (hash-ref *splash-hazard-ally-skip-set* ut #f)
                       (hash-ref u 'is-flying? #f)
                       (hash-ref u 'flying #f)
                       (hash-ref u 'air? #f)
                       (hash-ref u 'is-building? #f)
                       (hash-ref u 'structure? #f))
             (define raw-hp (or (hash-ref u 'hp #f) (hash-ref u 'health #f)))
             (define alive? (or (not (real? raw-hp)) (fl> (splash-fl raw-hp 1.0) 0.0)))
             (when alive?
               (define uid (or (hash-ref u 'unit-id #f)
                               (hash-ref u 'id #f)
                               (hash-ref u 'tag #f)))
               (when uid
                 (define ux (splash-fl (hash-ref u 'x #f) +nan.0))
                 (define uy (splash-fl (hash-ref u 'y #f) +nan.0))
                 (when (and (rational? ux) (rational? uy))
                   (vector-set! auid n uid)
                   (flvector-set! ax n ux)
                   (flvector-set! ay n uy)
                   (vector-set! acombat n (not (hash-ref *splash-worker-set* ut #f)))
                   (vector-set! adive n (not (not (hash-ref *splash-deadzone-dive-set* ut #f))))
                   (when need-speed?
                     (flvector-set! aspd n (splash-unit-speed u ut)))
                   (set! n (fx+ n 1))))))))

       (cond
         [(fx= n 0) '()]
         [else
          (define acmd (make-vector n #f))

          ;; Priority 0: Active Purification Nova (`<= 6.5` tiles, front/targeted clump flare >= 3.0 spacing)
          (when (pair? active-novas)
            (define nnv (length active-novas))
            (define nxv (make-flvector nnv 0.0))
            (define nyv (make-flvector nnv 0.0))
            (let fill-nv ([xs active-novas] [k 0])
              (unless (null? xs)
                (flvector-set! nxv k (caar xs))
                (flvector-set! nyv k (cdar xs))
                (fill-nv (cdr xs) (fx+ k 1))))
            (define cand-idx '())
            (define ctxv (make-flvector n 0.0))
            (define ctyv (make-flvector n 0.0))
            (define cnxv (make-flvector n 0.0))
            (define cnyv (make-flvector n 0.0))
            (let uloop ([i 0])
              (when (fx< i n)
                (define ux (flvector-ref ax i))
                (define uy (flvector-ref ay i))
                (define best-d2 42.25) ; 6.5^2
                (define best-k -1)
                (let kloop ([k 0])
                  (when (fx< k nnv)
                    (define dx (flabs (fl- ux (flvector-ref nxv k))))
                    (when (fl<= dx 6.5)
                      (define dy (flabs (fl- uy (flvector-ref nyv k))))
                      (when (fl<= dy 6.5)
                        (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                        (when (and (fl<= d2 42.25)
                                   (or (fx= best-k -1) (fl< d2 best-d2)))
                          (set! best-d2 d2)
                          (set! best-k k))))
                    (kloop (fx+ k 1))))
                (unless (fx= best-k -1)
                  (define nx (flvector-ref nxv best-k))
                  (define ny (flvector-ref nyv best-k))
                  (define d (flsqrt best-d2))
                  (define-values (rx ry)
                    (if (fl> d 0.05)
                        (values (fl/ (fl- ux nx) d) (fl/ (fl- uy ny) d))
                        (let* ([hx (fl- home-x ux)]
                               [hy (fl- home-y uy)]
                               [hd (flsqrt (fl+ (fl* hx hx) (fl* hy hy)))])
                          (if (fl> hd 0.05)
                              (values (fl/ hx hd) (fl/ hy hd))
                              (values 1.0 0.0)))))
                  (define px (fl- ry))
                  (define py rx)
                  (define sep-x 0.0)
                  (define sep-y 0.0)
                  (let jloop ([j 0])
                    (when (fx< j n)
                      (unless (fx= i j)
                        (define dx (fl- ux (flvector-ref ax j)))
                        (when (fl<= (flabs dx) 3.2)
                          (define dy (fl- uy (flvector-ref ay j)))
                          (when (fl<= (flabs dy) 3.2)
                            (define nd2 (fl+ (fl* dx dx) (fl* dy dy)))
                            (when (fl<= nd2 10.24)
                              (if (fl> nd2 0.0001)
                                  (let* ([nd (flsqrt nd2)]
                                         [w (fl/ 1.0 (flmax 0.3 nd))])
                                    (set! sep-x (fl+ sep-x (fl* w (fl/ dx nd))))
                                    (set! sep-y (fl+ sep-y (fl* w (fl/ dy nd)))))
                                  (let ([s (if (fx< i j) -1.0 1.0)])
                                    (set! sep-x (fl+ sep-x (fl* s px)))
                                    (set! sep-y (fl+ sep-y (fl* s py)))))))))
                      (jloop (fx+ j 1))))
                  (define smag (flsqrt (fl+ (fl* sep-x sep-x) (fl* sep-y sep-y))))
                  (define-values (sux suy)
                    (if (fl> smag 0.01)
                        (values (fl/ sep-x smag) (fl/ sep-y smag))
                        (let ([s (if (fx= (remainder i 2) 0) 1.0 -1.0)])
                          (values (fl* s px) (fl* s py)))))
                  (define pdot (fl+ (fl* sux px) (fl* suy py)))
                  (define p-sign
                    (cond
                      [(fl> pdot 0.05) 1.0]
                      [(fl< pdot -0.05) -1.0]
                      [(fx= (remainder i 2) 0) 1.0]
                      [else -1.0]))
                  (define bx (fl+ (fl+ (fl* 0.55 rx) (fl* 0.65 (fl* p-sign px))) (fl* 0.45 sux)))
                  (define by (fl+ (fl+ (fl* 0.55 ry) (fl* 0.65 (fl* p-sign py))) (fl* 0.45 suy)))
                  (define bmag (flsqrt (fl+ (fl* bx bx) (fl* by by))))
                  (define-values (mx my)
                    (if (fl> bmag 0.01)
                        (values (fl/ bx bmag) (fl/ by bmag))
                        (values rx ry)))
                  (define step (flmax 3.4 (flmin 4.8 (fl- 7.0 d))))
                  (flvector-set! ctxv i (fl+ ux (fl* step mx)))
                  (flvector-set! ctyv i (fl+ uy (fl* step my)))
                  (flvector-set! cnxv i nx)
                  (flvector-set! cnyv i ny)
                  (set! cand-idx (cons i cand-idx)))
                (uloop (fx+ i 1))))
            ;; Target-spacing relaxation pass so clumped units achieve >= 3.0 tile spacing
            (define rev-cands (reverse cand-idx))
            (let relax ([xs rev-cands])
              (unless (null? xs)
                (define i (car xs))
                (define txi (flvector-ref ctxv i))
                (define tyi (flvector-ref ctyv i))
                (let ploop ([ys rev-cands])
                  (unless (null? ys)
                    (define j (car ys))
                    (when (fx< j i)
                      (define dx (fl- txi (flvector-ref ctxv j)))
                      (define dy (fl- tyi (flvector-ref ctyv j)))
                      (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                      (when (fl< d2 9.3025) ; 3.05^2
                        (define d (flsqrt d2))
                        (define nx (flvector-ref cnxv i))
                        (define ny (flvector-ref cnyv i))
                        (define rx (fl- txi nx))
                        (define ry (fl- tyi ny))
                        (define rmag (flmax 0.1 (flsqrt (fl+ (fl* rx rx) (fl* ry ry)))))
                        (define-values (ux-p uy-p)
                          (if (fl> d 0.05)
                              (values (fl/ dx d) (fl/ dy d))
                              (let ([s (if (fx= (remainder i 2) 0) 1.0 -1.0)])
                                (values (fl* s (fl- (fl/ ry rmag))) (fl* s (fl/ rx rmag))))))
                        (define push (fl+ (fl- 3.1 d) 0.15))
                        (set! txi (fl+ txi (fl* push ux-p)))
                        (set! tyi (fl+ tyi (fl* push uy-p)))))
                    (ploop (cdr ys))))
                (vector-set! acmd i
                  (hasheq 'action 'move
                          'unit-id (vector-ref auid i)
                          'role 'dodge-active-disruptor-nova
                          'reason 'flare-away-from-active-disruptor-nova
                          'target-x txi
                          'target-y tyi))
                (relax (cdr xs)))))

          ;; Helper: nearest friendly ground unit (prefer combat) within range
          (define (find-nearest-spine-target lx ly max-r)
            (define r2 (fl* max-r max-r))
            (define best-combat-d2 r2)
            (define best-combat-i -1)
            (define best-any-d2 r2)
            (define best-any-i -1)
            (let loop ([i 0])
              (when (fx< i n)
                (define dx (fl- (flvector-ref ax i) lx))
                (define dy (fl- (flvector-ref ay i) ly))
                (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                (when (fl<= d2 r2)
                  (when (or (fx= best-any-i -1) (fl< d2 best-any-d2))
                    (set! best-any-d2 d2)
                    (set! best-any-i i))
                  (when (and (vector-ref acombat i)
                             (or (fx= best-combat-i -1) (fl< d2 best-combat-d2)))
                    (set! best-combat-d2 d2)
                    (set! best-combat-i i)))
                (loop (fx+ i 1))))
            (if (not (fx= best-combat-i -1))
                best-combat-i
                best-any-i))

          ;; 4. Build active Lurker spine segments (vector lx ly vx vy)
          (define spine-segs '())
          (define lurker-pts '())
          (define (add-lurker-seg! lx ly vx vy)
            (set! spine-segs (cons (vector lx ly vx vy) spine-segs)))

          (define (unit-dir-to lx ly tx ty)
            (define dx (fl- tx lx))
            (define dy (fl- ty ly))
            (define d (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))
            (if (fl> d 0.05)
                (values (fl/ dx d) (fl/ dy d))
                (let* ([hx (fl- home-x lx)]
                       [hy (fl- home-y ly)]
                       [hd (flsqrt (fl+ (fl* hx hx) (fl* hy hy)))])
                  (if (fl> hd 0.05)
                      (values (fl/ hx hd) (fl/ hy hd))
                      (values 1.0 0.0)))))

          (define lurker-scan-r (if (and has-seismic-lurker? (not effective-commit?)) 11.5 10.0))
          (for ([lp (in-list burrowed-lurkers)])
            (define lx (car lp))
            (define ly (cdr lp))
            (set! lurker-pts (cons lp lurker-pts))
            (define ti (find-nearest-spine-target lx ly lurker-scan-r))
            (when (not (fx= ti -1))
              (define-values (vx vy) (unit-dir-to lx ly (flvector-ref ax ti) (flvector-ref ay ti)))
              (add-lurker-seg! lx ly vx vy)))

          (for ([lp (in-list intent-lurkers)])
            (define lx (car lp))
            (define ly (cdr lp))
            (define ti95 (find-nearest-spine-target lx ly 9.5))
            (when (not (fx= ti95 -1))
              (set! lurker-pts (cons lp lurker-pts))
              (define-values (vx vy) (unit-dir-to lx ly (flvector-ref ax ti95) (flvector-ref ay ti95)))
              (add-lurker-seg! lx ly vx vy)))

          (for ([se (in-list spine-effects)])
            (define lx (vector-ref se 0))
            (define ly (vector-ref se 1))
            (define tx (vector-ref se 2))
            (define ty (vector-ref se 3))
            (define dx (vector-ref se 4))
            (define dy (vector-ref se 5))
            (set! lurker-pts (cons (cons lx ly) lurker-pts))
            (cond
              [(and (rational? tx) (rational? ty))
               (define-values (vx vy) (unit-dir-to lx ly tx ty))
               (add-lurker-seg! lx ly vx vy)]
              [(and (rational? dx) (rational? dy)
                    (fl> (flsqrt (fl+ (fl* dx dx) (fl* dy dy))) 0.05))
               (define d (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))
               (add-lurker-seg! lx ly (fl/ dx d) (fl/ dy d))]
              [else
               (define ti (find-nearest-spine-target lx ly lurker-scan-r))
               (when (not (fx= ti -1))
                 (define-values (vx vy) (unit-dir-to lx ly (flvector-ref ax ti) (flvector-ref ay ti)))
                 (add-lurker-seg! lx ly vx vy))]))

          ;; Priority 1: Lurker Linear Spine Splash Avoidance (unboxed loop, zero tuple boxing)
          (when (pair? spine-segs)
            (define nseg (length spine-segs))
            (define slxv (make-flvector nseg 0.0))
            (define slyv (make-flvector nseg 0.0))
            (define svxv (make-flvector nseg 0.0))
            (define svyv (make-flvector nseg 0.0))
            (define min-sx 1e9)
            (define max-sx -1e9)
            (define min-sy 1e9)
            (define max-sy -1e9)
            (let fill-s ([xs spine-segs] [si 0])
              (unless (null? xs)
                (define seg (car xs))
                (define lx (vector-ref seg 0))
                (define ly (vector-ref seg 1))
                (flvector-set! slxv si lx)
                (flvector-set! slyv si ly)
                (flvector-set! svxv si (vector-ref seg 2))
                (flvector-set! svyv si (vector-ref seg 3))
                (when (fl< lx min-sx) (set! min-sx lx))
                (when (fl> lx max-sx) (set! max-sx lx))
                (when (fl< ly min-sy) (set! min-sy ly))
                (when (fl> ly max-sy) (set! max-sy ly))
                (fill-s (cdr xs) (fx+ si 1))))

            (define nl (length lurker-pts))
            (define lxv (make-flvector nl 0.0))
            (define lyv (make-flvector nl 0.0))
            (let fill-l ([xs lurker-pts] [i 0])
              (unless (null? xs)
                (flvector-set! lxv i (caar xs))
                (flvector-set! lyv i (cdar xs))
                (fill-l (cdr xs) (fx+ i 1))))

            ;; Enemy points within 28 tiles of active spine origins
            (define ex-lo (fl- min-sx 28.0))
            (define ex-hi (fl+ max-sx 28.0))
            (define ey-lo (fl- min-sy 28.0))
            (define ey-hi (fl+ max-sy 28.0))
            (define enemy-pts '())
            (for ([e (in-list enemy-units)])
              (when (hash? e)
                (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                (when (and (rational? ex) (rational? ey)
                           (fl>= ex ex-lo) (fl<= ex ex-hi)
                           (fl>= ey ey-lo) (fl<= ey ey-hi))
                  (define raw-hp (or (hash-ref e 'hp #f) (hash-ref e 'health #f)))
                  (when (or (not (real? raw-hp)) (fl> (splash-fl raw-hp 1.0) 0.0))
                    (set! enemy-pts (cons (cons ex ey) enemy-pts))))))
            (define ne (length enemy-pts))
            (define exv (make-flvector ne 0.0))
            (define eyv (make-flvector ne 0.0))
            (let fill-e ([xs enemy-pts] [i 0])
              (unless (null? xs)
                (flvector-set! exv i (caar xs))
                (flvector-set! eyv i (cdar xs))
                (fill-e (cdr xs) (fx+ i 1))))

            (define naoe (length aoe-effects))
            (define aexv (make-flvector naoe 0.0))
            (define aeyv (make-flvector naoe 0.0))
            (define aetrv2 (make-flvector naoe 0.0))
            (let fill-a ([xs aoe-effects] [i 0])
              (unless (null? xs)
                (define ae (car xs))
                (flvector-set! aexv i (vector-ref ae 1))
                (flvector-set! aeyv i (vector-ref ae 2))
                (define tr (vector-ref ae 4))
                (flvector-set! aetrv2 i (fl* tr tr))
                (fill-a (cdr xs) (fx+ i 1))))

            (define (seg-dist2-within-10.5 px py lx ly vx vy)
              (define dx (fl- px lx))
              (define dy (fl- py ly))
              (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
              (if (fl> d2 110.25)
                  999.0
                  (let* ([proj (fl+ (fl* dx vx) (fl* dy vy))]
                         [tc (flmax 0.0 (flmin 10.0 proj))]
                         [sdx (fl- dx (fl* tc vx))]
                         [sdy (fl- dy (fl* tc vy))])
                    (fl+ (fl* sdx sdx) (fl* sdy sdy)))))

            (define (score-lurker-step px py perp-dot)
              (define sc 0.0)
              (let sloop ([k 0])
                (when (fx< k nseg)
                  (when (fl<= (seg-dist2-within-10.5 px py
                                                     (flvector-ref slxv k) (flvector-ref slyv k)
                                                     (flvector-ref svxv k) (flvector-ref svyv k))
                              2.1025)
                    (set! sc (fl- sc 1000.0)))
                  (sloop (fx+ k 1))))
              (when (fx> naoe 0)
                (let aloop ([k 0])
                  (when (fx< k naoe)
                    (define dx (fl- px (flvector-ref aexv k)))
                    (define dy (fl- py (flvector-ref aeyv k)))
                    (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (flvector-ref aetrv2 k))
                        (set! sc (fl- sc 500.0))
                        (aloop (fx+ k 1))))))
              (when (fx> nl 0)
                (define min-ld2 225.0)
                (let lloop ([k 0])
                  (when (fx< k nl)
                    (define dx (fl- px (flvector-ref lxv k)))
                    (define dy (fl- py (flvector-ref lyv k)))
                    (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                    (when (fl< d2 min-ld2) (set! min-ld2 d2))
                    (lloop (fx+ k 1))))
                ;; Run-through commit flips +20.0*d -> -14.0*d so off-ray steps advance diagonally forward
                (if effective-commit?
                    (set! sc (fl- sc (fl* 14.0 (flsqrt min-ld2))))
                    (set! sc (fl+ sc (fl* 20.0 (flsqrt min-ld2))))))
              (when (fx> ne 0)
                (define min-ed2 225.0)
                (let eloop ([k 0])
                  (when (fx< k ne)
                    (define dx (flabs (fl- px (flvector-ref exv k))))
                    (when (fl< dx 15.0)
                      (define dy (flabs (fl- py (flvector-ref eyv k))))
                      (when (fl< dy 15.0)
                        (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                        (when (fl< d2 min-ed2) (set! min-ed2 d2))))
                    (eloop (fx+ k 1))))
                (if effective-commit?
                    (set! sc (fl- sc (fl* 4.0 (flsqrt min-ed2))))
                    (set! sc (fl+ sc (fl* 8.0 (flsqrt min-ed2))))))
              (when (fl> perp-dot 0.05)
                (set! sc (fl+ sc 2.0)))
              (if effective-commit?
                  sc
                  (let ([hdx (fl- px home-x)]
                        [hdy (fl- py home-y)])
                    (fl- sc (fl* 0.05 (flsqrt (fl+ (fl* hdx hdx) (fl* hdy hdy))))))))

            (define direct-hit (make-vector n #f))
            (define best-seg-idx (make-vector n -1))
            (define best-seg-d2 (make-flvector n 1e9))
            (let sloop ([si 0])
              (when (fx< si nseg)
                (define lx (flvector-ref slxv si))
                (define ly (flvector-ref slyv si))
                (define vx (flvector-ref svxv si))
                (define vy (flvector-ref svyv si))
                (let uloop ([i 0])
                  (when (fx< i n)
                    (define sd2 (seg-dist2-within-10.5 (flvector-ref ax i) (flvector-ref ay i)
                                                       lx ly vx vy))
                    (when (fl<= sd2 1.8225) ; 1.35^2
                      (vector-set! direct-hit i si)
                      (when (fl< sd2 (flvector-ref best-seg-d2 i))
                        (flvector-set! best-seg-d2 i sd2)
                        (vector-set! best-seg-idx i si)))
                    (uloop (fx+ i 1))))
                (sloop (fx+ si 1))))
            (let uloop ([i 0])
              (when (fx< i n)
                (when (fx= (vector-ref best-seg-idx i) -1)
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (let nloop ([j 0])
                    (when (fx< j n)
                      (when (and (not (fx= i j)) (vector-ref direct-hit j))
                        (define dx (flabs (fl- (flvector-ref ax j) ux)))
                        (when (fl<= dx 1.6)
                          (define dy (flabs (fl- (flvector-ref ay j) uy)))
                          (when (and (fl<= dy 1.6)
                                     (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 2.56))
                            (define si (vector-ref direct-hit j))
                            (define lx (flvector-ref slxv si))
                            (define ly (flvector-ref slyv si))
                            (define vx (flvector-ref svxv si))
                            (define vy (flvector-ref svyv si))
                            (define sdx (fl- ux lx))
                            (define sdy (fl- uy ly))
                            (define dl2 (fl+ (fl* sdx sdx) (fl* sdy sdy)))
                            (when (fl<= dl2 110.25)
                              (define proj (fl+ (fl* sdx vx) (fl* sdy vy)))
                              (when (and (fl>= proj -0.5) (fl<= proj 10.5))
                                (define tc (flmax 0.0 (flmin 10.0 proj)))
                                (define rdx (fl- sdx (fl* tc vx)))
                                (define rdy (fl- sdy (fl* tc vy)))
                                (define sd2 (fl+ (fl* rdx rdx) (fl* rdy rdy)))
                                (when (or (fx= (vector-ref best-seg-idx i) -1)
                                          (fl< sd2 (flvector-ref best-seg-d2 i)))
                                  (vector-set! best-seg-idx i si)
                                  (flvector-set! best-seg-d2 i sd2)))))))
                      (nloop (fx+ j 1)))))
                (uloop (fx+ i 1))))
            (let eloop ([i 0])
              (when (fx< i n)
                (define si (vector-ref best-seg-idx i))
                (when (and (not (fx= si -1)) (not (vector-ref acmd i)))
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (define vx (flvector-ref svxv si))
                  (define vy (flvector-ref svyv si))
                  (define n1x (fl- vy))
                  (define n1y vx)
                  (define n2x vy)
                  (define n2y (fl- vx))
                  (define perp (fl+ (fl* (fl- ux (flvector-ref slxv si)) (fl- vy))
                                    (fl* (fl- uy (flvector-ref slyv si)) vx)))
                  (cond
                    [effective-commit?
                     ;; Forward-diagonal step off the 0.5-1.5t spine corridor toward the Lurker
                     (define-values (fx fy) (unit-dir-to ux uy (flvector-ref slxv si) (flvector-ref slyv si)))
                     (define f1x (fl+ (fl* 0.65 fx) (fl* 0.76 n1x)))
                     (define f1y (fl+ (fl* 0.65 fy) (fl* 0.76 n1y)))
                     (define f1m (flmax 0.01 (flsqrt (fl+ (fl* f1x f1x) (fl* f1y f1y)))))
                     (define f2x (fl+ (fl* 0.65 fx) (fl* 0.76 n2x)))
                     (define f2y (fl+ (fl* 0.65 fy) (fl* 0.76 n2y)))
                     (define f2m (flmax 0.01 (flsqrt (fl+ (fl* f2x f2x) (fl* f2y f2y)))))
                     (define p1x (fl+ ux (fl* 2.4 (fl/ f1x f1m))))
                     (define p1y (fl+ uy (fl* 2.4 (fl/ f1y f1m))))
                     (define p2x (fl+ ux (fl* 2.4 (fl/ f2x f2m))))
                     (define p2y (fl+ uy (fl* 2.4 (fl/ f2y f2m))))
                     (define p3x (fl+ ux (fl* 2.5 n1x)))
                     (define p3y (fl+ uy (fl* 2.5 n1y)))
                     (define p4x (fl+ ux (fl* 2.5 n2x)))
                     (define p4y (fl+ uy (fl* 2.5 n2y)))
                     (define s1 (score-lurker-step p1x p1y perp))
                     (define s2 (score-lurker-step p2x p2y (fl- perp)))
                     (define s3 (score-lurker-step p3x p3y perp))
                     (define s4 (score-lurker-step p4x p4y (fl- perp)))
                     (define-values (best-x best-y _)
                       (let ([bx p1x] [by p1y] [bs s1])
                         (when (fl> s2 bs) (set! bx p2x) (set! by p2y) (set! bs s2))
                         (when (fl> s3 bs) (set! bx p3x) (set! by p3y) (set! bs s3))
                         (when (fl> s4 bs) (set! bx p4x) (set! by p4y) (set! bs s4))
                         (values bx by bs)))
                     (vector-set! acmd i
                       (hasheq 'action 'move
                               'unit-id (vector-ref auid i)
                               'role 'commit-run-through-splash-concave
                               'reason 'diagonal-forward-step-off-lurker-spines
                               'target-x best-x
                               'target-y best-y))]
                    [else
                     (define p1x (fl+ ux (fl* 2.5 n1x)))
                     (define p1y (fl+ uy (fl* 2.5 n1y)))
                     (define p2x (fl+ ux (fl* 2.5 n2x)))
                     (define p2y (fl+ uy (fl* 2.5 n2y)))
                     (define s1 (score-lurker-step p1x p1y perp))
                     (define s2 (score-lurker-step p2x p2y (fl- perp)))
                     (define use1? (fl>= s1 s2))
                     (vector-set! acmd i
                       (hasheq 'action 'move
                               'unit-id (vector-ref auid i)
                               'role 'avoid-lurker-linear-spine-splash
                               'reason 'step-perpendicular-out-of-lurker-spines
                               'target-x (if use1? p1x p2x)
                               'target-y (if use1? p1y p2y)))]))
                (eloop (fx+ i 1)))))

          ;; Priority 2: AoE Hazard Effects ('corrosive-bile, 'psionic-storm/'psi-storm, 'nuke/'nuke-persistent)
          (when (pair? aoe-effects)
            ;; Build enemy High Templar / backline target list lazily if committing through Psi Storm
            (define storm-forward-pts
              (if (not effective-commit?)
                  '()
                  (if (pair? enemy-hts)
                      enemy-hts
                      (let ([pts '()])
                        (for ([e (in-list enemy-units)])
                          (when (hash? e)
                            (define raw-hp (or (hash-ref e 'hp #f) (hash-ref e 'health #f)))
                            (when (or (not (real? raw-hp)) (fl> (splash-fl raw-hp 1.0) 0.0))
                              (define et (splash-unit-type e))
                              (unless (or (hash-ref *splash-nova-set* et #f)
                                          (hash-ref *splash-noncombat-or-structure-set* et #f))
                                (define ex (splash-fl (hash-ref e 'x #f) +nan.0))
                                (define ey (splash-fl (hash-ref e 'y #f) +nan.0))
                                (when (and (rational? ex) (rational? ey))
                                  (set! pts (cons (cons ex ey) pts)))))))
                        pts))))
            (let uloop ([i 0])
              (when (fx< i n)
                (unless (vector-ref acmd i)
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (define rx 0.0)
                  (define ry 0.0)
                  (define hit? #f)
                  (define worst-kind #f)
                  (define max-need 0.0)
                  (for ([ae (in-list aoe-effects)])
                    (define ex (vector-ref ae 1))
                    (define ey (vector-ref ae 2))
                    (define er (vector-ref ae 3))
                    (define tr (vector-ref ae 4))
                    (define dx (fl- ux ex))
                    (define dy (fl- uy ey))
                    (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                    (when (fl<= d2 (fl* tr tr))
                      (set! hit? #t)
                      (set! worst-kind (vector-ref ae 0))
                      (define d (flsqrt d2))
                      (define need (fl- (fl+ er 1.2) d))
                      (when (fl> need max-need) (set! max-need need))
                      (define w (fl+ 1.0 (flmax 0.0 (fl- tr d))))
                      (if (fl> d 0.01)
                          (begin
                            (set! rx (fl+ rx (fl* w (fl/ dx d))))
                            (set! ry (fl+ ry (fl* w (fl/ dy d)))))
                          (let* ([hx (fl- home-x ux)]
                                 [hy (fl- home-y uy)]
                                 [hd (flsqrt (fl+ (fl* hx hx) (fl* hy hy)))])
                            (if (fl> hd 0.05)
                                (begin
                                  (set! rx (fl+ rx (fl/ hx hd)))
                                  (set! ry (fl+ ry (fl/ hy hd))))
                                (set! rx (fl+ rx 1.0)))))))
                  (when hit?
                    (cond
                      [(and effective-commit?
                            (memq worst-kind '(psionic-storm psi-storm))
                            (pair? storm-forward-pts))
                       ;; Step 2.2t forward-perpendicular through 1.5r Storm onto HTs/backline
                       (define best-pt (car storm-forward-pts))
                       (define best-d2 1e9)
                       (for ([pt (in-list storm-forward-pts)])
                         (define dx (fl- (car pt) ux))
                         (define dy (fl- (cdr pt) uy))
                         (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                         (when (fl< d2 best-d2)
                           (set! best-d2 d2)
                           (set! best-pt pt)))
                       (define fd (flsqrt best-d2))
                       (define-values (fx fy)
                         (if (fl> fd 0.05)
                             (values (fl/ (fl- (car best-pt) ux) fd)
                                     (fl/ (fl- (cdr best-pt) uy) fd))
                             (values 1.0 0.0)))
                       (define p1x (fl- fy))
                       (define p1y fx)
                       (define rdot (fl+ (fl* rx p1x) (fl* ry p1y)))
                       (define psign
                         (cond
                           [(fl> rdot 0.05) 1.0]
                           [(fl< rdot -0.05) -1.0]
                           [(fx= (remainder i 2) 0) 1.0]
                           [else -1.0]))
                       (define bx (fl+ (fl* 0.80 fx) (fl* 0.55 (fl* psign p1x))))
                       (define by (fl+ (fl* 0.80 fy) (fl* 0.55 (fl* psign p1y))))
                       (define bmag (flmax 0.01 (flsqrt (fl+ (fl* bx bx) (fl* by by)))))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'commit-run-through-splash-concave
                                 'reason 'push-forward-through-psi-storm
                                 'target-x (fl+ ux (fl* 2.2 (fl/ bx bmag)))
                                 'target-y (fl+ uy (fl* 2.2 (fl/ by bmag)))))]
                      [else
                       (define rmag (flsqrt (fl+ (fl* rx rx) (fl* ry ry))))
                       (define-values (ux-m uy-m)
                         (if (fl> rmag 0.01)
                             (values (fl/ rx rmag) (fl/ ry rmag))
                             (values 1.0 0.0)))
                       (define step (flmin 4.5 (flmax 2.3 max-need)))
                       (define reason-sym
                         (cond
                           [(eq? worst-kind 'corrosive-bile) 'evade-corrosive-bile]
                           [(memq worst-kind '(nuke nuke-persistent)) 'evade-nuke-zone]
                           [else 'evade-psionic-storm]))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'avoid-aoe-splash-effect
                                 'reason reason-sym
                                 'target-x (fl+ ux (fl* step ux-m))
                                 'target-y (fl+ uy (fl* step uy-m))))])))
                (uloop (fx+ i 1)))))

          ;; Priority 3: Ready vs Cooldown Enemy Disruptor Speed-Aware Standoff / Commit Split Dive
          (when (pair? enemy-disruptors)
            (define nd (length enemy-disruptors))
            (define dxv (make-flvector nd 0.0))
            (define dyv (make-flvector nd 0.0))
            (define dcdv (make-vector nd #f))
            (let fill-d ([xs enemy-disruptors] [k 0])
              (unless (null? xs)
                (define item (car xs))
                (flvector-set! dxv k (vector-ref item 0))
                (flvector-set! dyv k (vector-ref item 1))
                (vector-set! dcdv k (vector-ref item 2))
                (fill-d (cdr xs) (fx+ k 1))))
            (let uloop ([i 0])
              (when (fx< i n)
                (unless (vector-ref acmd i)
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (define best-ri -1)
                  (define best-rd2 1e9)
                  (define best-ai -1)
                  (define best-ad2 1e9)
                  (let kloop ([k 0])
                    (when (fx< k nd)
                      (define dx (fl- ux (flvector-ref dxv k)))
                      (when (fl<= (flabs dx) 15.5)
                        (define dy (fl- uy (flvector-ref dyv k)))
                        (when (fl<= (flabs dy) 15.5)
                          (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                          (when (fl<= d2 240.25) ; 15.5^2
                            (when (or (fx= best-ai -1) (fl< d2 best-ad2))
                              (set! best-ad2 d2)
                              (set! best-ai k))
                            (unless (vector-ref dcdv k)
                              (when (or (fx= best-ri -1) (fl< d2 best-rd2))
                                (set! best-rd2 d2)
                                (set! best-ri k))))))
                      (kloop (fx+ k 1))))
                  (unless (fx= best-ai -1)
                    (define sep-x 0.0)
                    (define sep-y 0.0)
                    (define nbr-cnt 0)
                    (let jloop ([j 0])
                      (when (fx< j n)
                        (unless (fx= i j)
                          (define dx (fl- ux (flvector-ref ax j)))
                          (when (fl< (flabs dx) 2.8)
                            (define dy (fl- uy (flvector-ref ay j)))
                            (when (fl< (flabs dy) 2.8)
                              (define nd2 (fl+ (fl* dx dx) (fl* dy dy)))
                              (when (fl< nd2 7.84)
                                (set! nbr-cnt (fx+ nbr-cnt 1))
                                (if (fl> nd2 0.0001)
                                    (let* ([nd (flsqrt nd2)]
                                           [w (fl/ 1.0 (flmax 0.3 nd))])
                                      (set! sep-x (fl+ sep-x (fl* w (fl/ dx nd))))
                                      (set! sep-y (fl+ sep-y (fl* w (fl/ dy nd)))))
                                    (let ([s (if (fx< i j) -1.0 1.0)])
                                      (set! sep-x (fl+ sep-x s))))))))
                        (jloop (fx+ j 1))))
                    (define clumped? (fx>= nbr-cnt 1))
                    (define catch-r (fast-disruptor-nova-catchable-range (flvector-ref aspd i) clumped? #t))
                    (define rd (if (fx= best-ri -1) 999.0 (flsqrt best-rd2)))
                    (define ad (flsqrt best-ad2))
                    (cond
                      [(and (not effective-commit?)
                            (not (fx= best-ri -1))
                            (fl<= rd catch-r))
                       (define rdx (flvector-ref dxv best-ri))
                       (define rdy (flvector-ref dyv best-ri))
                       (define-values (rx ry)
                         (if (fl> rd 0.05)
                             (values (fl/ (fl- ux rdx) rd) (fl/ (fl- uy rdy) rd))
                             (values -1.0 0.0)))
                       (define smag (flsqrt (fl+ (fl* sep-x sep-x) (fl* sep-y sep-y))))
                       (define-values (mx my)
                         (if (and clumped? (fl> smag 0.01))
                             (let* ([sux (fl/ sep-x smag)]
                                    [suy (fl/ sep-y smag)]
                                    [bx (fl+ (fl* 0.72 rx) (fl* 0.45 sux))]
                                    [by (fl+ (fl* 0.72 ry) (fl* 0.45 suy))]
                                    [bm (flmax 0.01 (flsqrt (fl+ (fl* bx bx) (fl* by by))))])
                               (values (fl/ bx bm) (fl/ by bm)))
                             (values rx ry)))
                       (define step (flmax 2.2 (flmin 5.0 (fl- (fl+ catch-r 0.45) rd))))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'avoid-disruptor-nova-catchable-range
                                 'reason 'standoff-outside-catchable-nova-range
                                 'target-x (fl+ ux (fl* step mx))
                                 'target-y (fl+ uy (fl* step my))))]
                      [(and (fl<= ad 15.0)
                            (or effective-commit?
                                (and (vector-ref dcdv best-ai)
                                     (or (fx= best-ri -1) (fl<= ad 7.5)))))
                       (define ex (flvector-ref dxv best-ai))
                       (define ey (flvector-ref dyv best-ai))
                       (define-values (fx fy)
                         (if (fl> ad 0.05)
                             (values (fl/ (fl- ex ux) ad) (fl/ (fl- ey uy) ad))
                             (values 1.0 0.0)))
                       (define px (fl- fy))
                       (define py fx)
                       (define smag (flsqrt (fl+ (fl* sep-x sep-x) (fl* sep-y sep-y))))
                       (define-values (sux suy)
                         (if (fl> smag 0.01)
                             (let* ([sx (fl/ sep-x smag)]
                                    [sy (fl/ sep-y smag)]
                                    ;; Project slightly off backward so units split laterally >= 2.8t while diving
                                    [fdot (fl+ (fl* sx fx) (fl* sy fy))]
                                    [lx (fl- sx (fl* (flmin 0.0 fdot) fx))]
                                    [ly (fl- sy (fl* (flmin 0.0 fdot) fy))]
                                    [lm (flsqrt (fl+ (fl* lx lx) (fl* ly ly)))])
                               (if (fl> lm 0.05)
                                   (values (fl/ lx lm) (fl/ ly lm))
                                   (let ([s (if (fx= (remainder i 2) 0) 1.0 -1.0)])
                                     (values (fl* s px) (fl* s py)))))
                             (let ([s (if (fx= (remainder i 2) 0) 1.0 -1.0)])
                               (values (fl* s px) (fl* s py)))))
                       (define bx (fl+ (fl* 0.75 fx) (fl* 0.65 sux)))
                       (define by (fl+ (fl* 0.75 fy) (fl* 0.65 suy)))
                       (define bm (flmax 0.01 (flsqrt (fl+ (fl* bx bx) (fl* by by)))))
                       (define step (flmax 2.2 (flmin 3.8 (fl- ad 1.5))))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'commit-run-through-disruptor-split
                                 'reason (if (vector-ref dcdv best-ai)
                                             'cooldown-punish-dive-split
                                             'commit-run-through-disruptor-split)
                                 'target-x (fl+ ux (fl* step (fl/ bx bm)))
                                 'target-y (fl+ uy (fl* step (fl/ by bm)))))])))
                (uloop (fx+ i 1)))))

          ;; Priority 4: Enemy Colossus (`9.0` ETL / `7.0` base) Standoff vs Radial/Depth-Staggered Split Dive
          (when (pair? enemy-colossi)
            (define nc (length enemy-colossi))
            (define cxv (make-flvector nc 0.0))
            (define cyv (make-flvector nc 0.0))
            (define crv (make-flvector nc 8.5))
            (let fill-c ([xs enemy-colossi] [k 0])
              (unless (null? xs)
                (define item (car xs))
                (flvector-set! cxv k (vector-ref item 0))
                (flvector-set! cyv k (vector-ref item 1))
                (flvector-set! crv k (vector-ref item 2))
                (fill-c (cdr xs) (fx+ k 1))))
            (let uloop ([i 0])
              (when (fx< i n)
                (unless (vector-ref acmd i)
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (define best-cd2 1e9)
                  (define best-ci -1)
                  (let cloop ([k 0])
                    (when (fx< k nc)
                      (define dx (fl- ux (flvector-ref cxv k)))
                      (when (fl<= (flabs dx) 11.0)
                        (define dy (fl- uy (flvector-ref cyv k)))
                        (when (fl<= (flabs dy) 11.0)
                          (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                          (when (and (fl<= d2 114.49) ; 10.7^2
                                     (or (fx= best-ci -1) (fl< d2 best-cd2)))
                            (set! best-cd2 d2)
                            (set! best-ci k))))
                      (cloop (fx+ k 1))))
                  (unless (fx= best-ci -1)
                    (define cx (flvector-ref cxv best-ci))
                    (define cy (flvector-ref cyv best-ci))
                    (define standoff-r (flvector-ref crv best-ci))
                    (define d (flsqrt best-cd2))
                    (define-values (rx ry)
                      (if (fl> d 0.05)
                          (values (fl/ (fl- ux cx) d) (fl/ (fl- uy cy) d))
                          (values 1.0 0.0)))
                    (cond
                      [(and (not effective-commit?) (fl> d 5.5) (fl<= d standoff-r))
                       (define step (flmax 2.0 (flmin 5.2 (fl- (fl+ standoff-r 0.4) d))))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'avoid-colossus-sweep-standoff
                                 'reason (if (fl> standoff-r 9.0)
                                             'standoff-outside-colossus-etl-range
                                             'standoff-outside-colossus-base-range)
                                 'target-x (fl+ ux (fl* step rx))
                                 'target-y (fl+ uy (fl* step ry))))]
                      [(and (or effective-commit? (fl<= d 5.5)) (fl<= d (fl+ standoff-r 0.4)))
                       ;; Radial/depth-staggered split avoiding 3.0t perpendicular sweep strips + dive <= 3.5-5.0t
                       (define px (fl- ry))
                       (define py rx)
                       (define sweep-lat 0.0)
                       (define sweep-rad 0.0)
                       (let nloop ([j 0])
                         (when (fx< j n)
                           (unless (fx= i j)
                             (define dx (fl- ux (flvector-ref ax j)))
                             (when (fl<= (flabs dx) 3.2)
                               (define dy (fl- uy (flvector-ref ay j)))
                               (when (fl<= (flabs dy) 3.2)
                                 (define drad (fl+ (fl* dx rx) (fl* dy ry)))
                                 (define dlat (fl+ (fl* dx px) (fl* dy py)))
                                 (when (and (fl<= (flabs drad) 0.95) (fl<= (flabs dlat) 1.85))
                                   (define lsign (cond [(fl> dlat 0.05) 1.0]
                                                       [(fl< dlat -0.05) -1.0]
                                                       [(fx< i j) -1.0]
                                                       [else 1.0]))
                                   (define rsign (cond [(fl> drad 0.05) 1.0]
                                                       [(fl< drad -0.05) -1.0]
                                                       [(fx= (remainder i 2) 0) -1.0]
                                                       [else 1.0]))
                                   (set! sweep-lat (fl+ sweep-lat lsign))
                                   (set! sweep-rad (fl+ sweep-rad rsign))))))
                           (nloop (fx+ j 1))))
                       ;; Alternating radial depth tier (3.2 vs 4.6) + angular fan around Colossus
                       (define r-target (if (fx= (remainder i 2) 0) 3.1 4.6))
                       (define fan-sign
                         (cond
                           [(fl> sweep-lat 0.1) 1.0]
                           [(fl< sweep-lat -0.1) -1.0]
                           [else (case (remainder i 3) [(0) 0.0] [(1) 1.0] [else -1.0])]))
                       (define depth-offset
                         (cond
                           [(fl> sweep-rad 0.1) 0.7]
                           [(fl< sweep-rad -0.1) -0.7]
                           [else 0.0]))
                       (define r-goal (flmax 2.0 (flmin 4.9 (fl+ r-target depth-offset))))
                       (define fx-goal (fl+ rx (fl* (fl* 0.55 fan-sign) px)))
                       (define fy-goal (fl+ ry (fl* (fl* 0.55 fan-sign) py)))
                       (define fmag (flmax 0.01 (flsqrt (fl+ (fl* fx-goal fx-goal) (fl* fy-goal fy-goal)))))
                       (define gx (fl+ cx (fl* r-goal (fl/ fx-goal fmag))))
                       (define gy (fl+ cy (fl* r-goal (fl/ fy-goal fmag))))
                       (define mvx (fl- gx ux))
                       (define mvy (fl- gy uy))
                       (define mdist (flsqrt (fl+ (fl* mvx mvx) (fl* mvy mvy))))
                       (define-values (tx ty)
                         (if (fl<= mdist 4.2)
                             (values gx gy)
                             (values (fl+ ux (fl* 4.2 (fl/ mvx mdist)))
                                     (fl+ uy (fl* 4.2 (fl/ mvy mdist))))))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'colossus-radial-split-dive
                                 'reason 'radial-depth-stagger-and-dive-inside-colossus-sweep
                                 'target-x tx
                                 'target-y ty))])))
                (uloop (fx+ i 1)))))

          ;; Priority 5: Siege Tank Deadzone Dive + Lateral Split (standoff) / Forward-Diagonal Push (commit)
          (when (pair? sieged-tanks)
            (define nt (length sieged-tanks))
            (define txv (make-flvector nt 0.0))
            (define tyv (make-flvector nt 0.0))
            (let fill-t ([xs sieged-tanks] [k 0])
              (unless (null? xs)
                (flvector-set! txv k (caar xs))
                (flvector-set! tyv k (cdar xs))
                (fill-t (cdr xs) (fx+ k 1))))
            (let uloop ([i 0])
              (when (fx< i n)
                (unless (vector-ref acmd i)
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (define best-td2 1e9)
                  (define best-ti -1)
                  (let tloop ([k 0])
                    (when (fx< k nt)
                      (define dx (fl- ux (flvector-ref txv k)))
                      (when (fl<= (flabs dx) 13.85)
                        (define dy (fl- uy (flvector-ref tyv k)))
                        (when (fl<= (flabs dy) 13.85)
                          (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                          (when (and (fl<= d2 190.44) ; 13.8^2
                                     (or (fx= best-ti -1) (fl< d2 best-td2)))
                            (set! best-td2 d2)
                            (set! best-ti k))))
                      (tloop (fx+ k 1))))
                  (unless (fx= best-ti -1)
                    (define sx (flvector-ref txv best-ti))
                    (define sy (flvector-ref tyv best-ti))
                    (define d (flsqrt best-td2))
                    (cond
                      [(and (vector-ref adive i) (fl>= d 2.0) (fl<= d 3.8))
                       (define rx (fl/ (fl- ux sx) d))
                       (define ry (fl/ (fl- uy sy) d))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'siege-tank-deadzone-dive
                                 'reason 'enter-siege-tank-min-range-deadzone
                                 'target-x (fl+ sx (fl* 1.1 rx))
                                 'target-y (fl+ sy (fl* 1.1 ry))))]
                      [(and effective-commit? (fl> d 3.8) (fl<= d 13.8))
                       ;; Disable pure sideways shuffle; forward-diagonal push straight into < 3.5 deadzone
                       (define fx (fl/ (fl- sx ux) d))
                       (define fy (fl/ (fl- sy uy) d))
                       (define p1x (fl- fy))
                       (define p1y fx)
                       (define sep-x 0.0)
                       (define sep-y 0.0)
                       (define has-nbr? #f)
                       (let nloop ([j 0])
                         (when (fx< j n)
                           (unless (fx= i j)
                             (define dx (fl- ux (flvector-ref ax j)))
                             (when (fl<= (flabs dx) 1.85)
                               (define dy (fl- uy (flvector-ref ay j)))
                               (when (fl<= (flabs dy) 1.85)
                                 (define nd2 (fl+ (fl* dx dx) (fl* dy dy)))
                                 (when (fl<= nd2 3.4225)
                                   (set! has-nbr? #t)
                                   (when (fl> nd2 0.0001)
                                     (let* ([nd (flsqrt nd2)]
                                            [w (fl/ 1.0 (flmax 0.25 nd))])
                                       (set! sep-x (fl+ sep-x (fl* w (fl/ dx nd))))
                                       (set! sep-y (fl+ sep-y (fl* w (fl/ dy nd))))))))))
                           (nloop (fx+ j 1))))
                       (define-values (lx ly)
                         (if has-nbr?
                             (let* ([pdot (fl+ (fl* sep-x p1x) (fl* sep-y p1y))]
                                    [sign (cond
                                            [(fl> pdot 0.05) 1.0]
                                            [(fl< pdot -0.05) -1.0]
                                            [(fx= (remainder i 2) 0) 1.0]
                                            [else -1.0])])
                               (values (fl* sign p1x) (fl* sign p1y)))
                             (let ([sign (if (fx= (remainder i 2) 0) 1.0 -1.0)])
                               (values (fl* 0.55 (fl* sign p1x))
                                       (fl* 0.55 (fl* sign p1y))))))
                       (define bx (fl+ (fl* 0.75 fx) (fl* 0.45 lx)))
                       (define by (fl+ (fl* 0.75 fy) (fl* 0.45 ly)))
                       (define bmag (flmax 0.01 (flsqrt (fl+ (fl* bx bx) (fl* by by)))))
                       (define step (flmax 2.3 (flmin 3.8 (fl- d 2.2))))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'commit-run-through-splash-concave
                                 'reason 'forward-diagonal-push-into-tank-deadzone
                                 'target-x (fl+ ux (fl* step (fl/ bx bmag)))
                                 'target-y (fl+ uy (fl* step (fl/ by bmag)))))]
                      [(and (not effective-commit?) (fl> d 3.8) (fl<= d 13.5))
                       (define sep-x 0.0)
                       (define sep-y 0.0)
                       (define has-nbr? #f)
                       (let nloop ([j 0])
                         (when (fx< j n)
                           (unless (fx= i j)
                             (define dx (fl- ux (flvector-ref ax j)))
                             (when (fl<= (flabs dx) 1.85)
                               (define dy (fl- uy (flvector-ref ay j)))
                               (when (fl<= (flabs dy) 1.85)
                                 (define nd2 (fl+ (fl* dx dx) (fl* dy dy)))
                                 (when (fl<= nd2 3.4225)
                                   (set! has-nbr? #t)
                                   (if (fl> nd2 0.0001)
                                       (let* ([nd (flsqrt nd2)]
                                              [w (fl/ 1.0 (flmax 0.25 nd))])
                                         (set! sep-x (fl+ sep-x (fl* w (fl/ dx nd))))
                                         (set! sep-y (fl+ sep-y (fl* w (fl/ dy nd)))))
                                       (let ([ang (if (fx< i j) 0.0 3.14159265)])
                                         (set! sep-x (fl+ sep-x (cos ang)))
                                         (set! sep-y (fl+ sep-y (sin ang)))))))))
                           (nloop (fx+ j 1))))
                       (when has-nbr?
                         (define kx (fl/ (fl- ux sx) d))
                         (define ky (fl/ (fl- uy sy) d))
                         (define p1x (fl- ky))
                         (define p1y kx)
                         (define smag (flsqrt (fl+ (fl* sep-x sep-x) (fl* sep-y sep-y))))
                         (define-values (sux suy)
                           (if (fl> smag 0.01)
                               (values (fl/ sep-x smag) (fl/ sep-y smag))
                               (let ([sign (if (fx= (remainder i 2) 0) 1.0 -1.0)])
                                 (values (fl* sign p1x) (fl* sign p1y)))))
                         (define dot1 (fl+ (fl* sux p1x) (fl* suy p1y)))
                         (define sign-perp
                           (cond
                             [(fl> (flabs dot1) 0.05) (if (fl>= dot1 0.0) 1.0 -1.0)]
                             [else
                              (define hdot (fl+ (fl* (fl- home-x ux) p1x) (fl* (fl- home-y uy) p1y)))
                              (if (fl>= hdot 0.0) 1.0 -1.0)]))
                         (define px (fl* sign-perp p1x))
                         (define py (fl* sign-perp p1y))
                         (define bx (fl+ (fl* 0.35 sux) (fl* 0.65 px)))
                         (define by (fl+ (fl* 0.35 suy) (fl* 0.65 py)))
                         (define bmag (flsqrt (fl+ (fl* bx bx) (fl* by by))))
                         (define-values (mx my)
                           (if (fl> bmag 0.01)
                               (values (fl/ bx bmag) (fl/ by bmag))
                               (values px py)))
                         (vector-set! acmd i
                           (hasheq 'action 'move
                                   'unit-id (vector-ref auid i)
                                   'role 'avoid-siege-tank-splash-split
                                   'reason 'pre-split-against-siege-tank-splash
                                   'target-x (fl+ ux (fl* 2.3 mx))
                                   'target-y (fl+ uy (fl* 2.3 my)))))]
                      [(and (not effective-commit?) (fl> d 13.5) (fl<= d 13.8))
                       (define rx (fl/ (fl- ux sx) d))
                       (define ry (fl/ (fl- uy sy) d))
                       (define step (flmax 1.5 (fl- 13.95 d)))
                       (vector-set! acmd i
                         (hasheq 'action 'move
                                 'unit-id (vector-ref auid i)
                                 'role 'avoid-siege-tank-standoff-edge
                                 'reason 'hold-outside-siege-tank-13.8-range
                                 'target-x (fl+ ux (fl* step rx))
                                 'target-y (fl+ uy (fl* step ry))))])))
                (uloop (fx+ i 1)))))

          ;; Priority 5b: Burrowed Lurker Non-Commit Standoff Hold (>= 9.5 base / >= 11.5 Seismic)
          (when (and (not effective-commit?) (pair? burrowed-lurkers))
            (define nl (length burrowed-lurkers))
            (define blxv (make-flvector nl 0.0))
            (define blyv (make-flvector nl 0.0))
            (let fill-bl ([xs burrowed-lurkers] [k 0])
              (unless (null? xs)
                (flvector-set! blxv k (caar xs))
                (flvector-set! blyv k (cdar xs))
                (fill-bl (cdr xs) (fx+ k 1))))
            (define standoff-r (if has-seismic-lurker? 11.5 9.5))
            (define standoff-r2 (fl* standoff-r standoff-r))
            (let uloop ([i 0])
              (when (fx< i n)
                (unless (vector-ref acmd i)
                  (define ux (flvector-ref ax i))
                  (define uy (flvector-ref ay i))
                  (define best-d2 1e9)
                  (define best-k -1)
                  (let kloop ([k 0])
                    (when (fx< k nl)
                      (define dx (fl- ux (flvector-ref blxv k)))
                      (when (fl<= (flabs dx) standoff-r)
                        (define dy (fl- uy (flvector-ref blyv k)))
                        (when (fl<= (flabs dy) standoff-r)
                          (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                          (when (and (fl<= d2 standoff-r2)
                                     (or (fx= best-k -1) (fl< d2 best-d2)))
                            (set! best-d2 d2)
                            (set! best-k k))))
                      (kloop (fx+ k 1))))
                  (unless (fx= best-k -1)
                    (define d (flsqrt best-d2))
                    (define lx (flvector-ref blxv best-k))
                    (define ly (flvector-ref blyv best-k))
                    (define-values (rx ry)
                      (if (fl> d 0.05)
                          (values (fl/ (fl- ux lx) d) (fl/ (fl- uy ly) d))
                          (values -1.0 0.0)))
                    (define step (flmax 1.8 (flmin 4.8 (fl- (fl+ standoff-r 0.35) d))))
                    (vector-set! acmd i
                      (hasheq 'action 'move
                              'unit-id (vector-ref auid i)
                              'role 'avoid-lurker-standoff-range
                              'reason 'hold-outside-lurker-standoff-range
                              'target-x (fl+ ux (fl* step rx))
                              'target-y (fl+ uy (fl* step ry))))))
                (uloop (fx+ i 1)))))

          (let collect ([i (fx- n 1)] [acc '()])
            (if (fx< i 0)
                acc
                (let ([c (vector-ref acmd i)])
                  (collect (fx- i 1) (if c (cons c acc) acc)))))])])))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [fast-units-have-any-type? (-> (Listof Any) (Listof Symbol) Boolean)]
  [fast-counter-burrow-needed?
   (-> Any (HashTable Integer (Pairof Flonum Flonum)) (Listof Any)
       (Listof Symbol) (Listof Symbol) (Listof Symbol)
       Integer
       Boolean)]
  [fast-counter-burrow-preflight
   (-> Any (HashTable Integer (Pairof Flonum Flonum)) (Listof Any)
       (Listof Symbol) (Listof Symbol) (Listof Symbol)
       Integer
       (Values Boolean Any (Listof Any) (Listof Any) (Listof Any) (Listof Any) (Listof Any)
               Boolean Boolean Boolean Boolean Boolean))]
  [fast-dodge-obs-header
   (-> Any Flonum Flonum
       (Values Integer (Listof Any) Boolean Boolean Flonum Flonum
               (Listof Any) (Listof Any) (Listof Any) (Listof Any) (Listof Any)))]
  [fast-extract-burrow-allies
   (-> (Listof Any) (Listof Symbol) (Listof Symbol) Flonum Flonum
       (Listof (Vector Any Any Integer Symbol Flonum Flonum Flonum Flonum Boolean)))]
  [fast-unit-revealed? (-> Any Boolean)]
  [fast-dodge-fallback-state (-> Any Integer Boolean Flonum (Values Flonum Integer Integer))]
  [fast-build-enemy-detectors
   (-> (Listof Any) (Listof Any) (Listof Any) (Listof Any) (Listof Any)
       (Listof Symbol) (Listof Symbol) (Listof Symbol) Flonum
       (Values FlVector Fixnum))]
  [fast-build-enemy-xy (-> (Listof Any) (Listof Symbol) (Values FlVector Fixnum))]
  [fast-flvec-det-within? (-> FlVector Fixnum Flonum Flonum Flonum Boolean)]
  [fast-flvec-xy-within? (-> FlVector Fixnum Flonum Flonum Flonum Boolean)]
  [fast-disruptor-nova-catchable-range (-> Real Boolean Boolean Flonum)]
  [fast-should-commit-through-splash?
   (-> (Listof Any) (Listof Any) Any (Option Real) Boolean (Option Real) Boolean)]
  [fast-plan-avoid-siege-tank-and-lurker-splash-zones
   (-> (Listof Any) (Listof Any) (Listof Any) Flonum Flonum
       Boolean (Listof Any) Any Flonum
       (Listof (Immutable-HashTable Symbol Any)))])

(provide
 ZERG-UNIT-BURROW-DOWN-ABILITY-TABLE
 zerg-innate-burrower-sym?
 zerg-unit-type->burrow-ability-id
 zerg-burrow-upgrade-researched?
 zerg-unit-burrow-allowed?
 zerg-unit-burrowed?
 execute-roach-tunneling-burrow-micro
 execute-infestor-burrow-cast-micro
 lurker-burrow-action
 drone-evade-burrow-action
 (struct-out burrow-dodge-state)
 (struct-out burrow-dodge-tracker)
 make-burrow-dodge-tracker
 execute-zerg-reactive-burrow-dodge-micro
 execute-stationary-detection-ring-ambush-micro
 (struct-out CounterBurrowPlan)
 plan-counter-burrow-response
 plan-burrowed-zergling-expansion-blocks
 plan-clear-own-expansion-block-for-build
 disruptor-nova-catchable-range
 should-commit-through-splash?
 plan-avoid-siege-tank-and-lurker-splash-zones)

;; Exact unit-type -> Burrow*Down SC2 wire ability ID (Bug 8c: never broadcast generic `3661` across mixed units).
(: ZERG-UNIT-BURROW-DOWN-ABILITY-TABLE (Immutable-HashTable Symbol Integer))
(define ZERG-UNIT-BURROW-DOWN-ABILITY-TABLE
  (hasheq
   'zergling       1390
   'baneling       1374
   'drone          1378
   'roach          1386
   'hydralisk      1382
   'infestor       1444
   'lurker         2108
   'lurker-mp      2108
   'queen          1433
   'ravager        2340
   'swarm-host     2014
   'swarm-host-mp  2014
   'widow-mine     2095))

(: zerg-innate-burrower-sym? (-> Any Boolean))
(define (zerg-innate-burrower-sym? ut)
  (not (not (memq ut '(lurker lurker-mp swarm-host swarm-host-mp widow-mine)))))

(: zerg-unit-type->burrow-ability-id (-> Any (Option Integer)))
(define (zerg-unit-type->burrow-ability-id ut)
  (and (symbol? ut)
       (hash-ref ZERG-UNIT-BURROW-DOWN-ABILITY-TABLE ut (lambda () #f))))

;; Returns `#t` iff `burrow` (or `tunneling-claws`) is explicitly researched in `obs` (never `#t` by omission).
(: zerg-burrow-upgrade-researched? (-> Any Boolean))
(define (zerg-burrow-upgrade-researched? obs)
  (if (not (hash? obs))
      #f
      (let ([flag (dyn-hash-ref obs 'burrow-researched? 'unset)])
        (if (boolean? flag)
            flag
            (let ([upgrades (let ([v (dyn-hash-ref obs 'researched-upgrades '())])
                              (if (list? v) v '()))])
              (not (not (or (memq 'burrow upgrades)
                            (memq 'burrow-upgrade upgrades)
                            (memq 'tunneling-claws upgrades)
                            (memv 64 upgrades)))))))))

(: zerg-unit-burrow-allowed? (-> Any Boolean Boolean))
(define (zerg-unit-burrow-allowed? ut burrow-researched?)
  (and (zerg-unit-type->burrow-ability-id ut)
       (or burrow-researched?
           (zerg-innate-burrower-sym? ut))))

(: zerg-unit-burrowed? (-> Any Symbol Boolean))
(define (zerg-unit-burrowed? u burrowed-type)
  (define utype (dyn-hash-ref u 'type 'unknown))
  (not (not (or (eq? utype burrowed-type)
                (dyn-hash-ref u 'burrowed #f)
                (dyn-hash-ref u 'is-burrowed? #f)))))

(: nearest-enemy-and-dist (-> Flonum Flonum (Listof Any) (Values Any Flonum)))
(define (nearest-enemy-and-dist ux uy enemy-units)
  (for/fold ([best-e : Any #f]
             [best-d : Flonum 999.0])
            ([e (in-list enemy-units)]
             #:when (hash? e))
    (define ex (safe-real (dyn-hash-ref e 'x 160.0) 160.0))
    (define ey (safe-real (dyn-hash-ref e 'y 160.0) 160.0))
    (define d (dist2d ux uy ex ey))
    (if (< d best-d)
        (values e d)
        (values best-e best-d))))

(: units-have-any-type? (-> (Listof Any) (Listof Symbol) Boolean))
(define (units-have-any-type? units syms)
  (fast-units-have-any-type? units syms))

(: obs-has-unit-type? (-> Any Symbol (Listof Any) (Listof Symbol) Boolean))
(define (obs-has-unit-type? obs by-type-key units syms)
  (define by-type (dyn-hash-ref obs by-type-key #f))
  (if (and (hash? by-type) (> (hash-count by-type) 0))
      (for/or : Boolean ([s (in-list syms)])
        (define v (dyn-hash-ref by-type s #f))
        (or (pair? v) (and (real? v) (> v 0))))
      (units-have-any-type? units syms)))

;; Burrowed Roach (`TunnelingClaws`) movement & regeneration micro:
;; - When Roach HP ratio <= `SC2-ROACH-BURROW-HP-PCT-THRESH` (0.38) and Burrow is
;;   researched: burrow down (`burrow-down`) and tunnel-move toward `base-x, base-y`
;;   (`roach-tunnel-move`) if `tunneling-claws` is researched.
;; - When Burrowed Roach HP ratio >= `SC2-ROACH-UNBURROW-HP-PCT-THRESH` (0.82):
;;   unburrow (`burrow-up`) to re-engage.
(: execute-roach-tunneling-burrow-micro (-> Any (Listof (Listof Any))))
(define (execute-roach-tunneling-burrow-micro obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-raw (dyn-hash-ref sanitized-obs 'ally-units '()))
  (define ally-units : (Listof Any) (if (list? ally-raw) ally-raw '()))
  (cond
    [(not (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units '(roach roach-burrowed)))
     '()]
    [else
     (define upgrades-raw (dyn-hash-ref sanitized-obs 'researched-upgrades '()))
     (define upgrades : (Listof Any) (if (list? upgrades-raw) upgrades-raw '()))
     (define has-burrow? : Boolean
       (zerg-burrow-upgrade-researched? sanitized-obs))
     (define has-tunneling? : Boolean
       (or (not (not (dyn-hash-ref sanitized-obs 'tunneling-claws? #f)))
           (not (not (memq 'tunneling-claws upgrades)))))
     (define base-x (safe-exact-int (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32))
     (define base-y (safe-exact-int (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32))
     (define enemy-raw (dyn-hash-ref sanitized-obs 'enemy-units '()))
     (define enemy-units : (Listof Any) (if (list? enemy-raw) enemy-raw '()))
     (define actions : (Listof (Listof Any)) '())
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     (when has-burrow?
       (for ([u (in-list ally-units)]
             #:when (and (hash? u)
                         (memq (dyn-hash-ref u 'type 'unknown) '(roach roach-burrowed))))
         (define uid (dyn-hash-ref u 'id 0))
         (define burrowed? (zerg-unit-burrowed? u 'roach-burrowed))
         (define hp (max 1.0 (safe-real (dyn-hash-ref u 'hp 145.0) 145.0)))
         (define max-hp (max 1.0 (safe-real (dyn-hash-ref u 'max-hp 145.0) 145.0)))
         (define hp-pct (/ hp max-hp))
         (define ux (safe-real (dyn-hash-ref u 'x base-x) base-x))
         (define uy (safe-real (dyn-hash-ref u 'y base-y) base-y))
         (define-values (nearest-e dist-e) (nearest-enemy-and-dist ux uy enemy-units))
         (cond
           [(and (not burrowed?)
                 (<= hp-pct SC2-ROACH-BURROW-HP-PCT-THRESH)
                 (<= dist-e 12.0))
            (emit! (list 'burrow-down uid 'roach-regen-escape 1386))
            (when has-tunneling?
              (define-values (kx ky)
                (if nearest-e
                    (compute-kite-vector (exact-round ux) (exact-round uy)
                                         (safe-exact-int (dyn-hash-ref nearest-e 'x 160) 160)
                                         (safe-exact-int (dyn-hash-ref nearest-e 'y 160) 160)
                                         5)
                    (values base-x base-y)))
              (emit! (list 'roach-tunnel-move uid kx ky)))]
           [(and burrowed? (< hp-pct SC2-ROACH-UNBURROW-HP-PCT-THRESH))
            (when has-tunneling?
              (define-values (kx ky)
                (if (and nearest-e (<= dist-e 10.0))
                    (compute-kite-vector (exact-round ux) (exact-round uy)
                                         (safe-exact-int (dyn-hash-ref nearest-e 'x 160) 160)
                                         (safe-exact-int (dyn-hash-ref nearest-e 'y 160) 160)
                                         5)
                    (values base-x base-y)))
              (emit! (list 'roach-tunnel-move uid kx ky)))]
           [(and burrowed? (>= hp-pct SC2-ROACH-UNBURROW-HP-PCT-THRESH))
            (emit! (list 'burrow-up uid 'roach-healed-reengage))])))
     (reverse actions)]))

;; Burrowed Infestor movement, cast & escape micro:
;; - Burrow-approach when within `SC2-INFESTOR-BURROW-APPROACH-RANGE` (16.0).
;; - Cast `neural-parasite` on capital targets when energy >= `SC2-INFESTOR-NEURAL-ENERGY`.
;; - Unburrow & cast `fungal-growth` within `SC2-INFESTOR-FUNGAL-CAST-RANGE` when energy >= 75.
;; - Burrow-retreat home when energy < `SC2-INFESTOR-FUNGAL-ENERGY`.
(: execute-infestor-burrow-cast-micro (-> Any (Listof (Listof Any))))
(define (execute-infestor-burrow-cast-micro obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-raw (dyn-hash-ref sanitized-obs 'ally-units '()))
  (define enemy-raw (dyn-hash-ref sanitized-obs 'enemy-units '()))
  (define ally-units : (Listof Any) (if (list? ally-raw) ally-raw '()))
  (define enemy-units : (Listof Any) (if (list? enemy-raw) enemy-raw '()))
  (define scan-allies : (Listof Any)
    (if (and (pair? enemy-units)
             (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units '(infestor infestor-burrowed)))
        ally-units
        '()))
  (define base-x (safe-exact-int (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32))
  (define base-y (safe-exact-int (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32))
  (define capital-syms : (Listof Symbol)
    '(thor battlecruiser siege-tank siege-tank-sieged colossus immortal archon
           carrier tempest mothership ultralisk))
  (define has-burrow? : Boolean
    (and (pair? scan-allies)
         (zerg-burrow-upgrade-researched? sanitized-obs)))
  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  (for ([u (in-list scan-allies)]
        #:when (and (hash? u)
                    (memq (dyn-hash-ref u 'type 'unknown) '(infestor infestor-burrowed))))
    (define uid (dyn-hash-ref u 'id 0))
    (define burrowed? (zerg-unit-burrowed? u 'infestor-burrowed))
    (define energy (safe-real (dyn-hash-ref u 'energy 75.0) 75.0))
    (define ux (safe-real (dyn-hash-ref u 'x base-x) base-x))
    (define uy (safe-real (dyn-hash-ref u 'y base-y) base-y))
    (define-values (nearest-e dist-e) (nearest-enemy-and-dist ux uy enemy-units))
    (when nearest-e
      (define ex (safe-exact-int (dyn-hash-ref nearest-e 'x 160) 160))
      (define ey (safe-exact-int (dyn-hash-ref nearest-e 'y 160) 160))
      (define capital-target : Any
        (findf (lambda ([e : Any])
                 (and (hash? e)
                      (memq (dyn-hash-ref e 'type 'unknown) capital-syms)
                      (<= (dist2d ux uy
                                  (safe-real (dyn-hash-ref e 'x 160.0) 160.0)
                                  (safe-real (dyn-hash-ref e 'y 160.0) 160.0))
                          (+ SC2-INFESTOR-NEURAL-CAST-RANGE 2.0))))
               enemy-units))
      (cond
        [(< energy SC2-INFESTOR-FUNGAL-ENERGY)
         (when (and has-burrow? (not burrowed?))
           (emit! (list 'burrow-down uid 'infestor-post-cast-hide 1444)))
         (emit! (list 'move uid base-x base-y))]
        [(and capital-target (>= energy SC2-INFESTOR-NEURAL-ENERGY))
         (define ctag (dyn-hash-ref capital-target 'id 0))
         (define cx (safe-exact-int (dyn-hash-ref capital-target 'x ex) ex))
         (define cy (safe-exact-int (dyn-hash-ref capital-target 'y ey) ey))
         (when (and has-burrow? (not burrowed?))
           (emit! (list 'burrow-down uid 'infestor-stealth-neural 1444)))
         (if (and (exact-integer? ctag) (> ctag 0))
             (emit! (list 'cast-spell uid 'neural-parasite ctag))
             (emit! (list 'cast-spell uid 'fungal-growth cx cy)))]
        [(and (<= dist-e (+ SC2-INFESTOR-FUNGAL-CAST-RANGE 0.5))
              (>= energy SC2-INFESTOR-FUNGAL-ENERGY))
         (when burrowed?
           (emit! (list 'burrow-up uid 'infestor-unburrow-for-fungal)))
         (emit! (list 'cast-spell uid 'fungal-growth ex ey))]
        [(<= dist-e SC2-INFESTOR-BURROW-APPROACH-RANGE)
         (when (and has-burrow? (not burrowed?))
           (emit! (list 'burrow-down uid 'infestor-stealth-approach 1444)))
         (emit! (list 'move uid ex ey))])))
  (reverse actions))

;; Pure Lurker burrow/unburrow decision (`'burrow-down`, `'burrow-up`, or `'hold`).
(: lurker-burrow-action (-> Boolean Real Symbol))
(define (lurker-burrow-action currently-burrowed? min-ground-enemy-dist)
  (define d (safe-finite-real min-ground-enemy-dist 999.0))
  (cond
    [(and currently-burrowed? (> d 10.5)) 'burrow-up]
    [(and (not currently-burrowed?) (<= d 9.0)) 'burrow-down]
    [else 'hold]))

;; Pure Drone harass-evade burrow decision (`'burrow-down`, `'burrow-up`, or `'hold`).
(: drone-evade-burrow-action (-> Boolean Real Real Boolean Symbol))
(define (drone-evade-burrow-action currently-burrowed? hp-pct nearest-threat-dist enemy-has-detection?)
  (define pct (safe-finite-real hp-pct 1.0))
  (define d (safe-finite-real nearest-threat-dist 999.0))
  (cond
    [(and currently-burrowed? (or enemy-has-detection? (> d 10.0))) 'burrow-up]
    [(and (not currently-burrowed?) (not enemy-has-detection?) (<= pct 0.45) (<= d 6.0)) 'burrow-down]
    [else 'hold]))

;; =============================================================================
;; Reactive Burrow Dodge, Stationary Detection Ring Ambush & Counter-Burrow
;; =============================================================================

(: BURROWABLE-ZERG-SYMS (Listof Symbol))
(define BURROWABLE-ZERG-SYMS
  '(zergling roach hydralisk baneling ravager queen drone infestor lurker lurker-mp
    swarm-host swarm-host-mp widow-mine
    zergling-burrowed roach-burrowed hydralisk-burrowed baneling-burrowed
    ravager-burrowed queen-burrowed drone-burrowed infestor-burrowed
    lurker-burrowed lurker-mp-burrowed swarm-host-burrowed swarm-host-mp-burrowed
    widow-mine-burrowed))

(: BURROWED-UNIT-TYPE-SYMS (Listof Symbol))
(define BURROWED-UNIT-TYPE-SYMS
  '(zergling-burrowed roach-burrowed hydralisk-burrowed baneling-burrowed
    ravager-burrowed queen-burrowed drone-burrowed infestor-burrowed
    lurker-burrowed lurker-mp-burrowed swarm-host-burrowed swarm-host-mp-burrowed
    widow-mine-burrowed))

(: BURROW-RANGED-THREAT-SYMS (Listof Symbol))
(define BURROW-RANGED-THREAT-SYMS
  '(stalker marine marauder immortal colossus adept sentry roach hydralisk cyclone))

(: BURROW-MELEE-THREAT-SYMS (Listof Symbol))
(define BURROW-MELEE-THREAT-SYMS
  '(zergling zealot hellbat scv probe drone broodling dark-templar ultralisk baneling))

(: BURROW-DETECTOR-EFFECT-SYMS (Listof Symbol))
(define BURROW-DETECTOR-EFFECT-SYMS
  '(scanner-sweep oracle-revelation revelation reveal))

(: BURROW-TOWNHALL-SYMS (Listof Symbol))
(define BURROW-TOWNHALL-SYMS
  '(hatchery lair hive nexus command-center orbital-command planetary-fortress))

(struct burrow-dodge-state
  ([prev-hp : Flonum]
   [last-burrow-frame : Integer]
   [last-unburrow-frame : Integer])
  #:mutable #:transparent)

(struct burrow-dodge-tracker
  ([last-frame : Integer]
   [units : (HashTable Integer burrow-dodge-state)]
   [remembered-rings : (HashTable Integer (Pairof Flonum Flonum))])
  #:mutable #:transparent)

(: make-burrow-dodge-tracker (-> burrow-dodge-tracker))
(define (make-burrow-dodge-tracker)
  (burrow-dodge-tracker -1 (make-hasheqv) (make-hasheqv)))

(: DEFAULT-BURROW-DODGE-TRACKER burrow-dodge-tracker)
(define DEFAULT-BURROW-DODGE-TRACKER (make-burrow-dodge-tracker))

(: dyn-symbol (-> Any Symbol Symbol))
(define (dyn-symbol v fallback)
  (if (symbol? v) v fallback))

(: dyn-list (-> Any (Listof Any)))
(define (dyn-list v)
  (if (list? v) v '()))

(: unit-is-burrowed? (-> Any Symbol Boolean))
(define (unit-is-burrowed? u ut)
  (or (not (not (memq ut BURROWED-UNIT-TYPE-SYMS)))
      (not (not (dyn-hash-ref u 'burrowed #f)))
      (not (not (dyn-hash-ref u 'is-burrowed? #f)))))

(: unit-has-reveal-buff? (-> Any Boolean))
(define (unit-has-reveal-buff? u)
  (or (not (not (dyn-hash-ref u 'revealed? #f)))
      (not (not (dyn-hash-ref u 'detected? #f)))
      (let ([buffs (dyn-list (dyn-hash-ref u 'buffs '()))])
        (for/or : Boolean ([b (in-list buffs)])
          (or (not (not (memq b '(oracle-revelation revelation 281 99))))
              (and (exact-integer? b) (= b 281)))))))

(: enemy-detector-within?
   (->* (Flonum Flonum Flonum (Listof Any) (Listof Any))
        ((Listof Any) Any)
        Boolean))
(define (enemy-detector-within? ux uy radius enemy-units enemy-bldgs [effects '()] [self-u #f])
  (or (and (hash? self-u) (unit-has-reveal-buff? self-u))
      (for/or : Boolean ([e (in-list enemy-units)])
        (and (hash? e)
             (let ([et (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)])
               (or (and (memq et SC2-MOBILE-DETECTOR-SYMS) #t)
                   (and (memq et SC2-STATIC-DETECTOR-SYMS)
                        (>= (safe-real (dyn-hash-ref e 'build-progress 1.0) 1.0)
                            SC2-BUILD-COMPLETE-PROGRESS))))
             (<= (dist2d ux uy
                         (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                         (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
                 radius)))
      (for/or : Boolean ([b (in-list enemy-bldgs)])
        (and (hash? b)
             (let ([bt (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)])
               (and (memq bt SC2-STATIC-DETECTOR-SYMS) #t))
             (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                 SC2-BUILD-COMPLETE-PROGRESS)
             (<= (dist2d ux uy
                         (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                         (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                 radius)))
      (for/or : Boolean ([eff (in-list effects)])
        (and (hash? eff)
             (let ([et (dyn-symbol (or (dyn-hash-ref eff 'type #f)
                                       (dyn-hash-ref eff 'spell #f)
                                       'unknown)
                                   'unknown)]
                   [er (safe-real (dyn-hash-ref eff 'radius radius) radius)])
               (and (or (memq et BURROW-DETECTOR-EFFECT-SYMS)
                        (memv (safe-exact-int (dyn-hash-ref eff 'effect-id 0) 0) '(6 399 2146)))
                    (<= (dist2d ux uy
                                (safe-real (dyn-hash-ref eff 'x 9999.0) 9999.0)
                                (safe-real (dyn-hash-ref eff 'y 9999.0) 9999.0))
                        (max radius er))))))))

(: any-enemy-of-types-within? (-> Flonum Flonum Flonum (Listof Any) (Listof Symbol) Boolean))
(define (any-enemy-of-types-within? ux uy radius enemy-units syms)
  (for/or : Boolean ([e (in-list enemy-units)])
    (and (hash? e)
         (let ([et (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)])
           (and (memq et syms) #t))
         (<= (dist2d ux uy
                     (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                     (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
             radius))))

(: sync-burrow-dodge-tracker! (-> burrow-dodge-tracker Integer Void))
(define (sync-burrow-dodge-tracker! tr frame)
  (when (or (<= frame 0) (< frame (burrow-dodge-tracker-last-frame tr)))
    (hash-clear! (burrow-dodge-tracker-units tr))
    (hash-clear! (burrow-dodge-tracker-remembered-rings tr)))
  (set-burrow-dodge-tracker-last-frame! tr frame))

;; Reactive Burrow Attack-Dodging for all burrowable Zerg ground units:
;; When Burrow is researched and 0 enemy detectors are within 11.0 tiles, tracks
;; per-unit `(prev-hp, last-burrow-frame, last-unburrow-frame)` and emits
;; `(burrow-down uid 'reactive-attack-dodge)` (3661) on active damage (`<= 0.75`)
;; or low-HP pressure under ranged fire (`<= 0.65` within 8.5 tiles), then unburrows
;; `(burrow-up uid 'reactive-dodge-pop-up)` (3662) after 18-28 frames (or `>= 0.80`
;; for Tunneling Claws Roaches, or when melee contact `<= 2.0`).
(: execute-zerg-reactive-burrow-dodge-micro
   (->* (Any) (#:tracker (Option burrow-dodge-tracker)) (Listof (Listof Any))))
(define (execute-zerg-reactive-burrow-dodge-micro obs #:tracker [opt-tr #f])
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (cond
    [(not (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units BURROWABLE-ZERG-SYMS))
     '()]
    [else
     (define tr : burrow-dodge-tracker (or opt-tr DEFAULT-BURROW-DODGE-TRACKER))
     (define-values (frame _upgrades has-burrow? has-tunneling? base-x base-y
                           enemy-units enemy-bldgs eff1 eff2 eff3)
       (fast-dodge-obs-header sanitized-obs
                              (->float SC2-DEFAULT-HOME-BASE-X)
                              (->float SC2-DEFAULT-HOME-BASE-Y)))
     (sync-burrow-dodge-tracker! tr frame)
     (define ally-recs
       (fast-extract-burrow-allies ally-units BURROWABLE-ZERG-SYMS BURROWED-UNIT-TYPE-SYMS base-x base-y))
     (cond
       [(null? ally-recs) '()]
       [else
        (define det-ready? : Boolean #f)
        (define det-fv : FlVector (flvector))
        (define det-len : Fixnum 0)
        (: det-within? (-> Any Flonum Flonum Flonum Boolean))
        (define (det-within? self-u ux uy radius)
          (or (fast-unit-revealed? self-u)
              (begin
                (unless det-ready?
                  (define-values (fv flen)
                    (fast-build-enemy-detectors enemy-units enemy-bldgs eff1 eff2 eff3
                                                SC2-MOBILE-DETECTOR-SYMS SC2-STATIC-DETECTOR-SYMS
                                                BURROW-DETECTOR-EFFECT-SYMS
                                                (->float SC2-BUILD-COMPLETE-PROGRESS)))
                  (set! det-fv fv)
                  (set! det-len flen)
                  (set! det-ready? #t))
                (and (fx> det-len 0)
                     (fast-flvec-det-within? det-fv det-len ux uy radius)))))

        (define rng-ready? : Boolean #f)
        (define rng-fv : FlVector (flvector))
        (define rng-len : Fixnum 0)
        (: ranged-within? (-> Flonum Flonum Flonum Boolean))
        (define (ranged-within? ux uy radius)
          (unless rng-ready?
            (define-values (fv flen) (fast-build-enemy-xy enemy-units BURROW-RANGED-THREAT-SYMS))
            (set! rng-fv fv)
            (set! rng-len flen)
            (set! rng-ready? #t))
          (and (fx> rng-len 0)
               (fast-flvec-xy-within? rng-fv rng-len ux uy radius)))

        (define mel-ready? : Boolean #f)
        (define mel-fv : FlVector (flvector))
        (define mel-len : Fixnum 0)
        (: melee-within? (-> Flonum Flonum Flonum Boolean))
        (define (melee-within? ux uy radius)
          (unless mel-ready?
            (define-values (fv flen) (fast-build-enemy-xy enemy-units BURROW-MELEE-THREAT-SYMS))
            (set! mel-fv fv)
            (set! mel-len flen)
            (set! mel-ready? #t))
          (and (fx> mel-len 0)
               (fast-flvec-xy-within? mel-fv mel-len ux uy radius)))

        (define unit-tbl (burrow-dodge-tracker-units tr))
        (define actions : (Listof (Listof Any)) '())
        (: emit! (-> (Listof Any) Void))
        (define (emit! a) (set! actions (cons a actions)))

        (for ([rec (in-list ally-recs)])
          (define u (vector-ref rec 0))
          (define raw-uid (vector-ref rec 1))
          (define uid (vector-ref rec 2))
          (define utype (vector-ref rec 3))
          (define ux (vector-ref rec 4))
          (define uy (vector-ref rec 5))
          (define hp (vector-ref rec 6))
          (define max-hp (vector-ref rec 7))
          (define burrowed? (vector-ref rec 8))
          (define hp-pct (/ hp max-hp))
          (define prev-st : (Option burrow-dodge-state) (hash-ref unit-tbl uid #f))
          (define-values (prev-hp last-burrow last-unburrow)
            (if prev-st
                (values (burrow-dodge-state-prev-hp prev-st)
                        (burrow-dodge-state-last-burrow-frame prev-st)
                        (burrow-dodge-state-last-unburrow-frame prev-st))
                (fast-dodge-fallback-state u frame burrowed? hp)))
          (define took-damage? (< hp prev-hp))
          (define new-last-burrow : Integer last-burrow)
          (define new-last-unburrow : Integer last-unburrow)

          (cond
            [(not burrowed?)
             (define ab-id (zerg-unit-type->burrow-ability-id utype))
             (when (and ab-id
                        (zerg-unit-burrow-allowed? utype has-burrow?)
                        (>= (- frame last-unburrow) 24)
                        (<= hp-pct 0.75)
                        (or took-damage?
                            (and (<= hp-pct 0.65)
                                 (ranged-within? ux uy 8.5)))
                        (not (det-within? u ux uy 11.0)))
               (set! new-last-burrow frame)
               (emit! (list 'burrow-down raw-uid 'reactive-attack-dodge ab-id)))]
            [else
             (define dwell (- frame last-burrow))
             (define roach? (memq utype '(roach roach-burrowed)))
             (define should-pop-up? : Boolean
               (cond
                 [(melee-within? ux uy 2.0) #t]
                 [(and roach? has-tunneling?) (>= hp-pct 0.80)]
                 [(>= dwell 24) #t]
                 [(>= dwell 18) (not (ranged-within? ux uy 8.5))]
                 [else #f]))
             (when should-pop-up?
               (set! new-last-unburrow frame)
               (emit! (list 'burrow-up raw-uid 'reactive-dodge-pop-up)))])

          (if prev-st
              (begin
                (set-burrow-dodge-state-prev-hp! prev-st hp)
                (set-burrow-dodge-state-last-burrow-frame! prev-st new-last-burrow)
                (set-burrow-dodge-state-last-unburrow-frame! prev-st new-last-unburrow))
              (hash-set! unit-tbl uid (burrow-dodge-state hp new-last-burrow new-last-unburrow))))
        (reverse actions)])]))

;; Stationary Detection Ring Stand-Off & Base-Trap Ambush:
;; When Zerg raiders within 18.0 tiles of an enemy base with stationary detectors
;; (`photon-cannon`/`missile-turret`/`spore-crawler`) and 0 mobile detectors within
;; 11.5 tiles face `local-enemy-power > 0.75 * raider-power`, park/burrow on the
;; `11.8-13.0` tile ring outside stationary detection. Once the defending army
;; moves out (`> 13.5` tiles from base or `local-enemy-power <= 0.65 * raider-power`),
;; unburrow `(burrow-up uid 'base-trap-pounce)` and attack `(attack-pos uid bx by)`.
(: RING-AMBUSH-RAIDER-SYMS (Listof Symbol))
(define RING-AMBUSH-RAIDER-SYMS
  '(zergling roach hydralisk baneling ravager lurker lurker-mp infestor
    zergling-burrowed roach-burrowed hydralisk-burrowed baneling-burrowed
    ravager-burrowed lurker-burrowed lurker-mp-burrowed infestor-burrowed))

(: execute-stationary-detection-ring-ambush-micro (-> Any (Listof (Listof Any))))
(define (execute-stationary-detection-ring-ambush-micro obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
  (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))
  (define has-static-det? : Boolean
    (and (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units RING-AMBUSH-RAIDER-SYMS)
         (or (obs-has-unit-type? sanitized-obs 'enemy-by-type enemy-units SC2-STATIC-DETECTOR-SYMS)
             (units-have-any-type? enemy-bldgs SC2-STATIC-DETECTOR-SYMS))))
  (define static-detectors : (Listof Any)
    (if has-static-det?
        (append
         (filter (lambda ([rec : Any])
                   (and (hash? rec)
                        (memq (dyn-symbol (dyn-hash-ref rec 'type 'unknown) 'unknown)
                              SC2-STATIC-DETECTOR-SYMS)
                        (>= (safe-real (dyn-hash-ref rec 'build-progress 1.0) 1.0)
                            SC2-BUILD-COMPLETE-PROGRESS)))
                 enemy-units)
         (filter (lambda ([rec : Any])
                   (and (hash? rec)
                        (memq (dyn-symbol (dyn-hash-ref rec 'type 'unknown) 'unknown)
                              SC2-STATIC-DETECTOR-SYMS)
                        (>= (safe-real (dyn-hash-ref rec 'build-progress 1.0) 1.0)
                            SC2-BUILD-COMPLETE-PROGRESS)))
                 enemy-bldgs))
        '()))
  (define base-x (if (null? static-detectors) 32.0 (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0)))
  (define base-y (if (null? static-detectors) 32.0 (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0)))
  (define enemy-x (if (null? static-detectors) 160.0 (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0)))
  (define enemy-y (if (null? static-detectors) 160.0 (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0)))
  (define upgrades (if (null? static-detectors) '() (dyn-list (dyn-hash-ref sanitized-obs 'researched-upgrades '()))))
  (define has-burrow? : Boolean
    (if (null? static-detectors)
        #f
        (zerg-burrow-upgrade-researched? sanitized-obs)))

  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  (unless (null? static-detectors)
    (define raider-syms RING-AMBUSH-RAIDER-SYMS)
    (define all-raiders : (Listof Any)
      (filter (lambda ([u : Any])
                (and (hash? u)
                     (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                           raider-syms)
                     #t))
              ally-units))

    ;; Evaluate each stationary-detector base cluster nearest the local raiders
    (define handled-raiders : (HashTable Any Boolean) (make-hasheq))
    (for ([det (in-list static-detectors)])
      (define det-x (safe-real (dyn-hash-ref det 'x enemy-x) enemy-x))
      (define det-y (safe-real (dyn-hash-ref det 'y enemy-y) enemy-y))
      (define-values (nearest-th _best-th-d)
        (for/fold ([best : Any #f]
                   [best-d : Flonum 18.0])
                  ([b (in-list enemy-bldgs)]
                   #:when (and (hash? b)
                               (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                                     BURROW-TOWNHALL-SYMS)))
          (define bd (dist2d det-x det-y
                             (safe-real (dyn-hash-ref b 'x enemy-x) enemy-x)
                             (safe-real (dyn-hash-ref b 'y enemy-y) enemy-y)))
          (if (<= bd best-d) (values b bd) (values best best-d))))
      (define target-bx : Flonum
        (cond
          [(hash? nearest-th) (safe-real (dyn-hash-ref nearest-th 'x det-x) det-x)]
          [(<= (dist2d det-x det-y enemy-x enemy-y) 18.0) enemy-x]
          [else det-x]))
      (define target-by : Flonum
        (cond
          [(hash? nearest-th) (safe-real (dyn-hash-ref nearest-th 'y det-y) det-y)]
          [(<= (dist2d det-x det-y enemy-x enemy-y) 18.0) enemy-y]
          [else det-y]))
      (define target-bx-i (exact-round target-bx))
      (define target-by-i (exact-round target-by))

      (define local-raiders : (Listof Any)
        (filter (lambda ([r : Any])
                  (define rid (dyn-hash-ref r 'id 0))
                  (define rx (safe-real (dyn-hash-ref r 'x base-x) base-x))
                  (define ry (safe-real (dyn-hash-ref r 'y base-y) base-y))
                  (and (not (hash-ref handled-raiders rid #f))
                       (or (<= (dist2d rx ry target-bx target-by) 18.0)
                           (<= (dist2d rx ry det-x det-y) 18.0))))
                all-raiders))

      (define mobile-det-near? : Boolean
        (for/or : Boolean ([e (in-list enemy-units)])
          (and (hash? e)
               (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                     SC2-MOBILE-DETECTOR-SYMS)
               (let ([ex (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)]
                     [ey (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0)])
                 (or (<= (dist2d ex ey det-x det-y) 11.5)
                     (for/or : Boolean ([r (in-list local-raiders)])
                       (<= (dist2d ex ey
                                   (safe-real (dyn-hash-ref r 'x base-x) base-x)
                                   (safe-real (dyn-hash-ref r 'y base-y) base-y))
                           11.5)))))))

      (when (and (not (null? local-raiders)) (not mobile-det-near?))
        (for ([r (in-list local-raiders)])
          (hash-set! handled-raiders (dyn-hash-ref r 'id 0) #t))
        (define raider-power : Flonum
          (for/fold ([acc : Flonum 0.0]) ([r (in-list local-raiders)])
            (+ acc (max 15.0 (+ (safe-real (dyn-hash-ref r 'hp 45.0) 45.0)
                                (safe-real (dyn-hash-ref r 'shields 0.0) 0.0))))))
        (define local-enemy-combat-cnt : Integer 0)
        (define moved-out-enemy-combat-cnt : Integer 0)
        (define local-enemy-power : Flonum
          (for/fold ([acc : Flonum 0.0]) ([e (in-list enemy-units)])
            (cond
              [(not (hash? e)) acc]
              [else
               (define et (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown))
               (define ex (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0))
               (define ey (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
               (define bd (dist2d ex ey target-bx target-by))
               (define worker? (memq et '(probe scv drone drone-burrowed)))
               (define noncombat? (or (memq et '(larva egg)) (sc2-non-combat-or-summon-sym? et)))
               (cond
                 [(or worker? noncombat?) acc]
                 [(<= bd 13.5)
                  (set! local-enemy-combat-cnt (add1 local-enemy-combat-cnt))
                  (+ acc (max 25.0 (+ (safe-real (dyn-hash-ref e 'hp 60.0) 60.0)
                                      (safe-real (dyn-hash-ref e 'shields 0.0) 0.0))))]
                 [(<= bd 42.0)
                  (set! moved-out-enemy-combat-cnt (add1 moved-out-enemy-combat-cnt))
                  acc]
                 [else acc])])))

        (define any-burrowed-raider? : Boolean
          (for/or : Boolean ([r (in-list local-raiders)])
            (define rt (dyn-symbol (dyn-hash-ref r 'type 'unknown) 'unknown))
            (unit-is-burrowed? r rt)))
        (define enemy-moved-out? : Boolean
          (and (= local-enemy-combat-cnt 0)
               (> moved-out-enemy-combat-cnt 0)))

        (cond
          [(or enemy-moved-out?
               (and any-burrowed-raider? (<= local-enemy-power (* 0.65 raider-power))))
           (for ([r (in-list local-raiders)])
             (define uid (dyn-hash-ref r 'id 0))
             (define rt (dyn-symbol (dyn-hash-ref r 'type 'unknown) 'unknown))
             (define burrowed? (unit-is-burrowed? r rt))
             (when burrowed?
               (emit! (list 'burrow-up uid 'base-trap-pounce)))
             (emit! (list 'attack-pos uid target-bx-i target-by-i)))]
          [(> local-enemy-power (* 0.75 raider-power))
           (for ([r (in-list local-raiders)])
             (define uid (dyn-hash-ref r 'id 0))
             (define rt (dyn-symbol (dyn-hash-ref r 'type 'unknown) 'unknown))
             (define burrowed? (unit-is-burrowed? r rt))
             (define rx (safe-real (dyn-hash-ref r 'x base-x) base-x))
             (define ry (safe-real (dyn-hash-ref r 'y base-y) base-y))
             (define d-det (dist2d rx ry det-x det-y))
             (cond
               [(and (<= 11.8 d-det) (<= d-det 13.0))
                (define ab-id (zerg-unit-type->burrow-ability-id rt))
                (when (and ab-id
                           (not burrowed?)
                           (zerg-unit-burrow-allowed? rt has-burrow?))
                  (emit! (list 'burrow-down uid 'stationary-detector-ring-ambush ab-id)))]
               [else
                ;; Compute radial point on the 11.8-13.0 ring (midpoint 12.4 tiles from detector)
                (define vx (- rx det-x))
                (define vy (- ry det-y))
                (define vlen (dist2d 0.0 0.0 vx vy))
                (define-values (ux uy)
                  (if (> vlen 0.1)
                      (values (/ vx vlen) (/ vy vlen))
                      (let* ([bx (- base-x det-x)]
                             [by (- base-y det-y)]
                             [bl (max 1.0 (dist2d 0.0 0.0 bx by))])
                        (values (/ bx bl) (/ by bl)))))
                (define ring-x (max 4.0 (min 248.0 (+ det-x (* 12.4 ux)))))
                (define ring-y (max 4.0 (min 248.0 (+ det-y (* 12.4 uy)))))
                (when burrowed?
                  (emit! (list 'burrow-up uid 'reposition-to-detector-ring)))
                (emit! (list 'move uid ring-x ring-y))]))]))))
  (reverse actions))

;; Counter-Burrow Plan & Response
(struct CounterBurrowPlan
  ([commands : (Listof (Listof Any))]
   [detector-orders : (Listof (Listof Any))]
   [aoe-reveal-orders : (Listof (Listof Any))]
   [sweep-orders : (Listof (Listof Any))]
   [remembered-ring-targets : (Listof (Pairof Flonum Flonum))]
   [action-kind : Symbol]
   [reason : Symbol])
  #:transparent)

(: ally-combat-centroid (-> (Listof Any) Flonum Flonum (Values Flonum Flonum)))
(define (ally-combat-centroid ally-units fallback-x fallback-y)
  (define sx : Flonum 0.0)
  (define sy : Flonum 0.0)
  (define cnt : Integer 0)
  (for ([u (in-list ally-units)]
        #:when (hash? u))
    (define ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown))
    (when (and (not (memq ut '(scv probe drone drone-burrowed overlord larva egg mule)))
               (not (memq ut SC2-MOBILE-DETECTOR-SYMS))
               (not (sc2-non-combat-or-summon-sym? ut)))
      (set! sx (+ sx (safe-real (dyn-hash-ref u 'x fallback-x) fallback-x)))
      (set! sy (+ sy (safe-real (dyn-hash-ref u 'y fallback-y) fallback-y)))
      (set! cnt (add1 cnt))))
  (if (> cnt 0)
      (values (/ sx (->float cnt)) (/ sy (->float cnt)))
      (values fallback-x fallback-y)))

(: pick-aoe-or-reveal-caster (-> (Listof Any) (Listof Any) Flonum Flonum (Values Any Symbol)))
(define (pick-aoe-or-reveal-caster ally-units ally-bldgs tx ty)
  (define-values (best-oc _best-oc-en)
    (for/fold ([best : Any #f] [best-en : Flonum 49.9]) ([b (in-list ally-bldgs)])
      (if (and (hash? b)
               (eq? (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) 'orbital-command)
               (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0) SC2-BUILD-COMPLETE-PROGRESS)
               (> (safe-real (dyn-hash-ref b 'energy 50.0) 50.0) best-en))
          (values b (safe-real (dyn-hash-ref b 'energy 50.0) 50.0))
          (values best best-en))))
  (cond
    [(hash? best-oc) (values best-oc 'scanner-sweep)]
    [else
     (define-values (best-u best-spell _best-score)
       (for/fold ([best-u : Any #f] [best-spell : Symbol 'none] [best-score : Flonum 1e9])
                 ([u (in-list ally-units)])
         (cond
           [(not (hash? u)) (values best-u best-spell best-score)]
           [else
            (define ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown))
            (define en (safe-real (dyn-hash-ref u 'energy 75.0) 75.0))
            (define ux (safe-real (dyn-hash-ref u 'x 9999.0) 9999.0))
            (define uy (safe-real (dyn-hash-ref u 'y 9999.0) 9999.0))
            (define d (dist2d ux uy tx ty))
            (define cand-spell : Symbol
              (cond
                [(and (eq? ut 'oracle) (>= en 25.0) (<= d 11.0)) 'oracle-revelation]
                [(and (memq ut '(infestor infestor-burrowed)) (>= en 75.0) (<= d 11.0)) 'fungal-growth]
                [(and (eq? ut 'high-templar) (>= en 75.0) (<= d 10.5)) 'psi-storm]
                [(and (eq? ut 'ghost) (>= en 75.0) (<= d 11.5)) 'emp-round]
                [(and (eq? ut 'ravager) (<= d 10.5)) 'corrosive-bile]
                [else 'none]))
            (if (and (not (eq? cand-spell 'none)) (< d best-score))
                (values u cand-spell d)
                (values best-u best-spell best-score))])))
     (values best-u best-spell)]))

;; Counter-Burrow Tactics (`CounterBurrowPlan`):
;;   1. Leashes 1 mobile detector (`observer`/`overseer`/`raven`) `<= 3.5` tiles from
;;      our front-line army centroid.
;;   2. Emits `scanner-sweep` / `oracle-revelation` / AoE (`fungal-growth`/`psi-storm`/
;;      `emp-round`/`corrosive-bile`) onto unrevealed burrowed coordinates.
;;   3. Sweeps remembered enemy burrow rings (`11.5-13.5` tiles around our stationary
;;      detectors) with 1 detector + 2-4 defenders before army move-out.
(: plan-counter-burrow-response
   (->* (Any)
        (#:remembered-burrows (Listof Any) #:tracker (Option burrow-dodge-tracker))
        CounterBurrowPlan))
(define (plan-counter-burrow-response obs #:remembered-burrows [rem-arg '()] #:tracker [opt-tr #f])
  (define tr : burrow-dodge-tracker (or opt-tr DEFAULT-BURROW-DODGE-TRACKER))
  (define ring-tbl (burrow-dodge-tracker-remembered-rings tr))
  (cond
    [(not (fast-counter-burrow-needed? obs ring-tbl rem-arg
                                       SC2-MOBILE-DETECTOR-SYMS SC2-STATIC-DETECTOR-SYMS
                                       BURROWED-UNIT-TYPE-SYMS SC2-SHIMMER-DISPLAY-TYPE-HIDDEN))
     (CounterBurrowPlan '() '() '() '() '() 'none 'counter-burrow-response)]
    [else
     (define-values (_need-work? sanitized-obs ally-units ally-bldgs enemy-units
                     obs-rem ripples sweep-flag?
                     has-mobile-det? has-enemy-burrowed? has-enemy-hidden? has-our-static-det?)
       (fast-counter-burrow-preflight obs ring-tbl rem-arg
                                      SC2-MOBILE-DETECTOR-SYMS SC2-STATIC-DETECTOR-SYMS
                                      BURROWED-UNIT-TYPE-SYMS SC2-SHIMMER-DISPLAY-TYPE-HIDDEN))
     (define frame (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
     (sync-burrow-dodge-tracker! tr frame)
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))

     ;; Extract mobile detectors & static detectors only when needed
     (define mobile-detectors : (Listof Any)
       (if has-mobile-det?
           (filter (lambda ([u : Any])
                     (and (hash? u)
                          (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                SC2-MOBILE-DETECTOR-SYMS)
                          #t))
                   ally-units)
           '()))
     (define has-defender? : Boolean
       (and (not (null? mobile-detectors))
            (for/or : Boolean ([u (in-list ally-units)])
              (and (hash? u)
                   (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                     (and (not (memq ut '(scv probe drone drone-burrowed overlord larva egg mule)))
                          (not (memq ut SC2-MOBILE-DETECTOR-SYMS))
                          (not (sc2-non-combat-or-summon-sym? ut))
                          (not (dyn-hash-ref u 'is-hallucination #f))))))))
     (define our-static-detectors : (Listof Any)
       (if has-our-static-det?
           (append
            (filter (lambda ([b : Any])
                      (and (hash? b)
                           (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                                 SC2-STATIC-DETECTOR-SYMS)
                           (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                               SC2-BUILD-COMPLETE-PROGRESS)))
                    ally-units)
            (filter (lambda ([b : Any])
                      (and (hash? b)
                           (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                                 SC2-STATIC-DETECTOR-SYMS)
                           (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                               SC2-BUILD-COMPLETE-PROGRESS)))
                    ally-bldgs))
           '()))

     ;; Remember enemy burrowed sightings around our static detectors (`11.5-13.5` ring)
     (when (and has-enemy-burrowed? (not (null? our-static-detectors)))
       (for ([e (in-list enemy-units)]
             #:when (and (hash? e)
                         (or (dyn-hash-ref e 'burrowed #f)
                             (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                                   '(zergling-burrowed roach-burrowed hydralisk-burrowed
                                     baneling-burrowed ravager-burrowed infestor-burrowed
                                     lurker-burrowed lurker-mp-burrowed)))))
         (define eid (safe-exact-int (dyn-hash-ref e 'id 0) 0))
         (define ex (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0))
         (define ey (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
         (when (for/or : Boolean ([sd (in-list our-static-detectors)])
                 (define d (dist2d ex ey
                                   (safe-real (dyn-hash-ref sd 'x base-x) base-x)
                                   (safe-real (dyn-hash-ref sd 'y base-y) base-y)))
                 (and (>= d 11.5) (<= d 13.5)))
           (hash-set! ring-tbl eid (cons ex ey)))))

     (define detector-orders : (Listof (Listof Any)) '())
     (define aoe-reveal-orders : (Listof (Listof Any)) '())
     (define sweep-orders : (Listof (Listof Any)) '())
     (define used-det-ids : (Listof Any) '())

     ;; 1. Position lead mobile detector (`Observer`/`Overseer`/`Raven`):
     ;;    L27-P0-3 (`z10` high-ground ramp Lurkers, `p11` cloaked Banshees): when burrowed,
     ;;    cloaked, shimmer, or nearby combat threats exist within 24.0t of `ally-combat-centroid`,
     ;;    advance `lead-det` up to `5.5t` AHEAD of the frontline centroid toward the threat
     ;;    (keeping safe `6.0t` standoff from hidden/burrowed threats and `7.5t` from visible
     ;;    combat enemies) so `11.0t` detection reveals high-ground Lurkers & cloaked Banshees!
     ;;    Otherwise leash `<= 3.5t` of `ally-combat-centroid`.
     (when (and has-defender? (not (null? mobile-detectors)))
       (define-values (cx cy) (ally-combat-centroid ally-units base-x base-y))
       (define lead-det (car mobile-detectors))
       (define did (dyn-hash-ref lead-det 'id 0))
       (define dx (safe-real (dyn-hash-ref lead-det 'x base-x) base-x))
       (define dy (safe-real (dyn-hash-ref lead-det 'y base-y) base-y))
       (define-values (best-hid-x best-hid-y best-hid-d)
         (for/fold ([bx : Float 0.0] [by : Float 0.0] [bd : Float +inf.0])
                   ([e (in-list (if (pair? ripples) (append ripples enemy-units) enemy-units))])
           (if (and (hash? e)
                    (or (dyn-hash-ref e 'burrowed #f)
                        (memv (safe-exact-int (dyn-hash-ref e 'cloak 0) 0) '(1 2))
                        (eq? (dyn-hash-ref e 'cloak #f) 'cloaked)
                        (= (safe-exact-int (dyn-hash-ref e 'display-type 1) 1)
                           SC2-SHIMMER-DISPLAY-TYPE-HIDDEN)
                        (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                              BURROWED-UNIT-TYPE-SYMS)))
               (let* ([ex0 (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)]
                      [ey0 (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0)]
                      [d0 (dist2d cx cy ex0 ey0)])
                 (if (and (<= d0 24.0) (< d0 bd))
                     (values ex0 ey0 d0)
                     (values bx by bd)))
               (values bx by bd))))
       (define-values (best-vis-x best-vis-y best-vis-d)
         (if (< best-hid-d +inf.0)
             (values 0.0 0.0 +inf.0)
             (for/fold ([bx : Float 0.0] [by : Float 0.0] [bd : Float +inf.0])
                       ([e (in-list enemy-units)])
               (if (and (hash? e)
                        (not (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                                   '(overlord overseer observer larva egg))))
                   (let* ([ex0 (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)]
                          [ey0 (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0)]
                          [d0 (dist2d cx cy ex0 ey0)])
                     (if (and (<= d0 24.0) (< d0 bd))
                         (values ex0 ey0 d0)
                         (values bx by bd)))
                   (values bx by bd)))))
       (define-values (adv-x adv-y thresh)
         (cond
           [(< best-hid-d +inf.0)
            (define step (if (> best-hid-d 0.5) (min 5.5 (max 0.0 (- best-hid-d 6.0))) 0.0))
            (define ux (if (> best-hid-d 0.5) (/ (- best-hid-x cx) best-hid-d) 0.0))
            (define uy (if (> best-hid-d 0.5) (/ (- best-hid-y cy) best-hid-d) 0.0))
            (values (+ cx (* step ux)) (+ cy (* step uy)) 2.2)]
           [(< best-vis-d +inf.0)
            (define step (if (> best-vis-d 0.5) (min 5.5 (max 0.0 (- best-vis-d 7.0))) 0.0))
            (define ux (if (> best-vis-d 0.5) (/ (- best-vis-x cx) best-vis-d) 0.0))
            (define uy (if (> best-vis-d 0.5) (/ (- best-vis-y cy) best-vis-d) 0.0))
            (values (+ cx (* step ux)) (+ cy (* step uy)) 2.5)]
           [else (values cx cy 3.5)]))
       (when (> (dist2d dx dy adv-x adv-y) thresh)
         (set! detector-orders (list (list 'move did adv-x adv-y)))
         (set! used-det-ids (cons did used-det-ids))))

     ;; 2. Emit reveal / AoE onto unrevealed burrowed targets
     (define burrowed-or-hidden : (Listof Any)
       (if (or has-enemy-hidden? (pair? ripples))
           (append
            (filter (lambda ([r : Any]) (hash? r)) ripples)
            (if has-enemy-hidden?
                (filter (lambda ([e : Any])
                          (and (hash? e)
                               (or (dyn-hash-ref e 'burrowed #f)
                                   (= (safe-exact-int (dyn-hash-ref e 'display-type 1) 1)
                                      SC2-SHIMMER-DISPLAY-TYPE-HIDDEN)
                                   (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                                         BURROWED-UNIT-TYPE-SYMS))
                               (not (enemy-detector-within?
                                     (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                                     (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0)
                                     10.5 ally-units ally-bldgs))))
                        enemy-units)
                '()))
           '()))

     (for ([tgt (in-list (if (null? burrowed-or-hidden) '() (list (car burrowed-or-hidden))))])
       (define tx (safe-real (dyn-hash-ref tgt 'x enemy-x) enemy-x))
       (define ty (safe-real (dyn-hash-ref tgt 'y enemy-y) enemy-y))
       (define-values (caster spell) (pick-aoe-or-reveal-caster ally-units ally-bldgs tx ty))
       (when (and (hash? caster) (not (eq? spell 'none)))
         (set! aoe-reveal-orders
               (cons (list 'cast-spell (dyn-hash-ref caster 'id 0) spell (exact-round tx) (exact-round ty))
                     aoe-reveal-orders))))

     ;; 3. Remembered stationary-detector ring targets (`11.5-13.5` tiles): 1 detector + 2-4 defenders
     (define remembered-pts : (Listof (Pairof Flonum Flonum))
       (if (or (> (hash-count ring-tbl) 0) (pair? obs-rem) (pair? rem-arg))
           (append
            (hash-values ring-tbl)
            (filter-map
             (lambda ([p : Any])
               (cond
                 [(and (pair? p) (real? (car p)) (real? (cdr p)))
                  (cons (->float (car p)) (->float (cdr p)))]
                 [(hash? p)
                  (cons (safe-real (dyn-hash-ref p 'x base-x) base-x)
                        (safe-real (dyn-hash-ref p 'y base-y) base-y))]
                 [else #f]))
             (append obs-rem rem-arg)))
           '()))

     ;; Also infer forward 12.5-tile sweep point if static detectors exist + explicit pre-moveout sweep
     (define final-ring-targets : (Listof (Pairof Flonum Flonum))
       (if (and (null? remembered-pts)
                (not (null? our-static-detectors))
                sweep-flag?)
           (let* ([sd (car our-static-detectors)]
                  [sx (safe-real (dyn-hash-ref sd 'x base-x) base-x)]
                  [sy (safe-real (dyn-hash-ref sd 'y base-y) base-y)]
                  [vx (- enemy-x sx)]
                  [vy (- enemy-y sy)]
                  [vl (max 1.0 (dist2d 0.0 0.0 vx vy))])
             (list (cons (max 4.0 (min 248.0 (+ sx (* 12.5 (/ vx vl)))))
                         (max 4.0 (min 248.0 (+ sy (* 12.5 (/ vy vl))))))))
           remembered-pts))

     (unless (null? final-ring-targets)
       (define ring-pt (car final-ring-targets))
       (define rx (car ring-pt))
       (define ry (cdr ring-pt))
       (define sweep-det : Any
         (or (findf (lambda ([d : Any]) (not (member (dyn-hash-ref d 'id 0) used-det-ids)))
                    mobile-detectors)
             (and (pair? mobile-detectors) (car mobile-detectors))))
       (when (hash? sweep-det)
         (set! sweep-orders (cons (list 'move (dyn-hash-ref sweep-det 'id 0) rx ry) sweep-orders)))
       (define defenders : (Listof Any)
         (filter (lambda ([u : Any])
                   (and (hash? u)
                        (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                          (and (not (memq ut '(scv probe drone drone-burrowed overlord larva egg mule)))
                               (not (memq ut SC2-MOBILE-DETECTOR-SYMS))
                               (not (sc2-non-combat-or-summon-sym? ut))
                               (not (dyn-hash-ref u 'is-hallucination #f))))))
                 ally-units))
       (define sorted-defs : (Listof Any)
         (sort defenders
               (lambda ([a : Any] [b : Any])
                 (< (dist2d rx ry (safe-real (dyn-hash-ref a 'x base-x) base-x)
                            (safe-real (dyn-hash-ref a 'y base-y) base-y))
                    (dist2d rx ry (safe-real (dyn-hash-ref b 'x base-x) base-x)
                            (safe-real (dyn-hash-ref b 'y base-y) base-y))))))
       (define sweep-squad (take sorted-defs (min 4 (length sorted-defs))))
       (when (>= (length sweep-squad) 1)
         (for ([df (in-list sweep-squad)])
           (set! sweep-orders
                 (cons (list 'attack-pos (dyn-hash-ref df 'id 0) rx ry) sweep-orders)))))

     (define all-cmds (append detector-orders (reverse aoe-reveal-orders) (reverse sweep-orders)))
     (CounterBurrowPlan
      all-cmds
      detector-orders
      (reverse aoe-reveal-orders)
      (reverse sweep-orders)
      final-ring-targets
      (cond
        [(not (null? sweep-orders)) 'sweep-remembered-ring]
        [(not (null? aoe-reveal-orders)) 'reveal-or-aoe-burrowed]
        [(not (null? detector-orders)) 'leash-frontline-detector]
        [else 'none])
      'counter-burrow-response)]))

;; =============================================================================
;; Burrowed Zergling Expansion Blocks + Smart Self-Unblock & Counter-Clear
;; =============================================================================

(: WORKER-BASE-SYMS (Listof Symbol))
(define WORKER-BASE-SYMS '(drone scv probe))

(: EXPAND-ORDER-ABILITY-IDS (Listof Integer))
(define EXPAND-ORDER-ABILITY-IDS '(1152 318 880))

(: EXPAND-ORDER-SYMS (Listof Symbol))
(define EXPAND-ORDER-SYMS '(expand build-hatchery build-command-center build-nexus))

(: SELF-PAD-UNBLOCKER-SYMS (Listof Symbol))
(define SELF-PAD-UNBLOCKER-SYMS
  '(zergling-burrowed roach-burrowed hydralisk-burrowed baneling-burrowed
    ravager-burrowed infestor-burrowed zergling changeling
    changeling-zealot changeling-marine changeling-marine-shield
    changeling-zergling changeling-zergling-wings))

(: burrow-pad-pt (-> Any (Option (Pairof Flonum Flonum))))
(define (burrow-pad-pt p)
  (cond
    [(hash? p)
     (define vx (dyn-hash-ref p 'x #f))
     (define vy (dyn-hash-ref p 'y #f))
     (and (real? vx) (real? vy) (cons (real->double-flonum vx) (real->double-flonum vy)))]
    [(and (list? p) (>= (length p) 2))
     (define a (car p))
     (define b (cadr p))
     (and (real? a) (real? b) (cons (real->double-flonum a) (real->double-flonum b)))]
    [(pair? p)
     (define a (car p))
     (define b (cdr p))
     (and (real? a) (real? b) (cons (real->double-flonum a) (real->double-flonum b)))]
    [else #f]))

(: add-unique-pad! (-> (Listof (Pairof Flonum Flonum)) Flonum Flonum (Listof (Pairof Flonum Flonum))))
(define (add-unique-pad! pts px py)
  (if (ormap (lambda ([q : (Pairof Flonum Flonum)])
               (<= (dist2d px py (car q) (cdr q)) 3.5))
             pts)
      pts
      (cons (cons px py) pts)))

(: worker-expanding? (-> Any Boolean))
(define (worker-expanding? w)
  (or (not (not (dyn-hash-ref w 'expanding? #f)))
      (not (not (dyn-hash-ref w 'has-expand-order? #f)))
      (not (not (memq (dyn-symbol (dyn-hash-ref w 'order 'none) 'none) EXPAND-ORDER-SYMS)))
      (not (not (memv (safe-exact-int (dyn-hash-ref w 'order-ability-id 0) 0) EXPAND-ORDER-ABILITY-IDS)))
      (for/or : Boolean ([o (in-list (dyn-list (dyn-hash-ref w 'orders '())))])
        (and (hash? o)
             (or (not (not (memv (safe-exact-int (dyn-hash-ref o 'ability-id 0) 0)
                                 EXPAND-ORDER-ABILITY-IDS)))
                 (not (not (memq (dyn-symbol (dyn-hash-ref o 'type 'none) 'none)
                                 EXPAND-ORDER-SYMS))))))))

(: unit-patrol-blocking? (-> Any Boolean))
(define (unit-patrol-blocking? u)
  (or (not (not (dyn-hash-ref u 'patrol-blocking? #f)))
      (= (safe-exact-int (dyn-hash-ref u 'order-ability-id 0) 0) 17)
      (eq? (dyn-symbol (dyn-hash-ref u 'order 'none) 'none) 'patrol)
      (for/or : Boolean ([o (in-list (dyn-list (dyn-hash-ref u 'orders '())))])
        (and (hash? o)
             (= (safe-exact-int (dyn-hash-ref o 'ability-id 0) 0) 17)))))

(: townhall-occupies-pad? (-> Flonum Flonum (Listof Any) (Listof Any) Boolean))
(define (townhall-occupies-pad? px py ally-bldgs enemy-bldgs)
  (or (for/or : Boolean ([b (in-list ally-bldgs)])
        (and (hash? b)
             (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                             BURROW-TOWNHALL-SYMS)))
             (<= (dist2d px py
                         (safe-real (dyn-hash-ref b 'x -999.0) -999.0)
                         (safe-real (dyn-hash-ref b 'y -999.0) -999.0))
                 5.2)))
      (for/or : Boolean ([b (in-list enemy-bldgs)])
        (and (hash? b)
             (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                             BURROW-TOWNHALL-SYMS)))
             (<= (dist2d px py
                         (safe-real (dyn-hash-ref b 'x -999.0) -999.0)
                         (safe-real (dyn-hash-ref b 'y -999.0) -999.0))
                 5.2)))))

(: extract-own-pending-expansion-targets (-> Any (Listof (Pairof Flonum Flonum))))
(define (extract-own-pending-expansion-targets sanitized-obs)
  (define mins (safe-real (dyn-hash-ref sanitized-obs 'minerals 0.0) 0.0))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define raw-pads (dyn-list (dyn-hash-ref sanitized-obs 'expansion-pads '())))
  (define explicit-pt (burrow-pad-pt (dyn-hash-ref sanitized-obs 'pending-expansion-target #f)))
  (define pending-raw (dyn-list (dyn-hash-ref sanitized-obs 'pending-expansion-targets '())))
  (define has-expanding-worker? : Boolean
    (for/or : Boolean ([u (in-list ally-units)])
      (and (hash? u)
           (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-BASE-SYMS)
           (worker-expanding? u))))
  (define can-check-pads? : Boolean
    (and (pair? raw-pads) (or (>= mins 225.0) has-expanding-worker?)))
  (cond
    [(and (not explicit-pt)
          (null? pending-raw)
          (not can-check-pads?)
          (not has-expanding-worker?))
     '()]
    [else
     (define unowned-pads : (Listof (Pairof Flonum Flonum))
       (if can-check-pads?
           (let ([ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '()))]
                 [enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '()))])
             (for/fold ([acc : (Listof (Pairof Flonum Flonum)) '()]) ([rp (in-list raw-pads)])
               (define pt (burrow-pad-pt rp))
               (if (and pt (not (townhall-occupies-pad? (car pt) (cdr pt) ally-bldgs enemy-bldgs)))
                   (add-unique-pad! acc (car pt) (cdr pt))
                   acc)))
           '()))
     (define targets : (Listof (Pairof Flonum Flonum)) '())
     (when explicit-pt
       (set! targets (add-unique-pad! targets (car explicit-pt) (cdr explicit-pt))))
     (for ([tp (in-list pending-raw)])
       (define pt (burrow-pad-pt tp))
       (when pt
         (set! targets (add-unique-pad! targets (car pt) (cdr pt)))))
     ;; Workers actively expanding or approaching an unowned expansion pad (`<= 10.0` at `minerals >= 225`)
     (when (or has-expanding-worker? (and (pair? unowned-pads) (>= mins 225.0)))
       (for ([u (in-list ally-units)]
             #:when (and (hash? u)
                         (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-BASE-SYMS)))
         (define exp? (worker-expanding? u))
         (when (or exp? (and (pair? unowned-pads) (>= mins 225.0)))
           (when exp?
             (define exp-pt
               (or (burrow-pad-pt (dyn-hash-ref u 'expand-target #f))
                   (burrow-pad-pt (dyn-hash-ref u 'target-pos #f))))
             (when exp-pt
               (set! targets (add-unique-pad! targets (car exp-pt) (cdr exp-pt)))))
           (when (pair? unowned-pads)
             (define wx (safe-real (dyn-hash-ref u 'x -999.0) -999.0))
             (define wy (safe-real (dyn-hash-ref u 'y -999.0) -999.0))
             (for ([pad (in-list unowned-pads)])
               (define dx (- wx (car pad)))
               (define dy (- wy (cdr pad)))
               (when (and (<= (abs dx) 10.0)
                          (<= (abs dy) 10.0)
                          (<= (+ (* dx dx) (* dy dy)) 100.0))
                 (set! targets (add-unique-pad! targets (car pad) (cdr pad)))))))))
     (reverse targets)]))

(: own-pad-self-burrowed? (-> Any Boolean))
(define (own-pad-self-burrowed? u)
  (unit-is-burrowed? u (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)))

(: pad-blocked-by-hidden-enemy?
   (-> Flonum Flonum Any (Listof Any) (Listof Any) (Listof Any) Flonum Boolean))
(define (pad-blocked-by-hidden-enemy? px py sanitized-obs ally-units enemy-units enemy-bldgs mins)
  (define worker-close?
    (for/or : Boolean ([u (in-list ally-units)])
      (and (hash? u)
           (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-BASE-SYMS)
           (<= (dist2d px py
                       (safe-real (dyn-hash-ref u 'x -999.0) -999.0)
                       (safe-real (dyn-hash-ref u 'y -999.0) -999.0))
               4.0))))
  (define visible-blocker?
    (or (for/or : Boolean ([e (in-list enemy-units)])
          (and (hash? e)
               (not (dyn-hash-ref e 'flying #f))
               (<= (dist2d px py
                           (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                           (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
                   4.5)))
        (for/or : Boolean ([e (in-list enemy-bldgs)])
          (and (hash? e)
               (not (dyn-hash-ref e 'flying #f))
               (<= (dist2d px py
                           (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                           (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
                   4.5)))))
  (define obstructed-signal?
    (or (not (not (dyn-hash-ref sanitized-obs 'pad-obstructed? #f)))
        (not (not (dyn-hash-ref sanitized-obs 'build-failed-obstructed? #f)))
        (for/or : Boolean ([u (in-list ally-units)])
          (and (hash? u)
               (or (dyn-hash-ref u 'expand-obstructed? #f)
                   (dyn-hash-ref u 'build-blocked? #f))
               (<= (dist2d px py
                           (safe-real (dyn-hash-ref u 'x -999.0) -999.0)
                           (safe-real (dyn-hash-ref u 'y -999.0) -999.0))
                   5.0)))))
  (and (>= mins 300.0)
       worker-close?
       (not visible-blocker?)
       obstructed-signal?))

;; Smart Self-Unblock + Symmetric Counter for hidden enemy pad blockers.
;; Whenever our bot plans to expand at `(pad-x, pad-y)`, immediately emits
;; `(burrow-up lid 'clear-own-expansion-pad)` + `(move lid (+ pad-x 7.0) (+ pad-y 7.0))`
;; for any friendly burrowed/blocking unit within 5.5 tiles; and if an expanding worker
;; reaches `<= 4.0` tiles at `minerals >= 300` with 0 visible blockers yet obstructed,
;; dispatches reveal (`scanner-sweep`/`oracle-revelation`/detector) + 2 combat units.
(: plan-clear-own-expansion-block-for-build
   (->* (Any) (#:tracker (Option burrow-dodge-tracker)) (Listof (Listof Any))))
(define (plan-clear-own-expansion-block-for-build obs #:tracker [opt-tr #f])
  (define tr : burrow-dodge-tracker (or opt-tr DEFAULT-BURROW-DODGE-TRACKER))
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define target-pads (extract-own-pending-expansion-targets sanitized-obs))
  (cond
    [(null? target-pads) '()]
    [else
     (sync-burrow-dodge-tracker! tr (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define mins (safe-real (dyn-hash-ref sanitized-obs 'minerals 0.0) 0.0))
     (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
     (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
     (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
     (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))
     (define actions : (Listof (Listof Any)) '())
     (define used-ids : (HashTable Any Boolean) (make-hash))
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

  (for ([pad (in-list target-pads)])
    (define px (car pad))
    (define py (cdr pad))
    (define esc-x (max 4.0 (min 248.0 (+ px 7.0))))
    (define esc-y (max 4.0 (min 248.0 (+ py 7.0))))
    ;; 1. Clear our own friendly burrowed/blocking/patrol units within 5.5 tiles
    (for ([u (in-list ally-units)]
          #:when (hash? u))
      (define uid (dyn-hash-ref u 'id 0))
      (define ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown))
      (define ux (safe-real (dyn-hash-ref u 'x -999.0) -999.0))
      (define uy (safe-real (dyn-hash-ref u 'y -999.0) -999.0))
      (when (and (not (hash-ref used-ids uid #f))
                 (<= (dist2d px py ux uy) 5.5)
                 (or (own-pad-self-burrowed? u)
                     (not (not (memq ut SELF-PAD-UNBLOCKER-SYMS)))
                     (not (not (memq ut SC2-CHANGELING-UNIT-SYMS)))
                     (unit-patrol-blocking? u)))
        (hash-set! used-ids uid #t)
        (when (own-pad-self-burrowed? u)
          (emit! (list 'burrow-up uid 'clear-own-expansion-pad)))
        (emit! (list 'move uid esc-x esc-y))))
    ;; 2. Symmetric counter: hidden/burrowed enemy pad blocker suspected -> reveal + 2 defenders
    (when (pad-blocked-by-hidden-enemy? px py sanitized-obs ally-units enemy-units enemy-bldgs mins)
      (define-values (caster-u caster-spell)
        (pick-aoe-or-reveal-caster ally-units ally-bldgs px py))
      (when (and (hash? caster-u) (not (eq? caster-spell 'none)))
        (define cid (dyn-hash-ref caster-u 'id 0))
        (unless (hash-ref used-ids cid #f)
          (hash-set! used-ids cid #t)
          (emit! (list 'cast-spell cid caster-spell px py))))
      (define free-dets : (Listof Any)
        (filter (lambda ([d : Any])
                  (and (hash? d)
                       (not (hash-ref used-ids (dyn-hash-ref d 'id 0) #f))
                       (not (not (memq (dyn-symbol (dyn-hash-ref d 'type 'unknown) 'unknown)
                                       SC2-MOBILE-DETECTOR-SYMS)))))
                ally-units))
      (unless (null? free-dets)
        (define best-det
          (argmin (lambda ([d : Any])
                    (dist2d px py (safe-real (dyn-hash-ref d 'x base-x) base-x)
                            (safe-real (dyn-hash-ref d 'y base-y) base-y)))
                  free-dets))
        (define did (dyn-hash-ref best-det 'id 0))
        (hash-set! used-ids did #t)
        (emit! (list 'move did px py)))
      (define free-combat : (Listof Any)
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                       (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                         (and (not (memq ut '(scv probe drone drone-burrowed overlord larva egg mule)))
                              (not (memq ut SC2-MOBILE-DETECTOR-SYMS))
                              (not (memq ut BURROWED-UNIT-TYPE-SYMS))
                              (not (sc2-non-combat-or-summon-sym? ut))
                              (not (dyn-hash-ref u 'is-hallucination #f))))))
                ally-units))
      (define sorted-clearers : (Listof Any)
        (sort free-combat
              (lambda ([a : Any] [b : Any])
                (< (dist2d px py (safe-real (dyn-hash-ref a 'x base-x) base-x)
                           (safe-real (dyn-hash-ref a 'y base-y) base-y))
                   (dist2d px py (safe-real (dyn-hash-ref b 'x base-x) base-x)
                           (safe-real (dyn-hash-ref b 'y base-y) base-y))))))
      (for ([df (in-list (take sorted-clearers (min 2 (length sorted-clearers))))])
        (define dfid (dyn-hash-ref df 'id 0))
        (hash-set! used-ids dfid #t)
        (emit! (list 'attack-pos dfid px py)))))
  (reverse actions)]))

(: collect-candidate-enemy-block-pads
   (-> Any (Listof (Pairof Flonum Flonum)) (Listof Any) (Listof Any)
       Flonum Flonum Flonum Flonum Flonum Flonum (Listof (Pairof Flonum Flonum))))
(define (collect-candidate-enemy-block-pads
         sanitized-obs self-clearing-pads ally-bldgs enemy-bldgs
         base-x base-y nat-x nat-y enemy-x enemy-y)
  (define raw-list : (Listof (Pairof Flonum Flonum)) '())
  (define en-nat-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-x (+ enemy-x 0.0)) -1.0))
  (define en-nat-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-y (+ enemy-y 0.0)) -1.0))
  (when (and (> en-nat-x 0.0) (> en-nat-y 0.0)
             (or (dyn-hash-has-key? sanitized-obs 'enemy-natural-x)
                 (dyn-hash-has-key? sanitized-obs 'enemy-natural-y)))
    (set! raw-list (add-unique-pad! raw-list en-nat-x en-nat-y)))
  (for ([k (in-list '(expansion-pads enemy-expansion-pads contested-pads))])
    (for ([p (in-list (dyn-list (dyn-hash-ref sanitized-obs k '())))])
      (define pt (burrow-pad-pt p))
      (when pt
        (set! raw-list (add-unique-pad! raw-list (car pt) (cdr pt))))))
  (define filtered : (Listof (Pairof Flonum Flonum))
    (filter (lambda ([pt : (Pairof Flonum Flonum)])
              (define px (car pt))
              (define py (cdr pt))
              (and (> (dist2d px py base-x base-y) 8.0)
                   (> (dist2d px py nat-x nat-y) 8.0)
                   (> (dist2d px py enemy-x enemy-y) 8.0)
                   (not (townhall-occupies-pad? px py ally-bldgs enemy-bldgs))
                   (not (ormap (lambda ([sp : (Pairof Flonum Flonum)])
                                 (<= (dist2d px py (car sp) (cdr sp)) 6.0))
                               self-clearing-pads))))
            raw-list))
  (sort filtered
        (lambda ([a : (Pairof Flonum Flonum)] [b : (Pairof Flonum Flonum)])
          (define da (dist2d (car a) (cdr a) enemy-x enemy-y))
          (define db (dist2d (car b) (cdr b) enemy-x enemy-y))
          (< da db))))

;; Once `'burrow` is researched & `zergling >= 8`, sends/burrows 1 Zergling directly
;; on unowned enemy/contested expansion pad centers (`(burrow-down lid 'expansion-pad-block)`).
;; Automatically yields any own pending expansion pad cleanly via `plan-clear-own-expansion-block-for-build`.
(: plan-burrowed-zergling-expansion-blocks
   (->* (Any) (#:tracker (Option burrow-dodge-tracker)) (Listof (Listof Any))))
(define (plan-burrowed-zergling-expansion-blocks obs #:tracker [opt-tr #f])
  (define tr : burrow-dodge-tracker (or opt-tr DEFAULT-BURROW-DODGE-TRACKER))
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define unblock-cmds (plan-clear-own-expansion-block-for-build sanitized-obs #:tracker tr))
  (define burrow-ready?
    (zerg-burrow-upgrade-researched? sanitized-obs))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define has-enough-lings? : Boolean
    (and burrow-ready?
         (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units '(zergling zergling-burrowed))
         (>= (for/fold ([n : Integer 0])
                       ([u (in-list ally-units)])
               (if (and (hash? u)
                        (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                          (or (eq? ut 'zergling) (eq? ut 'zergling-burrowed))))
                   (add1 n)
                   n))
             8)))
  (cond
    [(not has-enough-lings?)
     unblock-cmds]
    [else
     (define live-lings : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (hash? u)
                      (eq? (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) 'zergling)
                      (not (dyn-hash-ref u 'burrowed #f))))
               ally-units))
     (define burrowed-lings : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (hash? u)
                      (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                        (or (eq? ut 'zergling-burrowed)
                            (and (eq? ut 'zergling) (not (not (dyn-hash-ref u 'burrowed #f))))))))
               ally-units))
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define nat-x (safe-real (dyn-hash-ref sanitized-obs 'natural-x SC2-DEFAULT-NATURAL-X) 48.0))
     (define nat-y (safe-real (dyn-hash-ref sanitized-obs 'natural-y SC2-DEFAULT-NATURAL-Y) 48.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
     (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
     (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))
     (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
     (define effects (dyn-list (dyn-hash-ref sanitized-obs 'effects '())))
     (define self-pads (extract-own-pending-expansion-targets sanitized-obs))
     (define cand-pads
       (collect-candidate-enemy-block-pads
        sanitized-obs self-pads ally-bldgs enemy-bldgs
        base-x base-y nat-x nat-y enemy-x enemy-y))
     ;; Track any Zergling already unassigned and away from urgent home defense (`<= 12` tiles)
     (define used-lings : (HashTable Any Boolean) (make-hash))
     (for ([cmd (in-list unblock-cmds)]
           #:when (and (list? cmd) (>= (length cmd) 2)))
       (hash-set! used-lings (cadr cmd) #t))
     (define actions : (Listof (Listof Any)) '())
     (define assigned-pads : Integer 0)
     (for ([pad (in-list cand-pads)]
           #:break (>= assigned-pads 3))
       (define px (car pad))
       (define py (cdr pad))
       (define already-burrowed?
         (for/or : Boolean ([bl (in-list burrowed-lings)])
           (<= (dist2d px py
                       (safe-real (dyn-hash-ref bl 'x -999.0) -999.0)
                       (safe-real (dyn-hash-ref bl 'y -999.0) -999.0))
               3.0)))
       (cond
         [already-burrowed?
          (set! assigned-pads (add1 assigned-pads))]
         [else
          (define det-unsafe? (enemy-detector-within? px py 9.5 enemy-units enemy-bldgs effects #f))
          (define home-under-threat?
            (for/or : Boolean ([e (in-list enemy-units)])
              (and (hash? e)
                   (<= (dist2d base-x base-y
                               (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                               (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
                       14.0))))
          (define avail-lings : (Listof Any)
            (filter (lambda ([l : Any])
                      (and (not (hash-ref used-lings (dyn-hash-ref l 'id 0) #f))
                           (or (not home-under-threat?)
                               (> (dist2d (safe-real (dyn-hash-ref l 'x base-x) base-x)
                                          (safe-real (dyn-hash-ref l 'y base-y) base-y)
                                          base-x base-y)
                                  16.0))))
                    live-lings))
          (unless (or det-unsafe? (null? avail-lings))
            (define chosen
              (argmin (lambda ([l : Any])
                        (dist2d px py
                                (safe-real (dyn-hash-ref l 'x base-x) base-x)
                                (safe-real (dyn-hash-ref l 'y base-y) base-y)))
                      avail-lings))
            (define lid (dyn-hash-ref chosen 'id 0))
            (define lx (safe-real (dyn-hash-ref chosen 'x base-x) base-x))
            (define ly (safe-real (dyn-hash-ref chosen 'y base-y) base-y))
            (hash-set! used-lings lid #t)
            (set! assigned-pads (add1 assigned-pads))
            (if (<= (dist2d lx ly px py) 1.5)
                (set! actions (cons (list 'burrow-down lid 'expansion-pad-block 1390) actions))
                (set! actions (cons (list 'move lid px py) actions))))]))
     (append unblock-cmds (reverse actions))]))

;; Computes speed-aware Disruptor Purification Nova catchable standoff range.
(: disruptor-nova-catchable-range
   (->* (Real) (Boolean #:disruptor-ready? Boolean) Flonum))
(define (disruptor-nova-catchable-range unit-speed-tps [clumped? #f] #:disruptor-ready? [ready? #t])
  (fast-disruptor-nova-catchable-range unit-speed-tps clumped? ready?))

;; Evaluates whether friendly army should commit through enemy splash zones rather than hold standoff.
(: should-commit-through-splash?
   (->* ((Listof Any) (Listof Any))
        (#:tactical-disposition Any
         #:lanchester-ratio (Option Real)
         #:has-detector? Boolean
         #:concavity-deg (Option Real))
        Boolean))
(define (should-commit-through-splash? friendly-units enemy-units
                                       #:tactical-disposition [disp #f]
                                       #:lanchester-ratio [ratio #f]
                                       #:has-detector? [has-detector? #t]
                                       #:concavity-deg [arc-deg #f])
  (fast-should-commit-through-splash? friendly-units enemy-units disp ratio has-detector? arc-deg))

;; Plans immediate Nova flare, linear spine avoidance, AoE hazard evasion, Siege Tank
;; deadzone dives, Colossus standoff/radial-split dive, and splash pre-splits/commit pushes.
(: plan-avoid-siege-tank-and-lurker-splash-zones
   (->* ((Listof Any) (Listof Any))
        (#:effects (Listof Any)
         #:home-x Real
         #:home-y Real
         #:commit-through-splash? Boolean
         #:enemy-upgrades (Listof Any)
         #:tactical-disposition Any
         #:lanchester-ratio Real)
        (Listof (Immutable-HashTable Symbol Any))))
(define (plan-avoid-siege-tank-and-lurker-splash-zones ally-units enemy-units
                                                      #:effects [effects '()]
                                                      #:home-x [home-x 30.0]
                                                      #:home-y [home-y 30.0]
                                                      #:commit-through-splash? [commit-through-splash? #f]
                                                      #:enemy-upgrades [enemy-upgrades '()]
                                                      #:tactical-disposition [tactical-disposition #f]
                                                      #:lanchester-ratio [lanchester-ratio 1.0])
  (define hx : Flonum (if (rational? home-x) (real->double-flonum home-x) 30.0))
  (define hy : Flonum (if (rational? home-y) (real->double-flonum home-y) 30.0))
  (define lr : Flonum (if (rational? lanchester-ratio) (real->double-flonum lanchester-ratio) 1.0))
  (fast-plan-avoid-siege-tank-and-lurker-splash-zones
   ally-units enemy-units effects hx hy
   commit-through-splash? enemy-upgrades tactical-disposition lr))
