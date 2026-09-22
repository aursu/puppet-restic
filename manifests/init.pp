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
# The archive method fetches a binary over the network and installs it as a
# root-owned executable, so the download is verified against a pinned digest.
# `puppet/archive` verifies only when a checksum is supplied; with none it
# accepts whatever the endpoint returns. A version with no known digest is a
# hard failure rather than an unverified install.
#
# @param install_method  'archive' (pinned binary) or 'package'.
# @param version         restic version for the archive install method.
# @param checksum        digest of the release asset, for the archive install
#                        method. Overrides the lookup in $checksums.
# @param checksums       known-good digests keyed by release asset filename,
#                        e.g. 'restic_0.19.1_linux_amd64.bz2'. Shipped in the
#                        module data for the pinned default version.
# @param checksum_type   digest algorithm for $checksum / $checksums.
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
  Optional[String[1]]        $checksum       = undef,
  Hash[String[1], String[1]] $checksums      = {},
  Enum['md5', 'sha1', 'sha256', 'sha384', 'sha512'] $checksum_type = 'sha256',
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

      # An explicit checksum wins; otherwise the digest must be known for this
      # exact asset. No digest means no install - see the class documentation.
      if $checksum {
        $asset_checksum = $checksum
      }
      else {
        $asset_checksum = $checksums[$asset]
      }

      unless $asset_checksum {
        $err_what = "restic: no ${checksum_type} digest known for ${asset}."
        $err_fix  = 'Add it to restic::checksums, or set restic::checksum.'
        fail("${err_what} ${err_fix} Refusing to install an unverified binary.")
      }

      archive { "restic-${version}":
        path            => $tmp,
        source          => "https://github.com/restic/restic/releases/download/v${version}/${asset}",
        extract         => false,
        creates         => $target,
        cleanup         => false,
        checksum        => $asset_checksum,
        checksum_type   => $checksum_type,
        checksum_verify => true,
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
