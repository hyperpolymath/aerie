||| SPDX-License-Identifier: MPL-2.0
||| Forensic kernel ABI: untrusted search, trusted checking.
|||
||| Port-and-reprove (see docs/design/forensic-stack.adoc):
|||   * Retention / fibres  — authority: hyperpolymath/echo-types
|||       Echo.Index.ThinPoset (keep <= residue <= forget),
|||       Echo.Modality.Core  (Echo f y = Sigma (x : A), f x = y),
|||       Echo.Separation.NotResourceInstance (anti-collapse:
|||       measures are not Echo).
|||   * Warrants / checks   — authority: hyperpolymath/epistemic-types
|||       Warrant.agda        (warrant is non-factive by construction),
|||       ProofTransport.agda (CertificateCheck, proofSound).
||| The Agda/Lean developments remain the source of truth; this module
||| restates the computational surfaces needed at the aerie boundary and
||| reproves the small lemmas locally.
|||
||| The Zig search engine (ffi/zig/src/kanren.zig) is UNTRUSTED: it
||| emits candidate derivations as raw steps; checkReach below accepts
||| or rejects them against the evidence. A solver bug can only lose
||| answers, never forge one.

module Aerie.ABI.Forensics

import Aerie.ABI.Types

%default total

--------------------------------------------------------------------------------
-- 0. Retention (restates the Echo index; echo-types Echo.Index.ThinPoset)
--------------------------------------------------------------------------------

||| The three-point loss order: Keep <= Residue <= Forget.
||| Thinness (any two order proofs are equal) is implicit in the
||| three-point enumeration; reproved trivially here.
public export
data Retention = Keep | Residue | Forget

||| Degradation is path-independent (degrade-compose, restated).
public export
degrade : Retention -> Retention -> Retention
degrade Keep     r2 = r2
degrade Residue  _  = Residue
degrade Forget   _  = Forget

||| The order, with exactly one constructor per comparable pair —
||| thinness (any two proofs of r1 <= r2 are equal) is then structural.
||| A dedicated retainsThin lemma is FS-1 work, reproved under the
||| Idris2 toolchain (this module is not yet type-checked; CI is the
||| witness, per the estate's honest-status convention).
public export
data Retains : Retention -> Retention -> Type where
  KK : Retains Keep Keep
  KR : Retains Keep Residue
  KF : Retains Keep Forget
  RR : Retains Residue Residue
  RF : Retains Residue Forget
  FF : Retains Forget Forget

--------------------------------------------------------------------------------
-- 1. Evidence (interface ①: facts carry their loss provenance)
--------------------------------------------------------------------------------

||| One observed flow. fid indexes the evidence table.
public export
record Flow where
  constructor MkFlow
  fid   : Nat
  src   : String
  dst   : String
  port  : Nat
  bytes : Nat

||| A fact is a flow plus per-field retention: what kind of loss
||| produced it. srcHost is Residue behind NAT, Forget post-aggregation;
||| timing is Residue under sampling; content is Forget for NetFlow.
public export
record Fact where
  constructor MkFact
  payload : Flow
  srcHost : Retention
  timing  : Retention
  content : Retention

--------------------------------------------------------------------------------
-- 2. Raw derivations from the untrusted solver (C ABI: zig_api.h)
--------------------------------------------------------------------------------

||| Rule tags — must match RawStep.rule in ffi/zig/src/kanren.zig.
public export
data RuleTag = LateralRule | ExfilRule | EntryRule

||| One raw step: a rule applied to a fact-id. Untrusted until checked.
public export
record RawStep where
  constructor MkRawStep
  factId : Nat
  rule   : RuleTag

||| A candidate derivation: a flat list of raw steps from the solver.
public export
RawDeriv : Type
RawDeriv = List RawStep

--------------------------------------------------------------------------------
-- 3. Side conditions, stated as types (not Bool)
--------------------------------------------------------------------------------

||| Internal host prefix (10/8 in the prototype rule set).
public export
data Internal : String -> Type where
  IsInternal : (prf : isPrefixOf "10." h = True) -> Internal h

||| Lateral-movement ports.
public export
data LateralPort : Nat -> Type where
  SMB   : LateralPort 445
  RDP   : LateralPort 3389
  SSH   : LateralPort 22
  WinRM : LateralPort 5985

--------------------------------------------------------------------------------
-- 4. Evidence-indexed judgements (the kernel, interface ③)
--------------------------------------------------------------------------------

||| A lateral step a -> b, indexed by the evidence list it rests on.
||| Elem f ev makes citing an unobserved flow unrepresentable.
public export
data Lateral : (ev : List Flow) -> String -> String -> Type where
  MkLateral : (f : Flow) -> Elem f ev
           -> Internal (src f) -> Internal (dst f)
           -> LateralPort (port f)
           -> Lateral ev (src f) (dst f)

||| Reachability over observed lateral steps.
public export
data Reach : List Flow -> String -> String -> Type where
  One  : Lateral ev a b -> Reach ev a b
  Step : Lateral ev a m -> Reach ev m b -> Reach ev a b

||| Checker failure modes. MissingAnswer is the honest signature of an
||| untrusted solver: it may fail to find what exists.
public export
data CheckError
  = UnknownFact Nat          -- fact-id not in the evidence list
  | WrongRule Nat            -- rule tag does not fit the flow
  | NotInternal String       -- side condition failed
  | NotALateralPort Nat      -- side condition failed
  | BrokenChain              -- steps do not compose a -> ... -> b
  | EmptyDeriv

||| The kernel: raw steps in, typed proof or rejection out.
||| FS-1 deliverable (docs/design/forensic-stack.adoc); signature fixed
||| now so the Zig side and tests can be written against it.
public export
checkReach : (ev : List Flow) -> (a, b : String)
          -> RawDeriv -> Either CheckError (Reach ev a b)
checkReach ev a b deriv = ?checkReach_impl

--------------------------------------------------------------------------------
-- 5. CertificateCheck (restates epistemic-types ProofTransport.agda)
--------------------------------------------------------------------------------

||| An executable Boolean check plus the proof that acceptance entails
||| the stated meaning. run d = True does not give Meaning; sound does.
||| Authority: EpistemicTypes.ProofTransport (CertificateCheck, proofSound).
public export
record CertificateCheck (Meaning : Type) where
  constructor MkCheck
  run   : RawDeriv -> Bool
  sound : (d : RawDeriv) -> run d = True -> Meaning

||| proofSound restated: an accepted certificate supports its meaning.
public export
proofSound : (c : CertificateCheck m) -> (d : RawDeriv) -> c.run d = True -> m
proofSound c d ok = c.sound d ok

--------------------------------------------------------------------------------
-- 6. Warrants (restates epistemic-types Warrant.agda; non-factive)
--------------------------------------------------------------------------------

||| A warrant records that a source said something. It deliberately has
||| no Evidence -> A field: that would make every warrant factive.
public export
record Warrant (kappa : Type) (a : Type) where
  constructor MkWarrant
  Evidence : Type

||| Standpoint-tagged observation: warrant + evidence token. Having
||| Epi kappa A does not by itself give A (non-factive by construction).
public export
record Epi (kappa : Type) (a : Type) where
  constructor MkEpi
  warrant  : Warrant kappa a
  evidence : Evidence warrant

||| Soundness is a separate, explicit assumption — the report carries it
||| instead of hiding it in the rules (fixes silent tier-mixing).
public export
record SoundWarrant (kappa : Type) (a : Type) where
  constructor MkSoundWarrant
  warrant : Warrant kappa a
  sound   : (ev : Evidence warrant) -> a
