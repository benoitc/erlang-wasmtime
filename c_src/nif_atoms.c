/*
 * nif_atoms.c: Atoms and error terms: the one place that builds
 * {error, #{class, kind, msg, ctx}}, erlang_wasm's wasm_error shape, and
 * turns Wasmtime errors and traps into it. `class` is one of malformed,
 * invalid, link, trap and exhaustion.
 */
#include "nif.h"

ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false, atom_compiler, atom_wat, atom_wasi,
    atom_none, atom_capture, atom_binary, atom_trace, atom_func_index, atom_func_offset,
    atom_func_name, atom_module_name, atom_immutable, atom_undefined, atom_inherit, atom_file,
    atom_read, atom_write, atom_nan, atom_infinity, atom_neg_infinity, atom_class, atom_kind,
    atom_msg, atom_ctx, atom_not_running, atom_func, atom_global, atom_table, atom_memory, atom_tag,
    atom_wasmtime_result, atom_wasmtime_host_call, atom_no_pending_host_call, atom_enqueued,
    atom_stream, atom_wasmtime_stream, atom_stdout, atom_stderr, atom_channel, atom_null, atom_i31,
    atom_externref, atom_funcref, atom_struct, atom_array, atom_anyref, atom_instance, atom_imports,
    atom_wasi, atom_memory_limit, atom_max_tables, atom_max_table_elements, atom_max_instances,
    atom_host_timeout, atom_host, atom_inbox_limit, atom_shim, atom_args, atom_env, atom_dirs,
    atom_stdin, atom_output_limit, atom_clocks, atom_monotonic, atom_all, atom_detail, atom_name,
    atom_reason, atom_wasi_exit, atom_module, atom_fuel, atom_caller;

ERL_NIF_TERM mk_atom(ErlNifEnv *env, const char *s) {
  ERL_NIF_TERM a;
  if (!enif_make_existing_atom(env, s, &a, ERL_NIF_LATIN1)) a = enif_make_atom(env, s);
  return a;
}

ERL_NIF_TERM mk_binary(ErlNifEnv *env, const void *data, size_t len) {
  ERL_NIF_TERM t;
  unsigned char *p = enif_make_new_binary(env, len, &t);
  if (len) memcpy(p, data, len);
  return t;
}

/* {error, #{class => Class, kind => Kind, msg => Msg, ctx => Ctx}} */
ERL_NIF_TERM mk_error_ctx(ErlNifEnv *env, const char *cls, const char *kind, const char *msg,
                          size_t len, ERL_NIF_TERM ctx) {
  ERL_NIF_TERM keys[4] = {atom_class, atom_kind, atom_msg, atom_ctx};
  ERL_NIF_TERM vals[4] = {mk_atom(env, cls), mk_atom(env, kind), mk_binary(env, msg, len), ctx};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 4, &map);
  return enif_make_tuple2(env, atom_error, map);
}

ERL_NIF_TERM mk_error(ErlNifEnv *env, const char *cls, const char *kind, const char *msg,
                      size_t len) {
  return mk_error_ctx(env, cls, kind, msg, len, enif_make_new_map(env));
}

ERL_NIF_TERM mk_error_s(ErlNifEnv *env, const char *cls, const char *kind, const char *msg) {
  return mk_error(env, cls, kind, msg, strlen(msg));
}

static ERL_NIF_TERM ctx_put(ErlNifEnv *env, ERL_NIF_TERM ctx, ERL_NIF_TERM key, ERL_NIF_TERM val) {
  enif_make_map_put(env, ctx, key, val, &ctx);
  return ctx;
}

/* An error about a named thing: the name goes in ctx. */
ERL_NIF_TERM mk_name_error(ErlNifEnv *env, const char *cls, const char *kind, const char *msg,
                           const void *name, size_t len) {
  ERL_NIF_TERM ctx = ctx_put(env, enif_make_new_map(env), atom_name, mk_binary(env, name, len));
  return mk_error_ctx(env, cls, kind, msg, strlen(msg), ctx);
}

/* A call with another number of arguments than the function takes. */
ERL_NIF_TERM arity_error(ErlNifEnv *env, size_t expected, ERL_NIF_TERM args) {
  unsigned got = 0;
  ERL_NIF_TERM ctx = ctx_put(env, enif_make_new_map(env), mk_atom(env, "expected"),
                             enif_make_uint64(env, expected));
  if (enif_get_list_length(env, args, &got))
    ctx = ctx_put(env, ctx, mk_atom(env, "got"), enif_make_uint(env, got));
  const char *msg = "wrong number of arguments";
  return mk_error_ctx(env, "link", "argument_arity", msg, strlen(msg), ctx);
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

/* Wasmtime's traps under erlang_wasm's classes and kinds. `text` is how
 * Wasmtime words the trap after "wasm trap: ", which is all an error (a
 * component's trap) carries; `msg` is the specification's wording. */
typedef struct {
  int code;
  const char *text, *cls, *kind, *msg;
} trap_row_t;

/* Formatters of different releases disagree on a braced macro body. */
/* clang-format off */
#define T(code, text, kind, msg) {code, text, "trap", kind, msg}
#define X(code, text, kind, msg) {code, text, "exhaustion", kind, msg}
/* clang-format on */
static const trap_row_t trap_rows[] = {
    X(0, "call stack exhausted", "call_stack_exhausted", "call stack exhausted"),
    T(1, "out of bounds memory access", "out_of_bounds_memory_access",
      "out of bounds memory access"),
    T(2, "unaligned atomic", "unaligned_atomic", "unaligned atomic"),
    T(3, "undefined element: out of bounds table access", "out_of_bounds_table_access",
      "out of bounds table access"),
    T(4, "uninitialized element", "uninitialized_element", "uninitialized element"),
    T(5, "indirect call type mismatch", "indirect_call_type_mismatch",
      "indirect call type mismatch"),
    T(6, "integer overflow", "integer_overflow", "integer overflow"),
    T(7, "integer divide by zero", "integer_divide_by_zero", "integer divide by zero"),
    T(8, "invalid conversion to integer", "invalid_conversion_to_integer",
      "invalid conversion to integer"),
    T(9, "wasm `unreachable` instruction executed", "unreachable", "unreachable"),
    T(10, "interrupt", "interrupt", "interrupted"),
    X(11, "all fuel consumed by WebAssembly", "out_of_fuel", "out of fuel"),
    T(12, "atomic wait on non-shared memory", "expected_shared_memory", "expected shared memory"),
    T(13, "null reference", "null_reference", "null reference"),
    T(14, "out of bounds array access", "out_of_bounds_array_access", "out of bounds array access"),
    T(15, "allocation size too large", "array_too_large", "array too large"),
    T(16, "cast failure", "cast_failure", "cast failure"),
    T(17, "cannot enter component instance", "cannot_enter_component",
      "cannot enter component instance"),
    T(18, "async-lifted export failed to produce a result", "no_async_result",
      "no result from an async export"),
    T(19, "unhandled tag", "uncaught_exception", "uncaught exception"),
    T(22, "deadlock detected", "async_deadlock", "deadlock detected"),
    T(49, "uncaught exception", "uncaught_exception", "uncaught exception"),
    X(55, "hostcall fuel", "hostcall_fuel", "too much data copied between host and guest"),
};
#undef T
#undef X
#define NTRAPS (sizeof trap_rows / sizeof *trap_rows)

static int contains(const char *msg, size_t len, const char *needle) {
  size_t n = strlen(needle);
  for (size_t i = 0; i + n <= len; i++)
    if (memcmp(msg + i, needle, n) == 0) return 1;
  return 0;
}

static const trap_row_t *trap_by_text(const char *msg, size_t len) {
  for (size_t i = 0; i < NTRAPS; i++) {
    char needle[96];
    snprintf(needle, sizeof needle, "wasm trap: %s", trap_rows[i].text);
    if (contains(msg, len, needle)) return &trap_rows[i];
  }
  return NULL;
}

/* A trap's error: Wasmtime's own wording in ctx.detail, the frames in
 * ctx.trace. `row` NULL is a trap without a kind of its own. */
static ERL_NIF_TERM mk_trap(ErlNifEnv *env, const trap_row_t *row, const char *detail, size_t len,
                            ERL_NIF_TERM trace) {
  ERL_NIF_TERM ctx = ctx_put(env, enif_make_new_map(env), atom_detail, mk_binary(env, detail, len));
  if (trace) ctx = ctx_put(env, ctx, atom_trace, trace);
  if (row) return mk_error_ctx(env, row->cls, row->kind, row->msg, strlen(row->msg), ctx);
  /* a trap of ours, or one without a kind: its own words say what happened */
  return mk_error_ctx(env, "trap", "trap", detail, len, ctx);
}

/* Consumes `trap`. */
ERL_NIF_TERM trap_to_term(ErlNifEnv *env, wasm_trap_t *trap) {
  wasm_message_t msg;
  wasm_trap_message(trap, &msg);
  wasmtime_trap_code_t code;
  /* Wasmtime NUL-terminates trap messages; drop the terminator. */
  size_t len = msg.size && msg.data[msg.size - 1] == 0 ? msg.size - 1 : msg.size;
  wasm_frame_vec_t frames;
  wasm_trap_trace(trap, &frames);
  ERL_NIF_TERM trace = frames_term(env, &frames);
  const trap_row_t *row = NULL;
  if (wasmtime_trap_code(trap, &code))
    for (size_t i = 0; i < NTRAPS && !row; i++)
      if (trap_rows[i].code == (int)code) row = &trap_rows[i];
  ERL_NIF_TERM t = mk_trap(env, row, msg.data, len, trace);
  wasm_byte_vec_delete(&msg);
  wasm_trap_delete(trap);
  return t;
}

static ERL_NIF_TERM detail_ctx(ErlNifEnv *env, const char *detail, size_t len) {
  return ctx_put(env, enif_make_new_map(env), atom_detail, mk_binary(env, detail, len));
}

/* How a module or component that does not load is worded, to erlang_wasm's
 * malformed (the bytes do not decode) and invalid (they do not validate). */
static ERL_NIF_TERM compile_error(ErlNifEnv *env, const char *detail, size_t len) {
  static const struct {
    const char *text, *cls, *kind;
  } rows[] = {
      {"magic header not detected", "malformed", "magic_header_not_detected"},
      {"unknown binary version", "malformed", "unknown_binary_version"},
      {"unexpected end", "malformed", "unexpected_end"},
      {"unexpected end-of-file", "malformed", "unexpected_end"},
      {"section size mismatch", "malformed", "section_size_mismatch"},
      {"section out of order", "malformed", "section_out_of_order"},
      {"malformed UTF-8", "malformed", "malformed_utf8"},
      {"invalid leb128", "malformed", "malformed_integer"},
      {"invalid var_", "malformed", "malformed_integer"},
      {"malformed", "malformed", "malformed_module"},
      {"type mismatch", "invalid", "type_mismatch"},
      {"unknown local", "invalid", "unknown_local"},
      {"unknown global", "invalid", "unknown_global"},
      {"unknown function", "invalid", "unknown_func"},
      {"unknown type", "invalid", "unknown_type"},
      {"unknown table", "invalid", "unknown_table"},
      {"unknown memory", "invalid", "unknown_memory"},
  };
  const char *cls = "invalid", *kind = "invalid_module";
  for (size_t i = 0; i < sizeof rows / sizeof *rows; i++)
    if (contains(detail, len, rows[i].text)) {
      cls = rows[i].cls;
      kind = rows[i].kind;
      break;
    }
  const char *msg =
      strcmp(cls, "invalid") ? "the module cannot be decoded" : "the module does not validate";
  return mk_error_ctx(env, cls, kind, msg, strlen(msg), detail_ctx(env, detail, len));
}

/* Wasmtime errors whose wording says what happened, whatever was asked. */
static const struct {
  const char *text, *cls, *kind, *msg;
} common_rows[] = {
    {"does not fit in pooling allocator requirements", "exhaustion", "pool_limit",
     "the module does not fit the pool"},
    {"failed to grow table", "exhaustion", "table_limit", "table limit exceeded"},
    {"index out of bounds: the length is", "trap", "out_of_bounds_array_access",
     "out of bounds array access"},
    {"struct only has", "link", "out_of_bounds", "no such field"},
    {"failed to open file", "link", "file_error", "cannot read module file"},
};

/* "unknown import: `module::name` has not been defined" puts the two names
 * in ctx; a component's has an interface path instead, kept as the name. */
static ERL_NIF_TERM import_ctx(ErlNifEnv *env, ERL_NIF_TERM ctx, const char *detail, size_t len) {
  const char *open = memchr(detail, '`', len);
  if (!open) return ctx;
  const char *from = open + 1, *end = detail + len;
  const char *close = memchr(from, '`', (size_t)(end - from));
  if (!close) return ctx;
  for (const char *p = from; p + 1 < close; p++)
    if (p[0] == ':' && p[1] == ':') {
      ctx = ctx_put(env, ctx, atom_module, mk_binary(env, from, (size_t)(p - from)));
      return ctx_put(env, ctx, atom_name, mk_binary(env, p + 2, (size_t)(close - p - 2)));
    }
  return ctx_put(env, ctx, atom_name, mk_binary(env, from, (size_t)(close - from)));
}

/* Why instantiation failed. */
static ERL_NIF_TERM link_error(ErlNifEnv *env, const char *detail, size_t len) {
  static const struct {
    const char *text, *cls, *kind, *msg;
  } rows[] = {
      {"unknown import", "link", "unknown_import", "unknown import"},
      {"matching implementation was not found", "link", "unknown_import", "unknown import"},
      {"incompatible import type", "link", "incompatible_import_type", "incompatible import type"},
      {"exceeds memory limits", "exhaustion", "memory_limit", "memory limit exceeded"},
      {"exceeds table limits", "exhaustion", "table_limit", "table limit exceeded"},
      {"resource limit exceeded", "exhaustion", "instance_limit", "instance limit exceeded"},
  };
  ERL_NIF_TERM ctx = detail_ctx(env, detail, len);
  for (size_t i = 0; i < sizeof rows / sizeof *rows; i++)
    if (contains(detail, len, rows[i].text)) {
      if (strcmp(rows[i].kind, "unknown_import") == 0) ctx = import_ctx(env, ctx, detail, len);
      return mk_error_ctx(env, rows[i].cls, rows[i].kind, rows[i].msg, strlen(rows[i].msg), ctx);
    }
  return mk_error_ctx(env, "link", "link", detail, len, ctx);
}

/* WASI's proc_exit, as erlang_wasm reports it: a host function that trapped,
 * with the status in ctx. Status 0 too. */
static ERL_NIF_TERM exit_error(ErlNifEnv *env, int status) {
  ERL_NIF_TERM code = enif_make_int(env, status);
  ERL_NIF_TERM ctx = ctx_put(env, enif_make_new_map(env), atom_wasi_exit, code);
  ctx = ctx_put(env, ctx, atom_reason, enif_make_tuple2(env, atom_wasi_exit, code));
  return mk_error_ctx(env, "trap", "host_error", "host error", 10, ctx);
}

/* Consumes `err`. `hint` is "compile", "wat" (the text format), "link"
 * (instantiation), or else the kind of a `link` error that is neither an
 * exit nor a trap. */
ERL_NIF_TERM error_to_term(ErlNifEnv *env, wasmtime_error_t *err, const char *hint) {
  int status;
  ERL_NIF_TERM t;
  if (wasmtime_error_exit_status(err, &status)) {
    t = exit_error(env, status);
  } else {
    wasm_name_t msg;
    wasmtime_error_message(err, &msg);
    wasm_frame_vec_t frames;
    wasmtime_error_wasm_trace(err, &frames);
    ERL_NIF_TERM trace = frames_term(env, &frames);
    const trap_row_t *row = trap_by_text(msg.data, msg.size);
    size_t common = 0, ncommon = sizeof common_rows / sizeof *common_rows;
    while (common < ncommon && !contains(msg.data, msg.size, common_rows[common].text)) common++;
    /* an error carrying wasm frames is a trap that Wasmtime wrapped */
    if (row || trace)
      t = mk_trap(env, row, msg.data, msg.size, trace);
    else if (common < ncommon)
      t = mk_error_ctx(env, common_rows[common].cls, common_rows[common].kind,
                       common_rows[common].msg, strlen(common_rows[common].msg),
                       detail_ctx(env, msg.data, msg.size));
    else if (strcmp(hint, "wat") == 0)
      t = mk_error_ctx(env, "malformed", "syntax_error", "the text cannot be parsed", 25,
                       detail_ctx(env, msg.data, msg.size));
    else if (strcmp(hint, "compile") == 0)
      t = compile_error(env, msg.data, msg.size);
    else if (strcmp(hint, "link") == 0)
      t = link_error(env, msg.data, msg.size);
    else
      t = mk_error(env, "link", hint, msg.data, msg.size);
    wasm_byte_vec_delete(&msg);
  }
  wasmtime_error_delete(err);
  return t;
}
