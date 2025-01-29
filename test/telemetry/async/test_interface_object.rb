# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"

module Syskit
    module Telemetry
        module Async
            describe InterfaceObject do
                before do
                    @object = InterfaceObject.new(flexmock, "something", flexmock)
                end

                describe "on_reachable" do
                    it "registers a callback called when the object " \
                       "becomes reachable" do
                        recorder = flexmock
                        recorder.should_receive(:called).with(raw = flexmock).once
                        @object.on_reachable do
                            recorder.called(_1)
                        end
                        @object.reachable!(raw)
                    end

                    it "calls the callback right away if the object is already " \
                       "reachable" do
                        recorder = flexmock
                        recorder.should_receive(:called).with(raw = flexmock).once
                        @object.reachable!(raw)
                        @object.on_reachable do
                            recorder.called(_1)
                        end
                    end

                    it "stops calling if the value returned on registration was " \
                       "disposed" do
                        recorder = flexmock
                        recorder.should_receive(:called).never
                        disposable = @object.on_reachable do
                            recorder.called(_1)
                        end
                        disposable.dispose
                        @object.reachable!(flexmock)
                    end
                end
            end
        end
    end
end
