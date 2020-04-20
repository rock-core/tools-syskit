# frozen_string_literal: true

task_m = Syskit::TaskContext.new_submodel(name: "some::Task") do
    abstract
end

Syskit.extend_model task_m do
    def configure
        super
        puts "TEST: CONFIGURE CALLED"
    end
end

describe task_m do
    it "deploys a stubbed model in simulation mode" do
        syskit_deploy_and_configure task_m
    end
end
