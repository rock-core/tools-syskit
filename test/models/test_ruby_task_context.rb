# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe RubyTaskContext do
            describe "#deployed_as" do
                before do
                    @task_m = Syskit::RubyTaskContext.new_submodel(
                        orogen_model_name: "test::Task"
                    )
                    Syskit.conf.register_process_server(
                        "ruby_tasks",
                        Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader)
                    )
                end

                after do
                    teardown_registered_plans
                    Syskit.conf.remove_process_server("ruby_tasks")
                end

                def self.common_behavior(c)
                    c.it "uses the default deployment using the given name" do
                        task = @task_m.new
                        candidates = @ir
                                     .deployment_group
                                     .find_all_suitable_deployments_for(task)

                        assert_equal 1, candidates.size
                        c = candidates.first
                        assert_equal "ruby_tasks",
                                     c.configured_deployment.process_server_name
                        assert_equal "test", c.mapped_task_name
                        assert_equal(
                            { "task" => "test" },
                            c.configured_deployment.name_mappings
                        )
                    end
                end

                describe "called on the task model" do
                    before do
                        @ir = @task_m.deployed_as("test")
                    end

                    common_behavior(self)
                end

                describe "called on InstanceRequirements" do
                    before do
                        @ir = Syskit::InstanceRequirements
                              .new([@task_m])
                              .deployed_as("test")
                    end

                    common_behavior(self)
                end
            end
        end
    end
end
