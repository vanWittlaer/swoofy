# CORS on the public asset bucket. The storefront (var.*.web_domain) loads theme
# assets from the S3 origin; browsers require CORS for
# fonts (.woff2), so without this the fonts are blocked cross-origin. The bucket is
# shared across environments, so both storefront origins are allowed. Managed via the
# aws provider pointed at Hetzner Object Storage (providers.tf). The private bucket needs
# no CORS — it's never fetched by the browser.
resource "aws_s3_bucket_cors_configuration" "public" {
  bucket = var.production.s3.bucket_public

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = [var.production.web_domain, var.staging.web_domain]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}
