#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f build/resolved.env ]]; then
  echo "build/resolved.env was not generated. Run scripts/resolve_package.py first." >&2
  exit 1
fi

source build/resolved.env

if command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  SUDO=()
fi

if [[ -f "${DEPENDENCY_SETUP_COMMANDS_FILE}" && -s "${DEPENDENCY_SETUP_COMMANDS_FILE}" ]]; then
  while IFS= read -r command; do
    [[ -z "${command}" ]] && continue
    echo "+ ${command}"
    if [[ ${#SUDO[@]} -gt 0 ]]; then
      "${SUDO[@]}" bash -lc "${command}"
    else
      bash -lc "${command}"
    fi
  done < "${DEPENDENCY_SETUP_COMMANDS_FILE}"
fi

if [[ ! -s "${BUILD_DEPENDENCIES_FILE}" ]]; then
  echo "No build dependencies declared."
  exit 0
fi

mapfile -t deps < "${BUILD_DEPENDENCIES_FILE}"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install --yes "${deps[@]}"
  exit 0
fi

echo "Automatic dependency installation is unavailable because apt-get is not present." >&2
echo "Preinstall these packages on the runner or extend scripts/install_build_deps.sh." >&2
printf 'Declared dependencies: %s\n' "${deps[*]}" >&2
