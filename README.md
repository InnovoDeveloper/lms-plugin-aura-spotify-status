# Aura Spotify Status — LMS plugin (Innovo)

A small **Lyrion Music Server (LMS)** plugin that adds an **"Aura Spotify Status"**
health/status dashboard to the LMS web UI, for the Aura Spotify-in-LMS system
(CastLabs Electron + Widevine decoder, the audio daemons, ride-on-Spotty auth).

## What it shows

A live dashboard (auto-refreshing every 5 s) with:

- **Decoder (Widevine)** — Electron SDK ready, Aura-M device, now-playing track
- **Auth** — harness token, account, premium status, Aura-M registered, which Spotty account it rides
- **Services** — the audio daemons + per-service uptime
- **System** — version, LMS, snd-aloop loopback, hub, Spotty wiring, decode engine
- **Recent Errors** — from the system logs

## Design

**Thin + standalone.** The plugin does not collect health itself — it serves the
dashboard and proxies the JSON from the on-device helper `spotify-status.py`
(`127.0.0.1:8795`). Both the page and its `/data` endpoint are served from LMS's own
port, so it works over LAN and remote tunnels with no cross-origin dependency.

**Survives Spotty updates.** This is its own plugin (`Plugins::AuraSpotifyStatus`), a
separate directory from Spotty. An LMS/Spotty update never touches it — it's not wired
into Spotty at all.

> Requires the Aura Spotify-in-LMS system (which provides `spotify-status.py` on :8795).
> Without that helper the dashboard shows a "helper not responding" banner.

## Subscribing your LMS to updates

Add this URL to **LMS → Settings → Plugins → Additional Repositories**:

```
https://innovodeveloper.github.io/lms-plugin-aura-spotify-status/extensions.xml
```

Save, and the LMS plugin manager offers **Aura Spotify Status** under "3rd Party
Plugins". Enable it, restart LMS, and every release published here is picked up by the
plugin manager's normal update polling.

## Releasing (maintainers)

```
git tag -a 0.X.Y -m "..." && git push origin 0.X.Y   # CI builds the zip + publishes extensions.xml
```

The `Release` GitHub Action runs `make dist`, attaches the zip to the release, and
publishes `extensions.xml` to GitHub Pages.

## License

MIT.
