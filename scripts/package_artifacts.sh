#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f build/resolved.env ]]; then
  echo "build/resolved.env was not generated. Run scripts/resolve_package.py first." >&2
  exit 1
fi

source build/resolved.env

rm -rf "${PACKAGE_STAGE_DIR}" "${DIST_DIR}"
mkdir -p "${PACKAGE_STAGE_DIR}/${ARCHIVE_BASENAME}" "${DIST_DIR}"

copy_path_into_stage() {
  local relpath="$1"
  local src="${SOURCE_DIR}/${relpath}"
  local dest_dir="${PACKAGE_STAGE_DIR}/${ARCHIVE_BASENAME}/$(dirname "${relpath}")"

  if [[ ! -e "${src}" ]]; then
    echo "Expected output file not found: ${src}" >&2
    exit 1
  fi

  mkdir -p "${dest_dir}"
  cp -a "${src}" "${dest_dir}/"
}

copy_symlink_chain_into_stage() {
  local relpath="$1"
  local current_rel="${relpath}"
  local current_src="${SOURCE_DIR}/${relpath}"
  local link_target=""
  local next_src=""
  local next_rel=""
  local depth=0

  while [[ -L "${current_src}" ]]; do
    depth=$((depth + 1))
    if (( depth > 32 )); then
      echo "Symlink resolution exceeded 32 hops for ${relpath}" >&2
      exit 1
    fi

    link_target="$(readlink "${current_src}")"
    if [[ "${link_target}" = /* ]]; then
      next_src="${link_target}"
      case "${next_src}" in
        "${SOURCE_DIR}"/*)
          next_rel="${next_src#${SOURCE_DIR}/}"
          ;;
        *)
          echo "Symlink target escapes source tree: ${current_src} -> ${link_target}" >&2
          exit 1
          ;;
      esac
    else
      next_rel="$(python3 - "${current_rel}" "${link_target}" <<'PY'
import os
import sys

print(os.path.normpath(os.path.join(os.path.dirname(sys.argv[1]), sys.argv[2])))
PY
)"
      next_src="${SOURCE_DIR}/${next_rel}"
    fi

    if [[ ! -e "${next_src}" ]]; then
      echo "Symlink target not found: ${current_src} -> ${link_target}" >&2
      exit 1
    fi

    copy_path_into_stage "${next_rel}"
    current_rel="${next_rel}"
    current_src="${next_src}"
  done
}

while IFS= read -r relpath; do
  [[ -z "${relpath}" ]] && continue
  copy_path_into_stage "${relpath}"
  if [[ -L "${SOURCE_DIR}/${relpath}" ]]; then
    copy_symlink_chain_into_stage "${relpath}"
  fi
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
