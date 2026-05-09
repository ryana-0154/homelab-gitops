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

## Ingress — Envoy Gateway (Gateway API)

The cluster uses the Kubernetes Gateway API (the successor to ingress-nginx),
implemented by [Envoy Gateway](https://gateway.envoyproxy.io/). Two apps in
`apps/values.yaml` set this up:

- `envoy-gateway` — the controller (Helm chart, `envoy-gateway-system` ns).
- `gateway-resources` — the `GatewayClass`, `Gateway`, and per-app `HTTPRoute`s
  in `gateway/`.

### Post-install steps

Once both apps are Synced:

1. **Find the gateway's external IP** (provided by your existing LoadBalancer):

   ```sh
   kubectl -n envoy-gateway-system get gateway homelab \
     -o jsonpath='{.status.addresses[0].value}'
   ```

2. **Add a Pi-hole local DNS record** pointing `argocd.homelab.lan` (or
   whatever hostname you set in `gateway/argocd-route.yaml`) to that IP.

3. **Flip ArgoCD into insecure mode** so the gateway can terminate the
   connection over plain HTTP (the gateway listens on :80; TLS is a future
   step with cert-manager):

   ```sh
   kubectl -n argocd patch configmap argocd-cmd-params-cm \
     --type merge -p '{"data":{"server.insecure":"true"}}'
   kubectl -n argocd rollout restart deploy argocd-server
   ```

### Adding a route for another app

Drop another `HTTPRoute` into `gateway/` referencing the `homelab` Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  parentRefs:
    - name: homelab
      namespace: envoy-gateway-system
  hostnames:
    - myapp.homelab.lan
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

Commit, add the Pi-hole record, done.

## Monitoring — Grafana Cloud

The `monitoring` app installs the
[`k8s-monitoring`](https://github.com/grafana/k8s-monitoring-helm) chart
(Grafana Alloy + node-exporter + kube-state-metrics) and ships metrics +
logs to Grafana Cloud.

Edit scrape targets / toggles inline in `apps/values.yaml` under the
`monitoring` entry. The remote-write URLs and cluster name live there too;
only the credentials are sealed.

### Bootstrap credentials

Get a Grafana Cloud Access Policy token with `metrics:write` and
`logs:write` scopes (Grafana Cloud → *Access Policies* → *Add token*),
note the metrics + logs instance IDs (usernames) from the data source
"send Prometheus metrics" / "send Loki logs" pages, then:

```sh
./scripts/seal-grafana-cloud.sh
```

This writes `secrets/monitoring/grafana-cloud-credentials.yaml`. Commit
and push — the `monitoring-secrets` Argo app applies it; the
`monitoring` release picks it up via `existingSecret`.

### Adjusting the remote-write endpoints

Replace the placeholder hostnames in `apps/values.yaml` (`prometheus-prod-13-...`
and `logs-prod-006...`) with the URLs shown in your Grafana Cloud stack's
Prometheus / Loki data source pages.

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
