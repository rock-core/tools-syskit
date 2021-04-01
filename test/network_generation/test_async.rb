# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe Async do
            subject { Async.new(plan) }

            def assert_future_fulfilled(future)
                result = future.value
                unless future.fulfilled?
                    raise future.reason
                end

                result
            end

            describe "#prepare" do
                it "computes the system network in a separate plan" do
                    requirements = Set[flexmock]
                    resolution = subject.prepare(requirements)
                    flexmock(resolution.engine).should_receive(:resolve_system_network)
                                               .with(requirements, any)
                                               .once.and_return(ret = flexmock)
                    resolution.execute
                    assert_equal ret, subject.join
                end
            end

            describe "#valid?" do
                it "returns true if the current set of requirements match the set stored in the current resolution" do
                    requirements = Set[flexmock]
                    flexmock(Engine).new_instances.should_receive(:resolve_system_network)
                    subject.start(requirements)
                    assert subject.valid?(requirements)
                end

                it "returns false if the current set of requirements does not match the set stored in the current resolution" do
                    requirements = Set[flexmock]
                    flexmock(Engine).new_instances.should_receive(:resolve_system_network)
                    subject.start(requirements)
                    assert !subject.valid?(Set.new)
                end
            end

            describe "#cancel" do
                it "discards the transaction once the future finishes" do
                    latch = Concurrent::IVar.new
                    flexmock(Engine).new_instances.should_receive(:resolve_system_network)
                                    .and_return { latch.value }
                    future = subject.start(Set[flexmock])
                    work_plan = future.engine.work_plan
                    flexmock(work_plan).should_receive(:discard_transaction).once
                                       .pass_thru
                    subject.cancel
                    latch.set true
                    future.value
                    subject.apply

                    assert work_plan.finalized?
                end
            end

            describe "#apply" do
                it "applies the computed network on the plan" do
                    requirements = Set[flexmock]
                    resolution = subject.prepare(requirements)
                    engine = flexmock(resolution.engine, :strict)
                    engine.should_receive(:resolve_system_network)
                          .with(requirements, any).once.and_return(ret = flexmock)

                    if RUBY_VERSION >= "2.7"
                        engine.should_receive(:apply_system_network_to_plan).with(ret).once
                    else
                        engine.should_receive(:apply_system_network_to_plan).with(ret, {}).once
                    end
                    resolution.execute
                    subject.join
                    assert subject.finished?
                    subject.apply
                end

                it "carries forward options passed to prepare "\
                   "that are relevant to the apply step" do
                    requirements = Set[flexmock]
                    resolution = subject.prepare(
                        requirements, compute_deployments: false
                    )
                    engine = flexmock(resolution.engine, :strict)
                    engine.should_receive(:resolve_system_network)
                          .with(requirements, any).once.and_return(ret = flexmock)
                    engine.should_receive(:apply_system_network_to_plan)
                          .with(ret, compute_deployments: false).once
                    resolution.execute
                    subject.join
                    assert subject.finished?
                    subject.apply
                end

                it "discards the transcation if applying the plan fails" do
                    error_t = Class.new(RuntimeError)
                    requirements = Set[flexmock]
                    resolution = subject.prepare(requirements)
                    engine = flexmock(resolution.engine, :strict)
                    engine.should_receive(:resolve_system_network).and_return(ret = flexmock)
                    engine.should_receive(:apply_system_network_to_plan).and_raise(error_t)
                    flexmock(engine.work_plan).should_receive(:discard_transaction).once
                    resolution.execute
                    subject.join
                    assert_raises(error_t) { subject.apply }
                end

                it "passes any exception raised inside the future and discards the transaction" do
                    error_t = Class.new(RuntimeError)
                    requirements = Set[flexmock]
                    resolution = subject.prepare(requirements)
                    engine = flexmock(resolution.engine, :strict)
                    engine.should_receive(:resolve_system_network).and_raise(error_t)
                    engine.should_receive(:apply_system_network_to_plan).never
                    flexmock(engine.work_plan).should_receive(:discard_transaction).once.pass_thru
                    resolution.execute
                    assert_raises(error_t) { subject.join }
                    assert subject.finished?
                    assert_raises(error_t) { subject.apply }
                end
            end
        end
    end
end
