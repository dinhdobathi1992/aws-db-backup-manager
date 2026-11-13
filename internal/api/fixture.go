package api

import (
	"context"
	"fmt"
	"time"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// FixtureService is an in-memory Service implementation returning realistic
// fake data. It exists only for frontend development and manual UI review;
// main.go wires it in only when ADBM_FIXTURES=1 and it is never the
// default. It never talks to AWS.
type FixtureService struct {
	accounts  []model.Account
	databases map[string][]model.Database        // keyed by AccountID
	snapshots map[string][]model.Snapshot        // keyed by DBIdentifier
	plans     map[string]model.BackupPlanSummary // keyed by DBIdentifier
	schedules map[string][]model.Schedule        // keyed by AccountID
	activity  map[string][]model.Activity        // keyed by AccountID
}

// NewFixtureService builds the fixture dataset: 2 accounts, 6 databases
// across them, with a mix of manual, automated and AWS Backup sources.
func NewFixtureService() *FixtureService {
	now := time.Now()
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	ptr := func(t time.Time) *string { s := t.Format(time.RFC3339); return &s }

	accounts := []model.Account{
		{ID: "acct-prod", Name: "Production", Profile: "prod", Regions: []string{"us-east-1", "us-west-2"}, Color: "#2563eb"},
		{ID: "acct-staging", Name: "Staging", Profile: "staging", Regions: []string{"us-east-1"}, Color: "#16a34a"},
	}

	databases := map[string][]model.Database{
		"acct-prod": {
			{
				AccountID: "acct-prod", Region: "us-east-1", Kind: model.DBKindCluster,
				Identifier: "prod-orders-cluster", Engine: "aurora-postgresql", EngineVersion: "15.4",
				Class: "db.r6g.large", Status: "available", Endpoint: "prod-orders-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com",
				MultiAZ: true, StorageGB: 200, Encrypted: true, BackupRetentionDays: 7,
				PreferredBackupWindow: "03:00-03:30", LatestRestorableTime: ptr(ago(2 * time.Minute)),
				Tags: map[string]string{"env": "prod", "team": "orders"},
			},
			{
				AccountID: "acct-prod", Region: "us-east-1", Kind: model.DBKindInstance,
				Identifier: "prod-reporting-pg", Engine: "postgres", EngineVersion: "16.1",
				Class: "db.m6g.xlarge", Status: "available", Endpoint: "prod-reporting-pg.xxxxx.us-east-1.rds.amazonaws.com",
				MultiAZ: true, StorageGB: 500, Encrypted: true, BackupRetentionDays: 14,
				PreferredBackupWindow: "02:00-02:30", LatestRestorableTime: ptr(ago(5 * time.Minute)),
				Tags: map[string]string{"env": "prod", "team": "data"},
			},
			{
				AccountID: "acct-prod", Region: "us-west-2", Kind: model.DBKindInstance,
				Identifier: "prod-users-mysql", Engine: "mysql", EngineVersion: "8.0.35",
				Class: "db.r6g.large", Status: "available", Endpoint: "prod-users-mysql.xxxxx.us-west-2.rds.amazonaws.com",
				MultiAZ: false, StorageGB: 100, Encrypted: true, BackupRetentionDays: 7,
				PreferredBackupWindow: "05:00-05:30", LatestRestorableTime: ptr(ago(10 * time.Minute)),
				Tags: map[string]string{"env": "prod", "team": "identity"},
			},
			{
				AccountID: "acct-prod", Region: "us-east-1", Kind: model.DBKindCluster,
				Identifier: "prod-billing-cluster", Engine: "aurora-mysql", EngineVersion: "3.05.2",
				Class: "db.r6g.xlarge", Status: "available", Endpoint: "prod-billing-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com",
				MultiAZ: true, StorageGB: 300, Encrypted: true, BackupRetentionDays: 30,
				PreferredBackupWindow: "01:00-01:30", LatestRestorableTime: ptr(ago(1 * time.Minute)),
				Tags: map[string]string{"env": "prod", "team": "billing"},
			},
		},
		"acct-staging": {
			{
				AccountID: "acct-staging", Region: "us-east-1", Kind: model.DBKindInstance,
				Identifier: "staging-orders-pg", Engine: "postgres", EngineVersion: "16.1",
				Class: "db.t4g.medium", Status: "available", Endpoint: "staging-orders-pg.xxxxx.us-east-1.rds.amazonaws.com",
				MultiAZ: false, StorageGB: 50, Encrypted: true, BackupRetentionDays: 1,
				PreferredBackupWindow: "04:00-04:30", LatestRestorableTime: ptr(ago(20 * time.Minute)),
				Tags: map[string]string{"env": "staging"},
			},
			{
				AccountID: "acct-staging", Region: "us-east-1", Kind: model.DBKindInstance,
				Identifier: "staging-sandbox-mysql", Engine: "mysql", EngineVersion: "8.0.35",
				Class: "db.t4g.small", Status: "stopped", Endpoint: "staging-sandbox-mysql.xxxxx.us-east-1.rds.amazonaws.com",
				MultiAZ: false, StorageGB: 20, Encrypted: false, BackupRetentionDays: 1,
				PreferredBackupWindow: "06:00-06:30", LatestRestorableTime: nil,
				Tags: map[string]string{"env": "staging"},
			},
		},
	}

	snapshots := map[string][]model.Snapshot{
		"prod-orders-cluster": {
			{ID: "prod-orders-cluster-manual-2026-11-10", ARN: "arn:aws:rds:us-east-1:111111111111:cluster-snapshot:prod-orders-cluster-manual-2026-11-10", DBIdentifier: "prod-orders-cluster", Kind: model.DBKindCluster, Source: model.SnapshotSourceManual, Status: "available", CreatedAt: ago(72 * time.Hour).Format(time.RFC3339), SizeGB: 200, Encrypted: true, Engine: "aurora-postgresql"},
			{ID: "rds:prod-orders-cluster-2026-11-13-03-00", ARN: "arn:aws:rds:us-east-1:111111111111:cluster-snapshot:rds:prod-orders-cluster-2026-11-13-03-00", DBIdentifier: "prod-orders-cluster", Kind: model.DBKindCluster, Source: model.SnapshotSourceAutomated, Status: "available", CreatedAt: ago(17 * time.Hour).Format(time.RFC3339), SizeGB: 200, Encrypted: true, Engine: "aurora-postgresql"},
			{ID: "backup-rp-orders-0001", ARN: "arn:aws:backup:us-east-1:111111111111:recovery-point:orders-0001", DBIdentifier: "prod-orders-cluster", Kind: model.DBKindCluster, Source: model.SnapshotSourceAWSBackup, Status: "completed", CreatedAt: ago(41 * time.Hour).Format(time.RFC3339), SizeGB: 200, Encrypted: true, Engine: "aurora-postgresql", VaultName: "prod-vault"},
		},
		"prod-reporting-pg": {
			{ID: "rds:prod-reporting-pg-2026-11-13-02-00", ARN: "arn:aws:rds:us-east-1:111111111111:snapshot:rds:prod-reporting-pg-2026-11-13-02-00", DBIdentifier: "prod-reporting-pg", Kind: model.DBKindInstance, Source: model.SnapshotSourceAutomated, Status: "available", CreatedAt: ago(18 * time.Hour).Format(time.RFC3339), SizeGB: 500, Encrypted: true, Engine: "postgres"},
		},
		"prod-users-mysql": {
			{ID: "prod-users-mysql-manual-pre-migration", ARN: "arn:aws:rds:us-west-2:111111111111:snapshot:prod-users-mysql-manual-pre-migration", DBIdentifier: "prod-users-mysql", Kind: model.DBKindInstance, Source: model.SnapshotSourceManual, Status: "available", CreatedAt: ago(240 * time.Hour).Format(time.RFC3339), SizeGB: 100, Encrypted: true, Engine: "mysql"},
			{ID: "rds:prod-users-mysql-2026-11-13-05-00", ARN: "arn:aws:rds:us-west-2:111111111111:snapshot:rds:prod-users-mysql-2026-11-13-05-00", DBIdentifier: "prod-users-mysql", Kind: model.DBKindInstance, Source: model.SnapshotSourceAutomated, Status: "available", CreatedAt: ago(15 * time.Hour).Format(time.RFC3339), SizeGB: 100, Encrypted: true, Engine: "mysql"},
		},
		"prod-billing-cluster": {
			{ID: "backup-rp-billing-0007", ARN: "arn:aws:backup:us-east-1:111111111111:recovery-point:billing-0007", DBIdentifier: "prod-billing-cluster", Kind: model.DBKindCluster, Source: model.SnapshotSourceAWSBackup, Status: "completed", CreatedAt: ago(16 * time.Hour).Format(time.RFC3339), SizeGB: 300, Encrypted: true, Engine: "aurora-mysql", VaultName: "prod-vault"},
			{ID: "rds:prod-billing-cluster-2026-11-13-01-00", ARN: "arn:aws:rds:us-east-1:111111111111:cluster-snapshot:rds:prod-billing-cluster-2026-11-13-01-00", DBIdentifier: "prod-billing-cluster", Kind: model.DBKindCluster, Source: model.SnapshotSourceAutomated, Status: "available", CreatedAt: ago(19 * time.Hour).Format(time.RFC3339), SizeGB: 300, Encrypted: true, Engine: "aurora-mysql"},
		},
		"staging-orders-pg": {
			{ID: "rds:staging-orders-pg-2026-11-13-04-00", ARN: "arn:aws:rds:us-east-1:222222222222:snapshot:rds:staging-orders-pg-2026-11-13-04-00", DBIdentifier: "staging-orders-pg", Kind: model.DBKindInstance, Source: model.SnapshotSourceAutomated, Status: "available", CreatedAt: ago(16 * time.Hour).Format(time.RFC3339), SizeGB: 50, Encrypted: true, Engine: "postgres"},
		},
		"staging-sandbox-mysql": {
			{ID: "staging-sandbox-mysql-manual-before-stop", ARN: "arn:aws:rds:us-east-1:222222222222:snapshot:staging-sandbox-mysql-manual-before-stop", DBIdentifier: "staging-sandbox-mysql", Kind: model.DBKindInstance, Source: model.SnapshotSourceManual, Status: "available", CreatedAt: ago(500 * time.Hour).Format(time.RFC3339), SizeGB: 20, Encrypted: false, Engine: "mysql"},
		},
	}

	plans := map[string]model.BackupPlanSummary{
		"prod-orders-cluster": {
			DB:        "prod-orders-cluster",
			Manual:    model.ManualBackupSummary{Count: 1, Latest: ptr(ago(72 * time.Hour))},
			Automated: model.AutomatedBackupSummary{Retention: 7, Window: "03:00-03:30", Earliest: ptr(ago(168 * time.Hour)), Latest: ptr(ago(17 * time.Hour))},
			AwsBackup: []model.AWSBackupPlanRef{{PlanID: "plan-orders", PlanName: "orders-daily", RuleName: "daily-3am", Cron: "cron(0 3 * * ? *)", Lifecycle: "delete-after-35-days", Vault: "prod-vault"}},
		},
		"prod-reporting-pg": {
			DB:        "prod-reporting-pg",
			Manual:    model.ManualBackupSummary{Count: 0},
			Automated: model.AutomatedBackupSummary{Retention: 14, Window: "02:00-02:30", Earliest: ptr(ago(336 * time.Hour)), Latest: ptr(ago(18 * time.Hour))},
			AwsBackup: []model.AWSBackupPlanRef{},
		},
		"prod-users-mysql": {
			DB:        "prod-users-mysql",
			Manual:    model.ManualBackupSummary{Count: 1, Latest: ptr(ago(240 * time.Hour))},
			Automated: model.AutomatedBackupSummary{Retention: 7, Window: "05:00-05:30", Earliest: ptr(ago(168 * time.Hour)), Latest: ptr(ago(15 * time.Hour))},
			AwsBackup: []model.AWSBackupPlanRef{},
		},
		"prod-billing-cluster": {
			DB:        "prod-billing-cluster",
			Manual:    model.ManualBackupSummary{Count: 0},
			Automated: model.AutomatedBackupSummary{Retention: 30, Window: "01:00-01:30", Earliest: ptr(ago(720 * time.Hour)), Latest: ptr(ago(19 * time.Hour))},
			AwsBackup: []model.AWSBackupPlanRef{{PlanID: "plan-billing", PlanName: "billing-compliance", RuleName: "daily-1am", Cron: "cron(0 1 * * ? *)", Lifecycle: "delete-after-365-days", Vault: "prod-vault"}},
		},
		"staging-orders-pg": {
			DB:        "staging-orders-pg",
			Manual:    model.ManualBackupSummary{Count: 0},
			Automated: model.AutomatedBackupSummary{Retention: 1, Window: "04:00-04:30", Earliest: ptr(ago(24 * time.Hour)), Latest: ptr(ago(16 * time.Hour))},
			AwsBackup: []model.AWSBackupPlanRef{},
		},
		"staging-sandbox-mysql": {
			DB:        "staging-sandbox-mysql",
			Manual:    model.ManualBackupSummary{Count: 1, Latest: ptr(ago(500 * time.Hour))},
			Automated: model.AutomatedBackupSummary{Retention: 1, Window: "06:00-06:30"},
			AwsBackup: []model.AWSBackupPlanRef{},
		},
	}

	schedules := map[string][]model.Schedule{
		"acct-prod": {
			{Source: model.ScheduleSourceAutomatedWindow, DB: "prod-orders-cluster", Expression: "03:00-03:30 UTC daily", NextRun: ptr(now.Add(7 * time.Hour)), Retention: 7},
			{Source: model.ScheduleSourceAutomatedWindow, DB: "prod-reporting-pg", Expression: "02:00-02:30 UTC daily", NextRun: ptr(now.Add(6 * time.Hour)), Retention: 14},
			{Source: model.ScheduleSourceAWSBackupRule, DB: "prod-orders-cluster", Expression: "cron(0 3 * * ? *)", NextRun: ptr(now.Add(7 * time.Hour)), Retention: 35},
			{Source: model.ScheduleSourceAWSBackupRule, DB: "prod-billing-cluster", Expression: "cron(0 1 * * ? *)", NextRun: ptr(now.Add(5 * time.Hour)), Retention: 365},
		},
		"acct-staging": {
			{Source: model.ScheduleSourceAutomatedWindow, DB: "staging-orders-pg", Expression: "04:00-04:30 UTC daily", NextRun: ptr(now.Add(8 * time.Hour)), Retention: 1},
		},
	}

	activity := map[string][]model.Activity{
		"acct-prod": {
			{Time: ago(17 * time.Hour).Format(time.RFC3339), Source: model.ActivitySourceRDSEvent, DB: "prod-orders-cluster", Action: "automated-snapshot", Status: "completed", Message: "Automated backup finished"},
			{Time: ago(16 * time.Hour).Format(time.RFC3339), Source: model.ActivitySourceBackupJob, DB: "prod-billing-cluster", Action: "backup-job", Status: "completed", Message: "AWS Backup job completed to prod-vault"},
			{Time: ago(72 * time.Hour).Format(time.RFC3339), Source: model.ActivitySourceApp, DB: "prod-orders-cluster", Action: "create-snapshot", Status: "completed", Message: "Manual snapshot requested from AWS DB Backup Manager"},
		},
		"acct-staging": {
			{Time: ago(16 * time.Hour).Format(time.RFC3339), Source: model.ActivitySourceRDSEvent, DB: "staging-orders-pg", Action: "automated-snapshot", Status: "completed", Message: "Automated backup finished"},
		},
	}

	return &FixtureService{
		accounts:  accounts,
		databases: databases,
		snapshots: snapshots,
		plans:     plans,
		schedules: schedules,
		activity:  activity,
	}
}

func (f *FixtureService) ListAccounts(ctx context.Context) ([]model.Account, error) {
	return f.accounts, nil
}

func (f *FixtureService) SaveAccount(ctx context.Context, account model.Account) (model.Account, error) {
	for i, a := range f.accounts {
		if a.ID == account.ID {
			f.accounts[i] = account
			return account, nil
		}
	}
	f.accounts = append(f.accounts, account)
	return account, nil
}

func (f *FixtureService) TestAccount(ctx context.Context, accountID string) (model.AccountStatus, error) {
	for _, a := range f.accounts {
		if a.ID == accountID {
			return model.AccountStatus{AccountID: a.ID, ARN: fmt.Sprintf("arn:aws:iam::111111111111:user/%s", a.Profile), AwsAccountID: "111111111111", State: model.AccountStateOK, Message: "fixture data"}, nil
		}
	}
	return model.AccountStatus{}, fmt.Errorf("account %q not found", accountID)
}

func (f *FixtureService) SsoLogin(ctx context.Context, accountID string) (model.AccountStatus, error) {
	return f.TestAccount(ctx, accountID)
}

func (f *FixtureService) ListDatabases(ctx context.Context, accountID string) ([]model.Database, error) {
	return f.databases[accountID], nil
}

func (f *FixtureService) GetBackupPlan(ctx context.Context, accountID string, dbIdentifier string) (model.BackupPlanSummary, error) {
	plan, ok := f.plans[dbIdentifier]
	if !ok {
		return model.BackupPlanSummary{}, fmt.Errorf("no backup plan for database %q", dbIdentifier)
	}
	return plan, nil
}

func (f *FixtureService) ListSnapshots(ctx context.Context, accountID string, dbIdentifier string) ([]model.Snapshot, error) {
	return f.snapshots[dbIdentifier], nil
}

func (f *FixtureService) ListSchedules(ctx context.Context, accountID string) ([]model.Schedule, error) {
	return f.schedules[accountID], nil
}

func (f *FixtureService) ListActivity(ctx context.Context, accountID string, limit int) ([]model.Activity, error) {
	items := f.activity[accountID]
	if limit > 0 && limit < len(items) {
		return items[:limit], nil
	}
	return items, nil
}

func (f *FixtureService) CreateSnapshot(ctx context.Context, req model.CreateSnapshotReq) (model.Snapshot, error) {
	snap := model.Snapshot{
		ID:           req.SnapshotName,
		ARN:          fmt.Sprintf("arn:aws:rds:%s:111111111111:snapshot:%s", req.Region, req.SnapshotName),
		DBIdentifier: req.DBIdentifier,
		Kind:         req.Kind,
		Source:       model.SnapshotSourceManual,
		Status:       "creating",
		CreatedAt:    time.Now().Format(time.RFC3339),
		Encrypted:    true,
	}
	f.snapshots[req.DBIdentifier] = append(f.snapshots[req.DBIdentifier], snap)
	return snap, nil
}

func (f *FixtureService) StartBackupJob(ctx context.Context, req model.StartBackupJobReq) (model.Activity, error) {
	act := model.Activity{Time: time.Now().Format(time.RFC3339), Source: model.ActivitySourceBackupJob, DB: req.DBIdentifier, Action: "backup-job", Status: "running", Message: fmt.Sprintf("On-demand AWS Backup job started to %s", req.VaultName)}
	f.activity[req.AccountID] = append(f.activity[req.AccountID], act)
	return act, nil
}

func (f *FixtureService) CreateBackupPlan(ctx context.Context, req model.CreateBackupPlanReq) (model.BackupPlanSummary, error) {
	plan := f.plans[req.DBIdentifier]
	plan.DB = req.DBIdentifier
	plan.AwsBackup = append(plan.AwsBackup, model.AWSBackupPlanRef{
		PlanID: fmt.Sprintf("plan-%s", req.PlanName), PlanName: req.PlanName, RuleName: req.RuleName,
		Cron: req.Cron, Lifecycle: fmt.Sprintf("delete-after-%d-days", req.RetentionDays), Vault: req.VaultName,
	})
	f.plans[req.DBIdentifier] = plan
	return plan, nil
}

func (f *FixtureService) ModifyAutomatedBackup(ctx context.Context, req model.ModifyAutomatedBackupReq) (model.Database, error) {
	dbs := f.databases[req.AccountID]
	for i, db := range dbs {
		if db.Identifier == req.DBIdentifier {
			if req.Window != "" {
				dbs[i].PreferredBackupWindow = req.Window
			}
			if req.RetentionDays > 0 {
				dbs[i].BackupRetentionDays = req.RetentionDays
			}
			return dbs[i], nil
		}
	}
	return model.Database{}, fmt.Errorf("database %q not found in account %q", req.DBIdentifier, req.AccountID)
}

func (f *FixtureService) Restore(ctx context.Context, req model.RestoreReq) (model.Activity, error) {
	for _, dbs := range f.databases {
		for _, db := range dbs {
			if db.Identifier == req.TargetIdentifier {
				return model.Activity{}, fmt.Errorf("target identifier %q already exists", req.TargetIdentifier)
			}
		}
	}
	act := model.Activity{Time: time.Now().Format(time.RFC3339), Source: model.ActivitySourceRestoreJob, DB: req.TargetIdentifier, Action: fmt.Sprintf("restore-from-%s", req.Source), Status: "creating", Message: fmt.Sprintf("Restoring %s into new database %q", req.Source, req.TargetIdentifier)}
	f.activity[req.AccountID] = append(f.activity[req.AccountID], act)
	return act, nil
}

var _ interface {
	ListAccounts(context.Context) ([]model.Account, error)
} = (*FixtureService)(nil)
