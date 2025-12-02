# frozen_string_literal: true

require "syskit/test/self"
require "syskit/schedulers/global"

module Syskit
    module Schedulers
        describe Global do
            before do
                @scheduler = Global.new(plan)
            end

            it "schedules the configuration precedence task of a non-executable task" do
                task_m = TaskContext.new_submodel
                plan.add(root = task_m.new)
                root.depends_on(precedence = task_m.new)
                precedence.executable = true
                root.should_configure_after(precedence.start_event)

                assert_scheduled_tasks([precedence])
            end

            it "does not schedule the configuration precedence if " \
               "it is itself not executable" do
                task_m = TaskContext.new_submodel
                plan.add(root = task_m.new)
                root.depends_on(precedence = task_m.new)
                root.should_configure_after(precedence.start_event)

                assert_scheduled_tasks([])
            end

            def assert_scheduled_tasks(set)
                assert_equal set.to_set, @scheduler.compute_tasks_to_schedule
            end
        end
    end
end
