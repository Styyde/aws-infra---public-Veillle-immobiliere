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

output "bastion_asg_name" {
  description = "ASG du bastion (1 instance, auto-relancée si elle meurt). Récupérer l'ID de l'instance courante avec la commande de l'output bastion_instance_id_command."
  value       = aws_autoscaling_group.bastion.name
}

output "bastion_instance_id_command" {
  description = "Commande pour récupérer l'ID courant de l'instance bastion (change si l'ASG la relance) -- coller le résultat dans 'aws ssm start-session --target <id>'"
  value       = "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name ${aws_autoscaling_group.bastion.name} --region ${var.aws_region} --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text"
}

output "argocd_access_instructions" {
  value = <<-EOT
    Cluster EKS privé — accès admin uniquement via SSM :
      0. (une seule fois) Bootstrap des composants Helm :
         terraform output -raw bootstrap_script > bootstrap.sh
         # puis coller ce script dans la session SSM ci-dessous et l'exécuter : bash bootstrap.sh
      1. Récupérer l'ID de l'instance bastion courante (le bastion est dans un ASG,
         son ID peut changer s'il a été relancé) :
         terraform output -raw bastion_instance_id_command | bash
      2. aws ssm start-session --target <id obtenu ci-dessus>
      3. aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}
      4. kubectl port-forward -n argocd svc/argocd-server 8080:443 --address 0.0.0.0
    Depuis le poste local (nouveau terminal, avec le même <id>) :
      aws ssm start-session --target <id> \
        --document-name AWS-StartPortForwardingSession \
        --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
    Puis ouvrir https://localhost:8080
  EOT
}

output "yace_role_arn" {
  description = "ARN IAM à coller dans flask-gitops/yace/values.yaml (annotation eks.amazonaws.com/role-arn du ServiceAccount yace)"
  value       = aws_iam_role.yace.arn
}

output "alertmanager_slack_secret_name" {
  description = "Nom du secret Secrets Manager -> à référencer dans l'ExternalSecret Alertmanager (flask-gitops/monitoring)"
  value       = aws_secretsmanager_secret.alertmanager_slack.name
}

output "loki_role_arn" {
  description = "ARN IAM à coller dans flask-gitops/loki/values.yaml (annotation eks.amazonaws.com/role-arn du ServiceAccount loki)"
  value       = aws_iam_role.loki.arn
}

output "loki_logs_bucket_name" {
  description = "Bucket S3 des chunks de logs Loki -> à référencer dans flask-gitops/loki/values.yaml (loki.storage.bucketNames)"
  value       = aws_s3_bucket.loki_logs.id
}

output "bootstrap_script" {
  description = "Script d'installation des composants Helm (Argo CD, ALB Controller, ExternalDNS, External Secrets). A exécuter manuellement depuis le bastion, jamais depuis un poste local (cluster privé). Récupérer avec : terraform output -raw bootstrap_script > bootstrap.sh"
  value       = local.bootstrap_script
}