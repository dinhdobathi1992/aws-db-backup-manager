package awsx

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func notFound(string) (string, error) { return "", errors.New("not found") }

func TestResolveAWSCLIPrefersPATH(t *testing.T) {
	got, err := resolveAWSCLI(func(string) (string, error) { return "/custom/bin/aws", nil }, nil)
	if err != nil || got != "/custom/bin/aws" {
		t.Fatalf("got %q, %v; want PATH hit", got, err)
	}
}

func TestResolveAWSCLIFallsBackToKnownLocations(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing", "aws")
	notExec := filepath.Join(dir, "plain")
	exe := filepath.Join(dir, "aws")
	if err := os.WriteFile(notExec, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := resolveAWSCLI(notFound, []string{missing, notExec, dir, exe})
	if err != nil || got != exe {
		t.Fatalf("got %q, %v; want %q", got, err, exe)
	}
}

func TestResolveAWSCLIErrorsWhenAbsent(t *testing.T) {
	if _, err := resolveAWSCLI(notFound, []string{filepath.Join(t.TempDir(), "aws")}); err == nil {
		t.Fatal("expected an error when aws is nowhere to be found")
	}
}
