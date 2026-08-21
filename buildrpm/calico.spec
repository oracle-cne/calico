
%global _buildhost build-ol%{?oraclelinux}-%{?_arch}.oracle.com
%{!?registry_url: %global registry_url container-registry.oracle.com/olcne}
%{!?gofips140: %global gofips140 inprocess}

%global debug_package %{nil}
%global git_short_ver $(git rev-parse --short HEAD)
%global build_dir src/github.com/projectcalico/calico

%global app_name calico
%global app_version 3.32.1
%global oracle_release_version 1

%ifarch %{arm} arm64 aarch64
%global arch arm64
%else
%global arch amd64
%endif

Name:           %{app_name}
Version:        %{app_version}
Release:        %{oracle_release_version}%{?dist}
Summary:        Calico network connectivity and security policy enforcement tool http://www.projectcalico.org
License:        Apache 2.0
Url:            https://github.com/projectcalico/calico
Source:         %{name}-%{version}.tar.bz2
Vendor:         Oracle America
BuildRequires:  git
BuildRequires:	make
BuildRequires:  libbpf-devel
BuildRequires:  libbpf
BuildRequires:  libbpf-static
BuildRequires:  libpcap-devel
BuildRequires:  libpcap
BuildRequires:  clang = 18.1.8
BuildRequires:  llvm = 18.1.8
BuildRequires:  gcc
BuildRequires:  kernel-headers
BuildRequires:  elfutils-libelf-devel
BuildRequires:  zlib-devel
BuildRequires:  file
%if %{?oraclelinux} == 8
BuildRequires:  gcc-toolset-11
%endif
Requires:       runit
Requires:       tini
Requires:       iptables
Requires:       ipset
Requires:       iputils
Requires:       iproute
Requires:       conntrack-tools
Requires:       file
Requires:       net-tools
Requires:       kmod

%description
Calico is an open source networking and network security solution for Kubernetes, virtual machines, and bare-metal workloads. Calico provides two major services for Cloud Native applications:

 - Network connectivity between workloads.
 - Network security policy enforcement between workloads.

%package -n apiserver
Summary: Project Calico API server for Kubernetes.

%description -n apiserver
Project Calico API server for Kubernetes.

%package -n app-policy
Summary: Application Layer Policy for Project Calico enforces network and application layer authorization policies using Istio.

%description -n app-policy
Application Layer Policy for Project Calico enforces network and application layer authorization policies using Istio.

%package -n calicoctl
Summary: Home of calicoctl.

%description -n calicoctl
Home of calicoctl.

%package -n cni-plugin
Summary: Project Calico network plugin for CNI.

%description -n cni-plugin
Project Calico network plugin for CNI.

%package -n felix
Summary: Felix is a Calico component that runs on every machine that provides endpoints.

%description -n felix
Felix is a Calico component that runs on every machine that provides endpoints.

%package -n kube-controllers
Summary: A collection of kubernetes controllers for Calico.

%description -n kube-controllers
A collection of kubernetes controllers for Calico.

%package -n node
Summary: Command line tool, node, makes it easy to manage Calico network and security policy, as well as other Calico configurations.

%description -n node
Command line tool, node, makes it easy to manage Calico network and security policy, as well as other Calico configurations.

%package -n pod2daemon
Summary: Part of pod2daemon, which enables secure communication between a Kubernetes pod and a daemon (e.g. created with a DaemonSet) running on the host.

%description -n pod2daemon
Part of pod2daemon, which enables secure communication between a Kubernetes pod and a daemon (e.g. created with a DaemonSet) running on the host.

%package -n typha
Summary: Typha sits between the datastore (such as the Kubernetes API server) and many instances of Felix.

%description -n typha
Typha sits between the datastore (such as the Kubernetes API server) and many instances of Felix.


%prep
%setup -n %{name}-%{version}

%build
GOPATH=$(pwd)
mkdir -p ${GOPATH}/bin
mkdir -p ${GOPATH}/pkg/mod
export GOTOOLCHAIN=local
export GOMODCACHE=${GOPATH}/pkg/mod

verify_static_go_fips_binary() {
  binary="$1"
  echo "+++ Verifying ${binary} is statically linked"
  file "${binary}"
  file "${binary}" | grep -q "statically linked"
  verify_go_fips_binary "${binary}"
}

verify_go_fips_binary() {
  binary="$1"
  echo "+++ Verifying ${binary} was built with native Go FIPS mode"
  go version -m "${binary}"
  go version -m "${binary}" | grep "GOFIPS140=" >/dev/null
  go version -m "${binary}" | grep "fips140=on" >/dev/null
}

build_container_go_binary() {
  binary="$1"
  shift
  echo "+++ Building ${binary} for container-image execution with GOFIPS140 disabled"
  GOEXPERIMENT= GOFIPS140= go build -trimpath=false -v \
           -o "${binary}" \
           "$@"
}

build_container_static_go_binary() {
  binary="$1"
  shift
  echo "+++ Building ${binary} for container-image execution with CGO_ENABLED=0 GOFIPS140 disabled"
  CGO_ENABLED=0 GOEXPERIMENT= GOFIPS140= go build -trimpath=false -v \
           -o "${binary}" \
           "$@"
}

build_static_go_fips_binary() {
  binary="$1"
  shift
  echo "+++ Building ${binary} with CGO_ENABLED=0 GOFIPS140=%{gofips140}"
  CGO_ENABLED=0 GOEXPERIMENT= GOFIPS140=%{gofips140} go build -trimpath=false -v \
           -o "${binary}" \
           "$@"
  verify_static_go_fips_binary "${binary}"
}

%if %{?oraclelinux} == 8
echo "+++ Enabling gcc-toolset-11 compiler environment"
source /opt/rh/gcc-toolset-11/enable
gcc --version
%endif

# Binaries to build: apiserver dikastes healthz calicoctl install cni-plugin-install calico calico-felix kube-controllers check-status calico-node mountns node-driver-registrar flexvol csidriver calico-typha
%define rpm_name apiserver
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/%{rpm_name} \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/%{rpm_name}/%{rpm_name}.go

popd

%define rpm_name app-policy
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/dikastes \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/dikastes/dikastes.go

build_container_go_binary ${GOPATH}/bin/healthz \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/healthz/healthz.go
popd

%define rpm_name calicoctl
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/%{rpm_name} \
         -ldflags "-X main.VERSION=v%{version}" \
         -ldflags "-X %{rpm_name}/calicoctl/commands.VERSION=v%{version} \
                   -X %{rpm_name}/commands.GIT_REVISION=%{git_short_ver} \
                   -X %{rpm_name}/commands/common.VERSION=v%{version}" \
         %{rpm_name}/%{rpm_name}.go
popd

%define rpm_name cni-plugin
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/install \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/install/install.go

build_static_go_fips_binary ${GOPATH}/bin/calico \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/calico/calico.go

build_static_go_fips_binary ${GOPATH}/bin/cni-plugin-install \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/install/install.go

popd

%define rpm_name felix
felix/hack/build-felix-host.sh --arch %{arch}

%define rpm_name kube-controllers
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/%{rpm_name} \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/%{rpm_name}/main.go

build_container_go_binary ${GOPATH}/bin/check-status \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/check-status/main.go
popd


%define rpm_name node
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/calico-node \
         -ldflags "-X pkg/lifecycle/startup.VERSION=v%{version}" \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/calico-node/main.go

build_container_go_binary ${GOPATH}/bin/mountns \
         -ldflags "-X pkg/lifecycle/startup.VERSION=v%{version}" \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/mountns/main.go
#make GIT_VERSION=v%{version} build
popd

%define rpm_name pod2daemon
pushd %{rpm_name}
# node-driver-registrar is built from the staged upstream kubernetes-csi source.
pushd node-driver-registrar
build_container_static_go_binary ${GOPATH}/bin/node-driver-registrar \
         -buildvcs=false \
         cmd/csi-node-driver-registrar/*.go
popd

build_static_go_fips_binary ${GOPATH}/bin/flexvol \
         -ldflags "-X main.VERSION=v%{version}" \
         flexvol/flexvoldriver.go

build_container_go_binary ${GOPATH}/bin/csidriver \
         -ldflags "-X main.VERSION=v%{version}" \
         csidriver/main.go
popd


%define rpm_name typha
pushd %{rpm_name}
build_container_go_binary ${GOPATH}/bin/calico-typha \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/calico-typha/typha.go
popd


%install
# apiserver
install -D -m 755 bin/apiserver %{buildroot}%{_bindir}/apiserver

# app-policy
install -D -m 755 bin/dikastes %{buildroot}%{_bindir}/dikastes
install -D -m 755 bin/healthz %{buildroot}%{_bindir}/healthz

# calicoctl
install -D -m 755 bin/calicoctl %{buildroot}%{_bindir}/calicoctl

# cni-plugin
install -m 755 -d %{buildroot}/opt/cni/bin
install -D -m 755 bin/install %{buildroot}/opt/cni/bin/install
install -D -m 755 bin/cni-plugin-install %{buildroot}/opt/cni/bin/cni-plugin-install
install -D -m 755 bin/calico %{buildroot}/opt/cni/bin/calico
cp -a %{buildroot}/opt/cni/bin/calico %{buildroot}/opt/cni/bin/calico-ipam
echo "+++ Verifying Calico CNI plugin and IPAM binaries are identical"
if ! cmp -s %{buildroot}/opt/cni/bin/calico %{buildroot}/opt/cni/bin/calico-ipam; then
  echo "+++ ERROR: %{buildroot}/opt/cni/bin/calico and %{buildroot}/opt/cni/bin/calico-ipam differ"
  exit 1
fi
echo "+++ Verifying Calico CNI plugin and installer binaries are different"
if cmp -s %{buildroot}/opt/cni/bin/calico %{buildroot}/opt/cni/bin/cni-plugin-install; then
  echo "+++ ERROR: %{buildroot}/opt/cni/bin/calico and %{buildroot}/opt/cni/bin/cni-plugin-install are identical"
  exit 1
fi

# felix
install -d -m 755 %{buildroot}/usr/lib/calico/bpf
install -D -m 755 felix/bin/bpf/* %{buildroot}/usr/lib/calico/bpf/
install -d -m 755 %{buildroot}/etc/calico
install -p felix/docker-image/felix.cfg %{buildroot}/etc/calico/felix.cfg
install -p felix/docker-image/calico-felix-wrapper %{buildroot}%{_bindir}/
install -D -m 755 felix/bin/calico-felix-%{arch} %{buildroot}%{_bindir}/calico-felix

# kube-controllers
install -D -m 755 bin/kube-controllers %{buildroot}%{_bindir}/kube-controllers
install -D -m 755 bin/check-status %{buildroot}%{_bindir}/check-status

# node
directories=(bird bird6 confd felix node-services)
for directory in "${directories[@]}"; do
  install -d -m 755 %{buildroot}/etc/service/available/${directory}/log
  install -p node/filesystem/etc/service/available/${directory}/run %{buildroot}/etc/service/available/${directory}
  install -p node/filesystem/etc/service/available/${directory}/log/run %{buildroot}/etc/service/available/${directory}/log
done
install -d -m 755 %{buildroot}/etc/calico/confd/config
install -d -m 755 %{buildroot}/etc/calico/confd/templates
install -d -m 755 %{buildroot}/etc/calico/confd/conf.d
install -p confd/etc/calico/confd/templates/*  %{buildroot}/etc/calico/confd/templates/
install -p confd/etc/calico/confd/conf.d/* %{buildroot}/etc/calico/confd/conf.d/
install -p node/filesystem/etc/calico/felix.cfg %{buildroot}/etc/calico/felix.cfg
install -p node/filesystem/etc/rc.local %{buildroot}/etc/rc.local.node
install -d -m 755 %{buildroot}/usr/sbin/
binary=(restart-calico-confd start_runit versions)
for bin in "${binary[@]}"; do
install -p node/filesystem/sbin/${bin} %{buildroot}/usr/sbin/
done
install -D -m 755 bin/calico-node %{buildroot}%{_bindir}/calico-node
install -D -m 755 bin/mountns %{buildroot}%{_bindir}/mountns

# pod2daemon
install -D -m 755 bin/node-driver-registrar %{buildroot}%{_bindir}/node-driver-registrar
install -D -m 755 bin/flexvol %{buildroot}%{_bindir}/flexvol
install -D -m 755 bin/csidriver %{buildroot}%{_bindir}/csidriver

# typha
install -D -m 755 bin/calico-typha %{buildroot}%{_bindir}/calico-typha

%check
verify_go_fips_rpm_binary() {
  binary="$1"
  echo "+++ Verifying installed RPM binary ${binary} was built with native Go FIPS mode"
  go version -m "${binary}"
  go version -m "${binary}" | grep "GOFIPS140=" >/dev/null
  go version -m "${binary}" | grep "fips140=on" >/dev/null
}

verify_static_go_fips_rpm_binary() {
  binary="$1"
  echo "+++ Verifying installed RPM binary ${binary} is statically linked"
  file "${binary}"
  file "${binary}" | grep -q "statically linked"
  verify_go_fips_rpm_binary "${binary}"
}

verify_non_fips_rpm_binary() {
  binary="$1"
  echo "+++ Verifying installed RPM binary ${binary} was built without native Go FIPS mode"
  go version -m "${binary}"
  if go version -m "${binary}" | grep "fips140=on" >/dev/null; then
    echo "+++ ERROR: ${binary} was unexpectedly built with native Go FIPS mode"
    exit 1
  fi
}

for binary in \
  %{buildroot}/opt/cni/bin/cni-plugin-install \
  %{buildroot}/opt/cni/bin/calico \
  %{buildroot}/opt/cni/bin/calico-ipam \
  %{buildroot}%{_bindir}/flexvol; do
  verify_static_go_fips_rpm_binary "${binary}"
done

for binary in \
  %{buildroot}%{_bindir}/apiserver \
  %{buildroot}%{_bindir}/dikastes \
  %{buildroot}%{_bindir}/healthz \
  %{buildroot}%{_bindir}/calicoctl \
  %{buildroot}/opt/cni/bin/install \
  %{buildroot}%{_bindir}/kube-controllers \
  %{buildroot}%{_bindir}/check-status \
  %{buildroot}%{_bindir}/calico-node \
  %{buildroot}%{_bindir}/node-driver-registrar \
  %{buildroot}%{_bindir}/csidriver \
  %{buildroot}%{_bindir}/calico-typha; do
  verify_non_fips_rpm_binary "${binary}"
done

verify_non_fips_rpm_binary %{buildroot}%{_bindir}/mountns

%files -n apiserver
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/apiserver

%files -n app-policy
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/dikastes
%attr(755,root,root) %{_bindir}/healthz

%files -n calicoctl
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/calicoctl

%files -n cni-plugin
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) /opt/cni/bin/install
%attr(755,root,root) /opt/cni/bin/cni-plugin-install
%attr(755,root,root) /opt/cni/bin/calico
%attr(755,root,root) /opt/cni/bin/calico-ipam

%files -n felix
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/calico-felix
%attr(755,root,root) %{_bindir}/calico-felix-wrapper
/usr/lib/calico/bpf/*
/etc/calico/felix.cfg

%files -n kube-controllers
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/kube-controllers
%attr(755,root,root) %{_bindir}/check-status

%files -n node
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
/etc/calico/*
/etc/service/*
%attr(755,root,root) /etc/rc.local.node
%attr(755,root,root) /usr/sbin/*
%attr(755,root,root) %{_bindir}/calico-node
%attr(755,root,root) %{_bindir}/mountns

%files -n pod2daemon
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/node-driver-registrar
%attr(755,root,root) %{_bindir}/flexvol
%attr(755,root,root) %{_bindir}/csidriver

%files -n typha
%license LICENSE.md THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/calico-typha


%post -n node
# Cannot install rc.local if already exists.
# Error: Transaction test error:
#  file /etc/rc.local from install of node-3.25.0-1.el8.x86_64 conflicts with file from package systemd-239-68.0.1.el8.x86_64
# Workaround as follows.
mv /etc/rc.local /etc/rc.local.bak
cp /etc/rc.local.node /etc/rc.local


%post -n cni-plugin
ln -s /opt/cni/bin/calico /bin/calico
ln -s /opt/cni/bin/calico-ipam /bin/calico-ipam


%postun -n node
# Restore rc.local backup
rm -f /etc/rc.local
mv /etc/rc.local.bak /etc/rc.local


%postun -n cni-plugin
rm -f /bin/calico
rm -f /bin/calico-ipam


%changelog
* Thu Jun 25 2026 Oracle Cloud Native Environment Authors <noreply@oracle.com> - %{version}-%{oracle_release_version}
- Add Oracle specific files for calico
