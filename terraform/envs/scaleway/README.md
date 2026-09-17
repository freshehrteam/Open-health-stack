# Scaleway terraform environment

Provisions a self-managed k3s cluster on Scaleway Instances and deploys the
`health-stack` Helm chart onto it — the Scaleway counterpart to
[`terraform/envs/hetzner/`](../hetzner/). Wires the `scaleway-*` modules
(`network`, `cluster`, `lb`, `cloud-integration`) plus the shared,
provider-agnostic `k8s-apps` module.

## Required IAM setup

Scaleway API keys can't carry a policy directly — the policy attaches to the
**Application** that owns the key (Console: IAM → Applications → the
application backing this key → Policies). Attach a policy scoped to the one
project this environment deploys into, granting these permission sets:

| Permission set | Why |
|---|---|
| `ObjectStorageFullAccess` | remote state backend (see `versions.tf`) |
| `SSHKeysFullAccess` | uploads the operator's SSH key so cloud-init can inject it into new nodes — see **security note** below |
| Instances (servers + security groups) | `scaleway-cluster` module |
| VPC | `scaleway-network` module |
| Load Balancer | `scaleway-lb` module |

None of these are labeled "IAM" in the console's product filter even though
the underlying API is `iam/v1alpha1/*` — search "all products" if a filtered
search comes up empty, as it did for SSH keys.

### ⚠ Security note: `SSHKeysFullAccess`

This permission set is broader than it looks, and worth understanding before
granting it to a long-lived automation credential.

**Why it's needed at all:** unlike Hetzner (`hcloud_server.ssh_keys`, a
per-server attachment), Scaleway's `scaleway_instance_server` resource has no
per-server SSH key argument. Every SSH key registered on the project gets
injected via cloud-init into **every new instance's** `authorized_keys`
automatically. `scaleway-cluster`'s `scaleway_iam_ssh_key` resource is how the
operator's key gets there — without it, nothing can SSH into the new nodes to
fetch the kubeconfig.

**What the risk actually is:** anyone holding a credential with
`SSHKeysFullAccess` can register their own key, and it will be pushed to new
instances with the same privilege our own tooling relies on — the
`kubeconfig` provisioner connects as `root`, so keys land with root-equivalent
access. On this cluster that means direct access to k3s's local datastore
(unencrypted by default, holding every generated Secret — Postgres, EHRbase,
Keycloak admin, OAuth2-proxy), the ability to pivot across the private
network to the other nodes, and read/write access to whatever the deployed
health-stack is holding once it's running. In short: this permission turns a
leaked API key from "can damage/rack up cost on infrastructure" into "can
read the data and secrets that infrastructure holds." Whether a newly
registered key also propagates to **already-running** instances (not just new
ones) is not confirmed here — check Scaleway's current documentation before
assuming either way.

**To avoid granting this at all:** register your SSH key once, manually, via
the Scaleway console, and change `scaleway-cluster` to reference that
existing key by ID instead of creating one with Terraform. That removes this
permission requirement from the automation credential entirely — the
tradeoff is a manual one-time step outside Terraform's management. This
repo's current `scaleway-cluster` module does not implement that path; ask
before assuming it's been done.

## Remote state backend

State lives in Scaleway Object Storage (S3-compatible) — see `versions.tf`.
The bucket does not get created by `terraform init`; create it once yourself,
and note two things this environment's setup ran into:

- **Path-style addressing is required** (`use_path_style = true`, already set
  in `versions.tf`). Virtual-hosted-style (`<bucket>.s3.<region>.scw.cloud`)
  is a different hostname per bucket — if your network egress policy
  allowlists specific hosts rather than a wildcard, only the bare
  `s3.<region>.scw.cloud` host needs to be reachable with path-style.
- Scaleway's access/secret key pair works directly as S3-compatible
  credentials: `export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"` /
  `export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"` before `terraform init`.

## Apply

Three-phase — Hetzner's two-phase pattern (cluster, then apps) plus a
Scaleway-specific middle phase: nodes are bootstrapped with
`--kubelet-arg=cloud-provider=external`, so they carry the
`node.cloudprovider.kubernetes.io/uninitialized` taint (unschedulable) until
the cloud-controller-manager runs, and the CCM only needs the kubeconfig, not
a domain — so it has its own `install_cloud_integration` flag, independent of
`install_apps`.

```bash
cd terraform/envs/scaleway
cp terraform.tfvars.example terraform.tfvars   # fill in real values, gitignored
terraform init
terraform apply -var 'install_apps=false' -var 'install_cloud_integration=false'
  # phase 1: cluster only — no kubeconfig yet, so no k8s/helm provider calls
terraform apply -var 'install_apps=false'
  # phase 2: cloud-controller-manager + CSI driver — untaints nodes, no domain needed yet
terraform apply
  # phase 3: add-ons + health-stack chart (needs a real domain)
```

## Status

Scaffolded and schema-validated against a live Scaleway project. The
cloud-init templates' assumptions about the private-network interface name
and Scaleway's metadata-service response shape are first-draft and were not
confirmed against a real boot as of this environment's initial commit — see
the comments at the top of `terraform/cloud-init/scaleway-*.yaml.tftpl`.
