import * as R from 'ramda';
import { query } from '../../util/db';
import { Helpers as environmentHelpers } from '../environment/helpers';
import { Sql } from './sql';
import { ResolverFn } from '../index';
import { knex } from '../../util/db';
import logger from '../../logger';

export const getFactsByEnvironmentId: ResolverFn = async (
  { id: environmentId },
  args,
  { sqlClientPool, hasPermission }
) => {
  const environment = await environmentHelpers(
    sqlClientPool
  ).getEnvironmentById(environmentId);

  await hasPermission('fact', 'view', {
    project: environment.project
  });

  const rows = await query(
    sqlClientPool,
    Sql.selectFactsByEnvironmentId({
      environmentId
    })
  );

  return R.sort(R.descend(R.prop('created')), rows);
};

const predicateRHSProcess = (predicate, targetValue) => predicate == 'CONTAINS' ? `%${targetValue}%` : targetValue

const getSqlPredicate = (predicate) => {
  const predicateMap = {
    'CONTAINS': 'like',
    'LESS_THAN': '<',
    'LESS_THAN_OR_EQUALS': '<=',
    'GREATER_THAN': '>',
    'GREATER_THAN_OR_EQUALS': '<=',
    'EQUALS': '=',
  };

  return predicateMap[predicate];
}

export const getProjectsByFactSearch: ResolverFn = async (
  root,
  { input },
  { sqlClientPool, hasPermission, keycloakGrant, models }
) => {

  let userProjectIds: number[];
  try {
    await hasPermission('project', 'viewAll');
  } catch (err) {
    if (!keycloakGrant) {
      logger.warn('No grant available for getAllProjects');
      return [];
    }

    userProjectIds = await models.UserModel.getAllProjectsIdsForUser({
      id: keycloakGrant.access_token.content.sub
    });
  }

  let factQuery = knex('project').distinct('project.*').innerJoin('environment', 'environment.project', 'project.id');

  const filters = {};

  if (input.filters.length > 0) {
    input.filters.forEach((e, i) => {

      let { lhsTarget, lhs } = e;

      let tabName = `env${i}`;
      if (lhsTarget == "project" || lhsTarget == 'environment') {
        switch(lhs) {
          case("name"):
            break;
          case("environmentType"):
            break;
          default:
            throw Error(`lhsTarget "${lhs}" unsupported`)
        }
      }
      else {
        if (input.filterConnective == 'AND') {
          factQuery = factQuery.innerJoin(`environment_fact as ${tabName}`, 'environment.id', `${tabName}.environment`)
        } else {
          factQuery = factQuery.leftJoin(`environment_fact as ${tabName}`, 'environment.id', `${tabName}.environment`)
        }
      }
    });

    factQuery.where((builder) => {
      input.filters.forEach((e, i) => {
        let { lhsTarget, lhs } = e;
        if (lhsTarget == "PROJECT" || lhsTarget == "ENVIRONMENT") {
          if (input.filterConnective == 'AND') {
            builder = builder.andWhere(`${lhsTarget}.${lhs}`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          } else {
            builder = builder.orWhere(`${lhsTarget}.${lhs}`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          }
        } else {
          let tabName = `env${i}`;
          if (input.filterConnective == 'AND') {
            builder = builder.andWhere(`${tabName}.name`, '=', `${e.lhs}`)
            builder = builder.andWhere(`${tabName}.value`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          } else {
            builder = builder.orWhere(`${tabName}.name`, '=', `${e.lhs}`)
            builder = builder.orWhere(`${tabName}.value`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          }
        }
        return builder;
      });
    });
  }
  else {
    factQuery = factQuery.innerJoin(`environment_fact`, 'environment.id', `environment_fact.environment`);
  }

  if (userProjectIds) {
    factQuery = factQuery.andWhere('environment.project', 'IN', userProjectIds);
  }

  const DEFAULT_RESULTSET_SIZE = 50;

  //skip and take logic
  let { skip = 0, take=DEFAULT_RESULTSET_SIZE } = input;
  factQuery = factQuery.limit(take).offset(skip);


  console.log(factQuery.toString());
  // console.log(await query(sqlClientPool, factQuery.toString()));

  const rows = await query(sqlClientPool, factQuery.toString());
  return rows;
}

export const getEnvironmentsByFactSearch: ResolverFn = async (
  root,
  { input },
  { sqlClientPool, hasPermission, keycloakGrant, models }
) => {

  let userProjectIds: number[];
  try {
    await hasPermission('project', 'viewAll');
  } catch (err) {
    if (!keycloakGrant) {
      logger.warn('No grant available for getAllProjects');
      return [];
    }

    userProjectIds = await models.UserModel.getAllProjectsIdsForUser({
      id: keycloakGrant.access_token.content.sub
    });
  }

  let factQuery = knex('environment').distinct('environment.*').innerJoin('project', 'environment.project', 'project.id');

  const filters = {};

  if (input.filters.length > 0) {
    input.filters.forEach((e, i) => {

      let { lhsTarget, lhs } = e;

      let tabName = `env${i}`;
      if(lhsTarget == "project") {
        switch(lhs) {
          case("name"):
          break;
          default:
            throw Error(`lhsTarget "${lhs}" unsupported`)
        }
      } else {
        if (input.filterConnective == 'AND') {
          factQuery = factQuery.innerJoin(`environment_fact as ${tabName}`, 'environment.id', `${tabName}.environment`)
        } else {
          factQuery = factQuery.leftJoin(`environment_fact as ${tabName}`, 'environment.id', `${tabName}.environment`)
        }
      }
    });

    factQuery.where((builder) => {
      input.filters.forEach((e, i) => {

        let { lhsTarget, lhs } = e;

        if(lhsTarget == "PROJECT") {
          if (input.filterConnective == 'AND') {
            builder = builder.andWhere(`${lhsTarget}.${lhs}`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          } else {
            builder = builder.orWhere(`${lhsTarget}.${lhs}`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          }
        } else {
          let tabName = `env${i}`;
          if (input.filterConnective == 'AND') {
            builder = builder.andWhere(`${tabName}.name`, '=', `${e.lhs}`)
            builder = builder.andWhere(`${tabName}.value`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          } else {
            builder = builder.orWhere(`${tabName}.name`, '=', `${e.lhs}`)
            builder = builder.orWhere(`${tabName}.value`, getSqlPredicate(e.predicate), predicateRHSProcess(e.predicate, e.rhs))
          }
        }
        return builder;
      });
    });
  }
  else {
    factQuery = factQuery.innerJoin(`environment_fact`, 'environment.id', `environment_fact.environment`);
  }

  if (userProjectIds) {
    factQuery = factQuery.andWhere('environment.project', 'IN', userProjectIds);
  }

  const DEFAULT_RESULTSET_SIZE = 25

  //skip and take logic
  let { skip = 0, take = DEFAULT_RESULTSET_SIZE } = input;
  factQuery = factQuery.limit(take).offset(skip);


  console.log(factQuery.toString());


  const rows = await query(sqlClientPool, factQuery.toString());
  return rows;
}

export const addFact: ResolverFn = async (
  root,
  {
    input: {
      id, environment: environmentId, name, value, source, description, type, category, reference
    },
  },
  { sqlClientPool, hasPermission },
) => {
  const environment = await environmentHelpers(
    sqlClientPool
  ).getEnvironmentById(environmentId);

  await hasPermission('fact', 'add', {
    project: environment.project
  });

  const { insertId } = await query(
    sqlClientPool,
    Sql.insertFact({
      environment: environmentId,
      name,
      value,
      source,
      description,
      type,
      reference,
      category
    }),
  );

  const rows = await query(
    sqlClientPool,
    Sql.selectFactByDatabaseId(insertId)
  );

  return R.prop(0, rows);
};

export const addFacts: ResolverFn = async (
  root,
  { input: { facts } },
  { sqlClientPool, hasPermission }
) => {
  // We first check that the user has access to all of the environments, so this is an atomic operation.
  await facts.map(async fact => {
    const { environment } = fact;
    const env = await environmentHelpers(sqlClientPool).getEnvironmentById(
      environment
    );

    await hasPermission('fact', 'add', {
      project: env.project
    });
  });

  return await facts.map(async (fact) => {
    const { environment, name, value, source, description, type, category, reference } = fact;

    const { insertId } = await query(
      sqlClientPool,
      Sql.insertFact({
        environment,
        name,
        value,
        source,
        description,
        type,
        reference,
        category
      }),
    );

    const rows = await query(
      sqlClientPool,
      Sql.selectFactByDatabaseId(insertId)
    );
    return R.prop(0, rows);
  });
};

export const deleteFact: ResolverFn = async (
  root,
  { input: { environment: environmentId, name } },
  { sqlClientPool, hasPermission }
) => {
  const environment = await environmentHelpers(
    sqlClientPool
  ).getEnvironmentById(environmentId);

  await hasPermission('fact', 'delete', {
    project: environment.project
  });

  await query(sqlClientPool, Sql.deleteFact(environmentId, name));

  return 'success';
};

export const deleteFactsFromSource: ResolverFn = async (
  root,
  { input: { environment: environmentId, source } },
  { sqlClientPool, hasPermission }
) => {
  const environment = await environmentHelpers(
    sqlClientPool
  ).getEnvironmentById(environmentId);

  await hasPermission('fact', 'delete', {
    project: environment.project
  });

  await query(sqlClientPool, Sql.deleteFactsFromSource(environmentId, source));

  return 'success';
};
