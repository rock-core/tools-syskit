# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Module providing common functionality to validate that some methods are
            # called within the main thread
            module MainThreadRestrictions
                # Make a thread the main thread
                #
                # Usually called in an object's constructor
                #
                # @param [Thread] thread the thread that will become 'main', by default
                #    the current thread
                def update_main_thread(thread = Thread.current)
                    @__main_thread = thread
                end

                class InvalidThread < RuntimeError; end

                # Validate that the current thread is the main thread
                #
                # Called in non-thread-safe methods to make sure they aren't called
                # outside of the main thread
                def ensure_in_main_thread
                    return if Thread.current == @__main_thread

                    raise InvalidThread,
                          "calling #{caller(1, 1).first} outside of main thread"
                end
            end
        end
    end
end
