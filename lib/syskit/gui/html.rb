module Syskit
    module GUI
        module HTML
            class Button
                attr_reader :id
                attr_reader :on_text
                attr_reader :off_text
                attr_accessor :state

                def initialize(id, options = Hash.new)
                    options = Kernel.validate_options options,
                        :on_text => "#{id} (on)", :off_text => "#{id} (off)",
                        :state => false

                    if id[0, 1] != '/'
                        id = "/#{id}"
                    elsif id[-1, 1] == '/'
                        id = id[0..-2]
                    end
                    @id = id
                    @on_text = options[:on_text]
                    @off_text = options[:off_text]
                    @state = options[:state]
                end

                def html_id; id.gsub(/[^\w]/, '_') end

                def base_url; "btn://syskit#{id}" end
                def toggle_url
                    if state then "#{base_url}#off"
                    else "#{base_url}#on"
                    end
                end
                def url
                    if state then "#{base_url}#on"
                    else "#{base_url}#off"
                    end
                end
                def text
                    if state then off_text
                    else on_text
                    end
                end

                def render
                    "<a id=\"#{html_id}\" href=\"#{toggle_url}\">#{text}</a>"
                end
            end

            def self.render_button_bar(buttons)
                if !buttons.empty?
                    "<div class=\"button_bar\"><span>#{buttons.map(&:render).join(" / ")}</span></div>"
                end
            end
        end
    end
end

