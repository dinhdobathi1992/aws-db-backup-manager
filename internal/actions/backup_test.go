package actions

import (
	"context"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

const testProfile = "shared-service-test"
const testRegion = "ap-southeast-1"

func testAccount() model.Account {
	return model.Account{ID: "acct-1", Name: "Test", Profile: testProfile, Regions: []string{testRegion}}
}

func TestCreateSnapshotDefaultsNameForInstance(t *testing.T) {
	var gotID *string
	cs := newStubClientSet(&stubRDS{
		createDBSnapshot: func(ctx context.Context, in *rds.CreateDBSnapshotInput) (*rds.CreateDBSnapshotOutput, error) {
			gotID = in.DBSnapshotIdentifier
			return &rds.CreateDBSnapshotOutput{DBSnapshot: &rdstypes.DBSnapshot{
				DBSnapshotIdentifier: in.DBSnapshotIdentifier,
				DBInstanceIdentifier: in.DBInstanceIdentifier,
				Status:               aws.String("creating"),
				Engine:               aws.String("postgres"),
			}}, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	snap, err := CreateSnapshot(context.Background(), clients, testAccount(), model.CreateSnapshotReq{
		Region:       testRegion,
		Kind:         model.DBKindInstance,
		DBIdentifier: "prod-db",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotID == nil || !containsManualPrefix(*gotID, "prod-db") {
		t.Errorf("expected a default manual snapshot name for prod-db, got %v", gotID)
	}
	if snap.Source != model.SnapshotSourceManual || snap.Kind != model.DBKindInstance {
		t.Errorf("unexpected snapshot shape: %+v", snap)
	}
}

func containsManualPrefix(id, db string) bool {
	prefix := db + "-manual-"
	return len(id) >= len(prefix) && id[:len(prefix)] == prefix
}

func TestCreateSnapshotRejectsMissingDBIdentifier(t *testing.T) {
	clients := newStubClients(testProfile, testRegion, newStubClientSet(nil, nil, nil))
	_, err := CreateSnapshot(context.Background(), clients, testAccount(), model.CreateSnapshotReq{Region: testRegion})
	if err == nil {
		t.Fatal("expected an error when dbIdentifier is missing")
	}
}

func TestStartBackupJobUsesDefaultVaultAndRole(t *testing.T) {
	var gotInput *backup.StartBackupJobInput
	cs := newStubClientSet(nil, &stubBackup{
		startBackupJob: func(ctx context.Context, in *backup.StartBackupJobInput) (*backup.StartBackupJobOutput, error) {
			gotInput = in
			return &backup.StartBackupJobOutput{BackupJobId: aws.String("job-1"), CreationDate: aws.Time(time.Now())}, nil
		},
	}, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := StartBackupJob(context.Background(), clients, testAccount(), model.StartBackupJobReq{
		Region:       testRegion,
		Kind:         model.DBKindInstance,
		DBIdentifier: "prod-db",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if aws.ToString(gotInput.BackupVaultName) != defaultBackupVaultName {
		t.Errorf("expected default vault %q, got %q", defaultBackupVaultName, aws.ToString(gotInput.BackupVaultName))
	}
	if aws.ToString(gotInput.IamRoleArn) != defaultBackupRoleArn("123456789012") {
		t.Errorf("expected default role arn, got %q", aws.ToString(gotInput.IamRoleArn))
	}
}

func TestCreateBackupPlanRejectsRetentionBelowMinimum(t *testing.T) {
	clients := newStubClients(testProfile, testRegion, newStubClientSet(nil, nil, nil))
	_, err := CreateBackupPlan(context.Background(), clients, testAccount(), model.CreateBackupPlanReq{
		Region:        testRegion,
		Kind:          model.DBKindInstance,
		DBIdentifier:  "prod-db",
		Cron:          "cron(0 5 * * ? *)",
		RetentionDays: minBackupPlanRetentionDays - 1,
	})
	if err == nil {
		t.Fatal("expected retentionDays below the minimum to be blocked before any AWS call")
	}
}

func TestCreateBackupPlanRejectsMissingCron(t *testing.T) {
	clients := newStubClients(testProfile, testRegion, newStubClientSet(nil, nil, nil))
	_, err := CreateBackupPlan(context.Background(), clients, testAccount(), model.CreateBackupPlanReq{
		Region:        testRegion,
		Kind:          model.DBKindInstance,
		DBIdentifier:  "prod-db",
		RetentionDays: minBackupPlanRetentionDays,
	})
	if err == nil {
		t.Fatal("expected a missing cron expression to be rejected")
	}
}

func TestCreateBackupPlanCreatesPlanAndSelectionByArn(t *testing.T) {
	var gotPlan *backup.CreateBackupPlanInput
	var gotSelection *backup.CreateBackupSelectionInput
	cs := newStubClientSet(
		&stubRDS{
			// CreateBackupPlan re-reads inventory afterward; return no
			// databases so the action falls back to its own summary
			// rather than exercising the full inventory read path here.
			describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
				return &rds.DescribeDBInstancesOutput{}, nil
			},
			describeDBClusters: func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error) {
				return &rds.DescribeDBClustersOutput{}, nil
			},
		},
		&stubBackup{
			createBackupPlan: func(ctx context.Context, in *backup.CreateBackupPlanInput) (*backup.CreateBackupPlanOutput, error) {
				gotPlan = in
				return &backup.CreateBackupPlanOutput{BackupPlanId: aws.String("plan-1")}, nil
			},
			createBackupSelection: func(ctx context.Context, in *backup.CreateBackupSelectionInput) (*backup.CreateBackupSelectionOutput, error) {
				gotSelection = in
				return &backup.CreateBackupSelectionOutput{SelectionId: aws.String("sel-1")}, nil
			},
		},
		nil,
	)
	clients := newStubClients(testProfile, testRegion, cs)

	summary, err := CreateBackupPlan(context.Background(), clients, testAccount(), model.CreateBackupPlanReq{
		Region:        testRegion,
		Kind:          model.DBKindInstance,
		DBIdentifier:  "prod-db",
		Cron:          "cron(0 5 * * ? *)",
		RetentionDays: 30,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotPlan == nil || len(gotPlan.BackupPlan.Rules) != 1 {
		t.Fatalf("expected exactly one backup rule, got %+v", gotPlan)
	}
	if gotPlan.BackupPlan.Rules[0].Lifecycle.DeleteAfterDays == nil || *gotPlan.BackupPlan.Rules[0].Lifecycle.DeleteAfterDays != 30 {
		t.Errorf("expected DeleteAfterDays=30, got %+v", gotPlan.BackupPlan.Rules[0].Lifecycle)
	}
	if gotSelection == nil || len(gotSelection.BackupSelection.Resources) != 1 {
		t.Fatalf("expected the selection to target exactly one resource ARN, got %+v", gotSelection)
	}
	if summary.DB != "prod-db" {
		t.Errorf("expected summary.DB = prod-db, got %q", summary.DB)
	}
}

func TestModifyAutomatedBackupRejectsMissingFields(t *testing.T) {
	clients := newStubClients(testProfile, testRegion, newStubClientSet(nil, nil, nil))
	_, err := ModifyAutomatedBackup(context.Background(), clients, testAccount(), model.ModifyAutomatedBackupReq{
		Region:       testRegion,
		Kind:         model.DBKindInstance,
		DBIdentifier: "prod-db",
	})
	if err == nil {
		t.Fatal("expected an error when neither window nor retentionDays is set")
	}
}

func TestModifyAutomatedBackupBlocksLoweringRetention(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			return &rds.DescribeDBInstancesOutput{
				DBInstances: []rdstypes.DBInstance{{
					DBInstanceIdentifier:  in.DBInstanceIdentifier,
					BackupRetentionPeriod: aws.Int32(30),
					PreferredBackupWindow: aws.String("05:00-05:30"),
				}},
			}, nil
		},
		modifyDBInstance: func(ctx context.Context, in *rds.ModifyDBInstanceInput) (*rds.ModifyDBInstanceOutput, error) {
			t.Fatal("ModifyDBInstance must never be called when the request would lower retention")
			return nil, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := ModifyAutomatedBackup(context.Background(), clients, testAccount(), model.ModifyAutomatedBackupReq{
		Region:        testRegion,
		Kind:          model.DBKindInstance,
		DBIdentifier:  "prod-db",
		RetentionDays: 7, // lower than the current 30
	})
	if err == nil {
		t.Fatal("expected lowering retention below the current value to be blocked")
	}
}

func TestModifyAutomatedBackupAllowsRaisingRetention(t *testing.T) {
	var modifyCalled bool
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			if modifyCalled {
				// The post-modify inventory re-read lists every instance
				// in the region unfiltered, so the identifier must come
				// from the fixture, not an (absent) request filter.
				return &rds.DescribeDBInstancesOutput{
					DBInstances: []rdstypes.DBInstance{{
						DBInstanceIdentifier:  aws.String("prod-db"),
						BackupRetentionPeriod: aws.Int32(45),
					}},
				}, nil
			}
			return &rds.DescribeDBInstancesOutput{
				DBInstances: []rdstypes.DBInstance{{
					DBInstanceIdentifier:  in.DBInstanceIdentifier,
					BackupRetentionPeriod: aws.Int32(7),
				}},
			}, nil
		},
		modifyDBInstance: func(ctx context.Context, in *rds.ModifyDBInstanceInput) (*rds.ModifyDBInstanceOutput, error) {
			modifyCalled = true
			if in.BackupRetentionPeriod == nil || *in.BackupRetentionPeriod != 45 {
				t.Errorf("expected BackupRetentionPeriod=45, got %+v", in.BackupRetentionPeriod)
			}
			return &rds.ModifyDBInstanceOutput{}, nil
		},
		describeDBClusters: func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error) {
			// The post-modify inventory re-read fans out to clusters too;
			// this account has none.
			return &rds.DescribeDBClustersOutput{}, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	db, err := ModifyAutomatedBackup(context.Background(), clients, testAccount(), model.ModifyAutomatedBackupReq{
		Region:        testRegion,
		Kind:          model.DBKindInstance,
		DBIdentifier:  "prod-db",
		RetentionDays: 45,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !modifyCalled {
		t.Error("expected ModifyDBInstance to be called when raising retention")
	}
	if db.BackupRetentionDays != 45 {
		t.Errorf("expected the re-read database to report retention 45, got %d", db.BackupRetentionDays)
	}
}

func TestCurrentBackupSettingsCluster(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBClusters: func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error) {
			return &rds.DescribeDBClustersOutput{
				DBClusters: []rdstypes.DBCluster{{
					BackupRetentionPeriod: aws.Int32(14),
					PreferredBackupWindow: aws.String("03:00-03:30"),
				}},
			}, nil
		},
	}, nil, nil)

	retention, window, err := currentBackupSettings(context.Background(), cs, model.DBKindCluster, "prod-cluster")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if retention != 14 || window != "03:00-03:30" {
		t.Errorf("unexpected settings: retention=%d window=%q", retention, window)
	}
}
