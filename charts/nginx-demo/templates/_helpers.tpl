{{- define "nginx-demo.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{- define "nginx-demo.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "nginx-demo.labels" -}}
app.kubernetes.io/name: {{ include "nginx-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ .Values.labels.appPartOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "nginx-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nginx-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
