# Lab 2.5: IaC as Compliance Evidence (AWS)

## Problem Statement

Compliance auditors require evidence that infrastructure was deployed correctly, by whom, and that the evidence itself has not been tampered with. Screenshots of AWS console states are weak evidence — they carry no integrity guarantee, no attribution, and cannot be reproduced. A malicious or negligent admin can delete or alter them silently.

The challenge is to build a system where:
- Infrastructure state is captured as structured, machine-readable artifacts
- Each artifact is cryptographically hashed so tampering is detectable
- The storage vault physically refuses deletion within a retention window
- A durable receipt ties the uploaded bundle to a specific immutable version

## What We Built

### Evidence Vault (`terraform/`)

An S3 bucket with Object Lock enabled at creation time — the only point at which it can be enabled. The vault enforces:

| Control | Implementation |
|---|---|
| Immutability | Object Lock (GOVERNANCE mode, 1-day default retention) |
| Versioning | S3 Versioning enabled (required by Object Lock) |
| Encryption at rest | AES-256 server-side encryption |
| Public access | All public access blocked |
| Deletion protection | Bucket policy denies `s3:DeleteBucket` for all principals except account root |

### Capture Script (`scripts/capture-evidence.sh`)

A bash script that reads a Terraform workspace and produces a tamper-evident bundle:

1. Exports the Terraform plan as JSON (`plan.json`)
2. Pulls current Terraform state (`state.json`)
3. Records the last git commit (`commit.txt`)
4. Records the Terraform version (`version.txt`)
5. SHA-256 hashes every file and writes a `manifest.json`
6. Tars the bundle and uploads to the vault via `aws s3api put-object`
7. Prints a single-line JSON receipt with the S3 `VersionId` — the durable, immutable handle to this exact upload

### Evidence Receipt (`evidence/lab-2-5/receipt.json`)

```json
{"run_id":"test-001","vault":"cgep-lab-grc-evidence-vault-a37d6236","key":"runs/test-001/bundle.tar.gz","version_id":"zeuWXsTs5FmL3Zd6liEp5FPi6VhU3w8H","captured_at_utc":"2026-06-28T17:36:47Z"}
```

## What We Achieved

### Three Properties Auditors Require

| Property | How This Lab Delivers It |
|---|---|
| **Integrity** | SHA-256 manifest + Object Lock prevents silent alteration |
| **Attribution** | `commit.txt` records who committed; AWS CloudTrail records who uploaded |
| **Reproducibility** | `plan.json` and `state.json` fully describe what was deployed and what configuration produced it |

### Verified Immutability

Three explicit checks confirmed the vault works as designed:

1. **Object Lock configured** — `get-object-lock-configuration` confirmed GOVERNANCE mode with 1-day retention on the bucket
2. **Retention on uploaded object** — `get-object-retention` confirmed `RetainUntilDate: 2026-06-29T17:37:03Z`
3. **Delete attempt blocked** — `delete-object` returned `AccessDenied: Access Denied because object protected by object lock`

The AccessDenied response on the delete attempt is the core proof: even a privileged IAM user cannot destroy the evidence within its retention window.

## Architecture

```
Lab 2.3 workspace              capture-evidence.sh              Object Lock vault
─────────────────              ───────────────────              ─────────────────
tfplan, .tf files,   ──▶      plan.json, state.json,  ──▶     s3://vault/runs/RUN_ID/
terraform.tfstate,            commit.txt, version.txt,          bundle.tar.gz
git log                        SHA-256 manifest,                 Retention: GOVERNANCE
                               tar + upload                      VersionId in receipt
```

## Key Design Decisions

- **GOVERNANCE vs COMPLIANCE**: GOVERNANCE mode is used for lab work so the bucket can be cleaned up. Production evidence vaults should use COMPLIANCE mode, which cannot be bypassed by anyone until retention expires.
- **Object Lock at creation**: S3 Object Lock cannot be retrofitted onto an existing bucket. The bucket must be created with `object_lock_enabled = true`.
- **VersionId as the evidence handle**: Every downstream reference (OSCAL component evidence links, audit reports) should point to `s3://VAULT/KEY?versionId=...` — not just the key — to pin the exact immutable version.

## How This Feeds the Capstone

This vault is the capstone's evidence vault. Every PR that closes a gap in the cgep-app-starter runs through the Lab 4.3 pipeline, which calls Lab 4.4's signing step and uploads to this vault using this exact pattern. OSCAL component evidence links in Chapter 6 resolve to objects stored here.
