# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Test
        describe NetworkManipulation do
            describe "#syskit_write" do
                before do
                    @task_m = Syskit::RubyTaskContext.new_submodel do
                        input_port "in", "/int"
                        output_port "out", "/int"
                    end
                    use_ruby_tasks @task_m => "test", on: "stubs"
                end

                it "connects and writes to the port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    syskit_write task.in_port, 10
                    assert_equal 10, task.orocos_task.in.read_new
                end

                it "allows writing to a local port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    out_reader = task.out_port.reader
                    expect_execution.to { achieve { out_reader.ready? } }
                    sample = expect_execution { syskit_write task.out_port, 10 }
                             .to { have_one_new_sample out_reader }
                    assert_equal 10, sample
                end

                it "buffers multiple samples" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    syskit_write task.in_port, 10, 20, 30
                    assert_equal 10, task.orocos_task.in.read_new
                    assert_equal 20, task.orocos_task.in.read_new
                    assert_equal 30, task.orocos_task.in.read_new
                    assert_nil task.orocos_task.in.read_new
                end
            end

            describe "#syskit_create_writer" do
                before do
                    @task_m = Syskit::RubyTaskContext.new_submodel do
                        input_port "in", "/int"
                        output_port "out", "/int"
                    end
                    use_ruby_tasks @task_m => "test", on: "stubs"
                end

                it "creates a writer to the port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    w = syskit_create_writer task.in_port
                    w.write(10)
                    assert_equal 10, task.orocos_task.in.read_new
                end

                it "allows creating a writer to a local port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    out_reader = task.out_port.reader
                    expect_execution.to { achieve { out_reader.ready? } }
                    w = syskit_create_writer task.out_port
                    sample = expect_execution { w.write 10 }
                             .to { have_one_new_sample out_reader }
                    assert_equal 10, sample
                end
            end

            describe "#syskit_create_reader" do
                before do
                    @task_m = Syskit::RubyTaskContext.new_submodel do
                        input_port "in", "/int"
                        output_port "out", "/int"
                    end
                    use_ruby_tasks @task_m => "test", on: "stubs"
                end

                it "creates a reader to the port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    r = syskit_create_reader task.out_port
                    task.orocos_task.out.write(10)
                    assert_equal 10, r.read_new
                end

                it "allows creating a reader to a local port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    in_writer = task.in_port.writer
                    expect_execution.to { achieve { in_writer.ready? } }
                    r = syskit_create_reader task.in_port
                    sample = expect_execution { in_writer.write 10 }
                             .to { have_one_new_sample r }
                    assert_equal 10, sample
                end
            end

            describe "#syskit_stub_and_deploy" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: "Task")
                    @srv_m = Syskit::DataService.new_submodel(name: "Srv")
                    @cmp_m = Syskit::Composition.new_submodel(name: "Cmp")
                    @cmp_m.add @srv_m, as: "srv"
                end

                it "stubs a composition" do
                    cmp = syskit_stub_and_deploy(@cmp_m)
                    assert_kind_of @cmp_m, cmp
                    assert_kind_of @srv_m, cmp.srv_child

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end

                it "stubs device drivers" do
                    dev_m = Syskit::Device.new_submodel(name: "Dev")
                    dev_m.provides @srv_m

                    cmp = syskit_stub_and_deploy(@cmp_m.use("srv" => dev_m))
                    assert_kind_of @cmp_m, cmp
                    assert_kind_of dev_m, cmp.srv_child
                    assert_equal dev_m, cmp.srv_child.dev0_dev.model

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end

                it "stubs devices" do
                    dev_m = Syskit::Device.new_submodel(name: "Dev")
                    dev_m.provides @srv_m
                    task_m = Syskit::TaskContext.new_submodel(name: "DevDriver")
                    task_m.driver_for dev_m, as: "dev"

                    cmp = syskit_stub_and_deploy(@cmp_m.use("srv" => task_m))
                    assert_equal dev_m, cmp.srv_child.dev_dev.model

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end

                it "stubs tags" do
                    profile = Syskit::Actions::Profile.new "P"
                    profile.tag "test", @srv_m

                    cmp = syskit_stub_and_deploy(@cmp_m.use("srv" => profile.test_tag))
                    assert_kind_of @srv_m, cmp.srv_child

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end
            end

            describe "#syskit_deploy" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: "Test")
                    syskit_stub_deployment_model(@task_m, "orogen_default_Test")
                end

                it "uses a usable deployment from the requirement's deployment group" do
                    task = syskit_deploy(@task_m.deployed_as("local_level", on: "stubs"))
                    assert_equal "local_level", task.orocos_name
                end

                it "prefers a requirement-level deployment over a test-level one" do
                    use_deployment @task_m => "test_level", on: "stubs"
                    task = syskit_deploy(@task_m.deployed_as("local_level", on: "stubs"))
                    assert_equal "local_level", task.orocos_name
                end

                it "uses a usable deployment from the test's deployment group" do
                    use_deployment @task_m => "test_level", on: "stubs"
                    task = syskit_deploy(@task_m)
                    assert_equal "test_level", task.orocos_name
                end
            end

            describe "#syskit_configure" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    @cmp_m = Syskit::Composition.new_submodel
                    @cmp_m.add @task_m, as: "test"
                end

                it "configures a plain task context" do
                    task = syskit_stub_and_deploy(@task_m)
                    syskit_configure task
                    assert task.setup?
                end
                it "configures a composition" do
                    cmp = syskit_stub_and_deploy(@cmp_m)
                    syskit_configure cmp
                    assert cmp.test_child.setup?
                end
                it "does not bails out for having a fixed point if tasks do have their state readers connected" do
                    task = syskit_stub_and_deploy(@task_m)
                    timeout_expired = Concurrent::Event.new
                    flexmock(task)
                        .should_receive(:read_current_state)
                        .and_return { :PRE_OPERATIONAL if timeout_expired.set? }
                    syskit_start_execution_agents task
                    Thread.new do
                        sleep 0.1
                        timeout_expired.set
                    end
                    syskit_configure task
                    assert task.setup?
                end
            end
        end
    end
end
