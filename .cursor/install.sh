#!/usr/bin/env bash
set -euo pipefail

# Idempotent Cloud Agent setup for the CloudQuery Platform API Go client.
# Runs from the repository root after checkout. Keep it fast and repeatable:
# no dev servers, tests, or code generation here.

# Resolve the Go toolchain pinned by go.mod (GOTOOLCHAIN=auto downloads it).
go mod download

# Warm the build cache and confirm the module compiles.
go build ./...

# Install golangci-lint at the version CI pins so `make lint` works locally.
# See .github/workflows/lint_golang.yml. go install drops the binary in
# "$(go env GOPATH)/bin", which is already on PATH.
GOLANGCI_LINT_VERSION="v2.12.2"
if ! golangci-lint --version 2>/dev/null | grep -q "${GOLANGCI_LINT_VERSION#v}"; then
  go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}"
fi

echo "Setup complete: $(go version), $(golangci-lint --version)"
