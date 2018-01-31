require 'bundler/gem_tasks'
require "rake/testtask"

task :default

Rake::TestTask.new('test:core') do |t|
    t.libs << "."
    t.libs << "lib"
    test_files = FileList['test/**/test_*.rb']
    test_files = test_files.
        exclude("test/ros/**/*.rb").
        exclude("test/gui/**/*.rb")
    t.test_files = test_files
    t.warning = false
end

Rake::TestTask.new('test:gui') do |t|
    t.libs << "."
    t.libs << "lib"
    t.test_files = FileList['test/gui/**/test_*.rb']
    t.warning = false
end

task 'test' => ['test:gui', 'test:core']

begin
    require 'coveralls/rake/task'
    Coveralls::RakeTask.new
    task 'test:coveralls' => ['test', 'coveralls:push']
rescue LoadError
end

# For backward compatibility with some scripts that expected hoe
task :gem => :build

