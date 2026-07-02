#!/usr/bin/env python3
"""noaa_stream.py — NOAA Weather Radio (NBFM) on the remote Airspy HF+.

Reads IQ from the HF+ via SoapySDR directly, forcing remote:prot=tcp as a STREAM
arg (the wbfm_stream.py pattern — rx_fm mangles SoapyRemote's MTU-sized partial
reads). Demods narrowband FM and emits s16le mono @ 16 kHz on stdout, for
ffmpeg -> rack Icecast /wx.mp3.

The HF+ is tuned OFFSET below the channel so the wanted carrier sits off the
zero-IF DC spike; a phase-continuous digital NCO recenters it. Two-stage
decimate (channel-select -> discriminate -> audio band-limit), with overlap-save
FIR history + carried discriminator/NCO phase across reads for clean audio.
numpy-only (matches wbfm_stream.py / am_stream.py).
"""
import os
import signal
import sys

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_CS16, SOAPY_SDR_RX

HW_RATE = 384000
DECIM1 = 8                       # 384k -> 48k (channel + discriminator rate)
IF_RATE = HW_RATE // DECIM1      # 48000
DECIM2 = 3                       # 48k -> 16k audio
AUDIO_RATE = IF_RATE // DECIM2   # 16000
CHAN_CUTOFF = 8000.0             # NBFM channel half-bw (~±5 kHz dev + skirt)
AUDIO_CUTOFF = 3500.0            # voice band-limit
DEEMPH_US = 75.0                 # de-emphasis time constant


def lowpass(taps, cutoff, fs, dtype):
    n = np.arange(taps) - (taps - 1) / 2
    h = np.sinc(2 * cutoff / fs * n) * np.hamming(taps)
    h /= h.sum()
    return h.astype(dtype)


class DecimFIR:
    """Decimating FIR with overlap-save history (phase-continuous across reads)."""

    def __init__(self, taps, decim, dtype):
        self.h = taps
        self.decim = decim
        self.hist = np.zeros(len(taps) - 1, dtype=dtype)

    def __call__(self, x):
        buf = np.concatenate([self.hist, x])
        y = np.convolve(buf, self.h, mode="valid")
        self.hist = buf[-(len(self.h) - 1):]
        return y[:: self.decim]


def read_env(path):
    env = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env


def main():
    src = read_env("/etc/radio-compute/source-hf-plus.env")
    soapy_args = os.environ.get("SOAPY_ARGS", src.get(
        "SOAPY_ARGS", "driver=remote,remote=tcp://radio.srvr:55002,remote:driver=airspyhf"))
    freq = float(os.environ.get("WX_FREQ", "162550000"))
    gain = float(os.environ.get("WX_GAIN", "32"))
    offset = float(os.environ.get("WX_OFFSET", "50000"))
    seconds = float(os.environ.get("WX_TEST_SECONDS", "0"))  # >0 = test mode

    dev = SoapySDR.Device(soapy_args)
    dev.setSampleRate(SOAPY_SDR_RX, 0, HW_RATE)
    try:
        dev.setGain(SOAPY_SDR_RX, 0, gain)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"noaa_stream: setGain failed: {e}\n")
    dev.setFrequency(SOAPY_SDR_RX, 0, freq - offset)
    sys.stderr.write(
        f"noaa_stream: {soapy_args} tune={freq-offset:.0f} chan={freq:.0f} "
        f"rate={dev.getSampleRate(SOAPY_SDR_RX,0):.0f} -> audio {AUDIO_RATE}\n")
    sys.stderr.flush()

    chan_fir = DecimFIR(lowpass(199, CHAN_CUTOFF, HW_RATE, np.complex64), DECIM1, np.complex64)
    audio_fir = DecimFIR(lowpass(127, AUDIO_CUTOFF, IF_RATE, np.float32), DECIM2, np.float32)
    deemph_a = np.float32(np.exp(-1.0 / (AUDIO_RATE * DEEMPH_US * 1e-6)))

    st = dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"remote:prot": "tcp"})
    dev.activateStream(st)

    chunk = 1 << 15
    raw = np.empty(2 * chunk, np.int16)
    nco_phase = 0.0
    nco_step = -2 * np.pi * offset / HW_RATE
    prev = np.complex64(1)
    deemph_z = np.float32(0)
    out = sys.stdout.buffer
    written = 0

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
        iq = iq.astype(np.complex64)
        # phase-continuous NCO: shift the +offset channel down to DC
        ph = nco_phase + nco_step * np.arange(1, n + 1)
        iq = iq * np.exp(1j * ph).astype(np.complex64)
        nco_phase = float(ph[-1])
        ch = chan_fir(iq)                       # 384k -> 48k, channel-selected
        if len(ch) == 0:
            continue
        # quadrature FM discriminator, carrying phase across reads
        d = np.empty(len(ch), np.complex64)
        d[0] = ch[0] * np.conj(prev)
        d[1:] = ch[1:] * np.conj(ch[:-1])
        prev = ch[-1]
        disc = np.angle(d).astype(np.float32)
        audio = audio_fir(disc)                 # 48k -> 16k
        # de-emphasis (one-pole) + gain
        for_out = np.empty(len(audio), np.float32)
        z = deemph_z
        a = deemph_a
        # vectorized one-pole via lfilter-equivalent loop kept tight
        for i in range(len(audio)):
            z = audio[i] * (1 - a) + z * a
            for_out[i] = z
        deemph_z = z
        s16 = np.clip(for_out * 12000.0, -32767, 32767).astype('<i2')
        out.write(s16.tobytes())
        written += len(s16)
        if seconds and written >= seconds * AUDIO_RATE:
            break

    dev.deactivateStream(st)
    dev.closeStream(st)


if __name__ == "__main__":
    main()
