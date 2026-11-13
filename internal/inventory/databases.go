package inventory

import (
	"context"
	"fmt"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// ListDatabases returns every RDS instance and Aurora/RDS cluster across
// all of an account's configured regions. An Aurora cluster's member
// instances are folded under one row for the cluster; they never appear as
// separate rows in the result.
func ListDatabases(ctx context.Context, clients *awsx.Clients, account model.Account) ([]model.Database, error) {
	key := "databases|" + account.ID
	return cached(defaultCache, key, func() ([]model.Database, error) {
		return listDatabasesUncached(ctx, clients, account)
	})
}

// RefreshDatabases forces the next ListDatabases call for this account to
// bypass the cache and re-read AWS.
func RefreshDatabases(account model.Account) {
	defaultCache.invalidate("databases|" + account.ID)
}

func listDatabasesUncached(ctx context.Context, clients *awsx.Clients, account model.Account) ([]model.Database, error) {
	var mu sync.Mutex
	var all []model.Database

	errs := fanOutRegions(ctx, account.Regions, func(ctx context.Context, region string) error {
		dbs, err := listDatabasesInRegion(ctx, clients, account, region)
		if err != nil {
			return err
		}
		mu.Lock()
		all = append(all, dbs...)
		mu.Unlock()
		return nil
	})

	if len(errs) > 0 && len(all) == 0 {
		return nil, fmt.Errorf("list databases for account %s: %s", account.ID, joinErrs(errs))
	}
	return all, nil
}

func listDatabasesInRegion(ctx context.Context, clients *awsx.Clients, account model.Account, region string) ([]model.Database, error) {
	cs, err := clients.For(ctx, account.Profile, region, account.ReadOnly)
	if err != nil {
		return nil, err
	}

	clusters := map[string]rdstypes.DBCluster{}
	cp := rds.NewDescribeDBClustersPaginator(cs.RDS, &rds.DescribeDBClustersInput{})
	for cp.HasMorePages() {
		page, err := cp.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("describe db clusters in %s: %w", region, err)
		}
		for _, c := range page.DBClusters {
			clusters[aws.ToString(c.DBClusterIdentifier)] = c
		}
	}

	// Members of an Aurora/Multi-AZ cluster are folded under their
	// cluster's row, never listed again as standalone instances.
	memberInstance := map[string]bool{}
	var out []model.Database
	for _, c := range clusters {
		out = append(out, mapCluster(account.ID, region, c))
		for _, m := range c.DBClusterMembers {
			memberInstance[aws.ToString(m.DBInstanceIdentifier)] = true
		}
	}

	ip := rds.NewDescribeDBInstancesPaginator(cs.RDS, &rds.DescribeDBInstancesInput{})
	for ip.HasMorePages() {
		page, err := ip.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("describe db instances in %s: %w", region, err)
		}
		for _, inst := range page.DBInstances {
			id := aws.ToString(inst.DBInstanceIdentifier)
			if memberInstance[id] {
				continue
			}
			out = append(out, mapInstance(account.ID, region, inst))
		}
	}
	return out, nil
}

func mapCluster(accountID, region string, c rdstypes.DBCluster) model.Database {
	return model.Database{
		AccountID:             accountID,
		Region:                region,
		Kind:                  model.DBKindCluster,
		Identifier:            aws.ToString(c.DBClusterIdentifier),
		Engine:                aws.ToString(c.Engine),
		EngineVersion:         aws.ToString(c.EngineVersion),
		Class:                 aws.ToString(c.DBClusterInstanceClass),
		Status:                aws.ToString(c.Status),
		Endpoint:              aws.ToString(c.Endpoint),
		MultiAZ:               aws.ToBool(c.MultiAZ),
		StorageGB:             int64(aws.ToInt32(c.AllocatedStorage)),
		Encrypted:             aws.ToBool(c.StorageEncrypted),
		BackupRetentionDays:   int(aws.ToInt32(c.BackupRetentionPeriod)),
		PreferredBackupWindow: aws.ToString(c.PreferredBackupWindow),
		LatestRestorableTime:  formatTimePtr(c.LatestRestorableTime),
		Tags:                  tagMap(c.TagList),
	}
}

func mapInstance(accountID, region string, inst rdstypes.DBInstance) model.Database {
	endpoint := ""
	if inst.Endpoint != nil {
		endpoint = aws.ToString(inst.Endpoint.Address)
	}
	return model.Database{
		AccountID:             accountID,
		Region:                region,
		Kind:                  model.DBKindInstance,
		Identifier:            aws.ToString(inst.DBInstanceIdentifier),
		Engine:                aws.ToString(inst.Engine),
		EngineVersion:         aws.ToString(inst.EngineVersion),
		Class:                 aws.ToString(inst.DBInstanceClass),
		Status:                aws.ToString(inst.DBInstanceStatus),
		Endpoint:              endpoint,
		MultiAZ:               aws.ToBool(inst.MultiAZ),
		StorageGB:             int64(aws.ToInt32(inst.AllocatedStorage)),
		Encrypted:             aws.ToBool(inst.StorageEncrypted),
		BackupRetentionDays:   int(aws.ToInt32(inst.BackupRetentionPeriod)),
		PreferredBackupWindow: aws.ToString(inst.PreferredBackupWindow),
		LatestRestorableTime:  formatTimePtr(inst.LatestRestorableTime),
		Tags:                  tagMap(inst.TagList),
	}
}
