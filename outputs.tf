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