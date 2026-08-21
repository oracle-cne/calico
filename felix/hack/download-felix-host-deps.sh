#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FELIX_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd "${FELIX_DIR}/.." && pwd)
METADATA_FILE="${REPO_ROOT}/metadata.mk"

DOWNLOAD_BPF=true
SKIP_REQUIREMENTS=false
CHECK_ONLY=false
ARCH=${ARCH:-}
GOFLAGS=${GOFLAGS:-}
GOAMD64=${GOAMD64:-v2}
PROTOC_GEN_GO_VERSION=${PROTOC_GEN_GO_VERSION:-v1.36.11}
PROTOC_GEN_GO_GRPC_VERSION=${PROTOC_GEN_GO_GRPC_VERSION:-v1.6.0}
STRINGER_VERSION=${STRINGER_VERSION:-v0.41.0}

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
Download Felix host-build dependencies without Docker or invoking make.

Usage:
  felix/hack/download-felix-host-deps.sh [options]

Options:
  --arch ARCH              Target architecture: amd64, arm64, ppc64le, or s390x.
  --no-bpf                 Do not fetch libbpf.
  --skip-requirements      Skip host tool availability checks.
  --check-only             Validate settings and host tools, then exit.
  -h, --help               Show this help.

Environment:
  ARCH, GOFLAGS, GOAMD64, GOPATH, PROTOC_GEN_GO_VERSION,
  PROTOC_GEN_GO_GRPC_VERSION, STRINGER_VERSION.

Downloads:
  Go modules for the repository.
  stringer, protoc-gen-go, and protoc-gen-go-grpc into GOPATH/bin.
  felix/bpf-gpl/libbpf at LIBBPF_VERSION unless --no-bpf.

Generates:
  felix/bpf/asm generated Go sources.
  felix/routetable generated Go sources.
  felix/proto generated Go sources when protobuf outputs are missing or stale.
  felix/bpf-gpl/libbpf/offline-include public header layout for offline BPF builds.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires an argument"
      ARCH=$2
      shift 2
      ;;
    --no-bpf)
      DOWNLOAD_BPF=false
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

metadata_value() {
  local key=$1
  awk -F= -v key="${key}" '$1 == key {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "${METADATA_FILE}"
}

canonical_arch() {
  local value=$1
  case "${value}" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    amd64|arm64|ppc64le|s390x) printf '%s' "${value}" ;;
    *) die "unsupported architecture '${value}'" ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  command_exists "$1" || die "required command not found: $1"
}

newer_than() {
  local output=$1
  shift
  [[ ! -e "${output}" ]] && return 0
  local input
  for input in "$@"; do
    [[ "${input}" -nt "${output}" ]] && return 0
  done
  return 1
}

go_env_setup() {
  export GOCACHE="${REPO_ROOT}/.go-pkg-cache"
  export GOPATH=${GOPATH:-"$(go env GOPATH)"}
  export PATH="$(go env GOPATH)/bin:${PATH}"
  export GOARCH="${ARCH}"
  export GOFLAGS
  if [[ "${ARCH}" == "amd64" ]]; then
    export GOAMD64
  fi
  mkdir -p "${GOCACHE}" "${FELIX_DIR}/bin"
  log "Go environment: GOARCH=${GOARCH} GOAMD64=${GOAMD64:-unset} GOCACHE=${GOCACHE} GOFLAGS=${GOFLAGS:-unset}"
}

check_requirements() {
  if [[ "${SKIP_REQUIREMENTS}" == "true" ]]; then
    log "Skipping host requirement checks."
    return
  fi

  log "Checking host requirements for dependency download."
  require_cmd git
  require_cmd go
}

fetch_go_modules() {
  log "Fetching Go module dependencies without make."
  run go -C "${REPO_ROOT}" mod download
}

install_go_tool() {
  local binary=$1
  local package=$2
  local version=$3

  if command_exists "${binary}"; then
    log "Go tool already available: ${binary}"
    return
  fi
  log "Installing generated-code tool without make: ${package}@${version}"
  run go install "${package}@${version}"
  command_exists "${binary}" || die "installed ${package}@${version}, but '${binary}' is still not on PATH"
}

install_generated_code_tools() {
  log "Installing generated-code tool dependencies."
  install_go_tool stringer golang.org/x/tools/cmd/stringer "${STRINGER_VERSION}"
  install_go_tool protoc-gen-go google.golang.org/protobuf/cmd/protoc-gen-go "${PROTOC_GEN_GO_VERSION}"
  install_go_tool protoc-gen-go-grpc google.golang.org/grpc/cmd/protoc-gen-go-grpc "${PROTOC_GEN_GO_GRPC_VERSION}"
}

generate_go_files() {
  log "Generating Go sources before any binary build."
  run go -C "${FELIX_DIR}" generate ./bpf/asm/
  run go -C "${FELIX_DIR}" generate ./routetable/

  if newer_than "${FELIX_DIR}/proto/felixbackend.pb.go" "${FELIX_DIR}/proto/felixbackend.proto" || \
     newer_than "${FELIX_DIR}/proto/felixbackend_grpc.pb.go" "${FELIX_DIR}/proto/felixbackend.proto"; then
    require_cmd protoc
    run env -C "${FELIX_DIR}/proto" protoc --proto_path=. --go_out=. --go-grpc_out=.. --go_opt=paths=source_relative felixbackend.proto
  else
    log "Protobuf outputs are present and not older than proto/felixbackend.proto."
  fi
}

remove_cloned_repo_git_metadata() {
  local repo_dir=$1
  local git_dir="${repo_dir}/.git"

  if [[ ! -d "${git_dir}" ]]; then
    log "No cloned repository Git metadata directory to remove: ${git_dir}"
    return
  fi
  log "Removing cloned repository Git metadata directory: ${git_dir}"
  rm -rf "${git_dir}"
}

fetch_libbpf() {
  local libbpf_dir="${FELIX_DIR}/bpf-gpl/libbpf"
  local libbpf_git_dir="${libbpf_dir}/.git"
  local libbpf_marker="${FELIX_DIR}/bpf-gpl/.libbpf-${LIBBPF_VERSION}"

  if [[ "${DOWNLOAD_BPF}" != "true" ]]; then
    log "Skipping libbpf fetch because BPF dependency download is disabled."
    return
  fi

  log "Fetching libbpf ${LIBBPF_VERSION} without make."
  if [[ -f "${libbpf_marker}" && -d "${libbpf_dir}/src" ]]; then
    log "libbpf dependency marker already exists: ${libbpf_marker}"
    return
  fi
  if [[ ! -e "${libbpf_dir}" ]]; then
    run git -C "${FELIX_DIR}/bpf-gpl" clone --depth 1 --single-branch https://github.com/libbpf/libbpf.git
  elif [[ ! -d "${libbpf_git_dir}" ]]; then
    log "Found existing libbpf source tree without nested Git metadata: ${libbpf_dir}"
    log "Treating existing libbpf sources as the downloaded dependency and recording ${LIBBPF_VERSION}."
    [[ -d "${libbpf_dir}/src" ]] || die "existing libbpf path is not a usable source tree: ${libbpf_dir}"
    rm -rf "${FELIX_DIR}/bpf-gpl"/.libbpf-*
    printf '%s\n' "${LIBBPF_VERSION}" > "${libbpf_marker}"
    return
  fi

  run env -u GIT_DIR -u GIT_WORK_TREE git --git-dir "${libbpf_git_dir}" --work-tree "${libbpf_dir}" fetch --tags
  run env -u GIT_DIR -u GIT_WORK_TREE git --git-dir "${libbpf_git_dir}" --work-tree "${libbpf_dir}" checkout "${LIBBPF_VERSION}"
  remove_cloned_repo_git_metadata "${libbpf_dir}"
  rm -rf "${FELIX_DIR}/bpf-gpl"/.libbpf-*
  printf '%s\n' "${LIBBPF_VERSION}" > "${libbpf_marker}"
}

prepare_libbpf_public_headers() {
  local libbpf_dir="${FELIX_DIR}/bpf-gpl/libbpf"
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

  if [[ "${DOWNLOAD_BPF}" != "true" ]]; then
    log "Skipping libbpf public header preparation because BPF dependency download is disabled."
    return
  fi

  log "Preparing libbpf public headers for offline BPF builds: ${include_root}"
  [[ -d "${source_dir}" ]] || die "libbpf source directory missing: ${source_dir}"
  rm -rf "${include_root}"
  mkdir -p "${bpf_include_dir}" "${iproute2_include_dir}"
  for header in "${headers[@]}"; do
    [[ -f "${source_dir}/${header}" ]] || die "required libbpf public header missing: ${source_dir}/${header}"
    run cp "${source_dir}/${header}" "${bpf_include_dir}/${header}"
  done
  log "Writing offline iproute2 bpf_elf.h compatibility header: ${iproute2_include_dir}/bpf_elf.h"
  cat > "${iproute2_include_dir}/bpf_elf.h" <<'HEADER'
#ifndef __CALI_OFFLINE_IPROUTE2_BPF_ELF_H__
#define __CALI_OFFLINE_IPROUTE2_BPF_ELF_H__

/* Compatibility header for offline Calico BPF builds. */

#endif /* __CALI_OFFLINE_IPROUTE2_BPF_ELF_H__ */
HEADER
}

main() {
  log "Starting Felix host dependency download."
  [[ -f "${METADATA_FILE}" ]] || die "metadata file not found: ${METADATA_FILE}"

  LIBBPF_VERSION=$(metadata_value LIBBPF_VERSION)
  [[ -n "${LIBBPF_VERSION}" ]] || die "LIBBPF_VERSION not found in ${METADATA_FILE}"
  export LIBBPF_VERSION

  if [[ -z "${ARCH}" ]]; then
    ARCH=$(canonical_arch "$(uname -m)")
  else
    ARCH=$(canonical_arch "${ARCH}")
  fi
  export ARCH

  log "Repository root: ${REPO_ROOT}"
  log "Felix directory: ${FELIX_DIR}"
  log "Target architecture: ${ARCH}"
  log "libbpf version: ${LIBBPF_VERSION}"
  log "Dependency options: bpf=${DOWNLOAD_BPF} check_only=${CHECK_ONLY}"

  check_requirements
  go_env_setup
  if [[ "${CHECK_ONLY}" == "true" ]]; then
    log "Check-only mode complete. No dependencies were downloaded."
    exit 0
  fi
  fetch_go_modules
  install_generated_code_tools
  generate_go_files
  fetch_libbpf
  prepare_libbpf_public_headers
  log "Felix host dependency download complete."
}

main "$@"
