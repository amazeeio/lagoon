import * as R from 'ramda';
import { query, prepare } from '../../util/db';
import { Sql } from './sql';
import { Helpers as problemHelpers } from './helpers';
import { Helpers as environmentHelpers } from '../environment/helpers';
import { ResolverFn } from '../';
const logger = require('../../logger');

export const getAllProblems: ResolverFn = async (
  root,
  args,
  {
    sqlClient,
    hasPermission
  }
) => {
  let rows = [];

  try {
     rows = await problemHelpers(sqlClient).getAllProblemsPerProject(args.source, args.environment, args.envType, args.severity);
  }
  catch (err) {
    if (err) {
      logger.warn(err);
      return [];
    }
  }

  const problems: any = rows && Object.keys(rows).map(async (p: any) => {
    // Only check if user has access to each project, not problem.
    await hasPermission('problem', 'view', {
        project: p,
    });

    const problem = rows[p].map((problem: any) => {
        const { environment: envId, name, project, environmentType, openshiftProjectName, ...rest } = problem;
        return { ...rest, environment: { id: envId, name, project, environmentType, openshiftProjectName }};
    });

    return problem.map(p => p);
  });

  return Promise.all(problems).then((p) => {
    const sorted = R.sort(R.descend(R.prop('severity')), [].concat.apply([], p));
    return sorted.map((row: any) => ({ ...(row as Object) }));
  });
};

export const getSeverityOptions = async (
  root,
  args,
  { sqlClient },
) => {
  return await problemHelpers(sqlClient).getSeverityOptions();
};

export const getProblemSources = async (
  root,
  args,
  { sqlClient },
) => {
  const preparedQuery = prepare(
    sqlClient,
    `SELECT DISTINCT source FROM environment_problem`,
  );

  return R.map(
    R.prop('source'),
      await query(sqlClient, preparedQuery(args))
    );
};

export const getProblemsByEnvironmentId = async (
  { id: environmentId },
  {severity, source},
  { sqlClient, hasPermission },
) => {
  const environment = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);

  await hasPermission('problem', 'view', {
    project: environment.project,
  });

  const rows = await query(
    sqlClient,
    Sql.selectProblemsByEnvironmentId({
      environmentId,
      severity,
      source,
    }),
  );

  return  R.sort(R.descend(R.prop('created')), rows);
};

export const addProblem = async (
  root,
  {
    input: {
      id, severity, environment: environmentId, identifier, service, source, data, created,
        severityScore, associatedPackage, description, version, fixedVersion, links
    },
  },
  { sqlClient, hasPermission },
) => {
  const environment = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);

  await hasPermission('problem', 'add', {
    project: environment.project,
  });

  const {
    info: { insertId },
  } = await query(
    sqlClient,
    Sql.insertProblem({
      severity,
      severity_score: severityScore,
      lagoon_service: service || '',
      identifier,
      environment: environmentId,
      source,
      associated_package: associatedPackage,
      description,
      version: version || '',
      fixed_version: fixedVersion,
      links: links,
      data,
      created,
    }),
  );

  const rows = await query(sqlClient, Sql.selectProblemByDatabaseId(insertId));
  return R.prop(0, rows);
};

export const deleteProblem = async (
  root,
  {
    input : {
      environment: environmentId,
      identifier,
    }
  },
  { sqlClient, hasPermission },
) => {
  const environment = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);

  await hasPermission('problem', 'delete', {
    project: environment.project,
  });

  await query(sqlClient, Sql.deleteProblem(environmentId, identifier));

  return 'success';
};

export const deleteProblemsFromSource = async (
  root,
  {
    input : {
      environment: environmentId,
      source,
      service,
    }
  },
  { sqlClient, hasPermission },
) => {
  const environment = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);

  await hasPermission('problem', 'delete', {
    project: environment.project,
  });

  await query(sqlClient, Sql.deleteProblemsFromSource(environmentId, source, service));

  return 'success';
}

export const getProblemHarborScanMatches = async (
  root,
  args,
  { sqlClient, hasPermission },
) => {

  await hasPermission('harbor_scan_match', 'view', {});

  const rows = await query(
    sqlClient,
    Sql.selectAllProblemHarborScanMatches(),
  );

  return rows;
};

export const addProblemHarborScanMatch = async (
  root,
  {
    input: {
      name,
      description,
      defaultLagoonProject,
      defaultLagoonEnvironment,
      defaultLagoonServiceName,
      regex
    },
  },
  { sqlClient, hasPermission },
) => {

  await hasPermission('harbor_scan_match', 'add', {});

  const {
    info: { insertId },
  } = await query(
    sqlClient,
    Sql.insertProblemHarborScanMatch(
      {
        id: null,
        name,
        description,
        default_lagoon_project: defaultLagoonProject,
        default_lagoon_environment: defaultLagoonEnvironment,
        default_lagoon_service_name: defaultLagoonServiceName,
        regex
      }
    ),
  );

  const rows = await query(sqlClient, Sql.selectAllProblemHarborScanMatchByDatabaseId(insertId));
  return R.prop(0, rows);
};


export const deleteProblemHarborScanMatch = async (
  root,
  {
    input : {
      id
    }
  },
  { sqlClient, hasPermission },
) => {

  await hasPermission('harbor_scan_match', 'delete', {});

  await query(sqlClient, Sql.deleteProblemHarborScanMatch(id));

  return 'success';
};
