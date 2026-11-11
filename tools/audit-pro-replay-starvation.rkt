#lang racket/base

(require "../lib/pro-replay-starvation-audit.rkt")

(module+ main
  (define rep (run-pro-replay-starvation-audit #:max-checkpoints 5575 #:stride 1))
  (display (format-pro-starvation-audit-report rep))
  (unless (and (= (pro-starvation-audit-report-expansion-starvation-failures rep) 0)
               (= (pro-starvation-audit-report-worker-stall-failures rep) 0)
               (= (pro-starvation-audit-report-supply-deadlock-failures rep) 0)
               (= (pro-starvation-audit-report-hoarding-stall-failures rep) 0))
    (for ([s (in-list (pro-starvation-audit-report-failure-samples rep))])
      (eprintf "  FAIL: ~a\n" s))
    (exit 1)))
