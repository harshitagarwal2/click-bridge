# Three Independent Clicks Design

**Archive status:** Historical approved design; not an active implementation
queue. The real-phone/Octo acceptance below remains `NOT RUN` until observed.

**Status:** Approved for implementation

**Date:** 2026-08-12

**Scope:** Change one successful Click Bridge logical `click` action into exactly three independent ordinary macOS left clicks without changing protocol v1, action identity, retry behavior, or phone result handling.

## Outcome

Every accepted phone input still creates one `action.request`, one `actionId`, one relay acknowledgement path, one Mac `action.result`, and at most one terminal-result haptic. Only `MacInputExecutor` expands the successful logical action into this physical sequence at the cursor position captured for the action:

```text
down(clickState=1) -> optional CLICK_GAP_MS -> up(clickState=1)
down(clickState=1) -> optional CLICK_GAP_MS -> up(clickState=1)
down(clickState=1) -> optional CLICK_GAP_MS -> up(clickState=1)
```

This is three ordinary clicks, not the macOS semantic triple-click gesture. Every down and up event keeps `mouseEventClickState = 1`; values `2` and `3` are never posted.

## Chosen Approach

The expansion belongs inside `MacInputExecutor`.

- **Chosen: one wire action, three Mac click pairs.** This preserves at-most-once action IDs, relay deduplication, one-in-flight behavior, expiry, cached results, and result-only haptics. The change stays at the physical-input adapter boundary.
- **Rejected: three phone or relay actions.** This would create three IDs or require a wire-schema change, add network latency, and weaken the existing deduplication contract.
- **Rejected: semantic click states `1`, `2`, `3`.** Applications may interpret that sequence as a triple-click command instead of three ordinary clicks.

`Constants.clickRepetitions` is the named runtime value and equals `3`. `MacInputExecutor` captures the cursor point once, constructs three distinct `ClickEventPair` values backed by six distinct `CGEvent` objects at that point, and validates the complete burst before posting anything. It then records the wall-clock timestamp immediately before the first down event and posts `down1/up1`, `down2/up2`, and `down3/up3`. If any of the six events cannot be created, the whole action returns event-creation failure with zero posts.

No inter-click sleep is added initially. `CLICK_GAP_MS` remains the optional down-to-up gap inside each click. Pair-to-pair execution stays immediate for lowest latency. If the physical Octo acceptance gate proves that immediate pairs are dropped, add only the smallest measured `interClickGapMs` in a separate TDD change; do not speculate one into the hot path.

## Invariants

- `ActionProcessor` calls `InputPosting.postLeftClickAtCurrentCursor()` once for a new valid `actionId`.
- Exact duplicates return the cached result and do not execute a second three-click burst.
- ID conflicts, expired actions, disabled remote control, missing permission, and event-creation failure post zero events.
- A Posted result contains the timestamp recorded immediately before the first mouse-down attempt in the three-click burst.
- One Posted logical action increments diagnostic counters by exactly `mouseDown +3` and `mouseUp +3` attempted posts.
- `CGEvent.post(tap:)` has no success result. A Posted terminal result and the diagnostic counters prove that Click Bridge invoked the six post calls; they do not prove that Octo accepted or acted on them.
- The wire action remains `{ "action": "click" }`; no repetition field, result field, version bump, or iOS-specific message is added.
- Phone clients retain one action in flight and produce one haptic only after the one matching Mac terminal result.

## Evidence Accounting

Benchmark and negative-matrix evidence must distinguish logical actions from physical clicks.

- Latency CSV rows and `logicalActionCount` remain one row/count per logical action.
- `mouseDownPostedUnixMs` remains the first down timestamp and therefore remains the actuation timestamp.
- For `N` Posted logical actions, exact Mac attempted-post evidence is `mouseDown +3N` and `mouseUp +3N`.
- For `N` Posted logical actions, authoritative target-observation evidence is an Octo increase of `3N`.
- A duplicate action-ID case proves one total burst: counters `+3/+3` and Octo `+3`, not `+6/+6`.
- Conflict, expiry, and other rejected cases remain `+0/+0` and Octo `+0`.
- A result-drop case still has one original execution: counters `+3/+3`, Octo `+3`, no replay.

The PWA benchmark validator owns a named physical-click multiplier of `3` for evidence checks. This mirrors `Constants.clickRepetitions` without adding physical behavior to the wire protocol.

## Product Copy and Documentation

Phone surfaces must say that one trigger produces three ordinary clicks while retaining one logical action:

- PWA primary control, hint, and install-manifest description;
- native iOS button, accessibility hint, App Intent title/description, and App Shortcut phrases;
- README, `FINAL-PLAN.md`, `benchmarks/README.md`, benchmark guidance, smoke matrices, physical acceptance, and iOS acceptance evidence.

Do not mechanically replace every use of “one action.” One input still produces one action ID, one request, one result, and one haptic. Only physical click and counter expectations change from one to three.

## Verification and Acceptance

Automated acceptance requires:

1. `MacInputExecutorTests` tags three distinct pairs and proves all three are constructed before `down1/up1`, `down2/up2`, and `down3/up3`; it also proves one within-click gap per pair, first-down timestamp, `+3/+3` attempted-post counters, and zero posts for nil or incomplete construction.
2. `ActionProcessorTests` continues proving that 1,000 concurrent duplicates call the poster once.
3. Benchmark tests require three physical clicks for each Posted logical action while retaining logical row counts.
4. Negative-matrix tests require `+3/+3` and Octo `+3` for duplicate/result-drop executions and zero for rejections.
5. Static verification finds only click-state value `1` in `MacInputExecutor`.
6. Full Node 24, macOS test, Release build, and generated-project checks pass.

Physical acceptance remains mandatory: with the installed Release Mac app, public OCI relay, a real phone, and an explicitly harmless Octo target, one accepted action must yield one terminal result, Mac attempted-post counters `+3/+3`, and Octo `+3`. One hundred distinct Posted actions must yield exactly `300` attempted down posts, `300` attempted up posts, and `300` Octo increments. Because `CGEvent.post` cannot report delivery, the Octo observation is authoritative for physical success; matching Mac counters are necessary supporting evidence. Until observed, this gate remains `NOT RUN`.
