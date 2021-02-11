# frozen_string_literal: true

require "syskit/test/self"
require "vizkit"
require "syskit/gui/testing"
require "syskit/gui/state_label"

module Syskit
    module GUI
        describe Testing do
            before do
                @app = flexmock(discover_test_files: [], argv_set: [])
                @testing = Testing.new(app: app)
            end

            describe "#discover_exceptions_from_failure" do
                it "resolves an Minitest::UnexpectedError's original error" do
                    original_error = ArgumentError.new
                    unexpected_error = Minitest::UnexpectedError.new(original_error)

                    assert_equal(
                        [original_error],
                        @testing.discover_exceptions_from_failure(unexpected_error)
                    )
                end
            end
        end
    end
end
