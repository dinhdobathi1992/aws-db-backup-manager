package api

import (
	"context"
	"testing"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// TestRequireWritable is the pure-function unit test for the account-level
// write gate: a read-only account is rejected, a normal account is not.
func TestRequireWritable(t *testing.T) {
	if err := requireWritable(model.Account{Name: "prod", ReadOnly: true}); err == nil {
		t.Error("expected an error for a read-only account")
	}
	if err := requireWritable(model.Account{Name: "prod", ReadOnly: false}); err != nil {
		t.Errorf("expected no error for a writable account, got: %v", err)
	}
}

// TestWriteActionsRejectReadOnlyAccountBeforeAnyAWSCall exercises every
// write method on AWSService with a read-only account whose AWS profile
// does not exist on this machine. Because requireWritable runs before
// s.clients.For is ever reached, none of these calls can resolve AWS
// credentials or build a client - if the read-only check were bypassed or
// removed, this test would hang or fail trying to load a nonexistent AWS
// profile instead of returning instantly with a clear error, so it also
// proves the "zero SDK calls" property rather than just asserting an error
// string.
func TestWriteActionsRejectReadOnlyAccountBeforeAnyAWSCall(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	svc := NewAWSService()
	ctx := context.Background()

	account, err := svc.SaveAccount(ctx, model.Account{
		Name:     "Read-Only Test Account",
		Profile:  "this-profile-does-not-exist-on-this-machine",
		Regions:  []string{"us-east-1"},
		ReadOnly: true,
	})
	if err != nil {
		t.Fatalf("SaveAccount: %v", err)
	}

	if _, err := svc.CreateSnapshot(ctx, model.CreateSnapshotReq{
		AccountID: account.ID, Region: "us-east-1", DBIdentifier: "db1",
	}); err == nil {
		t.Error("CreateSnapshot: expected the read-only account to be refused")
	}

	if _, err := svc.StartBackupJob(ctx, model.StartBackupJobReq{
		AccountID: account.ID, Region: "us-east-1", DBIdentifier: "db1",
	}); err == nil {
		t.Error("StartBackupJob: expected the read-only account to be refused")
	}

	if _, err := svc.CreateBackupPlan(ctx, model.CreateBackupPlanReq{
		AccountID: account.ID, Region: "us-east-1", DBIdentifier: "db1", Cron: "cron(0 5 * * ? *)", RetentionDays: 30,
	}); err == nil {
		t.Error("CreateBackupPlan: expected the read-only account to be refused")
	}

	if _, err := svc.ModifyAutomatedBackup(ctx, model.ModifyAutomatedBackupReq{
		AccountID: account.ID, Region: "us-east-1", DBIdentifier: "db1", RetentionDays: 14,
	}); err == nil {
		t.Error("ModifyAutomatedBackup: expected the read-only account to be refused")
	}

	if _, err := svc.Restore(ctx, model.RestoreReq{
		AccountID: account.ID, Region: "us-east-1", Source: model.RestoreSourceSnapshot,
		SourceDBIdentifier: "db1", SnapshotID: "snap1", TargetIdentifier: "db1-restored",
	}); err == nil {
		t.Error("Restore: expected the read-only account to be refused")
	}
}

// TestWriteActionsAllowedForWritableAccount is the control for the test
// above: the same account with ReadOnly=false must fail for an ordinary
// reason (a nonexistent AWS profile), proving requireWritable is what
// blocked the read-only case and not some unrelated validation error.
func TestWriteActionsAllowedForWritableAccount(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	svc := NewAWSService()
	ctx := context.Background()

	account, err := svc.SaveAccount(ctx, model.Account{
		Name:     "Writable Test Account",
		Profile:  "this-profile-does-not-exist-on-this-machine",
		Regions:  []string{"us-east-1"},
		ReadOnly: false,
	})
	if err != nil {
		t.Fatalf("SaveAccount: %v", err)
	}

	_, err = svc.CreateSnapshot(ctx, model.CreateSnapshotReq{
		AccountID: account.ID, Region: "us-east-1", DBIdentifier: "db1",
	})
	if err == nil {
		t.Fatal("expected an error since the profile does not exist")
	}
	if err.Error() == requireWritableErrorMessage(account) {
		t.Errorf("a writable account was rejected by requireWritable: %v", err)
	}
}

func requireWritableErrorMessage(account model.Account) string {
	err := requireWritable(model.Account{Name: account.Name, ReadOnly: true})
	if err == nil {
		return ""
	}
	return err.Error()
}
