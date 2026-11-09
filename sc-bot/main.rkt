#lang racket/base

(require "../compiler/syntax.rkt")

(provide (all-from-out racket/base)
         (all-from-out "../compiler/syntax.rkt"))

(module reader syntax/module-reader
  sc-bot)
