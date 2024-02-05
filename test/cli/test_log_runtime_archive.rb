# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive"

module Syskit
    module CLI
        describe LogRuntimeArchive do
            before do
                @root = make_tmppath
                @archive_path = (make_tmppath / "archive.tar")
                @in_files = []
            end

            describe ".find_all_dataset_folders" do
                it "returns the directories that look like a dataset path" do
                    path = make_valid_folder("20229523-1104.1")
                    assert_equal(
                        [path],
                        LogRuntimeArchive.find_all_dataset_folders(@root)
                    )
                end

                it "sorts the entries lexicographically" do
                    path1 = make_valid_folder("20229523-1104.1")
                    path2 = make_valid_folder("20229423-1104.1")
                    assert_equal(
                        [path2, path1],
                        LogRuntimeArchive.find_all_dataset_folders(@root)
                    )
                end

                it "does not return paths that match the pattern but "\
                   "do not have a info.yml file inside" do
                    path = (@root / "20229423-1104")
                    path.mkpath
                    assert_equal([], LogRuntimeArchive.find_all_dataset_folders(@root))
                end

                it "does not return paths that do not match the pattern" do
                    path = (@root / "20240223-11043")
                    path.mkpath
                    FileUtils.touch(path / "info.yml")
                    assert_equal([], LogRuntimeArchive.find_all_dataset_folders(@root))
                end

                it "ignores paths that match the pattern but are not folders" do
                    path = (@root / "20240223-1104")
                    FileUtils.touch(path.to_s)
                    assert_equal([], LogRuntimeArchive.find_all_dataset_folders(@root))
                end
            end

            describe ".add_to_archive" do
                it "adds a compressed version of the input I/O to the archive "\
                   "and deletes the input file" do
                    something = make_in_file "something.txt", "something"

                    @archive_path.open("w") do |archive_io|
                        @in_files.each do |in_path|
                            LogRuntimeArchive.add_to_archive(archive_io, in_path)
                        end
                    end

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries.first, name: "something.txt.zst", content: "something"
                    )
                    refute something.exist?
                end

                it "creates a multi-file archive" do
                    bla = make_in_file "bla.txt", "bla"
                    blo = make_in_file "blo.txt", "blo"
                    @archive_path.open("w") do |archive_io|
                        @in_files.each do |in_path|
                            LogRuntimeArchive.add_to_archive(archive_io, in_path)
                        end
                    end

                    entries = read_archive
                    assert_equal 2, entries.size
                    assert_entry_matches(*entries[0], name: "bla.txt.zst", content: "bla")
                    assert_entry_matches(*entries[1], name: "blo.txt.zst", content: "blo")
                    refute bla.exist?
                    refute blo.exist?
                end

                it "restores the file as it was and keeps the input file if zstd fails "\
                   "but continues with other files" do
                    bla = make_in_file "bla.txt", "bla"
                    blo = make_in_file "blo.txt", "blo"
                    bli = make_in_file "bli.txt", "bli"

                    @archive_path.open("w") do |archive_io|
                        assert LogRuntimeArchive.add_to_archive(archive_io, bla)
                        FlexMock.use(Process) do |mock|
                            mock.should_receive(:waitpid2).once
                                .and_return([10, flexmock(success?: false)])
                            refute LogRuntimeArchive.add_to_archive(archive_io, blo)
                        end
                        assert LogRuntimeArchive.add_to_archive(archive_io, bli)
                    end

                    entries = read_archive
                    assert_equal 2, entries.size
                    assert_entry_matches(*entries[0], name: "bla.txt.zst", content: "bla")
                    assert_entry_matches(*entries[1], name: "bli.txt.zst", content: "bli")
                    refute bla.exist?
                    assert blo.exist?
                    refute bli.exist?
                end

                it "restores the file as it was and keeps the input file if an "\
                   "exception occurs" do
                    bla = make_in_file "bla.txt", "bla"
                    blo = make_in_file "blo.txt", "blo"
                    bli = make_in_file "bli.txt", "bli"

                    @archive_path.open("w") do |archive_io|
                        assert LogRuntimeArchive.add_to_archive(archive_io, bla)
                        FlexMock.use(Process) do |mock|
                            mock.should_receive(:waitpid2).once
                                .and_raise(Exception.new)
                            flexmock(Roby).should_receive(:display_exception).once
                            refute LogRuntimeArchive.add_to_archive(archive_io, blo)
                        end
                        assert LogRuntimeArchive.add_to_archive(archive_io, bli)
                    end

                    entries = read_archive
                    assert_equal 2, entries.size
                    assert_entry_matches(*entries[0], name: "bla.txt.zst", content: "bla")
                    assert_entry_matches(*entries[1], name: "bli.txt.zst", content: "bli")
                    refute bla.exist?
                    assert blo.exist?
                    refute bli.exist?
                end
            end

            describe ".archive_dataset" do
                it "in full mode, archives only the rotated logs if there are some" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(2).pass_thru
                        LogRuntimeArchive.archive_dataset(archive_io, dataset, full: true)
                    end
                    refute ret

                    entries = read_archive
                    assert_equal 2, entries.size
                    entries = entries.sort_by { _1[0].full_name }
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                    assert_entry_matches(
                        *entries[1], name: "test.1.log.zst", content: "test1"
                    )
                end

                it "in full mode, archives the non-rotated logs "\
                   "if there are no rotated logs" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "something.txt", "something", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(2).pass_thru
                        LogRuntimeArchive.archive_dataset(archive_io, dataset, full: true)
                    end
                    assert ret

                    entries = read_archive
                    assert_equal 2, entries.size
                    entries = entries.sort_by { _1[0].full_name }
                    assert_entry_matches(
                        *entries[0], name: "info.yml.zst", content: ""
                    )
                    assert_entry_matches(
                        *entries[1], name: "something.txt.zst", content: "something"
                    )
                end

                it "does a partial archive of a given dataset" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false
                        )
                    end
                    assert ret

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                end

                it "stops processing when it reaches the max size" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "test.2.log", "test2", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false, max_size: 4
                        )
                    end
                    refute ret

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                end

                it "orders log files according to their index" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "test.2.log", "test2", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        flexmock(LogRuntimeArchive)
                            .should_receive(:each_file_from_path)
                            .pass_thru { |files| files.to_a.shuffle }

                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false, max_size: 4
                        )
                    end
                    refute ret

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                end

                it "always adds at least a file, "\
                   "regardless of the current size of the archive" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "test.2.log", "test2", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(2).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false, max_size: 4
                        )
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false, max_size: 4
                        )
                    end
                    assert ret

                    entries = read_archive
                    assert_equal 2, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                    assert_entry_matches(
                        *entries[1], name: "test.1.log.zst", content: "test1"
                    )
                end

                it "reports a complete processing in full mode if the size limit "\
                   "is reached on the last rotated log and "\
                   "there are no non-rotated logs" do
                    dataset = @root / "20220434-2023"
                    dataset.mkpath
                    make_in_file "test.0.log", "test0", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: true, max_size: 0
                        )
                    end
                    assert ret

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                end

                it "reports a complete processing in full mode if the size limit "\
                   "is reached on the last non-rotated log and "\
                   "there are no rotated logs" do
                    dataset = make_valid_folder("20220434-2023")

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: true, max_size: 0
                        )
                    end
                    assert ret

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "info.yml.zst", content: ""
                    )
                end

                it "reports a complete processing in partial mode if the size limit "\
                   "is reached on the last log to process" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset

                    ret = @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false, max_size: 512
                        )
                    end
                    assert ret

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                end
            end

            describe ".process_root_folder" do
                before do
                    @archive_dir = make_tmppath
                    @process = LogRuntimeArchive.new(@root, @archive_dir)
                end

                it "archives all folders, the last one only partially" do
                    dataset0 = make_valid_folder("20220434-2023")
                    dataset1 = make_valid_folder("20220434-2024")
                    dataset2 = make_valid_folder("20220434-2025")

                    should_archive_dataset(dataset0, "20220434-2023.0.tar", full: true)
                    should_archive_dataset(dataset1, "20220434-2024.0.tar", full: true)
                    should_archive_dataset(dataset2, "20220434-2025.0.tar", full: false)
                    @process.process_root_folder

                    assert (@archive_dir / "20220434-2023.0.tar").file?
                    assert (@archive_dir / "20220434-2024.0.tar").file?
                    assert (@archive_dir / "20220434-2025.0.tar").file?
                end

                it "splits the archive according to the max size" do
                    dataset = make_valid_folder("20220434-2023")
                    (dataset / "test.0.log")
                        .write(test0 = Base64.encode64(Random.bytes(1024)))
                    (dataset / "test.1.log")
                        .write(test1 = Base64.encode64(Random.bytes(1024)))
                    (dataset / "test.2.log").write(Base64.encode64(Random.bytes(1024)))
                    process = LogRuntimeArchive.new(
                        @root, @archive_dir, max_archive_size: 1024
                    )
                    process.process_root_folder

                    entries = read_archive(path: @archive_dir / "20220434-2023.0.tar")
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: test0
                    )

                    entries = read_archive(path: @archive_dir / "20220434-2023.1.tar")
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.1.log.zst", content: test1
                    )

                    refute (@archive_dir / "20220434-2023.2.tar").exist?
                end

                it "appends to the last created archive" do
                    dataset = make_valid_folder("20220434-2023")
                    (dataset / "test.0.log")
                        .write(Base64.encode64(Random.bytes(1024)))
                    (dataset / "test.1.log")
                        .write(test1 = Base64.encode64(Random.bytes(128)))
                    (dataset / "test.2.log")
                        .write(test2 = Base64.encode64(Random.bytes(128)))
                    process = LogRuntimeArchive.new(
                        @root, @archive_dir, max_archive_size: 1024
                    )
                    process.process_root_folder

                    (dataset / "test.3.log").write(Base64.encode64(Random.bytes(1024)))
                    process.process_root_folder

                    entries = read_archive(path: @archive_dir / "20220434-2023.1.tar")
                    assert_equal 2, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.1.log.zst", content: test1
                    )
                    assert_entry_matches(
                        *entries[1], name: "test.2.log.zst", content: test2
                    )

                    refute (@archive_dir / "20220434-2023.2.tar").exist?
                end

                it "creates a new archive if the last archive is already "\
                   "above the limit" do
                    dataset = make_valid_folder("20220434-2023")
                    make_random_file "test.0.log", root: dataset
                    test1 = make_random_file "test.1.log", root: dataset
                    test2 = make_random_file "test.2.log", root: dataset
                    process = LogRuntimeArchive.new(
                        @root, @archive_dir, max_archive_size: 1024
                    )
                    process.process_root_folder

                    make_random_file "test.3.log", root: dataset
                    process.process_root_folder

                    entries = read_archive(path: @archive_dir / "20220434-2023.1.tar")
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.1.log.zst", content: test1
                    )

                    entries = read_archive(path: @archive_dir / "20220434-2023.2.tar")
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.2.log.zst", content: test2
                    )

                    refute (@archive_dir / "20220434-2023.3.tar").exist?
                end

                it "appends to existing archives" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset

                    @process.process_root_folder
                    make_in_file "test.2.log", "test2", root: dataset
                    @process.process_root_folder

                    entries = read_archive(path: @archive_dir / "20220434-2023.0.tar")
                    assert_equal 2, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                    assert_entry_matches(
                        *entries[1], name: "test.1.log.zst", content: "test1"
                    )
                end

                it "gathers all non-rotated logs in the very last archive" do
                    dataset = make_valid_folder("20220434-2023")
                    make_valid_folder("20220434-2024")
                    make_random_file "test.0.log", root: dataset
                    make_random_file "test.1.log", root: dataset
                    make_random_file "test.2.log", root: dataset
                    make_random_file "test.txt", root: dataset
                    make_random_file "test-PID.txt", root: dataset

                    @process.process_root_folder

                    entries = read_archive(path: @archive_dir / "20220434-2023.0.tar")
                    assert_equal %w[test.0.log.zst test.1.log.zst test.2.log.zst],
                                 entries.map { _1.first.name }.sort

                    entries = read_archive(path: @archive_dir / "20220434-2023.1.tar")
                    assert_equal %w[info.yml.zst test-PID.txt.zst test.txt.zst],
                                 entries.map { _1.first.name }.sort
                end

                def should_archive_dataset(dataset, archive_basename, full:)
                    flexmock(LogRuntimeArchive)
                        .should_receive(:archive_dataset)
                        .with(
                            ->(p) { p.path == (@archive_dir / archive_basename).to_s },
                            dataset, hsh(full: full)
                        ).once.pass_thru
                end
            end

            describe "#ensure_free_space" do
                before do
                    @archive_dir = make_tmppath
                    @mocked_files_sizes = []

                    10.times { |i| (@archive_dir / i.to_s).write(i.to_s) }

                    @archiver = LogRuntimeArchive.new(@root, @archive_dir)
                end

                it "does nothing if there is enough free space" do
                    mock_available_space(2)
                    @archiver.ensure_free_space(1, 10)
                    assert_deleted_files([])
                end

                it "removes enough files to reach the freed limit" do
                    size_files = [6, 2, 1, 6, 7, 10, 3, 5, 8, 9]
                    mock_files_size(size_files)
                    mock_available_space(0.5)

                    @archiver.ensure_free_space(1, 10)
                    assert_deleted_files([0, 1, 2, 3])
                end

                it "stops removing files when there is no file in folder even if freed
                    limit is not achieved" do
                    size_files = Array.new(10, 1)
                    mock_files_size(size_files)
                    mock_available_space(0.5)

                    @archiver.ensure_free_space(1, 15)
                    assert_deleted_files([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
                end

                def mock_files_size(sizes)
                    @mocked_files_sizes = sizes
                    @mocked_files_sizes.each_with_index do |size, i|
                        (@archive_dir / i.to_s).write(" " * size)
                    end
                end

                def mock_available_space(total_available_disk_space)
                    flexmock(Sys::Filesystem)
                        .should_receive(:stat).with(@archive_dir)
                        .and_return do
                            flexmock(
                                bytes_free: total_available_disk_space
                            )
                        end
                end

                def assert_deleted_files(deleted_files) # rubocop:disable Metrics/AbcSize
                    if deleted_files.empty?
                        files = @archive_dir.each_child.select(&:file?)
                        assert_equal 10, files.size
                    else
                        (0..9).each do |i|
                            if deleted_files.include?(i)
                                refute (@archive_dir / i.to_s).exist?,
                                       "#{i} was expected to be deleted, but has not been"
                            else
                                assert (@archive_dir / i.to_s).exist?,
                                       "#{i} was expected to be present, but got deleted"
                            end
                        end
                    end
                end
            end

            def make_valid_folder(name)
                path = (@root / name)
                path.mkpath
                FileUtils.touch(path / "info.yml")
                path
            end

            def make_random_file(name, root: @root, size: 1024)
                content = Base64.encode64(Random.bytes(size))
                make_in_file name, content, root: root
                content
            end

            def make_in_file(name, content, root: @root)
                path = (root / name)
                path.write(content)
                @in_files << path
                path
            end

            def read_archive(path: @archive_path)
                tar = Archive::Tar::Minitar::Input.open(path.open("r"))
                tar.each_entry.map { |e| [e, e.read] }
            end

            def decompress_data(data)
                IO.popen(["zstd", "-d", "--stdout"], "r+") do |io|
                    io.write data
                    io.close_write
                    io.read
                end
            end

            def assert_entry_matches(entry, data, name:, content:)
                assert entry.file?
                assert_equal name, entry.full_name
                assert_equal content, decompress_data(data)
            end
        end
    end
end
