# frozen_string_literal: true

module Syskit
    module Test
        # Definition of expectations for Roby's expect_execution harness
        module ExecutionExpectations
            # @api private
            #
            # Helper used to resolve reader objects
            def self.resolve_orocos_reader(reader, **policy)
                if reader.respond_to?(:to_runkit_port)
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
                orocos_port = Runkit.allow_blocking_calls { port.to_runkit_port }
                if orocos_port.respond_to?(:read_new)
                    orocos_port # local input port
                else
                    Runkit.allow_blocking_calls { orocos_port.reader(**policy) }
                end
            end

            # @api private
            #
            # Get an orocos reader from a syskit port
            def self.resolve_orocos_reader_from_syskit_reader(reader)
                Runkit.allow_blocking_calls do
                    reader.port.to_runkit_port.reader(**reader.policy)
                end
            end

            # @api private
            #
            # Implementation of the {#have_no_new_sample} predicate
            class HaveNoNewSample < Roby::Test::ExecutionExpectations::Maintain
                DEFAULT_BUFFER_SIZE = 100

                def initialize(
                    reader, at_least_during, description, buffer_size, backtrace
                )
                    @reader = reader
                    orocos_reader = ExecutionExpectations.resolve_orocos_reader(
                        reader, type: :buffer, size: buffer_size
                    )

                    block = ->(_) { process_samples(orocos_reader) }
                    super(at_least_during, block, description, backtrace)
                end

                def process_samples(reader)
                    until (sample = reader.read_new).nil?
                        if !@predicate || @predicate.call(sample)
                            @received_sample = sample
                            return false
                        end
                    end
                    true
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
            # @param [Integer] buffer_size the size of the reading buffer, only
            #   needed when using {HaveNoNewSample#matching}. The default is 100,
            #   which should be big enough for most test cases. Tune if you are
            #   sending more than 100 samples and expect the test to filter out
            #   all of them
            # @return [nil]
            def have_no_new_sample(
                reader,
                buffer_size: HaveNoNewSample::DEFAULT_BUFFER_SIZE,
                at_least_during: 0, backtrace: caller(1)
            )
                description = "#{reader} should not have received a new sample"
                add_expectation(
                    HaveNoNewSample.new(
                        reader, at_least_during, description, buffer_size, backtrace
                    )
                )
            end

            # @api private
            #
            # Implementation of the #have.*new_sample.* predicates
            #
            # It is basically #achieve, but with the ability to add a #matching
            # block
            class HaveNewSamples < Roby::Test::ExecutionExpectations::Achieve
                DEFAULT_BUFFER_SIZE = 100

                def initialize(reader, count, buffer_size, backtrace)
                    @received_samples = []
                    @predicate = nil

                    orocos_reader = ExecutionExpectations.resolve_orocos_reader(
                        reader, type: :buffer, size: buffer_size
                    )

                    description = proc do
                        matching = " matching the given predicate" if @predicate
                        "#{reader} should have received #{count} new sample(s)"\
                        "#{matching}, but got #{@received_samples.size}"
                    end
                    block = ->(_) { process_samples(orocos_reader, count) }
                    super(block, description, backtrace)
                end

                def process_samples(reader, count)
                    until (sample = reader.read_new).nil?
                        if !@predicate || @predicate.call(sample)
                            @received_samples << sample
                            return true if @received_samples.size == count
                        end
                    end
                    false
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
            # @param [Integer] buffer_size the size of the reading buffer. The default
            #   is 100, which should be big enough for most test cases. Tune if you
            #   are sure the samples are sent, but only partially read (and if you are
            #   sending more than 100 of them)
            # @return [Object]
            def have_one_new_sample(
                reader, buffer_size: HaveNewSamples::DEFAULT_BUFFER_SIZE,
                backtrace: caller(1)
            )
                have_new_samples(
                    reader, 1, buffer_size: buffer_size, backtrace: backtrace
                ).filter_result_with(&:first)
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
            # @param [Integer] buffer_size the size of the reading buffer. The default
            #   is 100, which should be big enough for most test cases. Tune if you
            #   are sure the samples are sent, but only partially read (and if you are
            #   sending more than 100 of them)
            # @return [Object]
            def have_new_samples(
                reader, count, buffer_size: HaveNewSamples::DEFAULT_BUFFER_SIZE,
                backtrace: caller(1)
            )
                add_expectation(
                    HaveNewSamples.new(reader, count, buffer_size, backtrace)
                )
            end
        end
    end
end
