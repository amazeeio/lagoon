# Use Lagoon

## Requirements

### Docker

To run Lagoon Project your system must meet the requirements to run Docker. We suggest installing the latest version of Docker for your workstation. You can download Docker [here](https://www.docker.com/get-docker). We also suggest allowing Docker at least 4 CPUs and 4GB RAM.

### Local Development Environments

TL;DR: install and start `pygmy`:

    gem install pygmy
    pygmy up

Learn more about Lagoon and [Local Development Environments](./local_development_environments.md)

## Step by Step Guides

- Drupal: [Lagoonize your Drupal Site](./drupal/lagoonize.md)
- [Setup a new Project in Lagoon](./setup_project.md)
- General: [First Deployment](./first_deployment.md)
- Drupal: [First Deployment Drupal](./drupal/first_deployment.md)

## Overview of Lagoon Configuration Files

### `.lagoon.yml`

They main file that will be used by Lagoon to understand what should be deployed and many more things. See [Documentation for .lagoon.yml]()

### `docker-compose.yml`

This file is used by Docker Compose to start you Local Development environment. Lagoon also uses it to understand which of the Services should be deployed, which type and how to build them. This happens via `labels`. See [Documentation for docker-compose.yml]()

### Dockerfiles

Some Docker Images and Containers need additional customizations from the provided Images, this usually has two reasons:
1. Application code: Containers like Nginx, PHP, Node, etc. need the actual programming code within their Images. This is done during a Docker Build step which are configured in Dockerfiles. Lagoon has full support for Docker and therefore also allows you full control over the resulting Images via Dockerfile customizations.
2. Customization of Images: Lagoon also allows you to customize the base Images according to your needs. This can be to inject an addtional environment variable, change a service configuration or even install additional tools, even though we advise caution with installing additional tools to the Docker Images, as such adaptations need to be maintained by yourself in the future!

## Supported Services & Base Images by Lagoon

| Type           | Versions      | Dockerfile                                                                                                   | Notes                |
| ---------------| --------------| -------------------------------------------------------------------------------------------------------------| ---------------------|
| nginx          | 1.12          | [nginx/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/nginx/Dockerfile)                   |                      |
| nginx-drupal   |               | [nginx-drupal/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/nginx-drupal/Dockerfile)     |                      |
| php-fpm        | 5.6, 7.0, 7.1 | [php/fpm/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/php/fpm/Dockerfile)               |                      |
| php-cli        | 5.6, 7.0, 7.1 | [php/cli/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/php/cli/Dockerfile)               |                      |
| php-cli-drupal | 5.6, 7.0, 7.1 | [php/cli-drupal/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/php/cli-drupal/Dockerfile) |                      |
| mariadb        | 10            | [mariadb/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/mariadb/Dockerfile)               |                      |
| mariadb-drupal | 10            | [mariadb-drupal/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/mariadb-drupal/Dockerfile) |                      |
| mongo          | 3.6           | [mongo/Dockerfile](https://github.com/amazeeio/lagoon/blob/master/images/mongo/Dockerfile)                   |                      |
| solr           |               |                                                                                                              |                      |
| solr-drupal    |               |                                                                                                              |                      |
| redis          |               |                                                                                                              |                      |
| varnish        |               |                                                                                                              |                      |
| varnish-drupal |               |                                                                                                              |                      |
