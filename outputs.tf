output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "rds_endpoint" {
  value = module.db.db_instance_address
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "app_certificate_arn" {
  value = aws_acm_certificate.app.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "db_credentials_secret_arn" {
  value = aws_secretsmanager_secret.db_credentials.arn
}

output "grafana_admin_secret_name" {
  description = "Nom du secret Secrets Manager -> à référencer dans l'ExternalSecret Grafana (flask-gitops/monitoring)"
  value       = aws_secretsmanager_secret.grafana_admin.name
}

output "bastion_instance_id" {
  description = "Cible pour 'aws ssm start-session --target <id>' (accès admin au cluster privé)"
  value       = aws_instance.bastion.id
}

output "argocd_access_instructions" {
  value = <<-EOT
    Cluster EKS privé — accès admin uniquement via SSM :
      0. (une seule fois) Bootstrap des composants Helm :
         terraform output -raw bootstrap_script > bootstrap.sh
         # puis coller ce script dans la session SSM ci-dessous et l'exécuter : bash bootstrap.sh
      1. aws ssm start-session --target ${aws_instance.bastion.id}
      2. aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}
      3. kubectl port-forward -n argocd svc/argocd-server 8080:443 --address 0.0.0.0
    Depuis le poste local (nouveau terminal) :
      aws ssm start-session --target ${aws_instance.bastion.id} \
        --document-name AWS-StartPortForwardingSession \
        --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
    Puis ouvrir https://localhost:8080
  EOT
}

output "bootstrap_script" {
  description = "Script d'installation des composants Helm (Argo CD, ALB Controller, ExternalDNS, External Secrets). A exécuter manuellement depuis le bastion, jamais depuis un poste local (cluster privé). Récupérer avec : terraform output -raw bootstrap_script > bootstrap.sh"
  value       = local.bootstrap_script
}