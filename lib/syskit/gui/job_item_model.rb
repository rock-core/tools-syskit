module Syskit
    module GUI
        # @api private
        #
        # Expose job information to the Qt model system
        class JobItemModel < Qt::StandardItemModel
            class JobInfo
                attr_reader :job_id
                attr_reader :placeholder_task
                attr_reader :job_task

                attr_reader :name

                def initialize(job_id)
                    @job_id = job_id
                end

                def update_job_tasks(placeholder_task, job_task)
                    @placeholder_task = placeholder_task
                    @job_task = job_task
                end

                def update_name(name)
                    @name = name

                    return unless @root_item
                    @root_item.text =
                        if name
                            "##{job_id} #{name}"
                        else
                            "##{job_id}"
                        end
                end

                def create_item_model
                    @root_item = Qt::StandardItem.new
                    @root_item.setData(Qt::Variant.new(@job_id), ROLE_JOB_ID)
                    @notifications_root_item = Qt::StandardItem.new("Notifications")
                    @tasks_root_item = Qt::StandardItem.new("Tasks")
                    @root_item.append_row(@notifications_root_item)
                    @root_item.append_row(@tasks_root_item)

                    update_name(@name)
                    @root_item
                end

                def has_created_items?
                    @root_item
                end

                def display_notifications_on_list(list_view)
                    list_view.model      = @notifications_root_item.model
                    list_view.root_index = @notifications_root_item.index
                end

                def take_model_from(model)
                    model.takeRow(@root_item.row)
                end

                ROLE_NOTIFICATION_TIME        = Qt::UserRole + 1
                ROLE_NOTIFICATION_CHILD_LABEL = Qt::UserRole + 2
                ROLE_NOTIFICATION_CHILD_TEXT  = Qt::UserRole + 3

                def move_notifications_to_top(items)
                    return if items.empty?

                    # Optimization if all items are consecutive (happens quite
                    # often)
                    items = items.sort_by(&:row)
                    is_consecutive = items.each_cons(2).
                        all? { |a, b| a.row + 1 == b.row }
                    if is_consecutive
                        return if items.first.row == 0 # Nothing to do

                        @notifications_root_item.model.begin_move_rows(
                            @notifications_root_item.index,
                            items.first.row, items.last.row,
                            @notifications_root_item.index, 0)
                        items.each do |item|
                            @notifications_root_item.take_row(item.row)
                        end
                        @notifications_root_item.insert_rows(0, items)
                        @notifications_root_item.model.end_move_rows()
                    else
                        # Keep relative order
                        items.each_with_index do |item, i|
                            # Nothing to be done, it's already where we want it
                            next if item.row == i

                            @notifications_root_item.model.begin_move_rows(
                                @notifications_root_item.index, item.row, item.row,
                                @notifications_root_item.index, i)
                            @notifications_root_item.take_row(item.row)
                            @notifications_root_item.insert_row(i, item)
                            @notifications_root_item.model.end_move_rows()
                        end
                    end
                end

                def add_notification_items(items)
                    return if items.empty?
                    @notifications_root_item.insert_rows(0, items)
                end

                def create_notification_item(notification)
                    child_label =
                        unless notification.task.empty?
                            "(#{notification.task})"
                        end

                    time = notification.time.strftime("%H:%M:%S.%3N") if notification.time
                    text = [time, child_label, notification.message].
                        compact.join(" ")
                    item = Qt::StandardItem.new(text)
                    item.setData(Qt::Variant.new(notification.time),
                        ROLE_NOTIFICATION_TIME)
                    item.setData(Qt::Variant.new(notification.task),
                        ROLE_NOTIFICATION_CHILD_LABEL)
                    item.setData(Qt::Variant.new(notification.message),
                        ROLE_NOTIFICATION_CHILD_TEXT)
                    item
                end
            end

            Notification = Struct.new :task, :time, :message

            attr_accessor :plan

            def initialize(plan, parent = nil)
                super(parent)
                @plan = plan
                @job_info = Hash.new
                @scheduler_messages = Hash.new
            end

            # Compute task labels (as role chains) from a given root
            #
            # This is used to label information about specific tasks
            class TaskLabelVisitor < RGL::DFSVisitor
                # Label information
                #
                # The information is a mapping from a task object to the set of
                # role chains from the root to the task
                #
                # @return [Array<Array<String>>]
                attr_reader :labels

                def initialize(graph, root)
                    super(graph)
                    @root = root
                    @labels = Hash.new
                    @labels[root] = [[]]
                end

                def handle_edge(u, v)
                    roles = graph.edge_info(u, v)[:roles]
                    chains = (@labels[v] ||= Array.new)
                    @labels[u].each do |role_chain|
                        new_chains = roles.map { |r| role_chain + [r] }
                        chains.concat(new_chains)
                    end
                end

                def handle_tree_edge(u, v)
                    handle_edge(u, v)
                end
                def handle_back_edge(u, v)
                    handle_edge(u, v)
                end
                def handle_forward_edge(u, v)
                    handle_edge(u, v)
                end

                # Compute the labels of all the children of a task in a graph
                #
                # @return (see TaskLabelVisitor#labels)
                def self.compute(graph, root_task)
                    visitor = new(graph, root_task)
                    graph.depth_first_visit(root_task, visitor) {}
                    visitor.labels
                end
            end

            # Compute the mapping from a job placeholder task to its job task
            def update_job_info(current_info)
                current_info = current_info.dup
                updated_jobs = Array.new
                new_jobs     = Array.new

                updated_info = @plan.each_task.each_with_object(Hash.new) do |t, result|
                    next unless t.kind_of?(Roby::Interface::Job) && (job_id = t.job_id)
                    next unless (placeholder_task = t.planned_task)

                    if (info = current_info.delete(job_id))
                        info.update_job_tasks(placeholder_task, t)
                        updated_jobs << job_id
                    else
                        info = JobInfo.new(job_id)
                        new_jobs << job_id
                    end
                    info.update_job_tasks(placeholder_task, t)
                    result[job_id] = info
                end

                [updated_info, updated_jobs, new_jobs, current_info]
            end

            # Compute the labels of tasks, as a mapping from the job or from the
            # task
            def compute_tasks_labels(job_root_tasks)
                job_to_task_labels = Hash.new
                dependency_graph = plan.
                    task_relation_graph_for(Roby::TaskStructure::Dependency)
                job_root_tasks.each do |job_task|
                    job_to_task_labels[job_task] = TaskLabelVisitor.
                        compute(dependency_graph, job_task)
                end

                task_to_job_labels = Hash.new
                job_to_task_labels.each do |job, task_to_labels|
                    task_to_labels.each do |task, labels|
                        h = (task_to_job_labels[task] ||= Hash.new)
                        h[job] = labels
                    end
                end

                [job_to_task_labels, task_to_job_labels]
            end

            # All the known tasks
            def all_tasks
                @task_to_job_labels.keys
            end

            # Tests whether a task is a logging task
            def logger_task?(t)
                return if @logger_m == false
                @logger_m ||= Syskit::TaskContext.
                    find_model_from_orogen_name('logger::Logger') || false
                t.kind_of?(@logger_m)
            end

            # Filter out the loggers in the given set of tasks
            def filter_out_loggers(tasks)
                if !@known_loggers
                    @known_loggers = Set.new
                    all_tasks.each do |t|
                        @known_loggers << t if logger_task?(t)
                    end
                end

                tasks.find_all do |t|
                    if @known_loggers.include?(t)
                        false
                    elsif logger_task?(t)
                        @known_loggers << t
                        false
                    else true
                    end
                end
            end

            ROLE_JOB_ID = Qt::UserRole + 1
            ROLE_NOTIFICATION_TIME = Qt::UserRole + 1

            # Update the model from a new plan state
            def update(time = Time.now)
                @job_info, =
                    update_job_info(@job_info)
                @job_info.each_value do |info|
                    unless info.has_created_items?
                        appendRow(info.create_item_model)
                    end
                end

                @jobs_to_task_labels, @task_to_job_labels =
                    compute_tasks_labels(@job_info.each_value.map(&:placeholder_task))

                @plan.scheduler_states.each do |state|
                    update_scheduler_state(time, state)
                end
                update_events
            end

            def update_events(events = @plan.emitted_events)
                notifications = events.map do |event|
                    next unless event.respond_to?(:task)
                    Notification.new(event.task, event.time, event.symbol.to_s)
                end
                add_notifications(notifications)
            end

            def update_scheduler_state(time, state)
                notifications = Array.new

                state.pending_non_executable_tasks.each do |msg, *args|
                    formatted_msg = Roby::Schedulers::State.format_message_into_string(msg, *args)
                    args.each do |obj|
                        if obj.kind_of?(Roby::Task)
                            notifications << Notification.new(obj, nil, formatted_msg)
                        end
                    end
                end
                state.non_scheduled_tasks.each do |task, messages|
                    messages.each do |msg, *args|
                        formatted_msg = Roby::Schedulers::State.format_message_into_string(msg, task, *args)
                        notifications << Notification.new(task, nil, formatted_msg)
                    end
                end

                state.actions.each do |task, messages|
                    messages.each do |msg, *args|
                        formatted_msg = Roby::Schedulers::State.format_message_into_string(msg, task, *args)
                        notifications << Notification.new(task, time, formatted_msg)
                    end
                end

                current_messages = @scheduler_messages
                @scheduler_messages =
                    add_notifications(notifications, items: current_messages)
                used_items, old_items = [@scheduler_messages, current_messages].
                    map do |task2msg2job2items|
                        task2msg2job2items.each_value.flat_map do |msg2job2items|
                            msg2job2items.each_value.flat_map do |job2items|
                                job2items.values
                            end
                        end.to_set
                    end

                old_items.each do |item|
                    next if used_items.include?(item)
                    item.parent.take_row(item.row)
                end
            end

            def update_job_name(job_id, job_name)
                fetch_or_create_job_info(job_id).update_name(job_name)
            end

            def add_notifications(notifications, items: Hash.new)
                per_job = notifications.each_with_object(Hash.new) do |n, result|
                    next unless (jobs_and_labels = @task_to_job_labels[n.task])
                    jobs_and_labels.map do |job_task, chains|
                        next unless (job_id = job_task.planning_task&.job_id)
                        child_label = chains.first.join(".")
                        notification = n.dup
                        notification.task = child_label
                        (result[job_id] ||= Array.new) <<
                            [n.task, notification]
                    end
                end

                per_job.each_with_object(Hash.new) do |(job_id, messages), result_items|
                    job_info = fetch_job_info(job_id)

                    new_messages_without_time, new_messages, updated_messages =
                        Array.new, Array.new, Array.new
                    messages.each do |task, n|
                        if !n.time
                            if (item = items.dig(task, n.message, job_id))
                                updated_messages << item
                            else
                                item = job_info.create_notification_item(n)
                                new_messages_without_time << item
                            end
                        else
                            item = job_info.create_notification_item(n)
                            new_messages << item
                        end
                        unless n.time
                            result_items[task] ||= Hash.new
                            result_items[task][n.message] ||= Hash.new
                            result_items[task][n.message][job_id] = item
                        end
                    end

                    job_info.add_notification_items(new_messages.reverse)
                    job_info.move_notifications_to_top(updated_messages.reverse)
                    job_info.add_notification_items(new_messages_without_time.reverse)
                end
            end

            def fetch_job_info(job_id)
                @job_info.fetch(job_id)
            end

            def fetch_or_create_job_info(job_id)
                if (info = @job_info[job_id])
                    return info
                end

                info = JobInfo.new(job_id)
                @job_info[job_id] = info
                appendRow(info.create_item_model)
                info
            end
        end
    end
end
