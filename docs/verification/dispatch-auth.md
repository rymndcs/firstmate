# Dispatch authentication verification

Audience: maintainer verification.

This record supports the dispatch judgment rules in `.agents/skills/quota-array-dispatch/SKILL.md` and the bounded vendor probe in `bin/fm-vendor-auth-probe.sh`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

Firstmate resolves a candidate's provider family, credential surface, and applicable capacity by reading the evidence below and reasoning in the open.
Capacity itself is read from `dispatch-axi`, which carries `quota-axi` as one of its sources; the `quota-axi` facts recorded here are the shape that source supplies and the credential surface `dispatch-axi` does not expose.
No script maps a model to a provider, a provider to a credential store, or a name prefix to a family, so the facts here are what that reasoning rests on.
Credential paths below are shown with the home directory replaced by `<home>`.

## Quota granularity the judgment depends on

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi --json` reports availability at whatever granularity the vendor supplies, and states the vendor's own bounding rule in `quotaSemantics.description`.

```json
{
  "provider": "codex",
  "state": { "status": "fresh", "stale": false },
  "quotaSemantics": {
    "status": "known",
    "description": "Codex base account windows bound every model. Named model windows add bounds for that model; code-review windows describe a separate workload and are not included in model availability.",
    "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly"] },
      { "scope": "model:codex_bengalfox", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly", "model:codex_bengalfox:7d"] }
    ]
  }
}
```

Three properties follow and are load-bearing for dispatch:

- An `all_models` (or `all_products`) scope is real evidence for every model in that provider family, including a model with no window of its own.
- A `model:`-scoped entry is an additional bound for that one model. `model:codex_bengalfox` is the GPT-5.3-Codex-Spark window and bounds nothing else.
- A named-model window can be tighter than the account bound, so it must not be read across models. In the same snapshot Claude reported `all_models` with `effectivePercentRemaining` 10 while `model:fable` reported 4, limited by the `model:fable` window itself. A non-Fable Claude model reads 10, not 4.

`quotaSemantics.status` is `unknown` with no `effectiveAvailability` entries at all for providers whose vendor exposes no window (observed for `cursor` and `copilot`).
`state.authStatus` is present only for some providers (observed for `grok` alone), so its absence is missing evidence, not a credential fault.

## Completion-runway shape the judgment depends on

Verified 2026-07-31 against quota-axi 0.1.17 schema 3.
The command below records the producer shape without persisting account-specific quota values:

```sh
quota-axi --json | jq '{schemaVersion, effectiveAvailabilityFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]? | keys] | unique), runwayFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.runway? | select(type == "object") | keys] | unique)}'
```

```json
{
  "schemaVersion": 3,
  "effectiveAvailabilityFields": [
    [
      "boundedBy",
      "effectivePercentRemaining",
      "limitingWindowIds",
      "pace",
      "runway",
      "scope",
      "status"
    ]
  ],
  "runwayFields": [
    [
      "limitingWindowId",
      "projectedExhaustedAt",
      "projectionBasis",
      "projectionConfidence",
      "status",
      "usableRunwaySeconds"
    ],
    [
      "limitingWindowId",
      "projectedExhaustedAt",
      "status",
      "usableRunwaySeconds"
    ]
  ]
}
```

`runway` is nested under each effective-availability scope, so the same provider/model applicability rules govern both effective headroom and runway.
Projection confidence and basis are not present on every known runway, so selection must preserve their absence as uncertainty rather than fabricate them.
The older-schema fallback contract is owned by `quota-array-dispatch`; this evidence does not reinterpret an absent runway or pace field.

## Provider-family counterfactual that this producer schema supports

Verified 2026-07-30 on Pi 0.82.0 and quota-axi 0.1.16.

```sh
pi --list-models terra
```

```text
provider      model          context  max-out  thinking  images
openai-codex  gpt-5.6-terra  272K     128K     yes       yes
```

The Pi catalog is authoritative for Pi model support and reports the provider family in its own column.
For `harness=pi`, `model=openai-codex/gpt-5.6-terra` the catalog establishes the model is supported and belongs to the `openai-codex` family, and the Codex `all_models` scope above supplies fresh, known 64 effective remaining for every model in that family.
No Terra-specific window exists in the snapshot, and `quota-axi auth --json` lists no `pi:openai-codex` source.
Both absences are missing model-level and source-level detail, not contradictory evidence, so this candidate is dispatchable with the model-level uncertainty disclosed.

```sh
pi --list-models gpt-9.9-nonexistent
```

```text
No models matching "gpt-9.9-nonexistent"
```

A listing that reaches the account and returns no row is the authoritative negative that does block a candidate.

## Credential sources are independent per provider

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi auth --json` reports each provider's credential sources separately, which is what lets a candidate be scoped to the one surface it actually authenticates through:

```json
[
  { "provider": "claude", "sources": [
      { "source": "oauth-file", "path": "<home>/.claude/.credentials.json", "status": "missing" },
      { "source": "keychain", "status": "available" } ] },
  { "provider": "codex", "sources": [
      { "source": "auth-json", "path": "<home>/.codex/auth.json", "status": "available" },
      { "source": "cli-rpc", "path": "<path-to>/codex", "status": "available" } ] },
  { "provider": "grok", "sources": [
      { "source": "auth-json", "path": "<home>/.grok/auth.json", "status": "available" },
      { "source": "pi:xai", "status": "available" } ] },
  { "provider": "kimi", "sources": [
      { "source": "pi:kimi-coding", "status": "available" },
      { "source": "kimi-code-cli", "status": "expired", "error": "kimi_code_cli_credential_expired" } ] }
]
```

Observed source statuses are `available`, `expired` (with an `error` slug), and `missing`.

- A provider can carry a healthy source beside a missing or expired one, so a provider must not be collapsed to a single status. Claude's `oauth-file` is missing while its keychain source is available, and Kimi's standalone CLI credential is expired while its Pi source is available.
- A `pi:`-prefixed source exists only where Pi holds its own credential for that family (`pi:xai`, `pi:kimi-coding`). Pi's `openai-codex` family has none, because it authenticates through the Codex store that the `codex` provider already lists. A missing `pi:` source is therefore never evidence against a Pi candidate.

Neither this per-source shape nor `state.authStatus` exists before quota-axi 0.1.16.
`bin/fm-bootstrap.sh` enforces that floor through `bin/fm-dispatch-axi-lib.sh`.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 41` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## The dispatch tool's own surface

Verified 2026-08-08 against the installed dispatch-axi and quota-axi 0.1.17.
dispatch-axi publishes no version string, so its contract is identified here by the `schemaVersion: 1` it reports in `--json`.

The two commands below record the producer shape without persisting account-specific capacity values:

```sh
dispatch-axi --json | jq '{schemaVersion, candidateKeys: ([.candidates[0] | keys]), runwayKeys: ([.candidates[0].runway | keys]), rankingKeys: ([.rankings[0] | keys]), top: [.candidates[].evidence | keys] | unique}'
```

```json
{
  "schemaVersion": 1,
  "candidateKeys": [
    [
      "errors",
      "evidence",
      "label",
      "provider",
      "runway",
      "source",
      "warnings"
    ]
  ],
  "runwayKeys": [
    [
      "limitingWindow",
      "projectedExhaustedAt",
      "projectionBasis",
      "projectionConfidence",
      "resetsAt",
      "runwayHuman",
      "runwaySeconds",
      "status"
    ]
  ],
  "rankingKeys": [
    [
      "provider",
      "rank",
      "runway_human"
    ]
  ],
  "top": [
    [
      "balance_usd",
      "daily_burn_usd",
      "granted_balance",
      "history_days",
      "history_note",
      "is_available",
      "topped_up_balance"
    ],
    [
      "effectiveAvailability"
    ],
    [
      "effectivePercentRemaining",
      "liveWindows",
      "worstReservePercentPoints"
    ]
  ]
}
```

```sh
dispatch-axi --json | jq '{topLevelKeys: keys, degradedSources, unrankedProviders: [.rankings[] | select(.rank == null) | .provider], rankedProviders: [.rankings[] | select(.rank != null) | .provider]}'
```

```json
{
  "topLevelKeys": [
    "candidates",
    "degradedSources",
    "generatedAt",
    "rankings",
    "schemaVersion",
    "warnings"
  ],
  "degradedSources": [],
  "unrankedProviders": [
    "cursor",
    "copilot",
    "grok",
    "kimi"
  ],
  "rankedProviders": [
    "deepseek",
    "claude",
    "codex"
  ]
}
```

```sh
dispatch-axi --json | jq '[.candidates[] | {provider, source, evidence: (.evidence|keys), runwayStatus: .runway.status, errors}]'
```

```json
[
  {
    "provider": "deepseek",
    "source": "balance",
    "evidence": [
      "balance_usd",
      "daily_burn_usd",
      "granted_balance",
      "history_days",
      "history_note",
      "is_available",
      "topped_up_balance"
    ],
    "runwayStatus": "low_confidence_balance",
    "errors": []
  },
  {
    "provider": "claude",
    "source": "window",
    "evidence": [
      "effectivePercentRemaining",
      "liveWindows",
      "worstReservePercentPoints"
    ],
    "runwayStatus": "through_reset",
    "errors": []
  },
  {
    "provider": "codex",
    "source": "window",
    "evidence": [
      "effectivePercentRemaining",
      "liveWindows",
      "worstReservePercentPoints"
    ],
    "runwayStatus": "projected_exhaustion",
    "errors": []
  },
  {
    "provider": "cursor",
    "source": "unknown",
    "evidence": [
      "effectiveAvailability"
    ],
    "runwayStatus": "unknown",
    "errors": [
      "sqlite3_unavailable",
      "No effectiveAvailability entries"
    ]
  },
  {
    "provider": "copilot",
    "source": "unknown",
    "evidence": [
      "effectiveAvailability"
    ],
    "runwayStatus": "unknown",
    "errors": [
      "GitHub Copilot sign-in required",
      "No effectiveAvailability entries"
    ]
  },
  {
    "provider": "grok",
    "source": "unknown",
    "evidence": [
      "effectiveAvailability"
    ],
    "runwayStatus": "unknown",
    "errors": [
      "Grok sign-in required",
      "No effectiveAvailability entries"
    ]
  },
  {
    "provider": "kimi",
    "source": "unknown",
    "evidence": [
      "effectiveAvailability"
    ],
    "runwayStatus": "unknown",
    "errors": [
      "kimi_credential_unavailable",
      "No effectiveAvailability entries"
    ]
  }
]
```

The runway field name differs by container and the difference is load-bearing: `candidates[].runway.runwayHuman` is camelCase, while the parallel `rankings[].runway_human` is snake_case.
`bin/fm-dispatch-axi-lib.sh` reads the camelCase `candidates[].runway.runwayHuman` and nothing else from `runway`, so that key is the one this record exists to pin.
`rankings[]` carries a `rank` of `null` for every provider `dispatch-axi` could not measure, which is what the reading records as an unranked candidate rather than dropping it.

The remaining observations are ones no command output can express:

- There is no `--version` and no `--help`. An unrecognized flag is ignored and the human report prints anyway, so any version probe reads a report as a version string. Both `dispatch-axi --version` and `dispatch-axi auth` were run and each printed the ranked report under its `═══ DISPATCH AXI ═══` heading and exited `0`. `bin/fm-bootstrap.sh` therefore presence-checks the tool and `bin/fm-dispatch-axi-lib.sh` validates `schemaVersion` where the tool is read.
- There is no auth subcommand and no credential field anywhere in the output. `quota-axi auth --json` remains the only per-provider credential surface, which is why the sections above stay authoritative and why `quota-axi` stays a required tool.
- Per-window percentages, per-window resets, `quotaSemantics.description`, and the named unmeasurable-window lists recorded above are consumed inside `dispatch-axi` and are not passed through on any shape. `liveWindows` still names a model-scoped window such as `model:fable`, which is the granularity signal the selection procedure relies on.

### Evidence shapes

`candidates[].evidence` is not one shape with optional keys, so it must be read by the keys actually present.
Three shapes appear in the snapshot pasted above.

- Balance, with `source: balance`, observed for `deepseek`: `balance_usd`, `granted_balance`, `topped_up_balance`, `daily_burn_usd`, `is_available`, `history_days`, and an optional `history_note`.
- Window, with `source: window`, observed for `claude` and `codex`: `effectivePercentRemaining`, `worstReservePercentPoints`, and `liveWindows`. This is the only shape carrying a headroom figure.
- Sentinel, with `source: unknown` and `runway.status: unknown`, observed for `cursor`, `copilot`, `grok`, and `kimi`: the single key `effectiveAvailability` whose value is the literal string `empty`, alongside an `errors` entry `No effectiveAvailability entries`.

That sentinel is a diagnostic marker meaning `quota-axi` returned no effective-availability entries for that provider.
It shares a key name with the rich `quotaSemantics.effectiveAvailability` array pinned at the top of this record and nothing else: it carries no `boundedBy`, no `limitingWindowIds`, no `pace`, and no per-scope `runway`.
Reading it as that array is the inference this paragraph exists to prevent.

The following variants did not occur in this snapshot and are recorded as code-derived claims, not as observed output, from the producing path `dispatch_axi/normalizer.py` in the `dispatch-axi` project.

- Window fallback, with `source: window`, `runway.status: window_fallback`, and `runway.projectionBasis: window_fallback`: `liveWindows` only, with no `effectivePercentRemaining` and no `worstReservePercentPoints`, alongside an `errors` entry `No effectiveAvailability entries; using window fallback`. It half-matches the window shape while carrying no headroom figure, which is why the selection procedure must test for the key rather than the `source`.
- Two further sentinels beside the observed one, each also `source: unknown` with `runway.status: unknown`: `raw_has_quota_semantics` set to `false` with an `errors` entry `No quotaSemantics in provider data`, and the key `effectiveAvailability[0]` set to `not a dict`.
- An entirely empty `evidence` object for a provider that is neither balance-shaped nor window-shaped, which carries only whatever `errors` the source supplied.

`.agents/skills/quota-array-dispatch/SKILL.md` owns how each shape is handled during selection; this record owns only what the shapes are.

## Standalone Grok discovery probe

Verified 2026-07-30 on `grok 0.2.117 (f1c06093089f) [stable]`.

```sh
grok --version
grok models   # stdin closed, single attempt, hard-bounded
```

Observed:

- `grok models` exits `0` and its first stdout line is `You are logged in with grok.com.` for an authenticated session.
- With a home directory holding no Grok credential, the first stdout line is `You are not authenticated.`, also with exit status `0`.
- Because the status is `0` in both cases, the exit status is not a verdict; only the literal first stdout line is examined, and a blank first line does not authenticate.
- `<home>/.grok/auth.json` was byte-identical across the authenticated run (`mtime`, `size`, and mode `0600` unchanged), so the probe is a read in that path.

These discriminator strings are un-owned vendor UI text.
`bin/fm-vendor-auth-probe.sh` pins the verified version, reports `versionVerified=no` when the running CLI differs, and classifies any unrecognized first line as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section and the pinned version together when the vendor CLI changes.

## Regression coverage

`tests/fm-vendor-auth-probe.test.sh` drives the real script against a fake vendor CLI that records every invocation's argv and anything readable on stdin.
It asserts that the script accepts no harness, model, or provider input, never calls `quota-axi`, exits alike for every probe result because it renders no verdict, invokes only the two fixed non-destructive argv forms with stdin closed, holds a real bound even when the configured bound is zero or malformed, and never echoes raw vendor output.
`tests/fm-spawn-dispatch-profile.test.sh` owns spawn's deterministic profile and harness refusals.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic and the dispatch-axi presence diagnostic, including that bootstrap never invokes dispatch-axi.
`tests/fm-spawn-dispatch-reading.test.sh` owns the spawn-boundary reading, including that an unrecognized `dispatch-axi` schema records `unavailable` rather than a guessed line, and that a snapshot with no usable candidate still records its named degraded source instead of collapsing to `unavailable`.
`tests/fm-quota-array-dispatch-live-e2e.test.sh` drives the public Pi skill-loading interface against one fake `dispatch-axi --json` snapshot per case, with a fake `quota-axi` beside it that fails and records any call, so a direct capacity read is caught.
It covers the Claude 1 percent versus Codex 55 percent reserve regression, explicit accounting for an unranked candidate, the strongest-reasoning constraint, and a stated override of a low-confidence cross-shape top rank.
