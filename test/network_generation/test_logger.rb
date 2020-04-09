# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::NetworkGeneration::LoggerConfigurationSupport do
    attr_reader :syskit_engine
    attr_reader :task, :task_m, :deployment_m, :deployment, :dataflow_dynamics
    before do
        Roby.app.using_task_library "logger"

        @task_m = Syskit::TaskContext.new_submodel do
            output_port "out1", "/double"
            output_port "out2", "/int"
        end
        task_m = @task_m
        @deployment_m = Syskit::Deployment.new_submodel(name: "deployment") do
            task "task", task_m.orogen_model
            add_default_logger
        end
        @deployment = syskit_stub_deployment("deployment", deployment_m)
        @task = deployment.task "task"

        dataflow = flexmock
        dataflow.should_receive(:policy_for).and_return({}).by_default

        @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
        flexmock(syskit_engine)
        syskit_engine.should_receive(:dataflow_dynamics).and_return(dataflow)
        syskit_engine.should_receive(:deployment_tasks).and_return([deployment])
        syskit_engine.should_receive(:deployed_tasks).and_return([@task])
                     .by_default

        @logger_m = Syskit::TaskContext.find_model_from_orogen_name "logger::Logger"
        @logger_m.include Syskit::NetworkGeneration::LoggerConfigurationSupport
    end

    describe "add_logging_to_network" do
        before do
            @dataflow_graph = plan.task_relation_graph_for(Syskit::Flows::DataFlow)
        end
        it "creates a new logger task and uses it if one does not exist" do
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            logger = plan.find_tasks(@logger_m).first

            assert_equal Hash[["state", "task.state"] => {},
                              ["out1", "task.out1"] => {},
                              ["out2", "task.out2"] => {}], @dataflow_graph.edge_info(task, logger)
        end

        it "reuses an existing logger task if there is one" do
            logger = @deployment.task("deployment_Logger")
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            assert_equal Hash[["state", "task.state"] => {},
                              ["out1", "task.out1"] => {},
                              ["out2", "task.out2"] => {}], @dataflow_graph.edge_info(task, logger)
        end

        it "sets default_logger?" do
            logger = deployment.task "deployment_Logger"
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            assert logger.default_logger?
        end

        it "ensures that pending tasks are started after the logger" do
            logger = deployment.task "deployment_Logger"
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            assert task.start_event.should_emit_after?(logger.start_event)
        end

        it "does not synchronize already running tasks with new loggers" do
            flexmock(task).should_receive(:pending?).and_return(false)
            logger = deployment.task "deployment_Logger"
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            refute task.start_event.should_emit_after?(logger.start_event)
        end

        it "does not setup the underlying orocos task if it is not already setup" do
            logger = deployment.task "deployment_Logger"
            flexmock(logger).should_receive(:create_logging_port).never
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
        end

        it "removes unnecessary connections" do
            logger = deployment.task "deployment_Logger"
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            flexmock(deployment).should_receive(:log_port?)
                                .with(task.out1_port)
                                .and_return(false)
            flexmock(deployment).should_receive(:log_port?).and_return(true)
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            assert_equal Hash[["state", "task.state"] => {},
                              ["out2", "task.out2"] => {}],
                         @dataflow_graph.edge_info(task, logger)
        end

        it "completely disconnects a task if all its ports are ignored" do
            logger = deployment.task "deployment_Logger"
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            flexmock(deployment).should_receive(:log_port?).and_return(false)
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            refute @dataflow_graph.has_edge?(task, logger)
        end

        it "leaves connections to tasks that are not part of the final plan alone" do
            logger = deployment.task "deployment_Logger"
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            new_task = deployment.task "task"
            syskit_engine.should_receive(:deployed_tasks).and_return([new_task])
            flexmock(task).should_receive(:connect_ports).never

            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            assert_equal Hash[["state", "task.state"] => {},
                              ["out1", "task.out1"] => {},
                              ["out2", "task.out2"] => {}],
                         @dataflow_graph.edge_info(new_task, logger)
            assert_equal Hash[["state", "task.state"] => {},
                              ["out1", "task.out1"] => {},
                              ["out2", "task.out2"] => {}],
                         @dataflow_graph.edge_info(task, logger)
        end

        it "creates new logging ports if the logger task is already configured" do
            logger = deployment.task "deployment_Logger"
            flexmock(logger).should_receive(:setup?).and_return(true)
            flexmock(logger).should_receive(:create_logging_port)
                            .with("task.state", task, task.state_port).once
            flexmock(logger).should_receive(:create_logging_port)
                            .with("task.out1", task, task.out1_port).once
            flexmock(logger).should_receive(:create_logging_port)
                            .with("task.out2", task, task.out2_port).once
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
        end
    end

    describe "#configure" do
        it "sets up the underlying logging task for each input connection" do
            plan.add_permanent_task(logger = deployment.task("deployment_Logger"))
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            flexmock(logger).should_receive(:create_logging_port)
                            .with("task.out1", task, task.out1_port).once.and_return(true)
            flexmock(logger).should_receive(:create_logging_port)
                            .with("task.out2", task, task.out2_port).once.and_return(true)
            flexmock(logger).should_receive(:create_logging_port)
                            .with("task.state", task, task.state_port).once.and_return(true)
            flexmock(Orocos.conf).should_receive(:apply)
            syskit_start_execution_agents(logger)
            Orocos.allow_blocking_calls do
                logger.orocos_task.create_input_port "task.out1", "/double"
                logger.orocos_task.create_input_port "task.out2", "/int32_t"
                logger.orocos_task.create_input_port "task.state", "/int32_t"
                syskit_configure(logger)
            end
        end
    end
end
