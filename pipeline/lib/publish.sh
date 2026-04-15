#!/bin/bash

# Commit, push, and PR helpers.

commit_and_push_changes() {
    git add -A
    git commit -m "feat: implement issue #$ISSUE_NUMBER - $ISSUE_TITLE" || true
    git push origin "$BRANCH"
}

determine_pr_mode() {
    CREATE_PR=true

    if [ "$PIPELINE_BRANCH_MODE" = "direct-target" ]; then
        CREATE_PR=false
    fi

    if [ "$SKIP_PR_CREATE" = "true" ]; then
        CREATE_PR=false
    elif [ "$SKIP_PR_CREATE" = "false" ]; then
        CREATE_PR=true
    fi

    if [ "$BRANCH" = "$BASE_BRANCH" ]; then
        CREATE_PR=false
    fi
}

build_pr_metadata() {
    if [ "$TEST_PASSED" = true ]; then
        PR_TITLE="feat: $ISSUE_TITLE"
        PR_LABEL="ready-for-review"
        PR_BODY="Closes #$ISSUE_NUMBER

## Route

$TOOL_MODE

## What was done

$(cat "$PLAN_FILE")

## Tests

Automated checks passed via $TEST_STATUS."
    else
        PR_TITLE="wip: $ISSUE_TITLE [needs review]"
        PR_LABEL="needs-human-review"
        PR_BODY="Closes #$ISSUE_NUMBER

## Route

$TOOL_MODE

## Status

Pipeline completed but validation status is: $TEST_STATUS.

## Plan

$(cat "$PLAN_FILE")

## Test output

\`\`\`
$(cat "$TEST_OUTPUT_FILE" 2>/dev/null || echo 'no output')
\`\`\`"
    fi
}

publish_results() {
    if [ "$CREATE_PR" = true ]; then
        gh pr create \
            --title "$PR_TITLE" \
            --body "$PR_BODY" \
            --base "$BASE_BRANCH" \
            --head "$BRANCH" || log "PR already exists or creation failed"

        gh pr edit "$BRANCH" --add-label "$PR_LABEL" >/dev/null 2>&1 || log "Label '$PR_LABEL' could not be added"
        log "Done - PR opened for issue #$ISSUE_NUMBER"
    else
        gh issue edit "$ISSUE_NUMBER" --repo "$GITHUB_REPO" --add-label "$PR_LABEL" >/dev/null 2>&1 || log "Issue label '$PR_LABEL' could not be added"
        log "Done - committed directly to $BRANCH for issue #$ISSUE_NUMBER (PR skipped)"
    fi
}
