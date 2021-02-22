import * as R from 'ramda';
import { MariaClient } from 'mariasql';
import { query} from '../../util/db';
import { Sql } from './sql';

export const Helpers = (sqlClient: MariaClient) => {
  const getAllProblems = async (projects, args) => {
    const source = args.source && args.source.map(t => t.toLowerCase() || []);
    const severity = args.severity && args.severity.map(t => t || []);
    const envType = args.envType && args.envType.map(t => t.toLowerCase() || []);

    const rows = await query(
      sqlClient,
      Sql.selectProblemsByProjects({ projects, source, severity, envType })
    );

    return rows;
  };

  const getSeverityOptions = async () => (
    R.map(
      R.prop('severity'),
        await query(sqlClient, Sql.selectSeverityOptions()),
      )
  );

  return {
    getAllProblems,
    getSeverityOptions
  };
};