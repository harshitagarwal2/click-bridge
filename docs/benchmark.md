# Measuring latency honestly

## Rules

1. **Never subtract wall clocks across devices** to produce a latency figure.
   Each device reports durations from its own monotonic clock:
   - phone: `performance.now()` for `ackMs` and `confirmationMs`
   - relay: `relayProcessingUs`
   - Mac: `macProcessingUs`
2. **Never call half an RTT "one-way latency."**
3. For a cross-device estimate, use the NTP four-timestamp exchange:

   ```
   offset = ((t1 - t0) + (t2 - t3)) / 2      # Mac minus phone
   rtt    = (t3 - t0) - (t2 - t1)
   uncertainty = rtt / 2
   ```

   Run 20 exchanges, keep the sample with the smallest non-negative RTT, and
   report the uncertainty alongside every derived number.
4. **Never remove an outlier.**
5. Latency percentiles include **only** Posted samples. Rejected and Unknown
   stay in the reliability totals.
6. A subgroup under 100 samples gets median, max, and count — **no p95 or p99
   claim**.

## Schedule

Per condition: 10 warm-up taps (discarded) then 100 recorded, using one
pre-generated randomised order of 70 two-second gaps, 20 fifteen-second gaps,
and 10 sixty-second gaps. Reuse the identical schedule for every comparison.
Record the *actual* gap, not the requested one.

The idle stratification is the point: it isolates the radio-wake cost, which is
the largest controllable term.

## Keep-warm A/B

Alternate randomised blocks **within** a session — never all-off in the morning
against all-on in the evening. Two sessions at different times.

Keep the 5-second keep-warm only if, in **both** sessions:

- Posted p95 improves by ≥15% **and** ≥20 ms
- Posted reliability does not drop
- Unknown and reconnect counts do not rise

Otherwise delete the keep-warm loop and its setting before accepting the
milestone. An unmeasured battery cost is not a feature.

## Tailscale, if you get there

Label a route **direct** only when `tailscale status --json` proves it. A
successful WSS handshake proves nothing about the path. A DERP-relayed run may
be recorded, but never as "direct".
