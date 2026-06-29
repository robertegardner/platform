#!/usr/bin/env python3
"""Cross-check Meteor-M2 4 pass predictions: cached TLE vs a freshly fetched one,
printed in CDT (UTC-5) for comparison against n2yo.com. Run on .84 (pyorbital)."""
import datetime
import json
import urllib.request

from pyorbital.orbital import Orbital

LAT, LON, ALT = 37.31, -89.55, 0.1
NORAD = 59051
CDT = datetime.timezone(datetime.timedelta(hours=-5))
HORIZON = 0
MIN_EL = 10


def load_cached():
    ls = open(f"/var/lib/sdr-streams/wxsat/tle/{NORAD}.tle").read().splitlines()
    return ls[0].strip(), ls[1].strip(), ls[2].strip()


def fetch_fresh():
    url = f"https://tle.ivanstanojevic.me/api/tle/{NORAD}"
    req = urllib.request.Request(url, headers={"User-Agent": "verify/1.0"})
    d = json.load(urllib.request.urlopen(req, timeout=15))
    return d.get("name", "METEOR-M2 4"), d["line1"], d["line2"]


def epoch_age(l1):
    yy = int(l1[18:20]); doy = float(l1[20:32])
    e = datetime.datetime(2000 + yy, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(days=doy - 1)
    age = (datetime.datetime.now(datetime.timezone.utc) - e).total_seconds() / 3600
    return e, age


def passes(name, l1, l2, hours=26):
    orb = Orbital(name, line1=l1, line2=l2)
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    out = []
    for rise, fall, maxt in orb.get_next_passes(now, hours, LON, LAT, ALT, horizon=HORIZON):
        _, el = orb.get_observer_look(maxt, LON, LAT, ALT)
        if el < MIN_EL:
            continue
        out.append((rise, fall, maxt, el))
    return out


for label, tle in [("CACHED (what the scheduler uses)", load_cached()),
                   ("FRESH (fetched just now)", fetch_fresh())]:
    name, l1, l2 = tle
    e, age = epoch_age(l1)
    print(f"\n=== {label}: {name}  epoch {e:%Y-%m-%d %H:%M}Z ({age:.1f}h old) ===")
    for rise, fall, maxt, el in passes(name, l1, l2):
        rc = rise.replace(tzinfo=datetime.timezone.utc).astimezone(CDT)
        mc = maxt.replace(tzinfo=datetime.timezone.utc).astimezone(CDT)
        print(f"  AOS {rc:%a %m/%d %I:%M %p} CDT  | TCA {mc:%I:%M %p}  | max {el:.0f} deg  | {(fall-rise).seconds//60} min")
