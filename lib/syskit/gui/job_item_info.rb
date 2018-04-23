module Syskit
    module GUI
        class JobItemInfo < Qt::Object
            attr_reader :job_id
            attr_reader :placeholder_task
            attr_reader :job_task

            attr_reader :name

            # The mapping from this job's tasks to the supporting execution agents
            #
            # This is updated by {JobItemModel#update}
            attr_reader :execution_agents

            def initialize(job_id)
                super()
                @job_id = job_id
                @snapshot = Hash.new
                @notification_messages = Hash.new
                @execution_agents = Hash.new
            end

            def execution_agents=(agents)
                if @execution_agents != agents
                    @execution_agents = agents
                    emit job_summary_updated()
                end
            end

            def update_job_tasks(placeholder_task, job_task)
                @placeholder_task = placeholder_task
                @job_task = job_task
            end

            def snapshot
                return @snapshot unless placeholder_task.plan

                dependency_graph = placeholder_task.
                    relation_graph_for(Roby::TaskStructure::Dependency)
                @snapshot = JobItemModel::TaskLabelVisitor.compute(
                    dependency_graph, placeholder_task)
            end

            def find_roles_from_snapshot(task)
                if task == placeholder_task
                    [[]]
                else
                    @snapshot[task]
                end
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

            # How many notifications of the given type are currently present
            #
            # @param [Integer] type the notification type as one of the
            #   `JobItemModel::NOTIFICATION_` constants (e.g.
            #   {JobItemModel::NOTIFICATION_SCHEDULER_PENDING})
            # @return [{String=>Integer}] per-role messages of the notifications
            def notifications_by_type(type)
                @notification_messages[type] || Hash.new
            end

            def add_to(model)
                item = create_item_model
                model.appendRow(item)
                connect \
                    model, SIGNAL('rowsInserted(const QModelIndex&, int, int)'),
                    self, SLOT('rows_inserted(const QModelIndex&, int, int)')
                connect \
                    model, SIGNAL('rowsAboutToBeRemoved(const QModelIndex&, int, int)'),
                    self, SLOT('rows_about_to_be_removed(const QModelIndex&, int, int)')
            end

            def take_from(model)
                disconnect \
                    model, SIGNAL('rowsInserted(const QModelIndex&, int, int)'),
                    self, SLOT('rows_inserted(const QModelIndex&, int, int)')
                disconnect \
                    model, SIGNAL('rowsAboutToBeRemoved(const QModelIndex&, int, int)'),
                    self, SLOT('rows_about_to_be_removed(const QModelIndex&, int, int)')
                model.takeRow(@root_item.row)
            end

            ROLE_JOB_ID = Qt::UserRole + 1

            ROLE_NOTIFICATION_TIME    = Qt::UserRole + 1
            ROLE_NOTIFICATION_ROLE    = Qt::UserRole + 2
            ROLE_NOTIFICATION_MESSAGE = Qt::UserRole + 3
            ROLE_NOTIFICATION_TYPE    = Qt::UserRole + 4

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

            def rows_inserted(parent_index, row_start, row_end)
                return unless parent_index == @notifications_root_item.index
                (row_start...row_end + 1).each do |row|
                    child = @notifications_root_item.child(row)
                    notification_messages_for(child) << child.text
                    emit job_summary_updated
                end
            end
            slots 'rows_inserted(const QModelIndex&, int, int)'

            def rows_about_to_be_removed(parent_index, row_start, row_end)
                return unless parent_index == @notifications_root_item.index
                (row_start...row_end + 1).each do |row|
                    child = @notifications_root_item.child(row)
                    notification_messages_for(child).delete(child.text)
                    emit job_summary_updated
                end
            end
            slots 'rows_about_to_be_removed(const QModelIndex&, int, int)'

            signals 'job_summary_updated()'

            private def notification_messages_for(item)
                role = item.data(ROLE_NOTIFICATION_ROLE).to_string
                type = item.data(ROLE_NOTIFICATION_TYPE).to_int
                messages_by_roles = (@notification_messages[type] ||= Hash.new)
                messages_by_roles[role] ||= Array.new
            end

            def create_notification_item(notification)
                role =
                    unless notification.role.empty?
                        "(#{notification.role})"
                    end

                time = notification.time.strftime("%H:%M:%S.%3N") if notification.time
                text = [time, role, notification.message].compact.join(" ")

                item = Qt::StandardItem.new(text)
                item.setData(Qt::Variant.new(notification.time), ROLE_NOTIFICATION_TIME)
                item.setData(Qt::Variant.new(notification.role), ROLE_NOTIFICATION_ROLE)
                item.setData(Qt::Variant.new(notification.message),
                    ROLE_NOTIFICATION_MESSAGE)
                item.setData(Qt::Variant.new(notification.type), ROLE_NOTIFICATION_TYPE)
                item
            end
        end
    end
end
