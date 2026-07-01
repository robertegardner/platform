# Meteor LRPT on the GOES Pi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode Meteor-M2 LRPT with the Nooelec v5 on the GOES Pi by reviving the existing (DARK) wxsat stack, while making `goes.service` immune to a second RTL dongle.

**Architecture:** The GOES Pi keeps decoding GOES HRIT locally (geostationary exception) but now pins its SatDump to the SMArTee by serial. A second unit (repointed `pi-wxsat`) serves the Nooelec's IQ over `rtl_tcp`, selected strictly by serial with a hard-fail. The rack's existing `radio-compute` wxsat scheduler + `/wxsat` gallery (pass prediction, per-pass waterfall/spectrograph + pass-arc track) decode it remotely, un-gated. New ntfy pushes + a dashboard Meteor tile surface passes and decodes.

**Tech Stack:** Terraform (bpg/proxmox modules + `null_resource`/`remote-exec`), bash provisioners rendered by `templatefile()`, SatDump (`meteor_m2-x_lrpt`), librtlsdr / `rtl_tcp` / `rtl_test`, Python 3 stdlib (scheduler, notifier, dashboard).

## Global Constraints

- **Everything install/write-if-absent or marker-guarded** — re-applies must not clobber hand-tuned state (`goes.service`, `wxsat.env`, `dashboard.env` are keep-if-absent).
- **Select SDRs strictly by serial, hard-fail** — never fall back to librtlsdr device 0. SatDump's RTL selector is `--source_id <index>`; `rtl_tcp -d <index>`; both use librtlsdr enumeration order, which `rtl_test` reports with `SN:`.
- **RTL gain stays LOW (7.2 dB, `WXSAT_GAIN_TENTHS=72`)** — an externally powered LNA is upstream; 40 dB stacked clipped ~19% and killed the LRPT decode (2026-06-18). Do not raise without re-checking clip%.
- **`.tpl` escaping:** `${x}` = templatefile var; `$${VAR}` = literal runtime shell var; quoted heredocs `<< 'EOF'`.
- **Provisioner gotchas:** `remote-exec` inline runs WITHOUT `set -e` (chain `script && rm -f script`); `grep ... >/dev/null` not `grep -q` after a pipe; after rewriting units use `systemctl enable` + `systemctl restart` (never `enable --now`).
- **Terraform:** runs on **thebeast** as `deploy`; `terraform.tfvars` + state are **thebeast-only, never committed, never `rsync --delete`**. Validate with `terraform validate`; **never** `terraform fmt`. Ship the tree with `rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/`.
- **SSH reach:** codeserver → thebeast by IP `192.168.6.163` (deploy user); GOES Pi + LXCs reached *through* thebeast (`ssh deploy@163 'ssh -i ~/.ssh/id_rsa_homelab <user>@<host>'`). GOES Pi user = `rgardner`; radio-compute (.84) root via `id_rsa_homelab`.
- **Never** `pct exec` / root-SSH to thebeast; never destroy/recreate the GOES Pi's `null_resource` (bare metal, live).
- **Targeted re-provision:** bare-metal pi modules use `count`, so index them: `module.pi_goes.null_resource.provision[0]`, `module.pi_wxsat.null_resource.provision[0]`. Container modules (`radio_compute`, `dashboard`) have NO count — address them WITHOUT the index: `module.radio_compute.null_resource.provision`. (Targeting a non-existent `[0]` silently no-ops as "No changes".)

---

## File Structure

**Task 1 — GOES serial-pin (safety, ship first):**
- Modify `terraform/registry/devices.json` — add `"serial": "47360874"` to the `goes` device.
- Modify `terraform/modules/pi-goes/main.tf` — add `goes_serial` to the `templatefile()` map.
- Modify `terraform/modules/pi-goes/provision-goes.sh.tpl` — write `/etc/goes/pin.env` + `/usr/local/sbin/goes-satdump.sh`; patch/fresh-write `goes.service` ExecStart to the wrapper.

**Task 2 — Serve the Nooelec on the GOES Pi (repoint `pi-wxsat`):**
- Modify `terraform/registry/devices.json` — un-shelve `nooelec-wx` (host/endpoint/serial/present + comment).
- Modify `terraform/modules/pi-wxsat/provision-wxsat.sh.tpl` — refresh p24/ADS-B comments → GOES Pi (logic unchanged).
- (thebeast, not committed) `terraform.tfvars` — `wxsat_host = "goes.srvr"`, `wxsat_ssh_user = "rgardner"`.

**Task 3 — Un-gate the rack scheduler:**
- (live on .84, not committed) `/etc/radio-compute/wxsat.env`.
- Modify `terraform/modules/radio-compute/provision-radio.sh.tpl` — fresh-write env defaults (both sats; keep `DRY_RUN=1` as the safe fresh default).

**Task 4 — ntfy alerts:**
- Create `terraform/modules/radio-compute/wxsat_notify.py` + `terraform/modules/radio-compute/tests/test_wxsat_notify.py`.
- Modify `terraform/modules/radio-compute/wxsat_scheduler.py` — call the notifier at pass-start + decode-complete.
- Modify `terraform/modules/radio-compute/main.tf` — add `wxsat_notify_py = file(...)`.
- Modify `terraform/modules/radio-compute/provision-radio.sh.tpl` — write + chmod `wxsat_notify.py`; add `NTFY_URL`/`NTFY_TOPIC` to the `wxsat.env` fresh-write.

**Task 5 — Dashboard Meteor tile:**
- Modify `terraform/modules/dashboard/dashboard.py` — `poll_meteor()`, register it, `/api/proxy/meteor-latest.png` route, `OPEN_METEOR`.
- Create `terraform/modules/dashboard/tests/test_poll_meteor.py`.
- Modify `terraform/modules/dashboard/provision-dashboard.sh.tpl` — add `DASH_OPEN_METEOR` to the env fresh-write.

**Task 6 — Docs + end-to-end verification + PR.**

---

## Task 1: Pin `goes.service` to the SMArTee by serial (fixes the flake)

Independent and safe to ship first; after this the Nooelec can be hot-plugged with zero risk to GOES.

**Files:**
- Modify: `terraform/registry/devices.json` (the `goes` device object)
- Modify: `terraform/modules/pi-goes/main.tf:12-24` (templatefile map)
- Modify: `terraform/modules/pi-goes/provision-goes.sh.tpl:62-88` (goes.service block)

**Interfaces:**
- Produces: `/usr/local/sbin/goes-satdump.sh` (runtime wrapper: resolves the SMArTee index from `$GOES_SERIAL`, appends `--source_id <idx>`, hard-fails if the serial is absent); `/etc/goes/pin.env` (`GOES_SERIAL=<serial>`); templatefile var `goes_serial`.

- [ ] **Step 1: Add the serial to the registry.** In `terraform/registry/devices.json`, inside the `"goes"` object, add a `serial` field (right after `"host": "goes.srvr",`):

```json
      "serial": "47360874",
```

- [ ] **Step 2: Pass it into the template.** In `terraform/modules/pi-goes/main.tf`, add one line to the `templatefile(...)` map (after the `gain` line at :15):

```hcl
    goes_serial  = try(local.dev.serial, "47360874")
```

- [ ] **Step 3: Write the pin.env + wrapper in the provisioner.** In `terraform/modules/pi-goes/provision-goes.sh.tpl`, immediately BEFORE the `GS=/etc/systemd/system/goes.service` line (currently :62), insert:

```bash
# --- 3a) Serial-pin wrapper -------------------------------------------------
# goes.service must bind the GOES SMArTee (not a second RTL like the Meteor
# Nooelec). SatDump's RTL selector is --source_id <librtlsdr index>; index order
# is NOT stable with two identical RTL2838s, so resolve it from the unique serial
# at each start and HARD-FAIL rather than grab index 0. (Same pattern as
# pi-wxsat's wxsat-rtltcp.sh.)
install -d /etc/goes
cat > /etc/goes/pin.env <<EOF
GOES_SERIAL=${goes_serial}
EOF
cat > /usr/local/sbin/goes-satdump.sh <<'EOF'
#!/bin/bash
# platform-managed (pi-goes): pin SatDump to the GOES SMArTee by serial.
set -u
. /etc/goes/pin.env 2>/dev/null || true
: "$${GOES_SERIAL:?GOES_SERIAL unset}"
idx="$(timeout 5 rtl_test 2>&1 | grep "SN: $${GOES_SERIAL}" | grep -oE '^[[:space:]]*[0-9]+:' | tr -dc '0-9' | head -c3 || true)"
if [ -z "$${idx}" ]; then
  echo "goes-satdump: no RTL with serial $${GOES_SERIAL} — refusing to start (would risk grabbing the Meteor Nooelec)" >&2
  exit 1
fi
echo "goes-satdump: SMArTee serial=$${GOES_SERIAL} -> librtlsdr index $${idx}"
# SatDump 2.0-alpha requires --opt=value; space-separated "--source_id $${idx}"
# corrupts the parser ("Could not find a handler for source type : rtlsdr").
exec /usr/bin/satdump "$@" --source_id=$${idx}
EOF
chmod +x /usr/local/sbin/goes-satdump.sh
echo "    wrote /usr/local/sbin/goes-satdump.sh (serial-pin, GOES_SERIAL=${goes_serial})"

```

- [ ] **Step 4: Patch the keep-if-absent unit + fresh-write default.** In the same file, replace the whole `if [ -f "$GS" ]; then … fi` block (currently :63-86) with:

```bash
if [ -f "$GS" ]; then
  echo "    $GS present — keeping the hand-tuned unit"
  # Idempotent pin: route the existing hand-tuned ExecStart through the wrapper
  # (which appends --source_id). Only touches the binary path; freq/gain/rate
  # are preserved. Marker = the wrapper path already being present.
  if grep 'ExecStart=/usr/bin/satdump ' "$GS" >/dev/null 2>&1; then
    sed -i 's#ExecStart=/usr/bin/satdump #ExecStart=/usr/local/sbin/goes-satdump.sh #' "$GS"
    echo "    patched goes.service ExecStart -> serial-pin wrapper"
  else
    echo "    goes.service ExecStart already pinned (or custom) — left as-is"
  fi
else
  cat > "$GS" <<EOF
[Unit]
Description=SatDump GOES-19 HRIT live decode
Documentation=https://github.com/robertegardner/platform
After=network-online.target
Wants=network-online.target

[Service]
User=$${RUN_USER}
ExecStartPre=/bin/mkdir -p ${output_dir}
ExecStart=/usr/local/sbin/goes-satdump.sh live goes_hrit ${output_dir} --source rtlsdr \
  --samplerate ${samplerate} --frequency ${frequency_hz} --gain ${gain} \
  --http_server 0.0.0.0:8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  echo "    wrote default $GS (fresh install, serial-pinned)"
fi
```

- [ ] **Step 5: Validate Terraform.** Ship the tree and validate on thebeast:

Run:
```bash
rsync -az terraform docs deploy@192.168.6.163:/home/deploy/platform/
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform validate'
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Apply just pi-goes and verify GOES survives the pin.**

Run:
```bash
ssh deploy@192.168.6.163 "cd /home/deploy/platform/terraform && terraform apply -auto-approve -target='module.pi_goes.null_resource.provision[0]'"
```
Then verify on the Pi (through thebeast):
```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab rgardner@goes.srvr bash -s' <<'EOF'
grep ExecStart= /etc/systemd/system/goes.service
systemctl is-active goes.service
journalctl -u goes.service -n 5 --no-pager | grep -i "index\|serial\|goes-satdump" || true
ls -t /home/rgardner/goes_output 2>/dev/null | head -3
EOF
```
Expected: ExecStart points at `/usr/local/sbin/goes-satdump.sh`; service `active`; journal shows `SMArTee serial=47360874 -> librtlsdr index 0`; fresh products in `goes_output`. (If it fails to start, GOES was the only RTL and index resolved fine — investigate before proceeding.)

- [ ] **Step 7: Commit.**

```bash
cd /home/rgardner/projects/platform
git add terraform/registry/devices.json terraform/modules/pi-goes/main.tf terraform/modules/pi-goes/provision-goes.sh.tpl
git commit -m "feat(pi-goes): pin goes.service to the SMArTee by serial (fix two-RTL flake)"
```

---

## Task 2: Serve the Nooelec over rtl_tcp on the GOES Pi (repoint pi-wxsat)

Requires the user to plug the Nooelec + Meteor antenna into `goes.srvr` for the serial read and apply.

**Files:**
- Modify: `terraform/registry/devices.json` (the `nooelec-wx` device object)
- Modify: `terraform/modules/pi-wxsat/provision-wxsat.sh.tpl` (comments only)
- Modify (thebeast, not committed): `terraform.tfvars`

**Interfaces:**
- Consumes: Task 1's serial-pinned `goes.service` (so both dongles coexist).
- Produces: `wxsat-rtltcp.service` on `goes.srvr` serving the Nooelec (serial-pinned) on `:1234`; registry `nooelec-wx.host = goes.srvr` feeding `radio-compute`'s `wxsat_rtltcp_host`.

- [ ] **Step 1: Read the Nooelec's actual serial (user plugs it in).** With GOES already serial-pinned (Task 1), plugging the Nooelec in is now safe. Read both dongles:

```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab rgardner@goes.srvr "rtl_test -t 2>&1 | head -8"'
```
Expected: two devices; note the Nooelec's `SN:` (the SMArTee is `47360874`). Call the Nooelec's serial `<NOOELEC_SN>` below. If it collides with `47360874` (unlikely — Nooelec ships factory-unique), reflash it: `rtl_eeprom -d <idx> -s 00000200` and re-read.

- [ ] **Step 2: Un-shelve the registry device.** In `terraform/registry/devices.json`, edit the `nooelec-wx` object: set `"present": true`, `"host": "goes.srvr"`, `"endpoint": "tcp://goes.srvr:1234"`, `"serial": "<NOOELEC_SN>"`, and replace the `_comment` with:

```json
      "_comment": "Nooelec NESDR SMArt v5 (RTL2838) + tuned Meteor antenna + externally powered LNA, on the GOES Pi (goes.srvr, 192.168.6.134). Served over rtl_tcp (wxsat-rtltcp.service, serial-pinned + hard-fail) so it can never steal the GOES SMArTee (47360874); the rack radio-compute wxsat scheduler decodes Meteor-M2 LRPT off this rtl_tcp. RTL gain stays LOW (7.2 dB) — the LNA provides gain; 40 dB stacked clips. Moved here from p24 2026-07-01.",
```

- [ ] **Step 3: Refresh the provisioner comments (logic unchanged).** In `terraform/modules/pi-wxsat/provision-wxsat.sh.tpl`, update the header/HARD-RULE comments so they describe the GOES Pi instead of p24. Change the HARD-RULE block (around :8-10) to:

```bash
# HARD RULE: never disturb the GOES downlink. goes.service is serial-pinned to
# the SMArTee (47360874); this unit selects the Nooelec STRICTLY by its unique
# serial and hard-fails rather than ever fall back to device 0.
```
(Leave every executable line — blacklist, `usbfs_memory_mb=1000`, the serial→index wrapper — unchanged. `usbfs_memory_mb=1000` is ample for GOES @2.4 Msps + Nooelec @1.5 Msps and replaces the Pi's current `0`/unlimited.)

- [ ] **Step 4: Repoint the module target on thebeast (tfvars, not committed).**

```bash
ssh deploy@192.168.6.163 "cd /home/deploy/platform/terraform && sed -i 's/^wxsat_host.*/wxsat_host        = \"goes.srvr\"/; s/^wxsat_ssh_user.*/wxsat_ssh_user    = \"rgardner\"/' terraform.tfvars && grep -E 'wxsat_(host|ssh_user)' terraform.tfvars"
```
Expected: both lines show `goes.srvr` / `rgardner`. (If the keys are absent, append them.)

- [ ] **Step 5: Validate + apply pi-wxsat.**

```bash
rsync -az terraform deploy@192.168.6.163:/home/deploy/platform/
ssh deploy@192.168.6.163 "cd /home/deploy/platform/terraform && terraform validate && terraform apply -auto-approve -target='module.pi_wxsat.null_resource.provision[0]'"
```
Expected: `Apply complete`.

- [ ] **Step 6: Verify the Nooelec is served AND GOES is unaffected.**

```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab rgardner@goes.srvr bash -s' <<'EOF'
systemctl is-active wxsat-rtltcp.service goes.service
journalctl -u wxsat-rtltcp.service -n 5 --no-pager | grep -i "serving\|serial\|index" || true
ss -ltn | grep 1234 || echo "NO 1234 LISTENER"
ls -t /home/rgardner/goes_output | head -2
EOF
```
Expected: both services `active`; `wxsat-rtltcp` log shows it resolved the Nooelec's serial to an index and is serving on `:1234`; a listener on `1234`; GOES products still fresh.

- [ ] **Step 7: Commit** (registry + provisioner only — tfvars is thebeast-only).

```bash
cd /home/rgardner/projects/platform
git add terraform/registry/devices.json terraform/modules/pi-wxsat/provision-wxsat.sh.tpl
git commit -m "feat(pi-wxsat): serve the Nooelec/Meteor rtl_tcp from goes.srvr"
```

---

## Task 3: Un-gate the rack Meteor scheduler (validation phase)

**Files:**
- Modify (live on .84, not committed): `/etc/radio-compute/wxsat.env`
- Modify: `terraform/modules/radio-compute/provision-radio.sh.tpl` (fresh-write env defaults)

**Interfaces:**
- Consumes: Task 2's `goes.srvr:1234` rtl_tcp source.
- Produces: `wxsat-scheduler.service` running against `goes.srvr`, `DRY_RUN=0`, populating `/api/wxsat/{status,passes,captures}` on `.84:8080`.

- [ ] **Step 1: Edit the live env (keep-if-absent — registry host does NOT rewrite it).**

```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 bash -s' <<'EOF'
f=/etc/radio-compute/wxsat.env
sed -i 's/^DRY_RUN=.*/DRY_RUN=0/; s/^WXSAT_RTLTCP_HOST=.*/WXSAT_RTLTCP_HOST=goes.srvr/; s/^M2_3_ENABLED=.*/M2_3_ENABLED=1/; s/^M2_4_ENABLED=.*/M2_4_ENABLED=1/; s/^MIN_ELEV_DEG=.*/MIN_ELEV_DEG=8/' "$f"
grep -E '^(DRY_RUN|WXSAT_RTLTCP_HOST|M2_3_ENABLED|M2_4_ENABLED|MIN_ELEV_DEG|WXSAT_GAIN_TENTHS)=' "$f"
systemctl restart wxsat-scheduler.service
sleep 3
systemctl is-active wxsat-scheduler.service
journalctl -u wxsat-scheduler.service -n 8 --no-pager
EOF
```
Expected: env shows `DRY_RUN=0`, host `goes.srvr`, both sats `=1`, `MIN_ELEV_DEG=8`, gain still `72`; service `active`; the "scheduler up" log line shows `dry_run=False, sats=[...two...], rtl_tcp=goes.srvr:1234`.

- [ ] **Step 2: End-to-end RF-chain test via a forced capture.** (`--force` bypasses the schedule AND DRY_RUN — records from the rtl_tcp now and decodes.)

```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 "cd /opt/wxsat && sudo -u radio HOME=/var/lib/sdr-streams/wxsat env $(cat /etc/radio-compute/wxsat.env | grep -v ^# | xargs) python3 wxsat_scheduler.py --force 2>&1 | tail -30"'
```
Expected: it records CU8 from `goes.srvr:1234` (log: `recording … from rtl_tcp goes.srvr:1234`), then runs SatDump. During a real pass this yields LRPT frames; off-pass it records clean noise (0% clip confirms the RF/gain chain — the point of the validation phase). **Confirm clip% is ~0 and mean|IQ| is low** in the log; if clip% is high, the LNA gain is stacking — do NOT raise `WXSAT_GAIN_TENTHS`.

- [ ] **Step 3: Confirm the gallery APIs are live.**

```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 "curl -s localhost:8080/api/wxsat/status; echo; curl -s localhost:8080/api/wxsat/passes | head -c 400"'
```
Expected: `status` JSON (`state`, `next_pass`, `dry_run:false`); `passes` lists upcoming Meteor passes.

- [ ] **Step 4: Update fresh-write defaults in the provisioner** so a future fresh install matches (keep `DRY_RUN=1` as the safe default — the operator flips it live). In `terraform/modules/radio-compute/provision-radio.sh.tpl`, in the `wxsat.env` heredoc (the `else` branch ~:750-770), change `M2_3_ENABLED=0` → `M2_3_ENABLED=1`. Leave `DRY_RUN=1`, `MIN_ELEV_DEG=20` as safe defaults; add a comment line above `MIN_ELEV_DEG`:

```bash
# Validation phase: operator lowers MIN_ELEV_DEG (e.g. 8) + sets DRY_RUN=0 live.
```

- [ ] **Step 5: Validate + commit.**

```bash
rsync -az terraform deploy@192.168.6.163:/home/deploy/platform/ && ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform validate'
cd /home/rgardner/projects/platform
git add terraform/modules/radio-compute/provision-radio.sh.tpl
git commit -m "feat(radio-compute): enable both Meteor-M2 sats in wxsat fresh-write defaults"
```

---

## Task 4: ntfy pass + decode alerts

**Files:**
- Create: `terraform/modules/radio-compute/wxsat_notify.py`
- Create: `terraform/modules/radio-compute/tests/test_wxsat_notify.py`
- Modify: `terraform/modules/radio-compute/wxsat_scheduler.py`
- Modify: `terraform/modules/radio-compute/main.tf`
- Modify: `terraform/modules/radio-compute/provision-radio.sh.tpl`

**Interfaces:**
- Produces: `wxsat_notify.notify(event: str, title: str, message: str, priority: str = "default", tags: str = "") -> bool` — best-effort ntfy POST; reads `NTFY_URL` + `NTFY_TOPIC` from env; returns `False` (never raises) if unconfigured or on any error.

- [ ] **Step 1: Write the failing test.** Create `terraform/modules/radio-compute/tests/test_wxsat_notify.py`:

```python
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import wxsat_notify  # noqa: E402


class NotifyTest(unittest.TestCase):
    def test_unconfigured_returns_false_no_raise(self):
        with mock.patch.dict(os.environ, {"NTFY_URL": "", "NTFY_TOPIC": ""}, clear=False):
            self.assertFalse(wxsat_notify.notify("pass", "t", "m"))

    def test_posts_to_topic_url(self):
        env = {"NTFY_URL": "https://ntfy.sh", "NTFY_TOPIC": "meteor-cape"}
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch("wxsat_notify.urllib.request.urlopen") as uo:
            uo.return_value.__enter__ = lambda s: s
            uo.return_value.__exit__ = lambda *a: False
            ok = wxsat_notify.notify("decode", "Meteor decode", "M2-4 45deg", tags="satellite")
        self.assertTrue(ok)
        req = uo.call_args[0][0]
        self.assertEqual(req.full_url, "https://ntfy.sh/meteor-cape")
        self.assertEqual(req.data, b"M2-4 45deg")
        self.assertEqual(req.headers.get("Title"), "Meteor decode")
        self.assertEqual(req.headers.get("Tags"), "satellite")

    def test_never_raises_on_network_error(self):
        env = {"NTFY_URL": "https://ntfy.sh", "NTFY_TOPIC": "x"}
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch("wxsat_notify.urllib.request.urlopen", side_effect=OSError("boom")):
            self.assertFalse(wxsat_notify.notify("pass", "t", "m"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd terraform/modules/radio-compute && python3 -m unittest tests.test_wxsat_notify -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'wxsat_notify'`.

- [ ] **Step 3: Implement the notifier.** Create `terraform/modules/radio-compute/wxsat_notify.py`:

```python
#!/usr/bin/env python3
"""Best-effort ntfy push for wxsat (Meteor) pass + decode events.

Stdlib only (mirrors dashboard.py / wx_alert.py). Reads NTFY_URL + NTFY_TOPIC
from the environment; a POST failure or missing config NEVER raises — a down
ntfy must never break a capture.
"""
import logging
import os
import urllib.request

log = logging.getLogger("wxsat.notify")


def notify(event, title, message, priority="default", tags=""):
    base = (os.environ.get("NTFY_URL") or "").rstrip("/")
    topic = os.environ.get("NTFY_TOPIC") or ""
    if not base or not topic:
        return False
    try:
        req = urllib.request.Request(
            f"{base}/{topic}",
            data=message.encode("utf-8"),
            method="POST",
            headers={
                "Title": title,
                "Priority": priority,
                "Tags": tags,
                "User-Agent": "wxsat-notify/1.0",  # non-default UA (some proxies 403 urllib)
            },
        )
        with urllib.request.urlopen(req, timeout=8):
            pass
        return True
    except Exception as e:  # noqa: BLE001 — best-effort
        log.warning("ntfy %s failed: %s", event, e)
        return False
```

- [ ] **Step 4: Run the test, verify it passes.**

Run: `cd terraform/modules/radio-compute && python3 -m unittest tests.test_wxsat_notify -v`
Expected: `OK` (3 tests).

- [ ] **Step 5: Hook the scheduler.** In `terraform/modules/radio-compute/wxsat_scheduler.py`, after the `import wxsat_predict as predict` line, add:

```python
import wxsat_notify  # noqa: E402
```
Then add a pass-start push where a real (non-dry-run) capture is launched, and a decode-complete push where the capture result is recorded. Concretely: locate the block that launches `CAPTURE_SCRIPT` for a due pass (near the `env = dict(os.environ, ...)` at ~:139) and immediately before the capture subprocess is spawned, add:

```python
            wxsat_notify.notify(
                "pass",
                f"Meteor pass: {p.get('satellite', 'METEOR-M2')}",
                f"AOS now — max elev {round(p.get('max_elev', 0))}deg, recording {int(dur)}s",
                tags="artificial_satellite",
            )
```
And after the capture+decode returns and the record dict (with sync/status) is built, add:

```python
            wxsat_notify.notify(
                "decode",
                f"Meteor decode: {rec.get('satellite', 'METEOR-M2')}",
                f"{rec.get('status', 'done')} — elev {round(rec.get('max_elev', 0))}deg"
                + (f", {rec['image']}" if rec.get("image") else ""),
                tags="satellite",
            )
```
(Match `p`/`dur`/`rec` to the actual local variable names in that function — read the surrounding code first; the field keys `satellite`/`max_elev`/`status`/`image` are the ones the scheduler already writes to `captures.json`.)

- [ ] **Step 6: Wire the file into the module + provisioner.** In `terraform/modules/radio-compute/main.tf`, in the templatefile map (near the other `wxsat_*_py = file(...)` lines ~:148-152), add:

```hcl
    wxsat_notify_py    = file("${path.module}/wxsat_notify.py")
```
In `terraform/modules/radio-compute/provision-radio.sh.tpl`: (a) add a write block for `wxsat_notify.py` next to the other `cat > /opt/wxsat/wxsat_*.py` writes (~:721); (b) add `/opt/wxsat/wxsat_notify.py` to the `chmod +x` line (:736); (c) in the `wxsat.env` fresh-write heredoc, add two keys:

```bash
NTFY_URL=
NTFY_TOPIC=
```

Write block to add (mirror the neighboring heredoc style):

```bash
cat > /opt/wxsat/wxsat_notify.py <<'PYEOF'
${wxsat_notify_py}
PYEOF
```

- [ ] **Step 7: Validate, deploy, live test.**

```bash
rsync -az terraform deploy@192.168.6.163:/home/deploy/platform/ && ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform validate && terraform apply -auto-approve -target="module.radio_compute.null_resource.provision"'
```
Then set ntfy live + send a test push:
```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 bash -s' <<'EOF'
sed -i 's#^NTFY_URL=.*#NTFY_URL=https://ntfy.sh#; s#^NTFY_TOPIC=.*#NTFY_TOPIC=<YOUR_TOPIC>#' /etc/radio-compute/wxsat.env
cd /opt/wxsat && NTFY_URL=https://ntfy.sh NTFY_TOPIC=<YOUR_TOPIC> python3 -c "import wxsat_notify; print(wxsat_notify.notify('test','Meteor test','wxsat wired on goes.srvr',tags='satellite'))"
systemctl restart wxsat-scheduler.service
EOF
```
Expected: prints `True` and a push arrives on the user's ntfy topic. (Replace `<YOUR_TOPIC>` with the user's chosen topic.)

- [ ] **Step 8: Commit.**

```bash
cd /home/rgardner/projects/platform
git add terraform/modules/radio-compute/wxsat_notify.py terraform/modules/radio-compute/tests/test_wxsat_notify.py terraform/modules/radio-compute/wxsat_scheduler.py terraform/modules/radio-compute/main.tf terraform/modules/radio-compute/provision-radio.sh.tpl
git commit -m "feat(wxsat): ntfy pass + decode alerts (best-effort)"
```

---

## Task 5: Dashboard Meteor tile

**Files:**
- Modify: `terraform/modules/dashboard/dashboard.py`
- Create: `terraform/modules/dashboard/tests/test_poll_meteor.py`
- Modify: `terraform/modules/dashboard/provision-dashboard.sh.tpl`

**Interfaces:**
- Consumes: radio app `RADIO_BASE` (`.84:8080`) `/api/wxsat/{status,passes,captures}` + `/api/wxsat/image/<relpath>`; helpers `_get_json`, `_ago`, `_num` already in `dashboard.py`.
- Produces: `poll_meteor() -> dict` tile `{title:"Meteor", icon, state, headline, detail, open_url, upcoming:[...], thumb_url}`; route `/api/proxy/meteor-latest.png`.

- [ ] **Step 1: Write the failing test.** Create `terraform/modules/dashboard/tests/test_poll_meteor.py`:

```python
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dashboard  # noqa: E402


class PollMeteorTest(unittest.TestCase):
    def test_down_when_status_unreachable(self):
        with mock.patch.object(dashboard, "_get_json", return_value=(None, "unreachable")):
            t = dashboard.poll_meteor()
        self.assertEqual(t["title"], "Meteor")
        self.assertEqual(t["state"], "down")

    def test_headline_from_next_pass_and_capture(self):
        def fake_get(url):
            if url.endswith("/api/wxsat/status"):
                return ({"state": "idle", "dry_run": False,
                         "next_pass": {"satellite": "METEOR-M2 4", "max_elev": 62,
                                       "aos_unix": 9999999999}}, None)
            if url.endswith("/api/wxsat/passes"):
                return ({"passes": [{"satellite": "METEOR-M2 4", "max_elev": 62,
                                     "aos_unix": 9999999999}]}, None)
            if url.endswith("/api/wxsat/captures"):
                return ({"captures": [{"satellite": "METEOR-M2 4", "image": "x/full.png",
                                       "thumb": "x/thumb.png", "status": "ok"}]}, None)
            return (None, "n/a")
        with mock.patch.object(dashboard, "_get_json", side_effect=fake_get):
            t = dashboard.poll_meteor()
        self.assertEqual(t["state"], "ok")
        self.assertIn("METEOR-M2 4", t["headline"])
        self.assertTrue(t["upcoming"])
        self.assertEqual(t["thumb_url"], "/api/proxy/meteor-latest.png")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd terraform/modules/dashboard && python3 -m unittest tests.test_poll_meteor -v`
Expected: FAIL — `AttributeError: module 'dashboard' has no attribute 'poll_meteor'`.

- [ ] **Step 3: Implement `poll_meteor` + the open-URL const.** In `terraform/modules/dashboard/dashboard.py`, near the other `OPEN_*` consts (~:49) add:

```python
OPEN_METEOR = os.environ.get("DASH_OPEN_METEOR", "https://radio.rg2.io/wxsat")
```
After `poll_goes()` (it ends ~:250), add:

```python
def poll_meteor():
    """Meteor-M2 LRPT tile: next passes (upcoming) + last decode (past)."""
    tile = {"title": "Meteor", "icon": "\U0001F6F0️", "open_url": OPEN_METEOR,
            "upcoming": [], "thumb_url": None}
    status, err = _get_json(f"{RADIO_BASE}/api/wxsat/status")
    if status is None:
        tile.update(state="down", headline="Offline", detail=err or "unreachable")
        return tile
    passes, _ = _get_json(f"{RADIO_BASE}/api/wxsat/passes")
    caps, _ = _get_json(f"{RADIO_BASE}/api/wxsat/captures")

    plist = (passes or {}).get("passes", []) if isinstance(passes, dict) else (passes or [])
    for p in plist[:3]:
        tile["upcoming"].append({
            "sat": p.get("satellite", "METEOR-M2"),
            "elev": _num(p.get("max_elev")),
            "aos": p.get("aos_unix"),
        })

    clist = (caps or {}).get("captures", []) if isinstance(caps, dict) else (caps or [])
    last_img = next((c for c in clist if c.get("image")), None)
    if last_img:
        tile["thumb_url"] = "/api/proxy/meteor-latest.png"

    state_word = (status.get("state") or "idle").lower()
    tile["state"] = "ok" if state_word in ("capturing", "decoding", "idle") else "warn"
    np = status.get("next_pass") or {}
    if np:
        tile["headline"] = f"Next: {np.get('satellite', 'METEOR-M2')} {round(_num(np.get('max_elev')) or 0)}deg {_ago(-(np.get('aos_unix', 0)))}".replace(" ago", "")
    else:
        tile["headline"] = state_word.capitalize()
    tile["detail"] = f"{len(tile['upcoming'])} upcoming | {len(clist)} captures"
    return tile
```
Register it: find the list where pollers are dispatched (the aggregate that builds `/api/dashboard` — search for `poll_goes` usage) and add `poll_meteor` alongside the others.

Add the proxy route: find the `/api/proxy/goes-latest.png` handler and add a sibling that fetches the newest wxsat capture's thumb. Near that handler:

```python
def _meteor_latest_thumb_path():
    caps, _ = _get_json(f"{RADIO_BASE}/api/wxsat/captures")
    clist = (caps or {}).get("captures", []) if isinstance(caps, dict) else (caps or [])
    c = next((c for c in clist if c.get("thumb") or c.get("image")), None)
    if not c:
        return None
    return c.get("thumb") or c.get("image")
```
In the request handler's route dispatch, add a branch for `/api/proxy/meteor-latest.png` that resolves `_meteor_latest_thumb_path()` and streams `{RADIO_BASE}/api/wxsat/image/<relpath>` (mirror exactly how `goes-latest.png` proxies bytes, including content-type + the down/placeholder path).

- [ ] **Step 4: Run the test, verify it passes.**

Run: `cd terraform/modules/dashboard && python3 -m unittest tests.test_poll_meteor -v`
Expected: `OK` (2 tests).

- [ ] **Step 5: Add the open-URL env default.** In `terraform/modules/dashboard/provision-dashboard.sh.tpl`, in the `dashboard.env` fresh-write heredoc, add:

```bash
DASH_OPEN_METEOR=https://radio.rg2.io/wxsat
```
(No new backend base — the tile reuses `DASH_RADIO_BASE`.)

- [ ] **Step 6: Validate, deploy, verify.**

```bash
rsync -az terraform deploy@192.168.6.163:/home/deploy/platform/ && ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform validate && terraform apply -auto-approve -target="module.dashboard.null_resource.provision"'
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.88 "curl -s localhost:8080/api/dashboard | python3 -m json.tool | grep -A2 Meteor"'
```
Expected: the aggregate JSON contains the Meteor tile with a state + headline. Then load `home.rg2.io` and confirm the Meteor tile renders with upcoming passes; if a capture exists, the thumbnail loads via `/api/proxy/meteor-latest.png`.

- [ ] **Step 7: Commit.**

```bash
cd /home/rgardner/projects/platform
git add terraform/modules/dashboard/dashboard.py terraform/modules/dashboard/tests/test_poll_meteor.py terraform/modules/dashboard/provision-dashboard.sh.tpl
git commit -m "feat(dashboard): Meteor tile (upcoming passes + last decode)"
```

---

## Task 6: Docs, end-to-end verification, PR

**Files:**
- Modify: `docs/session_notes.md`, `CLAUDE.md` (Current state + NPM map: radio.rg2.io/wxsat now decodes off goes.srvr), memory `wxsat-meteor-on-p24.md` (+ MEMORY.md pointer).

- [ ] **Step 1: End-to-end verification over a real pass.** After the next Meteor-M2 pass (check `/api/wxsat/passes` for the ETA), verify the whole chain:

```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 "curl -s localhost:8080/api/wxsat/captures | python3 -m json.tool | head -40"'
```
Expected: a new capture with an `image`, non-error `status`, and (from `wxsat_live`) a waterfall + track recorded; an ntfy "decode" push arrived; the `home.rg2.io` Meteor tile shows it. GOES stayed `active` throughout.

- [ ] **Step 2: Update docs.** Edit `docs/session_notes.md` (dated entry: Meteor LRPT revived on goes.srvr — serial-pinned GOES, repointed pi-wxsat, un-gated rack scheduler, ntfy + dashboard tile). Update `CLAUDE.md` Current-state bullet + the `radio.rg2.io` NPM-map note (wxsat now decodes off `goes.srvr`, not p24) + the pi-goes note (serial-pinned). Update the `wxsat-meteor-on-p24.md` memory to reflect the goes.srvr home + the two-RTL-pin lesson.

- [ ] **Step 3: Commit + PR.**

```bash
cd /home/rgardner/projects/platform
git add docs/ CLAUDE.md
git commit -m "docs: Meteor LRPT revived on the GOES Pi (serial-pin + wxsat cutover)"
git push -u origin meteor-lrpt-goes-pi
gh pr create --title "Meteor LRPT on the GOES Pi" --body "Serial-pin goes.service to the SMArTee (fix the two-RTL flake), repoint pi-wxsat to serve the Nooelec/rtl_tcp from goes.srvr, un-gate the rack wxsat scheduler + gallery, add ntfy alerts + a dashboard Meteor tile. Spec + plan in docs/superpowers/. 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review

**Spec coverage:** (1) serial-pin GOES → Task 1. (2) repoint pi-wxsat / rtl_tcp on goes.srvr → Task 2. (3) registry un-shelve → Tasks 1+2. (4) un-gate scheduler (Phase 1, both sats, low elev) → Task 3. (5) ntfy → Task 4. (6) dashboard tile → Task 5. (7) LNA/low-gain constraint → Global Constraints + Task 3 Step 2. (8) keep-if-absent gotchas → Global Constraints + Tasks 1/3. (9) blacklist/usbfs interaction → Task 2 Step 3. (10) docs/memory → Task 6. No gaps.

**Open values to fill at execution time (not placeholders — they require reading live hardware/user input):** `<NOOELEC_SN>` (Task 2 Step 1, read via `rtl_test`), `<YOUR_TOPIC>` (Task 4 Step 7, the user's ntfy topic). Both have explicit acquisition steps.

**Type consistency:** `notify(event,title,message,priority,tags)` defined in Task 4 Step 3, called with those kwargs in Steps 5+7. `poll_meteor()` returns the tile dict defined in Task 5 Step 3, asserted in Step 1. Capture field keys (`satellite`/`max_elev`/`status`/`image`/`thumb`) used consistently in Tasks 4 and 5, matching `captures.json` written by `wxsat_scheduler.py`.
