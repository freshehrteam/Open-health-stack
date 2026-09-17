terraform {
  required_providers {
    scaleway = { source = "scaleway/scaleway", version = "~> 2.45" }
    tls      = { source = "hashicorp/tls", version = "~> 4.0" }
    null     = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

variable "name" { type = string }
variable "zone" { type = string }
variable "image" { type = string }
variable "control_plane_type" { type = string }
variable "agent_type" { type = string }
variable "agent_count" { type = number }
variable "ssh_public_key_path" { type = string }
variable "admin_ssh_cidrs" { type = list(string) }

variable "k3s_api_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the k3s API (port 6443) from outside the private
    network, separate from admin_ssh_cidrs. Port 6443 requires a valid client
    cert (kubeconfig) to do anything, unlike SSH — so this can safely default
    wide open even when admin_ssh_cidrs is locked down to one IP, letting CI
    runners (no fixed IP) reach the cluster for `terraform apply` without
    also exposing SSH.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "k3s_version" { type = string }
variable "private_network_id" { type = string }
variable "network_cidr" { type = string }
variable "kubeconfig_path" { type = string }

variable "ssh_private_key_path" {
  description = "Private key matching ssh_public_key_path, used to fetch the kubeconfig. Defaults to the public key path minus .pub."
  type        = string
  default     = ""
}

# Deterministic k3s cluster token (kept in state; state is gitignored).
resource "tls_private_key" "k3s_token" {
  algorithm = "ED25519"
}

locals {
  k3s_token = substr(sha256(tls_private_key.k3s_token.private_key_pem), 0, 48)

  ssh_private_key_path = var.ssh_private_key_path != "" ? var.ssh_private_key_path : replace(var.ssh_public_key_path, ".pub", "")

  # Each server's `private_ips` list holds both an IPv4 and an IPv6 address,
  # and the IPv6 one is not reliably at a fixed index — observed in practice
  # landing at index 0. Select the IPv4 entry explicitly (no colon) rather
  # than assuming an index; picking the wrong one breaks the agent's k3s
  # join URL (unbracketed IPv6 + port isn't parseable) and would equally
  # break LB backend targeting.
  control_plane_private_ipv4 = [
    for ip in scaleway_instance_server.control_plane.private_ips : ip.address if !strcontains(ip.address, ":")
  ][0]

  agent_private_ipv4s = [
    for s in scaleway_instance_server.agent : [
      for ip in s.private_ips : ip.address if !strcontains(ip.address, ":")
    ][0]
  ]
}

# ── SSH key ──────────────────────────────────────────────────────────────────
resource "scaleway_iam_ssh_key" "this" {
  name       = "${var.name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# ── Security group ───────────────────────────────────────────────────────────
# Unlike hcloud_firewall, scaleway_instance_security_group rules take one
# ip_range per rule (no source_ips list) — CIDR lists are expanded with
# dynamic blocks below.
resource "scaleway_instance_security_group" "this" {
  name                    = "${var.name}-sg"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = var.admin_ssh_cidrs
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 22
      ip_range = inbound_rule.value
    }
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 80
    ip_range = "0.0.0.0/0"
  }
  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 443
    ip_range = "0.0.0.0/0"
  }
  inbound_rule {
    action     = "accept"
    protocol   = "TCP"
    port_range = "30000-32767"
    ip_range   = "0.0.0.0/0"
  }

  dynamic "inbound_rule" {
    for_each = toset(concat([var.network_cidr], var.k3s_api_cidrs))
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 6443
      ip_range = inbound_rule.value
    }
  }

  inbound_rule {
    action   = "accept"
    protocol = "UDP"
    port     = 8472 # flannel VXLAN
    ip_range = var.network_cidr
  }
  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 10250 # kubelet
    ip_range = var.network_cidr
  }
}

# ── Control-plane server ─────────────────────────────────────────────────────
# Its own private IP is unknown until after creation (private_ips is computed,
# and user_data must be resolvable at create time) — cloud-init self-discovers
# it at boot instead of receiving it as a templated value. See
# terraform/cloud-init/scaleway-control-plane.yaml.tftpl.
resource "scaleway_instance_server" "control_plane" {
  name              = "${var.name}-cp"
  type              = var.control_plane_type
  image             = var.image
  zone              = var.zone
  security_group_id = scaleway_instance_security_group.this.id
  enable_dynamic_ip = true # unlike hcloud_server, Scaleway servers get no public IP by default

  user_data = {
    "cloud-init" = templatefile("${path.module}/../../cloud-init/scaleway-control-plane.yaml.tftpl", {
      k3s_version  = var.k3s_version
      k3s_token    = local.k3s_token
      network_cidr = var.network_cidr
    })
  }

  private_network {
    pn_id = var.private_network_id
  }

  tags = ["cluster:${var.name}", "role:control-plane"]

  lifecycle {
    ignore_changes = [
      user_data,               # avoid recreate churn on template tweaks
      additional_volume_ids,   # owned by the Scaleway CSI driver, not this config —
                                # reconciling it here would detach a live PVC's volume
    ]
  }
}

# ── Agent servers ────────────────────────────────────────────────────────────
resource "scaleway_instance_server" "agent" {
  count             = var.agent_count
  name              = "${var.name}-agent-${count.index}"
  type              = var.agent_type
  image             = var.image
  zone              = var.zone
  security_group_id = scaleway_instance_security_group.this.id
  enable_dynamic_ip = true # unlike hcloud_server, Scaleway servers get no public IP by default

  # The control-plane is already created by the time this resource is
  # applied (depends_on below), so its private_ips[0].address is a real,
  # known value here — unlike the control-plane's own user_data above.
  user_data = {
    "cloud-init" = templatefile("${path.module}/../../cloud-init/scaleway-agent.yaml.tftpl", {
      k3s_version  = var.k3s_version
      k3s_token    = local.k3s_token
      server_url   = "https://${local.control_plane_private_ipv4}:6443"
      network_cidr = var.network_cidr
    })
  }

  private_network {
    pn_id = var.private_network_id
  }

  tags = ["cluster:${var.name}", "role:agent"]

  depends_on = [scaleway_instance_server.control_plane]

  lifecycle {
    ignore_changes = [
      user_data,               # avoid recreate churn on template tweaks
      additional_volume_ids,   # owned by the Scaleway CSI driver, not this config —
                                # reconciling it here would detach a live PVC's volume
    ]
  }
}

# ── Fetch kubeconfig from the control-plane ──────────────────────────────────
resource "null_resource" "kubeconfig" {
  triggers = {
    control_plane_id = scaleway_instance_server.control_plane.id
  }

  connection {
    type    = "ssh"
    host    = scaleway_instance_server.control_plane.public_ips[0].address
    user    = "root"
    agent   = true
    timeout = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
        for i in $(seq 1 60); do
          if [ -f /tmp/k3s-ready ]; then echo "k3s ready"; exit 0; fi
          echo "waiting for k3s"
          sleep 5
        done
        echo "ERROR: k3s did not become ready within 5m" >&2
        echo "--- cloud-init status ---" >&2
        cloud-init status --long >&2 2>&1 || true
        echo "--- k3s journal (last 50) ---" >&2
        journalctl -u k3s --no-pager -n 50 >&2 2>&1 || true
        exit 1
      EOT
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@${scaleway_instance_server.control_plane.public_ips[0].address}:/etc/rancher/k3s/k3s.yaml ${var.kubeconfig_path}
      sed -i.bak 's#https://127.0.0.1:6443#https://${scaleway_instance_server.control_plane.public_ips[0].address}:6443#g' ${var.kubeconfig_path}
      rm -f ${var.kubeconfig_path}.bak
      chmod 600 ${var.kubeconfig_path}
    EOT
  }

  depends_on = [scaleway_instance_server.control_plane]
}

# ── Outputs ──────────────────────────────────────────────────────────────────
output "control_plane_ipv4" { value = scaleway_instance_server.control_plane.public_ips[0].address }
output "agent_ipv4s" { value = [for s in scaleway_instance_server.agent : s.public_ips[0].address] }
output "control_plane_private_ip" { value = local.control_plane_private_ipv4 }
output "agent_private_ips" { value = local.agent_private_ipv4s }
output "k3s_token" {
  value     = local.k3s_token
  sensitive = true
}
