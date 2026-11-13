package awsx

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/aws/smithy-go/middleware"
)

// invokeGuarded attaches GuardMiddleware to a fresh stack and runs it for
// the given (service, operation, parameters), returning whatever error (if
// any) the guard produced. The terminal handler always succeeds, so a
// non-nil error here can only have come from the guard itself.
func invokeGuarded(t *testing.T, service, operation string, params interface{}) error {
	t.Helper()
	return invokeGuardedReadOnly(t, false, service, operation, params)
}

// invokeGuardedReadOnly is invokeGuarded with an explicit readOnly flag, for
// testing the read-only account backstop.
func invokeGuardedReadOnly(t *testing.T, readOnly bool, service, operation string, params interface{}) error {
	t.Helper()

	stack := middleware.NewStack("test", func() interface{} { return nil })
	if err := GuardMiddleware(readOnly)(stack); err != nil {
		t.Fatalf("attach guard middleware: %v", err)
	}

	ctx := middleware.WithServiceID(context.Background(), service)
	ctx = middleware.WithOperationName(ctx, operation)

	next := middleware.HandlerFunc(func(ctx context.Context, input interface{}) (interface{}, middleware.Metadata, error) {
		return "ok", middleware.Metadata{}, nil
	})

	_, _, err := stack.Initialize.HandleMiddleware(ctx, params, next)
	return err
}

func TestGuardAllowsReadOnlyAndSafeMutatingCalls(t *testing.T) {
	cases := []struct {
		service, op string
		params      interface{}
	}{
		{"RDS", "DescribeDBInstances", &rds.DescribeDBInstancesInput{}},
		{"RDS", "DescribeDBClusters", &rds.DescribeDBClustersInput{}},
		{"RDS", "DescribeDBSnapshots", &rds.DescribeDBSnapshotsInput{}},
		{"RDS", "ListTagsForResource", &rds.ListTagsForResourceInput{}},
		{"RDS", "CreateDBSnapshot", &rds.CreateDBSnapshotInput{}},
		{"RDS", "RestoreDBInstanceFromDBSnapshot", &rds.RestoreDBInstanceFromDBSnapshotInput{}},
		{"Backup", "ListRecoveryPointsByResource", &backup.ListRecoveryPointsByResourceInput{}},
		{"Backup", "StartBackupJob", &backup.StartBackupJobInput{}},
		{"STS", "GetCallerIdentity", nil},
	}
	for _, c := range cases {
		if err := invokeGuarded(t, c.service, c.op, c.params); err != nil {
			t.Errorf("%s/%s: expected allowed, got error: %v", c.service, c.op, err)
		}
	}
}

func TestGuardBlocksEveryDestructiveOperation(t *testing.T) {
	cases := []struct{ service, op string }{
		{"RDS", "DeleteDBInstance"},
		{"RDS", "DeleteDBCluster"},
		{"RDS", "DeleteDBSnapshot"},
		{"RDS", "DeleteDBClusterSnapshot"},
		{"RDS", "StopDBInstance"},
		{"RDS", "StopDBCluster"},
		{"RDS", "RebootDBInstance"},
		{"RDS", "FailoverDBCluster"},
		{"RDS", "ModifyDBSnapshotAttribute"},
		{"RDS", "ModifyDBClusterSnapshotAttribute"},
		{"Backup", "DeleteBackupPlan"},
		{"Backup", "DeleteBackupVault"},
		{"Backup", "DeleteRecoveryPoint"},
		{"Backup", "DeleteBackupSelection"},
		{"Backup", "UpdateBackupPlan"},
		{"Backup", "PutBackupVaultAccessPolicy"},
		{"Backup", "PutBackupVaultLockConfiguration"},
		// Not forbidden by name, just never put on the allowlist.
		{"RDS", "ModifyDBInstanceToMaintenanceWindow"},
		{"RDS", "SomeFutureOperation"},
		{"EC2", "DescribeInstances"},
	}
	for _, c := range cases {
		err := invokeGuarded(t, c.service, c.op, struct{}{})
		if err == nil {
			t.Errorf("%s/%s: expected blocked, got nil error", c.service, c.op)
			continue
		}
		var forbidden *ErrOperationForbidden
		if !errors.As(err, &forbidden) {
			t.Errorf("%s/%s: expected *ErrOperationForbidden, got %T: %v", c.service, c.op, err, err)
		}
	}
}

func TestGuardModifyDBInstanceOnlyAllowsBackupSettings(t *testing.T) {
	id := "my-db"
	okCases := []*rds.ModifyDBInstanceInput{
		{DBInstanceIdentifier: &id, BackupRetentionPeriod: aws.Int32(14)},
		{DBInstanceIdentifier: &id, PreferredBackupWindow: aws.String("03:00-03:30")},
		{DBInstanceIdentifier: &id, ApplyImmediately: aws.Bool(true), BackupRetentionPeriod: aws.Int32(7)},
	}
	for i, in := range okCases {
		if err := invokeGuarded(t, "RDS", "ModifyDBInstance", in); err != nil {
			t.Errorf("case %d: expected allowed, got: %v", i, err)
		}
	}

	badCases := []*rds.ModifyDBInstanceInput{
		{DBInstanceIdentifier: &id, DeletionProtection: aws.Bool(false)},
		{DBInstanceIdentifier: &id, MasterUserPassword: aws.String("hunter2")},
		{DBInstanceIdentifier: &id, EngineVersion: aws.String("15.4")},
		{DBInstanceIdentifier: &id, AllocatedStorage: aws.Int32(999)},
		{DBInstanceIdentifier: &id, BackupRetentionPeriod: aws.Int32(0)}, // retention 0 == disabled
	}
	for i, in := range badCases {
		if err := invokeGuarded(t, "RDS", "ModifyDBInstance", in); err == nil {
			t.Errorf("case %d: expected blocked, got nil error", i)
		}
	}
}

func TestGuardModifyDBClusterOnlyAllowsBackupSettings(t *testing.T) {
	id := "my-cluster"
	if err := invokeGuarded(t, "RDS", "ModifyDBCluster", &rds.ModifyDBClusterInput{
		DBClusterIdentifier: &id, BackupRetentionPeriod: aws.Int32(30),
	}); err != nil {
		t.Errorf("expected allowed, got: %v", err)
	}
	if err := invokeGuarded(t, "RDS", "ModifyDBCluster", &rds.ModifyDBClusterInput{
		DBClusterIdentifier: &id, DeletionProtection: aws.Bool(false),
	}); err == nil {
		t.Error("expected blocked for DeletionProtection change, got nil error")
	}
	if err := invokeGuarded(t, "RDS", "ModifyDBCluster", &rds.ModifyDBClusterInput{
		DBClusterIdentifier: &id, BackupRetentionPeriod: aws.Int32(0),
	}); err == nil {
		t.Error("expected blocked for retention 0, got nil error")
	}
}

func TestGuardCreateBackupPlanEnforcesMinimumLifecycle(t *testing.T) {
	plan := func(deleteAfter *int64) *backup.CreateBackupPlanInput {
		return &backup.CreateBackupPlanInput{
			BackupPlan: &backuptypes.BackupPlanInput{
				BackupPlanName: aws.String("daily"),
				Rules: []backuptypes.BackupRuleInput{
					{
						RuleName:              aws.String("daily-rule"),
						TargetBackupVaultName: aws.String("vault"),
						Lifecycle: &backuptypes.Lifecycle{
							DeleteAfterDays: deleteAfter,
						},
					},
				},
			},
		}
	}

	if err := invokeGuarded(t, "Backup", "CreateBackupPlan", plan(aws.Int64(35))); err != nil {
		t.Errorf("expected allowed for 35-day retention, got: %v", err)
	}
	if err := invokeGuarded(t, "Backup", "CreateBackupPlan", plan(aws.Int64(7))); err != nil {
		t.Errorf("expected allowed at the 7-day floor, got: %v", err)
	}
	if err := invokeGuarded(t, "Backup", "CreateBackupPlan", plan(aws.Int64(1))); err == nil {
		t.Error("expected blocked for a 1-day lifecycle, got nil error")
	}
	if err := invokeGuarded(t, "Backup", "CreateBackupPlan", plan(nil)); err != nil {
		t.Errorf("expected allowed when DeleteAfterDays is unset, got: %v", err)
	}
}

// TestGuardReadOnlyBlocksEveryWriteButAllowsReads is the defence-in-depth
// backstop for a read-only account: GuardMiddleware(true) must still allow
// every List/Describe/Get call the allowlist permits, but reject every
// allowlisted write (CreateDBSnapshot, StartBackupJob, CreateBackupPlan,
// ModifyDBInstance, every Restore* call) and sts:GetCallerIdentity must
// remain allowed since account testing needs it.
func TestGuardReadOnlyBlocksEveryWriteButAllowsReads(t *testing.T) {
	readCases := []struct{ service, op string }{
		{"RDS", "DescribeDBInstances"},
		{"RDS", "DescribeDBClusters"},
		{"RDS", "DescribeDBSnapshots"},
		{"RDS", "ListTagsForResource"},
		{"Backup", "ListRecoveryPointsByResource"},
		{"Backup", "GetBackupPlan"},
		{"STS", "GetCallerIdentity"},
	}
	for _, c := range readCases {
		if err := invokeGuardedReadOnly(t, true, c.service, c.op, &rds.DescribeDBInstancesInput{}); err != nil {
			t.Errorf("read-only: %s/%s: expected allowed, got error: %v", c.service, c.op, err)
		}
	}

	writeCases := []struct{ service, op string }{
		{"RDS", "CreateDBSnapshot"},
		{"RDS", "CreateDBClusterSnapshot"},
		{"RDS", "CreateDBInstance"},
		{"RDS", "RestoreDBInstanceFromDBSnapshot"},
		{"RDS", "RestoreDBClusterFromSnapshot"},
		{"RDS", "RestoreDBInstanceToPointInTime"},
		{"RDS", "RestoreDBClusterToPointInTime"},
		{"RDS", "ModifyDBInstance"},
		{"RDS", "ModifyDBCluster"},
		{"Backup", "StartBackupJob"},
		{"Backup", "StartRestoreJob"},
		{"Backup", "CreateBackupPlan"},
		{"Backup", "CreateBackupSelection"},
	}
	for _, c := range writeCases {
		err := invokeGuardedReadOnly(t, true, c.service, c.op, struct{}{})
		if err == nil {
			t.Errorf("read-only: %s/%s: expected blocked, got nil error", c.service, c.op)
			continue
		}
		var forbidden *ErrOperationForbidden
		if !errors.As(err, &forbidden) {
			t.Errorf("read-only: %s/%s: expected *ErrOperationForbidden, got %T: %v", c.service, c.op, err, err)
		}
	}
}
