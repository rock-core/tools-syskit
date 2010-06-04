require 'orocos'
require 'pp'
require 'optparse'
require 'yaml'

output_type, output_file = "txt", nil
categories = Hash.new
parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: scripts/orocos/task_models [options] [pattern]
Loads all oroGen projects and displays all task models that are available.
If a pattern is given, only task context names that match this pattern
will be displayed.
    EOD
    opt.on('-o TYPE[:file]', '--output=TYPE[:file]', String, 'in what format to output the result (can be: txt, dot, png or svg), defaults to txt') do |output_arg|
        output_type, output_file = output_arg.split(':')
        output_type = output_type.downcase
    end
    opt.on('-c FILE', '--categories FILE', String, "sort the task contexts in categories specified in this YAML file") do |path|
       categories = YAML.load(File.read(path))
    end
end
remaining = parser.parse(ARGV)

# Generate a default name if the output file name has not been given
if output_type != 'txt' && !output_file
    output_file = "task_models.#{output_type}"
end

pattern = remaining.shift
if pattern
    pattern = Regexp.new(pattern, Regexp::IGNORECASE)
end

Orocos.load

fake_project = Orocos::Generation::Component.new
tasks = Set.new
Orocos.available_task_libraries.each do |project_name, _|
    tasklib = fake_project.using_task_library project_name
    tasklib.self_tasks.each do |task|
        next if pattern && task.name !~ pattern
        tasks << task
    end
end

def to_dot(io, categories, tasks)
    io << "digraph {"

    categories.each do |cat_name, cat_content|
        cat_tasks = []
        cat_content.each do |task_name|
            task_name = Regexp.new("(?:::|^)#{Regexp.quote(task_name)}(?:::|$)")
            matching_tasks, tasks = tasks.partition { |t| t.name =~ task_name }
            cat_tasks.concat(matching_tasks)
        end
        if !cat_tasks.empty?
            io << "subgraph cluster_#{cat_name} {"
            cat_tasks.each do |t|
                io << t.to_dot
            end
            io << "}"
        else
            STDERR.puts "found no task for category #{cat_name} (#{cat_content.join(",")})"
        end
    end

    tasks.each do |t|
        io << t.to_dot
    end
    io << "}"
end

case output_type
when "txt"
    tasks.each do |t|
        pp t
    end
when "dot"
    File.open(output_file, 'w') do |output_io|
        to_dot(output_io)
    end
when "png"
    Tempfile.open('roby_orocos_system_model') do |io|
        to_dot(io, categories, tasks)
        io.flush

        File.open(output_file, 'w') do |output_io|
            output_io.puts(`dot -Tpng #{io.path}`)
        end
    end
when "svg"
    Tempfile.open('roby_orocos_system_model') do |io|
        to_dot(io, categories, tasks)
        io.flush

        File.open(output_file, 'w') do |output_io|
            output_io.puts(`dot -Tsvg #{io.path}`)
        end
    end
end
if output_file
    STDERR.puts "exported result to #{output_file}"
end

