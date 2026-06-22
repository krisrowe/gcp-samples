variable "project_id" {
  type        = string
  description = "The GCP Project ID to deploy the producer resources into."
}

variable "region" {
  type        = string
  description = "The GCP region for the producer resources."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "The GCP zone for the backend instances."
  default     = "us-central1-f"
}
