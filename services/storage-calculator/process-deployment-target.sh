#!/bin/bash

if [ -z "$1" ]
  then
    echo 'You must pass the deployment target as the first argument'
    exit
fi

# Load all projects and their environments
all_projects=`cat /tmp/all_projects.json`
projects_with_environments=$(echo "$all_projects" | jq '.data.environments | map(select(.environments | length > 0))')
projects_in_deployment_target=$(echo "$projects_with_environments" | jq 'map(select(.openshift.name=="'$1'"))')
project_names=$(echo "$projects_in_deployment_target" | jq -r 'map(.name) | join("\n")')

echo "$project_names" | parallel --will-cite --jobs ${PARALLEL_PROJECT_JOBS:-2} ./process-project.sh {}
