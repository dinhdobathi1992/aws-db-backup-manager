package inventory

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/backup"
	backuptypes "github.com/aws/aws-sdk-go-v2/service/backup/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/audit"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// activityWindow stays an hour under RDS's own 14-day DescribeEvents
// limit: a StartTime of exactly 14 days ago is rejected by AWS as "more
// than 14 days in the past" once request latency pushes the clock past it.
const activityWindow = 14*24*time.Hour - time.Hour

// ListActivity returns the most recent activity across every region in an
// account: RDS's own event history, AWS Backup job/restore history, and
// this app's local audit log of actions it started, merged and sorted
// newest first.
func ListActivity(ctx context.Context, clients *awsx.Clients, account model.Account, limit int) ([]model.Activity, error) {
	var all []model.Activity

	errs := fanOutRegions(ctx, account.Regions, func(ctx context.Context, region string) error {
		items, err := listActivityInRegion(ctx, clients, account, region)
		if err != nil {
			return err
		}
		all = append(all, items...)
		return nil
	})
	if len(errs) > 0 && len(all) == 0 {
		return nil, fmt.Errorf("list activity for account %s: %s", account.ID, joinErrs(errs))
	}

	if entries, err := audit.ReadAll(); err == nil {
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
				Message: fmt.Sprintf("%s %s: %s", e.Action, e.Target, e.Result),
			})
		}
	}

	sort.Slice(all, func(i, j int) bool { return all[i].Time > all[j].Time })
	if limit > 0 && len(all) > limit {
		all = all[:limit]
	}
	return all, nil
}

func listActivityInRegion(ctx context.Context, clients *awsx.Clients, account model.Account, region string) ([]model.Activity, error) {
	cs, err := clients.For(ctx, account.Profile, region, account.ReadOnly)
	if err != nil {
		return nil, err
	}

	start := time.Now().Add(-activityWindow)
	var out []model.Activity

	events, err := cs.RDS.DescribeEvents(ctx, &rds.DescribeEventsInput{
		StartTime:       aws.Time(start),
		EventCategories: []string{"backup", "restoration", "notification"},
	})
	if err != nil {
		return nil, fmt.Errorf("describe events in %s: %w", region, err)
	}
	for _, e := range events.Events {
		out = append(out, mapRDSEvent(e))
	}

	bp := backup.NewListBackupJobsPaginator(cs.Backup, &backup.ListBackupJobsInput{ByCreatedAfter: aws.Time(start)})
	for bp.HasMorePages() {
		page, err := bp.NextPage(ctx)
		if err != nil {
			break // AWS Backup may not be set up; don't fail the whole feed
		}
		for _, j := range page.BackupJobs {
			out = append(out, mapBackupJob(j))
		}
	}

	rp := backup.NewListRestoreJobsPaginator(cs.Backup, &backup.ListRestoreJobsInput{ByCreatedAfter: aws.Time(start)})
	for rp.HasMorePages() {
		page, err := rp.NextPage(ctx)
		if err != nil {
			break
		}
		for _, j := range page.RestoreJobs {
			out = append(out, mapRestoreJob(j))
		}
	}

	return out, nil
}

func mapRDSEvent(e rdstypes.Event) model.Activity {
	return model.Activity{
		Time:    formatTime(e.Date),
		Source:  model.ActivitySourceRDSEvent,
		DB:      aws.ToString(e.SourceIdentifier),
		Action:  string(e.SourceType),
		Status:  "",
		Message: aws.ToString(e.Message),
	}
}

func mapBackupJob(j backuptypes.BackupJob) model.Activity {
	return model.Activity{
		Time:    formatTime(j.CreationDate),
		Source:  model.ActivitySourceBackupJob,
		DB:      aws.ToString(j.ResourceName),
		Action:  "backup-job",
		Status:  string(j.State),
		Message: aws.ToString(j.StatusMessage),
	}
}

func mapRestoreJob(j backuptypes.RestoreJobsListMember) model.Activity {
	return model.Activity{
		Time:    formatTime(j.CreationDate),
		Source:  model.ActivitySourceRestoreJob,
		DB:      aws.ToString(j.CreatedResourceArn),
		Action:  "restore-job",
		Status:  string(j.Status),
		Message: aws.ToString(j.StatusMessage),
	}
}
