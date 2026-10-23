# Kiro Crew public access

Put your Kiro Crew dashboard on a public HTTPS URL behind Google login:

```
browser ─HTTPS─> Cloudflare ─tunnel─> cloudflared
   ─> oauth2-proxy :4180   (Google login, email allowlist)
        /          ─> Kiro Crew gateway :5476
        /kc-auth/  ─> kc-auth token API :3000
```

- **Cloudflare Tunnel** carries traffic from Cloudflare to your machine over an
  outbound connection. No open ports, no static IP, and it works behind
  NAT/CGNAT. Cloudflare provides the TLS certificate.
- **oauth2-proxy** makes everyone sign in with Google and lets through only the
  addresses in your allowlist.
- **kc-auth** is a small Node.js API. An allowed user opens `/kc-auth/token`
  and gets a Kiro Crew dashboard token, minted on your machine with
  `kirocrew token`.

Everything listens on `127.0.0.1` only. Runs on Linux and macOS.

## Why kc-auth is not a container

`kirocrew token` asks the gateway to mint a token, and the gateway agrees only
when the caller is an ordinary process on the host. On Linux it must share the
gateway's user and mount namespaces; a Docker container always has its own
mount namespace, so a containerized kc-auth would be refused every time.
`setup.sh` therefore runs kc-auth on the host (a systemd user service on
Linux, a launchd agent on macOS), and Docker runs only oauth2-proxy and
cloudflared.

## Linux and macOS differences

| | Linux | macOS |
|---|---|---|
| kc-auth runs as | systemd user service `kc-auth.service` | launchd agent `com.kc-remote-access.kc-auth` |
| Container networking | host networking (`docker-compose.yml`) | normal Docker network plus `host.docker.internal` (`docker-compose.mac.yml`, selected by `setup.sh`) |
| Cloudflare Public Hostname URL | `localhost:4180` | `oauth2-proxy:4180` |
| Keeps running | at boot, after `sudo loginctl enable-linger $USER` | while you are logged in; starts at login |
| kc-auth logs | `journalctl --user -u kc-auth.service -f` | `tail -f ~/Library/Logs/kc-auth.log` |

macOS support is new. If something fails on a Mac, the two places to look are
oauth2-proxy reaching `host.docker.internal` (`docker compose logs
oauth2-proxy`) and kc-auth's mint call (`~/Library/Logs/kc-auth.log`).

## Requirements

- Linux with systemd, or macOS with Docker Desktop (Compose 2.24 or newer)
- Kiro Crew installed and its gateway running on this machine (`kirocrew status`)
- Docker with the compose plugin (`docker compose version`)
- Node.js 18 or newer
- A domain whose DNS is managed by Cloudflare (the free plan is enough)
- A Google account to create the OAuth client

## Setup

### 1. Get the repository

```bash
git clone <this repo> kc-remote-access
cd kc-remote-access
cp .env.example .env
chmod 600 .env
```

Fill in `.env` as you go through the next steps.

### 2. Choose the hostname

Pick the public hostname, for example `crew.yourdomain.com`, and set it as
`DOMAIN` in `.env`.

### 3. Create the Google OAuth client

1. Open [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials).
   Create or select a project.
2. If asked, configure the OAuth consent screen. "External" works for personal
   Gmail accounts; add yourself and your teammates as test users, or publish
   the app.
3. **Create credentials → OAuth client ID → Web application.**
4. Under **Authorized redirect URIs** add exactly:
   `https://<DOMAIN>/oauth2/callback`
5. Copy the client ID and client secret into `GOOGLE_CLIENT_ID` and
   `GOOGLE_CLIENT_SECRET`.

### 4. Generate the cookie secret

```bash
openssl rand -base64 32 | tr -- '+/' '-_'
```

Put the output in `OAUTH2_COOKIE_SECRET`.

### 5. List the allowed Google accounts

Set `ALLOWED_EMAILS` to a comma-separated list:

```
ALLOWED_EMAILS=you@gmail.com,teammate@example.com
```

Only these accounts can get past the login.

### 6. Create the Cloudflare tunnel

1. In the [Cloudflare dashboard](https://dash.cloudflare.com/), open
   **Zero Trust → Networks → Tunnels → Create a tunnel**.
2. Choose **Cloudflared** as the connector type and name the tunnel.
3. On the **Install connector** screen, copy the token (the long string after
   `--token` in any of the install commands). Put it in
   `CLOUDFLARE_TUNNEL_TOKEN`. You do not need to run Cloudflare's install
   command; the compose stack runs the connector.
4. Go to the **Public Hostname** tab and add a route:
   - **Subdomain / Domain:** the parts of your `DOMAIN`
   - **Service type:** `HTTP`
   - **URL:** `localhost:4180` on Linux, `oauth2-proxy:4180` on macOS

   On Linux, cloudflared runs with host networking and reaches oauth2-proxy on
   the host's loopback. On macOS, both containers share a Docker network and
   cloudflared reaches oauth2-proxy by its service name. `setup.sh` prints the
   right URL at the end.
5. Save. Cloudflare creates a DNS record for the hostname: a proxied CNAME
   pointing at `<tunnel-id>.cfargotunnel.com`.

If a DNS record with that name already existed (an `A` record, for example),
Cloudflare cannot create the CNAME. Delete the old record under your domain's
**DNS → Records** and save the Public Hostname again, or add the CNAME by hand
with the proxy status set to **Proxied**.

**One tunnel per machine.** If you run this on more than one machine, create a
separate tunnel and hostname for each (for example `crew.example.com` and
`crew2.example.com`). Two machines running the same tunnel token become
connectors of one tunnel, and Cloudflare splits requests between them, so a
user bounces between two different Kiro Crew gateways. You can reuse one Google
OAuth client: add each hostname's `https://<hostname>/oauth2/callback` to its
authorized redirect URIs. Generate a new `OAUTH2_COOKIE_SECRET` per machine.

### 7. Run the installer

```bash
./setup.sh
```

It checks `.env` and the prerequisites, writes `authenticated-emails.txt`,
installs and starts kc-auth (systemd on Linux, launchd on macOS), waits for it
to answer, and starts the containers. On macOS it also adds
`COMPOSE_FILE=docker-compose.yml:docker-compose.mac.yml` to `.env`, so plain
`docker compose` commands in this directory use the Mac override. It is safe
to run again after changing `.env`.

**Linux:** to keep kc-auth running after you log out, and start it at boot:

```bash
sudo loginctl enable-linger "$USER"
```

**macOS:** kc-auth starts when you log in. Set Docker Desktop to start at login
(Settings → General) so the containers come back after a reboot.

### 8. Tell Kiro Crew its public URL

Kiro Crew does not let agents edit its config, so do this yourself. In
`~/.kiro/crew/config.json` set:

```json
"dashboard": { "url": "https://<DOMAIN>" }
```

Then run `kirocrew restart`. Without it, the dashboard's WebSocket handshake
from the public URL is rejected and the UI keeps going offline.

## Using it

1. Open `https://<DOMAIN>` and sign in with an allowed Google account.
2. When the dashboard asks for a token, open `https://<DOMAIN>/kc-auth/token`
   in the same browser. It returns:

   ```json
   {"token": "...", "email": "you@gmail.com", "expiresIn": "8h"}
   ```

3. Paste the `token` value into the dashboard.

`TOKEN_TTL` in `.env` sets how long each token lasts.

## Managing it

| Task | Linux | macOS |
|---|---|---|
| Add or remove an allowed email | Edit `authenticated-emails.txt` (reloads on save), and update `ALLOWED_EMAILS` so a re-run of `setup.sh` keeps it | same |
| Container logs | `docker compose logs -f` | same |
| kc-auth logs | `journalctl --user -u kc-auth.service -f` | `tail -f ~/Library/Logs/kc-auth.log` |
| Restart kc-auth | `systemctl --user restart kc-auth.service` | `launchctl kickstart -k gui/$(id -u)/com.kc-remote-access.kc-auth` |
| Stop everything | `docker compose down && systemctl --user stop kc-auth.service` | `docker compose down && launchctl bootout gui/$(id -u)/com.kc-remote-access.kc-auth` |
| Uninstall kc-auth | `systemctl --user disable --now kc-auth.service && rm ~/.config/systemd/user/kc-auth.service && systemctl --user daemon-reload` | `launchctl bootout gui/$(id -u)/com.kc-remote-access.kc-auth; rm ~/Library/LaunchAgents/com.kc-remote-access.kc-auth.plist` |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Cloudflare **error 530** | The hostname is not bound to the tunnel. Check that its DNS record is a proxied CNAME to `<tunnel-id>.cfargotunnel.com`, not an `A` record. If cloudflared logs show no request lines, the edge never reached your tunnel. |
| 502 or connection errors after login | The Public Hostname URL is wrong for your OS: `localhost:4180` on Linux, `oauth2-proxy:4180` on macOS. Check `docker compose logs cloudflared` for the service URL it received. |
| macOS: 502 from oauth2-proxy, logs show `host.docker.internal` connection refused | Docker Desktop is not forwarding to the Mac's loopback, or the gateway/kc-auth is not running. Check `curl http://127.0.0.1:5476/` and `curl http://127.0.0.1:3000/kc-auth/health` on the Mac, and that `COMPOSE_FILE` in `.env` includes `docker-compose.mac.yml`. |
| Any Google account gets in | Something set `OAUTH2_PROXY_EMAIL_DOMAINS`. Remove it; the allowlist file must be the only email gate. |
| `/kc-auth/token` returns 500 | `kirocrew token` failed. Check the kc-auth logs (see Managing it) and that the gateway is running. |
| Dashboard keeps reconnecting | `dashboard.url` is not set to `https://<DOMAIN>` (step 8), or you did not run `kirocrew restart`. |
| Settings pages refuse to save | Expected. Kiro Crew refuses config writes and secret reveals on proxied requests. Change settings locally or over SSH. |

## Security notes

Read these before you share access.

- **Every allowed user gets a full owner session.** Tokens from `kirocrew token`
  are owner tokens; Kiro Crew has no per-user scoping behind a proxy. The
  Google allowlist is your access control, so keep it short.
- **kc-auth trusts the `X-Forwarded-Email` header.** oauth2-proxy sets it for
  outside requests, but any program on this machine can call
  `127.0.0.1:<KC_AUTH_PORT>/kc-auth/token` with a made-up header and get an
  owner token. That includes agent sessions your Kiro Crew gateway runs.
  Anyone with a shell on the machine already has owner access, but agents are
  normally blocked from minting tokens and this endpoint removes that block.
  Verifying the Google ID token in kc-auth (oauth2-proxy can forward it with
  `OAUTH2_PROXY_PASS_AUTHORIZATION_HEADER=true`) would close the gap.
  On macOS the reach is wider: any container on the Mac's Docker Desktop can
  call `host.docker.internal:<KC_AUTH_PORT>`, so do not run untrusted
  containers on that Mac.
- `.env` holds your secrets. Keep it `chmod 600` and never commit it
  (`.gitignore` excludes it).
