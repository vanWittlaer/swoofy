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

```hcl
backend "s3" {
  bucket       = "your-tfstate-bucket"
  key          = "infra/tofu.tfstate"
  region       = "us-east-1"             # a real AWS region, even for non-AWS endpoints
  use_lockfile = true                    # OpenTofu >= 1.10 native locking — no DynamoDB
  # endpoints  = { s3 = "https://..." }  # set for non-AWS (R2/MinIO/Hetzner); omit on real AWS
  # Hetzner/Ceph only: encrypt = false + skip_credentials_validation / skip_region_validation /
  #   skip_requesting_account_id / skip_metadata_api_check / skip_s3_checksum = true
}
```

Then `tofu init -migrate-state`. Credentials via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.

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
