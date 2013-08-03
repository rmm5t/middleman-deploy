require "middleman-core/cli"

require "middleman-deploy/extension"
require "middleman-deploy/pkg-info"

PACKAGE = "#{Middleman::Deploy::PACKAGE}"
VERSION = "#{Middleman::Deploy::VERSION}"

module Middleman
  module Cli

    # This class provides a "deploy" command for the middleman CLI.
    class Deploy < Thor
      include Thor::Actions

      check_unknown_options!

      namespace :deploy

      # Tell Thor to exit with a nonzero exit code on failure
      def self.exit_on_failure?
        true
      end

      desc "deploy [options]", Middleman::Deploy::TAGLINE
      method_option "build_before",
      :type => :boolean,
      :aliases => "-b",
      :desc => "Run `middleman build` before the deploy step"

      def deploy
        if options.has_key? "build_before"
          build_before = options.build_before
        else
          build_before = self.deploy_options.build_before
        end
        if build_before
          # http://forum.middlemanapp.com/t/problem-with-the-build-task-in-an-extension
          run("middleman build") || exit(1)
        end
        send("deploy_#{self.deploy_options.method}")
      end

      protected

      def print_usage_and_die(message)
        raise Error, "ERROR: " + message + "\n" + <<EOF

You should follow one of the possible deploy configurations as described in
the README to setup the deploy extension in config.rb.

https://github.com/tvaughan/middleman-deploy#possible-configurations
EOF
      end

      def inst
        ::Middleman::Application.server.inst
      end

      def deploy_options
        options = nil

        begin
          options = inst.options
        rescue
          print_usage_and_die "You need to activate the deploy extension in config.rb."
        end

        if (!options.method)
          print_usage_and_die "The deploy extension requires you to set a method."
        end

        case options.method
        when :rsync
          if (!options.host || !options.path)
            print_usage_and_die "The rsync deploy method requires host and path to be set."
          end
        when :ftp, :sftp
          if (!options.host || !options.user || !options.password || !options.path)
            print_usage_and_die "The #{options.method} method requires host, user, password, and path to be set."
          end
        end

        options
      end

      def deploy_rsync
        host = self.deploy_options.host
        port = self.deploy_options.port
        user = self.deploy_options.user
        path = self.deploy_options.path
        url = [[user, host].compact.join("@"), path].join(":")

        puts "## Deploying via rsync to #{url} port=#{port}"

        command = "rsync -avze 'ssh -p #{port}' #{self.inst.build_dir}/ #{url}"

        if self.deploy_options.clean
          command += " --delete"
        end

        run command
      end

      def deploy_git
        remote = self.deploy_options.remote
        branch = self.deploy_options.branch

        puts "## Deploying via git to remote=\"#{remote}\" and branch=\"#{branch}\""

        #check if remote is not a git url
        unless remote =~ /\.git$/
          remote = `git config --get remote.#{remote}.url`.chop
        end

        #if the remote name doesn't exist in the main repo
        if remote == ''
          puts "Can't deploy! Please add a remote with the name '#{self.deploy_options.remote}' to your repo."
          exit
        end

        Dir.chdir(self.inst.build_dir) do
          unless File.exists?('.git')
            `git init`
            `git remote add origin #{remote}`
          else
            #check if the remote repo has changed
            unless remote == `git config --get remote.origin.url`.chop
              `git remote rm origin`
              `git remote add origin #{remote}`
            end
          end

          #if there is a branch with that name, switch to it, otherwise create a new one and switch to it
          if `git branch`.split("\n").any? { |b| b =~ /#{branch}/i }
            `git checkout #{branch}`
          else
            `git checkout -b #{branch}`
          end

          `git add -A`
          `git commit --allow-empty -am 'Automated commit at #{Time.now.utc} by #{PACKAGE} #{VERSION}'`
          `git push -f origin #{branch}`
        end
      end

      def deploy_ftp
        require 'net/ftp'
        require 'ptools'

        host = self.deploy_options.host
        user = self.deploy_options.user
        pass = self.deploy_options.password
        path = self.deploy_options.path

        puts "## Deploying via ftp to #{user}@#{host}:#{path}"

        ftp = Net::FTP.new(host)
        ftp.login(user, pass)
        ftp.chdir(path)
        ftp.passive = true

        Dir.chdir(self.inst.build_dir) do
          files = Dir.glob('**/*', File::FNM_DOTMATCH)
          files.reject { |a| a =~ Regexp.new('\.$') }.each do |f|
            if File.directory?(f)
              begin
                ftp.mkdir(f)
                puts "Created directory #{f}"
              rescue
              end
            else
              begin
                if File.binary?(f)
                  ftp.putbinaryfile(f, f)
                else
                  ftp.puttextfile(f, f)
                end
              rescue Exception => e
                reply = e.message
                err_code = reply[0,3].to_i
                if err_code == 550
                  if File.binary?(f)
                    ftp.putbinaryfile(f, f)
                  else
                    ftp.puttextfile(f, f)
                  end
                end
              end
              puts "Copied #{f}"
            end
          end
        end
        ftp.close
      end

      def deploy_sftp
        require 'net/sftp'
        require 'ptools'

        host = self.deploy_options.host
        user = self.deploy_options.user
        pass = self.deploy_options.password
        path = self.deploy_options.path

        puts "## Deploying via sftp to #{user}@#{host}:#{path}"

        Net::SFTP.start(host, user, :password => pass) do |sftp|
          sftp.mkdir(path)
          Dir.chdir(self.inst.build_dir) do
            files = Dir.glob('**/*', File::FNM_DOTMATCH)
            files.reject { |a| a =~ Regexp.new('\.$') }.each do |f|
              if File.directory?(f)
                begin
                  sftp.mkdir("#{path}/#{f}")
                  puts "Created directory #{f}"
                rescue
                end
              else
                begin
                  sftp.upload(f, "#{path}/#{f}")
                rescue Exception => e
                  reply = e.message
                  err_code = reply[0,3].to_i
                  if err_code == 550
                    sftp.upload(f, "#{path}/#{f}")
                  end
                end
                puts "Copied #{f}"
              end
            end
          end
        end
      end

    end

    # Alias "d" to "deploy"
    Base.map({ "d" => "deploy" })

  end
end
