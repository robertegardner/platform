#!/usr/bin/env python3
"""wxsat_record_rtltcp.py — record a Meteor-M LRPT baseband from a remote rtl_tcp.

The Nooelec (Meteor V-dipole) lives on the OUTDOOR ADS-B Pi (p24) and is served
to the rack over the rtl_tcp protocol (wxsat-rtltcp.service on p24). This client
connects to that rtl_tcp, sets the tune/rate/gain, and writes raw CU8 IQ to a
file for the pass window. radio-compute's SatDump then decodes the file offline
(`satdump pipeline meteor_m2-x_lrpt baseband <file> <out> --baseband_format u8`).

Two robust stages (record -> decode) instead of a live SDR->pipeline source:
SatDump 2.0-alpha's file/baseband path is rock-solid and testable in isolation,
the rtl_tcp wire format is trivial CU8, and recording then decoding mirrors the
proven Pi offline-decode flow. All compute + storage stay on the rack.

rtl_tcp wire protocol:
  * On connect the server sends a 12-byte header: magic "RTL0" (4) +
    tuner_type (u32 BE) + tuner_gain_count (u32 BE).
  * The client sends 5-byte commands: [cmd:u8][param:u32 BE]. We use
    SET_FREQ(0x01), SET_SAMPLERATE(0x02), SET_GAIN_MODE(0x03),
    SET_GAIN(0x04), SET_FREQ_CORRECTION(0x05), SET_AGC_MODE(0x08).
  * Thereafter the server streams raw interleaved unsigned-8-bit I,Q (CU8).

Env (set by wxsat.env / the scheduler):
  WXSAT_RTLTCP_HOST (p24.srvr)  WXSAT_RTLTCP_PORT (1234)
  WXSAT_FREQ_HZ (137900000)     WXSAT_SAMPLERATE (1024000)
  WXSAT_GAIN_TENTHS ("" = AGC, else tenths of dB e.g. 400 = 40.0 dB)
  WXSAT_PPM (0)
Args: <output_cu8_path> <duration_seconds>
"""
import os
import signal
import socket
import struct
import sys
import time

MAGIC = b"RTL0"
SET_FREQ, SET_SAMPLERATE, SET_GAIN_MODE = 0x01, 0x02, 0x03
SET_GAIN, SET_FREQ_CORRECTION, SET_AGC_MODE = 0x04, 0x05, 0x08


def _cmd(sock, cmd, param):
    # param is unsigned 32-bit big-endian; allow signed (ppm) via two's complement.
    sock.sendall(struct.pack(">BI", cmd, param & 0xFFFFFFFF))


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: wxsat_record_rtltcp.py <out.cu8> <duration_s>\n")
        return 2
    out_path, duration = sys.argv[1], float(sys.argv[2])

    host = os.environ.get("WXSAT_RTLTCP_HOST", "p24.srvr")
    port = int(os.environ.get("WXSAT_RTLTCP_PORT", "1234"))
    freq = int(os.environ.get("WXSAT_FREQ_HZ", "137900000"))
    rate = int(os.environ.get("WXSAT_SAMPLERATE", "1024000"))
    gain_env = os.environ.get("WXSAT_GAIN_TENTHS", "").strip()
    ppm = int(os.environ.get("WXSAT_PPM", "0"))

    want_bytes = int(duration * rate) * 2  # CU8 = 2 bytes/sample (I,Q)
    sys.stderr.write(
        f"wxsat-record: {host}:{port} freq={freq} rate={rate} "
        f"gain={'AGC' if not gain_env else gain_env+'/10dB'} ppm={ppm} "
        f"-> {out_path} ({duration:.0f}s = {want_bytes/1e6:.0f} MB)\n")
    sys.stderr.flush()

    running = [True]
    signal.signal(signal.SIGTERM, lambda *_: running.__setitem__(0, False))
    signal.signal(signal.SIGINT, lambda *_: running.__setitem__(0, False))

    s = socket.create_connection((host, port), timeout=15)
    s.settimeout(15)
    hdr = b""
    while len(hdr) < 12:
        chunk = s.recv(12 - len(hdr))
        if not chunk:
            sys.stderr.write("wxsat-record: rtl_tcp closed before header\n")
            return 11
        hdr += chunk
    if hdr[:4] != MAGIC:
        sys.stderr.write(f"wxsat-record: bad rtl_tcp magic {hdr[:4]!r} (not a dongle?)\n")
        return 11

    # Order matters: rate first, then freq, then gain.
    _cmd(s, SET_SAMPLERATE, rate)
    _cmd(s, SET_FREQ, freq)
    _cmd(s, SET_FREQ_CORRECTION, ppm)
    if gain_env:
        _cmd(s, SET_GAIN_MODE, 1)        # manual
        _cmd(s, SET_GAIN, int(gain_env))
    else:
        _cmd(s, SET_GAIN_MODE, 0)        # hardware AGC
        _cmd(s, SET_AGC_MODE, 1)

    written = 0
    deadline = time.time() + duration
    tmp = out_path + ".part"
    with open(tmp, "wb", buffering=1 << 20) as f:
        while running[0] and written < want_bytes and time.time() < deadline:
            try:
                buf = s.recv(1 << 16)
            except socket.timeout:
                sys.stderr.write("wxsat-record: stream stalled (15s no data)\n")
                break
            if not buf:
                sys.stderr.write("wxsat-record: rtl_tcp closed mid-stream\n")
                break
            f.write(buf)
            written += len(buf)
    try:
        s.close()
    except OSError:
        pass

    os.replace(tmp, out_path)
    mb = written / 1e6
    sys.stderr.write(f"wxsat-record: wrote {mb:.0f} MB ({written/ (rate*2):.0f}s) to {out_path}\n")
    # Enough samples for a usable decode? (a too-short grab = no signal / early close)
    return 0 if written >= want_bytes * 0.5 else 12


if __name__ == "__main__":
    sys.exit(main())
