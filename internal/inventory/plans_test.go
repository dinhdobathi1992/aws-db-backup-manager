package inventory

import (
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
)

const testDBArn = "arn:aws:rds:ap-southeast-1:111122223333:db:prod-reporting-pg"

func TestBackupSelectionCoversExactResourceArn(t *testing.T) {
	sel := backuptypes.BackupSelection{Resources: []string{testDBArn}}
	if !backupSelectionCovers(sel, testDBArn, nil) {
		t.Error("expected exact ARN match to cover the database")
	}
	if backupSelectionCovers(sel, "arn:aws:rds:ap-southeast-1:111122223333:db:other-db", nil) {
		t.Error("expected a different ARN not to match")
	}
}

func TestBackupSelectionCoversWildcard(t *testing.T) {
	sel := backuptypes.BackupSelection{Resources: []string{"*"}}
	if !backupSelectionCovers(sel, testDBArn, nil) {
		t.Error("expected \"*\" to cover every resource")
	}
}

func TestBackupSelectionCoversTrailingWildcardPrefix(t *testing.T) {
	sel := backuptypes.BackupSelection{
		Resources: []string{"arn:aws:rds:ap-southeast-1:111122223333:db:prod-*"},
	}
	if !backupSelectionCovers(sel, testDBArn, nil) {
		t.Error("expected trailing-* prefix to match")
	}
	if backupSelectionCovers(sel, "arn:aws:rds:ap-southeast-1:111122223333:db:staging-reporting-pg", nil) {
		t.Error("expected trailing-* prefix not to match a different prefix")
	}
}

func TestBackupSelectionNotResourcesExcludesEvenOnPositiveMatch(t *testing.T) {
	sel := backuptypes.BackupSelection{
		Resources:    []string{"*"},
		NotResources: []string{testDBArn},
	}
	if backupSelectionCovers(sel, testDBArn, nil) {
		t.Error("expected NotResources to exclude a database even though Resources matches everything")
	}
}

func TestBackupSelectionListOfTagsMatch(t *testing.T) {
	sel := backuptypes.BackupSelection{
		ListOfTags: []backuptypes.Condition{
			{ConditionKey: aws.String("aws:ResourceTag/env"), ConditionValue: aws.String("prod")},
		},
	}
	if !backupSelectionCovers(sel, testDBArn, map[string]string{"env": "prod"}) {
		t.Error("expected ListOfTags condition on env=prod to match")
	}
	if backupSelectionCovers(sel, testDBArn, map[string]string{"env": "staging"}) {
		t.Error("expected ListOfTags condition on env=prod not to match env=staging")
	}
}

func TestBackupSelectionConditionsStringEqualsExactOnly(t *testing.T) {
	sel := backuptypes.BackupSelection{
		Conditions: &backuptypes.Conditions{
			StringEquals: []backuptypes.ConditionParameter{
				{ConditionKey: aws.String("aws:ResourceTag/env"), ConditionValue: aws.String("prod")},
			},
		},
	}
	if !backupSelectionCovers(sel, testDBArn, map[string]string{"env": "prod"}) {
		t.Error("expected StringEquals exact match to cover")
	}
	if backupSelectionCovers(sel, testDBArn, map[string]string{"env": "production"}) {
		t.Error("StringEquals must not glob-match \"production\" against \"prod\"")
	}
}

func TestBackupSelectionConditionsStringLikeWildcard(t *testing.T) {
	sel := backuptypes.BackupSelection{
		Conditions: &backuptypes.Conditions{
			StringLike: []backuptypes.ConditionParameter{
				{ConditionKey: aws.String("aws:ResourceTag/env"), ConditionValue: aws.String("prod*")},
			},
		},
	}
	if !backupSelectionCovers(sel, testDBArn, map[string]string{"env": "production"}) {
		t.Error("expected StringLike \"prod*\" to match \"production\"")
	}
	if backupSelectionCovers(sel, testDBArn, map[string]string{"env": "staging"}) {
		t.Error("expected StringLike \"prod*\" not to match \"staging\"")
	}
}

func TestBackupSelectionStringNotEqualsIsNotStandaloneMatch(t *testing.T) {
	// A selection that only carries StringNotEquals must not be treated as
	// a positive match on its own -- AWS Backup uses it only to narrow an
	// otherwise-positive Resources/StringEquals/StringLike match.
	sel := backuptypes.BackupSelection{
		Conditions: &backuptypes.Conditions{
			StringNotEquals: []backuptypes.ConditionParameter{
				{ConditionKey: aws.String("aws:ResourceTag/env"), ConditionValue: aws.String("staging")},
			},
		},
	}
	if backupSelectionCovers(sel, testDBArn, map[string]string{"env": "prod"}) {
		t.Error("expected a selection with only StringNotEquals not to match on its own")
	}
}

func TestMatchWildcard(t *testing.T) {
	cases := []struct {
		value, pattern string
		want           bool
	}{
		{"production", "prod*", true},
		{"staging", "prod*", false},
		{"prod", "prod", true},
		{"prod", "prod*", true},
		{"my-prod-db", "*prod*", true},
		{"my-staging-db", "*prod*", false},
	}
	for _, c := range cases {
		if got := matchWildcard(c.value, c.pattern); got != c.want {
			t.Errorf("matchWildcard(%q, %q) = %v, want %v", c.value, c.pattern, got, c.want)
		}
	}
}

func TestLifecycleTextAndRetentionDays(t *testing.T) {
	if got := lifecycleText(nil); got != "" {
		t.Errorf("lifecycleText(nil) = %q, want empty", got)
	}
	if got := lifecycleRetentionDays(nil); got != 0 {
		t.Errorf("lifecycleRetentionDays(nil) = %d, want 0", got)
	}

	l := &backuptypes.Lifecycle{DeleteAfterDays: aws.Int64(35)}
	if got := lifecycleText(l); got != "35 day(s)" {
		t.Errorf("lifecycleText = %q, want \"35 day(s)\"", got)
	}
	if got := lifecycleRetentionDays(l); got != 35 {
		t.Errorf("lifecycleRetentionDays = %d, want 35", got)
	}
}
