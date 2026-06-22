variable "project_id" {
  type        = string
  description = "The GCP Project ID to deploy the consumer resources into."
}

variable "region" {
  type        = string
  description = "The GCP region for the consumer resources."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "The GCP zone for the test client instance."
  default     = "us-central1-f"
}

variable "service_attachment_uri" {
  type        = string
  description = "The URI of the published Service Attachment from the Producer stage."
}
