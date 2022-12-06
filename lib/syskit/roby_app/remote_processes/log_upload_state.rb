# frozen_string_literal: true

module Syskit
    module RobyApp
        module RemoteProcesses
            # State of the asynchronous file transfers managed by {Server}
            class LogUploadState
                attr_reader :pending_count

                Result = Struct.new :file, :success, :message do
                    def success?
                        success
                    end
                end

                def initialize(pending_count, results)
                    @pending_count = pending_count
                    @results = results
                end

                def each_result(&block)
                    @results.each(&block)
                end
            end
        end
    end
end
