#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=nsjail/lib/constants.sh
source "${ROOT}/nsjail/lib/constants.sh"

dest="${SCRIPTS_ROOT}/.local/bin/nsjail"
lib_dir="${SCRIPTS_ROOT}/.local/lib"
mkdir -p "$(dirname "${dest}")" "${lib_dir}"

echo "Building spike image (includes NsJail ${NSJAIL_VERSION})..."
runner_sha="$(sha256sum "${NSJAIL_EXPERIMENT_DIR}/runner.sh" | awk '{print $1}')"
docker build \
  --build-arg RUNNER_SCRIPT_SHA="${runner_sha}" \
  -t "${NSJAIL_SPIKE_IMAGE}" \
  "${NSJAIL_EXPERIMENT_DIR}"

cid="$(docker create "${NSJAIL_SPIKE_IMAGE}")"
trap 'docker rm -f "${cid}" >/dev/null 2>&1 || true' EXIT
docker cp "${cid}:/usr/local/bin/nsjail" "${dest}"
chmod 0555 "${dest}"

for lib in libprotobuf.so.23 libnl-route-3.so.200; do
  resolved="$(docker run --rm --entrypoint readlink "${NSJAIL_SPIKE_IMAGE}" -f "/usr/lib/x86_64-linux-gnu/${lib}")"
  docker cp "${cid}:${resolved}" "${lib_dir}/${lib}"
  chmod 0644 "${lib_dir}/${lib}"
done

export LD_LIBRARY_PATH="${lib_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
echo "Installed ${dest} (runtime libs in ${lib_dir})"
"${dest}" --help 2>&1 | head -1
