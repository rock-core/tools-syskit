# frozen_string_literal: true

require "syskit/test/self"
require "syskit/gui/logging_configuration.rb"

module Syskit
    module GUI
        describe LoggingConfiguration do
            attr_reader :subject
            attr_reader :syskit
            attr_reader :client
            attr_reader :conf
            before do
                @conf = Syskit::ShellInterface::LoggingConfiguration.new true, true, {}
                @conf.groups["images"] = Syskit::ShellInterface::LoggingGroup.new "images", true
                @conf.groups["messages"] = Syskit::ShellInterface::LoggingGroup.new "messages", true

                @client = flexmock("client")
                @syskit = flexmock("syskit")
                @syskit.should_receive(:client).and_return { client }
                @syskit.should_receive(:reachable?).and_return { !!client }
                @syskit.should_receive(:async_call).with(["syskit"], :logging_conf, any).and_yield(nil, conf)
                @syskit.should_receive(:async_call_pending?).and_return(false)
                @subject = LoggingConfiguration.new(syskit)
            end

            def expected_items_data
                items_data = []
                items_data << [subject.item_name, "Logging Configuration"]
                items_data << [subject.item_name.conf_logs_item_name, "Enable conf logs"]
                items_data << [subject.item_name.conf_logs_item_value, conf.conf_logs_enabled]
                items_data << [subject.item_name.port_logs_item_name, "Enable port logs"]
                items_data << [subject.item_name.port_logs_item_value, conf.port_logs_enabled]
                items_data << [subject.item_name.groups_item_name, "Enable group"]
                items_data << [subject.item_name.groups_item_value, "#{conf.groups.size} logging group(s)"]
                conf.groups.each_pair do |key, group|
                    items_data << [subject.item_name.groups_item_name.items_name[key], group.name]
                    items_data << [subject.item_name.groups_item_name.items_value[key], group.enabled]
                end
                items_data
            end

            def all_items
                expected_items_data.map { |item| item[0] }
            end

            def item_data(item, expected_type)
                case expected_type.class.to_s
                when "String"
                    item.data(Qt::DisplayRole).toString.to_s
                when "TrueClass", "FalseClass"
                    item.data(Qt::DisplayRole).toBool
                else
                    raise ArgumentError, "Unknown type"
                end
            end

            def item_set_bool(item, value)
                item.setData(Qt::Variant.new(value), Qt::EditRole)
            end

            def item_from_name(name)
                subject.item_name.groups_item_name.items_value[name]
            end

            def assert_view_matches_conf
                expected_items_data.each do |pair|
                    assert_equal item_data(pair[0], pair[1]), pair[1]
                end
            end

            def assert_items_modified(items, modified = true)
                items.each do |item|
                    assert_equal item.modified?, modified
                end
            end

            it "displays current logging configuration" do
                assert_view_matches_conf
            end

            it "is not in a modified state after initialization" do
                assert_items_modified(all_items, false)
            end

            it "updates view when conf is modified" do
                conf.conf_logs_enabled = !conf.conf_logs_enabled
                conf.port_logs_enabled = !conf.port_logs_enabled
                conf.groups.each_value do |group|
                    group.enabled = !group.enabled
                end

                subject.refresh
                assert_view_matches_conf
            end

            it "removes groups from view" do
                conf.groups.delete("images")
                subject.refresh
                assert_view_matches_conf

                conf.groups.delete("messages")
                subject.refresh
                assert_view_matches_conf
            end

            it "adds group to view" do
                conf.groups["events"] = Syskit::ShellInterface::LoggingGroup.new "events", true

                subject.refresh
                assert_view_matches_conf
            end

            it "changes views modified? state" do
                item = subject.item_name.port_logs_item_value
                item_set_bool(item, !conf.port_logs_enabled)

                modified_items = []
                modified_items << subject.item_name.port_logs_item_value
                modified_items << subject.item_name.port_logs_item_name
                modified_items << subject.item_name
                modified_items << subject.item_value

                assert_items_modified(modified_items, true)
                assert_items_modified(all_items - modified_items, false)
                subject.item_value.modified!(false)

                modified_items.clear
                item = item_from_name("images")
                item_set_bool(item, !conf.groups["images"].enabled)

                modified_items << item
                modified_items << subject.item_name.groups_item_name.items_name["images"]
                modified_items << subject.item_name.groups_item_name
                modified_items << subject.item_name.groups_item_value
                modified_items << subject.item_name
                modified_items << subject.item_value

                assert_items_modified(modified_items, true)
                assert_items_modified(all_items - modified_items, false)
            end

            it "discards changes in the view model" do
                item = item_from_name("images")
                item_set_bool(item, !conf.groups["images"].enabled)

                client.should_receive(:call).times(0)
                subject.item_value.modified!(false)

                assert_view_matches_conf
                assert_items_modified(all_items, false)
            end

            it "sends updated conf to the remote side and resets modified?" do
                conf.port_logs_enabled = !conf.port_logs_enabled
                conf.conf_logs_enabled = !conf.conf_logs_enabled
                conf.groups["images"].enabled = !conf.groups["images"].enabled
                conf.groups["messages"].enabled = !conf.groups["messages"].enabled

                item_set_bool(subject.item_name.conf_logs_item_value, conf.conf_logs_enabled)
                item_set_bool(subject.item_name.port_logs_item_value, conf.port_logs_enabled)
                item_set_bool(item_from_name("images"), conf.groups["images"].enabled)
                item_set_bool(item_from_name("messages"), conf.groups["images"].enabled)

                syskit.should_receive(:async_call).with(["syskit"], :update_logging_conf, conf, any).and_yield(nil, nil).times(1)
                subject.item_value.write
                assert_view_matches_conf
                assert_items_modified(all_items, false)
            end

            it "does not update view if it is being edited" do
                new_conf = Marshal.load(Marshal.dump(conf))
                new_conf.port_logs_enabled = !conf.port_logs_enabled
                new_conf.conf_logs_enabled = !conf.conf_logs_enabled
                new_conf.groups["images"].enabled = !conf.groups["images"].enabled
                new_conf.groups["messages"].enabled = !conf.groups["messages"].enabled

                subject.item_name.modified!
                subject.update_model(new_conf)
                assert_view_matches_conf
            end

            it "does not toggle modified? state if value is unchanged" do
                item = item_from_name("messages")
                item_set_bool(item, conf.groups["messages"].enabled)
                assert_equal item.modified?, false
            end

            it "disables/enables views when client is disconnected/connected" do
                client_mock = client
                @client = nil

                subject.refresh
                all_items.each do |item|
                    assert_equal item.isEnabled, false
                end

                @client = client_mock
                subject.refresh
                all_items.each do |item|
                    assert_equal item.isEnabled, true
                end
            end

            it "does not crash if it is initialized with an unreachable syskit" do
                @client = nil
                LoggingConfiguration.new(syskit)
            end
        end
    end
end
