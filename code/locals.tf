locals {
  profile = "segoja7"
  name    = var.environment_name
  region  = var.aws_region

  vpc_cidr       = var.vpc_cidr
  num_of_subnets = min(length(data.aws_availability_zones.available.names), 2)
  azs            = slice(data.aws_availability_zones.available.names, 0, local.num_of_subnets)

  tags = {
    blog = "kubernetes-series"
  }
}

locals {
  cleaned_issuer_url = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}
