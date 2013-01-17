require 'syskit/gui/stacked_display'

module Syskit
module GUI
Roby::TaskStructure.relation 'SpecializationCompatibilityGraph', :child_name => :compatible_specialization, :dag => false

class ModelDisplayView < StackedDisplay
    attr_reader :specializations
    attr_reader :current_model

    def initialize(parent = nil)
        super(parent)
        @specializations = Hash.new
    end

    def clickedSpecialization(obj_as_variant)
        object = obj_as_variant.to_ruby
        if !specializations.values.include?(object)
            return
        end

        clicked  = object.model.applied_specializations.dup.to_set
        selected = current_model.applied_specializations.dup.to_set

        if clicked.all? { |s| selected.include?(s) }
            # This specialization is already selected, remove it
            clicked.each { |s| selected.delete(s) }
            new_selection = selected

            new_merged_selection = new_selection.inject(Syskit::Models::CompositionSpecialization.new) do |merged, s|
                merged.merge(s)
            end
        else
            # This is not already selected, add it to the set. We have to
            # take care that some of the currently selected specializations
            # might not be compatible
            new_selection = clicked
            new_merged_selection = new_selection.inject(Syskit::Models::CompositionSpecialization.new) do |merged, s|
                merged.merge(s)
            end

            selected.each do |s|
                if new_merged_selection.compatible_with?(s)
                    new_selection << s
                    new_merged_selection.merge(s)
                end
            end
        end

        new_model = current_model.root_model.specializations.create_specialized_model(new_merged_selection, new_selection)
        render_model(new_model)
    end
    slots 'clickedSpecialization(QVariant&)'

    def clear
        super
        specializations.clear
    end

    def render_specialization_graph(root_model)
        plan = Roby::Plan.new
        specializations = Hash.new
        root_model.specializations.each_specialization.map do |spec|
            task_model = root_model.specializations.create_specialized_model(spec, [spec])
            plan.add(task = task_model.new)
            specializations[spec] = task
        end

        return plan, specializations
    end

    def render_model(model)
        clear
        @current_model = model

        plan_display_options = Hash[
            :remove_compositions => false,
            :annotations => ['task_info', 'port_details'].to_set
        ]

        if model <= Syskit::Composition
            plan, @specializations = render_specialization_graph(model.root_model)

            current_specializations, incompatible_specializations = [], Hash.new
            if model.root_model != model
                current_specializations = model.applied_specializations.map { |s| specializations[s] }

                incompatible_specializations = specializations.dup
                incompatible_specializations.delete_if do |spec, task|
                    model.applied_specializations.all? { |applied_spec| applied_spec.compatible_with?(spec) }
                end
            end

            display_options = {
                :accessor => :each_compatible_specialization,
                :dot_edge_mark => '--',
                :dot_graph_type => 'graph',
                :graphviz_tool => 'fdp',
                :highlights => current_specializations,
                :toned_down => incompatible_specializations.values
            }
            plan_display = push_plan('Specializations', 'relation_to_dot',
                      plan, Roby.syskit_engine,
                      display_options)
            Qt::Object.connect(plan_display, SIGNAL('selectedObject(QVariant&,QPoint&)'),
                               self, SLOT('clickedSpecialization(QVariant&)'))

            if specializations.empty?
                self.set_item_enabled(count - 1, false)
            end
        end

        main_plan = Roby::Plan.new
        requirements = Syskit::InstanceRequirements.new([model])
        task = requirements.instanciate(
            main_plan,
            Syskit::DependencyInjectionContext.new)
        main_plan.add(task)

        if model <= Syskit::Component
            push_plan('Task Dependency Hierarchy', 'hierarchy', main_plan, Roby.syskit_engine, plan_display_options)
            default_widget = push_plan('Dataflow', 'dataflow', main_plan, Roby.syskit_engine, plan_display_options)

        else
            default_widget = push_plan('Interface', 'dataflow', main_plan, Roby.syskit_engine, plan_display_options)
        end

        services = []
        task.model.each_data_service.sort_by(&:first).each do |service_name, service|
            model_hierarchy = service.model.ancestors.
                find_all do |m|
                    m.kind_of?(Syskit::Models::DataServiceModel) &&
                        m != Syskit::DataService &&
                        m != Syskit::Device &&
                        m != task.model
                end

            services << service_name
            model_hierarchy.each do |m|
                port_mappings = service.port_mappings_for(m).dup
                port_mappings.delete_if do |from, to|
                    from == to
                end
                model_name = m.short_name.gsub("DataServices::", "")
                if !port_mappings.empty?
                    services << "    #{model_name} with port mappings #{port_mappings}"
                else
                    services << "    #{model_name}"
                end
            end
        end
        label = Qt::Label.new(services.join("\n"), self)
        label.background_role = Qt::Palette::NoRole
        push("Provided Services", label)

        self.current_widget = default_widget
    end
end
end
end


