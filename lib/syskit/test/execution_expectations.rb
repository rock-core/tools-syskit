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
                    reader = Orocos.allow_blocking_calls do
                        reader.to_orocos_port
                    end
                end
                unless reader.respond_to?(:read_new)
                    if reader.respond_to?(:reader)
                        reader = Orocos.allow_blocking_calls do
                            reader.reader(**policy)
                        end
                    end
                end
                reader
            end

            # @api private
            #
            # Implementation of the {#have_no_new_sample} predicate
            class HaveNoNewSample < Roby::Test::ExecutionExpectations::Maintain
                def initialize(reader, at_least_during, predicate, description, backtrace)
                    @reader = reader
                    orocos_reader = ExecutionExpectations.resolve_orocos_reader(reader)
                    block = proc do
                        sample = orocos_reader.read_new
                        if sample && predicate.call(sample)
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
                    HaveNoNewSample.new(reader, at_least_during, ->(_) { true },
                                        description, backtrace)
                )
            end

            # Expect that no new samples that match the given predicate arrive on
            # the reader for a certain time period
            #
            # @param [Float] at_least_during no samples should arrive for at
            #   least that many seconds. This is a minimum.
            # @return [nil]
            def have_no_new_sample_matching(
                reader, at_least_during: 0, backtrace: caller(1), &predicate
            )
                description = "#{reader} should not have received a new sample "\
                              "matching the given predicate"
                add_expectation(
                    HaveNoNewSample.new(reader, at_least_during, predicate,
                                        description, backtrace)
                )
            end

            # Expect that one sample arrives on the reader, and return the sample
            #
            # @return [Object]
            def have_one_new_sample(reader, backtrace: caller(1))
                have_new_samples(reader, 1, backtrace: backtrace) { true }
                    .filter_result_with(&:first)
            end

            # Expect that one sample matching the given predicate arrives on the
            # reader, and return it
            #
            # @return [Object]
            def have_one_new_sample_matching(reader, backtrace: caller(1), &predicate)
                have_new_samples_matching(
                    reader, 1, backtrace: backtrace, &predicate
                ).filter_result_with(&:first)
            end

            # Expect that a certain number of samples arrive on the reader,
            # and return them
            #
            # @return [Array]
            def have_new_samples(reader, count, backtrace: caller(1))
                received_count = 0
                description ||= proc do
                    "#{reader} should have received #{count} new sample(s), "\
                    "but got #{received_count}"
                end
                have_new_samples_matching(
                    reader, count,
                    description: description, backtrace: backtrace
                ) { received_count += 1 }
            end

            # Expect that a certain number of samples matching the given predicate
            # arrive, and return them
            #
            # @return [Array]
            def have_new_samples_matching(
                reader, count, description: nil, backtrace: caller(1), &predicate
            )
                orocos_reader = ExecutionExpectations.resolve_orocos_reader(
                    reader, type: :buffer, size: count
                )

                samples = []
                description ||= proc do
                    "#{reader} should have received #{count} new sample(s) matching "\
                    "the given predicate, but got #{samples.size}"
                end
                achieve(description: description, backtrace: backtrace) do
                    if (sample = orocos_reader.read_new)
                        samples << sample if predicate.call(sample)
                        samples if samples.size == count
                    end
                end
            end
        end
    end
end
