package awsx

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"regexp"
	"testing"
)

// forbiddenCallTarget matches the name of any destructive AWS operation
// when it appears as the target of a call expression (a direct SDK call,
// through a renamed import, or as `pkg.DeleteDBInstance(...)`). It is
// deliberately scoped to call targets, not every identifier, so it does
// not flag an unrelated struct field such as DeletionProtection.
var forbiddenCallTarget = regexp.MustCompile(
	`^(Delete|Remove|Stop|Reboot|Failover|Terminate)\w*$` +
		`|^(UpdateBackupPlan|PutBackupVaultAccessPolicy|PutBackupVaultLockConfiguration|ModifyDBSnapshotAttribute|ModifyDBClusterSnapshotAttribute)$`,
)

// callTargetName returns the identifier a call expression invokes: for
// `pkg.Name(...)` that is "Name"; for `Name(...)` that is "Name"; anything
// else (e.g. a call through a function value with an unrelated name)
// returns "".
func callTargetName(call *ast.CallExpr) string {
	switch fn := call.Fun.(type) {
	case *ast.Ident:
		return fn.Name
	case *ast.SelectorExpr:
		return fn.Sel.Name
	default:
		return ""
	}
}

// TestNoDeleteOrDestructiveCallsAnywhereInInternal statically scans every
// Go source file under internal/** (this package included) for an
// identifier matching forbiddenIdentifier. It fails the build the moment
// anyone, now or later, writes a call to a destructive AWS operation -
// independent of the runtime guard in guard.go, and independent of
// whether that code path is ever exercised by a test.
func TestNoDeleteOrDestructiveCallsAnywhereInInternal(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("resolve project root: %v", err)
	}
	internalDir := filepath.Join(root, "internal")

	fset := token.NewFileSet()
	found := 0

	err = filepath.WalkDir(internalDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || filepath.Ext(path) != ".go" {
			return nil
		}

		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}

		ast.Inspect(file, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			name := callTargetName(call)
			if name != "" && forbiddenCallTarget.MatchString(name) {
				t.Errorf("%v: forbidden call %q found (violates the no-delete invariant)",
					fset.Position(call.Pos()), name)
				found++
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", internalDir, err)
	}
	t.Logf("scanned internal/** for destructive identifiers; found=%d", found)
}
