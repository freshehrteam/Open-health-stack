# ============================================================================
# Root: Scaleway (k3s on Scaleway Instances) — Layer 3, per-cloud root.
# Wires the scaleway-* provisioning modules + the shared k8s-apps module (which
# installs add-ons and the health-stack Helm chart). Provider-agnostic parts live
# in k8s-apps and charts/health-stack; Scaleway specifics are the four scaleway-*
# modules.
#
# THREE-PHASE APPLY (kubeconfig must exist before the k8s/helm providers connect,
# and the CCM must untaint nodes before the app chart's PVCs can bind):
#   terraform apply -var 'install_apps=false' -var 'install_cloud_integration=false'
#     # phase 1: cluster only — no kubeconfig yet, so no k8s/helm provider calls
#   terraform apply -var 'install_apps=false'
#     # phase 2: cloud-controller-manager + CSI driver — untaints nodes, no domain needed yet
#   terraform apply
#     # phase 3: add-ons + the health-stack chart (needs a real domain)
# ============================================================================

module "network" {
  source = "../../modules/scaleway-network"

  name        = var.cluster_name
  region      = var.region
  subnet_cidr = var.subnet_cidr
}

module "cluster" {
  source = "../../modules/scaleway-cluster"

  name                = var.cluster_name
  zone                = var.zone
  image               = var.image
  control_plane_type  = var.control_plane_type
  agent_type          = var.agent_type
  agent_count         = var.agent_count
  ssh_public_key_path = var.ssh_public_key_path
  admin_ssh_cidrs     = var.admin_ssh_cidrs
  k3s_api_cidrs       = var.k3s_api_cidrs
  k3s_version         = var.k3s_version

  private_network_id = module.network.private_network_id
  network_cidr       = var.network_cidr

  kubeconfig_path = var.kubeconfig_path
}

module "lb" {
  source = "../../modules/scaleway-lb"

  name               = var.cluster_name
  private_network_id = module.network.private_network_id

  # Scaleway has no label-selector target — backends take the actual node
  # private IPs, only known once the cluster module has been applied.
  target_ips = concat(
    [module.cluster.control_plane_private_ip],
    module.cluster.agent_private_ips,
  )

  http_node_port  = 30080
  https_node_port = 30443
}

# ── Generated credentials ─────────────────────────────────────────────────────
# Every database/API password is generated here rather than shipped as a default,
# so no well-known credential is ever exposed on a public endpoint.
#
# `special = false` on purpose: these values are interpolated into JDBC URLs, YAML
# and SQL string literals, where punctuation causes quoting/escaping bugs. 32
# alphanumeric characters is ~190 bits — ample.
#
# ⚠ These land in terraform.tfstate in PLAINTEXT (a documented Terraform
# behaviour — `sensitive` only masks CLI output). State lives in the remote
# Scaleway Object Storage backend (see versions.tf) — treat that bucket as a
# secret store: anyone who can read it has every password.
# Retrieve them with:  terraform output -json credentials | jq
resource "random_password" "pg_superuser" {
  length  = 32
  special = false
}
resource "random_password" "ehrbase_db" {
  length  = 32
  special = false
}
resource "random_password" "ehrbase_db_admin" {
  length  = 32
  special = false
}
resource "random_password" "hapi_db" {
  length  = 32
  special = false
}
resource "random_password" "openfhir_db" {
  length  = 32
  special = false
}
# ── Keycloak / OAuth2 credentials ────────────────────────────────────────────
resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}
resource "random_password" "keycloak_db" {
  length  = 32
  special = false
}
# client_credentials service account for external API callers (`terraform
# output -raw kc_api_client_secret` to retrieve).
resource "random_password" "kc_api_client" {
  length  = 32
  special = false
}
# client_credentials service account for the HAPI interceptor's HAPI→EHRbase hop.
resource "random_password" "kc_hapi_svc" {
  length  = 32
  special = false
}
resource "random_password" "oauth2_proxy_client" {
  length  = 32
  special = false
}
# MUST be exactly 16, 24 or 32 bytes — oauth2-proxy rejects other lengths.
resource "random_password" "oauth2_proxy_cookie" {
  length  = 32
  special = false
}

# Scaleway-specific cloud-provider integration (CCM + CSI). Gated on its own
# flag, not install_apps: it only needs the kubeconfig (module.cluster), not a
# domain, and nodes stay tainted node.cloudprovider.kubernetes.io/uninitialized
# (unschedulable) until it runs — so it belongs in its own phase 2, ahead of
# the domain-dependent health-stack chart.
module "scaleway_cloud_integration" {
  source = "../../modules/scaleway-cloud-integration"
  count  = var.install_cloud_integration ? 1 : 0

  scw_access_key  = var.scw_access_key
  scw_secret_key  = var.scw_secret_key
  scw_project_id  = var.scw_project_id
  scw_region      = var.region
  scw_zone        = var.zone
  kubeconfig_path = var.kubeconfig_path

  depends_on = [module.cluster]
}

# Cluster add-ons (ingress-nginx + cert-manager) + the health-stack chart.
# Provider-agnostic — the Scaleway-specific cloud integration above is a
# separate module so this one doesn't need to change per cloud.
module "apps" {
  source = "../../modules/k8s-apps"
  count  = var.install_apps ? 1 : 0

  kubeconfig_path   = var.kubeconfig_path
  domain            = var.domain
  letsencrypt_email = var.letsencrypt_email

  pg_superuser_password     = random_password.pg_superuser.result
  ehrbase_db_password       = random_password.ehrbase_db.result
  ehrbase_db_admin_password = random_password.ehrbase_db_admin.result
  hapi_db_password          = random_password.hapi_db.result
  openfhir_db_password      = random_password.openfhir_db.result

  keycloak_admin_password    = random_password.keycloak_admin.result
  keycloak_db_password       = random_password.keycloak_db.result
  kc_api_client_secret       = random_password.kc_api_client.result
  kc_hapi_svc_secret         = random_password.kc_hapi_svc.result
  oauth2_proxy_client_secret = random_password.oauth2_proxy_client.result
  oauth2_proxy_cookie_secret = random_password.oauth2_proxy_cookie.result

  http_node_port       = 30080
  https_node_port      = 30443
  ingress_service_type = "NodePort"

  chart_path        = "${path.module}/../../../charts/health-stack"
  chart_values_file = "${path.module}/../../../charts/health-stack/values-scaleway.yaml"

  # module.cluster: needs the kubeconfig to exist. module.scaleway_cloud_integration:
  # needs the CSI driver up before the chart's PVCs try to bind.
  depends_on = [module.cluster, module.scaleway_cloud_integration]
}
