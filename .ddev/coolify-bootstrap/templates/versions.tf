#ddev-generated
terraform {
  required_version = ">= 1.7.0"

  # State lives in a LOCAL file (tofu.tfstate, not the default terraform.tfstate) — the
  # one-shot bootstrap model: provision once, then archive this file off-machine and delete
  # it locally (see STATE.md in the module repo). It holds secrets in plaintext.
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
