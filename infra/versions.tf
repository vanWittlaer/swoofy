terraform {
  required_version = ">= 1.7.0"

  # State lives in a LOCAL file (tofu.tfstate, not the default terraform.tfstate) — the
  # deliberate choice for the one-shot bootstrap model: the stack is provisioned once from
  # one machine, then the Coolify UI owns the environment. After bootstrap, archive
  # tofu.tfstate + the git-ignored secrets.auto.tfvars off-machine and delete them locally —
  # they are recovery records, not living artifacts. See STATE.md.
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
