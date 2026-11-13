package inventory

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// backupPlanCoverage pairs the user-facing plan/rule reference with the
// rule's raw retention, which schedules.go also needs but the frozen model
// only exposes as a formatted Lifecycle string.
type backupPlanCoverage struct {
	Ref           model.AWSBackupPlanRef
	RetentionDays int
}

// GetBackupPlanForDB builds the manual/automated/AWS-Backup grouped summary
// for one database: manual snapshot count and latest, the automated backup
// window and retention already on the database itself, and every AWS
// Backup plan rule whose selection covers this database.
func GetBackupPlanForDB(ctx context.Context, clients *awsx.Clients, account model.Account, db model.Database) (model.BackupPlanSummary, error) {
	snapshots, err := ListSnapshotsForDB(ctx, clients, account, db.Region, db.Kind, db.Identifier)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}

	manual := model.ManualBackupSummary{}
	for _, s := range snapshots {
		if s.Source != model.SnapshotSourceManual {
			continue
		}
		manual.Count++
		if manual.Latest == nil || s.CreatedAt > *manual.Latest {
			t := s.CreatedAt
			manual.Latest = &t
		}
	}

	automated := model.AutomatedBackupSummary{
		Retention: db.BackupRetentionDays,
		Window:    db.PreferredBackupWindow,
		Latest:    db.LatestRestorableTime,
	}
	// Best-effort, same as AWS Backup coverage below: a describe error here
	// must not fail the whole summary, just leave Earliest unset.
	if earliest, err := automatedBackupEarliest(ctx, clients, account, db); err == nil {
		automated.Earliest = earliest
	}

	// AWS Backup coverage is best-effort: an account without Backup set up,
	// or without permission to read it, must not fail the whole summary.
	var awsBackup []model.AWSBackupPlanRef
	if coverage, err := listAWSBackupPlanCoverage(ctx, clients, account, db); err == nil {
		for _, c := range coverage {
			awsBackup = append(awsBackup, c.Ref)
		}
	}

	return model.BackupPlanSummary{
		DB:        db.Identifier,
		Manual:    manual,
		Automated: automated,
		AwsBackup: awsBackup,
	}, nil
}

// automatedBackupEarliest returns the earliest point a database's automated
// backups (including PITR) can currently restore to. Clusters carry this
// directly on DescribeDBClusters; instances only expose it per automated
// backup via DescribeDBInstanceAutomatedBackups, so the earliest of those
// restore windows is used.
func automatedBackupEarliest(ctx context.Context, clients *awsx.Clients, account model.Account, db model.Database) (*string, error) {
	cs, err := clients.For(ctx, account.Profile, db.Region, account.ReadOnly)
	if err != nil {
		return nil, err
	}

	if db.Kind == model.DBKindCluster {
		out, err := cs.RDS.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
			DBClusterIdentifier: aws.String(db.Identifier),
		})
		if err != nil {
			return nil, fmt.Errorf("describe db cluster %s: %w", db.Identifier, err)
		}
		if len(out.DBClusters) == 0 {
			return nil, nil
		}
		return formatTimePtr(out.DBClusters[0].EarliestRestorableTime), nil
	}

	out, err := cs.RDS.DescribeDBInstanceAutomatedBackups(ctx, &rds.DescribeDBInstanceAutomatedBackupsInput{
		DBInstanceIdentifier: aws.String(db.Identifier),
	})
	if err != nil {
		return nil, fmt.Errorf("describe automated backups for %s: %w", db.Identifier, err)
	}

	var earliest *time.Time
	for _, b := range out.DBInstanceAutomatedBackups {
		if b.RestoreWindow == nil || b.RestoreWindow.EarliestTime == nil {
			continue
		}
		if earliest == nil || b.RestoreWindow.EarliestTime.Before(*earliest) {
			earliest = b.RestoreWindow.EarliestTime
		}
	}
	return formatTimePtr(earliest), nil
}

func listAWSBackupPlanCoverage(ctx context.Context, clients *awsx.Clients, account model.Account, db model.Database) ([]backupPlanCoverage, error) {
	cs, err := clients.For(ctx, account.Profile, db.Region, account.ReadOnly)
	if err != nil {
		return nil, err
	}

	acctNum, err := resolveAccountNumber(ctx, clients, account, db.Region)
	if err != nil {
		return nil, err
	}
	dbArn := recoveryPointResourceArn(db.Region, acctNum, db.Kind, db.Identifier)

	var plans []backuptypes.BackupPlansListMember
	pp := backup.NewListBackupPlansPaginator(cs.Backup, &backup.ListBackupPlansInput{})
	for pp.HasMorePages() {
		page, err := pp.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list backup plans: %w", err)
		}
		plans = append(plans, page.BackupPlansList...)
	}

	var out []backupPlanCoverage
	for _, p := range plans {
		planID := aws.ToString(p.BackupPlanId)

		selections, err := listBackupSelections(ctx, cs, planID)
		if err != nil {
			continue
		}

		covered := false
		for _, sel := range selections {
			if backupSelectionCovers(sel, dbArn, db.Tags) {
				covered = true
				break
			}
		}
		if !covered {
			continue
		}

		full, err := cs.Backup.GetBackupPlan(ctx, &backup.GetBackupPlanInput{BackupPlanId: p.BackupPlanId})
		if err != nil || full.BackupPlan == nil {
			continue
		}
		for _, rule := range full.BackupPlan.Rules {
			out = append(out, backupPlanCoverage{
				Ref: model.AWSBackupPlanRef{
					PlanID:    planID,
					PlanName:  aws.ToString(p.BackupPlanName),
					RuleName:  aws.ToString(rule.RuleName),
					Cron:      aws.ToString(rule.ScheduleExpression),
					Lifecycle: lifecycleText(rule.Lifecycle),
					Vault:     aws.ToString(rule.TargetBackupVaultName),
				},
				RetentionDays: lifecycleRetentionDays(rule.Lifecycle),
			})
		}
	}
	return out, nil
}

func listBackupSelections(ctx context.Context, cs *awsx.ClientSet, planID string) ([]backuptypes.BackupSelection, error) {
	var out []backuptypes.BackupSelection
	sp := backup.NewListBackupSelectionsPaginator(cs.Backup, &backup.ListBackupSelectionsInput{BackupPlanId: aws.String(planID)})
	for sp.HasMorePages() {
		page, err := sp.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list backup selections: %w", err)
		}
		for _, s := range page.BackupSelectionsList {
			full, err := cs.Backup.GetBackupSelection(ctx, &backup.GetBackupSelectionInput{
				BackupPlanId: aws.String(planID),
				SelectionId:  s.SelectionId,
			})
			if err != nil || full.BackupSelection == nil {
				continue
			}
			out = append(out, *full.BackupSelection)
		}
	}
	return out, nil
}

// backupSelectionCovers reports whether a resource selection assigns the
// given database to its plan, by ARN (with AWS's trailing-"*" wildcards),
// or by tag condition. NotResources excludes a database even if a Resources
// entry or tag condition would otherwise match it.
func backupSelectionCovers(sel backuptypes.BackupSelection, resourceArn string, tags map[string]string) bool {
	for _, excluded := range sel.NotResources {
		if resourceArnMatches(excluded, resourceArn) {
			return false
		}
	}
	for _, r := range sel.Resources {
		if resourceArnMatches(r, resourceArn) {
			return true
		}
	}
	for _, c := range sel.ListOfTags {
		if tagKeyValueMatches(aws.ToString(c.ConditionKey), aws.ToString(c.ConditionValue), tags) {
			return true
		}
	}
	if sel.Conditions != nil {
		for _, c := range sel.Conditions.StringEquals {
			if tagConditionMatches(c, tags, true) {
				return true
			}
		}
		for _, c := range sel.Conditions.StringLike {
			if tagConditionMatches(c, tags, false) {
				return true
			}
		}
		// StringNotEquals/StringNotLike only narrow a positive match in
		// AWS Backup; they are not evaluated as a standalone "yes" here.
	}
	return false
}

func resourceArnMatches(pattern, arn string) bool {
	if pattern == "*" || pattern == arn {
		return true
	}
	if strings.HasSuffix(pattern, "*") && strings.HasPrefix(arn, strings.TrimSuffix(pattern, "*")) {
		return true
	}
	return false
}

func tagKeyValueMatches(key, value string, tags map[string]string) bool {
	key = strings.TrimPrefix(key, "aws:ResourceTag/")
	v, ok := tags[key]
	return ok && v == value
}

func tagConditionMatches(p backuptypes.ConditionParameter, tags map[string]string, exact bool) bool {
	key := strings.TrimPrefix(aws.ToString(p.ConditionKey), "aws:ResourceTag/")
	val, ok := tags[key]
	if !ok {
		return false
	}
	pattern := aws.ToString(p.ConditionValue)
	if exact {
		return val == pattern
	}
	return matchWildcard(val, pattern)
}

func matchWildcard(value, pattern string) bool {
	if !strings.Contains(pattern, "*") {
		return value == pattern
	}
	parts := strings.Split(pattern, "*")
	if !strings.HasPrefix(value, parts[0]) {
		return false
	}
	rest := strings.TrimPrefix(value, parts[0])
	for _, p := range parts[1:] {
		if p == "" {
			continue
		}
		idx := strings.Index(rest, p)
		if idx < 0 {
			return false
		}
		rest = rest[idx+len(p):]
	}
	return true
}

func lifecycleText(l *backuptypes.Lifecycle) string {
	if l == nil || l.DeleteAfterDays == nil {
		return ""
	}
	return fmt.Sprintf("%d day(s)", *l.DeleteAfterDays)
}

func lifecycleRetentionDays(l *backuptypes.Lifecycle) int {
	if l == nil || l.DeleteAfterDays == nil {
		return 0
	}
	return int(*l.DeleteAfterDays)
}
