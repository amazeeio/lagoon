# Node.js Service Debugging
All of the Node based services in Lagoon are setup to allow remote debugging.

## Using Visual Studio Code locally

1. Open the Run view (⇧⌘D).
2. Select the service you'd like to debug from the RUN dropdown, then click the
   green arrow.
3. Your local `dist` needs to be up to date with `src` folder in order for
   sourcemaps and breakpoints to work correctly, so always run `yarn build` to
   keep it up to date

## Using Visual Studio Code Remote - Containers extension

1. Attach to the container you want to debug.
2. Open the Run view (⇧⌘D) and click the green RUN arrow (there is only one
   configuration).

## Using another debugger

1. You must first enable the Node inspector in the container. This can be done
   by sending the `SIGUSR1` signal to the node process.

   Using `docker-compose`:

   ```bash
   docker-compose exec <service-name> sh -c 'pkill -SIGUSR1 -f inspect'
   ```

   From inside the container:

   ```bash
   pkill -SIGUSR1 -f inspect
   ```

2. Then lookup the exposed port for that service in the `docker-compose.yml`
   file. All the debugger ports are in the range 9000-9020.
