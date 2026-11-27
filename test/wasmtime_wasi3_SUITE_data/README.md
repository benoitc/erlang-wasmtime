# WASI 0.3 test programs

The `p3_*.component.wasm` files are Wasmtime's own test programs
(`crates/test-programs` of
[bytecodealliance/wasmtime](https://github.com/bytecodealliance/wasmtime),
Apache-2.0 WITH LLVM-exception), built from the v48.0.1 tag by erlang_wasm's
`scripts/build-wasmtime-p2.sh` and copied from its fixtures. Each checks
itself: it exits 0 when every check passed.
