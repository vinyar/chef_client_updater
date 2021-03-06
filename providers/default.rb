#
# Cookbook:: chef_client_updater
# Resource:: updater
#
# Copyright:: 2016-2017, Will Jordan
# Copyright:: 2016-2017, Chef Software Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use_inline_resources

provides :chef_client_updater if respond_to?(:provides)

def load_mixlib_install
  gem 'mixlib-install', '~> 3.2', '>= 3.2.1'
  require 'mixlib/install'
rescue LoadError
  Chef::Log.info('mixlib-install gem not found. Installing now')
  chef_gem 'mixlib-install' do
    version '>= 3.2.1'
    compile_time true if respond_to?(:compile_time)
  end

  require 'mixlib/install'
end

def load_mixlib_versioning
  require 'mixlib/versioning'
rescue LoadError
  Chef::Log.info('mixlib-versioning gem not found. Installing now')
  chef_gem 'mixlib-versioning' do
    compile_time true if respond_to?(:compile_time)
  end

  require 'mixlib/versioning'
end

def mixlib_install
  load_mixlib_install
  options = {
    product_name: 'chef',
    platform_version_compatibility_mode: true,
    channel: new_resource.channel.to_sym,
    product_version: new_resource.version == 'latest' ? :latest : new_resource.version,

  }
  if new_resource.download_url_override && new_resource.checksum
    options[:install_command_options] = { download_url_override: new_resource.download_url_override, checksum: new_resource.checksum }
  end
  Mixlib::Install.new(options)
end

# why would we use this when mixlib-install has a current_version method?
# well mixlib-version parses the manifest JSON, which might not be there.
# ohai handles this better IMO
def current_version
  node['chef_packages']['chef']['version']
end

def desired_version
  new_resource.version.to_sym == :latest ? mixlib_install.available_versions.last : new_resource.version
end

# why wouldn't we use the built in update_available? method in mixlib-install?
# well that would use current_version from mixlib-install and it has no
# concept or preventing downgrades
def update_necessary?
  load_mixlib_versioning
  cur_version = Mixlib::Versioning.parse(current_version)
  des_version = Mixlib::Versioning.parse(desired_version)
  Chef::Log.debug("The current chef-client version is #{cur_version} and the desired version is #{desired_version}")
  new_resource.prevent_downgrade ? (des_version > cur_version) : (des_version != cur_version)
end

def eval_post_install_action
  return unless new_resource.post_install_action == 'exec'

  if Chef::Config[:interval]
    Chef::Log.warn 'post_install_action "exec" not supported for long-running client process -- changing to "kill".'
    new_resource.post_install_action = 'kill'
  end

  return if Process.respond_to?(:exec)
  Chef::Log.warn 'post_install_action Process.exec not available -- changing to "kill".'
  new_resource.post_install_action = 'kill'
end

def run_post_install_action
  # make sure the passed action will actually work
  eval_post_install_action

  case new_resource.post_install_action
  when 'exec'
    if Chef::Config[:local_mode]
      Chef::Log.info 'Shutting down local-mode server.'
      if Chef::Application.respond_to?(:destroy_server_connectivity)
        Chef::Application.destroy_server_connectivity
      elsif defined?(Chef::LocalMode) && Chef::LocalMode.respond_to?(:destroy_server_connectivity)
        Chef::LocalMode.destroy_server_connectivity
      end
    end
    Chef::Log.warn 'Replacing ourselves with the new version of Chef to continue the run.'
    Kernel.exec(new_resource.exec_command, *new_resource.exec_args)
  when 'kill'
    if Chef::Config[:client_fork] && Process.ppid != 1
      Chef::Log.warn 'Chef client is defined for forked runs. Sending TERM to parent process!'
      Process.kill('TERM', Process.ppid)
    end
    Chef::Log.warn 'New chef-client installed. Forcing chef exit!'
    exit(213)
  else
    raise "Unexpected post_install_action behavior: #{new_resource.post_install_action}"
  end
end

# cleanup a previous backup of the chef-client on windows
def cleanup_windows_workaround
  directory 'c:/opscode/chef.upgrade' do
    action :delete
    recursive true
  end
end

# Windows does not like having files that are open deleted. We need to workaround that
def windows_workaround
  execute 'chef-move' do
    command 'move c:/opscode/chef c:/opscode/chef.upgrade'
  end
end

action :update do
  cleanup_windows_workaround if platform_family?('windows')

  if update_necessary?
    converge_by "Upgraded chef-client #{current_version} to #{desired_version}" do
      windows_workaround if platform_family?('windows')

      upgrade_command = Mixlib::ShellOut.new(mixlib_install.install_command)
      upgrade_command.run_command
      run_post_install_action
    end
  end
end
