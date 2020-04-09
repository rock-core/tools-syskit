# frozen_string_literal: true

require "syskit/gui/model_browser"
require "syskit/gui/page"
require "syskit/gui/html_page"
require "syskit/gui/component_network_view"
require "metaruby/gui/exception_view"

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
                @page = HTMLPage.new(@display.page)
                main_layout.add_widget(@display)
                @rendering = Syskit::GUI::ComponentNetworkView.new(@page)
                rendering.enable

                # Add the exception view
                @exception_view = MetaRuby::GUI::ExceptionView.new

                splitter.orientation = Qt::Vertical
                splitter.add_widget display
                splitter.set_stretch_factor 0, 3
                splitter.add_widget exception_view
                splitter.set_stretch_factor 1, 1

                @apply_btn.connect(SIGNAL("clicked()")) do
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    compute
                end

                @permanent = permanent
                @instance_txt.text = arguments
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

                begin
                    Instanciate.compute(plan, passes, true, true, true, false, permanent)
                rescue Exception => e
                    Roby.app.registered_exceptions.each do |loading_error, reason|
                        exception_view.push(loading_error, reason)
                    end
                    exception_view.push(e)
                end
                rendering.render_plan
            end
            slots "compute()"

            def self.parse_passes(remaining)
                passes = []
                current = []
                while name = remaining.shift
                    if name == "/"
                        passes << current
                        current = []
                    else
                        current << name
                    end
                end
                unless current.empty?
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
                    requirement_tasks = actions.map do |action_name|
                        action_name = action_name.gsub(/!$/, "")
                        begin
                            _, act = ::Robot.action_from_name(action_name)
                        rescue ArgumentError
                            act = eval(action_name).to_action # rubocop:disable Security/Eval
                        end

                        # Instanciate the action, and find out if it is actually
                        # a syskit-centric action or not
                        task = act.instanciate(plan)
                        if !(planner = task.planning_task) || !planner.respond_to?(:requirements)
                            raise ArgumentError, "#{action_name} is not an action created from a Syskit definition or device"
                        end

                        plan.add_mission_task(task)
                        task
                    end
                    permanent.each do |req|
                        plan.add_mission_task(task = req.as_plan)
                        requirement_tasks << task
                    end
                    requirement_tasks = requirement_tasks.map(&:planning_task)

                    Scripts.resume_profiling
                    Scripts.tic
                    engine = Syskit::NetworkGeneration::Engine.new(plan)
                    engine.resolve(requirement_tasks: requirement_tasks,
                                   compute_policies: compute_policies,
                                   compute_deployments: compute_deployments,
                                   validate_generated_network: validate_network,
                                   validate_deployed_network: validate_network,
                                   validate_final_network: validate_network,
                                   on_error: :commit)
                    plan.static_garbage_collect do |task|
                        plan.remove_task(task)
                    end
                    Scripts.toc_tic "computed deployment in %.3f seconds"
                    if display_timepoints
                        pp engine.format_timepoints
                    end
                    Scripts.pause_profiling
                end
                Scripts.end_profiling
            end
        end
    end
end
