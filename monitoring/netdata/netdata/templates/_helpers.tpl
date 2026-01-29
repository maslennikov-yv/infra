{{- define "netdata.name" -}}
netdata
{{- end -}}

{{- define "netdata.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "netdata.labels" -}}
app.kubernetes.io/name: {{ include "netdata.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "netdata.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netdata.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
