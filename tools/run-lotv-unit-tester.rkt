#lang racket/base

;; =============================================================================
;; `tools/run-lotv-unit-tester.rkt`
;; Offline Pure-Racket CLI for Mothman's 8 Asymmetric LotV Unit-Tester Scenarios
;;
;; Supports:
;;   --all             Run all 8 asymmetric LotV scenarios (`default-ai` & `mothman-tactics`)
;;   --scenario <id>   Run one named scenario
;;   --json            Emit structured JSON report to stdout
;;   --verify          Verify all selected scenarios (`default-ai -> enemy`,
;;                     `mothman-tactics -> ally`) and exit 0 iff 100% pass
;;   --list            Print available scenario IDs
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/string
         json
         "../lib/sc2-unit-tester-lotv.rkt")

(define (sanitize-for-json v)
  (cond
    [(symbol? v) (symbol->string v)]
    [(list? v) (map sanitize-for-json v)]
    [(hash? v)
     (for/hasheq ([(k val) (in-hash v)])
       (define ks (if (symbol? k) k (string->symbol (~a k))))
       (values ks (sanitize-for-json val)))]
    [else v]))

(define (print-scenario-table results)
  (printf "==========================================================================================\n")
  (printf "MOTHMAN LOTV UNIT TESTER (default-ai vs mothman-tactics)\n")
  (printf "==========================================================================================\n")
  (printf "~a ~a ~a ~a ~a\n"
          (~a "SCENARIO" #:min-width 48)
          (~a "DEFAULT" #:min-width 9)
          (~a "MOTHMAN" #:min-width 9)
          (~a "ALIVE(D/M)" #:min-width 12)
          "STATUS")
  (printf "------------------------------------------------------------------------------------------\n")
  (for ([r (in-list results)])
    (define def (hash-ref r 'default_ai))
    (define moth (hash-ref r 'mothman_tactics))
    (define alive-str
      (format "~a/~a | ~a/~a"
              (hash-ref def 'ally_alive) (hash-ref def 'ally_start)
              (hash-ref moth 'ally_alive) (hash-ref moth 'ally_start)))
    (printf "~a ~a ~a ~a ~a\n"
            (~a (hash-ref r 'scenario) #:min-width 48)
            (~a (hash-ref r 'default_winner) #:min-width 9)
            (~a (hash-ref r 'mothman_winner) #:min-width 9)
            (~a alive-str #:min-width 12)
            (if (hash-ref r 'passed #f) "PASS" "FAIL")))
  (printf "==========================================================================================\n"))

(module+ main
  (define run-all? #f)
  (define one-scenario #f)
  (define emit-json? #f)
  (define verify? #f)
  (define list-only? #f)

  (command-line
   #:program "run-lotv-unit-tester.rkt"
   #:once-each
   [("--all") "Run all 8 LotV asymmetric combat scenarios"
              (set! run-all? #t)]
   [("--scenario") sid "Run a single scenario by ID"
                   (set! one-scenario sid)]
   [("--json") "Emit structured JSON summary to stdout"
               (set! emit-json? #t)]
   [("--verify") "Fail with non-zero exit code unless all executed scenarios pass"
                 (set! verify? #t)]
   [("--list") "List all supported scenario IDs"
               (set! list-only? #t)])

  (cond
    [list-only?
     (for ([s (in-list LOTV-UNIT-TESTER-SCENARIOS)])
       (printf "~a\t~a\n"
               (lotv-scenario-spec-id s)
               (lotv-scenario-spec-description s)))]
    [else
     (define summary
       (if (and one-scenario (not run-all?))
           (let ([res (run-lotv-unit-tester-scenario one-scenario)])
             (hasheq 'total 1
                     'passed (if (hash-ref res 'passed #f) 1 0)
                     'failed (if (hash-ref res 'passed #f) 0 1)
                     'all_passed (hash-ref res 'passed #f)
                     'results (list res)))
           (run-all-lotv-unit-tester-scenarios)))
     (cond
       [emit-json?
        (write-json (sanitize-for-json summary))
        (newline)]
       [else
        (print-scenario-table (hash-ref summary 'results))
        (printf "Total: ~a/~a passed (failed=~a)\n"
                (hash-ref summary 'passed)
                (hash-ref summary 'total)
                (hash-ref summary 'failed))])
     (when verify?
       (unless (hash-ref summary 'all_passed #f)
         (exit 1)))]))
