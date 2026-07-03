provider "coolify" {
  endpoint = var.coolify_endpoint # or COOLIFY_ENDPOINT env var
  token    = var.coolify_token    # or COOLIFY_TOKEN env var
}

# AWS provider pointed at Hetzner Object Storage (S3-compatible), used only to manage
# bucket CORS. The skip_* flags disable AWS-only preflight a non-AWS endpoint can't serve;
# path-style + endpoint override match how Shopware talks to the same buckets.
provider "aws" {
  access_key = var.secrets_production.s3_access_key_id
  secret_key = var.secrets_production.s3_secret_access_key
  # The AWS provider validates `region` against real AWS regions (rejects "hel1"). With an
  # endpoint override the region is only a SigV4 signing placeholder, so we use a valid AWS
  # region string. If Hetzner rejects the signature, switch this to match its location.
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    s3 = var.production.s3.endpoint
  }
}
