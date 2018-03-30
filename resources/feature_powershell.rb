#
# Author:: Greg Zapp (<greg.zapp@gmail.com>)
# Author:: Tim Smith(<tsmith@chef.io>)
# Cookbook:: windows
# Resource:: feature_powershell
#
# Copyright:: 2015-2018, Chef Software, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

property :feature_name, [Array, String], coerce: proc { |x| to_lowercase_array(x) }, name_property: true
property :source, String
property :all, [true, false], default: false
property :timeout, Integer, default: 600
property :management_tools, [true, false], default: false

def to_lowercase_array(x)
  x = x.split(/\s*,\s*/) if x.is_a?(String) # split multiple forms of a comma separated list
  x.map(&:downcase)
end

include Chef::Mixin::PowershellOut

action :install do
  raise_on_old_powershell
  raise_if_unavailable # raise if the features don't exist
  raise_if_removed # raise if the features are in removed state

  Chef::Log.debug("Windows features needing installation: #{features_to_install.empty? ? 'none' : features_to_install.join(',')}")
  unless features_to_install.empty?
    converge_by("install Windows feature#{'s' if features_to_install.count > 1} #{features_to_install.join(',')}") do
      install_command = "#{install_feature_cmdlet} #{features_to_install.join(',')}"
      install_command << ' -IncludeAllSubFeature'  if new_resource.all
      if node['platform_version'].to_f < 6.2 && (new_resource.source || new_resource.management_tools)
        Chef::Log.warn("The 'source' and 'management_tools' properties are not available on Windows 2012R2 or great. Skipping these properties!")
      else
        install_command << " -Source \"#{new_resource.source}\"" if new_resource.source
        install_command << ' -IncludeManagementTools' if new_resource.management_tools
      end

      cmd = powershell_out!(install_command, timeout: new_resource.timeout)
      Chef::Log.info(cmd.stdout)

      reset_ps_cache # Reload cached powershell feature state
    end
  end
end

action :remove do
  raise_on_old_powershell

  Chef::Log.debug("Windows features needing removal: #{features_to_remove.empty? ? 'none' : features_to_remove.join(',')}")

  unless features_to_remove.empty?
    converge_by("remove Windows feature#{'s' if features_to_remove.count > 1} #{features_to_remove.join(',')}") do
      cmd = powershell_out!("#{remove_feature_cmdlet} #{features_to_remove.join(',')}", timeout: new_resource.timeout)
      Chef::Log.info(cmd.stdout)

      reset_ps_cache # Reload cached powershell feature state
    end
  end
end

action :delete do
  raise_on_old_powershell
  raise_if_delete_unsupported
  raise_if_unavailable # raise if the features don't exist

  Chef::Log.debug("Windows features needing deletion: #{features_to_delete.empty? ? 'none' : features_to_delete.join(',')}")

  unless features_to_delete.empty?
    converge_by("delete Windows feature#{'s' if features_to_delete.count > 1} #{features_to_delete.join(',')} from the image") do
      cmd = powershell_out!("Uninstall-WindowsFeature #{features_to_delete.join(',')} -Remove", timeout: new_resource.timeout)
      Chef::Log.info(cmd.stdout)

      reset_ps_cache # Reload cached powershell feature state
    end
  end
end

action_class do
  # shellout to determine the actively installed version of powershell
  # we have this same data in ohai, but it doesn't get updated if powershell is installed mid run
  # @return [Integer] the powershell version or 0 for nothing
  def powershell_version
    cmd = powershell_out('$PSVersionTable.psversion.major')
    return 1 if cmd.stdout.empty? # PowerShell 1.0 doesn't have a $PSVersionTable
    Regexp.last_match(1).to_i if cmd.stdout =~ /^(\d+)/
  rescue Errno::ENOENT
    0 # zero as in nothing is installed
  end

  # raise if we're running powershell less than 3.0 since we need convertto-json
  # check the powershell version via ohai data and if we're < 3.0 also shellout to make sure as
  # a newer version could be installed post ohai run. Yes we're double checking. It's fine.
  # @todo this can go away when we fully remove support for Windows 2008 R2
  # @raise [RuntimeError] Raise if powershell is < 3.0
  def raise_on_old_powershell
    # be super defensive about the powershell lang plugin not being there
    return if node['languages'] && node['languages']['powershell'] && node['languages']['powershell']['version'].to_i > 3
    raise 'The windows_feature_powershell resource requires PowerShell 3.0 or later. Please install PowerShell 3.0+ before running this resource.' if powershell_version < 3
  end

  def install_feature_cmdlet
    node['platform_version'].to_f < 6.2 ? 'Import-Module ServerManager; Add-WindowsFeature' : 'Install-WindowsFeature'
  end

  def remove_feature_cmdlet
    node['platform_version'].to_f < 6.2 ? 'Import-Module ServerManager; Remove-WindowsFeature' : 'Uninstall-WindowsFeature'
  end

  # @return [Array] features the user has requested to install which need installation
  def features_to_install
    # the intersection of the features to install & disabled features are what needs installing
    @install ||= new_resource.feature_name & ps_cache['disabled']
  end

  # @return [Array] features the user has requested to remove which need removing
  def features_to_remove
    # the intersection of the features to remove & enabled features are what needs removing
    @remove ||= new_resource.feature_name & ps_cache['enabled']
  end

  # @return [Array] features the user has requested to delete which need deleting
  def features_to_delete
    # the intersection of the features to remove & enabled/disabled features are what needs removing
    @remove ||= begin
      all_available = ps_cache['enabled'] + ps_cache['disabled']
      new_resource.feature_name & all_available
    end
  end

  # if any features are not supported on this release of Windows or
  # have been deleted raise with a friendly message. At one point in time
  # we just warned, but this goes against the behavior of ever other package
  # provider in Chef and it isn't clear what you'd want if you passed an array
  # and some features were available and others were not.
  # @return [void]
  def raise_if_unavailable
    all_available = ps_cache['enabled'] + ps_cache['disabled'] + ps_cache['removed']

    # the difference of desired features to install to all features is what's not available
    unavailable = (new_resource.feature_name - all_available)
    raise "The Windows feature#{'s' if unavailable.count > 1} #{unavailable.join(',')} #{unavailable.count > 1 ? 'are' : 'is'} not available on this version of Windows. Run 'Get-WindowsFeature' to see the list of available feature names." unless unavailable.empty?
  end

  # Raise if any of the packages are in a removed state
  # @return [void]
  def raise_if_removed
    return if new_resource.source # if someone provides a source then all is well
    if node['platform_version'].to_f > 6.2
      return if registry_key_exists?('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing') && registry_value_exists?('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing', name: 'LocalSourcePath') # if source is defined in the registry, still fine
    end
    removed = new_resource.feature_name & ps_cache['removed']
    raise "The Windows feature#{'s' if removed.count > 1} #{removed.join(',')} #{removed.count > 1 ? 'are' : 'is'} have been removed from the host and cannot be installed." unless removed.empty?
  end

  # Raise unless we're on windows 8+ / 2012+ where deleting a feature is supported
  def raise_if_delete_unsupported
    raise Chef::Exceptions::UnsupportedAction, "#{self} :delete action not support on Windows releases before Windows 8/2012. Cannot continue!" unless node['platform_version'].to_f >= 6.2
  end

  # read the cached powershell data
  # @return [Hash] Hash of arrays
  def ps_cache
    PSCache.instance.data
  end

  # reset the cached powershell data
  # @return [void]
  def reset_ps_cache
    PSCache.instance.reset
  end
end
