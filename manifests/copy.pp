# @summary Define one restic copy job (local T1 → remote T2/S3 offsite tier)
#
# Copies snapshots from a *source* `restic::repository` (the hourly, local T1
# tier) into a *destination* `restic::repository` (the daily, remote/S3 T2 tier)
# with `restic copy`. Because `copy` transfers already-packed blobs, the source
# data is NOT re-read or re-dumped — the database/etcd source is hit exactly
# once (by the T1 `restic::job`); the offsite tier is a cheap, deduplicated,
# still-encrypted copy.
#
# Three concerns, matching the module's SRP split:
#
# * **init** — the destination is created with `restic init --copy-chunker-params
#   --from-repo <source>` so its chunker parameters match the source. This is
#   MANDATORY: without it `copy` still works but deduplication between the two
#   repositories is lost, so every run re-uploads the full snapshot. Init is
#   idempotent (guarded by `restic cat config`). Because of this special init,
#   the destination `restic::repository` MUST be declared with `init => false`
#   (this type owns the destination's creation).
# * **copy** — `restic copy` from source → destination on a schedule, optionally
#   restricted to `$tags`.
# * **forget** — retention on the DESTINATION after each copy (default
#   `--keep-daily 5`). Pruning (space reclaim) is owned by the destination
#   `restic::repository` prune schedule, which shares the `/run/restic-<dest>.lock`
#   this job locks against.
#
# Both repositories keep their own 0600 env file (managed by
# `restic::repository`); this type reads the source repo's `RESTIC_REPOSITORY`
# and `RESTIC_PASSWORD` from that file at runtime and maps them onto restic's
# `RESTIC_FROM_*` — no credential is duplicated into a second file.
#
# @param source_repository  short name of the source (T1) `restic::repository`.
# @param dest_repository    short name of the destination (T2) `restic::repository`
#                           (declare it with `init => false`).
# @param tags               restrict the copy (and forget) to snapshots carrying
#                           these tags; undef = the whole repository.
# @param keep               destination retention policy, keyed by restic keep-*
#                           class (default: keep 5 daily).
# @param init               run the `--copy-chunker-params` init of the destination.
# @param schedule_provider  'cron' (native cron) or 'systemd_timer'.
# @param minute             cron minute (cron provider).
# @param hour               cron hour (cron provider).
# @param monthday           cron monthday (cron provider).
# @param month              cron month (cron provider).
# @param weekday            cron weekday (cron provider).
# @param crontab            whole `minute hour monthday month weekday` string;
#                           when set it overrides the discrete cron fields.
# @param user               cron user (cron provider).
# @param on_calendar        systemd OnCalendar (systemd_timer provider).
# @param enable             enable+start the copy timer (systemd_timer provider).
#
# @example CEM MariaDB T1 → offsite DR T2
#   restic::repository { 'mariadb':      # T1 (local)
#     repository => '/share/backups/restic/cem3/mariadb',
#     password   => $repo_password,
#   }
#   restic::repository { 'mariadb-dr':   # T2 (S3) — NOTE init => false
#     repository => 's3:https://content.cem.crytek.com/cem-prod-backup/cem3/mariadb',
#     password   => $repo_password,
#     env        => { 'AWS_ACCESS_KEY_ID' => $key, 'AWS_SECRET_ACCESS_KEY' => $secret },
#     init       => false,
#   }
#   restic::copy { 'mariadb-dr':
#     source_repository => 'mariadb',
#     dest_repository   => 'mariadb-dr',
#   }
define restic::copy (
  String[1]                     $source_repository,
  String[1]                     $dest_repository,
  Optional[Array[String[1]]]    $tags              = undef,
  Hash[Enum['last', 'hourly', 'daily', 'weekly', 'monthly', 'yearly'], Integer] $keep = {
    'daily' => 5,
  },
  Boolean                       $init              = true,
  Enum['cron', 'systemd_timer'] $schedule_provider = 'cron',
  String[1]                     $minute            = '30',
  String[1]                     $hour              = '3',
  String[1]                     $monthday          = '*',
  String[1]                     $month             = '*',
  String[1]                     $weekday           = '*',
  Optional[String[1]]           $crontab           = undef,
  String[1]                     $user              = 'root',
  String[1]                     $on_calendar       = '*-*-* 03:30:00',
  Boolean                       $enable            = true,
) {
  include restic

  $bin_dir     = $restic::bin_dir
  $config_dir  = $restic::config_dir
  $source_env  = "${config_dir}/${source_repository}.env"
  $dest_env    = "${config_dir}/${dest_repository}.env"
  $restic_run  = "${bin_dir}/restic-run"
  # Share the destination repository's lock so copy never overlaps its prune.
  $lockfile    = "/run/restic-${dest_repository}.lock"
  $script      = "${bin_dir}/copy-${title}.sh"

  $keep_flags = $keep.map |$rule, $count| { "--keep-${rule} ${count}" }
  $tag_flags  = $tags ? {
    undef   => [],
    default => $tags.map |$t| { "--tag '${t}'" },
  }
  $copy_flags   = $tag_flags
  $forget_flags = $keep_flags + $tag_flags

  # A whole crontab string overrides the discrete fields.
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
    content => epp('restic/copy.sh.epp', {
        source_envfile => $source_env,
        dest_envfile   => $dest_env,
        lockfile       => $lockfile,
        tag_label      => $title,
        copy_flags     => $copy_flags,
        forget_flags   => $forget_flags,
    }),
    require => [Restic::Repository[$source_repository], Restic::Repository[$dest_repository]],
  }

  if $init {
    # `restic cat config` on the destination succeeds only once the repo exists
    # with the right password: a safe idempotency guard for the chunker-params
    # init. The init itself runs through the same script (`init` action).
    exec { "restic-copy-init-${title}":
      command => "${script} init",
      unless  => "${restic_run} ${dest_env} cat config",
      require => File[$script],
    }
  }

  case $schedule_provider {
    'systemd_timer': {
      systemd::unit_file { "restic-copy-${title}.service":
        content => epp('restic/service.epp', {
            description => "restic copy (${title})",
            exec_start  => $script,
        }),
        require => File[$script],
      }

      systemd::unit_file { "restic-copy-${title}.timer":
        content => epp('restic/timer.epp', {
            description => "restic copy (${title})",
            on_calendar => $on_calendar,
        }),
        enable  => $enable,
        active  => $enable,
        require => Systemd::Unit_file["restic-copy-${title}.service"],
      }
    }
    default: {
      cron { "restic copy ${title}":
        command  => "${script} 2>&1 | /usr/bin/logger -t restic-copy-${title}",
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
