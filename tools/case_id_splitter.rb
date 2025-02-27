#!/usr/bin/env ruby
# frozen_string_literal: true

"""
Utility to split feature files by given case IDs
"""

require 'commander'
require 'fileutils'

require_relative 'common/load_path'

require 'common'
require "gherkin_parse"

module BushSlicer
  class CaseIDSplitter
    include Commander::Methods
    include Common::Helper

    def initialize
      always_trace!
    end

    def run
      program :name, 'Case ID splitter'
      program :version, '0.0.1'
      program :description, 'Split feature files by test case ID tag'

      #Commander::Runner.instance.default_command(:gui)
      default_command :help

      command :fiddle do |c|
        c.syntax = "#{__FILE__} fiddle"
        c.description = 'enter a pry shell to play with API'
        c.action do |args, options|
          require 'pry'
          binding.pry
        end
      end

      command :"file-line" do |c|
        c.syntax = "#{$0} file-line CASE-123 ... [options]"
        c.description = "Generate a list of feature files and line numbers given a list of case IDs"
        c.action do |args, options|
          setup_global_opts(options)
          if args.empty?
            raise "please add Test Case IDs in the command line"
            exit false
          end

          parser = GherkinParse.new
          cases_loc = parser.locations_for(*args)
          features_list = generate_feature_list(cases_loc)
          puts features_list
        end
      end

      command :split do |c|
        c.syntax = "#{$0} split [options]"
        c.description = "Split feature files based on provided case_id tag\n\t" \
          'Example: tools/case_id_splitter.rb split --dir=features/ --target-dir=/tmp/split "OCP-xxxxx" "OCP-yyyyy" "OCP-zzzzz"'
        c.option('--dir DIR', "Where to search for feature files")
        c.option('--target-dir DIR', "Where to write the split files")
        c.option('--suffix STRING', "Feature name suffix of split files")
        c.action do |args, options|
          setup_global_opts(options)
          if args.empty?
            raise "please add Test Case IDs in the command line"
            exit false
          end

          dir = options.dir
          unless String === dir && Dir.exists?(dir)
            raise "directory '#{dir}' does not exist"
          end

          # setup target dir
          if options.target_dir
            FileUtils.mkdir_p(options.target_dir)
            split_scenarios_dir = File.join(options.target_dir, "split")
            remaining_scenarios_dir = File.join(options.target_dir, "remaining")
            Dir.mkdir(split_scenarios_dir)
            Dir.mkdir(remaining_scenarios_dir)
            options.split_scenarios_dir = split_scenarios_dir
            options.remaining_scenarios_dir = remaining_scenarios_dir
          else
            raise "please specify an empty or non-existent target dir"
          end

          parser = GherkinParse.new
          cases_loc = parser.ranges_for(*args, dir: dir) { |path, lines, ranges|
            split_feature(path, lines, normalize_ranges(ranges))
          }
        end
      end

      command :"add-tags" do |c|
        c.syntax = "#{$PROGRAM_NAME} add-tags [tag] [test_case]"
        c.description = "Add tags to test case\n\t" \
          'Example: tools/case_id_splitter.rb add-tags @tag_name OCP-xxxxx'
        c.option('--tags TAGS', Array, 'Tag to add to the scenario')
        c.option('--cid ID', String, 'Test case id')
        c.action do |_args, options|
          setup_global_opts(options)

          tags = options.tags
          case_id = options.cid

          add_tags_to_scenario(tags, case_id)
        end
      end

      run!
    end

    private def split_feature(path, lines, ranges)
      target_file = File.join(opts[:split_scenarios_dir], path)
      FileUtils.mkdir_p File.dirname(target_file)
      target_io = File.open(target_file, "w")
      target_io.write feature_line(lines), "\n"
      lines.unshift "" # range is in line numbers, not index
      ranges.each { |id, range|
        target_io.write *lines[range], "\n"
      }

      remaining_file = File.join(opts[:remaining_scenarios_dir], path)
      FileUtils.mkdir_p File.dirname(remaining_file)
      remaining_io = File.open(remaining_file, "w")
      from_index = 0
      ranges.each { |id, range|
        # manipulate indices to avoid multiple empty lines
        from_index += 1 while lines[from_index] =~ GherkinParse::EMPTY_STRING
        to_index = range.min - 1
        to_index -= 1 while lines[to_index] =~ GherkinParse::EMPTY_STRING
        write_range = (from_index..to_index)
        remaining_io.write(*lines[write_range], "\n") if write_range.any?
        from_index = range.max + 1
      }
      from_index += 1 while lines[from_index] =~ GherkinParse::EMPTY_STRING
      write_range = (from_index...lines.size)
      remaining_io.write *lines[write_range] if write_range.any?
    ensure
      target_io.close if target_io
      remaining_io.close if remaining_io
    end

    private def feature_line(lines)
      lines.find { |line| line =~ /^\s*Feature:/ }
    end

    # make sure ranges are unique, non-overlapping and sequentially ordered
    # @param ranges [Hash<String,Range>]
    private def normalize_ranges(ranges)
      uranges = ranges.uniq {|id,r| r}
      sranges = uranges.sort {|a, b| a.last.min <=> b.last.min}
      idx = 0
      while idx < sranges.size - 1
        if sranges[idx].last.max >= sranges[idx + 1].last.min
          raise "overlapping range '#{sranges[idx].last}' and " \
            "'#{sranges[idx + 1].last}'"
        end
        idx += 1
      end
      return sranges.to_h
    end

    # given a list of case_ids, generate a feature file location (file name + line number)
    # @param hash of location data, with the key as the case_id, and the value as the file
    # location and line numbers, separately.
    private def generate_feature_list(cases_loc_hash)
      complete_feature_list = []
      cases_loc_hash.each do |key, value|
        complete_feature_list << "#{value[0]}:#{value[1].to_s}"
      end
      return complete_feature_list
    end

    # add tags to a test scenario in the .feature
    private def add_tags_to_scenario(tags, case_id)
      parser = GherkinParse.new
      begin
        ranges_loc = parser.ranges_for(case_id)
      rescue RuntimeError => re
        puts "Could not find locations for test case #{case_id}"
        return
      end

      res = ranges_loc[case_id]

      current_tags = []
      start_line_num = 0

      content = IO.readlines(res[:file])
      res[:range].each do |i|
        current_tags << content[i].strip if content[i] =~ /^\s.*@/
        if content[i] =~ /^\s*(Scenario)/
          start_line_num = i
          break
        end
      end

      tags.each do |tag|
        if current_tags.include?(tag)
          puts "Test case #{case_id} already has tag #{tag}"
          next
        end

        line_to_add = "  #{tag}"
        puts "Adding tag #{tag} to #{res[:file]} for test case #{case_id}"
        content.insert(start_line_num, line_to_add)
      end

      File.open(res[:file], 'w') { |f| f.puts(content) }
    end

    def opts
      @opts || raise('please first call `setup_global_opts(options)`')
    end

    # @param options [Ostruct] options as processed by Commander
    def setup_global_opts(options)
      @opts = options.default
    end
  end
end

if __FILE__ == $0
  BushSlicer::CaseIDSplitter.new.run
end
