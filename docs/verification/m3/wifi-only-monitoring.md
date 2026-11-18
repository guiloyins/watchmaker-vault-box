# Wi-Fi-only connection monitoring

Rafa confirmed on 13 November 2026 that no Ethernet cable or adapter is available and requested a ping-based comparison. Continue on Wi-Fi; do not require an Ethernet setup. No network settings were changed.

The current route and ARP entries were checked before capture: router `192.0.2.102`, CYD A `192.0.2.101` (reviewed A MAC), CYD B `192.0.2.104` (reviewed B MAC), and Phoenix `192.0.2.103:4013`, listening under the expected timing-enabled bench process. The user-facing Terminal command is `ping -n -i 1 192.0.2.102`. A separate bounded monitor records UTC receipt times for all three ping streams and local Phoenix health checks. Healthy ICMP does not establish timely WebSocket delivery.

## Retained incident before this run

The server recorded B transport closes at 19:47:08.799 and 19:47:13.004 EST and an A close at 19:47:10.772 EST. A's current 16-report USB capture retains its original MCU boot, active generation 9 and failure count 8. Its latest failure is generation 8 at uptime 4,256,853 ms: SDK-origin close, raw-send phase 6 taking 26 ms, with numeric error fields zero and no controller-initiated retirement reason. This aligns with the A server event within the precision of delayed serial receipt and clock drift; it does not establish packet ordering or bytes delivered. [Device history](cyd-a-wifi-monitor-startup.json)

There were no server timing warnings at or above 100 ms near the 19:47 closes. This weakens the explanation of a measured room/API stall, but does not exclude unmeasured socket scheduling, transport/ACK delivery, cumulative shorter delays or wireless loss. Later sample/scope delays of 130/139 ms at 20:30:41 EST, and tick-work/scope delays of 175/215–233 ms at 20:34:33 EST, had no accompanying logged close. They are separate observations. No retry, timeout or firmware change is justified by these records alone.

At the monitoring checkpoint, the host was paused at A4/board 0, with both roles unassigned after the later loss, setup required on the simulated box and no release requested. No new physical swipe was verified then. [Host snapshot](dual-cyd-wifi-monitor-host.json)

## Current comparison

The five-minute comparison completed from **20:34:38 to 20:39:38 EST**. Both CYDs and the router returned 299 consecutive observed replies (sequence 0–298), with no interior sequence gap. The bounded capture does not classify unsampled boundary sends. Median RTT A/B/router was 6.298/5.885/2.588 ms; maxima were 48.748/49.716/14.893 ms. All 300 local Phoenix health checks passed, with a maximum request duration of 37 ms and maximum scheduling delay of 5 ms. No device-close event was logged in the comparison window. [Correlation capture](cyd-pair-wifi-correlation-02.json)

The startup, two-minute and final-minute USB captures returned 16 + 239 + 119 validated reports. All retained the same boot, active generation 9, online flags and failure count 8. The latest recorded failure remains the earlier 19:47 event. These captures establish another observed recovery window, not a root cause or a stability repair. No firmware, server runtime, network configuration or game state was changed during this run. [Startup](cyd-a-wifi-monitor-startup.json) · [Two-minute capture](cyd-a-wifi-monitor-01.json) · [Final-minute capture](cyd-a-wifi-monitor-02.json)

The bounded monitor is complete. The user's Terminal ping can continue for a longer observation; note the local time of any board disconnect and whether the router ping shows timeouts then. Server timing diagnostics remain enabled. A healthy ping during a game disconnect does not rule out TCP/WebSocket-specific failure.

## User-requested resume — 13 November 2026, 21:03 EST

At Rafa’s request, the host verified both physical CYDs fresh and neutral, prepared the simulated reference, exited simulated service, armed the simulated box and resumed the retained maze at A4/board 0. No reset or move was issued, and no release was requested. This establishes the resumed starting state, not a physical swipe or network-stability pass. [Before](dual-cyd-before-user-resume.json) · [Verified resume](dual-cyd-user-resumed.json)

## Successful run — 13 November 2026, 21:06 EST

Rafa subsequently reported that the run worked as expected and that he had detected no disconnects in approximately 20 minutes. Read-only host/store checks confirmed solved state, both fresh physical CYD owners and exactly one completed simulated release without error/conflict. Ten post-run USB reports retained A's boot, generation 9 and failure count 8; no later transport close was present in the inspected server log. A remains on diagnostic v2 and B on normal firmware. This adds a successful observed run, without establishing 20 minutes of active play or resolving the earlier failure's cause. [Complete result and limits](dual-cyd-success.md)
