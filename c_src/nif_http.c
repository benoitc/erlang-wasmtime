/*
 * nif_http.c: HTTP to and from a component. One request given to its
 * wasi:http handler, whose response reaches Erlang as it is made, through
 * host_exchange: the guest waits while the caller takes each part. And the
 * requests it sends, handed to a transport in Erlang and answered later.
 */
#include "nif.h"

#if NIF_HAVE_ASYNC_API && defined(WASMTIME_FEATURE_WASI_HTTP)

/* An unpatched library's headers lack these: wasmtime/component/serve.h.
 * Patch 0007 adds the transport's to the same header. */
#ifndef WASMTIME_COMPONENT_SERVE_H
typedef struct wasmtime_http_field_t {
  const uint8_t *name;
  size_t name_len;
  const uint8_t *value;
  size_t value_len;
} wasmtime_http_field_t;
typedef struct wasmtime_http_request_t {
  const uint8_t *method;
  size_t method_len;
  const uint8_t *scheme;
  size_t scheme_len;
  const uint8_t *authority;
  size_t authority_len;
  const uint8_t *path;
  size_t path_len;
  const wasmtime_http_field_t *headers;
  size_t headers_len;
  const uint8_t *body;
  size_t body_len;
  const wasmtime_http_field_t *trailers;
  size_t trailers_len;
} wasmtime_http_request_t;
typedef struct wasmtime_http_sink_t {
  void *data;
  bool (*head)(void *data, uint16_t status, const wasmtime_http_field_t *headers,
               size_t headers_len);
  bool (*chunk)(void *data, const uint8_t *bytes, size_t len);
  bool (*done)(void *data, const wasmtime_http_field_t *trailers, size_t trailers_len);
} wasmtime_http_sink_t;
typedef enum wasmtime_http_outcome_t {
  WASMTIME_HTTP_SERVED = 0,
  WASMTIME_HTTP_NO_HANDLER,
  WASMTIME_HTTP_NO_RESPONSE,
  WASMTIME_HTTP_ERROR_CODE,
  WASMTIME_HTTP_STOPPED,
  WASMTIME_HTTP_BAD_REQUEST,
} wasmtime_http_outcome_t;
typedef struct wasmtime_http_result_t {
  wasmtime_http_outcome_t outcome;
  bool p3;
  wasm_byte_vec_t detail;
} wasmtime_http_result_t;
#endif

/* Weak: null with a library built without the patch. */
extern wasmtime_error_t *wasmtime_component_serve_http_blocking(
    wasmtime_context_t *context, const wasmtime_component_instance_t *instance,
    const wasmtime_http_request_t *request, const wasmtime_http_sink_t *sink,
    const wasmtime_cancel_t *cancel, wasmtime_http_result_t *result) __attribute__((weak));

#ifndef WASMTIME_HAS_HTTP_TRANSPORT
typedef struct wasmtime_http_outgoing_t {
  const uint8_t *method;
  size_t method_len;
  const uint8_t *scheme;
  size_t scheme_len;
  const uint8_t *host;
  size_t host_len;
  const uint8_t *address;
  size_t address_len;
  uint16_t port;
  const uint8_t *path;
  size_t path_len;
  const wasmtime_http_field_t *headers;
  size_t headers_len;
  const uint8_t *body;
  size_t body_len;
  uint64_t connect_timeout_ms;
  uint64_t first_byte_timeout_ms;
  uint64_t between_bytes_timeout_ms;
} wasmtime_http_outgoing_t;
typedef struct wasmtime_http_responder_t wasmtime_http_responder_t;
typedef void (*wasmtime_http_transport_t)(void *data, const wasmtime_http_outgoing_t *request,
                                          wasmtime_http_responder_t *responder);
#endif

extern void wasmtime_http_responder_respond(wasmtime_http_responder_t *responder, uint16_t status,
                                            const wasmtime_http_field_t *headers,
                                            size_t headers_len, const uint8_t *body,
                                            size_t body_len) __attribute__((weak));
extern void wasmtime_http_responder_fail(wasmtime_http_responder_t *responder, const uint8_t *name,
                                         size_t name_len, bool has_size, uint64_t size,
                                         const uint8_t *text, size_t text_len)
    __attribute__((weak));
extern void wasmtime_http_responder_delete(wasmtime_http_responder_t *responder)
    __attribute__((weak));
extern bool wasmtime_context_set_wasi_http_transport(wasmtime_context_t *context,
                                                     wasmtime_http_transport_t callback, void *data,
                                                     void (*finalizer)(void *))
    __attribute__((weak));

int serve_available(void) {
  return async_available() && wasmtime_component_serve_http_blocking != NULL;
}

/* Sends one part of the response to the caller and waits, as long as the call
 * lasts, for {ok, Continue}. `part` lives in `menv`, consumed here. False ends
 * the call: the caller said so, or the request is ending. */
static bool emit(instance_t *inst, ErlNifEnv *menv, ERL_NIF_TERM part) {
  static hostfn_t events = {.module = "$http", .name = "response", .event = 1};
  const char *fail = NULL;
  ERL_NIF_TERM go;
  enum host_status st = host_exchange(inst, &events, menv, enif_make_list1(menv, part), &go, &fail);
  bool more = st == HOST_OK && enif_is_identical(go, atom_true);
  pthread_mutex_unlock(&inst->mu);
  wasm_trap_t *trap = host_outcome(inst, &events, st, fail, NULL);
  if (trap) wasm_trap_delete(trap); /* the flags it set are what is read */
  return more;
}

/* [{Name, Value}] */
static ERL_NIF_TERM fields_term(ErlNifEnv *env, const wasmtime_http_field_t *f, size_t n) {
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = n; i > 0; i--) {
    ERL_NIF_TERM pair = enif_make_tuple2(env, mk_binary(env, f[i - 1].name, f[i - 1].name_len),
                                         mk_binary(env, f[i - 1].value, f[i - 1].value_len));
    list = enif_make_list_cell(env, pair, list);
  }
  return list;
}

static bool on_head(void *data, uint16_t status, const wasmtime_http_field_t *f, size_t n) {
  ErlNifEnv *env = enif_alloc_env();
  return emit(data, env,
              enif_make_tuple3(env, mk_atom(env, "head"), enif_make_uint(env, status),
                               fields_term(env, f, n)));
}

static bool on_chunk(void *data, const uint8_t *bytes, size_t len) {
  ErlNifEnv *env = enif_alloc_env();
  return emit(data, env, enif_make_tuple2(env, mk_atom(env, "chunk"), mk_binary(env, bytes, len)));
}

static bool on_done(void *data, const wasmtime_http_field_t *f, size_t n) {
  ErlNifEnv *env = enif_alloc_env();
  return emit(data, env, enif_make_tuple2(env, mk_atom(env, "done"), fields_term(env, f, n)));
}

/* The fields of [{Name, Value}], pointing into `env`'s binaries. NULL when
 * the term is not that; free with enif_free. */
static wasmtime_http_field_t *fields_of(ErlNifEnv *env, ERL_NIF_TERM list, size_t *len) {
  unsigned n;
  if (!enif_get_list_length(env, list, &n)) return NULL;
  wasmtime_http_field_t *f = enif_alloc((n ? n : 1) * sizeof *f);
  ERL_NIF_TERM h;
  for (unsigned i = 0; i < n && enif_get_list_cell(env, list, &h, &list); i++) {
    const ERL_NIF_TERM *pair;
    int arity;
    ErlNifBinary name, value;
    if (!enif_get_tuple(env, h, &arity, &pair) || arity != 2 ||
        !enif_inspect_binary(env, pair[0], &name) || !enif_inspect_binary(env, pair[1], &value)) {
      enif_free(f);
      return NULL;
    }
    f[i] = (wasmtime_http_field_t){name.data, name.size, value.data, value.size};
  }
  *len = n;
  return f;
}

/* `request` is {Method, Scheme, Authority, Path, Headers, Body, Trailers}.
 * {ok, {Outcome, p2 | p3, Detail}}, or the error the call ended with. */
ERL_NIF_TERM serve_component(instance_t *inst, req_t *req, ERL_NIF_TERM request, ErlNifEnv *out) {
  ErlNifEnv *env = req->env;
  if (!serve_available())
    return mk_error_s(out, "link", "unavailable", "this library cannot serve HTTP requests");
  const ERL_NIF_TERM *t;
  int arity;
  ErlNifBinary b[5]; /* method, scheme, authority, path, body */
  wasmtime_http_request_t r = {0};
  wasmtime_http_field_t *headers = NULL, *trailers = NULL;
  if (!enif_get_tuple(env, request, &arity, &t) || arity != 7 ||
      !enif_inspect_binary(env, t[0], &b[0]) || !enif_inspect_binary(env, t[1], &b[1]) ||
      !enif_inspect_binary(env, t[2], &b[2]) || !enif_inspect_binary(env, t[3], &b[3]) ||
      !enif_inspect_binary(env, t[5], &b[4]) || !(headers = fields_of(env, t[4], &r.headers_len)) ||
      !(trailers = fields_of(env, t[6], &r.trailers_len))) {
    enif_free(headers);
    return mk_error_s(out, "link", "badarg", "the HTTP request is malformed");
  }
  r.method = b[0].data, r.method_len = b[0].size;
  r.scheme = b[1].data, r.scheme_len = b[1].size;
  r.authority = b[2].data, r.authority_len = b[2].size;
  r.path = b[3].data, r.path_len = b[3].size;
  r.body = b[4].data, r.body_len = b[4].size;
  r.headers = headers;
  r.trailers = trailers;

  ERL_NIF_TERM result = component_arm(inst, req, out);
  if (!result) {
    wasmtime_http_sink_t sink = {inst, on_head, on_chunk, on_done};
    wasmtime_http_result_t served;
    memset(&served, 0, sizeof served);
    wasmtime_error_t *e = wasmtime_component_serve_http_blocking(
        inst->wasm.ctx, &inst->wasm.cinst, &r, &sink, inst->wasm.cancel, &served);
    int failed = e != NULL;
    note_cancel(inst, e);
    result = outcome(inst, out, e, NULL, "call_failed");
    if (enif_is_identical(result, atom_ok)) {
      static const char *const names[] = {"served",     "no_handler", "no_response",
                                          "error_code", "stopped",    "bad_request"};
      /* Any other end may leave the guest suspended inside the request, so it
       * runs no more code in this store. */
      if (served.outcome != WASMTIME_HTTP_SERVED && served.outcome != WASMTIME_HTTP_NO_HANDLER &&
          served.outcome != WASMTIME_HTTP_BAD_REQUEST)
        inst->wasm.cancelled = 1;
      result = enif_make_tuple2(
          out, atom_ok,
          enif_make_tuple3(out, mk_atom(out, names[served.outcome]),
                           mk_atom(out, served.p3 ? "p3" : "p2"),
                           mk_binary(out, served.detail.data, served.detail.size)));
    } else if (!failed) {
      inst->wasm.cancelled = 1; /* interrupted between two parts */
    }
    if (!failed) wasm_byte_vec_delete(&served.detail);
  }
  enif_free(headers);
  enif_free(trailers);
  return result;
}

/* ------------------------------------------------- outgoing requests -- */

/* Who gets a store's outgoing requests. The library calls back on any thread,
 * for as long as the store holds the channel, so it refers to nothing of the
 * instance. */
typedef struct http_channel {
  pthread_mutex_t mu;
  ErlNifPid target;
  ErlNifEnv *env; /* owns ref, the instance's */
  ERL_NIF_TERM ref;
} http_channel_t;

/* One request waiting for http_reply/2; NULL once answered. */
typedef struct {
  wasmtime_http_responder_t *responder;
} reply_t;

/* An unanswered request whose term is gone fails. */
void reply_dtor(ErlNifEnv *env, void *obj) {
  reply_t *r = obj;
  if (r->responder) wasmtime_http_responder_delete(r->responder);
}

static ERL_NIF_TERM bytes_term(ErlNifEnv *env, const uint8_t *p, size_t len) {
  return mk_binary(env, p, len);
}

static ERL_NIF_TERM timeout_term(ErlNifEnv *env, uint64_t ms) {
  return ms == UINT64_MAX ? atom_undefined : enif_make_uint64(env, ms);
}

/* Sends {wasmtime_http_request, Ref, Reply, Request}, Request being
 * {Method, Scheme, Host, Address, Port, Path, Headers, Body, ConnectTimeout,
 * FirstByteTimeout, BetweenBytesTimeout}. Never blocks. */
static void on_request(void *data, const wasmtime_http_outgoing_t *r,
                       wasmtime_http_responder_t *responder) {
  http_channel_t *ch = data;
  reply_t *reply = enif_alloc_resource(reply_type, sizeof *reply);
  reply->responder = responder;
  ErlNifEnv *env = enif_alloc_env();
  ERL_NIF_TERM t[11] = {bytes_term(env, r->method, r->method_len),
                        bytes_term(env, r->scheme, r->scheme_len),
                        bytes_term(env, r->host, r->host_len),
                        bytes_term(env, r->address, r->address_len),
                        enif_make_uint(env, r->port),
                        bytes_term(env, r->path, r->path_len),
                        fields_term(env, r->headers, r->headers_len),
                        bytes_term(env, r->body, r->body_len),
                        timeout_term(env, r->connect_timeout_ms),
                        timeout_term(env, r->first_byte_timeout_ms),
                        timeout_term(env, r->between_bytes_timeout_ms)};
  pthread_mutex_lock(&ch->mu);
  ErlNifPid target = ch->target;
  ERL_NIF_TERM ref = enif_make_copy(env, ch->ref);
  pthread_mutex_unlock(&ch->mu);
  ERL_NIF_TERM msg =
      enif_make_tuple4(env, mk_atom(env, "wasmtime_http_request"), ref,
                       enif_make_resource(env, reply), enif_make_tuple_from_array(env, t, 11));
  /* the message holds the resource now; if it is not delivered, freeing the
   * environment drops the last reference and the request fails */
  enif_release_resource(reply);
  enif_send(NULL, &target, env, msg);
  enif_free_env(env);
}

static void channel_free(void *data) {
  http_channel_t *ch = data;
  pthread_mutex_destroy(&ch->mu);
  enif_free_env(ch->env);
  enif_free(ch);
}

int transport_available(void) {
  return serve_available() && wasmtime_context_set_wasi_http_transport != NULL;
}

/* After limit_http. 0 when the library cannot. */
int set_transport(instance_t *inst, const ErlNifPid *target) {
  if (!transport_available()) return 0;
  http_channel_t *ch = enif_alloc(sizeof *ch);
  pthread_mutex_init(&ch->mu, NULL);
  ch->target = *target;
  ch->env = enif_alloc_env();
  ch->ref = enif_make_copy(ch->env, inst->ref);
  /* consumes ch, also when it refuses */
  if (!wasmtime_context_set_wasi_http_transport(inst->wasm.ctx, on_request, ch, channel_free))
    return 0;
  inst->wasm.transport = ch;
  return 1;
}

/* Who runs the transport for the request about to run. */
void transport_target(instance_t *inst, const ErlNifPid *target) {
  http_channel_t *ch = inst->wasm.transport;
  if (!ch) return;
  pthread_mutex_lock(&ch->mu);
  ch->target = *target;
  pthread_mutex_unlock(&ch->mu);
}

/* http_reply(Reply, {ok, Status, Headers, Body} | {error, Code, Size, Text})
 * -> ok | answered. Code is the WIT name, Size an integer or none. */
ERL_NIF_TERM nif_http_reply(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  reply_t *reply;
  const ERL_NIF_TERM *t;
  int arity;
  if (!transport_available() || !enif_get_resource(env, argv[0], reply_type, (void **)&reply) ||
      !enif_get_tuple(env, argv[1], &arity, &t) || arity != 4)
    return enif_make_badarg(env);
  unsigned status = 0;
  ErlNifBinary body, name, text;
  wasmtime_http_field_t *headers = NULL;
  size_t n = 0;
  ErlNifUInt64 size = 0;
  int ok = enif_is_identical(t[0], atom_ok), has_size = 0;
  if (ok) {
    if (!enif_get_uint(env, t[1], &status) || status > UINT16_MAX ||
        !enif_inspect_binary(env, t[3], &body) || !(headers = fields_of(env, t[2], &n)))
      return enif_make_badarg(env);
  } else {
    has_size = enif_get_uint64(env, t[2], &size);
    if (!enif_inspect_binary(env, t[1], &name) || !enif_inspect_binary(env, t[3], &text))
      return enif_make_badarg(env);
  }
  /* one answer, whoever holds the term */
  wasmtime_http_responder_t *responder =
      __atomic_exchange_n(&reply->responder, NULL, __ATOMIC_ACQ_REL);
  if (responder && ok)
    wasmtime_http_responder_respond(responder, (uint16_t)status, headers, n, body.data, body.size);
  else if (responder)
    wasmtime_http_responder_fail(responder, name.data, name.size, has_size, has_size ? size : 0,
                                 text.data, text.size);
  enif_free(headers);
  return responder ? atom_ok : mk_atom(env, "answered");
}

#else

int serve_available(void) {
  return 0;
}

int transport_available(void) {
  return 0;
}

int set_transport(instance_t *inst, const ErlNifPid *target) {
  (void)inst, (void)target;
  return 0;
}

void transport_target(instance_t *inst, const ErlNifPid *target) {
  (void)inst, (void)target;
}

void reply_dtor(ErlNifEnv *env, void *obj) {
  (void)env, (void)obj;
}

ERL_NIF_TERM nif_http_reply(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc, (void)argv;
  return enif_make_badarg(env);
}

#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
ERL_NIF_TERM serve_component(instance_t *inst, req_t *req, ERL_NIF_TERM request, ErlNifEnv *out) {
  (void)inst, (void)req, (void)request;
  return mk_error_s(out, "link", "unavailable", "this library cannot serve HTTP requests");
}
#endif

#endif
