#!/usr/bin/env bash
# fm-jev.sh - advisory Jev rankings for Firstmate decisions and worker models.
#
# Usage: fm-jev.sh [--models] <question-or-task> <context> <options-json>
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
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"
  exit 0
fi
exec python3 - "$@" <<'PY'
import json
import math
import re
import subprocess
import sys

THRESHOLD = 0.9


def fail(message):
    print("fm-jev: " + message + "; ask the captain (treat as below threshold)", file=sys.stderr)
    sys.exit(1)


args = sys.argv[1:]
models = bool(args and args[0] == "--models")
if models:
    args.pop(0)
if len(args) != 3 or not args[0].strip():
    fail("usage: fm-jev.sh [--models] <question-or-task> <context> <options-json>")
question, context, raw_options = args
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

request = {
    "model": "jev-latest",
    "state": {"context": context},
    "questions": {"ranking": {
        "type": "choice",
        "instructions": ("Which candidate worker model best fits this task? Task: " + question
                         if models else question),
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
