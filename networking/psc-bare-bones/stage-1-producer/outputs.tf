output "service_attachment_uri" {
  value       = google_compute_service_attachment.producer_service_attachment.id
  description = "The URI of the published Private Service Connect Service Attachment. Share this with the consumer."
}
