package actions

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/inventory"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// minBackupPlanRetentionDays mirrors the floor internal/awsx's guard
// enforces on CreateBackupPlan (see awsx.GuardMiddleware). It is duplicated
// here only so a plan with too-short a retention fails with a clear,
// specific message before an AWS call is even made; the guard remains the
// real enforcement point and is never relaxed by this duplication.
const minBackupPlanRetentionDays = 7

// CreateSnapshot starts an on-demand manual snapshot of a database. The
// snapshot name defaults to "<db>-manual-<yyyymmdd-hhmm>" (UTC) when the
// caller doesn't name one.
func CreateSnapshot(ctx context.Context, clients *awsx.Clients, account model.Account, req model.CreateSnapshotReq) (model.Snapshot, error) {
	if req.DBIdentifier == "" {
		return model.Snapshot{}, errors.New("dbIdentifier is required")
	}
	snapshotName := req.SnapshotName
	if snapshotName == "" {
		snapshotName = manualSnapshotID(req.DBIdentifier)
	}
	if err := ValidateIdentifier(snapshotName); err != nil {
		return model.Snapshot{}, err
	}

	cs, err := clients.For(ctx, account.Profile, req.Region, account.ReadOnly)
	if err != nil {
		return model.Snapshot{}, err
	}

	var snap model.Snapshot
	if req.Kind == model.DBKindCluster {
		out, err := cs.RDS.CreateDBClusterSnapshot(ctx, &rds.CreateDBClusterSnapshotInput{
			DBClusterIdentifier:         aws.String(req.DBIdentifier),
			DBClusterSnapshotIdentifier: aws.String(snapshotName),
		})
		if err != nil {
			return model.Snapshot{}, fmt.Errorf("create db cluster snapshot: %w", err)
		}
		s := out.DBClusterSnapshot
		snap = model.Snapshot{
			ID:           aws.ToString(s.DBClusterSnapshotIdentifier),
			ARN:          aws.ToString(s.DBClusterSnapshotArn),
			DBIdentifier: aws.ToString(s.DBClusterIdentifier),
			Kind:         model.DBKindCluster,
			Source:       model.SnapshotSourceManual,
			Status:       aws.ToString(s.Status),
			CreatedAt:    formatTime(s.SnapshotCreateTime),
			SizeGB:       int64(aws.ToInt32(s.AllocatedStorage)),
			Encrypted:    aws.ToBool(s.StorageEncrypted),
			Engine:       aws.ToString(s.Engine),
		}
	} else {
		out, err := cs.RDS.CreateDBSnapshot(ctx, &rds.CreateDBSnapshotInput{
			DBInstanceIdentifier: aws.String(req.DBIdentifier),
			DBSnapshotIdentifier: aws.String(snapshotName),
		})
		if err != nil {
			return model.Snapshot{}, fmt.Errorf("create db snapshot: %w", err)
		}
		s := out.DBSnapshot
		snap = model.Snapshot{
			ID:           aws.ToString(s.DBSnapshotIdentifier),
			ARN:          aws.ToString(s.DBSnapshotArn),
			DBIdentifier: aws.ToString(s.DBInstanceIdentifier),
			Kind:         model.DBKindInstance,
			Source:       model.SnapshotSourceManual,
			Status:       aws.ToString(s.Status),
			CreatedAt:    formatTime(s.SnapshotCreateTime),
			SizeGB:       int64(aws.ToInt32(s.AllocatedStorage)),
			Encrypted:    aws.ToBool(s.Encrypted),
			Engine:       aws.ToString(s.Engine),
		}
	}

	recordAudit(account, snap.ARN, "CreateSnapshot", req.DBIdentifier, snap.Status)
	inventory.RefreshSnapshots(account, req.Region, req.DBIdentifier)
	return snap, nil
}

// StartBackupJob starts an on-demand AWS Backup job for a database, using
// AWS Backup's own default vault and service role when the caller doesn't
// name one.
func StartBackupJob(ctx context.Context, clients *awsx.Clients, account model.Account, req model.StartBackupJobReq) (model.Activity, error) {
	if req.DBIdentifier == "" {
		return model.Activity{}, errors.New("dbIdentifier is required")
	}

	cs, err := clients.For(ctx, account.Profile, req.Region, account.ReadOnly)
	if err != nil {
		return model.Activity{}, err
	}
	acctNum, err := resolveAccountNumber(ctx, cs)
	if err != nil {
		return model.Activity{}, err
	}

	vault := req.VaultName
	if vault == "" {
		vault = defaultBackupVaultName
	}
	role := req.IamRoleArn
	if role == "" {
		role = defaultBackupRoleArn(acctNum)
	}
	resourceArn := dbResourceArn(req.Region, acctNum, req.Kind, req.DBIdentifier)

	out, err := cs.Backup.StartBackupJob(ctx, &backup.StartBackupJobInput{
		BackupVaultName: aws.String(vault),
		IamRoleArn:      aws.String(role),
		ResourceArn:     aws.String(resourceArn),
	})
	if err != nil {
		return model.Activity{}, fmt.Errorf("start backup job: %w", err)
	}

	jobID := aws.ToString(out.BackupJobId)
	recordAudit(account, resourceArn, "StartBackupJob", req.DBIdentifier, "pending")
	return model.Activity{
		Time:    formatTime(out.CreationDate),
		Source:  model.ActivitySourceBackupJob,
		DB:      req.DBIdentifier,
		Action:  "start-backup-job",
		Status:  "pending",
		Message: fmt.Sprintf("backup job %s started in vault %s", jobID, vault),
	}, nil
}

// CreateBackupPlan creates a new AWS Backup plan with one rule and one
// resource selection targeting a single database, by ARN.
func CreateBackupPlan(ctx context.Context, clients *awsx.Clients, account model.Account, req model.CreateBackupPlanReq) (model.BackupPlanSummary, error) {
	if req.DBIdentifier == "" {
		return model.BackupPlanSummary{}, errors.New("dbIdentifier is required")
	}
	if req.Cron == "" {
		return model.BackupPlanSummary{}, errors.New("cron schedule expression is required")
	}
	if req.RetentionDays < minBackupPlanRetentionDays {
		return model.BackupPlanSummary{}, fmt.Errorf("retentionDays must be at least %d", minBackupPlanRetentionDays)
	}

	planName := req.PlanName
	if planName == "" {
		planName = req.DBIdentifier + "-plan"
	}
	ruleName := req.RuleName
	if ruleName == "" {
		ruleName = "default-rule"
	}
	vault := req.VaultName
	if vault == "" {
		vault = defaultBackupVaultName
	}

	cs, err := clients.For(ctx, account.Profile, req.Region, account.ReadOnly)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}
	acctNum, err := resolveAccountNumber(ctx, cs)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}
	role := req.IamRoleArn
	if role == "" {
		role = defaultBackupRoleArn(acctNum)
	}
	resourceArn := dbResourceArn(req.Region, acctNum, req.Kind, req.DBIdentifier)

	planOut, err := cs.Backup.CreateBackupPlan(ctx, &backup.CreateBackupPlanInput{
		BackupPlan: &backuptypes.BackupPlanInput{
			BackupPlanName: aws.String(planName),
			Rules: []backuptypes.BackupRuleInput{
				{
					RuleName:              aws.String(ruleName),
					TargetBackupVaultName: aws.String(vault),
					ScheduleExpression:    aws.String(req.Cron),
					Lifecycle:             &backuptypes.Lifecycle{DeleteAfterDays: aws.Int64(int64(req.RetentionDays))},
				},
			},
		},
	})
	if err != nil {
		return model.BackupPlanSummary{}, fmt.Errorf("create backup plan: %w", err)
	}

	_, err = cs.Backup.CreateBackupSelection(ctx, &backup.CreateBackupSelectionInput{
		BackupPlanId: planOut.BackupPlanId,
		BackupSelection: &backuptypes.BackupSelection{
			SelectionName: aws.String(planName + "-selection"),
			IamRoleArn:    aws.String(role),
			Resources:     []string{resourceArn},
		},
	})
	if err != nil {
		return model.BackupPlanSummary{}, fmt.Errorf("create backup selection: %w", err)
	}

	recordAudit(account, resourceArn, "CreateBackupPlan", req.DBIdentifier, aws.ToString(planOut.BackupPlanId))

	dbs, err := inventory.ListDatabases(ctx, clients, account)
	if err == nil {
		for _, db := range dbs {
			if db.Identifier == req.DBIdentifier && db.Region == req.Region {
				return inventory.GetBackupPlanForDB(ctx, clients, account, db)
			}
		}
	}
	// The database couldn't be re-read right after the plan was created
	// (a transient inventory error); return what we know rather than
	// failing the whole action after the plan already exists in AWS.
	return model.BackupPlanSummary{
		DB: req.DBIdentifier,
		AwsBackup: []model.AWSBackupPlanRef{{
			PlanID:    aws.ToString(planOut.BackupPlanId),
			PlanName:  planName,
			RuleName:  ruleName,
			Cron:      req.Cron,
			Lifecycle: fmt.Sprintf("%d day(s)", req.RetentionDays),
			Vault:     vault,
		}},
	}, nil
}

// ModifyAutomatedBackup changes a database's automated backup window and/or
// raises its retention. Retention can only go up: the guard blocks 0 (never
// disable automated backups), and this function additionally blocks any
// request to lower an already-higher retention, since "raise retention" is
// the only automated-backup change this app offers.
func ModifyAutomatedBackup(ctx context.Context, clients *awsx.Clients, account model.Account, req model.ModifyAutomatedBackupReq) (model.Database, error) {
	if req.DBIdentifier == "" {
		return model.Database{}, errors.New("dbIdentifier is required")
	}
	if req.Window == "" && req.RetentionDays == 0 {
		return model.Database{}, errors.New("window or retentionDays is required")
	}

	cs, err := clients.For(ctx, account.Profile, req.Region, account.ReadOnly)
	if err != nil {
		return model.Database{}, err
	}

	currentRetention, _, err := currentBackupSettings(ctx, cs, req.Kind, req.DBIdentifier)
	if err != nil {
		return model.Database{}, err
	}
	if req.RetentionDays > 0 && req.RetentionDays < currentRetention {
		return model.Database{}, fmt.Errorf(
			"retention can only be raised, not lowered: current is %d day(s), requested %d",
			currentRetention, req.RetentionDays,
		)
	}

	var retentionPtr *int32
	if req.RetentionDays > 0 {
		retentionPtr = aws.Int32(int32(req.RetentionDays))
	}
	var windowPtr *string
	if req.Window != "" {
		windowPtr = aws.String(req.Window)
	}

	if req.Kind == model.DBKindCluster {
		_, err = cs.RDS.ModifyDBCluster(ctx, &rds.ModifyDBClusterInput{
			DBClusterIdentifier:   aws.String(req.DBIdentifier),
			ApplyImmediately:      aws.Bool(true),
			BackupRetentionPeriod: retentionPtr,
			PreferredBackupWindow: windowPtr,
		})
	} else {
		_, err = cs.RDS.ModifyDBInstance(ctx, &rds.ModifyDBInstanceInput{
			DBInstanceIdentifier:  aws.String(req.DBIdentifier),
			ApplyImmediately:      aws.Bool(true),
			BackupRetentionPeriod: retentionPtr,
			PreferredBackupWindow: windowPtr,
		})
	}
	if err != nil {
		return model.Database{}, fmt.Errorf("modify automated backup settings: %w", err)
	}

	recordAudit(account, req.DBIdentifier, "ModifyAutomatedBackup", req.DBIdentifier, "applied")
	inventory.RefreshDatabases(account)

	dbs, err := inventory.ListDatabases(ctx, clients, account)
	if err != nil {
		return model.Database{}, err
	}
	for _, db := range dbs {
		if db.Identifier == req.DBIdentifier && db.Region == req.Region {
			return db, nil
		}
	}
	return model.Database{}, fmt.Errorf("database %q not found after modify", req.DBIdentifier)
}

// currentBackupSettings reads a database's live (uncached) retention and
// window, so ModifyAutomatedBackup can enforce "raise only" against the
// current truth rather than a read view that could be up to a minute stale.
func currentBackupSettings(ctx context.Context, cs *awsx.ClientSet, kind model.DBKind, identifier string) (retentionDays int, window string, err error) {
	if kind == model.DBKindCluster {
		out, err := cs.RDS.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
			DBClusterIdentifier: aws.String(identifier),
		})
		if err != nil || len(out.DBClusters) == 0 {
			return 0, "", fmt.Errorf("describe cluster %q: %w", identifier, err)
		}
		c := out.DBClusters[0]
		return int(aws.ToInt32(c.BackupRetentionPeriod)), aws.ToString(c.PreferredBackupWindow), nil
	}

	out, err := cs.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		DBInstanceIdentifier: aws.String(identifier),
	})
	if err != nil || len(out.DBInstances) == 0 {
		return 0, "", fmt.Errorf("describe instance %q: %w", identifier, err)
	}
	inst := out.DBInstances[0]
	return int(aws.ToInt32(inst.BackupRetentionPeriod)), aws.ToString(inst.PreferredBackupWindow), nil
}
