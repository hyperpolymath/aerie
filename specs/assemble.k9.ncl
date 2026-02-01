# SPDX-License-Identifier: PMPL-1.0-or-later
# Assemble Aerie specs from bottom-up K9 components (Yard level only).

let policy = import "components/policy-entitlements.k9.ncl" in
let graphql = import "components/graphql-schema.k9.ncl" in
let proof = import "components/proof-envelope.k9.ncl" in
let bitemporal = import "components/bitemporal-store.k9.ncl" in
let transport = import "components/subscription-transport.k9.ncl" in
let gate = import "components/resolver-policy-gate.k9.ncl" in
let auth = import "components/subscription-auth-flow.k9.ncl" in
let vql = import "components/vql-mapping.k9.ncl" in
let osi = import "components/osi-forensics-matrix.k9.ncl" in
let collector = import "components/passive-collector.k9.ncl" in
let hud = import "components/hud-module-mapping.k9.ncl" in
let gate_impl = import "components/resolver-policy-gate-impl.k9.ncl" in

{
  components = {
    policy = policy,
    graphql = graphql,
    proof = proof,
    bitemporal = bitemporal,
    transport = transport,
    gate = gate,
    auth = auth,
    vql = vql,
    osi = osi,
    collector = collector,
    hud = hud,
    gate_impl = gate_impl,
  },

  outputs = [
    "outputs/policy-entitlements.adoc",
    "outputs/graphql-schema.adoc",
    "outputs/proof-envelope.adoc",
    "outputs/bitemporal-store.adoc",
    "outputs/subscription-transport.adoc",
    "outputs/resolver-policy-gate.adoc",
    "outputs/subscription-auth-flow.adoc",
    "outputs/vql-mapping.adoc",
    "outputs/osi-forensics-matrix.adoc",
    "outputs/passive-collector.adoc",
    "outputs/hud-module-mapping.adoc",
    "outputs/resolver-policy-gate-impl.adoc",
  ],

  notes = [
    "All components are Yard-level (no execution).",
    "Outputs are rendered separately into specs/outputs/ for humans.",
  ],
}
