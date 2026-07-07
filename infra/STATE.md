# State

OpenTofu writes a **state file** (`tofu.tfstate`, local backend — see `versions.tf`) that maps
the config to the real Coolify resources. It holds secrets in plaintext, so treat it like a
credential.

In the one-shot bootstrap model the state is **not a living artifact**. After bootstrap it is a
**recovery record you archive** — alongside `secrets.auto.tfvars`.

## After bootstrap: archive, then delete locally

Store both files in a password manager / offline vault, then remove them from the machine:

- **`secrets.auto.tfvars` first.** `app_secret` / `instance_id` exist **only** there and can
  only be *regenerated* — and a new `app_secret` invalidates live sessions and signed URLs.
  DB/Redis passwords are Coolify-generated and survive the loss of both files.
- **`tofu.tfstate` second.** Losing it is annoying, not fatal (see below) — an archived copy
  just spares you tedious work.

## Why keep the state at all

- **Teardown of a trial run** — `ddev coolify-bootstrap destroy` needs the local state.
- **Disaster recovery** — with the archived state restored, tofu re-links to the stack
  immediately. Without it, the resources still exist in Coolify and can be re-adopted one by
  one with `tofu import` (the provider supports it; see the module's
  [FINDINGS.md](https://github.com/vanWittlaer/terraform-coolify-shopware-stack/blob/main/FINDINGS.md)).
  All DSNs self-heal from module-owned credentials; the `random_password` resources import
  with the password value itself as the ID (read it from the Coolify UI).

## What this model deliberately does NOT need

Remote state backends, state locking and client-side state encryption solve "multiple people
run tofu against this environment continuously" — which is out of scope here by design: the
bootstrap runs once, from one machine, and the Coolify UI owns the environment afterwards.
