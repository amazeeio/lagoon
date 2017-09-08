// @flow

const uuid4 = require('uuid4');
const url = require('url');
const R = require('ramda');

import type { RawData, WebhookRequestData } from './types';

type Req = {
  method: string,
  url: string,
  headers: { [key: string]: string }
};

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
function extractWebhookData(req: Req, body?: string): WebhookRequestData {
  const { method, headers } = req;

  const parameters = {};
  let webhooktype;
  let event;
  let uuid;
  let bodyObj: ?RawData;
  let giturl;

  if (method === 'POST') {
    try {
      bodyObj = body == null || body === '' ? {} : JSON.parse(body);
    } catch (e) {
      throw new Error(`request body is not parsable as JSON: ${e}`);
    }

    if ('x-github-event' in req.headers) {
      webhooktype = 'github';
      event = req.headers['x-github-event'];
      uuid = req.headers['x-github-delivery'];
      giturl = R.path(['repository', 'ssh_url'], bodyObj);
    } else if ('x-gitlab-event' in req.headers) {
      webhooktype = 'gitlab';
      event = bodyObj.object_kind;
      uuid = uuid4();
      giturl = R.path(['project', 'git_ssh_url'], bodyObj);
    } else if ('x-event-key' in req.headers) {
      webhooktype = 'bitbucket'
      event = req.headers['x-event-key']
      uuid = req.headers['x-request-uuid']
      /*
      bitbucket does not provide a git-ssh URI to the repo in the webhook payload,
      here we transform the the https url into the ssh URI
      ex: https://bitbucket.org/teamawesome/repository => git@bitbucket.org:teamawesome/repository.git
      start by grabbing the repo name from the payload
      */
      // bodyObj.repository.full_name is `<organization>/<reponame>`, so like `teamawesome/repository`
      // we escape the special chars: `teamawesome\/repository`
      const fullName = bodyObj.repository.full_name.replace(/[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&")

      // Set up a RegExp object to match a URL that has the repo name in it, example: /https?:\/\/([a-z0-9-_.]*).*\/teamawesome\/repository$/i
      const pat =  new RegExp(`https?:\/\/([a-z0-9-_.]*).*${fullName}$`,"i")
      // Use the html repo link (example https://bitbucket.org/teamawesome/repository) and RegExp to extract the correct target domain
      // this could be bitbuck.org(.com) or a private bitbucket server
      const repoPath = bodyObj.repository.links.html.href.match(pat)
      // use the extracted domain and repo name to build the git URI, example git@bitbucket.org:teamawesome/repository.git
      giturl = `git@${repoPath[1]}:${bodyObj.repository.full_name}.git`
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

module.exports = extractWebhookData;
