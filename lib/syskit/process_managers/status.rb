# frozen_string_literal: true

module Syskit
    module ProcessManagers
        # Fake status class used by process managers to report exit status
        class Status
            def initialize(success = true)
                @success = success
            end

            def stopped?
                false
            end

            def exited?
                !@success
            end

            def exitstatus
                success ? 0 : 1
            end

            def signaled?
                false
            end

            def success?
                @success
            end
        end
    end
end
