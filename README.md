# glymur-npu-enable

Scripts to bring up the Hexagon NPU on Qualcomm X Elite 2 laptops
(Glymur / Mahua / Kolambo) running Debian/Ubuntu arm64.

Two self-contained scripts:

| Script | Purpose |
| --- | --- |
| `install-firmware.sh` | Fetch the Qualcomm Hexagon NPU Windows driver, extract it on Linux, and push signed firmware + DSP userspace libs (Hexagon skels, Qnn/Snpe HTP, `fastrpc_shell_*`) + the master fastrpc machine YAML to the target. |
| `build-llamacpp.sh` | Cross-build `llama.cpp` with the Hexagon backend using the Snapdragon toolchain Docker image under x86_64 emulation, and optionally deploy it. Assumes `install-firmware.sh` already ran. |

Both scripts self-clone anything they need under `$WORK` (default
`/tmp/qcom-npu-fw`) — nothing has to be pre-staged on the host.

## 1. Install firmware

### Host dependencies

| Tool | Debian / Ubuntu | Fedora / RHEL | Arch |
| --- | --- | --- | --- |
| CAB extraction | `p7zip-full` | `p7zip p7zip-plugins` | `p7zip` |
| MSI tooling | `msitools` | `msitools` | `msitools` |
| File typing | `file` | `file` | `file` |
| Payload scan | `python3` | `python3` | `python` |
| Zip wrapper | `unzip` | `unzip` | `unzip` |
| Fetch / sync | `curl rsync openssh-client` | `curl rsync openssh-clients` | `curl rsync openssh` |
| Auto-clone | `git` | `git` | `git` |
| YAML schema check (optional) | `python3-yamale` | `python3-yamale` (EPEL) or `pip install yamale` | AUR `python-yamale` |

One-liners:

```bash
# Debian / Ubuntu
sudo apt install --no-install-recommends \
     p7zip-full msitools file python3 unzip \
     curl rsync openssh-client git

# Fedora / RHEL (CoreOS: use rpm-ostree instead)
sudo dnf install -y \
     p7zip p7zip-plugins msitools file python3 unzip \
     curl rsync openssh-clients git

# Arch
sudo pacman -S --needed \
     p7zip msitools file python unzip \
     curl rsync openssh git
```

### Usage

```bash
chmod +x install-firmware.sh

# host-only: stage everything under /tmp/qcom-npu-fw/root
./install-firmware.sh

# full deploy to a target
TARGET=root@glymur.local ./install-firmware.sh
```

The script:

1. Downloads [Qualcomm_Hexagon_NPU_Driver-v1.3.1.0.zip](https://softwarecenter.qualcomm.com/api/download/software/tools/Qualcomm_HND/Windows/ARM64/1.3.1.0/Qualcomm_Hexagon_NPU_Driver-v1.3.1.0.zip).
2. Clones <https://github.com/Srinivas-Kandagatla/installer-extract> and runs
   `wix-burn-extract.sh` to carve the installer's `WixAttachedContainer` and
   peel each MSI back to real filenames. (The extractor now identifies MSIs
   by OLE2 magic, so it works on Debian AND Fedora — earlier releases only
   matched Debian's `file(1)` wording.)
3. SSHes into the target, reads `/sys/firmware/devicetree/base/model`, and
   maps it to a per-OEM firmware subdir.
4. Deploys:
   - signed firmware → `/lib/firmware/qcom/<soc>/<OEM>/<model>/` (CRD/QCP
     boards also get a `cdsp.mbn` symlink to the SoC's `qccdsp*.mbn`)
   - DSP userspace shared objects → `/usr/share/hexagon-dsp/<soc>/dsp/cdsp/`
     (shared across every OEM board on that SoC family)
   - master fastrpc YAML → `/usr/share/hexagon-dsp/conf.d/50-qcom-laptops.yaml`
5. Tells you to reboot.

> **Note**: fastrpc's compiled-in config dir is `/usr/share/qcom/conf.d/`.
> If you ship `conf.d/` under `/usr/share/hexagon-dsp/` instead, either
> symlink `/usr/share/qcom -> /usr/share/hexagon-dsp` on the target or
> override `QCOM_SHARE=/usr/share/qcom` when running the script.

### Supported machines

| DT model string | Firmware subdir |
| --- | --- |
| Qualcomm Technologies, Inc. Glymur CRD | `qcom/glymur` |
| ASUS Zenbook A16 (UX3607OA) | `qcom/glymur/ASUSTeK/UX3607OA` |
| HP EliteBook X G2q 14 AI | `qcom/glymur/hp/elitebook-x-g2q` |
| Lenovo Yoga Slim 7x Gen 11 | `qcom/glymur/LENOVO/83QR` |
| Qualcomm Technologies, Inc. Mahua CRD | `qcom/mahua` |
| Lenovo ThinkPad T14s Gen 7 (LCD) | `qcom/glymur/LENOVO/22A8` |
| Qualcomm Technologies, Inc. Kolambo CRD | `qcom/kolambo` *(placeholder)* |

Add a board by extending `model_to_fw_subdir()` *and* `write_master_yaml()`
with matching entries.

### Env vars

| Var | Default | Meaning |
| --- | --- | --- |
| `URL` | Qualcomm NPU driver v1.3.1.0 | Installer zip URL |
| `WORK` | `/tmp/qcom-npu-fw` | Host scratch dir |
| `EXTRACT_REPO` | `https://github.com/Srinivas-Kandagatla/installer-extract` | Extractor repo |
| `EXTRACT_SH` | `$WORK/installer-extract/wix-burn-extract.sh` | Extractor path |
| `FASTRPC_REPO` | `https://github.com/quic/fastrpc` | fastrpc repo (for optional YAML schema) |
| `FASTRPC_DIR` | `$WORK/fastrpc` | Where fastrpc is cloned |
| `TARGET` | *(unset)* | SSH destination; unset = host-only |
| `STAGE` | *(unset)* | Local staging root; unset + no TARGET = `$WORK/root` |
| `MACHINE` | `all` in STAGE mode, DT-detected in TARGET mode | Which board to install for |
| `QCOM_SHARE` | `/usr/share/hexagon-dsp` | Target DSP userspace root |
| `YAML_NAME` | `50-qcom-laptops.yaml` | fastrpc config filename |
| `SOC_TREE` | auto from `MACHINE` | `8380` (V73, X Elite 1) or `8480` (V81, X Elite 2) |

## 2. Build + deploy llama.cpp

### Host dependencies

Docker + amd64 QEMU user-mode (the Snapdragon toolchain image is x86_64,
run under emulation on an arm64 host). The script installs these for you on
first run if the `alpine --platform linux/amd64` smoke test fails.

| Tool | Debian / Ubuntu | Fedora / RHEL | Arch |
| --- | --- | --- | --- |
| Docker | `docker.io` | `moby-engine` (or Docker CE from docker.com) | `docker` |
| amd64 QEMU | `qemu-user-static binfmt-support` | `qemu-user-static` | `qemu-user-static binfmt-support` |
| Git / rsync / ssh | `git rsync openssh-client` | `git rsync openssh-clients` | `git rsync openssh` |

Manual install if you'd rather not let the script run `sudo`:

```bash
# Debian / Ubuntu
sudo apt install docker.io qemu-user-static binfmt-support git rsync openssh-client

# Fedora / RHEL
sudo dnf install moby-engine qemu-user-static git rsync openssh-clients
sudo systemctl enable --now docker

# Arch
sudo pacman -S --needed docker qemu-user-static binfmt-support git rsync openssh
sudo systemctl enable --now docker
```

Add yourself to the `docker` group (`sudo usermod -aG docker $USER` + re-login)
or prefix the script with `sudo`.

### Usage

```bash
chmod +x build-llamacpp.sh

# build only (install tree under $LLAMA_SRC/pkg-snapdragon/)
./build-llamacpp.sh

# build + deploy
TARGET=root@glymur.local ./build-llamacpp.sh
```

The script registers the amd64 binfmt handler (if missing), clones
<https://github.com/ggml-org/llama.cpp>, runs CMake inside
`ghcr.io/snapdragon-toolchain/arm64-linux:v0.1` via QEMU, and (if `TARGET` is
set) rsyncs the install tree to `/opt/llama-snapdragon/` on the target.

Expect multi-GB image downloads and slow emulated compilation.

### Env vars

| Var | Default | Meaning |
| --- | --- | --- |
| `LLAMA_REPO` | `https://github.com/ggml-org/llama.cpp` | Source repo |
| `LLAMA_SRC` | `~/src/llama.cpp` | Local checkout |
| `LLAMA_IMAGE` | `ghcr.io/snapdragon-toolchain/arm64-linux:v0.1` | Toolchain image |
| `LLAMA_PRESET` | `arm64-linux-snapdragon-release` | CMake preset |
| `LLAMA_DEST` | `/opt/llama-snapdragon` | Install dir on target |
| `TARGET` | *(unset)* | SSH destination; unset = build only |

### Running on the target

```bash
export LD_LIBRARY_PATH=/opt/llama-snapdragon/lib
export ADSP_LIBRARY_PATH=/opt/llama-snapdragon/lib
/opt/llama-snapdragon/bin/llama-cli -m model-Q4_0.gguf --device HTP0 -ngl 99 -p "hello"
```

Q4_0 models are the recommended format for the Hexagon backend.

## Verifying on the target

```bash
# firmware load errors?
dmesg | grep -iE 'firmware|remoteproc|q6v5|adreno|wcn'

# remoteproc state
for r in /sys/class/remoteproc/remoteproc*; do
    printf '%s: %s %s fw=%s\n' "$r" "$(cat $r/state)" \
        "$(cat $r/name)" "$(cat $r/firmware)"
done

# fastrpc config
cat /sys/firmware/devicetree/base/model; echo
ls /usr/share/qcom/conf.d/
```
