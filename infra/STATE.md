# State

OpenTofu keeps a **state file** that maps your config to the real Coolify resources. It holds
secrets in plaintext, so treat it like a credential.

## Default: local state + backup (recommended for a single operator)

The stack ships with `backend "local"` (`tofu.tfstate` beside the config) — the simplest thing
that works:

- Keep `tofu.tfstate` on a machine you control and **back it up off-machine**. It and the
  git-ignored `secrets.auto.tfvars` are the only copies.
- If you lose it, you can rebuild it — the coolify provider supports `tofu import`, so the stack
  can be re-adopted resource by resource (see `FINDINGS.md`).

No backend service, no encryption ceremony. For one person this is genuinely fine — stop here.

### If you lose state

Losing `tofu.tfstate` is annoying, not fatal — the resources still exist in Coolify:

- **Rebuild state** by re-adopting each resource with `tofu import` (the provider supports it;
  see `FINDINGS.md`). MariaDB DSNs self-heal from the DB's attributes; **reseed the two Redis
  URLs** via `redis_url_seed` (paste from the Coolify UI), since `internal_db_url` reads null on
  import.
- **`secrets.auto.tfvars` is the file you truly cannot lose.** `app_secret` / `instance_id` live
  only there and can only be *regenerated* — and a new `app_secret` invalidates live sessions and
  signed URLs. DB/Redis passwords are Coolify-generated and survive state loss.

**Backup priority: `secrets.auto.tfvars` first, `tofu.tfstate` second.**

## Going remote (only if state is shared across people/machines)

If more than one person or machine runs `tofu`, put state in an **S3-compatible bucket** (AWS S3,
Cloudflare R2, MinIO, Hetzner — you likely already have S3 for media). Replace the `backend
"local"` block in your root `versions.tf` with:

On **real AWS S3** it's minimal:

```hcl
backend "s3" {
  bucket       = "your-tfstate-bucket"
  key          = "infra/tofu.tfstate"
  region       = "eu-central-1"          # your bucket's real AWS region
  use_lockfile = true                    # OpenTofu >= 1.10 native locking — no DynamoDB
}
```

On **Hetzner Object Storage** (Ceph-based S3) it needs more, because Ceph doesn't implement the
AWS-only preflight the `s3` backend assumes. Define exactly this:

```hcl
backend "s3" {
  bucket    = "your-tfstate-bucket"
  key       = "infra/tofu.tfstate"
  region    = "hel1"                                         # your Hetzner LOCATION (hel1/fsn1/nbg1)
  endpoints = { s3 = "https://hel1.your-objectstorage.com" } # the matching location endpoint

  use_lockfile = true    # native conditional-write locking — verified working on Hetzner
  encrypt      = false   # Ceph rejects server-side encryption (SSE) with HTTP 400
  use_path_style = true  # Hetzner serves path-style URLs (bucket in the path)

  skip_credentials_validation = true # no AWS STS to validate against
  skip_requesting_account_id  = true # no IAM GetCallerIdentity
  skip_region_validation      = true # "hel1" isn't a real AWS region name
  skip_metadata_api_check     = true # no EC2 instance-metadata endpoint
  skip_s3_checksum            = true # Ceph rejects the SDK's newer default checksum trailer
}
```

Each `skip_*` turns off an AWS-specific call/validation Hetzner can't answer; `encrypt = false`
is required (SSE 400s), and `use_path_style` matches how Hetzner addresses buckets.

Then `tofu init -migrate-state`. Credentials via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.

> On Hetzner, S3 keys are **project-wide** — a dedicated state bucket is *not* isolated from your
> data buckets, and SSE is off. So if this state must be encrypted at rest, use the client-side
> **encryption** block below rather than relying on the bucket.

> **GitHub has no state backend.** A managed Terraform state backend is a *GitLab* feature;
> GitHub offers none. "State on GitHub" would mean committing the state file to a repo — only safe
> if encrypted, and with no locking. Prefer local+backup or S3.

## Optional: encrypt the state

Only needed if state lives somewhere others could read it (a shared bucket, or a repo). OpenTofu
≥ 1.7 encrypts it client-side — add this to the `terraform {}` block and pass the passphrase
out-of-band (`TF_VAR_state_passphrase=…`, never committed):

```hcl
encryption {
  key_provider "pbkdf2" "s" { passphrase = var.state_passphrase } # >= 16 chars
  method "aes_gcm" "s" { keys = key_provider.pbkdf2.s }
  state { method = method.aes_gcm.s }
  plan  { method = method.aes_gcm.s }
}
```

Apply it once un-`enforced`, then add `enforced = true` to each block. **Lose the passphrase and
the state is unrecoverable** — back it up like a root secret. (Teams: swap `pbkdf2` for the
`aws_kms` key provider so there's no shared passphrase to distribute.)
