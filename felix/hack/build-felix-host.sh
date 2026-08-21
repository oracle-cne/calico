#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FELIX_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd "${FELIX_DIR}/.." && pwd)
METADATA_FILE="${REPO_ROOT}/metadata.mk"

BUILD_BPF=true
SKIP_REQUIREMENTS=false
CHECK_ONLY=false
FIPS=${FIPS:-false}
JOBS=${JOBS:-16}
ARCH=${ARCH:-}
GOFLAGS=${GOFLAGS:-}
GOAMD64=${GOAMD64:-v2}

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
  cat <<'EOF'
Build Felix on the host without Docker, dependency downloads, or invoking make.

Run felix/hack/download-felix-host-deps.sh first to download dependencies and
generate source artifacts.

Usage:
  felix/hack/build-felix-host.sh [options]

Options:
  --arch ARCH              Target architecture: amd64, arm64, ppc64le, or s390x.
  --no-bpf                 Do not build libbpf or BPF object files.
  --skip-requirements      Skip host tool availability checks.
  --check-only             Validate settings and host tools, then exit.
  -h, --help               Show this help.

Environment:
  ARCH, FIPS, GOFLAGS, GOAMD64, JOBS, CC, AR, CLANG, LLC, PKG_CONFIG,
  GOPATH.

Outputs:
  felix/bin/calico-felix-<arch>
  felix/bin/calico-felix
  felix/bin/bpf/*.o                      unless --no-bpf
  felix/bpf-gpl/libbpf/src/<arch>/libbpf.a unless --no-bpf
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires an argument"
      ARCH=$2
      shift 2
      ;;
    --no-bpf)
      BUILD_BPF=false
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

host_os() {
  uname -s | tr '[:upper:]' '[:lower:]'
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  command_exists "$1" || die "required command not found: $1"
}

git_description() {
  git -C "${REPO_ROOT}" describe --tags --dirty --always --abbrev=12 2>/dev/null || printf '<unknown>'
}

git_commit() {
  git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || printf '<unknown>'
}

build_id() {
  git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || uuidgen | sed 's/-//g'
}

go_env_setup() {
  export GOCACHE="${REPO_ROOT}/.go-pkg-cache"
  export GOPATH=${GOPATH:-"$(go env GOPATH)"}
  export PATH="$(go env GOPATH)/bin:${PATH}"
  export GOOS="$(host_os)"
  export GOARCH="${ARCH}"
  export GOFLAGS
  if [[ "${ARCH}" == "amd64" ]]; then
    export GOAMD64
  fi
  mkdir -p "${GOCACHE}" "${FELIX_DIR}/bin"
  log "Go environment: GOOS=${GOOS} GOARCH=${GOARCH} GOAMD64=${GOAMD64:-unset} GOCACHE=${GOCACHE} GOFLAGS=${GOFLAGS:-unset}"
}

check_requirements() {
  if [[ "${SKIP_REQUIREMENTS}" == "true" ]]; then
    log "Skipping host requirement checks."
    return
  fi

  log "Checking host requirements."
  require_cmd git
  require_cmd go
  require_cmd gcc
  require_cmd ar

  if [[ "${BUILD_BPF}" == "true" ]]; then
    require_cmd "${CLANG:-clang}"
    require_cmd "${LLC:-llc}"
    require_cmd "${PKG_CONFIG:-pkg-config}"
  fi
}

build_libbpf_static() {
  [[ "${BUILD_BPF}" == "true" ]] || return

  local src_dir="${FELIX_DIR}/bpf-gpl/libbpf/src"
  local obj_dir="${src_dir}/${ARCH}"
  local static_obj_dir="${obj_dir}/staticobjs"
  local cc=${CC:-cc}
  local ar=${AR:-ar}
  local pkg_config=${PKG_CONFIG:-pkg-config}
  local cflags
  local obj
  local source
  local objects=(
    bpf.o btf.o libbpf.o libbpf_errno.o netlink.o
    nlattr.o str_error.o libbpf_probes.o bpf_prog_linfo.o
    btf_dump.o hashmap.o ringbuf.o strset.o linker.o gen_loader.o
    relo_core.o usdt.o zip.o elf.o features.o btf_iter.o btf_relocate.o
  )

  log "Building static libbpf without make: ${obj_dir}/libbpf.a"
  [[ -d "${src_dir}" ]] || die "libbpf source directory missing: ${src_dir}"
  mkdir -p "${static_obj_dir}"

  cflags="-I. -I.. -I../include -I../include/uapi -g -O2 -Werror -Wall -std=gnu89 -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -Wno-unknown-warning-option -Wno-format-overflow"
  cflags+=" $(${pkg_config} --cflags libelf zlib)"

  for obj in "${objects[@]}"; do
    source=${obj%.o}.c
    run env -C "${src_dir}" "${cc}" ${cflags} -c "${source}" -o "${static_obj_dir}/${obj}"
  done
  run "${ar}" rcs "${obj_dir}/libbpf.a" "${static_obj_dir}"/*.o
  sed -e 's|@PREFIX@|/usr|' \
      -e 's|@LIBDIR@|${prefix}/lib64|' \
      -e "s|@VERSION@|${LIBBPF_VERSION#v}|" \
      < "${src_dir}/libbpf.pc.template" > "${obj_dir}/libbpf.pc"
}

common_bpf_cflags() {
  local triplet
  triplet=$(gcc -dumpmachine)
  printf '%s' "-Wall -Werror -fno-stack-protector -Wno-address-of-packed-member -O2 -target bpf -emit-llvm -g -I ./libbpf/offline-include -I ./libbpf/src/ -I ./libbpf/include/uapi -I/usr/include/${triplet}"
  case "${triplet}" in
    *x86_64*) printf ' -D__TARGET_ARCH_x86 -D__x86_64__' ;;
    *aarch64*) printf ' -D__TARGET_ARCH_arm64' ;;
  esac
}

generate_gpl_map_stub() {
  local output=$1
  shift
  {
    printf '#include "bpf.h"\n'
    local header
    for header in "$@"; do
      printf '#include "%s"\n' "${header}"
    done
    printf '\nSEC("xdp")\n'
    printf 'int xdp_prog(struct xdp_md *ctx) { return XDP_PASS; }\n'
  } > "${output}"
}

gpl_source_for_object() {
  local base=$1
  case "${base}" in
    tc_preamble_ingress|tc_preamble_egress) printf 'tc_preamble.c' ;;
    tcx_test) printf 'tcx_test.c' ;;
    xdp_preamble) printf 'xdp_preamble.c' ;;
    policy_default_ingress|policy_default_egress) printf 'policy_default.c' ;;
    connect_balancer*)
      if [[ "${base}" == *_v46 || "${base}" == *_v46_* ]]; then
        printf 'connect_balancer_v46.c'
      elif [[ "${base}" == *_v6 || "${base}" == *_v6_* ]]; then
        printf 'connect_balancer_v6.c'
      else
        printf 'connect_balancer.c'
      fi
      ;;
    conntrack_cleanup*) printf 'conntrack_cleanup.c' ;;
    xdp*|test_xdp*) printf 'xdp.c' ;;
    from*|to*|test_from*|test_to*) printf 'tc.c' ;;
    *) die "unable to map BPF object '${base}.o' to a source file" ;;
  esac
}

compile_gpl_object() {
  local object=$1
  local clang=${CLANG:-clang}
  local llc=${LLC:-llc}
  local cflags=$2
  local object_path="${FELIX_DIR}/bpf-gpl/${object}"
  local base
  local ll_file
  local source
  local extra_flags=()

  base=$(basename "${object}" .o)
  ll_file="${FELIX_DIR}/bpf-gpl/${base}.ll"
  source=$(gpl_source_for_object "${base}")

  if [[ "${base}" == "tcx_test" ]]; then
    extra_flags=()
  elif [[ "${base}" == "xdp_preamble" ]]; then
    extra_flags=(-DCALI_COMPILE_FLAGS=64)
  else
    read -r -a extra_flags <<<"$(cd "${FELIX_DIR}/bpf-gpl" && ./calculate-flags "${base}.ll")"
  fi

  mkdir -p "$(dirname "${object_path}")"
  run env -C "${FELIX_DIR}/bpf-gpl" "${clang}" ${cflags} "${extra_flags[@]}" -c "${source}" -o "${ll_file}"
  run "${llc}" -march=bpf -filetype=obj -o "${object_path}" "${ll_file}"
}

build_bpf_apache() {
  [[ "${BUILD_BPF}" == "true" ]] || return

  local clang=${CLANG:-clang}
  local llc=${LLC:-llc}
  local libbpf_include_dir="${FELIX_DIR}/bpf-gpl/libbpf/offline-include"
  local triplet
  local cflags
  local source
  local base

  log "Building Apache-licensed BPF objects without make."
  [[ -f "${libbpf_include_dir}/bpf/bpf_helpers.h" ]] || die "libbpf public headers missing: run felix/hack/download-felix-host-deps.sh first"
  triplet=$(gcc -dumpmachine)
  cflags="-x c -D__KERNEL__ -D__ASM_SYSREG_H -Wunused -Wall -Werror -fno-stack-protector -O2 -target bpf -emit-llvm -g -I${libbpf_include_dir} -I/usr/include/${triplet}"
  mkdir -p "${FELIX_DIR}/bpf-apache/bin"

  for source in filter.c redir.c sockops.c; do
    base=${source%.c}
    run env -C "${FELIX_DIR}/bpf-apache" "${clang}" ${cflags} -c "${source}" -o "${base}.ll"
    run "${llc}" -march=bpf -filetype=obj -o "${FELIX_DIR}/bpf-apache/bin/${base}.o" "${FELIX_DIR}/bpf-apache/${base}.ll"
  done
}

build_bpf_gpl() {
  [[ "${BUILD_BPF}" == "true" ]] || return

  local clang=${CLANG:-clang}
  local cflags
  local map_cflags
  local production_objects=()
  local unit_objects=()
  local fixed_objects=(
    bin/tc_preamble_ingress.o
    bin/tc_preamble_egress.o
    bin/xdp_preamble.o
    bin/policy_default_ingress.o
    bin/policy_default_egress.o
    bin/tcx_test.o
  )
  local map_objects=(
    bin/common_map_stub.o
    bin/ipv4_map_stub.o
    bin/ipv6_map_stub.o
    bin/xdp_map_stub.o
    bin/common_map_stub_ing.o
  )
  local object

  log "Building GPL-licensed BPF objects without make."
  cflags=$(common_bpf_cflags)
  map_cflags=${cflags//-emit-llvm/}

  mkdir -p "${FELIX_DIR}/bpf-gpl/bin"
  (
    cd "${FELIX_DIR}/bpf-gpl"
    generate_gpl_map_stub common_map_stub.c counters.h ifstate.h perf_types.h profiling.h rule_counters.h qos.h ctlb_map.h jump.h
    generate_gpl_map_stub ipv4_map_stub.c arp.h conntrack_cleanup.h conntrack_types.h failsafe.h nat_types.h policy.h routes.h sendrecv.h ip_v4_fragment.h
    generate_gpl_map_stub ipv6_map_stub.c arp.h conntrack_cleanup.h conntrack_types.h failsafe.h nat_types.h policy.h routes.h sendrecv.h
    generate_gpl_map_stub xdp_map_stub.c jump.h
  )

  run env -C "${FELIX_DIR}/bpf-gpl" "${clang}" ${map_cflags} -c common_map_stub.c -o bin/common_map_stub.o
  run env -C "${FELIX_DIR}/bpf-gpl" "${clang}" ${map_cflags} -DCALI_COMPILE_FLAGS=2 -c common_map_stub.c -o bin/common_map_stub_ing.o
  run env -C "${FELIX_DIR}/bpf-gpl" "${clang}" ${map_cflags} -c ipv4_map_stub.c -o bin/ipv4_map_stub.o
  run env -C "${FELIX_DIR}/bpf-gpl" "${clang}" ${map_cflags} -DIPVER6 -c ipv6_map_stub.c -o bin/ipv6_map_stub.o
  run env -C "${FELIX_DIR}/bpf-gpl" "${clang}" ${map_cflags} -DCALI_COMPILE_FLAGS=64 -c xdp_map_stub.c -o bin/xdp_map_stub.o

  mapfile -t production_objects < <(cd "${FELIX_DIR}/bpf-gpl" && ./list-objs)
  mapfile -t unit_objects < <(cd "${FELIX_DIR}/bpf-gpl" && ./list-ut-objs)

  for object in "${production_objects[@]}" "${unit_objects[@]}" "${fixed_objects[@]}"; do
    case " ${map_objects[*]} " in
      *" ${object} "*) continue ;;
    esac
    compile_gpl_object "${object}" "${cflags}"
  done
}

copy_bpf_outputs() {
  [[ "${BUILD_BPF}" == "true" ]] || return

  local production_objects=()
  local object

  log "Copying BPF production objects into felix/bin/bpf."
  rm -rf "${FELIX_DIR}/bin/bpf"
  mkdir -p "${FELIX_DIR}/bin/bpf"
  mapfile -t production_objects < <(cd "${FELIX_DIR}/bpf-gpl" && ./list-objs)
  production_objects+=(
    bin/tc_preamble_ingress.o
    bin/tc_preamble_egress.o
    bin/xdp_preamble.o
    bin/policy_default_ingress.o
    bin/policy_default_egress.o
    bin/tcx_test.o
    bin/common_map_stub.o
    bin/ipv4_map_stub.o
    bin/ipv6_map_stub.o
    bin/xdp_map_stub.o
    bin/common_map_stub_ing.o
  )
  for object in "${production_objects[@]}"; do
    run cp "${FELIX_DIR}/bpf-gpl/${object}" "${FELIX_DIR}/bin/bpf/"
  done
  for object in "${FELIX_DIR}/bpf-apache/bin"/*.o; do
    run cp "${object}" "${FELIX_DIR}/bin/bpf/"
  done
}

build_felix_binary() {
  local output="${FELIX_DIR}/bin/calico-felix-${ARCH}"
  local package="github.com/projectcalico/calico/felix/cmd/calico-felix"
  local ldflags
  local cgo_enabled=0
  local tags=()

  log "Building Felix binary for ${ARCH} without make or Docker."
  ldflags="-X github.com/projectcalico/calico/pkg/buildinfo.Version=$(git_description)"
  ldflags+=" -X github.com/projectcalico/calico/pkg/buildinfo.BuildDate=$(date -u +'%FT%T%z')"
  ldflags+=" -X github.com/projectcalico/calico/pkg/buildinfo.GitRevision=$(git_commit)"
  if [[ "$(host_os)" != "darwin" ]]; then
    ldflags+=" -B 0x$(build_id)"
  fi

  if [[ "${BUILD_BPF}" == "true" && ( "${ARCH}" == "amd64" || "${ARCH}" == "arm64" ) ]]; then
    cgo_enabled=1
    export CGO_CFLAGS="-I${FELIX_DIR}/bpf-gpl/libbpf/src -I${FELIX_DIR}/bpf-gpl"
    export CGO_LDFLAGS="-L${FELIX_DIR}/bpf-gpl/libbpf/src/${ARCH} -lbpf -lelf -lz"
  fi

  if [[ "${FIPS}" == "true" ]]; then
    [[ "${ARCH}" == "amd64" ]] || die "FIPS build is only supported for amd64"
    cgo_enabled=1
    export GOEXPERIMENT=boringcrypto
    tags=(-tags fipsstrict)
  fi

  run env CGO_ENABLED="${cgo_enabled}" go -C "${FELIX_DIR}" build -o "${output}" -v -buildvcs=false -ldflags "${ldflags}" "${tags[@]}" "${package}"

  if [[ "${FIPS}" == "true" ]]; then
    log "Checking Felix binary for BoringCrypto symbols."
    go tool nm "${output}" | grep '_Cfunc__goboringcrypto_' >/dev/null || die "FIPS build did not contain boringcrypto symbols"
  fi

  run ln -f "${output}" "${FELIX_DIR}/bin/calico-felix"
}

main() {
  log "Starting host Felix build."
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
  log "Build options: bpf=${BUILD_BPF} fips=${FIPS} jobs=${JOBS} check_only=${CHECK_ONLY}"

  check_requirements
  go_env_setup
  if [[ "${CHECK_ONLY}" == "true" ]]; then
    log "Check-only mode complete. No build actions were run."
    exit 0
  fi
  build_libbpf_static
  build_bpf_apache
  build_bpf_gpl
  copy_bpf_outputs
  build_felix_binary
  log "Host Felix build complete."
}

main "$@"
