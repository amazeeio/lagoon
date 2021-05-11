import React, { useState } from 'react';
import * as R from 'ramda';
import { withRouter } from 'next/router';
import Head from 'next/head';
import { Query } from 'react-apollo';
import MainLayout from 'layouts/MainLayout';
import ProjectByNameQuery from 'lib/query/ProjectByName';
import Breadcrumbs from 'components/Breadcrumbs';
import ProjectBreadcrumb from 'components/Breadcrumbs/Project';
import ProjectDetailsSidebar from 'components/ProjectDetailsSidebar';
import Environments from 'components/Environments';
import withQueryLoading from 'lib/withQueryLoading';
import withQueryError from 'lib/withQueryError';
import { withProjectRequired } from 'lib/withDataRequired';
import { bp, color } from 'lib/variables';
import ToggleDisplay from '../components/ToggleDisplay';

/**
 * Displays a project page, given the project name.
 */
export const PageProject = ({ router }) => (
  <>
    <Head>
      <title>{`${router.query.projectName} | Project`}</title>
    </Head>
    <Query
      query={ProjectByNameQuery}
      variables={{ name: router.query.projectName }}
    >
      {R.compose(
        withQueryLoading,
        withQueryError,
        withProjectRequired
      )(({ data: { project } }) => {
        const [toggleDisplay, setToggleDisplay] = useState('list');

        // Sort alphabetically by environmentType and then deployType
        const environments = R.sortWith(
          [
            R.descend(R.prop('environmentType')),
            R.ascend(R.prop('deployType'))
          ],
          project.environments
        );

        const changeDisplay = () => {
          if (toggleDisplay == 'list') {
            setToggleDisplay('detailed')
          }
          if (toggleDisplay == 'detailed') {
            setToggleDisplay('list')
          }
        };

        return (
          <MainLayout>
            <Breadcrumbs>
              <ProjectBreadcrumb projectSlug={project.name} />
            </Breadcrumbs>
            <div className="content-wrapper">
              <div className="project-details-sidebar">
                <ProjectDetailsSidebar project={project} />
              </div>
              <div className="environments-wrapper">
                <div className="environments-header">
                  <div className="title">
                    <h3>Environments</h3>
                  </div>
                  <div className="toggle">
                    <label>Toggle</label>
                    <ToggleDisplay
                      action={changeDisplay}
                      disabled={toggleDisplay === 'list'}
                    >
                      List view
                    </ToggleDisplay>
                    <ToggleDisplay
                      action={changeDisplay}
                      disabled={toggleDisplay === 'detailed'}
                    >
                      Detailed view
                    </ToggleDisplay>
                  </div>
                </div>
                {!environments.length && <p>No Environments</p>}
                <Environments environments={environments} display={toggleDisplay} />
              </div>
            </div>
            <style jsx>{`
              .content-wrapper {
                @media ${bp.tabletUp} {
                  display: flex;
                  justify-content: space-between;
                }
              }

              .project-details-sidebar {
                background-color: ${color.lightestGrey};
                border-right: 1px solid ${color.midGrey};
                padding: 32px calc((100vw / 16) * 1);
                width: 100%;
                @media ${bp.xs_smallUp} {
                  padding: 24px calc((100vw / 16) * 1) 24px
                    calc(((100vw / 16) * 1.5) + 28px);
                }
                @media ${bp.tabletUp} {
                  min-width: 50%;
                  padding: 48px calc(((100vw / 16) * 1) + 28px);
                  width: 50%;
                }
                @media ${bp.desktopUp} {
                  min-width: 40%;
                  padding: 48px calc((100vw / 16) * 1);
                  width: 40%;
                }
                @media ${bp.wideUp} {
                  min-width: 33.33%;
                  min-width: calc((100vw / 16) * 5);
                  width: 33.33%;
                  width: calc((100vw / 16) * 5);
                }
              }

              .environments-wrapper {
                flex-grow: 1;
                padding: 40px calc((100vw / 16) * 1);
              }
              
              .environments-header {
                display: flex;
                justify-content: space-between;
              }
            `}</style>
          </MainLayout>
        );
      })}
    </Query>
  </>
);

export default withRouter(PageProject);
