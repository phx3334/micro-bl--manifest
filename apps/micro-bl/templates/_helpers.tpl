{{- define "micro-bl.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride -}}
{{- end -}}

{{- define "micro-bl.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- define "micro-bl.labels" -}}
app.kubernetes.io/part-of: micro-bl
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "micro-bl.image" -}}
{{- printf "%s/micro-bl-%s:%s" .root.Values.images.registry .component .root.Values.images.tag -}}
{{- end -}}

{{- define "micro-bl.configMapName" -}}
{{- printf "%s-config" (include "micro-bl.fullname" .) -}}
{{- end -}}

{{- define "micro-bl.secretName" -}}
{{- printf "%s-secret" (include "micro-bl.fullname" .) -}}
{{- end -}}

{{- /* 凭据来源：显式指定 existingSecret 时用外部 Secret，否则用 Chart 自建的 Secret */ -}}
{{- define "micro-bl.secretRefName" -}}
{{- if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else -}}
{{- include "micro-bl.secretName" . -}}
{{- end -}}
{{- end -}}