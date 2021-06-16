import { knex } from '../../util/db';

export const Sql = {
  updateOpenshift: ({
    id,
    patch
  }: {
    id: number;
    patch: { [key: string]: any };
  }) =>
    knex('openshift')
      .where('id', '=', id)
      .update(patch)
      .toString(),
  selectOpenshiftById: (id: number) =>
    knex('openshift')
      .where('id', '=', id)
      .toString(),
  selectOpenshiftByName: (name: string) =>
    knex('openshift')
      .where('name', '=', name)
      .toString(),
  truncateOpenshift: () =>
    knex('openshift')
      .truncate()
      .toString()
};
