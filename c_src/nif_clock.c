/*
 * nif_clock.c: `clocks => monotonic`. WASI's clock_time_get and
 * clock_res_get are put in front of Wasmtime's own: the monotonic clock is
 * the host's, every other clock (wall time, process and thread CPU time)
 * answers ENOTSUP. Wasmtime's C API has no setting for this.
 */
#include "nif.h"

#if NIF_HAVE_WASI
/* WASI preview 1 clock ids and errno values. */
#define WASI_CLOCK_MONOTONIC 1
#define WASI_ERRNO_FAULT 21
#define WASI_ERRNO_NOTSUP 58

/* Writes `v` little-endian at `ptr` of the caller's memory; 0 when it does
 * not fit or the caller exports no memory. */
static int put_u64(wasmtime_caller_t *caller, uint32_t ptr, uint64_t v) {
  wasmtime_extern_t ext;
  if (!wasmtime_caller_export_get(caller, "memory", 6, &ext) || ext.kind != WASMTIME_EXTERN_MEMORY)
    return 0;
  wasmtime_context_t *ctx = wasmtime_caller_context(caller);
  uint8_t *base = wasmtime_memory_data(ctx, &ext.of.memory);
  size_t size = wasmtime_memory_data_size(ctx, &ext.of.memory);
  if ((uint64_t)ptr + 8 > size) return 0;
  for (int i = 0; i < 8; i++) base[ptr + i] = (uint8_t)(v >> (8 * i));
  return 1;
}

/* The host's monotonic clock, not one starting at instantiation: a
 * pre-initialized guest may hold readings taken before its image was
 * captured, and they must stay in the past (docs/preinit.md). */
static uint64_t read_clock(int res) {
  struct timespec ts;
  if (res)
    clock_getres(CLOCK_MONOTONIC, &ts);
  else
    clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

/* clock_time_get(id: i32, precision: i64, out: i32) -> errno */
static wasm_trap_t *time_get_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                                size_t nvals) {
  (void)envp;
  (void)nvals;
  int32_t id = vals[0].i32;
  uint32_t out = (uint32_t)vals[2].i32;
  vals[0].i32 = id != WASI_CLOCK_MONOTONIC            ? WASI_ERRNO_NOTSUP
                : put_u64(caller, out, read_clock(0)) ? 0
                                                      : WASI_ERRNO_FAULT;
  return NULL;
}

/* clock_res_get(id: i32, out: i32) -> errno */
static wasm_trap_t *res_get_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                               size_t nvals) {
  (void)envp;
  (void)nvals;
  int32_t id = vals[0].i32;
  uint32_t out = (uint32_t)vals[1].i32;
  vals[0].i32 = id != WASI_CLOCK_MONOTONIC            ? WASI_ERRNO_NOTSUP
                : put_u64(caller, out, read_clock(1)) ? 0
                                                      : WASI_ERRNO_FAULT;
  return NULL;
}

static wasm_functype_t *functype(int with_precision) {
  wasm_valtype_t *ps[3];
  size_t n = 0;
  ps[n++] = wasm_valtype_new(WASM_I32);
  if (with_precision) ps[n++] = wasm_valtype_new(WASM_I64);
  ps[n++] = wasm_valtype_new(WASM_I32);
  wasm_valtype_t *rs[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t pv, rv;
  wasm_valtype_vec_new(&pv, n, (wasm_valtype_t *const *)ps);
  wasm_valtype_vec_new(&rv, 1, (wasm_valtype_t *const *)rs);
  return wasm_functype_new(&pv, &rv);
}

static wasmtime_error_t *define(wasmtime_linker_t *linker, const char *name, int with_precision,
                                wasmtime_func_unchecked_callback_t cb) {
  wasm_functype_t *ft = functype(with_precision);
  wasmtime_error_t *e = wasmtime_linker_define_func_unchecked(
      linker, "wasi_snapshot_preview1", 22, name, strlen(name), ft, cb, NULL, NULL);
  wasm_functype_delete(ft);
  return e;
}
#endif

/* Called after the WASI definitions are in the linker. */
ERL_NIF_TERM restrict_clocks(wasmtime_linker_t *linker, ErlNifEnv *out) {
#if NIF_HAVE_WASI
  wasmtime_linker_allow_shadowing(linker, true);
  wasmtime_error_t *e = define(linker, "clock_time_get", 1, time_get_cb);
  if (!e) e = define(linker, "clock_res_get", 0, res_get_cb);
  wasmtime_linker_allow_shadowing(linker, false);
  return e ? error_to_term(out, e, "wasi") : 0;
#else
  (void)linker;
  return mk_error_s(out, "wasi", "unavailable", "this build of erlang_wasmtime has no WASI");
#endif
}
