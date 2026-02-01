# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: Known limitations + guardrails

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-known-limitations",
    version = "1.0.0-alpha",
    description = "Documented guardrails for storage, secrets, and automation limits",
  },
  target = {
    os = 'Linux,
    requires_podman = true,
  },
  security = {
    trust_level = 'Yard,
  },
  validation = {
    checksum = "sha256:placeholder",
  },
} in

{
  pedigree = component_pedigree,

  limitations = [
    {
      id = "relative-bind-banned",
      description = "Relative host paths are rejected because Vörðr MCP stores named volumes under the project root, and docker/docker-compose-style relative binds risk escaping the managed directory.",
      mitigation = "Use absolute paths or named volumes defined in the compose file; guards will log the rejected spec.",
    },
    {
      id = "dev-secrets-gated",
      description = "Secrets can only be injected via file mounts unless `SELUR_DEV_SECRETS=1` is set; developer mode prints a warning before populating env vars.",
      mitigation = "Always store secrets in sealed storage (Vault, Argo) and map them to `/run/secrets` mounts.",
    },
    {
      id = "rate-limit-automation",
      description = "Cloudflare/LibreSpeed endpoints block aggressive automated clients and may flag bot-like patterns.",
      mitigation = "The CF-NDS dashboard exposes authenticated APIs with policy throttles and fallback to self-hosted tests (LibreSpeed/Hyperglass) so automation stays under control.",
    },
    {
      id = "in-place-edit-guarded",
      description = "Spec outputs (AsciiDoc) and policy documents are auto-generated and marked read-only to stop manual edits that would bypass manifest verification.",
      mitigation = "Run `just specs` to regenerate and update `specs/manifest.sha256` before editing any component.",
    },
  ],
}
