#lang typed/racket/base

;; =============================================================================
;; Layer 0c: Typed Structured Step-Logging & Snapshot Extraction (`lib/sc2-logging.rkt`)
;; =============================================================================

(require racket/string
         typed/racket/unsafe
         "sc2-types.rkt")

(module exp-meta-ops racket/base
  (provide record-exp-meta!
           lookup-exp-meta
           record-econ-belief-meta!
           lookup-econ-belief-meta)
  (define exp-meta-table (make-weak-hasheq))
  (define econ-belief-meta-table (make-weak-hasheq))
  (define (record-exp-meta! rec meta)
    (when (hash? meta)
      (hash-set! exp-meta-table rec meta))
    rec)
  (define (lookup-exp-meta rec)
    (hash-ref exp-meta-table rec #f))
  (define (record-econ-belief-meta! rec meta)
    (when (hash? meta)
      (hash-set! econ-belief-meta-table rec meta))
    rec)
  (define (lookup-econ-belief-meta rec)
    (hash-ref econ-belief-meta-table rec #f)))

(unsafe-require/typed 'exp-meta-ops
                      [record-exp-meta! (-> Any (Option (Immutable-HashTable Symbol Any)) Any)]
                      [lookup-exp-meta (-> Any (Option (Immutable-HashTable Symbol Any)))]
                      [record-econ-belief-meta! (-> Any (Option (Immutable-HashTable Symbol Any)) Any)]
                      [lookup-econ-belief-meta (-> Any (Option (Immutable-HashTable Symbol Any)))])

(provide
 (struct-out bot-mind-log-snapshot)
 (struct-out bot-goal-log-snapshot)
 (struct-out bot-tactics-log-snapshot)
 (struct-out bot-step-log-record)
 should-emit-step-log?
 extract-experiment-log-tag
 extract-bot-step-log-record
 format-bot-step-log-line
 bot-step-log-record->hash)

;; -----------------------------------------------------------------------------
;; 1. Structured Step-Log Snapshot Structs
;; -----------------------------------------------------------------------------

(struct bot-mind-log-snapshot
  ([frame : Nonnegative-Integer]
   [race : KnownRace]
   [enemy-race : Race]
   [matchup : MatchupSym]
   [posture : Symbol]
   [personality : Symbol]
   [enemy-archetype : Symbol]
   [win-prob : Float]
   [confidence : Float]
   [bluff-posterior : Float]
   [rush-posterior : Float]
   [hidden-expand-posterior : Float]
   [tech-switch-posterior : Float]
   [pad-camped-posterior : Float])
  #:transparent)

(struct bot-goal-log-snapshot
  ([active-bo-goal-sym : Symbol]
   [active-bo-goal-kind : Symbol]
   [active-bo-target-count : Nonnegative-Integer]
   [active-bo-target-sec : Float]
   [reserved-minerals : Nonnegative-Integer]
   [reserved-gas : Nonnegative-Integer]
   [target-workers : Nonnegative-Integer]
   [target-army-supply : Real]
   [scheduled-ids : (Listof Symbol)]
   [escrow-blocked-ids : (Listof Symbol)])
  #:transparent)

(struct bot-tactics-log-snapshot
  ([combat-posture : Symbol]
   [snowball-adv : Float]
   [retreat-sector : Integer]
   [burrowed-count : Nonnegative-Integer]
   [shimmer-alerts : Nonnegative-Integer]
   [swapped-addons : Nonnegative-Integer]
   [issued-orders : Nonnegative-Integer])
  #:transparent)

(struct bot-step-log-record
  ([mind : bot-mind-log-snapshot]
   [goals : bot-goal-log-snapshot]
   [tactics : bot-tactics-log-snapshot])
  #:transparent)

;; -----------------------------------------------------------------------------
;; 2. Total Coercion Helpers
;; -----------------------------------------------------------------------------

(: hget* (-> Any (Listof Symbol) Any Any))
(define (hget* src keys default)
  (if (hash? src)
      (let loop ([ks : (Listof Symbol) keys])
        (cond
          [(null? ks) default]
          [(hash-has-key? src (car ks))
           (hash-ref src (car ks) (lambda () default))]
          [else (loop (cdr ks))]))
      default))

(: safe-sym (->* (Any) (Symbol) Symbol))
(define (safe-sym v [default 'unknown])
  (cond
    [(symbol? v) v]
    [(and (string? v) (> (string-length v) 0)) (string->symbol v)]
    [else default]))

(: safe-sym-list (-> Any (Listof Symbol)))
(define (safe-sym-list xs)
  (reverse
   (for/fold ([acc : (Listof Symbol) '()])
             ([x : Any (in-list (safe-list xs))])
     (cond
       [(symbol? x) (cons x acc)]
       [(and (string? x) (> (string-length x) 0)) (cons (string->symbol x) acc)]
       [else acc]))))

(: safe-enemy-race (-> Any Race))
(define (safe-enemy-race r)
  (cond
    [(or (eq? r 'Zerg) (eq? r 'zerg) (equal? r "Zerg") (equal? r "zerg")) 'Zerg]
    [(or (eq? r 'Protoss) (eq? r 'protoss) (equal? r "Protoss") (equal? r "protoss")) 'Protoss]
    [(or (eq? r 'Terran) (eq? r 'terran) (equal? r "Terran") (equal? r "terran")) 'Terran]
    [else 'Random]))

(: safe-army-real (-> Any Real))
(define (safe-army-real v)
  (cond
    [(exact-integer? v) v]
    [(finite-real? v) (safe-finite-real v 0.0)]
    [else 0.0]))

(: extract-mind-snapshot (-> Any bot-mind-log-snapshot))
(define (extract-mind-snapshot src)
  (cond
    [(bot-mind-log-snapshot? src) src]
    [else
     (define race : KnownRace
       (normalize-known-race (hget* src '(race our-race self-race) 'Zerg)))
     (define raw-er (hget* src '(enemy-race opp-race) 'Random))
     (define enemy-race : Race (safe-enemy-race raw-er))
     (define raw-m (hget* src '(matchup) #f))
     (define matchup : MatchupSym
       (if (matchup-sym? raw-m)
           raw-m
           (resolve-matchup-symbol race (if (or (eq? enemy-race 'Random) (not raw-er)) 'Unknown enemy-race))))
     (define post-src (let ([bp (hget* src '(bayesian-posteriors posteriors) #f)])
                        (if (hash? bp) bp src)))
     (bot-mind-log-snapshot
      (safe-nonneg-int (hget* src '(frame) 0) 0)
      race
      enemy-race
      matchup
      (safe-sym (hget* src '(posture strategic-posture) 'macro) 'macro)
      (safe-sym (hget* src '(personality) 'default) 'default)
      (safe-sym (hget* src '(enemy-archetype predicted-enemy-archetype archetype) 'unknown) 'unknown)
      (clamp-prob (safe-finite-real (hget* src '(win-prob win-probability) 0.5) 0.5))
      (clamp-prob (safe-finite-real (hget* src '(confidence) 0.5) 0.5))
      (clamp-prob (safe-finite-real (hget* post-src '(bluff-posterior bluff) 0.0) 0.0))
      (clamp-prob (safe-finite-real (hget* post-src '(rush-posterior rush) 0.0) 0.0))
      (clamp-prob (safe-finite-real (hget* post-src '(hidden-expand-posterior hidden-expand) 0.0) 0.0))
      (clamp-prob (safe-finite-real (hget* post-src '(tech-switch-posterior tech-switch) 0.0) 0.0))
      (clamp-prob (safe-finite-real (hget* post-src '(pad-camped-posterior pad-camped) 0.0) 0.0)))]))

(: extract-goal-snapshot (-> Any bot-goal-log-snapshot))
(define (extract-goal-snapshot src)
  (cond
    [(bot-goal-log-snapshot? src) src]
    [(pro-bo-eval-result? src)
     (define ag (pro-bo-eval-result-active-goal src))
     (bot-goal-log-snapshot
      (if (pro-bo-goal? ag) (pro-bo-goal-target-sym ag) 'none)
      (if (pro-bo-goal? ag) (pro-bo-goal-kind ag) 'none)
      (if (pro-bo-goal? ag) (pro-bo-goal-target-count ag) 0)
      (if (pro-bo-goal? ag) (safe-finite-real (pro-bo-goal-target-sec ag) 0.0) 0.0)
      (pro-bo-eval-result-reserved-minerals src)
      (pro-bo-eval-result-reserved-gas src)
      (pro-bo-eval-result-target-workers src)
      (pro-bo-eval-result-target-army-supply src)
      '()
      '())]
    [else
     (define raw-ag (hget* src '(active-bo-goal bo-active-goal active-goal) #f))
     (define def-sym : Symbol (if (pro-bo-goal? raw-ag) (pro-bo-goal-target-sym raw-ag) 'none))
     (define def-kind : Symbol (if (pro-bo-goal? raw-ag) (pro-bo-goal-kind raw-ag) 'none))
     (define def-cnt : Nonnegative-Integer (if (pro-bo-goal? raw-ag) (pro-bo-goal-target-count raw-ag) 0))
     (define def-sec : Float
       (if (pro-bo-goal? raw-ag)
           (safe-finite-real (pro-bo-goal-target-sec raw-ag) 0.0)
           0.0))
     (bot-goal-log-snapshot
      (safe-sym (hget* src '(active-bo-goal-sym bo-goal-sym saving-for) def-sym) def-sym)
      (safe-sym (hget* src '(active-bo-goal-kind bo-goal-kind) def-kind) def-kind)
      (safe-nonneg-int (hget* src '(active-bo-target-count bo-target-count) def-cnt) def-cnt)
      (safe-finite-real (hget* src '(active-bo-target-sec bo-target-sec target-sec) def-sec) def-sec)
      (safe-nonneg-int (hget* src '(reserved-minerals reserved-min-floor) 0) 0)
      (safe-nonneg-int (hget* src '(reserved-gas reserved-gas-floor) 0) 0)
      (safe-nonneg-int (hget* src '(target-workers) 0) 0)
      (safe-army-real (hget* src '(target-army-supply target-army) 0))
      (safe-sym-list (hget* src '(scheduled-ids) '()))
      (safe-sym-list (hget* src '(escrow-blocked-ids) '())))]))

(: extract-tactics-snapshot (-> Any bot-tactics-log-snapshot))
(define (extract-tactics-snapshot src)
  (cond
    [(bot-tactics-log-snapshot? src) src]
    [else
     (bot-tactics-log-snapshot
      (safe-sym (hget* src '(combat-posture posture) 'hold) 'hold)
      (safe-finite-real (hget* src '(snowball-adv snowball-advantage) 0.0) 0.0)
      (safe-exact-int (hget* src '(retreat-sector) 0) 0)
      (safe-nonneg-int (hget* src '(burrowed-count) 0) 0)
      (safe-nonneg-int (hget* src '(shimmer-alerts) 0) 0)
      (safe-nonneg-int (hget* src '(swapped-addons) 0) 0)
      (safe-nonneg-int (hget* src '(issued-orders) 0) 0))]))

;; -----------------------------------------------------------------------------
;; 3. Public API: Predicate, Extractor, Formatter, Hash Serializer
;; -----------------------------------------------------------------------------

(: should-emit-step-log? (-> Nonnegative-Integer Nonnegative-Integer Boolean Boolean))
(define (should-emit-step-log? frame interval changed?)
  (or (<= frame 1)
      changed?
      (and (> interval 0)
           (= (remainder frame interval) 0))))

(: rx-group-str (-> (Pairof String (Listof (Option String))) Natural String))
(define (rx-group-str m idx)
  (define xs : (Listof (Option String)) m)
  (if (< idx (length xs))
      (or (list-ref xs idx) "")
      ""))

(: valid-exp-id-sym (-> Any (Option Symbol)))
(define (valid-exp-id-sym v)
  (cond
    [(symbol? v)
     (if (memq v (ann '(#f unknown none ||) (Listof Any))) #f v)]
    [(string? v)
     (define t (string-trim v))
     (if (or (string=? t "")
             (string=? t "unknown")
             (string=? t "none"))
         #f
         (string->symbol t))]
    [else #f]))

(: extract-experiment-log-tag (-> Any (U False (Immutable-HashTable Symbol Any))))
(define (extract-experiment-log-tag raw)
  (cond
    [(bot-step-log-record? raw)
     (lookup-exp-meta raw)]
    [(string? raw)
     (define m1
       (regexp-match #px"\\[EXP:([^|\\]]+)\\|race:([^|\\]]+)\\|matchup:([^|\\]]+)\\|spot:([0-9]+):([^|\\]]+)\\|p:([0-9.]+)%\\]"
                     raw))
     (cond
       [m1
        (define id-sym (valid-exp-id-sym (rx-group-str m1 1)))
        (and id-sym
             (let ([sp-n (string->number (rx-group-str m1 4))]
                   [pct-n (string->number (rx-group-str m1 6))])
               (hasheq 'experiment-id id-sym
                       'race (normalize-known-race (rx-group-str m1 2))
                       'matchup (safe-sym (rx-group-str m1 3) 'unknown)
                       'experiment-spot-idx (safe-nonneg-int sp-n 0)
                       'spot-label (safe-sym (rx-group-str m1 5) 'default)
                       'probability-pct (safe-finite-real pct-n 0.0))))]
       [else
        (define m2 (regexp-match #px"(?:^|\\s)exp=([A-Za-z0-9_.-]+)@spot([0-9]+)" raw))
        (and m2
             (let ([id-sym (valid-exp-id-sym (rx-group-str m2 1))]
                   [sp-n (string->number (rx-group-str m2 2))])
               (and id-sym
                    (hasheq 'experiment-id id-sym
                            'experiment-spot-idx (safe-nonneg-int sp-n 0)))))])]
    [(hash? raw)
     (define direct-id
       (valid-exp-id-sym
        (hget* raw '(experiment-id experiment_id exp-id exp_id) #f)))
     (cond
       [direct-id
        (define spot-raw
          (hget* raw '(experiment-spot-idx experiment_spot_idx spot-idx spot_idx) 0))
        (define spot-n
          (cond
            [(exact-nonnegative-integer? spot-raw) spot-raw]
            [(real? spot-raw) (safe-nonneg-int spot-raw 0)]
            [(string? spot-raw) (safe-nonneg-int (string->number (string-trim spot-raw)) 0)]
            [else 0]))
        (define lbl (hget* raw '(experiment-spot-label experiment_spot_label spot-label spot_label) #f))
        (define base-ht : (Immutable-HashTable Symbol Any)
          (hasheq 'experiment-id direct-id
                  'experiment-spot-idx spot-n))
        (if (or (symbol? lbl) (and (string? lbl) (> (string-length (string-trim lbl)) 0)))
            (hash-set base-ht 'spot-label (safe-sym lbl 'default))
            base-ht)]
       [else
        (or (let ([sub (hget* raw '(experiment experiment-selection experiment_selection) #f)])
              (and sub (extract-experiment-log-tag sub)))
            (let ([tag-str (hget* raw '(experiment-tag experiment_tag exp-tag log-tag tag) #f)])
              (and (string? tag-str) (extract-experiment-log-tag tag-str)))
            #f)])]
    [else #f]))

(: extract-econ-belief-meta (-> Any Any (Option (Immutable-HashTable Symbol Any))))
(define (extract-econ-belief-meta raw-mind mind-src)
  (define (pick [k : Symbol]) : Any
    (define v1 (hget* mind-src (list k) #f))
    (if (real? v1)
        v1
        (let ([v2 (hget* raw-mind (list k) #f)])
          (if (real? v2) v2 #f))))
  (define raw-cb (pick 'enemy-confirmed-bases))
  (define raw-eb (pick 'enemy-estimated-bases))
  (define raw-cg (pick 'enemy-confirmed-gases))
  (define raw-eg (pick 'enemy-estimated-gases))
  (if (or (real? raw-cb) (real? raw-eb) (real? raw-cg) (real? raw-eg))
      (let* ([cb (safe-nonneg-int raw-cb 0)]
             [eb (if (real? raw-eb) (safe-nonneg-int raw-eb cb) cb)]
             [cg (safe-nonneg-int raw-cg 0)]
             [eg (if (real? raw-eg) (safe-nonneg-int raw-eg cg) cg)])
        (ann (hasheq 'enemy-confirmed-bases cb
                     'enemy-estimated-bases eb
                     'enemy-confirmed-gases cg
                     'enemy-estimated-gases eg)
             (Immutable-HashTable Symbol Any)))
      #f))

(: extract-bot-step-log-record (->* () (Any Any Any) bot-step-log-record))
(define (extract-bot-step-log-record [raw-mind #f] [raw-goals #f] [raw-tactics #f])
  (if (and (bot-step-log-record? raw-mind)
           (not raw-goals)
           (not raw-tactics))
      raw-mind
      (let* ([mind-src (if (and (not raw-goals) (not raw-tactics) (hash? raw-mind) (hash-has-key? raw-mind 'mind))
                           (hash-ref raw-mind 'mind (lambda () raw-mind))
                           raw-mind)]
             [goal-src (or raw-goals
                           (and (hash? raw-mind) (hash-ref raw-mind 'goals (lambda () #f)))
                           raw-mind)]
             [tac-src (or raw-tactics
                          (and (hash? raw-mind) (hash-ref raw-mind 'tactics (lambda () #f)))
                          raw-mind)]
             [exp-meta (or (extract-experiment-log-tag raw-mind)
                           (extract-experiment-log-tag raw-goals)
                           (extract-experiment-log-tag raw-tactics)
                           (extract-experiment-log-tag mind-src)
                           (extract-experiment-log-tag goal-src)
                           (extract-experiment-log-tag tac-src))]
             [econ-meta (extract-econ-belief-meta raw-mind mind-src)]
             [rec (bot-step-log-record
                   (extract-mind-snapshot mind-src)
                   (extract-goal-snapshot goal-src)
                   (extract-tactics-snapshot tac-src))])
        (when exp-meta
          (record-exp-meta! rec exp-meta))
        (when econ-meta
          (record-econ-belief-meta! rec econ-meta))
        rec)))

(: fmt2 (-> Float String))
(define (fmt2 x)
  (real->decimal-string (safe-finite-real x 0.0) 2))

(: fmt-army (-> Real String))
(define (fmt-army x)
  (if (exact-integer? x)
      (number->string x)
      (real->decimal-string (safe-finite-real x 0.0) 1)))

(: format-bot-step-log-line (-> bot-step-log-record String))
(define (format-bot-step-log-line rec)
  (define m (bot-step-log-record-mind rec))
  (define g (bot-step-log-record-goals rec))
  (define t (bot-step-log-record-tactics rec))
  (define sched-str
    (string-join (map symbol->string (bot-goal-log-snapshot-scheduled-ids g)) ","))
  (define target-sec (bot-goal-log-snapshot-active-bo-target-sec g))
  (define timing-tag
    (if (> target-sec 0.0)
        (format "@~as" (round1 target-sec))
        ""))
  (define exp-meta (lookup-exp-meta rec))
  (define exp-tag
    (if exp-meta
        (format " exp=~a@spot~a"
                (hash-ref exp-meta 'experiment-id (lambda () 'unknown))
                (hash-ref exp-meta 'experiment-spot-idx (lambda () 0)))
        ""))
  (define econ-meta (lookup-econ-belief-meta rec))
  (define econ-tag
    (if econ-meta
        (format " eB=~a/~a eG=~a/~a"
                (hash-ref econ-meta 'enemy-confirmed-bases (lambda () 0))
                (hash-ref econ-meta 'enemy-estimated-bases (lambda () 0))
                (hash-ref econ-meta 'enemy-confirmed-gases (lambda () 0))
                (hash-ref econ-meta 'enemy-estimated-gases (lambda () 0)))
        ""))
  (format "[SCBOT_STATE] f=~a matchup=~a posture=~a pers=~a arch=~a win=~a conf=~a bayesian=(bluff=~a,rush=~a,hexp=~a,tsw=~a,camp=~a) goal=~a/~a~a(escrow=~aM/~aG,w=~a,army=~a) sched=(~a) tactics=(pos=~a,adv=~a,sec=~a,orders=~a)~a~a"
          (bot-mind-log-snapshot-frame m)
          (bot-mind-log-snapshot-matchup m)
          (bot-mind-log-snapshot-posture m)
          (bot-mind-log-snapshot-personality m)
          (bot-mind-log-snapshot-enemy-archetype m)
          (fmt2 (bot-mind-log-snapshot-win-prob m))
          (fmt2 (bot-mind-log-snapshot-confidence m))
          (fmt2 (bot-mind-log-snapshot-bluff-posterior m))
          (fmt2 (bot-mind-log-snapshot-rush-posterior m))
          (fmt2 (bot-mind-log-snapshot-hidden-expand-posterior m))
          (fmt2 (bot-mind-log-snapshot-tech-switch-posterior m))
          (fmt2 (bot-mind-log-snapshot-pad-camped-posterior m))
          (bot-goal-log-snapshot-active-bo-goal-kind g)
          (bot-goal-log-snapshot-active-bo-goal-sym g)
          timing-tag
          (bot-goal-log-snapshot-reserved-minerals g)
          (bot-goal-log-snapshot-reserved-gas g)
          (bot-goal-log-snapshot-target-workers g)
          (fmt-army (bot-goal-log-snapshot-target-army-supply g))
          sched-str
          (bot-tactics-log-snapshot-combat-posture t)
          (fmt2 (bot-tactics-log-snapshot-snowball-adv t))
          (bot-tactics-log-snapshot-retreat-sector t)
          (bot-tactics-log-snapshot-issued-orders t)
          exp-tag
          econ-tag))

(: bot-step-log-record->hash (-> bot-step-log-record (HashTable Symbol Any)))
(define (bot-step-log-record->hash rec)
  (define m (bot-step-log-record-mind rec))
  (define g (bot-step-log-record-goals rec))
  (define t (bot-step-log-record-tactics rec))
  (define econ-meta (lookup-econ-belief-meta rec))
  (define mind-ht : (HashTable Symbol Any)
    (let ([base-mind
           ((inst hash Symbol Any)
            'frame (bot-mind-log-snapshot-frame m)
            'race (bot-mind-log-snapshot-race m)
            'enemy-race (bot-mind-log-snapshot-enemy-race m)
            'matchup (bot-mind-log-snapshot-matchup m)
            'posture (bot-mind-log-snapshot-posture m)
            'personality (bot-mind-log-snapshot-personality m)
            'enemy-archetype (bot-mind-log-snapshot-enemy-archetype m)
            'win-prob (bot-mind-log-snapshot-win-prob m)
            'confidence (bot-mind-log-snapshot-confidence m)
            'bluff-posterior (bot-mind-log-snapshot-bluff-posterior m)
            'rush-posterior (bot-mind-log-snapshot-rush-posterior m)
            'hidden-expand-posterior (bot-mind-log-snapshot-hidden-expand-posterior m)
            'tech-switch-posterior (bot-mind-log-snapshot-tech-switch-posterior m)
            'pad-camped-posterior (bot-mind-log-snapshot-pad-camped-posterior m))])
      (if econ-meta
          (let* ([h1 (hash-set base-mind 'enemy-confirmed-bases
                               (hash-ref econ-meta 'enemy-confirmed-bases (lambda () 0)))]
                 [h2 (hash-set h1 'enemy-estimated-bases
                               (hash-ref econ-meta 'enemy-estimated-bases (lambda () 0)))]
                 [h3 (hash-set h2 'enemy-confirmed-gases
                               (hash-ref econ-meta 'enemy-confirmed-gases (lambda () 0)))])
            (hash-set h3 'enemy-estimated-gases
                      (hash-ref econ-meta 'enemy-estimated-gases (lambda () 0))))
          base-mind)))
  (define goals-ht : (HashTable Symbol Any)
    ((inst hash Symbol Any)
     'active-bo-goal-sym (bot-goal-log-snapshot-active-bo-goal-sym g)
     'active-bo-goal-kind (bot-goal-log-snapshot-active-bo-goal-kind g)
     'active-bo-target-count (bot-goal-log-snapshot-active-bo-target-count g)
     'active-bo-target-sec (bot-goal-log-snapshot-active-bo-target-sec g)
     'reserved-minerals (bot-goal-log-snapshot-reserved-minerals g)
     'reserved-gas (bot-goal-log-snapshot-reserved-gas g)
     'target-workers (bot-goal-log-snapshot-target-workers g)
     'target-army-supply (bot-goal-log-snapshot-target-army-supply g)
     'scheduled-ids (bot-goal-log-snapshot-scheduled-ids g)
     'escrow-blocked-ids (bot-goal-log-snapshot-escrow-blocked-ids g)))
  (define tactics-ht : (HashTable Symbol Any)
    ((inst hash Symbol Any)
     'combat-posture (bot-tactics-log-snapshot-combat-posture t)
     'snowball-adv (bot-tactics-log-snapshot-snowball-adv t)
     'retreat-sector (bot-tactics-log-snapshot-retreat-sector t)
     'burrowed-count (bot-tactics-log-snapshot-burrowed-count t)
     'shimmer-alerts (bot-tactics-log-snapshot-shimmer-alerts t)
     'swapped-addons (bot-tactics-log-snapshot-swapped-addons t)
     'issued-orders (bot-tactics-log-snapshot-issued-orders t)))
  (define base-ht : (HashTable Symbol Any)
    ((inst hash Symbol Any)
     'frame (bot-mind-log-snapshot-frame m)
     'matchup (bot-mind-log-snapshot-matchup m)
     'mind mind-ht
     'goals goals-ht
     'tactics tactics-ht))
  (define exp-meta (lookup-exp-meta rec))
  (define ht-with-exp : (HashTable Symbol Any)
    (if exp-meta
        (let* ([ht1 (hash-set base-ht 'experiment-id
                              (hash-ref exp-meta 'experiment-id (lambda () 'unknown)))]
               [ht2 (hash-set ht1 'experiment-spot-idx
                              (hash-ref exp-meta 'experiment-spot-idx (lambda () 0)))])
          (if (hash-has-key? exp-meta 'spot-label)
              (hash-set ht2 'experiment-spot-label (hash-ref exp-meta 'spot-label (lambda () 'default)))
              ht2))
        base-ht))
  (if econ-meta
      (let* ([h1 (hash-set ht-with-exp 'enemy-confirmed-bases
                           (hash-ref econ-meta 'enemy-confirmed-bases (lambda () 0)))]
             [h2 (hash-set h1 'enemy-estimated-bases
                           (hash-ref econ-meta 'enemy-estimated-bases (lambda () 0)))]
             [h3 (hash-set h2 'enemy-confirmed-gases
                           (hash-ref econ-meta 'enemy-confirmed-gases (lambda () 0)))])
        (hash-set h3 'enemy-estimated-gases
                  (hash-ref econ-meta 'enemy-estimated-gases (lambda () 0))))
      ht-with-exp))
