/*
 * nif_serve.c: One HTTP request given to a component's wasi:http handler.
 * The response reaches Erlang as it is made, through host_exchange: the
 * guest waits while the caller takes each part.
 */
#include "nif.h"

#if NIF_HAVE_ASYNC_API && defined(WASMTIME_FEATURE_WASI_HTTP)

/* An unpatched library's headers lack these: wasmtime/component/serve.h. */
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

#else

int serve_available(void) {
  return 0;
}

#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
ERL_NIF_TERM serve_component(instance_t *inst, req_t *req, ERL_NIF_TERM request, ErlNifEnv *out) {
  (void)inst, (void)req, (void)request;
  return mk_error_s(out, "link", "unavailable", "this library cannot serve HTTP requests");
}
#endif

#endif
