#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REAL_GIT="$(command -v git)"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repo"

cat > "$TMP_DIR/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "push" ]; then
    exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP_DIR/bin/git"

cd "$TMP_DIR/repo"
PATH="$TMP_DIR/bin:$PATH"
git init -q
git config user.name "Test User"
git config user.email "test@example.com"

echo "base" > app.txt
git add app.txt
git commit -q -m "init"
git checkout -q -b task/issue-123

mkdir -p .rabin/history/issue-123
echo "old plan" > .rabin/history/issue-123/old.plan.md
echo "old output" > .rabin/history/issue-123/old.test_output.txt
echo "old root plan" > plan.md
echo "old root output" > test_output.txt
git add -A
git commit -q -m "bad artifact commit"

echo "new code" >> app.txt
echo "new plan" > .rabin/history/issue-123/current.plan.md
echo "new output" > .rabin/history/issue-123/current.test_output.txt
echo "new root plan" > plan.md
echo "new root output" > test_output.txt

ISSUE_NUMBER=123
ISSUE_TITLE="Keep run artifacts out"
BRANCH="task/issue-123"
REPO_PATH="$TMP_DIR/repo"
PIPELINE_STATE_DIR="$TMP_DIR/repo/.rabin/history"
TEST_OUTPUT_FILE="$TMP_DIR/repo/.rabin/history/issue-123/current.test_output.txt"
PLAN_FILE="$TMP_DIR/repo/.rabin/history/issue-123/current.plan.md"

source "$ROOT_DIR/pipeline/lib/common.sh"
source "$ROOT_DIR/pipeline/lib/repo.sh"
source "$ROOT_DIR/pipeline/lib/publish.sh"

commit_and_push_changes

if git ls-files | grep -E '(^|/)(plan\.md|test_output\.txt|\.rabin/history/)'; then
    echo "Expected pipeline artifacts to be removed from git tracking." >&2
    exit 1
fi

grep -q 'new root plan' plan.md || {
    echo "Expected local plan artifact to remain on disk after untracking." >&2
    exit 1
}

echo "PASS"
