require 'pry'
require 'syskit'
require 'syskit/test'

describe Syskit::RobyApp::Plugin do
    include Syskit::SelfTest

    describe "#enable" do
        it "makes Roby.syskit_engine return app.plan.syskit_engine" do
            assert Roby.app.plan.syskit_engine
            assert_equal Roby.app.plan.syskit_engine, Roby.syskit_engine
        end
        it "makes Roby.app.syskit_engine return app.plan.syskit_engine" do
            assert Roby.app.plan.syskit_engine
            assert_equal Roby.app.plan.syskit_engine, Roby.app.syskit_engine
        end
    end
end


