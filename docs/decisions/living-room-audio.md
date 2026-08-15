# Living-room audio — one speaker, two sources, one physical switch

**Status:** in progress (2026-08-16) — the routing fix is live and verified by hand;
Rung 1 (HA input-switch script) is built and pending first deploy. Rung 2 deliberately
deferred; see Discussion.

## Why — the ask (verbatim)

> **Verbatim (2026-08-16):** "i want to make my homelab as a home hub. i have an ipad. a
> marshall speaker (acton iii) that has a wiim mini attached to it. i have a projector
> (hisense m2pro - vidaaOS).
>
> the marshall speaker has a switch that switches between aux and bluetooth. i use both -
> aux for the wiim mini for music. and bluetooth for the projector. it is pretty annoying
> switching between the two. whenever i want to listen to music, i have to physically click
> the switch to aux. default to bluetooth as we use the projector more often.
>
> i want to use my homelab, if possible, to make these things easier. i also want to use
> the ipad mini or the homelab as a music hub."

After the projector was re-pointed at the WiiM and tested:

> **Verbatim (2026-08-16):** "hmm auto switching doesn't work 100%.
>
> * playing on projector (bluetooth) then switch to using phone. switches fine.
> * playing on phone (wifi) then switch to projector. projector uses device sound. i need to
>   go to settings then connect (cause it's already paired) then it plays."

The observation that cracked the diagnosis:

> **Verbatim (2026-08-16):** "ah before, whenever i clicked on the aux-bt switch on the
> marshall, my projector connected automatically to the marshall speakers. possibly because
> no other device is connected to it via bt? not sure though"

On the music-hub half, the requirement that turned out to be the whole thing:

> **Verbatim (2026-08-16):** "for music hub, i want to start playing something from my
> iphone, but i want to move on without having the speaker stop. ie) start playing music on
> the speaker using my iphone, but also watch some youtube using my phone afterwards"

> **Verbatim (2026-08-16):** "hmm spotify/tidal any free alternatives?"

On the config-location fork (edit `configuration.yaml` in the volume vs. a git-tracked
package fragment), and on the deferral of Rung 2:

> **Verbatim (2026-08-16):** "B."

> **Verbatim (2026-08-16):** "why is rung 2 not recommended?"

## Discussion

### The constraint that dictated everything

The Marshall Acton III is a **dumb amp**: Bluetooth 5.2 and a 3.5 mm aux in, no Wi-Fi, no
AirPlay, no network control of any kind. One input is active at a time and it is chosen by
a **physical selector**. No homelab software will ever flip it.

So the design could not be "automate the switch." It had to be **make the switch
irrelevant** — route everything through one input, permanently, and never touch it again.
Aux was the only candidate, because the WiiM Mini already sits there and is the only device
in the chain that can accept a second source.

### Verifying the hardware first paid for itself

Three facts were checked against vendor documentation rather than assumed, and one of them
was wrong in the popular sources:

- **WiiM Mini can act as a Bluetooth receiver** — selectable input, auto-switches when a
  paired device connects. This is the load-bearing fact and it held. (Amusingly, WiiM's own
  forum carries complaints that BT auto-switch is *too* aggressive; that bug is this
  design's feature.)
- **Hisense M2 Pro has NO 3.5 mm output and no optical out.** Audio leaves it by exactly two
  paths: Bluetooth or HDMI eARC. Several review sites claim a headphone jack; Hisense's own
  spec sheet and the hands-on teardown both say otherwise. A whole wired branch — passively
  summing the projector and the WiiM into the Marshall's aux — was designed on the false
  claim and had to be discarded. **This is the `verify against the artifact` rule earning
  its keep**; the branch would have been built before the missing jack was discovered.
- **Marshall Acton III** — confirmed dumb amp, as above.

### The architecture

```
   iPhone / iPad / Mac ──AirPlay 2 / Spotify Connect over Wi-Fi──┐
                                                                  ├──→ WiiM Mini ──3.5mm──→ Marshall
   Hisense M2 Pro ──────Bluetooth───────────────────────────────┘        (one active         (locked
                        ↑ the ONE BT slot — projector only                 input)              on AUX)
```

**Cost: nothing.** Every device was already owned. The Marshall's selector goes to AUX and
is never touched again, which is precisely the complaint in the opening ask.

**The discipline that keeps it working: never pair a phone to the WiiM over Bluetooth.**
The WiiM holds one active BT connection, so a phone would contend with the projector for it,
and the WiiM's aggressive input auto-switching makes that contention ugly. Phones use
AirPlay or Spotify Connect — unlimited, uncompressed by BT, and they leave the slot alone.

### The ceiling, stated plainly

**The WiiM has exactly one active input.** Music and projector audio can never both be live
on it. This is structural, not a setting, and it means there will always be *some* gesture
going music → projector. Software can shrink that gesture; it cannot delete it.

Only the wired topology (eARC extractor + analog mixer, both sources permanently summed)
deletes it. That was priced at roughly ₩60–100k, costs the projector's single HDMI port
unless the extractor has passthrough, and was **not** taken — the gesture is now one tap.

### Why the friction was misdiagnosed twice, and what it actually was

First guess: the WiiM's auto-switching was failing. Wrong — the projector→music direction
works fine; it is only music→projector that stalls.

Second guess: VIDAA never re-initiates a Bluetooth connection, so it falls back to its
internal speakers. This is **true and documented**, and it looked like a dead end, because
the community Hisense integration for HA does not expose arbitrary remote key codes
("expose all keys as buttons" is still on its TBD list) — so HA could not drive the
projector's menu to reconnect.

Han's observation about the old setup is what broke it open. The Marshall appeared to
reconnect "automatically," which contradicted VIDAA never initiating. The resolution:

> **Flipping the Marshall's switch to BT *was* the reconnect gesture.** Entering Bluetooth
> mode makes the Marshall — a dedicated BT sink — re-initiate the link to its last paired
> source. VIDAA never initiates, but it happily *accepts*. There was never any auto-reconnect
> to lose.

His own guess ("possibly because no other device is connected to it via bt") was not the
mechanism — the Acton III supports two simultaneous BT connections, so nothing needed
freeing. The trigger was entering BT mode, not the slot being empty.

That relocates the fix from the projector (unreachable) to **the WiiM (very reachable)**.
Selecting the WiiM's Bluetooth input makes it re-initiate, and the projector accepts —
confirmed by hand before anything was built.

### Why the local HTTP API, and not `select_source`

None of the three `media_player` entities expose a `source_list`, so
`media_player.select_source` is unavailable. The fallback turned out to be the better path
anyway: WiiM publishes a **local HTTP API** (`setPlayerCmd:switchmode:bluetooth`), so this
needs no HACS, no third-party code inside HA, and no new integration — just a
`rest_command`. That sidesteps the attack-surface tradeoff `plan/home-assistant-followups.md`
flags for HACS.

A trap worth recording: the community WiiM integration advertises "Audio Output Mode — Line
Out, Optical, Coax, Bluetooth." That is **output** mode (BT transmit). What this design needs
is the **input** switch. Installing it expecting this to work would waste an evening.

Two operational facts that bit during diagnosis and are now encoded in `ha/packages/wiim.yaml`:

- The WiiM is on **Wi-Fi**, so its address must be DHCP-reserved (MAC `40:D9:5A:2F:34:EC`)
  or the hardcoded IP breaks silently.
- `wiim-Living-Room.local` **also resolves publicly** (`218.38.137.27`) via the ISP's DNS
  wildcard. Using the hostname risks sending the command to the open internet. Use the IP.

The Mac could not reach the WiiM at all during diagnosis — mDNS multicast answered, every
unicast port was closed — which is the signature of wireless client isolation. It is a
non-issue: the `rest_command` runs from the box, which reaches the device fine.

### The rungs, and why Rung 1 alone

Four escalating options were laid out. Rung 1 is built; the rest are recorded so they are
not rediscovered:

| Rung | What | Gesture | Cost |
|------|------|---------|------|
| 0 | Select BT in the WiiM Home app | open app, tap | free, available immediately |
| **1** | **HA script + dashboard button + Siri via HomeKit bridge** | **one tap / one sentence** | **built here** |
| 2 | VIDAA MQTT integration fires Rung 1 on projector power-on | none | HACS + Mosquitto bridge service |
| 3 | eARC extractor + analog mixer; delete Bluetooth | none, ever | ~₩60–100k + the HDMI port |

**On deferring Rung 2** — the first framing ("buys one tap → zero taps, costs third-party
code and a broker bridge") was too narrow and Han pushed back on it. Judged only against
this problem it is a poor trade; judged as **home-hub infrastructure** it is much stronger,
because projector power state is the most useful signal in the room — it is the trigger for
lights, AC, and pausing music, not just this one script. Mosquitto is already anticipated in
`plan/home-assistant-followups.md` for Zigbee2MQTT.

The deferral therefore rests on **sequencing, not merit**: *Rung 2 is Rung 1 plus a trigger.*
The script built here is exactly what Rung 2 would call, so building Rung 1 first costs
nothing toward it, is a strict prerequisite, and buys the information of whether one tap
actually annoys anyone. If it does, Rung 2 is purely additive.

### Config location — the A/B fork

HA's `configuration.yaml` lives inside the `ha_data` **named volume**, and
`plan/home-assistant-followups.md` deliberately called that "onboarding territory, not
declarative-config territory."

A `rest_command` is the first HA config that is genuinely *declarative*, and it hardcodes a
fact (the WiiM's IP) that nothing else in the repo records. Two options were put:

- **A** — edit `configuration.yaml` in the volume. Simplest, matches the existing stance,
  but untracked: invisible to git, lost on a volume restore, and its disappearance would be
  **silent**.
- **B** — a git-tracked package fragment, bind-mounted read-only.

Han chose **B**. It is the same pattern gerbera's `config.xml` already uses — a file HA does
not rewrite can be the source of truth in git — and this is exactly the "guarded config"
class `ops/index.py` exists to catch. The line is now drawn inside HA's config rather than
around it: **`ha_data` holds onboarding state, `./ha/packages` holds decisions.**

### The music hub — the requirement changed the answer

The opening ask mentioned a music hub vaguely; the follow-up made it specific, and it
inverted an earlier recommendation. The distinction that decides everything is whether the
phone is the **source** or the **remote**:

| Mechanism | Phone is… | Survives switching to YouTube? |
|---|---|---|
| Bluetooth | the source | ✗ YouTube takes the audio |
| AirPlay 2 | the source | ✗ iOS hands the audio session to YouTube |
| **Spotify / Tidal Connect** | **a remote** | ✓ the WiiM pulls the stream itself |
| DLNA / Music Assistant | a remote | ✓ |

**Earlier advice to "use AirPlay for everything" was wrong for this requirement** — AirPlay
keeps the phone tethered as the source, which is the exact thing Han wants to escape. The
answer is Spotify/Tidal **Connect**, selected inside the streaming app rather than from the
AirPlay menu.

The catch: **Apple Music has no Connect protocol**, so on Apple Music the requirement is
natively unachievable. Music Assistant does have an Apple Music provider, but it requires
**Widevine CDM binaries** and its own docs say playback is "not officially supported by
Apple, use at your own risk" — recorded here so it is not mistaken for a clean fix.

**Free alternatives** (the follow-up ask), in the order recommended:

1. **Spotify Free + Connect** — officially possible since Spotify opened the free tier to
   Connect via its partner SDK, but adoption is per-manufacturer and undocumented for the
   Mini. Five minutes to test, zero build.
2. **Gerbera over DLNA** — already running for the projector. The WiiM Home app browses
   DLNA servers under *Home Music Share*; the WiiM then pulls from the box directly, so the
   phone is only a control point. Free, uses existing infrastructure. Needs a second mount
   (gerbera currently serves only `${TORRENT_DOWNLOADS}/complete`, tuned for video).
3. **Internet radio** — built into the WiiM Home app, satisfies the model with no work.

**Music Assistant stays deferred**, contrary to its standing as roadmap item #1: the WiiM
already *is* the music hub for streaming, and MA earns a service slot on an 8 GB box only if
DLNA browsing proves too clunky, or if multi-room across several WiiM endpoints appears.
**YouTube Music is ruled out** — it needs Chromecast, which the Mini does not support.

The iPad is a **control surface, not a server** — iOS will not host anything in the
background. Its role is an HA dashboard, and Apple Home via the HomeKit bridge.

### Open questions

- Which streaming service Han actually subscribes to — this decides whether anything at all
  remains to build for the music hub.
- Whether Spotify Free + Connect works on the WiiM Mini specifically (untested).
- Why there are **two** WiiM `media_player` entities (`wiim_living_room`,
  `wiim_living_room_2`) — two integrations appear to have claimed one device. Harmless today,
  confusing later.
- Rung 2, if one tap turns out to be one too many.

### Addendum (2026-08-16) — the control surface

> **Verbatim (2026-08-16):** "yes dashboard button and the HomeKit bridge."

**HomeKit bridge — built**, in `ha/packages/homekit.yaml`, with a per-entity allowlist
holding exactly the two audio scripts. HA maps a `script.*` to a HomeKit switch that
turns itself back off, so the Siri phrase is *"turn on projector audio"*. Pairing is a
one-time human step and its state lives in `ha_data`, not git — it is onboarding state,
which is the split working as designed.

`advertise_ip` turned out to be **required rather than optional**: the box runs four
docker bridge interfaces alongside `wlp1s0` and `tailscale0`, and HA's mDNS advertisement
under host networking regularly lands on a docker address, failing pairing with no useful
error. It also surfaced that **the box is on Wi-Fi**, so it needs a DHCP reservation for
the same reason the WiiM does. Two hardcoded addresses now depend on router reservations;
both fail silently if a lease rotates.

**Dashboard button — deliberately NOT built in git.** The obvious move was a YAML
dashboard in `ha/packages/`, matching the "declarative config in git" choice above. It
was rejected on the split's own logic: **a dashboard layout is onboarding state, not a
decision.** It is visual, iterated often, and the UI editor is genuinely the better tool
for it — putting it in YAML would trade a good editor for reproducibility nobody needs
on a button's position. The line drawn earlier says `ha_data` holds what HA's UI writes;
a dashboard is exactly that.

This is worth recording because it is the first time the volume/git split was used to
argue *against* git-tracking something, which is the test of whether the line is real or
just a preference for version control.
