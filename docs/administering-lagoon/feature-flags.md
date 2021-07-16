# Feature flags

Some Lagoon features can be controlled by setting feature flags.
This is designed to assist users and administrators to roll out new platform features in a controlled manner.

## Environment variables

The following environment variables can be set on an environment or project to toggle feature flags.

| Environment Variable Name                      | Active scope\* | Version introduced | Version removed | Default Value | Description                                                                                                                                                                                                                                                                                                                                       |
| ---                                            | ---            | ---                | ---             | ---           | ---                                                                                                                                                                                                                                                                                                                                               |
| `LAGOON_FEATURE_FLAG_ROOTLESS_WORKLOAD`        | `build`        | 2.0.0              | -               | `disabled`    | Set to `enabled` to set a non-root pod securty context on the pods in this environment or project.<br><br>This flag will eventually be deprecated, at which point non-root workloads will be enforced.                                                                                                                                                                                              |
| `LAGOON_FEATURE_FLAG_ISOLATION_NETWORK_POLICY` | `build`        | 2.0.0              | -               | `disabled`    | Set to `enabled` to add a default namespace isolation network policy to each environment on deployment.<br><br>This flag will eventually be deprecated, at which point the namespace isolation network policy will be enforced.<br><br>NOTE: enabling and then disabling this feature will _not_ remove any existing network policy from previous deployments. Those must be removed manually. |

\* Active scope indicates whether the variable must be set as `build` or `runtime` scope to take effect. `global` sets the variable in both scopes, so that will work too.

## Cluster-level controls

Feature flags may also be controlled at the cluster level. There is support for this in the [`lagoon-build-deploy` chart](https://github.com/uselagoon/lagoon-charts/blob/main/charts/lagoon-build-deploy/values.yaml).
For each feature flag there are two flavours of values which can be set: `default` and `force`.

* `default` controls the default policy for environments deployed to the cluster, but can be overridden at the project or environment level by the environment variables documented above.
* `force` also controls the policy for environments deployed to the cluster, but _cannot be overridden_ by the environment variables documented above.
