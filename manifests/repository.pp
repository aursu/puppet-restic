# @summary Define one restic repository (env file, init, prune schedule)
#
# Writes a 0600 environment file describing a single restic repository
# (`RESTIC_REPOSITORY` + `RESTIC_PASSWORD` + any backend env such as S3
# credentials), optionally initialises the repository, and installs a dedicated
# `prune` schedule. Prune is deliberately kept OUT of the per-run `forget` in
# `restic::job`: prune takes an exclusive repository lock and is expensive, so
# it runs once on its own schedule while each backup job only runs the cheap
# `forget`. A `flock` on `/run/restic-<title>.lock` serialises backup vs prune.
#
# The title is the repository's short name; the env file is
# `${restic::config_dir}/<title>.env` and jobs reference it by that same short
# name.
#
# @param repository         the RESTIC_REPOSITORY value (local path or s3:… URL).
# @param password           repository encryption password (loss = unrecoverable).
# @param env                extra backend env vars (e.g. AWS_ACCESS_KEY_ID); land
#                           in the 0600 env file.
# @param init               run `restic init` if the repository is not yet present.
# @param manage_directory   create the local repo's backing dir tree before init
#                           (no-op for remote s3: backends).
# @param cache_dir          optional RESTIC_CACHE_DIR.
# @param manage_prune       install the prune schedule for this repository.
# @param schedule_provider  'cron' (native cron) or 'systemd_timer'.
# @param prune_minute       prune cron minute (cron provider).
# @param prune_hour         prune cron hour (cron provider).
# @param prune_weekday      prune cron weekday (cron provider).
# @param prune_on_calendar  prune systemd OnCalendar (systemd_timer provider).
# @param enable             enable+start the prune timer (systemd_timer provider).
#
# @example
#   restic::repository { 'mariadb':
#     repository => '/share/backups/restic/cem3/mariadb',
#     password   => $repo_password,
#   }
define restic::repository (
  String[1]                           $repository,
  Variant[String[1], Sensitive[String[1]]] $password,
  Hash[String, String]                $env               = {},
  Boolean                             $init              = true,
  Boolean                             $manage_directory  = true,
  Optional[String[1]]                 $cache_dir         = undef,
  Boolean                             $manage_prune      = true,
  Enum['cron', 'systemd_timer']       $schedule_provider = 'cron',
  String[1]                           $prune_minute      = '20',
  String[1]                           $prune_hour        = '4',
  String[1]                           $prune_weekday     = '*',
  String[1]                           $prune_on_calendar = '*-*-* 04:20:00',
  Boolean                             $enable            = true,
) {
  include restic

  $config_dir = $restic::config_dir
  $bin_dir    = $restic::bin_dir
  $env_file   = "${config_dir}/${title}.env"
  $lockfile   = "/run/restic-${title}.lock"
  $restic_run = "${bin_dir}/restic-run"

  $pass = $password =~ Sensitive ? {
    true    => $password.unwrap,
    default => $password,
  }

  file { $env_file:
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    show_diff => false,
    content   => Sensitive(epp('restic/repository.env.epp', {
          repository => $repository,
          password   => $pass,
          env        => $env,
          cache_dir  => $cache_dir,
    })),
    require   => Class['restic'],
  }

  # For a local (file-based) repository, ensure the backing directory tree
  # exists before init. Remote backends (s3:, …) are not absolute paths.
  if $manage_directory and $repository =~ Stdlib::Absolutepath {
    $repo_parent = dirname($repository)

    exec { "restic-mkdir-${title}":
      command => "mkdir -p '${repo_parent}'",
      creates => $repo_parent,
      path    => ['/usr/bin', '/bin'],
    }

    file { $repository:
      ensure  => directory,
      owner   => 'root',
      group   => 'root',
      mode    => '0700',
      require => Exec["restic-mkdir-${title}"],
    }

    $init_require = [File[$env_file], File[$restic_run], File[$repository]]
  }
  else {
    $init_require = [File[$env_file], File[$restic_run]]
  }

  if $init {
    # Idempotency guard for init.
    #
    # For a LOCAL (file-based) repository, use the presence of the repo `config`
    # file as a deterministic marker. This is deliberately NOT `restic cat
    # config`: that guard opens the repository, which it shares with the running
    # backup jobs, so it can return non-zero *transiently* (a lock/IO race while a
    # backup is mid-write). A transient miss would then run `init` on an existing
    # repo, which hard-fails ("config file already exists") and cascades to skip
    # every job + copy that requires this repository. A filesystem check touches
    # neither restic nor a lock.
    #
    # A REMOTE (s3:, …) repository has no local path, so fall back to `restic cat
    # config` (which also verifies the password matches).
    if $repository =~ Stdlib::Absolutepath {
      exec { "restic-init-${title}":
        command => "${restic_run} ${env_file} init",
        creates => "${repository}/config",
        require => $init_require,
      }
    }
    else {
      exec { "restic-init-${title}":
        command => "${restic_run} ${env_file} init",
        unless  => "${restic_run} ${env_file} cat config",
        require => $init_require,
      }
    }
  }

  if $manage_prune {
    $prune_script = "${bin_dir}/restic-${title}-prune.sh"

    file { $prune_script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0750',
      content => epp('restic/prune.sh.epp', {
          restic_run   => $restic_run,
          repo_envfile => $env_file,
          lockfile     => $lockfile,
      }),
      require => File[$env_file],
    }

    case $schedule_provider {
      'systemd_timer': {
        systemd::unit_file { "restic-prune-${title}.service":
          content => epp('restic/service.epp', {
              description => "restic repository prune (${title})",
              exec_start  => $prune_script,
          }),
          require => File[$prune_script],
        }

        systemd::unit_file { "restic-prune-${title}.timer":
          content => epp('restic/timer.epp', {
              description => "restic repository prune (${title})",
              on_calendar => $prune_on_calendar,
          }),
          enable  => $enable,
          active  => $enable,
          require => Systemd::Unit_file["restic-prune-${title}.service"],
        }
      }
      default: {
        cron { "restic prune ${title}":
          command => "${prune_script} 2>&1 | /usr/bin/logger -t restic-prune-${title}",
          user    => 'root',
          minute  => $prune_minute,
          hour    => $prune_hour,
          weekday => $prune_weekday,
          require => File[$prune_script],
        }
      }
    }
  }
}
