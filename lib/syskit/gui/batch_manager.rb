# frozen_string_literal: true

require "syskit/gui/widget_list"

module Syskit
    module GUI
        class BatchManager < WidgetList
            def initialize(syskit, parent = nil)
                super(parent)
                @syskit = syskit

                @actions = Qt::Widget.new
                actions_layout = Qt::HBoxLayout.new(@actions)
                @process_btn = Qt::PushButton.new("Process")
                @cancel_btn  = Qt::PushButton.new("Cancel")

                actions_layout.add_widget(@process_btn)
                actions_layout.add_widget(@cancel_btn)
                add_widget(@actions, permanent: true)

                @process_btn.connect(SIGNAL(:clicked)) do
                    process
                end
                @cancel_btn.connect(SIGNAL(:clicked)) do
                    cancel
                end
                disable_actions

                @start_job = []
                @drop_job = []
            end

            def process
                batch = @syskit.client.create_batch
                @drop_job.each do |j|
                    batch.drop_job(j.job_id)
                end
                @start_job.each do |j|
                    arguments = j.action_arguments
                    arguments.delete(:job_id)
                    batch.start_job(j.action_name, arguments)
                end
                begin
                    batch.__process
                rescue Exception => e # rubocop:disable Lint/RescueException
                    Roby.display_exception(STDOUT, e)

                    Qt::MessageBox.critical(
                        self, "Syskit Process Batch",
                        "failed to process batch: #{e.message}, "\
                        "see console output for more details"
                    )
                end
                clear
            end

            def cancel
                clear
            end

            def clear
                clear_widgets
                @start_job.clear
                @drop_job.clear
                disable_actions
            end

            StartJob = Struct.new :action_name, :action_arguments

            def disable_actions
                emit active(false)
                @process_btn.enabled = false
                @cancel_btn.enabled = false
            end

            def enable_actions
                emit active(true)
                @process_btn.enabled = true
                @cancel_btn.enabled = true
            end

            signals "active(bool)"

            def drop_job(job_widget)
                @drop_job << job_widget.job
                add_before(Qt::Label.new("<b>Drop</b> #{job_widget.label}"), @actions)
                enable_actions
            end

            def start_job(action_name, action_arguments)
                @start_job << StartJob.new(action_name, action_arguments)
                add_before(Qt::Label.new("<b>Start</b> #{action_name}"), @actions)
                enable_actions
            end

            def create_new_job(action_name, arguments = {})
                action_model = @syskit.actions.find { |m| m.name == action_name }
                unless action_model
                    raise ArgumentError, "no action named #{action_name} found"
                end

                if action_model.arguments.empty?
                    start_job(action_name, {})
                    true
                else
                    formatted_arguments = String.new
                    action_model.arguments.each do |arg|
                        default_arg = arguments.fetch(
                            arg.name.to_sym, arg.default
                        )
                        has_default_arg = arguments.key?(arg.name.to_sym) || !arg.required?

                        unless formatted_arguments.empty?
                            formatted_arguments << ",\n"
                        end
                        doc_lines = (arg.doc || "").split("\n")
                        formatted_arguments << "\n  # #{doc_lines.join("\n  # ")}\n"
                        if !has_default_arg
                            formatted_arguments << "  #{arg.name}: "
                        elsif default_arg.nil?
                            formatted_arguments << "  #{arg.name}: nil"
                        elsif default_arg.respond_to?(:name) && MetaRuby::Registration.accessible_by_name?(default_arg)
                            formatted_arguments << "  #{arg.name}: #{default_arg.name}"
                        elsif as_string = ToString.convert(default_arg)
                            formatted_arguments << "  #{arg.name}: #{as_string}"
                        elsif arg.required?
                            formatted_arguments << "  #{arg.name}: "
                        else
                            formatted_arguments << "  # #{arg.name}'s default argument cannot be handled by the IDE\n"
                            formatted_arguments << "  # #{arg.name}: #{default_arg}"

                        end
                    end
                    formatted_action = "#{action_name}!(\n#{formatted_arguments}\n)"
                    dialog = NewJobDialog.new(self, formatted_action)
                    if dialog.exec == Qt::Dialog::Accepted
                        action_name, action_options = dialog.result
                        start_job(action_name, action_options)
                        true
                    else false
                    end
                end
            end

            class ToString < BasicObject
                def self.const_missing(const_name)
                    ::Object.const_get(const_name)
                end

                def self.convert(obj)
                    if obj.kind_of?(Symbol)
                        ":#{obj}"
                    elsif obj.kind_of?(String)
                        "\"#{obj}\""
                    else
                        as_string = obj.to_s
                        parser = new
                        begin
                            if parser.instance_eval(as_string) == obj
                                as_string
                            end
                        rescue Exception
                        end
                    end
                end
            end

            class NewJobDialog < Qt::Dialog
                attr_reader :editor

                def initialize(parent = nil, text = "")
                    super(parent)
                    resize(800, 600)

                    layout = Qt::VBoxLayout.new(self)
                    @error_message = Qt::Label.new(self)
                    @error_message.style_sheet = "QLabel { background-color: #ffb8b9; border: 1px solid #ff6567; padding: 5px; }"
                    @error_message.frame_style = Qt::Frame::StyledPanel
                    layout.add_widget(@error_message)
                    @error_message.hide

                    @editor = Qt::TextEdit.new(self)
                    self.text = text
                    layout.add_widget editor

                    buttons = Qt::DialogButtonBox.new(Qt::DialogButtonBox::Ok | Qt::DialogButtonBox::Cancel)
                    buttons.connect(SIGNAL("accepted()")) do
                        begin
                            @error_message.hide
                            @result = Parser.parse(self.text)
                            accept
                        rescue Exception => e
                            @error_message.text = e.message
                            @error_message.show
                        end
                    end
                    buttons.connect(SIGNAL("rejected()")) { reject }
                    layout.add_widget buttons
                end

                def self.exec(parent, text)
                    new(parent, text).exec
                end

                class Parser < BasicObject
                    def self.const_missing(const_name)
                        ::Object.const_get(const_name)
                    end

                    def self.parse(text)
                        parser = new
                        parser.instance_eval(text)
                        parser.__result
                    end

                    def method_missing(m, **options)
                        @method_name = m[0..-2]
                        @method_options = options
                    end

                    def __result
                        [@method_name, @method_options]
                    end
                end

                def result
                    @result
                end

                def text=(text)
                    editor.plain_text = text
                end

                def text
                    editor.to_plain_text
                end
            end
        end
    end
end
