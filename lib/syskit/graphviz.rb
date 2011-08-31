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
                        result << "  #{source_task.dot_id}:#{source_port_id} -> #{sink_task.dot_id}:#{sink_port_id} [#{style}label=\"#{label}\"];"
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
                        result << "    #{dot_task_attributes(deployment, Array.new, Array.new, task_colors, remove_compositions).join(";\n     ")};"
                    end

                    task_contexts.each do |task|
                        if !task
                            raise "#{task} #{deployment} #{task_contexts.inspect}"
                        end
                        attributes = dot_task_attributes(task, input_ports[task].to_a.sort, output_ports[task].to_a.sort, task_colors, remove_compositions)
                        result << "    #{task.dot_id} [#{attributes.join(",")}];"
                    end

                    if deployment
                        result << "  };"
                    end
                end

                result << "};"
                result.join("\n")
            end
            def format_annotations(annotations, key)
                if !annotations.has_key?(key)
                    return
                end

                result = []
                ann = annotations[key]
                result = ann.map do |category, values|
                    next if values.empty?

                    "<TR><TD ROWSPAN=\"#{values.size()}\">#{category}</TD><TD>#{values.first}</TD></TR>\n" +
                    values[1..-1].map { |v| "<TR><TD>#{v}</TD></TR>" }.join("\n")
                end.flatten

                if !result.empty?
                    result.map { |l| "    #{l}" }.join("\n")
                end
            end


            def format_task_label(task, task_colors = Hash.new)
                task_node_attributes = []
                task_flags = []
                #task_flags << "E" if task.executable?
                #task_flags << "A" if task.abstract?
                #task_flags << "C" if task.kind_of?(Composition)
                task_flags =
                    if !task_flags.empty?
                        "[#{task_flags.join(",")}]"
                    else ""
                    end
                
                task_label = "<TR><TD COLSPAN=\"2\">"
                task_label << 
                    if task.respond_to?(:proxied_data_services)
                        task.proxied_data_services.map(&:short_name).join(", ") + task_flags
                    else
                        text = task.to_s
                        text = text.gsub('Orocos::RobyPlugin::', '').
                            gsub(/\s+/, '').gsub('=>', ':').tr('<>', '[]')
                        result =
                            if text =~ /(.*)\/\[(.*)\](:0x[0-9a-f]+)/
                                # It is a specialization, move the
                                # specialization specification below the model
                                # name
                                name = $1
                                specializations = $2
                                id  = $3
                                name + task_flags +
                                    "<BR/>" + specializations.gsub('),', ')<BR/>')
                            else
                                text.gsub /:0x[0-9a-f]+/, ''
                            end
                        result.gsub(/\s+/, '').gsub('=>', ':').
                            gsub(/\[\]|\{\}/, '').gsub(/[{}]/, '<BR/>')
                    end
                task_label.tr('<>', '[]')

                if task.kind_of?(Deployment)
                    if task_colors[task]
                        task_node_attributes << "color=\"#{task_colors[task]}\""
                        task_label = "<FONT COLOR=\"#{task_colors[task]}\">#{task_label}"
                        task_label << " <BR/> [Process name: #{task.model.deployment_name}]</FONT>"
                    else
                        task_label = "#{task_label}"
                        task_label << " <BR/> [Process name: #{task.model.deployment_name}]"
                    end
                elsif task.kind_of?(Composition)
                    task_node_attributes << "color=\"blue\""
                end

                roles = task.roles
                task_label << " <BR/> roles:#{roles.to_a.sort.join(",")}</TD></TR>"
                
                ann = format_annotations(task_annotations, task)
                if ann
                    task_label << ann
                end

                return task_label, task_node_attributes
            end

            # Helper method for the to_dot methods
            def dot_task_attributes(task, inputs, outputs, task_colors, remove_compositions = false) # :nodoc:
                task_label, task_dot_attributes = format_task_label(task, task_colors)

                label = "  <TABLE ALIGN=\"LEFT\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n"
                if !inputs.empty?
                    label << inputs.map do |name|
                        ann = format_annotations(port_annotations, [task, name])
                        "    <TABLE BORDER=\"0\" CELLBORDER=\"1\"><TR BORDER=\"1\"><TD COLSPAN=\"2\" PORT=\"#{name.gsub(/[^\w]/, '_')}\">#{name}</TD></TR>\n#{ann}</TD></TR></TABLE>"
                    end.join("")
                end
                label << "    #{task_label}\n"
                if !outputs.empty?
                    label << outputs.map do |name|
                        ann = format_annotations(port_annotations, [task, name])
                        "    <TR><TD><TABLE BORDER=\"0\" CELLBORDER=\"1\"><TR><TD COLSPAN=\"2\" PORT=\"#{name.gsub(/[^\w]/, '_')}\">#{name}</TD></TR>\n#{ann}</TD></TR></TABLE></TR></TD>"
                    end.join("")
                end
                label << "  </TABLE>"

                task_dot_attributes << "label=< #{label} >"
                if task.abstract?
                    task_dot_attributes << "color=\"red\""
                end
                task_dot_attributes
            end
        end
    end
end
