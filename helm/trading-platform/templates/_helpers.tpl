{{/*
Expand the name of the chart.
*/}}
{{- define "trading-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "trading-platform.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "trading-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "trading-platform.labels" -}}
helm.sh/chart: {{ include "trading-platform.chart" . }}
{{ include "trading-platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: radix-hft
{{- end }}

{{/*
Selector labels
*/}}
{{- define "trading-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trading-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "trading-platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "trading-platform.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image tag helper — falls back to global.imageTag if service-specific tag not set
*/}}
{{- define "trading-platform.imageTag" -}}
{{- .tag | default .global.imageTag | default "latest" }}
{{- end }}

{{/*
Full image reference for a service
Usage: {{ include "trading-platform.image" (dict "registry" .Values.global.imageRegistry "repo" "radix-hft/order-service" "tag" .Values.orderService.image.tag "global" .Values.global) }}
*/}}
{{- define "trading-platform.image" -}}
{{- $registry := .registry | default "" }}
{{- $tag := .tag | default .global.imageTag | default "latest" }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry .repo $tag }}
{{- else }}
{{- printf "%s:%s" .repo $tag }}
{{- end }}
{{- end }}

{{/*
Environment label for pod annotations
*/}}
{{- define "trading-platform.environment" -}}
{{- .Values.global.environment | default .Release.Namespace }}
{{- end }}

{{/*
Return true if pod disruption budgets should be created
*/}}
{{- define "trading-platform.pdbEnabled" -}}
{{- if or .Values.global.pdbEnabled (and .Values.orderService.podDisruptionBudget.enabled) }}
true
{{- end }}
{{- end }}

{{/*
Tolerations for trading-critical nodes
*/}}
{{- define "trading-platform.tradingCriticalTolerations" -}}
- key: workload
  value: trading-critical
  effect: NoSchedule
- key: dedicated
  operator: Equal
  value: trading-critical
  effect: NoExecute
  tolerationSeconds: 30
{{- end }}

{{/*
Pod affinity rules for high availability
*/}}
{{- define "trading-platform.podAntiAffinity" -}}
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
          - key: app.kubernetes.io/name
            operator: In
            values:
              - {{ include "trading-platform.name" . }}
      topologyKey: kubernetes.io/hostname
{{- end }}

{{/*
Topology spread constraints for zone distribution
*/}}
{{- define "trading-platform.topologySpreadConstraints" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: {{ include "trading-platform.name" . }}
        app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
