package inventory

import (
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

func TestSnapshotSourceFromType(t *testing.T) {
	cases := map[string]model.SnapshotSource{
		"manual":    model.SnapshotSourceManual,
		"Manual":    model.SnapshotSourceManual,
		"automated": model.SnapshotSourceAutomated,
		"awsbackup": "",
		"shared":    "",
		"":          "",
	}
	for in, want := range cases {
		if got := snapshotSourceFromType(in); got != want {
			t.Errorf("snapshotSourceFromType(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMapInstanceSnapshotSkipsAWSBackupType(t *testing.T) {
	// An "awsbackup"-typed RDS snapshot is the same recovery point this
	// app already reports via ListRecoveryPointsByResource; mapping it a
	// second time here would double-count it, so mapInstanceSnapshot must
	// return nil for it.
	s := rdstypes.DBSnapshot{
		DBSnapshotIdentifier: aws.String("awsbackup:job-1234"),
		SnapshotType:         aws.String("awsbackup"),
	}
	if got := mapInstanceSnapshot(s); got != nil {
		t.Errorf("mapInstanceSnapshot(awsbackup) = %+v, want nil", got)
	}
}

func TestMapInstanceSnapshotKeepsManualAndAutomated(t *testing.T) {
	manual := rdstypes.DBSnapshot{
		DBSnapshotIdentifier: aws.String("manual-snap-1"),
		DBInstanceIdentifier: aws.String("prod-reporting-pg"),
		SnapshotType:         aws.String("manual"),
		Status:               aws.String("available"),
		AllocatedStorage:     aws.Int32(500),
		Encrypted:            aws.Bool(true),
		Engine:               aws.String("postgres"),
	}
	got := mapInstanceSnapshot(manual)
	if got == nil {
		t.Fatal("mapInstanceSnapshot(manual) = nil, want a snapshot")
	}
	if got.Source != model.SnapshotSourceManual {
		t.Errorf("source = %q, want manual", got.Source)
	}
	if got.SizeGB != 500 {
		t.Errorf("sizeGb = %d, want 500", got.SizeGB)
	}

	automated := rdstypes.DBSnapshot{
		DBSnapshotIdentifier: aws.String("rds:prod-reporting-pg-2026-11-13"),
		SnapshotType:         aws.String("automated"),
	}
	got = mapInstanceSnapshot(automated)
	if got == nil || got.Source != model.SnapshotSourceAutomated {
		t.Errorf("mapInstanceSnapshot(automated) = %+v, want source automated", got)
	}
}

func TestMapClusterSnapshotSkipsAWSBackupType(t *testing.T) {
	s := rdstypes.DBClusterSnapshot{
		DBClusterSnapshotIdentifier: aws.String("awsbackup:job-5678"),
		SnapshotType:                aws.String("awsbackup"),
	}
	if got := mapClusterSnapshot(s); got != nil {
		t.Errorf("mapClusterSnapshot(awsbackup) = %+v, want nil", got)
	}
}

func TestMapRecoveryPointSizeConversion(t *testing.T) {
	rp := backuptypes.RecoveryPointByResource{
		RecoveryPointArn: aws.String("arn:aws:backup:us-east-1:111111111111:recovery-point:abc"),
		BackupSizeBytes:  aws.Int64(3 * 1024 * 1024 * 1024),
		Status:           backuptypes.RecoveryPointStatusCompleted,
		BackupVaultName:  aws.String("default"),
	}
	got := mapRecoveryPoint("prod-orders-cluster", model.DBKindCluster, rp)
	if got.Source != model.SnapshotSourceAWSBackup {
		t.Errorf("source = %q, want aws-backup", got.Source)
	}
	if got.SizeGB != 3 {
		t.Errorf("sizeGb = %d, want 3", got.SizeGB)
	}
	if got.VaultName != "default" {
		t.Errorf("vaultName = %q, want default", got.VaultName)
	}
}

func TestRecoveryPointResourceArn(t *testing.T) {
	instArn := recoveryPointResourceArn("ap-southeast-1", "111122223333", model.DBKindInstance, "prod-reporting-pg")
	if instArn != "arn:aws:rds:ap-southeast-1:111122223333:db:prod-reporting-pg" {
		t.Errorf("instance arn = %q", instArn)
	}
	clusterArn := recoveryPointResourceArn("ap-southeast-1", "111122223333", model.DBKindCluster, "prod-orders-cluster")
	if clusterArn != "arn:aws:rds:ap-southeast-1:111122223333:cluster:prod-orders-cluster" {
		t.Errorf("cluster arn = %q", clusterArn)
	}
}
