# frozen_string_literal: true

module Syskit
    module RobyApp
        # Module mixed-in the global context to provide toplevel functionality,
        # thus allowing to create 'syskit scripts'
        module SingleFileDSL
            attribute(:profile_name) { "Script" }
            attribute(:global_profile) do
                Syskit::Actions::Profile.new(profile_name)
            end
            def add_mission(req)
                Roby.app.permanent_requirements << req
            end

            def add_mission_task(req)
                Roby.app.permanent_requirements << req
            end

            def profile
                if block_given?
                    global_profile.instance_eval(&proc)
                end
                global_profile
            end

            def method_missing(m, *args, &block)
                if m =~ /(?:_def|_dev)$|^define$/
                    return global_profile.send(m, *args, &block)
                end

                super
            end
        end
    end
end
