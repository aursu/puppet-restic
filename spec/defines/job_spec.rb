# frozen_string_literal: true

require 'spec_helper'

describe 'restic::job' do
  let(:title) { 'db1' }
  let(:pre_condition) do
    <<~PUPPET
      restic::repository { 'mariadb':
        repository => '/backups/restic/mariadb',
        password   => 'secret',
      }
    PUPPET
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'stdin mode with a cron schedule (crontab string)' do
        let(:params) do
          {
            'repository' => 'mariadb',
            'command' => ['/usr/bin/mariadb-dump', '--single-transaction', 'db1'],
            'stdin_filename' => 'db1.sql',
            'crontab' => '55 2 * * 0',
            'keep' => { 'daily' => 5 },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/opt/backup/backup-db1.sh')
            .with(ensure: 'file', mode: '0750')
            .that_requires('Restic::Repository[mariadb]')
        }

        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{backup --stdin-from-command}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{--stdin-filename 'db1.sql'}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{-- '/usr/bin/mariadb-dump' '--single-transaction' 'db1'}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{forget --tag 'db1' --keep-daily 5}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').without_content(%r{trap cleanup EXIT}) }

        # crontab string overrides discrete fields
        it {
          is_expected.to contain_cron('restic backup db1')
            .with(user: 'root', minute: '55', hour: '2', monthday: '*', month: '*', weekday: '0')
        }
        it { is_expected.not_to contain_systemd__unit_file('restic-backup-db1.timer') }
      end

      context 'stdin mode with discrete cron fields and a custom user' do
        let(:params) do
          {
            'repository' => 'mariadb',
            'command' => ['/usr/bin/mariadb-dump', 'db1'],
            'stdin_filename' => 'db1.sql',
            'minute' => '30',
            'hour' => '1',
            'user' => 'backup',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it {
          is_expected.to contain_cron('restic backup db1')
            .with(user: 'backup', minute: '30', hour: '1')
        }
      end

      context 'path mode with systemd timer and pre/post hooks' do
        let(:params) do
          {
            'repository' => 'mariadb',
            'paths' => ['/var/backups/etcd/etcd-snapshot.db'],
            'pre_command' => '/opt/backup/etcd-snapshot.sh /var/backups/etcd/etcd-snapshot.db',
            'post_command' => "rm -f '/var/backups/etcd/etcd-snapshot.db'",
            'snapshot_tag' => 'etcd',
            'schedule_provider' => 'systemd_timer',
            'on_calendar' => '*-*-* 03:30:00',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{trap cleanup EXIT}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{cleanup\(\) \{ rm -f '/var/backups/etcd/etcd-snapshot.db'; \}}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{/opt/backup/etcd-snapshot.sh /var/backups/etcd/etcd-snapshot.db}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{backup \\}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{--tag 'etcd'}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{'/var/backups/etcd/etcd-snapshot.db'}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{forget --tag 'etcd'}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').without_content(%r{--stdin-from-command}) }

        it { is_expected.to contain_systemd__unit_file('restic-backup-db1.service') }
        it {
          is_expected.to contain_systemd__unit_file('restic-backup-db1.timer')
            .with_content(%r{OnCalendar=\*-\*-\* 03:30:00})
        }
        it { is_expected.not_to contain_cron('restic backup db1') }
      end

      context 'path mode with only a pre_command (no cleanup trap)' do
        let(:params) do
          {
            'repository' => 'mariadb',
            'paths' => ['/data'],
            'pre_command' => '/bin/true',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').without_content(%r{trap cleanup EXIT}) }
        it { is_expected.to contain_file('/opt/backup/backup-db1.sh').with_content(%r{^/bin/true$}) }
      end

      context 'validation errors' do
        context 'with neither command nor paths' do
          let(:params) { { 'repository' => 'mariadb' } }

          it { is_expected.to compile.and_raise_error(%r{exactly one}) }
        end

        context 'with both command and paths' do
          let(:params) do
            {
              'repository' => 'mariadb',
              'command' => ['/usr/bin/true'],
              'stdin_filename' => 'x.sql',
              'paths' => ['/var/x'],
            }
          end

          it { is_expected.to compile.and_raise_error(%r{exactly one}) }
        end

        context 'stdin mode without stdin_filename' do
          let(:params) do
            {
              'repository' => 'mariadb',
              'command' => ['/usr/bin/true'],
            }
          end

          it { is_expected.to compile.and_raise_error(%r{requires .*stdin_filename}) }
        end
      end
    end
  end
end
