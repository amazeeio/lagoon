SHELL := /bin/bash
# amazee.io lagoon Makefile The main purpose of this Makefile is to provide easier handling of
# building images and running tests It understands the relation of the different images (like
# nginx-drupal is based on nginx) and builds them in the correct order Also it knows which
# services in docker-compose.yml are depending on which base images or maybe even other service
# images
#
# The main commands are:

# make build/<imagename>
# Builds an individual image and all of it's needed parents. Run `make build-list` to get a list of
# all buildable images. Make will keep track of each build image with creating an empty file with
# the name of the image in the folder `build`. If you want to force a rebuild of the image, either
# remove that file or run `make clean`

# make build
# builds all images in the correct order. Uses existing images for layer caching, define via `TAG`
# which branch should be used

# make tests/<testname>
# Runs individual tests. In a nutshell it does:
# 1. Builds all needed images for the test
# 2. Starts needed Lagoon services for the test via docker-compose up
# 3. Executes the test
#
# Run `make tests-list` to see a list of all tests.

# make tests
# Runs all tests together. Can be executed with `-j2` for two parallel running tests

# make up
# Starts all Lagoon Services at once, usefull for local development or just to start all of them.

# make logs
# Shows logs of Lagoon Services (aka docker-compose logs -f)

# make minishift
# Some tests need a full openshift running in order to test deployments and such. This can be
# started via openshift. It will:
# 1. Download minishift cli
# 2. Start an OpenShift Cluster
# 3. Configure OpenShift cluster to our needs

# make minishift/stop
# Removes an OpenShift Cluster

# make minishift/clean
# Removes all openshift related things: OpenShift itself and the minishift cli

#######
####### Default Variables
#######

# Parameter for all `docker build` commands, can be overwritten by passing `DOCKER_BUILD_PARAMS=` via the `-e` option
DOCKER_BUILD_PARAMS := --quiet

# On CI systems like jenkins we need a way to run multiple testings at the same time. We expect the
# CI systems to define an Environment variable CI_BUILD_TAG which uniquely identifies each build.
# If it's not set we assume that we are running local and just call it lagoon.
CI_BUILD_TAG ?= lagoon
# SOURCE_REPO is the repos where the upstream images are found (usually uselagoon, but can substiture for testlagoon)
UPSTREAM_REPO ?= uselagoon
UPSTREAM_TAG ?= latest

# Local environment
ARCH := $(shell uname | tr '[:upper:]' '[:lower:]')
LAGOON_VERSION := $(shell git describe --tags --exact-match 2>/dev/null || echo development)
DOCKER_DRIVER := $(shell docker info -f '{{.Driver}}')

# Version and Hash of the OpenShift cli that should be downloaded
MINISHIFT_VERSION := 1.34.1
OPENSHIFT_VERSION := v3.11.0
MINISHIFT_CPUS := $(nproc --ignore 2)
MINISHIFT_MEMORY := 8GB
MINISHIFT_DISK_SIZE := 30GB

# Version and Hash of the minikube cli that should be downloaded
K3S_VERSION := v1.17.0-k3s.1
KUBECTL_VERSION := v1.21.1
HELM_VERSION := v3.6.0
MINIKUBE_VERSION := 1.5.2
MINIKUBE_PROFILE := $(CI_BUILD_TAG)-minikube
MINIKUBE_CPUS := $(nproc --ignore 2)
MINIKUBE_MEMORY := 2048
MINIKUBE_DISK_SIZE := 30g

K3D_VERSION := 1.4.0
# k3d has a 35-char name limit
K3D_NAME := k3s-$(shell echo $(CI_BUILD_TAG) | sed -E 's/.*(.{31})$$/\1/')

# Name of the Branch we are currently in
BRANCH_NAME := $(shell git rev-parse --abbrev-ref HEAD)
SAFE_BRANCH_NAME := $(shell echo $(BRANCH_NAME) | sed -E 's/[^[:alnum:]_.-]//g' | cut -c 1-128)

# Skip image scanning by default to make building images substantially faster
SCAN_IMAGES := false

# Init the file that is used to hold the image tag cross-reference table
$(shell >build.txt)
$(shell >scan.txt)

#######
####### Functions
#######

# Builds a docker image. Expects as arguments: name of the image, location of Dockerfile, path of
# Docker Build Context
docker_build = DOCKER_SCAN_SUGGEST=false docker build $(DOCKER_BUILD_PARAMS) --build-arg LAGOON_VERSION=$(LAGOON_VERSION) --build-arg IMAGE_REPO=$(CI_BUILD_TAG) --build-arg UPSTREAM_REPO=$(UPSTREAM_REPO) --build-arg UPSTREAM_TAG=$(UPSTREAM_TAG) -t $(CI_BUILD_TAG)/$(1) -f $(2) $(3)

scan_cmd = docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/Library/Caches:/root/.cache/ aquasec/trivy --timeout 5m0s $(CI_BUILD_TAG)/$(1) >> scan.txt

ifeq ($(SCAN_IMAGES),true)
	scan_image = $(scan_cmd)
else
	scan_image =
endif

# Tags an image with the `testlagoon` repository and pushes it
docker_publish_testlagoon = docker tag $(CI_BUILD_TAG)/$(1) testlagoon/$(2) && docker push testlagoon/$(2) | cat

# Tags an image with the `uselagoon` repository and pushes it
docker_publish_uselagoon = docker tag $(CI_BUILD_TAG)/$(1) uselagoon/$(2) && docker push uselagoon/$(2) | cat


#######
####### Base Images
#######
####### Base Images are the base for all other images and are also published for clients to use during local development

images :=     oc \
							kubectl \
							oc-build-deploy-dind \
							kubectl-build-deploy-dind \
							athenapdf-service \
							curator \
							docker-host

# base-images is a variable that will be constantly filled with all base image there are
base-images += $(images)
s3-images += $(images)

# List with all images prefixed with `build/`. Which are the commands to actually build images
build-images = $(foreach image,$(images),build/$(image))

# Define the make recipe for all base images
$(build-images):
#	Generate variable image without the prefix `build/`
	$(eval image = $(subst build/,,$@))
# Call the docker build
	$(call docker_build,$(image),images/$(image)/Dockerfile,images/$(image))
#scan created image with Trivy
	$(call scan_image,$(image),)
# Touch an empty file which make itself is using to understand when the image has been last build
	touch $@

# Define dependencies of Base Images so that make can build them in the right order. There are two
# types of Dependencies
# 1. Parent Images, like `build/centos7-node6` is based on `build/centos7` and need to be rebuild
#    if the parent has been built
# 2. Dockerfiles of the Images itself, will cause make to rebuild the images if something has
#    changed on the Dockerfiles
build/docker-host: images/docker-host/Dockerfile
build/oc: images/oc/Dockerfile
build/kubectl: images/kubectl/Dockerfile
build/curator: images/curator/Dockerfile
build/oc-build-deploy-dind: build/oc images/oc-build-deploy-dind
build/athenapdf-service:images/athenapdf-service/Dockerfile
build/kubectl-build-deploy-dind: build/kubectl images/kubectl-build-deploy-dind


#######
####### Service Images
#######
####### Services Images are the Docker Images used to run the Lagoon Microservices, these images
####### will be expected by docker-compose to exist.

# Yarn Workspace Image which builds the Yarn Workspace within a single image. This image will be
# used by all microservices based on Node.js to not build similar node packages again
build-images += yarn-workspace-builder
build/yarn-workspace-builder: images/yarn-workspace-builder/Dockerfile
	$(eval image = $(subst build/,,$@))
	$(call docker_build,$(image),images/$(image)/Dockerfile,.)
	$(call scan_image,$(image),)
	touch $@

#######
####### Task Images
#######
####### Task Images are standalone images that are used to run advanced tasks when using the builddeploy controllers.

# task-activestandby is the task image that lagoon builddeploy controller uses to run active/standby misc tasks
build/task-activestandby: taskimages/activestandby/Dockerfile

# the `taskimages` are the name of the task directories contained within `taskimages/` in the repostory root
taskimages := activestandby
# in the following process, taskimages are prepended with `task-` to make built task images more identifiable
# use `build/task-<name>` to build it, but the references in the directory structure remain simpler with
# taskimages/
#	activestandby
#	anothertask
# the resulting image will be called `task-<name>` instead of `<name>` to make it known that it is a task image
task-images += $(foreach image,$(taskimages),task-$(image))
build-taskimages = $(foreach image,$(taskimages),build/task-$(image))
$(build-taskimages):
	$(eval image = $(subst build/task-,,$@))
	$(call docker_build,task-$(image),taskimages/$(image)/Dockerfile,taskimages/$(image))
	$(call scan_image,task-$(image),)
	touch $@

# Variables of service images we manage and build
services :=	api \
			api-db \
			api-redis \
			auth-server \
			auto-idler \
			backup-handler \
			broker \
			broker-single \
			controllerhandler \
			drush-alias \
			keycloak \
			keycloak-db \
			logs-concentrator \
			logs-db-curator \
			logs-dispatcher \
			logs-tee \
			logs2email \
			logs2microsoftteams \
			logs2rocketchat \
			logs2slack \
			logs2webhook \
			storage-calculator \
			ui \
			webhook-handler \
			webhooks2tasks


service-images += $(services)

build-services = $(foreach image,$(services),build/$(image))

# Recipe for all building service-images
$(build-services):
	$(eval image = $(subst build/,,$@))
	$(call docker_build,$(image),services/$(image)/Dockerfile,services/$(image))
	$(call scan_image,$(image),)
	touch $@

# Dependencies of Service Images
build/auth-server build/logs2email build/logs2slack build/logs2rocketchat build/logs2webhook build/logs2microsoftteams build/backup-handler build/controllerhandler build/webhook-handler build/webhooks2tasks build/api build/ui: build/yarn-workspace-builder
build/api-db: services/api-db/Dockerfile
build/api-redis: services/api-redis/Dockerfile
build/auto-idler: build/oc
build/broker-single: services/broker/Dockerfile
build/broker: build/broker-single
build/drush-alias: services/drush-alias/Dockerfile
build/keycloak-db: services/keycloak-db/Dockerfile
build/keycloak: services/keycloak/Dockerfile
build/logs-concentrator: services/logs-concentrator/Dockerfile
build/logs-db-curator: build/curator
build/logs-dispatcher: services/logs-dispatcher/Dockerfile
build/logs-tee: services/logs-tee/Dockerfile
build/storage-calculator: build/oc
build/tests-controller-kubernetes: build/tests
build/tests-kubernetes: build/tests
build/tests-openshift: build/tests
build/tests: tests/Dockerfile
build/local-minio:
# Auth SSH needs the context of the root folder, so we have it individually
build/ssh: services/ssh/Dockerfile
	$(eval image = $(subst build/,,$@))
	$(call docker_build,$(image),services/$(image)/Dockerfile,.)
	$(call scan_image,$(image),)
	touch $@
service-images += ssh

build/local-git: local-dev/git/Dockerfile
build/local-api-data-watcher-pusher: local-dev/api-data-watcher-pusher/Dockerfile
build/local-registry: local-dev/registry/Dockerfile
build/local-dbaas-provider: local-dev/dbaas-provider/Dockerfile
build/local-mongodb-dbaas-provider: local-dev/mongodb-dbaas-provider/Dockerfile

# Images for local helpers that exist in another folder than the service images
localdevimages := local-git \
									local-api-data-watcher-pusher \
									local-registry \
									local-dbaas-provider \
									local-mongodb-dbaas-provider

service-images += $(localdevimages)
build-localdevimages = $(foreach image,$(localdevimages),build/$(image))

$(build-localdevimages):
	$(eval folder = $(subst build/local-,,$@))
	$(eval image = $(subst build/,,$@))
	$(call docker_build,$(image),local-dev/$(folder)/Dockerfile,local-dev/$(folder))
	$(call scan_image,$(image),)
	touch $@

# Image with ansible test
build/tests:
	$(eval image = $(subst build/,,$@))
	$(call docker_build,$(image),$(image)/Dockerfile,$(image))
	$(call scan_image,$(image),)
	touch $@
service-images += tests

s3-images += $(service-images)

#######
####### Commands
#######
####### List of commands in our Makefile

# Builds all Images
.PHONY: build
build: $(foreach image,$(base-images) $(service-images) $(task-images),build/$(image))
# Outputs a list of all Images we manage
.PHONY: build-list
build-list:
	@for number in $(foreach image,$(build-images),build/$(image)); do \
			echo $$number ; \
	done

# Define list of all tests
all-k8s-tests-list:=				nginx \
														drupal-php72 \
														drupal-php73 \
														drupal-php74 \
														python \
														active-standby-kubernetes \
														features-kubernetes \
														node-mongodb

all-k8s-tests = $(foreach image,$(all-k8s-tests-list),k8s-tests/$(image))

# Run all k8s tests
.PHONY: k8s-tests
k8s-tests: $(all-k8s-tests)

.PHONY: $(all-k8s-tests)
$(all-k8s-tests): k3d k8s-test-services-up
		$(MAKE) push-local-registry -j6
		$(eval testname = $(subst k8s-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) UPSTREAM_REPO=$(UPSTREAM_REPO) UPSTREAM_TAG=$(UPSTREAM_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility run --rm \
			tests-kubernetes ansible-playbook --skip-tags="skip-on-kubernetes,skip-on-jenkins" --extra-vars="@/ansible/tests/vars/test_vars.yaml" \
			/ansible/tests/$(testname).yaml \
			--extra-vars \
			"$$(cat $$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)') | \
				jq -rcsR '{kubeconfig: .}')"

# push command of our base images into minishift
push-local-registry-images = $(foreach image,$(base-images) $(task-images),[push-local-registry]-$(image))
# tag and push all images
.PHONY: push-local-registry
push-local-registry: $(push-local-registry-images)
# tag and push of each image
.PHONY:
	docker login -u admin -p admin 172.17.0.1:8084
	$(push-local-registry-images)

$(push-local-registry-images):
	$(eval image = $(subst [push-local-registry]-,,$@))
	$(eval image = $(subst __,:,$(image)))
	$(info pushing $(image) to local local-registry)
	if docker inspect $(CI_BUILD_TAG)/$(image) > /dev/null 2>&1; then \
		docker tag $(CI_BUILD_TAG)/$(image) localhost:5000/lagoon/$(image) && \
		docker push localhost:5000/lagoon/$(image) | cat; \
	fi

# Define list of all tests
all-openshift-tests-list:=	features-openshift \
														node \
														drupal-php72 \
														drupal-php73 \
														drupal-php74 \
														drupal-postgres \
														github \
														gitlab \
														bitbucket \
														nginx \
														elasticsearch \
														active-standby-openshift \
														node-mongodb
all-openshift-tests = $(foreach image,$(all-openshift-tests-list),openshift-tests/$(image))

.PHONY: openshift-tests
openshift-tests: $(all-openshift-tests)

# Run all tests
.PHONY: tests
tests: k8s-tests openshift-tests

# Wait for Keycloak to be ready (before this no API calls will work)
.PHONY: wait-for-keycloak
wait-for-keycloak:
	$(info Waiting for Keycloak to be ready....)
	grep -m 1 "Config of Keycloak done." <(docker-compose -p $(CI_BUILD_TAG) --compatibility logs -f keycloak 2>&1)

# Define a list of which Lagoon Services are needed for running any deployment testing
main-test-services = broker logs2email logs2slack logs2rocketchat logs2microsoftteams logs2webhook api api-db api-redis keycloak keycloak-db ssh auth-server local-git local-api-data-watcher-pusher local-minio

# Define a list of which Lagoon Services are needed for openshift testing
openshift-test-services = openshiftremove openshiftbuilddeploy openshiftbuilddeploymonitor openshiftmisc tests-openshift local-dbaas-provider local-mongodb-dbaas-provider

# Define a list of which Lagoon Services are needed for kubernetes testing
k8s-test-services = controllerhandler tests-kubernetes local-registry local-dbaas-provider local-mongodb-dbaas-provider drush-alias

# List of Lagoon Services needed for webhook endpoint testing
webhooks-test-services = webhook-handler webhooks2tasks backup-handler

# List of Lagoon Services needed for drupal testing
drupal-test-services = drush-alias

# All tests that use Webhook endpoints
webhook-tests = github gitlab bitbucket

# All Tests that use API endpoints
api-tests = node features-openshift features-kubernetes nginx elasticsearch active-standby-openshift active-standby-kubernetes node-mongodb

# All drupal tests
drupal-tests = drupal-php72 drupal-php73 drupal-php74 drupal-postgres

# These targets are used as dependencies to bring up containers in the right order.
.PHONY: main-test-services-up
main-test-services-up: $(foreach image,$(main-test-services),build/$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d $(main-test-services)
	$(MAKE) wait-for-keycloak

.PHONY: openshift-test-services-up
openshift-test-services-up: main-test-services-up $(foreach image,$(openshift-test-services),build/$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d $(openshift-test-services)

.PHONY: k8s-test-services-up
k8s-test-services-up: main-test-services-up $(foreach image,$(k8s-test-services),build/$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d $(k8s-test-services)

.PHONY: drupaltest-services-up
drupaltest-services-up: main-test-services-up $(foreach image,$(drupal-test-services),build/$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d $(drupal-test-services)

.PHONY: webhooks-test-services-up
webhooks-test-services-up: main-test-services-up $(foreach image,$(webhooks-test-services),build/$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d $(webhooks-test-services)

.PHONY: local-registry-up
local-registry-up: build/local-registry
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d local-registry

# broker-up is used to ensure the broker is running before the lagoon-builddeploy operator is installed
# when running kubernetes tests
.PHONY: broker-up
broker-up: build/broker-single
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d broker

openshift-run-api-tests = $(foreach image,$(api-tests),openshift-tests/$(image))
.PHONY: $(openshift-run-api-tests)
$(openshift-run-api-tests): minishift build/oc-build-deploy-dind openshift-test-services-up push-minishift
		$(eval testname = $(subst openshift-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility run --rm tests-openshift ansible-playbook /ansible/tests/$(testname).yaml

openshift-run-drupal-tests = $(foreach image,$(drupal-tests),openshift-tests/$(image))
.PHONY: $(openshift-run-drupal-tests)
$(openshift-run-drupal-tests): minishift build/oc-build-deploy-dind openshift-test-services-up drupaltest-services-up push-minishift
		$(eval testname = $(subst openshift-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility run --rm tests-openshift ansible-playbook /ansible/tests/$(testname).yaml

openshift-run-webhook-tests = $(foreach image,$(webhook-tests),openshift-tests/$(image))
.PHONY: $(openshift-run-webhook-tests)
$(openshift-run-webhook-tests): minishift build/oc-build-deploy-dind openshift-test-services-up webhooks-test-services-up push-minishift
		$(eval testname = $(subst openshift-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility run --rm tests-openshift ansible-playbook /ansible/tests/$(testname).yaml

# push command of our base images into minishift
push-minishift-images = $(foreach image,$(base-images),[push-minishift]-$(image))
# tag and push all images
.PHONY: push-minishift
push-minishift: minishift/login-docker-registry $(push-minishift-images)
# tag and push of each image
.PHONY: $(push-minishift-images)
$(push-minishift-images):
	$(eval image = $(subst [push-minishift]-,,$@))
	$(eval image = $(subst __,:,$(image)))
	$(info pushing $(image) to minishift registry)
	if docker inspect $(CI_BUILD_TAG)/$(image) > /dev/null 2>&1; then \
		docker tag $(CI_BUILD_TAG)/$(image) $$(cat minishift):30000/lagoon/$(image) && \
		docker push $$(cat minishift):30000/lagoon/$(image) | cat; \
	fi

push-docker-host-image: build/docker-host minishift/login-docker-registry
	docker tag $(CI_BUILD_TAG)/docker-host $$(cat minishift):30000/lagoon/docker-host
	docker push $$(cat minishift):30000/lagoon/docker-host | cat

lagoon-kickstart: $(foreach image,$(deployment-test-services-rest),build/$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) CI=false docker-compose -p $(CI_BUILD_TAG) --compatibility up -d $(deployment-test-services-rest)
	sleep 90
	curl -X POST -H "Content-Type: application/json" --data 'mutation { deployEnvironmentBranch(input: { project: { name: "lagoon" }, branchName: "master" } )}' http://localhost:3000/graphql
	make logs

#######
####### Publishing Images
#######
####### All main&PR images are pushed to testlagoon repository
#######

# Publish command to testlagoon docker hub, done on any main branch or PR
publish-testlagoon-baseimages = $(foreach image,$(base-images),[publish-testlagoon-baseimages]-$(image))
# tag and push all images

.PHONY: publish-testlagoon-baseimages
publish-testlagoon-baseimages: $(publish-testlagoon-baseimages)

# tag and push of each image
.PHONY: $(publish-testlagoon-baseimages)
$(publish-testlagoon-baseimages):
#   Calling docker_publish for image, but remove the prefix '[publish-testlagoon-baseimages]-' first
		$(eval image = $(subst [publish-testlagoon-baseimages]-,,$@))
# 	Publish images with version tag
		$(call docker_publish_testlagoon,$(image),$(image):$(BRANCH_NAME))


# Publish command to amazeeio docker hub, this should only be done during main deployments
publish-testlagoon-serviceimages = $(foreach image,$(service-images),[publish-testlagoon-serviceimages]-$(image))
# tag and push all images
.PHONY: publish-testlagoon-serviceimages
publish-testlagoon-serviceimages: $(publish-testlagoon-serviceimages)

# tag and push of each image
.PHONY: $(publish-testlagoon-serviceimages)
$(publish-testlagoon-serviceimages):
#   Calling docker_publish for image, but remove the prefix '[publish-testlagoon-serviceimages]-' first
		$(eval image = $(subst [publish-testlagoon-serviceimages]-,,$@))
# 	Publish images with version tag
		$(call docker_publish_testlagoon,$(image),$(image):$(BRANCH_NAME))


# Publish command to amazeeio docker hub, this should only be done during main deployments
publish-testlagoon-taskimages = $(foreach image,$(task-images),[publish-testlagoon-taskimages]-$(image))
# tag and push all images
.PHONY: publish-testlagoon-taskimages
publish-testlagoon-taskimages: $(publish-testlagoon-taskimages)

# tag and push of each image
.PHONY: $(publish-testlagoon-taskimages)
$(publish-testlagoon-taskimages):
#   Calling docker_publish for image, but remove the prefix '[publish-testlagoon-taskimages]-' first
		$(eval image = $(subst [publish-testlagoon-taskimages]-,,$@))
# 	Publish images with version tag
		$(call docker_publish_testlagoon,$(image),$(image):$(BRANCH_NAME))


#######
####### All tagged releases are pushed to uselagoon repository with new semantic tags
#######

# Publish command to uselagoon docker hub, only done on tags
publish-uselagoon-baseimages = $(foreach image,$(base-images),[publish-uselagoon-baseimages]-$(image))

# tag and push all images
.PHONY: publish-uselagoon-baseimages
publish-uselagoon-baseimages: $(publish-uselagoon-baseimages)

# tag and push of each image
.PHONY: $(publish-uselagoon-baseimages)
$(publish-uselagoon-baseimages):
#   Calling docker_publish for image, but remove the prefix '[publish-uselagoon-baseimages]-' first
		$(eval image = $(subst [publish-uselagoon-baseimages]-,,$@))
# 	Publish images as :latest
		$(call docker_publish_uselagoon,$(image),$(image):latest)
# 	Publish images with version tag
		$(call docker_publish_uselagoon,$(image),$(image):$(LAGOON_VERSION))


# Publish command to amazeeio docker hub, this should only be done during main deployments
publish-uselagoon-serviceimages = $(foreach image,$(service-images),[publish-uselagoon-serviceimages]-$(image))
# tag and push all images
.PHONY: publish-uselagoon-serviceimages
publish-uselagoon-serviceimages: $(publish-uselagoon-serviceimages)

# tag and push of each image
.PHONY: $(publish-uselagoon-serviceimages)
$(publish-uselagoon-serviceimages):
#   Calling docker_publish for image, but remove the prefix '[publish-uselagoon-serviceimages]-' first
		$(eval image = $(subst [publish-uselagoon-serviceimages]-,,$@))
# 	Publish images as :latest
		$(call docker_publish_uselagoon,$(image),$(image):latest)
# 	Publish images with version tag
		$(call docker_publish_uselagoon,$(image),$(image):$(LAGOON_VERSION))


# Publish command to amazeeio docker hub, this should only be done during main deployments
publish-uselagoon-taskimages = $(foreach image,$(task-images),[publish-uselagoon-taskimages]-$(image))
# tag and push all images
.PHONY: publish-uselagoon-taskimages
publish-uselagoon-taskimages: $(publish-uselagoon-taskimages)

# tag and push of each image
.PHONY: $(publish-uselagoon-taskimages)
$(publish-uselagoon-taskimages):
#   Calling docker_publish for image, but remove the prefix '[publish-uselagoon-taskimages]-' first
		$(eval image = $(subst [publish-uselagoon-taskimages]-,,$@))
# 	Publish images as :latest
		$(call docker_publish_uselagoon,$(image),$(image):latest)
# 	Publish images with version tag
		$(call docker_publish_uselagoon,$(image),$(image):$(LAGOON_VERSION))

# Clean all build touches, which will case make to rebuild the Docker Images (Layer caching is
# still active, so this is a very safe command)
clean:
	rm -rf build/*

# Show Lagoon Service Logs
logs:
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility logs --tail=10 -f $(service)

# Start all Lagoon Services
up:
ifeq ($(ARCH), darwin)
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d
else
	# once this docker issue is fixed we may be able to do away with this
	# linux-specific workaround: https://github.com/docker/cli/issues/2290
	KEYCLOAK_URL=$$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' bridge):8088 \
		IMAGE_REPO=$(CI_BUILD_TAG) \
		docker-compose -p $(CI_BUILD_TAG) --compatibility up -d
endif
	$(MAKE) wait-for-keycloak

down:
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility down -v --remove-orphans

# kill all containers containing the name "lagoon"
kill:
	docker ps --format "{{.Names}}" | grep lagoon | xargs -t -r -n1 docker rm -f -v

.PHONY: openshift
openshift:
	$(info the openshift command has been renamed to minishift)

# Start Local OpenShift Cluster within a docker machine with a given name, also check if the IP
# that has been assigned to the machine is not the default one and then replace the IP in the yaml files with it
minishift: local-dev/minishift/minishift
	$(info starting minishift $(MINISHIFT_VERSION) with name $(CI_BUILD_TAG))
ifeq ($(ARCH), darwin)
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) start --docker-opt "bip=192.168.89.1/24" --host-only-cidr "192.168.42.1/24" --cpus $(MINISHIFT_CPUS) --memory $(MINISHIFT_MEMORY) --disk-size $(MINISHIFT_DISK_SIZE) --vm-driver virtualbox --openshift-version="$(OPENSHIFT_VERSION)"
else
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) start --docker-opt "bip=192.168.89.1/24" --cpus $(MINISHIFT_CPUS) --memory $(MINISHIFT_MEMORY) --disk-size $(MINISHIFT_DISK_SIZE) --openshift-version="$(OPENSHIFT_VERSION)"
endif
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) openshift component add service-catalog
ifeq ($(ARCH), darwin)
	@OPENSHIFT_MACHINE_IP=$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip); \
	echo "replacing IP in local-dev/api-data/02-populate-api-data-openshift.gql and docker-compose.yaml with the IP '$$OPENSHIFT_MACHINE_IP'"; \
	sed -i '' -E "s/192.168\.[0-9]{1,3}\.([2-9]|[0-9]{2,3})/$${OPENSHIFT_MACHINE_IP}/g" local-dev/api-data/02-populate-api-data-openshift.gql docker-compose.yaml;
else
	@OPENSHIFT_MACHINE_IP=$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip); \
	echo "replacing IP in local-dev/api-data/02-populate-api-data-openshift.gql and docker-compose.yaml with the IP '$$OPENSHIFT_MACHINE_IP'"; \
	sed -i "s/192.168\.[0-9]\{1,3\}\.\([2-9]\|[0-9]\{2,3\}\)/$${OPENSHIFT_MACHINE_IP}/g" local-dev/api-data/02-populate-api-data-openshift.gql docker-compose.yaml;
endif
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ssh --  '/bin/sh -c "sudo sysctl -w vm.max_map_count=262144"'
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	oc login -u system:admin; \
	bash -c "echo '{\"apiVersion\":\"v1\",\"kind\":\"Service\",\"metadata\":{\"name\":\"docker-registry-external\"},\"spec\":{\"ports\":[{\"port\":5000,\"protocol\":\"TCP\",\"targetPort\":5000,\"nodePort\":30000}],\"selector\":{\"docker-registry\":\"default\"},\"sessionAffinity\":\"None\",\"type\":\"NodePort\"}}' | oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" create -n default -f -"; \
	oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" adm policy add-cluster-role-to-user cluster-admin system:anonymous; \
	oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" adm policy add-cluster-role-to-user cluster-admin developer;
	@echo "$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip)" > $@
	@echo "wait 60secs in order to give openshift time to setup it's registry"
	sleep 60
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	for i in {10..30}; do oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" patch pv pv00$${i} -p '{"spec":{"storageClassName":"bulk"}}'; done;
	$(MAKE) minishift/configure-lagoon-local push-docker-host-image

.PHONY: minishift/login-docker-registry
minishift/login-docker-registry: minishift
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	oc login --insecure-skip-tls-verify -u developer -p developer $$(cat minishift):8443; \
	oc whoami -t | docker login --username developer --password-stdin $$(cat minishift):30000

# Configures an openshift to use with Lagoon
.PHONY: openshift-lagoon-setup
openshift-lagoon-setup:
# Only use the minishift provided oc if we don't have one yet (allows system engineers to use their own oc)
	if ! which oc; then eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); fi; \
	oc -n default set env dc/router -e ROUTER_LOG_LEVEL=info -e ROUTER_SYSLOG_ADDRESS=router-logs.lagoon.svc:5141; \
	oc new-project lagoon; \
	oc adm pod-network make-projects-global lagoon; \
	oc -n lagoon create serviceaccount openshiftbuilddeploy; \
	oc -n lagoon policy add-role-to-user admin -z openshiftbuilddeploy; \
	oc -n lagoon create -f openshift-setup/clusterrole-openshiftbuilddeploy.yaml; \
	oc -n lagoon adm policy add-cluster-role-to-user openshiftbuilddeploy -z openshiftbuilddeploy; \
	oc -n lagoon create -f openshift-setup/priorityclasses.yaml; \
	oc -n lagoon create -f openshift-setup/shared-resource-viewer.yaml; \
	oc -n lagoon create -f openshift-setup/policybinding.yaml | oc -n lagoon create -f openshift-setup/rolebinding.yaml; \
	oc -n lagoon create serviceaccount docker-host; \
	oc -n lagoon adm policy add-scc-to-user privileged -z docker-host; \
	oc -n lagoon policy add-role-to-user edit -z docker-host; \
	oc -n lagoon adm policy add-cluster-role-to-user daemonset-admin -z lagoon-deployer; \
	oc -n lagoon create serviceaccount lagoon-deployer; \
	oc -n lagoon policy add-role-to-user edit -z lagoon-deployer; \
	oc -n lagoon create -f openshift-setup/clusterrole-daemonset-admin.yaml; \
	oc -n lagoon adm policy add-cluster-role-to-user daemonset-admin -z lagoon-deployer; \
	bash -c "oc process -n lagoon -f openshift-setup/docker-host.yaml | oc -n lagoon apply -f -"; \
	oc -n lagoon create -f openshift-setup/dbaas-roles.yaml; \
	oc -n dbaas-operator-system create -f openshift-setup/dbaas-operator.yaml; \
	oc -n lagoon create -f openshift-setup/dbaas-providers.yaml; \
	oc -n lagoon create -f openshift-setup/dioscuri-roles.yaml; \
	oc -n dioscuri-controller create -f openshift-setup/dioscuri-operator.yaml; \
	echo -e "\n\nAll Setup, use this token as described in the Lagoon Install Documentation:" \
	oc -n lagoon serviceaccounts get-token openshiftbuilddeploy


# This calls the regular openshift-lagoon-setup first, which configures our minishift like we configure a real openshift for lagoon.
# It then overwrites the docker-host deploymentconfig and cronjobs to use our own just-built docker-host images.
.PHONY: minishift/configure-lagoon-local
minishift/configure-lagoon-local: openshift-lagoon-setup
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	bash -c "oc process -n lagoon -p SERVICE_IMAGE=172.30.1.1:5000/lagoon/docker-host:latest -p REPOSITORY_TO_UPDATE=lagoon -f services/docker-host/docker-host.yaml | oc -n lagoon apply -f -"; \
	oc -n default set env dc/router -e ROUTER_LOG_LEVEL=info -e ROUTER_SYSLOG_ADDRESS=172.17.0.1:5140;

# Stop MiniShift
.PHONY: minishift/stop
minishift/stop: local-dev/minishift/minishift
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) delete --force
	rm -f minishift

# Stop All MiniShifts
.PHONY: minishift/stopall
minishift/stopall: local-dev/minishift/minishift
	for profile in $$(./local-dev/minishift/minishift profile list | awk '{ print $$2 }'); do ./local-dev/minishift/minishift --profile $$profile delete --force; done
	rm -f minishift

# Stop MiniShift, remove downloaded minishift
.PHONY: minishift/clean
minishift/clean: minishift/stop
	rm -rf ./local-dev/minishift/minishift

# Stop All Minishifts, remove downloaded minishift
.PHONY: openshift/cleanall
minishift/cleanall: minishift/stopall
	rm -rf ./local-dev/minishift/minishift

# Symlink the installed minishift client if the correct version is already
# installed, otherwise downloads it.
local-dev/minishift/minishift:
	@mkdir -p ./local-dev/minishift
ifeq ($(MINISHIFT_VERSION), $(shell minishift version 2>/dev/null | sed -E 's/^minishift v([0-9.]+).*/\1/'))
	$(info linking local minishift version $(MINISHIFT_VERSION))
	ln -s $(shell command -v minishift) ./local-dev/minishift/minishift
else
	$(info downloading minishift version $(MINISHIFT_VERSION) for $(ARCH))
	curl -L https://github.com/minishift/minishift/releases/download/v$(MINISHIFT_VERSION)/minishift-$(MINISHIFT_VERSION)-$(ARCH)-amd64.tgz | tar xzC local-dev/minishift --strip-components=1
endif

# Symlink the installed k3d client if the correct version is already
# installed, otherwise downloads it.
local-dev/k3d:
ifeq ($(K3D_VERSION), $(shell k3d version 2>/dev/null | grep k3d | sed -E 's/^k3d version v([0-9.]+).*/\1/'))
	$(info linking local k3d version $(K3D_VERSION))
	ln -s $(shell command -v k3d) ./local-dev/k3d
else
	$(info downloading k3d version $(K3D_VERSION) for $(ARCH))
	curl -Lo local-dev/k3d https://github.com/rancher/k3d/releases/download/v$(K3D_VERSION)/k3d-$(ARCH)-amd64
	chmod a+x local-dev/k3d
endif

# Symlink the installed kubectl client if the correct version is already
# installed, otherwise downloads it.
local-dev/kubectl:
ifeq ($(KUBECTL_VERSION), $(shell kubectl version --short --client 2>/dev/null | sed -E 's/Client Version: v([0-9.]+).*/\1/'))
	$(info linking local kubectl version $(KUBECTL_VERSION))
	ln -s $(shell command -v kubectl) ./local-dev/kubectl
else
	$(info downloading kubectl version $(KUBECTL_VERSION) for $(ARCH))
	curl -sSLo local-dev/kubectl https://storage.googleapis.com/kubernetes-release/release/$(KUBECTL_VERSION)/bin/$(ARCH)/amd64/kubectl
	chmod a+x local-dev/kubectl
endif

# Symlink the installed helm client if the correct version is already
# installed, otherwise downloads it.
local-dev/helm:
ifeq ($(HELM_VERSION), $(shell helm version --short --client 2>/dev/null | sed -nE 's/v([0-9.]+).*/\1/p'))
	$(info linking local helm version $(HELM_VERSION))
	ln -s $(shell command -v helm) ./local-dev/helm
else
	$(info downloading helm version $(HELM_VERSION) for $(ARCH))
	curl -sSL https://get.helm.sh/helm-$(HELM_VERSION)-$(ARCH)-amd64.tar.gz | tar -xzC local-dev --strip-components=1 $(ARCH)-amd64/helm
	chmod a+x local-dev/helm
endif

ifeq ($(DOCKER_DRIVER), btrfs)
# https://github.com/rancher/k3d/blob/main/docs/faq/faq.md
K3D_BTRFS_VOLUME := --volume /dev/mapper:/dev/mapper
else
K3D_BTRFS_VOLUME :=
endif

k3d: local-dev/k3d local-dev/kubectl local-dev/helm build/docker-host
	$(MAKE) local-registry-up
	$(MAKE) broker-up
	$(info starting k3d with name $(K3D_NAME))
	$(info Creating Loopback Interface for docker gateway if it does not exist, this might ask for sudo)
ifeq ($(ARCH), darwin)
	if ! ifconfig lo0 | grep $$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}') -q; then sudo ifconfig lo0 alias $$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}'); fi
endif
	./local-dev/k3d create --wait 0 --publish 18080:80 \
		--publish 18443:443 \
		--api-port 16643 \
		--name $(K3D_NAME) \
		--image docker.io/rancher/k3s:$(K3S_VERSION) \
		--volume $$PWD/local-dev/k3d-registries.yaml:/etc/rancher/k3s/registries.yaml \
		$(K3D_BTRFS_VOLUME) \
		-x --no-deploy=traefik
	echo "$(K3D_NAME)" > $@
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')"; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" apply -f $$PWD/local-dev/k3d-storageclass-bulk.yaml; \
	docker tag $(CI_BUILD_TAG)/docker-host localhost:5000/lagoon/docker-host; \
	docker push localhost:5000/lagoon/docker-host; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace nginx-ingress; \
	local-dev/helm/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add stable https://charts.helm.sh/stable; \
	local-dev/helm/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n nginx-ingress nginx stable/nginx-ingress; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace k8up; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add appuio https://charts.appuio.ch; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n k8up k8up appuio/k8up; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace dioscuri; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add dioscuri https://raw.githubusercontent.com/amazeeio/dioscuri/main/charts ; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n dioscuri dioscuri dioscuri/dioscuri ; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace dbaas-operator; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add dbaas-operator https://raw.githubusercontent.com/amazeeio/dbaas-operator/main/charts ; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n dbaas-operator dbaas-operator dbaas-operator/dbaas-operator ; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n dbaas-operator mariadbprovider dbaas-operator/mariadbprovider -f local-dev/helm-values-mariadbprovider.yml ; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n dbaas-operator mongodbprovider dbaas-operator/mongodbprovider -f local-dev/helm-values-mongodbprovider.yml ; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace harbor; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add harbor https://helm.goharbor.io ; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n harbor harbor harbor/harbor -f local-dev/helm-values-harbor.yml ; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace lagoon-builddeploy; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add lagoon-builddeploy https://raw.githubusercontent.com/amazeeio/lagoon-kbd/main/charts ; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n lagoon-builddeploy lagoon-builddeploy lagoon-builddeploy/lagoon-builddeploy \
		--set vars.lagoonTargetName=ci-local-control-k8s \
		--set vars.rabbitPassword=guest \
		--set vars.rabbitUsername=guest \
		--set vars.rabbitHostname=172.17.0.1:5672; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' create namespace lagoon; \
	local-dev/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' repo add lagoon https://uselagoon.github.io/lagoon-charts/; \
	local-dev/helm/helm --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --kube-context='$(K3D_NAME)' upgrade --install -n lagoon lagoon-remote lagoon/lagoon-remote \
		--set dioscuri.enabled=false \
		--set dockerHost.image.repository=172.17.0.1:5000/lagoon/docker-host \
		--set dockerHost.image.tag=latest \
		--set dockerHost.registry=172.17.0.1:5000; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon rollout status deployment lagoon-remote-docker-host -w;
ifeq ($(ARCH), darwin)
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')"; \
	KUBERNETESBUILDDEPLOY_TOKEN=$$(local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon describe secret $$(local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon get secret | grep lagoon-remote-kubernetes-build-deploy-token | awk '{print $$1}') | grep token: | awk '{print $$2}' | tr -d '\n'); \
	sed -i '' -e "s/\".*\" # make-kubernetes-token/\"$${KUBERNETESBUILDDEPLOY_TOKEN}\" # make-kubernetes-token/g" local-dev/api-data/03-populate-api-data-kubernetes.gql; \
	DOCKER_IP="$$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}')"; \
	sed -i '' -e "s/172\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/$${DOCKER_IP}/g" local-dev/api-data/03-populate-api-data-kubernetes.gql docker-compose.yaml;
else
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')"; \
	KUBERNETESBUILDDEPLOY_TOKEN=$$(local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon describe secret $$(local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon get secret | grep lagoon-remote-kubernetes-build-deploy-token | awk '{print $$1}') | grep token: | awk '{print $$2}' | tr -d '\n'); \
	sed -i "s/\".*\" # make-kubernetes-token/\"$${KUBERNETESBUILDDEPLOY_TOKEN}\" # make-kubernetes-token/g" local-dev/api-data/03-populate-api-data-kubernetes.gql; \
	DOCKER_IP="$$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}')"; \
	sed -i "s/172\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/$${DOCKER_IP}/g" local-dev/api-data/03-populate-api-data-kubernetes.gql docker-compose.yaml;
endif
	$(MAKE) push-kubectl-build-deploy-dind

.PHONY: push-kubectl-build-deploy-dind
push-kubectl-build-deploy-dind: build/kubectl-build-deploy-dind
	docker tag $(CI_BUILD_TAG)/kubectl-build-deploy-dind localhost:5000/lagoon/kubectl-build-deploy-dind
	docker push localhost:5000/lagoon/kubectl-build-deploy-dind

.PHONY: rebuild-push-kubectl-build-deploy-dind
rebuild-push-kubectl-build-deploy-dind:
	rm -rf build/kubectl-build-deploy-dind
	$(MAKE) push-kubectl-build-deploy-dind

k3d-kubeconfig:
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name=$$(cat k3d))"

k3d-dashboard:
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name=$$(cat k3d))"; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/00_dashboard-namespace.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/01_dashboard-serviceaccount.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/02_dashboard-service.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/03_dashboard-secret.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/04_dashboard-configmap.yaml; \
	echo '{"apiVersion": "rbac.authorization.k8s.io/v1","kind": "ClusterRoleBinding","metadata": {"name": "kubernetes-dashboard","namespace": "kubernetes-dashboard"},"roleRef": {"apiGroup": "rbac.authorization.k8s.io","kind": "ClusterRole","name": "cluster-admin"},"subjects": [{"kind": "ServiceAccount","name": "kubernetes-dashboard","namespace": "kubernetes-dashboard"}]}' | local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n kubernetes-dashboard apply -f - ; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/06_dashboard-deployment.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/07_scraper-service.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/08_scraper-deployment.yaml; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n kubernetes-dashboard patch deployment kubernetes-dashboard --patch '{"spec": {"template": {"spec": {"containers": [{"name": "kubernetes-dashboard","args": ["--auto-generate-certificates","--namespace=kubernetes-dashboard","--enable-skip-login"]}]}}}}'; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n kubernetes-dashboard rollout status deployment kubernetes-dashboard -w; \
	open http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ ; \
	local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' proxy

k8s-dashboard:
	kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended.yaml; \
	kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n kubernetes-dashboard rollout status deployment kubernetes-dashboard -w; \
	echo -e "\nUse this token:"; \
	kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon describe secret $$(local-dev/kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' -n lagoon get secret | grep kubernetes-build-deploy | awk '{print $$1}') | grep token: | awk '{print $$2}'; \
	open http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ ; \
	kubectl --kubeconfig="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')" --context='$(K3D_NAME)' proxy

# Stop k3d
.PHONY: k3d/stop
k3d/stop: local-dev/k3d
	./local-dev/k3d delete --name=$$(cat k3d) || true
	rm -f k3d

# Stop All k3d
.PHONY: k3d/stopall
k3d/stopall: local-dev/k3d
	./local-dev/k3d delete --all || true
	rm -f k3d

# Stop k3d, remove downloaded k3d
.PHONY: k3d/clean
k3d/clean: k3d/stop
	rm -rf ./local-dev/k3d

# Stop All k3d, remove downloaded k3d
.PHONY: k3d/cleanall
k3d/cleanall: k3d/stopall
	rm -rf ./local-dev/k3d

# Configures an openshift to use with Lagoon
.PHONY: kubernetes-lagoon-setup
kubernetes-lagoon-setup:
	kubectl create namespace lagoon; \
	local-dev/helm repo add lagoon https://uselagoon.github.io/lagoon-charts/; \
	local-dev/helm upgrade --install -n lagoon lagoon-remote lagoon/lagoon-remote; \
	echo -e "\n\nAll Setup, use this token as described in the Lagoon Install Documentation:";
	$(MAKE) kubernetes-get-kubernetesbuilddeploy-token

.PHONY: kubernetes-get-kubernetesbuilddeploy-token
kubernetes-get-kubernetesbuilddeploy-token:
	kubectl -n lagoon describe secret $$(kubectl -n lagoon get secret | grep kubernetes-build-deploy | awk '{print $$1}') | grep token: | awk '{print $$2}'

.PHONY: rebuild-push-oc-build-deploy-dind
rebuild-push-oc-build-deploy-dind:
	rm -rf build/oc-build-deploy-dind
	$(MAKE) minishift/login-docker-registry build/oc-build-deploy-dind [push-minishift]-oc-build-deploy-dind



.PHONY: ui-development
ui-development: build/api build/api-db build/local-api-data-watcher-pusher build/ui build/keycloak build/keycloak-db build/broker-single build/api-redis
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d api api-db local-api-data-watcher-pusher ui keycloak keycloak-db broker api-redis

.PHONY: api-development
api-development: build/api build/api-db build/local-api-data-watcher-pusher build/keycloak build/keycloak-db build/broker-single build/api-redis
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) --compatibility up -d api api-db local-api-data-watcher-pusher keycloak keycloak-db broker api-redis

## CI targets

KIND_VERSION = v0.11.1
GOJQ_VERSION = v0.12.3
CHART_TESTING_VERSION = v3.4.0
KIND_IMAGE = kindest/node:v1.21.1@sha256:69860bda5563ac81e3c0057d654b5253219618a22ec3a346306239bba8cfa1a6
TESTS = [features-kubernetes-3]
CHARTS_TREEISH = main

local-dev/kind:
ifeq ($(KIND_VERSION), $(shell kind version 2>/dev/null | sed -nE 's/kind (v[0-9.]+).*/\1/p'))
	$(info linking local kind version $(KIND_VERSION))
	ln -s $(shell command -v kind) ./local-dev/kind
else
	$(info downloading kind version $(KIND_VERSION) for $(ARCH))
	curl -sSLo local-dev/kind https://github.com/kubernetes-sigs/kind/releases/download/$(KIND_VERSION)/kind-$(ARCH)-amd64
	chmod a+x local-dev/kind
endif

local-dev/jq:
ifeq ($(GOJQ_VERSION), $(shell jq -v 2>/dev/null | sed -nE 's/gojq ([0-9.]+).*/v\1/p'))
	$(info linking local jq version $(KIND_VERSION))
	ln -s $(shell command -v jq) ./local-dev/jq
else
	$(info downloading gojq version $(GOJQ_VERSION) for $(ARCH))
ifeq ($(ARCH), darwin)
	TMPDIR=$$(mktemp -d) \
		&& curl -sSL https://github.com/itchyny/gojq/releases/download/$(GOJQ_VERSION)/gojq_$(GOJQ_VERSION)_$(ARCH)_amd64.zip -o $$TMPDIR/gojq.zip \
		&& (cd $$TMPDIR && unzip gojq.zip) && cp $$TMPDIR/gojq_$(GOJQ_VERSION)_$(ARCH)_amd64/gojq ./local-dev/jq && rm -rf $$TMPDIR
else
	curl -sSL https://github.com/itchyny/gojq/releases/download/$(GOJQ_VERSION)/gojq_$(GOJQ_VERSION)_$(ARCH)_amd64.tar.gz | tar -xzC local-dev --strip-components=1 gojq_$(GOJQ_VERSION)_$(ARCH)_amd64/gojq
	mv ./local-dev/{go,}jq
endif
	chmod a+x local-dev/jq
endif

.PHONY: helm/repos
helm/repos: local-dev/helm
	# install repo dependencies required by the charts
	./local-dev/helm repo add harbor https://helm.goharbor.io
	./local-dev/helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	./local-dev/helm repo add stable https://charts.helm.sh/stable
	./local-dev/helm repo add bitnami https://charts.bitnami.com/bitnami
	./local-dev/helm repo add amazeeio https://amazeeio.github.io/charts/
	./local-dev/helm repo add lagoon https://uselagoon.github.io/lagoon-charts/
	./local-dev/helm repo update

# stand up a kind cluster configured appropriately for lagoon testing
.PHONY: kind/cluster
kind/cluster: local-dev/kind
	./local-dev/kind get clusters | grep -q "$(CI_BUILD_TAG)" && exit; \
		docker network create kind || true \
		&& export KUBECONFIG=$$(mktemp) \
		KINDCONFIG=$$(mktemp ./kindconfig.XXX) \
		KIND_NODE_IP=$$(docker run --rm --network kind alpine ip -o addr show eth0 | sed -nE 's/.* ([0-9.]{7,})\/.*/\1/p') \
		&& chmod 644 $$KUBECONFIG \
		&& curl -sSLo $$KINDCONFIG.tpl https://raw.githubusercontent.com/uselagoon/lagoon-charts/$(CHARTS_TREEISH)/test-suite.kind-config.yaml.tpl \
		&& envsubst < $$KINDCONFIG.tpl > $$KINDCONFIG \
		&& echo '  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]'                >> $$KINDCONFIG \
		&& echo '    endpoint = ["https://imagecache.amazeeio.cloud", "https://index.docker.io/v1/"]' >> $$KINDCONFIG \
		&& echo 'nodes:'                                                                              >> $$KINDCONFIG \
		&& echo '- role: control-plane'                                                               >> $$KINDCONFIG \
		&& echo '  image: $(KIND_IMAGE)'                                                              >> $$KINDCONFIG \
		&& echo '  extraMounts:'                                                                      >> $$KINDCONFIG \
		&& echo '  - containerPath: /var/lib/kubelet/config.json'                                     >> $$KINDCONFIG \
		&& echo '    hostPath: $(HOME)/.docker/config.json'                                           >> $$KINDCONFIG \
		&& echo '  - containerPath: /lagoon/services'                                                 >> $$KINDCONFIG \
		&& echo '    hostPath: ./services'                                                            >> $$KINDCONFIG \
		&& echo '    readOnly: false'                                                                 >> $$KINDCONFIG \
		&& echo '  - containerPath: /lagoon/node-packages'                                            >> $$KINDCONFIG \
		&& echo '    hostPath: ./node-packages'                                                       >> $$KINDCONFIG \
		&& echo '    readOnly: false'                                                                 >> $$KINDCONFIG \
		&& KIND_CLUSTER_NAME="$(CI_BUILD_TAG)" ./local-dev/kind create cluster --wait=120s --config=$$KINDCONFIG \
		&& cp $$KUBECONFIG "kubeconfig.kind.$(CI_BUILD_TAG)" \
		&& echo -e 'Interact with the cluster during the test run in Jenkins like so:\n' \
		&& echo "export KUBECONFIG=\$$(mktemp) && scp $$NODE_NAME:$$KUBECONFIG \$$KUBECONFIG && KIND_PORT=\$$(sed -nE 's/.+server:.+:([0-9]+)/\1/p' \$$KUBECONFIG) && ssh -fNL \$$KIND_PORT:127.0.0.1:\$$KIND_PORT $$NODE_NAME" \
		&& echo -e '\nOr running locally:\n' \
		&& echo -e './local-dev/kind export kubeconfig --name "$(CI_BUILD_TAG)"\n' \
		&& echo -e 'kubectl ...\n'
ifeq ($(ARCH), darwin)
	export KUBECONFIG="$$(pwd)/kubeconfig.kind.$(CI_BUILD_TAG)" && \
	if ! ifconfig lo0 | grep $$(./local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}') -q; then sudo ifconfig lo0 alias $$(./local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'); fi
	docker rm --force $(CI_BUILD_TAG)-kind-proxy-32080 || true
	docker run -d --name $(CI_BUILD_TAG)-kind-proxy-32080 \
      --publish 32080:32080 \
      --link $(CI_BUILD_TAG)-control-plane:target --network kind \
      alpine/socat -dd \
      tcp-listen:32080,fork,reuseaddr tcp-connect:target:32080
endif

KIND_SERVICES = api api-db api-redis auth-server broker controllerhandler docker-host drush-alias keycloak keycloak-db webhook-handler webhooks2tasks kubectl-build-deploy-dind local-api-data-watcher-pusher local-git ssh tests ui
KIND_TESTS = local-api-data-watcher-pusher local-git tests
KIND_TOOLS = kind helm kubectl jq

# install lagoon charts and run lagoon test suites in a kind cluster
.PHONY: kind/test
kind/test: kind/cluster helm/repos $(addprefix local-dev/,$(KIND_TOOLS)) $(addprefix build/,$(KIND_SERVICES))
	export CHARTSDIR=$$(mktemp -d ./lagoon-charts.XXX) \
		&& ln -sfn "$$CHARTSDIR" lagoon-charts.kind.lagoon \
		&& git clone https://github.com/uselagoon/lagoon-charts.git "$$CHARTSDIR" \
		&& cd "$$CHARTSDIR" \
		&& git checkout $(CHARTS_TREEISH) \
		&& export KUBECONFIG="$$(realpath ../kubeconfig.kind.$(CI_BUILD_TAG))" \
		&& export IMAGE_REGISTRY="registry.$$(../local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}').nip.io:32080/library" \
		&& $(MAKE) install-registry HELM=$$(realpath ../local-dev/helm) KUBECTL=$$(realpath ../local-dev/kubectl) \
		&& cd .. && $(MAKE) kind/push-images && cd "$$CHARTSDIR" \
		&& $(MAKE) fill-test-ci-values TESTS=$(TESTS) IMAGE_TAG=$(SAFE_BRANCH_NAME) \
			HELM=$$(realpath ../local-dev/helm) KUBECTL=$$(realpath ../local-dev/kubectl) \
			JQ=$$(realpath ../local-dev/jq) \
			OVERRIDE_BUILD_DEPLOY_DIND_IMAGE=$$IMAGE_REGISTRY/kubectl-build-deploy-dind:$(SAFE_BRANCH_NAME) \
			IMAGE_REGISTRY=$$IMAGE_REGISTRY \
			SKIP_INSTALL_REGISTRY=true \
		&& docker run --rm --network host --name ct-$(CI_BUILD_TAG) \
			--volume "$$(pwd)/test-suite-run.ct.yaml:/etc/ct/ct.yaml" \
			--volume "$$(pwd):/workdir" \
			--volume "$$(realpath ../kubeconfig.kind.$(CI_BUILD_TAG)):/root/.kube/config" \
			--workdir /workdir \
			"quay.io/helmpack/chart-testing:$(CHART_TESTING_VERSION)" \
			ct install

LOCAL_DEV_SERVICES = api auth-server controllerhandler logs2email logs2microsoftteams logs2rocketchat logs2slack logs2webhook ui webhook-handler webhooks2tasks

# kind/local-dev-patch will build the services in LOCAL_DEV_SERVICES on your machine, and then use kubectl patch to mount the folders into Kubernetes
# the deployments should be restarted to trigger any updated code changes
# `kubectl rollout undo deployment` can be used to rollback a deployment to before the annotated patch
# ensure that the correct version of Node to build the services is set on your machine
.PHONY: kind/local-dev-patch
kind/local-dev-patch:
	export KUBECONFIG="$$(pwd)/kubeconfig.kind.$(CI_BUILD_TAG)" && \
		export IMAGE_REGISTRY="registry.$$(./local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}').nip.io:32080/library" \
		&& for image in $(LOCAL_DEV_SERVICES); do \
			echo "building $$image" \
			&& cd services/$$image && yarn install && yarn build && cd ../..; \
		done \
		&& for image in $(LOCAL_DEV_SERVICES); do \
			echo "patching lagoon-core-$$image" \
			&& ./local-dev/kubectl --namespace lagoon patch deployment lagoon-core-$$image --patch-file ./local-dev/kubectl-patches/$$image.yaml; \
		done

## Use local-dev-logging to deploy an Elasticsearch/Kibana cluster into docker compose and forward
## container logs to it
.PHONY: kind/local-dev-logging
kind/local-dev-logging:
	export KUBECONFIG="$$(pwd)/kubeconfig.kind.$(CI_BUILD_TAG)" \
		&& docker-compose -f local-dev/odfe-docker-compose.yml -p odfe up -d \
		&& ./local-dev/helm upgrade --install --create-namespace \
			--namespace lagoon-logs-concentrator \
			--wait --timeout 15m \
			--values ./local-dev/lagoon-logs-concentrator.values.yaml \
			lagoon-logs-concentrator \
			./lagoon-charts.kind.lagoon/charts/lagoon-logs-concentrator \
		&& ./local-dev/helm dependency update ./lagoon-charts.kind.lagoon/charts/lagoon-logging \
		&& ./local-dev/helm upgrade --install --create-namespace --namespace lagoon-logging \
			--wait --timeout 15m \
			--values ./local-dev/lagoon-logging.values.yaml \
			lagoon-logging \
			./lagoon-charts.kind.lagoon/charts/lagoon-logging \
		&& echo -e '\n\nInteract with the OpenDistro cluster at http://0.0.0.0:5601 using the default `admin/admin` credentials\n' \
		&& echo -e 'You will need to create a default index at http://0.0.0.0:5601/app/management/kibana/indexPatterns/create \n' \
		&& echo -e 'with a default `container-logs-*` pattern'

# kind/dev can only be run once a cluster is up and running (run kind/test first) - it doesn't rebuild the cluster at all, just pushes the built images
# into the image registry and reinstalls the lagoon-core helm chart.
.PHONY: kind/dev
kind/dev: $(addprefix build/,$(KIND_SERVICES))
	export KUBECONFIG="$$(realpath ./kubeconfig.kind.$(CI_BUILD_TAG))" \
		&& export IMAGE_REGISTRY="registry.$$(./local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}').nip.io:32080/library" \
		&& $(MAKE) kind/push-images && cd lagoon-charts.kind.lagoon \
		&& $(MAKE) install-lagoon-core IMAGE_TAG=$(SAFE_BRANCH_NAME) \
			HELM=$$(realpath ../local-dev/helm) KUBECTL=$$(realpath ../local-dev/kubectl) \
			JQ=$$(realpath ../local-dev/jq) \
			OVERRIDE_BUILD_DEPLOY_DIND_IMAGE=$$IMAGE_REGISTRY/kubectl-build-deploy-dind:$(SAFE_BRANCH_NAME) \
			IMAGE_REGISTRY=$$IMAGE_REGISTRY

# kind/push-images pushes locally build images into the kind cluster registry.
IMAGES = $(KIND_SERVICES) $(LOCAL_DEV_SERVICES)
.PHONY: kind/push-images
kind/push-images:
	export KUBECONFIG="$$(pwd)/kubeconfig.kind.$(CI_BUILD_TAG)" && \
		export IMAGE_REGISTRY="registry.$$(./local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}').nip.io:32080/library" \
		&& docker login -u admin -p Harbor12345 $$IMAGE_REGISTRY \
		&& for image in $(IMAGES); do \
			docker tag $(CI_BUILD_TAG)/$$image $$IMAGE_REGISTRY/$$image:$(SAFE_BRANCH_NAME) \
			&& docker push $$IMAGE_REGISTRY/$$image:$(SAFE_BRANCH_NAME); \
		done

# Use kind/get-admin-creds to retrieve the admin JWT, Lagoon admin password, and the password for the lagoonadmin user.
# These credentials are re-created on every re-install of Lagoon Core.
.PHONY: kind/get-admin-creds
kind/get-admin-creds:
	export KUBECONFIG="$$(realpath ./kubeconfig.kind.$(CI_BUILD_TAG))" \
		&& cd lagoon-charts.kind.lagoon \
		&& $(MAKE) get-admin-creds

# Use kind/port-forwards to create local ports for the UI (6060), API (7070) and Keycloak (8080). These ports will always
# log in the foreground, so perform this command in a separate window/terminal.
.PHONY: kind/port-forwards
kind/port-forwards:
	export KUBECONFIG="$$(realpath ./kubeconfig.kind.$(CI_BUILD_TAG))" \
		&& cd lagoon-charts.kind.lagoon \
		&& $(MAKE) port-forwards

# kind/retest re-runs tests in the local cluster. It preserves the last build
# lagoon core & remote setup, reducing rebuild time.
.PHONY: kind/retest
kind/retest:
	export KUBECONFIG="$$(pwd)/kubeconfig.kind.$(CI_BUILD_TAG)" \
		&& export IMAGE_REGISTRY="registry.$$(./local-dev/kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}').nip.io:32080/library" \
		&& cd lagoon-charts.kind.lagoon \
		&& $(MAKE) fill-test-ci-values TESTS=$(TESTS) IMAGE_TAG=$(SAFE_BRANCH_NAME) \
			HELM=$$(realpath ../local-dev/helm) KUBECTL=$$(realpath ../local-dev/kubectl) \
			JQ=$$(realpath ../local-dev/jq) \
			OVERRIDE_BUILD_DEPLOY_DIND_IMAGE=$$IMAGE_REGISTRY/kubectl-build-deploy-dind:$(SAFE_BRANCH_NAME) \
			IMAGE_REGISTRY=$$IMAGE_REGISTRY \
			SKIP_ALL_DEPS=true \
		&& docker run --rm --network host --name ct-$(CI_BUILD_TAG) \
			--volume "$$(pwd)/test-suite-run.ct.yaml:/etc/ct/ct.yaml" \
			--volume "$$(pwd):/workdir" \
			--volume "$$(realpath ../kubeconfig.kind.$(CI_BUILD_TAG)):/root/.kube/config" \
			--workdir /workdir \
			"quay.io/helmpack/chart-testing:$(CHART_TESTING_VERSION)" \
			ct install

.PHONY: kind/clean
kind/clean: local-dev/kind
	KIND_CLUSTER_NAME="$(CI_BUILD_TAG)" ./local-dev/kind delete cluster
ifeq ($(ARCH), darwin)
	docker rm --force $(CI_BUILD_TAG)-kind-proxy-32080
endif
