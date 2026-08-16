# Latest patch of the pinned minor track. Resolved from DO's supported list at
# plan time, so a patch release shows up as a diff here rather than as drift.
data "digitalocean_kubernetes_versions" "this" {
  version_prefix = var.kubernetes_version_prefix
}

# A dedicated VPC rather than the region's default network, so what lands next
# to the cluster is decided here. Free, but ip_range cannot be changed later.
resource "digitalocean_vpc" "this" {
  name     = "${var.cluster_name}-vpc"
  region   = var.region
  ip_range = "10.10.0.0/16"
}

resource "digitalocean_kubernetes_cluster" "this" {
  name     = var.cluster_name
  region   = var.region
  vpc_uuid = digitalocean_vpc.this.id

  # Only the minor track is ours to choose: DO applies patch releases itself
  # inside the maintenance window, and the data source keeps this in step.
  version      = data.digitalocean_kubernetes_versions.this.latest_version
  auto_upgrade = true

  # Upgrades replace nodes; with a one-node pool, surge is what keeps the
  # workload alive across the swap (an extra node is billed while it runs).
  surge_upgrade = true

  # An HA control plane is +$40/month — off while this stays a hobby cluster.
  ha = false

  # start_time is UTC and must be a whole hour: Sunday 19:00 UTC = Monday 04:00 JST.
  maintenance_policy {
    day        = "sunday"
    start_time = "19:00"
  }

  # Load balancers and volumes created *by* the cluster (Services of type
  # LoadBalancer, PVCs) are billed separately and would outlive a destroy.
  destroy_all_associated_resources = true

  node_pool {
    name       = "default"
    size       = var.node_size
    node_count = var.node_count
  }

  tags = ["terraform", "boykush"]
}
