# Container registry for the API image.
#
# Lives in `data` rather than `compute` because images must survive teardown — `make up` should
# deploy the existing image, not rebuild it.

resource "aws_ecr_repository" "api" {
  name                 = "${var.project}-api"
  image_tag_mutability = "IMMUTABLE" # P-04 Immutable Infrastructure

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# IMMUTABLE tags are the load-bearing setting here. With MUTABLE, `docker push :abc123` can
# silently replace what abc123 points at, and the deploy workflow's SHA assertion (P-10) would
# pass while serving different code. Immutability is what makes "the SHA identifies the
# artifact" true rather than aspirational.
#
# Consequence to know: re-pushing the same tag fails. That is correct — a given commit should
# produce one image. Rebuilding means a new commit.

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the ${var.ecr_image_count} most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.ecr_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
