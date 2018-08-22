USE infrastructure;

-- Tables

CREATE TABLE IF NOT EXISTS ssh_key (
       id            int NOT NULL auto_increment PRIMARY KEY,
       name          varchar(100) NOT NULL,
       keyValue      varchar(5000) NOT NULL,
       keyType       ENUM('ssh-rsa', 'ssh-ed25519') NOT NULL DEFAULT 'ssh-rsa',
       created       timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS customer (
       id             int NOT NULL auto_increment PRIMARY KEY,
       name           varchar(50) UNIQUE,
       comment        text,
       private_key    varchar(5000),
       created        timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS openshift (
       id              int NOT NULL auto_increment PRIMARY KEY,
       name            varchar(50) UNIQUE,
       console_url     varchar(300),
       token           varchar(1000),
       router_pattern  varchar(300),
       project_user    varchar(100),
       ssh_host        varchar(300),
       ssh_port        varchar(50),
       created         timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS notification_rocketchat (
       id          int NOT NULL auto_increment PRIMARY KEY,
       name        varchar(50) UNIQUE,
       webhook     varchar(300),
       channel     varchar(300)
);

CREATE TABLE IF NOT EXISTS notification_slack (
       id          int NOT NULL auto_increment PRIMARY KEY,
       name        varchar(50) UNIQUE,
       webhook     varchar(300),
       channel     varchar(300)
);


CREATE TABLE IF NOT EXISTS project (
       id                     int NOT NULL auto_increment PRIMARY KEY,
       name                   varchar(100) UNIQUE,
       customer               int REFERENCES customer (id),
       git_url                varchar(300),
       subfolder              varchar(300),
       active_systems_deploy  varchar(300),
       active_systems_promote varchar(300),
       active_systems_remove  varchar(300),
       branches               varchar(300),
       pullrequests           varchar(300),
       production_environment varchar(100),
       auto_idle              int(1) NOT NULL default 1,
       storage_calc           int(1) NOT NULL default 1,
       openshift              int REFERENCES openshift (id),
       openshift_project_pattern varchar(300),
       created                timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS environment (
       id                     int NOT NULL auto_increment PRIMARY KEY,
       name                   varchar(100),
       project                int REFERENCES project (id),
       deploy_type            ENUM('branch', 'pullrequest', 'promote') NOT NULL,
       environment_type       ENUM('production', 'development') NOT NULL,
       openshift_projectname  varchar(100),
       lagoon_route           varchar(300),
       lagoon_routes          text,
       monitoring_urls        text,
       updated                timestamp DEFAULT CURRENT_TIMESTAMP,
       created                timestamp DEFAULT CURRENT_TIMESTAMP,
       deleted                timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
       UNIQUE KEY `project_name_deleted` (`project`,`name`, `deleted`)
);

CREATE TABLE IF NOT EXISTS environment_storage (
       id                       int NOT NULL auto_increment PRIMARY KEY,
       environment              int REFERENCES environment (id),
       persistent_storage_claim varchar(100),
       bytes_used               bigint,
       updated                  date,
       UNIQUE KEY `environment_persistent_storage_claim_updated` (`environment`,`persistent_storage_claim`, `updated`)
);

-- Junction Tables

CREATE TABLE IF NOT EXISTS project_notification (
       nid              int,
       pid              int REFERENCES project (id),
       type             ENUM('slack','rocketchat') NOT NULL,
       CONSTRAINT project_notification_pkey PRIMARY KEY (nid, pid, type)
);

CREATE TABLE IF NOT EXISTS customer_ssh_key (
       cid int REFERENCES customer (id),
       skid int REFERENCES ssh_key (id),
       CONSTRAINT customer_ssh_key_pkey PRIMARY KEY (cid, skid)
);

CREATE TABLE IF NOT EXISTS project_ssh_key (
       pid int REFERENCES project (id),
       skid int REFERENCES ssh_key (id),
       CONSTRAINT project_ssh_key_pkey PRIMARY KEY (pid, skid)
);


DROP VIEW IF EXISTS pid_skid;
CREATE VIEW pid_skid
AS
  SELECT DISTINCT
          p.id as pid, csk.skid as skid
        FROM customer_ssh_key csk
        INNER JOIN customer c ON csk.cid = c.id
        INNER JOIN project p ON p.customer = c.id
        UNION DISTINCT
        SELECT psk.pid AS pid, psk.skid as skid
        FROM project_ssh_key psk;

DROP VIEW IF EXISTS permission;
CREATE VIEW permission
AS
  SELECT
    sk.id AS keyId,
    CONCAT(sk.keyType, ' ', sk.keyValue) AS sshKey,
    (SELECT
      GROUP_CONCAT(DISTINCT csk.cid SEPARATOR ',')
      FROM customer_ssh_key csk
      WHERE csk.skid = sk.id) as customers,
    (SELECT GROUP_CONCAT(DISTINCT r.pid SEPARATOR ',')
      FROM
      pid_skid AS r
      WHERE r.skid = sk.id
    ) AS projects
  FROM ssh_key sk;

DELIMITER $$

CREATE OR REPLACE PROCEDURE
  add_production_environment_to_project()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'project'
                AND table_schema = 'infrastructure'
                AND column_name = 'production_environment'
            )  THEN
      ALTER TABLE `project` ADD `production_environment` varchar(100);

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_ssh_to_openshift()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'openshift'
                AND table_schema = 'infrastructure'
                AND column_name = 'ssh_host'
            )  THEN
      ALTER TABLE `openshift` ADD `ssh_host` varchar(300);
      ALTER TABLE `openshift` ADD `ssh_port` varchar(50);

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  convert_project_pullrequest_to_varchar()

  BEGIN
    DECLARE column_type varchar(50);
    SELECT DATA_TYPE into column_type
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE table_name = 'project'
        AND table_schema = 'infrastructure'
        AND column_name = 'pullrequests';
    IF (column_type = 'tinyint') THEN
      ALTER TABLE project MODIFY pullrequests varchar(300);
    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_active_systems_promote_to_project()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'project'
                AND table_schema = 'infrastructure'
                AND column_name = 'active_systems_promote'
            )  THEN
      ALTER TABLE `project` ADD `active_systems_promote` varchar(300);
      UPDATE project SET active_systems_promote = 'lagoon_openshiftBuildDeploy';

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  rename_git_type_to_deploy_type_in_environment()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'environment'
                AND table_schema = 'infrastructure'
                AND column_name = 'deploy_type'
            )  THEN
      ALTER TABLE `environment` CHANGE `git_type` `deploy_type` ENUM('branch','pullrequest');

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_enum_promote_to_deploy_type_in_environment()

  BEGIN
    DECLARE column_type_enum_deploy_type varchar(50);

    SELECT COLUMN_TYPE into column_type_enum_deploy_type
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE table_name = 'environment'
        AND table_schema = 'infrastructure'
        AND column_name = 'deploy_type';

	  IF (column_type_enum_deploy_type = "enum('branch','pullrequest')") THEN
      ALTER TABLE environment MODIFY deploy_type ENUM('branch','pullrequest','promote');
    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_autoidle_to_project()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'project'
                AND table_schema = 'infrastructure'
                AND column_name = 'auto_idle'
            )  THEN
      ALTER TABLE `project` ADD `auto_idle` int(1) NOT NULL default '1';


    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_enum_rocketchat_to_type_in_project_notification()

  BEGIN
    DECLARE column_type_project_notification_type varchar(50);

    SELECT COLUMN_TYPE into column_type_project_notification_type
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE table_name = 'project_notification'
        AND table_schema = 'infrastructure'
        AND column_name = 'type';

	  IF (column_type_project_notification_type = "enum('slack')") THEN
      ALTER TABLE project_notification MODIFY type ENUM('slack','rocketchat');
    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_deleted_to_environment()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'environment'
                AND table_schema = 'infrastructure'
                AND column_name = 'deleted'
            )  THEN
      ALTER TABLE `environment` DROP INDEX project_name;
      ALTER TABLE `environment` ADD `deleted` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00';
      ALTER TABLE `environment` ADD UNIQUE KEY `project_name_deleted` (`project`,`name`, `deleted`);

    END IF;

  END;
$$


CREATE OR REPLACE PROCEDURE
  add_storagecalc_to_project()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'project'
                AND table_schema = 'infrastructure'
                AND column_name = 'storage_calc'
            )  THEN
      ALTER TABLE `project` ADD `storage_calc` int(1) NOT NULL default '1';

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_project_pattern_to_openshift()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'openshift'
                AND table_schema = 'infrastructure'
                AND column_name = 'project_pattern'
            )  THEN
      ALTER TABLE `openshift` ADD `project_pattern` varchar(300);

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_subfolder_to_project()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'project'
                AND table_schema = 'infrastructure'
                AND column_name = 'subfolder'
            )  THEN
      ALTER TABLE `project` ADD `subfolder` varchar(300);

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  delete_project_pattern_from_openshift()

  BEGIN

    IF EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'openshift'
                AND table_schema = 'infrastructure'
                AND column_name = 'project_pattern'
            )  THEN
      ALTER TABLE `openshift` DROP COLUMN `project_pattern`;

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_openshift_project_pattern_to_project()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'project'
                AND table_schema = 'infrastructure'
                AND column_name = 'openshift_project_pattern'
            )  THEN
      ALTER TABLE `project` ADD `openshift_project_pattern` varchar(300);

    END IF;

  END;
$$

CREATE OR REPLACE PROCEDURE
  add_routes_monitoring_urls_to_environments()

  BEGIN

    IF NOT EXISTS(
              SELECT NULL
                FROM INFORMATION_SCHEMA.COLUMNS
              WHERE table_name = 'environment'
                AND table_schema = 'infrastructure'
                AND column_name = 'lagoon_route'
            )  THEN
      ALTER TABLE `environment` ADD `lagoon_route`    varchar(300);
      ALTER TABLE `environment` ADD `lagoon_routes`   text;
      ALTER TABLE `environment` ADD `monitoring_urls` text;

    END IF;

  END;
$$

DELIMITER ;

CALL add_production_environment_to_project;
CALL add_ssh_to_openshift;
CALL convert_project_pullrequest_to_varchar;
CALL add_active_systems_promote_to_project;
CALL rename_git_type_to_deploy_type_in_environment;
CALL add_enum_promote_to_deploy_type_in_environment;
CALL add_autoidle_to_project;
CALL add_enum_rocketchat_to_type_in_project_notification();
CALL add_deleted_to_environment;
CALL add_storagecalc_to_project();
CALL add_project_pattern_to_openshift();
CALL add_subfolder_to_project();
CALL delete_project_pattern_from_openshift();
CALL add_openshift_project_pattern_to_project();
CALL add_routes_monitoring_urls_to_environments();
