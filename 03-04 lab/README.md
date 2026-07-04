# Lab 3.4: Integrating PaC with Terraform via Conftest (AWS)

Lab 3.3 wrote three Rego policies (SC-28, AC-3, CM-6) against GCP fixtures. This lab takes that same policy library and points it at an AWS Terraform plan using Conftest instead of `opa eval`. The GCP-typed rules don't match anything in an AWS plan, which forces the real exercise: add AWS-resource-type variants of each rule while keeping the control ID stable. The control ID is the portable unit, not the Rego resource-type match.

---

## What this lab teaches

- Wiring Conftest into the Terraform plan workflow as a fail-closed gate
- Adding AWS variants of SC-28 and AC-3 policies without breaking the GCP originals
- Matching Terraform resources by `configuration` references instead of `planned_values`, because plan-time values for generated names are unknown
- Proving the gate actually blocks a merge by feeding it a deliberately broken plan

---

## Prerequisites

- [02-03 lab/cgep-labs/terraform/primitives/compliant-s3](../02-03%20lab/cgep-labs/terraform/primitives/compliant-s3) — the compliant AWS S3 primitive from Lab 2.3. Its plan is the input for this lab.
- [03-03 lab/policies](../03-03%20lab/policies) — the Lab 3.3 policy library (3 rules, 8 tests, all passing).
- Conftest installed (`conftest --version`). Tested with 0.50+.
- AWS credentials for the sandbox account used in Lab 2.3.

---

## Architecture

```text
Lab 2.3 workspace          policy-gate.sh (this lab)         CI (Lab 4.3)
──────────────────         ────────────────────────         ──────────────
terraform plan -out=tfplan ─▶  terraform show -json    ─▶   on every PR:
                                conftest test                run policy-gate.sh,
                                (per namespace)               fail closed on any
                                                              violation
```

---

## Step-by-step: problem and solution

### Step 1 — Carry the library forward

**Problem:** The Lab 3.3 policies live in a different lab folder. Conftest needs them local to this workspace, and we need proof they still pass before touching anything.

**Solution:**

```powershell
Copy-Item -Recurse "..\03-03 lab\policies" ".\policies"
opa test -v policies/
```

Expected: `PASS: 8/8`. If this fails, the problem is in the copy, not in anything new — fix it before moving on.

### Step 2 — Generate `plan.json` from Lab 2.3

**Problem:** Conftest evaluates the Terraform plan as JSON, not `.tf` files or HCL state. Lab 2.3 never produced this artifact, and this lab needs its own copy of the plan rather than reaching into another lab's workspace every time the gate runs.

**Solution:** copy the primitive's `.tf` files into a local [terraform/](terraform) workspace in this lab, then plan and export as usual:

```powershell
mkdir terraform
Copy-Item "..\02-03 lab\cgep-labs\terraform\primitives\compliant-s3\main.tf","..\02-03 lab\cgep-labs\terraform\primitives\compliant-s3\variables.tf","..\02-03 lab\cgep-labs\terraform\primitives\compliant-s3\outputs.tf" ".\terraform\"
cd terraform
terraform init
terraform plan -out=tfplan -var="project_name=cgep" -var="environment=dev"
terraform show -json tfplan > plan.json
```

This ran against live AWS credentials (`aws sts get-caller-identity` confirmed the sandbox account) and produced a real plan: 11 resources to add (S3 bucket, encryption config, public access block, versioning, logging, etc.), matching the Lab 2.3 primitive exactly.

### Step 3 — Run the GCP policies against the AWS plan (the cross-cloud lesson)

**Problem:** It's tempting to assume "the policy library already covers SC-28 and AC-3" and skip straight to CI wiring.

**Solution / observation:** run it and watch it lie to you:

```powershell
conftest test --policy policies --namespace compliance.sc28 plan.json
conftest test --policy policies --namespace compliance.ac3  plan.json
conftest test --policy policies --namespace compliance.cm6  plan.json
```

SC-28 and AC-3 report a pass — but it's a false pass. They check `google_storage_bucket` and `google_compute_firewall`, and there are zero GCP resources in an AWS plan, so the deny set is trivially empty. Zero coverage, not zero risk. CM-6 is closer to being cloud-agnostic since it only checks tag/label keys, but it still needs an AWS-aware resource-type filter (`labels` vs `tags`/`tags_all`).

**Takeaway:** a control ID (`SC-28`, `AC-3`) is portable across clouds; a Rego rule that hardcodes `resource.type == "google_storage_bucket"` is not. Fix this by adding per-cloud rule variants under the same control ID, rather than trying to write one rule that special-cases every resource type.

### Step 4 — Add the AWS variant of SC-28

**Problem:** `aws_s3_bucket_server_side_encryption_configuration` is a separate resource from `aws_s3_bucket` in the AWS provider (unlike GCP's inline `encryption` block). At plan time, both resources' `values.bucket` show up as `null` / "known after apply" because the bucket name depends on `random_id.bucket_suffix`, which hasn't been generated yet. Matching on `planned_values` values doesn't work.

**Solution:** match on `configuration.root_module.resources[].expressions.bucket.references` instead — this is a static list of reference strings (e.g. `"aws_s3_bucket.primary.id"`) that Terraform resolves at apply, and it's already populated at plan time.

File: `policies/sc28_encryption_aws.rego` (package `compliance.sc28_aws`, control ID `SC-28`, unchanged). Walks every `aws_s3_bucket` address, and denies any that no `aws_s3_bucket_server_side_encryption_configuration` resource references via `bucket`, `bucket.id`, or `bucket.bucket`.

### Step 5 — Add the AWS variant of AC-3

**Problem:** GCP's AC-3 rule checks a single boolean-ish setting (`public_access_prevention = "enforced"`). AWS splits public-access control into four independent flags on a separate `aws_s3_bucket_public_access_block` resource, and a bucket with the resource present but only 3 of 4 flags true is still non-compliant.

**Solution:** File `policies/ac3_no_public_aws.rego` (package `compliance.ac3_aws`, control ID `AC-3`). Finds the `aws_s3_bucket_public_access_block` referencing each bucket (same reference-matching technique as Step 4), then checks its `planned_values` — `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets` must **all** be `true`. Missing the PAB resource entirely, or having any flag false/absent, denies.

### Step 6 — Add the AWS variant of CM-6

**Problem:** GCP resources carry `labels`; AWS resources carry `tags`, and when a provider sets `default_tags` (as this workspace's `compliant-s3/main.tf` does), the fully merged tag set only appears in `tags_all`, not `tags`.

**Solution:** File `policies/cm6_required_tags_aws.rego` (package `compliance.cm6_aws`, control ID `CM-6`). Checks `tags_all` first, falls back to `tags` if `tags_all` isn't set, and denies any taggable resource (`aws_s3_bucket`, `aws_dynamodb_table`, `aws_lambda_function`, `aws_kms_key`, `aws_cloudtrail`) missing any of `Project`, `Environment`, `ManagedBy`, `ComplianceScope`. Also recurses into `child_modules`, not just the root module.

### Step 7 — Run the gate against the compliant plan

**Problem:** Need to confirm the three new AWS variants actually pass against a known-compliant plan before trusting them as a gate.

**Solution:**

```powershell
foreach ($ns in "compliance.sc28_aws","compliance.ac3_aws","compliance.cm6_aws") {
  Write-Output "=== $ns ==="
  conftest test --policy policies --namespace $ns plan.json
}
```

Expected: `1 test, 1 passed, 0 warnings, 0 failures, 0 exceptions` for all three. Lab 2.3's plan (`aws_s3_bucket_server_side_encryption_configuration.primary` present, `aws_s3_bucket_public_access_block.primary` with all four flags `true`, `default_tags` supplying all four required keys) satisfies every rule.

### Step 8 — Break it and watch the gate fire

**Problem:** A gate that has never failed is unproven. Need a negative-path demonstration that a real regression gets blocked, not silently waved through.

**Solution:** copy the workspace into [broken/](broken), delete the encryption resource, regenerate the plan:

```powershell
mkdir broken
Copy-Item ".\terraform\*.tf" ".\broken\"
# edit broken/main.tf: remove the aws_s3_bucket_server_side_encryption_configuration.primary block
cd broken
terraform init
terraform plan -out=tfplan -var="project_name=cgep" -var="environment=dev"
terraform show -json tfplan > plan.json
cd ..
conftest test --policy policies --namespace compliance.sc28_aws broken/plan.json
```

`outputs.tf` also had to be trimmed — it had an `encryption_algorithm` output referencing `aws_s3_bucket_server_side_encryption_configuration.primary.rule`, so `terraform plan` refused to run (`Reference to undeclared resource`) until that output was removed alongside the resource. A reminder that "delete one resource" in Terraform often means "delete everything that references it too."

Expected:

```text
FAIL - broken/plan.json - compliance.sc28_aws - [SC-28] aws_s3_bucket.primary: aws_s3_bucket has no matching aws_s3_bucket_server_side_encryption_configuration. Remediation: add one referencing this bucket.

1 test, 0 passed, 0 warnings, 1 failure, 0 exceptions
```

Non-zero exit code. The message names the resource, the control, and the fix — enough for a developer to act on without reading the Rego.

### Step 9 — Wrap it in a single script for CI

**Problem:** Lab 4.3's CI workflow needs one command to call, not four `conftest` invocations with manual JSON parsing and a mental model of exit codes.

**Solution:** [scripts/policy-gate.sh](scripts/policy-gate.sh) runs all four namespaces (`sc28_aws`, `ac3_aws`, `cm6_aws`, plus the original GCP-typed `cm6` in case a mixed-cloud plan ever needs it), writes a combined JSON evidence file to `evidence/lab-3-4/conftest-results.json`, and exits non-zero if any namespace has a failure.

Key choices baked into the script:

- `|| true` after each `conftest test` call — one namespace failing must not abort the loop before the others run and get recorded.
- `--output=json` — CI needs a machine-readable artifact, not text scraped from stdout.
- A Python one-liner to decide pass/fail from the JSON — parsing nested JSON correctly in pure bash is more effort than it's worth. The script honors a `PYTHON` env var (defaults to `python3`) so it works on machines where the launcher isn't named `python3` on PATH.

**Bug found while implementing this:** the reference version of this script (and the lab writeup) does `( cd "$WORKSPACE" && terraform show -json tfplan > "$WORKSPACE/plan.json" )`. Once the subshell has `cd`'d into `$WORKSPACE`, the redirect target `"$WORKSPACE/plan.json"` is resolved *again* relative to the new working directory — i.e. it tries to write `terraform/terraform/plan.json`, which fails because there's no nested `terraform/` directory. Fixed by writing to the bare `plan.json` inside the subshell instead, since the `cd` already put us where we need to be.

---

## Verification

Actually run, not just described:

- **Compliant plan** ([terraform/](terraform) — a copy of the Lab 2.3 `compliant-s3` primitive, planned against live AWS credentials): `bash scripts/policy-gate.sh --workspace terraform` → `policy-gate: PASS`, exit `0`, zero failures across `sc28_aws`, `ac3_aws`, `cm6_aws`.
- **Broken plan** ([broken/](broken) — same config with `aws_s3_bucket_server_side_encryption_configuration.primary` and its output removed): `bash scripts/policy-gate.sh --workspace broken` → `policy-gate: FAIL`, exit `1`, with `evidence/lab-3-4/conftest-results-broken.json` containing the `[SC-28] aws_s3_bucket.primary: ...` failure message and `null` failures for the other three namespaces (only encryption was broken).
- `evidence/lab-3-4/conftest-results-compliant.json` and `evidence/lab-3-4/conftest-results-broken.json` both exist and hold the full Conftest JSON output per namespace. (Named per-run here since this lab captures both the pass and fail case side by side; the script itself always writes to `conftest-results.json`, so CI would just keep the latest.)

---

## Portfolio checklist

- [x] `policies/` carried forward from Lab 3.3, `opa test -v policies/` still 8/8
- [x] `policies/sc28_encryption_aws.rego`, `policies/ac3_no_public_aws.rego`, `policies/cm6_required_tags_aws.rego` added and passing against a real plan
- [x] `scripts/policy-gate.sh` runs all namespaces and writes evidence JSON (path bug found and fixed during implementation)
- [x] `evidence/lab-3-4/conftest-results-compliant.json` and `conftest-results-broken.json`
- [x] This README

---

## Notes for later labs

- Lab 4.3 wires `scripts/policy-gate.sh` into CI as a required check on every PR.
- If a future cloud (Azure) gets added, the pattern repeats: add `sc28_encryption_azure.rego` etc. under the same control IDs rather than trying to generalize the resource-type match.
