# Two ECR repositories, one per service image. Terraform cannot build or push, so this module
# creates the destinations and `just push` does the rest.

resource "aws_ecr_repository" "service" {
  for_each = toset(var.services)

  name = "${var.project_name}/${each.key}"

  # terraform destroy fails on a repository holding images. Production: false.
  force_delete = true

  # MUTABLE so `latest` can be re-pointed. Production: IMMUTABLE, with a real tagging scheme.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # Basic scanning is free.
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}/${each.key}"
  }
}

# Storage is billed per GB-month, and without a lifecycle policy every build is kept forever.
resource "aws_ecr_lifecycle_policy" "expire_old_images" {
  for_each = aws_ecr_repository.service

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the ${var.retained_image_count} most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.retained_image_count
      }
      action = {
        type = "expire"
      }
    }]
  })
}
