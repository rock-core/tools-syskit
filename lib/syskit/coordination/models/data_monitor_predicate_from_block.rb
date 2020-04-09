# frozen_string_literal: true

module Syskit
    module Coordination
        module Models
            class DataMonitorPredicateFromBlock
                # @return [#call] the predicate block. It is called with the
                #   data samples in the same order than defined by the
                #   data_streams argument of {#initialize}
                attr_reader :block
                # @return [Array<Object,nil>] the per-stream set of samples
                #   last received. The sample order is the same than the
                #   data_streams argument of {#initialize}
                attr_reader :samples
                # @return [{Syskit::Models::OutputReader=>Integer}] a mapping
                #   from a reader model to the index in the list of samples
                #   (and, therefore, in the block's argument list)
                attr_reader :stream_to_index
                # @return [Boolean] indicates whether #call has been received
                #   with a new sample since the last call to #finalize
                def has_new_sample?
                    @new_sample
                end
                # @return [Hash] set of arguments that are needed by the
                # predicate block
                attr_reader :arguments

                # @param [Array<Syskit::Models::OutputReader>] data_streams the
                #   data streams, in the same order than expected by the given
                #   block
                # @param [#call] predicate_block the predicate object. See the
                #   documentation of {#block}
                def initialize(data_streams, predicate_block, arguments = {})
                    check_arity(predicate_block, data_streams.size)

                    @arguments = arguments
                    @stream_to_index = {}
                    data_streams.each_with_index do |s, idx|
                        stream_to_index[s] = idx
                    end
                    @samples = Array.new(data_streams.size)
                    @block = predicate_block

                    # Flag used to know whether we have at least a sample per
                    # stream
                    @full = false
                    @new_sample = false
                end

                def bind(table, data_streams)
                    self.class.new(data_streams, block, table.arguments)
                end

                # Called when a new sample has been received
                #
                # @param [Syskit::Models::OutputReader] the data stream on which
                #   the sample has been received
                # @param [Object] the sample itself
                def call(stream, sample)
                    samples[stream_to_index[stream]] = sample
                    @new_sample = true
                end

                # Called to know whether this predicate matched or not
                # @return [Boolean]
                def finalize
                    return unless has_new_sample?

                    unless @full
                        return if samples.compact.size != samples.size

                        @full = true
                    end
                    @new_samples = false
                    instance_exec(*samples, &block)
                end

                def respond_to_missing?(m, include_private)
                    arguments.key?(m) || super
                end

                def method_missing(m, *args)
                    if arguments.key?(m)
                        unless args.empty?
                            raise ArgumentError, "#{args.size} provided to #{m}, zero expected"
                        end

                        return arguments[m]
                    end
                    super
                end
            end
        end
    end
end
