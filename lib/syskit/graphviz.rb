require 'roby/gui/dot_id'

module Syskit
        # Used by the to_dot* methods for color allocation
        attr_reader :current_color
        # A set of colors to be used in graphiz graphs
        COLOR_PALETTE = %w{#FF9955 #FF0000 #bb9c21 #37c637 #62816e #2A7FFF #AA00D4 #D40055 #0000FF}
        # Returns a color from COLOR_PALETTE, rotating each time the method is
        # called. It is used by the to_dot* methods.
        def self.allocate_color
            @current_color = (@current_color + 1) % COLOR_PALETTE.size
            COLOR_PALETTE[@current_color]
        end
        @current_color = 0
        
        # Exception raised when the dot subprocess crashes in the Graphviz class
        class DotCrashError < RuntimeError; end
        # Exception raised when the dot subprocess reported a failure in the Graphviz class
        class DotFailedError < RuntimeError; end

        # General support to export a generated plan into a dot-compatible
        # format
        #
        # This class generates the dot specification files (and runs dot for
        # you), exporting the component-related information out of a plan.
        #
        # It also contains an API that allows to add "annotations" to the
        # generated graph. Four types of annotations can be generated:
        #
        # * port annotations: text is added to the port descriptions
        #   (#add_port_annotation)
        # * task annotations: text is added to the task description
        #   (#add_task_annotation)
        # * additional vertices (#add_vertex)
        # * additional edges (#add_edge)
        #
        class Graphviz
            attr_predicate :make_links?, true
            # The plan object containing the structure we want to display
            attr_reader :plan
            # Annotations for connections
            attr_reader :conn_annotations
            # Annotations for tasks
            attr_reader :task_annotations
            # Annotations for ports
            attr_reader :port_annotations
            # Additional vertices that should be added to the generated graph
            attr_reader :additional_vertices
            # Additional edges that should be added to the generated graph
            attr_reader :additional_edges
            # A rendering context for the SVG
            # @return [#link_to(object[, text])]
            attr_reader :page

            class << self
                # @return [Set<String>] set of annotation names that make sense
                #   for a task alone
                attr_reader :available_task_annotations
                # @return [Set<String>] set of annotation names that make sense
                #   only for tasks that are part of a graph
                attr_reader :available_graph_annotations
            end
            @available_task_annotations = Set.new
            @available_graph_annotations = Set.new

            class DummyPage
                def link_to(obj, text = nil)
                    if text then text
                    else
                        obj.name.gsub("<", "&lt;").
                            gsub(">", "&gt;")
                    end
                end
            end

            def initialize(plan, page = DummyPage.new)
                @plan = plan
                @page = page
                @make_links = true
                @typelib_resolver = GUI::ModelBrowser::TypelibResolver.new

                @task_annotations = Hash.new { |h, k| h[k] = Hash.new { |a, b| a[b] = Array.new } }
                @port_annotations = Hash.new { |h, k| h[k] = Hash.new { |a, b| a[b] = Array.new } }
                @conn_annotations = Hash.new { |h, k| h[k] = Array.new }
                @additional_vertices = Hash.new { |h, k| h[k] = Array.new }
                @additional_edges    = Array.new
            end

            def uri_for(type)
                "link://metaruby/" + @typelib_resolver.split_name(type).join("/")
            end

            def escape_dot(string)
                string.
                    gsub(/</, "&lt;").
                    gsub(/>/, "&gt;").
                    gsub(/[^\[\]&;:\w\. ]/, "_")
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

            # Add an annotation block to a task label.
            #
            # @param [Component] task is the task to which the information
            #   should be added
            # @param [String] name is the annotation name. It appears on the
            #   left column of the task label
            # @param [Array<String>] ann is the annotation itself, as an array.
            #   Each line in the array is displayed as a separate line in the
            #   label.
            # @return [void]
            def add_task_annotation(task, name, ann)
                if !ann.respond_to?(:to_ary)
                    ann = [ann]
                end

                task_annotations[task].merge!(name => ann) do |_, old, new|
                    old + new
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

            # Add an annotation block to a port label.
            #
            # @param [Component] task the task that contains the port
            # @param [String] port_name the port name
            # @param [String] name the annotation name. It appears on the left
            #   column of the task label
            # @param [Array<String>] ann the annotation itself, as an array.
            #   Each line in the array is displayed as a separate line in the
            #   label.
            # @return [void]
            def add_port_annotation(task, port_name, name, ann)
                port_annotations[[task, port_name]].merge!(name => ann) do |_, old, new|
                    old + new
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

            def add_vertex(task, vertex_name, vertex_label)
                additional_vertices[task] << [vertex_name, vertex_label]
            end

            def add_edge(from, to, label = nil)
                additional_edges << [from, to, label]
            end

            def run_dot_with_retries(retry_count, command)
                retry_count.times do |i|
                    Tempfile.open('roby_orocos_graphviz') do |io|
                        dot_graph = yield
                        io.write dot_graph
                        io.flush

                        graph = `#{command % [io.path]}`
                        if $?.exited?
                            return graph
                        end
                        puts "dot crashed, retrying (#{i}/#{retry_count})"
                    end
                end
                nil
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_file(kind, format, output_io, options = Hash.new)
                # For backward compatibility reasons
                filename ||= kind
                if File.extname(filename) != ".#{format}"
                    filename += ".#{format}"
                end

                file_options, display_options = Kernel.filter_options options,
                    :graphviz_tool => "dot"

                graph = run_dot_with_retries(20, "#{file_options[:graphviz_tool]} -T#{format} %s") do
                    send(kind, display_options)
                end
                graph ||= run_dot_with_retries(20, "#{file_options[:graphviz_tool]} -Tpng %s") do
                    send(kind, display_options)
                end

                if !graph
                    Syskit.debug do
                        i = 0
                        pattern = "syskit_graphviz_%i.dot"
                        while File.file?(pattern % [i])
                            i += 1
                        end
                        path = pattern % [i]
                        File.open(path, 'w') { |io| io.write send(kind, display_options) }
                        "saved graphviz input in #{path}"
                    end
                    raise DotFailedError, "dot reported an error generating the graph"
                end

                if output_io.respond_to?(:to_str)
                    File.open(output_io, 'w') do |io|
                        io.puts(graph)
                    end
                else
                    output_io.puts(graph)
                    output_io.flush
                end
            end

            COLORS = {
                :normal => %w{#000000 red},
                :toned_down => %w{#D3D7CF #D3D7CF}
            }

            def format_edge_info(value)
                if value.respond_to?(:to_str)
                    value.to_str
                elsif value.respond_to?(:each)
                    value.map { |v| format_edge_info(v) }.join(",")
                else
                    value.to_s
                end
            end

            # Generates a dot graph that represents the task hierarchy in this
            # deployment
            def relation_to_dot(options = Hash.new)
                options = Kernel.validate_options options,
                    :accessor => nil,
                    :dot_edge_mark => "->",
                    :dot_graph_type => 'digraph',
                    :highlights => [],
                    :toned_down => [],
                    :displayed_options => [],
                    :annotations => ['task_info']

                if !options[:accessor]
                    raise ArgumentError, "no :accessor option given"
                end

                port_annotations.clear
                task_annotations.clear

                options[:annotations].each do |ann_name|
                    send("add_#{ann_name}_annotations")
                end

                result = []

                all_tasks = Set.new

                plan.find_local_tasks(Component).each do |task|
                    all_tasks << task
                    task.send(options[:accessor]) do |child_task, edge_info|
                        label = []
                        options[:displayed_options].each do |key|
                            label << "#{key}=#{format_edge_info(edge_info[key])}"
                        end
                        all_tasks << child_task
                        result << "  #{task.dot_id} #{options[:dot_edge_mark]} #{child_task.dot_id} [label=\"#{label.join("\\n")}\"];"
                    end
                end

                all_tasks.each do |task|
                    attributes = []
                    task_label = format_task_label(task)
                    label = "  <TABLE ALIGN=\"LEFT\" COLOR=\"white\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n#{task_label}</TABLE>"
                    attributes << "label=<#{label}>"
                    if make_links?
                        attributes << "href=\"plan://syskit/#{task.dot_id}\""
                    end
                    color_set =
                        if options[:toned_down].include?(task)
                            COLORS[:toned_down]
                        else COLORS[:normal]
                        end
                    color =
                        if task.abstract? then color_set[1]
                        else color_set[0]
                        end
                    attributes << "color=\"#{color}\""
                    if options[:highlights].include?(task)
                        attributes << "penwidth=3"
                    end

                    result << "  #{task.dot_id} [#{attributes.join(" ")}];"
                end

                if result.empty?
                    # This workarounds a dot bug in which some degenerate graphs
                    # (only one node) crash it
                    return "#{options[:dot_graph_type]} { }"
                else
                    ["#{options[:dot_graph_type]} {",
                     "  mindist=0",
                     "  rankdir=TB",
                     "  node [shape=record,height=.1,fontname=\"Arial\"];"].
                    concat(result).
                    concat(["}"]).
                    join("\n")
                end
            end

            # Generates a dot graph that represents the task hierarchy in this
            # deployment
            #
            # It takes no options. The +options+ argument is used to have a
            # common signature with #dataflow
            def hierarchy(options = Hash.new)
                relation_to_dot(:accessor => :each_child)
            end

            def self.available_annotations
                instance_methods.map do |m|
                    if m.to_s =~ /^add_(\w+)_annotations/
                        $1
                    end
                end.compact
            end

            def add_port_details_annotations
                plan.find_local_tasks(Component).each do |task|
                    task.model.each_port do |p|
                        add_port_annotation(task, p.name, "Type", p.type_name)
                    end
                end
            end
            available_task_annotations << 'port_details'

            def add_task_info_annotations
                plan.find_local_tasks(Component).each do |task|
                    arguments = task.arguments.map { |k, v| "#{k}: #{v}" }
                    task.model.arguments.each do |arg_name|
                        if !task.arguments.has_key?(arg_name)
                            arguments << "#{arg_name}: (unset)"
                        end
                    end
                    add_task_annotation(task, "Arguments", arguments.sort)
                    add_task_annotation(task, "Roles", task.roles.to_a.sort.join(", "))
                end
            end
            available_task_annotations << 'task_info'

            def add_connection_policy_annotations
                plan.find_local_tasks(TaskContext).each do |source_task|
                    source_task.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        policy = policy.dup
                        policy.delete(:fallback_policy)
                        if policy.empty?
                            policy_s = "(no policy)"
                        else
                            policy_s = if policy.empty? then ""
                                       elsif policy[:type] == :data then 'data'
                                       elsif policy[:type] == :buffer then  "buffer:#{policy[:size]}"
                                       else policy.to_s
                                       end
                        end
                        conn_annotations[[source_task, source_port, sink_task, sink_port]] << policy_s
                    end
                end
            end
            available_graph_annotations << 'connection_policy'

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
            available_graph_annotations << 'trigger'

            # Generates a dot graph that represents the task dataflow in this
            # deployment
            def dataflow(options = Hash.new, excluded_models = Set.new, annotations = Set.new)
                # For backward compatibility with the signature
                # dataflow(remove_compositions = false, excluded_models = Set.new, annotations = Set.new)
                if !options.kind_of?(Hash)
                    options = { :remove_compositions => options, :excluded_models => excluded_models, :annotations => annotations }
                end

                options = Kernel.validate_options options,
                    :remove_compositions => false,
                    :excluded_models => Set.new,
                    :annotations => Set.new,
                    :highlights => Set.new,
                    :show_all_ports => true
                excluded_models = options[:excluded_models]
                    
                port_annotations.clear
                task_annotations.clear

                annotations = options[:annotations].to_set
                annotations.each do |ann|
                    send("add_#{ann}_annotations")
                end

                output_ports = Hash.new { |h, k| h[k] = Set.new }
                input_ports  = Hash.new { |h, k| h[k] = Set.new }
                connected_ports  = Hash.new { |h, k| h[k] = Set.new }
                port_annotations.each do |task, p|
                    connected_ports[task] << p
                end
                additional_edges.each do |(from_id, from_task), (to_id, to_task), _|
                    from_id = from_task.find_port(from_id) if !from_id.respond_to?(:name)
                    connected_ports[from_task] << from_id
                    to_id = to_task.find_port(to_id) if !to_id.respond_to?(:name)
                    connected_ports[to_task] << to_id
                end
                connections = Hash.new

                all_tasks = plan.find_local_tasks(Deployment).to_set

                # Register all ports and all connections
                #
                # Note that a connection is not guaranteed to be from an output
                # to an input: on compositions, exported ports are represented
                # as connections between either two inputs or two outputs
                plan.find_local_tasks(Component).each do |source_task|
                    next if options[:remove_compositions] && source_task.kind_of?(Composition)
                    next if excluded_models.include?(source_task.concrete_model)

                    source_task.each_input_port do |port|
                        input_ports[source_task] << port
                    end
                    source_task.each_output_port do |port|
                        output_ports[source_task] << port
                    end

                    all_tasks << source_task

                    if !source_task.kind_of?(Composition)
                        source_task.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                            next if excluded_models.include?(sink_task.concrete_model)
                            connections[[source_task, source_port, sink_port, sink_task]] = policy
                        end
                    end
                    source_task.each_output_connection do |source_port, sink_port, sink_task, policy|
                        next if connections.has_key?([source_port, sink_port, sink_task])
                        next if excluded_models.include?(sink_task.concrete_model)
                        next if options[:remove_compositions] && sink_task.kind_of?(Composition)
                        connections[[source_task, source_port, sink_port, sink_task]] = policy
                    end
                end

                # Register ports that are part of connections, but are not
                # defined on the task's interface. They are dynamic ports.
                connections.each do |(source_task, source_port, sink_port, sink_task), policy|
                    source_port = source_task.find_port(source_port)
                    connected_ports[source_task] << source_port
                    sink_port   = sink_task.find_port(sink_port)
                    connected_ports[sink_task]   << sink_port
                    if !input_ports[source_task].include?(source_port)
                        output_ports[source_task] << source_port
                    end
                    if !output_ports[sink_task].include?(sink_port)
                        input_ports[sink_task] << sink_port
                    end
                end

                result = []

                # Finally, emit the dot code for connections
                connections.each do |(source_task, source_port, sink_port, sink_task), policy|
                    source_port = source_task.find_port(source_port)
                    sink_port   = sink_task.find_port(sink_port)
                    if !(source_port.output? ^ sink_port.output?)
                        style = "style=dashed,"
                    end

                    source_port_id = dot_id(source_port, source_task)
                    sink_port_id   = dot_id(sink_port, sink_task)

                    label = conn_annotations[[source_task, source_port.name, sink_task, sink_port.name]].join(",")
                    result << "  #{source_port_id} -> #{sink_port_id} [#{style}label=\"#{label}\"];"
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
                used_deployments = all_tasks.map(&:execution_agent).to_set
                used_deployments.each do |task|
                    task_colors[task] = Syskit.allocate_color
                end

                clusters.each do |deployment, task_contexts|
                    if deployment
                        result << "  subgraph cluster_#{deployment.dot_id} {"
                        task_label, task_dot_attributes = format_task_label(deployment, task_colors)
                        label = "  <TABLE ALIGN=\"LEFT\" COLOR=\"white\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n"
                        label << "    #{task_label}\n"
                        label << "  </TABLE>"
                        result << "      label=< #{label} >;"
                    end

                    task_contexts.each do |task|
                        if !task
                            raise "#{task} #{deployment} #{task_contexts.inspect}"
                        end
                        if options[:highlights].include?(task)
                            style = "penwidth=3;"
                        end
                        inputs  = input_ports[task]
                        outputs = output_ports[task]
                        if !options[:show_all_ports]
                            inputs  = (inputs & connected_ports[task]).to_a.sort_by(&:name)
                            outputs = (outputs & connected_ports[task]).to_a.sort_by(&:name)
                        end
                        result << render_task(task, inputs, outputs, style)
                    end

                    if deployment
                        result << "  };"
                    end
                end

                additional_edges.each do |from, to, label|
                    from_id = dot_id(*from)
                    to_id   = dot_id(*to)
                    result << "  #{from_id} -> #{to_id} [#{label}];"
                end

                if result.empty?
                    # This workarounds a dot bug in which some degenerate graphs
                    # (only one node) crash it
                    return "digraph { }"
                else
                    ["digraph {",
                     "  rankdir=LR;",
                     "  node [shape=none,margin=0,height=.1,fontname=\"Arial\"];"].
                    concat(result).
                    concat(["}"]).
                    join("\n")
                end
            end

            def dot_symbol_quote(string)
                string.gsub(/[^\w]/, '_')
            end

            def dot_id(object, context = nil)
                case object
                when Syskit::TaskContext
                    "label#{object.dot_id}"
                when Syskit::InputPort, OroGen::Spec::InputPort
                    "inputs#{context.dot_id}:#{dot_id(object.name)}"
                when Syskit::OutputPort, OroGen::Spec::OutputPort
                    "outputs#{context.dot_id}:#{dot_id(object.name)}"
                else
                    if object.respond_to?(:to_str)
                        if !context
                            return dot_symbol_quote(object)
                        elsif context.respond_to?(:dot_id)
                            return "#{dot_symbol_quote(object)}#{context.dot_id}"
                        end
                    end

                    raise ArgumentError, "don't know how to generate a dot ID for #{object} in context #{context}"
                end
            end

            HTML_CHAR_CLASSES = Hash[
                '<' => '&lt;',
                '>' => '&gt;'
            ]

            def render_task(task, input_ports, output_ports, style = nil)
                task_link = if make_links?
                                "href=\"plan://syskit/#{task.dot_id}\""
                            end

                result = []
                result << "    subgraph cluster_#{task.dot_id} {"
                result << "        #{task_link};"
                result << "        label=\"\";"
                if task.abstract?
                    result << "      color=\"red\";"
                end
                result << style if style

                additional_vertices[task].each do |vertex_name, vertex_label|
                    result << "      #{dot_id(vertex_name, task)} [#{vertex_label}];"
                end

                task_label, attributes = format_task_label(task)
                task_label = "  <TABLE ALIGN=\"LEFT\" COLOR=\"white\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">#{task_label}</TABLE>"
                result << "    label#{task.dot_id} [#{task_link},shape=none,label=< #{task_label} >];";

                if !input_ports.empty?
                    input_port_label = "<TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\">"
                    input_ports.each do |p|
                        port_id = dot_id(p.name)
                        ann = format_annotations(port_annotations, [task, p.name])
                        doc = escape_dot(p.model.doc || '<no documentation for this port>')
                        input_port_label << "<TR><TD HREF=\"#{uri_for(p.type)}\" TITLE=\"#{doc}\"><TABLE BORDER=\"0\" CELLBORDER=\"0\"><TR><TD PORT=\"#{port_id}\" COLSPAN=\"2\">#{p.name}</TD></TR>#{ann}</TABLE></TD></TR>"
                    end
                    input_port_label << "\n</TABLE>"
                    result << "    inputs#{task.dot_id} [label=< #{input_port_label} >,shape=none];"
                    result << "    inputs#{task.dot_id} -> label#{task.dot_id} [style=invis];"
                end

                if !output_ports.empty?
                    output_port_label = "<TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\">"
                    output_ports.each do |p|
                        port_id = dot_id(p.name)
                        ann = format_annotations(port_annotations, [task, p.name])
                        doc = escape_dot(p.model.doc || '<no documentation for this port>')
                        output_port_label << "<TR><TD HREF=\"#{uri_for(p.type)}\" TITLE=\"#{doc}\"><TABLE BORDER=\"0\" CELLBORDER=\"0\"><TR><TD PORT=\"#{port_id}\" COLSPAN=\"2\">#{p.name}</TD></TR>#{ann}</TABLE></TD></TR>"
                    end
                    output_port_label << "\n</TABLE>"
                    result << "    outputs#{task.dot_id} [label=< #{output_port_label} >,shape=none];"
                    result << "    label#{task.dot_id} -> outputs#{task.dot_id} [style=invis];"
                end

                result << "    }"
                result.join("\n")
            end
            def format_annotations(annotations, key = nil, include_empty: false)
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
                    # Values are allowed to be an array of strings or plain strings, normalize to array
                    values = [*values]
                    next if (values.empty? && !include_empty)

                    values = values.map { |v| v.tr("<>", "[]") }
                    values = values.map { |v| v.tr("{}", "[]") }

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
                    name = task.proxied_data_services.map do |model|
                        model.name
                    end
                    if ![Syskit::Component, Syskit::TaskContext, Syskit::Composition].include?(task.model.superclass) &&
                        name = [task.model.superclass.name] + name
                    end
                    name = escape_dot(name.join(","))
                    if task.model.respond_to?(:tag_name)
                        name = "#{task.model.tag_name}_tag(#{name})"
                    end
                    if task.transaction_proxy?
                        name = "[T] #{name}"
                    end
                    label << "<TR><TD COLSPAN=\"2\">#{escape_dot(name)}</TD></TR>"
                else
                    annotations = Array.new
                    if task.model.respond_to?(:is_specialization?) && task.model.is_specialization?
                        annotations = [["Specialized On", [""]]]
                        name = task.model.root_model.name || ""
                        task.model.specialized_children.each do |child_name, child_models|
                            child_models = child_models.map(&:short_name)
                            annotations << [child_name, child_models.shift]
                            child_models.each do |m|
                                annotations << ["", m]
                            end
                        end

                    else
                        name = task.concrete_model.name || ""
                    end

                    if task.execution_agent && task.respond_to?(:orocos_name)
                        name << "[#{task.orocos_name}]"
                    end
                    if task.transaction_proxy?
                        name = "[T] #{name}"
                    end
                    label << "<TR><TD COLSPAN=\"2\">#{escape_dot(name)}</TD></TR>"
                    ann = format_annotations(annotations)
                    label << ann
                end
                
                if ann = format_annotations(task_annotations, task)
                    label << ann
                end

                return "    " + label.join("\n    ")
            end

            def self.dot_iolabel(name, inputs, outputs)
                label = "{{"
                if !inputs.empty?
                    label << inputs.sort.map do |port_name|
                            "<#{port_name}> #{port_name}"
                    end.join("|")
                    label << "|"
                end
                label << "<main> #{name}"

                if !outputs.empty?
                    label << "|"
                    label << outputs.sort.map do |port_name|
                            "<#{port_name}> #{port_name}"
                    end.join("|")
                end
                label << "}}"
            end
        end
end
