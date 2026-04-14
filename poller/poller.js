const fs = require('fs/promises');
const { spawn } = require('child_process');
const path = require('path');

const GITHUB_REPO = process.env.GITHUB_REPO || '';
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';
const PIPELINE_SCRIPT = process.env.PIPELINE_SCRIPT
    || path.join(__dirname, '..', 'pipeline', 'run_pipeline.sh');
const TRIGGER_LABEL = process.env.TRIGGER_LABEL || 'overnight-task';
const PROCESSING_LABEL = process.env.PROCESSING_LABEL || 'processing';
const TASK_LABEL_CODE = process.env.TASK_LABEL_CODE || 'task-code';
const TASK_LABEL_E2E = process.env.TASK_LABEL_E2E || 'task-e2e';
const MOCK_ISSUES_FILE = process.env.MOCK_ISSUES_FILE || '';
const DRY_RUN = ['1', 'true', 'yes'].includes(String(process.env.DRY_RUN || '').toLowerCase());

function log(message) {
    console.log(`[poller] ${new Date().toISOString()} ${message}`);
}

function normalizeLabel(label) {
    if (typeof label === 'string') return label;
    return label?.name || '';
}

function uniq(items) {
    return [...new Set(items.filter(Boolean))];
}

function getToolMode(labels) {
    if (labels.includes(TASK_LABEL_E2E)) return TASK_LABEL_E2E;
    return TASK_LABEL_CODE;
}

async function api(pathname, options = {}) {
    const response = await fetch(`https://api.github.com${pathname}`, {
        ...options,
        headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': `Bearer ${GITHUB_TOKEN}`,
            'User-Agent': 'autonomous-coding-pipeline',
            ...(options.headers || {})
        }
    });

    if (!response.ok) {
        const body = await response.text();
        throw new Error(`GitHub API ${response.status}: ${body}`);
    }

    if (response.status === 204) return null;
    return response.json();
}

async function listCandidateIssues(owner, repo) {
    if (MOCK_ISSUES_FILE) {
        const raw = await fs.readFile(MOCK_ISSUES_FILE, 'utf8');
        return JSON.parse(raw);
    }

    return api(`/repos/${owner}/${repo}/issues?state=open&labels=${encodeURIComponent(TRIGGER_LABEL)}&sort=created&direction=asc&per_page=20`);
}

async function updateIssueLabels(owner, repo, issueNumber, labels) {
    if (DRY_RUN || MOCK_ISSUES_FILE) {
        log(`Dry run: would set issue #${issueNumber} labels to [${labels.join(', ')}]`);
        return null;
    }

    return api(`/repos/${owner}/${repo}/issues/${issueNumber}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ labels })
    });
}

async function runPipeline(issue, toolMode) {
    if (DRY_RUN || MOCK_ISSUES_FILE) {
        log(`Dry run: would launch ${PIPELINE_SCRIPT} for issue #${issue.number} using ${toolMode}`);
        return 0;
    }

    return new Promise((resolve) => {
        const proc = spawn('bash', [
            PIPELINE_SCRIPT,
            String(issue.number),
            issue.title || '',
            issue.body || '',
            toolMode
        ], {
            env: { ...process.env, TOOL_MODE: toolMode },
            stdio: 'inherit'
        });

        proc.on('close', (code) => resolve(code ?? 1));
    });
}

async function main() {
    if (!GITHUB_REPO) {
        throw new Error('GITHUB_REPO is not set');
    }
    if (!GITHUB_TOKEN && !MOCK_ISSUES_FILE) {
        throw new Error('GITHUB_TOKEN is not set');
    }

    const [owner, repo] = GITHUB_REPO.split('/');
    if (!owner || !repo) {
        throw new Error('GITHUB_REPO must be in owner/repo format');
    }

    log(`Checking ${GITHUB_REPO} for ${TRIGGER_LABEL} issues...`);
    const issues = await listCandidateIssues(owner, repo);
    const nextIssue = issues
        .filter((issue) => !issue.pull_request)
        .find((issue) => !(issue.labels || []).map(normalizeLabel).includes(PROCESSING_LABEL));

    if (!nextIssue) {
        log('No pending issues found.');
        return;
    }

    const currentLabels = (nextIssue.labels || []).map(normalizeLabel);
    const toolMode = getToolMode(currentLabels);
    const runningLabels = uniq(currentLabels.filter((label) => label !== TRIGGER_LABEL).concat(PROCESSING_LABEL));
    const finishedLabels = uniq(runningLabels.filter((label) => label !== PROCESSING_LABEL));

    log(`Selected issue #${nextIssue.number}: ${nextIssue.title}`);
    log(`Tool route: ${toolMode}`);

    await updateIssueLabels(owner, repo, nextIssue.number, runningLabels);
    const exitCode = await runPipeline(nextIssue, toolMode);
    await updateIssueLabels(owner, repo, nextIssue.number, finishedLabels);

    if (exitCode !== 0) {
        throw new Error(`Pipeline exited with code ${exitCode}`);
    }

    log(`Finished issue #${nextIssue.number}`);
}

main().catch((error) => {
    log(`ERROR: ${error.message}`);
    process.exit(1);
});
