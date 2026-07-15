# Changelog

All notable changes to this project will be documented in this file.

## Release 0.2.1

**Bugfixes**

* `restic::repository` now guards `init` on a **local** (file-based) repository with a `creates => "<repository>/config"` filesystem check instead of `unless => restic cat config`. The `cat config` guard opens the repository, which is shared with running backup jobs, so it could return non-zero *transiently* (a lock/IO race while a backup was mid-write); that transient miss then ran `init` on the existing repo, which hard-fails with `config file already exists` and cascades to skip every dependent job and copy. The filesystem marker touches neither restic nor a lock. Remote (`s3:`) repositories have no local path and keep the `cat config` guard.

## Release 0.2.0

**Features**

* Added `restic::copy` defined type — copies snapshots from a local (T1) `restic::repository` into a remote/S3 (T2) `restic::repository` with `restic copy`, for a deduplicated, still-encrypted offsite tier without re-reading the source. Inits the destination with `--copy-chunker-params` (idempotent, guarded by `restic cat config`) so cross-repository deduplication is preserved, runs the copy on a cron or systemd-timer schedule, and applies destination retention via `forget` (default `--keep-daily 5`). Reads the source repository's `RESTIC_REPOSITORY`/`RESTIC_PASSWORD` from its own env file and maps them onto `RESTIC_FROM_*` (no credential duplicated). Shares the destination repository's `/run/restic-<dest>.lock` so copy never overlaps its prune.

## Release 0.1.0

**Features**

* Added `restic` class to install the restic backup client (pinned binary via puppet-archive by default, or distro package) and a shared `restic-run` runner wrapper
* Added `restic::repository` defined type — encrypted repository env file, idempotent `restic init`, local backing-directory management, and a dedicated `prune` schedule (cron or systemd timer)
* Added `restic::job` defined type — backup jobs in stdin mode (`restic backup --stdin-from-command` for dumps) or path mode (`restic backup <paths>` for existing files), with optional `pre_command`/`post_command` hooks, per-tag `forget`, and a cron or systemd-timer schedule
* Extracted from `aursu/lsys` (`lsys::restic*`) and `aursu/kubeinstall` (`kubeinstall::restic`) into a single dedicated, company-agnostic module
