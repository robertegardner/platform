# comics-display

A rotating classic-comics display for the **Seeed reTerminal E1002** (7.3″ E Ink
Spectra 6, 6-colour, 800×480, ESP32-S3).

The panel is dumb on purpose: it wakes from deep sleep every few hours, does one
HTTP GET for a pre-rendered image, draws it, and sleeps. **All the work is
server-side** — this module is a small `stdlib + Pillow` HTTP service
(`comics.py`) that scrapes a pool of comic sources, fits each to 800×480, dithers
to the panel's 6-colour palette, and serves the current pick at a stable URL.

A web UI at `/` lets you **add / drop / enable / disable** sources live — no
redeploy.

```
 reTerminal E1002  ──GET /next.png──▶  comics-display (LXC)  ──scrape──▶  xkcd / gocomics / thefarside / any og:image page
   (deep sleep, wakes                    Pillow: fit 800×480,
    every N hours)          ◀──800×480───  dither → Spectra 6
                              6-colour PNG
```

## Endpoints

| Path | Purpose |
|------|---------|
| `GET /` | Source-management web UI (add/drop/enable/disable, live preview) |
| `GET /next.png` | **Device URL.** Advances the rotation, returns the next comic. Each wake = a new comic. |
| `GET /current.png` | The current comic without advancing (`.bmp` variants also served) |
| `GET /api/state` | JSON: all sources + per-source scrape status |
| `POST /api/sources` | Add a source `{name,type,palette,slug|url|mode}` |
| `POST /api/sources/<id>/toggle` · `/refresh` | Enable/disable · force re-scrape |
| `DELETE /api/sources/<id>` | Drop a source |

## Source types

| type | argument | notes |
|------|----------|-------|
| `xkcd` | — | Random strip via the official JSON API (CC-licensed) |
| `gocomics` | `slug` | `gocomics.com/<slug>` — today's strip (e.g. `calvinandhobbes`, `garfield`, `peanuts`) |
| `farside` | — | The Far Side "daily dose" homepage |
| `ogimage` | `url` | Any comic page — uses its `og:image` (covers most sites) |
| `image` | `url` | A direct link to an image file |

`palette` per source: `auto` (mono when the source is nearly greyscale, else
colour), `color` (full 6), or `mono` (black/white — best for line-art dailies
like The Far Side; avoids JPEG-speckle colour). Defaults seed XKCD + Calvin and
Hobbes + The Far Side on first run.

**Legal note:** intended for a single personal device pulling each source's own
current strip for private display — no redistribution. XKCD has a real API;
the scraped strips have no official feed, so those handlers are best-effort
against the public pages and degrade to the last good frame on failure.

## Deploy

Not wired into the root `main.tf` yet — pick a free vmid/IP (the platform LXCs
run 900–906; **907 / 192.168.6.89** is the next free slot) and add:

```hcl
module "comics_display" {
  source = "./modules/comics-display"

  vmid     = 907
  ip       = "192.168.6.89"
  gw       = var.gw
  vlan_id  = 0                 # Server VLAN, native untagged
  node     = var.node
  storage  = var.storage
  template = var.template
  bridge   = var.bridge

  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path
}
```

Then, from thebeast as `deploy`: `terraform apply`
(or re-provision only: `terraform taint 'module.comics_display.null_resource.provision' && terraform apply`).

Add an NPM proxy host (e.g. `comics.rg2.io → 192.168.6.89:8080`) if you want it
on the dashboard / behind TLS.

### Run standalone (no Terraform)

The service is self-contained — on any box with Python 3 + Pillow:

```bash
COMICS_DATA_DIR=./data python3 comics.py      # UI on :8080
```

## Firmware

`firmware/reterminal-e1002-comics.yaml` — ESPHome config for the panel
(requires ESPHome ≥ 2025.11.1 for the `Seeed-reTerminal-E1002` model). Set
`comic_url` to `http://<this-lxc-ip>:8080/next.png` and `refresh_hours`, add a
`secrets.yaml` with `wifi_ssid` / `wifi_password`, and flash.

The SPI `clk`/`mosi` pins are confirmed; the display `cs`/`dc`/`reset`/`busy`
pins are board-revision specific — if the panel stays blank, reconcile just
those against Seeed's official ESPHome cookbook example (everything else is
board-independent). Alternatively the same `/next.png` endpoint works as a TRMNL
"BYOS" image source if you prefer that firmware.

## Config (`/etc/comics-display/comics.env`, write-if-absent)

| var | default | meaning |
|-----|---------|---------|
| `COMICS_PORT` | 8080 | HTTP listen port |
| `COMICS_DATA_DIR` | `/var/lib/comics-display` | sources.json (UI-owned) + rendered frames |
| `COMICS_REFRESH_SEC` | 21600 | how long a scraped frame stays fresh (6 h) |
| `COMICS_AUTO_ADVANCE_SEC` | 0 | wall-clock preview auto-advance; 0 = device-driven only |
| `COMICS_TZ` | America/Chicago | local tz used to pick "today" for GoComics |

Source add/drop/enable is done in the **web UI**, not this file — `sources.json`
lives in the data dir and survives a re-apply.
