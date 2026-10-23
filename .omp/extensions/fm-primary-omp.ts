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
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

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

export default function (pi: ExtensionAPI) {
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
  pi.on("session_stop", async (event) => {
    const payload = JSON.stringify({ stop_hook_active: event.stop_hook_active === true });
    const result = await run("fm-turnend-guard.sh", ["--omp"], payload);
    if (result.code !== 2) return {};
    return {
      decision: "block",
      reason: result.stderr.trim() || "TURN WOULD END BLIND - supervision is off; repair it before ending the turn.",
    };
  });
}
