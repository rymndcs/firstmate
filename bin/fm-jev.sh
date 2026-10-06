#!/usr/bin/env bash
# fm-jev.sh - advisory Jev rankings for Firstmate decisions and worker models.
#
# Usage:
#   fm-jev.sh --review-round <round-summary-file>
#   fm-jev.sh --models <brief-file> <options-json>
#   fm-jev.sh <question> <context-file> <options-json> [context-file ...]
# Context is always read from nonempty UTF-8 files; bare text is refused.
# Review mode reads the whole summary and fixes the question and three options.
# Model mode reads the brief's Task section, live dispatch-axi --json capacity
# (or an explicit failure notice), and the captain's model/effort limits.
# The dated Codex default applies through 2026-10-11.
# Options are a JSON array of 2-255 distinct nonempty strings. In --models mode,
# objects with a nonempty model and optional effort/description are also accepted.
# Output is one JSON object: confident=yes|no, threshold, mode, automatic=no,
# and rankings (option, probability, captain_permission_required), descending by
# probability with input order breaking ties. No option is selected or executed.
# confident reports whether the top option probability reaches threshold.
# --models always requires captain selection; Fable, gpt-6-astra and xhigh are
# additionally marked as requiring explicit permission, regardless of probability.
# Read confident rather than recreating the threshold. A nonzero exit means
# unavailable/below-bar: ask the captain, including before another review round.
# The key is read at each call from macOS Keychain service dev.friday.typesafe.
# It stays in memory and curl's stdin, never in files, arguments or environment.
# Requires python3, curl and macOS security. Requests use the live TypeSafe Choice
# API (https://docs.typesafe.ai/api), with no retries, logs or accounting.
set +x
set +v
set -eu
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit 0
fi
exec python3 - "$@" <<'PY'
import json
import math
from pathlib import Path
import re
import subprocess
import sys

THRESHOLD = 0.9


def fail(message):
    print("fm-jev: " + message + "; ask the captain (treat as below threshold)", file=sys.stderr)
    sys.exit(1)


def read_context(path):
    try:
        content = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError, ValueError):
        fail("context must come from readable UTF-8 files, never bare text: " + path)
    if not content.strip():
        fail("context file is empty: " + path)
    return content


args = sys.argv[1:]
models = bool(args and args[0] == "--models")
review = bool(args and args[0] == "--review-round")
if models or review:
    args.pop(0)
if review and len(args) == 1:
    context = read_context(args[0])
    question = "Should we start another review round, stop and land, or stop and drop?"
    raw_options = json.dumps(["start another round",
                              "stop and land with the open findings recorded", "stop and drop"])
elif models and len(args) == 2:
    brief = read_context(args[0])
    task = re.search(r"^# Task[ \t]*\r?\n(.*?)(?=^# |\Z)", brief, re.M | re.S)
    if not task or not task[1].strip():
        fail("brief file must contain a nonempty # Task section")
    context = "Task from brief:\n" + task[1]
    question = "Which candidate worker model best fits this task?"
    raw_options = args[1]
else:
    if models or review or len(args) < 3 or not args[0].strip() or args[0].startswith("--"):
        fail("usage: --review-round <summary-file>, --models <brief-file> <options-json>, "
             "or <question> <context-file> <options-json> [context-file ...]; bare text is refused")
    question, path, raw_options = args[:3]
    context = "\n\n".join(read_context(p) for p in [path] + args[3:])
try:
    options = json.loads(raw_options)
    if not isinstance(options, list) or not 2 <= len(options) <= 255:
        raise ValueError()
    for option in options:
        if isinstance(option, str) and option.strip():
            continue
        if (models and isinstance(option, dict)
                and isinstance(option.get("model"), str) and option["model"].strip()
                and isinstance(option.get("effort", ""), str)):
            continue
        raise ValueError()
    if len({json.dumps(o, sort_keys=True) for o in options}) != len(options):
        raise ValueError()
except (ValueError, TypeError):
    fail("options must be 2-255 distinct nonempty strings (or model objects in --models mode)")

if models:
    try:
        capacity = subprocess.run(["dispatch-axi", "--json"], capture_output=True,
                                  text=True, check=True, timeout=30).stdout
        if not capacity.strip():
            raise ValueError()
        json.loads(capacity)
    except (OSError, subprocess.SubprocessError, UnicodeError, ValueError):
        capacity = "dispatch-axi failed; current capacity is unavailable."
    context += "\n\nCurrent capacity (dispatch-axi):\n" + capacity
    context += ("\n\nCaptain's limits: Fable, gpt-6-astra and xhigh effort require explicit permission. "
                "Model selection always belongs to the captain. "
                "This week's default (2026-10-04 through 2026-10-11): every worker and scout uses "
                "Codex, gpt-6.1-sol recommended; do not offer Claude as a worker option. "
                "After 2026-10-11, the standing default returns to Claude first, "
                "then Codex and DeepSeek as overflow.")

request = {
    "model": "jev-latest",
    "state": {"context": context},
    "questions": {"ranking": {
        "type": "choice",
        "instructions": question,
        "criteria": {str(i): option for i, option in enumerate(options)},
    }},
}
try:
    credential = subprocess.run(
        ["security", "find-generic-password", "-s", "dev.friday.typesafe", "-w"],
        capture_output=True, text=True, check=True,
    ).stdout.rstrip("\r\n")
    if not credential or any(c in credential for c in "\r\n"):
        fail("TypeSafe Keychain credential is missing or invalid")
except (OSError, subprocess.SubprocessError, UnicodeError):
    fail("cannot read TypeSafe Keychain credential")

# curl's config stdin avoids exposing the credential in process arguments.
config = '\n'.join([
    'url = "https://api.typesafe.ai/v1/systemone"',
    'header = ' + json.dumps("Authorization: Bearer " + credential),
    'header = "Content-Type: application/json"',
    'data = ' + json.dumps(json.dumps(request)),
]) + '\n'
try:
    response = subprocess.run(
        ["curl", "--disable", "--silent", "--fail", "--connect-timeout", "5",
         "--max-time", "30", "--config", "-"],
        input=config, capture_output=True, text=True, check=True,
    ).stdout
except (OSError, subprocess.SubprocessError, UnicodeError):
    fail("Jev cannot be reached or rejected the request")

try:
    answer = json.loads(response)["answers"]["ranking"]
    probabilities = answer["probabilities"]
    if answer["type"] != "choice" or not isinstance(probabilities, dict):
        raise ValueError()
    if set(probabilities) != {str(i) for i in range(len(options))}:
        raise ValueError()
    if any(type(p) not in (int, float) or not math.isfinite(p) or not 0 <= p <= 1
           for p in probabilities.values()):
        raise ValueError()
    if not math.isclose(sum(probabilities.values()), 1, abs_tol=0.000001):
        raise ValueError()
    order = sorted(range(len(options)), key=lambda i: (-probabilities[str(i)], i))
    if answer["choice"] not in probabilities or probabilities[answer["choice"]] != probabilities[str(order[0])]:
        raise ValueError()
except (ValueError, TypeError, KeyError, OverflowError):
    fail("Jev returned an invalid or incomplete ranking")


def permission_required(option):
    if not models:
        return False
    identity = (option if isinstance(option, str)
                else option["model"] + " " + option.get("effort", ""))
    return bool(re.search(r"(?<![a-z0-9])(?:fable|gpt-6-astra|xhigh)(?![a-z0-9])", identity, re.I))


print(json.dumps({
    "confident": "yes" if probabilities[str(order[0])] >= THRESHOLD else "no",
    "threshold": THRESHOLD,
    "mode": "models" if models else "decision",
    "automatic": "no",
    "rankings": [{"option": options[i], "probability": probabilities[str(i)],
                  "captain_permission_required": permission_required(options[i])} for i in order],
}, ensure_ascii=False))
PY
