# Scaleway cloud-provider integrations (CCM + CSI) — mirrors
# hcloud-cloud-integration's role: keeps k8s-apps provider-agnostic.
#
# Secret name/namespace are NOT free choices: the upstream CCM manifest
# (github.com/scaleway/scaleway-cloud-controller-manager, examples/k8s-scaleway-ccm-latest.yml)
# hardcodes `envFrom.secretRef.name: scaleway-secret` in namespace `kube-system` —
# confirmed by reading that manifest directly, not assumed. The CSI chart's
# `controller.scaleway.existingSecretName` is configurable, so it's pointed at
# the same secret/namespace to avoid provisioning Scaleway credentials twice.
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

variable "scw_access_key" {
  type      = string
  sensitive = true
}
variable "scw_secret_key" {
  type      = string
  sensitive = true
}
variable "scw_project_id" {
  type = string
}
variable "scw_zone" {
  type = string
}
# The Scaleway SDK (which the CCM's cloud-provider init uses) requires both
# region and zone — SCW_DEFAULT_ZONE alone fails with "region is required".
variable "scw_region" {
  type = string
}
variable "kubeconfig_path" {
  type = string
}

locals {
  ccm_manifest_url = "https://raw.githubusercontent.com/scaleway/scaleway-cloud-controller-manager/master/examples/k8s-scaleway-ccm-latest.yml"
}

resource "kubernetes_secret" "scaleway" {
  metadata {
    name      = "scaleway-secret"
    namespace = "kube-system"
  }
  data = {
    SCW_ACCESS_KEY         = var.scw_access_key
    SCW_SECRET_KEY         = var.scw_secret_key
    SCW_DEFAULT_PROJECT_ID = var.scw_project_id
    SCW_DEFAULT_REGION     = var.scw_region
    SCW_DEFAULT_ZONE       = var.scw_zone
  }
}

# Scaleway CSI (dynamic PVC provisioning -> scw-bssd storage class).
resource "helm_release" "scaleway_csi" {
  name       = "scaleway-csi"
  namespace  = "kube-system"
  repository = "https://helm.scw.cloud/"
  chart      = "scaleway-csi"

  set {
    name  = "controller.scaleway.existingSecretName"
    value = kubernetes_secret.scaleway.metadata[0].name
  }

  depends_on = [kubernetes_secret.scaleway]
}

# Scaleway Cloud Controller Manager (nodes get proper providerIDs). No
# official Helm chart exists, so this applies the upstream manifest directly —
# same local-exec + kubeconfig pattern hcloud-cluster's kubeconfig fetch uses,
# not a new mechanism.
resource "null_resource" "ccm" {
  triggers = {
    manifest_url = local.ccm_manifest_url
  }

  provisioner "local-exec" {
    command = "kubectl --kubeconfig=${var.kubeconfig_path} apply -f ${local.ccm_manifest_url}"
  }

  depends_on = [kubernetes_secret.scaleway]
}
