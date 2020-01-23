// @flow

const Sql = require('./sql');

describe('Sql', () => {
  describe('selectAssignedProjectNotificationByName', () => {
    it('should create proper statement', () => {
      const input = { name: 'slack_foo', type: 'slack' };
      const ret = Sql.selectProjectNotificationByNotificationName(input);
      expect(ret).toMatchSnapshot();
    });
  });

  describe('selectProjectNotificationsWithoutAccess', () => {
    it('should create a proper statement', () => {
      const cred = {
        permissions: {
          projects: ['3', '4'],
        },
      };

      const nids = ['1'];
      const ret = Sql.selectProjectNotificationsWithoutAccess(cred, { nids });
      expect(ret).toMatchSnapshot();
    });
  });

  describe('selectNotificationsByTypeByProjectId', () => {
    it('should create a proper query', () => {
      const input = {
        type: 'slack',
        pid: 3,
      };

      const ret = Sql.selectNotificationsByTypeByProjectId(input);
      expect(ret).toMatchSnapshot();
    });
  });

  describe('selectUnassignedNotificationsByType', () => {
    it('should create a proper query', () => {
      const ret = Sql.selectUnassignedNotificationsByType('rocketchat');
      expect(ret).toMatchSnapshot();
    });
  });

  describe('updateNotificationSlack', () => {
    it('should create a proper query', () => {
      const input = {
        name: 'n1',
        patch: {
          name: 'test',
          webhook: 'new-webhook',
        },
      };

      const ret = Sql.updateNotificationSlack(input);
      expect(ret).toMatchSnapshot();
    });
  });

  describe('selectCustomer', () => {
    it('should create a proper query', () => {
      const ret = Sql.selectNotificationSlackByName('n1');
      expect(ret).toMatchSnapshot();
    });
  });

  describe('deleteProjectNotification', () => {
    it('should create a proper query', () => {
      const input = {
        project: 'some_project',
        notificationType: 'slack',
        notificationName: 'some_slack',
      };

      const ret = Sql.deleteProjectNotification(input);
      expect(ret).toMatchSnapshot();
    });
  });
});
