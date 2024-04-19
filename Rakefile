# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

task :default

TESTOPTS = ENV.delete("TESTOPTS") || ""

RUBOCOP_REQUIRED = (ENV["RUBOCOP"] == "1")
USE_RUBOCOP = (ENV["RUBOCOP"] != "0")
USE_JUNIT = (ENV["JUNIT"] == "1")
USE_GRPC = (ENV["SYSKIT_HAS_GRPC"] != "0")
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
                 .exclude("test/live/**/*.rb")
    t.test_files = test_files
    t.warning = false
end

task "test:live" do
    tests = Dir.enum_for(:glob, "test/live/test_*.rb").to_a
    unless system(File.join("test", "live", "run"), *tests)
        $stderr.puts "live tests failed"
        exit 1
    end
end
Rake::TestTask.new("test:gui") do |t|
    t.libs << "."
    t.libs << "lib"

    minitest_set_options(t, "gui")
    t.test_files = FileList["test/gui/**/test_*.rb"]
    t.warning = false
end

task "test" => ["test:gui", "test:core", "test:live"]

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

protogen =
    file "lib/syskit/telemetry/agent/agent_pb.rb" =>
        ["lib/syskit/telemetry/agent/agent.proto"] do
        system(
            "grpc_tools_ruby_protoc",
            "syskit/telemetry/agent/agent.proto",
            "--ruby_out=.",
            "--grpc_out=.",
            chdir: "lib",
            exception: true
        )
    end
task "default" => protogen if USE_GRPC

# For backward compatibility with some scripts that expected hoe
task "gem" => "build"
