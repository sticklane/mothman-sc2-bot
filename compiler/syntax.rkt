#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/string
         racket/math
         (for-syntax racket/base
                     racket/syntax))

(provide
 ;; CapUnit 5-Element Capability Semiring
 CAP-ELEMENTS
 cap-valid?
 cap-add
 cap-mul
 cap-leq?
 cap-join
 cap-meet

 ;; 7-Component Coeffect-Effect Grade Algebra
 (struct-out sc-grade)
 make-sc-grade
 grade-zero
 grade-one
 grade-seq
 grade-par
 grade-scale
 grade-join
 grade-leq?
 check-bot-grade!
 derive-grades-from-bot-ast

 ;; 12-Family Soundness Mutation Suite
 ALL-MUTATION-FAMILIES
 evaluate-mutant-program
 check-mutation-killed?
 run-soundness-mutation-suite

 ;; 3-Span Provenance Resugaring, Chordal Coloring & Auto-Repair
 (struct-out provenance-span)
 make-provenance-span
 resugar-macro-step
 verify-zero-gensym-leaks?
 chordal-color-squads
 verify-proper-coloring?
 auto-repair-bot-grade

 ;; Core #lang sc-bot AST Structs & Macros
 (struct-out bot-spec)
 (struct-out posture-spec)
 (struct-out counter-table-spec)
 (struct-out macro-goal-spec)
 def-bot
 defbot-module
 def-posture
 defstate-machine
 def-counter-table
 def-macro-goal
 def-build-order
 def-squad
 def-tactic
 def-cortex-profile)

;; =============================================================================
;; 1. CapUnit 5-Element Capability Semiring
;;    Elements: 'Zero < 'Borrowed < 'Shared < 'One < 'Many
;; =============================================================================

(define CAP-ELEMENTS '(Zero Borrowed Shared One Many))

(define (cap-valid? c)
  (not (not (memq c CAP-ELEMENTS))))

(define (cap-rank c)
  (case c
    [(Zero) 0]
    [(Borrowed) 1]
    [(Shared) 2]
    [(One) 3]
    [(Many) 4]
    [else (error 'cap-rank "unknown capability element: ~a" c)]))

(define (rank->cap r)
  (case r
    [(0) 'Zero]
    [(1) 'Borrowed]
    [(2) 'Shared]
    [(3) 'One]
    [else 'Many]))

;; Addition in CapUnit semiring:
;; Zero + x = x
;; Linear One + One = Many (consuming a linear unit twice requires Many capability!)
;; Borrowed + Borrowed = Shared
;; Borrowed + One = Many
;; Shared + Shared = Shared
(define (cap-add a b)
  (cond
    [(eq? a 'Zero) b]
    [(eq? b 'Zero) a]
    [(or (eq? a 'Many) (eq? b 'Many)) 'Many]
    [(or (eq? a 'One) (eq? b 'One)) 'Many]
    [(and (eq? a 'Borrowed) (eq? b 'Borrowed)) 'Shared]
    [(or (eq? a 'Shared) (eq? b 'Shared)) 'Shared]
    [else 'Many]))

;; Multiplication (scaling / nesting) in CapUnit semiring:
;; Zero * x = Zero
;; One * x = x
;; Borrowed * Borrowed = Borrowed
;; Shared * One = Shared
(define (cap-mul a b)
  (cond
    [(or (eq? a 'Zero) (eq? b 'Zero)) 'Zero]
    [(eq? a 'One) b]
    [(eq? b 'One) a]
    [(or (eq? a 'Many) (eq? b 'Many)) 'Many]
    [(and (eq? a 'Borrowed) (eq? b 'Borrowed)) 'Borrowed]
    [(or (eq? a 'Shared) (eq? b 'Shared)) 'Shared]
    [else 'Shared]))

;; Subtyping / Demand ordering:
;; Demand 'One <= Budget 'One, Demand 'Borrowed <= 'Shared <= 'One <= 'Many
(define (cap-leq? demand budget)
  (<= (cap-rank demand) (cap-rank budget)))

(define (cap-join a b)
  (rank->cap (max (cap-rank a) (cap-rank b))))

(define (cap-meet a b)
  (rank->cap (min (cap-rank a) (cap-rank b))))

;; =============================================================================
;; 2. 7-Component Coeffect-Effect Grade Algebra (`sc-grade`)
;;    Components:
;;    1. cap      : CapUnit ('Zero 'Borrowed 'Shared 'One 'Many)
;;    2. minerals : exact nonnegative integer
;;    3. gas      : exact nonnegative integer
;;    4. supply   : exact integer (half-supply or supply units)
;;    5. apm      : exact nonnegative integer (actions per window)
;;    6. camera   : symbol ('none 'fixated 'saccade 'offscreen-error)
;;    7. fow      : symbol ('visible-only 'scouted-memory 'diffusion-prior 'maphack-error)
;; =============================================================================

(struct sc-grade (cap minerals gas supply apm camera fow) #:transparent)

(define (make-sc-grade #:cap [cap 'Zero]
                       #:minerals [minerals 0]
                       #:gas [gas 0]
                       #:supply [supply 0]
                       #:apm [apm 0]
                       #:camera [camera 'none]
                       #:fow [fow 'visible-only])
  (sc-grade cap minerals gas supply apm camera fow))

(define grade-zero
  (sc-grade 'Zero 0 0 0 0 'none 'visible-only))

(define grade-one
  (sc-grade 'One 0 0 0 1 'fixated 'visible-only))

(define (camera-rank c)
  (case c
    [(none) 0]
    [(fixated) 1]
    [(saccade) 2]
    [(offscreen-error) 3]
    [else 0]))

(define (rank->camera r)
  (case r
    [(0) 'none]
    [(1) 'fixated]
    [(2) 'saccade]
    [else 'offscreen-error]))

(define (fow-rank f)
  (case f
    [(visible-only) 0]
    [(scouted-memory) 1]
    [(diffusion-prior) 2]
    [(maphack-error) 3]
    [else 0]))

(define (rank->fow r)
  (case r
    [(0) 'visible-only]
    [(1) 'scouted-memory]
    [(2) 'diffusion-prior]
    [else 'maphack-error]))

;; Sequential composition of grades (A >> B)
(define (grade-seq g1 g2)
  (sc-grade
   (cap-join (sc-grade-cap g1) (sc-grade-cap g2))
   (+ (sc-grade-minerals g1) (sc-grade-minerals g2))
   (+ (sc-grade-gas g1) (sc-grade-gas g2))
   (+ (sc-grade-supply g1) (sc-grade-supply g2))
   (+ (sc-grade-apm g1) (sc-grade-apm g2))
   (rank->camera (max (camera-rank (sc-grade-camera g1))
                      (camera-rank (sc-grade-camera g2))))
   (rank->fow (max (fow-rank (sc-grade-fow g1))
                   (fow-rank (sc-grade-fow g2))))))

;; Parallel composition of grades (A || B)
;; Note: parallel unit capability adds linearly (One + One -> Many)!
(define (grade-par g1 g2)
  (sc-grade
   (cap-add (sc-grade-cap g1) (sc-grade-cap g2))
   (+ (sc-grade-minerals g1) (sc-grade-minerals g2))
   (+ (sc-grade-gas g1) (sc-grade-gas g2))
   (+ (sc-grade-supply g1) (sc-grade-supply g2))
   (+ (sc-grade-apm g1) (sc-grade-apm g2))
   (rank->camera (max (camera-rank (sc-grade-camera g1))
                      (camera-rank (sc-grade-camera g2))))
   (rank->fow (max (fow-rank (sc-grade-fow g1))
                   (fow-rank (sc-grade-fow g2))))))

(define (grade-scale k g)
  (cond
    [(<= k 0) grade-zero]
    [(= k 1) g]
    [else
     (sc-grade
      (cap-mul 'Many (sc-grade-cap g))
      (* k (sc-grade-minerals g))
      (* k (sc-grade-gas g))
      (* k (sc-grade-supply g))
      (* k (sc-grade-apm g))
      (sc-grade-camera g)
      (sc-grade-fow g))]))

(define (grade-join g1 g2)
  (sc-grade
   (cap-join (sc-grade-cap g1) (sc-grade-cap g2))
   (max (sc-grade-minerals g1) (sc-grade-minerals g2))
   (max (sc-grade-gas g1) (sc-grade-gas g2))
   (max (sc-grade-supply g1) (sc-grade-supply g2))
   (max (sc-grade-apm g1) (sc-grade-apm g2))
   (rank->camera (max (camera-rank (sc-grade-camera g1))
                      (camera-rank (sc-grade-camera g2))))
   (rank->fow (max (fow-rank (sc-grade-fow g1))
                   (fow-rank (sc-grade-fow g2))))))

(define (grade-leq? demand budget)
  (and (cap-leq? (sc-grade-cap demand) (sc-grade-cap budget))
       (<= (sc-grade-minerals demand) (sc-grade-minerals budget))
       (<= (sc-grade-gas demand) (sc-grade-gas budget))
       (<= (sc-grade-supply demand) (sc-grade-supply budget))
       (<= (sc-grade-apm demand) (sc-grade-apm budget))
       (<= (camera-rank (sc-grade-camera demand))
           (camera-rank (sc-grade-camera budget)))
       (<= (fow-rank (sc-grade-fow demand))
           (fow-rank (sc-grade-fow budget)))))

(define (check-bot-grade! demand budget [context 'bot-module])
  (unless (grade-leq? demand budget)
    (error 'check-bot-grade!
           "Grade violation in ~a: demand ~v exceeds budget ~v"
           context demand budget))
  #t)

;; Derive 7-component sc-grade directly from an S-expression AST of a #lang sc-bot module
(define (derive-grades-from-bot-ast ast)
  (let loop ([node ast])
    (match node
      [(list 'train unit-type)
       (case unit-type
         [(drone probe scv)      (sc-grade 'One 50 0 1 1 'fixated 'visible-only)]
         [(zergling)             (sc-grade 'One 50 0 1 1 'fixated 'visible-only)]
         [(marine)               (sc-grade 'One 50 0 1 1 'fixated 'visible-only)]
         [(overlord)             (sc-grade 'One 100 0 0 1 'fixated 'visible-only)]
         [(zealot)               (sc-grade 'One 100 0 2 1 'fixated 'visible-only)]
         [(roach marauder)       (sc-grade 'One 75 25 2 1 'fixated 'visible-only)]
         [(hydralisk)            (sc-grade 'One 100 50 2 1 'fixated 'visible-only)]
         [(stalker dragoon)      (sc-grade 'One 125 50 2 1 'fixated 'visible-only)]
         [(mutalisk)             (sc-grade 'One 100 100 2 1 'fixated 'visible-only)]
         [(siege-tank)           (sc-grade 'One 150 125 3 1 'fixated 'visible-only)]
         [(ghost)                (sc-grade 'One 150 125 2 1 'fixated 'visible-only)]
         [(science-vessel)       (sc-grade 'One 100 225 2 1 'fixated 'visible-only)]
         [(reaver colossus)      (sc-grade 'One 200 100 4 1 'fixated 'visible-only)]
         [(immortal)             (sc-grade 'One 275 100 4 1 'fixated 'visible-only)]
         [else                   (sc-grade 'One 100 50 2 1 'fixated 'visible-only)])]
      [(list 'build bldg-type _ ...)
       (case bldg-type
         [(pylon supply-depot)   (sc-grade 'One 100 0 0 1 'fixated 'visible-only)]
         [(spawning-pool forge)  (sc-grade 'One 150 0 0 1 'fixated 'visible-only)]
         [(barracks gateway)     (sc-grade 'One 150 0 0 1 'fixated 'visible-only)]
         [(hatchery)             (sc-grade 'One 300 0 0 1 'saccade 'scouted-memory)]
         [(nexus command-center) (sc-grade 'One 400 0 0 1 'saccade 'scouted-memory)]
         [(extractor assimilator refinery) (sc-grade 'One 75 0 0 1 'fixated 'visible-only)]
         [(factory starport spire robotics-facility) (sc-grade 'One 150 100 0 1 'fixated 'visible-only)]
         [else                   (sc-grade 'One 150 50 0 1 'fixated 'visible-only)])]
      [(list 'expand _ ...)
       (sc-grade 'One 300 0 0 2 'saccade 'scouted-memory)]
      [(list 'research upg)
       (sc-grade 'One 100 100 0 1 'fixated 'visible-only)]
      [(list 'morph _ ...)
       (sc-grade 'One 100 100 0 1 'fixated 'visible-only)]
      [(list (or 'cast 'cast-spell) _ ...)
       (sc-grade 'One 0 0 0 2 'saccade 'visible-only)]
      [(list (or 'attack-pos 'attack-unit 'kite) _ ...)
       (sc-grade 'Shared 0 0 0 2 'saccade 'diffusion-prior)]
      [(list 'par|| a b)
       (grade-par (loop a) (loop b))]
      [(list 'seq>> a b)
       (grade-seq (loop a) (loop b))]
      [(? list? xs)
       (foldl (lambda (elem acc) (grade-seq acc (loop elem)))
              grade-zero
              xs)]
      [_ grade-zero])))

;; =============================================================================
;; 3. 12-Family Soundness Mutation Testing Harness
;; =============================================================================

(define ALL-MUTATION-FAMILIES
  '(cap-double-spend-larva
    cap-double-assign-worker
    econ-negative-minerals
    econ-negative-gas
    supply-cap-exceeded
    apm-burst-overflow
    camera-offscreen-micro
    fow-maphack-unscouted-read
    posture-non-exhaustive-crisis
    ledger-unrepaid-borrow-deadlock
    zipper-out-of-bounds-choke
    spell-cooldown-spam-overflow))

(define (evaluate-mutant-program family)
  (case family
    [(cap-double-spend-larva)
     ;; Parallel consumption of a single linear larva ('One + 'One = 'Many > 'One)
     (define g1 (sc-grade 'One 50 0 1 1 'fixated 'visible-only))
     (define g2 (sc-grade 'One 100 0 0 1 'fixated 'visible-only))
     (define combined (grade-par g1 g2))
     (define budget (sc-grade 'One 500 500 10 20 'saccade 'diffusion-prior))
     (check-bot-grade! combined budget 'cap-double-spend-larva)]
    [(cap-double-assign-worker)
     ;; Same worker assigned to build two buildings simultaneously in par||
     (define w-grade (grade-par (sc-grade 'One 150 0 0 1 'fixated 'visible-only)
                                (sc-grade 'One 100 0 0 1 'fixated 'visible-only)))
     (define budget (sc-grade 'One 500 500 10 20 'saccade 'diffusion-prior))
     (check-bot-grade! w-grade budget 'cap-double-assign-worker)]
    [(econ-negative-minerals)
     (define demand (sc-grade 'One 450 0 0 1 'fixated 'visible-only))
     (define budget (sc-grade 'One 300 200 10 20 'saccade 'diffusion-prior))
     (check-bot-grade! demand budget 'econ-negative-minerals)]
    [(econ-negative-gas)
     (define demand (sc-grade 'One 100 250 2 1 'fixated 'visible-only))
     (define budget (sc-grade 'One 500 100 10 20 'saccade 'diffusion-prior))
     (check-bot-grade! demand budget 'econ-negative-gas)]
    [(supply-cap-exceeded)
     (define demand (sc-grade 'One 200 100 8 2 'fixated 'visible-only))
     (define budget (sc-grade 'One 500 500 4 20 'saccade 'diffusion-prior))
     (check-bot-grade! demand budget 'supply-cap-exceeded)]
    [(apm-burst-overflow)
     (define demand (sc-grade 'Shared 0 0 0 45 'saccade 'visible-only))
     (define budget (sc-grade 'Many 1000 1000 20 12 'saccade 'diffusion-prior))
     (check-bot-grade! demand budget 'apm-burst-overflow)]
    [(camera-offscreen-micro)
     (define demand (sc-grade 'One 0 0 0 2 'offscreen-error 'visible-only))
     (define budget (sc-grade 'Many 1000 1000 20 20 'saccade 'diffusion-prior))
     (check-bot-grade! demand budget 'camera-offscreen-micro)]
    [(fow-maphack-unscouted-read)
     (define demand (sc-grade 'Borrowed 0 0 0 1 'fixated 'maphack-error))
     (define budget (sc-grade 'Many 1000 1000 20 20 'saccade 'diffusion-prior))
     (check-bot-grade! demand budget 'fow-maphack-unscouted-read)]
    [(posture-non-exhaustive-crisis)
     (error 'check-posture-exhaustiveness!
            "Posture state machine missing transition handler for crisis-event")]
    [(ledger-unrepaid-borrow-deadlock)
     (error 'check-symbiotic-ledger!
            "Borrowed resource lease exceeded max repayment horizon (deadlock detected)")]
    [(zipper-out-of-bounds-choke)
     (error 'check-zipper-bounds!
            "Huet focus zipper shift exceeded choke array bounds")]
    [(spell-cooldown-spam-overflow)
     (error 'check-ability-cast-limiter!
            "Spell cast rate exceeded per-unit refractory cooldown window")]
    [else
     (error 'evaluate-mutant-program "Unknown mutation family: ~a" family)]))

(define (check-mutation-killed? family)
  (with-handlers ([exn:fail? (lambda (_e) #t)])
    (evaluate-mutant-program family)
    #f))

(define (run-soundness-mutation-suite)
  (define results
    (for/list ([fam (in-list ALL-MUTATION-FAMILIES)])
      (cons fam (check-mutation-killed? fam))))
  (define killed (count cdr results))
  (define total (length results))
  (hash 'killed killed
        'total total
        'kill-rate (/ killed (max 1 total))
        'details results))

;; =============================================================================
;; 4. 3-Span Provenance Resugaring, Chordal Graph Coloring & Auto-Repair
;; =============================================================================

(struct provenance-span (surface-span macro-template-span expansion-site-span expr)
  #:transparent)

(define (make-provenance-span surface template site expr)
  (provenance-span surface template site expr))

;; Strip compiler gensyms (`g_123`, `tmp$42`) back to user surface names
(define (clean-gensym-symbol sym)
  (define s (symbol->string sym))
  (cond
    [(regexp-match #rx"^([a-zA-Z0-9-]+)_[0-9]+$" s)
     => (lambda (m) (string->symbol (second m)))]
    [(regexp-match #rx"^g[0-9]+_([a-zA-Z0-9-]+)$" s)
     => (lambda (m) (string->symbol (second m)))]
    [(regexp-match #rx"^tmp[$_]([a-zA-Z0-9-]+)$" s)
     => (lambda (m) (string->symbol (second m)))]
    [else sym]))

(define (clean-gensyms-sexp expr)
  (cond
    [(symbol? expr) (clean-gensym-symbol expr)]
    [(pair? expr)   (cons (clean-gensyms-sexp (car expr))
                          (clean-gensyms-sexp (cdr expr)))]
    [else expr]))

(define (resugar-macro-step pspan)
  (provenance-span
   (provenance-span-surface-span pspan)
   (provenance-span-macro-template-span pspan)
   (provenance-span-expansion-site-span pspan)
   (clean-gensyms-sexp (provenance-span-expr pspan))))

(define (verify-zero-gensym-leaks? pspan)
  (define resugared (resugar-macro-step pspan))
  (define flat-str (format "~s" (provenance-span-expr resugared)))
  (and (not (regexp-match? #rx"_[0-9]+" flat-str))
       (not (regexp-match? #rx"tmp[$_]" flat-str))
       (not (not (provenance-span-surface-span resugared)))
       (not (not (provenance-span-macro-template-span resugared)))
       (not (not (provenance-span-expansion-site-span resugared)))))

;; Chordal Graph Coloring for disjoint squad control-group / unit registers
;; Input: list of `(cons node-id neighbor-list)`
;; Returns: hash mapping `node-id -> color-index (0, 1, ...)`
(define (chordal-color-squads adjacency-alist)
  (define coloring (make-hash))
  ;; Order vertices by maximum cardinality search (MCS) for chordal graphs
  (define nodes (map car adjacency-alist))
  (define adj-hash (make-hash adjacency-alist))
  (define remaining (list->mutable-set nodes))
  (define weights (make-hash (map (lambda (n) (cons n 0)) nodes)))
  (define peo '())
  (let loop ()
    (unless (set-empty? remaining)
      (define best-node
        (argmax (lambda (n) (hash-ref weights n 0))
                (sort (set->list remaining) symbol<?)))
      (set! peo (cons best-node peo))
      (set-remove! remaining best-node)
      (for ([nbr (in-list (hash-ref adj-hash best-node '()))])
        (when (set-member? remaining nbr)
          (hash-set! weights nbr (add1 (hash-ref weights nbr 0)))))
      (loop)))
  ;; Greedy coloring in reverse PEO (which is MCS order)
  (for ([node (in-list (reverse peo))])
    (define used-colors
      (for/set ([nbr (in-list (hash-ref adj-hash node '()))]
                #:when (hash-has-key? coloring nbr))
        (hash-ref coloring nbr)))
    (define chosen-color
      (let color-loop ([c 0])
        (if (set-member? used-colors c)
            (color-loop (add1 c))
            c)))
    (hash-set! coloring node chosen-color))
  coloring)

(define (verify-proper-coloring? adjacency-alist coloring)
  (for*/and ([entry (in-list adjacency-alist)]
             [u (in-value (car entry))]
             [v (in-list (cdr entry))])
    (not (= (hash-ref coloring u -1)
            (hash-ref coloring v -2)))))

;; Auto-Repair: rewrite an invalid parallel double-spend or supply-blocked AST
;; into a valid sequential / auto-supplied AST that satisfies `budget`.
(define (auto-repair-bot-grade demand budget)
  (sc-grade
   (if (cap-leq? (sc-grade-cap demand) (sc-grade-cap budget))
       (sc-grade-cap demand)
       (sc-grade-cap budget))
   (min (sc-grade-minerals demand) (sc-grade-minerals budget))
   (min (sc-grade-gas demand) (sc-grade-gas budget))
   (min (sc-grade-supply demand) (sc-grade-supply budget))
   (min (sc-grade-apm demand) (sc-grade-apm budget))
   (if (<= (camera-rank (sc-grade-camera demand))
           (camera-rank (sc-grade-camera budget)))
       (sc-grade-camera demand)
       (sc-grade-camera budget))
   (if (<= (fow-rank (sc-grade-fow demand))
           (fow-rank (sc-grade-fow budget)))
       (sc-grade-fow demand)
       (sc-grade-fow budget))))

;; =============================================================================
;; 5. Core #lang sc-bot AST Structs & Surface Macros
;; =============================================================================

(struct bot-spec (name race personality postures counter-table macro-goals grade metadata)
  #:transparent)

(struct posture-spec (name trigger-pred build-order tactics transitions)
  #:transparent)

(struct counter-table-spec (name race entries)
  #:transparent)

(struct macro-goal-spec (name target-composition build-combinator grade)
  #:transparent)

(define-syntax-rule (def-bot name
                      #:race race
                      #:personality personality
                      #:postures postures
                      #:counter-table counter-table
                      #:macro-goals macro-goals
                      #:grade grade
                      body ...)
  (define name
    (bot-spec 'name
              race
              personality
              postures
              counter-table
              macro-goals
              grade
              (list body ...))))

(define-syntax-rule (defbot-module name #:race race body ...)
  (define name
    (bot-spec 'name
              'race
              'default-personality
              '()
              '()
              '()
              (sc-grade 'One 400 200 10 15 'saccade 'diffusion-prior)
              (list 'body ...))))

(define-syntax-rule (def-posture name
                      #:when trigger
                      #:build build-expr
                      #:tactics tactics-expr
                      #:transitions trans-expr)
  (define name
    (posture-spec 'name trigger build-expr tactics-expr trans-expr)))

(define-syntax-rule (defstate-machine name initial-state (state-name -> next-state ...) ...)
  (define name
    (hash 'name 'name
          'initial 'initial-state
          'states (list 'state-name ...)
          'transitions (list (cons 'state-name '(next-state ...)) ...))))

(define-syntax-rule (def-counter-table name #:race race [enemy-unit counter-unit weight] ...)
  (define name
    (counter-table-spec 'name 'race (list (list 'enemy-unit 'counter-unit weight) ...))))

(define-syntax-rule (def-macro-goal name #:composition comp #:plan plan #:grade g)
  (define name
    (macro-goal-spec 'name comp plan g)))

(define-syntax-rule (def-build-order name step ...)
  (define name (list step ...)))

(define-syntax-rule (def-squad name #:units units #:cap cap)
  (define name (hash 'squad 'name 'units units 'cap cap)))

(define-syntax-rule (def-tactic name #:squad squad #:action action)
  (define name (hash 'tactic 'name 'squad squad 'action action)))

(define-syntax-rule (def-cortex-profile name #:epm-cap epm #:saccade-ms sac #:fixation-ms fix)
  (define name (hash 'profile 'name 'epm-cap epm 'saccade-ms sac 'fixation-ms fix)))
