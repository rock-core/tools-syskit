require 'orocos/roby/gui/orocos_composer_ui'
require 'orocos/roby/gui/instanciate_composition'

module Ui
    class OrocosComposerWidget < Qt::Object
        attr_reader :main
        attr_reader :ui
        attr_reader :system_model
        attr_reader :robot
        attr_reader :composition_models

        attr_reader :composer
        attr_reader :composer_widget
        attr_reader :model_to_item

        def initialize(system_model, robot)
            @system_model = system_model
            @robot        = robot
            super()
            @model_to_item = Hash.new
        end

        def model
            composer.model
        end

        def actual_selection
            composer.actual_selection
        end

        def set(model, selection)
            composer.disable_updates
            ui.compositionModels.current_item = model_to_item[model]
            composer.model = model
            composer.selection.merge!(selection)
            composer.enable_updates
            composer.update
        end

        def state
            model = composer.model
            actual_selection = composer.actual_selection
            code = composer.to_ruby(actual_selection)
            return model, actual_selection, code
        end

        def item_clicked(item, column)
            idx = item.data(column, Qt::UserRole)
            puts "selected #{composition_models[idx]}"
            composer.model = composition_models[idx]
        end

        slots 'item_clicked(QTreeWidgetItem*,int)'

        def exec
            main.exec
        end

        def setupUi(main)
            @main = main

            @ui = Ui::OrocosComposer.new
            @ui.setupUi(main)
            @graph_holder_layout = Qt::VBoxLayout.new(ui.graphHolder)

            composer = @composer = Ui::InstanciateComposition.new(system_model, robot, ui.graphHolder)
            @composer_widget = composer.view
            @graph_holder_layout.add_widget(@composer_widget)

            @ui.use_main_selection.checked = composer.engine.use_main_selection?
            @ui.use_main_selection.connect(SIGNAL('toggled(bool)')) do |value|
                composer.engine.use_main_selection = value
                composer.update
            end

            Qt::Object.connect(ui.compositionModels, SIGNAL('itemClicked(QTreeWidgetItem*,int)'),
                              self, SLOT('item_clicked(QTreeWidgetItem*,int)'))
            composer.connect(SIGNAL('updated()')) do
                begin
                    text = composer.to_ruby
                    ui.codeDisplay.text = text
                    ui.btnDone.enabled = true
                rescue Exception => e
                    ui.codeDisplay.text = e.message
                    ui.btnDone.enabled = false
                end
            end
            
            @composition_models = []
            system_model.each_composition do |model|
                next if model.is_specialization?
                composition_models << model
                item = Qt::TreeWidgetItem.new(ui.compositionModels, [model.short_name])
                model_to_item[model] = item
                item.setData(0, Qt::UserRole, Qt::Variant.new(composition_models.size - 1))
            end

            ui.btnCancel.connect(SIGNAL('clicked()')) do
                main.reject
            end
            ui.btnDone.connect(SIGNAL('clicked()')) do
                main.accept
            end

            settings = Qt::Settings.new('Orocos', 'SystemBuilder')
            main.restore_geometry(settings.value('composer/geometry').to_byte_array)
            ui.hsplitter.restore_state(
                settings.value('composer/hsplitter/state').to_byte_array)
            ui.vsplitter.restore_state(
                settings.value('composer/vsplitter/state').to_byte_array)

            class << main; attr_accessor :ui end
            main.ui = ui
            def main.closeEvent(event)
                settings = Qt::Settings.new('Orocos', 'SystemBuilder')
                settings.setValue("composer/geometry",
                                  Qt::Variant.new(save_geometry))
                settings.setValue("composer/vsplitter/state",
                                  Qt::Variant.new(ui.vsplitter.save_state))
                settings.setValue("composer/hsplitter/state",
                                  Qt::Variant.new(ui.hsplitter.save_state))
                super
            end
        end
    end
end
