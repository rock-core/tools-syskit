# frozen_string_literal: true

module Syskit
    module Test
        # Definition of expectations for Roby's expect_execution harness
        module ExecutionExpectations
            # @api private
            #
            # Helper used to resolve reader objects
            def self.resolve_orocos_reader(reader, **policy)
                if reader.respond_to?(:to_orocos_port)
                    resolve_orocos_reader_from_port(reader, **policy)
                elsif reader.respond_to?(:orocos_accessor)
                    resolve_orocos_reader_from_syskit_reader(reader)
                elsif !reader.respond_to?(:reader_new)
                    raise ArgumentError, "#{reader} does not seem to be an output reader"
                end
            end

            # @api private
            #
            # Get an orocos reader from a syskit port
            def self.resolve_orocos_reader_from_port(port, **policy)
                orocos_port = Orocos.allow_blocking_calls { port.to_orocos_port }
                if orocos_port.respond_to?(:read_new)
                    orocos_port # local input port
                else
                    Orocos.allow_blocking_calls { orocos_port.reader(**policy) }
                end
            end

            # @api private
            #
            # Get an orocos reader from a syskit port
            def self.resolve_orocos_reader_from_syskit_reader(reader)
                Orocos.allow_blocking_calls do
                    reader.port.to_orocos_port.reader(**reader.policy)
                end
            end

            # @api private
            #
            # Implementation of the {#have_no_new_sample} predicate
            class HaveNoNewSample < Roby::Test::ExecutionExpectations::Maintain
                def initialize(reader, at_least_during, description, backtrace)
                    @reader = reader
                    orocos_reader = ExecutionExpectations.resolve_orocos_reader(reader)
                    block = proc do
                        sample = orocos_reader.read_new
                        if sample && (!@predicate || @predicate.call(sample))
                            @received_sample = sample
                            false
                        else
                            true
                        end
                    end
                    super(at_least_during, block, description, backtrace)
                end

                def explain_unachievable(propagation_info)
                    @received_sample
                end

                def format_unachievable_explanation(pp, explanation)
                    pp.text "but it received one: "
                    explanation.pretty_print(pp)
                end

                def to_s
                    parent = super
                    if @predicate
                        "#{parent} matching the given predicate"
                    else
                        parent
                    end
                end

                def matching(&block)
                    if @predicate
                        raise ArgumentError, "only one #matching predicate is allowed"
                    end

                    @predicate = block
                    self
                end
            end

            # Expect that no new samples arrive on the reader for a certain time
            # period
            #
            # @param [Float] at_least_during no samples should arrive for at
            #   least that many seconds. This is a minimum.
            # @return [nil]
            def have_no_new_sample(reader, at_least_during: 0, backtrace: caller(1))
                description = "#{reader} should not have received a new sample"
                add_expectation(
                    HaveNoNewSample.new(reader, at_least_during, description, backtrace)
                )
            end

            # @api private
            #
            # Implementation of the #have.*new_sample.* predicates
            #
            # It is basically #achieve, but with the ability to add a #matching
            # block
            class HaveNewSamples < Roby::Test::ExecutionExpectations::Achieve
                def initialize(reader, count, backtrace)
                    @received_samples = []
                    @predicate = nil

                    orocos_reader = ExecutionExpectations.resolve_orocos_reader(
                        reader, type: :buffer, size: count
                    )

                    block = proc do
                        if (sample = orocos_reader.read_new)
                            if !@predicate || @predicate.call(sample)
                                @received_samples << sample
                                @received_samples.size == count
                            end
                        end
                    end
                    description = proc do
                        matching = " matching the given predicate" if @predicate
                        "#{reader} should have received #{count} new sample(s)"\
                        "#{matching}, but got #{@received_samples.size}"
                    end
                    super(block, description, backtrace)
                end

                def return_object
                    @received_samples
                end

                def matching(&block)
                    if @predicate
                        raise ArgumentError, "only one #matching predicate is allowed"
                    end

                    @predicate = block
                    self
                end
            end

            # Expect that one sample arrives on the reader, and return the sample
            #
            # If you'd like to wait for a sample that matches a particular predicate,
            # use #matching:
            #
            #   have_one_new_sample(reader)
            #       .matching { |s| s > 10 }
            #
            # @return [Object]
            def have_one_new_sample(reader, backtrace: caller(1))
                have_new_samples(reader, 1, backtrace: backtrace)
                    .filter_result_with(&:first)
            end

            # Expect that a certain number of sample arrives on the reader, and
            # return them
            #
            # If you'd like to wait for samples that match a particular
            # predicate, use #matching:
            #
            #   have_new_samples(reader, 10)
            #       .matching(&:odd?)
            #
            # @return [Object]
            def have_new_samples(reader, count, backtrace: caller(1))
                add_expectation(
                    HaveNewSamples.new(reader, count, backtrace)
                )
            end
        end
    end
end
