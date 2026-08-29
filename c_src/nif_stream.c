/*
 * nif_stream.c: Streams: the per-instance inbox fed by send/2, read by the
 * guest through stdin (an fd_read in front of WASI's, forwarding other fds
 * through the shim) or the erlang.recv import; guest output pushed as
 * {wasmtime_stream, ...} messages.
 */
#include "nif.h"

/* Called with the mutex held. */
void inbox_drop_head(instance_t *inst) {
  chunk_t *c = inst->inbox.head;
  inst->inbox.head = c->next;
  if (!inst->inbox.head) inst->inbox.tail = NULL;
  inst->inbox.bytes -= c->len - c->off;
  enif_free(c->data);
  enif_free(c);
}

enum inbox_status { INBOX_DATA, INBOX_CLOSED, INBOX_INTERRUPTED };

/* Wait, with the mutex held, until the inbox has bytes, is closed, or the
 * running request is being stopped. */
static enum inbox_status inbox_wait(instance_t *inst) {
  for (;;) {
    if (inst->host.abort || inst->queue.current->cancelled) return INBOX_INTERRUPTED;
    if (inst->inbox.head) return INBOX_DATA;
    if (inst->inbox.closed) return INBOX_CLOSED;
    pthread_cond_wait(&inst->cv, &inst->mu);
  }
}

static wasm_trap_t *interrupted_trap(instance_t *inst) {
  inst->interrupted_fired = 1;
  return wasmtime_trap_new("interrupted", 11);
}

/* The caller's exported memory, "memory" by name as WASI and every
 * toolchain export it. */
static int guest_mem(wasmtime_caller_t *caller, unsigned char **base, size_t *size) {
  wasmtime_extern_t ext;
  if (!wasmtime_caller_export_get(caller, "memory", 6, &ext) || ext.kind != WASMTIME_EXTERN_MEMORY)
    return 0;
  wasmtime_context_t *ctx = wasmtime_caller_context(caller);
  *base = wasmtime_memory_data(ctx, &ext.of.memory);
  *size = wasmtime_memory_data_size(ctx, &ext.of.memory);
  return 1;
}

static int in_bounds(size_t size, uint32_t ptr, uint32_t len) {
  return (uint64_t)ptr + len <= size;
}

/* {wasmtime_stream, Ref, Kind, Bytes} to the stream process. A receiver
 * that is gone drops the bytes, like `none` does. */
static void stream_send(instance_t *inst, ERL_NIF_TERM kind, const unsigned char *data,
                        size_t len) {
  ErlNifEnv *menv = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple4(menv, atom_wasmtime_stream, enif_make_copy(menv, inst->ref),
                                      kind, mk_binary(menv, data, len));
  enif_send(NULL, &inst->inbox.stream_pid, menv, msg);
  enif_free_env(menv);
}

/* erlang.send(ptr: i32, len: i32): one message to the stream process */
static wasm_trap_t *erlang_send_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                                   size_t nvals) {
  instance_t *inst = envp;
  unsigned char *base;
  size_t size;
  uint32_t ptr = (uint32_t)vals[0].i32, len = (uint32_t)vals[1].i32;
  if (!guest_mem(caller, &base, &size) || !in_bounds(size, ptr, len))
    return wasmtime_trap_new("erlang.send: out of bounds", 26);
  stream_send(inst, atom_channel, base + ptr, len);
  return NULL;
}

/* erlang.recv(ptr: i32, cap: i32) -> i32: one whole message copied to ptr,
 * its length returned; blocks until one is queued. -1 once closed and
 * drained; -2 - Needed when cap is too small (the message stays queued). */
static wasm_trap_t *erlang_recv_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                                   size_t nvals) {
  instance_t *inst = envp;
  unsigned char *base;
  size_t size;
  uint32_t ptr = (uint32_t)vals[0].i32, cap = (uint32_t)vals[1].i32;
  if (!guest_mem(caller, &base, &size) || !in_bounds(size, ptr, cap))
    return wasmtime_trap_new("erlang.recv: out of bounds", 26);
  pthread_mutex_lock(&inst->mu);
  enum inbox_status st = inbox_wait(inst);
  int32_t r = -1;
  if (st == INBOX_DATA) {
    chunk_t *c = inst->inbox.head;
    size_t len = c->len - c->off;
    if (len > cap) {
      r = -2 - (int32_t)len;
    } else {
      memcpy(base + ptr, c->data + c->off, len);
      r = (int32_t)len;
      inbox_drop_head(inst);
    }
  }
  pthread_mutex_unlock(&inst->mu);
  if (st == INBOX_INTERRUPTED) return interrupted_trap(inst);
  vals[0].i32 = r;
  return NULL;
}

#if NIF_HAVE_WASI
/* wasi_snapshot_preview1.fd_read(fd, iovs, iovs_len, nread) -> errno, in
 * front of Wasmtime's own: fd 0 reads the inbox as a byte stream, any other
 * fd is forwarded. Wasmtime has no custom stdin hook; this is the one place
 * the preview 1 surface is reimplemented. */
#define WASI_EFAULT 21

wasm_trap_t *fd_read_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                        size_t nvals) {
  instance_t *inst = envp;
  if (vals[0].i32 != 0) {
    if (!inst->inbox.has_shim)
      return wasmtime_trap_new("fd_read before the instance is linked", 38);
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *e = wasmtime_func_call_unchecked(wasmtime_caller_context(caller),
                                                       &inst->inbox.shim_fd_read, vals, 4, &trap);
    if (e) {
      wasm_name_t msg;
      wasmtime_error_message(e, &msg);
      trap = wasmtime_trap_new(msg.data, msg.size);
      wasm_byte_vec_delete(&msg);
      wasmtime_error_delete(e);
    }
    return trap;
  }
  unsigned char *base;
  size_t size;
  uint32_t iovs = (uint32_t)vals[1].i32, niovs = (uint32_t)vals[2].i32,
           nread = (uint32_t)vals[3].i32;
  if (!guest_mem(caller, &base, &size) || niovs > size / 8 || !in_bounds(size, iovs, niovs * 8) ||
      !in_bounds(size, nread, 4)) {
    vals[0].i32 = WASI_EFAULT;
    return NULL;
  }
  /* Each iovec is {buf: u32, len: u32}, little endian. */
  uint64_t want = 0;
  for (uint32_t i = 0; i < niovs; i++) {
    uint32_t buf, len;
    memcpy(&buf, base + iovs + i * 8, 4);
    memcpy(&len, base + iovs + i * 8 + 4, 4);
    if (!in_bounds(size, buf, len)) {
      vals[0].i32 = WASI_EFAULT;
      return NULL;
    }
    want += len;
  }
  uint32_t got = 0;
  if (want > 0) {
    pthread_mutex_lock(&inst->mu);
    enum inbox_status st = inbox_wait(inst);
    if (st == INBOX_INTERRUPTED) {
      pthread_mutex_unlock(&inst->mu);
      return interrupted_trap(inst);
    }
    /* A short read: what is queued now, never a wait for more. */
    for (uint32_t i = 0; i < niovs && inst->inbox.head; i++) {
      uint32_t buf, len;
      memcpy(&buf, base + iovs + i * 8, 4);
      memcpy(&len, base + iovs + i * 8 + 4, 4);
      while (len > 0 && inst->inbox.head) {
        chunk_t *c = inst->inbox.head;
        size_t n = c->len - c->off;
        if (n > len) n = len;
        memcpy(base + buf, c->data + c->off, n);
        buf += (uint32_t)n;
        len -= (uint32_t)n;
        got += (uint32_t)n;
        c->off += n;
        inst->inbox.bytes -= n;
        if (c->off == c->len) inbox_drop_head(inst);
      }
    }
    pthread_mutex_unlock(&inst->mu);
  }
  memcpy(base + nread, &got, 4);
  vals[0].i32 = 0;
  return NULL;
}
#endif

/* Put fd_read in front of Wasmtime's own. Called after the WASI definitions
 * are in the linker. */
ERL_NIF_TERM define_stdin_stream(instance_t *inst, ErlNifEnv *out) {
#if NIF_HAVE_WASI
  wasmtime_extern_t real;
  if (!wasmtime_linker_get(inst->wasm.linker, inst->wasm.ctx, "wasi_snapshot_preview1", 22,
                           "fd_read", 7, &real) ||
      real.kind != WASMTIME_EXTERN_FUNC)
    return mk_error_s(out, "wasi", "config", "wasi fd_read is not in the linker");
  inst->inbox.real_fd_read = real.of.func;
  wasm_valtype_t *ps[4] = {wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
                           wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32)};
  wasm_valtype_t *rs[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t pv, rv;
  wasm_valtype_vec_new(&pv, 4, (wasm_valtype_t *const *)ps);
  wasm_valtype_vec_new(&rv, 1, (wasm_valtype_t *const *)rs);
  wasm_functype_t *ft = wasm_functype_new(&pv, &rv);
  wasmtime_linker_allow_shadowing(inst->wasm.linker, true);
  wasmtime_error_t *e = wasmtime_linker_define_func_unchecked(
      inst->wasm.linker, "wasi_snapshot_preview1", 22, "fd_read", 7, ft, fd_read_cb, inst, NULL);
  wasmtime_linker_allow_shadowing(inst->wasm.linker, false);
  wasm_functype_delete(ft);
  if (e) return error_to_term(out, e, "wasi");
  return 0;
#else
  return mk_error_s(out, "wasi", "unavailable", "this build of erlang_wasmtime has no WASI");
#endif
}

/* Called once the guest is instantiated and its memory is known. */
ERL_NIF_TERM link_stdin_shim(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM shim_bytes,
                             ErlNifEnv *out) {
  const char *why = "stdin shim";
  wasmtime_module_t *shim = engine_shim(inst->wasm.mod->engine, env, shim_bytes, &why);
  if (!shim) return mk_error_s(out, "wasi", "unavailable", why);
  if (!inst->wasm.has_memory)
    return mk_error_s(out, "wasi", "config", "stdin => stream needs an exported memory");
  wasmtime_extern_t real = {.kind = WASMTIME_EXTERN_FUNC, .of.func = inst->inbox.real_fd_read};
  wasmtime_extern_t mem = {.kind = WASMTIME_EXTERN_MEMORY, .of.memory = inst->wasm.memory};
  wasmtime_linker_t *l = wasmtime_linker_new(inst->wasm.mod->engine->engine);
  wasmtime_error_t *e = wasmtime_linker_define(l, inst->wasm.ctx, "wasi", 4, "fd_read", 7, &real);
  if (!e) e = wasmtime_linker_define(l, inst->wasm.ctx, "guest", 5, "memory", 6, &mem);
  wasmtime_instance_t si;
  wasm_trap_t *trap = NULL;
  if (!e) e = wasmtime_linker_instantiate(l, inst->wasm.ctx, shim, &si, &trap);
  wasmtime_linker_delete(l);
  if (trap) wasm_trap_delete(trap);
  if (e) {
    wasmtime_error_delete(e);
    return mk_error_s(out, "wasi", "config",
                      "stdin => stream could not link to this memory (shared or 64-bit?)");
  }
  wasmtime_extern_t fwd;
  if (!wasmtime_instance_export_get(inst->wasm.ctx, &si, "fd_read", 7, &fwd) ||
      fwd.kind != WASMTIME_EXTERN_FUNC)
    return mk_error_s(out, "wasi", "config", "stdin shim has no fd_read");
  inst->inbox.shim_fd_read = fwd.of.func;
  inst->inbox.has_shim = 1;
  return 0;
}

/* The `erlang` imports a module may declare: send (i32 i32) and
 * recv (i32 i32) -> i32. Bound natively when present with that exact type. */
static int functype_is(const wasm_functype_t *ft, size_t np, size_t nr) {
  const wasm_valtype_vec_t *ps = wasm_functype_params(ft), *rs = wasm_functype_results(ft);
  if (ps->size != np || rs->size != nr) return 0;
  for (size_t i = 0; i < np; i++)
    if (kind_of(ps->data[i]) != WASMTIME_I32) return 0;
  for (size_t i = 0; i < nr; i++)
    if (kind_of(rs->data[i]) != WASMTIME_I32) return 0;
  return 1;
}

ERL_NIF_TERM define_erlang_imports(instance_t *inst, ErlNifEnv *out,
                                   const wasm_importtype_vec_t *imports) {
  for (size_t i = 0; i < imports->size; i++) {
    const wasm_name_t *m = wasm_importtype_module(imports->data[i]);
    const wasm_name_t *n = wasm_importtype_name(imports->data[i]);
    if (m->size != 6 || memcmp(m->data, "erlang", 6) != 0) continue;
    int is_send = n->size == 4 && memcmp(n->data, "send", 4) == 0;
    int is_recv = n->size == 4 && memcmp(n->data, "recv", 4) == 0;
    if (!is_send && !is_recv) continue;
    const wasm_externtype_t *et = wasm_importtype_type(imports->data[i]);
    const wasm_functype_t *ft =
        wasm_externtype_kind(et) == WASM_EXTERN_FUNC ? wasm_externtype_as_functype_const(et) : NULL;
    if (!ft || !functype_is(ft, 2, is_recv ? 1 : 0))
      return mk_error_s(out, "link", "unsupported_type",
                        is_send ? "erlang.send must be a function (i32 i32)"
                                : "erlang.recv must be a function (i32 i32) -> i32");
    wasmtime_error_t *e = wasmtime_linker_define_func_unchecked(
        inst->wasm.linker, "erlang", 6, is_send ? "send" : "recv", 4, ft,
        is_send ? erlang_send_cb : erlang_recv_cb, inst, NULL);
    if (e) return error_to_term(out, e, "link");
  }
  return 0;
}

#if NIF_HAVE_WASI

/* Runs on the instance thread inside a WASI write. Appends under the mutex
 * so read_output/1 can copy the buffer from a scheduler thread meanwhile. */
ptrdiff_t capture_write(void *envp, const unsigned char *data, size_t len) {
  capture_env_t *ce = envp;
  instance_t *inst = ce->inst;
  pthread_mutex_lock(&inst->mu);
  size_t room = inst->capture.limit > inst->capture.buf[ce->which].len
                    ? inst->capture.limit - inst->capture.buf[ce->which].len
                    : 0;
  size_t keep = len < room ? len : room;
  if (keep) {
    size_t need = inst->capture.buf[ce->which].len + keep;
    if (need > inst->capture.buf[ce->which].cap) {
      size_t cap = inst->capture.buf[ce->which].cap ? inst->capture.buf[ce->which].cap * 2 : 4096;
      while (cap < need) cap *= 2;
      inst->capture.buf[ce->which].data = enif_realloc(inst->capture.buf[ce->which].data, cap);
      inst->capture.buf[ce->which].cap = cap;
    }
    memcpy(inst->capture.buf[ce->which].data + inst->capture.buf[ce->which].len, data, keep);
    inst->capture.buf[ce->which].len += keep;
  }
  inst->capture.dropped[ce->which] += len - keep;
  pthread_mutex_unlock(&inst->mu);
  return (ptrdiff_t)len; /* the guest sees a complete write either way */
}

/* stdout/stderr `stream`: every write goes out as a message at once. */
ptrdiff_t stream_write(void *envp, const unsigned char *data, size_t len) {
  capture_env_t *ce = envp;
  stream_send(ce->inst, ce->which == 0 ? atom_stdout : atom_stderr, data, len);
  return (ptrdiff_t)len;
}
#endif

/* send(Handle, Bytes) -> ok | {error, Map}: queue one message for the guest */
ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  ErlNifBinary bin;
  if (!get_handle(env, argv[0], &inst) || !enif_inspect_iolist_as_binary(env, argv[1], &bin))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r = atom_ok;
  if (inst->queue.stopping) {
    r = mk_error_s(env, "stream", "stopped", "instance is stopped");
  } else if (inst->inbox.closed) {
    r = mk_error_s(env, "stream", "closed", "the guest's input is closed");
  } else if (inst->inbox.bytes + bin.size > inst->inbox.limit) {
    r = mk_error_s(env, "stream", "inbox_full", "the guest has not read what was sent");
  } else {
    chunk_t *c = enif_alloc(sizeof *c);
    c->data = enif_alloc(bin.size ? bin.size : 1);
    memcpy(c->data, bin.data, bin.size);
    c->len = bin.size;
    c->off = 0;
    c->next = NULL;
    if (inst->inbox.tail)
      inst->inbox.tail->next = c;
    else
      inst->inbox.head = c;
    inst->inbox.tail = c;
    inst->inbox.bytes += bin.size;
    pthread_cond_broadcast(&inst->cv);
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* close(Handle) -> ok: end of input once the inbox is drained */
ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  inst->inbox.closed = 1;
  pthread_cond_broadcast(&inst->cv);
  pthread_mutex_unlock(&inst->mu);
  return atom_ok;
}
