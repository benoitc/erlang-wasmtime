/*
 * nif_component.c: Components: the linker for one component and import
 * shape (WASI 0.2, the clocks override, Erlang host functions), instantiate
 * and call on the worker thread, host functions served through the same
 * exchange as core imports, and imports/exports for component types.
 * Values cross in nif_cvalues.c.
 */
#include "nif.h"

#ifdef WASMTIME_FEATURE_COMPONENT_MODEL

/* The WASI 0.2 wall clock Wasmtime defines, which `clocks => monotonic`
 * replaces. Tied to the Wasmtime version: a bump must check it
 * (RELEASING.md, "Bump Wasmtime"); wasi_clocks_component in the tests
 * fails if the name no longer shadows Wasmtime's. */
#define WALL_CLOCK "wasi:clocks/wall-clock@0.2.12"

static wasmtime_error_t *wall_clock_refused(void *envp, wasmtime_context_t *ctx,
                                            const wasmtime_component_func_type_t *ty,
                                            wasmtime_component_val_t *args, size_t nargs,
                                            wasmtime_component_val_t *results, size_t nresults) {
  (void)envp, (void)ty, (void)args, (void)nargs, (void)results, (void)nresults;
  /* `now` returns a datetime and has no error case: a trap, reported as
   * kind => clock_refused (outcome) */
  instance_t *inst = wasmtime_context_get_data(ctx);
  inst->clock_refused = 1;
  return wasmtime_error_new("clock_refused: wasi:clocks/wall-clock (clocks => monotonic)");
}

static wasmtime_error_t *refuse_wall_clock(wasmtime_component_linker_t *l) {
  wasmtime_component_linker_allow_shadowing(l, true);
  wasmtime_component_linker_instance_t *root = wasmtime_component_linker_root(l), *wc = NULL;
  wasmtime_error_t *e =
      wasmtime_component_linker_instance_add_instance(root, WALL_CLOCK, strlen(WALL_CLOCK), &wc);
  if (!e)
    e = wasmtime_component_linker_instance_add_func(wc, "now", 3, wall_clock_refused, NULL, NULL);
  if (!e)
    e = wasmtime_component_linker_instance_add_func(wc, "resolution", 10, wall_clock_refused, NULL,
                                                    NULL);
  if (wc) wasmtime_component_linker_instance_delete(wc);
  wasmtime_component_linker_instance_delete(root);
  wasmtime_component_linker_allow_shadowing(l, false);
  return e;
}

/* The key in `imports` (a list of {Module, Name}) matching an import:
 * Module is the interface with or without its version, "" for a function
 * the component imports at its root. Copies the key's own strings. */
static int match_key(ErlNifEnv *env, ERL_NIF_TERM imports, const char *iface, size_t ilen,
                     const char *fname, size_t flen, char **module, char **name) {
  size_t base = ilen;
  for (size_t i = 0; i < ilen; i++)
    if (iface[i] == '@') {
      base = i;
      break;
    }
  ERL_NIF_TERM h, l = imports;
  while (enif_get_list_cell(env, l, &h, &l)) {
    const ERL_NIF_TERM *mn;
    int ar;
    ErlNifBinary m, n;
    if (!enif_get_tuple(env, h, &ar, &mn) || ar != 2 ||
        !enif_inspect_iolist_as_binary(env, mn[0], &m) ||
        !enif_inspect_iolist_as_binary(env, mn[1], &n))
      continue;
    if (n.size != flen || memcmp(n.data, fname, flen) != 0) continue;
    if (!((m.size == ilen && memcmp(m.data, iface, ilen) == 0) ||
          (m.size == base && memcmp(m.data, iface, base) == 0)))
      continue;
    *module = enif_alloc(m.size + 1);
    memcpy(*module, m.data, m.size);
    (*module)[m.size] = 0;
    *name = enif_alloc(n.size + 1);
    memcpy(*name, n.data, n.size);
    (*name)[n.size] = 0;
    return 1;
  }
  return 0;
}

static wasmtime_error_t *add_host_func(linker_entry_t *le, wasmtime_component_linker_instance_t *li,
                                       const char *fname, size_t flen, char *module, char *name) {
  size_t idx = le->nhostfns++;
  hostfn_t *fn = &le->hostfns[idx];
  fn->module = module;
  fn->name = name;
  fn->type = NULL; /* the callback gets the component function type itself */
  return wasmtime_component_linker_instance_add_func(li, fname, flen, component_host_callback,
                                                     (void *)(uintptr_t)idx, NULL);
}

/* Binds every import the component declares and `imports` provides. */
static ERL_NIF_TERM bind_component_imports(linker_entry_t *le, module_res_t *m, ErlNifEnv *env,
                                           ERL_NIF_TERM imports, ErlNifEnv *out) {
  unsigned nkeys;
  if (!enif_get_list_length(env, imports, &nkeys))
    return mk_error_s(out, "link", "badarg", "imports must be a list");
  le->hostfns = enif_alloc(sizeof(hostfn_t) * (nkeys + 1));
  memset(le->hostfns, 0, sizeof(hostfn_t) * (nkeys + 1));
  if (nkeys == 0) return 0;
  wasm_engine_t *engine = m->engine->engine;
  wasmtime_component_type_t *ct = wasmtime_component_type(m->comp);
  size_t n = wasmtime_component_type_import_count(ct, engine);
  wasmtime_error_t *e = NULL;
  for (size_t i = 0; i < n && !e && le->nhostfns < nkeys; i++) {
    const char *iname;
    size_t ilen;
    wasmtime_component_item_t item;
    if (!wasmtime_component_type_import_nth(ct, engine, i, &iname, &ilen, &item)) continue;
    char *module, *name;
    if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
      if (match_key(env, imports, "", 0, iname, ilen, &module, &name)) {
        wasmtime_component_linker_instance_t *root = wasmtime_component_linker_root(le->clinker);
        e = add_host_func(le, root, iname, ilen, module, name);
        wasmtime_component_linker_instance_delete(root);
      }
    } else if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
      const wasmtime_component_instance_type_t *it = item.of.component_instance;
      size_t nf = wasmtime_component_instance_type_export_count(it, engine);
      wasmtime_component_linker_instance_t *root = NULL, *li = NULL;
      for (size_t j = 0; j < nf && !e; j++) {
        const char *fname;
        size_t flen;
        wasmtime_component_item_t fitem;
        if (!wasmtime_component_instance_type_export_nth(it, engine, j, &fname, &flen, &fitem))
          continue;
        if (fitem.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC &&
            match_key(env, imports, iname, ilen, fname, flen, &module, &name)) {
          if (!li) {
            root = wasmtime_component_linker_root(le->clinker);
            e = wasmtime_component_linker_instance_add_instance(root, iname, ilen, &li);
          }
          if (!e) {
            e = add_host_func(le, li, fname, flen, module, name);
          } else {
            enif_free(module);
            enif_free(name);
          }
        }
        wasmtime_component_item_delete(&fitem);
      }
      if (li) wasmtime_component_linker_instance_delete(li);
      if (root) wasmtime_component_linker_instance_delete(root);
    }
    wasmtime_component_item_delete(&item);
  }
  wasmtime_component_type_delete(ct);
  return e ? error_to_term(out, e, "link") : 0;
}

static linker_entry_t *build_centry(module_res_t *m, ErlNifEnv *env, ERL_NIF_TERM key,
                                    ERL_NIF_TERM imports, int wasi, int monotonic, ErlNifEnv *out,
                                    ERL_NIF_TERM *err) {
  linker_entry_t *le = enif_alloc(sizeof *le);
  memset(le, 0, sizeof *le);
  le->key_env = enif_alloc_env();
  le->key = enif_make_copy(le->key_env, key);
  le->clinker = wasmtime_component_linker_new(m->engine->engine);
  wasmtime_error_t *e = NULL;
  *err = 0;
  if (wasi) {
#if NIF_HAVE_WASI
    e = wasmtime_component_linker_add_wasip2(le->clinker);
    if (!e && monotonic) e = refuse_wall_clock(le->clinker);
    if (e) *err = error_to_term(out, e, "wasi");
#else
    (void)monotonic;
    *err = mk_error_s(out, "wasi", "unavailable", "this build of erlang_wasmtime has no WASI");
#endif
  }
  if (!*err) *err = bind_component_imports(le, m, env, imports, out);
  if (*err) {
    linker_entry_free(le);
    return NULL;
  }
  return le;
}

#define MAX_LINKERS 16

/* The same cache as core modules (nif_instantiate.c, link_entry); the key
 * starts with `component` so the two never meet. */
ERL_NIF_TERM component_instantiate(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM imports, int wasi,
                                   int monotonic, ErlNifEnv *out) {
  module_res_t *m = inst->wasm.mod;
  ERL_NIF_TERM key =
      enif_make_tuple4(env, mk_atom(env, "component"), imports, wasi ? atom_true : atom_false,
                       monotonic ? atom_true : atom_false);
  ERL_NIF_TERM err = 0;
  pthread_mutex_lock(&m->mu);
  linker_entry_t *le = m->linkers;
  while (le && !enif_is_identical(le->key, key)) le = le->next;
  if (!le) {
    le = build_centry(m, env, key, imports, wasi, monotonic, out, &err);
    if (le && m->nlinkers < MAX_LINKERS) {
      le->next = m->linkers;
      m->linkers = le;
      m->nlinkers++;
    } else if (le) {
      inst->wasm.owns_entry = 1;
    }
  }
  pthread_mutex_unlock(&m->mu);
  inst->wasm.entry = le;
  if (err) return err;
  wasmtime_error_t *e = wasmtime_component_linker_instantiate(le->clinker, inst->wasm.ctx, m->comp,
                                                              &inst->wasm.cinst);
  ERL_NIF_TERM r = outcome(inst, out, e, NULL, "link");
  return enif_is_identical(r, atom_ok) ? 0 : r;
}

/* ------------------------------------------------------------- calls */

/* `Export` is erlang_wasm's name: "func" at the root, "iface#func" inside
 * an exported interface. The interface may be given without its version
 * when the component exports only one. */
static wasmtime_component_export_index_t *find_export(instance_t *inst, const char *name,
                                                      size_t len) {
  const wasmtime_component_t *c = inst->wasm.mod->comp;
  const char *hash = memchr(name, '#', len);
  if (!hash) return wasmtime_component_get_export_index(c, NULL, name, len);
  size_t ilen = (size_t)(hash - name);
  wasmtime_component_export_index_t *parent =
      wasmtime_component_get_export_index(c, NULL, name, ilen);
  if (!parent && !memchr(name, '@', ilen)) {
    /* unversioned: the one export named "iface@..." */
    wasm_engine_t *engine = inst->wasm.mod->engine->engine;
    wasmtime_component_type_t *ct = wasmtime_component_type(c);
    size_t n = wasmtime_component_type_export_count(ct, engine);
    for (size_t i = 0; i < n && !parent; i++) {
      const char *en;
      size_t el;
      wasmtime_component_item_t item;
      if (!wasmtime_component_type_export_nth(ct, engine, i, &en, &el, &item)) continue;
      if (el > ilen && memcmp(en, name, ilen) == 0 && en[ilen] == '@')
        parent = wasmtime_component_get_export_index(c, NULL, en, el);
      wasmtime_component_item_delete(&item);
    }
    wasmtime_component_type_delete(ct);
  }
  if (!parent) return NULL;
  wasmtime_component_export_index_t *idx =
      wasmtime_component_get_export_index(c, parent, hash + 1, len - ilen - 1);
  wasmtime_component_export_index_delete(parent);
  return idx;
}

/* {drop, Handle}: the guest's destructor runs here, on the worker, since it
 * is guest code; the handle is gone afterwards. */
static ERL_NIF_TERM drop_resource(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM h,
                                  ErlNifEnv *out) {
  unsigned i;
  if (!enif_get_uint(env, h, &i) || i == 0 || i > inst->wasm.nres || !inst->wasm.res[i - 1])
    return mk_error_s(out, "call", "badarg", "not a live resource handle of this instance");
  wasmtime_component_resource_any_t *r = inst->wasm.res[i - 1];
  wasmtime_context_set_epoch_deadline(inst->wasm.ctx, 1);
  wasmtime_error_t *e = wasmtime_component_resource_any_drop(inst->wasm.ctx, r);
  /* the slot is freed under the mutex: a scheduler may read the table */
  pthread_mutex_lock(&inst->mu);
  inst->wasm.res[i - 1] = NULL;
  pthread_mutex_unlock(&inst->mu);
  wasmtime_component_resource_any_delete(r);
  ERL_NIF_TERM result = outcome(inst, out, e, NULL, "call");
  return enif_is_identical(result, atom_ok) ? enif_make_tuple2(out, atom_ok, atom_undefined)
                                            : result;
}

/* {ok, Value}: `undefined` for a function without result, as erlang_wasm. */
ERL_NIF_TERM component_call(instance_t *inst, req_t *req, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  ErlNifBinary name;
  const ERL_NIF_TERM *dt;
  int dar;
  if (enif_get_tuple(env, req->name, &dar, &dt) && dar == 2 &&
      enif_is_identical(dt[0], mk_atom(env, "drop")))
    return drop_resource(inst, env, dt[1], out);
  if (!enif_inspect_iolist_as_binary(env, req->name, &name))
    return mk_error_s(out, "call", "badarg", "export name must be a binary");
  wasmtime_component_export_index_t *idx = find_export(inst, (const char *)name.data, name.size);
  wasmtime_component_func_t func;
  int found =
      idx && wasmtime_component_instance_get_func(&inst->wasm.cinst, inst->wasm.ctx, idx, &func);
  if (idx) wasmtime_component_export_index_delete(idx);
  if (!found) return mk_error(out, "call", "no_such_export", (const char *)name.data, name.size);

  wasmtime_component_func_type_t *ft = wasmtime_component_func_type(&func, inst->wasm.ctx);
  size_t np = wasmtime_component_func_type_param_count(ft);
  wasmtime_component_valtype_t rt;
  int has_result = wasmtime_component_func_type_result(ft, &rt);
  unsigned nargs;
  ERL_NIF_TERM result = 0;
  wasmtime_component_val_t *args = NULL;
  size_t built = 0;
  if (!enif_get_list_length(env, req->args, &nargs) || nargs != np) {
    result = mk_error_s(out, "call", "badarity", "wrong number of arguments");
    goto done;
  }
  args = enif_alloc((np ? np : 1) * sizeof *args);
  ERL_NIF_TERM h, l = req->args;
  for (; built < np && enif_get_list_cell(env, l, &h, &l); built++) {
    const char *pn;
    size_t pl;
    wasmtime_component_valtype_t pt;
    wasmtime_component_func_type_param_nth(ft, built, &pn, &pl, &pt);
    const char *why = term_to_cval(env, inst, h, &pt, &args[built]);
    wasmtime_component_valtype_delete(&pt);
    if (why) {
      built++;
      result = mk_error_s(out, "call", "badarg", why);
      goto done;
    }
  }
  ErlNifUInt64 fuel;
  if (enif_get_uint64(env, req->opts, &fuel)) {
    wasmtime_error_t *fe = wasmtime_context_set_fuel(inst->wasm.ctx, fuel);
    if (fe) {
      wasmtime_error_delete(fe);
      result = mk_error_s(out, "call", "fuel_disabled",
                          "the component was not compiled with fuel metering");
      goto done;
    }
  }
  wasmtime_context_set_epoch_deadline(inst->wasm.ctx, 1);
  wasmtime_component_val_t res;
  memset(&res, 0, sizeof res);
  res.kind = WASMTIME_COMPONENT_BOOL;
  wasmtime_error_t *e =
      wasmtime_component_func_call(&func, inst->wasm.ctx, args, np, &res, has_result ? 1 : 0);
  result = outcome(inst, out, e, NULL, "call");
  const ERL_NIF_TERM *rt2;
  int rar;
  if (enif_get_tuple(out, result, &rar, &rt2) && rar == 2 && enif_is_identical(rt2[0], atom_ok)) {
    /* the guest called exit(0): the program ended normally, no result */
    result = enif_make_tuple2(out, atom_ok, atom_undefined);
  } else if (enif_is_identical(result, atom_ok)) {
    ERL_NIF_TERM v = has_result ? cval_to_term(out, inst, &res, &rt) : atom_undefined;
    e = wasmtime_component_func_post_return(&func, inst->wasm.ctx);
    result = e ? outcome(inst, out, e, NULL, "call") : enif_make_tuple2(out, atom_ok, v);
  }
  if (has_result) wasmtime_component_val_delete(&res);
done:
  for (size_t i = 0; i < built; i++) wasmtime_component_val_delete(&args[i]);
  enif_free(args);
  if (has_result) wasmtime_component_valtype_delete(&rt);
  wasmtime_component_func_type_delete(ft);
  return result;
}

/* Runs on the instance thread inside a component call: the same exchange
 * as a core import, with WIT values. The Erlang side answers {ok, Value}. */
wasmtime_error_t *component_host_callback(void *envp, wasmtime_context_t *ctx,
                                          const wasmtime_component_func_type_t *ty,
                                          wasmtime_component_val_t *args, size_t nargs,
                                          wasmtime_component_val_t *results, size_t nresults) {
  instance_t *inst = wasmtime_context_get_data(ctx);
  hostfn_t *fn = &inst->wasm.entry->hostfns[(uintptr_t)envp];
  const char *fail = NULL;
  ErlNifEnv *menv = enif_alloc_env();
  ERL_NIF_TERM list = enif_make_list(menv, 0);
  for (size_t i = nargs; i > 0; i--) {
    const char *pn;
    size_t pl;
    wasmtime_component_valtype_t pt;
    int has = wasmtime_component_func_type_param_nth(ty, i - 1, &pn, &pl, &pt);
    list =
        enif_make_list_cell(menv, cval_to_term(menv, inst, &args[i - 1], has ? &pt : NULL), list);
    if (has) wasmtime_component_valtype_delete(&pt);
  }
  ERL_NIF_TERM value;
  enum host_status st = host_exchange(inst, fn, menv, list, &value, &fail);
  if (st == HOST_OK && nresults == 1) {
    wasmtime_component_valtype_t rt;
    if (wasmtime_component_func_type_result(ty, &rt)) {
      fail = term_to_cval(inst->host.reply_env, inst, value, &rt, &results[0]);
      wasmtime_component_valtype_delete(&rt);
    }
  }
  pthread_mutex_unlock(&inst->mu);
  wasm_trap_t *trap = host_outcome(inst, st, fail);
  if (!trap) return NULL;
  wasm_message_t msg;
  wasm_trap_message(trap, &msg);
  wasmtime_error_t *e = wasmtime_error_new(msg.size ? msg.data : "host error");
  wasm_byte_vec_delete(&msg);
  wasm_trap_delete(trap);
  return e;
}

/* --------------------------------------------------- imports, exports */

/* [{Name, func | instance | module | resource | type | component}], with
 * each function of an interface listed again as "iface#func", the name
 * call/3 takes. */
static ERL_NIF_TERM item_kind(ErlNifEnv *env, wasmtime_component_item_kind_t k) {
  switch (k) {
  case WASMTIME_COMPONENT_ITEM_COMPONENT: return mk_atom(env, "component");
  case WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE: return mk_atom(env, "instance");
  case WASMTIME_COMPONENT_ITEM_MODULE: return mk_atom(env, "module");
  case WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC: return atom_func;
  case WASMTIME_COMPONENT_ITEM_RESOURCE: return mk_atom(env, "resource");
  case WASMTIME_COMPONENT_ITEM_CORE_FUNC: return mk_atom(env, "core_func");
  default: return mk_atom(env, "type");
  }
}

ERL_NIF_TERM component_items(ErlNifEnv *env, module_res_t *m, int exports) {
  wasm_engine_t *engine = m->engine->engine;
  wasmtime_component_type_t *ct = wasmtime_component_type(m->comp);
  size_t n = exports ? wasmtime_component_type_export_count(ct, engine)
                     : wasmtime_component_type_import_count(ct, engine);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = n; i > 0; i--) {
    const char *name;
    size_t len;
    wasmtime_component_item_t item;
    int ok = exports ? wasmtime_component_type_export_nth(ct, engine, i - 1, &name, &len, &item)
                     : wasmtime_component_type_import_nth(ct, engine, i - 1, &name, &len, &item);
    if (!ok) continue;
    if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
      const wasmtime_component_instance_type_t *it = item.of.component_instance;
      size_t nf = wasmtime_component_instance_type_export_count(it, engine);
      for (size_t j = nf; j > 0; j--) {
        const char *fname;
        size_t flen;
        wasmtime_component_item_t fitem;
        if (!wasmtime_component_instance_type_export_nth(it, engine, j - 1, &fname, &flen, &fitem))
          continue;
        if (fitem.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
          ERL_NIF_TERM full;
          unsigned char *p = enif_make_new_binary(env, len + 1 + flen, &full);
          memcpy(p, name, len);
          p[len] = '#';
          memcpy(p + len + 1, fname, flen);
          list = enif_make_list_cell(env, enif_make_tuple2(env, full, atom_func), list);
        }
        wasmtime_component_item_delete(&fitem);
      }
    }
    list = enif_make_list_cell(
        env, enif_make_tuple2(env, mk_binary(env, name, len), item_kind(env, item.kind)), list);
    wasmtime_component_item_delete(&item);
  }
  wasmtime_component_type_delete(ct);
  return list;
}

#endif
