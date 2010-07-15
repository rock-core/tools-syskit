require 'gui/plan_display'
module Ui
    class InvalidInstanciation < RuntimeError; end

    # Widget that allows to instanciate a composition step by step
    class InstanciateComposition < PlanDisplay
        attr_reader :model
        attr_reader :selection

        attr_reader :plan
        attr_reader :system_model
        attr_reader :robot
        attr_reader :engine
        attr_reader :parent_window

        def initialize(system_model, robot, main = nil)
            super(main)
            @selection = Hash.new

            @parent_window = main
            @system_model = system_model
            @robot = robot
            @plan   = Roby::Plan.new
            @engine = Orocos::RobyPlugin::Engine.new(plan, system_model, robot)
        end

        def root_task
            main.task
        end

        def actual_selection
            selection = self.selection
            actual_selection = selection.dup
            actual_selection.delete_if do |from, to|
                to.respond_to?(:is_specialization?) && to.is_specialization?
            end

            removed_selections = selection.keys - actual_selection.keys
            if !removed_selections.empty?
                removed_selections.map! do |path|
                    [path, root_task.resolve_role_path(path.split('.')).model]
                end

                @selection = actual_selection
                compute
                removed_selections.each do |path, model|
                    current_model = root_task.resolve_role_path(path.split('.')).model
                    if current_model != model
                        raise InvalidInstanciation, "cannot generate instanciation code in the current state: you need to enforce the specialization of #{path} by picking the relevant children"
                    end
                end
            end
            actual_selection

        ensure
            if selection
                @selection = selection
                compute
                update_view
            end
        end


        def to_ruby(actual_selection = nil)
            result = ["add(#{model.short_name})"]

            (actual_selection || self.actual_selection).each do |from, to|
                if from.respond_to?(:to_str)
                    from = "'#{from.to_str}'"
                elsif from.respond_to?(:short_name)
                    from = from.short_name
                end
                if to.respond_to?(:to_str)
                    to = "'#{to.to_str}'"
                elsif to.respond_to?(:short_name)
                    to = to.short_name
                end
                result << "\n  use(#{from} => #{to})"
            end
            result.join(".")
        end

        attr_reader :model

        def model=(model)
            @model = model
            selection.clear
            update
        end

        def compute
            engine.clear
            plan.clear

            @main = engine.add_mission(model).use(selection)
            engine.prepare
            engine.instanciate
            plan.static_garbage_collect
        end

        def disable_updates; @updates_disabled = true end
        def enable_updates; @updates_disabled = false end
        def updates_disabled?; !!@updates_disabled end

        signals 'updated()'
        def update
            return if updates_disabled?

            compute
            update_view
            emit updated()
        end

        def update_view
            super(plan, engine)
        end

        attr_reader :main

        def display_svg(filename)
            items = super
            items.find_all { |it| it.respond_to?(:task) }.
                each do |item|
                    def item.mousePressEvent(event)
                        super

                        models =
                            if task.respond_to?(:proxied_data_services)
                                task.proxied_data_services.map(&:model)
                            else [task.model]
                            end

                        # Get the task's role. We can safely assume the task
                        # has only one parent and is used for only one role
                        # in this parent
                        roles = window.root_task.role_paths(task).
                            map { |role_path| role_path.join(".") }

                        candidates = 
                            if models.empty?
                                ValueSet.new
                            else
                                models.map do |m|
                                    window.engine.service_allocation_candidates[m] || ValueSet.new
                                end.
                                    map(&:to_value_set).
                                    inject(&:&)
                            end

                        current_selection = roles.find_all do |role_name|
                            window.selection[role_name]
                        end

                        puts "mouse pressed for #{self} (#{models.map(&:name).join(", ")}) [#{task}, #{roles.to_a.join(", ")}]"
                        menu = Qt::Menu.new
                        candidates = candidates.to_a.sort_by(&:name)
                        if candidates.empty? && current_selection.empty?
                            action = menu.add_action('No available selection')
                            action.enabled = false
                        end

                        deselection = Hash.new
                        current_selection.each do |role_name|
                            text = "Don't use for #{role_name}"
                            deselection[text] = role_name
                            menu.add_action(text)
                        end

                        selection = Hash.new
                        candidates.each do |m|
                            selection[m.name] = m
                            menu.add_action(m.name)
                        end
                        return unless action = menu.exec(event.screenPos)

                        if selected_model = selection[action.text]
                            roles.each do |child_name|
                                window.selection[child_name] = selected_model
                            end
                            puts "selected #{selected_model.short_name} for #{roles.to_a.join(", ")}"
                        elsif deselected_role = deselection[action.text]
                            window.selection.delete(deselected_role)
                        end

                        window.update
                    end
                end
            items
        end

    end
end

