module Syskit
    module GUI
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
            end
        end
    end
end


