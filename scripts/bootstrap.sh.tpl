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

echo "Attente que le webhook du AWS Load Balancer Controller soit prêt..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

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
kubectl rollout status deployment/external-secrets-webhook -n external-secrets --timeout=300s
kubectl rollout status deployment/external-secrets-cert-controller -n external-secrets --timeout=300s
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

# 6bis. Installer Cluster Autoscaler
echo "Installation de Cluster Autoscaler..."
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=${cluster_name} \
  --set awsRegion=${region} \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${cluster_autoscaler_role} \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.skip-nodes-with-system-pods=false

echo "Attente de Cluster Autoscaler..."
kubectl rollout status deployment/cluster-autoscaler -n kube-system --timeout=180s

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

# 9. Créer le root-app (pattern "app of apps") : Argo CD synchronise ensuite
#    tout ce qui se trouve dans argocd/applications/ (flask-app, monitoring,
#    yace, et toute future Application ajoutée par un simple commit) --
#    c'est le SEUL apply manuel requis ici, plus jamais un par composant.
echo "Création du root-app (app of apps)..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${gitops_repo_url}
    targetRevision: main
    path: argocd/applications
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
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
echo "Rôle IAM YACE : ${yace_role_arn}"
echo "  -> à coller dans l'annotation eks.amazonaws.com/role-arn de flask-gitops/yace/values.yaml"
echo "Secret Alertmanager/Slack dans Secrets Manager : ${alertmanager_secret_name} (région ${region})"
echo "  -> à référencer via remoteRef.key dans flask-gitops/monitoring/templates/externalsecret-alertmanager-slack.yaml"