require 'utilrb/qt/variant/from_ruby'
require 'syskit/gui/component_network_view'
module Syskit::GUI
    module ModelViews
        # Visualization of a syskit profile
        class Profile < Qt::Widget
            attr_reader :list
            attr_reader :view

            def make_header_item(text)
                item = Qt::ListWidgetItem.new(text)
                font = item.font
                font.bold = true
                item.font = font
                item.flags = 0
                item
            end

            attr_reader :item_id_to_spec

            def initialize(parent = nil)
                super

                @item_id_to_spec = Array.new
                layout = Qt::VBoxLayout.new(self)
                @list = Qt::ListWidget.new(self)
                layout.add_widget(@list)
                list.connect(SIGNAL('currentItemChanged(QListWidgetItem*,QListWidgetItem*)')) do |current, previous|
                    if current && (spec = item_id_to_spec[list.row(current)])
                        render_network(spec)
                    end
                end
                @view = ComponentNetworkView.new(self)
                layout.add_widget(@view, 1)
            end

            def register_item(item, value)
                item_id_to_spec[list.row(item)] = value
            end

            def render(model)
                list.clear
                item_id_to_spec.clear
                list.add_item(item = make_header_item('Explicit Selection'))
                model.explicit.each do |key, value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{key} => #{value}"))
                    register_item(item, value)
                end
                list.add_item(item = make_header_item('Default Selection'))
                model.defaults.each do |value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{value}"))
                    register_item(item, value)
                end
                list.add_item(item = make_header_item('Definitions'))
                model.definitions.each do |name, value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{name}: #{value}"))
                    value = value.dup
                    value.use(model)
                    register_item(item, value)
                end
            end

            def render_network(spec)
                return if spec.respond_to?(:to_str)
                spec = spec.to_instance_requirements
                view.render(spec)
            end
        end
    end
end

