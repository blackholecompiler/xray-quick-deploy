#!/usr/bin/env bash
# xray-up-marker (do not remove: the script uses this line to recognise itself)
#
# xray-up: one-shot Xray deployment for a clean Debian 12/13 VPS.
#
#   - Xray-core (pinned release, checksum-verified) as a systemd service
#   - one VLESS + REALITY inbound (XHTTP by default, raw TCP + Vision optional), one user
#   - a sudo user with a random password, root SSH login disabled, SSH on a new port
#   - nftables firewall (only SSH and the Xray port are reachable)
#   - automatic security updates (unattended-upgrades)
#
# First run (as root):   bash xray-up.sh --sni www.example.com
# Later (as the admin):  sudo xray-up --show | --rotate | --upgrade
#
# Run "bash xray-up.sh --help" for all options.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
XRAY_VERSION_DEFAULT="v26.11.9"   # tested with this script; override with --xray-version

# Transport for new deployments. Deliberately not a command-line option.
#   xhttp  VLESS + XHTTP + REALITY, random path, no flow (Vision does not work over XHTTP)
#   raw    VLESS + raw TCP + REALITY + xtls-rprx-vision
# Existing servers keep the transport they were deployed with (it is in the state file).
TRANSPORT=xhttp

# Extra geodata files, installed next to the geoip.dat/geosite.dat that ship with Xray.
# Reference them in the config as "ext:<file>:<list>", e.g. "ext:geosite_ru.dat:category-ads-all".
# Using the name geoip.dat or geosite.dat replaces the bundled file instead.
# Format: "<installed file name>|<https URL>". "<URL>.sha256sum" must exist and is verified.
# Downloaded on the first run and again on every --upgrade.
GEO_EXTRA=(
	"geosite_RU.dat|https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
	"geoip_RU.dat|https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
)

XRAY_BIN=/usr/local/bin/xray
XRAY_ETC=/usr/local/etc/xray
XRAY_CONF=$XRAY_ETC/config.json
XRAY_SHARE=/usr/local/share/xray
XRAY_UNIT=/etc/systemd/system/xray.service
XRAY_USER=xray

STATE_DIR=/etc/xray-up
STATE_FILE=$STATE_DIR/state
SELF_PATH=/usr/local/sbin/xray-up
LOG_FILE=/var/log/xray-up.log

SSHD_MAIN=/etc/ssh/sshd_config
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
SSHD_DROPIN=$SSHD_DROPIN_DIR/00-xray-up.conf
SSHD_BACKUP=$SSHD_MAIN.xray-up.bak

NFT_CONF=/etc/nftables.conf
NFT_MARKER="# Managed by xray-up"

# Options (empty = not given on the command line)
MODE=install
SNI=""
PORT=""
UUID=""
NAME=""
HOST=""
ADMIN_USER=""
SSH_PORT=""
PUBKEY=""
XRAY_VERSION=""
OPT_FIREWALL=1
OPT_AUTO_REBOOT=1
OPT_SNI_CHECK=1
OPT_QR=0

# Runtime values
NET=""             # transport of this server: xhttp | raw
XHTTP_PATH=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
ADMIN_PASS=""
SSH_AUTH="password"
FIREWALL_STATE="not configured"
WORK_DIR=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
	if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
		rm -rf "$WORK_DIR"
	fi
}

on_error() {
	local rc=$1 line=$2 cmd=$3
	printf 'ERROR: command failed (exit %s) at line %s: %s\n' "$rc" "$line" "$cmd" >&2
	printf 'ERROR: details may be in %s\n' "$LOG_FILE" >&2
	exit "$rc"
}

usage() {
	cat <<EOF
xray-up: one-shot Xray (VLESS + REALITY, $TRANSPORT) deployment for clean Debian 12/13.

First run, as root:
  bash xray-up.sh --sni DOMAIN [options]

Options for the first run:
  --sni DOMAIN          REQUIRED. Real third-party HTTPS site that REALITY borrows
                        the TLS handshake from. Must support TLS 1.3.
  --port N              Xray listen port (default: 443)
  --uuid UUID           Client UUID (default: generated)
  --name LABEL          Label shown in the client app (default: xray-up)
  --host ADDR           Address put into the link (default: detected public IPv4)
  --user NAME           Admin user to create (default: vpsadmin)
  --ssh-port N          New SSH port (default: random, 10000-32767)
  --pubkey "KEY"        SSH public key for the admin user. If given, SSH password
                        logins are disabled entirely.
  --xray-version V      Xray release tag, or "latest" (default: $XRAY_VERSION_DEFAULT)
  --no-firewall         Do not configure nftables
  --no-auto-reboot      Do not reboot automatically after kernel updates
  --skip-sni-check      Do not test the --sni domain from this server
  --qr                  Also print the link as a QR code (installs qrencode)

After the first run (sudo xray-up ...):
  --show                Print the connection link and server details again
  --rotate              New UUID, REALITY keys, short ID and XHTTP path
                        (old link stops working; the transport stays the same).
                        Accepts --sni, --name, --uuid, --host.
  --upgrade             Replace the Xray binary and re-download the geodata.
                        Accepts --xray-version.
  -h, --help            This text
EOF
}

need_value() {
	if [[ $# -lt 2 || -z ${2:-} ]]; then
		die "option $1 needs a value"
	fi
}

is_port() {
	[[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_private_ipv4() {
	[[ $1 =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]
}

is_ipv4() {
	local IFS=. part
	local -a parts
	[[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	read -r -a parts <<<"$1"
	for part in "${parts[@]}"; do
		(( 10#$part <= 255 )) || return 1
	done
}

port_listening() {
	ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

wait_for_port() {
	local port=$1 tries=${2:-20} i
	for (( i = 0; i < tries; i++ )); do
		if port_listening "$port"; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}

gen_password() {
	local p=""
	while (( ${#p} < 32 )); do
		p+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
	done
	printf '%s' "${p:0:32}"
}

apt_run() {
	if ! DEBIAN_FRONTEND=noninteractive apt-get -y -q \
		-o DPkg::Lock::Timeout=180 \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold \
		"$@" >>"$LOG_FILE" 2>&1; then
		return 1
	fi
}

apt_install() {
	if ! apt_run install --no-install-recommends "$@"; then
		tail -n 25 "$LOG_FILE" >&2 || true
		die "apt-get install failed for: $* (full log: $LOG_FILE)"
	fi
}

# ----------------------------------------------------------------------------
# Argument parsing and validation
# ----------------------------------------------------------------------------
parse_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
			--sni)            need_value "$@"; SNI=$2; shift 2 ;;
			--port)           need_value "$@"; PORT=$2; shift 2 ;;
			--uuid)           need_value "$@"; UUID=$2; shift 2 ;;
			--name)           need_value "$@"; NAME=$2; shift 2 ;;
			--host)           need_value "$@"; HOST=$2; shift 2 ;;
			--user)           need_value "$@"; ADMIN_USER=$2; shift 2 ;;
			--ssh-port)       need_value "$@"; SSH_PORT=$2; shift 2 ;;
			--pubkey)         need_value "$@"; PUBKEY=$2; shift 2 ;;
			--xray-version)   need_value "$@"; XRAY_VERSION=$2; shift 2 ;;
			--no-firewall)    OPT_FIREWALL=0; shift ;;
			--no-auto-reboot) OPT_AUTO_REBOOT=0; shift ;;
			--skip-sni-check) OPT_SNI_CHECK=0; shift ;;
			--qr)             OPT_QR=1; shift ;;
			--show)           MODE=show; shift ;;
			--rotate)         MODE=rotate; shift ;;
			--upgrade)        MODE=upgrade; shift ;;
			-h|--help)        usage; exit 0 ;;
			*)                die "unknown option: $1 (see --help)" ;;
		esac
	done
}

validate_sni() {
	[[ ${#SNI} -le 253 && $SNI =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
		|| die "--sni must be a plain domain name such as www.example.com (got: $SNI)"
	SNI=${SNI,,}
}

validate_common() {
	if [[ -n $UUID ]]; then
		[[ $UUID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
			|| die "--uuid is not a valid UUID: $UUID"
		UUID=${UUID,,}
	fi
	if [[ -n $NAME ]]; then
		[[ $NAME =~ ^[A-Za-z0-9._-]{1,32}$ ]] \
			|| die "--name may only contain letters, digits, dot, underscore, dash (max 32)"
	fi
	if [[ -n $HOST ]]; then
		[[ $HOST =~ ^[A-Za-z0-9.:-]{1,253}$ ]] || die "--host is not a valid address: $HOST"
	fi
	if [[ -n $XRAY_VERSION ]]; then
		[[ $XRAY_VERSION == latest || $XRAY_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
			|| die "--xray-version must look like v26.11.9, or be \"latest\""
	fi
}

validate_install_args() {
	[[ -n $SNI ]] || die "--sni is required (see --help)"
	validate_sni
	PORT=${PORT:-443}
	NAME=${NAME:-xray-up}
	ADMIN_USER=${ADMIN_USER:-vpsadmin}
	XRAY_VERSION=${XRAY_VERSION:-$XRAY_VERSION_DEFAULT}
	validate_common

	is_port "$PORT" || die "--port must be 1-65535"
	PORT=$(( 10#$PORT ))

	[[ $ADMIN_USER =~ ^[a-z][a-z0-9_-]{0,30}$ ]] \
		|| die "--user must start with a lowercase letter and contain only a-z, 0-9, _ and -"
	[[ $ADMIN_USER != root && $ADMIN_USER != "$XRAY_USER" ]] \
		|| die "--user cannot be \"$ADMIN_USER\""

	if [[ -n $SSH_PORT ]]; then
		is_port "$SSH_PORT" || die "--ssh-port must be 1-65535"
		SSH_PORT=$(( 10#$SSH_PORT ))
		[[ $SSH_PORT -ne $PORT ]] || die "--ssh-port and --port must differ"
	fi

	if [[ -n $PUBKEY ]]; then
		[[ $PUBKEY != *$'\n'* ]] || die "--pubkey must be a single line"
		[[ $PUBKEY =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
			|| die "--pubkey must be one OpenSSH public key line (ssh-ed25519 AAAA... comment)"
		SSH_AUTH="key"
	fi
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
preflight() {
	local os_id os_ver
	[[ $EUID -eq 0 ]] || die "run this as root (after the first run: sudo xray-up ...)"
	[[ -r /etc/os-release ]] || die "/etc/os-release not found; this script supports Debian only"
	# Parsed, not sourced: os-release defines NAME, VERSION etc., which would clobber ours.
	os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -n 1)
	os_ver=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -n 1)
	[[ $os_id == debian ]] || die "this script supports Debian only (found: ${os_id:-unknown})"
	case $os_ver in
		12|13) ;;
		*) warn "tested on Debian 12 and 13; this is Debian ${os_ver:-unknown}, continuing anyway" ;;
	esac
	[[ -d /run/systemd/system ]] || die "systemd is not running; cannot continue"
	[[ $TRANSPORT == xhttp || $TRANSPORT == raw ]] \
		|| die "TRANSPORT at the top of the script must be xhttp or raw (got: $TRANSPORT)"
}

xray_asset_name() {
	case $(dpkg --print-architecture) in
		amd64) printf 'Xray-linux-64.zip' ;;
		arm64) printf 'Xray-linux-arm64-v8a.zip' ;;
		*)     die "unsupported CPU architecture: $(dpkg --print-architecture) (amd64 and arm64 only)" ;;
	esac
}

# ----------------------------------------------------------------------------
# Packages and automatic updates
# ----------------------------------------------------------------------------
install_packages() {
	local i ok=0
	log "Updating package lists"
	# A freshly booted VM may still be running its own first apt job; retry on lock errors.
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if apt_run update; then
			ok=1
			break
		fi
		sleep 6
	done
	if [[ $ok -ne 1 ]]; then
		tail -n 25 "$LOG_FILE" >&2 || true
		die "apt-get update failed (full log: $LOG_FILE)"
	fi

	log "Installing packages"
	apt_install ca-certificates curl unzip openssl sudo openssh-server iproute2 unattended-upgrades
	if [[ $OPT_FIREWALL -eq 1 ]]; then
		apt_install nftables
	fi
	if [[ $OPT_QR -eq 1 ]]; then
		apt_install qrencode
	fi
}

setup_auto_updates() {
	log "Enabling automatic security updates"
	cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Managed by xray-up
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
	if [[ $OPT_AUTO_REBOOT -eq 1 ]]; then
		cat >/etc/apt/apt.conf.d/52xray-up-unattended <<'EOF'
// Managed by xray-up
// Reboot on its own when an update (in practice: a new kernel) requires it.
// The time is the server's local time.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
	else
		rm -f /etc/apt/apt.conf.d/52xray-up-unattended
	fi
	systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >>"$LOG_FILE" 2>&1 \
		|| warn "could not enable the apt timers; automatic updates may not run"
}

# ----------------------------------------------------------------------------
# REALITY target check
# ----------------------------------------------------------------------------
check_sni() {
	local out
	log "Checking that $SNI works as a REALITY target (TLS 1.3 from this server)"
	if ! out=$(timeout 20 openssl s_client -connect "$SNI:443" -servername "$SNI" \
		-tls1_3 -groups X25519 -alpn h2,http/1.1 </dev/null 2>&1); then
		die "could not complete a TLS 1.3 handshake with $SNI:443 from this server. Pick another --sni, or pass --skip-sni-check to ignore."
	fi
	grep -q 'TLSv1\.3' <<<"$out" \
		|| die "$SNI did not negotiate TLS 1.3, so it cannot be a REALITY target. Pick another --sni."
	if grep -q 'ALPN protocol: h2' <<<"$out"; then
		:
	elif grep -q 'ALPN protocol:' <<<"$out"; then
		warn "$SNI does not offer HTTP/2; it works, but an h2-capable site is a better REALITY target"
	else
		die "$SNI does not negotiate ALPN at all, and REALITY handshakes fail against such a target. Pick another --sni."
	fi
	if ! grep -Eq 'Verify return code: 0 \(ok\)|Verification: OK' <<<"$out"; then
		warn "the certificate of $SNI did not verify from this server; double-check the domain"
	fi
}

# ----------------------------------------------------------------------------
# Xray
# ----------------------------------------------------------------------------
resolve_latest() {
	# Turn "latest" into a concrete tag, so the archive and its checksum file are
	# guaranteed to come from the same release. GitHub answers
	# .../releases/latest/download/<asset> with a redirect to .../releases/download/<tag>/<asset>.
	local asset=$1 loc tag
	loc=$(curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 -o /dev/null -w '%{redirect_url}' \
		"https://github.com/XTLS/Xray-core/releases/latest/download/$asset.dgst") \
		|| die "could not reach GitHub to look up the latest Xray release"
	tag=$(sed -n 's#.*/releases/download/\(v[0-9][0-9.]*\)/.*#\1#p' <<<"$loc")
	[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "could not work out the latest Xray release (redirect: ${loc:-none}); pass --xray-version"
	XRAY_VERSION=$tag
}

fetch_geodata() {
	# Downloads and verifies every GEO_EXTRA entry into $WORK_DIR/xray/.
	local entry file url expected actual
	for entry in "${GEO_EXTRA[@]}"; do
		file=${entry%%|*}
		url=${entry#*|}
		[[ $entry == *'|'* && $file =~ ^[A-Za-z0-9._-]+\.dat$ && $url =~ ^https://[^[:space:]]+$ ]] \
			|| die "invalid GEO_EXTRA entry: $entry"
		log "Downloading geodata $file"
		curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK_DIR/xray/$file" "$url" \
			|| die "download failed: $url"
		curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK_DIR/$file.sha256sum" "$url.sha256sum" \
			|| die "download failed: $url.sha256sum"
		expected=$(awk 'NR==1 { print $1 }' "$WORK_DIR/$file.sha256sum")
		actual=$(sha256sum "$WORK_DIR/xray/$file" | awk '{ print $1 }')
		[[ $expected =~ ^[0-9a-f]{64}$ ]] || die "could not read the SHA-256 for $file"
		[[ $expected == "$actual" ]] || die "checksum mismatch for $file (expected $expected, got $actual)"
	done
}

fetch_xray() {
	# Downloads and verifies the release (plus extra geodata) into $WORK_DIR/xray/.
	local asset base expected actual
	asset=$(xray_asset_name)
	if [[ $XRAY_VERSION == latest ]]; then
		resolve_latest "$asset"
	fi
	base="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"

	log "Downloading Xray ($XRAY_VERSION, $asset)"
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK_DIR/xray.zip" "$base/$asset" \
		|| die "download failed: $base/$asset"
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK_DIR/xray.zip.dgst" "$base/$asset.dgst" \
		|| die "download failed: $base/$asset.dgst"

	expected=$(awk -F'= *' '/^SHA2-256=/ { print $2; exit }' "$WORK_DIR/xray.zip.dgst" | tr -d '[:space:]')
	actual=$(sha256sum "$WORK_DIR/xray.zip" | awk '{ print $1 }')
	[[ $expected =~ ^[0-9a-f]{64}$ ]] || die "could not read the SHA-256 from the release checksum file"
	[[ $expected == "$actual" ]] || die "checksum mismatch for $asset (expected $expected, got $actual)"

	mkdir -p "$WORK_DIR/xray"
	unzip -q -o "$WORK_DIR/xray.zip" xray geoip.dat geosite.dat -d "$WORK_DIR/xray" \
		|| die "could not unpack the Xray archive"
	chmod 0755 "$WORK_DIR/xray/xray"
	"$WORK_DIR/xray/xray" version >/dev/null || die "the downloaded Xray binary does not run on this machine"
	fetch_geodata
}

place_xray() {
	install -d -m 0755 "$XRAY_SHARE"
	install -m 0755 "$WORK_DIR/xray/xray" "$XRAY_BIN.new"
	mv -f "$XRAY_BIN.new" "$XRAY_BIN"
	install -m 0644 "$WORK_DIR"/xray/*.dat "$XRAY_SHARE/"
}

xray_version_string() {
	"$XRAY_BIN" version 2>/dev/null | awk 'NR==1 { print $2 }'
}

test_xray_config() {
	# $1 = binary, $2 = asset dir, $3 = config file
	local out
	if ! out=$(XRAY_LOCATION_ASSET=$2 "$1" run -test -config "$3" 2>&1); then
		printf '%s\n' "$out" >&2
		return 1
	fi
}

gen_xray_identity() {
	local keys check
	keys=$("$XRAY_BIN" x25519)
	# Line 1 is the private key, line 2 the public key. The labels have changed between
	# Xray versions ("Public key" / "Password" / "Password (PublicKey)"), so go by position.
	PRIVATE_KEY=$(awk 'NR==1 { print $NF }' <<<"$keys")
	PUBLIC_KEY=$(awk 'NR==2 { print $NF }' <<<"$keys")
	[[ $PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] \
		|| die "unexpected output from 'xray x25519'; cannot read the REALITY keys"
	[[ $PRIVATE_KEY != "$PUBLIC_KEY" ]] || die "unexpected output from 'xray x25519'"
	# Cross-check: deriving from the private key must give the same public key.
	check=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" | awk 'NR==2 { print $NF }')
	[[ $check == "$PUBLIC_KEY" ]] || die "REALITY key self-check failed"

	SHORT_ID=$(openssl rand -hex 8)
	[[ $SHORT_ID =~ ^[0-9a-f]{16}$ ]] || die "could not generate a short ID"

	if [[ $NET == xhttp ]]; then
		XHTTP_PATH="/$(openssl rand -hex 8)"
		[[ $XHTTP_PATH =~ ^/[0-9a-f]{16}$ ]] || die "could not generate an XHTTP path"
	else
		XHTTP_PATH=""
	fi

	if [[ -z $UUID ]]; then
		UUID=$("$XRAY_BIN" uuid)
	fi
	[[ $UUID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
		|| die "could not generate a UUID"
}

write_xray_config() {
	# Every interpolated value has been validated to a JSON-safe character set.
	local tmp=$WORK_DIR/config.json flow_json transport_json
	case $NET in
		xhttp)
			# No "flow": XTLS Vision does not work over XHTTP.
			flow_json=""
			transport_json='"network": "xhttp",
        "xhttpSettings": {
          "path": "'"$XHTTP_PATH"'",
          "mode": "auto"
        },'
			;;
		raw)
			flow_json='
            "flow": "xtls-rprx-vision",'
			transport_json='"network": "raw",'
			;;
		*) die "unknown transport: $NET" ;;
	esac
	cat >"$tmp" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",$flow_json
            "email": "$NAME"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        $transport_json
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
        {
            "domain": [
                "geosite:category-ads-all",
                "ext:geosite_RU.dat:category-ads-all",
                "ext:geosite_RU.dat:ru-available-only-inside",
                "domain:ru",
                "domain:su",
                "domain:xn--p1ai"
            ],
            "outboundTag": "block",
            "type": "field"
        },
        { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
        { "type": "field", "ip": ["geoip:private", "ext:geoip_RU.dat:ru"], "outboundTag": "block" }
    ]
  }
}
EOF
	test_xray_config "$XRAY_BIN" "$XRAY_SHARE" "$tmp" \
		|| die "Xray rejected the generated config (see the output above)"

	install -d -m 0750 -o root -g "$XRAY_USER" "$XRAY_ETC"
	install -m 0640 -o root -g "$XRAY_USER" "$tmp" "$XRAY_CONF.new"
	mv -f "$XRAY_CONF.new" "$XRAY_CONF"
}

write_xray_unit() {
	cat >"$XRAY_UNIT" <<EOF
[Unit]
Description=Xray (managed by xray-up)
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=$XRAY_USER
Group=$XRAY_USER
Environment=XRAY_LOCATION_ASSET=$XRAY_SHARE
ExecStart=$XRAY_BIN run -config $XRAY_CONF
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
}

restart_xray() {
	systemctl enable xray.service >>"$LOG_FILE" 2>&1
	systemctl restart xray.service
	if ! wait_for_port "$PORT" 20 || ! systemctl is-active --quiet xray.service; then
		journalctl -u xray.service -n 20 --no-pager >&2 || true
		return 1
	fi
}

install_xray() {
	if port_listening "$PORT" && ! systemctl is-active --quiet xray.service; then
		ss -Hltnp "sport = :$PORT" >&2 || true
		die "port $PORT is already in use by another program"
	fi

	fetch_xray
	if ! id -u "$XRAY_USER" >/dev/null 2>&1; then
		useradd --system --user-group --no-create-home --home-dir /nonexistent \
			--shell /usr/sbin/nologin "$XRAY_USER"
	fi
	place_xray
	log "Installed Xray $(xray_version_string) ($NET transport)"

	gen_xray_identity
	write_xray_config
	write_xray_unit
	log "Starting Xray on port $PORT"
	restart_xray || die "Xray did not start (see the log lines above)"
}

# ----------------------------------------------------------------------------
# Admin user
# ----------------------------------------------------------------------------
setup_admin_user() {
	local home
	if id -u "$ADMIN_USER" >/dev/null 2>&1; then
		warn "user $ADMIN_USER already exists; resetting its password and reusing it"
	else
		log "Creating user $ADMIN_USER"
		useradd --create-home --shell /bin/bash "$ADMIN_USER"
	fi
	usermod -aG sudo "$ADMIN_USER"

	ADMIN_PASS=$(gen_password)
	printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd

	if [[ -n $PUBKEY ]]; then
		printf '%s\n' "$PUBKEY" >"$WORK_DIR/pubkey"
		ssh-keygen -l -f "$WORK_DIR/pubkey" >/dev/null 2>&1 \
			|| die "--pubkey is not a valid OpenSSH public key"
		home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
		[[ -n $home && -d $home ]] || die "home directory of $ADMIN_USER not found"
		install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
		install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$WORK_DIR/pubkey" "$home/.ssh/authorized_keys"
	fi
}

# ----------------------------------------------------------------------------
# SSH
# ----------------------------------------------------------------------------
pick_ssh_port() {
	local p i
	for (( i = 0; i < 100; i++ )); do
		p=$(shuf -i 10000-32767 -n 1)
		if [[ $p -ne $PORT ]] && ! port_listening "$p"; then
			printf '%s' "$p"
			return 0
		fi
	done
	return 1
}

rollback_ssh() {
	warn "restoring the previous SSH configuration"
	rm -f "$SSHD_DROPIN"
	if [[ -f $SSHD_BACKUP ]]; then
		cp -a "$SSHD_BACKUP" "$SSHD_MAIN"
	fi
	systemctl restart ssh.service || true
}

harden_ssh() {
	local effective ports pw_want=yes

	if [[ -z $SSH_PORT ]]; then
		SSH_PORT=$(pick_ssh_port) || die "could not find a free port for SSH"
	elif port_listening "$SSH_PORT"; then
		# Fine only if it is sshd itself (e.g. --ssh-port 22).
		if ! sshd -T 2>/dev/null | grep -qx "port $SSH_PORT"; then
			die "--ssh-port $SSH_PORT is already in use by another program"
		fi
	fi
	if [[ $SSH_AUTH == key ]]; then
		pw_want=no
	fi

	log "Configuring SSH: port $SSH_PORT, user $ADMIN_USER only, root login disabled"
	if [[ ! -f $SSHD_BACKUP ]]; then
		cp -a "$SSHD_MAIN" "$SSHD_BACKUP"
	fi
	install -d -m 0755 "$SSHD_DROPIN_DIR"

	# sshd uses the first value it reads for most options, so the drop-in directory
	# has to be included before anything else in the main file.
	if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"; then
		sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_MAIN"
	fi
	# "Port" is the exception: it accumulates. Disable any Port line in the main file,
	# otherwise sshd would keep listening on the old port as well.
	sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/I' "$SSHD_MAIN"

	cat >"$SSHD_DROPIN" <<EOF
# Managed by xray-up
Port $SSH_PORT
PermitRootLogin no
AllowUsers $ADMIN_USER
PubkeyAuthentication yes
PasswordAuthentication $pw_want
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
	chmod 0644 "$SSHD_DROPIN"

	if ! sshd -t; then
		rollback_ssh
		die "sshd rejected the new configuration; nothing was changed"
	fi

	# Check what sshd will actually use, not what we wrote.
	effective=$(sshd -T 2>/dev/null) || { rollback_ssh; die "could not read the effective sshd configuration"; }
	ports=$(awk '$1 == "port" { print $2 }' <<<"$effective" | sort -u | tr '\n' ' ')
	if [[ $ports != "$SSH_PORT " ]] \
		|| ! grep -qx 'permitrootlogin no' <<<"$effective" \
		|| ! grep -qx "passwordauthentication $pw_want" <<<"$effective" \
		|| ! grep -qix "allowusers $ADMIN_USER" <<<"$effective"; then
		rollback_ssh
		die "another file in /etc/ssh overrides the SSH settings (effective ports: ${ports:-none}); nothing was changed"
	fi

	# Debian runs sshd as a plain service. If socket activation was switched on,
	# go back to the service so that the Port setting above is what counts.
	if systemctl is-active --quiet ssh.socket; then
		systemctl disable --now ssh.socket >>"$LOG_FILE" 2>&1 || true
	fi
	systemctl enable ssh.service >>"$LOG_FILE" 2>&1 || true

	# Restarting sshd does not end sessions that are already open (including this one).
	if ! systemctl restart ssh.service || ! wait_for_port "$SSH_PORT" 20; then
		rollback_ssh
		die "sshd did not come up on port $SSH_PORT; the previous configuration was restored"
	fi
}

# ----------------------------------------------------------------------------
# Firewall
# ----------------------------------------------------------------------------
setup_firewall() {
	local tmp=$WORK_DIR/nftables.conf load=$WORK_DIR/nftables.load
	local c_ip="" s_port="" fam keep_rule=""

	# Leave an existing firewall alone unless it is our own from an earlier run.
	if [[ -n $(nft list ruleset 2>/dev/null) ]] && ! grep -qF "$NFT_MARKER" "$NFT_CONF" 2>/dev/null; then
		warn "this server already has firewall rules; leaving them untouched (no nftables setup)"
		FIREWALL_STATE="skipped (existing rules found)"
		return 1
	fi

	cat >"$tmp" <<EOF
#!/usr/sbin/nft -f
$NFT_MARKER
flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;

		ct state established,related accept
		ct state invalid drop
		iifname "lo" accept

		meta l4proto icmp accept
		meta l4proto ipv6-icmp accept
		ip6 saddr fe80::/10 udp dport 546 accept comment "DHCPv6 client"

		tcp dport $SSH_PORT accept comment "SSH"
		tcp dport $PORT accept comment "Xray VLESS"
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF

	if ! nft -c -f "$tmp" >>"$LOG_FILE" 2>&1; then
		warn "nftables rejected the ruleset; no firewall was configured (see $LOG_FILE)"
		FIREWALL_STATE="FAILED (not active)"
		return 1
	fi

	# Keep the SSH session that is running this script alive: it is still on the old
	# port, which the permanent rules no longer allow. This extra rule only matches the
	# deploying address, is not written to disk, and disappears on the next reboot.
	read -r c_ip _ _ s_port <<<"${SSH_CONNECTION:-}" || true
	if [[ $c_ip =~ ^[0-9A-Fa-f:.]+$ && $s_port =~ ^[0-9]+$ && $s_port != "$SSH_PORT" ]]; then
		if [[ $c_ip == *:* ]]; then fam=ip6; else fam=ip; fi
		keep_rule="insert rule inet filter input $fam saddr $c_ip tcp dport $s_port accept comment \"xray-up deploy session (temporary)\""
	fi

	cat "$tmp" >"$load"
	if [[ -n $keep_rule ]]; then
		printf '%s\n' "$keep_rule" >>"$load"
	fi

	if [[ -f $NFT_CONF ]] && ! grep -qF "$NFT_MARKER" "$NFT_CONF"; then
		cp -a "$NFT_CONF" "$NFT_CONF.xray-up.bak"
	fi
	install -m 0755 "$tmp" "$NFT_CONF"

	# One atomic transaction: permanent rules plus the temporary session rule.
	if ! nft -f "$load" >>"$LOG_FILE" 2>&1; then
		warn "could not load the firewall rules (see $LOG_FILE); no firewall is active"
		FIREWALL_STATE="FAILED (not active)"
		return 1
	fi
	# Enable only: the rules are already loaded, and a "start" would drop the session rule.
	if ! systemctl enable nftables.service >>"$LOG_FILE" 2>&1; then
		warn "could not enable nftables.service; the firewall will be gone after a reboot"
		FIREWALL_STATE="active until reboot only"
		return 1
	fi
	FIREWALL_STATE="active (inbound: tcp $SSH_PORT, tcp $PORT, ICMP)"
}

# ----------------------------------------------------------------------------
# Address detection, state, output
# ----------------------------------------------------------------------------
detect_host() {
	local ip ext
	if [[ -n $HOST ]]; then
		return 0
	fi
	ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n 1) || true
	if [[ -z $ip ]] || is_private_ipv4 "$ip"; then
		# Behind NAT (or no IPv4 route): ask an external service for the public address.
		ext=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
			|| curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
		ext=$(tr -d '[:space:]' <<<"$ext")
		if is_ipv4 "$ext"; then
			ip=$ext
		fi
	fi
	if [[ -z $ip ]] || ! is_ipv4 "$ip"; then
		die "could not detect the public IPv4 address of this server; pass it with --host"
	fi
	if is_private_ipv4 "$ip"; then
		warn "using $ip in the link, which looks like a private address; pass --host if that is wrong"
	fi
	HOST=$ip
}

write_state() {
	local tmp
	install -d -m 0700 "$STATE_DIR"
	tmp=$(mktemp "$STATE_DIR/state.XXXXXX")
	{
		printf '# xray-up state. Root only. Do not edit by hand.\n'
		printf 'S_HOST=%q\n' "$HOST"
		printf 'S_PORT=%q\n' "$PORT"
		printf 'S_NET=%q\n' "$NET"
		printf 'S_XHTTP_PATH=%q\n' "$XHTTP_PATH"
		printf 'S_UUID=%q\n' "$UUID"
		printf 'S_SNI=%q\n' "$SNI"
		printf 'S_PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
		printf 'S_SHORT_ID=%q\n' "$SHORT_ID"
		printf 'S_NAME=%q\n' "$NAME"
		printf 'S_ADMIN_USER=%q\n' "$ADMIN_USER"
		printf 'S_SSH_PORT=%q\n' "$SSH_PORT"
		printf 'S_SSH_AUTH=%q\n' "$SSH_AUTH"
		printf 'S_FIREWALL_STATE=%q\n' "$FIREWALL_STATE"
	} >"$tmp"
	chmod 0600 "$tmp"
	mv -f "$tmp" "$STATE_FILE"
}

load_state() {
	local S_HOST="" S_PORT="" S_NET="" S_XHTTP_PATH="" S_UUID="" S_SNI="" S_PUBLIC_KEY="" S_SHORT_ID="" S_NAME=""
	local S_ADMIN_USER="" S_SSH_PORT="" S_SSH_AUTH="" S_FIREWALL_STATE=""
	[[ -f $STATE_FILE ]] || die "no xray-up installation found on this server ($STATE_FILE is missing)"
	# shellcheck disable=SC1090
	. "$STATE_FILE"
	# Command-line values (already validated) win over stored ones where a mode allows them.
	HOST=${HOST:-$S_HOST}
	PORT=$S_PORT
	NET=${S_NET:-raw}   # state files written before XHTTP support were all raw
	XHTTP_PATH=$S_XHTTP_PATH
	UUID=${UUID:-$S_UUID}
	SNI=${SNI:-$S_SNI}
	PUBLIC_KEY=$S_PUBLIC_KEY
	SHORT_ID=$S_SHORT_ID
	NAME=${NAME:-$S_NAME}
	ADMIN_USER=$S_ADMIN_USER
	SSH_PORT=$S_SSH_PORT
	SSH_AUTH=$S_SSH_AUTH
	FIREWALL_STATE=$S_FIREWALL_STATE
}

install_self() {
	# Only possible when the script was started from a file (not piped into bash).
	if [[ -f $0 && -r $0 ]] && grep -q '^# xray-up-marker' "$0" 2>/dev/null; then
		if [[ ! $0 -ef $SELF_PATH ]]; then
			install -m 0755 "$0" "$SELF_PATH"
		fi
		return 0
	fi
	return 1
}

vless_link() {
	local h=$HOST
	if [[ $h == *:* ]]; then
		h="[$h]"
	fi
	if [[ $NET == xhttp ]]; then
		# The path is "/" plus hex, so encoding the slash is all the URL-encoding it needs.
		printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto#%s' \
			"$UUID" "$h" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "${XHTTP_PATH//\//%2F}" "$NAME"
	else
		printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
			"$UUID" "$h" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$NAME"
	fi
}

print_qr() {
	if [[ $OPT_QR -ne 1 ]]; then
		return 0
	fi
	if ! command -v qrencode >/dev/null 2>&1; then
		apt_run install --no-install-recommends qrencode || true
	fi
	if command -v qrencode >/dev/null 2>&1; then
		printf '\n'
		qrencode -t ANSIUTF8 -m 2 "$(vless_link)" || true
	else
		warn "qrencode is not available; no QR code"
	fi
}

print_connection() {
	local transport_lines
	if [[ $NET == xhttp ]]; then
		transport_lines="  Flow          (empty)
  Transport     xhttp
  Path          $XHTTP_PATH
  Mode          auto"
	else
		transport_lines="  Flow          xtls-rprx-vision
  Transport     tcp (raw)"
	fi
	cat <<EOF

VLESS link (import into the client app):

$(vless_link)

Manual client settings:
  Address       $HOST
  Port          $PORT
  UUID          $UUID
$transport_lines
  Security      reality
  SNI           $SNI
  Fingerprint   chrome
  Public key    $PUBLIC_KEY
  Short ID      $SHORT_ID
EOF
	print_qr
}

print_summary() {
	local pass_line key_line="" self_line
	if [[ -n $ADMIN_PASS ]]; then
		pass_line="  Password      $ADMIN_PASS"
	else
		pass_line="  Password      (shown only once, at deployment)"
	fi
	if [[ $SSH_AUTH == key ]]; then
		key_line="  SSH login     public key only (the password is for sudo)"
	else
		key_line="  SSH login     password"
	fi
	if [[ -x $SELF_PATH ]]; then
		self_line="  Show again    ssh -t -p $SSH_PORT $ADMIN_USER@$HOST sudo xray-up --show"
	else
		self_line="  Show again    not installed (script was piped into bash); details are in $STATE_FILE"
	fi

	printf '\n================================================================\n'
	if [[ -n $ADMIN_PASS ]]; then
		printf ' xray-up finished. SAVE EVERYTHING BELOW NOW.\n'
		printf ' The password is not stored anywhere and will not be shown again.\n'
	else
		printf ' xray-up: current server details\n'
	fi
	printf '================================================================\n'
	print_connection
	cat <<EOF

Server access:
  SSH           ssh -p $SSH_PORT $ADMIN_USER@$HOST
  User          $ADMIN_USER (sudo)
$pass_line
$key_line
  Root login    disabled over SSH (root's password still works on the provider's console)
$self_line

Server state:
  Xray          $(xray_version_string) ($(systemctl is-active xray.service 2>/dev/null || true))
  Firewall      $FIREWALL_STATE
  Auto updates  $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)
================================================================
EOF
}

# ----------------------------------------------------------------------------
# Modes
# ----------------------------------------------------------------------------
mode_install() {
	if [[ -f $STATE_FILE ]]; then
		log "This server was already set up by xray-up; nothing was changed."
		log "Use --rotate for new credentials or --upgrade for a new Xray version."
		HOST="" UUID="" SNI="" NAME=""
		load_state
		print_summary
		exit 0
	fi
	validate_install_args
	NET=$TRANSPORT

	: >>"$LOG_FILE"
	chmod 0600 "$LOG_FILE"
	install_packages
	if [[ $OPT_SNI_CHECK -eq 1 ]]; then
		check_sni
	fi
	detect_host
	install_xray
	setup_auto_updates
	setup_admin_user

	harden_ssh

	# ---- Point of no return ------------------------------------------------
	# From here root can no longer log in over SSH, so nothing below may abort
	# before the summary (which carries the only copy of the password) is printed.
	trap - ERR
	set +e

	if [[ $OPT_FIREWALL -eq 1 ]]; then
		log "Configuring the firewall"
		setup_firewall
	else
		FIREWALL_STATE="not configured (--no-firewall)"
	fi

	write_state || warn "could not write $STATE_FILE"
	install_self || warn "could not install $SELF_PATH (the script was not started from a file)"
	print_summary
	exit 0
}

mode_show() {
	validate_common
	HOST="" UUID="" SNI="" NAME=""
	load_state
	print_summary
}

mode_rotate() {
	local new_uuid=$UUID
	validate_common
	if [[ -n $SNI ]]; then
		validate_sni
	fi
	UUID=""
	load_state
	UUID=$new_uuid   # empty means: generate a fresh one
	[[ -x $XRAY_BIN ]] || die "$XRAY_BIN not found"

	if [[ $OPT_SNI_CHECK -eq 1 ]]; then
		check_sni
	fi
	log "Generating new credentials"
	gen_xray_identity
	write_xray_config
	restart_xray || die "Xray did not restart with the new config (see the log lines above)"
	write_state
	log "Done. The previous link no longer works."
	print_summary
}

mode_upgrade() {
	validate_common
	XRAY_VERSION=${XRAY_VERSION:-$XRAY_VERSION_DEFAULT}
	HOST="" UUID="" SNI="" NAME=""
	load_state
	local before
	before=$(xray_version_string)

	fetch_xray
	# Make sure the new binary accepts the existing config before replacing anything.
	test_xray_config "$WORK_DIR/xray/xray" "$WORK_DIR/xray" "$XRAY_CONF" \
		|| die "the new Xray version rejects the current config; nothing was changed"
	place_xray
	restart_xray || die "Xray did not restart after the upgrade (see the log lines above)"
	log "Xray: ${before:-unknown} -> $(xray_version_string)"
}

main() {
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
	parse_args "$@"
	preflight
	trap cleanup EXIT
	trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
	WORK_DIR=$(mktemp -d /tmp/xray-up.XXXXXX)
	umask 022

	case $MODE in
		install) mode_install ;;
		show)    mode_show ;;
		rotate)  mode_rotate ;;
		upgrade) mode_upgrade ;;
	esac
}

# The whole file is parsed before anything runs, so a truncated download cannot
# execute half a script.
if [[ ${XRAY_UP_SOURCE_ONLY:-0} != 1 ]]; then
	main "$@"
fi
