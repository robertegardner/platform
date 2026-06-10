# session_notes.md — SDR Platform V2 build log

Working notes per session, newest first. Full detail lives in
`deployment_notes.md` (results, runbooks) and git history; this is the quick
"where were we" index.

## 2026-06-10 — Distribution tier stood up (no cutover)

**State: rack Icecast LIVE at 192.168.6.82 (LXC 900). Production untouched.**

- Built `module.distribution` (container + provision, copied from
  homelab-monitor's `module.monitoring`) and `terraform/registry/mounts.json`
  (V2 audio namespace + legacy Pi mounts with their migration phase).
- Verified end-to-end: ffmpeg test source from the Pi → `/test.mp3` on the rack
  Icecast → listener pulled valid MP3 → mount cleaned up. Idempotent re-provision
  (icecast.xml marker guard, byte-identical).
- Same source password as the Pi's Icecast (tfvars on thebeast only) — future
  source cutovers change only the host.
- **Deliberately not done:** NPMplus repoint, Pi source changes, anything
  scanner. Cutover runbook in `deployment_notes.md`.
- Gotchas: deploy token lacks `Pool.Allocate` (no pools — tag-identified);
  LXC SSH needs `id_rsa_homelab` (the injected key; `id_ed25519` only works on
  the Pi); bpg modules need their own `required_providers`.
- Commits: `9a1edd0` (scaffold), `ee3104a` (live + runbook). Pushed; tree synced
  to thebeast.

**Next:** `scanner-compute` (.83/vmid 901) when the Airspy R2 arrives →
`radio-compute` (.84/902) → NPMplus repoint last. Flip the registry device
`present: true` + re-apply to join each new tuner.

## 2026-06-09/10 — Phase 0: scaffold + dx-R2 transport proof → **GO**

**State: Gate 0B GO. SoapyRemote 8 Msps CS16 proven Pi → rack.**

- Phase 0A: Terraform scaffold (bpg/proxmox per homelab-monitor), device
  registry (`terraform/registry/devices.json`, only dx-r2 `present: true`),
  `pi-acquisition` module (null_resource + remote-exec, NO container).
  Commit `ece97b2`.
- Phase 0B first attempt: 8 Msps stalled after ~6 s → NO-GO recorded
  (`4ed4e52`). 2.5 Msps clean with real signal (KGMO carrier +13.7 dB).
- Tuning window: root cause = kernel socket buffers (Pi at 4 MB default;
  SoapyRemote wants ~100 MB — its sysctl drop never applies post-boot). Fixed +
  encoded in `provision-pi.sh.tpl`. Re-test: 120 s @ ~7.9 Msps, 0 overflows,
  0 timeouts → **GO** (`f27a4ce`).
- Local USB sanity passed (dx-R2 ~7.9 Msps on the Pi) — co-resident RTL2838 is
  a non-factor.
- Carry-forwards: client must pass `remote:driver=sdrplay`; default gain
  saturates the ADC at 8 Msps (compute sets gain at connect);
  `sdr-source@dx-r2` stays disabled (single-client vs live radio — attended
  windows only, dead-man timer pattern in `deployment_notes.md`).
- Live radio (`sdr-fm@active` / `icecast.rg2.io/fm.mp3`) restored and verified
  after every window.
