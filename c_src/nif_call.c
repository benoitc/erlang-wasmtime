/*
 * nif_call.c: Calling a guest function on the worker thread: the raw path for
 * numbers and v128, the typed path when references are involved.
 */
#include "nif.h"

/* Numbers and v128 cross through the raw API: the typed one aborts on v128. */
static ERL_NIF_TERM call_raw(instance_t *inst, req_t *req, ErlNifEnv *out, wasmtime_func_t *func,
                             const wasm_valtype_vec_t *ps, const wasm_valtype_vec_t *rs) {
  ErlNifEnv *env = req->env;
  wasmtime_val_raw_t vals[MAX_VALS];
  ERL_NIF_TERM l = req->args, h;
  for (size_t i = 0; enif_get_list_cell(env, l, &h, &l); i++)
    if (!term_to_raw(env, h, kind_of(ps->data[i]), &vals[i]))
      return mk_error_s(out, "call", "badarg", "argument does not match the parameter type");
  wasm_trap_t *trap = NULL;
  size_t nvals = ps->size > rs->size ? ps->size : rs->size;
  wasmtime_error_t *e = wasmtime_func_call_unchecked(inst->wasm.ctx, func, vals, nvals, &trap);
  ERL_NIF_TERM result = outcome(inst, out, e, trap, "call");
  if (!enif_is_identical(result, atom_ok)) return result;
  ERL_NIF_TERM list = enif_make_list(out, 0);
  for (size_t i = rs->size; i > 0; i--)
    list = enif_make_list_cell(out, raw_to_term(out, kind_of(rs->data[i - 1]), &vals[i - 1]), list);
  return enif_make_tuple2(out, atom_ok, list);
}

/* References cross through the typed API: Wasmtime checks the arguments
 * (including subtyping of concrete types) and roots the results. */
static ERL_NIF_TERM call_typed(instance_t *inst, req_t *req, ErlNifEnv *out, wasmtime_func_t *func,
                               const wasm_valtype_vec_t *ps, const wasm_valtype_vec_t *rs) {
  ErlNifEnv *env = req->env;
  wasmtime_val_t args[MAX_VALS], results[MAX_VALS];
  ERL_NIF_TERM l = req->args, h;
  size_t nargs = 0;
  for (; enif_get_list_cell(env, l, &h, &l); nargs++) {
    vtype_t t;
    vtype_of(ps->data[nargs], &t);
    const char *kind = term_to_val(env, inst, h, &t, &args[nargs]);
    if (kind) {
      unroot_vals(args, nargs);
      return conv_error(out, "call", kind);
    }
  }
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e =
      wasmtime_func_call(inst->wasm.ctx, func, args, nargs, results, rs->size, &trap);
  unroot_vals(args, nargs);
  ERL_NIF_TERM result = outcome(inst, out, e, trap, "call");
  if (!enif_is_identical(result, atom_ok)) return result;
  ERL_NIF_TERM list = enif_make_list(out, 0);
  int bad = 0;
  for (size_t i = rs->size; i > 0; i--) {
    ERL_NIF_TERM t = val_to_term(out, inst, &results[i - 1]);
    if (!t) bad = 1;
    list = enif_make_list_cell(out, t ? t : atom_undefined, list);
  }
  if (bad) return mk_error_s(out, "call", "unsupported_type", "a result cannot cross the boundary");
  return enif_make_tuple2(out, atom_ok, list);
}

ERL_NIF_TERM do_call(instance_t *inst, req_t *req, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  ErlNifBinary name;
  wasmtime_func_t func;
  ref_t *r;
  if (enif_get_resource(env, req->name, ref_type, (void **)&r)) {
    /* call_ref: a funcref this instance handed out */
    if (r->inst != inst) return conv_error(out, "call", "wrong_instance");
    if (r->kind != REF_FUNC) return mk_error_s(out, "call", "badarg", "not a funcref");
    func = r->of.func;
  } else {
    if (!enif_inspect_iolist_as_binary(env, req->name, &name))
      return mk_error_s(out, "call", "badarg", "export name must be a binary");
    wasmtime_extern_t ext;
    if (!wasmtime_instance_export_get(inst->wasm.ctx, &inst->wasm.instance, (const char *)name.data,
                                      name.size, &ext))
      return mk_error(out, "call", "no_such_export", (const char *)name.data, name.size);
    if (ext.kind != WASMTIME_EXTERN_FUNC)
      return mk_error(out, "call", "not_a_function", (const char *)name.data, name.size);
    func = ext.of.func;
  }

  wasm_functype_t *ft = wasmtime_func_type(inst->wasm.ctx, &func);
  const wasm_valtype_vec_t *ps = wasm_functype_params(ft), *rs = wasm_functype_results(ft);
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
  shape_t sh = shape_of(ft);
  if (sh.exn || (sh.refs && sh.v128)) {
    result = mk_error_s(out, "call", "unsupported_type",
                        sh.exn ? "exception references cannot cross the boundary"
                               : "v128 and references cannot mix in one signature");
    goto done;
  }
  ErlNifUInt64 fuel;
  if (enif_get_uint64(env, req->opts, &fuel)) {
    wasmtime_error_t *fe = wasmtime_context_set_fuel(inst->wasm.ctx, fuel);
    if (fe) {
      wasmtime_error_delete(fe);
      result =
          mk_error_s(out, "call", "fuel_disabled",
                     "the module was not compiled with fuel metering: compile with fuel => true");
      goto done;
    }
  }
  wasmtime_context_set_epoch_deadline(inst->wasm.ctx, 1);
  result =
      sh.refs ? call_typed(inst, req, out, &func, ps, rs) : call_raw(inst, req, out, &func, ps, rs);
done:
  wasm_functype_delete(ft);
  return result;
}
