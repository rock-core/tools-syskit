require 'orocos/roby/gui/orocos_composer'
require 'orocos/roby/gui/orocos_system_builder_ui'
require 'orocos/roby/gui/instanciate_composition'
require 'orocos/roby/gui/plan_display'

module Ui
    class OrocosSystemBuilderWidget < Qt::Object
        attr_reader :system_model
        attr_reader :robot
        attr_reader :engine
        attr_reader :plan
        attr_reader :plan_display
        attr_reader :plan_display_widget

        def initialize(system_model, robot)
            super()
            @instances = Array.new
            @defines   = Array.new

            @system_model = system_model
            @robot        = robot
            robot.devices.each do |name, d|
                puts "device: #{name} #{d}"
            end
            @plan   = Roby::Plan.new
            @engine = Orocos::RobyPlugin::Engine.new(plan, system_model, robot)

        end

        attr_reader :composer
        attr_reader :instances
        attr_reader :defines
        attr_reader :ui

        def setup_composer
            if !@composer_dialog
                dialog   = Qt::Dialog.new
                dialog.set_attribute(Qt::WA_DeleteOnClose, false)
                composer = Ui::OrocosComposerWidget.new(system_model, robot)
                composer.setupUi(dialog)
                @composer_dialog = composer
            end
            @composer_dialog
        end

        def setupUi(main)
            system_builder = self
            ui = @ui = Ui::OrocosSystemBuilder.new
            @ui.setupUi(main)

            @graph_holder_layout = Qt::VBoxLayout.new(ui.graphHolder)
            @plan_display = Ui::PlanDisplay.new
            @plan_display_widget = plan_display.view
            @graph_holder_layout.add_widget plan_display_widget

            ui.lstInstances.connect(SIGNAL('itemDoubleClicked(QTreeWidgetItem*,int)')) do |item, column|
                composer = setup_composer
                composer.set(item.base_model, item.selection)
                if composer.exec == Qt::Dialog::Accepted
                    base, selection, code = composer.state
                    refresh(item, base, selection, code)
                end
            end
            ui.lstInstances.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, column|
                if item.check_state(0) == Qt::Checked
                    if !instances.include?(item)
                        instances << item
                        defines.delete(item)
                        update
                    end
                else
                    if !defines.include?(item)
                        defines << item
                        instances.delete(item)
                        update
                    end
                end
            end

            ui.btnAdd.connect(SIGNAL('clicked()')) do
                composer = setup_composer
                if composer.exec == Qt::Dialog::Accepted
                    base, selection, code = composer.state
                    add(base, selection, code)
                end
            end

            ui.lstInstances.connect(SIGNAL('itemSelectionChanged()')) do
                ui.btnDelete.enabled = !ui.lstInstances.selected_items.empty?
            end
            ui.btnDelete.connect(SIGNAL('clicked()')) do
                if current_selection = ui.lstInstances.selected_items.first
                    remove(current_selection)
                end
            end

            settings = Qt::Settings.new('Orocos', 'SystemBuilder')
            main.restore_geometry(
                settings.value('orocosSystemBuilder/geometry').to_byte_array)
            ui.splitter.restore_state(
                settings.value('orocosSystemBuilder/splitter_state').to_byte_array)

            class << main; attr_accessor :ui end
            main.ui = ui
            def main.closeEvent(event)
                settings = Qt::Settings.new('Orocos', 'SystemBuilder')
                settings.setValue("orocosSystemBuilder/geometry",
                                  Qt::Variant.new(save_geometry))
                settings.setValue("orocosSystemBuilder/splitter_state",
                                  Qt::Variant.new(ui.splitter.save_state))
                super
            end
        end

        def refresh(item, base_model, selection, code)
            item.set_text(0, code)
            item.base_model = base_model
            item.selection  = selection
            ui.lstInstances.update
            update
        end

        def add(base_model, selection, code)
            item = Qt::TreeWidgetItem.new(ui.lstInstances, [code])
            class << item
                attr_accessor :base_model
                attr_accessor :selection
            end
            item.base_model = base_model
            item.selection  = selection
            item.set_check_state(0, Qt::Checked)
            instances << item

            update
        end

        def remove(item)
            instances.delete(item)
            defines.delete(item)

            idx = ui.lstInstances.index_of_top_level_item(item)
            ui.lstInstances.take_top_level_item(idx)
            update
        end

        def update
            plan.clear
            engine.clear
            instances.each do |item|
                engine.add(item.base_model).
                    use(item.selection)
            end

            begin
                engine.prepare
                engine.compute_system_network
                plan.static_garbage_collect
                plan_display.update_view(plan, engine)
            rescue Exception => e
                plan_display.display_error("Failed to deploy the required system network", e)
            end
        end
    end
end

