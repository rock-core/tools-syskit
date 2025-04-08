# frozen_string_literal: true

using_task_library "orogen_syskit_tests"

module Syskit
    # Provide an alias for the RockLogger is set to the logger model in orogen/logger.rb
    # as OroGen.logger is taken (can't access through OroGen.logger.LoggerTask)
    RockLogger = OroGen.syskit_model_by_orogen_name("logger::Logger")
end

Syskit.extend_model Syskit::RockLogger do
    provides Syskit::LoggerService
    include Syskit::NetworkGeneration::LoggerConfigurationSupport

    def update_properties
        super

        properties.overwrite_existing_files = false
        properties.auto_timestamp_files = false
    end
end

module Syskit
    class LogicalTimeLoggingTest < Syskit::Test::ComponentTest
        run_live

        attr_reader :task

        before do
            Syskit.conf.logs.enable_port_logging
            @task = syskit_deploy(
                OroGen.orogen_syskit_tests.LogicalTimeLoggingTest
                    .deployed_as("logical_time_logging_test")
            )

            @timestamp = Time.at(1234)
            @task.properties.test_type_timestamp = @timestamp
        end

        after do
            Syskit.conf.logs.disable_port_logging
        end

        it "logs the correct logical time field value and metadata" do
            syskit_configure_and_start(@task)
            logger = plan.find_tasks(Syskit::RockLogger).first
            logfile_path = File.join(Roby.app.log_dir, "logical_time_field.0.log")
            logger.properties.file = logfile_path
            syskit_configure_and_start(logger)

            expect_execution.to do
                have_one_new_sample(task.out_port)
                    .matching { |s| s.timestamp == Time.at(1234) }
            end

            syskit_stop(@task)
            syskit_stop(logger)

            file = Pocolog::Logfiles.open(logfile_path)
            file.stream("logical_time_logging_test.out").samples.each do |_, lg, _|
                assert_equal @timestamp, lg
            end
        end
    end
end
