# Lab 4.3: Building a GRC Evidence Pipeline (AWS + GitHub Actions)

The local Conftest gate from [Lab 3.4](../03-04%20lab) catches violations on one laptop. This lab wires that same gate into GitHub Actions so it runs on every pull request, adds a `tfsec` scan, and uploads a named evidence artifact for every run. The workflow YAML committed here **is** the CM-3, CM-6, CA-2, RA-5, and AU-9 evidence — nobody can quietly edit a run after the fact, and every PR gets its own timestamped, named artifact.

---

## What this lab teaches

- Wiring AWS OIDC trust to GitHub Actions so the workflow assumes an IAM role without any long-lived key ever touching GitHub
- Running `terraform plan`, Conftest, and `tfsec` on every PR, failing closed on policy violations or high/critical findings
- Capturing evidence even when the gate fails — a check that only produces proof on the happy path isn't proof of anything
- Naming the evidence artifact (`grc-evidence-<run-id>`) so every run is individually addressable, not overwritten by the next one
- Verifying third-party Action names and release assets actually exist before trusting them in CI — one didn't

---

## Prerequisites — verified against this repo

| Prerequisite | Status |
|---|---|
| GitHub repo you own | `debjym/cgep-labs`, public, branch `main`, pushed and up to date with origin |
| AWS account with permission to create an IAM OIDC provider + role | Confirmed — user `grcengineering` has `AdministratorAccess` via the `GRC_AWSmanagedAdministratorAccess` group |
| Lab 2.3 / 3.3 / 3.4 artifacts committed | Confirmed — [terraform/primitives/compliant-s3](../terraform/primitives/compliant-s3) (2.3), [03-03 lab/policies](../03-03%20lab/policies) (3.3), [03-04 lab/policies](../03-04%20lab/policies) + [03-04 lab/scripts/policy-gate.sh](../03-04%20lab/scripts/policy-gate.sh) (3.4) |
| AWS CLI v2, working profile | Confirmed — v2.34.41, default profile, account `612063236841` |
| No pre-existing OIDC provider collision | Confirmed — `aws iam list-open-id-connect-providers` returned empty before this lab |

One correction versus the prompt as given: it references a reference implementation wired to `cgep-app-starter`. That's the lab author's example repo, not this one — the trust policy here is scoped to `repo:debjym/cgep-labs`.

---

## Architecture

```text
PR opened  ───▶  workflow run (.github/workflows/grc-evidence-pipeline.yml)
                     │
                     ├── Configure AWS creds (OIDC via aws-actions/configure-aws-credentials, no keys on disk)
                     ├── terraform init / plan   (terraform/primitives/compliant-s3, the Lab 2.3 primitive)
                     ├── Conftest gate           (03-04 lab/scripts/policy-gate.sh — fails closed on policy failures)
                     ├── tfsec scan              (fails closed on high/critical)
                     ├── Upload evidence artifact (plan.json, conftest-results.json, tfsec.sarif) named grc-evidence-<run-id>
                     └── Comment on PR with pass/fail summary
```

Note on the OIDC trust condition: GitHub's OIDC token sets the `sub` claim to `repo:<owner>/<repo>:pull_request` for `pull_request`-triggered runs specifically — **not** the `ref:refs/heads/<branch>` form, which only appears on push/schedule/workflow_dispatch runs. [terraform/oidc/main.tf](terraform/oidc/main.tf) scopes to the `pull_request` form since that's this workflow's trigger; scoping to a branch ref here would silently never match and every `AssumeRoleWithWebIdentity` call would fail closed for the wrong reason.

Because the repo is public, that trust condition matches a `pull_request` event from *any* fork, not just maintainer-opened PRs. The attached IAM policy is deliberately read-only and scoped to `arn:aws:s3:::cgep-*`, which bounds the blast radius — but it's a real, accepted tradeoff, not an oversight. Tightening it further (GitHub Environment approval gates for fork PRs, or skipping the AWS steps entirely when `github.event.pull_request.head.repo.full_name != github.repository`) is flagged as follow-up work, not done in this pass.

---

## Step-by-step: problem and solution

### Step 1 — Stand up the OIDC trust

**Problem:** GitHub Actions needs to assume an AWS role without ever storing an access key as a GitHub secret.

**Solution:** [terraform/oidc/main.tf](terraform/oidc/main.tf) creates the IAM OIDC identity provider for `token.actions.githubusercontent.com` (thumbprint fetched live via a `tls_certificate` data source, not hand-copied) plus an IAM role (`github-actions-grc-evidence`) whose trust policy checks both `aud=sts.amazonaws.com` and `sub=repo:debjym/cgep-labs:pull_request`, and a least-privilege inline policy (`sts:GetCallerIdentity` + read-only S3 actions scoped to `arn:aws:s3:::cgep-*`).

```powershell
cd "04-03 lab/terraform/oidc"
terraform init
terraform plan
terraform apply
```

Actually applied. `terraform state list` confirms all 3 resources live:

```text
oidc_provider_arn = "arn:aws:iam::612063236841:oidc-provider/token.actions.githubusercontent.com"
role_arn          = "arn:aws:iam::612063236841:role/github-actions-grc-evidence"
```

`role_arn` matches the `ROLE_ARN` hardcoded in the workflow's `env:` block exactly — nothing wires the two together automatically, so this was checked, not assumed.

### Step 2 — Reject two stray/competing drafts before committing

**Problem:** Along the way, two other partial implementations surfaced that didn't match this repo — worth documenting because they'd have quietly shipped weaker security if merged without comparison:

- A second, unapplied `04-03 lab/main.tf` at the top level used the AWS-managed `ReadOnlyAccess` policy (read access to *every* service in the account, not just the S3 buckets this pipeline touches), a hardcoded/stale OIDC thumbprint, and a wildcard trust scope (`repo:org/repo:*` matching every ref, not just `pull_request`). Never applied (no local Terraform state existed for it), kept on disk untracked, excluded from git.
- A full alternate workflow draft (`grc-gate.yml`) referenced paths that don't exist in this repo (`terraform/`, `policies/`, `../policies` instead of `terraform/primitives/compliant-s3` and `03-04 lab/policies`) and a `${{ vars.AWS_ROLE_ARN }}` repo variable that was never created. Discarded; the working `grc-evidence-pipeline.yml` was kept.

### Step 3 — Verify third-party Action names before trusting them

**Problem:** It's easy to write `uses: some-org/some-action@vX` from memory and assume it exists.

**Solution / what was actually caught:** `aquasecurity/setup-tfsec` — the action originally referenced for installing tfsec — **does not exist** (`gh api repos/aquasecurity/setup-tfsec` returns 404). This would have failed the very first run with "action not found," before ever reaching the scan. Fixed by installing the `tfsec` binary directly via `curl`, mirroring the pattern already used for Conftest:

```yaml
- name: Install tfsec
  run: |
    TFSEC_VERSION=1.28.14
    curl -fsSL "https://github.com/aquasecurity/tfsec/releases/download/v${TFSEC_VERSION}/tfsec-linux-amd64" -o /usr/local/bin/tfsec
    chmod +x /usr/local/bin/tfsec
```

Both release assets (`tfsec-linux-amd64` for `v1.28.14`, `conftest_0.56.0_Linux_x86_64.tar.gz` for Conftest) were confirmed to actually exist via `gh api repos/<org>/<repo>/releases/tags/<tag>` before trusting them in CI.

### Step 4 — Commit, push, open the PR

```powershell
git checkout -b add-grc-gate
git add .github/workflows/grc-evidence-pipeline.yml "04-03 lab/README.md" "04-03 lab/evidence" "04-03 lab/terraform"
git commit -m "Add GRC evidence pipeline"
git push -u origin add-grc-gate
gh pr create --title "Add GRC evidence pipeline" --base main
```

PR opened: **https://github.com/debjym/cgep-labs/pull/1**

### Step 5 — First real run: a genuine variable-validation bug

**Problem:** The workflow originally passed `-var="environment=ci-pr-${{ github.event.pull_request.number }}"` for per-run uniqueness.

**Observed failure** (run [29171473217](https://github.com/debjym/cgep-labs/actions/runs/29171473217), failed in 25s): `terraform/primitives/compliant-s3/variables.tf` validates `environment` against `contains(["dev", "staging", "prod"], var.environment)` — `"ci-pr-1"` doesn't match, so `terraform plan` errored before Conftest or tfsec ever ran. Also confirmed as a side effect: the OIDC step itself had already succeeded (`AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN` were live in the step env) — the trust relationship worked correctly on the very first try.

**Fix:** per-run bucket-name uniqueness is already handled by the module's own `random_id.bucket_suffix` logic (see [terraform/primitives/compliant-s3/main.tf](../terraform/primitives/compliant-s3/main.tf)), so encoding the PR number into `environment` was unnecessary. Changed to `-var="environment=dev"`, matching Lab 3.4's precedent.

### Step 6 — Second real run: a genuine tfsec finding

**Observed failure** (run [29171522863](https://github.com/debjym/cgep-labs/actions/runs/29171522863)): Conftest passed — confirming the AWS-variant SC-28/AC-3/CM-6 policies from Lab 3.4 still correctly validate the compliant primitive — but tfsec failed with a HIGH-severity finding:

```text
aws-s3-encryption-customer-key: Bucket does not encrypt data with a customer managed key.
  main.tf:43-59 (aws_s3_bucket_server_side_encryption_configuration.primary)
```

This is not a pipeline bug. The Lab 2.3 primitive deliberately uses SSE-S3 (`AES256`) and already has a commented-out "KMS teaser" block noting the customer-managed-key migration is "covered in a later lab." The tfsec gate correctly caught that deferred gap.

**Decision:** document and accept the finding rather than weaken the gate. Added a scoped, reasoned ignore directly above the resource in `terraform/primitives/compliant-s3/main.tf`:

```hcl
#tfsec:ignore:aws-s3-encryption-customer-key -- SSE-S3 accepted at this lab stage; KMS migration is the commented block below, tracked for a later lab, not a missed finding.
resource "aws_s3_bucket_server_side_encryption_configuration" "primary" {
```

A pure-comment change — no functional resource diff, no `terraform apply` needed.

### Step 7 — Third run: fully green

Run [29171631129](https://github.com/debjym/cgep-labs/actions/runs/29171631129) — every step passed, including OIDC, `terraform plan`, Conftest, tfsec, evidence upload, and the PR comment. The `Fail closed if any gate failed` step correctly **skipped** (nothing to fail on). PR comment:

```text
### GRC Evidence Pipeline
- Conftest policy gate: pass
- tfsec (high/critical): pass
- Evidence artifact: grc-evidence-29171631129
```

Evidence artifact downloaded and inspected directly (`gh run download 29171631129 -n grc-evidence-29171631129`) — contains `plan.json`, `conftest-results.json`, `tfsec.sarif`, all populated with real content from a live run against real AWS credentials.

---

## Still open — not yet done

### Negative-path proof (fail-closed on a real regression)

Not yet executed on this PR. To prove it: on a branch, remove `aws_s3_bucket_server_side_encryption_configuration.primary` (and the output referencing it) from `terraform/primitives/compliant-s3/main.tf`, push, and confirm the Conftest step fails the SC-28 check, the evidence artifact is still uploaded (`if: always()`), the PR comment shows the failure, and the job goes red. Revert afterward — don't merge the broken change.

### Require the check in branch protection

Branch protection on `main` requiring the `evidence` job as a required status check turns "the gate reports failure" into "the merge button is actually disabled." This workflow produces the signal; enabling the required-check setting on the repo is what makes it binding. A one-time repo setting, not scripted here.

### Tighten fork-PR trust scope (optional hardening)

As noted in Architecture above: any fork can currently trigger a run that assumes this read-only role. Consider a GitHub Environment approval gate or a `github.event.pull_request.head.repo.full_name == github.repository` condition on the AWS-touching steps if this repo starts accepting external contributions.

---

## Verification

Actually run, not just described — three real workflow runs on PR #1 (branch `add-grc-gate`), in order:

| Run | Result | Cause |
|---|---|---|
| [29171473217](https://github.com/debjym/cgep-labs/actions/runs/29171473217) | ❌ failed (25s) | `environment` value failed the module's own validation rule |
| [29171522863](https://github.com/debjym/cgep-labs/actions/runs/29171522863) | ❌ failed (31s) | Genuine tfsec HIGH finding (SSE-S3 vs customer-managed KMS) |
| [29171631129](https://github.com/debjym/cgep-labs/actions/runs/29171631129) | ✅ passed (26s) | Fixed environment var + documented tfsec exception |

Evidence artifact from the passing run: `grc-evidence-29171631129`, containing `plan.json`, `conftest-results.json`, `tfsec.sarif` — downloaded and confirmed non-empty.

---

## Portfolio checklist

- [x] `terraform/oidc/` applied — OIDC provider + role live in the account (`arn:aws:iam::612063236841:role/github-actions-grc-evidence`)
- [x] `.github/workflows/grc-evidence-pipeline.yml` committed and pushed
- [x] Positive-path PR run: OIDC assume succeeds, both gates pass, `grc-evidence-<run-id>` artifact present, PR comment posted (PR #1, run 29171631129)
- [ ] Negative-path PR run: gate fails closed, evidence still captured, PR comment shows failure
- [ ] (Recommended) branch protection requires this check on `main`
- [ ] (Optional hardening) fork-PR trust scope tightened

---

## Notes for later labs

- Lab 4.4 adds Cosign signing of the evidence bundle and uploads it to the Lab 2.5 S3 Object Lock vault.
- If a future workflow trigger type is added (e.g. `workflow_dispatch` for manual re-runs), its OIDC `sub` claim form differs again — check GitHub's docs for that trigger before assuming the existing trust condition covers it.
- Before trusting any third-party Action by name, verify it exists (`gh api repos/<org>/<repo>`) and that the release asset you're pinning to is real (`gh api repos/<org>/<repo>/releases/tags/<tag>`). One didn't, in this lab.
