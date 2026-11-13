package api

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/google/uuid"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/actions"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/audit"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/inventory"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/settings"
)

// AWSService is the real Service implementation, backed by the local Mac's
// configured AWS CLI profiles. It never stores or accepts raw credentials:
// every AWS call goes through internal/awsx, which resolves credentials
// from the named profile and attaches the no-delete safety guard.
type AWSService struct {
	clients *awsx.Clients
}

// NewAWSService creates the real, AWS-backed Service.
func NewAWSService() *AWSService {
	return &AWSService{clients: awsx.NewClients()}
}

var _ Service = (*AWSService)(nil)

func (s *AWSService) account(accountID string) (model.Account, error) {
	cfg, err := settings.Load()
	if err != nil {
		return model.Account{}, err
	}
	for _, a := range cfg.Accounts {
		if a.ID == accountID {
			return a, nil
		}
	}
	return model.Account{}, fmt.Errorf("account %q not found", accountID)
}

// findDatabase resolves a database's region and kind, since several
// Service methods are keyed only on accountID+dbIdentifier.
func (s *AWSService) findDatabase(ctx context.Context, account model.Account, dbIdentifier string) (model.Database, error) {
	dbs, err := inventory.ListDatabases(ctx, s.clients, account)
	if err != nil {
		return model.Database{}, err
	}
	for _, db := range dbs {
		if db.Identifier == dbIdentifier {
			return db, nil
		}
	}
	return model.Database{}, fmt.Errorf("database %q not found in account %q", dbIdentifier, account.ID)
}

func primaryRegion(account model.Account) string {
	if len(account.Regions) == 0 {
		return ""
	}
	return account.Regions[0]
}

// Accounts

func (s *AWSService) ListAccounts(ctx context.Context) ([]model.Account, error) {
	cfg, err := settings.Load()
	if err != nil {
		return nil, err
	}
	return cfg.Accounts, nil
}

func (s *AWSService) SaveAccount(ctx context.Context, account model.Account) (model.Account, error) {
	cfg, err := settings.Load()
	if err != nil {
		return model.Account{}, err
	}
	if account.ID == "" {
		account.ID = "acct-" + uuid.NewString()
	}

	found := false
	for i, a := range cfg.Accounts {
		if a.ID == account.ID {
			cfg.Accounts[i] = account
			found = true
			break
		}
	}
	if !found {
		cfg.Accounts = append(cfg.Accounts, account)
	}

	if err := settings.Save(cfg); err != nil {
		return model.Account{}, err
	}
	// Drop any cached clients for this profile: the profile or regions may
	// have changed, and a stale cached client would keep using the old one.
	s.clients.Forget(account.Profile)
	return account, nil
}

func (s *AWSService) TestAccount(ctx context.Context, accountID string) (model.AccountStatus, error) {
	account, err := s.account(accountID)
	if err != nil {
		return model.AccountStatus{}, err
	}
	return s.testAccount(ctx, account)
}

func (s *AWSService) testAccount(ctx context.Context, account model.Account) (model.AccountStatus, error) {
	region := primaryRegion(account)
	if region == "" {
		return model.AccountStatus{AccountID: account.ID, State: model.AccountStateError, Message: "no region configured"}, nil
	}

	cs, err := s.clients.For(ctx, account.Profile, region, account.ReadOnly)
	if err != nil {
		return model.AccountStatus{AccountID: account.ID, State: model.AccountStateError, Message: err.Error()}, nil
	}

	out, err := cs.STS.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		state := model.AccountStateError
		if strings.Contains(strings.ToLower(err.Error()), "expired") {
			state = model.AccountStateExpired
		}
		return model.AccountStatus{AccountID: account.ID, State: state, Message: err.Error()}, nil
	}

	return model.AccountStatus{
		AccountID:    account.ID,
		ARN:          aws.ToString(out.Arn),
		AwsAccountID: aws.ToString(out.Account),
		State:        model.AccountStateOK,
		Message:      "ok",
	}, nil
}

func (s *AWSService) SsoLogin(ctx context.Context, accountID string) (model.AccountStatus, error) {
	account, err := s.account(accountID)
	if err != nil {
		return model.AccountStatus{}, err
	}
	if err := awsx.SsoLogin(ctx, account.Profile); err != nil {
		return model.AccountStatus{AccountID: account.ID, State: model.AccountStateError, Message: err.Error()}, nil
	}
	// The SSO login just refreshed the token source; forget any client
	// built before it so the next call picks up the new credentials.
	s.clients.Forget(account.Profile)
	return s.testAccount(ctx, account)
}

// Inventory & backup read model

func (s *AWSService) ListDatabases(ctx context.Context, accountID string) ([]model.Database, error) {
	account, err := s.account(accountID)
	if err != nil {
		return nil, err
	}
	return inventory.ListDatabases(ctx, s.clients, account)
}

func (s *AWSService) GetBackupPlan(ctx context.Context, accountID string, dbIdentifier string) (model.BackupPlanSummary, error) {
	account, err := s.account(accountID)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}
	db, err := s.findDatabase(ctx, account, dbIdentifier)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}
	return inventory.GetBackupPlanForDB(ctx, s.clients, account, db)
}

func (s *AWSService) ListSnapshots(ctx context.Context, accountID string, dbIdentifier string) ([]model.Snapshot, error) {
	account, err := s.account(accountID)
	if err != nil {
		return nil, err
	}
	db, err := s.findDatabase(ctx, account, dbIdentifier)
	if err != nil {
		return nil, err
	}
	return inventory.ListSnapshotsForDB(ctx, s.clients, account, db.Region, db.Kind, dbIdentifier)
}

func (s *AWSService) ListSchedules(ctx context.Context, accountID string) ([]model.Schedule, error) {
	account, err := s.account(accountID)
	if err != nil {
		return nil, err
	}
	return inventory.ListSchedules(ctx, s.clients, account)
}

func (s *AWSService) ListActivity(ctx context.Context, accountID string, limit int) ([]model.Activity, error) {
	account, err := s.account(accountID)
	if err != nil {
		return nil, err
	}

	awsActivity, err := inventory.ListActivity(ctx, s.clients, account, limit)
	if err != nil {
		return nil, err
	}

	entries, err := audit.ReadAll()
	if err != nil {
		return nil, err
	}
	all := append([]model.Activity{}, awsActivity...)
	for _, e := range entries {
		if e.Account != account.ID {
			continue
		}
		all = append(all, model.Activity{
			Time:    e.Time,
			Source:  model.ActivitySourceApp,
			DB:      e.Target,
			Action:  e.Action,
			Status:  e.Result,
			Message: fmt.Sprintf("%s %s", e.Action, e.Result),
		})
	}

	sort.Slice(all, func(i, j int) bool { return all[i].Time > all[j].Time })
	if limit > 0 && len(all) > limit {
		all = all[:limit]
	}
	return all, nil
}

// requireWritable rejects a write action on a read-only account before any
// AWS client is built: the account-level ReadOnly flag is the first line of
// defense (zero SDK calls for a blocked request), with the per-client guard
// in internal/awsx as the independent backstop if this check is ever
// bypassed or skipped by a future caller.
func requireWritable(account model.Account) error {
	if account.ReadOnly {
		return fmt.Errorf("account %q is read-only; write actions are disabled", account.Name)
	}
	return nil
}

// Define backup

func (s *AWSService) CreateSnapshot(ctx context.Context, req model.CreateSnapshotReq) (model.Snapshot, error) {
	account, err := s.account(req.AccountID)
	if err != nil {
		return model.Snapshot{}, err
	}
	if err := requireWritable(account); err != nil {
		return model.Snapshot{}, err
	}
	snap, err := actions.CreateSnapshot(ctx, s.clients, account, req)
	if err != nil {
		return model.Snapshot{}, err
	}
	inventory.RefreshSnapshots(account, req.Region, req.DBIdentifier)
	return snap, nil
}

func (s *AWSService) StartBackupJob(ctx context.Context, req model.StartBackupJobReq) (model.Activity, error) {
	account, err := s.account(req.AccountID)
	if err != nil {
		return model.Activity{}, err
	}
	if err := requireWritable(account); err != nil {
		return model.Activity{}, err
	}
	activity, err := actions.StartBackupJob(ctx, s.clients, account, req)
	if err != nil {
		return model.Activity{}, err
	}
	inventory.RefreshSnapshots(account, req.Region, req.DBIdentifier)
	return activity, nil
}

func (s *AWSService) CreateBackupPlan(ctx context.Context, req model.CreateBackupPlanReq) (model.BackupPlanSummary, error) {
	account, err := s.account(req.AccountID)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}
	if err := requireWritable(account); err != nil {
		return model.BackupPlanSummary{}, err
	}
	plan, err := actions.CreateBackupPlan(ctx, s.clients, account, req)
	if err != nil {
		return model.BackupPlanSummary{}, err
	}
	inventory.RefreshSnapshots(account, req.Region, req.DBIdentifier)
	return plan, nil
}

func (s *AWSService) ModifyAutomatedBackup(ctx context.Context, req model.ModifyAutomatedBackupReq) (model.Database, error) {
	account, err := s.account(req.AccountID)
	if err != nil {
		return model.Database{}, err
	}
	if err := requireWritable(account); err != nil {
		return model.Database{}, err
	}
	db, err := actions.ModifyAutomatedBackup(ctx, s.clients, account, req)
	if err != nil {
		return model.Database{}, err
	}
	inventory.RefreshDatabases(account)
	return db, nil
}

// Restore (always into a new identifier)

func (s *AWSService) Restore(ctx context.Context, req model.RestoreReq) (model.Activity, error) {
	account, err := s.account(req.AccountID)
	if err != nil {
		return model.Activity{}, err
	}
	if err := requireWritable(account); err != nil {
		return model.Activity{}, err
	}
	activity, err := actions.Restore(ctx, s.clients, account, req)
	if err != nil {
		return model.Activity{}, err
	}
	inventory.RefreshDatabases(account)
	return activity, nil
}
