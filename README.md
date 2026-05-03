# homelab-gitops

ArgoCD app-of-apps for homelab cluster.

## Layout

- `bootstrap/root-app.yaml` — seed `Application` pointing at `apps/`. Apply once.
- `apps/` — Helm chart that renders one `Application` per entry in `values.yaml`.

## Bootstrap

1. Edit `bootstrap/root-app.yaml` and set `spec.source.repoURL` to this repo's URL.
2. Apply it to the cluster:

   ```sh
   kubectl apply -n argocd -f bootstrap/root-app.yaml
   ```

ArgoCD then reconciles `apps/` and creates every child `Application` defined in `apps/values.yaml`.

## Adding an app

Two source types are supported.

**Git source** (manifests / kustomize / chart-in-a-repo):

```yaml
- name: myapp
  repoUrl: https://github.com/me/myapp
  branch: main
  path: deploy
  namespace: myapp
```

**Helm chart source** (upstream chart, inline values):

```yaml
- name: myapp
  repoUrl: https://charts.example.com
  chart: myapp
  version: 1.2.3
  namespace: myapp
  values: |
    replicas: 2
```

Commit and push. ArgoCD self-heals the rest.

## Fields

| field       | required          | default | description                                |
|-------------|-------------------|---------|--------------------------------------------|
| `name`      | yes               | —       | Application name (also used as identifier) |
| `repoUrl`   | yes               | —       | Git repo URL or Helm chart repo URL        |
| `namespace` | yes               | —       | Destination namespace (auto-created)       |
| `branch`    | git only          | `main`  | Git revision (branch / tag / sha)          |
| `path`      | git only          | —       | Path within the repo to sync               |
| `chart`     | helm only         | —       | Chart name (presence selects helm mode)    |
| `version`   | helm only         | —       | Chart version                              |
| `values`    | helm only, opt.   | —       | Inline Helm values YAML                    |

## Vault bootstrap

Three components deploy together: a small `vault-unsealer` Vault holding a
transit key, the main `vault` (auto-unseals via that key), and `vault-secrets-operator`.

The main Vault pod will **CrashLoopBackOff until step 4 finishes** (it's
waiting on the `vault-unsealer-token` secret). That's expected.

### 1. Bootstrap the unsealer (one time)

```sh
# Initialize — store the 5 unseal keys and root token securely
kubectl -n vault-unsealer exec -it vault-unsealer-0 -- vault operator init

# Unseal (run 3x with different keys)
kubectl -n vault-unsealer exec -it vault-unsealer-0 -- vault operator unseal
```

### 2. Create the transit key + policy

```sh
kubectl -n vault-unsealer exec -it vault-unsealer-0 -- sh
  export VAULT_TOKEN=<unsealer-root-token>
  vault secrets enable transit
  vault write -f transit/keys/autounseal

  vault policy write autounseal - <<EOF
  path "transit/encrypt/autounseal" { capabilities = ["update"] }
  path "transit/decrypt/autounseal" { capabilities = ["update"] }
  EOF

  # Token used by main Vault — periodic so it auto-renews
  vault token create -policy=autounseal -period=24h -orphan
```

### 3. Stash the token where main Vault can read it

```sh
kubectl -n vault create secret generic vault-unsealer-token \
  --from-literal=token=<token-from-previous-step>
```

### 4. Initialize main Vault

The pod should now start and auto-unseal. Initialize with recovery keys
(no unseal keys — transit handles that):

```sh
kubectl -n vault exec -it vault-0 -- vault operator init \
  -recovery-shares=5 -recovery-threshold=3
```

### 5. Configure Kubernetes auth + KV engine

```sh
kubectl -n vault exec -it vault-0 -- sh
  export VAULT_TOKEN=<main-root-token>
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc"
  vault secrets enable -path=kv -version=2 kv
```

### After unsealer restarts

Only the unsealer needs manual unsealing again (3x with the keys from step 1).
The main Vault auto-recovers as soon as the unsealer is reachable.

### Wiring a workload to a Vault secret

Create `VaultAuth` + `VaultStaticSecret` CRs in the workload's namespace —
VSO syncs the Vault path into a native `Secret`.

### What's *not* in git

These pieces of state are deliberately created out-of-band — committing them
would defeat their purpose. If you ever rebuild the cluster from scratch,
these are the bits you recreate by hand:

| Item                                      | Where it lives          | How to recreate                                     |
|-------------------------------------------|-------------------------|-----------------------------------------------------|
| Unsealer unseal keys + root token         | Your password manager   | `vault operator init` on `vault-unsealer-0`         |
| Transit autounseal key                    | Unsealer's file storage | `vault write -f transit/keys/autounseal`            |
| `vault-unsealer-token` secret             | `vault` namespace       | `kubectl create secret generic …` (step 3 above)    |
| Main Vault recovery keys + root token     | Your password manager   | `vault operator init -recovery-shares=…` on `vault-0` |
| Main Vault data (KV, auth config, policies) | Main Vault's Raft PVC | Re-run steps 5+ and re-populate KV                  |
