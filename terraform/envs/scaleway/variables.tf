# ── Provider / auth ──────────────────────────────────────────────────────────
variable "scw_access_key" {
  description = "Scaleway API access key. Provide via TF_VAR_scw_access_key or a gitignored *.tfvars."
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway API secret key. Provide via TF_VAR_scw_secret_key or a gitignored *.tfvars."
  type        = string
  sensitive   = true
}

variable "scw_project_id" {
  description = "Scaleway project ID all resources are created in."
  type        = string
}

# ── Cluster shape ────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Name prefix for all Scaleway resources."
  type        = string
  default     = "freshehr"
}

variable "region" {
  description = "Scaleway region (VPC/private-network/LB are region-scoped)."
  type        = string
  default     = "nl-ams"
}

variable "zone" {
  description = "Scaleway zone (instances are zone-scoped)."
  type        = string
  default     = "nl-ams-1"
}

variable "control_plane_type" {
  description = "Instance commercial type for the k3s control-plane node."
  type        = string
  default     = "DEV1-M"
}

variable "agent_type" {
  description = "Instance commercial type for k3s agent nodes."
  type        = string
  default     = "DEV1-L"
}

variable "agent_count" {
  description = "Number of k3s agent nodes."
  type        = number
  default     = 2
}

variable "image" {
  description = "Marketplace image label for the nodes."
  type        = string
  default     = "ubuntu_jammy"
}

# ── SSH / access ─────────────────────────────────────────────────────────────
variable "ssh_public_key_path" {
  description = "Path to the SSH public key uploaded to Scaleway and installed on nodes."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_ssh_cidrs" {
  description = "CIDRs allowed to SSH (port 22) to the nodes. Lock this down."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "k3s_api_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the k3s API (port 6443), separate from
    admin_ssh_cidrs. Safe to leave wide open (the default) even when
    admin_ssh_cidrs is locked down: port 6443 requires a valid client cert
    (kubeconfig) to do anything, and this is what lets a CI runner with no
    fixed IP run `terraform apply` against the cluster.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── Networking ───────────────────────────────────────────────────────────────
variable "network_cidr" {
  description = "CIDR for the private network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the node subnet within the private network."
  type        = string
  default     = "10.0.1.0/24"
}

# ── k3s ──────────────────────────────────────────────────────────────────────
variable "k3s_version" {
  description = "k3s channel or pinned version (e.g. 'stable', 'v1.30')."
  type        = string
  default     = "stable"
}

# ── Apps layer (k8s-apps module) ─────────────────────────────────────────────
variable "domain" {
  description = "DNS host for the ingress (must resolve to the load balancer IP). Empty = skip TLS host wiring."
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Contact email for the cert-manager Let's Encrypt ClusterIssuer."
  type        = string
  default     = "admin@example.com"
}

variable "install_apps" {
  description = "Whether the k8s-apps module installs add-ons + the health-stack chart. Set false for a cluster-only (phase 1) apply."
  type        = bool
  default     = true
}

variable "install_cloud_integration" {
  description = <<-EOT
    Whether to install Scaleway's cloud-controller-manager + CSI driver. Only
    needs the kubeconfig (module.cluster), not a domain — so it has its own
    flag rather than sharing install_apps. Nodes are bootstrapped with
    --kubelet-arg=cloud-provider=external, so until the CCM runs they carry
    the node.cloudprovider.kubernetes.io/uninitialized taint and stay
    unschedulable; leaving this false alongside install_apps=false is a valid
    cluster-only phase, but the CCM must go in before install_apps=true (the
    health-stack chart's PVCs need the CSI driver to bind).
  EOT
  type        = bool
  default     = true
}

variable "kubeconfig_path" {
  description = "Local path where the fetched k3s kubeconfig is written."
  type        = string
  default     = "./kubeconfig"
}
