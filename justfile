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


