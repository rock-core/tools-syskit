require 'orocos'
require 'pp'

Orocos.load

pattern = ARGV.shift
if pattern
    pattern = Regexp.new(pattern, Regexp::IGNORECASE)
end

fake_project = Orocos::Generation::Component.new
Orocos.available_task_libraries.each do |project_name, _|
    tasklib = fake_project.using_task_library project_name
    tasklib.self_tasks.each do |task|
        next if pattern && task.name !~ pattern
        PP.pp task, STDOUT, 0
    end
end

