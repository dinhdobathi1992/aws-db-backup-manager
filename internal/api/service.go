// Package api defines the Service contract the Wails-bound App delegates
// to, and the safety guard every implementation must sit behind.
package api

import (
	"context"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// Service is the backend contract bound to the frontend through App. It is
// deliberately a closed set: there is no Delete*, Remove*, Terminate*, or
// Stop* method, and no implementation may add one. The no-delete invariant
// for the whole product starts here, at the contract.
type Service interface {
	// Accounts
	ListAccounts(ctx context.Context) ([]model.Account, error)
	SaveAccount(ctx context.Context, account model.Account) (model.Account, error)
	TestAccount(ctx context.Context, accountID string) (model.AccountStatus, error)
	SsoLogin(ctx context.Context, accountID string) (model.AccountStatus, error)

	// Inventory & backup read model
	ListDatabases(ctx context.Context, accountID string) ([]model.Database, error)
	GetBackupPlan(ctx context.Context, accountID string, dbIdentifier string) (model.BackupPlanSummary, error)
	ListSnapshots(ctx context.Context, accountID string, dbIdentifier string) ([]model.Snapshot, error)
	ListSchedules(ctx context.Context, accountID string) ([]model.Schedule, error)
	ListActivity(ctx context.Context, accountID string, limit int) ([]model.Activity, error)

	// Define backup
	CreateSnapshot(ctx context.Context, req model.CreateSnapshotReq) (model.Snapshot, error)
	StartBackupJob(ctx context.Context, req model.StartBackupJobReq) (model.Activity, error)
	CreateBackupPlan(ctx context.Context, req model.CreateBackupPlanReq) (model.BackupPlanSummary, error)
	ModifyAutomatedBackup(ctx context.Context, req model.ModifyAutomatedBackupReq) (model.Database, error)

	// Restore (always into a new identifier)
	Restore(ctx context.Context, req model.RestoreReq) (model.Activity, error)
}
