# The fake subscriber for the AWS load run: HTTP API, one Lambda, one DynamoDB table.
# A separate root because it is a test fixture, outside the VPC, so deliveries take the
# documented worker to NAT to internet path. Idle cost is zero.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Partial configuration: bucket and region come from bootstrap/ via just init.
  backend "s3" {
    key          = "webhook-relay/loadtest.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
      Purpose = "loadtest"
    }
  }
}

variable "aws_region" {
  description = "Region of the sink. The same region as the platform keeps latency honest."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "webhook-relay"
}

variable "reserved_concurrency" {
  description = "Concurrent sink invocations. Throttles surface as 5xx, which the worker retries."
  type        = number
  default     = null
}

locals {
  name = "${var.project_name}-sink"
}

# One item per (run, event id), so a duplicate delivery increments a counter instead of
# adding a row, and the tally is a single Query on the run.
resource "aws_dynamodb_table" "tally" {
  name         = local.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run"
  range_key    = "event_id"

  attribute {
    name = "run"
    type = "S"
  }

  attribute {
    name = "event_id"
    type = "S"
  }
}

data "archive_file" "sink" {
  type        = "zip"
  source_file = "${path.module}/sink.py"
  output_path = "${path.module}/.build/sink.zip"
}

resource "aws_iam_role" "sink" {
  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sink" {
  name = "tally"
  role = aws_iam_role.sink.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.tally.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.sink.arn}:*"
      },
    ]
  })
}

# Created here so it has a retention and is removed by destroy.
resource "aws_cloudwatch_log_group" "sink" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 3
}

resource "aws_lambda_function" "sink" {
  function_name    = local.name
  role             = aws_iam_role.sink.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "sink.handler"
  filename         = data.archive_file.sink.output_path
  source_code_hash = data.archive_file.sink.output_base64sha256
  memory_size      = 256
  timeout          = 5

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      TABLE = aws_dynamodb_table.tally.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.sink]
}

resource "aws_apigatewayv2_api" "sink" {
  name          = local.name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "sink" {
  api_id                 = aws_apigatewayv2_api.sink.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.sink.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "sink" {
  api_id    = aws_apigatewayv2_api.sink.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.sink.id}"
}

resource "aws_apigatewayv2_stage" "sink" {
  api_id      = aws_apigatewayv2_api.sink.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "sink" {
  statement_id  = "AllowHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sink.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.sink.execution_arn}/*/*"
}

output "sink_url" {
  description = "Base URL. Subscribe <sink_url>/hook?run=<label>, read <sink_url>/stats?run=<label>."
  value       = trimsuffix(aws_apigatewayv2_stage.sink.invoke_url, "/")
}
