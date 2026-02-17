# Platform Engineering Handbook

## 1. Introduction to Platform Engineering

Platform engineering is the discipline of designing and building **toolchains** and **workflows** that enable self-service capabilities for software engineering organizations. A well-designed *internal developer platform* (IDP) reduces cognitive load on development teams and accelerates delivery.

> "The goal of platform engineering is to make the right thing the easy thing."
> — *Gregor Hohpe, Enterprise Integration Patterns*

### 1.1 Core Principles

- **Self-service first**: Developers should be able to provision and manage resources without filing tickets
- **Golden paths**: Provide well-paved roads that teams *can* deviate from but rarely *need* to
- **Automation everywhere**: Manual toil is a bug, not a feature
- **Observability by default**: Every service should be born with metrics, logs, and traces

| Principle | Description | Example |
|-----------|-------------|---------|
| Self-service | Developer autonomy | One-click environment creation |
| Golden paths | Opinionated defaults | Standard service templates |
| Automation | Eliminate toil | Auto-scaling, auto-remediation |
| Observability | Built-in telemetry | OpenTelemetry instrumentation |

### 1.2 Team Topology

The platform team operates as an **enabling team** that builds and maintains the internal developer platform:

1. **Platform Core**: Infrastructure, networking, compute
2. **Developer Experience**: CLI tools, templates, documentation
3. **Observability**: Metrics, logging, tracing pipelines
4. **Security**: IAM, secrets management, compliance

> Platform teams should treat their developers as customers, building products that solve real problems rather than mandating tools from the top down.

### 1.3 Key Metrics

Track these metrics to measure platform effectiveness:

- **Deployment frequency**: How often teams deploy to production
- **Lead time**: Time from commit to production
- **Change failure rate**: Percentage of deployments causing incidents
- **Mean time to recovery** (MTTR): Time to restore service after an incident
- **Developer satisfaction**: Quarterly survey scores (NPS)

| Metric | Target | Current | Status |
|--------|--------|---------|--------|
| Deployment frequency | 10/day | 7/day | Improving |
| Lead time | < 1 hour | 2.5 hours | Needs work |
| Change failure rate | < 5% | 3.2% | On track |
| MTTR | < 30 min | 45 min | Needs work |
| Developer NPS | > 50 | 42 | Improving |

---

## 2. Container Orchestration with Kubernetes

Kubernetes is the *de facto* standard for container orchestration. Understanding its core concepts is essential for any platform engineer.

### 2.1 Pod Specification

A `Pod` is the smallest deployable unit in Kubernetes. Here is a production-ready pod specification:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-server
  labels:
    app: api-server
    version: v2.1.0
    team: payments
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
spec:
  serviceAccountName: api-server-sa
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: api-server
      image: registry.internal/api-server:v2.1.0
      ports:
        - containerPort: 8080
          name: http
        - containerPort: 9090
          name: metrics
      env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: api-server-secrets
              key: database-url
        - name: LOG_LEVEL
          value: "info"
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: "1"
          memory: 1Gi
      livenessProbe:
        httpGet:
          path: /healthz
          port: http
        initialDelaySeconds: 15
        periodSeconds: 20
      readinessProbe:
        httpGet:
          path: /readyz
          port: http
        initialDelaySeconds: 5
        periodSeconds: 10
      volumeMounts:
        - name: config
          mountPath: /etc/config
          readOnly: true
  volumes:
    - name: config
      configMap:
        name: api-server-config
```

### 2.2 Deployment Strategies

The **rolling update** strategy is the default, but for critical services you might want **blue-green** or **canary** deployments:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: production
spec:
  replicas: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
        version: v3.2.1
    spec:
      containers:
        - name: payment-service
          image: registry.internal/payment-service:v3.2.1
          ports:
            - containerPort: 8080
```

> **Best Practice**: Always set `maxUnavailable: 0` for production services to ensure zero-downtime deployments.

### 2.3 Horizontal Pod Autoscaler

The `HorizontalPodAutoscaler` (HPA) adjusts the number of replicas based on observed metrics:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payment-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payment-service
  minReplicas: 3
  maxReplicas: 50
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: requests_per_second
        target:
          type: AverageValue
          averageValue: "1000"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
```

#### Checklist for HPA configuration

- [x] Set appropriate `minReplicas` for baseline load
- [x] Define `maxReplicas` based on cost constraints
- [x] Configure scale-down stabilization to prevent thrashing
- [ ] Add custom metrics from Prometheus adapter
- [ ] Test with load testing tools like `k6` or `locust`

### 2.4 Pod Disruption Budgets

Always define a `PodDisruptionBudget` for production workloads:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payment-service-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: payment-service
```

### 2.5 Resource Quotas

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-payments-quota
  namespace: production
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "100"
    services: "20"
    persistentvolumeclaims: "10"
```

---

## 3. CI/CD Pipeline Architecture

A modern CI/CD pipeline automates the path from code commit to production deployment. The pipeline should be **fast**, **reliable**, and **observable**.

### 3.1 Pipeline Stages

```
[Commit] -> [Build] -> [Unit Test] -> [Integration Test] -> [Security Scan] -> [Deploy Staging] -> [E2E Test] -> [Deploy Production]
```

### 3.2 GitHub Actions Workflow

```yaml
name: deploy-pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
      - run: npm ci
      - run: npm run lint
      - run: npm test -- --coverage
      - uses: actions/upload-artifact@v4
        with:
          name: coverage
          path: coverage/

  security-scan:
    needs: build-and-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          severity: CRITICAL,HIGH

  deploy-staging:
    needs: [build-and-test, security-scan]
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to staging
        run: |
          kubectl config use-context staging
          helm upgrade --install my-app ./charts/my-app             --namespace staging             --set image.tag=${{ github.sha }}             --wait --timeout 5m

  deploy-production:
    needs: deploy-staging
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to production
        run: |
          kubectl config use-context production
          helm upgrade --install my-app ./charts/my-app             --namespace production             --set image.tag=${{ github.sha }}             --wait --timeout 10m
```

### 3.3 Build Optimization

Use **Docker layer caching** and **multi-stage builds** to reduce build times:

```dockerfile
# Stage 1: Build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --production=false
COPY . .
RUN npm run build

# Stage 2: Production
FROM node:20-alpine AS production
WORKDIR /app
RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001
COPY --from=builder --chown=nextjs:nodejs /app/dist ./dist
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./package.json
USER nextjs
EXPOSE 3000
CMD ["node", "dist/main.js"]
```

> **Tip**: Pin your base images to specific digests (e.g., `node:20-alpine@sha256:abc123`) to ensure reproducible builds.

### 3.4 Pipeline Metrics

Track these CI/CD metrics to identify bottlenecks:

| Metric | Description | Target |
|--------|-------------|--------|
| Build time | Time from commit to artifact | < 5 min |
| Test time | Time for all test suites | < 10 min |
| Deployment time | Time from artifact to running | < 3 min |
| Pipeline success rate | % of pipelines that pass | > 95% |
| Rollback frequency | Rollbacks per week | < 1 |

---

## 4. Infrastructure as Code

### 4.1 Terraform Configuration

Terraform enables declarative infrastructure management. Here is a typical **VPC + EKS** setup:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "production-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.0.0"

  cluster_name    = "production"
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = false

  eks_managed_node_groups = {
    general = {
      desired_size = 3
      min_size     = 2
      max_size     = 10
      instance_types = ["m6i.xlarge"]
      capacity_type  = "ON_DEMAND"
    }
    spot = {
      desired_size = 2
      min_size     = 0
      max_size     = 20
      instance_types = ["m6i.xlarge", "m5.xlarge", "m5a.xlarge"]
      capacity_type  = "SPOT"
    }
  }
}
```

### 4.2 Pulumi with TypeScript

For teams that prefer general-purpose languages, [Pulumi](https://www.pulumi.com/) offers infrastructure as *actual* code:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as eks from "@pulumi/eks";

const config = new pulumi.Config();
const minClusterSize = config.getNumber("minClusterSize") || 3;
const maxClusterSize = config.getNumber("maxClusterSize") || 10;
const desiredClusterSize = config.getNumber("desiredClusterSize") || 3;
const eksNodeInstanceType = config.get("eksNodeInstanceType") || "t3.medium";

// Create a VPC for the EKS cluster
const vpc = new aws.ec2.Vpc("platform-vpc", {
  cidrBlock: "10.0.0.0/16",
  enableDnsHostnames: true,
  enableDnsSupport: true,
  tags: {
    Name: "platform-vpc",
    ManagedBy: "pulumi",
  },
});

// Create EKS cluster
const cluster = new eks.Cluster("production-cluster", {
  vpcId: vpc.id,
  instanceType: eksNodeInstanceType,
  desiredCapacity: desiredClusterSize,
  minSize: minClusterSize,
  maxSize: maxClusterSize,
  createOidcProvider: true,
});

// Export the kubeconfig
export const kubeconfig = cluster.kubeconfig;
export const clusterName = cluster.eksCluster.name;
```

#### IaC Comparison

| Feature | Terraform | Pulumi | CDK |
|---------|-----------|--------|-----|
| Language | HCL | Any (TS, Python, Go) | Any (TS, Python, Go, Java) |
| State management | S3/Consul/Cloud | Pulumi Cloud/S3 | CloudFormation |
| Drift detection | `terraform plan` | `pulumi preview` | `cdk diff` |
| Testing | Terratest | Native unit tests | Native unit tests |
| Learning curve | Low | Medium | Medium |

### 4.3 Terraform Best Practices

- [x] Use **remote state** with locking (S3 + DynamoDB)
- [x] Organize by **environment** and **component**
- [x] Use **modules** for reusable infrastructure
- [ ] Implement **policy as code** with Sentinel or OPA
- [ ] Run `terraform plan` in CI for every PR

```bash
# Directory structure
infra/
  modules/
    vpc/
    eks/
    rds/
    monitoring/
  environments/
    production/
      main.tf
      variables.tf
      outputs.tf
      terraform.tfvars
    staging/
      main.tf
      variables.tf
      outputs.tf
      terraform.tfvars
```

---

## 5. Observability Stack

### 5.1 Metrics with Prometheus

Prometheus is the standard for metrics collection in cloud-native environments. Instrument your services with the [OpenTelemetry SDK](https://opentelemetry.io/):

```go
package main

import (
    "net/http"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
    httpRequestsTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )

    httpRequestDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.ExponentialBuckets(0.001, 2, 15),
        },
        []string{"method", "path"},
    )

    activeConnections = prometheus.NewGauge(
        prometheus.GaugeOpts{
            Name: "active_connections",
            Help: "Number of active connections",
        },
    )
)

func init() {
    prometheus.MustRegister(httpRequestsTotal, httpRequestDuration, activeConnections)
}

func instrumentHandler(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        activeConnections.Inc()
        defer activeConnections.Dec()

        recorder := &statusRecorder{ResponseWriter: w, statusCode: 200}
        next.ServeHTTP(recorder, r)

        duration := time.Since(start).Seconds()
        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, http.StatusText(recorder.statusCode)).Inc()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
    })
}

type statusRecorder struct {
    http.ResponseWriter
    statusCode int
}

func (r *statusRecorder) WriteHeader(code int) {
    r.statusCode = code
    r.ResponseWriter.WriteHeader(code)
}

func main() {
    mux := http.NewServeMux()
    mux.Handle("/metrics", promhttp.Handler())
    mux.HandleFunc("/api/v1/orders", handleOrders)
    http.ListenAndServe(":8080", instrumentHandler(mux))
}

func handleOrders(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte(`{"orders": []}`))
}
```

### 5.2 Distributed Tracing

Use **OpenTelemetry** for distributed tracing across microservices:

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

# Configure the tracer
resource = Resource.create({
    "service.name": "payment-service",
    "service.version": "2.1.0",
    "deployment.environment": "production",
})

provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint="http://otel-collector:4317")
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)

async def process_payment(order_id: str, amount: float):
    with tracer.start_as_current_span("process_payment") as span:
        span.set_attribute("order.id", order_id)
        span.set_attribute("payment.amount", amount)

        # Validate payment
        with tracer.start_as_current_span("validate_payment"):
            await validate_card(order_id)

        # Charge payment
        with tracer.start_as_current_span("charge_payment"):
            result = await charge_card(order_id, amount)
            span.set_attribute("payment.status", result.status)

        # Send confirmation
        with tracer.start_as_current_span("send_confirmation"):
            await send_email(order_id, result)

        return result
```

### 5.3 Structured Logging

**Structured logging** with JSON output is essential for log aggregation:

```python
import structlog
import logging

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
)

log = structlog.get_logger()

def handle_request(request):
    log.info(
        "request_received",
        method=request.method,
        path=request.path,
        user_id=request.user_id,
        request_id=request.request_id,
    )
    try:
        result = process(request)
        log.info("request_completed", status="success", duration_ms=result.duration)
        return result
    except Exception as e:
        log.error("request_failed", error=str(e), exc_info=True)
        raise
```

### 5.4 Grafana Dashboard Configuration

```json
{
  "dashboard": {
    "title": "Service Overview",
    "panels": [
      {
        "title": "Request Rate",
        "type": "timeseries",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total[5m])) by (service)",
            "legendFormat": "{{service}}"
          }
        ]
      },
      {
        "title": "P99 Latency",
        "type": "timeseries",
        "targets": [
          {
            "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))",
            "legendFormat": "{{service}}"
          }
        ]
      },
      {
        "title": "Error Rate",
        "type": "stat",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{status=~'5..'}[5m])) / sum(rate(http_requests_total[5m])) * 100"
          }
        ]
      }
    ]
  }
}
```

### 5.5 Alerting Rules

```yaml
groups:
  - name: service-alerts
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
          / sum(rate(http_requests_total[5m])) by (service)
          > 0.01
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate for {{ $labels.service }}"
          description: "Error rate is {{ $value | humanizePercentage }}"

      - alert: HighLatency
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          ) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High P99 latency for {{ $labels.service }}"

      - alert: PodRestartLoop
        expr: |
          increase(kube_pod_container_status_restarts_total[1h]) > 5
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.pod }} is in a restart loop"
```

> **Alert Rule**: Set up alerts for error rate > 1%, p99 latency > 500ms, and pod restart count > 3 in 5 minutes.

---

## 6. Service Mesh and Networking

### 6.1 Istio Configuration

A **service mesh** provides traffic management, security, and observability at the infrastructure layer. [Istio](https://istio.io/) is the most widely adopted service mesh:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-service
  namespace: production
spec:
  hosts:
    - payment-service
  http:
    - match:
        - headers:
            x-canary:
              exact: "true"
      route:
        - destination:
            host: payment-service
            subset: canary
          weight: 100
    - route:
        - destination:
            host: payment-service
            subset: stable
          weight: 95
        - destination:
            host: payment-service
            subset: canary
          weight: 5
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: payment-service
  namespace: production
spec:
  host: payment-service
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        h2UpgradePolicy: DEFAULT
        http1MaxPendingRequests: 1024
        http2MaxRequests: 1024
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: stable
      labels:
        version: v2.0.0
    - name: canary
      labels:
        version: v2.1.0
```

### 6.2 Network Policies

Use `NetworkPolicy` to control pod-to-pod traffic:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-service-netpol
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: payment-service
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api-gateway
        - podSelector:
            matchLabels:
              app: order-service
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

### 6.3 Ingress Controller Configuration

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-ingress
  annotations:
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/rate-limit-window: "1m"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: api-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /api/v1
            pathType: Prefix
            backend:
              service:
                name: api-gateway
                port:
                  number: 8080
```

### 6.4 DNS and Service Discovery

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: production
  labels:
    app: payment-service
spec:
  type: ClusterIP
  selector:
    app: payment-service
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: grpc
      port: 9090
      targetPort: 9090
    - name: metrics
      port: 9091
      targetPort: 9091
```

---

## 7. Database Operations

### 7.1 PostgreSQL Configuration

```sql
-- Create partitioned table for high-volume event data
CREATE TABLE events (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    event_type  TEXT NOT NULL,
    payload     JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id     BIGINT NOT NULL,
    session_id  UUID,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Create monthly partitions
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE events_2024_03 PARTITION OF events
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- Indexes for common query patterns
CREATE INDEX idx_events_user_id ON events (user_id);
CREATE INDEX idx_events_type_created ON events (event_type, created_at DESC);
CREATE INDEX idx_events_payload_gin ON events USING GIN (payload jsonb_path_ops);

-- Useful queries for monitoring
SELECT schemaname, tablename,
       pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
       n_live_tup AS row_count,
       n_dead_tup AS dead_rows,
       last_autovacuum
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 20;
```

### 7.2 Database Migration Strategy

Use a migration tool like **golang-migrate** for version-controlled schema changes:

```bash
#!/bin/bash
# Run database migrations with safety checks

set -euo pipefail

DB_URL="${DATABASE_URL:?DATABASE_URL is required}"
MIGRATIONS_DIR="./migrations"

echo "Running pending migrations..."
migrate -path "$MIGRATIONS_DIR" -database "$DB_URL" up

echo "Verifying migration status..."
migrate -path "$MIGRATIONS_DIR" -database "$DB_URL" version

echo "Running post-migration health check..."
psql "$DB_URL" -c "SELECT count(*) FROM schema_migrations WHERE dirty = false;"
```

Example migration files:

```sql
-- 000001_create_users.up.sql
CREATE TABLE users (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users (email);
```

```sql
-- 000001_create_users.down.sql
DROP TABLE IF EXISTS users;
```

### 7.3 Redis Caching Patterns

```python
import redis
import json
from functools import wraps
from typing import Any, Optional
import hashlib

redis_client = redis.Redis(host="redis", port=6379, db=0, decode_responses=True)

def cache(ttl_seconds: int = 300, prefix: str = "cache"):
    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            key_data = json.dumps({"args": args, "kwargs": kwargs}, sort_keys=True)
            cache_key = f"{prefix}:{func.__name__}:{hashlib.md5(key_data.encode()).hexdigest()}"
            cached = redis_client.get(cache_key)
            if cached is not None:
                return json.loads(cached)
            result = await func(*args, **kwargs)
            redis_client.setex(cache_key, ttl_seconds, json.dumps(result))
            return result
        return wrapper
    return decorator

@cache(ttl_seconds=60, prefix="users")
async def get_user_profile(user_id: int) -> dict:
    return await db.fetch_one("SELECT * FROM users WHERE id = $1", user_id)
```

### 7.4 Connection Pooling with PgBouncer

```ini
; pgbouncer.ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb pool_size=20

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_lifetime = 3600
server_idle_timeout = 600
log_connections = 1
log_disconnections = 1
stats_period = 60
```

---

## 8. Security and Compliance

### 8.1 Secret Management with Vault

[HashiCorp Vault](https://www.vaultproject.io/) provides **dynamic secrets** and **encryption as a service**:

```bash
# Initialize Vault
vault operator init -key-shares=5 -key-threshold=3

# Enable KV secrets engine
vault secrets enable -path=secret kv-v2

# Store a secret
vault kv put secret/production/database   username="app_user"   password="$(openssl rand -base64 32)"   host="db.internal:5432"

# Read a secret
vault kv get -field=password secret/production/database

# Enable dynamic database credentials
vault secrets enable database
vault write database/config/mydb   plugin_name=postgresql-database-plugin   allowed_roles="readonly,readwrite"   connection_url="postgresql://{{username}}:{{password}}@db.internal:5432/mydb"   username="vault_admin"   password="vault_password"

vault write database/roles/readonly   db_name=mydb   creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"   default_ttl="1h"   max_ttl="24h"
```

### 8.2 Kubernetes RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-role
  namespace: staging
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-binding
  namespace: staging
subjects:
  - kind: Group
    name: "developers"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-role
  apiGroup: rbac.authorization.k8s.io
```

### 8.3 OPA (Open Policy Agent) Policies

```rego
package kubernetes.admission

import future.keywords.in

# Deny containers running as root
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not container.securityContext.runAsNonRoot
    msg := sprintf("Container %s must set securityContext.runAsNonRoot to true", [container.name])
}

# Deny images from untrusted registries
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not startswith(container.image, "registry.internal/")
    not startswith(container.image, "gcr.io/my-project/")
    msg := sprintf("Container %s uses untrusted image registry: %s", [container.name, container.image])
}

# Require resource limits
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not container.resources.limits.memory
    msg := sprintf("Container %s must define memory limits", [container.name])
}
```

### 8.4 Security Checklist

- [x] All secrets stored in Vault or Kubernetes Secrets (encrypted at rest)
- [x] RBAC configured with least-privilege principle
- [x] Network policies restrict pod-to-pod communication
- [x] Container images scanned for vulnerabilities in CI
- [ ] Runtime security monitoring with Falco
- [ ] Audit logging enabled for all API server requests
- [ ] Pod Security Standards enforced (restricted profile)
- [ ] mTLS enabled between all services via service mesh

---

## 9. Developer Experience

### 9.1 Service Scaffolding

A good platform provides **service templates** that include all the boilerplate:

```bash
#!/bin/bash
# scaffold-service.sh - Create a new microservice from template

set -euo pipefail

SERVICE_NAME="${1:?Usage: scaffold-service.sh <service-name>}"
TEMPLATE_DIR="$(dirname "$0")/../templates/service"
OUTPUT_DIR="./services/${SERVICE_NAME}"

if [[ -d "$OUTPUT_DIR" ]]; then
  echo "Error: Service directory already exists: ${OUTPUT_DIR}"
  exit 1
fi

echo "Scaffolding new service: ${SERVICE_NAME}"
mkdir -p "$OUTPUT_DIR"

# Copy and template files
for file in $(find "$TEMPLATE_DIR" -type f); do
  relative="${file#$TEMPLATE_DIR/}"
  target="$OUTPUT_DIR/$relative"
  mkdir -p "$(dirname "$target")"
  sed "s/{{SERVICE_NAME}}/${SERVICE_NAME}/g" "$file" > "$target"
done

echo "Service scaffolded at: ${OUTPUT_DIR}"
echo "Next steps:"
echo "  1. cd ${OUTPUT_DIR}"
echo "  2. make dev    # Start local development"
echo "  3. make test   # Run tests"
echo "  4. make deploy # Deploy to staging"
```

### 9.2 Local Development with Tilt

[Tilt](https://tilt.dev/) enables live-reload Kubernetes development:

```python
# Tiltfile

# Build the Docker image
docker_build(
    "registry.internal/payment-service",
    ".",
    dockerfile="Dockerfile.dev",
    live_update=[
        sync("./src", "/app/src"),
        run("npm install", trigger=["package.json", "package-lock.json"]),
    ],
)

# Deploy with Helm
k8s_yaml(helm(
    "./charts/payment-service",
    name="payment-service",
    namespace="dev",
    set=[
        "image.tag=dev",
        "replicaCount=1",
        "resources.requests.cpu=100m",
        "resources.requests.memory=256Mi",
    ],
))

# Port forwarding
k8s_resource("payment-service", port_forwards=[
    "8080:8080",  # API
    "9090:9090",  # Metrics
])
```

### 9.3 Developer Portal with Backstage

Build an internal developer portal with [Backstage](https://backstage.io/):

```yaml
# catalog-info.yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payment-service
  description: Handles payment processing and refunds
  annotations:
    github.com/project-slug: my-org/payment-service
    backstage.io/techdocs-ref: dir:.
    pagerduty.com/service-id: P1234567
    grafana/dashboard-selector: "service=payment"
  tags:
    - python
    - grpc
    - payments
  links:
    - url: https://grafana.internal/d/payment-overview
      title: Grafana Dashboard
      icon: dashboard
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: payment-platform
  dependsOn:
    - component:postgres-cluster
    - component:redis-cache
    - component:notification-service
  providesApis:
    - payment-api
```

### 9.4 Internal CLI Tool

```go
package main

import (
    "fmt"
    "os"
    "os/exec"

    "github.com/spf13/cobra"
)

func main() {
    rootCmd := &cobra.Command{
        Use:   "platform",
        Short: "Internal developer platform CLI",
    }

    rootCmd.AddCommand(
        newServiceCmd(),
        deployCmd(),
        logsCmd(),
        statusCmd(),
    )

    if err := rootCmd.Execute(); err != nil {
        fmt.Fprintln(os.Stderr, err)
        os.Exit(1)
    }
}

func newServiceCmd() *cobra.Command {
    return &cobra.Command{
        Use:   "new [service-name]",
        Short: "Create a new service from template",
        Args:  cobra.ExactArgs(1),
        RunE: func(cmd *cobra.Command, args []string) error {
            name := args[0]
            fmt.Printf("Creating service: %s\n", name)
            return scaffoldService(name)
        },
    }
}

func deployCmd() *cobra.Command {
    var env string
    cmd := &cobra.Command{
        Use:   "deploy",
        Short: "Deploy current service",
        RunE: func(cmd *cobra.Command, args []string) error {
            fmt.Printf("Deploying to %s...\n", env)
            return runHelm(env)
        },
    }
    cmd.Flags().StringVarP(&env, "env", "e", "staging", "Target environment")
    return cmd
}

func logsCmd() *cobra.Command {
    return &cobra.Command{
        Use:   "logs [service-name]",
        Short: "Stream logs from a service",
        Args:  cobra.ExactArgs(1),
        RunE: func(cmd *cobra.Command, args []string) error {
            c := exec.Command("kubectl", "logs", "-f", "-l", "app="+args[0], "-n", "production", "--tail=100")
            c.Stdout = os.Stdout
            c.Stderr = os.Stderr
            return c.Run()
        },
    }
}

func statusCmd() *cobra.Command {
    return &cobra.Command{
        Use:   "status [service-name]",
        Short: "Show service status",
        Args:  cobra.ExactArgs(1),
        RunE: func(cmd *cobra.Command, args []string) error {
            fmt.Printf("Service: %s\n", args[0])
            fmt.Println("Status: Running")
            fmt.Println("Replicas: 3/3")
            fmt.Println("Version: v2.1.0")
            return nil
        },
    }
}

func scaffoldService(name string) error { return nil }
func runHelm(env string) error           { return nil }
```

---

## 10. Cost Optimization

### 10.1 Spot Instance Strategy

Use **spot instances** for fault-tolerant workloads to reduce costs by up to **90%**:

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spot-pool
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m6i.xlarge", "m5.xlarge", "m5a.xlarge", "m5d.xlarge", "c6i.xlarge"]
      nodeClassRef:
        name: default
  limits:
    cpu: "100"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h
```

### 10.2 Resource Right-Sizing

Use the **Vertical Pod Autoscaler** (VPA) in recommendation mode:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: payment-service-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payment-service
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: payment-service
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: "4"
          memory: 8Gi
```

### 10.3 Cost Monitoring

```bash
# Install Kubecost
helm install kubecost cost-analyzer   --repo https://kubecost.github.io/cost-analyzer/   --namespace kubecost   --create-namespace   --set kubecostToken="YOUR_TOKEN"

# Query cost allocation via API
curl -s http://kubecost:9090/model/allocation   -d window=7d   -d aggregate=namespace   | jq '.data[0] | to_entries[] | {namespace: .key, totalCost: .value.totalCost}'
```

| Resource | Monthly Cost | Optimization | Savings |
|----------|-------------|-------------|---------|
| EKS Nodes (on-demand) | $12,000 | Move to spot + reserved | $7,200 |
| RDS PostgreSQL | $4,500 | Right-size instances | $1,200 |
| NAT Gateway | $2,800 | VPC endpoints for S3/DynamoDB | $800 |
| EBS Volumes | $1,500 | Switch gp2 to gp3 | $300 |
| **Total** | **$20,800** | | **$9,500** |

### 10.4 FinOps Practices

- [x] Tag all resources with `team`, `environment`, `service`
- [x] Set up cost alerts at 80% and 100% of budget
- [x] Review unused resources weekly
- [ ] Implement automated resource cleanup for dev environments
- [ ] Reserved Instance/Savings Plan coverage > 60%

---

## 11. Incident Management

### 11.1 Incident Response Runbook

```python
#!/usr/bin/env python3
import datetime
from dataclasses import dataclass
from enum import Enum
from typing import List, Optional

class Severity(Enum):
    SEV1 = "sev1"  # Customer-facing outage
    SEV2 = "sev2"  # Degraded service
    SEV3 = "sev3"  # Internal tooling issue
    SEV4 = "sev4"  # Minor issue, no impact

@dataclass
class Incident:
    id: str
    title: str
    severity: Severity
    description: str
    affected_services: List[str]
    started_at: datetime.datetime
    commander: Optional[str] = None
    status: str = "investigating"

    def escalation_window_minutes(self) -> int:
        return {
            Severity.SEV1: 5,
            Severity.SEV2: 15,
            Severity.SEV3: 60,
            Severity.SEV4: 240,
        }[self.severity]

    def notification_channels(self) -> List[str]:
        base = ["#incidents"]
        if self.severity in (Severity.SEV1, Severity.SEV2):
            base.extend(["#engineering-leads", "pagerduty-oncall"])
        if self.severity == Severity.SEV1:
            base.append("executive-notification")
        return base
```

### 11.2 SLO Definitions

```yaml
# slo-definitions.yaml
slos:
  - name: payment-service-availability
    description: "Payment service should be available 99.95% of the time"
    service: payment-service
    indicator:
      type: availability
      good_events: 'http_requests_total{status!~"5.."}'
      total_events: "http_requests_total"
    objective: 99.95
    window: 30d
    error_budget_policy:
      - consumed_percent: 50
        action: "Review recent deployments, increase monitoring"
      - consumed_percent: 75
        action: "Freeze non-critical deployments"
      - consumed_percent: 90
        action: "All hands on deck, incident commander assigned"
      - consumed_percent: 100
        action: "Full deployment freeze until budget replenished"

  - name: payment-service-latency
    description: "P99 latency should be under 500ms"
    service: payment-service
    indicator:
      type: latency
      threshold_ms: 500
      percentile: 99
      metric: "http_request_duration_seconds"
    objective: 99.9
    window: 30d
```

> **Tip**: Use [Sloth](https://github.com/slok/sloth) to generate Prometheus recording rules and alerts from SLO definitions.

### 11.3 Post-Incident Review Template

```markdown
## Incident Report: INC-20250115-001

**Title**: Payment processing degraded for 23 minutes
**Severity**: SEV2
**Duration**: 14:32 UTC - 14:55 UTC (23 minutes)
**Commander**: @jane-doe
**Services affected**: payment-service, checkout-flow

### Timeline
- 14:32 — Alert fires: payment-service error rate > 5%
- 14:34 — On-call engineer acknowledges, begins investigation
- 14:38 — Root cause identified: database connection pool exhaustion
- 14:42 — Mitigation applied: increased PgBouncer pool size
- 14:48 — Error rate returning to baseline
- 14:55 — All clear declared

### Root Cause
A slow query introduced in deploy v2.3.1 caused connection pool exhaustion.
The query was missing an index on the `orders.user_id` column.

### Action Items
- [ ] Add index on `orders.user_id` (owner: @dev-team)
- [ ] Add query timeout to PgBouncer config (owner: @platform)
- [ ] Set up slow query alerting > 1s (owner: @observability)
```

---

## 12. API Gateway Patterns

### 12.1 Kong Gateway Configuration

```yaml
# Kong declarative configuration
_format_version: "3.0"

services:
  - name: payment-api
    url: http://payment-service.production:8080
    connect_timeout: 5000
    write_timeout: 10000
    read_timeout: 30000
    retries: 3
    routes:
      - name: payment-routes
        paths:
          - /api/v1/payments
        methods:
          - GET
          - POST
          - PUT
        strip_path: false
    plugins:
      - name: rate-limiting
        config:
          minute: 100
          hour: 5000
          policy: redis
          redis_host: redis.infrastructure
      - name: jwt
        config:
          secret_is_base64: false
          claims_to_verify:
            - exp
      - name: request-transformer
        config:
          add:
            headers:
              - "X-Request-ID:$(uuid)"
              - "X-Gateway-Version:v2"

  - name: user-api
    url: http://user-service.production:8080
    routes:
      - name: user-routes
        paths:
          - /api/v1/users
        methods:
          - GET
          - POST
```

### 12.2 GraphQL Federation

For complex API surfaces, use **Apollo Federation** to compose multiple subgraphs:

```typescript
import { ApolloServer } from "@apollo/server";
import { ApolloGateway, IntrospectAndCompose } from "@apollo/gateway";

const gateway = new ApolloGateway({
  supergraphSdl: new IntrospectAndCompose({
    subgraphs: [
      { name: "users", url: "http://user-service:4001/graphql" },
      { name: "payments", url: "http://payment-service:4002/graphql" },
      { name: "orders", url: "http://order-service:4003/graphql" },
      { name: "inventory", url: "http://inventory-service:4004/graphql" },
    ],
  }),
});

const server = new ApolloServer({ gateway });

server.listen({ port: 4000 }).then(({ url }) => {
  console.log(`Gateway ready at ${url}`);
});
```

### 12.3 gRPC Service Definition

```protobuf
syntax = "proto3";

package payment.v1;

option go_package = "github.com/my-org/payment-service/gen/payment/v1";

service PaymentService {
  rpc CreatePayment(CreatePaymentRequest) returns (CreatePaymentResponse);
  rpc GetPayment(GetPaymentRequest) returns (GetPaymentResponse);
  rpc ListPayments(ListPaymentsRequest) returns (ListPaymentsResponse);
  rpc RefundPayment(RefundPaymentRequest) returns (RefundPaymentResponse);
}

message CreatePaymentRequest {
  string order_id = 1;
  int64 amount_cents = 2;
  string currency = 3;
  PaymentMethod method = 4;
}

message CreatePaymentResponse {
  string payment_id = 1;
  PaymentStatus status = 2;
  string created_at = 3;
}

message GetPaymentRequest {
  string payment_id = 1;
}

message GetPaymentResponse {
  Payment payment = 1;
}

message Payment {
  string id = 1;
  string order_id = 2;
  int64 amount_cents = 3;
  string currency = 4;
  PaymentStatus status = 5;
  PaymentMethod method = 6;
  string created_at = 7;
  string updated_at = 8;
}

enum PaymentStatus {
  PAYMENT_STATUS_UNSPECIFIED = 0;
  PAYMENT_STATUS_PENDING = 1;
  PAYMENT_STATUS_COMPLETED = 2;
  PAYMENT_STATUS_FAILED = 3;
  PAYMENT_STATUS_REFUNDED = 4;
}

enum PaymentMethod {
  PAYMENT_METHOD_UNSPECIFIED = 0;
  PAYMENT_METHOD_CREDIT_CARD = 1;
  PAYMENT_METHOD_DEBIT_CARD = 2;
  PAYMENT_METHOD_BANK_TRANSFER = 3;
  PAYMENT_METHOD_WALLET = 4;
}

message ListPaymentsRequest {
  string order_id = 1;
  int32 page_size = 2;
  string page_token = 3;
}

message ListPaymentsResponse {
  repeated Payment payments = 1;
  string next_page_token = 2;
}

message RefundPaymentRequest {
  string payment_id = 1;
  int64 amount_cents = 2;
  string reason = 3;
}

message RefundPaymentResponse {
  string refund_id = 1;
  PaymentStatus status = 2;
}
```

---

## 13. Message Queue Architecture

### 13.1 Apache Kafka Configuration

```yaml
# kafka-cluster.yaml (Strimzi operator)
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: production-kafka
  namespace: messaging
spec:
  kafka:
    version: 3.7.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
      log.retention.hours: 168
      log.segment.bytes: 1073741824
      num.partitions: 12
    storage:
      type: jbod
      volumes:
        - id: 0
          type: persistent-claim
          size: 500Gi
          class: gp3
    resources:
      requests:
        memory: 4Gi
        cpu: "2"
      limits:
        memory: 8Gi
        cpu: "4"
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 50Gi
      class: gp3
```

### 13.2 Event-Driven Architecture with Kafka

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/segmentio/kafka-go"
)

type OrderEvent struct {
    EventID   string    `json:"event_id"`
    EventType string    `json:"event_type"`
    OrderID   string    `json:"order_id"`
    UserID    string    `json:"user_id"`
    Amount    float64   `json:"amount"`
    Timestamp time.Time `json:"timestamp"`
}

func main() {
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
    go func() {
        <-sigCh
        log.Println("Shutting down gracefully...")
        cancel()
    }()

    reader := kafka.NewReader(kafka.ReaderConfig{
        Brokers:        []string{"kafka-0:9092", "kafka-1:9092", "kafka-2:9092"},
        Topic:          "order-events",
        GroupID:         "payment-processor",
        MinBytes:        1e3,
        MaxBytes:        10e6,
        MaxWait:         500 * time.Millisecond,
        CommitInterval:  time.Second,
        StartOffset:     kafka.LastOffset,
    })
    defer reader.Close()

    log.Println("Starting order event consumer...")
    for {
        msg, err := reader.ReadMessage(ctx)
        if err != nil {
            if ctx.Err() != nil {
                break
            }
            log.Printf("Error reading message: %v", err)
            continue
        }

        var event OrderEvent
        if err := json.Unmarshal(msg.Value, &event); err != nil {
            log.Printf("Error unmarshaling event: %v", err)
            continue
        }

        if err := processOrderEvent(ctx, event); err != nil {
            log.Printf("Error processing event %s: %v", event.EventID, err)
        }
    }
}

func processOrderEvent(ctx context.Context, event OrderEvent) error {
    switch event.EventType {
    case "order.created":
        return handleOrderCreated(ctx, event)
    case "order.paid":
        return handleOrderPaid(ctx, event)
    case "order.cancelled":
        return handleOrderCancelled(ctx, event)
    default:
        return fmt.Errorf("unknown event type: %s", event.EventType)
    }
}

func handleOrderCreated(ctx context.Context, event OrderEvent) error {
    log.Printf("Processing order created: %s (amount: %.2f)", event.OrderID, event.Amount)
    return nil
}

func handleOrderPaid(ctx context.Context, event OrderEvent) error {
    log.Printf("Processing order paid: %s", event.OrderID)
    return nil
}

func handleOrderCancelled(ctx context.Context, event OrderEvent) error {
    log.Printf("Processing order cancelled: %s", event.OrderID)
    return nil
}
```

### 13.3 Dead Letter Queue Pattern

```python
import json
import logging
from dataclasses import dataclass, asdict
from datetime import datetime
from typing import Any, Dict

logger = logging.getLogger(__name__)

@dataclass
class DeadLetterEntry:
    original_topic: str
    original_partition: int
    original_offset: int
    error_message: str
    retry_count: int
    payload: Dict[str, Any]
    failed_at: str
    processor: str

class DeadLetterHandler:
    MAX_RETRIES = 3
    DLQ_TOPIC = "dead-letter-queue"

    def __init__(self, producer):
        self.producer = producer

    def handle_failure(
        self,
        topic: str,
        partition: int,
        offset: int,
        payload: dict,
        error: Exception,
        processor: str,
        retry_count: int = 0,
    ) -> None:
        if retry_count < self.MAX_RETRIES:
            logger.warning(
                "Retrying message",
                extra={
                    "topic": topic,
                    "offset": offset,
                    "retry": retry_count + 1,
                    "error": str(error),
                },
            )
            return

        entry = DeadLetterEntry(
            original_topic=topic,
            original_partition=partition,
            original_offset=offset,
            error_message=str(error),
            retry_count=retry_count,
            payload=payload,
            failed_at=datetime.utcnow().isoformat(),
            processor=processor,
        )

        logger.error(
            "Message moved to DLQ",
            extra={"topic": topic, "offset": offset, "error": str(error)},
        )

        self.producer.send(
            self.DLQ_TOPIC,
            key=f"{topic}-{partition}-{offset}".encode(),
            value=json.dumps(asdict(entry)).encode(),
        )
```

---

## 14. Platform Maturity Model

### 14.1 Maturity Levels

| Level | Name | Description | Key Capabilities |
|-------|------|-------------|-----------------|
| 1 | **Ad-hoc** | Manual processes, tribal knowledge | Docs, shared runbooks |
| 2 | **Managed** | Some automation, basic CI/CD | CI pipelines, container builds |
| 3 | **Defined** | Standardized workflows, IDP | Service templates, GitOps |
| 4 | **Measured** | SLOs, cost tracking, metrics | SLO dashboards, cost reports |
| 5 | **Optimizing** | Self-healing, auto-remediation | Auto-scaling, chaos engineering |

### 14.2 Assessment Checklist

#### Infrastructure

- [x] All infrastructure defined as code (Terraform/Pulumi)
- [x] State files stored remotely with locking
- [x] Environments (dev, staging, prod) are consistent
- [ ] Drift detection runs on schedule
- [ ] Infrastructure changes require PR review

#### Deployment

- [x] CI/CD pipeline for all services
- [x] Automated testing in pipeline
- [x] Rollback capability for all deployments
- [ ] Canary deployments for critical services
- [ ] Feature flags for progressive rollout

#### Observability

- [x] Metrics collection (Prometheus/Datadog)
- [x] Centralized logging (ELK/Loki)
- [x] Distributed tracing (Jaeger/Tempo)
- [ ] SLO-based alerting
- [ ] Anomaly detection

#### Security

- [x] Secret management (Vault/AWS Secrets Manager)
- [x] Container image scanning
- [x] Network policies
- [ ] Runtime security monitoring
- [ ] Automated compliance checks

---

## 15. Chaos Engineering

### 15.1 Litmus Chaos Experiments

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: payment-chaos
  namespace: production
spec:
  appinfo:
    appns: production
    applabel: app=payment-service
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"
            - name: CHAOS_INTERVAL
              value: "10"
            - name: FORCE
              value: "false"
    - name: pod-network-latency
      spec:
        components:
          env:
            - name: NETWORK_INTERFACE
              value: eth0
            - name: NETWORK_LATENCY
              value: "200"
            - name: TOTAL_CHAOS_DURATION
              value: "60"
```

### 15.2 Chaos Testing Strategy

> **Principle**: Start with the *smallest blast radius* and expand as confidence grows.

1. **Unit chaos**: Kill individual pods, verify self-healing
2. **Service chaos**: Add network latency between services, verify timeout handling
3. **Zone chaos**: Simulate AZ failure, verify multi-AZ resilience
4. **Region chaos**: Test cross-region failover procedures

```bash
# Gameday script
#!/bin/bash
set -euo pipefail

echo "=== Chaos Gameday: Payment Service Resilience ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "1. Verifying baseline..."
kubectl get pods -n production -l app=payment-service
echo ""

echo "2. Recording baseline metrics..."
BASELINE_P99=$(curl -s 'http://prometheus:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket{service="payment"}[5m]))' | jq -r '.data.result[0].value[1]')
echo "   Baseline P99: ${BASELINE_P99}s"
echo ""

echo "3. Injecting chaos: killing 1 pod..."
kubectl delete pod -n production -l app=payment-service --field-selector=status.phase=Running --wait=false | head -1
echo ""

echo "4. Waiting 30s for recovery..."
sleep 30

echo "5. Checking recovery..."
kubectl get pods -n production -l app=payment-service
echo ""

echo "=== Gameday Complete ==="
```

---

## 16. GitOps with ArgoCD

### 16.1 Application Definition

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: production
  source:
    repoURL: https://github.com/my-org/k8s-manifests.git
    targetRevision: HEAD
    path: services/payment-service/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### 16.2 Kustomize Overlays

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
  - pdb.yaml
commonLabels:
  app: payment-service
  managed-by: kustomize
```

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
  - ../../base
namePrefix: prod-
patches:
  - target:
      kind: Deployment
    patch: |
      - op: replace
        path: /spec/replicas
        value: 5
  - target:
      kind: HorizontalPodAutoscaler
    patch: |
      - op: replace
        path: /spec/minReplicas
        value: 5
      - op: replace
        path: /spec/maxReplicas
        value: 50
```

---

## Appendix A: Useful Commands Reference

```bash
# Kubernetes debugging
kubectl get events --sort-by=.metadata.creationTimestamp -n production
kubectl top pods -n production --sort-by=memory
kubectl describe pod <pod-name> -n production | grep -A 5 "Events:"
kubectl logs -f deployment/payment-service -n production --tail=100

# Helm operations
helm list -A
helm history payment-service -n production
helm rollback payment-service 3 -n production

# Network debugging
kubectl run debug --image=nicolaka/netshoot --rm -it -- bash
nslookup payment-service.production.svc.cluster.local
curl -v http://payment-service.production:8080/healthz

# Resource usage
kubectl resource-quota -n production
kubectl get limitrange -n production -o yaml
```

## Appendix B: Glossary

| Term | Definition |
|------|-----------|
| **IDP** | Internal Developer Platform |
| **SLO** | Service Level Objective |
| **SLI** | Service Level Indicator |
| **SLA** | Service Level Agreement |
| **MTTR** | Mean Time to Recovery |
| **MTTD** | Mean Time to Detect |
| **HPA** | Horizontal Pod Autoscaler |
| **VPA** | Vertical Pod Autoscaler |
| **PDB** | Pod Disruption Budget |
| **CRD** | Custom Resource Definition |
| **OPA** | Open Policy Agent |
| **mTLS** | Mutual Transport Layer Security |
| **DLQ** | Dead Letter Queue |
| **GitOps** | Git as single source of truth for declarative infrastructure |
| **IaC** | Infrastructure as Code |

---

*This handbook is maintained by the **Platform Engineering Team**. For questions or contributions, see [our wiki](https://wiki.internal/platform) or join `#platform-engineering` on Slack.*

> **Last updated**: 2025-01-15 | **Version**: 3.2.0 | **Owner**: Platform Team
