# Active Standby

Lagoon supports Active/Standby (also known as blue/green) deployments.

## Configuration
To change an existing project to support active/standby you'll need to configure some project settings in the Lagoon API

`productionEnviromment` should be set to the branch name of the current environment that is active
`standbyProductionEnvironment` should be set to the branch name of the current environment that is in standby

```
mutation updateProject {
  updateProject(input:{
    id:1234
    patch:{
      productionEnvironment:"production-brancha"
      standbyProductionEnvironment:"production-branchb"
    }
  }){
    standbyProductionEnvironment
    name
    productionEnvironment
  }
}
```
### `.lagoon.yml` - `production_routes`
To configure a project for active/standby in the `.lagoon.yml` file, you'll need to configure the `production_routes` section with any routes you want to attach to the `active` environment, and any routes to the `standby` environment. During an Active/Standby switch, these routes will migrate between the two environments.

If you have two production environments, `production-brancha` and `production-branchb`, with the current active production environment as `production-brancha` then:
* routes under `production_routes.active` will direct you to `production-brancha`.
* routes under `production_routes.standby` will direct you to `production-branchb`.

During an Active/Standby switch, the routes will swap:
* routes under `production_routes.active` will direct you to `production-branchb`.
* routes under `production_routes.standby` will direct you to `production-brancha`.

```
production_routes:
  active:
    routes:
      - nginx:
        - example.com:
            tls-acme: 'false'
        - active.example.com:
            tls-acme: 'false'
  standby:
    routes:
      - nginx:
        - standby.example.com:
            tls-acme: 'false'
```

## Triggering a switch event

To trigger an event to switch the environments, you can run the following graphQL mutation, this will inform lagoon to begin the process.

```
mutation ActiveStandby {
  deployActiveStandby(
    input:{
      project:{
        name:"drupal-example"
      }
    }
  )
}
```

@TODO: status check