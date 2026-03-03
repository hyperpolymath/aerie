# Aerie task shortcuts

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
