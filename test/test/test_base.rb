# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Test
        class << self
            attr_accessor :update_and_restore_attr_target_attribute

            attr_writer :update_and_restore_attr_target_predicate

            def update_and_restore_attr_target_predicate?
                @update_and_restore_attr_target_predicate
            end
        end
        @update_and_restore_attr_target_attribute = 0
        @update_and_restore_attr_target_predicate = false

        describe Base do
            include Base

            describe "update_and_restore_attr" do
                describe "the update part" do
                    before do
                        update_and_restore_attr(
                            Syskit::Test, :update_and_restore_attr_target_attribute, 42
                        )
                        update_and_restore_attr(
                            Syskit::Test, :update_and_restore_attr_target_predicate?, true
                        )
                    end

                    it "updates a plain attribute" do
                        assert_equal(
                            42, Syskit::Test.update_and_restore_attr_target_attribute
                        )
                    end

                    it "updates a predicate attribute" do
                        assert Syskit::Test.update_and_restore_attr_target_predicate?
                    end
                end

                it "restores the attribute after the test finishes " do
                    assert_equal 0, Syskit::Test.update_and_restore_attr_target_attribute
                end

                it "restores the attribute after it has been " do
                    refute Syskit::Test.update_and_restore_attr_target_predicate?
                end
            end
        end
    end
end
