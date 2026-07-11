# variables.tf

variable "aws_region" {
  description = "Region the IAM OIDC provider/role are created in (IAM is global, but the provider resource still needs a region for the aws provider block)."
  type        = string
  default     = "ca-central-1"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume this role, as owner/name."
  type        = string
  default     = "debjym/cgep-labs"
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes via OIDC."
  type        = string
  default     = "github-actions-grc-evidence"
}
