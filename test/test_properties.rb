# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe Properties do
        attr_reader :task, :property, :properties
        before do
            @property = flexmock(:on, Property)
            @task = flexmock(:on, TaskContext)
            @properties = Properties.new(task, "prop" => @property)
        end

        describe "#each" do
            it "enumerates the property objects" do
                recorder = flexmock { |m| m.should_receive(:call).with(property).once }
                properties.each { |p| recorder.call(p) }
                assert_equal [property], properties.each.to_a
            end
        end
        describe "#include?" do
            it "returns true for an existing property" do
                assert properties.include?("prop")
            end
            it "returns false for a non-existent property" do
                refute properties.include?("does_not_exist")
            end
        end

        describe "#[]" do
            it "returns an existing property object" do
                assert_equal property, properties["prop"]
            end
            it "returns nil for a non-existent property object" do
                assert_nil properties["does_not_exist"]
            end
        end

        describe "#method_missing" do
            it "returns the value of an existent property" do
                property.should_receive(:read).once.and_return(value = flexmock)
                assert_equal value, properties.prop
            end
            it "sets the value of an existent property" do
                property.should_receive(:write).once.with(value = flexmock)
                assert_equal value, (properties.prop = value)
            end
            it "raises if trying to get the value of a non-existing property" do
                exception = assert_raises(Orocos::NotFound) { properties.does_not_exist }
                assert_equal "does_not_exist is not a property of #{task}", exception.message
            end
            it "raises if trying to set the value of a non-existing property" do
                exception = assert_raises(Orocos::NotFound) { properties.does_not_exist = 10 }
                assert_equal "does_not_exist is not a property of #{task}", exception.message
            end
            it "returns the raw value of an existent property" do
                property.should_receive(:raw_read).once.and_return(value = flexmock)
                assert_equal value, properties.raw_prop
            end
            it "sets the raw value of an existent property" do
                property.should_receive(:raw_write).once.with(value = flexmock)
                assert_equal value, (properties.raw_prop = value)
            end
            it "raises if trying to get the raw value of a non-existing property" do
                exception = assert_raises(Orocos::NotFound) { properties.raw_does_not_exist }
                assert_equal "neither does_not_exist nor raw_does_not_exist are a property of #{task}", exception.message
            end
            it "raises if trying to set the raw value of a non-existing property" do
                exception = assert_raises(Orocos::NotFound) { properties.raw_does_not_exist = 10 }
                assert_equal "neither does_not_exist nor raw_does_not_exist are a property of #{task}", exception.message
            end
            it "gets the non-raw value of a property whose name starts with raw_" do
                properties = Properties.new(task, "raw_prop" => @property)
                property.should_receive(:read).once.and_return(value = flexmock)
                properties.raw_prop
            end
            it "gets raw value of a property whose name starts with raw_" do
                properties = Properties.new(task, "raw_prop" => @property)
                property.should_receive(:raw_read).once.and_return(value = flexmock)
                assert_equal value, properties.raw_raw_prop
            end
            it "sets a property whose name starts with raw_" do
                properties = Properties.new(task, "raw_prop" => @property)
                property.should_receive(:raw_write).once.with(value = flexmock)
                assert_equal value, (properties.raw_raw_prop = value)
            end

            it "can read and update a property using a block form" do
                property.should_receive(:read).once.and_return(read_value = flexmock)
                property.should_receive(:write).once.with(write_value = flexmock)
                recorder = flexmock { |m| m.should_receive(:called).with(read_value).and_return(write_value) }
                properties.prop do |v|
                    recorder.called(v)
                end
            end

            it "can raw_read and update a property using a block form" do
                property.should_receive(:raw_read).once.and_return(read_value = flexmock)
                property.should_receive(:raw_write).once.with(write_value = flexmock)
                recorder = flexmock { |m| m.should_receive(:called).with(read_value).and_return(write_value) }
                properties.raw_prop do |v|
                    recorder.called(v)
                end
            end
        end
    end
end
