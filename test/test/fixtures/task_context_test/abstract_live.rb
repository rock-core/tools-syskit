# frozen_string_literal: true

task_m = Syskit::TaskContext.new_submodel(name: "some::Task") do
    abstract
end

describe task_m do
    run_live

    it "calls the tests even though the task is abstract" do
        puts "TEST: CALLED"
    end
end
