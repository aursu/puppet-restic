# @summary Install the restic backup client
#
# Installs restic and creates the shared directories used by
# `restic::repository` (env files) and `restic::job` (wrapper scripts). This
# class knows only about restic itself — it holds no knowledge of databases,
# etcd or any specific workload (SRP).
#
# Default install method is `archive` (a pinned single binary from the upstream
# GitHub release). This guarantees a uniform, modern restic (>= 0.16, needed for
# `--stdin-from-command` and repo-v2 zstd/compression) across a mixed
# Ubuntu/Rocky estate, where distro packages lag badly (Ubuntu 22.04 ships
# 0.12.1). Set `install_method` to `package` on hosts whose distro provides a
# new-enough restic.
#
# @param install_method  'archive' (pinned binary) or 'package'.
# @param version         restic version for the archive install method.
# @param package_ensure  ensure value when install_method is 'package'.
# @param package_name    package name when install_method is 'package'.
# @param config_dir      directory holding per-repository env files (0700).
# @param bin_dir         directory holding generated wrapper scripts (0750).
#
# @example
#   include restic
class restic (
  Enum['archive', 'package'] $install_method = 'archive',
  String[1]                  $version        = '0.19.1',
  String[1]                  $package_ensure = 'installed',
  String[1]                  $package_name   = 'restic',
  Stdlib::Absolutepath       $config_dir     = '/etc/restic',
  Stdlib::Absolutepath       $bin_dir        = '/opt/backup',
) {
  # 0700: env files carry the repository password + backend keys.
  file { $config_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  file { $bin_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
  }

  # Shared runner: `restic-run <repo-env-file> <restic-args…>` sources the
  # repository env file then execs restic. Used by init/cat-config, prune and
  # backup jobs so the env-sourcing lives in exactly one place.
  file { "${bin_dir}/restic-run":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0750',
    content => file('restic/restic-run'),
    require => File[$bin_dir],
  }

  case $install_method {
    'archive': {
      $arch = $facts['os']['architecture'] ? {
        'aarch64' => 'arm64',
        'arm64'   => 'arm64',
        default   => 'amd64',
      }
      $asset  = "restic_${version}_linux_${arch}.bz2"
      $tmp    = "/tmp/${asset}"
      $target = "/usr/local/bin/restic-${version}"

      archive { "restic-${version}":
        path    => $tmp,
        source  => "https://github.com/restic/restic/releases/download/v${version}/${asset}",
        extract => false,
        creates => $target,
        cleanup => false,
      }

      exec { "restic-install-${version}":
        command => "bunzip2 -kfc ${tmp} > ${target} && chmod 0755 ${target}",
        creates => $target,
        path    => ['/usr/bin', '/bin', '/usr/local/bin'],
        require => Archive["restic-${version}"],
      }

      file { '/usr/local/bin/restic':
        ensure  => link,
        target  => $target,
        require => Exec["restic-install-${version}"],
      }
    }
    'package': {
      package { 'restic':
        ensure => $package_ensure,
        name   => $package_name,
      }
    }
    default: {}
  }
}
