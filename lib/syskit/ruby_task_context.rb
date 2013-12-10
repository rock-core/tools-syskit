module Syskit
    class RubyTaskContext < Syskit::TaskContext
        def self.input_port(*args, &block)
            orogen_model.input_port(*args, &block)
        end

        def self.output_port(*args, &block)
            orogen_model.output_port(*args, &block)
        end
    end
end

