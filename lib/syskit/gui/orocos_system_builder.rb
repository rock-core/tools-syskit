require 'orocos/roby/gui/orocos_composer'
require 'orocos/roby/gui/orocos_system_builder_ui'
require 'orocos/roby/gui/instanciate_composition'
require 'orocos/roby/gui/plan_display'

module Ui
    class OrocosSystemBuilderWidget < Qt::Object
        attr_reader :system_model
        attr_reader :engine
        attr_reader :plan
        attr_reader :plan_display
        attr_reader :plan_display_widget

        def initialize(system_model)
            super()
            @instances = Array.new

            @system_model = system_model
            @plan   = Roby::Plan.new
            @engine = Orocos::RobyPlugin::Engine.new(plan, system_model)
        end

        attr_reader :composer
        attr_reader :instances
        attr_reader :ui

        def setup_composer
            if !@composer_dialog
                dialog   = Qt::Dialog.new
                dialog.set_attribute(Qt::WA_DeleteOnClose, false)
                composer = Ui::OrocosComposerWidget.new(system_model)
                composer.setupUi(dialog)
                @composer_dialog = composer
            end
            @composer_dialog
        end

        def setupUi(main)
            @ui = Ui::OrocosSystemBuilder.new
            @ui.setupUi(main)

            @graph_holder_layout = Qt::VBoxLayout.new(ui.graphHolder)
            @plan_display = Ui::PlanDisplay.new(system_model)
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

            ui.btnAdd.connect(SIGNAL('clicked()')) do
                composer = setup_composer
                if composer.exec == Qt::Dialog::Accepted
                    base, selection, code = composer.state
                    add(base, selection, code)
                end
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
            instances << item

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
                engine.compute_system_network
                plan_display.update_view(plan, engine)
            rescue Exception => e
                plan_display.display_error("Failed to deploy the required system network", e)
            end
        end
    end
end

