ARG IMAGE_REPO
FROM ${IMAGE_REPO:-lagoon}/kubectl

# the kubectl image comes with an HOME=/home which is needed to run as unpriviledged, but kubectl-build-deploy-dind will run as root
RUN rm -rf /root && ln -s /home /root
ENV LAGOON=kubectl-build-deploy-dind

RUN  mkdir -p /kubectl-build-deploy/git
RUN  mkdir -p /kubectl-build-deploy/lagoon

WORKDIR /kubectl-build-deploy/git

COPY docker-entrypoint.sh /lagoon/entrypoints/100-docker-entrypoint.sh
COPY build-deploy.sh /kubectl-build-deploy/build-deploy.sh
COPY build-deploy-docker-compose.sh /kubectl-build-deploy/build-deploy-docker-compose.sh

COPY scripts /kubectl-build-deploy/scripts

COPY helmcharts  /kubectl-build-deploy/helmcharts

ENV IMAGECACHE_REGISTRY=imagecache.amazeeio.cloud

RUN curl -sSL https://github.com/smlx/lagoon-ges/releases/download/v0.2.0/lagoon-ges_0.2.0_linux_amd64.tar.gz \
      | tar -xz -C /usr/local/bin lagoon-ges

CMD ["/kubectl-build-deploy/build-deploy.sh"]
