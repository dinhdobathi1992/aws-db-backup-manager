package actions

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/audit"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// resolveAccountNumber looks up the AWS account number behind a profile, to
// build resource ARNs (RDS db/cluster, IAM role) without ever asking the
// user for one. Each action call resolves it fresh rather than sharing
// inventory's read-view cache: actions are infrequent and must never act on
// a stale account identity.
func resolveAccountNumber(ctx context.Context, cs *awsx.ClientSet) (string, error) {
	out, err := cs.STS.GetCallerIdentity(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("get caller identity: %w", err)
	}
	return aws.ToString(out.Account), nil
}

// defaultBackupRoleArn is AWS Backup's own default service role, used when
// the caller doesn't name one.
func defaultBackupRoleArn(accountNumber string) string {
	return fmt.Sprintf("arn:aws:iam::%s:role/service-role/AWSBackupDefaultServiceRole", accountNumber)
}

// defaultBackupVaultName is the vault every AWS account has out of the box.
const defaultBackupVaultName = "Default"

// dbResourceArn builds the RDS resource ARN for a database, the same shape
// AWS Backup's ResourceArn/Resources fields expect.
func dbResourceArn(region, accountNumber string, kind model.DBKind, identifier string) string {
	resourceType := "db"
	if kind == model.DBKindCluster {
		resourceType = "cluster"
	}
	return fmt.Sprintf("arn:aws:rds:%s:%s:%s:%s", region, accountNumber, resourceType, identifier)
}

// manualSnapshotID generates the default identifier for an on-demand manual
// snapshot: "<db>-manual-<yyyymmdd-hhmm>" in UTC, so two snapshots started
// in the same minute don't collide across timezones.
func manualSnapshotID(dbIdentifier string) string {
	return fmt.Sprintf("%s-manual-%s", dbIdentifier, time.Now().UTC().Format("20060102-1504"))
}

func formatTime(t *time.Time) string {
	if t == nil || t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// recordAudit appends one entry to the local audit log. A logging failure
// never fails the caller's action: the AWS call it describes already
// happened by the time this runs, so the only options are to log what
// happened or lose the record entirely.
func recordAudit(account model.Account, arn, action, target, result string) {
	_ = audit.Append(audit.Entry{
		Time:    nowRFC3339(),
		Account: account.ID,
		Profile: account.Profile,
		ARN:     arn,
		Action:  action,
		Target:  target,
		Result:  result,
	})
}
