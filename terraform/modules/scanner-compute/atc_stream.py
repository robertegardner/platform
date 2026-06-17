#!/usr/bin/env python3
"""atc_stream.py — VHF airband AM demod on the remote Airspy R2 (discone).

On-demand ATC listening; preempts P25 (see atc-listen@.service). Reads the R2
via SoapySDR directly (remote:prot=tcp as a STREAM arg, the wbfm_stream.py
pattern — rx_fm mangles SoapyRemote partial reads), AM envelope-demods one
airband channel with AGC + carrier squelch, emits s16le mono @ 12.5 kHz on
stdout for ffmpeg -> rack Icecast /scanner-atc.mp3.

The R2 is tuned OFFSET below the channel so the carrier sits off the zero-IF DC
spike; a phase-continuous NCO recenters it. Decimation cascade 2.5M -> 12.5k.
numpy-only (matches wbfm_stream.py / noaa_stream.py).
"""
import os
import signal
import sys

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_CS16, SOAPY_SDR_RX

HW_RATE = 2_500_000
D1, D2, D3 = 5, 5, 8                 # 2.5M -> 500k -> 100k -> 12.5k
R1 = HW_RATE // D1                   # 500_000
R2 = R1 // D2                        # 100_000  (channel + envelope rate)
AUDIO_RATE = R2 // D3                # 12_500
STAGE1_CUT = 40_000.0               # anti-alias for the first ÷5 at 2.5M
CHAN_CUT = 5_500.0                  # AM channel half-bw (~±5 kHz airband)
AUDIO_CUT = 3_200.0                 # voice band-limit
OFFSET = 100_000.0                  # tune this far below the channel (off DC)
SQUELCH = float(os.environ.get("ATC_SQUELCH", "0.005"))  # carrier-level gate


def lowpass(taps, cutoff, fs, dtype):
    n = np.arange(taps) - (taps - 1) / 2
    h = np.sinc(2 * cutoff / fs * n) * np.hamming(taps)
    h /= h.sum()
    return h.astype(dtype)


class DecimFIR:
    def __init__(self, taps, decim, dtype):
        self.h = taps
        self.decim = decim
        self.hist = np.zeros(len(taps) - 1, dtype=dtype)

    def __call__(self, x):
        buf = np.concatenate([self.hist, x])
        y = np.convolve(buf, self.h, mode="valid")
        self.hist = buf[-(len(self.h) - 1):]
        return y[:: self.decim]


def main():
    soapy_args = os.environ.get(
        "SOAPY_ARGS", "driver=remote,remote=tcp://radio.srvr:55003,remote:driver=airspy")
    freq = float(os.environ.get("ATC_FREQ", "120550000"))
    gains = os.environ.get("ATC_GAINS", "LNA:14,MIX:13,VGA:14")

    dev = SoapySDR.Device(soapy_args)
    dev.setSampleRate(SOAPY_SDR_RX, 0, HW_RATE)
    for pair in gains.split(","):
        if ":" in pair:
            name, val = pair.split(":")
            try:
                dev.setGain(SOAPY_SDR_RX, 0, name.strip(), float(val))
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"atc_stream: setGain {name} failed: {e}\n")
    dev.setFrequency(SOAPY_SDR_RX, 0, freq - OFFSET)
    sys.stderr.write(
        f"atc_stream: tune={freq-OFFSET:.0f} chan={freq:.0f} rate={dev.getSampleRate(SOAPY_SDR_RX,0):.0f}"
        f" -> audio {AUDIO_RATE}\n")
    sys.stderr.flush()

    s1 = DecimFIR(lowpass(63, STAGE1_CUT, HW_RATE, np.complex64), D1, np.complex64)
    s2 = DecimFIR(lowpass(127, CHAN_CUT, R1, np.complex64), D2, np.complex64)
    s3 = DecimFIR(lowpass(127, AUDIO_CUT, R2, np.float32), D3, np.float32)

    st = dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"remote:prot": "tcp"})
    dev.activateStream(st)

    chunk = 1 << 16
    raw = np.empty(2 * chunk, np.int16)
    nco_phase = 0.0
    nco_step = -2 * np.pi * OFFSET / HW_RATE
    dc = np.float32(0)            # carrier DC estimate (for envelope DC-block)
    agc = np.float32(0.02)        # slow envelope average (AGC)
    out = sys.stdout.buffer
    blk = 0
    carrier_max = 0.0

    running = [True]
    def stop(*_):
        running[0] = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while running[0]:
        sr = dev.readStream(st, [raw], chunk, timeoutUs=1_000_000)
        if sr.ret <= 0:
            continue
        n = sr.ret
        iq = (raw[:2 * n:2].astype(np.float32) + 1j * raw[1:2 * n:2].astype(np.float32)) / 32768.0
        ph = nco_phase + nco_step * np.arange(1, n + 1)
        iq = (iq * np.exp(1j * ph)).astype(np.complex64)
        nco_phase = float(ph[-1])
        ch = s2(s1(iq))                          # 2.5M -> 100k, channel-selected
        if len(ch) == 0:
            continue
        env = np.abs(ch).astype(np.float32)      # AM envelope
        # carrier level (slow) for AGC + squelch
        carrier = float(env.mean())
        carrier_max = max(carrier_max, carrier)
        blk += 1
        if blk % 30 == 0:
            sys.stderr.write(f"atc_stream: carrier~{carrier:.4f} (peak {carrier_max:.4f}) squelch={SQUELCH}\n")
            sys.stderr.flush()
            carrier_max = 0.0
        agc = np.float32(0.9 * agc + 0.1 * max(carrier, 1e-4))
        # DC-block (remove carrier) -> voice, normalize by AGC
        dcv = np.empty(len(env), np.float32)
        d = dc
        for i in range(len(env)):
            d = 0.9995 * d + 0.0005 * env[i]
            dcv[i] = env[i] - d
        dc = d
        voice = dcv / agc
        if carrier < SQUELCH:                    # squelch: silence between calls
            voice[:] = 0.0
        audio = s3(voice)                        # 100k -> 12.5k
        s16 = np.clip(audio * 9000.0, -32767, 32767).astype('<i2')
        out.write(s16.tobytes())

    dev.deactivateStream(st)
    dev.closeStream(st)


if __name__ == "__main__":
    main()
