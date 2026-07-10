# Changelog

All notable changes to this project will be documented in this file.

## Release 0.1.0

**Features**

* Added `restic` class to install the restic backup client (pinned binary via puppet-archive by default, or distro package) and a shared `restic-run` runner wrapper
* Added `restic::repository` defined type — encrypted repository env file, idempotent `restic init`, local backing-directory management, and a dedicated `prune` schedule (cron or systemd timer)
* Added `restic::job` defined type — backup jobs in stdin mode (`restic backup --stdin-from-command` for dumps) or path mode (`restic backup <paths>` for existing files), with optional `pre_command`/`post_command` hooks, per-tag `forget`, and a cron or systemd-timer schedule
* Extracted from `aursu/lsys` (`lsys::restic*`) and `aursu/kubeinstall` (`kubeinstall::restic`) into a single dedicated, company-agnostic module
