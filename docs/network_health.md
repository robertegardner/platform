# Network health — gates, monitoring, and the link-flap saga

Project notes for the V2 rollout gates and the monitoring built during the
2026-06-10/11 stability hunt. Status as of 2026-06-11 morning: **V2 radio
re-rollout ON HOLD** pending physical fixes (below); scanner V2 stays live
(watchdogs absorb the residual flaps).

## Root cause record (chronological, each layer real)

1. **wlan0 ARP flux** — Pi dual-homed on one subnet → per-host loss waves.
   Fixed: `nmcli radio wifi off` (never re-enable on this wired node).
2. **EEE on the Pi 5 NIC** vs the multi-gig flex port → chronic flapping
   contributor. Fixed: `eth0-no-eee.service` (boot-persistent ethtool off).
3. **Switch port forced-1G / autoneg off** (gigabit requires autoneg).
   Fixed: port set to AUTO (user) → flap rate 31/hr → ~0.
4. **RESIDUAL (open): thermally-sensitive marginal link** — clean through
   the cool night (23:57→06:07), flaps resumed and accelerated with morning
   attic heat (06:07, 06:26, 06:36…). Same 3 s down/up signature. Strongly
   indicates the cable run / connectors. → attic visit (see README TODO).
5. **2026-06-12 ~14:40 CDT — #4 ESCALATED TO HARD FAILURE** (peak afternoon
   heat): link died outright with the PHY wedged — UniFi showed the port
   with no ethernet client but **10 W PoE draw**; the Pi ran on, blind
   (`stream.sh: Network is unreachable`), both public streams silent. PoE
   power-cycle → boot-time 3–7 s flap burst (~1 min) → ~60 s stable → dead
   again, then bouncing. The medium now fails hard, not just flaps —
   **the dedicated attic run is required for V1 reliability, not just V2**.
   Interim triage order: different switch port → reseat connectors → force
   100FDX (2-pair stopgap; V1-hybrid + scanner CU8 traffic fits in 100M).

## V2 re-rollout gates (re-run after the physical fixes)

Runbook: deployment_notes.md → "V2 radio RE-ROLLOUT runbook". Gates:

1. **Flap gate:** zero `eth0: Link is` kernel events across a window that
   includes a WARM AFTERNOON (the thermal worst case), e.g.
   `sudo journalctl -k --since "-6 hours" | grep -c "eth0: Link is"` on the Pi.
2. **Loss gate:** iperf3 UDP ladder Pi→.84 (server: `iperf3 -s -D` on .84):
   64/102/256 Mbps × 45 s, each <0.01% loss. Healed-link baseline 2026-06-11
   ~00:30: 0.0004% / 0.0005% / 0.0032% (and 400 M @ 0.18%); TCP 767 Mbps.
3. **IQ gate (the real thing, runs inside the cutover):** `tools/capture-iq.py`
   from .84 against the dx-R2 at 2 AND 8 Msps, 120 s each — ~full effective
   rate, 0 timeouts. (8 Msps CS16 ≈ 256 Mbps = the V2 target.)

## Monitoring inventory

| What | Where | Mechanism |
|---|---|---|
| `fm-watch.timer` | radio-compute .84 | mount-404 watchdog → restart rack `sdr-fm@active` (dormant while V2 paused) |
| `pi-fm-watch.timer` | Pi | same for the V1-hybrid publish chain (ffmpeg CLOSE-WAIT zombies) |
| `op25-watch.timer` | scanner-compute .83 | bridge `current:null` staleness → restart op25 (flap-starved sessions) |
| `eth0-no-eee.service` | Pi | persistence for the EEE mitigation |
| Live flap watch | ad-hoc | `journalctl -kf \| grep "eth0: Link is"` (Monitor recipe; counts via `journalctl -k --since … \| grep -c`) |
| `tools/unifi-port-audit.sh` | codeserver → UDM | network-wide forced-speed/autoneg/error-counter audit (read-only mongo) |
| `tools/npm-proxy.py` | codeserver | NPM list/repoint/clone for scripted cutovers (creds: `~/.config/npm-proxy.env`) |

UDM-SE access: `ssh root@192.168.85.1`; Network app DB `mongo --port 27117
ace` (config) / `ace_stat` (5-min port stats incl. `x-total-*` lifetime
counters). The web UI's System Log timeline is NOT in mongo (newer UniFi);
device-side kernel logs are the flap ground truth for Linux hosts.

## Port audit findings (2026-06-11, see README TODO for actions)

- **Agg "Server Rack Right" port 1 = THE UPLINK TO THE UDM-SE GATEWAY**
  (SFP+ 10G): active frame errors (~40 rx/5 min, ~72k lifetime). All
  north-south traffic rides this — prime suspect for general/historical
  network flakiness (homelab-monitor era). Reseat/replace DAC/transceiver.
- BASE-T forced-1G + autoneg-off (the Pi's exact landmine class):
  Flex-Office p5, Flex Living Room p1, Flex Pool Outside p2+p5 → set AUTO.
- Forced-100 + autoneg-off: Garage p4, Front Walk p2 — verify deliberate
  (far end must be forced too, else half-duplex fallback).
- Proxmox uplinks (`Proxmox1`/`Beast1`, forced 10G SFP+): clean — normal
  for DAC; satisfaction 100, ~zero lifetime errors. Not a suspect.
- Homelab-monitor tie-in (future): unpoller already exports per-port error
  counters → alert on error deltas and autoneg-off config drift.
