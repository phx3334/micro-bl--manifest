{{- define "fake-tiktok.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride -}}
{{- end -}}

{{- define "fake-tiktok.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- define "fake-tiktok.labels" -}}
app.kubernetes.io/part-of: fake-tiktok
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "fake-tiktok.image" -}}
{{- printf "%s/fake_tiktok-%s:%s" .root.Values.images.registry .component .root.Values.images.tag -}}
{{- end -}}

{{- define "fake-tiktok.configMapName" -}}
{{- printf "%s-config" (include "fake-tiktok.fullname" .) -}}
{{- end -}}

{{- define "fake-tiktok.secretName" -}}
{{- printf "%s-secret" (include "fake-tiktok.fullname" .) -}}
{{- end -}}

{{- /* 凭据来源：显式指定 existingSecret 时用外部 Secret，否则用 Chart 自建的 Secret */ -}}
{{- define "fake-tiktok.secretRefName" -}}
{{- if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else -}}
{{- include "fake-tiktok.secretName" . -}}
{{- end -}}
{{- end -}}