# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # An API compatible with {OutputPort} but that will give access to a sub-part
            # of a data sample
            #
            # For instance, a field in a struct
            class OutputPortSubfield < InterfaceObject
                def initialize(port, subfield, port_read_manager)
                    @path = normalize_subfield_path(subfield)
                    subname = compute_subname(@path)
                    subtype = compute_subtype(port.type, @path)

                    super(port.task_context, "#{port.name}#{subname.join}", subtype)

                    @port_read_manager = port_read_manager

                    @orig_port = port
                    @on_port_reachable = port.on_reachable do |raw|
                        reachable!(raw)
                    end
                    @on_port_unreachable = port.on_unreachable do
                        unreachable!
                    end
                end

                def output?
                    true
                end

                def input?
                    false
                end

                def dispose
                    @on_port_reachable.dispose
                    @on_port_unreachable.dispose
                end

                def on_raw_data(period: 0.1, init: false, buffer_size: 1)
                    callback = proc do |value|
                        yield(self.class.resolve_subfield(value, @path)) if value
                    end

                    register_with = proc do
                        @port_read_manager.register_callback(
                            @orig_port, callback,
                            period: period, init: init, buffer_size: buffer_size
                        )
                    end

                    listener = Listener.new(register_with)
                    listener.start
                    listener
                end

                def on_data(**policy)
                    on_raw_data(**policy) do |sample|
                        sample = Typelib.to_ruby(sample)
                        yield(sample)
                    end
                end

                def sub_port(subfield)
                    OutputPortSubfield.new(
                        @orig_port,
                        @subfield + Array(subfield)
                    )
                end

                def self.resolve_subfield(root_sample, path)
                    path.inject(root_sample) do |sample, f|
                        break(nil) if f.kind_of?(Integer) && sample.size <= f

                        sample.raw_get(f)
                    end
                end

                def compute_subtype(type, path)
                    path.inject(type) do |t, f|
                        case f
                        when Integer
                            t.deference
                        else
                            t[f]
                        end
                    end
                end

                def normalize_subfield_path(subfield)
                    subfield.map do |field|
                        if /^\d+$/.match?(field)
                            Integer(field)
                        else
                            field.to_s
                        end
                    end
                end

                def compute_subname(path)
                    path.map do |field|
                        case field
                        when Integer
                            "[#{field}]"
                        else
                            ".#{field}"
                        end
                    end
                end
            end
        end
    end
end
