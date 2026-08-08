{{/* Common labels applied to every object this chart renders. */}}
{{- define "anubis-platform.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: anubis
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Shared ALB annotations.

Every Ingress in this chart joins one load balancer through group.name, so these must be
identical across all three -- the controller reconciles conflicting group-level
annotations by last-writer-wins, which produces a load balancer whose configuration
depends on apply order.
*/}}
{{- define "anubis-platform.albAnnotations" -}}
alb.ingress.kubernetes.io/group.name: {{ .Values.ingress.groupName | quote }}
alb.ingress.kubernetes.io/scheme: {{ .Values.ingress.scheme | quote }}
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/ssl-redirect: "443"
alb.ingress.kubernetes.io/certificate-arn: {{ .Values.ingress.certificateArn | quote }}
alb.ingress.kubernetes.io/load-balancer-attributes: >-
  idle_timeout.timeout_seconds={{ .Values.ingress.idleTimeoutSeconds }},
  routing.http2.enabled=true,
  routing.http.drop_invalid_header_fields.enabled=true
alb.ingress.kubernetes.io/target-group-attributes: >-
  stickiness.enabled=true,
  stickiness.type=lb_cookie,
  stickiness.lb_cookie.duration_seconds={{ .Values.ingress.stickinessSeconds }},
  deregistration_delay.timeout_seconds={{ .Values.ingress.deregistrationDelaySeconds }}
alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "10"
alb.ingress.kubernetes.io/healthy-threshold-count: "2"
alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
{{- end }}
