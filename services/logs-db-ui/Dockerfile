ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
FROM ${UPSTREAM_REPO:-uselagoon}/kibana-7:${UPSTREAM_TAG:-latest}

ARG LAGOON_VERSION
ENV LAGOON_VERSION=$LAGOON_VERSION

ENV NODE_OPTIONS="--max-old-space-size=2048" \
    LOGSDB_KIBANASERVER_PASSWORD=kibanaserver \
    LOGSDB_ADMIN_PASSWORD=admin \
    ELASTICSEARCH_HOSTS=http://logs-db-service:9200 \
    OPENDISTRO_SECURITY_OPENID_CLIENT_SECRET=xxxx \
    KEYCLOAK_ADMIN_USER=admin \
    KEYCLOAK_ADMIN_PASSWORD=admin

RUN echo $'\n\
xpack.monitoring.enabled: true\n\
xpack.graph.enabled: true\n\
xpack.ml.enabled: false\n\
xpack.apm.enabled: false\n\
xpack.security.enabled: false\n\
xpack.watcher.enabled: false\n\
xpack.spaces.enabled: false\n\
xpack.infra.enabled: false \n\
xpack.uptime.enabled: false\n\
xpack.reporting.enabled: false\n\
\n\
# Configure the Kibana internal server user\n\
elasticsearch.username: "kibanaserver"\n\
elasticsearch.password: "${LOGSDB_KIBANASERVER_PASSWORD}"\n\
\n\
# Disable SSL verification because we use self-signed demo certificates\n\
elasticsearch.ssl.verificationMode: none\n\
\n\
# Whitelist the opendistro_security Multi Tenancy Header\n\
elasticsearch.requestHeadersWhitelist: [ "Authorization", "securitytenant" ]\n\
\n\
# Enable multitenancy\n\
opendistro_security.multitenancy.enabled: true\n\
# Disable opendistro_security global tenant\n\
opendistro_security.multitenancy.tenants.enable_global: false\n\
opendistro_security.multitenancy.tenants.enable_private: false\n\
# v14 and above: Enable OpenID authentication\n\
opendistro_security.auth.type: "openid"\n\
\n\
# the IdP metadata endpoint\n\
opendistro_security.openid.connect_url: "${KEYCLOAK_URL:-}/auth/realms/lagoon/.well-known/openid-configuration"\n\
\n\
# the ID of the OpenID Connect client in your IdP\n\
opendistro_security.openid.client_id: "lagoon-opendistro-security"\n\
\n\
# the client secret of the OpenID Connect client\n\
opendistro_security.openid.client_secret: "${OPENDISTRO_SECURITY_OPENID_CLIENT_SECRET}"\n\
\n\
# the URL of kibana which us used as the redirect URL for openid
opendistro_security.openid.base_redirect_url: "${LOGSDB_UI_URL:-http://0.0.0.0:5601}"\n\
\n\
# optional: the scope of the identity token\n\
opendistro_security.openid.scope: "profile email"\n\
\n\
opendistro_security.cookie.password: "${OPENDISTRO_SECURITY_COOKIE_PASSWORD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"\n\
\n\
' >> config/kibana.yml

RUN bin/kibana-plugin --allow-root install https://d3g5vo6xdbdb9a.cloudfront.net/downloads/kibana-plugins/opendistro-security/opendistro_security_kibana_plugin-1.6.0.0.zip
COPY opendistro_security.js /usr/share/kibana/plugins/opendistro_security/lib/backend/opendistro_security.js

COPY entrypoints/80-keycloak-url.bash /lagoon/entrypoints/
COPY entrypoints/81-logs-db-ui-url.bash /lagoon/entrypoints/
COPY entrypoints/90-keycloak-client-secret.bash /lagoon/entrypoints/

RUN fix-permissions config/kibana.yml

