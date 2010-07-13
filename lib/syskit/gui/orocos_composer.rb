require 'orocos/roby/gui/orocos_composer_ui'
require 'orocos/roby/gui/instanciate_composition'

module Ui
    class OrocosComposerWidget < Qt::Object
        attr_reader :main
        attr_reader :ui
        attr_reader :system_model
        attr_reader :composition_models

        attr_reader :composer
        attr_reader :composer_widget

        def initialize(system_model)
            @system_model = system_model
            super()
        end

        def item_clicked(item, column)
            idx = item.data(column, Qt::UserRole)
            puts "selected #{composition_models[idx]}"
            composer.model = composition_models[idx]
        end

        def compositionInstanciationUpdated
            text = composer.to_ruby
            ui.codeDisplay.text = text
        rescue Exception => e
            ui.codeDisplay.text = e.message
        end

        slots 'item_clicked(QTreeWidgetItem*,int)', 'compositionInstanciationUpdated()'

        def setupUi(main)
            @main = main
            @ui = Ui::OrocosComposer.new
            @ui.setupUi(main)

            layout = Qt::VBoxLayout.new(ui.graphHolder)
            @composer = Ui::InstanciateComposition.new(ui.graphHolder)
            @composer_widget = composer.view
            layout.add_widget(@composer_widget)

            Qt::Object.connect(ui.compositionModels, SIGNAL('itemClicked(QTreeWidgetItem*,int)'),
                              self, SLOT('item_clicked(QTreeWidgetItem*,int)'))
            Qt::Object.connect(composer, SIGNAL('updated()'),
                              self, SLOT('compositionInstanciationUpdated()'))
            
            @composition_models = []
            system_model.each_composition do |model|
                next if model.is_specialization?
                composition_models << model
                item = Qt::TreeWidgetItem.new(ui.compositionModels, [model.short_name])
                item.setData(0, Qt::UserRole, Qt::Variant.new(composition_models.size - 1))
            end
        end
    end
end
