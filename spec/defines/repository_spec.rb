# frozen_string_literal: true

require 'spec_helper'

describe 'restic::repository' do
  let(:title) { 'mariadb' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'local repository with default (cron) prune' do
        let(:params) do
          {
            'repository' => '/backups/restic/mariadb',
            'password' => 'secret',
          }
        end

        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/etc/restic/mariadb.env')
            .with(ensure: 'file', owner: 'root', group: 'root', mode: '0600', show_diff: false)
            .that_requires('Class[restic]')
        }

        it { is_expected.to contain_file('/etc/restic/mariadb.env').with_content(%r{RESTIC_REPOSITORY='/backups/restic/mariadb'}) }
        it { is_expected.to contain_file('/etc/restic/mariadb.env').with_content(%r{RESTIC_PASSWORD='secret'}) }

        it { is_expected.to contain_exec('restic-mkdir-mariadb').with_command(%r{mkdir -p '/backups/restic'}) }
        it { is_expected.to contain_file('/backups/restic/mariadb').with(ensure: 'directory', mode: '0700') }

        it {
          is_expected.to contain_exec('restic-init-mariadb')
            .with_command('/opt/backup/restic-run /etc/restic/mariadb.env init')
            .with_unless('/opt/backup/restic-run /etc/restic/mariadb.env cat config')
        }

        it { is_expected.to contain_file('/opt/backup/restic-mariadb-prune.sh').with_mode('0750') }
        it {
          is_expected.to contain_cron('restic prune mariadb')
            .with(user: 'root', minute: '20', hour: '4', weekday: '*')
        }
        it { is_expected.not_to contain_systemd__unit_file('restic-prune-mariadb.timer') }
      end

      context 'with a Sensitive password, extra env and cache_dir' do
        let(:params) do
          {
            'repository' => 's3:https://s3.example.com/bucket/mariadb',
            'password' => sensitive('supersecret'),
            'env' => { 'AWS_ACCESS_KEY_ID' => 'AKIA', 'AWS_SECRET_ACCESS_KEY' => 'shh' },
            'cache_dir' => '/var/cache/restic',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/restic/mariadb.env').with_content(%r{RESTIC_PASSWORD='supersecret'}) }
        it { is_expected.to contain_file('/etc/restic/mariadb.env').with_content(%r{AWS_ACCESS_KEY_ID='AKIA'}) }
        it { is_expected.to contain_file('/etc/restic/mariadb.env').with_content(%r{RESTIC_CACHE_DIR='/var/cache/restic'}) }
      end

      context 's3 repository (remote backend) does not manage a backing directory' do
        let(:params) do
          {
            'repository' => 's3:https://s3.example.com/bucket/mariadb',
            'password' => 'secret',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('restic-mkdir-mariadb') }
        it { is_expected.not_to contain_file('s3:https://s3.example.com/bucket/mariadb') }
        it { is_expected.to contain_exec('restic-init-mariadb') }
      end

      context 'with systemd-timer prune' do
        let(:params) do
          {
            'repository' => '/backups/restic/mariadb',
            'password' => 'secret',
            'schedule_provider' => 'systemd_timer',
            'prune_on_calendar' => '*-*-* 05:00:00',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_systemd__unit_file('restic-prune-mariadb.service') }
        it {
          is_expected.to contain_systemd__unit_file('restic-prune-mariadb.timer')
            .with_content(%r{OnCalendar=\*-\*-\* 05:00:00})
        }
        it { is_expected.not_to contain_cron('restic prune mariadb') }
      end

      context 'with init disabled' do
        let(:params) do
          {
            'repository' => '/backups/restic/mariadb',
            'password' => 'secret',
            'init' => false,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('restic-init-mariadb') }
      end

      context 'with manage_directory disabled on a local repository' do
        let(:params) do
          {
            'repository' => '/backups/restic/mariadb',
            'password' => 'secret',
            'manage_directory' => false,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('restic-mkdir-mariadb') }
        it { is_expected.not_to contain_file('/backups/restic/mariadb') }
      end

      context 'with prune disabled' do
        let(:params) do
          {
            'repository' => '/backups/restic/mariadb',
            'password' => 'secret',
            'manage_prune' => false,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_file('/opt/backup/restic-mariadb-prune.sh') }
        it { is_expected.not_to contain_cron('restic prune mariadb') }
      end
    end
  end
end
