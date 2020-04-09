# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module RobyApp
        describe LoggingConfiguration do
            subject { LoggingConfiguration.new }

            describe "global conf logging control" do
                it "is enabled by default" do
                    assert subject.conf_logs_enabled?
                end
                it "is disabled by disable_conf_logging" do
                    subject.disable_conf_logging
                    assert !subject.conf_logs_enabled?
                end
                it "is reenabled by enable_conf_logging" do
                    subject.enable_conf_logging
                    assert subject.conf_logs_enabled?
                end
            end

            describe "global port logging control" do
                it "is enabled by default" do
                    assert subject.port_logs_enabled?
                end
                it "is disabled by disable_port_logging" do
                    subject.disable_port_logging
                    assert !subject.port_logs_enabled?
                end
                it "is reenabled by enable_port_logging" do
                    subject.enable_port_logging
                    assert subject.port_logs_enabled?
                end
            end

            describe "group creation and update" do
                it "creates a new group" do
                    group = subject.create_group "test"
                    assert_same group, subject.group_by_name("test")
                end
                it "yields the group for setup" do
                    recorder = flexmock
                    recorder.should_receive(:called).with(LoggingGroup).once
                    subject.create_group "test" do |g|
                        recorder.called(g)
                    end
                end
                it "raises ArgumentError if trying to create group with an existing name" do
                    subject.create_group "test"
                    assert_raises(ArgumentError) { subject.create_group("test") }
                end
                it "raises ArgumentError if trying to resolve a group that does not exist" do
                    assert_raises(ArgumentError) { subject.group_by_name("test") }
                end
                it "allows to update an existing group" do
                    group = subject.create_group "test"
                    recorder = flexmock
                    recorder.should_receive(:called).with(group).once
                    subject.update_group "test" do |g|
                        recorder.called(g)
                    end
                end
                it "allows to enable a group at creation time" do
                    group = subject.create_group "test", enabled: true
                    assert group.enabled?
                end
                it "allows to disable a group at creation time" do
                    group = subject.create_group "test", enabled: false
                    assert !group.enabled?
                end
            end

            describe "#port_excluded_from_log?" do
                describe "empty configuration" do
                    it "returns false" do
                        assert !subject.port_excluded_from_log?(subject)
                    end
                end

                describe "a configuration with groups" do
                    attr_reader :group0, :group1
                    before do
                        @group0 = flexmock(subject.create_group("group0", enabled: true))
                        @group1 = flexmock(subject.create_group("group1", enabled: false))
                    end

                    let(:port) { flexmock }

                    it "returns false if no groups match the port" do
                        group0.should_receive(:matches_port?).with(port).and_return(false)
                        group1.should_receive(:matches_port?).with(port).and_return(false)
                        assert !subject.port_excluded_from_log?(port)
                    end

                    it "returns false if at least one group matches, and all of them are enabled" do
                        group0.should_receive(:matches_port?).with(port).and_return(true)
                        group1.should_receive(:matches_port?).with(port).and_return(false)
                        assert !subject.port_excluded_from_log?(port)
                    end

                    it "returns false if at least one group matches, and at least one of them is enabled" do
                        group0.should_receive(:matches_port?).with(port).and_return(true)
                        group1.should_receive(:matches_port?).with(port).and_return(true)
                        assert !subject.port_excluded_from_log?(port)
                    end

                    it "returns true if at least one group matches, and all of them are disabled" do
                        group0.should_receive(:matches_port?).with(port).and_return(false)
                        group1.should_receive(:matches_port?).with(port).and_return(true)
                        assert subject.port_excluded_from_log?(port)
                    end
                end
            end

            describe "enabling and disabling log groups" do
                it "disables log groups" do
                    group = subject.create_group "test", enabled: true
                    assert group.enabled?
                    subject.disable_log_group "test"
                    assert !group.enabled?
                end
                it "enables log groups" do
                    group = subject.create_group "test", enabled: false
                    assert !group.enabled?
                    subject.enable_log_group "test"
                    assert group.enabled?
                end
            end

            describe "#enable_log_group" do
            end
        end
    end
end
