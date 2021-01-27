#!/bin/bash

function outputToYaml() {
  set +x
  IFS=''
  while read data; do
    echo "$data" >> /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml;
  done;
  # Inject YAML document separator
  echo "---" >> /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml;
  set -x
}

function cronScheduleMoreOftenThanXMinutes() {
  # Takes a unexpanded cron schedule, returns 0 if it's more often than NATIVE_CRON_POD_MINIMUM_FREQUENCY minutes
  # NATIVE_CRON_POD_MINIMUM_FREQUENCY defaults to 15 minutes
  MINUTE=$(echo $1 | (read -a ARRAY; echo ${ARRAY[0]}) )
  if [[ $MINUTE =~ ^(M|H|\*)\/([0-5]?[0-9])$ ]]; then
    # Match found for M/xx, H/xx or */xx
    # Check if xx is smaller than x, which means this cronjob runs more often than every NATIVE_CRON_POD_MINIMUM_FREQUENCY minutes.
    STEP=${BASH_REMATCH[2]}
    if [ $STEP -lt $NATIVE_CRON_POD_MINIMUM_FREQUENCY ]; then
      return 0
    else
      return 1
    fi
  elif [[ $MINUTE =~ ^\*$ ]]; then
    # We are running every minute
    return 0
  else
    # all other cases are more often than NATIVE_CRON_POD_MINIMUM_FREQUENCY minutes
    return 1
  fi
}

##############################################
### PREPARATION
##############################################

# Load path of docker-compose that should be used
set +x # reduce noise in build logs
DOCKER_COMPOSE_YAML=($(cat .lagoon.yml | shyaml get-value docker-compose-yaml))

DEPLOY_TYPE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.deploy-type default)

# Load all Services that are defined
COMPOSE_SERVICES=($(cat $DOCKER_COMPOSE_YAML | shyaml keys services))

# Default shared mariadb service broker
MARIADB_SHARED_DEFAULT_CLASS="lagoon-dbaas-mariadb-apb"
MONGODB_SHARED_DEFAULT_CLASS="lagoon-maas-mongodb-apb"

# Figure out which services should we handle
SERVICE_TYPES=()
IMAGES=()
NATIVE_CRONJOB_CLEANUP_ARRAY=()
SERVICEBROKERS=()
declare -A MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME
declare -A MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE
declare -A MAP_SERVICE_NAME_TO_IMAGENAME
declare -A MAP_SERVICE_NAME_TO_SERVICEBROKER_CLASS
declare -A MAP_SERVICE_NAME_TO_SERVICEBROKER_PLAN
declare -A MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT
declare -A IMAGES_PULL
declare -A IMAGES_BUILD
set -x

set +x # reduce noise in build logs
# Allow the servicetype be overridden by the lagoon API
# This accepts colon separated values like so `SERVICE_NAME:SERVICE_TYPE_OVERRIDE`, and multiple overrides
# separated by commas
# Example 1: mariadb:mariadb-dbaas < tells any docker-compose services named mariadb to use the mariadb-dbaas service type
# Example 2: mariadb:mariadb-dbaas,nginx:nginx-persistent
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_SERVICE_TYPES=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_SERVICE_TYPES") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_SERVICE_TYPES=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_SERVICE_TYPES") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_SERVICE_TYPES ]; then
    LAGOON_SERVICE_TYPES=$TEMP_LAGOON_SERVICE_TYPES
  fi
fi
# Allow the dbaas environment type to be overridden by the lagoon API
# This accepts colon separated values like so `SERVICE_NAME:DBAAS_ENVIRONMENT_TYPE`, and multiple overrides
# separated by commas
# Example 1: mariadb:production < tells any docker-compose services named mariadb to use the production dbaas environment type
# Example 2: mariadb:production,mariadb-test:development
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_DBAAS_ENVIRONMENT_TYPES=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_DBAAS_ENVIRONMENT_TYPES") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_DBAAS_ENVIRONMENT_TYPES=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_DBAAS_ENVIRONMENT_TYPES") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_DBAAS_ENVIRONMENT_TYPES ]; then
    LAGOON_DBAAS_ENVIRONMENT_TYPES=$TEMP_LAGOON_DBAAS_ENVIRONMENT_TYPES
  fi
fi
set -x

for COMPOSE_SERVICE in "${COMPOSE_SERVICES[@]}"
do
  # The name of the service can be overridden, if not we use the actual servicename
  SERVICE_NAME=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.name default)
  if [ "$SERVICE_NAME" == "default" ]; then
    SERVICE_NAME=$COMPOSE_SERVICE
  fi

  # Load the servicetype. If it's "none" we will not care about this service at all
  SERVICE_TYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.type custom)

  # Allow the servicetype to be overriden by environment in .lagoon.yml
  ENVIRONMENT_SERVICE_TYPE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.types.$SERVICE_NAME false)
  if [ ! $ENVIRONMENT_SERVICE_TYPE_OVERRIDE == "false" ]; then
    SERVICE_TYPE=$ENVIRONMENT_SERVICE_TYPE_OVERRIDE
  fi

  if [ ! -z "$LAGOON_SERVICE_TYPES" ]; then
    IFS=',' read -ra LAGOON_SERVICE_TYPES_SPLIT <<< "$LAGOON_SERVICE_TYPES"
    for LAGOON_SERVICE_TYPE in "${LAGOON_SERVICE_TYPES_SPLIT[@]}"
    do
      IFS=':' read -ra LAGOON_SERVICE_TYPE_SPLIT <<< "$LAGOON_SERVICE_TYPE"
      if [ "${LAGOON_SERVICE_TYPE_SPLIT[0]}" == "$SERVICE_NAME" ]; then
        SERVICE_TYPE=${LAGOON_SERVICE_TYPE_SPLIT[1]}
      fi
    done
  fi

  # "mariadb" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - mariadb-single (a single mariadb pod)
  # - mariadb-shared (use a mariadb shared service broker)
  if [ "$SERVICE_TYPE" == "mariadb" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # mariadb-single deployed (probably from the past where there was no mariadb-shared yet) and use that one
    if oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="mariadb-single"
    # check if an existing mariadb service instance already exists
    elif oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get serviceinstance "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="mariadb-shared"
    # check if we can use the dbaas operator
    elif oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get mariadbconsumer.v1.mariadb.amazee.io &> /dev/null; then
      SERVICE_TYPE="mariadb-dbaas"
    # check if this cluster supports the default one, if not we assume that this cluster is not capable of shared mariadbs and we use a mariadb-single
    elif svcat --scope cluster get class $MARIADB_SHARED_DEFAULT_CLASS > /dev/null; then
      SERVICE_TYPE="mariadb-shared"
    else
      SERVICE_TYPE="mariadb-single"
    fi

  fi

  ## check if the .lagoon.yml overwrites the environment to use
  if [[ "$SERVICE_TYPE" == "mariadb-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.$SERVICE_TYPE\\.environment "${ENVIRONMENT_TYPE}")

    # Allow the dbaas shared servicebroker plan to be overriden by environment in .lagoon.yml
    ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH}.overrides.$SERVICE_NAME.$SERVICE_TYPE\\.environment false)
    if [ ! $DBAAS_ENVIRONMENT_OVERRIDE == "false" ]; then
      DBAAS_ENVIRONMENT=$ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE
    fi

    # If we have a dbaas environment type override in the api, consume it here
    if [ ! -z "$LAGOON_DBAAS_ENVIRONMENT_TYPES" ]; then
      IFS=',' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPES"
      for LAGOON_DBAAS_ENVIRONMENT_TYPE in "${LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT[@]}"
      do
        IFS=':' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPE"
        if [ "${LAGOON_DBAAS_ENVIRONMENT_TYPE[0]}" == "$SERVICE_NAME" ]; then
          DBAAS_ENVIRONMENT_TYPE=${LAGOON_DBAAS_ENVIRONMENT_TYPE[1]}
        fi
      done
    fi

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="$DBAAS_ENVIRONMENT"
  fi

  if [ "$SERVICE_TYPE" == "mariadb-shared" ]; then
    # Load a possible defined mariadb-shared
    MARIADB_SHARED_CLASS=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.mariadb-shared\\.class "${MARIADB_SHARED_DEFAULT_CLASS}")

    # Allow the mariadb shared servicebroker to be overriden by environment in .lagoon.yml
    ENVIRONMENT_MARIADB_SHARED_CLASS_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH}.overrides.$SERVICE_NAME.mariadb-shared\\.class false)
    if [ ! $ENVIRONMENT_MARIADB_SHARED_CLASS_OVERRIDE == "false" ]; then
      MARIADB_SHARED_CLASS=$ENVIRONMENT_MARIADB_SHARED_CLASS_OVERRIDE
    fi

    # check if the defined service broker class exists
    if svcat --scope cluster get class $MARIADB_SHARED_CLASS > /dev/null; then
      SERVICE_TYPE="mariadb-shared"
      MAP_SERVICE_NAME_TO_SERVICEBROKER_CLASS["${SERVICE_NAME}"]="${MARIADB_SHARED_CLASS}"
    else
      echo "defined mariadb-shared service broker class '$MARIADB_SHARED_CLASS' for service '$SERVICE_NAME' not found in cluster";
      exit 1
    fi

    # Default plan is the enviroment type
    MARIADB_SHARED_PLAN=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.mariadb-shared\\.plan "${ENVIRONMENT_TYPE}")

    # Allow the mariadb shared servicebroker plan to be overriden by environment in .lagoon.yml
    ENVIRONMENT_MARIADB_SHARED_PLAN_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH}.overrides.$SERVICE_NAME.mariadb-shared\\.plan false)
    if [ ! $MARIADB_SHARED_PLAN_OVERRIDE == "false" ]; then
      MARIADB_SHARED_PLAN=$ENVIRONMENT_MARIADB_SHARED_PLAN_OVERRIDE
    fi

    # Check if the defined service broker plan  exists
    if svcat --scope cluster get plan --class "${MARIADB_SHARED_CLASS}" "${MARIADB_SHARED_PLAN}" > /dev/null; then
        MAP_SERVICE_NAME_TO_SERVICEBROKER_PLAN["${SERVICE_NAME}"]="${MARIADB_SHARED_PLAN}"
    else
        echo "defined service broker plan '${MARIADB_SHARED_PLAN}' for service '$SERVICE_NAME' and service broker '$MARIADB_SHARED_CLASS' not found in cluster";
        exit 1
    fi
  fi

  if [ "$SERVICE_TYPE" == "mongodb-shared" ]; then
    MONGODB_SHARED_CLASS=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.mongo-shared\\.class "${MONGODB_SHARED_DEFAULT_CLASS}")
    MONGODB_SHARED_PLAN=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.mongo-shared\\.plan "${ENVIRONMENT_TYPE}")

    # Check if the defined service broker plan  exists
    if svcat --scope cluster get plan --class "${MONGODB_SHARED_CLASS}" "${MONGODB_SHARED_PLAN}" > /dev/null; then
        MAP_SERVICE_NAME_TO_SERVICEBROKER_PLAN["${SERVICE_NAME}"]="${MONGODB_SHARED_PLAN}"
    else
        echo "defined service broker plan '${MONGODB_SHARED_PLAN}' for service '$SERVICE_NAME' and service broker '$MONGODB_SHARED_CLASS' not found in cluster";
        exit 1
    fi
  fi

  if [[ "$SERVICE_TYPE" == "mongodb-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.$SERVICE_TYPE\\.environment "${ENVIRONMENT_TYPE}")

    # Allow the dbaas shared servicebroker plan to be overriden by environment in .lagoon.yml
    ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH}.overrides.$SERVICE_NAME.$SERVICE_TYPE\\.environment false)
    if [ ! $DBAAS_ENVIRONMENT_OVERRIDE == "false" ]; then
      DBAAS_ENVIRONMENT=$ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE
    fi

    # If we have a dbaas environment type override in the api, consume it here
    if [ ! -z "$LAGOON_DBAAS_ENVIRONMENT_TYPES" ]; then
      IFS=',' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPES"
      for LAGOON_DBAAS_ENVIRONMENT_TYPE in "${LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT[@]}"
      do
        IFS=':' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPE"
        if [ "${LAGOON_DBAAS_ENVIRONMENT_TYPE[0]}" == "$SERVICE_NAME" ]; then
          DBAAS_ENVIRONMENT_TYPE=${LAGOON_DBAAS_ENVIRONMENT_TYPE[1]}
        fi
      done
    fi

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="$DBAAS_ENVIRONMENT"
  fi

  if [ "$SERVICE_TYPE" == "none" ]; then
    continue
  fi

  # For DeploymentConfigs with multiple Services inside (like nginx-php), we allow to define the service type of within the
  # deploymentconfig via lagoon.deployment.servicetype. If this is not set we use the Compose Service Name
  DEPLOYMENT_SERVICETYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.deployment\\.servicetype default)
  if [ "$DEPLOYMENT_SERVICETYPE" == "default" ]; then
    DEPLOYMENT_SERVICETYPE=$COMPOSE_SERVICE
  fi

  # The ImageName is the same as the Name of the Docker Compose ServiceName
  IMAGE_NAME=$COMPOSE_SERVICE

  # Do not handle images for shared services
  if  [[ "$SERVICE_TYPE" != "mariadb-dbaas" ]] &&
      [[ "$SERVICE_TYPE" != "mariadb-shared" ]] &&
      [[ "$SERVICE_TYPE" != "mongodb-shared" ]] &&
      [[ "$SERVICE_TYPE" != "mongodb-dbaas" ]]; then
    # Generate List of Images to build
    IMAGES+=("${IMAGE_NAME}")
  fi

  # Map Deployment ServiceType to the ImageName
  MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME["${SERVICE_NAME}:${DEPLOYMENT_SERVICETYPE}"]="${IMAGE_NAME}"

  # Create an array with all Service Names and Types if it does not exist yet
  if [[ ! " ${SERVICE_TYPES[@]} " =~ " ${SERVICE_NAME}:${SERVICE_TYPE} " ]]; then
    SERVICE_TYPES+=("${SERVICE_NAME}:${SERVICE_TYPE}")
  fi

  # ServiceName and Type to Original Service Name Mapping, but only once per Service name and Type,
  # as we have original services that appear twice (like in the case of nginx-php)
  if [[ ! "${MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_NAME}:${SERVICE_TYPE}"]+isset}" ]]; then
    MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_NAME}:${SERVICE_TYPE}"]="${COMPOSE_SERVICE}"
  fi

  # ServiceName to ImageName mapping, but only once as we have original services that appear twice (like in the case of nginx-php)
  # these will be handled via MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME
  if [[ ! "${MAP_SERVICE_NAME_TO_IMAGENAME["${SERVICE_NAME}"]+isset}" ]]; then
    MAP_SERVICE_NAME_TO_IMAGENAME["${SERVICE_NAME}"]="${IMAGE_NAME}"
  fi

done

##############################################
### PRIVATE REGISTRY LOGINS
##############################################
# we want to be able to support private container registries
set +x
# grab all the container-registries that are defined in the `.lagoon.yml` file
PRIVATE_CONTAINER_REGISTRIES=($(cat .lagoon.yml | shyaml keys container-registries || echo ""))
for PRIVATE_CONTAINER_REGISTRY in "${PRIVATE_CONTAINER_REGISTRIES[@]}"
do
  # check if a url is set, if none set proceed against docker hub
  PRIVATE_CONTAINER_REGISTRY_URL=$(cat .lagoon.yml | shyaml get-value container-registries.$PRIVATE_CONTAINER_REGISTRY.url false)
  if [ $PRIVATE_CONTAINER_REGISTRY_URL == "false" ]; then
    echo "No 'url' defined for registry $PRIVATE_CONTAINER_REGISTRY, will proceed against docker hub";
  fi
  # check the username and passwords are defined in yaml
  PRIVATE_CONTAINER_REGISTRY_USERNAME=$(cat .lagoon.yml | shyaml get-value container-registries.$PRIVATE_CONTAINER_REGISTRY.username false)
  if [ $PRIVATE_CONTAINER_REGISTRY_USERNAME == "false" ]; then
    echo "No 'username' defined for registry $PRIVATE_CONTAINER_REGISTRY"; exit 1;
  fi
  PRIVATE_CONTAINER_REGISTRY_PASSWORD=$(cat .lagoon.yml | shyaml get-value container-registries.$PRIVATE_CONTAINER_REGISTRY.password false)
  if [[ $PRIVATE_CONTAINER_REGISTRY_PASSWORD == "false" ]]; then
    echo "No 'password' defined for registry $PRIVATE_CONTAINER_REGISTRY"; exit 1;
  fi
  # if we have everything we need, we can proceed to logging in
  if [ $PRIVATE_CONTAINER_REGISTRY_PASSWORD != "false" ]; then
    PRIVATE_REGISTRY_CREDENTIAL=""
    # check if we have a password defined anywhere in the api first
    if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
      PRIVATE_REGISTRY_CREDENTIAL=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "container_registry" and .name == "'$PRIVATE_CONTAINER_REGISTRY_PASSWORD'") | "\(.value)"'))
    fi
    if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
      TEMP_PRIVATE_REGISTRY_CREDENTIAL=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "container_registry" and .name == "'$PRIVATE_CONTAINER_REGISTRY_PASSWORD'") | "\(.value)"'))
      if [ ! -z "$TEMP_PRIVATE_REGISTRY_CREDENTIAL" ]; then
        PRIVATE_REGISTRY_CREDENTIAL=$TEMP_PRIVATE_REGISTRY_CREDENTIAL
      fi
    fi
    if [ -z $PRIVATE_REGISTRY_CREDENTIAL ]; then
      #if no password defined in the lagoon api, pass the one in `.lagoon.yml` as a password
      PRIVATE_REGISTRY_CREDENTIAL=$PRIVATE_CONTAINER_REGISTRY_PASSWORD
    fi
    if [ -z "$PRIVATE_REGISTRY_CREDENTIAL" ]; then
      echo -e "A private container registry was defined in the .lagoon.yml file, but no password could be found in either the .lagoon.yml or in the Lagoon API\n\nPlease check if the password has been set correctly."
      exit 1
    fi
    if [ $PRIVATE_CONTAINER_REGISTRY_URL != "false" ]; then
      echo "Attempting to log in to $PRIVATE_CONTAINER_REGISTRY_URL with user $PRIVATE_CONTAINER_REGISTRY_USERNAME - $PRIVATE_CONTAINER_REGISTRY_PASSWORD"
      docker login --username $PRIVATE_CONTAINER_REGISTRY_USERNAME --password $PRIVATE_REGISTRY_CREDENTIAL $PRIVATE_CONTAINER_REGISTRY_URL
    else
      echo "Attempting to log in to docker hub with user $PRIVATE_CONTAINER_REGISTRY_USERNAME - $PRIVATE_CONTAINER_REGISTRY_PASSWORD"
      docker login --username $PRIVATE_CONTAINER_REGISTRY_USERNAME --password $PRIVATE_REGISTRY_CREDENTIAL
    fi
  fi
done
set -x

##############################################
### BUILD IMAGES
##############################################

# we only need to build images for pullrequests and branches, but not during a TUG build
if [[ ( "$TYPE" == "pullrequest"  ||  "$TYPE" == "branch" ) && ! $THIS_IS_TUG == "true" ]]; then

  BUILD_ARGS=()

  set +x # reduce noise in build logs
  # Get the pre-rollout and post-rollout vars
    if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
      LAGOON_PREROLLOUT_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_PREROLLOUT_DISABLED") | "\(.value)"'))
      LAGOON_POSTROLLOUT_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_POSTROLLOUT_DISABLED") | "\(.value)"'))
    fi
    if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
      LAGOON_PREROLLOUT_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_PREROLLOUT_DISABLED") | "\(.value)"'))
      LAGOON_POSTROLLOUT_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_POSTROLLOUT_DISABLED") | "\(.value)"'))
    fi
  set -x

  set +x # reduce noise in build logs
  # Add environment variables from lagoon API as build args
  if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
    echo "LAGOON_PROJECT_VARIABLES are available from the API"
    # multiline/spaced variables seem to break when being added from the API.
    # this changes the way it works to create the variable in a similar way to how they are injected below
    LAGOON_ENV_VARS=$(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | "\(.name)"')
    for LAGOON_ENV_VAR in $LAGOON_ENV_VARS
    do
      BUILD_ARGS+=(--build-arg $(echo $LAGOON_ENV_VAR)="$(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | select(.name == "'$LAGOON_ENV_VAR'") | "\(.value)"')")
    done
  fi
  if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
    echo "LAGOON_ENVIRONMENT_VARIABLES are available from the API"
    # multiline/spaced variables seem to break when being added from the API.
    # this changes the way it works to create the variable in a similar way to how they are injected below
    LAGOON_ENV_VARS=$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | "\(.name)"')
    for LAGOON_ENV_VAR in $LAGOON_ENV_VARS
    do
      BUILD_ARGS+=(--build-arg $(echo $LAGOON_ENV_VAR)="$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | select(.name == "'$LAGOON_ENV_VAR'") | "\(.value)"')")
    done
  fi
  set -x

  BUILD_ARGS+=(--build-arg IMAGE_REPO="${CI_OVERRIDE_IMAGE_REPO}")
  BUILD_ARGS+=(--build-arg LAGOON_GIT_SHA="${LAGOON_GIT_SHA}")
  BUILD_ARGS+=(--build-arg LAGOON_GIT_BRANCH="${BRANCH}")
  BUILD_ARGS+=(--build-arg LAGOON_GIT_SAFE_BRANCH="${SAFE_BRANCH}")
  BUILD_ARGS+=(--build-arg LAGOON_PROJECT="${PROJECT}")
  BUILD_ARGS+=(--build-arg LAGOON_ENVIRONMENT="${SAFE_BRANCH}")
  BUILD_ARGS+=(--build-arg LAGOON_SAFE_PROJECT="${SAFE_PROJECT}")
  BUILD_ARGS+=(--build-arg LAGOON_BUILD_TYPE="${TYPE}")
  BUILD_ARGS+=(--build-arg LAGOON_GIT_SOURCE_REPOSITORY="${SOURCE_REPOSITORY}")

  set +x
  BUILD_ARGS+=(--build-arg LAGOON_SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY}")
  set -x

  if [ "$TYPE" == "pullrequest" ]; then
    BUILD_ARGS+=(--build-arg LAGOON_PR_HEAD_BRANCH="${PR_HEAD_BRANCH}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_HEAD_SHA="${PR_HEAD_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_BASE_BRANCH="${PR_BASE_BRANCH}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_BASE_SHA="${PR_BASE_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_TITLE="${PR_TITLE}")
  fi

  for IMAGE_NAME in "${IMAGES[@]}"
  do

    DOCKERFILE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.dockerfile false)
    if [ $DOCKERFILE == "false" ]; then
      # No Dockerfile defined, assuming to download the Image directly

      PULL_IMAGE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.image false)
      if [ $PULL_IMAGE == "false" ]; then
        echo "No Dockerfile or Image for service ${IMAGE_NAME} defined"; exit 1;
      fi

      # allow to overwrite image that we pull
      OVERRIDE_IMAGE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.labels.lagoon\\.image false)
      if [ ! $OVERRIDE_IMAGE == "false" ]; then
        # expand environment variables from ${OVERRIDE_IMAGE}
        PULL_IMAGE=$(echo "${OVERRIDE_IMAGE}" | envsubst)
      fi

      # if the image just is an image name (like "alpine") we prefix it with `libary/` as the imagecache does not understand
      # the magic `alpine` images
      if [[ ! "$PULL_IMAGE" =~ "/" ]]; then
        PULL_IMAGE="library/$PULL_IMAGE"
      fi

      # Add the images we should pull to the IMAGES_PULL array, they will later be tagged from dockerhub
      IMAGES_PULL["${IMAGE_NAME}"]="${PULL_IMAGE}"

    else
      # Dockerfile defined, load the context and build it

      # We need the Image Name uppercase sometimes, so we create that here
      IMAGE_NAME_UPPERCASE=$(echo "$IMAGE_NAME" | tr '[:lower:]' '[:upper:]')


      # To prevent clashes of ImageNames during parallel builds, we give all Images a Temporary name
      TEMPORARY_IMAGE_NAME="${OPENSHIFT_PROJECT}-${IMAGE_NAME}"

      BUILD_CONTEXT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.context .)
      if [ ! -f $BUILD_CONTEXT/$DOCKERFILE ]; then
        echo "defined Dockerfile $DOCKERFILE for service $IMAGE_NAME not found"; exit 1;
      fi

      . /oc-build-deploy/scripts/exec-build.sh

      # Keep a list of the images we have built, as we need to push them to the OpenShift Registry later
      IMAGES_BUILD["${IMAGE_NAME}"]="${TEMPORARY_IMAGE_NAME}"

      # adding the build image to the list of arguments passed into the next image builds
      BUILD_ARGS+=(--build-arg ${IMAGE_NAME_UPPERCASE}_IMAGE=${TEMPORARY_IMAGE_NAME})
    fi

  done

fi

# if $DEPLOY_TYPE is tug we just push the images to the defined docker registry and create a clone
# of ourselves and push it into `lagoon-tug` image which is then executed in the destination openshift
# If though this is the actual tug deployment in the destination openshift, we don't run this
if [[ $DEPLOY_TYPE == "tug" && ! $THIS_IS_TUG == "true" ]]; then

  . /oc-build-deploy/tug/tug-build-push.sh

  # exit here, we are done
  exit
fi

##############################################
### RUN PRE-ROLLOUT tasks defined in .lagoon.yml
##############################################

if [ "${LAGOON_PREROLLOUT_DISABLED}" != "true" ]; then
  COUNTER=0
  while [ -n "$(cat .lagoon.yml | shyaml keys tasks.pre-rollout.$COUNTER 2> /dev/null)" ]
  do
    TASK_TYPE=$(cat .lagoon.yml | shyaml keys tasks.pre-rollout.$COUNTER)
    echo $TASK_TYPE
    case "$TASK_TYPE" in
      run)
          COMMAND=$(cat .lagoon.yml | shyaml get-value tasks.pre-rollout.$COUNTER.$TASK_TYPE.command)
          SERVICE_NAME=$(cat .lagoon.yml | shyaml get-value tasks.pre-rollout.$COUNTER.$TASK_TYPE.service)
          CONTAINER=$(cat .lagoon.yml | shyaml get-value tasks.pre-rollout.$COUNTER.$TASK_TYPE.container false)
          SHELL=$(cat .lagoon.yml | shyaml get-value tasks.pre-rollout.$COUNTER.$TASK_TYPE.shell sh)
          . /oc-build-deploy/scripts/exec-pre-tasks-run.sh
          ;;
      *)
          echo "Task Type ${TASK_TYPE} not implemented"; exit 1;

    esac

    let COUNTER=COUNTER+1
  done
else
  echo "pre-rollout tasks are currently disabled LAGOON_PREROLLOUT_DISABLED is set to true"
fi

##############################################
### CREATE OPENSHIFT SERVICES, ROUTES and SERVICEBROKERS
##############################################

YAML_CONFIG_FILE="services-routes"

# BC for routes.insecure, which is now called routes.autogenerate.insecure
BC_ROUTES_AUTOGENERATE_INSECURE=$(cat .lagoon.yml | shyaml get-value routes.insecure false)
if [ ! $BC_ROUTES_AUTOGENERATE_INSECURE == "false" ]; then
  echo "=== routes.insecure is now defined in routes.autogenerate.insecure, pleae update your .lagoon.yml file"
  ROUTES_AUTOGENERATE_INSECURE=$BC_ROUTES_AUTOGENERATE_INSECURE
else
  # By default we allow insecure traffic on autogenerate routes
  ROUTES_AUTOGENERATE_INSECURE=$(cat .lagoon.yml | shyaml get-value routes.autogenerate.insecure Allow)
fi

ROUTES_AUTOGENERATE_ENABLED=$(set -o pipefail; cat .lagoon.yml | shyaml get-value routes.autogenerate.enabled true | tr '[:upper:]' '[:lower:]')
ROUTES_AUTOGENERATE_ALLOW_PRS=$(cat .lagoon.yml | shyaml get-value routes.autogenerate.allowPullrequests $ROUTES_AUTOGENERATE_ENABLED | tr '[:upper:]' '[:lower:]')
if [[ "$TYPE" == "pullrequest" && "$ROUTES_AUTOGENERATE_ALLOW_PRS" == "true" ]]; then
  ROUTES_AUTOGENERATE_ENABLED=true
fi
## fail silently if the key autogenerateRoutes doesn't exist and default to whatever ROUTES_AUTOGENERATE_ENABLED is set to
ROUTES_AUTOGENERATE_BRANCH=$(set -o pipefail; cat .lagoon.yml | shyaml -q get-value environments.${BRANCH//./\\.}.autogenerateRoutes $ROUTES_AUTOGENERATE_ENABLED | tr '[:upper:]' '[:lower:]')
if [[ "$ROUTES_AUTOGENERATE_BRANCH" == "true" ]]; then
  ROUTES_AUTOGENERATE_ENABLED=true
fi

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do
  echo "=== BEGIN route processing for service ${SERVICE_TYPES_ENTRY} ==="
  echo "=== OPENSHIFT_SERVICES_TEMPLATE=${OPENSHIFT_SERVICES_TEMPLATE} "
  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  TEMPLATE_PARAMETERS=()

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_TYPE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.types.$SERVICE_NAME false)
  if [ ! $SERVICE_TYPE_OVERRIDE == "false" ]; then
    SERVICE_TYPE=$SERVICE_TYPE_OVERRIDE
  fi

  OPENSHIFT_SERVICES_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/services.yml"
  if [ -f $OPENSHIFT_SERVICES_TEMPLATE ]; then
    OPENSHIFT_TEMPLATE=$OPENSHIFT_SERVICES_TEMPLATE
    .  /oc-build-deploy/scripts/exec-openshift-resources.sh
  fi

  if [ $ROUTES_AUTOGENERATE_ENABLED == "true" ]; then

    OPENSHIFT_ROUTES_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/routes.yml"
    if [ -f $OPENSHIFT_ROUTES_TEMPLATE ]; then

      # The very first generated route is set as MAIN_GENERATED_ROUTE
      if [ -z "${MAIN_GENERATED_ROUTE+x}" ]; then
        MAIN_GENERATED_ROUTE=$SERVICE_NAME
      fi

      OPENSHIFT_TEMPLATE=$OPENSHIFT_ROUTES_TEMPLATE

      TEMPLATE_PARAMETERS+=(-p ROUTES_INSECURE="${ROUTES_AUTOGENERATE_INSECURE}")
      .  /oc-build-deploy/scripts/exec-openshift-resources.sh
    fi

  fi

  OPENSHIFT_SERVICES_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/servicebroker.yml"
  if [ -f $OPENSHIFT_SERVICES_TEMPLATE ]; then
    # Load the requested class and plan for this service
    SERVICEBROKER_CLASS="${MAP_SERVICE_NAME_TO_SERVICEBROKER_CLASS["${SERVICE_NAME}"]}"
    SERVICEBROKER_PLAN="${MAP_SERVICE_NAME_TO_SERVICEBROKER_PLAN["${SERVICE_NAME}"]}"
    . /oc-build-deploy/scripts/exec-openshift-create-servicebroker.sh
    SERVICEBROKERS+=("${SERVICE_NAME}:${SERVICE_TYPE}")
  fi

  # If we have a dbaas consumer, create it
  OPENSHIFT_SERVICES_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/consumer.yml"
  if [ -f $OPENSHIFT_SERVICES_TEMPLATE ]; then
    OPENSHIFT_TEMPLATE=$OPENSHIFT_SERVICES_TEMPLATE
    OPERATOR_ENVIRONMENT="${MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]}"
    TEMPLATE_ADDITIONAL_PARAMETERS=()
    oc process  --local -o yaml --insecure-skip-tls-verify \
      -n ${OPENSHIFT_PROJECT} \
      -f ${OPENSHIFT_TEMPLATE} \
      -p SERVICE_NAME="${SERVICE_NAME}" \
      -p SAFE_BRANCH="${SAFE_BRANCH}" \
      -p SAFE_PROJECT="${SAFE_PROJECT}" \
      -p ENVIRONMENT="${OPERATOR_ENVIRONMENT}" \
      | outputToYaml
    SERVICEBROKERS+=("${SERVICE_NAME}:${SERVICE_TYPE}")
  fi

done

TEMPLATE_PARAMETERS=()

##############################################
### CUSTOM ROUTES FROM .lagoon.yml
##############################################


MONITORING_ENABLED="false" # monitoring is by default disabled, it will be enabled for the first route again
MONITORING_INTERVAL=60

ROUTES_SERVICE_COUNTER=0

# we need to check for production routes for active/standby if they are defined, as these will get migrated between environments as required
if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
  if [ "${BRANCH//./\\.}" == "${ACTIVE_ENVIRONMENT}" ]; then
    if [ -n "$(cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; then
      while [ -n "$(cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; do
        ROUTES_SERVICE=$(cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER)

        ROUTE_DOMAIN_COUNTER=0
        while [ -n "$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER 2> /dev/null)" ]; do
          # Routes can either be a key (when the have additional settings) or just a value
          if cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER &> /dev/null; then
            ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
            # Route Domains include dots, which need to be esacped via `\.` in order to use them within shyaml
            ROUTE_DOMAIN_ESCAPED=$(cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER | sed 's/\./\\./g')
            ROUTE_TLS_ACME=$(set -o pipefail; cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.tls-acme true | tr '[:upper:]' '[:lower:]')
            ROUTE_MIGRATE=$(set -o pipefail; cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.migrate true | tr '[:upper:]' '[:lower:]')
            ROUTE_INSECURE=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.insecure Redirect)
            ROUTE_HSTS=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.hsts null)
            MONITORING_PATH=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.monitoring-path "/")
          else
            # Only a value given, assuming some defaults
            ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
            ROUTE_TLS_ACME=true
            ROUTE_MIGRATE=true
            ROUTE_INSECURE=Redirect
            ROUTE_HSTS=null
          fi

          # The very first found route is set as MAIN_CUSTOM_ROUTE
          if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
            MAIN_CUSTOM_ROUTE=$ROUTE_DOMAIN

            # if we are in production we enabled monitoring for the main custom route
            if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
              MONITORING_ENABLED="true"
            fi

          fi

          ROUTE_SERVICE=$ROUTES_SERVICE

          .  /oc-build-deploy/scripts/exec-openshift-create-route.sh

          MONITORING_ENABLED="false" # disabling a possible enabled monitoring again

          let ROUTE_DOMAIN_COUNTER=ROUTE_DOMAIN_COUNTER+1
        done

        let ROUTES_SERVICE_COUNTER=ROUTES_SERVICE_COUNTER+1
      done
    fi
  fi
  if [ "${BRANCH//./\\.}" == "${STANDBY_ENVIRONMENT}" ]; then
    if [ -n "$(cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; then
      while [ -n "$(cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; do
        ROUTES_SERVICE=$(cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER)

        ROUTE_DOMAIN_COUNTER=0
        while [ -n "$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER 2> /dev/null)" ]; do
          # Routes can either be a key (when the have additional settings) or just a value
          if cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER &> /dev/null; then
            ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
            # Route Domains include dots, which need to be esacped via `\.` in order to use them within shyaml
            ROUTE_DOMAIN_ESCAPED=$(cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER | sed 's/\./\\./g')
            ROUTE_TLS_ACME=$(set -o pipefail; cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.tls-acme true | tr '[:upper:]' '[:lower:]')
            ROUTE_MIGRATE=$(set -o pipefail; cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.migrate true | tr '[:upper:]' '[:lower:]')
            ROUTE_INSECURE=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.insecure Redirect)
            ROUTE_HSTS=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.hsts null)
            MONITORING_PATH=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.monitoring-path "/")
          else
            # Only a value given, assuming some defaults
            ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
            ROUTE_TLS_ACME=true
            ROUTE_MIGRATE=true
            ROUTE_INSECURE=Redirect
            ROUTE_HSTS=null
          fi

          # The very first found route is set as MAIN_CUSTOM_ROUTE
          if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
            MAIN_CUSTOM_ROUTE=$ROUTE_DOMAIN

            # if we are in production we enabled monitoring for the main custom route
            if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
              MONITORING_ENABLED="true"
            fi

          fi

          ROUTE_SERVICE=$ROUTES_SERVICE

          .  /oc-build-deploy/scripts/exec-openshift-create-route.sh

          MONITORING_ENABLED="false" # disabling a possible enabled monitoring again

          let ROUTE_DOMAIN_COUNTER=ROUTE_DOMAIN_COUNTER+1
        done

        let ROUTES_SERVICE_COUNTER=ROUTES_SERVICE_COUNTER+1
      done
    fi
  fi
fi

# Two while loops as we have multiple services that want routes and each service has multiple routes
ROUTES_SERVICE_COUNTER=0
if [ -n "$(cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; then
  while [ -n "$(cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; do
    ROUTES_SERVICE=$(cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER)

    ROUTE_DOMAIN_COUNTER=0
    while [ -n "$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER 2> /dev/null)" ]; do
      # Routes can either be a key (when the have additional settings) or just a value
      if cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER &> /dev/null; then
        ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
        # Route Domains include dots, which need to be esacped via `\.` in order to use them within shyaml
        ROUTE_DOMAIN_ESCAPED=$(cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER | sed 's/\./\\./g')
        ROUTE_TLS_ACME=$(set -o pipefail; cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.tls-acme true | tr '[:upper:]' '[:lower:]')
        ROUTE_MIGRATE=$(set -o pipefail; cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.migrate false | tr '[:upper:]' '[:lower:]')
        ROUTE_INSECURE=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.insecure Redirect)
        ROUTE_HSTS=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.hsts null)
        MONITORING_PATH=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.monitoring-path "/")
      else
        # Only a value given, assuming some defaults
        ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
        ROUTE_TLS_ACME=true
        ROUTE_MIGRATE=false
        ROUTE_INSECURE=Redirect
        ROUTE_HSTS=null
      fi

      # The very first found route is set as MAIN_CUSTOM_ROUTE
      if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
        MAIN_CUSTOM_ROUTE=$ROUTE_DOMAIN

        # if we are in production we enabled monitoring for the main custom route
        if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
          MONITORING_ENABLED="true"
        fi

      fi

      ROUTE_SERVICE=$ROUTES_SERVICE

      .  /oc-build-deploy/scripts/exec-openshift-create-route.sh

      MONITORING_ENABLED="false" # disabling a possible enabled monitoring again

      let ROUTE_DOMAIN_COUNTER=ROUTE_DOMAIN_COUNTER+1
    done

    let ROUTES_SERVICE_COUNTER=ROUTES_SERVICE_COUNTER+1
  done
else
  while [ -n "$(cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER 2> /dev/null)" ]; do
    ROUTES_SERVICE=$(cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER)

    ROUTE_DOMAIN_COUNTER=0
    while [ -n "$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER 2> /dev/null)" ]; do
      # Routes can either be a key (when the have additional settings) or just a value
      if cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER &> /dev/null; then
        ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
        # Route Domains include dots, which need to be esacped via `\.` in order to use them within shyaml
        ROUTE_DOMAIN_ESCAPED=$(cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER | sed 's/\./\\./g')
        ROUTE_TLS_ACME=$(set -o pipefail; cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.tls-acme true | tr '[:upper:]' '[:lower:]')
        ROUTE_MIGRATE=$(set -o pipefail; cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.migrate false | tr '[:upper:]' '[:lower:]')
        ROUTE_INSECURE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.insecure Redirect)
        ROUTE_HSTS=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.hsts null)
        MONITORING_PATH=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.monitoring-path "/")
      else
        # Only a value given, assuming some defaults
        ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
        ROUTE_TLS_ACME=true
        ROUTE_MIGRATE=false
        ROUTE_INSECURE=Redirect
        ROUTE_HSTS=null
      fi

      # The very first found route is set as MAIN_CUSTOM_ROUTE
      if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
        MAIN_CUSTOM_ROUTE=$ROUTE_DOMAIN

        # if we are in production we enabled monitoring for the main custom route
        if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
          MONITORING_ENABLED="true"
        fi

      fi

      ROUTE_SERVICE=$ROUTES_SERVICE

      .  /oc-build-deploy/scripts/exec-openshift-create-route.sh

      MONITORING_ENABLED="false" # disabling a possible enabled monitoring again

      let ROUTE_DOMAIN_COUNTER=ROUTE_DOMAIN_COUNTER+1
    done

    let ROUTES_SERVICE_COUNTER=ROUTES_SERVICE_COUNTER+1
  done
fi

# If restic backups are supported by this cluster we create the schedule definition
if oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get schedules.backup.appuio.ch &> /dev/null; then

  if ! oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get secret baas-repo-pw &> /dev/null; then
    # Create baas-repo-pw secret based on the project secret
    set +x
    oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} create secret generic baas-repo-pw --from-literal=repo-pw=$(echo -n "$PROJECT_SECRET-BAAS-REPO-PW" | sha256sum | cut -d " " -f 1)
    set -x
  fi

  TEMPLATE_PARAMETERS=()

  # Check for custom baas bucket name
  if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
    BAAS_BUCKET_NAME=$(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_BAAS_BUCKET_NAME") | "\(.value)"')
  fi
  if [ -z $BAAS_BUCKET_NAME ]; then
    BAAS_BUCKET_NAME=baas-${SAFE_PROJECT}
  fi
  TEMPLATE_PARAMETERS+=(-p BAAS_BUCKET_NAME="${BAAS_BUCKET_NAME}")

  # Pull in .lagoon.yml variables
  PRODUCTION_MONTHLY_BACKUP_RETENTION=$(cat .lagoon.yml | shyaml get-value backup-retention.production.monthly "")
  PRODUCTION_WEEKLY_BACKUP_RETENTION=$(cat .lagoon.yml | shyaml get-value backup-retention.production.weekly "")
  PRODUCTION_DAILY_BACKUP_RETENTION=$(cat .lagoon.yml | shyaml get-value backup-retention.production.daily "")

  # Set template parameters for retention values (prefer .lagoon.yml values over supplied defaults after ensuring they are valid integers via "-eq" comparison)
  if [ ! -z $PRODUCTION_MONTHLY_BACKUP_RETENTION ] && [ "$PRODUCTION_MONTHLY_BACKUP_RETENTION" -eq "$PRODUCTION_MONTHLY_BACKUP_RETENTION" ] && [ $ENVIRONMENT_TYPE = 'production']; then
    TEMPLATE_PARAMETERS+=(-p MONTHLY_BACKUP_RETENTION="${PRODUCTION_MONTHLY_BACKUP_RETENTION}")
  else
    TEMPLATE_PARAMETERS+=(-p MONTHLY_BACKUP_RETENTION="${MONTHLY_BACKUP_DEFAULT_RETENTION}")
  fi
  if [ ! -z $PRODUCTION_WEEKLY_BACKUP_RETENTION ] && [ "$PRODUCTION_WEEKLY_BACKUP_RETENTION" -eq "$PRODUCTION_WEEKLY_BACKUP_RETENTION" ] && [ $ENVIRONMENT_TYPE = 'production']; then
    TEMPLATE_PARAMETERS+=(-p WEEKLY_BACKUP_RETENTION="${PRODUCTION_WEEKLY_BACKUP_RETENTION}")
  else
    TEMPLATE_PARAMETERS+=(-p WEEKLY_BACKUP_RETENTION="${WEEKLY_BACKUP_DEFAULT_RETENTION}")
  fi
  if [ ! -z $PRODUCTION_DAILY_BACKUP_RETENTION ] && [ "$PRODUCTION_DAILY_BACKUP_RETENTION" -eq "$PRODUCTION_DAILY_BACKUP_RETENTION" ] && [ $ENVIRONMENT_TYPE = 'production']; then
    TEMPLATE_PARAMETERS+=(-p DAILY_BACKUP_RETENTION="${PRODUCTION_DAILY_BACKUP_RETENTION}")
  else
    TEMPLATE_PARAMETERS+=(-p DAILY_BACKUP_RETENTION="${DAILY_BACKUP_DEFAULT_RETENTION}")
  fi

  # Run Backups every day at 2200-0200
  BACKUP_SCHEDULE=$( /oc-build-deploy/scripts/convert-crontab.sh "${OPENSHIFT_PROJECT}" "M H(22-2) * * *")
  TEMPLATE_PARAMETERS+=(-p BACKUP_SCHEDULE="${BACKUP_SCHEDULE}")

  # Checks
  if [ ! -z $K8UP_WEEKLY_RANDOM_FEATURE_FLAG ] && [ $K8UP_WEEKLY_RANDOM_FEATURE_FLAG = 'enabled' ]; then
    # Let the controller deduplicate checks (will run weekly at a random time throughout the week)
    CHECK_SCHEDULE="@weekly-random"
  else
    # Run Checks on Sunday at 0300-0600
    CHECK_SCHEDULE=$( /oc-build-deploy/scripts/convert-crontab.sh "${OPENSHIFT_PROJECT}" "M H(3-6) * * 0")
  fi
  TEMPLATE_PARAMETERS+=(-p CHECK_SCHEDULE="${CHECK_SCHEDULE}")

  # Prunes
  if [ ! -z $K8UP_WEEKLY_RANDOM_FEATURE_FLAG ] && [ $K8UP_WEEKLY_RANDOM_FEATURE_FLAG = 'enabled' ]; then
    # Let the controller deduplicate prunes (will run weekly at a random time throughout the week)
    PRUNE_SCHEDULE="@weekly-random"
  else
    # Run Prune on Saturday at 0300-0600
    PRUNE_SCHEDULE=$( /oc-build-deploy/scripts/convert-crontab.sh "${OPENSHIFT_PROJECT}" "M H(3-6) * * 6")
  fi
  TEMPLATE_PARAMETERS+=(-p PRUNE_SCHEDULE="${PRUNE_SCHEDULE}")

  OPENSHIFT_TEMPLATE="/oc-build-deploy/openshift-templates/backup-schedule.yml"
  .  /oc-build-deploy/scripts/exec-openshift-resources.sh
fi

if [ -f /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml ]; then
  oc apply --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} -f /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml
fi

##############################################
### CUSTOM MONITORING_URLS FROM .lagoon.yml
##############################################
# @DEPRECATED - to be removed with Lagoon 2.0
URL_COUNTER=0
while [ -n "$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.monitoring_urls.$URL_COUNTER 2> /dev/null)" ]; do
  echo "DEPRECATION WARNING: 'monitoring_urls' is being moved to a per-route 'monitoring-path', please update your route"
  MONITORING_URL="$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.monitoring_urls.$URL_COUNTER)"
  if [[ $URL_COUNTER > 0 ]]; then
    MONITORING_URLS="${MONITORING_URLS}, ${MONITORING_URL}"
  else
    MONITORING_URLS="${MONITORING_URL}"
  fi
  let URL_COUNTER=URL_COUNTER+1
done

##############################################
### PROJECT WIDE ENV VARIABLES
##############################################

# If we have a custom route, we use that as main route
if [ "$MAIN_CUSTOM_ROUTE" ]; then
  MAIN_ROUTE_NAME=$MAIN_CUSTOM_ROUTE
# no custom route, we use the first generated route
elif [ "$MAIN_GENERATED_ROUTE" ]; then
  MAIN_ROUTE_NAME=$MAIN_GENERATED_ROUTE
fi

# Load the found main routes with correct schema
if [ "$MAIN_ROUTE_NAME" ]; then
  ROUTE=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get route "$MAIN_ROUTE_NAME" -o=go-template --template='{{if .spec.tls.termination}}https://{{else}}http://{{end}}{{.spec.host}}')
fi

# Load all routes with correct schema and comma separated
ROUTES=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get routes -l "acme.openshift.io/exposer!=true" -o=go-template --template='{{range $index, $route := .items}}{{if $index}},{{end}}{{if $route.spec.tls.termination}}https://{{else}}http://{{end}}{{$route.spec.host}}{{end}}')

# Active / Standby routes
ACTIVE_ROUTES=""
STANDBY_ROUTES=""
if [ ! -z "${STANDBY_ENVIRONMENT}" ]; then
ACTIVE_ROUTES=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get routes -l "dioscuri.amazee.io/migrate=true" -o=go-template --template='{{range $index, $route := .items}}{{if $index}},{{end}}{{if $route.spec.tls.termination}}https://{{else}}http://{{end}}{{$route.spec.host}}{{end}}')
STANDBY_ROUTES=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get routes -l "dioscuri.amazee.io/migrate=true" -o=go-template --template='{{range $index, $route := .items}}{{if $index}},{{end}}{{if $route.spec.tls.termination}}https://{{else}}http://{{end}}{{$route.spec.host}}{{end}}')
fi

# Get list of autogenerated routes
AUTOGENERATED_ROUTES=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get routes -l "lagoon/autogenerated=true" -o=go-template --template='{{range $index, $route := .items}}{{if $index}},{{end}}{{if $route.spec.tls.termination}}https://{{else}}http://{{end}}{{$route.spec.host}}{{end}}')

# If no MONITORING_URLS were specified, fall back to the ROUTE of the project
if [ -z "$MONITORING_URLS" ]; then
  echo "No monitoring_urls provided, using ROUTE"
  MONITORING_URLS="${ROUTE}"
fi

# Generate a Config Map with project wide env variables
oc process --local --insecure-skip-tls-verify \
  -n ${OPENSHIFT_PROJECT} \
  -f /oc-build-deploy/openshift-templates/configmap.yml \
  -p NAME="lagoon-env" \
  -p SAFE_BRANCH="${SAFE_BRANCH}" \
  -p SAFE_PROJECT="${SAFE_PROJECT}" \
  -p BRANCH="${BRANCH}" \
  -p PROJECT="${PROJECT}" \
  -p ENVIRONMENT_TYPE="${ENVIRONMENT_TYPE}" \
  -p ROUTE="${ROUTE}" \
  -p ROUTES="${ROUTES}" \
  -p ACTIVE_ROUTES="${ACTIVE_ROUTES}" \
  -p STANDBY_ROUTES="${STANDBY_ROUTES}" \
  -p MONITORING_URLS="${MONITORING_URLS}" \
  -p OPENSHIFT_NAME="${OPENSHIFT_NAME}" \
  -p AUTOGENERATED_ROUTES="${AUTOGENERATED_ROUTES}" \
  | oc apply --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} -f -


# process the api-configmap template with null data value
# doing this means that the only variables in `lagoon-api-vars` configmap will be ones that come from the lagoon api
# this allows us to remove them from the lagoon api and not leave them hanging around in a configmap
# the lagoon-env configmap can then be left for persistent changes
# mounting `lagoon-api-vars` into a pod after `lagoon-env` means that what is in the api-vars configmap
# should be used instead of whats in lagoon-env, meaning API variables will be used before lagoon-env ones
if ! oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-api-vars &> /dev/null; then
# only create the configmap if it doesn't already exist
cat <<EOF | oc apply --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} -f -
kind: ConfigMap
apiVersion: v1
metadata:
  name: lagoon-api-vars
data:
EOF
fi

set +x # reduce noise in build logs
# store the existing variables that are in the configmap here
EXISTING_CONFIGMAP_VARS=""
if oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-api-vars -o json | jq -r '.data | keys[]' 2> /dev/null; then
  EXISTING_CONFIGMAP_VARS=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-api-vars -o json | jq -r '.data | keys[]' 2> /dev/null)
fi


# Add environment variables from lagoon API
# patch the `lagoon-api-vars` configmap with what is in actually in the lagoon api
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  HAS_PROJECT_RUNTIME_VARS=$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") )')

  if [ ! "$HAS_PROJECT_RUNTIME_VARS" = "[]" ]; then
    oc patch --insecure-skip-tls-verify \
      -n ${OPENSHIFT_PROJECT} \
      configmap lagoon-api-vars \
      -p "{\"data\":$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | tostring')}"
  fi
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  HAS_ENVIRONMENT_RUNTIME_VARS=$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") )')

  if [ ! "$HAS_ENVIRONMENT_RUNTIME_VARS" = "[]" ]; then
    oc patch --insecure-skip-tls-verify \
      -n ${OPENSHIFT_PROJECT} \
      configmap lagoon-api-vars \
      -p "{\"data\":$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | tostring')}"
  fi
fi

# if there were existing vars in the configmap
# work out which ones no longer exist in the API and run patch op remove on them
if [ ! -z "$EXISTING_CONFIGMAP_VARS" ]; then
  # get what is in the configmap now that the patch operations to add what is in the API has been done already
  CURRENT_CONFIGMAP_VARS=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-api-vars -o json | jq -r '.data | keys[]')
  # get the keys of the vars that were added from the api
  API_PROJECT_VARS=$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | keys[]')
  API_ENVIRONMENT_VARS=$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | keys[]')
  # get all the unique keys from the API and current configmap
  # and remove anything that isn't in the API anymore from the configmap
  VARS_TO_REMOVE1=$(comm -23 <(echo $CURRENT_CONFIGMAP_VARS | tr ' ' '\n' | sort) <(echo $API_ENVIRONMENT_VARS | tr ' ' '\n' | sort))
  VARS_TO_REMOVE2=$(comm -23 <(echo $VARS_TO_REMOVE1 | tr ' ' '\n' | sort) <(echo $API_PROJECT_VARS | tr ' ' '\n' | sort))

  # if there are vars to remove, then craft the remove operation patch
  REMOVE_OPERATION_JSON=""
  if [ ! -z "$VARS_TO_REMOVE2" ]; then
    for VAR_TO_REMOVE in $VARS_TO_REMOVE2
    do
      REMOVE_OPERATION_JSON="${REMOVE_OPERATION_JSON:+$REMOVE_OPERATION_JSON, }$(echo -n {\"op\": \"remove\", \"path\": \"/data/$VAR_TO_REMOVE\"})"
    done
    # then actually apply the patch to remove the vars from the configmap
    oc patch --insecure-skip-tls-verify \
      -n ${OPENSHIFT_PROJECT} \
      configmap lagoon-api-vars \
      --type=json -p "[$REMOVE_OPERATION_JSON]"
  fi
fi
set -x

if [ "$TYPE" == "pullrequest" ]; then
  oc patch --insecure-skip-tls-verify \
    -n ${OPENSHIFT_PROJECT} \
    configmap lagoon-env \
    -p "{\"data\":{\"LAGOON_PR_HEAD_BRANCH\":\"${PR_HEAD_BRANCH}\", \"LAGOON_PR_BASE_BRANCH\":\"${PR_BASE_BRANCH}\", \"LAGOON_PR_TITLE\":$(echo $PR_TITLE | jq -R)}}"
fi

# loop through created ServiceBroker
for SERVICEBROKER_ENTRY in "${SERVICEBROKERS[@]}"
do
  IFS=':' read -ra SERVICEBROKER_ENTRY_SPLIT <<< "$SERVICEBROKER_ENTRY"

  SERVICE_NAME=${SERVICEBROKER_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICEBROKER_ENTRY_SPLIT[1]}

  # The prefix for the environment variables.
  SERVICE_NAME_UPPERCASE=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

  case "$SERVICE_TYPE" in
    # Operator can take some time to return the required information, do it here
    mariadb-dbaas)
        . /oc-build-deploy/scripts/exec-openshift-mariadb-dbaas.sh
        ;;

    mariadb-shared)
        # ServiceBrokers take a bit, wait until the credentials secret is available
	# We added a timeout of 10 minutes (120 retries) before exit
	SERVICE_BROKER_COUNTER=1
	SERVICE_BROKER_TIMEOUT=180
        until oc get --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} secret ${SERVICE_NAME}-servicebroker-credentials
        do
	  if [ $SERVICE_BROKER_COUNTER -lt $SERVICE_BROKER_TIMEOUT ]; then
		  let SERVICE_BROKER_COUNTER=SERVICE_BROKER_COUNTER+1
		  echo "Secret ${SERVICE_NAME}-servicebroker-credentials not available yet, waiting for 5 secs"
		  sleep 5
	  else
		  echo "Timeout of $SERVICE_BROKER_TIMEOUT for ${SERVICE_NAME}-servicebroker-credentials reached"
		  exit 1
	  fi
        done
        # Load credentials out of secret
        oc get --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} secret ${SERVICE_NAME}-servicebroker-credentials -o yaml > /oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml
        set +x
        DB_HOST=$(cat /oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml | shyaml get-value data.DB_HOST | base64 -d)
        DB_USER=$(cat /oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml | shyaml get-value data.DB_USER | base64 -d)
        DB_PASSWORD=$(cat /oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml | shyaml get-value data.DB_PASSWORD | base64 -d)
        DB_NAME=$(cat /oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml | shyaml get-value data.DB_NAME | base64 -d)
        DB_PORT=$(cat /oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml | shyaml get-value data.DB_PORT | base64 -d)

        # Add credentials to our configmap, prefixed with the name of the servicename of this servicebroker
        oc patch --insecure-skip-tls-verify \
          -n ${OPENSHIFT_PROJECT} \
          configmap lagoon-env \
          -p "{\"data\":{\"${SERVICE_NAME_UPPERCASE}_HOST\":\"${DB_HOST}\", \"${SERVICE_NAME_UPPERCASE}_USERNAME\":\"${DB_USER}\", \"${SERVICE_NAME_UPPERCASE}_PASSWORD\":\"${DB_PASSWORD}\", \"${SERVICE_NAME_UPPERCASE}_DATABASE\":\"${DB_NAME}\", \"${SERVICE_NAME_UPPERCASE}_PORT\":\"${DB_PORT}\"}}"

        # only add the DB_READREPLICA_HOSTS variable if it exists in the servicebroker credentials yaml
        if DB_READREPLICA_HOSTS=$(shyaml get-value data.DB_READREPLICA_HOSTS < "/oc-build-deploy/lagoon/${SERVICE_NAME}-servicebroker-credentials.yml" | base64 -d); then
          oc patch --insecure-skip-tls-verify \
            -n "$OPENSHIFT_PROJECT" \
            configmap lagoon-env \
            -p "{\"data\":{\"${SERVICE_NAME_UPPERCASE}_READREPLICA_HOSTS\":\"${DB_READREPLICA_HOSTS}\"}}"
        fi

        set -x
        ;;

    mongodb-dbaas)
        . /oc-build-deploy/scripts/exec-openshift-mongodb-dbaas.sh
        ;;

    *)
        echo "ServiceBroker Type ${SERVICE_TYPE} not implemented"; exit 1;

  esac
done

##############################################
### PUSH IMAGES TO OPENSHIFT REGISTRY
##############################################
if [[ $THIS_IS_TUG == "true" ]]; then
  # Allow to disable registry auth
  if [ ! "${TUG_SKIP_REGISTRY_AUTH}" == "true" ]; then
    # This adds the defined credentials to the serviceaccount/default so that the deployments can pull from the remote registry
    if oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get secret tug-registry 2> /dev/null; then
      oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} delete secret tug-registry
    fi
    oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} create secret docker-registry tug-registry --docker-server="${TUG_REGISTRY}" --docker-username="${TUG_REGISTRY_USERNAME}" --docker-password="${TUG_REGISTRY_PASSWORD}" --docker-email="${TUG_REGISTRY_USERNAME}"
    oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} secrets link default tug-registry --for=pull
  fi

  # Import all remote Images into ImageStreams
  readarray -t TUG_IMAGES < /oc-build-deploy/tug/images
  for TUG_IMAGE in "${TUG_IMAGES[@]}"
  do
    oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} tag --source=docker "${TUG_REGISTRY}/${TUG_REGISTRY_REPOSITORY}/${TUG_IMAGE_PREFIX}${TUG_IMAGE}:${SAFE_BRANCH}" "${TUG_IMAGE}:latest"
  done

elif [ "$TYPE" == "pullrequest" ] || [ "$TYPE" == "branch" ]; then

  # All images that should be pulled are copied to the openshift and harbor registry
  for IMAGE_NAME in "${!IMAGES_PULL[@]}"
  do
    PULL_IMAGE="${IMAGES_PULL[${IMAGE_NAME}]}"
    . /oc-build-deploy/scripts/exec-openshift-copy-to-registry.sh
  done

  for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
  do
    # Before the push the temporary name is resolved to the future tag with the registry in the image name
    TEMPORARY_IMAGE_NAME="${IMAGES_BUILD[${IMAGE_NAME}]}"

    # This will actually not push any images and instead just add them to the file /oc-build-deploy/lagoon/push
    . /oc-build-deploy/scripts/exec-push-parallel.sh
  done

  # If we have Images to Push to the OpenRegistry and Harbor, let's do so
  if [ -f /oc-build-deploy/lagoon/push ]; then
    parallel --retries 4 < /oc-build-deploy/lagoon/push
  fi

elif [ "$TYPE" == "promote" ]; then

  for IMAGE_NAME in "${IMAGES[@]}"
  do
    .  /oc-build-deploy/scripts/exec-openshift-tag.sh
  done

fi

# Load all Image Hashes for just pushed images
declare -A IMAGE_HASHES
parallel --retries 40 --results /tmp/istag oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get istag -o go-template --template='{{.image.dockerImageReference}}' {}:latest ::: ${IMAGES[@]}
for i in $(ls /tmp/istag/1); do
  IMAGE_HASHES[${i}]=$(cat /tmp/istag/1/${i}/stdout)
done

##############################################
### REDEPLOY DEPLOYMENTS IF CONFIG MAP CHANGES
##############################################

VARS_CONFIGMAP_SHA=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-api-vars -o yaml | shyaml get-value data "" | sha256sum | awk '{print $1}')
LAGOON_CONFIG_MAP_SHA=$(oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-env -o yaml | shyaml get-value data "" | sha256sum | awk '{print $1}')
CONFIG_MAP_SHA=$(echo $VARS_CONFIGMAP_SHA$LAGOON_CONFIG_MAP_SHA | sha256sum | awk '{print $1}')
# write the configmap value to a variable so when we `exec-openshift-resources-with-images.sh` the deploymentconfigs will get the value of the config map
# which will cause a change in the deployment and trigger a rollout if only the configmap has changed

##############################################
### CREATE PVC, DEPLOYMENTS AND CRONJOBS
##############################################

YAML_CONFIG_FILE="deploymentconfigs-pvcs-cronjobs-backups"

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do
  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_NAME_UPPERCASE=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

  COMPOSE_SERVICE=${MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_TYPES_ENTRY}"]}

  # Some Templates need additonal Parameters, like where persistent storage can be found.
  TEMPLATE_PARAMETERS=()

  PERSISTENT_STORAGE_CLASS=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.class false)
  if [ ! $PERSISTENT_STORAGE_CLASS == "false" ]; then
      TEMPLATE_PARAMETERS+=(-p PERSISTENT_STORAGE_CLASS="${PERSISTENT_STORAGE_CLASS}")
  fi

  PERSISTENT_STORAGE_SIZE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.size false)
  if [ ! $PERSISTENT_STORAGE_SIZE == "false" ]; then
      TEMPLATE_PARAMETERS+=(-p PERSISTENT_STORAGE_SIZE="${PERSISTENT_STORAGE_SIZE}")
  fi

  PERSISTENT_STORAGE_PATH=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent false)
  if [ ! $PERSISTENT_STORAGE_PATH == "false" ]; then
    TEMPLATE_PARAMETERS+=(-p PERSISTENT_STORAGE_PATH="${PERSISTENT_STORAGE_PATH}")

    PERSISTENT_STORAGE_NAME=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.name false)
    if [ ! $PERSISTENT_STORAGE_NAME == "false" ]; then
      TEMPLATE_PARAMETERS+=(-p PERSISTENT_STORAGE_NAME="${PERSISTENT_STORAGE_NAME}")
    fi
  fi

  DEPLOYMENT_STRATEGY=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.deployment\\.strategy false)
  if [ ! $DEPLOYMENT_STRATEGY == "false" ]; then
    TEMPLATE_PARAMETERS+=(-p DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY}")
  fi

  # Generate PVC if service type defines one
  OPENSHIFT_SERVICES_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/pvc.yml"
  if [ -f $OPENSHIFT_SERVICES_TEMPLATE ]; then
    OPENSHIFT_TEMPLATE=$OPENSHIFT_SERVICES_TEMPLATE
    PVC_NAME=$SERVICE_NAME
    if [ $SERVICE_TYPE == "mariadb-single" ]; then
      # mariadb creates PVCs with a `-data` suffix, adding that
      PVC_NAME=${SERVICE_NAME}-data
    fi
    . /oc-build-deploy/scripts/exec-openshift-create-pvc.sh
  fi

  # Generate Backup Definitions are supported and if service type defines one
  if oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get prebackuppod.backup.appuio.ch &> /dev/null; then
    OPENSHIFT_SERVICES_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/prebackuppod.yml"
    if [ -f $OPENSHIFT_SERVICES_TEMPLATE ]; then
      OPENSHIFT_TEMPLATE=$OPENSHIFT_SERVICES_TEMPLATE

      # Create a copy of TEMPLATE_PARAMETERS so we can restore it
      NO_SERVICE_NAME_UPPERCASE_PARAMETERS=(${TEMPLATE_PARAMETERS[@]})

      # prebackuppod templates need SERVICE_NAME_UPPERCASE
      TEMPLATE_PARAMETERS+=(-p SERVICE_NAME_UPPERCASE="${SERVICE_NAME_UPPERCASE}")

      . /oc-build-deploy/scripts/exec-openshift-resources-with-images.sh

      # restore TEMPLATE_PARAMETERS
      TEMPLATE_PARAMETERS=(${NO_SERVICE_NAME_UPPERCASE_PARAMETERS[@]})
    fi
  fi

  CRONJOB_COUNTER=0
  CRONJOBS_ARRAY_INSIDE_POD=()   #crons run inside an existing pod more frequently than every 15 minutes
  while [ -n "$(cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER 2> /dev/null)" ]
  do

    CRONJOB_SERVICE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.service)

    # Only implement the cronjob for the services we are currently handling
    if [ $CRONJOB_SERVICE == $SERVICE_NAME ]; then

      CRONJOB_NAME=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.name | sed "s/[^[:alnum:]-]/-/g" | sed "s/^-//g")

      CRONJOB_SCHEDULE_RAW=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.schedule)

      # Convert the Cronjob Schedule for additional features and better spread
      CRONJOB_SCHEDULE=$( /oc-build-deploy/scripts/convert-crontab.sh "${OPENSHIFT_PROJECT}" "$CRONJOB_SCHEDULE_RAW")
      CRONJOB_COMMAND=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.command)

      if cronScheduleMoreOftenThanXMinutes "$CRONJOB_SCHEDULE_RAW" ; then
        # If this cronjob is more often than 15 minutes, we run the cronjob inside the pod itself
        CRONJOBS_ARRAY_INSIDE_POD+=("${CRONJOB_SCHEDULE} ${CRONJOB_COMMAND}")
      else
        # This cronjob runs less ofen than every 15 minutes, we create a kubernetes native cronjob for it.
        OPENSHIFT_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/custom-cronjob.yml"

        # Add this cronjob to the native cleanup array, this will remove native cronjobs at the end of this script
        NATIVE_CRONJOB_CLEANUP_ARRAY+=($(echo "cronjob-${SERVICE_NAME}-${CRONJOB_NAME}" | awk '{print tolower($0)}'))
        # oc stores this cronjob name lowercased

        if [ ! -f $OPENSHIFT_TEMPLATE ]; then
          echo "No cronjob support for service '${SERVICE_NAME}' with type '${SERVICE_TYPE}', please contact the Lagoon maintainers to implement cronjob support"; exit 1;
        else

          # Create a copy of TEMPLATE_PARAMETERS so we can restore it
          NO_CRON_PARAMETERS=(${TEMPLATE_PARAMETERS[@]})

          TEMPLATE_PARAMETERS+=(-p CRONJOB_NAME="${CRONJOB_NAME,,}")
          TEMPLATE_PARAMETERS+=(-p CRONJOB_SCHEDULE="${CRONJOB_SCHEDULE}")
          TEMPLATE_PARAMETERS+=(-p CRONJOB_COMMAND="${CRONJOB_COMMAND}")

          . /oc-build-deploy/scripts/exec-openshift-resources-with-images.sh

          # restore template parameters without any cronjobs in them (allows to create a secondary cronjob, plus also any other templates)
          TEMPLATE_PARAMETERS=(${NO_CRON_PARAMETERS[@]})

        fi
      fi
    fi

    let CRONJOB_COUNTER=CRONJOB_COUNTER+1
  done


  # if there are cronjobs running inside pods, add them to the deploymentconfig.
  if [[ ${#CRONJOBS_ARRAY_INSIDE_POD[@]} -ge 1 ]]; then
    CRONJOBS_ONELINE=$(printf "%s\\n" "${CRONJOBS_ARRAY_INSIDE_POD[@]}")
    TEMPLATE_PARAMETERS+=(-p CRONJOBS="${CRONJOBS_ONELINE}")
  fi

  OVERRIDE_TEMPLATE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.template false)
  ENVIRONMENT_OVERRIDE_TEMPLATE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.templates.$SERVICE_NAME false)
  if [[ "${OVERRIDE_TEMPLATE}" == "false" && "${ENVIRONMENT_OVERRIDE_TEMPLATE}" == "false" ]]; then # No custom template defined in docker-compose or .lagoon.yml,  using the given service ones
    # Generate deployment if service type defines it
    OPENSHIFT_DEPLOYMENT_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/deployment.yml"
    if [ -f $OPENSHIFT_DEPLOYMENT_TEMPLATE ]; then
      OPENSHIFT_TEMPLATE=$OPENSHIFT_DEPLOYMENT_TEMPLATE
      . /oc-build-deploy/scripts/exec-openshift-resources-with-images.sh
    fi

    # Generate statefulset if service type defines it
    OPENSHIFT_STATEFULSET_TEMPLATE="/oc-build-deploy/openshift-templates/${SERVICE_TYPE}/statefulset.yml"
    if [ -f $OPENSHIFT_STATEFULSET_TEMPLATE ]; then
      OPENSHIFT_TEMPLATE=$OPENSHIFT_STATEFULSET_TEMPLATE
      . /oc-build-deploy/scripts/exec-openshift-resources-with-images.sh
    fi
  elif [[ "${ENVIRONMENT_OVERRIDE_TEMPLATE}" != "false" ]]; then # custom template defined for this service in .lagoon.yml, trying to use it

    OPENSHIFT_TEMPLATE=$ENVIRONMENT_OVERRIDE_TEMPLATE
    if [ ! -f $OPENSHIFT_TEMPLATE ]; then
      echo "defined template $OPENSHIFT_TEMPLATE for service $SERVICE_TYPE in .lagoon.yml not found"; exit 1;
    else
      . /oc-build-deploy/scripts/exec-openshift-resources-with-images.sh
    fi
  elif [[ "${OVERRIDE_TEMPLATE}" != "false" ]]; then # custom template defined for this service in docker-compose, trying to use it

    OPENSHIFT_TEMPLATE=$OVERRIDE_TEMPLATE
    if [ ! -f $OPENSHIFT_TEMPLATE ]; then
      echo "defined template $OPENSHIFT_TEMPLATE for service $SERVICE_TYPE in $DOCKER_COMPOSE_YAML not found"; exit 1;
    else
      . /oc-build-deploy/scripts/exec-openshift-resources-with-images.sh
    fi
  fi

done

##############################################
### APPLY RESOURCES
##############################################

if [ -f /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml ]; then

  # During CI tests of Lagoon itself we only have a single compute node, so we change podAntiAffinity to podAffinity
  if [ "$CI" == "true" ]; then
    sed -i s/podAntiAffinity/podAffinity/g /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml
  fi

  # If this is openshift 3.9, remove all occurences of priorityClassName
  if oc version | grep openshift | awk '{print $2}' | grep -q "v3\.9.*"; then
    sed -i /priorityClassName/d /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml
  fi

  oc apply --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} -f /oc-build-deploy/lagoon/${YAML_CONFIG_FILE}.yml
fi

##############################################
### WAIT FOR POST-ROLLOUT TO BE FINISHED
##############################################

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do

  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_ROLLOUT_TYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.${SERVICE_NAME}.labels.lagoon\\.rollout deploymentconfigs)

  # Allow the rollout type to be overriden by environment in .lagoon.yml
  ENVIRONMENT_SERVICE_ROLLOUT_TYPE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.rollouts.${SERVICE_NAME} false)
  if [ ! $ENVIRONMENT_SERVICE_ROLLOUT_TYPE == "false" ]; then
    SERVICE_ROLLOUT_TYPE=$ENVIRONMENT_SERVICE_ROLLOUT_TYPE
  fi

  if [ $SERVICE_TYPE == "elasticsearch-cluster" ]; then

    STATEFULSET="${SERVICE_NAME}"
    . /oc-build-deploy/scripts/exec-monitor-statefulset.sh

  elif [ $SERVICE_TYPE == "rabbitmq-cluster" ]; then

    STATEFULSET="${SERVICE_NAME}"
    . /oc-build-deploy/scripts/exec-monitor-statefulset.sh

  elif [ $SERVICE_ROLLOUT_TYPE == "statefulset" ]; then

    STATEFULSET="${SERVICE_NAME}"
    . /oc-build-deploy/scripts/exec-monitor-statefulset.sh

  elif [ $SERVICE_ROLLOUT_TYPE == "deamonset" ]; then

    DAEMONSET="${SERVICE_NAME}"
    . /oc-build-deploy/scripts/exec-monitor-deamonset.sh

  elif [ $SERVICE_TYPE == "mariadb-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ $SERVICE_TYPE == "mariadb-shared" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ $SERVICE_TYPE == "mongodb-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ ! $SERVICE_ROLLOUT_TYPE == "false" ]; then
    . /oc-build-deploy/scripts/exec-monitor-deploy.sh
  fi
done


##############################################
### CLEANUP NATIVE CRONJOBS which have been removed from .lagoon.yml or modified to run more frequently than every 15 minutes
##############################################

CURRENT_CRONJOBS=$(oc -n ${OPENSHIFT_PROJECT} get cronjobs --no-headers | cut -d " " -f 1 | xargs)

IFS=' ' read -a SPLIT_CURRENT_CRONJOBS <<< $CURRENT_CRONJOBS

for SINGLE_NATIVE_CRONJOB in ${SPLIT_CURRENT_CRONJOBS[@]}
do
  re="\<$SINGLE_NATIVE_CRONJOB\>"
  text=$( IFS=' '; echo "${NATIVE_CRONJOB_CLEANUP_ARRAY[*]}")
  if [[ "$text" =~ $re ]]; then
    #echo "Single cron found: ${SINGLE_NATIVE_CRONJOB}"
    continue
  else
    #echo "Single cron missing: ${SINGLE_NATIVE_CRONJOB}"
    oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} delete cronjob ${SINGLE_NATIVE_CRONJOB}
  fi
done

##############################################
### RUN POST-ROLLOUT tasks defined in .lagoon.yml
##############################################

# if we have LAGOON_POSTROLLOUT_DISABLED set, don't try to run any pre-rollout tasks
if [ "${LAGOON_POSTROLLOUT_DISABLED}" != "true" ]; then
  COUNTER=0
  while [ -n "$(cat .lagoon.yml | shyaml keys tasks.post-rollout.$COUNTER 2> /dev/null)" ]
  do
    TASK_TYPE=$(cat .lagoon.yml | shyaml keys tasks.post-rollout.$COUNTER)
    echo $TASK_TYPE
    case "$TASK_TYPE" in
      run)
          COMMAND=$(cat .lagoon.yml | shyaml get-value tasks.post-rollout.$COUNTER.$TASK_TYPE.command)
          SERVICE_NAME=$(cat .lagoon.yml | shyaml get-value tasks.post-rollout.$COUNTER.$TASK_TYPE.service)
          CONTAINER=$(cat .lagoon.yml | shyaml get-value tasks.post-rollout.$COUNTER.$TASK_TYPE.container false)
          SHELL=$(cat .lagoon.yml | shyaml get-value tasks.post-rollout.$COUNTER.$TASK_TYPE.shell sh)
          . /oc-build-deploy/scripts/exec-tasks-run.sh
          ;;
      *)
          echo "Task Type ${TASK_TYPE} not implemented"; exit 1;

    esac

    let COUNTER=COUNTER+1
  done
else
  echo "post-rollout tasks are currently disabled LAGOON_POSTROLLOUT_DISABLED is set to true"
fi

##############################################
### PUSH the latest .lagoon.yml into lagoon-yaml configmap
##############################################

if oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} get configmap lagoon-yaml &> /dev/null; then
  # replace it
  oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} create configmap lagoon-yaml --from-file=.lagoon.yml -o yaml --dry-run | oc replace -f -
else
  # create it
  oc --insecure-skip-tls-verify -n ${OPENSHIFT_PROJECT} create configmap lagoon-yaml --from-file=.lagoon.yml
fi
