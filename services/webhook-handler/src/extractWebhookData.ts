import uuid4 from 'uuid4';
import url from 'url';
import R from 'ramda';
import { IncomingMessage } from 'http';
import { secureGitlabSystemHooks } from '@lagoon/commons/dist/gitlabApi';

import type { RawData, WebhookRequestData } from './types';

/**
 * This function will check request headers for
 * service specific data like github / gitlab / etc.
 * if the request method is POST.
 *
 * Will eventually generate 'custom' webhook data on
 * GET requests.
 *
 * Will throw an error on malformed request headers,
 * non-json body data or unsupported method.
 */
export function extractWebhookData(req: IncomingMessage, body: string): WebhookRequestData {
  const { method, headers } = req;

  let parameters: any = {};
  let webhooktype;
  let event;
  let uuid;
  let bodyObj: RawData;
  let giturl;

  if (method === 'POST') {
    try {
      bodyObj = body == null || body === '' ? {} : JSON.parse(body);
    } catch (e) {
      throw new Error(`Request body is not parsable as JSON. Are you sure you have enabled application/json as the webhook content type? ${e}.`);
    }

    if ('x-gitea-event' in req.headers) {
      webhooktype = 'gitea';
      event = req.headers['x-gitea-event'];
      uuid = req.headers['x-gitea-delivery'];
      giturl = R.path(['repository', 'ssh_url'], bodyObj);
    } else if ('x-github-event' in req.headers) {
      webhooktype = 'github';
      event = req.headers['x-github-event'];
      uuid = req.headers['x-github-delivery'];
      giturl = R.path(['repository', 'ssh_url'], bodyObj);
    } else if ('x-gitlab-event' in req.headers) {
      webhooktype = 'gitlab';
      event = bodyObj.object_kind || bodyObj.event_name;
      uuid = uuid4();
      giturl = R.path(['project', 'git_ssh_url'], bodyObj);

      // This is a system webhook
      if (R.contains(event, secureGitlabSystemHooks)) {
        // Ensure the system hook came from gitlab
        if (!('x-gitlab-token' in req.headers) || req.headers['x-gitlab-token'] !== process.env.GITLAB_SYSTEM_HOOK_TOKEN) {
          throw new Error('Gitlab system hook secret verification failed');
        }
      }
    } else if ('x-event-key' in req.headers) {
      webhooktype = 'bitbucket'
      event = req.headers['x-event-key']
      uuid = req.headers['x-request-uuid']
      // Bitbucket does not provide a git-ssh URI to the repo in the webhook payload
      // We the html repo link (example https://bitbucket.org/teamawesome/repository) to extract the correct target domain (bitbucket.org)
      // this could be bitbuck.org(.com) or a private bitbucket server
      // Also the git server could be running on another port than 22, so there is a second regex match for `:[0-9]`
      const regexmatch = bodyObj.repository.links.html.href.match(/https?:\/\/([a-z0-9-_.]*)(:[0-9]*)?\//i)
      // The first match is the domain
      const domain = regexmatch[1]
      if (!regexmatch[2]) {
        // If there is no 2nd regex match, ther is no port found and it's not added to the URL
        // use the extracted domain and repo full_name (teamawesome/repository) to build the git URI, example git@bitbucket.org:teamawesome/repository.git
        giturl = `git@${domain}:${bodyObj.repository.full_name}.git`
      } else {
        // If there is a second regex match, we add the port to the url and also format the url with `ssh://` in front which is needed for requests with anoter port
        const port = regexmatch[2]
        giturl = `ssh://git@${domain}${port}/${bodyObj.repository.full_name}.git`
      }
    // TODO: Use when single snapshot data is fixed
    // } else if (bodyObj.backup_metrics) {
    //   webhooktype = 'resticbackup';
    //   event = 'snapshot:finished'
    //   uuid = uuid4();
    } else if (bodyObj.snapshots) {
      webhooktype = 'resticbackup';
      event = 'snapshot:sync'
      uuid = uuid4();
    } else if (bodyObj.restore_location) {
      webhooktype = 'resticbackup';
      event = 'restore:finished';
      uuid = uuid4();
    } else if (bodyObj.type && bodyObj.type == 'SCANNING_COMPLETED') {
      webhooktype = 'problems';
      event = 'harbor:scanningcompleted';
      uuid = uuid4();
    } else if (bodyObj.lagoonInfo) {
      webhooktype = 'problems';
      event = 'drutiny:resultset';
      uuid = uuid4();
    } else {
      throw new Error('No supported event header found on POST request');
    }
  } else if (method === 'GET') {
    try {
      webhooktype = 'custom';
      event = 'push';
      uuid = uuid4();

      const parsedUrl = url.parse(req.url, true); // true to get query as object
      const { query = {} } = parsedUrl;

      // TODO: Potential for refactor
      const getParam = (name: string, shouldThrow: boolean = false): string => {
        const value = query[name];
        if (value == null && shouldThrow) {
          throw new Error(`Query param '${name}' not found!`);
        }
        if (value === '' && shouldThrow) {
          throw new Error(`Query param '${name}' is empty!`);
        }
        // @ts-ignore
        return value;
      };

      giturl = req.url;
      parameters.url = getParam('url', true);
      parameters.branch = getParam('branch', true);
      parameters.sha = getParam('sha') || '';
      bodyObj = parameters;
    } catch (e) {
      throw new Error(`Error in handling GET request: ${e.message}`);
    }
  } else {
    throw new Error(`Unsupported request method: ${method}`);
  }

  const ret: WebhookRequestData = {
    webhooktype,
    event,
    body: bodyObj
  };

  if (giturl != null) {
    ret.giturl = giturl;
  }

  if (uuid != null) {
    ret.uuid = uuid;
  }

  return ret;
}
