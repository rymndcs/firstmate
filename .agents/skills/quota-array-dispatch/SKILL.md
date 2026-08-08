---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from current dispatch-axi output, including its ranking, the runway and
  headroom evidence printed beside it, and when firstmate may override a rank.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the completion-aware profile-array selection procedure.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`dispatch-axi` ranks providers by runway and shows its working; it never selects, never spawns, and never knows what task you are dispatching.
`quota-axi` is a data source inside `dispatch-axi`, not something you read for capacity yourself.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
Deterministic shell owns only schema, configuration, and version validation plus concrete spawn safeguards; every model-to-provider, provider-to-credential, and capacity-applicability relation is yours to establish transparently and to show your evidence for.

## Why the ranking is an input and not the answer

A rank is one number over one axis: how long that provider can keep working.
Selection needs four things that number cannot contain - whether the candidate can do this task at all, which provider a `harness`/`model` tuple actually reaches, whether the candidate's own credential surface is usable, and how long *this* task will run.
So read the rank, then read the evidence beside it, then apply what the tool could not know.

The failure this procedure exists to prevent is not a wrong choice; it is an unexplainable one.
A full day of dispatches once went to a single provider and neither the captain nor firstmate could say why until the deciding comparison was reconstructed by hand.
A selection you cannot restate from named evidence is a defect even when the outcome happens to be right.

## Collect facts

Run `dispatch-axi --json` once per intake and reuse that snapshot for every candidate.
Do not take a second snapshot to settle a candidate.
Read `quota-axi auth --json` when a candidate's credential surface is in question; `dispatch-axi` exposes no auth surface, so that read stays direct and is the one capacity-adjacent tool call it does not own.

For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness.
Then, from the snapshot, record against the candidate's provider:

- task/profile fit and required reasoning class
- `rankings[].rank`, or unranked, and `runway.runwayHuman` with `runway.runwaySeconds`
- `runway.status`, `runway.projectionConfidence`, `runway.projectionBasis`, `runway.limitingWindow`, `runway.resetsAt`, and `runway.projectedExhaustedAt`
- `source`, which is `window`, `balance`, or `unknown` - the measurement shape
- `evidence.effectivePercentRemaining` and `evidence.liveWindows` for a window provider, or `evidence.balance_usd`, `evidence.daily_burn_usd`, and `evidence.history_days` for a balance provider
- `evidence.worstReservePercentPoints` for later diagnostic tie-breaking
- every entry in that candidate's `warnings` and `errors`
- the task-completion horizon and the evidence and confidence used to estimate it
- top-level `degradedSources` and `warnings`, which apply to the whole snapshot

`degradedSources` naming a source means the providers that source feeds are absent or unmeasured, not healthy and not empty.
Grok's prepaid credit balance is unrelated to a percentage window; never read one as the other.

### What the snapshot does not carry

`dispatch-axi` reports one effective figure per provider, not per window.
`evidence.effectivePercentRemaining` is already the bounded result across that provider's live windows, and `evidence.liveWindows` names which windows produced it, including a model-scoped one such as `model:fable`.
It does not carry per-window percentages, per-window reset times, `quotaSemantics.description`, or the named unmeasurable-window lists.

So apply the granularity rule in the form the snapshot supports:

1. Confirm the candidate's authoritative catalog lists its model and record the provider family the catalog reports.
   A model the authoritative catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
2. Read `evidence.liveWindows`.
   When no `model:` window is named, the effective figure is a provider-level bound and applies to every model you established in that family.
   When a `model:` window is named and it is the candidate's model, the figure is bounded for that candidate.
   When a `model:` window is named and it is a *different* model, the effective figure was bounded by a window the candidate does not use: that is disclosed uncertainty about this candidate, never its number.
3. Record what remains unknown instead of converting it into a verdict.

## Authentication is scoped to the selected surface

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.

Uncertainty and ineligibility are different findings:

- An unranked candidate, an `errors` entry such as a sign-in message, no matching auth source, an absent `state.authStatus`, an `unknown` measurement shape, or a surface the snapshot does not model at all is disclosed uncertainty.
  Keep the candidate eligible, state the unknown, and prefer known sustainable evidence when otherwise comparable.
- An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.
- Only concrete contradictory evidence blocks: an authoritative catalog proving the model unsupported, or proof that the credential the candidate actually selects is unusable.
- Reserve login wording for that proven-unusable case, and name the harness, model, surface, and evidence.

When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.

## Pace semantics

`worstReservePercentPoints` is the worst signed reserve across that provider's live windows, where reserve is remaining percentage minus elapsed-window percentage.
Negative reserve means usage is ahead of reset pace and creates conservation pressure.
Positive reserve means usage is behind reset pace, and zero is neutral.
An absent reserve figure is explicit uncertainty, not parser failure and not permission to assume health.

## Selection order

Apply only among candidates satisfying required fit and strongest reasoning class.
Never use rank, runway, headroom, pace, or reserve to silently replace that reasoning class.

1. Concrete contradictory evidence or malformed configuration: stop and report the tuple and that evidence.
   An unranked candidate, an unmeasured runway, a missing model-scoped window, and a credential surface the snapshot does not model are uncertainty, never this rule.
2. Honor any explicit captain instruction that sets a floor for that candidate before the generic comparison.
   Do not invent a generic percentage floor or treat a low percentage as an automatic failure.
3. Keep the strongest-reasoning class when every candidate is tight or completion evidence is poor.
   Dispatch inside that class when a candidate can proceed, or report that its strongest-class choice cannot proceed rather than downgrading it to conserve capacity.
4. Take `dispatch-axi`'s ranking among the remaining candidates as the default order, restricted to the providers your candidates actually reach.
   An unranked candidate is not last: it is unmeasured, stays eligible, and is compared under rule 7.
5. Check the ranking's own stated limits before relying on it, and go to rule 6 when any hold.
   The ranking is approximate across measurement shapes, so a `balance` provider ranked above a `window` provider on runway alone is not a settled comparison.
   A rank resting on `projectionConfidence: low` or a thin `projectionBasis` such as one day of burn history does not outrank established evidence.
   A `runway.status` that projects exhaustion inside the task's likely-completion horizon loses to one that projects through it, even when its raw runway number is larger.
6. Override the rank when the evidence beside it says to, and say so explicitly.
   State the rank you are not taking, the exact field that overrides it, and the candidate you chose instead - for example "not taking rank 1 deepseek: `projectionConfidence: low` on one day of burn history, against rank 3 claude's established `cycle_average` through the horizon".
   Fit, reasoning class, catalog evidence, authentication scoping, a candidate `warnings`/`errors` entry, a `degradedSources` entry covering that provider, and rule 5's limits are all legitimate grounds.
   A preference with no named field behind it is not.
7. Resolve remaining uncertainty explicitly.
   An authenticated candidate with unknown, unranked, or unmeasurable runway or headroom stays eligible and cannot be silently excluded or assumed sustainable.
   Never treat absent, `unknown`, or unmeasurable evidence as zero or as a healthy value, and never let it establish dominance in either direction.
   Prefer known viable evidence when otherwise comparable, and report uncertainty or ask the captain when it still prevents a justified choice.
8. Use pace and signed reserve only as later diagnostic tie-break evidence among candidates still unresolved after rank, runway, likely-completion viability, and uncertainty.
   Pace and reserve never rescue a clearly inferior completion prospect.
   Do not collapse these facts into an opaque composite score.
9. An unrecognized snapshot schema, a missing ranking, or absent runway and reserve fields: do not crash, fabricate a rank or runway, treat absence as healthy, or silently exclude a candidate.
   State which evidence is unavailable, retain the candidate, and apply only the comparisons the snapshot supports.
10. Genuine ties: stop and report every tied candidate for captain choice.
    Do not select by rank order when the rank is not what separates them, and never by array order, harness name, or another arbitrary identity ordering.
    Report duplicate concrete profiles as a configuration error.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable capacity and authentication facts, remaining uncertainty, fit and reasoning class, rank, runway and headroom, likely-completion reasoning, and later pace or reserve evidence when used.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label, and never with a bare "rank 1" either - the rank is evidence you cite, not a reason you give.
