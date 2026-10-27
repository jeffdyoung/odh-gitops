# ai-grid-o11y-hub

The receiving end of AI Grid usage-log aggregation: a LokiStack on an ACM hub that spoke
clusters write their MaaS usage records to, plus the identities that authorize the write.

The hub runs no OpenShift AI. This chart needs the Loki operator and an S3-compatible
endpoint, nothing else — no RHOAI, no `odh-observability`, no ACM.

Disabled by default. `ai-grid-o11y-hub.enabled=true` turns it on.

## Prerequisites

| | |
|---|---|
| Loki operator | the parent chart installs it through `dependencies.loki`; this chart reuses it and declares no operator of its own |
| Object storage | an S3-compatible endpoint and a bucket. Multicloud Object Gateway, ODF, AWS S3 and Minio all work |
| StorageClass | RWO, for the ingester, compactor and index-gateway volumes |

The chart renders `LokiStack` and `ObjectBucketClaim` resources unconditionally when
enabled, rather than gating on CRD presence, so a render is reproducible without a cluster
and GitOps tooling retries until the operators are ready.

`lokiStack.enabled` covers the whole store — the `LokiStack`, its object storage and the
ingest identities. Everything in this chart is under it, so leaving it true is the normal
case; false is for a hub whose store this chart did not create.

## What it creates

| Object | Name | Notes |
|---|---|---|
| `Namespace` | `ai-grid-o11y` | skip with `createNamespace: false` |
| `ObjectBucketClaim` | `<stack>-bucket` | only with `objectStorage.obc.create` |
| `Secret` | `<stack>-object-storage` | only with `objectStorage.secret.create`; otherwise supplied |
| `ConfigMap` | `openshift-service-ca-bundle` | only with `objectStorage.serviceCA.enabled` |
| `LokiStack` | `usage-logs` | `tenants.mode: openshift-logging` |
| `ServiceAccount` + `ClusterRole` + binding | `<stack>-writer`, `<stack>-infrastructure-writer` | the identity every spoke presents |
| `ServiceAccount` + `ClusterRole` + binding | `<stack>-reader`, `<stack>-infrastructure-reader` | only with `ingest.reader.create` |
| `Route` | `usage-logs` | created by the Loki operator, not by this chart |

## The ingest contract

This is what `Monitoring.spec.usageLogs.exporters` on each spoke consumes, and it is the
reason several things here are not configurable.

| | |
|---|---|
| **Endpoint** | `https://<route-host>/api/logs/v1/infrastructure/otlp/v1/logs` |
| **Collector `endpoint` value** | the same without `/v1/logs`; an `otlphttp` exporter appends it |
| **Method** | `POST`, OTLP, `application/json` or `application/x-protobuf` |
| **Auth** | `Authorization: Bearer <token>` for an identity with `create` on `infrastructure`/`logs` |
| **Tenant** | from the URL path. `X-Scope-OrgID` is not used in `openshift-logging` mode |
| **TLS** | the Route's serving certificate. Publicly trusted on ROSA, so spokes need no CA bundle |
| **Success** | `HTTP 204`, empty body |

**The tenant is `infrastructure` and the chart does not let you change it.** In
`openshift-logging` mode the gateway's OPA sidecar injects a namespace matcher built from
the *hub's* RBAC for the `application` tenant, so a record carrying a namespace that exists
only on a spoke is accepted with `204` and then matches no query — for any user, including
cluster-admin. `infrastructure` is in the gateway's `--opa.skip-tenants` list and receives
no matcher. A one-word override would make every spoke's data silently unreadable while
every write still succeeded, so the tenant is fixed in a helper with that reasoning beside
it.

**The tenant is also the RBAC resource**, not the thing being written: the grant is `create`
on resource `infrastructure` with resourceName `logs`. Reversing them authorizes nothing
while reading plausibly. `oc auth can-i` cannot check it either, because
`loki.grafana.com/infrastructure` is not a served API and `can-i` answers `no` even for a
working writer. Use a `SubjectAccessReview`, or test by writing.

## Object storage

Three ways in, because the credentials' origin differs per platform.

**Bring your own Secret** (default). Set `objectStorage.secretName`. The Loki operator reads
the keys `bucketnames`, `endpoint`, `access_key_id` and `access_key_secret`, and optionally
`region`. This is the right choice when a cloud credential operator owns the Secret.

**Render the Secret from values.** Set `objectStorage.secret.create` and the four fields.
Suitable for an external S3 endpoint where the keys are already known.

**Create an ObjectBucketClaim.** Set `objectStorage.obc.create` for a hub with ODF. The
claim is declarative, but **its credentials are not copied into the storage Secret**: ODF
publishes the bucket name in a ConfigMap and the keys in a Secret, both under names the Loki
operator does not read, and no controller translates them. Translating is a read of live
cluster state, which a template cannot do. The chart's `NOTES.txt` prints the one command
that does it; until it runs, the LokiStack will not become Ready. A translating Job was
considered and rejected: it needs a CLI image this repo deliberately has no default for, RBAC
to read one Secret and create another, and hook ordering ahead of the LokiStack — more
machinery than an ODF-only convenience justifies.

Set `objectStorage.serviceCA.enabled` when the endpoint is an in-cluster Service, such as
`https://s3.openshift-storage.svc:443`. It renders a service-CA ConfigMap and points
`spec.storage.tls` at it. An endpoint with a publicly trusted certificate needs neither.

## Credentials

The chart creates the writer identity. It cannot mint the token, because a token is not a
declarative object:

```bash
oc create token usage-logs-writer -n ai-grid-o11y --duration=8760h
```

That token is a portable bearer credential for the hub, bound to namespace and
ServiceAccount but not to a pod or Secret, carrying the cluster's default audience. The
grant is narrow — `create` on one tenant — but the token is not Loki-specific: the LokiStack
gateway validates it with a `TokenReview` and a `SubjectAccessReview` against the hub API
server, so revoking a spoke is an RBAC edit here rather than a Loki change.

Nothing rotates it and no object reports its age. The spoke side re-reads its mounted
credential, so a rotated Secret does reach a running collector, but the schedule is an
operational commitment this chart cannot make.

`ingest.reader.create` adds a separate read-only identity (`get`, not `create`) for an
unattended consumer such as Grafana or a billing job. It is off by default, since any hub
user who already holds the grant can read.

## Sizing and retention

`size` defaults to `1x.extra-small`, which reserves 2 CPU and 8Gi per ingester across two
replicas. On a small hub that does not schedule, and the failure is quiet: the LokiStack
never reports Ready. `1x.demo` has identical ingestion limits — 4 MB/s sustained, 6 MB
burst, 5 MB per stream — with no resource requests and replication factor 1, so it fits
anywhere, but it has no redundancy and Loki documents it as demo-only.

`lokiStack.limits` is a passthrough, and **retention lives there**. Loki keeps everything
forever without it:

```yaml
lokiStack:
  limits:
    global:
      retention:
        days: 30
```

The hub carries aggregated fleet volume, so the figure is a cost decision the chart cannot
make for you. No default is supplied rather than one invented.

## Per-spoke read isolation

Every spoke writes to the one `infrastructure` tenant with the same credential, so any
spoke's token can read every other spoke's usage data. In `openshift-logging` mode the
gateway's OPA arguments are operator-managed, so this cannot be narrowed by configuration.

Per-spoke isolation needs `spec.tenants.mode: static`, where tenants are declared with their
own OIDC authentication and authorization. That replaces bearer-token-plus-SAR as the auth
mechanism, which changes the ingest contract above for every spoke. It is a design decision,
not a value, which is why this chart does not offer the mode.

## Verify

```bash
oc wait --for=condition=Ready lokistack/usage-logs -n ai-grid-o11y --timeout=15m
ROUTE=$(oc get route usage-logs -n ai-grid-o11y -o jsonpath='{.spec.host}')
TOKEN=$(oc create token usage-logs-writer -n ai-grid-o11y --duration=1h)

curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST "https://${ROUTE}/api/logs/v1/infrastructure/otlp/v1/logs" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"log_type","value":{"stringValue":"application"}}]},
       "scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$(date +%s)"'000000000","body":{"stringValue":"probe"}}]}]}]}'
```

`204` means the write was accepted. Then confirm storage is actually exercised, which
`Ready` does not tell you:

```bash
oc logs -n ai-grid-o11y usage-logs-ingester-0 | grep 'flushing stream'
```

A `memberlist fast-join` error during cold start is benign — a single ingester has no peer
to join yet. Check for errors after the first flush.

## Values

See [api-docs.md](api-docs.md), generated by `make helm-docs`.
