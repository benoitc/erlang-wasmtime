(module
  (import "erlang" "send" (func $send (param i32 i32)))
  (import "erlang" "recv" (func $recv (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; echo every message back until the input is closed; count them
  (func (export "echo") (result i32) (local $n i32) (local $count i32)
    (block (loop
      (local.set $n (call $recv (i32.const 0) (i32.const 1024)))
      (br_if 1 (i32.lt_s (local.get $n) (i32.const 0)))
      (call $send (i32.const 0) (local.get $n))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (br 0)))
    (local.get $count)))
