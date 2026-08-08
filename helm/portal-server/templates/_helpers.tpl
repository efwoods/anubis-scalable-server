{{- define "portal-server.selectorLabels" -}}
app.kubernetes.io/name: portal-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "portal-server.labels" -}}
{{ include "portal-server.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: anubis
app.kubernetes.io/component: customer-portal
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}
