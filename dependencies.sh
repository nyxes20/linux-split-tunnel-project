#!/usr/bin/env bash
set -euo pipefail

# --- configuration ----------------
BIN=subfinder
DNSX_BIN=dnsx
CIDR_BIN=cidr-merger
# packages to use with apt
PKGS=(ipset golang-go ipcalc)
# ----------------------------------

# helper to run apt install non-interactively
apt_install() {
    sudo DEBIAN_FRONTEND=noninteractive apt install -y "$@"
}

echo "Starting dependency installation..."

# --- Install apt packages ---
for pkg in "${PKGS[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "$pkg not found — installing..."
        sudo apt update
        apt_install "$pkg"
    else
        echo "$pkg already installed."
    fi
done

# --- Ensure Go is available ---
if ! command -v go >/dev/null 2>&1; then
    echo "Go compiler not found — installing golang-go..."
    apt_install golang-go
else
    echo "Go detected: $(go version)"
fi

# --- Install subfinder system-wide ---
if command -v "$BIN" >/dev/null 2>&1; then
    echo "$BIN already installed; skipping."
else
    echo "$BIN not found — installing to /usr/local/bin..."
    sudo GOBIN=/usr/local/bin go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
    sudo chmod +x /usr/local/bin/subfinder

    if command -v "$BIN" >/dev/null 2>&1; then
        echo "$BIN installed successfully in /usr/local/bin."
    else
        echo "ERROR: $BIN installation failed."
        exit 1
    fi
fi

# --- Install dnsx system-wide ---
if command -v "$DNSX_BIN" >/dev/null 2>&1; then
    echo "$DNSX_BIN already installed; skipping."
else
    echo "$DNSX_BIN not found — installing to /usr/local/bin..."
    sudo GOBIN=/usr/local/bin go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
    sudo chmod +x /usr/local/bin/dnsx

    if command -v "$DNSX_BIN" >/dev/null 2>&1; then
        echo "$DNSX_BIN installed successfully in /usr/local/bin."
    else
        echo "ERROR: $DNSX_BIN installation failed."
        exit 1
    fi
fi

# --- Install cidr-merger system-wide ---
if command -v "$CIDR_BIN" >/dev/null 2>&1; then
    echo "$CIDR_BIN already installed; skipping."
else
    echo "$CIDR_BIN not found — installing to /usr/local/bin..."
    sudo GOBIN=/usr/local/bin go install github.com/zhanhb/cidr-merger@latest
    sudo chmod +x /usr/local/bin/cidr-merger

    if command -v "$CIDR_BIN" >/dev/null 2>&1; then
        echo "$CIDR_BIN installed successfully in /usr/local/bin."
    else
        echo "ERROR: $CIDR_BIN installation failed."
        exit 1
    fi
fi

echo "All dependencies installed successfully!"
