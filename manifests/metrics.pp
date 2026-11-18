# @summary Export the freshness of restic repositories as node_exporter textfile metrics
#
# Installs `restic-metrics` and a systemd timer that, every 15 minutes by default, lists the
# snapshots of each repository (`restic snapshots --json --no-lock` through `restic-run`) and
# writes one metrics file for the node_exporter textfile collector:
#
# * `restic_repository_up{repository}` - 1 if the snapshot list could be read
# * `restic_repository_snapshots{repository}`
# * `restic_repository_latest_snapshot_timestamp_seconds{repository}`
# * `restic_tag_latest_snapshot_timestamp_seconds{repository,tag}`
# * `restic_repository_read_duration_seconds{repository}`
# * `restic_metrics_collector_timestamp_seconds`
#
# `repository` is the name of the `restic::repository` (its env file in `restic::config_dir`).
# `restic copy` keeps the original snapshot time, so the latest snapshot of an off-site copy shows
# when the copied backup was taken - an alert on "older than N hours" covers the copy as well.
#
# The module does not manage node_exporter: `textfile_directory` must exist (node_exporter's
# textfile collector directory). Needs Python 3.7 or later (`python`).
#
# @param ensure
#   `absent` removes the timer, the service, the script and the metrics file.
# @param textfile_directory
#   Directory read by the node_exporter textfile collector.
# @param filename
#   Name of the metrics file in `textfile_directory`.
# @param repositories
#   Repository names to read. Empty: every `*.env` in `restic::config_dir`.
# @param on_calendar
#   systemd OnCalendar of the collector.
# @param timeout
#   Seconds allowed per repository before it is reported as not readable.
# @param python
#   Python 3 interpreter.
#
# @example
#   include restic::metrics
#
class restic::metrics (
  Enum['present', 'absent'] $ensure             = 'present',
  Stdlib::Absolutepath      $textfile_directory = '/var/lib/node_exporter/textfile',
  Pattern[/\A[^\/]+\.prom\z/] $filename         = 'restic.prom',
  Array[String[1]]          $repositories       = [],
  String[1]                 $on_calendar        = '*:0/15',
  Integer[1]                $timeout            = 300,
  Stdlib::Absolutepath      $python             = '/usr/bin/python3',
) {
  include restic

  $script = "${restic::bin_dir}/restic-metrics"
  $output = "${textfile_directory}/${filename}"
  $repository_args = $repositories.map |$name| { "--repository ${name}" }
  $exec_start = join([
      $python,
      $script,
      "--output ${output}",
      "--config-dir ${restic::config_dir}",
      "--runner ${restic::bin_dir}/restic-run",
      "--timeout ${timeout}",
  ] + $repository_args, ' ')

  if $ensure == 'present' {
    file { $script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0750',
      content => file('restic/restic_metrics.py'),
      require => File[$restic::bin_dir],
    }

    systemd::unit_file { 'restic-metrics.service':
      content => epp('restic/service.epp', {
          description => 'restic repository freshness metrics',
          exec_start  => $exec_start,
      }),
      require => File[$script],
    }

    systemd::unit_file { 'restic-metrics.timer':
      content => epp('restic/timer.epp', {
          description => 'restic repository freshness metrics',
          on_calendar => $on_calendar,
      }),
      enable  => true,
      active  => true,
      require => Systemd::Unit_file['restic-metrics.service'],
    }
  }
  else {
    systemd::unit_file { 'restic-metrics.timer':
      ensure => absent,
      enable => false,
      active => false,
    }

    systemd::unit_file { 'restic-metrics.service':
      ensure  => absent,
      require => Systemd::Unit_file['restic-metrics.timer'],
    }

    file { [$script, $output]:
      ensure => absent,
    }
  }
}
