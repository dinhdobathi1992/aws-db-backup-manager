package actions

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/service/backup"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
)

// stubRDS implements awsx.RDSAPI with per-test-overridable function fields.
// Any method left nil fails loudly, so a test that didn't expect a call to
// reach AWS finds out immediately instead of silently getting a zero value.
// DescribeDBInstances/DescribeDBClusters default to "not found" (a database
// that doesn't exist yet), the shape most tests want for a restore/backup
// target.
type stubRDS struct {
	describeDBInstances                func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error)
	describeDBClusters                 func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error)
	describeDBSnapshots                func(ctx context.Context, in *rds.DescribeDBSnapshotsInput) (*rds.DescribeDBSnapshotsOutput, error)
	describeDBClusterSnapshots         func(ctx context.Context, in *rds.DescribeDBClusterSnapshotsInput) (*rds.DescribeDBClusterSnapshotsOutput, error)
	describeEvents                     func(ctx context.Context, in *rds.DescribeEventsInput) (*rds.DescribeEventsOutput, error)
	describeDBInstanceAutomatedBackups func(ctx context.Context, in *rds.DescribeDBInstanceAutomatedBackupsInput) (*rds.DescribeDBInstanceAutomatedBackupsOutput, error)
	createDBSnapshot                   func(ctx context.Context, in *rds.CreateDBSnapshotInput) (*rds.CreateDBSnapshotOutput, error)
	createDBClusterSnapshot            func(ctx context.Context, in *rds.CreateDBClusterSnapshotInput) (*rds.CreateDBClusterSnapshotOutput, error)
	createDBInstance                   func(ctx context.Context, in *rds.CreateDBInstanceInput) (*rds.CreateDBInstanceOutput, error)
	modifyDBInstance                   func(ctx context.Context, in *rds.ModifyDBInstanceInput) (*rds.ModifyDBInstanceOutput, error)
	modifyDBCluster                    func(ctx context.Context, in *rds.ModifyDBClusterInput) (*rds.ModifyDBClusterOutput, error)
	restoreDBInstanceFromDBSnapshot    func(ctx context.Context, in *rds.RestoreDBInstanceFromDBSnapshotInput) (*rds.RestoreDBInstanceFromDBSnapshotOutput, error)
	restoreDBClusterFromSnapshot       func(ctx context.Context, in *rds.RestoreDBClusterFromSnapshotInput) (*rds.RestoreDBClusterFromSnapshotOutput, error)
	restoreDBInstanceToPointInTime     func(ctx context.Context, in *rds.RestoreDBInstanceToPointInTimeInput) (*rds.RestoreDBInstanceToPointInTimeOutput, error)
	restoreDBClusterToPointInTime      func(ctx context.Context, in *rds.RestoreDBClusterToPointInTimeInput) (*rds.RestoreDBClusterToPointInTimeOutput, error)
}

func (s *stubRDS) DescribeDBInstances(ctx context.Context, in *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	if s.describeDBInstances != nil {
		return s.describeDBInstances(ctx, in)
	}
	return nil, &rdstypes.DBInstanceNotFoundFault{}
}

func (s *stubRDS) DescribeDBClusters(ctx context.Context, in *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	if s.describeDBClusters != nil {
		return s.describeDBClusters(ctx, in)
	}
	return nil, &rdstypes.DBClusterNotFoundFault{}
}

func (s *stubRDS) DescribeDBSnapshots(ctx context.Context, in *rds.DescribeDBSnapshotsInput, _ ...func(*rds.Options)) (*rds.DescribeDBSnapshotsOutput, error) {
	if s.describeDBSnapshots != nil {
		return s.describeDBSnapshots(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to DescribeDBSnapshots")
}

func (s *stubRDS) DescribeDBClusterSnapshots(ctx context.Context, in *rds.DescribeDBClusterSnapshotsInput, _ ...func(*rds.Options)) (*rds.DescribeDBClusterSnapshotsOutput, error) {
	if s.describeDBClusterSnapshots != nil {
		return s.describeDBClusterSnapshots(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to DescribeDBClusterSnapshots")
}

func (s *stubRDS) DescribeEvents(ctx context.Context, in *rds.DescribeEventsInput, _ ...func(*rds.Options)) (*rds.DescribeEventsOutput, error) {
	if s.describeEvents != nil {
		return s.describeEvents(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to DescribeEvents")
}

func (s *stubRDS) DescribeDBInstanceAutomatedBackups(ctx context.Context, in *rds.DescribeDBInstanceAutomatedBackupsInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstanceAutomatedBackupsOutput, error) {
	if s.describeDBInstanceAutomatedBackups != nil {
		return s.describeDBInstanceAutomatedBackups(ctx, in)
	}
	return &rds.DescribeDBInstanceAutomatedBackupsOutput{}, nil
}

func (s *stubRDS) CreateDBSnapshot(ctx context.Context, in *rds.CreateDBSnapshotInput, _ ...func(*rds.Options)) (*rds.CreateDBSnapshotOutput, error) {
	if s.createDBSnapshot != nil {
		return s.createDBSnapshot(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to CreateDBSnapshot")
}

func (s *stubRDS) CreateDBClusterSnapshot(ctx context.Context, in *rds.CreateDBClusterSnapshotInput, _ ...func(*rds.Options)) (*rds.CreateDBClusterSnapshotOutput, error) {
	if s.createDBClusterSnapshot != nil {
		return s.createDBClusterSnapshot(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to CreateDBClusterSnapshot")
}

func (s *stubRDS) CreateDBInstance(ctx context.Context, in *rds.CreateDBInstanceInput, _ ...func(*rds.Options)) (*rds.CreateDBInstanceOutput, error) {
	if s.createDBInstance != nil {
		return s.createDBInstance(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to CreateDBInstance")
}

func (s *stubRDS) ModifyDBInstance(ctx context.Context, in *rds.ModifyDBInstanceInput, _ ...func(*rds.Options)) (*rds.ModifyDBInstanceOutput, error) {
	if s.modifyDBInstance != nil {
		return s.modifyDBInstance(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to ModifyDBInstance")
}

func (s *stubRDS) ModifyDBCluster(ctx context.Context, in *rds.ModifyDBClusterInput, _ ...func(*rds.Options)) (*rds.ModifyDBClusterOutput, error) {
	if s.modifyDBCluster != nil {
		return s.modifyDBCluster(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to ModifyDBCluster")
}

func (s *stubRDS) RestoreDBInstanceFromDBSnapshot(ctx context.Context, in *rds.RestoreDBInstanceFromDBSnapshotInput, _ ...func(*rds.Options)) (*rds.RestoreDBInstanceFromDBSnapshotOutput, error) {
	if s.restoreDBInstanceFromDBSnapshot != nil {
		return s.restoreDBInstanceFromDBSnapshot(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to RestoreDBInstanceFromDBSnapshot")
}

func (s *stubRDS) RestoreDBClusterFromSnapshot(ctx context.Context, in *rds.RestoreDBClusterFromSnapshotInput, _ ...func(*rds.Options)) (*rds.RestoreDBClusterFromSnapshotOutput, error) {
	if s.restoreDBClusterFromSnapshot != nil {
		return s.restoreDBClusterFromSnapshot(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to RestoreDBClusterFromSnapshot")
}

func (s *stubRDS) RestoreDBInstanceToPointInTime(ctx context.Context, in *rds.RestoreDBInstanceToPointInTimeInput, _ ...func(*rds.Options)) (*rds.RestoreDBInstanceToPointInTimeOutput, error) {
	if s.restoreDBInstanceToPointInTime != nil {
		return s.restoreDBInstanceToPointInTime(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to RestoreDBInstanceToPointInTime")
}

func (s *stubRDS) RestoreDBClusterToPointInTime(ctx context.Context, in *rds.RestoreDBClusterToPointInTimeInput, _ ...func(*rds.Options)) (*rds.RestoreDBClusterToPointInTimeOutput, error) {
	if s.restoreDBClusterToPointInTime != nil {
		return s.restoreDBClusterToPointInTime(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to RestoreDBClusterToPointInTime")
}

// stubBackup implements awsx.BackupAPI the same way stubRDS implements
// awsx.RDSAPI: nil fields fail loudly instead of returning a zero value.
type stubBackup struct {
	getBackupPlan                   func(ctx context.Context, in *backup.GetBackupPlanInput) (*backup.GetBackupPlanOutput, error)
	getBackupSelection              func(ctx context.Context, in *backup.GetBackupSelectionInput) (*backup.GetBackupSelectionOutput, error)
	getRecoveryPointRestoreMetadata func(ctx context.Context, in *backup.GetRecoveryPointRestoreMetadataInput) (*backup.GetRecoveryPointRestoreMetadataOutput, error)
	listRecoveryPointsByResource    func(ctx context.Context, in *backup.ListRecoveryPointsByResourceInput) (*backup.ListRecoveryPointsByResourceOutput, error)
	listBackupPlans                 func(ctx context.Context, in *backup.ListBackupPlansInput) (*backup.ListBackupPlansOutput, error)
	listBackupSelections            func(ctx context.Context, in *backup.ListBackupSelectionsInput) (*backup.ListBackupSelectionsOutput, error)
	listBackupJobs                  func(ctx context.Context, in *backup.ListBackupJobsInput) (*backup.ListBackupJobsOutput, error)
	listRestoreJobs                 func(ctx context.Context, in *backup.ListRestoreJobsInput) (*backup.ListRestoreJobsOutput, error)
	createBackupPlan                func(ctx context.Context, in *backup.CreateBackupPlanInput) (*backup.CreateBackupPlanOutput, error)
	createBackupSelection           func(ctx context.Context, in *backup.CreateBackupSelectionInput) (*backup.CreateBackupSelectionOutput, error)
	startBackupJob                  func(ctx context.Context, in *backup.StartBackupJobInput) (*backup.StartBackupJobOutput, error)
	startRestoreJob                 func(ctx context.Context, in *backup.StartRestoreJobInput) (*backup.StartRestoreJobOutput, error)
}

func (s *stubBackup) GetBackupPlan(ctx context.Context, in *backup.GetBackupPlanInput, _ ...func(*backup.Options)) (*backup.GetBackupPlanOutput, error) {
	if s.getBackupPlan != nil {
		return s.getBackupPlan(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to GetBackupPlan")
}

func (s *stubBackup) GetBackupSelection(ctx context.Context, in *backup.GetBackupSelectionInput, _ ...func(*backup.Options)) (*backup.GetBackupSelectionOutput, error) {
	if s.getBackupSelection != nil {
		return s.getBackupSelection(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to GetBackupSelection")
}

func (s *stubBackup) GetRecoveryPointRestoreMetadata(ctx context.Context, in *backup.GetRecoveryPointRestoreMetadataInput, _ ...func(*backup.Options)) (*backup.GetRecoveryPointRestoreMetadataOutput, error) {
	if s.getRecoveryPointRestoreMetadata != nil {
		return s.getRecoveryPointRestoreMetadata(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to GetRecoveryPointRestoreMetadata")
}

func (s *stubBackup) ListRecoveryPointsByResource(ctx context.Context, in *backup.ListRecoveryPointsByResourceInput, _ ...func(*backup.Options)) (*backup.ListRecoveryPointsByResourceOutput, error) {
	if s.listRecoveryPointsByResource != nil {
		return s.listRecoveryPointsByResource(ctx, in)
	}
	return &backup.ListRecoveryPointsByResourceOutput{}, nil
}

func (s *stubBackup) ListBackupPlans(ctx context.Context, in *backup.ListBackupPlansInput, _ ...func(*backup.Options)) (*backup.ListBackupPlansOutput, error) {
	if s.listBackupPlans != nil {
		return s.listBackupPlans(ctx, in)
	}
	return &backup.ListBackupPlansOutput{}, nil
}

func (s *stubBackup) ListBackupSelections(ctx context.Context, in *backup.ListBackupSelectionsInput, _ ...func(*backup.Options)) (*backup.ListBackupSelectionsOutput, error) {
	if s.listBackupSelections != nil {
		return s.listBackupSelections(ctx, in)
	}
	return &backup.ListBackupSelectionsOutput{}, nil
}

func (s *stubBackup) ListBackupJobs(ctx context.Context, in *backup.ListBackupJobsInput, _ ...func(*backup.Options)) (*backup.ListBackupJobsOutput, error) {
	if s.listBackupJobs != nil {
		return s.listBackupJobs(ctx, in)
	}
	return &backup.ListBackupJobsOutput{}, nil
}

func (s *stubBackup) ListRestoreJobs(ctx context.Context, in *backup.ListRestoreJobsInput, _ ...func(*backup.Options)) (*backup.ListRestoreJobsOutput, error) {
	if s.listRestoreJobs != nil {
		return s.listRestoreJobs(ctx, in)
	}
	return &backup.ListRestoreJobsOutput{}, nil
}

func (s *stubBackup) CreateBackupPlan(ctx context.Context, in *backup.CreateBackupPlanInput, _ ...func(*backup.Options)) (*backup.CreateBackupPlanOutput, error) {
	if s.createBackupPlan != nil {
		return s.createBackupPlan(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to CreateBackupPlan")
}

func (s *stubBackup) CreateBackupSelection(ctx context.Context, in *backup.CreateBackupSelectionInput, _ ...func(*backup.Options)) (*backup.CreateBackupSelectionOutput, error) {
	if s.createBackupSelection != nil {
		return s.createBackupSelection(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to CreateBackupSelection")
}

func (s *stubBackup) StartBackupJob(ctx context.Context, in *backup.StartBackupJobInput, _ ...func(*backup.Options)) (*backup.StartBackupJobOutput, error) {
	if s.startBackupJob != nil {
		return s.startBackupJob(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to StartBackupJob")
}

func (s *stubBackup) StartRestoreJob(ctx context.Context, in *backup.StartRestoreJobInput, _ ...func(*backup.Options)) (*backup.StartRestoreJobOutput, error) {
	if s.startRestoreJob != nil {
		return s.startRestoreJob(ctx, in)
	}
	return nil, fmt.Errorf("unexpected call to StartRestoreJob")
}

// stubSTS implements awsx.STSAPI, defaulting GetCallerIdentity to a fixed,
// obviously-fake account number so helpers.go's resolveAccountNumber works
// without a real STS call.
type stubSTS struct {
	getCallerIdentity func(ctx context.Context, in *sts.GetCallerIdentityInput) (*sts.GetCallerIdentityOutput, error)
}

func (s *stubSTS) GetCallerIdentity(ctx context.Context, in *sts.GetCallerIdentityInput, _ ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error) {
	if s.getCallerIdentity != nil {
		return s.getCallerIdentity(ctx, in)
	}
	account := "123456789012"
	return &sts.GetCallerIdentityOutput{Account: &account}, nil
}

// newStubClientSet builds a ClientSet backed entirely by the stubs above.
func newStubClientSet(r *stubRDS, b *stubBackup, s *stubSTS) *awsx.ClientSet {
	if r == nil {
		r = &stubRDS{}
	}
	if b == nil {
		b = &stubBackup{}
	}
	if s == nil {
		s = &stubSTS{}
	}
	return &awsx.ClientSet{RDS: r, Backup: b, STS: s}
}

// newStubClients wraps a stub ClientSet in a real *awsx.Clients cache, so
// action functions that take *awsx.Clients (and internally call
// clients.For) exercise their real code path, including any re-read via
// the inventory package, without ever reaching a live AWS endpoint.
func newStubClients(profile, region string, cs *awsx.ClientSet) *awsx.Clients {
	c := awsx.NewClients()
	c.Seed(profile, region, cs)
	return c
}
