require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::LoggerConfigurationSupport do
    attr_reader :task, :task_m, :deployment_m, :deployment, :dataflow_dynamics
    before do
        Roby.app.using_task_library 'logger'
        
        @task_m = Syskit::TaskContext.new_submodel do
            output_port 'out1', '/double'
            output_port 'out2', '/int'
        end
        task_m = @task_m
        @deployment_m = Syskit::Deployment.new_submodel(name: 'deployment') do
            task 'task', task_m.orogen_model
            add_default_logger
        end
        @deployment = syskit_stub_deployment('deployment', deployment_m)
        flexmock(deployment).should_receive(:log_port?).and_return(true).by_default
        flexmock(syskit_engine).should_receive(:deployment_tasks).and_return([deployment])

        @task   = deployment.task 'task'
        flexmock(task).should_receive(:connect_ports).by_default

        logger_m = Syskit::TaskContext.find_model_from_orogen_name 'logger::Logger'
        logger_m.include Syskit::NetworkGeneration::LoggerConfigurationSupport

        @dataflow_dynamics = flexmock('dataflow_dynamics')
        dataflow_dynamics.should_receive(:policy_for).and_return(Hash.new).by_default
        flexmock(syskit_engine).should_receive(:dataflow_dynamics).and_return(dataflow_dynamics)
    end

    describe "add_logging_to_network" do
        it "should declare connections from the task's output ports to the logger task" do
            logger = deployment.task 'deployment_Logger'
            flexmock(task).should_receive(:connect_ports).once.
                with(logger,
                     Hash[['out1', 'task.out1'] => Hash.new,
                          ['out2', 'task.out2'] => Hash.new])
            flexmock(syskit_engine).should_receive(:deployment_tasks).and_return([deployment])

            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end

        it "should create a new logger task if one does not exist" do
            logger_m = Syskit::TaskContext.find_model_from_orogen_name 'logger::Logger'
            plan.add(logger = logger_m.new)
            flexmock(deployment).should_receive(:task).with("deployment_Logger").and_return(logger)

            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end

        it "should set the logger as default logger" do
            logger = deployment.task 'deployment_Logger'
            flexmock(logger).should_receive(:default_logger=).with(true).once
            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end

        it "should ensure that pending tasks are started after the logger" do
            logger = deployment.task 'deployment_Logger'
            flexmock(task).should_receive(:should_start_after).with(logger.start_event).once
            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end

        it "should not synchronize already running tasks with new loggers" do
            logger = deployment.task 'deployment_Logger'
            flexmock(task).should_receive(:pending?).and_return(false)
            flexmock(task).should_receive(:should_start_after).with(logger.start_event).never
            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end

        it "should not setup the underlying orocos task if it is not already setup" do
            logger = deployment.task 'deployment_Logger'
            flexmock(logger).should_receive(:setup?).and_return(false)
            flexmock(logger).should_receive(:createLoggingPort).never
            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end

        it "should setup the underlying orocos task if the logger is already setup" do
            logger = deployment.task 'deployment_Logger'
            flexmock(logger).should_receive(:setup?).and_return(true)
            flexmock(logger).should_receive(:createLoggingPort).
                with('task.out1', task, task.out1_port).once
            flexmock(logger).should_receive(:createLoggingPort).
                with('task.out2', task, task.out2_port).once
            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)
        end
    end

    describe "#configure" do
        it "should setup the underlying logging task for each input connection" do
            plan.add_permanent(logger = deployment.task('deployment_Logger'))
            flexmock(task).should_receive(:connect_ports).pass_thru
            Syskit::NetworkGeneration::LoggerConfigurationSupport.
                add_logging_to_network(syskit_engine, plan)

            flexmock(logger).should_receive(:createLoggingPort).
                with('task.out1', task, task.out1_port).once
            flexmock(logger).should_receive(:createLoggingPort).
                with('task.out2', task, task.out2_port).once
            flexmock(Orocos.conf).should_receive(:apply)
            deployment.start!
            logger.configure
        end
    end
end

