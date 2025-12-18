
%global _buildhost build-ol%{?oraclelinux}-%{?_arch}.oracle.com
%{!?registry_url: %global registry_url container-registry.oracle.com/olcne}

%global debug_package %{nil}
%global git_short_ver $(git rev-parse --short HEAD)
%global build_dir src/github.com/projectcalico/calico

%global app_name calico
%global app_version 3.31.1
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
BuildRequires:  podman
BuildRequires:  podman-docker
BuildRequires:	make
BuildRequires:  golang >= 1.20.12
BuildRequires:  libbpf-devel
BuildRequires:  libbpf
BuildRequires:  clang
BuildRequires:  kernel-headers
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
Patch0:         metadata.mk.patch

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
%patch0

%build
GOPATH=$(pwd)
mkdir -p ${GOPATH}/bin

%if %{?oraclelinux} == 8
# setup gcc toolset 11
dnf install gcc-toolset-11
echo "source /opt/rh/gcc-toolset-11/enable" >> ~/.bashrc
source ~/.bashrc
%endif

# Binaries to build: apiserver filecheck dikastes healthz calicoctl cni-plugin-install calico-felix kube-controllers check-status calico-node mountns node-driver-registrar flexvol csidriver calico-typha
%define rpm_name apiserver
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/%{rpm_name} \
	 -ldflags "-X main.VERSION=v%{version}" \
         cmd/%{rpm_name}/%{rpm_name}.go

popd

%define rpm_name app-policy
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/dikastes \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/dikastes/dikastes.go

go build -trimpath=false -v \
         -o ${GOPATH}/bin/healthz \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/healthz/healthz.go
popd

%define rpm_name calicoctl
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/%{rpm_name} \
         -ldflags "-X main.VERSION=v%{version}" \
         -ldflags "-X %{rpm_name}/calicoctl/commands.VERSION=v%{version} \
                   -X %{rpm_name}/commands.GIT_REVISION=%{git_short_ver} \
                   -X %{rpm_name}/commands/common.VERSION=v%{version}" \
         %{rpm_name}/%{rpm_name}.go
popd

%define rpm_name cni-plugin
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/calico \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/calico/calico.go

go build -trimpath=false -v \
         -o ${GOPATH}/bin/cni-plugin-install \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/install/install.go

popd

%define rpm_name felix
podman pull %{registry_url}/go-build:v1.24.2
podman tag %{registry_url}/go-build:v1.24.2 %{registry_url}/go-build:v1.24.2-%{arch}
export GO_BUILD_IMAGE=%{registry_url}/go-build
export GO_BUILD_VER=v1.24.2
pushd %{rpm_name}
make build
popd

%define rpm_name kube-controllers
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/%{rpm_name} \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/%{rpm_name}/main.go

go build -trimpath=false -v \
         -o ${GOPATH}/bin/check-status \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/check-status/main.go
popd


%define rpm_name node
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/calico-node \
         -ldflags "-X pkg/lifecycle/startup.VERSION=v%{version}" \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/calico-node/main.go

go build -trimpath=false -v \
         -o ${GOPATH}/bin/mountns \
         -ldflags "-X pkg/lifecycle/startup.VERSION=v%{version}" \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/mountns/main.go
#make GIT_VERSION=v%{version} build
popd

%define rpm_name pod2daemon
pushd %{rpm_name}
# node-driver-registrar is built from upstream kubernetes-csi project so need to git clone.
go build -trimpath=false -v \
         -o ${GOPATH}/bin/flexvol \
         -ldflags "-X main.VERSION=v%{version}" \
         flexvol/flexvoldriver.go

go build -trimpath=false -v \
         -o ${GOPATH}/bin/csidriver \
         -ldflags "-X main.VERSION=v%{version}" \
         csidriver/main.go
popd


%define rpm_name typha
pushd %{rpm_name}
go build -trimpath=false -v \
         -o ${GOPATH}/bin/calico-typha \
         -ldflags "-X main.VERSION=v%{version}" \
         cmd/calico-typha/typha.go
popd


%install
# apiserver
install -D -m 755 bin/apiserver %{buildroot}%{_bindir}/apiserver
install -D -m 755 bin/filecheck %{buildroot}%{_bindir}/filecheck

# app-policy
install -D -m 755 bin/dikastes %{buildroot}%{_bindir}/dikastes
install -D -m 755 bin/healthz %{buildroot}%{_bindir}/healthz

# calicoctl
install -D -m 755 bin/calicoctl %{buildroot}%{_bindir}/calicoctl

# cni-plugin
install -m 755 -d %{buildroot}/opt/cni/bin
install -D -m 755 bin/cni-plugin-install %{buildroot}/opt/cni/bin/install
install -D -m 755 bin/calico %{buildroot}/opt/cni/bin/calico
install -D -m 755 bin/calico %{buildroot}/opt/cni/bin/calico-ipam

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
directories=(allocate-tunnel-addrs bird bird6 calico-bgp-daemon cni confd felix monitor-addresses node-status-reporter)
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
install -D -m 755 node/dist/bin/calico-node-%{arch} %{buildroot}%{_bindir}/calico-node
install -D -m 755 node/dist/bin/mountns-%{arch} %{buildroot}%{_bindir}/mountns

# pod2daemon
install -D -m 755 bin/node-driver-registrar %{buildroot}%{_bindir}/node-driver-registrar
install -D -m 755 bin/flexvol %{buildroot}%{_bindir}/flexvol
install -D -m 755 bin/csidriver %{buildroot}%{_bindir}/csidriver

# typha
install -D -m 755 bin/calico-typha %{buildroot}%{_bindir}/calico-typha

%files -n apiserver
%license apiserver/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/apiserver
%attr(755,root,root) %{_bindir}/filecheck

%files -n app-policy
%license app-policy/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/dikastes
%attr(755,root,root) %{_bindir}/healthz

%files -n calicoctl
%license calicoctl/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/calicoctl

%files -n cni-plugin
%license cni-plugin/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/cni-plugin-install

%files -n felix
%license felix/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/calico-felix
%attr(755,root,root) %{_bindir}/calico-felix-wrapper
/usr/lib/calico/bpf/*
/etc/calico/felix.cfg

%files -n kube-controllers
%license kube-controllers/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/kube-controllers
%attr(755,root,root) %{_bindir}/check-status

%files -n node
%license node/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
/etc/calico/*
/etc/service/*
%attr(755,root,root) /etc/rc.local.node
%attr(755,root,root) /usr/sbin/*
%attr(755,root,root) %{_bindir}/calico-node
%attr(755,root,root) %{_bindir}/mountns

%files -n pod2daemon
%license pod2daemon/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/node-driver-registrar
%attr(755,root,root) %{_bindir}/flexvol
%attr(755,root,root) %{_bindir}/csidriver

%files -n typha
%license typha/LICENSE THIRD_PARTY_LICENSES.txt SECURITY.md
%attr(755,root,root) %{_bindir}/calico-typha


%post -n node
# Cannot install rc.local if already exists.
# Error: Transaction test error:
#  file /etc/rc.local from install of node-3.25.0-1.el8.x86_64 conflicts with file from package systemd-239-68.0.1.el8.x86_64
# Workaround as follows.
mv /etc/rc.local /etc/rc.local.bak
cp /etc/rc.local.node /etc/rc.local


%post -n cni-plugin
ln -s /bin/cni-plugin-install /bin/calico
ln -s /bin/cni-plugin-install /bin/calico-ipam


%postun -n node
# Restore rc.local backup
rm -f /etc/rc.local
mv /etc/rc.local.bak /etc/rc.local


%postun -n cni-plugin
rm -f /bin/calico
rm -f /bin/calico-ipam


%changelog
* Thu Dec 18 2025 Oracle Cloud Native Environment Authors <noreply@oracle.com> - %{version}-%{oracle_release_version}
- Add Oracle specific files for calico
