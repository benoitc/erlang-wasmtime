/*
 * nif_instantiate.c: Building an instance: options, limits, WASI, import binding
 * (Erlang host functions and the erlang.* imports), the start section,
 * the exported memory and the stdin shim. Runs on the worker thread.
 */
#include "nif.h"

static char *bin_to_cstr(ErlNifEnv *env, ERL_NIF_TERM t) {
  ErlNifBinary b;
  if (!enif_inspect_iolist_as_binary(env, t, &b)) return NULL;
  char *s = enif_alloc(b.size + 1);
  memcpy(s, b.data, b.size);
  s[b.size] = 0;
  return s;
}

/* Configures the store's WASI context: everything per instance (arguments,
 * environment, preopens, stdio). What the linker needs to know of it, the
 * clocks and the shadowed stdio functions, goes to *monotonic and the
 * inbox flags; the WASI functions themselves are in the shared linker.
 *
 * Wasi :: none | #{args, env, dirs, stdin, stdout, stderr, output_limit, clocks}
 * (wasi_options/1 in wasmtime.erl fills every key)
 * args  :: inherit | [binary()]     env :: inherit | [{binary(), binary()}]
 * stdin :: none | inherit | stream | {file, Path} | {binary, Bytes}
 * stdout, stderr :: none | inherit | stream | {file, Path} | capture
 * dirs  :: [{GuestPath, HostPath, read | write}]
 * clocks :: all | monotonic */
static ERL_NIF_TERM configure_wasi(instance_t *inst, ErlNifEnv *env, ErlNifEnv *out,
                                   ERL_NIF_TERM wasi, int *monotonic) {
  ERL_NIF_TERM t[8];
  const ERL_NIF_TERM keys[8] = {atom_args,   atom_env,    atom_dirs,         atom_stdin,
                                atom_stdout, atom_stderr, atom_output_limit, atom_clocks};
  if (enif_is_identical(wasi, atom_none)) return 0;
  for (int i = 0; i < 8; i++)
    if (!enif_get_map_value(env, wasi, keys[i], &t[i]))
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
  inst->capture.limit = limit;
  int monotonic_only = enif_is_identical(t[7], atom_monotonic);
  *monotonic = monotonic_only;
  if (!monotonic_only && !enif_is_identical(t[7], atom_all)) {
    err = "wasi clocks must be all or monotonic";
    goto done;
  }
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
    if (fd == 0 && enif_is_identical(s, atom_stream)) {
      inst->inbox.stdin = 1;
      if ((err = stdin_pipe_open(inst, cfg))) goto done;
      continue;
    }
    if (fd > 0 && (enif_is_identical(s, atom_capture) || enif_is_identical(s, atom_stream))) {
      capture_env_t *ce = enif_alloc(sizeof *ce);
      ce->inst = inst;
      ce->which = fd - 1;
      ptrdiff_t (*cb)(void *, const unsigned char *, size_t) =
          enif_is_identical(s, atom_capture) ? capture_write : stream_write;
      /* A streamed stdout looks like a terminal so the guest's C library
       * line-buffers it and every line leaves on its own. */
      if (cb == stream_write) inst->inbox.tty_mask |= 1 << fd;
      if (fd == 1)
        wasi_config_set_stdout_custom(cfg, cb, ce, enif_free);
      else
        wasi_config_set_stderr_custom(cfg, cb, ce, enif_free);
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
    err = fd == 0 ? "wasi stdin must be none, inherit, stream, {file, Path} or {binary, Bytes}"
                  : "wasi stdout and stderr must be none, inherit, stream, {file, Path} or capture";
    goto done;
  }

done:
  if (err) {
    wasi_config_delete(cfg);
    return mk_error_s(out, "wasi", "config", err);
  }
  wasmtime_error_t *werr = wasmtime_context_set_wasi(inst->wasm.ctx, cfg); /* consumes cfg */
  if (werr) {
    wasmtime_error_delete(werr);
    return mk_error_s(out, "wasi", "config", "wasi could not be configured");
  }
  return 0;
#endif
}

/* What instantiate/2 passes, as nif_options/3 in wasmtime.erl builds it:
 * every key present, defaults already applied. */
typedef struct {
  ERL_NIF_TERM imports; /* [{Module, Name}]: the host functions to bind */
  ERL_NIF_TERM wasi;    /* none | map, see configure_wasi */
  ERL_NIF_TERM shim;    /* binary() | undefined: the precompiled stdin shim */
  ErlNifSInt64 memory_limit, max_tables, max_table_elements, max_instances; /* -1: unlimited */
} opts_t;

static ERL_NIF_TERM opt_error(ErlNifEnv *out, const char *key) {
  char msg[80];
  snprintf(msg, sizeof msg, "option %s is missing or of the wrong type", key);
  return mk_error_s(out, "link", "badarg", msg);
}

/* Reads the options map into `o` and the instance fields it sets. */
static ERL_NIF_TERM parse_options(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM map, opts_t *o,
                                  ErlNifEnv *out) {
  ERL_NIF_TERM v;
  if (!enif_get_map_value(env, map, atom_imports, &o->imports) || !enif_is_list(env, o->imports))
    return opt_error(out, "imports");
  if (!enif_get_map_value(env, map, atom_wasi, &o->wasi)) return opt_error(out, "wasi");
  if (!enif_get_map_value(env, map, atom_shim, &o->shim)) return opt_error(out, "shim");
  struct {
    ERL_NIF_TERM key;
    const char *name;
    ErlNifSInt64 *dst;
  } limits[4] = {{atom_memory_limit, "memory_limit", &o->memory_limit},
                 {atom_max_tables, "max_tables", &o->max_tables},
                 {atom_max_table_elements, "max_table_elements", &o->max_table_elements},
                 {atom_max_instances, "max_instances", &o->max_instances}};
  for (int i = 0; i < 4; i++)
    if (!enif_get_map_value(env, map, limits[i].key, &v) || !enif_get_int64(env, v, limits[i].dst))
      return opt_error(out, limits[i].name);
  if (!enif_get_map_value(env, map, atom_host_timeout, &v) ||
      !enif_get_uint(env, v, &inst->host.timeout_ms))
    return opt_error(out, "host_timeout");
  if (!enif_get_map_value(env, map, atom_host, &v)) return opt_error(out, "host");
  inst->host.has_pid = enif_get_local_pid(env, v, &inst->host.pid);
  if (!inst->host.has_pid && !enif_is_identical(v, atom_undefined)) return opt_error(out, "host");
  if (!enif_get_map_value(env, map, atom_stream, &v) ||
      !enif_get_local_pid(env, v, &inst->inbox.stream_pid))
    return opt_error(out, "stream");
  ErlNifUInt64 limit;
  if (!enif_get_map_value(env, map, atom_inbox_limit, &v) || !enif_get_uint64(env, v, &limit))
    return opt_error(out, "inbox_limit");
  inst->inbox.limit = limit;
  return 0;
}

/* The store, its limits and the epoch hook. Its data is the instance, which
 * outlives it: callbacks find their instance there (caller_inst). */
static void configure_store(instance_t *inst, const opts_t *o) {
  wasm_engine_t *engine = inst->wasm.mod->engine->engine;
  inst->wasm.store = wasmtime_store_new(engine, inst, NULL);
  inst->wasm.ctx = wasmtime_store_context(inst->wasm.store);
  wasmtime_store_limiter(inst->wasm.store, o->memory_limit, o->max_table_elements, o->max_instances,
                         o->max_tables, -1);
  wasmtime_store_epoch_deadline_callback(inst->wasm.store, epoch_callback, inst, NULL);
  wasmtime_context_set_epoch_deadline(inst->wasm.ctx, 1);
}

/* The import type named {Module, Name}, or NULL when the module does not
 * have it. */
static const wasm_importtype_t *find_import(const wasm_importtype_vec_t *imports,
                                            const char *module, const char *name) {
  for (size_t i = 0; i < imports->size; i++) {
    const wasm_name_t *m = wasm_importtype_module(imports->data[i]);
    const wasm_name_t *n = wasm_importtype_name(imports->data[i]);
    if (m->size == strlen(module) && memcmp(m->data, module, m->size) == 0 &&
        n->size == strlen(name) && memcmp(n->data, name, n->size) == 0)
      return imports->data[i];
  }
  return NULL;
}

/* Binds one Erlang-backed import into the entry's linker. Takes ownership
 * of `module` and `name`. The callback's env is the import's index in
 * `hostfns`; the instance comes from the store (caller_inst). */
static ERL_NIF_TERM bind_import(linker_entry_t *le, ErlNifEnv *out, char *module, char *name,
                                const wasm_importtype_t *found) {
  if (strcmp(module, "erlang") == 0 && (strcmp(name, "send") == 0 || strcmp(name, "recv") == 0)) {
    enif_free(module);
    enif_free(name);
    return mk_error_s(out, "link", "reserved_import",
                      "erlang.send and erlang.recv are provided by the runtime");
  }
  const wasm_externtype_t *et = wasm_importtype_type(found);
  if (wasm_externtype_kind(et) != WASM_EXTERN_FUNC) {
    enif_free(module);
    enif_free(name);
    return mk_error_s(out, "link", "unsupported_import",
                      "only function imports can be provided from Erlang");
  }
  const wasm_functype_t *ft = wasm_externtype_as_functype_const(et);
  const wasm_valtype_vec_t *rs = wasm_functype_results(ft);
  shape_t sh = shape_of(ft);
  if (sh.exn || (sh.refs && sh.v128) || rs->size > MAX_VALS) {
    enif_free(module);
    enif_free(name);
    return mk_error_s(out, "link", "unsupported_type",
                      sh.exn    ? "host functions cannot take or return exception references"
                      : sh.refs ? "v128 and references cannot mix in one signature"
                                : "too many results");
  }
  size_t idx = le->nhostfns++;
  hostfn_t *fn = &le->hostfns[idx];
  fn->module = module;
  fn->name = name;
  fn->type = wasm_functype_copy(ft);
  fn->typed = sh.refs;
  void *env = (void *)(uintptr_t)idx;
  wasmtime_error_t *e =
      fn->typed
          ? wasmtime_linker_define_func(le->linker, module, strlen(module), name, strlen(name),
                                        fn->type, host_callback_typed, env, NULL)
          : wasmtime_linker_define_func_unchecked(le->linker, module, strlen(module), name,
                                                  strlen(name), fn->type, host_callback, env, NULL);
  return e ? error_to_term(out, e, "link") : 0;
}

/* Host functions: only imports named in the map are defined. Anything else
 * the module needs makes wasmtime_linker_instantiate_pre fail with a link
 * error. The erlang.* imports are bound by the runtime when the module has
 * them. */
static ERL_NIF_TERM bind_imports(linker_entry_t *le, module_res_t *m, ErlNifEnv *env,
                                 ERL_NIF_TERM list, ErlNifEnv *out) {
  unsigned nimports;
  if (!enif_get_list_length(env, list, &nimports))
    return mk_error_s(out, "link", "badarg", "imports must be a list");
  le->hostfns = enif_alloc(sizeof(hostfn_t) * (nimports + 1));
  memset(le->hostfns, 0, sizeof(hostfn_t) * (nimports + 1));

  wasm_importtype_vec_t imports;
  wasmtime_module_imports(m->mod, &imports);
  ERL_NIF_TERM h, result = 0;
  while (!result && enif_get_list_cell(env, list, &h, &list)) {
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
    const wasm_importtype_t *found = find_import(&imports, module, name);
    if (!found) {
      /* Providing a fun for an import the module does not have is harmless;
       * skip it so the same imports map can serve several modules. */
      enif_free(module);
      enif_free(name);
      continue;
    }
    result = bind_import(le, out, module, name, found);
  }
  if (!result) result = define_erlang_imports(le->linker, out, &imports);
  wasm_importtype_vec_delete(&imports);
  return result;
}

void linker_entry_free(linker_entry_t *le) {
  if (!le) return;
  if (le->pre) wasmtime_instance_pre_delete(le->pre);
  if (le->linker) wasmtime_linker_delete(le->linker);
#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
  if (le->clinker) wasmtime_component_linker_delete(le->clinker);
#endif
  for (size_t i = 0; i < le->nhostfns; i++) {
    enif_free(le->hostfns[i].module);
    enif_free(le->hostfns[i].name);
    if (le->hostfns[i].type) wasm_functype_delete(le->hostfns[i].type);
  }
  enif_free(le->hostfns);
  if (le->key_env) enif_free_env(le->key_env);
  enif_free(le);
}

/* Builds the linker and InstancePre for one shape. NULL with *err set when
 * the module cannot link with it. */
static linker_entry_t *build_entry(module_res_t *m, ErlNifEnv *env, ERL_NIF_TERM key,
                                   ERL_NIF_TERM imports, int wasi, int monotonic, int tty_mask,
                                   ErlNifEnv *out, ERL_NIF_TERM *err) {
  linker_entry_t *le = enif_alloc(sizeof *le);
  memset(le, 0, sizeof *le);
  le->key_env = enif_alloc_env();
  le->key = enif_make_copy(le->key_env, key);
  le->linker = wasmtime_linker_new(m->engine->engine);
  *err = 0;
#if NIF_HAVE_WASI
  if (wasi) {
    wasmtime_error_t *werr = wasmtime_linker_define_wasi(le->linker);
    if (werr) {
      wasmtime_error_delete(werr);
      *err = mk_error_s(out, "wasi", "config", "wasi could not be linked");
    }
    if (!*err && monotonic) *err = restrict_clocks(le->linker, out);
    if (!*err && tty_mask) *err = shadow_wasi(le->linker, tty_mask, out);
  }
#else
  (void)wasi, (void)monotonic, (void)tty_mask;
#endif
  if (!*err) *err = bind_imports(le, m, env, imports, out);
  if (!*err) {
    wasmtime_error_t *e = wasmtime_linker_instantiate_pre(le->linker, m->mod, &le->pre);
    if (e) *err = error_to_term(out, e, "link");
  }
  if (*err) {
    linker_entry_free(le);
    return NULL;
  }
  return le;
}

/* Linkers kept per module; a module instantiated with more shapes than this
 * builds a private linker for each further instance. */
#define MAX_LINKERS 16

/* The entry for this instance's shape: the module's, built on first use, or
 * a private one when the module's cache is full. */
static ERL_NIF_TERM link_entry(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM imports, int wasi,
                               int monotonic, ErlNifEnv *out) {
  module_res_t *m = inst->wasm.mod;
  ERL_NIF_TERM key = enif_make_tuple4(env, imports, wasi ? atom_true : atom_false,
                                      monotonic ? atom_true : atom_false,
                                      enif_make_int(env, inst->inbox.tty_mask));
  ERL_NIF_TERM err = 0;
  pthread_mutex_lock(&m->mu);
  linker_entry_t *le = m->linkers;
  while (le && !enif_is_identical(le->key, key)) le = le->next;
  if (!le) {
    le = build_entry(m, env, key, imports, wasi, monotonic, inst->inbox.tty_mask, out, &err);
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
  return err;
}

/* Runs the module's start section, which may call host functions. */
static ERL_NIF_TERM instantiate_module(instance_t *inst, ErlNifEnv *out) {
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e = wasmtime_instance_pre_instantiate(inst->wasm.entry->pre, inst->wasm.ctx,
                                                          &inst->wasm.instance, &trap);
  ERL_NIF_TERM result = outcome(inst, out, e, trap, "link");
  return enif_is_identical(result, atom_ok) ? 0 : result;
}

/* The exported memory, "memory" by name or the first one exported. */
static void cache_memory(instance_t *inst) {
  wasmtime_extern_t ext;
  if (wasmtime_instance_export_get(inst->wasm.ctx, &inst->wasm.instance, "memory", 6, &ext) &&
      ext.kind == WASMTIME_EXTERN_MEMORY) {
    inst->wasm.memory = ext.of.memory;
    inst->wasm.has_memory = 1;
    return;
  }
  char *nm;
  size_t nlen;
  for (size_t i = 0;
       wasmtime_instance_export_nth(inst->wasm.ctx, &inst->wasm.instance, i, &nm, &nlen, &ext);
       i++) {
    if (ext.kind == WASMTIME_EXTERN_MEMORY) {
      inst->wasm.memory = ext.of.memory;
      inst->wasm.has_memory = 1;
      return;
    }
  }
}

/* The REQ_INSTANTIATE request, on the worker thread. Each step answers 0
 * or the error to send; a failure leaves the instance stopped. */
ERL_NIF_TERM do_instantiate(instance_t *inst, req_t *req, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  opts_t o;
  ERL_NIF_TERM err;
  if ((err = parse_options(inst, env, req->opts, &o, out))) return err;
  configure_store(inst, &o);
  int monotonic = 0, wasi = !enif_is_identical(o.wasi, atom_none);
  if ((err = configure_wasi(inst, env, out, o.wasi, &monotonic))) return err;
#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
  if (inst->wasm.mod->comp) {
    /* WASI 0.2 reads the same context; the preview 1 stdout terminal rule
     * has no counterpart there (docs/design.md, "Streams") */
    inst->wasm.component = 1;
    if ((err = component_instantiate(inst, env, o.imports, wasi, monotonic, out))) return err;
    stdin_pump_start(inst);
    inst->wasm.instantiated = 1;
    return atom_ok;
  }
#endif
  if ((err = link_entry(inst, env, o.imports, wasi, monotonic, out))) return err;
  if ((err = instantiate_module(inst, out))) return err;
  cache_memory(inst);
  if (inst->inbox.tty_mask) {
    if ((err = take_real_wasi(inst, out))) return err;
    if ((err = link_wasi_shim(inst, env, o.shim, out))) return err;
  }
  stdin_pump_start(inst);
  inst->wasm.instantiated = 1;
  return atom_ok;
}
