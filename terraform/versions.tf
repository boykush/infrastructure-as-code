terraform {
  required_version = ">= 1.6"

  # State is stored in HCP Terraform (app.terraform.io), as in github-management.
  #
  # IMPORTANT: set this workspace's Execution Mode to "Local" in the HCP UI, so
  # terraform runs where DIGITALOCEAN_TOKEN exists (workstation / GitHub Actions)
  # and HCP is used only for remote state storage + locking.
  cloud {
    organization = "boykush"

    workspaces {
      name = "infrastructure-as-code"
    }
  }

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}
