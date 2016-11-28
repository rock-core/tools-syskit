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
    end
end

