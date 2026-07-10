# @summary Define one restic backup job (optional pre → backup → forget → cleanup)
#
# Generates a wrapper script and a schedule (cron or systemd timer) for a single
# backup job writing into a `restic::repository`. Two source modes:
#
# * **stdin mode** (`$command`): restic runs the dump command itself via
#   `restic backup --stdin-from-command -- <argv>` (restic >= 0.16). A non-zero
#   dump ABORTS the snapshot, so a failed/partial dump never becomes a
#   "successful" backup (this is why the raw `dump | restic backup --stdin` pipe
#   is avoided). Used for database dumps.
# * **path mode** (`$paths`): `restic backup <paths>` — backs up existing files
#   (e.g. an etcd snapshot already written to disk).
#
# Optional hooks wrap the backup:
#
# * `$pre_command` runs BEFORE the backup under `set -e`; its failure aborts the
#   job (no snapshot). Use it to produce the file(s) named in `$paths`.
# * `$post_command` is registered as a `trap … EXIT`, so it runs on ANY exit
#   (success or failure) AFTER the pre hook is set up — i.e. cleanup semantics.
#   Use it to remove transient files created by `$pre_command`.
#
# After a successful backup the job runs `restic forget` scoped to this job's
# tag (per-workload retention). Pruning is handled separately by the owning
# `restic::repository` (single lock owner).
#
# @param repository         short name of the target `restic::repository`.
# @param command            stdin mode: argv of the dump command (NOT a shell
#                           string), passed to restic after `--`. Mutually
#                           exclusive with `$paths`.
# @param stdin_filename     stdin mode: virtual filename recorded in the snapshot.
# @param paths              path mode: files/directories to back up. Mutually
#                           exclusive with `$command`.
# @param pre_command        shell run before the backup (failure aborts).
# @param post_command       shell run on exit via `trap` (cleanup semantics).
# @param snapshot_tag       restic tag for this job (default: the resource title).
# @param keep               forget retention policy, keyed by restic keep-* class.
# @param schedule_provider  'cron' (native cron) or 'systemd_timer'.
# @param minute             cron minute (cron provider).
# @param hour               cron hour (cron provider).
# @param monthday           cron monthday (cron provider).
# @param month              cron month (cron provider).
# @param weekday            cron weekday (cron provider).
# @param crontab            whole `minute hour monthday month weekday` string;
#                           when set it overrides the discrete cron fields.
# @param user               cron user (must reach the source creds/socket).
# @param on_calendar        systemd OnCalendar (systemd_timer provider).
# @param enable             enable+start the backup timer (systemd_timer provider).
#
# @example stdin (database dump)
#   restic::job { 'cem_www_prod':
#     repository     => 'mariadb',
#     command        => ['/usr/bin/mariadb-dump', '--single-transaction', 'cem_www_prod'],
#     stdin_filename => 'cem_www_prod.sql',
#     crontab        => '55 * * * *',
#   }
#
# @example path with pre/post (etcd snapshot)
#   restic::job { 'etcd':
#     repository        => 'etcd',
#     paths             => ['/var/backups/etcd/etcd-snapshot.db'],
#     pre_command       => '/opt/backup/etcd-snapshot.sh /var/backups/etcd/etcd-snapshot.db',
#     post_command      => "rm -f '/var/backups/etcd/etcd-snapshot.db'",
#     schedule_provider => 'systemd_timer',
#   }
define restic::job (
  String[1]                                  $repository,
  Optional[Array[String[1]]]                 $command           = undef,
  Optional[String[1]]                        $stdin_filename    = undef,
  Optional[Array[String[1]]]                 $paths             = undef,
  Optional[String[1]]                        $pre_command       = undef,
  Optional[String[1]]                        $post_command      = undef,
  String[1]                                  $snapshot_tag      = $title,
  Hash[Enum['last', 'hourly', 'daily', 'weekly', 'monthly', 'yearly'], Integer] $keep = {
    'hourly' => 24,
    'daily'  => 7,
  },
  Enum['cron', 'systemd_timer']              $schedule_provider = 'cron',
  String[1]                                  $minute            = '0',
  String[1]                                  $hour              = '*',
  String[1]                                  $monthday          = '*',
  String[1]                                  $month             = '*',
  String[1]                                  $weekday           = '*',
  Optional[String[1]]                        $crontab           = undef,
  String[1]                                  $user              = 'root',
  String[1]                                  $on_calendar       = '*-*-* 03:00:00',
  Boolean                                    $enable            = true,
) {
  include restic

  $bin_dir    = $restic::bin_dir
  $env_file   = "${restic::config_dir}/${repository}.env"
  $lockfile   = "/run/restic-${repository}.lock"
  $script     = "${bin_dir}/backup-${title}.sh"
  $restic_run = "${bin_dir}/restic-run"

  # Exactly one of stdin mode ($command) or path mode ($paths).
  $stdin_mode = $command =~ Array[String]
  $path_mode  = $paths =~ Array[String]
  if $stdin_mode == $path_mode {
    fail("restic::job[${title}] requires exactly one of \$command (stdin mode) or \$paths (path mode)")
  }
  if $stdin_mode and !$stdin_filename {
    fail("restic::job[${title}] stdin mode requires \$stdin_filename")
  }
  $mode = $stdin_mode ? {
    true    => 'stdin',
    default => 'path',
  }

  $forget_flags = $keep.map |$rule, $count| { "--keep-${rule} ${count}" }

  # A whole crontab string (as commonly stored in Hiera) overrides the discrete
  # fields: `minute hour monthday month weekday`.
  if $crontab =~ String {
    $fields        = split($crontab, /\s+/)
    $cron_minute   = $fields[0]
    $cron_hour     = $fields[1]
    $cron_monthday = $fields[2]
    $cron_month    = $fields[3]
    $cron_weekday  = $fields[4]
  }
  else {
    $cron_minute   = $minute
    $cron_hour     = $hour
    $cron_monthday = $monthday
    $cron_month    = $month
    $cron_weekday  = $weekday
  }

  file { $script:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0750',
    content => epp('restic/job.sh.epp', {
        restic_run     => $restic_run,
        repo_envfile   => $env_file,
        mode           => $mode,
        command        => pick($command, []),
        stdin_filename => pick($stdin_filename, ''),
        paths          => pick($paths, []),
        pre_command    => $pre_command,
        post_command   => $post_command,
        tag            => $snapshot_tag,
        lockfile       => $lockfile,
        forget_flags   => $forget_flags,
    }),
    require => Restic::Repository[$repository],
  }

  case $schedule_provider {
    'systemd_timer': {
      systemd::unit_file { "restic-backup-${title}.service":
        content => epp('restic/service.epp', {
            description => "restic backup (${title})",
            exec_start  => $script,
        }),
        require => File[$script],
      }

      systemd::unit_file { "restic-backup-${title}.timer":
        content => epp('restic/timer.epp', {
            description => "restic backup (${title})",
            on_calendar => $on_calendar,
        }),
        enable  => $enable,
        active  => $enable,
        require => Systemd::Unit_file["restic-backup-${title}.service"],
      }
    }
    default: {
      cron { "restic backup ${title}":
        command  => "${script} 2>&1 | /usr/bin/logger -t restic-backup-${title}",
        user     => $user,
        minute   => $cron_minute,
        hour     => $cron_hour,
        monthday => $cron_monthday,
        month    => $cron_month,
        weekday  => $cron_weekday,
        require  => File[$script],
      }
    }
  }
}
