import { knex } from '../../util/db';

const Sql = {
  selectEnvVariable: (id: number) =>
    knex('env_vars')
      .select('id', 'name', 'value', 'scope')
      .where('id', '=', id)
      .toString(),
  insertEnvVariable: (
    {
      id,
      name,
      value,
      scope,
      project,
      environment,
      group,
    }: {
    id: number,
    name: string,
    value: string,
    scope: string,
    project?: number,
    environment?: number,
    group?: string,
  },
  ) =>
    knex('env_vars')
      .insert({
        id,
        name,
        value,
        scope,
        project,
        environment,
        group_id: group,
      })
      .toString(),
  deleteEnvVariable: (id: number) =>
    knex('env_vars')
      .where('id', id)
      .del()
      .toString(),
  selectPermsForEnvVariable: (id: number) =>
    knex('env_vars')
      .select({ pid: 'project.id' })
      .leftJoin('environment', 'env_vars.environment', '=', 'environment.id')
      .leftJoin('project', function () {
        this
          .on('env_vars.project', '=', 'project.id')
          .orOn('environment.project', '=', 'project.id')
      })
      .where('env_vars.id', id)
      .toString(),
};

export default Sql;
