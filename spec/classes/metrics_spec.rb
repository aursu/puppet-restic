# frozen_string_literal: true

require 'spec_helper'

describe 'restic::metrics' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with default parameters' do
        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/opt/backup/restic-metrics')
            .with(ensure: 'file', owner: 'root', group: 'root', mode: '0750')
            .with_content(%r{restic_repository_latest_snapshot_timestamp_seconds})
            .that_requires('File[/opt/backup]')
        }

        it {
          is_expected.to contain_systemd__unit_file('restic-metrics.service')
            .with_content(%r{^Type=oneshot$})
            .with_content(%r{^ExecStart=/usr/bin/python3 /opt/backup/restic-metrics --output /var/lib/node_exporter/textfile/restic\.prom })
            .with_content(%r{ --config-dir /etc/restic --runner /opt/backup/restic-run --timeout 300$})
        }

        it {
          is_expected.to contain_systemd__unit_file('restic-metrics.timer')
            .with(enable: true, active: true)
            .with_content(%r{^OnCalendar=\*:0/15$})
            .that_requires('Systemd::Unit_file[restic-metrics.service]')
        }
      end

      context 'with named repositories and a custom textfile directory' do
        let(:params) do
          {
            repositories: ['vault', 'keycloak'],
            textfile_directory: '/srv/textfile',
            filename: 'backup.prom',
            timeout: 60,
          }
        end

        it {
          is_expected.to contain_systemd__unit_file('restic-metrics.service')
            .with_content(%r{--output /srv/textfile/backup\.prom .* --timeout 60 --repository vault --repository keycloak$})
        }
      end

      context 'with ensure absent' do
        let(:params) { { ensure: 'absent' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_systemd__unit_file('restic-metrics.timer').with(ensure: 'absent', enable: false, active: false) }
        it { is_expected.to contain_systemd__unit_file('restic-metrics.service').with_ensure('absent') }
        it { is_expected.to contain_file('/opt/backup/restic-metrics').with_ensure('absent') }
        it { is_expected.to contain_file('/var/lib/node_exporter/textfile/restic.prom').with_ensure('absent') }
      end

      context 'with a filename that is a path' do
        let(:params) { { filename: '../restic.prom' } }

        it { is_expected.to compile.and_raise_error(%r{filename}) }
      end
    end
  end
end
