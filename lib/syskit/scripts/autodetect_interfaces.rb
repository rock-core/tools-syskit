# frozen_string_literal: true

require "roby/standalone"
require "orocos"
require "syskit"
require "syskit/roby_app"

Roby.app.using "syskit"

if ARGV[0] == "--all"
    Roby.app.orocos_load_component_extensions = false
end

Roby.filter_backtrace do
    Roby.app.setup
    Roby.app.orogen_load_all
end

layout = Hash.new { |h, k| h[k] = [] }

tasks = TaskContext.each_submodel.to_a
until tasks.empty?
    result = []

    task = tasks.find do |t|
        tasks.none? { |m| t < m }
    end
    tasks.delete(task)

    Syskit::Interfaces.each do |source_model|
        next if task < source_model # already set
        next unless (matches = source_model.guess_source_name(task))

        # Remove useless entries in +result+
        matches.each do |interface_name|
            if task.has_data_source?(interface_name) && task.data_source_type(interface_name) == source_model
                next
            end

            result.delete_if { |m, n| source_model < m && n == interface_name }

            result << [source_model, interface_name]
        end
    end

    unless result.empty?
        result.each do |source_model, interface_name|
            task_name = task.name.gsub(/^Syskit::/, "")
            mod_name, task_name = task_name.split "::"
            if interface_name == ""
                task.provides source_model
                layout[mod_name] << "#{task_name}.interface #{source_model.name}"
            else
                task.provides source_model, :as => interface_name
                layout[mod_name] << "#{task_name}.interface #{source_model.name}, :as => #{interface_name}"
            end
        end
    end
    result.clear
end

layout.keys.sort.each do |mod_name|
    puts "module #{mod_name}"
    layout[mod_name].each do |decl|
        puts "    #{decl}"
    end
    puts "end"
    puts
end
