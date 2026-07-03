terraform {
  required_version = ">= 1.7.0"

  # Local state, named tofu.tfstate (not the default terraform.tfstate). For a real
  # project, swap this for a shared/remote backend so state isn't single-machine.
  backend "local" {
    path = "tofu.tfstate"
  }

  required_providers {
    coolify = {
      # Verify the exact source at `tofu init`. OpenTofu registry / GitHub org is
      # coolify-terraform; the provider's own docs sometimes write coolify-io/coolify.
      source  = "coolify-terraform/coolify"
      version = "~> 0.1.7"
    }
    # Used ONLY to manage bucket CORS on the S3-compatible object storage (Hetzner).
    # The buckets themselves are created outside tofu.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
