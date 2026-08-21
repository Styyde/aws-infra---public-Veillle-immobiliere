# ─── VPC ──────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  enable_vpn_gateway     = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    Environment = var.environment
  }
}

# ─── VPC Endpoint S3 (Gateway) ─────────────────────────────────────────────────
# Gratuit (pas de coût horaire ni de traitement de données, contrairement aux
# endpoints Interface) : évite que les pulls d'images ECR (layers stockées sur
# S3) et l'accès au bucket Loki passent par le NAT Gateway / Internet Gateway.
# Attaché aux route tables publiques et privées : aucune contre-indication à
# le faire sur les deux, un Gateway endpoint n'ajoute qu'une route S3 locale.
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  route_table_ids = concat(
    module.vpc.private_route_table_ids,
    module.vpc.public_route_table_ids,
  )

  tags = {
    Name        = "${local.cluster_name}-s3-endpoint"
    Environment = var.environment
  }
}

# ─── ECR ──────────────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 30 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ─── EKS Cluster ──────────────────────────────────────────────────────────────
locals {
  cluster_name = "${var.project_name}-${var.environment}"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Cluster 100% privé : l'API server n'est joignable que depuis le VPC
  # (bastion SSM, cf. bastion.tf). Aucun accès public, même par CIDR.
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  # aws-auth ConfigMap remplacé par les access entries EKS en v20 ; on ne
  # donne pas d'accès admin implicite au créateur, comme avant (manage/create = false)
  enable_cluster_creator_admin_permissions = false

  # On gère le node group manuellement
  eks_managed_node_groups = {}

  tags = {
    Environment = var.environment
  }
}

# ─── EKS Node Group ────────────────────────────────────────────────────────────
resource "aws_iam_role" "node_role" {
  name = "${local.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

# Hop limit IMDS = 2 (au lieu de 1 par défaut) : nécessaire pour que les pods
# (ex: aws-load-balancer-controller) puissent atteindre l'instance metadata
# service depuis l'intérieur d'un conteneur (le réseau pod ajoute un hop par
# rapport au réseau host).
resource "aws_launch_template" "application_workers" {
  name_prefix = "${local.cluster_name}-application-workers-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "application_workers" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "application-workers"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  instance_types = var.node_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.application_workers.id
    version = aws_launch_template.application_workers.latest_version
  }

  labels = {
    role = "application"
  }

  update_config {
    max_unavailable = 1
  }

  # Tags propagés à l'ASG sous-jacent -- requis pour que Cluster Autoscaler
  # découvre automatiquement ce node group (--node-group-auto-discovery).
  tags = {
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}

# ─── ALB Controller IAM ──────────────────────────────────────────────────────
resource "aws_iam_role" "alb_controller" {
  name = "${local.cluster_name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "alb_controller_policy" {
  name        = "${local.cluster_name}-alb-controller-policy"
  description = "Policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:SetWebAcl",
          "waf:GetWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "waf:AssociateWebACL",
          "wafv2:AssociateWebACL",
          "waf:DisassociateWebACL",
          "wafv2:DisassociateWebACL",
          "cognito-idp:DescribeUserPoolClient",
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "iam:ListAttachedRolePolicies",
          "iam:ListPolicies",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetRole",
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:PassRole",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller_attach" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn
}

# ─── RDS PostgreSQL ──────────────────────────────────────────────────────────
resource "random_password" "db" {
  length  = 32
  special = false # évite les caractères qui doivent être URL-encodés dans DATABASE_URL
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow PostgreSQL access from EKS"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Environment = var.environment
  }
}

resource "aws_security_group_rule" "rds_ingress_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.eks.cluster_primary_security_group_id
  security_group_id        = aws_security_group.rds.id
}

resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.0.0"

  identifier = "${var.project_name}-db-${var.environment}"

  engine               = "postgres"
  engine_version       = "15"
  family               = "postgres15"
  major_engine_version = "15"

  instance_class = var.db_instance_class

  allocated_storage     = var.db_storage
  storage_encrypted     = true
  storage_type          = "gp3"
  max_allocated_storage = 50

  db_name                     = var.db_name
  username                    = var.db_username
  password                    = random_password.db.result
  manage_master_user_password = false
  apply_immediately           = true

  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports        = ["postgresql"]
  cloudwatch_log_group_retention_in_days = 7

  multi_az = var.db_multi_az

  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnets

  tags = {
    Environment = var.environment
  }
}

# ─── Secrets Manager : identifiants DB (jamais commités dans Git) ───────────
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${local.cluster_name}-db-credentials"
  description = "Identifiants RDS pour ${var.project_name}, consommés par External Secrets Operator"

  tags = {
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username     = var.db_username
    password     = random_password.db.result
    host         = module.db.db_instance_address
    port         = 5432
    dbname       = var.db_name
    DATABASE_URL = "postgresql://${var.db_username}:${random_password.db.result}@${module.db.db_instance_address}:5432/${var.db_name}"
  })
}

# ─── Secrets Manager : identifiants admin Grafana (jamais commités dans Git) ─
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name        = "${local.cluster_name}-grafana-admin"
  description = "Identifiants admin Grafana, consommés par External Secrets Operator"

  tags = {
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id

  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  })
}

# ─── Alertmanager -> Slack (Secrets Manager, jamais commité dans Git) ───────
resource "aws_secretsmanager_secret" "alertmanager_slack" {
  name        = "${local.cluster_name}-alertmanager-slack"
  description = "Webhook Slack entrant pour les notifications Alertmanager, consommé par External Secrets Operator"

  tags = {
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "alertmanager_slack" {
  secret_id = aws_secretsmanager_secret.alertmanager_slack.id

  secret_string = jsonencode({
    slack_api_url = var.alertmanager_slack_webhook_url
  })
}

# ─── External Secrets Operator IAM (IRSA) ────────────────────────────────────
resource "aws_iam_role" "external_secrets" {
  name = "${local.cluster_name}-external-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "external_secrets_policy" {
  name        = "${local.cluster_name}-external-secrets-policy"
  description = "Autorise External Secrets Operator à lire les secrets DB, Grafana et Alertmanager dans Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.db_credentials.arn,
          aws_secretsmanager_secret.grafana_admin.arn,
          aws_secretsmanager_secret.alertmanager_slack.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets_attach" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets_policy.arn
}

# ─── GitHub Actions OIDC Role ──────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # GitHub inclut désormais les IDs numériques immuables de l'org et
            # du repo dans le sub claim (ex: repo:org@12345/repo@67890:...),
            # en plus du format classique repo:org/repo:... -> on accepte les deux.
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_organization}/${var.github_repository}:*",
              "repo:${var.github_organization}@*/${var.github_repository}@*:*",
            ]
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "github_actions_policy" {
  name        = "${var.project_name}-github-actions-policy"
  description = "Policy pour GitHub Actions : push d'images vers ECR uniquement (le déploiement est fait par Argo CD, pas par la CI)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = aws_ecr_repository.app.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_attach" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_policy.arn
}

# ─── Route53 et ACM ─────────────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.hosted_zone_name}" # wildcard pour d'autres sous-domaines
  ]

  tags = {
    Name        = "${var.project_name}-cert"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ─── IAM Role pour ExternalDNS ──────────────────────────────────────────────
resource "aws_iam_role" "external_dns" {
  name = "${local.cluster_name}-external-dns-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:external-dns"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "external_dns_policy" {
  name        = "${local.cluster_name}-external-dns-policy"
  description = "Policy for ExternalDNS to manage Route53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone"
        ]
        Resource = data.aws_route53_zone.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_dns_attach" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns_policy.arn
}

# ─── Cluster Autoscaler IAM ──────────────────────────────────────────────────
# Scale automatiquement le node group EKS (application_workers) en fonction
# des pods Pending faute de capacité -- indépendant du HPA, qui lui scale les
# pods (cf. flask-gitops/apps/flask-app/templates/hpa.yaml).
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.cluster_name}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "cluster_autoscaler_policy" {
  name        = "${local.cluster_name}-cluster-autoscaler-policy"
  description = "Policy for Cluster Autoscaler to scale the EKS node group ASG"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler_attach" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler_policy.arn
}

# ─── YACE (yet-another-cloudwatch-exporter) IAM (IRSA) ───────────────────────
# Expose en Prometheus les métriques CloudWatch que Prometheus ne peut pas
# scraper nativement (RDS, ALB -- ressources hors du cluster). Lecture seule
# strict : aucune action de modification. Déployé via Helm/Argo CD, cf.
# flask-gitops/yace (le rôle ci-dessous doit être collé dans son values.yaml).
resource "aws_iam_role" "yace" {
  name = "${local.cluster_name}-yace-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:monitoring:yace"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "yace_policy" {
  name        = "${local.cluster_name}-yace-policy"
  description = "Lecture seule CloudWatch/Tagging pour yet-another-cloudwatch-exporter (métriques RDS + ALB)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricStatistics",
          "rds:DescribeDBInstances",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "yace_attach" {
  role       = aws_iam_role.yace.name
  policy_arn = aws_iam_policy.yace_policy.arn
}

# ─── Loki (logs des pods) : bucket S3 + IAM (IRSA) ───────────────────────────
# Un seul bucket sert aux 3 usages de Loki (chunks/ruler/admin, cf.
# flask-gitops/loki/values.yaml) -- pratique courante pour un déploiement
# mono-tenant de cette taille, pas besoin de 3 buckets séparés.
resource "aws_s3_bucket" "loki_logs" {
  bucket = "${local.cluster_name}-loki-logs"

  tags = {
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Purge automatique : les logs applicatifs n'ont pas besoin d'être conservés
# indéfiniment (à la différence des backups RDS). Le compactor Loki applique
# déjà sa propre rétention logique (14j, cf. loki.limits_config dans
# flask-gitops/loki/values.yaml) ; cette règle de cycle de vie S3 est un
# filet de sécurité si jamais le compactor ne tourne pas.
resource "aws_s3_bucket_lifecycle_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

resource "aws_iam_role" "loki" {
  name = "${local.cluster_name}-loki-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:monitoring:loki"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_policy" "loki_policy" {
  name        = "${local.cluster_name}-loki-policy"
  description = "Autorise Loki à lire/écrire ses chunks de logs dans son bucket S3 dédié"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.loki_logs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.loki_logs.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "loki_attach" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki_policy.arn
}

# ─── BOOTSTRAP POST-DEPLOY (script, rendu mais non exécuté par Terraform) ────
# Le cluster EKS est privé (cluster_endpoint_public_access = false) : aucune
# machine hors VPC ne peut joindre son API. Terraform ne fait donc plus de
# kubectl/helm lui-même (ancien null_resource + local-exec, retiré) : le
# rendu ci-dessous est exposé via l'output `bootstrap_script` et doit être
# exécuté manuellement depuis le bastion (cf. bastion.tf pour la procédure
# complète et les schémas réseau/IAM).
locals {
  bootstrap_script = templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    cluster_name             = module.eks.cluster_name
    region                   = var.aws_region
    gitops_repo_url          = var.gitops_repo_url
    alb_role_arn             = aws_iam_role.alb_controller.arn
    external_dns_role        = aws_iam_role.external_dns.arn
    external_secrets_role    = aws_iam_role.external_secrets.arn
    cluster_autoscaler_role  = aws_iam_role.cluster_autoscaler.arn
    db_secret_name           = aws_secretsmanager_secret.db_credentials.name
    grafana_secret_name      = aws_secretsmanager_secret.grafana_admin.name
    yace_role_arn            = aws_iam_role.yace.arn
    alertmanager_secret_name = aws_secretsmanager_secret.alertmanager_slack.name
    domain_name              = var.domain_name
  })
}