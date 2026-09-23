# What AWS holds is one thing: the token Claude Code Actions runs as, and the
# trust that lets each repository read it with its own OIDC identity instead of
# a repository secret. The owner account has no other workload.

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id

  # This repository, as GitHub spells it in the sub claim. Nothing in Terraform
  # knows the repository it is checked out from, so it is written out.
  terraform_repository = "infrastructure-as-code"

  claude_code_parameter_arn = "arn:aws:ssm:${var.aws_region}:${local.aws_account_id}:parameter${var.claude_code_parameter_name}"
}

# One provider for all of GitHub Actions. The thumbprint is still required by
# the API but is no longer verified for this issuer, so the well-known value is
# pinned here rather than resolved from the certificate at plan time.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trusts the repositories listed in claude_code_repositories and nothing else.
# A sub of repo:<owner>/* would hand the token to every repository the owner
# ever creates, including ones added by mistake.
data "aws_iam_policy_document" "claude_code_trust" {
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
      values   = [for repository in var.claude_code_repositories : "repo:${var.github_owner}/${repository}:*"]
    }
  }
}

# The parameter itself is deliberately not a resource here: the provider reads a
# SecureString back on every refresh, which would land the token in HCP state.
# It is written with the CLI instead — see the README's rotation steps.
data "aws_iam_policy_document" "claude_code" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.claude_code_parameter_arn]
  }
}

resource "aws_iam_role" "claude_code" {
  name               = "github-actions-claude-code"
  description        = "Read the Claude Code token from Parameter Store, for workflows in ${var.github_owner}'s repositories"
  assume_role_policy = data.aws_iam_policy_document.claude_code_trust.json
}

resource "aws_iam_role_policy" "claude_code" {
  name   = "read-claude-code-token"
  role   = aws_iam_role.claude_code.id
  policy = data.aws_iam_policy_document.claude_code.json
}

# The role CI applies with. Terraform manages the credential it runs as, so a
# change that breaks this trust can only be repaired by a local apply — the
# same exception the cluster bootstrap took.
data "aws_iam_policy_document" "terraform_trust" {
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
      values   = ["repo:${var.github_owner}/${local.terraform_repository}:*"]
    }
  }
}

# Scoped to the exact ARNs this configuration owns. A wildcard over role/* would
# let a run in this repository mint a role with AdministratorAccess attached,
# which is a shorter path to the account than anything else here.
data "aws_iam_policy_document" "terraform" {
  statement {
    effect  = "Allow"
    actions = ["iam:*"]

    resources = [
      aws_iam_openid_connect_provider.github.arn,
      aws_iam_role.claude_code.arn,
      aws_iam_role.terraform.arn,
    ]
  }
}

resource "aws_iam_role" "terraform" {
  name               = "github-actions-terraform"
  description        = "Apply this repository's AWS resources from CI"
  assume_role_policy = data.aws_iam_policy_document.terraform_trust.json
}

resource "aws_iam_role_policy" "terraform" {
  name   = "manage-github-actions-identities"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform.json
}
