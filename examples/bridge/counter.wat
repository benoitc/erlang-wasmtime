;; A guest that talks to the Erlang VM through four imports.
;;
;; Strings cross the boundary as (ptr, len) pairs into linear memory; the
;; host reads and writes them with wasmtime:read_memory/3 and write_memory/3.
(module
  (import "erlang" "log"    (func $log    (param i32 i32)))
  (import "erlang" "kv_get" (func $kv_get (param i32 i32) (result i32)))
  (import "erlang" "kv_put" (func $kv_put (param i32 i32 i32)))
  (import "erlang" "notify" (func $notify (param i32 i32 i32)))

  (memory (export "memory") 1)
  (data (i32.const 0) "hits")
  (data (i32.const 16) "counter bumped")

  ;; bump(by): read "hits" from Erlang, add `by`, store it back, tell
  ;; subscribers, and return the new value.
  (func (export "bump") (param $by i32) (result i32) (local $n i32)
    (local.set $n (i32.add (call $kv_get (i32.const 0) (i32.const 4)) (local.get $by)))
    (call $kv_put (i32.const 0) (i32.const 4) (local.get $n))
    (call $log (i32.const 16) (i32.const 14))
    (call $notify (i32.const 0) (i32.const 4) (local.get $n))
    (local.get $n))

  ;; greet(ptr, len): upper-case a string the host wrote into memory, in place.
  (func (export "upcase") (param $ptr i32) (param $len i32) (local $i i32) (local $c i32)
    (block (loop
      (br_if 1 (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $c (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))
        (then (i32.store8 (i32.add (local.get $ptr) (local.get $i)) (i32.sub (local.get $c) (i32.const 32)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br 0)))))
