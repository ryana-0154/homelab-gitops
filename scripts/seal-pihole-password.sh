#!/usr/bin/env bash
# Generate a pihole admin password, seal it with kubeseal, and write a
# SealedSecret manifest to secrets/pihole/admin.yaml ready to commit.
#
# Re-running rotates the password — review the diff before committing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/secrets/pihole/admin.yaml"
SECRETS_DIR="${REPO_ROOT}/.secrets"

NAMESPACE="pihole"
SECRET_NAME="pihole-admin"
CONTROLLER_NS="sealed-secrets"
CONTROLLER_NAME="sealed-secrets-controller"

log() { printf '\033[1;34m[seal]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl  >/dev/null || die "kubectl not found"
command -v kubeseal >/dev/null || die "kubeseal not found — install from https://github.com/bitnami-labs/sealed-secrets/releases"

kubectl -n "$CONTROLLER_NS" get deploy "$CONTROLLER_NAME" >/dev/null 2>&1 \
  || die "sealed-secrets controller not found at ${CONTROLLER_NS}/${CONTROLLER_NAME} — wait for ArgoCD to deploy it first"

mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
mkdir -p "$(dirname "$OUT")"

PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
printf '%s\n' "$PASSWORD" > "${SECRETS_DIR}/pihole-admin-password.txt"
chmod 600 "${SECRETS_DIR}/pihole-admin-password.txt"
log "plaintext password saved to .secrets/pihole-admin-password.txt (gitignored)"

log "sealing password into ${OUT}"
kubectl create secret generic "$SECRET_NAME" \
    --namespace="$NAMESPACE" \
    --from-literal=password="$PASSWORD" \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-namespace="$CONTROLLER_NS" \
      --controller-name="$CONTROLLER_NAME" \
      --format=yaml \
  > "$OUT"

log "done."
echo "    review:  git diff ${OUT#${REPO_ROOT}/}"
echo "    commit + push to apply"
