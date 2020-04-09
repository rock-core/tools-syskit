# frozen_string_literal: true

require "vizkit"
require "vizkit/vizkit_items"
require "vizkit/tree_view"
require "Qt4"
require "syskit/shell_interface"
require "syskit/gui/logging_configuration_item"
require "roby/interface/exceptions"

module Syskit
    module GUI
        # A widget containing an editable TreeView to allow the user to
        # manage basic Syskit's logging configuration
        class LoggingConfiguration < Qt::Widget
            attr_reader :model, :tree_view, :syskit, :item_name, :item_value, :pending_call
            def initialize(syskit, parent = nil)
                super(parent)
                main_layout = Qt::VBoxLayout.new(self)
                @tree_view = Qt::TreeView.new

                Vizkit.setup_tree_view tree_view
                @model = Vizkit::VizkitItemModel.new
                tree_view.setModel @model
                main_layout.add_widget(tree_view)
                tree_view.setColumnWidth(0, 200)
                tree_view.style_sheet = <<~STYLESHEET
                    QTreeView {
                        background-color: rgb(255, 255, 219);
                        alternate-background-color: rgb(255, 255, 174);
                        color: rgb(0, 0, 0);
                    }
                    QTreeView:disabled { color: rgb(159, 158, 158); }
                STYLESHEET

                @syskit = syskit
                @timer = Qt::Timer.new
                @timer.connect(SIGNAL("timeout()")) { refresh }
                @timer.start 1500

                refresh
            end

            # Whether there is a refreshing call pending
            def refreshing?
                syskit.async_call_pending?(pending_call)
            end

            # Fetches the current logging configuration from syskit's
            # sync interface
            def refresh
                if syskit.reachable?
                    begin
                        return if refreshing?

                        @pending_call = syskit.async_call ["syskit"], :logging_conf do |error, result|
                            if error.nil?
                                enabled true
                                update_model(result)
                            else
                                enabled false
                            end
                        end
                    rescue Roby::Interface::ComError
                        enabled false
                    end
                else
                    enabled false
                end
            end

            # Expands the entire tree
            def recursive_expand(item)
                tree_view.expand(item.index)
                (0...item.rowCount).each do |i|
                    recursive_expand(item.child(i))
                end
            end

            # Changes the top most item in the tree state
            # and makes it update its childs accordingly
            def enabled(toggle)
                @item_name&.enabled toggle
            end

            # Updates the view model
            def update_model(conf)
                if @item_name.nil?
                    @item_name = LoggingConfigurationItem.new(conf, :accept => true)
                    @item_value = LoggingConfigurationItem.new(conf)
                    @item_value.setEditable true
                    @item_value.setText ""
                    @model.appendRow([@item_name, @item_value])
                    recursive_expand(@item_name)

                    @item_name.on_accept_changes do |new_conf|
                        begin
                            syskit.async_call ["syskit"], :update_logging_conf, new_conf do |error, result|
                                enabled false unless error.nil?
                            end
                        rescue Roby::Interface::ComError
                            enabled false
                        end
                    end
                else
                    return if @item_name.modified?

                    @item_name.update_conf(conf)
                end
            end
        end
    end
end
