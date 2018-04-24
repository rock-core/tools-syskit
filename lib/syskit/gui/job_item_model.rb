require 'syskit/gui/job_item_info'
require 'syskit/gui/job_state_rebuilder'

module Syskit
    module GUI
        # @api private
        #
        # Expose job information to the Qt model system
        class JobItemModel < Qt::StandardItemModel
            Notification = Struct.new :task, :time, :message, :job_id, :role, :type,
                :extended_message

            NOTIFICATION_SCHEDULER_PENDING     = 1
            NOTIFICATION_SCHEDULER_HOLDOFF     = 2
            NOTIFICATION_SCHEDULER_ACTION      = 3
            NOTIFICATION_EVENT_EMITTED         = 4
            NOTIFICATION_EVENT_EMISSION_FAILED = 5
            NOTIFICATION_EXCEPTION_FATAL       = 6
            NOTIFICATION_EXCEPTION_HANDLED     = 7

            attr_accessor :plan

            def initialize(plan, parent = nil)
                super(parent)
                @plan = plan
                @job_info = Hash.new
                @notification_state = Hash.new
                @pending_notifications = Array.new
                @emitted_events = Hash.new
                @pending_forwards = Hash.new
            end

            def queue_notification(notification)
                @pending_notifications << notification
                notification
            end

            def remove_job(job_id)
                @job_info.delete(job_id).take_from(self)
                @notification_state.delete_if do |task, message2job2item|
                    message2job2item.delete_if do |message, job2item|
                        job2item.delete(job_id)
                        job2item.empty?
                    end
                    message2job2item.empty?
                end
            end

            def find_job_id(task)
                (job_task = task.planning_task) &&
                    job_task.kind_of?(Roby::Interface::Job) &&
                    job_task.job_id
            end

            def find_jobs_of_task(task)
                dependency_graph = task.relation_graph_for(
                    Roby::TaskStructure::Dependency)
                labels = TaskLabelVisitor.compute(
                    dependency_graph.reverse, task)
                has_mission = labels.each_key.any?(&:mission?)

                if has_mission
                    labels.each_with_object(Hash.new) do |(t, chain), result|
                        if job_id = find_job_id(t)
                            result[job_id] = chain
                        end
                    end
                else
                    @job_info.each_value.each_with_object(Hash.new) do |info, result|
                        if (roles = info.find_roles_from_snapshot(task))
                            result[info.job_id] = roles
                        end
                    end
                end
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
                        info = JobItemInfo.new(job_id)
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

            # Update the model from a new plan state
            def update(time = Time.now)
                current_job_info, _new, _updated, finalized_jobs =
                    update_job_info(@job_info)
                @job_info = current_job_info.merge(finalized_jobs)
                @job_info.each_value do |info|
                    unless info.has_created_items?
                        info.add_to(self)
                    end
                end

                current_placeholder_tasks = current_job_info.each_value.
                    map(&:placeholder_task)
                @jobs_to_task_labels, @task_to_job_labels =
                    compute_tasks_labels(current_placeholder_tasks)

                update_execution_agents(@jobs_to_task_labels)

                add_notifications(@pending_notifications)
                @pending_notifications = Array.new
                @pending_forwards = Hash.new
                @emitted_events = Hash.new
            end

            def update_execution_agents(jobs_to_task_labels)
                jobs_to_task_labels.each do |job_task, task2labels|
                    next unless (job_id = find_job_id(job_task))

                    fetch_job_info(job_id).execution_agents = task2labels.
                        each_with_object(Hash.new) do |(task, labels), result|
                            if (agent = task.execution_agent)
                                (result[agent] ||= Array.new) << labels.first.join(".")
                            end
                        end
                end
            end

            def remove_old_notification_items(old, new)
                old_items, new_items = [old, new].
                    map do |task2msg2job2items|
                        task2msg2job2items.each_value.flat_map do |msg2job2items|
                            msg2job2items.each_value.flat_map do |job2items|
                                job2items.values
                            end
                        end.to_set
                    end

                old_items.each do |item|
                    item.parent.take_row(item.row) unless new_items.include?(item)
                end
            end

            def update_job_name(job_id, job_name)
                fetch_or_create_job_info(job_id).update_name(job_name)
            end

            def add_notifications(notifications)
                old_notification_state = @notification_state

                per_job = notifications.each_with_object(Hash.new) do |n, result|
                    next unless @job_info.has_key?(n.job_id)
                    (result[n.job_id] ||= Array.new) << n
                    next
                end

                @notification_state = per_job.each_with_object(Hash.new) do |(job_id, messages), result_items|
                    job_info = fetch_job_info(job_id)

                    new_messages_without_time, new_messages, updated_messages =
                        Array.new, Array.new, Array.new
                    messages.each do |n|
                        if n.time
                            item = job_info.create_notification_item(n)
                            new_messages << item
                        elsif result_items.dig(n.task, n.message, job_id)
                            next
                        else
                            if (item = old_notification_state.dig(n.task, n.message, job_id))
                                updated_messages << item
                            else
                                item = job_info.create_notification_item(n)
                                new_messages_without_time << item
                            end

                            result_items[n.task] ||= Hash.new
                            result_items[n.task][n.message] ||= Hash.new
                            result_items[n.task][n.message][job_id] = item
                        end
                    end

                    updated_messages = updated_messages.uniq
                    job_info.add_notification_items(new_messages.reverse)
                    job_info.move_notifications_to_top(updated_messages.reverse)
                    job_info.add_notification_items(new_messages_without_time.reverse)
                end

                remove_old_notification_items(old_notification_state, @notification_state)
                @notification_state
            end

            def fetch_job_info(job_id)
                @job_info.fetch(job_id)
            end

            def fetch_or_create_job_info(job_id)
                if (info = @job_info[job_id])
                    return info
                end

                info = JobItemInfo.new(job_id)
                @job_info[job_id] = info
                info.add_to(self)
                info
            end

            def queue_rebuilder_notification(
                task, time, message, type, extended_message = "")

                jobs = find_jobs_of_task(task)
                jobs.map do |job_id, chain|
                    role = chain.first.reverse.join(".")
                    notification = Notification.new(task, time, message, job_id,
                        role, type, extended_message)
                    queue_notification(notification)
                    notification
                end
            end

            def queue_generator_fired(event)
                if (forwarded_from = @pending_forwards.delete(event.generator))
                    return queue_forwarded_event(event, forwarded_from)
                end

                extended_message = PP.pp(event, "")
                if event.task.kind_of?(Roby::Interface::Job) && event.task.job_id
                    if planned_task = event.task.planned_task
                        queue_rebuilder_notification(planned_task, event.time,
                            "planning:#{event.symbol.to_s}", NOTIFICATION_EVENT_EMITTED,
                            extended_message)
                    end
                end

                @emitted_events[[event.time, event.generator]] =
                    queue_rebuilder_notification(event.task, event.time,
                        event.symbol.to_s, NOTIFICATION_EVENT_EMITTED, extended_message)
            end

            def queue_forwarded_event(event, forwarded_from)
                forwarded_from.each do |ev|
                    notifications = @emitted_events[[ev.time, ev.generator]]
                    @emitted_events[[event.time, event.generator]] = notifications
                    notifications.each do |existing|
                        existing.message += " -> #{event.symbol}"
                        existing.extended_message =
                            "event '#{event.symbol}' emitted at "\
                            "[#{Roby.format_time(event.time)} @#{event.propagation_id}]"\
                            "\n#{existing.extended_message}"
                    end
                end
            end

            def queue_generator_emit_failed(time, generator, error)
                return unless generator.respond_to?(:task)
                extended_message = PP.pp(error, "")
                queue_rebuilder_notification(generator.task, time,
                    "emission of #{generator.symbol.to_s} failed",
                    NOTIFICATION_EVENT_EMISSION_FAILED, extended_message)
            end

            def queue_generator_forward_events(time, events, generator)
                return unless generator.respond_to?(:task)
                events = events.find_all do |ev|
                    ev.respond_to?(:task) && ev.task == generator.task
                end
                @pending_forwards[generator] = events unless events.empty?
            end

            def garbage_task(task)
                jobs = find_jobs_of_task(task)
                jobs.each do |job_id, chains|
                    fetch_job_info(job_id).snapshot if chains == [[]]
                end
            end

            def localized_error_summary(exception)
                exception_class =
                    if exception.respond_to?(:exception_class)
                        exception.exception_class.name
                    else
                        exception.class.name
                    end

                if (failed_generator = exception.failed_generator)
                    "#{exception_class} from #{failed_generator.symbol}"
                else
                    exception_class.dup
                end
            end

            EXCEPTION_MODE_TO_NOTIFICATION_TYPE = Hash[
                fatal:   NOTIFICATION_EXCEPTION_FATAL,
                handled: NOTIFICATION_EXCEPTION_HANDLED
            ].freeze

            def queue_localized_error(time, mode, error, involved_objects)
                return unless error.failed_task

                job_roles = find_jobs_of_task(error.failed_task)
                involved_objects.each do |obj|
                    next unless (job_id = find_job_id(obj))

                    roles = job_roles[job_id]
                    role  = roles.first.join(".")
                    type  = EXCEPTION_MODE_TO_NOTIFICATION_TYPE[mode]
                    message = "#{mode} exception #{localized_error_summary(error)}"
                    extended_message =
                        if error.respond_to?(:formatted_message)
                            error.formatted_message.join("\n")
                        else
                            PP.pp(error, "")
                        end
                    queue_notification(Notification.new(
                        error.failed_task, time, message, job_id, role, type,
                        extended_message))
                end
            end
        end
    end
end
