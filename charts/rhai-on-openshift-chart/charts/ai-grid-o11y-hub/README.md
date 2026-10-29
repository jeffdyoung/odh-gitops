# ai-grid-o11y-hub

The hub side of AI Grid usage-log aggregation, in two halves that install on the same
cluster:

| | |
|---|---|
| **the store** | a LokiStack that spoke clusters write their MaaS usage records to, plus the identities that authorize the write. `lokiStack.enabled`, on by default |
| **the spoke policy** | one ACM `Placement` and one `Policy` that configure every MaaS spoke to forward here. `spokePolicy.enabled`, off by default |

Both run on the hub. The spoke policy is *about* spokes but installs nowhere near one: a
spoke in an ACM fleet receives its configuration through the policy and needs nothing
installed on it.

A spoke outside ACM is the sibling chart's job:
[ai-grid-o11y-spoke](../ai-grid-o11y-spoke) installs on the spoke itself and places the
credential there directly.

The hub runs no OpenShift AI, so set `operator.enabled: false` on the parent chart. The
`DSCInitialization` and `DataScienceCluster` then disappear too, since they are gated on their
CRDs existing and nothing installs them on a hub — a fresh hub gets 13 objects: the Loki
operator, this chart's store, and nothing else. A render with `--set skipCrdCheck=true` still
shows the two CRs, because that flag forces the check true.

The store needs the Loki operator and an S3-compatible endpoint, nothing else — no RHOAI and
no `odh-observability`. The spoke policy needs ACM on
this cluster and the spokes imported; it renders ACM resources and does not install ACM,
following `grid-enrollment`.

Disabled by default. `ai-grid-o11y-hub.enabled=true` turns it on.

## Prerequisites

| | |
|---|---|
| Loki operator | the parent chart installs it through `dependencies.loki`; this chart reuses it and declares no operator of its own |
| Object storage | an S3-compatible endpoint and a bucket. Multicloud Object Gateway, ODF, AWS S3 and Minio all work |
| StorageClass | RWO, for the ingester, compactor and index-gateway volumes |

The `LokiStack` and the `ObjectBucketClaim` are gated on their CRDs existing, like every
other dependency CR in this chart, so **the first install does not create the store**: the
release that creates the LokiStack is the same release that installs the Loki operator, and
`helm install` rejects the entire manifest for an unknown kind rather than retrying. Run the
same `helm upgrade --install` again once the CRDs are there — the parent `NOTES.txt` says so
too, and `scripts/wait-for-crds.sh` waits for them. For a render without a cluster, where
`lookup` always comes back empty, pass `--set skipCrdCheck=true --set global.skipCrdCheck=true`;
the second flag is what a subchart can see.

`lokiStack.enabled` covers the whole store — the `LokiStack`, its object storage and the
ingest identities. Leaving it true is the normal case; false renders only the spoke policy,
for a hub that forwards to a LokiStack this chart did not create.

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
| `Namespace` | `ai-grid-policies` | spoke policy only |
| `ManagedClusterSetBinding` | `default` | spoke policy only; ACM matches it to the set by name |
| `Placement` + `PlacementBinding` | `ai-grid-maas-spokes` | spoke policy only |
| `Policy` | `ai-grid-maas-remote-usage-logs` | spoke policy only; one `ConfigurationPolicy`, two object templates |

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

The chart creates the writer identity. **It does not create a Secret containing the token,
and no object it renders ever holds one** — a token is not a declarative object, so it is
minted imperatively:

```bash
oc create token usage-logs-writer -n ai-grid-o11y --duration=8760h > hub-writer-token
```

That leaves the obvious question of where it goes. There are two destinations, and a spoke
needs exactly one of them:

| How the spoke is configured | Where the token goes |
|---|---|
| In an ACM fleet | a Secret in `spokePolicy.namespace` on this hub, named by `spokePolicy.credentialSecretName`. The policy delivers it to every selected spoke as encrypted ciphertext — nothing to do per spoke |
| Directly | the [ai-grid-o11y-spoke](../ai-grid-o11y-spoke) chart on the spoke cluster, with `credential.enabled` set and `--set-file ai-grid-o11y-spoke.credential.token=./hub-writer-token`. It creates the Secret the collector mounts |

For the ACM path:

```bash
oc create secret generic usage-logs-hub-credential -n ai-grid-policies \
  --from-literal=token="$(oc create token usage-logs-writer -n ai-grid-o11y --duration=8760h)"
```

`NOTES.txt` prints both, resolved to the names this release actually used. Delete any local
copy of the token afterwards.

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

## The spoke policy

`spokePolicy.enabled` adds one `Placement` and one `Policy` that set
`DSCInitialization.spec.monitoring.usageLogs` on every selected spoke and deliver the writer
token there. Onboarding a spoke then needs no per-cluster hand editing and no spoke
credentials.

**Install it as a second step, not at the same time.** `spokePolicy.endpoint` is the
LokiStack's Route host, which does not exist until the stack is Ready — so the order is
install the store, read the Route, then upgrade the *same release* with the spoke-policy
values added:

```bash
# step one, run twice: the store's CRs wait for the Loki operator's CRDs
helm upgrade --install rhoai ./charts/rhai-on-openshift-chart \
  -f docs/examples/values-ai-grid-o11y-hub.yaml -n rhoai-gitops
./scripts/wait-for-crds.sh
helm upgrade --install rhoai ./charts/rhai-on-openshift-chart \
  -f docs/examples/values-ai-grid-o11y-hub.yaml -n rhoai-gitops

# translate the ObjectBucketClaim if objectStorage.obc.create is set — see NOTES.txt
oc wait --for=condition=Ready lokistack/usage-logs -n ai-grid-o11y --timeout=15m
ROUTE=$(oc get route usage-logs -n ai-grid-o11y -o jsonpath='{.spec.host}')

# step two, with the Route host now known
helm upgrade --install rhoai ./charts/rhai-on-openshift-chart \
  -f docs/examples/values-ai-grid-o11y-hub.yaml \
  -f docs/examples/values-ai-grid-o11y-spoke-policy.yaml -n rhoai-gitops \
  --set ai-grid-o11y-hub.spokePolicy.endpoint="https://$ROUTE/api/logs/v1/infrastructure/otlp"

# only now does ai-grid-policies exist, so the credential goes in after, not before
oc create secret generic usage-logs-hub-credential -n ai-grid-policies \
  --from-literal=token="$(oc create token usage-logs-writer -n ai-grid-o11y --duration=8760h)"
oc label managedcluster <spoke> ai-grid.redhat.com/maas=true
```

The credential lands after the upgrade because `ai-grid-policies` is the policy half's own
namespace: before that upgrade there is nowhere to put it. The policy resolves its hub templates
only when a `Placement` has a decision to deliver to, so a policy that exists before its Secret
does is not an error — it reports `PlacementSatisfied=False NoManagedClusterMatched` until a
spoke is imported and labelled, and picks the token up then.

A second *release* will not work: both halves are in one chart under the parent, so a second
release re-renders the shared operator, DSCI and DSC objects and collides with the first on
Helm's ownership check. Keep both `-f` files on the upgrade — dropping the first does not
quietly resize the store to the `1x.extra-small` default, it fails the render outright, because
`lokiStack.schemas` defaults to one entry with an empty `effectiveDate` and the chart requires
one. That is the intended outcome: a store that resized itself on an upgrade would be far worse
than one that refuses to render.

**The endpoint is supplied, not computed**, even though this chart renders the store it
points at. The Route's domain belongs to the cluster and may carry an
infrastructure-specific prefix — on ROSA it is `apps.rosa.<name>...`, not `apps.<name>...` —
so a composed host would be wrong on exactly the clusters where it matters. It is validated
instead: a render fails if it ends in `/v1/logs`, which the collector's exporter appends and
which would 404 every record, or if it does not address the `infrastructure` tenant.

**`usageLogs.storage` is deliberately not delivered.** It is per-cluster — secret name and
storage class — and belongs to whatever installs RHOAI on the spoke. This policy completes a
spoke whose usage logs already run locally; it does not turn them on. A spoke needing both
gets `storage` from its own install and the rest from here.

Two per-spoke values come from ACM templates rather than Helm, resolved per cluster at
delivery:

| Value | Source | Resolved on |
|---|---|---|
| `cluster_name` | `{{hub .ManagedClusterName hub}}` | the hub, from the Placement decision |
| `cluster_id` | `lookup` of `ClusterClaim/id.k8s.io` | the managed cluster |

The credential travels as `$ocm_encrypted:` ciphertext with a per-policy IV, so the token is
not replicated in clear text. It belongs under `data:` and not `stringData:`, because
`fromSecret` already emits base64 — `stringData:` double-encodes it and the policy still
reports Compliant, so the collector would present a corrupt token. The symptom is fainter than
a `401`: the LokiStack gateway redirects an unauthenticated write with `302` to
`/openshift/infrastructure/login`, byte-identical to the response for a garbage token, so there
is no error status to grep for on a cluster you may have no credentials for — only
`otelcol_exporter_send_failed_log_records` climbing.

Two reporting gaps worth knowing. Drift is remediated in enforce mode but only
`status.details[].history` records it, so anything watching `status.compliant` sees a
permanently healthy fleet; a paired inform-mode policy is the usual answer. And compliance
says the Secret matches the policy, not that the token works: an expired or wrongly scoped
token distributes as Compliant, and `ManagedClusterView` refuses Secrets, so the hub cannot
read back what a spoke holds. The signal that the chain works is records arriving here with
the right `cluster_name`.

When deleting, remove the Policy before the namespace, or the objects it delivered are
orphaned on the spokes.

## Sizing and retention

`size` defaults to `1x.extra-small`, which requests 1 CPU and 5.25Gi per ingester across
three ingesters — around 3 CPU and 15.75Gi for the ingest tier alone, before the other
components. On a small hub that does not schedule, and the failure is quiet: the LokiStack
never reports Ready. `1x.demo` has identical ingestion limits — 4 MB/s sustained, 6 MB
burst, 5 MB per stream — with a single ingester and no resource requests at all, so it fits
anywhere. It is also the only size with replication factor 1; every other size uses 2. That
is the redundancy you give up, and it is why Loki documents it as demo-only.

**The sizes are the Loki operator's, and the set is closed.** `spec.size` is a
`+kubebuilder:validation:Enum` of exactly `1x.demo`, `1x.pico`, `1x.extra-small`, `1x.small`
and `1x.medium`; each maps to a fixed table of per-component CPU, memory and PVC sizes in the
operator (`operator/internal/manifests/internal/sizes.go`). You cannot define a new size, and
you cannot override a size's CPU or memory: `LokiComponentSpec` exposes only `replicas`,
`nodeSelector`, `tolerations` and `podAntiAffinity` — there is no `resources` field, and
per-component request tuning is an explicit non-goal in the operator's own planning
(LOG-5204, LOG-5939).

What you *can* adjust, through this chart:

| | |
|---|---|
| `lokiStack.template` | per-component `replicas`, `nodeSelector`, `tolerations`, `podAntiAffinity`. Dropping `1x.extra-small`'s ingesters from three to two cuts the ingest tier's footprint by a third without changing the per-pod request |
| `lokiStack.limits` | ingestion and query limits — `spec.limits` is independent of size, so you can raise the rate on a small size or cap it on a large one |

So the practical lever on footprint is size plus replica count, and the practical lever on
throughput is `limits`. If a size's per-pod requests are wrong for your hardware, the only
options are a different size or fewer replicas.

Note `1x.pico` arrived in OpenShift Logging 6.1; this chart pins the Loki operator to
`stable-6.5`, so all five values in the enum are available.

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

## One credential for the fleet

Every spoke presents the same writer token. That is a deliberate starting point, not an
oversight, and it has two consequences: a leaked token is a write credential for the whole
fleet, and revoking one spoke means rotating all of them.

Per-spoke *write* credentials would not need a tenant-mode change — it is one writer
ServiceAccount per spoke, all bound to the same ClusterRole, so revoking a spoke becomes
deleting its binding. The policy would select the right one with the cluster name as the
**key** inside a single Secret:

```yaml
token: '{{hub fromSecret "ai-grid-policies" "usage-logs-spoke-credentials" .ManagedClusterName hub}}'
```

The keyed form matters: ACM restricts hub templates to the policy's own namespace plus the
target's `ManagedCluster` object, so reading a Secret from each cluster's own hub namespace
is not possible by default. It can be unlocked with `spec.hubTemplateOptions.serviceAccountName`
(ACM 2.12 and later), but that ServiceAccount is used for *every* lookup in the policy and
needs `list` and `watch` on what it reads — in practice a ServiceAccount that can read every
Secret on the hub. Not worth it to avoid composing a key name.

It is not implemented because it inverts the operational cost: individually revocable, but N
tokens to mint and rotate, and N independent silent expiries instead of one. It is worth
doing after automated rotation exists, not before.

## Per-spoke read isolation

Read access is a separate problem, and a more expensive one. Every spoke writes to the one
`infrastructure` tenant, so any credential that can read the tenant reads every spoke's usage
data. In `openshift-logging` mode the gateway's OPA arguments are operator-managed, so this
cannot be narrowed by configuration.

Per-spoke isolation needs `spec.tenants.mode: static`, where tenants are declared with their
own OIDC authentication and authorization. That replaces bearer-token-plus-SAR as the auth
mechanism, which changes the ingest contract above for every spoke, and therefore the spoke
policy too. It is a design decision, not a value, which is why this chart does not offer the
mode.

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
