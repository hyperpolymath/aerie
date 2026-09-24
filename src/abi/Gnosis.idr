||| SPDX-License-Identifier: MPL-2.0
||| Gnosis server + service-connector C ABI for AERIE.
|||
||| Declared here (ABI = Idris2), implemented in `ffi/zig/` (FFI = Zig).
||| The surface is superset-compatible with developer-ecosystem/zig-api:
||| symbol names, tag values and v1 struct layouts match, so the estate
||| library can replace the in-repo implementation without gateway changes.
|||
||| The **V2 request** is an aerie extension: v1 strips the query string
||| and exposes no headers, which starves the policy gate of `X-Api-Key`
||| and the resolvers of query parameters. V2 carries both, plus the
||| query separately from the path.

module Aerie.ABI.Gnosis

import Aerie.ABI.Types

%default total

--------------------------------------------------------------------------------
-- Tags (values are fixed by the C ABI; see ffi/zig/include/zig_api.h)
--------------------------------------------------------------------------------

||| Server lifecycle states.
public export
data ServerState = SrvIdle | SrvListening | SrvDraining | SrvStopped

||| Connector lifecycle states.
public export
data ConnectorState = CnDisconnected | CnConnecting | CnConnected
                    | CnDegraded | CnFailed | CnDraining

||| Service identity tags for the connector pool.
public export
data ServiceId = AmbientOps | Boj | Burble | Echidna | Gossamer
               | GrooveBridge | Hypatia | Idaptik | Reposystem
               | Stapeln | VerisimDB

||| HTTP method tags (wire order is fixed by the ABI).
public export
data MethodTag = MGet | MPost | MPut | MDelete | MHead | MOptions | MPatch

--------------------------------------------------------------------------------
-- Wire structures
--------------------------------------------------------------------------------

||| V1 edge request. Kept for ABI compatibility; strips query + headers.
public export
record GnosisRequest where
  constructor MkGnosisRequest
  ||| HTTP method, null-terminated.
  reqMethod : Bits64
  ||| Query-stripped path, null-terminated.
  reqPath   : Bits64
  ||| Body bytes; 0 when empty.
  reqBody   : Bits64
  reqBodyLen: Bits32

||| V2 edge request: v1 plus the raw query (no `?`) and parallel
||| header name/value arrays. `headerCount` entries are valid; the
||| arrays themselves are NULL when `headerCount` is 0.
public export
record GnosisRequestV2 where
  constructor MkGnosisRequestV2
  reqV2Method      : Bits64
  ||| Query-stripped path.
  reqV2Path        : Bits64
  ||| Raw query string without the leading `?`; empty string when absent.
  reqV2Query       : Bits64
  reqV2Body        : Bits64
  reqV2BodyLen     : Bits32
  ||| NULL-terminated C-string arrays, length `reqV2HeaderCount`.
  reqV2HeaderNames : Bits64
  reqV2HeaderValues: Bits64
  reqV2HeaderCount : Bits32

||| Edge response written by a handler; flushed by the server loop.
public export
record GnosisResponse where
  constructor MkGnosisResponse
  respStatus      : Bits16
  respPad         : Bits16
  respContentType : Bits64
  respBody        : Bits64
  respBodyLen     : Bits32

--------------------------------------------------------------------------------
-- Library lifecycle
--------------------------------------------------------------------------------

||| One-time library init. Idempotent. 0 = ok.
export
%foreign "C:uapi_init, libzig_api"
prim__uapiInit : PrimIO Bits8

||| Tear down servers + connectors and free library memory.
export
%foreign "C:uapi_teardown, libzig_api"
prim__uapiTeardown : PrimIO ()

||| Null-terminated library version string.
export
%foreign "C:uapi_version, libzig_api"
prim__uapiVersion : PrimIO Bits64

--------------------------------------------------------------------------------
-- Gnosis server pool
--------------------------------------------------------------------------------

||| Reserve a server slot for `port`; handle is non-zero on success.
export
%foreign "C:uapi_gnosis_create, libzig_api"
prim__gnosisCreate : Bits16 -> PrimIO Bits64

||| Bind (if needed) and start the serve thread. Idempotent.
export
%foreign "C:uapi_gnosis_start, libzig_api"
prim__gnosisStart : Bits64 -> PrimIO Bits8

||| Stop accepting, drain in-flight connections, join the thread.
export
%foreign "C:uapi_gnosis_stop, libzig_api"
prim__gnosisStop : Bits64 -> PrimIO ()

||| Destroy the handle (stops first if listening).
export
%foreign "C:uapi_gnosis_destroy, libzig_api"
prim__gnosisDestroy : Bits64 -> PrimIO ()

||| Current ServerState tag.
export
%foreign "C:uapi_gnosis_state, libzig_api"
prim__gnosisState : Bits64 -> PrimIO Bits8

||| 0 = serving, 1 = not serving.
export
%foreign "C:uapi_gnosis_health, libzig_api"
prim__gnosisHealth : Bits64 -> PrimIO Bits8

||| Register the v1 edge handler (query-stripped, no headers).
||| Must be called between create and start.
export
%foreign "C:uapi_gnosis_set_handler, libzig_api"
prim__gnosisSetHandler : Bits64 -> AnyPtr -> PrimIO Bits8

||| Register the v2 edge handler (query + headers carried).
||| Takes precedence over the v1 handler when both are set.
export
%foreign "C:uapi_gnosis_set_handler_v2, libzig_api"
prim__gnosisSetHandlerV2 : Bits64 -> AnyPtr -> PrimIO Bits8

||| Convenience: fill a GnosisResponse in one call.
export
%foreign "C:uapi_gnosis_write_response, libzig_api"
prim__gnosisWriteResponse
  : Bits64 -> Bits16 -> Bits64 -> Bits64 -> Bits32 -> PrimIO ()

--------------------------------------------------------------------------------
-- Service connector pool
--------------------------------------------------------------------------------

||| Allocate a connector for `serviceId` at `baseUrl`.
||| Returns the slot index, or 255 on failure.
export
%foreign "C:uapi_connector_create, libzig_api"
prim__connectorCreate : Bits8 -> Bits64 -> PrimIO Bits8

||| GET /health probe; returns a ConnectorState tag.
export
%foreign "C:uapi_connector_health, libzig_api"
prim__connectorHealth : Bits8 -> PrimIO Bits8

||| Perform an HTTP round-trip on the slot. 0 = ok (body copied,
||| null-terminated, into the caller buffer); non-zero = transport error.
export
%foreign "C:uapi_connector_call, libzig_api"
prim__connectorCall
  : Bits8 -> Bits8 -> Bits64 -> Bits64 -> Bits64 -> Bits32 -> PrimIO Bits8

||| Release the slot.
export
%foreign "C:uapi_connector_destroy, libzig_api"
prim__connectorDestroy : Bits8 -> PrimIO ()

||| Current ConnectorState tag for the slot.
export
%foreign "C:uapi_connector_state, libzig_api"
prim__connectorState : Bits8 -> PrimIO Bits8
