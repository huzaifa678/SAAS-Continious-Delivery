{{- define "saas-e2e.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "saas-e2e.fullname" -}}
{{- default (include "saas-e2e.name" .) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "saas-e2e.labels" -}}
app.kubernetes.io/name: {{ include "saas-e2e.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: e2e-smoke
{{- end -}}

{{- define "saas-e2e.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "saas-e2e.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
