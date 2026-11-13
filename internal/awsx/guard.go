// Package awsx is the only place AWS SDK clients are constructed in this
// app. Every client carries the safety guard in this file: an allowlist of
// (service, operation) pairs enforced as a smithy Initialize middleware, so
// no call outside it can leave the process, however it is reached in the
// code above this package.
package awsx

import (
	"context"
	"fmt"
	"reflect"
	"regexp"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	"github.com/aws/smithy-go/middleware"
)

// ErrOperationForbidden is returned when an AWS API call outside the
// allowlist, or violating a parameter guard, is attempted.
type ErrOperationForbidden struct {
	Service   string
	Operation string
	Reason    string
}

func (e *ErrOperationForbidden) Error() string {
	if e.Reason != "" {
		return fmt.Sprintf("blocked op=%s service=%s: %s", e.Operation, e.Service, e.Reason)
	}
	return fmt.Sprintf("blocked op=%s service=%s: not on the safety allowlist", e.Operation, e.Service)
}

// minBackupPlanRetentionDays is the floor for an AWS Backup rule's
// DeleteAfterDays: a plan cannot be used to make recovery points vanish
// almost immediately.
const minBackupPlanRetentionDays = 7

// allowlist holds every (service ID, operation name) pair this app may ever
// call. Anything not listed here is rejected before it is signed or sent.
// This is deliberately an allowlist, not a denylist: a new AWS SDK
// operation is blocked by default until someone adds it here on purpose.
var allowlist = map[string]map[string]bool{
	"RDS": {
		// Read-only.
		"DescribeDBInstances":                  true,
		"DescribeDBClusters":                   true,
		"DescribeDBSnapshots":                  true,
		"DescribeDBClusterSnapshots":           true,
		"DescribeDBSnapshotAttributes":         true,
		"DescribeDBClusterSnapshotAttributes":  true,
		"DescribeEvents":                       true,
		"DescribeEventSubscriptions":           true,
		"DescribeDBInstanceAutomatedBackups":   true,
		"DescribeDBSubnetGroups":               true,
		"DescribeDBParameterGroups":            true,
		"DescribeDBClusterParameterGroups":     true,
		"DescribeOrderableDBInstanceOptions":   true,
		"DescribeDBEngineVersions":             true,
		"DescribeAccountAttributes":            true,
		"DescribeValidDBInstanceModifications": true,
		"DescribePendingMaintenanceActions":    true,
		"ListTagsForResource":                  true,
		// Creates a new resource; never touches an existing one.
		"CreateDBSnapshot":        true,
		"CreateDBClusterSnapshot": true,
		// Restore always targets a brand-new identifier; internal/actions
		// verifies that before any of these are called.
		"RestoreDBInstanceFromDBSnapshot": true,
		"RestoreDBClusterFromSnapshot":    true,
		"RestoreDBInstanceToPointInTime":  true,
		"RestoreDBClusterToPointInTime":   true,
		"CreateDBInstance":                true, // Aurora cluster restore's writer instance only.
		// Backup-settings-only modify; parameter-guarded below.
		"ModifyDBInstance":  true,
		"ModifyDBCluster":   true,
		"AddTagsToResource": true,
	},
	"Backup": {
		"ListBackupPlans":                 true,
		"ListBackupSelections":            true,
		"ListBackupJobs":                  true,
		"ListRestoreJobs":                 true,
		"ListRecoveryPointsByResource":    true,
		"ListBackupVaults":                true,
		"ListTags":                        true,
		"GetBackupPlan":                   true,
		"GetBackupSelection":              true,
		"GetRecoveryPointRestoreMetadata": true,
		"GetBackupVaultAccessPolicy":      true,
		"GetBackupVaultNotifications":     true,
		"DescribeBackupJob":               true,
		"DescribeRestoreJob":              true,
		"DescribeRecoveryPoint":           true,
		"DescribeBackupVault":             true,
		"StartBackupJob":                  true,
		"StartRestoreJob":                 true,
		"CreateBackupPlan":                true,
		"CreateBackupSelection":           true,
	},
	"STS": {
		"GetCallerIdentity": true,
	},
}

// forbiddenPattern is a second, independent line of defense: it names the
// exact shape of every destructive operation the app must never call,
// regardless of the allowlist above. internal/awsx/static_test.go asserts
// that no source file ever references one of these identifiers, and this
// pattern asserts it again at runtime.
var forbiddenPattern = regexp.MustCompile(
	`^(Delete|Remove|Stop|Reboot|Failover|Terminate)` +
		`|^(UpdateBackupPlan|PutBackupVaultAccessPolicy|PutBackupVaultLockConfiguration|ModifyDBSnapshotAttribute|ModifyDBClusterSnapshotAttribute)$`,
)

// readOnlyPattern matches every operation a read-only account's clients may
// still call: List/Describe/Get reads, plus sts:GetCallerIdentity (which
// also starts with "Get"). Everything else - any create, modify, restore or
// backup-job call - is blocked for a read-only account regardless of the
// allowlist above.
var readOnlyPattern = regexp.MustCompile(`^(List|Describe|Get)`)

// GuardMiddleware returns the smithy Initialize middleware that enforces
// the allowlist and parameter guards. internal/awsx/clients.go attaches it
// to every AWS client the app constructs; there is no other way to build a
// client in this codebase. readOnly additionally restricts the client to
// List/Describe/Get calls only, independent of the allowlist: it is the
// defence-in-depth backstop for an account marked read-only in Settings, in
// case a bug above this package ever tries to send a write for one anyway.
func GuardMiddleware(readOnly bool) func(stack *middleware.Stack) error {
	return func(stack *middleware.Stack) error {
		return stack.Initialize.Add(
			middleware.InitializeMiddlewareFunc("SafetyGuard", func(
				ctx context.Context, in middleware.InitializeInput, next middleware.InitializeHandler,
			) (middleware.InitializeOutput, middleware.Metadata, error) {
				service := middleware.GetServiceID(ctx)
				operation := middleware.GetOperationName(ctx)

				if forbiddenPattern.MatchString(operation) {
					return middleware.InitializeOutput{}, middleware.Metadata{}, &ErrOperationForbidden{Service: service, Operation: operation, Reason: "matches a destructive operation pattern"}
				}
				if !allowlist[service][operation] {
					return middleware.InitializeOutput{}, middleware.Metadata{}, &ErrOperationForbidden{Service: service, Operation: operation}
				}
				if readOnly && !readOnlyPattern.MatchString(operation) {
					return middleware.InitializeOutput{}, middleware.Metadata{}, &ErrOperationForbidden{Service: service, Operation: operation, Reason: "account is configured as read-only; only List/Describe/Get calls are allowed"}
				}
				if err := checkParameters(operation, in.Parameters); err != nil {
					return middleware.InitializeOutput{}, middleware.Metadata{}, err
				}

				return next.HandleInitialize(ctx, in)
			}),
			middleware.Before,
		)
	}
}

// checkParameters applies the Phase 2 parameter guards to the small set of
// allowed mutating calls whose inputs could otherwise be abused to reduce
// or remove backup coverage.
func checkParameters(operation string, params interface{}) error {
	switch operation {
	case "ModifyDBInstance":
		return checkModifyParams(operation, params, "DBInstanceIdentifier")
	case "ModifyDBCluster":
		return checkModifyParams(operation, params, "DBClusterIdentifier")
	case "CreateBackupPlan":
		return checkBackupPlanLifecycle(params)
	default:
		return nil
	}
}

// modifyAllowedFields are the only fields ModifyDBInstance/ModifyDBCluster
// may set, besides the resource identifier and ApplyImmediately: backup
// window and retention. Any other non-zero field (storage class changes,
// engine version, deletion protection, master password, etc.) is rejected,
// so this call can only ever be used to change backup settings.
var modifyAllowedFields = map[string]bool{
	"ApplyImmediately":      true,
	"BackupRetentionPeriod": true,
	"PreferredBackupWindow": true,
}

func checkModifyParams(operation string, params interface{}, identifierField string) error {
	v := reflect.ValueOf(params)
	if v.Kind() == reflect.Ptr {
		v = v.Elem()
	}
	if !v.IsValid() || v.Kind() != reflect.Struct {
		return &ErrOperationForbidden{Operation: operation, Reason: "unexpected parameter type"}
	}

	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		name := t.Field(i).Name
		if name == identifierField || modifyAllowedFields[name] {
			continue
		}
		fv := v.Field(i)
		if fv.CanInterface() && !fv.IsZero() {
			return &ErrOperationForbidden{
				Operation: operation,
				Reason:    fmt.Sprintf("field %q is not allowed on a backup-settings-only modify call", name),
			}
		}
	}

	if bp := v.FieldByName("BackupRetentionPeriod"); bp.IsValid() && !bp.IsNil() {
		if days := bp.Elem().Int(); days < 1 {
			return &ErrOperationForbidden{
				Operation: operation,
				Reason:    "BackupRetentionPeriod must be at least 1 day; automated backups can never be disabled",
			}
		}
	}
	return nil
}

func checkBackupPlanLifecycle(params interface{}) error {
	input, ok := params.(*backup.CreateBackupPlanInput)
	if !ok || input.BackupPlan == nil {
		return nil
	}
	for _, rule := range input.BackupPlan.Rules {
		if rule.Lifecycle == nil || rule.Lifecycle.DeleteAfterDays == nil {
			continue
		}
		if *rule.Lifecycle.DeleteAfterDays < minBackupPlanRetentionDays {
			return &ErrOperationForbidden{
				Operation: "CreateBackupPlan",
				Reason: fmt.Sprintf(
					"rule %q keeps recovery points for only %d day(s); the minimum is %d",
					aws.ToString(rule.RuleName), *rule.Lifecycle.DeleteAfterDays, minBackupPlanRetentionDays,
				),
			}
		}
	}
	return nil
}
