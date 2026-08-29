(module
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "hello\n")
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 8))
    (i32.store (i32.const 4) (i32.const 6))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20))))
  ;; copy stdin to stdout (up to 1000 bytes), return the byte count
  (func (export "cat") (result i32)
    (i32.store (i32.const 0) (i32.const 3000))
    (i32.store (i32.const 4) (i32.const 1000))
    (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 24)))
    (i32.store (i32.const 4) (i32.load (i32.const 24)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20)))
    (i32.load (i32.const 24))))
