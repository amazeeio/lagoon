import React, { useState } from 'react';
import { bp, color, fontSize } from 'lib/variables';
import useSortableData from '../../lib/withSortedItems';

const Facts = ({ facts }) => {
    const { sortedItems, getClassNamesFor, requestSort } = useSortableData(facts, {key: 'name', direction: 'ascending'});

    const [factTerm, setFactTerm] = useState('');
    const [hasFilter, setHasFilter] = React.useState(false);

    const handleFactFilterChange = (event) => {
        setHasFilter(false);

        if (event.target.value !== null || event.target.value !== '') {
            setHasFilter(true);
        }
        setFactTerm(event.target.value);
    };

    const handleSort = (key) => {
        return requestSort(key);
    };

    const filterResults = (item) => {
        const lowercasedFilter = factTerm.toLowerCase();

        if (factTerm == null || factTerm === '') {
            return facts;
        }

        return Object.keys(item).some(key => {
            if (item[key] !== null) {
                return item[key].toString().toLowerCase().includes(lowercasedFilter);
            }
        });
    };

    return (
        <div className="facts">
            <div className="filters">
                <input type="text" id="filter" placeholder="Filter facts e.g. PHP version"
                       value={factTerm}
                       onChange={handleFactFilterChange}
                />
            </div>
            <div className="header">
                <button
                    type="button"
                    onClick={() => handleSort('name')}
                    className={`button-sort name ${getClassNamesFor('name')}`}
                >
                    Name
                </button>
                <button
                    type="button"
                    onClick={() => handleSort('source')}
                    className={`button-sort value ${getClassNamesFor('source')}`}
                >
                    Source
                </button>
                <button
                    type="button"
                    onClick={() => handleSort('value')}
                    className={`button-sort value ${getClassNamesFor('value')}`}
                >
                    Value
                </button>
            </div>
            <div className="data-table">
                {!sortedItems.filter(fact => filterResults(fact)).length && <div className="data-none">No Facts</div>}
                {sortedItems.filter(fact => filterResults(fact)).map((fact) => {
                    return (
                        <div className="data-row row-heading" key={fact.id}>
                            <div className="col col-1">
                                <div className="name">{fact.name}</div>
                                <div className="description">{fact.description}</div>
                            </div>
                            <div className="col col-2">{fact.source}</div>
                            { fact.type == "URL"
                              ? <div className="col col-3"><a className="external-link" href={fact.value} target="_blank">{fact.value}</a></div>
                              : <div className="col col-3">{fact.value}</div>
                            }

                        </div>
                    );
                })}
            </div>
            <style jsx>{`
              .header {
                @media ${bp.smallOnly} {
                  flex-wrap: wrap;
                  margin: 10px;
                }
                @media ${bp.wideUp} {
                  align-items: center;
                  display: flex;
                  margin: 15px 20px 10px;
                }

                display: flex;
                justify-content: space-between;

                label {
                  display: none;
                  padding-left: 20px;
                  @media ${bp.wideUp} {
                    display: block;
                  }
                }
              }

              input#filter {
                width: 100%;
                border: none;
                padding: 10px 20px;
                margin: 0;
                font-style: italic;
              }

              .button-sort {
                color: #5f6f7a;
                position: relative;
                font-family: 'source-code-pro',sans-serif;
                font-size: 13px;
                font-size: 0.8125rem;
                line-height: 1.4;
                text-transform: uppercase;
                padding-left: 20px;
                border: none;
                background: none;
                cursor: pointer;

                &:after {
                  position: absolute;
                  right:  -18px;
                  top: 0;
                  width: 20px;
                  height: 20px;
                }

                &.ascending:after {
                  content: ' \\25B2';
                }

                &.descending:after {
                  content: ' \\25BC';
                }

                &:first-child {
                  padding-left: 0;
                }
              }

              .expanded-wrapper {
                padding: 20px;
                background: ${color.lightestGrey};
                .fieldWrapper {
                  padding-bottom: 20px;
                }
              }

              .data-row {
                display: flex;
                justify-content: space-between;
                border: 1px solid ${color.white};
                border-bottom: 1px solid ${color.lightestGrey};
                border-radius: 0;
                line-height: 1.5rem;

                @media ${bp.smallOnly} {
                  padding: 10px;
                }

                @media ${bp.wideUp} {
                  padding: 15px 0;
                }

                &:hover {
                  border: 1px solid ${color.brightBlue};
                }

                &:first-child {
                  border-top-left-radius: 3px;
                  border-top-right-radius: 3px;
                }

                &:last-child {
                  border-bottom-left-radius: 3px;
                  border-bottom-right-radius: 3px;
                }

                .col {
                  @media ${bp.wideUp} {
                    padding: 0 20px;
                  }
                  width: 33.33%;
                }

                .col-2 {
                  text-align: center;
                }

                .col-3  {
                  text-align: end;
                }

                .description {
                  font-style: italic;
                  font-size: 12px;
                }

                a.external-link {
                  color: ${color.brightBlue};
                  text-decoration: underline;
                  font-style: italic;
                }
              }

              .row-heading {
                background: ${color.white};
              }
            `}</style>
        </div>
    );
};

export default Facts;
