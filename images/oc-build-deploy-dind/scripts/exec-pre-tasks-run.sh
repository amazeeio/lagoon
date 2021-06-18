#!/bin/bash

# if there is a deploymentconfig for the given service
if [[ $(oc -n ${OPENSHIFT_PROJECT} get deploymentconfigs --no-headers=true -o name -l service=${SERVICE_NAME}| wc -l) -gt 0 ]]; then
  DEPLOYMENTCONFIG=$(oc -n ${OPENSHIFT_PROJECT} get deploymentconfigs -l service=${SERVICE_NAME} -o name)
  # check if deploymenconfig has at least 1 ready pod, if not, scale and check again in 3 secounds.
  while [[ $(oc -n ${OPENSHIFT_PROJECT} get ${DEPLOYMENTCONFIG} -o go-template --template='{{.status.readyReplicas}}') = "<no value>" ]] || [[ $(oc -n ${OPENSHIFT_PROJECT} get ${DEPLOYMENTCONFIG} -o go-template --template='{{.status.readyReplicas}}') = "0" ]]
  do
    # Sending the scaling command while it already scaling is no problem for the Kubernetes API
    oc -n ${OPENSHIFT_PROJECT} scale --replicas=1 ${DEPLOYMENTCONFIG}
    sleep 3
  done
fi

POD=$(oc -n ${OPENSHIFT_PROJECT} get pods -l service=${SERVICE_NAME} -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running")] | first | .metadata.name // empty')

if [[ ! $POD ]]; then
  echo "No running pod found for ${SERVICE_NAME}, skipping"
else

  if [[ $CONTAINER == "false" ]]; then
    CONTAINER_PARAMETER=""
  else
    CONTAINER_PARAMETER="-c ${CONTAINER}"
  fi

  # Container entrypoints aren't automatically invoked for `oc exec` or `oc rsh`
  oc -n ${OPENSHIFT_PROJECT} exec ${POD} ${CONTAINER_PARAMETER} -i -- /lagoon/entrypoints.sh ${SHELL} -c "${COMMAND}"

fi
