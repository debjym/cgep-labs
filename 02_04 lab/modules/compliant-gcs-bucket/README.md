# compliant-gcs-bucket

Terraform module that provisions a hardened GCS bucket with a customer-managed encryption key (CMEK). The security baseline is locked inside the module; consumers may supply business settings but cannot disable the controls below.

## Controls enforced

| Control family | Control | How it is enforced |
|---|---|---|
| **SC-12** | Cryptographic key establishment — the key is owned by the customer, not Google. | `google_kms_key_ring` + `google_kms_crypto_key` |
| **SC-13 / SC-28** | Data at rest is encrypted with a CMEK; the key rotates every 90 days (`7776000s`). | `encryption {}` block on the bucket + `rotation_period` on the key |
| **AU-11** | Objects are retained for a configurable period; production requires ≥ 365 days (enforced at plan time). | `retention_policy` block + `validation` in `variables.tf` |
| **CM-6** | Four required compliance labels (`project`, `environment`, `managed_by`, `compliance_scope`) are merged on top of any consumer-supplied labels and cannot be removed. | `merge(var.labels, local.required_labels)` in `locals` |
| **AC-3** | Uniform bucket-level access is enforced and public access is blocked. | `uniform_bucket_level_access = true` + `public_access_prevention = "enforced"` |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `gcp_project` | string | — | GCP project ID |
| `location` | string | `us-central1` | GCS bucket location |
| `kms_location` | string | `us-central1` | KMS keyring location (must be a single region) |
| `project_label` | string | — | Short project identifier (3–21 chars, lowercase) |
| `environment` | string | — | `dev`, `staging`, or `prod` |
| `retention_days` | number | — | Object retention in days (1–3650; ≥ 365 for prod) |
| `bucket_name_suffix` | string | — | Globally unique suffix appended to the bucket name |
| `labels` | map(string) | `{}` | Optional additional labels |

## Outputs

| Name | Description |
|---|---|
| `bucket_url` | `gs://` URL of the compliant bucket |
| `bucket_self_link` | Self-link of the compliant bucket |
| `kms_key_id` | Resource ID of the CMEK |
| `compliance_attestation` | Machine-readable map attesting which controls are active |

## Usage

```hcl
module "data_bucket" {
  source = "../../modules/compliant-gcs-bucket"

  gcp_project        = "your-gcp-project"
  project_label      = "cgep-lab"
  environment        = "dev"
  retention_days     = 30
  bucket_name_suffix = "dev-data-001"
}

output "attestation" { value = module.data_bucket.compliance_attestation }
output "bucket_url"  { value = module.data_bucket.bucket_url }
```
