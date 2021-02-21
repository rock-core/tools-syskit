# frozen_string_literal: true

module Syskit
    # Namespace containing all the functionality required to integrate syskit in
    # a Roby application
    #
    # It is not loaded by default when you require 'syskit'. You need to
    # explicitly require 'syskit/roby_app'
    module RobyApp
        extend Logger::Hierarchy
    end
end

require "syskit/roby_app/logging_configuration"
require "syskit/roby_app/logging_group"
require "syskit/roby_app/robot_extension"
require "syskit/roby_app/toplevel"
require "syskit/roby_app/configuration"
require "syskit/roby_app/plugin"
require "syskit/roby_app/single_file_dsl"
require "syskit/roby_app/unmanaged_process"
require "syskit/roby_app/unmanaged_tasks_manager"
require "syskit/roby_app/remote_processes"
require "syskit/roby_app/log_transfer_server"

module Syskit
    class << self
        # The main configuration object
        #
        # For consistency reasons, it is also available as Roby.conf.syskit when
        # running in a Roby application
        def conf
            @conf ||= RobyApp::Configuration.new(Roby.app)
        end
    end
end
