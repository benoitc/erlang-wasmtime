;; The stdin stream shim: Wasmtime's WASI functions find the guest memory
;; through their caller's "memory" export, and the fd_read the runtime puts
;; in front of WASI's is a host function with no caller. This module imports
;; the guest memory, exports it under that name and forwards to Wasmtime's
;; fd_read. The same bytes are embedded in c_src/wasmtime_nif.c (SHIM_WASM)
;; for builds with a compiler; scripts/precompile-shims.sh compiles this
;; file for runtime-only builds.
(module
  (import "wasi" "fd_read" (func $r (param i32 i32 i32 i32) (result i32)))
  (import "guest" "memory" (memory 0))
  (export "memory" (memory 0))
  (func (export "fd_read") (param i32 i32 i32 i32) (result i32)
    local.get 0 local.get 1 local.get 2 local.get 3 call $r))
