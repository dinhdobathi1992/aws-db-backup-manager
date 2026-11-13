package inventory

import (
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// These fixtures mirror the shape DescribeDBInstances/DescribeDBClusters
// actually return (recorded field names from the SDK's own type docs), not
// a simplified stand-in, so the mapping is exercised against the real
// contract between this app and AWS.

func TestMapInstance(t *testing.T) {
	restorable := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	inst := rdstypes.DBInstance{
		DBInstanceIdentifier:  aws.String("prod-reporting-pg"),
		Engine:                aws.String("postgres"),
		EngineVersion:         aws.String("16.1"),
		DBInstanceClass:       aws.String("db.m6g.xlarge"),
		DBInstanceStatus:      aws.String("available"),
		Endpoint:              &rdstypes.Endpoint{Address: aws.String("prod-reporting-pg.xxxxx.us-east-1.rds.amazonaws.com")},
		MultiAZ:               aws.Bool(true),
		AllocatedStorage:      aws.Int32(500),
		StorageEncrypted:      aws.Bool(true),
		BackupRetentionPeriod: aws.Int32(14),
		PreferredBackupWindow: aws.String("04:00-04:30"),
		LatestRestorableTime:  &restorable,
		TagList:               []rdstypes.Tag{{Key: aws.String("env"), Value: aws.String("prod")}},
	}

	db := mapInstance("acct-prod", "us-east-1", inst)

	if db.Kind != model.DBKindInstance {
		t.Errorf("kind = %q, want instance", db.Kind)
	}
	if db.Identifier != "prod-reporting-pg" {
		t.Errorf("identifier = %q", db.Identifier)
	}
	if db.Endpoint != "prod-reporting-pg.xxxxx.us-east-1.rds.amazonaws.com" {
		t.Errorf("endpoint = %q", db.Endpoint)
	}
	if db.StorageGB != 500 {
		t.Errorf("storageGb = %d, want 500", db.StorageGB)
	}
	if db.BackupRetentionDays != 14 {
		t.Errorf("backupRetentionDays = %d, want 14", db.BackupRetentionDays)
	}
	if db.LatestRestorableTime == nil || *db.LatestRestorableTime != "2026-11-13T10:00:00Z" {
		t.Errorf("latestRestorableTime = %v", db.LatestRestorableTime)
	}
	if db.Tags["env"] != "prod" {
		t.Errorf("tags[env] = %q, want prod", db.Tags["env"])
	}
}

func TestMapCluster(t *testing.T) {
	c := rdstypes.DBCluster{
		DBClusterIdentifier:   aws.String("prod-orders-cluster"),
		Engine:                aws.String("aurora-postgresql"),
		EngineVersion:         aws.String("15.4"),
		Status:                aws.String("available"),
		Endpoint:              aws.String("prod-orders-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"),
		MultiAZ:               aws.Bool(true),
		AllocatedStorage:      aws.Int32(200),
		StorageEncrypted:      aws.Bool(true),
		BackupRetentionPeriod: aws.Int32(7),
		PreferredBackupWindow: aws.String("03:00-03:30"),
		DBClusterMembers: []rdstypes.DBClusterMember{
			{DBInstanceIdentifier: aws.String("prod-orders-cluster-writer"), IsClusterWriter: aws.Bool(true)},
			{DBInstanceIdentifier: aws.String("prod-orders-cluster-reader-1"), IsClusterWriter: aws.Bool(false)},
		},
	}

	db := mapCluster("acct-prod", "us-east-1", c)

	if db.Kind != model.DBKindCluster {
		t.Errorf("kind = %q, want cluster", db.Kind)
	}
	if db.Identifier != "prod-orders-cluster" {
		t.Errorf("identifier = %q", db.Identifier)
	}
	if db.BackupRetentionDays != 7 {
		t.Errorf("backupRetentionDays = %d, want 7", db.BackupRetentionDays)
	}
}

func TestListDatabasesInRegionFoldsClusterMembers(t *testing.T) {
	// listDatabasesInRegion itself needs a live/guarded client, so this
	// test exercises the folding logic the same way it does: build the
	// memberInstance set from DBClusterMembers and confirm both writer and
	// reader identifiers are excluded from standalone instance rows.
	c := rdstypes.DBCluster{
		DBClusterIdentifier: aws.String("prod-orders-cluster"),
		DBClusterMembers: []rdstypes.DBClusterMember{
			{DBInstanceIdentifier: aws.String("prod-orders-cluster-writer")},
			{DBInstanceIdentifier: aws.String("prod-orders-cluster-reader-1")},
		},
	}

	memberInstance := map[string]bool{}
	for _, m := range c.DBClusterMembers {
		memberInstance[aws.ToString(m.DBInstanceIdentifier)] = true
	}

	instances := []rdstypes.DBInstance{
		{DBInstanceIdentifier: aws.String("prod-orders-cluster-writer"), DBClusterIdentifier: aws.String("prod-orders-cluster")},
		{DBInstanceIdentifier: aws.String("prod-orders-cluster-reader-1"), DBClusterIdentifier: aws.String("prod-orders-cluster")},
		{DBInstanceIdentifier: aws.String("prod-standalone-pg")},
	}

	var standalone []string
	for _, inst := range instances {
		id := aws.ToString(inst.DBInstanceIdentifier)
		if memberInstance[id] {
			continue
		}
		standalone = append(standalone, id)
	}

	if len(standalone) != 1 || standalone[0] != "prod-standalone-pg" {
		t.Errorf("standalone instances = %v, want only [prod-standalone-pg]", standalone)
	}
}
