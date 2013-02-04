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
                @btn_compute_system_network = Qt::CheckBox.new("Compute System Network")
                layout.add_widget(@btn_compute_system_network)
                @list = Qt::ListWidget.new(self)
                list.size_policy = Qt::SizePolicy.new(Qt::SizePolicy::Preferred, Qt::SizePolicy::Maximum)
                layout.add_widget(@list, 1)
                list.connect(SIGNAL('currentItemChanged(QListWidgetItem*,QListWidgetItem*)')) do |current, previous|
                    if current && (spec = item_id_to_spec[list.row(current)])
                        render_network(spec)
                    end
                end
                @view = ComponentNetworkView.new(self)
                view.size_policy = Qt::SizePolicy.new(Qt::SizePolicy::Preferred, Qt::SizePolicy::Ignored)
                layout.add_widget(@view, 3)
            end

            def register_item(item, value)
                item_id_to_spec[list.row(item)] = value
            end

            def render(model)
                list.clear
                item_id_to_spec.clear
                list.add_item(item = make_header_item('Explicit Selection'))
                model.dependency_injection.explicit.each do |key, value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{key} => #{value}"))
                    register_item(item, value)
                end
                list.add_item(item = make_header_item('Default Selection'))
                model.dependency_injection.defaults.each do |value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{value}"))
                    register_item(item, value)
                end
                list.add_item(item = make_header_item('Definitions'))
                model.definitions.each do |name, value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{name}: #{value}"))
                    value = model.resolved_definition(name)
                    register_item(item, value)
                end
                list.add_item(item = make_header_item('Devices'))
                model.robot.each_device do |value|
                    list.add_item(item = Qt::ListWidgetItem.new("#{value.name}: #{value}"))
                    register_item(item, value)
                end
            end

            def instanciation_method
                if @btn_compute_system_network.checked?
                    :compute_system_network
                else :instanciate_model
                end
            end

            def render_network(spec)
                return if spec.respond_to?(:to_str)
                spec = spec.to_instance_requirements
                view.render(spec, :method => instanciation_method)
                emit updated
            rescue ::Exception => e
                Roby.app.register_exception(e)
                emit updated
            end

            signals :updated
        end
    end
end

