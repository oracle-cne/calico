
%global debug_package %{nil}
%{!?registry: %global registry container-registry.oracle.com/olcne}
%global _buildhost build-ol%{?oraclelinux}-%{?_arch}.oracle.com

%global app_name calico
%global app_version 3.30.6
%global oracle_release_version 1

Name:		%{app_name}-container-image
Version:	%{app_version}
Release:	%{oracle_release_version}%{?dist}
Summary:	Calico network connectivity and security policy enforcement tool http://www.projectcalico.org
License:	Apache 2.0
URL:		https://github.com/projectcalico/calico
Source0:	%{name}-%{version}.tar.bz2
Vendor:		Oracle America

%description
Calico is an open source networking and network security solution for Kubernetes, virtual machines, and bare-metal workloads. Calico provides two major services for Cloud Native applications:

 - Network connectivity between workloads.
 - Network security policy enforcement between workloads.


%prep
%setup -q -n %{name}-%{version}


%build
%define image_tag %{version}
dnf clean all && \
  yumdownloader --destdir=${PWD}/rpms *-%{version}-%{release}.%{_build_arch} --exclude calico-container-image-%{version}-%{release}.%{_build_arch}

chmod +x ./olm/builds/build-image.sh
./olm/builds/build-image.sh \
    %{image_tag} \
    _output \
    %{registry}


%install
mkdir -p %{buildroot}/usr/local/share/olcne
install -m 755 -d %{buildroot}/usr/local/share/olcne
images=(apiserver cni csi ctl dikastes kube-controllers node node-driver-registrar pod2daemon-flexvol typha)
for image in "${images[@]}"; do
  echo "+++ INSTALLING DOCKER IMAGES ${image}"
  install -p -m 755 -t %{buildroot}/usr/local/share/olcne _output/oracle_docker/${image}.tar
done


%files -n calico-container-image
%license THIRD_PARTY_LICENSES.txt
/usr/local/share/olcne/apiserver.tar
/usr/local/share/olcne/cni.tar
/usr/local/share/olcne/csi.tar
/usr/local/share/olcne/ctl.tar
/usr/local/share/olcne/dikastes.tar
/usr/local/share/olcne/kube-controllers.tar
/usr/local/share/olcne/node.tar
/usr/local/share/olcne/node-driver-registrar.tar
/usr/local/share/olcne/pod2daemon-flexvol.tar
/usr/local/share/olcne/typha.tar


%changelog
* Fri Jan 23 2026 Oracle Cloud Native Environment Authors <noreply@oracle.com> - %{version}-%{oracle_release_version}
- Added Oracle Specific Files For calico
