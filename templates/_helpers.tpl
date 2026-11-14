{{/* ------------------------------------------------------------------
     Names
------------------------------------------------------------------- */}}

{{- define "remnawave.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "remnawave.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "remnawave.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "remnawave.panel.fullname" -}}
{{- include "remnawave.fullname" . -}}
{{- end -}}

{{- define "remnawave.metrics.authSecretName" -}}
{{- printf "%s-metrics-auth" (include "remnawave.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "remnawave.valkey.fullname" -}}
{{- printf "%s-valkey" (include "remnawave.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "remnawave.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "remnawave.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------
     Labels
------------------------------------------------------------------- */}}

{{- define "remnawave.labels" -}}
helm.sh/chart: {{ include "remnawave.chart" . }}
{{ include "remnawave.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: remnawave
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "remnawave.selectorLabels" -}}
app.kubernetes.io/name: {{ include "remnawave.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Usage: include "remnawave.componentLabels" (dict "ctx" $ "component" "panel") */}}
{{- define "remnawave.componentLabels" -}}
{{ include "remnawave.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "remnawave.componentSelectorLabels" -}}
{{ include "remnawave.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "remnawave.commonAnnotations" -}}
{{- with .Values.commonAnnotations }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/* ------------------------------------------------------------------
     Scheduling

     Global `scheduling` applies to every component; component values override:
       - nodeSelector: merged, component keys win;
       - tolerations / affinity / topologySpreadConstraints: component value
         replaces the global one when non-empty.
     Usage: include "remnawave.scheduling" (dict "ctx" $ "component" .Values.panel)
------------------------------------------------------------------- */}}
{{- define "remnawave.scheduling" -}}
{{- $g := .ctx.Values.scheduling -}}
{{- $c := .component -}}
{{- $nodeSelector := merge (deepCopy (default (dict) $c.nodeSelector)) (default (dict) $g.nodeSelector) -}}
{{- with $nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (default $g.affinity $c.affinity) }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (default $g.tolerations $c.tolerations) }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (default $g.topologySpreadConstraints $c.topologySpreadConstraints) }}
topologySpreadConstraints:
  {{- tpl (toYaml .) $.ctx | nindent 2 }}
{{- end }}
{{- end -}}

{{/* ------------------------------------------------------------------
     Images
------------------------------------------------------------------- */}}

{{/* Usage: include "remnawave.image" (dict "image" .Values.panel.image "default" .Chart.AppVersion) */}}
{{- define "remnawave.image" -}}
{{- $tag := default .default .image.tag | toString -}}
{{- if .image.digest -}}
{{- printf "%s:%s@%s" .image.repository $tag .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------
     Env rendering

     Values are taken verbatim from a map whose keys are env var names.
       - null and "" are skipped (the application falls back to its default);
       - lists / maps are rendered as JSON ([60, 80] -> "[60,80]");
       - whole floats (YAML numbers are parsed as float64) are rendered as integers;
       - everything else is stringified.
------------------------------------------------------------------- */}}

{{- define "remnawave.envValue" -}}
{{- $v := . -}}
{{- if or (kindIs "slice" $v) (kindIs "map" $v) -}}
{{- toJson $v -}}
{{- else if kindIs "float64" $v -}}
{{- if eq $v (float64 (int64 $v)) -}}{{- int64 $v -}}{{- else -}}{{- $v -}}{{- end -}}
{{- else -}}
{{- $v -}}
{{- end -}}
{{- end -}}

{{- define "remnawave.isSet" -}}
{{- if and (not (kindIs "invalid" .)) (ne (toString .) "") -}}true{{- end -}}
{{- end -}}

{{/* Renders map entries as `KEY: "value"` lines (ConfigMap data). */}}
{{- define "remnawave.envData" -}}
{{- range $k, $v := . }}
{{- if include "remnawave.isSet" $v }}
{{ $k }}: {{ include "remnawave.envValue" $v | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Renders map entries as base64-encoded `KEY: value` lines (Secret data). */}}
{{- define "remnawave.envSecretData" -}}
{{- range $k, $v := . }}
{{- if include "remnawave.isSet" $v }}
{{ $k }}: {{ include "remnawave.envValue" $v | b64enc }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
  Returns a stable random value: explicit value -> value already stored in the
  Secret in the cluster -> new random string.
  Note: `lookup` returns nothing under `helm template` and in most GitOps tools
  (Argo CD), so set such values explicitly there.
  Usage: include "remnawave.persistentSecret" (dict "ctx" $ "secret" "name" "key" "KEY" "value" $v "length" 64)
*/}}
{{- define "remnawave.persistentSecret" -}}
{{- if include "remnawave.isSet" .value -}}
{{- include "remnawave.envValue" .value -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .secret -}}
{{- $data := dict -}}
{{- if $existing }}{{- $data = default (dict) $existing.data -}}{{- end -}}
{{- if hasKey $data .key -}}
{{- index $data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (int .length) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------
     Panel
------------------------------------------------------------------- */}}

{{- define "remnawave.panel.appPort" -}}
{{- include "remnawave.envValue" (default 3000 (index .Values.panel.env "APP_PORT")) -}}
{{- end -}}

{{- define "remnawave.panel.metricsPort" -}}
{{- include "remnawave.envValue" (default 3001 (index .Values.panel.env "METRICS_PORT")) -}}
{{- end -}}

{{/* Panel domain: panel.env.PANEL_DOMAIN, otherwise routing.hosts.panel. */}}
{{- define "remnawave.panel.domain" -}}
{{- $explicit := index .Values.panel.env "PANEL_DOMAIN" -}}
{{- if include "remnawave.isSet" $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- .Values.routing.hosts.panel -}}
{{- end -}}
{{- end -}}

{{/* Public panel host for routing: routing.hosts.panel, otherwise PANEL_DOMAIN. */}}
{{- define "remnawave.routing.panelHost" -}}
{{- default (index .Values.panel.env "PANEL_DOMAIN" | default "") .Values.routing.hosts.panel -}}
{{- end -}}

{{/*
  SUB_PUBLIC_DOMAIN: explicit value, otherwise
    - subscription page enabled: <routing.hosts.sub or panel domain>[/<CUSTOM_SUB_PREFIX>];
    - otherwise: <panel domain>/api/sub.
*/}}
{{- define "remnawave.panel.subPublicDomain" -}}
{{- $explicit := index .Values.panel.env "SUB_PUBLIC_DOMAIN" -}}
{{- $domain := include "remnawave.panel.domain" . -}}
{{- if include "remnawave.isSet" $explicit -}}
{{- $explicit -}}
{{- else if include "remnawave.sub.enabled" . -}}
{{- $host := default $domain .Values.routing.hosts.sub -}}
{{- $prefix := include "remnawave.sub.prefix" . -}}
{{- if $host -}}{{- ternary (printf "%s/%s" $host $prefix) $host (ne $prefix "") -}}{{- end -}}
{{- else if $domain -}}
{{- printf "%s/api/sub" $domain -}}
{{- end -}}
{{- end -}}

{{/* Non-secret env of the panel (ConfigMap). */}}
{{- define "remnawave.panel.configEnv" -}}
{{- $env := deepCopy .Values.panel.env -}}
{{- $_ := set $env "PANEL_DOMAIN" (include "remnawave.panel.domain" .) -}}
{{- $_ := set $env "SUB_PUBLIC_DOMAIN" (include "remnawave.panel.subPublicDomain" .) -}}
{{- if and .Values.valkey.enabled (not (include "remnawave.isSet" (index $env "REDIS_DB"))) -}}
{{- $_ := set $env "REDIS_DB" .Values.valkey.db -}}
{{- end -}}
{{- if and (not .Values.valkey.enabled) (include "remnawave.isSet" .Values.externalRedis.username) -}}
{{- $_ := set $env "REDIS_USERNAME" .Values.externalRedis.username -}}
{{- end -}}
{{- toYaml $env -}}
{{- end -}}

{{/* Secret env of the panel managed by the chart. */}}
{{- define "remnawave.panel.secretEnv" -}}
{{- $name := include "remnawave.panel.fullname" . -}}
{{- $env := deepCopy .Values.panel.secretEnv -}}
{{- range $key, $len := dict "APP_SECRET" 64 "METRICS_PASS" 32 -}}
{{- $_ := set $env $key (include "remnawave.persistentSecret" (dict "ctx" $ "secret" $name "key" $key "value" (index $env $key) "length" $len)) -}}
{{- end -}}
{{- if and (eq .Values.database.mode "external") (not .Values.database.external.existingSecret) .Values.database.external.url -}}
{{- $_ := set $env "DATABASE_URL" .Values.database.external.url -}}
{{- end -}}
{{- if and (not .Values.valkey.enabled) (not .Values.externalRedis.existingSecret) (include "remnawave.isSet" .Values.externalRedis.password) -}}
{{- $_ := set $env "REDIS_PASSWORD" .Values.externalRedis.password -}}
{{- end -}}
{{- toYaml $env -}}
{{- end -}}

{{/* Env vars wired by the chart (Redis, DB from external secrets). */}}
{{- define "remnawave.panel.managedEnv" -}}
{{- if .Values.valkey.enabled }}
{{- if eq .Values.valkey.mode "sidecar" }}
- name: REDIS_SOCKET
  value: {{ .Values.valkey.socketPath | quote }}
{{- else }}
- name: REDIS_HOST
  value: {{ include "remnawave.valkey.fullname" . | quote }}
- name: REDIS_PORT
  value: {{ .Values.valkey.port | toString | quote }}
{{- end }}
{{- if .Values.valkey.auth.enabled }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "remnawave.valkey.secretName" . }}
      key: {{ include "remnawave.valkey.secretKey" . }}
{{- end }}
{{- else }}
{{- if .Values.externalRedis.socket }}
- name: REDIS_SOCKET
  value: {{ .Values.externalRedis.socket | quote }}
{{- else }}
- name: REDIS_HOST
  value: {{ .Values.externalRedis.host | quote }}
- name: REDIS_PORT
  value: {{ .Values.externalRedis.port | toString | quote }}
{{- end }}
{{- if .Values.externalRedis.existingSecret }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalRedis.existingSecret }}
      key: {{ .Values.externalRedis.existingSecretPasswordKey }}
{{- end }}
{{- end }}
{{ include "remnawave.database.urlEnv" . }}
{{- end -}}

{{/* ------------------------------------------------------------------
     Database
------------------------------------------------------------------- */}}

{{- define "remnawave.cnpg.fullname" -}}
{{- default (printf "%s-pg" (include "remnawave.fullname" .)) .Values.database.cnpg.nameOverride | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{/* Secret + key holding DATABASE_URL for the selected mode. */}}
{{- define "remnawave.database.urlSecretRef" -}}
{{- if eq .Values.database.mode "cnpg" -}}
name: {{ printf "%s-app" (include "remnawave.cnpg.fullname" .) }}
key: uri
{{- else if .Values.database.external.existingSecret -}}
name: {{ .Values.database.external.existingSecret }}
key: {{ .Values.database.external.existingSecretKey }}
{{- else -}}
name: {{ include "remnawave.panel.fullname" . }}
key: DATABASE_URL
{{- end -}}
{{- end -}}

{{- define "remnawave.database.urlEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- include "remnawave.database.urlSecretRef" . | nindent 6 }}
{{- end -}}

{{/* initContainer: wait until PostgreSQL accepts connections. */}}
{{- define "remnawave.database.waitContainer" -}}
{{- $w := .Values.database.waitForDb -}}
- name: wait-for-db
  image: {{ include "remnawave.image" (dict "image" $w.image "default" "18-alpine") }}
  imagePullPolicy: {{ $w.image.pullPolicy }}
  env:
    {{- include "remnawave.database.urlEnv" . | nindent 4 }}
  command:
    - sh
    - -c
    - |
      # libpq rejects Prisma-specific query params (?schema=...), strip them
      url="${DATABASE_URL%%\?*}"
      until pg_isready -q -t 3 -d "$url"; do
        echo "waiting for PostgreSQL..."
        sleep {{ $w.interval }}
      done
      echo "PostgreSQL is ready"
  {{- with $w.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $w.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{/* ------------------------------------------------------------------
     Valkey
------------------------------------------------------------------- */}}

{{- define "remnawave.valkey.secretName" -}}
{{- default (include "remnawave.valkey.fullname" .) .Values.valkey.auth.existingSecret -}}
{{- end -}}

{{- define "remnawave.valkey.secretKey" -}}
{{- if .Values.valkey.auth.existingSecret -}}
{{- .Values.valkey.auth.existingSecretPasswordKey -}}
{{- else -}}
password
{{- end -}}
{{- end -}}

{{/* valkey-server arguments for the selected mode. */}}
{{- define "remnawave.valkey.args" -}}
- --save
- ""
- --appendonly
- "no"
- --maxmemory-policy
- {{ .Values.valkey.maxmemoryPolicy | quote }}
{{- with .Values.valkey.maxmemory }}
- --maxmemory
- {{ . | quote }}
{{- end }}
- --loglevel
- {{ .Values.valkey.logLevel | quote }}
{{- if eq .Values.valkey.mode "sidecar" }}
- --port
- "0"
- --unixsocket
- {{ .Values.valkey.socketPath | quote }}
- --unixsocketperm
- "777"
{{- else }}
- --port
- {{ .Values.valkey.port | toString | quote }}
- --protected-mode
- "no"
{{- end }}
{{- if .Values.valkey.auth.enabled }}
- --requirepass
- $(VALKEY_PASSWORD)
{{- end }}
{{- range .Values.valkey.extraArgs }}
- {{ . | quote }}
{{- end }}
{{- end -}}

{{/* Shell command for valkey probes. */}}
{{- define "remnawave.valkey.probeCommand" -}}
{{- $target := ternary (printf "-s %s" .Values.valkey.socketPath) (printf "-p %v" .Values.valkey.port) (eq .Values.valkey.mode "sidecar") -}}
{{- $auth := ternary "-a \"$VALKEY_PASSWORD\" --no-auth-warning " "" .Values.valkey.auth.enabled -}}
- sh
- -c
- {{ printf "valkey-cli %s%s ping | grep -q PONG" $auth $target | quote }}
{{- end -}}

{{/* Full valkey container spec (shared by standalone Deployment and sidecar). */}}
{{- define "remnawave.valkey.container" -}}
- name: valkey
  image: {{ include "remnawave.image" (dict "image" .Values.valkey.image "default" "9-alpine") }}
  imagePullPolicy: {{ .Values.valkey.image.pullPolicy }}
  command:
    - valkey-server
  args:
    {{- include "remnawave.valkey.args" . | nindent 4 }}
  {{- if .Values.valkey.auth.enabled }}
  env:
    - name: VALKEY_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "remnawave.valkey.secretName" . }}
          key: {{ include "remnawave.valkey.secretKey" . }}
  {{- end }}
  {{- if ne .Values.valkey.mode "sidecar" }}
  ports:
    - name: valkey
      containerPort: {{ .Values.valkey.port }}
      protocol: TCP
  {{- end }}
  {{- range $kind, $probe := dict "startupProbe" .Values.valkey.startupProbe "livenessProbe" .Values.valkey.livenessProbe "readinessProbe" .Values.valkey.readinessProbe }}
  {{- if $probe.enabled }}
  {{ $kind }}:
    exec:
      command:
        {{- include "remnawave.valkey.probeCommand" $ | nindent 8 }}
    {{- toYaml (omit $probe "enabled") | nindent 4 }}
  {{- end }}
  {{- end }}
  {{- with .Values.valkey.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.valkey.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: valkey-data
      mountPath: /data
    {{- if eq .Values.valkey.mode "sidecar" }}
    - name: valkey-socket
      mountPath: {{ dir .Values.valkey.socketPath }}
    {{- end }}
{{- end -}}

{{/* ------------------------------------------------------------------
     Subscription page
------------------------------------------------------------------- */}}

{{- define "remnawave.sub.fullname" -}}
{{- printf "%s-sub" (include "remnawave.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Non-secret env of the subscription page (ConfigMap). */}}
{{- define "remnawave.sub.configEnv" -}}
{{- $env := deepCopy .Values.subscriptionPage.env -}}
{{- if not (include "remnawave.isSet" (index $env "REMNAWAVE_PANEL_URL")) -}}
{{- $_ := set $env "REMNAWAVE_PANEL_URL" (printf "http://127.0.0.1:%s" (include "remnawave.panel.appPort" .)) -}}
{{- end -}}
{{- with include "remnawave.sub.prefix" . -}}
{{- $_ := set $env "CUSTOM_SUB_PREFIX" . -}}
{{- end -}}
{{- toYaml $env -}}
{{- end -}}

{{- define "remnawave.sub.container" -}}
{{- $s := .Values.subscriptionPage -}}
- name: subscription-page
  image: {{ include "remnawave.image" (dict "image" $s.image "default" "latest") }}
  imagePullPolicy: {{ $s.image.pullPolicy }}
  ports:
    - name: sub
      containerPort: {{ include "remnawave.sub.port" . }}
      protocol: TCP
  envFrom:
    - configMapRef:
        name: {{ include "remnawave.sub.fullname" . }}
    - secretRef:
        name: {{ include "remnawave.sub.fullname" . }}
    {{- with $s.existingSecret }}
    - secretRef:
        name: {{ . }}
    {{- end }}
    {{- with $s.extraEnvFrom }}
    {{- tpl (toYaml .) $ | nindent 4 }}
    {{- end }}
  {{- with $s.extraEnv }}
  env:
    {{- tpl (toYaml .) $ | nindent 4 }}
  {{- end }}
  {{- range $kind, $probe := dict "startupProbe" $s.startupProbe "livenessProbe" $s.livenessProbe "readinessProbe" $s.readinessProbe }}
  {{- if $probe.enabled }}
  {{ $kind }}:
    tcpSocket:
      port: sub
    {{- toYaml (omit $probe "enabled") | nindent 4 }}
  {{- end }}
  {{- end }}
  {{- with $s.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $s.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $s.extraVolumeMounts }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{- define "remnawave.sub.enabled" -}}
{{- if dig "enabled" false (default (dict) .Values.subscriptionPage) -}}true{{- end -}}
{{- end -}}

{{- define "remnawave.sub.port" -}}
{{- include "remnawave.envValue" (dig "env" "APP_PORT" 3010 (default (dict) .Values.subscriptionPage)) -}}
{{- end -}}

{{- define "remnawave.sub.prefix" -}}
{{- dig "env" "CUSTOM_SUB_PREFIX" "" (default (dict) .Values.subscriptionPage) | default "" | trimAll "/" -}}
{{- end -}}

{{/* ------------------------------------------------------------------
     Routing
------------------------------------------------------------------- */}}

{{- define "remnawave.routing.tlsSecretName" -}}
{{- default (printf "%s-tls" (include "remnawave.fullname" .)) .Values.routing.tls.secretName -}}
{{- end -}}

{{- define "remnawave.routing.gatewayApi.gatewayName" -}}
{{- default (include "remnawave.fullname" .) .Values.routing.gatewayApi.gateway.name -}}
{{- end -}}

{{- define "remnawave.routing.istio.gatewayName" -}}
{{- default (include "remnawave.fullname" .) .Values.routing.istio.gateway.name -}}
{{- end -}}

{{/*
  Routing model shared by Gateway API and Istio: one entry per public host,
  rules ordered from the most specific path.
  - name: panel
    host: panel.example.com
    rules:
      - { name: sub,   path: /sub, port: 3010 }   # subscription page on the panel host
      - { name: panel, path: /,    port: 3000 }
  - name: sub
    host: sub.example.com
    rules:
      - { name: sub, path: /, port: 3010 }
*/}}
{{- define "remnawave.routing.model" -}}
{{- $panelPort := include "remnawave.panel.appPort" . | int -}}
{{- $subPort := include "remnawave.sub.port" . | int -}}
{{- $panelRules := list -}}
{{- $entries := list -}}
{{- if include "remnawave.sub.enabled" . -}}
{{- if .Values.routing.hosts.sub -}}
{{- $entries = append $entries (dict "name" "sub" "host" .Values.routing.hosts.sub "rules" (list (dict "name" "sub" "path" "/" "port" $subPort))) -}}
{{- else -}}
{{- $panelRules = append $panelRules (dict "name" "sub" "path" (printf "/%s" (include "remnawave.sub.prefix" .)) "port" $subPort) -}}
{{- end -}}
{{- end -}}
{{- $panelRules = append $panelRules (dict "name" "panel" "path" "/" "port" $panelPort) -}}
{{- $entries = prepend $entries (dict "name" "panel" "host" (include "remnawave.routing.panelHost" .) "rules" $panelRules) -}}
{{- toYaml $entries -}}
{{- end -}}

{{- define "remnawave.routing.hosts" -}}
{{- $hosts := list -}}
{{- range (include "remnawave.routing.model" . | fromYamlArray) }}{{ $hosts = append $hosts .host }}{{ end -}}
{{- toYaml $hosts -}}
{{- end -}}

{{/* Istio: HTTP -> HTTPS redirect is done by a VirtualService route instead of the Gateway server. */}}
{{- define "remnawave.routing.istio.vsRedirect" -}}
{{- $r := .Values.routing -}}
{{- if and (eq $r.type "istio") $r.tls.enabled $r.tls.httpsRedirect -}}
{{- $mode := $r.istio.redirectMode | default "auto" -}}
{{- if or (eq $mode "virtualService") (and (eq $mode "auto") (include "remnawave.certManager.http01" .)) -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------
     cert-manager
------------------------------------------------------------------- */}}

{{- define "remnawave.certManager.http01" -}}
{{- if and .Values.certManager.enabled (eq .Values.certManager.issuer.solver "http01") -}}true{{- end -}}
{{- end -}}

{{/* Namespace of the Certificate (and of a namespaced Issuer). */}}
{{- define "remnawave.certManager.namespace" -}}
{{- if .Values.certManager.certificate.namespace -}}
{{- .Values.certManager.certificate.namespace -}}
{{- else if eq .Values.routing.type "istio" -}}
{{- .Values.routing.istio.gateway.namespace -}}
{{- else -}}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{- define "remnawave.certManager.issuerName" -}}
{{- $i := .Values.certManager.issuer -}}
{{- if $i.name -}}
{{- $i.name -}}
{{- else if eq $i.kind "ClusterIssuer" -}}
{{- printf "%s-%s" .Release.Namespace (include "remnawave.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "remnawave.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "remnawave.certManager.dnsNames" -}}
{{- if .Values.certManager.certificate.dnsNames -}}
{{- toYaml .Values.certManager.certificate.dnsNames -}}
{{- else if ne .Values.routing.type "none" -}}
{{- include "remnawave.routing.hosts" . -}}
{{- else -}}
{{- toYaml (list) -}}
{{- end -}}
{{- end -}}

{{/* Parents of the HTTP-01 solver HTTPRoute (Gateway API). */}}
{{- define "remnawave.certManager.http01ParentRefs" -}}
{{- $g := .Values.routing.gatewayApi -}}
{{- $refs := .Values.certManager.issuer.http01.gatewayHTTPRoute.parentRefs -}}
{{- if not $refs -}}
{{- if $g.createGateway -}}
{{- $refs = list (dict "name" (include "remnawave.routing.gatewayApi.gatewayName" .) "namespace" .Release.Namespace "sectionName" "http") -}}
{{- else -}}
{{- $refs = $g.httpRedirectParentRefs -}}
{{- end -}}
{{- end -}}
{{- toYaml (default (list) $refs) -}}
{{- end -}}

{{- define "remnawave.certManager.solvers" -}}
{{- $i := .Values.certManager.issuer -}}
{{- if $i.solvers -}}
{{- toYaml $i.solvers -}}
{{- else -}}
{{- $solver := dict -}}
{{- if eq $i.solver "http01" -}}
{{- if eq .Values.routing.type "gatewayApi" -}}
{{- $route := dict "parentRefs" (include "remnawave.certManager.http01ParentRefs" . | fromYamlArray) -}}
{{- with $i.http01.gatewayHTTPRoute.labels }}{{ $_ := set $route "labels" . }}{{ end -}}
{{- $_ := set $solver "http01" (dict "gatewayHTTPRoute" $route) -}}
{{- else -}}
{{- $_ := set $solver "http01" (dict "ingress" (default (dict) $i.http01.ingress)) -}}
{{- end -}}
{{- else -}}
{{- $d := $i.dns01 -}}
{{- $p := dict -}}
{{- if eq $d.provider "cloudflare" -}}
{{- $p = dict "cloudflare" (dict "apiTokenSecretRef" $d.cloudflare.apiTokenSecretRef) -}}
{{- else if eq $d.provider "route53" -}}
{{- $r53 := dict -}}
{{- range $k := list "region" "hostedZoneID" "role" "accessKeyIDSecretRef" "secretAccessKeySecretRef" -}}
{{- with index $d.route53 $k }}{{ $_ := set $r53 $k . }}{{ end -}}
{{- end -}}
{{- $p = dict "route53" $r53 -}}
{{- else if eq $d.provider "rfc2136" -}}
{{- $p = dict "rfc2136" (pick $d.rfc2136 "nameserver" "tsigKeyName" "tsigAlgorithm" "tsigSecretSecretRef") -}}
{{- else if eq $d.provider "webhook" -}}
{{- $p = dict "webhook" (pick $d.webhook "groupName" "solverName" "config") -}}
{{- end -}}
{{- $_ := set $solver "dns01" $p -}}
{{- end -}}
{{- with $i.selector }}{{ $_ := set $solver "selector" . }}{{ end -}}
{{- toYaml (list $solver) -}}
{{- end -}}
{{- end -}}

{{/* Namespaces of shared Gateways that need a ReferenceGrant to the TLS Secret. */}}
{{- define "remnawave.certManager.referenceGrantNamespaces" -}}
{{- $rg := .Values.certManager.referenceGrant -}}
{{- $certNs := include "remnawave.certManager.namespace" . -}}
{{- $nss := list -}}
{{- if and .Values.certManager.enabled .Values.certManager.certificate.create $rg.create (eq .Values.routing.type "gatewayApi") (not .Values.routing.gatewayApi.createGateway) .Values.routing.tls.enabled -}}
{{- if $rg.fromNamespaces -}}
{{- $nss = $rg.fromNamespaces -}}
{{- else -}}
{{- range .Values.routing.gatewayApi.parentRefs -}}
{{- $nss = append $nss (default $.Release.Namespace .namespace) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range ($nss | uniq) }}{{ if ne . $certNs }}{{ $out = append $out . }}{{ end }}{{ end -}}
{{- toYaml $out -}}
{{- end -}}
