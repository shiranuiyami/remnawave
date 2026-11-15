# remnawave

Helm chart for the [Remnawave](https://docs.rw) panel (`remnawave/backend`) with Valkey and an
optional subscription page (`remnawave/subscription-page`).

What the chart deploys:

- **Panel**: one pod with a single replica and the `Recreate` strategy. pm2 runs `api`, `jobs` and
  `scheduler` inside the container, and the entrypoint runs the Prisma migrations. Scale with
  `API_INSTANCES` / `WORKER_INSTANCES`, not with replicas.
- **Valkey**: either a standalone Deployment + Service (TCP) or a sidecar in the panel pod
  (unix socket). An external Redis can be used instead.
- **PostgreSQL**: an external database, or a CloudNativePG `Cluster` created by the chart.
- **Subscription page** (optional): a container in the panel pod that talks to the panel over
  `127.0.0.1`.
- **Routing** (optional): Gateway API `HTTPRoute` or Istio `VirtualService`, with an own or shared
  Gateway.
- **TLS** (optional): a cert-manager ACME `Issuer` / `ClusterIssuer` and a `Certificate`.
- **Monitoring** (optional): a prometheus-operator `ServiceMonitor` and NetworkPolicies.

## Requirements

| Component | Required when | Notes |
|---|---|---|
| Kubernetes | always | on ≥ 1.29 the sidecar Valkey runs as a native sidecar (it starts before the panel) |
| PostgreSQL (UTC) | always | `database.mode=external`, or CNPG below |
| [CloudNativePG](https://cloudnative-pg.io) operator | `database.mode=cnpg` | the chart creates only the `Cluster` |
| Gateway API CRDs + an implementation | `routing.type=gatewayApi` | `gateway.networking.k8s.io/v1` |
| Istio | `routing.type=istio` | `networking.istio.io/v1` |
| [cert-manager](https://cert-manager.io) | `certManager.enabled` | HTTP-01 over Gateway API needs `--enable-gateway-api` |
| prometheus-operator | `metrics.serviceMonitor.enabled` | e.g. kube-prometheus-stack |
| CNI with NetworkPolicy support | `networkPolicy.enabled` | Cilium, Calico, … |

On install the chart checks that the CRDs it needs are present. For offline rendering
(`helm template`, CI) either pass `--api-versions` or set the matching `skipCrdCheck: true`.

### PostgreSQL must run in UTC

The panel expects the database to use the UTC time zone. The CNPG cluster sets
`postgresql.parameters.timezone: UTC` by default. For an external database, check
`SHOW timezone;` and set `timezone = 'UTC'` for the database or role if it differs:
`ALTER DATABASE remnawave SET timezone TO 'UTC';`.

### Open file limit (`ulimits`)

The upstream docker-compose raises `nofile` for the panel container. Kubernetes has no per-pod
ulimit setting: containers inherit the limit of the container runtime on the node, and the default
depends on the runtime and its version. To check it:

```sh
kubectl -n remnawave exec deploy/<release>-remnawave -c panel -- sh -c 'ulimit -n'
```

If the value is low, raise it in the runtime config on the nodes (containerd / CRI-O systemd unit),
not in the chart.

## Installation

The chart is published as an OCI artifact in GitHub Container Registry:

```
oci://ghcr.io/shiranuiyami/charts/remnawave
```

No `helm repo add` is needed, OCI charts are referenced directly:

```sh
# show the chart and its default values
helm show chart  oci://ghcr.io/shiranuiyami/charts/remnawave --version 0.1.0
helm show values oci://ghcr.io/shiranuiyami/charts/remnawave --version 0.1.0 > values.yaml

# install / upgrade
helm upgrade --install rw oci://ghcr.io/shiranuiyami/charts/remnawave --version 0.1.0 \
  -n remnawave --create-namespace -f values.yaml

# download the .tgz
helm pull oci://ghcr.io/shiranuiyami/charts/remnawave --version 0.1.0
```

Available versions are listed on the
[package page](https://github.com/shiranuiyami/remnawave/pkgs/container/charts%2Fremnawave)
and in [GitHub Releases](https://github.com/shiranuiyami/remnawave/releases) (each release also
has the packaged `.tgz` attached).

### Argo CD

OCI Helm repositories need `enableOCI: "true"` and a URL without the `oci://` scheme:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: remnawave-charts
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: remnawave-charts
  type: helm
  enableOCI: "true"
  url: ghcr.io/shiranuiyami/charts
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: remnawave
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ghcr.io/shiranuiyami/charts
    chart: remnawave
    targetRevision: 0.1.0
    helm:
      valuesObject: {}   # your values
  destination:
    server: https://kubernetes.default.svc
    namespace: remnawave
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

See [Secrets, `lookup` and GitOps](#secrets-lookup-and-gitops) before using Argo CD.

### Flux

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: remnawave
  namespace: flux-system
spec:
  interval: 1h
  url: oci://ghcr.io/shiranuiyami/charts/remnawave
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    semver: "0.1.x"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: rw
  namespace: remnawave
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: remnawave
    namespace: flux-system
  values: {}   # your values
```

## Quick start

Minimal install with an external database and an own Gateway API Gateway:

```yaml
# values.yaml
database:
  external:
    url: postgresql://remnawave:password@postgres.db.svc:5432/remnawave

routing:
  type: gatewayApi
  hosts:
    panel: panel.example.com
  gatewayApi:
    createGateway: true
    gateway:
      className: cilium

certManager:
  enabled: true
  issuer:
    solver: http01
```

```sh
helm install rw oci://ghcr.io/shiranuiyami/charts/remnawave --version 0.1.0 \
  -n remnawave --create-namespace -f values.yaml
```

`helm install` prints NOTES with the service addresses, routes, how to get the metrics password,
the CNPG status and the cert-manager diagnostic commands.

## First install: order of steps

The subscription page needs an API token, and that token can only be created in the UI of a
running panel. So the first install takes two steps:

1. Install with `subscriptionPage.enabled=false` (the default).
2. Open the panel, create the first admin account, then create an API token in the panel UI.
3. Enable the subscription page and pass the token:

   ```sh
   helm upgrade rw oci://ghcr.io/shiranuiyami/charts/remnawave --version 0.1.0 \
     -n remnawave --reuse-values \
     --set subscriptionPage.enabled=true \
     --set subscriptionPage.secretEnv.REMNAWAVE_API_TOKEN=<token>
   ```

   To keep the token out of the values, store it in a Secret and set
   `subscriptionPage.existingSecret` (the Secret must contain the key `REMNAWAVE_API_TOKEN`).

Where the subscription page is served:

- `routing.hosts.sub` is set: on that host (`/`).
- `routing.hosts.sub` is empty: on the panel host under `/<CUSTOM_SUB_PREFIX>`. The prefix is then
  required.

`SUB_PUBLIC_DOMAIN` is computed from these settings unless you set it explicitly. With the page
disabled it is `<panel host>/api/sub`.

## Secrets, `lookup` and GitOps

When left empty, several values are generated on the first install and then reused on upgrades.
The chart reads them back from the existing Secret with `lookup`:

| Value | Stored in |
|---|---|
| `panel.secretEnv.APP_SECRET` | Secret `<fullname>` |
| `panel.secretEnv.METRICS_PASS` | Secret `<fullname>` |
| `valkey.auth.password` (with `valkey.auth.enabled`) | Secret `<fullname>-valkey` |

`lookup` returns nothing under `helm template` and in most GitOps tools (Argo CD renders with
`helm template`; Flux's helm-controller does support `lookup`). There, a new random value is
generated on every render, so the Secret changes on every sync and the panel restarts with a
new `APP_SECRET`. In that case:

- set these values explicitly, for example from SOPS / sealed-secrets / an External Secrets
  provided values file, **or**
- keep them in a Secret you manage yourself and reference it: `panel.existingSecret` (added last to
  `envFrom`, so it overrides the chart's Secret), `valkey.auth.existingSecret`,
  `database.external.existingSecret`, `subscriptionPage.existingSecret`.

`APP_SECRET` must not be `change_me`, the chart refuses to render it.

Other secrets are never generated: `DATABASE_URL` (`database.external.url` / `existingSecret`, or
the CNPG `<cluster>-app` Secret), `TELEGRAM_BOT_TOKEN`, `WEBHOOK_SECRET_HEADER` and
`REMNAWAVE_API_TOKEN`.

### DNS-01 credentials

The chart does not create Secrets for DNS providers, it only references them
(`certManager.issuer.dns01.<provider>.*SecretRef`). Create the Secret in the Issuer namespace for an
`Issuer`, or in the cert-manager cluster resource namespace (usually `cert-manager`) for a
`ClusterIssuer`:

```sh
kubectl -n remnawave create secret generic cloudflare-api-token --from-literal=api-token=<token>
```

## Environment variables

`panel.env` (rendered into a ConfigMap) and `panel.secretEnv` (rendered into a Secret) take
**verbatim env var names** as keys. Any key you add is passed to the container, so new upstream
variables work without changing the chart.

- `null` / `""`: the variable is not set and the application default applies.
- bool / number: stringified, whole numbers without `.0`.
- list / map: JSON (`[60, 80]` becomes `"[60,80]"`, the format the panel parses).

The chart wires these variables itself and refuses them in `panel.env` / `panel.secretEnv`:
`DATABASE_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_SOCKET`, `REDIS_PASSWORD`, `REDIS_USERNAME`.
`REMNAWAVE_BRANCH` is baked into the image and is refused too.

`PANEL_DOMAIN` defaults to `routing.hosts.panel`. `FRONT_END_DOMAIN` is required (`"*"` allows any
origin). See `values.yaml` and the [upstream reference](https://docs.rw/docs/install/environment-variables)
for the full list.

## Values

The main switches are listed below. Every key is documented in [`values.yaml`](values.yaml), and
`values.schema.json` rejects unknown keys and out-of-range values.

### Panel

| Key | Default | Description |
|---|---|---|
| `panel.image.tag` | `""` (appVersion) | Panel image tag; `panel.image.digest` pins a digest |
| `panel.env` | see values | Non-secret env (ConfigMap) |
| `panel.secretEnv` | see values | Secret env; `APP_SECRET` / `METRICS_PASS` are generated when empty |
| `panel.existingSecret` | `""` | Extra Secret, added last to `envFrom` |
| `panel.extraEnv` / `panel.extraEnvFrom` | `[]` | Raw `EnvVar` / `EnvFromSource` entries |
| `panel.resources` | `{}` | Keep `API_INSTANCES` within the CPU limit |
| `panel.startupProbe.failureThreshold` | `30` | × 10 s, leaves time for the migrations |
| `panel.extraContainers` / `initContainers` / `extraVolumes` | `[]` | Raw specs; containers go through `tpl` |

### Placement

| Key | Description |
|---|---|
| `scheduling.{nodeSelector,affinity,tolerations,topologySpreadConstraints}` | Defaults for every component |
| `panel.*` / `valkey.*` / `database.cnpg.*` (same keys) | Per-component overrides: `nodeSelector` is merged, the other keys replace the global value |

The subscription page and the sidecar Valkey live in the panel pod and follow it.

### Database

| Key | Default | Description |
|---|---|---|
| `database.mode` | `external` | `external` \| `cnpg` |
| `database.external.url` / `existingSecret` / `existingSecretKey` | `""` / `""` / `uri` | `DATABASE_URL` source |
| `database.cnpg.instances` | `1` | `1` = primary only, `3` = primary + 2 standby |
| `database.cnpg.storage.size` / `storageClass` | `10Gi` / `""` | Data volume |
| `database.cnpg.podAntiAffinity.type` | `preferred` | `required` keeps replicas Pending until enough nodes exist |
| `database.cnpg.keepOnUninstall` | `true` | `helm.sh/resource-policy: keep` on the Cluster |
| `database.cnpg.backup` / `monitoring` / `extraSpec` | `{}` | Passed to the Cluster spec |
| `database.waitForDb.enabled` | `true` | initContainer that runs `pg_isready` against `DATABASE_URL` |

Failover is handled by CNPG: with `instances >= 2` it promotes a replica and moves the
`<cluster>-rw` service. To scale from 1 to 3 instances, change `instances` and run `helm upgrade`.
The panel needs no changes.

### Valkey / Redis

| Key | Default | Description |
|---|---|---|
| `valkey.enabled` | `true` | `false` → `externalRedis.*` |
| `valkey.mode` | `standalone` | `standalone` (Deployment + Service) \| `sidecar` (unix socket, data lost on each panel rollout) |
| `valkey.db` | `1` | `REDIS_DB` for the panel |
| `valkey.auth.enabled` / `password` / `existingSecret` | `false` | `--requirepass`; the password is generated when empty |
| `externalRedis.{host,port,socket,username,password,existingSecret}` | | Used when `valkey.enabled=false` |

### Subscription page

| Key | Default | Description |
|---|---|---|
| `subscriptionPage.enabled` | `false` | See [First install](#first-install-order-of-steps) |
| `subscriptionPage.image.tag` | `latest` | Pin a version in production |
| `subscriptionPage.env.CUSTOM_SUB_PREFIX` | `""` | Required on the panel host |
| `subscriptionPage.secretEnv.REMNAWAVE_API_TOKEN` | `""` | Or `subscriptionPage.existingSecret` |

### Routing

| Key | Default | Description |
|---|---|---|
| `routing.type` | `none` | `none` \| `gatewayApi` \| `istio` |
| `routing.hosts.panel` / `routing.hosts.sub` | `panel.example.com` / `""` | Public hosts |
| `routing.tls.enabled` / `secretName` / `httpsRedirect` | `true` / `""` (`<fullname>-tls`) / `true` | HTTPS listener / server |
| `routing.gatewayApi.parentRefs` / `httpRedirectParentRefs` | `[]` | Shared Gateway: the HTTPS listener and the HTTP listener for the redirect |
| `routing.gatewayApi.createGateway` / `gateway.className` | `false` / `""` | Own Gateway |
| `routing.istio.gateways` | `[]` | Shared istio Gateways (`namespace/name`) |
| `routing.istio.createGateway` / `gateway.namespace` | `false` / `istio-system` | Own Gateway; the TLS Secret must be in the ingress gateway namespace |
| `routing.istio.redirectMode` | `auto` | Where HTTP → HTTPS happens; `auto` keeps HTTP-01 challenges working |

The metrics port is never routed.

### cert-manager

| Key | Default | Description |
|---|---|---|
| `certManager.enabled` | `false` | |
| `certManager.issuer.create` / `kind` / `name` | `true` / `Issuer` / `""` | Create an ACME issuer, or reference an existing one (`create=false`) |
| `certManager.issuer.acme.server` / `email` | Let's Encrypt prod / `""` | |
| `certManager.issuer.solver` | `http01` | `http01` \| `dns01` (`cloudflare`, `route53`, `rfc2136`, `webhook`) |
| `certManager.issuer.solvers` | `[]` | Raw ACME solvers, replace everything above |
| `certManager.certificate.dnsNames` | `[]` | Empty → routing hosts |
| `certManager.referenceGrant.create` | `true` | Lets a shared Gateway in another namespace use the TLS Secret |

### Monitoring and NetworkPolicy

| Key | Default | Description |
|---|---|---|
| `metrics.serviceMonitor.enabled` | `false` | Scrapes `/metrics` on the metrics port with Basic auth |
| `metrics.serviceMonitor.labels` | `{}` | Must match your Prometheus `serviceMonitorSelector` |
| `metrics.serviceMonitor.basicAuth.existingSecret` | `""` | Empty → `METRICS_PASS` from the panel Secret, `METRICS_USER` copied into `<fullname>-metrics-auth` |
| `networkPolicy.enabled` | `false` | Ingress only: panel and standalone Valkey |
| `networkPolicy.ingressFrom` | `[]` | Peers allowed to reach the panel / subscription page (the gateway); empty → any source |
| `networkPolicy.metricsFrom` | `[]` | Peers allowed to scrape metrics; empty → nobody |

Get the metrics password:

```sh
kubectl -n remnawave get secret <release>-remnawave -o jsonpath='{.data.METRICS_PASS}' | base64 -d
```

## Upgrading

- The panel uses the `Recreate` strategy, so every rollout has a short downtime. Migrations run on
  start.
- Changes to env (`panel.env`, `panel.secretEnv`, subscription page env) restart the pod through
  checksum annotations.
- With `valkey.mode=sidecar` the Valkey data (queues, cache) is lost on every rollout.

## Development

```sh
helm lint --strict .
for f in ci/*.yaml; do helm template rw . -n remnawave -f "$f" > /dev/null; done
helm unittest .        # https://github.com/helm-unittest/helm-unittest
```

CI (`.github/workflows/ci.yaml`) runs lint, template and unittest, then a smoke install in kind
with a temporary PostgreSQL.

### Releasing

1. Bump `version` in `Chart.yaml` (and `appVersion` if needed), merge to `master`.
2. Tag the commit with the same version prefixed by `v` and push the tag:

   ```sh
   git tag v0.1.1 && git push origin v0.1.1
   ```

`.github/workflows/release.yaml` checks that the tag matches `Chart.yaml`, runs lint and
unittest, pushes the chart to `oci://ghcr.io/shiranuiyami/charts/remnawave` and creates a GitHub
Release with the `.tgz` attached. A version that is already in the registry is overwritten, so
always bump the version.

## License

[MIT](LICENSE)
