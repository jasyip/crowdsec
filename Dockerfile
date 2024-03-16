# vim: set ft=dockerfile:
FROM golang:1.21.7-alpine3.18 AS build

ARG BUILD_VERSION
ARG YQ_VERSION=4.42.1

WORKDIR /go/src/crowdsec

# We like to choose the release of re2 to use, and Alpine does not ship a static version anyway.
ENV RE2_VERSION=2023-03-01
ENV BUILD_VERSION=${BUILD_VERSION}

# wizard.sh requires GNU coreutils
RUN apk add --no-cache git g++ gcc libc-dev make bash gettext binutils-gold coreutils pkgconfig && \
    wget -qO - https://github.com/google/re2/archive/refs/tags/${RE2_VERSION}.tar.gz | \
        tar -xzf - && \
    cd re2-${RE2_VERSION} && \
    make install && \
    echo "githubciXXXXXXXXXXXXXXXXXXXXXXXX" > /etc/machine-id && \
    cd .. && \
    wget -qO - "https://github.com/mikefarah/yq/archive/refs/tags/v${YQ_VERSION}.tar.gz" | \
        tar -xzf - --strip-components 1 && CGO_ENABLED=0 go build -o /yq -ldflags=-extldflags=-static .

COPY . .

RUN make clean release DOCKER_BUILD=1 BUILD_STATIC=1 && \
    cd crowdsec-v* && \
    ./wizard.sh --docker-mode && \
    cd - >/dev/null && \
    cscli hub update && \
    cscli collections install crowdsecurity/linux && \
    cscli parsers install crowdsecurity/whitelists

    # In case we need to remove agents here..
    # cscli machines list -o json | yq '.[].machineId' | xargs -r cscli machines delete

FROM gcr.io/distroless/static-debian12:debug-nonroot as slim

SHELL ["/busybox/sh", "-c"]
USER root

RUN install -o nonroot -g nonroot -m755 -d /staging/etc/crowdsec \
                                           /staging/etc/crowdsec/acquis.d \
                                           /staging/var/lib/crowdsec \
                                           /var/lib/crowdsec/data

COPY --from=build /yq /usr/local/bin/crowdsec /usr/local/bin/cscli /usr/local/bin/
USER nonroot
COPY --from=build --chown=nonroot:nonroot /etc/crowdsec /staging/etc/crowdsec
COPY --from=build --chown=nonroot:nonroot /go/src/crowdsec/docker/docker_start.sh /
COPY --from=build --chown=nonroot:nonroot /go/src/crowdsec/docker/config.yaml /staging/etc/crowdsec/config.yaml
RUN yq -n '.url="http://0.0.0.0:8080"' | install -m600 -o nonroot -g nonroot /dev/stdin /staging/etc/crowdsec/local_api_credentials.yaml

HEALTHCHECK CMD wget -q --spider localhost:8080/health || exit 1
ENTRYPOINT ["sh", "/docker_start.sh"]

FROM slim as plugins

# Due to the wizard using cp -n, we have to copy the config files directly from the source as -n does not exist in busybox cp
# The files are here for reference, as users will need to mount a new version to be actually able to use notifications
COPY --from=build \
    /go/src/crowdsec/cmd/notification-email/email.yaml \
    /go/src/crowdsec/cmd/notification-http/http.yaml \
    /go/src/crowdsec/cmd/notification-slack/slack.yaml \
    /go/src/crowdsec/cmd/notification-splunk/splunk.yaml \
    /go/src/crowdsec/cmd/notification-sentinel/sentinel.yaml \
    /staging/etc/crowdsec/notifications/

COPY --from=build /usr/local/lib/crowdsec/plugins /usr/local/lib/crowdsec/plugins

FROM slim as geoip

COPY --from=build /var/lib/crowdsec /staging/var/lib/crowdsec

FROM plugins as full

COPY --from=build /var/lib/crowdsec /staging/var/lib/crowdsec
