# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe RubyTaskContext do
        attr_reader :task_m
        before do
            @task_m = RubyTaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            Syskit.conf.register_process_server(
                "ruby_tasks",
                Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader)
            )
        end

        after do
            teardown_registered_plans
            Syskit.conf.remove_process_server("ruby_tasks")
        end

        it "allows to specify a component interface and have it deployed" do
            use_ruby_tasks task_m => "test"
            task = syskit_deploy_configure_and_start(task_m)
            assert_kind_of RubyTaskContext, task
            assert_equal "test", task.orocos_name

            remote_task = Orocos.allow_blocking_calls { Orocos.name_service.get("test") }
            assert_equal remote_task, task.orocos_task
            Orocos.allow_blocking_calls do
                assert_equal remote_task.in, task.orocos_task.in
                assert_equal remote_task.out, task.orocos_task.out
            end
        end

        it "allows writing and reading from the task's handlers" do
            task_m.poll do
                while (sample = orocos_task.in.read_new)
                    orocos_task.out.write(sample * 2)
                end
            end
            use_ruby_tasks task_m => "test"
            task = syskit_deploy_configure_and_start(task_m)

            reader = Orocos.allow_blocking_calls do
                writer = task.orocos_task.in.writer(type: :buffer, size: 2)
                writer.write 1
                writer.write 2
                task.orocos_task.out.reader(type: :buffer, size: 2)
            end

            samples = []
            expect_execution.to do
                achieve do
                    if (sample = reader.read_new)
                        samples << sample
                    end
                    samples.size == 2
                end
            end
            assert_equal [2, 4], samples
        end

        it "allows to optionally resolve the created task as a remote task" do
            use_ruby_tasks({ task_m => "test" }, remote_task: true)
            task = syskit_deploy_configure_and_start(task_m)
            assert_kind_of Orocos::RubyTasks::RemoteTaskContext, task.orocos_task
        end
    end
end
