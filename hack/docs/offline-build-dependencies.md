# Offline RPM build dependency download

`hack/download-build-deps.sh` downloads only the network-backed inputs needed by `buildrpm/calico.spec` so the RPM build can run in an environment that cannot access external servers.

## What the RPM spec builds

`buildrpm/calico.spec` uses host `go build` commands for these components:

- `apiserver`
- `app-policy`
- `calicoctl`
- `cni-plugin`
- `kube-controllers`
- `node`
- `pod2daemon`
- `typha`

The spec also runs `felix/hack/build-felix-host.sh --arch %{arch}`, which builds Felix and BPF outputs from host tools.

## What the downloader fetches

The downloader fetches only inputs required by those RPM build paths:

- Go modules from the root `go.mod`, used by the host `go build` commands in `buildrpm/calico.spec`.
- `libbpf` at `LIBBPF_VERSION` from `metadata.mk`, used by `felix/hack/build-felix-host.sh`.
- The staged `felix/bpf-gpl/libbpf/offline-include` headers required by the Felix BPF build.
- `kubernetes-csi/node-driver-registrar` at `UPSTREAM_REGISTRAR_TAG` from `pod2daemon/Makefile`, staged into `pod2daemon/node-driver-registrar` for the RPM spec to build.

It does not download Docker images, Yarn packages, Python wheels, Helm, kubectl, test dependencies, release tools, or third-party source trees that are not referenced by the RPM spec build section.

## Connected environment

Run the downloader from the repository root:

```bash
hack/download-build-deps.sh --arch amd64
```

Useful variants:

```bash
hack/download-build-deps.sh --arch arm64
hack/download-build-deps.sh --dest /tmp/calico-rpm-deps --arch amd64
hack/download-build-deps.sh --check-only
```

## Offline environment

Copy `.offline-rpm-build-deps` and the prepared repository tree to the RPM build environment, then source the generated environment file before running `rpmbuild`:

```bash
source .offline-rpm-build-deps/offline-rpm-build-env.sh
rpmbuild -ba buildrpm/calico.spec
```

The environment file sets `GOMODCACHE`, `GOCACHE`, `GOPROXY=off`, and `GOSUMDB=off` so `go build` uses the local module cache instead of contacting module servers.

## Host packages still required

The script does not download RPM `BuildRequires` or runtime `Requires`. Those must be available from the offline RPM build environment or a local package repository, including `golang`, `libbpf-devel`, `libpcap-devel`, `clang`, `llvm`, `kernel-headers`, `podman`, `podman-docker`, `runit`, `tini`, `iptables`, `ipset`, `iproute`, and related packages listed in `buildrpm/calico.spec`.
