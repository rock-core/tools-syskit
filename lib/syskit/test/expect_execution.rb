# frozen_string_literal: true

module Syskit
    module Test
        # Extensions to the execution expectation API that is mixed in the test classes
        module ExpectExecution
            def setup
                super

                @expect_execution_process_async_resolutions = true
            end

            # Controls at the test level whether the execution expectation harness
            # should poll async resolution results
            #
            # @see ExecutionExpectations#process_async_resolutions?
            attr_accessor :expect_execution_process_async_resolutions
        end
    end
end
