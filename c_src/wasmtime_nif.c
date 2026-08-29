/*
 * wasmtime_nif.c: Wasmtime bindings for Erlang.
 *
 * Shape of the runtime, borrowed from erlang-python:
 *
 *   - One OS thread per instance owns the Wasmtime store. Wasmtime stores are
 *     single-threaded, so a thread that never shares its store needs no locks
 *     around execution.
 *   - Erlang never blocks inside a NIF while a guest runs. `call` enqueues a
 *     request and returns; the worker thread replies with enif_send:
 *         {wasmtime_result, Ref, Id, {ok, Results} | {error, Map}}
 *   - A host function (an import provided by an Erlang fun) sends
 *         {wasmtime_host_call, Ref, HostId, {Module, Name}, Args}
 *     to the calling process and waits, bounded, for host_reply/3.
 *   - Interruption uses Wasmtime epochs. One ticker thread bumps the engine
 *     epoch every 10 ms; each store's deadline callback checks the instance's
 *     interrupt flag and either extends the deadline or fails the call.
 *
 * Ownership. Two resource types:
 *   - handle_t is what Erlang holds. Its destructor only tells the instance
 *     to stop; it never blocks.
 *   - instance_t is internal. It is kept alive by the handle and by its own
 *     worker thread (one reference each). The thread is detached and drops
 *     its reference as its last act, so the instance destructor never runs
 *     while the thread can still touch the instance, and never joins.
 *   Messages carry an Erlang reference (`Ref`, created by the Erlang side),
 *   not a resource term, so a worker thread never resurrects a resource.
 *
 * Sections: atoms and errors, values, instance state, host calls, worker
 * thread, resources, NIF entry points, load/unload.
 */
/* clock_gettime, nanosleep and pthread_cond_timedwait under -std=c11 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <erl_nif.h>
#include <wasi.h>
#include <wasm.h>
#include <wasmtime.h>

/* What the linked library can do. build-nif.sh probes the archive and passes
 * these; a plain `cc` against a full tree gets them from conf.h. The NIF
 * table is the same in every build; absent features answer
 * {error, #{kind => unavailable}}. */
#ifndef NIF_HAVE_COMPILER
#if defined(WASMTIME_FEATURE_CRANELIFT) || defined(WASMTIME_FEATURE_WINCH)
#define NIF_HAVE_COMPILER 1
#else
#define NIF_HAVE_COMPILER 0
#endif
#endif
#ifndef NIF_HAVE_WAT
#ifdef WASMTIME_FEATURE_WAT
#define NIF_HAVE_WAT 1
#else
#define NIF_HAVE_WAT 0
#endif
#endif
#ifndef NIF_HAVE_WASI
#ifdef WASMTIME_FEATURE_WASI
#define NIF_HAVE_WASI 1
#else
#define NIF_HAVE_WASI 0
#endif
#endif
#if NIF_HAVE_COMPILER && !defined(WASMTIME_FEATURE_CRANELIFT) && !defined(WASMTIME_FEATURE_WINCH)
#error "the library has a compiler but the headers do not declare one: include/ and lib/ differ"
#endif
#if NIF_HAVE_WAT && !defined(WASMTIME_FEATURE_WAT)
#error "the library reads WAT but the headers do not declare it: include/ and lib/ differ"
#endif
#if NIF_HAVE_WASI && !defined(WASMTIME_FEATURE_WASI)
#error "the library has WASI but the headers do not declare it: include/ and lib/ differ"
#endif

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define EPOCH_TICK_NS (10 * 1000 * 1000) /* 10 ms */
#define MAX_VALS 32

/* ---------------------------------------------------------------- atoms -- */

static ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false, atom_compiler, atom_wat, atom_wasi,
    atom_none, atom_capture, atom_binary, atom_trace, atom_func_index, atom_func_offset,
    atom_func_name, atom_module_name, atom_immutable, atom_undefined, atom_inherit, atom_file,
    atom_read, atom_write, atom_nan, atom_infinity, atom_neg_infinity, atom_class, atom_kind,
    atom_message, atom_status, atom_not_running, atom_func, atom_global, atom_table, atom_memory,
    atom_tag, atom_wasmtime_result, atom_wasmtime_host_call, atom_no_pending_host_call,
    atom_enqueued;

static ERL_NIF_TERM mk_atom(ErlNifEnv *env, const char *s) {
  ERL_NIF_TERM a;
  if (!enif_make_existing_atom(env, s, &a, ERL_NIF_LATIN1)) a = enif_make_atom(env, s);
  return a;
}

static ERL_NIF_TERM mk_binary(ErlNifEnv *env, const void *data, size_t len) {
  ERL_NIF_TERM t;
  unsigned char *p = enif_make_new_binary(env, len, &t);
  if (len) memcpy(p, data, len);
  return t;
}

/* {error, #{class => Class, kind => Kind, message => Msg[, trace => Frames]}} */
static ERL_NIF_TERM mk_error_trace(ErlNifEnv *env, const char *cls, const char *kind,
                                   const char *msg, size_t len, ERL_NIF_TERM trace) {
  ERL_NIF_TERM keys[4] = {atom_class, atom_kind, atom_message, atom_trace};
  ERL_NIF_TERM vals[4] = {mk_atom(env, cls), mk_atom(env, kind), mk_binary(env, msg, len), trace};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, trace ? 4 : 3, &map);
  return enif_make_tuple2(env, atom_error, map);
}

static ERL_NIF_TERM mk_error(ErlNifEnv *env, const char *cls, const char *kind, const char *msg,
                             size_t len) {
  return mk_error_trace(env, cls, kind, msg, len, 0);
}

/* The wasm frames of a trap, innermost first, as
 * [#{func_index, func_offset, func_name, module_name}]; 0 when empty.
 * Consumes `frames`. */
static ERL_NIF_TERM frames_term(ErlNifEnv *env, wasm_frame_vec_t *frames) {
  if (frames->size == 0) {
    wasm_frame_vec_delete(frames);
    return 0;
  }
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = frames->size; i > 0; i--) {
    const wasm_frame_t *f = frames->data[i - 1];
    const wasm_name_t *fn = wasmtime_frame_func_name(f);
    const wasm_name_t *mn = wasmtime_frame_module_name(f);
    ERL_NIF_TERM keys[4] = {atom_func_index, atom_func_offset, atom_func_name, atom_module_name};
    ERL_NIF_TERM vals[4] = {enif_make_uint(env, wasm_frame_func_index(f)),
                            enif_make_uint64(env, wasm_frame_func_offset(f)),
                            fn ? mk_binary(env, fn->data, fn->size) : atom_undefined,
                            mn ? mk_binary(env, mn->data, mn->size) : atom_undefined};
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, 4, &map);
    list = enif_make_list_cell(env, map, list);
  }
  wasm_frame_vec_delete(frames);
  return list;
}

static ERL_NIF_TERM mk_error_s(ErlNifEnv *env, const char *cls, const char *kind, const char *msg) {
  return mk_error(env, cls, kind, msg, strlen(msg));
}

static const char *trap_kind(wasmtime_trap_code_t code) {
  switch (code) {
  case WASMTIME_TRAP_CODE_STACK_OVERFLOW: return "stack_overflow";
  case WASMTIME_TRAP_CODE_MEMORY_OUT_OF_BOUNDS: return "memory_out_of_bounds";
  case WASMTIME_TRAP_CODE_HEAP_MISALIGNED: return "heap_misaligned";
  case WASMTIME_TRAP_CODE_TABLE_OUT_OF_BOUNDS: return "table_out_of_bounds";
  case WASMTIME_TRAP_CODE_INDIRECT_CALL_TO_NULL: return "indirect_call_to_null";
  case WASMTIME_TRAP_CODE_BAD_SIGNATURE: return "bad_signature";
  case WASMTIME_TRAP_CODE_INTEGER_OVERFLOW: return "integer_overflow";
  case WASMTIME_TRAP_CODE_INTEGER_DIVISION_BY_ZERO: return "integer_division_by_zero";
  case WASMTIME_TRAP_CODE_BAD_CONVERSION_TO_INTEGER: return "bad_conversion_to_integer";
  case WASMTIME_TRAP_CODE_UNREACHABLE_CODE_REACHED: return "unreachable";
  case WASMTIME_TRAP_CODE_INTERRUPT: return "interrupt";
  case WASMTIME_TRAP_CODE_OUT_OF_FUEL: return "out_of_fuel";
  default: return "trap";
  }
}

/* Consumes `trap`. */
static ERL_NIF_TERM trap_to_term(ErlNifEnv *env, wasm_trap_t *trap) {
  wasm_message_t msg;
  wasm_trap_message(trap, &msg);
  wasmtime_trap_code_t code;
  ERL_NIF_TERM t;
  /* Wasmtime NUL-terminates trap messages; drop the terminator. */
  size_t len = msg.size && msg.data[msg.size - 1] == 0 ? msg.size - 1 : msg.size;
  wasm_frame_vec_t frames;
  wasm_trap_trace(trap, &frames);
  ERL_NIF_TERM trace = frames_term(env, &frames);
  if (wasmtime_trap_code(trap, &code))
    t = mk_error_trace(env, "trap", trap_kind(code), msg.data, len, trace);
  else
    t = mk_error_trace(env, "trap", "trap", msg.data, len, trace);
  wasm_byte_vec_delete(&msg);
  wasm_trap_delete(trap);
  return t;
}

/* Consumes `err`. */
static ERL_NIF_TERM error_to_term(ErlNifEnv *env, wasmtime_error_t *err, const char *cls) {
  int status;
  ERL_NIF_TERM t;
  if (wasmtime_error_exit_status(err, &status)) {
    if (status == 0) {
      t = enif_make_tuple2(env, atom_ok, enif_make_list(env, 0));
    } else {
      ERL_NIF_TERM keys[4] = {atom_class, atom_kind, atom_message, atom_status};
      char buf[64];
      int n = snprintf(buf, sizeof buf, "exited with status %d", status);
      ERL_NIF_TERM vals[4] = {mk_atom(env, "exit"), mk_atom(env, "exit"),
                              mk_binary(env, buf, (size_t)n), enif_make_int(env, status)};
      ERL_NIF_TERM map;
      enif_make_map_from_arrays(env, keys, vals, 4, &map);
      t = enif_make_tuple2(env, atom_error, map);
    }
  } else {
    wasm_name_t msg;
    wasmtime_error_message(err, &msg);
    wasm_frame_vec_t frames;
    wasmtime_error_wasm_trace(err, &frames);
    ERL_NIF_TERM trace = frames_term(env, &frames);
    /* an error carrying wasm frames is a trap that Wasmtime wrapped */
    t = mk_error_trace(env, trace ? "trap" : cls, trace ? "trap" : cls, msg.data, msg.size, trace);
    wasm_byte_vec_delete(&msg);
  }
  wasmtime_error_delete(err);
  return t;
}

/* --------------------------------------------------------------- values -- */

/* wasm_valtype_kind aborts the process on v128 and on non-nullable references
 * (a TODO in Wasmtime's C API); wasmtime_valtype_new classifies every type. */
static uint8_t kind_of(const wasm_valtype_t *vt) {
  wasmtime_valtype_t t;
  wasmtime_valtype_new(vt, &t);
  uint8_t k = t.kind;
  wasmtime_valtype_delete(&t);
  return k;
}

static int ref_kind(uint8_t k) {
  return k == WASMTIME_VALTYPE_KIND_REF;
}

/* Values cross the boundary as wasmtime_val_raw_t: the typed wasmtime_val_t
 * path of the C API aborts the process on v128, the raw one supports it. The
 * kind always comes from the function type, never from the value. Reference
 * kinds never reach these two functions: they are refused when a function
 * type is inspected. */
static ERL_NIF_TERM raw_to_term(ErlNifEnv *env, uint8_t kind, const wasmtime_val_raw_t *v) {
  double d;
  switch (kind) {
  case WASMTIME_VALTYPE_KIND_I32: return enif_make_int(env, v->i32);
  case WASMTIME_VALTYPE_KIND_I64: return enif_make_int64(env, v->i64);
  case WASMTIME_VALTYPE_KIND_F32: d = v->f32; goto flt;
  case WASMTIME_VALTYPE_KIND_F64: d = v->f64; goto flt;
  default: return mk_binary(env, v->v128, 16);
  }
flt:
  if (isnan(d)) return atom_nan;
  if (isinf(d)) return d > 0 ? atom_infinity : atom_neg_infinity;
  return enif_make_double(env, d);
}

static int term_to_double(ErlNifEnv *env, ERL_NIF_TERM t, double *d) {
  ErlNifSInt64 i;
  if (enif_get_double(env, t, d)) return 1;
  if (enif_get_int64(env, t, &i)) {
    *d = (double)i;
    return 1;
  }
  if (enif_is_identical(t, atom_nan)) {
    *d = NAN;
    return 1;
  }
  if (enif_is_identical(t, atom_infinity)) {
    *d = INFINITY;
    return 1;
  }
  if (enif_is_identical(t, atom_neg_infinity)) {
    *d = -INFINITY;
    return 1;
  }
  return 0;
}

static int term_to_raw(ErlNifEnv *env, ERL_NIF_TERM t, uint8_t kind, wasmtime_val_raw_t *v) {
  ErlNifSInt64 i;
  ErlNifUInt64 u;
  double d;
  ErlNifBinary bin;
  memset(v, 0, sizeof *v);
  switch (kind) {
  case WASMTIME_VALTYPE_KIND_I32:
    if (!enif_get_int64(env, t, &i) || i < INT32_MIN || i > UINT32_MAX) return 0;
    v->i32 = (int32_t)(uint32_t)i;
    return 1;
  case WASMTIME_VALTYPE_KIND_I64:
    if (enif_get_int64(env, t, &i)) {
      v->i64 = i;
      return 1;
    }
    if (enif_get_uint64(env, t, &u)) {
      v->i64 = (int64_t)u;
      return 1;
    }
    return 0;
  case WASMTIME_VALTYPE_KIND_F32:
    if (!term_to_double(env, t, &d)) return 0;
    v->f32 = (float)d;
    return 1;
  case WASMTIME_VALTYPE_KIND_F64:
    if (!term_to_double(env, t, &d)) return 0;
    v->f64 = d;
    return 1;
  default:
    if (!enif_inspect_binary(env, t, &bin) || bin.size != 16) return 0;
    memcpy(v->v128, bin.data, 16);
    return 1;
  }
}

/* -------------------------------------------------------- instance state -- */

typedef struct {
  wasmtime_module_t *mod;
  int fuel; /* engine index: 0 plain, 1 with fuel metering */
} module_res_t;

enum req_kind { REQ_INSTANTIATE, REQ_CALL };

typedef struct req {
  enum req_kind kind;
  ErlNifUInt64 id;
  ErlNifPid caller;
  ErlNifEnv *env; /* owns name, args, opts */
  ERL_NIF_TERM name, args, opts;
  ErlNifMonitor mon;
  int monitored;
  int cancelled; /* caller died or gave up: run nothing, send nothing */
  struct req *next;
} req_t;

typedef struct {
  char *module, *name;
  wasm_functype_t *type;
} hostfn_t;

struct instance;

typedef struct {
  struct instance *inst;
  size_t idx;
} hostfn_env_t;

enum state { ST_IDLE, ST_RUNNING, ST_IN_HOST };

typedef struct instance {
  pthread_mutex_t mu;
  pthread_cond_t cv;

  ErlNifEnv *ref_env; /* owns ref, the Erlang reference carried by messages */
  ERL_NIF_TERM ref;

  req_t *head, *tail;
  req_t *current;
  enum state state;
  int stopping;

  /* host call in flight (state == ST_IN_HOST) */
  ErlNifUInt64 host_id, host_seq;
  int has_reply, abort;
  ErlNifPid host_pid; /* serves host calls for REQ_CALL when has_host_pid */
  int has_host_pid;

  /* WASI stdout/stderr captured in memory (stdio option `capture`) */
  struct {
    unsigned char *data;
    size_t len, cap;
  } capture[2];
  size_t output_limit; /* bytes kept per stream; the rest is counted */
  size_t dropped[2];
  ErlNifPid host_target; /* who the in-flight host call was sent to */
  ErlNifEnv *reply_env;
  ERL_NIF_TERM reply;
  unsigned host_timeout_ms;

  /* set under mu by interrupt/cancel/down, read by the epoch callback */
  volatile int interrupt;
  /* worker-thread only: how the running request ended */
  int interrupted_fired; /* the interrupt flag ended it */
  int host_failed;       /* a host function failed it */
  char *host_msg;        /* the host function's reason */

  wasmtime_store_t *store;
  wasmtime_context_t *ctx;
  wasmtime_linker_t *linker;
  wasmtime_instance_t instance;
  int instantiated;
  module_res_t *mod;
  int has_memory;
  wasmtime_memory_t memory;
  hostfn_t *hostfns;
  size_t nhostfns;
} instance_t;

typedef struct {
  instance_t *inst;
} handle_t;

static ErlNifResourceType *module_type, *instance_type, *handle_type;
/* Two engines: fuel metering changes code generation and is part of a
 * precompiled module's compatibility check, so modules pick one at compile
 * time. The ticker bumps both epochs. */
static wasm_engine_t *engines[2];
static pthread_t ticker;
static volatile int ticker_stop;

static void req_free(req_t *r) {
  if (r->env) enif_free_env(r->env);
  enif_free(r);
}

/* Build and send {wasmtime_result, Ref, Id, Result}. `env` owns `result`. */
static void send_result(instance_t *inst, req_t *req, ErlNifEnv *env, ERL_NIF_TERM result) {
  ERL_NIF_TERM msg = enif_make_tuple4(env, atom_wasmtime_result, enif_make_copy(env, inst->ref),
                                      enif_make_uint64(env, req->id), result);
  enif_send(NULL, &req->caller, env, msg);
}

/* ------------------------------------------------------------ host calls -- */

static void add_ms(struct timespec *ts, unsigned ms) {
  clock_gettime(CLOCK_REALTIME, ts);
  ts->tv_sec += ms / 1000;
  ts->tv_nsec += (long)(ms % 1000) * 1000000L;
  if (ts->tv_nsec >= 1000000000L) {
    ts->tv_sec++;
    ts->tv_nsec -= 1000000000L;
  }
}

static void set_host_failure(instance_t *inst, const char *msg, size_t len) {
  enif_free(inst->host_msg);
  inst->host_msg = enif_alloc(len + 1);
  memcpy(inst->host_msg, msg, len);
  inst->host_msg[len] = 0;
  inst->host_failed = 1;
}

/* How the request that just ran ended, in priority order. Consumes `e` and
 * `trap`. A trap raised by a host callback comes back from Wasmtime as an
 * error wrapping a backtrace; the instance flags tell the real cause. */
static ERL_NIF_TERM outcome(instance_t *inst, ErlNifEnv *out, wasmtime_error_t *e,
                            wasm_trap_t *trap, const char *cls) {
  if (inst->interrupted_fired || inst->host_failed) {
    if (e) wasmtime_error_delete(e);
    if (trap) wasm_trap_delete(trap);
    if (inst->interrupted_fired) return mk_error_s(out, "trap", "interrupt", "interrupted");
    return mk_error_s(out, "host", "host_error", inst->host_msg ? inst->host_msg : "host error");
  }
  if (e) return error_to_term(out, e, cls);
  if (trap) return trap_to_term(out, trap);
  return atom_ok;
}

/* Runs on the instance thread, inside wasmtime_func_call. The mutex is not
 * held while the guest runs, so take it here. */
static wasm_trap_t *host_callback(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                                  size_t nvals) {
  hostfn_env_t *he = envp;
  instance_t *inst = he->inst;
  hostfn_t *fn = &inst->hostfns[he->idx];
  const wasm_valtype_vec_t *pt = wasm_functype_params(fn->type);
  const wasm_valtype_vec_t *rt = wasm_functype_results(fn->type);
  size_t nargs = pt->size, nresults = rt->size;
  const char *fail = NULL;
  int interrupted = 0;

  /* Read every argument before any result is written: they share `vals`. */
  ErlNifEnv *menv = enif_alloc_env();
  ERL_NIF_TERM list = enif_make_list(menv, 0);
  for (size_t i = nargs; i > 0; i--)
    list =
        enif_make_list_cell(menv, raw_to_term(menv, kind_of(pt->data[i - 1]), &vals[i - 1]), list);

  pthread_mutex_lock(&inst->mu);
  if (inst->abort || inst->current->cancelled) {
    /* interrupted or cancelled before we got here: do not even ask */
    pthread_mutex_unlock(&inst->mu);
    enif_free_env(menv);
    inst->interrupted_fired = 1;
    return wasmtime_trap_new("interrupted", 11);
  }
  inst->state = ST_IN_HOST;
  inst->host_id = ++inst->host_seq;
  inst->has_reply = 0;
  /* A dedicated handler serves calls; the start section at instantiate
   * time goes to the caller, which is the only process that has the
   * instance at that point. */
  inst->host_target = inst->has_host_pid && inst->current->kind == REQ_CALL ? inst->host_pid
                                                                            : inst->current->caller;
  enif_clear_env(inst->reply_env);
  ERL_NIF_TERM msg =
      enif_make_tuple5(menv, atom_wasmtime_host_call, enif_make_copy(menv, inst->ref),
                       enif_make_uint64(menv, inst->host_id),
                       enif_make_tuple2(menv, mk_binary(menv, fn->module, strlen(fn->module)),
                                        mk_binary(menv, fn->name, strlen(fn->name))),
                       list);
  int sent = enif_send(NULL, &inst->host_target, menv, msg);
  enif_free_env(menv);
  if (!sent) {
    fail = "host process is gone";
  } else {
    struct timespec deadline;
    add_ms(&deadline, inst->host_timeout_ms);
    while (!inst->has_reply && !inst->abort) {
      if (pthread_cond_timedwait(&inst->cv, &inst->mu, &deadline) == ETIMEDOUT) {
        if (!inst->has_reply && !inst->abort) fail = "host function timed out";
        break;
      }
    }
    if (!fail && inst->abort) interrupted = 1;
  }
  inst->state = ST_RUNNING;

  if (!fail && !interrupted) {
    /* {ok, Results} | {error, Message :: binary()} */
    ErlNifEnv *renv = inst->reply_env;
    const ERL_NIF_TERM *tup;
    int arity;
    ErlNifBinary bin;
    if (!enif_get_tuple(renv, inst->reply, &arity, &tup) || arity != 2) {
      fail = "host function returned a malformed reply";
    } else if (enif_is_identical(tup[0], atom_error)) {
      if (!enif_inspect_iolist_as_binary(renv, tup[1], &bin)) {
        bin.data = (unsigned char *)"host error";
        bin.size = 10;
      }
      set_host_failure(inst, (const char *)bin.data, bin.size);
    } else {
      ERL_NIF_TERM l = tup[1], h;
      size_t i = 0;
      while (i < nresults && enif_get_list_cell(renv, l, &h, &l)) {
        if (!term_to_raw(renv, h, kind_of(rt->data[i]), &vals[i])) {
          fail = "host function returned a value of the wrong type";
          break;
        }
        i++;
      }
      if (!fail && (i != nresults || !enif_is_empty_list(renv, l)))
        fail = "host function returned the wrong number of values";
    }
  }
  pthread_mutex_unlock(&inst->mu);

  if (interrupted) {
    inst->interrupted_fired = 1;
    return wasmtime_trap_new("interrupted", 11);
  }
  if (fail) set_host_failure(inst, fail, strlen(fail));
  if (inst->host_failed) return wasmtime_trap_new(inst->host_msg, strlen(inst->host_msg));
  return NULL;
}

/* --------------------------------------------------------- worker thread -- */

static wasmtime_error_t *epoch_callback(wasmtime_context_t *ctx, void *data, uint64_t *delta,
                                        wasmtime_update_deadline_kind_t *kind) {
  instance_t *inst = data;
  if (__atomic_load_n(&inst->interrupt, __ATOMIC_ACQUIRE)) {
    inst->interrupted_fired = 1;
    return wasmtime_error_new("interrupted");
  }
  *delta = 1;
  *kind = WASMTIME_UPDATE_DEADLINE_CONTINUE;
  return NULL;
}

static char *bin_to_cstr(ErlNifEnv *env, ERL_NIF_TERM t) {
  ErlNifBinary b;
  if (!enif_inspect_iolist_as_binary(env, t, &b)) return NULL;
  char *s = enif_alloc(b.size + 1);
  memcpy(s, b.data, b.size);
  s[b.size] = 0;
  return s;
}

#if NIF_HAVE_WASI
typedef struct {
  instance_t *inst;
  int which; /* 0 stdout, 1 stderr */
} capture_env_t;

/* Runs on the instance thread inside a WASI write. Appends under the mutex
 * so read_output/1 can copy the buffer from a scheduler thread meanwhile. */
static ptrdiff_t capture_write(void *envp, const unsigned char *data, size_t len) {
  capture_env_t *ce = envp;
  instance_t *inst = ce->inst;
  pthread_mutex_lock(&inst->mu);
  size_t room = inst->output_limit > inst->capture[ce->which].len
                    ? inst->output_limit - inst->capture[ce->which].len
                    : 0;
  size_t keep = len < room ? len : room;
  if (keep) {
    size_t need = inst->capture[ce->which].len + keep;
    if (need > inst->capture[ce->which].cap) {
      size_t cap = inst->capture[ce->which].cap ? inst->capture[ce->which].cap * 2 : 4096;
      while (cap < need) cap *= 2;
      inst->capture[ce->which].data = enif_realloc(inst->capture[ce->which].data, cap);
      inst->capture[ce->which].cap = cap;
    }
    memcpy(inst->capture[ce->which].data + inst->capture[ce->which].len, data, keep);
    inst->capture[ce->which].len += keep;
  }
  inst->dropped[ce->which] += len - keep;
  pthread_mutex_unlock(&inst->mu);
  return (ptrdiff_t)len; /* the guest sees a complete write either way */
}
#endif

/* Wasi :: none | {Args, Env, Dirs, Stdin, Stdout, Stderr, OutputLimit}
 * Args  :: inherit | [binary()]     Env :: inherit | [{binary(), binary()}]
 * Stdin :: none | inherit | {file, Path} | {binary, Bytes}
 * Stdout, Stderr :: none | inherit | {file, Path} | capture
 * Dirs  :: [{GuestPath, HostPath, read | write}] */
static ERL_NIF_TERM configure_wasi(instance_t *inst, ErlNifEnv *env, ErlNifEnv *out,
                                   ERL_NIF_TERM wasi) {
  const ERL_NIF_TERM *t;
  int arity;
  if (enif_is_identical(wasi, atom_none)) return 0;
  if (!enif_get_tuple(env, wasi, &arity, &t) || arity != 7)
    return mk_error_s(out, "wasi", "config", "wasi option is malformed");
#if !NIF_HAVE_WASI
  return mk_error_s(out, "wasi", "unavailable", "this build of erlang_wasmtime has no WASI");
#else

  wasi_config_t *cfg = wasi_config_new();
  const char *err = NULL;
  unsigned n;
  ERL_NIF_TERM l, h;
  const ERL_NIF_TERM *tt;
  int ar;

  ErlNifUInt64 limit;
  if (!enif_get_uint64(env, t[6], &limit)) {
    err = "wasi output_limit must be an integer";
    goto done;
  }
  inst->output_limit = limit;
  /* argv */
  if (enif_is_identical(t[0], atom_inherit)) {
    wasi_config_inherit_argv(cfg);
  } else if (!enif_get_list_length(env, t[0], &n)) {
    err = "wasi args must be a list or inherit";
    goto done;
  } else {
    const char **argv = enif_alloc(sizeof(char *) * (n + 1));
    size_t i = 0;
    for (l = t[0]; enif_get_list_cell(env, l, &h, &l); i++) argv[i] = bin_to_cstr(env, h);
    int ok = 1;
    for (size_t j = 0; j < n; j++) ok = ok && argv[j];
    if (ok) wasi_config_set_argv(cfg, n, argv);
    for (size_t j = 0; j < n; j++) enif_free((void *)argv[j]);
    enif_free(argv);
    if (!ok) {
      err = "wasi args must be binaries";
      goto done;
    }
  }
  /* env */
  if (enif_is_identical(t[1], atom_inherit)) {
    wasi_config_inherit_env(cfg);
  } else if (!enif_get_list_length(env, t[1], &n)) {
    err = "wasi env must be a list or inherit";
    goto done;
  } else {
    const char **names = enif_alloc(sizeof(char *) * (n + 1));
    const char **values = enif_alloc(sizeof(char *) * (n + 1));
    size_t i = 0;
    int ok = 1;
    for (l = t[1]; enif_get_list_cell(env, l, &h, &l); i++) {
      names[i] = values[i] = NULL;
      if (enif_get_tuple(env, h, &ar, &tt) && ar == 2) {
        names[i] = bin_to_cstr(env, tt[0]);
        values[i] = bin_to_cstr(env, tt[1]);
      }
      ok = ok && names[i] && values[i];
    }
    if (ok) wasi_config_set_env(cfg, n, names, values);
    for (size_t j = 0; j < n; j++) {
      enif_free((void *)names[j]);
      enif_free((void *)values[j]);
    }
    enif_free(names);
    enif_free(values);
    if (!ok) {
      err = "wasi env must be a list of {Name, Value} binaries";
      goto done;
    }
  }
  /* dirs */
  for (l = t[2]; enif_get_list_cell(env, l, &h, &l);) {
    if (!enif_get_tuple(env, h, &ar, &tt) || ar != 3) {
      err = "wasi dirs entries must be {Guest, Host, read | write}";
      goto done;
    }
    char *guest = bin_to_cstr(env, tt[0]), *host = bin_to_cstr(env, tt[1]);
    int mutable = enif_is_identical(tt[2], atom_write);
    int ok = guest && host && (mutable || enif_is_identical(tt[2], atom_read)) &&
             wasi_config_preopen_dir(cfg, host, guest, mutable);
    enif_free(guest);
    enif_free(host);
    if (!ok) {
      err = "wasi dir could not be preopened";
      goto done;
    }
  }
  /* stdio */
  for (int fd = 0; fd < 3; fd++) {
    ERL_NIF_TERM s = t[3 + fd];
    if (enif_is_identical(s, atom_none)) continue;
    if (enif_is_identical(s, atom_inherit)) {
      if (fd == 0)
        wasi_config_inherit_stdin(cfg);
      else if (fd == 1)
        wasi_config_inherit_stdout(cfg);
      else
        wasi_config_inherit_stderr(cfg);
      continue;
    }
    if (fd > 0 && enif_is_identical(s, atom_capture)) {
      capture_env_t *ce = enif_alloc(sizeof *ce);
      ce->inst = inst;
      ce->which = fd - 1;
      if (fd == 1)
        wasi_config_set_stdout_custom(cfg, capture_write, ce, enif_free);
      else
        wasi_config_set_stderr_custom(cfg, capture_write, ce, enif_free);
      continue;
    }
    ErlNifBinary bytes;
    if (fd == 0 && enif_get_tuple(env, s, &ar, &tt) && ar == 2 &&
        enif_is_identical(tt[0], atom_binary) &&
        enif_inspect_iolist_as_binary(env, tt[1], &bytes)) {
      wasm_byte_vec_t vec;
      wasm_byte_vec_new(&vec, bytes.size, (const wasm_byte_t *)bytes.data);
      wasi_config_set_stdin_bytes(cfg, &vec); /* consumes vec */
      continue;
    }
    if (enif_get_tuple(env, s, &ar, &tt) && ar == 2 && enif_is_identical(tt[0], atom_file)) {
      char *path = bin_to_cstr(env, tt[1]);
      int ok = path && (fd == 0   ? wasi_config_set_stdin_file(cfg, path)
                        : fd == 1 ? wasi_config_set_stdout_file(cfg, path)
                                  : wasi_config_set_stderr_file(cfg, path));
      enif_free(path);
      if (!ok) {
        err = "wasi stdio file could not be opened";
        goto done;
      }
      continue;
    }
    err = fd == 0 ? "wasi stdin must be none, inherit, {file, Path} or {binary, Bytes}"
                  : "wasi stdout and stderr must be none, inherit, {file, Path} or capture";
    goto done;
  }

done:
  if (err) {
    wasi_config_delete(cfg);
    return mk_error_s(out, "wasi", "config", err);
  }
  wasmtime_error_t *werr = wasmtime_context_set_wasi(inst->ctx, cfg); /* consumes cfg */
  if (werr) {
    wasmtime_error_delete(werr);
    return mk_error_s(out, "wasi", "config", "wasi could not be configured");
  }
  werr = wasmtime_linker_define_wasi(inst->linker);
  if (werr) {
    wasmtime_error_delete(werr);
    return mk_error_s(out, "wasi", "config", "wasi could not be linked");
  }
  return 0;
#endif
}

/* Opts :: {Imports :: [{Module, Name}], Wasi, Limits, HostTimeoutMs, HostPid}
 * Limits :: {MemoryBytes, Tables, TableElements, Instances}, -1 = unlimited
 * HostPid :: pid() | undefined */
static ERL_NIF_TERM do_instantiate(instance_t *inst, req_t *req, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  const ERL_NIF_TERM *o, *lim;
  int arity;
  if (!enif_get_tuple(env, req->opts, &arity, &o) || arity != 5 ||
      !enif_get_tuple(env, o[2], &arity, &lim) || arity != 4)
    return mk_error_s(out, "link", "badarg", "malformed options");
  inst->has_host_pid = enif_get_local_pid(env, o[4], &inst->host_pid);

  ErlNifSInt64 mem, tables, elems, instances;
  unsigned host_timeout;
  if (!enif_get_int64(env, lim[0], &mem) || !enif_get_int64(env, lim[1], &tables) ||
      !enif_get_int64(env, lim[2], &elems) || !enif_get_int64(env, lim[3], &instances) ||
      !enif_get_uint(env, o[3], &host_timeout))
    return mk_error_s(out, "link", "badarg", "malformed limits");
  inst->host_timeout_ms = host_timeout;

  inst->store = wasmtime_store_new(engines[inst->mod->fuel], NULL, NULL);
  inst->ctx = wasmtime_store_context(inst->store);
  wasmtime_store_limiter(inst->store, mem, elems, instances, tables, -1);
  wasmtime_store_epoch_deadline_callback(inst->store, epoch_callback, inst, NULL);
  wasmtime_context_set_epoch_deadline(inst->ctx, 1);
  inst->linker = wasmtime_linker_new(engines[inst->mod->fuel]);

  ERL_NIF_TERM wasi_err = configure_wasi(inst, env, out, o[1]);
  if (wasi_err) return wasi_err;

  /* Host functions: only imports named in the map are defined. Anything else
   * the module needs makes wasmtime_linker_instantiate fail with a link error. */
  unsigned nimports;
  if (!enif_get_list_length(env, o[0], &nimports))
    return mk_error_s(out, "link", "badarg", "imports must be a list");
  inst->hostfns = enif_alloc(sizeof(hostfn_t) * (nimports + 1));
  memset(inst->hostfns, 0, sizeof(hostfn_t) * (nimports + 1));

  wasm_importtype_vec_t imports;
  wasmtime_module_imports(inst->mod->mod, &imports);
  ERL_NIF_TERM l = o[0], h;
  ERL_NIF_TERM result = atom_ok;
  while (enif_get_list_cell(env, l, &h, &l)) {
    const ERL_NIF_TERM *mn;
    int ar;
    if (!enif_get_tuple(env, h, &ar, &mn) || ar != 2) {
      result = mk_error_s(out, "link", "badarg", "imports keys must be {Module, Name}");
      break;
    }
    char *module = bin_to_cstr(env, mn[0]), *name = bin_to_cstr(env, mn[1]);
    if (!module || !name) {
      enif_free(module);
      enif_free(name);
      result = mk_error_s(out, "link", "badarg", "imports keys must be binaries");
      break;
    }
    const wasm_importtype_t *found = NULL;
    for (size_t i = 0; i < imports.size; i++) {
      const wasm_name_t *m = wasm_importtype_module(imports.data[i]);
      const wasm_name_t *n = wasm_importtype_name(imports.data[i]);
      if (m->size == strlen(module) && memcmp(m->data, module, m->size) == 0 &&
          n->size == strlen(name) && memcmp(n->data, name, n->size) == 0) {
        found = imports.data[i];
        break;
      }
    }
    if (!found) {
      /* Providing a fun for an import the module does not have is harmless;
       * skip it so the same imports map can serve several modules. */
      enif_free(module);
      enif_free(name);
      continue;
    }
    const wasm_externtype_t *et = wasm_importtype_type(found);
    if (wasm_externtype_kind(et) != WASM_EXTERN_FUNC) {
      enif_free(module);
      enif_free(name);
      result = mk_error_s(out, "link", "unsupported_import",
                          "only function imports can be provided from Erlang");
      break;
    }
    const wasm_functype_t *ft = wasm_externtype_as_functype_const(et);
    const wasm_valtype_vec_t *ps = wasm_functype_params(ft), *rs = wasm_functype_results(ft);
    int refs = 0;
    for (size_t i = 0; i < ps->size; i++) refs |= ref_kind(kind_of(ps->data[i]));
    for (size_t i = 0; i < rs->size; i++) refs |= ref_kind(kind_of(rs->data[i]));
    if (refs || rs->size > MAX_VALS) {
      enif_free(module);
      enif_free(name);
      result = mk_error_s(out, "link", "unsupported_type",
                          "host functions cannot take or return reference types");
      break;
    }
    hostfn_t *fn = &inst->hostfns[inst->nhostfns];
    fn->module = module;
    fn->name = name;
    fn->type = wasm_functype_copy(ft);
    hostfn_env_t *he = enif_alloc(sizeof *he);
    he->inst = inst;
    he->idx = inst->nhostfns;
    inst->nhostfns++;
    /* The linker owns `he` from here and frees it with enif_free, on the
     * error path too. */
    wasmtime_error_t *e =
        wasmtime_linker_define_func_unchecked(inst->linker, module, strlen(module), name,
                                              strlen(name), fn->type, host_callback, he, enif_free);
    if (e) {
      result = error_to_term(out, e, "link");
      break;
    }
  }
  wasm_importtype_vec_delete(&imports);
  if (!enif_is_identical(result, atom_ok)) return result;

  /* This runs the module's start section, which may call host functions. */
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e =
      wasmtime_linker_instantiate(inst->linker, inst->ctx, inst->mod->mod, &inst->instance, &trap);
  result = outcome(inst, out, e, trap, "link");
  if (!enif_is_identical(result, atom_ok)) return result;
  inst->instantiated = 1;

  /* Cache the exported memory, "memory" by name or the first one exported. */
  wasmtime_extern_t ext;
  if (wasmtime_instance_export_get(inst->ctx, &inst->instance, "memory", 6, &ext) &&
      ext.kind == WASMTIME_EXTERN_MEMORY) {
    inst->memory = ext.of.memory;
    inst->has_memory = 1;
  } else {
    char *nm;
    size_t nlen;
    for (size_t i = 0;
         wasmtime_instance_export_nth(inst->ctx, &inst->instance, i, &nm, &nlen, &ext); i++) {
      if (ext.kind == WASMTIME_EXTERN_MEMORY) {
        inst->memory = ext.of.memory;
        inst->has_memory = 1;
        break;
      }
    }
  }
  return atom_ok;
}

static ERL_NIF_TERM do_call(instance_t *inst, req_t *req, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  ErlNifBinary name;
  if (!enif_inspect_iolist_as_binary(env, req->name, &name))
    return mk_error_s(out, "call", "badarg", "export name must be a binary");
  wasmtime_extern_t ext;
  if (!wasmtime_instance_export_get(inst->ctx, &inst->instance, (const char *)name.data, name.size,
                                    &ext))
    return mk_error(out, "call", "no_such_export", (const char *)name.data, name.size);
  if (ext.kind != WASMTIME_EXTERN_FUNC)
    return mk_error(out, "call", "not_a_function", (const char *)name.data, name.size);

  wasm_functype_t *ft = wasmtime_func_type(inst->ctx, &ext.of.func);
  const wasm_valtype_vec_t *ps = wasm_functype_params(ft), *rs = wasm_functype_results(ft);
  wasmtime_val_raw_t vals[MAX_VALS];
  ERL_NIF_TERM result;
  unsigned nargs;
  if (!enif_get_list_length(env, req->args, &nargs) || nargs != ps->size) {
    result = mk_error_s(out, "call", "badarity", "wrong number of arguments");
    goto done;
  }
  if (ps->size > MAX_VALS || rs->size > MAX_VALS) {
    result = mk_error_s(out, "call", "unsupported_type", "too many parameters or results");
    goto done;
  }
  {
    ERL_NIF_TERM l = req->args, h;
    for (size_t i = 0; enif_get_list_cell(env, l, &h, &l); i++) {
      uint8_t k = kind_of(ps->data[i]);
      if (ref_kind(k)) {
        result = mk_error_s(out, "call", "unsupported_type",
                            "reference-typed parameters cannot be passed from Erlang");
        goto done;
      }
      if (!term_to_raw(env, h, k, &vals[i])) {
        result = mk_error_s(out, "call", "badarg", "argument does not match the parameter type");
        goto done;
      }
    }
    for (size_t i = 0; i < rs->size; i++) {
      if (ref_kind(kind_of(rs->data[i]))) {
        result = mk_error_s(out, "call", "unsupported_type",
                            "reference-typed results cannot be returned to Erlang");
        goto done;
      }
    }
  }
  ErlNifUInt64 fuel;
  if (enif_get_uint64(env, req->opts, &fuel)) {
    wasmtime_error_t *fe = wasmtime_context_set_fuel(inst->ctx, fuel);
    if (fe) {
      wasmtime_error_delete(fe);
      result =
          mk_error_s(out, "call", "fuel_disabled",
                     "the module was not compiled with fuel metering: compile with fuel => true");
      goto done;
    }
  }
  wasmtime_context_set_epoch_deadline(inst->ctx, 1);
  {
    wasm_trap_t *trap = NULL;
    size_t nvals = ps->size > rs->size ? ps->size : rs->size;
    wasmtime_error_t *e = wasmtime_func_call_unchecked(inst->ctx, &ext.of.func, vals, nvals, &trap);
    result = outcome(inst, out, e, trap, "call");
    if (enif_is_identical(result, atom_ok)) {
      ERL_NIF_TERM list = enif_make_list(out, 0);
      for (size_t i = rs->size; i > 0; i--)
        list = enif_make_list_cell(out, raw_to_term(out, kind_of(rs->data[i - 1]), &vals[i - 1]),
                                   list);
      result = enif_make_tuple2(out, atom_ok, list);
    }
  }
done:
  wasm_functype_delete(ft);
  return result;
}

/* Called with the mutex held. Removes the request's monitor and frees it. */
static void req_done(instance_t *inst, req_t *req) {
  if (req->monitored) enif_demonitor_process(NULL, inst, &req->mon);
  req_free(req);
}

static void *worker_main(void *arg) {
  instance_t *inst = arg;
  pthread_mutex_lock(&inst->mu);
  while (!inst->stopping) {
    if (!inst->head) {
      pthread_cond_wait(&inst->cv, &inst->mu);
      continue;
    }
    req_t *req = inst->head;
    inst->head = req->next;
    if (!inst->head) inst->tail = NULL;
    if (req->cancelled) {
      req_done(inst, req);
      continue;
    }
    inst->current = req;
    inst->state = ST_RUNNING;
    inst->abort = 0;
    inst->interrupted_fired = 0;
    inst->host_failed = 0;
    __atomic_store_n(&inst->interrupt, 0, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&inst->mu);

    ErlNifEnv *out = enif_alloc_env();
    ERL_NIF_TERM result =
        req->kind == REQ_INSTANTIATE ? do_instantiate(inst, req, out) : do_call(inst, req, out);

    pthread_mutex_lock(&inst->mu);
    inst->state = ST_IDLE;
    inst->current = NULL;
    if (!req->cancelled) send_result(inst, req, out, result);
    enif_free_env(out);
    int failed_instantiate = req->kind == REQ_INSTANTIATE && !inst->instantiated;
    req_done(inst, req);
    if (failed_instantiate) inst->stopping = 1;
  }
  /* Nothing more runs. Tell whoever is still waiting. */
  while (inst->head) {
    req_t *req = inst->head;
    inst->head = req->next;
    if (!req->cancelled) {
      ErlNifEnv *out = enif_alloc_env();
      send_result(inst, req, out, mk_error_s(out, "call", "stopped", "instance is stopped"));
      enif_free_env(out);
    }
    req_done(inst, req);
  }
  inst->tail = NULL;
  pthread_mutex_unlock(&inst->mu);
  /* The thread's own reference; nothing below may touch `inst`. */
  enif_release_resource(inst);
  return NULL;
}

static void *ticker_main(void *arg) {
  struct timespec ts = {0, EPOCH_TICK_NS};
  while (!__atomic_load_n(&ticker_stop, __ATOMIC_ACQUIRE)) {
    nanosleep(&ts, NULL);
    wasmtime_engine_increment_epoch(engines[0]);
    wasmtime_engine_increment_epoch(engines[1]);
  }
  return NULL;
}

/* ------------------------------------------------------------ resources -- */

static void module_dtor(ErlNifEnv *env, void *obj) {
  module_res_t *m = obj;
  if (m->mod) wasmtime_module_delete(m->mod);
}

/* Runs once the handle and the worker thread have both let go: the thread
 * has exited (or never started), so nothing else can be using the instance. */
static void instance_dtor(ErlNifEnv *env, void *obj) {
  instance_t *inst = obj;
  while (inst->head) {
    req_t *r = inst->head;
    inst->head = r->next;
    req_free(r);
  }
  if (inst->linker) wasmtime_linker_delete(inst->linker);
  if (inst->store) wasmtime_store_delete(inst->store);
  for (size_t i = 0; i < inst->nhostfns; i++) {
    enif_free(inst->hostfns[i].module);
    enif_free(inst->hostfns[i].name);
    wasm_functype_delete(inst->hostfns[i].type);
  }
  enif_free(inst->hostfns);
  if (inst->reply_env) enif_free_env(inst->reply_env);
  if (inst->ref_env) enif_free_env(inst->ref_env);
  enif_free(inst->capture[0].data);
  enif_free(inst->capture[1].data);
  enif_free(inst->host_msg);
  if (inst->mod) enif_release_resource(inst->mod);
  pthread_mutex_destroy(&inst->mu);
  pthread_cond_destroy(&inst->cv);
}

/* Ask the running request to end. Called with the mutex held. */
static void stop_current(instance_t *inst) {
  inst->abort = 1;
  __atomic_store_n(&inst->interrupt, 1, __ATOMIC_RELEASE);
  pthread_cond_broadcast(&inst->cv);
}

/* Erlang dropped its last reference: stop the thread, never wait for it. */
static void handle_dtor(ErlNifEnv *env, void *obj) {
  handle_t *h = obj;
  instance_t *inst = h->inst;
  if (!inst) return;
  pthread_mutex_lock(&inst->mu);
  inst->stopping = 1;
  if (inst->current) inst->current->cancelled = 1;
  stop_current(inst);
  pthread_mutex_unlock(&inst->mu);
  enif_release_resource(inst);
}

/* A process with a request on this instance died. Its running request is
 * interrupted and its queued requests are dropped before they start. */
static void instance_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
  instance_t *inst = obj;
  pthread_mutex_lock(&inst->mu);
  if (inst->current && enif_compare_pids(&inst->current->caller, pid) == 0) {
    inst->current->cancelled = 1;
    stop_current(inst);
  }
  for (req_t *r = inst->head; r; r = r->next)
    if (enif_compare_pids(&r->caller, pid) == 0) r->cancelled = 1;
  pthread_mutex_unlock(&inst->mu);
}

/* ------------------------------------------------------ nif entry points -- */

static ERL_NIF_TERM nif_compile(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  int is_wat = enif_is_identical(argv[1], atom_true);
#if !NIF_HAVE_COMPILER
  (void)is_wat;
  return mk_error_s(env, "compile", "unavailable",
                    "this build of erlang_wasmtime has no compiler: use deserialize/1");
#else
  wasm_byte_vec_t wasm = {0, NULL};
  const uint8_t *data = bin.data;
  size_t size = bin.size;
  if (is_wat) {
#if !NIF_HAVE_WAT
    return mk_error_s(env, "compile", "unavailable",
                      "this build of erlang_wasmtime cannot read the text format");
#else
    wasmtime_error_t *e = wasmtime_wat2wasm((const char *)bin.data, bin.size, &wasm);
    if (e) return error_to_term(env, e, "compile");
    data = (const uint8_t *)wasm.data;
    size = wasm.size;
#endif
  }
  int fuel = enif_is_identical(argv[2], atom_true);
  wasmtime_module_t *mod = NULL;
  wasmtime_error_t *e = wasmtime_module_new(engines[fuel], data, size, &mod);
  if (is_wat) wasm_byte_vec_delete(&wasm);
  if (e) return error_to_term(env, e, "compile");
  module_res_t *m = enif_alloc_resource(module_type, sizeof *m);
  m->mod = mod;
  m->fuel = fuel;
  ERL_NIF_TERM t = enif_make_resource(env, m);
  enif_release_resource(m);
  return enif_make_tuple2(env, atom_ok, t);
#endif
}

/* validate(Binary) -> ok | {error, _}: decode and validate without compiling */
static ERL_NIF_TERM nif_validate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
#if !NIF_HAVE_COMPILER
  return mk_error_s(env, "compile", "unavailable", "this build of erlang_wasmtime cannot validate");
#else
  wasmtime_error_t *e = wasmtime_module_validate(engines[0], bin.data, bin.size);
  if (e) return error_to_term(env, e, "compile");
  return atom_ok;
#endif
}

/* serialize(Module) -> {ok, Binary}: Wasmtime's own precompiled format */
static ERL_NIF_TERM nif_serialize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
#if !NIF_HAVE_COMPILER
  return mk_error_s(env, "compile", "unavailable",
                    "this build of erlang_wasmtime cannot serialize modules");
#else
  wasm_byte_vec_t out;
  wasmtime_error_t *e = wasmtime_module_serialize(m->mod, &out);
  if (e) return error_to_term(env, e, "compile");
  ERL_NIF_TERM t = mk_binary(env, out.data, out.size);
  wasm_byte_vec_delete(&out);
  return enif_make_tuple2(env, atom_ok, t);
#endif
}

/* deserialize(Binary) -> {ok, Module}. Wasmtime checks its own version and
 * the CPU features the code was compiled for, not the code itself: only
 * bytes that came from serialize/1 may be passed here. */
static ERL_NIF_TERM nif_deserialize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  wasmtime_module_t *mod = NULL;
  int fuel = 0;
  wasmtime_error_t *e = wasmtime_module_deserialize(engines[0], bin.data, bin.size, &mod);
  if (e) {
    /* compiled with fuel metering? the other engine accepts it */
    wasmtime_error_t *e2 = wasmtime_module_deserialize(engines[1], bin.data, bin.size, &mod);
    if (e2) {
      wasmtime_error_delete(e2);
      return error_to_term(env, e, "compile");
    }
    wasmtime_error_delete(e);
    fuel = 1;
  }
  module_res_t *m = enif_alloc_resource(module_type, sizeof *m);
  m->mod = mod;
  m->fuel = fuel;
  ERL_NIF_TERM t = enif_make_resource(env, m);
  enif_release_resource(m);
  return enif_make_tuple2(env, atom_ok, t);
}

static ERL_NIF_TERM extern_kind_atom(wasm_externkind_t k) {
  switch (k) {
  case WASM_EXTERN_FUNC: return atom_func;
  case WASM_EXTERN_GLOBAL: return atom_global;
  case WASM_EXTERN_TABLE: return atom_table;
  case WASM_EXTERN_MEMORY: return atom_memory;
  default: return atom_tag; /* WASM_EXTERN_TAG, the last kind in wasm.h */
  }
}

static ERL_NIF_TERM nif_module_imports(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
  wasm_importtype_vec_t v;
  wasmtime_module_imports(m->mod, &v);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = v.size; i > 0; i--) {
    const wasm_importtype_t *it = v.data[i - 1];
    const wasm_name_t *mn = wasm_importtype_module(it), *nn = wasm_importtype_name(it);
    list = enif_make_list_cell(
        env,
        enif_make_tuple3(env, mk_binary(env, mn->data, mn->size),
                         mk_binary(env, nn->data, nn->size),
                         extern_kind_atom(wasm_externtype_kind(wasm_importtype_type(it)))),
        list);
  }
  wasm_importtype_vec_delete(&v);
  return list;
}

static ERL_NIF_TERM nif_module_exports(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
  wasm_exporttype_vec_t v;
  wasmtime_module_exports(m->mod, &v);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = v.size; i > 0; i--) {
    const wasm_exporttype_t *et = v.data[i - 1];
    const wasm_name_t *nn = wasm_exporttype_name(et);
    list = enif_make_list_cell(
        env,
        enif_make_tuple2(env, mk_binary(env, nn->data, nn->size),
                         extern_kind_atom(wasm_externtype_kind(wasm_exporttype_type(et)))),
        list);
  }
  wasm_exporttype_vec_delete(&v);
  return list;
}

static int get_handle(ErlNifEnv *env, ERL_NIF_TERM t, instance_t **out) {
  handle_t *h;
  if (!enif_get_resource(env, t, handle_type, (void **)&h)) return 0;
  *out = h->inst;
  return 1;
}

/* Enqueue a request for the instance thread. Called on a scheduler thread. */
static ERL_NIF_TERM enqueue(ErlNifEnv *env, instance_t *inst, enum req_kind kind, ERL_NIF_TERM id,
                            ERL_NIF_TERM name, ERL_NIF_TERM args, ERL_NIF_TERM opts) {
  req_t *r = enif_alloc(sizeof *r);
  memset(r, 0, sizeof *r);
  r->kind = kind;
  if (!enif_get_uint64(env, id, &r->id)) {
    enif_free(r);
    return enif_make_badarg(env);
  }
  enif_self(env, &r->caller);
  r->env = enif_alloc_env();
  r->name = enif_make_copy(r->env, name);
  r->args = enif_make_copy(r->env, args);
  r->opts = enif_make_copy(r->env, opts);

  pthread_mutex_lock(&inst->mu);
  if (inst->stopping) {
    pthread_mutex_unlock(&inst->mu);
    req_free(r);
    return mk_error_s(env, "call", "stopped", "instance is stopped");
  }
  /* A host function calling back into the instance it runs on would wait for
   * itself: the guest is parked until this process answers the host call. */
  if (inst->state == ST_IN_HOST && enif_compare_pids(&inst->host_target, &r->caller) == 0) {
    pthread_mutex_unlock(&inst->mu);
    req_free(r);
    return mk_error_s(env, "call", "reentrant",
                      "a host function cannot call the instance it is running on");
  }
  r->monitored = enif_monitor_process(env, inst, &r->caller, &r->mon) == 0;
  if (inst->tail)
    inst->tail->next = r;
  else
    inst->head = r;
  inst->tail = r;
  pthread_cond_broadcast(&inst->cv);
  pthread_mutex_unlock(&inst->mu);
  return atom_enqueued;
}

/* instantiate(Module, Opts, Ref, Id) -> {ok, Handle}; result arrives as a message */
static ERL_NIF_TERM nif_instantiate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m) || !enif_is_ref(env, argv[2]))
    return enif_make_badarg(env);

  instance_t *inst = enif_alloc_resource(instance_type, sizeof *inst);
  memset(inst, 0, sizeof *inst);
  pthread_mutex_init(&inst->mu, NULL);
  pthread_cond_init(&inst->cv, NULL);
  inst->reply_env = enif_alloc_env();
  inst->ref_env = enif_alloc_env();
  inst->ref = enif_make_copy(inst->ref_env, argv[2]);
  inst->mod = m;
  enif_keep_resource(m);
  inst->host_timeout_ms = 30000;

  /* The handle holds one reference to the instance, the thread the other
   * (the one enif_alloc_resource returned). */
  handle_t *h = enif_alloc_resource(handle_type, sizeof *h);
  h->inst = inst;
  enif_keep_resource(inst);
  ERL_NIF_TERM ht = enif_make_resource(env, h);
  enif_release_resource(h);

  ERL_NIF_TERM r =
      enqueue(env, inst, REQ_INSTANTIATE, argv[3], atom_undefined, atom_undefined, argv[1]);
  if (!enif_is_identical(r, atom_enqueued)) {
    enif_release_resource(inst);
    return r;
  }
  /* Wasmtime runs the guest on the native stack (max_wasm_stack, 512 KB by
   * default) and our callback runs above it; the platform default for a new
   * thread is 512 KB on macOS. Ask for a size that holds both everywhere. */
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
  pthread_t tid;
  int rc = pthread_create(&tid, &attr, worker_main, inst);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    pthread_mutex_lock(&inst->mu);
    inst->stopping = 1;
    pthread_mutex_unlock(&inst->mu);
    enif_release_resource(inst); /* the thread's reference, never taken */
    return mk_error_s(env, "link", "thread", "could not start instance thread");
  }
  return enif_make_tuple2(env, atom_ok, ht);
}

/* call(Handle, Name, Args, Id, Fuel | undefined) -> enqueued; result arrives as a message */
static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst) || !enif_is_list(env, argv[2])) return enif_make_badarg(env);
  return enqueue(env, inst, REQ_CALL, argv[3], argv[1], argv[2], argv[4]);
}

/* Look up an export of a given kind while the guest is not executing. On
 * success the caller holds inst->mu. */
static ERL_NIF_TERM with_export(ErlNifEnv *env, ERL_NIF_TERM handle, ERL_NIF_TERM name,
                                wasmtime_extern_kind_t kind, const char *what, instance_t **out,
                                wasmtime_extern_t *ext) {
  instance_t *inst;
  ErlNifBinary nm;
  if (!get_handle(env, handle, &inst) || !enif_inspect_iolist_as_binary(env, name, &nm))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  if (inst->state == ST_RUNNING) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, what, "busy", "guest is running");
  }
  if (!inst->instantiated ||
      !wasmtime_instance_export_get(inst->ctx, &inst->instance, (const char *)nm.data, nm.size,
                                    ext) ||
      ext->kind != kind) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error(env, what, "no_such_export", (const char *)nm.data, nm.size);
  }
  *out = inst;
  return 0;
}

/* A wasmtime_val_t (from a global) as a term; refs are refused. */
static ERL_NIF_TERM typed_val_to_term(ErlNifEnv *env, wasmtime_val_t *v, ERL_NIF_TERM *out) {
  wasmtime_val_raw_t r;
  switch (v->kind) {
  case WASMTIME_I32: *out = enif_make_int(env, v->of.i32); return 0;
  case WASMTIME_I64: *out = enif_make_int64(env, v->of.i64); return 0;
  case WASMTIME_F32:
    r.f32 = v->of.f32;
    *out = raw_to_term(env, WASMTIME_VALTYPE_KIND_F32, &r);
    return 0;
  case WASMTIME_F64:
    r.f64 = v->of.f64;
    *out = raw_to_term(env, WASMTIME_VALTYPE_KIND_F64, &r);
    return 0;
  case WASMTIME_V128: *out = mk_binary(env, v->of.v128, 16); return 0;
  default:
    wasmtime_val_unroot(v);
    return mk_error_s(env, "global", "unsupported_type", "reference-typed values cannot be read");
  }
}

/* A term as a wasmtime_val_t of the given WASMTIME_VALTYPE_KIND_*. */
static int term_to_typed_val(ErlNifEnv *env, ERL_NIF_TERM t, uint8_t kind, wasmtime_val_t *v) {
  wasmtime_val_raw_t r;
  if (ref_kind(kind) || !term_to_raw(env, t, kind, &r)) return 0;
  switch (kind) {
  case WASMTIME_VALTYPE_KIND_I32:
    v->kind = WASMTIME_I32;
    v->of.i32 = r.i32;
    return 1;
  case WASMTIME_VALTYPE_KIND_I64:
    v->kind = WASMTIME_I64;
    v->of.i64 = r.i64;
    return 1;
  case WASMTIME_VALTYPE_KIND_F32:
    v->kind = WASMTIME_F32;
    v->of.f32 = r.f32;
    return 1;
  case WASMTIME_VALTYPE_KIND_F64:
    v->kind = WASMTIME_F64;
    v->of.f64 = r.f64;
    return 1;
  default:
    v->kind = WASMTIME_V128;
    memcpy(v->of.v128, r.v128, 16);
    return 1;
  }
}

/* global_get(Handle, Name) -> {ok, Value} */
static ERL_NIF_TERM nif_global_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_GLOBAL, "global", &inst, &ext);
  if (err) return err;
  wasmtime_val_t v;
  wasmtime_global_get(inst->ctx, &ext.of.global, &v);
  ERL_NIF_TERM value = atom_undefined;
  err = typed_val_to_term(env, &v, &value);
  pthread_mutex_unlock(&inst->mu);
  return err ? err : enif_make_tuple2(env, atom_ok, value);
}

/* global_set(Handle, Name, Value) -> ok */
static ERL_NIF_TERM nif_global_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_GLOBAL, "global", &inst, &ext);
  if (err) return err;
  wasm_globaltype_t *gt = wasmtime_global_type(inst->ctx, &ext.of.global);
  ERL_NIF_TERM r;
  wasmtime_val_t v;
  if (wasm_globaltype_mutability(gt) == WASM_CONST) {
    r = mk_error_s(env, "global", "immutable", "the global is not mutable");
  } else if (!term_to_typed_val(env, argv[2], kind_of(wasm_globaltype_content(gt)), &v)) {
    r = mk_error_s(env, "global", "badarg", "value does not match the global's type");
  } else {
    wasmtime_error_t *e = wasmtime_global_set(inst->ctx, &ext.of.global, &v);
    r = e ? error_to_term(env, e, "global") : atom_ok;
  }
  wasm_globaltype_delete(gt);
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* table_size(Handle, Name) -> {ok, Elements} */
static ERL_NIF_TERM nif_table_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  ERL_NIF_TERM r = enif_make_tuple2(
      env, atom_ok, enif_make_uint64(env, wasmtime_table_size(inst->ctx, &ext.of.table)));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* table_grow(Handle, Name, Delta) -> {ok, PreviousSize}: new slots hold null */
static ERL_NIF_TERM nif_table_grow(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 delta;
  if (!enif_get_uint64(env, argv[2], &delta)) return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  uint64_t prev = 0;
  wasmtime_val_t init;
  memset(&init, 0, sizeof init);
  init.kind = WASMTIME_FUNCREF; /* a null funcref: store_id 0 */
  wasmtime_error_t *e = wasmtime_table_grow(inst->ctx, &ext.of.table, delta, &init, &prev);
#ifdef WASMTIME_EXTERNREF
  if (e) {
    /* not a funcref table: a null externref then */
    wasmtime_error_delete(e);
    memset(&init, 0, sizeof init);
    init.kind = WASMTIME_EXTERNREF;
    e = wasmtime_table_grow(inst->ctx, &ext.of.table, delta, &init, &prev);
  }
#endif
  ERL_NIF_TERM r = e ? error_to_term(env, e, "table")
                     : enif_make_tuple2(env, atom_ok, enif_make_uint64(env, prev));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* fuel_remaining(Handle) -> {ok, Fuel} */
static ERL_NIF_TERM nif_fuel_remaining(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r;
  uint64_t fuel = 0;
  if (inst->state == ST_RUNNING) {
    r = mk_error_s(env, "call", "busy", "guest is running");
  } else if (!inst->instantiated || !inst->mod->fuel) {
    r = mk_error_s(env, "call", "fuel_disabled",
                   "the module was not compiled with fuel metering: compile with fuel => true");
  } else {
    wasmtime_error_t *e = wasmtime_context_get_fuel(inst->ctx, &fuel);
    r = e ? error_to_term(env, e, "call")
          : enif_make_tuple2(env, atom_ok, enif_make_uint64(env, fuel));
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* host_reply(Handle, HostId, {ok, Results} | {error, Message}) -> ok */
static ERL_NIF_TERM nif_host_reply(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  ErlNifUInt64 id;
  if (!get_handle(env, argv[0], &inst) || !enif_get_uint64(env, argv[1], &id))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r;
  if (inst->state == ST_IN_HOST && inst->host_id == id && !inst->has_reply) {
    inst->reply = enif_make_copy(inst->reply_env, argv[2]);
    inst->has_reply = 1;
    pthread_cond_broadcast(&inst->cv);
    r = atom_ok;
  } else {
    r = enif_make_tuple2(env, atom_error, atom_no_pending_host_call);
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* interrupt(Handle) -> ok | not_running: end whatever runs, keep its result */
static ERL_NIF_TERM nif_interrupt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r = atom_not_running;
  if (inst->current) {
    stop_current(inst);
    r = atom_ok;
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* cancel(Handle, Id) -> ok | not_running: end request Id and drop its result.
 * `ok` means no result message will follow; `not_running` means the request
 * already finished and its result is in the caller's mailbox. */
static ERL_NIF_TERM nif_cancel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  ErlNifUInt64 id;
  if (!get_handle(env, argv[0], &inst) || !enif_get_uint64(env, argv[1], &id))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r = atom_not_running;
  if (inst->current && inst->current->id == id) {
    inst->current->cancelled = 1;
    stop_current(inst);
    r = atom_ok;
  } else {
    for (req_t *q = inst->head; q; q = q->next) {
      if (q->id == id) {
        q->cancelled = 1;
        r = atom_ok;
        break;
      }
    }
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* Memory is reachable from Erlang only while the guest is not executing:
 * when the instance is idle, or while it waits inside a host function. On
 * success the caller holds inst->mu and *mem names the memory: the default
 * one when `name` is the atom `default`, else the export called `name`. */
static ERL_NIF_TERM with_memory(ErlNifEnv *env, ERL_NIF_TERM handle, ERL_NIF_TERM name,
                                instance_t **out, wasmtime_memory_t *mem) {
  instance_t *inst;
  ErlNifBinary nm;
  int named = !enif_is_atom(env, name);
  if (!get_handle(env, handle, &inst) || (named && !enif_inspect_iolist_as_binary(env, name, &nm)))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  if (inst->state == ST_RUNNING) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, "memory", "busy", "guest is running");
  }
  if (!inst->instantiated) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, "memory", "no_memory", "instance exports no memory");
  }
  if (named) {
    wasmtime_extern_t ext;
    if (!wasmtime_instance_export_get(inst->ctx, &inst->instance, (const char *)nm.data, nm.size,
                                      &ext) ||
        ext.kind != WASMTIME_EXTERN_MEMORY) {
      pthread_mutex_unlock(&inst->mu);
      return mk_error(env, "memory", "no_memory", (const char *)nm.data, nm.size);
    }
    *mem = ext.of.memory;
  } else if (inst->has_memory) {
    *mem = inst->memory;
  } else {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, "memory", "no_memory", "instance exports no memory");
  }
  *out = inst;
  return 0;
}

/* read_memory(Handle, Name | default, Ptr, Len) */
static ERL_NIF_TERM nif_read_memory(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 ptr, len;
  if (!enif_get_uint64(env, argv[2], &ptr) || !enif_get_uint64(env, argv[3], &len))
    return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  size_t size = wasmtime_memory_data_size(inst->ctx, &mem);
  ERL_NIF_TERM r;
  if (ptr > size || len > size - ptr) {
    r = mk_error_s(env, "memory", "out_of_bounds", "range is outside linear memory");
  } else {
    const uint8_t *data = wasmtime_memory_data(inst->ctx, &mem);
    r = enif_make_tuple2(env, atom_ok, mk_binary(env, data + ptr, len));
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* write_memory(Handle, Name | default, Ptr, Data) */
static ERL_NIF_TERM nif_write_memory(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 ptr;
  ErlNifBinary bin;
  if (!enif_get_uint64(env, argv[2], &ptr) || !enif_inspect_iolist_as_binary(env, argv[3], &bin))
    return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  size_t size = wasmtime_memory_data_size(inst->ctx, &mem);
  ERL_NIF_TERM r;
  if (ptr > size || bin.size > size - ptr) {
    r = mk_error_s(env, "memory", "out_of_bounds", "range is outside linear memory");
  } else {
    memcpy(wasmtime_memory_data(inst->ctx, &mem) + ptr, bin.data, bin.size);
    r = atom_ok;
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* memory_size(Handle, Name | default) */
static ERL_NIF_TERM nif_memory_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  ERL_NIF_TERM r = enif_make_tuple2(
      env, atom_ok,
      enif_make_tuple2(env, enif_make_uint64(env, wasmtime_memory_size(inst->ctx, &mem)),
                       enif_make_uint64(env, wasmtime_memory_data_size(inst->ctx, &mem))));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* read_output(Handle) -> {ok, {Stdout, Stderr, {DroppedOut, DroppedErr}}}: takes what
 * the captured streams hold and empties them; safe while the guest runs. */
static ERL_NIF_TERM nif_read_output(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM out = mk_binary(env, inst->capture[0].data, inst->capture[0].len);
  ERL_NIF_TERM err = mk_binary(env, inst->capture[1].data, inst->capture[1].len);
  ERL_NIF_TERM dropped = enif_make_tuple2(env, enif_make_uint64(env, inst->dropped[0]),
                                          enif_make_uint64(env, inst->dropped[1]));
  inst->capture[0].len = inst->capture[1].len = 0;
  inst->dropped[0] = inst->dropped[1] = 0;
  pthread_mutex_unlock(&inst->mu);
  return enif_make_tuple2(env, atom_ok, enif_make_tuple3(env, out, err, dropped));
}

/* features() -> #{compiler => bool, wat => bool, wasi => bool} */
static ERL_NIF_TERM nif_features(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ERL_NIF_TERM keys[3] = {atom_compiler, atom_wat, atom_wasi};
  ERL_NIF_TERM vals[3] = {NIF_HAVE_COMPILER ? atom_true : atom_false,
                          NIF_HAVE_WAT ? atom_true : atom_false,
                          NIF_HAVE_WASI ? atom_true : atom_false};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 3, &map);
  return map;
}

static ERL_NIF_TERM nif_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  return mk_binary(env, WASMTIME_VERSION, strlen(WASMTIME_VERSION));
}

/* ---------------------------------------------------------- load/unload -- */

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
#define A(name, str) name = enif_make_atom(env, str)
  A(atom_ok, "ok");
  A(atom_error, "error");
  A(atom_true, "true");
  A(atom_false, "false");
  A(atom_compiler, "compiler");
  A(atom_wat, "wat");
  A(atom_wasi, "wasi");
  A(atom_none, "none");
  A(atom_trace, "trace");
  A(atom_func_index, "func_index");
  A(atom_func_offset, "func_offset");
  A(atom_func_name, "func_name");
  A(atom_module_name, "module_name");
  A(atom_immutable, "immutable");
  A(atom_capture, "capture");
  A(atom_binary, "binary");
  A(atom_undefined, "undefined");
  A(atom_inherit, "inherit");
  A(atom_file, "file");
  A(atom_read, "read");
  A(atom_write, "write");
  A(atom_nan, "nan");
  A(atom_infinity, "infinity");
  A(atom_neg_infinity, "neg_infinity");
  A(atom_class, "class");
  A(atom_kind, "kind");
  A(atom_message, "message");
  A(atom_status, "status");
  A(atom_not_running, "not_running");
  A(atom_func, "func");
  A(atom_global, "global");
  A(atom_table, "table");
  A(atom_memory, "memory");
  A(atom_tag, "tag");
  A(atom_wasmtime_result, "wasmtime_result");
  A(atom_wasmtime_host_call, "wasmtime_host_call");
  A(atom_no_pending_host_call, "no_pending_host_call");
  A(atom_enqueued, "enqueued");
#undef A

  ErlNifResourceTypeInit mi = {.dtor = module_dtor};
  ErlNifResourceTypeInit ii = {.dtor = instance_dtor, .down = instance_down};
  ErlNifResourceTypeInit hi = {.dtor = handle_dtor};
  module_type = enif_open_resource_type_x(env, "wasmtime_module", &mi, ERL_NIF_RT_CREATE, NULL);
  instance_type = enif_open_resource_type_x(env, "wasmtime_instance", &ii, ERL_NIF_RT_CREATE, NULL);
  handle_type = enif_open_resource_type_x(env, "wasmtime_handle", &hi, ERL_NIF_RT_CREATE, NULL);
  if (!module_type || !instance_type || !handle_type) return -1;

  for (int fuel = 0; fuel < 2; fuel++) {
    wasm_config_t *cfg = wasm_config_new();
    wasmtime_config_epoch_interruption_set(cfg, true);
    wasmtime_config_consume_fuel_set(cfg, fuel);
    /* Engine settings are part of a precompiled module's compatibility
     * check. Runtime-only builds have no component model, so the full build
     * must not compile modules with the concurrency support it would
     * otherwise enable by default; nothing here uses components. */
#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
    wasmtime_config_concurrency_support_set(cfg, false);
#endif
    engines[fuel] = wasm_engine_new_with_config(cfg); /* consumes cfg */
    if (!engines[fuel]) return -1;
  }
  ticker_stop = 0;
  if (pthread_create(&ticker, NULL, ticker_main, NULL) != 0) {
    wasm_engine_delete(engines[0]);
    wasm_engine_delete(engines[1]);
    return -1;
  }
  return 0;
}

/* Instances still alive at unload keep their own engine reference through
 * their store; deleting ours here only drops the handle taken at load. */
static void unload(ErlNifEnv *env, void *priv) {
  __atomic_store_n(&ticker_stop, 1, __ATOMIC_RELEASE);
  pthread_join(ticker, NULL);
  wasm_engine_delete(engines[0]);
  wasm_engine_delete(engines[1]);
}

static ErlNifFunc funcs[] = {
    {"compile", 3, nif_compile, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"validate", 1, nif_validate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"module_imports", 1, nif_module_imports, 0},
    {"module_exports", 1, nif_module_exports, 0},
    {"serialize", 1, nif_serialize, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"deserialize", 1, nif_deserialize, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"instantiate", 4, nif_instantiate, 0},
    {"call", 5, nif_call, 0},
    {"global_get", 2, nif_global_get, 0},
    {"global_set", 3, nif_global_set, 0},
    {"table_size", 2, nif_table_size, 0},
    {"table_grow", 3, nif_table_grow, 0},
    {"fuel_remaining", 1, nif_fuel_remaining, 0},
    {"host_reply", 3, nif_host_reply, 0},
    {"interrupt", 1, nif_interrupt, 0},
    {"cancel", 2, nif_cancel, 0},
    {"read_memory", 4, nif_read_memory, 0},
    {"write_memory", 4, nif_write_memory, 0},
    {"memory_size", 2, nif_memory_size, 0},
    {"read_output", 1, nif_read_output, 0},
    {"features", 0, nif_features, 0},
    {"version", 0, nif_version, 0},
};

ERL_NIF_INIT(wasmtime_nif, funcs, load, NULL, NULL, unload)
