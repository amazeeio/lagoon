// @flow

const { logger } = require('@lagoon/commons/src/local-logging');

const { getRocketChatInfoForProject } = require('@lagoon/commons/src/api');

const { URL } = require('url');
const http = require('https');

export type ChannelWrapper = {
  ack: (msg: Object) => void,
}

export type RabbitMQMsg = {
  content: Buffer,
  fields: Object,
  properties: Object,
};

export type Project = {
  rocketchat: Object,
  name: string,
};

async function readFromRabbitMQ (msg: RabbitMQMsg, channelWrapperLogs: ChannelWrapper): Promise<void> {
  const {
    content,
    fields,
    properties,
  } = msg;

  const logMessage = JSON.parse(content.toString())

  const {
    severity,
    project,
    uuid,
    event,
    meta,
    message
  } = logMessage

  const appId = msg.properties.appId || ""

 logger.verbose(`received ${event}`, logMessage)

  switch (event) {

    case "github:pull_request:closed:handled":
    case "github:pull_request:opened:handled":
    case "github:pull_request:synchronize:handled":
    case "github:delete:handled":
    case "github:push:handled":
    case "bitbucket:repo:push:handled":
    case "bitbucket:pullrequest:created:handled":
    case "bitbucket:pullrequest:updated:handled":
    case "bitbucket:pullrequest:fulfilled:handled":
    case "bitbucket:pullrequest:rejected:handled":
    case "gitlab:push:handled":
    case "rest:deploy:receive":
    case "rest:remove:receive":
      sendToRocketChat(project, message, '#E8E8E8', ':information_source:', channelWrapperLogs, msg, appId)
      break;

    case "task:deploy-openshift:finished":
    case "task:remove-openshift:finished":
    case "task:remove-openshift-resources:finished":
    case "task:builddeploy-openshift:complete":
      sendToRocketChat(project, message, 'lawngreen', ':white_check_mark:', channelWrapperLogs, msg, appId)
      break;

    case "task:deploy-openshift:retry":
    case "task:remove-openshift:retry":
    case "task:remove-openshift-resources:retry":
      sendToRocketChat(project, message, 'gold', ':warning:', channelWrapperLogs, msg, appId)
      break;

    case "task:deploy-openshift:error":
    case "task:remove-openshift:error":
    case "task:remove-openshift-resources:error":
    case "task:builddeploy-openshift:failed":
      sendToRocketChat(project, message, 'red', ':bangbang:', channelWrapperLogs, msg, appId)
      break;

    case "github:pull_request:closed:CannotDeleteProductionEnvironment":
    case "github:push:CannotDeleteProductionEnvironment":
    case "bitbucket:repo:push:CannotDeleteProductionEnvironment":
    case "gitlab:push:CannotDeleteProductionEnvironment":
    case "rest:remove:CannotDeleteProductionEnvironment":
      sendToRocketChat(project, message, 'gold', ':warning:', channelWrapperLogs, msg, appId)
      break;

    case "unresolvedProject:webhooks2tasks":
    case "unhandledWebhook":
    case "webhooks:receive":
    case "task:deploy-openshift:start":
    case "task:remove-openshift:start":
    case "task:remove-openshift-resources:start":
    case "task:builddeploy-openshift:running":
      // known logs entries that should never go to RocketChat
      channelWrapperLogs.ack(msg)
      break;

    default:
      logger.info(`unhandled log message ${event} ${JSON.stringify(logMessage)}`)
      return channelWrapperLogs.ack(msg)
  }

}

const sendToRocketChat = async (project, message, color, emoji, channelWrapperLogs, msg, appId) => {
  let projectRocketChats;
  try {
    projectRocketChats = await getRocketChatInfoForProject(project)
  }
  catch (error) {
    logger.error(`No RocketChat information found, error: ${error}`)
    return channelWrapperLogs.ack(msg)
  }
  projectRocketChats.forEach(async (projectRocketChat) => {
    const { channel, webhook } = projectRocketChat;
    const rocketchat = new URL(webhook);

    var data = JSON.stringify({
      channel: `#${channel}`,
      attachments: [{
        text: `${emoji} ${message}`,
        color: color,
      }]
    });

    var options = {
      hostname: rocketchat.hostname,
      port: rocketchat.port,
      path: rocketchat.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': data.length
      }
    };

    var req = http.request(options, function(res) {
      res.setEncoding('utf8');
    });

    req.on('error', function(e) {
      logger.error(`problem with request: ${e.message}`);
    });
    req.write(data);
    req.end();
  });
  channelWrapperLogs.ack(msg)
  return
}

module.exports = readFromRabbitMQ;
