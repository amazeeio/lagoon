import gql from 'graphql-tag';

export default gql`
  query getAllProblemsQuery($source: [String], $envType: [EnvType], $identifier: String, $severity: [ProblemSeverityRating]) {
    problems: allProblems(source: $source, identifier: $identifier, envType: $envType, severity: $severity) {
      id
      identifier
      environment {
        id
        name
        environmentType
        openshiftProjectName
        project {
          id
          name
          problemsUi
        }
      }
      data
      severity
      source
      service
      created
      deleted
      severityScore
      associatedPackage
      description
      version
      fixedVersion
      links
    }
  }
`;