variable "aws_region" {
  description = "Région AWS"
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Nom du projet"
  type        = string
  default     = "veille-immo"
}

variable "environment" {
  description = "Environnement (prod, staging)"
  type        = string
  default     = "prod"
}

# ---- Networking ----
variable "vpc_cidr" {
  description = "CIDR du VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Zones de disponibilité (minimum 2 pour HA)"
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs pour les sous-réseaux privés"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs pour les sous-réseaux publics"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ---- EKS ----
variable "kubernetes_version" {
  description = "Version de Kubernetes"
  type        = string
  default     = "1.33"
}

variable "node_instance_types" {
  description = "Type d'instance pour les nodes EKS"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Nombre minimal de nodes (HA = 2)"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Nombre maximal de nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Nombre souhaité de nodes"
  type        = number
  default     = 2
}

variable "bastion_instance_type" {
  description = "Type d'instance du bastion SSM (accès admin privé à EKS/Argo CD)"
  type        = string
  default     = "t3.micro"
}

# ---- ECR ----
variable "ecr_repository_name" {
  description = "Nom du repository ECR"
  type        = string
  default     = "veille-immo-api"
}

# ---- RDS ----
variable "db_instance_class" {
  description = "Classe d'instance RDS"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_storage" {
  description = "Taille de stockage RDS en GB"
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Activer le multi-AZ pour RDS (HA, coût x2)"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Nom de la base"
  type        = string
  default     = "veilleimmo"
}

variable "db_username" {
  description = "Nom d'utilisateur de la base"
  type        = string
  sensitive   = true
}

# Le mot de passe RDS est généré automatiquement (random_password.db) et stocké
# uniquement dans AWS Secrets Manager — jamais dans Git ni dans une variable Terraform.

# ---- IAM ----
variable "github_organization" {
  description = "Nom de l'organisation GitHub"
  type        = string
  default     = "votre-org" # À remplacer par ton organisation
}

variable "github_repository" {
  description = "Nom du repository GitHub (celui du code Flask)"
  type        = string
  default     = "veille-immo"
}

# ---- GitOps (pour Argo CD) ----
variable "gitops_repo_url" {
  description = "URL du dépôt GitOps"
  type        = string
  default     = "https://github.com/Styyde/flask-gitops---public-veille-immobiliere.git"
}

# ---- Domaines ----
variable "domain_name" {
  description = "Domaine principal pour l'application (ex: amandal.kolynois.com)"
  type        = string
  default     = "amandal.kolynois.com"
}

variable "hosted_zone_name" {
  description = "Nom de la zone Route53 (ex: kolynois.com)"
  type        = string
  default     = "kolynois.com"
}