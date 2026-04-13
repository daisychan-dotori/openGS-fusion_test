#!/usr/bin/env bash
# =============================================================================
# download_weights.sh
# Downloads MobileSAMv2 weights from Google Drive and places them into
# the expected directory inside the OpenGS-Fusion submodule tree.
# =============================================================================

set -euo pipefail

WEIGHT_DIR="${OPENGS_ROOT}/submodules/MobileSAM/MobileSAMv2/weight"
GDRIVE_FILE_ID="1dE-YAG-1mFCBmao2rHDp0n-PP4eH7SjE"
ARCHIVE_NAME="mobileSAMv2_weights.zip"
EXPECTED_FILES=("l2.pt" "mobile_sam.pt" "ObjectAwareModel.pt")

echo "========================================="
echo " MobileSAMv2 Weight Downloader"
echo "========================================="

# ── already downloaded? ───────────────────────────────────────────────────────
all_present=true
for f in "${EXPECTED_FILES[@]}"; do
    if [[ ! -f "${WEIGHT_DIR}/${f}" ]]; then
        all_present=false
        break
    fi
done

if $all_present; then
    echo "[✓] All weights already present — skipping download."
    exit 0
fi

# ── create destination directory ──────────────────────────────────────────────
mkdir -p "${WEIGHT_DIR}"

# ── resolve pip (prefer conda env pip if OPENGS_ENV is set) ──────────────────
if [[ -n "${OPENGS_ENV:-}" && -x "${OPENGS_ENV}/bin/pip" ]]; then
    PIP="${OPENGS_ENV}/bin/pip"
else
    PIP="$(command -v pip)"
fi

# ── install gdown if necessary ────────────────────────────────────────────────
if ! command -v gdown &>/dev/null; then
    echo "[*] Installing gdown ..."
    $PIP install --quiet gdown
fi

# ── download from Google Drive ───────────────────────────────────────────────
echo "[*] Downloading weights (file ID: ${GDRIVE_FILE_ID}) ..."
# Use command -v to locate gdown; fail fast with a clear message if missing
GDOWN_BIN="$(command -v gdown 2>/dev/null || true)"
if [[ -z "$GDOWN_BIN" ]]; then
    echo "[✗] ERROR: gdown not found in PATH. PATH=$PATH"
    exit 1
fi
$GDOWN_BIN --fuzzy \
           "https://drive.google.com/file/d/${GDRIVE_FILE_ID}/view" \
           -O "/tmp/${ARCHIVE_NAME}"

# ── extract ───────────────────────────────────────────────────────────────────
echo "[*] Extracting archive ..."
TMP_EXTRACT="/tmp/mobileSAMv2_weights"
mkdir -p "${TMP_EXTRACT}"

case "${ARCHIVE_NAME}" in
    *.zip)  unzip -q "/tmp/${ARCHIVE_NAME}" -d "${TMP_EXTRACT}" ;;
    *.tar.gz|*.tgz) tar -xzf "/tmp/${ARCHIVE_NAME}" -C "${TMP_EXTRACT}" ;;
    *.tar)  tar -xf  "/tmp/${ARCHIVE_NAME}" -C "${TMP_EXTRACT}" ;;
    *.pt)
        # The archive is itself a single weight file (unlikely, but handled)
        cp "/tmp/${ARCHIVE_NAME}" "${WEIGHT_DIR}/"
        ;;
esac

# ── copy .pt files into the weight directory ──────────────────────────────────
echo "[*] Placing weight files into ${WEIGHT_DIR} ..."
find "${TMP_EXTRACT}" -name "*.pt" -exec cp -v {} "${WEIGHT_DIR}/" \;

# ── clean up ──────────────────────────────────────────────────────────────────
rm -rf "/tmp/${ARCHIVE_NAME}" "${TMP_EXTRACT}"

# ── verify ───────────────────────────────────────────────────────────────────
echo "[*] Verifying weight files ..."
missing=()
for f in "${EXPECTED_FILES[@]}"; do
    if [[ ! -f "${WEIGHT_DIR}/${f}" ]]; then
        missing+=("$f")
    fi
done

if [[ ${#missing[@]} -ne 0 ]]; then
    echo ""
    echo "[✗] ERROR: The following weight files are missing after extraction:"
    for f in "${missing[@]}"; do echo "      - ${f}"; done
    echo ""
    echo "    This usually means the archive layout differs from what was expected."
    echo "    Please download the weights manually from:"
    echo "    https://drive.google.com/file/d/${GDRIVE_FILE_ID}/view"
    echo "    and place l2.pt, mobile_sam.pt, ObjectAwareModel.pt into:"
    echo "    ${WEIGHT_DIR}"
    exit 1
fi

echo ""
echo "[✓] All weight files downloaded successfully:"
for f in "${EXPECTED_FILES[@]}"; do
    echo "      ${WEIGHT_DIR}/${f}"
done
echo "========================================="