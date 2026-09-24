/* SPDX-License-Identifier: MPL-2.0                                        */
/* Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)                  */
/*   <j.d.a.jewell@open.ac.uk>                                              */
/*                                                                            */
/* zig_api.h — C ABI for the in-repo gnosis server + connector pool          */
/*                                                                            */
/* Declared:   src/abi/Gnosis.idr  (aerie-owned, Idris2 source of truth)     */
/* Implemented: ffi/zig/src/{gnosis,connector}.zig (FFI = Zig, estate law)   */
/*                                                                            */
/* Superset-compatible with developer-ecosystem/zig-api: symbol names, tag  */
/* values and v1 struct layouts match, so the estate library can replace    */
/* this implementation without gateway changes.                              */
/*                                                                            */
/* V2 EXTENSION (aerie): GnosisRequestV2 carries the raw query string and   */
/* the request headers, both of which v1 strips — v1 starves the policy     */
/* gate of X-Api-Key and the resolvers of query parameters.                 */
/*                                                                            */
/* ABI-stable across patch versions. Minor bumps add symbols; major bumps  */
/* may remove them. Layout is asserted against this header by tests.        */

#ifndef ZIG_API_H
#define ZIG_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Version
 * ========================================================================== */

/** Null-terminated version string, e.g. "0.1.0". */
const char *uapi_version(void);

/* ============================================================================
 * Library lifecycle
 * ========================================================================== */

/** One-time initialisation; idempotent. Returns 0 on success. */
uint8_t uapi_init(void);

/** Tear down all servers and connectors; free library-level memory. */
void uapi_teardown(void);

/* ============================================================================
 * Result codes
 * ========================================================================== */

#define UAPI_OK                      0
#define UAPI_ERR                     1
#define UAPI_INVALID_PARAM           2
#define UAPI_OUT_OF_MEMORY           3
#define UAPI_NULL_POINTER            4
#define UAPI_PATH_DENIED             5
#define UAPI_PROCESS_FAILED          6
#define UAPI_TIMEOUT                 7
#define UAPI_NOT_FOUND               8
#define UAPI_ALREADY_EXISTS          9
#define UAPI_SLOT_EXHAUSTED          10

/* ============================================================================
 * ServerState tags
 * ========================================================================== */

#define UAPI_SERVER_IDLE             0
#define UAPI_SERVER_LISTENING        1
#define UAPI_SERVER_DRAINING         2
#define UAPI_SERVER_STOPPED          3

/* ============================================================================
 * HealthStatus tags
 * ========================================================================== */

#define UAPI_HEALTH_SERVING          0
#define UAPI_HEALTH_NOT_SERVING      1

/* ============================================================================
 * ConnectorState tags
 * ========================================================================== */

#define UAPI_CONNECTOR_DISCONNECTED  0
#define UAPI_CONNECTOR_CONNECTING    1
#define UAPI_CONNECTOR_CONNECTED     2
#define UAPI_CONNECTOR_DEGRADED      3
#define UAPI_CONNECTOR_FAILED        4
#define UAPI_CONNECTOR_DRAINING      5

/* ============================================================================
 * ServiceId tags
 * ========================================================================== */

#define UAPI_SERVICE_AMBIENT_OPS     0
#define UAPI_SERVICE_BOJ             1
#define UAPI_SERVICE_BURBLE          2
#define UAPI_SERVICE_ECHIDNA         3
#define UAPI_SERVICE_GOSSAMER        4
#define UAPI_SERVICE_GROOVE_BRIDGE   5
#define UAPI_SERVICE_HYPATIA         6
#define UAPI_SERVICE_IDAPTIK         7
#define UAPI_SERVICE_REPOSYSTEM      8
#define UAPI_SERVICE_STAPELN         9
#define UAPI_SERVICE_VERISIMDB       10

/* ============================================================================
 * HTTP Method tags
 * ========================================================================== */

#define UAPI_METHOD_GET              0
#define UAPI_METHOD_POST             1
#define UAPI_METHOD_PUT              2
#define UAPI_METHOD_DELETE           3
#define UAPI_METHOD_HEAD             4
#define UAPI_METHOD_OPTIONS          5
#define UAPI_METHOD_PATCH            6

/* ============================================================================
 * Gnosis API server  (ffi/zig/src/gnosis.zig)
 * ========================================================================== */

/** Request context for v1 edge handlers (query-stripped, no headers). */
typedef struct {
    const char    *method;    /**< HTTP method, e.g. "GET" (null-terminated). */
    const char    *path;      /**< Request path, query-stripped (null-terminated). */
    const uint8_t *body_ptr;  /**< Request body bytes; NULL when empty. */
    uint32_t       body_len;  /**< Byte length of body_ptr; 0 when empty. */
} GnosisRequest;

/**
 * V2 request context (aerie extension): v1 plus the raw query string and
 * parallel header arrays. All pointers are valid only for the duration of
 * the handler call. `header_names`/`header_values` are NULL when
 * `header_count` is 0; otherwise each has exactly `header_count` entries.
 */
typedef struct {
    const char    *method;         /**< HTTP method, e.g. "GET". */
    const char    *path;           /**< Query-stripped request path. */
    const char    *query;          /**< Raw query without '?'; "" when absent. */
    const uint8_t *body_ptr;       /**< Request body bytes; NULL when empty. */
    uint32_t       body_len;       /**< Byte length of body_ptr. */
    const char *const *header_names;   /**< NULL-terminated name strings, or NULL. */
    const char *const *header_values;  /**< Parallel value strings, or NULL. */
    uint32_t       header_count;   /**< Number of valid header entries. */
    uint8_t       *resp_scratch;   /**< Per-connection response buffer. HANDLERS:
                                        response bodies whose lifetime would end
                                        with the handler (arenas, stacks) MUST be
                                        copied here — the server writes after the
                                        handler returns and frees the scratch. */
    uint32_t       resp_scratch_len; /**< Byte length of resp_scratch. */
} GnosisRequestV2;

/** Response written by an edge handler. */
typedef struct {
    uint16_t       status;        /**< HTTP status code, e.g. 200, 404. */
    uint16_t       _pad;          /**< Reserved; set to 0. */
    const char    *content_type;  /**< MIME type string (null-terminated). */
    const uint8_t *body_ptr;      /**< Response body; NULL for zero-length body. */
    uint32_t       body_len;      /**< Byte length of body_ptr. */
} GnosisResponse;

/** Create a gnosis server bound to `port`. Returns handle (non-zero) or 0. */
uint64_t uapi_gnosis_create(uint16_t port);

/** Start serving (binds on first start; spawns the serve thread). Idempotent. */
uint8_t uapi_gnosis_start(uint64_t handle);

/** Stop accepting, drain in-flight connections, join the serve thread. */
void uapi_gnosis_stop(uint64_t handle);

/** Destroy the handle (stops first if listening). */
void uapi_gnosis_destroy(uint64_t handle);

/** Query server state: a UAPI_SERVER_* tag. */
uint8_t uapi_gnosis_state(uint64_t handle);

/** Health probe: UAPI_HEALTH_SERVING (0) or UAPI_HEALTH_NOT_SERVING (1). */
uint8_t uapi_gnosis_health(uint64_t handle);

/** Register the v1 edge handler. Between create and start only. */
uint8_t uapi_gnosis_set_handler(
    uint64_t      handle,
    void        (*handler_fn)(const GnosisRequest *req, GnosisResponse *resp)
);

/** Register the v2 edge handler (query + headers). Takes precedence over v1. */
uint8_t uapi_gnosis_set_handler_v2(
    uint64_t      handle,
    void        (*handler_fn)(const GnosisRequestV2 *req, GnosisResponse *resp)
);

/** Convenience: fill all fields of a GnosisResponse in one call. */
void uapi_gnosis_write_response(
    GnosisResponse *resp,
    uint16_t        status,
    const char     *content_type,
    const uint8_t  *body_ptr,
    uint32_t        body_len
);

/* ============================================================================
 * Service connector pool  (ffi/zig/src/connector.zig)
 * ========================================================================== */

/** Allocate a connector for `service_id` at `base_url`. Slot index or 255. */
uint8_t uapi_connector_create(uint8_t service_id, const char *base_url);

/** GET /health probe. Returns a UAPI_CONNECTOR_* tag. */
uint8_t uapi_connector_health(uint8_t slot);

/**
 * Synchronous HTTP round-trip on `slot`. On UAPI_OK the response body is
 * copied into `out_buf` (truncated to out_len-1 if larger) and
 * null-terminated. Non-2xx statuses still return UAPI_OK — the body is
 * the payload; only transport failures are errors.
 */
uint8_t uapi_connector_call(
    uint8_t      slot,
    uint8_t      method_tag,
    const char  *path,
    const char  *body,
    uint8_t     *out_buf,
    uint32_t     out_len
);

/** Release the connector at `slot`. */
void uapi_connector_destroy(uint8_t slot);

/** Current UAPI_CONNECTOR_* tag for `slot`. */
uint8_t uapi_connector_state(uint8_t slot);

/* ============================================================================
 * Forensic search engine — UNTRUSTED (ffi/zig/src/kanren.zig)
 *
 * Design: docs/design/forensic-stack.adoc. The engine emits candidate
 * attack paths as flat derivations; the trusted Idris2 kernel
 * (src/abi/Forensics.idr, checkReach) accepts or rejects each against
 * the evidence. A solver bug can only lose answers, never forge one.
 * ========================================================================== */

/** Rule tags for RawStep. */
#define KANREN_RULE_LATERAL 0
#define KANREN_RULE_EXFIL   1
#define KANREN_RULE_ENTRY   2

/** One raw step: a rule applied to a fact-id. Untrusted until checked. */
typedef struct {
    uint32_t fact_id; /**< Index into the evidence table. */
    uint8_t  rule;    /**< KANREN_RULE_*. */
    uint8_t  _pad;
    uint16_t _pad2;
} RawStep;

/** A candidate derivation (flat step list). Arena-owned until kanren_free. */
typedef struct {
    const RawStep *steps; /**< NULL when len is 0. */
    uint32_t       len;
} RawDeriv;

/** Add one observed flow to the evidence table. Fact-id or 0xFFFFFFFF. */
uint32_t kanren_add_flow(
    const char *src,
    const char *dst,
    uint16_t    port,
    uint64_t    bytes
);

/** Clear the evidence table and release the derivation arena. */
void kanren_clear(void);

/** Release the derivation arena; callers hold nothing after this. */
void kanren_free(void);

/**
 * Depth-bounded search: candidate paths from `src` ending in an exfil
 * step. On return, *out points at an arena-owned RawDeriv array (valid
 * until kanren_free). Returns the count. A count of 0 means "no
 * candidate within budget" — distinct from "no path exists"; max_depth
 * is a declared resource grade on the query (tropical budget seam).
 */
uint32_t kanren_attack_paths(
    const char        *src,
    const RawDeriv   **out,
    uint32_t           max_depth
);

#ifdef __cplusplus
}
#endif

#endif /* ZIG_API_H */
