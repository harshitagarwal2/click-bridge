# Benchmark evidence

These CSV files are intentionally header-only until a physical phone, the public OCI relay,
the real Mac receiver, and the harmless Octo target are used together. Physical and latency
acceptance are **NOT RUN**. Never add synthetic rows to these canonical evidence files.

`measurements.csv` contains one logical action per row. It must not contain tokens, IP
addresses, cursor coordinates, browsing/page content, or Octo profile data.
`run-evidence.csv` records before/after Mac post counters and operator-observed Octo counters.

## Collection

1. Disconnect the ordinary PWA before using the negative harness; the relay permits one phone.
2. In the PWA Diagnostics area, choose **Start benchmark**. This performs 20 sequential clock
   exchanges and selects the minimum non-negative RTT sample. It refreshes after 25 terminal
   actions. Requests are scoped to the current socket generation and are canceled on disconnect
   or visibility loss; replacement-socket responses cannot satisfy an older request.
3. Perform only the predeclared schedule: 10 excluded warm-ups, then 70×2s, 20×15s, and
   10×60s gaps in a pre-generated randomized order. The action control remains disabled until
   each scheduled gap has elapsed, and records the actual idle time.
4. Choose **Finish benchmark**, enter the observed Octo counters, then explicitly export both
   CSV files. Finish rejects the run unless Mac down/up counter deltas and the Octo delta exactly
   match all actual Posted actions, including excluded warm-ups; `logicalActionCount` includes
   warm-ups while measurement rows do not. Copy reviewed rows into the canonical files.
5. Summarize without outlier removal:

   ```sh
   cd relay
   node scripts/summarize-latency.mjs ../benchmarks/measurements.csv
   ```

## Negative matrix

With the PWA disconnected, Mac ready, Octo frontmost, and environment variables supplied
without shell history exposure, run:

```sh
export CLICK_BRIDGE_URL=wss://your-host/ws
read -rs PHONE_TOKEN; export PHONE_TOKEN
export NEGATIVE_MATRIX_OCTO_OBSERVATIONS='{"exact_duplicate":{"before":10,"after":11},"id_conflict":{"before":11,"after":11},"expired":{"before":11,"after":11},"result_drop":{"before":12,"after":13}}'
node relay/scripts/run-negative-matrix.mjs
```

The harness covers exact duplicate, changed-payload ID conflict, expired request, and result
route drop. It checks both Mac mouse-down and mouse-up counter deltas. For result drop it takes
the baseline before the original request and the final snapshot after reconnect, requiring exactly
one original down/up post, no result delivery to the replacement socket, and an observed Octo
delta of one. Replace every Octo example value with the operator-observed counters for that exact
scenario; a missing or mismatched observation makes the row fail. Capacity remains a
deterministic injected Swift `ActionProcessor` test and must not be induced publicly.
