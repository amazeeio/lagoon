# Logging

Lagoon provides access to the following logs via Kibana:

* Logs from the Kubernetes Routers, including every single HTTP and HTTPS request with:
  * Source IP
  * URL
  * Path
  * HTTP verb
  * Cookies
  * Headers
  * User agent
  * Project
  * Container name
  * Response size
  * Response time
* Logs from containers:
  * `stdout` and `stderr` messages
  * Container name
  * Project
* Lagoon logs:
  * Webhooks parsing
  * Build logs
  * Build errors
  * Any other Lagoon related logs
* Application logs:
  * Any logs sent by the running application
  * For Drupal: install the [Lagoon Logs](https://www.drupal.org/project/lagoon_logs) module in order to receive logs from Drupal Watchdog.

To access the logs, please check with your Lagoon administrator to get the URL for the Kibana route \(for amazee.io this is [https://logs.amazeeio.cloud/)\).

Each Lagoon user account has their own login and will see the logs only for the projects to which they have access.

Each Lagoon user account also has their own **Kibana Tenant**, which means no saved searches or visualizations are shared with another account.

If you would like to know more about how to use Kibana: [https://www.elastic.co/webinars/getting-started-kibana](https://www.elastic.co/webinars/getting-started-kibana).

