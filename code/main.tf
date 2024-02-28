module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 6, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 6, k + 10)]

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/role/elb"              = 1
    "kubernetes.io/cluster/${local.name}" = "shared" #adding tags for deploy elb
    # "karpenter.sh/discovery" = local.name
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"     = 1
    "kubernetes.io/cluster/${local.name}" = "shared" #adding tags for deploy elb
    "karpenter.sh/discovery"              = local.name
  }

  tags = local.tags

}

#Adding EKS Cluster

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.20.0"

  cluster_name                   = local.name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets


  #we uses only 1 security group to allow connection with Fargate, MNG, and Karpenter nodes
  create_node_security_group = false
  eks_managed_node_groups = {
    cloud-people = {
      node_group_name = var.node_group_name
      instance_types  = ["m5.large"]

      min_size     = 1
      max_size     = 5
      desired_size = 2
      subnet_ids   = module.vpc.private_subnets
    }

  }
  #aws-auth configmap
  manage_aws_auth_configmap = true

  #You cand add roles for aws-auth
  aws_auth_roles = []

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    #    aws-ebs-csi-driver = {
    #      most_recent = true
    #    }
  }
  cluster_tags = {
    "kubernetes.io/cluster/${local.name}" = null
  }
  node_security_group_tags = {
    "kubernetes.io/cluster/${local.name}" = null
  }
  tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = "${local.name}"
  })

}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0" #ensure to update this to the latest/desired version

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  helm_releases = {
    efs-csi-driver = {
      name             = "efs-csi-driver"
      namespace        = "kube-system"
      create_namespace = true
      chart            = "./helm-charts/aws-efs-csi-driver"
      values = [
        templatefile("./helm-charts/aws-efs-csi-driver/values.yaml", {
          role_arn = aws_iam_role.efs_controller_role.arn,
          efs_id   = module.efs.id
        })
      ]
    }
  }
}


module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "1.6.0"

  name                            = "efs-testing"
  encrypted                       = true
  performance_mode                = "generalPurpose"
  throughput_mode                 = "provisioned"
  provisioned_throughput_in_mibps = 25
  enable_backup_policy            = false
  create_backup_policy            = false
  attach_policy                   = true
  policy_statements = [
    {
      sid    = "connect"
      Effect = "Allow"
      actions = ["elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientRootAccess",
      "elasticfilesystem:ClientWrite"]
      principals = [
        {
          type        = "AWS"
          identifiers = ["*"]
        }
      ]
    }
  ]

  lifecycle_policy = {
    transition_to_ia = "AFTER_90_DAYS"
  }

  mount_targets = {
    for i in range(length(module.vpc.private_subnets)) :
    module.vpc.private_subnets[i] => {
      subnet_id = module.vpc.private_subnets[i]
#      security_groups = [module.security-group.security_group_id]
    }
  }
  security_group_description = "EFS security group"
#  create_security_group = true
  security_group_vpc_id      = module.vpc.vpc_id
  security_group_rules = {
    vpc = {
      # relying on the defaults provdied for EFS/NFS (2049/TCP + ingress)
      description = "NFS ingress from VPC private subnets"
      cidr_blocks = module.vpc.private_subnets_cidr_blocks
    }
  }
}

resource "aws_iam_role" "efs_controller_role" {
  name = "role-efsdriver-${module.eks.cluster_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.cleaned_issuer_url}"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${local.cleaned_issuer_url}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
            "${local.cleaned_issuer_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "efs_controller_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.efs_controller_role.name
}

