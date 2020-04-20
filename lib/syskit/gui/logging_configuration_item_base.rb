# frozen_string_literal: true

require "vizkit"
require "Qt4"
require "syskit/gui/ruby_item"

module Syskit
    module GUI
        # Base class for most items in the LoggingConfiguration widget with
        # common functionality
        class LoggingConfigurationItemBase < Vizkit::VizkitItem
            attr_reader :current_model
            attr_reader :editing_model
            def initialize(model)
                super()
                @current_model = deep_copy(model)
                @editing_model = deep_copy(model)
            end

            # Creates a marshallable deep copy of the object
            def deep_copy(model)
                Marshal.load(Marshal.dump(model))
            end

            # Adds a ruby primitive type to the tree view
            def add_conf_item(label, accessor = nil)
                item1 = Vizkit::VizkitItem.new(label)
                item2 = RubyItem.new

                unless accessor.nil?
                    item2.getter do
                        @editing_model.method(accessor).call
                    end

                    item2.setter do |value|
                        @editing_model.method("#{accessor}=".to_sym).call value
                    end
                end

                appendRow([item1, item2])
                [item1, item2]
            end

            def data(role = Qt::UserRole + 1)
                if role == Qt::EditRole
                    Qt::Variant.from_ruby self
                else
                    super
                end
            end

            # Updates view's sibling modified? state possibly rejecting changes
            # made to the model
            def modified!(value = true, items = [], update_parent = false)
                super
                reject_changes unless value
                if column == 0
                    i = index.sibling(row, 1)
                    if i.isValid
                        item = i.model.itemFromIndex i
                        item.modified!(value, items)
                    end
                end
            end

            def reject_changes
                @editing_model = deep_copy(@current_model)
            end

            def accept_changes
                @current_model = deep_copy(@editing_model)
            end
        end
    end
end
