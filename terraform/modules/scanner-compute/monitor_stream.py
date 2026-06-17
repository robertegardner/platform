#!/usr/bin/env python3
"""monitor_stream.py — on-demand FM/AM monitor on the remote Airspy R2 (discone).

Generalizes atc_stream.py to the V1 "monitor" tuner: tune any VHF/UHF channel in
NFM or AM (NOAA WX / Marine / EMS = NFM, aviation = AM), preempting P25. Reads the
R2 via SoapySDR (remote:prot=tcp STREAM arg, the wbfm_stream pattern — rx_fm
mangles SoapyRemote partial reads), demods, emits s16le mono @ 12.5 kHz on stdout
for ffmpeg -> rack Icecast. Phase-continuous across reads; carrier squelch.
Per-sample IIR loops run post-decimation (12.5k) to stay cheap. numpy-only.

Env: MON_FREQ (Hz), MON_MODE (am|nfm), MON_GAINS, MON_SQUELCH (carrier-level gate).
"""
import os
import signal
import sys

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_CS16, SOAPY_SDR_RX

HW_RATE = 2_500_000
D1, D2, D3 = 5, 5, 8                 # 2.5M -> 500k -> 100k -> 12.5k
R1 = HW_RATE // D1
RC = R1 // D2                        # 100k channel/demod rate
AUDIO_RATE = RC // D3                # 12.5k
STAGE1_CUT = 40_000.0
AUDIO_CUT = 3_400.0
OFFSET = 100_000.0                   # tune this far below the channel (off DC)
DEEMPH_US = 75.0


def lowpass(taps, cutoff, fs, dtype):
    n = np.arange(taps) - (taps - 1) / 2
    h = np.sinc(2 * cutoff / fs * n) * np.hamming(taps)
    return (h / h.sum()).astype(dtype)


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
    freq = float(os.environ.get("MON_FREQ", "120550000"))
    mode = os.environ.get("MON_MODE", "am").lower()
    gains = os.environ.get("MON_GAINS", "LNA:14,MIX:13,VGA:14")
    squelch = float(os.environ.get("MON_SQUELCH", "0.005"))
    chan_cut = 8000.0 if mode == "nfm" else 5500.0

    dev = SoapySDR.Device(soapy_args)
    dev.setSampleRate(SOAPY_SDR_RX, 0, HW_RATE)
    for pair in gains.split(","):
        if ":" in pair:
            name, val = pair.split(":")
            try:
                dev.setGain(SOAPY_SDR_RX, 0, name.strip(), float(val))
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"monitor: setGain {name} failed: {e}\n")
    dev.setFrequency(SOAPY_SDR_RX, 0, freq - OFFSET)
    sys.stderr.write(f"monitor: {mode.upper()} {freq:.0f} sq={squelch} "
                     f"rate={dev.getSampleRate(SOAPY_SDR_RX,0):.0f} -> audio {AUDIO_RATE}\n")
    sys.stderr.flush()

    s1 = DecimFIR(lowpass(63, STAGE1_CUT, HW_RATE, np.complex64), D1, np.complex64)
    s2 = DecimFIR(lowpass(127, chan_cut, R1, np.complex64), D2, np.complex64)
    s3 = DecimFIR(lowpass(127, AUDIO_CUT, RC, np.float32), D3, np.float32)
    deemph_a = np.float32(np.exp(-1.0 / (AUDIO_RATE * DEEMPH_US * 1e-6)))

    st = dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"remote:prot": "tcp"})
    dev.activateStream(st)
    chunk = 1 << 16
    raw = np.empty(2 * chunk, np.int16)
    nco_phase = 0.0
    nco_step = -2 * np.pi * OFFSET / HW_RATE
    prev = np.complex64(1)       # NFM discriminator continuity
    dc = np.float32(0)           # AM carrier DC estimate
    agc = np.float32(0.02)       # AM AGC
    deemph_z = np.float32(0)     # NFM de-emphasis
    out = sys.stdout.buffer

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
        ch = s2(s1(iq))                       # 2.5M -> 100k channel
        if len(ch) == 0:
            continue
        carrier = float(np.abs(ch).mean())
        if mode == "nfm":
            d = np.empty(len(ch), np.complex64)
            d[0] = ch[0] * np.conj(prev)
            d[1:] = ch[1:] * np.conj(ch[:-1])
            prev = ch[-1]
            audio = s3(np.angle(d).astype(np.float32))   # 100k -> 12.5k
            z = deemph_z
            for i in range(len(audio)):                   # de-emphasis @ 12.5k
                z = audio[i] * (1 - deemph_a) + z * deemph_a
                audio[i] = z
            deemph_z = z
            voice = audio * 4.0
        else:  # am
            env = s3(np.abs(ch).astype(np.float32))       # 100k env -> 12.5k (carrier+voice)
            agc = np.float32(0.9 * agc + 0.1 * max(carrier, 1e-4))
            d = dc
            voice = np.empty(len(env), np.float32)
            for i in range(len(env)):                     # DC-block @ 12.5k
                d = 0.999 * d + 0.001 * env[i]
                voice[i] = env[i] - d
            dc = d
            voice = voice / agc
        if carrier < squelch:
            voice = voice * 0.0
        s16 = np.clip(voice * 9000.0, -32767, 32767).astype('<i2')
        out.write(s16.tobytes())

    dev.deactivateStream(st)
    dev.closeStream(st)


if __name__ == "__main__":
    main()
