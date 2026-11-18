#!/usr/bin/env bash
# install-firmware.sh — fetch + deploy Qualcomm Hexagon NPU firmware and
# DSP userspace (skels, Qnn/Snpe HTP libs, fastrpc_shell) for X Elite 2
# laptops (Glymur / Mahua / Kolambo).
#
#   1. Download the Qualcomm Hexagon NPU Windows driver zip
#   2. Extract it with wix-burn-extract.sh (self-cloned on first run)
#   3. SSH the target, read /sys/firmware/devicetree/base/model
#   4. Pick the right per-OEM subdir for that machine
#   5. Deploy:
#        signed firmware           -> /lib/firmware/<fw_subdir>/
#        DSP userspace shared objs -> /usr/share/qcom/<fw_subdir>/
#        master fastrpc YAML       -> /usr/share/qcom/conf.d/
#
# Usage:
#   ./install-firmware.sh                           # host-only stage
#   TARGET=root@glymur.local ./install-firmware.sh  # full deploy
#
set -euo pipefail

# ---------------------------------------------------------------------------
# config (override with env vars)
# ---------------------------------------------------------------------------
URL="${URL:-https://softwarecenter.qualcomm.com/api/download/software/tools/Qualcomm_HND/Windows/ARM64/1.3.1.0/Qualcomm_Hexagon_NPU_Driver-v1.3.1.0.zip}"
ZIP="$(basename "$URL")"

WORK="${WORK:-/tmp/qcom-npu-fw}"
EXTRACT_REPO="${EXTRACT_REPO:-https://github.com/Srinivas-Kandagatla/installer-extract}"
EXTRACT_SH="${EXTRACT_SH:-$WORK/installer-extract/wix-burn-extract.sh}"
FASTRPC_REPO="${FASTRPC_REPO:-https://github.com/quic/fastrpc}"
FASTRPC_DIR="${FASTRPC_DIR:-$WORK/fastrpc}"
TARGET="${TARGET:-}"
STAGE="${STAGE:-}"                          # local staging root (dry-run); unset = normal

QCOM_SHARE="${QCOM_SHARE:-/usr/share/hexagon-dsp}"
YAML_NAME="${YAML_NAME:-50-qcom-laptops.yaml}"

# ---------------------------------------------------------------------------
# model -> { kernel firmware subdir ; DSP userspace subdir }
#
# fw_subdir is relative to /lib/firmware/     (so starts with "qcom/")
# dsp_subdir is relative to /usr/share/qcom/  (so NO "qcom/" prefix) and
#            matches the DSP_LIBRARY_PATH in the YAML below.
# ---------------------------------------------------------------------------
model_to_fw_subdir() {
    case "$1" in
        # X Elite 2 (SM8480 / Hexagon V81)
        "Qualcomm Technologies, Inc. Glymur CRD")   echo "qcom/glymur" ;;
        "ASUS Zenbook A16 (UX3607OA)")              echo "qcom/glymur/ASUSTeK/UX3607OA" ;;
        "HP EliteBook X G2q 14 AI")                 echo "qcom/glymur/hp/elitebook-x-g2q" ;;
        "Lenovo Yoga Slim 7x Gen 11")               echo "qcom/glymur/LENOVO/83QR" ;;
        "Qualcomm Technologies, Inc. Mahua CRD")    echo "qcom/mahua" ;;
        "Lenovo ThinkPad T14s Gen 7 (LCD)")         echo "qcom/glymur/LENOVO/22A8" ;;
        "Qualcomm Technologies, Inc. Kolambo CRD")  echo "qcom/kolambo" ;;
        # X Elite 1 / Hamoa (SM8380 / Hexagon V73)
        "Qualcomm Technologies, Inc. X1E80100 CRD") echo "qcom/x1e80100" ;;
        "Qualcomm Technologies, Inc. X1E80100 QCP") echo "qcom/x1e80100" ;;
        "Qualcomm Technologies, Inc. X1E001DE Snapdragon Devkit for Windows") echo "qcom/x1e80100/Thundercomm/DEVKIT" ;;
        "ASUS Vivobook S 15")                       echo "qcom/x1e80100/ASUSTeK/vivobook-s15" ;;
        "ASUS Zenbook A14 (UX3407RA)")              echo "qcom/x1e80100/ASUSTeK/zenbook-a14" ;;
        "Dell Inspiron 14 Plus 7441")               echo "qcom/x1e80100/dell/inspiron-14-plus-7441" ;;
        "Dell Latitude 7455")                       echo "qcom/x1e80100/dell/latitude-7455" ;;
        "Dell XPS 13 9345")                         echo "qcom/x1e80100/dell/xps13-9345" ;;
        "HONOR MagicBook Art 14 Snapdragon")        echo "qcom/x1e80100/HONOR/MRO-XXX" ;;
        "HP EliteBook Ultra G1q")                   echo "qcom/x1e80100/hp/elitebook-ultra-g1q" ;;
        "HP Omnibook X 14-fe0")                     echo "qcom/x1e80100/hp/omnibook-x14" ;;
        "Lenovo Yoga Slim 7x")                      echo "qcom/x1e80100/LENOVO/83ED" ;;
        "Medion SPRCHRGD 14 S1")                    echo "qcom/x1e80100/Medion/sprchrgd-14-s1" ;;
        *) return 1 ;;
    esac
}

# DSP userspace is identical across every OEM on a SoC family — collapse by
# family (one copy of the skels per SoC under /usr/share/qcom/<family>/).
# Signed kernel firmware stays OEM-specific in model_to_fw_subdir().
model_to_dsp_subdir() {
    case "$1" in
        *Glymur*|"ASUS Zenbook A16 (UX3607OA)"|"HP EliteBook X G2q 14 AI"|"Lenovo Yoga Slim 7x Gen 11")
            echo "glymur/dsp/cdsp" ;;
        *Mahua*|"Lenovo ThinkPad T14s Gen 7 (LCD)")
            echo "mahua/dsp/cdsp" ;;
        *Kolambo*)
            echo "kolambo/dsp/cdsp" ;;
        *X1E80100*|*X1E001DE*|"ASUS Vivobook S 15"|"ASUS Zenbook A14 (UX3407RA)"|Dell*|HONOR*|"HP EliteBook Ultra G1q"|"HP Omnibook X 14-fe0"|"Lenovo Yoga Slim 7x"|"Medion SPRCHRGD 14 S1")
            echo "x1e80100/dsp/cdsp" ;;
        *) return 1 ;;
    esac
}

# Which SoC tree inside the Windows installer each machine pulls from:
#   8380 → Hexagon V73 (X Elite 1 / Hamoa / x1e80100)
#   8480 → Hexagon V81 (X Elite 2 / Glymur / Mahua / Kolambo)
model_to_soc_tree() {
    case "$1" in
        *Glymur*|*Mahua*|*Kolambo*|"ASUS Zenbook A16 (UX3607OA)"|"HP EliteBook X G2q 14 AI"|"Lenovo Yoga Slim 7x Gen 11"|"Lenovo ThinkPad T14s Gen 7 (LCD)")
            echo "8480" ;;
        *X1E80100*|*X1E001DE*|"ASUS Vivobook S 15"|"ASUS Zenbook A14 (UX3407RA)"|Dell*|HONOR*|"HP EliteBook Ultra G1q"|"HP Omnibook X 14-fe0"|"Lenovo Yoga Slim 7x"|"Medion SPRCHRGD 14 S1")
            echo "8380" ;;
        *) return 1 ;;
    esac
}

write_master_yaml() {
    local out="$1" m dsp
    {
        echo "# SPDX-License-Identifier: MIT"
        echo "# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries."
        echo
        echo "machines:"
        for m in "${ALL_MACHINES[@]}"; do
            dsp="$(model_to_dsp_subdir "$m")" || continue
            # drop only the trailing "/cdsp" — fastrpc looks at <family>/dsp/
            dsp="${dsp%/cdsp}"
            echo "  $m:"
            echo "    DSP_LIBRARY_PATH: $dsp"
        done
    } > "$out"
}

# ---------------------------------------------------------------------------
# sanity checks
# ---------------------------------------------------------------------------
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: $1" >&2
        exit 1
    }
}
need curl
need find
need rsync
need ssh
need scp
need git

mkdir -p "$WORK"

if [[ ! -x "$EXTRACT_SH" ]]; then
    echo "Fetching wix-burn-extract.sh from $EXTRACT_REPO"
    EXTRACT_DIR="$(dirname "$EXTRACT_SH")"
    if [[ -d "$EXTRACT_DIR/.git" ]]; then
        git -C "$EXTRACT_DIR" pull --ff-only
    else
        mkdir -p "$(dirname "$EXTRACT_DIR")"
        git clone --depth 1 "$EXTRACT_REPO" "$EXTRACT_DIR"
    fi
    chmod +x "$EXTRACT_SH"
    [[ -x "$EXTRACT_SH" ]] || { echo "ERROR: no $EXTRACT_SH after clone" >&2; exit 1; }
fi

# optional: fetch upstream fastrpc only if we're going to validate the YAML
if command -v yamale >/dev/null 2>&1 && [[ ! -d "$FASTRPC_DIR/.git" ]]; then
    echo "Fetching fastrpc from $FASTRPC_REPO (for YAML schema)"
    git clone --depth 1 "$FASTRPC_REPO" "$FASTRPC_DIR" || true
fi

# ---------------------------------------------------------------------------
# 1. fetch + extract
# ---------------------------------------------------------------------------
cd "$WORK"

echo "[1/5] Fetching $ZIP"
# Qualcomm's CDN frequently resets HTTP/2 streams mid-flight, so pin HTTP/1.1
# and retry hard with resume. --fail-early would abort on the first 5xx we
# want to retry, so we leave it off.
curl -L --http1.1 --fail --retry 20 --retry-delay 5 --retry-all-errors \
     --connect-timeout 30 --speed-time 60 --speed-limit 1024 \
     -C - -o "$ZIP" "$URL"

echo "[2/5] Extracting with wix-burn-extract.sh"
rm -rf extracted
"$EXTRACT_SH" -o extracted "$ZIP"

# Discover the target's DT model up-front so staging can pick the right
# SoC tree (8380 / 8480).  TARGET mode SSHes; STAGE mode uses $MACHINE.
if [[ -z "${MACHINE:-}" && -n "$TARGET" ]]; then
    MACHINE="$(ssh "$TARGET" 'tr -d \\0 < /sys/firmware/devicetree/base/model')"
fi
if [[ -n "${MACHINE:-}" ]]; then
    echo "       machine: $MACHINE"
fi

echo "[3/5] Staging payloads (per SoC tree)"
rm -rf stage && mkdir -p stage/8380/fw stage/8380/dsp stage/8480/fw stage/8480/dsp

stage_soc() {
    local soc="$1"
    local fw="stage/$soc/fw" dsp="stage/$soc/dsp"
    find extracted -type f -path "*_${soc}_*" \
         \( -iname '*.mbn' -o -iname '*.elf' -o -iname '*.mdt' \
            -o -iname '*.b??' -o -iname '*.jsn' -o -iname '*.acdb' \
            -o -iname '*.qmp' -o -iname '*.fw' \) \
         -exec cp -n {} "$fw/" \;
    while IFS= read -r -d '' f; do
        cp -n "$f" "$dsp/"
    done < <(find extracted -type f -path "*_${soc}_*" \
                  \( -iname 'lib*skel*.so' -o -iname 'libQnnHtp*.so' \
                     -o -iname 'libSnpeHtp*.so' -o -iname 'fastrpc_shell_*' \) \
                  -print0)
    echo "       $soc: $(find $fw -type f | wc -l) fw / $(find $dsp -type f | wc -l) dsp"
}
stage_soc 8380
stage_soc 8480

echo "[4/5] Per-machine fastrpc YAMLs will be written during install"
SCHEMA="$FASTRPC_DIR/Docs/schemas/fastrpc-config-schema.yaml"

# ---------------------------------------------------------------------------
# 2. pick machine(s) + install
# ---------------------------------------------------------------------------
if [[ -z "$TARGET" && -z "$STAGE" ]]; then
    STAGE="$WORK/root"
    echo "       (no TARGET/STAGE set — staging to $STAGE)"
fi
# default MACHINE=all when staging (handy for creating a fleet image)
: "${MACHINE:=all}"
if [[ "$MACHINE" == "all" ]]; then
    ALL_MACHINES=(
        "Qualcomm Technologies, Inc. Glymur CRD"
        "ASUS Zenbook A16 (UX3607OA)"
        "HP EliteBook X G2q 14 AI"
        "Lenovo Yoga Slim 7x Gen 11"
        "Qualcomm Technologies, Inc. Mahua CRD"
        "Lenovo ThinkPad T14s Gen 7 (LCD)"
        "Qualcomm Technologies, Inc. Kolambo CRD"
        "Qualcomm Technologies, Inc. X1E80100 CRD"
        "Qualcomm Technologies, Inc. X1E80100 QCP"
        "Qualcomm Technologies, Inc. X1E001DE Snapdragon Devkit for Windows"
        "ASUS Vivobook S 15"
        "ASUS Zenbook A14 (UX3407RA)"
        "Dell Inspiron 14 Plus 7441"
        "Dell Latitude 7455"
        "Dell XPS 13 9345"
        "HONOR MagicBook Art 14 Snapdragon"
        "HP EliteBook Ultra G1q"
        "HP Omnibook X 14-fe0"
        "Lenovo Yoga Slim 7x"
        "Medion SPRCHRGD 14 S1"
    )
else
    ALL_MACHINES=("$MACHINE")
fi

# Install one machine into either $STAGE or (via rsync/ssh) $TARGET.
# For CRD/QCP boards the in-kernel DTS asks for the GENERIC names
#   adsp.mbn / cdsp.mbn
# while OEM boards use the installer's native qcadsp8380/qccdsp8480 names.
install_machine() {
    local machine="$1" fw_sub dsp_sub soc src_fw src_dsp root_fw root_dsp
    fw_sub="$(model_to_fw_subdir   "$machine")" || return 1
    dsp_sub="$(model_to_dsp_subdir "$machine")" || return 1
    soc="$(model_to_soc_tree       "$machine")" || return 1
    src_fw="stage/$soc/fw"
    src_dsp="stage/$soc/dsp"

    if [[ -n "$STAGE" ]]; then
        root_fw="$STAGE/lib/firmware/$fw_sub"
        root_dsp="$STAGE$QCOM_SHARE/$dsp_sub"
        mkdir -p "$root_fw" "$root_dsp"
        rsync -a --chmod=F0644 "$src_fw/"  "$root_fw/"
        rsync -a --chmod=F0644 "$src_dsp/" "$root_dsp/"
        case "$machine" in
            *CRD*|*QCP*)
                [[ -f "$root_fw/qccdsp${soc}.mbn" ]] && \
                    ln -sf "qccdsp${soc}.mbn" "$root_fw/cdsp.mbn"
                [[ -f "$root_fw/qcadsp${soc}.mbn" ]] && \
                    ln -sf "qcadsp${soc}.mbn" "$root_fw/adsp.mbn"
                ;;
        esac
    else
        ssh "$TARGET" "mkdir -p '/lib/firmware/$fw_sub' '$QCOM_SHARE/$dsp_sub'"
        rsync -a --chmod=F0644 "$src_fw/"  "$TARGET:/lib/firmware/$fw_sub/"
        rsync -a --chmod=F0644 "$src_dsp/" "$TARGET:$QCOM_SHARE/$dsp_sub/"
        case "$machine" in
            *CRD*|*QCP*)
                ssh "$TARGET" "cd /lib/firmware/$fw_sub && \
                    [ -f qccdsp${soc}.mbn ] && ln -sf qccdsp${soc}.mbn cdsp.mbn; \
                    [ -f qcadsp${soc}.mbn ] && ln -sf qcadsp${soc}.mbn adsp.mbn; \
                    true"
                ;;
        esac
    fi
    printf '       %-55s  soc=%s  → %s\n' "$machine" "$soc" "$dsp_sub"
}

echo "[5/5] Installing ${#ALL_MACHINES[@]} machine(s)"
for m in "${ALL_MACHINES[@]}"; do
    install_machine "$m" || echo "       SKIP (unmapped): $m" >&2
done

# one master fastrpc machine YAML with every installed board
if [[ -n "$STAGE" ]]; then
    mkdir -p "$STAGE$QCOM_SHARE/conf.d"
    write_master_yaml "$STAGE$QCOM_SHARE/conf.d/$YAML_NAME"
    echo
    echo "       YAML: $STAGE$QCOM_SHARE/conf.d/$YAML_NAME"
else
    ssh "$TARGET" "mkdir -p '$QCOM_SHARE/conf.d'"
    write_master_yaml "stage/$YAML_NAME"
    scp -q "stage/$YAML_NAME" "$TARGET:$QCOM_SHARE/conf.d/$YAML_NAME"
    ssh "$TARGET" "sync; echo 'Reboot the target to let the NPU driver reload firmware.'"
fi
