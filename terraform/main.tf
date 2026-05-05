terraform {
  backend "s3" {
    key     = "rbai/terraform.tfstate"
    encrypt = true
    # bucket and region passed via -backend-config at init time
  }
  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {}

variable "container_image" {
  description = "Full image URI (registry/name:tag)"
  default     = "placeholder"
}

variable "app_port" {
  type    = number
  default = 8000
}

variable "replica_count" {
  type    = number
  default = 2
}

variable "node_instance_type" {
  default = "t3.small"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 3
}

variable "health_check_path" {
  default = "/"
}

# ── Optional secrets passed to kubectl apply as env vars ─────────────────────
variable "database_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "db_host" {
  type    = string
  default = ""
}

variable "db_port" {
  type    = string
  default = ""
}

variable "db_name" {
  type    = string
  default = ""
}

variable "db_username" {
  type    = string
  default = ""
}

variable "db_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "mongo_uri" {
  type      = string
  default   = ""
  sensitive = true
}

variable "redis_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "secret_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "jwt_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "spring_datasource_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "spring_datasource_user" {
  type    = string
  default = ""
}

variable "spring_datasource_pass" {
  type      = string
  default   = ""
  sensitive = true
}

variable "spring_mongodb_uri" {
  type      = string
  default   = ""
  sensitive = true
}


locals {
  name_safe = trimsuffix(substr(lower(replace(replace(var.project_name, "_", "-"), " ", "-")), 0, 24), "-")
  ecr_name  = lower(replace(replace(var.project_name, "_", "-"), " ", "-"))
  namespace = local.name_safe

  _ext_port    = var.db_port != "" ? var.db_port : "5432"
  _ext_scheme  = "postgresql+asyncpg"
  _auto_db_url = var.db_host != "" ? "${local._ext_scheme}://${var.db_username}:${var.db_password}@${var.db_host}:${local._ext_port}/${var.db_name}" : ""
  _db_url      = var.database_url != "" ? var.database_url : local._auto_db_url
  _db_host     = var.db_host
  _db_port     = local._ext_port
  _db_name     = var.db_name
  _db_user     = var.db_username
  _db_password = var.db_password
  _spring_ds_url  = var.spring_datasource_url
  _spring_ds_user = var.spring_datasource_user
  _spring_ds_pass = var.spring_datasource_pass

  _all_env = {
    PORT                        = tostring(var.app_port)
    APP_ENV                     = "production"
    DATABASE_URL                = local._db_url
    DB_HOST                     = local._db_host
    DB_PORT                     = local._db_port
    DB_NAME                     = local._db_name
    DB_USER                     = local._db_user
    DB_PASSWORD                 = local._db_password
    MONGO_URI                   = var.mongo_uri
    REDIS_URL                   = var.redis_url
    SECRET_KEY                  = var.secret_key
    JWT_SECRET                  = var.jwt_secret
    SPRING_DATASOURCE_URL       = local._spring_ds_url
    SPRING_DATASOURCE_USERNAME  = local._spring_ds_user
    SPRING_DATASOURCE_PASSWORD  = local._spring_ds_pass
    SPRING_DATA_MONGODB_URI     = var.spring_mongodb_uri
  }
  app_env = { for k, v in local._all_env : k => v if v != "" }
}

# ── VPC ────────────────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_safe}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ── EKS Cluster ────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name_safe}-eks"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      name           = "${local.name_safe}-ng"
      instance_types = [var.node_instance_type]
      min_size       = var.min_nodes
      max_size       = var.max_nodes
      desired_size   = var.replica_count

      labels = {
        project = var.project_name
      }
    }
  }

  enable_cluster_creator_admin_permissions = true
}

# ── ECR ────────────────────────────────────────────────────────────────────────
data "aws_ecr_repository" "app" {
  depends_on = [module.eks]
  name       = local.ecr_name
}

# ── IRSA for AWS Load Balancer Controller ──────────────────────────────────────
data "aws_iam_policy_document" "lbc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${local.name_safe}-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
}

data "http" "lbc_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${local.name_safe}-lbc-policy"
  policy = data.http.lbc_policy.response_body
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}


# ── Outputs ────────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "namespace" {
  value = local.namespace
}

output "ecr_repository_url" {
  value = data.aws_ecr_repository.app.repository_url
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}

output "app_env_json" {
  value     = jsonencode(local.app_env)
  sensitive = true
}
