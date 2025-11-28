# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe Async do
            def assert_future_fulfilled(future)
                result = future.value
                unless future.fulfilled?
                    raise future.reason
                end

                result
            end

            describe "#valid?" do
                it "returns true if the current set of requirements match the set stored in the current resolution" do
                    requirements = Set[flexmock]
                    async = Async.new(plan, requirements)
                    assert async.valid?(requirements)
                end

                it "returns false if the current set of requirements does not match the set stored in the current resolution" do
                    requirements = Set[flexmock]
                    async = Async.new(plan, requirements)
                    refute async.valid?(Set.new)
                end
            end
        end
    end
end
