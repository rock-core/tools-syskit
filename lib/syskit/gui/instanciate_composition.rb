require 'gui/plan_display'
module Ui
    class InvalidInstanciation < RuntimeError; end

    # Widget that allows to instanciate a composition step by step
    class InstanciateComposition < PlanDisplay
        # The model
        attr_reader :model
        # The disambiguation selection
        attr_reader :selection

        attr_reader :plan
        attr_reader :system_model
        attr_reader :robot
        attr_reader :engine
        attr_reader :parent_window
        attr_reader :parent_engine

        def initialize(system_model, robot, main = nil, parent_engine = nil)
            super(main)
            @selection = Orocos::RobyPlugin::DependencyInjection.new

            Qt::Object.connect(self, SIGNAL('selectedObject(QVariant&,QPoint&)'),
                               self, SLOT('selectedTask(QVariant&,QPoint&)'))

            @parent_window = main
            @system_model = system_model
            @parent_engine = parent_engine || Roby.app.orocos_engine
            @robot = robot
            @plan   = Roby::Plan.new
            @engine = Orocos::RobyPlugin::Engine.new(plan, system_model, robot)
        end

        def root_task
            main.task
        end

        def actual_selection
            self.selection.dup
        end

        def to_ruby(actual_selection = nil, name = nil)
            InstanciateComposition.to_ruby(
                model, actual_selection || self.actual_selection, name)
        end

        def self.selection_to_string(selection, array_is_path)
            case selection
            when Orocos::RobyPlugin::ProvidedDataService
                "#{selection.model.short_name}.#{selection.full_name}"
            when Orocos::RobyPlugin::DeviceInstance
                selection.name
            when Class
                if selection.respond_to?(:short_name)
                    selection.short_name
                else
                    selection.name
                end
            when String
                "\"#{selection}\""
            when NilClass
                'nil'
            when Array
                if array_is_path
                    "\"#{selection.join(".")}\""
                else
                    "[#{selection.map { |s| selection_to_string(s) }.join(", ")}]"
                end
            when Orocos::RobyPlugin::InstanceRequirements
                to_ruby(selection.base_models.first, selection.selections, nil)
            else
                raise NotImplementedError, "cannot convert #{selection.class} to a Ruby syntax"
            end
        end

        def self.format_selection(actual_selection)
            list = []
            actual_selection.explicit.each do |from, to|
                from = selection_to_string(from, true)
                to   = selection_to_string(to, false)
                list << "#{from} => #{to}"
            end
            actual_selection.defaults.each do |obj|
                list << selection_to_string(obj, false)
            end

            "use(#{list.join(",\n  ")})"
        end

        def self.to_ruby_define(model, actual_selection, name)
            if !name
                raise ArgumentError, "definitions must have a name"
            end
            result = ["define('#{name}', #{model.short_name})"]
            result << "  " + format_selection(actual_selection)
            result.join(".\n")
        end

        def self.to_ruby(model, actual_selection, name)
            if name
                options = ", :as => #{name}"
            end
            result = ["add(#{model.short_name}#{options})"]
            result << "  " + format_selection(actual_selection)
            result.join(".\n")
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

            if model
                begin
                    Orocos::RobyPlugin::Composition.strict_specialization_selection = false
                    @main = engine.add_mission(model).use(selection)

                    parent_engine.deployments.each do |host, names|
                        names.each do |n|
                            @engine.use_deployment(n, :on => host)
                        end
                    end

                    engine.prepare
                    engine.instanciate
                    plan.static_garbage_collect
                ensure
                    Orocos::RobyPlugin::Composition.strict_specialization_selection = true
                end
            end
        end

        def disable_updates; @updates_disabled = true end
        def enable_updates; @updates_disabled = false end
        def updates_disabled?; !!@updates_disabled end

        signals 'updated()'
        def update
            return if updates_disabled?

            begin
                compute
                update_view
            rescue Exception => e
                display_error("Failed to deploy the required system network", e)
            end
            emit updated()
        end

        def update_view
            super(plan, engine)
        end

        attr_reader :main

        def selection_candidates_for(models)
            # Get the task's role. We can safely assume the task
            # has only one parent and is used for only one role
            # in this parent
            device_candidates = Hash.new
            robot.devices.values.find_all do |dev|
                dev.service.fullfills?(models)
            end.each do |dev|
                device_candidates[dev.name] = dev
            end

            if models.empty?
                return Hash.new, device_candidates
            end

            candidates = models.map do |m|
                engine.service_allocation_candidates[m] || ValueSet.new
            end.map(&:to_value_set).inject(&:&)

            # We now have to take care about ambiguity ... I.e.
            # either use faceted selection or explicit service
            # selection when needed
            system_candidates = Hash.new
            candidates.each do |model|
                disambiguation = []
                models.each do |expected_model|
                    available_services =
                        model.find_all_services_from_type(expected_model)
                    if available_services.size == 1
                        next
                    else
                        disambiguation << available_services
                    end
                end

                # If there are multiple candidates, check if they have all a
                # different model. In this case, use the .as() mechanism.
                # Otherwise, we have to use the service name
                if disambiguation.size > 1
                    raise NotImplementedError
                end
                disambiguation = disambiguation.first
                if !disambiguation
                    system_candidates[model.short_name] = model
                elsif disambiguation.map(&:model).to_value_set == disambiguation.size
                    disambiguation.each do |service|
                        system_candidates["#{model.short_name}.as(#{service.model.short_name})"] = service
                    end
                else
                    disambiguation.each do |service|
                        system_candidates[service.short_name] = service
                    end

                end
            end

            return system_candidates, device_candidates
        end

        def selectedTask(_task, click_pos)
            task = _task.value
            models =
                if task.respond_to?(:proxied_data_services)
                    task.proxied_data_services
                else [task.model]
                end

            system_candidates, device_candidates = selection_candidates_for(models)

            roles = root_task.role_paths(task)
            current_selection = roles.find_all do |role_name|
                selection.explicit[role_name]
            end

            menu = Qt::Menu.new

            device_candidates = device_candidates.to_a.sort_by(&:first)
            system_candidates = system_candidates.to_a.sort_by(&:first)
            if device_candidates.empty? && system_candidates.empty? && current_selection.empty?
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
            if !device_candidates.empty?
                menu.add_separator.text = "Devices"
                device_candidates.each do |name, m|
                    selection[name] = m
                    menu.add_action(name)
                end
            end
            if !system_candidates.empty?
                menu.add_separator.text = "Models"
                system_candidates.each do |name, m|
                    selection[name] = m
                    menu.add_action(name)
                end
            end
            return unless action = menu.exec(click_pos)

            if selected_model = selection[action.text]
                role = roles.min_by(&:size)
                self.selection.explicit[role] = selected_model
            elsif deselected_role = deselection[action.text]
                self.selection.explicit.delete(deselected_role)
            end

            update
        end
        slots "selectedTask(QVariant&,QPoint&)"

        def display_svg(filename)
            items = super
            items.find_all { |it| it.respond_to?(:task) }.
                each do |item|
                    item.extend ComposerSvgItem
                end
            items
        end

    end
end

