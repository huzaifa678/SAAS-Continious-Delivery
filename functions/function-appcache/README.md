# function-appcache

A Crossplane composition function for the `platform.saas.example` **XAppCache**
API. It is the code form of what used to be `function-patch-and-transform` YAML:
a single function that branches on the claim's `mode`.

- **shared** — composes one provider-aws `elasticache.User` (IAM auth) scoped to
  `~<keyPrefix>:*`, labelled `platform.saas.example/redis-tenant-group` so the
  platform user group (`platform/appcache/redis-tenant-usergroup.yaml`) adds it
  to the shared cluster. No new cluster.
- **dedicated** — composes the service's own `elasticache.ReplicationGroup`
  (cluster-mode capable via `numShards`), encrypted in transit + at rest, with a
  private RBAC user group (disabled `default` + app user bound by
  `matchControllerRef`).

The connection secret carries `username` + `prefix` (both modes) and
`host` + `port` (dedicated only — the shared cluster's host comes from the
gitops-contract redis secret).

## Input

| field | default | meaning |
|-------|---------|---------|
| `providerConfigName` | `aws-elasticache` | ProviderConfig every composed MR references |
| `defaultUserGroupId` | `saas-redis` | shared user group joined when the claim omits `userGroupId` |

## Develop

```
make test    # go vet + go test
make image   # build the runtime container
make xpkg    # build the Crossplane package (needs the crossplane CLI)
```

CI builds and pushes the package (see `.github/workflows/build-function.yml`);
`platform/functions/functions.yaml` pins the pushed image.
