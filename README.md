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

Append to `apps/values.yaml`:

```yaml
apps:
  - name: myapp
    repoUrl: https://github.com/me/myapp
    branch: main
    path: deploy
    namespace: myapp
```

Commit and push. ArgoCD self-heals the rest.

## Fields

| field      | required | default  | description                                |
|------------|----------|----------|--------------------------------------------|
| `name`     | yes      | —        | Application name (also used as identifier) |
| `repoUrl`  | yes      | —        | Git repo containing manifests              |
| `branch`   | no       | `main`   | Git revision (branch / tag / sha)          |
| `path`     | yes      | —        | Path within the repo to sync               |
| `namespace`| yes      | —        | Destination namespace (auto-created)       |
