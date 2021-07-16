const express = require('express');
const next = require('next');

const dev = process.env.NODE_ENV !== 'production';
const port = dev ? 3003 : 3000;
const app = next({
  dev,
  dir: 'src'
});
const handle = app.getRequestHandler();

app
  .prepare()
  .then(() => {
    const server = express();

    server.use((req, res, next) => {
      // Express middleware to add security headers to the responses.
      res.header('X-Content-Type-Options', 'nosniff');
      res.header('X-Frame-Options', 'SameOrigin');
      next()
    })

    // Handle favicon requests that ignore our HTML meta tags.
    server.get('/favicon.ico', (req, res) =>
      res
        .status(200)
        .sendFile('favicon.ico', {
          root: __dirname + '/src/static/images/favicons/'
        })
    );

    server.get('/projects', (req, res) => {
      app.render(req, res, '/projects');
    });

    server.get('/projects/:projectSlug', (req, res) => {
      app.render(req, res, '/project', { projectName: req.params.projectSlug });
    });

    server.get('/projects/:projectSlug/:environmentSlug', (req, res) => {
      app.render(req, res, '/environment', {
        openshiftProjectName: req.params.environmentSlug
      });
    });

    server.get(
      '/projects/:projectSlug/:environmentSlug/backups',
      (req, res) => {
        app.render(req, res, '/backups', {
          openshiftProjectName: req.params.environmentSlug
        });
      }
    );

    server.get(
      '/projects/:projectSlug/:environmentSlug/deployments',
      (req, res) => {
        app.render(req, res, '/deployments', {
          openshiftProjectName: req.params.environmentSlug
        });
      }
    );

    server.get(
      '/projects/:projectSlug/:environmentSlug/deployments/:deploymentSlug',
      (req, res) => {
        app.render(req, res, '/deployment', {
          openshiftProjectName: req.params.environmentSlug,
          deploymentName: req.params.deploymentSlug
        });
      }
    );

    server.get('/projects/:projectSlug/:environmentSlug/tasks', (req, res) => {
      app.render(req, res, '/tasks', {
        openshiftProjectName: req.params.environmentSlug
      });
    });

    server.get(
      '/projects/:projectSlug/:environmentSlug/tasks/:taskSlug',
      (req, res) => {
        app.render(req, res, '/task', {
          openshiftProjectName: req.params.environmentSlug,
          taskId: req.params.taskSlug
        });
      }
    );

    server.get(
      '/projects/:projectSlug/:environmentSlug/problems',
      (req, res) => {
        app.render(req, res, '/problems', {
          openshiftProjectName: req.params.environmentSlug
        });
      }
    );

    server.get('/problems/project', (req, res) => {
      app.render(req, res, '/problems-dashboard-by-project');
    });

    server.get('/problems', (req, res) => {
      app.render(req, res, '/problems-dashboard-by-project-hex');
    });

    server.get('/problems/identifier', (req, res) => {
      app.render(req, res, '/problems-dashboard');
    });

    server.get('/projects/:projectSlug/:environmentSlug/facts', (req, res) => {
      app.render(req, res, '/facts', {
        openshiftProjectName: req.params.environmentSlug
      });
    });

    server.get('*', (req, res) => {
      return handle(req, res);
    });

    server.listen(port, err => {
      if (err) throw err;
      console.log('> Ready on http://localhost:' + port);
    });
  })
  .catch(ex => {
    console.error(ex.stack);
    process.exit(1);
  });
