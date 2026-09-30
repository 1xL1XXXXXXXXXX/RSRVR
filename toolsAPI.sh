#!/usr/bin/env bash
set -Eeuo pipefail

# install-tools.sh
# Ubuntu/Debian installer for the API-recon toolset from the supplied api-recon SKILL.md.
#
# Installs:
#   subfinder, httpx, TruffleHog, ffuf, feroxbuster, Kiterunner,
#   OWASP ZAP, Autoswagger, Schemathesis, InQL, Clairvoyance,
#   Graphw00f, Autorize, Burp Suite Community Edition.
#
# Intended for authorized security testing only.

TOOLS_DIR="${TOOLS_DIR:-/opt/api-tools}"
GO_VERSION="${GO_VERSION:-1.27.1}"
BURP_VERSION="${BURP_VERSION:-2026.8}"
KITERUNNER_VERSION="${KITERUNNER_VERSION:-v1.0.2}"

log()  { printf '\n\033[1;36m[+]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root: sudo bash install-tools.sh"

source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "This script supports Ubuntu/Debian. Detected: ${ID:-unknown}" ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) GO_ARCH="amd64" ;;
  arm64) GO_ARCH="arm64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

export DEBIAN_FRONTEND=noninteractive

log "Installing system dependencies"
apt-get update
apt-get install -y \
  ca-certificates curl wget git jq unzip tar gzip xz-utils \
  python3 python3-venv python3-pip \
  build-essential pkg-config \
  openjdk-17-jdk task \
  snapd

mkdir -p "$TOOLS_DIR" /usr/local/bin
chmod 755 "$TOOLS_DIR"

# ---------------------------------------------------------------------------
# Go 1.26.8
# Required by the current ProjectDiscovery subfinder release.
# Official checksum verified against go.dev/dl.
# ---------------------------------------------------------------------------
log "Installing Go ${GO_VERSION}"
GO_TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

if [[ "$GO_ARCH" == "amd64" ]]; then
  GO_SHA256="63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445"
else
  GO_SHA256="3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec"
fi

TMP_GO="$(mktemp -d)"
curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "${TMP_GO}/${GO_TARBALL}"
echo "${GO_SHA256}  ${TMP_GO}/${GO_TARBALL}" | sha256sum -c -
rm -rf /usr/local/go
tar -C /usr/local -xzf "${TMP_GO}/${GO_TARBALL}"
rm -rf "$TMP_GO"

cat >/etc/profile.d/api-tools-go.sh <<'EOF'
export PATH="/usr/local/go/bin:/root/go/bin:/usr/local/bin:$PATH"
EOF
export PATH="/usr/local/go/bin:/root/go/bin:/usr/local/bin:$PATH"

go version

# ---------------------------------------------------------------------------
# Go tools
# ---------------------------------------------------------------------------
log "Installing subfinder"
go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest

log "Installing httpx"
go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest

log "Installing ffuf"
go install -v github.com/ffuf/ffuf/v2@latest

install -m 0755 /root/go/bin/subfinder /usr/local/bin/subfinder
install -m 0755 /root/go/bin/httpx /usr/local/bin/httpx
install -m 0755 /root/go/bin/ffuf /usr/local/bin/ffuf

# ---------------------------------------------------------------------------
# TruffleHog
# Official installer. Retry because freshly-published releases can briefly
# exist before binary assets are available.
# ---------------------------------------------------------------------------
log "Installing TruffleHog"
for attempt in 1 2 3 4 5; do
  if curl -sSfL \
      https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
      | sh -s -- -b /usr/local/bin; then
    break
  fi
  if [[ "$attempt" -eq 5 ]]; then
    die "TruffleHog installer failed after 5 attempts"
  fi
  warn "TruffleHog release assets may still be propagating; retrying..."
  sleep 15
done

# ---------------------------------------------------------------------------
# Feroxbuster
# Official install script.
# ---------------------------------------------------------------------------
log "Installing feroxbuster"
curl -sSfL \
  https://raw.githubusercontent.com/epi052/feroxbuster/main/install-nix.sh \
  | bash -s /usr/local/bin

# ---------------------------------------------------------------------------
# Kiterunner
# Legacy tool, pinned to the latest upstream release v1.0.2.
# Build method is the one documented by the upstream repository.
# ---------------------------------------------------------------------------
log "Installing Kiterunner ${KITERUNNER_VERSION} (legacy)"
KITE_DIR="${TOOLS_DIR}/kiterunner"
rm -rf "$KITE_DIR"
git clone --depth 1 --branch "$KITERUNNER_VERSION" \
  https://github.com/assetnote/kiterunner.git "$KITE_DIR"
(
  cd "$KITE_DIR"
  make build
)
install -m 0755 "${KITE_DIR}/dist/kr" /usr/local/bin/kr

# ---------------------------------------------------------------------------
# Python tools: isolated virtual environments to avoid Ubuntu PEP 668 issues.
# ---------------------------------------------------------------------------
PY_BASE="${TOOLS_DIR}/venvs"
mkdir -p "$PY_BASE"

make_venv() {
  local name="$1"
  python3 -m venv "${PY_BASE}/${name}"
  "${PY_BASE}/${name}/bin/pip" install --upgrade pip setuptools wheel
}

# Schemathesis
log "Installing Schemathesis"
make_venv schemathesis
"${PY_BASE}/schemathesis/bin/pip" install schemathesis
ln -sf "${PY_BASE}/schemathesis/bin/schemathesis" /usr/local/bin/schemathesis

# Clairvoyance
log "Installing Clairvoyance"
make_venv clairvoyance
"${PY_BASE}/clairvoyance/bin/pip" install clairvoyance
ln -sf "${PY_BASE}/clairvoyance/bin/clairvoyance" /usr/local/bin/clairvoyance

# Graphw00f
log "Installing Graphw00f"
GRAPHW00F_DIR="${TOOLS_DIR}/graphw00f"
rm -rf "$GRAPHW00F_DIR"
git clone --depth 1 https://github.com/dolevf/graphw00f.git "$GRAPHW00F_DIR"
make_venv graphw00f
"${PY_BASE}/graphw00f/bin/pip" install -r "${GRAPHW00F_DIR}/requirements.txt"
cat >/usr/local/bin/graphw00f <<EOF
#!/usr/bin/env bash
exec "${PY_BASE}/graphw00f/bin/python" "${GRAPHW00F_DIR}/main.py" "\$@"
EOF
chmod 755 /usr/local/bin/graphw00f

# Autoswagger
log "Installing Autoswagger"
AUTOSWAGGER_DIR="${TOOLS_DIR}/autoswagger"
rm -rf "$AUTOSWAGGER_DIR"
git clone --depth 1 https://github.com/intruder-io/autoswagger.git "$AUTOSWAGGER_DIR"
make_venv autoswagger
"${PY_BASE}/autoswagger/bin/pip" install -r "${AUTOSWAGGER_DIR}/requirements.txt"
cat >/usr/local/bin/autoswagger <<EOF
#!/usr/bin/env bash
exec "${PY_BASE}/autoswagger/bin/python" "${AUTOSWAGGER_DIR}/autoswagger.py" "\$@"
EOF
chmod 755 /usr/local/bin/autoswagger

# ---------------------------------------------------------------------------
# InQL
# Official Burp extension. Build with Taskfile + Java 17.
# ---------------------------------------------------------------------------
log "Building InQL"
INQL_DIR="${TOOLS_DIR}/inql"
rm -rf "$INQL_DIR"
git clone --depth 1 https://github.com/doyensec/inql.git "$INQL_DIR"
(
  cd "$INQL_DIR"
  task all
)
INQL_JAR="$(find "$INQL_DIR" -maxdepth 2 -type f -name 'InQL*.jar' -print -quit)"
[[ -n "$INQL_JAR" ]] || die "InQL.jar was not produced"
cp -f "$INQL_JAR" "${TOOLS_DIR}/InQL.jar"
chmod 644 "${TOOLS_DIR}/InQL.jar"

# ---------------------------------------------------------------------------
# Autorize
# Burp extension. Clone the official PortSwigger repository; loading it into
# Burp is intentionally left as a UI/BApp step.
# ---------------------------------------------------------------------------
log "Preparing Autorize"
AUTORIZE_DIR="${TOOLS_DIR}/autorize"
rm -rf "$AUTORIZE_DIR"
git clone --depth 1 https://github.com/PortSwigger/autorize.git "$AUTORIZE_DIR"

# ---------------------------------------------------------------------------
# OWASP ZAP
# Official Snap package. ZAP requires Java 17+.
# ---------------------------------------------------------------------------
log "Installing OWASP ZAP"
if ! command -v snap >/dev/null 2>&1; then
  systemctl enable --now snapd.socket || true
  sleep 2
fi
snap install zaproxy --classic || snap refresh zaproxy
ln -sf /snap/bin/zaproxy /usr/local/bin/zaproxy

# ---------------------------------------------------------------------------
# Burp Suite Community Edition
# Pin to the latest STABLE release currently listed by PortSwigger:
# 2026.8. Verify SHA-256 before installing.
# ---------------------------------------------------------------------------
log "Installing Burp Suite Community Edition ${BURP_VERSION}"
BURP_JAR="${TOOLS_DIR}/burpsuite_${BURP_VERSION}.jar"
BURP_URL="https://portswigger.net/burp/releases/download?product=community&version=${BURP_VERSION}&type=Jar"
BURP_SHA256="888f0588cf82a3b70d508dcbf07591184a26249e38cda8ea8b5a68f4b5a30789"

curl -fL "$BURP_URL" -o "$BURP_JAR"
echo "${BURP_SHA256}  ${BURP_JAR}" | sha256sum -c -
ln -sf "$BURP_JAR" /usr/local/bin/burpsuite.jar

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
log "Verifying installed tools"

declare -a REQUIRED_CMDS=(
  subfinder
  httpx
  trufflehog
  ffuf
  feroxbuster
  kr
  schemathesis
  clairvoyance
  graphw00f
  autoswagger
  zaproxy
)

FAIL=0

for cmd in "${REQUIRED_CMDS[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '\033[1;32m[OK]\033[0m %-14s %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf '\033[1;31m[FAIL]\033[0m %-14s not found\n' "$cmd"
    FAIL=1
  fi
done

if [[ -s "${TOOLS_DIR}/InQL.jar" ]]; then
  ok "InQL           ${TOOLS_DIR}/InQL.jar"
else
  printf '\033[1;31m[FAIL]\033[0m InQL.jar missing\n"
  FAIL=1
fi

if [[ -f "${AUTORIZE_DIR}/Autorize.py" ]]; then
  ok "Autorize        ${AUTORIZE_DIR}/Autorize.py"
else
  printf '\033[1;31m[FAIL]\033[0m Autorize.py missing\n"
  FAIL=1
fi

if [[ -f "$BURP_JAR" ]]; then
  ok "Burp Suite     ${BURP_JAR}"
else
  printf '\033[1;31m[FAIL]\033[0m Burp JAR missing\n"
  FAIL=1
fi

echo
echo "============================================================"
echo " API Recon Tool Installation"
echo "============================================================"
echo "Tools directory : ${TOOLS_DIR}"
echo
echo "CLI tools:"
echo "  subfinder      httpx          trufflehog"
echo "  ffuf           feroxbuster    kr"
echo "  schemathesis   clairvoyance   graphw00f"
echo "  autoswagger    zaproxy"
echo
echo "Burp extensions:"
echo "  InQL     : ${TOOLS_DIR}/InQL.jar"
echo "  Autorize : ${AUTORIZE_DIR}/Autorize.py"
echo
echo "Burp Suite:"
echo "  ${BURP_JAR}"
echo
echo "NOTE: InQL and Autorize are Burp extensions; load them from"
echo "      Burp → Extensions. Autorize is also available via BApp Store."
echo "NOTE: Kiterunner is legacy and intentionally pinned to ${KITERUNNER_VERSION}."
echo "============================================================"

if [[ "$FAIL" -ne 0 ]]; then
  die "One or more installations failed."
fi

ok "All automated installation checks passed."
