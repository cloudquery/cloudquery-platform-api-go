#!/usr/bin/env bash
set -uo pipefail

# Cloud Agent setup for a MULTI-REPO CloudQuery workspace.
#
# Philosophy: do NOT bake tools into the base image (they change often).
# Instead, scan every repo checked out in the workspace, detect which
# toolchains it actually needs from its own content (go.mod, package.json,
# *.tf, .pre-commit-config.yaml, ...), and install the pinned versions each
# time this script runs. Everything here is idempotent: already-correct tools
# are detected and skipped, so re-runs are fast.
#
# Runs from the primary repo root after checkout. It locates sibling repos in
# the same workspace and processes all of them.

# ---------------------------------------------------------------------------
# Pinned version defaults (overridable via env). These mirror what the repos
# pin today; live detection below overrides them from repo content when found.
# ---------------------------------------------------------------------------
GOLANGCI_LINT_VERSION_DEFAULT="${GOLANGCI_LINT_VERSION:-v2.12.2}"
TERRAFORM_VERSION_DEFAULT="${TERRAFORM_VERSION:-1.14.7}"
TFLINT_VERSION_DEFAULT="${TFLINT_VERSION:-v0.52.0}"
NODE_VERSIONS_DEFAULT="${NODE_VERSIONS:-22 24}"   # majors; exact .nvmrc pins added on top
TERRAMATE_VERSION="${TERRAMATE_VERSION:-latest}"        # repo pins only ">= 0.9.0"
TERRAFORM_DOCS_VERSION="${TERRAFORM_DOCS_VERSION:-latest}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-latest}"
HELM_VERSION="${HELM_VERSION:-latest}"
FLUX_VERSION="${FLUX_VERSION:-latest}"

BIN_DIR="/usr/local/bin"
GOBIN_DIR="$(go env GOPATH 2>/dev/null)/bin"
export PATH="${GOBIN_DIR}:${HOME}/.local/bin:${PATH}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

# Detected-needs flags and collected versions (populated by the scan).
NEED_GO=0 NEED_NODE=0 NEED_TERRAFORM=0 NEED_TFLINT=0 NEED_TFDOCS=0
NEED_PRECOMMIT=0 NEED_KUSTOMIZE=0 NEED_HELM=0 NEED_FLUX=0
GOLANGCI_VERSION="" ; TERRAFORM_VERSION_DETECTED="" ; TFLINT_VERSION_DETECTED=""
declare -A NODE_MAJORS=() ; declare -A NVMRC_PINS=() ; declare -A PNPM_VERSIONS=()
FAILURES=()

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup:warn]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[setup:FAIL]\033[0m %s\n' "$*"; FAILURES+=("$*"); }

place_bin() {  # place_bin <src-binary> <name>: expose on the default PATH
  local src="$1" name="$2"
  [ -x "$src" ] || return 1
  sudo ln -sf "$src" "${BIN_DIR}/${name}" 2>/dev/null \
    || ln -sf "$src" "${BIN_DIR}/${name}" 2>/dev/null \
    || { mkdir -p "${HOME}/.local/bin"; ln -sf "$src" "${HOME}/.local/bin/${name}"; }
}

fetch() { curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors "$@"; }

has_version() {  # has_version <needle> <cmd...>: true if <cmd> output contains
                 # <needle>. Captures output first so a non-zero exit from the
                 # tool (e.g. `tflint --version`) does not trip `pipefail`.
  local needle="$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 1
  local out; out="$("$@" 2>&1)" || true
  case "$out" in *"$needle"*) return 0 ;; *) return 1 ;; esac
}

yaml_grep() {  # yaml_grep <repo> <regex>: match only YAML manifests (avoids
               # false positives from generated specs, changelogs, or this script)
  local repo="$1" re="$2" f
  while IFS= read -r f; do
    grep -qsE "$re" "$f" && return 0
  done < <(find "$repo" -maxdepth 5 \( -name '*.yaml' -o -name '*.yml' \) \
             -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
  return 1
}

# ---------------------------------------------------------------------------
# Locate the workspace repos.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_REPO="$(dirname "$SCRIPT_DIR")"
WORKSPACE_ROOT="$(dirname "$PRIMARY_REPO")"

REPOS=()
if [ "$(basename "$WORKSPACE_ROOT")" = "repos" ]; then
  for d in "$WORKSPACE_ROOT"/*/; do
    [ -e "${d}.git" ] && REPOS+=("${d%/}")
  done
fi
# Always include the primary repo; fall back to it if no siblings were found.
case " ${REPOS[*]-} " in *" $PRIMARY_REPO "*) : ;; *) REPOS+=("$PRIMARY_REPO") ;; esac
[ "${#REPOS[@]}" -gt 0 ] || REPOS=("$PRIMARY_REPO")

log "Workspace root: ${WORKSPACE_ROOT}"
log "Repos detected: ${REPOS[*]}"

# ---------------------------------------------------------------------------
# Detection helpers (content-driven).
# ---------------------------------------------------------------------------
detect_golangci_version_in() {  # echo version found in a repo's workflows
  local repo="$1" f v
  [ -d "$repo/.github/workflows" ] || return 0
  while IFS= read -r f; do
    v="$(awk '/golangci-lint-action/{a=1} a&&/version:/{for(i=1;i<=NF;i++){g=$i;gsub(/[",]/,"",g);if(g ~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/){print g;exit}}}' "$f")"
    [ -n "$v" ] && { echo "$v"; return 0; }
  done < <(find "$repo/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
}

scan_repo() {
  local repo="$1" name; name="$(basename "$repo")"
  local found=()

  # --- Go ---
  if find "$repo" -maxdepth 3 -name go.mod -not -path '*/vendor/*' -print -quit 2>/dev/null | grep -q .; then
    NEED_GO=1; found+=("go")
    local v; v="$(detect_golangci_version_in "$repo")"
    if [ -n "$v" ]; then GOLANGCI_VERSION="$v"; found+=("golangci-lint($v)"); fi
  fi

  # --- Node / pnpm ---
  if [ -f "$repo/pnpm-lock.yaml" ] || [ -f "$repo/pnpm-workspace.yaml" ] \
     || find "$repo" -maxdepth 3 -name package.json -not -path '*/node_modules/*' -print -quit 2>/dev/null | grep -q .; then
    NEED_NODE=1; found+=("node")
    # Exact .nvmrc pins (root and nested, excluding node_modules).
    local n
    while IFS= read -r n; do
      local pin; pin="$(tr -d ' \tv' < "$n" | head -1)"
      [ -n "$pin" ] && NVMRC_PINS["$pin"]=1
    done < <(find "$repo" -maxdepth 3 -name .nvmrc -not -path '*/node_modules/*' 2>/dev/null)
    # engines.node majors + packageManager pnpm versions from package.json files.
    local pj
    while IFS= read -r pj; do
      local eng pm
      eng="$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]+"' "$pj" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
      [ -n "$eng" ] && NODE_MAJORS["$eng"]=1
      pm="$(grep -oE '"packageManager"[[:space:]]*:[[:space:]]*"pnpm@[0-9.]+' "$pj" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [ -n "$pm" ] && PNPM_VERSIONS["$pm"]=1
    done < <(find "$repo" -maxdepth 3 -name package.json -not -path '*/node_modules/*' 2>/dev/null)
  fi

  # --- Terraform / Terramate ---
  if [ -f "$repo/terramate.tm.hcl" ] \
     || find "$repo" -maxdepth 3 \( -name '*.tf' -o -name '*.tm.hcl' \) -print -quit 2>/dev/null | grep -q .; then
    NEED_TERRAFORM=1; found+=("terraform+terramate")
    local tv
    tv="$(grep -rhoE '1\.(1[0-9]|[2-9][0-9])\.[0-9]+' "$repo/config.tm.hcl" 2>/dev/null | head -1)"
    [ -n "$tv" ] && TERRAFORM_VERSION_DETECTED="$tv"
    if [ -f "$repo/.tflint.hcl" ]; then
      NEED_TFLINT=1; found+=("tflint")
      local lv; lv="$(grep -rhoE 'tflint_version:[[:space:]]*v?[0-9.]+' "$repo/.github/workflows" 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [ -n "$lv" ] && TFLINT_VERSION_DETECTED="$lv"
    fi
    [ -f "$repo/.terraform-docs.yml" ] && { NEED_TFDOCS=1; found+=("terraform-docs"); }
  fi

  # --- GitOps: kustomize / helm / flux ---
  if find "$repo" -maxdepth 4 -name kustomization.yaml -not -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
    NEED_KUSTOMIZE=1; found+=("kustomize")
  fi
  if [ -f "$repo/Chart.yaml" ] || find "$repo" -maxdepth 3 -name 'Chart.yaml' -print -quit 2>/dev/null | grep -q . \
     || yaml_grep "$repo" 'kind:[[:space:]]*HelmRelease'; then
    NEED_HELM=1; found+=("helm")
  fi
  if yaml_grep "$repo" 'toolkit\.fluxcd\.io|flux check'; then
    NEED_FLUX=1; found+=("flux")
  fi

  # --- pre-commit ---
  [ -f "$repo/.pre-commit-config.yaml" ] && { NEED_PRECOMMIT=1; found+=("pre-commit"); }

  log "  ${name}: ${found[*]:-<no known toolchain>}"
}

# ---------------------------------------------------------------------------
# Installers (each idempotent; skip when the correct version is present).
# ---------------------------------------------------------------------------
install_golangci_lint() {
  local ver="${GOLANGCI_VERSION:-$GOLANGCI_LINT_VERSION_DEFAULT}"; ver="v${ver#v}"
  if has_version "${ver#v}" golangci-lint --version; then
    log "golangci-lint ${ver} already present"
  else
    log "Installing golangci-lint ${ver}"
    go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${ver}" \
      || { fail "golangci-lint ${ver}"; return; }
  fi
  place_bin "${GOBIN_DIR}/golangci-lint" golangci-lint || true
}

install_node_and_pnpm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" || { fail "nvm not found at $NVM_DIR"; return; }

  # Build the version set: default majors + engines majors + exact .nvmrc pins.
  local versions=() v
  for v in $NODE_VERSIONS_DEFAULT; do versions+=("$v"); done
  for v in "${!NODE_MAJORS[@]}"; do versions+=("$v"); done
  for v in "${!NVMRC_PINS[@]}"; do versions+=("$v"); done
  local uniq; uniq="$(printf '%s\n' "${versions[@]}" | sort -uV)"

  local highest=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if nvm which "$v" >/dev/null 2>&1; then
      log "Node ${v} already installed"
    else
      log "Installing Node ${v}"
      nvm install "$v" >/dev/null 2>&1 || { warn "Node ${v} install failed"; continue; }
    fi
    highest="$v"
  done <<< "$uniq"
  [ -n "$highest" ] && nvm alias default "$highest" >/dev/null 2>&1

  # Enable corepack on the default node and prefetch each pinned pnpm.
  nvm use default >/dev/null 2>&1 || true
  corepack enable >/dev/null 2>&1 || warn "corepack enable failed"
  local pv
  for pv in "${!PNPM_VERSIONS[@]}"; do
    log "Preparing pnpm@${pv}"
    corepack prepare "pnpm@${pv}" --activate >/dev/null 2>&1 || warn "pnpm@${pv} prepare failed"
  done
  # Expose node/npm/npx/corepack/pnpm on the default PATH. The workspace ships a
  # node at /exec-daemon/node that shadows /usr/local/bin, but GOBIN_DIR
  # (~/go/bin) sorts BEFORE /exec-daemon on PATH, so symlinking there wins.
  local nbin; nbin="$(dirname "$(nvm which default 2>/dev/null)")" || true
  if [ -n "$nbin" ] && [ -d "$nbin" ]; then
    mkdir -p "$GOBIN_DIR"
    local t
    for t in node npm npx corepack pnpm; do
      if [ -e "$nbin/$t" ]; then
        ln -sf "$nbin/$t" "${GOBIN_DIR}/$t" 2>/dev/null || true
        place_bin "$nbin/$t" "$t" || true
      fi
    done
  fi
}

install_terraform() {
  local ver="${TERRAFORM_VERSION_DETECTED:-$TERRAFORM_VERSION_DEFAULT}"
  if has_version "v${ver}" terraform version; then
    log "terraform ${ver} already present"; return
  fi
  log "Installing terraform ${ver}"
  local tmp; tmp="$(mktemp -d)"
  if fetch -o "$tmp/tf.zip" "https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_amd64.zip" \
     && (cd "$tmp" && unzip -oq tf.zip); then
    # Copy the real binary (tmp is ephemeral, so a symlink would dangle).
    sudo cp "$tmp/terraform" "${BIN_DIR}/terraform" 2>/dev/null \
      || { mkdir -p "${HOME}/.local/bin"; cp "$tmp/terraform" "${HOME}/.local/bin/terraform"; }
  else
    fail "terraform ${ver}"
  fi
  rm -rf "$tmp"
}

install_terramate() {
  if command -v terramate >/dev/null 2>&1 && [ "$TERRAMATE_VERSION" = "latest" ]; then
    log "terramate already present ($(terramate --version 2>/dev/null | head -1))"
  else
    log "Installing terramate (${TERRAMATE_VERSION})"
    local ref="latest"; [ "$TERRAMATE_VERSION" != "latest" ] && ref="v${TERRAMATE_VERSION#v}"
    go install "github.com/terramate-io/terramate/cmd/terramate@${ref}" 2>/dev/null \
      || { fail "terramate"; return; }
  fi
  place_bin "${GOBIN_DIR}/terramate" terramate || true
}

install_tflint() {
  local ver="${TFLINT_VERSION_DETECTED:-$TFLINT_VERSION_DEFAULT}"; ver="v${ver#v}"
  if has_version "${ver#v}" tflint --version; then
    log "tflint ${ver} already present"; return
  fi
  log "Installing tflint ${ver}"
  local tmp; tmp="$(mktemp -d)"
  if fetch -o "$tmp/tflint.zip" "https://github.com/terraform-linters/tflint/releases/download/${ver}/tflint_linux_amd64.zip" \
     && (cd "$tmp" && unzip -oq tflint.zip); then
    sudo cp "$tmp/tflint" "${BIN_DIR}/tflint" 2>/dev/null || cp "$tmp/tflint" "${HOME}/.local/bin/tflint"
  else
    warn "tflint ${ver} download failed"
  fi
  rm -rf "$tmp"
}

install_terraform_docs() {
  if command -v terraform-docs >/dev/null 2>&1; then
    log "terraform-docs already present"
  else
    log "Installing terraform-docs (${TERRAFORM_DOCS_VERSION})"
    local ref="latest"; [ "$TERRAFORM_DOCS_VERSION" != "latest" ] && ref="v${TERRAFORM_DOCS_VERSION#v}"
    go install "github.com/terraform-docs/terraform-docs@${ref}" 2>/dev/null || warn "terraform-docs install failed"
  fi
  place_bin "${GOBIN_DIR}/terraform-docs" terraform-docs || true
}

install_kustomize() {
  if command -v kustomize >/dev/null 2>&1; then
    log "kustomize already present"
  else
    log "Installing kustomize (${KUSTOMIZE_VERSION})"
    local ref="latest"; [ "$KUSTOMIZE_VERSION" != "latest" ] && ref="v${KUSTOMIZE_VERSION#v}"
    go install "sigs.k8s.io/kustomize/kustomize/v5@${ref}" 2>/dev/null || warn "kustomize install failed"
  fi
  place_bin "${GOBIN_DIR}/kustomize" kustomize || true
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then log "helm already present"; return; fi
  log "Installing helm (${HELM_VERSION})"
  local tmp; tmp="$(mktemp -d)"
  if fetch -o "$tmp/get-helm-3" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3; then
    if [ "$HELM_VERSION" = "latest" ]; then
      USE_SUDO=true HELM_INSTALL_DIR="$BIN_DIR" bash "$tmp/get-helm-3" >/dev/null 2>&1 || warn "helm install failed"
    else
      USE_SUDO=true HELM_INSTALL_DIR="$BIN_DIR" bash "$tmp/get-helm-3" --version "v${HELM_VERSION#v}" >/dev/null 2>&1 || warn "helm install failed"
    fi
  else
    warn "helm installer download failed"
  fi
  rm -rf "$tmp"
}

install_flux() {
  if command -v flux >/dev/null 2>&1; then log "flux already present"; return; fi
  log "Installing flux (${FLUX_VERSION})"
  local tmp; tmp="$(mktemp -d)"
  if fetch -o "$tmp/flux-install.sh" https://fluxcd.io/install.sh; then
    if [ "$FLUX_VERSION" = "latest" ]; then
      sudo env bash "$tmp/flux-install.sh" >/dev/null 2>&1 || bash "$tmp/flux-install.sh" >/dev/null 2>&1 || warn "flux install failed"
    else
      sudo env FLUX_VERSION="${FLUX_VERSION#v}" bash "$tmp/flux-install.sh" >/dev/null 2>&1 || warn "flux install failed"
    fi
  else
    warn "flux installer download failed"
  fi
  rm -rf "$tmp"
}

install_precommit() {
  if command -v pre-commit >/dev/null 2>&1; then log "pre-commit already present"; return; fi
  log "Installing pre-commit"
  if command -v pipx >/dev/null 2>&1; then
    pipx install pre-commit >/dev/null 2>&1 || warn "pipx pre-commit failed"
  elif command -v pip3 >/dev/null 2>&1; then
    pip3 install --user --quiet pre-commit >/dev/null 2>&1 || pip3 install --break-system-packages --user --quiet pre-commit >/dev/null 2>&1 || warn "pip pre-commit failed"
  else
    warn "no pip/pipx available for pre-commit"
  fi
}

# ---------------------------------------------------------------------------
# Run: scan, then install the union of detected needs.
# ---------------------------------------------------------------------------
log "Scanning repos for required toolchains..."
for repo in "${REPOS[@]}"; do scan_repo "$repo"; done

log "Installing tools for detected toolchains..."
[ "$NEED_GO" = 1 ]        && install_golangci_lint
[ "$NEED_NODE" = 1 ]      && install_node_and_pnpm
[ "$NEED_TERRAFORM" = 1 ] && { install_terraform; install_terramate; }
[ "$NEED_TFLINT" = 1 ]    && install_tflint
[ "$NEED_TFDOCS" = 1 ]    && install_terraform_docs
[ "$NEED_KUSTOMIZE" = 1 ] && install_kustomize
[ "$NEED_HELM" = 1 ]      && install_helm
[ "$NEED_FLUX" = 1 ]      && install_flux
[ "$NEED_PRECOMMIT" = 1 ] && install_precommit

# ---------------------------------------------------------------------------
# Summary. Fail only if a required language toolchain/linter is missing.
# ---------------------------------------------------------------------------
echo
log "===== Tool summary ====="
command -v go            >/dev/null 2>&1 && echo "  go:            $(go version 2>/dev/null)"
command -v golangci-lint >/dev/null 2>&1 && echo "  golangci-lint: $(golangci-lint --version 2>/dev/null)"
command -v node          >/dev/null 2>&1 && echo "  node:          $(node --version 2>/dev/null) (default)"
command -v pnpm          >/dev/null 2>&1 && echo "  pnpm:          $(pnpm --version 2>/dev/null)"
command -v terraform     >/dev/null 2>&1 && echo "  terraform:     $(terraform version 2>/dev/null | head -1)"
command -v terramate     >/dev/null 2>&1 && echo "  terramate:     $(terramate --version 2>/dev/null | head -1)"
command -v tflint        >/dev/null 2>&1 && echo "  tflint:        $(tflint --version 2>/dev/null | head -1)"
command -v terraform-docs>/dev/null 2>&1 && echo "  terraform-docs:$(terraform-docs --version 2>/dev/null | head -1)"
command -v kustomize     >/dev/null 2>&1 && echo "  kustomize:     $(kustomize version 2>/dev/null | head -1)"
command -v helm          >/dev/null 2>&1 && echo "  helm:          $(helm version --short 2>/dev/null)"
command -v flux          >/dev/null 2>&1 && echo "  flux:          $(flux --version 2>/dev/null)"
command -v pre-commit    >/dev/null 2>&1 && echo "  pre-commit:    $(pre-commit --version 2>/dev/null)"

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo
  fail "Required tools failed to install: ${FAILURES[*]}"
  exit 1
fi
log "Setup complete."
