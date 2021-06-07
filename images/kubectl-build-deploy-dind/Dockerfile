ARG IMAGE_REPO
FROM ${IMAGE_REPO:-lagoon}/kubectl

ENV LAGOON=kubectl-build-deploy-dind

RUN mkdir -p /kubectl-build-deploy/git
RUN mkdir -p /kubectl-build-deploy/lagoon

WORKDIR /kubectl-build-deploy/git

COPY docker-entrypoint.sh /lagoon/entrypoints/100-docker-entrypoint.sh
COPY build-deploy.sh /kubectl-build-deploy/build-deploy.sh
COPY build-deploy-docker-compose.sh /kubectl-build-deploy/build-deploy-docker-compose.sh

COPY scripts /kubectl-build-deploy/scripts

COPY helmcharts  /kubectl-build-deploy/helmcharts

ENV IMAGECACHE_REGISTRY=imagecache.amazeeio.cloud

# enable running unprivileged
RUN fix-permissions /home && fix-permissions /kubectl-build-deploy

CMD ["/kubectl-build-deploy/build-deploy.sh"]
