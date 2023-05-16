# mariabackup.sh
Shell script to create full/incremental backups with mariabackup

## Backup

```bash
> ./mariabackup.sh backup -h

Usage: mariabackup.sh [options] backup [<args>]

Create full/incremental backups with mariabackup

args:
  --full                  full backup
  --incr                  incremental backup (on top of most recent full backup)

options:
  -h, --help              show this help message and exit
  -v, --version           show program's version number and exit
  -d, --debug             show debug messages
  --loglevel LOGLEVEL, -l LOGLEVEL
                          level of log messages to capture (one of debug, info, warn, error). Default:
                          info
  mariadb connection options
  --host                  mysql hostname. Default:
                              'MYSQL_HOST' env variable used by default, 'localhost' used if not set
  --port                  mysql port. Default:
                              'MYSQL_PORT' env variable used by default, '3306' used if not set
  --user                  mysql user. Default:
                              'MYSQL_USER' env variable used by default, 'root' used if not set
  --password              mysql password. Default: 'MYSQL_PASSWORD' env variable
```


### Create backup user

```sql
-- See https://mariadb.com/kb/en/mariabackup-overview/#authentication-and-privileges
CREATE USER 'backup'@'%' IDENTIFIED BY 'YourPassword';

-- MariaDB < 10.5:
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'%';
-- MariaDB >= 10.5:
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'backup'@'%';

FLUSH PRIVILEGES;
```

### Backup folder structure

```bash
/backup/
├── <full_1>/
│   ├── backup.mb.xz
│   ├── xtrabackup_checkpoints
│   ├── xtrabackup_info
│   ├── <incr_1>/
│   │   └── backup.mb.xz
│   .
│   └── <incr_n>/
│       └── backup.mb.xz
.
└── <full_n>/
```

The backup folder names have the following format:

```bash
<year>-<month>-<day>_<hour>-<minute>-<second>
```

## Restore

```bash
>./mariabackup.sh restore -h
Usage: mariabackup.sh [options] restore [<args>]

Restore a backup with mariabackup

args:
  --name                  backup name. Default: the most recent one if not specified

options:
  -h, --help              show this help message and exit
  -v, --version           show program's version number and exit
  -d, --debug             show debug messages
  --loglevel LOGLEVEL, -l LOGLEVEL
                          level of log messages to capture (one of debug, info, warn, error). Default:
                          info
  mariadb connection options
  --host                  mysql hostname. Default:
                              'MYSQL_HOST' env variable used by default, 'localhost' used if not set
  --port                  mysql port. Default:
                              'MYSQL_PORT' env variable used by default, '3306' used if not set
  --user                  mysql user. Default:
                              'MYSQL_USER' env variable used by default, 'root' used if not set
  --password              mysql password. Default: 'MYSQL_PASSWORD' env variable
```


## Environment variable configuration

- `MYSQL_HOST`: 
- `MYSQL_PORT`: 
- `MYSQL_USER`: 
- `MYSQL_PASSWORD`: 
- `MYSQL_BACKUP_ROOT`: backup root path, default: `/backup`
- `MYSQL_BACKUP_THREADS`: number of threads to use for parallel data file transfer
- `MYSQL_BACKUP_COMPRESS`: whether to enable backup compression (.xz format)
- `MYSQL_BACKUP_KEEP_DAYS`: maximum age of full backups
- `MYSQL_BACKUP_KEEP_N`: maximum number of full backups
- `MYSQL_BACKUP_LOG_LEVEL`: log level, one of debug, info, warn, error
