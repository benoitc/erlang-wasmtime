/*
 * nif_atoms.c: Atoms and error terms: the one place that builds
 * {error, #{class, kind, message[, trace]}} and turns Wasmtime errors and
 * traps into it.
 */
#include "nif.h"

ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false, atom_compiler, atom_wat, atom_wasi,
    atom_none, atom_capture, atom_binary, atom_trace, atom_func_index, atom_func_offset,
    atom_func_name, atom_module_name, atom_immutable, atom_undefined, atom_inherit, atom_file,
    atom_read, atom_write, atom_nan, atom_infinity, atom_neg_infinity, atom_class, atom_kind,
    atom_message, atom_status, atom_not_running, atom_func, atom_global, atom_table, atom_memory,
    atom_tag, atom_wasmtime_result, atom_wasmtime_host_call, atom_no_pending_host_call,
    atom_enqueued, atom_stream, atom_wasmtime_stream, atom_stdout, atom_stderr, atom_channel,
    atom_null, atom_i31, atom_externref, atom_funcref, atom_struct, atom_array, atom_anyref,
    atom_instance;

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

/* {error, #{class => Class, kind => Kind, message => Msg[, trace => Frames]}} */
static ERL_NIF_TERM mk_error_trace(ErlNifEnv *env, const char *cls, const char *kind,
                                   const char *msg, size_t len, ERL_NIF_TERM trace) {
  ERL_NIF_TERM keys[4] = {atom_class, atom_kind, atom_message, atom_trace};
  ERL_NIF_TERM vals[4] = {mk_atom(env, cls), mk_atom(env, kind), mk_binary(env, msg, len), trace};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, trace ? 4 : 3, &map);
  return enif_make_tuple2(env, atom_error, map);
}

ERL_NIF_TERM mk_error(ErlNifEnv *env, const char *cls, const char *kind, const char *msg,
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

ERL_NIF_TERM mk_error_s(ErlNifEnv *env, const char *cls, const char *kind, const char *msg) {
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
ERL_NIF_TERM trap_to_term(ErlNifEnv *env, wasm_trap_t *trap) {
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
ERL_NIF_TERM error_to_term(ErlNifEnv *env, wasmtime_error_t *err, const char *cls) {
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
