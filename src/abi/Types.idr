||| ABI Type Definitions Template
|||
||| This module defines the Application Binary Interface (ABI) for the 
||| project. It provides the fundamental types and proofs used to ensure
||| binary compatibility across language boundaries.
|||
||| ARCHITECTURE:
||| Idris (Proofs) <-> Zig (Stable C ABI) <-> Rust/Python (Consumers)

module {{PROJECT}}.ABI.Types

import Data.Bits
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- Platform Detection
--------------------------------------------------------------------------------

||| Supported targets for the high-assurance stack.
public export
data Platform = Linux | Windows | MacOS | BSD | WASM

||| Resolves the target platform at compile time.
public export
thisPlatform : Platform
thisPlatform =
  %runElab do
    -- DEFAULT: Currently hardcoded to Linux. 
    -- TODO: Integration with build system flags.
    pure Linux

--------------------------------------------------------------------------------
-- Core Result Types
--------------------------------------------------------------------------------

||| Formal result codes for all FFI operations.
||| Maps 1:1 with C-style integer return codes.
public export
data Result : Type where
  ||| Success (0)
  Ok : Result
  ||| Generic failure (1)
  Error : Result
  ||| Logic error: invalid parameter (2)
  InvalidParam : Result
  ||| System error: allocation failure (3)
  OutOfMemory : Result
  ||| Safety error: unexpected null (4)
  NullPointer : Result

||| Decidability proof for results, allowing for verified branching logic.
public export
DecEq Result where
  decEq Ok Ok = Yes Refl
  decEq Error Error = Yes Refl
  decEq InvalidParam InvalidParam = Yes Refl
  decEq OutOfMemory OutOfMemory = Yes Refl
  decEq NullPointer NullPointer = Yes Refl
  decEq _ _ = No absurd

--------------------------------------------------------------------------------
-- Safety Handles
--------------------------------------------------------------------------------

||| Opaque resource handle.
||| INVARIANT: A `Handle` instance GUARANTEES that the internal pointer is non-null.
public export
data Handle : Type where
  MkHandle : (ptr : Bits64) -> {auto 0 nonNull : So (ptr /= 0)} -> Handle

||| SAFE CONSTRUCTOR: Validates a raw pointer before creating a `Handle`.
public export
createHandle : Bits64 -> Maybe Handle
createHandle 0 = Nothing
createHandle ptr = Just (MkHandle ptr)

||| RAW ACCESS: Extracts the pointer for use in native FFI calls.
public export
handlePtr : Handle -> Bits64
handlePtr (MkHandle ptr) = ptr

--------------------------------------------------------------------------------
-- Memory Layout Verification
--------------------------------------------------------------------------------

||| Proof witness that a type `t` occupies exactly `n` bytes.
public export
data HasSize : Type -> Nat -> Type where
  SizeProof : {0 t : Type} -> {n : Nat} -> HasSize t n

||| Proof witness that a type `t` requires `n`-byte alignment.
public export
data HasAlignment : Type -> Nat -> Type where
  AlignProof : {0 t : Type} -> {n : Nat} -> HasAlignment t n

--------------------------------------------------------------------------------
-- Platform-Specific Bit Widths
--------------------------------------------------------------------------------

||| Formalizes pointer width for the target platform.
public export
ptrSize : Platform -> Nat
ptrSize Linux = 64
ptrSize WASM = 32
ptrSize _ = 64

||| Generic C-pointer type alias.
public export
CPtr : Platform -> Type -> Type
CPtr p _ = Bits (ptrSize p)
