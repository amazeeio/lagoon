#!/bin/bash

# Open a remote shell session to a container

# takes arguments:
# $1: API JWT Admin Token
# $2: ssh public key of the connecting user
# $3: name of oc project
# Optional:
#   service=xxx (service to connect to)
#   container=xxx (container to connect to)
#   any additonal parameters (run in the container via 'sh -c')

API_ADMIN_TOKEN=$1
USER_SSH_KEY=$2
REQUESTED_PROJECT=$3
shift 3

# check if project is a valid one
if [[ -n "$REQUESTED_PROJECT" ]]; then
  if [[ "$REQUESTED_PROJECT" =~ ^[A-Za-z0-9-]+$ ]]; then
    PROJECT=$REQUESTED_PROJECT
  else
    echo "ERROR: given project '$REQUESTED_PROJECT' contains illegal characters";
    exit
  fi
else
  echo "ERROR: no project defined";
  exit 1
fi

##
## Check if this user has access to this OpenShift project by using an API token of that user
##
TOKEN=${LAGOON_TOKEN:=$(./token.sh "$API_ADMIN_TOKEN" "$USER_SSH_KEY")}
BEARER="Authorization: bearer $TOKEN"
GRAPHQL="query userCanSshToEnvironment {
  userCanSshToEnvironment(openshiftProjectName: \"$PROJECT\") {
    openshiftProjectName
  }
}"
# GraphQL query on single line with \\n for newlines and escaped quotes
QUERY=$(echo $GRAPHQL | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g' | awk -F'\n' '{if(NR == 1) {printf $0} else {printf "\\n"$0}}')
ENVIRONMENT=$(curl -s -XPOST -H 'Content-Type: application/json' -H "$BEARER" api:3000/graphql -d "{\"query\": \"$QUERY\"}")

# Check if the returned OpenShift projectname is the same as the one being requested. This will only be true if the user actually has access to this environment
if [[ ! "$(echo $ENVIRONMENT | jq --raw-output '.data.userCanSshToEnvironment.openshiftProjectName')" == "$PROJECT" ]]; then
  echo "no access to $PROJECT"
  exit
fi

##
## Get OpenShift Console URL and Token with Admin Token
##
ADMIN_BEARER="Authorization: bearer $API_ADMIN_TOKEN"
ADMIN_GRAPHQL="query getEnvironmentByOpenshiftProjectName {
  environmentByOpenshiftProjectName(openshiftProjectName: \"$PROJECT\") {
    project {
      openshift {
        consoleUrl
        token
        name
      }
    }
  }
}"
# GraphQL query on single line with \\n for newlines and escaped quotes
ADMIN_QUERY=$(echo $ADMIN_GRAPHQL | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g' | awk -F'\n' '{if(NR == 1) {printf $0} else {printf "\\n"$0}}')
ADMIN_ENVIRONMENT=$(curl -s -XPOST -H 'Content-Type: application/json' -H "$ADMIN_BEARER" api:3000/graphql -d "{\"query\": \"$ADMIN_QUERY\"}")

OPENSHIFT_CONSOLE=$(echo $ADMIN_ENVIRONMENT | jq --raw-output '.data.environmentByOpenshiftProjectName.project.openshift.consoleUrl')
OPENSHIFT_TOKEN=$(echo $ADMIN_ENVIRONMENT | jq --raw-output '.data.environmentByOpenshiftProjectName.project.openshift.token')
OPENSHIFT_NAME=$(echo $ADMIN_ENVIRONMENT | jq --raw-output '.data.environmentByOpenshiftProjectName.project.openshift.name')

##
## Check if we have a service and container given, if yes use them.
## Fallback is the cli service
##
if [[ $1 =~ ^service=([A-Za-z0-9-]+)$ ]]; then
  SERVICE=${BASH_REMATCH[1]}
  shift

  if [[ $1 =~ ^container=([A-Za-z0-9-]+)$ ]]; then
    CONTAINER=${BASH_REMATCH[1]}
    shift
  fi
else
  SERVICE=cli
fi

echo "Incoming Remote Shell Connection: project='${PROJECT}' openshift='${OPENSHIFT_NAME}' service='${SERVICE}' container='${CONTAINER}' command='$*'"  >> /proc/1/fd/1

# This only happens on local development with minishift.
# Login as developer:deveeloper and get the token
if [[ $OPENSHIFT_TOKEN == "null" ]]; then
  KUBECONFIG="/tmp/kube" /usr/bin/oc --insecure-skip-tls-verify login -p developer -u developer ${OPENSHIFT_CONSOLE} > /dev/null
  OPENSHIFT_TOKEN=$(KUBECONFIG="/tmp/kube" oc --insecure-skip-tls-verify whoami -t)
fi

OC="/usr/bin/oc --insecure-skip-tls-verify -n ${PROJECT} --token=${OPENSHIFT_TOKEN} --server=${OPENSHIFT_CONSOLE} "

# If there is a deploymentconfig for the given service
if [[ "$OC get deploymentconfigs -l service=${SERVICE}" ]]; then
  DEPLOYMENTCONFIG=$($OC get deploymentconfigs -l service=${SERVICE} -o name)
  # If the deploymentconfig is scaled to 0, scale to 1
  if [[ $($OC get ${DEPLOYMENTCONFIG} -o go-template --template='{{.status.replicas}}') == "0" ]]; then

    $OC scale --replicas=1 ${DEPLOYMENTCONFIG} >/dev/null 2>&1

    # Wait until the scaling is done
    while [[ ! $($OC get ${DEPLOYMENTCONFIG} -o go-template --template='{{.status.readyReplicas}}') == "1" ]]
    do
      sleep 1
    done
  fi
fi

POD=$($OC get pods -l service=${SERVICE} -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | .metadata.name' | head -n 1)

if [[ ! $POD ]]; then
  echo "No running pod found for service ${SERVICE}"
  exit 1
fi

# If no container defined, load the name of the first container
if [[ -z ${CONTAINER} ]]; then
  CONTAINER=$($OC get pod ${POD} -o json | jq --raw-output '.spec.containers[0].name')
fi

if [ -t 1 ]; then
  TTY_PARAMETER="-t"
else
  TTY_PARAMETER=""
fi

if [[ -z "$*" ]]; then
  exec $OC exec ${POD} -c ${CONTAINER} -i ${TTY_PARAMETER} -- sh
else
  exec $OC exec ${POD} -c ${CONTAINER} -i ${TTY_PARAMETER} -- sh -c "$*"
fi
