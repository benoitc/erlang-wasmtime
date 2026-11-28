/*
 * nif_net.c: What the network grants and the per-store limits need from this
 * project's patches: address rules for sockets and outgoing HTTP, the initial
 * directory, and the caps on WASI resources, copied data, headers and
 * response bodies.
 */
#include "nif.h"

#if NIF_HAVE_WASI

/* Weak: null with a library built without the patches. */
#ifndef WASI_HAS_NET_RULES
typedef struct wasi_net_rule_t {
  uint8_t udp, listen, is_v6, prefix;
  uint16_t port_lo, port_hi;
  uint8_t addr[16];
} wasi_net_rule_t;
#endif
extern void wasi_config_allow_tcp(wasi_config_t *, bool) __attribute__((weak));
extern void wasi_config_allow_udp(wasi_config_t *, bool) __attribute__((weak));
extern void wasi_config_set_net_rules(wasi_config_t *, const wasi_net_rule_t *, size_t)
    __attribute__((weak));
extern bool wasi_config_set_initial_cwd(wasi_config_t *, const char *) __attribute__((weak));
#ifdef WASMTIME_FEATURE_WASI_HTTP
extern bool wasmtime_context_deny_wasi_http_names(wasmtime_context_t *) __attribute__((weak));
extern bool wasmtime_context_limit_wasi_http(wasmtime_context_t *, const wasi_net_rule_t *, size_t,
                                             bool, size_t, uint64_t) __attribute__((weak));
#endif
#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
extern bool wasmtime_context_set_max_wasi_resources(wasmtime_context_t *, size_t)
    __attribute__((weak));
extern void wasmtime_context_set_hostcall_fuel(wasmtime_context_t *, size_t) __attribute__((weak));
#endif

/* A grant as wasmtime_net:grant/1 makes it: none | all | {rules, Tcp, Udp,
 * Resolve, [{Udp, Listen, Address, Prefix, FirstPort, LastPort}]}. Fills `g`
 * (free it with net_grant_free); 0 when the term is none of these. */
int net_grant(ErlNifEnv *env, ERL_NIF_TERM term, net_grant_t *g) {
  memset(g, 0, sizeof *g);
  if (enif_is_identical(term, atom_none)) return 1;
  if (enif_is_identical(term, atom_all)) {
    g->kind = NET_ALL;
    return 1;
  }
  const ERL_NIF_TERM *t;
  int arity;
  unsigned n;
  if (!enif_get_tuple(env, term, &arity, &t) || arity != 5 || !enif_get_list_length(env, t[4], &n))
    return 0;
  g->kind = NET_RULES;
  g->tcp = enif_is_identical(t[1], atom_true);
  g->udp = enif_is_identical(t[2], atom_true);
  g->resolve = enif_is_identical(t[3], atom_true);
  wasi_net_rule_t *rules = enif_alloc((n ? n : 1) * sizeof *rules);
  g->rules = rules;
  ERL_NIF_TERM h, l = t[4];
  while (enif_get_list_cell(env, l, &h, &l)) {
    const ERL_NIF_TERM *r;
    ErlNifBinary addr;
    unsigned udp, listen, prefix, lo, hi;
    if (!enif_get_tuple(env, h, &arity, &r) || arity != 6 || !enif_get_uint(env, r[0], &udp) ||
        !enif_get_uint(env, r[1], &listen) || !enif_inspect_binary(env, r[2], &addr) ||
        (addr.size != 4 && addr.size != 16) || !enif_get_uint(env, r[3], &prefix) ||
        prefix > addr.size * 8 || !enif_get_uint(env, r[4], &lo) || lo > 65535 ||
        !enif_get_uint(env, r[5], &hi) || hi > 65535) {
      net_grant_free(g);
      return 0;
    }
    wasi_net_rule_t *rule = &rules[g->len++];
    memset(rule, 0, sizeof *rule);
    rule->udp = udp != 0;
    rule->listen = listen != 0;
    rule->is_v6 = addr.size == 16;
    rule->prefix = (uint8_t)prefix;
    rule->port_lo = (uint16_t)lo;
    rule->port_hi = (uint16_t)hi;
    memcpy(rule->addr, addr.data, addr.size);
  }
  return 1;
}

void net_grant_free(net_grant_t *g) {
  enif_free(g->rules);
  g->rules = NULL;
  g->len = 0;
}

#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
/* Opens wasi:sockets to what the grant allows. The caller checks
 * sockets_available() for any grant and limits_available() for rules. */
void net_grant_sockets(wasi_config_t *cfg, const net_grant_t *g) {
  if (g->kind == NET_NONE) return;
  if (g->kind == NET_ALL) {
    wasi_config_inherit_network(cfg);
  } else {
    wasi_config_set_net_rules(cfg, g->rules, g->len);
  }
  wasi_config_allow_ip_name_lookup(cfg, g->kind == NET_ALL || g->resolve);
  wasi_config_allow_tcp(cfg, g->kind == NET_ALL || g->tcp);
  wasi_config_allow_udp(cfg, g->kind == NET_ALL || g->udp);
}
#endif

int initial_cwd(wasi_config_t *cfg, const char *path) {
  return wasi_config_set_initial_cwd != NULL && wasi_config_set_initial_cwd(cfg, path);
}

/* After wasmtime_context_set_wasi_http. 0 when the library cannot. A grant
 * without `resolve` refuses host names, and a library that cannot refuse them
 * is not given the grant. */
int limit_http(wasmtime_context_t *ctx, const net_grant_t *g, uint64_t max_field_bytes,
               uint64_t max_body_bytes) {
  if (g->kind != NET_RULES && !max_field_bytes && !max_body_bytes) return 1;
#ifdef WASMTIME_FEATURE_WASI_HTTP
  if (wasmtime_context_limit_wasi_http == NULL ||
      !wasmtime_context_limit_wasi_http(ctx, g->rules, g->len, g->kind == NET_RULES,
                                        (size_t)max_field_bytes, max_body_bytes))
    return 0;
  if (g->kind != NET_RULES || g->resolve) return 1;
  return wasmtime_context_deny_wasi_http_names != NULL &&
         wasmtime_context_deny_wasi_http_names(ctx);
#else
  (void)ctx;
  return 0;
#endif
}

#endif /* NIF_HAVE_WASI */

int limits_available(void) {
#if NIF_HAVE_WASI
  return wasi_config_set_net_rules != NULL;
#else
  return 0;
#endif
}

/* Whether the library has the socket switches: TCP and UDP are off in
 * Wasmtime's own builder. */
int sockets_available(void) {
#if NIF_HAVE_WASI && defined(WASMTIME_FEATURE_COMPONENT_MODEL)
  return wasi_config_allow_tcp != NULL && wasi_config_allow_udp != NULL;
#else
  return 0;
#endif
}

/* `resource_limit` and `transfer_limit` of a component, -1 when not given.
 * The WASI resource table exists only with `wasi`. 0 when the library
 * cannot. */
int limit_component_store(wasmtime_context_t *ctx, int wasi, int64_t resources, int64_t transfer) {
  if (resources < 0 && transfer < 0) return 1;
#if NIF_HAVE_WASI && defined(WASMTIME_FEATURE_COMPONENT_MODEL)
  if (wasmtime_context_set_hostcall_fuel == NULL) return 0;
  if (transfer >= 0) wasmtime_context_set_hostcall_fuel(ctx, (size_t)transfer);
  if (resources >= 0 && wasi) wasmtime_context_set_max_wasi_resources(ctx, (size_t)resources);
  return 1;
#else
  (void)ctx, (void)wasi;
  return 0;
#endif
}
