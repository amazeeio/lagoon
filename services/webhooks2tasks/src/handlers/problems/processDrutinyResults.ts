// @flow

import {
  addProblem,
  deleteProblemsFromSource,
  getProblemsforProjectEnvironment,
} from'@lagoon/commons/dist/api';
import { sendToLagoonLogs } from '@lagoon/commons/dist/logs';
const DRUTINY_VULNERABILITY_SOURCE_BASE = 'Drutiny';
const DRUTINY_SERVICE_NAME = 'cli';
const DRUTINY_PACKAGE_NAME = ''
import {
  getProjectByName,
  getEnvironmentByOpenshiftProjectName,
  getOpenShiftInfoForProject,
} from '@lagoon/commons/dist/api';
import { generateProblemsWebhookEventName } from "./webhookHelpers";
import * as R from 'ramda';

const ERROR_STATES = ["error", "failure"];
const SEVERITY_LEVELS = [
  "NONE",
  "UNKNOWN",
  "NEGLIGIBLE",
  "LOW",
  "MEDIUM",
  "HIGH",
  "CRITICAL"
];
const DEFAULT_SEVERITY_LEVEL = "NEGLIGIBLE";

export async function processDrutinyResultset(
  WebhookRequestData,
  channelWrapperWebhooks
) {

  const { webhooktype, event, uuid, body } = WebhookRequestData;
  const { lagoonInfo, results, profile: drutinyProfile } = body;

  try {
        const lagoonProjectName =
          lagoonInfo.LAGOON_DRUTINY_PROJECT_NAME ||
          lagoonInfo.LAGOON_PROJECT ||
          lagoonInfo.LAGOON_SAFE_PROJECT;

        if (!lagoonProjectName) {
          throw new Error('No project name passed in Drutiny results');
        }

        const lagoonEnvironmentName =
          lagoonInfo.LAGOON_DRUTINY_ENVIRONMENT_NAME ||
          lagoonInfo.LAGOON_ENVIRONMENT ||
          lagoonInfo.LAGOON_GIT_BRANCH;

        if (!lagoonEnvironmentName) {
          throw new Error('No environment name passed in Drutiny results');
        }

        const { id: lagoonProjectId } = await getProjectByName(
          lagoonProjectName
        );

        const result = await getOpenShiftInfoForProject(lagoonProjectName);
        const projectOpenShift = result.project;

        const ocsafety = string =>
        string.toLocaleLowerCase().replace(/[^0-9a-z-]/g, '-');

        let openshiftProjectName = projectOpenShift.openshiftProjectPattern
        ? projectOpenShift.openshiftProjectPattern
            .replace('${branch}', ocsafety(lagoonEnvironmentName))
            .replace('${project}', ocsafety(lagoonProjectName))
        : ocsafety(`${lagoonProjectName}-${lagoonEnvironmentName}`);

        const environmentResult = await getEnvironmentByOpenshiftProjectName(openshiftProjectName);
        const environmentDetails: any = R.prop('environmentByOpenshiftProjectName', environmentResult)

        const lagoonEnvironmentId = environmentDetails.id;
        const lagoonServiceName = DRUTINY_SERVICE_NAME;
        const drutinyVulnerabilitySource = `${DRUTINY_VULNERABILITY_SOURCE_BASE}-${drutinyProfile}`;

        //Let's get the existing problems before removing them ...
        const existingProblemSet = (
          await getProblemsforProjectEnvironment(
            lagoonEnvironmentName,
            lagoonProjectId
          )
        )
          .filter((e) => e.service == lagoonServiceName)
          .reduce((prev, current) => prev.concat([current.identifier]), []);

        await deleteProblemsFromSource(
          environmentDetails.id,
          drutinyVulnerabilitySource,
          DRUTINY_SERVICE_NAME
        );

        if (results) {
          results
            .filter((e) => ERROR_STATES.includes(e.type))
            .forEach((element) => {
              addProblem({
                environment: lagoonEnvironmentId,
                identifier: element.name,
                severity: convertSeverityLevels(element.severity),
                source: drutinyVulnerabilitySource,
                description: element.description,
                data: JSON.stringify(element),
                service: DRUTINY_SERVICE_NAME,
                severityScore: null,
                associatedPackage: 'Drupal',
                version: null,
                fixedVersion: null,
                links: null,
              })
                .then(() => {
                    sendToLagoonLogs(
                      'info',
                      lagoonProjectName,
                      uuid,
                      generateProblemsWebhookEventName({
                        source: 'drutiny',
                        severity: convertSeverityLevels(element.severity),
                        isNew: !existingProblemSet.includes(element.name)
                      }),
                      {
                        lagoonProjectId,
                        lagoonProjectName,
                        lagoonEnvironmentId,
                        lagoonEnvironmentName,
                        lagoonServiceName,
                        severity: convertSeverityLevels(element.severity),
                        vulnerability: element,
                      },
                      `New problem found for ${lagoonProjectName}:${lagoonEnvironmentName}:${lagoonServiceName}.\n Severity: ${element.severity}.\n Description: ${element.description}`
                    );
                })
                .catch((error) =>
                  sendToLagoonLogs(
                    'error',
                    '',
                    uuid,
                    `${webhooktype}:${event}:problem_insert_error`,
                    {},
                    `Error inserting problem id ${element.id} for ${lagoonProjectId}:${environmentDetails.id} -- ${error.message}`
                  )
                );
            });
        }
      } catch (error) {
    sendToLagoonLogs(
      'error',
      '',
      uuid,
      `${webhooktype}:${event}:unhandled`,
      {},
      `Could not process incoming Drutiny scan results, reason: ${error}`
    );
  }
}

const convertSeverityLevels = (level) => {
  level = level.toUpperCase();
  if(SEVERITY_LEVELS.includes(level)) {
    return level;
  }

  return DEFAULT_SEVERITY_LEVEL;
}
