package inventory

import (
	"testing"
	"time"
)

func TestNextAutomatedWindowRunRollsToNextDay(t *testing.T) {
	after := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC) // 10:00 UTC
	got := nextAutomatedWindowRun("04:00-04:30", after)
	if got == nil {
		t.Fatal("got nil, want a next-run time")
	}
	want := "2026-11-14T04:00:00Z" // window already passed today, rolls to tomorrow
	if *got != want {
		t.Errorf("next run = %s, want %s", *got, want)
	}
}

func TestNextAutomatedWindowRunSameDayWhenUpcoming(t *testing.T) {
	after := time.Date(2026, 11, 13, 1, 0, 0, 0, time.UTC) // 01:00 UTC
	got := nextAutomatedWindowRun("04:00-04:30", after)
	if got == nil {
		t.Fatal("got nil, want a next-run time")
	}
	want := "2026-11-13T04:00:00Z"
	if *got != want {
		t.Errorf("next run = %s, want %s", *got, want)
	}
}

func TestNextAutomatedWindowRunMalformed(t *testing.T) {
	if got := nextAutomatedWindowRun("not-a-window", time.Now()); got != nil {
		t.Errorf("got %v, want nil for a malformed window", got)
	}
}

func TestNormalizeAWSCronDropsYearAndQuestionMarks(t *testing.T) {
	fields, ok := normalizeAWSCron("cron(0 5 * * ? *)")
	if !ok {
		t.Fatal("normalizeAWSCron returned ok=false")
	}
	want := []string{"0", "5", "*", "*", "*"}
	for i, w := range want {
		if fields[i] != w {
			t.Errorf("fields[%d] = %q, want %q (full: %v)", i, fields[i], w, fields)
		}
	}
}

func TestNormalizeAWSCronDayOfMonthVariant(t *testing.T) {
	fields, ok := normalizeAWSCron("cron(15 3 1 * ? *)")
	if !ok {
		t.Fatal("normalizeAWSCron returned ok=false")
	}
	if fields[2] != "1" || fields[4] != "*" {
		t.Errorf("fields = %v, want dom=1 dow=*", fields)
	}
}

func TestNormalizeAWSCronRejectsWrongFieldCount(t *testing.T) {
	if _, ok := normalizeAWSCron("cron(0 5 * *)"); ok {
		t.Error("expected ok=false for a 4-field expression")
	}
}

func TestParseAWSCronNextRun(t *testing.T) {
	after := time.Date(2026, 11, 13, 4, 0, 0, 0, time.UTC)
	got := parseAWSCronNextRun("cron(0 5 * * ? *)", after)
	if got == nil {
		t.Fatal("got nil, want a next-run time")
	}
	want := "2026-11-13T05:00:00Z"
	if *got != want {
		t.Errorf("next run = %s, want %s", *got, want)
	}
}

func TestParseAWSCronNextRunMalformedReturnsNil(t *testing.T) {
	if got := parseAWSCronNextRun("not a cron", time.Now()); got != nil {
		t.Errorf("got %v, want nil for a malformed cron", got)
	}
}
