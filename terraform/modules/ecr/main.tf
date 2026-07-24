terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# IMMUTABLE means once a tag (e.g. "v1.2.3") is pushed, it can never be
# overwritten by a later push of the same tag — a new build must use a
# new tag. This closes off "latest silently changed underneath a running
# deployment" as a failure mode and keeps a 1:1 mapping between a tag and
# the exact image bytes it pointed to, which matters for traceability
# (rollbacks, incident review: "what was actually running at 2am?").
resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Lifecycle policy is a cost/hygiene control, not just cleanup: untagged
# images (leftovers from builds that got re-tagged, or failed pushes)
# have no way to ever be referenced again, so there's no reason to keep
# paying storage for them past a short grace period. Capping tagged
# images at the most recent 30 stops an ever-growing image history from
# silently accumulating storage cost for versions nobody will ever
# deploy again. Raised from 10 to 30 after this cap silently evicted a
# still-deployed tag twice -- every push rebuilds all matrix services
# regardless of what changed, so 10 was too easy to exceed with unrelated
# commits (docs, README, a single service's own changes) before anyone
# manually bumped every service's deployed tag.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent 30 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
