package actions

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

func TestValidateIdentifier(t *testing.T) {
	cases := []struct {
		id      string
		wantErr bool
	}{
		{"", true},
		{"my-db-1", false},
		{"1-leading-digit", true},
		{"has--double-hyphen", true},
		{"trailing-hyphen-", true},
		{"has_underscore", true},
		{"UpperCamelDB", false},
		{string(make([]byte, 64, 64)), true}, // too long and invalid charset
	}
	for _, c := range cases {
		err := ValidateIdentifier(c.id)
		if (err != nil) != c.wantErr {
			t.Errorf("ValidateIdentifier(%q) err = %v, wantErr %v", c.id, err, c.wantErr)
		}
	}
}

func TestValidateNewTargetRejectsExistingIdentifier(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			return &rds.DescribeDBInstancesOutput{
				DBInstances: []rdstypes.DBInstance{{DBInstanceIdentifier: in.DBInstanceIdentifier}},
			}, nil
		},
	}, nil, nil)

	err := ValidateNewTarget(context.Background(), cs, model.DBKindInstance, "source-db", "already-exists")
	if err == nil {
		t.Fatal("expected an error when the target identifier already exists, got nil")
	}
}

func TestValidateNewTargetAllowsNewIdentifierWhenSourceNotFound(t *testing.T) {
	// stubRDS defaults DescribeDBInstances to a "not found" fault, which is
	// exactly what a brand-new target identifier should produce.
	cs := newStubClientSet(nil, nil, nil)

	err := ValidateNewTarget(context.Background(), cs, model.DBKindInstance, "source-db", "brand-new-db")
	if err != nil {
		t.Fatalf("expected a genuinely new identifier to pass, got: %v", err)
	}
}

func TestValidateNewTargetRejectsSameAsSource(t *testing.T) {
	cs := newStubClientSet(nil, nil, nil)
	err := ValidateNewTarget(context.Background(), cs, model.DBKindInstance, "same-db", "same-db")
	if err == nil {
		t.Fatal("expected an error when target == source, got nil")
	}
}

func TestValidateNewTargetRejectsInvalidIdentifier(t *testing.T) {
	cs := newStubClientSet(nil, nil, nil)
	err := ValidateNewTarget(context.Background(), cs, model.DBKindInstance, "source-db", "--bad")
	if err == nil {
		t.Fatal("expected an error for an invalid target identifier, got nil")
	}
}

func TestValidateNewTargetPropagatesNonNotFoundErrors(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			return nil, &rdstypes.InvalidDBInstanceStateFault{Message: aws.String("boom")}
		},
	}, nil, nil)

	err := ValidateNewTarget(context.Background(), cs, model.DBKindInstance, "source-db", "some-target")
	if err == nil {
		t.Fatal("expected a non-NotFound error to propagate, got nil")
	}
}

func TestLookupSourceConfigInstance(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBInstances: func(ctx context.Context, in *rds.DescribeDBInstancesInput) (*rds.DescribeDBInstancesOutput, error) {
			return &rds.DescribeDBInstancesOutput{
				DBInstances: []rdstypes.DBInstance{{
					DBInstanceClass: aws.String("db.r6g.large"),
					Engine:          aws.String("postgres"),
					DBSubnetGroup:   &rdstypes.DBSubnetGroup{DBSubnetGroupName: aws.String("subnet-group-a")},
					DBParameterGroups: []rdstypes.DBParameterGroupStatus{
						{DBParameterGroupName: aws.String("param-group-a")},
					},
					VpcSecurityGroups: []rdstypes.VpcSecurityGroupMembership{
						{VpcSecurityGroupId: aws.String("sg-1")},
						{VpcSecurityGroupId: aws.String("sg-2")},
					},
				}},
			}, nil
		},
	}, nil, nil)

	cfg, err := lookupSourceConfig(context.Background(), cs, model.DBKindInstance, "source-db")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.InstanceClass != "db.r6g.large" || cfg.Engine != "postgres" || cfg.SubnetGroupName != "subnet-group-a" || cfg.ParameterGroupName != "param-group-a" {
		t.Errorf("unexpected sourceConfig: %+v", cfg)
	}
	if len(cfg.SecurityGroupIDs) != 2 || cfg.SecurityGroupIDs[0] != "sg-1" || cfg.SecurityGroupIDs[1] != "sg-2" {
		t.Errorf("unexpected security groups: %v", cfg.SecurityGroupIDs)
	}
}

func TestLookupSourceConfigCluster(t *testing.T) {
	cs := newStubClientSet(&stubRDS{
		describeDBClusters: func(ctx context.Context, in *rds.DescribeDBClustersInput) (*rds.DescribeDBClustersOutput, error) {
			return &rds.DescribeDBClustersOutput{
				DBClusters: []rdstypes.DBCluster{{
					Engine:                  aws.String("aurora-postgresql"),
					DBSubnetGroup:           aws.String("subnet-group-b"),
					DBClusterParameterGroup: aws.String("cluster-param-group-b"),
					VpcSecurityGroups: []rdstypes.VpcSecurityGroupMembership{
						{VpcSecurityGroupId: aws.String("sg-9")},
					},
				}},
			}, nil
		},
	}, nil, nil)

	cfg, err := lookupSourceConfig(context.Background(), cs, model.DBKindCluster, "source-cluster")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Engine != "aurora-postgresql" || cfg.SubnetGroupName != "subnet-group-b" || cfg.ParameterGroupName != "cluster-param-group-b" {
		t.Errorf("unexpected sourceConfig: %+v", cfg)
	}
	if len(cfg.SecurityGroupIDs) != 1 || cfg.SecurityGroupIDs[0] != "sg-9" {
		t.Errorf("unexpected security groups: %v", cfg.SecurityGroupIDs)
	}
}

func TestResolvedNetworkingOverridesWinOverSource(t *testing.T) {
	src := sourceConfig{
		SubnetGroupName:    "source-subnet",
		SecurityGroupIDs:   []string{"sg-source"},
		ParameterGroupName: "source-param-group",
		InstanceClass:      "db.r6g.large",
	}

	req := model.RestoreReq{
		SubnetGroup:    "override-subnet",
		SecurityGroups: []string{"sg-override"},
		InstanceClass:  "db.r6g.xlarge",
	}
	subnet, sgs, paramGroup, class := resolvedNetworking(req, src)
	if subnet != "override-subnet" || len(sgs) != 1 || sgs[0] != "sg-override" || class != "db.r6g.xlarge" {
		t.Errorf("expected overrides to win, got subnet=%q sgs=%v class=%q", subnet, sgs, class)
	}
	// The model has no override field for the parameter group: it is
	// always copied from the source when available.
	if paramGroup != "source-param-group" {
		t.Errorf("expected parameter group to be copied from source, got %q", paramGroup)
	}
}

func TestResolvedNetworkingFallsBackToSourceWhenNoOverride(t *testing.T) {
	src := sourceConfig{
		SubnetGroupName:    "source-subnet",
		SecurityGroupIDs:   []string{"sg-source"},
		ParameterGroupName: "source-param-group",
		InstanceClass:      "db.r6g.large",
	}
	subnet, sgs, paramGroup, class := resolvedNetworking(model.RestoreReq{}, src)
	if subnet != "source-subnet" || len(sgs) != 1 || sgs[0] != "sg-source" || class != "db.r6g.large" || paramGroup != "source-param-group" {
		t.Errorf("expected fallback to source config, got subnet=%q sgs=%v class=%q paramGroup=%q", subnet, sgs, class, paramGroup)
	}
}
