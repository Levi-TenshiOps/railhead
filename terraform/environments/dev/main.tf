module "vpc" {
  source = "../../modules/vpc"

  cluster_name = "railhead-dev"
  vpc_cidr     = "10.0.0.0/16"
}

module "iam" {
  source = "../../modules/iam"

  github_org       = "Levi-TenshiOps"
  github_repo      = "railhead"
  state_bucket_arn = "arn:aws:s3:::railhead-tfstate-993268717190"
  lock_table_arn   = "arn:aws:dynamodb:us-east-1:993268717190:table/railhead-tfstate-lock"
}

module "ecr" {
  source = "../../modules/ecr"

  repository_names = ["railhead-api", "railhead-worker"]
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = "railhead-dev"
  kubernetes_version = "1.34"
  subnet_ids         = module.vpc.private_subnet_ids
}

# ecr:GetAuthorizationToken authenticates to the ECR registry itself
# (it's how the docker/aws CLI gets a login token before any specific
# repository is even known), not to a single repository, so AWS does not
# let this action be scoped to a repository ARN — "*" is the only valid
# resource value for it. The rest of the actions below are ordinary
# per-repository push/pull operations, so those stay scoped to this
# project's actual ECR repository ARNs.
resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push-pull"
  role = module.iam.github_actions_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
        ]
        Resource = values(module.ecr.repository_arns)
      }
    ]
  })
}
