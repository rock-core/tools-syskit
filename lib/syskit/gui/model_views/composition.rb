require 'syskit/gui/component_network_view'
module Syskit::GUI
    module ModelViews
        Roby::TaskStructure.relation 'SpecializationCompatibilityGraph', :child_name => :compatible_specialization, :dag => false

        # Visualization of a composition model
        #
        # In addition to the plain component network, it visualizes the
        # specializations and allows to select them dynamically
        class Composition < ComponentNetworkView
            attr_reader :specializations

            def initialize(page)
                super(page)
                @specializations = Hash.new
                connect(page, SIGNAL('linkClicked(const QUrl&)'), self, SLOT('linkClicked(const QUrl&)'))
            end

            def linkClicked(url)
                if url.scheme == 'plan'
                    id = Integer(url.path.gsub(/\//, ''))
                    if task = specializations.values.find { |task| task.dot_id == id }
                        clickedSpecialization(task)
                    end
                end
            end
            slots 'linkClicked(const QUrl&)'

            def clickedSpecialization(task)
                clicked  = task.model.applied_specializations.dup.to_set
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
                render(new_model)
            end

            def clear
                super
                specializations.clear
            end

            def create_specialization_graph(root_model)
                plan = Roby::Plan.new
                specializations = Hash.new
                root_model.specializations.each_specialization.map do |spec|
                    task_model = root_model.specializations.create_specialized_model(spec, [spec])
                    plan.add(task = task_model.new)
                    specializations[spec] = task
                end

                return plan, specializations
            end

            def render_specializations(model)
                plan, @specializations = create_specialization_graph(model.root_model)

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
                    :toned_down => incompatible_specializations.values,
                    :annotations => [],
                    :id => 'specializations'
                }
                page.push_plan('Specializations', 'relation_to_dot',
                                         plan, display_options)
            end

            def render(model, options = Hash.new)
                super
                if task
                    render_data_services(task)
                end
                render_specializations(model)
            end
        end
    end
end

