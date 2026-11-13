package inventory

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// formatTimePtr renders an AWS SDK *time.Time as an RFC3339 string pointer,
// or nil if the source is nil or the zero value AWS sometimes sends instead
// of omitting the field.
func formatTimePtr(t *time.Time) *string {
	if t == nil || t.IsZero() {
		return nil
	}
	s := t.Format(time.RFC3339)
	return &s
}

// formatTime renders an AWS SDK *time.Time as an RFC3339 string, or "" if
// the source is nil.
func formatTime(t *time.Time) string {
	if t == nil || t.IsZero() {
		return ""
	}
	return t.Format(time.RFC3339)
}

// tagMap converts the RDS SDK's tag list into the plain map the frozen
// model contract uses.
func tagMap(tags []rdstypes.Tag) map[string]string {
	if len(tags) == 0 {
		return nil
	}
	out := make(map[string]string, len(tags))
	for _, t := range tags {
		out[aws.ToString(t.Key)] = aws.ToString(t.Value)
	}
	return out
}

// resolveAccountNumber returns the 12-digit AWS account number behind an
// account's local profile, cached per account since it never changes across
// regions. It is used to build resource ARNs for AWS Backup calls that need
// one (ListRecoveryPointsByResource) without requiring the user to type
// their account number anywhere.
func resolveAccountNumber(ctx context.Context, clients *awsx.Clients, account model.Account, region string) (string, error) {
	key := "acctnum|" + account.ID
	return cached(defaultCache, key, func() (string, error) {
		cs, err := clients.For(ctx, account.Profile, region, account.ReadOnly)
		if err != nil {
			return "", err
		}
		out, err := cs.STS.GetCallerIdentity(ctx, nil)
		if err != nil {
			return "", fmt.Errorf("get caller identity: %w", err)
		}
		return aws.ToString(out.Account), nil
	})
}
