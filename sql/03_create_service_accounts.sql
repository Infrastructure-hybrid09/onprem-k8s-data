-- Run on the current writable Primary.
-- Replace every <..._PASSWORD> placeholder before execution.
-- Never commit the populated file.

CREATE USER IF NOT EXISTS 'ir_app'@'192.168.44.21'
  IDENTIFIED BY '<APP_PASSWORD>';
GRANT SELECT, INSERT, UPDATE, DELETE
  ON infraready.* TO 'ir_app'@'192.168.44.21';

-- Failover 검증용 DB를 유지하는 경우에만 부여합니다.
GRANT SELECT, INSERT, UPDATE, DELETE
  ON infraready_smoke.* TO 'ir_app'@'192.168.44.21';

CREATE USER IF NOT EXISTS 'ir_repl'@'192.168.44.51'
  IDENTIFIED BY '<REPLICATION_PASSWORD>';
GRANT REPLICATION SLAVE ON *.*
  TO 'ir_repl'@'192.168.44.51';

CREATE USER IF NOT EXISTS 'ir_repl'@'192.168.44.52'
  IDENTIFIED BY '<REPLICATION_PASSWORD>';
GRANT REPLICATION SLAVE ON *.*
  TO 'ir_repl'@'192.168.44.52';

CREATE USER IF NOT EXISTS 'mxs_mon'@'192.168.44.21'
  IDENTIFIED BY '<MONITOR_PASSWORD>';
GRANT RELOAD, PROCESS, SHOW DATABASES, EVENT, SET USER,
  CONNECTION ADMIN, READ_ONLY ADMIN, REPLICATION SLAVE ADMIN,
  BINLOG ADMIN, SLAVE MONITOR ON *.*
  TO 'mxs_mon'@'192.168.44.21';
GRANT SELECT ON mysql.user
  TO 'mxs_mon'@'192.168.44.21';
GRANT SELECT ON mysql.global_priv
  TO 'mxs_mon'@'192.168.44.21';

CREATE USER IF NOT EXISTS 'mxs_route'@'192.168.44.21'
  IDENTIFIED BY '<ROUTE_PASSWORD>';
GRANT SELECT ON mysql.user TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.db TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.tables_priv TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.columns_priv TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.procs_priv TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.proxies_priv TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.global_priv TO 'mxs_route'@'192.168.44.21';
GRANT SELECT ON mysql.roles_mapping TO 'mxs_route'@'192.168.44.21';
GRANT SHOW DATABASES ON *.* TO 'mxs_route'@'192.168.44.21';

CREATE USER IF NOT EXISTS 'ir_exporter'@'localhost'
  IDENTIFIED BY '<EXPORTER_PASSWORD>';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.*
  TO 'ir_exporter'@'localhost';

CREATE USER IF NOT EXISTS 'ir_backup'@'localhost'
  IDENTIFIED BY '<BACKUP_PASSWORD>';
GRANT RELOAD, PROCESS, SLAVE MONITOR ON *.*
  TO 'ir_backup'@'localhost';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER
  ON infraready.* TO 'ir_backup'@'localhost';

FLUSH PRIVILEGES;

