# frozen_string_literal: true

require 'syskit/test/self'

module Syskit
    describe DynamicDataSource do
        describe 'from a port matcher' do
            it 'raises on creation of the matcher\'s type cannot be inferred' do
                task_m = Syskit::TaskContext.new_submodel do
                    output_port 'out', '/double'
                end
                matcher = task_m.match.out_port
                flexmock(matcher).should_receive(try_resolve_type: nil)
                e = assert_raises(ArgumentError) do
                    Models::DynamicDataSource.create(matcher)

                end
                assert_equal 'cannot create a dynamic data source from a matcher '\
                             'whose type cannot be inferred', e.message
            end

            describe '#update' do
                attr_reader :task, :ds

                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        output_port 'out', '/double'
                    end
                    @ds_m = Models::DynamicDataSource
                            .create(@task_m.match.running.out_port)
                    @task = syskit_stub_and_deploy(@task_m, remote_task: false)
                    @ds = @ds_m.instanciate(@task)
                end

                it 'returns false if there are no matches in the plan' do
                    refute @ds.update
                end

                it 'returns true if there is a new match in the plan '\
                   'and resolves the match' do
                    syskit_configure_and_start(@task)

                    assert @ds.update
                    expect_execution.to { achieve { ds.connected? } }
                    sample = expect_execution { syskit_write @task.out_port, 0 }
                             .to { have_one_new_sample ds }
                    assert_equal 0, sample
                end

                it 'returns true if the current match is still valid '\
                   'and keeps the match' do
                    syskit_configure_and_start(@task)

                    @ds.update
                    expect_execution.to { achieve { ds.connected? } }

                    assert @ds.update
                    assert ds.connected?

                    sample = expect_execution { syskit_write @task.out_port, 0 }
                             .to { have_one_new_sample ds }
                    assert_equal 0, sample
                end

                it 'returns false if the current match is not valid anymore '\
                   'and resets the reader' do
                    syskit_configure_and_start(@task)

                    @ds.update
                    expect_execution.to { achieve { ds.connected? } }
                    syskit_stop task

                    refute @ds.update
                    refute @ds.valid?
                    refute @ds.connected?
                end
            end

            describe '#read_new' do
                attr_reader :task, :ds

                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        output_port 'out', '/double'
                    end
                    @task = syskit_stub_deploy_configure_and_start(
                        @task_m, remote_task: false
                    )
                end

                it 'returns nil if there are no samples' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    assert_nil ds.read_new
                end

                it 'returns nil if there are only already read samples' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    assert_nil ds.read_new
                    execute { syskit_write @task.out_port, 2 }
                    ds.read_new
                    assert_nil ds.read_new
                end

                it 'returns new samples' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 2, ds.read_new
                end

                it 'processes the samples through the resolver' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .transform { |v| v * 2 }
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 4, ds.read_new
                end

                it 're-attaches to a new source' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    syskit_stop @task

                    task = syskit_stub_deploy_configure_and_start(
                        @task_m, remote_task: false
                    )
                    wait_until_connected ds
                    execute { syskit_write task.out_port, 4 }
                    assert_equal 4, ds.read_new
                end

                def wait_until_connected(ds)
                    assert ds.update, "#{ds} cannot be connected, no port to attach to"
                    expect_execution.to { achieve { ds.connected? } }
                end
            end

            describe '#read' do
                attr_reader :task, :ds

                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        output_port 'out', '/double'
                    end
                    @task = syskit_stub_deploy_configure_and_start(
                        @task_m, remote_task: false
                    )
                end

                it 'returns nil if there are no samples' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    assert_nil ds.read_new
                end

                it 'returns new samples' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 2, ds.read
                end

                it 'processes the samples through the resolver' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .transform { |v| v * 2 }
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 4, ds.read
                end

                it 'returns already read samples if they come from the same source' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 2, ds.read
                    assert_equal 2, ds.read
                end

                it 'returns nil even with already read samples if the source stopped' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 2, ds.read
                    syskit_stop @task
                    ds.update
                    assert_nil ds.read
                end

                it 'returns nil even with already read samples if the source changed' do
                    ds = Models::DynamicDataSource
                         .create(@task_m.match.running.out_port)
                         .instanciate(@task)
                    wait_until_connected ds
                    execute { syskit_write @task.out_port, 2 }
                    assert_equal 2, ds.read
                    syskit_stop @task

                    task = syskit_stub_deploy_configure_and_start(
                        @task_m, remote_task: false
                    )
                    wait_until_connected ds
                    execute { syskit_write task.out_port, 4 }
                    assert_equal 4, ds.read
                end

                def wait_until_connected(ds)
                    assert ds.update, "#{ds} cannot be connected, no port to attach to"
                    expect_execution.to { achieve { ds.connected? } }
                end
            end
        end

        describe 'from composition child' do
            attr_reader :cmp, :ds

            before do
                task_m = Syskit::TaskContext.new_submodel do
                    output_port 'out', '/double'
                end
                @cmp_m = Syskit::Composition.new_submodel do
                    add task_m, as: 'test'
                end

                @cmp = syskit_stub_and_deploy(@cmp_m, remote_task: false)
            end

            describe '#update' do
                it 'returns true if the underlying composition is not finalized' do
                    ds_m = Models::DynamicDataSource.create(@cmp_m.test_child.out_port)
                    assert ds_m.instanciate(@cmp).update
                end

                it 'returns false once the underlying composition is finalized' do
                    ds_m = Models::DynamicDataSource.create(@cmp_m.test_child.out_port)
                    ds = ds_m.instanciate(@cmp)
                    expect_execution { plan.unmark_mission_task(@cmp) }
                        .garbage_collect(true)
                        .to_run
                    refute ds.update
                end
            end

            describe '#read_new' do
                attr_reader :task, :ds

                before do
                    syskit_configure_and_start(@cmp)
                end

                it 'returns nil if there are no samples' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .instanciate(@cmp)
                    wait_until_connected ds
                    assert_nil ds.read_new
                end

                it 'returns nil if there are only already read samples' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .instanciate(@cmp)
                    wait_until_connected ds
                    assert_nil ds.read_new
                    execute { syskit_write @cmp.test_child.out_port, 2 }
                    ds.read_new
                    assert_nil ds.read_new
                end

                it 'returns new samples' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .instanciate(@cmp)
                    wait_until_connected ds
                    execute { syskit_write @cmp.test_child.out_port, 2 }
                    assert_equal 2, ds.read_new
                end

                it 'processes the samples through the resolver' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .transform { |v| v * 2 }
                         .instanciate(@cmp)
                    wait_until_connected ds
                    execute { syskit_write @cmp.test_child.out_port, 2 }
                    assert_equal 4, ds.read_new
                end

                def wait_until_connected(ds)
                    assert ds.update, "#{ds} cannot be connected, no port to attach to"
                    expect_execution.to { achieve { ds.connected? } }
                end
            end

            describe '#read_new' do
                attr_reader :task, :ds

                before do
                    syskit_configure_and_start(@cmp)
                end

                it 'returns nil if there are no samples' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .instanciate(@cmp)
                    wait_until_connected ds
                    assert_nil ds.read_new
                end

                it 'returns new samples' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .instanciate(@cmp)
                    wait_until_connected ds
                    execute { syskit_write @cmp.test_child.out_port, 2 }
                    assert_equal 2, ds.read
                end

                it 'returns already read samples' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .instanciate(@cmp)
                    wait_until_connected ds
                    assert_nil ds.read_new
                    execute { syskit_write @cmp.test_child.out_port, 2 }
                    ds.read
                    assert_equal 2, ds.read
                end

                it 'processes the samples through the resolver' do
                    ds = Models::DynamicDataSource
                         .create(@cmp_m.test_child.out_port)
                         .transform { |v| v * 2 }
                         .instanciate(@cmp)
                    wait_until_connected ds
                    execute { syskit_write @cmp.test_child.out_port, 2 }
                    assert_equal 4, ds.read
                end

                def wait_until_connected(ds)
                    assert ds.update, "#{ds} cannot be connected, no port to attach to"
                    expect_execution.to { achieve { ds.connected? } }
                end
            end
        end
    end
end
