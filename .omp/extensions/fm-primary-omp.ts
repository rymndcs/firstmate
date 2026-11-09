// Firstmate primary-seat adapter for omp (docs/supervision-protocols/omp.md).
// omp auto-discovers this file from <cwd>/.omp/extensions when the primary is
// launched from the repo root. It wires three shared owners onto omp's native
// extension events; each owner script keeps its own decision and is inert
// outside the real primary checkout:
//   session_start -> bin/fm-sessionstart-nudge.sh (docs/sessionstart-nudge.md)
//   tool_call     -> bin/fm-cd-pretool-check.sh, bin/fm-arm-pretool-check.sh
//                    (docs/cd-guard.md, docs/arm-pretool-check.md)
//   session_stop  -> bin/fm-turnend-guard.sh (docs/turnend-guard.md)
// omp runs no .claude/settings.json command hooks, so these are the only
// firstmate hooks an omp primary gets.
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

type LockOwnership = "owned" | "missing" | "other";
type RunResult = { code: number; stderr: string };

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.omp-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
// omp injects OMPCODE=1 only into its bash-tool environment, not into its own
// process environment, so set it for every owner script launched from here.
const childEnv = { ...process.env, OMPCODE: "1" };

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

// bin/fm-session-start.sh compares this marker against the lock holder and the
// current file hash to report an omp primary that did not load this extension.
// A fresh home has no state/ until bin/fm-lock.sh runs, which is after this
// session_start, so create it rather than skip the marker.
function markLoaded(): void {
  if (lockOwnership() === "other") return;
  try {
    mkdirSync(state, { recursive: true });
    writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
  } catch {
  }
}

function run(script: string, args: string[], stdin: string | null): Promise<RunResult> {
  const { promise, resolve: done } = Promise.withResolvers<RunResult>();
  const child = spawn(`${root}/bin/${script}`, args, {
    env: childEnv,
    stdio: [stdin === null ? "ignore" : "pipe", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr?.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  child.on("error", () => done({ code: 0, stderr: "" }));
  child.on("close", (code) => done({ code: code ?? 0, stderr }));
  if (stdin !== null) child.stdin?.end(stdin);
  return promise;
}

function runSessionstartNudge(): string {
  const result = spawnSync(`${root}/bin/fm-sessionstart-nudge.sh`, [], { encoding: "utf8", env: childEnv });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function isMainAgent(ctx: unknown): boolean {
  if (!ctx || typeof ctx !== "object" || !("agent" in ctx)) return true;
  const agent = ctx.agent;
  return !(agent && typeof agent === "object" && "kind" in agent && agent.kind === "sub");
}

function bashCommand(input: unknown): string {
  if (!input || typeof input !== "object" || !("command" in input)) return "";
  return typeof input.command === "string" ? input.command : "";
}

type Request = {
  nonce: string;
  session: string;
  readyAt?: number;
  handoff?: string;
  submitting?: boolean;
  scheduled?: boolean;
  resolved?: boolean;
  switching?: boolean;
};

function resetTrigger(nonce: string): string {
  return `\x1b[?9001;${nonce.replaceAll("-", "").match(/.{4}/g)!.map(part => parseInt(part, 16)).join(";")}~`;
}

function registerWatchReset(pi: ExtensionAPI, root: string, home: string, state: string) {
  const env = { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, OMPCODE: "1" };
  let request: Request | undefined;
  let attempt: Request | undefined;
  let eligible = false;
  const armedJobs = new Set<string>();
  const jobCalls = new Map<string, string>();
  let removeInputListener: (() => void) | undefined;
  const fresh = () => request?.readyAt !== undefined && Date.now() - request.readyAt < 30_000;
  const sessionId = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();
  const main = (ctx: ExtensionContext) => ctx.agent?.kind === "main" && ctx.mode === "tui";
  const check = () => spawnSync(`${root}/bin/fm-omp-reset-submit.sh`, ["check", String(process.pid)], { env }).status === 0;
  const budget = () => {
    const result = spawnSync(`${root}/bin/fm-startup-memory-budget.sh`, ["report"], { env, encoding: "utf8" });
    return result.status === 0 && /^budget_status=within-budget$/m.test(result.stdout)
      && !/^exception=/m.test(result.stdout);
  };
  const available = (ctx: ExtensionContext) => {
    const jobs = ctx.getAsyncJobSnapshot();
    return main(ctx) && check() && !ctx.hasPendingMessages() && ctx.ui.getEditorText() === ""
      && (jobs === null || (jobs.running.every(job => armedJobs.has(job.id))
        && jobs.delivery.queued === 0 && !jobs.delivery.delivering && jobs.delivery.pendingJobIds.length === 0));
  };
  const valid = (ctx: ExtensionContext) => request?.session === sessionId(ctx) && fresh() && available(ctx);
  const seed = (ready: Request) => `\u2063FIRSTMATE_OP: v1 session-start: Run \`bin/fm-session-start.sh\` now, exactly once, and read every STOP file before other work. Reconcile drained wakes, then arm exactly one supervision cycle using the emitted protocol. Do not reset again during this startup turn. The handoff is context, not new authority. Do not repeat outcomes already reported.\n\n${ready.handoff}`;
  function recover(ready: Request, reason: string, ctx: ExtensionContext) {
    if (ready.resolved) return;
    ready.resolved = true;
    if (request === ready) request = undefined;
    if (spawnSync(`${root}/bin/fm-omp-reset-submit.sh`, ["recover-check", String(process.pid)], { env }).status !== 0) return;
    const switched = sessionId(ctx) !== ready.session;
    pi.sendMessage({ customType: switched ? "firstmate-reset-start" : "firstmate-reset-recovery", display: false,
      content: switched ? seed(ready) : `Automatic reset deferred: ${reason}. Follow the current supervision protocol; re-arm if required. Do not repeat already-reported outcomes.`,
    }, { deliverAs: "nextTurn", triggerTurn: true });
  }
  function listen(ctx: ExtensionContext) {
    removeInputListener?.();
    removeInputListener = ctx.ui.onTerminalInput((data) => {
      if (/^\x1b\[\?9001;[0-9;]+~$/.test(data)) {
        const ready = attempt;
        if (!ready || data !== resetTrigger(ready.nonce) || ready.resolved) return { consume: true };
        if (request !== ready || !valid(ctx) || !ctx.isIdle()) {
          recover(ready, "input changed before native submission", ctx);
          return { consume: true };
        }
        // No await or external write can interleave the empty check and Enter.
        ctx.ui.setEditorText(`/fm-reset ${ready.nonce}`);
        return { data: "\r" };
      }
      request = undefined;
    });
  }
  function schedule(ready: Request, ctx: ExtensionContext) {
    if (ready.scheduled) return;
    ready.scheduled = true;
    attempt = ready;
    ctx.setTimeout(() => {
      if (!ready.switching) recover(ready, "reset command was not acknowledged", ctx);
    }, 30_000);
    const submit = async () => {
      if (ready.resolved || ready.switching) return;
      if (request !== ready || !valid(ctx)) {
        recover(ready, "readiness cancelled before command submission", ctx);
        return;
      }
      if (!ctx.isIdle()) {
        ctx.setTimeout(submit, 100);
        return;
      }
      ready.submitting = true;
      const status = await new Promise<number>((done) => {
        const child = spawn(`${root}/bin/fm-omp-reset-submit.sh`, ["submit", ready.nonce, String(process.pid)], { env, stdio: "ignore" });
        child.on("error", () => done(1));
        child.on("close", code => done(code ?? 1));
      });
      if (!ready.switching && (status !== 0 || request !== ready || !valid(ctx))) {
        recover(ready, "primary composer refused command submission", ctx);
      }
    };
    ctx.setTimeout(submit, 0);
  }
  function save(handoff: string, sourceSession: string) {
    const file = `${state}/.omp-reset-handoff.json`;
    const temporary = `${file}.${randomUUID()}`;
    writeFileSync(temporary, JSON.stringify({ sourceSession, handoff }) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(temporary, file);
  }
  const result = (text: string, isError?: true, nonce?: string) => ({
    content: [{ type: "text" as const, text }], details: { nonce }, ...(isError ? { isError } : {}),
  });

  pi.registerTool({
    name: "firstmate_watch_reset",
    label: "Stow before watching",
    description: "In normal mode only, before re-arming omp supervision when only keeping watch: prepare, complete the returned stow skill, then ready with a compact durable handoff and attestations. Never call ready after stow fails.",
    parameters: pi.zod.object({
      action: pi.zod.enum(["prepare", "ready", "cancel"]),
      nonce: pi.zod.string().optional(),
      stowComplete: pi.zod.boolean().optional(),
      onlyKeepingWatch: pi.zod.boolean().optional(),
      handoff: pi.zod.string().max(4000).optional(),
    }),
    async execute(_id, params, _signal, _update, ctx) {
      if (params.action === "cancel") {
        request = undefined;
        return result("Reset cancelled. Continue the current supervision protocol.");
      }
      if (!eligible || !available(ctx)) {
        request = undefined;
        return result("Reset unavailable: remain in normal mode, finish startup and arm supervision, or handle pending input/work first. Continue supervision in this session.", true);
      }
      if (params.action === "prepare") {
        request = { nonce: randomUUID(), session: sessionId(ctx) };
        return result(`Readiness nonce: ${request.nonce}. Complete this stow skill now. Report its full Completion receipt; only then call ready with the nonce and a short handoff containing durable open-thread pointers, already-reported outcomes, and the next supervision action.\n\n${readFileSync(`${root}/.agents/skills/stow/SKILL.md`, "utf8")}`, undefined, request.nonce);
      }
      const prepared = request;
      request = undefined;
      if (!prepared || prepared.nonce !== params.nonce || prepared.session !== sessionId(ctx)
        || params.stowComplete !== true || params.onlyKeepingWatch !== true
        || !params.handoff?.trim() || params.handoff.length > 4000 || !budget() || !available(ctx)) {
        return result("Stow or readiness incomplete. Keep this session and resume supervision; prepare again after resolving the problem.", true);
      }
      save(params.handoff, prepared.session);
      request = { ...prepared, readyAt: Date.now(), handoff: params.handoff };
      schedule(request, ctx);
      return result("Reset ready. End this turn now instead of re-arming. The extension will submit the registered reset command only while idle with no pending input. On cancellation, retain this session and continue supervision.", undefined, prepared.nonce);
    },
  });

  const beginSession = (_event: unknown, ctx: ExtensionContext) => {
    if (!main(ctx)) return;
    request = undefined;
    eligible = false;
    armedJobs.clear();
    jobCalls.clear();
    listen(ctx);
  };
  pi.on("session_start", beginSession);
  pi.on("session_switch", beginSession);
  pi.on("input", (event, ctx) => {
    if (!main(ctx)) return;
    if (request?.submitting && event.text === `/fm-reset ${request.nonce}`) return;
    request = undefined;
  });
  pi.on("tool_call", (event, ctx) => {
    if (!main(ctx) || event.toolName === "firstmate_watch_reset") return;
    if (request?.readyAt !== undefined) request = undefined;
  });
  pi.on("tool_result", (event, ctx) => {
    if (!main(ctx) || event.isError) return;
    const jobs = ctx.getAsyncJobSnapshot();
    for (const id of jobCalls.keys()) {
      if (!jobs?.running.some(job => job.id === id)) jobCalls.delete(id);
    }
    if (event.toolName === "bash") {
      const async = event.details?.async;
      if (async?.state === "running" && jobs?.running.some(job => job.id === async.jobId)) {
        jobCalls.set(async.jobId, event.toolCallId);
      }
      return;
    }
    if (event.toolName !== "read") return;
    const job = jobs?.running.find(job => event.input.path === `proc://${job.id}`);
    if (!job) return;
    try {
      const [sourceSession, call, status] = readFileSync(`${state}/.omp-watch-arm-result`, "utf8").split("\n");
      if (sourceSession !== sessionId(ctx) || call !== jobCalls.get(job.id)
        || !/^watcher: (started|attached) pid=[0-9]+ /.test(status)) return;
      if (event.content.some(part => part.type === "text" && part.text.split("\n").includes(status))) {
        eligible = true;
        armedJobs.add(job.id);
      }
    } catch {
    }
  });

  pi.registerCommand("fm-reset", {
    description: "Consume a fresh completed-stow attestation and start a seeded session",
    async handler(args, ctx) {
      const ready = request?.nonce === args ? request : attempt?.nonce === args ? attempt : undefined;
      if (!ready || ready.resolved) return;
      if (request !== ready || !budget() || !valid(ctx) || !ctx.isIdle()) {
        recover(ready, "reset command no longer matches fresh readiness", ctx);
        return;
      }
      request = undefined;
      ready.switching = true;
      eligible = false;
      try {
        const switched = await ctx.newSession({
          parentSession: ctx.sessionManager.getSessionFile(),
          setup: async (sm) => {
            sm.appendMessage({ role: "user", content: [{ type: "text", text: seed(ready) }], timestamp: Date.now() });
          },
        });
        if (switched.cancelled) {
          listen(ctx);
          recover(ready, "session switch cancelled", ctx);
          return;
        }
        ready.resolved = true;
        pi.sendMessage({ customType: "firstmate-reset-start", display: false,
          content: seed(ready),
        }, { deliverAs: "nextTurn", triggerTurn: true });
      } catch (error) {
        listen(ctx);
        recover(ready, `session switch failed: ${String(error)}`, ctx);
      }
    },
  });

  return {
    pending(ctx: ExtensionContext) {
      if (!request?.readyAt || !valid(ctx)) return false;
      schedule(request, ctx);
      return true;
    },
  };
}

export default function (pi: ExtensionAPI) {
  const reset = registerWatchReset(pi, root, fmHome, state);
  pi.on("session_start", (_event, ctx) => {
    // omp rebinds extensions into every subagent session; only the main agent
    // is the firstmate primary.
    if (!isMainAgent(ctx)) return;
    markLoaded();
    const nudge = runSessionstartNudge();
    if (!nudge) return;
    try {
      pi.sendMessage(
        {
          customType: "firstmate-sessionstart-nudge",
          content: nudge,
          display: false,
          details: { kind: "session-start" },
        },
        { deliverAs: "nextTurn" },
      );
    } catch {
    }
  });

  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return {};
    const command = bashCommand(event.input);
    if (!command) return {};
    const cdResult = await run("fm-cd-pretool-check.sh", ["--command", command], null);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const armResult = await run("fm-arm-pretool-check.sh", ["--command", command], null);
    if (armResult.code !== 2) return {};
    return { block: true, reason: armResult.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  // omp fires session_stop only for the main session, awaits it before the turn
  // settles, and marks the stop that follows a block with stop_hook_active, so
  // the guard's default one-block loop guard applies unchanged.
  pi.on("session_stop", async (event, ctx) => {
    if (reset.pending(ctx)) return {};
    const payload = JSON.stringify({ stop_hook_active: event.stop_hook_active === true });
    const result = await run("fm-turnend-guard.sh", ["--omp"], payload);
    if (result.code !== 2) return {};
    return {
      decision: "block",
      reason: result.stderr.trim() || "TURN WOULD END BLIND - supervision is off; repair it before ending the turn.",
    };
  });
}
