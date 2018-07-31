// @flow

import { green } from 'chalk';
import inquirer from 'inquirer';
import R from 'ramda';

import { answerWithOptionIfSetOrPrompt } from '../../cli/answerWithOption';
import { config } from '../../config';
import gql from '../../gql';
import { printGraphQLErrors, printErrors } from '../../printErrors';
import { runGQLQuery } from '../../query';
import { getOptions } from '..';

import typeof Yargs from 'yargs';
import type { BaseHandlerArgs } from '..';

export const command = 'delete';
export const description = 'Delete a project';

export const PROJECT: 'project' = 'project';

export const commandOptions = {
  [PROJECT]: PROJECT,
};

type OptionalOptions = {
  project?: string,
};

type Options = {
  +project: string,
};

export function builder(yargs: Yargs): Yargs {
  return yargs
    .usage(`$0 ${command} - ${description}`)
    .options({
      [PROJECT]: {
        demandOption: false,
        describe: 'Name of project',
        type: 'string',
        alias: 'p',
      },
    })
    .example(`$0 ${command}`, 'Delete a project (will prompt for project name)')
    .example(
      `$0 ${command} --${PROJECT} myproject`,
      'Delete the project named "myproject"',
    );
}

type PromptForQueryOptionsArgs = {|
  options: OptionalOptions,
  clog: typeof console.log,
|};

async function promptForQueryOptions({
  options,
  clog,
}:
PromptForQueryOptionsArgs): Promise<Options> {
  return inquirer.prompt([
    {
      type: 'input',
      name: PROJECT,
      message: 'Project name:',
      when: answerWithOptionIfSetOrPrompt({ option: PROJECT, options, clog }),
      validate: input =>
        Boolean(input) ||
        'Please enter a project name to delete or press CTRL-C to exit.',
    },
  ]);
}

type ProjectDetailsArgs = {
  clog: typeof console.log,
  cerr: typeof console.error,
  options: OptionalOptions,
};

export async function deleteProject({
  clog,
  cerr,
  options,
}:
ProjectDetailsArgs): Promise<number> {
  const { project: projectName } = await promptForQueryOptions({
    options,
    clog,
  });

  const result = await runGQLQuery({
    cerr,
    query: gql`
      mutation DeleteProject($input: DeleteProjectInput!) {
        deleteProject(input: $input)
      }
    `,
    variables: {
      input: {
        project: projectName,
      },
    },
  });

  const { errors } = result;
  if (errors != null) {
    return printGraphQLErrors(cerr, ...errors);
  }

  const response = R.path(['data', 'deleteProject'])(result);

  if (!R.equals(response, 'success')) {
    return printErrors(cerr, {
      message: `Error: API responded with "${response || '<empty>'}"`,
    });
  }

  clog(green(`Project "${projectName}" deleted successfully!`));

  return 0;
}

type Args = BaseHandlerArgs & {
  argv: {
    project: ?string,
  },
};

export async function handler({ clog, cerr, argv }: Args): Promise<number> {
  const options = getOptions({
    config,
    argv,
    commandOptions,
    dynamicOptionKeys: [PROJECT],
  });
  return deleteProject({ clog, cerr, options });
}
