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
 *   - A guest that runs for long exchanges bytes without stopping: send/2
 *     queues a message in the instance inbox, read by the guest through
 *     `stdin => stream` or the `erlang.recv` import; guest writes to a
 *     `stream` stdout/stderr or `erlang.send` arrive as
 *         {wasmtime_stream, Ref, stdout | stderr | channel, Bytes}
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
 * Sections: atoms and errors, values, instance state, host calls, streams,
 * worker thread, resources, NIF entry points, load/unload.
 */
/* clock_gettime, nanosleep and pthread_cond_timedwait under -std=c11 */
#ifndef WASMTIME_NIF_H
#define WASMTIME_NIF_H

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

/* -------------------------------------------------------------- atoms -- */
extern ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false, atom_compiler, atom_wat, atom_wasi,
    atom_none, atom_capture, atom_binary, atom_trace, atom_func_index, atom_func_offset,
    atom_func_name, atom_module_name, atom_immutable, atom_undefined, atom_inherit, atom_file,
    atom_read, atom_write, atom_nan, atom_infinity, atom_neg_infinity, atom_class, atom_kind,
    atom_message, atom_status, atom_not_running, atom_func, atom_global, atom_table, atom_memory,
    atom_tag, atom_wasmtime_result, atom_wasmtime_host_call, atom_no_pending_host_call,
    atom_enqueued, atom_stream, atom_wasmtime_stream, atom_stdout, atom_stderr, atom_channel,
    atom_null, atom_i31, atom_externref, atom_funcref, atom_struct, atom_array, atom_anyref,
    atom_instance;

/* -------------------------------------------------------------- types -- */
/* wasm_valtype_kind aborts the process on v128 and on non-nullable references
 * (a TODO in Wasmtime's C API); wasmtime_valtype_new classifies every type. */
/* A value type as the boundary sees it: the kind, and for references the
 * family that decides which Erlang terms are accepted and which
 * wasmtime_val_t kind carries them. wasm_valtype_kind aborts the process on
 * GC and non-nullable types, so everything goes through wasmtime_valtype_t. */
enum { FAM_NUM, FAM_EXTERN, FAM_FUNC, FAM_ANY, FAM_EXN };
typedef struct {
  uint8_t kind; /* WASMTIME_VALTYPE_KIND_* */
  uint8_t fam;
  uint8_t nullable;
} vtype_t;
/* How a function type crosses: the raw path carries numbers and v128, the
 * typed path carries references (and checks them). Both at once, or an
 * exception reference, cannot cross. */
typedef struct {
  int refs, v128, exn;
} shape_t;
struct engine_entry;
typedef struct {
  wasmtime_module_t *mod;
  struct engine_entry *engine; /* the engine it was compiled or loaded with */
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
  int typed; /* references in the signature: the checked callback serves it */
} hostfn_t;
struct instance;
typedef struct {
  struct instance *inst;
  size_t idx;
} hostfn_env_t;
enum state { ST_IDLE, ST_RUNNING, ST_IN_HOST };
typedef struct chunk {
  unsigned char *data;
  size_t len, off; /* off: what stdin already consumed */
  struct chunk *next;
} chunk_t;
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

  /* Bytes sent to the guest with send/2, one chunk per call, read by the
   * guest through stdin (`stdin => stream`) or the `erlang.recv` import.
   * Guarded by mu, signalled on cv. */
  struct chunk *inbox_head, *inbox_tail;
  size_t inbox_bytes, inbox_limit;
  int inbox_closed;
  ErlNifPid stream_pid; /* receives {wasmtime_stream, Ref, Kind, Bytes} */
  int stdin_stream;
  wasmtime_func_t real_fd_read; /* Wasmtime's own, taken before it is shadowed */
  wasmtime_func_t wasi_fd_read; /* the shim in front of it, for fds other than 0 */
  int has_fd_read;

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
/* A reference the guest handed out, as an Erlang term. externref and anyref
 * are owned GC roots (wasmtime_*_unroot takes no context and only drops a
 * liveness Arc, so the destructor may run on any thread, even after the
 * store is gone); funcref is a store-bound handle with nothing to release.
 * The resource keeps its instance alive so the store outlives the term. */
enum { REF_EXTERN, REF_FUNC, REF_ANY };
typedef struct {
  instance_t *inst;
  uint8_t kind;
  union {
    wasmtime_func_t func;
#ifdef WASMTIME_FEATURE_GC
    wasmtime_externref_t ext;
    wasmtime_anyref_t any;
#endif
  } of;
} ref_t;
/* One engine per distinct set of compile options. Fuel metering and the
 * optimization level change code generation and are part of a precompiled
 * module's compatibility check; proposal toggles change validation. Engines
 * are created on first use, never freed, and capped. The ticker bumps every
 * engine's epoch. */
#define NPROPOSALS 15
#define MAX_ENGINES 32
typedef struct engine_entry {
  wasm_engine_t *engine;
  int fuel;
  int opt_level;               /* 0 none, 1 speed, 2 speed_and_size */
  uint32_t set_mask, val_mask; /* proposal overrides: which, and to what */
  wasmtime_module_t *shim;     /* the stdin stream forwarder, compiled on first use */
  struct engine_entry *next;
} engine_t;

extern ErlNifResourceType *module_type, *instance_type, *handle_type, *ref_type;

#if NIF_HAVE_WASI
/* Env of a custom stdout/stderr callback (capture or stream). */
typedef struct {
  instance_t *inst;
  int which; /* 0 stdout, 1 stderr */
} capture_env_t;
#endif

/* ------------------------------------------- shared between the files -- */
ERL_NIF_TERM mk_atom(ErlNifEnv *env, const char *s);
ERL_NIF_TERM mk_binary(ErlNifEnv *env, const void *data, size_t len);
ERL_NIF_TERM mk_error(ErlNifEnv *env, const char *cls, const char *kind, const char *msg,
                      size_t len);
ERL_NIF_TERM mk_error_s(ErlNifEnv *env, const char *cls, const char *kind, const char *msg);
ERL_NIF_TERM trap_to_term(ErlNifEnv *env, wasm_trap_t *trap);
ERL_NIF_TERM error_to_term(ErlNifEnv *env, wasmtime_error_t *err, const char *cls);
void vtype_of(const wasm_valtype_t *vt, vtype_t *t);
uint8_t kind_of(const wasm_valtype_t *vt);
shape_t shape_of(const wasm_functype_t *ft);
ERL_NIF_TERM raw_to_term(ErlNifEnv *env, uint8_t kind, const wasmtime_val_raw_t *v);
int term_to_raw(ErlNifEnv *env, ERL_NIF_TERM t, uint8_t kind, wasmtime_val_raw_t *v);
ERL_NIF_TERM val_to_term(ErlNifEnv *env, instance_t *inst, wasmtime_val_t *v);
const char *term_to_val(ErlNifEnv *env, instance_t *inst, ERL_NIF_TERM term, const vtype_t *t,
                        wasmtime_val_t *v);
void unroot_vals(wasmtime_val_t *vals, size_t n);
ERL_NIF_TERM conv_error(ErlNifEnv *env, const char *cls, const char *kind);
ERL_NIF_TERM term_or_unsupported(ErlNifEnv *env, const char *cls, ERL_NIF_TERM t);
engine_t *engine_for(ErlNifEnv *env, ERL_NIF_TERM key, ERL_NIF_TERM *err);
ERL_NIF_TERM key_term(ErlNifEnv *env, const engine_t *e);
wasmtime_module_t *engine_shim(engine_t *e, ErlNifEnv *env, ERL_NIF_TERM shim, const char **why);
wasmtime_error_t *epoch_callback(wasmtime_context_t *ctx, void *data, uint64_t *delta,
                                 wasmtime_update_deadline_kind_t *kind);
void *worker_main(void *arg);
void module_dtor(ErlNifEnv *env, void *obj);
void instance_dtor(ErlNifEnv *env, void *obj);
void stop_current(instance_t *inst);
void handle_dtor(ErlNifEnv *env, void *obj);
void instance_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon);
int get_handle(ErlNifEnv *env, ERL_NIF_TERM t, instance_t **out);
ERL_NIF_TERM enqueue(ErlNifEnv *env, instance_t *inst, enum req_kind kind, ERL_NIF_TERM id,
                     ERL_NIF_TERM name, ERL_NIF_TERM args, ERL_NIF_TERM opts);
ERL_NIF_TERM with_export(ErlNifEnv *env, ERL_NIF_TERM handle, ERL_NIF_TERM name,
                         wasmtime_extern_kind_t kind, const char *what, instance_t **out,
                         wasmtime_extern_t *ext);
ERL_NIF_TERM with_ref(ErlNifEnv *env, ERL_NIF_TERM term, ref_t **out);
ERL_NIF_TERM with_memory(ErlNifEnv *env, ERL_NIF_TERM handle, ERL_NIF_TERM name, instance_t **out,
                         wasmtime_memory_t *mem);
ERL_NIF_TERM do_instantiate(instance_t *inst, req_t *req, ErlNifEnv *out);
ERL_NIF_TERM do_call(instance_t *inst, req_t *req, ErlNifEnv *out);
ERL_NIF_TERM outcome(instance_t *inst, ErlNifEnv *out, wasmtime_error_t *e, wasm_trap_t *trap,
                     const char *cls);
wasm_trap_t *host_callback(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                           size_t nvals);
wasm_trap_t *host_callback_typed(void *envp, wasmtime_caller_t *caller, const wasmtime_val_t *args,
                                 size_t nargs, wasmtime_val_t *results, size_t nresults);
void inbox_drop_head(instance_t *inst);
wasm_trap_t *fd_read_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                        size_t nvals);
ERL_NIF_TERM define_stdin_stream(instance_t *inst, ErlNifEnv *out);
ERL_NIF_TERM link_stdin_shim(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM shim_bytes,
                             ErlNifEnv *out);
ERL_NIF_TERM define_erlang_imports(instance_t *inst, ErlNifEnv *out,
                                   const wasm_importtype_vec_t *imports);
ptrdiff_t capture_write(void *envp, const unsigned char *data, size_t len);
ptrdiff_t stream_write(void *envp, const unsigned char *data, size_t len);
ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
void ref_dtor(ErlNifEnv *env, void *obj);
ERL_NIF_TERM mk_ref(ErlNifEnv *env, instance_t *inst, const ref_t *src);
ERL_NIF_TERM nif_ref_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_externref(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_externref_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_struct_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_struct_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_array_len(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_array_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_array_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_gc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
int ticker_start(void);
void ticker_shutdown(void);
void engines_free_all(void);
#ifndef WASMTIME_FEATURE_GC
/* Without GC support every reference entry point but funcref answers
 * `unavailable`; nif_refs.c defines nif_no_gc. */
#define nif_externref nif_no_gc
#define nif_externref_data nif_no_gc
#define nif_struct_get nif_no_gc
#define nif_struct_set nif_no_gc
#define nif_array_len nif_no_gc
#define nif_array_get nif_no_gc
#define nif_array_set nif_no_gc
#define nif_gc nif_no_gc
#endif

#endif /* WASMTIME_NIF_H */
