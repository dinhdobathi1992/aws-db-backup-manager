package awsx

import (
	"context"
	"fmt"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go/middleware"
)

// RDSAPI is the subset of *rds.Client this app calls, narrowed to an
// interface so tests can substitute a stub instead of a live, guarded
// client. *rds.Client satisfies this automatically; production code never
// constructs a ClientSet any other way.
type RDSAPI interface {
	DescribeDBInstances(ctx context.Context, in *rds.DescribeDBInstancesInput, optFns ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error)
	DescribeDBClusters(ctx context.Context, in *rds.DescribeDBClustersInput, optFns ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error)
	DescribeDBSnapshots(ctx context.Context, in *rds.DescribeDBSnapshotsInput, optFns ...func(*rds.Options)) (*rds.DescribeDBSnapshotsOutput, error)
	DescribeDBClusterSnapshots(ctx context.Context, in *rds.DescribeDBClusterSnapshotsInput, optFns ...func(*rds.Options)) (*rds.DescribeDBClusterSnapshotsOutput, error)
	DescribeEvents(ctx context.Context, in *rds.DescribeEventsInput, optFns ...func(*rds.Options)) (*rds.DescribeEventsOutput, error)
	DescribeDBInstanceAutomatedBackups(ctx context.Context, in *rds.DescribeDBInstanceAutomatedBackupsInput, optFns ...func(*rds.Options)) (*rds.DescribeDBInstanceAutomatedBackupsOutput, error)
	CreateDBSnapshot(ctx context.Context, in *rds.CreateDBSnapshotInput, optFns ...func(*rds.Options)) (*rds.CreateDBSnapshotOutput, error)
	CreateDBClusterSnapshot(ctx context.Context, in *rds.CreateDBClusterSnapshotInput, optFns ...func(*rds.Options)) (*rds.CreateDBClusterSnapshotOutput, error)
	CreateDBInstance(ctx context.Context, in *rds.CreateDBInstanceInput, optFns ...func(*rds.Options)) (*rds.CreateDBInstanceOutput, error)
	ModifyDBInstance(ctx context.Context, in *rds.ModifyDBInstanceInput, optFns ...func(*rds.Options)) (*rds.ModifyDBInstanceOutput, error)
	ModifyDBCluster(ctx context.Context, in *rds.ModifyDBClusterInput, optFns ...func(*rds.Options)) (*rds.ModifyDBClusterOutput, error)
	RestoreDBInstanceFromDBSnapshot(ctx context.Context, in *rds.RestoreDBInstanceFromDBSnapshotInput, optFns ...func(*rds.Options)) (*rds.RestoreDBInstanceFromDBSnapshotOutput, error)
	RestoreDBClusterFromSnapshot(ctx context.Context, in *rds.RestoreDBClusterFromSnapshotInput, optFns ...func(*rds.Options)) (*rds.RestoreDBClusterFromSnapshotOutput, error)
	RestoreDBInstanceToPointInTime(ctx context.Context, in *rds.RestoreDBInstanceToPointInTimeInput, optFns ...func(*rds.Options)) (*rds.RestoreDBInstanceToPointInTimeOutput, error)
	RestoreDBClusterToPointInTime(ctx context.Context, in *rds.RestoreDBClusterToPointInTimeInput, optFns ...func(*rds.Options)) (*rds.RestoreDBClusterToPointInTimeOutput, error)
}

// BackupAPI is the subset of *backup.Client this app calls, narrowed to an
// interface for the same reason as RDSAPI.
type BackupAPI interface {
	GetBackupPlan(ctx context.Context, in *backup.GetBackupPlanInput, optFns ...func(*backup.Options)) (*backup.GetBackupPlanOutput, error)
	GetBackupSelection(ctx context.Context, in *backup.GetBackupSelectionInput, optFns ...func(*backup.Options)) (*backup.GetBackupSelectionOutput, error)
	GetRecoveryPointRestoreMetadata(ctx context.Context, in *backup.GetRecoveryPointRestoreMetadataInput, optFns ...func(*backup.Options)) (*backup.GetRecoveryPointRestoreMetadataOutput, error)
	ListRecoveryPointsByResource(ctx context.Context, in *backup.ListRecoveryPointsByResourceInput, optFns ...func(*backup.Options)) (*backup.ListRecoveryPointsByResourceOutput, error)
	ListBackupPlans(ctx context.Context, in *backup.ListBackupPlansInput, optFns ...func(*backup.Options)) (*backup.ListBackupPlansOutput, error)
	ListBackupSelections(ctx context.Context, in *backup.ListBackupSelectionsInput, optFns ...func(*backup.Options)) (*backup.ListBackupSelectionsOutput, error)
	ListBackupJobs(ctx context.Context, in *backup.ListBackupJobsInput, optFns ...func(*backup.Options)) (*backup.ListBackupJobsOutput, error)
	ListRestoreJobs(ctx context.Context, in *backup.ListRestoreJobsInput, optFns ...func(*backup.Options)) (*backup.ListRestoreJobsOutput, error)
	CreateBackupPlan(ctx context.Context, in *backup.CreateBackupPlanInput, optFns ...func(*backup.Options)) (*backup.CreateBackupPlanOutput, error)
	CreateBackupSelection(ctx context.Context, in *backup.CreateBackupSelectionInput, optFns ...func(*backup.Options)) (*backup.CreateBackupSelectionOutput, error)
	StartBackupJob(ctx context.Context, in *backup.StartBackupJobInput, optFns ...func(*backup.Options)) (*backup.StartBackupJobOutput, error)
	StartRestoreJob(ctx context.Context, in *backup.StartRestoreJobInput, optFns ...func(*backup.Options)) (*backup.StartRestoreJobOutput, error)
}

// STSAPI is the subset of *sts.Client this app calls, narrowed to an
// interface for the same reason as RDSAPI.
type STSAPI interface {
	GetCallerIdentity(ctx context.Context, in *sts.GetCallerIdentityInput, optFns ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error)
}

// ClientSet is the guarded set of AWS clients for one (profile, region)
// pair. Every client in it was built with GuardMiddleware already
// attached; there is no code path that builds an RDS, Backup or STS client
// any other way. The fields are interfaces (satisfied automatically by
// *rds.Client, *backup.Client and *sts.Client) purely so action/inventory
// code can be unit-tested against a stub instead of a live AWS endpoint.
type ClientSet struct {
	RDS    RDSAPI
	Backup BackupAPI
	STS    STSAPI
	Config aws.Config
}

// Clients caches ClientSet by (profile, region) so repeated calls (list
// views polling, multiple databases in one account) reuse one AWS config
// and credential chain instead of re-resolving SSO/assume-role each time.
type Clients struct {
	mu    sync.Mutex
	cache map[string]*ClientSet
}

// NewClients returns an empty, ready-to-use client cache.
func NewClients() *Clients {
	return &Clients{cache: map[string]*ClientSet{}}
}

// Seed injects a pre-built ClientSet into the cache for a profile/region,
// bypassing real AWS config loading. It exists only so tests can substitute
// a stub ClientSet in front of action/inventory code that takes *Clients;
// production code never calls it.
func (c *Clients) Seed(profile, region string, cs *ClientSet) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cache[cacheKey(profile, region)] = cs
}

func cacheKey(profile, region string) string { return profile + "|" + region }

// For returns the guarded ClientSet for the given local AWS profile and
// region, loading and caching it on first use. profile must name a profile
// already configured in ~/.aws/config or ~/.aws/credentials; this app
// never stores or accepts raw credentials. readOnly must be the owning
// Account's ReadOnly flag: it is baked into the client's guard for the
// lifetime of the cache entry, so a read-only account's clients can never
// send a write call even if a bug elsewhere tries to. SaveAccount forgets
// any cached clients for a profile, so a settings change always rebuilds
// the client with the current flag.
func (c *Clients) For(ctx context.Context, profile, region string, readOnly bool) (*ClientSet, error) {
	if profile == "" {
		return nil, fmt.Errorf("aws profile is required")
	}
	if region == "" {
		return nil, fmt.Errorf("aws region is required")
	}

	key := cacheKey(profile, region)

	c.mu.Lock()
	if cs, ok := c.cache[key]; ok {
		c.mu.Unlock()
		return cs, nil
	}
	c.mu.Unlock()

	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithSharedConfigProfile(profile),
		config.WithRegion(region),
	)
	if err != nil {
		return nil, fmt.Errorf("load AWS config for profile %q: %w", profile, err)
	}

	// The guard is attached per-client, not via config.WithAPIOptions on
	// cfg: that would also wrap the SDK's own internal credential-refresh
	// calls (SSO GetRoleCredentials, STS AssumeRole for an assume-role
	// profile), which aren't RDS/Backup/STS application calls and must
	// never be blocked by this app-level allowlist.
	withGuard := func(o *middleware.Stack) error { return GuardMiddleware(readOnly)(o) }
	cs := &ClientSet{
		RDS:    rds.NewFromConfig(cfg, func(o *rds.Options) { o.APIOptions = append(o.APIOptions, withGuard) }),
		Backup: backup.NewFromConfig(cfg, func(o *backup.Options) { o.APIOptions = append(o.APIOptions, withGuard) }),
		STS:    sts.NewFromConfig(cfg, func(o *sts.Options) { o.APIOptions = append(o.APIOptions, withGuard) }),
		Config: cfg,
	}

	c.mu.Lock()
	c.cache[key] = cs
	c.mu.Unlock()
	return cs, nil
}

// Forget drops any cached clients for a profile across all regions. Call it
// after SsoLogin so the next call re-resolves credentials instead of
// reusing a pre-login config that may have cached an expired token source.
func (c *Clients) Forget(profile string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	prefix := profile + "|"
	for k := range c.cache {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			delete(c.cache, k)
		}
	}
}
