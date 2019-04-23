# frozen_string_literal: true

require 'syskit/test/self'

module Syskit
    module Test
        describe NetworkManipulation do
            describe '#syskit_write' do
                before do
                    @task_m = Syskit::RubyTaskContext.new_submodel do
                        input_port 'in', '/int'
                        output_port 'out', '/int'
                    end
                    use_ruby_tasks @task_m => 'test', on: 'stubs'
                end

                it 'connects and writes to the port' do
                    task = syskit_deploy_configure_and_start(@task_m)
                    syskit_write task.in_port, 10
                    assert_equal 10, task.orocos_task.in.read_new
                end

                it 'allows writing to a local port' do
                    task = syskit_deploy_configure_and_start(@task_m)
                    out_reader = task.out_port.reader
                    expect_execution.to { achieve { out_reader.ready? } }
                    sample = expect_execution { syskit_write task.out_port, 10 }
                             .to { have_one_new_sample out_reader }
                    assert_equal 10, sample
                end
            end

            describe '#syskit_stub_and_deploy' do
                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: 'Task')
                    @srv_m = Syskit::DataService.new_submodel(name: 'Srv')
                    @cmp_m = Syskit::Composition.new_submodel(name: 'Cmp')
                    @cmp_m.add @srv_m, as: 'srv'
                end

                it 'stubs a composition' do
                    cmp = syskit_stub_and_deploy(@cmp_m)
                    assert_kind_of @cmp_m, cmp
                    assert_kind_of @srv_m, cmp.srv_child

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end

                it 'stubs device drivers' do
                    dev_m = Syskit::Device.new_submodel(name: 'Dev')
                    dev_m.provides @srv_m

                    cmp = syskit_stub_and_deploy(@cmp_m.use('srv' => dev_m))
                    assert_kind_of @cmp_m, cmp
                    assert_kind_of dev_m, cmp.srv_child
                    assert_equal dev_m, cmp.srv_child.dev0_dev.model

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end

                it 'stubs devices' do
                    dev_m = Syskit::Device.new_submodel(name: 'Dev')
                    dev_m.provides @srv_m
                    task_m = Syskit::TaskContext.new_submodel(name: 'DevDriver')
                    task_m.driver_for dev_m, as: 'dev'

                    cmp = syskit_stub_and_deploy(@cmp_m.use('srv' => task_m))
                    assert_equal dev_m, cmp.srv_child.dev_dev.model

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end

                it 'stubs tags' do
                    profile = Syskit::Actions::Profile.new 'P'
                    profile.tag 'test', @srv_m

                    cmp = syskit_stub_and_deploy(@cmp_m.use('srv' => profile.test_tag))
                    assert_kind_of @srv_m, cmp.srv_child

                    # Make sure that stubbing created a network we can start
                    expect_execution.scheduler(true).to do
                        start cmp
                        start cmp.srv_child
                    end
                end
            end
        end
    end
end
