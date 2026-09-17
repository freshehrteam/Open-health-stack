terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.45"
    }
  }
}

variable "name" { type = string }
variable "region" { type = string }
variable "subnet_cidr" { type = string }

# VPC carrying the cluster's private network. Scaleway VPCs are regional,
# unlike hcloud's zone-scoped networks.
resource "scaleway_vpc" "this" {
  name   = "${var.name}-vpc"
  region = var.region
  tags   = ["cluster:${var.name}"]
}

# Private network carrying node<->node (flannel) and node<->DB traffic.
resource "scaleway_vpc_private_network" "this" {
  name   = "${var.name}-net"
  vpc_id = scaleway_vpc.this.id
  region = var.region

  ipv4_subnet {
    subnet = var.subnet_cidr
  }

  tags = ["cluster:${var.name}"]
}

output "private_network_id" {
  value = scaleway_vpc_private_network.this.id
}
