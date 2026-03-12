#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f build/resolved.env ]]; then
  echo "build/resolved.env was not generated. Run scripts/resolve_package.py first." >&2
  exit 1
fi

source build/resolved.env

rm -rf "${SOURCE_DIR}"
mkdir -p "$(dirname "${SOURCE_DIR}")"

if command -v nproc >/dev/null 2>&1; then
  BUILD_JOBS="$(nproc)"
elif command -v getconf >/dev/null 2>&1; then
  BUILD_JOBS="$(getconf _NPROCESSORS_ONLN)"
else
  BUILD_JOBS=1
fi
export BUILD_JOBS

if [[ -f "${BUILD_ENV_FILE}" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "${key}" ]] && continue
    export "${key}=${value}"
  done < <(python3 - <<'PY'
import json
from pathlib import Path

data = json.loads(Path("build/build-env.json").read_text())
for key, value in data.items():
    print(f"{key}={value}")
PY
)
fi

# Some upstream build systems read generic ARCH from the environment.
# Keep the workflow target under TARGET_ARCH and avoid leaking runner-specific values.
unset ARCH || true

git clone --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_REPO}" "${SOURCE_DIR}" 2>/dev/null || {
  git clone "${UPSTREAM_REPO}" "${SOURCE_DIR}"
  git -C "${SOURCE_DIR}" checkout "${UPSTREAM_REF}"
}

build_dir="${SOURCE_DIR}/${BUILD_SUBDIR}"
if [[ ! -d "${build_dir}" ]]; then
  mkdir -p "${build_dir}"
fi

pushd "${build_dir}" >/dev/null
while IFS= read -r command; do
  [[ -z "${command}" ]] && continue
  echo "+ ${command}"
  bash -lc "${command}"
done < "${BUILD_COMMANDS_FILE}"
popd >/dev/null
