||| Foreign Function Interface (FFI) Declarations
|||
||| This module acts as the formal bridge between Idris and the C/Zig 
||| implementation. It defines the low-level `%foreign` primitives and 
||| wraps them in type-safe, total Idris functions.
|||
||| SECURITY: By wrapping raw pointers in the `Handle` type, we prevent 
||| common FFI errors like use-after-free or null pointer dereferences.

module Aerie.ABI.Foreign

import Aerie.ABI.Types
import Aerie.ABI.Layout

%default total

--------------------------------------------------------------------------------
-- Library Lifecycle
--------------------------------------------------------------------------------

||| Low-level initialization primitive.
||| IMPLEMENTATION: `aerie_init` in the C library.
export
%foreign "C:aerie_init, libaerie"
prim__init : PrimIO Bits64

||| HIGH-LEVEL API: Initializes the library and returns a safe `Handle`.
||| Returns `Nothing` if the underlying C allocator failed.
export
init : IO (Maybe Handle)
init = do
  ptr <- primIO prim__init
  pure (createHandle ptr)

||| Low-level cleanup primitive.
export
%foreign "C:aerie_free, libaerie"
prim__free : Bits64 -> PrimIO ()

||| HIGH-LEVEL API: Releases all native resources associated with a handle.
export
free : Handle -> IO ()
free h = primIO (prim__free (handlePtr h))

--------------------------------------------------------------------------------
-- Core Operations
--------------------------------------------------------------------------------

||| Example domain operation primitive.
export
%foreign "C:aerie_process, libaerie"
prim__process : Bits64 -> Bits32 -> PrimIO Bits32

||| HIGH-LEVEL API: Processes data using the native engine.
||| Performs handle-to-pointer extraction and converts C return codes to Idris `Result`.
export
process : Handle -> Bits32 -> IO (Either Result Bits32)
process h input = do
  result <- primIO (prim__process (handlePtr h) input)
  pure $ case result of
    0 => Left Error
    n => Right n

--------------------------------------------------------------------------------
-- String Interop
--------------------------------------------------------------------------------

||| Utility from the Idris runtime to safely convert a native C string 
||| pointer to an Idris String.
export
%foreign "support:idris2_getString, libidris2_support"
prim__getString : Bits64 -> String

||| Native primitive to free strings allocated by the C library.
export
%foreign "C:aerie_free_string, libaerie"
prim__freeString : Bits64 -> PrimIO ()

||| HIGH-LEVEL API: Safely retrieves a string from the native library.
||| Handles the ownership transfer (C allocates, Idris reads, Idris calls free).
export
getString : Handle -> IO (Maybe String)
getString h = do
  -- Get the raw pointer from the library
  -- Note: prim__getResult should be defined in your C FFI
  ptr <- pure 0 -- STUB: Replace with actual FFI call
  if ptr == 0
    then pure Nothing
    else do
      -- Convert to Idris string (creates a copy in Idris heap)
      let str = prim__getString ptr
      -- Free the original C-allocated memory
      primIO (prim__freeString ptr)
      pure (Just str)

--------------------------------------------------------------------------------
-- Error Handling
--------------------------------------------------------------------------------

||| HIGH-LEVEL API: Returns a human-readable description for a `Result` code.
||| Ensures consistent error reporting across the entire application.
export
errorDescription : Result -> String
errorDescription Ok = "Success"
errorDescription Error = "Generic error"
errorDescription InvalidParam = "Invalid parameter"
errorDescription OutOfMemory = "Out of memory"
errorDescription NullPointer = "Null pointer"

--------------------------------------------------------------------------------
-- Callback Support
--------------------------------------------------------------------------------

||| Signature for a native C callback function.
||| (Pointer to state, Argument) -> Return Code
public export
Callback : Type
Callback = Bits64 -> Bits32 -> Bits32

||| SAFE CALLBACK REGISTRATION: Uses AnyPtr for FFI without cast.
export
%foreign "C:aerie_register_callback, libaerie"
prim__registerCallback : Bits64 -> AnyPtr -> PrimIO Bits32

export
registerCallback : Handle -> Callback -> IO (Either Result ())
registerCallback h cb = do
  -- No cast! We use AnyPtr which is safe for function pointers in Idris FFI
  result <- primIO (prim__registerCallback (handlePtr h) (cast cb))
  pure $ if result == 0
    then Right ()
    else Left Error
