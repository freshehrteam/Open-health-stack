terraform {
  required_providers {
    scaleway = { source = "scaleway/scaleway", version = "~> 2.45" }
  }
}

variable "name" { type = string }
variable "private_network_id" { type = string }

# Scaleway has no label-selector target like hcloud_load_balancer_target —
# backends take a plain list of server IPs, computed from the cluster
# module's outputs at the env level (control-plane + all agents). This
# creates a real apply-order dependency (cluster before lb) that Hetzner's
# label-selector approach didn't have.
variable "target_ips" { type = list(string) }

variable "http_node_port" { type = number }
variable "https_node_port" { type = number }

variable "lb_type" {
  type    = string
  default = "lb-s" # cheapest tier; internal-backend-only, matches our use case
}

resource "scaleway_lb_ip" "this" {}

resource "scaleway_lb" "this" {
  name   = "${var.name}-lb"
  type   = var.lb_type
  ip_ids = [scaleway_lb_ip.this.id]

  # Reach node targets over the private network, like hcloud_load_balancer_network.
  private_network {
    private_network_id = var.private_network_id
  }

  tags = ["cluster:${var.name}"]
}

# :80 -> ingress-nginx HTTP NodePort
resource "scaleway_lb_backend" "http" {
  lb_id            = scaleway_lb.this.id
  name             = "${var.name}-http"
  forward_protocol = "tcp"
  forward_port     = var.http_node_port
  server_ips       = var.target_ips

  health_check_port        = var.http_node_port
  health_check_delay       = "10s"
  health_check_timeout     = "5s"
  health_check_max_retries = 3
}

resource "scaleway_lb_frontend" "http" {
  lb_id        = scaleway_lb.this.id
  name         = "${var.name}-http"
  backend_id   = scaleway_lb_backend.http.id
  inbound_port = 80
}

# :443 -> ingress-nginx HTTPS NodePort (TLS terminates at ingress-nginx/cert-manager)
resource "scaleway_lb_backend" "https" {
  lb_id            = scaleway_lb.this.id
  name             = "${var.name}-https"
  forward_protocol = "tcp"
  forward_port     = var.https_node_port
  server_ips       = var.target_ips

  health_check_port        = var.https_node_port
  health_check_delay       = "10s"
  health_check_timeout     = "5s"
  health_check_max_retries = 3
}

resource "scaleway_lb_frontend" "https" {
  lb_id        = scaleway_lb.this.id
  name         = "${var.name}-https"
  backend_id   = scaleway_lb_backend.https.id
  inbound_port = 443
}

output "ipv4" { value = scaleway_lb_ip.this.ip_address }
output "id" { value = scaleway_lb.this.id }
