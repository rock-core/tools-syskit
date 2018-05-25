require 'syskit/test/self'

module Syskit
    module NetworkGeneration
        describe PortDynamics::Trigger do
            attr_reader :trigger, :trigger_name, :period, :sample_count
            before do
                @trigger = PortDynamics::Trigger.new(
                    @trigger_name = 'trigger_test', @period = flexmock, @sample_count = flexmock)
            end
            it "defines hash-compatible equality" do
                trigger1 = PortDynamics::Trigger.new(
                    trigger_name, period, sample_count)
                assert_equal Set[trigger], Set[trigger1]
            end
            it "is inequal in the hash sense if the name differs" do
                trigger1 = PortDynamics::Trigger.new(
                    'other_name', period, sample_count)
                refute_equal Set[trigger], Set[trigger1]
            end
            it "is inequal in the hash sense if the period differs" do
                trigger1 = PortDynamics::Trigger.new(
                    trigger_name, flexmock, sample_count)
                refute_equal Set[trigger], Set[trigger1]
            end
            it "is inequal in the hash sense if the sample_count differs" do
                trigger1 = PortDynamics::Trigger.new(
                    trigger_name, period, flexmock)
                refute_equal Set[trigger], Set[trigger1]
            end
        end
        describe PortDynamics do
            describe "#merge" do
                # This tests against a memory explosion regression.
                # InstanceRequirements are routinely merged against themselves,
                # thus PortDynamics too (through InstanceRequirements#dynamics).
                # This led to having the trigger array of #dynamics explode
                # after a few deployments.
                it "stays identical if merged with a duplicate of itself" do
                    dynamics0 = PortDynamics.new('port')
                    dynamics0.add_trigger 'test', 1, 1
                    dynamics1 = PortDynamics.new('port')
                    dynamics1.add_trigger 'test', 1, 1
                    dynamics0.merge(dynamics1)
                    assert_equal 1, dynamics0.triggers.size
                end
            end
        end

        describe DataFlowDynamics do
            attr_reader :dynamics
            before do
                @dynamics = NetworkGeneration::DataFlowDynamics.new(plan)
            end

            describe "initial port information" do
                it "uses the task's requirements as final information for a port" do
                    stub_t = stub_type '/test'
                    task_m = Syskit::TaskContext.new_submodel do
                        output_port 'out', stub_t
                    end
                    req = task_m.to_instance_requirements.add_port_period('out', 0.1)
                    task = req.instanciate(plan)
                    dynamics.propagate([task])
                    assert dynamics.has_final_information_for_port?(task, 'out')
                    port_dynamics = dynamics.port_info(task, 'out')

                    assert_equal [PortDynamics::Trigger.new('period', 0.1, 1)],
                        port_dynamics.triggers.to_a
                end

                describe "master/slave deployments" do
                    before do
                        task_m = Syskit::TaskContext.new_submodel do
                            output_port 'out', '/double'
                        end
                        deployment_m = Syskit::Deployment.new_submodel do
                            master = task('master', task_m.orogen_model).
                                periodic(0.1)
                            slave  = task 'slave', task_m.orogen_model
                            slave.slave_of(master)
                        end

                        plan.add(deployment = deployment_m.new)
                        @master = deployment.task('master')
                        @slave  = deployment.task('slave')
                        dynamics.reset([@master, @slave])
                    end

                    it "resolves if called for the slave after the master" do
                        flexmock(dynamics).should_receive(:set_port_info).
                            with(@slave, nil, any).once
                        flexmock(dynamics).should_receive(:set_port_info)
                        dynamics.initial_information(@master)
                        dynamics.initial_information(@slave)
                        assert dynamics.has_final_information_for_task?(@master)
                        assert dynamics.has_final_information_for_task?(@slave)
                    end

                    it "resolves if called for the master after the slave" do
                        flexmock(dynamics).should_receive(:set_port_info).
                            with(@slave, nil, any).once
                        flexmock(dynamics).should_receive(:set_port_info)
                        dynamics.initial_information(@slave)
                        dynamics.initial_information(@master)
                        assert dynamics.has_final_information_for_task?(@master)
                        assert dynamics.has_final_information_for_task?(@slave)
                    end

                    it "resolves the slave's main trigger using the master's" do
                        dynamics.propagate([@master, @slave])
                        assert_equal 0.1, dynamics.task_info(@slave).
                            minimal_period
                    end

                    it "samples the slave's port using the trigger activity" do
                        source_m = Syskit::TaskContext.new_submodel do
                            output_port('out', '/double')
                        end
                        master_m = Syskit::TaskContext.new_submodel
                        sink_m = Syskit::TaskContext.new_submodel do
                            input_port 'in', '/double'
                            output_port('out', '/double').triggered_on('in')
                        end
                        deployment_m = Syskit::Deployment.new_submodel do
                            task('source', source_m.orogen_model).
                                periodic(0.01)
                            master = task('master', master_m.orogen_model).
                                periodic(0.1)
                            slave  = task 'slave', sink_m.orogen_model
                            slave.slave_of(master)
                        end

                        plan.add(deployment = deployment_m.new)
                        master = deployment.task('master')
                        source = deployment.task('source')
                        slave  = deployment.task('slave')
                        source.out_port.connect_to slave.in_port
                        dynamics.propagate([master, slave, source])

                        port_info = dynamics.port_info(slave, 'out')
                        assert_equal 1, port_info.triggers.size
                        assert(port_info.triggers.first.sample_count > 10)
                    end
                end
            end
        end
    end
end
