# frozen_string_literal: true

require "vizkit"
require "Qt4"
require "vizkit/vizkit_items"

module Syskit
    module GUI
        # A QStandardItem to display and edit primitive ruby types in a tree view
        class RubyItem < Vizkit::VizkitAccessorItem
            def initialize
                super(nil, :nil?)
                setEditable false
            end

            def setData(data, role = Qt::UserRole + 1)
                return super if role != Qt::EditRole || data.isNull

                val = from_variant data, @getter.call
                return false if val.nil?
                return false unless val != @getter.call

                @setter.call val
                modified!
            end

            # Defines a block to be called to update the model when the item is edited
            def setter(&block)
                @setter = block
                setEditable true
            end

            # Defines a block to be called to fetch data from the model
            def getter(&block)
                @getter = block
            end
        end
    end
end
