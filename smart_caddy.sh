#!/usr/bin/env bash
# =============================================================================
#  smart_caddy.sh - smart reverse proxy management for Caddy
#
#  Give it a domain, it writes the config, gets the certificate, validates
#  and reloads. If anything is wrong it rolls back - Caddy never goes down.
#
#  https://github.com/<you>/smart-caddy
#  License: MIT
#
#  Install:
#      curl -fsSL https://raw.githubusercontent.com/<you>/smart-caddy/main/smart_caddy.sh -o smart_caddy.sh
#      chmod +x smart_caddy.sh && sudo ./smart_caddy.sh install
#
#  Usage:
#      smart-caddy add panel.example.com 54321
#      smart-caddy add modem.example.com 2222 --host-header 127.0.0.1
#      smart-caddy del panel.example.com
#      smart-caddy doctor
# =============================================================================
set -euo pipefail

VERSION="1.5.0"
SELF_NAME="smart-caddy"
CONF_FILE="/etc/smart-caddy.conf"

# --- defaults (overridden by install / /etc/smart-caddy.conf) ----------------
CADDYFILE="/etc/caddy/Caddyfile"
SITES_DIR="/etc/caddy/sites.d"
CADDY_USER="caddy"
CADDY_GROUP="caddy"
CADDY_DATA="/var/lib/caddy/.local/share/caddy"
LE_LIVE="/etc/letsencrypt/live"
ACME_HOST="acme-v02.api.letsencrypt.org-directory"
FRONT_IP=""          # empty = do not emit bind (single-IP server)
ACME_EMAIL=""
SRC_DIR=""           # where install was run from, so 'panel' can find ui.py later

# Where to fetch a fresh copy of this script. Override with SMART_CADDY_URL.
SELF_URL="${SMART_CADDY_URL:-https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh}"

[[ -r "$CONF_FILE" ]] && . "$CONF_FILE"

# --- output ------------------------------------------------------------------
if [[ -t 1 ]]; then
	C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_WARN=$'\e[33m'
	C_INF=$'\e[36m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_OFF=$'\e[0m'
else
	C_OK=""; C_ERR=""; C_WARN=""; C_INF=""; C_DIM=""; C_B=""; C_OFF=""
fi
ok()   { printf '%s[ ok ]%s %s\n'   "$C_OK"   "$C_OFF" "$*"; }
info() { printf '%s[info]%s %s\n'   "$C_INF"  "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$C_WARN" "$C_OFF" "$*"; }
dim()  { printf '%s       %s%s\n'   "$C_DIM"  "$*" "$C_OFF"; }
hdr()  { printf '\n%s== %s ==%s\n'  "$C_B"    "$*" "$C_OFF"; }
die()  { printf '%s[fail]%s %s\n'   "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

ASSUME_YES=0
ask() {   # ask "question" [y|n] -> 0=yes 1=no
	local q="$1" def="${2:-n}" a p
	[[ "$def" == "y" ]] && p="[Y/n]" || p="[y/N]"
	if [[ $ASSUME_YES -eq 1 || ! -t 0 ]]; then
		[[ $ASSUME_YES -eq 1 ]] && printf '%s %s -> %s (auto)\n' "$q" "$p" "$def"
		[[ "$def" == "y" ]] && return 0 || return 1
	fi
	read -r -p "$q $p " a || a=""
	a="${a:-$def}"
	[[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

need_root() { [[ $EUID -eq 0 ]] || die "must run as root: sudo $0 $*"; }

# A readable copy of this script on disk, for installing it to /usr/local/bin.
#
# With `bash <(curl ...)` $0 is a pipe, not a file: it is already consumed, it
# cannot be rewound, and reading it again steals the text bash has not executed
# yet - which kills the running script mid-way. So in that case, fetch a fresh
# copy over the network instead of touching $0 at all.
# A runnable way to refer to this script, for messages. Under
# `bash -c "$(curl ...)"` (too long to work anyway past 128 KB) $0 is literally "bash"; telling someone to run
# `bash bash setup` helps nobody.
self_invocation() {
	if [[ -x "/usr/local/bin/$SELF_NAME" ]]; then
		printf '%s' "$SELF_NAME"
	elif [[ -f "$0" && -r "$0" ]]; then
		printf 'bash %s' "$0"
	else
		printf 'bash smart_caddy.sh'   # after: curl -fsSL "$SELF_URL" -o smart_caddy.sh
	fi
}

# Is the install actually complete, or did something stop halfway?
install_is_complete() {
	[[ -r "$CONF_FILE" ]] && [[ -x "/usr/local/bin/$SELF_NAME" ]]
}

self_source() {
	local f; f="$(readlink -f "$0" 2>/dev/null || echo "$0")"
	if [[ -f "$f" && -r "$f" && -s "$f" ]]; then
		printf '%s\n' "$f"; return 0
	fi
	have curl || return 1
	local tmp; tmp="$(mktemp /tmp/smart-caddy.XXXXXX.sh)"
	if curl -fsSL "$SELF_URL" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]] \
	   && bash -n "$tmp" 2>/dev/null && grep -q 'smart-caddy' "$tmp"; then
		printf '%s\n' "$tmp"; return 0
	fi
	rm -f "$tmp"; return 1
}
have()      { command -v "$1" >/dev/null 2>&1; }

# prompt VARNAME "question" ["default"] - reads into VARNAME
prompt() {
	local __v="$1" q="$2" def="${3:-}" ans=""
	if [[ ! -t 0 ]]; then printf -v "$__v" '%s' "$def"; return; fi
	if [[ -n "$def" ]]; then
		read -r -p "  $q [$def]: " ans; ans="${ans:-$def}"
	else
		read -r -p "  $q: " ans
	fi
	printf -v "$__v" '%s' "$ans"
}

# =============================================================================
#  File-permission safety
#
#  Caddy's systemd unit runs as an unprivileged user, so every file it reads
#  must stay readable by that user. Writing via `mktemp` + `mv` silently
#  replaces mode and ownership with 0600 root:root and breaks every later
#  reload with "permission denied". Always write through these helpers.
# =============================================================================

# Replace a file's contents in place, keeping its inode, mode and ownership.
write_inplace() {
	local dest="$1" src="$2"
	if [[ -e "$dest" ]]; then
		cat "$src" > "$dest"        # truncate + write: inode, mode, owner kept
	else
		install -m 0644 "$src" "$dest"
	fi
	rm -f "$src"
}

caddy_group() {
	if [[ -n "${CADDY_GROUP:-}" ]] && getent group "$CADDY_GROUP" >/dev/null 2>&1; then
		echo "$CADDY_GROUP"
	elif getent group caddy >/dev/null 2>&1; then
		echo caddy
	else
		echo root
	fi
}

caddy_can_read() {   # caddy_can_read <path>
	id -u "$CADDY_USER" >/dev/null 2>&1 || return 0   # no such user: skip check
	sudo -u "$CADDY_USER" test -r "$1" 2>/dev/null
}

fix_perms() {
	local grp; grp="$(caddy_group)"
	local changed=0
	if [[ -f "$CADDYFILE" ]]; then
		chown "root:${grp}" "$CADDYFILE" 2>/dev/null || true
		chmod 0644 "$CADDYFILE"           2>/dev/null || true
		changed=1
	fi
	if [[ -d "$SITES_DIR" ]]; then
		chown -R "root:${grp}" "$SITES_DIR" 2>/dev/null || true
		chmod 0755 "$SITES_DIR"             2>/dev/null || true
		find "$SITES_DIR" -type f -name '*.caddy' -exec chmod 0644 {} + 2>/dev/null || true
		changed=1
	fi
	[[ $changed -eq 1 ]] || return 0
	return 0
}

# =============================================================================
#  Helpers
# =============================================================================
bind_line() {
	# Must return 0 even with no FRONT_IP: it runs inside `{ ... } > file`
	# groups, where a non-zero status would abort the write under set -e.
	# Behind a front proxy only that proxy may reach Caddy, so loopback.
	if [[ -n "$(caddy_front_port)" ]]; then printf '\tbind 127.0.0.1\n'; return 0; fi
	[[ -n "$FRONT_IP" ]] || return 0
	printf '\tbind %s\n' "$FRONT_IP"
}

# =============================================================================
#  Front proxy
#
#  Some servers put another program on :80/:443 - an SNI proxy such as
#  DNSGuard - that hands the names it does not serve itself to Caddy on a
#  loopback port, with a PROXY protocol header. Caddy's global options then
#  carry 'https_port <n>' with n != 443. Sites on such a box are ordinary
#  HTTPS sites bound to 127.0.0.1, NOT Xray fallbacks.
# =============================================================================

# Caddy's https_port when it is not 443, i.e. something in front hands
# traffic over. Empty (and status 0) on a normal box.
caddy_front_port() {
	[[ -r "$CADDYFILE" ]] || return 0
	awk '
		NR == 1 && $0 !~ /^[ \t]*\{[ \t]*$/ { exit }
		/^\}/ { exit }
		{ if (match($0, /^[ \t]*https_port[ \t]+[0-9]+/)) {
			n = $0; gsub(/[^0-9]/, "", n); if (n != "443") print n; exit } }
	' "$CADDYFILE" 2>/dev/null || true
}

# Caddy's own http->https redirect is off (front proxies often do that), so
# every HTTPS site needs an explicit one.
caddy_redirects_off() {
	grep -qE '^\s*auto_https\s+(disable_redirects|off)' "$CADDYFILE" 2>/dev/null
}

# A plain redirect block for the http:// side of a site behind a front proxy.
redirect_block() {
	printf '\n# http -> https (Caddy'"'"'s automatic redirect is off on this server)\n'
	printf 'http://%s {\n\tbind 127.0.0.1\n\tredir https://{host}{uri} permanent\n}\n' "$1"
}

# DNSGuard keeps its list of names to hand over in its .env
DNSGUARD_ENV="/opt/dnsguard/.env"
dnsguard_present() {
	[[ -r "$DNSGUARD_ENV" ]] && grep -qE '^SNI_LOCAL=.+' "$DNSGUARD_ENV"
}

# Does DNSGuard already hand <domain> to Caddy? (PUBLIC_DOMAIN and its
# subdomains, plus SNI_LOCAL_NAMES)
dnsguard_covers() {
	local d="${1,,}" n names
	names="$(grep -oP '^PUBLIC_DOMAIN=\K.*' "$DNSGUARD_ENV" | head -1 || true),$(grep -oP '^SNI_LOCAL_NAMES=\K.*' "$DNSGUARD_ENV" | head -1 || true)"
	IFS=',' read -ra names <<<"${names// /}"
	for n in "${names[@]}"; do
		n="${n,,}"; n="${n%.}"
		[[ -z "$n" ]] && continue
		[[ "$d" == "$n" || "$d" == *".$n" ]] && return 0
	done
	return 1
}

# Add <domain> to DNSGuard's SNI_LOCAL_NAMES and restart it (a few seconds,
# DNS included) so it starts handing that name to Caddy.
dnsguard_add_name() {
	local d="$1" cur bak
	dnsguard_covers "$d" && { ok "DNSGuard already hands $d to Caddy"; return 0; }
	bak="$(mktemp)"; cp -p "$DNSGUARD_ENV" "$bak"
	cur="$(grep -oP '^SNI_LOCAL_NAMES=\K.*' "$DNSGUARD_ENV" | head -1 || true)"
	if grep -q '^SNI_LOCAL_NAMES=' "$DNSGUARD_ENV"; then
		sed -i "s|^SNI_LOCAL_NAMES=.*|SNI_LOCAL_NAMES=${cur:+$cur,}$d|" "$DNSGUARD_ENV"
	else
		printf 'SNI_LOCAL_NAMES=%s\n' "$d" >> "$DNSGUARD_ENV"
	fi
	[[ -n "$ACTIVITY_DIFF" ]] && diff -u --label "a$DNSGUARD_ENV" --label "b$DNSGUARD_ENV" \
		"$bak" "$DNSGUARD_ENV" | grep -vE '^[-+ ](ADMIN_KEY|TOKEN|BOT_TOKEN|NODE_KEY|SNI_PASS)=' \
		>> "$ACTIVITY_DIFF" 2>/dev/null || true
	rm -f "$bak"
	if systemctl restart dnsguard 2>/dev/null; then
		ok "DNSGuard now hands $d to Caddy (restarted it - DNS paused for a few seconds)"
	else
		warn "added $d to SNI_LOCAL_NAMES but could not restart dnsguard - restart it by hand"
	fi
}

# After writing a site behind a front proxy: make sure the front proxy will
# actually send this name to Caddy, or say what is missing.
front_register() {
	local d="$1" fp; fp="$(caddy_front_port)"
	[[ -n "$fp" ]] || return 0
	if dnsguard_present; then
		dnsguard_covers "$d" && { ok "DNSGuard already hands $d to Caddy"; return 0; }
		info "DNSGuard owns :80/:443 and only hands over the names it knows"
		if ask "Add $d to DNSGuard's SNI_LOCAL_NAMES now? (restarts DNSGuard for a few seconds)" y; then
			dnsguard_add_name "$d"
		else
			warn "$d will not be reachable until DNSGuard hands it over"
			dim "add it to SNI_LOCAL_NAMES in $DNSGUARD_ENV and restart dnsguard"
		fi
	else
		info "the program on :443 ($(port_owner 443)) must hand $d to Caddy on 127.0.0.1:$fp"
		dim "with a PROXY protocol header - otherwise the site stays unreachable"
	fi
}

certbot_cert()   { printf '%s/%s/fullchain.pem' "$LE_LIVE" "$1"; }
certbot_key()    { printf '%s/%s/privkey.pem'   "$LE_LIVE" "$1"; }
caddy_cert_dir() { printf '%s/certificates/%s/%s' "$CADDY_DATA" "$ACME_HOST" "$1"; }
site_file()      { printf '%s/%s.caddy' "$SITES_DIR" "$1"; }

caddy_has_cert() { [[ -f "$(caddy_cert_dir "$1")/$1.crt" ]]; }

# Which certificate files exist for a domain, whether or not a site uses them.
stored_cert_kind() {   # -> certbot | caddy | none
	local d="$1"
	[[ -f "$(certbot_cert "$d")" ]] && { echo certbot; return; }
	caddy_has_cert "$d" && { echo caddy; return; }
	echo none
}

# Which certificate a site actually serves. A leftover certbot copy must not
# hide the fact that Caddy is the one issuing and renewing it.
cert_kind() {   # -> certbot | caddy | internal | none
	local d="$1" f; f="$(site_file "$d")"
	[[ -f "$f" ]] || { stored_cert_kind "$d"; return; }
	if   grep -qE '^\s*tls\s+internal' "$f"; then echo internal
	elif grep -qE '^\s*tls\s+/' "$f";      then echo certbot
	elif grep -qE '^\s*http://' "$f";       then echo none
	elif caddy_has_cert "$d";               then echo caddy
	else echo none; fi
}

cert_expiry() {
	local d="$1" f=""
	case "$(cert_kind "$d")" in
		certbot) f="$(certbot_cert "$d")" ;;
		caddy)   f="$(caddy_cert_dir "$d")/$d.crt" ;;
		*) return 1 ;;
	esac
	openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2
}

valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

normalize_target() {
	local t="$1"
	[[ "$t" =~ ^[0-9]+$ ]] && t="127.0.0.1:$t"
	[[ "$t" =~ ^https?://[a-zA-Z0-9._-]+(:[0-9]+)?(/.*)?$ ]] && { echo "$t"; return; }
	[[ "$t" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]] || return 1
	echo "$t"
}

# host:port of a target, with any scheme and path stripped (for reachability tests)
target_hostport() {
	local t="${1#*://}"; t="${t%%/*}"; echo "$t"
}

# What kind of thing is this backend? Echoes "<kind> <value>".
#   proxy     a service to reverse-proxy to (local port, or someone else's site)
#   files     a directory served straight off disk
#   redirect  send visitors somewhere else entirely
classify_target() {
	local t="$1"
	case "$t" in
		redirect:*) printf 'redirect %s\n' "${t#redirect:}"; return 0 ;;
		redir:*)    printf 'redirect %s\n' "${t#redir:}";    return 0 ;;
		/*)         printf 'files %s\n'    "${t%/}";         return 0 ;;
	esac
	if [[ "$t" =~ ^[0-9]+$ ]]; then printf 'proxy 127.0.0.1:%s\n' "$t"; return 0; fi
	if [[ "$t" =~ ^https?://[a-zA-Z0-9._-]+(:[0-9]+)?(/.*)?$ ]]; then printf 'proxy %s\n' "$t"; return 0; fi
	if [[ "$t" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]]; then printf 'proxy %s\n' "$t"; return 0; fi
	if valid_domain "$t"; then printf 'proxy https://%s\n' "$t"; return 0; fi
	return 1
}

# A named host is somebody else's site; loopback or a bare IP is our own box.
# This decides the Host header: a remote vhost needs its own name to match.
target_is_remote() {
	local h; h="$(target_hostport "$1")"; h="${h%:*}"
	case "$h" in 127.0.0.1|::1|localhost|0.0.0.0) return 1 ;; esac
	if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then return 1; fi
	return 0
}

# Normalize "/a/b/" or "a/b" -> "/a/b"
clean_path() { local p="/${1#/}"; p="${p%/}"; [[ -z "$p" ]] && p="/"; echo "$p"; }

# Last error Caddy logged, used to explain a failed reload.
last_caddy_error() {
	journalctl -u caddy --since "30 seconds ago" --no-pager 2>/dev/null \
		| grep -iE 'error|denied|already in use' | tail -5 || true
}

# --- safe apply: validate -> reload, rollback on failure ---------------------
_rb_new=()        # files to delete on rollback
_rb_old=()        # "path|backup" pairs to restore on rollback

stage_new()  { _rb_new+=("$1"); }
stage_edit() { local b; b=$(mktemp); cp "$1" "$b"; _rb_old+=("$1|$b"); }

rollback() {
	local f e p
	for f in "${_rb_new[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
	for e in "${_rb_old[@]:-}"; do
		[[ -z "$e" ]] && continue
		p="${e%%|*}"
		cat "${e##*|}" > "$p"        # in place: keeps mode and owner
		rm -f "${e##*|}"
	done
	_rb_new=(); _rb_old=()
}
clear_stage() {
	local e
	for e in "${_rb_old[@]:-}"; do [[ -n "$e" ]] && rm -f "${e##*|}"; done
	_rb_new=(); _rb_old=()
}

apply() {
	local log; log=$(mktemp)

	if ! caddy validate --config "$CADDYFILE" >"$log" 2>&1; then
		grep -iE 'error|invalid|cannot|ambiguous' "$log" | head -20 >&2 || cat "$log" >&2
		rm -f "$log"; rollback
		die "Caddy config is invalid - everything was rolled back, Caddy untouched."
	fi
	rm -f "$log"

	# Make sure Caddy can still read what we just wrote before asking it to reload.
	if ! caddy_can_read "$CADDYFILE"; then
		warn "user '$CADDY_USER' cannot read $CADDYFILE - repairing permissions"
		fix_perms
	fi

	if systemctl reload caddy 2>/dev/null; then
		activity_diff
		clear_stage
		ok "Caddy reloaded with no downtime."
		return 0
	fi

	# --- reload failed: explain, try one targeted repair -------------------
	local err; err="$(last_caddy_error)"

	if grep -qi 'permission denied' <<<"$err"; then
		warn "reload failed: Caddy cannot read its config file."
		fix_perms
		if systemctl reload caddy 2>/dev/null; then
			activity_diff
			clear_stage
			ok "Permissions repaired, Caddy reloaded."
			return 0
		fi
		err="$(last_caddy_error)"
	fi

	if grep -qi 'address already in use' <<<"$err"; then
		warn "reload failed: port already in use by another process."
		dim "A site block without 'bind' makes Caddy listen on 0.0.0.0, which"
		dim "collides with anything else on :80/:443 on this machine."
		if [[ -n "$FRONT_IP" ]]; then
			echo
			info "Blocks missing 'bind':"
			find_unbound_blocks || dim "(none found - check other services with: ss -tnlp)"
			dim "Fix with:  $SELF_NAME fixbind"
		fi
	fi

	printf '%s\n' "$err" | sed 's/^/       /' >&2
	rollback
	systemctl reload caddy >/dev/null 2>&1 || true
	die "Reload failed - changes rolled back."
}

# =============================================================================
#  install
# =============================================================================
# =============================================================================
#  Bootstrap: install Caddy, then walk through the whole setup
# =============================================================================

detect_pkg() {
	if   have apt-get; then echo apt
	elif have dnf;     then echo dnf
	elif have yum;     then echo yum
	elif have pacman;  then echo pacman
	elif have apk;     then echo apk
	else echo unknown; fi
}

install_caddy() {
	local pm; pm="$(detect_pkg)"
	info "installing Caddy via $pm"
	case "$pm" in
		apt)
			export DEBIAN_FRONTEND=noninteractive
			apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null
			curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
				| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
			curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
				> /etc/apt/sources.list.d/caddy-stable.list
			chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
			chmod o+r /etc/apt/sources.list.d/caddy-stable.list
			apt-get update -qq
			apt-get install -y caddy
			;;
		dnf)
			dnf install -y 'dnf-command(copr)' dnf-plugins-core >/dev/null 2>&1 || true
			dnf copr enable -y @caddy/caddy
			dnf install -y caddy
			;;
		yum)
			yum install -y yum-plugin-copr >/dev/null 2>&1 || true
			yum copr enable -y @caddy/caddy
			yum install -y caddy
			;;
		pacman) pacman -Syu --noconfirm caddy ;;
		apk)    apk add --no-cache caddy ;;
		*) die "unknown package manager - install Caddy first: https://caddyserver.com/docs/install" ;;
	esac
	have caddy || die "Caddy still not on PATH after installing"
	ok "Caddy $(caddy version 2>/dev/null | head -1)"
}

# Best-effort helper install. Takes alternative package names for the same
# tool (dnsutils on Debian is bind-utils on Fedora) and tries them one at a
# time - passing both to one invocation fails the whole command.
install_optional() {
	local pm pkg; pm="$(detect_pkg)"
	for pkg in "$@"; do
		case "$pm" in
			apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 && return 0 ;;
			dnf)    dnf install -y "$pkg"    >/dev/null 2>&1 && return 0 ;;
			yum)    yum install -y "$pkg"    >/dev/null 2>&1 && return 0 ;;
			pacman) pacman -S --noconfirm "$pkg" >/dev/null 2>&1 && return 0 ;;
			apk)    apk add --no-cache "$pkg"    >/dev/null 2>&1 && return 0 ;;
			*) return 0 ;;
		esac
	done
	return 0
}

# What already owns :80/:443, so setup can explain itself instead of colliding.
# Deliberately avoids gawk's 3-argument match(): Debian ships mawk, where that
# is a syntax error rather than a graceful failure.
# With FRONT_IP set, only listeners on that address or on every address
# count: a service on another IP of a multi-address box is no conflict.
port_owner() {
	local p=":$1"
	ss -tnlpH 2>/dev/null | awk -v p="$p" -v ip="$FRONT_IP" '
		{
			a = $4
			if (length(a) >= length(p) && substr(a, length(a) - length(p) + 1) == p) {
				h = substr(a, 1, length(a) - length(p))
				sub(/%.*$/, "", h)
				if (ip != "" && h != ip && h != "0.0.0.0" && h != "*" && h != "[::]") next
				print; exit
			}
		}' | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p'
}

cmd_setup() {
	need_root setup
	local do_panel="" panel_domain="" panel_user="admin"
	local first_domain="" first_target="" email="" ip=""

	# setup is a wizard; with stdin on a pipe every prompt silently takes its
	# default, which is how people end up with the wrong address configured.
	# 'curl ... | bash' hits exactly this, so name the working form.
	if [[ ! -t 0 ]]; then
		warn "stdin is not a terminal, so setup cannot ask you anything"
		dim "it would silently accept every default. Run it one of these ways:"
		dim "    curl -fsSL $SELF_URL -o smart_caddy.sh && sudo bash smart_caddy.sh setup"
		die "refusing to guess"
	fi

	printf '\n%s┌──────────────────────────────────────────┐%s\n' "$C_B" "$C_OFF"
	printf '%s│  smart-caddy setup                       │%s\n'   "$C_B" "$C_OFF"
	printf '%s└──────────────────────────────────────────┘%s\n'   "$C_B" "$C_OFF"

	hdr "Looking around"

	local pm; pm="$(detect_pkg)"
	[[ "$pm" == unknown ]] && warn "unrecognised package manager" || ok "package manager: $pm"

	if have caddy; then
		ok "Caddy is installed - $(caddy version 2>/dev/null | head -1)"
	else
		warn "Caddy is not installed"
		if ask "Install it now from the official repository?" y; then
			install_caddy
		else
			die "Caddy is required. https://caddyserver.com/docs/install"
		fi
	fi

	have python3 || { warn "python3 missing (needed for the web panel)"; install_optional python3; }
	have setfacl || install_optional acl
	have dig     || install_optional dnsutils bind-utils bind9-dnsutils
	have nc      || install_optional netcat-openbsd netcat

	# --- addresses ---
	local ips; mapfile -t ips < <(ip -4 -o addr show scope global 2>/dev/null \
		| awk '{print $4}' | cut -d/ -f1)
	if [[ ${#ips[@]} -eq 0 ]]; then
		warn "no global IPv4 address found"
	elif [[ ${#ips[@]} -eq 1 ]]; then
		ok "one public address: ${ips[0]} - no bind needed"
		ip=""
	else
		ok "several addresses: ${ips[*]}"
	fi

	# --- who holds the web ports ---
	local o80 o443; o80="$(port_owner 80)"; o443="$(port_owner 443)"
	local blocked=0
	[[ -n "$o80"  ]] && { warn ":80 is held by '$o80'";  blocked=1; }
	[[ -n "$o443" ]] && { warn ":443 is held by '$o443'"; blocked=1; }
	[[ $blocked -eq 0 ]] && ok ":80 and :443 are free"

	if [[ $blocked -eq 1 && -n "$(caddy_front_port)" ]]; then
		ok "that program hands traffic to Caddy on 127.0.0.1:$(caddy_front_port) - sites will sit behind it"
		dnsguard_present && dim "it is DNSGuard: new domains are added to its SNI_LOCAL_NAMES for you"
		blocked=0
	fi
	if [[ $blocked -eq 1 ]]; then
		echo
		dim "Caddy cannot share a port with another process. Your options:"
		dim "  * if that is Xray, keep it and put sites behind its fallback:"
		dim "        smart-caddy add <domain> <port> --behind-xray"
		dim "  * if it is an old nginx/apache you no longer want, stop it first"
		dim "  * or give Caddy its own IP on a multi-address host"
		echo
		if [[ ${#ips[@]} -gt 1 ]]; then
			dim "You have more than one address, so Caddy can take a free one."
		fi
		ask "Continue with setup anyway?" y || { info "stopped"; exit 0; }
	fi

	# --- questions ---
	hdr "A few questions"

	if [[ ${#ips[@]} -gt 1 ]]; then
		dim "This host has several addresses. Caddy must be told which one to"
		dim "listen on, otherwise it grabs all of them and collides."
		while :; do
			prompt ip "Address for Caddy (one of: ${ips[*]})" "${ips[0]}"
			[[ " ${ips[*]} " == *" $ip "* ]] && break
			warn "'$ip' is not one of this host's addresses"
		done
	fi

	prompt email "Email for Let's Encrypt (expiry notices)" "admin@$(hostname -d 2>/dev/null || echo example.com)"

	if ask "Set up the web panel, so you can manage sites in a browser?" y; then
		do_panel=yes
		while :; do
			prompt panel_domain "Domain for the panel (e.g. caddy.example.com)"
			[[ -z "$panel_domain" ]] && { do_panel=""; break; }
			valid_domain "$panel_domain" && break
			warn "'$panel_domain' is not a valid domain"
		done
		[[ -n "$do_panel" ]] && prompt panel_user "Panel username" "admin"
	fi

	if ask "Add your first site now?" n; then
		while :; do
			prompt first_domain "Domain"
			[[ -z "$first_domain" ]] && break
			valid_domain "$first_domain" && break
			warn "not a valid domain"
		done
		[[ -n "$first_domain" ]] && prompt first_target "Backend (port, host:port, or https://host:port)"
	fi

	# --- do it ---
	hdr "Running install"
	local args=(install --yes --email "$email")
	[[ -n "$ip" ]] && args+=(--ip "$ip")
	cmd_install "${args[@]:1}"

	# cmd_install re-reads nothing, so pick the saved settings back up
	[[ -r "$CONF_FILE" ]] && . "$CONF_FILE"
	offer_import ask

	if [[ -n "$do_panel" ]]; then
		hdr "Setting up the web panel"
		cmd_panel "$panel_domain" --user "$panel_user" --yes || \
			warn "the panel step failed - you can retry with: $SELF_NAME panel"
	fi

	if [[ -n "$first_domain" && -n "$first_target" ]]; then
		hdr "Adding $first_domain"
		cmd_add "$first_domain" "$first_target" --yes || \
			warn "could not add $first_domain - try again with: $SELF_NAME add"
	fi

	hdr "Setup complete"
	dim "$SELF_NAME add <domain> <port>    add a site"
	dim "$SELF_NAME list                   see what you have"
	dim "$SELF_NAME doctor                 diagnose anything odd"
	[[ -n "$do_panel" ]] && dim "https://${panel_domain}      the web panel"
	echo
}

# Sites written by hand before smart-caddy existed sit in the Caddyfile,
# invisible to 'list' and the panel. Offer to adopt them. Never moves anyone's
# config behind their back: 'update' runs install --yes silently, so only an
# interactive run (or setup, which asks for real) imports.
offer_import() {
	local force_ask="${1:-}"
	[[ $ASSUME_YES -eq 1 && -z "$force_ask" ]] && return 0
	have python3 || return 0
	caddyfile_scan tsv 2>/dev/null | awk -F'\t' '$1=="site" && $5=="1"' | grep -q . || return 0
	hdr "Existing sites"
	info "the Caddyfile already serves sites smart-caddy does not manage yet:"
	caddyfile_scan tsv | awk -F'\t' '$1=="site" && $5=="1" { print "       " $6 }'
	if [[ ! -t 0 ]]; then
		dim "import them with: $SELF_NAME import   (or from the web panel)"
		return 0
	fi
	local was=$ASSUME_YES; ASSUME_YES=0
	if ask "Import them so the panel can show and edit them?" y; then
		( cmd_import --all ) || warn "import failed and was rolled back - nothing changed"
	else
		dim "later: $SELF_NAME import"
	fi
	ASSUME_YES=$was
}

cmd_install() {
	need_root install
	local ip="" email="" ip_given=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--ip)     ip="${2:?}"; ip_given=1; shift 2 ;;
			--email)  email="${2:?}";          shift 2 ;;
			--yes|-y) ASSUME_YES=1;            shift ;;
			*) die "unknown option: $1" ;;
		esac
	done

	have caddy || die "Caddy is not installed. See https://caddyserver.com/docs/install"
	[[ -f "$CADDYFILE" ]] || die "$CADDYFILE not found."

	hdr "1/9  Front IP"
	local ips; mapfile -t ips < <(ip -4 -o addr show scope global 2>/dev/null \
		| awk '{print $4}' | cut -d/ -f1)
	if [[ $ip_given -eq 0 ]]; then
		# Once every site lives in sites.d the Caddyfile holds no 'bind' at
		# all, so the saved setting and the site files count first.
		local existing=""
		[[ -n "$FRONT_IP" && " ${ips[*]} " == *" $FRONT_IP "* ]] && existing="$FRONT_IP"
		[[ -z "$existing" ]] && existing=$(cat "$CADDYFILE" "$SITES_DIR"/*.caddy 2>/dev/null \
			| grep -oP '^\s*bind\s+\K[0-9.]+' | grep -v '^127\.' | head -1 || true)
		if [[ -n "$existing" ]]; then
			ip="$existing"; info "keeping the address Caddy already uses: $ip"
		elif [[ ${#ips[@]} -eq 1 ]]; then
			ip=""; info "single-IP host (${ips[0]}) - no bind needed"
		elif [[ ${#ips[@]} -eq 0 ]]; then
			# No global IPv4: a v6-only box, or 'ip' is missing. Leaving bind
			# unset is the safe default - Caddy listens on everything.
			ip=""; warn "no global IPv4 address found - continuing without 'bind'"
			dim "pass --ip <address> if Caddy should listen on one address only"
		else
			warn "this host has several IPs: ${ips[*]}"
			warn "with more than one service on :80/:443, 'bind' is mandatory"
			die "re-run with --ip <address>, e.g. $0 install --ip ${ips[0]}"
		fi
	fi
	FRONT_IP="$ip"
	[[ -n "$FRONT_IP" ]] && ok "front IP: $FRONT_IP" || ok "no bind (single IP)"

	hdr "2/9  Backup"
	local bak="${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"
	cp -p "$CADDYFILE" "$bak"; ok "$bak"

	hdr "3/9  Sites directory and import line"
	mkdir -p "$SITES_DIR"
	if grep -qF "$SITES_DIR" "$CADDYFILE"; then
		ok "import line already present"
	else
		printf '\n# --- sites managed by %s ---\nimport %s/*.caddy\n' \
			"$SELF_NAME" "$SITES_DIR" >> "$CADDYFILE"
		ok "import line appended"
	fi

	hdr "4/9  Global options block"
	if ! grep -qE '^\s*\{\s*$' "$CADDYFILE"; then
		[[ -z "$email" ]] && email="admin@$(hostname -d 2>/dev/null || echo localhost)"
		local tmp; tmp=$(mktemp)
		{ printf '{\n\tadmin 127.0.0.1:2019\n\temail %s\n}\n\n' "$email"; cat "$CADDYFILE"; } > "$tmp"
		write_inplace "$CADDYFILE" "$tmp"     # keeps mode + ownership
		ok "added (email: $email)"
		ACME_EMAIL="$email"
	else
		ok "already present - left alone"
		ACME_EMAIL=$(grep -oP '^\s*email\s+\K\S+' "$CADDYFILE" | head -1 || true)
	fi

	hdr "5/9  File permissions"
	fix_perms
	if caddy_can_read "$CADDYFILE"; then
		ok "user '$CADDY_USER' can read $CADDYFILE"
	else
		warn "user '$CADDY_USER' still cannot read $CADDYFILE"
		dim "check: namei -l $CADDYFILE"
	fi

	hdr "6/9  certbot integration"
	if [[ -d /etc/letsencrypt ]]; then
		if have setfacl; then
			setfacl -R  -m "u:${CADDY_USER}:rX" /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
			setfacl -dR -m "u:${CADDY_USER}:rX" /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
			ok "ACL granted to user '$CADDY_USER'"
		else
			warn "setfacl not installed - Caddy will not be able to read certbot certs"
			dim "install with: apt install -y acl   (or dnf install -y acl)"
		fi
		mkdir -p /etc/letsencrypt/renewal-hooks/deploy
		cat > /etc/letsencrypt/renewal-hooks/deploy/00-reload-caddy.sh <<-EOF
			#!/bin/sh
			# installed by ${SELF_NAME}
			command -v setfacl >/dev/null 2>&1 && \\
			  setfacl -R -m u:${CADDY_USER}:rX /etc/letsencrypt/live /etc/letsencrypt/archive
			systemctl reload caddy
		EOF
		chmod +x /etc/letsencrypt/renewal-hooks/deploy/00-reload-caddy.sh
		ok "renewal hook installed"
	else
		info "certbot not present - Caddy will manage its own certificates"
	fi

	hdr "7/9  Saving settings"
	cat > "$CONF_FILE" <<-EOF
		# ${SELF_NAME} v${VERSION} - $(date -Is)
		CADDYFILE="${CADDYFILE}"
		SITES_DIR="${SITES_DIR}"
		CADDY_USER="${CADDY_USER}"
		CADDY_GROUP="$(caddy_group)"
		CADDY_DATA="${CADDY_DATA}"
		LE_LIVE="${LE_LIVE}"
		FRONT_IP="${FRONT_IP}"
		ACME_EMAIL="${ACME_EMAIL}"
		SRC_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo .)")" 2>/dev/null && pwd || echo "")"
	EOF
	chmod 0644 "$CONF_FILE"; ok "$CONF_FILE"

	local src=""
	if src="$(self_source)"; then
		if [[ "$(readlink -f "$src")" != "/usr/local/bin/$SELF_NAME" ]]; then
			install -m 0755 "$src" "/usr/local/bin/$SELF_NAME"
			ok "command installed -> /usr/local/bin/$SELF_NAME"
		fi
		case "$src" in /tmp/smart-caddy.*.sh) rm -f "$src" ;; esac
	else
		warn "could not get a copy of this script to install"
		dim "download it to a file and run 'install' again, or set SMART_CADDY_URL"
	fi

	# Stash the web UI now, while we still know where the download landed.
	# After this the CLI runs from /usr/local/bin, where the .py never was.
	local ui_src
	if ui_src="$(find_ui_source)"; then
		mkdir -p "$(dirname "$UI_PY")"
		install -m 0755 "$ui_src" "$UI_PY"
		ok "web panel source stored -> $UI_PY"
		# a running panel keeps the old code in memory until it restarts
		if systemctl is-active --quiet smart-caddy-ui 2>/dev/null; then
			systemctl restart smart-caddy-ui >/dev/null 2>&1 \
				&& ok "web panel restarted on the new version" || true
		fi
	else
		info "smart_caddy_ui.py not found - the CLI works, 'panel' needs it"
		dim "put it next to this script and re-run install to enable the web panel"
	fi

	hdr "8/9  Checking 'bind' on existing blocks"
	if [[ -n "$FRONT_IP" ]] && find_unbound_blocks; then
		warn "the blocks above have no 'bind' - they will collide on :80/:443"
		if ask "Add 'bind $FRONT_IP' to them now?" y; then
			cmd_fixbind
		else
			dim "later: $SELF_NAME fixbind"
		fi
	else
		ok "all blocks are bound"
	fi

	hdr "9/9  Final check"
	if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
		ok "config is valid"
		if systemctl reload caddy 2>/dev/null; then
			ok "Caddy reloaded"
		else
			warn "reload failed:"
			last_caddy_error | sed 's/^/       /'
			dim "run '$SELF_NAME doctor' for a full diagnosis"
			dim "clean backup: $bak"
		fi
	else
		warn "config still invalid:"
		caddy validate --config "$CADDYFILE" 2>&1 | grep -i error | head -10 | sed 's/^/       /'
		dim "clean backup: $bak"
	fi

	offer_import

	hdr "Ready"
	dim "$SELF_NAME add panel.example.com 54321"
	dim "$SELF_NAME doctor"
}

# =============================================================================
#  fixbind
# =============================================================================
snippets_with_bind() {
	awk '
		/^[ \t]*\(/ { inside=1; name=$0; sub(/^[ \t]*\(/,"",name); sub(/\).*$/,"",name); has=0; next }
		inside && /^[ \t]*bind[ \t]/ { has=1 }
		inside && /^[ \t]*\}/ { if (has) print name; inside=0 }
	' "$CADDYFILE" | paste -sd'|' -
}

find_unbound_blocks() {
	local snips; snips="$(snippets_with_bind)"; [[ -z "$snips" ]] && snips="__none__"
	local out
	out=$(awk -v SNIPS="$snips" '
		function cntc(s, ch,   t){ t=s; return gsub(ch,"",t) }
		BEGIN{ depth=0; started=0 }
		{
			op=cntc($0,"{"); cl=cntc($0,"}")
			if (!started && op>0) {
				header=$0; started=1; hasbind=0
				isglobal  = ($0 ~ /^[ \t]*\{/)
				issnippet = ($0 ~ /^[ \t]*\(/)
				if ($0 ~ /[{ \t]bind[ \t]/) hasbind=1
				depth = op-cl
				if (depth<=0) {
					if (!isglobal && !issnippet && !hasbind) {
						h=header; sub(/[ \t]*\{.*$/,"",h); print h
					}
					started=0
				}
				next
			}
			if (started) {
				if ($0 ~ /^[ \t]*bind[ \t]/) hasbind=1
				if ($0 ~ ("^[ \t]*import[ \t]+(" SNIPS ")[ \t]*$")) hasbind=1
				depth += op-cl
				if (depth<=0) {
					if (!isglobal && !issnippet && !hasbind) {
						h=header; sub(/[ \t]*\{.*$/,"",h); print h
					}
					started=0
				}
			}
		}
	' "$CADDYFILE")
	[[ -z "$out" ]] && return 1
	printf '%s\n' "$out" | while read -r l; do dim "-> $l"; done
	return 0
}

cmd_fixbind() {
	need_root fixbind
	[[ -n "$FRONT_IP" ]] || die "FRONT_IP is not set. Run: $SELF_NAME install --ip <address>"
	local snips; snips="$(snippets_with_bind)"; [[ -z "$snips" ]] && snips="__none__"
	local tmp; tmp=$(mktemp)
	awk -v IP="$FRONT_IP" -v SNIPS="$snips" '
		function cntc(s, ch,   t){ t=s; return gsub(ch,"",t) }
		BEGIN{ depth=0; started=0; n=0 }
		{
			op=cntc($0,"{"); cl=cntc($0,"}")
			if (!started && op>0) {
				n=1; B[1]=$0; started=1; hasbind=0
				isglobal  = ($0 ~ /^[ \t]*\{/)
				issnippet = ($0 ~ /^[ \t]*\(/)
				if ($0 ~ /[{ \t]bind[ \t]/) hasbind=1
				depth = op-cl
				if (depth<=0) {                       # one-line block: expand it
					if (!isglobal && !issnippet && !hasbind) {
						h=$0; sub(/\{.*$/,"",h); gsub(/[ \t]+$/,"",h)
						b=$0; sub(/^[^{]*\{/,"",b); sub(/\}[ \t]*$/,"",b)
						gsub(/^[ \t]+/,"",b); gsub(/[ \t]+$/,"",b)
						printf "%s {\n\tbind %s\n", h, IP
						if (b != "") printf "\t%s\n", b
						printf "}\n"
					} else print $0
					started=0; n=0
				}
				next
			}
			if (started) {
				n++; B[n]=$0
				if ($0 ~ /^[ \t]*bind[ \t]/) hasbind=1
				if ($0 ~ ("^[ \t]*import[ \t]+(" SNIPS ")[ \t]*$")) hasbind=1
				depth += op-cl
				if (depth<=0) {
					print B[1]
					if (!isglobal && !issnippet && !hasbind) printf "\tbind %s\n", IP
					for (i=2;i<=n;i++) print B[i]
					started=0; n=0
				}
				next
			}
			print
		}
	' "$CADDYFILE" > "$tmp"

	if diff -q "$CADDYFILE" "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"; ok "every block already has 'bind'"; return
	fi
	stage_edit "$CADDYFILE"
	write_inplace "$CADDYFILE" "$tmp"      # keeps mode + ownership
	apply
	ok "'bind $FRONT_IP' added to blocks that were missing it"
}

# =============================================================================
#  add
# =============================================================================
# =============================================================================
#  Sitting behind an Xray fallback
#
#  When Xray owns :443 it terminates TLS itself and hands the decrypted stream
#  to a local port, optionally prefixed with a PROXY protocol header (xver).
#  So the web server behind it speaks plain HTTP on loopback, must parse that
#  header, and needs h2c because an "alpn h2" fallback arrives as cleartext
#  HTTP/2. Getting any one of those wrong looks like a dead port.
# =============================================================================

# First TCP port in a range that nothing is listening on and no other site uses.
pick_free_port() {
	local lo="${1:-8081}" hi="${2:-8199}" p
	for (( p = lo; p <= hi; p++ )); do
		ss -tnlH 2>/dev/null | grep -qE "[:.]${p}\b" && continue
		grep -rqs "127\.0\.0\.1:${p}\b" "$SITES_DIR" 2>/dev/null && continue
		printf '%s\n' "$p"; return 0
	done
	return 1
}

# Every fallback dest port Xray currently knows about, from whichever config
# file this box uses. Used to tell the user whether they still owe us a row.
xray_fallback_dests() {
	local f
	for f in /usr/local/x-ui/bin/config.json /usr/local/etc/xray/config.json \
	         /etc/xray/config.json /opt/xray/config.json; do
		[[ -r "$f" ]] || continue
		python3 -c '
import json, sys, re
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
out = set()
def walk(o):
    if isinstance(o, dict):
        if "dest" in o and not isinstance(o["dest"], (dict, list)):
            m = re.search(r"(\d+)\s*$", str(o["dest"]))
            if m:
                out.add(m.group(1))
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(cfg)
print("\n".join(sorted(out)))
' "$f" 2>/dev/null
	done | sort -u
}

# Caddy requires listener options in the global block, which must be the first
# block in the Caddyfile - so this is the one place we edit it directly.
ensure_global_server_block() {
	local addr="$1" tmp
	grep -qF "servers ${addr} {" "$CADDYFILE" && return 0

	tmp="$(mktemp)"
	if grep -qE '^\s*\{\s*$' "$CADDYFILE"; then
		awk -v addr="$addr" '
			BEGIN { done = 0 }
			{
				print
				if (!done && $0 ~ /^[ \t]*\{[ \t]*$/) {
					printf "\tservers %s {\n", addr
					print  "\t\tprotocols h1 h2c"
					print  "\t\tlistener_wrappers {"
					print  "\t\t\tproxy_protocol {"
					print  "\t\t\t\tallow 127.0.0.1/32"
					print  "\t\t\t}"
					print  "\t\t}"
					print  "\t\ttrusted_proxies static 127.0.0.1/32"
					print  "\t}"
					done = 1
				}
			}
		' "$CADDYFILE" > "$tmp"
	else
		{
			echo "{"
			printf '\tservers %s {\n' "$addr"
			echo -e "\t\tprotocols h1 h2c"
			echo -e "\t\tlistener_wrappers {"
			echo -e "\t\t\tproxy_protocol {"
			echo -e "\t\t\t\tallow 127.0.0.1/32"
			echo -e "\t\t\t}"
			echo -e "\t\t}"
			echo -e "\t\ttrusted_proxies static 127.0.0.1/32"
			echo -e "\t}"
			echo "}"
			echo
			cat "$CADDYFILE"
		} > "$tmp"
	fi
	stage_edit "$CADDYFILE"
	write_inplace "$CADDYFILE" "$tmp"
}

cmd_add() {
	need_root add
	local domain="${1:-}" target="${2:-}"
	local host_header="" cert_mode="auto" dns_check=1
	local paths="" insecure=0 nobuffer=0 preset="" wizard=0 strict_path=0
	local behind_xray=0 listen_port="" replace=0 routes=()

	# No arguments at all -> walk the user through it.
	if [[ -z "$domain" ]]; then
		wizard=1
		hdr "Add a site"
		[[ -n "$FRONT_IP" ]] && dim "This server answers on $FRONT_IP"
		echo
		while :; do
			prompt domain "Domain (e.g. panel.example.com)"
			[[ -z "$domain" ]] && die "cancelled"
			valid_domain "$domain" && break
			warn "'$domain' is not a valid domain - try again"
		done
		dim "Backend can be any of:"
		dim "  54321                    a port on this machine"
		dim "  https://127.0.0.1:27389  a local app that serves TLS itself"
		dim "  /var/www/mysite          a directory of files to serve"
		dim "  example.com              proxy through to another site"
		dim "  redirect:https://x.com   just send visitors elsewhere"
		while :; do
			prompt target "Backend"
			[[ -z "$target" ]] && die "cancelled"
			classify_target "$target" >/dev/null && break
			warn "'$target' is not something I recognise - try again"
		done
		dim "Some panels live under a secret path, e.g. /5wSobQvUFuNy4zBUcc."
		dim "Leave blank to serve the whole domain."
		prompt paths "Path prefix" ""
		dim "Routers and modem UIs usually need Host forced to 127.0.0.1."
		prompt host_header "Force Host header (blank for none)" ""
		if ask "  Is this an admin panel (x-ui, marzban, hiddify, ...)?" y; then
			preset="panel"
		fi
		echo
	else
		shift 2 2>/dev/null || shift $#
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--path)         paths="${paths:+$paths,}${2:?}"; shift 2 ;;
			--strict-path)  strict_path=1;         shift ;;
			--route)        routes+=("${2:?}");    shift 2 ;;
			--replace)      replace=1;             shift ;;
			--behind-xray)  behind_xray=1;         shift ;;
			--listen-port)  listen_port="${2:?}";  shift 2 ;;
			--host-header)  host_header="${2:?}";  shift 2 ;;
			--insecure)     insecure=1;            shift ;;
			--no-buffer)    nobuffer=1;            shift ;;
			--panel)        preset="panel";        shift ;;
			--auto-cert)    cert_mode="acme";      shift ;;
			--certbot)      cert_mode="certbot";   shift ;;
			--self-signed)  cert_mode="internal";  shift ;;
			--no-tls)       cert_mode="none";      shift ;;
			--no-dns-check) dns_check=0;           shift ;;
			--yes|-y)       ASSUME_YES=1;          shift ;;
			*) die "unknown option: $1" ;;
		esac
	done

	# --panel: what admin panels (x-ui, 3x-ui, marzban, hiddify...) normally need
	if [[ "$preset" == "panel" ]]; then
		insecure=1
		nobuffer=1
	fi

	valid_domain "$domain" || die "invalid domain: $domain"
	local tinfo tkind
	tinfo="$(classify_target "$target")" \
		|| die "don't know what to do with backend '$target'
       expected a port, host:port, https://host:port, a directory path,
       another domain, or redirect:<url>"
	tkind="${tinfo%% *}"; target="${tinfo#* }"
	if [[ -f "$(site_file "$domain")" && $replace -eq 0 ]]; then
		die "$domain already exists. Remove it first: $SELF_NAME del $domain  (or pass --replace)"
	fi
	# Editing a site behind Xray must keep its loopback port, or the fallback
	# row already saved in x-ui would point at nothing.
	if [[ $replace -eq 1 && $behind_xray -eq 1 && -z "$listen_port" && -f "$(site_file "$domain")" ]]; then
		listen_port=$(grep -oP '^http://[^:]+:\K[0-9]+' "$(site_file "$domain")" | head -1 || true)
	fi

	# --route PATH=TARGET: send one path to a different backend
	local r rpath rtarget rinfo route_specs=()
	for r in ${routes[@]+"${routes[@]}"}; do
		rpath="${r%%=*}"; rtarget="${r#*=}"
		[[ "$r" == *=* && "$rpath" =~ ^/[A-Za-z0-9._~/*-]*$ ]] \
			|| die "invalid --route '$r'  (expected /path=backend, e.g. /dns-query/*=8000)"
		rinfo="$(classify_target "$rtarget")" || die "don't know what to do with route backend '$rtarget'"
		route_specs+=("$rpath ${rinfo}")
	done
	mkdir -p "$SITES_DIR"
	grep -qF "$SITES_DIR" "$CADDYFILE" || die "import line missing. Run: $SELF_NAME install"

	hdr "Pre-flight checks"

	if [[ $dns_check -eq 1 ]] && have dig; then
		local r; r=$(dig +short "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || true
		if [[ -z "$r" ]]; then
			warn "no A record found for $domain"
			ask "Continue anyway?" n || exit 1
		elif [[ -n "$FRONT_IP" && "$r" != "$FRONT_IP" ]]; then
			warn "$domain -> $r  but Caddy listens on $FRONT_IP"
			dim "Point the A record at $FRONT_IP or no traffic (and no cert) will arrive."
			ask "Write the config anyway?" n || exit 1
		else
			ok "DNS -> $r"
		fi
	fi

	local hp="" th="" tp=""
	if [[ "$tkind" == files ]]; then
		if [[ -d "$target" ]]; then
			ok "serving files from $target"
		else
			warn "$target is not a directory"
			ask "Create it?" y && { mkdir -p "$target"; ok "created $target"; }
		fi
	elif [[ "$tkind" == redirect ]]; then
		ok "visitors will be redirected to $target"
	elif target_is_remote "$target"; then
		hp="$(target_hostport "$target")"; th="${hp%:*}"
		ok "remote site: $target"
		dim "Host will be sent as $th so their vhost matches"
	else
		hp="$(target_hostport "$target")"; th="${hp%:*}"; tp="${hp##*:}"
		if have nc && ! nc -z -w2 "$th" "$tp" 2>/dev/null; then
			warn "$hp is not answering right now - config will be written anyway"
		else
			ok "backend $hp is reachable"
		fi
	fi

	# A backend that speaks TLS on a plain-http target is the most common 502 cause.
	if [[ "$tkind" == proxy ]] && have curl && [[ "$target" != https://* ]] \
	   && ! target_is_remote "$target"; then
		if curl -sk --max-time 3 "https://$hp/" -o /dev/null 2>/dev/null \
		   && ! curl -s --max-time 3 "http://$hp/" -o /dev/null 2>/dev/null; then
			warn "$hp appears to speak HTTPS, not HTTP"
			dim "use  https://$hp  as the target (add --insecure for a self-signed cert)"
			ask "Switch the target to https://$hp automatically?" y && {
				target="https://$hp"; insecure=1; ok "target set to $target --insecure"
			}
		fi
	fi

	local front_port; front_port="$(caddy_front_port)"
	if [[ -n "$front_port" && $behind_xray -eq 0 ]]; then
		ok "Caddy sits behind a front proxy on :443 - this site is served on 127.0.0.1:${front_port}"
	fi

	if [[ $behind_xray -eq 1 ]]; then
		cert_mode="none"          # Xray holds the certificate, not us
		dns_check=0               # nothing of ours is reachable from outside
		if [[ -z "$listen_port" ]]; then
			listen_port="$(pick_free_port)" \
				|| die "no free loopback port in 8081-8199; pass --listen-port"
			ok "picked free loopback port $listen_port"
		fi
		[[ "$listen_port" =~ ^[0-9]+$ ]] || die "invalid --listen-port: $listen_port"
	fi

	# auto keeps whatever an edited site already used; for a new one it reuses
	# a certificate that is already on disk rather than issuing another
	local tls_block="" kind; kind="$(cert_kind "$domain")"
	[[ "$kind" == none || "$kind" == internal ]] && kind="$(stored_cert_kind "$domain")"
	case "$cert_mode" in
		none)     info "plain HTTP, no TLS" ;;
		internal) tls_block=$'\ttls internal'; info "internal Caddy cert (browsers will warn)" ;;
		acme)
			if caddy_has_cert "$domain"; then ok "Caddy already holds a certificate - it renews it by itself"
			else info "Caddy will get a certificate from Let's Encrypt and renew it by itself"; fi ;;
		certbot)
			[[ -f "$(certbot_cert "$domain")" ]] \
				|| die "no certbot certificate for $domain in $LE_LIVE - use --auto-cert to let Caddy get one"
			tls_block=$'\ttls '"$(certbot_cert "$domain") $(certbot_key "$domain")"
			ok "using the certbot certificate"
			certbot_renew_ok "$domain" || {
				warn "certbot cannot renew this certificate on this machine"
				dim "it will expire on $(openssl x509 -in "$(certbot_cert "$domain")" -noout -enddate 2>/dev/null | cut -d= -f2)"
				dim "let Caddy handle it instead: --auto-cert"; } ;;
		auto)
			case "$kind" in
				certbot)
					tls_block=$'\ttls '"$(certbot_cert "$domain") $(certbot_key "$domain")"
					ok "certificate already exists (certbot) - reusing it, no new issuance"
					dim "expires: $(cert_expiry "$domain")" ;;
				caddy)
					ok "certificate already exists (Caddy's own store) - not re-issuing"
					dim "expires: $(cert_expiry "$domain")" ;;
				none)
					info "no certificate yet - Caddy will obtain one right after reload" ;;
			esac ;;
	esac

	# --- render the reverse_proxy block at a given indent level ---------------
	render_proxy() {
		local ind="$1" target="${2:-$target}" hh="$host_header"
		if [[ -z "$hh" ]]; then
			if target_is_remote "$target"; then
				hh="$(target_hostport "$target")"; hh="${hh%:*}"
			else
				hh='{host}'
			fi
		fi
		printf '%sreverse_proxy %s {\n' "$ind" "$target"
		if [[ "$target" == https://* ]]; then
			printf '%s\ttransport http {\n' "$ind"
			[[ $insecure -eq 1 ]] && printf '%s\t\ttls_insecure_skip_verify\n' "$ind"
			# Caddy defaults to "versions 1.1 2" and a TLS backend can negotiate
			# HTTP/2 over ALPN. HTTP/2 has no Upgrade mechanism, so WebSocket
			# handshakes silently fail - which is how live traffic/speed panels
			# end up permanently blank while the rest of the app works.
			printf '%s\t\tversions 1.1\n' "$ind"
			printf '%s\t}\n'               "$ind"
		fi
		printf '%s\theader_up Host %s\n'               "$ind" "$hh"
		printf '%s\theader_up X-Real-IP {remote_host}\n'      "$ind"
		printf '%s\theader_up X-Forwarded-Proto {scheme}\n'   "$ind"
		printf '%s\theader_up X-Forwarded-Port {server_port}\n' "$ind"
		if [[ $nobuffer -eq 1 ]]; then
			printf '%s\n%s\t# stream responses straight through - needed for live\n' "" "$ind"
			printf '%s\t# stats, SSE and log tails, which otherwise sit in a buffer\n' "$ind"
			printf '%s\tflush_interval -1\n' "$ind"
		fi
		printf '%s}\n' "$ind"
	}

	if [[ $behind_xray -eq 1 ]]; then
		ensure_global_server_block "127.0.0.1:${listen_port}"
	fi

	render_body() {
		local ind="$1" tkind="${2:-$tkind}" target="${3:-$target}"
		case "$tkind" in
			files)
				printf '%sroot * %s\n'  "$ind" "$target"
				printf '%sfile_server\n' "$ind"
				;;
			redirect)
				printf '%sredir %s{uri} permanent\n' "$ind" "${target%/}"
				;;
			*) render_proxy "$ind" "$target" ;;
		esac
	}

	if [[ -n "$host_header" && "$preset" == panel ]]; then
		warn "forcing the Host header on an admin panel usually breaks it"
		dim "Panels check the websocket's Origin against the Host they receive."
		dim "Sending Host: $host_header while the browser sends"
		dim "Origin: https://$domain makes that check fail, the websocket is"
		dim "refused, and live traffic/speed columns stay empty forever."
		dim "Leave the Host header blank unless this is a router or modem UI."
		ask "Drop the Host header?" y && { host_header=""; ok "Host header removed"; }
	fi

	render_main() {
		if [[ ${#route_specs[@]} -gt 0 ]]; then
			echo -e "\t# everything else"
			echo -e "\thandle {"
			render_body $'\t\t'
			echo -e "\t}"
		else
			render_body $'\t'
		fi
	}

	local f; f="$(site_file "$domain")"
	# --replace edits in place: back the old file up so a rejected config
	# rolls back to exactly what was there, with no moment of downtime.
	if [[ -f "$f" ]]; then stage_edit "$f"; else stage_new "$f"; fi
	{
		if [[ $behind_xray -eq 1 ]]; then
			echo "# behind an Xray fallback: Xray terminates TLS on :443 and forwards"
			echo "# the decrypted stream here, so this listener is plain HTTP on"
			echo "# loopback. The PROXY protocol header and h2c are handled by the"
			echo "# matching 'servers 127.0.0.1:${listen_port}' block in the Caddyfile."
			echo "http://${domain}:${listen_port} {"
			echo -e "\tbind 127.0.0.1"
		elif [[ "$cert_mode" == "none" ]]; then
			echo "http://$domain {"
			bind_line
		else
			echo "$domain {"
			bind_line
		fi
		echo -e "\tencode zstd gzip"
		[[ -n "$tls_block" ]] && echo "$tls_block"

		local rs
		for rs in ${route_specs[@]+"${route_specs[@]}"}; do
			# "<path> <kind> <target>"
			echo
			echo -e "\t# route: ${rs%% *}"
			printf '\thandle %s {\n' "${rs%% *}"
			rs="${rs#* }"
			render_body $'\t\t' "${rs%% *}" "${rs#* }"
			echo -e "\t}"
		done

		if [[ -n "$paths" && $strict_path -eq 1 ]]; then
			# Match the bare prefix and everything under it, and refuse the rest.
			local matcher="" p parr
			IFS=',' read -ra parr <<< "$paths"
			for p in "${parr[@]}"; do
				p="$(clean_path "$p")"
				matcher+=" $p $p/*"
			done
			echo
			echo -e "\t@app path${matcher}"
			echo -e "\thandle @app {"
			render_body $'\t\t'
			echo -e "\t}"
			echo
			echo -e "\t# --strict-path: everything outside the prefix is refused."
			echo -e "\t# Apps that open a websocket or load assets from the site"
			echo -e "\t# root will break here - live stats are the usual casualty."
			echo -e "\thandle {"
			echo -e "\t\trespond 404"
			echo -e "\t}"
		elif [[ -n "$paths" ]]; then
			# Recorded, not enforced. Panels routinely open their websocket
			# outside their own base path, so matching on the prefix silently
			# kills live stats while the rest of the app looks fine. The app
			# already 404s its own root; use --strict-path to enforce anyway.
			echo
			echo -e "\t# app base path: ${paths//,/ }"
			render_main
		else
			echo
			render_main
		fi
		echo "}"
		if [[ -n "$front_port" && $behind_xray -eq 0 && "$cert_mode" != none ]] && caddy_redirects_off; then
			redirect_block "$domain"
		fi
	} > "$f"
	unset -f render_proxy render_body render_main
	chown "root:$(caddy_group)" "$f" 2>/dev/null || true
	chmod 0644 "$f"

	if [[ -n "$paths" && $strict_path -eq 1 ]]; then
		warn "--strict-path refuses every request outside $paths"
		dim "If the app opens a websocket or loads assets from the site root,"
		dim "that traffic is now blocked. Live traffic/speed panels are the"
		dim "usual casualty. Drop --strict-path if something goes blank."
	fi

	hdr "Applying"
	apply
	# before waiting for a certificate: Let's Encrypt can only reach this
	# name once the front proxy hands it to Caddy
	[[ $behind_xray -eq 0 ]] && front_register "$domain"

	if { [[ "$cert_mode" == "auto" && "$kind" == "none" ]]; } \
	   || { [[ "$cert_mode" == "acme" ]] && ! caddy_has_cert "$domain"; }; then
		printf '%s[info]%s waiting for certificate issuance' "$C_INF" "$C_OFF"
		local i
		for i in $(seq 1 30); do
			if caddy_has_cert "$domain"; then
				printf '\n'; ok "certificate issued, expires: $(cert_expiry "$domain")"
				break
			fi
			printf '.'; sleep 2
			if [[ $i -eq 30 ]]; then
				printf '\n'
				warn "not issued yet - usually means port 80 is not reachable for this domain"
				dim "check: journalctl -u caddy -n 40 --no-pager | grep -i acme"
			fi
		done
	fi

	if [[ $behind_xray -eq 1 ]]; then
		hdr "Done - one step left, in Xray"
		ok "listening on 127.0.0.1:${listen_port} (plain HTTP, PROXY protocol v2)"
		echo
		dim "Xray owns :443 and will not send anything here until you add a"
		dim "fallback for this domain. In x-ui: edit the inbound on 443 ->"
		dim "Fallbacks -> Add fallback, then fill in:"
		echo
		printf '    %-6s %s\n' "SNI"  "$domain"
		printf '    %-6s %s\n' "ALPN" "(leave empty)"
		printf '    %-6s %s\n' "Path" "/"
		printf '    %-6s %s\n' "Dest" "127.0.0.1:${listen_port}"
		printf '    %-6s %s\n' "xver" "2"
		echo
		dim "Leave ALPN empty unless you know the inbound advertises h2 - an"
		dim "'alpn h2' fallback that the inbound never negotiates simply never"
		dim "matches, and the domain looks dead for no visible reason."
		echo
		warn "The certificate for $domain must be on the Xray inbound, not here."
		dim "Xray terminates TLS; this listener never sees a handshake."

		local dests; dests="$(xray_fallback_dests)"
		if [[ -n "$dests" ]]; then
			if grep -qx "$listen_port" <<<"$dests"; then
				echo
				ok "an Xray fallback already points at :${listen_port} - nothing to do"
			else
				echo
				dim "Xray currently falls back to ports: $(tr '\n' ' ' <<<"$dests")"
			fi
		fi
		[[ -n "$host_header" ]] && dim "Host header forced to: $host_header"
		dim "file: $f"
		return 0
	fi

	hdr "Done"
	local scheme="https"; [[ "$cert_mode" == "none" ]] && scheme="http"
	if [[ -n "$paths" ]]; then
		local p parr
		IFS=',' read -ra parr <<< "$paths"
		for p in "${parr[@]}"; do
			ok "${scheme}://${domain}$(clean_path "$p")/  ->  ${target}"
		done
		dim "every other path on this domain returns 404"
	else
		ok "${scheme}://${domain}  ->  ${target}"
	fi
	[[ -n "$host_header" ]] && dim "Host header forced to: $host_header"
	[[ $insecure  -eq 1 ]] && dim "upstream TLS verification disabled"
	[[ $nobuffer  -eq 1 ]] && dim "response buffering off (live stats will update)"
	dim "file: $f"
}

# Can certbot renew this certificate here? Its standalone mode needs :80 free
# and its nginx mode needs nginx - neither holds once Caddy runs the show.
certbot_renew_ok() {
	local conf="/etc/letsencrypt/renewal/$1.conf" auth
	[[ -r "$conf" ]] || return 1
	auth=$(grep -oP '^\s*authenticator\s*=\s*\K\S+' "$conf" | head -1 || true)
	case "$auth" in
		standalone) [[ -z "$(port_owner 80)" ]] ;;
		nginx)      have nginx && systemctl is-active --quiet nginx ;;
		apache)     have apache2 || have httpd ;;
		*)          return 0 ;;   # webroot, dns-*: assume whoever set it up knows
	esac
}

# cert <domain> caddy - hand a site's certificate over to Caddy, which issues
# and renews it itself. Drops the 'tls <file> <file>' line; nothing is deleted.
cmd_cert() {
	need_root cert
	local domain="${1:-}" to="${2:-}"
	valid_domain "$domain" || die "usage: $SELF_NAME cert <domain> caddy"
	[[ "$to" == caddy ]] || die "usage: $SELF_NAME cert <domain> caddy"
	local f; f="$(site_file "$domain")"
	[[ -f "$f" ]] || die "$domain not found in $SITES_DIR"
	if ! grep -qE '^\s*tls\s+/' "$f"; then
		ok "$domain already uses Caddy's own certificate handling"
		return 0
	fi
	hdr "Handing $domain's certificate to Caddy"
	local tmp; tmp="$(mktemp)"
	grep -vE '^\s*tls\s+/' "$f" > "$tmp"
	stage_edit "$f"
	write_inplace "$f" "$tmp"
	apply
	if ! caddy_has_cert "$domain"; then
		printf '%s[info]%s waiting for certificate issuance' "$C_INF" "$C_OFF"
		local i
		for i in $(seq 1 30); do
			caddy_has_cert "$domain" && break
			printf '.'; sleep 2
		done
		printf '\n'
	fi
	if caddy_has_cert "$domain"; then
		ok "Caddy holds the certificate, expires: $(cert_expiry "$domain")"
		dim "it renews it by itself; the old certbot files were left untouched"
	else
		warn "not issued yet - usually means port 80 is not reachable for this domain"
		dim "check: journalctl -u caddy -n 40 --no-pager | grep -i acme"
	fi
}

# renew <domain> - fetch a fresh certificate now instead of waiting for Caddy's
# own renewal at ~30 days left. Caddy keeps certificates in memory across
# reloads, so this needs a restart; the current certificate is set aside first
# and put back if no new one arrives, so the site never ends up without one.
cmd_renew() {
	need_root renew
	local domain="${1:-}"
	valid_domain "$domain" || die "usage: $SELF_NAME renew <domain>"
	[[ -f "$(site_file "$domain")" ]] || die "$domain not found in $SITES_DIR"
	local kind; kind="$(cert_kind "$domain")"
	case "$kind" in
		caddy) ;;
		certbot) die "$domain uses a certbot certificate. Let Caddy manage it first: $SELF_NAME cert $domain caddy" ;;
		*) die "$domain has no certificate managed by Caddy (it is: $kind)" ;;
	esac

	local dir old bak
	dir="$(caddy_cert_dir "$domain")"
	old="$(cert_expiry "$domain")"
	bak="$(dirname "$dir")/.${domain}.renew-$(date +%s)"
	hdr "Renewing $domain"
	dim "current certificate expires: $old"

	mv "$dir" "$bak"
	info "restarting Caddy so it requests a new certificate (about a second of downtime)"
	if ! systemctl restart caddy; then
		mv "$bak" "$dir"; systemctl restart caddy || true
		die "Caddy did not restart - the previous certificate is back in place"
	fi

	printf '%s[info]%s waiting for the new certificate' "$C_INF" "$C_OFF"
	local i
	for i in $(seq 1 45); do
		caddy_has_cert "$domain" && break
		printf '.'; sleep 2
	done
	printf '\n'

	if caddy_has_cert "$domain"; then
		rm -rf -- "$bak"
		ok "new certificate issued, expires: $(cert_expiry "$domain")"
		dim "Caddy keeps renewing it by itself from here on"
	else
		warn "no new certificate arrived - restoring the previous one"
		rm -rf -- "$dir"; mv "$bak" "$dir"
		systemctl restart caddy || true
		dim "check: journalctl -u caddy -n 40 --no-pager | grep -i acme"
		die "renewal failed - the previous certificate (expires $old) is back in place"
	fi
}

# =============================================================================
#  del
# =============================================================================
cmd_del() {
	need_root del
	local domain="${1:-}"; [[ -n "$domain" ]] || die "which domain?"
	shift || true

	local cert_action="ask"
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--keep-cert)  cert_action="keep";  shift ;;
			--purge-cert) cert_action="purge"; shift ;;
			--yes|-y)     ASSUME_YES=1;        shift ;;
			*) die "unknown option: $1" ;;
		esac
	done

	local f; f="$(site_file "$domain")"
	[[ -f "$f" ]] || die "$domain not found in $SITES_DIR  (see: $SELF_NAME list)"

	local target; target=$(grep -oP 'reverse_proxy \K[^ {]+' "$f" | tail -1 || echo "?")  # last one: routes come first, the main backend last
	hdr "Removing $domain"
	dim "current target: $target"

	if [[ $ASSUME_YES -eq 0 ]]; then
		ask "Remove this proxy config?" y || { info "cancelled"; exit 0; }
	fi

	stage_edit "$f"
	rm -f "$f"
	apply
	ok "proxy config removed - the domain is no longer served"

	local kind; kind="$(cert_kind "$domain")"
	if [[ "$kind" == "none" ]]; then
		info "no stored certificate for this domain - nothing else to clean up"
		return
	fi

	hdr "Certificate"
	ok "a certificate exists for $domain  (type: $kind)"
	dim "expires: $(cert_expiry "$domain")"
	case "$kind" in
		certbot) dim "path: $LE_LIVE/$domain/" ;;
		caddy)   dim "path: $(caddy_cert_dir "$domain")/" ;;
	esac

	local do_purge=1
	case "$cert_action" in
		keep)  do_purge=1 ;;
		purge) do_purge=0 ;;
		ask)
			echo
			dim "Keeping it means a future 'add' for this domain reuses it instantly,"
			dim "with no new Let's Encrypt request and no rate-limit consumed."
			ask "Delete the certificate as well?" n && do_purge=0 || do_purge=1 ;;
	esac

	if [[ $do_purge -eq 1 ]]; then
		ok "certificate kept"
		dim "delete later with: $SELF_NAME del-cert $domain"
	else
		del_cert "$domain" "$kind"
	fi
}

del_cert() {
	local domain="$1" kind="${2:-}"
	[[ -z "$kind" ]] && kind="$(cert_kind "$domain")"
	case "$kind" in
		certbot)
			if have certbot; then
				certbot delete --cert-name "$domain" --non-interactive \
					&& ok "certbot certificate deleted" \
					|| warn "certbot could not delete it - check 'certbot certificates' for the real name"
			else
				warn "certbot not installed - remove the files manually"
			fi ;;
		caddy)
			rm -rf -- "$(caddy_cert_dir "$domain")" && ok "Caddy certificate deleted" ;;
		none) info "no certificate found" ;;
	esac
}

cmd_del_cert() {
	need_root del-cert
	local d="${1:-}"; [[ -n "$d" ]] || die "which domain?"
	local kind; kind="$(cert_kind "$d")"
	[[ "$kind" == "none" ]] && { info "no certificate for $d"; exit 0; }
	[[ -f "$(site_file "$d")" ]] && \
		warn "$d still has an active config - Caddy will just get a new certificate"
	ok "certificate found ($kind), expires: $(cert_expiry "$d")"
	ask "Really delete it?" n || { info "cancelled"; exit 0; }
	del_cert "$d" "$kind"
}

# =============================================================================
#  repair / list / doctor
# =============================================================================
# The caddy package ships a placeholder site that grabs :80. On a box where
# something else already owns that port, Caddy refuses to start at all - and
# the error names a port, not this block, so it is easy to misread.
has_stock_default_site() {
	grep -qE '^[ \t]*:80[ \t]*\{' "$CADDYFILE" 2>/dev/null \
		&& grep -q '/usr/share/caddy' "$CADDYFILE" 2>/dev/null
}

remove_stock_default_site() {
	local tmp; tmp="$(mktemp)"
	awk '
		function cntc(s, ch,   t){ t=s; return gsub(ch,"",t) }
		BEGIN { depth=0; drop=0 }
		{
			op=cntc($0,"{"); cl=cntc($0,"}")
			if (!drop && depth==0 && $0 ~ /^[ \t]*:80[ \t]*\{/) {
				drop=1; depth=op-cl
				if (depth<=0) drop=0
				next
			}
			if (drop) { depth += op-cl; if (depth<=0) drop=0; next }
			print
		}
	' "$CADDYFILE" > "$tmp"
	stage_edit "$CADDYFILE"
	write_inplace "$CADDYFILE" "$tmp"
}

cmd_repair() {
	need_root repair
	hdr "Repairing file permissions"
	fix_perms
	local grp; grp="$(caddy_group)"
	ok "$CADDYFILE -> 0644 root:$grp"
	[[ -d "$SITES_DIR" ]] && ok "$SITES_DIR -> 0755, *.caddy -> 0644 root:$grp"
	if have setfacl && [[ -d /etc/letsencrypt ]]; then
		setfacl -R -m "u:${CADDY_USER}:rX" /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null \
			&& ok "certbot ACL refreshed"
	fi

	hdr "Repairing Caddy startup"
	if has_stock_default_site; then
		local o80; o80="$(port_owner 80)"
		if [[ -n "$o80" && "$o80" != caddy ]]; then
			warn "the stock ':80' site from the caddy package is still in your Caddyfile"
			dim "but :80 is held by '$o80', so Caddy cannot start at all - and the"
			dim "error it prints names the port, not this block."
			if ask "Remove that placeholder site?" y; then
				remove_stock_default_site
				ok "removed - serving files from /usr/share/caddy was never the point"
			fi
		else
			info "the stock ':80' site is present but nothing else holds that port"
			dim "harmless for now; remove it if you want Caddy to serve only your sites"
		fi
	else
		ok "no leftover placeholder site"
	fi

	hdr "Repairing the panel service"
	if [[ -f "$UI_UNIT" && ! -f /etc/smart-caddy-panel.json ]]; then
		# The panel refuses to start without credentials, and systemd keeps
		# retrying, so the journal fills with the same failure forever.
		warn "the panel service is installed but has no credentials"
		systemctl disable --now smart-caddy-ui >/dev/null 2>&1 || true
		systemctl reset-failed smart-caddy-ui >/dev/null 2>&1 || true
		ok "stopped and disabled it, so it stops restart-looping"
		dim "set it up properly with:  $SELF_NAME panel <domain>"
	elif [[ -f "$UI_UNIT" ]] && ! systemctl is-active --quiet smart-caddy-ui; then
		systemctl reset-failed smart-caddy-ui >/dev/null 2>&1 || true
		systemctl restart smart-caddy-ui >/dev/null 2>&1 || true
		sleep 1
		systemctl is-active --quiet smart-caddy-ui \
			&& ok "panel service restarted" \
			|| warn "panel service still not starting - journalctl -u smart-caddy-ui -n 20"
	else
		ok "nothing to fix"
	fi

	hdr "Repairing the panel login"
	# Older versions fronted the panel with Caddy's basic_auth, which is what
	# produces the browser's native credential box. The panel now owns its
	# login, but an existing site file still carries the old directive -
	# 'install' never rewrites files it did not just create.
	local pf legacy=0
	shopt -s nullglob
	for pf in "$SITES_DIR"/*.caddy; do
		grep -q 'smart-caddy web panel' "$pf" || continue
		grep -qE '^\s*(basic_auth|basicauth)\s*\{' "$pf" || continue
		local ptmp; ptmp="$(mktemp)"
		awk '
			BEGIN { skip = 0 }
			/^[ \t]*(basic_auth|basicauth)[ \t]*\{/ { skip = 1; next }
			skip && /^[ \t]*\}[ \t]*$/              { skip = 0; next }
			skip { next }
			{ print }
		' "$pf" > "$ptmp"
		write_inplace "$pf" "$ptmp"
		ok "$(basename "$pf" .caddy): removed the old basic_auth block"
		dim "the panel's own sign-in page takes over - no more browser popup"
		legacy=1
	done
	shopt -u nullglob
	if [[ $legacy -eq 1 ]] && [[ ! -f /etc/smart-caddy-panel.json ]]; then
		warn "no panel credentials exist yet"
		dim "run:  $SELF_NAME panel <domain>   to set a username and password"
	fi
	[[ $legacy -eq 0 ]] && ok "nothing to fix"

	hdr "Repairing WebSocket support"
	local f fixed=0
	shopt -s nullglob
	for f in "$SITES_DIR"/*.caddy; do
		grep -q 'transport http {' "$f" || continue
		grep -q 'versions ' "$f" && continue
		local tmp; tmp="$(mktemp)"
		awk '{
			print
			if ($0 ~ /transport http \{/) {
				match($0, /^[ \t]*/)
				printf "%s\tversions 1.1\n", substr($0, RSTART, RLENGTH)
			}
		}' "$f" > "$tmp"
		write_inplace "$f" "$tmp"
		ok "$(basename "$f" .caddy): pinned HTTP/1.1 to the backend (fixes WebSocket)"
		fixed=1
	done
	shopt -u nullglob
	[[ $fixed -eq 0 ]] && ok "nothing to fix" || true
	if caddy_can_read "$CADDYFILE"; then ok "user '$CADDY_USER' can read the config"
	else warn "user '$CADDY_USER' still cannot read it - check: namei -l $CADDYFILE"; fi
	if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
		warn "the config is still invalid:"
		caddy validate --config "$CADDYFILE" 2>&1 | grep -i error | head -5 | sed 's/^/       /'
	elif systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null; then
		ok "Caddy reloaded"
	else
		warn "Caddy still will not start. Its own words:"
		journalctl -u caddy -n 15 --no-pager 2>/dev/null \
			| grep -iE 'error|already in use' | tail -3 | sed 's/^/       /' || true
		local o80 o443; o80="$(port_owner 80)"; o443="$(port_owner 443)"
		if [[ -n "$o80" || -n "$o443" ]]; then
			echo
			dim "':80' is held by '${o80:-nothing}', ':443' by '${o443:-nothing}'."
			dim "If that is Xray bound to every interface, Caddy cannot take those"
			dim "ports at all. Put your sites behind Xray instead:"
			dim "    $SELF_NAME add <domain> <port> --behind-xray"
		fi
	fi
}

cmd_list() {
	shopt -s nullglob
	local files=("$SITES_DIR"/*.caddy)
	shopt -u nullglob
	if [[ ${#files[@]} -eq 0 ]]; then
		info "no sites yet  ($SELF_NAME add <domain> <port>)"
		return
	fi
	printf '%s%-30s %-16s %-26s %-9s %s%s\n' "$C_B" "DOMAIN" "PATH" "TARGET" "CERT" "EXPIRES" "$C_OFF"
	printf '%s\n' "$(printf -- '-%.0s' {1..104})"
	local f d t k e p
	for f in "${files[@]}"; do
		d=$(basename "$f" .caddy)
		t=$(grep -oP 'reverse_proxy \K(https?://)?[^ {]+' "$f" | tail -1 || true)
		if [[ -z "$t" ]]; then
			t=$(grep -oP '^\s*root \* \K\S+' "$f" | head -1 || true)
			[[ -n "$t" ]] && t="dir:$t"
		fi
		if [[ -z "$t" ]]; then
			t=$(grep -oP '^\s*redir \K\S+' "$f" | head -1 || true)
			[[ -n "$t" ]] && t="redir:${t%\{uri\}}"
		fi
		[[ -z "$t" ]] && t="?"
		p=$(grep -oP '^\s*(@app path|# app base path:) \K\S+' "$f" | head -1 || echo "/")
		if grep -q 'tls internal' "$f"; then k="internal"; else k="$(cert_kind "$d")"; fi
		e=$(cert_expiry "$d" 2>/dev/null || echo "-")
		[[ ${#t} -gt 26 ]] && t="${t:0:23}..."
		printf '%-30s %-16s %-26s %-9s %s\n' "$d" "$p" "$t" "$k" "$e"
	done
}

cmd_doctor() {
	hdr "1  Listeners on :80 and :443"
	ss -tnlp 2>/dev/null | grep -E ':(80|443)\b' | sed 's/^/       /' || dim "(none)"

	hdr "2  Installation"
	if [[ -x "/usr/local/bin/$SELF_NAME" ]]; then
		ok "command installed at /usr/local/bin/$SELF_NAME"
	else
		warn "/usr/local/bin/$SELF_NAME is missing - this install is incomplete"
		dim "fix with:  sudo $(self_invocation) install"
	fi
	[[ -f "$UI_PY" ]] && ok "panel source at $UI_PY" \
		|| dim "no web panel installed (optional)"

	hdr "3  Caddy service"
	if systemctl is-active caddy >/dev/null 2>&1; then ok "running"
	else warn "not running"; dim "journalctl -u caddy -n 30 --no-pager"; fi
	if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then ok "config is valid"
	else
		warn "config is invalid:"
		caddy validate --config "$CADDYFILE" 2>&1 | grep -i error | head -8 | sed 's/^/       /'
	fi

	hdr "4  File permissions"
	if [[ -f "$CADDYFILE" ]]; then
		dim "$(stat -c '%A %U:%G  %n' "$CADDYFILE")"
		if caddy_can_read "$CADDYFILE"; then ok "user '$CADDY_USER' can read the config"
		else
			warn "user '$CADDY_USER' CANNOT read the config - every reload will fail"
			dim "fix: $SELF_NAME repair"
		fi
	fi

	hdr "5  bind directives"
	if [[ -z "$FRONT_IP" ]]; then
		info "FRONT_IP not set - fine on a single-IP host, dangerous otherwise"
	elif find_unbound_blocks; then
		warn "the blocks above have no 'bind' - they will collide on :80/:443"
		dim "fix: $SELF_NAME fixbind"
	else
		ok "all blocks bound to $FRONT_IP"
	fi

	hdr "6  certbot certificate access"
	if [[ -d /etc/letsencrypt/archive ]]; then
		if caddy_can_read /etc/letsencrypt/archive; then ok "user '$CADDY_USER' can read them"
		else
			warn "user '$CADDY_USER' cannot read certbot certs"
			dim "fix: $SELF_NAME repair"
		fi
	else
		dim "certbot not present on this host"
	fi

	local dfp; dfp="$(caddy_front_port)"
	if [[ -n "$dfp" ]]; then
		hdr "6a Front proxy"
		ok "Caddy sits behind a front proxy - it hands traffic to 127.0.0.1:$dfp"
		local ff fd
		shopt -s nullglob
		for ff in "$SITES_DIR"/*.caddy; do
			fd=$(basename "$ff" .caddy)
			grep -q 'behind an Xray fallback' "$ff" && continue
			if grep -qE '^\s*bind\s+' "$ff" && ! grep -qE '^\s*bind\s+127\.0\.0\.1' "$ff"; then
				warn "$fd: bound to a public address - behind a front proxy it must be 127.0.0.1"
			fi
			if dnsguard_present; then
				if dnsguard_covers "$fd"; then ok "$fd: DNSGuard hands it to Caddy"
				else warn "$fd: DNSGuard does not hand it over - add it to SNI_LOCAL_NAMES in $DNSGUARD_ENV"; fi
			fi
		done
		shopt -u nullglob
	fi

	hdr "6b Certificate renewal"
	local cf cd cany=0
	shopt -s nullglob
	for cf in "$SITES_DIR"/*.caddy; do
		cd=$(basename "$cf" .caddy)
		grep -qE '^\s*tls\s+/' "$cf" || continue
		cany=1
		if certbot_renew_ok "$cd"; then
			ok "$cd: certbot can renew it"
		else
			warn "$cd: certbot cannot renew it here - expires $(cert_expiry "$cd" 2>/dev/null || echo '?')"
			dim "fix: $SELF_NAME cert $cd caddy"
		fi
	done
	shopt -u nullglob
	[[ $cany -eq 0 ]] && ok "every HTTPS site gets its certificate from Caddy, which renews it itself"

	hdr "7  WebSocket support"
	local wsbad=0 f
	shopt -s nullglob
	for f in "$SITES_DIR"/*.caddy; do
		grep -q 'transport http {' "$f" || continue
		if ! grep -q 'versions ' "$f"; then
			warn "$(basename "$f" .caddy): TLS backend without 'versions 1.1'"
			dim "Caddy may speak HTTP/2 to it, which cannot carry a WebSocket"
			dim "upgrade - live traffic / speed panels stay blank"
			wsbad=1
		fi
	done
	shopt -u nullglob
	if [[ $wsbad -eq 1 ]]; then dim "fix: $SELF_NAME repair"
	else ok "no TLS backends missing an HTTP version pin"; fi

	hdr "8  Xray fallbacks"
	shopt -s nullglob
	local xf xdests xport xany=0
	xdests="$(xray_fallback_dests)"
	for xf in "$SITES_DIR"/*.caddy; do
		grep -q 'behind an Xray fallback' "$xf" || continue
		xany=1
		xport=$(grep -oP 'http://[^:]+:\K[0-9]+' "$xf" | head -1 || true)
		if [[ -z "$xdests" ]]; then
			info "$(basename "$xf" .caddy): expects an Xray fallback to :$xport"
			dim "could not read an Xray config to confirm it"
		elif grep -qx "$xport" <<<"$xdests"; then
			ok "$(basename "$xf" .caddy): Xray falls back to :$xport"
		else
			warn "$(basename "$xf" .caddy): no Xray fallback points at :$xport"
			dim "the domain will look dead until you add that row in x-ui"
		fi
	done
	shopt -u nullglob
	[[ $xany -eq 0 ]] && dim "(no sites are behind an Xray fallback)"

	hdr "9  Sites"
	cmd_list

	hdr "10  DNS"
	shopt -s nullglob
	local f d r
	for f in "$SITES_DIR"/*.caddy; do
		d=$(basename "$f" .caddy)
		r=$(dig +short "$d" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || true
		if [[ -z "$r" ]];                                 then warn "$d -> no A record"
		elif [[ -n "$FRONT_IP" && "$r" != "$FRONT_IP" ]]; then warn "$d -> $r  (expected $FRONT_IP)"
		else ok "$d -> $r"; fi
	done
	shopt -u nullglob
	echo

	hdr "11  Recent Caddy errors"
	journalctl -u caddy --since "1 hour ago" --no-pager 2>/dev/null \
		| grep -iE '"level":"error"|denied|already in use' | tail -5 | sed 's/^/       /' \
		|| dim "(none in the last hour)"
	echo
}


# =============================================================================
#  import - adopt sites that already live in the Caddyfile
#
#  A box that ran Caddy before smart-caddy keeps its sites in the Caddyfile
#  itself, where neither 'list' nor the panel can see them. 'import' moves each
#  domain block, byte for byte, into its own file under sites.d - the served
#  config is identical, it just becomes manageable. Blocks with no domain name
#  (:80, localhost, a bare IP) and snippets stay where they are.
# =============================================================================

# caddyfile_scan <tsv|json> - top-level blocks of the Caddyfile.
# A brace only opens or closes a block when it stands alone as a token, so
# placeholders such as {host} or {$DOMAIN} never upset the depth count.
caddyfile_scan() {
	python3 - "$1" "$CADDYFILE" "$SITES_DIR" <<'CADDYFILE_SCAN_PY'
import json, os, re, sys

mode, path, sites_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    src = open(path).read()
except OSError:
    print("[]" if mode == "json" else "")
    sys.exit(0)
lines = src.split("\n")
RE_DOM = re.compile(r"^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$")

def standalone(i):
    before = src[i - 1] if i > 0 else "\n"
    after = src[i + 1] if i + 1 < len(src) else "\n"
    return before in " \t\n" and after in " \t\r\n"

blocks, depth, line, i, n = [], 0, 1, 0, len(src)
quote, head, head_line, start = None, "", None, None
while i < n:
    c = src[i]
    if quote:
        if c == "\\" and quote == '"':
            if i + 1 < n and src[i + 1] == "\n":
                line += 1
            i += 2
            continue
        if c == "\n":
            line += 1
        if c == quote:
            quote = None
        if depth == 0:
            head += c
        i += 1
        continue
    if c == "#" and (i == 0 or src[i - 1] in " \t\n"):
        while i < n and src[i] != "\n":
            i += 1
        continue
    if c in "\"`":
        quote = c
        if depth == 0:
            head += c
        i += 1
        continue
    if c == "\n":
        if depth == 0 and head.strip() and not head.rstrip().endswith(","):
            # a top-level line with no block: import, a lone directive, ...
            blocks.append({"kind": "statement", "start": head_line, "end": line,
                           "header": head.strip()})
            head, head_line = "", None
        line += 1
        i += 1
        continue
    if c == "{" and standalone(i):
        if depth == 0:
            start = head_line or line
            hdr = head.strip()
            head, head_line = "", None
            cur = {"start": start, "header": hdr}
        depth += 1
        i += 1
        continue
    if c == "}" and standalone(i) and depth > 0:
        depth -= 1
        if depth == 0:
            cur["end"] = line
            rest = src[i + 1:].split("\n", 1)[0]
            cur["clean"] = not rest.strip() or rest.strip().startswith("#")
            blocks.append(cur)
        i += 1
        continue
    if depth == 0:
        if not head.strip() and c not in " \t\r":
            head_line = line
        head += c
    i += 1

out, prev_end = [], 0
for b in blocks:
    floor, prev_end = prev_end, b["end"]
    if "kind" in b:
        continue
    h = b["header"]
    if h == "":
        b["kind"] = "global"
    elif h.startswith("("):
        b["kind"] = "snippet"
    elif h.startswith("&("):
        b["kind"] = "route"
    else:
        b["kind"] = "site"
    b["domain"], b["importable"], b["reason"], b["duplicate"] = "", False, "", False
    if b["kind"] == "site":
        hosts = []
        for a in re.split(r"[,\s]+", h):
            if not a:
                continue
            a = re.sub(r"^[a-z]+://", "", a).split("/", 1)[0]
            a = re.sub(r":\d+$", "", a)
            hosts.append(a.lower())
        doms = [x for x in hosts if RE_DOM.match(x)]
        if not doms:
            b["reason"] = "no domain name (port, IP, localhost or wildcard)"
        else:
            b["domain"] = doms[0]
            if not b.get("clean"):
                b["reason"] = "shares a line with other config"
            else:
                if os.path.exists(os.path.join(sites_dir, doms[0] + ".caddy")):
                    # defined twice: only 'import --replace <domain>' moves it
                    b["reason"] = "already managed in sites.d"
                    b["duplicate"] = True
                else:
                    b["importable"] = True
                # comments sitting right on top of the block travel with it
                while b["start"] - 1 > floor and lines[b["start"] - 2].lstrip().startswith("#") \
                        and not lines[b["start"] - 2].lstrip().startswith("# ---"):
                    b["start"] -= 1
    b["text"] = "\n".join(lines[b["start"] - 1:b["end"]])
    b.pop("clean", None)
    out.append(b)

if mode == "json":
    print(json.dumps(out))
else:
    for b in out:
        print("\t".join([b["kind"], str(b["start"]), str(b["end"]),
                         b["domain"] or "-", "1" if b["importable"] else "0",
                         b["header"].replace("\t", " ") or "{ global }",
                         b["reason"] or "-", "1" if b["duplicate"] else "0"]))
CADDYFILE_SCAN_PY
}

cmd_import() {
	need_root import
	local mode="move" all=0 want=() d replace=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--list)   mode="list"; shift ;;
			--replace) replace=1;  shift ;;
			--json)   mode="json"; shift ;;
			--all)    all=1;       shift ;;
			--yes|-y) ASSUME_YES=1; shift ;;
			-*) die "unknown option: $1" ;;
			*)  want+=("${1,,}"); shift ;;
		esac
	done
	[[ -f "$CADDYFILE" ]] || die "$CADDYFILE not found"
	have python3 || die "python3 is required to read the Caddyfile"

	if [[ "$mode" == json ]]; then caddyfile_scan json; return; fi

	local rows=() kind s e dom imp header reason dup
	mapfile -t rows < <(caddyfile_scan tsv)

	if [[ "$mode" == list ]]; then
		hdr "Blocks in $CADDYFILE"
		local any=0
		for r in "${rows[@]}"; do
			IFS=$'\t' read -r kind s e dom imp header reason dup <<<"$r"
			[[ "$kind" == site ]] || continue
			any=1
			if [[ "$imp" == 1 ]]; then ok "$header  (lines $s-$e) - can be imported"
			elif [[ "$dup" == 1 ]]; then
				warn "$header  (lines $s-$e) - also defined in $(site_file "$dom")"
				dim "keep this one with:  $SELF_NAME import $dom --replace"
			else dim "$header  (lines $s-$e) - stays: $reason"; fi
		done
		[[ $any -eq 1 ]] || info "no site blocks in the Caddyfile itself"
		return 0
	fi

	# pick what to move
	local pick=() found
	for r in "${rows[@]}"; do
		IFS=$'\t' read -r kind s e dom imp header reason dup <<<"$r"
		[[ "$kind" == site ]] || continue
		# A block that duplicates a managed site only moves when asked for by
		# name with --replace: it overwrites the managed copy.
		if [[ "$imp" != 1 ]]; then
			[[ $replace -eq 1 && "$dup" == 1 && " ${want[*]:-} " == *" $dom "* ]] || continue
		fi
		if [[ ${#want[@]} -gt 0 ]]; then
			found=0
			for d in "${want[@]}"; do [[ "$d" == "$dom" ]] && found=1; done
			[[ $found -eq 1 ]] || continue
		fi
		pick+=("$s|$e|$dom|$header")
	done
	for d in ${want[@]+"${want[@]}"}; do
		printf '%s\n' "${pick[@]}" | grep -q "|$d|" \
			|| die "$d is not an importable block in $CADDYFILE  (see: $SELF_NAME import --list)"
	done
	if [[ ${#pick[@]} -eq 0 ]]; then
		info "nothing to import - every domain block is already managed"
		return 0
	fi

	hdr "Importing from $CADDYFILE"
	local p
	for p in "${pick[@]}"; do dim "${p##*|}"; done
	echo
	dim "Each block moves unchanged into $SITES_DIR/<domain>.caddy, so what"
	dim "Caddy serves stays the same - it just shows up in 'list' and the panel."
	if [[ ${#want[@]} -eq 0 && $all -eq 0 ]]; then
		ask "Import these ${#pick[@]} site(s)?" y || { info "cancelled"; return 0; }
	fi

	grep -qF "$SITES_DIR" "$CADDYFILE" || die "import line missing. Run: $SELF_NAME install"
	mkdir -p "$SITES_DIR"

	local bak="${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"
	cp -p "$CADDYFILE" "$bak"

	local f ranges="" written=" "
	for p in "${pick[@]}"; do
		IFS='|' read -r s e dom header <<<"$p"
		f="$(site_file "$dom")"
		# A domain often has more than one block - "x.com {" plus an
		# "http://x.com {" redirect. They all belong in the same file, so
		# every block after the first is appended, never written over it.
		if [[ "$written" == *" $dom "* ]]; then
			{ echo; sed -n "${s},${e}p" "$CADDYFILE"; } >> "$f"
			ranges+="$s-$e "
			continue
		fi
		written+="$dom "
		if [[ -f "$f" ]]; then
			warn "replacing the managed copy of $dom with the Caddyfile block"
			stage_edit "$f"
		else
			stage_new "$f"
		fi
		{
			echo "# imported by $SELF_NAME from $CADDYFILE on $(date +%F)"
			sed -n "${s},${e}p" "$CADDYFILE"
		} > "$f"
		chown "root:$(caddy_group)" "$f" 2>/dev/null || true
		chmod 0644 "$f"
		ranges+="$s-$e "
	done

	local tmp; tmp="$(mktemp)"
	awk -v r="$ranges" '
		BEGIN { n = split(r, a, " "); for (k = 1; k <= n; k++) { split(a[k], b, "-"); S[k] = b[1]; E[k] = b[2] } }
		{ for (k = 1; k <= n; k++) if (NR >= S[k] && NR <= E[k]) next; print }
	' "$CADDYFILE" | cat -s > "$tmp"
	stage_edit "$CADDYFILE"
	write_inplace "$CADDYFILE" "$tmp"

	hdr "Applying"
	apply
	for dom in $written; do
		ok "$dom -> $(site_file "$dom")"
	done
	dim "backup of the old Caddyfile: $bak"
}

# put <domain> <file> - replace a site's config with hand-written text.
# Validated and reloaded like everything else, rolled back if Caddy objects.
cmd_put() {
	need_root put
	local domain="${1:-}" src="${2:-}"
	valid_domain "$domain" || die "invalid domain: $domain"
	[[ -f "$src" ]] || die "no such file: $src"
	grep -q '[^[:space:]]' "$src" || die "refusing to write an empty config"
	grep -qF "$SITES_DIR" "$CADDYFILE" || die "import line missing. Run: $SELF_NAME install"

	local f; f="$(site_file "$domain")"
	local tmp; tmp="$(mktemp)"
	{
		# Mark hand-edited files, so the panel knows the form cannot express them.
		grep -qE '^# (imported by|custom config)' "$src" \
			|| echo "# custom config - edited by hand in $SELF_NAME"
		cat "$src"
	} > "$tmp"

	hdr "Saving $domain"
	if [[ -f "$f" ]]; then
		stage_edit "$f"
		write_inplace "$f" "$tmp"
	else
		mkdir -p "$SITES_DIR"
		install -m 0644 "$tmp" "$f"; rm -f "$tmp"
		chown "root:$(caddy_group)" "$f" 2>/dev/null || true
		stage_new "$f"
	fi
	apply
	ok "$domain saved -> $f"
}

# =============================================================================
#  Activity log
#
#  Every command that changes something leaves one JSON line in ACTIVITY_LOG:
#  when, who, from where (cli or panel), what it printed, and a unified diff
#  of every file it touched. The panel shows it as its change history.
# =============================================================================
ACTIVITY_LOG="/var/log/smart-caddy/activity.jsonl"
ACTIVITY_DIFF=""

# Record what this apply changed. Must run before clear_stage drops the backups.
activity_diff() {
	[[ -n "$ACTIVITY_DIFF" ]] || return 0
	local f e p b
	for e in "${_rb_old[@]:-}"; do
		[[ -z "$e" ]] && continue
		p="${e%%|*}"; b="${e##*|}"
		if [[ -e "$p" ]]; then diff -u --label "a$p" --label "b$p" "$b" "$p"
		else                   diff -u --label "a$p" --label "/dev/null" "$b" /dev/null; fi
	done >> "$ACTIVITY_DIFF" 2>/dev/null || true
	for f in "${_rb_new[@]:-}"; do
		[[ -n "$f" && -e "$f" ]] || continue
		diff -u --label "/dev/null" --label "b$f" /dev/null "$f"
	done >> "$ACTIVITY_DIFF" 2>/dev/null || true
}

activity_begin() {
	[[ $EUID -eq 0 ]] && have python3 && have tee || return 0
	ACTIVITY_CMD="$*"
	ACTIVITY_OUT="$(mktemp)"; ACTIVITY_DIFF="$(mktemp)"
	# Copy everything printed into a file as well, so the log keeps the output.
	exec 3>&1 4>&2
	exec > >(tee -a "$ACTIVITY_OUT") 2>&1
	ACTIVITY_TEE=$!
	trap 'activity_end $?' EXIT
}

activity_end() {
	local rc="$1"
	trap - EXIT
	exec 1>&3 2>&4 3>&- 4>&-
	wait "$ACTIVITY_TEE" 2>/dev/null || sleep 0.3
	mkdir -p "$(dirname "$ACTIVITY_LOG")"
	ACT_RC="$rc" ACT_CMD="$ACTIVITY_CMD" ACT_SRC="${SMART_CADDY_SOURCE:-cli}" \
	ACT_WHO="${SMART_CADDY_ACTOR:-${SUDO_USER:-$(id -un)}}" \
	python3 - "$ACTIVITY_OUT" "$ACTIVITY_DIFF" "$ACTIVITY_LOG" <<'ACTIVITY_PY' 2>/dev/null || true
import json, os, re, sys, time
out = re.sub(r"\x1b\[[0-9;]*m", "", open(sys.argv[1], errors="replace").read())
diff = open(sys.argv[2], errors="replace").read()
ent = {"ts": int(time.time()), "src": os.environ["ACT_SRC"], "who": os.environ["ACT_WHO"],
       "cmd": os.environ["ACT_CMD"], "ok": os.environ["ACT_RC"] == "0",
       "out": out[-20000:], "diff": diff[:60000]}
path = sys.argv[3]
try:
    lines = open(path).read().splitlines()[-499:]
except OSError:
    lines = []
lines.append(json.dumps(ent))
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
ACTIVITY_PY
	rm -f "$ACTIVITY_OUT" "$ACTIVITY_DIFF"
	exit "$rc"
}

# --- embedded panel source ---------------------------------------------------
# The web panel's Python, carried inside this script so a single downloaded
# file is enough. A standalone smart_caddy_ui.py, if present, wins over this.
ui_payload() {
cat <<'SMART_CADDY_UI_PY_PAYLOAD'
#!/usr/bin/env python3
"""
smart-caddy web panel

A tiny stdlib-only HTTP server that drives the smart-caddy CLI.
Binds to localhost only; Caddy puts it on a domain and handles auth and TLS.

    smart-caddy panel caddy.example.com

Reads site definitions straight from /etc/caddy/sites.d/, and shells out to
smart-caddy for anything that changes state, so there is exactly one code path
that writes config.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

HOST = os.environ.get("SMART_CADDY_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("SMART_CADDY_UI_PORT", "9797"))
SITES_DIR = os.environ.get("SMART_CADDY_SITES", "/etc/caddy/sites.d")
CLI = shutil.which("smart-caddy") or "/usr/local/bin/smart-caddy"
CONF = "/etc/smart-caddy.conf"
AUTH_FILE = os.environ.get("SMART_CADDY_PANEL_AUTH", "/etc/smart-caddy-panel.json")
ACTIVITY_LOG = os.environ.get("SMART_CADDY_ACTIVITY", "/var/log/smart-caddy/activity.jsonl")
VERSION = "1.5.0"

COOKIE = "sc_session"
SESSION_HOURS = 12
PBKDF2_ROUNDS = 240_000

# --- strict input validation: every value below reaches a subprocess argv ----
RE_DOMAIN = re.compile(r"^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$")
# A backend can be a port, a host:port, a URL, a directory to serve, another
# site to proxy, or a redirect. Mirrors classify_target() in the shell script.
RE_PORT     = re.compile(r"^[0-9]{1,5}$")
RE_HOSTPORT = re.compile(r"^[a-zA-Z0-9.\-]{1,253}:[0-9]{1,5}$")
RE_URL      = re.compile(r"^https?://[a-zA-Z0-9.\-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~\-/]*)?$")
RE_DIR      = re.compile(r"^/[A-Za-z0-9._\-/]{0,255}$")
RE_REDIR    = re.compile(r"^redirect:https?://[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~\-/]*)?$")
RE_PATH   = re.compile(r"^/[A-Za-z0-9._~\-/]{0,200}$")
RE_HOST_H = re.compile(r"^[A-Za-z0-9.\-]{1,253}$")
RE_ROUTE  = re.compile(r"^/[A-Za-z0-9._~\-/*]{0,200}$")


def front_ip():
    try:
        with open(CONF) as fh:
            m = re.search(r'^FRONT_IP="([^"]*)"', fh.read(), re.M)
            return m.group(1) if m else ""
    except OSError:
        return ""


def cert_expiry(path):
    try:
        out = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-enddate"],
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0:
            return out.stdout.strip().split("=", 1)[1]
    except Exception:
        pass
    return None


# Directives the form knows how to write back. A site that uses anything else
# is edited as raw text, because the form would silently drop the rest.
FORM_TOP = {"bind", "encode", "tls", "reverse_proxy", "handle", "root",
            "file_server", "redir", "@app", "respond"}
FORM_PROXY = {"header_up", "transport", "tls_insecure_skip_verify", "versions",
              "flush_interval"}
STD_HEADERS = {"X-Real-IP", "X-Forwarded-Proto", "X-Forwarded-Port", "X-Forwarded-For"}


def parse_site(text):
    """Turn a site file back into the fields of the add/edit form.

    Line based, which is how smart-caddy and nearly every hand-written
    Caddyfile lay a site out. form_ok is False when something is present that
    the form cannot express."""
    info = {"target": "", "routes": [], "paths": [], "strict_path": False,
            "host_header": "", "insecure": False, "nobuffer": False,
            "behind_xray": "behind an Xray fallback" in text, "listen_port": "",
            "no_tls": False, "form_ok": True, "unknown": []}
    m = re.search(r"^\s*(?:@app path|# app base path:)\s+(.+)$", text, re.M)
    if m:
        for tok in m.group(1).split():
            if not tok.endswith("/*") and tok not in info["paths"]:
                info["paths"].append(tok)
    info["strict_path"] = "@app path" in text

    # the plain "http://name { bind ...; redir https://{host}{uri} }" block
    # written next to a site behind a front proxy belongs to that site
    text = re.sub(r"\n?(#[^\n]*\n)?http://\S+\s*\{\s*(bind\s+\S+\s*)?"
                  r"redir\s+https://\{host\}\{uri\}(\s+permanent)?\s*\}\s*", "\n", text)
    stack = []          # open blocks, as (directive, argument)
    handle = None       # path of the handle block we are in ("" = catch-all)
    blocks = http_blocks = 0

    def body_target(words):
        d = words[0]
        if d == "reverse_proxy" and len(words) > 1 and words[1] != "{":
            return words[1]
        if d == "root" and len(words) > 2:
            return words[2]
        if d == "redir" and len(words) > 1:
            return "redirect:" + re.sub(r"\{uri\}$", "", words[1])
        return None

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        words = line.split()
        if line == "}":
            if stack:
                d, _ = stack.pop()
                if d == "handle":
                    handle = None
            continue
        opens = words[-1] == "{"
        depth = len(stack)
        if depth == 0:
            addr = words[0]
            blocks += 1
            if addr.startswith("http://"):
                http_blocks += 1
                mp = re.match(r"http://[^:/]+:(\d+)", addr)
                if mp:
                    info["listen_port"] = mp.group(1)
            if opens:
                stack.append(("site", addr))
            continue
        d = words[0]
        parent = stack[-1][0]
        if parent in ("site", "handle"):
            if d not in FORM_TOP:
                info["unknown"].append(d)
            elif d == "handle":
                arg = words[1] if len(words) > 2 else ""
                if arg.startswith("/") or arg in ("", "@app"):
                    handle = "" if arg in ("", "@app") else arg
                else:
                    info["unknown"].append("handle " + arg)
            else:
                t = body_target(words)
                if t:
                    if handle:
                        info["routes"].append({"path": handle, "target": t})
                    elif not info["target"]:
                        info["target"] = t
        elif parent == "reverse_proxy":
            if d not in FORM_PROXY:
                info["unknown"].append(d)
            elif d == "header_up" and len(words) > 2:
                if words[1] == "Host":
                    if words[2] != "{host}" and not handle:
                        info["host_header"] = words[2]
                elif words[1] not in STD_HEADERS:
                    info["unknown"].append("header_up " + words[1])
            elif d == "flush_interval":
                info["nobuffer"] = True
        elif parent == "transport":
            if d == "tls_insecure_skip_verify":
                info["insecure"] = True
            elif d not in FORM_PROXY:
                info["unknown"].append(d)
        if opens:
            stack.append((d, words[1] if len(words) > 2 else ""))
    # plain HTTP only when every block is http:// (an "https + http redirect"
    # pair is an HTTPS site); and the form writes one block, so a file with
    # several would lose the others if saved from it
    info["no_tls"] = blocks > 0 and http_blocks == blocks and not info["behind_xray"]
    if blocks > 1:
        info["unknown"].append("several site blocks")
    # A remote site gets its own name as Host automatically, so that one is
    # implied by the target rather than chosen; only a forced value is shown.
    th = re.sub(r"^[a-z]+://", "", info["target"]).split("/")[0].rsplit(":", 1)[0]
    if info["host_header"] and info["host_header"] == th and RE_DOMAIN.match(th):
        info["host_header"] = ""
    info["target"] = info["target"] or "?"
    info["form_ok"] = not info["unknown"] and info["target"] != "?"
    return info


def read_sites():
    sites = []
    try:
        names = sorted(n for n in os.listdir(SITES_DIR) if n.endswith(".caddy"))
    except OSError:
        return sites

    for name in names:
        domain = name[:-6]
        try:
            with open(os.path.join(SITES_DIR, name)) as fh:
                text = fh.read()
        except OSError:
            continue

        info = parse_site(text)
        if info["host_header"] == domain:      # same as {host}: nothing forced
            info["host_header"] = ""

        cert, expires = "auto", None
        m = re.search(r"^\s*tls\s+(/\S+)\s", text, re.M)
        if "tls internal" in text:
            cert = "internal"
        elif info["behind_xray"]:
            cert = "xray"
        elif info["no_tls"]:
            cert = "none"
        elif m:
            cert = "certbot"
            expires = cert_expiry(m.group(1))
        else:
            guess = f"/var/lib/caddy/.local/share/caddy/certificates/" \
                    f"acme-v02.api.letsencrypt.org-directory/{domain}/{domain}.crt"
            if os.path.exists(guess):
                cert = "caddy"
                expires = cert_expiry(guess)
            else:
                cert = "pending"

        info.update({
            "domain": domain,
            "cert": cert,
            "expires": expires,
            "imported": bool(re.search(r"^# (imported by|custom config)", text, re.M)),
        })
        sites.append(info)
    return sites


def read_log(limit=150):
    try:
        with open(ACTIVITY_LOG) as fh:
            lines = fh.read().splitlines()[-limit:]
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def port_owner(port):
    """Which process holds this TCP port, if any. Empty when it is free."""
    try:
        out = subprocess.run(["ss", "-tnlpH"], capture_output=True, text=True, timeout=5)
    except Exception:
        return ""
    suffix = ":" + str(port)
    mine = front_ip()
    for line in out.stdout.splitlines():
        cols = line.split()
        if len(cols) < 4 or not cols[3].endswith(suffix):
            continue
        # On a multi-address box Caddy binds one IP; a service on another
        # address is no conflict and must not trigger the Xray hint.
        host = cols[3][:-len(suffix)].split("%")[0]
        if mine and host not in (mine, "0.0.0.0", "*", "[::]"):
            continue
        m = re.search(r'users:\(\("([^"]+)"', line)
        return m.group(1) if m else "?"
    return ""


def caddyfile_blocks():
    """Site blocks still living in the Caddyfile itself, via 'import --json'."""
    try:
        p = subprocess.run([CLI, "import", "--json"], capture_output=True,
                           text=True, timeout=20)
        return [b for b in json.loads(p.stdout or "[]") if b.get("kind") == "site"]
    except Exception:
        return []


def site_config(domain):
    try:
        with open(os.path.join(SITES_DIR, domain + ".caddy")) as fh:
            return fh.read()
    except OSError:
        return None


def front_proxy():
    """Caddy's https_port when something else owns :443 and hands traffic
    over (an SNI proxy such as DNSGuard). Mirrors caddy_front_port()."""
    try:
        with open("/etc/caddy/Caddyfile") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != "{":
        return None
    for line in lines[1:]:
        if line.startswith("}"):
            break
        m = re.match(r"\s*https_port\s+(\d+)", line)
        if m and m.group(1) != "443":
            name = "DNSGuard" if os.path.exists("/opt/dnsguard/.env") else port_owner(443)
            return {"port": m.group(1), "name": name or "?"}
    return None


def caddy_running():
    try:
        return subprocess.run(["systemctl", "is-active", "--quiet", "caddy"],
                              timeout=5).returncode == 0
    except Exception:
        return False


def run_cli(args, timeout=120, actor=None):
    """Run the smart-caddy CLI. argv list only - never a shell string.
    actor is recorded in the activity log as who made the change."""
    env = dict(os.environ, SMART_CADDY_SOURCE="panel")
    if actor:
        env["SMART_CADDY_ACTOR"] = actor
    try:
        p = subprocess.run([CLI] + args, capture_output=True, text=True,
                           timeout=timeout, env=env)
        clean = re.compile(r"\x1b\[[0-9;]*m")
        return {
            "ok": p.returncode == 0,
            "code": p.returncode,
            "out": clean.sub("", p.stdout + p.stderr).strip(),
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "code": -1, "out": "timed out"}
    except Exception as exc:
        return {"ok": False, "code": -1, "out": str(exc)}



# =============================================================================
#  Authentication
#
#  The panel owns its login instead of leaning on Caddy's basic_auth, so people
#  get a real form rather than the browser's native credential box. Passwords
#  are stored as PBKDF2-HMAC-SHA256; sessions are HMAC-signed cookies, which
#  keeps you logged in across a service restart without any server-side state.
# =============================================================================

def load_auth():
    try:
        with open(AUTH_FILE) as fh:
            return json.load(fh)
    except Exception:
        return None


def hash_password(password, salt=None, rounds=PBKDF2_ROUNDS):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds)
    return salt.hex(), dk.hex(), rounds


def init_auth(user, password, path=AUTH_FILE):
    """Write the credentials file. Called by 'smart-caddy panel'."""
    salt, digest, rounds = hash_password(password)
    data = {
        "user": user,
        "salt": salt,
        "hash": digest,
        "rounds": rounds,
        "secret": secrets.token_hex(32),
    }
    old = os.umask(0o077)                 # 0600 from the moment it exists
    try:
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    return True


def check_password(user, password):
    auth = load_auth()
    if not auth:
        return False
    try:
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(),
                                 bytes.fromhex(auth["salt"]), auth["rounds"])
    except Exception:
        return False
    # compare_digest on both fields so a wrong username costs the same as a
    # wrong password and cannot be distinguished by timing
    ok_user = hmac.compare_digest(str(user), str(auth.get("user", "")))
    ok_pass = hmac.compare_digest(dk.hex(), auth.get("hash", ""))
    return ok_user and ok_pass


def make_token():
    auth = load_auth()
    if not auth:
        return None
    exp = str(int(time.time()) + SESSION_HOURS * 3600)
    sig = hmac.new(auth["secret"].encode(), exp.encode(), hashlib.sha256).hexdigest()
    return f"{exp}.{sig}"


def valid_token(token):
    auth = load_auth()
    if not auth or not token or "." not in token:
        return False
    exp, _, sig = token.partition(".")
    expect = hmac.new(auth["secret"].encode(), exp.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expect):
        return False
    try:
        return int(exp) > time.time()
    except ValueError:
        return False


# Crude but effective: slow down guessing without needing any storage.
_fails = {}

def throttle_check(ip):
    n, until = _fails.get(ip, (0, 0))
    return max(0, int(until - time.time()))

def throttle_fail(ip):
    n, _ = _fails.get(ip, (0, 0))
    n += 1
    delay = 0 if n < 5 else min(300, 2 ** (n - 4))
    _fails[ip] = (n, time.time() + delay)

def throttle_reset(ip):
    _fails.pop(ip, None)


class Handler(BaseHTTPRequestHandler):
    server_version = "smart-caddy-ui/" + VERSION

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- helpers ------------------------------------------------------------
    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def client_ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def is_https(self):
        return (self.headers.get("X-Forwarded-Proto", "").lower() == "https")

    def authed(self):
        raw = self.headers.get("Cookie", "")
        if not raw:
            return False
        try:
            return valid_token(SimpleCookie(raw).get(COOKIE).value)
        except Exception:
            return False

    def set_session(self, token, clear=False):
        bits = [f"{COOKIE}={'' if clear else token}", "Path=/", "HttpOnly",
                "SameSite=Strict"]
        bits.append("Max-Age=0" if clear else f"Max-Age={SESSION_HOURS * 3600}")
        if self.is_https():
            bits.append("Secure")
        self.send_header("Set-Cookie", "; ".join(bits))

    def same_origin(self):
        """Reject cross-site POSTs. SameSite=Strict already blocks the cookie,
        this is the belt to that pair of braces."""
        origin = self.headers.get("Origin")
        if not origin:
            return True                      # curl and friends send none
        host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host", "")
        return urlparse(origin).netloc == host

    def read_json(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n <= 0 or n > 262144:
                return {}
            return json.loads(self.rfile.read(n).decode())
        except Exception:
            return {}

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            return self.send_html(PAGE if self.authed() else LOGIN_PAGE)
        if not self.authed():
            return self.send_json({"error": "unauthorized"}, 401)
        if path == "/api/state":
            return self.send_json({
                "version": VERSION,
                "front_ip": front_ip(),
                "caddy_running": caddy_running(),
                "ports": {"80": port_owner(80), "443": port_owner(443)},
                "front": front_proxy(),
                "sites": read_sites(),
                "caddyfile": caddyfile_blocks(),
            })
        if path == "/api/config":
            domain = (parse_qs(urlparse(self.path).query).get("domain") or [""])[0].lower()
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            text = site_config(domain)
            if text is None:
                return self.send_json({"ok": False, "out": "no such site"}, 404)
            return self.send_json({"ok": True, "domain": domain, "config": text})
        if path == "/api/doctor":
            return self.send_json(run_cli(["doctor"]))
        if path == "/api/log":
            return self.send_json({"ok": True, "log": read_log()})
        self.send_json({"error": "not found"}, 404)

    def cli(self, args):
        auth = load_auth() or {}
        return run_cli(args, actor=f"{auth.get('user', 'panel')}@{self.client_ip()}")

    def do_add(self, data, replace=False):
        domain = str(data.get("domain", "")).strip().lower()
        target = str(data.get("target", "")).strip()
        if not RE_DOMAIN.match(domain):
            return self.send_json({"ok": False, "out": "invalid domain"}, 400)
        if not (RE_PORT.match(target) or RE_HOSTPORT.match(target)
                or RE_URL.match(target) or RE_DIR.match(target)
                or RE_REDIR.match(target) or RE_DOMAIN.match(target)):
            return self.send_json(
                {"ok": False,
                 "out": "backend must be a port, host:port, https://host:port, "
                        "a directory path, another domain, or redirect:<url>"}, 400)

        args = ["add", domain, target, "--yes", "--no-dns-check"]
        if replace:
            args.append("--replace")

        for r in (data.get("routes") or []):
            rp = str((r or {}).get("path", "")).strip()
            rt = str((r or {}).get("target", "")).strip()
            if not rp and not rt:
                continue
            if not rp.startswith("/"):
                rp = "/" + rp
            if not RE_ROUTE.match(rp):
                return self.send_json({"ok": False, "out": f"invalid route path: {rp}"}, 400)
            if not (RE_PORT.match(rt) or RE_HOSTPORT.match(rt) or RE_URL.match(rt)
                    or RE_DIR.match(rt) or RE_REDIR.match(rt) or RE_DOMAIN.match(rt)):
                return self.send_json({"ok": False, "out": f"invalid route backend: {rt}"}, 400)
            args += ["--route", f"{rp}={rt}"]

        for p in (data.get("paths") or []):
            p = str(p).strip()
            if not p:
                continue
            if not p.startswith("/"):
                p = "/" + p
            if not RE_PATH.match(p):
                return self.send_json({"ok": False, "out": f"invalid path: {p}"}, 400)
            args += ["--path", p]

        hh = str(data.get("host_header", "")).strip()
        if hh:
            if not RE_HOST_H.match(hh):
                return self.send_json({"ok": False, "out": "invalid host header"}, 400)
            args += ["--host-header", hh]

        if data.get("behind_xray"): args.append("--behind-xray")
        if data.get("panel"):       args.append("--panel")
        if data.get("insecure"):    args.append("--insecure")
        if data.get("nobuffer"):    args.append("--no-buffer")
        cert = str(data.get("cert", ""))
        if cert == "caddy":         args.append("--auto-cert")
        elif cert == "certbot":     args.append("--certbot")
        elif cert == "internal":    args.append("--self-signed")
        if data.get("self_signed"): args.append("--self-signed")
        if data.get("no_tls"):      args.append("--no-tls")

        return self.send_json(self.cli(args))

    def do_POST(self):
        path = urlparse(self.path).path
        data = self.read_json()

        if not self.same_origin():
            return self.send_json({"ok": False, "out": "cross-origin request"}, 403)

        if path == "/api/login":
            ip = self.client_ip()
            wait = throttle_check(ip)
            if wait:
                return self.send_json(
                    {"ok": False, "out": f"too many attempts - wait {wait}s"}, 429)
            if check_password(str(data.get("user", "")), str(data.get("password", ""))):
                throttle_reset(ip)
                token = make_token()
                body = json.dumps({"ok": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.set_session(token)
                self.end_headers()
                return self.wfile.write(body)
            throttle_fail(ip)
            time.sleep(0.4)
            return self.send_json({"ok": False, "out": "wrong username or password"}, 401)

        if path == "/api/logout":
            body = json.dumps({"ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.set_session("", clear=True)
            self.end_headers()
            return self.wfile.write(body)

        if not self.authed():
            return self.send_json({"ok": False, "out": "unauthorized"}, 401)

        if path == "/api/add":
            return self.do_add(data)

        if path == "/api/edit":
            # Replaced in place: the old file is the rollback, so a rejected
            # edit leaves the site exactly as it was and it never goes down.
            return self.do_add(data, replace=True)

        if path == "/api/del":
            domain = str(data.get("domain", "")).strip().lower()
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            args = ["del", domain, "--yes",
                    "--purge-cert" if data.get("purge_cert") else "--keep-cert"]
            return self.send_json(self.cli(args))

        if path == "/api/import":
            doms = [str(d).strip().lower() for d in (data.get("domains") or [])]
            if not doms or not all(RE_DOMAIN.match(d) for d in doms):
                return self.send_json({"ok": False, "out": "invalid domain list"}, 400)
            if data.get("replace"):
                # overwrites a managed site, so only ever one, named explicitly
                if len(doms) != 1:
                    return self.send_json({"ok": False, "out": "replace takes one domain"}, 400)
                return self.send_json(self.cli(["import", doms[0], "--replace", "--yes"]))
            return self.send_json(self.cli(["import"] + doms + ["--yes"]))

        if path == "/api/put":
            domain = str(data.get("domain", "")).strip().lower()
            text = str(data.get("config", ""))
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            if not text.strip() or len(text) > 60000:
                return self.send_json({"ok": False, "out": "config is empty or too large"}, 400)
            fd, tmp = tempfile.mkstemp(prefix="smart-caddy-put.", suffix=".caddy")
            try:
                with os.fdopen(fd, "w") as fh:
                    fh.write(text if text.endswith("\n") else text + "\n")
                return self.send_json(self.cli(["put", domain, tmp]))
            finally:
                os.unlink(tmp)

        if path == "/api/renew":
            # Restarts Caddy - and this very request travels through Caddy -
            # so run it detached; the outcome lands in the activity log.
            domain = str(data.get("domain", "")).strip().lower()
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            auth = load_auth() or {}
            env = dict(os.environ, SMART_CADDY_SOURCE="panel",
                       SMART_CADDY_ACTOR=f"{auth.get('user', 'panel')}@{self.client_ip()}")
            try:
                proc = subprocess.Popen([CLI, "renew", domain], env=env,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
                threading.Thread(target=proc.wait, daemon=True).start()
            except Exception as exc:
                return self.send_json({"ok": False, "out": str(exc)})
            return self.send_json({"ok": True, "started": True,
                                   "out": f"renewing {domain} - the result appears in the activity log"})

        if path == "/api/cert":
            domain = str(data.get("domain", "")).strip().lower()
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            return self.send_json(self.cli(["cert", domain, "caddy"]))

        if path == "/api/fixbind":
            return self.send_json(self.cli(["fixbind"]))
        if path == "/api/repair":
            return self.send_json(self.cli(["repair"]))

        self.send_json({"error": "not found"}, 404)


LOGIN_PAGE = r"""<!doctype html>
<html lang="en" dir="ltr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Smart Caddy</title>
<style>
:root{
  --bg:#f6f7f9; --card:#fff; --ink:#16181d; --mut:#6b7280; --line:#e4e6eb;
  --acc:#2f6f4f; --acc-ink:#fff; --bad:#b3261e;
}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --bg:#0f1114; --card:#171a1f; --ink:#e8eaed; --mut:#9aa0a6; --line:#2a2e35;
  --acc:#4e9b74; --acc-ink:#07120c; --bad:#f2b8b5;
}}
*{box-sizing:border-box}
:root{color-scheme:light dark}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px 16px;
  background:var(--bg);color:var(--ink);
  font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
html[lang=fa] body{font-family:Vazirmatn,"Segoe UI",Tahoma,sans-serif}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
  padding:30px 28px;width:100%;max-width:370px;
  box-shadow:0 1px 2px rgba(0,0,0,.05),0 12px 32px rgba(0,0,0,.07)}
.mark{display:flex;align-items:center;gap:9px;margin-bottom:22px}
.mark svg{flex:none}
.mark .grow{flex:1}
h1{font-size:17px;margin:0;letter-spacing:-.01em}
.host{font-size:12.5px;color:var(--mut);margin-top:1px;direction:ltr;text-align:start}
label{display:block;font-size:12px;color:var(--mut);margin:0 0 5px}
input{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:8px;
  background:var(--bg);color:var(--ink);font:inherit;font-size:14.5px;margin-bottom:15px}
input:focus{outline:2px solid color-mix(in srgb,var(--acc) 45%,transparent);
  outline-offset:1px;border-color:var(--acc)}
button{width:100%;font:inherit;font-size:14.5px;font-weight:600;padding:11px;
  border-radius:8px;border:1px solid var(--acc);background:var(--acc);
  color:var(--acc-ink);cursor:pointer}
button:hover{filter:brightness(1.08)}
button:disabled{opacity:.55;cursor:default}
.lang{display:inline-flex;border:1px solid var(--line);border-radius:7px;overflow:hidden}
.lang button{width:auto;border:0;border-radius:0;background:transparent;color:var(--mut);
  font-size:12px;font-weight:500;padding:4px 9px}
.lang button.on{background:var(--acc);color:var(--acc-ink)}
.err{font-size:13px;color:var(--bad);margin:0 0 14px;min-height:1.2em}
.foot{font-size:11.5px;color:var(--mut);margin:18px 0 0;text-align:center}
</style>
</head>
<body>
<form class="card" id="f" autocomplete="on">
  <div class="mark">
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <rect x="2.5" y="4" width="19" height="6" rx="2" stroke="var(--acc)" stroke-width="1.6"/>
      <rect x="2.5" y="14" width="19" height="6" rx="2" stroke="var(--acc)" stroke-width="1.6"/>
      <circle cx="6.5" cy="7" r="1.1" fill="var(--acc)"/>
      <circle cx="6.5" cy="17" r="1.1" fill="var(--acc)"/>
    </svg>
    <div class="grow">
      <h1>Smart Caddy</h1>
      <div class="host" id="host"></div>
    </div>
    <div class="lang"><button type="button" data-lang="fa">فا</button><button type="button" data-lang="en">EN</button></div>
  </div>

  <label for="u" data-t="user">Username</label>
  <input id="u" name="username" autocomplete="username" dir="ltr" autofocus required>

  <label for="p" data-t="pass">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" dir="ltr" required>

  <p class="err" id="err"></p>
  <button type="submit" id="b" data-t="signin">Sign in</button>
  <p class="foot" data-t="foot">Reverse proxy management</p>
</form>

<script>
const I18N = {
  en: {user:'Username', pass:'Password', signin:'Sign in', signing:'Signing in…',
       foot:'Reverse proxy management', wrong:'Wrong username or password',
       unreach:'Could not reach the server', failed:'Sign in failed'},
  fa: {user:'نام کاربری', pass:'رمز عبور', signin:'ورود', signing:'در حال ورود…',
       foot:'مدیریت ریورس پروکسی', wrong:'نام کاربری یا رمز عبور اشتباه است',
       unreach:'ارتباط با سرور برقرار نشد', failed:'ورود ناموفق بود'}
};
let LANG = 'en';
try { LANG = localStorage.getItem('sc-lang') || ''; } catch(_) {}
if (!I18N[LANG]) LANG = (navigator.language || '').startsWith('fa') ? 'fa' : 'en';
const t = k => I18N[LANG][k] || I18N.en[k] || k;
function applyLang(){
  document.documentElement.lang = LANG;
  document.documentElement.dir = LANG === 'fa' ? 'rtl' : 'ltr';
  document.querySelectorAll('[data-t]').forEach(e => e.textContent = t(e.dataset.t));
  document.querySelectorAll('[data-lang]').forEach(b => b.classList.toggle('on', b.dataset.lang === LANG));
}
document.querySelectorAll('[data-lang]').forEach(b => b.onclick = () => {
  LANG = b.dataset.lang;
  try { localStorage.setItem('sc-lang', LANG); } catch(_) {}
  applyLang();
});
applyLang();

document.getElementById('host').textContent = location.host;
const f = document.getElementById('f'), b = document.getElementById('b'),
      err = document.getElementById('err');
f.onsubmit = async e => {
  e.preventDefault();
  err.textContent = '';
  b.disabled = true; b.textContent = t('signing');
  try{
    const r = await fetch('/api/login', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({user: u.value, password: p.value})
    });
    const d = await r.json();
    if (d.ok) { location.reload(); return; }
    err.textContent = r.status === 401 ? t('wrong') : (d.out || t('failed'));
  } catch(_) {
    err.textContent = t('unreach');
  }
  b.disabled = false; b.textContent = t('signin');
  p.value = ''; p.focus();
};
</script>
</body>
</html>
"""

PAGE = r"""<!doctype html>
<html lang="en" dir="ltr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Smart Caddy</title>
<style>
:root{
  --bg:#f6f7f9; --card:#fff; --ink:#16181d; --mut:#6b7280; --line:#e4e6eb;
  --acc:#2f6f4f; --acc-ink:#fff; --bad:#b3261e; --warn:#8a5a00; --ok:#1f7a4d;
  --add:#1f7a4d; --del:#b3261e; --radius:10px;
}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --bg:#0f1114; --card:#171a1f; --ink:#e8eaed; --mut:#9aa0a6; --line:#2a2e35;
  --acc:#4e9b74; --acc-ink:#07120c; --bad:#f2b8b5; --warn:#e3b341; --ok:#6cc48f;
  --add:#6cc48f; --del:#f2a19c;
}}
*{box-sizing:border-box}
:root{color-scheme:light dark}
@media (prefers-color-scheme:light){:root{color-scheme:light}}
body{margin:0;background:var(--bg);color:var(--ink);
  font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
html[lang=fa] body{font-family:Vazirmatn,"Segoe UI",Tahoma,sans-serif}
.wrap{max-width:1680px;margin:0 auto;padding:24px 28px 64px}
header{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:6px}
header .grow{flex:1}
h1{font-size:20px;margin:0;letter-spacing:-.01em}
.sub{color:var(--mut);font-size:13px}
.ltr{direction:ltr;unicode-bidi:isolate}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  padding:18px;margin-top:16px;min-width:0}
h2{font-size:14px;margin:0 0 14px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut)}
html[lang=fa] h2{letter-spacing:0}
.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:3px 9px;
  border-radius:99px;border:1px solid var(--line);color:var(--mut)}
.dot{width:7px;height:7px;border-radius:99px;background:var(--mut);flex:none}
.dot.up{background:var(--ok)} .dot.down{background:var(--bad)}
.lang{display:inline-flex;border:1px solid var(--line);border-radius:7px;overflow:hidden}
.lang button{border:0;border-radius:0;background:transparent;color:var(--mut);font-size:12px;padding:4px 10px}
.lang button.on{background:var(--acc);color:var(--acc-ink)}

.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin-top:16px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px}
.tile b{display:block;font-size:24px;line-height:1.2;font-variant-numeric:tabular-nums}
.tile span{font-size:12px;color:var(--mut);text-transform:uppercase;letter-spacing:.06em}
html[lang=fa] .tile span{letter-spacing:0}
.tile.warn b{color:var(--warn)} .tile.ok b{color:var(--ok)}
.h2row{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.h2row h2{margin:0}
.h2row .grow{flex:1}

table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:start;font-weight:600;font-size:11px;text-transform:uppercase;
  letter-spacing:.06em;color:var(--mut);padding:0 0 8px;padding-inline-end:10px;border-bottom:1px solid var(--line)}
td{padding:11px 0;padding-inline-end:10px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
#sites{overflow-x:auto}
code{font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;direction:ltr;unicode-bidi:isolate;
  background:color-mix(in srgb,var(--ink) 7%,transparent);padding:1px 5px;border-radius:4px}
.dom{font-weight:600}
.dom a{color:inherit;text-decoration:none;border-bottom:1px solid var(--line)}
.dom a:hover{border-color:var(--acc)}
.rt{font-size:12px;color:var(--mut);margin-top:4px;white-space:nowrap}
.tag{font-size:11px;padding:2px 7px;border-radius:5px;border:1px solid var(--line);
  color:var(--mut);margin:0 0 3px;margin-inline-end:4px;display:inline-block}
.tag.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 40%,transparent)}
.tag.warn{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 40%,transparent)}
.tag.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 40%,transparent)}
.acts{text-align:end;white-space:nowrap}

form{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:18px 22px}
.full{grid-column:1/-1}
label{display:block;font-size:12.5px;color:var(--mut);margin-bottom:5px}
label .opt{opacity:.65}
input[type=text]{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:7px;
  background:var(--bg);color:var(--ink);font:inherit;font-size:14px;direction:ltr;text-align:left}
input[type=text]:focus{outline:2px solid color-mix(in srgb,var(--acc) 45%,transparent);
  outline-offset:1px;border-color:var(--acc)}
input[readonly]{opacity:.7}
select{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:7px;
  background:var(--bg);color:var(--ink);font:inherit;font-size:14px}
select:disabled{opacity:.5}
.hint{font-size:12px;color:var(--mut);margin-top:6px;line-height:1.6}
.hint code{font-size:11.5px}
.route{display:flex;gap:8px;align-items:center;margin-bottom:8px;max-width:760px}
.route input{flex:1;min-width:0}
.route .arr{color:var(--mut);flex:none}
html[dir=rtl] .route .arr{transform:scaleX(-1)}
.note{grid-column:1/-1;font-size:12.5px;line-height:1.6;padding:10px 12px;border-radius:8px;
  border:1px solid color-mix(in srgb,var(--warn) 45%,transparent);
  background:color-mix(in srgb,var(--warn) 8%,transparent)}
.checks{grid-column:1/-1;display:grid;gap:14px 22px;grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr))}
.checks label{display:flex;align-items:flex-start;gap:9px;font-size:13.5px;color:var(--ink);margin:0;cursor:pointer}
.checks input{margin:4px 0 0;flex:none}
.checks .hint{margin:2px 0 0}
.row{grid-column:1/-1;display:flex;gap:10px;align-items:center;flex-wrap:wrap}

button{font:inherit;font-size:14px;padding:9px 16px;border-radius:7px;border:1px solid var(--line);
  background:var(--card);color:var(--ink);cursor:pointer}
button:hover{border-color:var(--acc)}
button.primary{background:var(--acc);color:var(--acc-ink);border-color:var(--acc);font-weight:600}
button.primary:hover{filter:brightness(1.08)}
button.link{border:0;background:0;color:var(--mut);padding:4px 6px;font-size:13px}
button.link:hover{color:var(--bad)}
button.link.go:hover{color:var(--acc)}
button:disabled{opacity:.5;cursor:default}

pre{background:color-mix(in srgb,var(--ink) 6%,transparent);padding:14px 16px;
  border:1px solid var(--line);border-radius:8px;direction:ltr;text-align:left;
  font:12.5px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;
  word-break:normal;overflow-wrap:anywhere;max-height:420px;overflow:auto;margin:0}
pre .ln-ok{color:var(--ok)}   pre .ln-warn{color:var(--warn)}
pre .ln-bad{color:var(--bad)} pre .ln-dim{color:var(--mut)}
pre .ln-hdr{color:var(--ink);font-weight:600}
pre .d-add{color:var(--add)} pre .d-del{color:var(--del)}
pre .d-hunk{color:var(--mut)} pre .d-file{color:var(--ink);font-weight:600}
.empty{color:var(--mut);font-size:14px;padding:14px 0}

details.blk{border-top:1px solid var(--line);padding:10px 0}
details.blk:first-of-type{border-top:0}
details.blk summary{display:flex;align-items:center;gap:10px;cursor:pointer;list-style:none;flex-wrap:wrap}
details.blk summary::-webkit-details-marker{display:none}
details.blk summary .grow{flex:1;min-width:0;overflow-wrap:anywhere}
details.blk pre{margin-top:10px;max-height:340px}
details.blk h3{font-size:11.5px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:12px 0 6px}
.log{max-height:640px;overflow:auto;padding-inline-end:8px}
.when{font-size:12.5px;color:var(--mut);white-space:nowrap;font-variant-numeric:tabular-nums}
.cmd{font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;direction:ltr;unicode-bidi:isolate}

dialog{border:1px solid var(--line);border-radius:12px;background:var(--card);color:var(--ink);
  padding:20px;width:min(980px,94vw);box-shadow:0 20px 60px rgba(0,0,0,.35)}
dialog::backdrop{background:rgba(0,0,0,.55)}
textarea{width:100%;min-height:52vh;resize:vertical;padding:14px;border:1px solid var(--line);
  border-radius:8px;background:var(--bg);color:var(--ink);tab-size:4;direction:ltr;text-align:left;
  font:13px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace}
textarea:focus{outline:2px solid color-mix(in srgb,var(--acc) 45%,transparent);border-color:var(--acc)}
#form-card.editing{border-color:var(--acc);box-shadow:0 0 0 1px var(--acc)}
.toast{position:fixed;left:50%;transform:translateX(-50%);bottom:24px;z-index:9;
  background:var(--card);border:1px solid var(--line);border-inline-start:3px solid var(--acc);
  border-radius:8px;padding:11px 16px;font-size:14px;max-width:min(560px,92vw);
  box-shadow:0 8px 28px rgba(0,0,0,.16)}
.toast.bad{border-inline-start-color:var(--bad)}
@media(max-width:640px){
  .wrap{padding:16px 16px 56px}
  th:nth-child(3),td:nth-child(3){display:none}
  .acts{white-space:normal}
  .acts button{display:block;margin-inline-start:auto}
}
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1>Smart Caddy</h1>
  <span class="pill"><span class="dot" id="dot"></span><span id="status" data-t="checking">checking</span></span>
  <span class="sub ltr" id="meta"></span>
  <span class="grow"></span>
  <div class="lang"><button type="button" data-lang="fa">فارسی</button><button type="button" data-lang="en">EN</button></div>
  <button class="link" id="btn-out" data-t="sign_out">Sign out</button>
</header>

<div class="tiles">
  <div class="tile"><span data-t="tile_sites">Sites</span><b id="t-sites">&ndash;</b></div>
  <div class="tile ok"><span data-t="tile_certs">Certificates</span><b id="t-certs">&ndash;</b></div>
  <div class="tile" id="t-exp-tile"><span data-t="tile_exp">Expiring &lt; 21 days</span><b id="t-exp">&ndash;</b></div>
  <div class="tile" id="t-cf-tile"><span data-t="tile_cf">Unmanaged in Caddyfile</span><b id="t-cf">&ndash;</b></div>
</div>

<div class="card" id="ports-note" hidden>
  <h2 data-t="heads_up">Heads up</h2>
  <p id="ports-text" style="margin:0;font-size:14px;line-height:1.6"></p>
</div>

<div class="card">
  <h2 data-t="sites">Sites</h2>
  <div id="sites"><div class="empty" data-t="loading">Loading…</div></div>
</div>

<div class="card" id="cf-card" hidden>
  <div class="h2row">
    <h2 data-t="cf_title">Found in Caddyfile</h2><span class="grow"></span>
    <button type="button" class="primary" id="btn-import-all" data-t="import_all" hidden>Import all</button>
  </div>
  <div class="hint" style="margin:-6px 0 10px" data-t="cf_hint"></div>
  <div id="cf-list"></div>
</div>

<div class="card" id="form-card">
  <h2 id="form-title" data-t="form_add">Add a site</h2>
  <form id="add" autocomplete="off">
    <div class="note" id="edit-note" hidden></div>

    <div>
      <label for="f-domain" data-t="f_domain">Domain</label>
      <input type="text" id="f-domain" placeholder="panel.example.com" required>
      <div class="hint" data-t="f_domain_h"></div>
    </div>
    <div>
      <label for="f-target" data-t="f_target">Main backend</label>
      <input type="text" id="f-target" placeholder="8088" required>
      <div class="hint" data-th="f_target_h"></div>
    </div>

    <div class="full">
      <label><span data-t="f_routes">Routes</span> <span class="opt" data-t="optional">(optional)</span></label>
      <div id="routes"></div>
      <button type="button" class="link go" id="btn-route" data-t="add_route">+ Add route</button>
      <div class="hint" data-th="f_routes_h"></div>
    </div>

    <div>
      <label for="f-path"><span data-t="f_path">Path prefix</span> <span class="opt" data-t="optional">(optional)</span></label>
      <input type="text" id="f-path" placeholder="/5wSobQvUFuNy4zBUcc">
      <div class="hint" data-t="f_path_h"></div>
    </div>
    <div>
      <label for="f-host"><span data-t="f_host">Host header</span> <span class="opt" data-t="optional">(optional)</span></label>
      <input type="text" id="f-host" placeholder="127.0.0.1">
      <div class="hint" data-th="f_host_h"></div>
    </div>

    <div>
      <label for="f-cert" data-t="f_cert">SSL certificate</label>
      <select id="f-cert">
        <option value="caddy" data-t="cert_caddy">Caddy</option>
        <option value="certbot" data-t="cert_certbot">certbot</option>
        <option value="internal" data-t="cert_internal">Self-signed</option>
      </select>
      <div class="hint" data-t="f_cert_h"></div>
    </div>

    <div class="checks">
      <label><input type="checkbox" id="f-panel">
        <span><span data-t="c_panel">Admin panel</span><div class="hint" data-t="c_panel_h"></div></span></label>
      <label><input type="checkbox" id="f-notls">
        <span><span data-t="c_notls">Plain HTTP</span><div class="hint" data-t="c_notls_h"></div></span></label>
      <label><input type="checkbox" id="f-xray">
        <span><span data-t="c_xray">Behind Xray</span><div class="hint" data-t="c_xray_h"></div></span></label>
    </div>

    <div class="row">
      <button type="submit" class="primary" id="btn-add" data-t="btn_add">Add site</button>
      <button type="button" class="link" id="btn-cancel" data-t="cancel" hidden>Cancel</button>
    </div>
  </form>
</div>

<div class="card" id="out-card">
  <div class="h2row"><h2 id="out-title" data-t="diag_title">Diagnostics &amp; output</h2><span class="grow"></span>
    <button type="button" class="link go" id="btn-doctor" data-t="btn_doctor">Run diagnostics</button></div>
  <div class="hint" id="out-idle" data-t="diag_idle"></div>
  <pre id="out" hidden></pre>
</div>

<div class="card">
  <div class="h2row">
    <h2 data-t="log_title">Activity log</h2><span class="grow"></span>
    <button type="button" class="link go" id="btn-log" data-t="refresh">Refresh</button>
  </div>
  <div class="hint" style="margin:-6px 0 10px" data-t="log_hint"></div>
  <div class="log" id="log"><div class="empty" data-t="loading">Loading…</div></div>
</div>

</div>

<dialog id="raw">
  <div class="h2row">
    <h2 id="raw-title" class="ltr">Config</h2><span class="grow"></span>
    <button type="button" class="link" id="raw-close" data-t="close">Close</button>
  </div>
  <textarea id="raw-text" spellcheck="false" autocomplete="off"></textarea>
  <div class="hint" style="margin:8px 0 14px" data-th="raw_hint"></div>
  <div style="display:flex;gap:10px;align-items:center">
    <button type="button" class="primary" id="raw-save" data-t="raw_save">Save &amp; reload</button>
    <button type="button" class="link" id="raw-cancel" data-t="cancel">Cancel</button>
  </div>
</dialog>

<script>
const $ = s => document.querySelector(s);

// ---------------------------------------------------------------- language
const I18N = {
en: {
  checking:'checking', caddy_running:'Caddy running', caddy_down:'Caddy down', sign_out:'Sign out',
  loading:'Loading…', close:'Close', cancel:'Cancel', refresh:'Refresh', optional:'(optional)',
  tile_sites:'Sites', tile_certs:'Certificates', tile_exp:'Expiring < 21 days', tile_cf:'Unmanaged in Caddyfile',
  heads_up:'Heads up',
  front_text:'{0} owns ports 80 and 443 on this server and hands the domains it knows to Caddy on {1}. Add sites normally, without Behind Xray: they are served on loopback, and each new domain is added to the list of {0} for you (it restarts for a few seconds).',
  ports_text:'This machine already has {0} on the address Caddy uses. Caddy cannot share a port, so an ordinary site will fail with <code>address already in use</code>. Add sites with <b>Behind Xray</b> ticked: Caddy listens on a loopback port and you add one fallback row in x-ui.',
  sites:'Sites', th_domain:'Domain', th_backend:'Backend', th_notes:'Notes',
  no_sites:'No sites yet. Add one with the form.', no_sites_cf:'No sites yet. Add one with the form, or import the ones found in the Caddyfile.',
  edit:'Edit', config:'Config', remove:'Remove',
  tag_pending:'no cert yet', tag_internal:'self-signed', tag_xray:'cert on Xray', tag_none:'plain HTTP',
  tag_path:'path', tag_behind_xray:'behind Xray', tag_unbuffered:'unbuffered', tag_insecure:'insecure upstream',
  tag_custom:'custom config', tag_imported:'imported', routes_n:'{0} routes',
  cf_title:'Found in Caddyfile', import_all:'Import all', import:'Import', lines:'lines',
  cf_hint:'Sites written straight into the Caddyfile. Importing moves each block unchanged into its own file, so it is served exactly as before and becomes editable here.',
  'no domain name (port, IP, localhost or wildcard)':'no domain name (port, IP, localhost or wildcard)',
  'already managed in sites.d':'already managed here', 'shares a line with other config':'shares a line with other config',
  confirm_import:'Import {0}?\n\nThe block moves unchanged out of the Caddyfile into its own file. A backup of the Caddyfile is kept, and nothing changes if Caddy rejects it.',
  imported_n:'Imported {0} site(s)', import_failed:'Import failed - see the output',
  output:'Output',
  form_add:'Add a site', form_edit:'Edit {0}',
  f_domain:'Domain',
  f_domain_h:'The address visitors type. Its A record must point at this server, with any CDN or cloud proxy (the orange cloud) turned off, or no certificate can be issued.',
  f_target:'Main backend',
  f_target_h:'Where requests go when no route below matches: <code>8088</code> a port on this server · <code>https://127.0.0.1:27389</code> an app that speaks HTTPS itself · <code>/var/www/site</code> serve files from a folder · <code>example.com</code> proxy another website · <code>redirect:https://x.com</code> send visitors elsewhere.',
  f_routes:'Routes', add_route:'+ Add route', route_path:'/dns-query/*', route_target:'8000',
  f_routes_h:'Send particular paths to a different backend. A DNS server, for example: <code>/dns-query/*</code> → <code>8000</code> for DNS-over-HTTPS and <code>/panel*</code> → <code>8000</code> for its admin page, while everything else goes to the main backend. <code>*</code> matches anything after it; routes are checked before the main backend.',
  f_path:'Path prefix',
  f_path_h:'Only for apps that live under a secret path, like x-ui. It is recorded and used for the link in the list; nothing is blocked, because the app already answers 404 outside its path.',
  f_host:'Host header',
  f_host_h:'Overrides the Host header sent to the backend. Leave it empty for normal apps. Routers and modems usually need <code>127.0.0.1</code>. Do not use it on admin panels: it breaks their live-stats websocket.',
  c_panel:'Admin panel',
  c_panel_h:'For x-ui, 3x-ui, Marzban, Hiddify and similar. Accepts the backend\'s self-signed certificate and turns off response buffering, so live traffic and speed numbers update.',
  c_notls:'Plain HTTP',
  c_notls_h:'Serve over http:// only, with no certificate. For testing, or when something in front already handles HTTPS.',
  c_xray:'Behind Xray',
  c_xray_h:'Use when Xray owns port 443 on this server. Caddy listens on a private loopback port and Xray forwards this domain to it; you add one fallback row in x-ui (shown after saving). The certificate then lives on the Xray inbound.',
  f_cert:'SSL certificate',
  cert_caddy:'Caddy - issues and renews it automatically (recommended)',
  cert_certbot:'Existing certbot certificate', cert_internal:'Self-signed (testing only)',
  f_cert_h:'Who provides the HTTPS certificate. Caddy gets one from Let\'s Encrypt the moment the site is saved and renews it on its own, with nothing else to run. Use certbot only if certbot can still renew it here - it needs port 80 free or nginx, which no longer holds once Caddy runs the server. Self-signed makes browsers warn.',
  cert_by_caddy:'SSL by Caddy', to_caddy:'Let Caddy manage SSL',
  confirm_to_caddy:'Hand {0}\'s certificate over to Caddy?\n\nCaddy gets a fresh certificate from Let\'s Encrypt and renews it by itself from now on. The site stays up meanwhile; the old certbot files are left untouched.',
  to_caddy_done:'Caddy now manages SSL for {0}',
  days_left:'{0} days left', renew:'Renew',
  confirm_renew:'Get a fresh certificate for {0} now?\n\nCaddy already renews it by itself about 30 days before it expires, so this is only needed if something is wrong. Caddy restarts for about a second; if no new certificate arrives the current one is put back.\n\nLet\'s Encrypt allows only 5 renewals of the same name per week.',
  renew_started:'Renewing {0}… Caddy restarts for a moment. The result shows up in the activity log within a minute.',
  btn_add:'Add site', btn_save:'Save changes', btn_doctor:'Run diagnostics', working:'Working…',
  note_imported:'This site was imported or edited by hand. Saving from the form rewrites it in the standard layout and drops its comments. The previous version stays in the activity log, and <b>Config</b> always edits the raw text.',
  toast_live:'{0} is live', toast_updated:'{0} updated', toast_failed:'Failed - see the output',
  confirm_remove:'Stop serving {0}?\n\nIts certificate is kept, so adding it back later is instant.',
  removed:'{0} removed', remove_failed:'Could not remove {0}',
  raw_hint:'Saved through <code>smart-caddy put</code>: Caddy validates it first and everything rolls back if it is rejected, so a typo cannot take the server down.',
  raw_save:'Save & reload', raw_saved:'{0} saved', raw_rejected:'Rejected - nothing changed, see the output', raw_read_fail:'Could not read the config',
  log_title:'Activity log', log_hint:'Every change, from the panel or the command line: who made it, what it printed, and exactly which lines of config changed.',
  log_empty:'No changes recorded yet.', log_changes:'Changes', log_output:'Output', log_nodiff:'No config files changed.',
  src_panel:'panel', src_cli:'terminal', failed:'failed',
  diag:'Diagnostics', running:'Running…', no_output:'(no output)',
  diag_title:'Diagnostics & output', diag_idle:'Run diagnostics to check the whole setup: ports, permissions, certificates, DNS and Xray fallbacks. The output of every action you take also shows up here.',
  dup_tag:'defined twice', dup_keep:'Keep this one',
  confirm_dup:'{0} is defined both here in the Caddyfile and in Smart Caddy.\n\nKeep the Caddyfile block: it replaces the managed copy and leaves the Caddyfile. The replaced copy stays in the activity log, and nothing changes if Caddy rejects it.',
  act_add:'Added', act_add_r:'Edited', act_del:'Removed', act_import:'Imported', act_put:'Config saved',
  act_fixbind:'Fixed bind', act_repair:'Repaired', act_uninstall:'Uninstalled', act_del_cert:'Certificate deleted',
  act_renew:'Certificate renewed', act_cert:'SSL handed to Caddy'
},
fa: {
  checking:'در حال بررسی', caddy_running:'Caddy فعال است', caddy_down:'Caddy خاموش است', sign_out:'خروج',
  loading:'در حال بارگذاری…', close:'بستن', cancel:'انصراف', refresh:'به‌روزرسانی', optional:'(اختیاری)',
  tile_sites:'سایت‌ها', tile_certs:'گواهی‌ها', tile_exp:'انقضا کمتر از ۲۱ روز', tile_cf:'مدیریت‌نشده در Caddyfile',
  heads_up:'توجه',
  front_text:'روی این سرور {0} پورت‌های 80 و 443 را دارد و دامنه‌هایی را که می‌شناسد روی {1} به Caddy تحویل می‌دهد. سایت‌ها را معمولی و بدون تیک «پشت Xray» اضافه کنید: روی loopback سرو می‌شوند و هر دامنهٔ جدید خودکار به فهرست {0} اضافه می‌شود ({0} چند ثانیه ری‌استارت می‌شود).',
  ports_text:'روی آدرسی که Caddy استفاده می‌کند، {0} از قبل پورت را گرفته است. Caddy نمی‌تواند پورت را با برنامهٔ دیگری شریک شود، پس سایت معمولی با خطای <code>address already in use</code> بالا نمی‌آید. سایت‌ها را با تیک <b>پشت Xray</b> اضافه کنید: Caddy روی یک پورت داخلی گوش می‌دهد و شما یک ردیف fallback در x-ui اضافه می‌کنید.',
  sites:'سایت‌ها', th_domain:'دامنه', th_backend:'مقصد', th_notes:'توضیحات',
  no_sites:'هنوز سایتی نیست. از فرم یکی اضافه کنید.', no_sites_cf:'هنوز سایتی نیست. از فرم یکی اضافه کنید یا سایت‌های پیداشده در Caddyfile را وارد کنید.',
  edit:'ویرایش', config:'کانفیگ', remove:'حذف',
  tag_pending:'هنوز گواهی ندارد', tag_internal:'خودامضا', tag_xray:'گواهی روی Xray', tag_none:'HTTP ساده',
  tag_path:'مسیر', tag_behind_xray:'پشت Xray', tag_unbuffered:'بدون بافر', tag_insecure:'بک‌اند بدون بررسی گواهی',
  tag_custom:'کانفیگ سفارشی', tag_imported:'واردشده', routes_n:'{0} مسیر',
  cf_title:'پیداشده در Caddyfile', import_all:'وارد کردن همه', import:'وارد کردن', lines:'خطوط',
  cf_hint:'سایت‌هایی که مستقیم داخل Caddyfile نوشته شده‌اند. وارد کردن، هر بلاک را بدون هیچ تغییری به فایل جداگانهٔ خودش منتقل می‌کند؛ سایت دقیقاً مثل قبل سرویس می‌دهد و از اینجا قابل ویرایش می‌شود.',
  'no domain name (port, IP, localhost or wildcard)':'نام دامنه ندارد (پورت، IP، localhost یا wildcard)',
  'already managed in sites.d':'از قبل اینجا مدیریت می‌شود', 'shares a line with other config':'با کانفیگ دیگری در یک خط است',
  confirm_import:'{0} وارد شود؟\n\nبلاک بدون تغییر از Caddyfile به فایل جداگانه منتقل می‌شود. از Caddyfile نسخهٔ پشتیبان گرفته می‌شود و اگر Caddy قبول نکند هیچ چیز تغییر نمی‌کند.',
  imported_n:'{0} سایت وارد شد', import_failed:'وارد کردن ناموفق بود - خروجی را ببینید',
  output:'خروجی',
  form_add:'افزودن سایت', form_edit:'ویرایش {0}',
  f_domain:'دامنه',
  f_domain_h:'آدرسی که کاربر در مرورگر می‌زند. رکورد A آن باید به IP همین سرور اشاره کند و CDN یا پروکسی ابری (ابر نارنجی) خاموش باشد؛ وگرنه گواهی SSL صادر نمی‌شود.',
  f_target:'مقصد اصلی',
  f_target_h:'درخواست‌هایی که با هیچ‌کدام از مسیرهای پایین جور نیستند به اینجا می‌روند: <code>8088</code> یک پورت روی همین سرور · <code>https://127.0.0.1:27389</code> برنامه‌ای که خودش HTTPS دارد · <code>/var/www/site</code> نمایش فایل‌های یک پوشه · <code>example.com</code> پروکسی به یک سایت دیگر · <code>redirect:https://x.com</code> فرستادن بازدیدکننده به جای دیگر.',
  f_routes:'مسیرها', add_route:'+ افزودن مسیر', route_path:'/dns-query/*', route_target:'8000',
  f_routes_h:'مسیرهای مشخص را به مقصد دیگری بفرستید. مثلاً برای سرور DNS: <code>/dns-query/*</code> ← <code>8000</code> برای DNS-over-HTTPS و <code>/panel*</code> ← <code>8000</code> برای صفحهٔ مدیریتش؛ بقیهٔ درخواست‌ها به مقصد اصلی می‌روند. <code>*</code> یعنی هر چیزی بعد از آن. مسیرها قبل از مقصد اصلی بررسی می‌شوند.',
  f_path:'پیشوند مسیر',
  f_path_h:'فقط برای برنامه‌هایی که زیر یک مسیر مخفی هستند، مثل x-ui. ثبت می‌شود و برای لینک داخل لیست استفاده می‌شود؛ چیزی مسدود نمی‌شود، چون خود برنامه بیرون از مسیرش 404 می‌دهد.',
  f_host:'هدر Host',
  f_host_h:'هدر Host ارسالی به بک‌اند را عوض می‌کند. برای برنامه‌های معمولی خالی بگذارید. روترها و مودم‌ها معمولاً <code>127.0.0.1</code> می‌خواهند. روی پنل‌های مدیریتی استفاده نکنید؛ وب‌سوکت آمار زنده‌شان را خراب می‌کند.',
  c_panel:'پنل مدیریتی',
  c_panel_h:'برای x-ui، 3x-ui، مرزبان، هیدیفای و مشابه. گواهی خودامضای بک‌اند را قبول می‌کند و بافر پاسخ را خاموش می‌کند تا آمار زندهٔ ترافیک و سرعت به‌روز شود.',
  c_notls:'HTTP ساده',
  c_notls_h:'فقط با http:// و بدون هیچ گواهی سرویس می‌دهد. برای تست، یا وقتی چیز دیگری جلوتر HTTPS را انجام می‌دهد.',
  c_xray:'پشت Xray',
  c_xray_h:'وقتی Xray پورت 443 این سرور را گرفته است. Caddy روی یک پورت داخلی (loopback) گوش می‌دهد و Xray این دامنه را به آن می‌فرستد؛ شما یک ردیف fallback در x-ui اضافه می‌کنید (بعد از ذخیره نشان داده می‌شود). گواهی در این حالت روی inbound خود Xray است.',
  f_cert:'گواهی SSL',
  cert_caddy:'Caddy - خودکار می‌گیرد و تمدید می‌کند (پیشنهادی)',
  cert_certbot:'گواهی موجود certbot', cert_internal:'خودامضا (فقط برای تست)',
  f_cert_h:'چه کسی گواهی HTTPS را تهیه کند. Caddy همان لحظهٔ ذخیره از Let\'s Encrypt گواهی می‌گیرد و خودش تمدیدش می‌کند؛ لازم نیست کار دیگری انجام دهید. certbot را فقط وقتی انتخاب کنید که بتواند اینجا تمدید کند - به پورت 80 آزاد یا nginx نیاز دارد که وقتی Caddy سرور را می‌گرداند برقرار نیست. خودامضا باعث هشدار مرورگر می‌شود.',
  cert_by_caddy:'SSL توسط Caddy', to_caddy:'مدیریت SSL با Caddy',
  confirm_to_caddy:'گواهی {0} به Caddy سپرده شود؟\n\nCaddy یک گواهی تازه از Let\'s Encrypt می‌گیرد و از این به بعد خودش تمدیدش می‌کند. سایت در این مدت بالا می‌ماند و فایل‌های قبلی certbot دست‌نخورده می‌مانند.',
  to_caddy_done:'SSL دامنهٔ {0} حالا با Caddy است',
  days_left:'{0} روز مانده', renew:'تمدید',
  confirm_renew:'همین الان برای {0} گواهی تازه گرفته شود؟\n\nCaddy خودش حدود ۳۰ روز قبل از انقضا تمدید می‌کند، پس فقط وقتی مشکلی هست لازم است. Caddy حدود یک ثانیه ری‌استارت می‌شود و اگر گواهی جدید نرسد، گواهی فعلی برگردانده می‌شود.\n\nLet\'s Encrypt برای یک دامنه فقط ۵ بار تمدید در هفته اجازه می‌دهد.',
  renew_started:'در حال تمدید {0}… Caddy برای لحظه‌ای ری‌استارت می‌شود. نتیجه تا یک دقیقه دیگر در گزارش تغییرات می‌آید.',
  btn_add:'افزودن سایت', btn_save:'ذخیرهٔ تغییرات', btn_doctor:'اجرای عیب‌یابی', working:'در حال انجام…',
  note_imported:'این سایت وارد شده یا دستی ویرایش شده است. ذخیره از طریق فرم، آن را با چیدمان استاندارد بازنویسی می‌کند و توضیحات (کامنت‌ها) حذف می‌شوند. نسخهٔ قبلی در گزارش تغییرات می‌ماند و دکمهٔ <b>کانفیگ</b> همیشه متن خام را ویرایش می‌کند.',
  toast_live:'{0} فعال شد', toast_updated:'{0} به‌روز شد', toast_failed:'ناموفق بود - خروجی را ببینید',
  confirm_remove:'سرویس‌دهی {0} متوقف شود؟\n\nگواهی آن نگه داشته می‌شود تا اضافه کردن دوباره فوری باشد.',
  removed:'{0} حذف شد', remove_failed:'حذف {0} ناموفق بود',
  raw_hint:'از طریق <code>smart-caddy put</code> ذخیره می‌شود: Caddy اول آن را بررسی می‌کند و اگر رد شود همه چیز برمی‌گردد، پس یک اشتباه تایپی سرور را از کار نمی‌اندازد.',
  raw_save:'ذخیره و اعمال', raw_saved:'{0} ذخیره شد', raw_rejected:'رد شد - هیچ چیز تغییر نکرد، خروجی را ببینید', raw_read_fail:'خواندن کانفیگ ممکن نشد',
  log_title:'گزارش تغییرات', log_hint:'همهٔ تغییرات، چه از پنل چه از ترمینال: چه کسی انجام داد، چه خروجی‌ای داشت و دقیقاً کدام خطوط کانفیگ عوض شد.',
  log_empty:'هنوز تغییری ثبت نشده است.', log_changes:'تغییرات', log_output:'خروجی', log_nodiff:'هیچ فایل کانفیگی تغییر نکرد.',
  src_panel:'پنل', src_cli:'ترمینال', failed:'ناموفق',
  diag:'عیب‌یابی', running:'در حال اجرا…', no_output:'(بدون خروجی)',
  diag_title:'عیب‌یابی و خروجی', diag_idle:'با اجرای عیب‌یابی کل تنظیمات بررسی می‌شود: پورت‌ها، دسترسی فایل‌ها، گواهی‌ها، DNS و fallbackهای Xray. خروجی هر کاری که انجام می‌دهید هم اینجا نمایش داده می‌شود.',
  dup_tag:'دو بار تعریف شده', dup_keep:'همین را نگه دار',
  confirm_dup:'{0} هم اینجا در Caddyfile و هم در Smart Caddy تعریف شده است.\n\nبلاک Caddyfile نگه داشته شود: جای نسخهٔ مدیریت‌شده را می‌گیرد و از Caddyfile خارج می‌شود. نسخهٔ جایگزین‌شده در گزارش تغییرات می‌ماند و اگر Caddy قبول نکند هیچ چیز تغییر نمی‌کند.',
  act_add:'افزوده شد', act_add_r:'ویرایش شد', act_del:'حذف شد', act_import:'وارد شد', act_put:'کانفیگ ذخیره شد',
  act_fixbind:'اصلاح bind', act_repair:'تعمیر', act_uninstall:'حذف نصب', act_del_cert:'گواهی حذف شد',
  act_renew:'گواهی تمدید شد', act_cert:'SSL به Caddy سپرده شد'
}};

let LANG = 'en';
try { LANG = localStorage.getItem('sc-lang') || ''; } catch(_) {}
if (!I18N[LANG]) LANG = (navigator.language || '').startsWith('fa') ? 'fa' : 'en';

function t(k, ...a){
  let s = I18N[LANG][k] ?? I18N.en[k] ?? k;
  a.forEach((v, i) => { s = s.split('{' + i + '}').join(v); });
  return s;
}

function applyLang(){
  document.documentElement.lang = LANG;
  document.documentElement.dir = LANG === 'fa' ? 'rtl' : 'ltr';
  document.querySelectorAll('[data-t]').forEach(e => e.textContent = t(e.dataset.t));
  // static, trusted strings that carry <code>/<b> markup
  document.querySelectorAll('[data-th]').forEach(e => e.innerHTML = t(e.dataset.th));
  document.querySelectorAll('[data-lang]').forEach(b => b.classList.toggle('on', b.dataset.lang === LANG));
  formTexts();
  if (STATE) render(STATE);
  if (LOG) renderLog(LOG);
}

document.querySelectorAll('[data-lang]').forEach(b => b.onclick = () => {
  LANG = b.dataset.lang;
  try { localStorage.setItem('sc-lang', LANG); } catch(_) {}
  applyLang();
});

// ---------------------------------------------------------------- helpers
let busy = false, STATE = null, LOG = null, SITES = [];
let EDITING = null;          // the site object being edited, null while adding
let XRAY_TOUCHED = false;    // once the user sets it themselves, stop guessing

function esc(s){
  return String(s).replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function toast(msg, bad){
  document.querySelectorAll('.toast').forEach(x => x.remove());
  const el = document.createElement('div');
  el.className = 'toast' + (bad ? ' bad' : '');
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 5200);
}

// Colour CLI output the way a terminal does.
function paint(text){
  return text.split('\n').map(line => {
    const e = esc(line);
    if (/^\s*\[\s*ok\s*\]/.test(line)) return '<span class="ln-ok">'   + e + '</span>';
    if (/^\s*\[warn\]/.test(line))       return '<span class="ln-warn">' + e + '</span>';
    if (/^\s*\[fail\]/.test(line))       return '<span class="ln-bad">'  + e + '</span>';
    if (/^\s*==.*==\s*$/.test(line))      return '<span class="ln-hdr">'  + e + '</span>';
    if (/^\s{4,}\S/.test(line))           return '<span class="ln-dim">'  + e + '</span>';
    return e;
  }).join('\n');
}

function paintDiff(text){
  return text.split('\n').map(line => {
    const e = esc(line);
    if (/^(\+\+\+|---) /.test(line)) return '<span class="d-file">' + e + '</span>';
    if (line.startsWith('@@'))        return '<span class="d-hunk">' + e + '</span>';
    if (line.startsWith('+'))         return '<span class="d-add">'  + e + '</span>';
    if (line.startsWith('-'))         return '<span class="d-del">'  + e + '</span>';
    return e;
  }).join('\n');
}

function show(title, text){
  $('#out-title').textContent = title;
  $('#out').innerHTML = text ? paint(text) : esc(t('no_output'));
  $('#out-idle').hidden = true;
  $('#out').hidden = false;
  $('#out-card').scrollIntoView({behavior:'smooth', block:'nearest'});
}

async function api(path, body){
  const r = await fetch(path, body ? {
    method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)
  } : {});
  if (r.status === 401) { location.reload(); return {}; }   // session expired
  return r.json();
}

// ---------------------------------------------------------------- state
function certTag(s){
  if (s.cert === 'pending')  return '<span class="tag warn">' + esc(t('tag_pending')) + '</span>';
  if (s.cert === 'internal') return '<span class="tag warn">' + esc(t('tag_internal')) + '</span>';
  if (s.cert === 'xray')     return '<span class="tag">' + esc(t('tag_xray')) + '</span>';
  if (s.cert === 'none')     return '<span class="tag">' + esc(t('tag_none')) + '</span>';
  // days left, coloured as it gets close; the full date is in the tooltip
  let left = '', cls = 'ok';
  if (s.expires){
    const days = Math.floor((Date.parse(s.expires) - Date.now()) / 864e5);
    if (!isNaN(days)){
      left = ' · ' + esc(t('days_left', days));
      cls = days < 7 ? 'bad' : days < 21 ? 'warn' : 'ok';
    }
  }
  const title = s.expires ? ' title="' + esc(s.expires) + '"' : '';
  if (s.cert === 'certbot')
    return '<span class="tag warn"' + title + '>certbot' + left + '</span>'
         + '<button type="button" class="link go" data-cert="' + esc(s.domain) + '">' + esc(t('to_caddy')) + '</button>';
  return '<span class="tag ' + cls + '"' + title + '>' + esc(t('cert_by_caddy')) + left + '</span>'
       + '<button type="button" class="link go" data-renew="' + esc(s.domain) + '">' + esc(t('renew')) + '</button>';
}

async function load(){
  const d = await api('/api/state');
  if (!d || !d.sites) return;
  STATE = d;
  render(d);
}

function render(d){
  $('#dot').className = 'dot ' + (d.caddy_running ? 'up' : 'down');
  $('#status').textContent = t(d.caddy_running ? 'caddy_running' : 'caddy_down');
  $('#meta').textContent = 'v' + d.version + (d.front_ip ? ' · ' + d.front_ip : '');

  // Something else on the web ports means a plain site can never bind. Say
  // so once, up front, and pre-tick the option that actually works here.
  const p = d.ports || {};
  const busy443 = p['443'] && p['443'] !== 'caddy';
  const busy80  = p['80']  && p['80']  !== 'caddy';
  if (d.front){
    // another program owns :80/:443 and hands our names to Caddy - normal
    // HTTPS sites work here, so no Xray hint and nothing pre-ticked
    $('#ports-text').innerHTML = t('front_text', '<b>' + esc(d.front.name) + '</b>', '<code>127.0.0.1:' + esc(d.front.port) + '</code>');
    $('#ports-note').hidden = false;
  } else if (busy443 || busy80){
    const who = [busy80 ? ':80 (' + esc(p['80']) + ')' : '',
                 busy443 ? ':443 (' + esc(p['443']) + ')' : ''].filter(Boolean).join(' + ');
    $('#ports-text').innerHTML = t('ports_text', '<code>' + who + '</code>');
    $('#ports-note').hidden = false;
    if (!EDITING && !XRAY_TOUCHED) $('#f-xray').checked = true;
  } else {
    $('#ports-note').hidden = true;
  }

  renderTiles(d);
  renderCaddyfile(d.caddyfile || []);

  SITES = d.sites;
  if (!d.sites.length){
    const any = (d.caddyfile || []).some(b => b.importable);
    $('#sites').innerHTML = '<div class="empty">' + esc(t(any ? 'no_sites_cf' : 'no_sites')) + '</div>';
    return;
  }

  let h = '<table><thead><tr><th>' + esc(t('th_domain')) + '</th><th>' + esc(t('th_backend'))
        + '</th><th>' + esc(t('th_notes')) + '</th><th></th></tr></thead><tbody>';
  d.sites.forEach((s, i) => {
    const pth = s.paths.length ? s.paths[0] : '';
    const scheme = (s.cert === 'none') ? 'http://' : 'https://';
    const url = scheme + s.domain + pth + (pth && !pth.endsWith('/') ? '/' : '');
    let notes = certTag(s);
    if (s.paths.length)  notes += '<span class="tag">' + esc(t('tag_path')) + ' <span class="ltr">' + esc(pth) + '</span></span>';
    if (s.behind_xray)   notes += '<span class="tag">' + esc(t('tag_behind_xray'))
                                + (s.listen_port ? ' :' + esc(s.listen_port) : '') + '</span>';
    if (s.nobuffer)      notes += '<span class="tag">' + esc(t('tag_unbuffered')) + '</span>';
    if (s.insecure)      notes += '<span class="tag">' + esc(t('tag_insecure')) + '</span>';
    if (!s.form_ok)      notes += '<span class="tag warn">' + esc(t('tag_custom')) + '</span>';
    else if (s.imported) notes += '<span class="tag">' + esc(t('tag_imported')) + '</span>';
    let backend = '<code>' + esc(s.target) + '</code>';
    for (const r of s.routes)
      backend += '<div class="rt ltr"><code>' + esc(r.path) + '</code> → <code>' + esc(r.target) + '</code></div>';
    h += '<tr>'
      +  '<td class="dom"><a class="ltr" href="' + esc(url) + '" target="_blank" rel="noopener">' + esc(s.domain) + '</a></td>'
      +  '<td>' + backend + '</td>'
      +  '<td>' + notes + '</td>'
      +  '<td class="acts">'
      +  '<button class="link go" data-edit="' + i + '">' + esc(t('edit')) + '</button>'
      +  '<button class="link go" data-raw="' + esc(s.domain) + '">' + esc(t('config')) + '</button>'
      +  '<button class="link" data-del="' + esc(s.domain) + '">' + esc(t('remove')) + '</button></td>'
      +  '</tr>';
  });
  $('#sites').innerHTML = h + '</tbody></table>';

  document.querySelectorAll('[data-del]').forEach(b => b.onclick = () => remove(b.dataset.del));
  document.querySelectorAll('[data-raw]').forEach(b => b.onclick = () => openRaw(b.dataset.raw));
  document.querySelectorAll('[data-cert]').forEach(b => b.onclick = () => toCaddy(b.dataset.cert));
  document.querySelectorAll('[data-renew]').forEach(b => b.onclick = () => renewCert(b.dataset.renew));
  document.querySelectorAll('[data-edit]').forEach(b => b.onclick = () => {
    // A block the form cannot express would lose directives if saved from
    // the form, so it goes straight to the raw editor.
    const s = SITES[+b.dataset.edit];
    s.form_ok ? startEdit(s) : openRaw(s.domain);
  });
}

function renderTiles(d){
  const now = Date.now(), soon = 21 * 864e5;
  let certs = 0, expiring = 0;
  for (const s of d.sites){
    if (!s.expires) continue;
    certs++;
    const ts = Date.parse(s.expires);
    if (!isNaN(ts) && ts - now < soon) expiring++;
  }
  const unmanaged = (d.caddyfile || []).filter(b => b.importable).length;
  $('#t-sites').textContent = d.sites.length;
  $('#t-certs').textContent = certs;
  $('#t-exp').textContent = expiring;
  $('#t-exp-tile').className = 'tile' + (expiring ? ' warn' : '');
  $('#t-cf').textContent = unmanaged;
  $('#t-cf-tile').className = 'tile' + (unmanaged ? ' warn' : '');
}

function renderCaddyfile(blocks){
  const card = $('#cf-card');
  if (!blocks.length){ card.hidden = true; return; }
  card.hidden = false;
  const open = new Set([...document.querySelectorAll('#cf-list details[open]')].map(x => x.dataset.k));
  let h = '';
  for (const b of blocks){
    const k = b.start + '-' + b.end;
    const act = b.importable
      ? '<button type="button" class="link go" data-imp="' + esc(b.domain) + '">' + esc(t('import')) + '</button>'
      : b.duplicate
      ? '<span class="tag warn">' + esc(t('dup_tag')) + '</span>'
        + '<button type="button" class="link go" data-rep="' + esc(b.domain) + '">' + esc(t('dup_keep')) + '</button>'
      : '<span class="tag">' + esc(t(b.reason)) + '</span>';
    h += '<details class="blk" data-k="' + k + '"' + (open.has(k) ? ' open' : '') + '>'
      +  '<summary><span class="grow"><b class="ltr">' + esc(b.header) + '</b>'
      +  ' <span class="sub">' + esc(t('lines')) + ' <span class="ltr">' + b.start + '–' + b.end + '</span></span></span>'
      +  act + '</summary><pre>' + esc(b.text) + '</pre></details>';
  }
  $('#cf-list').innerHTML = h;
  const all = blocks.filter(b => b.importable).map(b => b.domain);
  $('#btn-import-all').hidden = all.length < 2;
  $('#btn-import-all').onclick = () => importSites(all);
  document.querySelectorAll('[data-imp]').forEach(btn => {
    btn.onclick = e => { e.preventDefault(); importSites([btn.dataset.imp]); };
  });
  document.querySelectorAll('[data-rep]').forEach(btn => {
    btn.onclick = e => { e.preventDefault(); importSites([btn.dataset.rep], true); };
  });
}

// ---------------------------------------------------------------- actions
async function remove(domain){
  if (busy) return;
  if (!confirm(t('confirm_remove', domain))) return;
  busy = true;
  const r = await api('/api/del', {domain, purge_cert:false});
  busy = false;
  toast(r.ok ? t('removed', domain) : t('remove_failed', domain), !r.ok);
  show(t('remove') + ' ' + domain, r.out);
  if (EDITING && EDITING.domain === domain) stopEdit();
  refresh();
}

async function importSites(domains, replace){
  if (busy) return;
  if (!confirm(t(replace ? 'confirm_dup' : 'confirm_import', domains.join(', ')))) return;
  busy = true;
  const r = await api('/api/import', {domains, replace: !!replace});
  busy = false;
  toast(r.ok ? t('imported_n', domains.length) : t('import_failed'), !r.ok);
  show(t('import'), r.out);
  refresh();
}

async function toCaddy(domain){
  if (busy) return;
  if (!confirm(t('confirm_to_caddy', domain))) return;
  busy = true;
  toast(t('working'));
  const r = await api('/api/cert', {domain});
  busy = false;
  toast(r.ok ? t('to_caddy_done', domain) : t('toast_failed'), !r.ok);
  show('SSL ' + domain, r.out);
  refresh();
}

async function renewCert(domain){
  if (busy) return;
  if (!confirm(t('confirm_renew', domain))) return;
  const r = await api('/api/renew', {domain});
  if (!r.ok){ toast(r.out || t('toast_failed'), true); return; }
  toast(t('renew_started', domain));
  show(t('renew') + ' ' + domain, t('renew_started', domain));
  // Caddy restarts in the middle, so poll for the outcome a few times
  [8, 20, 40, 75, 110].forEach(sec => setTimeout(refresh, sec * 1000));
}

// ---------------------------------------------------------------- routes
function addRouteRow(path, target){
  const row = document.createElement('div');
  row.className = 'route';
  row.innerHTML = '<input type="text" class="r-path"><span class="arr">→</span>'
                + '<input type="text" class="r-target">'
                + '<button type="button" class="link" aria-label="remove">✕</button>';
  row.querySelector('.r-path').value = path || '';
  row.querySelector('.r-target').value = target || '';
  row.querySelector('.r-path').placeholder = t('route_path');
  row.querySelector('.r-target').placeholder = t('route_target');
  row.querySelector('button').onclick = () => row.remove();
  $('#routes').appendChild(row);
  return row;
}
$('#btn-route').onclick = () => addRouteRow().querySelector('.r-path').focus();

function readRoutes(){
  return [...document.querySelectorAll('#routes .route')].map(r => ({
    path: r.querySelector('.r-path').value.trim(),
    target: r.querySelector('.r-target').value.trim()
  })).filter(r => r.path || r.target);
}

// ---------------------------------------------------------------- form
function formTexts(){
  $('#form-title').textContent = EDITING ? t('form_edit', EDITING.domain) : t('form_add');
  $('#btn-add').textContent = t(EDITING ? 'btn_save' : 'btn_add');
  document.querySelectorAll('#routes .r-path').forEach(i => i.placeholder = t('route_path'));
  document.querySelectorAll('#routes .r-target').forEach(i => i.placeholder = t('route_target'));
  if (EDITING && EDITING.imported) $('#edit-note').innerHTML = t('note_imported');
}

function startEdit(s){
  EDITING = s;
  $('#f-domain').value  = s.domain;
  $('#f-target').value  = s.target;
  $('#f-path').value    = s.paths.length ? s.paths[0] : '';
  $('#f-host').value    = s.host_header || '';
  $('#f-panel').checked = !!(s.insecure || s.nobuffer);
  $('#f-notls').checked = !!s.no_tls;
  $('#f-xray').checked  = !!s.behind_xray;
  $('#f-cert').value    = (s.cert === 'certbot' || s.cert === 'internal') ? s.cert : 'caddy';
  syncCert();
  XRAY_TOUCHED = true;
  $('#routes').innerHTML = '';
  for (const r of s.routes) addRouteRow(r.path, r.target);
  $('#f-domain').readOnly = true;
  $('#edit-note').hidden = !s.imported;
  $('#form-card').classList.add('editing');
  $('#btn-cancel').hidden = false;
  formTexts();
  $('#form-card').scrollIntoView({behavior:'smooth', block:'start'});
  $('#f-target').focus({preventScroll:true});
}

function stopEdit(){
  EDITING = null;
  $('#add').reset();
  $('#routes').innerHTML = '';
  $('#f-xray').checked = false;
  $('#f-cert').value = 'caddy';
  syncCert();
  XRAY_TOUCHED = false;
  $('#f-domain').readOnly = false;
  $('#edit-note').hidden = true;
  $('#form-card').classList.remove('editing');
  $('#btn-cancel').hidden = true;
  formTexts();
}

// No certificate to choose when the site is plain HTTP or Xray holds it.
function syncCert(){ $('#f-cert').disabled = $('#f-notls').checked || $('#f-xray').checked; }
$('#f-xray').onchange = () => { XRAY_TOUCHED = true; syncCert(); };
$('#f-notls').onchange = syncCert;
$('#btn-cancel').onclick = stopEdit;

$('#add').onsubmit = async e => {
  e.preventDefault();
  if (busy) return;
  const body = {
    domain: $('#f-domain').value.trim(),
    target: $('#f-target').value.trim(),
    routes: readRoutes(),
    paths: $('#f-path').value.trim() ? [$('#f-path').value.trim()] : [],
    host_header: $('#f-host').value.trim(),
    panel: $('#f-panel').checked,
    no_tls: $('#f-notls').checked,
    behind_xray: $('#f-xray').checked,
    cert: $('#f-cert').value
  };
  const editing = !!EDITING;
  busy = true;
  $('#btn-add').disabled = true;
  $('#btn-add').textContent = t('working');
  const r = await api(editing ? '/api/edit' : '/api/add', body);
  $('#btn-add').disabled = false;
  busy = false;
  toast(r.ok ? t(editing ? 'toast_updated' : 'toast_live', body.domain) : t('toast_failed'), !r.ok);
  show((editing ? t('edit') : t('btn_add')) + ' ' + body.domain, r.out);
  if (r.ok) stopEdit(); else formTexts();
  refresh();
};

$('#btn-out').onclick = async () => {
  await api('/api/logout', {});
  location.reload();
};

$('#btn-doctor').onclick = async () => {
  if (busy) return;
  busy = true;
  show(t('diag'), t('running'));
  const r = await api('/api/doctor');
  busy = false;
  show(t('diag'), r.out);
};

// ---------------------------------------------------------------- raw editor
let RAW = null;

async function openRaw(domain){
  const r = await api('/api/config?domain=' + encodeURIComponent(domain));
  if (!r.ok){ toast(r.out || t('raw_read_fail'), true); return; }
  RAW = domain;
  $('#raw-title').textContent = domain;
  $('#raw-text').value = r.config;
  $('#raw').showModal();
  $('#raw-text').focus();
}
function closeRaw(){ RAW = null; $('#raw').close(); }
$('#raw-close').onclick = closeRaw;
$('#raw-cancel').onclick = closeRaw;

// Tab inserts a tab instead of leaving the editor; Caddyfiles are tab-indented.
$('#raw-text').addEventListener('keydown', e => {
  if (e.key !== 'Tab' || e.shiftKey) return;
  e.preventDefault();
  const el = e.target;
  el.setRangeText('\t', el.selectionStart, el.selectionEnd, 'end');
});

$('#raw-save').onclick = async () => {
  if (busy || !RAW) return;
  const domain = RAW;
  busy = true;
  $('#raw-save').disabled = true;
  const r = await api('/api/put', {domain, config: $('#raw-text').value});
  $('#raw-save').disabled = false;
  busy = false;
  toast(r.ok ? t('raw_saved', domain) : t('raw_rejected'), !r.ok);
  show(t('config') + ' ' + domain, r.out);
  if (r.ok) closeRaw();
  refresh();
};

// ---------------------------------------------------------------- activity log
function actLabel(cmd){
  const w = cmd.split(/\s+/), c = w[0];
  const key = {add:'act_add', del:'act_del', rm:'act_del', remove:'act_del', import:'act_import',
               adopt:'act_import', put:'act_put', fixbind:'act_fixbind', repair:'act_repair',
               uninstall:'act_uninstall', 'del-cert':'act_del_cert', renew:'act_renew', cert:'act_cert'}[c];
  if (!key) return c;
  if (c === 'add' && w.includes('--replace')) return t('act_add_r');
  return t(key);
}
function actTarget(cmd){
  const w = cmd.split(/\s+/).slice(1).filter(x => !x.startsWith('-') && /\./.test(x) && !x.startsWith('/'));
  return w.length ? w[0] : '';
}

async function loadLog(){
  const r = await api('/api/log');
  if (!r || !r.log) return;
  LOG = r.log;
  renderLog(LOG);
}

function renderLog(list){
  if (!list.length){ $('#log').innerHTML = '<div class="empty">' + esc(t('log_empty')) + '</div>'; return; }
  const open = new Set([...document.querySelectorAll('#log details[open]')].map(x => x.dataset.k));
  const fmt = new Intl.DateTimeFormat(LANG === 'fa' ? 'fa-IR' : 'en-GB',
                {year:'numeric', month:'short', day:'numeric', hour:'2-digit', minute:'2-digit'});
  let h = '';
  for (const e of list){
    const k = e.ts + e.cmd;
    const tgt = actTarget(e.cmd);
    h += '<details class="blk" data-k="' + esc(k) + '"' + (open.has(k) ? ' open' : '') + '>'
      +  '<summary><span class="dot ' + (e.ok ? 'up' : 'down') + '"></span>'
      +  '<span class="when">' + esc(fmt.format(new Date(e.ts * 1000))) + '</span>'
      +  '<span class="grow"><b>' + esc(actLabel(e.cmd)) + '</b>'
      +  (tgt ? ' <span class="ltr">' + esc(tgt) + '</span>' : '')
      +  (e.ok ? '' : ' <span class="tag bad">' + esc(t('failed')) + '</span>') + '</span>'
      +  '<span class="tag">' + esc(t(e.src === 'panel' ? 'src_panel' : 'src_cli')) + '</span>'
      +  '<span class="sub ltr">' + esc(e.who || '') + '</span></summary>'
      +  '<div class="cmd sub" style="margin-top:8px">$ smart-caddy ' + esc(e.cmd) + '</div>'
      +  '<h3>' + esc(t('log_changes')) + '</h3>'
      +  (e.diff ? '<pre>' + paintDiff(e.diff) + '</pre>' : '<div class="sub">' + esc(t('log_nodiff')) + '</div>')
      +  '<h3>' + esc(t('log_output')) + '</h3><pre>' + (e.out ? paint(e.out) : esc(t('no_output'))) + '</pre>'
      +  '</details>';
  }
  $('#log').innerHTML = h;
}
$('#btn-log').onclick = loadLog;

function refresh(){ load(); loadLog(); }

applyLang();
stopEdit();
refresh();
setInterval(() => { if (!busy && !$('#raw').open) refresh(); }, 20000);
</script>
</body>
</html>
"""


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--init-auth":
        init_auth(sys.argv[2], sys.argv[3])
        print(AUTH_FILE)
        return

    if not load_auth():
        sys.stderr.write(
            f"no credentials at {AUTH_FILE}\n"
            f"create them with:  python3 {sys.argv[0]} --init-auth <user> <password>\n")
        sys.exit(1)

    if not os.path.exists(CLI):
        sys.stderr.write(f"smart-caddy CLI not found at {CLI}\n")
        sys.exit(1)
    if HOST not in ("127.0.0.1", "::1", "localhost"):
        sys.stderr.write(
            f"WARNING: binding to {HOST}. The panel authenticates, but it speaks\n"
            f"plain HTTP - put Caddy in front of it rather than exposing it.\n")
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"smart-caddy panel listening on http://{HOST}:{PORT}\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
SMART_CADDY_UI_PY_PAYLOAD
}

# =============================================================================
#  panel - install the web UI behind Caddy basic auth
# =============================================================================
UI_PY="/usr/local/lib/smart-caddy/ui.py"
UI_UNIT="/etc/systemd/system/smart-caddy-ui.service"
UI_PORT_DEFAULT=9797
UI_SRC_OVERRIDE=""

# Where to look for a standalone smart_caddy_ui.py, in priority order.
# Deliberately does NOT list $UI_PY. That is where we *install* to, and an
# older copy sitting there used to win over the payload embedded in this
# script - so every upgrade silently kept running the previous panel.
ui_candidates() {
	printf '%s\n' \
		"$UI_SRC_OVERRIDE" \
		"$(dirname "$(readlink -f "$0")")/smart_caddy_ui.py" \
		"${SRC_DIR:+$SRC_DIR/smart_caddy_ui.py}" \
		"$PWD/smart_caddy_ui.py" \
		"${HOME:-/root}/smart_caddy_ui.py" \
		"/root/smart_caddy_ui.py" \
		"/opt/smart-caddy/smart_caddy_ui.py" \
		| awk 'NF && !seen[$0]++'
}

# A candidate counts only if it parses as Python and looks like our panel -
# a truncated download or a leftover placeholder must not be installed.
ui_is_valid() {
	python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$1" 2>/dev/null \
		&& grep -q 'smart-caddy web panel' "$1" 2>/dev/null
}

# Print each candidate with whether it exists - shown when something is wrong.
ui_report() {
	local c
	while read -r c; do
		if   [[ ! -f "$c" ]];    then dim "missing $c"
		elif ! ui_is_valid "$c"; then dim "not the panel $c"
		else                          dim "found   $c"; fi
	done < <(ui_candidates)
}

# Resolve the panel source. Prefers a standalone file (so you can hack on it),
# otherwise writes out the copy embedded in this script - which is why the
# panel works from a single downloaded file with nothing else alongside it.
find_ui_source() {
	local c
	while read -r c; do
		[[ -f "$c" ]] || continue
		ui_is_valid "$c" || continue
		readlink -f "$c"; return 0
	done < <(ui_candidates)

	c=$(find /root /home /opt -maxdepth 4 -name 'smart_caddy_ui.py' \
	     -type f 2>/dev/null | head -1) || true
	[[ -n "$c" ]] && ui_is_valid "$c" && { echo "$c"; return 0; }

	if declare -F ui_payload >/dev/null 2>&1; then
		local tmp; tmp="$(mktemp /tmp/smart-caddy-ui.XXXXXX.py)"
		ui_payload > "$tmp"
		if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmp" 2>/dev/null; then
			echo "$tmp"; return 0
		fi
		rm -f "$tmp"
	fi

	# Nothing else worked: fall back to whatever is already installed.
	[[ -f "$UI_PY" ]] && ui_is_valid "$UI_PY" && { readlink -f "$UI_PY"; return 0; }
	return 1
}

cmd_update() {
	need_root update
	have curl || die "curl is required to update"
	local force=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--force|-f) force=1; shift ;;
			*) die "unknown option: $1" ;;
		esac
	done

	hdr "Updating from the latest release"
	dim "$SELF_URL"
	local tmp; tmp="$(mktemp /tmp/smart-caddy.XXXXXX.sh)"
	curl -fsSL "$SELF_URL" -o "$tmp" \
		|| { rm -f "$tmp"; die "download failed"; }
	# Never install something we have not sanity-checked: a captive portal or
	# a 404 page would otherwise replace a working install with HTML.
	[[ -s "$tmp" ]] && bash -n "$tmp" 2>/dev/null && grep -q 'smart-caddy' "$tmp" \
		|| { rm -f "$tmp"; die "what came back is not a valid smart-caddy script"; }

	local newv; newv="$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)"
	local installed="/usr/local/bin/$SELF_NAME"

	# Compare CONTENT, not the version string. Re-uploading a fixed build under
	# the same version number is normal during development, and a version-only
	# check would report "nothing to do" while serving the old code forever.
	if [[ $force -eq 0 && -f "$installed" ]] && cmp -s "$tmp" "$installed"; then
		ok "already running the published build (v$VERSION) - nothing to do"
		dim "use '--force' to reinstall it anyway"
		rm -f "$tmp"; return 0
	fi

	if [[ "$newv" == "$VERSION" ]]; then
		info "same version number (v$VERSION), but the published file differs"
		dim "updating on content, not on the version string"
	else
		ok "v$VERSION -> v${newv:-?}"
	fi
	if have sha256sum; then
		dim "new build: $(sha256sum "$tmp" | cut -c1-12)"
	fi

	install -m 0755 "$tmp" "/usr/local/bin/$SELF_NAME"
	rm -f "$tmp"
	ok "command replaced"

	# The panel source lives inside the script, so it has to be refreshed too.
	"/usr/local/bin/$SELF_NAME" install --yes >/dev/null 2>&1 \
		&& ok "panel source and system wiring refreshed" \
		|| warn "run '$SELF_NAME install' by hand to finish the update"

	hdr "Done"
	dim "$SELF_NAME doctor   check everything still looks right"
}

cmd_passwd() {
	need_root passwd
	local user="" pass="" show=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--user)     user="${2:?}"; shift 2 ;;
			--password) pass="${2:?}"; shift 2 ;;
			*) [[ -z "$user" ]] && { user="$1"; shift; } || die "unknown option: $1" ;;
		esac
	done

	[[ -f "$UI_PY" ]] || die "the web panel is not installed. Run: $SELF_NAME panel <domain>"
	grep -q -- '--init-auth' "$UI_PY" \
		|| die "$UI_PY is too old. Run '$SELF_NAME install' to refresh it."

	# Keep the existing username unless a new one is given.
	if [[ -z "$user" ]]; then
		user="$(python3 -c '
import json,sys
try: print(json.load(open("/etc/smart-caddy-panel.json"))["user"])
except Exception: pass' 2>/dev/null || true)"
		[[ -z "$user" ]] && user="admin"
	fi

	hdr "Panel password"
	dim "user: $user"
	if [[ -z "$pass" ]]; then
		if [[ -t 0 ]]; then
			local p2
			read -r -s -p "  New password (blank to generate one): " pass; echo
			if [[ -n "$pass" ]]; then
				read -r -s -p "  Again: " p2; echo
				[[ "$pass" == "$p2" ]] || die "the two passwords do not match"
				[[ ${#pass} -ge 8 ]] || die "use at least 8 characters"
			fi
		fi
		if [[ -z "$pass" ]]; then
			pass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20 || true)"
			[[ ${#pass} -ge 12 ]] || pass="$(openssl rand -hex 12)"
			ok "generated a random password"
		fi
	fi

	python3 "$UI_PY" --init-auth "$user" "$pass" >/dev/null \
		|| die "could not write the credentials"
	chmod 0600 /etc/smart-caddy-panel.json 2>/dev/null || true
	systemctl restart smart-caddy-ui >/dev/null 2>&1 || true
	sleep 1

	ok "password changed - every existing session was signed out"
	echo
	printf '    username: %s%s%s\n' "$C_B" "$user" "$C_OFF"
	printf '    password: %s%s%s\n' "$C_B" "$pass" "$C_OFF"
	echo
	dim "changing the password rotates the session key, so anyone already"
	dim "logged in has to sign in again"
}

cmd_panel() {
	need_root panel
	local sub="${1:-}"
	case "$sub" in
		remove|uninstall) shift; panel_remove "$@"; return ;;
		status)           panel_status; return ;;
	esac

	local domain="" user="admin" port="$UI_PORT_DEFAULT" pass=""
	local behind_xray=0 front_port=""
	# First bare argument is the domain; everything else is a flag.
	if [[ -n "${1:-}" && "${1:0:1}" != "-" ]]; then domain="$1"; shift; fi
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--user)     user="${2:?}";            shift 2 ;;
			--port)     port="${2:?}";            shift 2 ;;
			--password) pass="${2:?}";            shift 2 ;;
			--ui)       UI_SRC_OVERRIDE="${2:?}"; shift 2 ;;
			--behind-xray) behind_xray=1;         shift ;;
			--front-port)  front_port="${2:?}";   shift 2 ;;
			--yes|-y)   ASSUME_YES=1;             shift ;;
			*) die "unknown option: $1" ;;
		esac
	done

	have python3 || die "python3 is required for the web panel"

	# If something else owns both web ports on every interface, a normal :443
	# site can never bind. Offer the only arrangement that can work here.
	if [[ $behind_xray -eq 0 && -n "$(caddy_front_port)" ]]; then
		ok "a front proxy owns :443 and hands traffic to Caddy - the panel goes behind it"
	elif [[ $behind_xray -eq 0 ]]; then
		local _o443; _o443="$(port_owner 443)"
		if [[ -n "$_o443" && "$_o443" != caddy ]]; then
			warn ":443 is held by '$_o443', so Caddy cannot serve the panel there"
			if ask "Put the panel behind its fallback instead (--behind-xray)?" y; then
				behind_xray=1
			fi
		fi
	fi

	# --- ask for anything not given on the command line --------------------
	if [[ -z "$domain" ]]; then
		hdr "Web panel setup"
		[[ -n "$FRONT_IP" ]] && dim "This server answers on $FRONT_IP"
		dim "Pick a subdomain for the panel. Its A record must point here,"
		dim "with any CDN / cloud-proxy toggle switched OFF."
		echo
		while :; do
			prompt domain "Domain for the panel (e.g. caddy.example.com)"
			[[ -z "$domain" ]] && die "cancelled"
			valid_domain "$domain" && break
			warn "'$domain' is not a valid domain - try again"
		done
		prompt user "Username" "admin"
		prompt port "Local port for the panel service" "$UI_PORT_DEFAULT"
		echo
	fi
	valid_domain "$domain" || die "invalid domain: $domain"
	[[ "$port" =~ ^[0-9]+$ ]] || die "invalid port: $port"
	[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid username: $user"

	local src
	if ! src="$(find_ui_source)"; then
		warn "could not obtain the panel source. Paths checked:"
		ui_report
		dim "This build has no embedded copy either - re-download smart_caddy.sh,"
		dim "or point at the .py directly:"
		dim "    $SELF_NAME panel $domain --ui /path/to/smart_caddy_ui.py"
		die "web panel source missing"
	fi
	case "$src" in
		/tmp/smart-caddy-ui.*) ok "panel source: embedded in this script" ;;
		*)                     ok "panel source: $src" ;;
	esac

	hdr "1/6  Installing the panel"
	mkdir -p "$(dirname "$UI_PY")"
	# find_ui_source can hand back $UI_PY itself, or a temp file holding the
	# embedded payload. Copying a file onto itself is an error, so check first.
	if [[ "$(readlink -f "$src")" != "$(readlink -f "$UI_PY" 2>/dev/null || echo /nonexistent)" ]]; then
		install -m 0755 "$src" "$UI_PY"
		ok "installed -> $UI_PY"
	else
		chmod 0755 "$UI_PY"
		ok "already present at $UI_PY"
	fi
	case "$src" in /tmp/smart-caddy-ui.*.py) rm -f "$src" ;; esac

	# Credentials BEFORE the service. The panel refuses to start without them,
	# so starting first means systemd restart-loops on a failure that is really
	# just "we have not written the password yet".
	hdr "2/6  Credentials"
	if [[ -z "$pass" ]]; then
		# tr is killed by SIGPIPE when head has had enough; with pipefail that
		# reads as failure and set -e would abort here.
		pass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20 || true)"
		[[ ${#pass} -ge 12 ]] || pass="$(openssl rand -hex 12)"
		ok "generated a random password"
	fi
	if ! grep -q -- '--init-auth' "$UI_PY"; then
		die "the installed panel at $UI_PY is older than this script and cannot
       set credentials. Re-run 'install' to refresh it."
	fi
	# The panel hashes and stores this itself (PBKDF2), so the plaintext never
	# reaches a config file and the login is a real form, not the browser's
	# native credential box.
	python3 "$UI_PY" --init-auth "$user" "$pass" >/dev/null \
		|| die "could not write the panel credentials"
	chmod 0600 /etc/smart-caddy-panel.json 2>/dev/null || true
	ok "credentials stored (PBKDF2, /etc/smart-caddy-panel.json, mode 0600)"

	hdr "3/6  Service"
	cat > "$UI_UNIT" <<-EOF
		[Unit]
		Description=smart-caddy web panel
		After=network.target caddy.service
		StartLimitIntervalSec=60
		StartLimitBurst=5

		[Service]
		Type=simple
		Environment=SMART_CADDY_UI_HOST=127.0.0.1
		Environment=SMART_CADDY_UI_PORT=${port}
		ExecStart=$(command -v python3) ${UI_PY}
		Restart=on-failure
		RestartSec=3
		# It edits /etc/caddy and reloads the service, so it needs root -
		# but it only ever listens on loopback.
		User=root
		NoNewPrivileges=yes
		ProtectHome=yes
		PrivateTmp=yes

		[Install]
		WantedBy=multi-user.target
	EOF
	systemctl daemon-reload
	systemctl reset-failed smart-caddy-ui >/dev/null 2>&1 || true
	systemctl enable smart-caddy-ui >/dev/null 2>&1 || true
	# restart, not start: on a re-run the old process still holds the previous
	# ui.py and the port, so 'start' would silently change nothing.
	systemctl restart smart-caddy-ui >/dev/null 2>&1 || true
	sleep 1
	if systemctl is-active --quiet smart-caddy-ui; then
		ok "service running on 127.0.0.1:${port}"
	else
		warn "the panel service did not start. Last few lines:"
		journalctl -u smart-caddy-ui -n 8 --no-pager 2>/dev/null \
			| sed 's/^/       /' >&2 || true
		die "panel service failed to start"
	fi

	if [[ $behind_xray -eq 1 ]]; then
		[[ -n "$front_port" ]] || front_port="$(pick_free_port 8200 8299)" \
			|| die "no free loopback port for the panel's front door"
		ok "front door on 127.0.0.1:${front_port} (plain HTTP, PROXY protocol v2)"
	fi

	hdr "4/6  Certificate"
	local tls_block=""
	if [[ -f "$(certbot_cert "$domain")" ]] && certbot_renew_ok "$domain"; then
		tls_block=$'\ttls '"$(certbot_cert "$domain") $(certbot_key "$domain")"
		ok "reusing the existing certbot certificate"
	else
		info "Caddy will obtain the certificate and renew it by itself"
	fi

	hdr "5/6  Caddy site"
	local f; f="$(site_file "$domain")"
	[[ -f "$f" ]] && stage_edit "$f" || stage_new "$f"

	if [[ $behind_xray -eq 1 ]]; then
		ensure_global_server_block "127.0.0.1:${front_port}"
		{
			echo "# smart-caddy web panel - managed by '$SELF_NAME panel'"
			echo "# behind an Xray fallback: Xray terminates TLS on :443 and forwards"
			echo "# here, so this listener is plain HTTP on loopback."
			echo "http://${domain}:${front_port} {"
			echo -e "\tbind 127.0.0.1"
			echo -e "\tencode zstd gzip"
			echo
			echo -e "\t# The panel handles its own login and sessions."
			echo -e "\treverse_proxy 127.0.0.1:${port} {"
			echo -e "\t\theader_up Host {host}"
			echo -e "\t\theader_up X-Real-IP {remote_host}"
			echo -e "\t\theader_up X-Forwarded-Proto https"
			echo -e "\t}"
			echo "}"
		} > "$f"
		chown "root:$(caddy_group)" "$f" 2>/dev/null || true
		chmod 0644 "$f"
		apply

		hdr "6/6  Done - one step left, in Xray"
		ok "https://${domain}  (once the fallback below exists)"
		echo
		printf '    %-6s %s\n' "SNI"  "$domain"
		printf '    %-6s %s\n' "ALPN" "(leave empty)"
		printf '    %-6s %s\n' "Path" "/"
		printf '    %-6s %s\n' "Dest" "127.0.0.1:${front_port}"
		printf '    %-6s %s\n' "xver" "2"
		echo
		warn "the certificate for $domain must be on the Xray inbound, not here"
		echo
		printf '    username: %s%s%s\n' "$C_B" "$user" "$C_OFF"
		printf '    password: %s%s%s\n' "$C_B" "$pass" "$C_OFF"
		echo
		warn "write the password down - only a PBKDF2 hash is kept"
		return 0
	fi

	{
		echo "# smart-caddy web panel - managed by '$SELF_NAME panel'"
		echo "$domain {"
		bind_line
		echo -e "\tencode zstd gzip"
		[[ -n "$tls_block" ]] && echo "$tls_block"
		echo
		echo -e "\t# The panel handles its own login and sessions."
		echo -e "\treverse_proxy 127.0.0.1:${port} {"
		echo -e "\t\theader_up Host {host}"
		echo -e "\t\theader_up X-Real-IP {remote_host}"
		echo -e "\t\theader_up X-Forwarded-Proto {scheme}"
		echo -e "\t}"
		echo "}"
		if [[ -n "$(caddy_front_port)" ]] && caddy_redirects_off; then
			redirect_block "$domain"
		fi
	} > "$f"
	chown "root:$(caddy_group)" "$f" 2>/dev/null || true
	chmod 0644 "$f"
	apply
	front_register "$domain"

	hdr "6/6  Done"
	ok "https://${domain}"
	echo
	printf '    username: %s%s%s\n' "$C_B" "$user" "$C_OFF"
	printf '    password: %s%s%s\n' "$C_B" "$pass" "$C_OFF"
	echo
	warn "write the password down - only a PBKDF2 hash is kept, it cannot be recovered"
	dim "change it later: $SELF_NAME panel $domain --password <new>"
	echo
	if [[ -n "$FRONT_IP" ]] && have dig; then
		local r; r=$(dig +short "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || true
		if [[ -z "$r" ]]; then
			warn "$domain has no A record yet - create one pointing at $FRONT_IP"
		elif [[ "$r" != "$FRONT_IP" ]]; then
			warn "$domain resolves to $r, not $FRONT_IP"
			dim "if your DNS provider has a CDN / cloud-proxy toggle, turn it OFF -"
			dim "with it on, the record returns the CDN's IP and no certificate is issued"
		else
			ok "DNS -> $r"
		fi
	fi
}

panel_status() {
	if systemctl is-active --quiet smart-caddy-ui; then
		ok "panel service running"
		dim "$(systemctl show smart-caddy-ui -p ExecStart --value)"
	else
		warn "panel service not running"
		dim "journalctl -u smart-caddy-ui -n 30 --no-pager"
	fi
	shopt -s nullglob
	local f
	for f in "$SITES_DIR"/*.caddy; do
		grep -q 'smart-caddy web panel' "$f" && ok "served at: $(basename "$f" .caddy)"
	done
	shopt -u nullglob
}

panel_remove() {
	need_root panel
	local domain="${1:-}"
	systemctl disable --now smart-caddy-ui >/dev/null 2>&1 || true
	rm -f "$UI_UNIT"; systemctl daemon-reload
	rm -rf "$(dirname "$UI_PY")"
	ok "panel service removed"
	if [[ -n "$domain" ]]; then
		rm -f "$(site_file "$domain")"
		apply
		ok "$domain removed from Caddy (certificate kept)"
	else
		dim "remove its domain with: $SELF_NAME del <domain>"
	fi
}

cmd_uninstall() {
	need_root uninstall
	warn "this removes the import line and the $SELF_NAME command"
	dim "your own Caddyfile blocks and all certificates are left untouched"
	ask "Continue?" n || { info "cancelled"; exit 0; }
	local bak="${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"; cp -p "$CADDYFILE" "$bak"
	local tmp; tmp=$(mktemp)
	grep -v -e "^import ${SITES_DIR}/\*\.caddy" -e "^# --- sites managed by" "$CADDYFILE" > "$tmp"
	write_inplace "$CADDYFILE" "$tmp"
	caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && systemctl reload caddy 2>/dev/null || true
	ok "import line removed, backup: $bak"
	dim "site files kept in $SITES_DIR"
	rm -f "/usr/local/bin/$SELF_NAME" "$CONF_FILE"
	ok "$SELF_NAME command removed"
}

# =============================================================================
usage() {
cat <<EOF
${C_B}smart-caddy v${VERSION}${C_OFF} - smart reverse proxy management for Caddy

${C_B}FIRST TIME? RUN THIS:${C_OFF}
  sudo $(self_invocation) setup

${C_B}COMMANDS${C_OFF}
  setup                                    one command: installs Caddy if
                                           needed, then asks its way through
                                           the whole thing
  install [--ip <IP>] [--email <mail>]     just the system wiring
  add <domain> <port|host:port> [opts]     add a domain (automatic TLS)
  del <domain> [--keep-cert|--purge-cert]  remove a domain
  del-cert <domain>                        remove only the certificate
  cert <domain> caddy                      let Caddy issue and renew the
                                           certificate instead of certbot
  renew <domain>                           get a fresh certificate right now
                                           (the old one returns if it fails)
  list                                     list domains and certificates
  import [domain...] [--all|--list]        move sites already in the Caddyfile
         <domain> --replace                ... over a managed copy of the same domain
                                           into sites.d so they can be managed
  put <domain> <file>                      replace a site's config with your
                                           own text (validated, rolled back
                                           if Caddy rejects it)
  panel <domain> [--user u] [--port n]     install the web UI at that domain
                 [--behind-xray]           ... behind an Xray fallback instead
  panel status | panel remove [<domain>]   check or remove the web UI
  passwd [user] [--password <p>]           change the panel password
  update [--force]                         fetch and install the latest release
  doctor                                   full diagnostic
  fixbind                                  add 'bind' to blocks missing it
  repair                                   fix file permissions and reload
  uninstall                                remove integration (certs kept)

${C_B}ADD OPTIONS${C_OFF}
  --path <prefix>      record the app's base path (shown in 'list'); repeatable
  --route <p>=<backend> send one path to another backend, e.g.
                       --route '/dns-query/*=8000'; repeatable. The main
                       backend still gets everything else
  --replace            overwrite an existing site in place (keeps its cert,
                       and its loopback port when behind Xray)
  --strict-path        additionally refuse everything outside those prefixes.
                       Breaks apps that use the site root for websockets or
                       assets - which most admin panels do
  --behind-xray        Xray owns :443 and falls back to us. Listens on a free
                       loopback port as plain HTTP with PROXY protocol + h2c,
                       and prints the fallback row to add in x-ui
  --listen-port <n>    pick the loopback port yourself (default: first free
                       one in 8081-8199)
  --panel              preset for admin panels: implies --insecure --no-buffer
  --insecure           do not verify the backend's TLS cert (self-signed backends)
  --no-buffer          stream responses through (live stats, SSE, log tails)
  --host-header <v>    force the Host header sent upstream (routers want 127.0.0.1)
  --auto-cert          Caddy issues and renews the certificate itself, even
                       if certbot already has one (recommended)
  --certbot            use the existing certbot certificate
  --self-signed        use Caddy's internal CA (testing only)
  --no-tls             plain HTTP, no certificate
  --no-dns-check       skip the A-record check
  -y, --yes            non-interactive

${C_B}TARGETS${C_OFF}
  54321                      a port on this machine
  127.0.0.1:54321            the same, spelled out
  https://127.0.0.1:27389    a local app that serves TLS itself (+ --insecure)
  10.0.0.5:9000              a service on another machine
  /var/www/mysite            serve files from a directory
  example.com                proxy through to somebody else's site
  redirect:https://x.com     send visitors there instead

${C_B}RECIPES${C_OFF}
  ${C_DIM}# plain web app${C_OFF}
  smart-caddy add app.example.com 3000

  ${C_DIM}# x-ui / 3x-ui panel: HTTPS backend, secret base path, live traffic stats${C_OFF}
  smart-caddy add panel.example.com https://127.0.0.1:27389 \\
      --panel --path /5wSobQvUFuNy4zBUcc

  ${C_DIM}# router or modem UI behind a tunnel, insists on seeing its own Host${C_OFF}
  smart-caddy add modem.example.com 2222 --host-header 127.0.0.1

  ${C_DIM}# two apps on one domain${C_OFF}
  smart-caddy add app.example.com 3000 --path /api --path /admin

${C_B}OTHER EXAMPLES${C_OFF}
  smart-caddy install --ip 203.0.113.10
  smart-caddy del panel.example.com
  smart-caddy doctor
EOF
}

main() {
	local cmd="${1:-}"; [[ $# -gt 0 ]] && shift
	case "$cmd" in
		add|del|rm|remove|del-cert|put|cert|renew|fixbind|repair|uninstall)
			activity_begin "$cmd" "$@" ;;
		import|adopt)
			[[ " $* " == *" --list "* || " $* " == *" --json "* ]] || activity_begin "$cmd" "$@" ;;
	esac
	case "$cmd" in
		setup)             cmd_setup "$@" ;;
		install)           cmd_install "$@" ;;
		add)               cmd_add "$@" ;;
		del|rm|remove)     cmd_del "$@" ;;
		del-cert)          cmd_del_cert "$@" ;;
		list|ls)           cmd_list ;;
		import|adopt)      cmd_import "$@" ;;
		cert)              cmd_cert "$@" ;;
		renew)             cmd_renew "$@" ;;
		put)               cmd_put "$@" ;;
		doctor|check)      cmd_doctor ;;
		panel)             cmd_panel "$@" ;;
		passwd|password)   cmd_passwd "$@" ;;
		update|upgrade)    cmd_update "$@" ;;
		fixbind)           cmd_fixbind ;;
		repair)            cmd_repair ;;
		uninstall)         cmd_uninstall ;;
		-v|--version)      echo "smart-caddy v$VERSION" ;;
		-h|--help|help)    usage ;;
		"")
			# Running the script bare almost always means "install this",
			# not "show me every flag". Offer that, and only fall back to
			# the command list once the machine is already configured.
			if install_is_complete; then
				usage
				echo
				ok "this machine is already set up ($CONF_FILE)"
				dim "$SELF_NAME list     what you have"
				dim "$SELF_NAME doctor   check it over"
				dim "$SELF_NAME setup    run setup again"
			elif [[ -r "$CONF_FILE" ]]; then
				# Settings exist but the command does not: a previous run was
				# interrupted, or installed from a source it could not copy.
				warn "this machine is half-installed"
				dim "$CONF_FILE exists, but /usr/local/bin/$SELF_NAME is missing"
				echo
				if ask "Finish the installation now?" y; then
					cmd_install --yes
					install_is_complete \
						&& { echo; ok "fixed - try:  $SELF_NAME doctor"; } \
						|| warn "still not installed; run with 'install' and read the output"
				else
					echo
					dim "later:  sudo $(self_invocation) install"
				fi
			else
				info "smart-caddy is not set up on this machine yet"
				echo
				if ask "Start setup now?" y; then
					cmd_setup
				else
					echo
					dim "when you are ready:  sudo bash $0 setup"
					dim "full command list:   bash $0 --help"
				fi
			fi
			;;
		*) die "unknown command: $cmd   (try: $0 --help)" ;;
	esac
}
main "$@"
