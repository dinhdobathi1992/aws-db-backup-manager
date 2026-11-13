package awsx

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
)

// awsCLICandidates are the usual install locations of the AWS CLI on macOS.
// A GUI app launched from Finder inherits launchd's minimal PATH
// (/usr/bin:/bin:/usr/sbin:/sbin), so Homebrew and the official .pkg
// installer locations are checked explicitly after the PATH lookup.
var awsCLICandidates = []string{
	"/opt/homebrew/bin/aws",
	"/usr/local/bin/aws",
	"/usr/local/aws-cli/aws",
	"/usr/bin/aws",
}

// resolveAWSCLI returns the absolute path of the aws binary: PATH first,
// then the well-known install locations.
func resolveAWSCLI(lookPath func(string) (string, error), candidates []string) (string, error) {
	if p, err := lookPath("aws"); err == nil {
		return p, nil
	}
	for _, c := range candidates {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return c, nil
		}
	}
	return "", fmt.Errorf("aws CLI not found on PATH or in %v; install AWS CLI v2 to use SSO sign-in", candidates)
}

// SsoLogin runs `aws sso login --profile <profile>` as a real subprocess
// with an explicit argument array: no shell, no string interpolation into
// a command line, so the profile name can never be used for command
// injection. It opens the user's browser to complete SSO; stdout/stderr are
// captured only to surface a useful error message.
func SsoLogin(ctx context.Context, profile string) error {
	if profile == "" {
		return fmt.Errorf("aws profile is required")
	}

	awsBin, err := resolveAWSCLI(exec.LookPath, awsCLICandidates)
	if err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, awsBin, "sso", "login", "--profile="+profile)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("aws sso login --profile %s: %w: %s", profile, err, out.String())
	}
	return nil
}
