# frozen_string_literal: true

require "rake/testtask"

task :default

TESTOPTS = ENV.delete("TESTOPTS") || ""

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

def core_task(name, files_setup)
    Rake::TestTask.new("test:core#{name}") do |t|
        t.libs << "."
        t.libs << "lib"
        minitest_set_options(t, "core")
        test_files = FileList["test/**/test_*.rb", *files_setup]
        test_files = test_files
                     .exclude("test/ros/**/*.rb")
                     .exclude("test/gui/**/*.rb")
                     .exclude("test/live/**/*.rb")
                     .exclude("test/telemetry/**/*.rb")
        t.test_files = test_files
        t.warning = false
    end
end

def core(early_deploy: false, capture_errors_during_network_resolution: false,
    all_features: false)
    s = ":no-features"
    if capture_errors_during_network_resolution
        s = ":capture-errors"
        files_setup = ["test/features/capture_errors.rb"]
    elsif early_deploy
        s = ":early-deploy"
        files_setup = ["test/features/early_deploy.rb"]
    elsif all_features
        s = ":all-features"
        files_setup = ["test/features/all_features.rb"]
    end

    core_task(s, files_setup)
end

Rake::TestTask.new("test:telemetry") do |t|
    t.libs << "."
    t.libs << "lib"
    minitest_set_options(t, "telemetry")
    t.test_files = FileList["test/telemetry/**/test_*.rb"]
    t.warning = false
end

desc "Run separate tests that require a live syskit instance"
task "test:live" do
    tests = Dir.enum_for(:glob, "test/live/test_*.rb").to_a
    unless system(File.join("test", "live", "run"), *tests)
        $stderr.puts "live tests failed"
        exit 1
    end
end

desc "run gui-only tests"
Rake::TestTask.new("test:gui") do |t|
    t.libs << "."
    t.libs << "lib"

    minitest_set_options(t, "gui")
    t.test_files = FileList["test/gui/**/test_*.rb"]
    t.warning = false
end

core early_deploy: true
core capture_errors_during_network_resolution: true
core all_features: true
core
desc "Run core library tests, excluding GUI and live tests"
task "test:core" => %w[test:core:no-features test:core:early-deploy
                       test:core:capture-errors test:core:all-features]

desc "Run all tests"
task "test" => ["test:gui", "test:core", "test:live", "test:telemetry"]

task "rubocop" do
    raise "rubocop failed" unless system(ENV["RUBOCOP_CMD"] || "rubocop")
end
task "test" => "rubocop" if ENV["RUBOCOP"] != "0"

protogen =
    file "lib/syskit/telemetry/agent/agent_pb.rb" =>
        ["lib/syskit/telemetry/agent/agent.proto"] do
        success = system(
            "grpc_tools_ruby_protoc",
            "syskit/telemetry/agent/agent.proto",
            "--ruby_out=.",
            "--grpc_out=.",
            chdir: "lib"
        )
        raise "grpc_tools_ruby_protoc call failed" unless success
    end
task "default" => protogen if USE_GRPC

# For backward compatibility with some scripts that expected hoe
task "gem" => "build"
