# frozen_string_literal: true

module Syskit
    module RobyApp
        class LogIndex
            # The underlying database handle
            #
            # Meant for tests. Use the public API.
            #
            # @return [Sequel::Database]
            attr_reader :db

            def self.open(path)
                db = connect(path)
                new(db)
            end

            def self.create(path)
                db = connect(path)

                index = new(db)
                index.create_schema
                index
            end

            def self.connect(path)
                Sequel.connect(
                    "sqlite://#{path}",
                    connect_sqls: [
                        "PRAGMA journal_mode = WAL;",
                        "PRAGMA synchronous = NORMAL;"
                    ]
                )
            end

            def initialize(db)
                @db = db
                @log_files = db[:log_files]

                @pending_finished_logs = []
                @pending_new_logs = []
            end

            def dispose
                @db.disconnect
                @db = nil
            end

            LogFinished = Struct.new(:time, :path, keyword_init: true)

            # Register that an existing log file has been finished
            #
            # For performance reasons, the method does not immediately save the
            # information in the log index. It will automatically be registered at the end
            # of the log rotation pass by calling #write_log_rotation
            #
            # @param [Time] time the time that should be used as the end time of
            #   'old_path' and start time of 'new_path'. It is understood that it might be
            #   inaccurante by a few seconds.
            # @param [String] path path of the log file that was just closed
            def register_finished_log(time, path)
                @pending_finished_logs << LogFinished.new(time: time, path: path)
            end

            LogNew = Struct.new(:time, :path, :streams, keyword_init: true)

            # Register that a log file has been rotated
            #
            # For performance reasons, the method does not immediately save the rotation
            # in the log index. It will automatically be registered at the end of the log
            # rotation pass by calling #write_pending_rotated_logs
            #
            # @param [Time] time the time that should be used as the end time of
            #   'old_path' and start time of 'new_path'. It is understood that it might be
            #   inaccurante by a few seconds.
            # @param [String,nil] old_path of the log file that was just closed. `nil` if
            #   we are creating a new file
            # @param [String,nil] new_path of the log file that has just been created.
            #   `nil` if an old file has been closed but no new file has been created
            def register_new_log(time, path, streams)
                @pending_new_logs << LogNew.new(time: time, path: path, streams: streams)
            end

            # Write to the DB all registered log rotations since the last write, as a
            # single log rotation
            def write_log_rotation(time)
                return if @pending_finished_logs.empty? && @pending_new_logs.empty?

                @db.transaction(mode: :immediate) do
                    log_rotation_id = @db[:log_rotations].insert(time: time)

                    @pending_finished_logs.each do |r|
                        basename, = path_to_log_info(r.path)

                        @log_files
                            .filter(basename: basename, end_time: nil)
                            .update(end_time: r.time)
                    end

                    @pending_new_logs.each do |r|
                        basename, sequence = path_to_log_info(r.path)

                        id = @log_files.insert(
                            basename: basename, log_rotation_id: log_rotation_id,
                            sequence: sequence, start_time: r.time
                        )

                        next if r.streams.empty?

                        associations =
                            insert_and_resolve_stream_ids(r.streams)
                            .values.map do |stream_id|
                                { log_file_id: id, log_stream_id: stream_id }
                            end

                        @db[:log_file_stream_association].multi_insert(associations)
                    end
                end

                @pending_finished_logs.clear
                @pending_new_logs.clear
            end

            def insert_and_resolve_stream_ids(stream_names)
                resolved_streams =
                    @db[:log_streams].where(name: stream_names).to_h { |r| [r[:name], r[:id]] }
                stream_names.map do |stream_name|
                    next if resolved_streams.key?(stream_name)

                    resolved_streams[stream_name] = @db[:log_streams].insert(name: stream_name)
                end
                resolved_streams
            end

            # @api private
            #
            # Extract sequence number and log basename from a log file path
            def path_to_log_info(path)
                basename = File.basename(path, ".log")
                m = basename.match(/\.(\d+)/)
                [m.pre_match, Integer(m[1])]
            end

            def create_schema # rubocop:disable Metrics/AbcSize
                @db.create_table :log_files do
                    primary_key :id
                    String :basename, null: false
                    Integer :sequence, null: false

                    foreign_key :log_rotation_id
                    Time :start_time, null: false
                    Time :end_time
                    String :archive_name
                end

                @db.create_table :log_rotations do
                    primary_key :id
                    Time :time
                end

                @db.create_table :log_streams do
                    primary_key :id
                    String :name, null: false
                end

                @db.create_table :log_file_stream_association do
                    foreign_key :log_file_id
                    foreign_key :log_stream_id
                end
            end
        end
    end
end
