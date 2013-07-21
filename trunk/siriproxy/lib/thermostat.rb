# This is a Ruby class for accessing the iPhone interface of Heatmiser's
# range of Wi-Fi enabled thermostats via the heatmiser_json.pl script.

# Copyright © 2013 Alexander Thoukydides
#
# This file is part of the Heatmiser Wi-Fi project.
# <http://code.google.com/p/heatmiser-wifi/>
#
# Heatmiser Wi-Fi is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# Heatmiser Wi-Fi is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License
# along with Heatmiser Wi-Fi. If not, see <http://www.gnu.org/licenses/>.

require 'date'
require 'json'
require 'open3'


class Thermostat

  # Read status of all configured hosts and return array of Thermostat instances

  def self.read_all
    script_read_all.map { |host, dcb| Thermostat.new(host.to_s, dcb) }
  end

  # A single thermostat instance

  def initialize(host, dcb)
    @host = host
    @dcb = dcb
    read if dcb.empty?
  end

  attr_reader :host, :dcb

  # SQL DATETIME format string
  SQL_DATETIME = '%Y-%m-%d %H:%M:%S'

  # Query cached information common to all thermostats

  def to_s
    @host
  end

  def controls_heating?
    @dcb.has_key? :heating
  end

  def controls_hotwater?
    @dcb.has_key? :hotwater
  end

  def on?
    @dcb[:enabled] != 0
  end

  def holiday?
    @dcb[:holiday][:enabled] != 0
  end

  def holiday_return_date
    return unless holiday?
    DateTime.strptime(@dcb[:holiday][:time], SQL_DATETIME)
  end

  def keylock?
    @dcb[:keylock] != 0
  end

  # Control features common to all thermostats

  def on=(enabled)
    write(enabled: enabled)
  end

  def holiday(return_date)
    write(holiday: {enabled: true, time: return_date.strftime(SQL_DATETIME)})
  end

  def cancel_holiday
    write(holiday: {enabled: false})
  end

  def keylock=(enabled)
    write(keylock: enabled)
  end

  # Query cached information specific to thermostats with heating control

  def temperature_units # 'C' or 'F'
    @dcb[:config][:units]
  end

  def hold?
    @dcb[:heating][:hold] != 0
  end

  def hold_minutes
    @dcb[:heating][:hold]
  end

  def target_temperature
    return unless heating_mode?
    @dcb[:heating][:target]
  end

  def heating_mode?
    on? and @dcb[:runmode] == 'heating'
  end

  def frost_protect_enabled?
    @dcb[:frostprotect][:enabled] != 0
  end

  def frost_protect_mode?
    on? and @dcb[:runmode] == 'frost' and frost_protect_enabled?
  end

  def heating_active?
    @dcb[:heating][:on] != 0
  end

  def current_temperature
    # Select preferred sensor for which there is a temperature reading
    @dcb[:temperature].values_at(:remote, :internal, :floor).compact.first
  end

  # Control features specific to thermostats with heating control

  def hold(minutes, degrees = nil) # and force normal heating mode
    dcb_items = {enabled: true, holiday: {enabled: false}, runmode: 'heating',
                 heating: {hold: minutes}}
    dcb_items[:heating][:target] = degrees.round(0) if degrees
    write(dcb_items)
  end

  def cancel_hold
    write(heating: {hold: 0})
  end

  def target_temperature=(degrees) # and force normal heating mode
    write(enabled: true, holiday: {enabled: false}, runmode: 'heating',
          heating: {target: degrees.round(0)})
  end

  def heating_mode # and force thermostat to be enabled and not on holiday
    write(enabled: true, holiday: {enabled: false}, runmode: 'heating')
  end

  def frost_protect_mode # and force thermostat to be enabled
    write(enabled: true, runmode: 'frost')
  end

  # Query cached information specific to thermostats with hot water control

  def home_mode?
    on? and @dcb[:awaymode] == 'home'
  end

  def hotwater_active?
    @dcb[:hotwater][:on] != 0
  end

  def boost?
    @dcb[:hotwater][:boost] != 0
  end

  def boost_minutes
    @dcb[:hotwater][:boost]
  end

  # Control features specific to thermostats with hot water control

  def home_mode # and force thermostat to be enabled and not on holiday
    write(enabled: true, holiday: {enabled: false}, awaymode: 'home')
  end

  def away_mode
    write(awaymode: 'away')
  end

  def hotwater=(enabled = nil) # or nil to return to program
     # Also force normal hot water mode
    write(enabled: true, holiday: {enabled: false}, awaymode: 'home',
          hotwater: {on: enabled})
  end

  def boost(minutes) # and force normal hot water mode
    write(enabled: true, holiday: {enabled: false}, awaymode: 'home',
          hotwater: {boost: minutes})
  end

  def cancel_boost
    write(hotwater: {boost: 0})
  end

  private

  # Query or control a single thermostat, updating the cached status

  def read
    write_and_read
  end

  def write(dcb_items)
    write_and_read(dcb_items)
  end

  def write_and_read(dcb_items = nil)
    @dcb = self.class.script_write_and_read_single(@host, dcb_items)
  end

  # Perl script execution

  SCRIPT = 'heatmiser_json.pl'
  # Assume default installation location relative to this SiriProxy plugin
  @script_path = File.expand_path('../../bin', File.dirname(__FILE__))
  class << self
    attr_accessor :script_path
  end

  def self.script_read_all
    script_write_and_read
  end

  def self.script_write_and_read_single(host, dcb_items = nil)
    dcbs = script_write_and_read(host, dcb_items)
    return unless dcbs
    dcbs.values.first
  end

  def self.script_write_and_read(host = nil, dcb_items = nil)
    args = []
    args << '-h' << host if host
    args << JSON.generate(dcb_items) if dcb_items
    dcb_json = script_exec(args)
    JSON.parse(dcb_json, {symbolize_names: true})
  end

  def self.script_exec(args)
    script = File.expand_path(SCRIPT, @script_path)
    stdout_str, stderr_str, status = Open3.capture3(script, *args)
    unless status.success?
      puts "Error executing: #{script} #{args.join(' ')}"
      puts stderr_str
      raise stderr_str
    end
    stdout_str
  end

end
