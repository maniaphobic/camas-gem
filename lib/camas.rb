# encoding: UTF-8
# ________________________________________
# Description: Import Chef community cookbooks to a local Gerrit mirror

# Import required modules

require 'fileutils'
require 'inifile'
require 'tmpdir'
require 'tempfile'
require 'yaml'

# Camas namespace
module Camas
  # Application class
  class App
    def initialize(config_path=[])
      @config = parse_config(config_path.first)
      @project_config_path = 'project.config'
    end

    # Run the application
    def run
      default = @config.fetch('default', {})
      failsafe = default.fetch('debug', false) == true ? 'echo' : ''

      # Iterate over the cookbooks to mirror

      @config.fetch('cookbooks', {}).each do |cb_name, cb_spec|

        # Extract the source and local Git URLs, and create a
        # temporary path for each repository

        local_path  = Dir.mktmpdir
        local_url   = sprintf(cb_spec.fetch('local_url', ''), cb_name)
        source_path = Dir.mktmpdir
        source_url  = sprintf(cb_spec.fetch('source_url', ''), cb_name)

        # Execute the process in a "begin" block to guarantee that we
        # remove the temporary paths in the "ensure" branch

        begin

          # Clone the local repository and grant the "create" and "push"
          # privileges to the specified LDAP group

          `git clone #{local_url} #{local_path}`
          Dir.chdir(local_path) do
            `git fetch origin refs/meta/config:refs/remotes/origin/meta/config`
            `git checkout meta/config`

            # Load the project configuration file, which is in INI format

            begin
              project_config = IniFile.load(@project_config_path)
            rescue StandardError => e
              raise("Failed while loading project config file '#{@project_config_path}': #{e.msg}")
            end

            # Load the Gerrit privileges from the configuration.
            # Merge each matching section.

            default.fetch('gerrit', {})
              .fetch('project_config', {}).each do |section_name, section_body|
              next unless project_config.has_section?(section_name)
              project_config.merge!(
                IniFile.new({ content: { section_name => section_body } })
              )
            end

            # Write the project configuration file to disk

            begin
              project_config.write
            rescue StandardError => e
              raise("Failed writing Gerrit project configuration: '#{e.msg}'")
            end

            # Import the Git commit message configuration

            msg_spec = default.fetch('git', {})
                         .fetch('commit_message', {})
            msg_text = msg_spec.fetch(
              'text',
              "I modified the project configuration file"
            )

            # Convert the variables to symbols for #sprintf

            msg_variables = Hash[
              msg_spec.fetch('variables', {}).map do |k, v|
                [k.to_sym, v]
              end
            ]

            # Create a commit message, commit the changes, and publish
            # the changes

            commit_msg = Tempfile.new('commit_msg')
            begin
              commit_msg.write(sprintf(msg_text, msg_variables))
              commit_msg.close
              `git commit --all --file #{commit_msg.path}`
            ensure
              commit_msg.unlink
            end
            `#{failsafe} git push origin meta/config:meta/config`
          end

          # Clone the source repository, create an "upstream" branch, and
          # push it to Gerrit

          `git clone #{source_url} #{source_path}`
          Dir.chdir(source_path) do
            `git remote add gerrit #{local_url}`
            `git checkout -b upstream`
            `#{failsafe} git push gerrit upstream`
          end

          # Fetch the "upstream" branch, copy it to "master", and push

          Dir.chdir(local_path) do
            `git fetch origin upstream`
            `git checkout upstream`
            `git checkout -b master`
            `#{failsafe} git push origin master`
          end
        ensure
          # Remove the temporary paths
          [local_path, source_path].each do |path|
            FileUtils.remove_entry(path)
          end
        end
      end
    end

    # Parse the config file
    def parse_config(config_path)
      begin
        YAML.load(IO.read(config_path))
      rescue StandardError => e
        raise("Failed reading configuration from '#{config_path}': '#{e}'")
      end
    end
  end
end
