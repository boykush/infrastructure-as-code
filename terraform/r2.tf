# Object storage for boykush/famoney's data lake: the Money Forward ME CSVs its
# ingest job downloads, and later what its pipeline derives from them. R2 over
# DO Spaces because the lake is kilobytes a month — inside R2's free tier, where
# Spaces bills a flat $5 — and because creating it takes only the Cloudflare
# token CI already holds, where a Spaces bucket would need a second, all-bucket
# S3 key as a repository secret.
#
# The job's own credential (an R2 API token scoped to this bucket) is created in
# the dashboard and handed to the cluster with kubectl, never through Terraform:
# a token resource would put its secret into the HCP state.
resource "cloudflare_r2_bucket" "famoney" {
  account_id = local.account_id
  name       = "famoney"

  # Next to the cluster in sgp1. Without a hint R2 places the bucket near the
  # caller, which for an apply from CI is a US runner.
  location = "apac"
}
