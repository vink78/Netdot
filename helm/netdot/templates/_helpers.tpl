{{- define "netdot.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "netdot.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "netdot.labels" -}}
app.kubernetes.io/name: {{ include "netdot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "netdot.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netdot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
