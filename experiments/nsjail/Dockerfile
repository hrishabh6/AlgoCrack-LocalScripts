FROM eclipse-temurin:21-jdk-jammy AS build

ARG NSJAIL_VERSION=3.6

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        autoconf bison flex g++ gcc git libnl-route-3-dev libprotobuf-dev \
        libtool make pkg-config protobuf-compiler \
    && git clone --depth 1 --branch "${NSJAIL_VERSION}" https://github.com/google/nsjail.git /src/nsjail \
    && make -C /src/nsjail

FROM eclipse-temurin:21-jdk-jammy

ARG RUNNER_SCRIPT_SHA=unspecified
RUN test -n "${RUNNER_SCRIPT_SHA}"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libnl-route-3-200 libprotobuf23 \
    && apt-get clean \
    && useradd --uid 10001 --create-home --shell /usr/sbin/nologin runner \
    && mkdir -p /workspace /runner-secret \
        /opt/jail-root/usr /opt/jail-root/lib /opt/jail-root/lib64 \
        /opt/jail-root/bin /opt/jail-root/workspace /opt/jail-root/tmp \
        /opt/jail-root/proc /opt/jail-root/opt/java \
    && printf 'not-visible-to-jail\n' > /runner-secret/value \
    && chmod 0444 /runner-secret/value \
    && chmod 0555 /opt/jail-root

COPY --from=build /src/nsjail/nsjail /usr/local/bin/nsjail
ARG RUNNER_SCRIPT_SHA
COPY runner.sh /usr/local/bin/run-nsjail
COPY fixtures /opt/nsjail-fixtures

RUN chmod 0555 /usr/local/bin/nsjail /usr/local/bin/run-nsjail \
    && chmod -R a+rX /opt/nsjail-fixtures

USER 10001:10001
WORKDIR /workspace
CMD ["sleep", "infinity"]
