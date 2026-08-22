#!/bin/bash
set -e

# HOME n'est pas toujours positionné selon la méthode d'exécution (ex: SSM
# Run Command, contrairement à une session SSM interactive classique) --
# kubectl résout son kubeconfig via $HOME/.kube/config et se rabat sinon
# silencieusement sur http://localhost:8080 (connection refused en boucle,
# jamais une vraie erreur explicite). aws eks update-kubeconfig n'a pas ce
# problème (résolution via la base utilisateurs système), d'où le piège :
# le fichier est bien écrit dans /root/.kube/config mais kubectl ne le trouve
# pas. On force donc HOME explicitement avant tout appel kubectl/helm.
export HOME=/root

echo "=== Bootstrapping Kubernetes components ==="

# 1. Configurer kubectl
aws eks update-kubeconfig --region ${region} --name ${cluster_name}

# 2. Attendre que le cluster soit prêt
echo "Attente que l'API du cluster soit joignable..."
timeout 300 bash -c 'until kubectl get --raw=/healthz >/dev/null 2>&1; do sleep 5; done'

echo "Attente qu'au moins un noeud soit Ready..."
timeout 300 bash -c 'until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")" -ge 1 ]; do sleep 5; done'

# 2bis. StorageClass par défaut (le pilote est l'addon EKS "aws-ebs-csi-driver",
# géré par Terraform -- ici on ne fait que déclarer la StorageClass qui
# l'utilise et la marquer par défaut). Sans ça, tout PVC sans storageClassName
# explicite -- comme celui de Loki -- reste Pending indéfiniment.
echo "Création de la StorageClass par défaut (gp3, ebs.csi.aws.com)..."
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp3
EOF

# Un PVC déjà créé AVANT qu'une StorageClass par défaut n'existe reste avec
# storageClassName="" figé (jamais réévalué a posteriori) -- on supprime donc
# tout PVC resté bloqué en Pending pour qu'il soit recréé proprement par son
# StatefulSet au prochain sync Argo CD, cette fois avec la classe par défaut.
echo "Nettoyage des PVC restés Pending avant l'installation du pilote EBS CSI..."
kubectl get pvc -A --no-headers 2>/dev/null | awk '$3 == "Pending" {print $1, $2}' | while read -r ns name; do
  echo "  -> suppression de $ns/$name"
  kubectl delete pvc "$name" -n "$ns"
done

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

# Le chart régénère un nouveau certificat/CA auto-signé pour le webhook à
# CHAQUE helm upgrade (pas seulement au premier install). Si le pod existant
# n'est pas redémarré, il continue de servir l'ancien certificat alors que
# le MutatingWebhookConfiguration référence déjà la nouvelle CA -> échec TLS
# "certificate signed by unknown authority" pour toute création de Service
# par la suite (Cluster Autoscaler, etc.). On force donc un restart après
# chaque upgrade pour garantir la cohérence cert/CA, que ce soit un premier
# déploiement ou un re-run.
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
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
# image.tag figé sur la version mineure de Kubernetes du cluster (1.33) --
# le chart installe par défaut la dernière image Cluster Autoscaler (ex:
# 1.35.0, prévue pour k8s 1.35), qui embarque des informers pour les CRD de
# Dynamic Resource Allocation (ResourceClaim/ResourceSlice/DeviceClass).
# Ces CRD n'existent pas sur un cluster 1.33 : WaitForCacheSync() bloque
# indéfiniment en attendant leur synchronisation, et le pod reste
# "Running/Ready" (le probe de santé ne vérifie pas la boucle de scaling)
# sans jamais évaluer le moindre pod pending -- aucun crash, aucun log
# d'erreur visible, juste un scaling qui ne se déclenche jamais.
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set image.tag=v1.33.5 \
  --set fullnameOverride=cluster-autoscaler \
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