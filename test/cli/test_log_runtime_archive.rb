# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive"

module Syskit
    module CLI
        describe LogRuntimeArchive do
            describe ".find_all_dataset_folders" do
                before do
                    @root = make_tmppath
                end

                def make_valid_folder(name)
                    path = (@root / name)
                    path.mkpath
                    FileUtils.touch(path / "info.yml")
                    path
                end

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
                before do
                    @root = make_tmppath
                    @archive_path = (make_tmppath / "archive.tar")
                    @in_files = []
                end

                def make_in_file(name, content)
                    path = (@root / name)
                    path.write(content)
                    @in_files << path
                    path
                end

                def read_archive
                    tar = Archive::Tar::Minitar::Input.open(@archive_path.open("r"))
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
        end
    end
end
