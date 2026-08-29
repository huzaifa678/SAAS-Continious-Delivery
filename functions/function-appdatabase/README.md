# function-appdatabase

A [Crossplane composition function][functions] (Go, [function-sdk-go]) that
composes a **Postgres database** for the `platform.saas.example` `XAppDatabase`
API (see `platform/xrds/appdatabase.yaml`).

It is the *code* form of what used to be the `function-patch-and-transform`
YAML in `platform/compositions/appdatabase-postgres.yaml`. The composition is
now a single static pipeline step that references this function's image; the
generator (`scripts/gen/appdatabase-composition`) emits that pipeline.

## What it composes

From one `AppDatabase` claim (`spec.parameters.{databaseName, owner, instance,
extensions[]}`) it emits [provider-sql][provider-sql] resources:

| Resource | Purpose |
|---|---|
| `Role` | the owning Postgres role (login), writes its connection secret |
| `Database` | the database, owned by the role |
| `Grant` | `ALL` privileges on the database to the role |
| `Extension` (0..n) | one per `spec.parameters.extensions` entry |

Each resource is wired to the ProviderConfig `rds-<instance>` (from the input's
`providerConfigFormat`). The Role's `username` / `password` / `endpoint` (as
`host`) plus the `database` name are surfaced on the composite so they flow into
the claim's connection secret. `function-auto-ready` (pipeline step 2) derives
readiness.

**Beyond the old YAML:** the previous `function-patch-and-transform` composition
ignored `spec.parameters.extensions`. This function honours it, composing an
`Extension` per requested extension.

## Build

```bash
make test     # go vet + unit tests
make xpkg     # runtime image + Crossplane .xpkg (needs docker + crossplane CLI)
```

CI builds and pushes it to ECR as `function-appdatabase` — see
`.github/workflows/build-function.yml` (`build-runtime` -> `package`). The
`package` step wraps the runtime image into a `.xpkg` via
`crossplane xpkg build --embed-runtime-image` and pushes `function-appdatabase:sha-<commit>`.
`platform/functions/functions.yaml` installs that tag as a `Function`.

## Input

The composition passes an `Input` (`appdatabase.fn.saas.example/v1beta1`); every
field has a default so the composition stays minimal:

| Field | Default | Meaning |
|---|---|---|
| `providerConfigFormat` | `rds-%s` | `fmt` mapping the claim's `instance` to a ProviderConfig name |
| `connectionSecretNamespace` | `crossplane-system` | where the Role writes its connection secret |

## Layout

```
functions/function-appdatabase/
├── main.go                    # kong CLI + function.Serve (gRPC :9443)
├── fn.go                      # RunFunction: composes Role/Database/Grant/Extension
├── fn_test.go                 # unit tests (structpb request fixtures)
├── input/v1beta1/             # Input type + hand-written deepcopy
├── package/
│   ├── crossplane.yaml        # meta.pkg.crossplane.io Function metadata
│   └── input/…                # Input CRD (shipped in the package)
├── Dockerfile                 # multi-stage: go test -> distroless runtime
├── Makefile                   # local build helpers
└── go.mod / go.sum            # pinned; go.sum committed
```

[functions]: https://docs.crossplane.io/latest/concepts/compositions/#composition-functions
[function-sdk-go]: https://github.com/crossplane/function-sdk-go
[provider-sql]: https://github.com/crossplane-contrib/provider-sql
