# ------------------------------------------------------------------------------------------------- #
# ---------------------------------- VPC Network and Subnetworks ---------------------------------- #
# ------------------------------------------------------------------------------------------------- #

resource "google_compute_network" "vpc_network" {
  name                    = "shibl-vpc-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "management_subnet" {
  name          = "shibl-management-subnet"
  ip_cidr_range = "10.10.10.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_subnetwork" "restricted_subnet" {
  name          = "shibl-restricted-subnet"
  ip_cidr_range = "10.10.20.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

# ------------------------------------------------------------------------------------------------- #
# ---------------------------------- NAT Router and NAT Gateway ----------------------------------- #
# ------------------------------------------------------------------------------------------------- #

resource "google_compute_router" "nat_router" {
  name    = "shibl-nat-router"
  network = google_compute_network.vpc_network.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "shibl-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.management_subnet.name
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}


# ------------------------------------------------------------------------------------------------- #
# ---------------------------------------- VM Creation -------------------------------------------- #
# ------------------------------------------------------------------------------------------------- #


data "google_compute_image" "my_image" {
  project = "ubuntu-os-cloud"
  family  = "ubuntu-2204-lts"
}

resource "google_service_account" "vm_sa" {
  account_id   = "shibl-vm-sa"
  display_name = "shibl-vm-sa"
}

resource "google_project_iam_member" "vm_sa_roles" {
  for_each = toset([
    "roles/container.developer",
    "roles/container.clusterAdmin",
    "roles/artifactregistry.admin",
    "roles/iam.serviceAccountUser"
  ])
  
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm_sa.email}"
}

resource "google_compute_instance" "shibl-vm" {
  name         = "shibl-vm"
  machine_type = "e2-medium"
  zone         = var.zone
  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y docker.io
    sudo usermod -aG docker $USER
    newgrp docker
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | \
    sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    sudo apt-get update
    sudo apt-get install google-cloud-sdk-gke-gcloud-auth-plugin
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
  EOF

  boot_disk {
    initialize_params {
      image = data.google_compute_image.my_image.self_link
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.management_subnet.name
    network_ip = "10.10.10.10"
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  allow_stopping_for_update = true

  tags = ["management-vm"]
}

# ------------------------------------------------------------------------------------------------- #
# ---------------------------------------- GKE Cluster -------------------------------------------- #
# ------------------------------------------------------------------------------------------------- #

resource "google_service_account" "gke_sa" {
  account_id   = "shibl-gke-sa"
  display_name = "shibl-gke-sa"
}

resource "google_project_iam_member" "artifact_registry_admin_binding" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_container_cluster" "private_gke_cluster" {
  name     = "shibl-private-cluster"
  location = var.zone

  network    = google_compute_network.vpc_network.id
  subnetwork = google_compute_subnetwork.restricted_subnet.name

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
    master_global_access_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.10.10.0/24"
      display_name = "Management Subnet"
    }
  }

  node_config {
    machine_type    = "e2-medium"
    service_account = google_service_account.gke_sa.email
    tags            = ["gke-node"]
    disk_size_gb    = 30
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  initial_node_count       = 2

  logging_service     = "logging.googleapis.com/kubernetes"
  monitoring_service  = "monitoring.googleapis.com/kubernetes"
  deletion_protection = false
}

# ------------------------------------------------------------------------------------------------- #
# --------------------------------------- Artifact Registry --------------------------------------- #
# ------------------------------------------------------------------------------------------------- #

resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = "shibl-gke-repo"
  format        = "DOCKER"
}


# ------------------------------------------------------------------------------------------------- #
# ---------------------------------------- Firewall Rules ----------------------------------------- #
# ------------------------------------------------------------------------------------------------- #


resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc_network.name

  direction     = "INGRESS"
  priority      = 65534
  source_ranges = ["10.10.0.0/16"]

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "allow_ssh_management" {
  name    = "allow-ssh-management-subnet"
  network = google_compute_network.vpc_network.name

  direction = "INGRESS"
  priority  = 100

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["management-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "allow-gcp-health-checks"
  network = google_compute_network.vpc_network.name

  direction = "INGRESS"
  priority  = 1000
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]

  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }
}

resource "google_compute_firewall" "allow_gke_node_ports" {
  name    = "allow-gke-node-ports"
  network = google_compute_network.vpc_network.name

  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["10.10.0.0/16"]

  target_tags = ["gke-node"]

  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }
}
