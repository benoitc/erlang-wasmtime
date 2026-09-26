/*
 * nif_stream.c: Streams: the per-instance inbox fed by send/2, read by the
 * guest through stdin (a pipe Wasmtime reads, filled by a pump thread) or
 * the erlang.recv import; guest output pushed as {wasmtime_stream, ...}
 * messages.
 */
#include "nif.h"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

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
  (void)envp;
  instance_t *inst = caller_inst(caller);
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
  (void)envp;
  instance_t *inst = caller_inst(caller);
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

/* Calls Wasmtime's own function through the shim. */
static wasm_trap_t *forward(instance_t *inst, wasmtime_caller_t *caller, wasmtime_func_t *fn,
                            wasmtime_val_raw_t *vals, size_t nvals) {
  if (!inst->inbox.has_shim)
    return wasmtime_trap_new("WASI call before the instance is linked", 39);
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e =
      wasmtime_func_call_unchecked(wasmtime_caller_context(caller), fn, vals, nvals, &trap);
  if (e) {
    wasm_name_t msg;
    wasmtime_error_message(e, &msg);
    trap = wasmtime_trap_new(msg.data, msg.size);
    wasm_byte_vec_delete(&msg);
    wasmtime_error_delete(e);
  }
  return trap;
}

#if NIF_HAVE_WASI
/* wasi_snapshot_preview1.fd_fdstat_get(fd, buf) -> errno, in front of
 * Wasmtime's own: a `stream` stdout or stderr is reported as a character
 * device without seek and tell rights, which is what wasi-libc's isatty
 * checks. The guest's C library then line-buffers it, so a line written
 * by the guest leaves at once instead of waiting in a buffer. */
#define WASI_FILETYPE_CHARACTER_DEVICE 2
#define WASI_RIGHT_FD_SEEK (1ull << 2)
#define WASI_RIGHT_FD_TELL (1ull << 5)
static wasm_trap_t *fd_fdstat_cb(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                                 size_t nvals) {
  (void)envp;
  instance_t *inst = caller_inst(caller);
  int32_t fd = vals[0].i32;
  uint32_t buf = (uint32_t)vals[1].i32;
  wasm_trap_t *trap = forward(inst, caller, &inst->inbox.shim_fdstat, vals, 2);
  if (trap || vals[0].i32 != 0 || fd < 0 || fd > 2 || !((inst->inbox.tty_mask >> fd) & 1))
    return trap;
  unsigned char *base;
  size_t size;
  if (!guest_mem(caller, &base, &size) || !in_bounds(size, buf, 24)) return NULL;
  /* fdstat: fs_filetype u8 at 0, fs_flags u16 at 2, rights u64 at 8 and 16 */
  base[buf] = WASI_FILETYPE_CHARACTER_DEVICE;
  for (int off = 8; off <= 16; off += 8) {
    uint64_t rights;
    memcpy(&rights, base + buf + off, 8);
    rights &= ~(WASI_RIGHT_FD_SEEK | WASI_RIGHT_FD_TELL);
    memcpy(base + buf + off, &rights, 8);
  }
  return NULL;
}

/* A (i32 x n) -> i32 function type. */
static wasm_functype_t *i32_functype(size_t nparams) {
  wasm_valtype_t *ps[4];
  for (size_t i = 0; i < nparams; i++) ps[i] = wasm_valtype_new(WASM_I32);
  wasm_valtype_t *rs[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t pv, rv;
  wasm_valtype_vec_new(&pv, nparams, (wasm_valtype_t *const *)ps);
  wasm_valtype_vec_new(&rv, 1, (wasm_valtype_t *const *)rs);
  return wasm_functype_new(&pv, &rv);
}

/* Puts `cb` in front of Wasmtime's `name`. */
static ERL_NIF_TERM shadow_one(wasmtime_linker_t *linker, ErlNifEnv *out, const char *name,
                               size_t nparams, wasmtime_func_unchecked_callback_t cb) {
  wasm_functype_t *ft = i32_functype(nparams);
  wasmtime_linker_allow_shadowing(linker, true);
  wasmtime_error_t *e = wasmtime_linker_define_func_unchecked(
      linker, "wasi_snapshot_preview1", 22, name, strlen(name), ft, cb, NULL, NULL);
  wasmtime_linker_allow_shadowing(linker, false);
  wasm_functype_delete(ft);
  return e ? error_to_term(out, e, "wasi") : 0;
}
#endif

/* Put the runtime's fd_fdstat_get (a `stream` stdout or stderr) in front of
 * Wasmtime's own, in a linker that already has the WASI definitions. */
ERL_NIF_TERM shadow_wasi(wasmtime_linker_t *linker, int tty_mask, ErlNifEnv *out) {
#if NIF_HAVE_WASI
  return tty_mask ? shadow_one(linker, out, "fd_fdstat_get", 2, fd_fdstat_cb) : 0;
#else
  (void)linker, (void)tty_mask;
  return mk_error_s(out, "wasi", "unavailable", "this build of erlang_wasmtime has no WASI");
#endif
}

/* Wasmtime's own fd_read and fd_fdstat_get in this store, for the shim to
 * forward to whichever is shadowed: taken from the engine's WASI-only
 * linker, since the instance's linker has them shadowed. */
ERL_NIF_TERM take_real_wasi(instance_t *inst, ErlNifEnv *out) {
#if NIF_HAVE_WASI
  wasmtime_linker_t *wl = engine_wasi_linker(inst->wasm.mod->engine);
  wasmtime_extern_t ext;
  const char *names[2] = {"fd_read", "fd_fdstat_get"};
  wasmtime_func_t *reals[2] = {&inst->inbox.real_fd_read, &inst->inbox.real_fdstat};
  for (int i = 0; i < 2; i++) {
    if (!wl ||
        !wasmtime_linker_get(wl, inst->wasm.ctx, "wasi_snapshot_preview1", 22, names[i],
                             strlen(names[i]), &ext) ||
        ext.kind != WASMTIME_EXTERN_FUNC)
      return mk_error_s(out, "wasi", "config", "the WASI function to forward to is missing");
    *reals[i] = ext.of.func;
  }
  return 0;
#else
  (void)inst;
  return mk_error_s(out, "wasi", "unavailable", "this build of erlang_wasmtime has no WASI");
#endif
}

/* Called once the guest is instantiated and its memory is known. */
ERL_NIF_TERM link_wasi_shim(instance_t *inst, ErlNifEnv *env, ERL_NIF_TERM shim_bytes,
                            ErlNifEnv *out) {
  const char *why = "WASI shim";
  wasmtime_module_t *shim = engine_shim(inst->wasm.mod->engine, env, shim_bytes, &why);
  if (!shim) return mk_error_s(out, "wasi", "unavailable", why);
  if (!inst->wasm.has_memory)
    return mk_error_s(out, "wasi", "config", "streamed stdio needs an exported memory");
  wasmtime_extern_t rd = {.kind = WASMTIME_EXTERN_FUNC, .of.func = inst->inbox.real_fd_read};
  wasmtime_extern_t st = {.kind = WASMTIME_EXTERN_FUNC, .of.func = inst->inbox.real_fdstat};
  wasmtime_extern_t mem = {.kind = WASMTIME_EXTERN_MEMORY, .of.memory = inst->wasm.memory};
  wasmtime_linker_t *l = wasmtime_linker_new(inst->wasm.mod->engine->engine);
  wasmtime_error_t *e = wasmtime_linker_define(l, inst->wasm.ctx, "wasi", 4, "fd_read", 7, &rd);
  if (!e) e = wasmtime_linker_define(l, inst->wasm.ctx, "wasi", 4, "fd_fdstat_get", 13, &st);
  if (!e) e = wasmtime_linker_define(l, inst->wasm.ctx, "guest", 5, "memory", 6, &mem);
  wasmtime_instance_t si;
  wasm_trap_t *trap = NULL;
  if (!e) e = wasmtime_linker_instantiate(l, inst->wasm.ctx, shim, &si, &trap);
  wasmtime_linker_delete(l);
  if (trap) wasm_trap_delete(trap);
  if (e) {
    wasmtime_error_delete(e);
    return mk_error_s(out, "wasi", "config",
                      "streamed stdio could not link to this memory (shared or 64-bit?)");
  }
  wasmtime_extern_t fwd;
  if (!wasmtime_instance_export_get(inst->wasm.ctx, &si, "fd_read", 7, &fwd) ||
      fwd.kind != WASMTIME_EXTERN_FUNC)
    return mk_error_s(out, "wasi", "config", "the WASI shim has no fd_read");
  inst->inbox.shim_fd_read = fwd.of.func;
  if (!wasmtime_instance_export_get(inst->wasm.ctx, &si, "fd_fdstat_get", 13, &fwd) ||
      fwd.kind != WASMTIME_EXTERN_FUNC)
    return mk_error_s(out, "wasi", "config", "the WASI shim has no fd_fdstat_get");
  inst->inbox.shim_fdstat = fwd.of.func;
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

ERL_NIF_TERM define_erlang_imports(wasmtime_linker_t *linker, ErlNifEnv *out,
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
        linker, "erlang", 6, is_send ? "send" : "recv", 4, ft,
        is_send ? erlang_send_cb : erlang_recv_cb, NULL, NULL);
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

/* ------------------------------------------------------------ stdin pipe --
 * `stdin => stream`: Wasmtime's C API takes stdin only from bytes, a file or
 * the process's own, and reads a file asynchronously. So the guest's stdin
 * is the read end of a pipe, which preview 1 and WASI 0.2 read alike: a read
 * waits for bytes, a 0.2 pollable waits properly, end of file is the pipe
 * closing. The pump thread moves what send/2 queued into the write end; a
 * pipe holds 16 to 64 KB and a scheduler must never block on it.
 *
 * A guest blocked in a stdin read is inside Wasmtime, where the epoch cannot
 * reach it: stopping the instance closes the pipe to wake it (stdin_abort).
 * An interrupted instance's stdin stays closed. docs/streams.md.
 */

#if NIF_HAVE_WASI
/* Opens the pipe and hands its read end to `cfg`. NULL on success, else why
 * not. The read end is given by path: /dev/fd/N reopens it where the
 * platform has that (Linux, macOS); elsewhere a named pipe in a private
 * directory, removed at once. */
const char *stdin_pipe_open(instance_t *inst, wasi_config_t *cfg) {
  int fds[2];
  char path[64];
  if (pipe(fds) == 0) {
    snprintf(path, sizeof path, "/dev/fd/%d", fds[0]);
    if (wasi_config_set_stdin_file(cfg, path)) {
      close(fds[0]);
      fcntl(fds[1], F_SETFD, FD_CLOEXEC);
      fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK);
      inst->inbox.pipe_w = fds[1];
      return NULL;
    }
    close(fds[0]);
    close(fds[1]);
  }
  char fifo[64];
  int w;
  if (!private_fifo(fifo, sizeof fifo, &w)) return "could not create the stdin pipe";
  int opened = wasi_config_set_stdin_file(cfg, fifo);
  private_fifo_remove(fifo);
  if (!opened) {
    close(w);
    return "could not open the stdin pipe";
  }
  inst->inbox.pipe_w = w;
  return NULL;
}
#endif

/* Writes all of buf unless the pump is told to stop. 0 when the pipe is
 * gone (the guest's store was freed) or the pump must stop. */
static int pump_write(instance_t *inst, int fd, const unsigned char *buf, size_t n) {
  size_t done = 0;
  while (done < n) {
    if (__atomic_load_n(&inst->inbox.pump_abort, __ATOMIC_ACQUIRE)) return 0;
    ssize_t w = write(fd, buf + done, n - done);
    if (w > 0) {
      done += (size_t)w;
    } else if (w < 0 && errno == EAGAIN) {
      /* full: the guest is not reading; look again, and at pump_abort */
      struct pollfd p = {.fd = fd, .events = POLLOUT};
      poll(&p, 1, 20);
    } else if (!(w < 0 && errno == EINTR)) {
      return 0;
    }
  }
  return 1;
}

static void *pump_main(void *arg) {
  instance_t *inst = arg;
  unsigned char *buf = enif_alloc(65536);
  pthread_mutex_lock(&inst->mu);
  int fd = inst->inbox.pipe_w;
  for (;;) {
    while (!inst->inbox.head && !inst->inbox.closed && !inst->inbox.pump_abort)
      pthread_cond_wait(&inst->cv, &inst->mu);
    if (inst->inbox.pump_abort || !inst->inbox.head) break; /* stopped, or closed and drained */
    /* Copied out under the mutex: erlang.recv may take chunks meanwhile. */
    chunk_t *c = inst->inbox.head;
    size_t n = c->len - c->off;
    if (n > 65536) n = 65536;
    memcpy(buf, c->data + c->off, n);
    c->off += n;
    inst->inbox.bytes -= n;
    if (c->off == c->len) inbox_drop_head(inst);
    pthread_mutex_unlock(&inst->mu);
    int ok = pump_write(inst, fd, buf, n);
    pthread_mutex_lock(&inst->mu);
    if (!ok) break;
  }
  inst->inbox.pipe_w = -1;
  inst->inbox.closed = 1;
  pthread_mutex_unlock(&inst->mu);
  close(fd); /* end of file for the guest */
  enif_free(buf);
  enif_release_resource(inst); /* the pump's reference, taken at start */
  return NULL;
}

/* After a successful instantiate. 0 when the thread could not start: the
 * pipe is closed then, and the guest sees end of file. */
int stdin_pump_start(instance_t *inst) {
  if (inst->inbox.pipe_w < 0) return 1;
  enif_keep_resource(inst);
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_attr_setstacksize(&attr, 256 * 1024);
  pthread_t tid;
  int rc = pthread_create(&tid, &attr, pump_main, inst);
  pthread_attr_destroy(&attr);
  if (rc == 0) return 1;
  enif_release_resource(inst);
  return 0;
}

/* Called with the mutex held when the instance is stopped: its stdin ends
 * now, which also wakes a guest blocked reading it. */
void stdin_abort(instance_t *inst) {
  if (!inst->inbox.stdin) return;
  inst->inbox.closed = 1;
  __atomic_store_n(&inst->inbox.pump_abort, 1, __ATOMIC_RELEASE);
  pthread_cond_broadcast(&inst->cv);
}
