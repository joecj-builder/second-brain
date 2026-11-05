#!/bin/bash
# Tests for scripts/datacontext-match.sh (the DataContext matcher + Agent hook).
#
#   bash tests/datacontext-match-test.sh                  fixture vault only
#   bash tests/datacontext-match-test.sh --goldens FILE   also run FILE against the real vault
#
# With no --goldens, ~/.claude/second-brain/datacontext-goldens.tsv is used if it
# exists. Golden file format, one case per line (tab-separated, # = comment):
#   <expected><TAB><prompt>
# <expected> is a comma-separated list of note names that must all appear; an
# entry may be a|b (either one), and "-" means nothing may match.
# The real vault comes from config.env (SECOND_BRAIN_VAULT), as in the hook.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
match="$here/../scripts/datacontext-match.sh"
goldens="$HOME/.claude/second-brain/datacontext-goldens.tsv"
[ "${1:-}" = "--goldens" ] && goldens="${2:-}"

fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- fixture vault -------------------------------------------------------
v="$tmp/vault"
mkdir -p "$v/DataContext/working-with-user" "$v/DataContext/_archive"
cat > "$v/DataContext/usage-vs-plan-sot.md" <<'EOF'
---
name: usage-vs-plan-sot
description: Usage vs plan limits for every type (seats, storage, API calls) comes from the billing dashboard Finance invoices from
keywords: [usage vs plan, over plan, overage, seats, storage, api calls, billing dashboard]
metadata:
  type: reference
---
# Usage vs plan
EOF
cat > "$v/DataContext/crm-account-ids.md" <<'EOF'
---
name: crm-account-ids
description: Which CRM company property holds the account id (account_uid, not legacy_account_id)
keywords: [account id, account_uid, legacy_account_id, crm company id]
---
# CRM account ids
EOF
cat > "$v/DataContext/revenue-definitions.md" <<'EOF'
---
name: revenue-definitions
description: >
  Where recurring revenue, retention and bookings numbers come from
  and how the sources disagree
keywords:
  - mrr
  - recurring revenue
  - retention
---
# Revenue
EOF
cat > "$v/DataContext/no-frontmatter.md" <<'EOF'
# Warehouse table naming conventions
Some text.
EOF
cat > "$v/DataContext/broken-frontmatter.md" <<'EOF'
---
name: [unclosed
description: "half a quote
keywords: [also, unclosed
EOF
printf '\xff\xfe\x00binary-ish\n' > "$v/DataContext/binary.md"
cat > "$v/DataContext/working-with-user/prefer-small-prs.md" <<'EOF'
---
name: prefer-small-prs
description: The user prefers small pull requests split by risk
---
EOF
cat > "$v/DataContext/_archive/old-usage-note.md" <<'EOF'
---
name: old-usage-note
description: Old usage vs plan seats storage overage note
keywords: [usage vs plan, seats, storage, overage]
---
EOF

cfg="$tmp/config.env"
printf 'SECOND_BRAIN_VAULT="%s"\n' "$v" > "$cfg"
export SECOND_BRAIN_CONFIG="$cfg"

expect_case() {  # <expected> <prompt> — expected as in the golden file format
  local expected="$1" prompt="$2" got want ok alt label
  got="$(bash "$match" --json "$prompt" | python3 -I -c 'import json,sys,os; print(" ".join(os.path.basename(m["path"])[:-3] for m in json.load(sys.stdin)))')"
  label="$(printf '%.60s' "$prompt") -> [${got:-nothing}]"
  if [ "$expected" = "-" ]; then
    [ -z "$got" ] && pass "$label" || fail "$label (expected nothing)"
    return
  fi
  ok=1
  IFS=',' read -r -a wants <<< "$expected"
  for want in "${wants[@]}"; do
    local found=0
    IFS='|' read -r -a alts <<< "$want"
    for alt in "${alts[@]}"; do
      case " $got " in *" $alt "*) found=1 ;; esac
    done
    [ $found = 1 ] || ok=0
  done
  [ $ok = 1 ] && pass "$label" || fail "$label (expected $expected)"
}

echo "== fixture vault: matching"
expect_case "usage-vs-plan-sot" "Compute seats and storage usage vs plan for each account, flag over plan"
expect_case "crm-account-ids" "Read the account id from the CRM company record (account_uid)"
expect_case "revenue-definitions" "Chart MRR and retention by month"
expect_case "-" "rename a variable in the CSS"
expect_case "-" "Refactor the TypeScript build config and bump eslint"
expect_case "-" "Add a dark mode toggle to the settings page"
got="$(bash "$match" --json "usage vs plan seats storage overage")"
case "$got" in *old-usage-note*) fail "_archive/ notes are skipped" ;; *) pass "_archive/ notes are skipped" ;; esac
got="$(bash "$match" --json "pull requests")"
case "$got" in *prefer-small-prs*) fail "weak working-with-user match is skipped" ;; *) pass "weak working-with-user match is skipped" ;; esac

echo "== fixture vault: hook"
agent_json() {  # <prompt>
  python3 -I -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"build","prompt":sys.argv[1],"subagent_type":"general-purpose"}}))' "$1"
}
hook() { bash "$match" --hook; }

out="$(agent_json "Compute seats and storage usage vs plan for each account" | hook)"; rc=$?
if [ $rc = 0 ] && printf '%s' "$out" | python3 -I -c '
import json,sys
o=json.load(sys.stdin)["hookSpecificOutput"]
p=o["updatedInput"]["prompt"]
assert p.startswith("Compute seats"), "original prompt kept first"
assert "usage-vs-plan-sot.md" in p and "Read these before defining metrics" in p
assert o["updatedInput"]["subagent_type"] == "general-purpose", "other fields kept"
assert "permissionDecision" not in o
'; then pass "inject: appends matches, keeps other fields"; else fail "inject: appends matches, keeps other fields"; fi

out="$(agent_json "rename a variable in the CSS" | hook)"
[ -z "$out" ] && pass "inject: no match -> no output" || fail "inject: no match -> no output ($out)"

out="$(agent_json "seats and storage usage vs plan; see DataContext/usage-vs-plan-sot.md" | hook)"
case "$out" in *usage-vs-plan-sot*) fail "inject: skips notes the prompt already names" ;; *) pass "inject: skips notes the prompt already names" ;; esac

out="$(agent_json "Compute seats and storage usage vs plan" | SECOND_BRAIN_SUBAGENT_CONTEXT=remind hook)"
printf '%s' "$out" | python3 -I -c 'import json,sys; o=json.load(sys.stdin)["hookSpecificOutput"]; assert "updatedInput" not in o and "usage-vs-plan-sot" in o["additionalContext"]' \
  && pass "remind: additionalContext only" || fail "remind: additionalContext only"

out="$(agent_json "Compute seats and storage usage vs plan" | SECOND_BRAIN_SUBAGENT_CONTEXT=deny hook)"
printf '%s' "$out" | python3 -I -c 'import json,sys; o=json.load(sys.stdin)["hookSpecificOutput"]; assert o["permissionDecision"]=="deny" and "usage-vs-plan-sot" in o["permissionDecisionReason"]' \
  && pass "deny: refuses with the matches" || fail "deny: refuses with the matches"

out="$(agent_json "Compute seats and storage usage vs plan" | SECOND_BRAIN_SUBAGENT_CONTEXT=off hook)"
[ -z "$out" ] && pass "off: no output" || fail "off: no output"

echo "== hook never fails"
for input in "" "not json" '{"tool_input":null}' '{"tool_input":{"prompt":42}}' '{"tool_name":"Agent"}'; do
  out="$(printf '%s' "$input" | hook 2>&1)"; rc=$?
  [ $rc = 0 ] && [ -z "$out" ] && pass "bad stdin '${input:-<empty>}'" || fail "bad stdin '${input:-<empty>}' (rc=$rc out=$out)"
done
printf 'SECOND_BRAIN_VAULT="%s"\n' "$tmp/missing" > "$tmp/missing.env"
out="$(agent_json "seats usage vs plan" | SECOND_BRAIN_CONFIG="$tmp/missing.env" hook 2>&1)"; rc=$?
[ $rc = 0 ] && [ -z "$out" ] && pass "missing vault" || fail "missing vault (rc=$rc)"
out="$(agent_json "seats usage vs plan" | SECOND_BRAIN_CONFIG="$tmp/nope.env" SECOND_BRAIN_VAULT="" hook 2>&1)"; rc=$?
[ $rc = 0 ] && [ -z "$out" ] && pass "no config" || fail "no config (rc=$rc)"

# ---- real vault goldens (private file, optional) ---------------------------
if [ -n "$goldens" ] && [ -f "$goldens" ]; then
  unset SECOND_BRAIN_CONFIG
  . "$here/../scripts/config.sh"
  echo "== goldens: $goldens (vault ${SECOND_BRAIN_VAULT:-unset})"
  while IFS=$'\t' read -r expected prompt; do
    case "$expected" in ''|'#'*) continue ;; esac
    expect_case "$expected" "$prompt"
  done < "$goldens"

  # Timing on the real vault: the hook should add well under 300 ms.
  big="$(agent_json "$(printf 'usage seats contract overage bandwidth credits root org ARR %.0s' $(seq 1 40))")"
  start=$(python3 -I -c 'import time; print(time.time())')
  for _ in 1 2 3 4 5; do printf '%s' "$big" | hook >/dev/null; done
  ms=$(python3 -I -c "import time; print(int((time.time()-$start)*1000/5))")
  [ "$ms" -lt 300 ] && pass "hook time on real vault: ${ms} ms" || fail "hook time on real vault: ${ms} ms (limit 300)"
fi

echo
if [ $fails = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
