module Syskit
    module Test
        class ComponentTest < Spec
            include Syskit::Test

            def self.roby_should_run(test, app)
                super

                if app.simulation?
                    begin
                        ruby_task = Orocos::RubyTasks::TaskContext.new(
                            "spec#{object_id}", :model => desc.orogen_model)
                        ruby_task.dispose
                    rescue ::Exception => e
                        test.skip("#{test.__name__} cannot run: #{e.message}")
                    end
                else
                    project_name = desc.orogen_model.project.name
                    if !Orocos.default_pkgconfig_loader.has_project?(project_name)
                        test.skip("#{test.__name__} cannot run: the task is not available")
                    end
                end
            end
        end
    end
end

