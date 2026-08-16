# ─── Bastion SSM (accès admin privé à EKS / Argo CD) ────────────────────────
# Pas d'IP publique, aucun port entrant ouvert : l'accès se fait uniquement via
# AWS Systems Manager Session Manager (auth IAM, sessions journalisées dans
# CloudTrail). C'est le seul point d'entrée pour administrer le cluster EKS
# privé et atteindre Argo CD (qui reste en ClusterIP, cf. scripts/bootstrap.sh.tpl).
#
# Accès :
#   aws ssm start-session --target <bastion_instance_id>
#   # une fois dans la session :
#   aws eks update-kubeconfig --region <region> --name <cluster_name>
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

resource "aws_iam_role" "bastion" {
  name = "${local.cluster_name}-bastion-role"

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

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.bastion_instance_type
  subnet_id                   = module.vpc.private_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required" # IMDSv2 uniquement
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y unzip
    curl -o /tmp/kubectl "https://s3.us-west-2.amazonaws.com/amazon-eks/${var.kubernetes_version}.0/2024-01-04/bin/linux/amd64/kubectl"
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  EOF

  tags = {
    Name        = "${local.cluster_name}-bastion"
    Environment = var.environment
  }

  depends_on = [module.eks]
}
