#!/usr/bin/env bash
set -eo pipefail

NAME=libduckdb
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
RELEASE_TAG=$1
PLATFORMS=(linux-amd64)
set -u

if [ -z "$RELEASE_TAG" ]; then
  echo "GitHub tag must be provided as first and only argument"
  exit 1
fi

set +e
REQUIRED_TOOLS=(curl unzip)
for tool in "${REQUIRED_TOOLS[@]}"; do
  which ${tool} > /dev/null
  if [ $? -ne 0 ]; then
    echo "Required command '${tool}' is not available in \$PATH."
    exit 1
  fi
done
set -e

for platform in "${PLATFORMS[@]}"; do
  PLATFORM_DIR="${SCRIPT_DIR}/${platform}"
  LIBDUCKDB_ARCHIVE="libduckdb-${platform}.zip"
  DOWNLOAD_URL="https://github.com/duckdb/duckdb/releases/download/${RELEASE_TAG}/${LIBDUCKDB_ARCHIVE}"
  VERSION_FILE="${PLATFORM_DIR}/VERSION.txt"

  EXISTING_VERSION=$(cat ${VERSION_FILE} 2>/dev/null || true )
  if [ "${EXISTING_VERSION}" = "${DOWNLOAD_URL}" ]; then
    echo "${NAME} ${platform} is up to date"
    continue
  fi

  echo "Downloading ${RELEASE_TAG} for ${platform} from ${DOWNLOAD_URL}"

  mkdir -p "${PLATFORM_DIR}"
  cd "${PLATFORM_DIR}"
  curl --fail --location "${DOWNLOAD_URL}" -o "${LIBDUCKDB_ARCHIVE}"
  unzip -o "${LIBDUCKDB_ARCHIVE}"
  rm "${LIBDUCKDB_ARCHIVE}"
  echo -n "${DOWNLOAD_URL}" > "${VERSION_FILE}"
done
