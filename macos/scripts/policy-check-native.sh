#!/usr/bin/env bash
# Diff the Allow actions in docs/iam-policy.json against the native app's
# allowlist: the AWSOperation enum in Sources/ADBMCore/Guard.swift, with each
# case's IAM prefix taken from AWSOperation.service. Exit 1 on any drift.
# Needs jq. The native counterpart of scripts/policy-check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
policy_json=../docs/iam-policy.json
guard_swift=Sources/ADBMCore/Guard.swift

jq empty "$policy_json"

guard=$(mktemp); policy=$(mktemp)
trap 'rm -f "$guard" "$policy"' EXIT

awk '
  # Pass 1 (enum body): case swiftName = "RawValue"
  /enum AWSOperation/ { inenum = 1; next }
  inenum && /public var name/ { inenum = 0 }
  inenum && match($0, /case [A-Za-z]+ = "[A-Za-z]+"/) {
    s = substr($0, RSTART + 5, RLENGTH - 5); split(s, a, " = ")
    gsub(/"/, "", a[2]); raw[a[1]] = a[2]; order[++n] = a[1]; next
  }
  # Pass 2 (service switch): collect the cases mapped to each service.
  /public var service: AWSService/ { insvc = 1; next }
  insvc {
    line = line " " $0
    if ($0 ~ /return \./) {
      match($0, /return \.[a-z]+/); svc = substr($0, RSTART + 8, RLENGTH - 8)
      while (match(line, /\.[a-zA-Z]+[,:]/)) {
        name = substr(line, RSTART + 1, RLENGTH - 2); prefix[name] = svc
        line = substr(line, RSTART + RLENGTH)
      }
      line = ""
    }
    if ($0 ~ /default:/) { line = "" }
    if ($0 ~ /^    }$/) { insvc = 0 }
  }
  END {
    for (i = 1; i <= n; i++) {
      k = order[i]; p = (k in prefix) ? prefix[k] : "rds"
      print p ":" raw[k]
    }
  }
' "$guard_swift" | sort -u > "$guard"

jq -r '.Statement[] | select(.Effect == "Allow" and ((.Sid // "") | startswith("AppGuardAllowlist"))) | .Action | if type == "array" then .[] else . end' "$policy_json" | sort -u > "$policy"

g=$(wc -l < "$guard" | tr -d ' '); p=$(wc -l < "$policy" | tr -d ' ')
echo "native allowlist: $g actions"
echo "policy allow:     $p actions"
if diff -u --label Guard.swift "$guard" --label iam-policy.json "$policy"; then
  echo "OK: $g/$p policy Allow set matches the native allowlist one-to-one"
else
  echo "DRIFT: fix docs/iam-policy.json or macos/Sources/ADBMCore/Guard.swift" >&2
  exit 1
fi
echo "explicit Deny: $(jq '[.Statement[] | select(.Effect == "Deny") | .Action | if type == "array" then .[] else . end] | length' "$policy_json") action patterns"
