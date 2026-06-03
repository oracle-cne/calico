FROM container-registry.oracle.com/os/oraclelinux:9

COPY rpms/calicoctl*.rpm /tmp/

RUN dnf install -y /tmp/*.rpm &&\
    dnf clean all && rm -rfv /var/cache/yum /tmp/* /LICENSES &&\
    ln -s /usr/share/licenses /LICENSES

FROM container-registry.oracle.com/os/oraclelinux:9-slim

COPY --from=0 /bin/calicoctl /calicoctl

COPY --from=0 /usr/share/licenses/calicoctl/* /usr/share/licenses/

ENV CALICO_CTL_CONTAINER=TRUE

ENV PATH="$PATH:/"

WORKDIR /root

ENTRYPOINT ["/calicoctl"]
