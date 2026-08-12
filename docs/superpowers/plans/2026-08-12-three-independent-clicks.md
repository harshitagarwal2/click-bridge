# Three Independent Clicks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Use xcodebuildmcp-cli for every Xcode build, test, and diagnostic command. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one successful Click Bridge logical action post exactly three independent ordinary left clicks on the Mac while preserving one action ID, one result, and one terminal-result haptic.

**Architecture:** Keep protocol v1 and every phone/relay action boundary unchanged. Expand only inside `MacInputExecutor`, then update benchmark and negative-matrix evidence to multiply each Posted logical action by three physical clicks.

**Tech Stack:** Swift 5.9, Core Graphics `CGEvent`, XCTest, Node.js 24, Node test runner, XcodeGen, XcodeBuildMCP CLI, existing Click Bridge protocol v1.

## Global Constraints

- Read `docs/superpowers/specs/2026-08-12-three-independent-clicks-design.md` before implementation; it is the approved design source.
- One accepted input still produces one immutable protocol-v1 `action.request`, one `actionId`, one terminal `action.result`, and at most one terminal-result haptic.
- Add `Constants.clickRepetitions = 3`; do not add a repetition field, new message type, action name, or protocol version.
- Capture the cursor point once, construct three distinct down/up pairs backed by six distinct `CGEvent` objects at that point, validate the complete burst before posting, then post the pairs in order. Every native down and up keeps `mouseEventClickState = 1`; never post semantic click states `2` or `3`.
- Return the timestamp captured immediately before the first down event.
- Increment diagnostic counters by exactly `mouseDown +3` and `mouseUp +3` attempted posts for one Posted logical action.
- `CGEvent.post(tap:)` returns no success value. Mac counters prove attempted post calls; Octo observation is authoritative for target acceptance.
- Construct and validate all three pairs before the first post. Nil or incomplete construction posts nothing and keeps counters unchanged.
- Keep `CLICK_GAP_MS` as the down-to-up delay inside every click. Add no inter-click delay unless physical Octo evidence proves immediate pairs are dropped.
- Keep one `ActionProcessor` poster call per new action ID. Exact duplicates return the cached result without another burst.
- Preserve PWA/native phone one-in-flight, no-queue, no-retry, expiry, reconnect, clock-health, and result-only haptic behavior.
- Keep latency rows and `logicalActionCount` logical; multiply only exact post-counter and Octo evidence by three.
- Do not claim physical success until a real phone, OCI relay, installed Release Mac app, and harmless Octo target pass the recorded gate.

## File Structure and Ownership

```text
mac/ClickBridgeMac/WireMessage.swift
  Owns Constants.clickRepetitions = 3.
mac/ClickBridgeMac/MacInputExecutor.swift
  Expands one InputPosting call into three ordinary click pairs.
mac/ClickBridgeMacTests/MacInputExecutorTests.swift
  Locks attempted-post order, timing, timestamp, counters, and failure behavior.
mac/ClickBridgeMacTests/ActionProcessorTests.swift
  Retains the one-poster-call deduplication invariant.

relay/public/benchmark-session.js
  Converts Posted logical-action count into exact attempted-post and Octo evidence.
relay/test/benchmark-session.test.js
  Locks the three-to-one evidence multiplier without changing row counts.
relay/scripts/run-negative-matrix.mjs
  Requires one attempted three-click burst plus matching Octo evidence for duplicate and result-drop cases.
relay/test/negative-matrix.test.js
  Locks positive and zero-post negative expectations.

relay/public/index.html
relay/public/manifest.webmanifest
relay/test/assets.test.js
ios/ClickBridgePhone/ContentView.swift
ios/ClickBridgePhone/ClickBridgeIntents.swift
  Explain that one trigger sends three ordinary clicks.

README.md
FINAL-PLAN.md
benchmarks/README.md
docs/benchmark.md
docs/smoke-test.md
docs/physical-smoke-test.md
docs/ios-acceptance.md
docs/superpowers/specs/2026-08-12-native-ios-volume-client-design.md
docs/superpowers/plans/2026-08-12-native-ios-volume-client.md
  Distinguish one logical action/result/haptic from three physical clicks.
```

No project file, package dependency, wire codec, relay routing, `ActionProcessor` production code, phone coordinator, or haptics implementation changes.

---

### Task 1: Expand the Mac physical-input adapter

**Files:**
- Modify: `mac/ClickBridgeMac/WireMessage.swift`
- Modify: `mac/ClickBridgeMac/MacInputExecutor.swift`
- Modify: `mac/ClickBridgeMacTests/MacInputExecutorTests.swift`
- Verify unchanged: `mac/ClickBridgeMac/ActionProcessor.swift`
- Verify: `mac/ClickBridgeMacTests/ActionProcessorTests.swift`

**Interfaces:**
- Consumes: `InputPosting.postLeftClickAtCurrentCursor() -> InputPostOutcome`
- Produces: one `.posted(mouseDownUnixMs:)` after six attempted post calls, or `.creationFailed` before any post.
- Preserves: one `ActionProcessor` call per unique accepted `actionId`.

- [ ] **Step 1: Change the executor test to require three independent pairs**

Replace the one-pair assertion with this exact behavioral shape:

```swift
func testOneLogicalPostConstructsThreePairsBeforeOrderedAttemptedPosts() {
    let trace = TraceRecorder()
    let executor = MacInputExecutor(
        clickGapMs: 7,
        constructEvents: {
            (1...3).map { pairID in
                trace.append("construct\(pairID)")
                return ClickEventPair.testing(pairID: pairID)
            }
        },
        postEvent: { trace.append("\($0.phase.rawValue)\($0.pairID)") },
        sleepMicroseconds: { trace.append("sleep-\($0)") },
        wallClockMilliseconds: { trace.append("timestamp"); return 1_234.5 }
    )

    guard case .posted(let timestamp) = executor.postLeftClickAtCurrentCursor() else {
        return XCTFail("expected posted")
    }

    XCTAssertEqual(timestamp, 1_234.5)
    XCTAssertEqual(trace.snapshot(), [
        "construct1", "construct2", "construct3", "timestamp",
        "down1", "sleep-7000", "up1",
        "down2", "sleep-7000", "up2",
        "down3", "sleep-7000", "up3",
    ])
    XCTAssertEqual(executor.diagnosticPostCounts(),
                   InputPostCounts(mouseDownPostCount: 3, mouseUpPostCount: 3))
}
```

Keep `testConstructionFailurePostsNothingAndKeepsCountersZero()` and add:

```swift
func testIncompleteBurstPostsNothingAndKeepsCountersZero() {
    let trace = TraceRecorder()
    let executor = MacInputExecutor(
        constructEvents: { [ClickEventPair.testing(pairID: 1),
                            ClickEventPair.testing(pairID: 2)] },
        postEvent: { _ in trace.append("posted") },
        sleepMicroseconds: { _ in }
    )

    XCTAssertEqual(executor.postLeftClickAtCurrentCursor(), .creationFailed)
    XCTAssertTrue(trace.snapshot().isEmpty)
    XCTAssertEqual(executor.diagnosticPostCounts(), .zero)
}
```

The nil-construction and incomplete-burst tests both prove that validation finishes before the first native side effect.

- [ ] **Step 2: Run the focused test and observe the intended failure**

```bash
xcodegen generate --spec mac/project.yml
xcodebuildmcp macos test \
  --project-path mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac \
  --extra-args '-only-testing:ClickBridgeMacTests/MacInputExecutorTests'
```

Expected: FAIL to compile because the constructor still returns one `ClickEventPair` and events do not expose the test pair ID.

- [ ] **Step 3: Add the named repetition constant**

Add to `Constants` in `WireMessage.swift`:

```swift
static let clickRepetitions = 3
```

Do not move this physical behavior into the protocol codec or an environment variable.

- [ ] **Step 4: Construct and validate three distinct pairs before posting**

Give test traces a pair identity, change the constructor to return the complete burst, and replace the one-pair implementation with this shape:

```swift
struct ClickEvent: @unchecked Sendable {
    let phase: ClickEventPhase
    let pairID: Int
    fileprivate let native: CGEvent?
    init(phase: ClickEventPhase, pairID: Int, native: CGEvent? = nil) {
        self.phase = phase
        self.pairID = pairID
        self.native = native
    }
}

struct ClickEventPair: @unchecked Sendable {
    let down: ClickEvent
    let up: ClickEvent
    static func testing(pairID: Int) -> ClickEventPair {
        ClickEventPair(down: ClickEvent(phase: .down, pairID: pairID),
                       up: ClickEvent(phase: .up, pairID: pairID))
    }
}

typealias EventConstruction = @Sendable () -> [ClickEventPair]?

func postLeftClickAtCurrentCursor() -> InputPostOutcome {
    guard let eventPairs = constructEvents(),
          eventPairs.count == Constants.clickRepetitions else {
        return .creationFailed
    }
    let mouseDownUnixMs = wallClockMilliseconds()
    for events in eventPairs {
        postEvent(events.down)
        lock.withLock {
            counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount + 1,
                                     mouseUpPostCount: counts.mouseUpPostCount)
        }
        if clickGapMs > 0 { sleepMicroseconds(clickGapMs * 1_000) }
        postEvent(events.up)
        lock.withLock {
            counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount,
                                     mouseUpPostCount: counts.mouseUpPostCount + 1)
        }
    }
    return .posted(mouseDownUnixMs: mouseDownUnixMs)
}

private static func makeNativeEvents() -> [ClickEventPair]? {
    guard let probe = CGEvent(source: nil) else { return nil }
    let point = probe.location
    let source = CGEventSource(stateID: .hidSystemState)
    var pairs: [ClickEventPair] = []
    pairs.reserveCapacity(Constants.clickRepetitions)

    for pairID in 1...Constants.clickRepetitions {
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            return nil
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        pairs.append(ClickEventPair(
            down: ClickEvent(phase: .down, pairID: pairID, native: down),
            up: ClickEvent(phase: .up, pairID: pairID, native: up)
        ))
    }
    return pairs
}
```

The single `point` capture fixes all six distinct native events to the same cursor coordinate. Returning `nil` from any iteration discards the locally constructed pairs before `postLeftClickAtCurrentCursor()` can invoke `postEvent`.

Do not add an inter-click scheduler, queue, timer, new protocol, or new executor type. `EventPosting` remains `@Sendable (ClickEvent) -> Void` because `CGEvent.post(tap:)` provides no delivery or acceptance result. Increment counters after each attempted call, and describe them as attempted-post counters rather than proof that Octo handled the click.

Retain these values for every one of the six events:

```swift
down.setIntegerValueField(.mouseEventClickState, value: 1)
up.setIntegerValueField(.mouseEventClickState, value: 1)
```

Do not reuse a `CGEvent` object across pairs and do not construct later pairs after the first post.

<!-- The former one-pair loop is deliberately replaced by the complete burst above. -->

```text
attempted order: down1, up1, down2, up2, down3, up3
```

The optional `CLICK_GAP_MS` sleep remains between each numbered down and its matching up. There is no sleep between `up1/down2` or `up2/down3`.

The counter updates remain:

```swift
postEvent(events.down)
lock.withLock {
    counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount + 1,
                             mouseUpPostCount: counts.mouseUpPostCount)
}
if clickGapMs > 0 { sleepMicroseconds(clickGapMs * 1_000) }
postEvent(events.up)
lock.withLock {
    counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount,
                             mouseUpPostCount: counts.mouseUpPostCount + 1)
}
```

Because the post API returns `Void`, these increments record attempted native submissions. The physical Octo counter remains the authoritative observation of application behavior.

- [ ] **Step 5: Run focused Mac tests and static click-state verification**

```bash
xcodebuildmcp macos test \
  --project-path mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac \
  --extra-args '-only-testing:ClickBridgeMacTests/MacInputExecutorTests'
xcodebuildmcp macos test \
  --project-path mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac \
  --extra-args '-only-testing:ClickBridgeMacTests/ActionProcessorTests'
rg -n 'mouseEventClickState' mac/ClickBridgeMac/MacInputExecutor.swift
```

Expected: both test classes PASS. The search prints exactly two assignments and both use `value: 1`; no `value: 2` or `value: 3` exists. The 1,000-duplicate test still reports one poster call.

- [ ] **Step 6: Commit the independently testable Mac change**

```bash
git add mac/ClickBridgeMac/WireMessage.swift \
  mac/ClickBridgeMac/MacInputExecutor.swift \
  mac/ClickBridgeMacTests/MacInputExecutorTests.swift
git commit -m "feat(mac): post three ordinary clicks per action"
```

### Task 2: Multiply benchmark physical evidence without changing logical rows

**Files:**
- Modify: `relay/public/benchmark-session.js`
- Modify: `relay/test/benchmark-session.test.js`

**Interfaces:**
- Consumes: Posted logical-action count, Mac counter snapshots, operator Octo start/end counts.
- Produces: exact-run validation against three physical clicks per Posted logical action.
- Preserves: one latency row and one `logicalActionCount` unit per action ID.

- [ ] **Step 1: Change benchmark tests to require the three-to-one multiplier**

Update successful fixtures so two Posted logical actions use counter snapshots `10/10 -> 16/16` and Octo `5 -> 11`. Update the exported evidence assertion to:

```js
assert.match(exported.evidence, /r,10,10,16,16,5,11,2/);
```

For the excluded warm-up test, three Posted logical actions require `10/10 -> 19/19` and Octo `5 -> 14`, while `logicalActionCount` remains `3`. Keep mismatch tests that independently reject incorrect down, up, and Octo deltas.

- [ ] **Step 2: Run the benchmark test and observe the intended failure**

```bash
node --test relay/test/benchmark-session.test.js
```

Expected: FAIL with `exact post evidence does not match logical actions` because production still expects one physical click per Posted action.

- [ ] **Step 3: Implement the named evidence multiplier**

At module scope in `benchmark-session.js`, add:

```js
export const PHYSICAL_CLICKS_PER_POSTED_ACTION = 3;
```

Rename the validation input to make its unit explicit:

```js
validateExactRun({ start, end, expectedPhysicalClickCount, octoCounterStart, octoCounterEnd }) {
  const delta = counterDelta(start, end);
  const octoDelta = octoCounterEnd - octoCounterStart;
  if (!Number.isSafeInteger(expectedPhysicalClickCount) || expectedPhysicalClickCount < 0
    || !Number.isSafeInteger(octoCounterStart) || !Number.isSafeInteger(octoCounterEnd)
    || delta.mouseDownPostCount !== expectedPhysicalClickCount
    || delta.mouseUpPostCount !== expectedPhysicalClickCount
    || octoDelta !== expectedPhysicalClickCount) {
    throw new Error('exact post evidence does not match logical actions');
  }
  return delta;
}
```

In `BenchmarkSession.finish`, preserve logical counting and calculate only the physical evidence value:

```js
const postedLogicalActionCount = this.excludedPosted
  + runRows.filter((row) => row.status === 'Posted').length;
const expectedPhysicalClickCount = postedLogicalActionCount
  * PHYSICAL_CLICKS_PER_POSTED_ACTION;
this.counterSnapshots.validateExactRun({
  start: this.run.start,
  end,
  expectedPhysicalClickCount,
  octoCounterStart,
  octoCounterEnd,
});
```

Do not multiply `runRows.length`, `logicalActionCount`, sample indexes, reliability totals, or percentile denominators.

- [ ] **Step 4: Run the benchmark tests**

```bash
node --test relay/test/benchmark-session.test.js
```

Expected: all benchmark-session tests PASS, including exact counter, Octo, warm-up, incomplete-run, and mismatch cases.

- [ ] **Step 5: Commit the benchmark evidence change**

```bash
git add relay/public/benchmark-session.js relay/test/benchmark-session.test.js
git commit -m "test(benchmark): count three physical clicks per action"
```

### Task 3: Update adversarial negative evidence

**Files:**
- Modify: `relay/scripts/run-negative-matrix.mjs`
- Modify: `relay/test/negative-matrix.test.js`

**Interfaces:**
- Consumes: one duplicate, conflict, expiry, or result-drop logical action scenario.
- Produces: explicit physical counter and Octo expectations for that scenario.
- Reuses: `PHYSICAL_CLICKS_PER_POSTED_ACTION` from `relay/public/benchmark-session.js`.

- [ ] **Step 1: Change negative-matrix fixtures to the three-click contract**

For `exact_duplicate` and `result_drop`, change fake Mac increments from `1/1` to `3/3` and operator Octo deltas from `1` to `3`. Keep `id_conflict` and `expired` at zero. Update the final expected Octo vector to:

```js
assert.deepEqual(report.map((row) => row.octoIncrement), [3, 0, 0, 3]);
```

Keep failure tests that use mismatched down/up counters, absent Octo evidence, or an unexpected second execution.

- [ ] **Step 2: Run the negative-matrix test and observe the intended failure**

```bash
node --test relay/test/negative-matrix.test.js
```

Expected: FAIL because production still requires `1/1` for the two executed scenarios.

- [ ] **Step 3: Apply the shared physical-click multiplier**

Import the named evidence constant:

```js
import { PHYSICAL_CLICKS_PER_POSTED_ACTION } from '../public/benchmark-session.js';
```

Use it for both protocol evidence and the expected Octo delta:

```js
const clicks = PHYSICAL_CLICKS_PER_POSTED_ACTION;
const cases = [
  ['exact_duplicate', duplicate, clicks, duplicate.exactCached
    && duplicate.mouseDownIncrement === clicks && duplicate.mouseUpIncrement === clicks],
  ['id_conflict', conflict, 0, conflict.reason === 'id_conflict'
    && conflict.mouseDownIncrement === 0 && conflict.mouseUpIncrement === 0],
  ['expired', expired, 0, expired.reason === 'expired'
    && expired.mouseDownIncrement === 0 && expired.mouseUpIncrement === 0],
  ['result_drop', dropped, clicks, !dropped.lateDelivery
    && dropped.totalDownIncrement === clicks && dropped.totalUpIncrement === clicks],
];
```

Do not send three requests and do not alter the action payload.

- [ ] **Step 4: Run both evidence suites**

```bash
node --test relay/test/negative-matrix.test.js relay/test/benchmark-session.test.js
```

Expected: both suites PASS. Duplicate/result-drop each prove one `+3/+3` burst; conflict/expiry prove zero.

- [ ] **Step 5: Commit the negative-evidence change**

```bash
git add relay/scripts/run-negative-matrix.mjs relay/test/negative-matrix.test.js
git commit -m "test(relay): verify three-click action evidence"
```

### Task 4: Make phone surfaces and canonical documentation truthful

**Files:**
- Modify: `relay/public/index.html`
- Modify: `relay/public/manifest.webmanifest`
- Modify: `relay/test/assets.test.js`
- Modify: `ios/ClickBridgePhone/ContentView.swift`
- Modify: `ios/ClickBridgePhone/ClickBridgeIntents.swift`
- Modify: `README.md`
- Modify: `FINAL-PLAN.md`
- Modify: `benchmarks/README.md`
- Modify: `docs/benchmark.md`
- Modify: `docs/smoke-test.md`
- Modify: `docs/physical-smoke-test.md`
- Modify: `docs/ios-acceptance.md`
- Modify: `docs/superpowers/specs/2026-08-12-native-ios-volume-client-design.md`
- Modify: `docs/superpowers/plans/2026-08-12-native-ios-volume-client.md`

**Interfaces:**
- Consumes: the implemented one-logical-action/three-physical-click contract.
- Produces: user-facing copy and verification guidance that distinguish action IDs from physical clicks.
- Preserves: protocol action string `click`, coordinator method names, and one result/haptic.

- [ ] **Step 1: Add a failing PWA asset-copy assertion**

In `relay/test/assets.test.js`, parse the shipped manifest beside the existing HTML fixture and add:

```js
const manifest = JSON.parse(readFileSync(join(PUBLIC, 'manifest.webmanifest'), 'utf8'));

test('primary control states the three-click physical outcome', () => {
  assert.match(html, />3 CLICKS<\/button>/);
  assert.match(html, /Three ordinary clicks at the Mac's current cursor/);
  assert.equal(manifest.description,
    "Post three ordinary left clicks at the Mac's current cursor.");
});
```

- [ ] **Step 2: Run the asset test and observe the intended failure**

```bash
node --test relay/test/assets.test.js
```

Expected: FAIL because `index.html` still says `CLICK`, its hint describes the old outcome, and the manifest still says `Post one left click`.

- [ ] **Step 3: Update the PWA and native phone copy**

Use this PWA copy:

```html
<button id="click-button" class="click" type="button" disabled>3 CLICKS</button>
<p class="hint">Three ordinary clicks at the Mac's current cursor</p>
```

Set the install-manifest description to this exact string:

```json
"description": "Post three ordinary left clicks at the Mac's current cursor."
```

Use `Trigger 3 Clicks` for the SwiftUI button, accessibility label, App Intent title, and shortcut short title. Use `Sends three ordinary clicks to the connected Mac` for the accessibility hint and `Open Click Bridge and send three ordinary clicks to the connected Mac.` for the intent description. Update shortcut phrases to `Trigger three clicks with ...` and `Click three times using ...`.

Do not rename `TriggerClickIntent`, `triggerClick()`, `PhoneActionCoordinator`, the wire action `click`, or any protocol type.

- [ ] **Step 4: Update evidence and operator documentation by unit**

Apply these exact semantic rules throughout the listed documents:

- `one action`, `one action ID`, `one result`, and `one haptic` remain one;
- one Posted action means `mouseDown +3`, `mouseUp +3`, and Octo `+3`;
- one hundred Posted actions mean `300/300` Mac posts and `300` Octo increments;
- duplicate ID means one total three-click burst and one exact cached result;
- conflict, expiry, remote-off, permission, and creation-failure rows remain zero;
- `CLICK_GAP_MS` remains the within-click calibration control for each of the three pairs;
- physical acceptance remains `NOT RUN` until observed on a real phone and Octo.

State in `benchmarks/README.md`, `docs/benchmark.md`, both smoke documents, iOS acceptance, and `FINAL-PLAN.md` that Mac diagnostic counts are attempted `CGEvent.post` calls. `CGEvent.post(tap:)` returns no success result, so a matching Octo delta is the authoritative physical-target observation.

In `FINAL-PLAN.md`, replace the global outcome with “one accepted input produces one logical action that posts exactly three independent ordinary left clicks.” Repair every physical smoke/benchmark/acceptance row that still equates one action with one down/up pair or one Octo increment. Do not change logical deduplication, lifecycle, or phone action-ID requirements.

- [ ] **Step 5: Run copy, compile, and contradiction checks**

```bash
node --test relay/test/assets.test.js
xcodegen generate --spec ios/project.yml
xcodebuildmcp simulator list --enabled true --output json
xcodebuildmcp simulator test \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 17" \
  --use-latest-os \
  --extra-args '-only-testing:ClickBridgePhoneTests/PhoneStateTests'
rg -n 'one mouse-down and one mouse-up|one counter increment|one Octo increment|send one click|Sends one click' \
  README.md FINAL-PLAN.md docs/benchmark.md docs/smoke-test.md \
  docs/physical-smoke-test.md docs/ios-acceptance.md \
  docs/superpowers/specs/2026-08-12-native-ios-volume-client-design.md \
  docs/superpowers/plans/2026-08-12-native-ios-volume-client.md \
  benchmarks/README.md relay/public ios/ClickBridgePhone
```

Expected: PWA and iOS tests PASS. If `iPhone 17` is not in the enabled list, use an enabled iPhone name returned by the preceding command. The final search returns no statement that describes the physical outcome as one click; any logical one-action statement explicitly distinguishes the three-click physical burst.

- [ ] **Step 6: Commit truthful product copy and documentation**

```bash
git add relay/public/index.html relay/public/manifest.webmanifest relay/test/assets.test.js \
  ios/ClickBridgePhone/ContentView.swift ios/ClickBridgePhone/ClickBridgeIntents.swift \
  README.md FINAL-PLAN.md benchmarks/README.md docs
git commit -m "docs: describe three-click action behavior"
```

### Task 5: Run integrated verification and record the physical gate honestly

**Files:**
- Verify: all files modified in Tasks 1-4
- Record observed evidence only after execution: `docs/physical-smoke-test.md`, `docs/ios-acceptance.md`, and append-only benchmark CSVs when a benchmark is actually run.

**Interfaces:**
- Consumes: integrated Mac, relay/PWA evidence, native iOS copy, and documentation changes.
- Produces: a PR-ready branch with automated evidence and an explicit physical acceptance state.

- [ ] **Step 1: Regenerate and verify the tracked Mac project**

```bash
xcodegen generate --spec mac/project.yml
git diff --exit-code -- mac/ClickBridgeMac.xcodeproj/project.pbxproj
```

Expected: XcodeGen succeeds and the generated project is byte-identical because no source file was added or removed.

- [ ] **Step 2: Run the complete Mac test and Release build**

```bash
xcodebuildmcp macos test \
  --project-path mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac
xcodebuildmcp macos build \
  --project-path mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac \
  --configuration Release \
  --arch arm64
```

Expected: the full Mac suite and arm64 Release build PASS.

- [ ] **Step 3: Run the full Node 24 contract**

```bash
npm --prefix relay ci
npm --prefix relay run check
```

Expected: parser checks and all relay/PWA tests PASS on Node `>=24 <25`.

- [ ] **Step 4: Run repository hygiene checks**

```bash
git diff --check
rg -n 'mouseEventClickState' mac/ClickBridgeMac/MacInputExecutor.swift
rg -n 'clickRepetitions|PHYSICAL_CLICKS_PER_POSTED_ACTION' mac relay
```

Expected: no whitespace errors; exactly two native click-state assignments, both `value: 1`; Swift runtime and JavaScript evidence multipliers both equal `3`.

- [ ] **Step 5: Run the physical Octo gate when the required hardware is available**

With the installed Release Mac app, public OCI relay, one real phone on cellular, Mac Accessibility permission, and an explicitly harmless Octo counter target:

1. Record starting Mac attempted down/up counters and Octo count.
2. Send one accepted input and wait for the one matching terminal result/haptic.
3. Require Mac attempted-post counter deltas `+3/+3` and authoritative Octo delta `+3`.
4. Resend the exact same action ID through the negative harness; require an identical cached result and no additional burst.
5. Run 100 distinct Posted actions; require Mac attempted-post deltas `+300/+300` and authoritative Octo delta `+300`.
6. Calibrate `CLICK_GAP_MS` in the documented order only if a down/up pair is missed.

Expected: every exact count matches. The Mac counters prove six attempted post calls per action; only Octo proves all three ordinary clicks were observed by the physical target. If the three immediate pairs are not all observed, keep the gate failed and add the smallest measured inter-click gap through a separate failing test and focused change. Never relabel a partial run as passed.

- [ ] **Step 6: Record evidence state and prepare the PR**

If Step 5 was not run, retain `NOT RUN` and state the missing hardware/Octo gate in the PR. If it was run, record device, macOS, Octo version, action/result counts, counter deltas, and Octo deltas without tokens.

```bash
git status --short
git log --oneline --decorate -5
```

Expected: only intended files are changed, implementation commits are reviewable, and no token or generated build artifact is present.
