{{/* Render-time checks. Included once from templates/panel/deployment.yaml. */}}
{{- define "remnawave.validate" -}}

{{/* Env managed by the chart must not be set by hand. */}}
{{- range $key := list "DATABASE_URL" "REDIS_HOST" "REDIS_PORT" "REDIS_SOCKET" "REDIS_PASSWORD" "REDIS_USERNAME" }}
{{- if or (hasKey $.Values.panel.env $key) (hasKey $.Values.panel.secretEnv $key) }}
{{- fail (printf "panel.env / panel.secretEnv: %s is managed by the chart, use the database / valkey / externalRedis blocks instead" $key) }}
{{- end }}
{{- end }}
{{- if hasKey .Values.panel.env "REMNAWAVE_BRANCH" }}
{{- fail "panel.env: REMNAWAVE_BRANCH is baked into the image and must not be changed" }}
{{- end }}

{{/* Database */}}
{{- if eq .Values.database.mode "external" }}
{{- if and (not .Values.database.external.url) (not .Values.database.external.existingSecret) }}
{{- fail "database.external: set url or existingSecret (DATABASE_URL is required)" }}
{{- end }}
{{- else if eq .Values.database.mode "cnpg" }}
{{- $c := .Values.database.cnpg }}
{{- if and (not $c.skipCrdCheck) (not (.Capabilities.APIVersions.Has "postgresql.cnpg.io/v1/Cluster")) }}
{{- fail "database.mode=cnpg: CRD postgresql.cnpg.io/v1 Cluster not found. Install the CloudNativePG operator (or pass --api-versions postgresql.cnpg.io/v1/Cluster / set database.cnpg.skipCrdCheck=true for offline rendering)" }}
{{- end }}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString $c.instances)) }}
{{- fail "database.cnpg.instances must be an integer >= 1" }}
{{- end }}
{{- if not (has $c.podAntiAffinity.type (list "preferred" "required")) }}
{{- fail "database.cnpg.podAntiAffinity.type: preferred | required" }}
{{- end }}
{{- if not $c.storage.size }}
{{- fail "database.cnpg.storage.size is required" }}
{{- end }}
{{- else }}
{{- fail (printf "database.mode: unsupported value %q (external | cnpg)" .Values.database.mode) }}
{{- end }}

{{/* Valkey / Redis */}}
{{- if .Values.valkey.enabled }}
{{- if not (has .Values.valkey.mode (list "standalone" "sidecar")) }}
{{- fail (printf "valkey.mode: unsupported value %q (standalone | sidecar)" .Values.valkey.mode) }}
{{- end }}
{{- if and .Values.valkey.auth.enabled .Values.valkey.auth.existingSecret (not .Values.valkey.auth.existingSecretPasswordKey) }}
{{- fail "valkey.auth.existingSecretPasswordKey is required with valkey.auth.existingSecret" }}
{{- end }}
{{- else }}
{{- if and (not .Values.externalRedis.socket) (not .Values.externalRedis.host) }}
{{- fail "valkey.enabled=false: set externalRedis.host (or externalRedis.socket)" }}
{{- end }}
{{- end }}

{{/* Panel env */}}
{{- if not (include "remnawave.panel.subPublicDomain" .) }}
{{- fail "set routing.hosts.panel (or panel.env.PANEL_DOMAIN / panel.env.SUB_PUBLIC_DOMAIN)" }}
{{- end }}
{{- if not (include "remnawave.isSet" (index .Values.panel.env "FRONT_END_DOMAIN")) }}
{{- fail "panel.env.FRONT_END_DOMAIN is required (use \"*\" to allow any origin)" }}
{{- end }}
{{- if eq (toString (index .Values.panel.secretEnv "APP_SECRET")) "change_me" }}
{{- fail "panel.secretEnv.APP_SECRET must not be \"change_me\"" }}
{{- end }}

{{/* Subscription page */}}
{{- if include "remnawave.sub.enabled" . }}
{{- $s := .Values.subscriptionPage }}
{{- if and (not (include "remnawave.isSet" (index $s.secretEnv "REMNAWAVE_API_TOKEN"))) (not $s.existingSecret) }}
{{- fail "subscriptionPage.enabled: set subscriptionPage.secretEnv.REMNAWAVE_API_TOKEN (or existingSecret). The token is created in the panel UI: install with subscriptionPage.enabled=false first, then enable it with `helm upgrade`" }}
{{- end }}
{{- $subPort := include "remnawave.sub.port" . }}
{{- if has $subPort (list (include "remnawave.panel.appPort" .) (include "remnawave.panel.metricsPort" .)) }}
{{- fail (printf "subscriptionPage.env.APP_PORT=%s collides with a panel port (APP_PORT / METRICS_PORT): they share the pod network" $subPort) }}
{{- end }}
{{- if and (eq .Values.routing.type "none") (not .Values.routing.hosts.sub) (not (include "remnawave.sub.prefix" .)) (not (include "remnawave.isSet" (index .Values.panel.env "SUB_PUBLIC_DOMAIN"))) }}
{{- fail "subscriptionPage on the panel domain needs subscriptionPage.env.CUSTOM_SUB_PREFIX (or set routing.hosts.sub / panel.env.SUB_PUBLIC_DOMAIN)" }}
{{- end }}
{{- end }}

{{/* Metrics / NetworkPolicy */}}
{{- $sm := .Values.metrics.serviceMonitor }}
{{- if $sm.enabled }}
{{- if and (not $sm.skipCrdCheck) (not (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor")) }}
{{- fail "metrics.serviceMonitor.enabled: CRD monitoring.coreos.com/v1 ServiceMonitor not found. Install prometheus-operator (or pass --api-versions monitoring.coreos.com/v1/ServiceMonitor / set metrics.serviceMonitor.skipCrdCheck=true)" }}
{{- end }}
{{- if $sm.basicAuth.existingSecret }}
{{- if or (not $sm.basicAuth.usernameKey) (not $sm.basicAuth.passwordKey) }}
{{- fail "metrics.serviceMonitor.basicAuth: usernameKey and passwordKey are required with existingSecret" }}
{{- end }}
{{- else if not (include "remnawave.isSet" (index .Values.panel.env "METRICS_USER")) }}
{{- fail "metrics.serviceMonitor.enabled: set panel.env.METRICS_USER (or metrics.serviceMonitor.basicAuth.existingSecret)" }}
{{- end }}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.metricsFrom) }}
{{- fail "networkPolicy.enabled blocks the metrics port: set networkPolicy.metricsFrom (e.g. the monitoring namespace) for the ServiceMonitor" }}
{{- end }}
{{- end }}

{{/* Routing */}}
{{- $r := .Values.routing }}
{{- if not (has $r.type (list "none" "gatewayApi" "istio")) }}
{{- fail (printf "routing.type: unsupported value %q (none | gatewayApi | istio)" $r.type) }}
{{- end }}
{{- if ne $r.type "none" }}
{{- if not (include "remnawave.routing.panelHost" .) }}
{{- fail "routing.hosts.panel is required" }}
{{- end }}
{{- if and (include "remnawave.sub.enabled" .) (not $r.hosts.sub) (not (include "remnawave.sub.prefix" .)) }}
{{- fail "subscription page on the panel host (routing.hosts.sub is empty) requires subscriptionPage.env.CUSTOM_SUB_PREFIX" }}
{{- end }}
{{- end }}
{{- if eq $r.type "gatewayApi" }}
{{- if and (not $r.skipCrdCheck) (not (.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1/HTTPRoute")) }}
{{- fail "routing.type=gatewayApi: CRD gateway.networking.k8s.io/v1 HTTPRoute not found (install Gateway API CRDs, or pass --api-versions / set routing.skipCrdCheck=true)" }}
{{- end }}
{{- if $r.gatewayApi.createGateway }}
{{- if not $r.gatewayApi.gateway.className }}
{{- fail "routing.gatewayApi.gateway.className is required with createGateway=true" }}
{{- end }}
{{- else if not $r.gatewayApi.parentRefs }}
{{- fail "routing.gatewayApi: set parentRefs (existing Gateway) or createGateway=true" }}
{{- end }}
{{- else if eq $r.type "istio" }}
{{- if and (not $r.skipCrdCheck) (not (.Capabilities.APIVersions.Has (printf "%s/VirtualService" $r.istio.apiVersion))) }}
{{- fail (printf "routing.type=istio: CRD %s VirtualService not found (install Istio, or pass --api-versions / set routing.skipCrdCheck=true)" $r.istio.apiVersion) }}
{{- end }}
{{- if and (not $r.istio.createGateway) (not $r.istio.gateways) }}
{{- fail "routing.istio: set gateways (existing istio Gateway, namespace/name) or createGateway=true" }}
{{- end }}
{{- if not (has ($r.istio.redirectMode | default "auto") (list "auto" "gateway" "virtualService")) }}
{{- fail (printf "routing.istio.redirectMode: unsupported value %q (auto | gateway | virtualService)" $r.istio.redirectMode) }}
{{- end }}
{{- if and (include "remnawave.certManager.http01" .) $r.tls.httpsRedirect (eq $r.istio.redirectMode "gateway") }}
{{- fail "routing.istio.redirectMode=gateway redirects ACME HTTP-01 challenges to https and breaks them: use auto / virtualService, or certManager.issuer.solver=dns01" }}
{{- end }}
{{- end }}

{{/* cert-manager */}}
{{- $cm := .Values.certManager }}
{{- if $cm.enabled }}
{{- $i := $cm.issuer }}
{{- if and (not $cm.skipCrdCheck) (not (.Capabilities.APIVersions.Has "cert-manager.io/v1/Certificate")) }}
{{- fail "certManager.enabled: CRD cert-manager.io/v1 Certificate not found. Install cert-manager (or pass --api-versions cert-manager.io/v1/Certificate / set certManager.skipCrdCheck=true for offline rendering)" }}
{{- end }}
{{- if not (has $i.kind (list "Issuer" "ClusterIssuer")) }}
{{- fail (printf "certManager.issuer.kind: unsupported value %q (Issuer | ClusterIssuer)" $i.kind) }}
{{- end }}
{{- if not (has $i.solver (list "http01" "dns01")) }}
{{- fail (printf "certManager.issuer.solver: unsupported value %q (http01 | dns01)" $i.solver) }}
{{- end }}
{{- if and (ne $r.type "none") (not $r.tls.enabled) }}
{{- fail "certManager.enabled requires routing.tls.enabled=true (the certificate is only used by the HTTPS listener)" }}
{{- end }}
{{- if and (not $i.create) (not $i.name) }}
{{- fail "certManager.issuer.name is required with issuer.create=false" }}
{{- end }}
{{- if and $i.create (not $i.acme.server) }}
{{- fail "certManager.issuer.acme.server is required" }}
{{- end }}

{{- if eq $i.solver "http01" }}
{{- if eq $r.type "none" }}
{{- fail "certManager.issuer.solver=http01 needs routing (routing.type=gatewayApi | istio) to serve the challenge; use dns01 with routing.type=none" }}
{{- end }}
{{- if and $i.create (not $i.solvers) (eq $r.type "gatewayApi") (not (include "remnawave.certManager.http01ParentRefs" . | fromYamlArray)) }}
{{- fail "certManager http01 with a shared Gateway: set certManager.issuer.http01.gatewayHTTPRoute.parentRefs or routing.gatewayApi.httpRedirectParentRefs (HTTP listener on :80)" }}
{{- end }}
{{- end }}

{{- if and $i.create (not $i.solvers) (eq $i.solver "dns01") }}
{{- $d := $i.dns01 }}
{{- if eq $d.provider "cloudflare" }}
{{- if not (include "remnawave.certManager.cloudflare.secretRef" . | fromYaml).name }}
{{- fail "certManager.issuer.dns01.cloudflare: set apiToken (the chart creates the Secret) or apiTokenSecretRef.name (existing Secret)" }}
{{- end }}
{{- else if eq $d.provider "route53" }}
{{- if not $d.route53.region }}
{{- fail "certManager.issuer.dns01.route53.region is required" }}
{{- end }}
{{- if ne (empty $d.route53.accessKeyIDSecretRef) (empty $d.route53.secretAccessKeySecretRef) }}
{{- fail "certManager.issuer.dns01.route53: set both accessKeyIDSecretRef and secretAccessKeySecretRef, or neither (ambient credentials)" }}
{{- end }}
{{- else if eq $d.provider "rfc2136" }}
{{- if or (not $d.rfc2136.nameserver) (not $d.rfc2136.tsigKeyName) (not $d.rfc2136.tsigSecretSecretRef.name) }}
{{- fail "certManager.issuer.dns01.rfc2136: nameserver, tsigKeyName and tsigSecretSecretRef.name are required" }}
{{- end }}
{{- else if eq $d.provider "webhook" }}
{{- if or (not $d.webhook.groupName) (not $d.webhook.solverName) }}
{{- fail "certManager.issuer.dns01.webhook: groupName and solverName are required" }}
{{- end }}
{{- else }}
{{- fail (printf "certManager.issuer.dns01.provider: unsupported value %q (cloudflare | route53 | rfc2136 | webhook)" $d.provider) }}
{{- end }}
{{- end }}

{{- if $cm.certificate.create }}
{{- $dnsNames := include "remnawave.certManager.dnsNames" . | fromYamlArray }}
{{- if not $dnsNames }}
{{- fail "certManager.certificate.dnsNames is required with routing.type=none" }}
{{- end }}
{{- if eq $i.solver "http01" }}
{{- range $dnsNames }}
{{- if hasPrefix "*" . }}
{{- fail (printf "certManager: wildcard %q cannot be issued with http01, use dns01" .) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and (include "remnawave.certManager.referenceGrantNamespaces" . | fromYamlArray) (not $r.skipCrdCheck) (not (.Capabilities.APIVersions.Has (printf "%s/ReferenceGrant" $cm.referenceGrant.apiVersion))) }}
{{- fail (printf "certManager.referenceGrant: CRD %s ReferenceGrant not found (install Gateway API CRDs, set certManager.referenceGrant.create=false, or pass --api-versions / set routing.skipCrdCheck=true)" $cm.referenceGrant.apiVersion) }}
{{- end }}
{{- end }}
{{- end }}

{{- end -}}
