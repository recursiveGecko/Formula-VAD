#!/usr/bin/env bash
set -eo pipefail

NAME=deepfilternet
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DOWNLOAD_URL=$1
BLESSED_RUST_VERSION="1.77.0"
BLESSED_CARGO_C_VERSION="0.9.31"
TARGETS=("x86_64-unknown-linux-gnu")
set -u

if [ -z "$DOWNLOAD_URL" ]; then
  echo ".tar.gz download URL must be provided as first and only argument"
  exit 1
fi

set +e
REQUIRED_TOOLS=(curl unzip cargo rustup)
for tool in "${REQUIRED_TOOLS[@]}"; do
  which ${tool} > /dev/null
  if [ $? -ne 0 ]; then
    echo "Required command '${tool}' is not available in \$PATH."
    exit 1
  fi
done
set -e


BUILD_ROOT_DIR="${SCRIPT_DIR}/build_root"
TARGET_DIR="${SCRIPT_DIR}/target"
MODELS_DIR="${SCRIPT_DIR}/models"
FILE_NAME="DeepFilterNet.tar.gz"
VERSION_FILE="${TARGET_DIR}/VERSION.txt"

EXISTING_VERSION=$(cat ${VERSION_FILE} 2>/dev/null || true )
if [ "${EXISTING_VERSION}" = "${DOWNLOAD_URL}" ]; then
  echo "${NAME} is up to date - ${DOWNLOAD_URL}"
  exit 0
fi

echo "Downloading ${DOWNLOAD_URL}"

set -x
# Install blessed Rust version
rustup install "${BLESSED_RUST_VERSION}"
cargo install "cargo-c@${BLESSED_CARGO_C_VERSION}"
# Re-create build root
rm -r "${BUILD_ROOT_DIR}" 2>&1 >/dev/null || true
mkdir -p "${BUILD_ROOT_DIR}"
cd "${BUILD_ROOT_DIR}"
# Download and extract DFN
curl --fail --location "${DOWNLOAD_URL}" -o "${FILE_NAME}"
tar xvf "${FILE_NAME}" --strip-components 1

# Clean output directory, models directory and Rust cache
rm -r "${TARGET_DIR}" 2>&1 >/dev/null || true
rm -r "${MODELS_DIR}" 2>&1 >/dev/null || true
# Copy cbindgen.toml to libDF, `cinstall` doesn't seem to be using the one in root directory for some reason.
# The "state" of the project directory also seems to get cached between builds, so if this step isn't performed correctly
# `cargo cinstall` will keep generating C++ headers rather than C headers even after the file is later copied in correct
# location. To resolve this, run `cargo clean`. If the file is now in correct position, `cargo cinstall` should work as expected.
cp cbindgen.toml libDF
# Build DeepFilterNet, copy artifacts to ./out
for target in "${TARGETS[@]}"; do
  cargo "+${BLESSED_RUST_VERSION}" cinstall --frozen --package deep_filter --profile release-lto --target "${target}" --prefix "${TARGET_DIR}/${target}"
done

# Copy models over too
cp -r models "${MODELS_DIR}"
# # Delete build root
rm -r "${BUILD_ROOT_DIR}"
set +x

# Save version file
echo -n "${DOWNLOAD_URL}" > "${VERSION_FILE}"
echo "DeepFilterNet built successfully."
