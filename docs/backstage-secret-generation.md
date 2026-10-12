# Backstage secret generation (Keycloak client secret + Argo CD token)

Two of Backstage's runtime secrets have **no generator** on the AWS side and would
otherwise be typed in by a human and seeded into `saas/backstage-input`:

- `KEYCLOAK_CLIENT_SECRET` — the OIDC client secret Keycloak issues for the portal.
- `ARGOCD_AUTH_TOKEN` — an Argo CD API token the portal's Argo CD plugin uses.

This feature generates both **in-cluster**, idempotently, as Argo CD `PreSync` hooks, so
nothing has to be hand-seeded and nothing is ever printed or sent to AWS. It is **opt-in**
(`secretGeneration.enabled`, default `false`); until you turn it on, the seeded path is
unchanged.

## How it works

Templates live in [`gitops/infra/backstage/templates/secret-generation.yaml`](../gitops/infra/backstage/templates/secret-generation.yaml);
knobs in `secretGeneration` in [`values.yaml`](../gitops/infra/backstage/values.yaml).

```
PreSync, by sync-wave, before the Backstage Deployment:

 -3  ServiceAccount backstage-bootstrap + least-privilege RBAC:
       • backstage ns : secrets get/create/patch   (write the target Secret)
       • keycloak  ns : get ONLY keycloak-admin-secret
       • argocd    ns : get ONLY argocd-initial-admin-secret
 -2  Job backstage-keycloak-client
       admin-auth → ensure the OIDC client exists (create if missing, idempotent) →
       read its client secret → write KEYCLOAK_CLIENT_SECRET into <targetSecret>
 -1  Job backstage-argocd-token
       admin-auth (REST /session) → mint a token for the `backstage` apiKey account
       (/account/backstage/token) → merge ARGOCD_AUTH_TOKEN into <targetSecret>
  0  Deployment: envFrom <targetSecret> (listed last, so it wins over backstage-app)
```

Both Jobs run `alpine/k8s` (kubectl + curl + jq), talk to Keycloak and Argo CD over their
in-cluster Services, read each admin password with a **single, resource-scoped** `get`, and
never log secret values. The two keys are merged into one Secret across two sync-waves
(wave `-2` creates it, wave `-1` patch-merges), so neither clobbers the other.

## Enabling it (both repos)

1. **Argo CD account** (infra repo, already wired): `modules/k8s-and-helm/argocd-values.yaml`
   defines `accounts.backstage: apiKey` + a read-only RBAC policy. The token Job fails with
   a clear message if this account is missing.
2. **Turn on generation** (this repo): set `secretGeneration.enabled: true` in the backstage
   values for the env, and confirm `keycloak.realm` / `keycloak.clientId` match the infra
   backstage module's `keycloak_realm` / `keycloak_client_id`.
3. **Stop seeding** (infra repo): set `generate_secrets_in_cluster = true` on the `backstage`
   module so `KEYCLOAK_CLIENT_SECRET` and `ARGOCD_AUTH_TOKEN` are omitted from the
   `backstage-app` secret, and drop them from `saas/backstage-input` (leave `GITHUB_TOKEN`).

Order matters only in that the Argo CD `backstage` account (step 1) must exist before the
token Job runs; everything else reconciles idempotently on the next sync.

## What still needs seeding

`GITHUB_TOKEN` has no in-cluster source, so it stays in `saas/backstage-input` (seeded via
the infra repo's `scripts/seed-secrets.sh`). Keycloak and Argo CD **admin** credentials are
assumed already present in-cluster (`keycloak-admin-secret`, `argocd-initial-admin-secret`),
as they are today.

## Trade-offs

- **Pro:** no human-held Argo/Keycloak secrets, no drift, rotation is "re-run the sync".
- **Con:** the Jobs hold (briefly, in memory) the Keycloak and Argo CD **admin** passwords to
  mint scoped credentials. RBAC is tightened to a single named secret per namespace, and the
  Jobs run as non-root with a read-only rootfs and all capabilities dropped.
- The Keycloak Job reads the **existing** client secret when the client already exists (it
  does not rotate on every sync), so portal sessions are not invalidated on resync.
