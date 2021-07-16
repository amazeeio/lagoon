import { Pool } from 'mariadb';
import { opendistroSecurityClient } from '../../clients/opendistroSecurityClient';
import { kibanaClient } from '../../clients/kibanaClient';
import { logger } from '../../loggers/logger';
import { Helpers as projectHelpers } from '../project/helpers';

export const OpendistroSecurityOperations = (
  sqlClientPool: Pool,
  GroupModel
) => ({
  syncGroup: async (groupName, groupProjectIDs) => {
    const groupProjectNames = [];
    // groupProjectIDs is a comma separated string of IDs, split it up and remove any entries with `''`
    const groupProjectIDsArray = groupProjectIDs
      .split(',')
      .filter(groupProjectID => groupProjectID !== '');

    // Load project name by ID and add to groupProjectNames array
    for (const groupProjectID of groupProjectIDsArray) {
      try {
        const project = await projectHelpers(sqlClientPool).getProjectById(
          groupProjectID
        );
        const projectName = project.name;
        // Within elasticsearch we don't support any special characters, except dashes, convert all special characters to them and make it lowercase
        const openshiftProjectNameStyle = projectName
          .toLocaleLowerCase()
          .replace(/[^0-9a-z-]/g, '-');
        groupProjectNames.push(openshiftProjectNameStyle);
      } catch (error) {
        logger.error(
          `Error processing project id '${groupProjectID}' of '${groupName}: ${error}`
        );
      }
    }

    const groupProjectPermissions = {
      body: {
        index_permissions: [
          {
            index_patterns: [],
            allowed_actions: ['read']
          }
        ],
        tenant_permissions: [
          {
            tenant_patterns: [groupName],
            allowed_actions: ['kibana_all_write']
          }
        ]
      }
    };

    // If this group has no projects assigned, we create a fake project as OpendistroSecurity needs at least one indicies permission to work.
    if (groupProjectIDsArray.length === 0) {
      groupProjectPermissions.body.index_permissions[0].index_patterns.push(
        `${groupName}-has-no-project`
      );
    } else {
      // inject project permissions into permission array
      groupProjectNames.forEach(projectName =>
        groupProjectPermissions.body.index_permissions[0].index_patterns.push(
          `*-${projectName}-*`
        )
      );
    }

    try {
      // Create a new OpendistroSecurity Role for this Group with read permissions for all Projects assigned to this group
      await opendistroSecurityClient.put(
        `roles/${groupName}`,
        groupProjectPermissions
      );
      logger.debug(
        `${groupName}: Created OpendistroSecurity role "${groupName}"`
      );
    } catch (err) {
      logger.error(`OpendistroSecurity create role error: ${err}`);
    }

    try {
      // Create a new Tenant for this Group
      await opendistroSecurityClient.put(`tenants/${groupName}`, { body: { description: 'Lagoon group tenant' } });
      logger.debug(`${groupName}: Created Tentant "${groupName}"`);
    } catch (err) {
      logger.error(`Opendistro-Security create tenant error: ${err}`);
    }

    // Create index-patterns for this group
    // @TODO Remove index-patterns that are not used anymore? like when a project is removed from the group?
    const indexPatterns = [];

    // Define the default fields for index patterns
    const applicationLogs =
      '[{"name":"@timestamp","type":"date","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"@version","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"_id","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_index","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_score","type":"number","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_source","type":"_source","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"application","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"application.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"channel","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"channel.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.ip","type":"ip","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.latitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.location","type":"geo_point","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.longitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"host","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"host.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"ip","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"ip.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"level","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"level.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"link","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"link.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"log-type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"log-type.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"message","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_project","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_project.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"request_uri","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"request_uri.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"uid","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true}]';
    const containerLogs =
      '[{"name":"@timestamp","type":"date","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"@version","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"_id","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_index","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_score","type":"number","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_source","type":"_source","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"geoip.ip","type":"ip","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.latitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.location","type":"geo_point","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.longitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.container_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.container_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.host","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.host.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.baasid","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.baasid.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.baasresource","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.baasresource.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.branch","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.branch.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.controller-uid","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.controller-uid.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.deployment","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.deployment.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.deploymentconfig","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.deploymentconfig.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.job-name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.job-name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.openshift_io/build_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.openshift_io/build_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.openshift_io/deployer-pod-for_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.openshift_io/deployer-pod-for_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.project","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.project.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.labels.service","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.labels.service.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.namespace_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.namespace_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"kubernetes.pod_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"kubernetes.pod_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"level","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"level.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"message","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false}]';
    const routerLogs =
      '[{"name":"@timestamp","type":"date","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"@version","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"_id","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_index","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_score","type":"number","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_source","type":"_source","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"accept_date","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"accept_date.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"actconn","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"actconn.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"backend_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"backend_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"backend_queue","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"backend_queue.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"beconn","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"beconn.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"bytes_read","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"bytes_read.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"captured_request_cookie","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"captured_request_cookie.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"captured_request_headers","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"captured_request_headers.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"captured_response_cookie","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"captured_response_cookie.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"client_ip","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"client_ip.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"client_port","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"client_port.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"feconn","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"feconn.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"frontend_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"frontend_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.ip","type":"ip","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.latitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.location","type":"geo_point","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.longitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_backend","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_backend.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_hour","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_hour.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_milliseconds","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_milliseconds.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_minute","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_minute.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_month","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_month.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_monthday","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_monthday.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_second","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_second.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_time","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_time.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"haproxy_year","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"haproxy_year.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"host","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"host.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"http_request","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"http_request.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"http_status_code","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"http_status_code.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"http_verb","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"http_verb.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"http_version","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"http_version.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"log-type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"log-type.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"openshift_pod","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_pod.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"openshift_pod_ip","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_pod_ip.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"openshift_pod_port","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_pod_port.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"openshift_project","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_project.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"openshift_route","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_route.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"openshift_service","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"openshift_service.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"pid","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"pid.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"port","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"port.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"program","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"program.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"request_header_host","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"request_header_host.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"request_header_useragent","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"request_header_useragent.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"retries","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"retries.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"server_name","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"server_name.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"srv_queue","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"srv_queue.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"srvconn","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"srvconn.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"syslog_timestamp","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"syslog_timestamp.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"termination_state","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"termination_state.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"time_backend_connect","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"time_backend_connect.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"time_backend_response","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"time_backend_response.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"time_duration","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"time_duration.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"time_queue","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"time_queue.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"time_request","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"time_request.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true}]';
    const lagoonLogs =
      '[{"name":"@timestamp","type":"date","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"@version","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"_id","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_index","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"_score","type":"number","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_source","type":"_source","count":0,"scripted":false,"searchable":false,"aggregatable":false,"readFromDocValues":false},{"name":"_type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":false},{"name":"event","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"event.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.ip","type":"ip","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.latitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.location","type":"geo_point","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"geoip.longitude","type":"number","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"log-type","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"log-type.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"message","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.branchName","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.branchName.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.buildName","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.buildName.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.buildPhase","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.buildPhase.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.environmentName","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.environmentName.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.fullEvent","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.fullEvent.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.logLink","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.logLink.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.openshiftProject","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.openshiftProject.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.projectName","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.projectName.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.remoteId","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.remoteId.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.route","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.route.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"meta.routes","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"meta.routes.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"project","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"project.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"severity","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"severity.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true},{"name":"uuid","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":false,"readFromDocValues":false},{"name":"uuid.keyword","type":"string","count":0,"scripted":false,"searchable":true,"aggregatable":true,"readFromDocValues":true}]';

    indexPatterns.push(
      ['application-logs-*', applicationLogs],
      ['router-logs-*', routerLogs],
      ['container-logs-*', containerLogs],
      ['lagoon-logs-*', lagoonLogs]
    );

    groupProjectNames.forEach(projectName =>
      indexPatterns.push(
        [`application-logs-${projectName}-*`, applicationLogs],
        [`router-logs-${projectName}-*`, routerLogs],
        [`container-logs-${projectName}-*`, containerLogs],
        [`lagoon-logs-${projectName}-*`, lagoonLogs]
      )
    );

    for (const indexPattern of indexPatterns) {
      try {
        await kibanaClient.post(
          `saved_objects/index-pattern/${indexPattern[0]}`,
          {
            body: {
              attributes: {
                title: `${indexPattern[0]}`,
                timeFieldName: '@timestamp',
                fields: `${indexPattern[1]}`
              }
            },
            headers: {
              securitytenant: groupName
            }
          }
        );
        logger.debug(
          `${groupName}: Created index-pattern "${indexPattern[0]}"`
        );
      } catch (err) {
        // 409 Errors are expected and mean that there is already an index-pattern with that name defined, we ignore them
        if (err.statusCode !== 409) {
          logger.error(
            `Kibana Error during setup of index pattern "${indexPattern[0]}": ${err}`
          );
          // Don't fail if we have Kibana Errors, as they are "non-critical"
        } else {
          logger.debug(
            `${groupName}: index-pattern "${indexPattern[0]}" already existing`
          );
        }
      }
    }

    try {
      const currentSettings = await kibanaClient.get('kibana/settings', {
        headers: {
          securitytenant: groupName
        }
      });

      const defaultIndexPattern = 'container-logs-*';

      // Define a default Index if there is none yet
      if (!('defaultIndex' in currentSettings.body.settings)) {
        await kibanaClient.post('kibana/settings', {
          body: {
            changes: {
              defaultIndex: defaultIndexPattern,
              'telemetry:optIn': false // also opt out of telemetry from xpack
            }
          },
          headers: {
            securitytenant: groupName
          }
        });
        logger.debug(
          `${groupName}: Configured default index for tenant "${groupName}" to  "${defaultIndexPattern}"`
        );
      } else {
        logger.debug(
          `${groupName}: Configured default index for tenant "${groupName}" was already set to "${currentSettings.body.settings.defaultIndex.userValue}"`
        );
      }
    } catch (err) {
      logger.error(`Kibana Error during config of default Index: ${err}`);
      // Don't fail if we have Kibana Errors, as they are "non-critical"
    }
  },
  deleteGroup: async groupName => {
    // delete groups that have no Projects assigned to them
    try {
      await opendistroSecurityClient.delete(`roles/${groupName}`);
      logger.debug(
        `${groupName}: OpendistroSecurity Role "${groupName}" deleted`
      );
    } catch (err) {
      // 404 Errors are expected and mean that the role does not exist
      if (err.statusCode !== 404) {
        logger.error(
          `OpendistroSecurity Error during deletion of role "${groupName}": ${err}`
        );
      } else {
        logger.debug(
          `OpendistroSecurity Role "${groupName}" did not exist, skipping deletion`
        );
      }
    }

    try {
      // Create a new Tenant for this Group
      await opendistroSecurityClient.delete(`tenants/${groupName}`);
      logger.debug(
        `${groupName}: Deleted Opendistro-Security Tentant "${groupName}"`
      );
    } catch (err) {
      // 404 Errors are expected and mean that the role does not exist
      if (err.statusCode !== 404) {
        logger.error(
          `Opendistro-Security Error during deletion of tenant "${groupName}": ${err}`
        );
      } else {
        logger.debug(
          `Opendistro-Security tenant "${groupName}" did not exist, skipping deletion`
        );
      }
    }
  }
});
