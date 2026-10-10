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

  claude_code_parameter_arn = "arn:aws:ssm:${var.aws_region}:${local.aws_account_id}:parameter${var.claude_code_parameter_name}"

  # Both are paths, so what a policy names is everything under them.
  cluster_secrets_parameters_arn             = "arn:aws:ssm:${var.aws_region}:${local.aws_account_id}:parameter${var.cluster_secrets_parameter_path}/*"
  external_secrets_credential_parameters_arn = "arn:aws:ssm:${var.aws_region}:${local.aws_account_id}:parameter${var.external_secrets_credential_parameter_path}/*"

  # The roles below are named here rather than read off the resources, because
  # the policy CI applies with has to name them before they exist — see the
  # ordering note there. Same construction as the parameter ARNs above.
  external_secrets_role_name = "github-actions-external-secrets"
  terraform_plan_role_name   = "github-actions-terraform-plan"
  external_secrets_user_name = "external-secrets"
  github_app_role_names      = { for app in var.github_apps : app.name => "github-actions-github-app-${app.name}" }

  # GitHub puts immutable ids in the sub claim for repositories created after
  # 2026-07-15, and for older ones once they opt in. Both spellings are listed
  # so a repository's age, and any later opt-in, never breaks the trust.
  claude_code_subjects = flatten([
    for repository in var.claude_code_repositories : [
      "repo:${var.github_owner}/${repository}:*",
      "repo:${var.github_owner}@${var.github_owner_id}/${repository}@*:*",
    ]
  ])

  # Runs of main only. Both roles that share this can write — the apply and the
  # operator's access key — and a run on any other ref executes that branch's
  # own copy of the workflows. Pull requests plan with the role below instead.
  this_repository_subjects = [
    "repo:${var.github_owner}/${local.terraform_repository}:ref:refs/heads/main",
    "repo:${var.github_owner}@${var.github_owner_id}/${local.terraform_repository}@*:ref:refs/heads/main",
  ]

  # Runs a pull request wakes, and nothing else: a push to a branch carries
  # that branch's ref instead, and a run of main carries main's.
  this_repository_pull_request_subjects = [
    "repo:${var.github_owner}/${local.terraform_repository}:pull_request",
    "repo:${var.github_owner}@${var.github_owner_id}/${local.terraform_repository}@*:pull_request",
  ]

  # What a trusted sub ends in after the repository. A run of main carries its
  # ref; one a pull request wakes carries :pull_request, and a push to any other
  # branch that branch's ref, so neither matches a main-only app.
  github_app_refs = { for app in var.github_apps : app.name => app.main_only ? "ref:refs/heads/main" : "*" }

  # Both spellings again, this time grouped by the app each repository may sign
  # as. A repository can appear under more than one app; the reverse — one role
  # over several apps — is what the grouping exists to prevent.
  github_app_subjects = {
    for app in var.github_apps : app.name => flatten([
      for repository in app.repositories : [
        "repo:${var.github_owner}/${repository}:${local.github_app_refs[app.name]}",
        "repo:${var.github_owner}@${var.github_owner_id}/${repository}@*:${local.github_app_refs[app.name]}",
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

  # CI runs as a role whose policy this same apply widens, so the widening has
  # to land first. Without this the graph is free to try the key beforehand,
  # and kms:CreateKey comes back AccessDenied.
  depends_on = [aws_iam_role_policy.terraform]

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

  # Same ordering as the keys: iam:CreateRole on this ARN is granted by the
  # policy update in this apply.
  depends_on = [aws_iam_role_policy.terraform]

  name               = local.github_app_role_names[each.key]
  description        = "Sign the ${each.key} GitHub App's JWT with its KMS key"
  assume_role_policy = data.aws_iam_policy_document.github_app_trust[each.key].json
}

resource "aws_iam_role_policy" "github_app" {
  for_each = aws_iam_role.github_app

  name   = "sign-github-app-jwt"
  role   = each.value.id
  policy = data.aws_iam_policy_document.github_app[each.key].json
}

# What External Secrets Operator reads Parameter Store as. A user with an access
# key, the one long-lived credential here, because nothing shorter is on offer:
# the cluster signs its service account tokens as an in-cluster name
# (kubernetes.default.svc.cluster.local) that AWS cannot reach to verify, so no
# pod can assume a role. All the key opens is reading the cluster's own Secrets.
resource "aws_iam_user" "external_secrets" {
  depends_on = [aws_iam_role_policy.terraform]

  name = local.external_secrets_user_name
}

# The parameters are no more resources here than the Claude Code token is, and
# for the same reason. Among them is the one app key KMS cannot hold: Argo CD
# Image Updater signs its own JWTs inside the cluster, so it needs the PEM.
data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.cluster_secrets_parameters_arn]
  }
}

resource "aws_iam_user_policy" "external_secrets" {
  name   = "read-cluster-secrets"
  user   = aws_iam_user.external_secrets.name
  policy = data.aws_iam_policy_document.external_secrets.json
}

# The access key is not a resource either: aws_iam_access_key would put the
# secret half in HCP state. `mise run external-secrets:key` mints it into
# Parameter Store, and a workflow of this repository carries it into the
# cluster with its own OIDC identity — the one Secret the operator cannot
# fetch for itself.
data "aws_iam_policy_document" "external_secrets_credential_trust" {
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

data "aws_iam_policy_document" "external_secrets_credential" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.external_secrets_credential_parameters_arn]
  }
}

resource "aws_iam_role" "external_secrets_credential" {
  depends_on = [aws_iam_role_policy.terraform]

  name               = local.external_secrets_role_name
  description        = "Read the operator's access key from Parameter Store, for this repository's External Secrets Credential workflow"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_credential_trust.json
}

resource "aws_iam_role_policy" "external_secrets_credential" {
  name   = "read-external-secrets-credential"
  role   = aws_iam_role.external_secrets_credential.id
  policy = data.aws_iam_policy_document.external_secrets_credential.json
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

    # The identities this apply is about to create are named as strings:
    # reading the ARNs off the resources would order this policy after them, and
    # creating them is exactly what it grants. The rest are existing resources.
    resources = concat([
      aws_iam_openid_connect_provider.github.arn,
      aws_iam_role.claude_code.arn,
      aws_iam_role.terraform.arn,
      "arn:aws:iam::${local.aws_account_id}:role/${local.external_secrets_role_name}",
      "arn:aws:iam::${local.aws_account_id}:role/${local.terraform_plan_role_name}",
      "arn:aws:iam::${local.aws_account_id}:user/${local.external_secrets_user_name}",
      ], [
      for name in values(local.github_app_role_names) :
      "arn:aws:iam::${local.aws_account_id}:role/${name}"
    ])
  }

  # Neither of these names a resource: the key does not exist yet when it is
  # created, and an alias is only ever found by listing.
  statement {
    effect    = "Allow"
    actions   = ["kms:CreateKey", "kms:ListAliases"]
    resources = ["*"]
  }

  # A key's ARN is not knowable in advance the way a role's name is, so this is
  # held to the account's own keys — and to managing them: kms:Sign,
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

# The role a pull request plans with. A plan runs the branch's own copy of the
# workflow, so whatever role it assumes is handed to anyone who can push a
# branch here; this one can read what the apply manages and change nothing.
data "aws_iam_policy_document" "terraform_plan_trust" {
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
      values   = local.this_repository_pull_request_subjects
    }
  }
}

# What a refresh reads, and no more. IAM reads are open across the account,
# which holds no other workload; the KMS reads stay on the account's own keys,
# and none of them reaches a key's material or a signature.
data "aws_iam_policy_document" "terraform_plan" {
  statement {
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*", "kms:ListAliases"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
    ]

    resources = [
      "arn:aws:kms:${var.aws_region}:${local.aws_account_id}:key/*",
    ]
  }
}

resource "aws_iam_role" "terraform_plan" {
  # iam:CreateRole on this ARN is granted by the policy update in this apply.
  depends_on = [aws_iam_role_policy.terraform]

  name               = local.terraform_plan_role_name
  description        = "Plan this repository's AWS resources from a pull request, read-only"
  assume_role_policy = data.aws_iam_policy_document.terraform_plan_trust.json
}

resource "aws_iam_role_policy" "terraform_plan" {
  name   = "read-github-actions-identities"
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.terraform_plan.json
}
