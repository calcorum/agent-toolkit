#!/usr/bin/env bash
# test-gitea-field-shapes.sh — git-cli tolerates tea's three field shapes.
#
# WHAT
#   `tea` reports user/assignee/label fields three different ways depending on
#   which subcommand produced the JSON:
#     1. objects  — `tea api`, the comment endpoints: {"login": "alice"}
#     2. strings in an array — `tea issues <N> --output json`: ["alice"]
#     3. one comma-joined string — `tea issues list --fields ...`: "alice"
#   Every gitea normalizer in git-cli must accept all three and always emit the
#   documented schema: an array of plain login/name strings.
#
# WHY
#   jq's `//` cannot absorb the difference. Indexing a string (`"alice" | .login`)
#   is a HARD ERROR in jq, not null, so the alternative operator never runs and
#   the entire filter aborts with:
#       jq: error: Cannot index string with string "login"
#   The pre-fix `issue show` used `[.assignees[] | .login // empty]`, which meant
#   it crashed (exit 5) on every *assigned* Gitea issue while unassigned issues
#   passed — the empty array never reached the `.login`. The type must be tested
#   before the index, which is what JQ_GITEA_ASSIGNEES/_LABELS/_USER do.
#
#   The two failure modes this guards are different and both matter:
#     - the crash (shape 2 assignees), and
#     - the SILENT one: a wrong-typed guard that yields `[]` for a populated
#       field, which looks like success. Hence every assertion below checks the
#       *value*, not just the exit code.
#
# Usage: bash tests/git-cli/test-gitea-field-shapes.sh [filter]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_CLI="$SCRIPT_DIR/../../utils/git-cli"

PASS=0
FAIL=0
SKIP=0
FILTER="${1:-}"

MOCK_DIR=""
cleanup() { [[ -n "$MOCK_DIR" ]] && rm -rf "$MOCK_DIR"; }
trap cleanup EXIT
MOCK_DIR=$(mktemp -d)

pass() {
  printf "  \033[32m✓\033[0m %s\n" "$1"
  ((PASS++)) || true
}
fail() {
  printf "  \033[31m✗\033[0m %s  (%s)\n" "$1" "$2"
  ((FAIL++)) || true
}
skip_filter() {
  if [[ -n "$FILTER" ]] && ! echo "$1" | grep -qi "$FILTER"; then
    ((SKIP++)) || true
    return 0
  fi
  return 1
}

run_cli() { PATH="$MOCK_DIR:$PATH" bash "$GIT_CLI" "$@" 2>"$MOCK_DIR/stderr"; }

# assert_json <label> <jq-test-expr> <output>
assert_json() {
  local label="$1" expr="$2" out="$3"
  if ! echo "$out" | jq -e . >/dev/null 2>&1; then
    fail "$label" "not valid JSON: out=$out stderr=$(cat "$MOCK_DIR/stderr")"
  elif echo "$out" | jq -e "$expr" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "assertion '$expr' failed: out=$out"
  fi
}

# The gitea platform selector: remote host must match the tea login host so
# detect_platform resolves gitea rather than falling back to github.
write_git_mock() {
  cat >"$MOCK_DIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "remote get-url origin") echo "https://git.stonefish.tech/owner/repo.git" ;;
  *) command git "$@" ;;
esac
EOF
  chmod +x "$MOCK_DIR/git"
}

# write_tea_mock <issue-show-json> <issue-list-json> <pr-list-json>
# Each argument is the literal JSON the corresponding tea subcommand returns,
# so a single test can pin one specific field shape.
write_tea_mock() {
  local show_json="$1" list_json="$2" pr_list_json="$3"
  cat >"$MOCK_DIR/tea" <<EOF
#!/usr/bin/env bash
case "\$1 \$2 \$3" in
  "login list --output") echo '[{"url":"https://git.stonefish.tech","user":"alice"}]'; exit 0 ;;
esac
case "\$1 \$2" in
  "issues list") echo '${list_json}'; exit 0 ;;
  "pr list")     echo '${pr_list_json}'; exit 0 ;;
esac
# \`tea issues <N> --output json\` — the show path (no "list" subcommand).
if [[ "\$1" == "issues" && "\$2" =~ ^[0-9]+\$ ]]; then
  echo '${show_json}'; exit 0
fi
echo "unexpected tea call: \$*" >&2; exit 1
EOF
  chmod +x "$MOCK_DIR/tea"
}

write_git_mock

# ---------------------------------------------------------------------------
# Shape 2: `tea issues <N>` — assignees as an array of bare login STRINGS.
# This is the reported crash. Regression guard for "Cannot index string with
# string \"login\"".
# ---------------------------------------------------------------------------
echo "── issue show: assignees as strings (the reported crash) ──"

SHOW_STRINGS='{"index":3,"title":"T","body":"B","state":"closed","user":"cal","assignees":["cal","bob"],"labels":[{"name":"bug","color":"red"}],"created":"t1","url":"https://git.stonefish.tech/owner/repo/issues/3"}'
SHOW_EMPTY='{"index":1,"title":"T","body":"B","state":"open","user":"cal","assignees":[],"labels":[],"created":"t1","url":"u"}'
SHOW_OBJECTS='{"index":4,"title":"T","body":"B","state":"open","user":{"login":"cal"},"assignees":[{"login":"cal"}],"labels":[{"name":"bug"}],"created":"t1","url":"u"}'
LIST_EMPTY='[]'
PR_LIST_EMPTY='[]'

if ! skip_filter "show string assignees"; then
  write_tea_mock "$SHOW_STRINGS" "$LIST_EMPTY" "$PR_LIST_EMPTY"
  out=$(run_cli issue show 3)
  rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "issue show with string assignees exits 0" "rc=$rc stderr=$(cat "$MOCK_DIR/stderr")"
  else
    pass "issue show with string assignees exits 0"
  fi
  # The silent-failure guard: [] here would look like success but lose the data.
  assert_json "issue show maps string assignees to [\"cal\",\"bob\"]" \
    '.assignees == ["cal","bob"]' "$out"
  assert_json "issue show maps object labels to [\"bug\"]" '.labels == ["bug"]' "$out"
  assert_json "issue show maps string user to author" '.author == "cal"' "$out"
fi

if ! skip_filter "show object assignees"; then
  write_tea_mock "$SHOW_OBJECTS" "$LIST_EMPTY" "$PR_LIST_EMPTY"
  out=$(run_cli issue show 4)
  assert_json "issue show maps object assignees to logins" '.assignees == ["cal"]' "$out"
  assert_json "issue show maps object user to author" '.author == "cal"' "$out"
fi

if ! skip_filter "show unassigned"; then
  write_tea_mock "$SHOW_EMPTY" "$LIST_EMPTY" "$PR_LIST_EMPTY"
  out=$(run_cli issue show 1)
  # The known-good control: unassigned issues passed before the fix and must
  # keep passing, so a green suite is not just the bug's absence.
  assert_json "issue show with no assignees still yields []" '.assignees == []' "$out"
  assert_json "issue show with no labels still yields []" '.labels == []' "$out"
fi

# ---------------------------------------------------------------------------
# Shape 3: `tea issues list --fields` — one comma-joined string per field.
# ---------------------------------------------------------------------------
echo "── issue list: --fields flattens to strings ──"

LIST_STRINGS='[{"index":"15","title":"T","body":"B","state":"open","author":"cal","assignees":"cal","labels":"wayfinder","milestone":"","created":"t1","updated":"t2","url":"u"},{"index":"14","title":"T2","body":"","state":"open","author":"cal","assignees":"","labels":"","milestone":"","created":"t1","updated":"t2","url":"u2"}]'

if ! skip_filter "list string fields"; then
  write_tea_mock "$SHOW_EMPTY" "$LIST_STRINGS" "$PR_LIST_EMPTY"
  out=$(run_cli issue list --state all)
  assert_json "issue list wraps a scalar assignee string in an array" \
    '.[0].assignees == ["cal"]' "$out"
  assert_json "issue list wraps a scalar label string in an array" \
    '.[0].labels == ["wayfinder"]' "$out"
  assert_json "issue list maps empty assignee string to []" '.[1].assignees == []' "$out"
  assert_json "issue list maps empty label string to []" '.[1].labels == []' "$out"
fi

if ! skip_filter "list array fields"; then
  LIST_ARRAYS='[{"index":"15","title":"T","body":"B","state":"open","author":"cal","assignees":["cal"],"labels":[{"name":"bug"}],"milestone":null,"created":"t1","updated":"t2","url":"u"}]'
  write_tea_mock "$SHOW_EMPTY" "$LIST_ARRAYS" "$PR_LIST_EMPTY"
  out=$(run_cli issue list --state all)
  assert_json "issue list accepts array-of-strings assignees" '.[0].assignees == ["cal"]' "$out"
  assert_json "issue list accepts array-of-objects labels" '.[0].labels == ["bug"]' "$out"
fi

# ---------------------------------------------------------------------------
# The PR paths share the same normalizers and the same hazard.
# ---------------------------------------------------------------------------
echo "── pr list / pr show: same shapes ──"

PR_LIST_STRINGS='[{"index":6,"title":"P","body":"B","state":"open","merged":false,"author":"cal","head":"feat/x","base":"main","assignees":["cal"],"labels":["bug"],"created":"t1","updated":"t2","url":"u"}]'

if ! skip_filter "pr list string assignees"; then
  write_tea_mock "$SHOW_EMPTY" "$LIST_EMPTY" "$PR_LIST_STRINGS"
  out=$(run_cli pr list --state all)
  assert_json "pr list maps string assignees to logins" '.[0].assignees == ["cal"]' "$out"
  assert_json "pr list maps string labels to names" '.[0].labels == ["bug"]' "$out"

  out=$(run_cli pr show 6)
  assert_json "pr show maps string assignees to logins" '.assignees == ["cal"]' "$out"
  assert_json "pr show maps string labels to names" '.labels == ["bug"]' "$out"
fi

echo
echo "Total: $((PASS + FAIL))  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
[[ $FAIL -eq 0 ]]
