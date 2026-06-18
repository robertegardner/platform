#!/usr/bin/env python3
"""CW/BFO demod of a single carrier for aural Morse ID (e.g. an NDB beacon).

Tunes the carrier to an audio beat note (BFO offset) and writes s16le mono PCM to
stdout — pipe to ffmpeg → Icecast and listen. A keyed carrier (NDB A1A) is heard
as on/off Morse at the beat frequency; a dead spur is a steady tone. Defaults to
516 kHz on the remote HF+ YouLoop (:55002). No effect on the dx-R2/FM path.

  ndb-listen.py [FREQ_HZ] | ffmpeg -f s16le -ar 8000 -ac 1 -i - ... /ndb.mp3
"""
import signal
import sys

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_CF32

FREQ = float(sys.argv[1]) if len(sys.argv) > 1 else 516_000.0
DEV = "driver=remote,remote=radio.srvr:55002,remote:driver=airspyhf"
RATE = 192_000.0
BFO = 800.0          # audio beat note Hz (carrier lands here in baseband)
DECIM = 24           # 192k -> 8k out
OUT_RATE = int(RATE // DECIM)
BLOCK = 8160         # multiple of DECIM → no per-block decimation-phase drift
LO = FREQ - BFO

# Anti-alias lowpass (~3 kHz) before decimation to 8 kHz.
NT = 129
_n = np.arange(NT) - (NT - 1) / 2
TAPS = (np.sinc(2 * 3000 / RATE * _n) * np.hamming(NT)).astype(np.float32)
TAPS /= TAPS.sum()


def main():
    d = SoapySDR.Device(SoapySDR.KwargsFromString(DEV))
    d.setSampleRate(SOAPY_SDR_RX, 0, RATE)
    try:
        d.setAntenna(SOAPY_SDR_RX, 0, "RX")
    except Exception as e:
        sys.stderr.write(f"setAntenna: {e}\n")
    try:
        d.setGainMode(SOAPY_SDR_RX, 0, False)
    except Exception:
        pass
    d.setGain(SOAPY_SDR_RX, 0, 40)
    d.setFrequency(SOAPY_SDR_RX, 0, LO)
    sys.stderr.write(f"ndb-listen: {FREQ/1e3:.1f} kHz, LO {LO/1e3:.3f} kHz, "
                     f"BFO {BFO:.0f} Hz, out {OUT_RATE} Hz\n")
    sys.stderr.flush()
    st = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32, [0], {"remote:prot": "tcp"})
    d.activateStream(st)

    run = [True]
    signal.signal(signal.SIGTERM, lambda *a: run.__setitem__(0, False))
    signal.signal(signal.SIGINT, lambda *a: run.__setitem__(0, False))

    hist = np.zeros(NT - 1, np.complex64)
    acc = np.empty(0, np.complex64)
    buf = np.zeros(BLOCK, np.complex64)
    agc = np.float32(0.05)
    out = sys.stdout.buffer

    while run[0]:
        r = d.readStream(st, [buf], BLOCK, timeoutUs=200_000)
        if r.ret <= 0:
            continue
        acc = np.concatenate((acc, buf[:r.ret]))
        while len(acc) >= BLOCK:
            chunk = acc[:BLOCK]
            acc = acc[BLOCK:]
            ext = np.concatenate((hist, chunk))
            y = np.convolve(ext, TAPS, mode="valid").astype(np.complex64)
            hist = chunk[-(NT - 1):]
            audio = np.real(y[::DECIM]).astype(np.float32)   # beat-note tone
            # Slow RMS AGC (per-block EMA) — steady level without syllable pumping.
            rms = float(np.sqrt(np.mean(audio * audio)) + 1e-9)
            agc = np.float32(0.98) * agc + np.float32(0.02) * rms
            audio = np.clip(audio / float(agc) * 0.3, -1.0, 1.0)
            out.write((audio * 32767).astype("<i2").tobytes())

    d.deactivateStream(st)
    d.closeStream(st)


if __name__ == "__main__":
    main()
