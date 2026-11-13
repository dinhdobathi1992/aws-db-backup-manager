package inventory

import (
	"context"
	"strings"
	"time"

	"github.com/robfig/cron/v3"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// ListSchedules returns every recurring backup schedule native to AWS for
// an account's databases: each database's automated backup window, and
// every AWS Backup rule covering it. The app never runs its own scheduler;
// this is a read-only projection of schedules AWS already owns.
func ListSchedules(ctx context.Context, clients *awsx.Clients, account model.Account) ([]model.Schedule, error) {
	dbs, err := ListDatabases(ctx, clients, account)
	if err != nil {
		return nil, err
	}

	now := time.Now()
	var out []model.Schedule
	for _, db := range dbs {
		if db.PreferredBackupWindow != "" {
			out = append(out, model.Schedule{
				Source:     model.ScheduleSourceAutomatedWindow,
				DB:         db.Identifier,
				Expression: db.PreferredBackupWindow,
				NextRun:    nextAutomatedWindowRun(db.PreferredBackupWindow, now),
				Retention:  db.BackupRetentionDays,
			})
		}

		coverage, err := listAWSBackupPlanCoverage(ctx, clients, account, db)
		if err != nil {
			continue
		}
		for _, c := range coverage {
			out = append(out, model.Schedule{
				Source:     model.ScheduleSourceAWSBackupRule,
				DB:         db.Identifier,
				Expression: c.Ref.Cron,
				NextRun:    parseAWSCronNextRun(c.Ref.Cron, now),
				Retention:  c.RetentionDays,
			})
		}
	}
	return out, nil
}

// nextAutomatedWindowRun computes the next UTC occurrence of an RDS
// preferred backup window's start time ("hh24:mi-hh24:mi").
func nextAutomatedWindowRun(window string, after time.Time) *string {
	parts := strings.SplitN(window, "-", 2)
	if len(parts) != 2 {
		return nil
	}
	start, err := time.Parse("15:04", parts[0])
	if err != nil {
		return nil
	}

	a := after.UTC()
	next := time.Date(a.Year(), a.Month(), a.Day(), start.Hour(), start.Minute(), 0, 0, time.UTC)
	if !next.After(a) {
		next = next.Add(24 * time.Hour)
	}
	s := next.Format(time.RFC3339)
	return &s
}

// parseAWSCronNextRun computes the next run of an AWS Backup rule's
// six-field cron expression (e.g. "cron(0 5 * * ? *)"). AWS cron always
// carries a trailing year field and uses "?" for "no specific value" in
// whichever of day-of-month/day-of-week is unused; both are normalized to
// "*" for the standard 5-field parser. A malformed expression returns nil
// rather than failing the whole schedules list.
func parseAWSCronNextRun(expr string, after time.Time) *string {
	fields, ok := normalizeAWSCron(expr)
	if !ok {
		return nil
	}
	sched, err := cron.ParseStandard(strings.Join(fields, " "))
	if err != nil {
		return nil
	}
	s := sched.Next(after).Format(time.RFC3339)
	return &s
}

func normalizeAWSCron(expr string) ([]string, bool) {
	expr = strings.TrimSpace(expr)
	expr = strings.TrimPrefix(expr, "cron(")
	expr = strings.TrimSuffix(expr, ")")
	fields := strings.Fields(expr)
	if len(fields) != 6 {
		return nil, false
	}
	minute, hour, dom, month, dow := fields[0], fields[1], fields[2], fields[3], fields[4]
	if dom == "?" {
		dom = "*"
	}
	if dow == "?" {
		dow = "*"
	}
	return []string{minute, hour, dom, month, dow}, true
}
