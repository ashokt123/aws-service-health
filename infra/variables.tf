variable "region" {
  description = "AWS Region. New-experience AWS projects are locked to one Region."
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = "AWS CLI profile used for local deploys."
  type        = string
  default     = "multicloud"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "service-health"
}

variable "alert_email" {
  description = "Email address for alarm and budget notifications."
  type        = string
}

variable "allowed_origins" {
  description = "Browser origins allowed to call the API (CORS)."
  type        = list(string)
  default     = ["http://localhost:8000"]
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget that triggers an email alert."
  type        = string
  default     = "1"
}
