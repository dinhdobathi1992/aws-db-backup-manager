package awsx

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// iamPrefix maps the smithy service ID the guard keys on to the IAM action
// prefix used in docs/iam-policy.json.
var iamPrefix = map[string]string{"RDS": "rds", "Backup": "backup", "STS": "sts"}

type policyDoc struct {
	Statement []struct {
		Sid         string
		Effect      string
		Action      stringOrList
		NotAction   json.RawMessage
		Resource    stringOrList
		NotResource json.RawMessage
		Condition   json.RawMessage
	}
}

type stringOrList []string

func (s *stringOrList) UnmarshalJSON(b []byte) error {
	var one string
	if err := json.Unmarshal(b, &one); err == nil {
		*s = []string{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		return err
	}
	*s = many
	return nil
}

func loadPolicy(t *testing.T) policyDoc {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "docs", "iam-policy.json"))
	if err != nil {
		t.Fatalf("read docs/iam-policy.json: %v", err)
	}
	var p policyDoc
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatalf("parse docs/iam-policy.json: %v", err)
	}
	return p
}

// TestPolicyMatchesAllowlist keeps the published IAM policy and the runtime
// guard in lockstep: the AppGuardAllowlist* statements must grant exactly
// the guard's (service, operation) pairs, no more and no fewer.
func TestPolicyMatchesAllowlist(t *testing.T) {
	want := map[string]bool{}
	for svc, ops := range allowlist {
		prefix, ok := iamPrefix[svc]
		if !ok {
			t.Fatalf("guard service %q has no IAM prefix mapping; add it to iamPrefix and the policy", svc)
		}
		for op, allowed := range ops {
			if allowed {
				want[prefix+":"+op] = true
			}
		}
	}

	got := map[string]bool{}
	for _, st := range loadPolicy(t).Statement {
		if st.Effect != "Allow" || !strings.HasPrefix(st.Sid, "AppGuardAllowlist") {
			continue
		}
		for _, a := range st.Action {
			if strings.Contains(a, "*") {
				t.Errorf("allowlist statement %s uses a wildcard action %q", st.Sid, a)
			}
			got[a] = true
		}
	}

	var missing, extra []string
	for a := range want {
		if !got[a] {
			missing = append(missing, a)
		}
	}
	for a := range got {
		if !want[a] {
			extra = append(extra, a)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	if len(missing) > 0 {
		t.Errorf("policy lacks guard-allowed actions: %v", missing)
	}
	if len(extra) > 0 {
		t.Errorf("policy grants actions the guard does not allow: %v", extra)
	}
}

// TestPolicyOtherAllowsAreDependenciesOnly pins the only Allow statements
// outside the allowlist mirror: PassRole for AWS Backup and KMS grants for
// encrypted restores. Any new one has to be added here on purpose.
func TestPolicyOtherAllowsAreDependenciesOnly(t *testing.T) {
	permitted := map[string]bool{"iam:PassRole": true, "kms:CreateGrant": true, "kms:DescribeKey": true}
	for _, st := range loadPolicy(t).Statement {
		if st.Effect != "Allow" || strings.HasPrefix(st.Sid, "AppGuardAllowlist") {
			continue
		}
		for _, a := range st.Action {
			if !permitted[a] {
				t.Errorf("statement %s allows unexpected action %q", st.Sid, a)
			}
		}
	}
}

// TestPolicyDenyCoversForbiddenPatternAndNeverHitsAllowlist checks the
// explicit Deny: it must cover every destructive verb the guard forbids,
// and must not accidentally deny anything the app legitimately calls.
func TestPolicyDenyCoversForbiddenPatternAndNeverHitsAllowlist(t *testing.T) {
	var deny []string
	for _, st := range loadPolicy(t).Statement {
		if st.Effect == "Deny" {
			deny = append(deny, st.Action...)
		}
	}
	if len(deny) == 0 {
		t.Fatal("policy has no explicit Deny statement")
	}

	matches := func(pattern, action string) bool {
		// IAM action matching is case-insensitive.
		re := "(?i)^" + strings.ReplaceAll(regexp.QuoteMeta(pattern), `\*`, ".*") + "$"
		return regexp.MustCompile(re).MatchString(action)
	}
	denied := func(action string) bool {
		for _, d := range deny {
			if matches(d, action) {
				return true
			}
		}
		return false
	}

	for svc, ops := range allowlist {
		for op := range ops {
			if a := iamPrefix[svc] + ":" + op; denied(a) {
				t.Errorf("explicit Deny blocks guard-allowed action %s", a)
			}
		}
	}

	mustDeny := []string{
		"rds:DeleteDBInstance", "rds:DeleteDBCluster", "rds:DeleteDBSnapshot", "rds:DeleteDBClusterSnapshot",
		"rds:DeleteDBInstanceAutomatedBackup", "rds:DeleteDBClusterAutomatedBackup",
		"rds:StopDBInstance", "rds:StopDBCluster", "rds:RebootDBInstance", "rds:RebootDBCluster",
		"rds:FailoverDBCluster", "rds:FailoverGlobalCluster", "rds:RemoveFromGlobalCluster",
		"rds:ModifyDBSnapshotAttribute", "rds:ModifyDBClusterSnapshotAttribute",
		"backup:DeleteRecoveryPoint", "backup:DeleteBackupVault", "backup:DeleteBackupPlan", "backup:DeleteBackupSelection",
		"backup:DeleteBackupVaultLockConfiguration", "backup:StopBackupJob", "backup:DisassociateRecoveryPoint",
		"backup:UpdateBackupPlan", "backup:UpdateRecoveryPointLifecycle", "backup:StartCopyJob",
		"rds:BacktrackDBCluster", "rds:StartExportTask",
		"backup:PutBackupVaultAccessPolicy", "backup:PutBackupVaultLockConfiguration",
	}
	for _, a := range mustDeny {
		if !denied(a) {
			t.Errorf("explicit Deny does not cover destructive action %s", a)
		}
	}
}

// TestPolicyStatementShape rules out the constructs that would let a
// policy pass the action-set checks above while meaning something else:
// NotAction/NotResource anywhere, or a Deny narrowed by Resource or
// switched off by a Condition.
func TestPolicyStatementShape(t *testing.T) {
	for _, st := range loadPolicy(t).Statement {
		if len(st.NotAction) > 0 || len(st.NotResource) > 0 {
			t.Errorf("statement %q uses NotAction/NotResource", st.Sid)
		}
		if st.Effect == "Deny" {
			if len(st.Condition) > 0 {
				t.Errorf("Deny statement %q has a Condition; the destructive Deny must be unconditional", st.Sid)
			}
			if len(st.Resource) != 1 || st.Resource[0] != "*" {
				t.Errorf("Deny statement %q must apply to Resource \"*\", got %v", st.Sid, st.Resource)
			}
		}
	}
}
