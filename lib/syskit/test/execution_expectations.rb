module Syskit
    module Test
        # Definition of expectations for Roby's expect_execution harness
        module ExecutionExpectations
            # @api private
            #
            # Helper used to resolve reader objects
            def self.resolve_orocos_reader(reader)
                if reader.respond_to?(:to_orocos_port)
                    reader = Orocos.allow_blocking_calls do
                        reader.to_orocos_port
                    end
                end
                if !reader.respond_to?(:read_new)
                    if reader.respond_to?(:reader)
                        reader = Orocos.allow_blocking_calls do
                            reader.reader
                        end
                    end
                end
                reader
            end

            # Expect that no new samples arrive on the reader for a certain time
            # period
            #
            # @param [Float] at_least_during no samples should arrive for at
            #   least that many seconds. This is a minimum.
            # @return [nil]
            def have_no_new_sample(reader, at_least_during: 0)
                reader = ExecutionExpectations.resolve_orocos_reader(reader)
                maintain(at_least_during: at_least_during, description: "#{reader} has one new sample #{sample}, but none was expected") do
                    !reader.read_new
                end
                nil
            end

            # Expect that one sample arrives on the reader, and return the sample
            #
            # @return [Object]
            def have_one_new_sample(reader)
                reader = ExecutionExpectations.resolve_orocos_reader(reader)
                achieve(description: "receive one sample on #{reader}") { reader.read_new }
            end
        end
    end
end

