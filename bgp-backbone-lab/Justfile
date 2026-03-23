# SPDX-License-Identifier: PMPL-1.0-or-later
# Justfile - BGP backbone lab deployment automation

default:
    @just --list

# Deploy BGP lab topology via containerlab
deploy:
    @echo "Deploying BGP backbone lab..."
    containerlab deploy --topo topologies/flatracoon-bgp.clab.yml
    @echo "BGP lab deployed"

# Destroy BGP lab topology
destroy:
    @echo "Destroying BGP backbone lab..."
    containerlab destroy --topo topologies/flatracoon-bgp.clab.yml
    @echo "BGP lab destroyed"

# Deploy via K8s Job (for in-cluster deployment)
deploy-k8s:
    kubectl apply -f manifests/containerlab-job.yaml
    @echo "K8s containerlab job submitted"

# Show topology status
status:
    containerlab inspect --topo topologies/flatracoon-bgp.clab.yml 2>/dev/null || echo "Not deployed"

# Build the project (ABI/FFI compilation)
build:
    @echo "Building ABI definitions..."

# Run tests
test:
    @echo "Testing..."

# Run lints
lint:
    @echo "Linting..."

# Clean build artifacts
clean:
    @echo "Cleaning..."

# Format code
fmt:
    @echo "Formatting..."

# Run all checks
check: lint test

# Prepare a release
release VERSION:
    @echo "Releasing {{VERSION}}..."
