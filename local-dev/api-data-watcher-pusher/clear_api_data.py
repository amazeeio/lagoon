#!/usr/bin/env python3

import mysql.connector
import errno

__PATH_TO_NAS__ = "./"

# DataBase connection
try:
    cnx = mysql.connector.connect(user='api', password='api', host='api-db', database='infrastructure')
    cursor = cnx.cursor(buffered=False, dictionary=False)
except mysql.connector.Error as err:
    if err.errno == errorcode.ER_ACCESS_DENIED_ERROR:
        print("Something is wrong with your user name or password")
    elif err.errno == errorcode.ER_BAD_DB_ERROR:
        print("Database does not exist")
    else:
        print(err)

user_ssh_key = "TRUNCATE TABLE `user_ssh_key`"
user = "TRUNCATE TABLE `user`"
task_file = "TRUNCATE TABLE `task_file`"
task = "TRUNCATE TABLE `task`"
ssh_key = "TRUNCATE TABLE `ssh_key`"
s3_file = "TRUNCATE TABLE `s3_file`"
project_user = "TRUNCATE TABLE `project_user`"
project_notification = "TRUNCATE TABLE `project_notification`"
project = "TRUNCATE TABLE `project`"
problem_harbor_scan_matcher = "TRUNCATE TABLE `problem_harbor_scan_matcher`"
openshift = "TRUNCATE TABLE `openshift`"
notification_slack = "TRUNCATE TABLE `notification_slack`"
notification_rocketchat = "TRUNCATE TABLE `notification_rocketchat`"
notification_microsoftteams = "TRUNCATE TABLE `notification_microsoftteams`"
notification_email = "TRUNCATE TABLE `notification_email`"
environment_storage = "TRUNCATE TABLE `environment_storage`"
environment_service = "TRUNCATE TABLE `environment_service`"
environment_problem = "TRUNCATE TABLE `environment_problem`"
environment_fact = "TRUNCATE TABLE `environment_fact`"
environment_backup = "TRUNCATE TABLE `environment_backup`"
environment = "TRUNCATE TABLE `environment`"
env_vars = "TRUNCATE TABLE `env_vars`"
deployment = "TRUNCATE TABLE `deployment`"
customer_user = "TRUNCATE TABLE `customer_user`"
customer = "TRUNCATE TABLE `customer`"
billing_modifier = "TRUNCATE TABLE `billing_modifier`"
backup_restore = "TRUNCATE TABLE `backup_restore`"

cursor.execute(user_ssh_key)
cursor.execute(user)
cursor.execute(task_file)
cursor.execute(task)
cursor.execute(ssh_key)
cursor.execute(s3_file)
cursor.execute(project_user)
cursor.execute(project_notification)
cursor.execute(project)
cursor.execute(problem_harbor_scan_matcher)
cursor.execute(openshift)
cursor.execute(notification_slack)
cursor.execute(notification_rocketchat)
cursor.execute(notification_microsoftteams)
cursor.execute(notification_email)
cursor.execute(environment_storage)
cursor.execute(environment_service)
cursor.execute(environment_problem)
cursor.execute(environment_fact)
cursor.execute(environment_backup)
cursor.execute(environment)
cursor.execute(env_vars)
cursor.execute(deployment)
cursor.execute(customer_user)
cursor.execute(customer)
cursor.execute(billing_modifier)
cursor.execute(backup_restore)

cursor.close()
cnx.close()
