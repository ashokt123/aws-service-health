output "health_url" {
  description = "Public health endpoint."
  value       = "${aws_lambda_function_url.api.function_url}health"
}

output "kill_switch_parameter" {
  description = "SSM parameter that toggles maintenance mode."
  value       = aws_ssm_parameter.maintenance.name
}

output "alarm_name" {
  value = aws_cloudwatch_metric_alarm.unhealthy.alarm_name
}
