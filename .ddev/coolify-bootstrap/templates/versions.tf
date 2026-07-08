terraform {
  required_version = ">= 1.7.0"

  # This is an EXAMPLE consuming the module at ../../ — no state backend is configured here.
  # In a real deployment, add a `backend` block (see the module's STATE.md guidance).

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
