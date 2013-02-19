require 'syskit/gui/page'
require 'syskit/gui/component_network_view'
require 'metaruby/gui/exception_view'

module Syskit
    module GUI
        class Instanciate < Qt::Widget
            attr_reader :apply_btn
            attr_reader :instance_txt

            attr_reader :display
            attr_reader :page
            attr_reader :rendering

            attr_reader :exception_view

            attr_reader :permanent

            def plan
                rendering.plan
            end

            def initialize(parent = nil, arguments = "", permanent = [])
                super(parent)

                main_layout = Qt::VBoxLayout.new(self)
                toolbar_layout = create_toolbar
                main_layout.add_layout(toolbar_layout)

                splitter = Qt::Splitter.new(self)
                main_layout.add_widget(splitter)

                # Add the main view
                @display = Qt::WebView.new
                @page = Syskit::GUI::Page.new(@display)
                main_layout.add_widget(@display)
                @rendering = Syskit::GUI::ComponentNetworkView.new(@page)
                rendering.enable

                # Add the exception view
                @exception_view = MetaRuby::GUI::ExceptionView.new

                splitter.orientation = Qt::Vertical
                splitter.add_widget display
                splitter.add_widget exception_view

                @apply_btn.connect(SIGNAL('clicked()')) do
                    Roby.app.reload_models
                    Roby.app.reload_config
                    compute
                end

                @permanent = permanent
                @instance_txt.text = arguments
                compute
            end

            def create_toolbar
                toolbar_layout = Qt::HBoxLayout.new
                @apply_btn = Qt::PushButton.new("Reload && Apply", self)
                @instance_txt = Qt::LineEdit.new(self)
                toolbar_layout.add_widget(@apply_btn)
                toolbar_layout.add_widget(@instance_txt)
                toolbar_layout
            end

            def compute
                passes = Instanciate.parse_passes(instance_txt.text.split(" "))
                plan.clear
                exception_view.clear

                begin Instanciate.compute(plan, passes, true, true, true, false, permanent)
                rescue Exception => e
                    exception_view.push(e)
                end

                rendering.render_plan
            end
            slots 'compute()'

            def self.parse_passes(remaining)
                passes = []
                current = []
                while name = remaining.shift
                    if name == "/"
                        result << current
                        current = []
                    else
                        current << name
                    end
                end
                if !current.empty?
                    passes << current
                end
                passes
            end

            def self.compute(plan, passes, compute_policies, compute_deployments, validate_network, display_timepoints = false, permanent = [])
                Scripts.start_profiling
                Scripts.pause_profiling

                if passes.empty? && !permanent.empty?
                    passes << []
                end
                passes.each do |actions|
                    requirement_tasks = actions.each do |action_name|
                        act = ::Robot.action_from_name(action_name)
                        if !act.respond_to?(:requirements)
                            raise ArgumentError, "#{action_name} is not an action created from a Syskit definition or device"
                        end
                        plan.add_mission(task = act.requirements.as_plan)
                        task
                    end
                    permanent.each do |req|
                        plan.add_mission(task = req.as_plan)
                        requirement_tasks << task
                    end
                    requirement_tasks = requirement_tasks.map(&:planning_task)

                    Scripts.resume_profiling
                    Scripts.tic
                    engine = Syskit::NetworkGeneration::Engine.new(plan)
                    engine.resolve(:requirement_tasks => requirement_tasks,
                                   :compute_policies => compute_policies,
                                   :compute_deployments => compute_deployments,
                                   :validate_network => validate_network,
                                   :on_error => :commit)
                    plan.static_garbage_collect do |task|
                        plan.remove_object(task)
                    end
                    Scripts.toc_tic "computed deployment in %.3f seconds"
                    if display_timepoints
                        pp Roby.app.syskit_engine.format_timepoints
                    end
                    Scripts.pause_profiling
                end
                Scripts.end_profiling
            end
        end
    end
end

