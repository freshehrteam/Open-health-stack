terraform {
  required_version = ">= 1.6.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.45"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Real remote backend, NOT optional here (unlike envs/hetzner's local-state
  # default): this cluster is meant to keep running after a sandbox session
  # ends, so state must live somewhere durable and outside any one container.
  # Scaleway Object Storage is S3-compatible, so Terraform's built-in "s3"
  # backend works unmodified.
  #
  # The bucket must already exist — this backend block does not create it
  # (`scw object bucket create freshehr-tfstate-scaleway --region=nl-ams`, or
  # via the Scaleway console). Credentials come from AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY (Scaleway's access/secret key pair works directly as
  # an S3-compatible credential pair) — export them before `terraform init`:
  #   export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
  #   export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
  backend "s3" {
    bucket                      = "freshehr-tfstate-scaleway"
    key                         = "health-stack/scaleway.tfstate"
    region                      = "nl-ams"
    endpoints                   = { s3 = "https://s3.nl-ams.scw.cloud" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    # Virtual-hosted-style (<bucket>.s3.nl-ams.scw.cloud) is a different host
    # than s3.nl-ams.scw.cloud, so it needs its own egress allowlist entry.
    # Path-style avoids that entirely.
    use_path_style = true
  }
}
