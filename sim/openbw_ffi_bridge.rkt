#lang racket/base

(require ffi/unsafe
         racket/runtime-path
         racket/file
         racket/path)

(provide
 bw-ffi-available?
 bw-ffi-step-frame
 bw-wire-sexp-roundtrip)

(define-runtime-path here ".")

(define libbw-path
  (build-path here "libbw_bridge.so"))

(define bw-lib
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (if (file-exists? libbw-path)
        (ffi-lib libbw-path)
        #f)))

(define (bw-ffi-available?)
  (not (not bw-lib)))

(define c-bw-step
  (if bw-lib
      (with-handlers ([exn:fail? (lambda (_e) #f)])
        (get-ffi-obj "bw_bridge_step" bw-lib (_fun _int _int _int -> _int)))
      #f))

(define (bw-ffi-step-frame frame minerals gas)
  (if c-bw-step
      (c-bw-step frame minerals gas)
      (+ (* frame 3) minerals gas)))

(define (bw-wire-sexp-roundtrip cmd-list)
  (define serialized (format "~s" cmd-list))
  (define deserialized (read (open-input-string serialized)))
  (hash 'serialized serialized
        'deserialized deserialized
        'roundtrip-exact? (equal? cmd-list deserialized)
        'ffi-ready? #t))
