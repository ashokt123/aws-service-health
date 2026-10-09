locals {
  function_name = "${var.project}-api"
}

# ---------- Application package ----------

data "archive_file" "app" {
  type        = "zip"
  source_file = "${path.module}/../app/handler.py"
  output_path = "${path.module}/build/app.zip"
}

# ---------- Data: visit counter ----------

# Provisioned 1/1 stays inside the always-free allowance and throttles instead of
# billing more if the public endpoint is spammed.
resource "aws_dynamodb_table" "visits" {
  name           = "${var.project}-visits"
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

# ---------- Kill switch ----------

resource "aws_ssm_parameter" "maintenance" {
  name        = "/${var.project}/maintenance"
  description = "Set to true to make the API return 503 (outage demo)."
  type        = "String"
  value       = "false"

  # Flipped out-of-band by `make outage` / `make recover`.
  lifecycle {
    ignore_changes = [value]
  }
}

# ---------- Logs ----------

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 7
}

# ---------- IAM: least privilege ----------

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "CounterOnly"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.visits.arn]
  }
  statement {
    sid       = "KillSwitchRead"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.maintenance.arn]
  }
  statement {
    sid       = "OwnLogsOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "${local.function_name}-policy"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

# ---------- Compute ----------

resource "aws_lambda_function" "api" {
  function_name    = local.function_name
  role             = aws_iam_role.api.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 5
  filename         = data.archive_file.app.output_path
  source_code_hash = data.archive_file.app.output_base64sha256

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.visits.name
      MAINTENANCE_PARAM = aws_ssm_parameter.maintenance.name
      APP_VERSION       = substr(data.archive_file.app.output_md5, 0, 7)
    }
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.api]
}

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = var.allowed_origins
    allow_methods = ["GET"]
    max_age       = 300
  }
}

resource "aws_lambda_permission" "public_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# ---------- Alerting ----------

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# A 503 from the kill switch is a handled response, not a Lambda error, so the
# built-in Errors metric would miss it. Count 5xx log lines instead.
resource "aws_cloudwatch_log_metric_filter" "unhealthy" {
  name           = "${var.project}-5xx"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "{ ($.event = \"request\") && ($.status >= 500) }"

  metric_transformation {
    name          = "Unhealthy5xx"
    namespace     = var.project
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "${var.project}-unhealthy"
  alarm_description   = "API returned 5xx responses (outage or backend failure)."
  namespace           = var.project
  metric_name         = aws_cloudwatch_log_metric_filter.unhealthy.metric_transformation[0].name
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------- Cost guardrail ----------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ---------- Frontend config ----------

resource "local_file" "web_config" {
  filename = "${path.module}/../web/config.js"
  content  = <<-EOT
    // Generated by Terraform. Do not edit.
    window.STATUS_CONFIG = {
      endpoint: "${aws_lambda_function_url.api.function_url}health",
      region: "${var.region}",
      intervalMs: 5000,
      timeoutMs: 8000,
    };
  EOT
}
