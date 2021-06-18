#!/bin/bash

function cronScheduleMoreOftenThan30Minutes() {
  #takes a unexpanded cron schedule, returns 0 if it's more often that 30 minutes
  MINUTE=$(echo $1 | (read -a ARRAY; echo ${ARRAY[0]}) )
  if [[ $MINUTE =~ ^(M|H|\*)\/([0-5]?[0-9])$ ]]; then
    # Match found for M/xx, H/xx or */xx
    # Check if xx is smaller than 30, which means this cronjob runs more often than every 30 minutes.
    STEP=${BASH_REMATCH[2]}
    if [ $STEP -lt 30 ]; then
      return 0
    else
      return 1
    fi
  elif [[ $MINUTE =~ ^\*$ ]]; then
    # We are running every minute
    return 0
  else
    # all other cases are more often than 30 minutes
    return 1
  fi
}

function contains() {
    [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]] && return 0 || return 1
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
DBAAS=()
declare -A MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME
declare -A MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE
declare -A MAP_SERVICE_NAME_TO_IMAGENAME
declare -A MAP_SERVICE_NAME_TO_SERVICEBROKER_CLASS
declare -A MAP_SERVICE_NAME_TO_SERVICEBROKER_PLAN
declare -A MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT
declare -A IMAGES_PULL
declare -A IMAGES_BUILD
declare -A IMAGE_HASHES


HELM_ARGUMENTS=()
. /kubectl-build-deploy/scripts/kubectl-get-cluster-capabilities.sh
for CAPABILITIES in "${CAPABILITIES[@]}"; do
  HELM_ARGUMENTS+=(-a "${CAPABILITIES}")
done

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

  # Previous versions of Lagoon used "python-ckandatapusher", this should be mapped to "python"
  if [[ "$SERVICE_TYPE" == "python-ckandatapusher" ]]; then
    SERVICE_TYPE="python"
  fi

  # "mariadb" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - mariadb-single (a single mariadb pod)
  # - mariadb-dbaas (use the dbaas shared operator)
  if [ "$SERVICE_TYPE" == "mariadb" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # mariadb-single deployed (probably from the past where there was no mariadb-shared yet, or mariadb-dbaas) and use that one
    if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="mariadb-single"
    # check if this cluster supports the default one, if not we assume that this cluster is not capable of shared mariadbs and we use a mariadb-single
    # real basic check to see if the mariadbconsumer exists as a kind
    elif [[ "${CAPABILITIES[@]}" =~ "mariadb.amazee.io/v1/MariaDBConsumer" ]]; then
      SERVICE_TYPE="mariadb-dbaas"
    else
      SERVICE_TYPE="mariadb-single"
    fi

  fi

  # Previous versions of Lagoon supported "mariadb-shared", this has been superseeded by "mariadb-dbaas"
  if [[ "$SERVICE_TYPE" == "mariadb-shared" ]]; then
    SERVICE_TYPE="mariadb-dbaas"
  fi

  if [[ "$SERVICE_TYPE" == "mariadb-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.mariadb-dbaas\\.environment "${ENVIRONMENT_TYPE}")

    # Allow the dbaas shared servicebroker plan to be overriden by environment in .lagoon.yml
    ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$SERVICE_NAME.mariadb-dbaas\\.environment false)
    if [ ! $DBAAS_ENVIRONMENT_OVERRIDE == "false" ]; then
      DBAAS_ENVIRONMENT=$ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE
    fi

    # If we have a dbaas environment type override in the api, consume it here
    if [ ! -z "$LAGOON_DBAAS_ENVIRONMENT_TYPES" ]; then
      IFS=',' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPES"
      for LAGOON_DBAAS_ENVIRONMENT_TYPE in "${LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT[@]}"
      do
        IFS=':' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPE"
        if [ "${LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT[0]}" == "$SERVICE_NAME" ]; then
          DBAAS_ENVIRONMENT=${LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT[1]}
        fi
      done
    fi

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="${DBAAS_ENVIRONMENT}"
  fi

  # "postgres" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - postgres-single (a single postgres pod)
  # - postgres-dbaas (use the dbaas shared operator)
  if [ "$SERVICE_TYPE" == "postgres" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # postgres-single deployed (probably from the past where there was no postgres-shared yet, or postgres-dbaas) and use that one
    if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="postgres-single"
    # heck if this cluster supports the default one, if not we assume that this cluster is not capable of shared PostgreSQL and we use a postgres-single
    # real basic check to see if the postgreSQLConsumer exists as a kind
    elif [[ "${CAPABILITIES[@]}" =~ "postgres.amazee.io/v1/PostgreSQLConsumer" ]]; then
      SERVICE_TYPE="postgres-dbaas"
    else
      SERVICE_TYPE="postgres-single"
    fi

  fi

  # Previous versions of Lagoon supported "postgres-shared", this has been superseeded by "postgres-dbaas"
  if [[ "$SERVICE_TYPE" == "postgres-shared" ]]; then
    SERVICE_TYPE="postgres-dbaas"
  fi

  if [[ "$SERVICE_TYPE" == "postgres-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.postgres-dbaas\\.environment "${ENVIRONMENT_TYPE}")

    # Allow the dbaas shared servicebroker plan to be overriden by environment in .lagoon.yml
    ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$SERVICE_NAME.postgres-dbaas\\.environment false)
    if [ ! $DBAAS_ENVIRONMENT_OVERRIDE == "false" ]; then
      DBAAS_ENVIRONMENT=$ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE
    fi

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="${DBAAS_ENVIRONMENT}"
  fi

  # "mongo" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - mongodb-single (a single mongodb pod)
  # - mongodb-dbaas (use the dbaas shared operator)
  if [ "$SERVICE_TYPE" == "mongo" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # mongodb-single deployed (probably from the past where there was no mongodb-shared yet, or mongodb-dbaas) and use that one
    if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="mongodb-single"
    # heck if this cluster supports the default one, if not we assume that this cluster is not capable of shared MongoDB and we use a mongodb-single
    # real basic check to see if the MongoDBConsumer exists as a kind
    elif [[ "${CAPABILITIES[@]}" =~ "mongodb.amazee.io/v1/MongoDBConsumer" ]]; then
      SERVICE_TYPE="mongodb-dbaas"
    else
      SERVICE_TYPE="mongodb-single"
    fi

  fi

  # Previous versions of Lagoon supported "mongo-shared", this has been superseeded by "mongodb-dbaas"
  if [[ "$SERVICE_TYPE" == "mongo-shared" ]]; then
    SERVICE_TYPE="mongodb-dbaas"
  fi

  # Previous versions of Lagoon supported "mongodb-shared", this has been superseeded by "mongodb-dbaas"
  if [[ "$SERVICE_TYPE" == "mongodb-shared" ]]; then
    SERVICE_TYPE="mongodb-dbaas"
  fi

  if [[ "$SERVICE_TYPE" == "mongodb-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.mongodb-dbaas\\.environment "${ENVIRONMENT_TYPE}")

    # Allow the dbaas shared servicebroker plan to be overriden by environment in .lagoon.yml
    ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$SERVICE_NAME.mongodb-dbaas\\.environment false)
    if [ ! $DBAAS_ENVIRONMENT_OVERRIDE == "false" ]; then
      DBAAS_ENVIRONMENT=$ENVIRONMENT_DBAAS_ENVIRONMENT_OVERRIDE
    fi

    # If we have a dbaas environment type override in the api, consume it here
    if [ ! -z "$LAGOON_DBAAS_ENVIRONMENT_TYPES" ]; then
      IFS=',' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPES"
      for LAGOON_DBAAS_ENVIRONMENT_TYPE in "${LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT[@]}"
      do
        IFS=':' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPE"
        if [ "${LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT[0]}" == "$SERVICE_NAME" ]; then
          DBAAS_ENVIRONMENT=${LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT[1]}
        fi
      done
    fi

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="${DBAAS_ENVIRONMENT}"
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
      [[ "$SERVICE_TYPE" != "postgres-shared" ]] &&
      [[ "$SERVICE_TYPE" != "postgres-dbaas" ]] &&
      [[ "$SERVICE_TYPE" != "mongodb-dbaas" ]] &&
      [[ "$SERVICE_TYPE" != "mongodb-shared" ]]; then
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
### BUILD IMAGES
##############################################

# we only need to build images for pullrequests and branches, but not during a TUG build
if [[ ( "$BUILD_TYPE" == "pullrequest"  ||  "$BUILD_TYPE" == "branch" ) && ! $THIS_IS_TUG == "true" ]]; then

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
  BUILD_ARGS+=(--build-arg LAGOON_PROJECT="${PROJECT}")
  BUILD_ARGS+=(--build-arg LAGOON_ENVIRONMENT="${ENVIRONMENT}")
  BUILD_ARGS+=(--build-arg LAGOON_ENVIRONMENT_TYPE="${ENVIRONMENT_TYPE}")
  BUILD_ARGS+=(--build-arg LAGOON_BUILD_TYPE="${BUILD_TYPE}")
  BUILD_ARGS+=(--build-arg LAGOON_GIT_SOURCE_REPOSITORY="${SOURCE_REPOSITORY}")

  set +x
  BUILD_ARGS+=(--build-arg LAGOON_SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY}")
  set -x

  if [ "$BUILD_TYPE" == "branch" ]; then
    BUILD_ARGS+=(--build-arg LAGOON_GIT_SHA="${LAGOON_GIT_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_GIT_BRANCH="${BRANCH}")
  fi

  if [ "$BUILD_TYPE" == "pullrequest" ]; then
    BUILD_ARGS+=(--build-arg LAGOON_PR_HEAD_BRANCH="${PR_HEAD_BRANCH}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_HEAD_SHA="${PR_HEAD_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_BASE_BRANCH="${PR_BASE_BRANCH}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_BASE_SHA="${PR_BASE_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_TITLE="${PR_TITLE}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_NUMBER="${PR_NUMBER}")
  fi

  for IMAGE_NAME in "${IMAGES[@]}"
  do

    DOCKERFILE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.dockerfile false)

    # allow to overwrite build dockerfile for this environment and service
    ENVIRONMENT_DOCKERFILE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$IMAGE_NAME.build.dockerfile false)
    if [ ! $ENVIRONMENT_DOCKERFILE_OVERRIDE == "false" ]; then
      DOCKERFILE=$ENVIRONMENT_DOCKERFILE_OVERRIDE
    fi

    if [ $DOCKERFILE == "false" ]; then
      # No Dockerfile defined, assuming to download the Image directly

      PULL_IMAGE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.image false)
      if [ $PULL_IMAGE == "false" ]; then
        echo "No Dockerfile or Image for service ${IMAGE_NAME} defined"; exit 1;
      fi

      # allow to overwrite image that we pull
      OVERRIDE_IMAGE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.labels.lagoon\\.image false)

      # allow to overwrite image that we pull for this environment and service
      ENVIRONMENT_IMAGE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$IMAGE_NAME.image false)
      if [ ! $ENVIRONMENT_IMAGE_OVERRIDE == "false" ]; then
        OVERRIDE_IMAGE=$ENVIRONMENT_IMAGE_OVERRIDE
      fi

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
      TEMPORARY_IMAGE_NAME="${NAMESPACE}-${IMAGE_NAME}"

      BUILD_CONTEXT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.context .)

      # allow to overwrite build context for this environment and service
      ENVIRONMENT_BUILD_CONTEXT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$IMAGE_NAME.build.context false)
      if [ ! $ENVIRONMENT_BUILD_CONTEXT_OVERRIDE == "false" ]; then
        BUILD_CONTEXT=$ENVIRONMENT_BUILD_CONTEXT_OVERRIDE
      fi

      if [ ! -f $BUILD_CONTEXT/$DOCKERFILE ]; then
        echo "defined Dockerfile $DOCKERFILE for service $IMAGE_NAME not found"; exit 1;
      fi

      . /kubectl-build-deploy/scripts/exec-build.sh

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
echo "TODO: lagoon-tug is not implemented yet in kubernetes"
exit 1
  . /kubectl-build-deploy/tug/tug-build-push.sh

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
          . /kubectl-build-deploy/scripts/exec-pre-tasks-run.sh
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
### CREATE OPENSHIFT SERVICES, ROUTES and SERVICEBROKERS  PART 1
##############################################

YAML_FOLDER="/kubectl-build-deploy/lagoon/services-routes"
mkdir -p $YAML_FOLDER

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
ROUTES_AUTOGENERATE_ALLOW_PRS=$(set -o pipefail; cat .lagoon.yml | shyaml get-value routes.autogenerate.allowPullrequests $ROUTES_AUTOGENERATE_ENABLED | tr '[:upper:]' '[:lower:]')
if [[ "$TYPE" == "pullrequest" && "$ROUTES_AUTOGENERATE_ALLOW_PRS" == "true" ]]; then
  ROUTES_AUTOGENERATE_ENABLED=true
fi
## fail silently if the key autogenerateRoutes doesn't exist and default to whatever ROUTES_AUTOGENERATE_ENABLED is set to
ROUTES_AUTOGENERATE_BRANCH=$(set -o pipefail; cat .lagoon.yml | shyaml -q get-value environments.${BRANCH//./\\.}.autogenerateRoutes $ROUTES_AUTOGENERATE_ENABLED | tr '[:upper:]' '[:lower:]')
if [[ "$ROUTES_AUTOGENERATE_BRANCH" == "true" ]]; then
  ROUTES_AUTOGENERATE_ENABLED=true
fi

ROUTES_AUTOGENERATE_PREFIXES=$(yq r -C .lagoon.yml routes.autogenerate.prefixes.*)

touch /kubectl-build-deploy/values.yaml

yq write -i -- /kubectl-build-deploy/values.yaml 'project' $PROJECT
yq write -i -- /kubectl-build-deploy/values.yaml 'environment' $ENVIRONMENT
yq write -i -- /kubectl-build-deploy/values.yaml 'environmentType' $ENVIRONMENT_TYPE
yq write -i -- /kubectl-build-deploy/values.yaml 'namespace' $NAMESPACE
yq write -i -- /kubectl-build-deploy/values.yaml 'gitSha' $LAGOON_GIT_SHA
yq write -i -- /kubectl-build-deploy/values.yaml 'buildType' $BUILD_TYPE
yq write -i -- /kubectl-build-deploy/values.yaml 'routesAutogenerateInsecure' $ROUTES_AUTOGENERATE_INSECURE
yq write -i -- /kubectl-build-deploy/values.yaml 'routesAutogenerateEnabled' $ROUTES_AUTOGENERATE_ENABLED
yq write -i -- /kubectl-build-deploy/values.yaml 'routesAutogenerateSuffix' $ROUTER_URL
yq write -i -- /kubectl-build-deploy/values.yaml 'routesAutogenerateShortSuffix' $SHORT_ROUTER_URL
for i in $ROUTES_AUTOGENERATE_PREFIXES; do yq write -i -- /kubectl-build-deploy/values.yaml 'routesAutogeneratePrefixes[+]' $i; done
yq write -i -- /kubectl-build-deploy/values.yaml 'kubernetes' $KUBERNETES
yq write -i -- /kubectl-build-deploy/values.yaml 'lagoonVersion' $LAGOON_VERSION


echo -e "\
imagePullSecrets:\n\
" >> /kubectl-build-deploy/values.yaml

for REGISTRY_SECRET in "${REGISTRY_SECRETS[@]}"
do
  echo -e "\
  - name: "${REGISTRY_SECRET}"\n\
" >> /kubectl-build-deploy/values.yaml
done

echo -e "\
LAGOON_PROJECT=${PROJECT}\n\
LAGOON_ENVIRONMENT=${ENVIRONMENT}\n\
LAGOON_ENVIRONMENT_TYPE=${ENVIRONMENT_TYPE}\n\
LAGOON_GIT_SHA=${LAGOON_GIT_SHA}\n\
LAGOON_KUBERNETES=${KUBERNETES}\n\
" >> /kubectl-build-deploy/values.env

# DEPRECATED: will be removed with Lagoon 3.0.0
# LAGOON_GIT_SAFE_BRANCH is pointing to the enviornment name, therefore also is filled if this environment
# is created by a PR or Promote workflow. This technically wrong, therefore will be removed
echo -e "\
LAGOON_GIT_SAFE_BRANCH=${ENVIRONMENT}\n\
" >> /kubectl-build-deploy/values.env

if [ "$BUILD_TYPE" == "branch" ]; then
  yq write -i -- /kubectl-build-deploy/values.yaml 'branch' $BRANCH

  echo -e "\
LAGOON_GIT_BRANCH=${BRANCH}\n\
" >> /kubectl-build-deploy/values.env
fi

if [ "$BUILD_TYPE" == "pullrequest" ]; then
  yq write -i -- /kubectl-build-deploy/values.yaml 'prHeadBranch' "$PR_HEAD_BRANCH"
  yq write -i -- /kubectl-build-deploy/values.yaml 'prBaseBranch' "$PR_BASE_BRANCH"
  yq write -i -- /kubectl-build-deploy/values.yaml 'prTitle' "$PR_TITLE"
  yq write -i -- /kubectl-build-deploy/values.yaml 'prNumber' "$PR_NUMBER"

  echo -e "\
LAGOON_PR_HEAD_BRANCH=${PR_HEAD_BRANCH}\n\
LAGOON_PR_BASE_BRANCH=${PR_BASE_BRANCH}\n\
LAGOON_PR_TITLE=${PR_TITLE}\n\
LAGOON_PR_NUMBER=${PR_NUMBER}\n\
" >> /kubectl-build-deploy/values.env
fi

##############################################
### CUSTOM FASTLY API SECRETS .lagoon.yml
##############################################

# if a customer is using their own fastly configuration, then they can define their api token and platform tls configuration ID in the .lagoon.yml file
# this will get created as a `kind: Secret` in kubernetes so that created ingresses will be able to use this secret to talk to the fastly api.
#
# in this example, the customer needs to add a build envvar called `FASTLY_API_TOKEN` and then populates the .lagoon.yml file with something like this
#
# fastly:
#   api-secrets:
#     - name: customer
#       apiTokenVariableName: FASTLY_API_TOKEN
#       platformTLSConfiguration: A1bcEdFgH12eD242Sds
#
# then the build process will attempt to check the lagoon variables for one called `FASTLY_API_TOKEN` and will use the value of this variable when creating the
# `kind: Secret` in kubernetes
#
# support for multiple api-secrets is possible in the instance that a customer uses 2 separate services in different accounts in the one project

## any fastly api secrets will be prefixed with this, so that we always add this to whatever the customer provides
FASTLY_API_SECRET_PREFIX="fastly-api-"

FASTLY_API_SECRETS_COUNTER=0
FASTLY_API_SECRETS=()
if [ -n "$(cat .lagoon.yml | shyaml keys fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER 2> /dev/null)" ]; then
  while [ -n "$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER 2> /dev/null)" ]; do
    FASTLY_API_SECRET_NAME=$FASTLY_API_SECRET_PREFIX$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER.name 2> /dev/null)
    if [ -z "$FASTLY_API_SECRET_NAME" ]; then
        echo -e "A fastly api secret was defined in the .lagoon.yml file, but no name could be found the .lagoon.yml\n\nPlease check if the name has been set correctly."
        exit 1
    fi
    FASTLY_API_TOKEN_VALUE=$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER.apiTokenVariableName false)
    if [[ $FASTLY_API_TOKEN_VALUE == "false" ]]; then
      echo "No 'apiTokenVariableName' defined for fastly secret $FASTLY_API_SECRET_NAME"; exit 1;
    fi
    # if we have everything we need, we can proceed to logging in
    if [ $FASTLY_API_TOKEN_VALUE != "false" ]; then
      FASTLY_API_TOKEN=""
      # check if we have a password defined anywhere in the api first
      if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
        FASTLY_API_TOKEN=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build" and .name == "'$FASTLY_API_TOKEN_VALUE'") | "\(.value)"'))
      fi
      if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
        TEMP_FASTLY_API_TOKEN=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build" and .name == "'$FASTLY_API_TOKEN_VALUE'") | "\(.value)"'))
        if [ ! -z "$TEMP_FASTLY_API_TOKEN" ]; then
          FASTLY_API_TOKEN=$TEMP_FASTLY_API_TOKEN
        fi
      fi
      if [ -z "$FASTLY_API_TOKEN" ]; then
        echo -e "A fastly api secret was defined in the .lagoon.yml file, but no token could be found in the Lagoon API matching the variable name provided\n\nPlease check if the token has been set correctly."
        exit 1
      fi
    fi
    FASTLY_API_PLATFORMTLS_CONFIGURATION=$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER.platformTLSConfiguration "")
    if [ -z "$FASTLY_API_PLATFORMTLS_CONFIGURATION" ]; then
      echo -e "A fastly api secret was defined in the .lagoon.yml file, but no platform tls configuration id could be found in the .lagoon.yml\n\nPlease check if the platform tls configuration id has been set correctly."
      exit 1
    fi

    # run the script to create the secrets
    . /kubectl-build-deploy/scripts/exec-fastly-api-secrets.sh

    let FASTLY_API_SECRETS_COUNTER=FASTLY_API_SECRETS_COUNTER+1
  done
fi

# FASTLY API SECRETS FROM LAGOON API VARIABLE
# Allow for defining fastly api secrets using lagoon api variables
# This accepts colon separated values like so `SECRET_NAME:FASTLY_API_TOKEN:FASTLY_PLATFORMTLS_CONFIGURATION_ID`, and multiple overrides
# separated by commas
# Example 1: examplecom:x1s8asfafasf7ssf:fa23rsdgsdgas
# ^^^ will create a kubernetes secret called `$FASTLY_API_SECRET_PREFIX-examplecom` with 2 data fields (one for api token, the other for platform tls id)
# populated with `x1s8asfafasf7ssf` and `fa23rsdgsdgas` for whichever field it should be
# and the name will get created with the prefix defined in `FASTLY_API_SECRET_PREFIX`
# Example 2: examplecom:x1s8asfafasf7ssf:fa23rsdgsdgas,example2com:fa23rsdgsdgas:x1s8asfafasf7ssf,example3com:fa23rsdgsdgas:x1s8asfafasf7ssf:example3com
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_FASTLY_API_SECRETS=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_API_SECRETS") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_FASTLY_API_SECRETS=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_API_SECRETS") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_FASTLY_API_SECRETS ]; then
    LAGOON_FASTLY_API_SECRETS=$TEMP_LAGOON_FASTLY_API_SECRETS
  fi
fi
if [ ! -z "$LAGOON_FASTLY_API_SECRETS" ]; then
  IFS=',' read -ra LAGOON_FASTLY_API_SECRETS_SPLIT <<< "$LAGOON_FASTLY_API_SECRETS"
  for LAGOON_FASTLY_API_SECRETS_DATA in "${LAGOON_FASTLY_API_SECRETS_SPLIT[@]}"
  do
    IFS=':' read -ra LAGOON_FASTLY_API_SECRET_SPLIT <<< "$LAGOON_FASTLY_API_SECRETS_DATA"
    if [ -z "${LAGOON_FASTLY_API_SECRET_SPLIT[0]}" ] || [ -z "${LAGOON_FASTLY_API_SECRET_SPLIT[1]}" ] || [ -z "${LAGOON_FASTLY_API_SECRET_SPLIT[2]}" ]; then
      echo -e "An override was defined in the lagoon API with LAGOON_FASTLY_API_SECRETS but was not structured correctly, the format should be NAME:FASTLY_API_TOKEN:FASTLY_PLATFORMTLS_CONFIGURATION_ID and comma separated for multiples"
      exit 1
    fi
    # the fastly api secret name will be created with the prefix that is defined above
    FASTLY_API_SECRET_NAME=$FASTLY_API_SECRET_PREFIX${LAGOON_FASTLY_API_SECRET_SPLIT[0]}
    FASTLY_API_TOKEN=${LAGOON_FASTLY_API_SECRET_SPLIT[1]}
    FASTLY_API_PLATFORMTLS_CONFIGURATION=${LAGOON_FASTLY_API_SECRET_SPLIT[2]}
    # run the script to create the secrets
    . /kubectl-build-deploy/scripts/exec-fastly-api-secrets.sh
  done
fi

# FASTLY SERVICE ID PER INGRESS OVERRIDE FROM LAGOON API VARIABLE
# Allow the fastly serviceid for specific ingress to be overridden by the lagoon API
# This accepts colon separated values like so `INGRESS_DOMAIN:FASTLY_SERVICE_ID:WATCH_STATUS:SECRET_NAME(OPTIONAL)`, and multiple overrides
# separated by commas
# Example 1: www.example.com:x1s8asfafasf7ssf:true
# ^^^ tells the ingress creation to use the service id x1s8asfafasf7ssf for ingress www.example.com, with the watch status of true
# Example 2: www.example.com:x1s8asfafasf7ssf:true,www.not-example.com:fa23rsdgsdgas:false
# ^^^ same as above, but also tells the ingress creation to use the service id fa23rsdgsdgas for ingress www.not-example.com, with the watch status of false
# Example 3: www.example.com:x1s8asfafasf7ssf:true:examplecom
# ^^^ tells the ingress creation to use the service id x1s8asfafasf7ssf for ingress www.example.com, with the watch status of true
# but it will also be annotated to be told to use the secret named `examplecom` that could be defined elsewhere
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_FASTLY_SERVICE_IDS=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_SERVICE_IDS") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_FASTLY_SERVICE_IDS=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_SERVICE_IDS") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_FASTLY_SERVICE_IDS ]; then
    LAGOON_FASTLY_SERVICE_IDS=$TEMP_LAGOON_FASTLY_SERVICE_IDS
  fi
fi

##############################################
### CREATE OPENSHIFT SERVICES, ROUTES and SERVICEBROKERS PART 2
##############################################

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do
  echo "=== BEGIN route processing for service ${SERVICE_TYPES_ENTRY} ==="
  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  TEMPLATE_PARAMETERS=()

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  touch /kubectl-build-deploy/${SERVICE_NAME}-values.yaml

  HELM_SERVICE_TEMPLATE="templates/service.yaml"
  if [ -f /kubectl-build-deploy/helmcharts/${SERVICE_TYPE}/$HELM_SERVICE_TEMPLATE ]; then
    cat /kubectl-build-deploy/values.yaml
    helm template ${SERVICE_NAME} /kubectl-build-deploy/helmcharts/${SERVICE_TYPE} -s $HELM_SERVICE_TEMPLATE -f /kubectl-build-deploy/values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${SERVICE_NAME}.yaml
  fi

  if [ $ROUTES_AUTOGENERATE_ENABLED == "true" ]; then
    HELM_INGRESS_TEMPLATE="templates/ingress.yaml"
    if [ -f /kubectl-build-deploy/helmcharts/${SERVICE_TYPE}/$HELM_INGRESS_TEMPLATE ]; then

      # The very first generated route is set as MAIN_GENERATED_ROUTE
      if [ -z "${MAIN_GENERATED_ROUTE+x}" ]; then
        MAIN_GENERATED_ROUTE=$SERVICE_NAME
      fi


      ROUTE_FASTLY_SERVICE_WATCH=false
      # if the builddeploy controller is injecting a featureflag value, load it in
      if [ -z $LAGOON_FASTLY_AUTOGENERATED_FEATURE_FLAG ]; then
        LAGOON_FASTLY_AUTOGENERATED=$LAGOON_FASTLY_AUTOGENERATED_FEATURE_FLAG
      fi
      # if the lagoon api has an envvar override, use it instead
      if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
        LAGOON_FASTLY_AUTOGENERATED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_AUTOGENERATED") | "\(.value)"'))
      fi
      if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
        TEMP_LAGOON_FASTLY_AUTOGENERATED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_AUTOGENERATED") | "\(.value)"'))
        if [ ! -z $TEMP_LAGOON_FASTLY_AUTOGENERATED ]; then
          LAGOON_FASTLY_AUTOGENERATED=$TEMP_LAGOON_FASTLY_AUTOGENERATED
        fi
      fi
      # Create the fastly values required
      FASTLY_ARGS=()
      # if the feature is enabled, then do what is required to generated the labels/annotations etc
      if [ ! -z $LAGOON_FASTLY_AUTOGENERATED ] && [ $LAGOON_FASTLY_AUTOGENERATED = 'enabled' ]; then
        # work out if there are any lagoon api variable overrides for the annotations that are being added
        . /kubectl-build-deploy/scripts/exec-fastly-annotations.sh
        # if we get any other populated service id overrides in any of the steps in exec-fastly-annotations.sh
        # make it available to the ingress creation here by overriding what may be defined in the lagoon.yml
        # `LAGOON_FASTLY_SERVICE_ID` is created in the exec-fastly-annotations.sh script
        if [ ! -z "$LAGOON_FASTLY_SERVICE_ID" ]; then
          ROUTE_FASTLY_SERVICE_ID=$LAGOON_FASTLY_SERVICE_ID
          ROUTE_FASTLY_SERVICE_WATCH=$LAGOON_FASTLY_SERVICE_WATCH
          if [ ! -z $LAGOON_FASTLY_SERVICE_API_SECRET ]; then
            ROUTE_FASTLY_SERVICE_API_SECRET=$LAGOON_FASTLY_SERVICE_API_SECRET
          fi
        fi
        if [ ! -z "$ROUTE_FASTLY_SERVICE_ID" ]; then
          FASTLY_ARGS+=(--set fastly.serviceId=${ROUTE_FASTLY_SERVICE_ID})
          if [ ! -z "$ROUTE_FASTLY_SERVICE_API_SECRET" ]; then
            if contains $FASTLY_API_SECRETS "${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET}"; then
              FASTLY_ARGS+=(--set fastly.apiSecretName=${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET})
            else
              echo "$ROUTE_FASTLY_SERVICE_API_SECRET requested, but not found in .lagoon.yml file"; exit 1;
            fi
          fi
          ROUTE_FASTLY_SERVICE_WATCH=true
        fi
      fi
      # finally template the autogenerated route
      helm template ${SERVICE_NAME} /kubectl-build-deploy/helmcharts/${SERVICE_TYPE} \
        -s $HELM_INGRESS_TEMPLATE \
        "${FASTLY_ARGS[@]}" --set fastly.watch="${ROUTE_FASTLY_SERVICE_WATCH}" \
        -f /kubectl-build-deploy/values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${SERVICE_NAME}.yaml
    fi
  fi

  HELM_DBAAS_TEMPLATE="templates/dbaas.yaml"
  if [ -f /kubectl-build-deploy/helmcharts/${SERVICE_TYPE}/$HELM_DBAAS_TEMPLATE ]; then
    # Load the requested class and plan for this service
    DBAAS_ENVIRONMENT="${MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]}"
    yq write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'environment' $DBAAS_ENVIRONMENT
    helm template ${SERVICE_NAME} /kubectl-build-deploy/helmcharts/${SERVICE_TYPE} -s $HELM_DBAAS_TEMPLATE -f /kubectl-build-deploy/values.yaml -f /kubectl-build-deploy/${SERVICE_NAME}-values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${SERVICE_NAME}.yaml
    DBAAS+=("${SERVICE_NAME}:${SERVICE_TYPE}")
  fi
done

TEMPLATE_PARAMETERS=()

##############################################
### CUSTOM ROUTES FROM .lagoon.yml
##############################################


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
            ROUTE_ANNOTATIONS=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.annotations {})
            # get the fastly configuration values from .lagoon.yml
            if cat .lagoon.yml | shyaml keys production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly &> /dev/null; then
              ROUTE_FASTLY_SERVICE_ID=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.service-id "")
              ROUTE_FASTLY_SERVICE_API_SECRET=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.api-secret-name "")
              ROUTE_FASTLY_SERVICE_WATCH=$(set -o pipefail; cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.watch false | tr '[:upper:]' '[:lower:]')
            else
              ROUTE_FASTLY_SERVICE_ID=""
              ROUTE_FASTLY_SERVICE_API_SECRET=""
              ROUTE_FASTLY_SERVICE_WATCH=false
            fi
          else
            # Only a value given, assuming some defaults
            ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value production_routes.active.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
            ROUTE_TLS_ACME=true
            ROUTE_MIGRATE=true
            ROUTE_INSECURE=Redirect
            ROUTE_HSTS=null
            MONITORING_PATH="/"
            ROUTE_ANNOTATIONS="{}"
            ROUTE_FASTLY_SERVICE_ID=""
            ROUTE_FASTLY_SERVICE_API_SECRET=""
            ROUTE_FASTLY_SERVICE_WATCH=false
          fi

          # work out if there are any lagoon api variable overrides for the annotations that are being added
          . /kubectl-build-deploy/scripts/exec-fastly-annotations.sh
          # if we get any other populated service id overrides in any of the steps in exec-fastly-annotations.sh
          # make it available to the ingress creation here by overriding what may be defined in the lagoon.yml
          # `LAGOON_FASTLY_SERVICE_ID` is created in the exec-fastly-annotations.sh script
          if [ ! -z "$LAGOON_FASTLY_SERVICE_ID" ]; then
            ROUTE_FASTLY_SERVICE_ID=$LAGOON_FASTLY_SERVICE_ID
            ROUTE_FASTLY_SERVICE_WATCH=$LAGOON_FASTLY_SERVICE_WATCH
            if [ ! -z $LAGOON_FASTLY_SERVICE_API_SECRET ]; then
              ROUTE_FASTLY_SERVICE_API_SECRET=$LAGOON_FASTLY_SERVICE_API_SECRET
            fi
          fi

          FASTLY_ARGS=()
          if [ ! -z "$ROUTE_FASTLY_SERVICE_ID" ]; then
            FASTLY_ARGS+=(--set fastly.serviceId=${ROUTE_FASTLY_SERVICE_ID})
            if [ ! -z "$ROUTE_FASTLY_SERVICE_API_SECRET" ]; then
              if contains $FASTLY_API_SECRETS "${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET}"; then
                FASTLY_ARGS+=(--set fastly.apiSecretName=${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET})
              else
                echo "$ROUTE_FASTLY_SERVICE_API_SECRET requested, but not found in .lagoon.yml file"; exit 1;
              fi
            fi
          fi

          touch /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml
          echo "$ROUTE_ANNOTATIONS" | yq p - annotations > /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

          # ${ROUTE_DOMAIN} is used as a helm release name which be max 53 characters long.
          # So we need some logic to make sure it's always max 53 characters
          if [[ ${#ROUTE_DOMAIN} -gt 53 ]] ; then
            # Trim the route domain to 47 characters, and add an 5 character hash of the domain at the end
            # this gives a total of 53 characters
            INGRESS_NAME=${ROUTE_DOMAIN:0:47}-$(echo ${ROUTE_DOMAIN} | md5sum | cut -f 1 -d " " | cut -c 1-5)
          else
            INGRESS_NAME=${ROUTE_DOMAIN}
          fi

          # The very first found route is set as MAIN_CUSTOM_ROUTE
          if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
            MAIN_CUSTOM_ROUTE=$INGRESS_NAME

            # if we are in production we enabled monitoring for the main custom route
            if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
              MONITORING_ENABLED="true"
            fi

          fi

          ROUTE_SERVICE=$ROUTES_SERVICE

          cat /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

          helm template ${INGRESS_NAME} \
            /kubectl-build-deploy/helmcharts/custom-ingress \
            --set host="${ROUTE_DOMAIN}" \
            --set service="${ROUTE_SERVICE}" \
            --set tls_acme="${ROUTE_TLS_ACME}" \
            --set insecure="${ROUTE_INSECURE}" \
            --set hsts="${ROUTE_HSTS}" \
            --set routeMigrate="${ROUTE_MIGRATE}" \
            --set ingressmonitorcontroller.enabled="${MONITORING_ENABLED}" \
            --set ingressmonitorcontroller.path="${MONITORING_PATH}" \
            --set ingressmonitorcontroller.alertContacts="${MONITORING_ALERTCONTACT}" \
            --set ingressmonitorcontroller.statuspageId="${MONITORING_STATUSPAGEID}" \
            "${FASTLY_ARGS[@]}" --set fastly.watch="${ROUTE_FASTLY_SERVICE_WATCH}" \
            -f /kubectl-build-deploy/values.yaml -f /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${ROUTE_DOMAIN}.yaml

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
            ROUTE_ANNOTATIONS=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.annotations {})
            # get the fastly configuration values from .lagoon.yml
            if cat .lagoon.yml | shyaml keys production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly &> /dev/null; then
              ROUTE_FASTLY_SERVICE_ID=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.service-id "")
              ROUTE_FASTLY_SERVICE_API_SECRET=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.api-secret-name "")
              ROUTE_FASTLY_SERVICE_WATCH=$(set -o pipefail; cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.watch false | tr '[:upper:]' '[:lower:]')
            else
              ROUTE_FASTLY_SERVICE_ID=""
              ROUTE_FASTLY_SERVICE_API_SECRET=""
              ROUTE_FASTLY_SERVICE_WATCH=false
            fi
          else
            # Only a value given, assuming some defaults
            ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value production_routes.standby.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
            ROUTE_TLS_ACME=true
            ROUTE_MIGRATE=true
            ROUTE_INSECURE=Redirect
            ROUTE_HSTS=null
            MONITORING_PATH="/"
            ROUTE_ANNOTATIONS="{}"
            ROUTE_FASTLY_SERVICE_ID=""
            ROUTE_FASTLY_SERVICE_API_SECRET=""
            ROUTE_FASTLY_SERVICE_WATCH=false
          fi

          # work out if there are any lagoon api variable overrides for the annotations that are being added
          . /kubectl-build-deploy/scripts/exec-fastly-annotations.sh
          # if we get any other populated service id overrides in any of the steps in exec-fastly-annotations.sh
          # make it available to the ingress creation here by overriding what may be defined in the lagoon.yml
          # `LAGOON_FASTLY_SERVICE_ID` is created in the exec-fastly-annotations.sh script
          if [ ! -z "$LAGOON_FASTLY_SERVICE_ID" ]; then
            ROUTE_FASTLY_SERVICE_ID=$LAGOON_FASTLY_SERVICE_ID
            ROUTE_FASTLY_SERVICE_WATCH=$LAGOON_FASTLY_SERVICE_WATCH
            if [ ! -z $LAGOON_FASTLY_SERVICE_API_SECRET ]; then
              ROUTE_FASTLY_SERVICE_API_SECRET=$LAGOON_FASTLY_SERVICE_API_SECRET
            fi
          fi

          # Create the fastly values required
          FASTLY_ARGS=()
          if [ ! -z "$ROUTE_FASTLY_SERVICE_ID" ]; then
            FASTLY_ARGS+=(--set fastly.serviceId=${ROUTE_FASTLY_SERVICE_ID})
            if [ ! -z "$ROUTE_FASTLY_SERVICE_API_SECRET" ]; then
              if contains $FASTLY_API_SECRETS "${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET}"; then
                FASTLY_ARGS+=(--set fastly.apiSecretName=${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET})
              else
                echo "$ROUTE_FASTLY_SERVICE_API_SECRET requested, but not found in .lagoon.yml file"; exit 1;
              fi
            fi
            ROUTE_FASTLY_SERVICE_WATCH=true
          fi

          touch /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml
          echo "$ROUTE_ANNOTATIONS" | yq p - annotations > /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

          # ${ROUTE_DOMAIN} is used as a helm release name which be max 53 characters long.
          # So we need some logic to make sure it's always max 53 characters
          if [[ ${#ROUTE_DOMAIN} -gt 53 ]] ; then
            # Trim the route domain to 47 characters, and add an 5 character hash of the domain at the end
            # this gives a total of 53 characters
            INGRESS_NAME=${ROUTE_DOMAIN:0:47}-$(echo ${ROUTE_DOMAIN} | md5sum | cut -f 1 -d " " | cut -c 1-5)
          else
            INGRESS_NAME=${ROUTE_DOMAIN}
          fi

          # The very first found route is set as MAIN_CUSTOM_ROUTE
          if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
            MAIN_CUSTOM_ROUTE=$INGRESS_NAME

            # if we are in production we enabled monitoring for the main custom route
            if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
              MONITORING_ENABLED="true"
            fi

          fi

          ROUTE_SERVICE=$ROUTES_SERVICE

          cat /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

          helm template ${INGRESS_NAME} \
            /kubectl-build-deploy/helmcharts/custom-ingress \
            --set host="${ROUTE_DOMAIN}" \
            --set service="${ROUTE_SERVICE}" \
            --set tls_acme="${ROUTE_TLS_ACME}" \
            --set insecure="${ROUTE_INSECURE}" \
            --set hsts="${ROUTE_HSTS}" \
            --set routeMigrate="${ROUTE_MIGRATE}" \
            --set ingressmonitorcontroller.enabled="${MONITORING_ENABLED}" \
            --set ingressmonitorcontroller.path="${MONITORING_PATH}" \
            --set ingressmonitorcontroller.alertContacts="${MONITORING_ALERTCONTACT}" \
            --set ingressmonitorcontroller.statuspageId="${MONITORING_STATUSPAGEID}" \
            "${FASTLY_ARGS[@]}" --set fastly.watch="${ROUTE_FASTLY_SERVICE_WATCH}" \
            -f /kubectl-build-deploy/values.yaml -f /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${ROUTE_DOMAIN}.yaml

          MONITORING_ENABLED="false" # disabling a possible enabled monitoring again

          let ROUTE_DOMAIN_COUNTER=ROUTE_DOMAIN_COUNTER+1
        done

        let ROUTES_SERVICE_COUNTER=ROUTES_SERVICE_COUNTER+1
      done
    fi
  fi
fi

MONITORING_ENABLED="false" # monitoring is by default disabled, it will be enabled for the first route again

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
        ROUTE_ANNOTATIONS=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.annotations {})
        # get the fastly configuration values from .lagoon.yml
        if cat .lagoon.yml | shyaml keys ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly &> /dev/null; then
          ROUTE_FASTLY_SERVICE_ID=$(cat .lagoon.yml | shyaml ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.service-id "")
          ROUTE_FASTLY_SERVICE_API_SECRET=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.api-secret-name "")
          ROUTE_FASTLY_SERVICE_WATCH=$(set -o pipefail; cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.watch false | tr '[:upper:]' '[:lower:]')
        else
          ROUTE_FASTLY_SERVICE_ID=""
          ROUTE_FASTLY_SERVICE_API_SECRET=""
          ROUTE_FASTLY_SERVICE_WATCH=false
        fi
      else
        # Only a value given, assuming some defaults
        ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value ${PROJECT}.environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
        ROUTE_TLS_ACME=true
        ROUTE_MIGRATE=false
        ROUTE_INSECURE=Redirect
        ROUTE_HSTS=null
        MONITORING_PATH="/"
        ROUTE_ANNOTATIONS="{}"
        ROUTE_FASTLY_SERVICE_ID=""
        ROUTE_FASTLY_SERVICE_API_SECRET=""
        ROUTE_FASTLY_SERVICE_WATCH=false
      fi

      # work out if there are any lagoon api variable overrides for the annotations that are being added
      . /kubectl-build-deploy/scripts/exec-fastly-annotations.sh
      # if we get any other populated service id overrides in any of the steps in exec-fastly-annotations.sh
      # make it available to the ingress creation here by overriding what may be defined in the lagoon.yml
      # `LAGOON_FASTLY_SERVICE_ID` is created in the exec-fastly-annotations.sh script
      if [ ! -z "$LAGOON_FASTLY_SERVICE_ID" ]; then
        ROUTE_FASTLY_SERVICE_ID=$LAGOON_FASTLY_SERVICE_ID
        ROUTE_FASTLY_SERVICE_WATCH=$LAGOON_FASTLY_SERVICE_WATCH
        if [ ! -z $LAGOON_FASTLY_SERVICE_API_SECRET ]; then
          ROUTE_FASTLY_SERVICE_API_SECRET=$LAGOON_FASTLY_SERVICE_API_SECRET
        fi
      fi

      # Create the fastly values required
      FASTLY_ARGS=()
      if [ ! -z "$ROUTE_FASTLY_SERVICE_ID" ]; then
        FASTLY_ARGS+=(--set fastly.serviceId=${ROUTE_FASTLY_SERVICE_ID})
        if [ ! -z "$ROUTE_FASTLY_SERVICE_API_SECRET" ]; then
          if contains $FASTLY_API_SECRETS "${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET}"; then
            FASTLY_ARGS+=(--set fastly.apiSecretName=${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET})
          else
            echo "$ROUTE_FASTLY_SERVICE_API_SECRET requested, but not found in .lagoon.yml file"; exit 1;
          fi
        fi
        ROUTE_FASTLY_SERVICE_WATCH=true
      fi

      # ${ROUTE_DOMAIN} is used as a helm release name which be max 53 characters long.
      # So we need some logic to make sure it's always max 53 characters
      if [[ ${#ROUTE_DOMAIN} -gt 53 ]] ; then
        # Trim the route domain to 47 characters, and add an 5 character hash of the domain at the end
        # this gives a total of 53 characters
        INGRESS_NAME=${ROUTE_DOMAIN:0:47}-$(echo ${ROUTE_DOMAIN} | md5sum | cut -f 1 -d " " | cut -c 1-5)
      else
        INGRESS_NAME=${ROUTE_DOMAIN}
      fi

      touch /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml
      echo "$ROUTE_ANNOTATIONS" | yq p - annotations > /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

      # The very first found route is set as MAIN_CUSTOM_ROUTE
      if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
        MAIN_CUSTOM_ROUTE=$INGRESS_NAME

        # if we are in production we enabled monitoring for the main custom route
        if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
          MONITORING_ENABLED="true"
        fi

      fi

      ROUTE_SERVICE=$ROUTES_SERVICE

      cat /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

      helm template ${INGRESS_NAME} \
        /kubectl-build-deploy/helmcharts/custom-ingress \
        --set host="${ROUTE_DOMAIN}" \
        --set service="${ROUTE_SERVICE}" \
        --set tls_acme="${ROUTE_TLS_ACME}" \
        --set insecure="${ROUTE_INSECURE}" \
        --set hsts="${ROUTE_HSTS}" \
        --set routeMigrate="${ROUTE_MIGRATE}" \
        --set ingressmonitorcontroller.enabled="${MONITORING_ENABLED}" \
        --set ingressmonitorcontroller.path="${MONITORING_PATH}" \
        --set ingressmonitorcontroller.alertContacts="${MONITORING_ALERTCONTACT}" \
        --set ingressmonitorcontroller.statuspageId="${MONITORING_STATUSPAGEID}" \
            "${FASTLY_ARGS[@]}" --set fastly.watch="${ROUTE_FASTLY_SERVICE_WATCH}" \
        -f /kubectl-build-deploy/values.yaml -f /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${ROUTE_DOMAIN}.yaml

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
        ROUTE_ANNOTATIONS=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.annotations {})
        # get the fastly configuration values from .lagoon.yml
        if cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly &> /dev/null; then
          ROUTE_FASTLY_SERVICE_ID=$(cat .lagoon.yml | shyaml environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.service-id "")
          ROUTE_FASTLY_SERVICE_API_SECRET=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.api-secret-name "")
          ROUTE_FASTLY_SERVICE_WATCH=$(set -o pipefail; cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER.$ROUTE_DOMAIN_ESCAPED.fastly.watch false | tr '[:upper:]' '[:lower:]')
        else
          ROUTE_FASTLY_SERVICE_ID=""
          ROUTE_FASTLY_SERVICE_API_SECRET=""
          ROUTE_FASTLY_SERVICE_WATCH=false
        fi
      else
        # Only a value given, assuming some defaults
        ROUTE_DOMAIN=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.routes.$ROUTES_SERVICE_COUNTER.$ROUTES_SERVICE.$ROUTE_DOMAIN_COUNTER)
        ROUTE_TLS_ACME=true
        ROUTE_MIGRATE=false
        ROUTE_INSECURE=Redirect
        ROUTE_HSTS=null
        MONITORING_PATH="/"
        ROUTE_ANNOTATIONS="{}"
        ROUTE_FASTLY_SERVICE_ID=""
        ROUTE_FASTLY_SERVICE_API_SECRET=""
        ROUTE_FASTLY_SERVICE_WATCH=false
      fi

      # work out if there are any lagoon api variable overrides for the annotations that are being added
      . /kubectl-build-deploy/scripts/exec-fastly-annotations.sh
      # if we get any other populated service id overrides in any of the steps in exec-fastly-annotations.sh
      # make it available to the ingress creation here by overriding what may be defined in the lagoon.yml
      # `LAGOON_FASTLY_SERVICE_ID` is created in the exec-fastly-annotations.sh script
      if [ ! -z "$LAGOON_FASTLY_SERVICE_ID" ]; then
        ROUTE_FASTLY_SERVICE_ID=$LAGOON_FASTLY_SERVICE_ID
        ROUTE_FASTLY_SERVICE_WATCH=$LAGOON_FASTLY_SERVICE_WATCH
        if [ ! -z $LAGOON_FASTLY_SERVICE_API_SECRET ]; then
          ROUTE_FASTLY_SERVICE_API_SECRET=$LAGOON_FASTLY_SERVICE_API_SECRET
        fi
      fi

      # Create the fastly values required
      FASTLY_ARGS=()
      if [ ! -z "$ROUTE_FASTLY_SERVICE_ID" ]; then
        FASTLY_ARGS+=(--set fastly.serviceId=${ROUTE_FASTLY_SERVICE_ID})
        if [ ! -z "$ROUTE_FASTLY_SERVICE_API_SECRET" ]; then
          if contains $FASTLY_API_SECRETS "${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET}"; then
            FASTLY_ARGS+=(--set fastly.apiSecretName=${FASTLY_API_SECRET_PREFIX}${ROUTE_FASTLY_SERVICE_API_SECRET})
          else
            echo "$ROUTE_FASTLY_SERVICE_API_SECRET requested, but not found in .lagoon.yml file"; exit 1;
          fi
        fi
        ROUTE_FASTLY_SERVICE_WATCH=true
      fi

      touch /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml
      echo "$ROUTE_ANNOTATIONS" | yq p - annotations > /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

      # ${ROUTE_DOMAIN} is used as a helm release name which be max 53 characters long.
      # So we need some logic to make sure it's always max 53 characters
      if [[ ${#ROUTE_DOMAIN} -gt 53 ]] ; then
        # Trim the route domain to 47 characters, and add an 5 character hash of the domain at the end
        # this gives a total of 53 characters
        INGRESS_NAME=${ROUTE_DOMAIN:0:47}-$(echo ${ROUTE_DOMAIN} | md5sum | cut -f 1 -d " " | cut -c 1-5)
      else
        INGRESS_NAME=${ROUTE_DOMAIN}
      fi

      # The very first found route is set as MAIN_CUSTOM_ROUTE
      if [ -z "${MAIN_CUSTOM_ROUTE+x}" ]; then
        MAIN_CUSTOM_ROUTE=$INGRESS_NAME

        # if we are in production we enabled monitoring for the main custom route
        if [ "${ENVIRONMENT_TYPE}" == "production" ]; then
          MONITORING_ENABLED="true"
        fi

      fi

      ROUTE_SERVICE=$ROUTES_SERVICE

      cat /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml

      helm template ${INGRESS_NAME} \
        /kubectl-build-deploy/helmcharts/custom-ingress \
        --set host="${ROUTE_DOMAIN}" \
        --set service="${ROUTE_SERVICE}" \
        --set tls_acme="${ROUTE_TLS_ACME}" \
        --set insecure="${ROUTE_INSECURE}" \
        --set hsts="${ROUTE_HSTS}" \
        --set routeMigrate="${ROUTE_MIGRATE}" \
        --set ingressmonitorcontroller.enabled="${MONITORING_ENABLED}" \
        --set ingressmonitorcontroller.path="${MONITORING_PATH}" \
        --set ingressmonitorcontroller.alertContacts="${MONITORING_ALERTCONTACT}" \
        --set ingressmonitorcontroller.statuspageId="${MONITORING_STATUSPAGEID}" \
            "${FASTLY_ARGS[@]}" --set fastly.watch="${ROUTE_FASTLY_SERVICE_WATCH}" \
        -f /kubectl-build-deploy/values.yaml -f /kubectl-build-deploy/${ROUTE_DOMAIN}-values.yaml  "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/${ROUTE_DOMAIN}.yaml

      MONITORING_ENABLED="false" # disabling a possible enabled monitoring again

      let ROUTE_DOMAIN_COUNTER=ROUTE_DOMAIN_COUNTER+1
    done

    let ROUTES_SERVICE_COUNTER=ROUTES_SERVICE_COUNTER+1
  done
fi

# If k8up is supported by this cluster we create the schedule definition
if [[ "${CAPABILITIES[@]}" =~ "backup.appuio.ch/v1alpha1/Schedule" ]]; then

  if ! kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get secret baas-repo-pw &> /dev/null; then
    # Create baas-repo-pw secret based on the project secret
    set +x
    kubectl --insecure-skip-tls-verify -n ${NAMESPACE} create secret generic baas-repo-pw --from-literal=repo-pw=$(echo -n "$PROJECT_SECRET-BAAS-REPO-PW" | sha256sum | cut -d " " -f 1)
    set -x
  fi

  TEMPLATE_PARAMETERS=()

  # Check for custom baas bucket name
  if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
    BAAS_BUCKET_NAME=$(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_BAAS_BUCKET_NAME") | "\(.value)"')
  fi
  if [ -z $BAAS_BUCKET_NAME ]; then
    BAAS_BUCKET_NAME=baas-${PROJECT}
  fi

  # Pull in .lagoon.yml variables
  PRODUCTION_MONTHLY_BACKUP_RETENTION=$(cat .lagoon.yml | shyaml get-value backup-retention.production.monthly "")
  PRODUCTION_WEEKLY_BACKUP_RETENTION=$(cat .lagoon.yml | shyaml get-value backup-retention.production.weekly "")
  PRODUCTION_DAILY_BACKUP_RETENTION=$(cat .lagoon.yml | shyaml get-value backup-retention.production.daily "")

  # Set template parameters for retention values (prefer .lagoon.yml values over supplied defaults after ensuring they are valid integers via "-eq" comparison)
  if [ ! -z $PRODUCTION_MONTHLY_BACKUP_RETENTION ] && [ "$PRODUCTION_MONTHLY_BACKUP_RETENTION" -eq "$PRODUCTION_MONTHLY_BACKUP_RETENTION" ] && [ $ENVIRONMENT_TYPE = 'production' ]; then
    MONTHLY_BACKUP_RETENTION=${PRODUCTION_MONTHLY_BACKUP_RETENTION}
  else
    MONTHLY_BACKUP_RETENTION=${MONTHLY_BACKUP_DEFAULT_RETENTION}
  fi
  if [ ! -z $PRODUCTION_WEEKLY_BACKUP_RETENTION ] && [ "$PRODUCTION_WEEKLY_BACKUP_RETENTION" -eq "$PRODUCTION_WEEKLY_BACKUP_RETENTION" ] && [ $ENVIRONMENT_TYPE = 'production' ]; then
    WEEKLY_BACKUP_RETENTION=${PRODUCTION_WEEKLY_BACKUP_RETENTION}
  else
    WEEKLY_BACKUP_RETENTION=${WEEKLY_BACKUP_DEFAULT_RETENTION}
  fi
  if [ ! -z $PRODUCTION_DAILY_BACKUP_RETENTION ] && [ "$PRODUCTION_DAILY_BACKUP_RETENTION" -eq "$PRODUCTION_DAILY_BACKUP_RETENTION" ] && [ $ENVIRONMENT_TYPE = 'production' ]; then
    DAILY_BACKUP_RETENTION=${PRODUCTION_DAILY_BACKUP_RETENTION}
  else
    DAILY_BACKUP_RETENTION=${DAILY_BACKUP_DEFAULT_RETENTION}
  fi

  # Run Backups every day at 2200-0200
  BACKUP_SCHEDULE=$( /kubectl-build-deploy/scripts/convert-crontab.sh "${NAMESPACE}" "M H(22-2) * * *")

  if [ ! -z $K8UP_WEEKLY_RANDOM_FEATURE_FLAG ] && [ $K8UP_WEEKLY_RANDOM_FEATURE_FLAG = 'enabled' ]; then
    # Let the controller deduplicate checks (will run weekly at a random time throughout the week)
    CHECK_SCHEDULE="@weekly-random"
  else
    # Run Checks on Sunday at 0300-0600
    CHECK_SCHEDULE=$( /kubectl-build-deploy/scripts/convert-crontab.sh "${NAMESPACE}" "M H(3-6) * * 0")
  fi

  if [ ! -z $K8UP_WEEKLY_RANDOM_FEATURE_FLAG ] && [ $K8UP_WEEKLY_RANDOM_FEATURE_FLAG = 'enabled' ]; then
    # Let the controller deduplicate prunes (will run weekly at a random time throughout the week)
    PRUNE_SCHEDULE="@weekly-random"
  else
    # Run Prune on Saturday at 0300-0600
    PRUNE_SCHEDULE=$( /kubectl-build-deploy/scripts/convert-crontab.sh "${NAMESPACE}" "M H(3-6) * * 6")
  fi

  OPENSHIFT_TEMPLATE="/kubectl-build-deploy/openshift-templates/backup-schedule.yml"
  helm template k8up-lagoon-backup-schedule /kubectl-build-deploy/helmcharts/k8up-schedule \
    -f /kubectl-build-deploy/values.yaml \
    --set backup.schedule="${BACKUP_SCHEDULE}" \
    --set check.schedule="${CHECK_SCHEDULE}" \
    --set prune.schedule="${PRUNE_SCHEDULE}" "${HELM_ARGUMENTS[@]}" \
    --set baasBucketName="${BAAS_BUCKET_NAME}" > $YAML_FOLDER/k8up-lagoon-backup-schedule.yaml \
    --set prune.retention.keepMonthly=$MONTHLY_BACKUP_RETENTION \
    --set prune.retention.keepWeekly=$WEEKLY_BACKUP_RETENTION \
    --set prune.retention.keepDaily=$DAILY_BACKUP_RETENTION
fi

if [ "$(ls -A $YAML_FOLDER/)" ]; then
  find $YAML_FOLDER -type f -exec cat {} \;
  kubectl apply --insecure-skip-tls-verify -n ${NAMESPACE} -f $YAML_FOLDER/
fi

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
  ROUTE=$(kubectl -n ${NAMESPACE} get ingress "$MAIN_ROUTE_NAME" -o=go-template --template='{{if .spec.tls}}https://{{else}}http://{{end}}{{(index .spec.rules 0).host}}')
fi

# Load all routes with correct schema and comma separated
ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "acme.openshift.io/exposer!=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')

# Active / Standby routes
ACTIVE_ROUTES=""
STANDBY_ROUTES=""
if [ ! -z "${STANDBY_ENVIRONMENT}" ]; then
ACTIVE_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "dioscuri.amazee.io/migrate=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')
STANDBY_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "dioscuri.amazee.io/migrate=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')
fi

# Get list of autogenerated routes
AUTOGENERATED_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "lagoon.sh/autogenerated=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')

yq write -i -- /kubectl-build-deploy/values.yaml 'route' "$ROUTE"
yq write -i -- /kubectl-build-deploy/values.yaml 'routes' "$ROUTES"
yq write -i -- /kubectl-build-deploy/values.yaml 'autogeneratedRoutes' "$AUTOGENERATED_ROUTES"

echo -e "\
LAGOON_ROUTE=${ROUTE}\n\
LAGOON_ROUTES=${ROUTES}\n\
LAGOON_AUTOGENERATED_ROUTES=${AUTOGENERATED_ROUTES}\n\
" >> /kubectl-build-deploy/values.env

# Generate a Config Map with project wide env variables
kubectl -n ${NAMESPACE} create configmap lagoon-env -o yaml --dry-run --from-env-file=/kubectl-build-deploy/values.env | kubectl apply -n ${NAMESPACE} -f -

set +x # reduce noise in build logs
# Add environment variables from lagoon API
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  HAS_PROJECT_RUNTIME_VARS=$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") )')

  if [ ! "$HAS_PROJECT_RUNTIME_VARS" = "[]" ]; then
    kubectl patch --insecure-skip-tls-verify \
      -n ${NAMESPACE} \
      configmap lagoon-env \
      -p "{\"data\":$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | tostring')}"
  fi
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  HAS_ENVIRONMENT_RUNTIME_VARS=$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") )')

  if [ ! "$HAS_ENVIRONMENT_RUNTIME_VARS" = "[]" ]; then
    kubectl patch --insecure-skip-tls-verify \
      -n ${NAMESPACE} \
      configmap lagoon-env \
      -p "{\"data\":$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | tostring')}"
  fi
fi
set -x

if [ "$BUILD_TYPE" == "pullrequest" ]; then
  kubectl patch --insecure-skip-tls-verify \
    -n ${NAMESPACE} \
    configmap lagoon-env \
    -p "{\"data\":{\"LAGOON_PR_HEAD_BRANCH\":\"${PR_HEAD_BRANCH}\", \"LAGOON_PR_BASE_BRANCH\":\"${PR_BASE_BRANCH}\", \"LAGOON_PR_TITLE\":$(echo $PR_TITLE | jq -R)}}"
fi

# loop through created DBAAS
for DBAAS_ENTRY in "${DBAAS[@]}"
do
  IFS=':' read -ra DBAAS_ENTRY_SPLIT <<< "$DBAAS_ENTRY"

  SERVICE_NAME=${DBAAS_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${DBAAS_ENTRY_SPLIT[1]}

  SERVICE_NAME_UPPERCASE=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

  case "$SERVICE_TYPE" in

    mariadb-dbaas)
        . /kubectl-build-deploy/scripts/exec-kubectl-mariadb-dbaas.sh
        ;;

    postgres-dbaas)
        . /kubectl-build-deploy/scripts/exec-kubectl-postgres-dbaas.sh
        ;;

    mongodb-dbaas)
        . /kubectl-build-deploy/scripts/exec-kubectl-mongodb-dbaas.sh
        ;;

    *)
        echo "DBAAS Type ${SERVICE_TYPE} not implemented"; exit 1;

  esac
done

##############################################
### REDEPLOY DEPLOYMENTS IF CONFIG MAP CHANGES
##############################################

CONFIG_MAP_SHA=$(kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get configmap lagoon-env -o yaml | shyaml get-value data | sha256sum | awk '{print $1}')
# write the configmap to the values file so when we `exec-kubectl-resources-with-images.sh` the deployments will get the value of the config map
# which will cause a change in the deployment and trigger a rollout if only the configmap has changed
yq write -i -- /kubectl-build-deploy/values.yaml 'configMapSha' $CONFIG_MAP_SHA

##############################################
### PUSH IMAGES TO OPENSHIFT REGISTRY
##############################################

if [[ $THIS_IS_TUG == "true" ]]; then
  # TODO: lagoon-tug is not implemented yet in kubernetes
  echo "lagoon-tug is not implemented yet in kubernetes"
  exit 1
  # Allow to disable registry auth
  if [ ! "${TUG_SKIP_REGISTRY_AUTH}" == "true" ]; then
    # This adds the defined credentials to the serviceaccount/default so that the deployments can pull from the remote registry
    if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get secret tug-registry 2> /dev/null; then
      kubectl --insecure-skip-tls-verify -n ${NAMESPACE} delete secret tug-registry
    fi

    kubectl --insecure-skip-tls-verify -n ${NAMESPACE} secrets new-dockercfg tug-registry --docker-server="${TUG_REGISTRY}" --docker-username="${TUG_REGISTRY_USERNAME}" --docker-password="${TUG_REGISTRY_PASSWORD}" --docker-email="${TUG_REGISTRY_USERNAME}"
    kubectl --insecure-skip-tls-verify -n ${NAMESPACE} secrets add serviceaccount/default secrets/tug-registry --for=pull
  fi

  # Import all remote Images into ImageStreams
  readarray -t TUG_IMAGES < /kubectl-build-deploy/tug/images
  for TUG_IMAGE in "${TUG_IMAGES[@]}"
  do
    kubectl --insecure-skip-tls-verify -n ${NAMESPACE} tag --source=docker "${TUG_REGISTRY}/${TUG_REGISTRY_REPOSITORY}/${TUG_IMAGE_PREFIX}${TUG_IMAGE}:${SAFE_BRANCH}" "${TUG_IMAGE}:latest"
  done

elif [ "$BUILD_TYPE" == "pullrequest" ] || [ "$BUILD_TYPE" == "branch" ]; then

  # All images that should be pulled are copied to the harbor registry
  for IMAGE_NAME in "${!IMAGES_PULL[@]}"
  do
    PULL_IMAGE="${IMAGES_PULL[${IMAGE_NAME}]}"

    # Try to handle private registries first
    if [ $PRIVATE_REGISTRY_COUNTER -gt 0 ]; then
      if [ $PRIVATE_EXTERNAL_REGISTRY ]; then
        EXTERNAL_REGISTRY=0
        for EXTERNAL_REGISTRY_URL in "${PRIVATE_REGISTRY_URLS[@]}"
        do
          # strip off "http://" or "https://" from registry url if present
          bare_url="${EXTERNAL_REGISTRY_URL#http://}"
          bare_url="${EXTERNAL_REGISTRY_URL#https://}"

          # Test registry to see if image is from an external registry or just private docker hub
          case $bare_url in
            "$PULL_IMAGE"*)
              EXTERNAL_REGISTRY=1
              ;;
          esac
        done

        # If this image is hosted in an external registry, pull it from there
        if [ $EXTERNAL_REGISTRY -eq 1 ]; then
          skopeo copy --dest-tls-verify=false docker://${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
        # If this image is not from an external registry, but docker hub creds were supplied, pull it straight from Docker Hub
        elif [ $PRIVATE_DOCKER_HUB_REGISTRY -eq 1 ]; then
          skopeo copy --dest-tls-verify=false docker://${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
        # If image not from an external registry and no docker hub creds were supplied, pull image from the imagecache
        else
          skopeo copy --dest-tls-verify=false docker://${IMAGECACHE_REGISTRY}/${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
        fi
      # If the private registry counter is 1 and no external registry was listed, we know a private docker hub was specified
      else
        skopeo copy --dest-tls-verify=false docker://${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
      fi
    # If no private registries, use the imagecache
    else
      skopeo copy --dest-tls-verify=false docker://${IMAGECACHE_REGISTRY}/${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
    fi

    IMAGE_HASHES[${IMAGE_NAME}]=$(skopeo inspect docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest} --tls-verify=false | jq ".Name + \"@\" + .Digest" -r)
  done

  for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
  do
    # Before the push the temporary name is resolved to the future tag with the registry in the image name
    TEMPORARY_IMAGE_NAME="${IMAGES_BUILD[${IMAGE_NAME}]}"

    # This will actually not push any images and instead just add them to the file /kubectl-build-deploy/lagoon/push
    . /kubectl-build-deploy/scripts/exec-push-parallel.sh
  done

  # If we have Images to Push to the OpenRegistry, let's do so
  if [ -f /kubectl-build-deploy/lagoon/push ]; then
    parallel --retries 4 < /kubectl-build-deploy/lagoon/push
  fi

  # load the image hashes for just pushed Images
  for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
  do
    JQ_QUERY=(jq -r ".[]|select(test(\"${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}\"))")
    IMAGE_HASHES[${IMAGE_NAME}]=$(docker inspect ${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest} --format '{{json .RepoDigests}}' | "${JQ_QUERY[@]}")
  done

elif [ "$BUILD_TYPE" == "promote" ]; then

  for IMAGE_NAME in "${IMAGES[@]}"
  do
    .  /kubectl-build-deploy/scripts/exec-kubernetes-promote.sh
    IMAGE_HASHES[${IMAGE_NAME}]=$(skopeo inspect docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest} --tls-verify=false | jq ".Name + \"@\" + .Digest" -r)
  done

fi

##############################################
### CREATE PVC, DEPLOYMENTS AND CRONJOBS
##############################################

YAML_FOLDER="/kubectl-build-deploy/lagoon/deploymentconfigs-pvcs-cronjobs-backups"
mkdir -p $YAML_FOLDER

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do
  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_NAME_IMAGE="${MAP_SERVICE_NAME_TO_IMAGENAME[${SERVICE_NAME}]}"
  SERVICE_NAME_IMAGE_HASH="${IMAGE_HASHES[${SERVICE_NAME_IMAGE}]}"

  SERVICE_NAME_UPPERCASE=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]')

  COMPOSE_SERVICE=${MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_TYPES_ENTRY}"]}

  # Some Templates need additonal Parameters, like where persistent storage can be found.
  HELM_SET_VALUES=()

  # PERSISTENT_STORAGE_CLASS=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.class false)
  # if [ ! $PERSISTENT_STORAGE_CLASS == "false" ]; then
  #     TEMPLATE_PARAMETERS+=(-p PERSISTENT_STORAGE_CLASS="${PERSISTENT_STORAGE_CLASS}")
  # fi

  PERSISTENT_STORAGE_SIZE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.size false)
  if [ ! $PERSISTENT_STORAGE_SIZE == "false" ]; then
    HELM_SET_VALUES+=(--set "persistentStorage.size=${PERSISTENT_STORAGE_SIZE}")
  fi

  PERSISTENT_STORAGE_PATH=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent false)
  if [ ! $PERSISTENT_STORAGE_PATH == "false" ]; then
    HELM_SET_VALUES+=(--set "persistentStorage.path=${PERSISTENT_STORAGE_PATH}")

    PERSISTENT_STORAGE_NAME=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.name false)
    if [ ! $PERSISTENT_STORAGE_NAME == "false" ]; then
      HELM_SET_VALUES+=(--set "persistentStorage.name=${PERSISTENT_STORAGE_NAME}")
    else
      HELM_SET_VALUES+=(--set "persistentStorage.name=${SERVICE_NAME}")
    fi
  fi

# TODO: we don't need this anymore
  # DEPLOYMENT_STRATEGY=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.deployment\\.strategy false)
  # if [ ! $DEPLOYMENT_STRATEGY == "false" ]; then
  #   TEMPLATE_PARAMETERS+=(-p DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY}")
  # fi

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
      CRONJOB_SCHEDULE=$( /kubectl-build-deploy/scripts/convert-crontab.sh "${NAMESPACE}" "$CRONJOB_SCHEDULE_RAW")
      CRONJOB_COMMAND=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.command)

      if cronScheduleMoreOftenThan30Minutes "$CRONJOB_SCHEDULE_RAW" ; then
        # If this cronjob is more often than 30 minutes, we run the cronjob inside the pod itself
        CRONJOBS_ARRAY_INSIDE_POD+=("${CRONJOB_SCHEDULE} ${CRONJOB_COMMAND}")
      else
        # This cronjob runs less ofen than every 30 minutes, we create a kubernetes native cronjob for it.

        # Add this cronjob to the native cleanup array, this will remove native cronjobs at the end of this script
        NATIVE_CRONJOB_CLEANUP_ARRAY+=($(echo "cronjob-${SERVICE_NAME}-${CRONJOB_NAME}" | awk '{print tolower($0)}'))
        # kubectl stores this cronjob name lowercased

        # if [ ! -f $OPENSHIFT_TEMPLATE ]; then
        #   echo "No cronjob support for service '${SERVICE_NAME}' with type '${SERVICE_TYPE}', please contact the Lagoon maintainers to implement cronjob support"; exit 1;
        # else

        yq write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml "nativeCronjobs.${CRONJOB_NAME,,}.schedule" "$CRONJOB_SCHEDULE"
        yq write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml "nativeCronjobs.${CRONJOB_NAME,,}.command" "$CRONJOB_COMMAND"

        # fi
      fi
    fi

    let CRONJOB_COUNTER=CRONJOB_COUNTER+1
  done


  # if there are cronjobs running inside pods, add them to the deploymentconfig.
  if [[ ${#CRONJOBS_ARRAY_INSIDE_POD[@]} -ge 1 ]]; then
    yq write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'inPodCronjobs' "$(printf '%s\n' "${CRONJOBS_ARRAY_INSIDE_POD[@]}")"
  else
    yq write -i --tag '!!str' -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'inPodCronjobs' ''
  fi

  #OVERRIDE_TEMPLATE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.template false)
  #ENVIRONMENT_OVERRIDE_TEMPLATE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.templates.$SERVICE_NAME false)
  #if [[ "${OVERRIDE_TEMPLATE}" == "false" && "${ENVIRONMENT_OVERRIDE_TEMPLATE}" == "false" ]]; then # No custom template defined in docker-compose or .lagoon.yml,  using the given service ones
    # Generate deployment if service type defines it
    . /kubectl-build-deploy/scripts/exec-kubectl-resources-with-images.sh

  #   # Generate statefulset if service type defines it
  #   OPENSHIFT_STATEFULSET_TEMPLATE="/kubectl-build-deploy/openshift-templates/${SERVICE_TYPE}/statefulset.yml"
  #   if [ -f $OPENSHIFT_STATEFULSET_TEMPLATE ]; then
  #     OPENSHIFT_TEMPLATE=$OPENSHIFT_STATEFULSET_TEMPLATE
  #     . /kubectl-build-deploy/scripts/exec-kubernetes-resources-with-images.sh
  #   fi
  # elif [[ "${ENVIRONMENT_OVERRIDE_TEMPLATE}" != "false" ]]; then # custom template defined for this service in .lagoon.yml, trying to use it

  #   OPENSHIFT_TEMPLATE=$ENVIRONMENT_OVERRIDE_TEMPLATE
  #   if [ ! -f $OPENSHIFT_TEMPLATE ]; then
  #     echo "defined template $OPENSHIFT_TEMPLATE for service $SERVICE_TYPE in .lagoon.yml not found"; exit 1;
  #   else
  #     . /kubectl-build-deploy/scripts/exec-kubernetes-resources-with-images.sh
  #   fi
  # elif [[ "${OVERRIDE_TEMPLATE}" != "false" ]]; then # custom template defined for this service in docker-compose, trying to use it

  #   OPENSHIFT_TEMPLATE=$OVERRIDE_TEMPLATE
  #   if [ ! -f $OPENSHIFT_TEMPLATE ]; then
  #     echo "defined template $OPENSHIFT_TEMPLATE for service $SERVICE_TYPE in $DOCKER_COMPOSE_YAML not found"; exit 1;
  #   else
  #     . /kubectl-build-deploy/scripts/exec-kubernetes-resources-with-images.sh
  #   fi
  #fi


done

##############################################
### APPLY RESOURCES
##############################################

if [ "$(ls -A $YAML_FOLDER/)" ]; then

  if [ "$CI" == "true" ]; then
    # During CI tests of Lagoon itself we only have a single compute node, so we change podAntiAffinity to podAffinity
    find $YAML_FOLDER -type f  -print0 | xargs -0 sed -i s/podAntiAffinity/podAffinity/g
    # During CI tests of Lagoon itself we only have a single compute node, so we change ReadWriteMany to ReadWriteOnce
    find $YAML_FOLDER -type f  -print0 | xargs -0 sed -i s/ReadWriteMany/ReadWriteOnce/g
  fi

  find $YAML_FOLDER -type f -exec cat {} \;
  kubectl apply --insecure-skip-tls-verify -n ${NAMESPACE} -f $YAML_FOLDER/
fi

##############################################
### WAIT FOR POST-ROLLOUT TO BE FINISHED
##############################################

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do

  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_ROLLOUT_TYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.${SERVICE_NAME}.labels.lagoon\\.rollout deployment)

  # Allow the rollout type to be overriden by environment in .lagoon.yml
  ENVIRONMENT_SERVICE_ROLLOUT_TYPE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.rollouts.${SERVICE_NAME} false)
  if [ ! $ENVIRONMENT_SERVICE_ROLLOUT_TYPE == "false" ]; then
    SERVICE_ROLLOUT_TYPE=$ENVIRONMENT_SERVICE_ROLLOUT_TYPE
  fi

  if [ $SERVICE_TYPE == "elasticsearch-cluster" ]; then

    STATEFULSET="${SERVICE_NAME}"
    . /kubectl-build-deploy/scripts/exec-monitor-statefulset.sh

  elif [ $SERVICE_TYPE == "rabbitmq-cluster" ]; then

    STATEFULSET="${SERVICE_NAME}"
    . /kubectl-build-deploy/scripts/exec-monitor-statefulset.sh

  elif [ $SERVICE_ROLLOUT_TYPE == "statefulset" ]; then

    STATEFULSET="${SERVICE_NAME}"
    . /kubectl-build-deploy/scripts/exec-monitor-statefulset.sh

  elif [ $SERVICE_ROLLOUT_TYPE == "deamonset" ]; then

    DAEMONSET="${SERVICE_NAME}"
    . /kubectl-build-deploy/scripts/exec-monitor-deamonset.sh

  elif [ $SERVICE_TYPE == "mariadb-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ $SERVICE_TYPE == "postgres-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ $SERVICE_TYPE == "mongodb-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ ! $SERVICE_ROLLOUT_TYPE == "false" ]; then
    . /kubectl-build-deploy/scripts/exec-monitor-deploy.sh
  fi
done


##############################################
### CLEANUP NATIVE CRONJOBS which have been removed from .lagoon.yml or modified to run more frequently than every 15 minutes
##############################################

CURRENT_CRONJOBS=$(kubectl -n ${NAMESPACE} get cronjobs --no-headers | cut -d " " -f 1 | xargs)

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
    kubectl --insecure-skip-tls-verify -n ${NAMESPACE} delete cronjob ${SINGLE_NATIVE_CRONJOB}
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
          . /kubectl-build-deploy/scripts/exec-tasks-run.sh
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

if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get configmap lagoon-yaml &> /dev/null; then
  # replace it
  kubectl --insecure-skip-tls-verify -n ${NAMESPACE} create configmap lagoon-yaml --from-file=.lagoon.yml -o yaml --dry-run | kubectl replace -f -
else
  # create it
  kubectl --insecure-skip-tls-verify -n ${NAMESPACE} create configmap lagoon-yaml --from-file=.lagoon.yml
fi
