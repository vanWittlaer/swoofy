# State backend & encryption

The stack ships with a **local** state backend (`backend "local"` in `versions.tf`,
`tofu.tfstate`). That's a deliberate, safe default for a single operator — but state holds
**every secret in plaintext** (DB/Redis passwords, `app_secret`, S3 keys, …), so before you
share operation of this stack or run it from more than one machine, decide **two things
separately**:

1. **Protection** — is the state encrypted? (OpenTofu native encryption; backend-agnostic)
2. **Location** — where does the state file live? (the backend)

These are orthogonal. Encryption is the one that matters most, and it works even on the
current local file — so treat it as the first move, not something you get "for free" by going
remote.

---

## Axis 1 — Protection: OpenTofu native state encryption (recommended, do this first)

OpenTofu **≥ 1.7** (already this stack's floor, see the module's [COMPATIBILITY.md](https://github.com/vanWittlaer/terraform-coolify-shopware-stack/blob/main/COMPATIBILITY.md)) encrypts state **and**
plan files **client-side, before they touch any backend**. This is the direct answer to
"state stores every secret in plaintext" — and because it happens client-side it is
**independent of the backend**, so it also sidesteps object-storage encryption quirks (e.g.
Hetzner/Ceph rejecting bucket-side SSE — see Axis 2).

Add to `versions.tf` inside the `terraform {}` block:

```hcl
terraform {
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase # >= 16 chars; NEVER commit it
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true # refuse to read/write UNencrypted state
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
```

Passphrase handling — the encryption block is evaluated **before** state/providers exist, so it
may reference `var`/`local` but **not** data sources or provider functions:

- **Passphrase (simplest):** declare `variable "state_passphrase" {}` and pass it out-of-band —
  `TF_VAR_state_passphrase=…` in the environment, never in a committed `*.tfvars`. Or set the
  whole config via the `TF_ENCRYPTION` env var and drop the block from code entirely.
- **KMS (best for teams/CI):** swap the `pbkdf2` key provider for **`aws_kms`** / `gcp_kms` /
  `openbao` so there's no shared passphrase to distribute — the KMS handles key material.

Rollout is staged (OpenTofu supports it): first apply **without** `enforced` (writes encrypted,
still reads plaintext) to migrate the existing file, then set `enforced = true`. **If you lose
the passphrase/key, the state is unrecoverable** — back up the key material like a root secret,
and remember the coolify provider (v0.1.7) supports `tofu import` as a last-resort rebuild path.

---

## Axis 2 — Location: the backend

`local` is the shipped default. To go remote, replace the `backend "local"` block in
`versions.tf` with **one** of the following, then `tofu init -migrate-state`. Layer Axis 1 on
top of whichever you pick — a remote backend is not a substitute for encryption.

### Option A — GitLab-managed state (recommended if you use GitLab)

This repo already carries a GitLab pipeline (`.gitlab-ci.yml`). GitLab ships a managed
OpenTofu/Terraform state backend (an HTTP backend with built-in locking, encryption-at-rest and
RBAC) — **free on gitlab.com**, no extra cloud infra, and no shared-object-storage isolation
problem. It couples state to GitLab, which for a GitLab-CI'd project is usually fine.

```hcl
backend "http" {
  address        = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/terraform/state/infra"
  lock_address   = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/terraform/state/infra/lock"
  unlock_address = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/terraform/state/infra/lock"
  lock_method    = "POST"
  unlock_method  = "DELETE"
  retry_wait_min = 5
}
```

Auth is **not** in code: supply `TF_HTTP_USERNAME` + `TF_HTTP_PASSWORD` (a PAT with `api`
scope locally, or `gitlab-ci-token` + `CI_JOB_TOKEN` in CI) via the environment or
`-backend-config`.

### Option B — S3-compatible backend (`backend "s3"`)

Works against AWS S3, Cloudflare R2, MinIO — and Hetzner Object Storage, with caveats we hit
firsthand (a full Hetzner remote-state migration was built and then rolled back on this project;
the config below encodes what was learned). AWS/R2/MinIO adopters won't need most of the skip
flags.

```hcl
backend "s3" {
  bucket    = "your-tfstate-bucket"
  key       = "infra/tofu.tfstate"
  region    = "hel1" # Hetzner: must be a real location value, not "us-east-1"
  endpoints = { s3 = "https://hel1.your-objectstorage.com" }

  use_lockfile = true # OpenTofu >=1.10 native S3 locking — NO DynamoDB needed (verified on Hetzner)

  # --- Hetzner/Ceph-specific (drop these on AWS S3) ---
  encrypt                     = false # Ceph rejects SSE with HTTP 400 — use Axis 1 encryption INSTEAD
  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_s3_checksum            = true
}
```

Credentials via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (env or `-backend-config`), never
in code. **Hetzner caveat:** its S3 keys are **project-wide**, so a dedicated state bucket is
*not* truly isolated from your data buckets — anyone with the state key can also reach media.
This is exactly why Axis-1 client-side encryption matters more than the bucket choice here.

### Option C — keep local

Fine for a single operator. Discipline: keep an **off-machine backup** of `tofu.tfstate` and the
git-ignored `secrets.auto.tfvars` (the only copies), and lean on `tofu import` (provider v0.1.7)
to rebuild state if the file is ever lost.

---

## TL;DR

- **Do Axis 1 (native encryption) regardless of backend** — it's the real fix for plaintext state.
- **Prefer GitLab-managed state** for the backend if you're on GitLab; otherwise S3-compatible.
- On Hetzner, `encrypt=false` + client-side encryption; the state key is project-wide, so treat
  it as sensitive as the data keys.
