module Orocos
    module RobyPlugin
        # Support to export a dataflow and/or hierarchy structure to graphviz
        class Graphviz
            # The plan object containing the structure we want to display
            attr_reader :plan
            # Annotations for connections
            attr_reader :conn_annotations
            # Annotations for tasks
            attr_reader :task_annotations
            # Annotations for ports
            attr_reader :port_annotations

            def initialize(plan, engine)
                @plan = plan
                @engine = engine

                @task_annotations = Hash.new { |h, k| h[k] = Hash.new { |a, b| a[b] = Array.new } }
                @port_annotations = Hash.new { |h, k| h[k] = Hash.new { |a, b| a[b] = Array.new } }
                @conn_annotations = Hash.new { |h, k| h[k] = Array.new }
                @edges = Hash.new { |h, k| h[k] = Array.new }
            end

            def annotate_tasks(annotations)
                task_annotations.merge!(annotations) do |_, old, new|
                    old.merge!(new) do |_, old_array, new_array|
                        if new_array.respond_to?(:to_ary)
                            old_array.concat(new_array)
                        else
                            old_array << new_array
                        end
                    end
                end
            end
            def add_task_annotation(task, name, ann)
                task_annotations[task].merge!(name => ann) do |_, old, new|
                    old.concat(new)
                end
            end

            def annotate_ports(annotations)
                port_annotations.merge!(annotations) do |_, old, new|
                    old.merge!(new) do |_, old_array, new_array|
                        if new_array.respond_to?(:to_ary)
                            old_array.concat(new_array)
                        else
                            old_array << new_array
                        end
                    end
                end
            end
            def add_port_annotation(task, port_name, name, ann)
                port_annotations[[task, port_name]].merge!(name => ann) do |_, old, new|
                    old.concat(new)
                end
            end

            def annotate_connections(annotations)
                conn_annotations.merge!(annotations) do |_, old, new|
                    if new.respond_to?(:to_ary)
                        old.concat(new)
                    else
                        old << new
                    end
                end
            end

            def additional_edges(from, to, label)
                edges[[from, to]] << label
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_file(kind, format, filename = nil, *additional_args)
                # For backward compatibility reasons
                filename ||= kind
                if File.extname(filename) != kind
                    filename += ".#{kind}"
                end

                Tempfile.open('roby_orocos_graphviz') do |io|
                    io.write send(kind, *additional_args)
                    io.flush

                    File.open(filename, 'w') do |output_io|
                        output_io.puts(`dot -T#{format} #{io.path}`)
                    end
                end
            end

            # Generates a dot graph that represents the task hierarchy in this
            # deployment
            def hierarchy
                result = []
                result << "digraph {"
                result << "  rankdir=TB"
                result << "  node [shape=record,height=.1,fontname=\"Arial\"];"

                all_tasks = ValueSet.new

                plan.find_local_tasks(Composition).each do |task|
                    all_tasks << task
                    task.each_child do |child_task, _|
                        all_tasks << child_task
                        result << "  #{task.dot_id} -> #{child_task.dot_id};"
                    end
                end

                plan.find_local_tasks(Deployment).each do |task|
                    all_tasks << task
                    task.each_executed_task do |component|
                        all_tasks << component
                        result << "  #{component.dot_id} -> #{task.dot_id} [color=\"blue\"];"
                    end
                end

                all_tasks.each do |task|
                    task_label, attributes = format_task_label(task)
                    label = "  <TABLE ALIGN=\"LEFT\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n#{task_label}</TABLE>"
                    attributes << "label=<#{task_label}>"
                    if task.abstract?
                        attributes << " color=\"red\""
                    end

                    result << "  #{task.dot_id} [#{attributes.join(" ")}];"
                end

                result << "};"
                result.join("\n")
            end

            def self.available_annotations
                instance_methods.to_a.map(&:to_s).grep(/^add_\w+_annotations/).
                    map { |s| s.gsub(/add_(\w+)_annotations/, '\1') }
            end

            def add_task_info_annotations
                plan.find_local_tasks(TaskContext).each do |task|
                    add_task_annotation(task, "Arguments", task.arguments.map { |k, v| "#{k}: #{v}" })
                    add_task_annotation(task, "Roles", task.roles.to_a.sort.join(", "))
                end
            end

            def add_connection_policy_annotations
                plan.find_local_tasks(TaskContext).each do |source_task|
                    source_task.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        policy = policy.dup
                        policy.delete(:fallback_policy)
                        policy_s = if policy.empty? then ""
                                   elsif policy[:type] == :data then 'data'
                                   elsif policy[:type] == :buffer then  "buffer:#{policy[:size]}"
                                   else policy.to_s
                                   end
                        conn_annotations[[source_task, source_port, sink_task, sink_port]] << policy_s
                    end
                end
            end

            def add_trigger_annotations
                plan.find_local_tasks(TaskContext).each do |task|
                    task.model.each_port do |p|
                        if dyn = task.port_dynamics[p.name]
                            ann = dyn.triggers.map do |tr|
                                "#{tr.name}[p=#{tr.period},s=#{tr.sample_count}]"
                            end
                            port_annotations[[task, p.name]]['Triggers'].concat(ann)
                        end
                    end
                    if dyn = task.dynamics
                        ann = dyn.triggers.map do |tr|
                                "#{tr.name}[p=#{tr.period},s=#{tr.sample_count}]"
                        end
                        task_annotations[task]['Triggers'].concat(ann)
                    end
                end
            end

            # Generates a dot graph that represents the task dataflow in this
            # deployment
            def dataflow(remove_compositions = false, excluded_models = ValueSet.new)
                result = []
                result << "digraph {"
                result << "  rankdir=LR"
                result << "  node [shape=none,margin=0,height=.1,fontname=\"Arial\"];"

                output_ports = Hash.new { |h, k| h[k] = Set.new }
                input_ports  = Hash.new { |h, k| h[k] = Set.new }

                all_tasks = plan.find_local_tasks(Deployment).to_value_set

                plan.find_local_tasks(Component).each do |source_task|
                    next if remove_compositions && source_task.kind_of?(Composition)
                    next if excluded_models.include?(source_task.model)

                    source_task.model.each_input_port do |port|
                        input_ports[source_task] << port.name
                    end
                    source_task.model.each_output_port do |port|
                        output_ports[source_task] << port.name
                    end

                    all_tasks << source_task
                    source_task.each_output_connection do |source_port, sink_port, sink_task, policy|
                        next if excluded_models.include?(sink_task.model)
                        next if remove_compositions && sink_task.kind_of?(Composition)

                        is_concrete = !source_task.kind_of?(Composition) && !sink_task.kind_of?(Composition)
                        if !is_concrete
                            style = "style=dashed,"
                        end

                        output_ports[source_task] << source_port
                        input_ports[sink_task]    << sink_port
                        source_port_id = source_port.gsub(/[^\w]/, '_')
                        sink_port_id   = sink_port.gsub(/[^\w]/, '_')

                        label = conn_annotations[[source_task, source_port, sink_task, sink_port]].join(",")
                        result << "  outputs#{source_task.dot_id}:#{source_port_id} -> inputs#{sink_task.dot_id}:#{sink_port_id} [#{style}label=\"#{label}\"];"
                    end
                end

                # Group the tasks by deployment
                clusters = Hash.new { |h, k| h[k] = Array.new }
                all_tasks.each do |task|
                    if !task.kind_of?(Deployment)
                        clusters[task.execution_agent] << task
                    end
                end

                # Allocate one color for each task. The ideal would be to do a
                # graph coloring so that two related tasks don't get the same
                # color, but that's TODO
                task_colors = Hash.new
                used_deployments = all_tasks.map(&:execution_agent).to_value_set
                used_deployments.each do |task|
                    task_colors[task] = RobyPlugin.allocate_color
                end

                clusters.each do |deployment, task_contexts|
                    if deployment
                        result << "  subgraph cluster_#{deployment.dot_id} {"
                        task_label, task_dot_attributes = format_task_label(deployment, task_colors)
                        label = "  <TABLE ALIGN=\"LEFT\" BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n"
                        label << "    #{task_label}\n"
                        label << "  </TABLE>"
                        result << "      label=< #{label} >;"
                    end

                    task_contexts.each do |task|
                        if !task
                            raise "#{task} #{deployment} #{task_contexts.inspect}"
                        end
                        result << render_task(task, input_ports[task].to_a.sort, output_ports[task].to_a.sort)
                    end

                    if deployment
                        result << "  };"
                    end
                end

                result << "};"
                result.join("\n")
            end

            def render_task(task, input_ports, output_ports)
                result = []
                result << "    subgraph cluster_#{task.dot_id} {"
                result << "      label=\"#{"color=red" if task.abstract?}\"";
                
                task_label, attributes = format_task_label(task)
                task_label = "  <TABLE ALIGN=\"LEFT\" BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\">#{task_label}</TABLE>"
                result << "    label#{task.dot_id} [shape=none,label=< #{task_label} >];";

                if !input_ports.empty?
                    input_port_label = "<TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\">"
                    input_ports.each do |p|
                        port_id = p.gsub(/[^\w]/, '_')
                        ann = format_annotations(port_annotations, [task, p])
                        input_port_label << "<TR><TD><TABLE BORDER=\"0\" CELLBORDER=\"0\"><TR><TD PORT=\"#{port_id}\" COLSPAN=\"2\">#{p}</TD></TR>#{ann}</TABLE></TD></TR>"
                    end
                    input_port_label << "\n</TABLE>"
                    result << "    inputs#{task.dot_id} [label=< #{input_port_label} >,shape=none];"
                    result << "    inputs#{task.dot_id} -> label#{task.dot_id} [style=invis];"
                end

                if !output_ports.empty?
                    output_port_label = "<TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\">"
                    output_ports.each do |p|
                        port_id = p.gsub(/[^\w]/, '_')
                        ann = format_annotations(port_annotations, [task, p])
                        output_port_label << "<TR><TD><TABLE BORDER=\"0\" CELLBORDER=\"0\"><TR><TD PORT=\"#{port_id}\" COLSPAN=\"2\">#{p}</TD></TR>#{ann}</TABLE></TD></TR>"
                    end
                    output_port_label << "\n</TABLE>"
                    result << "    outputs#{task.dot_id} [label=< #{output_port_label} >,shape=none];"
                    result << "    label#{task.dot_id} -> outputs#{task.dot_id} [style=invis];"
                end

                result << "    }"
                result.join("\n")
            end
            def format_annotations(annotations, key = nil)
                if key
                    if !annotations.has_key?(key)
                        return
                    end
                    ann = annotations[key]
                else
                    ann = annotations
                end

                result = []
                result = ann.map do |category, values|
                    next if values.empty?

                    values = values.map { |v| v.tr("<>", "[]") }
                    "<TR><TD ROWSPAN=\"#{values.size()}\" VALIGN=\"TOP\" ALIGN=\"RIGHT\">#{category}</TD><TD ALIGN=\"LEFT\">#{values.first}</TD></TR>\n" +
                    values[1..-1].map { |v| "<TR><TD ALIGN=\"LEFT\">#{v}</TD></TR>" }.join("\n")
                end.flatten

                if !result.empty?
                    result.map { |l| "    #{l}" }.join("\n")
                end
            end


            def format_task_label(task, task_colors = Hash.new)
                label = []
                
                if task.respond_to?(:proxied_data_services)
                    name = task.proxied_data_services.map(&:short_name).join(", ").tr("<>", '[]')
                    label << "<TR><TD COLSPAN=\"2\">#{name}</TD></TR>"
                else
                    annotations = Hash.new
                    if task.model.respond_to?(:is_specialization?) && task.model.is_specialization?
                        name = task.model.root_model.name
                        spec = []
                        task.model.specialized_children.each do |child_name, child_models|
                            spec << "#{child_name}.is_a?(#{child_models.map(&:short_name).join(",")})"
                        end
                        annotations["Specialized On"] = spec
                    else
                        name = task.model.name
                    end
                    name = name.gsub("Orocos::RobyPlugin::", "").tr("<>", '[]')

                    if task.respond_to?(:orocos_name)
                        name << "[#{task.orocos_name}]"
                    end
                    label << "<TR><TD COLSPAN=\"2\">#{name}</TD></TR>"
                    ann = format_annotations(annotations)
                    label << ann
                end
                
                if ann = format_annotations(task_annotations, task)
                    label << ann
                end

                label = "    " + label.join("\n    ")
                return label
            end

            # Helper method for the to_dot methods
            def dot_task_attributes(task, task_colors, remove_compositions = false) # :nodoc:


                task_dot_attributes << "label=< #{label} >"
                if task.abstract?
                    task_dot_attributes << "color=\"red\""
                end
                task_dot_attributes
            end
        end
    end
end
