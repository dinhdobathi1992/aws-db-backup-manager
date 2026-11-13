package actions

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

func TestWriterInstanceIdentifierAppendsSuffix(t *testing.T) {
	got := writerInstanceIdentifier("my-cluster")
	if got != "my-cluster-1" {
		t.Errorf("got %q, want %q", got, "my-cluster-1")
	}
}

func TestWriterInstanceIdentifierTruncatesLongClusterName(t *testing.T) {
	long := strings.Repeat("a", 70)
	got := writerInstanceIdentifier(long)
	if len(got) > 63 {
		t.Errorf("writer identifier %q is %d characters, want <= 63", got, len(got))
	}
	if !strings.HasSuffix(got, "-1") {
		t.Errorf("expected writer identifier to end with -1, got %q", got)
	}
}

func TestParseRestoreTimeDefaultsToLatest(t *testing.T) {
	restoreTime, useLatest, err := parseRestoreTime(nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if restoreTime != nil {
		t.Errorf("expected a nil restoreTime, got %v", restoreTime)
	}
	if useLatest == nil || !*useLatest {
		t.Errorf("expected useLatest=true, got %v", useLatest)
	}
}

func TestParseRestoreTimeParsesRFC3339(t *testing.T) {
	ts := "2026-01-02T03:04:05Z"
	restoreTime, useLatest, err := parseRestoreTime(&ts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if useLatest != nil {
		t.Errorf("expected a nil useLatest when an explicit time is given, got %v", useLatest)
	}
	want, _ := time.Parse(time.RFC3339, ts)
	if restoreTime == nil || !restoreTime.Equal(want) {
		t.Errorf("got %v, want %v", restoreTime, want)
	}
}

func TestParseRestoreTimeRejectsMalformed(t *testing.T) {
	bad := "not-a-time"
	_, _, err := parseRestoreTime(&bad)
	if err == nil {
		t.Fatal("expected an error for a malformed restore time")
	}
}

func TestRestoreRejectsExistingTarget(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			// Both the source lookup and the existing-target check go
			// through DescribeDBInstances; returning a match for every
			// call is the simplest way to exercise "the target already
			// exists" without needing to distinguish which identifier
			// was asked for.
			return &rds.DescribeDBInstancesOutput{
				DBInstances: []rdstypes.DBInstance{{DBInstanceIdentifier: in.DBInstanceIdentifier}},
			}, nil
		},
		restoreDBInstanceFromDBSnapshot: func(ctx context.Context, in *rds.RestoreDBInstanceFromDBSnapshotInput) (*rds.RestoreDBInstanceFromDBSnapshotOutput, error) {
			t.Fatal("RestoreDBInstanceFromDBSnapshot must never be called when the target already exists")
			return nil, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindInstance,
		Source:             model.RestoreSourceSnapshot,
		SourceDBIdentifier: "prod-db",
		SnapshotID:         "prod-db-manual-20261113-0900",
		TargetIdentifier:   "prod-db-restored",
	})
	if err == nil {
		t.Fatal("expected restoring onto an existing target identifier to be rejected")
	}
}

func TestRestoreFromSnapshotInstance(t *testing.T) {
	var gotInput *rds.RestoreDBInstanceFromDBSnapshotInput
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			if aws.ToString(in.DBInstanceIdentifier) == "prod-db" {
				return &rds.DescribeDBInstancesOutput{
					DBInstances: []rdstypes.DBInstance{{
						DBInstanceIdentifier: in.DBInstanceIdentifier,
						DBInstanceClass:      aws.String("db.r6g.large"),
						Engine:               aws.String("postgres"),
					}},
				}, nil
			}
			return nil, &rdstypes.DBInstanceNotFoundFault{}
		},
		restoreDBInstanceFromDBSnapshot: func(ctx context.Context, in *rds.RestoreDBInstanceFromDBSnapshotInput) (*rds.RestoreDBInstanceFromDBSnapshotOutput, error) {
			gotInput = in
			return &rds.RestoreDBInstanceFromDBSnapshotOutput{}, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	activity, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindInstance,
		Source:             model.RestoreSourceSnapshot,
		SourceDBIdentifier: "prod-db",
		SnapshotID:         "prod-db-manual-20261113-0900",
		TargetIdentifier:   "prod-db-restored",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotInput == nil {
		t.Fatal("expected RestoreDBInstanceFromDBSnapshot to be called")
	}
	if aws.ToString(gotInput.DBInstanceIdentifier) != "prod-db-restored" {
		t.Errorf("unexpected target identifier: %q", aws.ToString(gotInput.DBInstanceIdentifier))
	}
	if aws.ToString(gotInput.DBInstanceClass) != "db.r6g.large" {
		t.Errorf("expected the source instance class to be copied, got %q", aws.ToString(gotInput.DBInstanceClass))
	}
	if activity.DB != "prod-db-restored" {
		t.Errorf("unexpected activity.DB: %q", activity.DB)
	}
}

func TestRestoreFromSnapshotClusterCreatesWriterInstance(t *testing.T) {
	var restoreCalled, createInstanceCalled bool
	cs := newStubClientSet(&stubRDS{
		describeDBClusters: func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error) {
			if aws.ToString(in.DBClusterIdentifier) == "prod-cluster" {
				return &rds.DescribeDBClustersOutput{
					DBClusters: []rdstypes.DBCluster{{DBClusterIdentifier: in.DBClusterIdentifier, Engine: aws.String("aurora-postgresql")}},
				}, nil
			}
			return nil, &rdstypes.DBClusterNotFoundFault{}
		},
		describeDBClusterSnapshots: func(ctx context.Context, in *rds.DescribeDBClusterSnapshotsInput) (*rds.DescribeDBClusterSnapshotsOutput, error) {
			return &rds.DescribeDBClusterSnapshotsOutput{
				DBClusterSnapshots: []rdstypes.DBClusterSnapshot{{
					DBClusterSnapshotIdentifier: in.DBClusterSnapshotIdentifier,
					Engine:                      aws.String("aurora-postgresql"),
					EngineVersion:               aws.String("15.4"),
				}},
			}, nil
		},
		restoreDBClusterFromSnapshot: func(ctx context.Context, in *rds.RestoreDBClusterFromSnapshotInput) (*rds.RestoreDBClusterFromSnapshotOutput, error) {
			restoreCalled = true
			if aws.ToString(in.Engine) != "aurora-postgresql" {
				t.Errorf("expected Engine to come from the snapshot, got %q", aws.ToString(in.Engine))
			}
			return &rds.RestoreDBClusterFromSnapshotOutput{}, nil
		},
		createDBInstance: func(ctx context.Context, in *rds.CreateDBInstanceInput) (*rds.CreateDBInstanceOutput, error) {
			createInstanceCalled = true
			if !restoreCalled {
				t.Error("CreateDBInstance must happen after RestoreDBClusterFromSnapshot")
			}
			if aws.ToString(in.DBClusterIdentifier) != "prod-cluster-restored" {
				t.Errorf("unexpected cluster identifier: %q", aws.ToString(in.DBClusterIdentifier))
			}
			if aws.ToString(in.DBInstanceIdentifier) != "prod-cluster-restored-1" {
				t.Errorf("unexpected writer instance identifier: %q", aws.ToString(in.DBInstanceIdentifier))
			}
			return &rds.CreateDBInstanceOutput{}, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindCluster,
		Source:             model.RestoreSourceSnapshot,
		SourceDBIdentifier: "prod-cluster",
		SnapshotID:         "prod-cluster-manual-20261113-0900",
		TargetIdentifier:   "prod-cluster-restored",
		InstanceClass:      "db.r6g.large",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !restoreCalled || !createInstanceCalled {
		t.Errorf("expected both RestoreDBClusterFromSnapshot and CreateDBInstance to be called, got restore=%v createInstance=%v", restoreCalled, createInstanceCalled)
	}
}

func TestRestoreFromPITRClusterUsesSourceEngine(t *testing.T) {
	var gotCreateInstance *rds.CreateDBInstanceInput
	cs := newStubClientSet(&stubRDS{
		describeDBClusters: func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error) {
			if aws.ToString(in.DBClusterIdentifier) == "prod-cluster" {
				return &rds.DescribeDBClustersOutput{
					DBClusters: []rdstypes.DBCluster{{DBClusterIdentifier: in.DBClusterIdentifier, Engine: aws.String("aurora-mysql")}},
				}, nil
			}
			return nil, &rdstypes.DBClusterNotFoundFault{}
		},
		restoreDBClusterToPointInTime: func(ctx context.Context, in *rds.RestoreDBClusterToPointInTimeInput) (*rds.RestoreDBClusterToPointInTimeOutput, error) {
			return &rds.RestoreDBClusterToPointInTimeOutput{}, nil
		},
		createDBInstance: func(ctx context.Context, in *rds.CreateDBInstanceInput) (*rds.CreateDBInstanceOutput, error) {
			gotCreateInstance = in
			return &rds.CreateDBInstanceOutput{}, nil
		},
	}, nil, nil)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindCluster,
		Source:             model.RestoreSourcePITR,
		SourceDBIdentifier: "prod-cluster",
		TargetIdentifier:   "prod-cluster-pitr",
		InstanceClass:      "db.r6g.large",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotCreateInstance == nil || aws.ToString(gotCreateInstance.Engine) != "aurora-mysql" {
		t.Errorf("expected the writer instance's engine to come from the live source cluster, got %+v", gotCreateInstance)
	}
}

func TestRestoreFromRecoveryPointUsesVaultFromInventoryAndMetadataResourceType(t *testing.T) {
	var gotStartRestore *backup.StartRestoreJobInput
	cs := newStubClientSet(
		&stubRDS{
			// ListSnapshotsForDB (used to resolve the recovery point's
			// vault) also reads RDS-native snapshots for this database;
			// this account has none.
			describeDBSnapshots: func(ctx context.Context, in *rds.DescribeDBSnapshotsInput) (*rds.DescribeDBSnapshotsOutput, error) {
				return &rds.DescribeDBSnapshotsOutput{}, nil
			},
		},
		&stubBackup{
			listRecoveryPointsByResource: func(ctx context.Context, in *backup.ListRecoveryPointsByResourceInput) (*backup.ListRecoveryPointsByResourceOutput, error) {
				return &backup.ListRecoveryPointsByResourceOutput{
					RecoveryPoints: []backuptypes.RecoveryPointByResource{{
						RecoveryPointArn: aws.String("arn:aws:backup:ap-southeast-1:123456789012:recovery-point:abc"),
						BackupVaultName:  aws.String("prod-vault"),
						Status:           backuptypes.RecoveryPointStatusCompleted,
						CreationDate:     aws.Time(time.Now()),
					}},
				}, nil
			},
			getRecoveryPointRestoreMetadata: func(ctx context.Context, in *backup.GetRecoveryPointRestoreMetadataInput) (*backup.GetRecoveryPointRestoreMetadataOutput, error) {
				if aws.ToString(in.BackupVaultName) != "prod-vault" {
					t.Errorf("expected the vault derived from inventory, got %q", aws.ToString(in.BackupVaultName))
				}
				return &backup.GetRecoveryPointRestoreMetadataOutput{
					ResourceType:    aws.String("RDS"),
					RestoreMetadata: map[string]string{"Engine": "postgres"},
				}, nil
			},
			startRestoreJob: func(ctx context.Context, in *backup.StartRestoreJobInput) (*backup.StartRestoreJobOutput, error) {
				gotStartRestore = in
				return &backup.StartRestoreJobOutput{RestoreJobId: aws.String("restore-1")}, nil
			},
		},
		&stubSTS{},
	)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindInstance,
		Source:             model.RestoreSourceRecoveryPoint,
		SourceDBIdentifier: "prod-db",
		RecoveryPointArn:   "arn:aws:backup:ap-southeast-1:123456789012:recovery-point:abc",
		TargetIdentifier:   "prod-db-from-rp",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotStartRestore == nil {
		t.Fatal("expected StartRestoreJob to be called")
	}
	if aws.ToString(gotStartRestore.ResourceType) != "RDS" {
		t.Errorf("expected ResourceType taken directly from the metadata lookup, got %q", aws.ToString(gotStartRestore.ResourceType))
	}
	if gotStartRestore.Metadata["DBInstanceIdentifier"] != "prod-db-from-rp" {
		t.Errorf("expected the target identifier to be set in the restore metadata, got %+v", gotStartRestore.Metadata)
	}
}

func TestRestoreFromRecoveryPointRejectsUnknownArn(t *testing.T) {
	cs := newStubClientSet(
		&stubRDS{
			describeDBSnapshots: func(ctx context.Context, in *rds.DescribeDBSnapshotsInput) (*rds.DescribeDBSnapshotsOutput, error) {
				return &rds.DescribeDBSnapshotsOutput{}, nil
			},
		},
		&stubBackup{
			listRecoveryPointsByResource: func(ctx context.Context, in *backup.ListRecoveryPointsByResourceInput) (*backup.ListRecoveryPointsByResourceOutput, error) {
				return &backup.ListRecoveryPointsByResourceOutput{}, nil
			},
		},
		&stubSTS{},
	)
	clients := newStubClients(testProfile, testRegion, cs)

	_, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindInstance,
		Source:             model.RestoreSourceRecoveryPoint,
		SourceDBIdentifier: "prod-db",
		RecoveryPointArn:   "arn:aws:backup:ap-southeast-1:123456789012:recovery-point:unknown",
		TargetIdentifier:   "prod-db-from-rp",
	})
	if err == nil {
		t.Fatal("expected an error when the recovery point ARN isn't found for this database")
	}
}

func TestRestoreRejectsMissingTargetIdentifier(t *testing.T) {
	clients := newStubClients(testProfile, testRegion, newStubClientSet(nil, nil, nil))
	_, err := Restore(context.Background(), clients, testAccount(), model.RestoreReq{
		Region:             testRegion,
		Kind:               model.DBKindInstance,
		Source:             model.RestoreSourceSnapshot,
		SourceDBIdentifier: "prod-db",
		SnapshotID:         "some-snapshot",
	})
	if err == nil {
		t.Fatal("expected an error when targetIdentifier is missing")
	}
}
