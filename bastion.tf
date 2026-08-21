# ─── Bastion SSM (administrateur interne VPC du cluster EKS) ────────────────
# Pas d'IP publique, aucun port entrant ouvert (pas de SSH) : l'accès se fait
# uniquement via AWS Systems Manager Session Manager (auth IAM, sessions
# journalisées dans CloudTrail).
#
#   Internet ──(❌ pas d'accès SSH)──> [Bastion, subnet privé]
#                                          │ SSM Session
#                                          ▼ kubectl / helm
#                                     [EKS private API]
#
# Deux couches d'autorisation distinctes :
#   - Réseau  : le SG du bastion peut atteindre le SG du control plane EKS sur
#     443 (règle aws_security_group_rule.bastion_to_eks_api ci-dessous).
#   - Identité : le rôle IAM du bastion est enregistré comme EKS access entry
#     avec la policy cluster-admin (aws_eks_access_entry / _access_policy_association
#     ci-dessous) -> une fois authentifié, kubectl/helm ont les droits RBAC admin.
#
# Le bastion sert pour : bootstrap initial des composants Helm (Argo CD, ALB
# Controller, External Secrets, metrics-server, ExternalDNS), diagnostic et
# administration du cluster, dépannage, et accès à Argo CD (qui reste en
# ClusterIP, jamais exposé sur Internet). Terraform ne fait plus de kubectl/helm
# lui-même (cf. suppression de l'ancien null_resource.bootstrap dans main.tf) :
# ces opérations sont désormais exécutées manuellement, depuis le bastion.
#
# Accès :
#   aws ssm start-session --target <bastion_instance_id>
#   # une fois dans la session :
#   aws eks update-kubeconfig --region <region> --name <cluster_name>
#   kubectl get nodes
#
#   # bootstrap initial des composants Helm (une seule fois) :
#   #   1. depuis le poste local : terraform output -raw bootstrap_script > bootstrap.sh
#   #   2. coller le contenu de bootstrap.sh dans la session SSM (ou le transférer
#   #      via `aws ssm send-command`), puis : bash bootstrap.sh
#
#   # accès à Argo CD (ClusterIP, jamais public) :
#   kubectl port-forward -n argocd svc/argocd-server 8080:443 --address 0.0.0.0
#
#   # depuis le poste local, dans un second terminal :
#   aws ssm start-session --target <bastion_instance_id> \
#     --document-name AWS-StartPortForwardingSession \
#     --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
#   # puis ouvrir https://localhost:8080

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ─── Plafond IAM du bastion (permissions boundary) ───────────────────────────
# Le bastion n'est PAS un second runner Terraform : il ne doit jamais pouvoir
# créer/modifier de l'infrastructure AWS (VPC, IAM, RDS, S3, Route53, Secrets
# Manager, ECR...). Cette boundary plafonne le rôle à deux familles d'actions,
# quoi qu'on lui attache par ailleurs plus tard :
#   - SSM / SSM Messages / EC2 Messages : connectivité Session Manager (aucune
#     de ces actions ne crée de ressource AWS, elles gèrent uniquement l'agent).
#   - eks:DescribeCluster + sts:GetCallerIdentity : récupérer un kubeconfig et
#     s'authentifier. Les droits d'administration réels sur le cluster sont
#     accordés côté RBAC Kubernetes par l'EKS access entry ci-dessous, pas par
#     IAM -> le bastion est admin *du cluster*, pas admin *du compte AWS*.
resource "aws_iam_policy" "bastion_boundary" {
  name        = "${local.cluster_name}-bastion-boundary"
  description = "Plafond de permissions du bastion : SSM + lecture EKS uniquement, aucun droit de provisioning AWS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Liste identique (pas de wildcard ssm:*) à celle de la managed policy
        # AmazonSSMManagedInstanceCore attachée plus bas : la boundary ne doit
        # pas être plus permissive que nécessaire, sinon elle ne plafonne
        # plus rien. Notamment PAS ssm:SendCommand/StartAutomationExecution
        # (contrôle d'autres instances) ni ssm:PutParameter (écriture).
        Sid    = "SSMConnectivity"
        Effect = "Allow"
        Action = [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
          "ssm:GetManifest",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
        ]
        Resource = "*"
      },
      {
        Sid      = "EKSReadOnlyAuth"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "bastion" {
  name                 = "${local.cluster_name}-bastion-role"
  permissions_boundary = aws_iam_policy.bastion_boundary.arn

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

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "bastion_eks_access" {
  name        = "${local.cluster_name}-bastion-eks-policy"
  description = "Permet au bastion de récupérer un kubeconfig pour le cluster EKS privé"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_eks_access" {
  role       = aws_iam_role.bastion.name
  policy_arn = aws_iam_policy.bastion_eks_access.arn
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# Droits Kubernetes RBAC du bastion sur le cluster (remplace l'aws-auth ConfigMap)
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_security_group" "bastion" {
  name        = "${local.cluster_name}-bastion-sg"
  description = "Bastion SSM : aucun port entrant, sortie uniquement vers le VPC/AWS"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "HTTPS sortant (SSM, EKS API, ECR...)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Port-forward vers API EKS / pods"
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Environment = var.environment
  }
}

# Autorise le bastion à atteindre l'API EKS privée sur 443. Sans cette règle,
# le SG du control plane EKS n'accepte aucun trafic entrant depuis le bastion,
# quels que soient ses droits IAM/RBAC.
resource "aws_security_group_rule" "bastion_to_eks_api" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = module.eks.cluster_primary_security_group_id
  description              = "Bastion SSM access to private EKS API (kubectl/helm)"
}

# Bastion en ASG à 1 instance (min=max=desired=1) plutôt qu'une aws_instance
# nue : si l'instance meurt (crash, maintenance AWS, AZ down), l'ASG en
# relance une automatiquement -- y compris dans une autre AZ puisque
# vpc_zone_identifier couvre tous les subnets privés. Ce n'est pas de la HA
# au sens "toujours dispo sans interruption" (un admin devra relancer sa
# session SSM), mais ça élimine le "reste mort tant que quelqu'un ne fait pas
# terraform apply à la main".
resource "aws_launch_template" "bastion" {
  name_prefix   = "${local.cluster_name}-bastion-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.bastion_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.bastion.name
  }

  vpc_security_group_ids = [aws_security_group.bastion.id]

  metadata_options {
    http_tokens = "required" # IMDSv2 uniquement
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    dnf install -y unzip tar gzip

    curl -sSL -o /tmp/kubectl "https://dl.k8s.io/release/v${var.kubernetes_version}.0/bin/linux/amd64/kubectl"
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

    curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.cluster_name}-bastion"
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bastion" {
  name                = "${local.cluster_name}-bastion-asg"
  vpc_zone_identifier = module.vpc.private_subnets
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.bastion.id
    version = aws_launch_template.bastion.latest_version
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  depends_on = [module.eks]
}
