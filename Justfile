# Aerie task shortcuts

import? "contractile.just"

specs:
	@./specs/tools/update_manifest.sh

specs-check:
	@./specs/tools/check_manifest.sh

specs-hooks:
	@./specs/tools/install_hooks.sh

specs-unlock:
	@./specs/tools/unlock_outputs.sh

specs-verify:
	@./specs/tools/check_manifest.sh
	@./specs/tools/install_hooks.sh

# --- API Generation ---

# Generate V-lang stubs from Protobuf
specs-to-v:
	@echo "Generating verified V-lang stubs (gRPC)..."
	../developer-ecosystem/v-ecosystem/v-api-interfaces/v-grpc/bin/v-grpc-gen src/api/proto/aerie.proto

# Generate V-lang stubs from GraphQL
specs-to-v-gql:
	@echo "Generating verified V-lang stubs (GraphQL)..."
	../developer-ecosystem/v-ecosystem/v-api-interfaces/v-graphql/bin/v-graphql-gen src/api/graphql/schema.graphql



# --- SECURITY ---

# Run security audit suite
security:
    @echo "=== Security Audit ==="
    @command -v gitleaks >/dev/null && gitleaks detect --source . --verbose || echo "gitleaks not found"
    @command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL . || echo "trivy not found"
    @echo "Security audit complete"

# Scan for vulnerabilities in dependencies
audit:
    @echo "=== Dependency Audit ==="
    @# Check Rust/Python/Node if tools exist
    @if [ -f Cargo.toml ]; then cargo audit; fi
    @if [ -f pyproject.toml ]; then bandit -r .; fi
    @echo "Dependency audit complete"

# --- QUALITY ---

# Run all tests
tests:
    @echo "=== Running Tests ==="
    @if [ -d qubes-sdp ] && [ -f qubes-sdp/justfile ]; then (cd qubes-sdp && just test); fi
    @if [ -d bgp-backbone-lab ] && [ -f bgp-backbone-lab/justfile ]; then (cd bgp-backbone-lab && just test); fi
    @echo "Tests complete"

# Run all quality checks
quality: lint tests


# Run linters
lint:
    @echo "=== Linting ==="
    @command -v shellcheck >/dev/null && find . -name "*.sh" -exec shellcheck {} + || echo "shellcheck not found"
    @command -v typos >/dev/null && typos . || echo "typos not found"
    @echo "Linting complete"

# Run panic-attacker pre-commit scan
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"

# ═══════════════════════════════════════════════════════════════════════════════
# ONBOARDING & DIAGNOSTICS
# ═══════════════════════════════════════════════════════════════════════════════

# Check all required toolchain dependencies and report health
doctor:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Aerie Doctor — Toolchain Health Check"
    echo "═══════════════════════════════════════════════════"
    echo ""
    PASS=0; FAIL=0; WARN=0
    check() {
        local name="$1" cmd="$2" min="$3"
        if command -v "$cmd" >/dev/null 2>&1; then
            VER=$("$cmd" --version 2>&1 | head -1)
            echo "  [OK]   $name — $VER"
            PASS=$((PASS + 1))
        else
            echo "  [FAIL] $name — not found (need $min+)"
            FAIL=$((FAIL + 1))
        fi
    }
    check "just"              just      "1.25" 
    check "git"               git       "2.40" 
    check "Zig"               zig       "0.13" 
    # Optional tools
    if command -v panic-attack >/dev/null 2>&1; then
        echo "  [OK]   panic-attack — available"
        PASS=$((PASS + 1))
    else
        echo "  [WARN] panic-attack — not found (pre-commit scanner)"
        WARN=$((WARN + 1))
    fi
    echo ""
    echo "  Result: $PASS passed, $FAIL failed, $WARN warnings"
    if [ "$FAIL" -gt 0 ]; then
        echo "  Run 'just heal' to attempt automatic repair."
        exit 1
    fi
    echo "  All required tools present."

# Attempt to automatically install missing tools
heal:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Aerie Heal — Automatic Tool Installation"
    echo "═══════════════════════════════════════════════════"
    echo ""
    if ! command -v just >/dev/null 2>&1; then
        echo "Installing just..."
        cargo install just 2>/dev/null || echo "Install just from https://just.systems"
    fi
    echo ""
    echo "Heal complete. Run 'just doctor' to verify."

# Guided tour of the project structure and key concepts
tour:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Aerie — Guided Tour"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo 'A high-assurance alternative to commercial speedtests. CF-NDS is designed to provide network engineers with the raw data required to diagnose routing interference, BGP hijacks, or ISP throttling without the privacy risks of third-party telemetry.'
    echo ""
    echo "Key directories:"
    echo "  src/                      Source code" 
    echo "  ffi/                      Foreign function interface (Zig)" 
    echo "  src/abi/                  Idris2 ABI definitions" 
    echo "  docs/                     Documentation" 
    echo "  tests/                    Test suite" 
    echo "  .github/workflows/        CI/CD workflows" 
    echo "  contractiles/             Must/Trust/Dust contracts" 
    echo "  .machine_readable/        Machine-readable metadata" 
    echo "  examples/                 Usage examples" 
    echo ""
    echo "Quick commands:"
    echo "  just doctor    Check toolchain health"
    echo "  just heal      Fix missing tools"
    echo "  just help-me   Common workflows"
    echo "  just default   List all recipes"
    echo ""
    echo "Read more: README.adoc, EXPLAINME.adoc"

# Show help for common workflows
help-me:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Aerie — Common Workflows"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "FIRST TIME SETUP:"
    echo "  just doctor           Check toolchain"
    echo "  just heal             Fix missing tools"
    echo "" 
    echo "PRE-COMMIT:"
    echo "  just assail           Run panic-attacker scan"
    echo ""
    echo "LEARN:"
    echo "  just tour             Guided project tour"
    echo "  just default          List all recipes" 


# Print the current CRG grade (reads from READINESS.md '**Current Grade:** X' line)
crg-grade:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    echo "$$grade"

# Generate a shields.io badge markdown for the current CRG grade
# Looks for '**Current Grade:** X' in READINESS.md; falls back to X
crg-badge:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    case "$$grade" in \
      A) color="brightgreen" ;; B) color="green" ;; C) color="yellow" ;; \
      D) color="orange" ;; E) color="red" ;; F) color="critical" ;; \
      *) color="lightgrey" ;; esac; \
    echo "[![CRG $$grade](https://img.shields.io/badge/CRG-$$grade-$$color?style=flat-square)](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)"
