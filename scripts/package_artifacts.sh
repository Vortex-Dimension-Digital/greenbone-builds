#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f build/resolved.env ]]; then
  echo "build/resolved.env was not generated. Run scripts/resolve_package.py first." >&2
  exit 1
fi

source build/resolved.env

rm -rf "${PACKAGE_STAGE_DIR}" "${DIST_DIR}"
mkdir -p "${PACKAGE_STAGE_DIR}/${ARCHIVE_BASENAME}" "${DIST_DIR}"

while IFS= read -r relpath; do
  [[ -z "${relpath}" ]] && continue
  src="${SOURCE_DIR}/${relpath}"
  if [[ ! -e "${src}" ]]; then
    echo "Expected output file not found: ${src}" >&2
    exit 1
  fi
  dest_dir="${PACKAGE_STAGE_DIR}/${ARCHIVE_BASENAME}/$(dirname "${relpath}")"
  mkdir -p "${dest_dir}"
  cp -a "${src}" "${dest_dir}/"
done < "${OUTPUT_FILES_FILE}"

archive_path="${DIST_DIR}/${ARCHIVE_FILENAME}"

if command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  SUDO=()
fi

case "${ARCHIVE_FORMAT}" in
  tar.gz)
    tar -C "${PACKAGE_STAGE_DIR}" -czf "${archive_path}" "${ARCHIVE_BASENAME}"
    ;;
  tar.zst)
    if ! command -v zstd >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        "${SUDO[@]}" apt-get update
        "${SUDO[@]}" apt-get install --yes zstd
      else
        echo "zstd is required for tar.zst packaging." >&2
        exit 1
      fi
    fi
    tar -C "${PACKAGE_STAGE_DIR}" --zstd -cf "${archive_path}" "${ARCHIVE_BASENAME}"
    ;;
  *)
    echo "Unsupported archive format: ${ARCHIVE_FORMAT}" >&2
    exit 1
    ;;
esac

(
  cd "${DIST_DIR}"
  sha256sum "${ARCHIVE_FILENAME}" > "${CHECKSUM_FILENAME}"
)
