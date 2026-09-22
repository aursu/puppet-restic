# frozen_string_literal: true

require 'spec_helper'

describe 'restic' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with default parameters (archive install)' do
        it { is_expected.to compile.with_all_deps }

        it { is_expected.to contain_class('restic') }

        it {
          is_expected.to contain_file('/etc/restic')
            .with(ensure: 'directory', owner: 'root', group: 'root', mode: '0700')
        }

        it {
          is_expected.to contain_file('/opt/backup')
            .with(ensure: 'directory', owner: 'root', group: 'root', mode: '0750')
        }

        it {
          is_expected.to contain_file('/opt/backup/restic-run')
            .with(ensure: 'file', mode: '0750')
            .that_requires('File[/opt/backup]')
        }

        it { is_expected.to contain_file('/opt/backup/restic-run').with_content(%r{exec restic "\$@"}) }
        it { is_expected.to contain_file('/opt/backup/restic-run').with_content(%r{RESTIC_CACHE_DIR="\$\{RESTIC_CACHE_DIR:-/var/cache/restic\}"}) }

        it {
          is_expected.to contain_archive('restic-0.19.1')
            .with(source: %r{restic/releases/download/v0.19.1/restic_0.19.1_linux_amd64.bz2})
            .with(extract: false)
        }

        # The digest comes from the module's own data, so an unconfigured
        # `include restic` still verifies what it downloads.
        it {
          is_expected.to contain_archive('restic-0.19.1')
            .with(checksum: 'f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c')
            .with(checksum_type: 'sha256')
            .with(checksum_verify: true)
        }

        it { is_expected.to contain_exec('restic-install-0.19.1').that_requires('Archive[restic-0.19.1]') }

        it {
          is_expected.to contain_file('/usr/local/bin/restic')
            .with(ensure: 'link', target: '/usr/local/bin/restic-0.19.1')
            .that_requires('Exec[restic-install-0.19.1]')
        }

        it { is_expected.not_to contain_package('restic') }
      end

      context 'with a custom version and an explicit checksum' do
        let(:params) { { 'version' => '0.18.0', 'checksum' => 'a' * 64 } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_archive('restic-0.18.0').with_checksum('a' * 64) }
        it { is_expected.to contain_file('/usr/local/bin/restic').with_target('/usr/local/bin/restic-0.18.0') }
      end

      context 'with a custom version whose digest is supplied through checksums' do
        let(:params) do
          {
            'version' => '0.18.0',
            'checksums' => { 'restic_0.18.0_linux_amd64.bz2' => 'b' * 64 },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_archive('restic-0.18.0').with_checksum('b' * 64) }
      end

      # The point of the guard: an unverified binary is never installed, even
      # if that means the run fails.
      context 'with a custom version and no digest for it' do
        let(:params) { { 'version' => '0.18.0' } }

        it {
          is_expected.to compile.and_raise_error(%r{no sha256 digest known for restic_0.18.0_linux_amd64.bz2})
        }
      end

      context 'with package install' do
        let(:params) { { 'install_method' => 'package', 'package_name' => 'restic', 'package_ensure' => 'latest' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('restic').with(ensure: 'latest', name: 'restic') }
        it { is_expected.not_to contain_archive('restic-0.19.1') }
        it { is_expected.not_to contain_exec('restic-install-0.19.1') }
        it { is_expected.not_to contain_file('/usr/local/bin/restic') }
      end

      context 'with custom directories' do
        let(:params) { { 'config_dir' => '/srv/restic', 'bin_dir' => '/srv/backup' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/srv/restic').with_mode('0700') }
        it { is_expected.to contain_file('/srv/backup').with_mode('0750') }
        it { is_expected.to contain_file('/srv/backup/restic-run') }
      end
    end
  end
end
