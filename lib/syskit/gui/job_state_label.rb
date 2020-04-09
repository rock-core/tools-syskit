# frozen_string_literal: true

module Syskit
    module GUI
        # A label that can be used to represent job states
        #
        # It [declares](StateLabel#declare_state) the known job states and
        # assigns proper colors to it.
        #
        # @example
        class JobStateLabel < StateLabel
            def initialize(**options)
                super
                declare_default_color :red
                declare_state Roby::Interface::JOB_PLANNING_READY.upcase, :blue
                declare_state Roby::Interface::JOB_PLANNING.upcase, :blue
                declare_state Roby::Interface::JOB_PLANNING_FAILED.upcase, :red
                declare_state Roby::Interface::JOB_READY.upcase, :blue
                declare_state Roby::Interface::JOB_STARTED.upcase, :green
                declare_state Roby::Interface::JOB_SUCCESS.upcase, :grey
                declare_state Roby::Interface::JOB_FAILED.upcase, :red
                declare_state Roby::Interface::JOB_FINISHED.upcase, :grey
                declare_state Roby::Interface::JOB_FINALIZED.upcase, :grey

                declare_state Roby::Interface::JOB_DROPPED.upcase, :grey
            end
        end
    end
end
