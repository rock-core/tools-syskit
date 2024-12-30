# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Async interface compatible with the orocos.rb's API
            class OutputPort < InterfaceObject
                def initialize(task_context, name, type, port_read_manager)
                    super(task_context, name, type)

                    @port_read_manager = port_read_manager
                end

                def output?
                    true
                end

                def input?
                    false
                end

                def on_raw_data(period: 0.1, init: false, buffer_size: 1)
                    callback = proc do |value|
                        yield(value) if value
                    end

                    register_with = proc do
                        @port_read_manager.register_callback(
                            self, callback,
                            period: period, init: init, buffer_size: buffer_size
                        )
                    end

                    listener = Listener.new(register_with)
                    listener.start
                    listener
                end

                def on_data(period: 0.1, init: false, buffer_size: 1)
                    on_raw_data(
                        period: period, init: init, buffer_size: buffer_size
                    ) do |data|
                        yield Typelib.to_ruby(data)
                    end
                end

                # Asynchronously create a data reader on this port
                def reader(connect_on:, disconnect_on:, **policy)
                    OutputReader.new(
                        self, policy,
                        connect_on: connect_on, disconnect_on: disconnect_on
                    )
                end

                def type?
                    true
                end
            end
        end
    end
end
