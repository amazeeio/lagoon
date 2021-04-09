ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
FROM ${UPSTREAM_REPO:-uselagoon}/commons:${UPSTREAM_TAG:-latest} as commons
FROM jboss/keycloak:7.0.1

ARG LAGOON_VERSION
ENV LAGOON_VERSION=$LAGOON_VERSION

USER root

RUN microdnf install -y nc python2 \
    && microdnf clean all \
    && rm -rf /var/cache/yum

LABEL maintainer="amazee.io"
ENV LAGOON=keycloak

# Copy commons files
COPY --from=commons /lagoon /lagoon
COPY --from=commons /bin/fix-permissions /bin/ep /bin/docker-sleep /bin/
COPY --from=commons /home /home

RUN chmod g+w /etc/passwd \
    && mkdir -p /home

# Fix permissions for JBoss home directory
RUN chgrp -R 0 $JBOSS_HOME &&\
    chmod -R g+rw $JBOSS_HOME

# Reproduce behavior of Alpine: Run Bash as sh
RUN rm -f /bin/sh && ln -s /bin/bash /bin/sh

ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /sbin/tini
RUN chmod +x /sbin/tini

ENV TMPDIR=/tmp \
    TMP=/tmp \
    HOME=/home \
    # When Bash is invoked via `sh` it behaves like the old Bourne Shell and sources a file that is given in `ENV`
    ENV=/home/.bashrc \
    # When Bash is invoked as non-interactive (like `bash -c command`) it sources a file that is given in `BASH_ENV`
    BASH_ENV=/home/.bashrc \
    KEYCLOAK_ADMIN_USER=admin \
    KEYCLOAK_ADMIN_PASSWORD=admin \
    KEYCLOAK_REALM=lagoon \
    KEYCLOAK_REALM_ROLES=admin \
    DB_ADDR=keycloak-db \
    DB_USER=keycloak \
    DB_PASSWORD=keycloak \
    DB_DATABASE=keycloak \
    KEYCLOAK_LAGOON_ADMIN_USERNAME=lagoonadmin \
    KEYCLOAK_LAGOON_ADMIN_PASSWORD=lagoonadmin \
    PROXY_ADDRESS_FORWARDING=true \
    KEYCLOAK_API_CLIENT_SECRET=39d5282d-3684-4026-b4ed-04bbc034b61a \
    KEYCLOAK_AUTH_SERVER_CLIENT_SECRET=f605b150-7636-4447-abd3-70988786b330 \
    JAVA_OPTS="-server -Xms4096m -Xmx6144m -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true -Djboss.modules.system.pkgs=org.jboss.byteman -Djava.awt.headless=true"

VOLUME /opt/jboss/keycloak/standalone/data

COPY start.sh /opt/jboss/tools/start.sh
COPY wait-for-mariadb.sh /lagoon/entrypoints/99-wait-for-mariadb.sh
COPY profile.properties /opt/jboss/keycloak/standalone/configuration/profile.properties

ENTRYPOINT ["/sbin/tini", "--", "/lagoon/entrypoints.bash"]
CMD ["/opt/jboss/tools/start.sh"]
