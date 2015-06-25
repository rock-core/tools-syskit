module Syskit
    module Test
        class TaskContextTest < ComponentTest
            def setup
                super
                deploy_subject_syskit_model
            end

            def deploy_subject_syskit_model
                use_deployment self.class.subject_syskit_model => 'task_under_test'
            end

            def self.use_syskit_model(model)
                @subject_syskit_model = model
            end

            def self.subject_syskit_model(*setter)
                if @subject_syskit_model
                    @subject_syskit_model
                else
                    current = self
                    while current && !current.desc.respond_to?(:orogen_model)
                        current = current.superclass
                    end
                    current.desc
                end
            end

            # Helper that creates a standard test which configures the
            # underlying task
            def self.it_should_be_configurable
                it "should be configurable" do
                    syskit_stub_deploy_and_configure(self.class.subject_syskit_model)
                end
            end

            def self.ensure_can_deploy_subject_syskit_model(test, app)
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
                        test.skip("#{test.__full_name__} cannot run: oroGen project #{project_name} is not available")
                    end
                end
            end

            def self.roby_should_run(test, app)
                super
                ensure_can_deploy_subject_syskit_model(test, app)
            end
        end
    end
end

