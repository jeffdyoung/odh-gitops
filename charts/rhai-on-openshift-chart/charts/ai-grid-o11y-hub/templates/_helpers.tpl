{{/*
Chart name, overridable only through the release, since this chart renders a fixed set of
cluster-scoped names that the ingest contract depends on.
*/}}
{{- define "ai-grid-o11y-hub.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ai-grid-o11y-hub.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels. part-of marks the whole aggregation path, hub and spoke alike, so the two
charts' objects can be listed together.
*/}}
{{- define "ai-grid-o11y-hub.labels" -}}
helm.sh/chart: {{ include "ai-grid-o11y-hub.chart" . }}
app.kubernetes.io/name: {{ include "ai-grid-o11y-hub.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: ai-grid-usage-logs
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
The LokiStack tenant, deliberately not a value.

In `openshift-logging` tenant mode the gateway's OPA sidecar injects a namespace matcher
built from the *hub's* RBAC for the `application` tenant, so a record carrying a namespace
that exists only on a spoke is accepted with 204 and then matches no query, for any user
including cluster-admin. `infrastructure` is in the gateway's --opa.skip-tenants list and
receives no matcher. Making this configurable would let a one-word override turn every
spoke's data silently unreadable.
*/}}
{{- define "ai-grid-o11y-hub.tenant" -}}
infrastructure
{{- end }}

{{- define "ai-grid-o11y-hub.lokiStackName" -}}
{{- .Values.lokiStack.name | required "lokiStack.name is required" }}
{{- end }}

{{- define "ai-grid-o11y-hub.writerName" -}}
{{- .Values.ingest.writer.serviceAccountName | default (printf "%s-writer" (include "ai-grid-o11y-hub.lokiStackName" .)) }}
{{- end }}

{{- define "ai-grid-o11y-hub.readerName" -}}
{{- .Values.ingest.reader.serviceAccountName | default (printf "%s-reader" (include "ai-grid-o11y-hub.lokiStackName" .)) }}
{{- end }}

{{- define "ai-grid-o11y-hub.obcName" -}}
{{- .Values.objectStorage.obc.name | default (printf "%s-bucket" (include "ai-grid-o11y-hub.lokiStackName" .)) }}
{{- end }}

{{/*
Name of the Secret the LokiStack reads. Rendered by this chart when
objectStorage.secret.create, supplied by the user otherwise.
*/}}
{{- define "ai-grid-o11y-hub.storageSecretName" -}}
{{- if .Values.objectStorage.secret.create -}}
{{- .Values.objectStorage.secretName | default (printf "%s-object-storage" (include "ai-grid-o11y-hub.lokiStackName" .)) }}
{{- else -}}
{{- .Values.objectStorage.secretName | required "objectStorage.secretName is required unless objectStorage.secret.create is true" }}
{{- end -}}
{{- end }}
