||| ABI Type Definitions Template
|||
||| This module defines the Application Binary Interface (ABI) for the 
||| project. It provides the fundamental types and proofs used to ensure
||| binary compatibility across language boundaries.
|||
||| ARCHITECTURE:
||| Idris (Proofs) <-> Zig (Stable C ABI) <-> Rust/Python (Consumers)

module Aerie.ABI.Types

import Data.Bits
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- Core Types (Aerie Specific)
--------------------------------------------------------------------------------

||| Telemetry sample from a network probe.
public export
record TelemetrySample where
  constructor MkTelemetrySample
  timestamp : Bits64
  latencyMs : Double
  jitterMs  : Float
  packetLoss : Double

||| A single hop in a network route path.
public export
record RouteHop where
  constructor MkRouteHop
  hop : Int32
  ip  : String
  asn : String
  rttMs : Double

||| A security audit event.
public export
record AuditEvent where
  constructor MkAuditEvent
  eventId   : String
  validTime : Bits64
  txTime    : Bits64
  severity  : String
  message   : String

--------------------------------------------------------------------------------
-- Results and Handles
--------------------------------------------------------------------------------

public export
data Result = Ok | Error | InvalidParam | OutOfMemory | NullPointer

public export
data Handle = MkHandle (ptr : Bits64)

--------------------------------------------------------------------------------
-- Platform and Bit Widths (Standard)
--------------------------------------------------------------------------------

public export
data Platform = Linux | Windows | MacOS | BSD | WASM

public export
thisPlatform : Platform
thisPlatform = Linux

public export
ptrSize : Platform -> Nat
ptrSize Linux = 64
ptrSize WASM = 32
ptrSize _ = 64
