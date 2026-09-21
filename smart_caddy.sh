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

VERSION="1.4.0"
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
	[[ -n "$FRONT_IP" ]] || return 0
	printf '\tbind %s\n' "$FRONT_IP"
}

certbot_cert()   { printf '%s/%s/fullchain.pem' "$LE_LIVE" "$1"; }
certbot_key()    { printf '%s/%s/privkey.pem'   "$LE_LIVE" "$1"; }
caddy_cert_dir() { printf '%s/certificates/%s/%s' "$CADDY_DATA" "$ACME_HOST" "$1"; }
site_file()      { printf '%s/%s.caddy' "$SITES_DIR" "$1"; }

cert_kind() {   # -> certbot | caddy | none
	local d="$1"
	[[ -f "$(certbot_cert "$d")" ]] && { echo certbot; return; }
	[[ -f "$(caddy_cert_dir "$d")/$d.crt" ]] && { echo caddy; return; }
	echo none
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
port_owner() {
	local p=":$1"
	ss -tnlpH 2>/dev/null | awk -v p="$p" '
		{
			a = $4
			if (length(a) >= length(p) && substr(a, length(a) - length(p) + 1) == p) {
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
		dim "    curl -fsSL <url> -o smart_caddy.sh && sudo bash smart_caddy.sh setup"
		dim "    sudo bash <(curl -fsSL <url>) setup"
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
		local existing; existing=$(grep -oP '^\s*bind\s+\K[0-9.]+' "$CADDYFILE" | head -1 || true)
		if [[ -n "$existing" ]]; then
			ip="$existing"; info "taken from existing 'bind' in Caddyfile: $ip"
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
	local behind_xray=0 listen_port=""

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
			--behind-xray)  behind_xray=1;         shift ;;
			--listen-port)  listen_port="${2:?}";  shift 2 ;;
			--host-header)  host_header="${2:?}";  shift 2 ;;
			--insecure)     insecure=1;            shift ;;
			--no-buffer)    nobuffer=1;            shift ;;
			--panel)        preset="panel";        shift ;;
			--auto-cert)    cert_mode="acme";      shift ;;
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
	[[ -f "$(site_file "$domain")" ]] && die "$domain already exists. Remove it first: $SELF_NAME del $domain"
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

	local tls_block="" kind; kind="$(cert_kind "$domain")"
	case "$cert_mode" in
		none)     info "plain HTTP, no TLS" ;;
		internal) tls_block=$'\ttls internal'; info "internal Caddy cert (browsers will warn)" ;;
		acme)     info "Caddy will request a certificate from Let's Encrypt" ;;
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
		local ind="$1" hh="$host_header"
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
		local ind="$1"
		case "$tkind" in
			files)
				printf '%sroot * %s\n'  "$ind" "$target"
				printf '%sfile_server\n' "$ind"
				;;
			redirect)
				printf '%sredir %s{uri} permanent\n' "$ind" "${target%/}"
				;;
			*) render_proxy "$ind" ;;
		esac
	}

	local f; f="$(site_file "$domain")"
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
			render_body $'\t'
		else
			echo
			render_body $'\t'
		fi
		echo "}"
	} > "$f"
	unset -f render_proxy render_body
	chown "root:$(caddy_group)" "$f" 2>/dev/null || true
	chmod 0644 "$f"
	stage_new "$f"

	if [[ -n "$paths" && $strict_path -eq 1 ]]; then
		warn "--strict-path refuses every request outside $paths"
		dim "If the app opens a websocket or loads assets from the site root,"
		dim "that traffic is now blocked. Live traffic/speed panels are the"
		dim "usual casualty. Drop --strict-path if something goes blank."
	fi

	if [[ -n "$host_header" && "$preset" == panel ]]; then
		warn "forcing the Host header on an admin panel usually breaks it"
		dim "Panels check the websocket's Origin against the Host they receive."
		dim "Sending Host: $host_header while the browser sends"
		dim "Origin: https://$domain makes that check fail, the websocket is"
		dim "refused, and live traffic/speed columns stay empty forever."
		dim "Leave the Host header blank unless this is a router or modem UI."
		ask "Drop the Host header?" y && { host_header=""; ok "Host header removed"; }
	fi

	hdr "Applying"
	apply

	if { [[ "$cert_mode" == "auto" && "$kind" == "none" ]]; } || [[ "$cert_mode" == "acme" ]]; then
		printf '%s[info]%s waiting for certificate issuance' "$C_INF" "$C_OFF"
		local i
		for i in $(seq 1 30); do
			if [[ "$(cert_kind "$domain")" != "none" ]]; then
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

	local target; target=$(grep -oP 'reverse_proxy \K[^ {]+' "$f" | head -1 || echo "?")
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
	caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && systemctl reload caddy 2>/dev/null \
		&& ok "Caddy reloaded" || warn "reload still failing - run '$SELF_NAME doctor'"
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
		t=$(grep -oP 'reverse_proxy \K(https?://)?[^ {]+' "$f" | head -1 || true)
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

	hdr "2  Caddy service"
	if systemctl is-active caddy >/dev/null 2>&1; then ok "running"
	else warn "not running"; dim "journalctl -u caddy -n 30 --no-pager"; fi
	if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then ok "config is valid"
	else
		warn "config is invalid:"
		caddy validate --config "$CADDYFILE" 2>&1 | grep -i error | head -8 | sed 's/^/       /'
	fi

	hdr "3  File permissions"
	if [[ -f "$CADDYFILE" ]]; then
		dim "$(stat -c '%A %U:%G  %n' "$CADDYFILE")"
		if caddy_can_read "$CADDYFILE"; then ok "user '$CADDY_USER' can read the config"
		else
			warn "user '$CADDY_USER' CANNOT read the config - every reload will fail"
			dim "fix: $SELF_NAME repair"
		fi
	fi

	hdr "4  bind directives"
	if [[ -z "$FRONT_IP" ]]; then
		info "FRONT_IP not set - fine on a single-IP host, dangerous otherwise"
	elif find_unbound_blocks; then
		warn "the blocks above have no 'bind' - they will collide on :80/:443"
		dim "fix: $SELF_NAME fixbind"
	else
		ok "all blocks bound to $FRONT_IP"
	fi

	hdr "5  certbot certificate access"
	if [[ -d /etc/letsencrypt/archive ]]; then
		if caddy_can_read /etc/letsencrypt/archive; then ok "user '$CADDY_USER' can read them"
		else
			warn "user '$CADDY_USER' cannot read certbot certs"
			dim "fix: $SELF_NAME repair"
		fi
	else
		dim "certbot not present on this host"
	fi

	hdr "6  WebSocket support"
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

	hdr "7  Xray fallbacks"
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

	hdr "8  Sites"
	cmd_list

	hdr "9  DNS"
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

	hdr "10  Recent Caddy errors"
	journalctl -u caddy --since "1 hour ago" --no-pager 2>/dev/null \
		| grep -iE '"level":"error"|denied|already in use' | tail -5 | sed 's/^/       /' \
		|| dim "(none in the last hour)"
	echo
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
import time
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

HOST = os.environ.get("SMART_CADDY_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("SMART_CADDY_UI_PORT", "9797"))
SITES_DIR = os.environ.get("SMART_CADDY_SITES", "/etc/caddy/sites.d")
CLI = shutil.which("smart-caddy") or "/usr/local/bin/smart-caddy"
CONF = "/etc/smart-caddy.conf"
AUTH_FILE = os.environ.get("SMART_CADDY_PANEL_AUTH", "/etc/smart-caddy-panel.json")
VERSION = "1.4.0"

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

        m = re.search(r"reverse_proxy\s+((?:https?://)?[\w.\-]+:\d+)", text)
        target = m.group(1) if m else "?"

        # Either an enforced matcher (--strict-path) or a recorded base path.
        m = re.search(r"^\s*(?:@app path|# app base path:)\s+(.+)$", text, re.M)
        paths = []
        if m:
            for tok in m.group(1).split():
                if not tok.endswith("/*") and tok not in paths:
                    paths.append(tok)
        strict = "@app path" in text

        cert, expires = "auto", None
        m = re.search(r"^\s*tls\s+(/\S+)\s", text, re.M)
        if "tls internal" in text:
            cert = "internal"
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

        sites.append({
            "domain": domain,
            "target": target,
            "paths": paths,
            "cert": cert,
            "expires": expires,
            "insecure": "tls_insecure_skip_verify" in text,
            "nobuffer": "flush_interval -1" in text,
            "strict_path": strict,
            "host_header": (re.search(r"header_up Host (\S+)", text) or [None, ""])[1],
        })
    return sites


def caddy_running():
    try:
        return subprocess.run(["systemctl", "is-active", "--quiet", "caddy"],
                              timeout=5).returncode == 0
    except Exception:
        return False


def run_cli(args, timeout=120):
    """Run the smart-caddy CLI. argv list only - never a shell string."""
    try:
        p = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=timeout)
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
            if n <= 0 or n > 65536:
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
                "sites": read_sites(),
            })
        if path == "/api/doctor":
            return self.send_json(run_cli(["doctor"]))
        self.send_json({"error": "not found"}, 404)

    def do_add(self, data, prefix=""):
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

        if data.get("panel"):       args.append("--panel")
        if data.get("insecure"):    args.append("--insecure")
        if data.get("nobuffer"):    args.append("--no-buffer")
        if data.get("self_signed"): args.append("--self-signed")
        if data.get("no_tls"):      args.append("--no-tls")

        r = run_cli(args)
        if prefix:
            r["out"] = prefix + r["out"]
        return self.send_json(r)

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
            # Caddy site files are whole-file; editing one means replacing it.
            # Keep the certificate so the domain does not go through issuance
            # again, then re-add with the new settings.
            domain = str(data.get("domain", "")).strip().lower()
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            gone = run_cli(["del", domain, "--yes", "--keep-cert"])
            if not gone["ok"]:
                return self.send_json(gone)
            self.path = "/api/add"
            return self.do_add(data, prefix=gone["out"] + "\n")

        if path == "/api/del":
            domain = str(data.get("domain", "")).strip().lower()
            if not RE_DOMAIN.match(domain):
                return self.send_json({"ok": False, "out": "invalid domain"}, 400)
            args = ["del", domain, "--yes",
                    "--purge-cert" if data.get("purge_cert") else "--keep-cert"]
            return self.send_json(run_cli(args))

        if path == "/api/fixbind":
            return self.send_json(run_cli(["fixbind"]))
        if path == "/api/repair":
            return self.send_json(run_cli(["repair"]))

        self.send_json({"error": "not found"}, 404)


LOGIN_PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>smart-caddy</title>
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
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px 16px;
  background:var(--bg);color:var(--ink);
  font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
  padding:30px 28px;width:100%;max-width:370px;
  box-shadow:0 1px 2px rgba(0,0,0,.05),0 12px 32px rgba(0,0,0,.07)}
.mark{display:flex;align-items:center;gap:9px;margin-bottom:22px}
.mark svg{flex:none}
h1{font-size:17px;margin:0;letter-spacing:-.01em}
.host{font-size:12.5px;color:var(--mut);margin-top:1px}
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
    <div>
      <h1>smart-caddy</h1>
      <div class="host" id="host"></div>
    </div>
  </div>

  <label for="u">Username</label>
  <input id="u" name="username" autocomplete="username" autofocus required>

  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" required>

  <p class="err" id="err"></p>
  <button type="submit" id="b">Sign in</button>
  <p class="foot">Reverse proxy management</p>
</form>

<script>
document.getElementById('host').textContent = location.host;
const f = document.getElementById('f'), b = document.getElementById('b'),
      err = document.getElementById('err');
f.onsubmit = async e => {
  e.preventDefault();
  err.textContent = '';
  b.disabled = true; b.textContent = 'Signing in…';
  try{
    const r = await fetch('/api/login', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({user: u.value, password: p.value})
    });
    const d = await r.json();
    if (d.ok) { location.reload(); return; }
    err.textContent = d.out || 'Sign in failed';
  } catch(_) {
    err.textContent = 'Could not reach the server';
  }
  b.disabled = false; b.textContent = 'Sign in';
  p.value = ''; p.focus();
};
</script>
</body>
</html>
"""

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>smart-caddy</title>
<style>
:root{
  --bg:#f6f7f9; --card:#fff; --ink:#16181d; --mut:#6b7280; --line:#e4e6eb;
  --acc:#2f6f4f; --acc-ink:#fff; --bad:#b3261e; --warn:#8a5a00; --ok:#1f7a4d;
  --radius:10px;
}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --bg:#0f1114; --card:#171a1f; --ink:#e8eaed; --mut:#9aa0a6; --line:#2a2e35;
  --acc:#4e9b74; --acc-ink:#07120c; --bad:#f2b8b5; --warn:#e3b341; --ok:#6cc48f;
}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:24px 16px 64px}
header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:6px}
h1{font-size:20px;margin:0;letter-spacing:-.01em}
.sub{color:var(--mut);font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  padding:18px;margin-top:16px}
h2{font-size:14px;margin:0 0 14px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut)}
.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:3px 9px;
  border-radius:99px;border:1px solid var(--line);color:var(--mut)}
.dot{width:7px;height:7px;border-radius:99px;background:var(--mut)}
.dot.up{background:var(--ok)} .dot.down{background:var(--bad)}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;
  letter-spacing:.06em;color:var(--mut);padding:0 10px 8px 0;border-bottom:1px solid var(--line)}
td{padding:11px 10px 11px 0;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
code{font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
  background:color-mix(in srgb,var(--ink) 7%,transparent);padding:1px 5px;border-radius:4px}
.dom{font-weight:600}
.dom a{color:inherit;text-decoration:none;border-bottom:1px solid var(--line)}
.dom a:hover{border-color:var(--acc)}
.tag{font-size:11px;padding:2px 7px;border-radius:5px;border:1px solid var(--line);
  color:var(--mut);margin-right:4px;display:inline-block}
.tag.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 40%,transparent)}
.tag.warn{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 40%,transparent)}
form{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}
label{display:block;font-size:12px;color:var(--mut);margin-bottom:5px}
input[type=text]{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:7px;
  background:var(--bg);color:var(--ink);font:inherit;font-size:14px}
input[type=text]:focus{outline:2px solid color-mix(in srgb,var(--acc) 45%,transparent);
  outline-offset:1px;border-color:var(--acc)}
.hint{font-size:11.5px;color:var(--mut);margin-top:5px;line-height:1.45}
.checks{grid-column:1/-1;display:flex;gap:18px;flex-wrap:wrap;padding-top:2px}
.checks label{display:flex;align-items:flex-start;gap:7px;font-size:13px;color:var(--ink);
  margin:0;cursor:pointer;max-width:290px}
.checks input{margin:3px 0 0}
.checks .hint{margin:2px 0 0}
.row{grid-column:1/-1;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
button{font:inherit;font-size:14px;padding:9px 16px;border-radius:7px;border:1px solid var(--line);
  background:var(--card);color:var(--ink);cursor:pointer}
button:hover{border-color:var(--acc)}
button.primary{background:var(--acc);color:var(--acc-ink);border-color:var(--acc);font-weight:600}
button.primary:hover{filter:brightness(1.08)}
button.link{border:0;background:0;color:var(--mut);padding:4px 6px;font-size:13px}
button.link:hover{color:var(--bad)}
button:disabled{opacity:.5;cursor:default}
pre{background:color-mix(in srgb,var(--ink) 6%,transparent);padding:16px 18px;
  border:1px solid var(--line);border-radius:8px;
  font:12.5px/1.8 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;
  word-break:normal;overflow-wrap:anywhere;max-height:420px;overflow:auto;margin:0}
pre .ln-ok{color:var(--ok)}   pre .ln-warn{color:var(--warn)}
pre .ln-bad{color:var(--bad)} pre .ln-dim{color:var(--mut)}
pre .ln-hdr{color:var(--ink);font-weight:600;display:inline-block;margin-top:6px}
.empty{color:var(--mut);font-size:14px;padding:18px 0}
.toast{position:fixed;left:50%;transform:translateX(-50%);bottom:24px;z-index:9;
  background:var(--card);border:1px solid var(--line);border-left:3px solid var(--acc);
  border-radius:8px;padding:11px 16px;font-size:14px;max-width:min(560px,92vw);
  box-shadow:0 8px 28px rgba(0,0,0,.16)}
.toast.bad{border-left-color:var(--bad)}
@media(max-width:640px){
  th:nth-child(3),td:nth-child(3){display:none}
  .wrap{padding:16px 16px 56px}
}
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1>smart-caddy</h1>
  <span class="pill"><span class="dot" id="dot"></span><span id="status">checking</span></span>
  <span class="sub" id="meta"></span>
  <button class="link" id="btn-out" style="margin-left:auto">Sign out</button>
</header>

<div class="card">
  <h2>Sites</h2>
  <div id="sites"><div class="empty">Loading&hellip;</div></div>
</div>

<div class="card">
  <h2 id="form-title">Add a site</h2>
  <form id="add" autocomplete="off">
    <div>
      <label for="f-domain">Domain</label>
      <input type="text" id="f-domain" placeholder="panel.example.com" required>
      <div class="hint">Its A record must point at this server, with any CDN
        or cloud proxy turned off.</div>
    </div>
    <div>
      <label for="f-target">Backend</label>
      <input type="text" id="f-target" placeholder="54321" required>
      <div class="hint"><code>54321</code> a local port &middot;
        <code>https://127.0.0.1:27389</code> if it speaks TLS &middot;
        <code>/var/www/site</code> to serve files &middot;
        <code>example.com</code> to proxy another site &middot;
        <code>redirect:https://x.com</code> to send visitors away.</div>
    </div>
    <div>
      <label for="f-path">Path prefix <span style="opacity:.6">(optional)</span></label>
      <input type="text" id="f-path" placeholder="/5wSobQvUFuNy4zBUcc">
      <div class="hint">For panels that live under a secret path. Everything
        else on the domain returns 404.</div>
    </div>
    <div>
      <label for="f-host">Host header <span style="opacity:.6">(optional)</span></label>
      <input type="text" id="f-host" placeholder="127.0.0.1">
      <div class="hint">Routers and modems usually need <code>127.0.0.1</code>.</div>
    </div>

    <div class="checks">
      <label><input type="checkbox" id="f-panel" checked>
        <span>Admin panel<div class="hint">Skips backend cert checks and turns
          off buffering, so live stats update.</div></span></label>
      <label><input type="checkbox" id="f-notls">
        <span>Plain HTTP<div class="hint">No certificate at all.</div></span></label>
    </div>

    <div class="row">
      <button type="submit" class="primary" id="btn-add">Add site</button>
      <button type="button" class="link" id="btn-cancel" hidden>Cancel</button>
      <button type="button" class="link" id="btn-doctor">Run diagnostics</button>
    </div>
  </form>
</div>

<div class="card" id="out-card" hidden>
  <h2 id="out-title">Output</h2>
  <pre id="out"></pre>
</div>

</div>

<script>
const $ = s => document.querySelector(s);
let busy = false;
let SITES = [];
let EDITING = null;   // domain being edited, null while adding

function toast(msg, bad){
  document.querySelectorAll('.toast').forEach(t => t.remove());
  const t = document.createElement('div');
  t.className = 'toast' + (bad ? ' bad' : '');
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 5200);
}

// Colour the CLI output the way a terminal does, so a wall of text reads as
// a list of outcomes rather than a paragraph.
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

function show(title, text){
  $('#out-title').textContent = title;
  $('#out').innerHTML = text ? paint(text) : '(no output)';
  $('#out-card').hidden = false;
  $('#out-card').scrollIntoView({behavior:'smooth', block:'nearest'});
}

async function api(path, body){
  const r = await fetch(path, body ? {
    method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)
  } : {});
  if (r.status === 401) { location.reload(); return {}; }   // session expired
  return r.json();
}

function certTag(s){
  if (s.cert === 'pending') return '<span class="tag warn">no cert yet</span>';
  if (s.cert === 'internal') return '<span class="tag warn">self-signed</span>';
  const exp = s.expires ? ' &middot; ' + s.expires.replace(/ GMT$/,'') : '';
  return '<span class="tag ok">' + s.cert + exp + '</span>';
}

async function load(){
  const d = await api('/api/state');
  $('#dot').className = 'dot ' + (d.caddy_running ? 'up' : 'down');
  $('#status').textContent = d.caddy_running ? 'Caddy running' : 'Caddy down';
  $('#meta').textContent = 'v' + d.version + (d.front_ip ? ' · ' + d.front_ip : '');

  if (!d.sites.length){
    $('#sites').innerHTML = '<div class="empty">No sites yet. Add one below.</div>';
    return;
  }

  SITES = d.sites;
  let h = '<table><thead><tr><th>Domain</th><th>Backend</th>'
        + '<th>Notes</th><th></th></tr></thead><tbody>';
  for (let i = 0; i < d.sites.length; i++){
    const s = d.sites[i];
    const p = s.paths.length ? s.paths[0] : '';
    const url = 'https://' + s.domain + p + (p ? '/' : '');
    let notes = certTag(s);
    if (s.paths.length)  notes += '<span class="tag">path ' + esc(p) + '</span>';
    if (s.nobuffer)      notes += '<span class="tag">unbuffered</span>';
    if (s.insecure)      notes += '<span class="tag">insecure upstream</span>';
    h += '<tr>'
      +  '<td class="dom"><a href="' + esc(url) + '" target="_blank" rel="noopener">'
      +  esc(s.domain) + '</a></td>'
      +  '<td><code>' + esc(s.target) + '</code></td>'
      +  '<td>' + notes + '</td>'
      +  '<td style="text-align:right;white-space:nowrap">'
      +  '<button class="link edit" data-i="' + i + '">Edit</button>'
      +  '<button class="link" data-del="' + esc(s.domain) + '">Remove</button></td>'
      +  '</tr>';
  }
  $('#sites').innerHTML = h + '</tbody></table>';

  document.querySelectorAll('[data-del]').forEach(b => {
    b.onclick = () => remove(b.dataset.del);
  });
  document.querySelectorAll('.edit').forEach(b => {
    b.onclick = () => startEdit(SITES[+b.dataset.i]);
  });
}

function esc(s){
  return String(s).replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

async function remove(domain){
  if (busy) return;
  if (!confirm('Stop serving ' + domain + '?\n\nIts certificate is kept, so adding it back later is instant.')) return;
  busy = true;
  const r = await api('/api/del', {domain, purge_cert:false});
  busy = false;
  toast(r.ok ? domain + ' removed' : 'Could not remove ' + domain, !r.ok);
  show('Remove ' + domain, r.out);
  load();
}

function startEdit(s){
  EDITING = s.domain;
  $('#f-domain').value  = s.domain;
  $('#f-target').value  = s.target;
  $('#f-path').value    = s.paths.length ? s.paths[0] : '';
  $('#f-host').value    = (s.host_header && s.host_header !== '{host}') ? s.host_header : '';
  $('#f-panel').checked = !!(s.insecure || s.nobuffer);
  $('#f-notls').checked = false;
  $('#f-domain').readOnly = true;
  $('#form-title').textContent = 'Edit ' + s.domain;
  $('#btn-add').textContent = 'Save changes';
  $('#btn-cancel').hidden = false;
  $('#add').scrollIntoView({behavior:'smooth', block:'center'});
  $('#f-target').focus();
}

function stopEdit(){
  EDITING = null;
  $('#add').reset();
  $('#f-panel').checked = true;
  $('#f-domain').readOnly = false;
  $('#form-title').textContent = 'Add a site';
  $('#btn-add').textContent = 'Add site';
  $('#btn-cancel').hidden = true;
}

$('#btn-cancel').onclick = stopEdit;

$('#add').onsubmit = async e => {
  e.preventDefault();
  if (busy) return;
  const body = {
    domain: $('#f-domain').value.trim(),
    target: $('#f-target').value.trim(),
    paths: $('#f-path').value.trim() ? [$('#f-path').value.trim()] : [],
    host_header: $('#f-host').value.trim(),
    panel: $('#f-panel').checked,
    no_tls: $('#f-notls').checked
  };
  const editing = EDITING;
  busy = true;
  $('#btn-add').disabled = true;
  const was = $('#btn-add').textContent;
  $('#btn-add').textContent = 'Working\u2026';
  const r = await api(editing ? '/api/edit' : '/api/add', body);
  $('#btn-add').disabled = false;
  $('#btn-add').textContent = was;
  busy = false;

  toast(r.ok ? body.domain + (editing ? ' updated' : ' is live')
             : 'Failed - see the output below', !r.ok);
  show((editing ? 'Edit ' : 'Add ') + body.domain, r.out);
  if (r.ok) stopEdit();
  load();
};

$('#btn-out').onclick = async () => {
  await api('/api/logout', {});
  location.reload();
};

$('#btn-doctor').onclick = async () => {
  if (busy) return;
  busy = true;
  show('Diagnostics', 'Running…');
  const r = await api('/api/doctor');
  busy = false;
  show('Diagnostics', r.out);
};

load();
setInterval(() => { if (!busy) load(); }, 20000);
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
	if [[ "$newv" == "$VERSION" ]]; then
		ok "already on v$VERSION - nothing to do"
		rm -f "$tmp"; return 0
	fi
	ok "v$VERSION -> v${newv:-?}"

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
	# First bare argument is the domain; everything else is a flag.
	if [[ -n "${1:-}" && "${1:0:1}" != "-" ]]; then domain="$1"; shift; fi
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--user)     user="${2:?}";            shift 2 ;;
			--port)     port="${2:?}";            shift 2 ;;
			--password) pass="${2:?}";            shift 2 ;;
			--ui)       UI_SRC_OVERRIDE="${2:?}"; shift 2 ;;
			--yes|-y)   ASSUME_YES=1;             shift ;;
			*) die "unknown option: $1" ;;
		esac
	done

	have python3 || die "python3 is required for the web panel"

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

	hdr "4/6  Certificate"
	local tls_block=""
	if [[ -f "$(certbot_cert "$domain")" ]]; then
		tls_block=$'\ttls '"$(certbot_cert "$domain") $(certbot_key "$domain")"
		ok "reusing the existing certbot certificate"
	else
		info "Caddy will obtain a certificate after reload"
	fi

	hdr "5/6  Caddy site"
	local f; f="$(site_file "$domain")"
	[[ -f "$f" ]] && stage_edit "$f" || stage_new "$f"
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
	} > "$f"
	chown "root:$(caddy_group)" "$f" 2>/dev/null || true
	chmod 0644 "$f"
	apply

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
  sudo bash $0 setup

${C_B}COMMANDS${C_OFF}
  setup                                    one command: installs Caddy if
                                           needed, then asks its way through
                                           the whole thing
  install [--ip <IP>] [--email <mail>]     just the system wiring
  add <domain> <port|host:port> [opts]     add a domain (automatic TLS)
  del <domain> [--keep-cert|--purge-cert]  remove a domain
  del-cert <domain>                        remove only the certificate
  list                                     list domains and certificates
  panel <domain> [--user u] [--port n]     install the web UI at that domain
  panel status | panel remove [<domain>]   check or remove the web UI
  passwd [user] [--password <p>]           change the panel password
  update                                   fetch and install the latest release
  doctor                                   full diagnostic
  fixbind                                  add 'bind' to blocks missing it
  repair                                   fix file permissions and reload
  uninstall                                remove integration (certs kept)

${C_B}ADD OPTIONS${C_OFF}
  --path <prefix>      record the app's base path (shown in 'list'); repeatable
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
  --auto-cert          request a new cert even if certbot already has one
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
		setup)             cmd_setup "$@" ;;
		install)           cmd_install "$@" ;;
		add)               cmd_add "$@" ;;
		del|rm|remove)     cmd_del "$@" ;;
		del-cert)          cmd_del_cert "$@" ;;
		list|ls)           cmd_list ;;
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
			if [[ -r "$CONF_FILE" ]]; then
				usage
				echo
				ok "this machine is already set up ($CONF_FILE)"
				dim "$SELF_NAME list     what you have"
				dim "$SELF_NAME doctor   check it over"
				dim "$SELF_NAME setup    run setup again"
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
