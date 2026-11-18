#!/usr/bin/env bash
# build-llamacpp.sh — cross-build llama.cpp with the Hexagon backend using
# the Snapdragon toolchain Docker image under x86_64 emulation, and
# (optionally) deploy the install tree to a Qualcomm X Elite 2 laptop.
#
# Assumes NPU firmware + fastrpc YAML are already in place on the target
# (run install-firmware.sh first).
#
# Usage:
#   ./build-llamacpp.sh                              # build only
#   TARGET=root@glymur.local ./build-llamacpp.sh     # build + deploy
#
set -euo pipefail

LLAMA_SRC="${LLAMA_SRC:-$HOME/src/llama.cpp}"
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp}"
LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/snapdragon-toolchain/arm64-linux:v0.1}"
LLAMA_PRESET="${LLAMA_PRESET:-arm64-linux-snapdragon-release}"
LLAMA_DEST="${LLAMA_DEST:-/opt/llama-snapdragon}"
TARGET="${TARGET:-}"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: $1" >&2
        exit 1
    }
}
need git
need docker

# ---------------------------------------------------------------------------
# 1. register amd64 binfmt handler if the host is arm64 (one-time)
# ---------------------------------------------------------------------------
install_binfmt_pkgs() {
    if command -v apt >/dev/null 2>&1; then
        sudo apt install -y docker.io qemu-user-static binfmt-support
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora: moby-engine is the stock docker; qemu-user-static covers the
        # binfmt handlers.  systemd-binfmt provides the registration bits.
        sudo dnf install -y moby-engine qemu-user-static systemd-udev
        sudo systemctl enable --now docker
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y docker qemu-linux-user
        sudo systemctl enable --now docker
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm docker qemu-user-static binfmt-support
        sudo systemctl enable --now docker
    else
        echo "ERROR: unknown distro — install docker + qemu-user-static manually" >&2
        exit 1
    fi
}

echo "[1/4] Checking x86_64 Docker emulation"
if ! docker run --rm --platform linux/amd64 alpine uname -m 2>/dev/null \
     | grep -q x86_64; then
    echo "       registering amd64 binfmt handler via tonistiigi/binfmt"
    install_binfmt_pkgs
    sudo docker run --privileged --rm tonistiigi/binfmt --install amd64
fi

# ---------------------------------------------------------------------------
# 2. clone / update llama.cpp
# ---------------------------------------------------------------------------
echo "[2/4] Preparing llama.cpp source at $LLAMA_SRC"
if [[ -d "$LLAMA_SRC/.git" ]]; then
    git -C "$LLAMA_SRC" pull --ff-only
else
    git clone "$LLAMA_REPO" "$LLAMA_SRC"
fi

# ---------------------------------------------------------------------------
# 3. build inside the Snapdragon toolchain container
# ---------------------------------------------------------------------------
echo "[3/4] Building with preset $LLAMA_PRESET"
docker run --rm -u "$(id -u):$(id -g)" \
    --volume "$LLAMA_SRC:/workspace" \
    --platform linux/amd64 "$LLAMA_IMAGE" \
    bash -lc "
        set -e
        cd /workspace
        cp docs/backend/snapdragon/CMakeUserPresets.json .
        cmake --preset $LLAMA_PRESET -B build-snapdragon
        cmake --build   build-snapdragon -j \$(nproc)
        cmake --install build-snapdragon --prefix pkg-snapdragon
    "

echo "       install tree: $LLAMA_SRC/pkg-snapdragon/"

# ---------------------------------------------------------------------------
# 4. deploy (optional)
# ---------------------------------------------------------------------------
if [[ -z "$TARGET" ]]; then
    cat <<EOF
[4/4] TARGET not set; stopping after build.
       To deploy:
         TARGET=root@<board> $0
EOF
    exit 0
fi

echo "[4/4] Deploying to $TARGET:$LLAMA_DEST"
need rsync
need ssh
ssh "$TARGET" "mkdir -p '$LLAMA_DEST'"
rsync -av "$LLAMA_SRC/pkg-snapdragon/" "$TARGET:$LLAMA_DEST/"

cat <<EOF

Run on the target with:
  export LD_LIBRARY_PATH=$LLAMA_DEST/lib
  export ADSP_LIBRARY_PATH=$LLAMA_DEST/lib
  $LLAMA_DEST/bin/llama-cli -m model-Q4_0.gguf --device HTP0 -ngl 99 -p "hello"
EOF
