# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Module providing common functionality to validate the thread some methods
            # are called from
            #
            # Set the "main" thread, that is the thread we want these methods to be called
            # from, by calling {#update_main_thread} and then call
            # {#ensure_in_main_thread} to enforce the restriction.
            #
            # This is usually meant to be used in an event-loop kind of application that
            # spawns futures/promises, to make sure thread-unsafe methods are not called
            # in a separate thread.
            module MainThreadRestrictions
                # Make a thread the main thread
                #
                # Usually called in an object's constructor
                #
                # @param [Thread] thread the thread that will become 'main', by default
                #    the current thread. When running on a UI, it will usually be called
                #    from within the thread of the UI event loop
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
