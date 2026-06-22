provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ------------------------------------------------------------------------------
# 1. NETWORKING INFRASTRUCTURE (VPC & SUBNET)
# ------------------------------------------------------------------------------

resource "google_compute_network" "consumer_vpc" {
  name                    = "psc-consumer-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "consumer_subnet" {
  name          = "psc-consumer-subnet"
  ip_cidr_range = "10.1.1.0/24"
  network       = google_compute_network.consumer_vpc.id
  region        = var.region
}


# ------------------------------------------------------------------------------
# 3. PRIVATE SERVICE CONNECT CONSUMER ENDPOINT
# ------------------------------------------------------------------------------

# Allocate a static internal IP for the PSC Endpoint
resource "google_compute_address" "psc_endpoint_ip" {
  name         = "psc-consumer-endpoint-ip"
  subnetwork   = google_compute_subnetwork.consumer_subnet.id
  address_type = "INTERNAL"
  region       = var.region
}

# Create the Forwarding Rule targeting the Service Attachment
resource "google_compute_forwarding_rule" "psc_endpoint" {
  name                    = "psc-consumer-endpoint"
  region                  = var.region
  network                 = google_compute_network.consumer_vpc.id
  ip_address              = google_compute_address.psc_endpoint_ip.id
  target                  = var.service_attachment_uri
  load_balancing_scheme   = ""
}


