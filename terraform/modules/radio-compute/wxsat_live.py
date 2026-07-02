#!/usr/bin/env python3
"""Live per-pass telemetry for the /wxsat page (RACK variant).

Short-lived sidecar that wxsat_capture_rack.sh launches for the lifetime of one
capture. Writes /run/sdr-streams/wxsat_live.json a few times a second so the web
UI shows, in real time, what the tuner is hearing/seeing:

  recording phase — spectrum/waterfall row + level read from the growing CU8
                    baseband (baseband.cu8.part), plus the satellite az/el and
                    the pass arc (cached TLE via pyorbital).
  decoding phase  — SatDump sync state (deframer/viterbi) scraped from capture.log.

Differs from the Pi sidecar: the rack records CU8 (not CS16) to a `.part` file
during recording, and the capture log markers are `wxsat-rack: ...`.

BEST-EFFORT: every loop is wrapped; an error just skips a frame. Read-only on the
IQ. The capture script kills it on exit; it also self-terminates when the decode
finishes or a deadline passes.

Env (set by wxsat_capture_rack.sh): WXSAT_OUT_DIR WXSAT_AOS WXSAT_LOS WXSAT_SAT
  WXSAT_NORAD WXSAT_SAMPLERATE WXSAT_FREQ_HZ
"""
import json
import os
import signal
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

LIVE_PATH = Path(os.environ.get("WXSAT_LIVE_PATH",
                                "/run/sdr-streams/wxsat_live.json"))
TLE_DIR = Path(os.environ.get("WXSAT_TLE_DIR", "/var/lib/sdr-streams/wxsat/tle"))

FFT_RAW = 4096
FFT_BINS = 256
TAIL_SAMPLES = 131072   # complex samples read from the end of the file per frame
POLL_S = 1.5


def _iq_file(out_dir):
    """The recorder writes baseband.cu8.part while recording, renames at the end."""
    part = out_dir / "baseband.cu8.part"
    return part if part.exists() else out_dir / "baseband.cu8"


def _atomic_write(payload):
    try:
        LIVE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = LIVE_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload))
        os.replace(tmp, LIVE_PATH)
    except OSError:
        pass


def _spectrum_and_level(iq_path):
    """(fft_db_list, rms, peak_pct) from the tail of the growing CU8 file."""
    try:
        size = iq_path.stat().st_size
    except OSError:
        return None, None, None
    nbytes = TAIL_SAMPLES * 2          # CU8 = 2 bytes per complex sample
    start = max(0, (size - nbytes) // 2 * 2)
    try:
        with open(iq_path, "rb") as f:
            f.seek(start)
            buf = f.read(nbytes)
    except OSError:
        return None, None, None
    u = np.frombuffer(buf, dtype=np.uint8)
    u = u[: (u.size // 2) * 2].astype(np.float32) - 127.5
    if u.size < 2 * FFT_RAW:
        return None, None, None
    iq = u[0::2] + 1j * u[1::2]
    rms = float(np.sqrt(np.mean(u * u)))
    peak_pct = round(100.0 * float(np.abs(u).max()) / 127.5, 2)

    win = np.hanning(FFT_RAW).astype(np.float32)
    acc = np.zeros(FFT_RAW)
    nwin = min(8, iq.size // FFT_RAW)
    for k in range(nwin):
        seg = iq[k * FFT_RAW:(k + 1) * FFT_RAW]
        acc += np.abs(np.fft.fftshift(np.fft.fft(seg * win))) ** 2
    psd = 10.0 * np.log10(acc / nwin + 1e-9)
    psd -= np.median(psd)
    psd = psd.reshape(FFT_BINS, FFT_RAW // FFT_BINS).mean(axis=1)
    psd = np.clip(psd, -5.0, 45.0)
    return [round(float(v), 1) for v in psd], round(rms, 1), peak_pct


class SkyTrack:
    def __init__(self, norad, lat, lon, alt_km):
        self.ok = False
        self.lat, self.lon, self.alt = lat, lon, alt_km
        try:
            from pyorbital.orbital import Orbital
            lines = (TLE_DIR / f"{norad}.tle").read_text().splitlines()
            self.orb = Orbital(lines[0].strip(), line1=lines[1].strip(),
                               line2=lines[2].strip())
            self.ok = True
        except Exception:
            self.orb = None

    def look(self, unix_t):
        if not self.ok:
            return None
        try:
            dt = datetime.fromtimestamp(unix_t, timezone.utc).replace(tzinfo=None)
            az, el = self.orb.get_observer_look(dt, self.lon, self.lat, self.alt)
            return round(float(az), 1), round(float(el), 1)
        except Exception:
            return None

    def arc(self, aos, los, n=48):
        if not (self.ok and los > aos):
            return []
        out = []
        for k in range(n + 1):
            t = aos + (los - aos) * k / n
            lk = self.look(t)
            if lk:
                out.append([int(t), lk[1], lk[0]])
        return out


def _parse_decode(log_path):
    """SatDump 2.0 sync state from capture.log (JSON-ish deframer/viterbi lines)."""
    out = {"decode_pct": None, "snr": None, "viterbi": None,
           "deframer": None, "done": False, "synced": None}
    try:
        size = log_path.stat().st_size
        with open(log_path, "r", errors="replace") as f:
            f.seek(max(0, size - 16384))
            lines = f.read().splitlines()
    except OSError:
        return out
    for ln in lines:
        if '"deframer_state"' in ln:
            out["deframer"] = "SYNC" if "SYNCED" in ln else "NOSYNC"
        if '"viterbi_state"' in ln:
            out["viterbi"] = "SYNCED" if "SYNCED" in ln else "NOSYNC"
        if '"viterbi_ber"' in ln:
            try:
                out["snr"] = None  # 2.0 logs BER not SNR; leave SNR None
            except (ValueError, IndexError):
                pass
        if "produced an image" in ln:
            out["synced"] = True
        if "no pipeline produced an image" in ln:
            out["synced"] = False
        if "wxsat-rack: capture complete" in ln or "no pipeline produced an image" in ln:
            out["done"] = True
    return out


def _read_tail(log_path, n=524288):
    try:
        size = log_path.stat().st_size
        with open(log_path, "r", errors="replace") as f:
            f.seek(max(0, size - n))
            return f.read()
    except OSError:
        return ""


def main():
    out_dir = Path(os.environ.get("WXSAT_OUT_DIR", ""))
    if not out_dir.name:
        return
    log_path = out_dir / "capture.log"
    aos = int(os.environ.get("WXSAT_AOS") or 0)
    los = int(os.environ.get("WXSAT_LOS") or 0)
    sat = os.environ.get("WXSAT_SAT") or "Meteor-M"
    norad = os.environ.get("WXSAT_NORAD") or ""
    try:
        fs = int(float(os.environ.get("WXSAT_SAMPLERATE", "1024000")))
    except ValueError:
        fs = 1024000
    try:
        freq_mhz = float(os.environ.get("WXSAT_FREQ_HZ", "137900000")) / 1e6
    except ValueError:
        freq_mhz = 137.9

    lat, lon, alt = 37.31, -89.55, 0.1
    try:
        import wxsat_predict as predict
        cfg = predict.load_config()
        lat, lon, alt = cfg["lat"], cfg["lon"], cfg["alt_km"]
    except Exception:
        pass

    track = SkyTrack(norad, lat, lon, alt)
    arc = track.arc(aos, los) if (aos and los) else []

    snapshot_path = out_dir / "pass.json"
    wf_rows, lvl = [], []
    best_snr = [None]
    last_decode = [{}]
    half_khz = min(250.0, fs / 2000.0)

    def save_snapshot():
        def thin(seq, m=240):
            if len(seq) <= m:
                return seq
            step = len(seq) / m
            return [seq[int(i * step)] for i in range(m)]
        snap = {
            "satellite": sat, "norad": norad, "aos_unix": aos, "los_unix": los,
            "max_elev": (round(max((r[1] for r in arc)), 1) if arc else None),
            "samplerate": fs, "freq_mhz": freq_mhz, "half_khz": round(half_khz, 1),
            "waterfall": thin(wf_rows), "level": thin(lvl), "track": arc,
            "decode": {**last_decode[0], "best_snr": best_snr[0]},
            "saved": int(time.time()),
        }
        try:
            tmp = snapshot_path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(snap))
            os.replace(tmp, snapshot_path)
        except OSError:
            pass

    def _on_term(*_):
        save_snapshot()
        os._exit(0)
    try:
        signal.signal(signal.SIGTERM, _on_term)
    except (ValueError, OSError):
        pass

    deadline = time.time() + (max(1800, (los - time.time()) + 1800) if los else 1800)
    tick = 0
    while time.time() < deadline:
        try:
            now = time.time()
            tick += 1
            logtext = _read_tail(log_path)
            decoding = "wxsat-rack: decoding" in logtext
            done = ("wxsat-rack: capture complete" in logtext
                    or "no pipeline produced an image" in logtext)

            payload = {
                "updated": int(now), "satellite": sat, "norad": norad,
                "aos_unix": aos, "los_unix": los,
                "samplerate": fs, "freq_mhz": freq_mhz,
                "phase": "decoding" if decoding else "recording",
            }

            if decoding:
                dec = _parse_decode(log_path)
                payload.update(dec)
                payload["done"] = done or dec.get("done")
                last_decode[0] = {k: dec.get(k) for k in
                                  ("decode_pct", "snr", "viterbi", "deframer", "synced")}
                _atomic_write(payload)
                if tick % 8 == 0:
                    save_snapshot()
                if payload["done"]:
                    break
            else:
                fft, rms, peak = _spectrum_and_level(_iq_file(out_dir))
                lk = track.look(now)
                if fft is not None:
                    wf_rows.append(fft)
                    lvl.append([int(now), peak, rms])
                payload.update({
                    "fft": fft, "rms": rms, "peak_pct": peak,
                    "elev": lk[1] if lk else None,
                    "azim": lk[0] if lk else None,
                    "track": arc,
                })
                _atomic_write(payload)
                if tick % 8 == 0:
                    save_snapshot()
        except Exception:
            pass
        time.sleep(POLL_S)

    save_snapshot()
    try:
        LIVE_PATH.unlink()
    except OSError:
        pass


if __name__ == "__main__":
    main()
