# Lab 3.3: Writing Compliance Policies in Rego (GCP)

This lab shows how to turn Terraform compliance requirements into Rego policies that evaluate a Terraform plan before anything is applied. The goal is to prove that a plan satisfies NIST 800-53 controls for:

- SC-28: encryption at rest for GCS buckets
- AC-3: no public access to buckets or management ports
- CM-6: required compliance labels

The workflow is intentionally developer-friendly: write Terraform, generate a plan, write Rego policies, test them, and use the policy output as a fast feedback loop before deployment.

---

## What this lab teaches

By the end of the lab, you should be able to:

- Write Rego policies with metadata that maps each rule to a NIST control
- Create Rego test fixtures for both passing and failing cases
- Run policy tests against a real Terraform plan JSON file
- Use policy results to fix Terraform configuration before applying it

---

## Prerequisites

Before starting, make sure the following tools are installed and working.

### 1) OPA

Install OPA version 0.60.0 or newer.

Verify it with:

```powershell
opa version
```

Expected result: a version number greater than or equal to 0.60.0.

### 2) Terraform

Install Terraform 1.6 or newer.

Verify it with:

```powershell
terraform version
```

### 3) Google Cloud authentication

This lab uses the Google provider, so you need access to a GCP project.

Set up authentication and project context:

```powershell
gcloud auth login
gcloud config set project your-gcp-project
gcloud auth application-default login
```

Replace `your-gcp-project` with your real GCP project ID.

> The lab only generates a Terraform plan. No resources are applied, so this is safe to run.

### 4) Terraform provider access

The fixture creates resources such as:

- a GCS bucket
- a KMS key ring and crypto key
- a firewall rule

Your account must have permission to read and plan those resources in the selected project.

---

## Suggested folder structure

Create the following structure before you begin:

```powershell
mkdir -p policies/tests terraform fixtures
```

Expected layout:

```text
policies/
  ac3_no_public.rego
  cm6_required_tags.rego
  sc28_encryption.rego
  tests/
    ac3_no_public_test.rego
    cm6_required_tags_test.rego
    sc28_encryption_test.rego
terraform/
  main.tf
fixtures/
```

---

## End-to-end workflow

### Step 1: Create a Terraform fixture

Create Terraform configuration that includes:

- one compliant GCS bucket
- several intentionally non-compliant resources
- a firewall rule that exposes port 22 to the public

This gives your Rego policies something concrete to evaluate.

### Step 2: Generate a Terraform plan

Run the following in the Terraform directory:

```powershell
cd terraform
terraform init
terraform plan -out=tfplan -var="gcp_project=your-gcp-project"
terraform show -json tfplan > plan.json
```

The policy engine will evaluate the generated file at [terraform/plan.json](terraform/plan.json).

### Step 3: Write Rego policies

Create three policy files under [policies](policies):

- [policies/sc28_encryption.rego](policies/sc28_encryption.rego)
- [policies/ac3_no_public.rego](policies/ac3_no_public.rego)
- [policies/cm6_required_tags.rego](policies/cm6_required_tags.rego)

Each policy should:

- include a metadata block with a control ID
- evaluate the Terraform plan JSON
- produce deny messages when a control is violated

### Step 4: Write tests

Create test fixtures in [policies/tests](policies/tests) for:

- a compliant input that should pass
- a non-compliant input that should fail

### Step 5: Run the test suite

Run:

```powershell
opa test -v policies/
```

You should see output similar to:

```text
PASS: 8/8
```

### Step 6: Evaluate the real plan

Run each policy over the real plan:

```powershell
opa eval -d policies -i terraform/plan.json data.compliance.sc28.deny --format=pretty
opa eval -d policies -i terraform/plan.json data.compliance.ac3.deny --format=pretty
opa eval -d policies -i terraform/plan.json data.compliance.cm6.deny --format=pretty
```

You should see violations for the intentionally broken resources.

### Step 7: Fix the Terraform fixture

Update the Terraform so that:

- the bucket includes an encryption block with a KMS key reference
- public access is disabled on the bucket
- labels are added to the bucket
- the firewall no longer exposes port 22 to 0.0.0.0/0

Regenerate the plan and re-run the policy checks.

Expected result after the fix:

- SC-28 deny set is empty
- AC-3 deny set is empty
- CM-6 deny set is empty

#### Fixes applied in this lab

The following changes were made in [terraform/main.tf](terraform/main.tf) to resolve the violations found in Step 6:

| Resource | Control | Problem | Fix |
|---|---|---|---|
| `google_storage_bucket.bad_no_cmek` | SC-28 | No `encryption` block, so the bucket relied on Google-managed encryption instead of a customer-managed key. | Added an `encryption { default_kms_key_name = google_kms_crypto_key.key.id }` block referencing the KMS key created earlier in the file. |
| `google_storage_bucket.bad_public` | AC-3 | `uniform_bucket_level_access = false` and `public_access_prevention = "inherited"` allowed per-object ACLs and did not enforce blocking of public access. | Changed to `uniform_bucket_level_access = true` and `public_access_prevention = "enforced"`, matching the compliant `good` bucket. |
| `google_storage_bucket.bad_no_labels` | CM-6 | No `labels` block, so the required tags were missing. | Added the standard label set: `project`, `environment`, `managed_by`, `compliance_scope`. |
| `google_compute_firewall.open_ssh` | AC-3 | `source_ranges = ["0.0.0.0/0"]` allowed SSH (port 22) from anywhere on the internet. | Narrowed `source_ranges` to `["10.0.0.0/8"]` so port 22 is only reachable from inside the VPC. |

After applying these fixes, regenerate the plan and re-run the `opa eval` commands from Step 6 — all three deny sets should return `[]`.

---

## What each policy checks

### SC-28: Encryption at Rest

Ensures every GCS bucket has an encryption block with a customer-managed KMS key reference.

### AC-3: No Public Access

Ensures:

- GCS buckets enforce uniform bucket-level access and public access prevention
- firewall rules do not allow management ports 22 or 3389 from 0.0.0.0/0

### CM-6: Required Labels

Ensures taggable resources have the required labels:

- project
- environment
- managed_by
- compliance_scope

---

## Helpful notes for this lab

- The Terraform plan uses JSON values that may appear under child modules, so your Rego rules should recurse through child modules when needed.
- For encryption, the plan may not contain a fully resolved KMS key ID at plan time. A present encryption block is enough for this policy to consider CMEK configuration as set.
- The deny messages should include the resource address and the control ID so that developers can quickly identify the problem.

---

## Troubleshooting

### OPA parse error related to metadata

If you see an error about YAML parsing in the metadata block, make sure string values like descriptions and remediation text are wrapped in quotes.

### Policy unexpectedly fires for a passing fixture

Check whether the resource is nested under child modules in the plan JSON. In that case, your rule should iterate over child modules as well as root resources.

### Encryption policy is too strict

Do not require the KMS key value to be a fully populated string in the plan JSON. At plan time, Terraform may show the value as unknown. A non-empty encryption block is the correct signal here.

---

## Portfolio checklist

When you are done, make sure you have:

- Rego policies in [policies](policies)
- Test files in [policies/tests](policies/tests)
- A real plan file at [terraform/plan.json](terraform/plan.json)
- A README file like this one
- Evidence of passing policy tests

---

## Quick-start commands

If you want the shortest possible path, use this sequence:

```powershell
mkdir -p policies/tests terraform fixtures
cd terraform
terraform init
terraform plan -out=tfplan -var="gcp_project=your-gcp-project"
terraform show -json tfplan > plan.json
cd ..
opa test -v policies/
```

Then evaluate the policies against the plan:

```powershell
opa eval -d policies -i terraform/plan.json data.compliance.sc28.deny --format=pretty
opa eval -d policies -i terraform/plan.json data.compliance.ac3.deny --format=pretty
opa eval -d policies -i terraform/plan.json data.compliance.cm6.deny --format=pretty
```
