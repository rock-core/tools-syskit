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

        def select(item)
            if !instances.include?(item)
                instances << item
                defines.delete(item)
            end
        end

        def deselect(item)
            if !defines.include?(item)
                defines << item
                instances.delete(item)
            end
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
                    base, selection = composer.state
                    refresh(item, base, selection)
                    update
                end
            end
            ui.lstInstances.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, column|
                if item.check_state(0) == Qt::Checked
                    select(item)
                else
                    deselect(item)
                end
                update
            end

            ui.btnAdd.connect(SIGNAL('clicked()')) do
                composer = setup_composer
                if composer.exec == Qt::Dialog::Accepted
                    base, selection = composer.state
                    add(base, selection)
                    update
                end
            end

            ui.lstInstances.connect(SIGNAL('itemSelectionChanged()')) do
                ui.btnDelete.enabled = !ui.lstInstances.selected_items.empty?
            end
            instance_list = ui.lstInstances
            def instance_list.contextMenuEvent(event)
                if current_selection = selected_items.first
                    menu = Qt::Menu.new
                    if current_selection.name
                        menu.add_action "Remove name"
                        menu.add_action "Change name"
                    else
                        menu.add_action "Set name"
                    end

                    if action = menu.exec(event.global_pos)
                        if action.text == "Remove name"
                            current_selection.name = nil
                            current_selection.update_text
                        else
                            new_name = current_selection.name || ""
                            valid = false
                            while !valid
                                new_name = Qt::InputDialog.getText(self,
                                        "Orocos System Builder",
                                        "Definition name",
                                        Qt::LineEdit::Normal,
                                        new_name || "")
                                break if !new_name

                                valid = true
                                if new_name !~ /^\w+$/
                                    Qt::MessageBox.warning(self, "Orocos System Builder", "invalid name '#{new_name}': names must be non-empty and contain only alphanumeric characters and _ (underscore)")
                                    valid = false
                                else
                                    valid = top_level_item_count.enum_for(:times).all? do |idx|
                                        item = top_level_item(idx)
                                        if item != current_selection && item.name == new_name
                                            Qt::MessageBox.warning(self, "Orocos System Builder", "the name '#{new_name}' is already in use")
                                            false
                                        else
                                            true
                                        end
                                    end
                                end
                            end

                            if new_name
                                current_selection.name = new_name
                                current_selection.update_text
                            end
                        end
                    end
                end
                super
            end

            ui.btnDelete.connect(SIGNAL('clicked()')) do
                if current_selection = ui.lstInstances.selected_items.first
                    remove(current_selection)
                end
            end
            ui.btnSave.connect(SIGNAL('clicked()')) do
                if filename = Qt::FileDialog.get_save_file_name
                    save(filename)
                end
            end
            ui.btnSaveSVG.connect(SIGNAL('clicked()')) do
                if filename = Qt::FileDialog.get_save_file_name
                    plan_display.save_svg(filename)
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

        def append(filename)
            engine.load_composite_file(filename)

            items = Hash.new
            engine.defines.each_value do |instance|
                item = add(instance.base_models.to_a.first, instance.using_spec)
                item.set_check_state(0, Qt::Unchecked)
                item.name = instance.name
                item.update_text
                items[item.name] = item
                deselect(item)
            end

            engine.instances.each do |instance|
                if item = items[instance.name]
                    item.set_check_state(0, Qt::Checked)
                    select(item)
                elsif composition = instance.base_models.find { |model| model <= Orocos::RobyPlugin::Compositon }
                    item = add(composition, instance.using_spec)
                    item.name = instance.name
                    items[item.name] = item
                    item.update_text
                end
            end
            update
        end

        def load(filename)
            engine.clear
            plan.clear
            ui.lstInstances.clear

            append(filename)
        end

        def save(filename)
            code = []
            ui.lstInstances.top_level_item_count.times do |idx|
                it = ui.lstInstances.top_level_item(idx)
                if it.name
                    code << InstanciateComposition.to_ruby_define(
                        it.base_model, it.selection, it.name)
                    if it.check_state(0) == Qt::Checked
                        code << "add('#{it.name}')"
                    end
                elsif it.check_state(0) == Qt::Checked
                    code << InstanciateComposition.to_ruby(
                        it.base_model, it.selection, it.name)
                end
            end

            File.open(filename, 'w') do |io|
                io.write code.join("\n")
            end
        end

        def refresh(item, base_model, selection)
            item.base_model = base_model
            item.selection  = selection
            item.set_text(0, InstanciateComposition.to_ruby(
                     base_model, selection, item.name))
            ui.lstInstances.update
        end

        def add(base_model, selection)
            code = InstanciateComposition.to_ruby(base_model, selection, nil)
            item = Qt::TreeWidgetItem.new(ui.lstInstances, [code])
            class << item
                attr_accessor :name
                attr_accessor :base_model
                attr_accessor :selection

                def update_text
                    self.set_text(0, InstanciateComposition.to_ruby(
                        base_model, selection, name))
                end
            end
            item.base_model = base_model
            item.selection  = selection
            item.set_check_state(0, Qt::Checked)
            instances << item

            item
        end

        def remove(item)
            instances.delete(item)
            defines.delete(item)

            idx = ui.lstInstances.index_of_top_level_item(item)
            ui.lstInstances.take_top_level_item(idx)
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

