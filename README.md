# homelab-gitops

ArgoCD app-of-apps for homelab cluster.

## Layout

- `bootstrap/root-app.yaml` — seed `Application` pointing at `apps/`. Apply once.
- `apps/` — Helm chart that renders one `Application` per entry in `values.yaml`.
- `secrets/` — committed `SealedSecret` manifests, one subdir per consuming namespace.
- `scripts/` — bootstrap and operational helpers.

## Bootstrap

1. Edit `bootstrap/root-app.yaml` and set `spec.source.repoURL` to this repo's URL.
2. Run the cluster bootstrap script (idempotent, safe to re-run):

   ```sh
   ./scripts/cluster-bootstrap.sh
   ```

ArgoCD reconciles `apps/` and creates every child `Application` defined in `apps/values.yaml`.

## Adding an app

Three source shapes are supported.

**Git source** (manifests / kustomize / chart-in-a-repo):

```yaml
- name: myapp
  repoUrl: https://github.com/me/myapp
  branch: main
  path: deploy
  namespace: myapp
```

**Git source with Helm value overrides** (path points at a chart in the repo):

```yaml
- name: myapp
  repoUrl: https://github.com/me/myapp-helm
  branch: main
  path: .
  namespace: myapp
  values: |
    replicas: 2
```

**Upstream Helm chart** (inline values):

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

| field         | required          | default | description                                                |
|---------------|-------------------|---------|------------------------------------------------------------|
| `name`        | yes               | —       | Application name                                           |
| `repoUrl`     | yes               | —       | Git repo URL or Helm chart repo URL                        |
| `namespace`   | yes               | —       | Destination namespace (auto-created)                       |
| `branch`      | git only          | `main`  | Git revision (branch / tag / sha)                          |
| `path`        | git only          | —       | Path within the repo to sync                               |
| `chart`       | helm only         | —       | Chart name (presence selects upstream-helm mode)           |
| `version`     | helm only         | —       | Chart version                                              |
| `values`      | optional          | —       | Inline Helm values YAML                                    |
| `ignoreDifferences` | optional    | —       | List of `ignoreDifferences` entries (jsonPointers / jq)    |

## Secrets — Sealed Secrets

[`sealed-secrets`](https://github.com/bitnami-labs/sealed-secrets) runs in the
cluster and holds a private key. You encrypt secrets locally with the
`kubeseal` CLI against the cluster's public key; the resulting
`SealedSecret` manifest is safe to commit to git, and the controller
decrypts it into a normal `Secret` in the right namespace.

### Install kubeseal

```sh
# https://github.com/bitnami-labs/sealed-secrets/releases
# (match the kubeseal client version to the controller chart's appVersion)
```

### Sealing a secret manually

```sh
kubectl create secret generic <name> \
    --namespace=<target-ns> \
    --from-literal=key=value \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-namespace=sealed-secrets \
      --controller-name=sealed-secrets-controller \
      --format=yaml \
  > secrets/<target-ns>/<name>.yaml
```

Commit `secrets/<target-ns>/<name>.yaml`. Add an `Application` entry pointing
at that path so ArgoCD applies it.

### Pihole admin password

Bootstrap (or rotate) the pihole admin password with the helper:

```sh
./scripts/seal-pihole-password.sh
```

This generates a 32-char password, writes it to `.secrets/pihole-admin-password.txt`
(gitignored — copy to your password manager and delete), and writes the sealed
manifest to `secrets/pihole/admin.yaml`. Commit and push.

The `pihole-secrets` Argo app applies `secrets/pihole/`, materializing the
`pihole-admin` Secret. The pihole release is configured with
`existingSecret: pihole-admin` and consumes it on next reconcile.

### Disaster recovery

The sealed-secrets controller's private key is the master key for every
`SealedSecret` in this repo. Back it up:

```sh
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > sealed-secrets-key-backup.yaml
```

Store this backup *outside* git (password manager, encrypted external drive).
Without it, a cluster rebuild forces re-sealing every secret in the repo.
