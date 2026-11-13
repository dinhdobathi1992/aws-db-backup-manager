package main

import (
	"context"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/api"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// App is the Wails-bound frontend entry point. It holds no business logic
// of its own; every method delegates 1:1 to a api.Service so the same
// contract works against fixtures (dev) and real AWS (Phase 2+).
type App struct {
	ctx     context.Context
	service api.Service
}

// NewApp creates a new App bound to the given Service implementation.
func NewApp(service api.Service) *App {
	return &App{service: service}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
}

// Accounts

func (a *App) ListAccounts() ([]model.Account, error) {
	return a.service.ListAccounts(a.ctx)
}

func (a *App) SaveAccount(account model.Account) (model.Account, error) {
	return a.service.SaveAccount(a.ctx, account)
}

func (a *App) TestAccount(accountID string) (model.AccountStatus, error) {
	return a.service.TestAccount(a.ctx, accountID)
}

func (a *App) SsoLogin(accountID string) (model.AccountStatus, error) {
	return a.service.SsoLogin(a.ctx, accountID)
}

// Inventory & backup read model

func (a *App) ListDatabases(accountID string) ([]model.Database, error) {
	return a.service.ListDatabases(a.ctx, accountID)
}

func (a *App) GetBackupPlan(accountID string, dbIdentifier string) (model.BackupPlanSummary, error) {
	return a.service.GetBackupPlan(a.ctx, accountID, dbIdentifier)
}

func (a *App) ListSnapshots(accountID string, dbIdentifier string) ([]model.Snapshot, error) {
	return a.service.ListSnapshots(a.ctx, accountID, dbIdentifier)
}

func (a *App) ListSchedules(accountID string) ([]model.Schedule, error) {
	return a.service.ListSchedules(a.ctx, accountID)
}

func (a *App) ListActivity(accountID string, limit int) ([]model.Activity, error) {
	return a.service.ListActivity(a.ctx, accountID, limit)
}

// Define backup

func (a *App) CreateSnapshot(req model.CreateSnapshotReq) (model.Snapshot, error) {
	return a.service.CreateSnapshot(a.ctx, req)
}

func (a *App) StartBackupJob(req model.StartBackupJobReq) (model.Activity, error) {
	return a.service.StartBackupJob(a.ctx, req)
}

func (a *App) CreateBackupPlan(req model.CreateBackupPlanReq) (model.BackupPlanSummary, error) {
	return a.service.CreateBackupPlan(a.ctx, req)
}

func (a *App) ModifyAutomatedBackup(req model.ModifyAutomatedBackupReq) (model.Database, error) {
	return a.service.ModifyAutomatedBackup(a.ctx, req)
}

// Restore

func (a *App) Restore(req model.RestoreReq) (model.Activity, error) {
	return a.service.Restore(a.ctx, req)
}
