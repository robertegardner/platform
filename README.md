# platform

Acquisition + distribution tier of the SDR homelab. Start with `CLAUDE.md`
(current state + rules) and `docs/` (architecture, deployment notes,
session log, network health).

## TODO — network port fixes (attic/rack visit, ~few days)

From the 2026-06-11 audit (`docs/network_health.md`); re-run the V2 rollout
gates after these, ideally across a warm afternoon:

- [ ] **Attic:** swap the Pi's cat6 patch cable — residual thermally-correlated
      link flaps survive the EEE-off + port-auto fixes (clean cool night,
      flaps return with morning heat)
- [ ] **Attic (while there):** try a different port on the camera flex for the
      Pi — isolates switch-port vs cable if flaps persist after the swap
- [ ] **Rack — PRIORITY:** "USW Aggregation Server Rack Right" **port 1 = the
      uplink to the UDM-SE gateway**, taking active frame errors (~40 rx/5 min,
      72k lifetime). All north-south traffic crosses it — likely behind
      historical network flakiness. Reseat/replace the SFP+ DAC/transceiver
      (and re-check counters after: `tools/unifi-port-audit.sh`)
- [ ] **UniFi config:** set BASE-T autoneg-off ports to AUTO — Flex-Office p5,
      Flex Living Room p1, Flex Pool Outside p2 + p5 (the Pi's-port landmine
      class: gigabit requires autonegotiation)
- [ ] **UniFi config:** confirm the forced-100 ports are deliberate and forced
      on BOTH ends (Garage p4, Front Walk p2) — else half-duplex fallback
- [ ] **Then:** re-run gates (`docs/network_health.md`) → if green, execute the
      V2 radio re-rollout (`docs/deployment_notes.md` runbook) — it's all
      staged; the NPM repoint is one `tools/npm-proxy.py` line
