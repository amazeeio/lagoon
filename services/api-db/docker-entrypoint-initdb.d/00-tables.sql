USE infrastructure;

-- Tables

CREATE TABLE IF NOT EXISTS ssh_key (
  id               int NOT NULL auto_increment PRIMARY KEY,
  name             varchar(100) NOT NULL,
  key_value        varchar(5000) NOT NULL,
  key_type         ENUM('ssh-rsa', 'ssh-ed25519') NOT NULL DEFAULT 'ssh-rsa',
  key_fingerprint  char(51) NULL UNIQUE,
  created          timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user (
  id            int NOT NULL auto_increment PRIMARY KEY,
  email         varchar(100) UNIQUE,
  first_name    varchar(50),
  last_name     varchar(50),
  comment       text,
  gitlab_id     int
);

CREATE TABLE IF NOT EXISTS customer (
  id             int NOT NULL auto_increment PRIMARY KEY,
  name           varchar(50) UNIQUE,
  comment        text,
  private_key    varchar(5000),
  created        timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS openshift (
  id                int NOT NULL auto_increment PRIMARY KEY,
  name              varchar(50) UNIQUE,
  console_url       varchar(300),
  token             varchar(2000),
  router_pattern    varchar(300),
  project_user      varchar(100),
  ssh_host          varchar(300),
  ssh_port          varchar(50),
  monitoring_config varchar(2048),
  created           timestamp DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS notification_microsoftteams (
  id          int NOT NULL auto_increment PRIMARY KEY,
  name        varchar(50) UNIQUE,
  webhook     varchar(512)
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

CREATE TABLE IF NOT EXISTS notification_email (
  id            int NOT NULL auto_increment PRIMARY KEY,
  name          varchar(50) UNIQUE,
  email_address varchar(300)
);


CREATE TABLE IF NOT EXISTS project (
  id                               int NOT NULL auto_increment PRIMARY KEY,
  name                             varchar(100) UNIQUE,
  customer                         int REFERENCES customer (id),
  git_url                          varchar(300),
  availability                     varchar(50) NOT NULL DEFAULT 'STANDARD',
  subfolder                        varchar(300),
  active_systems_deploy            varchar(300),
  active_systems_promote           varchar(300),
  active_systems_remove            varchar(300),
  active_systems_task              varchar(300),
  active_systems_misc              varchar(300),
  branches                         varchar(300),
  pullrequests                     varchar(300),
  production_environment           varchar(100),
  production_routes                text,
  production_alias                 varchar(100) NOT NULL DEFAULT 'lagoon-production',
  standby_production_environment   varchar(100),
  standby_routes                   text,
  standby_alias                    varchar(100) NOT NULL DEFAULT 'lagoon-standby',
  auto_idle                        int(1) NOT NULL default 1,
  storage_calc                     int(1) NOT NULL default 1,
  problems_ui                      int(1) NOT NULL default 0,
  facts_ui                         int(1) NOT NULL default 0,
  openshift                        int REFERENCES openshift (id),
  openshift_project_pattern        varchar(300),
  development_environments_limit   int DEFAULT NULL,
  created                          timestamp DEFAULT CURRENT_TIMESTAMP,
  private_key                      varchar(5000)
);

CREATE TABLE IF NOT EXISTS billing_modifier (
  id                              int NOT NULL auto_increment PRIMARY KEY,
  group_id                        varchar(36),
  weight                          int NOT NULL DEFAULT 0,
  start_date                      datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  end_date                        datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  discount_fixed                  DECIMAL NULL DEFAULT 0,
  discount_percentage             FLOAT NULL DEFAULT 0,
  extra_fixed                     DECIMAL NULL DEFAULT 0,
  extra_percentage                FLOAT NULL DEFAULT 0,
  min                             FLOAT NULL DEFAULT 0,
  max                             FLOAT NULL DEFAULT 0,
  customer_comments               text,
  admin_comments                  text
);

CREATE TABLE IF NOT EXISTS environment (
  id                     int NOT NULL auto_increment PRIMARY KEY,
  name                   varchar(100),
  project                int REFERENCES project (id),
  deploy_type            ENUM('branch', 'pullrequest', 'promote') NOT NULL,
  deploy_base_ref        varchar(100),
  deploy_head_ref        varchar(100),
  deploy_title           varchar(300),
  environment_type       ENUM('production', 'development') NOT NULL,
  auto_idle              int(1) NOT NULL default 1,
  openshift_project_name varchar(100),
  route                  varchar(300),
  routes                 text,
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

CREATE TABLE IF NOT EXISTS deployment (
  id           int NOT NULL auto_increment PRIMARY KEY,
  name         varchar(100) NOT NULL,
  status       ENUM('new', 'pending', 'running', 'cancelled', 'error', 'failed', 'complete') NOT NULL,
  created      datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started      datetime NULL,
  completed    datetime NULL,
  environment  int NOT NULL REFERENCES environment (id),
  remote_id    varchar(50) NULL
);

CREATE TABLE IF NOT EXISTS environment_backup (
  id                       int NOT NULL auto_increment PRIMARY KEY,
  environment              int REFERENCES environment (id),
  source                   varchar(300),
  backup_id                varchar(300),
  created                  timestamp,
  deleted                  timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  UNIQUE KEY `backup_id` (`backup_id`)
);

CREATE TABLE IF NOT EXISTS backup_restore (
  id                       int NOT NULL auto_increment PRIMARY KEY,
  backup_id                varchar(300),
  status                   ENUM('pending', 'successful', 'failed') DEFAULT 'pending',
  restore_location         varchar(300),
  created                  timestamp DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY `backup_id` (`backup_id`)
);

CREATE TABLE IF NOT EXISTS env_vars (
  id          int NOT NULL auto_increment PRIMARY KEY,
  name        varchar(300) NOT NULL,
  value       text NOT NULL,
  scope       ENUM('global', 'build', 'runtime', 'container_registry', 'internal_container_registry') NOT NULL DEFAULT 'global',
  project     int NULL REFERENCES project (id),
  environment int NULL REFERENCES environent (id),
  UNIQUE KEY `name_project` (`name`,`project`),
  UNIQUE KEY `name_environment` (`name`,`environment`)
);

CREATE TABLE IF NOT EXISTS environment_service (
  id          int NOT NULL auto_increment PRIMARY KEY,
  environment int NOT NULL REFERENCES environmnet (id),
  name        varchar(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS task (
  id           int NOT NULL auto_increment PRIMARY KEY,
  name         varchar(100) NOT NULL,
  environment  int NOT NULL REFERENCES environment (id),
  service      varchar(100) NOT NULL,
  command      varchar(300) NOT NULL,
  status       ENUM('active', 'succeeded', 'failed') NOT NULL,
  created      datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started      datetime NULL,
  completed    datetime NULL,
  remote_id    varchar(50) NULL
);

CREATE TABLE IF NOT EXISTS s3_file (
  id           int NOT NULL auto_increment PRIMARY KEY,
  filename     varchar(100) NOT NULL,
  s3_key       text NOT NULL,
  created      datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted      datetime NOT NULL DEFAULT '0000-00-00 00:00:00'
);

CREATE TABLE IF NOT EXISTS environment_problem (
  id                       int NOT NULL auto_increment PRIMARY KEY,
  environment              int REFERENCES environment (id),
  severity                 varchar(300) DEFAULT '',
  severity_score           DECIMAL(1,1) DEFAULT 0.0,
  identifier               varchar(300) NOT NULL,
  lagoon_service           varchar(300) DEFAULT '',
  source                   varchar(300) DEFAULT '',
  associated_package       varchar(300) DEFAULT '',
  description              TEXT NULL    DEFAULT '',
  version                  varchar(300) DEFAULT '',
  fixed_version            varchar(300) DEFAULT '',
  links                    varchar(300) DEFAULT '',
  data                     JSON,
  created                  timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted                  timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  UNIQUE(environment, lagoon_service, version, identifier, deleted)
);

CREATE TABLE IF NOT EXISTS problem_harbor_scan_matcher (
  id                              int NOT NULL auto_increment PRIMARY KEY,
  name                            varchar(100) NOT NULL,
  description                     text NULL,
  default_lagoon_project          varchar(300) NULL,
  default_lagoon_environment      varchar(300) NULL,
  default_lagoon_service_name     varchar(300) NULL,
  regex                           varchar(300) NOT NULL
);

-- Junction Tables

CREATE TABLE IF NOT EXISTS project_notification (
  nid      int,
  pid      int REFERENCES project (id),
  type     ENUM('slack','rocketchat','microsoftteams','email', 'webhook') NOT NULL,
  content_type ENUM('deployment', 'problem') NOT NULL,
  notification_severity_threshold int NOT NULL default 0,
  CONSTRAINT project_notification_pkey PRIMARY KEY (nid, pid, type)
);

CREATE TABLE IF NOT EXISTS user_ssh_key (
  usid int REFERENCES user (id),
  skid int REFERENCES ssh_key (id),
  CONSTRAINT user_ssh_key_pkey PRIMARY KEY (usid, skid)
);

CREATE TABLE IF NOT EXISTS customer_user (
  cid  int REFERENCES customer (id),
  usid int REFERENCES user (id),
  CONSTRAINT customer_user_pkey PRIMARY KEY (cid, usid)
);

CREATE TABLE IF NOT EXISTS project_user (
  pid int REFERENCES project (id),
  usid int REFERENCES user (id),
  CONSTRAINT project_user_pkey PRIMARY KEY (pid, usid)
);

CREATE TABLE IF NOT EXISTS task_file (
  tid int REFERENCES task (id),
  fid int REFERENCES file (id),
  CONSTRAINT task_file_pkey PRIMARY KEY (tid, fid)
);

CREATE TABLE IF NOT EXISTS environment_fact (
  id                       int NOT NULL auto_increment PRIMARY KEY,
  environment              int REFERENCES environment (id),
  name                     varchar(300) NOT NULL,
  value                    varchar(300) NOT NULL,
  type                     ENUM('TEXT', 'URL', 'SEMVER') DEFAULT 'TEXT',
  source                   varchar(300) DEFAULT '',
  description              TEXT NULL    DEFAULT '',
  created                  timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  category                 TEXT NULL    DEFAULT '',
  key_fact                 TINYINT(1) NOT NULL DEFAULT(0),
  UNIQUE(environment, name)
);

CREATE TABLE IF NOT EXISTS environment_fact_reference (
  id      int NOT NULL auto_increment PRIMARY KEY,
  fid     int NOT NULL REFERENCES environment_fact (id),
  name    varchar(300) NOT NULL,
  UNIQUE(fid, name)
);

CREATE TABLE IF NOT EXISTS notification_webhook (
  id          int NOT NULL auto_increment PRIMARY KEY,
  name        varchar(50) UNIQUE,
  webhook     varchar(2000)
);
