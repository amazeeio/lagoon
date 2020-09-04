import { knex } from '../../util/db';

export const Sql = {
  updateOpenshift: ({ id, patch }: { id: number; patch: { [key: string]: any } }) =>
    knex('openshift')
      .where('id', '=', id)
      .update(patch)
      .toString(),
  selectOpenshift: (id: number) =>
    knex('openshift')
      .where('id', '=', id)
      .toString(),
};
