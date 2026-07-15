# frozen_string_literal: true

require 'spec_helper'

describe 'restic::copy' do
  let(:title) { 'mariadb-dr' }
  let(:pre_condition) do
    <<~PUPPET
      restic::repository { 'mariadb':
        repository => '/share/backups/restic/cem3/mariadb',
        password   => 'secret',
      }
      restic::repository { 'mariadb-dr':
        repository => 's3:https://s3.example.com/cem-prod-backup/cem3/mariadb',
        password   => 'secret',
        env        => { 'AWS_ACCESS_KEY_ID' => 'AKIA', 'AWS_SECRET_ACCESS_KEY' => 'shh' },
        init       => false,
      }
    PUPPET
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with defaults (cron schedule, keep-daily 5)' do
        let(:params) do
          {
            'source_repository' => 'mariadb',
            'dest_repository' => 'mariadb-dr',
          }
        end

        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh')
            .with(ensure: 'file', owner: 'root', group: 'root', mode: '0750')
            .that_requires('Restic::Repository[mariadb]')
            .that_requires('Restic::Repository[mariadb-dr]')
        }

        # sources the two repository env files
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{RESTIC_CACHE_DIR="\$\{RESTIC_CACHE_DIR:-/var/cache/restic\}"}) }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{source '/etc/restic/mariadb-dr\.env'}) }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{RESTIC_FROM_REPOSITORY=.*source '/etc/restic/mariadb\.env'}) }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{restic init --from-repo .* --copy-chunker-params}) }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{restic copy --from-repo}) }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{restic forget --keep-daily 5$}) }
        # no tag filter by default
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').without_content(%r{--tag}) }
        # locks the destination repository lock (shared with its prune)
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{exec 9>'/run/restic-mariadb-dr\.lock'}) }

        it {
          is_expected.to contain_exec('restic-copy-init-mariadb-dr')
            .with_command('/opt/backup/copy-mariadb-dr.sh init')
            .with_unless('/opt/backup/restic-run /etc/restic/mariadb-dr.env cat config')
            .that_requires('File[/opt/backup/copy-mariadb-dr.sh]')
        }

        it {
          is_expected.to contain_cron('restic copy mariadb-dr')
            .with(user: 'root', minute: '30', hour: '3', monthday: '*', month: '*', weekday: '*')
        }
        it { is_expected.not_to contain_systemd__unit_file('restic-copy-mariadb-dr.timer') }
      end

      context 'with tags and a custom keep policy' do
        let(:params) do
          {
            'source_repository' => 'mariadb',
            'dest_repository' => 'mariadb-dr',
            'tags' => ['cem_www_prod'],
            'keep' => { 'daily' => 5, 'weekly' => 2 },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{restic copy --from-repo "\$\{RESTIC_FROM_REPOSITORY\}" --tag 'cem_www_prod'}) }
        it { is_expected.to contain_file('/opt/backup/copy-mariadb-dr.sh').with_content(%r{restic forget --keep-daily 5 --keep-weekly 2 --tag 'cem_www_prod'}) }
      end

      context 'with a crontab string overriding the discrete fields' do
        let(:params) do
          {
            'source_repository' => 'mariadb',
            'dest_repository' => 'mariadb-dr',
            'crontab' => '45 4 * * 6',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it {
          is_expected.to contain_cron('restic copy mariadb-dr')
            .with(minute: '45', hour: '4', monthday: '*', month: '*', weekday: '6')
        }
      end

      context 'with init disabled' do
        let(:params) do
          {
            'source_repository' => 'mariadb',
            'dest_repository' => 'mariadb-dr',
            'init' => false,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('restic-copy-init-mariadb-dr') }
      end

      context 'with a systemd-timer schedule' do
        let(:params) do
          {
            'source_repository' => 'mariadb',
            'dest_repository' => 'mariadb-dr',
            'schedule_provider' => 'systemd_timer',
            'on_calendar' => '*-*-* 05:15:00',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_systemd__unit_file('restic-copy-mariadb-dr.service') }
        it {
          is_expected.to contain_systemd__unit_file('restic-copy-mariadb-dr.timer')
            .with_content(%r{OnCalendar=\*-\*-\* 05:15:00})
        }
        it { is_expected.not_to contain_cron('restic copy mariadb-dr') }
      end
    end
  end
end
