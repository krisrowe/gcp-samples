provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ------------------------------------------------------------------------------
# 1. NETWORKING INFRASTRUCTURE (VPC & SUBNETS)
# ------------------------------------------------------------------------------

resource "google_compute_network" "producer_vpc" {
  name                    = "psc-producer-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "producer_subnet" {
  name          = "psc-producer-subnet"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.producer_vpc.id
  region        = var.region
}

# The dedicated NAT Subnet for Private Service Connect
resource "google_compute_subnetwork" "psc_nat_subnet" {
  name          = "psc-nat-subnet"
  ip_cidr_range = "10.0.2.0/24"
  network       = google_compute_network.producer_vpc.id
  region        = var.region
  purpose       = "PRIVATE_SERVICE_CONNECT"
  role          = "ACTIVE"
}

# ------------------------------------------------------------------------------
# 2. FIREWALL SECURITY LAYER
# ------------------------------------------------------------------------------

# Allow Google Cloud Health Check ranges to probe the backend VMs
resource "google_compute_firewall" "allow_hc" {
  name    = "psc-producer-allow-hc"
  network = google_compute_network.producer_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["psc-backend"]
}

# Allow incoming client connections from the PSC NAT subnet
resource "google_compute_firewall" "allow_psc_client" {
  name    = "psc-producer-allow-client"
  network = google_compute_network.producer_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = [google_compute_subnetwork.psc_nat_subnet.ip_cidr_range]
  target_tags   = ["psc-backend"]
}


# ------------------------------------------------------------------------------
# 4. LOAD BALANCING LAYER (ILB)
# ------------------------------------------------------------------------------

resource "google_compute_region_health_check" "producer_hc" {
  name   = "psc-producer-hc"
  region = var.region

  tcp_health_check {
    port = 80
  }
}

resource "google_compute_region_backend_service" "producer_backend_service" {
  name                  = "psc-producer-backend-service"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_region_health_check.producer_hc.id]
}

resource "google_compute_forwarding_rule" "producer_ilb" {
  name                  = "psc-producer-ilb"
  region                = var.region
  network               = google_compute_network.producer_vpc.id
  subnetwork            = google_compute_subnetwork.producer_subnet.id
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.producer_backend_service.id
  ip_protocol           = "TCP"
  ports                 = ["80"]
}

# ------------------------------------------------------------------------------
# 5. PSC PUBLISHING LAYER (SERVICE ATTACHMENT)
# ------------------------------------------------------------------------------

resource "google_compute_service_attachment" "producer_service_attachment" {
  name                  = "psc-producer-service-attachment"
  region                = var.region
  target_service        = google_compute_forwarding_rule.producer_ilb.id
  connection_preference = "ACCEPT_AUTOMATIC"
  nat_subnets           = [google_compute_subnetwork.psc_nat_subnet.id]
  enable_proxy_protocol = false
}
