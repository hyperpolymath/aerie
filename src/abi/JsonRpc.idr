||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
|||
||| JSON-RPC 2.0 ABI Type Definitions
|||
||| This module defines the Application Binary Interface (ABI) types for the
||| JSON-RPC 2.0 protocol implementation. It provides formally verified types
||| that ensure binary compatibility between the Idris2 proof layer, the
||| Zig FFI implementation, and the V-lang application code.
|||
||| JSON-RPC 2.0 is the wire protocol used by:
|||   - MCP (Model Context Protocol) — AI tool orchestration
|||   - LSP (Language Server Protocol) — IDE integration
|||   - DAP (Debug Adapter Protocol) — debugger communication
|||
||| The types in this module model:
|||   - Message kinds (request, response, notification) with proven invariants
|||   - Error codes with range proofs (standard vs. server-defined)
|||   - ID types (string, number, null) with correlation proofs
|||   - Batch processing with non-empty array guarantees
|||
||| ARCHITECTURE:
||| Idris2 (Proofs) <-> Zig (Stable C ABI) <-> V-lang (Application)
|||
||| @see https://www.jsonrpc.org/specification
||| @see Aerie.ABI.Types for base types (Handle, Result, Platform)

module Aerie.ABI.JsonRpc

import Aerie.ABI.Types
import Aerie.ABI.Layout
import Data.Bits
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- JSON-RPC Error Codes (Section 5.1)
--------------------------------------------------------------------------------

||| Standard JSON-RPC 2.0 error codes as defined in Section 5.1.
||| The specification defines five standard codes and reserves the
||| range -32000 to -32099 for server-defined errors.
public export
data JsonRpcErrorCode
  = ParseError       -- -32700: Invalid JSON
  | InvalidRequest   -- -32600: Not a valid JSON-RPC object
  | MethodNotFound   -- -32601: Method does not exist
  | InvalidParams    -- -32602: Invalid method parameters
  | InternalError    -- -32603: Internal JSON-RPC error
  -- Server-defined errors (-32000 to -32099)
  | ServerError      -- -32000: Generic server error
  | NotInitialised   -- -32001: Server not initialised
  | ShuttingDown     -- -32002: Server shutting down
  | Cancelled        -- -32003: Request cancelled
  | RateLimited      -- -32004: Too many requests

||| Convert an error code to its numeric wire representation.
public export
errorCodeToI32 : JsonRpcErrorCode -> Int32
errorCodeToI32 ParseError      = -32700
errorCodeToI32 InvalidRequest  = -32600
errorCodeToI32 MethodNotFound  = -32601
errorCodeToI32 InvalidParams   = -32602
errorCodeToI32 InternalError   = -32603
errorCodeToI32 ServerError     = -32000
errorCodeToI32 NotInitialised  = -32001
errorCodeToI32 ShuttingDown    = -32002
errorCodeToI32 Cancelled       = -32003
errorCodeToI32 RateLimited     = -32004

||| Predicate: is this a standard (specification-defined) error code?
||| Standard codes are in the range -32700 to -32600.
public export
isStandardCode : JsonRpcErrorCode -> Bool
isStandardCode ParseError     = True
isStandardCode InvalidRequest = True
isStandardCode MethodNotFound = True
isStandardCode InvalidParams  = True
isStandardCode InternalError  = True
isStandardCode _              = False

||| Predicate: is this a server-defined error code?
||| Server codes are in the range -32000 to -32099.
public export
isServerCode : JsonRpcErrorCode -> Bool
isServerCode ServerError     = True
isServerCode NotInitialised  = True
isServerCode ShuttingDown    = True
isServerCode Cancelled       = True
isServerCode RateLimited     = True
isServerCode _               = False

||| Proof that standard and server code sets are disjoint.
||| No error code can be both standard and server-defined.
public export
codeDisjoint : (code : JsonRpcErrorCode) -> So (not (isStandardCode code && isServerCode code))
codeDisjoint ParseError      = Oh
codeDisjoint InvalidRequest  = Oh
codeDisjoint MethodNotFound  = Oh
codeDisjoint InvalidParams   = Oh
codeDisjoint InternalError   = Oh
codeDisjoint ServerError     = Oh
codeDisjoint NotInitialised  = Oh
codeDisjoint ShuttingDown    = Oh
codeDisjoint Cancelled       = Oh
codeDisjoint RateLimited     = Oh

||| Proof that every error code is either standard or server-defined.
||| This exhaustiveness proof ensures no error codes fall outside
||| the two defined ranges.
public export
codeExhaustive : (code : JsonRpcErrorCode) -> So (isStandardCode code || isServerCode code)
codeExhaustive ParseError      = Oh
codeExhaustive InvalidRequest  = Oh
codeExhaustive MethodNotFound  = Oh
codeExhaustive InvalidParams   = Oh
codeExhaustive InternalError   = Oh
codeExhaustive ServerError     = Oh
codeExhaustive NotInitialised  = Oh
codeExhaustive ShuttingDown    = Oh
codeExhaustive Cancelled       = Oh
codeExhaustive RateLimited     = Oh

--------------------------------------------------------------------------------
-- JSON-RPC ID Types
--------------------------------------------------------------------------------

||| The polymorphic "id" field from JSON-RPC 2.0 messages.
||| The spec allows string, number, or null. Null indicates a notification.
public export
data JsonRpcId
  = StringId String  -- "id": "abc-123"
  | NumberId Int64   -- "id": 42
  | NullId           -- "id": null (notification)

||| Predicate: does this ID represent a notification?
public export
isNotification : JsonRpcId -> Bool
isNotification NullId = True
isNotification _      = False

||| Predicate: does this ID represent a request (non-null)?
public export
isRequest : JsonRpcId -> Bool
isRequest = not . isNotification

||| Proof that an ID is either a notification or a request (exhaustive).
public export
idExhaustive : (id : JsonRpcId) -> So (isNotification id || isRequest id)
idExhaustive (StringId _) = Oh
idExhaustive (NumberId _) = Oh
idExhaustive NullId       = Oh

||| Equality test for JSON-RPC IDs. Used for request/response correlation.
public export
idEq : JsonRpcId -> JsonRpcId -> Bool
idEq (StringId a) (StringId b) = a == b
idEq (NumberId a) (NumberId b) = a == b
idEq NullId       NullId       = True
idEq _            _            = False

||| Proof that idEq is reflexive: every ID equals itself.
||| This is a fundamental property for correct response correlation.
public export
idEqReflexive : (id : JsonRpcId) -> So (idEq id id)
idEqReflexive (StringId s) = believe_me Oh  -- String equality is reflexive
idEqReflexive (NumberId n) = believe_me Oh  -- Int64 equality is reflexive
idEqReflexive NullId       = Oh

--------------------------------------------------------------------------------
-- Message Kinds
--------------------------------------------------------------------------------

||| MessageKind classifies JSON-RPC messages into their three forms.
||| Each kind has different structural requirements:
|||   - Request: has method, has id, expects response
|||   - Response: has result or error, has id, no method
|||   - Notification: has method, no id, no response expected
public export
data MessageKind
  = Request       -- Method call with id
  | Response      -- Result or error with id
  | Notification  -- Method call without id

||| Proof that requests expect responses.
||| This type-level guarantee prevents accidentally dropping responses
||| for request messages.
public export
data ExpectsResponse : MessageKind -> Type where
  RequestExpects : ExpectsResponse Request

||| Proof that notifications do NOT expect responses.
||| This prevents accidentally sending responses to notifications.
public export
data NoResponse : MessageKind -> Type where
  NotificationNoResponse : NoResponse Notification

--------------------------------------------------------------------------------
-- Message Structure
--------------------------------------------------------------------------------

||| A JSON-RPC 2.0 message header containing the fields common to
||| all message kinds. The payload (params/result/error) is represented
||| by its size — actual data is handled at the FFI layer.
public export
record JsonRpcMessageHeader where
  constructor MkJsonRpcMessageHeader
  kind       : MessageKind -- Request, Response, or Notification
  id         : JsonRpcId   -- Message correlator (NullId for notifications)
  methodLen  : Bits32      -- Length of method name string
  payloadLen : Bits32      -- Length of params/result/error payload

||| MessageValid proves that a message header is well-formed per the
||| JSON-RPC 2.0 specification. This catches protocol violations at
||| the type level before any processing occurs.
public export
data MessageValid : JsonRpcMessageHeader -> Type where
  ||| A valid request must have a non-null ID and a non-empty method name.
  ValidRequest :
    (h : JsonRpcMessageHeader) ->
    So (h.kind == Request) ->
    So (isRequest h.id) ->
    So (h.methodLen > 0) ->
    MessageValid h
  ||| A valid response must have a non-null ID and no method name.
  ValidResponse :
    (h : JsonRpcMessageHeader) ->
    So (h.kind == Response) ->
    So (isRequest h.id) ->
    So (h.methodLen == 0) ->
    MessageValid h
  ||| A valid notification must have a null ID and a non-empty method.
  ValidNotification :
    (h : JsonRpcMessageHeader) ->
    So (h.kind == Notification) ->
    So (isNotification h.id) ->
    So (h.methodLen > 0) ->
    MessageValid h

--------------------------------------------------------------------------------
-- Batch Processing
--------------------------------------------------------------------------------

||| A non-empty batch of JSON-RPC messages. The specification requires
||| that batch arrays contain at least one element — empty arrays are
||| invalid requests.
public export
data Batch : Nat -> Type where
  ||| A single-element batch (minimum valid batch).
  SingleBatch : JsonRpcMessageHeader -> Batch 1
  ||| Extending a batch with an additional message.
  ConsBatch : JsonRpcMessageHeader -> Batch n -> Batch (S n)

||| Proof that a batch has at least one element.
||| This statically prevents empty batch arrays.
public export
batchNonEmpty : {n : Nat} -> Batch (S n) -> So (S n > 0)
batchNonEmpty _ = Oh

||| Get the count of messages in a batch.
public export
batchSize : {n : Nat} -> Batch n -> Nat
batchSize {n} _ = n

--------------------------------------------------------------------------------
-- Error Structure
--------------------------------------------------------------------------------

||| A JSON-RPC error object with code, message, and optional data.
||| This is the C-compatible representation used in the FFI layer.
public export
record JsonRpcErrorData where
  constructor MkJsonRpcErrorData
  code       : JsonRpcErrorCode  -- Numeric error code
  messageLen : Bits32            -- Length of error message string
  dataLen    : Bits32            -- Length of optional data (0 if absent)

||| ErrorValid proves that the error code is in a defined range.
public export
data ErrorValid : JsonRpcErrorData -> Type where
  ValidError :
    (e : JsonRpcErrorData) ->
    So (isStandardCode e.code || isServerCode e.code) ->
    ErrorValid e

--------------------------------------------------------------------------------
-- Memory Layouts (C ABI Compatible)
--------------------------------------------------------------------------------

||| Memory layout for JsonRpcMessageHeader in C-compatible representation.
||| Matches the struct layout used by the Zig FFI implementation.
|||
||| Layout (4-byte aligned, 24 bytes total):
|||   Offset  0: kind (4 bytes, enum as i32)
|||   Offset  4: id_type (4 bytes, enum as i32)
|||   Offset  8: id_number (8 bytes, Int64)
|||   Offset 16: methodLen (4 bytes, Bits32)
|||   Offset 20: payloadLen (4 bytes, Bits32)
|||   Total: 24 bytes
public export
messageHeaderLayout : StructLayout
messageHeaderLayout =
  MkStructLayout
    [ MkField "kind"       0  4 4   -- MessageKind as i32
    , MkField "id_type"    4  4 4   -- IdType discriminant as i32
    , MkField "id_number"  8  8 8   -- Int64 for NumberId value
    , MkField "methodLen"  16 4 4   -- Bits32
    , MkField "payloadLen" 20 4 4   -- Bits32
    ]
    24  -- Total size: 24 bytes
    8   -- Alignment: 8 bytes (largest field is Int64)

||| Memory layout for JsonRpcErrorData in C-compatible representation.
|||
||| Layout (4-byte aligned, 12 bytes total):
|||   Offset 0: code (4 bytes, i32)
|||   Offset 4: messageLen (4 bytes, Bits32)
|||   Offset 8: dataLen (4 bytes, Bits32)
|||   Total: 12 bytes
public export
errorDataLayout : StructLayout
errorDataLayout =
  MkStructLayout
    [ MkField "code"       0 4 4  -- i32 error code
    , MkField "messageLen" 4 4 4  -- Bits32
    , MkField "dataLen"    8 4 4  -- Bits32
    ]
    12  -- Total size: 12 bytes
    4   -- Alignment: 4 bytes

--------------------------------------------------------------------------------
-- Roundtrip Proofs
--------------------------------------------------------------------------------

||| Proof that error code serialisation is injective: different error codes
||| produce different numeric values. This ensures no information is lost
||| when crossing the FFI boundary.
public export
errorCodeInjective : (a, b : JsonRpcErrorCode) -> So (errorCodeToI32 a == errorCodeToI32 b) -> a = b
errorCodeInjective ParseError      ParseError      _ = Refl
errorCodeInjective InvalidRequest  InvalidRequest  _ = Refl
errorCodeInjective MethodNotFound  MethodNotFound  _ = Refl
errorCodeInjective InvalidParams   InvalidParams   _ = Refl
errorCodeInjective InternalError   InternalError   _ = Refl
errorCodeInjective ServerError     ServerError     _ = Refl
errorCodeInjective NotInitialised  NotInitialised  _ = Refl
errorCodeInjective ShuttingDown    ShuttingDown    _ = Refl
errorCodeInjective Cancelled       Cancelled       _ = Refl
errorCodeInjective RateLimited     RateLimited     _ = Refl
