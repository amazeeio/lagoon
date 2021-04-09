// @flow

import { sendToLagoonLogs } from '@lagoon/commons/dist/logs';
import {
  getVulnerabilitiesPayloadFromHarbor,
} from '@lagoon/commons/dist/harborApi';
import * as R from 'ramda';
import uuid4 from 'uuid4';

import {
  getProjectByName,
  getProblemHarborScanMatches,
  getEnvironmentByOpenshiftProjectName,
  getOpenShiftInfoForProject,
} from '@lagoon/commons/dist/api';

const HARBOR_WEBHOOK_SUCCESSFUL_SCAN = "Success";

const DEFAULT_REPO_DETAILS_REGEX = "^(?<lagoonProjectName>.+)\/(?<lagoonEnvironmentName>.+)\/(?<lagoonServiceName>.+)$";

const DEFAULT_REPO_DETAILS_MATCHER = {
  defaultProjectName: "",
  defaultEnvironmentName: "",
  defaultServiceName: "",
  regex: DEFAULT_REPO_DETAILS_REGEX,
};

 export async function harborScanningCompleted(
  WebhookRequestData,
  channelWrapperWebhooks
) {
  const { webhooktype, event, uuid, body } = WebhookRequestData;
  const HARBOR_WEBHOOK_SUCCESSFUL_SCAN = "Success";

  try {
    let {
      resources,
      repository,
      scanOverview,
      lagoonProjectName,
      lagoonEnvironmentName,
      lagoonServiceName,
      harborScanId,
    } = await validateAndTransformIncomingWebhookdata(body);

    if(scanOverview.scan_status !== HARBOR_WEBHOOK_SUCCESSFUL_SCAN) {
      sendToLagoonLogs(
        'error',
        '',
        uuid,
        `${webhooktype}:${event}:unhandled`,
        { data: body },
        `Received a scan report of status "${scanOverview.scan_status}" - ignoring`
      );

      return;
    }

    let vulnerabilities = [];
    vulnerabilities = await getVulnerabilitiesFromHarbor(harborScanId);

    let { id: lagoonProjectId } = await getProjectByName(lagoonProjectName);

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

    let size = 20; let batchedArrVulns = [];
    if (vulnerabilities) {
      for (let i = 0; i < vulnerabilities.length; i += size) {
        batchedArrVulns.push(vulnerabilities.slice(i, i + size));
      }
    }

    if (batchedArrVulns) {
      batchedArrVulns.forEach(async (element) => {
        let messageBody = {
          lagoonProjectId,
          lagoonProjectName,
          lagoonEnvironmentId: environmentDetails.id,
          lagoonEnvironmentName: environmentDetails.name,
          lagoonServiceName,
          vulnerabilities: element,
        };

        const webhookData = generateWebhookData(
          WebhookRequestData.giturl,
          'problems',
          'harbor:scanningresultfetched',
          messageBody
        );

        const buffer = new Buffer(JSON.stringify(webhookData));

        await channelWrapperWebhooks.publish(`lagoon-webhooks`, '', buffer, {
          persistent: true,
        });
      });
    }
  } catch (error) {
    sendToLagoonLogs(
      'error',
      '',
      uuid,
      `${webhooktype}:${event}:unhandled`,
      { data: body },
      `Could not fetch Harbor scan results, reason: ${error}`
    );
  }
}

/**
 * This function will take an incoming Harbor webhook and decompose it
 * into a more useable format
 *
 * @param {*} rawData
 */
const validateAndTransformIncomingWebhookdata = async (rawData) => {
  let { resources, repository } = rawData.event_data;

  if (!repository.repo_full_name) {
    throw generateError(
      'InvalidHarborInput',
      'Unable to find repo_full_name in body.event_data.repository'
    );
  }

  // scan_overview is tricky because the property doesn't have an obvious name.
  // We convert it to an array of objects with the old property as a member
  let scanOverviewArray = R.toPairs(resources[0].scan_overview).map((e) => {
    let obj = e[1];
    obj.scan_key = e[0];
    return obj;
  });

  let harborScanPatternMatchers = await getProblemHarborScanMatches();

  let {
    lagoonProjectName,
    lagoonEnvironmentName,
    lagoonServiceName,
   } = matchRepositoryAgainstPatterns(repository.repo_full_name, harborScanPatternMatchers.allProblemHarborScanMatchers);

  return {
    resources,
    repository,
    scanOverview: scanOverviewArray.pop(),
    lagoonProjectName,
    lagoonEnvironmentName,
    lagoonServiceName,
    harborScanId: repository.repo_full_name,
  };
};

const generateError = (name, message) => {
  let e = new Error(message);
  e.name = name;
  return e;
};

const matchRepositoryAgainstPatterns = (repoFullName, matchPatterns = []) => {
  const matchingRes = matchPatterns.filter((e) => generateRegex(e.regex).test(repoFullName));
  if(matchingRes.length > 1) {
    const stringifyMatchingRes = matchingRes.reduce((prevRetString, e) => `${e.regex},${prevRetString}`, '');
    throw generateError("InvalidHarborConfiguration",
      `We have multiple matching regexes for '${repoFullName}'`
    );
  } else if (matchingRes.length == 0 && !generateRegex(DEFAULT_REPO_DETAILS_MATCHER.regex).test(repoFullName)) {
    throw generateError("HarborError",
    `We have no matching regexes, including default, for '${repoFullName}'`
    );
  }

  const matchPatternDetails = matchingRes.pop() || DEFAULT_REPO_DETAILS_MATCHER;
  const {
    lagoonProjectName = matchPatternDetails.defaultLagoonProject,
    lagoonEnvironmentName = matchPatternDetails.defaultLagoonEnvironment,
    lagoonServiceName = matchPatternDetails.defaultLagoonService,
  } = extractRepositoryDetailsGivenRegex(repoFullName, matchPatternDetails.regex);

  return {lagoonProjectName, lagoonEnvironmentName, lagoonServiceName};
}

const generateRegex = R.memoizeWith(R.identity, re => new RegExp(re));

const extractRepositoryDetailsGivenRegex = (repoFullName, pattern = DEFAULT_REPO_DETAILS_REGEX) => {
  const re = generateRegex(pattern);
  const match = re.exec(repoFullName);
  return match.groups || {};
}

const generateWebhookData = (
  webhookGiturl,
  webhooktype,
  event,
  body,
  id = null
) => {
  return {
    webhooktype: webhooktype,
    event: event,
    giturl: webhookGiturl,
    uuid: id ? id : uuid4(),
    body: body,
  };
};

const extractVulnerabilities = (harborScanResponse) => {
  for (let [key, value] of Object.entries(harborScanResponse)) {
    let potentialStore: any = value;
    if (potentialStore.hasOwnProperty('vulnerabilities')) {
      return potentialStore.vulnerabilities;
    }
  }
  throw new ProblemsHarborConnectionError(
    "Scan response from Harbor does not contain a 'vulnerabilities' key"
  );
};

const getVulnerabilitiesFromHarbor = async (scanId) => {
  let harborPayload = null;
  try {
    harborPayload = await getVulnerabilitiesPayloadFromHarbor(
      scanId
    );
  } catch (error) {
    throw error;
  }

  return extractVulnerabilities(harborPayload);
};

class ProblemsHarborConnectionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'problems-harborConnectionError';
  }
}

class ProblemsInvalidWebhookData extends Error {
  constructor(message) {
    super(message);
    this.name = 'problems-invalidWebhookData';
  }
}

