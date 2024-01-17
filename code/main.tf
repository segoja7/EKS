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


  aws_auth_roles = [  ]

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
    aws-ebs-csi-driver = {
      most_recent = true
    }
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

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "19.17.1"

  cluster_name                    = module.eks.cluster_name
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  create_iam_role      = false
  iam_role_arn         = module.eks.eks_managed_node_groups["cloud-people"].iam_role_arn
  irsa_use_name_prefix = false

  tags = local.tags
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0" #ensure to update this to the latest/desired version

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn


  #  enable_velero = true
  #  velero = {
  #    s3_backup_location = "arn:aws:s3:::bucket-s3-terraform-nequi/velero-test"
  #  }
  #https://github.com/vmware-tanzu/velero-plugin-for-aws/blob/master/backupstoragelocation.md

  helm_releases = {
    velero = {
      name             = "velero"
      namespace        = "velero"
      create_namespace = true
      chart            = "./helm-charts/helm-charts-velero-5.2.0/velero"
      values           = [templatefile("./helm-charts/helm-charts-velero-5.2.0/velero/values.yaml", { ROLE = aws_iam_role.velero-backup-role.arn })]
    }
    metrics-server = {
      chart            = "./helm-charts/metrics-server"
      name             = "metrics-server"
      namespace        = "kube-system"
      create_namespace = true
      values           = [file("./helm-charts/metrics-server/values.yaml")]
    }
    karpenter = {
      namespace        = "karpenter"
      create_namespace = true

      name                = "karpenter"
      repository          = "oci://public.ecr.aws/karpenter"
      repository_username = data.aws_ecrpublic_authorization_token.token.user_name
      repository_password = data.aws_ecrpublic_authorization_token.token.password
      chart               = "karpenter"
      version             = "v0.32.2"

      set = [
        {
          name  = "settings.clusterName"
          value = module.eks.cluster_name
        },
        {
          name  = "settings.clusterEndpoint"
          value = module.eks.cluster_endpoint
        },
        {
          name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
          value = module.karpenter.irsa_arn
        },
        {
          name  = "settings.defaultInstanceProfile"
          value = module.karpenter.instance_profile_name
        },
        {
          name  = "settings.interruptionQueue"
          value = module.karpenter.queue_name
        }
      ]


    }
  }

  tags = {
    Environment = "dev"
  }
}

resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: default
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"] #"spot"
        - key: "node.kubernetes.io/instance-type"
          operator: In
          values: ["c5.large","c5a.large", "c5ad.large", "c5d.large", "c6i.large", "t2.medium", "t3.medium", "t3a.medium"]
      limits:
        resources:
          cpu: 1000
      providerRef:
        name: default
      ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    module.karpenter, helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_template" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1alpha1
    kind: AWSNodeTemplate
    metadata:
      name: default
    spec:
      subnetSelector:
        karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelector:
        karpenter.sh/discovery: ${module.eks.cluster_name}
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML

  depends_on = [
    module.karpenter, helm_release.karpenter
  ]
}

# Example deployment using the [pause image](https://www.ianlewis.org/en/almighty-pause-container)
# and starts with zero replicas
resource "kubectl_manifest" "karpenter_example_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: inflate
    spec:
      replicas: 0
      selector:
        matchLabels:
          app: inflate
      template:
        metadata:
          labels:
            app: inflate
        spec:
          terminationGracePeriodSeconds: 0
          containers:
            - name: inflate
              image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
              resources:
                requests:
                  cpu: 1
  YAML

  depends_on = [
    module.karpenter, helm_release.karpenter
  ]
}

resource "aws_iam_policy" "velero-backup" {
  name = "velero-backup-policy-${module.eks.cluster_name}"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "ec2:DescribeVolumes",
            "ec2:DescribeSnapshots",
            "ec2:CreateTags",
            "ec2:CreateVolume",
            "ec2:CreateSnapshot",
            "ec2:DeleteSnapshot"
          ],
          "Resource" : "*"
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:GetObject",
            "s3:DeleteObject",
            "s3:PutObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts"
          ],
          "Resource" : [
            "arn:aws:s3:::bucket-s3-terraform-nequi/*"
          ]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:ListBucket"
          ],
          "Resource" : [
            "arn:aws:s3:::bucket-s3-terraform-nequi/*",
            "arn:aws:s3:::bucket-s3-terraform-nequi"
          ]
        }
      ]
    }
  )
  tags = local.tags
}

resource "aws_iam_role" "velero-backup-role" {
  name = "velero-backup-role-${module.eks.cluster_name}"
  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.cleaned_issuer_url}"
          },
          "Action" : "sts:AssumeRoleWithWebIdentity",
          "Condition" : {
            "StringEquals" : {
              "${local.cleaned_issuer_url}:sub" = "system:serviceaccount:velero:velero-server"
              "${local.cleaned_issuer_url}:aud" = "sts.amazonaws.com"
            }
          }
        }
      ]
    }
  )
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "velero_policy_attachment" {
  policy_arn = aws_iam_policy.velero-backup.arn
  role       = aws_iam_role.velero-backup-role.name
}


resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "v0.32.2"

  set {
    name  = "settings.aws.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.aws.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.irsa_arn
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/sts-regional-endpoints"
    value = "true"
    type  = "string"
  }

  set {
    name  = "settings.aws.defaultInstanceProfile"
    value = module.karpenter.instance_profile_name
  }

  set {
    name  = "settings.aws.interruptionQueueName"
    value = module.karpenter.queue_name
  }
}

