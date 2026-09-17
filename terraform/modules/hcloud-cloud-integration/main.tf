# Hetzner cloud-provider integrations (CCM + CSI) — installed into the cluster
# as its own module so `k8s-apps` stays genuinely provider-agnostic (see
# terraform/modules/k8s-apps/main.tf, which used to carry this directly).
# A Scaleway (or any other cloud) env wires its own equivalent module instead
# of this one; k8s-apps itself never branches on cloud provider.
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}
variable "network_id" {
  type = string
}

resource "kubernetes_namespace" "system" {
  metadata { name = "hcloud-system" }
}

resource "kubernetes_secret" "hcloud" {
  metadata {
    name      = "hcloud"
    namespace = kubernetes_namespace.system.metadata[0].name
  }
  data = {
    token   = var.hcloud_token
    network = var.network_id
  }
}

# Hetzner Cloud Controller Manager (nodes get proper providerIDs).
resource "helm_release" "hcloud_ccm" {
  name       = "hccm"
  namespace  = kubernetes_namespace.system.metadata[0].name
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-cloud-controller-manager"

  set {
    name  = "networking.enabled"
    value = "true"
  }
  set {
    name  = "env.HCLOUD_TOKEN.valueFrom.secretKeyRef.name"
    value = kubernetes_secret.hcloud.metadata[0].name
  }

  depends_on = [kubernetes_secret.hcloud]
}

# Hetzner CSI (dynamic PVC provisioning → hcloud-volumes storage class).
resource "helm_release" "hcloud_csi" {
  name       = "hcloud-csi"
  namespace  = kubernetes_namespace.system.metadata[0].name
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-csi"

  depends_on = [helm_release.hcloud_ccm]
}

output "namespace" {
  value = kubernetes_namespace.system.metadata[0].name
}
