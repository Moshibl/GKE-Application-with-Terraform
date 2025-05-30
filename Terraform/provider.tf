# --------------------------------------------------------------------------
# Fetching GCP provider
# --------------------------------------------------------------------------

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.36.1"
    }
  }
}


# ---------------------------------------------------------------------
# Setting the configurations of GCP provider
# ---------------------------------------------------------------------

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}