package actions

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	"github.com/aws/aws-sdk-go-v2/service/rds"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/inventory"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// Restore creates a brand-new database from a snapshot, a point in time, or
// an AWS Backup recovery point. It never targets an existing identifier:
// ValidateNewTarget is the one check every branch below shares, and it is
// the backstop against this becoming a restore-over-existing-DB path even
// if everything else about a request were wrong.
func Restore(ctx context.Context, clients *awsx.Clients, account model.Account, req model.RestoreReq) (model.Activity, error) {
	if req.TargetIdentifier == "" {
		return model.Activity{}, errors.New("targetIdentifier is required")
	}
	if req.SourceDBIdentifier == "" {
		return model.Activity{}, errors.New("sourceDbIdentifier is required")
	}

	cs, err := clients.For(ctx, account.Profile, req.Region, account.ReadOnly)
	if err != nil {
		return model.Activity{}, err
	}
	if err := ValidateNewTarget(ctx, cs, req.Kind, req.SourceDBIdentifier, req.TargetIdentifier); err != nil {
		return model.Activity{}, err
	}

	// Copying the source's networking is best-effort: a source that has
	// since been deleted just means the restore falls back to whatever
	// the snapshot/recovery point itself remembers, via AWS's own
	// defaults, rather than failing the whole restore.
	src, _ := lookupSourceConfig(ctx, cs, req.Kind, req.SourceDBIdentifier)
	subnetGroup, securityGroups, parameterGroup, instanceClass := resolvedNetworking(req, src)

	switch req.Source {
	case model.RestoreSourceSnapshot:
		return restoreFromSnapshot(ctx, cs, account, req, subnetGroup, securityGroups, parameterGroup, instanceClass, src.Engine)
	case model.RestoreSourcePITR:
		return restoreFromPITR(ctx, cs, account, req, subnetGroup, securityGroups, parameterGroup, instanceClass, src.Engine)
	case model.RestoreSourceRecoveryPoint:
		return restoreFromRecoveryPoint(ctx, clients, cs, account, req)
	default:
		return model.Activity{}, fmt.Errorf("unsupported restore source %q", req.Source)
	}
}

func restoreFromSnapshot(ctx context.Context, cs *awsx.ClientSet, account model.Account, req model.RestoreReq, subnetGroup string, securityGroups []string, parameterGroup, instanceClass, sourceEngine string) (model.Activity, error) {
	if req.SnapshotID == "" {
		return model.Activity{}, errors.New("snapshotId is required")
	}

	if req.Kind == model.DBKindCluster {
		snap, err := cs.RDS.DescribeDBClusterSnapshots(ctx, &rds.DescribeDBClusterSnapshotsInput{
			DBClusterSnapshotIdentifier: aws.String(req.SnapshotID),
		})
		if err != nil || len(snap.DBClusterSnapshots) == 0 {
			return model.Activity{}, fmt.Errorf("describe db cluster snapshot %q: %w", req.SnapshotID, err)
		}
		engine := aws.ToString(snap.DBClusterSnapshots[0].Engine)
		engineVersion := aws.ToString(snap.DBClusterSnapshots[0].EngineVersion)

		_, err = cs.RDS.RestoreDBClusterFromSnapshot(ctx, &rds.RestoreDBClusterFromSnapshotInput{
			DBClusterIdentifier:         aws.String(req.TargetIdentifier),
			Engine:                      aws.String(engine),
			EngineVersion:               optionalString(engineVersion),
			SnapshotIdentifier:          aws.String(req.SnapshotID),
			DBSubnetGroupName:           optionalString(subnetGroup),
			VpcSecurityGroupIds:         optionalSlice(securityGroups),
			DBClusterParameterGroupName: optionalString(parameterGroup),
			PubliclyAccessible:          aws.Bool(req.PubliclyAccessible),
		})
		if err != nil {
			return model.Activity{}, fmt.Errorf("restore db cluster from snapshot: %w", err)
		}
		recordAudit(account, req.TargetIdentifier, "RestoreDBClusterFromSnapshot", req.TargetIdentifier, "pending")

		if err := createClusterWriterInstance(ctx, cs, account, req.TargetIdentifier, engine, instanceClass); err != nil {
			return model.Activity{}, err
		}

		return model.Activity{
			Time:    nowRFC3339(),
			Source:  model.ActivitySourceApp,
			DB:      req.TargetIdentifier,
			Action:  "restore",
			Status:  "pending",
			Message: fmt.Sprintf("cluster %q restoring from snapshot %q", req.TargetIdentifier, req.SnapshotID),
		}, nil
	}

	_, err := cs.RDS.RestoreDBInstanceFromDBSnapshot(ctx, &rds.RestoreDBInstanceFromDBSnapshotInput{
		DBInstanceIdentifier: aws.String(req.TargetIdentifier),
		DBSnapshotIdentifier: aws.String(req.SnapshotID),
		DBInstanceClass:      optionalString(instanceClass),
		DBSubnetGroupName:    optionalString(subnetGroup),
		VpcSecurityGroupIds:  optionalSlice(securityGroups),
		DBParameterGroupName: optionalString(parameterGroup),
		PubliclyAccessible:   aws.Bool(req.PubliclyAccessible),
	})
	if err != nil {
		return model.Activity{}, fmt.Errorf("restore db instance from snapshot: %w", err)
	}
	recordAudit(account, req.TargetIdentifier, "RestoreDBInstanceFromDBSnapshot", req.TargetIdentifier, "pending")

	return model.Activity{
		Time:    nowRFC3339(),
		Source:  model.ActivitySourceApp,
		DB:      req.TargetIdentifier,
		Action:  "restore",
		Status:  "pending",
		Message: fmt.Sprintf("instance %q restoring from snapshot %q", req.TargetIdentifier, req.SnapshotID),
	}, nil
}

func restoreFromPITR(ctx context.Context, cs *awsx.ClientSet, account model.Account, req model.RestoreReq, subnetGroup string, securityGroups []string, parameterGroup, instanceClass, sourceEngine string) (model.Activity, error) {
	restoreTime, useLatest, err := parseRestoreTime(req.RestoreTime)
	if err != nil {
		return model.Activity{}, err
	}

	if req.Kind == model.DBKindCluster {
		_, err := cs.RDS.RestoreDBClusterToPointInTime(ctx, &rds.RestoreDBClusterToPointInTimeInput{
			DBClusterIdentifier:         aws.String(req.TargetIdentifier),
			SourceDBClusterIdentifier:   aws.String(req.SourceDBIdentifier),
			RestoreToTime:               restoreTime,
			UseLatestRestorableTime:     useLatest,
			DBSubnetGroupName:           optionalString(subnetGroup),
			VpcSecurityGroupIds:         optionalSlice(securityGroups),
			DBClusterParameterGroupName: optionalString(parameterGroup),
			PubliclyAccessible:          aws.Bool(req.PubliclyAccessible),
		})
		if err != nil {
			return model.Activity{}, fmt.Errorf("restore db cluster to point in time: %w", err)
		}
		recordAudit(account, req.TargetIdentifier, "RestoreDBClusterToPointInTime", req.TargetIdentifier, "pending")

		if sourceEngine == "" {
			return model.Activity{}, fmt.Errorf("could not determine engine for source cluster %q; it may no longer exist", req.SourceDBIdentifier)
		}
		if err := createClusterWriterInstance(ctx, cs, account, req.TargetIdentifier, sourceEngine, instanceClass); err != nil {
			return model.Activity{}, err
		}

		return model.Activity{
			Time:    nowRFC3339(),
			Source:  model.ActivitySourceApp,
			DB:      req.TargetIdentifier,
			Action:  "restore",
			Status:  "pending",
			Message: fmt.Sprintf("cluster %q restoring to a point in time from %q", req.TargetIdentifier, req.SourceDBIdentifier),
		}, nil
	}

	_, err = cs.RDS.RestoreDBInstanceToPointInTime(ctx, &rds.RestoreDBInstanceToPointInTimeInput{
		TargetDBInstanceIdentifier: aws.String(req.TargetIdentifier),
		SourceDBInstanceIdentifier: aws.String(req.SourceDBIdentifier),
		RestoreTime:                restoreTime,
		UseLatestRestorableTime:    useLatest,
		DBInstanceClass:            optionalString(instanceClass),
		DBSubnetGroupName:          optionalString(subnetGroup),
		VpcSecurityGroupIds:        optionalSlice(securityGroups),
		DBParameterGroupName:       optionalString(parameterGroup),
		PubliclyAccessible:         aws.Bool(req.PubliclyAccessible),
	})
	if err != nil {
		return model.Activity{}, fmt.Errorf("restore db instance to point in time: %w", err)
	}
	recordAudit(account, req.TargetIdentifier, "RestoreDBInstanceToPointInTime", req.TargetIdentifier, "pending")

	return model.Activity{
		Time:    nowRFC3339(),
		Source:  model.ActivitySourceApp,
		DB:      req.TargetIdentifier,
		Action:  "restore",
		Status:  "pending",
		Message: fmt.Sprintf("instance %q restoring to a point in time from %q", req.TargetIdentifier, req.SourceDBIdentifier),
	}, nil
}

// restoreFromRecoveryPoint restores an AWS Backup recovery point via
// StartRestoreJob. The restore metadata is seeded from
// GetRecoveryPointRestoreMetadata (which already carries the source
// resource's own networking/parameter-group configuration) and only the
// target identifier and any explicit overrides are changed, so an
// unrecognized metadata key simply falls back to the recovery point's own
// copied defaults instead of failing silently in a way that matters.
func restoreFromRecoveryPoint(ctx context.Context, clients *awsx.Clients, cs *awsx.ClientSet, account model.Account, req model.RestoreReq) (model.Activity, error) {
	if req.RecoveryPointArn == "" {
		return model.Activity{}, errors.New("recoveryPointArn is required")
	}

	snapshots, err := inventory.ListSnapshotsForDB(ctx, clients, account, req.Region, req.Kind, req.SourceDBIdentifier)
	if err != nil {
		return model.Activity{}, fmt.Errorf("list recovery points for %q: %w", req.SourceDBIdentifier, err)
	}
	var vaultName string
	for _, s := range snapshots {
		if s.ARN == req.RecoveryPointArn {
			vaultName = s.VaultName
			break
		}
	}
	if vaultName == "" {
		return model.Activity{}, fmt.Errorf("recovery point %q not found for database %q; cannot determine its backup vault", req.RecoveryPointArn, req.SourceDBIdentifier)
	}

	meta, err := cs.Backup.GetRecoveryPointRestoreMetadata(ctx, &backup.GetRecoveryPointRestoreMetadataInput{
		BackupVaultName:  aws.String(vaultName),
		RecoveryPointArn: aws.String(req.RecoveryPointArn),
	})
	if err != nil {
		return model.Activity{}, fmt.Errorf("get recovery point restore metadata: %w", err)
	}

	metadata := make(map[string]string, len(meta.RestoreMetadata)+4)
	for k, v := range meta.RestoreMetadata {
		metadata[k] = v
	}
	if req.Kind == model.DBKindCluster {
		metadata["DBClusterIdentifier"] = req.TargetIdentifier
	} else {
		metadata["DBInstanceIdentifier"] = req.TargetIdentifier
	}
	if req.SubnetGroup != "" {
		metadata["DBSubnetGroupName"] = req.SubnetGroup
	}
	if len(req.SecurityGroups) > 0 {
		metadata["VpcSecurityGroupIds"] = strings.Join(req.SecurityGroups, ",")
	}

	acctNum, err := resolveAccountNumber(ctx, cs)
	if err != nil {
		return model.Activity{}, err
	}

	out, err := cs.Backup.StartRestoreJob(ctx, &backup.StartRestoreJobInput{
		Metadata:         metadata,
		RecoveryPointArn: aws.String(req.RecoveryPointArn),
		IamRoleArn:       aws.String(defaultBackupRoleArn(acctNum)),
		ResourceType:     meta.ResourceType,
	})
	if err != nil {
		return model.Activity{}, fmt.Errorf("start restore job: %w", err)
	}

	recordAudit(account, req.RecoveryPointArn, "StartRestoreJob", req.TargetIdentifier, "pending")
	return model.Activity{
		Time:    nowRFC3339(),
		Source:  model.ActivitySourceRestoreJob,
		DB:      req.TargetIdentifier,
		Action:  "restore",
		Status:  "pending",
		Message: fmt.Sprintf("restore job %s started from recovery point %q", aws.ToString(out.RestoreJobId), req.RecoveryPointArn),
	}, nil
}

// createClusterWriterInstance creates the one DB instance every freshly
// restored Aurora cluster needs before it is usable (RestoreDBClusterFrom*
// only creates the cluster shell). It is the one CreateDBInstance call this
// app ever makes, and it only ever attaches to a cluster this same restore
// just created.
func createClusterWriterInstance(ctx context.Context, cs *awsx.ClientSet, account model.Account, clusterIdentifier, engine, instanceClass string) error {
	if instanceClass == "" {
		return fmt.Errorf("an instance class is required to create cluster %q's writer instance; the source cluster's class could not be determined", clusterIdentifier)
	}
	instanceID := writerInstanceIdentifier(clusterIdentifier)

	_, err := cs.RDS.CreateDBInstance(ctx, &rds.CreateDBInstanceInput{
		DBInstanceClass:      aws.String(instanceClass),
		DBInstanceIdentifier: aws.String(instanceID),
		Engine:               aws.String(engine),
		DBClusterIdentifier:  aws.String(clusterIdentifier),
	})
	if err != nil {
		return fmt.Errorf("create writer instance for cluster %q: %w", clusterIdentifier, err)
	}
	recordAudit(account, instanceID, "CreateDBInstance", clusterIdentifier, "pending")
	return nil
}

// writerInstanceIdentifier derives the writer instance's identifier from
// its cluster's, truncating the cluster identifier if the "-1" suffix would
// otherwise push it past RDS's 63-character limit.
func writerInstanceIdentifier(clusterIdentifier string) string {
	const suffix = "-1"
	base := clusterIdentifier
	if len(base)+len(suffix) > 63 {
		base = strings.TrimRight(base[:63-len(suffix)], "-")
	}
	return base + suffix
}

// parseRestoreTime interprets RestoreReq.RestoreTime: nil means "the latest
// restorable time", matching the model's own doc comment on RestoreReq.
func parseRestoreTime(restoreTime *string) (*time.Time, *bool, error) {
	if restoreTime == nil || *restoreTime == "" {
		return nil, aws.Bool(true), nil
	}
	t, err := time.Parse(time.RFC3339, *restoreTime)
	if err != nil {
		return nil, nil, fmt.Errorf("restoreTime %q is not RFC3339: %w", *restoreTime, err)
	}
	return &t, nil, nil
}

func optionalString(s string) *string {
	if s == "" {
		return nil
	}
	return aws.String(s)
}

func optionalSlice(s []string) []string {
	if len(s) == 0 {
		return nil
	}
	return s
}
