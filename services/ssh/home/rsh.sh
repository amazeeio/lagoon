#!/bin/bash

# takes arguments:
# 1: name of oc project
# 2(optional): override for deploymentconfig

if [[ "$1" =~ ^[A-Za-z0-9-]+$ ]]; then
  project=$1
else
  echo "ERROR: no project defined";
  exit
fi

if [[ "$2" =~ ^[A-Za-z0-9-]+$ ]]; then
  deploymentconfig=$2
else
  deploymentconfig=cli
fi

# If the deploymentconfig is scaled to 0, scale to 1
if [ $(/usr/bin/oc -n ${project} deploymentconfigs/${deploymentconfig} -o go-template --template='{{.status.replicas}}') == "0" ]; then
  /usr/bin/oc -n ${project} scale --replicas=1 dc/${deploymentconfig} >/dev/null 2>&1
fi

if [ -z "$SSH_ORIGINAL_COMMAND" ]; then
  exec /usr/bin/oc -n ${project} rsh dc/${deploymentconfig} bash
else
  exec /usr/bin/oc -n ${project} rsh dc/${deploymentconfig} bash -c "$SSH_ORIGINAL_COMMAND"
fi