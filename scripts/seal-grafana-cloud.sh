#!/usr/bin/env bash
# Seal Grafana Cloud credentials for the k8s-monitoring stack.
#
# Prompts for the metrics username (numeric instance ID), logs username,
# and a single Access Policy token with metrics:write + logs:write scopes,
# then writes a SealedSecret to secrets/monitoring/grafana-cloud-credentials.yaml.
#
# Re-run to rotate the token. Review the diff before committing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/secrets/monitoring/grafana-cloud-credentials.yaml"

NAMESPACE="monitoring"
SECRET_NAME="grafana-cloud-credentials"
CONTROLLER_NS="sealed-secrets"
CONTROLLER_NAME="sealed-secrets-controller"

log() { printf '\033[1;34m[seal]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl  >/dev/null || die "kubectl not found"
command -v kubeseal >/dev/null || die "kubeseal not found — install from https://github.com/bitnami-labs/sealed-secrets/releases"

kubectl -n "$CONTROLLER_NS" get deploy "$CONTROLLER_NAME" >/dev/null 2>&1 \
  || die "sealed-secrets controller not found at ${CONTROLLER_NS}/${CONTROLLER_NAME} — wait for ArgoCD to deploy it first"

mkdir -p "$(dirname "$OUT")"

read -r -p "Grafana Cloud metrics username (instance ID): " METRICS_USER
[[ -n "$METRICS_USER" ]] || die "metrics username is required"

read -r -p "Grafana Cloud logs username (instance ID): " LOGS_USER
[[ -n "$LOGS_USER" ]] || die "logs username is required"

read -r -s -p "Grafana Cloud Access Policy token: " TOKEN
echo
[[ -n "$TOKEN" ]] || die "token is required"

log "sealing credentials into ${OUT}"
kubectl create secret generic "$SECRET_NAME" \
    --namespace="$NAMESPACE" \
    --from-literal=metrics-username="$METRICS_USER" \
    --from-literal=logs-username="$LOGS_USER" \
    --from-literal=password="$TOKEN" \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-namespace="$CONTROLLER_NS" \
      --controller-name="$CONTROLLER_NAME" \
      --format=yaml \
  > "$OUT"

log "done."
echo "    review:  git diff ${OUT#${REPO_ROOT}/}"
echo "    commit + push to apply"
