# What AWS holds is the credentials this owner's workflows would otherwise keep
# in repository secrets: the token Claude Code Actions runs as, the GitHub App
# private keys, and the trust that lets a repository reach its own with the OIDC
# identity of the run. The account has no other workload.

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id

  # This repository, as GitHub spells it in the sub claim. Nothing in Terraform
  # knows the repository it is checked out from, so it is written out.
  terraform_repository = "infrastructure-as-code"

  claude_code_parameter_arn   = "arn:aws:ssm:${var.aws_region}:${local.aws_account_id}:parameter${var.claude_code_parameter_name}"
  image_updater_parameter_arn = "arn:aws:ssm:${var.aws_region}:${local.aws_account_id}:parameter${var.image_updater_parameter_name}"

  # GitHub puts immutable ids in the sub claim for repositories created after
  # 2026-07-15, and for older ones once they opt in. Both spellings are listed
  # so a repository's age, and any later opt-in, never breaks the trust.
  claude_code_subjects = flatten([
    for repository in var.claude_code_repositories : [
      "repo:${var.github_owner}/${repository}:*",
      "repo:${var.github_owner}@${var.github_owner_id}/${repository}@*:*",
    ]
  ])

  this_repository_subjects = [
    "repo:${var.github_owner}/${local.terraform_repository}:*",
    "repo:${var.github_owner}@${var.github_owner_id}/${local.terraform_repository}@*:*",
  ]

  # Both spellings again, this time grouped by the app each repository may sign
  # as. A repository can appear under more than one app; the reverse — one role
  # over several apps — is what the grouping exists to prevent.
  github_app_subjects = {
    for app in var.github_apps : app.name => flatten([
      for repository in app.repositories : [
        "repo:${var.github_owner}/${repository}:*",
        "repo:${var.github_owner}@${var.github_owner_id}/${repository}@*:*",
      ]
    ])
  }
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
      values   = local.claude_code_subjects
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

# A GitHub App private key never expires, so a copy in a repository secret mints
# installation tokens for as long as the app keeps that key. KMS takes the key
# GitHub generated (origin EXTERNAL) and never hands it back: what a workflow
# reaches is a signature over the app's JWT, and an IAM policy bounds that.
resource "aws_kms_external_key" "github_app" {
  for_each = { for app in var.github_apps : app.name => app }

  description = "Private key of the ${each.key} GitHub App"

  # A GitHub App JWT is RS256, which fixes both of these.
  key_spec  = "RSA_2048"
  key_usage = "SIGN_VERIFY"

  # key_material_base64 is deliberately left out: handing the key to Terraform
  # would land it in HCP state, which is the copy this whole arrangement
  # removes. The key is PendingImport — and unusable — until the material is
  # imported with the CLI (`mise run app:key-import`), and enabled follows from
  # that import rather than from anything written here.
}

# Workflows name the key through its alias, so replacing the material — a new
# key, since KMS binds one import per key forever — leaves them untouched.
resource "aws_kms_alias" "github_app" {
  for_each = aws_kms_external_key.github_app

  # The resource id of an external key is the key id itself; there is no
  # key_id attribute on it, unlike aws_kms_key.
  name          = "alias/github-app-${each.key}"
  target_key_id = each.value.id
}

# One role per app. A single role over every key would let a run in
# renovate-runner sign as the app that administers every repository.
data "aws_iam_policy_document" "github_app_trust" {
  for_each = local.github_app_subjects

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
      values   = each.value
    }
  }
}

data "aws_iam_policy_document" "github_app" {
  for_each = aws_kms_external_key.github_app

  statement {
    effect    = "Allow"
    actions   = ["kms:Sign"]
    resources = [each.value.arn]

    # The algorithm a GitHub App JWT is signed with. Pinning it keeps the role
    # to that one use of the key rather than to signing in general.
    condition {
      test     = "StringEquals"
      variable = "kms:SigningAlgorithm"
      values   = ["RSASSA_PKCS1_V1_5_SHA_256"]
    }
  }
}

resource "aws_iam_role" "github_app" {
  for_each = local.github_app_subjects

  name               = "github-actions-github-app-${each.key}"
  description        = "Sign the ${each.key} GitHub App's JWT with its KMS key"
  assume_role_policy = data.aws_iam_policy_document.github_app_trust[each.key].json
}

resource "aws_iam_role_policy" "github_app" {
  for_each = aws_iam_role.github_app

  name   = "sign-github-app-jwt"
  role   = each.value.id
  policy = data.aws_iam_policy_document.github_app[each.key].json
}

# The one app KMS cannot hold: Argo CD Image Updater signs its own JWTs inside
# the cluster, so what it is given has to be the PEM. Parameter Store keeps the
# single copy and the credential workflow reads it with this repository's OIDC
# identity, which is what takes it out of a repository secret.
data "aws_iam_policy_document" "image_updater_trust" {
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
      values   = local.this_repository_subjects
    }
  }
}

data "aws_iam_policy_document" "image_updater" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.image_updater_parameter_arn]
  }
}

resource "aws_iam_role" "image_updater" {
  name               = "github-actions-image-updater"
  description        = "Read the Image Updater app's private key from Parameter Store, for this repository's credential workflow"
  assume_role_policy = data.aws_iam_policy_document.image_updater_trust.json
}

resource "aws_iam_role_policy" "image_updater" {
  name   = "read-image-updater-app-key"
  role   = aws_iam_role.image_updater.id
  policy = data.aws_iam_policy_document.image_updater.json
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
      values   = local.this_repository_subjects
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

    resources = concat([
      aws_iam_openid_connect_provider.github.arn,
      aws_iam_role.claude_code.arn,
      aws_iam_role.image_updater.arn,
      aws_iam_role.terraform.arn,
    ], values(aws_iam_role.github_app)[*].arn)
  }

  # Neither of these names a resource: the key does not exist yet when it is
  # created, and an alias is only ever found by listing.
  statement {
    effect    = "Allow"
    actions   = ["kms:CreateKey", "kms:ListAliases"]
    resources = ["*"]
  }

  # The key ARNs are known only after creation, so scoping to them would order
  # this policy behind the keys and leave the first apply unable to create them.
  # Held to the account's own keys instead, and to managing them: kms:Sign,
  # kms:ImportKeyMaterial and kms:PutKeyPolicy are all absent, so a run here can
  # neither sign as an app, replace what a key holds, nor open one to itself.
  statement {
    effect = "Allow"

    actions = [
      "kms:CancelKeyDeletion",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:DescribeKey",
      "kms:DisableKey",
      "kms:EnableKey",
      "kms:GetKeyPolicy",
      "kms:ListResourceTags",
      "kms:ScheduleKeyDeletion",
      "kms:UpdateAlias",
    ]

    resources = [
      "arn:aws:kms:${var.aws_region}:${local.aws_account_id}:alias/*",
      "arn:aws:kms:${var.aws_region}:${local.aws_account_id}:key/*",
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
