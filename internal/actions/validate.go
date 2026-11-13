// Package actions implements every mutating operation this app can perform
// (manual snapshots, on-demand AWS Backup jobs, backup plans, raising
// automated retention, and restores into a brand-new identifier), built only
// on top of the guarded clients in internal/awsx. There is no delete, remove,
// terminate, or failover call anywhere in this package; the guard enforces
// that independently, but every function here is written as if it were the
// only line of defense.
package actions

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/awsx"
	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// identifierCharset matches RDS's own identifier rules: letters, digits and
// hyphens, first character a letter. Length and the no-double-hyphen /
// no-trailing-hyphen rules are checked separately so a rejected identifier
// gets a specific reason instead of one generic regex mismatch.
var identifierCharset = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]*$`)

// ValidateIdentifier enforces RDS's DB/snapshot identifier constraints: 1-63
// characters, starts with a letter, no two consecutive hyphens, and no
// trailing hyphen.
func ValidateIdentifier(id string) error {
	if id == "" {
		return errors.New("identifier is required")
	}
	if len(id) > 63 {
		return fmt.Errorf("identifier %q is %d characters; the limit is 63", id, len(id))
	}
	if !identifierCharset.MatchString(id) {
		return fmt.Errorf("identifier %q must start with a letter and contain only letters, digits, and hyphens", id)
	}
	if strings.Contains(id, "--") {
		return fmt.Errorf("identifier %q cannot contain two consecutive hyphens", id)
	}
	if strings.HasSuffix(id, "-") {
		return fmt.Errorf("identifier %q cannot end with a hyphen", id)
	}
	return nil
}

// ValidateNewTarget enforces the restore-only-into-a-new-identifier rule: the
// target must pass identifier validation, must differ from the source, and
// must not already name an existing instance or cluster in this
// account/region. This is the one check every restore path in restore.go
// shares, and it is the backstop against ever restoring over an existing
// database even if a caller got everything else right.
func ValidateNewTarget(ctx context.Context, cs *awsx.ClientSet, kind model.DBKind, sourceIdentifier, targetIdentifier string) error {
	if err := ValidateIdentifier(targetIdentifier); err != nil {
		return err
	}
	if targetIdentifier == sourceIdentifier {
		return fmt.Errorf("target identifier %q must differ from the source %q", targetIdentifier, sourceIdentifier)
	}
	exists, err := dbExists(ctx, cs, kind, targetIdentifier)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("a %s named %q already exists; restore must target a new identifier", kind, targetIdentifier)
	}
	return nil
}

// dbExists reports whether an instance or cluster with this identifier
// already exists, treating AWS's own "not found" fault as the only
// authoritative "no" and propagating every other error (including
// credential/permission failures) rather than silently treating them as
// "safe to proceed".
func dbExists(ctx context.Context, cs *awsx.ClientSet, kind model.DBKind, identifier string) (bool, error) {
	if kind == model.DBKindCluster {
		_, err := cs.RDS.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
			DBClusterIdentifier: aws.String(identifier),
		})
		if err == nil {
			return true, nil
		}
		var notFound *rdstypes.DBClusterNotFoundFault
		if errors.As(err, &notFound) {
			return false, nil
		}
		return false, fmt.Errorf("check existing cluster %q: %w", identifier, err)
	}

	_, err := cs.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		DBInstanceIdentifier: aws.String(identifier),
	})
	if err == nil {
		return true, nil
	}
	var notFound *rdstypes.DBInstanceNotFoundFault
	if errors.As(err, &notFound) {
		return false, nil
	}
	return false, fmt.Errorf("check existing instance %q: %w", identifier, err)
}

// sourceConfig is what restore.go copies from a live source database unless
// the request explicitly overrides it: its subnet group, security groups,
// parameter group, and instance class. Looking it up is best-effort — a
// source that no longer exists (the snapshot/recovery point outlived it)
// just means restore.go leaves these to AWS's own snapshot-derived defaults
// instead of failing the restore.
type sourceConfig struct {
	SubnetGroupName    string
	SecurityGroupIDs   []string
	ParameterGroupName string
	InstanceClass      string
	Engine             string
}

// lookupSourceConfig fetches the current networking/parameter-group/class
// configuration of a live source database, for restore.go to copy onto the
// restored target unless the caller overrode it.
func lookupSourceConfig(ctx context.Context, cs *awsx.ClientSet, kind model.DBKind, identifier string) (sourceConfig, error) {
	if kind == model.DBKindCluster {
		out, err := cs.RDS.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
			DBClusterIdentifier: aws.String(identifier),
		})
		if err != nil || len(out.DBClusters) == 0 {
			return sourceConfig{}, fmt.Errorf("source cluster %q not found: %w", identifier, err)
		}
		c := out.DBClusters[0]
		cfg := sourceConfig{
			SubnetGroupName:    aws.ToString(c.DBSubnetGroup),
			ParameterGroupName: aws.ToString(c.DBClusterParameterGroup),
			Engine:             aws.ToString(c.Engine),
		}
		for _, sg := range c.VpcSecurityGroups {
			cfg.SecurityGroupIDs = append(cfg.SecurityGroupIDs, aws.ToString(sg.VpcSecurityGroupId))
		}
		return cfg, nil
	}

	out, err := cs.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		DBInstanceIdentifier: aws.String(identifier),
	})
	if err != nil || len(out.DBInstances) == 0 {
		return sourceConfig{}, fmt.Errorf("source instance %q not found: %w", identifier, err)
	}
	inst := out.DBInstances[0]
	cfg := sourceConfig{
		InstanceClass: aws.ToString(inst.DBInstanceClass),
		Engine:        aws.ToString(inst.Engine),
	}
	if inst.DBSubnetGroup != nil {
		cfg.SubnetGroupName = aws.ToString(inst.DBSubnetGroup.DBSubnetGroupName)
	}
	if len(inst.DBParameterGroups) > 0 {
		cfg.ParameterGroupName = aws.ToString(inst.DBParameterGroups[0].DBParameterGroupName)
	}
	for _, sg := range inst.VpcSecurityGroups {
		cfg.SecurityGroupIDs = append(cfg.SecurityGroupIDs, aws.ToString(sg.VpcSecurityGroupId))
	}
	return cfg, nil
}

// resolvedNetworking applies the "copy source unless overridden" rule: a
// non-empty override always wins; otherwise it falls back to whatever
// lookupSourceConfig found (which is empty, not an error, if the source
// lookup failed). The request model has no override field for parameter
// group, so it is always copied from the source when available.
func resolvedNetworking(req model.RestoreReq, src sourceConfig) (subnetGroup string, securityGroups []string, parameterGroup string, instanceClass string) {
	subnetGroup = req.SubnetGroup
	if subnetGroup == "" {
		subnetGroup = src.SubnetGroupName
	}
	securityGroups = req.SecurityGroups
	if len(securityGroups) == 0 {
		securityGroups = src.SecurityGroupIDs
	}
	parameterGroup = src.ParameterGroupName
	instanceClass = req.InstanceClass
	if instanceClass == "" {
		instanceClass = src.InstanceClass
	}
	return subnetGroup, securityGroups, parameterGroup, instanceClass
}
