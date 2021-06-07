{{/*
Expand the name of the chart.
*/}}
{{- define "isolation-network-policy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "isolation-network-policy.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "isolation-network-policy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "isolation-network-policy.labels" -}}
helm.sh/chart: {{ include "isolation-network-policy.chart" . }}
{{ include "isolation-network-policy.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "isolation-network-policy.lagoonLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "isolation-network-policy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "isolation-network-policy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Lagoon Labels
*/}}
{{- define "isolation-network-policy.lagoonLabels" -}}
lagoon.sh/service: {{ .Release.Name }}
lagoon.sh/service-type: {{ .Chart.Name }}
lagoon.sh/project: {{ .Values.project }}
lagoon.sh/environment: {{ .Values.environment }}
lagoon.sh/environmentType: {{ .Values.environmentType }}
lagoon.sh/buildType: {{ .Values.buildType }}
{{- end }}

{{/*
Lagoon Annotations
*/}}
{{- define "isolation-network-policy.annotations" -}}
lagoon.sh/version: {{ .Values.lagoonVersion | quote }}
{{- if .Values.branch }}
lagoon.sh/branch: {{ .Values.branch | quote }}
{{- end }}
{{- if .Values.prNumber }}
lagoon.sh/prNumber: {{ .Values.prNumber | quote }}
lagoon.sh/prHeadBranch: {{ .Values.prHeadBranch | quote }}
lagoon.sh/prBaseBranch: {{ .Values.prBaseBranch | quote }}
{{- end }}
{{- end }}
