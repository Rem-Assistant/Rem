#!/usr/bin/env node
/**
 * Symphony Daemon — lightweight orchestrator for RemClaw
 *
 * Poll loop:
 *   1. Reconcile — clean up dead processes, check retry timers
 *   2. Fetch dispatch-ready issues from GitHub Projects
 *   3. Dispatch until concurrency slots are full
 *   4. Record PR-ready dispatches for orchestrator review/merge
 *   5. Sleep → repeat
 *
 * State: symphony-state.json (runtime artifact)
 *
 * Architecture:
 *   - Concurrency: MAX_CONCURRENT agents in parallel
 *   - Retry: exponential backoff per issue, max 3 attempts
 *   - Review: PR is handed to humans or a separate reviewer workflow
 *   - Workspaces: .symphony-workspaces/<number>-<title>/
 *   - Multi-agent: each issue = one workspace = one Codex process
 */

const { spawn, execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

function gitRepoRoot() {
  try {
    return execSync("git rev-parse --show-toplevel", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch {
    return process.cwd();
  }
}

// ── Config ─────────────────────────────────────────────────────────────────────

const REPO_ROOT = gitRepoRoot();
const REPO = "Rem-Assistant/RemClaw";
const ROADMAP_PROJECT_TITLE = process.env.SYMPHONY_PROJECT_TITLE ?? "Rem Roadmap";
const DISPATCH_LABEL = process.env.SYMPHONY_DISPATCH_LABEL ?? "dispatch";
const DISPATCH_STATUSES = parseList(process.env.SYMPHONY_DISPATCH_STATUSES ?? "Ready,Dispatch");
const DISPATCH_SOURCE = process.env.SYMPHONY_DISPATCH_SOURCE ?? "label-or-status";
const POLL_INTERVAL_MS = parseInt(process.env.SYMPHONY_POLL_MS ?? "30000");
const WORKSPACE_ROOT = process.env.SYMPHONY_ROOT ?? path.join(REPO_ROOT, ".symphony-workspaces");
const STATE_FILE = path.join(REPO_ROOT, "symphony-state.json");
const DAEMON_LOG = path.join(REPO_ROOT, "symphony-daemon.log");
const GH = "/opt/homebrew/bin/gh";
const DEFAULT_CODEX = fs.existsSync("/Applications/Codex.app/Contents/Resources/codex")
  ? "/Applications/Codex.app/Contents/Resources/codex"
  : "codex";
const CODEX = process.env.SYMPHONY_CODEX ?? DEFAULT_CODEX;
const CODEX_MODEL = process.env.SYMPHONY_CODEX_MODEL ?? "";
const CODEX_SANDBOX = process.env.SYMPHONY_CODEX_SANDBOX ?? "danger-full-access";
const REDISPATCH_COMPLETED = process.env.SYMPHONY_REDISPATCH_COMPLETED === "1";
const MAX_CONCURRENT = parseInt(process.env.SYMPHONY_MAX ?? "3");
const MAX_RETRIES = parseInt(process.env.SYMPHONY_MAX_RETRIES ?? "3");
const MAX_BACKOFF_MS = parseInt(process.env.SYMPHONY_MAX_BACKOFF_MS ?? "300000"); // 5 min
const REQUIRED_SUBMODULES = parseList(process.env.SYMPHONY_REQUIRED_SUBMODULES ?? "openclaw");

function parseList(value) {
  return String(value)
    .split(",")
    .map(v => v.trim())
    .filter(Boolean);
}

// ── State ────────────────────────────────────────────────────────────────────

let state = {
  running: {},     // `${number}` -> { pid, startedAt, workspacePath, branch, mode }
  prReady: {},     // `${number}` -> { readyAt, exitCode, prUrl, workspacePath, branch }
  reviewed: {},    // `${number}` -> { reviewedAt, exitCode, prUrl, workspacePath }
  completed: {},   // `${number}` -> lifecycle terminal state after merge/closure
  blocked: {},     // `${number}` -> { blockedAt, reason, workspacePath, branch }
  retrying: {},    // `${number}` -> { attempt, dueAt, error, workspacePath }
  lastPoll: null,
  pid: null,
};

// ── State persistence ────────────────────────────────────────────────────────

function loadState() {
  try {
    const raw = fs.readFileSync(STATE_FILE, "utf8");
    state = { ...state, ...JSON.parse(raw) };
  } catch {
    // fresh state
  }
  state.prReady ??= {};
  state.reviewed ??= {};
  state.completed ??= {};
  state.blocked ??= {};
  state.retrying ??= {};
  state.running ??= {};
}

function saveState() {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// ── Logging ─────────────────────────────────────────────────────────────────

function log(msg) {
  const ts = new Date().toISOString();
  const line = `[symphony:${ts}] ${msg}`;
  console.log(line);
  fs.appendFileSync(DAEMON_LOG, line + "\n");
}

// ── Token cache ────────────────────────────────────────────────────────────────

let ghToken = null;
function getGhToken() {
  if (ghToken) return ghToken;
  try {
    const out = execSync([GH, "auth", "token", "--hostname", "github.com"].map(a => JSON.stringify(a)).join(" "), {
      encoding: "utf8",
      env: { ...process.env, PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    ghToken = out.trim();
    return ghToken;
  } catch (e) {
    log(`getGhToken failed: ${e.message}`);
    return "";
  }
}

function gh(args, opts = {}) {
  const env = { ...process.env, PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" };
  const cmd = [GH, ...args];
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd[0], cmd.slice(1), { env, stdio: ["ignore", "pipe", "pipe"], ...opts });
    let out = "", err = "";
    proc.stdout?.on("data", d => (out += d));
    proc.stderr?.on("data", d => (err += d));
    proc.on("close", code => {
      if (code !== 0) reject(new Error(`gh exit ${code}: ${err.slice(0, 300)}`));
      else resolve(out);
    });
  });
}

function runCommand(command, args, opts = {}) {
  const env = { ...process.env, PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" };
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"], ...opts });
    let out = "", err = "";
    proc.stdout?.on("data", d => (out += d));
    proc.stderr?.on("data", d => (err += d));
    proc.on("error", reject);
    proc.on("close", code => {
      if (code !== 0) reject(new Error(`${command} exit ${code}: ${err.slice(0, 300)}`));
      else resolve(out);
    });
  });
}

// ── Git helper ────────────────────────────────────────────────────────────────

function git(args, opts = {}) {
  const env = { ...process.env, PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" };
  const cmd = ["git", ...args];
  const proc = spawn(cmd[0], cmd.slice(1), { env, stdio: ["ignore", "pipe", "pipe"], ...opts });
  return new Promise((resolve, reject) => {
    let out = "", err = "";
    proc.stdout?.on("data", d => (out += d));
    proc.stderr?.on("data", d => (err += d));
    proc.on("close", code => {
      if (code !== 0) reject(new Error(`git exit ${code}: ${err.slice(0, 300)}`));
      else resolve(out);
    });
  });
}

// ── Fetch issues from GitHub Projects ─────────────────────────────────────────

async function fetchOpenIssues() {
  const PAGE_SIZE = parseInt(process.env.SYMPHONY_ISSUE_LIMIT ?? "200");
  let allIssues = [];

  const args = ["issue", "list",
    "--state", "open",
    "--limit", String(PAGE_SIZE),
    "--json", "number,title,state,body,url,labels,projectItems",
    "--jq", "."];

  if (DISPATCH_SOURCE === "label" || DISPATCH_SOURCE === "label-and-status") {
    // A label-filtered query is much cheaper and keeps the default path focused.
    args.splice(2, 0, "--label", DISPATCH_LABEL);
  }

  const out = await gh(args);

  if (!out.trim()) return [];

  try {
    allIssues = JSON.parse(out);
  } catch(e) {
    log(`[fetchOpenIssues] parse error: ${e.message}, output: ${out.slice(0,200)}`);
    return [];
  }

  return allIssues.map(normalizeIssue);
}

function normalizeIssue(i) {
  const labels = (i.labels || []).map(l => typeof l === "string" ? l : l.name);
  const projectItems = i.projectItems || [];
  const roadmapItem = projectItems.find(p => p.title === ROADMAP_PROJECT_TITLE) || projectItems[0] || {};
  const status = roadmapItem.status?.name ?? null;
  const projectStatuses = projectItems
    .map(p => ({ title: p.title, status: p.status?.name ?? null }))
    .filter(p => p.status);

  return {
    id: String(i.number),
    number: i.number,
    title: i.title,
    state: i.state,
    status,
    projectTitle: roadmapItem.title ?? null,
    priority: null,
    section: null,
    effort: null,
    body: i.body,
    url: i.url,
    labels,
    projectItems,
    projectStatuses,
  };
}

function isDispatchEligible(issue) {
  const key = String(issue.number);
  if (state.running[key] || state.retrying[key]) return false;
  if (!REDISPATCH_COMPLETED && state.prReady[key]) return false;
  if (!REDISPATCH_COMPLETED && state.reviewed[key]) return false;
  if (!REDISPATCH_COMPLETED && state.completed[key]?.exitCode === 0) return false;
  if (!REDISPATCH_COMPLETED && state.blocked[key]) return false;

  const hasLabel = issue.labels.includes(DISPATCH_LABEL);
  const hasStatus = issue.projectStatuses.some(p => DISPATCH_STATUSES.includes(p.status));

  switch (DISPATCH_SOURCE) {
    case "label":
      return hasLabel;
    case "project-status":
      return hasStatus;
    case "label-and-status":
      return hasLabel && hasStatus;
    case "label-or-status":
    default:
      return hasLabel || hasStatus;
  }
}

async function fetchDispatchIssues() {
  const issues = await fetchOpenIssues();
  return issues.filter(isDispatchEligible);
}

// ── PR detection ──────────────────────────────────────────────────────────────

async function detectPRs(workspacePath) {
  const issueNumber = fs.existsSync(path.join(workspacePath, ".symphony-issue"))
    ? fs.readFileSync(path.join(workspacePath, ".symphony-issue"), "utf8").trim()
    : null;
  if (!issueNumber) return [];

  try {
    const branchOut = await gh(["pr", "list", "--state", "open", "--head", branchName(issueNumber), "--json", "number,title,url", "--jq", ".[].url"]);
    const branchPrs = branchOut.trim().split("\n").filter(Boolean);
    if (branchPrs.length > 0) return branchPrs;

    const issueOut = await gh([
      "pr", "list",
      "--state", "open",
      "--search", `repo:${REPO} "#${issueNumber}" in:title,body`,
      "--json", "number,title,url",
      "--jq", ".[].url",
    ]);
    return issueOut.trim().split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

async function fetchPRState(prUrl) {
  const match = String(prUrl || "").match(/\/pull\/(\d+)/);
  if (!match) return null;
  try {
    const out = await gh(["pr", "view", match[1], "--json", "number,state,url,headRefName,baseRefName,mergedAt,closedAt"]);
    return JSON.parse(out);
  } catch (err) {
    log(`[fetchPRState] failed for ${prUrl}: ${err.message}`);
    return null;
  }
}

async function commentIssue(issueNumber, body) {
  try {
    await gh(["issue", "comment", String(issueNumber), "--body", body]);
  } catch (err) {
    log(`[commentIssue] failed for #${issueNumber}: ${err.message}`);
  }
}

async function reconcilePRReady() {
  let changed = false;
  for (const [key, info] of Object.entries(state.prReady)) {
    const pr = await fetchPRState(info.prUrl);
    if (!pr) continue;

    if (pr.state === "MERGED") {
      state.completed[key] = {
        completedAt: Date.now(),
        exitCode: info.exitCode ?? 0,
        mode: "merged",
        prUrl: pr.url,
        mergedAt: pr.mergedAt,
        workspacePath: info.workspacePath,
        branch: info.branch || pr.headRefName,
      };
      delete state.prReady[key];
      delete state.reviewed[key];
      delete state.blocked[key];
      log(`[#${key}] PR merged; lifecycle completed: ${pr.url}`);
      changed = true;
    } else if (pr.state === "CLOSED") {
      state.blocked[key] = {
        blockedAt: Date.now(),
        exitCode: info.exitCode ?? 0,
        mode: "closed-pr",
        reason: `PR closed before merge: ${pr.url}`,
        prUrl: pr.url,
        closedAt: pr.closedAt,
        workspacePath: info.workspacePath,
        branch: info.branch || pr.headRefName,
      };
      delete state.prReady[key];
      log(`[#${key}] PR closed before merge; marked blocked: ${pr.url}`);
      changed = true;
    }
  }
  if (changed) saveState();
}

// ── Backoff calculation ───────────────────────────────────────────────────────

function backoffMs(attempt) {
  return Math.min(10_000 * Math.pow(2, attempt - 1), MAX_BACKOFF_MS);
}

// ── Workspace management ──────────────────────────────────────────────────────

function sanitizeKey(str) {
  return String(str).replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80);
}

function branchName(issueNumber) {
  return `codex/symphony-${issueNumber}`;
}

function ensureWorkspaceRoot() {
  if (!fs.existsSync(WORKSPACE_ROOT)) {
    fs.mkdirSync(WORKSPACE_ROOT, { recursive: true });
    log(`Created workspace root: ${WORKSPACE_ROOT}`);
  }
}

function submoduleReferencePath(submodulePath) {
  const referencePath = path.join(REPO_ROOT, submodulePath);
  if (!fs.existsSync(referencePath)) return null;
  try {
    execSync(`git -C ${JSON.stringify(referencePath)} rev-parse --is-inside-work-tree`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    return null;
  }
  return referencePath;
}

function submoduleNeedsInitialization(ws, submodulePath) {
  const targetPath = path.join(ws, submodulePath);
  if (!fs.existsSync(path.join(targetPath, ".git"))) return true;
  try {
    execSync(`git -C ${JSON.stringify(targetPath)} rev-parse --is-inside-work-tree`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return false;
  } catch {
    return true;
  }
}

async function ensureRequiredSubmodules(ws, options = {}) {
  const { allowUpdate = true } = options;

  for (const submodulePath of REQUIRED_SUBMODULES) {
    const needsInitialization = submoduleNeedsInitialization(ws, submodulePath);

    if (!allowUpdate && !needsInitialization) {
      log(`[ensureWorkspace] ${submodulePath} already initialized; preserving dirty workspace checkout`);
      continue;
    }

    const referencePath = submoduleReferencePath(submodulePath);
    const bootstrapScript = path.join(REPO_ROOT, "scripts", "bootstrap-submodules.sh");

    if (fs.existsSync(bootstrapScript)) {
      const env = {
        ...process.env,
        PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        REMCLAW_REQUIRED_SUBMODULES: submodulePath,
      };
      if (referencePath) {
        env.REMCLAW_SUBMODULE_REFERENCE_ROOT = REPO_ROOT;
        log(`[ensureWorkspace] using local reference for ${submodulePath}: ${referencePath}`);
      }

      log(`[ensureWorkspace] bootstrapping submodule ${submodulePath} in ${ws}`);
      await runCommand(bootstrapScript, [], { cwd: ws, env });
      continue;
    }

    const args = ["submodule", "update", "--init", "--recursive", "--jobs", "4"];
    if (referencePath) args.push("--reference", referencePath);
    args.push("--", submodulePath);
    log(`[ensureWorkspace] initializing submodule ${submodulePath} in ${ws}`);
    await git(args, { cwd: ws });
  }
}

async function ensureWorkspace(issue, mode) {
  const key = sanitizeKey(`${issue.number}-${issue.title}`);
  const ws = path.join(WORKSPACE_ROOT, key);

  if (!fs.existsSync(WORKSPACE_ROOT)) {
    fs.mkdirSync(WORKSPACE_ROOT, { recursive: true });
    log(`Created workspace root: ${WORKSPACE_ROOT}`);
  }

  if (fs.existsSync(ws)) {
    log(`Workspace already exists for #${issue.number}: ${ws}`);
  } else {
    const tmp = path.join(WORKSPACE_ROOT, `.tmp-${key}`);

    try {
      if (fs.existsSync(tmp)) fs.rmSync(tmp, { recursive: true });
      if (fs.existsSync(ws)) fs.rmSync(ws, { recursive: true });

      log(`[ensureWorkspace] cloning to ${tmp}...`);
      const gitOut = await git(["clone", "--branch", "staging", "--single-branch", `https://github.com/${REPO}.git`, tmp], { cwd: WORKSPACE_ROOT });
      log(`[ensureWorkspace] clone output: ${gitOut.slice(0, 100)}`);
      fs.renameSync(tmp, ws);
    } catch (err) {
      // Clean up partial clone on failure
      try { if (fs.existsSync(tmp)) fs.rmSync(tmp, { recursive: true }); } catch {}
      try { if (fs.existsSync(ws)) fs.rmSync(ws, { recursive: true }); } catch {}
      log(`Clone failed for #${issue.number}: ${err.message}`);
      return null;
    }
  }

  // Ensure workspace is on correct branch
  try {
    const dirty = (await git(["status", "--porcelain"], { cwd: ws })).trim();
    const currentBranch = (await git(["branch", "--show-current"], { cwd: ws })).trim();
    const targetBranch = branchName(issue.number);
    if (currentBranch !== targetBranch) {
      await git(["checkout", "-B", targetBranch], { cwd: ws });
    }
    if (!dirty) {
      await git(["pull", "--ff-only", "origin", "staging"], { cwd: ws });
    } else {
      log(`[ensureWorkspace] #${issue.number} workspace has local changes; skipping pull`);
    }
  } catch (err) {
    log(`Branch setup failed for #${issue.number}: ${err.message}`);
  }

  try {
    const dirty = (await git(["status", "--porcelain"], { cwd: ws })).trim();
    await ensureRequiredSubmodules(ws, { allowUpdate: !dirty });
  } catch (err) {
    log(`Submodule bootstrap failed for #${issue.number}: ${err.message}`);
    return null;
  }

  fs.writeFileSync(path.join(ws, ".symphony-issue"), String(issue.number));
  fs.writeFileSync(path.join(ws, ".symphony-mode"), mode);
  return ws;
}

// ── Prompt builders ──────────────────────────────────────────────────────────

function buildDispatchPrompt(issue, attempt) {
  const attemptNote = attempt > 1
    ? `\n\n> **Retry attempt ${attempt}** — previous attempt(s) did not complete the work. The workspace still has your prior changes. Pick up from where you left off.\n> Previous error: see .symphony-error in your workspace.`
    : "";
  const labelsNote = issue.labels.length ? `\n\n> **Labels:** ${issue.labels.join(", ")}` : "";
  const body = issue.body ? `\n\n## Issue Description\n\n${issue.body}` : "";

  return `# Issue #${issue.number}: ${issue.title}${labelsNote}

**URL:** ${issue.url}${body}${attemptNote}

## Dispatch Metadata

- Labels: ${issue.labels.join(", ") || "(none)"}
- Project: ${issue.projectTitle ?? "(unknown)"}
- Project status: ${issue.status ?? "(none)"}
- Branch: ${branchName(issue.number)}

## Your Task

1. **Understand** the issue and its description above.
2. **Explore** the codebase (\`git status\`, \`rg\`, \`ls\`).
3. **Implement** the solution.
4. **Run tests**: \`make lint\` must pass, \`make test\` must pass.
5. **For UI changes**, follow \`docs/VISUAL_QA.md\`: capture the exact changed state, include at least one real click-through, and save durable evidence under \`docs/screenshots/issue-${issue.number}/\` or a stable GitHub attachment. A launch screenshot is not enough.
6. **Commit** your changes.
7. **Push** and **create a PR** to \`staging\`. PR title must include "Closes #${issue.number}".
8. **Post a comment** on the GitHub issue: "PR ready at https://github.com/${REPO}/pull/<number>"
9. Make the PR easy to finish: include validation commands, visual evidence paths for UI work, reviewer notes if available, and any known blockers. Completion is not the same as merge; the orchestrator owns merge or blocked state.

## Constraints

- Never push to \`main\`.
- Follow existing code style (SwiftLint: \`.swiftlint.yml\`, Swift format, TypeScript).
- Add tests for new functionality.
- Update relevant folder \`README.md\` files when touching new areas.
- If a build fails, fix the build before claiming done.
- If the task touches a stateful flow, include "States and transitions" in the PR body.
- For Mac/iOS visual changes, use \`peekaboo\`, Computer Use, or simulator tooling. If a state depends on gateway/backend data, add a fixture, mock, seeded state, or test mode before claiming visual QA.

## Workspace

Work in: ${path.join(WORKSPACE_ROOT, sanitizeKey(`${issue.number}-${issue.title}`))}

The workspace has the RemClaw repo cloned on branch \`${branchName(issue.number)}\`.
Required submodules are initialized during dispatch bootstrap: ${REQUIRED_SUBMODULES.join(", ") || "(none)"}.
If the workspace already exists from a previous attempt, \`git pull origin staging\` to get latest changes.
Before final validation or visual testing, refresh against latest \`origin/staging\` so evidence reflects current product UI.
`;
}

function buildReviewPrompt(issue, prUrl, attempt) {
  const attemptNote = attempt > 1 ? `\n\n> **Retry attempt ${attempt}** — pick up from where you left off.` : "";
  return `# Code Review: Issue #${issue.number}

**Issue:** ${issue.title}
**PR:** ${prUrl}${attemptNote}

## Your Task

You are an independent code reviewer. Your job:

1. **Read the issue** description at the GitHub URL above.
2. **Fetch the PR** — check \`git log\` in the workspace for recent commits.
3. **Review the code changes** — \`git diff origin/staging\` shows what changed.
4. **Verify** the implementation matches the issue description.
5. **Test the code** — run \`make lint\` and \`make test\`.
6. **Post your review** as a GitHub PR review comment on the PR at: ${prUrl}
7. Use the GitHub CLI: \`gh pr review <pr-number> --approve\` (if good) or \`--request-changes\` with comments.

## Constraints

- Be constructive and specific. Reference the actual code.
- If you find bugs, say exactly what's wrong and which file/line.
- Approve only if \`make lint\` + \`make test\` pass.
- Do not re-implement — only review and comment.
- If the PR is not ready (missing tests, failing lint, wrong approach), request changes with specific feedback.

## Workspace

${path.join(WORKSPACE_ROOT, sanitizeKey(`${issue.number}-${issue.title}`))}
`;
}

// ── Dispatch ─────────────────────────────────────────────────────────────────

async function dispatchIssue(issue, mode = "dispatch", attempt = 1) {
  const ws = await ensureWorkspace(issue, mode);
  if (!ws) return false;
  issue.workspacePath = ws;

  const prompt = mode === "review"
    ? buildReviewPrompt(issue, issue.prUrl, attempt)
    : buildDispatchPrompt(issue, attempt);

  fs.writeFileSync(path.join(ws, ".symphony-prompt.md"), prompt);
  fs.writeFileSync(path.join(ws, ".symphony-attempt"), String(attempt));

  log(`[${mode}] Dispatching #${issue.number} "${issue.title}" (attempt ${attempt}) -> ${ws}`);

  const promptFile = path.join(ws, ".symphony-prompt.md");
  const codexArgs = [
    "exec",
    "--cd", ws,
    "--sandbox", CODEX_SANDBOX,
    "-",
  ];
  if (CODEX_MODEL) codexArgs.splice(1, 0, "--model", CODEX_MODEL);

  const child = spawn(CODEX, codexArgs, {
    cwd: ws,
    env: {
      ...process.env,
      PATH: `${path.dirname(CODEX)}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdin.write(fs.readFileSync(promptFile, "utf8"));
  child.stdin.end();

  const pid = child.pid;
  state.running[issue.number] = { pid, startedAt: Date.now(), workspacePath: ws, mode, branch: branchName(issue.number) };
  saveState();

  child.stdout.on("data", d => log(`[codex:#${issue.number}] ${d.toString().slice(0, 200)}`));
  child.stderr.on("data", d => log(`[codex:#${issue.number}:err] ${d.toString().slice(0, 200)}`));

  child.on("exit", async (code, signal) => {
    log(`[#${issue.number}] codex exec exited (code=${code}, signal=${signal})`);
    delete state.running[issue.number];

    if (mode === "dispatch" && code === 0) {
      const prs = await detectPRs(ws);
      const prUrl = prs[0] || null;
      if (prUrl) {
        state.prReady[issue.number] = { readyAt: Date.now(), exitCode: code, mode, prUrl, workspacePath: ws, branch: branchName(issue.number) };
        delete state.retrying[issue.number];
        saveState();
        log(`[#${issue.number}] PR detected: ${prUrl}`);
      } else {
        log(`[#${issue.number}] codex exited 0 without detected PR for branch ${branchName(issue.number)}; retrying instead of marking complete`);
        scheduleRetry(issue, code, "no PR detected", attempt);
      }
    } else if (mode === "review") {
      state.reviewed[issue.number] = { reviewedAt: Date.now(), exitCode: code, mode, prUrl: issue.prUrl, workspacePath: ws };
      saveState();
    } else {
      scheduleRetry(issue, code, signal, attempt);
    }
  });

  return true;
}

// ── Retry scheduling ─────────────────────────────────────────────────────────

function scheduleRetry(issue, exitCode, signal, currentAttempt = 1) {
  const key = String(issue.number);
  const prev = state.retrying[key];
  const attempt = prev ? prev.attempt + 1 : currentAttempt + 1;

  if (attempt > MAX_RETRIES) {
    log(`[#${issue.number}] Max retries (${MAX_RETRIES}) exceeded. Giving up.`);
    state.blocked[key] = {
      blockedAt: Date.now(),
      exitCode,
      mode: "dispatch",
      reason: `max retries exceeded after exit ${exitCode} (${signal ?? "no signal"})`,
      workspacePath: issue.workspacePath ?? null,
      branch: branchName(issue.number),
    };
    delete state.retrying[key];
    saveState();
    commentIssue(issue.number, [
      "Symphony marked this issue blocked after max retry exhaustion.",
      "",
      `Reason: max retries exceeded after exit ${exitCode} (${signal ?? "no signal"}).`,
      `Branch: ${branchName(issue.number)}`,
      issue.workspacePath ? `Workspace: ${issue.workspacePath}` : null,
      "",
      "Next action: inspect the workspace/branch, repair manually, then redispatch or open a replacement issue.",
    ].filter(Boolean).join("\n"));
    return;
  }

  const delay = backoffMs(attempt);
  const dueAt = Date.now() + delay;

  state.retrying[key] = {
    attempt,
    dueAt,
    error: `exit ${exitCode} (${signal ?? "no signal"})`,
    workspacePath: issue.workspacePath ?? null,
    issue,
  };
  saveState();

  log(`[#${issue.number}] Scheduled retry ${attempt}/${MAX_RETRIES} in ${Math.round(delay / 1000)}s (at ${new Date(dueAt).toISOString()})`);

  setTimeout(async () => {
    if (!state.retrying[key]) return; // was cleared
    if (state.retrying[key].dueAt > Date.now()) return; // not yet

    delete state.retrying[key];
    if (state.prReady[issue.number] || state.completed[issue.number] || state.blocked[issue.number]) return;
    await dispatchIssue(issue, "dispatch", attempt);
  }, delay + 1000); // +1s buffer
}

// ── Concurrency guard ─────────────────────────────────────────────────────────

function canDispatch() {
  return Object.keys(state.running).length < MAX_CONCURRENT;
}

async function preflight({ verbose = true } = {}) {
  const checks = [];
  const record = (name, ok, detail) => checks.push({ name, ok, detail });

  try {
    await gh(["auth", "status", "--hostname", "github.com"]);
    record("GitHub auth", true, "gh authenticated");
  } catch (err) {
    record("GitHub auth", false, err.message);
  }

  try {
    const version = await runCommand(CODEX, ["--version"]);
    record("Codex CLI", true, version.trim());
  } catch (err) {
    record("Codex CLI", false, err.message);
  }

  try {
    const version = await runCommand("peekaboo", ["--version"]);
    record("Peekaboo", true, version.trim());
  } catch (err) {
    record("Peekaboo", false, `optional visual QA unavailable: ${err.message}`);
  }

  try {
    ensureWorkspaceRoot();
    fs.accessSync(WORKSPACE_ROOT, fs.constants.W_OK);
    record("Workspace root", true, WORKSPACE_ROOT);
  } catch (err) {
    record("Workspace root", false, err.message);
  }

  const ok = checks.filter(c => c.name !== "Peekaboo").every(c => c.ok);
  if (verbose) {
    console.log("=== Symphony Preflight ===");
    checks.forEach(c => console.log(`${c.ok ? "OK " : "ERR"} ${c.name}: ${c.detail}`));
    console.log(`Dispatch source: ${DISPATCH_SOURCE}`);
    console.log(`Dispatch label: ${DISPATCH_LABEL}`);
    console.log(`Dispatch statuses: ${DISPATCH_STATUSES.join(", ") || "(none)"}`);
    console.log(`Codex command: ${CODEX}`);
  }
  return { ok, checks };
}

// ── Reconciliation — clean up dead process entries ───────────────────────────

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // In sandboxed Codex runs, live sibling processes can be hidden from
    // signal checks. EPERM still means the PID exists, just not inspectable.
    if (err && err.code === "EPERM") return true;
    if (err && err.code === "ESRCH") return false;
    return false;
  }
}

function reconcile() {
  let changed = false;
  if (state.pid && !processExists(state.pid)) {
    log(`[reconcile] Clearing stale daemon PID ${state.pid}`);
    state.pid = null;
    changed = true;
  }
  for (const [key, info] of Object.entries(state.running)) {
    if (!processExists(info.pid)) {
      log(`[reconcile] Cleaning stale running entry #${key} (pid=${info.pid} dead)`);
      delete state.running[key];
      changed = true;
    }
  }
  if (changed) saveState();
}

// ── Poll loop ────────────────────────────────────────────────────────────────

let polling = true;
let pollTimer = null;

async function poll() {
  if (!polling) return;

  try {
    reconcile();
    await reconcilePRReady();

    // Check due retries
    const now = Date.now();
    for (const [key, entry] of Object.entries(state.retrying)) {
      if (entry.dueAt <= now) {
        if (canDispatch()) {
          log(`[retry] Firing due retry for #${key}`);
          const num = parseInt(key.replace("r-", ""));
          const currentIssues = await fetchOpenIssues();
          const issue = currentIssues.find(i => String(i.number) === String(num)) || entry.issue;
          if (!issue) {
            log(`[retry] Could not recover issue payload for #${key}; leaving retry queued`);
            continue;
          }
          delete state.retrying[key];
          await dispatchIssue(issue, "dispatch", entry.attempt);
        }
      }
    }

    log(`Poll (running=${Object.keys(state.running).length}/${MAX_CONCURRENT}, retrying=${Object.keys(state.retrying).length})`);
    state.lastPoll = new Date().toISOString();

    const pf = await preflight({ verbose: false });
    if (!pf.ok) {
      log(`Preflight failed; skipping dispatch this tick`);
      if (polling) pollTimer = setTimeout(poll, POLL_INTERVAL_MS);
      return;
    }

    const issues = await fetchDispatchIssues();
    if (issues.length > 0) log(`Found ${issues.length} dispatch-ready issue(s)`);

    for (const issue of issues) {
      if (!canDispatch()) {
        log("Concurrency full — skipping remaining");
        break;
      }
      try {
        await dispatchIssue(issue, "dispatch", 1);
      } catch (err) {
        log(`Dispatch error for #${issue.number}: ${err.message}`);
      }
    }
  } catch (err) {
    log(`Poll error: ${err.message}`);
  }

  if (polling) pollTimer = setTimeout(poll, POLL_INTERVAL_MS);
}

// ── Signal handling ───────────────────────────────────────────────────────────

function shutdown() {
  log("Shutting down...");
  polling = false;
  if (pollTimer) clearTimeout(pollTimer);
  for (const [key, info] of Object.entries(state.running)) {
    try { process.kill(info.pid, "SIGTERM"); log(`Killed #${key} pid=${info.pid}`); } catch {}
  }
  state.pid = null;
  saveState();
  log("Shutdown complete.");
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

// ── CLI ─────────────────────────────────────────────────────────────────────

const sub = process.argv[2];

// ── Start: fork to background ────────────────────────────────────────────────

async function cmdStart() {
  loadState();
  reconcile();

  // Check if already running
  if (state.pid) {
    if (processExists(state.pid)) {
      console.log(`Already running as PID ${state.pid}. Stop first: make symphony_stop`);
      process.exit(1);
    }
  }

  // Fork detached child
  const child = spawn(process.argv[0], [process.argv[1], "run"], {
    detached: true,
    stdio: "ignore",
    env: {
      ...process.env,
      PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      SYMPHONY_ROOT: WORKSPACE_ROOT,
      SYMPHONY_POLL_MS: String(POLL_INTERVAL_MS),
      SYMPHONY_MAX: String(MAX_CONCURRENT),
      SYMPHONY_MAX_RETRIES: String(MAX_RETRIES),
      SYMPHONY_DISPATCH_SOURCE: DISPATCH_SOURCE,
      SYMPHONY_DISPATCH_LABEL: DISPATCH_LABEL,
      SYMPHONY_DISPATCH_STATUSES: DISPATCH_STATUSES.join(","),
      SYMPHONY_CODEX: CODEX,
      SYMPHONY_CODEX_MODEL: CODEX_MODEL,
      SYMPHONY_CODEX_SANDBOX: CODEX_SANDBOX,
    },
  });

  child.unref();

  state.pid = child.pid;
  saveState();

  console.log(`Symphony forked to background (PID=${child.pid})`);
  console.log(`  Workspaces: ${WORKSPACE_ROOT}`);
  console.log(`  Poll: ${POLL_INTERVAL_MS}ms | Max agents: ${MAX_CONCURRENT} | Max retries: ${MAX_RETRIES}`);
  console.log(`  Dispatch: ${DISPATCH_SOURCE} label=${DISPATCH_LABEL} statuses=${DISPATCH_STATUSES.join(",") || "(none)"}`);
  console.log(`  Codex: ${CODEX}`);
  console.log(`  Log: ${DAEMON_LOG}`);
}

// ── Run: actual daemon loop ───────────────────────────────────────────────────

async function cmdRun() {
  loadState();
  ensureWorkspaceRoot();
  log(`Symphony daemon started PID=${process.pid}`);
  log(`Config: root=${WORKSPACE_ROOT} poll=${POLL_INTERVAL_MS}ms max=${MAX_CONCURRENT} retries=${MAX_RETRIES} source=${DISPATCH_SOURCE} codex=${CODEX}`);
  await poll();
  setInterval(() => {}, 1e9);
}

// ── Stop ─────────────────────────────────────────────────────────────────────

async function cmdStop() {
  loadState();
  if (state.pid) {
    try {
      process.kill(state.pid, "SIGTERM");
      log(`Sent SIGTERM to ${state.pid}`);
    } catch (err) {
      if (err.code === "ESRCH") log(`PID ${state.pid} not found — already stopped`);
      else throw err;
    }
    state.pid = null;
    saveState();
  } else {
    log("No daemon PID in state.");
  }
}

// ── Status ──────────────────────────────────────────────────────────────────

async function cmdStatus() {
  loadState();
  reconcile();
  await reconcilePRReady();

  console.log("=== Symphony Status ===");
  console.log(`Workspaces: ${WORKSPACE_ROOT}`);
  console.log(`Poll: ${POLL_INTERVAL_MS}ms | Max agents: ${MAX_CONCURRENT} | Max retries: ${MAX_RETRIES}`);
  console.log(`Dispatch: ${DISPATCH_SOURCE} label=${DISPATCH_LABEL} statuses=${DISPATCH_STATUSES.join(",") || "(none)"}`);
  console.log(`Codex: ${CODEX}`);

  if (state.pid) {
    if (processExists(state.pid)) {
      console.log(`Daemon: PID=${state.pid} (alive)`);
    } else {
      console.log(`Daemon: PID=${state.pid} (stale — no process)`);
    }
  } else {
    console.log("Daemon: not running");
  }

  console.log(`\nLast poll: ${state.lastPoll ?? "never"}`);

  const running = Object.entries(state.running);
  console.log(`\nRunning (${running.length}):`);
  running.length === 0 ? console.log("  (none)") : running.forEach(([k, v]) => {
    console.log(`  #${k} mode=${v.mode} pid=${v.pid} ${Math.round((Date.now()-v.startedAt)/1000)}s ${v.workspacePath}`);
  });

  const retrying = Object.entries(state.retrying);
  console.log(`\nRetrying (${retrying.length}):`);
  retrying.length === 0 ? console.log("  (none)") : retrying.forEach(([k, v]) => {
    const due = new Date(v.dueAt).toISOString();
    console.log(`  #${k} attempt=${v.attempt} due=${due} error=${v.error}`);
  });

  const prReady = Object.entries(state.prReady).slice(-10);
  console.log(`\nPR ready, pending orchestrator review/merge (${prReady.length}):`);
  prReady.length === 0 ? console.log("  (none)") : prReady.forEach(([k, v]) => {
    const ts = new Date(v.readyAt).toLocaleString();
    const pr = v.prUrl ? ` PR=${v.prUrl}` : "";
    console.log(`  #${k} exit=${v.exitCode}${pr} at ${ts}`);
  });

  const blocked = Object.entries(state.blocked).slice(-10);
  console.log(`\nBlocked (${blocked.length}):`);
  blocked.length === 0 ? console.log("  (none)") : blocked.forEach(([k, v]) => {
    const ts = new Date(v.blockedAt).toLocaleString();
    console.log(`  #${k} ${v.reason ?? "blocked"} at ${ts}`);
  });

  const reviewed = Object.entries(state.reviewed).slice(-10);
  console.log(`\nReviewed, pending resolution/merge (${reviewed.length}):`);
  reviewed.length === 0 ? console.log("  (none)") : reviewed.forEach(([k, v]) => {
    const ts = new Date(v.reviewedAt).toLocaleString();
    const pr = v.prUrl ? ` PR=${v.prUrl}` : "";
    console.log(`  #${k} exit=${v.exitCode}${pr} at ${ts}`);
  });

  const completed = Object.entries(state.completed).slice(-10);
  console.log(`\nLifecycle completed (${completed.length}):`);
  completed.length === 0 ? console.log("  (none)") : completed.forEach(([k, v]) => {
    const ts = new Date(v.completedAt).toLocaleString();
    const label = v.failed ? " FAILED" : v.mode === "review" ? " reviewed" : "";
    const pr = v.prUrl ? ` PR=${v.prUrl}` : "";
    console.log(`  #${k} exit=${v.exitCode}${label}${pr} at ${ts}`);
  });
}

// ── Dispatch preview ─────────────────────────────────────────────────────────

async function cmdDispatch() {
  loadState();
  reconcile();
  const issues = await fetchDispatchIssues();
  if (issues.length === 0) { console.log("No dispatch-ready issues."); return; }
  issues.forEach(i => {
    const retrying = state.retrying[i.number] ? ` RETRY #${i.number} attempt ${state.retrying[i.number].attempt}` : "";
    const matchingStatuses = i.projectStatuses
      .filter(p => DISPATCH_STATUSES.includes(p.status))
      .map(p => `${p.title}:${p.status}`);
    const trigger = [
      i.labels.includes(DISPATCH_LABEL) ? `label:${DISPATCH_LABEL}` : null,
      matchingStatuses.length ? `status:${matchingStatuses.join(",")}` : null,
    ].filter(Boolean).join(" + ");
    console.log(`[#${i.number}] ${i.title} [${i.projectTitle ?? "no project"}: ${i.status ?? "no status"}]${retrying}`);
    console.log(`  Trigger: ${trigger || "(none)"} | Labels: ${i.labels.join(", ") || "(none)"}`);
    console.log(`  Branch: ${branchName(i.number)} | ${i.url}`);
  });
  console.log(`\n${issues.length} issue(s) ready for dispatch`);
}

async function cmdPreflight() {
  loadState();
  const result = await preflight();
  if (!result.ok) process.exit(1);
}

// ── Clean workspaces ─────────────────────────────────────────────────────────

async function cmdClean() {
  loadState();
  let count = 0;
  for (const [, info] of Object.entries(state.completed)) {
    if (info.workspacePath && fs.existsSync(info.workspacePath)) {
      fs.rmSync(info.workspacePath, { recursive: true, force: true });
      log(`Cleaned: ${info.workspacePath}`);
      count++;
    }
  }
  state.completed = {};
  saveState();
  console.log(`Removed ${count} workspace(s).`);
}

// ── CLI dispatch ─────────────────────────────────────────────────────────────

switch (sub) {
  case "start":    cmdStart(); break;
  case "run":      cmdRun(); break;
  case "stop":     cmdStop(); break;
  case "status":   cmdStatus(); break;
  case "dispatch": cmdDispatch(); break;
  case "preflight": cmdPreflight(); break;
  case "clean":    cmdClean(); break;
  default:
    console.log(`Usage: node scripts/symphony-daemon.js <command>

  start    Fork daemon to background
  stop     Stop the daemon
  status   Show running sessions, retry queue, completed
  preflight Validate gh, Codex, Peekaboo, and workspace setup
  dispatch Preview dispatch-ready issues
  clean    Remove completed workspaces

Env:
  SYMPHONY_ROOT=${WORKSPACE_ROOT}
  SYMPHONY_POLL_MS=${POLL_INTERVAL_MS}
  SYMPHONY_MAX=${MAX_CONCURRENT}
  SYMPHONY_MAX_RETRIES=${MAX_RETRIES}
  SYMPHONY_MAX_BACKOFF_MS=${MAX_BACKOFF_MS}
  SYMPHONY_DISPATCH_SOURCE=${DISPATCH_SOURCE}
  SYMPHONY_DISPATCH_LABEL=${DISPATCH_LABEL}
  SYMPHONY_DISPATCH_STATUSES=${DISPATCH_STATUSES.join(",")}
  SYMPHONY_CODEX=${CODEX}
  SYMPHONY_CODEX_MODEL=${CODEX_MODEL || "(default)"}
  SYMPHONY_CODEX_SANDBOX=${CODEX_SANDBOX}
`);
    process.exit(sub ? 1 : 0);
}
