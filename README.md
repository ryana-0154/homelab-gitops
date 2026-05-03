# homelab-gitops

ArgoCD app-of-apps for homelab cluster.

## Layout

- `bootstrap/root-app.yaml` — seed `Application` pointing at `apps/`. Apply once.
- `apps/` — Helm chart that renders one `Application` per entry in `values.yaml`.

## Bootstrap

1. Edit `bootstrap/root-app.yaml` and set `spec.source.repoURL` to this repo's URL.
2. Run the cluster bootstrap script (idempotent, safe to re-run):

   ```sh
   ./scripts/cluster-bootstrap.sh
   ```

ArgoCD then reconciles `apps/` and creates every child `Application` defined in `apps/values.yaml`.

Once `vault` and `vault-unsealer` pods are up, finish Vault setup:

```sh
./scripts/vault-bootstrap.sh
```

See [Vault bootstrap](#vault-bootstrap) for what the script does and which
files it leaves behind in `.secrets/`.

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
