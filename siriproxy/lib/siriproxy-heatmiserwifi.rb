# This is a plugin for SiriProxy for controlling Heatmiser's range of Wi-Fi
# thermostats via their iPhone interface.

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

require 'cora'
require 'date'
require 'set'
require 'siri_objects'
require_relative 'thermostat'


class SiriProxy::Plugin::HeatmiserWiFi < SiriProxy::Plugin

  def initialize(config)
    # Construct mappings between thermostat hostnames and aliases
    @host_to_name = {}
    @host_to_aliases_re = {}
    if config.has_key? 'thermostats'
      config['thermostats'].each do |host, aliases|
        @host_to_name[host] = sub_possessive_determiners aliases.first
        @host_to_aliases_re[host] = /#{aliases.join('|')}/i
      end
    end
  end

  # Useful regular expression components
  RE_HEATING = /(?:central )?heat(?:ing)?(?: (?:system|mode))?/i
  RE_FROSTPROTECT = /frost protect(?:ion)?(?: mode)?/i
  RE_HOTWATER = /hot water(?: system)?/i
  RE_STATUS = /(?:the )?(?:condition|state|status)/i
  RE_INTERIOR = /indoors?|inside|interior|internal/i
  RE_TEMPERATURE = /temperatures?/i
  RE_TARGET = /(?:target )?temperature|target/i
  RE_OPTIONAL_TARGET = /(?:#{RE_TARGET} )?/
  RE_HOLD = /hold(?:ing)?|keep|maintain/i
  RE_HOTCOLD = /cold|cool|hot|warm/i
  RE_WHATIS = /(?:what (?:is|are)|what's|check|examine|interrogate|query)(?: the)?/i
  RE_SWITCH = /switch|turn|place|put/i
  RE_IS = /are|if|is/i
  RE_ISIT = /is it/i
  RE_HOW = /how/i
  RE_FOR = /for/i
  RE_OVERRIDE = /override|manual(?: control)?/i
  RE_SET = /place|put|set|#{RE_SWITCH} on/i
  RE_TO = /at|in|to|two/i # (Siri sometimes recognises 'to' as 'two')
  RE_OPTIONAL_BY = /(?:by )?/i
  RE_OPTIONAL_OF = /(?:of )?/i
  RE_OPTIONAL_AND = /(?:and )?/i
  RE_INCREASE = /increase|raise/i
  RE_DECREASE = /decrease|reduce|lower/i
  RE_CANCEL = /abort|cancel|countermand|end|finish|rescind|revoke|stop|terminate/i
  RE_AWAY = /(?:(?:in|on|to) )?(?:holiday|away)(?: (?:mode|state))?/i
  RE_RETURN =/until|return(?:ing)?(?: (?:on|at))?/i
  RE_ON = /on/i
  RE_OFF = /off/i
  RE_ONOFF = /(#{RE_ON}|#{RE_OFF})/
  RE_ENABLE = /enabled?|active|activated/i
  RE_DISABLE = /disabled?|inactive|deactivated/i
  RE_ENABLEDISABLE = /(#{RE_ENABLE}|#{RE_DISABLE})/
  RE_ACTIVATED = /#{RE_ON}|#{RE_OFF}|#{RE_ENABLE}|#{RE_DISABLE}/

  # Regular expressions to match all or specific named thermostats
  # (It would be better to explicitly match against the configured aliases,
  # but the listeners are registered before the configuration is available.)
  RE_THERMOSTATS_ALL = /all (?:(?:of )?(?:the|my) )?(?:Heatmiser )?thermostats/i
  RE_THERMOSTATS_SINGLE = /(?:(?:the|my) )?(?:Heatmiser )?thermostat/i
  RE_THERMOSTATS_NAMED_PREFIX = /(?:(?:the|my) )?/i
  RE_THERMOSTATS_NAMED_SUFFIX = / (?:Heatmiser )?thermostats?/i
  RE_THERMOSTATS = /((?:\w+ )*thermostats?)/i
  RE_OPTIONAL_THERMOSTATS = /|the |(\w+(?: \w+)*) /i

  # Regular expressions to match integers
  DIGITS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven',
            'eight', 'nine']
  RE_ONE = /a|an/i
  RE_DIGIT = /#{DIGITS.join('|')}/i
  RE_NUMERALS = /\d+/
  RE_INTEGER = /#{RE_ONE}|#{RE_DIGIT}|#{RE_NUMERALS}/

  # Regular expressions to match temperatures
  DEGREE = "\u00B0" # (degree symbol)
  RE_DEGREES_VALUE = RE_INTEGER
  RE_DEGREES_UNITS_PREFIX = /(?: ?degrees?|#{DEGREE})?/i
  RE_DEGREES_UNITS_C = /#{RE_DEGREES_UNITS_PREFIX} ?(?:Centigrade|Celsius|C)/i
  RE_DEGREES_UNITS_F = /#{RE_DEGREES_UNITS_PREFIX} ?(?:Fahrenheit|F)/i
  RE_DEGREES_UNITS_NONE = RE_DEGREES_UNITS_PREFIX
  RE_DEGREES_UNITS = /#{RE_DEGREES_UNITS_C}|#{RE_DEGREES_UNITS_F}|#{RE_DEGREES_UNITS_NONE}/
  RE_DEGREES = /(#{RE_DEGREES_VALUE}#{RE_DEGREES_UNITS})/

  # Regular expressions to match (hold) durations
  RE_DURATION_VALUE = RE_INTEGER
  RE_DURATION_UNITS_MINUTES = / ?minutes?/i
  RE_DURATION_UNITS_HOURS = / ?hours?/i
  RE_DURATION_UNITS_DAYS = / ?days?/i
  RE_DURATION_UNITS_WEEKS = / ?weeks?/i
  RE_DURATION_UNITS = /#{RE_DURATION_UNITS_MINUTES}|#{RE_DURATION_UNITS_HOURS}|#{RE_DURATION_UNITS_DAYS}|#{RE_DURATION_UNITS_WEEKS}/
  RE_DURATION = /(#{RE_DURATION_VALUE}#{RE_DURATION_UNITS})/

  # Regular expressions to match dates and times
  MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
            'August', 'September', 'October', 'November', 'December']
  RE_DAY = /\d\d?(?:st|nd|rd|th)/i
  RE_MONTH = /#{MONTHS.join('|')}/i
  RE_YEAR = /\d\d\d\d/
  RE_DATE_UK = /#{RE_DAY} (?:of )?#{RE_MONTH}(?: #{RE_YEAR})?/i
  RE_DATE_US = /#{RE_MONTH} #{RE_DAY}(?: #{RE_YEAR})?/i
  RE_DATE = /#{RE_DATE_UK}|#{RE_DATE_US}/
  RE_TIME = /\d\d:\d\d(?: ?(?:AM|PM))/i
  RE_DATETIME = /(#{RE_DATE}|#{RE_TIME}|#{RE_TIME} (?:on )#{RE_DATE})/i

  # Allow more readable regexps for speech patterns

  #   WORDS in capitals have 'RE_' prefixed to give constant name
  #   [WORDS] in capitals surrounded by square brackets have 'RE_OPTIONAL_'
  #     prefixed and the following space (if not at end of pattern) removed
  def self.listen_for_phrase(pattern, &block)
    flattened = pattern.gsub(/\[([A-Z_]+)\](?: |$)|([A-Z_]+)/) do |match|
      if match =~ /\[(\w+)\]/
        const_get("RE_OPTIONAL_#{$1}")
      else
        const_get("RE_#{match}")
      end
    end
    # HERE - Consider requiring match to be at the end of the speech
    listen_for /\b#{flattened}\b/i, &block
  end

  # Queries that apply to all types of thermostat

  listen_for_phrase('WHATIS THERMOSTATS STATUS')\
    { |thermostats| query_status thermostats }
  listen_for_phrase('WHATIS STATUS [OF] THERMOSTATS')\
    { |thermostats| query_status thermostats }

  # Actions that apply to all types of thermostat

  listen_for_phrase('SWITCH THERMOSTATS ONOFF')\
    { |thermostats, onoff| action_onoff thermostats, onoff }
  listen_for_phrase('SWITCH ONOFF THERMOSTATS')\
    { |onoff, thermostats| action_onoff thermostats, onoff }

  listen_for_phrase('SET THERMOSTATS AWAY RETURN DATETIME')\
    { |thermostats, datetime| action_holiday thermostats, datetime }

  listen_for_phrase('CANCEL THERMOSTATS AWAY')\
    { |thermostats| action_holiday_cancel thermostats }
  listen_for_phrase('CANCEL AWAY FOR THERMOSTATS')\
    { |thermostats| action_holiday_cancel thermostats }

  # Queries that apply to thermostats with heating control

  listen_for_phrase('WHATIS INTERIOR TEMPERATURE')\
    { query_temperature nil }
  listen_for_phrase('HOW HOTCOLD ISIT INTERIOR')\
    { query_temperature nil }
  listen_for_phrase('ISIT HOTCOLD INTERIOR')\
    { query_temperature nil }
  listen_for_phrase('WHATIS THERMOSTATS TEMPERATURE')\
    { |thermostats| query_temperature thermostats }
  listen_for_phrase('IS [THERMOSTATS] HEATING ACTIVATED')\
    { |thermostats| query_heating_status thermostats }
  listen_for_phrase('WHATIS [THERMOSTATS] HEATING STATUS')\
    { |thermostats| query_heating_status thermostats }
  listen_for_phrase('WHATIS STATUS [OF] [THERMOSTATS] HEATING')\
    { |thermostats| query_heating_status thermostats }

  # Actions that apply to thermostats with heating control

  listen_for_phrase('HOLD [THERMOSTATS] TARGET FOR DURATION')\
    { |thermostats, duration| action_hold_temperature thermostats, duration }

  listen_for_phrase('HOLD THERMOSTATS [TARGET] TO DEGREES FOR DURATION')\
    { |thermostats, degrees, duration| action_hold_temperature thermostats, duration, degrees }
  listen_for_phrase('HOLD [THERMOSTATS] TARGET TO DEGREES FOR DURATION')\
    { |thermostats, degrees, duration| action_hold_temperature thermostats, duration, degrees }
  listen_for_phrase('SET THERMOSTATS [TARGET] TO DEGREES [AND] HOLD FOR DURATION')\
    { |thermostats, degrees, duration| action_hold_temperature thermostats, duration, degrees }
  listen_for_phrase('SET [THERMOSTATS] TARGET TO DEGREES [AND] HOLD FOR DURATION')\
    { |thermostats, degrees, duration| action_hold_temperature thermostats, duration, degrees }

  listen_for_phrase('SET THERMOSTATS [TARGET] TO DEGREES')\
    { |thermostats, degrees| action_set_temperature thermostats, degrees }
  listen_for_phrase('SET [THERMOSTATS] TARGET TO DEGREES')\
    { |thermostats, degrees| action_set_temperature thermostats, degrees }

  listen_for_phrase('INCREASE [THERMOSTATS] TARGET [BY] DEGREES')\
    { |thermostats, degrees| action_increase_temperature thermostats, degrees }

  listen_for_phrase('DECREASE [THERMOSTATS] TARGET [BY] DEGREES')\
    { |thermostats, degrees| action_decrease_temperature thermostats, degrees }

  listen_for_phrase('CANCEL THERMOSTATS [TARGET] HOLD')\
    { |thermostats| action_cancel_hold thermostats }
  listen_for_phrase('CANCEL [THERMOSTATS] TARGET HOLD')\
    { |thermostats| action_cancel_hold thermostats }
  listen_for_phrase('CANCEL HOLD [THERMOSTATS] TARGET')\
    { |thermostats| action_cancel_hold thermostats }

  listen_for_phrase('SET THERMOSTATS TO FROSTPROTECT')\
    { |thermostats| action_frost_protect_mode thermostats }
  listen_for_phrase('ENABLEDISABLE [THERMOSTATS] FROSTPROTECT')\
    { |onoff, thermostats| action_frost_protect_mode thermostats, onoff }

  listen_for_phrase('SET THERMOSTATS TO HEATING')\
    { |thermostats| action_heating_mode thermostats }
  listen_for_phrase('ENABLEDISABLE [THERMOSTATS] HEATING')\
    { |onoff, thermostats| action_heating_mode thermostats, onoff }
  listen_for_phrase('SWITCH [THERMOSTATS] HEATING ONOFF')\
    { |thermostats, onoff| action_heating_mode thermostats, onoff }
  listen_for_phrase('SWITCH ONOFF [THERMOSTATS] HEATING')\
    { |onoff, thermostats| action_heating_mode thermostats, onoff }

  # Queries that apply to thermostats with hot water control

  listen_for_phrase('IS [THERMOSTATS] HOTWATER ACTIVATED')\
    { |thermostats| query_hotwater_status thermostats }
  listen_for_phrase('WHATIS [THERMOSTATS] HOTWATER STATUS')\
    { |thermostats| query_hotwater_status thermostats }
  listen_for_phrase('WHATIS STATUS [OF] [THERMOSTATS] HOTWATER')\
    { |thermostats| query_hotwater_status thermostats }

  # Actions that apply to thermostats with hot water control

  listen_for_phrase('SWITCH [THERMOSTATS] HOTWATER ONOFF')\
    { |thermostats, onoff| action_hotwater_onoff thermostats, onoff }
  listen_for_phrase('SWITCH ONOFF [THERMOSTATS] HOTWATER')\
    { |onoff, thermostats| action_hotwater_onoff thermostats, onoff }
  listen_for_phrase('ENABLEDISABLE [THERMOSTATS] HOTWATER')\
    { |onoff, thermostats| action_hotwater_onoff thermostats, onoff }

  listen_for_phrase('CANCEL [THERMOSTATS] HOTWATER OVERRIDE')\
    { |thermostats| action_hotwater_timer thermostats }

  # Queries that apply to all types of thermostat

  def query_status(thermostats)
    query_each_thermostat(thermostats) do |t|
      status = status_items_common(t)
      status.concat status_items_heating(t) if t.controls_heating?
      status.concat status_items_hotwater(t) if t.controls_hotwater?
      status.concat status_items_common_special(t)
      add_response nil, t, *status unless status.empty?
    end
  end

  # Actions that apply to all types of thermostat

  def action_onoff(thermostats, onoff)
    switch_on = speech_to_on(onoff)
    action_each_thermostat(thermostats) do |t|
      if t.on? == switch_on
        add_response nil, t, "was already #{onoff_to_s(switch_on)}"
      else
        t.on = switch_on # Switch thermostat on or off
        add_response 'I have turned', t, onoff_to_s(t.on?)
      end
    end
  end

  def action_holiday(thermostats, datetime)
    action_each_thermostat(thermostats) do |t|
      # HERE - Implement this command
      raise ResponseError, "I'm sorry, but I have not yet been taught how to place the thermostat in holiday mode."
    end
  end

  def action_holiday_cancel(thermostats)
    action_each_thermostat(thermostats) do |t|
      if t.holiday?
        t.cancel_holiday # Turn off away mode
        add_response 'I have cancelled', t, 'holiday mode'
      else
        add_response nil, t, 'was not in holiday mode'
      end
    end
  end

  # Queries that apply to thermostats with heating control

  def query_temperature(thermostats)
    query_each_thermostat_controlling_heating(thermostats) do |t|
      add_response 'According to', t,
                   'the current temperature is ' +
                   temperature_to_s(t.current_temperature,
                                    t.temperature_units)
    end
  end

  def query_heating_status(thermostats)
    query_each_thermostat_controlling_heating(thermostats) do |t|
      status = status_items_common(t)
      status.concat status_items_heating(t)
      add_response nil, t, *status unless status.empty?
    end
  end

  # Actions that apply to thermostats with heating control

  def action_set_temperature(thermostats, degrees)
    action_with_thermostats_controlling_heating(thermostats) do |ts|
      action_precondition_heating(ts, 'setting the target temperature')
      ts.each do |t|
        target = speech_to_temperature(degrees, t.temperature_units)
        t.target_temperature = target # Set the target temperature
        add_response nil, t, *status_items_heating(t)
      end
    end
  end

  def action_increase_temperature(thermostats, degrees)
    action_each_thermostat_controlling_heating(thermostats) do |t|
      if action_heating?(t)
        increase = speech_to_interval(degrees, t.temperature_units)
        t.target_temperature += increase # Increase the target temperature
        add_response nil, t, *status_items_heating(t)
      end
    end
  end

  def action_decrease_temperature(thermostats, degrees)
    action_each_thermostat_controlling_heating(thermostats) do |t|
      if action_heating?(t)
        decrease = speech_to_interval(degrees, t.temperature_units)
        t.target_temperature -= decrease # Decrease the target temperature
        add_response nil, t, *status_items_heating(t)
      end
    end
  end

  def action_hold_temperature(thermostats, duration, degrees = nil)
    action_with_thermostats_controlling_heating(thermostats) do |ts|
      if degrees
        action_precondition_heating(ts, 'setting the target temperature hold')
      end
      ts.each do |t|
        if degrees or action_heating?(t)
          minutes = speech_to_minutes(duration)
          target = speech_to_temperature(degrees, t.temperature_units) if degrees
          t.hold(minutes, target) # Set the target temperature hold
          add_response nil, t, *status_items_heating(t)
        end
      end
    end
  end

  def action_cancel_hold(thermostats)
    action_each_thermostat_controlling_heating(thermostats) do |t|
      if action_active?(t)
        if t.hold?
          t.cancel_hold # Cancel target temperature hold
          add_response 'I have cancelled', t, 'target temperature hold'
        else
          add_response nil, t, 'did not have temperature hold enabled'
        end
        add_response nil, t, *status_items_heating(t) if t.heating_mode?
      end
    end
  end

  def action_heating_mode(thermostats, onoff = nil)
    heat_on = speech_to_on(onoff)
    action_with_thermostats_controlling_heating(thermostats) do |ts|
      action_precondition_active(ts, 'turning heating mode on') if heat_on
      ts.each do |t|
        if heat_on or action_active?(t)
          if t.heating_mode? == heat_on
            add_response nil, t, "heating was already #{onoff_to_s(heat_on)}"
          elsif heat_on
            t.heating_mode # Turn on heating mode
            add_response 'I have turned', t, 'heating on'
          else
            t.frost_protect_mode # Turn on frost protection mode (if enabled)
            if t.frost_protect_enabled?
              add_response 'I have put', t, 'in frost protection mode'
            else
              add_response 'I have turned', t, 'heating off'
            end
          end
          add_response nil, t, *status_items_heating(t) if t.heating_mode?
        end
      end
    end
  end

  def action_frost_protect_mode(thermostats, onoff = nil)
    frost_on = speech_to_on(onoff)
    action_each_thermostat_controlling_heating(thermostats) do |t|
      if frost_on
        if not t.frost_protect_enabled?
          add_response 'Frost protection is disabled in the', t, 'configuration'
        elsif t.holiday?
          add_response 'I have left', t, 'in holiday mode'
        elsif t.frost_protect_mode?
          add_response nil, t, 'was already in frost protection mode'
        else
          t.frost_protect_mode # Turn on frost protection mode
          add_response 'I have put', t, 'in frost protection mode'
        end
      else # frost_off
        if not t.on?
          add_response nil, t, 'was already switched off'
        elsif t.heating_mode?
          add_response nil, t, 'was already in heating mode'
        else
          t.heating_mode # Turn on heating mode
          add_response 'I have turned', t, 'heating on'
        end
      end
      add_response nil, t, *status_items_heating(t) if t.heating_mode?
    end
  end

  # Queries that apply to thermostats with hot water control

  def query_hotwater_status(thermostats)
    query_each_thermostat_controlling_hotwater(thermostats) do |t|
      status = status_items_common(t)
      status.concat status_items_hotwater(t)
      add_response nil, t, *status unless status.empty?
    end
  end

  # Actions that apply to thermostats with hot water control

  def action_hotwater_onoff(thermostats, onoff)
    hotwater_on = speech_to_on(onoff)
    action_with_thermostats_controlling_hotwater(thermostats) do |ts|
      action_precondition_active(ts, 'turning the hot water on') if hotwater_on
      ts.each do |t|
        if hotwater_on or action_active?(t)
          if t.hotwater_active? == hotwater_on
            add_response nil, t,
                         "hot water was already #{onoff_to_s(hotwater_on)}"
          else
            t.hotwater = hotwater_on # Override the timer
            add_response 'I have turned', t,
                         "hot water #{onoff_to_s(t.hotwater_active?)}"
          end
        end
      end
    end
  end

  def action_hotwater_timer(thermostats)
    action_each_thermostat_controlling_hotwater(thermostats) do |t|
      if action_active?(t)
        t.hotwater = nil # Cancel any timer override
        add_response 'I have returned', t,
                     "hot water to timer control and it is now"\
                      " #{onoff_to_s(t.hotwater_active?)}"
      end
    end
  end

  # Common operations in queries

  def status_items_common(t)
    if not t.on?
      ['is switched off']
    elsif t.holiday?
      ["is in holiday mode until #{date_to_s(t.holiday_return_date)}"]
    else
      [] # (details will be added separately for heating and hot water)
    end
  end

  def status_items_common_special(t)
    if t.keylock?
      ['has its touchscreen locked']
    else
      []
    end
  end

  def status_items_heating(t)
    status = []
    if t.on? and not t.holiday?
      if t.heating_mode?
        status << 'has a target temperature of ' +
                  temperature_to_s(t.target_temperature, t.temperature_units, 0)
        if t.hold?
          status.last << " being held for #{minutes_to_s(t.hold_minutes)}"
        end
      elsif t.frost_protect_mode?
        status << 'is in frost protection mode'
      else
        status << 'has heating disabled'
      end
    end
    status << 'is currently measuring ' +
              temperature_to_s(t.current_temperature, t.temperature_units)
    if t.on? and t.heating_mode? || t.frost_protect_mode?
      status << "is #{t.heating_active? ? '' : 'not '}requesting heat"
    end
    status
  end

  def status_items_hotwater(t)
    if t.on? and not t.holiday?
      ["hot water is #{onoff_to_s(t.hotwater_active?)}"]
    else
      []
    end
  end

  # Common operations in actions

  def action_precondition_heating(ts, description) #, [yield]
    action_precondition_active(ts, description) do |t|
      if not t.heating_mode?
        add_response nil, t, 'has heating switched off'
      else
        yield t if block_given?
      end
    end
  end

  def action_precondition_active(ts, description) #, [yield]
    action_precondition(ts, description) do |t|
      if not t.on?
        add_response nil, t, 'is switched off'
      elsif t.holiday?
        add_response nil, t, 'is in holiday mode'
      else
        yield t if block_given?
      end
    end
  end

  def action_precondition(ts, description) #, yield
    ts.each { |t| yield t }
    if any_response?
      unless confirm_response "Should I continue #{description}?"
        raise ResponseError, "OK, no problem."
      end
    end
  end

  def action_heating?(t)
    if action_active?(t)
      if not t.heating_mode?
        add_response 'I have left', t, 'heating switched off'
      else
        return true
      end
    end
    return false
  end

  def action_active?(t)
    if not t.on?
      add_response 'I have left', t, 'switched off'
    elsif t.holiday?
      add_response 'I have left', t, 'in holiday mode'
    else
      return true
    end
    return false
  end

  # Query and action wrappers applying code block to each or all thermostats

  # Use metaprogramming to implement all of the variants:
  #   def query_each_thermostat(thermostats) #, yield
  #   def query_each_thermostat_controlling_heating(thermostats) #, yield
  #   def query_each_thermostat_controlling_hotwater(thermostats) #, yield
  #   def action_each_thermostat(thermostats) #, yield
  #   def action_each_thermostat_controlling_heating(thermostats) #, yield
  #   def action_each_thermostat_controlling_hotwater(thermostats) #, yield
  #   def query_with_thermostats(thermostats) #, yield
  #   def query_with_thermostats_controlling_heating(thermostats) #, yield
  #   def query_with_thermostats_controlling_hotwater(thermostats) #, yield
  #   def action_with_thermostats(thermostats) #, yield
  #   def action_with_thermostats_controlling_heating(thermostats) #, yield
  #   def action_with_thermostats_controlling_hotwater(thermostats) #, yield
  def method_missing(method, *args, &block)
    case method.id2name
    when /^(query|action)_each_thermostat(?:_controlling_(heating|hotwater))?$/
      do_with_thermostats(args[0], $1, $2) { |ts| ts.each(&block) }
    when /^(query|action)_with_thermostats(?:_controlling_(heating|hotwater))?$/
      do_with_thermostats(args[0], $1, $2, &block)
    else
      return super
    end
  end

  # Query and action wrapper applying code block to all selected thermostats

  def do_with_thermostats(*options) #, yield
    begin
      clear_response
      ts = select_thermostats *options
      yield ts
      say_response
    rescue ResponseError => e
      say *e.to_say_args
    rescue => e
      puts "Exception backtrace:", e.backtrace
      say "Error: #{e.to_s}", spoken: 'Sorry, something went wrong.'
    ensure
      request_completed
    end
  end

  # Read and select appropriate thermostats for the current request

  def select_thermostats(thermostats, verb, controlling)
    ts_all = read_all_thermostats
    named = speech_to_thermostats(thermostats)
    ts_selected = case named
                  when :single
                    filter_single_thermostat ts_all
                  when :all
                    ts_all
                  else
                    filter_named_thermostats ts_all, named
                  end
    ts_filtered = case controlling
                  when 'heating'
                    filter_thermostats_controlling_heating ts_selected, named
                  when 'hotwater'
                    filter_thermostats_controlling_hotwater ts_selected, named
                  else
                    ts_selected
                  end
    if verb == 'action' and named == :all and 1 < ts_filtered.size
      confirm_action_multiple_thermostats ts_filtered
    end
    ts_filtered
  end

  def read_all_thermostats
    begin
      all = Thermostat::read_all
    rescue => e
      puts "Exception backtrace:", e.backtrace
      raise ResponseError.new "Error reading thermostat status: #{e.to_s}",
            spoken: 'I am unable to communicate with the thermostat.'\
                    ' Have the Heatmiser Wi-Fi Perl scripts been correctly'\
                    ' installed?'
    end
    if all.empty?
      raise ResponseError.new\
            'There do not appear to be any thermostats configured.'\
            ' Have the Heatmiser Wi-Fi Perl scripts been correctly installed?'
    end
    all
  end

  def speech_to_thermostats(thermostats)
    case thermostats
    when nil, /^#{RE_THERMOSTATS_ALL}$/
      :all
    when /^#{RE_THERMOSTATS_SINGLE}$/
      :single
    else
      remain = thermostats.dup
      hosts = @host_to_aliases_re.flat_map do |host, re|
        remain.gsub!(/\b#{RE_THERMOSTATS_NAMED_PREFIX}?#{re}#{RE_THERMOSTATS_NAMED_SUFFIX}?\b/, '') ? host : []
      end
      unless remain =~ /^( +and )?$/i
        raise ResponseError.new\
              "I do not recognise \"#{remain.strip}\" as the name of a"\
              " thermostat.",
              spoken: 'Sorry, I do not recognise that thermostat name.'
      end
      hosts
    end
  end

  def filter_single_thermostat(ts)
    if 1 < ts.size
      raise ResponseError.new\
            "I found #{cardinal_to_s(ts.size)} thermostats:"\
            " #{thermostats_to_s(ts)}.",
            spoken: 'You appear to have multiple thermostats. Please'\
                    ' either specify all thermostats or name specific ones.'
    end
    ts
  end

  def filter_named_thermostats(ts, named)
    named.map do |n|
      ifnone = lambda do
        raise ResponseError.new\
              "I found #{thermostats_to_s(ts)} but was unable to locate"\
              " #{thermostats_to_s(n)}.",
              spoken: "Sorry, I could not find #{thermostats_to_s(n)}."
      end
      ts.detect(ifnone) { |t| t.host == n }
    end
  end

  def filter_thermostats_controlling_heating(ts, named)
    filter_thermostats_controlling(ts, named, 'heating')\
                                   { |t| t.controls_heating? }
  end

  def filter_thermostats_controlling_hotwater(ts, named)
    filter_thermostats_controlling(ts, named, 'hot water')\
                                   { |t| t.controls_hotwater? }
  end

  def filter_thermostats_controlling(ts, named, description, &controls)
    unless ts.any? &controls
      raise ResponseError,
            'I cannot do that because ' +
            (ts.size == 1 ? "#{thermostats_to_s(ts)} does not"\
                          : 'none of the thermostats') +
            " control #{description}."
    end
    if named.is_a? Array
      ts.reject(&controls).each do |t|
        add_response nil, t, "does not control #{description}"
      end
    end
    ts.find_all &controls
  end

  def confirm_action_multiple_thermostats(ts)
    number = ts.size == 2 ? 'both' : "all #{cardinal_to_s(ts.size)}"
    unless confirm "Would you like me to do that to #{thermostats_to_s(ts)}?",
                   spoken: "Would you like me to do that to #{number}"\
                           " thermostats?"
      raise ResponseError, "OK, I won't."
    end
  end

  # General speech and text processing

  def speech_to_on(onoff, default = true)
    case onoff
    when /^#{RE_ON}$/, /^#{RE_ENABLE}$/
      true
    when /^#{RE_OFF}$/, /^#{RE_DISABLE}$/
      false
    when nil
      default
    else
      raise "Unrecognised boolean \"#{onoff}\""
    end
  end

  def onoff_to_s(onoff)
    onoff ? 'on' : 'off'
  end

  def speech_to_i(integer)
    case integer
    when /^#{RE_ONE}/
      1
    when /^(#{RE_DIGIT}\b)/
      DIGITS.find_index $1.downcase
    when /^#{RE_NUMERALS}/
      integer.to_i
    end
  end

  def speech_to_temperature(degrees, to_units = nil, interval = false)
    number = speech_to_i degrees
    from_units = case degrees
                 when /#{RE_DEGREES_UNITS_C}$/
                   'C'
                 when /#{RE_DEGREES_UNITS_F}$/
                   'F'
                 end
    case [from_units, to_units]
    when ['C', 'F']
      temperature_c_to_f(number, interval)
    when ['F', 'C']
      temperature_f_to_c(number, interval)
    else
      number
    end
  end

  def speech_to_interval(degrees, to_units = nil)
    speech_to_temperature(degrees, to_units, true)
  end

  def temperature_to_s(degrees, units = nil, decimals = 1)
    format "%.#{decimals}f%s", degrees, units_to_s(units)
  end

  def units_to_s(units)
    case units
    when /^#{RE_DEGREES_UNITS_C}$/
      "#{DEGREE} Celsius"
    when /^#{RE_DEGREES_UNITS_F}$/
      "#{DEGREE} Fahrenheit"
    when nil, /^#{RE_DEGREES_UNITS_NONE}$/
      DEGREE
    else
      raise "Unrecognised temperature units \"#{units}\""
    end
  end

  def temperature_c_to_f(celcius, interval = false)
    celcius * 9.0 / 5 + (interval ? 0 : 32)
  end

  def temperature_f_to_c(fahrenheit, interval = false)
    (fahrenheit - (interval ? 0 : 32)) * 5.0 / 9
  end

  def speech_to_minutes(duration)
    number = speech_to_i duration
    multiplier = case duration
                 when /#{RE_DURATION_UNITS_MINUTES}$/
                   1
                 when /#{RE_DURATION_UNITS_HOURS}$/
                   60
                 when /#{RE_DURATION_UNITS_DAYS}$/
                   60 * 24
                 when /#{RE_DURATION_UNITS_WEEKS}$/
                   60 * 24 * 7
                 end
    number * multiplier
  end

  def date_to_s(date)
    date.strftime("%I:%M %p on %A #{ordinal_to_s(date.mday)} %B %Y")
  end

  def minutes_to_s(minutes)
    hours, minutes = minutes.divmod(60)
    days, hours = hours.divmod(24)
    duration = []
    if 0 < days
      duration << days.to_s + (days == 1 ? ' day' : ' days')
    end
    if 0 < hours
      duration << hours.to_s + (hours == 1 ? ' hour' : ' hours')
    end
    if duration.empty? or 0 < minutes
      duration << minutes.to_s + (minutes == 1 ? ' minute' : ' minutes')
    end
    list_to_s duration
  end

  def cardinal_to_s(n)
    DIGITS.fetch(n) { |n| n.to_s }
  end

  def ordinal_to_s(n)
    ordinal_indicator = ['st', 'nd', 'rd'].fetch((n - 1) % 10, 'th')
    ordinal_indicator = 'th' if 10 < n and n < 20 # (special case for 'teens')
    n.to_s + ordinal_indicator
  end

  def list_to_s(items, default = nil)
    if items.empty?
      default
    elsif items.size == 1
      items.first
    else
      items.slice(0, items.size - 1).join(', ') +
        (items.all? { |i| 1 < i.count(' ') } ? ',' : '') + # (Oxford comma)
        ' and ' + items.last
    end
  end

  def thermostats_to_s(ts)
    # HERE - Use 'the thermostat' if no alias defined and there is only one
    # HERE - Use 'all thermostats' if the list includes all of the thermostats
    names = ts.map { |t| @host_to_name.fetch(t.to_s, t.to_s) }
    names.sort!
    prefix = starts_with_possessive_adjective?(names.first) ? '' : 'the '
    suffix = names.size == 1 ? ' thermostat' : ' thermostats'
    prefix + list_to_s(names) + suffix
  end

  def sub_possessive_determiners(text)
    determiners = { 'my' => 'your', 'our' => 'your', 'your' => 'my' }
    text.gsub /\b(#{determiners.keys.join('|')})\b/, determiners
  end

  def starts_with_possessive_adjective?(text)
    text =~ /^(my|your|his|her|its|our|their|whose)\b/
  end

  def sub_pluralise_initial_possessive_adjectives(text) # (or verb)
    plurals = {'has' => 'have', 'was' => 'were', 'is' => 'are', # Possessive adj
               'its' => 'their', 'does' => 'do'} # Verbs
    text.gsub(/^((#{plurals.keys.join('|')}) )+/) { |p| p.gsub /\w+/, plurals }
  end

  # Exception for early return request processing

  # raise ResponseError, 'Written and spoken error text'
  # raise ResponseError.new 'Written error text', spoken: 'Spoken description'
  class ResponseError < RuntimeError

    def initialize(msg, options = {})
      @options = options
      super msg
    end

    def to_say_args
      [to_s, @options]
    end

  end

  # Compilation and formatting of responses

  def clear_response
    @response = {}
  end

  def any_response?
    not @response.empty?
  end

  def add_response(pre, t, *post)
    @response[pre] ||= {}
    @response[pre][post] ||= Set.new
    @response[pre][post] << t.to_s
  end

  def say_response
    say response_to_s
    clear_response
  end

  def confirm_response(question)
    question = response_to_s + "\n" + question if any_response?
    clear_response
    confirm question
  end

  def response_to_s
    lines = []
    @response.each do |pre, post_hash|
      post_hash.each do |post, ts|
        if 1 < ts.size
          post = post.map { |p| sub_pluralise_initial_possessive_adjectives p }
        end
        line = [pre, thermostats_to_s(ts), list_to_s(post)].compact.join(' ')
        lines << line.sub(/^./) { |c| c.upcase } + '.'
      end
    end
    lines.join("\n")
  end

end
