package inventory

import (
	"context"
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// ListSnapshotsForDB returns every manual/automated RDS snapshot and every
// AWS Backup recovery point for one database. RDS snapshots whose
// SnapshotType is "awsbackup" are skipped here: they are the same backup
// already reported as a recovery point below, just seen from the RDS side,
// and would otherwise be double-counted.
func ListSnapshotsForDB(ctx context.Context, clients *awsx.Clients, account model.Account, region string, kind model.DBKind, dbIdentifier string) ([]model.Snapshot, error) {
	key := "snapshots|" + account.ID + "|" + region + "|" + dbIdentifier
	return cached(defaultCache, key, func() ([]model.Snapshot, error) {
		return listSnapshotsUncached(ctx, clients, account, region, kind, dbIdentifier)
	})
}

// RefreshSnapshots forces the next ListSnapshotsForDB call for this
// database to bypass the cache and re-read AWS.
func RefreshSnapshots(account model.Account, region, dbIdentifier string) {
	defaultCache.invalidate("snapshots|" + account.ID + "|" + region + "|" + dbIdentifier)
}

func listSnapshotsUncached(ctx context.Context, clients *awsx.Clients, account model.Account, region string, kind model.DBKind, dbIdentifier string) ([]model.Snapshot, error) {
	cs, err := clients.For(ctx, account.Profile, region, account.ReadOnly)
	if err != nil {
		return nil, err
	}

	var out []model.Snapshot

	if kind == model.DBKindCluster {
		p := rds.NewDescribeDBClusterSnapshotsPaginator(cs.RDS, &rds.DescribeDBClusterSnapshotsInput{
			DBClusterIdentifier: aws.String(dbIdentifier),
		})
		for p.HasMorePages() {
			page, err := p.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("describe db cluster snapshots: %w", err)
			}
			for _, s := range page.DBClusterSnapshots {
				if snap := mapClusterSnapshot(s); snap != nil {
					out = append(out, *snap)
				}
			}
		}
	} else {
		p := rds.NewDescribeDBSnapshotsPaginator(cs.RDS, &rds.DescribeDBSnapshotsInput{
			DBInstanceIdentifier: aws.String(dbIdentifier),
		})
		for p.HasMorePages() {
			page, err := p.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("describe db snapshots: %w", err)
			}
			for _, s := range page.DBSnapshots {
				if snap := mapInstanceSnapshot(s); snap != nil {
					out = append(out, *snap)
				}
			}
		}
	}

	// AWS Backup recovery points. Best-effort: an account without AWS
	// Backup set up (or without permission to it) must not fail the whole
	// snapshot list, just omit this source.
	if acctNum, err := resolveAccountNumber(ctx, clients, account, region); err == nil && acctNum != "" {
		resourceArn := recoveryPointResourceArn(region, acctNum, kind, dbIdentifier)
		bp := backup.NewListRecoveryPointsByResourcePaginator(cs.Backup, &backup.ListRecoveryPointsByResourceInput{
			ResourceArn: aws.String(resourceArn),
		})
		for bp.HasMorePages() {
			page, err := bp.NextPage(ctx)
			if err != nil {
				break
			}
			for _, rp := range page.RecoveryPoints {
				out = append(out, mapRecoveryPoint(dbIdentifier, kind, rp))
			}
		}
	}

	return out, nil
}

// recoveryPointResourceArn builds the RDS resource ARN AWS Backup's
// ListRecoveryPointsByResource expects, from parts the app already has
// (region, account number, kind, identifier) rather than asking the user
// for an ARN.
func recoveryPointResourceArn(region, accountNumber string, kind model.DBKind, dbIdentifier string) string {
	resourceType := "db"
	if kind == model.DBKindCluster {
		resourceType = "cluster"
	}
	return fmt.Sprintf("arn:aws:rds:%s:%s:%s:%s", region, accountNumber, resourceType, dbIdentifier)
}

func mapInstanceSnapshot(s rdstypes.DBSnapshot) *model.Snapshot {
	source := snapshotSourceFromType(aws.ToString(s.SnapshotType))
	if source == "" {
		return nil
	}
	return &model.Snapshot{
		ID:           aws.ToString(s.DBSnapshotIdentifier),
		ARN:          aws.ToString(s.DBSnapshotArn),
		DBIdentifier: aws.ToString(s.DBInstanceIdentifier),
		Kind:         model.DBKindInstance,
		Source:       source,
		Status:       aws.ToString(s.Status),
		CreatedAt:    formatTime(s.SnapshotCreateTime),
		SizeGB:       int64(aws.ToInt32(s.AllocatedStorage)),
		Encrypted:    aws.ToBool(s.Encrypted),
		Engine:       aws.ToString(s.Engine),
	}
}

func mapClusterSnapshot(s rdstypes.DBClusterSnapshot) *model.Snapshot {
	source := snapshotSourceFromType(aws.ToString(s.SnapshotType))
	if source == "" {
		return nil
	}
	return &model.Snapshot{
		ID:           aws.ToString(s.DBClusterSnapshotIdentifier),
		ARN:          aws.ToString(s.DBClusterSnapshotArn),
		DBIdentifier: aws.ToString(s.DBClusterIdentifier),
		Kind:         model.DBKindCluster,
		Source:       source,
		Status:       aws.ToString(s.Status),
		CreatedAt:    formatTime(s.SnapshotCreateTime),
		SizeGB:       int64(aws.ToInt32(s.AllocatedStorage)),
		Encrypted:    aws.ToBool(s.StorageEncrypted),
		Engine:       aws.ToString(s.Engine),
	}
}

// snapshotSourceFromType maps RDS's SnapshotType to the model's source enum.
// "awsbackup"-typed RDS snapshots return "" on purpose: they are reported
// once, as a recovery point, not twice.
func snapshotSourceFromType(t string) model.SnapshotSource {
	switch strings.ToLower(t) {
	case "manual":
		return model.SnapshotSourceManual
	case "automated":
		return model.SnapshotSourceAutomated
	default:
		return ""
	}
}

func mapRecoveryPoint(dbIdentifier string, kind model.DBKind, rp backuptypes.RecoveryPointByResource) model.Snapshot {
	var sizeGB int64
	if rp.BackupSizeBytes != nil {
		sizeGB = *rp.BackupSizeBytes / (1024 * 1024 * 1024)
	}
	return model.Snapshot{
		ID:           aws.ToString(rp.RecoveryPointArn),
		ARN:          aws.ToString(rp.RecoveryPointArn),
		DBIdentifier: dbIdentifier,
		Kind:         kind,
		Source:       model.SnapshotSourceAWSBackup,
		Status:       string(rp.Status),
		CreatedAt:    formatTime(rp.CreationDate),
		SizeGB:       sizeGB,
		Encrypted:    rp.EncryptionKeyArn != nil,
		VaultName:    aws.ToString(rp.BackupVaultName),
	}
}
