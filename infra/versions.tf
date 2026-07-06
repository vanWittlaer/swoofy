terraform {
  required_version = ">= 1.7.0"

  # State lives in a LOCAL file (tofu.tfstate, not the default terraform.tfstate) — the
  # deliberate default for a single-operator stack. See STATE.md for the full picture; it
  # covers TWO orthogonal axes an adopter should decide separately:
  #   1. protection  — OpenTofu >=1.7 native `encryption {}` (client-side, backend-agnostic;
  #                    this is what answers "state stores every secret in plaintext")
  #   2. location    — the backend below (local / GitLab / S3-compatible)
  # To go remote, replace this block with ONE of the commented alternatives in STATE.md and
  # run `tofu init -migrate-state`. Keep an off-machine backup of tofu.tfstate + the
  # git-ignored secrets.auto.tfvars while on the local backend — they are the only copy.
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
