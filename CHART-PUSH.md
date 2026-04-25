# Helm Chart → ECR Push Workflow

## One-time setup

```bash
# Authenticate Helm to ECR (run before any push)
aws ecr get-login-password --region us-east-1 \
  | helm registry login \
      --username AWS \
      --password-stdin \
      <ECR-REGISTRY-ENDPOINT>
```

## Push a microservice chart

```bash
CHART=auth-service   # auth-service | billing-service | subscription-service | usage-service
VERSION=0.1.0        # must match Chart.yaml version
ACCOUNT=123456789
REGION=us-east-1

# 1. Bump version in charts/$CHART/Chart.yaml, then:
helm package charts/$CHART --destination /tmp/helm-packages

# 2. Push to ECR
helm push /tmp/helm-packages/${CHART}-${VERSION}.tgz \
  oci://${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/helm
```

## Promote a new version in ArgoCD

In the relevant `manifests/base/overlays/<env>/application/applications.yaml`,
update `targetRevision` for the chart:

```yaml
- repoURL: oci://123456789.dkr.ecr.us-east-1.amazonaws.com/helm
  chart: auth-service
  targetRevision: 0.2.0   # <-- bump here
```

Commit and push — ArgoCD auto-syncs.

## CI/CD integration (GitHub Actions snippet)

```yaml
- name: Push Helm chart to ECR
  run: |
    aws ecr get-login-password --region $AWS_REGION \
      | helm registry login --username AWS --password-stdin \
          $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
    helm package charts/${{ env.CHART }} --destination /tmp/pkg
    helm push /tmp/pkg/${{ env.CHART }}-${{ env.VERSION }}.tgz \
      oci://$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/helm
```
