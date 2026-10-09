terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# ── Inputs ────────────────────────────────────────────────────────────────────
variable "kubeconfig_path" { type = string }
variable "domain" { type = string }
variable "letsencrypt_email" { type = string }

variable "http_node_port" {
  type    = number
  default = 30080
}
variable "https_node_port" {
  type    = number
  default = 30443
}

# Path to the health-stack Helm chart (this repo's charts/health-stack).
variable "chart_path" { type = string }

# Values file passed to the chart (charts/health-stack/values-hetzner.yaml).
variable "chart_values_file" { type = string }

# ── Generated credentials (from the root module's random_password resources) ───
variable "pg_superuser_password" {
  type      = string
  sensitive = true
}
variable "ehrbase_db_password" {
  type      = string
  sensitive = true
}
variable "ehrbase_db_admin_password" {
  type      = string
  sensitive = true
}
variable "hapi_db_password" {
  type      = string
  sensitive = true
}
variable "openfhir_db_password" {
  type      = string
  sensitive = true
}
# ── Keycloak / OAuth2 (edge auth on /fhir via oauth2-proxy; EHRbase and the
# openFHIR engine validate natively). Client secrets are substituted into the
# realm import AND handed to each consumer by the chart, so realm and consumers
# always agree.
variable "keycloak_admin_user" {
  type    = string
  default = "admin"
}
variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}
variable "keycloak_db_password" {
  type      = string
  sensitive = true
}
variable "kc_api_client_secret" {
  type      = string
  sensitive = true
}
variable "kc_hapi_svc_secret" {
  type      = string
  sensitive = true
}
variable "oauth2_proxy_client_secret" {
  type      = string
  sensitive = true
}
# Must be exactly 16, 24 or 32 bytes (oauth2-proxy cookie encryption).
variable "oauth2_proxy_cookie_secret" {
  type      = string
  sensitive = true
}
# ingress-nginx Service type. NodePort on Hetzner — the hcloud LB fronts the pinned
# NodePorts below.
variable "ingress_service_type" {
  type    = string
  default = "NodePort"
}

# ============================================================================
# Cluster add-ons: ingress-nginx + cert-manager
# ============================================================================
# Cloud-provider CCM/CSI integration is deliberately NOT here — it lives in a
# per-cloud module (e.g. hcloud-cloud-integration, scaleway-cloud-integration)
# wired in by the env root, with `module.apps`'s depends_on pointing at it.
# This module stays the same on every cloud.

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  atomic           = true

  set {
    name  = "controller.service.type"
    value = var.ingress_service_type
  }

  # NodePort pinning only matters on hetzner (the hcloud LB targets these ports).
  dynamic "set" {
    for_each = var.ingress_service_type == "NodePort" ? [1] : []
    content {
      name  = "controller.service.nodePorts.http"
      value = tostring(var.http_node_port)
    }
  }
  dynamic "set" {
    for_each = var.ingress_service_type == "NodePort" ? [1] : []
    content {
      name  = "controller.service.nodePorts.https"
      value = tostring(var.https_node_port)
    }
  }

  # Preserve client source IPs through the TCP LB.
  set {
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }
}

# cert-manager (Let's Encrypt certs for the ingress) — same on every cloud.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  atomic           = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# ============================================================================
# The application stack — health-stack Helm chart
# ============================================================================
# Installs the local chart with the Hetzner values file, overriding the ingress
# host + cert-manager issuer email from Terraform vars so DNS/TLS line up with
# what the LB/network modules provisioned. cert-manager's ClusterIssuer is created
# by the chart here (clusterIssuer.create=true) so TLS works end-to-end.
resource "helm_release" "health_stack" {
  name             = "health-stack"
  namespace        = "health-stack"
  create_namespace = true
  chart            = var.chart_path
  # 300s isn't enough for a cold Keycloak boot; atomic avoids a stuck pending state.
  timeout = 600
  atomic  = true

  # Environment defaults (storage class, sizing, image tags).
  values = [file(var.chart_values_file)]

  # Have the chart render the Secrets from the generated credentials below, rather
  # than requiring a hand-maintained secrets.yaml applied out-of-band.
  set {
    name  = "secrets.create"
    value = "true"
  }

  # Generated credentials. set_sensitive keeps them out of Terraform's plan/apply
  # output. NOTE: the DB passwords are baked into the Postgres roles by init-db.sql,
  # which only runs on FIRST boot of an empty PVC — rotating them later needs the
  # roles altered in-place (ALTER USER ... PASSWORD) or the PVC recreated.
  set_sensitive {
    name  = "secrets.values.postgres.POSTGRES_PASSWORD"
    value = var.pg_superuser_password
  }
  set_sensitive {
    name  = "secrets.values.postgres.EHRBASE_PASSWORD"
    value = var.ehrbase_db_password
  }
  set_sensitive {
    name  = "secrets.values.postgres.EHRBASE_PASSWORD_ADMIN"
    value = var.ehrbase_db_admin_password
  }
  # EHRbase's own datasource creds must match the roles above.
  set_sensitive {
    name  = "secrets.values.ehrbase.DB_PASS"
    value = var.ehrbase_db_password
  }
  set_sensitive {
    name  = "secrets.values.ehrbase.DB_PASS_ADMIN"
    value = var.ehrbase_db_admin_password
  }
  set {
    name  = "secrets.values.ehrbase.SERVER_NODENAME"
    value = var.domain
  }
  # HAPI + openFHIR datasource creds; init-db.sql creates these roles with the
  # same values (rendered from these Secret values).
  set_sensitive {
    name  = "secrets.values.hapi.HAPI_DB_PASS"
    value = var.hapi_db_password
  }
  set_sensitive {
    name  = "secrets.values.openfhir.OPENFHIR_DB_PASS"
    value = var.openfhir_db_password
  }

  # Keycloak + oauth2-proxy credentials. values-hetzner.yaml blanks these (the
  # chart's `required` guards fail a bare render), so they MUST come from here.
  # The three client secrets are substituted into the realm import and handed to
  # their consumers by the chart.
  set {
    name  = "secrets.values.keycloak.KC_BOOTSTRAP_ADMIN_USERNAME"
    value = var.keycloak_admin_user
  }
  set_sensitive {
    name  = "secrets.values.keycloak.KC_BOOTSTRAP_ADMIN_PASSWORD"
    value = var.keycloak_admin_password
  }
  set_sensitive {
    name  = "secrets.values.keycloak.KC_DB_PASSWORD"
    value = var.keycloak_db_password
  }
  set_sensitive {
    name  = "secrets.values.keycloak.API_CLIENT_SECRET"
    value = var.kc_api_client_secret
  }
  set_sensitive {
    name  = "secrets.values.keycloak.HAPI_SVC_SECRET"
    value = var.kc_hapi_svc_secret
  }
  set_sensitive {
    name  = "secrets.values.keycloak.OAUTH2_PROXY_CLIENT_SECRET"
    value = var.oauth2_proxy_client_secret
  }
  set_sensitive {
    name  = "secrets.values.keycloak.OAUTH2_PROXY_COOKIE_SECRET"
    value = var.oauth2_proxy_cookie_secret
  }

  # Terraform-owned overrides: real domain + issuer email.
  set {
    name  = "ingress.host"
    value = var.domain
  }
  set {
    name  = "clusterIssuer.create"
    value = "true"
  }
  set {
    name  = "clusterIssuer.email"
    value = var.letsencrypt_email
  }
  set {
    name  = "ingress.tls.clusterIssuer"
    value = "letsencrypt-prod"
  }

  # Apps depend on the ingress controller + cert-manager (for the issuer CRD).
  # The cloud-integration module's CSI driver (so PVCs bind) is a dependency of
  # THIS MODULE CALL, set by the env root (e.g. `depends_on =
  # [module.hcloud_cloud_integration]` on `module.apps` in envs/hetzner/main.tf)
  # rather than a resource reference inside this generic module.
  depends_on = [
    helm_release.ingress_nginx,
    helm_release.cert_manager,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "ingress_namespace" { value = "ingress-nginx" }
output "app_namespace" { value = "health-stack" }
output "app_release" { value = helm_release.health_stack.name }
