# Lab 4.3: Building a GRC Evidence Pipeline (AWS + GitHub Actions)

The local Conftest gate from [Lab 3.4](../03-04%20lab) catches violations on one laptop. This lab wires that same gate into GitHub Actions so it runs on every pull request, adds a `tfsec` scan, and uploads a named evidence artifact for every run. The workflow YAML committed here **is** the CM-3, CM-6, CA-2, RA-5, and AU-9 evidence — nobody can quietly edit a run after the fact, and every PR gets its own timestamped, named artifact.

---

## What this lab teaches

- Wiring AWS OIDC trust to GitHub Actions so the workflow assumes an IAM role without any long-lived key ever touching GitHub
- Running `terraform plan`, Conftest, and `tfsec` on every PR, failing closed on policy violations or high/critical findings
- Capturing evidence even when the gate fails — a check that only produces proof on the happy path isn't proof of anything
- Naming the evidence artifact (`grc-evidence-<run-id>`) so every run is individually addressable, not overwritten by the next one

---

## Prerequisites — verified against this repo

| Prerequisite | Status |
|---|---|
| GitHub repo you own | `debjym/cgep-labs`, branch `main`, pushed and up to date with origin |
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

---

## What's been scaffolded so far

- [terraform/oidc/](terraform/oidc) — Terraform for the IAM OIDC provider + role (`github-actions-grc-evidence`) + a least-privilege read-only policy scoped to `arn:aws:s3:::cgep-*` and `sts:GetCallerIdentity`. **Not yet applied** — see Step 1 below.
- [.github/workflows/grc-evidence-pipeline.yml](../.github/workflows/grc-evidence-pipeline.yml) — the pipeline itself, at repo root (GitHub only reads workflows from `.github/workflows`).

Both are written but unexecuted. The steps below are what's left to actually stand this up.

---

## Step-by-step: what's left to do

### Step 1 — Apply the OIDC provider + role

```powershell
cd "04-03 lab/terraform/oidc"
terraform init
terraform plan
terraform apply
```

Expect 3 resources to add: `aws_iam_openid_connect_provider.github`, `aws_iam_role.github_actions`, `aws_iam_role_policy.grc_evidence_readonly`. Confirm the `role_arn` output equals `arn:aws:iam::612063236841:role/github-actions-grc-evidence` — it must match the `ROLE_ARN` hardcoded in the workflow env block, since nothing wires them together automatically.

### Step 2 — Commit and push

```powershell
git add "04-03 lab" ".github/workflows/grc-evidence-pipeline.yml"
git commit -m "Lab 4.3: OIDC-based GRC evidence pipeline in GitHub Actions"
git push
```

### Step 3 — Prove the positive path

Open a PR against `main` (any trivial change under `terraform/primitives/compliant-s3` or a new branch with no changes at all works, since the workflow runs on every PR regardless of diff). Confirm in the Actions tab:

- The `Configure AWS credentials` step succeeds with no static keys — check the step log for the assumed role ARN.
- Conftest and tfsec both report pass.
- An artifact named `grc-evidence-<run-id>` is attached to the run, containing `plan.json`, `conftest-results.json`, `tfsec.sarif`.
- A PR comment appears summarizing pass/fail for both gates.

### Step 4 — Prove the negative path (fail-closed)

Reuse Lab 3.4's broken variant: on a branch, remove `aws_s3_bucket_server_side_encryption_configuration.primary` (and the output that references it) from `terraform/primitives/compliant-s3/main.tf`, push, open a PR. Confirm:

- The Conftest step fails (SC-28 violation), the job still uploads the evidence artifact (`if: always()`), the PR comment shows the failure, and the final job status is red — a required check on this workflow would block the merge.

Revert the branch after confirming (don't merge the broken change).

### Step 5 (recommended, not yet done) — Require the check

Branch protection on `main` requiring the `evidence` job as a required status check turns "the gate reports failure" into "the merge button is actually disabled." This lab's workflow produces the signal; enabling the required-check setting on the repo is what makes it binding. Not scripted here since it's a one-time repo setting, not infrastructure.

---

## Verification

Not yet run — Steps 1–4 above are the actual verification for this lab (mirroring Lab 3.4's pattern of proving both the compliant and broken path). Update this section with real run IDs, artifact names, and PR links once executed.

---

## Portfolio checklist

- [ ] `terraform/oidc/` applied — OIDC provider + role live in the account
- [ ] `.github/workflows/grc-evidence-pipeline.yml` committed and pushed
- [ ] Positive-path PR run: OIDC assume succeeds, both gates pass, `grc-evidence-<run-id>` artifact present, PR comment posted
- [ ] Negative-path PR run: gate fails closed, evidence still captured, PR comment shows failure
- [ ] (Recommended) branch protection requires this check on `main`

---

## Notes for later labs

- Lab 4.4 adds Cosign signing of the evidence bundle and uploads it to the Lab 2.5 S3 Object Lock vault.
- If a future workflow trigger type is added (e.g. `workflow_dispatch` for manual re-runs), its OIDC `sub` claim form differs again — check GitHub's docs for that trigger before assuming the existing trust condition covers it.
