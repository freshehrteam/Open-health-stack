provider "scaleway" {
  access_key = var.scw_access_key
  secret_key = var.scw_secret_key
  project_id = var.scw_project_id
  region     = var.region
  zone       = var.zone
}

# ── Kubernetes / Helm providers ──────────────────────────────────────────────
# Read the kubeconfig the scaleway-cluster module fetches from the k3s control-plane.
# Guard with a fallback so a clean workspace (kubeconfig not yet written) still plans.
locals {
  kubeconfig_exists = fileexists(var.kubeconfig_path)
}

provider "kubernetes" {
  config_path = local.kubeconfig_exists ? var.kubeconfig_path : null
}

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_exists ? var.kubeconfig_path : null
  }
}
