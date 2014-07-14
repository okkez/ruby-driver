# encoding: utf-8

require 'spec_helper'

module Cql
  class Cluster
    describe(ControlConnection) do
      let :control_connection do
        described_class.new(io_reactor, request_runner, cluster_registry, driver_settings)
      end

      let :io_reactor do
        FakeIoReactor.new
      end

      let :cluster_registry do
        Registry.new
      end

      let :request_runner do
        Client::RequestRunner.new
      end

      let :logger do
        Client::NullLogger.new
      end

      let :driver_settings do
        Driver.new(logger: logger, protocol_version: 7)
      end

      def connections
        io_reactor.connections
      end

      def last_connection
        connections.last
      end

      def requests
        last_connection.requests
      end

      def last_request
        requests.last
      end

      def handle_request(&handler)
        @request_handler = handler
      end

      let :local_info do
        {
          'data_center' => 'dc1',
          'host_id' => nil,
        }
      end

      let :local_metadata do
        [
          ['system', 'local', 'data_center', :text],
          ['system', 'local', 'host_id', :uuid],
        ]
      end

      let :peer_metadata do
        [
          ['system', 'peers', 'peer', :inet],
          ['system', 'peers', 'data_center', :varchar],
          ['system', 'peers', 'host_id', :uuid],
          ['system', 'peers', 'rpc_address', :inet],
        ]
      end

      let :data_centers do
        Hash.new('dc1')
      end

      let :racks do
        Hash.new('rack1')
      end

      let :release_versions do
        Hash.new('2.0.7-SNAPSHOT')
      end

      let :host_ids do
        Hash.new {|hash, ip| hash[ip] = uuid_generator.next}
      end

      let :additional_nodes do
        Array.new(5) { IPAddr.new("127.0.#{rand(255)}.#{rand(255)}") }
      end

      let :bind_all_rpc_addresses do
        false
      end

      let :min_peers do
        [2]
      end

      let :uuid_generator do
        TimeUuid::Generator.new
      end

      before do
        cluster_registry.add_listener(driver_settings.load_balancing_policy)
        cluster_registry.host_found('127.0.0.1')

        io_reactor.on_connection do |connection|
          connection[:spec_rack]            = racks[connection.host]
          connection[:spec_data_center]     = data_centers[connection.host]
          connection[:spec_host_id]         = host_ids[connection.host]
          connection[:spec_release_version] = release_versions[connection.host]

          connection.handle_request do |request, timeout|
            additional_rpc_addresses = additional_nodes.dup
            if @request_handler
              response = @request_handler.call(request, connection, proc { connection.default_request_handler(request) }, timeout)
            end

            response ||= case request
            when Protocol::StartupRequest, Protocol::RegisterRequest
              Protocol::ReadyResponse.new
            when Protocol::QueryRequest
              response = case request.cql
              when /USE\s+"?(\S+)"?/
                Cql::Protocol::SetKeyspaceResultResponse.new($1, nil)
              when /FROM system\.local/
                row = {
                  'rack'            => connection[:spec_rack],
                  'data_center'     => connection[:spec_data_center],
                  'host_id'         => connection[:spec_host_id],
                  'release_version' => connection[:spec_release_version]
                }
                Protocol::RowsResultResponse.new([row], local_metadata, nil, nil)
              when /FROM system\.peers WHERE peer = \?/
                ip   = request.values.first.to_s
                rows = [
                  {
                    'rack'            => racks[ip],
                    'data_center'     => data_centers[ip],
                    'host_id'         => host_ids[ip],
                    'release_version' => release_versions[ip]
                  }
                ]
                Protocol::RowsResultResponse.new(rows, peer_metadata, nil, nil)
              when /FROM system\.peers/
                rows = min_peers[0].times.map do |host_id|
                  ip = additional_rpc_addresses.shift
                  {
                    'peer'            => ip,
                    'rack'            => racks[ip],
                    'data_center'     => data_centers[ip],
                    'host_id'         => host_ids[ip],
                    'rpc_address'     => bind_all_rpc_addresses ? IPAddr.new('0.0.0.0') : ip,
                    'release_version' => release_versions[ip]
                  }
                end
                Protocol::RowsResultResponse.new(rows, peer_metadata, nil, nil)
              end
            when Protocol::OptionsRequest
              Protocol::SupportedResponse.new('CQL_VERSION' => %w[3.0.0], 'COMPRESSION' => %w[lz4 snappy])
            end

            response ||= connection.default_request_handler(request)

            response
          end
        end
      end

      describe "#connect_async" do
        it 'tries decreasing protocol versions until one succeeds' do
          counter = 0
          handle_request do |request|
            if counter < 3
              counter += 1
              Protocol::ErrorResponse.new(0x0a, 'Bork version, dummy!')
            elsif counter == 3
              counter += 1
              Protocol::SupportedResponse.new('CQL_VERSION' => %w[3.0.0], 'COMPRESSION' => %w[lz4 snappy])
            end
          end

          control_connection.connect_async.get

          driver_settings.protocol_version.should == 4
        end

        it 'logs when it tries the next protocol version' do
          logger.stub(:warn)
          counter = 0
          handle_request do |request|
            if counter < 3
              counter += 1
              Protocol::ErrorResponse.new(0x0a, 'Bork version, dummy!')
            elsif counter == 3
              counter += 1
              Protocol::SupportedResponse.new('CQL_VERSION' => %w[3.0.0], 'COMPRESSION' => %w[lz4 snappy])
            end
          end


          control_connection.connect_async.get
          logger.should have_received(:warn).with(/could not connect using protocol version 7 \(will try again with 6\): bork version, dummy!/i)
        end

        it 'gives up when the protocol version is zero' do
          counter = 0
          handle_request do |request|
            counter += 1
            Protocol::ErrorResponse.new(0x0a, 'Bork version, dummy!')
          end
          expect { control_connection.connect_async.get }.to raise_error(NoHostsAvailable)
          counter.should == 7
        end

        it 'gives up when a non-protocol version related error is raised' do
          handle_request do |request|
            Protocol::ErrorResponse.new(0x1001, 'Get off my lawn!')
          end
          expect { control_connection.connect_async.get }.to raise_error(NoHostsAvailable) do |e|
            e.errors.should have(1).error
            e.errors.values.first.message.should match(/Get off my lawn/)
          end
        end

        it 'fails authenticating when an auth provider has been specified but the protocol is negotiated to v1' do
          driver_settings.protocol_version = 1
          driver_settings.auth_provider    = double(:auth_provider)

          counter = 0
          handle_request do |request|
            case request
            when Protocol::OptionsRequest
              Protocol::SupportedResponse.new('CQL_VERSION' => %w[3.0.0], 'COMPRESSION' => %w[lz4 snappy])
            when Protocol::StartupRequest
              Protocol::AuthenticateResponse.new('org.apache.cassandra.auth.PasswordAuthenticator')
            end
          end
          expect { control_connection.connect_async.get }.to raise_error(NoHostsAvailable) do |e|
            e.errors.should have(1).error
            e.errors.values.first.should be_a(AuthenticationError)
          end
        end

        it 'registers an event listener' do
          control_connection.connect_async.get
          last_connection.should have_event_listener
        end

        it 'populates cluster state' do
          control_connection.connect_async.get
          cluster_registry.should have(3).hosts

          cluster_registry.hosts.each do |host|
            ip = host.ip
            host.rack.should == racks[ip]
            host.datacenter.should == data_centers[ip]
            host.release_version.should == release_versions[ip]
          end
        end

        context 'with empty cluster state' do
          before do
            handle_request do |request, connection, default_response, timeout|
              default_response.call
            end
          end

          it 'fails' do
            expect { control_connection.connect_async.get }.to raise_error(NoHostsAvailable)
          end
        end

        context 'with logging' do
          it 'logs when fetching cluster state' do
            logger.stub(:debug)
            control_connection.connect_async.get
            logger.should have_received(:debug).with(/Looking for additional nodes/)
            logger.should have_received(:debug).with(/\d+ additional nodes found/)
          end
        end

        context 'when the nodes have 0.0.0.0 as rpc_address' do
          let :bind_all_rpc_addresses do
            true
          end

          it 'falls back on using the peer column' do
            control_connection.connect_async.get
            cluster_registry.should have(3).hosts

            cluster_registry.hosts.each do |host|
              ip = host.ip
              host.rack.should == racks[ip]
              host.datacenter.should == data_centers[ip]
              host.release_version.should == release_versions[ip]
            end
          end
        end

        context 'when connection closed' do
          before do
            control_connection.connect_async.get
            last_connection.close
          end

          it 'reconnects' do
            last_connection.should be_connected
          end

          context 'and reconnected' do
            it 'has an event listener' do
              control_connection.connect_async.get
              last_connection.should have_event_listener
            end
          end

          context 'and all hosts are down' do
            before do
              cluster_registry.ips.each do |ip|
                io_reactor.node_down(ip)
              end

              connections.each do |connection|
                connection.close
              end
            end

            it 'keeps trying until some host comes up' do
              rand(10).times { io_reactor.advance_time(driver_settings.reconnect_interval) }

              last_connection.should_not be_connected

              io_reactor.node_up('127.0.0.1')
              io_reactor.advance_time(driver_settings.reconnect_interval)
              last_connection.should be_connected
            end
          end
        end

        context 'registered for events' do
          let :registry do
            double("registry stub")
          end

          before do
            control_connection.connect_async.get
          end

          context 'when a status change event is received' do
            let :event do
              Protocol::StatusChangeEventResponse.new(change, address, 9999)
            end

            context 'with UP' do
              let :change do
                'UP'
              end

              let :address do
                IPAddr.new('127.0.0.1')
              end

              it 'logs when it receives an UP event' do
                logger.stub(:debug)
                cluster_registry.stub(:host_up)
                connections.first.trigger_event(event)
                logger.should have_received(:debug).with(/Received STATUS_CHANGE UP event/)
              end

              context 'and host is known' do
                before do
                  cluster_registry.stub(:host_known?) { true }
                end

                let :address do
                  additional_nodes[0]
                end

                it 'notifies registry' do
                  ip = address.to_s
                  expect(cluster_registry).to receive(:host_found).once.with(ip, {
                    'rack'            => racks[ip],
                    'data_center'     => data_centers[ip],
                    'host_id'         => host_ids[ip],
                    'release_version' => release_versions[ip]
                  })
                  connections.first.trigger_event(event)
                end
              end

              context 'and host is unknown' do
                before do
                  cluster_registry.stub(:host_known?) { false }
                end

                let :address do
                  additional_nodes[3]
                end

                it 'does nothing' do
                  expect(cluster_registry).to_not receive(:host_found)

                  connections.first.trigger_event(event)
                end
              end
            end

            context 'with DOWN' do
              let :change do
                'DOWN'
              end

              let :address do
                '127.0.0.1'
              end

              it 'logs when it receives an DOWN event' do
                logger.stub(:debug)
                connections.first.trigger_event(event)
                logger.should have_received(:debug).with(/Received STATUS_CHANGE DOWN event/)
              end

              it 'notifies registry' do
                ip = address.to_s
                expect(cluster_registry).to receive(:host_down).once.with(ip)
                connections.first.trigger_event(event)
              end
            end
          end

          context 'when a topology change event is received' do
            let :event do
              Protocol::TopologyChangeEventResponse.new(change, address, 9999)
            end

            context 'with NEW_NODE' do
              let :change do
                'NEW_NODE'
              end

              let :address do
                '127.0.0.1'
              end

              it 'logs when it receives an NEW_NODE event' do
                logger.stub(:debug)
                connections.first.trigger_event(event)
                logger.should have_received(:debug).with(/Received TOPOLOGY_CHANGE NEW_NODE event/)
              end

              context 'and host is unknown' do
                let :address do
                  additional_nodes[3]
                end

                before do
                  cluster_registry.stub(:host_known?) { false }
                end

                it 'notifies registry' do
                  ip = address.to_s
                  expect(cluster_registry).to receive(:host_found).once.with(ip, {
                    'rack'            => racks[ip],
                    'data_center'     => data_centers[ip],
                    'host_id'         => host_ids[ip],
                    'release_version' => release_versions[ip]
                  })
                  connections.first.trigger_event(event)
                end
              end

              context 'and host is known' do
                let :address do
                  additional_nodes[0]
                end

                before do
                  cluster_registry.stub(:host_known?) { true }
                end

                it 'does nothing' do
                  expect(cluster_registry).to_not receive(:host_found)

                  connections.first.trigger_event(event)
                end
              end
            end

            context 'with REMOVED_NODE' do
              let :change do
                'REMOVED_NODE'
              end

              let :address do
                '127.0.0.1'
              end

              it 'logs when it receives an REMOVED_NODE event' do
                logger.stub(:debug)
                connections.first.trigger_event(event)
                logger.should have_received(:debug).with(/Received TOPOLOGY_CHANGE REMOVED_NODE event/)
              end

              it 'notifies registry' do
                ip = address.to_s
                expect(cluster_registry).to receive(:host_lost).once.with(ip)
                connections.first.trigger_event(event)
              end
            end
          end
        end
      end

      describe "#close_async" do
        context 'when connected' do
          before do
            control_connection.connect_async.get
          end

          it 'closes connection' do
            future = double('close future')

            last_connection.should_receive(:close).once.and_return(future)
            control_connection.close_async.should == future
          end
        end

        context 'not connected' do
          it 'returns a fulfilled future' do
            future = control_connection.close_async
            future.should be_resolved
            future.get.should be_nil
          end
        end

        context 'when reconnecting' do
          before do
            control_connection.connect_async.get

            cluster_registry.ips.each do |ip|
              io_reactor.node_down(ip)
            end

            last_connection.close
          end

          it 'stops reconnecting' do
            connections.select(&:connected?).should be_empty
            control_connection.close_async

            cluster_registry.ips.each do |ip|
              io_reactor.node_up(ip)
            end

            io_reactor.advance_time(driver_settings.reconnect_interval)
            io_reactor.advance_time(driver_settings.reconnect_interval)

            connections.select(&:connected?).should be_empty
          end
        end
      end
    end
  end
end
