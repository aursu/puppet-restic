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

        it {
          is_expected.to contain_archive('restic-0.19.1')
            .with(source: %r{restic/releases/download/v0.19.1/restic_0.19.1_linux_amd64.bz2})
            .with(extract: false)
        }

        it { is_expected.to contain_exec('restic-install-0.19.1').that_requires('Archive[restic-0.19.1]') }

        it {
          is_expected.to contain_file('/usr/local/bin/restic')
            .with(ensure: 'link', target: '/usr/local/bin/restic-0.19.1')
            .that_requires('Exec[restic-install-0.19.1]')
        }

        it { is_expected.not_to contain_package('restic') }
      end

      context 'with a custom version' do
        let(:params) { { 'version' => '0.18.0' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_archive('restic-0.18.0') }
        it { is_expected.to contain_file('/usr/local/bin/restic').with_target('/usr/local/bin/restic-0.18.0') }
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
