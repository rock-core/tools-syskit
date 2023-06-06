# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe DataFlowComputation do
            describe "#add_port_info" do
                before do
                    @computation = DataFlowComputation.new
                end

                it "sets the port info to the new information object if it did not have "\
                   "any" do
                    @computation.add_port_info(@task, "port", info = flexmock)
                    assert_equal info, @computation.port_info(@task, "port")
                end

                it "calls #merge on the existing port info when it gets updated" do
                    @computation.add_port_info(@task, "port", info = flexmock)
                    info.should_receive(:merge).with(new_info = flexmock).once
                    @computation.add_port_info(@task, "port", new_info)
                end

                it "sets changed? if a port that had no previous info gets some" do
                    @computation.add_port_info(@task, "port", flexmock)
                    assert @computation.changed?
                end

                it "sets changed? if a port with existing information is updated" do
                    @computation.add_port_info(@task, "port", flexmock(merge: true))
                    @computation.reset_changed
                    refute @computation.changed?
                    @computation.add_port_info(@task, "port", flexmock)
                    assert @computation.changed?
                end

                it "keeps changed? set even if the port is not updated" do
                    @computation.add_port_info(@task, "port", flexmock(merge: false))
                    @computation.add_port_info(@task, "port", flexmock)
                    assert @computation.changed?
                end
            end
        end
    end
end
