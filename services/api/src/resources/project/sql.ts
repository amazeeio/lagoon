const { knex } = require('../../util/db');

export const Sql = {
  selectProject: (id: number) =>
    knex('project')
      .where('id', id)
      .toString(),
  selectAllProjectNames: () =>
    knex('project')
      .select('name')
      .toString(),
  selectAllProjects: () => knex('project').toString(),
  selectAllProjectNotIn: (ids: number) =>
    knex('project')
      .select('id', 'name')
      .whereNotIn('id', ids)
      .orderBy('id', 'asc')
      .toString(),
  selectProjectByName: (name: string) =>
    knex('project')
      .where('name', name)
      .toString(),
  selectProjectIdByName: (name: string) =>
    knex('project')
      .where('name', name)
      .select('id')
      .toString(),
  selectProjectsByIds: (projectIds: number[]) =>
    knex('project as p')
      .whereIn('p.id', projectIds)
      .toString(),
  selectProjectByEnvironmentId: (
      environmentId,
      environmentType = []
  ): {environmentId: number, environmentType: string} => {
      let q = knex('environment as e')
          .select('e.id', {envName: 'e.name'}, 'e.environment_type', 'e.project', 'e.openshift_project_name', 'p.name')
          .leftJoin('project as p', 'p.id', '=', 'e.project');
      if (environmentType && environmentType.length > 0) {
          q.where('e.environment_type', environmentType);
      }
      q.where('e.id', environmentId);
      return q.toString();
  },
  updateProject: ({ id, patch }: { id: number, patch: { [key: string]: any } }) =>
    knex('project')
      .where('id', '=', id)
      .update(patch)
      .toString(),
};
