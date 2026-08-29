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
    if (fd == 0 && enif_is_identical(s, atom_stream)) {
      inst->stdin_stream = 1; /* fd_read is put in front of WASI's below */
      continue;
    }
    if (fd > 0 && (enif_is_identical(s, atom_capture) || enif_is_identical(s, atom_stream))) {
      capture_env_t *ce = enif_alloc(sizeof *ce);
      ce->inst = inst;
      ce->which = fd - 1;
      ptrdiff_t (*cb)(void *, const unsigned char *, size_t) =
          enif_is_identical(s, atom_capture) ? capture_write : stream_write;
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
  if (inst->stdin_stream) return define_stdin_stream(inst, out);
  return 0;
#endif
}

/* Opts :: {Imports :: [{Module, Name}], Wasi, Limits, HostTimeoutMs, HostPid,
 *          StreamPid, InboxLimit, Shim :: binary() | undefined}
 * Limits :: {MemoryBytes, Tables, TableElements, Instances}, -1 = unlimited
 * HostPid :: pid() | undefined */
ERL_NIF_TERM do_instantiate(instance_t *inst, req_t *req, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  const ERL_NIF_TERM *o, *lim;
  int arity;
  if (!enif_get_tuple(env, req->opts, &arity, &o) || arity != 8 ||
      !enif_get_tuple(env, o[2], &arity, &lim) || arity != 4)
    return mk_error_s(out, "link", "badarg", "malformed options");
  inst->has_host_pid = enif_get_local_pid(env, o[4], &inst->host_pid);

  ErlNifSInt64 mem, tables, elems, instances;
  unsigned host_timeout;
  ErlNifUInt64 inbox_limit;
  if (!enif_get_int64(env, lim[0], &mem) || !enif_get_int64(env, lim[1], &tables) ||
      !enif_get_int64(env, lim[2], &elems) || !enif_get_int64(env, lim[3], &instances) ||
      !enif_get_uint(env, o[3], &host_timeout) ||
      !enif_get_local_pid(env, o[5], &inst->stream_pid) ||
      !enif_get_uint64(env, o[6], &inbox_limit))
    return mk_error_s(out, "link", "badarg", "malformed limits");
  inst->host_timeout_ms = host_timeout;
  inst->inbox_limit = inbox_limit;

  inst->store = wasmtime_store_new(inst->mod->engine->engine, NULL, NULL);
  inst->ctx = wasmtime_store_context(inst->store);
  wasmtime_store_limiter(inst->store, mem, elems, instances, tables, -1);
  wasmtime_store_epoch_deadline_callback(inst->store, epoch_callback, inst, NULL);
  wasmtime_context_set_epoch_deadline(inst->ctx, 1);
  inst->linker = wasmtime_linker_new(inst->mod->engine->engine);

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
    if (strcmp(module, "erlang") == 0 && (strcmp(name, "send") == 0 || strcmp(name, "recv") == 0)) {
      enif_free(module);
      enif_free(name);
      result = mk_error_s(out, "link", "reserved_import",
                          "erlang.send and erlang.recv are provided by the runtime");
      break;
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
    const wasm_valtype_vec_t *rs = wasm_functype_results(ft);
    shape_t sh = shape_of(ft);
    if (sh.exn || (sh.refs && sh.v128) || rs->size > MAX_VALS) {
      enif_free(module);
      enif_free(name);
      result = mk_error_s(out, "link", "unsupported_type",
                          sh.exn    ? "host functions cannot take or return exception references"
                          : sh.refs ? "v128 and references cannot mix in one signature"
                                    : "too many results");
      break;
    }
    hostfn_t *fn = &inst->hostfns[inst->nhostfns];
    fn->module = module;
    fn->name = name;
    fn->type = wasm_functype_copy(ft);
    fn->typed = sh.refs;
    hostfn_env_t *he = enif_alloc(sizeof *he);
    he->inst = inst;
    he->idx = inst->nhostfns;
    inst->nhostfns++;
    /* The linker owns `he` from here and frees it with enif_free, on the
     * error path too. */
    wasmtime_error_t *e =
        fn->typed
            ? wasmtime_linker_define_func(inst->linker, module, strlen(module), name, strlen(name),
                                          fn->type, host_callback_typed, he, enif_free)
            : wasmtime_linker_define_func_unchecked(inst->linker, module, strlen(module), name,
                                                    strlen(name), fn->type, host_callback, he,
                                                    enif_free);
    if (e) {
      result = error_to_term(out, e, "link");
      break;
    }
  }
  if (enif_is_identical(result, atom_ok)) {
    ERL_NIF_TERM e = define_erlang_imports(inst, out, &imports);
    if (e) result = e;
  }
  wasm_importtype_vec_delete(&imports);
  if (!enif_is_identical(result, atom_ok)) return result;

  /* This runs the module's start section, which may call host functions. */
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e =
      wasmtime_linker_instantiate(inst->linker, inst->ctx, inst->mod->mod, &inst->instance, &trap);
  result = outcome(inst, out, e, trap, "link");
  if (!enif_is_identical(result, atom_ok)) return result;

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
  if (inst->stdin_stream) {
    ERL_NIF_TERM r = link_stdin_shim(inst, env, o[7], out);
    if (r) return r;
  }
  inst->instantiated = 1;
  return atom_ok;
}
