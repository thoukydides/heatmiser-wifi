# Heatmiser Wi-Fi #

This project comprises a suite of [Perl](http://www.perl.org/) libraries for communicating with [Heatmiser Wi-Fi thermostats](http://www.heatmiser.co.uk/web/index.php/wifi-thermostats) together with a collection of optional clients:
* A daemon for logging the temperature and activity of the thermostat(s) to a [MySQL](http://dev.mysql.com/) database. This can optionally also record external temperatures obtained from an online weather service ([UK Met Office](http://www.metoffice.gov.uk/datapoint), [Weather Underground](http://www.wunderground.com/weather/api) or [Yahoo! Weather](http://developer.yahoo.com/weather)).
* A web interface for generating charts of the logged temperature, heating and hot water activity.
* A plugin for [SiriProxy](https://github.com/plamoni/SiriProxy) that allows voice control of the thermostat(s) from iPhone and iPad devices.<br>**Note: SiriProxy does not currently work with iOS 7 or 8; see [SiriProxy issue 542](https://github.com/plamoni/SiriProxy/issues/542) for details.**
* A utility to keep the thermostats' clocks synchronised, including summer time (daylight saving time) changes.

**Read the [Installation Instructions](https://github.com/thoukydides/heatmiser-wifi/wiki/Installation) to get started.**

![](https://raw.githubusercontent.com/wiki/thoukydides/heatmiser-wifi/architecture.png) 

This software has been developed on Ubuntu Linux versions 10.04.3 LTS and 12.04 LTS with Heatmiser PRT-TS WiFi and PRTHW-TS WiFi RF thermostats. It should work with most other Linux distributions (including Debian Raspbian "wheezy" on the [Raspberry Pi](http://www.raspberrypi.org/)) and any mixture of Heatmiser Wi-Fi thermostat models (PRT-TS WiFi, PRT-TS WiFi RF, PRTHW-TS WiFi, PRTHW-TS WiFi RF and PRT-ETS WiFi). It does **not** support hot-water only models (DT-TS WiFi or DT-TS WiFi RF), the newer Neo models, or any of the wired variants (including Multi-Link or Netmonitor).

![](https://raw.githubusercontent.com/wiki/thoukydides/heatmiser-wifi/chart-ipad-with-siri.png)

***
<sup>© Copyright 2011-2015 Alexander Thoukydides</sup>
