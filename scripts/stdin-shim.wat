;; The WASI shim: Wasmtime's WASI functions find the guest memory through
;; their caller's "memory" export, and the fd_read and fd_fdstat_get the
;; runtime puts in front of WASI's are host functions with no caller. This
;; module imports the guest memory, exports it under that name and forwards
;; to Wasmtime's own functions. The same bytes are embedded in
;; c_src/nif_engine.c (SHIM_WASM) for builds with a compiler;
;; scripts/precompile-shims.sh compiles this file for runtime-only builds.
(module
  (import "wasi" "fd_read" (func $r (param i32 i32 i32 i32) (result i32)))
  (import "wasi" "fd_fdstat_get" (func $s (param i32 i32) (result i32)))
  (import "guest" "memory" (memory 0))
  (export "memory" (memory 0))
  (func (export "fd_read") (param i32 i32 i32 i32) (result i32)
    local.get 0 local.get 1 local.get 2 local.get 3 call $r)
  (func (export "fd_fdstat_get") (param i32 i32) (result i32)
    local.get 0 local.get 1 call $s))
