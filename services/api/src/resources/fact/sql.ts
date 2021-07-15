import { KnownDirectives } from 'graphql/validation/rules/KnownDirectives';
import { knex } from '../../util/db';

const standardFactReturn = {
    id: 'f.id',
    environment: 'environment',
    name: 'f.name',
    value: 'value',
    source: 'source',
    description: 'description',
    type: 'type',
    category: 'category',
    keyFact: 'keyFact'
};

export const Sql = {
  selectFactByDatabaseId: (fid: number) =>
    knex('environment_fact as f')
      .distinct(standardFactReturn)
      .leftJoin('environment_fact_reference as r', 'r.fid', '=', 'f.id')
      .where('f.id', fid)
      .orderBy('f.id', 'asc')
      .toString(),
  selectFactsByEnvironmentId: ({ environmentId, keyFacts }) => {
    let q = knex('environment_fact as f')
      .distinct(standardFactReturn)
      .leftJoin('environment_fact_reference as r', 'r.fid', '=', 'f.id')
      .where('environment', environmentId);

    if (keyFacts) {
      q.where('f.keyFact', keyFacts);
    }

    return q.orderBy('f.id', 'asc').toString()
  },
  insertFact: ({ environment, name, value, source, description, type, category, keyFact }) =>
    knex('environment_fact').insert({ environment, name, value, source, description, type, category, keyFact }).toString(),
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
      .toString(),
  selectFactReferenceByDatabaseId: (id: number) =>
    knex('environment_fact_reference')
      .where({ id })
      .toString(),
  selectFactReferenceByNameAndEnvironmentId: (name: string, environmentId: number) =>
    knex('environment_fact_reference as r')
      .select('r.*', 'f.environment')
      .leftJoin('environment_fact as f', 'f.id', '=', 'r.fid')
      .where('r.name', '=', name)
      .andWhere('f.environment', '=', environmentId)
      .toString(),
  selectFactReferencesByFactId: (fid: number) =>
    knex('environment_fact_reference')
      .where('fid', '=', fid)
      .toString(),
  insertFactReference: ({ fid, name }) =>
    knex('environment_fact_reference')
      .insert({ fid, name })
      .onConflict(['name', 'fid'])
      .merge()
      .toString(),
  deleteFactReferencesByFactId: (fid) =>
    knex('environment_fact_reference')
      .where({ fid })
      .del()
      .toString(),
};
