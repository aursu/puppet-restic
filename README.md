# restic

Install [restic](https://restic.net/) and manage encrypted backup repositories
and backup jobs with Puppet.

## Table of Contents

1. [Description](#description)
1. [Usage](#usage)
1. [Reference](#reference)
1. [Limitations](#limitations)

## Description

This module owns the generic, reusable restic mechanics:

* **`restic`** — installs restic (a pinned single binary from the upstream
  GitHub release by default, or a distro package) and installs the shared
  `restic-run` wrapper (`restic-run <repo-env-file> <restic-args…>` sources the
  repository env file then execs restic).
* **`restic::repository`** — writes a `0600` repository environment file
  (`RESTIC_REPOSITORY` / `RESTIC_PASSWORD` + any backend env), optionally runs
  an idempotent `restic init`, manages the local backing directory for
  file-based repositories, and installs a dedicated `prune` schedule.
* **`restic::job`** — a single backup job. Either **stdin mode** (restic runs a
  dump command itself via `--stdin-from-command`, so a failed dump aborts the
  snapshot) or **path mode** (`restic backup <paths>`), with optional
  `pre_command` / `post_command` (cleanup) hooks, per-tag `forget`, and a cron
  or systemd-timer schedule.
* **`restic::copy`** — copies snapshots from a local (T1) repository into a
  remote/S3 (T2) repository with `restic copy` for an offsite tier. The source
  data is not re-read; the destination is a deduplicated, still-encrypted copy.
  It inits the destination with `--copy-chunker-params` (so cross-repo dedup
  works), runs `restic copy` on a schedule, and applies destination retention
  via `forget`.

Prune is intentionally separate from each job's `forget`: prune takes an
exclusive, expensive repository lock, so it runs once on its own schedule while
each job runs only the cheap per-tag `forget`. A `flock` on
`/run/restic-<repo>.lock` serialises backup vs prune.

This module is **company-agnostic**: all site-specific values (repository
paths, credentials, schedules, backend endpoints) are parameters, supplied by
the consuming profile/Hiera.

## Usage

### Database dump (stdin mode, cron)

```puppet
include restic

restic::repository { 'mariadb':
  repository => '/share/backups/restic/db01/mariadb',
  password   => $repo_password,
}

restic::job { 'app_prod':
  repository     => 'mariadb',
  command        => ['/usr/bin/mariadb-dump', '--single-transaction', 'app_prod'],
  stdin_filename => 'app_prod.sql',
  crontab        => '55 * * * *',
}
```

### File snapshot with pre/post hooks (path mode, systemd timer)

```puppet
restic::repository { 'etcd':
  repository        => '/var/backups/etcd/restic',
  password          => $repo_password,
  schedule_provider => 'systemd_timer',
}

restic::job { 'etcd':
  repository        => 'etcd',
  paths             => ['/var/backups/etcd/etcd-snapshot.db'],
  pre_command       => '/opt/backup/etcd-snapshot.sh /var/backups/etcd/etcd-snapshot.db',
  post_command      => "rm -f '/var/backups/etcd/etcd-snapshot.db'",
  schedule_provider => 'systemd_timer',
}
```

### Offsite copy (two-tier: local T1 → S3 T2)

The source data is dumped once into a local `restic::repository` (T1); a daily
`restic::copy` mirrors it into a remote/S3 `restic::repository` (T2). The
destination repository is declared with `init => false` — `restic::copy` owns
its creation so it can init with `--copy-chunker-params`.

```puppet
restic::repository { 'mariadb':                       # T1 (local, hourly source)
  repository => '/share/backups/restic/db01/mariadb',
  password   => $repo_password,
}

restic::repository { 'mariadb-dr':                    # T2 (S3) — NOTE init => false
  repository => 's3:https://s3.example.com/prod-backup/db01/mariadb',
  password   => $repo_password,
  env        => {
    'AWS_ACCESS_KEY_ID'     => $key_id,
    'AWS_SECRET_ACCESS_KEY' => $secret,
  },
  init       => false,
}

restic::copy { 'mariadb-dr':
  source_repository => 'mariadb',
  dest_repository   => 'mariadb-dr',
  # keep => { 'daily' => 5 } is the default
}
```

## Reference

See the in-manifest `@param` documentation on `restic`, `restic::repository`,
`restic::job` and `restic::copy`.

## Limitations

Targets systemd-based Linux (Rocky, Ubuntu). The `archive` install method
requires `bunzip2` (bzip2) on the target.
