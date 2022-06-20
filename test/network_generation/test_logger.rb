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
                     .by_default
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

        it "marks the loggers as permanent" do
            logger = @deployment.task("deployment_Logger")
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            assert plan.permanent_task?(logger)
        end

        it "does not mark a logger as permanent if it is unused" do
            logger = @deployment.task("deployment_Logger")
            flexmock(deployment).should_receive(log_port?: false)
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            refute plan.permanent_task?(logger)
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

        it "cleans up connections while sharing a logger across deployments" do
            deployment2 = syskit_stub_deployment("deployment2", deployment_m)
            task2 = deployment2.task "task"
            syskit_engine.should_receive(:deployment_tasks)
                         .and_return([@deployment, deployment2])
            syskit_engine.should_receive(:deployed_tasks)
                         .and_return([@task, task2])

            logger = deployment.task "deployment_Logger"
            deployment2.logger_task = logger

            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            flexmock(deployment).should_receive(log_port?: false)
            flexmock(deployment2).should_receive(log_port?: false)
            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)
            refute @dataflow_graph.has_edge?(task, logger)
            refute @dataflow_graph.has_edge?(task2, logger)
        end

        it "sets up logging while sharing a logger across deployments" do
            deployment2 = syskit_stub_deployment("deployment2", deployment_m)
            task2 = deployment2.task "task"
            syskit_engine.should_receive(:deployment_tasks)
                         .and_return([@deployment, deployment2])
            syskit_engine.should_receive(:deployed_tasks)
                         .and_return([@task, task2])

            logger = deployment.task "deployment_Logger"
            deployment2.logger_task = logger

            Syskit::NetworkGeneration::LoggerConfigurationSupport
                .add_logging_to_network(syskit_engine, plan)

            assert @dataflow_graph.has_edge?(task, logger)
            assert @dataflow_graph.has_edge?(task2, logger)
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

        describe "#logger_name" do
            before do
                Syskit.conf.logs.enable_port_logging
            end

            after do
                Syskit.conf.logs.disable_port_logging
            end

            it "allows to specify a nonstandard logger name" do
                Roby.app.using_task_library "orogen_syskit_tests"
                logger_m = Syskit::TaskContext.find_model_from_orogen_name(
                    "logger::Logger"
                )

                task_m = OroGen.orogen_syskit_tests.Empty.to_instance_requirements
                task_m.use_deployment(
                    OroGen::Deployments.syskit_test_nonstandard_logger_name,
                    logger_name: "nonstandard_logger_name"
                )

                syskit_run_planner_with_full_deployment(stub: false) do
                    run_planners(task_m)
                end

                logger_task = plan.find_tasks(logger_m).to_a
                assert_equal 1, logger_task.size
                assert_equal "nonstandard_logger_name",
                             logger_task.first.orocos_name
            end
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
