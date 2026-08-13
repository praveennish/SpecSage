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

  # ⚠️ ECR lifecycle policies have NO concept of referential integrity. They cannot tell an
  # orphaned layer from a child manifest that a tagged image index depends on, and they will
  # happily delete the latter — leaving a tag that resolves to nothing and fails every pull.
  #
  # This is not hypothetical: the first push to this repo produced three manifests, because
  # `docker buildx --push` attaches provenance attestations by default and therefore publishes
  # an image INDEX. The tag landed on the index; the actual 57 MB arm64 image and the
  # attestation were both untagged children. An aggressive untagged rule would have deleted
  # the real image roughly a day later, with no deploy and no warning.
  #
  # Two mitigations, because either alone is fragile:
  #   1. Build with --provenance=false --sbom=false so the tag points at a plain manifest
  #      and no untagged children exist. This is the actual fix (see the M0 compute runbook).
  #   2. The 14-day window below, as defence in depth for when someone forgets (1).
  #
  # 14 days is long enough that a broken image is caught by a deploy or a `make up` first,
  # and short enough that genuine orphans from failed pushes still get cleaned up.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days — see the warning above"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
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
