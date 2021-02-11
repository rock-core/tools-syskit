# frozen_string_literal: true

require "vizkit"
require "Qt4"
require "syskit/gui/logging_configuration_item_base"

module Syskit
    module GUI
        # A QStandardItem to display a hash of Sysit::ShellInterface::LoggingGroup
        # in a tree view
        class LoggingGroupsItem < LoggingConfigurationItemBase
            attr_reader :items_name, :items_value
            def initialize(logging_groups, label = "")
                super(logging_groups)

                @items_name = {}
                @items_value = {}

                setText label
                update_groups(logging_groups)
            end

            # Updates the model according to a new hash
            def update_groups(groups)
                @current_model.keys.each do |key|
                    unless groups.key? key
                        group_row = @items_name[key].index.row
                        @items_name[key].clear
                        @items_value[key].clear
                        @items_name.delete key
                        @items_value.delete key
                        removeRow(group_row)
                    end
                end

                @current_model = deep_copy(groups)
                @editing_model = deep_copy(groups)

                @current_model.keys.each do |key|
                    unless @items_name.key? key
                        @items_name[key], @items_value[key] = add_conf_item(key)
                        @items_value[key].getter do
                            @editing_model[key].enabled
                        end
                        @items_value[key].setter do |value|
                            @editing_model[key].enabled = value
                        end
                    end
                end
            end
        end
    end
end
