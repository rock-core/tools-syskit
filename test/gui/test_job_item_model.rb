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
                    @rebuilt_plan.add(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end

                it "adds new jobs to the model" do
                    assert_equal 1, @model.rowCount
                    item = @model.item(0)
                    assert_equal "#42", item.text
                    assert_equal 42, item.data(JobItemModel::ROLE_JOB_ID).to_int
                end

                it "updates existing jobs, updating the existing item" do
                    old_job_info = @model.fetch_job_info(42)
                    @model.update
                    assert_equal old_job_info, @model.fetch_job_info(42)
                end

                it "associates root task events with jobs" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @rebuilt_plan.emitted_events <<
                        @task.start_event.new([], 1, t)
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 start")
                end

                it "associates child task events with jobs" do
                    @task.depends_on(child = @task_m.new, role: 'some')
                    child.depends_on(grandchild = @task_m.new, role: 'child')
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @rebuilt_plan.emitted_events <<
                        grandchild.start_event.new([], 1, t)
                    @model.update
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 (some.child) start")
                end
            end

            describe "#update_job_name" do
                before do
                    @rebuilt_plan.add(task = @task_m.new)
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
                    @rebuilt_plan.add(@task = @task_m.new)
                    @task.planned_by(@job_m.new(job_id: 42))
                    @model.update
                end
                it "displays notifications for the job task itself" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, t, "start")])
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 start")
                end
                it "dispatches notifications for the child to the job item" do
                    @task.depends_on(child = @task_m.new, role: 'some')
                    child.depends_on(grandchild = @task_m.new, role: 'child')
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.update
                    @model.add_notifications(
                        [JobItemModel::Notification.new(grandchild, t, "start")])
                    assert_has_notification(@model.item(0),
                        text: "16:32:05.040 (some.child) start")
                end
                it "expects messages in chronological order"\
                    "and displays them in inverse" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, t, "start"),
                        JobItemModel::Notification.new(@task, t, "middle"),
                        JobItemModel::Notification.new(@task, t, "stop")])
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
                        JobItemModel::Notification.new(@task, nil, "timeless"),
                        JobItemModel::Notification.new(@task, t, "start")])
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
                        [JobItemModel::Notification.new(grandchild, nil, "start")])
                    expected = Hash[
                        grandchild => {
                            "start" => { 42 => find_first_notification(@model.item(0)) }
                        }
                    ]
                    assert_equal expected, result
                end
                it "does not include messages with time in the returned mapping" do
                    result = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, Time.now, "start")])
                    assert_equal Hash.new, result
                end
                it "reuses existing items for messages whose time is nil" do
                    existing = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start")])
                    new_existing = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start")],
                        items: existing)
                    assert_equal existing, new_existing
                end
                it "ignores existing items for messages with a time" do
                    existing = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start")])
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, Time.now, "start")],
                        items: existing)
                    assert_has_notification @model.item(0), count: 2
                end
                it "moves existing notifications to the top" do
                    existing = @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start")])
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, Time.now, "start")])
                    assert_has_notification @model.item(0),
                        count: 2, text: "start", row: 1
                    @model.add_notifications(
                        [JobItemModel::Notification.new(@task, nil, "start")],
                        items: existing)
                    assert_has_notification @model.item(0),
                        count: 2, text: "start", row: 0
                end
                it "applies an optimization for consecutive notifications" do
                    existing = @model.add_notifications([
                        JobItemModel::Notification.new(@task, Time.now, "start"),
                        JobItemModel::Notification.new(@task, nil, "start"),
                        JobItemModel::Notification.new(@task, nil, "stop")])
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "start"),
                        JobItemModel::Notification.new(@task, nil, "stop")],
                        items: existing)
                    assert_has_notification @model.item(0),
                        count: 3, text: "stop", row: 0
                    assert_has_notification @model.item(0),
                        count: 3, text: "start", row: 1
                end
                it "handles notifications that are not consecutive" do
                    t = Time.gm(2018, 02, 24, 16, 32, 5.04)
                    existing = @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "start")])
                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, t, "start")])
                    existing1 = @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "stop")])
                    existing[@task].merge!(existing1[@task])

                    assert_has_notification @model.item(0),
                        count: 3, text: "stop", row: 0
                    assert_has_notification @model.item(0),
                        count: 3, text: "start", row: 2

                    @model.add_notifications([
                        JobItemModel::Notification.new(@task, nil, "start"),
                        JobItemModel::Notification.new(@task, nil, "stop")],
                        items: existing)

                    assert_has_notification @model.item(0),
                        count: 3, text: "stop", row: 0
                    assert_has_notification @model.item(0),
                        count: 3, text: "start", row: 1
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
                end

                if text
                    item = notification_root_item.child(row, 0)
                    refute_nil item
                    assert_equal text, item.text
                end
            end
        end
    end
end
