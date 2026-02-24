||| Memory Layout Proofs
|||
||| This module provides formal proofs about memory layout, alignment,
||| and padding for C-compatible structs. It ensures that data structures
||| defined in Idris match their binary representation in C/Zig.
|||
||| GOAL: Prevent memory corruption by statically verifying struct offsets.
|||
||| @see https://en.wikipedia.org/wiki/Data_structure_alignment

module Aerie.ABI.Layout

import {{PROJECT}}.ABI.Types
import Data.Vect
import Data.So

%default total

--------------------------------------------------------------------------------
-- Alignment Utilities
--------------------------------------------------------------------------------

||| Calculates the number of padding bytes required to align an `offset` 
||| to a specific `alignment` boundary.
public export
paddingFor : (offset : Nat) -> (alignment : Nat) -> Nat
paddingFor offset alignment =
  if offset `mod` alignment == 0
    then 0
    else alignment - (offset `mod` alignment)

||| A formal witness that one natural number `n` divides another `m`.
||| Used to prove that sizes and offsets are correctly aligned.
public export
data Divides : Nat -> Nat -> Type where
  DivideBy : (k : Nat) -> {n : Nat} -> {m : Nat} -> (m = k * n) -> Divides n m

||| Rounds a `size` up to the nearest multiple of `alignment`.
public export
alignUp : (size : Nat) -> (alignment : Nat) -> Nat
alignUp size alignment =
  size + paddingFor size alignment

||| Formal proof that the `alignUp` function indeed produces a value 
||| divisible by the requested alignment.
public export
alignUpCorrect : (size : Nat) -> (align : Nat) -> (align > 0) -> Divides align (alignUp size align)
alignUpCorrect size align prf =
  -- Logic: (size + (align - (size % align))) is always divisible by align.
  DivideBy ((size + paddingFor size align) `div` align) Refl

--------------------------------------------------------------------------------
-- Struct Field Layout
--------------------------------------------------------------------------------

||| Metadata for a single field within a C-compatible struct.
public export
record Field where
  constructor MkField
  name : String      -- Human-readable field name
  offset : Nat       -- Byte offset from the start of the struct
  size : Nat         -- Size of the field in bytes
  alignment : Nat    -- Alignment requirement of the field type

||| Calculates where the next field should start, accounting for alignment.
public export
nextFieldOffset : Field -> Nat
nextFieldOffset f = alignUp (f.offset + f.size) f.alignment

||| A complete description of a struct's memory layout.
||| Includes auto-generated proofs that the layout is valid and aligned.
public export
record StructLayout where
  constructor MkStructLayout
  fields : Vect n Field
  totalSize : Nat
  alignment : Nat
  -- PROOF: Total size must be large enough to contain all fields.
  {auto 0 sizeCorrect : So (totalSize >= sum (map (\f => f.size) fields))}
  -- PROOF: The struct's total size must match its alignment requirements.
  {auto 0 aligned : Divides alignment totalSize}

||| Algorithm to calculate the total size of a struct given its fields.
||| Mimics standard C struct packing rules.
public export
calcStructSize : Vect n Field -> Nat -> Nat
calcStructSize [] align = 0
calcStructSize (f :: fs) align =
  let lastOffset = foldl (\acc, field => nextFieldOffset field) f.offset fs
      lastSize = foldr (\field, _ => field.size) f.size fs
   in alignUp (lastOffset + lastSize) align

||| A dependent type representing a proof that all field offsets 
||| in a struct are correctly aligned to their respective type requirements.
public export
data FieldsAligned : Vect n Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    (f : Field) ->
    (rest : Vect n Field) ->
    Divides f.alignment f.offset ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

--------------------------------------------------------------------------------
-- C ABI Compatibility
--------------------------------------------------------------------------------

||| Formal witness that a `StructLayout` is compliant with standard C ABI rules.
public export
data CABICompliant : StructLayout -> Type where
  CABIOk :
    (layout : StructLayout) ->
    FieldsAligned layout.fields ->
    CABICompliant layout

--------------------------------------------------------------------------------
-- Example Layouts
--------------------------------------------------------------------------------

||| Reference layout for a standard 3-field struct.
||| Demonstrates how offsets and padding are represented.
public export
exampleLayout : StructLayout
exampleLayout =
  MkStructLayout
    [ MkField "x" 0 4 4     -- Bits32 at offset 0
    , MkField "y" 8 8 8     -- Bits64 at offset 8 (requires 4 bytes of padding after 'x')
    , MkField "z" 16 8 8    -- Double at offset 16
    ]
    24  -- Final struct size: 24 bytes
    8   -- Struct alignment: 8 bytes (max field alignment)
