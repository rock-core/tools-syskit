require 'syskit/test/self'
require 'roby/droby/rebuilt_plan'
require 'syskit/gui/job_item_model'

module Syskit
    module GUI
        describe JobItemModel do
            before do
                @rebuilt_plan = Roby::DRoby::RebuiltPlan.new
                @model = JobItemModel.new(@rebuilt_plan)

                @task_m = Roby::Task.new_submodel
                @job_m = Roby::Task.new_submodel
                @job_m.provides Roby::Interface::Job
            end

            describe "#update_job_info" do
                it "returns an empty hash if there are no jobs" do
                    assert_equal [Hash.new, [], [], Hash.new],
                        @model.update_job_info(Hash.new)
                end
                it "matches a job and its placeholder" do
                    @rebuilt_plan.add(placeholder_task = @task_m.new)
                    @rebuilt_plan.add(job_task = @job_m.new(job_id: 42))
                    placeholder_task.planned_by(job_task)
                    updated_info, *updates =
                        @model.update_job_info(Hash.new)
                    assert_equal [[], [42], Hash.new], updates
                    assert_equal [42], updated_info.keys
                    assert_equal 42, updated_info[42].job_id
                    assert_equal placeholder_task, updated_info[42].placeholder_task
                    assert_equal job_task, updated_info[42].job_task
                end
                it "ignores jobs that are not planning tasks" do
                    @rebuilt_plan.add(@job_m.new(job_id: 42))
                    assert_equal [Hash.new, [], [], Hash.new],
                        @model.update_job_info(Hash.new)
                end
                it "ignores jobs that do not have a job ID" do
                    @rebuilt_plan.add(placeholder_task = @task_m.new)
                    @rebuilt_plan.add(job_task = @job_m.new(job_id: nil))
                    placeholder_task.planned_by(job_task)
                    assert_equal [Hash.new, [], [], Hash.new],
                        @model.update_job_info(Hash.new)
                end
            end

            describe "#compute_tasks_labels" do
                before do
                    @rebuilt_plan.add(@root_task = @task_m.new)
                end

                it "sets the children to an empty hash if there are no children" do
                    job2labels, tasks2labels = @model.compute_tasks_labels([@root_task])
                    assert_equal Hash[@root_task => Hash[@root_task => [[]]]],
                        job2labels
                    assert_equal Hash[@root_task => Hash[@root_task => [[]]]],
                        tasks2labels
                end

                it "handles a simple chain" do
                    @root_task.depends_on(child = @task_m.new, role: 'child')
                    child.depends_on(grandchild = @task_m.new, role: 'grandchild')
                    job2labels, tasks2labels = @model.compute_tasks_labels([@root_task])
                    e_job2labels = Hash[
                        @root_task => Hash[
                            @root_task => [[]],
                            child => [['child']],
                            grandchild => [['child', 'grandchild']]
                        ]
                    ]
                    e_tasks2labels = Hash[
                        @root_task => Hash[@root_task => [[]]],
                        child => Hash[@root_task => [['child']]],
                        grandchild => Hash[@root_task => [['child', 'grandchild']]]
                    ]
                    assert_equal e_job2labels, job2labels
                    assert_equal e_tasks2labels, tasks2labels
                end

                it "handles DAGs" do
                    @root_task.depends_on(child0 = @task_m.new, role: 'child0')
                    @root_task.depends_on(child1 = @task_m.new, role: 'child1')
                    grandchild = @task_m.new
                    child0.depends_on(grandchild, role: 'grandchild')
                    child1.depends_on(grandchild, role: 'grandchild')
                    job2labels, tasks2labels = @model.compute_tasks_labels([@root_task])
                    e_job2labels = Hash[
                        @root_task => Hash[
                            @root_task => [[]],
                            child0 => [['child0']],
                            child1 => [['child1']],
                            grandchild => [
                                ['child0', 'grandchild'],
                                ['child1', 'grandchild']
                            ]
                        ]
                    ]
                    e_tasks2labels = Hash[
                        @root_task => Hash[@root_task => [[]]],
                        child0 => Hash[@root_task => [['child0']]],
                        child1 => Hash[@root_task => [['child1']]],
                        grandchild => Hash[@root_task => [
                                ['child0', 'grandchild'],
                                ['child1', 'grandchild']
                            ]
                        ]
                    ]
                    assert_equal e_job2labels, job2labels
                    assert_equal e_tasks2labels, tasks2labels
                end

                it "handles children having multiple roles" do
                    @root_task.depends_on(child0 = @task_m.new, roles: ['child0', 'other0'])
                    @root_task.depends_on(child1 = @task_m.new, role: 'child1')
                    grandchild = @task_m.new
                    child0.depends_on(grandchild, role: 'grandchild')
                    child1.depends_on(grandchild, role: 'grandchild')
                    job2labels, tasks2labels = @model.compute_tasks_labels([@root_task])
                    e_job2labels = Hash[
                        @root_task => Hash[
                            @root_task => [[]],
                            child0 => [['child0'], ['other0']],
                            child1 => [['child1']],
                            grandchild => [
                                ['child0', 'grandchild'],
                                ['other0', 'grandchild'],
                                ['child1', 'grandchild']
                            ]
                        ]
                    ]
                    e_tasks2labels = Hash[
                        @root_task => Hash[@root_task => [[]]],
                        child0 => Hash[@root_task => [['child0'], ['other0']]],
                        child1 => Hash[@root_task => [['child1']]],
                        grandchild => Hash[@root_task => [
                                ['child0', 'grandchild'],
                                ['other0', 'grandchild'],
                                ['child1', 'grandchild']
                            ]
                        ]
                    ]
                    assert_equal e_job2labels, job2labels
                    assert_equal e_tasks2labels, tasks2labels
                end
            end

            describe "#update" do
                before do
                    @rebuilt_plan.add_mission_task(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end

                it "adds new jobs to the model" do
                    assert_equal 1, @model.rowCount
                    item = @model.item(0)
                    assert_equal "#42", item.text
                    assert_equal 42, item.data(JobItemInfo::ROLE_JOB_ID).to_int
                end

                it "updates existing jobs, updating the existing item" do
                    old_job_info = @model.fetch_job_info(42)
                    @model.update
                    assert_equal old_job_info, @model.fetch_job_info(42)
                end
            end

            describe "#queue_generator_fired" do
                before do
                    @rebuilt_plan.add_mission_task(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end

                it "associates root task events with jobs" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.queue_generator_fired(@task.start_event.new([], 1, t))
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 start")
                end

                it "associates child task events with jobs" do
                    @task.depends_on(child = @task_m.new, role: 'some')
                    child.depends_on(grandchild = @task_m.new, role: 'child')
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.queue_generator_fired(grandchild.start_event.new([], 1, t))
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 (some.child) start")
                end

                it "displays job planning task events with the 'planning' prefix" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.queue_generator_fired(
                        @task.planning_task.start_event.new([], 1, t))
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 planning:start")
                end
            end

            describe "#garbage_task" do
                before do
                    @rebuilt_plan.add(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end

                it "tracks a placeholder task events after it is dropped" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    # 'dropping' removes the planning task explicitely
                    @task.remove_planning_task(@task.planning_task)
                    @model.queue_generator_fired(@task.stop_event.new([], 1, t))
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 stop")
                end

                it "tracks a job and its children events during garbage collection" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @task.depends_on(child = @task_m.new, role: 'child')
                    # 'dropping' removes the planning task explicitely
                    @task.remove_planning_task(@task.planning_task)
                    @model.garbage_task(@task)
                    @model.queue_generator_fired(@task.stop_event.new([], 1, t))
                    @model.queue_generator_fired(child.stop_event.new([], 1, t))
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 stop", row: 1)
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 (child) stop", row: 0)
                end
            end

            describe "#remove_job" do
                before do
                    @rebuilt_plan.add(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end

                it "removes the items from the model" do
                    @model.remove_job(42)
                    assert_equal 0, @model.row_count
                end

                it "disconnects the job info from the model signals" do
                    flexmock(@model.fetch_job_info(42)).
                        should_receive(:rows_inserted).
                        never
                    flexmock(@model.fetch_job_info(42)).
                        should_receive(:rows_about_to_be_removed).
                        never
                    @model.remove_job(42)
                    @model.update
                end

                it "discards previous the notification messages" do
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "x", 42, "")])
                    @model.remove_job(42)
                    @model.update
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "x", 42, "")])
                    assert_has_notification @model.item(0), count: 1, text: "x"
                end
            end

            describe "#update_job_name" do
                before do
                    @rebuilt_plan.add_mission_task(task = @task_m.new)
                    task.planned_by(@job_m.new(job_id: 42))
                end
                it "changes the name of a known job" do
                    @model.update
                    @model.update_job_name(42, 'test')
                    assert_equal 'test', @model.fetch_job_info(42).name
                    assert_equal "#42 test", @model.item(0).text
                end
                it "creates the item as soon as the job name and ID are known" do
                    @model.update_job_name(42, 'test')
                    assert_equal "#42 test", @model.item(0).text
                end
            end

            describe "#add_notifications" do
                before do
                    @rebuilt_plan.add_mission_task(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end
                it "displays notifications for the job task itself" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, t, "start", 42, "")])
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 start")
                end
                it "dispatches notifications for the child to the job item" do
                    @task.depends_on(child = @task_m.new, role: 'some')
                    child.depends_on(grandchild = @task_m.new, role: 'child')
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.update
                    @model.add_notifications(
                        [JobItemModel::Notification.new(grandchild, t, "start", 42, "some.child")])
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 (some.child) start")
                end
                it "expects messages in chronological order"\
                    "and displays them in inverse" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, t, "start", 42, ""),
                        JobItemModel::Notification.new(@task, t, "middle", 42, ""),
                        JobItemModel::Notification.new(@task, t, "stop", 42, "")])
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 stop", row: 0)
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 middle", row: 1)
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 start", row: 2)
                end
                it "displays messages without time on top of the other messages"\
                    "and displays them in inverse" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "timeless", 42, ""),
                        JobItemModel::Notification.new(@task, t, "start", 42, "")])
                    assert_has_notification(@model.item(0),
                        text: "timeless", row: 0)
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 start", row: 1)
                end
                it "returns the mapping from task, job and message text to the item "\
                    "for messages whose time is nil" do
                    @task.depends_on(child = @task_m.new, role: 'some')
                    child.depends_on(grandchild = @task_m.new, role: 'child')
                    @model.update
                    result = @model.add_notifications(
                        [JobItemModel::Notification.new(grandchild, nil, "start", 42, "")])
                    expected = Hash[
                        grandchild => {
                            "start" => { 42 => find_first_notification(@model.item(0)) }
                        }
                    ]
                    assert_equal expected, result
                end
                it "does not include messages with time in the returned mapping" do
                    result = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, Time.now, "start", 42, "")])
                    assert_equal Hash.new, result
                end
                it "reuses existing items for messages whose time is nil" do
                    existing = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start", 42, "")])
                    new_existing = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start", 42, "")])
                    assert_equal existing, new_existing
                end
                it "ignores existing items for messages with a time" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start", 42, "")])
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, t, "start", 42, "")])
                    assert_has_notification @model.item(0), count: 1,
                        text: "16:32:05.040 start"
                end
                it "moves existing notifications to the top" do
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "x", 42, ""),
                         JobItemModel::Notification.new(@task, nil, "y", 42, "")])
                    assert_has_notification @model.item(0),
                        count: 2, text: "x", row: 1
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "x", 42, "")])
                    assert_has_notification @model.item(0),
                        count: 1, text: "x", row: 0
                end
                it "applies an optimization for consecutive notifications" do
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "x", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "y", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "z", 42, "")])
                    assert_has_notification @model.item(0),
                        count: 3, text: "y", row: 1
                    assert_has_notification @model.item(0),
                        count: 3, text: "x", row: 2
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "x", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "y", 42, "")])
                    assert_has_notification @model.item(0),
                        count: 2, text: "y", row: 0
                    assert_has_notification @model.item(0),
                        count: 2, text: "x", row: 1
                end
                it "handles notifications that are not consecutive" do
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "a", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "b", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "c", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "d", 42, "")])

                    assert_has_notification @model.item(0),
                        count: 4, text: "c", row: 1
                    assert_has_notification @model.item(0),
                        count: 4, text: "a", row: 3

                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "a", 42, ""),
                        JobItemModel::Notification.new(@task, nil, "c", 42, "")])

                    assert_has_notification @model.item(0),
                        count: 2, text: "c", row: 0
                    assert_has_notification @model.item(0),
                        count: 2, text: "a", row: 1
                end
                it "accounts for new notifications" do
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "a", 42, "", 1)])
                    assert_equal Hash['' => 1],
                        @model.fetch_job_info(42).notification_count(1)
                end
                it "accounts for removed notifications" do
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "a", 42, "", 1)])
                    item = assert_has_notification(@model.item(0), count: 1)
                    item.parent.take_row(item.row)
                    assert_equal Hash['' => 0],
                        @model.fetch_job_info(42).notification_count(1)
                end
                it "ignores a duplicate notification" do
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "a", 42, "", 1),
                        JobItemModel::Notification.new(@task, nil, "a", 42, "", 1)])
                    assert_has_notification @model.item(0), count: 1
                end
            end

            def find_first_notification(root_item)
                notification_root_item = root_item.child(0, 0)
                notification_root_item.child(0, 0)
            end

            def assert_has_notification(root_item, count: nil, text: nil, row: 0)
                notification_root_item = root_item.child(0, 0)
                if count
                    assert_equal count, notification_root_item.row_count
                    return if count == 0
                end

                if row
                    item = notification_root_item.child(row, 0)
                end

                if text
                    refute_nil item, "no notifications"
                    assert_equal text, item.text
                end
                item
            end
        end
    end
end
