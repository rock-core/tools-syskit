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

            class HaveNoNewSample < Roby::Test::ExecutionExpectations::Maintain
                def initialize(reader, at_least_during, backtrace)
                    @reader = reader
                    orocos_reader = ExecutionExpectations.resolve_orocos_reader(reader)
                    block = proc { !(@received_sample = orocos_reader.read_new) }
                    super(at_least_during, block, "", backtrace)
                end

                def to_s
                    "#{@reader} should not have received a new sample"
                end

                def explain_unachievable(propagation_info)
                    @received_sample
                end

                def format_unachievable_explanation(pp, explanation)
                    pp.text "but it received one: "
                    explanation.pretty_print(pp)
                end
            end

            # Expect that no new samples arrive on the reader for a certain time
            # period
            #
            # @param [Float] at_least_during no samples should arrive for at
            #   least that many seconds. This is a minimum.
            # @return [nil]
            def have_no_new_sample(reader, at_least_during: 0, backtrace: caller(1))
                add_expectation(HaveNoNewSample.new(
                    reader, at_least_during, backtrace))
            end

            # Expect that one sample arrives on the reader, and return the sample
            #
            # @return [Object]
            def have_one_new_sample(reader, backtrace: caller(1))
                orocos_reader = ExecutionExpectations.resolve_orocos_reader(reader)
                achieve(description: "#{reader} should have received a new sample",
                    backtrace: backtrace) { orocos_reader.read_new }
            end
        end
    end
end

