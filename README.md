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

### Host requirements

```bash
sudo apt install --no-install-recommends \
     p7zip-full msitools file python3 unzip \
     curl rsync openssh-client git
```

### Usage

```bash
chmod +x install-firmware.sh

# host-only: stage everything under /tmp/qcom-npu-fw/
./install-firmware.sh

# full deploy to a target
TARGET=root@glymur.local ./install-firmware.sh
```

The script:

1. Downloads [Qualcomm_Hexagon_NPU_Driver-v1.3.1.0.zip](https://softwarecenter.qualcomm.com/api/download/software/tools/Qualcomm_HND/Windows/ARM64/1.3.1.0/Qualcomm_Hexagon_NPU_Driver-v1.3.1.0.zip).
2. Clones <https://github.com/Srinivas-Kandagatla/installer-extract> and runs
   `wix-burn-extract.sh` to carve the installer's `WixAttachedContainer` and
   peel each MSI back to real filenames.
3. SSHes into the target, reads `/sys/firmware/devicetree/base/model`, and
   maps it to a per-OEM firmware subdir.
4. Deploys:
   - signed firmware → `/lib/firmware/<fw_subdir>/`
   - DSP userspace shared objects → `/usr/share/qcom/<fw_subdir>/`
   - master fastrpc YAML → `/usr/share/qcom/conf.d/50-qcom-laptops.yaml`
5. Tells you to reboot.

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
| `QCOM_SHARE` | `/usr/share/qcom` | Target DSP userspace root |
| `YAML_NAME` | `50-qcom-laptops.yaml` | fastrpc config filename |

## 2. Build + deploy llama.cpp

### Host requirements

```bash
sudo apt install docker.io qemu-user-static binfmt-support git rsync openssh-client
```

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
