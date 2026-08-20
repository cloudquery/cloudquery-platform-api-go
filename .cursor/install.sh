#!/usr/bin/env bash
set -euo pipefail

# Idempotent Cloud Agent setup for the CloudQuery Platform API Go client.
# Runs from the repository root after checkout. Keep it fast and repeatable:
# no dev servers, tests, or code generation here.

GOBIN_DIR="$(go env GOPATH)/bin"
export PATH="${GOBIN_DIR}:${PATH}"

# Resolve the Go toolchain pinned by go.mod (GOTOOLCHAIN=auto downloads it).
go mod download

# Warm the build cache and confirm the module compiles.
go build ./...

# Install golangci-lint at the version CI pins so `make lint` works locally.
# See .github/workflows/lint_golang.yml.
GOLANGCI_LINT_VERSION="v2.12.2"
if ! golangci-lint --version 2>/dev/null | grep -q "${GOLANGCI_LINT_VERSION#v}"; then
  go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}"
fi

# go install drops the binary in GOBIN_DIR. Symlink it onto the default PATH so
# `make lint` works in shells that don't inherit GOBIN_DIR (e.g. non-login).
if [ -x "${GOBIN_DIR}/golangci-lint" ]; then
  sudo ln -sf "${GOBIN_DIR}/golangci-lint" /usr/local/bin/golangci-lint 2>/dev/null \
    || ln -sf "${GOBIN_DIR}/golangci-lint" /usr/local/bin/golangci-lint 2>/dev/null \
    || true
fi

echo "Setup complete: $(go version), $(golangci-lint --version)"
