#lang typed/racket/base

;; =============================================================================
;; Layer 0c: Typed Structured Step-Logging & Snapshot Extraction (`lib/sc2-logging.rkt`)
;; =============================================================================

(require racket/string
         "sc2-types.rkt")

(provide
 (struct-out bot-mind-log-snapshot)
 (struct-out bot-goal-log-snapshot)
 (struct-out bot-tactics-log-snapshot)
 (struct-out bot-step-log-record)
 should-emit-step-log?
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
     (bot-goal-log-snapshot
      (safe-sym (hget* src '(active-bo-goal-sym bo-goal-sym saving-for) def-sym) def-sym)
      (safe-sym (hget* src '(active-bo-goal-kind bo-goal-kind) def-kind) def-kind)
      (safe-nonneg-int (hget* src '(active-bo-target-count bo-target-count) def-cnt) def-cnt)
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
                          raw-mind)])
        (bot-step-log-record
         (extract-mind-snapshot mind-src)
         (extract-goal-snapshot goal-src)
         (extract-tactics-snapshot tac-src)))))

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
  (format "[SCBOT_STATE] f=~a matchup=~a posture=~a pers=~a arch=~a win=~a conf=~a bayesian=(bluff=~a,rush=~a,hexp=~a,tsw=~a,camp=~a) goal=~a/~a(escrow=~aM/~aG,w=~a,army=~a) sched=(~a) tactics=(pos=~a,adv=~a,sec=~a,orders=~a)"
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
          (bot-goal-log-snapshot-reserved-minerals g)
          (bot-goal-log-snapshot-reserved-gas g)
          (bot-goal-log-snapshot-target-workers g)
          (fmt-army (bot-goal-log-snapshot-target-army-supply g))
          sched-str
          (bot-tactics-log-snapshot-combat-posture t)
          (fmt2 (bot-tactics-log-snapshot-snowball-adv t))
          (bot-tactics-log-snapshot-retreat-sector t)
          (bot-tactics-log-snapshot-issued-orders t)))

(: bot-step-log-record->hash (-> bot-step-log-record (HashTable Symbol Any)))
(define (bot-step-log-record->hash rec)
  (define m (bot-step-log-record-mind rec))
  (define g (bot-step-log-record-goals rec))
  (define t (bot-step-log-record-tactics rec))
  (define mind-ht : (HashTable Symbol Any)
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
     'pad-camped-posterior (bot-mind-log-snapshot-pad-camped-posterior m)))
  (define goals-ht : (HashTable Symbol Any)
    ((inst hash Symbol Any)
     'active-bo-goal-sym (bot-goal-log-snapshot-active-bo-goal-sym g)
     'active-bo-goal-kind (bot-goal-log-snapshot-active-bo-goal-kind g)
     'active-bo-target-count (bot-goal-log-snapshot-active-bo-target-count g)
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
  ((inst hash Symbol Any)
   'frame (bot-mind-log-snapshot-frame m)
   'matchup (bot-mind-log-snapshot-matchup m)
   'mind mind-ht
   'goals goals-ht
   'tactics tactics-ht))
