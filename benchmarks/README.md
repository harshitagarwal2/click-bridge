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
   actions. Visibility/network changes require ending and starting a new condition.
3. Perform only the predeclared schedule: 10 excluded warm-ups, then 70×2s, 20×15s, and
   10×60s gaps in a pre-generated randomized order. Record actual idle time.
4. Choose **Finish benchmark**, enter the observed Octo counters, then explicitly export both
   CSV files. Copy reviewed rows into the canonical files; do not overwrite earlier raw rows.
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
node relay/scripts/run-negative-matrix.mjs
```

The harness covers exact duplicate, changed-payload ID conflict, expired request, and result
route drop. Capacity remains a deterministic injected Swift `ActionProcessor` test and must
not be induced against the public receiver.
