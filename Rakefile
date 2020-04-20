# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

task :default

TESTOPTS = ENV.delete("TESTOPTS") || ""

RUBOCOP_REQUIRED = (ENV["RUBOCOP"] == "1")
USE_RUBOCOP = (ENV["RUBOCOP"] != "0")
USE_JUNIT = (ENV["JUNIT"] == "1")
REPORT_DIR = ENV["REPORT_DIR"] || File.expand_path("test_reports", __dir__)

def minitest_set_options(test_task, name)
    minitest_options = []
    if USE_JUNIT
        minitest_options += [
            "--junit", "--junit-jenkins",
            "--junit-filename=#{REPORT_DIR}/#{name}.junit.xml"
        ]
    end

    minitest_args =
        if minitest_options.empty?
            ""
        else
            "\"" + minitest_options.join("\" \"") + "\""
        end
    test_task.options = "#{TESTOPTS} #{minitest_args} -- --simplecov-name=#{name}"
end

Rake::TestTask.new("test:core") do |t|
    t.libs << "."
    t.libs << "lib"
    minitest_set_options(t, "core")
    test_files = FileList["test/**/test_*.rb"]
    test_files = test_files
                 .exclude("test/ros/**/*.rb")
                 .exclude("test/gui/**/*.rb")
    t.test_files = test_files
    t.warning = false
end

Rake::TestTask.new("test:gui") do |t|
    t.libs << "."
    t.libs << "lib"

    minitest_set_options(t, "gui")
    t.test_files = FileList["test/gui/**/test_*.rb"]
    t.warning = false
end

task "test" => ["test:gui", "test:core"]

if USE_RUBOCOP
    begin
        require "rubocop/rake_task"
        RuboCop::RakeTask.new do |t|
            if USE_JUNIT
                t.formatters << "junit"
                t.options << "-o" << "#{REPORT_DIR}/rubocop.junit.xml"
            end
        end
        task "test" => "rubocop"
    rescue LoadError
        raise if RUBOCOP_REQUIRED
    end
end

begin
    require "coveralls/rake/task"
    Coveralls::RakeTask.new
    task "test:coveralls" => ["test", "coveralls:push"]
rescue LoadError # rubocop:disable Lint/SuppressedException
end

# For backward compatibility with some scripts that expected hoe
task "gem" => "build"
