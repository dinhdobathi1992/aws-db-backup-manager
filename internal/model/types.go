// Package model defines the frozen Go<->TypeScript contract shared by the
// Wails backend and the React frontend. Every exported type here is
// generated into frontend/wailsjs; changing a field is a contract change
// that both Lin (backend) and Pixel (frontend) must agree on.
package model

// AccountState reports whether an account's local AWS credentials are usable.
type AccountState string

const (
	AccountStateOK      AccountState = "ok"
	AccountStateExpired AccountState = "expired"
	AccountStateError   AccountState = "error"
)

// DBKind distinguishes a standalone RDS instance from an Aurora/RDS cluster.
type DBKind string

const (
	DBKindInstance DBKind = "instance"
	DBKindCluster  DBKind = "cluster"
)

// SnapshotSource identifies how a snapshot or recovery point was produced.
type SnapshotSource string

const (
	SnapshotSourceManual    SnapshotSource = "manual"
	SnapshotSourceAutomated SnapshotSource = "automated"
	SnapshotSourceAWSBackup SnapshotSource = "aws-backup"
)

// ScheduleSource identifies where a recurring backup schedule is defined.
type ScheduleSource string

const (
	ScheduleSourceAutomatedWindow ScheduleSource = "automated-window"
	ScheduleSourceAWSBackupRule   ScheduleSource = "aws-backup-rule"
)

// ActivitySource identifies what produced an activity feed entry.
type ActivitySource string

const (
	ActivitySourceRDSEvent   ActivitySource = "rds-event"
	ActivitySourceBackupJob  ActivitySource = "backup-job"
	ActivitySourceRestoreJob ActivitySource = "restore-job"
	ActivitySourceApp        ActivitySource = "app"
)

// RestoreSource identifies what a restore is created from.
type RestoreSource string

const (
	RestoreSourceSnapshot      RestoreSource = "snapshot"
	RestoreSourcePITR          RestoreSource = "pitr"
	RestoreSourceRecoveryPoint RestoreSource = "recovery-point"
)

// Account is a user-configured AWS account/profile pairing. Credentials are
// never stored here or anywhere else in the app; Profile only names a local
// AWS CLI profile already configured on the user's Mac.
type Account struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Profile  string   `json:"profile"`
	Regions  []string `json:"regions"`
	Color    string   `json:"color"`
	ReadOnly bool     `json:"readOnly"`
}

// AccountStatus is the live result of testing an Account's local credentials.
type AccountStatus struct {
	AccountID    string       `json:"accountId"`
	ARN          string       `json:"arn"`
	AwsAccountID string       `json:"awsAccountId"`
	State        AccountState `json:"state"`
	Message      string       `json:"message"`
}

// Database is one RDS instance or Aurora/RDS cluster inventoried from an
// account/region.
type Database struct {
	AccountID             string            `json:"accountId"`
	Region                string            `json:"region"`
	Kind                  DBKind            `json:"kind"`
	Identifier            string            `json:"identifier"`
	Engine                string            `json:"engine"`
	EngineVersion         string            `json:"engineVersion"`
	Class                 string            `json:"class"`
	Status                string            `json:"status"`
	Endpoint              string            `json:"endpoint"`
	MultiAZ               bool              `json:"multiAz"`
	StorageGB             int64             `json:"storageGb"`
	Encrypted             bool              `json:"encrypted"`
	BackupRetentionDays   int               `json:"backupRetentionDays"`
	PreferredBackupWindow string            `json:"preferredBackupWindow"`
	LatestRestorableTime  *string           `json:"latestRestorableTime,omitempty"` // RFC3339, nil if unknown
	Tags                  map[string]string `json:"tags,omitempty"`
}

// Snapshot is a manual snapshot, an automated snapshot, or an AWS Backup
// recovery point for a given database.
type Snapshot struct {
	ID           string         `json:"id"`
	ARN          string         `json:"arn"`
	DBIdentifier string         `json:"dbIdentifier"`
	Kind         DBKind         `json:"kind"`
	Source       SnapshotSource `json:"source"`
	Status       string         `json:"status"`
	CreatedAt    string         `json:"createdAt"` // RFC3339
	SizeGB       int64          `json:"sizeGb"`
	Encrypted    bool           `json:"encrypted"`
	Engine       string         `json:"engine"`
	VaultName    string         `json:"vaultName,omitempty"`
}

// ManualBackupSummary summarizes manual snapshots for one database.
type ManualBackupSummary struct {
	Count  int     `json:"count"`
	Latest *string `json:"latest,omitempty"` // RFC3339
}

// AutomatedBackupSummary summarizes the automated/PITR backup state for one
// database.
type AutomatedBackupSummary struct {
	Retention int     `json:"retention"`
	Window    string  `json:"window"`
	Earliest  *string `json:"earliest,omitempty"` // RFC3339
	Latest    *string `json:"latest,omitempty"`   // RFC3339
}

// AWSBackupPlanRef summarizes one AWS Backup plan/rule covering a database.
type AWSBackupPlanRef struct {
	PlanID    string `json:"planId"`
	PlanName  string `json:"planName"`
	RuleName  string `json:"ruleName"`
	Cron      string `json:"cron"`
	Lifecycle string `json:"lifecycle"`
	Vault     string `json:"vault"`
}

// BackupPlanSummary is the backup-plan-grouped-by-database view: manual,
// automated and AWS Backup sources side by side for one database.
type BackupPlanSummary struct {
	DB        string                 `json:"db"`
	Manual    ManualBackupSummary    `json:"manual"`
	Automated AutomatedBackupSummary `json:"automated"`
	AwsBackup []AWSBackupPlanRef     `json:"awsBackup"`
}

// Schedule is one recurring backup schedule, native to AWS (an automated
// backup window or an AWS Backup rule's cron). The app never runs its own
// scheduler.
type Schedule struct {
	Source     ScheduleSource `json:"source"`
	DB         string         `json:"db"`
	Expression string         `json:"expression"`
	NextRun    *string        `json:"nextRun,omitempty"` // RFC3339
	Retention  int            `json:"retention"`
}

// Activity is one entry in the activity feed: an RDS event, a backup job, a
// restore job, or an app-originated action.
type Activity struct {
	Time    string         `json:"time"` // RFC3339
	Source  ActivitySource `json:"source"`
	DB      string         `json:"db"`
	Action  string         `json:"action"`
	Status  string         `json:"status"`
	Message string         `json:"message"`
}

// CreateSnapshotReq requests an on-demand manual snapshot of a database.
type CreateSnapshotReq struct {
	AccountID    string `json:"accountId"`
	Region       string `json:"region"`
	Kind         DBKind `json:"kind"`
	DBIdentifier string `json:"dbIdentifier"`
	SnapshotName string `json:"snapshotName"`
}

// StartBackupJobReq requests an on-demand AWS Backup job for a database.
type StartBackupJobReq struct {
	AccountID    string `json:"accountId"`
	Region       string `json:"region"`
	Kind         DBKind `json:"kind"`
	DBIdentifier string `json:"dbIdentifier"`
	VaultName    string `json:"vaultName"`
	IamRoleArn   string `json:"iamRoleArn"`
}

// CreateBackupPlanReq requests a new AWS Backup plan with one rule and one
// resource selection targeting a database.
type CreateBackupPlanReq struct {
	AccountID     string `json:"accountId"`
	Region        string `json:"region"`
	Kind          DBKind `json:"kind"`
	DBIdentifier  string `json:"dbIdentifier"`
	PlanName      string `json:"planName"`
	RuleName      string `json:"ruleName"`
	Cron          string `json:"cron"`
	VaultName     string `json:"vaultName"`
	RetentionDays int    `json:"retentionDays"`
	IamRoleArn    string `json:"iamRoleArn"`
}

// ModifyAutomatedBackupReq changes a database's automated backup window
// and/or raises its retention. Retention can never be lowered to 0; the
// safety guard enforces a minimum of 1 day (see internal/api guard).
type ModifyAutomatedBackupReq struct {
	AccountID     string `json:"accountId"`
	Region        string `json:"region"`
	Kind          DBKind `json:"kind"`
	DBIdentifier  string `json:"dbIdentifier"`
	Window        string `json:"window,omitempty"`
	RetentionDays int    `json:"retentionDays,omitempty"`
}

// RestoreReq requests a restore into a brand-new database identifier. A
// restore never targets an existing identifier; the safety guard rejects
// one that already exists.
type RestoreReq struct {
	AccountID          string        `json:"accountId"`
	Region             string        `json:"region"`
	Kind               DBKind        `json:"kind"`
	Source             RestoreSource `json:"source"`
	SourceDBIdentifier string        `json:"sourceDbIdentifier"`
	SnapshotID         string        `json:"snapshotId,omitempty"`
	RecoveryPointArn   string        `json:"recoveryPointArn,omitempty"`
	RestoreTime        *string       `json:"restoreTime,omitempty"` // RFC3339
	TargetIdentifier   string        `json:"targetIdentifier"`
	InstanceClass      string        `json:"instanceClass,omitempty"`
	SubnetGroup        string        `json:"subnetGroup,omitempty"`
	SecurityGroups     []string      `json:"securityGroups,omitempty"`
	PubliclyAccessible bool          `json:"publiclyAccessible"`
}
