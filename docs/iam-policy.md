# IAM policy for AWS DB Backup Manager

`docs/iam-policy.json` is the least-privilege identity policy for the AWS principal (SSO permission set, IAM role or user) whose profile the app uses. It is generated from, and tested against, the app's runtime guard allowlist in `internal/awsx/guard.go`.

## Statements

| Sid | Effect | What it covers |
|---|---|---|
| `AppGuardAllowlistReadOnly` | Allow | Every `Describe*` / `List*` / `Get*` call on the guard allowlist (RDS, AWS Backup, STS). |
| `AppGuardAllowlistCreateRestoreModify` | Allow | The mutating calls on the allowlist: create snapshot, restore to a **new** identifier, backup-settings-only modify, start backup/restore job, create backup plan/selection, add tags. |
| `PassAwsBackupDefaultServiceRole` | Allow | `iam:PassRole` on `service-role/AWSBackupDefaultServiceRole`, only to `backup.amazonaws.com`. Needed by `StartBackupJob`, `StartRestoreJob` and `CreateBackupSelection`. |
| `KmsGrantForEncryptedRestore` / `KmsDescribeKeyForEncryptedRestore` | Allow | `kms:CreateGrant` (only for AWS resources) and `kms:DescribeKey`, only when called through RDS. Needed to restore snapshots encrypted with a customer-managed key. AWS Backup restores run as the Backup service role, so they need nothing extra here. |
| `DenyDestructiveDefenseInDepth` | Deny | `rds:Delete*`, `rds:Remove*`, `rds:Stop*`, `rds:Reboot*`, `rds:Failover*`, snapshot-sharing attribute changes, `rds:StartExportTask` (snapshot data to S3), `rds:BacktrackDBCluster` (rewinds Aurora MySQL in place), replica promotion/switchover, `backup:StartCopyJob` (recovery points to another account), `backup:Delete*`, `backup:Stop*`, `backup:Disassociate*`, `backup:UpdateBackupPlan`, `backup:UpdateRecoveryPointLifecycle` (shortening retention = deleting), vault policy/lock changes, region/global setting changes. |

## Keeping it in sync

The two Allow statements whose Sid starts with `AppGuardAllowlist` must equal the guard allowlist one-to-one. Two checks enforce that:

```bash
make policy-check
go test ./internal/awsx -run Policy
```

`make policy-check` prints a `diff` of guard vs policy and exits non-zero on drift. The Go tests also fail if the Deny ever blocks an allowed action (matching is case-insensitive, like IAM), stops covering a destructive one, gains a `Condition`, or narrows its `Resource`; and if any statement uses `NotAction`/`NotResource`. Change the guard first, then the policy, then run both.

## How to deploy it

- **Attach it to a dedicated principal used only by this app** (for example an Identity Center permission set `DBBackupManager`). The explicit Deny wins over every other policy on that principal, so attaching it to a person's admin role would also stop them deleting things in the console.
- It is 4.2 KB, under the 6,144-character managed-policy limit and the 10,240-character permission-set inline limit.
- In an LZA-managed org, add it as a policy file in `iam-config.yaml` and assign the permission set there, then run the LZA pipeline (it has no auto-trigger).

## What IAM cannot enforce (the app guard does)

- **Modify parameters.** IAM has no condition keys for `BackupRetentionPeriod` or other `ModifyDBInstance`/`ModifyDBCluster` fields. The guard rejects any field other than backup window, retention and `ApplyImmediately`, and rejects retention below 1 day.
- **Backup plan lifecycle.** IAM cannot see `DeleteAfterDays`. The guard rejects plans that keep recovery points for fewer than 7 days.
- **Restore target is new.** IAM cannot tell a new identifier from an existing one; the app checks before calling.

So the policy alone does not make a profile safe for every tool. It makes this app's allowed surface explicit and blocks the destructive verbs for any client using the same principal.

## Known gaps

- `rds:ModifyDBInstance` / `rds:ModifyDBCluster` are allowed by IAM in full. Another client using the same principal could change non-backup settings, such as `DeletionProtection=false` or `PubliclyAccessible=true`; the app itself can't. Narrow with `aws:ResourceTag` conditions if that matters for your estate.
- `iam:PassRole` covers only the default AWS Backup service role. If you choose a custom role in the app, add its ARN to that statement.
- **Per-account read-only mode is app-side, not IAM-side.** Marking an account read-only in Settings makes the app refuse every write before it builds an AWS client, and its client guard additionally allows only `List`/`Describe`/`Get` calls for that account. This policy still grants the full write surface at the IAM level; use a least-privilege, read-only IAM role for an account you never intend the app to write to, rather than relying on the app's flag alone.
- The default role `AWSBackupDefaultServiceRole` and the `Default` vault exist only once someone has used AWS Backup in that account and region (the console creates them on first use). If either is missing, backup jobs and plans from the app fail until it is created.
- `backup:CreateBackupPlan` can include copy actions to other accounts; IAM can't block that per rule. The app doesn't build copy rules.
- `sts:GetCallerIdentity` is always allowed by AWS regardless of policy; it is listed only to keep the one-to-one match.
