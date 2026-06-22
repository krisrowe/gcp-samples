output "psc_endpoint_ip" {
  value       = google_compute_address.psc_endpoint_ip.address
  description = "The internal IP address allocated for the Private Service Connect endpoint."
}


output "consumer_project_id" {
  value       = var.project_id
  description = "The consumer GCP project ID."
}
