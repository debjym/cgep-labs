# main.tf
#
# Creates the AWS-side half of the OIDC trust: an IAM OIDC identity provider
# for token.actions.githubusercontent.com, and a role GitHub Actions can
# assume via sts:AssumeRoleWithWebIdentity. No long-lived AWS keys are ever
# stored in GitHub.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# Fetches GitHub's current OIDC signing certificate so the thumbprint is
# derived, not hand-copied from a doc that can drift out of date.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# Trust policy: only a workflow run triggered by a pull_request event in
# this exact repo may assume the role. GitHub's OIDC token sets the `sub`
# claim to "repo:<owner>/<repo>:pull_request" for pull_request-triggered
# runs specifically -- NOT the "ref:refs/heads/<branch>" form, which only
# appears on push/schedule/workflow_dispatch runs. Scoping to a branch ref
# here would silently never match and every AssumeRoleWithWebIdentity call
# would fail.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# Least privilege for a plan-only gate: the workflow never applies, so it
# only needs enough read access for `terraform plan` to validate provider
# config and (if state ever persists) reconcile against real resources.
data "aws_iam_policy_document" "grc_evidence_readonly" {
  statement {
    sid       = "STSCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid    = "S3ReadOnlyForPlan"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetBucketAcl",
      "s3:GetBucketLogging",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:ListBucket",
    ]
    resources = ["arn:aws:s3:::cgep-*"]
  }
}

resource "aws_iam_role_policy" "grc_evidence_readonly" {
  name   = "grc-evidence-plan-readonly"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.grc_evidence_readonly.json
}
