#!/usr/bin/env bash
# Idempotent Vault bootstrap.
#
# Brings vault-unsealer + vault from "freshly deployed by ArgoCD" to "main
# Vault initialized, unsealed, and ready to use." Each step checks current
# state before acting, so re-running after a partial run is safe.
#
# Sensitive material (unseal keys, recovery keys, root tokens, transit token)
# is written to .secrets/ at the repo root — gitignored. Move these to your
# password manager and delete the directory once stored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.secrets"

UNSEALER_NS="vault-unsealer"
UNSEALER_POD="vault-unsealer-0"
VAULT_NS="vault"
VAULT_POD="vault-0"
TRANSIT_KEY="autounseal"

log()  { printf '\033[1;34m[vault-bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
skip() { printf '\033[1;32m[skip]\033[0m %s\n' "$*"; }

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# kvault NAMESPACE POD -- vault-cmd...
kvault() {
  local ns="$1" pod="$2"; shift 2
  kubectl -n "$ns" exec "$pod" -- "$@"
}

wait_pod_running() {
  local ns="$1" pod="$2"
  log "waiting for ${ns}/${pod} to exist"
  for _ in $(seq 1 60); do
    kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "${ns}/${pod} did not appear within 5 minutes"
}

# --- preflight ---------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found"
command -v jq      >/dev/null || die "jq not found (used to parse vault JSON output)"

wait_pod_running "$UNSEALER_NS" "$UNSEALER_POD"

# --- 1. init unsealer --------------------------------------------------------

UNSEALER_KEYS_FILE="${SECRETS_DIR}/unsealer-init.json"

# `vault status` exits 0 unsealed, 1 error, 2 sealed. We don't want that
# bleeding into pipefail, so capture stdout first then jq separately.
vault_status_json() {
  local ns="$1" pod="$2"
  kubectl -n "$ns" exec "$pod" -- vault status -format=json 2>/dev/null || true
}

unsealer_initialized() {
  vault_status_json "$UNSEALER_NS" "$UNSEALER_POD" \
    | jq -e '.initialized == true' >/dev/null 2>&1
}

if unsealer_initialized; then
  skip "unsealer already initialized"
  if [[ ! -s "$UNSEALER_KEYS_FILE" ]]; then
    die "unsealer is initialized but ${UNSEALER_KEYS_FILE} is missing or empty — keys are unrecoverable. Wipe and re-init:
    kubectl -n ${UNSEALER_NS} delete pod ${UNSEALER_POD}
    kubectl -n ${UNSEALER_NS} delete pvc data-${UNSEALER_POD}
  Then re-run this script."
  fi
else
  log "initializing unsealer"
  # Write JSON inside the pod first, then copy it out — avoids any host-side
  # stdout filtering / shell wrappers truncating the keys on the way through.
  kubectl -n "$UNSEALER_NS" exec "$UNSEALER_POD" -- sh -c \
    'vault operator init -format=json > /tmp/vault-init.json'
  kubectl -n "$UNSEALER_NS" cp \
    "${UNSEALER_POD}:/tmp/vault-init.json" "$UNSEALER_KEYS_FILE"
  kubectl -n "$UNSEALER_NS" exec "$UNSEALER_POD" -- rm -f /tmp/vault-init.json

  [[ -s "$UNSEALER_KEYS_FILE" ]] || die "init succeeded but ${UNSEALER_KEYS_FILE} is empty — aborting before keys are lost"
  jq -e '.unseal_keys_b64 | length >= 3' "$UNSEALER_KEYS_FILE" >/dev/null \
    || die "${UNSEALER_KEYS_FILE} does not contain unseal_keys_b64 — aborting"

  chmod 600 "$UNSEALER_KEYS_FILE"
  log "unsealer keys written to ${UNSEALER_KEYS_FILE}"
fi

# --- 2. unseal unsealer ------------------------------------------------------

unsealer_sealed() {
  vault_status_json "$UNSEALER_NS" "$UNSEALER_POD" \
    | jq -e '.sealed == true' >/dev/null 2>&1
}

if unsealer_sealed; then
  [[ -f "$UNSEALER_KEYS_FILE" ]] || die "unsealer is sealed but ${UNSEALER_KEYS_FILE} is missing — cannot unseal automatically"
  log "unsealing unsealer"
  for i in 0 1 2; do
    KEY="$(jq -r ".unseal_keys_b64[$i] // .keys_b64[$i] // empty" "$UNSEALER_KEYS_FILE")"
    [[ -n "$KEY" ]] || die "could not extract unseal key $i from ${UNSEALER_KEYS_FILE}"
    kubectl -n "$UNSEALER_NS" exec "$UNSEALER_POD" \
      -- vault operator unseal "$KEY" >/dev/null
  done
else
  skip "unsealer already unsealed"
fi

UNSEALER_ROOT_TOKEN="$(jq -r '.root_token' "$UNSEALER_KEYS_FILE" 2>/dev/null || true)"
[[ -n "$UNSEALER_ROOT_TOKEN" && "$UNSEALER_ROOT_TOKEN" != "null" ]] \
  || die "could not read unsealer root token from ${UNSEALER_KEYS_FILE}"

# --- 3. transit engine + key + policy + token --------------------------------

unsealer_exec() {
  kubectl -n "$UNSEALER_NS" exec "$UNSEALER_POD" \
    -- env VAULT_TOKEN="$UNSEALER_ROOT_TOKEN" "$@"
}

if unsealer_exec vault secrets list -format=json | jq -e '."transit/"' >/dev/null 2>&1; then
  skip "transit engine already enabled"
else
  log "enabling transit engine"
  unsealer_exec vault secrets enable transit
fi

if unsealer_exec vault read -format=json "transit/keys/${TRANSIT_KEY}" >/dev/null 2>&1; then
  skip "transit key '${TRANSIT_KEY}' already exists"
else
  log "creating transit key '${TRANSIT_KEY}'"
  unsealer_exec vault write -f "transit/keys/${TRANSIT_KEY}" >/dev/null
fi

if unsealer_exec vault policy read autounseal >/dev/null 2>&1; then
  skip "autounseal policy already exists"
else
  log "writing autounseal policy"
  unsealer_exec sh -c 'cat <<EOF | vault policy write autounseal -
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF'
fi

# --- 4. transit token + k8s secret in vault namespace ------------------------

kubectl get ns "$VAULT_NS" >/dev/null 2>&1 || die "namespace ${VAULT_NS} does not exist yet — wait for ArgoCD to create it"

if kubectl -n "$VAULT_NS" get secret vault-unsealer-token >/dev/null 2>&1; then
  skip "vault-unsealer-token secret already exists in ${VAULT_NS}"
else
  log "creating periodic transit token"
  TRANSIT_TOKEN="$(unsealer_exec vault token create \
      -policy=autounseal -period=24h -orphan -format=json \
    | jq -r '.auth.client_token')"

  [[ -n "$TRANSIT_TOKEN" && "$TRANSIT_TOKEN" != "null" ]] \
    || die "failed to create transit token"

  echo "$TRANSIT_TOKEN" > "${SECRETS_DIR}/transit-token.txt"
  chmod 600 "${SECRETS_DIR}/transit-token.txt"

  log "creating vault-unsealer-token secret in ${VAULT_NS}"
  kubectl -n "$VAULT_NS" create secret generic vault-unsealer-token \
    --from-literal=token="$TRANSIT_TOKEN"
fi

# --- 5. main vault: wait, init, then enable k8s auth + KV --------------------

log "waiting for main vault pod to start (auto-unseal kicks in once secret is mounted)"
wait_pod_running "$VAULT_NS" "$VAULT_POD"

# Pod may be restarting to pick up the secret — give it a chance.
for _ in $(seq 1 30); do
  # Reachable if we get any JSON response, regardless of seal state.
  if vault_status_json "$VAULT_NS" "$VAULT_POD" | jq -e '.' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

VAULT_KEYS_FILE="${SECRETS_DIR}/vault-init.json"

vault_initialized() {
  vault_status_json "$VAULT_NS" "$VAULT_POD" \
    | jq -e '.initialized == true' >/dev/null 2>&1
}

if vault_initialized; then
  skip "main vault already initialized"
  if [[ ! -s "$VAULT_KEYS_FILE" ]]; then
    die "main vault is initialized but ${VAULT_KEYS_FILE} is missing — recovery keys + root token are unrecoverable from outside"
  fi
else
  log "initializing main vault (recovery keys, since transit handles unsealing)"
  kubectl -n "$VAULT_NS" exec "$VAULT_POD" -- sh -c \
    'vault operator init -recovery-shares=5 -recovery-threshold=3 -format=json > /tmp/vault-init.json'
  kubectl -n "$VAULT_NS" cp \
    "${VAULT_POD}:/tmp/vault-init.json" "$VAULT_KEYS_FILE"
  kubectl -n "$VAULT_NS" exec "$VAULT_POD" -- rm -f /tmp/vault-init.json

  [[ -s "$VAULT_KEYS_FILE" ]] || die "main vault init succeeded but ${VAULT_KEYS_FILE} is empty — aborting"
  jq -e '.root_token' "$VAULT_KEYS_FILE" >/dev/null \
    || die "${VAULT_KEYS_FILE} does not contain root_token — aborting"

  chmod 600 "$VAULT_KEYS_FILE"
  log "main vault recovery keys + root token written to ${VAULT_KEYS_FILE}"
fi

VAULT_ROOT_TOKEN="$(jq -r '.root_token' "$VAULT_KEYS_FILE" 2>/dev/null || true)"
[[ -n "$VAULT_ROOT_TOKEN" && "$VAULT_ROOT_TOKEN" != "null" ]] \
  || die "could not read main vault root token from ${VAULT_KEYS_FILE}"

# Wait until auto-unseal lands.
for _ in $(seq 1 30); do
  if ! vault_status_json "$VAULT_NS" "$VAULT_POD" \
       | jq -e '.sealed == true' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

vault_exec() {
  kubectl -n "$VAULT_NS" exec "$VAULT_POD" \
    -- env VAULT_TOKEN="$VAULT_ROOT_TOKEN" "$@"
}

if vault_exec vault auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  skip "kubernetes auth already enabled"
else
  log "enabling kubernetes auth"
  vault_exec vault auth enable kubernetes
  vault_exec vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc"
fi

if vault_exec vault secrets list -format=json | jq -e '."kv/"' >/dev/null 2>&1; then
  skip "kv-v2 engine already enabled at kv/"
else
  log "enabling kv-v2 engine at kv/"
  vault_exec vault secrets enable -path=kv -version=2 kv
fi

# --- done --------------------------------------------------------------------

log "vault is ready."
cat <<EOF

  Sensitive files in ${SECRETS_DIR} — move them to your password manager:
    - unsealer-init.json   (unsealer unseal keys + root token)
    - transit-token.txt    (transit token; also lives in the k8s secret)
    - vault-init.json      (main vault recovery keys + root token)

  Then:    rm -rf ${SECRETS_DIR}

  After unsealer pod restarts you'll need to unseal it again with 3 of its
  unseal keys; main vault auto-unseals as soon as the unsealer is reachable.
EOF
