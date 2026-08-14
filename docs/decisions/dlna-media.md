# Serving downloads to the projector (DLNA / gerbera)

**Status:** in progress (2026-08-15) — built, pending first deploy and a playback test
from the projector.

## Why — the ask (verbatim)

> **Verbatim (2026-08-15):** "btw, so how can i use this homelab to stream or serve or
> watch the videos i downloaded on my hisense m2pro projector?"

The first answer assumed Google TV and recommended Jellyfin. Han corrected it:

> **Verbatim (2026-08-15):** "hisense m2 pro runs vidaaOS btw"

That correction is the hinge of the whole design — see Discussion. After three options
were laid out (Google TV dongle + Jellyfin / DLNA server / Plex):

> **Verbatim (2026-08-15):** "i like 2. and there is a 콘텐츠 공유 menu - make sure the
> phone/pc is on the same network ..."

Then, on the three follow-up forks:

> **Verbatim (2026-08-15):** selected "Gerbera (Recommended)", "Yes — separate incomplete
> dir (Recommended)", and "Disable the UI; config.xml in git (Recommended)".

## Discussion

### The client dictated the architecture

The initial recommendation (Jellyfin + native app) was wrong because it assumed the
projector ran Google TV. VIDAA is a **closed** ecosystem: no Jellyfin, Kodi, or VLC
client exists for it. Han's one-line correction invalidated the entire approach, which
is a good argument for naming the client platform before designing around it.

What VIDAA *does* have is a **콘텐츠 공유** ("content sharing") menu — Han confirmed it
exists and prompts to "make sure the phone/PC is on the same network". That phrasing is
diagnostic: it is a DLNA browser relying on same-subnet discovery. So DLNA became the
integration point, chosen *because the client already speaks it*, not on its own merits.

**Plex was the other native option and was rejected.** It genuinely has a VIDAA app
(VIDAA U4+; the M2 Pro runs U7.6). But direct-play failures on VIDAA are widely reported
— users routinely fall back to DLNA from the same Plex server. A failed direct play means
**server-side transcoding**, i.e. sustained CPU on a 7th-gen laptop chassis already
running Home Assistant, duri and a seeding torrent client. That is the exact load the
thermal budget exists to prevent. DLNA either direct-plays or fails honestly; it never
quietly costs CPU. Plex also wants an account, and hardware transcoding is a paid tier.

A **Google TV dongle + Jellyfin** was offered as the option that fixes the real
constraint (the OS, not the projector) and gives proper subtitle handling. Han chose the
no-extra-hardware path. It remains the escape hatch if DLNA's subtitle handling proves
too limiting — recorded in SPEC as the trigger, so the fallback isn't rediscovered.

### Volume sharing, never network sharing

The sharpest line in this design: gerbera reads the files transmission writes, but must
**not** join gluetun's network namespace. Doing so would make it unreachable from the
living room *and* would route a living-room video stream through Tokyo. So gerbera lives
in the **root** `compose.yaml`, not `torrent/compose.yaml` — the file boundary reinforces
the network boundary, which is the same reason the torrent stack got its own file.

### `network_mode: host` is forced, and that decides the access plane

DLNA discovery is SSDP multicast (`239.255.255.250:1900`), and docker bridge networks do
not carry multicast to the LAN. A bridged gerbera is never discovered — it would look
healthy while being invisible to the projector. So host networking is a **protocol
requirement**, not a convenience.

Its consequence settles the access plane by itself: host networking binds every
interface, so gerbera lands on **LAN + Tailscale (intentional), never public** — the
identical row Home Assistant already has, for the identical class of reason (a discovery
protocol that needs the host's LAN interface). This is worth stating plainly because
SPEC insists the access plane is "a mechanical decision made per service"; here the
mechanism made it, and the record should say so rather than imply a free choice.

It also reintroduces a familiar trap: **`ports:` is ignored under host networking**, and
compose does not error. Same silent-failure shape as `ports:` on a
`network_mode: service:` container in the torrent stack. Commented inline in both places.

### Why the admin UI is disabled

Because host networking cannot bind selectively, there is no way to put gerbera's admin
UI on loopback the way duri (`127.0.0.1:3000`) and transmission (`127.0.0.1:9091`) are.
The options were: leave an unauthenticated admin panel on the home LAN, add an account,
or turn the UI off. Turning it off costs nothing — **media still serves; only the admin
surface disappears** — and the library stays current through inotify autoscan declared in
the config file rather than through a Rescan button.

This also happens to fit the repo's "all config in git" rule better than the alternatives.
Gerbera, unlike transmission, does **not** rewrite its `config.xml` at runtime (state
lives in a separate SQLite DB), so the file can be the source of truth, mounted read-only.
That is why gerbera gets a tracked config file while transmission needed
`scripts/settings-transmission.sh` — the difference is not stylistic, it is whether the
program overwrites its own config.

### Two details that would have caused quiet breakage

- **The UDN is pinned in git.** Gerbera generates a random UUID per config. A changing
  UDN makes the projector treat the server as brand new on every restart, losing its
  place in 콘텐츠 공유. Fixed value in the tracked config.
- **Gerbera points at `complete/`, not the parent.** transmission writes in-progress
  files to a sibling `incomplete/` and moves them on completion — same filesystem, so an
  atomic rename rather than a copy. Pointing gerbera at the parent would surface
  half-written files as broken entries. Worth noting this separation was **already the
  linuxserver image's default** (`incomplete-dir-enabled: true`), discovered by reading
  the running container's `settings.json` rather than assumed; the decision cost nothing
  to implement.

### Known limitation, accepted

**External `.srt` subtitles are unreliable over DLNA** and vary by renderer. Media with
embedded subtitle tracks is the path that works. Accepted rather than solved: solving it
properly means a real client app, i.e. the dongle + Jellyfin option. Recorded so the
limitation is a known tradeoff rather than a surprise.

### Open questions

- **Not yet playback-tested from the projector.** Discovery via 콘텐츠 공유 and actual
  direct play of a real file both need confirming on the device.
- **Codec support on VIDAA is unverified.** If common release formats (e.g. HEVC 10-bit)
  fail to direct-play, there is no transcoding fallback by design — that would be the
  second trigger for the dongle route.
