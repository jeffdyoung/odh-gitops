# ai-grid-o11y-hub

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1.0](https://img.shields.io/badge/AppVersion-0.1.0-informational?style=flat-square)

Central LokiStack on an ACM hub that AI Grid spokes write MaaS usage logs to

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| commonLabels | object | `{}` | Labels added to every object this chart renders. |
| createNamespace | bool | `true` | Create `namespace`. Set false when it is managed elsewhere. |
| enabled | bool | `false` | Render this chart. The parent gates the subchart on the same key. |
| ingest.reader.create | bool | `false` | Create a read-only identity, for Grafana, a billing job or any other consumer that should not be able to write. Off by default: reads also work with any hub user who already holds the grant, so this is only needed for an unattended consumer. |
| ingest.reader.serviceAccountName | string | `""` | Reader ServiceAccount name. Defaults to `<lokiStack.name>-reader`. |
| ingest.writer.create | bool | `true` | Create the writer ServiceAccount, ClusterRole and binding. This is the identity every spoke presents, so without it no spoke can write. |
| ingest.writer.serviceAccountName | string | `""` | Writer ServiceAccount name. Defaults to `<lokiStack.name>-writer`. |
| lokiStack.enabled | bool | `true` | Render the store: the LokiStack, its object storage and the ingest identities. Set false to render nothing but the distribution policy, for a hub that forwards to a LokiStack this chart did not create — the endpoint is only a string, so the store may live anywhere. Everything under `objectStorage` and `ingest` is skipped with it. |
| lokiStack.limits | object | `{}` | `spec.limits`, passed through. Retention lives here and Loki keeps everything forever without it, e.g. `global: {retention: {days: 30}}`. The hub carries aggregated fleet volume, so this is a sizing decision the chart cannot make. |
| lokiStack.name | string | `"usage-logs"` | LokiStack name. It also prefixes the storage Secret, the ingest ClusterRoles and the Route the Loki operator creates, so the ingest endpoint is `https://<name>-<namespace>.apps.<hub-domain>/api/logs/v1/infrastructure/otlp`. |
| lokiStack.schemas | list | `[{"effectiveDate":"","version":"v13"}]` | Object storage schemas. `effectiveDate` must not be in the future at install time or the stack never becomes Ready, so it has no default and must be set. |
| lokiStack.size | string | `"1x.extra-small"` | Loki t-shirt size. `1x.extra-small` reserves 2 CPU and 8Gi per ingester across two replicas and will not schedule on a small hub; `1x.demo` carries identical ingestion limits (4 MB/s sustained, 6 MB burst, 5 MB per stream) with no resource requests and replication factor 1, but has no redundancy and is documented by Loki as demo-only. |
| lokiStack.storageClassName | string | `"gp3-csi"` | StorageClass for the ingester, compactor and index-gateway volumes. Must be RWO. |
| lokiStack.template | object | `{}` | `spec.template`, passed through, for per-component replicas, tolerations and node placement. |
| namespace | string | `"ai-grid-o11y"` | Namespace holding the LokiStack, its storage Secret and the ingest identities. |
| objectStorage.obc.create | bool | `false` | Render an ObjectBucketClaim, for a hub with OpenShift Data Foundation. The claim's credentials are **not** copied into the storage Secret: ODF publishes them under different key names than Loki reads, and no controller translates them. See the chart README for the one command that does it. |
| objectStorage.obc.generateBucketName | string | `""` | Bucket name prefix; ODF appends a unique suffix. |
| objectStorage.obc.name | string | `""` | ObjectBucketClaim name. Defaults to `<lokiStack.name>-bucket`. |
| objectStorage.obc.storageClassName | string | `"openshift-storage.noobaa.io"` | ObjectBucketClaim StorageClass. |
| objectStorage.secret.accessKeyId | string | `""` | Access key id. |
| objectStorage.secret.accessKeySecret | string | `""` | Access key secret. |
| objectStorage.secret.bucketNames | string | `""` | Bucket name. |
| objectStorage.secret.create | bool | `false` | Render the storage Secret from the values below. Leave false and set `objectStorage.secretName` to bring your own, which is the right choice when the credentials come from a cloud credential operator. |
| objectStorage.secret.endpoint | string | `""` | S3 endpoint, e.g. `https://s3.openshift-storage.svc:443` for Multicloud Object Gateway or `https://s3.us-east-1.amazonaws.com`. |
| objectStorage.secret.region | string | `""` | Region, for endpoints that require it. |
| objectStorage.secretName | string | `""` | Name of the S3-shaped Secret the LokiStack reads. The Loki operator requires the keys `bucketnames`, `endpoint`, `access_key_id` and `access_key_secret`. |
| objectStorage.serviceCA.configMapName | string | `"openshift-service-ca-bundle"` | ConfigMap name. |
| objectStorage.serviceCA.enabled | bool | `false` | Render a service-CA ConfigMap and point `spec.storage.tls` at it. Needed when the S3 endpoint is an in-cluster Service, whose certificate the stack does not otherwise trust. An endpoint with a publicly trusted certificate needs neither. |

