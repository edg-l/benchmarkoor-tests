#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTEXTS_DIR="${REPO_ROOT}/configs/contexts"

# Only the repricing/v1/* contexts are dispatched. Each subdir there maps to a
# benchmarkoor-run.yaml dispatch with context=repricing, subdir=v1/<name>,
# snapshot=state-actor/v1.
CONTEXT="repricing"
VERSION="v1"
SNAPSHOT="state-actor/${VERSION}"
V1_DIR="${CONTEXTS_DIR}/${CONTEXT}/${VERSION}"

CLIENTS=(geth erigon nethermind besu reth ethrex)

cap() {
  local s="$1"
  printf '%s%s' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')" "${s:1}"
}

# Run-phase timeout in minutes for a (client, test_type) combo. Feeds the "run"
# field of the benchmarkoor-run.yaml `timeouts` JSON input.
get_run_timeout() {
  local client="$1" test_type="$2"
  if [[ "$test_type" == "stateful" ]]; then
    if [[ "$client" == "erigon" ]]; then
      echo "4500"
    else
      echo "2160"
    fi
  elif [[ "$test_type" == "compute" && ( "$client" == "erigon" || "$client" == "reth" ) ]]; then
    echo "900"
  else
    echo "360"
  fi
}

# Build-phase timeout (minutes) for the benchmarkoor-run.yaml state-actor build
# step. Matches the workflow's own default.
BUILD_TIMEOUT=360

# Print the dispatchable instance ids for a client, in clients.yaml order:
# `<client>-bal-full` and its AOT twin `<client>-bal-full-aot`, when present.
# Other variants (bal-sequential, bal-nobatchio, bare client name, …) are ignored.
get_dispatch_ids() {
  local clients_yaml="$1" client="$2"
  [[ -f "$clients_yaml" ]] || return 0

  local id
  while IFS= read -r id; do
    case "$id" in
      "${client}-bal-full"|"${client}-bal-full-aot") echo "$id" ;;
    esac
  done < <(sed -nE 's/^[[:space:]]+-[[:space:]]*id:[[:space:]]*([^[:space:]]+).*/\1/p' "$clients_yaml")
}

context_display="$(cap "$CONTEXT")"

for client in "${CLIENTS[@]}"; do
  outfile="${SCRIPT_DIR}/benchmarkoor.${client}.yaml"
  client_display="$(cap "$client")"

  entries=()

  while IFS= read -r subdir_path; do
    [[ -e "${subdir_path}/.dispatchoor_ignore" ]] && continue

    name="$(basename "$subdir_path")"
    subdir="${VERSION}/${name}"

    # Discover test types from the runner test-source files
    # (test-source.<type>.runner.yaml → <type>).
    test_types=()
    for ts in "${subdir_path}"/test-source.*.runner.yaml; do
      [[ -e "$ts" ]] || continue
      tt="${ts##*/test-source.}"
      tt="${tt%.runner.yaml}"
      [[ "$tt" == *.* ]] && continue
      test_types+=("$tt")
    done
    [[ ${#test_types[@]} -gt 0 ]] || continue

    # Dispatch the client's bal-full instance plus its AOT twin; skip subdirs
    # with neither.
    instance_ids=()
    while IFS= read -r found_id; do
      instance_ids+=("$found_id")
    done < <(get_dispatch_ids "${subdir_path}/clients.yaml" "$client")
    [[ ${#instance_ids[@]} -gt 0 ]] || continue

    entries+=("# --- Subdir: ${subdir} ---")

    for instance_id in "${instance_ids[@]}"; do
    for test_type in "${test_types[@]}"; do
      test_type_display="$(cap "$test_type")"
      run_timeout="$(get_run_timeout "$client" "$test_type")"
      global_timeout=$(( BUILD_TIMEOUT + run_timeout ))

      entries+=("- id: benchmarkoor-${client}-${CONTEXT}-${VERSION}-${name}-${test_type}-${instance_id}
  name: \"(${client_display}) - ${context_display} - ${subdir} - ${test_type_display} - ${instance_id}\"
  owner: ethpandaops
  repo: benchmarkoor-tests
  workflow_id: benchmarkoor-run.yaml
  ref: master
  labels:
    el-client: \"${client}\"
    snapshot: \"${SNAPSHOT}\"
    subdir: \"${subdir}\"
    test-type: \"${test_type}\"
    context: \"${CONTEXT}\"
    instance-id: \"${instance_id}\"
  inputs:
    clients: '[\"${client}\"]'
    instance-id: \"${instance_id}\"
    snapshot: \"${SNAPSHOT}\"
    subdir: \"${subdir}\"
    test-type: \"${test_type}\"
    context: \"${CONTEXT}\"
    timeouts: '{\"build\": ${BUILD_TIMEOUT}, \"run\": ${run_timeout}, \"global\": ${global_timeout}}'")
    done
    done
  done < <(find "${V1_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)

  {
    echo "# AUTO-GENERATED FILE - DO NOT EDIT MANUALLY"
    echo "# Regenerate with: make config (or ./dispatchoor/generate.sh)"
    echo "# Source: configs/contexts/repricing/v1/<subdir>/"
    for entry in "${entries[@]}"; do
      echo ""
      echo "$entry"
    done
  } > "${outfile}"
  echo "Generated ${outfile} (${#entries[@]} entries)"
done
