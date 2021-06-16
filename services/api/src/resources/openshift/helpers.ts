import * as R from 'ramda';
import { Pool } from 'mariadb';
import { asyncPipe } from '@lagoon/commons/dist/util';
import { query } from '../../util/db';
import { Sql } from './sql';

export const Helpers = (sqlClientPool: Pool) => {
  return {
    getOpenshiftByOpenshiftInput: async (openshiftInput: {
      id?: number;
      name?: string;
    }) => {
      const notEmpty = R.complement(R.anyPass([R.isNil, R.isEmpty]));
      const hasId = R.both(R.has('id'), R.propSatisfies(notEmpty, 'id'));
      const hasName = R.both(R.has('name'), R.propSatisfies(notEmpty, 'name'));

      const openshiftFromId = asyncPipe(R.prop('id'), async id => {
        const rows = await query(sqlClientPool, Sql.selectOpenshiftById(id));
        const openshift = R.prop(0, rows);

        if (!openshift) {
          throw new Error('Unauthorized');
        }

        return openshift;
      });

      const openshiftFromName = asyncPipe(R.prop('name'), async name => {
        const rows = await query(
          sqlClientPool,
          Sql.selectOpenshiftByName(name)
        );
        const openshift = R.prop(0, rows);

        if (!openshift) {
          throw new Error('Unauthorized');
        }

        return openshift;
      });

      return R.cond([
        [hasId, openshiftFromId],
        [hasName, openshiftFromName],
        [
          R.T,
          () => {
            throw new Error('Must provide openshift "id" or "name"');
          }
        ]
      ])(openshiftInput);
    }
  };
};
