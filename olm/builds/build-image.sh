#!/bin/bash -x
#
# Copyright (c) 2019, Oracle and/or its affiliates. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

if [[ ${#} -eq 0 ]] ; then
    echo "usage:" >&2
    echo "  ${0} version calico_binary_location [registry] [ol8|ol9] [yum_repo_config_dir]" >&2
    exit 1
fi

VERSION=v${1}
IMAGE_LOCATION=${2}
REGISTRY=${3:-container-registry.oracle.com/olcne}
IMAGE_PLATFORM=${4:-ol9}
YUM_REPO_CONFIG_DIR=${5:-}
case "${IMAGE_PLATFORM}" in
    ol8|ol9) ;;
    *)
        echo "build-image.sh: unsupported image platform ${IMAGE_PLATFORM}; expected ol8 or ol9" >&2
        exit 1
        ;;
esac
DOCKER_FILE=./olm/builds/Dockerfile.${IMAGE_PLATFORM}
image_tag="${VERSION}"

echo "build-image.sh: version=${VERSION}"
echo "build-image.sh: image_location=${IMAGE_LOCATION}"
echo "build-image.sh: registry=${REGISTRY}"
echo "build-image.sh: image_platform=${IMAGE_PLATFORM}"
if [[ -n "${YUM_REPO_CONFIG_DIR}" ]]; then
    echo "build-image.sh: using unified yum repo config directory ${YUM_REPO_CONFIG_DIR}"
else
    echo "build-image.sh: no unified yum repo config directory provided"
fi

mkdir -p ${IMAGE_LOCATION}/oracle_docker
echo "build-image.sh: ensured output directory ${IMAGE_LOCATION}/oracle_docker"

CALICO_IMAGE="apiserver cni csi ctl dikastes kube-controllers node node-driver-registrar pod2daemon-flexvol typha"
for IMAGE in ${CALICO_IMAGE}; do
	echo "build-image.sh: building image=${IMAGE} dockerfile=${DOCKER_FILE}.${IMAGE}"
	build_args=(
	    --pull
	    --build-arg "https_proxy=${https_proxy:-}"
	    --build-arg "IMAGE=${IMAGE}"
	    -t "${REGISTRY}/${IMAGE}:${image_tag}"
	    -f "${DOCKER_FILE}.${IMAGE}"
	    .
	)
	if [[ -n "${YUM_REPO_CONFIG_DIR}" ]]; then
	    if [[ ! -f "${YUM_REPO_CONFIG_DIR}/yum.conf" ]]; then
	        echo "build-image.sh: missing yum config file ${YUM_REPO_CONFIG_DIR}/yum.conf" >&2
	        exit 1
	    fi
	    if [[ ! -d "${YUM_REPO_CONFIG_DIR}/yum.repos.d" ]]; then
	        echo "build-image.sh: missing yum repo directory ${YUM_REPO_CONFIG_DIR}/yum.repos.d" >&2
	        exit 1
	    fi
	    build_args=(
	        --volume "${YUM_REPO_CONFIG_DIR}/yum.conf:/etc/yum.conf:ro"
	        --volume "${YUM_REPO_CONFIG_DIR}/yum.repos.d:/etc/yum.repos.d:ro"
	        "${build_args[@]}"
	    )
	fi
	podman build "${build_args[@]}"
	echo "build-image.sh: saving image=${REGISTRY}/${IMAGE}:${image_tag} to ${IMAGE_LOCATION}/oracle_docker/${IMAGE}.tar"
	podman save -o "${IMAGE_LOCATION}/oracle_docker/${IMAGE}.tar" "${REGISTRY}/${IMAGE}:${image_tag}"
done
