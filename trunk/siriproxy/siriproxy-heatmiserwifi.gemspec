# This is a gem specification (gemspec) for the SiriProxy plugin to control
# Heatmiser's range of Wi-Fi thermostats via their iPhone interface.

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

$:.push File.expand_path('../lib', __FILE__)

Gem::Specification.new do |s|
  s.name        = 'siriproxy-heatmiserwifi'
  s.version     = '0.0.1'
  s.author      = 'Alexander Thoukydides'
  s.email       = 'alex@thouky.co.uk'
  s.homepage    = 'https://code.google.com/p/heatmiser-wifi/'
  s.summary     = 'SiriProxy plugin to control Heatmiser Wi-Fi thermostats'
  s.description = %q{A plugin for SiriProxy to control Heatmiser's range of Wi-Fi thermostats via their iPhone interface.}
  s.license     = 'GPL-3'

  s.files         = `git ls-files 2> /dev/null`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/* 2> /dev/null`.split("\n")
  s.executables   = `git ls-files -- bin/* 2> /dev/null`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ['lib']
end
