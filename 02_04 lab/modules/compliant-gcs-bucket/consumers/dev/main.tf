terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
  }
}

provider "google" {
  project = "cgep-lab0204-500713"
  region  = "northamerica-northeast2"
}

module "data_bucket" {
  source = "../.."

  gcp_project        = "cgep-lab0204-500713"
  project_label      = "cgep-lab"
  environment        = "dev"
  retention_days     = 30
  bucket_name_suffix = "dev-data-djm-001"
  location           = "northamerica-northeast2"
  kms_location       = "northamerica-northeast2"
}
