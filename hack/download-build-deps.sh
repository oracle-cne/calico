#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
METADATA_FILE="${REPO_ROOT}/metadata.mk"
RPM_SPEC="${REPO_ROOT}/buildrpm/calico.spec"

DEST_DIR=${DEST_DIR:-"${REPO_ROOT}/.offline-rpm-build-deps"}
ARCH=${ARCH:-}
DOWNLOAD_GO=true
DOWNLOAD_LIBBPF=true
DOWNLOAD_REGISTRAR=true
PREPARE_REPO=true
CHECK_ONLY=false
SKIP_REQUIREMENTS=false

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

run() {
  log "RUN: $*"
  "$@"
}

usage() {
  cat <<'USAGE'
Download only the network-backed inputs needed to build buildrpm/calico.spec offline.

Usage:
  hack/download-build-deps.sh [options]

Options:
  --dest DIR                Dependency cache directory. Default: .offline-rpm-build-deps.
  --arch ARCH               RPM target architecture: amd64, arm64, x86_64, or aarch64.
  --no-go                   Skip Go module and Go tool downloads.
  --no-libbpf               Skip libbpf source download and repository preparation.
  --no-registrar            Skip node-driver-registrar source download and staging.
  --no-prepare-repo         Do not stage source trees into repository build paths.
  --skip-requirements       Skip host tool availability checks.
  --check-only              Validate settings and host tools, then exit.
  -h, --help                Show this help.

Environment:
  DEST_DIR, ARCH, GOPATH, GOMODCACHE, GOCACHE, GOFLAGS.

Outputs:
  .offline-rpm-build-deps/go             Go module/tool cache.
  .offline-rpm-build-deps/git/libbpf     libbpf source checkout.
  .offline-rpm-build-deps/git/node-driver-registrar
  .offline-rpm-build-deps/offline-rpm-build-env.sh

Use before building the RPM offline:
  source .offline-rpm-build-deps/offline-rpm-build-env.sh
  rpmbuild -ba buildrpm/calico.spec
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || die "--dest requires an argument"
      DEST_DIR=$2
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires an argument"
      ARCH=$2
      shift 2
      ;;
    --no-go)
      DOWNLOAD_GO=false
      shift
      ;;
    --no-libbpf)
      DOWNLOAD_LIBBPF=false
      shift
      ;;
    --no-registrar)
      DOWNLOAD_REGISTRAR=false
      shift
      ;;
    --no-prepare-repo)
      PREPARE_REPO=false
      shift
      ;;
    --skip-requirements)
      SKIP_REQUIREMENTS=true
      shift
      ;;
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  command_exists "$1" || die "required command not found: $1"
}

metadata_value() {
  local key=$1
  awk -F'[?]?=' -v key="${key}" '{lhs=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs); if (lhs == key) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}}' "${METADATA_FILE}"
}

makefile_value() {
  local file=$1
  local key=$2
  awk -F'[?]?=' -v key="${key}" '{lhs=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs); if (lhs == key) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}}' "${file}"
}

canonical_arch() {
  local input_arch=$1
  case "${input_arch}" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    amd64|arm64) printf '%s' "${input_arch}" ;;
    *) die "unsupported RPM architecture '${input_arch}'. buildrpm/calico.spec maps only x86_64/amd64 and aarch64/arm64." ;;
  esac
}

ensure_dirs() {
  log "Creating RPM dependency cache layout under ${DEST_DIR}."
  mkdir -p \
    "${DEST_DIR}/git" \
    "${DEST_DIR}/go/bin" \
    "${DEST_DIR}/go/cache" \
    "${DEST_DIR}/go/pkg/mod" \
    "${DEST_DIR}/logs"
}

check_requirements() {
  if [[ "${SKIP_REQUIREMENTS}" == "true" ]]; then
    log "Skipping host requirement checks."
    return
  fi

  log "Checking host tools needed by the RPM dependency downloader."
  require_cmd awk
  require_cmd git
  require_cmd tar
  if [[ "${DOWNLOAD_GO}" == "true" ]]; then
    require_cmd go
  fi
}

load_versions() {
  log "Loading RPM build dependency versions."
  [[ -f "${METADATA_FILE}" ]] || die "metadata file not found: ${METADATA_FILE}"
  [[ -f "${RPM_SPEC}" ]] || die "RPM spec not found: ${RPM_SPEC}"

  LIBBPF_VERSION=$(metadata_value LIBBPF_VERSION)
  [[ -n "${LIBBPF_VERSION}" ]] || die "LIBBPF_VERSION not found in ${METADATA_FILE}"
  REGISTRAR_IMAGE=$(makefile_value "${REPO_ROOT}/pod2daemon/Makefile" REGISTRAR_IMAGE)
  UPSTREAM_REGISTRAR_PROJECT=$(makefile_value "${REPO_ROOT}/pod2daemon/Makefile" UPSTREAM_REGISTRAR_PROJECT)
  UPSTREAM_REGISTRAR_TAG=$(makefile_value "${REPO_ROOT}/pod2daemon/Makefile" UPSTREAM_REGISTRAR_TAG | awk '{print $1}')
  [[ -n "${REGISTRAR_IMAGE}" ]] || die "REGISTRAR_IMAGE not found in pod2daemon/Makefile"
  [[ -n "${UPSTREAM_REGISTRAR_PROJECT}" ]] || die "UPSTREAM_REGISTRAR_PROJECT not found in pod2daemon/Makefile"
  [[ -n "${UPSTREAM_REGISTRAR_TAG}" ]] || die "UPSTREAM_REGISTRAR_TAG not found in pod2daemon/Makefile"
  UPSTREAM_REGISTRAR_PROJECT=${UPSTREAM_REGISTRAR_PROJECT/'$(REGISTRAR_IMAGE)'/${REGISTRAR_IMAGE}}

  if [[ -z "${ARCH}" ]]; then
    ARCH=$(canonical_arch "$(uname -m)")
  else
    ARCH=$(canonical_arch "${ARCH}")
  fi

  log "RPM dependency versions: LIBBPF_VERSION=${LIBBPF_VERSION}, REGISTRAR=${UPSTREAM_REGISTRAR_PROJECT}@${UPSTREAM_REGISTRAR_TAG}, ARCH=${ARCH}."
}

clone_libbpf() {
  if [[ "${DOWNLOAD_LIBBPF}" != "true" ]]; then
    log "Skipping libbpf source download."
    return
  fi

  local output_dir="${DEST_DIR}/git/libbpf"
  if [[ -d "${output_dir}/.git" ]]; then
    log "Updating existing libbpf checkout: ${output_dir}."
    run git -C "${output_dir}" fetch --tags origin "${LIBBPF_VERSION}"
    run git -C "${output_dir}" checkout "${LIBBPF_VERSION}"
    delete_libbpf_logo_assets "${output_dir}"
    return
  fi

  rm -rf "${output_dir}"
  log "Cloning libbpf ${LIBBPF_VERSION} for Felix RPM build input."
  run git clone --depth 1 --single-branch --branch "${LIBBPF_VERSION}" https://github.com/libbpf/libbpf.git "${output_dir}"
  delete_libbpf_logo_assets "${output_dir}"
}


delete_libbpf_logo_assets() {
  local libbpf_dir=$1
  if [[ ! -d "${libbpf_dir}" ]]; then
    log "No libbpf directory present for logo cleanup: ${libbpf_dir}"
    return
  fi

  log "Deleting libbpf logo assets under ${libbpf_dir}."
  while IFS= read -r logo_asset; do
    log "Deleting libbpf logo asset: ${logo_asset}"
    rm -f "${logo_asset}"
  done < <(find "${libbpf_dir}" -type f \( -iname '*logo*' -o -iname '*icon*' \) | sort)
}

copy_libbpf_worktree() {
  if [[ "${DOWNLOAD_LIBBPF}" != "true" || "${PREPARE_REPO}" != "true" ]]; then
    log "Skipping libbpf repository staging."
    return
  fi

  local source_repo="${DEST_DIR}/git/libbpf"
  local target_dir="${REPO_ROOT}/felix/bpf-gpl/libbpf"
  local marker="${REPO_ROOT}/felix/bpf-gpl/.libbpf-${LIBBPF_VERSION}"

  [[ -d "${source_repo}/.git" ]] || die "libbpf checkout missing: ${source_repo}"
  log "Staging libbpf ${LIBBPF_VERSION} into ${target_dir}."
  rm -rf "${target_dir}"
  mkdir -p "${target_dir}"
  run bash -c "git -C '$source_repo' archive '${LIBBPF_VERSION}' | tar -x -C '$target_dir'"
  delete_libbpf_logo_assets "${target_dir}"
  rm -rf "${REPO_ROOT}/felix/bpf-gpl"/.libbpf-*
  printf '%s\n' "${LIBBPF_VERSION}" > "${marker}"
}

clone_registrar() {
  if [[ "${DOWNLOAD_REGISTRAR}" != "true" ]]; then
    log "Skipping node-driver-registrar source download."
    return
  fi

  local output_dir="${DEST_DIR}/git/${REGISTRAR_IMAGE}"
  if [[ ! -d "${output_dir}/.git" ]]; then
    rm -rf "${output_dir}"
    log "Cloning ${UPSTREAM_REGISTRAR_PROJECT} for RPM node-driver-registrar build input."
    run git clone --depth 1 "https://github.com/${UPSTREAM_REGISTRAR_PROJECT}.git" "${output_dir}"
  fi

  log "Checking out node-driver-registrar source ${UPSTREAM_REGISTRAR_TAG}."
  run git -C "${output_dir}" fetch --tags origin "${UPSTREAM_REGISTRAR_TAG}" || true
  run git -C "${output_dir}" checkout "${UPSTREAM_REGISTRAR_TAG}"
}

copy_registrar_worktree() {
  if [[ "${DOWNLOAD_REGISTRAR}" != "true" || "${PREPARE_REPO}" != "true" ]]; then
    log "Skipping node-driver-registrar repository staging."
    return
  fi

  local source_repo="${DEST_DIR}/git/${REGISTRAR_IMAGE}"
  local target_dir="${REPO_ROOT}/pod2daemon/${REGISTRAR_IMAGE}"

  [[ -d "${source_repo}/.git" ]] || die "node-driver-registrar checkout missing: ${source_repo}"
  log "Staging node-driver-registrar ${UPSTREAM_REGISTRAR_TAG} into ${target_dir}."
  rm -rf "${target_dir}"
  mkdir -p "${target_dir}"
  run bash -c "git -C '$source_repo' archive '${UPSTREAM_REGISTRAR_TAG}' | tar -x -C '$target_dir'"
}

prepare_libbpf_public_headers() {
  if [[ "${DOWNLOAD_LIBBPF}" != "true" || "${PREPARE_REPO}" != "true" ]]; then
    log "Skipping libbpf public header preparation."
    return
  fi

  local libbpf_dir="${REPO_ROOT}/felix/bpf-gpl/libbpf"
  local source_dir="${libbpf_dir}/src"
  local include_root="${libbpf_dir}/offline-include"
  local bpf_include_dir="${include_root}/bpf"
  local iproute2_include_dir="${include_root}/iproute2"
  local header
  local headers=(
    bpf_core_read.h
    bpf_endian.h
    bpf_helper_defs.h
    bpf_helpers.h
    bpf_tracing.h
    libbpf.h
    libbpf_common.h
    libbpf_legacy.h
    libbpf_version.h
  )

  log "Preparing libbpf public headers required by felix/hack/build-felix-host.sh."
  [[ -d "${source_dir}" ]] || die "libbpf source directory missing after staging: ${source_dir}"
  rm -rf "${include_root}"
  mkdir -p "${bpf_include_dir}" "${iproute2_include_dir}"
  for header in "${headers[@]}"; do
    [[ -f "${source_dir}/${header}" ]] || die "required libbpf public header missing: ${source_dir}/${header}"
    run cp "${source_dir}/${header}" "${bpf_include_dir}/${header}"
  done
  log "Writing offline iproute2 bpf_elf.h compatibility header."
  cat > "${iproute2_include_dir}/bpf_elf.h" <<'HEADER'
#ifndef __CALI_OFFLINE_IPROUTE2_BPF_ELF_H__
#define __CALI_OFFLINE_IPROUTE2_BPF_ELF_H__

/* Compatibility header for offline Calico BPF builds. */

#endif /* __CALI_OFFLINE_IPROUTE2_BPF_ELF_H__ */
HEADER
}

download_go_dependencies() {
  if [[ "${DOWNLOAD_GO}" != "true" ]]; then
    log "Skipping Go dependency downloads."
    return
  fi

  log "Downloading Go modules required by buildrpm/calico.spec host go builds."
  export GOPATH=${GOPATH:-"${DEST_DIR}/go"}
  export GOMODCACHE=${GOMODCACHE:-"${DEST_DIR}/go/pkg/mod"}
  export GOCACHE=${GOCACHE:-"${DEST_DIR}/go/cache"}
  export GOBIN="${DEST_DIR}/go/bin"
  export PATH="${GOBIN}:${PATH}"

  run go -C "${REPO_ROOT}" mod download
  if [[ "${DOWNLOAD_REGISTRAR}" == "true" && -f "${DEST_DIR}/git/${REGISTRAR_IMAGE}/go.mod" ]]; then
    log "Downloading Go modules required by ${UPSTREAM_REGISTRAR_PROJECT}."
    run go -C "${DEST_DIR}/git/${REGISTRAR_IMAGE}" mod download
  fi

  log "Go dependency download complete."
}

write_offline_env() {
  local env_file="${DEST_DIR}/offline-rpm-build-env.sh"
  log "Writing offline RPM build environment helper: ${env_file}."
  cat > "${env_file}" <<ENV
#!/usr/bin/env bash
export CALICO_OFFLINE_RPM_DEPS="${DEST_DIR}"
export GOPATH="${DEST_DIR}/go"
export GOMODCACHE="${DEST_DIR}/go/pkg/mod"
export GOCACHE="${DEST_DIR}/go/cache"
export PATH="${DEST_DIR}/go/bin:\$PATH"
export GOSUMDB=off
export GOPROXY=off
ENV
  chmod +x "${env_file}"
}

write_manifest() {
  local manifest_file="${DEST_DIR}/manifest.txt"
  log "Writing RPM dependency manifest: ${manifest_file}."
  {
    printf 'repo_root=%s\n' "${REPO_ROOT}"
    printf 'rpm_spec=%s\n' "${RPM_SPEC}"
    printf 'generated_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'arch=%s\n' "${ARCH}"
    printf 'libbpf_version=%s\n' "${LIBBPF_VERSION}"
    printf 'registrar_project=%s\n' "${UPSTREAM_REGISTRAR_PROJECT}"
    printf 'registrar_tag=%s\n' "${UPSTREAM_REGISTRAR_TAG}"
    printf 'go_modules=go.mod\n'
  } > "${manifest_file}"
}

main() {
  log "Starting RPM-only Calico build dependency download."
  load_versions
  ensure_dirs
  check_requirements
  log "Download plan: go=${DOWNLOAD_GO} libbpf=${DOWNLOAD_LIBBPF} registrar=${DOWNLOAD_REGISTRAR} prepare_repo=${PREPARE_REPO} check_only=${CHECK_ONLY}."
  if [[ "${CHECK_ONLY}" == "true" ]]; then
    log "Check-only mode complete. No dependencies were downloaded."
    exit 0
  fi
  clone_libbpf
  clone_registrar
  download_go_dependencies
  copy_libbpf_worktree
  copy_registrar_worktree
  prepare_libbpf_public_headers
  write_offline_env
  write_manifest
  log "RPM-only Calico build dependency download complete."
}

main "$@"
