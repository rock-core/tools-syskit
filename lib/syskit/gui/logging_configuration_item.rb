# frozen_string_literal: true

require "vizkit"
require "Qt4"
require "syskit/gui/logging_configuration_item_base"
require "syskit/gui/logging_groups_item"

module Syskit
    module GUI
        # A QStandardItem that displays a Sysit::ShellInterface::LoggingConfiguration
        # in a tree view
        class LoggingConfigurationItem < LoggingConfigurationItemBase
            attr_reader :options
            attr_reader :conf_logs_item_name
            attr_reader :conf_logs_item_value
            attr_reader :port_logs_item_name
            attr_reader :port_logs_item_value
            attr_reader :groups_item_name
            attr_reader :groups_item_value
            def initialize(logging_configuration, options = {})
                super(logging_configuration)
                @options = options
                setText "Logging Configuration"

                @conf_logs_item_name, @conf_logs_item_value = add_conf_item("Enable conf logs",
                                                                            :conf_logs_enabled)
                @port_logs_item_name, @port_logs_item_value = add_conf_item("Enable port logs",
                                                                            :port_logs_enabled)

                @groups_item_name = LoggingGroupsItem.new(@current_model.groups, "Enable group")
                @groups_item_value = Vizkit::VizkitItem.new("#{@current_model.groups.size} logging group(s)")
                appendRow([@groups_item_name, @groups_item_value])
            end

            # Called when the user commit changes made to the model
            def write
                if column == 1
                    i = index.sibling(row, 0)
                    return unless i.isValid

                    item = i.model.itemFromIndex i
                    item.accept_changes
                end
                modified!(false)
            end

            # Notify child to also accept user changes,
            # updates internal copy of the logging configuration, and calls
            # a block that should the data to the remote side
            def accept_changes
                super
                @groups_item_name.accept_changes
                @current_model.groups = @groups_item_name.current_model
                @commit_block.call current_model
            end

            # Updates the model with a new logging configuration
            def update_conf(new_model)
                @current_model = deep_copy(new_model)
                @editing_model = deep_copy(new_model)
                @groups_item_name.update_groups(@current_model.groups)
                @groups_item_value.setText "#{@current_model.groups.size} logging group(s)"
                model.layoutChanged
            end

            # Sets the block to be called when the user accepts the changes
            # made to the model
            def on_accept_changes(&block)
                @commit_block = block
            end
        end
    end
end
