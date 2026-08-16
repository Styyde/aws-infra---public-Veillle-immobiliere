#!/bin/bash
set -e

echo "=== Bootstrapping Kubernetes components ==="

# 1. Configurer kubectl
aws eks update-kubeconfig --region ${region} --name ${cluster_name}

# 2. Attendre que le cluster soit prêt
echo "Attente que l'API du cluster soit joignable..."
timeout 300 bash -c 'until kubectl get --raw=/healthz >/dev/null 2>&1; do sleep 5; done'

echo "Attente qu'au moins un noeud soit Ready..."
timeout 300 bash -c 'until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")" -ge 1 ]; do sleep 5; done'

# 3. Installer AWS Load Balancer Controller
echo "Installation de AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=${cluster_name} \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${alb_role_arn}

# 4. Installer Metrics Server
echo "Installation de Metrics Server..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls"

# 5. Installer ExternalDNS
echo "Installation d'ExternalDNS..."
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update
helm upgrade --install external-dns external-dns/external-dns \
  --namespace kube-system \
  --set provider=aws \
  --set policy=sync \
  --set registry=txt \
  --set txtOwnerId=${cluster_name} \
  --set domainFilters[0]=kolynois.com \
  --set aws.region=${region} \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-dns \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${external_dns_role}

# 6. Installer External Secrets Operator (Secrets Manager -> Kubernetes Secret)
echo "Installation d'External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-secrets \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${external_secrets_role}

echo "Attente d'External Secrets Operator..."
kubectl rollout status deployment/external-secrets -n external-secrets --timeout=300s
kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=120s
kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=120s

echo "Création du ClusterSecretStore AWS Secrets Manager..."
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${region}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF

# 7. Installer Argo CD
echo "Installation d'Argo CD..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set server.ingress.enabled=false \
  --set configs.repositories[0].url=${gitops_repo_url} \
  --set configs.repositories[0].type=git

# 8. Attendre qu'Argo CD soit prêt
echo "Attente d'Argo CD..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s

# 9. Créer l'Application Flask (avec le domaine)
echo "Création de l'Application Flask..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: flask-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${gitops_repo_url}
    targetRevision: main
    path: apps/flask-app
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# 10. Créer l'Application Monitoring
echo "Création de l'Application Monitoring..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${gitops_repo_url}
    targetRevision: main
    path: monitoring
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo "=== Bootstrap terminé ==="
echo "Argo CD est PRIVÉ (ClusterIP, non exposé sur Internet)."
echo "Accès : kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo "Application URL : https://${domain_name}"
echo "Secret DB dans Secrets Manager : ${db_secret_name} (région ${region})"
echo "  -> à référencer via remoteRef.key dans l'ExternalSecret de flask-gitops/apps/flask-app"
echo "Secret Grafana dans Secrets Manager : ${grafana_secret_name} (région ${region})"
echo "  -> à référencer via remoteRef.key dans flask-gitops/monitoring/templates/externalsecret-grafana.yaml"