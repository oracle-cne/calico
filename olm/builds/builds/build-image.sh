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
    echo "  ${0} version calico_binary_location" >&2
    exit 1
fi

VERSION=v${1}
IMAGE_LOCATION=${2}
REGISTRY=${3:-container-registry.oracle.com/olcne}
DOCKER_FILE=./olm/builds/Dockerfile.ol8

mkdir -p ${IMAGE_LOCATION}/oracle_docker

CALICO_IMAGE="apiserver cni csi ctl dikastes kube-controllers node node-driver-registrar pod2daemon-flexvol typha"
for IMAGE in ${CALICO_IMAGE}; do
        docker build -v /etc/yum.repos.d/ol_artifacts.repo:/etc/yum.repos.d/ol_artifacts.repo --pull --build-arg https_proxy=${https_proxy} --build-arg VERSION=${VERSION} --build-arg IMAGE=${IMAGE} -t ${REGISTRY}/${IMAGE}:${VERSION} -f ${DOCKER_FILE}.${IMAGE} .
        docker save -o ${IMAGE_LOCATION}/oracle_docker/${IMAGE}.tar ${REGISTRY}/${IMAGE}:${VERSION}
done
