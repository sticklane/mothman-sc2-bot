#lang racket/base

;; =============================================================================
;; Loop 86C Track B: Believed Enemy Bases & Gases (`eB=<conf>/<est> eG=<conf>/<est>`)
;; Structured `[SCBOT_STATE]` Logging & ABI-Preservation Tests
;; =============================================================================

(require racket/string
         "../lib/sc2-types.rkt"
         "../lib/sc2-logging.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check-true name expr)
  (if expr
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected truthy, got ~s\n" name expr))))

(define (check-equal name actual expected)
  (if (equal? actual expected)
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected ~s, got ~s\n" name expected actual))))

;; -----------------------------------------------------------------------------
;; 1. Zero Struct ABI Change (`bot-mind-log-snapshot` stays 14 fields!)
;; -----------------------------------------------------------------------------
(define legacy-rec
  (extract-bot-step-log-record
   (hash 'frame 672 'race 'Terran 'enemy-race 'Protoss 'posture 'timing-push
         'personality 'aggressive 'enemy-archetype 'stalker-colossus
         'win-prob 0.64 'confidence 0.81
         'bluff-posterior 0.02 'rush-posterior 0.15
         'hidden-expand-posterior 0.22 'tech-switch-posterior 0.11
         'pad-camped-posterior 0.04)
   (pro-bo-eval-result 'TvP (pro-bo-goal 'train 'marine 4 20 #f 0.0) '() 0 0 22 4)
   (hash 'combat-posture 'hold 'snowball-adv 0.15 'retreat-sector 2 'issued-orders 7)))

(check-equal "l86-log-abi-mind-14-fields"
             (sub1 (vector-length (struct->vector (bot-step-log-record-mind legacy-rec))))
             14)
(check-equal "l86-log-abi-record-3-fields"
             (sub1 (vector-length (struct->vector legacy-rec)))
             3)

;; -----------------------------------------------------------------------------
;; 2. Legacy Byte-Identical Output (ZERO `eB=`/`eG=` when keys omitted!)
;; -----------------------------------------------------------------------------
(define legacy-line (format-bot-step-log-line legacy-rec))
(check-true "l86-log-legacy-prefix"
            (string-prefix? legacy-line "[SCBOT_STATE] f=672 matchup=TvP "))
(check-true "l86-log-legacy-no-eB"
            (not (string-contains? legacy-line " eB=")))
(check-true "l86-log-legacy-no-eG"
            (not (string-contains? legacy-line " eG=")))
(check-true "l86-log-legacy-ends-with-tactics"
            (string-suffix? legacy-line "tactics=(pos=hold,adv=0.15,sec=2,orders=7)"))

(define legacy-ht (bot-step-log-record->hash legacy-rec))
(check-true "l86-log-legacy-hash-no-eB-top"
            (not (hash-has-key? legacy-ht 'enemy-estimated-bases)))
(check-true "l86-log-legacy-hash-no-eG-top"
            (not (hash-has-key? legacy-ht 'enemy-estimated-gases)))
(check-true "l86-log-legacy-hash-no-eB-mind"
            (not (hash-has-key? (hash-ref legacy-ht 'mind) 'enemy-estimated-bases)))

;; -----------------------------------------------------------------------------
;; 3. Full `eB=<conf>/<est> eG=<conf>/<est>` Formatting & Hash Roundtrip
;; -----------------------------------------------------------------------------
(define econ-rec
  (extract-bot-step-log-record
   (hash 'frame 13440 'race 'Protoss 'enemy-race 'Terran 'posture 'macro
         'personality 'balanced 'enemy-archetype 'mech-turtle
         'win-prob 0.54 'confidence 0.78
         'bluff-posterior 0.05 'rush-posterior 0.08
         'hidden-expand-posterior 0.62 'tech-switch-posterior 0.14
         'pad-camped-posterior 0.71
         'enemy-confirmed-bases 2
         'enemy-estimated-bases 4
         'enemy-confirmed-gases 1
         'enemy-estimated-gases 5)
   (pro-bo-eval-result 'PvT (pro-bo-goal 'build 'nexus 4 480 #f 480.0) '() 400 0 62 40)
   (hash 'combat-posture 'attack 'snowball-adv 0.32 'retreat-sector 3 'issued-orders 18)))

(define econ-line (format-bot-step-log-line econ-rec))
(check-true "l86-log-econ-suffix-exact"
            (string-suffix? econ-line "tactics=(pos=attack,adv=0.32,sec=3,orders=18) eB=2/4 eG=1/5"))
(check-true "l86-log-econ-still-parseable-frame-hexp-rush-pos-arch"
            (and (equal? (cadr (regexp-match #px"f=([0-9]+)" econ-line)) "13440")
                 (equal? (cadr (regexp-match #px"hexp=([0-9.]+)" econ-line)) "0.62")
                 (equal? (cadr (regexp-match #px"rush=([0-9.]+)" econ-line)) "0.08")
                 (equal? (cadr (regexp-match #px"arch=([^\\s]+)" econ-line)) "mech-turtle")
                 (string-contains? econ-line "pos=attack")))

(define econ-ht (bot-step-log-record->hash econ-rec))
(check-equal "l86-log-econ-hash-top-cb" (hash-ref econ-ht 'enemy-confirmed-bases) 2)
(check-equal "l86-log-econ-hash-top-eb" (hash-ref econ-ht 'enemy-estimated-bases) 4)
(check-equal "l86-log-econ-hash-top-cg" (hash-ref econ-ht 'enemy-confirmed-gases) 1)
(check-equal "l86-log-econ-hash-top-eg" (hash-ref econ-ht 'enemy-estimated-gases) 5)
(define econ-mind-ht (hash-ref econ-ht 'mind))
(check-equal "l86-log-econ-hash-mind-cb" (hash-ref econ-mind-ht 'enemy-confirmed-bases) 2)
(check-equal "l86-log-econ-hash-mind-eb" (hash-ref econ-mind-ht 'enemy-estimated-bases) 4)
(check-equal "l86-log-econ-hash-mind-cg" (hash-ref econ-mind-ht 'enemy-confirmed-gases) 1)
(check-equal "l86-log-econ-hash-mind-eg" (hash-ref econ-mind-ht 'enemy-estimated-gases) 5)

;; Idempotent re-extraction preserves weak side-table metadata
(define econ-rec2 (extract-bot-step-log-record econ-rec))
(check-equal "l86-log-econ-idempotent-line" (format-bot-step-log-line econ-rec2) econ-line)

;; -----------------------------------------------------------------------------
;; 4. Coexistence with `exp=<id>@spot<n>` + Nested `'mind` Hash + Coercion
;; -----------------------------------------------------------------------------
(define exp-and-econ-rec
  (extract-bot-step-log-record
   (hash 'mind (hash 'frame 8064 'race 'Zerg 'enemy-race 'Protoss
                     'experiment-id 'exp-macro-ring 'experiment-spot-idx 2
                     'enemy-confirmed-bases 3 'enemy-estimated-bases 5
                     'enemy-confirmed-gases 2 'enemy-estimated-gases 6)
         'goals (hash 'active-bo-goal-sym 'hatchery 'active-bo-goal-kind 'build)
         'tactics (hash 'combat-posture 'hold 'snowball-adv 0.0 'retreat-sector 0 'issued-orders 5))))

(define exp-econ-line (format-bot-step-log-line exp-and-econ-rec))
(check-true "l86-log-exp-and-econ-suffix"
            (string-suffix? exp-econ-line " exp=exp-macro-ring@spot2 eB=3/5 eG=2/6"))
(define parsed-exp (extract-experiment-log-tag exp-econ-line))
(check-true "l86-log-exp-regex-unaffected-by-eB-eG"
            (and (hash? parsed-exp)
                 (eq? (hash-ref parsed-exp 'experiment-id) 'exp-macro-ring)
                 (= (hash-ref parsed-exp 'experiment-spot-idx) 2)))

;; Partial keys + negative/float coercion safety
(define partial-rec
  (extract-bot-step-log-record
   (hash 'frame 4000 'race 'Terran 'enemy-race 'Zerg
         'enemy-confirmed-bases 3 'enemy-confirmed-gases -1)
   (hash)
   (hash)))
(define partial-line (format-bot-step-log-line partial-rec))
(check-true "l86-log-partial-and-clamp-safe"
            (string-suffix? partial-line " eB=3/3 eG=0/0"))

(printf "\n=============================================================================\n")
(printf "l86-logging-eb-eg-test: ~a PASSED, ~a FAILED\n" pass-count fail-count)
(printf "=============================================================================\n")
(when (> fail-count 0) (exit 1))
