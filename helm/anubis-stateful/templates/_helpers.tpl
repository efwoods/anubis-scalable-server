{{- define "anubis-stateful.selectorLabels" -}}
app.kubernetes.io/name: anubis-stateful
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "anubis-stateful.labels" -}}
{{ include "anubis-stateful.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: anubis
app.kubernetes.io/component: media-and-mcp
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}
