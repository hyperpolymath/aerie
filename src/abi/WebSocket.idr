||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
|||
||| WebSocket ABI Type Definitions
|||
||| This module defines the Application Binary Interface (ABI) types for the
||| WebSocket protocol implementation. It provides formally verified types
||| that ensure binary compatibility between the Idris2 proof layer, the
||| Zig FFI implementation, and the V-lang application code.
|||
||| The WebSocket types model the complete protocol lifecycle:
|||   - Connection states (state machine with proven transitions)
|||   - Frame opcodes (RFC 6455 Section 5.2)
|||   - Close status codes (RFC 6455 Section 7.4.1)
|||   - Frame wire format (with payload size bounds)
|||   - Heartbeat configuration (with interval constraints)
|||
||| ARCHITECTURE:
||| Idris2 (Proofs) <-> Zig (Stable C ABI) <-> V-lang (Application)
|||
||| @see RFC 6455 — The WebSocket Protocol
||| @see Aerie.ABI.Types for base types (Handle, Result, Platform)

module Aerie.ABI.WebSocket

import Aerie.ABI.Types
import Aerie.ABI.Layout
import Data.Bits
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- WebSocket Opcodes (RFC 6455 Section 5.2)
--------------------------------------------------------------------------------

||| WebSocket frame opcodes as defined in RFC 6455 Section 5.2.
||| Data frames: continuation (0x0), text (0x1), binary (0x2).
||| Control frames: close (0x8), ping (0x9), pong (0xA).
||| Control frames MUST NOT be fragmented (enforced by WsFrameValid).
public export
data WsOpcode
  = Continuation  -- 0x0: Continuation frame
  | TextFrame     -- 0x1: UTF-8 text data
  | BinaryFrame   -- 0x2: Binary data
  | CloseFrame    -- 0x8: Connection close
  | PingFrame     -- 0x9: Heartbeat request
  | PongFrame     -- 0xA: Heartbeat response

||| Convert a WsOpcode to its wire representation (4-bit unsigned integer).
public export
opcodeToU8 : WsOpcode -> Bits8
opcodeToU8 Continuation = 0x0
opcodeToU8 TextFrame    = 0x1
opcodeToU8 BinaryFrame  = 0x2
opcodeToU8 CloseFrame   = 0x8
opcodeToU8 PingFrame    = 0x9
opcodeToU8 PongFrame    = 0xA

||| Parse a wire byte to a WsOpcode. Returns Nothing for reserved opcodes.
public export
u8ToOpcode : Bits8 -> Maybe WsOpcode
u8ToOpcode 0x0 = Just Continuation
u8ToOpcode 0x1 = Just TextFrame
u8ToOpcode 0x2 = Just BinaryFrame
u8ToOpcode 0x8 = Just CloseFrame
u8ToOpcode 0x9 = Just PingFrame
u8ToOpcode 0xA = Just PongFrame
u8ToOpcode _   = Nothing

||| Predicate: is this opcode a control frame?
||| Control frames have opcodes >= 0x8 per RFC 6455.
public export
isControlFrame : WsOpcode -> Bool
isControlFrame CloseFrame = True
isControlFrame PingFrame  = True
isControlFrame PongFrame  = True
isControlFrame _          = False

--------------------------------------------------------------------------------
-- WebSocket Close Status Codes (RFC 6455 Section 7.4.1)
--------------------------------------------------------------------------------

||| Standard close status codes per RFC 6455 Section 7.4.1.
||| These are carried in the first two bytes of a close frame's payload.
public export
data WsCloseCode
  = NormalClosure      -- 1000: Normal shutdown
  | GoingAway          -- 1001: Endpoint going away
  | ProtocolError      -- 1002: Protocol error
  | UnsupportedData    -- 1003: Unsupported data type
  | InvalidPayload     -- 1007: Invalid payload data
  | PolicyViolation    -- 1008: Policy violation
  | MessageTooBig      -- 1009: Message too large
  | ExtensionMissing   -- 1010: Missing expected extension
  | InternalError      -- 1011: Unexpected server condition

||| Convert a close code to its 16-bit wire representation.
public export
closeCodeToU16 : WsCloseCode -> Bits16
closeCodeToU16 NormalClosure    = 1000
closeCodeToU16 GoingAway        = 1001
closeCodeToU16 ProtocolError    = 1002
closeCodeToU16 UnsupportedData  = 1003
closeCodeToU16 InvalidPayload   = 1007
closeCodeToU16 PolicyViolation  = 1008
closeCodeToU16 MessageTooBig    = 1009
closeCodeToU16 ExtensionMissing = 1010
closeCodeToU16 InternalError    = 1011

||| Proof that all close codes are in the valid range [1000, 4999].
||| The RFC reserves 0-999 and 5000+ for future use.
public export
closeCodeInRange : (code : WsCloseCode) -> So (closeCodeToU16 code >= 1000 && closeCodeToU16 code <= 4999)
closeCodeInRange NormalClosure    = Oh
closeCodeInRange GoingAway        = Oh
closeCodeInRange ProtocolError    = Oh
closeCodeInRange UnsupportedData  = Oh
closeCodeInRange InvalidPayload   = Oh
closeCodeInRange PolicyViolation  = Oh
closeCodeInRange MessageTooBig    = Oh
closeCodeInRange ExtensionMissing = Oh
closeCodeInRange InternalError    = Oh

--------------------------------------------------------------------------------
-- Connection State Machine
--------------------------------------------------------------------------------

||| WebSocket connection states with proven transition rules.
||| The state machine ensures connections follow the protocol lifecycle:
|||   Connecting -> Open -> Closing -> Closed
||| Any state can transition to Closed on error.
public export
data WsState
  = Connecting  -- TCP connected, HTTP upgrade in progress
  | Open        -- Handshake complete, messaging active
  | Closing     -- Close frame sent, awaiting peer close
  | Closed      -- Connection fully terminated

||| ValidTransition proves that a state transition is legal.
||| This prevents invalid transitions at the type level — code that
||| attempts Closed -> Open will not compile.
public export
data ValidTransition : WsState -> WsState -> Type where
  ConnectToOpen    : ValidTransition Connecting Open
  OpenToClosing    : ValidTransition Open Closing
  ClosingToClosed  : ValidTransition Closing Closed
  -- Error transitions (any state -> Closed)
  ConnectError     : ValidTransition Connecting Closed
  OpenError        : ValidTransition Open Closed

||| Proof that Closed is a terminal state: no valid transitions exist from Closed.
||| This ensures that once a connection is closed, it cannot be reopened
||| (reconnection creates a new connection object).
public export
closedIsTerminal : ValidTransition Closed s -> Void
closedIsTerminal _ impossible

--------------------------------------------------------------------------------
-- Frame Structure
--------------------------------------------------------------------------------

||| A WebSocket frame header with all fields from RFC 6455 Section 5.2.
||| The payload is represented by its length — actual data is handled
||| at the FFI layer to avoid copying large buffers through Idris.
public export
record WsFrameHeader where
  constructor MkWsFrameHeader
  fin         : Bool      -- FIN bit: final frame in message
  opcode      : WsOpcode  -- Frame type
  masked      : Bool      -- Payload is XOR-masked
  payloadLen  : Bits64    -- Payload length in bytes

||| WsFrameValid is a proof that a frame header is well-formed per RFC 6455.
||| Control frames (close, ping, pong) have additional restrictions:
|||   - MUST NOT be fragmented (fin MUST be True)
|||   - Payload length MUST NOT exceed 125 bytes
public export
data WsFrameValid : WsFrameHeader -> Type where
  ||| Data frame validity: no restrictions beyond basic format.
  ValidDataFrame :
    (h : WsFrameHeader) ->
    So (not (isControlFrame h.opcode)) ->
    WsFrameValid h
  ||| Control frame validity: fin=True and payloadLen <= 125.
  ValidControlFrame :
    (h : WsFrameHeader) ->
    So (isControlFrame h.opcode) ->
    So (h.fin == True) ->
    So (h.payloadLen <= 125) ->
    WsFrameValid h

--------------------------------------------------------------------------------
-- Heartbeat Configuration
--------------------------------------------------------------------------------

||| Heartbeat configuration with interval and timeout constraints.
||| The timeout MUST be less than the interval to allow time for
||| the next ping cycle.
public export
record HeartbeatConfig where
  constructor MkHeartbeatConfig
  intervalMs : Bits32  -- Ping interval in milliseconds
  timeoutMs  : Bits32  -- Pong timeout in milliseconds

||| Proof that the heartbeat configuration is valid:
||| timeout must be strictly less than interval.
public export
data HeartbeatValid : HeartbeatConfig -> Type where
  HBValid :
    (cfg : HeartbeatConfig) ->
    So (cfg.timeoutMs < cfg.intervalMs) ->
    HeartbeatValid cfg

--------------------------------------------------------------------------------
-- Memory Layouts (C ABI Compatible)
--------------------------------------------------------------------------------

||| Memory layout for WsFrameHeader in C-compatible representation.
||| Matches the struct layout used by the Zig FFI implementation.
|||
||| Layout (8-byte aligned, 16 bytes total):
|||   Offset 0: fin (1 byte, padded to 4)
|||   Offset 4: opcode (1 byte, padded to 4)
|||   Offset 8: masked (1 byte, padded to 4)
|||   Offset 12: padding (4 bytes for 8-byte alignment of payloadLen)
|||   Offset 16: payloadLen (8 bytes, Bits64)
|||   Total: 24 bytes
public export
wsFrameHeaderLayout : StructLayout
wsFrameHeaderLayout =
  MkStructLayout
    [ MkField "fin"        0  1 1    -- Bool at offset 0
    , MkField "opcode"     4  1 1    -- Bits8 at offset 4
    , MkField "masked"     8  1 1    -- Bool at offset 8
    , MkField "payloadLen" 16 8 8    -- Bits64 at offset 16
    ]
    24  -- Total size: 24 bytes
    8   -- Alignment: 8 bytes (largest field is Bits64)

||| Memory layout for HeartbeatConfig in C-compatible representation.
|||
||| Layout (4-byte aligned, 8 bytes total):
|||   Offset 0: intervalMs (4 bytes, Bits32)
|||   Offset 4: timeoutMs (4 bytes, Bits32)
|||   Total: 8 bytes
public export
heartbeatConfigLayout : StructLayout
heartbeatConfigLayout =
  MkStructLayout
    [ MkField "intervalMs" 0 4 4  -- Bits32 at offset 0
    , MkField "timeoutMs"  4 4 4  -- Bits32 at offset 4
    ]
    8   -- Total size: 8 bytes
    4   -- Alignment: 4 bytes
