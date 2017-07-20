// @flow

import { logger } from '@amazeeio/amazeeio-local-logging';

import { getSlackinfoForSiteGroup } from '@amazeeio/amazeeio-api';

var IncomingWebhook = require('@slack/client').IncomingWebhook;

export type ChannelWrapper = {
  ack: (msg: Object) => void,
}

export type RabbitMQMsg = {
  content: Buffer,
  fields: Object,
  properties: Object,
};

export type SiteGroup = {
  slack: Object,
  siteGroupName: string,
};

export default async function readFromRabbitMQ (msg: RabbitMQMsg, channelWrapper: ChannelWrapper): Promise<void> {
  const {
    content,
    fields,
    properties,
  } = msg;

  const logMessage = JSON.parse(content.toString())

  const {
    severity,
    sitegroup,
    uuid,
    event,
    meta,
    message
  } = logMessage

  const appId = msg.properties.appId || ""

 logger.verbose(`received ${event}`, logMessage)

  switch (event) {

    case "github:pull_request:closed:handled":
    case "github:delete:handled":
    case "github:push:handled":
    case "rest:deploy:receive":
    case "rest:remove:receive":
      sendToSlack(sitegroup, message, '#E8E8E8', ':information_source:', channelWrapper, msg, appId)
      break;

    case "task:remove-openshift-resources:finished":
    case "task:deploy-openshift:finished":
    case "task:jobwatch:finished":
      sendToSlack(sitegroup, message, 'good', ':white_check_mark:', channelWrapper, msg, appId)
      break;

    case "task:deploy-openshift:retry":
    case "task:remove-openshift-resources:retry":
      sendToSlack(sitegroup, message, 'warning', ':warning:', channelWrapper, msg, appId)
      break;

    case "task:remove-openshift-resources:error":
    case "task:deploy-openshift:error":
    case "task:jobwatch:error":
      sendToSlack(sitegroup, message, 'danger', ':bangbang:', channelWrapper, msg, appId)
      break;

    case "unresolvedSitegroup:webhooks2tasks":
    case "unhandledWebhook":
    case "webhooks:receive":
    case "task:remove-openshift-resources:start":
    case "task:deploy-openshift:start":
      // known logs entries that should never go to slack
      channelWrapper.ack(msg)
      break;

    default:
      logger.warn(`unhandled log message ${event} ${JSON.stringify(logMessage)}`)
      return channelWrapper.ack(msg)
  }

}

const sendToSlack = async (sitegroup, message, color, emoji, channelWrapper, msg, appId) => {

  let sitegroupSlack;
  try {
    sitegroupSlack = await getSlackinfoForSiteGroup(sitegroup)
  }
  catch (error) {
    logger.error(`No Slack information found, error: ${error}`)
    return channelWrapper.ack(msg)
  }

  await new IncomingWebhook(sitegroupSlack.slack.webhook, {
    channel: sitegroupSlack.slack.channel,
  }).send({
    attachments: [{
      text: `${emoji} ${message}`,
      color: color,
      "mrkdwn_in": ["pretext", "text", "fields"],
      footer: appId
    }]
  });
  channelWrapper.ack(msg)
  return
}
