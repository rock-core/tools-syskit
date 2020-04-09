# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe Property do
        attr_reader :property
        before do
            task_m = Syskit::TaskContext.new_submodel do
                property "test", "/double"
            end
            @property = task_m.new.property("test")
        end

        describe "#update_remote_value" do
            it "isolates the remote value so that one cannot modify it after having set it" do
                dbl_t = property.type
                dbl = Typelib.from_ruby(0.1, dbl_t)
                property.update_remote_value(dbl)
                Typelib.copy(dbl, Typelib.from_ruby(0.2, dbl_t))
                property.write(0.2)
                assert property.needs_commit?
            end
        end

        describe "#needs_commit?" do
            it "returns false if the task has no value and no remote value" do
                refute property.needs_commit?
            end
            it "returns false if the task has no value" do
                property.update_remote_value(0.1)
                refute property.needs_commit?
            end
            it "returns true if the task has a value and no remote value" do
                property.write(0.1)
                assert property.needs_commit?
            end
            it "returns true if the task value and remote value do not match" do
                property.write(0.1)
                property.update_remote_value(0.2)
                assert property.needs_commit?
            end
            it "returns false if the task value and remote value do match" do
                property.write(0.1)
                property.update_remote_value(0.1)
                refute property.needs_commit?
            end
        end
    end
end
