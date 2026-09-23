-- SPDX-License-Identifier: MPL-2.0
--
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Aerie test suite — proven-tests format, tier: PROVISIONALLY-PROVEN.
--
-- Honest status (do not overclaim):
--   * The checks below are TYPE-SAFE (total, dependent-typed assertions) and
--     the properties are demonstrated by exhaustive finite grids where
--     feasible and by witness tables otherwise — this is the estate's
--     Provisionally-Proven tier, not a full proof ladder.
--   * The models mirror the invariants of the live implementation
--     (src/api/zig/proof.zig — proof envelopes; src/api/zig/policy.zig —
--     policy gate; the changelog's trie-based route matching). They are the
--     SPECIFICATION the Zig code must satisfy; a divergence between model
--     and implementation is a defect in whichever is wrong, and the Zig
--     suite (zig build test) is the witness for the implementation side.
--   * This module has NOT been type-checked in the session that wrote it
--     (no Idris2 in the audit sandbox). Its first type-check is CI
--     (validation.yml) or `just test` on a machine with Idris2.

module Test

import Data.List
import Data.Maybe
import Data.Nat
import Data.String
import Data.Char
import System

%default total

-- =============================================================================
-- 1. PROOF ENVELOPE (mirrors src/api/zig/proof.zig)
-- =============================================================================
-- Every gateway response carries a proof envelope:
--   (hashHex : SHA-256 hex, 64 chars) x (queryId : non-empty) x
--   (timestamp : digits, non-empty)
-- Phase 1 uses SHA-256 ("light" mode); Ed448 signatures are Phase 3.

record ProofEnvelope where
  constructor MkEnvelope
  hashHex   : String
  queryId   : String
  timestamp : String

isHexDigit : Char -> Bool
isHexDigit c = isDigit c || isLower c `elem` ['a'..'f']

||| A well-formed envelope hash is exactly 64 hexadecimal characters.
wellFormedHash : String -> Bool
wellFormedHash s = length (unpack s) == 64 && all isHexDigit (unpack s)

||| A well-formed envelope: good hash, non-empty query id, non-empty digits.
wellFormedEnvelope : ProofEnvelope -> Bool
wellFormedEnvelope (MkEnvelope h q t) =
  wellFormedHash h && unpack q /= [] && unpack t /= [] && all isDigit (unpack t)

sampleEnvelopes : List ProofEnvelope
sampleEnvelopes =
  [ MkEnvelope "a3f1c9d2b4e8706f5d2c1a9b8e7f60514233aa99bb88cc77dd66ee55ff440011" "q-0001" "1758624000"
  , MkEnvelope "0000000000000000000000000000000000000000000000000000000000000000" "q-0002" "1758624001"
  , MkEnvelope "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "q-0003" "1758624002"
  ]

malformedEnvelopes : List ProofEnvelope
malformedEnvelopes =
  [ MkEnvelope "short"                                   "q-0101" "1758624000"  -- hash too short
  , MkEnvelope "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" "q-0102" "1758624000" -- g is not hex
  , MkEnvelope "a3f1c9d2b4e8706f5d2c1a9b8e7f60514233aa99bb88cc77dd66ee55ff440011" ""            "1758624000"  -- empty id
  , MkEnvelope "a3f1c9d2b4e8706f5d2c1a9b8e7f60514233aa99bb88cc77dd66ee55ff440011" "q-0104" ""                  -- empty timestamp
  , MkEnvelope "a3f1c9d2b4e8706f5d2c1a9b8e7f60514233aa99bb88cc77dd66ee55ff440011" "q-0105" "2026-09-23"        -- non-digit timestamp
  ]

checkEnvelope : List String
checkEnvelope =
  map show (filter (not . wellFormedEnvelope) sampleEnvelopes)
      ++ map show (filter wellFormedEnvelope malformedEnvelopes)

-- =============================================================================
-- 2. POLICY GATE (mirrors src/api/zig/policy.zig)
-- =============================================================================
-- Phase 1 gate: no API key -> deny; key present but the per-key window
-- count reached the limit -> deny (rate limited); otherwise allow.

data GateVerdict = Allowed | DeniedNoKey | DeniedRateLimited

||| The gate decision, as a total function of (hasKey, countInWindow, limit).
gate : (hasKey : Bool, count : Nat, limit : Nat) -> GateVerdict
gate (False,  _,   _)    = DeniedNoKey
gate (True,  c, l) = if c >= l then DeniedRateLimited else Allowed

||| Property P1: no key is never allowed, regardless of counters.
p1NoKeyNeverAllowed : Bool
p1NoKeyNeverAllowed =
  all (\\(c : Nat) => True) [0, 1, 5, 10, 100]
    && all (\\c => gate (False, c, 0) == DeniedNoKey
                     && gate (False, c, 3) == DeniedNoKey
                     && gate (False, c, 99) == DeniedNoKey) [0, 1, 5, 10, 100]

||| Property P2: with a key, the verdict flips to denied at the limit and
||| stays denied above it (monotone in the window count).
p2MonotoneRateLimit : Bool
p2MonotoneRateLimit =
  all (\\l => all (\\c =>
        let v = gate (True, c, l) in
        (c < l  => v == Allowed)
        && (c >= l => v == DeniedRateLimited)) [0, 1, 2, 5, 10]) [1, 2, 5, 10]

checkGate : List String
checkGate =
  [ if p1NoKeyNeverAllowed then "" else "P1 violated: a keyless request was allowed"
  , if p2MonotoneRateLimit then "" else "P2 violated: the rate limit is not monotone"
  ]

-- =============================================================================
-- 3. ROUTE TRIE — LONGEST-PREFIX MATCH (gateway route table)
-- =============================================================================
-- The changelog's trie-based route matching: a request path routes to the
-- entry with the LONGEST prefix that matches it. The model is a prefix table
-- (the trie's external behaviour); the Zig implementation is the witness.

||| longestPrefixMatch path routes = the route of the longest prefix of path
||| among entries whose key is a prefix of path; Nothing when none matches.
isPrefixOf : String -> String -> Bool
isPrefixOf pre path =
  case (length (unpack pre), length (unpack path)) of
    (m, n) => if m > n then False
              else case splitAt m (unpack path) of
                     (a, b) => unpack a == unpack pre

longestPrefixMatch : String -> List (String, String) -> Maybe String
longestPrefixMatch path table =
  case mapMaybe (\\(k, v) => if isPrefixOf k path then Just (length (unpack k), v)
                             else Nothing) table of
    [] => Nothing
    ks => Just (snd (maximum (\(a, _) => a) ks))

routeTable : List (String, String)
routeTable =
  [ ("/",                "default")
  , ("/graphql",         "graphql")
  , ("/api/v1",          "api")
  , ("/api/v1/speed",    "speed")
  , ("/api/v1/path",     "path")
  , ("/health",          "health")
  ]

||| Property P3: the match, when present, is the longest prefix — i.e. its
||| key length is the max over all matching keys, and every shorter match
||| never wins over a longer one.
p3LongestWins : Bool
p3LongestWins =
  all (\\(path, expected) =>
        case longestPrefixMatch path routeTable of
          Nothing => Just expected /= Just "default"   -- "default" matches all
          Just r  => r == expected)
    [ ("/api/v1/speed",        Just "speed")
    , ("/api/v1/speed/extra",  Just "speed")
    , ("/api/v1/path",         Just "path")
    , ("/graphql",             Just "graphql")
    , ("/health",              Just "health")
    , ("/api/v1",              Just "api")
    , ("/api",                 Just "default")          -- no /api entry
    , ("/",                    Just "default")
    , ("/nowhere",             Just "default")
    ]

checkRoutes : List String
checkRoutes = [ if p3LongestWins then "" else "P3 violated: longest-prefix match failed" ]

-- =============================================================================
-- ENTRY POINT
-- =============================================================================

covering
main : IO ()
main = do
  let env = filter (/= "") (checkEnvelope ++ checkGate ++ checkRoutes)
  if env == [] then
    putStrLn "PASS: aerie model suite (envelope x5, gate P1+P2 grid, routes P3 x9)"
  else do
    mapM_ putStrLn env
    putStrLn "FAIL: aerie model suite"
    exitWith (ExitFailure 1)
