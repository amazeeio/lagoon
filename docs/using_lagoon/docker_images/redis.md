# Redis Image
Lagoon `Redis` image Dockerfile, based on offical `redis:alpine` image.

This Dockerfile is intended to be used to setup a standalone Redis *ephemeral* server by default.

## Lagoon & OpenShift adaptions
This image is prepared to be used on Lagoon which leverages OpenShift. There are therefore some things already done:

- Folder permissions are automatically adapted with [`fix-permissions`](https://github.com/sclorg/s2i-base-container/blob/master/core/root/usr/bin/fix-permissions) so this image will work with a random user and therefore also on OpenShift.
- The files within `/etc/redis/*` are parsed through [envplate](https://github.com/kreuzwerker/envplate) with an container-entrypoint.

## Included `redis.conf` configuration file
The image ships a *default* Redis configuration file, optimized to work on Lagoon.
Some options are configurable via environments variables (see [Environment Variables](#environment-variables)).

## Environment Variables
Environment variables defined in Redis base image. See also https://raw.githubusercontent.com/antirez/redis/4.0/redis.conf for futher confis.

| Environment Variable                   | Default          | Description                               |
| ---------------------------------      | ---------        | ---------------------------------------------- |
| `LOGLEVEL`                             |   notice 	    | Define the level of logs                             |
| `DATABASES`                            |   -1 	        | Default number of databases created at startup       |
| `MAXMEMORY`                            |   100mb 	        | Maximum amount of memory |