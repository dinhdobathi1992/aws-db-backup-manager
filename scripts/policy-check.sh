#!/usr/bin/env bash
# Diff the Allow actions in docs/iam-policy.json against the guard allowlist
# in internal/awsx/guard.go. Exit 1 on any drift. Needs jq.
set -euo pipefail
cd "$(dirname "$0")/.."

jq empty docs/iam-policy.json

guard=$(mktemp); policy=$(mktemp)
trap 'rm -f "$guard" "$policy"' EXIT

awk '
  /^var allowlist/ { inside = 1; next }
  inside && /^}/   { inside = 0 }
  inside && /^[[:space:]]*\/\// { next }
  inside && match($0, /"[A-Za-z]+": \{/) { split($0, a, "\""); svc = a[2]; next }
  inside && /": +true/ { split($0, a, "\""); p = (svc == "RDS" ? "rds" : svc == "Backup" ? "backup" : svc == "STS" ? "sts" : "UNMAPPED_" svc); print p ":" a[2] }
' internal/awsx/guard.go | sort -u > "$guard"

jq -r '.Statement[] | select(.Effect == "Allow" and ((.Sid // "") | startswith("AppGuardAllowlist"))) | .Action | if type == "array" then .[] else . end' docs/iam-policy.json | sort -u > "$policy"

echo "guard allowlist: $(wc -l < "$guard" | tr -d ' ') actions"
echo "policy allow:    $(wc -l < "$policy" | tr -d ' ') actions"
if diff -u --label guard.go "$guard" --label iam-policy.json "$policy"; then
  echo "OK: policy Allow set matches the guard allowlist one-to-one"
else
  echo "DRIFT: fix docs/iam-policy.json or internal/awsx/guard.go" >&2
  exit 1
fi
echo "explicit Deny: $(jq '[.Statement[] | select(.Effect == "Deny") | .Action | if type == "array" then .[] else . end] | length' docs/iam-policy.json) action patterns"
