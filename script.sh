#!/usr/bin/env bash
set -euo pipefail

# Ensure directory structure exists
mkdir -p bootstrap
mkdir -p apps/payment-api/base
mkdir -p apps/payment-api/overlays/dev
mkdir -p apps/payment-api/overlays/prod/patches
mkdir -p apps/shopping-cart/templates
mkdir -p apps/shopping-cart/kustomize-wrapper

# ==============================================================================
# 1. BOOTSTRAP: Root App & ApplicationSet (Targeting name: aws-eks-prod)
# ==============================================================================

cat <<'EOF' > root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-application
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/aboroufar/app-of-app-gitops-workloads.git
    targetRevision: main
    path: bootstrap
  destination:
    name: aws-eks-prod
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF

cat <<'EOF' > bootstrap/payment-api-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payment-api-workloads
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            namespace: payment-dev
          - env: prod
            namespace: payment-prod
  template:
    metadata:
      name: 'payment-api-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/aboroufar/app-of-app-gitops-workloads.git
        targetRevision: main
        path: 'apps/payment-api/overlays/{{env}}'
      destination:
        name: aws-eks-prod
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true
          - RespectIgnoreDifferences=true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
EOF

cat <<'EOF' > bootstrap/shopping-cart-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shopping-cart-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/aboroufar/app-of-app-gitops-workloads.git
    targetRevision: main
    path: apps/shopping-cart/kustomize-wrapper
  destination:
    name: aws-eks-prod
    namespace: shopping-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# ==============================================================================
# 2. PAYMENT-API WORKLOAD (Kustomize, PreSync Hook, Sync Waves, Public Images)
# ==============================================================================

cat <<'EOF' > apps/payment-api/base/db-migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: payment-db-migration
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "1"
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: public.ecr.aws/docker/library/busybox:latest
          command:
            - "sh"
            - "-c"
            - "echo 'Running database migrations...'; sleep 4; echo 'Migrations successful!'"
EOF

cat <<'EOF' > apps/payment-api/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/sync-options: Prune=false
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      containers:
        - name: web
          image: app-image
          ports:
            - containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 150m
              memory: 128Mi
EOF

cat <<'EOF' > apps/payment-api/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-api
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: payment-api
EOF

cat <<'EOF' > apps/payment-api/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - db-migration-job.yaml
  - deployment.yaml
  - service.yaml

images:
  - name: app-image
    newName: nginxinc/nginx-unprivileged
    newTag: 1.27-alpine
EOF

cat <<'EOF' > apps/payment-api/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

namePrefix: dev-
commonLabels:
  environment: dev
EOF

cat <<'EOF' > apps/payment-api/overlays/prod/patches/replica-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
spec:
  replicas: 3
EOF

cat <<'EOF' > apps/payment-api/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

namePrefix: prod-
commonLabels:
  environment: prod

patches:
  - path: patches/replica-patch.yaml
EOF

# ==============================================================================
# 3. SHOPPING-CART WORKLOAD (Helm Chart + Kustomize Wrapper)
# ==============================================================================

cat <<'EOF' > apps/shopping-cart/Chart.yaml
apiVersion: v2
name: shopping-cart
description: Helm chart for shopping cart service
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

cat <<'EOF' > apps/shopping-cart/values.yaml
replicaCount: 1
image:
  repository: nginxinc/nginx-unprivileged
  tag: 1.27-alpine
  pullPolicy: IfNotPresent
service:
  type: ClusterIP
  port: 80
  targetPort: 8080
EOF

cat <<'EOF' > apps/shopping-cart/values-prod.yaml
replicaCount: 2
service:
  type: LoadBalancer
  port: 80
  targetPort: 8080
EOF

cat <<'EOF' > apps/shopping-cart/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}
EOF

cat <<'EOF' > apps/shopping-cart/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
      name: http
  selector:
    app: {{ .Release.Name }}
EOF

cat <<'EOF' > apps/shopping-cart/kustomize-wrapper/ingress-patch.yaml
apiVersion: v1
kind: Service
metadata:
  name: shopping-cart
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
EOF

cat <<'EOF' > apps/shopping-cart/kustomize-wrapper/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: shopping-cart
    repo: ../
    releaseName: shopping-cart
    namespace: shopping-prod
    valuesFile: ../values-prod.yaml

patches:
  - path: ingress-patch.yaml
    target:
      kind: Service
      name: shopping-cart
EOF

echo "Script complete! All targets updated to 'name: aws-eks-prod'."