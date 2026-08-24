# Two ECR repositories, one per service image.
#
# Terraform cannot build or push images, so this module creates the destinations and the
# justfile owns everything after that. The repositories exist in Terraform rather than being
# created by hand because the ECS task definitions reference their URLs, and a hand-made
# repository is one more thing that has to be recreated correctly in an empty account.

resource "aws_ecr_repository" "service" {
  for_each = toset(var.services)

  name = "${var.project_name}/${each.key}"

  # Without this, terraform destroy fails on any repository that still holds an image, and
  # teardown is the actual cost guardrail for this project. The production setting is false.
  force_delete = true

  # MUTABLE so `latest` can be re-pointed by a rebuild. IMMUTABLE is the better production
  # answer, because it makes a deployed digest impossible to change underneath you, and it
  # requires a real image tagging scheme to go with it.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # Basic scanning is free. It reports CVEs in the image on push and costs nothing to leave on.
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}/${each.key}"
  }
}

# Storage is billed per GB-month. Ten images is enough to roll back through a few deploys and
# small enough that the bill never appears. Without a lifecycle policy, every build ever
# pushed is retained forever.
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
