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
                it "does a full archive of a given dataset" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(4).pass_thru
                        LogRuntimeArchive.archive_dataset(archive_io, dataset, full: true)
                    end

                    entries = read_archive
                    assert_equal 4, entries.size
                    entries = entries.sort_by { _1[0].full_name }
                    assert_entry_matches(
                        *entries[0], name: "info.yml.zst", content: ""
                    )
                    assert_entry_matches(
                        *entries[1], name: "something.txt.zst", content: "something"
                    )
                    assert_entry_matches(
                        *entries[2], name: "test.0.log.zst", content: "test0"
                    )
                    assert_entry_matches(
                        *entries[3], name: "test.1.log.zst", content: "test1"
                    )
                end

                it "does a partial archive of a given dataset" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset
                    make_in_file "something.txt", "something", root: dataset

                    @archive_path.open("w") do |archive_io|
                        flexmock(LogRuntimeArchive)
                            .should_receive(:add_to_archive).times(1).pass_thru
                        LogRuntimeArchive.archive_dataset(
                            archive_io, dataset, full: false
                        )
                    end

                    entries = read_archive
                    assert_equal 1, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                end
            end

            describe ".process_root_folder" do
                it "archives all folders, the last one only partially" do
                    dataset0 = make_valid_folder("20220434-2023")
                    dataset1 = make_valid_folder("20220434-2024")
                    dataset2 = make_valid_folder("20220434-2025")

                    archive_dir = make_tmppath
                    flexmock(LogRuntimeArchive)
                        .should_receive(:archive_dataset)
                        .with(
                            ->(p) { p.path == (archive_dir / "20220434-2023.tar").to_s },
                            dataset0,
                            hsh(full: true)
                        ).once.pass_thru
                    flexmock(LogRuntimeArchive)
                        .should_receive(:archive_dataset)
                        .with(
                            ->(p) { p.path == (archive_dir / "20220434-2024.tar").to_s },
                            dataset1,
                            hsh(full: true)
                        ).once.pass_thru
                    flexmock(LogRuntimeArchive)
                        .should_receive(:archive_dataset)
                        .with(
                            ->(p) { p.path == (archive_dir / "20220434-2025.tar").to_s },
                            dataset2,
                            hsh(full: false)
                        ).once.pass_thru

                    LogRuntimeArchive.process_root_folder(@root, archive_dir)

                    assert (archive_dir / "20220434-2023.tar").file?
                    assert (archive_dir / "20220434-2024.tar").file?
                    assert (archive_dir / "20220434-2025.tar").file?
                end

                it "appends to existing archives" do
                    dataset = make_valid_folder("20220434-2023")
                    make_in_file "test.0.log", "test0", root: dataset
                    make_in_file "test.1.log", "test1", root: dataset

                    archive_dir = make_tmppath
                    LogRuntimeArchive.process_root_folder(@root, archive_dir)
                    make_in_file "test.2.log", "test2", root: dataset
                    LogRuntimeArchive.process_root_folder(@root, archive_dir)

                    entries = read_archive(path: archive_dir / "20220434-2023.tar")
                    assert_equal 2, entries.size
                    assert_entry_matches(
                        *entries[0], name: "test.0.log.zst", content: "test0"
                    )
                    assert_entry_matches(
                        *entries[1], name: "test.1.log.zst", content: "test1"
                    )
                end
            end

            def make_valid_folder(name)
                path = (@root / name)
                path.mkpath
                FileUtils.touch(path / "info.yml")
                path
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
