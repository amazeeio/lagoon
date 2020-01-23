/*
    To run all tests here, execute the following command:
    $  yarn test resolvers --colors

    To run a specific test, you can use the tags at the end of the description.
    Example:
    $ yarn test resolvers --colors -t "#updateProject #availability"
*/
import axios, { AxiosInstance, AxiosResponse } from 'axios';
import { random } from 'faker';
import { legacyAdminToken } from '../../tests/util';
import {
  ADD_PROJECT,
  UPDATE_PROJECT,
  ADD_BILLING_GROUP,
  UPDATE_BILLING_GROUP,
  DELETE_BILLING_GROUP,
  ADD_PROJECT_TO_BILLING_GROUP,
  UPDATE_PROJECT_BILLING_GROUP,
  REMOVE_PROJECT_FROM_BILLING_GROUP,
  ALL_PROJECTS,
  PROJECT_BY_NAME,
  ALL_GROUPS,
  ALL_PROJECTS_IN_GROUP,
  DELETE_PROJECT,
  BILLING_GROUP_COST,
} from './gql.test';

const fakeName = random.alphaNumeric;

type Project = {
  id?: number;
  name?: string;
  gitUrl?: string;
  openshift?: number;
  productionEnvironment?: string;
  availability?: string;
  groups?: [Group];
};

type Group = {
  id?: number;
  name?: string;
  type?: string;
  currency?: string;
  billingSoftware?: string;
  projects?: [Project];
};

const defaultProject: Project = {
  name: 'PLACEHOLDER',
  gitUrl: 'http://github.com/amazeeio/lagoon.git',
  openshift: 1,
  productionEnvironment: 'master',
  availability: 'STANDARD',
};

const defaultBillingGroup: Group = {
  name: 'PLACEHOLDER',
  currency: 'USD',
  billingSoftware: 'Bexio',
};

const requestConfig = {
  baseURL: 'http://localhost:3000',
  timeout: 60000,
  headers: {
    Authorization: '',
    'content-type': 'application/json',
  },
};

let axiosInstance: AxiosInstance;

type DataResult = {
  data: {
    deleteGroup: { deleteGroup: 'success' };
    addProject: Project;
    updateProject: Project;
    addBillingGroup: Group;
    updateBillingGroup: Group;
    allGroups: [Group];
    addProjectToBillingGroup: Project;
    updateProjectBillingGroup: Project;
    removeProjectFromBillingGroup: Project;
    allProjects: [Project];
    projectByName: Project;
  };
  errors?: any;
  // [key: string]: Project | Group;
};

type AxiosResponseGraphQL = Promise<AxiosResponse<DataResult>>;
type AxiosGraphQL = (query: String, variables?: any) => AxiosResponseGraphQL;

const graphql: AxiosGraphQL = (query: String, variables?: any) =>
  axiosInstance.post('/graphql', {
    query,
    ...(variables ? { variables } : {}),
  });

const addProject = (project: Project) =>
  graphql(ADD_PROJECT, { input: { ...defaultProject, ...project } });

const updateProject = (id: number, project: Project) =>
  graphql(UPDATE_PROJECT, { input: { id, patch: { ...project } } });

const addBillingGroup = (group: Group) =>
  graphql(ADD_BILLING_GROUP, { input: { ...defaultBillingGroup, ...group } });

const updateBillingGroup = (group: Group, patch: Group) =>
  graphql(UPDATE_BILLING_GROUP, {
    input: { group: { ...group }, patch: { ...patch } },
  });

const deleteGroup = (group: Group) =>
  graphql(DELETE_BILLING_GROUP, { input: { group: { ...group } } });

const addProjectToBillingGroup = (project: Project, group: Group) =>
  graphql(ADD_PROJECT_TO_BILLING_GROUP, {
    input: { project: { ...project }, group: { ...group } },
  });

const updateProjectBillingGroup = (project: Project, group: Group) =>
  graphql(UPDATE_PROJECT_BILLING_GROUP, {
    input: { project: { ...project }, group: { ...group } },
  });

const removeProjectFromBillingGroup = (group: Group, project: Project) =>
  graphql(REMOVE_PROJECT_FROM_BILLING_GROUP, {
    input: { group: { ...group }, project: { ...project } },
  });

const allProjects = (
  createdAfter: String = null,
  gitUrl: String = null,
  order: String = null,
) => graphql(ALL_PROJECTS, { createdAfter, gitUrl, order });

const projectByName = (name: String = '') => graphql(PROJECT_BY_NAME, { name });

const allGroups = (type: String = null) => graphql(ALL_GROUPS, { type });

const allProjectsInGroup = (group: Group) =>
  graphql(ALL_PROJECTS_IN_GROUP, { input: { ...group } });

const deleteProject = (name: String) =>
  graphql(DELETE_PROJECT, { input: { project: name } });

const billingGroupCost = (group: Group, month: String) =>
  graphql(BILLING_GROUP_COST, { input: { ...group }, month });

const cleanup = {
  groups: [],
  projects: [],
};

// Unit Under Test
describe('Billing Group Costs Related Queries & Mutation', () => {
  beforeAll(async () => {
    // GET JWT Token
    const token = (await legacyAdminToken()).replace(/[\n\t\r]/g, '');
    requestConfig.headers.Authorization = `Bearer ${token}`;
    axiosInstance = axios.create(requestConfig);
  });

  afterEach(async () => {
    for (var i = cleanup.projects.length - 1; i >= 0; i--) {
      await deleteProject(cleanup.projects[i].name);
      cleanup.groups.splice(i, 1);
    }

    for (var i = cleanup.groups.length - 1; i >= 0; i--) {
      await deleteGroup(cleanup.groups[i]).catch(error => console.log(error));
      cleanup.groups.splice(i, 1);
    }
  }, 120000);

  describe('BillingGroup Mutations #mutations', () => {
    // scenarios and expectation

    it('When I run the mutation addBillingGroup, I expect the name to be returned. #mutaion #addBillingGroup', async () => {
      // Arrange
      const group = { name: fakeName(10) };

      // Act
      const { data } = await addBillingGroup(group);

      if (!data.data.addBillingGroup) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      const expected = {
        data: {
          addBillingGroup: {
            name: group.name,
          },
        },
      };
      expect(data).toMatchObject(expected);

      // cleanup
      cleanup.groups.push(group);
    }, 60000);

    it('When I update a billing group name, currency, and billing software, I expect the result to reflect this. #mutation #updateBillingGroup', async () => {
      // Arrange
      const group = { name: fakeName(10) };
      await addBillingGroup(group);

      const patch = {
        name: fakeName(10),
        currency: 'AUD',
        billingSoftware: 'Bexio',
      };

      // Act
      const { data } = await updateBillingGroup(group, patch);

      if (!data.data.updateBillingGroup) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      const expected = {
        data: {
          updateBillingGroup: {
            name: patch.name,
            type: 'billing',
            currency: 'AUD',
            billingSoftware: 'Bexio',
          },
        },
      };
      expect(data).toMatchObject(expected);

      // cleanup
      cleanup.groups.push(group);
    }, 60000);

    it('When I delete a billing group, I expect it to go away. #mutation #deleteGroup', async () => {
      // Arrange
      const group = { name: fakeName(10) };
      await addBillingGroup(group);

      // Act
      const { data } = await deleteGroup(group);

      if (!data.data.deleteGroup) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      const expected = {
        data: {
          deleteGroup: 'success',
        },
      };
      expect(data).toMatchObject(expected);
    }, 60000);

    it('When I add a project with STANDARD availability, the expect STANDARD to be returned. #mutation #addProject', async () => {
      // Arrange
      const project = { name: fakeName(10) };

      // Act
      const { data } = await addProject(project);

      if (!data.data.addProject) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      const expected = {
        data: {
          addProject: {
            name: project.name,
            availability: 'STANDARD',
          },
        },
      };
      expect(data).toMatchObject(expected);

      // cleanup
      cleanup.projects.push(project);
    });

    it('When I update a project availability, I expect the updated availability to be returned. #mutation #updateProject #availability', async () => {
      // Arrange
      const project = { name: fakeName(10) };
      const { data: addProjectData } = await addProject(project);

      // Act
      const { data } = await updateProject(addProjectData.data.addProject.id, {
        availability: 'HIGH',
      });

      if (!data.data.updateProject) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      const expected = {
        data: {
          updateProject: {
            name: project.name,
            availability: 'HIGH',
          },
        },
      };
      expect(data).toMatchObject(expected);

      // cleanup
      cleanup.projects.push(project);
    });

    it("When I add a project to a billing group, I should see that project returned in the billing groups' projects array. #mutation #addProjectToBillingGroup", async () => {
      // Arrange
      const project = { name: fakeName(10) };
      const group = { name: fakeName(10) };

      await addProject(project);
      await addBillingGroup(group);

      // Act
      const { data } = await addProjectToBillingGroup(project, group);

      if (!data.data.addProjectToBillingGroup) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      const expected = {
        data: {
          addProjectToBillingGroup: {
            name: project.name,
            groups: [{ name: `project-${project.name}` }, { name: group.name }],
          },
        },
      };

      // Sort the resulting group array otherwise the array order can throw off the test
      const nameSortFn = (a, b) => (a.name > b.name ? 1 : -1);
      data.data.addProjectToBillingGroup.groups.sort(nameSortFn);
      expected.data.addProjectToBillingGroup.groups.sort(nameSortFn);

      expect(data).toMatchObject(expected);

      // cleanup
      cleanup.groups.push(group);
      cleanup.projects.push(project);
    }, 60000);

    it("When I update the billing group associated to a project, I should see that project in the new billing groups' projects. #mutation #updateProjectBillingGroup", async () => {
      // Arrange
      const project = { name: fakeName(10) };
      const group = { name: fakeName(10) };
      const group2 = { name: fakeName(10) };

      await addProject(project);
      await addBillingGroup(group);
      await addBillingGroup(group2);
      await addProjectToBillingGroup(project, group);

      // Act
      const { data } = await updateProjectBillingGroup(project, group2);

      if (!data.data.updateProjectBillingGroup) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      expect(data.data.updateProjectBillingGroup.groups).toContainEqual(group2);

      // cleanup
      cleanup.groups.push(group);
      cleanup.groups.push(group2);
      cleanup.projects.push(project);
    }, 120000);

    it("When I remove a project from a billing group, I should NOT see that project in the billing groups' project list. #mutation #removeProjectFromBillingGroup", async () => {
      // Arrange
      const project = { name: fakeName(10) };
      const group = { name: fakeName(10) };

      await addProject(project);
      await addBillingGroup(group);
      await addProjectToBillingGroup(project, group);

      // Act
      const { data } = await removeProjectFromBillingGroup(group, project);

      if (!data.data.removeProjectFromBillingGroup) {
        throw new Error(data.errors[0].message);
      }

      // Assert
      expect(data.data.removeProjectFromBillingGroup.groups.length).toBe(1);

      // cleanup
      cleanup.groups.push(group);
      cleanup.projects.push(project);
    }, 60000);
  });

  describe('BillingGroup Related Queries #queries', () => {
    // scenarios and expectation

    it('When I query for all projects, filtered by the "test" gitUrl, I expect the result to match the query signature. #query #allProjects', async () => {
      // Arrange
      const project: Project = {
        name: fakeName(10),
        gitUrl: `http://github.com/amazeeio/${fakeName(5)}`,
      };
      await addProject(project);

      // Act
      const { data } = await allProjects(null, project.gitUrl);

      // Assert
      expect(data.data.allProjects.length).toBeGreaterThan(0);

      // cleanup
      cleanup.projects.push(project);
    }, 60000);

    it('When I query for the "high-cotton" project by name, I expect the result to match the query signature. #query #projectByName', async () => {
      // Arrange
      // Act
      const { data } = await projectByName('high-cotton');

      // Assert
      const expected = {
        data: {
          projectByName: {
            name: 'high-cotton',
          },
        },
      };
      expect(data).toMatchObject(expected);
    }, 60000);

    it('When I query for all groups filtered by billing type, I expect "High Cotton Billing Group" to be in the returned result. #query #allGroups', async () => {
      // Arrange
      // Act
      const { data } = await allGroups('billing');

      const group = await data.data.allGroups.find(
        group => group.name === 'High Cotton Billing Group',
      );

      // Assert
      const expected = {
        name: 'High Cotton Billing Group',
        type: 'billing',
        currency: 'USD',
      };
      expect(group).toEqual(expected);
    }, 60000);

    it('When I query for all projects in a group, I expect the result to match the query signature. #query #allProjectsInGroup', async () => {
      // Arrange
      const project = { name: 'High Cotton Billing Group' };

      // Act
      const { data } = await allProjectsInGroup(project);

      // Assert
      const expected = {
        data: {
          allProjectsInGroup: [
            {
              name: 'high-cotton',
            },
          ],
        },
      };
      expect(data).toMatchObject(expected);
    });

    it('When I query for the billing group cost, I expect the result to match the test data for hits, storage, and environment hours. #query #billingGroupCost', async () => {
      // Arrange
      const group = { name: 'High Cotton Billing Group' };

      // Act
      const { data } = await billingGroupCost(group, '2019-08');

      // Assert
      const expected = {
        data: {
          billingGroupCost: {
            currency: 'USD',
            availability: {
              high: {
                hitCost: 200,
                storageCost: 0,
                environmentCost: {
                  environmentCost: {
                    prod: 0,
                    dev: 0,
                  },
                },
                projects: [
                  {
                    id: '18',
                    name: 'high-cotton',
                    availability: 'HIGH',
                    hits: 0,
                    storageDays: 0,
                    prodHours: 0,
                    devHours: 0,
                    environments: [
                      {
                        id: '3',
                        name: 'Master',
                        type: 'production',
                        hits: {
                          total: 0,
                        },
                        storage: {
                          bytesUsed: null,
                          month: null,
                        },
                        hours: {
                          month: '2019-08',
                          hours: 0,
                        },
                      },
                      {
                        id: '4',
                        name: 'Staging',
                        type: 'development',
                        hits: {
                          total: 0,
                        },
                        storage: {
                          bytesUsed: null,
                          month: null,
                        },
                        hours: {
                          month: '2019-08',
                          hours: 0,
                        },
                      },
                      {
                        id: '5',
                        name: 'Development',
                        type: 'development',
                        hits: {
                          total: 0,
                        },
                        storage: {
                          bytesUsed: null,
                          month: null,
                        },
                        hours: {
                          month: '2019-08',
                          hours: 0,
                        },
                      },
                      {
                        id: '6',
                        name: 'PR-175',
                        type: 'development',
                        hits: {
                          total: 0,
                        },
                        storage: {
                          bytesUsed: null,
                          month: null,
                        },
                        hours: {
                          month: '2019-08',
                          hours: 0,
                        },
                      },
                    ],
                    month: '08',
                    year: '2019',
                  },
                ],
              },
            },
          },
        },
      };
      expect(data).toMatchObject(expected);
    });
  });
});
