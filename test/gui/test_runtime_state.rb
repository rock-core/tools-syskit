# frozen_string_literal: true

require "syskit/test/self"
require "vizkit"
require "metaruby/gui"
require "roby/gui/exception_view"
require "syskit/gui/state_label"
require "syskit/gui/runtime_state"
require "roby/interface/async/interface"

module Syskit
    module GUI
        describe RuntimeState do
            attr_reader :subject
            attr_reader :syskit
            attr_reader :client
            before do
                @syskit = flexmock(Roby::Interface::Async::Interface.new)
                @syskit.should_receive(:client).and_return { client }
                Orocos.allow_blocking_calls do
                    @subject = RuntimeState.new(syskit: syskit)
                end
                @client = flexmock("client")
                @client.should_receive(:jobs).and_return([])
                @client.should_receive(:actions).and_return([])
                @client.should_receive(:log_server_port).and_return(7357)
                @client.should_receive(:syskit)
            end

            it "refreshes logging configuration widget on reachable" do
                flexmock(subject.ui_logging_configuration).should_receive(:refresh).once
                syskit.run_hook :on_reachable
            end

            it "refreshes logging configuration widget on unreachable" do
                flexmock(subject.ui_logging_configuration).should_receive(:refresh).once
                syskit.run_hook :on_unreachable
            end
        end
    end
end
