# SaaS Continuous Delivery

![Status: In Development](https://img.shields.io/badge/status-in%20development-yellow)
![Kubernetes](https://img.shields.io/badge/kubernetes-1.28+-blue)
![Helm](https://img.shields.io/badge/helm-3.14+-blue)
![License](https://img.shields.io/badge/license-MIT-green)

GitOps-based continuous delivery repository for the SaaS platform. Contains a **Helm chart** (`saas-chart`) that packages all platform services and infrastructure, and **ArgoCD Application manifests** (Kustomize overlays) for deploying to multiple environments.

## What's Deployed

| Component | Type | Description |
|---|---|---|
| api-gateway | Service | Go API gateway (port 9000) |
| auth-service | Service | Authentication service (port 8080) |
| subscription-service | Service | NestJS subscription management (port 8081) |
| billing-service | Service | Spring Boot billing & payments (port 8082) |
| usage-service | Service | Python usage analytics (port 8083) |
| Keycloak | Identity | OIDC provider for JWT issuance |
| Apache Airflow | Orchestration | Usage data pipeline scheduler |
| OpenTelemetry Collector | Observability | Telemetry aggregation (DaemonSet) |
| Grafana + Loki + Tempo + Prometheus | Observability | Metrics, logs, and traces stack |
| Istio | Service Mesh | mTLS, traffic management, sidecar injection |

## Repository Structure

```
saas-continious-delivery/
├── saas-chart/                          # Helm chart for all platform services
│   ├── Chart.yaml                       # Chart metadata + dependencies
│   ├── Chart.lock                       # Locked dependency versions
│   ├── charts/
│   │   └── opentelemetry-collector-0.100.0.tgz  # Bundled OTel Collector chart
│   ├── templates/
│   │   ├── api-gateway.yaml             # API Gateway Deployment + Service
│   │   ├── subscription-service.yaml    # Subscription Service Deployment + Service
│   │   ├── billing-service.yaml         # Billing Service Deployment + Service
│   │   ├── usage-service.yaml           # Usage Service Deployment + Service
│   │   ├── auth-service.yaml            # Auth Service Deployment + Service
│   │   ├── gateway.yaml                 # Istio Gateway resource
│   │   ├── gateway-http.yaml            # HTTP Gateway route
│   │   ├── peer-authentication.yaml     # Istio mTLS PeerAuthentication
│   │   ├── service.yaml                 # Shared service definitions
│   │   ├── deployment.yaml              # Generic deployment template
│   │   ├── _helpers.tpl                 # Helm template helpers
│   │   └── tests/
│   │       └── api-gateway-test.yaml    # Helm test for API Gateway
│   ├── gateway-api-crds.yaml            # Kubernetes Gateway API CRDs
│   ├── values.yaml                      # Default values
│   ├── values-dev.yaml                  # Dev environment overrides
│   ├── values-test.yaml                 # Test environment overrides
│   ├── values-staging.yaml              # Staging environment overrides
│   └── values-prod.yaml                 # Production environment overrides
└── manifests/
    └── base/
        └── overlays/
            ├── dev/                     # Dev ArgoCD Applications + infra
            │   ├── application/
            │   │   └── applications.yaml    # ArgoCD Application resources
            │   ├── airflow/                 # Airflow Helm release + deployment
            │   ├── keycloak/                # Keycloak deployment + service
            │   ├── observability/
            │   │   └── grafana-stack/       # Prometheus + Loki ArgoCD apps
            │   ├── root.yaml                # ArgoCD App-of-Apps root
            │   └── kustomization.yaml
            ├── staging/                 # Staging overlays
            └── prod/                    # Production overlays
```

## Environments

| Environment | Values File | Observability Backend | Notes |
|---|---|---|---|
| `dev` | `values-dev.yaml` | Loki + Tempo + Prometheus (Grafana) | Debug verbosity, OTel debug exporter |
| `test` | `values-test.yaml` | — | Minimal config for CI |
| `staging` | `values-staging.yaml` | Elastic APM + Elasticsearch + Logstash | Full ELK stack |
| `prod` | `values-prod.yaml` | Configurable | TLS enabled, higher replicas |

## Prerequisites

- Kubernetes cluster (1.28+)
- Helm 3.14+
- ArgoCD installed in the cluster
- `kubectl` configured for your cluster
- Istio installed (if `istio.enabled: true`)

## Helm Chart Usage

### Install / Upgrade

```bash
# Add OTel Helm repo (for dependency)
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Update chart dependencies
helm dependency update saas-chart/

# Install to dev namespace
helm upgrade --install saas saas-chart/ \
  -f saas-chart/values-dev.yaml \
  --namespace saas-dev \
  --create-namespace \
  --set image.apiGateway=ghcr.io/your-org/api-gateway:latest \
  --set image.subscriptionService=ghcr.io/your-org/subscription-service:latest \
  --set image.billingService=ghcr.io/your-org/billing-service:latest \
  --set image.usageService=ghcr.io/your-org/usage-service:latest \
  --set image.authService=ghcr.io/your-org/auth-service:latest

# Install Gateway API CRDs (first time only)
kubectl apply -f saas-chart/gateway-api-crds.yaml
```

### Dry Run / Template

```bash
# Preview rendered manifests
helm template saas saas-chart/ -f saas-chart/values-dev.yaml

# Dry run
helm upgrade --install saas saas-chart/ \
  -f saas-chart/values-dev.yaml \
  --dry-run
```

### Run Helm Tests

```bash
helm test saas --namespace saas-dev
```

## ArgoCD GitOps Setup

The `manifests/` directory uses an **App-of-Apps** pattern. A root ArgoCD Application points to `manifests/base/overlays/<env>/root.yaml`, which bootstraps all child applications.

### Bootstrap Dev Environment

```bash
# Apply the root ArgoCD application
kubectl apply -f manifests/base/overlays/dev/root.yaml -n argocd
```

ArgoCD will then automatically sync:
- The `saas-chart` Helm release
- Keycloak
- Airflow
- Grafana stack (Prometheus + Loki)

### Sync Manually

```bash
argocd app sync saas-dev
argocd app sync airflow-dev
argocd app sync keycloak-dev
```

## Key Configuration Values

### Service Images

```yaml
image:
  apiGateway: ""           # Docker image for api-gateway
  authService: ""          # Docker image for auth-service
  subscriptionService: ""  # Docker image for subscription-service
  billingService: ""       # Docker image for billing-service
  usageService: ""         # Docker image for usage-service
```

### Replicas & Ports

```yaml
apiGateway:
  replicas: 2
  port: 9000

services:
  subscription:
    replicas: 2
    port: 8081
  billing:
    replicas: 2
    port: 8082
  usage:
    replicas: 2
    port: 8083
```

### Istio

```yaml
istio:
  enabled: true
  revision: ""   # Set to Istio revision label if using canary upgrades
```

When enabled, all service pods get `sidecar.istio.io/inject: "true"` annotations and a `PeerAuthentication` resource enforces mTLS across the mesh.

### OpenTelemetry Collector

The bundled OTel Collector runs as a **DaemonSet** and is configured per environment:

- **Dev/Test**: exports traces to Tempo, logs to Loki, metrics to Prometheus
- **Staging**: exports traces to Elastic APM, logs to Elasticsearch + Logstash, metrics to Prometheus

```yaml
opentelemetry-collector:
  enabled: true
  mode: daemonset
```

## Service Communication

```
External Traffic
      │
      ▼
Istio Gateway (nginx GatewayClass)
      │
      ▼
api-gateway (ClusterIP: saas-api-service)
      │
      ├── /api/auth/         → auth-service:8080
      ├── /api/subscription/ → subscription-service:8081
      └── /api/billing/      → billing-service:8082

subscription-service:50051 ←── billing-service (gRPC)
```

## Updating a Service

1. Build and push a new Docker image with a new tag
2. Update the image tag in the relevant `values-<env>.yaml`
3. Commit and push — ArgoCD will detect the change and sync automatically

Or trigger a manual image update:

```bash
helm upgrade saas saas-chart/ \
  -f saas-chart/values-dev.yaml \
  --set image.billingService=ghcr.io/your-org/billing-service:v1.2.3 \
  --namespace saas-dev
```

## License

MIT
