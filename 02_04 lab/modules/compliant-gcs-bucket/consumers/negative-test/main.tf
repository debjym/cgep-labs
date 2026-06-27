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
  environment        = "prod"
  retention_days     = 30   # FAILS: prod requires >= 365
  bucket_name_suffix = "should-never-exist"
  location           = "northamerica-northeast2"
  kms_location       = "northamerica-northeast2"
}
