module Syskit
    module Test
        class TaskContextTest < ComponentTest
            def self.subject_syskit_model
                current = self
                while current && !current.desc.respond_to?(:orogen_model)
                    current = current.superclass
                end
                current.desc
            end

            # Helper that creates a standard test which configures the
            # underlying task
            def self.it_should_be_configurable
                it "should be configurable" do
                    component_m = self.class.desc
                    if driver_srv = component_m.each_master_driver_service.first
                        component_m = stub_syskit_driver(driver_srv.model,
                                                         :as => 'driver_task',
                                                         :using => component_m)
                    else
                        stub_syskit_deployment_model(component_m, 'task')
                    end
                    task = syskit_run_deployer(component_m)
                    syskit_setup_component(task)
                end
            end

            def self.roby_should_run(test, app)
                super

                if app.simulation?
                    begin
                        ruby_task = Orocos::RubyTasks::TaskContext.new(
                            "spec#{object_id}", :model => subject_syskit_model.orogen_model)
                        ruby_task.dispose
                    rescue ::Exception => e
                        test.skip("#{test.__full_name__} cannot run: #{e.message}")
                    end
                else
                    project_name = subject_syskit_model.orogen_model.project.name
                    if !Orocos.default_pkgconfig_loader.has_project?(project_name)
                        test.skip("#{test.__full_name__} cannot run: the task is not available")
                    end
                end
            end
        end
    end
end

