#!/usr/bin/env python3
"""rtltcp_bridge.py — serve the remote Airspy R2 to op25 as an rtl_tcp source.

op25's gr-osmosdr soapy-remote source can't sustain the R2's 80 Mbps SoapyRemote
stream (it stalls after ~one buffer — it won't forward remote:prot=tcp to the
stream, so the transport stays lossy UDP), and op25 won't trunk from a file
source. But op25's rtl_tcp source IS a robust, tunable live source.

This reads the remote R2 via SoapySDR directly (tight loop, forcing
remote:prot=tcp as a STREAM arg — the thing gr-osmosdr can't do) and re-serves it
to op25 over the rtl_tcp wire protocol as CU8 @ 2.5 Msps (~40 Mbps, the same
profile as the retired RTL that op25 was happy with). op25's SET_FREQ commands
retune the R2, so trunk-following works exactly as before. numpy-only, to match
wbfm_stream.py / am_stream.py.
"""
import os
import socket
import struct
import sys
import threading

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_CS16, SOAPY_SDR_RX

PORT = int(os.environ.get("RTLTCP_PORT", "1234"))
RATE = float(os.environ.get("IQ_RATE", "2500000"))
FREQ0 = float(os.environ.get("IQ_FREQ", "769168750"))
GAINS = os.environ.get("IQ_GAINS", "LNA:15,MIX:15,VGA:15")
ARGS = os.environ.get(
    "SOAPY_ARGS", "driver=remote,remote=tcp://radio.srvr:55003,remote:driver=airspy"
)
# digital headroom: scale CS16 up before the >>8 to CU8 so the (low-level) airspy
# fills a usable share of the 8-bit range without clipping.
CU8_SHIFT = int(os.environ.get("CU8_SHIFT", "6"))  # x>>6 then +128 (i.e. x/64)


def log(msg):
    sys.stderr.write("rtltcp_bridge: " + msg + "\n")
    sys.stderr.flush()


def recvall(conn, n):
    buf = b""
    while len(buf) < n:
        c = conn.recv(n - len(buf))
        if not c:
            return None
        buf += c
    return buf


def serve(dev, conn):
    # rtl_tcp dongle-info header: magic 'RTL0', tuner type, tuner gain count.
    conn.sendall(b"RTL0" + struct.pack(">II", 5, 0))  # 5 = R820T
    stop = threading.Event()

    def cmd_loop():
        while not stop.is_set():
            hdr = recvall(conn, 5)
            if hdr is None:
                break
            cmd = hdr[0]
            param = struct.unpack(">I", hdr[1:5])[0]
            try:
                if cmd == 0x01:  # SET_FREQ (Hz)
                    dev.setFrequency(SOAPY_SDR_RX, 0, float(param))
                # 0x02 set rate, 0x03/0x04/0x05 gain/agc, etc. — sample rate is
                # fixed and gain is server-set; ignore so retuning stays clean.
            except Exception as exc:  # noqa: BLE001
                log(f"cmd 0x{cmd:02x}({param}) err: {exc}")
        stop.set()

    threading.Thread(target=cmd_loop, daemon=True).start()

    st = dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"remote:prot": "tcp"})
    dev.activateStream(st)
    chunk = 1 << 16
    raw = np.empty(2 * chunk, np.int16)
    try:
        while not stop.is_set():
            sr = dev.readStream(st, [raw], chunk, timeoutUs=1_000_000)
            if sr.ret > 0:
                # CS16 -> CU8 (rtl_tcp wire): scale up, center at 128, clamp.
                v = (raw[: 2 * sr.ret].astype(np.int32) >> CU8_SHIFT) + 128
                np.clip(v, 0, 255, out=v)
                conn.sendall(v.astype(np.uint8).tobytes())
            elif sr.ret < 0 and sr.ret != -1:  # ignore SOAPY_SDR_TIMEOUT
                log(f"readStream ret={sr.ret}")
    finally:
        stop.set()
        dev.deactivateStream(st)
        dev.closeStream(st)


def main():
    dev = SoapySDR.Device(ARGS)
    dev.setSampleRate(SOAPY_SDR_RX, 0, RATE)
    for pair in GAINS.split(","):
        if ":" in pair:
            name, val = pair.split(":")
            try:
                dev.setGain(SOAPY_SDR_RX, 0, name.strip(), float(val))
            except Exception as exc:  # noqa: BLE001
                log(f"setGain {name}={val} failed: {exc}")
    dev.setFrequency(SOAPY_SDR_RX, 0, FREQ0)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(1)
    log(f"listening 127.0.0.1:{PORT} freq={FREQ0:.0f} rate={RATE:.0f} gains={GAINS}")
    while True:
        conn, addr = srv.accept()
        log(f"client {addr} connected")
        try:
            serve(dev, conn)
        except Exception as exc:  # noqa: BLE001
            log(f"serve ended: {exc}")
        finally:
            conn.close()
            log("client gone")


if __name__ == "__main__":
    main()
