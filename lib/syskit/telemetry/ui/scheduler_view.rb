# frozen_string_literal: true

require "erb"
require "qtwebkit"
require "cgi"

module Syskit
    module Telemetry
        module UI
            # View for scheduling-related log events
            class SchedulerView < Qt::WebView
                def initialize(*)
                    super

                    connect(SIGNAL("loadFinished(bool)")) do |ok|
                        if ok && @scroll_position
                            page.main_frame.scroll_position = @scroll_position
                        end
                    end
                end

                def contents_height
                    page.main_frame.contents_size.height
                end

                def resources_dir
                    File.expand_path(__dir__)
                end

                def scheduler_view_css
                    File.join(resources_dir, "scheduler_view.css")
                end

                def scheduler_view_rhtml
                    File.join(resources_dir, "scheduler_view.rhtml")
                end

                def erb
                    unless @erb
                        template = File.read(scheduler_view_rhtml)
                        @erb = ERB.new(template)
                    end
                    @erb
                end

                def format_pp(object)
                    object_s = CGI.escapeHTML(PP.pp(object, +""))
                    "<pre>#{object_s}</pre>"
                end

                def format_msg_string(msg, *args)
                    string = args.each_with_index.inject(msg) do |updated_msg, (a, i)|
                        a = if a.respond_to?(:map)
                                a.map(&:to_s).join(", ")
                            else
                                a.to_s
                            end
                        updated_msg.gsub "%#{i + 1}", a
                    end
                    CGI.escapeHTML(string)
                end

                # Displays the state of the scheduler. It clears existing
                # information
                #
                # @param [Schedulers::State] state the state
                def display(state)
                    code = erb.result(binding)
                    return if @code == code

                    @scroll_position = page.main_frame.scroll_position
                    @code = self.html = code
                end
            end
        end
    end
end
