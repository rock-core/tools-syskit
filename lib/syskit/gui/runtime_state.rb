require 'syskit'
require 'roby/interface/async'

module Syskit
    module GUI
        # UI that displays and allows to control jobs
        class RuntimeState < Qt::Widget
            # @return [Roby::Interface::Async::Interface] the underlying syskit
            #   interface
            attr_reader :syskit

            # The toplevel layout
            attr_reader :main_layout
            # The layout used to organize the widgets to create new jobs
            attr_reader :new_job_layout
            # The layout used to organize the running jobs
            attr_reader :job_control_layout
            # The combo box used to create new jobs
            attr_reader :action_combo

            class ActionListDelegate < Qt::StyledItemDelegate
                OUTER_MARGIN = 5
                INTERLINE    = 3
                def sizeHint(option, index)
                    fm = option.font_metrics
                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    Qt::Size.new(
                        [fm.width(main), fm.width(doc)].max + 2 * OUTER_MARGIN,
                        fm.height * 2 + OUTER_MARGIN * 2 + INTERLINE)
                end

                def paint(painter, option, index)
                    painter.save

                    if (option.state & Qt::Style::State_Selected) != 0
                        painter.fill_rect(option.rect, option.palette.highlight)
                        painter.brush = option.palette.highlighted_text
                    end

                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    text_bounds = Qt::Rect.new

                    fm = option.font_metrics
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, option.rect.y + OUTER_MARGIN, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, main, text_bounds)

                    font = painter.font
                    font.italic = true
                    painter.font = font
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, text_bounds.bottom + INTERLINE, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, doc, text_bounds)
                ensure
                    painter.restore
                end
            end

            # @param [Roby::Interface::Async::Interface] syskit the underlying
            #   syskit interface
            # @param [Integer] poll_period how often should the syskit interface
            #   be polled (milliseconds). Set to nil if the polling is already
            #   done externally
            def initialize(parent:nil, syskit: Roby::Interface::Async::Interface.new, poll_period: 10)
                super(parent)

                if poll_period
                    poll_syskit_interface(syskit, poll_period)
                end

                create_ui

                @syskit = syskit
                syskit.on_reachable do
                    action_combo.clear
                    syskit.actions.sort_by(&:name).each do |action|
                        action_combo.add_item(action.name, Qt::Variant.new(action.doc))
                    end
                    emit connection_state_changed(true)
                end
                syskit.on_unreachable do
                    emit connection_state_changed(false)
                end
                syskit.on_job do |job|
                    job.start
                    monitor_job(job)
                end
            end

            signals 'connection_state_changed(bool)'

            def remote_name
                syskit.remote_name
            end

            def create_ui
                main_layout = Qt::VBoxLayout.new(self)
                main_layout.add_layout(@new_job_layout = new_job_ui)
                main_layout.add_layout(@job_control_layout = job_control_ui)
                main_layout.add_stretch(1)
            end

            def job_control_ui
                job_control_layout = Qt::GridLayout.new
                job_control_layout
            end

            def new_job_ui
                new_job_layout = Qt::HBoxLayout.new
                label   = Qt::Label.new("New Job", self)
                @action_combo = Qt::ComboBox.new(self)
                action_combo.item_delegate = ActionListDelegate.new(self)
                new_job_layout.add_widget label
                new_job_layout.add_widget action_combo, 1
                action_combo.connect(SIGNAL('activated(QString)')) do |action_name|
                    create_new_job(action_name)
                end
                new_job_layout
            end

            def create_new_job(action_name)
                action_model = syskit.actions.find { |m| m.name == action_name }
                if !action_model
                    raise ArgumentError, "no action named #{action_name} found"
                end
            end

            # @api private
            #
            # Sets up polling on a given syskit interface
            def poll_syskit_interface(syskit, period)
                syskit_poll = Qt::Timer.new
                syskit_poll.connect(SIGNAL('timeout()')) do
                    syskit.poll
                end
                syskit_poll.start(period)
                syskit
            end

            # @api private
            #
            # Create the UI elements for the given job
            #
            # @param [Roby::Interface::Async::JobMonitor] job
            def monitor_job(job)
                job_state = Vizkit.default_loader.StateViewer
                job_state.set_size_policy(Qt::SizePolicy::MinimumExpanding, Qt::SizePolicy::Minimum)
                job_state.update :INIT,
                    "##{job.job_id} #{job.action_name}",
                    job_state.unreachable_color
                job_kill = Qt::PushButton.new(self, "Kill")
                job_kill.connect(SIGNAL(:clicked)) do
                    job.kill
                end
                row = job_control_layout.row_count
                job_control_layout.add_widget job_state, row, 0
                job_control_layout.add_widget job_kill, row, 1
            end
        end
    end
end

