#!/bin/bash

# Load all projects and their environments
all_projects=$(./api-query.sh 'query {
  environments:allProjects {
    name
    storageCalc
    openshift {
      consoleUrl
      token
      name
    }
    environments {
      openshiftProjectName
      name
      id
    }
  }
}')

echo "$all_projects" > /tmp/all_projects.json

projects_with_environments=$(echo "$all_projects" | jq '.data.environments | map(select(.environments | length > 0))')
deployment_targets=$(echo "$projects_with_environments" | jq -r 'map(.openshift.name) | unique | join("\n")')

echo "Calculating storage in following deployment targets:"
echo "$deployment_targets"
echo ""
echo "$deployment_targets" | parallel --will-cite --ungroup ./process-deployment-target.sh {}
