package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/api"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// runCLI implements the ADBM_CLI=1 verification hook from the Phase 3
// plan: a headless, read-only entry point for checking inventory output
// against the AWS CLI's own output, without launching the GUI.
// save-account exists only to register an account for this headless
// verification without the GUI; it never touches AWS, only local settings.
//
// Usage:
//
//	ADBM_CLI=1 go run . list-accounts
//	ADBM_CLI=1 go run . save-account --name <name> --profile <profile> --regions <r1,r2> [--readonly]
//	ADBM_CLI=1 go run . list-databases --account <id>
//	ADBM_CLI=1 go run . get-backup-plan --account <id> --db <identifier>
//	ADBM_CLI=1 go run . list-snapshots --account <id> --db <identifier>
//	ADBM_CLI=1 go run . list-schedules --account <id>
//	ADBM_CLI=1 go run . list-activity --account <id> [--limit N]
//	ADBM_CLI=1 go run . create-snapshot --account <id> --db <identifier>
func runCLI(service api.Service) {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: list-accounts | save-account | list-databases | get-backup-plan | list-snapshots | list-schedules | list-activity | create-snapshot")
		os.Exit(2)
	}

	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	accountID := fs.String("account", "", "account id, as shown by list-accounts")
	name := fs.String("name", "", "account display name")
	profile := fs.String("profile", "", "local AWS CLI profile name")
	regions := fs.String("regions", "", "comma-separated AWS regions")
	readOnly := fs.Bool("readonly", false, "mark the account read-only: write actions are refused before any AWS call")
	db := fs.String("db", "", "database identifier")
	limit := fs.Int("limit", 50, "max activity entries")
	_ = fs.Parse(os.Args[2:])

	ctx := context.Background()
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")

	switch cmd {
	case "save-account":
		if *name == "" || *profile == "" || *regions == "" {
			fmt.Fprintln(os.Stderr, "--name, --profile and --regions are required")
			os.Exit(2)
		}
		account, err := service.SaveAccount(ctx, model.Account{
			Name:     *name,
			Profile:  *profile,
			Regions:  strings.Split(*regions, ","),
			ReadOnly: *readOnly,
		})
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(account)

	case "list-accounts":
		accounts, err := service.ListAccounts(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(accounts)

	case "list-databases":
		if *accountID == "" {
			fmt.Fprintln(os.Stderr, "--account is required")
			os.Exit(2)
		}
		dbs, err := service.ListDatabases(ctx, *accountID)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(dbs)
		fmt.Fprintf(os.Stderr, "count: %d\n", len(dbs))

	case "get-backup-plan":
		if *accountID == "" || *db == "" {
			fmt.Fprintln(os.Stderr, "--account and --db are required")
			os.Exit(2)
		}
		plan, err := service.GetBackupPlan(ctx, *accountID, *db)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(plan)

	case "list-snapshots":
		if *accountID == "" || *db == "" {
			fmt.Fprintln(os.Stderr, "--account and --db are required")
			os.Exit(2)
		}
		snaps, err := service.ListSnapshots(ctx, *accountID, *db)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(snaps)
		fmt.Fprintf(os.Stderr, "count: %d\n", len(snaps))

	case "list-schedules":
		if *accountID == "" {
			fmt.Fprintln(os.Stderr, "--account is required")
			os.Exit(2)
		}
		schedules, err := service.ListSchedules(ctx, *accountID)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(schedules)
		fmt.Fprintf(os.Stderr, "count: %d\n", len(schedules))

	case "list-activity":
		if *accountID == "" {
			fmt.Fprintln(os.Stderr, "--account is required")
			os.Exit(2)
		}
		activity, err := service.ListActivity(ctx, *accountID, *limit)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(activity)
		fmt.Fprintf(os.Stderr, "count: %d\n", len(activity))

	case "create-snapshot":
		if *accountID == "" || *db == "" {
			fmt.Fprintln(os.Stderr, "--account and --db are required")
			os.Exit(2)
		}
		snap, err := service.CreateSnapshot(ctx, model.CreateSnapshotReq{AccountID: *accountID, DBIdentifier: *db})
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		_ = enc.Encode(snap)

	default:
		fmt.Fprintln(os.Stderr, "unknown command:", cmd)
		os.Exit(2)
	}
}
