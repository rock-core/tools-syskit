# frozen_string_literal: true

module Syskit
    module GUI
        class WidgetList < Qt::Widget
            def auto_resize?
                @auto_resize
            end

            ListItem = Struct.new :widget, :permanent do
                def job
                    widget.job
                end

                def permanent?
                    permanent
                end
            end

            def initialize(parent = nil, auto_resize: true)
                super(parent)

                @main_layout = Qt::VBoxLayout.new(self)
                @widgets = []
                self.size_constraint = Qt::Layout::SetMinAndMaxSize
                @auto_resize = auto_resize
                if auto_resize
                    @main_layout.add_stretch(1)
                end
                @separators = {}
            end

            def size_constraint=(constraint)
                @main_layout.size_constraint = constraint
            end

            def add_separator(name, label, permanent: true)
                add_widget(w = Qt::Label.new(label, self), permanent: permanent)
                @separators[name] = w
                w
            end

            def add_before(widget, before, permanent: false)
                if before.respond_to?(:to_str)
                    before = @separators.fetch(before)
                end

                if i = @widgets.index { |w| w.widget == before }
                    @main_layout.insert_widget(i, widget)
                    @widgets.insert(i, ListItem.new(widget, permanent))
                else Kernel.raise ArgumentError, "#{before} is not part of #{self}"
                end
            end

            def add_after(widget, after, permanent: false)
                if after.respond_to?(:to_str)
                    after = @separators.fetch(after)
                end

                if i = @widgets.index { |w| w.widget == after }
                    @main_layout.insert_widget(i + 1, widget)
                    @widgets.insert(i + 1, ListItem.new(widget, permanent))
                else Kernel.raise ArgumentError, "#{after} is not part of #{self}"
                end
            end

            def add_widget(w, permanent: false)
                @widgets << ListItem.new(w, permanent)
                if auto_resize?
                    @main_layout.insert_widget(@widgets.size - 1, w)
                else
                    @main_layout.add_widget(w)
                end
            end

            def children_size_updated
                s = size
                new_height = @widgets.inject(0) do |h, w|
                    h + if w.widget.hidden? then 0
                        else w.widget.contents_height
                        end
                end
                if new_height != s.height
                    self.size = s
                end
            end

            def resizeEvent(event)
                s = size
                s.width = event.size.width
                self.size = s
                event.accept
            end

            # Enumerate the widgets in the list
            def each_widget
                return enum_for(__method__) unless block_given?

                @widgets.each do |item|
                    yield(item.widget)
                end
            end

            # Clear widgets for which the given filter returns true
            #
            # It removes all widgets if no filter is given
            #
            # @yieldparam [ListItem] item
            def clear_widgets(&filter)
                filter ||= ->(w) { true }
                separators = @separators.values

                kept_widgets = []
                until @widgets.empty?
                    w = @widgets.last
                    if !separators.include?(w.widget) && !w.permanent? && filter[w.widget]
                        @main_layout.remove_widget(w.widget)
                        w.widget.dispose
                    else
                        kept_widgets.unshift w
                    end
                    @widgets.pop
                end
            ensure
                @widgets.concat(kept_widgets)
            end
        end
    end
end
