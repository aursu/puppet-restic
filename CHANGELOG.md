# Changelog

All notable changes to this project will be documented in this file.

## Release 0.4.0

**Features**

* Added `restic::metrics`: a systemd timer (every 15 minutes) runs `restic-metrics`, which lists
  the snapshots of every repository (`restic snapshots --json --no-lock` through `restic-run`)
  and writes the node_exporter textfile `restic.prom`: whether the repository could be read, the
  number of snapshots, the time of the newest snapshot per repository and per tag, and the read
  duration. A backup or an off-site copy that stopped running can now be alerted on; before, the
  jobs only wrote to syslog. Python 3.7 or later; node_exporter itself is not managed.

## Release 0.3.0

**Bugfixes**

* The `archive` install method fetched the restic binary from the upstream GitHub release with no `checksum`, `checksum_type` or `checksum_url`, so `puppet/archive` performed no integrity verification whatsoever: whatever the endpoint returned was decompressed and installed as a root-owned executable in `/usr/local/bin` on every managed host. A truncated download, a corrupted cache or a substituted asset would all have been installed silently. The download is now verified against a pinned SHA-256 digest, and the class **fails rather than installing an unverified binary** when no digest is known for the requested version and architecture.

**Features**

* Added `restic::checksum` (explicit digest, overrides the lookup), `restic::checksums` (known-good digests keyed by release asset filename) and `restic::checksum_type` (default `sha256`). Digests for the pinned default version 0.19.1, `linux_amd64` and `linux_arm64`, ship in the module's data, so `include restic` needs no additional configuration. Bumping `restic::version` now requires adding the matching digests - that is deliberate, and it is what makes the pin a pin.

## Release 0.2.2

**Bugfixes**

* The `restic-run` wrapper and the `restic::copy` script now default `RESTIC_CACHE_DIR` to `/var/cache/restic` (overridable via the repo env file / `restic::repository`'s `cache_dir`). restic requires a cache directory for remote (S3) backends; when run from a Puppet `exec` there is no `$HOME`/`$XDG_CACHE_HOME`, so `restic::copy`'s init/copy against an S3 destination aborted with `unable to locate cache directory`. Local-only backups were unaffected.

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
