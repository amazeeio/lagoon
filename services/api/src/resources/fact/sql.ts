import { knex } from '../../util/db';

const standardFactReturn = {
  id: 'id',
  environment: 'environment',
  name: 'name',
  value: 'value',
  source: 'source',
  description: 'description'
};

export const Sql = {
  selectFactByDatabaseId: id =>
    knex('environment_fact')
      .where('id', id)
      .toString(),
  selectFactsByEnvironmentId: ({ environmentId }) => {
    return knex('environment_fact')
      .select(standardFactReturn)
      .where('environment', environmentId)
      .toString();
  },
  insertFact: ({ id, environment, name, value, source, description }) =>
    knex('environment_fact')
      .insert({ id, environment, name, value, source, description })
      .toString(),
  deleteFact: (environment, name) =>
    knex('environment_fact')
      .where({
        environment,
        name
      })
      .del()
      .toString(),
  deleteFactsFromSource: (environment, source) =>
    knex('environment_fact')
      .where({ environment, source })
      .del()
      .toString()
};
