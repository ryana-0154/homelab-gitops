#!/usr/bin/env bash
# Non-destructive cluster bootstrap.
#
# Verifies prerequisites and applies the ArgoCD root Application. Re-running
# is safe — every step is idempotent (kubectl apply / existence checks only).
#
# Does NOT install ArgoCD itself; that's a one-time decision left to the
# operator. If argocd is missing, this script tells you and exits.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_APP="${REPO_ROOT}/bootstrap/root-app.yaml"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found in PATH"

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || die "no current kubectl context — run 'kubectl config use-context …' first"
log "context: ${CTX}"

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "cannot reach cluster on context '${CTX}'"
fi

# --- argocd presence ---------------------------------------------------------

if ! kubectl get ns argocd >/dev/null 2>&1; then
  die "argocd namespace not found — install ArgoCD first, then re-run.

  Quick install:
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
"
fi

if ! kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
  warn "argocd namespace exists but argocd-server deployment is missing — install may be incomplete"
fi

# --- root app ----------------------------------------------------------------

[[ -f "$ROOT_APP" ]] || die "root app manifest not found at ${ROOT_APP}"

log "applying root Application"
kubectl apply -n argocd -f "$ROOT_APP"

# --- summary -----------------------------------------------------------------

log "done. ArgoCD will reconcile apps/ on its own."
log "watch progress:"
echo "    kubectl -n argocd get applications -w"
echo
log "next: once vault + vault-unsealer pods exist, run scripts/vault-bootstrap.sh"
