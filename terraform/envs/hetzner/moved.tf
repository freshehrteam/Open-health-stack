# State-address migration for the hcloud-cloud-integration extraction: these 4
# resources used to live directly inside module.apps (k8s-apps); they now live
# in their own module.hcloud_cloud_integration. Without these `moved` blocks,
# `terraform plan` would want to destroy and recreate all 4 (new resource
# address = new resource, as far as Terraform's state is concerned) — a real
# CCM/CSI outage on an existing cluster. Safe to delete once every real-world
# state has been migrated (i.e. after the next `terraform apply` everywhere
# this chart is deployed).
moved {
  from = module.apps[0].kubernetes_namespace.system
  to   = module.hcloud_cloud_integration[0].kubernetes_namespace.system
}
moved {
  from = module.apps[0].kubernetes_secret.hcloud
  to   = module.hcloud_cloud_integration[0].kubernetes_secret.hcloud
}
moved {
  from = module.apps[0].helm_release.hcloud_ccm
  to   = module.hcloud_cloud_integration[0].helm_release.hcloud_ccm
}
moved {
  from = module.apps[0].helm_release.hcloud_csi
  to   = module.hcloud_cloud_integration[0].helm_release.hcloud_csi
}
