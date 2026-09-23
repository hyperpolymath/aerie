<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Bottom-up K9/SVC component specifications.


Component specs in Nickel/K9 with guarded rendered AsciiDoc outputs. Changing specs/outputs without updating manifest.sha256 fails the pre-commit hook (just specs-hooks).

| Entry | Purpose |
|-------|---------|
| `components/` | component specs (k9.ncl + md) |
| `fragments/` | shared spec fragments |
| `outputs/` | guarded rendered AsciiDoc outputs |
| `tools/` | manifest + hook tooling |
| `k9/` | k9 pedigree |

See [`aerie_chora.deed`](../aerie_chora.deed) for the canonical machine-readable description of this layer.
