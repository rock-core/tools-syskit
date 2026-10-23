# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module RobyApp
        describe LogIndex do
            before do
                @dir = make_tmpdir
                @path = File.join(@dir, "index.sqlite")
                @index = LogIndex.create(@path)
            end

            it "creates a valid database" do
                @index.dispose

                db = Sequel.connect("sqlite:///#{@path}")
                db.execute("PRAGMA journal_mode;") do |result|
                    assert_equal [["wal"]], result.to_a
                end
            end

            it "does nothing in write_log_rotation if there are no logs" do
                @index.write_log_rotation(Time.now)
                assert_equal [], @index.db[:log_files].select.to_a
            end

            describe "#register_new_log" do
                it "creates a new record for the new log file" do
                    t0, t1 = 2.times.map { Time.now.floor(5) }

                    @index.register_new_log(t0, "test.10.log", [])
                    @index.write_log_rotation(t1)

                    expected = [
                        { id: 1, basename: "test", sequence: 10, log_rotation_id: 1,
                          start_time: t0, end_time: nil, archive_name: nil }
                    ]
                    assert_equal expected, @index.db[:log_files].select.to_a
                end

                it "creates new streams and associates them with the log file" do
                    t0, t1 = 2.times.map { Time.now.floor(5) }

                    streams = { "some" => "/int32_t", "stream" => "/double" }
                    @index.register_new_log(t0, "test.10.log", streams)
                    @index.write_log_rotation(t1)

                    expected = [{ id: 1, name: "some", type: "/int32_t" },
                                { id: 2, name: "stream", type: "/double" }]
                    assert_equal expected, @index.db[:log_streams].select.to_a
                    expected = [{ log_stream_id: 1, log_file_id: 1 },
                                { log_stream_id: 2, log_file_id: 1 }]
                    assert_equal(
                        expected, @index.db[:log_file_stream_association].select.to_a
                    )
                end

                it "reuses existing streams to associate them with the log file" do
                    t0, t1 = 2.times.map { Time.now.floor(5) }

                    streams = { "some" => "/int32_t", "stream" => "/double" }
                    @index.register_new_log(t0, "test.10.log", streams)
                    @index.db[:log_streams].multi_insert(
                        [{ name: "foo", type: "t" }, { name: "some", type: "t" },
                         { name: "bar", type: "t" }]
                    )
                    @index.write_log_rotation(t1)

                    expected = [{ log_stream_id: 2, log_file_id: 1 },
                                { log_stream_id: 4, log_file_id: 1 }]
                    assert_equal(
                        expected, @index.db[:log_file_stream_association].select.to_a
                    )
                end
            end

            describe "#register_finished_log" do
                it "sets the end time on files with the same basename that do not have " \
                   "one, regardless of their sequence number" do
                    t0, t1, t2, = 4.times.map { Time.now.floor(5) }

                    @index.db[:log_files].insert(
                        basename: "test", sequence: 8, start_time: t0, log_rotation_id: 0
                    )
                    @index.register_finished_log(t1, "test.10.log")
                    @index.write_log_rotation(t2)

                    expected = [
                        { id: 1, basename: "test", sequence: 8, log_rotation_id: 0,
                          start_time: t0, end_time: t1, archive_name: nil }
                    ]
                    assert_equal expected, @index.db[:log_files].select.to_a
                end

                it "does not touch file records that have an end time" do
                    t0, t1, t2, t3 = 4.times.map { Time.now.floor(5) }

                    @index.db[:log_files]
                          .insert(basename: "test", sequence: 10,
                                  start_time: t0, end_time: t1, log_rotation_id: 0)
                    @index.register_finished_log(t2, "test.10.log")
                    @index.write_log_rotation(t3)

                    expected = [
                        { id: 1, basename: "test", sequence: 10, log_rotation_id: 0,
                          start_time: t0, end_time: t1, archive_name: nil }
                    ]
                    assert_equal expected, @index.db[:log_files].select.to_a
                end

                it "does not touch file records of different basenames" do
                    t0, _, t2, t3 = 4.times.map { Time.now.floor(5) }

                    @index.db[:log_files]
                          .insert(basename: "foobar", sequence: 10,
                                  start_time: t0, log_rotation_id: 0)
                    @index.register_finished_log(t2, "test.10.log")
                    @index.write_log_rotation(t3)

                    expected = [
                        { id: 1, basename: "foobar", sequence: 10, log_rotation_id: 0,
                          start_time: t0, end_time: nil, archive_name: nil }
                    ]
                    assert_equal expected, @index.db[:log_files].select.to_a
                end
            end

            it "behaves correctly if a file is rotated" do
                t0, t1, t2, = 4.times.map { Time.now.floor(5) }
                @index.register_new_log(t0, "test.9.log", [])
                @index.write_log_rotation(t0)
                @index.register_finished_log(t1, "test.9.log")
                @index.register_new_log(t2, "test.10.log", [])
                @index.write_log_rotation(t2)

                expected = [
                    { id: 1, basename: "test", sequence: 9, log_rotation_id: 1,
                      start_time: t0, end_time: t1, archive_name: nil },
                    { id: 2, basename: "test", sequence: 10, log_rotation_id: 2,
                      start_time: t2, end_time: nil, archive_name: nil }
                ]
                assert_equal expected, @index.db[:log_files].to_a
            end

            it "behaves correctly if a file is opened and closed in the same cycle" do
                _, t1, t2, t3 = 4.times.map { Time.now.floor(5) }
                @index.register_new_log(t1, "test.10.log", [])
                @index.register_finished_log(t2, "test.10.log")
                @index.write_log_rotation(t3)

                expected = [
                    { id: 1, basename: "test", sequence: 10, log_rotation_id: 1,
                      start_time: t1, end_time: t2, archive_name: nil }
                ]
                assert_equal expected, @index.db[:log_files].to_a
            end
        end
    end
end
