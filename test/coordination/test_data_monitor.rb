# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Coordination::DataMonitor do
    describe "#poll" do
        class StreamStub < Array
            def read_new
                shift
            end
        end

        attr_reader :streams, :predicate, :data_monitor
        before do
            @streams = (1..3).map { StreamStub.new }
            @predicate = flexmock
            @data_monitor = Syskit::Coordination::DataMonitor
                            .new(nil, streams)
                            .trigger_on(predicate)
        end
        it "should call #call on the predicate for each new sample and then call #finalize" do
            samples = (1..3).map { flexmock }
            streams[0] << samples[0]
            streams[1] << samples[1] << samples[2]
            predicate.should_receive(:call).with(streams[0], samples[0]).once.ordered
            predicate.should_receive(:call).with(streams[1], samples[1]).once.ordered
            predicate.should_receive(:call).with(streams[1], samples[2]).once.ordered
            predicate.should_receive(:call).with(streams[2], any).never
            predicate.should_receive(:finalize).ordered
            data_monitor.poll(nil)
        end
        it "should not call #trigger if #finalize returns false" do
            predicate.should_receive(:finalize).once.and_return(false)
            flexmock(data_monitor).should_receive(:trigger).never
            assert !data_monitor.poll(nil)
        end
        it "should call #trigger if #finalize returns true" do
            root_task = flexmock
            predicate.should_receive(:finalize).once.and_return(true)
            flexmock(data_monitor).should_receive(:trigger).once
                                  .with(root_task)
            assert data_monitor.poll(root_task)
        end
    end
end
