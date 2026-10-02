<div align="center">

# Smart-Caddy

**English** · [فارسی](README.fa.md)

Smart reverse proxy management for [Caddy](https://caddyserver.com), in one script.

</div>

Give it a domain → it writes the config, gets the certificate, validates, reloads.
If anything is wrong it **rolls back automatically**, so Caddy never goes down.

```
$ sudo smart-caddy add panel.example.com 54321

== Pre-flight checks ==
[ ok ] DNS -> 203.0.113.10
[ ok ] backend 127.0.0.1:54321 is reachable
[info] no certificate yet - Caddy will obtain one right after reload

== Applying ==
[ ok ] Caddy reloaded with no downtime.
[info] waiting for certificate issuance....
[ ok ] certificate issued, expires: Dec 20 14:02:11 2026 GMT

== Done ==
[ ok ] https://panel.example.com  ->  127.0.0.1:54321
```

---

## Install

```bash
curl -fsSL https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh -o smart_caddy.sh && sudo bash smart_caddy.sh
```

That URL always resolves to the newest release — no version number to update.

One file, one command. It installs Caddy itself if missing (apt, dnf, yum, pacman,
apk), inspects the machine, and asks only about what it cannot work out alone:

```
== Looking around ==
[ ok ] package manager: apt
[ ok ] Caddy is installed - v2.11.4
[ ok ] several addresses: 203.0.113.10 203.0.113.11
[warn] :443 is held by 'xray-linux-amd6'

       Caddy cannot share a port with another process. Your options:
         * if that is Xray, keep it and put sites behind its fallback:
               smart-caddy add <domain> <port> --behind-xray
         * if it is an old nginx/apache you no longer want, stop it first
         * or give Caddy its own IP on a multi-address host

== A few questions ==
  Address for Caddy (one of: 203.0.113.10 203.0.113.11) [203.0.113.10]:
  Email for Let's Encrypt (expiry notices) [admin@example.com]:
  Set up the web panel, so you can manage sites in a browser? [Y/n]
  Add your first site now? [y/N]
```

On a single-address host it never asks about addresses at all. The web panel's
source is embedded in the script, so there is nothing else to download.

> **Why download first instead of piping into bash?**
>
> `curl ... | bash` leaves no terminal to ask questions on, so every prompt would
> silently take its default. The script detects that and refuses rather than guess.
>
> `sudo bash -c "$(curl ...)"` passes the whole script as one command-line argument,
> and Linux caps a single argument at 128 KB. The script is bigger than that, so you
> get `Argument list too long`.
>
> `sudo bash <(curl ...)` fails too: sudo closes the `/dev/fd/63` that process
> substitution creates, so you get `/dev/fd/63: No such file or directory`.
>
> Saving the file and running it has none of these problems, keeps your terminal
> attached for the questions, and lets you read the script first if you like:
>
> ```bash
> curl -fsSL https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh -o smart_caddy.sh
> less smart_caddy.sh      # read it first
> sudo bash smart_caddy.sh
> ```

Already installed? Update in place:

```bash
sudo smart-caddy update
```

## Features

| | |
|---|---|
| **Never breaks your server** | `caddy validate` before every reload; any failure rolls back |
| **Automatic `bind`** | always emitted on multi-IP hosts, so no port collisions |
| **Permission-safe writes** | edits the Caddyfile in place, never clobbering mode or ownership |
| **Certificates on autopilot** | Caddy issues and renews every certificate itself; the panel shows days left and has a one-click **Renew** that puts the old cert back if anything fails |
| **Adopts your existing Caddy** | finds sites you wrote straight into the Caddyfile and imports them unchanged, so they show up in the panel |
| **Path routes** | send `/dns-query/*` or `/api/*` to a different backend than the rest of the site |
| **Activity log** | every change, from the panel or the terminal: who, when, the output, and a diff of exactly which config lines changed |
| **Many backend types** | a local port, a TLS backend, a directory of files, another site, or a redirect |
| **Path-aware, not path-fragile** | records an app's base path without 404-ing the rest, so panel WebSockets keep working |
| **Behind another front proxy** | when an SNI proxy such as DNSGuard owns `:80`/`:443` and hands names to Caddy on loopback, sites are created behind it and the domain is registered with it for you |
| **Coexists with Xray** | `--behind-xray` sets up the loopback + PROXY protocol + h2c listener and verifies the fallback exists |
| **Web panel** | Persian / English, real login page, PBKDF2 passwords, signed sessions, add / edit / remove sites, raw config editor |
| **Safe removal** | on delete, asks whether to keep the certificate (default: keep) |
| **`doctor`** | listeners, bind, DNS, permissions, certificates that cannot renew, WebSocket pitfalls, Xray fallbacks, recent errors |
| **`repair`** | fixes file permissions, stale auth blocks and missing HTTP version pins |

## Web panel

```bash
sudo smart-caddy panel                    # asks for the domain
sudo smart-caddy panel caddy.example.com  # or name it up front
```

A localhost-only service behind Caddy with TLS. List your sites, add them, **edit**
them, remove them, and run the diagnostics — all by calling the same CLI
underneath, so there is exactly one code path that writes config.

What it shows and does:

- **Persian and English**, with a language switch (right-to-left in Persian).
- Every site with its backend, routes, and **how many days of SSL are left**,
  coloured as expiry gets close, with a **Renew** button.
- One form to add or edit a site, with an explanation under every field:
  main backend, **path routes**, path prefix, Host header, **SSL certificate**
  (Caddy, existing certbot, or self-signed), admin-panel preset, plain HTTP,
  behind Xray.
- **Config**: edit any site's raw Caddyfile text. It is validated first and rolled
  back if Caddy rejects it, so a typo cannot take the server down.
- **Found in Caddyfile**: sites written by hand into the Caddyfile, with one-click
  import. A domain defined twice gets a "keep this one" button.
- **Diagnostics & output** and the **Activity log** at the bottom of the page.
  Each log entry expands to the command's output and a coloured diff of the
  config files it changed.

It has a real sign-in page, not the browser's native credential box: passwords are
PBKDF2-HMAC-SHA256 (240k rounds) in `/etc/smart-caddy-panel.json` (mode 0600),
sessions are HMAC-signed cookies (`HttpOnly`, `SameSite=Strict`, `Secure` behind
HTTPS) that survive a restart, cross-origin POSTs are refused, and failed logins
back off exponentially after five tries.

Change the password from the terminal at any time:

```bash
sudo smart-caddy passwd                          # prompts twice
sudo smart-caddy passwd --password 'NewPass123'
sudo smart-caddy passwd newuser                  # change the username too
```

Changing it rotates the session key, so anyone already logged in is signed out.

Notes:

- The service binds `127.0.0.1` only. It authenticates, but speaks plain HTTP —
  keep Caddy in front of it rather than exposing the port.
- It runs as root, because it edits `/etc/caddy` and reloads the service.
- Every field is validated against a strict allowlist before reaching a
  subprocess, and commands are built as argv lists, never shell strings.

## Commands

```
setup                                    one command, start to finish
install [--ip <IP>] [--email <mail>]     just the system wiring
add <domain> <backend> [opts]            add a site
del <domain> [--keep-cert|--purge-cert]  remove a site
del-cert <domain>                        remove only the certificate
list                                     list sites and certificates
import [domain...] [--all|--list]        adopt sites already in the Caddyfile
import <domain> --replace                ... over a managed copy of the same domain
put <domain> <file>                      replace a site's config with your own text
cert <domain> caddy                      let Caddy issue and renew the certificate
renew <domain>                           get a fresh certificate now (rolls back on failure)
panel <domain> [--user u] [--port n]     install the web panel
panel status | panel remove [<domain>]   check or remove the web panel
passwd [user] [--password <p>]           change the panel password
doctor                                   full diagnostic
fixbind                                  add 'bind' to blocks missing it
repair                                   fix permissions and known upgrade issues
uninstall                                remove integration (certs kept)
```

Run `add` or `panel` with no arguments and they ask for what they need, validating
as they go.

### Backends

| You write | It means |
|---|---|
| `54321` | a port on this machine |
| `127.0.0.1:54321` | the same, spelled out |
| `https://127.0.0.1:27389` | a local app that serves TLS itself (pair with `--insecure`) |
| `10.0.0.5:9000` | a service on another machine |
| `/var/www/mysite` | serve files from that directory |
| `example.com` | proxy through to somebody else's site |
| `redirect:https://x.com` | send visitors there instead |

If you give a plain `host:port` but the backend actually speaks HTTPS, the script
detects it and offers to switch — that mismatch is the most common cause of a 502.

### `add` options

| Option | Effect |
|---|---|
| `--route <path>=<backend>` | send one path to another backend, e.g. `--route '/dns-query/*=8000'`. Repeatable. |
| `--replace` | overwrite an existing site in place (keeps its certificate and its Xray loopback port) |
| `--path <prefix>` | record the app's base path, shown in `list`. Repeatable. |
| `--strict-path` | additionally refuse everything outside those prefixes |
| `--behind-xray` | Xray owns `:443` and falls back to us |
| `--listen-port <n>` | pick the loopback port yourself (default: first free in 8081-8199) |
| `--panel` | preset for admin panels — implies `--insecure --no-buffer` |
| `--insecure` | don't verify the backend's TLS certificate |
| `--no-buffer` | stream responses through — live stats, SSE, log tails |
| `--host-header <v>` | force the `Host` header sent upstream (routers want `127.0.0.1`) |
| `--auto-cert` | Caddy issues and renews the certificate itself (recommended) |
| `--certbot` | use the existing certbot certificate |
| `--self-signed` | `tls internal` — Caddy's internal CA, for testing |
| `--no-tls` | plain HTTP |
| `--no-dns-check` | skip the A-record check |
| `-y, --yes` | non-interactive |

## Admin panels (x-ui, 3x-ui, Marzban, Hiddify)

These do three awkward things at once: they serve **HTTPS with a self-signed cert**
on localhost, they live under a **random base path**, and their dashboard streams
**live traffic counters**. Miss any one and you get a blank page, a 502, or a panel
that opens but never updates.

```bash
sudo smart-caddy add panel.example.com https://127.0.0.1:27389 \
    --panel --path /5wSobQvUFuNy4zBUcc
```

which generates:

```caddyfile
panel.example.com {
	bind 203.0.113.10
	encode zstd gzip

	# app base path: /5wSobQvUFuNy4zBUcc
	reverse_proxy https://127.0.0.1:27389 {
		transport http {
			tls_insecure_skip_verify
			versions 1.1
		}
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Port {server_port}

		flush_interval -1
	}
}
```

Three details matter, and each one fails the same invisible way:

- **`flush_interval -1`** — Caddy's equivalent of nginx's `proxy_buffering off`.
  Without it the dashboard's live counters sit in a buffer and look frozen.
- **`versions 1.1`** — a TLS backend can negotiate HTTP/2 over ALPN, and HTTP/2 has
  no Upgrade mechanism, so WebSocket handshakes silently fail.
- **Never force the `Host` header on a panel.** Panels check the WebSocket's
  `Origin` against the `Host` they receive. Sending `Host: 127.0.0.1` while the
  browser sends `Origin: https://panel.example.com` makes that check fail, the
  WebSocket is refused, and the speed columns stay empty forever. `add` warns you
  if you try.

### Why `--path` does not restrict by default

`--path` records where the app lives; it does not block anything else. Admin panels
routinely serve their base path from one place and open their live-stats WebSocket
from the **site root**, so matching on the prefix and 404-ing the remainder produces
a panel that looks completely healthy while the live traffic columns stay
permanently blank — a genuinely hard bug to spot, because every page you click
works.

The app already 404s its own root, so the extra restriction usually buys nothing.
`--strict-path` restores the strict matcher if you really want it, with a warning.

## Already running Caddy?

Sites you wrote by hand live in the Caddyfile itself, where nothing can see them.
`setup` and `install` notice them and offer to import; you can also do it any time:

```bash
sudo smart-caddy import --list     # what is there
sudo smart-caddy import            # move them into sites.d
```

Each block moves **byte for byte** into `/etc/caddy/sites.d/<domain>.caddy`, so Caddy
serves exactly what it served before. The Caddyfile is backed up first, and the move is
validated and rolled back like any other change. Blocks with no domain name (`:80`, an
IP, `localhost`) and snippets stay where they are.

Imported sites are read back into the panel's form when they use directives it
understands — reverse proxies, path routes, files, redirects. Anything more exotic is
edited as raw text with **Config**.

## Path routes

One domain, several backends. A DNS-over-HTTPS server with its own admin page and a
public landing page, for example:

```bash
sudo smart-caddy add dns.example.com 8088 \
    --route '/dns-query/*=8000' --route '/panel*=8000'
```

Each route becomes a `handle` block, and the main backend takes everything else:

```caddyfile
	handle /dns-query/* {
		reverse_proxy 127.0.0.1:8000 { ... }
	}
	handle /panel* {
		reverse_proxy 127.0.0.1:8000 { ... }
	}
	handle {
		reverse_proxy 127.0.0.1:8088 { ... }
	}
```

## Certificates

By default Caddy gets every certificate from Let's Encrypt and renews it about 30
days before expiry, with nothing else to run. `list` and the panel show what each
site actually uses and how long it has left.

A certbot certificate from before Caddy can quietly stop renewing: its `standalone`
mode needs port 80, which Caddy now holds, and its `nginx` mode needs nginx. `doctor`
flags that case, and one command hands the certificate to Caddy without downtime:

```bash
sudo smart-caddy cert panel.example.com caddy
```

`renew` fetches a fresh certificate on demand. Caddy keeps certificates in memory, so
it restarts Caddy for about a second; the current certificate is set aside first and
put back if no new one arrives. Let's Encrypt allows five renewals of the same name
per week.

## Activity log

Every command that changes something — from the panel or the terminal — appends one
entry to `/var/log/smart-caddy/activity.jsonl` (the last 500 are kept): when, who
(`user@ip` from the panel), the command, its output, and a unified diff of every file
it touched. The panel shows it at the bottom of the page.

## Sharing port 443 with Xray

Two processes cannot bind the same `IP:port`. But if Xray is already on `:443`, it
is also already a perfectly good multiplexer: it terminates TLS and dispatches by
SNI, ALPN and path to local ports. Caddy goes *behind* it.

```bash
sudo smart-caddy add shop.example.com 3000 --behind-xray
```

```
[ ok ] picked free loopback port 8082

== Done - one step left, in Xray ==
[ ok ] listening on 127.0.0.1:8082 (plain HTTP, PROXY protocol v2)

    SNI    shop.example.com
    ALPN   (leave empty)
    Path   /
    Dest   127.0.0.1:8082
    xver   2
```

Paste that into x-ui → the inbound on 443 → Fallbacks → Add fallback.

Three things have to line up, and getting any one wrong looks identical — a domain
that never responds:

- **Plain HTTP, not HTTPS.** Xray decrypts before forwarding, so the site is
  `http://domain:PORT` bound to `127.0.0.1` with no certificate.
- **PROXY protocol.** `xver 2` prefixes each connection with a binary header.
  Without the matching listener wrapper, Caddy reads it as a malformed request.
- **h2c.** An `alpn h2` fallback arrives as *cleartext* HTTP/2, which a plain
  listener does not speak by default.

`--behind-xray` writes all three and adds the listener stanza to the global options
block. **The certificate belongs to the Xray inbound, not to Caddy** — Xray does the
handshake, so this listener never sees one.

`doctor` then reads your Xray config and tells you whether the fallback row exists:

```
== 7  Xray fallbacks ==
[ ok ] shop.example.com: Xray falls back to :8082
[warn] api.example.com: no Xray fallback points at :8083
       the domain will look dead until you add that row in x-ui
```

## Behind an SNI proxy (DNSGuard and similar)

Some servers run an SNI proxy on `:80`/`:443` that serves its own clients and hands
the names it does not handle to Caddy on a loopback port, with a PROXY protocol
header. Caddy's global options then contain `https_port <n>` with `n` other than 443.

Smart Caddy detects that and stops suggesting `--behind-xray`. Every site it creates
there is an ordinary HTTPS site bound to `127.0.0.1`, with an explicit http → https
redirect when the front proxy has turned Caddy's own redirect off. For **DNSGuard** it
also adds the domain to `SNI_LOCAL_NAMES` in `/opt/dnsguard/.env` and restarts it (DNS
pauses for a few seconds); for anything else it tells you which name to forward.
`doctor` lists any site the front proxy does not hand over yet.

### What does not work

Putting a stock Caddy in front of Xray on `:443`. Caddy is an HTTP server: it
terminates TLS and expects HTTP, and VLESS/Reality is neither. (A WebSocket or
xHTTP inbound *is* HTTP, so Caddy can front those.) For real SNI routing with Caddy
in front you need the `caddy-l4` plugin and an `xcaddy` build; Xray already does it
with nothing extra.

## DNS

**Put your subdomains on DNS-only.** If your provider has a CDN or "cloud proxy"
toggle (Cloudflare's orange cloud, ArvanCloud's ابر), leave it off for anything
Caddy serves: with it on, the A record returns the CDN's IP, the ACME challenge
never reaches your server, no certificate is issued, and all your traffic — session
cookies included — passes through the CDN.

## Troubleshooting

```bash
sudo smart-caddy doctor
```

| Symptom | Usual cause |
|---|---|
| `reload failed` | a block has no `bind` → `smart-caddy fixbind` |
| `permission denied` on the Caddyfile | mode/ownership clobbered → `smart-caddy repair` |
| Browser shows a native login popup | an old `basic_auth` block → `smart-caddy repair` |
| Certificate never issued | A record points elsewhere, CDN proxy on, or port 80 closed |
| certbot certificate about to expire | certbot cannot renew while Caddy holds :80 → `smart-caddy cert <domain> caddy` |
| `502 Bad Gateway` | backend down, or it speaks HTTPS and you gave a plain `host:port` |
| Panel loads but **live stats stay empty** | a forced `Host` header, a `--strict-path` restriction, buffering, or a missing `versions 1.1` |
| `address already in use` | another service holds that IP:port — `ss -tnlp \| grep ':443'` |

### A note on file permissions

Caddy's systemd unit runs as an unprivileged user, so `/etc/caddy/Caddyfile` must
stay readable by it. Editing that file with `mktemp` + `mv` silently replaces its
mode and ownership with `0600 root:root`, and every later reload fails with
`permission denied`. This script always edits in place, preserving inode, mode and
owner. If something else already did the damage, `smart-caddy repair` fixes it.

## Requirements

`caddy`, `bash` 4+, `systemd`, and `python3` for the web panel. Recommended:
`acl` (setfacl), `dnsutils` (dig), `netcat`. `setup` installs what it can.

## License

MIT
